#!/usr/bin/env python3
"""Validate a FLASHIda method.json against the two-decision-section schema (ADR-0013 / ADR-0014).

Two check classes, and the distinction is the whole point:

  CLASS A  the engine would THROW at load -- we just find out in 200 ms instead of
           after a failed acquisition.
  CLASS B  the engine stays SILENT. These are the config states that load clean,
           run green, and do nothing. There is no other tool for these.

CLASS B got much smaller in the reshape, and that shrinkage is the measure of whether
the reshape worked. Things that used to be silent and are now load-time throws:

  unknown `mode` / `rank_by` / `metric` / `targeting`   (all four used to guess, and
      they guessed in DIFFERENT directions: a typo'd selection ENABLED MS3 while a
      typo'd metric DISABLED the sweep)
  ce_step <= 0 / reaction_time_step <= 0                (used to be an infinite loop
      inside processScan, on the C# ActionBlock thread -- a hang, not an error)
  selection_strategy.ms3.max_targets                    (the dead key four configs set
      to 200 while running 3; deleted, so it is now an unknown key)
  ms_settings.ms3[1..N]                                 (parsed, validated, unreachable;
      ms3 is a bare object now)

Usage:
    python validate.py <config.json> [more.json ...]
    python validate.py --all                      # every committed config
Exit code 1 if any CLASS A error is found, else 0.
"""
import json
import sys
import os
import glob
import re

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REFERENCE = os.path.join(REPO, "FlashIDA", "test-data", "config_schema_reference.json")
CONFIG_DIR = os.path.join(REPO, "FlashIDA", "test-data", "configs")

# --- values the engine accepts, from the code (NOT the doc comments) ----------
MODE_VALUES = {"off", "ambiguity", "coverage", "exhaustive"}
RANK_BY_VALUES = {"intensity", "qscore", "none"}
METRIC_VALUES = {"none", "mass_count", "remaining_precursor", "fragment_count"}
TARGETING_VALUES = {"none", "inclusion", "in_depth", "exclusion_masses"}
# Config.cpp -- ordinal, case-sensitive. These are a wire contract with the Thermo
# API, so unlike the schema keys they are deliberately NOT lowercased.
NEEDS_CE = {"HCD", "CID", "EThcD"}
NEEDS_RT = {"ETD", "EThcD"}
# ADR-0011 source-region parameters: 0 means "inherit the survey's value"
SOURCE_REGION = ("rf_lens", "source_cid", "source_cid_scaling")

# Keys the schema has gained but the COMMITTED config_schema_reference.json has not yet.
#
# The reference is GENERATED (a C# test under REGEN_CONFIG_REFERENCE=1, promoted from the CI
# artifact), so it structurally lands one commit behind the C#/C++ pair that adds a key -- there
# is no way to regenerate it in this workspace. Without this exemption the recursive allowlist in
# check_unknown_keys reports A3 "unknown key" for a key that is in fact legal on both sides, and a
# validator that emits false CLASS A errors is worse than no validator: the next reader learns to
# ignore its output.
#
# DELETE an entry the moment the regenerated reference lands carrying that key. A stale entry here
# is a hole in the allowlist, which is the failure this file exists to prevent (ADR-0007).
PENDING_REFERENCE_KEYS = {
    "characterization.min_target_mass",  # ADR-0023, exhaustive-mode pool floor
}

SCAN_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
RESERVED_SCAN_NAMES = {"ms1", "ms2", "ms3", "none", "off", "all"}

# C# property initialisers -- the EFFECTIVE defaults, because ToCppJson emits every
# key unconditionally so the C++ .value(key, default) fallbacks are dead in production.
DEFAULT_MODE = "off"
DEFAULT_MAX_TARGETS = 3
DEFAULT_RANK_BY = "qscore"


class Report:
    def __init__(self, path):
        self.path = path
        self.errors = []
        self.warns = []
        self.info = []

    def error(self, code, msg):
        self.errors.append((code, msg))

    def warn(self, code, msg):
        self.warns.append((code, msg))

    def note(self, msg):
        self.info.append(msg)


def scan_defs(cfg):
    """Every (path, scan_object) DEFINITION. Not the dispatch roster -- see roster()."""
    ms = cfg.get("ms_settings") or {}
    out = []
    for lvl in ("ms1", "ms2", "ms3"):
        if isinstance(ms.get(lvl), dict):
            out.append((f"ms_settings.{lvl}", ms[lvl]))
    add = ms.get("additional_ms2")
    if isinstance(add, dict):
        for name, sc in add.items():
            if isinstance(sc, dict):
                out.append((f"ms_settings.additional_ms2.{name}", sc))
    return out


def roster(cfg, level):
    """What level N actually DISPATCHES, in order. Order comes from the reference
    ARRAY, never from map iteration -- nlohmann's object_t is a std::map, so walking
    additional_ms2 would sort the names alphabetically and silently reorder dispatch."""
    ms = cfg.get("ms_settings") or {}
    if level == 1:
        return [("ms_settings.ms1", ms.get("ms1"))] if isinstance(ms.get("ms1"), dict) else []
    if level == 3:
        return [("ms_settings.ms3", ms.get("ms3"))] if isinstance(ms.get("ms3"), dict) else []
    out = []
    if isinstance(ms.get("ms2"), dict):
        out.append(("ms_settings.ms2", ms["ms2"]))
    add = ms.get("additional_ms2") or {}
    for n in (cfg.get("precursor_selection") or {}).get("additional_scans") or []:
        if isinstance(add, dict) and n in add:
            out.append((f"ms_settings.additional_ms2.{n}", add[n]))
    return out


def explorations(cfg):
    """The two exploration blocks, each tagged with the level it sweeps."""
    out = []
    ps = cfg.get("precursor_selection") or {}
    ch = cfg.get("characterization") or {}
    if isinstance(ps.get("exploration"), dict):
        out.append(("precursor_selection", 2, ps["exploration"]))
    if isinstance(ch.get("exploration"), dict):
        out.append(("characterization", 3, ch["exploration"]))
    return out


def check_unknown_keys(cfg, ref, rep):
    """Recursive allowlist check. Two exemptions, for opposite reasons:
    exploration.overrides is a dynamic string->string map (keys AND values free);
    additional_ms2 has user-authored KEYS but its values are full scan objects and
    are checked against the scan allowlist."""

    def walk(node, refnode, path):
        if not isinstance(node, dict) or not isinstance(refnode, dict):
            return
        if path.endswith(".exploration.overrides"):
            return
        if path == "ms_settings.additional_ms2":
            # keys are the user's; every value is a scan object
            sample = next((v for v in refnode.values() if isinstance(v, dict)), None)
            if sample:
                for k, v in node.items():
                    walk(v, sample, f"{path}.{k}")
            return
        for k, v in node.items():
            full = f"{path}.{k}" if path else k
            if k not in refnode:
                if full in PENDING_REFERENCE_KEYS:
                    continue
                rep.error("A3", f"unknown key '{full}'")
                continue
            rv = refnode[k]
            if isinstance(v, dict) and isinstance(rv, dict):
                walk(v, rv, full)

    walk(cfg, ref, "")


def validate(path, ref):
    rep = Report(path)
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:
        rep.error("A1", f"invalid JSON: {exc}")
        return rep, None

    ms = cfg.get("ms_settings") or {}
    ps = cfg.get("precursor_selection") or {}
    chz = cfg.get("characterization") or {}
    add = ms.get("additional_ms2") if isinstance(ms.get("additional_ms2"), dict) else {}

    # ---------------- CLASS A2 : migration errors (checked first) ---------------
    # These land before the generic unknown-key message, which would say only
    # "unknown key 'selection_strategy'" and leave the reader to find seven destinations.
    migrated = False
    if "selection_strategy" in cfg:
        rep.error("A2", "'selection_strategy' has been removed (ADR-0014). ms1.selection -> "
                        "precursor_selection.rank_by; ms1.max_targets -> .max_precursors; "
                        "ms1.min_charge -> .min_precursor_charge; ms2.exploration -> "
                        ".exploration; ms2.max_targets -> characterization.max_targets; "
                        "ms2.min_charge -> .min_fragment_charge; ms3.exploration -> "
                        "characterization.exploration. ms2/ms3.selection are absorbed by "
                        "characterization.mode; ms3.max_targets/.min_charge are deleted (dead).")
        migrated = True
    if "ms3" in cfg:
        rep.error("A2", "'ms3' is not a top-level section. MS3 is configured under "
                        "'characterization' with its scan parameters in 'ms_settings.ms3'.")
        migrated = True
    for lvl in ("ms2", "ms3"):
        if isinstance(ms.get(lvl), list):
            rep.error("A2", f"'ms_settings.{lvl}' is no longer an array; it is a single scan "
                            "object." + (" Extra MS2 configs go in 'ms_settings.additional_ms2' "
                                         "and are referenced by name." if lvl == "ms2" else
                                         " There is no additional_ms3: every level-3 consumer "
                                         "reads scans[0]."))
            migrated = True
    for sec in ("tagging", "quantification"):
        fus = (cfg.get(sec) or {}).get("follow_up_scan")
        if isinstance(fus, dict):
            rep.error("A2", f"{sec}.follow_up_scan is no longer an inline scan object; it is the "
                            f"NAME of an ms_settings.additional_ms2 entry, e.g. \"{sec}_follow_up\".")
            migrated = True
    if migrated:
        # Every check below reads the new shape; running them on an old file just
        # produces a second, confusing wall of errors.
        return rep, None

    # ---------------- CLASS A : the engine would throw --------------------
    check_unknown_keys(cfg, ref, rep)

    mode = chz.get("mode", DEFAULT_MODE)
    if mode not in MODE_VALUES:
        rep.error("A16", f"characterization.mode '{mode}' is not legal; expected one of "
                         f"{sorted(MODE_VALUES)}. This is hard-rejected precisely because the two "
                         "keys it absorbed both used to fail SILENTLY -- an unknown selection "
                         "landed on Intensity and an unknown objective on Ambiguity, so a typo'd "
                         "\"Off\" would have quietly ENABLED MS3.")
    rank_by = ps.get("rank_by", DEFAULT_RANK_BY)
    if rank_by not in RANK_BY_VALUES:
        rep.error("A16", f"precursor_selection.rank_by '{rank_by}' is not legal; expected one of "
                         f"{sorted(RANK_BY_VALUES)}")
    targeting = ps.get("targeting", "none")
    if targeting not in TARGETING_VALUES:
        rep.error("A16", f"precursor_selection.targeting '{targeting}' is not legal; expected one "
                         f"of {sorted(TARGETING_VALUES)}")

    tol = (cfg.get("deconvolution") or {}).get("tol")
    if not isinstance(tol, list) or len(tol) < 3:
        rep.error("A6", f"deconvolution.tol has {len(tol) if isinstance(tol, list) else 'no'} "
                        "entries; >=3 required -- Config materialises levels {1,2,3} "
                        "unconditionally and toleranceList() walks them positionally")

    # scan-config names: grammar and reserved words
    for name in add:
        if not SCAN_NAME_RE.match(name):
            rep.error("A5", f"scan-config name '{name}' in ms_settings.additional_ms2 is invalid; "
                            "names match ^[a-z][a-z0-9_]{0,31}$")
        elif name in RESERVED_SCAN_NAMES:
            rep.error("A5", f"'{name}' is a reserved word and cannot name a scan config. "
                            f"Reserved: {', '.join(sorted(RESERVED_SCAN_NAMES))}")

    # references resolve
    add_scans = ps.get("additional_scans") or []
    seen = set()
    for n in add_scans:
        if n in seen:
            rep.error("A4", f"precursor_selection.additional_scans lists '{n}' more than once")
        seen.add(n)
        if n not in add:
            rep.error("A4", f"precursor_selection.additional_scans references unknown MS2 scan "
                            f"config '{n}'. Known: {sorted(add) or '(none)'}")
    follow_refs = {}
    for sec in ("tagging", "quantification"):
        fus = (cfg.get(sec) or {}).get("follow_up_scan")
        if isinstance(fus, str) and fus:
            follow_refs[sec] = fus
            if fus not in add:
                rep.error("A4", f"{sec}.follow_up_scan references unknown MS2 scan config "
                                f"'{fus}'. Known: {sorted(add) or '(none)'}")

    if cfg.get("conditional_ms2") and "tagging" not in follow_refs:
        rep.error("A15", "conditional_ms2 is true but tagging.follow_up_scan is not set. Name an "
                         "ms_settings.additional_ms2 entry, or set conditional_ms2 to false.")

    seq = chz.get("protein_sequence", "")
    if mode != "off" and not seq:
        rep.error("A7", "characterization.mode is not \"off\" but characterization.protein_sequence "
                        "is empty. MS3 characterization matches fragments against that sequence.")
    if mode != "off" and not isinstance(ms.get("ms3"), dict):
        rep.error("A8", f"characterization.mode is \"{mode}\" but ms_settings.ms3 is not defined. "
                        "This is the direction that SEGFAULTS: Exploration::initiateNextLevel "
                        "reads next_cfg.scans[0] unguarded.")
    if rank_by != "none" and not isinstance(ms.get("ms2"), dict):
        rep.error("A9", "precursor_selection.rank_by is not \"none\" but ms_settings.ms2 is not "
                        "defined -- MS2 has nowhere to dispatch into.")

    # activation coupling, at every scan site the engine checks
    checked_sites = {p for p, _ in roster(cfg, 1) + roster(cfg, 2) + roster(cfg, 3)}
    checked_sites |= {f"ms_settings.additional_ms2.{n}" for n in follow_refs.values() if n in add}
    for site, scan in scan_defs(cfg):
        if site not in checked_sites:
            continue  # an unreferenced definition never fires; that is B1's problem
        act = scan.get("activation", "")
        if act in NEEDS_CE and not (scan.get("collision_energy") or 0) > 0:
            rep.error("A13", f"{site} activation '{act}' requires collision_energy > 0")
        if act in NEEDS_RT and not (scan.get("reaction_time") or 0) > 0:
            rep.error("A13", f"{site} activation '{act}' requires reaction_time > 0")

    for sect, lvl, expl in explorations(cfg):
        metric = expl.get("metric", "none")
        if metric not in METRIC_VALUES:
            rep.error("A16", f"{sect}.exploration.metric '{metric}' is not legal; expected one of "
                             f"{sorted(METRIC_VALUES)}")
            continue
        if metric == "none":
            continue
        n = len(roster(cfg, lvl))
        if n != 1:
            rep.error("A10", f"{sect}.exploration is enabled, so level {lvl} must dispatch exactly "
                             f"one scan config; it dispatches {n}. A CE/RT sweep varies ONE base "
                             "scan config. Remove entries from precursor_selection.additional_scans.")
        if metric == "fragment_count" and not seq:
            rep.error("A11", f"{sect}.exploration.metric 'fragment_count' requires a non-empty "
                             "characterization.protein_sequence")
        if (expl.get("ce_step", 5) or 0) <= 0:
            rep.error("A12", f"{sect}.exploration.ce_step is {expl.get('ce_step')}; must be > 0. "
                             "A non-positive step never terminates the sweep loop -- it spins "
                             "forever INSIDE processScan, on the C# ActionBlock thread.")
        rt_min, rt_max = expl.get("reaction_time_min", 0), expl.get("reaction_time_max", 0)
        if rt_max > rt_min and (expl.get("reaction_time_step", 1) or 0) <= 0:
            rep.error("A12", f"{sect}.exploration.reaction_time_step is "
                             f"{expl.get('reaction_time_step')}; must be > 0 when a range is set")
        acts = expl.get("activations") or []
        if not acts:
            base = roster(cfg, lvl)
            acts = [base[0][1].get("activation", "")] if base else []
        for a in acts:
            if a in NEEDS_CE and expl.get("ce_max", 40) <= expl.get("ce_min", 20):
                rep.error("A14", f"{sect}.exploration activation '{a}' requires ce_min < ce_max "
                                 f"({expl.get('ce_min')} >= {expl.get('ce_max')})")
            if a in NEEDS_RT and rt_max <= rt_min:
                rep.error("A14", f"{sect}.exploration activation '{a}' requires "
                                 f"reaction_time_min < reaction_time_max ({rt_min} >= {rt_max})")

    # ---------------- CLASS B : the engine stays silent -------------------
    referenced = set(add_scans) | set(follow_refs.values())
    for name in add:
        if name not in referenced:
            rep.warn("B1", f"ms_settings.additional_ms2.{name} is defined but never referenced; it "
                           "will never be acquired. (The engine prints [CONFIG-WARN] and loads.) "
                           "This is the only check that catches a typo on the DEFINITION side.")

    both = set(add_scans) & set(follow_refs.values())
    for name in sorted(both):
        who = [s for s, v in follow_refs.items() if v == name]
        rep.warn("B7", f"ms_settings.additional_ms2.{name} is in precursor_selection."
                       f"additional_scans AND is {'/'.join(who)}.follow_up_scan, so it fires "
                       "UNCONDITIONALLY once per precursor and again as a conditional follow-up. "
                       "additional_ms2 is one flat namespace serving two roles and nothing "
                       "currently separates them.")

    if chz.get("max_targets", DEFAULT_MAX_TARGETS) == 0 and mode != "off":
        rep.warn("B2", "characterization.max_targets is 0 -- planNextScans returns no targets for "
                       "every precursor. A silent, total MS3 kill switch that leaves mode looking on.")

    # min_target_mass is read by ONE branch. Set anywhere else it loads clean, crosses the bridge
    # (ToCppJson emits every scalar unconditionally) and is never consulted -- textbook CLASS B.
    if chz.get("min_target_mass", 0) and mode != "exhaustive":
        rep.warn("B8", f"characterization.min_target_mass is {chz['min_target_mass']} but "
                       f"characterization.mode is \"{mode}\". The floor is consulted only by the "
                       "exhaustive pool builder (ADR-0023 decision 9), so here it is parsed, "
                       "emitted across the bridge, and ignored. It is NOT a second "
                       "deconvolution.min_mass -- that floor does not reach MSn output at all.")

    ref_scan_keys = set(ref["ms_settings"]["ms2"].keys())
    for sect, lvl, expl in explorations(cfg):
        metric = expl.get("metric", "none")
        ov = expl.get("overrides") or {}
        if metric == "none":
            sweepish = {"ce_min", "ce_max", "ce_step", "reaction_time_min", "reaction_time_max",
                        "reaction_time_step", "activations", "overrides",
                        "tolerance_ppm"} & {k for k in expl if expl[k] not in (None, [], {})}
            if sweepish:
                rep.warn("B3", f"{sect}.exploration.metric is 'none' but {sorted(sweepish)} are "
                               "set -- ToJsonExploration takes the else branch and emits the "
                               "defaults 20/40/5; your values never cross the bridge.")
        if "tolerance_ppm" in ov:
            rep.warn("B5", f"{sect}.exploration.overrides['tolerance_ppm'] is a MIGRATION LEFTOVER. "
                           "tolerance_ppm is a first-class exploration key now. overrides is exempt "
                           "from key validation and applyOverrides has no trailing else, so this is "
                           "accepted, dropped without a word, and the tolerance silently reverts to "
                           f"deconvolution.tol[{lvl - 1}].")
        for k in ov:
            if k not in ref_scan_keys and k != "tolerance_ppm":
                rep.warn("B4", f"{sect}.exploration.overrides['{k}'] is not one of the 17 scan keys "
                               "-- applyOverrides has no trailing else, so it is dropped silently")
        for k, v in ov.items():
            if not isinstance(v, str):
                rep.warn("B4", f"{sect}.exploration.overrides['{k}'] is {type(v).__name__}, not a "
                               "string. Override VALUES must be JSON strings; a bare 30 throws an "
                               "nlohmann type_error, \"30\" works.")

    for site, scan in scan_defs(cfg):
        if site == "ms_settings.ms1":
            continue
        zeros = [k for k in SOURCE_REGION if scan.get(k) == 0]
        if zeros:
            rep.warn("B6", f"{site} sets {zeros} to 0, which means INHERIT the survey value "
                           "(ADR-0011), not 'off'. An explicit 0 is unrepresentable here.")

    if mode == "off":
        dead = []
        if isinstance(ms.get("ms3"), dict):
            dead.append("ms_settings.ms3")
        if seq:
            dead.append("characterization.protein_sequence")
        if dead:
            rep.note(f"mode is \"off\", so {', '.join(dead)} is carried but never read. Legal "
                     "(ADR-0013 keeps it optional rather than forbidden) -- just dead weight.")

    if mode == "exhaustive":
        floor = chz.get("min_target_mass", 0)
        rep.note("exhaustive: MS3 targets are EVERY deconvolved mass of the winner MS2 scan, not "
                 "only the ones that mapped to the winning proteoform (ADR-0023). Pool filters: "
                 f"min_target_mass={floor}{' (off)' if not floor else ' Da'}, "
                 f"min_fragment_charge={chz.get('min_fragment_charge', 0)}"
                 f"{' (off)' if not chz.get('min_fragment_charge', 0) else ''}. max_targets bounds "
                 "TARGETS, not commands -- a CE sweep or fragment_charges multiplies on top of it.")

    cv = (cfg.get("faims") or {}).get("cv_values")
    if isinstance(cv, list):
        state = "OFF" if not cv else ("ON, fixed CV" if len(cv) == 1 else f"ON, cycling {len(cv)} CVs")
        rep.note(f"FAIMS: {state} (ADR-0012)")

    # ---------------- the headline verdict --------------------------------
    # One key. That is the entire point of the reshape: it used to take five facts
    # across three sections in two languages to answer this.
    verdict = {
        "ms3_on": mode != "off",
        "mode": mode,
        "mode_stated": "mode" in chz,
        "budget": chz.get("max_targets", DEFAULT_MAX_TARGETS),
        "budget_stated": "max_targets" in chz,
        "precursors": ps.get("max_precursors", 1),
        "roster2": [p for p, _ in roster(cfg, 2)],
    }
    return rep, verdict


def emit(rep, verdict):
    name = os.path.basename(rep.path)
    print(f"\n=== {name}")
    if verdict:
        if verdict["ms3_on"]:
            src = "stated" if verdict["budget_stated"] else "DEFAULTED"
            print(f"  MS3: ON   mode={verdict['mode']}   budget={verdict['budget']} [{src}]")
        else:
            print("  MS3: OFF  because characterization.mode == \"off\""
                  + ("" if verdict["mode_stated"] else " [DEFAULTED]"))
        print(f"  MS2: {verdict['precursors']} precursor(s) x {len(verdict['roster2'])} scan "
              f"config(s) {verdict['roster2']}")
    for code, msg in rep.errors:
        print(f"  [ERROR {code}] {msg}")
    for code, msg in rep.warns:
        print(f"  [WARN  {code}] {msg}")
    for msg in rep.info:
        print(f"  [info] {msg}")
    if not rep.errors and not rep.warns:
        print("  clean")


def main(argv):
    with open(REFERENCE, encoding="utf-8") as fh:
        ref = json.load(fh)
    if argv and argv[0] == "--all":
        paths = sorted(glob.glob(os.path.join(CONFIG_DIR, "*.json")))
        paths.append(os.path.join(REPO, "FlashIDA", "src", "Flash", "etc", "method.json"))
    else:
        paths = argv
    if not paths:
        print(__doc__)
        return 2
    failed = 0
    for p in paths:
        rep, verdict = validate(p, ref)
        emit(rep, verdict)
        if rep.errors:
            failed += 1
    print(f"\n{len(paths)} config(s) checked, {failed} with CLASS A errors")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

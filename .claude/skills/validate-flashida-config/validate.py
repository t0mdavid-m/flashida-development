#!/usr/bin/env python3
"""Validate a FLASHIda method.json against the current (pre-reshape) schema.

Two check classes, and the distinction is the whole point:

  CLASS A  the engine would THROW at Config::validate() -- we just find out in
           200 ms instead of after a failed acquisition.
  CLASS B  the engine stays SILENT. These are the config states that load clean,
           run green, and do nothing. There is no other tool for these.

Usage:
    python validate.py <config.json> [more.json ...]
    python validate.py --all                      # every committed config
Exit code 1 if any CLASS A error is found, else 0.
"""
import json
import sys
import os
import glob

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REFERENCE = os.path.join(REPO, "FlashIDA", "test-data", "config_schema_reference.json")
CONFIG_DIR = os.path.join(REPO, "FlashIDA", "test-data", "configs")

# --- values the engine accepts, from the code (NOT the doc comments) ----------
SELECTION_VALUES = {"intensity", "qscore", "none", "terminal_fragments", "ambiguity_resolution"}
METRIC_VALUES = {"mass_count", "remaining_precursor", "fragment_count"}
OBJECTIVE_VALUES = {"ambiguity", "coverage"}
# Config.cpp:107-114 -- ordinal, case-sensitive
NEEDS_CE = {"HCD", "CID", "EThcD"}
NEEDS_RT = {"ETD", "EThcD"}
# ADR-0011 source-region parameters: 0 means "inherit the survey's value"
SOURCE_REGION = ("rf_lens", "source_cid", "source_cid_scaling")

# C# property initialisers -- the EFFECTIVE defaults, because ToCppJson emits
# every key unconditionally so the C++ .value(key, default) fallbacks are dead.
CS_DEFAULTS = {
    "ms1": {"selection": "qscore", "max_targets": 10, "min_charge": 0},
    "ms2": {"selection": "intensity", "max_targets": 3, "min_charge": 0},
    "ms3": {"selection": "none", "max_targets": 3, "min_charge": 0},
}
DEFAULT_OBJECTIVE = "ambiguity"


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


def scan_sites(cfg):
    """Every (path, scan_object) in the config. Five sites in today's schema."""
    ms = cfg.get("ms_settings") or {}
    out = []
    if isinstance(ms.get("ms1"), dict):
        out.append(("ms_settings.ms1", ms["ms1"]))
    for lvl in ("ms2", "ms3"):
        v = ms.get(lvl)
        if isinstance(v, list):
            for i, s in enumerate(v):
                if isinstance(s, dict):
                    out.append((f"ms_settings.{lvl}[{i}]", s))
    for sec in ("tagging", "quantification"):
        fus = (cfg.get(sec) or {}).get("follow_up_scan")
        if isinstance(fus, dict):
            out.append((f"{sec}.follow_up_scan", fus))
    return out


def level_cfg(cfg, lvl):
    """selection_strategy.msN merged over the C# defaults."""
    ss = cfg.get("selection_strategy") or {}
    got = ss.get(lvl) or {}
    merged = dict(CS_DEFAULTS[lvl])
    merged.update({k: v for k, v in got.items() if k != "exploration"})
    merged["exploration"] = got.get("exploration")
    merged["_stated"] = got
    return merged


def check_unknown_keys(cfg, ref, rep):
    """Recursive allowlist check. exploration.overrides is exempt (dynamic map)."""

    def walk(node, refnode, path):
        if not isinstance(node, dict) or not isinstance(refnode, dict):
            return
        if path.endswith(".exploration.overrides"):
            return  # dynamic string->string map, deliberately unvalidated
        for k, v in node.items():
            if k not in refnode:
                rep.error("A3", f"unknown key '{path + '.' if path else ''}{k}'")
                continue
            rv = refnode[k]
            if isinstance(v, dict) and isinstance(rv, dict):
                walk(v, rv, f"{path}.{k}" if path else k)
            elif isinstance(v, list) and isinstance(rv, list) and rv and isinstance(rv[0], dict):
                for i, item in enumerate(v):
                    walk(item, rv[0], f"{path}.{k}[{i}]" if path else f"{k}[{i}]")

    walk(cfg, ref, "")


def validate(path, ref):
    rep = Report(path)
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:
        rep.error("A1", f"invalid JSON: {exc}")
        return rep, None

    # ---------------- CLASS A : the engine would throw --------------------
    check_unknown_keys(cfg, ref, rep)

    if "selection_strategy" not in cfg:
        rep.error("A4", "'selection_strategy' is missing -- Config.cpp:389 throws "
                        "std::runtime_error (the only non-invalid_argument config error)")

    tol = (cfg.get("deconvolution") or {}).get("tol")
    if not isinstance(tol, list) or len(tol) < 3:
        rep.error("A5", f"deconvolution.tol has {len(tol) if isinstance(tol, list) else 'no'} "
                        "entries; >=3 required -- BuildSelectionStrategy always materialises "
                        "levels {1,2,3} (Config.cpp:464)")

    chz = cfg.get("characterization") or {}
    seq = chz.get("protein_sequence", "")
    for lvl in ("ms2", "ms3"):
        if level_cfg(cfg, lvl)["selection"] != "none" and not seq:
            rep.error("A6", f"selection_strategy.{lvl}.selection is "
                            f"'{level_cfg(cfg, lvl)['selection']}' but "
                            "characterization.protein_sequence is empty (Config.cpp:557)")
            break

    for site, scan in scan_sites(cfg):
        act = scan.get("activation", "")
        if act in NEEDS_CE and not (scan.get("collision_energy") or 0) > 0:
            rep.error("A7", f"{site} activation '{act}' requires collision_energy > 0 "
                            "(Config.cpp:526)")
        if act in NEEDS_RT and not (scan.get("reaction_time") or 0) > 0:
            rep.error("A7", f"{site} activation '{act}' requires reaction_time > 0 "
                            "(Config.cpp:523)")

    ms = cfg.get("ms_settings") or {}
    for lvl, nxt in (("ms1", "ms2"), ("ms2", "ms3")):
        if level_cfg(cfg, lvl)["selection"] != "none" and not (ms.get(nxt) or []):
            rep.error("A8", f"selection_strategy.{lvl}.selection targets {nxt.upper()} but "
                            f"ms_settings.{nxt} is empty (Config.cpp:567)")

    for lvl in ("ms2", "ms3"):
        expl = level_cfg(cfg, lvl)["exploration"] or {}
        metric = expl.get("metric", "none")
        if metric != "none":
            n = len(ms.get(lvl) or [])
            if n != 1:
                rep.error("A9", f"exploration is active at {lvl} so ms_settings.{lvl} must have "
                                f"exactly 1 scan config, got {n} (Config.cpp:540)")
            if metric == "fragment_count" and not seq:
                rep.error("A10", f"{lvl}.exploration.metric 'fragment_count' requires a non-empty "
                                 "characterization.protein_sequence (Config.cpp:549)")
            acts = expl.get("activations") or []
            if any(a in NEEDS_CE for a in acts) or not acts:
                if expl.get("ce_min", 20) >= expl.get("ce_max", 40):
                    rep.error("A11", f"{lvl}.exploration ce_min must be < ce_max "
                                     f"({expl.get('ce_min')} >= {expl.get('ce_max')})")
            if any(a in NEEDS_RT for a in acts):
                if expl.get("rt_min", 0) >= expl.get("rt_max", 0):
                    rep.error("A11", f"{lvl}.exploration sweeps an ETD-family activation but "
                                     f"rt_min ({expl.get('rt_min')}) >= rt_max ({expl.get('rt_max')})")

    # ---------------- CLASS B : the engine stays silent -------------------
    for lvl in ("ms2", "ms3"):
        expl = level_cfg(cfg, lvl)["exploration"] or {}
        metric = expl.get("metric", "none")
        if metric != "none":
            if expl.get("ce_step", 5) <= 0:
                rep.warn("B1", f"{lvl}.exploration.ce_step is {expl.get('ce_step')} -- "
                               "INFINITE LOOP inside processScan (Exploration.cpp:69). "
                               "Validated on neither side.")
            if expl.get("rt_max", 0) > expl.get("rt_min", 0) and expl.get("rt_step", 1) <= 0:
                rep.warn("B2", f"{lvl}.exploration.rt_step is {expl.get('rt_step')} -- "
                               "INFINITE LOOP (Exploration.cpp:73-77)")
            if metric not in METRIC_VALUES:
                rep.warn("B6", f"{lvl}.exploration.metric '{metric}' is not a legal value -- "
                               "fails CLOSED to None at Config.cpp:437, silently collapsing the "
                               f"sweep to a single {lvl.upper()}")
            ov = expl.get("overrides") or {}
            if set(ov) == {"tolerance_ppm"}:
                rep.warn("B8", f"{lvl}.exploration.overrides contains only tolerance_ppm, which "
                               "Config.cpp:476 ERASES before Exploration.cpp:605 tests the map for "
                               "emptiness -- the production scan is silently suppressed")
            ref_scan_keys = set(ref["ms_settings"]["ms2"][0].keys())
            for k in ov:
                if k not in ref_scan_keys and k != "tolerance_ppm":
                    rep.warn("B9", f"{lvl}.exploration.overrides['{k}'] is not one of the 17 scan "
                                   "keys -- applyOverrides has no trailing else, so it is dropped "
                                   "with no message (Config.cpp:141-163)")
        else:
            stated = (level_cfg(cfg, lvl)["_stated"].get("exploration") or {})
            sweepish = {"ce_min", "ce_max", "ce_step", "rt_min", "rt_max", "rt_step",
                        "activations", "overrides"} & set(stated)
            if sweepish:
                rep.warn("B7", f"{lvl}.exploration.metric is 'none' but {sorted(sweepish)} are set "
                               "-- MethodParameters.cs:302 takes the else branch and emits the "
                               "shared default 20/40/5; your values never cross the bridge")

    for lvl in ("ms1", "ms2", "ms3"):
        sel = level_cfg(cfg, lvl)["selection"]
        if sel not in SELECTION_VALUES:
            rep.warn("B6", f"selection_strategy.{lvl}.selection '{sel}' is not a legal value -- "
                           "Config.cpp:421 falls through to Intensity, so a typo ENABLES this level "
                           "rather than disabling it")

    obj = chz.get("objective")
    if obj is not None and obj not in OBJECTIVE_VALUES:
        rep.warn("B6", f"characterization.objective '{obj}' is not legal -- Config.cpp:285 is "
                       "`if (== \"coverage\") ... else Ambiguity`, so this silently means ambiguity")

    ms3_stated = level_cfg(cfg, "ms3")["_stated"]
    for dead in ("max_targets", "min_charge"):
        if dead in ms3_stated:
            rep.warn("B3", f"selection_strategy.ms3.{dead} = {ms3_stated[dead]} is DEAD -- parsed, "
                           f"emitted, never read. The live key is selection_strategy.ms2.{dead}")

    ms2c = level_cfg(cfg, "ms2")
    if ms2c["max_targets"] == 0:
        rep.warn("B5", "selection_strategy.ms2.max_targets is 0 -- ProteoformTracker.cpp:355 "
                       "returns no targets for every precursor. Silent, total MS3 kill switch.")

    for site, scan in scan_sites(cfg):
        if site == "ms_settings.ms1":
            continue
        zeros = [k for k in SOURCE_REGION if scan.get(k) == 0]
        if zeros:
            rep.warn("B10", f"{site} sets {zeros} to 0, which means INHERIT the survey value "
                            "(ADR-0011), not 'off'. An explicit 0 is unrepresentable here.")

    if len(ms.get("ms3") or []) > 1:
        rep.warn("B12", f"ms_settings.ms3 has {len(ms['ms3'])} entries; every level-3 consumer "
                        "indexes [0] (Exploration.cpp:799), so entries past the first are "
                        "parsed, validated and unreachable")

    cv = (cfg.get("faims") or {}).get("cv_values")
    if isinstance(cv, list):
        state = "OFF" if not cv else ("ON, fixed CV" if len(cv) == 1 else f"ON, cycling {len(cv)} CVs")
        rep.note(f"FAIMS: {state} (ADR-0012)")

    # ---------------- the headline verdict --------------------------------
    reasons = []
    if level_cfg(cfg, "ms1")["selection"] == "none":
        reasons.append("selection_strategy.ms1.selection == 'none' (FLASHIda.cpp:168)")
    if level_cfg(cfg, "ms2")["selection"] == "none":
        reasons.append("selection_strategy.ms2.selection == 'none' (Exploration.cpp:728)")
    if level_cfg(cfg, "ms3")["selection"] == "none":
        reasons.append("selection_strategy.ms3.selection == 'none' (Exploration.cpp:730)")
    if not (ms.get("ms3") or []):
        reasons.append("ms_settings.ms3 is empty (Exploration.cpp:729)")
    if not seq:
        reasons.append("characterization.protein_sequence is empty")
    if ms2c["max_targets"] == 0:
        reasons.append("selection_strategy.ms2.max_targets == 0")

    verdict = {
        "ms3_on": not reasons,
        "reasons": reasons,
        "budget": ms2c["max_targets"],
        "budget_stated": "max_targets" in ms2c["_stated"],
        "objective": chz.get("objective", DEFAULT_OBJECTIVE),
        "objective_stated": "objective" in chz,
    }
    return rep, verdict


def emit(rep, verdict):
    name = os.path.basename(rep.path)
    print(f"\n=== {name}")
    if verdict:
        if verdict["ms3_on"]:
            src = "stated" if verdict["budget_stated"] else "DEFAULTED"
            osrc = "stated" if verdict["objective_stated"] else "DEFAULTED (silently)"
            print(f"  MS3: ON   objective={verdict['objective']} [{osrc}]   "
                  f"budget={verdict['budget']} [{src}]")
        else:
            print("  MS3: OFF")
            for r in verdict["reasons"]:
                print(f"        because {r}")
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

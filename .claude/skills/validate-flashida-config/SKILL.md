---
name: validate-flashida-config
description: Validate a FLASHIda method.json before running it. Answers "will MS3 actually fire, and if not why not", reports the EFFECTIVE MS3 budget and the MS2 dispatch roster, reproduces every Config::validate() throw including the migration errors for the old selection_strategy schema, and flags the config states the engine accepts silently and then ignores. Use when authoring or reviewing a method config, when a run produced no MS3, when a config change is about to be pushed, or when migrating configs.
---

# Validate a FLASHIda config

```bash
uv run --quiet python .claude/skills/validate-flashida-config/validate.py <config.json>
uv run --quiet python .claude/skills/validate-flashida-config/validate.py --all   # all 34 committed
```

No build, no DLLs, no instrument. Pure JSON analysis, ~200 ms. Exit 1 if any CLASS A error.

Schema: the two-decision-section shape (ADR-0013 `characterization.mode`, ADR-0014 the
`precursor_selection` / `characterization` split and named scan configs).

## Why this exists

Two failure modes motivated it, and they need opposite treatment:

- **The engine throws.** Fine — but you find out at acquisition time, after a build. Class A
  reproduces `Config::validate()` so you find out now.
- **The engine says nothing.** A config loads clean, runs green, and fires zero MS3. There is no
  other tool for this, and it is the reason the skill exists.

The headline is now one line, because one key decides it:

```
=== method_dda_hcd.json
  MS3: OFF  because characterization.mode == "off"
  MS2: 1 precursor(s) x 1 scan config(s) ['ms_settings.ms2']

=== method_exploration_followup.json
  MS3: ON   mode=ambiguity   budget=3 [stated]
  MS2: 1 precursor(s) x 2 scan config(s) ['ms_settings.ms2', 'ms_settings.additional_ms2.secondary']
```

Before the reshape that first line took **five facts across three sections in two languages**, and
two of them lived under a level you were not configuring.

## What it checks

### Class A — the engine would throw

| Code | Check |
|---|---|
| A1 | JSON parses |
| A2 | **migration**: `selection_strategy` or a top-level `ms3` present; `ms_settings.ms2`/`ms3` still arrays; a `follow_up_scan` still an inline object. Reported alone — the rest of the checks read the new shape, and running them on an old file just produces a second confusing wall |
| A3 | no unknown keys, recursively, against the generated `config_schema_reference.json` |
| A4 | every `additional_scans` / `follow_up_scan` name resolves, and `additional_scans` has no duplicate |
| A5 | scan-config names match `^[a-z][a-z0-9_]{0,31}$` and avoid the reserved words `ms1 ms2 ms3 none off all` |
| A6 | `deconvolution.tol` has ≥ 3 entries — levels {1,2,3} are always materialised |
| A7 | `mode != off` ⇒ `characterization.protein_sequence` non-empty |
| A8 | `mode != off` ⇒ `ms_settings.ms3` defined. **The direction that segfaults** — `initiateNextLevel` reads `scans[0]` unguarded |
| A9 | `rank_by != none` ⇒ `ms_settings.ms2` defined |
| A10 | exploration active ⇒ that level dispatches exactly one scan config |
| A11 | `fragment_count` requires a protein sequence |
| A12 | `ce_step > 0`, and `reaction_time_step > 0` when a reaction-time range is set |
| A13 | activation coupling at every **dispatched** scan site: HCD/CID/EThcD need `collision_energy > 0`, ETD/EThcD need `reaction_time > 0` |
| A14 | `ce_min < ce_max`, and `reaction_time_min < reaction_time_max` when an ETD-family activation is swept |
| A15 | `conditional_ms2: true` ⇒ `tagging.follow_up_scan` names something |
| A16 | `mode`, `rank_by`, `targeting`, `metric` are legal values |

### Class B — the engine stays silent

| Code | Check | Consequence if hit |
|---|---|---|
| B1 | an `additional_ms2` entry nobody references | never acquired. The engine prints `[CONFIG-WARN]` and loads. The only check that catches a typo on the **definition** side |
| B2 | `characterization.max_targets == 0` with `mode != off` | silent, total MS3 kill switch that leaves `mode` looking on |
| B3 | `metric: "none"` with sweep values set | values silently replaced by the 20/40/5 default; yours never cross the bridge |
| B4 | `overrides` key outside the 17 scan keys, or a non-string value | unknown keys dropped with no message; a bare `30` throws an nlohmann `type_error` where `"30"` works |
| B5 | `overrides["tolerance_ppm"]` | a **migration leftover**. It is a first-class exploration key now; left in the map it is accepted, dropped silently, and the tolerance reverts to `deconvolution.tol[level-1]` |
| B6 | source-region parameter explicitly `0` on an MSn scan | means *inherit the survey*, not *off* (ADR-0011) |
| B7 | a name in **both** `additional_scans` and a `follow_up_scan` | fires unconditionally per precursor **and** as a conditional follow-up. `additional_ms2` is one flat namespace serving two roles and nothing separates them |

It also reports FAIMS state, since `cv_values` emptiness is the switch (ADR-0012): `[]` off, one CV
fixed, ≥ 2 cycling; and notes when `mode: off` leaves an `ms_settings.ms3` block or a
`protein_sequence` as dead weight (legal — ADR-0013 keeps them optional rather than forbidden).

### What moved out of Class B, and why that is the point

The reshape's success measure is how much of Class B became Class A:

| Was silent | Now |
|---|---|
| unknown `selection` | **A16.** It used to fail *open* — a typo *enabled* the level |
| unknown `metric` | **A16.** It used to fail *closed* — a typo *disabled* the sweep |
| unknown `objective` | **A16**, folded into `mode`. `"Coverage"` used to silently mean ambiguity, and with `mode` carrying the on/off bit a typo'd `"Off"` would have silently enabled MS3 |
| `ce_step <= 0` | **A12.** Used to be an infinite loop inside `processScan`, on the C# ActionBlock thread — a hang, not an error |
| `ms3.max_targets` set | **A3.** The dead key four configs set to 200 while running 3. Deleted, so it is now simply unknown |
| `ms_settings.ms3[1..N]` | **A2.** `ms3` is a bare object; there is no second slot to be unreachable |
| `overrides` = only `tolerance_ppm` | **B5**, and no longer a scan-suppressor: `tolerance_ppm` is promoted out of the map, so the emptiness test stops lying |

## Interpreting the output

- **A CLASS A error means the config will not load.** Fix before anything else.
- **`budget=N [DEFAULTED]`** means `characterization.max_targets` is absent and you are getting the
  C# default of 3. Hand-written **C++ test fixtures** bypass the emitter and get the C++ literal
  **10** instead — so a fixture that omits the key silently runs a different budget than a
  `method.json` that omits it.
- **The `MS2:` line is the dispatch roster, in dispatch order.** It is built from the reference
  array, never from map iteration — `nlohmann`'s `object_t` is a `std::map`, so walking
  `additional_ms2` would sort the names alphabetically and silently reorder dispatch.
- **Zero Class A errors across all 34 committed configs** is the baseline. Any error there is either
  a bug in this script or a stale reference — see below.

## Maintenance

The allowlist comes from `FlashIDA/test-data/config_schema_reference.json`, which is **generated**
from the C# schema by `ConfigSchemaParityTests.Reference_IsNeverStale`. It must be regenerated, never
hand-edited.

**If A3 reports unknown keys on committed configs, suspect the reference before the config.** A
stale reference makes every config using a newly added key look broken — that is exactly what
happened when the reshape added `characterization.exploration`,
`precursor_selection.additional_scans` and `precursor_selection.exploration.overrides`: six
committed configs went red against a reference that predated them. A local build cannot regenerate
it (no restored packages, no net48 reference assemblies, encrypted Thermo DLLs), so CI does it: the
`Capture config schema reference` step runs the test with `REGEN_CONFIG_REFERENCE=1` **after** the
unfiltered suite and uploads artifact `config-schema-reference-capture`. Promote that file.

The behavioural checks are keyed to code anchors named in the messages; if one stops resolving, the
check is stale and must be re-derived, not trusted.

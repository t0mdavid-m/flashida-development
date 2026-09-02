---
name: validate-flashida-config
description: Validate a FLASHIda method.json before running it. Answers "will MS3 actually fire, and if not why not", reports the EFFECTIVE MS3 budget and the MS2 dispatch roster, reproduces every Config::validate() throw including the migration errors for the old selection_strategy schema, and flags the config states the engine accepts silently and then ignores. Use when authoring or reviewing a method config, when a run produced no MS3, when a config change is about to be pushed, or when migrating configs.
---

# Validate a FLASHIda config

```bash
uv run --quiet python .claude/skills/validate-flashida-config/validate.py <config.json>
uv run --quiet python .claude/skills/validate-flashida-config/validate.py --all   # all 42: the 41 in test-data/configs + src/Flash/etc/method.json
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

=== method_quant.json
  MS3: OFF  because characterization.mode == "off"
  MS2: 1 precursor(s) x 1 scan config(s) ['ms_settings.ms2_quant']
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
| A17 | `metric: "remaining_precursor"` with an absent or empty `overrides` map. Such a sweep scans only the ~2 Th window it reads and always throws its pre-scans away, so it must declare what they run at — the **static form of ADR-0020 gate #1** (ADR-0026 decision 3) |
| A18 | `metric: "remaining_precursor"` paired with `"multiplexed"` **at the same level** — `precursor_charges` for the `precursor_selection` block, `fragment_charges` for the `characterization` one. A notch set is not one interval, and a bound pre-scan has only one. Two level-matched checks, not one "multiplexed anywhere" test: `separate` and the **cross-level** pair both stay legal (ADR-0026 decision 4) |
| A19 | `quantification.enabled` without `ms_settings.ms2_quant`. **The direction that quietly does nothing** — with no quantification scan the roster falls back to `ms2`, so the run is plain DDA that measures nothing and buys nothing (ADR-0038) |
| A20 | `quantification.conditions` is not **exactly two**. `fold_change = mean(conditions[0]) / mean(conditions[1])` is a two-group ratio, and the array **order is the direction**; a time course needs a different statistic, not the first two groups |
| A21 | `quantification.enabled` together with `precursor_selection.exploration`. Incompatible by construction: exploration replaces the level-2 roster with CE-sweep variants, so the quantification scan is never dispatched — and A10 does **not** catch it, because the inverted roster does have exactly one entry |
| A22 | unknown `quantification.labelling`. The seven OpenMS schemes only; `"none"` is deliberately not among them, since `enabled` is the switch |
| A23 | `quantification.enabled` without `ms_settings.ms2`. The scan the screen **buys** — absent, the engine builds it from a default-constructed `ScanConfig`, and the pre-existing "rank_by is not none but ms2 is not defined" guard cannot catch it because it reads the roster, which a quant config fills with the `'Q'` scan (ADR-0039). Required even under `identify: "none"`, where it is inert, so flipping the objective never invalidates a config |
| A24 | unknown `quantification.identify`. `differential` \| `quantified` \| `all` \| `none`, case-sensitive (ADR-0039). `"off"` is `characterization.mode`'s spelling and is **not** accepted — `enabled` is the switch |
| A25 | a `quantification.conditions` entry **named** `"either"`. That is `enriched_in`'s sentinel for "either direction", so the name would make the key ambiguous |
| A26 | `quantification.enriched_in` names no authored condition. It names a **condition**, never a direction — `fold_change = mean(conditions[0]) / mean(conditions[1])`, so `"up"` would mean "enriched in whichever condition is listed first" and would invert if the array were reordered |

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
| B8 | `characterization.min_target_mass` set with `mode != "exhaustive"` | parsed, emitted across the bridge, and never consulted — only the exhaustive pool builder reads it (ADR-0023 decision 9). It is **not** a second `deconvolution.min_mass`; that floor does not reach MSn output at all |
| B10 | `quantification.enriched_in` set while `quantification.identify` is not `"differential"` | authored, bound, and **inert**: direction restricts only the differential objective. The engine loads it and prints `[CONFIG-WARN]` rather than rejecting — deliberately, so a template that sets the direction once stays valid across every `identify` value (ADR-0039, applying ADR-0013's `ms_settings.ms3` rule). Warned, never an error |
| B9 | `ms_settings.ms2_quant.first_mass` above the labelling scheme's lowest reporter ion | the quantification scan cannot contain a reporter ion, so every spectrum returns `extraction_failed`, no identification scan is ever bought, and the run degrades to plain DDA. Checked per scheme (`itraq8plex` 113.108, `itraq4plex` 114.111, every TMT 126.128); `first_mass: 0` means "instrument default" (ADR-0011) and is skipped. Gated on `ms2_quant` **existing**, not on `enabled`, so the trap is named before the switch is flipped |

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
- **With quantification enabled the roster shows `ms_settings.ms2_quant`, not `ms2`** — that is
  ADR-0038 working, not a missing scan. The quantification scan is the screen and holds the
  unconditional slot; `ms_settings.ms2` becomes the identification scan the verdict
  buys, so it is off the roster by design and fires per *verdict* rather than per precursor.
  **Which verdicts buy is `quantification.identify`** (ADR-0039) — `differential` (default) |
  `quantified` | `all` | `none` — refined for the differential case by `quantification.enriched_in`,
  which names the **condition** a species must be enriched in, not a direction. Under
  `identify: "none"` nothing is ever bought and `ms_settings.ms2` is required but inert.
- **Zero Class A errors across the 42 configs `--all` walks** is the baseline — the 41 in
  `FlashIDA/test-data/configs/` plus the shipped `FlashIDA/src/Flash/etc/method.json`, which is in
  the sweep precisely because it is the one config nobody diffs against a golden. Any error there is
  either a bug in this script or a stale reference — see below.

## Maintenance

The allowlist comes from `FlashIDA/test-data/config_schema_reference.json`, which is **generated**
from the C# schema by `ConfigSchemaParityTests.Reference_IsNeverStale`. It must be regenerated, never
hand-edited.

**If A3 reports unknown keys on committed configs, suspect the reference before the config.** A
stale reference makes every config using a newly added key look broken — that is exactly what
happened when the reshape added `characterization.exploration`,
`precursor_selection.additional_scans` and `precursor_selection.exploration.overrides`: six
committed configs went red against a reference that predated them. The Windows container regenerates
it directly (`REGEN_CONFIG_REFERENCE=1`, opt-in, default OFF); CI's `Capture config schema reference`
step and its `config-schema-reference-capture` artifact remain the fallback — promote that file.
**The ordering is load-bearing:** the regeneration must run **after** the unfiltered suite, or the
gate passes against its own output and the schema silently drifts. Note this file is **not** under
`test-data/golden`, so the golden write guard does not see it — widening the change detector to
cover it is deferred until the owner rules on whether the container may regenerate it at all.

The behavioural checks are keyed to code anchors named in the messages; if one stops resolving, the
check is stale and must be re-derived, not trusted.

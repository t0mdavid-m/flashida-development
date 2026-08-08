---
name: validate-flashida-config
description: Validate a FLASHIda method.json before running it. Answers "will MS3 actually fire, and if not why not", reports the EFFECTIVE MS3 budget and objective, reproduces every Config::validate() throw, and flags the config states the engine accepts silently and then ignores. Use when authoring or reviewing a method config, when a run produced no MS3, when a config change is about to be pushed, or when migrating configs.
---

# Validate a FLASHIda config

```bash
uv run --quiet python .claude/skills/validate-flashida-config/validate.py <config.json>
uv run --quiet python .claude/skills/validate-flashida-config/validate.py --all   # all 33 committed
```

No build, no DLLs, no instrument. Pure JSON analysis, ~200 ms. Exit 1 if any CLASS A error.

## Why this exists

Two failure modes motivated it, and they need opposite treatment:

- **The engine throws.** Fine — but you find out at acquisition time, after a build. Class A
  reproduces `Config::validate()` so you find out now.
- **The engine says nothing.** A config loads clean, runs green, and fires zero MS3. There is no
  other tool for this, and it is the reason the skill exists.

The headline line is the one that matters:

```
=== method_dda_hcd.json
  MS3: OFF
        because selection_strategy.ms3.selection == 'none' (Exploration.cpp:730)

=== method_ms3_cytc_real.json
  MS3: ON   objective=ambiguity [DEFAULTED (silently)]   budget=3 [DEFAULTED]
  [WARN  B3] selection_strategy.ms3.max_targets = 200 is DEAD -- parsed, emitted, never
             read. The live key is selection_strategy.ms2.max_targets
```

That second block is a real bug in a committed config: the file states a budget of **200** and the
engine spends **3**.

## What it checks

### Class A — the engine would throw

| Code | Check |
|---|---|
| A1 | JSON parses |
| A3 | no unknown keys, recursively, against the generated `config_schema_reference.json` |
| A4 | `selection_strategy` present (its absence is the one `std::runtime_error`) |
| A5 | `deconvolution.tol` has ≥ 3 entries — levels {1,2,3} are always materialised |
| A6 | `characterization.protein_sequence` non-empty when any level ≥ 2 selects |
| A7 | activation coupling at **all five** scan sites: HCD/CID/EThcD need `collision_energy > 0`, ETD/EThcD need `reaction_time > 0` |
| A8 | selection at level N with a non-empty `ms_settings.ms(N+1)` |
| A9 | exploration active ⇒ exactly one scan config at that level |
| A10 | `fragment_count` requires a protein sequence |
| A11 | `ce_min < ce_max`, and `rt_min < rt_max` when an ETD-family activation is swept |

### Class B — the engine stays silent

| Code | Check | Consequence if hit |
|---|---|---|
| B1/B2 | `ce_step <= 0`, `reaction_time_step <= 0` | **infinite loop inside `processScan`** on the C# ActionBlock thread. Validated on neither side |
| B3 | `selection_strategy.ms3.max_targets` / `.min_charge` set | dead keys — they would budget MS4 |
| B5 | `ms2.max_targets == 0` | silent, total MS3 kill switch |
| B6 | unknown enum value | `selection` fails **open** (a typo *enables* the level), `metric` fails **closed**, `objective` silently means ambiguity |
| B7 | `metric: "none"` with sweep values set | values silently replaced by the shared 20/40/5 default |
| B8 | `overrides` containing only `tolerance_ppm` | erased before the emptiness test → production scan suppressed |
| B9 | `overrides` key outside the 17 scan keys | dropped with no message |
| B10 | source-region parameter explicitly `0` on an MSn scan | means *inherit the survey*, not *off* (ADR-0011) |
| B12 | `ms_settings.ms3` with more than one entry | entries past `[0]` are unreachable |

It also reports FAIMS state, since `cv_values` emptiness is the switch (ADR-0012): `[]` off, one CV
fixed, ≥ 2 cycling.

## Interpreting the output

- **A CLASS A error means the config will not load.** Fix before anything else.
- **`[DEFAULTED (silently)]` on `objective`** is not an error, but it means the file does not say what
  it does. Prefer stating it.
- **`budget=N [DEFAULTED]`** means `selection_strategy.ms2.max_targets` is absent and you are getting
  the C# default. If the file also sets `ms3.max_targets`, someone believed they set the budget and
  did not.
- **Zero Class A errors across all 33 committed configs** is the baseline. Any error there is a bug
  in this script, not in the config.

## Maintenance

The allowlist comes from `FlashIDA/test-data/config_schema_reference.json`, which is **generated**
from the C# schema — so A3 can never go stale as long as the reference is regenerated rather than
hand-edited. The behavioural checks are keyed to code anchors named in the messages; if one stops
resolving, the check is stale and must be re-derived, not trusted.

**After the config reshape lands, Class B shrinks** — most of these become load-time throws. That
shrinkage is the measure of whether the reshape worked, so update this skill in the same commit.

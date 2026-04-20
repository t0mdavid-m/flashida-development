---
title: Exploration — Scoring and Winner Selection
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:240   # computeExplorationScore_ decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:248   # computeMassCount_ decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:716         # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:734         # FragmentCount inlined case
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:747         # computeMassCount_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:752         # computeRemainingPrecursorScore_ definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59         # ExplorationMetric enum
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
---

## `feedResult` flow

`Exploration::feedResult` (decl `Exploration.h:186`, def `Exploration.cpp:229`) is called by the orchestrator whenever a returning MS2/MS3 scan carries an exploration tracking ID (`isExplorationVariant(tracking_id)` is true). It routes via `variant_tracking_map_` to find `{group_id, variant_index}`, deconvolves the raw spectrum with the correct precursor context and the per-level `exploration_tolerance_ppm`, calls `computeExplorationScore_` (`Exploration.h:240`), stores the score on the variant, marks `received=true`, and tests whether all variants have `received=true` (via `std::all_of` — see `Exploration.cpp:~388`). Once all variants have been received, runs winner selection (see below). On MS3 with the `FragmentCount` metric, also triggers `MS3FragmentMatcher::calibrateAndScore` (see `ms3-exploration.md`).

## `computeExplorationScore_` dispatcher

A single `switch` at `Exploration.cpp:716` over `ExplorationMetric` (`Config.h:59`) with three cases plus a default fallback. All three cases first call `computeFragmentMatch_` (which populates match metadata used by downstream logging and metadata), then return a metric-specific score. Returns a `double`; higher is better.

## Per-metric scoring

- **`MassCount` — `computeMassCount_` (`Exploration.cpp:747`)**: counts deconvolved masses in the variant's spectrum (`spec.size()`). A spectral-richness proxy: more distinct masses = better fragmentation. Cheap; no reference needed.
- **`RemainingPrecursor` — `computeRemainingPrecursorScore_` (`Exploration.cpp:752`)**: computes `ratio = remaining_intensity / baseline_reference` in the isolation window, then `score = 1.0 - |ratio - remaining_precursor_target|`, where `remaining_precursor_target` is a per-level config value. Rewards matching the configured target depletion, not maximizing it — a ratio equal to the target scores `1.0`; both over- and under-depletion lose score. Returns four sentinel values on error: `0.0` (empty input), `-1.0` (baseline reference intensity ≤ 0), `-2.0` (baseline variant not yet received), `-3.0` (score clamped when it would be negative). The `out_ratio` out-parameter also carries `-1.0` when the ratio can't be computed.
- **`FragmentCount` — inlined (`Exploration.cpp:734-739`)**: no separate helper function. The dispatcher's case inlines `return static_cast<double>(fmr.total_match_count);` using the `FragmentMatchResult` produced by `computeFragmentMatch_`. On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (`Exploration.cpp:400`), which re-scores variants with calibrated per-variant fragment m/z tolerance **after** the initial winner is selected (see `ms3-exploration.md`).

## Winner selection

Inside `feedResult` (`Exploration.cpp:436-448`), once all variants have been received, a linear scan iterates the group's variants tracking `best_score` (seeded at `-1.0`) and `best_idx`. Baseline variants (`is_baseline==true`) are skipped. The comparator is strict `>` (`Exploration.cpp:441`), so on ties the lowest-index variant wins (first-seen keeps the slot); given the default CE-inner sweep, that means lowest CE wins ties. `group.winner_index` is recorded, `group.complete = true` is *set* here (`Exploration.cpp:449`), and the winner's result is flagged via `is_best_variant`. An `[EXPL-WINNER]` log line (`Exploration.cpp:452`) records `group_id`, `winner_idx`, activation, CE, RT, and score.

## `overrides` application

`MSLevelConfig::overrides` is a key-value map that `Exploration::initiate` applies to the variant sweep's **base config** via `base_config.applyOverrides(cfg.overrides)` (`Exploration.cpp:127`) — so every variant inherits the overrides, not just a winner. The map *also* gates whether a separate post-winner production scan is emitted at all: the branch at `Exploration.cpp:460` (`if (!level_config.overrides.empty())`) builds a fresh production `ScanCommand` from `level_config.scans[0]` with the winner's CE/RT/activation copied onto it; otherwise no post-winner production scan is enqueued. Net effect: overrides shape every variant, and their presence doubles as a flag to request an additional explicit production scan on top of the winner's variant scan.

## Gotchas

- **Score sentinel `-1.0`.** Un-received variants carry `-1.0`; do not treat this as a legitimate low score. Winner selection only runs after all variants have been received, so this matters only for mid-lifecycle inspection.
- **Metric preconditions.** `RemainingPrecursor` without a baseline is a configuration bug; `FragmentCount` on MS3 presumes fragment analysis is configured. `Config::validate()` catches obvious misconfigurations (`FragmentCount` specifically requires a non-empty `targeting_.protein_sequence`); the baseline for `RemainingPrecursor` is *not* validated — if it goes missing, the ratio can't be computed.
- **No per-group timeout.** Restated from `exploration.md`: a dropped variant leaves the group pending indefinitely; `feedResult` never fires the winner path.

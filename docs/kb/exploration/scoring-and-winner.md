---
title: Exploration — Scoring and Winner Selection
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-09-22
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:287   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:81    # ExplorationVariant::measured_only (ADR-0045)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:347   # last_result_deconvolved_ (ADR-0045)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:357         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:397         # measured_only = isTrapAnalyzer(cmd.analyzer)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:415         # feedResultImpl_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:771         # post-winner dispatch gate (ADR-0020)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1254        # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1285        # computeMassCount_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1290        # precursorWindowIntensity_ (the anchor-window sum)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1309        # computeRemainingPrecursorScore_ definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:87         # ExplorationMetric enum
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:138        # isKnownAnalyzer / isTrapAnalyzer (ADR-0045)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:1293             # trap sweep must use remaining_precursor
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
  - ../fragment-analysis/ms2-matching.md
  - ../fragment-analysis/ms3-matching.md
---

## `feedResult` flow

`Exploration::feedResult` (decl `Exploration.h:287`, def `Exploration.cpp:357`) is called by the orchestrator whenever a returning MS2/MS3 scan carries an exploration tracking ID (`isExplorationVariant(tracking_id)` is true). It routes via `variant_tracking_map_` to find `{group_id, variant_index}`, deconvolves the raw spectrum with the correct precursor context and the per-level `exploration_tolerance_ppm`, calls `computeExplorationScore_` (`Exploration.cpp:1254`), stores the score on the variant, marks `received=true`, and tests whether all variants have `received=true`. Once all variants have been received, runs winner selection (see below). On MS3 with the `FragmentCount` metric, also triggers `MS3FragmentMatcher::calibrateAndScore` (see `ms3-exploration.md`).

## A trap pre-scan is measured, never identified (ADR-0045)

Before scoring, `feedResult` reads the variant's **own command**: `measured_only = isTrapAnalyzer(cmd.analyzer)` (`Exploration.cpp:397`, `Config.h:138`). A measured-only variant is **not deconvolved, not matched and not fed to the ProteoformTracker**, at any level, under any metric; the only thing read from it is the raw precursor-window sum, so its score is `computeRemainingPrecursorScore_` when the metric is `RemainingPrecursor` and the `-1.0` "not scored" sentinel otherwise (unreachable from config — `Config::validate` refuses an `IonTrap` override under a counting metric, `Config.cpp:1293`, because with nothing deconvolved `mass_count`/`fragment_count` would score every variant 0 and `ce_min` would always win). Two details are load-bearing: the flag is set from the **command**, never from the returning scan (ADR-0042); and `last_result_deconvolved_` (`Exploration.h:347`) makes `explorationDeconvMassCount()`/`explorationDeconvSpectrum()` report nothing after such a feed, because `FLASHIda.cpp` reads them for the `scan_results` row and the stored spectrum would otherwise be the *previous* variant's. Pinned by `a_trap_pre_scan_is_measured_never_identified` (ctest) and the `exploration_iontrap` golden (C#).

## `computeExplorationScore_` dispatcher

A single `switch` at `Exploration.cpp:1254` over `ExplorationMetric` (`Config.h:87`) with three cases plus a default fallback. All three cases first call `computeFragmentMatch_` (which populates match metadata used by downstream logging and metadata), then return a metric-specific score. Returns a `double`; higher is better. A measured-only variant never reaches it (above).

## Per-metric scoring

- **`MassCount` — `computeMassCount_` (`Exploration.cpp:1285`)**: counts deconvolved masses in the variant's spectrum (`spec.size()`). A spectral-richness proxy: more distinct masses = better fragmentation. Cheap; no reference needed.
- **`RemainingPrecursor` — `computeRemainingPrecursorScore_` (`Exploration.cpp:1309`)**: computes `ratio = remaining_intensity / baseline_reference` in the isolation window — the **anchor's** window only (`precursorWindowIntensity_`, `Exploration.cpp:1290`), which is why the metric is refused at load together with `multiplexed` charges at the same level: under co-isolation it reports one charge state's depletion (ADR-0026 decision 4, re-grounded by ADR-0044). The pre-scan itself reads out its level's full configured scan range; ADR-0026's narrowing to this window was withdrawn by ADR-0044. Then `score = 1.0 - |ratio - remaining_precursor_target|`, where `remaining_precursor_target` is a per-level config value. Rewards matching the configured target depletion, not maximizing it — a ratio equal to the target scores `1.0`; both over- and under-depletion lose score. **The returned score is always in `[0, 1]`**: every failure path (empty input, baseline not yet received, baseline reference intensity ≤ 0, or a computed score below 0) returns `0.0`. The "can't compute a ratio" signal lives **only** in the `out_ratio` out-parameter, which is `-1.0` (N/A) in those cases — it is never folded into the score. (Returning negative sentinels *as the score* was a regression that broke winner selection; see the abort note under Winner selection.)
- **`FragmentCount` — inlined (`Exploration.cpp:734-739`)**: no separate helper function. The dispatcher's case inlines `return static_cast<double>(fmr.total_match_count);` using the `FragmentMatchResult` produced by `computeFragmentMatch_`. For the MS2 fragment-matching integration (what it calls, tolerance source, gotchas), see [`../fragment-analysis/ms2-matching.md`](../fragment-analysis/ms2-matching.md). On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (`Exploration.cpp:400`), which re-scores variants with calibrated per-variant fragment m/z tolerance **after** the initial winner is selected (see `ms3-exploration.md` for the exploration-flow view; [`../fragment-analysis/ms3-matching.md`](../fragment-analysis/ms3-matching.md) for the matcher-side view).

## Winner selection

Inside `feedResult`, once all variants have been received, a linear scan iterates the group's variants tracking `best_score` (seeded at `-1.0`) and `best_idx`. Baseline variants (`is_baseline==true`) are skipped. The comparator is strict `>`, so on ties the lowest-index variant wins (first-seen keeps the slot); given the default CE-inner sweep, that means lowest CE wins ties. `group.winner_index` is recorded, `group.complete = true` is set, and the winner's result is flagged via `is_best_variant`. An `[EXPL-WINNER]` log line records `group_id`, `winner_idx`, activation, CE, RT, and score.

**Empty-baseline abort (RemainingPrecursor).** If the CE=0 baseline returns no in-window signal (`baseline_intensity <= 0`), no CE variant can be scored. When this is detected at baseline-feed time the group sets `baseline_failed=true` and **cancels its still-queued / in-flight child scans** via `ScanCommandQueue::cancelByScanIds` (the cancelled children are marked received so the group can complete). At winner selection a `baseline_failed` group (or, defensively, any group with no scorable variant — `best_idx < 0`) is finalized with **no winner and no follow-up production scan**, logged as `[EXPL-ABORT]`, and cleaned up normally. This replaces an earlier latent bug where all-`-1.0` scores left `best_idx == -1` and the group never completed.

## `overrides` application

`MSLevelConfig::overrides` is a key-value map that `Exploration::initiate` applies to the variant sweep's **base config** via `base_config.applyOverrides(cfg.overrides)` — so every variant inherits the overrides, not just a winner; `first_mass`/`last_mass` in the map patch the pre-scans like any other key (ADR-0044 decision 2). The map *also* gates whether a separate post-winner production scan is emitted: the branch at `Exploration.cpp:771` (`!level_config.overrides.empty() || measuring_ms3_sweep`) builds a fresh production `ScanCommand` from `level_config.scans[0]` — the **un-overridden** config, so a trap sweep's follow-up is an Orbitrap scan — with the winner's CE/RT/activation copied onto it; the second disjunct is ADR-0020's rule that a measuring MS3 sweep is always closed by a follow-up. Overrides are **optional under every metric** (ADR-0026 once required them for `remaining_precursor`; ADR-0044 lifted that).

## Gotchas

- **Score default `-1.0` vs computed score.** The `ExplorationVariant::score` field *defaults* to `-1.0` and keeps that value until the variant is received; do not treat the default as a legitimate low score. Once a variant is **received**, its computed score is always in `[0, 1]` (see RemainingPrecursor above) — a received variant never carries a negative score. Winner selection runs only after all variants are received, so it only ever compares `[0, 1]` scores.
- **Metric preconditions.** `RemainingPrecursor` without a baseline is a configuration bug; `FragmentCount` on MS3 presumes fragment analysis is configured. `Config::validate()` catches obvious misconfigurations (`FragmentCount` specifically requires a non-empty `targeting_.protein_sequence`); the baseline for `RemainingPrecursor` is *not* validated, but a baseline that returns with no in-window signal is handled at runtime by the empty-baseline abort (see Winner selection) rather than producing a meaningless winner.
- **No per-group timeout.** Restated from `exploration.md`: a dropped variant leaves the group pending indefinitely; `feedResult` never fires the winner path.

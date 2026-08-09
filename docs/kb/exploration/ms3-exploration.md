---
title: MS3 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-08-09
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:373                     # non-exploration MS2 -> MS3 initiateNextLevel call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:458                     # MS3 isExplorationVariant routing
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:183         # MS3 context wiring inside initiate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:185         # queue.buildMS3 variant build
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:162         # group field population (fragment_ion_type / fragment_ion_index / proteoform_ctx)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:492         # ProteoformTracker::scoreCalibratedVariants call (batch re-score)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:532         # winner selection best_idx loop
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:637         # queue.buildMS3 production scan from winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:667         # MS2-winner path: initiateNextLevel + ms2_context_cache propagation
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:733         # initiateNextLevel definition (shared with MS2-winner path)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:921         # queue.buildMS3 inside initiateNextLevel
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:131   # ExplorationGroup::fragment_ion_type
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:132   # ExplorationGroup::fragment_ion_index
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:133   # ExplorationGroup::proteoform_ctx
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:60    # ProteoformContext struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.h:281    # scoreCalibratedVariants signature
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ../fragment-analysis/ms3-matching.md
---

## Two trigger paths

MS3 exploration is reached via `Exploration::initiateNextLevel` (`Exploration.cpp:733`). There are two callers, distinguished only by what produced the MS2 result feeding in:

- **Exploration-winner path.** When an MS2 exploration group completes *with no production scan* (`level_config.overrides` empty), `feedResult` calls `initiateNextLevel(2, winner.result, group.faims_cv, queue, &winner.cmd, tracker, precursor_id)` with the winner variant's deconvolved spectrum (`Exploration.cpp:667`). This path only fires when MS2 exploration is enabled on the precursor. With overrides set the group emits a production MS2 instead, which then reaches MS3 through the non-exploration path below.
- **Non-exploration path.** When MS2 exploration is *disabled* but MS3 is configured, the regular MS2 result handler at `FLASHIda.cpp:373` calls `initiateNextLevel(2, deconv_.storedMS2(), parent_ctx.faims_cv, queue_, &parent_ctx, &tracker_, precursor_id)` with the stored MS2 result. MS3 exploration therefore does not require MS2 exploration upstream — it can run on its own.

Both callers pass the same argument shape. Inside `initiateNextLevel` the first statement of interest is `int next_level = msn_level + 1` — the `msn_level` parameter is the *source* level, not the target, so `msn_level=2` drives MS3.

Downstream behavior is identical regardless of origin; only the caller differs. **This became true on 2026-08-09 and was false before.** The exploration-winner path inserted `next_nlr.commands` into its result but dropped the parallel `next_nlr.ms3_contexts`, so the MS3s it dispatched arrived with no entry in `FLASHIda::ms2_context_cache_`. A returning MS3 that misses that lookup skips the entire identification block — no `identification.tsv` row, no `tracker_.feedScan`/`foldMs3`, nothing in `pooled_identification.tsv` — while still being acquired and still writing a `scan_results.tsv` row. Only the non-exploration path seeded the cache. `feedResult` now propagates the contexts (`Exploration.cpp:667`), pinned by `FLASHIda_exploration_test::ms2_exploration_fixed_ce_ms3_carries_parent_context`.

## Context plumbing

`ms_ctx` at MS3 is the originating MS2 `ScanCommand` (not a scan ID — `buildMS3` needs full two-stage isolation context including the MS1 precursor). The group's MS3-specific fields — `fragment_ion_type`, `fragment_ion_index`, and `proteoform_ctx` (`ExplorationGroup`, `Exploration.h:131-133`) — are populated unconditionally at `Exploration.cpp:162-164`; for MS2 the caller passes `'\0'` / `0` / empty-context, so they take default values. Separately, the per-variant `ScanCommand` build branches on `msn_level >= 3 && ms_ctx != nullptr` at `Exploration.cpp:183`: MS3 variants are built with `queue.buildMS3(*ms_ctx, variant_config, precursor_mz, charge, isolation_width, ion_type, frag_index, ...)` at `:185`; MS2 variants fall through to `queue.buildMS2` at `:192`.

- `fragment_ion_type` and `fragment_ion_index` identify which fragment from the parent MS2 is the MS3 target (e.g. `'b'` + 7 for the 7th b-ion).
- `proteoform_ctx` (type `MS3FragmentMatcher::ProteoformContext`, defined at `MS3FragmentMatcher.h:60`) caches the candidate protein sequence bounds (`region_start`/`region_end`) and PTM sites from MS2 tag-based matching. This cache lets batch re-scoring skip re-running proteoform identification against the protein database.

## Variant construction

`Exploration::initiate` builds MS3 variants via `queue.buildMS3(*ms_ctx, variant_config, precursor_mz, charge, isolation_width, ion_type, frag_index, expl_priority)` at `Exploration.cpp:185`. The CE / RT / activation-type axes work exactly as at MS2 (see `variants-and-sweeps.md`); the per-level `MSLevelConfig` fields come from `config_.level(3)` instead of `config_.level(2)`.

After winner selection, a separate production MS3 scan is built with `queue.buildMS3(group.variants[best_idx].cmd, prod_config, ...)` at `Exploration.cpp:637`. As at MS2, this production scan is only emitted when `level_config.overrides` is non-empty — same emission gate as described in `scoring-and-winner.md`. A third `queue.buildMS3` call lives at `Exploration.cpp:921` inside `initiateNextLevel` itself and handles the fragment-targeted build for callers that configure MS3 directly without recursive exploration.

MS3 variants share the same state machine and scoring scaffold as MS2; the level-specific differences are *what* gets fragmented (an MS2 fragment, not an MS1 precursor) and *what context* rides along (`fragment_ion_type`, `fragment_ion_index`, `proteoform_ctx`).

## Post-all-received: `ProteoformTracker::scoreCalibratedVariants`

> For the matcher-side view (two-pass calibration mechanics, MS3 ion types, dual theoreticals), see [`../fragment-analysis/ms3-matching.md`](../fragment-analysis/ms3-matching.md).

MS3-only, `FragmentCount`-metric-only. After `all_received` flips true but **before** winner selection, `feedResult` calls `ProteoformTracker::scoreCalibratedVariants(...)` at `Exploration.cpp:492`. The gate is `group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3`. (This was `MS3FragmentMatcher::calibrateAndScore`; the matcher still owns the calibration mechanics, but the entry point moved to `ProteoformTracker`.)

The function takes `variant_spectra` (deconvolved spectra for each variant), the configured protein sequence, a scoring context, the targeted fragment's type + index, `MS3FragmentMatcher::LOOSE_TOLERANCE_PPM` (500 ppm, a compile-time constant at `MS3FragmentMatcher.h:68`), and the level's configured `tolerance_ppm`. Critically, it performs its **own** fragment matching internally — a two-pass calibration followed by a tight-tolerance rematch — and does **not** reuse any `FragmentMatchResult` from earlier `computeFragmentMatch_` calls on the feed path.

**The scoring context is not `group.proteoform_ctx`.** With a tracker present it is `tracker->buildWinnerProteoformContext(precursor_id)` — the live winner (ADR-0002) — and `group.proteoform_ctx` stays the triggering scan's *render* context, driving `buildMS3` and the cached `MS2Context`. The group context is used for scoring only when `tracker == nullptr`, which is the unit-test case.

It returns two aligned outputs (one entry per variant):

1. `calibrated_scores[vi]` — overwrites `group.variants[vi].score` and is also cast to `int` and stored into `fragment_count`. After this loop, the `score` field no longer holds the initial value from `computeExplorationScore_`.
2. `detailed_results[vi]` — `FragmentAnalysis::ProteoformMatch` per variant, copied into each variant's `identification_result` field.

Only *after* this batch re-score does winner selection run (`best_idx` loop at `Exploration.cpp:532`). For MS3 FragmentCount, the winner is picked on the calibrated scores, not the initial per-variant scores. For MS3 with `MassCount` or any other metric, the batch re-score is skipped, `identification_result` stays at its default, and winner selection uses the initial score.

## Result routing

When an MS3 scan completes, `FLASHIda.cpp:458` checks `isExplorationVariant(tracking_id)`. If true, the result is diverted into `Exploration::feedResult` for the scoring / re-score / winner flow above. Non-exploration MS3 results (produced by the direct `queue.buildMS3` path at `Exploration.cpp:921` when `config_.hasExploration(3) == false`) skip `feedResult` entirely and go through the standard MS3 handler downstream.

The two routes differ in what they need from `ms2_context_cache_`. The regular MS3 handler *reads* it, and identifies nothing on a miss; the exploration branch never reads it and instead *erases* the returning variant's entry, since the context was minted at dispatch and is spent the moment the variant comes back. Both insertion sites and that erase must stay in step — see the `Gotchas` below.

## Gotchas

- **`proteoform_ctx` lifetime.** It lives on the `ExplorationGroup` (`Exploration.h:133`) and is valid only while the group is in `active_groups_`. Do not borrow references to it across group cleanup — downstream consumers must snapshot what they need (bounds + PTM sites) before the group is removed.
- **An MS3 command must leave with its parent-MS2 context, and only a regular-path return may consume it.** Three sites touch `FeedResultInfo::ms2_context_cache` / `NextLevelResult::ms3_contexts`: the production-MS3 re-acquisition (`Exploration.cpp:637`), the MS2-winner next-level dispatch (`:667`), and the regular MS2 handler (`FLASHIda.cpp:373`). Miss one and those MS3s are acquired and then silently unidentified. The mirror-image failure is never erasing: an MS3 exploration variant also gets a context but returns on a branch that cannot read it, so `FLASHIda.cpp` erases on that return. Neither failure shows up in the logs as an error — the first drops rows, the second only leaks memory.
- **`buildMS3` needs the MS2 `ScanCommand`, not the MS2 scan ID.** Passing a scan ID where `ScanCommand` is expected produces a malformed isolation request; the C++ side does not validate, and the instrument returns nonsense.
- **Non-exploration path only fires when MS3 is configured.** The call at `FLASHIda.cpp:373` is wrapped by a guard at `:367` (`if (config_.level(2).selection != SelectionMetric::None)`), which effectively means "MS3 targeting is enabled". MS3 configuration is per-level and independent of whether MS2 exploration is enabled.
- **`FragmentCount` + batch-re-score coupling.** Only the `FragmentCount` metric triggers `scoreCalibratedVariants`. If the selected MS3 metric is `MassCount`, `RemainingPrecursor`, `Intensity`, etc., `identification_result` is *not* populated, and the initial per-variant score stands.
- **`initiateNextLevel` is not exploration-only.** The `exploration_.` receiver names the owning object, not a precondition on the scan. It serves both MS3 shapes, chosen by `config_.hasExploration(3)`: off builds one fixed-CE MS3 per target from `ms_settings.ms3` (`Exploration.cpp:921`), on builds a CE sweep.

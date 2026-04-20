---
title: MS3 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927                     # non-exploration MS2 -> MS3 initiateNextLevel call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:986                     # MS3 isExplorationVariant routing
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:181         # MS3 context wiring inside initiate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:183         # queue.buildMS3 variant build
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:159         # group field population (fragment_ion_type / fragment_ion_index / proteoform_ctx)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400         # MS3FragmentMatcher::calibrateAndScore call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:470         # queue.buildMS3 production scan from winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504         # initiateNextLevel definition (shared with MS2-winner path)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:658         # queue.buildMS3 inside initiateNextLevel
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:119   # ExplorationGroup::fragment_ion_type
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:120   # ExplorationGroup::fragment_ion_index
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:121   # ExplorationGroup::proteoform_ctx
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:58    # ProteoformContext struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:115   # calibrateAndScore signature
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
---

## Two trigger paths

MS3 exploration is reached via `Exploration::initiateNextLevel` (`Exploration.cpp:504`). There are two callers, distinguished only by what produced the MS2 result feeding in:

- **Exploration-winner path.** When an MS2 exploration group completes, `feedResult` calls `initiateNextLevel(2, winner.result, ctx.faims_cv, queue_, ms_ctx)` with the winner variant's deconvolved spectrum. This path only fires when MS2 exploration is enabled on the precursor.
- **Non-exploration path.** When MS2 exploration is *disabled* but MS3 is configured, the regular MS2 result handler at `FLASHIda.cpp:927` calls `initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx)` with the stored MS2 result. MS3 exploration therefore does not require MS2 exploration upstream — it can run on its own.

Both callers pass the same argument shape `(msn_level=2, MS2 deconvolved spectrum, FAIMS CV, queue, ScanCommand context)`. Inside `initiateNextLevel` the first statement of interest is `int next_level = msn_level + 1` — the `msn_level` parameter is the *source* level, not the target, so `msn_level=2` drives MS3. Downstream behavior is identical regardless of origin; only the caller differs.

## Context plumbing

`ms_ctx` at MS3 is the originating MS2 `ScanCommand` (not a scan ID — `buildMS3` needs full two-stage isolation context including the MS1 precursor). The group's MS3-specific fields — `fragment_ion_type`, `fragment_ion_index`, and `proteoform_ctx` (`ExplorationGroup`, `Exploration.h:119-121`) — are populated unconditionally at `Exploration.cpp:159-162`; for MS2 the caller passes `'\0'` / `0` / empty-context, so they take default values. Separately, the per-variant `ScanCommand` build branches on `msn_level >= 3 && ms_ctx != nullptr` at `Exploration.cpp:181`: MS3 variants are built with `queue.buildMS3(*ms_ctx, variant_config, precursor_mz, charge, isolation_width, ion_type, frag_index, ...)` at `:183`; MS2 variants fall through to `queue.buildMS2` at `:189`.

- `fragment_ion_type` and `fragment_ion_index` identify which fragment from the parent MS2 is the MS3 target (e.g. `'b'` + 7 for the 7th b-ion).
- `proteoform_ctx` (type `MS3FragmentMatcher::ProteoformContext`, defined at `MS3FragmentMatcher.h:58`) caches the candidate protein sequence bounds (`region_start`/`region_end`) and PTM sites from MS2 tag-based matching. This cache lets batch re-scoring skip re-running proteoform identification against the protein database.

## Variant construction

`Exploration::initiate` builds MS3 variants via `queue.buildMS3(*ms_ctx, variant_config, precursor_mz, charge, isolation_width, ion_type, frag_index, expl_priority)` at `Exploration.cpp:183`. The CE / RT / activation-type axes work exactly as at MS2 (see `variants-and-sweeps.md`); the per-level `MSLevelConfig` fields come from `config_.level(3)` instead of `config_.level(2)`.

After winner selection, a separate production MS3 scan is built with `queue.buildMS3(group.variants[best_idx].cmd, prod_config, ...)` at `Exploration.cpp:470`. As at MS2, this production scan is only emitted when `level_config.overrides` is non-empty — same emission gate as described in `scoring-and-winner.md`. A third `queue.buildMS3` call lives at `Exploration.cpp:658` inside `initiateNextLevel` itself and handles the fragment-targeted build for callers that configure MS3 directly without recursive exploration.

MS3 variants share the same state machine and scoring scaffold as MS2; the level-specific differences are *what* gets fragmented (an MS2 fragment, not an MS1 precursor) and *what context* rides along (`fragment_ion_type`, `fragment_ion_index`, `proteoform_ctx`).

## Post-all-received: `MS3FragmentMatcher::calibrateAndScore`

MS3-only, `FragmentCount`-metric-only. After `all_received` flips true but **before** winner selection, `feedResult` calls `MS3FragmentMatcher::calibrateAndScore(...)` at `Exploration.cpp:400`. The gate is `group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3`.

The function takes `variant_spectra` (deconvolved spectra for each variant), the configured protein sequence, the group's cached `proteoform_ctx`, the targeted fragment's type + index, `MS3FragmentMatcher::LOOSE_TOLERANCE_PPM` (500 ppm, a compile-time constant at `MS3FragmentMatcher.h:66`), and the level's configured `tolerance_ppm`. Critically, it performs its **own** fragment matching internally — a two-pass calibration followed by a tight-tolerance rematch — and does **not** reuse any `FragmentMatchResult` from earlier `computeFragmentMatch_` calls on the feed path.

It returns two aligned outputs (one entry per variant):

1. `calibrated_scores[vi]` — overwrites `group.variants[vi].score` and is also cast to `int` and stored into `fragment_count`. After this loop, the `score` field no longer holds the initial value from `computeExplorationScore_`.
2. `detailed_results[vi]` — `FragmentAnalysis::ProteoformMatch` per variant, copied into each variant's `identification_result` field.

Only *after* this batch re-score does winner selection run (`best_idx` loop at `Exploration.cpp:436`). For MS3 FragmentCount, the winner is picked on the calibrated scores, not the initial per-variant scores. For MS3 with `MassCount` or any other metric, `calibrateAndScore` is skipped, `identification_result` stays at its default, and winner selection uses the initial score.

## Result routing

When an MS3 scan completes, `FLASHIda.cpp:986` checks `isExplorationVariant(tracking_id)`. If true, the result is diverted into `Exploration::feedResult` for the scoring / re-score / winner flow above. Non-exploration MS3 results (produced by the direct `queue.buildMS3` path at `Exploration.cpp:658` when `config_.hasExploration(3) == false`) skip `feedResult` entirely and go through the standard MS3 handler downstream.

## Gotchas

- **`proteoform_ctx` lifetime.** It lives on the `ExplorationGroup` (`Exploration.h:121`) and is valid only while the group is in `active_groups_`. Do not borrow references to it across group cleanup — downstream consumers must snapshot what they need (bounds + PTM sites) before the group is removed.
- **`buildMS3` needs the MS2 `ScanCommand`, not the MS2 scan ID.** Passing a scan ID where `ScanCommand` is expected produces a malformed isolation request; the C++ side does not validate, and the instrument returns nonsense.
- **Non-exploration path only fires when MS3 is configured.** The call at `FLASHIda.cpp:927` is wrapped by a guard at `:924` (`if (config_.level(2).selection != SelectionMetric::None)`), which effectively means "MS3 targeting is enabled". MS3 configuration is per-level and independent of whether MS2 exploration is enabled.
- **`FragmentCount` + `calibrateAndScore` coupling.** Only the `FragmentCount` metric triggers the batch re-score. If the selected MS3 metric is `MassCount`, `RemainingPrecursor`, `Intensity`, etc., `identification_result` is *not* populated, and the initial per-variant score stands.

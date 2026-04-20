---
title: MS2 Fragment Matching
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:716   # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:734   # FragmentCount case (inlined)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:793   # computeFragmentMatch_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:759   # getTopFragmentMatches definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:154   # getTopFragmentMatches signature
see_also:
  - README.md
  - data-model.md
  - ms3-matching.md
  - ../exploration/scoring-and-winner.md
---

## Overview

MS2 fragment matching in this packet refers to the specific call inside exploration's `FragmentCount` metric scoring: `Exploration::computeFragmentMatch_` delegates to `FragmentAnalysis::getTopFragmentMatches` against the configured protein sequence. The returned `total_match_count` is the metric score.

This is a read of the match count — the engine does not act on the matched fragments themselves at this level. For actual fragment-ion-targeted scan building, see `../exploration/ms3-exploration.md` and `tag-follow-up.md`.

## Context

The exploration scoring dispatcher `Exploration::computeExplorationScore_` (`Exploration.cpp:716`) switches on `ExplorationMetric`. The `FragmentCount` case is inlined at `:734`:

```cpp
case ExplorationMetric::FragmentCount:
  return static_cast<double>(fmr.total_match_count);
```

`fmr` is a `FragmentAnalysis::ProteoformMatch` produced upstream in the dispatcher by a call to `computeFragmentMatch_`.

## Flow

Inside `Exploration::computeFragmentMatch_` at `Exploration.cpp:793`:

1. Read `config_.targeting().protein_sequence` and the input `DeconvolvedSpectrum`.
2. **Short-circuit** on empty protein sequence OR empty spectrum → return an empty `ProteoformMatch` (`total_match_count == 0`).
3. Otherwise, call:
   ```cpp
   fragments_.getTopFragmentMatches(
       seq, /*max_matches=*/100,
       masses.data(), qscores.data(), charges.data(),
       wstarts.data(), wends.data(),
       ion_types.data(), frag_indices.data(),
       spec_copy, result, activation_type,
       config_.level(msn_level).exploration_tolerance_ppm);
   ```
   — with `result` as the output `ProteoformMatch` populated in place.
4. If `result.total_match_count > 0`, set `result.matched_protein = config_.targeting().fasta_file`.
5. Return `result` to the dispatcher; `total_match_count` becomes the `FragmentCount` score.

## Tolerance source

`config_.level(msn_level).exploration_tolerance_ppm`, NOT `level(msn_level).tolerance_ppm`. These are separate per-level config fields. In MS2 exploration scoring, only `exploration_tolerance_ppm` is read here — `tolerance_ppm` is used elsewhere in the deconvolution and matching pipeline.

Note the cross-mode divergence: MS3 calibration (`MS3FragmentMatcher::calibrateAndScore`, see `ms3-matching.md`) reads the **other** field, `config_.level(group.msn_level).tolerance_ppm`. MS2 exploration scoring and MS3 calibration do not share a tolerance source.

When debugging tolerance-related behavior in MS2 exploration scoring, check `exploration_tolerance_ppm` in the relevant level config first.

## Max matches

Hardcoded `100` inside `computeFragmentMatch_`. The caller-facing `FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.h:154`) accepts an `n` parameter; the internal call always passes 100. The returned `total_match_count` is *uncapped* (reflects actual matches), but the per-fragment arrays are capped at 100.

## Underlying matching function

`FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.cpp:759`) runs tag-based fragment matching using the stored MS2 deconvolution results. It orchestrates FLASHTagger + FLASHExtender internally to produce a full `ProteoformMatch` (region bounds, PTM sites, matched fragments). Internals (FLASHTagger / FLASHExtender orchestration, fragment indexing) are out of scope for this packet; see the OpenMS source or a future deep-dive packet.

**Not the same as tag+follow-up's tag detection.** `PrecursorSelection::processMS2ForTagBasedTargeting` (used by the tag+follow-up mode) invokes `FLASHTaggerAlgorithm::run()` directly for tag detection only — it does not call `getTopFragmentMatches` and does not produce a full `ProteoformMatch`. Both paths use FLASHTagger as a component, but at different levels.

## Gotchas

- **Silent zero-score on missing config.** An empty `protein_sequence` returns an empty `ProteoformMatch` with `total_match_count = 0`. This is indistinguishable downstream from a legitimate zero-match result. Empty protein + `FragmentCount` metric means all variants score 0 and winner selection picks the first non-baseline variant (strict `>` comparator; see `../exploration/scoring-and-winner.md`).

- **`exploration_tolerance_ppm` vs. `tolerance_ppm`.** Config divergence risk. When adjusting `method.json` for MS2 scoring tolerance, the relevant key is `ms_settings.ms2.exploration_tolerance_ppm` (not `tolerance_ppm`). Both exist; both flow from config-flow into per-level config; only the former is read by `computeFragmentMatch_`.

# Conditional Fragment Analysis Design Spec

**Date:** 2026-04-14
**Branch:** `phase-11` (parent) / `flashida-v9-bridge` (OpenMS submodule)
**Scope:** Gate `computeFragmentMatch_()` in exploration to only run when `ExplorationMetric::FragmentCount` is active. Eliminate the redundant double-call for FragmentCount.

---

## Problem

`feedResultImpl_()` in `Exploration.cpp:215` calls `computeFragmentMatch_()` unconditionally for every exploration variant result. Fragment analysis is expensive (FLASHTagger + FLASHExtender tag-based matching against the protein sequence).

Three issues:

1. **Unnecessary work for MassCount/RemainingPrecursor:** Fragment analysis runs even though the score doesn't use it. The result only populates TSV metadata columns (`fragment_count`, `matched_protein`, `proteoform_sequence`) which are acceptable as 0/empty for these metrics.

2. **Redundant double-call for FragmentCount:** `computeExplorationScore_()` at line 500 calls `computeFragmentMatch_(spec).count` for the score, then line 215 calls it again identically for metadata. Same spectrum, same `max_matches=100`.

3. **`initiateNextLevel()` is unaffected:** It runs its own independent fragment analysis (lines 370-393) with different parameters (`max_targets` from config) for next-level target selection. This call is always necessary when `SelectionMetric != None` and is not touched by this change.

---

## Downstream verification

The `frag` result from line 215 flows to:

| Destination | Line | Purpose |
|---|---|---|
| `v.fragment_count` | 225 | Stored on `ExplorationVariant` struct |
| `info.fragment_count` | 260 | Returned in `FeedResultInfo` |
| `info.matched_protein` / `info.proteoform_sequence` | 262-263 | Returned in `FeedResultInfo` |
| `meta.fragment_count` | 280 | Stored in `OptimizationMetadata` |
| `writeScanResultRow_()` | FLASHIda.cpp:681-683, 790-792 | TSV logging |

Winner selection (lines 291-301) uses only `v.score`. None of these metadata fields influence any decision.

---

## Changes

### 1. `computeExplorationScore_()` — add `FragmentMatchResult*` out-parameter

**File:** `Exploration.cpp:487-504`, `Exploration.h` (private declaration)

Add `FragmentMatchResult* out_frag = nullptr` after the existing `double* out_remaining_ratio` parameter. In the `FragmentCount` case, store the result before returning:

```cpp
double Exploration::computeExplorationScore_(ExplorationMetric metric,
    const DeconvolvedSpectrum& spec,
    const ExplorationGroup& group,
    const double* mzs, const double* ints, int length,
    double* out_remaining_ratio, FragmentMatchResult* out_frag) const
{
  switch (metric)
  {
    case ExplorationMetric::MassCount:
      return computeMassCount_(spec);
    case ExplorationMetric::RemainingPrecursor:
      return computeRemainingPrecursorScore_(group, mzs, ints, length, out_remaining_ratio);
    case ExplorationMetric::FragmentCount:
    {
      auto fmr = computeFragmentMatch_(spec);
      if (out_frag) *out_frag = fmr;
      return fmr.count;
    }
    default:
      return computeMassCount_(spec);
  }
}
```

### 2. `feedResultImpl_()` — remove unconditional call, use out-parameter

**File:** `Exploration.cpp:213-216`

Replace:
```cpp
v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio);
v.tic_coverage = computeTICCoverage_(ms2_deconv);
auto frag = computeFragmentMatch_(ms2_deconv);
v.fragment_count = static_cast<int>(frag.count);
```

With:
```cpp
FragmentMatchResult frag{};
v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio, &frag);
v.tic_coverage = computeTICCoverage_(ms2_deconv);
v.fragment_count = static_cast<int>(frag.count);
```

For `MassCount`/`RemainingPrecursor`: `frag` stays default (`count=0`, empty strings). For `FragmentCount`: `frag` is populated by the single call inside the score function.

---

## Result per metric

| Metric | Fragment analysis calls per variant | Before | After |
|---|---|---|---|
| MassCount | 0 | 1 (wasted) | 0 |
| RemainingPrecursor | 0 | 1 (wasted) | 0 |
| FragmentCount | 1 (scoring + metadata) | 2 (redundant) | 1 |

`initiateNextLevel()` is unchanged in all cases (separate call with different parameters for target selection).

---

## Files Modified

| File | Nature of change |
|---|---|
| `Exploration.h` | Add `FragmentMatchResult* out_frag = nullptr` to `computeExplorationScore_` declaration |
| `Exploration.cpp` | Score function: store result in out-param for FragmentCount case. `feedResultImpl_`: remove line 215, declare `frag{}`, pass `&frag` to score function |

---

## Tests

**File:** `FragmentAnalysis_test.cpp` (already runs in CI, passes)

`FLASHIda_exploration_test` is excluded from CI due to unrelated issues. Instead, add two sections to `FragmentAnalysis_test.cpp` which already has cytochrome c data, deconvolution, and protein sequence infrastructure.

**New includes needed:** `Exploration.h`, `ScanCommandQueue.h`, `PeakGroup.h`

**New configs:** Two exploration-enabled variants of the existing `fragment_test_config`:
- `fragment_count_exploration_config` — same as `fragment_test_config` but with `"exploration": { "metric": "fragment_count", "ce_min": 20.0, "ce_max": 30.0, "ce_step": 10.0 }` on the ms2 level
- `mass_count_exploration_config` — same but with `"metric": "mass_count"`

### Test 1: `fragment_count_populated_for_fragment_count_metric`

1. Deconvolve real cytochrome c MS2 scan (reuses existing pattern from `getTopFragmentMatches_cytochrome_c`)
2. Create `Exploration` with `fragment_count_exploration_config`
3. Create a synthetic `PeakGroup`, call `exploration.initiate()` to create CE variants
4. Call `exploration.feedResultForTest()` with the deconvolved spectrum
5. Assert: `info.fragment_count > 0`, `info.matched_protein.empty() == false`, `info.proteoform_sequence == cytochrome_c_seq`

### Test 2: `fragment_analysis_skipped_for_mass_count_metric`

1. Same deconvolved spectrum (cytochrome c, would produce fragment matches)
2. Create `Exploration` with `mass_count_exploration_config` (protein sequence present)
3. Create synthetic `PeakGroup`, call `exploration.initiate()`
4. Call `exploration.feedResultForTest()` with the same spectrum
5. Assert: `info.fragment_count == 0`, `info.matched_protein.empty() == true`, `info.proteoform_sequence.empty() == true`

This is the critical test: same data that produces matches with FragmentCount metric, but MassCount metric correctly skips fragment analysis.

Both tests use `feedResultForTest()` which passes `nullptr` for raw mz/int arrays, bypassing the full deconvolution pipeline and avoiding the issues that caused `FLASHIda_exploration_test` to be excluded from CI.

### Impact on existing `FLASHIda_exploration_test.cpp` (not in CI)

`fragment_match_propagated_in_feed_result` (line 1427) uses `exploration_config` which has `metric: "mass_count"`. After this change it will fail because fragment analysis is no longer run for MassCount. This test is not in CI, so it won't block. If the exploration test is re-enabled later, it would need updating to use a `fragment_count` config.

---

## Files Modified

| File | Nature of change |
|---|---|
| `Exploration.h` | Add `FragmentMatchResult* out_frag = nullptr` to `computeExplorationScore_` declaration |
| `Exploration.cpp` | Score function: store result in out-param for FragmentCount case. `feedResultImpl_`: remove line 215, declare `frag{}`, pass `&frag` to score function |
| `FragmentAnalysis_test.cpp` | Add includes, two exploration configs, two test sections |

---

## Out of Scope

- `initiateNextLevel()` fragment analysis (different purpose, different parameters)
- `computeTICCoverage_()` (separate concern, always cheap)
- Non-exploration paths in `FLASHIda.cpp` (they call `initiateNextLevel()` directly, not `computeFragmentMatch_()`)
- TSV column removal (columns stay, values are 0/empty when metric is not FragmentCount)

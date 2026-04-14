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

## Out of Scope

- `initiateNextLevel()` fragment analysis (different purpose, different parameters)
- `computeTICCoverage_()` (separate concern, always cheap)
- Non-exploration paths in `FLASHIda.cpp` (they call `initiateNextLevel()` directly, not `computeFragmentMatch_()`)
- TSV column removal (columns stay, values are 0/empty when metric is not FragmentCount)

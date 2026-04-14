# Add `remaining_ratio` Column to results.tsv

## Goal

Expose the raw remaining precursor ratio (`remaining_intensity / baseline_intensity`) as a new column in results.tsv so downstream analysis scripts can consume it directly without reverse-engineering the score.

## Background

The RemainingPrecursor exploration metric computes a ratio in `Exploration::computeRemainingPrecursorScore_()` (Exploration.cpp:536):

```
ratio = remaining_intensity / baseline_intensity
```

This ratio is currently a local variable — only the derived score (`1.0 - |ratio - target|`) survives into `FeedResultInfo` and the TSV. Downstream analysis needs the raw ratio.

## Design

### Column specification

- **Name:** `remaining_ratio`
- **Position:** Column 19 (appended after `exploration_score`)
- **Type:** double
- **Default:** `-1.0` for non-applicable rows (non-exploration scans, non-RemainingPrecursor metrics, baseline variants, error cases)
- **Valid range:** `[0.0, +inf)` where 0.0 = complete fragmentation, 1.0 = no fragmentation, >1.0 possible with noise

### Data flow

Thread the ratio out via an output parameter — no interface-breaking changes:

1. `computeRemainingPrecursorScore_()` gains `double* out_ratio = nullptr`
2. `computeExplorationScore_()` gains `double* out_remaining_ratio = nullptr`, passes through when metric is RemainingPrecursor
3. `feedResultImpl_()` declares `double remaining_ratio = -1.0`, passes `&remaining_ratio` to `computeExplorationScore_()`, copies to `info.remaining_ratio`
4. `FeedResultInfo` gains `double remaining_ratio = -1.0`
5. `writeScanResultRow_()` gains a `double remaining_ratio` parameter, writes it as the final column
6. TSV header gains `\tremaining_ratio` at the end

### Files to modify

| File | Change |
|------|--------|
| `Exploration.h:118-131` | Add `double remaining_ratio = -1.0` to `FeedResultInfo` |
| `Exploration.h:192-201` | Add `double* out_remaining_ratio = nullptr` parameter to `computeExplorationScore_()` and `computeRemainingPrecursorScore_()` |
| `Exploration.cpp:483-499` | Pass `out_remaining_ratio` through to `computeRemainingPrecursorScore_()` |
| `Exploration.cpp:506-542` | Set `*out_ratio = ratio` at line 536 (when pointer non-null) |
| `Exploration.cpp:~211` | In `feedResultImpl_()`: pass `&remaining_ratio` to `computeExplorationScore_()`, copy to `info.remaining_ratio` |
| `FLASHIda.cpp:96-102` | Append `\tremaining_ratio` to TSV header |
| `FLASHIda.cpp:309-353` | Add `double remaining_ratio` parameter to `writeScanResultRow_()`, write it |
| `FLASHIda.cpp:632-646` | MS2 exploration path: pass `info.remaining_ratio` |
| `FLASHIda.cpp:746-763` | MS3 exploration path: pass `info.remaining_ratio` |
| `FLASHIda.cpp` (all other `writeScanResultRow_` call sites) | Pass `-1.0` |

### Special cases in `computeRemainingPrecursorScore_()`

| Condition | Score returned | Ratio output |
|-----------|---------------|--------------|
| No raw data (length <= 0) | 0.0 | not set (stays -1.0) |
| Baseline not yet received | -2.0 | not set (stays -1.0) |
| Baseline intensity <= 0 | -1.0 | not set (stays -1.0) |
| Normal computation | 1.0 - \|ratio - target\| | ratio value |

### C++ tests

Extend existing test sections in `FLASHIda_exploration_test.cpp`:

**1. `remaining_precursor_score_with_raw_data` (lines 1154-1200)**
- After feeding baseline (CE=0) and CE=20 variant via `feedResult()`, assert `info.remaining_ratio` is in valid range `[0.0, 1.0]`
- Compute expected ratio from test data: baseline in-window = sum of {790,800,810} intensities within isolation window; CE=20 in-window = sum of reduced intensities; ratio = CE20_sum / baseline_sum
- Assert `info.remaining_ratio` matches expected within tolerance

**2. `remaining_precursor_target_aware_scoring` (lines 1362-1402)**
- Baseline = 1000.0 at mz_center. Perfect variant = 100.0 (ratio = 0.1). Over variant = 500.0 (ratio = 0.5)
- Assert `info_perfect.remaining_ratio` ~ 0.1
- Assert `info_over.remaining_ratio` ~ 0.5

**3. `remaining_precursor_score_no_raw_data` (lines 1108-1152)**
- Uses `feedResultForTest()` (no raw data path) — ratio should be -1.0
- Assert `info.remaining_ratio` == -1.0

**4. `remaining_precursor_score_no_signal_in_window` (lines 1202-1241)**
- Baseline has zero in-window signal — ratio should be -1.0 (baseline failure)
- Assert `info.remaining_ratio` == -1.0

**5. Non-RemainingPrecursor metric test**
- In existing `winner_selection_by_score` test (mass_count metric): assert `info.remaining_ratio` == -1.0

### No C# changes needed

C# does not parse results.tsv. The column is consumed by downstream Python/R scripts.

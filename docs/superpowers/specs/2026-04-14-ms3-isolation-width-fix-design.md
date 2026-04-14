# Fix MS3 Exploration Isolation Width

## Goal

Fix MS3 RemainingPrecursor exploration scoring, which always returns -1 because `group.isolation_width` is 0.0 for MS3 exploration groups.

## Background

`initiateNextLevel()` (Exploration.cpp:431-436) builds a synthetic single-peak PeakGroup for each MS3 fragment target, using only the center m/z. When `initiate()` calls `pg.getMzRange(charge)`, it gets `(mz, mz)` and computes `isolation_width = 0.0`. This zero width causes:

1. Baseline computation (line 231-243): zero-width window matches no peaks, `baseline_intensity = 0.0`
2. All subsequent variants hit `if (reference <= 0.0) return -1.0` (line 544)

Meanwhile, `buildMS3()` in ScanCommandQueue.cpp:312 correctly floors the instrument isolation width at `std::max(iso_width, 2.0)`, but this floor never reaches the exploration group.

The fragment analysis functions (`getTopFragmentMatches`, `getTerminalFragmentIons`, `getAmbiguityEnclosingIons`) return `wstarts[]`/`wends[]` arrays computed as `pg.getMzRange(charge) +/- 0.4 Da margin` (FragmentAnalysis.cpp:58, `optimal_window_margin_ = 0.4`). These represent the actual isolation window bounds for the instrument.

## Fix

Two changes in `Exploration.cpp`:

### 1. `initiateNextLevel()` (line 431-436): Push two peaks instead of one

Before:
```cpp
PeakGroup frag_pg(std::abs(charges[ti]), std::abs(charges[ti]), true);
frag_pg.setMonoisotopicMass(masses[ti]);
FLASHHelperClasses::LogMzPeak lp;
lp.mz = (wstarts[ti] + wends[ti]) / 2.0;
lp.abs_charge = std::abs(charges[ti]);
frag_pg.push_back(lp);
```

After:
```cpp
PeakGroup frag_pg(std::abs(charges[ti]), std::abs(charges[ti]), true);
frag_pg.setMonoisotopicMass(masses[ti]);
int abs_charge = std::abs(charges[ti]);
FLASHHelperClasses::LogMzPeak lp_lo;
lp_lo.mz = wstarts[ti];
lp_lo.abs_charge = abs_charge;
frag_pg.push_back(lp_lo);
FLASHHelperClasses::LogMzPeak lp_hi;
lp_hi.mz = wends[ti];
lp_hi.abs_charge = abs_charge;
frag_pg.push_back(lp_hi);
```

Now `pg.getMzRange(charge)` returns `(wstarts[ti], wends[ti])` and `isolation_width = wends - wstarts`, matching the actual instrument isolation window.

### 2. `initiate()` (after line 80): Apply 2.0 Da floor

After:
```cpp
double isolation_width = mz2 - mz1;
```

Add:
```cpp
isolation_width = std::max(isolation_width, 2.0);
```

This matches `buildMS3()`'s floor (ScanCommandQueue.cpp:312) and also protects MS2 against edge cases where a very narrow isotope envelope produces a sub-2 Da width.

## Files to modify

| File | Change |
|------|--------|
| `Exploration.cpp:431-436` | Push two peaks (`wstarts[ti]`, `wends[ti]`) instead of one center peak |
| `Exploration.cpp:80` | Add `isolation_width = std::max(isolation_width, 2.0)` after width computation |
| `FLASHIda_exploration_test.cpp` | Add test for narrow-PeakGroup scoring with 2.0 Da floor |

## Testing

### Existing test impact

- `remaining_precursor_target_aware_scoring`: Uses a PeakGroup with known width. The 2.0 Da floor should not affect this test if the existing window is >= 2.0 Da. Verify.

### New test: narrow PeakGroup triggers 2.0 Da floor

Construct a PeakGroup with a single peak (or two peaks < 2.0 Da apart), initiate exploration, feed baseline + one variant. Assert:
- `group.isolation_width` is 2.0 (floored)
- Baseline intensity is computed correctly (non-zero, using 2.0 Da window)
- Variant score is a real value (not -1.0)

## No C# changes needed

This is a C++ scoring bug. The instrument commands were already correct (buildMS3 has the floor).

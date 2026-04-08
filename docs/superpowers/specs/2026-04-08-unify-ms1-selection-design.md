# Unify MS1 Precursor Selection

**Date:** 2026-04-08
**Status:** Approved

## Problem

MS1 precursor count limiting has two independent code paths that both run but serve the same purpose:

1. **Legacy:** `MaxMs2CountPerMs1` in `<MSSettings>` → JSON `precursor_selection.max_mass_count` → C++ `mass_count_[0]` → hard break in `filterPeakGroupsUsingMassExclusion_` (line 696)
2. **Phase 7:** `<SelectionStrategy><MS1><MaxPrecursors>` → JSON `selection_strategy.ms1.max_precursors` → C++ `level_configs_[1].max_targets` → **never read for MS1**

The entire `<SelectionStrategy><MS1>` block (both `Selection` and `MaxPrecursors`) is dead config — parsed and stored but never queried. Only the legacy `mass_count_` actually caps MS1 precursors.

Additionally, MS1 precursor selection always sorts by QScore (or IDScore when enabled). There is no option to sort by intensity.

## Goal

1. Make `level_configs_[1].max_targets` the single source of truth for the MS1 precursor cap
2. Remove `MaxMs2CountPerMs1` from XML, C#, and C++ entirely
3. Add intensity-based MS1 selection as an alternative to QScore
4. Support `Selection=none` to skip MS1 precursor selection entirely
5. Preserve all existing behavior (targeting, exclusion, dynamic exclusion, tie-breaking, IDScore)

## Design

### C++ changes

#### `filterPeakGroupsUsingMassExclusion_` (`FLASHIda.cpp:553`)

**Cap source:** Replace `mass_count_[ms_level - 1]` (line 591) with `getLevelConfig_(ms_level).max_targets`. The break condition at line 696 stays identical.

**Intensity sort branch:** Currently the function has a 6-way branch (lines 555-572) for IDScore/QScore/AllCharges combinations. Restructure to:

```
if (use_idscore_)
  → 4 existing IDScore branches (unchanged — IDScore replaces QScore, not intensity)
else if (selection == Intensity)
  → if consider_all_Charge_states_: sortByIntensityAllCharges()
  → else: sortByIntensity()
else (default: QScore)
  → if consider_all_Charge_states_: sortByQScoreAllCharges()
  → else: sortByQscore()
```

IDScore is a drop-in replacement for QScore only. When `Selection=intensity`, the sort order is by intensity. IDScore does not override intensity sorting. However, the per-peak-group charge/HCD selection logic (lines 700-718) still uses IDScore when enabled regardless of selection metric.

Dynamic exclusion and TQScore filtering always use QScore/IDScore — intensity never feeds into exclusion decisions.

#### `processScan` MS1 path (`FLASHIda.cpp:3298`)

Before calling `getPeakGroups`, check:
```cpp
if (getLevelConfig_(1).selection == SelectionMetric::None)
  return 0;
```

This skips deconvolution and produces no MS2 follow-ups.

#### `parseJSONConfig_` (`FLASHIda.cpp:2791-2793`)

Remove the `mass_count_` parsing block:
```cpp
// DELETE:
auto mass_count_arr = ps.value("max_mass_count", std::vector<int>{1});
for (int j : mass_count_arr)
  mass_count_.push_back(j);
```

`level_configs_` already parses `max_precursors`/`max_targets` from `selection_strategy`.

#### `FLASHIda.h`

Remove `IntList mass_count_;` member (line 743).

#### `DeconvolvedSpectrum.h/.cpp`

Add two new sort methods (analogous to existing `sortByQscore()`/`sortByQScoreAllCharges()`):
- `sortByIntensity()` — sort by `getIntensity()` descending
- `sortByIntensityAllCharges()` — sort by `getIntensity()` descending (same implementation; intensity is not charge-dependent, but the method exists for API symmetry with the QScore variants)

#### `filterPeakGroupsUsingMassExclusion_` needs `selection` access

Currently `filterPeakGroupsUsingMassExclusion_` takes `(int ms_level, double rt)`. It needs access to the selection metric. Options:
- Read `getLevelConfig_(ms_level).selection` directly (it's a member function on `FLASHIda`, and `filterPeakGroupsUsingMassExclusion_` is a private method — no signature change needed)

### C# changes

#### Remove `MaxMs2CountPerMs1`

| File | Change |
|------|--------|
| `MethodConfig.cs:105` | Remove `public int MaxMs2CountPerMs1 = 4;` from `MSSettingsConfig` |
| `MethodConfig.cs:211` | Remove `public int[] max_mass_count { get; set; }` from `JsonPrecursorSelectionConfig` |
| `Parameter.cs:16` | Remove `public int MaxMs2CountPerMs1 { set; get; }` from `IDAParameters` |
| `Parameter.cs:15` | Remove `[Description("Maximum number of MS2 scans per MS1 cycle")]` |
| `Parameter.cs:104` | Remove `MaxMs2CountPerMs1 = maxMs2CountPerMs1;` and `maxMs2CountPerMs1` constructor parameter |
| `Parameter.cs:171` | Remove `max_mass_count = new int[] { MaxMs2CountPerMs1 },` from `ToJSON()` |
| `Parameter.cs:264` | Change `ss.MS1?.MaxPrecursors ?? MaxMs2CountPerMs1` to `ss.MS1?.MaxPrecursors ?? 10` |
| `MethodParameters.cs:133` | Remove `IDA.MaxMs2CountPerMs1 = MSSettings.MaxMs2CountPerMs1;` from `InitializeIDA()` |
| `MethodParameters.cs:273` | Remove `MaxMs2CountPerMs1` from `ToLogString()` MS settings format string |

### XML changes

#### Remove `<MaxMs2CountPerMs1>` and set `<MaxPrecursors>` to match

In all 21 XML files: remove `<MaxMs2CountPerMs1>` from `<MSSettings>`, set `<MaxPrecursors>` in `<SelectionStrategy><MS1>` to the value that `MaxMs2CountPerMs1` had (preserving existing effective behavior).

The base `method.xml` has no `<SelectionStrategy>` block — one must be added.

| File | Old MaxMs2CountPerMs1 | New MaxPrecursors |
|------|----------------------|-------------------|
| `src/Flash/etc/method.xml` | 1 | 1 |
| `method_deep.xml` | 5 | 5 |
| `method_default_legacy.xml` | 1 | 1 |
| `method_default_topn5.xml` | 5 | 5 |
| `method_default.xml` | 1 | 1 |
| `method_exclusion.xml` | 5 | 5 |
| `method_exploration_ms3.xml` | 1 | 1 |
| `method_exploration.xml` | 1 | 1 |
| `method_faims_3cv.xml` | 3 | 3 |
| `method_faims_skip.xml` | 3 | 3 |
| `method_inclusion_strict.xml` | 5 | 5 |
| `method_inclusion.xml` | 5 | 5 |
| `method_json_roundtrip.xml` | 3 | 3 |
| `method_ms3_mode1_hcd.xml` | 1 | 1 |
| `method_ms3_mode1.xml` | 1 | 1 |
| `method_ms3_mode2_hcd.xml` | 1 | 1 |
| `method_ms3_mode2.xml` | 1 | 1 |
| `method_ms3_mode3_hcd.xml` | 1 | 1 |
| `method_ms3_mode3.xml` | 1 | 1 |
| `method_quant.xml` | 1 | 1 |
| `method_tag_targeting.xml` | 5 | 5 |

Note: `method_default.xml` previously had `MaxMs2CountPerMs1=1` but `MaxPrecursors=5`. Since `MaxMs2CountPerMs1` was the one actually taking effect, `MaxPrecursors` changes from 5 to 1. Similarly, the exploration configs drop from 10 to 1.

### C++ test JSON updates

All embedded JSON configs in `FLASHIda_ProcessScan_test.cpp` (and other test files):
- Remove `"max_mass_count": [N]` from `precursor_selection`
- Ensure `selection_strategy.ms1.max_precursors` (or `max_targets`) carries the value

### What doesn't change

- `IDAParameters.HCDEnergy`, `UseIDScore`, `ConsiderAllChargeStates` — developer settings unchanged
- Dynamic exclusion / TQScore filtering logic — always uses QScore/IDScore
- Targeting modes (inclusion, exclusion, deep) — unchanged
- Priority tie-breaking for TSV targets — unchanged
- Per-peak-group charge/HCD selection (lines 700-718) — unchanged, still uses IDScore when enabled
- `selection_strategy.ms2` and `selection_strategy.ms3` — unchanged
- JSON `selection_strategy` structure — unchanged
- MS2/MS3 paths — unchanged

## Testing

### C++ unit tests (`FLASHIda_ProcessScan_test.cpp`)

- Update all embedded JSON configs: remove `max_mass_count`, ensure `selection_strategy.ms1.max_precursors` carries the value
- **New: intensity selection** — same MS1 input, configure `selection: "intensity"`, verify returned precursors are ordered by intensity (highest first) rather than QScore
- **New: none selection** — feed MS1 with `selection: "none"`, verify 0 commands returned
- **New: varied max_precursors** — configure max_precursors to 1, 3, 5 with same input, verify exact command counts match the cap
- Existing tests produce identical results (they use qscore selection, same cap values)

### C# acquisition loop continuity tests (AL-CT series)

- **AL-CT08** ("MS2 count respects TopN config") is the primary validation — after XML migration, confirms cap still works through full C#→C++ path
- All behavioral reference tests (AL-CT06, CT15, CT16, etc.) must pass unchanged — golden files are identical since effective cap values are preserved
- **New: intensity selection continuity test** — feed MS1 with a config using `Selection=intensity`, verify MS2 precursors are intensity-ordered

## Files to modify

| File | Change |
|------|--------|
| `OpenMS/.../FLASHIda.cpp` | Read cap from `level_configs_`, restructure sort branches, add none check, remove `mass_count_` parsing |
| `OpenMS/.../FLASHIda.h` | Remove `mass_count_` member |
| `OpenMS/.../DeconvolvedSpectrum.h` | Add `sortByIntensity()`, `sortByIntensityAllCharges()` declarations |
| `OpenMS/.../DeconvolvedSpectrum.cpp` | Add `sortByIntensity()`, `sortByIntensityAllCharges()` implementations |
| `OpenMS/.../FLASHIda_ProcessScan_test.cpp` | Update JSON configs, add new tests |
| `FlashIDA/src/Flash/MethodConfig.cs` | Remove `MaxMs2CountPerMs1` from `MSSettingsConfig`, remove `max_mass_count` from `JsonPrecursorSelectionConfig` |
| `FlashIDA/src/Flash/MethodParameters.cs` | Remove from `InitializeIDA()` and `ToLogString()` |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Remove from `IDAParameters`, constructor, `ToJSON()`, update `BuildSelectionStrategy` fallback |
| `FlashIDA/src/Flash/etc/method.xml` | Remove `MaxMs2CountPerMs1`, add `SelectionStrategy` block |
| `FlashIDA/test-data/configs/method_*.xml` (20 files) | Remove `MaxMs2CountPerMs1`, update `MaxPrecursors` values |

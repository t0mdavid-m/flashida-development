# processScan Cleanup Design (Round 2)

## Goal

Thirteen incremental improvements to `FLASHIda::processScan()`, `getNextScanCommand()`, and supporting classes. Covers timing semantics, FAIMS CV propagation, exploration flow, config validation, scan construction consolidation, real exploration scoring, unified MS3 targeting under `SelectionMetric`, legacy config removal, and dead code elimination.

## Branch

`phase-11` (single pass, all 13 items)

## Architecture

Changes span C++ (OpenMS, `flashida-v9-bridge` branch) and C# (FlashIDA, `phase-11` branch). The core changes are:

1. **Consolidate scan construction** — single `buildMS2` factory with explicit `ScanConfig` and priority
2. **Real exploration scoring** — `feedResult` owns deconvolution; `computeRemainingPrecursorScore_` and `computeFragmentCount_` get real implementations
3. **Unified MSn targeting** — `SelectionMetric` extended with `TerminalFragments` and `AmbiguityResolution`; `initiateNextLevel` uses `FragmentAnalysis` for fragment-aware targeting; legacy `selectMS3Targets_`/`ms3_mode`/`ms3_enabled` deleted
4. **Config migration** — `max_precursors`/`max_fragments` → `max_targets`; MS3 fields removed from `TargetingConfig`; ~21 JSON configs updated

## Implementation Waves

Dependency-ordered:

| Wave | Items | Theme |
|------|-------|-------|
| 1 | 1, 2, 4, 6 | Independent renames and refactors |
| 2 | 5, 7, 8, 9 | Exploration improvements (chain: 5 → 7,8 → 9) |
| 3 | 10, 11, 12, 13 | MS3 unification (chain: 10 → 11 → 12 → 13) |
| 4 | 3 | Inline processMS2Path_ (last — all other items reference its internals) |

## Validation Rules

Added to `Config::validate()`:

1. `targeting_.use_idscore && exploration_enabled_` → throw (IDScore vs exploration conflict)
2. Exploration at level N with `scans.size() != 1` → throw
3. `conditional_ms2_enabled` without `tagging.follow_up_scan` → throw
4. **Any level ≥ 2 with `SelectionMetric != None`** → require `protein_sequence` non-empty (fragment matching is default behavior for all MSn≥2 selection)
5. **Any level with `ExplorationMetric::FragmentCount`** → require `protein_sequence` non-empty

## Testing Strategy

| Item | Test approach |
|------|---------------|
| 1 (FAIMS guard) | Existing tests cover |
| 2 (priority param) | Update existing call sites in tests |
| 3 (inline processMS2Path_) | Pure refactor, existing tests cover |
| 4 (max_targets rename) | Update JSON in existing test configs |
| 5 (deconv into feedResult) | Update `FLASHIda_exploration_test` for new `feedResult` signature |
| 6 (rename deconvolveMSn) | Mechanical rename, existing tests cover |
| 7 (real RemainingPrecursor) | **New unit tests** in `FLASHIda_exploration_test` |
| 8 (real FragmentCount) | **New unit tests** in `FLASHIda_exploration_test` |
| 9 (TSV logging) | Update existing logging test expectations |
| 10 (fragment-aware initiateNextLevel) | Update exploration_test for fragment targeting |
| 11 (SelectionMetric extension) | **Extend** config parsing tests: new enum values, validation throws |
| 12 (remove legacy MS3 fields) | **Extend** config tests: old fields ignored/rejected |
| 13 (collapse Step 5) | Existing `FLASHIda_ProcessScan_test::processScan_ms3_commands` and exploration_test MS3 sections cover |

No new test files — all tests extend existing binaries.

---

## Item 1: Remove Redundant FAIMS CV Guard

### Problem

`FLASHIda.cpp:516` has `double parent_cv = config_.faims().enabled ? faims_cv : 0.0;`. The bridge passes `faims_cv = 0.0` when FAIMS is inactive, making the ternary redundant.

### Design

Replace with `double parent_cv = faims_cv;` or use `faims_cv` directly at call sites and remove `parent_cv`.

### Files

- `FLASHIda.cpp:516`

---

## Item 2: Add Priority Parameter to Scan Builders

### Problem

Priority is hardcoded per builder method (`buildMS2` → 1, `buildMS3` → 3, etc.). Priority is a scheduling concern decided by the caller, not a property of the scan type.

### Design

Add `int priority` parameter to `buildMS2`, `buildMS3`, `buildFollowUp`. Callers pass priority explicitly. Remove hardcoded priority from builder implementations.

### Files

- `ScanCommandQueue.h/.cpp` — add parameter
- `FLASHIda.cpp`, `Exploration.cpp` — pass priority at all call sites

---

## Item 3: Inline `processMS2Path_`

### Problem

`processMS2Path_` is called exactly once (line 602). The indirection splits `processScan` into two places with no reuse.

### Design

Replace the call at line 602 with the method body from lines 675+. Delete the method definition and declaration.

**Must be done last** — all other items reference line numbers inside this method.

### Files

- `FLASHIda.cpp:602` — inline body
- `FLASHIda.cpp:675+` — delete definition
- `FLASHIda.h:233` — delete declaration

---

## Item 4: Rename `max_precursors`/`max_fragments` → `max_targets`

### Problem

`max_precursors` (MS1) and `max_fragments` (MS2/MS3) are the same field — how many targets to select. Different names per level are misleading.

### Design

**C++ Config.cpp:292-295** — remove alias chain, read `"max_targets"` only.

**C# MethodConfig.cs:**
- `MS1SelectionConfig.MaxPrecursors` → `MaxTargets` with `[JsonKey("max_targets")]`
- `MS2SelectionConfig.MaxFragments` → `MaxTargets` with `[JsonKey("max_targets")]`
- `MS3SelectionConfig.MaxFragments` → `MaxTargets` with `[JsonKey("max_targets")]`

**C# MethodParameters.cs:236-302** — serialize as `max_targets` at all levels.

**~21 JSON config files** — rename `"max_precursors"` and `"max_fragments"` to `"max_targets"`.

### Files

- `Config.cpp:292-295`
- `MethodConfig.cs:277-306`
- `MethodParameters.cs:236-302`
- All JSON configs in `FlashIDA/test-data/configs/` and `FlashIDA/src/Flash/etc/`

---

## Item 5: Move MS2 Deconvolution into `Exploration::feedResult`

### Problem

The exploration path in `FLASHIda.cpp:688-701` deconvolves MS2 with dummy values (mass=0.0, charge=0) because the precursor context lives inside `ExplorationGroup`. Exploration should own this deconvolution step.

### Design

**New `feedResult` signature:**
```cpp
std::vector<ScanCommand> feedResult(int tracking_id,
    const double* mzs, const double* ints, int length,
    double rt, ScanCommandQueue& queue);
```

**Exploration gains `Deconvolution&` member** (set in constructor). `feedResult` looks up the group first, then calls `deconv_.deconvolveMSn(mzs, ints, length, rt, group.precursor_mass, group.precursor_charge)` with the correct precursor context.

**Caller simplifies to:**
```cpp
auto cmds = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);
```

### Files

- `Exploration.h` — add `Deconvolution&` member, update `feedResult` signature
- `Exploration.cpp` — `feedResult` deconvolves internally
- `FLASHIda.cpp:688-701` — simplify to single call
- `FLASHIda.h/.cpp` — pass `deconv_` to `Exploration` constructor

---

## Item 6: Rename `deconvolveMS2` → `deconvolveMSn`

### Problem

The method deconvolves any MSn>1 spectrum (MS2, MS3, exploration results). The name should reflect this.

### Design

Mechanical rename at all sites. Keep `deconvolveMS2Py` name for Python backwards compat.

### Files

- `Deconvolution.h:84` — rename
- `Deconvolution.cpp:73` — rename definition
- `Deconvolution.cpp:139` — update internal call in `deconvolveMS2Py`
- `FLASHIda.cpp:621,695,731` — rename 3 call sites
- `PrecursorSelection.h:160`, `PrecursorSelection.cpp:906` — update doc comments

---

## Item 7: Rewrite `computeRemainingPrecursorScore_`

### Problem

Current implementation (`Exploration.cpp:313-320`) just sums TIC. Doesn't actually measure remaining precursor intensity.

### Design

**Correct logic:**
1. Take precursor m/z ± isolation_width/2 from the ExplorationGroup
2. In the raw MSn spectrum (mzs/ints passed to `feedResult` via item 5), sum intensity within that window — this is the unfragmented precursor signal
3. Compare to reference intensity from `PeakGroup::getChargeIntensity(charge)`
4. Score = 1.0 - (remaining/reference), clamped to [0, 1]. Higher = less remaining precursor = better fragmentation

**Signature change** — needs raw spectrum data and group context (available after item 5 moves deconvolution into `feedResult`):
```cpp
double computeRemainingPrecursorScore_(const ExplorationGroup& group,
    const double* mzs, const double* ints, int length) const;
```

**New config field:** `remaining_precursor_target` in exploration config (default 0.1). Add to `MSLevelConfig` and parse from JSON.

### Files

- `Exploration.h` — updated signature
- `Exploration.cpp:313-320` — real implementation
- `Config.h` — add `remaining_precursor_target` to `MSLevelConfig`
- `Config.cpp` — parse from exploration JSON section

### Tests

New unit tests in `FLASHIda_exploration_test.cpp`:
- Spectrum with no precursor signal → score near 1.0
- Spectrum with 100% precursor signal → score near 0.0
- Spectrum with 10% precursor signal → score near target

---

## Item 8: Make `computeFragmentCount_` Use Sequence-Aware Matching

### Problem

`computeFragmentCount_` (`Exploration.cpp:322-325`) returns `spec.size()` — identical to `computeMassCount_`. No sequence awareness.

### Design

**Exploration gains `FragmentAnalysis&` member** (set in constructor, same dependency as item 10).

`computeFragmentCount_` calls `fragment_analysis_.getTopFragmentMatches(config_.targeting().protein_sequence, ...)` on the deconvolved spectrum, returns the match count.

**Validation** (rule 5): if any level uses `ExplorationMetric::FragmentCount`, `protein_sequence` must be non-empty.

### Files

- `Exploration.h` — add `FragmentAnalysis&` member
- `Exploration.cpp:322-325` — real implementation
- `Config.cpp::validate()` — add rule 5
- `FLASHIda.h/.cpp` — pass `fragments_` to `Exploration` constructor

### Tests

New unit tests in `FLASHIda_exploration_test.cpp`:
- Spectrum with known fragment ions → count matches expected
- Spectrum with no matches → returns 0

---

## Item 9: Log Exploration Metrics to Results TSV

### Problem

The exploration path (`FLASHIda.cpp:689-701`) returns early without calling `writeScanResultRow_`. Exploration results are invisible in the results TSV.

### Design

**Extend TSV header** with `tic_coverage` and `fragment_count` columns (12 total):
```
tracking_id  resolve_ts  duration_ms  rt  mass_count  commands_pushed  child_ids  tag_count  matched_protein  proteoform_sequence  tic_coverage  fragment_count
```

**Extend `writeScanResultRow_` signature** with `float tic_coverage = 0.0f, int fragment_count = 0`.

**Add `writeScanResultRow_` call** for exploration variants in `feedResult` path, passing actual values from `ExplorationVariant`.

Existing call sites pass defaults (0.0f, 0) for now.

### Files

- `FLASHIda.h:268-272` — extended signature
- `FLASHIda.cpp:96-98` — extended header
- `FLASHIda.cpp:326-335` — append new columns
- `FLASHIda.cpp:699-701` — add call for exploration path

---

## Item 10: Fragment-Aware `initiateNextLevel` with `SelectionMetric`

### Problem

`initiateNextLevel` (`Exploration.cpp:236-280`) always sorts by intensity and targets raw deconvolved masses. It should target fragment ions via `FragmentAnalysis` and sort by the configured `SelectionMetric`.

### Design

**Fragment matching is the default behavior** for all MSn≥2 selection. No fallback to raw deconvolved masses — `Config::validate()` requires `protein_sequence` when any level ≥ 2 has `SelectionMetric != None` (rule 4).

**`initiateNextLevel` changes:**
1. Call `fragment_analysis_.getTopFragmentMatches()` (for `Intensity`/`QScore`) or specialized methods (for `TerminalFragments`/`AmbiguityResolution` — item 11)
2. Sort matched fragments by the configured `SelectionMetric`:
   - `Intensity` → sort by intensity
   - `QScore` → sort by qscore
3. Select top `max_targets` fragments as MSn+1 targets
4. Build commands via `queue.buildMS2()` for each target

**Exploration gains `FragmentAnalysis&` member** (shared with item 8).

### Files

- `Exploration.h` — `FragmentAnalysis&` member (shared with item 8)
- `Exploration.cpp:236-280` — rewrite to use `FragmentAnalysis`
- `Config.cpp::validate()` — add rule 4

---

## Item 11: Unify MS3 Targeting into `SelectionMetric`

### Problem

Two parallel MS3 targeting systems: legacy `ms3_mode` (integer 0-4) with `selectMS3Targets_`, and new `SelectionMetric` per-level. Legacy modes map directly to `SelectionMetric` values.

### Design

**Extend `SelectionMetric` enum:**
```cpp
enum class SelectionMetric
{
  None = 0,
  Intensity,            // rank by raw intensity
  QScore,               // rank by qscore
  TerminalFragments,    // innermost b/y ions, interleaved (was ms3_mode=3)
  AmbiguityResolution   // PTM-site bracketing ions (was ms3_mode=2)
};
```

**Config parsing** (`Config.cpp:287-290`): add `"terminal_fragments"` and `"ambiguity_resolution"` string mappings.

**`initiateNextLevel`** dispatches on `SelectionMetric`:
- `Intensity`/`QScore` → `getTopFragmentMatches()`, sort by metric (item 10)
- `TerminalFragments` → `getTerminalFragmentIons()` 
- `AmbiguityResolution` → `getAmbiguityEnclosingIons()`

Activation type comes from the level's `ScanConfig`, not hardcoded per mode.

**Delete:**
- `selectMS3Targets_()` definition (`FLASHIda.cpp:631-673`) and declaration (`FLASHIda.h:230`)
- `MS3Target` typedef (`FLASHIda.h:227`)
- Legacy branch in processMS2Path_ (`FLASHIda.cpp:775-786`)

**Legacy mode mapping** (for reference — all modes now use fragment matching after item 10):
- Mode 0 (disabled) → `SelectionMetric::None`
- Mode 1 (SourceCID) → `Intensity` (was raw masses, now fragment-aware)
- Mode 2 (SPS) → `Intensity` (was raw masses, now fragment-aware)
- Mode 3 (HCD-triggered fragment matching) → `Intensity` or `QScore` (fragment matching is now default for all)
- Mode 4 (EThcD-triggered terminal ions) → `TerminalFragments`
- `AmbiguityResolution` is NEW — wires in `getAmbiguityEnclosingIons` which was implemented but never reachable

**JSON config migration:**
- `"ms3": { "mode": 1 }` → `"selection_strategy": { "ms2": { "selection": "intensity" } }`
- `"ms3": { "mode": 2 }` → `"selection_strategy": { "ms2": { "selection": "intensity" } }`
- `"ms3": { "mode": 3 }` → `"selection_strategy": { "ms2": { "selection": "intensity" } }` (fragment matching is now implicit)
- `"ms3": { "mode": 4 }` → `"selection_strategy": { "ms2": { "selection": "terminal_fragments" } }`

**C# MethodConfig.cs:**
- `Ms3Config.Mode` → removed
- `SelectionStrategy` selection string options updated to include new values

### Files

- `Config.h:49-54` — extend enum
- `Config.cpp:287-290` — parse new strings
- `Config.cpp::validate()` — rules 4 (already from item 10)
- `Exploration.cpp::initiateNextLevel` — dispatch on new metrics
- `FLASHIda.h:227-230` — delete MS3Target, selectMS3Targets_
- `FLASHIda.cpp:631-673` — delete selectMS3Targets_ body
- `FLASHIda.cpp:775-786` — delete legacy branch
- `MethodConfig.cs` — remove Mode from Ms3Config
- `MethodParameters.cs` — remove ms3.mode serialization
- ~21 JSON configs — migrate ms3.mode to selection_strategy

### Tests

Extend config tests:
- Parse `"terminal_fragments"` → `SelectionMetric::TerminalFragments`
- Parse `"ambiguity_resolution"` → `SelectionMetric::AmbiguityResolution`
- Validation: `TerminalFragments` at level 2 without `protein_sequence` → throws
- Validation: `AmbiguityResolution` at level 2 without `protein_sequence` → throws

---

## Item 12: Remove Legacy MS3 Config Fields from `TargetingConfig`

### Problem

After item 11, `ms3_enabled`, `max_ms3_per_ms2`, and `ms3_all_charges` are dead fields. MS3 is fully configured through `selection_strategy`.

### Design

**Remove from `TargetingConfig` (`Config.h:126-155`):**
- `ms3_all_charges` (line 134)
- `ms3_enabled` (line 139)
- `ms3_mode` (line 140 — already removed by item 11)
- `max_ms3_per_ms2` (line 141)

**MS3 is implied** when `selection_strategy` at the MS2 level has `selection != None` (selecting targets from MS2 results produces MS3 scans).

**`max_ms3_per_ms2`** replaced by `MSLevelConfig::max_targets` at the ms2 level in `selection_strategy`.

**`protein_sequence` stays** in `TargetingConfig` — items 8, 10, 11 all reference it there.

**Remove from parsing** (`Config.cpp:159-168`): `ms3_enabled`, `ms3_mode`, `ms3_all_charges` parsing.

**Reject legacy keys** — after parsing, check if the `ms3` JSON object contains any of the removed keys (`enabled`, `mode`, `all_charges`, `max_per_ms2`). If so, throw `std::invalid_argument` with a message telling the user to migrate to `selection_strategy`. This forces config migration rather than silently ignoring stale fields.

**JSON config migration:**
- Remove `ms3.enabled`, `ms3.mode`, `ms3.all_charges`, `ms3.max_per_ms2`
- Set `selection_strategy.ms2.max_targets` instead of `ms3.max_per_ms2`
- Keep `ms3.protein_sequence`

**C# MethodConfig.cs/MethodParameters.cs:**
- Remove `Ms3Config.Active`, `Ms3Config.Mode`, `Ms3Config.AllCharges`, `Ms3Config.MaxPerMs2`
- Remove `JsonMs3Config.enabled`, `JsonMs3Config.mode`, `JsonMs3Config.max_per_ms2`

### Files

- `Config.h:134-141` — remove 4 fields
- `Config.cpp:159-168` — remove parsing
- `Config.cpp:323` — remove `max_ms3_per_ms2` assignment
- `FLASHIda.cpp:775` — remove `ms3_enabled` guard (already deleted by item 11)
- `MethodConfig.cs` — remove fields from Ms3Config
- `MethodParameters.cs` — remove from JsonMs3Config and ToCppJson
- ~21 JSON configs — remove legacy ms3 fields

### Tests

Extend config tests:
- Config with `ms3.enabled` present → throws `std::invalid_argument` (rejected legacy key)
- Config with `ms3.mode` present → throws
- Config with `ms3.all_charges` present → throws
- Config with `ms3.max_per_ms2` present → throws
- Config with only `ms3.protein_sequence` → accepted (kept field)
- `selection_strategy.ms2.selection = "intensity"` implies MS3 targeting without `ms3.enabled`

---

## Item 13: Simplify Step 5 (MS3 Targeting) in `processMS2Path_`

### Problem

Three branches with duplicated code (`FLASHIda.cpp:763-797`):
1. `hasExploration(3)` → `initiateNextLevel` (line 765-773)
2. `ms3_enabled && ms3_mode > 0` → `selectMS3Targets_` (line 775-786) — deleted by item 11
3. `level(3).selection != None && !ms3_enabled` → `initiateNextLevel` (line 788-797)

After items 11/12, branches 1 and 3 are identical and branch 2 is gone.

### Design

Replace all three branches with:
```cpp
// Step 5: MS3 targeting via selection_strategy
if (config_.level(2).selection != SelectionMetric::None)
{
  auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_);
  for (auto& c : cmds)
  {
    queue_.push(c);
    child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
  }
}
```

Note: checks `config_.level(2).selection` (MS2 level) because MS3 scans are MS2 targets — they're selected at the MS2 level.

### Files

- `FLASHIda.cpp:763-797` — collapse to single branch

---

## File Impact Summary

### C++ (OpenMS)

| File | Items |
|------|-------|
| `Config.h` | 2, 4, 7, 8, 11, 12 |
| `Config.cpp` | 4, 7, 8, 11, 12 |
| `Exploration.h` | 5, 7, 8, 10 |
| `Exploration.cpp` | 5, 7, 8, 9, 10, 11 |
| `FLASHIda.h` | 1, 3, 5, 9, 11 |
| `FLASHIda.cpp` | 1, 2, 3, 5, 6, 9, 11, 13 |
| `ScanCommandQueue.h/.cpp` | 2 |
| `Deconvolution.h/.cpp` | 6 |
| `PrecursorSelection.h/.cpp` | 6 |

### C# (FlashIDA)

| File | Items |
|------|-------|
| `MethodConfig.cs` | 4, 11, 12 |
| `MethodParameters.cs` | 4, 11, 12 |
| ~21 JSON configs | 4, 11, 12 |

### Test Files

| File | Items |
|------|-------|
| `FLASHIda_exploration_test.cpp` | 5, 7, 8, 10, 11 |
| `FLASHIda_ProcessScan_test.cpp` | 2, 4, 13 (existing coverage) |
| Config test sections | 11, 12 |
| Logging test expectations | 9 |

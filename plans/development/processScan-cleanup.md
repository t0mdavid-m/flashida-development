# processScan Cleanup Tasks (Round 2)

Incremental improvements identified during code review.

**Branch:** `phase-11`
**Files:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

---

## 1. Remove redundant FAIMS CV guard

**Goal:** Eliminate the unnecessary `config_.faims().enabled` check when computing the parent CV for exploration.

**Changes:**

- `FLASHIda.cpp:516` — replace:
  ```cpp
  double parent_cv = config_.faims().enabled ? faims_cv : 0.0;
  ```
  with:
  ```cpp
  double parent_cv = faims_cv;
  ```
  Or just use `faims_cv` directly at call sites and remove `parent_cv` entirely.

**Why:** `faims_cv` is passed from the bridge (`processScan(..., double faims_cv)`) and is already `0.0` when FAIMS isn't active. The ternary guard is redundant and obscures this fact.

---

## 2. Add priority parameter to scan builders

**Goal:** Make scan priority explicit in the builder signatures instead of hardcoding it inside each method.

**Current state:** Priority is hardcoded per builder:
- `buildMS1` → 3 (lowest)
- `buildAGCScan` → 0 (highest)
- `buildMS2` → 1
- `buildFollowUp` → 2
- `buildMS3` → 3 (lowest)

**Changes:**

- `ScanCommandQueue.h` — add `int priority` parameter to `buildMS2`, `buildMS3`, `buildFollowUp`
- `ScanCommandQueue.cpp` — use the parameter instead of hardcoded values
- Call sites in `FLASHIda.cpp` and `Exploration.cpp` — pass priority explicitly

**Why:** Priority is a scheduling concern decided by the caller (processScan, exploration), not a property of the scan type. Making it explicit in the signature makes the queueing behavior visible at call sites and allows callers to override when needed (e.g. exploration variants at priority 0).

---

## 3. Inline `processMS2Path_`

**Goal:** Remove the single-use private method `processMS2Path_` and inline its body at the sole call site.

**Changes:**

- `FLASHIda.cpp:602` — replace `return processMS2Path_(mzs, ints, length, rt_min, scan_description);` with the body from lines 675+
- `FLASHIda.cpp:675+` — delete the method definition
- `FLASHIda.h:233` — delete the declaration

**Why:** `processMS2Path_` is called exactly once (line 602). The indirection adds no value — it just splits `processScan` into two places with no reuse. Inlining keeps the MS2 logic visible in the main flow.

---

## 4. Rename `max_precursors` / `max_fragments` to `max_targets`

**Goal:** Use a single consistent name `max_targets` across all config levels instead of level-specific aliases.

**Current state:** C++ `Config.cpp:292-295` already accepts all three names as aliases (falls through `max_targets` → `max_precursors` → `max_fragments`). But C# and all JSON configs still use the old names.

**Changes:**

- **C# `MethodConfig.cs`** — rename `JsonKey("max_precursors")` (line 277) and `JsonKey("max_fragments")` (lines 289, 304) to `JsonKey("max_targets")`; rename `JsonSelectionStrategyLevel.max_precursors`/`max_fragments` (lines 493-494) to single `max_targets`
- **C# `MethodParameters.cs:252-265`** — use `max_targets` instead of both `max_precursors` and `max_fragments`
- **All JSON configs** (~25 files in `FlashIDA/test-data/configs/` and `src/Flash/etc/`) — rename `"max_precursors"` and `"max_fragments"` to `"max_targets"`
- **C++ `Config.cpp:292-295`** — remove the alias chain, just read `"max_targets"` directly

**Why:** `max_precursors` and `max_fragments` are misleading — they're the same field (how many targets to select at that MS level). Using different names per level suggests they do different things. A single `max_targets` is clearer and matches the C++ internal field name.

---

## 5. Move MS2 deconvolution into `Exploration::feedResult`

**Goal:** `feedResult` should own the deconvolution of exploration results, using the correct precursor mass and charge from the stored ExplorationGroup.

**Current flow** (`FLASHIda.cpp:688-701`):
```cpp
DeconvolvedSpectrum ms2_deconv(tracking_id);  // misuses tracking_id as scan_number
if (mzs != nullptr && ints != nullptr && length > 0)
{
  deconv_.deconvolveMS2(mzs, ints, length, rt_min, 0.0, 0);  // wrong: mass=0.0, charge=0
  ms2_deconv = deconv_.storedMS2();
}
auto cmds = exploration_.feedResult(tracking_id, ms2_deconv, rt_min, queue_);
```

**Problems:**
- `deconvolveMS2` gets dummy mass=0.0 and charge=0 instead of the actual precursor values
- `ExplorationGroup` already stores `precursor_mass`, `precursor_charge`, and `precursor_pg` — the correct values are available inside Exploration
- Caller is doing deconvolution work that Exploration should own

**New signature:**
```cpp
std::vector<ScanCommand> feedResult(int tracking_id,
    const double* mzs, const double* ints, int length,
    double rt, ScanCommandQueue& queue);
```

**Changes:**

- `Exploration.h` — add `Deconvolution&` member (set in constructor)
- `Exploration.cpp` — `feedResult` deconvolves internally: look up group first, then call `deconv_.deconvolveMS2(mzs, ints, length, rt, group.precursor_mass, group.precursor_charge)`
- `FLASHIda.cpp:688-701` — replace with `auto cmds = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);`
- `FLASHIda.h` / `FLASHIda.cpp` — pass `deconv_` to Exploration constructor

**Why:** Exploration owns the context (precursor mass/charge) and the scoring — it should also own the deconvolution step. The current code passes dummy values (0.0, 0) which means deconvolution runs without proper precursor context.

---

## 6. Rename `deconvolveMS2` to `deconvolveMSn`

**Goal:** The method deconvolves any MSn>1 spectrum (MS2, MS3, exploration results) — the name should reflect this.

**Changes:**

- `Deconvolution.h:84` — rename `deconvolveMS2` → `deconvolveMSn`
- `Deconvolution.h:105` — update doc comment
- `Deconvolution.cpp:73` — rename definition
- `Deconvolution.cpp:139` — update internal call in `deconvolveMS2Py` (keep Py name for backwards compat)
- `FLASHIda.cpp:621,695,731` — rename all 3 call sites
- `PrecursorSelection.h:160`, `PrecursorSelection.cpp:906` — update doc comments

**Why:** The method is called for MS2 results, MS3 results, and exploration variant results at any level. `deconvolveMS2` is misleading — it's a general MSn deconvolution.

---

## 7. Rewrite `computeRemainingPrecursorScore_`

**Goal:** Implement the actual remaining-precursor metric: measure how much unfragmented precursor remains in the MSn spectrum relative to the original, and score by deviation from a configurable target ratio.

**Current state** (`Exploration.cpp:313-320`): Just sums TIC of deconvolved peak groups — does not actually measure remaining precursor intensity.

**Correct logic:**
1. Take the MSn-1 isolation window (`precursor_mz ± isolation_width/2` from the ScanCommand stages)
2. In the raw MSn spectrum (mzs/ints), sum intensity within that isolation window �� this is the unfragmented precursor signal
3. Compare to a reference intensity (e.g. PeakGroup charge intensity from MS1)
4. Score = deviation from a configurable target ratio (developer setting, e.g. `remaining_precursor_target: 0.1` meaning 10% remaining is optimal)

**Changes:**

- Signature needs raw spectrum data and ScanCommand context, not just `DeconvolvedSpectrum`
- Add `remaining_precursor_target` to developer/exploration config (default e.g. 0.1)
- `ExplorationGroup` already stores `precursor_pg` — use its charge intensity as the reference
- Config parsing in `Config.cpp` for the new developer setting

**Why:** The metric name promises "remaining precursor" but the implementation is just a TIC sum. The real metric measures fragmentation efficiency: how close the residual precursor signal is to a user-defined target (some residual is desirable for calibration; too much means poor fragmentation; none means over-fragmentation).

---

## 8. Make `computeFragmentCount_` use sequence-aware fragment matching

**Goal:** `computeFragmentCount_` should return the number of sequence-matched fragment ions (via FLASHTagger/FLASHExtender), not just `spec.size()` which is identical to `computeMassCount_`.

**Current state** (`Exploration.cpp:322-325`): Returns `spec.size()` — same as `computeMassCount_`. No sequence awareness.

**Changes:**

- `Exploration` constructor — accept a `FragmentAnalysis&` reference (or construct one internally from `config_`)
- `computeFragmentCount_` — call `fragment_analysis_.getTopFragmentMatches(config_.targeting().protein_sequence, ...)` on the deconvolved spectrum, return the match count
- `Config::validate()` — add rule: if any level uses `ExplorationMetric::FragmentCount`, `targeting_.protein_sequence` must be non-empty; throw `std::invalid_argument` otherwise
- `FLASHIda.h/cpp` — pass `FragmentAnalysis` to `Exploration` constructor

**Why:** `FragmentCount` and `MassCount` currently return the same value. The point of `FragmentCount` is to score by how many deconvolved masses actually match the protein sequence as fragment ions (b/y/c/z). This requires the FLASHTagger+FLASHExtender pipeline and a configured protein sequence. The config guard ensures users get a clear error instead of silently falling back to mass counting.

---

## 9. Log exploration metrics to results TSV

**Goal:** Add `tic_coverage` and `fragment_count` columns to the C++ results TSV, and write a result row for exploration variants (currently skipped entirely).

**Current state:** The exploration path (`FLASHIda.cpp:689-701`) returns early without calling `writeScanResultRow_`. The three existing call sites (MS1 at line 568, MS3 at line 625, MS2 at line 802) don't pass exploration metrics.

**Changes:**

- `FLASHIda.cpp:96-98` — append to results TSV header:
  ```cpp
  results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\trt\t"
                      << "mass_count\tcommands_pushed\tchild_ids\t"
                      << "tag_count\tmatched_protein\tproteoform_sequence\t"
                      << "tic_coverage\tfragment_count\n";
  ```
- `FLASHIda.h:268-272` — add `float tic_coverage = 0.0f, int fragment_count = 0` parameters to `writeScanResultRow_`
- `FLASHIda.cpp:326-335` — append `tic_coverage` and `fragment_count` to the row output
- `FLASHIda.cpp:568`, `625`, `802` — existing call sites pass defaults (0.0f, 0) for now
- `FLASHIda.cpp:699-701` — add a `writeScanResultRow_` call for exploration variants, passing the actual `tic_coverage` and `fragment_count` computed from the deconvolved result (via items 7 and 8). This requires `feedResult` to return or expose these values (e.g. via the `ExplorationVariant` stored in the group).

**Why:** Exploration results are currently invisible in the results TSV — the path returns early without logging. Adding the columns and the missing call site makes exploration scoring observable for diagnostics and parameter tuning. Other paths can be wired up later.

---

## 10. `initiateNextLevel` should target fragment ions and respect `SelectionMetric`

**Goal:** `initiateNextLevel` should select fragment ions (via `FragmentAnalysis`) instead of raw deconvolved masses, and sort them according to the configured `SelectionMetric` (intensity or qscore).

**Current state** (`Exploration.cpp:236-280`): Always sorts deconvolved peak groups by intensity descending (line 248-249), ignoring the `SelectionMetric` config. Targets are raw deconvolved masses, not sequence-matched fragment ions.

**Changes:**

- `Exploration.h` — `Exploration` needs access to `FragmentAnalysis&` (same dependency as item 8)
- `Exploration.cpp:246-249` — replace intensity-only sort with `SelectionMetric`-aware sorting:
  - `SelectionMetric::Intensity` → sort by intensity (current behavior)
  - `SelectionMetric::QScore` → sort by qscore
- `Exploration.cpp:246-276` — use `FragmentAnalysis` to identify sequence-matched fragment ions and select from those. `Config::validate()` ensures `protein_sequence` is set for all MSn≥2 selection (no fallback to raw deconvolved masses).
- `FLASHIda.h/cpp` — pass `FragmentAnalysis` to `Exploration` constructor (shared with item 8)

**Why:** `initiateNextLevel` picks MSn+1 targets from MSn results. Selecting raw deconvolved masses is a shotgun approach — many of those masses may be noise or non-informative. Fragment ions matched to the protein sequence are far more valuable as MSn+1 targets. Respecting `SelectionMetric` aligns this path with how `PrecursorSelection` already handles MS1→MS2 targeting.

---

## 11. Unify MS3 targeting into `SelectionMetric` and remove `ms3_mode`

**Goal:** Replace the legacy `ms3_mode` integer (0-4) with `SelectionMetric` per-level, adding two new enum values for specialized fragment selection strategies. Delete `selectMS3Targets_()` and the legacy MS3 code path.

**Current state:** Two parallel MS3 targeting systems coexist:
- Legacy: `ms3_mode` in `TargetingConfig` (lines 139-141), `selectMS3Targets_()` (`FLASHIda.cpp:631-673`), dispatched at `FLASHIda.cpp:775-786`
- New: `SelectionMetric` per-level via `initiateNextLevel` (`FLASHIda.cpp:788-797`)

`getAmbiguityEnclosingIons` is implemented in `FragmentAnalysis.cpp:894-1186` but never reachable from any MS3 targeting path.

**Changes:**

- `Config.h:49-54` — extend `SelectionMetric`:
  ```cpp
  enum class SelectionMetric
  {
    None = 0,
    Intensity,            // rank by raw intensity
    QScore,               // rank by qscore
    TerminalFragments,    // innermost b/y ions, interleaved
    AmbiguityResolution   // PTM-site bracketing ions
  };
  ```
- `Config.h:139-141` — remove `ms3_enabled`, `ms3_mode`, `max_ms3_per_ms2` from `TargetingConfig`
- `Config.cpp:161-162` — remove `ms3_enabled`/`ms3_mode` parsing from `ms3` section
- `Config.cpp:287-290` — add `"terminal_fragments"` and `"ambiguity_resolution"` to selection string parsing
- `Config.cpp` — validation: `TerminalFragments` and `AmbiguityResolution` require `protein_sequence` to be set
- `FLASHIda.cpp:631-673` — delete `selectMS3Targets_()`
- `FLASHIda.h` — delete `selectMS3Targets_()` declaration and `MS3Target` struct
- `FLASHIda.cpp:775-786` — delete the legacy `ms3_enabled && ms3_mode > 0` branch
- `FLASHIda.cpp:788` — remove the `!config_.targeting().ms3_enabled` guard so `initiateNextLevel` is the sole MS3 path
- `Exploration.cpp:initiateNextLevel` — handle `TerminalFragments` (call `getTerminalFragmentIons`) and `AmbiguityResolution` (call `getAmbiguityEnclosingIons`) in addition to `Intensity`/`QScore` (item 10)
- Activation type comes from the level's `ScanConfig` instead of being hardcoded per mode ("HCD", "EThcD")
- `max_targets` at level 3 replaces `max_ms3_per_ms2`
- **All JSON configs** — migrate `"ms3": { "mode": N }` to `"selection_strategy": { "ms2": { "selection": "..." } }` (MS3 targeting is configured at the MS2 level because MS3 scans are MS2 targets)
- **C# `MethodConfig.cs`/`MethodParameters.cs`** — remove `ms3_mode`/`ms3_enabled` serialization if present

**Why:** Two parallel targeting systems for the same purpose is confusing and means new strategies must be added in two places. Unifying under `SelectionMetric` makes all strategies available at any MSn level, wires in `AmbiguityResolution` (currently unreachable), and eliminates the legacy integer mode.

---

## 12. Remove legacy MS3 config fields from `TargetingConfig`

**Goal:** Eliminate `ms3_enabled`, `max_ms3_per_ms2`, and `ms3_all_charges` from `TargetingConfig`. MS3 is fully configured through `selection_strategy`.

**Current state:** `Config.h:134-141` has five MS3-related fields in `TargetingConfig`:
- `ms3_all_charges` (line 134)
- `ms3_enabled` (line 139)
- `ms3_mode` (line 140 — removed by item 11)
- `max_ms3_per_ms2` (line 141)
- `protein_sequence` (line 142)

**Changes:**

- `Config.h:134` — remove `ms3_all_charges`
- `Config.h:139` — remove `ms3_enabled`. MS3 is implied when `selection_strategy` ms2 level has `selection != None` (selecting targets from MS2 results produces MS3 scans).
- `Config.h:141` — remove `max_ms3_per_ms2`. Replaced by `MSLevelConfig::max_targets` at the ms2 level.
- `Config.cpp:161-168` — remove `ms3_enabled`, `ms3_mode`, `ms3_all_charges` parsing from `ms3` section
- `Config.cpp:323` — remove `ms3_max_per_ms2` assignment
- `FLASHIda.cpp:775` — remove `config_.targeting().ms3_enabled` guard (item 11 already deletes the legacy branch; this ensures the new path has no residual dependency)
- **All JSON configs** — remove `ms3.enabled`, `ms3.mode`, `ms3.all_charges`, `ms3.max_per_ms2`; set `selection_strategy.ms2.max_targets` instead
- **C# `MethodConfig.cs`/`MethodParameters.cs`** — remove MS3 mode/enabled/all_charges serialization

`protein_sequence` remains in `TargetingConfig` (read from `ms3.protein_sequence`) for now — items 8, 10, and 11 all reference it there.

**Why:** After item 11 unifies targeting under `SelectionMetric`, these legacy fields are redundant. `ms3_enabled` is just `selection != None` at the ms2 level. `max_ms3_per_ms2` is `max_targets` at the ms2 level. `ms3_all_charges` has no equivalent in the new system and is removed.

---

## 13. Simplify Step 5 (MS3 targeting) in `processMS2Path_`

**Goal:** Collapse the three-branch MS3 targeting logic into a single `initiateNextLevel` call.

**Current state** (`FLASHIda.cpp:763-797`): Three branches with duplicated code:
1. `hasExploration(3)` → `initiateNextLevel` (line 765-773)
2. `ms3_enabled && ms3_mode > 0` → `selectMS3Targets_` (line 775-786) — deleted by item 11
3. `level(3).selection != None && !ms3_enabled` → `initiateNextLevel` (line 788-797)

Branches 1 and 3 are identical code. Branch 2 is removed by item 11.

**Changes:**

- `FLASHIda.cpp:763-797` — replace all three branches with:
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

**Why:** After items 11 and 12 remove the legacy MS3 path and config fields, the three branches collapse naturally. `initiateNextLevel` handles everything: exploration CE sweep (if configured at ms3), selection metric dispatch, and fragment-aware targeting.

---

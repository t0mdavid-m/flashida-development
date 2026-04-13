# processScan Cleanup Design (Round 3)

## Goal

Twelve fixes and improvements to `processScan()`, `getNextScanCommand()`, scan construction, exploration scoring, results.tsv output, and C# config serialization. Covers priority restructuring, MS3 pipeline correctness, exploration config exposure, observability, and zero-CE baseline for RemainingPrecursor scoring.

## Branch

`phase-11` (C# and parent repo), `flashida-v9-bridge` (C++ / OpenMS)

## Build Strategy

**Single C++ DLL build cycle.** All C++ changes (9 commits for tasks 3, 4, 5, 6, 7, 8, 9, 11, 12) are pushed together to `flashida-v9-bridge`. C# changes (4 commits for tasks 1, 2, 10, 11) land on `phase-11` independently. After DLL build completes: download artifacts, update `FlashIDA/dll/`, commit, update submodule pointers.

## Implementation Ordering

Five phases, dependency-ordered:

| Phase | Tasks | Theme |
|-------|-------|-------|
| 1 | 3 | Priority restructuring (foundation — all tests target new scheme) |
| 2 | 5, 6, 7, 1 (C#) | MS3 pipeline fix (dispatch + CE/activation + context + serialization) |
| 3 | 10 (C#), 11, 2 (C#) | Exploration config (overrides exposure → remove exploration_activation → remaining_precursor_target) |
| 4 | 4, 8, 9 | Observability (AllMass log, fragment columns, exploration metadata in results.tsv) |
| 5 | 12 | Zero-CE baseline for RemainingPrecursor metric |

---

## Task 1: Serialize MS3 Config to C++ JSON

### Problem

`MethodParameters.ToCppJson()` serializes `ms1` and `ms2` into `ms_settings` but omits `ms3`. `JsonMsSettingsConfig` has no `ms3` property. The C++ parser (`Config.cpp:242-255`) is ready to parse `ms_settings.ms3` but never receives it. MS3 scans arrive with CE=0 and empty activation.

### Changes (C# only)

- `MethodConfig.cs:430-434` — add `public JsonMs2Config[] ms3 { get; set; }` to `JsonMsSettingsConfig`. Reuse `JsonMs2Config` (same fields: analyzer, activation, collision_energy, resolution).
- `MethodParameters.cs:~186` — after the `ms2` array, iterate `c.MsSettings.MS3` to build the `ms3` array, same pattern as MS2.

### Verification

JSON sent to C++ contains `ms_settings.ms3` array with non-zero collision_energy and non-empty activation matching the method config.

---

## Task 2: Expose `remaining_precursor_target` to JSON Config

### Problem

`remaining_precursor_target` is defined in C++ `MSLevelConfig` (Config.h:97, default 0.1) and parsed from JSON (Config.cpp:313), but C# never serializes it. Always gets the hardcoded default.

### Changes (C# only)

- `MethodConfig.cs` — add `public double RemainingPrecursorTarget { get; set; }` to `ExplorationBlockConfig`; add `public double remaining_precursor_target { get; set; }` to `JsonExplorationBlockConfig`.
- `MethodParameters.cs` — set `remaining_precursor_target = 0.1` in `defaultExpl`. Serialize actual value from `ss.MS2.Exploration.RemainingPrecursorTarget` / `ss.MS3.Exploration.RemainingPrecursorTarget`.

### Verification

JSON contains `"remaining_precursor_target": <value>` inside each exploration block.

---

## Task 3: Restructure Scan Priority Assignments

### Problem

Priority scheme is inconsistent: standard MS2 at priority 1 (high), MS3 at priority 3 (lowest), follow-ups at priority 2 despite being time-critical, cycle-time MS1 bypasses the queue entirely.

### New Priority Scheme

| Scan Type | Old Priority | New Priority | Old Behavior | New Behavior |
|-----------|-------------|-------------|-------------|-------------|
| AGC (scheduled + idle) | 0 | 0 | Immediate return | Immediate return (unchanged) |
| Cycle-time MS1 | 3 (immediate) | 0 | Immediate return | Queued |
| FAIMS CV-transition MS1 | 0 | 0 | Queued | Queued (unchanged) |
| Follow-up MS2 (conditional) | 2 | 0 | Queued | Queued |
| Follow-up MS2 (quant) | 2 | 0 | Queued | Queued |
| MS3 (standard) | 3 | 1 | Queued | Queued |
| MS3 exploration variant | 0 | 1 | Queued | Queued |
| MS2 (standard) | 1 | 2 | Queued | Queued |
| MS2 exploration variant | 0 | 2 | Queued | Queued |
| MS1 (standard/survey) | 3 | 3 | Queued | Queued (unchanged) |
| MS1 (idle cycle) | 0 | 3 | Queued | Queued |

### Changes (C++)

- `ScanCommandQueue.cpp` — `buildMS2()`: default priority 1 → 2. `buildMS3()`: default priority 3 → 1.
- `FLASHIda.cpp` — `getNextScanCommand()`: cycle-time MS1 changes from immediate return to `queue_.push()` at priority 0, then fall through to dequeue. Idle cycle MS1: priority 0 → 3.
- `FLASHIda.cpp` — `processScan()`: conditional MS2 follow-up priority 2 → 0. Quant MS2 follow-up priority 2 → 0.
- `Exploration.cpp` — exploration variant creation: priority based on scan level (MS2 → 2, MS3 → 1) instead of hardcoded 0.

### Dequeue Order

AGC (immediate) → cycle-time MS1 / CV-transition MS1 / follow-ups (p0) → MS3 (p1) → MS2 (p2) → MS1 survey (p3).

---

## Task 4: Fix AllMass IDA Log Reporting

### Problem

`writeIDALogEntry_()` (FLASHIda.cpp:213-220) iterates `selection_.selectedPeakGroups()` — the filtered subset capped at `max_targets`. Should list all deconvolved masses.

### Changes (C++)

- `FLASHIda.h` — update `writeIDALogEntry_()` signature: add `const DeconvolvedSpectrum& all_peak_groups` parameter.
- `FLASHIda.cpp` — change AllMass loop from `selection_.selectedPeakGroups()` to the new parameter.
- `PrecursorSelection.h` — add accessor: `const DeconvolvedSpectrum& deconvolvedMS1() const { return deconv_.deconvolvedMS1(); }`
- `FLASHIda.cpp` — at call site in `processScan()`, pass `selection_.deconvolvedMS1()`.

### Verification

AllMass entry count > Mass entry count when deconvolution finds more peak groups than max_targets.

---

## Task 5: Dispatch `initiateNextLevel` to Correct Builder by Target Level

### Problem

`initiateNextLevel()` (Exploration.cpp:340-363) always calls `buildMS2()` regardless of target level. For MS2→MS3, it calls `buildMS2()` and patches `cmd.msn_level = 3`, leaving `num_stages=1` and no MS2 precursor context. `buildMS3()` exists (ScanCommandQueue.cpp:249-304) but is never called.

### Changes (C++)

- `Exploration.h` — add `const ScanCommand* ms_ctx` parameter to `initiateNextLevel()` (nullptr for MS2, points to originating MS2 command for MS3).
- `Exploration.cpp` — in `initiateNextLevel()`, branch on `next_level`: when `next_level == 2`, keep existing `buildMS2()` path; when `next_level >= 3`, call `buildMS3()` passing the MS2 context, fragment m/z, charge, isolation width, ion type, fragment index, and the appropriate priority.

### Verification

MS2 commands: `num_stages=1`. MS3 commands: `num_stages=2`, stage 0 = MS2 precursor context, stage 1 = fragment target.

---

## Task 6: Fix `buildMS3()` CE and Activation to Use `levels_[3]` Config

### Problem

`buildMS3()` (ScanCommandQueue.cpp:277-278) hardcodes `stages[1].activation_type = "HCD"` and copies `stages[1].collision_energy` from `stages[0]` (the MS2 CE). Should read from `levels_[3].scans[0]` config.

### Changes (C++)

- `ScanCommandQueue.h` — update `buildMS3()` declaration: add `const ScanConfig& ms3_config` parameter.
- `ScanCommandQueue.cpp` — set `stages[1].collision_energy` from `ms3_config.collision_energy`. Set `stages[1].activation_type` from `ms3_config.activation`.

### Verification

MS3 `stages[1]` CE and activation match `levels_[3].scans[0]`, not inherited from MS2 stage.

---

## Task 7: Pass MS2 ScanCommand Context to `initiateNextLevel`

### Problem

The MS3 path in `initiateNextLevel()` (task 5) needs the originating MS2 ScanCommand. Neither call site provides it.

### Design Decision

**Store `ScanCommand originating_cmd` in `ExplorationGroup`** (option b). Reconstruction from fields is fragile — drifts if ScanCommand gains fields. ~1.2 KB per active group is negligible.

### Changes (C++)

- `Exploration.h` — add `ScanCommand originating_cmd` field to `ExplorationGroup`.
- `Exploration.cpp` — in `initiate()`, capture the originating MS2 command into `originating_cmd` when the group is created. Add `const ScanCommand* ms_ctx` parameter to `initiate()` or capture from the command built for the MS2 precursor.
- `FLASHIda.cpp` — at `processScan()` call site (line 698), pass `&ctx` as the MS2 context.
- `Exploration.cpp` — in `feedResultImpl_()` (line 258), pass `&group.originating_cmd` when calling `initiateNextLevel()`.

### Verification

Both call sites pass valid MS2 context. MS3 commands from both paths produce identical two-stage structure.

---

## Task 8: Populate Fragment Matching Columns in results.tsv

### Problem

Results.tsv header declares `matched_protein`, `proteoform_sequence`, `tic_coverage`, `fragment_count` but they are never populated (FLASHIda.cpp:710-711 passes empty strings and zeros). The fragment analysis that runs during MS3 target selection has this data but discards it.

### Design

Fragment columns apply to **MS2 scans that initiate MS3** through fragment analysis (not tag-based targeting — that initiates MS2 follow-ups).

`initiateNextLevel()` already runs fragment analysis to select MS3 targets. Change its return type to expose fragment match context:

```cpp
struct NextLevelResult
{
  std::vector<ScanCommand> commands;
  std::string matched_protein;
  std::string proteoform_sequence;
  float tic_coverage = 0.0f;
  int fragment_count = 0;
};
```

**TIC coverage formula:** `sum(matched fragment peak intensities) / sum(all MS2 peak intensities)`. Value in [0, 1] representing what fraction of MS2 signal is explained by identified fragments.

### Dependency

Builds on task 5's signature change to `initiateNextLevel()` (which adds `ms_ctx` parameter). Task 8 additionally changes the return type.

### Changes (C++)

- `Exploration.h` — define `NextLevelResult` struct. Change `initiateNextLevel()` return type from `std::vector<ScanCommand>` to `NextLevelResult`.
- `Exploration.cpp` — in `initiateNextLevel()`, after fragment analysis selects targets, populate `NextLevelResult` fields from the fragment match data.
- `FLASHIda.cpp` — at the `processScan()` call site, unpack `NextLevelResult` and pass fragment fields to `writeScanResultRow_()`.
- `FLASHIda.cpp` — at the exploration `feedResultImpl_` call site, same unpacking.

### Verification

MS2 rows that produce MS3 commands: non-empty `matched_protein`, `proteoform_sequence`, `fragment_count > 0`, `tic_coverage > 0`. MS2 rows without MS3: unchanged (empty/zero).

---

## Task 9: Populate Exploration Metadata in results.tsv

### Problem

Exploration variant rows contain only `mass_count` and `commands_pushed`. Group ID, variant index, CE, score, metric — all discarded when `ExplorationGroup` is erased at Exploration.cpp:266.

### Design

```cpp
struct FeedResultInfo
{
  std::vector<ScanCommand> commands;
  int group_id = -1;
  int variant_index = -1;
  int total_variants = 0;
  double collision_energy = 0.0;
  double score = -1.0;
  float tic_coverage = 0.0f;
  int fragment_count = 0;
  int exploration_metric = 0;       // ExplorationMetric enum as int
};
```

### Changes (C++)

- `Exploration.h` — define `FeedResultInfo`. Change `feedResult()` and `feedResultForTest()` return type from `std::vector<ScanCommand>` to `FeedResultInfo`.
- `Exploration.cpp` — in `feedResultImpl_()`, populate `FeedResultInfo` fields from the variant and group before erasing.
- `FLASHIda.cpp` — update results.tsv header: add `exploration_group_id`, `exploration_metric`, `variant_index`, `total_variants`, `collision_energy`, `exploration_score`.
- `FLASHIda.cpp` — update `writeScanResultRow_()` signature and body for new columns (defaults for non-exploration rows).
- `FLASHIda.cpp` — at exploration call site (~line 627-632), unpack `FeedResultInfo` and pass to `writeScanResultRow_()`.

### Verification

Exploration rows show group_id, variant_index, CE, score, metric. Same group shares group_id and total_variants. Non-exploration rows have defaults (-1/0).

---

## Task 10: Expose Exploration `overrides` in C# Config

### Problem

C++ supports per-level `exploration.overrides` (Config.cpp:314-319, Config.h:95) — a string→string map patching ScanConfig fields. C# never serializes it.

### Supported Override Keys

| Key | ScanConfig field | Type | Example |
|-----|-----------------|------|---------|
| `analyzer` | `analyzer` | string | `"ITMS"`, `"FTMS"` |
| `activation` | `activation` | string | `"HCD"`, `"CID"`, `"ETD"` |
| `collision_energy` | `collision_energy` | int | `"25"` |
| `resolution` | `resolution` | int | `"30000"` |
| `agc_target` | `agc_target` | int | `"500000"` |
| `first_mass` | `first_mass` | double | `"200.0"` |
| `last_mass` | `last_mass` | double | `"2000.0"` |
| `max_it` | `max_it` | double | `"50.0"` |

### Changes (C# only)

- `MethodConfig.cs` — add `public Dictionary<string, string> Overrides { get; set; }` to `ExplorationBlockConfig`; add `public Dictionary<string, string> overrides { get; set; }` to `JsonExplorationBlockConfig`.
- `MethodParameters.cs` — serialize overrides from domain model for MS2 and MS3 exploration blocks. Default `null` (omitted when null).

### Verification

Method JSON with `"overrides": {"analyzer": "ITMS"}` produces C++ JSON containing the same block.

---

## Task 11: Remove `exploration_activation` — Use Overrides Instead

### Problem

`MSLevelConfig::exploration_activation` (Config.h:94) duplicates the `"activation"` override key. Worse, `Exploration::initiate()` applies `exploration_activation` **after** `applyOverrides()` (line 104), silently clobbering any `"activation"` override.

### Dependency

Task 10 must land first (users need overrides to set activation before the dedicated field is removed).

### Changes

**C++ (OpenMS):**
- `Config.h` — remove `exploration_activation` from `MSLevelConfig`.
- `Config.cpp` — remove `"HCD"` from `default_level_` initializer; remove `cfg.exploration_activation = expl_obj.value(...)` from parser.
- `Exploration.cpp` — in `initiate()`: remove line 100 (`v.activation_type = cfg.exploration_activation`), remove line 104 (`variant_config.activation = cfg.exploration_activation`). After `applyOverrides`, set `v.activation_type = variant_config.activation` (reads from overridden base config).

**C# (FlashIDA):**
- `MethodConfig.cs` — remove `Activation` from `ExplorationBlockConfig`; remove `activation` from `JsonExplorationBlockConfig`.
- `MethodParameters.cs` — remove `activation = "HCD"` from `defaultExpl`; remove `activation = ...` from MS2/MS3 blocks.

**Test configs:**
- Remove `"activation"` from exploration blocks. Where non-default activation is needed, use `"overrides": {"activation": "CID"}`.

### Verification

Variants use base scan config activation by default. `"overrides": {"activation": "CID"}` changes all variant activations. No `activation` key in exploration JSON blocks.

---

## Task 12: Add Zero-CE Baseline Scan for RemainingPrecursor Metric

### Problem

`computeRemainingPrecursorScore_()` (Exploration.cpp:401-433) compares remaining precursor intensity against MS1 `PeakGroup::getChargeIntensity()`. This is inaccurate: MS1 and MS2 use different analyzers/resolution/AGC, and the isolation step itself attenuates intensity.

### Design

When exploration metric is `RemainingPrecursor`, prepend a CE=0 MS2 scan to the CE sweep. This captures the precursor after isolation but before fragmentation — a true same-conditions baseline.

- CE sweep `{20, 25, 30, 35, 40}` becomes `{0, 20, 25, 30, 35, 40}`
- CE=0 result is the reference intensity
- Score = `1 - (variant_isolation_intensity / baseline_isolation_intensity)`
- **`total_variants` excludes the baseline** (reports 5, not 6)
- Baseline gets `variant_index = -1`

### Baseline Failure Handling

If CE=0 scan returns zero isolation-window intensity: set remaining precursor ratio to 1/1 for all variants (score = 0, meaning 0% fragmentation detected). This makes the failure immediately obvious — every variant in the group shows no fragmentation efficiency. **No silent fallback to MS1 reference.**

### Changes (C++)

**Exploration.h:**
- `ExplorationVariant` — add `bool is_baseline = false;`
- `ExplorationGroup` — add `double baseline_intensity = 0.0;` and `bool has_baseline = false;`

**Exploration.cpp — `initiate()`:**
- After `buildCEVariants_()`, if metric is `RemainingPrecursor`, prepend CE=0 variant at index 0 with `is_baseline = true`. Subsequent variants shift index by 1.

**Exploration.cpp — `feedResultImpl_()`:**
- When variant with `is_baseline == true` arrives: compute isolation-window intensity sum, store as `group.baseline_intensity`, set `group.has_baseline = true`. Baseline score stays 0.

**Exploration.cpp — winner selection:**
- Skip variants where `is_baseline == true`.

**Exploration.cpp — `computeRemainingPrecursorScore_()`:**
- When `group.has_baseline`: use `group.baseline_intensity` as reference. If `baseline_intensity <= 0`: ratio = 1.0 (score = 0) for all variants.
- When `!group.has_baseline`: should not happen (baseline always arrives before CE>0 variants in normal operation), but if it does, ratio = 1.0.

### Verification

For `RemainingPrecursor` with CE sweep `{20, 25, 30, 35, 40}`:
- 6 ScanCommands emitted: 1 baseline (CE=0) + 5 CE variants
- CE=0 is never the winner
- Scores use baseline isolation-window intensity as denominator
- `total_variants` reports 5 (excludes baseline)
- Baseline failure: all variants score 0 (ratio 1/1)

---

## Test Strategy

Tests updated inline with each task. No new test files — all extend existing binaries.

### Task 3

- `FLASHIda_ProcessScan_test.cpp`: update all `cmd.priority` assertions. MS2: 1→2, MS3: 3→1, follow-ups: 2→0, cycle-time MS1: immediate→queued at p0.
- `FLASHIda_exploration_test.cpp`: exploration variants MS2 level: 0→2, MS3 level: 0→1.
- `FLASHIdaQueueTracking_test.cpp`: update dequeue-order assertions if present.

### Task 4

- Assert AllMass entry count > Mass entry count when deconvolution output exceeds max_targets.

### Tasks 5+6+7

- MS3 commands: `num_stages == 2`, `stages[0]` = MS2 precursor, `stages[1]` CE/activation from `levels_[3].scans[0]`.
- Test both paths: direct processScan MS2→MS3 and post-exploration winner→MS3.
- Test configs need distinct MS3 CE/activation to differentiate from MS2.

### Task 8

- MS2 rows initiating MS3: non-empty `matched_protein`, `proteoform_sequence`, `fragment_count > 0`, `tic_coverage > 0`.
- MS2 rows without MS3: columns remain empty/zero.

### Task 9

- Exploration rows: `group_id >= 0`, `variant_index >= 0`, `collision_energy > 0`, `exploration_metric` matches config.
- Same group shares `group_id` and `total_variants`.
- Non-exploration rows: defaults (-1/0).

### Task 11

- Remove `"activation"` from test configs. Use `"overrides": {"activation": "CID"}` where needed.
- Verify default activation = base scan config activation.

### Task 12

- RemainingPrecursor with CE sweep `{20, 25, 30}`: expect 4 commands (1 baseline + 3).
- Baseline CE=0, never selected as winner.
- Scores use baseline isolation-window intensity.
- Baseline failure (zero intensity): all variants score 0.
- `total_variants` = 3 (excludes baseline).

---

## File Impact Summary

### C++ (OpenMS, `flashida-v9-bridge`)

| File | Tasks |
|------|-------|
| `ScanCommandQueue.h/.cpp` | 3, 6 |
| `FLASHIda.h` | 4, 8, 9 |
| `FLASHIda.cpp` | 3, 4, 7, 8, 9 |
| `Exploration.h` | 5, 7, 8, 9, 12 |
| `Exploration.cpp` | 3, 5, 7, 8, 9, 11, 12 |
| `Config.h` | 11 |
| `Config.cpp` | 11 |
| `PrecursorSelection.h` | 4 |

### C# (FlashIDA, `phase-11`)

| File | Tasks |
|------|-------|
| `MethodConfig.cs` | 1, 2, 10, 11 |
| `MethodParameters.cs` | 1, 2, 10, 11 |

### Test Files

| File | Tasks |
|------|-------|
| `FLASHIda_ProcessScan_test.cpp` | 3, 4, 5, 6, 7, 8 |
| `FLASHIda_exploration_test.cpp` | 3, 9, 11, 12 |
| `FLASHIdaQueueTracking_test.cpp` | 3 |
| Test config JSONs | 11 |

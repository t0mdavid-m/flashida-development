# Exploration Test Rewrite & CI TSan Merge

## Goal

Rewrite the exploration tests to use direct `Exploration` API and `processScan()` instead of ForTest helpers. Delete the exploration-specific ForTest methods from `FLASHIda.h`. Merge the two C++ CI jobs into one TSan-enabled job.

## Architecture

Two-tier test rewrite in the existing `FLASHIda_exploration_test.cpp`:

- **Tier A (6 sections):** Instantiate `Config` + `ScanCommandQueue` + `Exploration` directly. Call `initiate()`, `feedResult()`, `initiateNextLevel()`. Assert on returned commands and group state. No `FLASHIda` object.
- **Tier B (3 sections):** Instantiate `FLASHIda` with exploration-enabled config. Feed real spectrum data via `processScan()`. Verify `getNextScanCommand()` behavior (cycle time suppression, MS1 resume, MS3 targeting).
- **2 sections unchanged:** `metadata_serialized_to_msspectrum` and `selection_metric_controls_config` already don't use ForTest helpers.

## Test Section Mapping

### Tier A -- Direct Exploration API

| Section | What it tests | API calls |
|---------|--------------|-----------|
| `exploration_group_creation` | `initiate()` creates group with correct CE variants | `exploration.initiate()`, `exploration.activeGroupCount()`, `exploration.getGroup()` |
| `exploration_variants_priority_0` | Returned commands have priority 0 | `exploration.initiate()`, assert `cmds[i].priority == 0` |
| `winner_selection_by_score` | `feedResult()` picks highest-scoring variant | `exploration.initiate()`, `exploration.feedResult()` with varying scores, check `group.winner_index` |
| `ms3_exploration_creates_child_groups` | MS3 exploration triggers child groups from MS2 winner | `exploration.initiate()`, `exploration.feedResult()`, `exploration.initiateNextLevel()`, check child group count |
| `optimization_metadata_populated` | Winner metadata fields (CE, TIC, fragment count) correct | `exploration.initiate()`, `exploration.feedResult()`, check group metadata fields |
| `metadata_serialized_to_msspectrum` | OptimizationMetadata round-trips through MSSpectrum | Already direct, no change |

### Tier B -- processScan integration

| Section | What it tests | Drive mechanism |
|---------|--------------|-----------------|
| `cycle_time_suppression_during_exploration` | `getNextScanCommand()` returns exploration MS2 (not cycle-time MS1) while exploration active | `processScan(ms1_data)` with exploration config, then `getNextScanCommand()` |
| `ms1_resumes_after_exploration_completes` | MS1 returns after all variants complete | `processScan(ms1_data)` then `processScan(ms2_data)` for each variant, verify MS1 resumes |
| `ms3_selection_no_exploration_standard_targeting` | Non-exploration MS3 via selection_strategy | `processScan(ms1_data)` + `processScan(ms2_data)` with MS3 selection config |

### Minor rewrite

| Section | Change |
|---------|--------|
| `no_ms2_exploration_ms3_exploration_immediate` | Uses `getActiveExplorationGroupCountForTest()` (being deleted). Replace with direct `Exploration` instance: `Exploration expl(cfg); TEST_EQUAL(expl.activeGroupCount(), 0)`. Config checks via `getLevelConfigForTest()` stay (method is kept). |

### Unchanged

| Section | Reason |
|---------|--------|
| `selection_metric_controls_config` | Config parsing only, uses `getLevelConfigForTest()` which is kept |
| `metadata_serialized_to_msspectrum` | Already direct, no ForTest helpers |

## ForTest Helper Cleanup

**Delete from `FLASHIda.h`:**
- `initiateExplorationForTest()`
- `feedExplorationResultForTest()`
- `getActiveExplorationGroupCountForTest()`
- `getExplorationGroupForTest()`
- `getExplorationForTest()`

**Keep (used by other tests):**
- `pushCommandForTest()`, `getQueueForTest()`, `getQueueSizeForTest()`, `getLevelConfigForTest()`, `getConfigForTest()`

## CI: Merge to Single TSan Job

Replace `cpp-unit-tests` + `tsan-tests` with one job:

- Build with `-fsanitize=thread -g -O1` (Debug mode)
- `TSAN_OPTIONS: "halt_on_error=1"` on test step
- Remove ccache (TSan objects differ from Release)
- Delete the `tsan-tests` job block
- Update stale comments

Every push and PR gets race detection. Build time is comparable to the previous Release build.

## File Changes

| File | Change |
|------|--------|
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | Rewrite 9 sections, keep 2 unchanged |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Delete 5 exploration ForTest methods |
| `.github/workflows/flashida-ci.yml` | Merge two C++ jobs into one with TSan |

No new files. No new test binaries. No cmake changes.

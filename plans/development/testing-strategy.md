# Testing Strategy for FLASHIda Migration

**Date:** 2026-03-21
**Applies to:** baseline-plan.md (v9) — Phases 1-8, Builds #1-#4

---

## 1. Testing Philosophy

FLASHIda operates at the intersection of two codebases (C# and C++), has no instrument hardware in CI, and has zero existing automated tests. The strategy therefore focuses on:

- **Test what can be tested offline.** Every piece of logic that does not require `IFusionInstrumentAccess` is testable. This includes all deconvolution, scoring, configuration parsing, struct marshaling, queue behavior, and mode routing.
- **Golden-file regression is the safety net.** `Flash.exe -t` already exists as an offline deconvolution harness. Its output, captured to files, becomes the regression baseline that gates every PR.
- **C++ tests are gated by pre-built artifacts.** Building OpenMS from source takes 30-60 minutes on a beefy runner. CI uses cached DLL artifacts from `build_dlls.yml` for the C# test tier, and only rebuilds OpenMS when C++ source changes.
- **Bridge correctness is paramount.** The P/Invoke boundary is the single most fragile surface. It gets its own dedicated test binary and validation suite.
- **Every phase adds tests; no phase removes them.** The test suite is purely additive. Phase N's tests become Phase N+1's regression suite.

---

## 2. Test Tiers

### Tier 1: Unit Tests (every PR, < 5 min)

**What:** Pure-logic tests that compile and run without any DLL dependency. These are fast, deterministic, and isolated.

- **C# units** (NUnit, new test project `Flash.Tests.csproj`): JSON serialization round-trips, `MethodConfig` parsing, `ScanCommand` struct layout validation, `Parameter.ToJSON()` field coverage, tracking ID format validation, scan description parsing.
- **C++ units** (OpenMS ClassTest framework): `OptimizationMetadata` struct accessors, `DeconvolvedSpectrum` metadata round-trip, queue priority logic (isolated from deconvolution), tracking ID generation (base-36 uniqueness), JSON config parsing.

**When:** On every push to any PR branch. Runs on `ubuntu-latest` (C++ unit tests) and `windows-latest` (C# unit tests).

### Tier 2: Integration Tests (every PR, < 15 min)

**What:** Tests that exercise the cross-project bridge. A C# test process loads `OpenMS.dll` and calls bridge functions with known inputs, validating outputs.

- Struct marshaling round-trips (C# writes `ScanCommand` -> C++ reads, C++ writes -> C# reads).
- `CreateFLASHIda` with JSON config -> verify initialization did not crash.
- `ProcessScan` with synthetic spectrum data -> verify return value and TRACK log output.
- `GetNextScanCommand` -> verify struct fields match expectations.
- DLL export symbol verification (`dumpbin /exports` on Windows).

**When:** On every push to any PR branch. Runs on `windows-latest` (requires Windows for .NET 4.8 + MSVC DLL).

### Tier 3: Regression Tests (every PR, < 20 min)

**What:** Golden-file comparison using `Flash.exe -t`. Captures full deconvolution output for a set of reference spectra and compares against checked-in golden files.

- Standard DDA mode with default `method.xml`.
- Each acquisition mode variant (deep, inclusion, exclusion, tag targeting, etc.) with mode-specific method configs and test data.
- Output comparison with numeric tolerance (configurable epsilon for floating-point fields).

**When:** On every push to any PR branch. Runs on `windows-latest`.

### Tier 4: Stress / Extended Tests (nightly or manual, < 60 min)

**What:** Long-running tests that validate behavior under load or edge conditions.

- Queue saturation: 10,000 rapid `ProcessScan` calls, verify no memory leaks, all tracking IDs unique.
- FAIMS CV cycling: simulate 500 scan events across 3 CVs, verify CV transition counts match expectations.
- Exploration engine: verify variant explosion limits (MaxQueueForExploration) are respected.
- Thread safety: concurrent `ProcessScan` + `GetNextScanCommand` from 2 threads, verify `queue_mutex_` prevents corruption.

**When:** Nightly scheduled run, or manually via `workflow_dispatch`. Runs on `windows-latest`.

---

## 3. Test Infrastructure

### 3.1 GitHub Actions Workflow Structure

```
.github/workflows/
  flashida-ci.yml          # Main CI workflow (Tiers 1-3)
  flashida-nightly.yml     # Nightly extended tests (Tier 4)
  build-openms-dll.yml     # OpenMS DLL build (triggered only on C++ changes)
```

**`flashida-ci.yml`** is the PR gate. It has three jobs:

```yaml
name: flashida-ci
on:
  push:
    branches: [main, develop, 'phase-*']
  pull_request:
    branches: [main, develop]

jobs:
  cpp-unit-tests:
    runs-on: ubuntu-latest          # C++ unit tests only, no Windows needed
    if: # only when C++ files changed
    steps: [checkout, restore-cmake-cache, build-tests-only, ctest -R FLASH]

  csharp-tests:
    runs-on: windows-latest         # .NET 4.8 + OpenMS.dll
    steps:
      - checkout
      - download-openms-dll-artifact   # from build-openms-dll.yml or cache
      - setup-msbuild
      - build Flash.Tests.csproj
      - run nunit3-console Flash.Tests.dll
      - run Flash.exe -t (regression)
      - compare golden files

  bridge-tests:
    runs-on: windows-latest
    needs: [csharp-tests]           # reuses build artifacts
    steps:
      - run bridge test binary
      - run dumpbin /exports validation
```

### 3.2 Handling the C++ Build

The OpenMS build is extremely expensive. The strategy:

1. **`build-openms-dll.yml`** already exists on the `FIdevelop` branch (see `OpenMS/.github/workflows/build_dlls.yml`). It builds on `windows-2022`, produces `OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll` as artifacts.

2. **Artifact caching:** The `flashida-ci.yml` workflow downloads the latest DLL artifact from `build-openms-dll.yml` using `actions/download-artifact` (cross-workflow) or a GitHub release asset. DLLs are cached with a hash key based on `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/**` file hashes.

3. **Conditional rebuild:** The CI workflow detects whether any C++ source in `ANALYSIS/TOPDOWN/` changed. If not, it skips the C++ build entirely and uses cached DLLs.

4. **C++ unit tests** are built separately — they only compile the test binaries, not the full OpenMS library. This is faster (~10 min vs 30-60 min) when using ccache from the existing workflow.

### 3.3 Handling the C# Build

```yaml
- name: Setup MSBuild
  uses: microsoft/setup-msbuild@v2

- name: Restore NuGet packages
  run: nuget restore FlashIDA/src/Flash.sln

- name: Build solution
  run: msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```

**Key requirement:** Thermo iAPI DLLs (`API-2.0.dll`, `Fusion.API-1.0.dll`, etc.) are proprietary and cannot be in the repo. For unit tests and bridge tests that do not instantiate `IFusionInstrumentAccess`, the test project references mock/stub interfaces. For regression tests (`Flash.exe -t`), the DLLs must exist in `FlashIDA/dependencies/` — these are stored as encrypted GitHub Actions secrets or in a private artifact store.

**Test project setup:**

```
FlashIDA/src/Flash.Tests/
  Flash.Tests.csproj          # References Flash.csproj, NUnit
  JsonConfigTests.cs
  ScanCommandLayoutTests.cs
  MethodParameterTests.cs
  TrackingIdTests.cs
```

The test project targets .NET Framework 4.8 and uses NUnit 3 as the test framework. It references the main `Flash.csproj` and adds `nunit3-console` for CLI execution in CI.

### 3.4 Test Data Management

Test data lives in a dedicated directory:

```
FlashIDA/test-data/
  spectra/
    ms1_standard.txt          # Tab-delimited mz/intensity, used by Flash.exe -t
    ms2_hcd_fragment.txt      # MS2 spectrum for tag-based targeting test
  configs/
    method_default.xml        # Standard DDA
    method_deep.xml           # Deep mode
    method_inclusion.xml      # Inclusion list mode
    method_exclusion.xml      # Exclusion list mode
    method_tag_targeting.xml  # MS2 tagging + conditional MS2
    method_quant.xml          # Isobaric quantification
    method_ms3_mode1.xml      # MS3 characterization mode 1
    method_ms3_mode2.xml      # MS3 characterization mode 2
    method_ms3_mode3.xml      # MS3 characterization mode 3
    method_faims_3cv.xml      # FAIMS with 3 CVs
    method_faims_skip.xml     # FAIMS with adaptive skipping
    method_exploration.xml    # Parameter optimization enabled
    method_json_roundtrip.xml # Full-featured config for JSON round-trip
  golden/
    standard_dda.tsv          # Expected output for ms1_standard.txt + method_default.xml
    deep_mode.tsv             # Expected output for deep mode
    ...                       # One golden file per mode configuration
  json/
    config_default.json       # Expected JSON output from method_default.xml
    config_full.json          # Expected JSON from method_json_roundtrip.xml
```

Golden files are committed to the repository. When an intentional behavioral change occurs, the developer runs `Flash.exe -t` locally with each config, inspects the diff, and commits updated golden files alongside the code change. The PR review process verifies that golden file changes are intentional.

---

## 4. Per-Phase Test Plan

### Phase 1: JSON Configuration

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P1-U01 | 1 | `Parameter.ToJSON()` produces valid JSON | `JavaScriptSerializer` can deserialize the output without error |
| P1-U02 | 1 | `ToJSON()` includes all `method.xml` sections | JSON contains keys: `deconvolution`, `precursor_selection`, `quantification`, `faims`, `ms_settings`, `scheduling`, `exploration`, `files` |
| P1-U03 | 1 | JSON field values match XML source | Parse `method_json_roundtrip.xml`, call `ToJSON()`, compare each field against `config_full.json` golden file |
| P1-U04 | 1 | `ms_settings.ms2` is an array (supports multiple MS2 configs) | Verify array length matches XML `<MS2>` child count |
| P1-U05 | 1 | `MethodConfig.cs` round-trip: XML -> MethodConfig -> JSON -> parse -> verify | All fields survive the round-trip |
| P1-I01 | 2 | `CreateFLASHIda(jsonString)` does not crash | C++ constructor returns non-null `FLASHIda*` |
| P1-I02 | 2 | `CreateFLASHIda(legacyString)` still works | Legacy format auto-detected, returns non-null |
| P1-I03 | 2 | JSON config values reach C++ internal state | After `CreateFLASHIda(json)`, call a diagnostic bridge function that returns parsed config values (e.g., min_charge, max_charge) and verify match |
| P1-R01 | 3 | `Flash.exe -t` with JSON config path | Output matches `standard_dda.tsv` golden file |
| P1-R02 | 3 | `Flash.exe -t` with legacy config (regression) | Output matches `standard_dda.tsv` — auto-detect fallback works |

**Working Product Verification automation:**
- WPV-1 ("Flash.exe -t runs with JSON config"): Automated by P1-R01.
- WPV-2 ("Round-trip method.xml -> ToJSON() -> C++ parse"): Automated by P1-I03.
- WPV-3 ("Legacy format still works"): Automated by P1-R02.

---

### Phase 2: OptimizationMetadata

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P2-U01 | 1 (C++) | `DeconvolvedSpectrum` default has no metadata | `hasOptimizationMetadata()` returns false |
| P2-U02 | 1 (C++) | `getOrCreateOptimizationMetadata()` creates metadata | `hasOptimizationMetadata()` returns true after call |
| P2-U03 | 1 (C++) | Metadata fields have correct defaults | `group_id == 0`, `variant_index == -1`, `fragmentation_quality_score == -1`, etc. |
| P2-U04 | 1 (C++) | `toSpectrum()` serializes metadata via `setMetaValue()` | Create spectrum with metadata, call `toSpectrum()`, verify `getMetaValue("optimization_group_id")` returns correct value |
| P2-U05 | 1 (C++) | `toSpectrum()` without metadata does not set metavalues | Verify `getMetaValue` throws or returns empty for optimization keys |
| P2-R01 | 3 | `Flash.exe -t` unchanged behavior | Output matches Phase 1 golden files exactly (no metadata populated yet) |

**Regression from Phase 1:** All P1-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("Flash.exe -t runs"): Automated by P2-R01.
- WPV-2 ("OpenMS unit test for metadata"): Automated by P2-U01 through P2-U05.
- WPV-3 ("hasOptimizationMetadata() returns false"): Automated by P2-U01.

---

### Phase 3: ScanCommand Struct + Bridge Stubs (Build #1)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P3-U01 | 1 (C#) | `ScanCommand` struct size matches C++ | `Marshal.SizeOf<ScanCommand>()` equals expected byte count (compute from C++ struct layout) |
| P3-U02 | 1 (C#) | `IsolationStage` struct size matches C++ | `Marshal.SizeOf<IsolationStage>()` equals expected byte count |
| P3-U03 | 1 (C#) | `ScanCommand` field offsets match C++ | `Marshal.OffsetOf` for each field matches C++ `offsetof` values (hard-coded in test) |
| P3-U04 | 1 (C#) | `char[]` fields in `ScanCommand` are `ByValTStr` with correct size | `analyzer` is 32 bytes, `scan_description` is 256 bytes, `activation_type` is 16 bytes |
| P3-U05 | 1 (C++) | Tracking ID base-36 encoding is correct | `encodeBase36(0)` = "0000", `encodeBase36(1)` = "0001", `encodeBase36(36)` = "0010" |
| P3-U06 | 1 (C++) | Tracking IDs are sequential and unique | Generate 10,000 IDs from a single `FLASHIda` instance, verify all unique, verify sequential |
| P3-U07 | 1 (C++) | `GetNextScanCommand` returns MS1 when queue is empty | Create `FLASHIda`, call `GetNextScanCommand`, verify `msn_level == 1` and `is_agc == 0` |
| P3-U08 | 1 (C++) | Queue priority dequeue order is 3 -> 0 | Push commands at priorities 0, 1, 2, 3, dequeue 4 times, verify order is 3, 2, 1, 0 |
| P3-U09 | 1 (C++) | AGC scan is always dequeued first | Configure AGC, verify `GetNextScanCommand` returns AGC before any queued command |
| P3-U10 | 1 (C++) | Timeout cleanup removes expired commands | Push command, advance clock past timeout, call `GetNextScanCommand`, verify expired command is not returned |
| P3-I01 | 2 | ScanCommand marshaling round-trip | C# populates `ScanCommand` with known values, calls bridge function that reads and echoes values, verify match |
| P3-I02 | 2 | `ProcessScan` stub returns 0 | Call `ProcessScan` with valid spectrum data, verify return value is 0 (stub) |
| P3-I03 | 2 | `GetNextScanCommand` returns valid struct | Call `GetNextScanCommand`, verify returned `ScanCommand` has `msn_level == 1` |
| P3-I04 | 2 | `GetNextTrackingId` returns incrementing values | Call 100 times, verify monotonically increasing |
| P3-I05 | 2 | DLL exports include new functions | `dumpbin /exports OpenMS.dll` contains `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` |
| P3-R01 | 3 | `Flash.exe -t` with shadow validation | Output matches Phase 2 golden files; TRACK log entries present in console output |

**Regression from Phases 1-2:** All P1-* and P2-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("Flash.exe -t runs, behavior unchanged"): Automated by P3-R01.
- WPV-2 ("ScanCommand marshaling"): Automated by P3-I01.
- WPV-3 ("GetNextScanCommand returns MS1"): Automated by P3-U07, P3-I03.
- WPV-4 ("Tracking ID uniqueness"): Automated by P3-U06.

---

### Phase 4: ProcessScan Full Routing — The Switch-Over (Build #2)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P4-U01 | 1 (C++) | ProcessScan MS1 path: deconvolve + score + push commands | Feed synthetic MS1 spectrum with known peaks, verify `processScan` returns > 0 commands |
| P4-U02 | 1 (C++) | All 6 scoring sort branches produce deterministic output | For each branch (`use_idscore_ x consider_all_Charge_states_` = 4, plus QScore alone = 2 total), verify sort order against known spectrum |
| P4-U03 | 1 (C++) | Mass exclusion filtering works | Push precursor, call ProcessScan with same mass within RT window, verify it is excluded |
| P4-U04 | 1 (C++) | MS2 path resolves tracking ID from scan_description | Push MS2 command with known tracking ID, call ProcessScan with matching scan description, verify TRACK-RESOLVE logged |
| P4-U05 | 1 (C++) | MS3 targets are generated from MS2 deconvolution | Configure MS3 mode, feed MS2 spectrum, verify MS3 commands pushed at priority 3 |
| P4-U06 | 1 (C++) | Conditional MS2 follow-ups pushed at priority 2 | Enable conditional MS2, feed qualifying MS2, verify follow-up at priority 2 |
| P4-U07 | 1 (C++) | `isDifferentiallyAbundant` routing in ProcessScan | Enable quant, feed MS2 with reporter ions, verify follow-up pushed only when fold change exceeds threshold |
| P4-U08 | 1 (C++) | Tag-based targeting in ProcessScan | Enable tag targeting, feed MS2 with matching tags, verify inclusion list expanded |
| P4-U09 | 1 (C++) | TRACK audit trail completeness | Feed 10 MS1 + 10 MS2 scans, verify every pushed command has TRACK-CREATE, every resolved scan has TRACK-RESOLVE |
| P4-I01 | 2 | Feature flag `UseUnifiedBridge=False` -> old behavior | Regression: identical output to Phase 3 |
| P4-I02 | 2 | Feature flag `UseUnifiedBridge=True` -> new behavior | Standard DDA output matches old behavior (same scan commands, same deconv results) |
| P4-R01 | 3 | Regression: `UseUnifiedBridge=False` | `Flash.exe -t` output matches Phase 3 golden files |
| P4-R02 | 3 | Standard DDA: `UseUnifiedBridge=True` | `Flash.exe -t` with `method_default.xml` + unified bridge, compare to `standard_dda.tsv` |
| P4-R03 | 3 | Deep mode: `UseUnifiedBridge=True` | `Flash.exe -t` with `method_deep.xml`, compare to `deep_mode.tsv` |
| P4-R04 | 3 | Inclusion list mode | `Flash.exe -t` with `method_inclusion.xml`, compare to golden |
| P4-R05 | 3 | Exclusion list mode | `Flash.exe -t` with `method_exclusion.xml`, compare to golden |
| P4-R06 | 3 | Tag-based targeting mode | `Flash.exe -t` with `method_tag_targeting.xml`, compare to golden |
| P4-R07 | 3 | Isobaric quant mode | `Flash.exe -t` with `method_quant.xml`, compare to golden |
| P4-R08 | 3 | MS3 mode 1 (fragment matching) | `Flash.exe -t` with `method_ms3_mode1.xml`, compare to golden |
| P4-R09 | 3 | MS3 mode 2 | `Flash.exe -t` with `method_ms3_mode2.xml`, compare to golden |
| P4-R10 | 3 | MS3 mode 3 | `Flash.exe -t` with `method_ms3_mode3.xml`, compare to golden |

**Regression from Phases 1-3:** All P1-* through P3-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("UseUnifiedBridge=False identical to Phase 3"): Automated by P4-R01.
- WPV-2 ("UseUnifiedBridge=True standard DDA matches"): Automated by P4-R02.
- WPV-3 ("Each mode works"): Automated by P4-R03 through P4-R10.
- WPV-4 ("TRACK audit trail"): Automated by P4-U09.
- WPV-5 ("Race condition fix"): Automated by P4-U01 (atomic return, no two-step GetPeakGroupSize/GetIsolationWindows).

---

### Phase 5: C# Simplification (no C++ build)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P5-U01 | 1 (C#) | `UnifiedScanProcessor` compiles and instantiates | Constructor does not throw |
| P5-U02 | 1 (C#) | `IScanProcessor` interface has only `void ProcessMS(IMsScan)` | Reflection: interface has exactly 1 method with correct signature |
| P5-U03 | 1 (C#) | No code references `QuantScanProcessor` | Compile succeeds after deletion; grep for `QuantScanProcessor` in `*.cs` returns zero hits |
| P5-U04 | 1 (C#) | `DataPipe` propagates completion correctly | Unit test: push 5 items, complete, verify ActionBlock processed all 5 |
| P5-R01 | 3 | All modes produce identical output to Phase 4 | `Flash.exe -t` with every mode config, compare to Phase 4 golden files |
| P5-R02 | 3 | FAIMS mode still works (ScanScheduler still active) | `Flash.exe -t` with `method_faims_3cv.xml`, compare to golden |

**Regression from Phases 1-4:** All P1-* through P4-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("All modes identical to Phase 4"): Automated by P5-R01.
- WPV-2 ("DataPipe completion"): Automated by P5-U04.
- WPV-3 ("FAIMS still works"): Automated by P5-R02.
- WPV-4 ("QuantScanProcessor fully dead"): Automated by P5-U03.

---

### Phase 6: FAIMS Absorption (Build #3)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P6-U01 | 1 (C++) | CV cycling order matches config | Configure 3 CVs [-40, -50, -60], cycle through, verify order -40 -> -50 -> -60 -> -40 |
| P6-U02 | 1 (C++) | Adaptive CV skipping: low precursor count skips CV | Set threshold=15, push 3 precursors for current CV, call update, verify CV advances |
| P6-U03 | 1 (C++) | CV skip limit enforced | Set max_cv_skip=2, simulate 2 consecutive skips, verify 3rd cycle is forced even with low count |
| P6-U04 | 1 (C++) | `ScanCommand.faims_cv` populated in every dequeued command | Configure FAIMS, dequeue 10 commands, verify all have non-zero `faims_cv` matching current CV |
| P6-U05 | 1 (C++) | CV transition injects MS1 with new CV | During CV transition, verify next dequeued command is MS1 with new CV before any pending MS2s |
| P6-U06 | 1 (C++) | Non-FAIMS mode: `faims_cv` is 0 | Configure without FAIMS CVs, dequeue command, verify `faims_cv == 0` |
| P6-U07 | 1 (C#) | No code references `ScanScheduler` after deletion | Grep returns zero hits (excluding test files and git history) |
| P6-U08 | 1 (C#) | No code references `FAIMSScanProcessor` after deletion | Grep returns zero hits |
| P6-I01 | 2 | FAIMS CV cycling through bridge | C# calls ProcessScan + GetNextScanCommand in loop, verify CV values cycle correctly |
| P6-R01 | 3 | Non-FAIMS regression | `Flash.exe -t` with `method_default.xml`, compare to Phase 5 golden files |
| P6-R02 | 3 | FAIMS 3-CV cycling | `Flash.exe -t` with `method_faims_3cv.xml`, compare CV transition log to golden |
| P6-R03 | 3 | FAIMS adaptive skipping | `Flash.exe -t` with `method_faims_skip.xml`, verify skip behavior in log output |
| P6-S01 | 4 | Stress: rapid scan events during CV transition | 500 rapid ProcessScan calls across 3 CVs, verify no mutex deadlock, no data corruption |

**Regression from Phases 1-5:** All P1-* through P5-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("Non-FAIMS regression"): Automated by P6-R01.
- WPV-2 ("3-CV cycling matches old behavior"): Automated by P6-R02.
- WPV-3 ("Adaptive skipping"): Automated by P6-U02, P6-R03.
- WPV-4 ("Skip limit"): Automated by P6-U03.
- WPV-5 ("ScanScheduler zero references"): Automated by P6-U07.
- WPV-6 ("Stress test"): Automated by P6-S01.

---

### Phase 7: Exploration Engine (Build #4)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P7-U01 | 1 (C++) | ExplorationGroup creation with CE variants | Configure CE 20-40 step 5, create group, verify 5 variants |
| P7-U02 | 1 (C++) | Exploration variants pushed at priority 0 | Create group, verify all variant commands have priority 0 |
| P7-U03 | 1 (C++) | Winner selection by FragmentationQuality score | Feed 5 variant results with known scores, verify winner has highest score |
| P7-U04 | 1 (C++) | Queue overflow protection | Set MaxQueueForExploration=50, fill queue to 51, attempt exploration, verify suppressed |
| P7-U05 | 1 (C++) | MS1 cycle time suppression during exploration | Start exploration, advance clock past cycle time, call GetNextScanCommand, verify no MS1 injected |
| P7-U06 | 1 (C++) | MS1 resumes after exploration completes | Complete exploration, advance clock past cycle time, verify MS1 injected |
| P7-U07 | 1 (C++) | MS3 recursive exploration | Enable MS3 exploration, complete MS2 winner, verify child group created for top fragments |
| P7-U08 | 1 (C++) | Recursive depth limit | Set MaxExplorationDepth=2, attempt depth-3 exploration, verify blocked |
| P7-U09 | 1 (C++) | OptimizationMetadata populated on exploration spectra | Complete exploration variant, verify metadata fields (group_id, variant_index, collision_energy, etc.) |
| P7-U10 | 1 (C++) | Metadata serialized to MSSpectrum via setMetaValue | Complete exploration, call toSpectrum(), verify metavalues present |
| P7-R01 | 3 | Exploration disabled regression | `Flash.exe -t` with `method_default.xml` (exploration off), compare to Phase 6 golden |
| P7-R02 | 3 | Exploration enabled | `Flash.exe -t` with `method_exploration.xml`, verify variant scans in output |

**Regression from Phases 1-6:** All P1-* through P6-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("Exploration disabled regression"): Automated by P7-R01.
- WPV-2 ("5 variants per precursor"): Automated by P7-U01, P7-R02.
- WPV-3 ("Winner selection"): Automated by P7-U03.
- WPV-4 ("Queue overflow"): Automated by P7-U04.
- WPV-5 ("MS1 suppression"): Automated by P7-U05, P7-U06.
- WPV-6 ("OptimizationMetadata populated"): Automated by P7-U09, P7-U10.
- WPV-7 ("MS3 recursive exploration"): Automated by P7-U07, P7-U08.

---

### Phase 8: Cleanup + Documentation (Build #4)

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P8-U01 | 1 (C#) | Only 5 P/Invoke declarations in `FLASHIdaWrapper.cs` | Count `[DllImport` attributes = 5 |
| P8-U02 | 1 (C#) | No reference to `ToFLASHDeconvInput()` in codebase | Grep returns zero hits |
| P8-U03 | 1 (C#) | `MethodDocGenerator` produces output from `[Description]` attributes | Run generator, verify non-empty output with expected field names |
| P8-U04 | 1 (C++) | Legacy config parsing removed | Attempt `CreateFLASHIda("not json")`, verify it fails or returns null (no legacy fallback) |
| P8-I01 | 2 | DLL exports: exactly 5 bridge functions | `dumpbin /exports OpenMS.dll \| grep -c` for `CreateFLASHIda`, `DisposeFLASHIda`, `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` — count = 5, no others matching `FLASH\|Ida\|PeakGroup\|Isolation` |
| P8-I02 | 2 | C# compiles with zero warnings | MSBuild with `/warnaserror` succeeds |
| P8-R01 | 3 | Full regression: every mode config | `Flash.exe -t` with all 12+ method configs, compare to Phase 7 golden files |

**Regression from Phases 1-7:** All P1-* through P7-* tests must pass.

**Working Product Verification automation:**
- WPV-1 ("Flash.exe -t final form"): Automated by P8-R01.
- WPV-2 ("5 exports"): Automated by P8-I01.
- WPV-3 ("Zero warnings"): Automated by P8-I02.
- WPV-4 ("MethodDocGenerator"): Automated by P8-U03.
- WPV-5 ("Full regression all modes"): Automated by P8-R01.

---

## 5. Cross-Project Bridge Tests

The P/Invoke bridge between C# and C++ is the most failure-prone surface in the system. This section specifies dedicated tests beyond what is covered in the per-phase plan.

### 5.1 Struct Marshaling Validation

**`ScanCommand` struct (estimated 550+ bytes):**

```
Offset validation test — hard-coded expected offsets from C++ sizeof/offsetof:

Field                    C++ offset    C# Marshal.OffsetOf
------------------------------------------------------
msn_level                0             0
num_isolation_stages     4             4
stages[0].precursor_mz   8             8
stages[0].activation_type 40           40  (char[16])
stages[9].reagent_agc_target  ???       ???
max_it                   (after stages array)
agc_target               ...
analyzer                 ... (char[32])
faims_cv                 ...
scan_description         ... (char[256])
priority                 ...
enqueue_timestamp_ms     ...
is_agc                   ...
scan_id                  ...
```

A C++ test binary (`ScanCommandLayoutTest`) is created that prints `sizeof(ScanCommand)`, `sizeof(IsolationStage)`, and `offsetof()` for every field. A C# test reads this output and compares against `Marshal.SizeOf` and `Marshal.OffsetOf`. Any mismatch fails the build.

**Implementation:**

```cpp
// OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp
#include <cstddef>
#include <cstdio>
#include "FLASHIda.h"

int main() {
    printf("sizeof_ScanCommand=%zu\n", sizeof(ScanCommand));
    printf("sizeof_IsolationStage=%zu\n", sizeof(IsolationStage));
    printf("offsetof_msn_level=%zu\n", offsetof(ScanCommand, msn_level));
    printf("offsetof_stages=%zu\n", offsetof(ScanCommand, stages));
    printf("offsetof_max_it=%zu\n", offsetof(ScanCommand, max_it));
    // ... all fields
    return 0;
}
```

```csharp
// Flash.Tests/ScanCommandLayoutTests.cs
[Test]
public void ScanCommand_SizeMatchesCpp()
{
    int cppSize = ReadCppLayoutOutput("sizeof_ScanCommand");
    Assert.AreEqual(cppSize, Marshal.SizeOf<ScanCommand>());
}

[Test]
public void ScanCommand_FieldOffsetsMatchCpp()
{
    var expected = ReadCppLayoutOutput(); // dictionary of field -> offset
    Assert.AreEqual(expected["offsetof_msn_level"],
        (int)Marshal.OffsetOf<ScanCommand>("msn_level"));
    // ... all fields
}
```

### 5.2 Round-Trip Tests

**C# -> C++ -> C#:**

1. C# creates a `ScanCommand` with known values (including edge cases: max-length strings, Unicode in `scan_description`, `MAX_ISOLATION_STAGES` stages filled, max `uint64_t` timestamp).
2. C# calls a test bridge function `RoundTripScanCommand(ScanCommand* in, ScanCommand* out)` that copies `*in` to `*out` in C++.
3. C# compares every field of input and output.

**String field edge cases:**
- `analyzer` = exactly 31 chars + null terminator (fills `char[32]`)
- `scan_description` = exactly 255 chars + null terminator (fills `char[256]`)
- `activation_type` = exactly 15 chars + null terminator (fills `char[16]`)
- Empty strings (all zeros)

### 5.3 ABI Compatibility Checks

**Compile-time assertion in C++:**

```cpp
static_assert(sizeof(ScanCommand) == EXPECTED_SIZE,
    "ScanCommand size changed — update C# struct layout");
static_assert(sizeof(IsolationStage) == EXPECTED_SIZE,
    "IsolationStage size changed — update C# struct layout");
```

These fail the C++ build immediately if someone changes the struct without updating the constant, forcing synchronization with the C# side.

### 5.4 DLL Export Symbol Verification

```yaml
- name: Verify DLL exports
  shell: cmd
  run: |
    dumpbin /exports FlashIDA\dll\OpenMS.dll > exports.txt
    findstr /C:"CreateFLASHIda" exports.txt || exit /b 1
    findstr /C:"DisposeFLASHIda" exports.txt || exit /b 1
    findstr /C:"ProcessScan" exports.txt || exit /b 1
    findstr /C:"GetNextScanCommand" exports.txt || exit /b 1
    findstr /C:"GetNextTrackingId" exports.txt || exit /b 1
```

In Phase 8, this is extended to verify that old exports (`GetPeakGroupSize`, `GetIsolationWindows`, etc.) are absent.

---

## 6. Regression Test Suite

### 6.1 Golden-File Capture

The regression suite uses `Flash.exe -t` as the test harness. The current test mode signature is:

```
Flash.exe -t <input_spectrum_file> <output_file> <method.xml> [ms2_spectrum_file]
```

The CI script runs this for each configuration:

```powershell
# regression-runner.ps1
$configs = @(
    @{ name="standard_dda"; method="method_default.xml"; ms1="ms1_standard.txt"; ms2=$null },
    @{ name="deep_mode";    method="method_deep.xml";    ms1="ms1_standard.txt"; ms2=$null },
    @{ name="inclusion";    method="method_inclusion.xml"; ms1="ms1_standard.txt"; ms2=$null },
    @{ name="tag_targeting"; method="method_tag_targeting.xml"; ms1="ms1_standard.txt"; ms2="ms2_hcd_fragment.txt" },
    # ... all modes
)

foreach ($cfg in $configs) {
    $args = @("test-data\spectra\$($cfg.ms1)", "output\$($cfg.name).tsv", "test-data\configs\$($cfg.method)")
    if ($cfg.ms2) { $args += "test-data\spectra\$($cfg.ms2)" }
    & bin\Flash.exe -t @args
}
```

### 6.2 Comparison Logic

Golden files are TSV with columns: `rt`, `mz1`, `mz2`, `qScore`, `charges`, `monoMasses`, `ccos`, `csnr`, `cos`, `snr`, `cScore`, `ppm`, `precursorIntensity`, `massIntensity`, `hcd`.

The comparison tool:

1. **Row count must match exactly.** A missing or extra precursor target is a regression.
2. **String columns** (`charges`): exact match.
3. **Floating-point columns** (`rt`, `mz1`, `mz2`, `qScore`, `monoMasses`, etc.): absolute tolerance of 1e-6 by default, or relative tolerance of 1e-4 for values > 1.0.
4. **Integer columns** (`hcd`): exact match.

Implementation — a small Python script `compare_golden.py`:

```python
#!/usr/bin/env python3
"""Compare two TSV files with numeric tolerance."""
import sys, csv, math

FLOAT_COLS = {'rt','mz1','mz2','qScore','monoMasses','ccos','csnr',
              'cos','snr','cScore','ppm','precursorIntensity','massIntensity'}
ABS_TOL = 1e-6
REL_TOL = 1e-4

def compare(golden_path, actual_path):
    with open(golden_path) as gf, open(actual_path) as af:
        golden = list(csv.DictReader(gf, delimiter='\t'))
        actual = list(csv.DictReader(af, delimiter='\t'))

    if len(golden) != len(actual):
        print(f"FAIL: row count {len(golden)} vs {len(actual)}")
        return False

    ok = True
    for i, (g, a) in enumerate(zip(golden, actual)):
        for col in g:
            if col in FLOAT_COLS:
                gv, av = float(g[col]), float(a[col])
                if abs(gv) > 1.0:
                    if abs(gv - av) / abs(gv) > REL_TOL:
                        print(f"FAIL row {i} col {col}: {gv} vs {av}")
                        ok = False
                else:
                    if abs(gv - av) > ABS_TOL:
                        print(f"FAIL row {i} col {col}: {gv} vs {av}")
                        ok = False
            else:
                if g[col] != a[col]:
                    print(f"FAIL row {i} col {col}: {g[col]!r} vs {a[col]!r}")
                    ok = False
    return ok

if __name__ == '__main__':
    if not compare(sys.argv[1], sys.argv[2]):
        sys.exit(1)
    print("PASS")
```

### 6.3 Golden File Updates

When an intentional behavioral change occurs (e.g., Phase 4 switch-over changes scoring order):

1. Developer runs the regression suite locally: `powershell regression-runner.ps1`.
2. Developer inspects the diff between old and new golden files.
3. Developer commits the updated golden files in the same PR as the code change.
4. PR reviewers verify that golden file changes are expected and explained in the PR description.

The CI workflow flags any golden file mismatch as a test failure. The PR cannot merge until golden files match.

---

## 7. Mode Coverage Matrix

This table tracks which acquisition modes are tested at each phase. A filled cell means the mode is actively tested (not just regressing).

| Mode | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 |
|------|----|----|----|----|----|----|----|----|
| Standard DDA | R | R | R | **NEW** | R | R | R | R |
| Deep mode | R | R | R | **NEW** | R | R | R | R |
| Inclusion list | R | R | R | **NEW** | R | R | R | R |
| Exclusion list | R | R | R | **NEW** | R | R | R | R |
| Tag-based targeting | - | - | - | **NEW** | R | R | R | R |
| Conditional MS2 | - | - | - | **NEW** | R | R | R | R |
| Isobaric quant | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 1 (SPS) | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 2 (CID) | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 3 (HCD) | - | - | - | **NEW** | R | R | R | R |
| FAIMS (multi-CV) | - | - | - | - | R | **NEW** | R | R |
| FAIMS adaptive skip | - | - | - | - | - | **NEW** | R | R |
| Exploration (CE opt) | - | - | - | - | - | - | **NEW** | R |
| Exploration (MS3) | - | - | - | - | - | - | **NEW** | R |

**Legend:** **NEW** = mode first tested at this phase with dedicated test cases. **R** = regression (must still pass, using golden files from when mode was first tested). **-** = not yet applicable.

---

## 8. Test Data Requirements

### 8.1 Spectrum Data Files

| File | Format | Description | Source |
|------|--------|-------------|--------|
| `ms1_standard.txt` | TSV (mz, intensity per line, spectra delimited by header lines) | Representative MS1 spectra from a top-down experiment. Must contain identifiable charge envelopes for deconvolution. | Extract from an existing mzML file using pyOpenMS, convert to the tab-delimited format `FLASHIdaWrapper.Main()` expects. |
| `ms2_hcd_fragment.txt` | TSV (mz, intensity) | Single MS2 HCD fragmentation spectrum with known fragment ions matching a known protein sequence. | Extract a good MS2 spectrum from existing test data. |
| `ms1_faims_3cv.txt` | TSV | MS1 spectra with header annotations indicating CV values. Simulates FAIMS cycling. | Construct synthetically or extract from FAIMS experiment data. |
| `ms1_high_density.txt` | TSV | MS1 spectrum with 50+ deconvolvable proteoforms. Used for queue saturation stress tests. | Extract from a complex top-down sample. |

### 8.2 Method Configuration Files

All method configs listed in Section 3.4 must be created. Each is a variant of the base `method.xml` with specific mode settings enabled. These are small XML files (< 5 KB each) and are committed to the repository.

### 8.3 Golden Output Files

One `.tsv` per (spectrum, config) combination. Created by running `Flash.exe -t` with the corresponding inputs on a known-good build. Committed to the repository.

### 8.4 JSON Reference Files

`config_default.json` and `config_full.json` are the expected JSON outputs from `Parameter.ToJSON()` for the default and full-featured method configs respectively. Used in Phase 1 unit tests.

### 8.5 Data Size and Storage

- Total estimated test data: < 50 MB (text spectrum files are compact).
- Golden files: < 1 MB total.
- Config files: < 100 KB total.
- All test data is committed to the repository under `FlashIDA/test-data/`.
- If spectrum files grow large, they can be stored as Git LFS objects.

### 8.6 Data Preparation Script

A one-time script `prepare-test-data.py` converts source mzML files to the tab-delimited format expected by `FLASHIdaWrapper.Main()`:

```python
#!/usr/bin/env python3
"""Convert mzML spectra to tab-delimited format for Flash.exe -t."""
import pyopenms as oms
import sys

exp = oms.MSExperiment()
oms.MzMLFile().load(sys.argv[1], exp)

with open(sys.argv[2], 'w') as f:
    for spec in exp:
        if spec.getMSLevel() != 1:
            continue
        rt = spec.getRT() / 60.0  # seconds to minutes
        f.write(f"Spec {spec.getNativeID()} rt={rt:.4f}\n")
        for peak in spec:
            f.write(f"{peak.getMZ():.6f}\t{peak.getIntensity():.2f}\n")
```

This script is run once to create the initial test data files, then the outputs are committed.

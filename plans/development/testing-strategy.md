# Testing Strategy for FLASHIda Migration

**Date:** 2026-03-21
**Applies to:** baseline-plan.md (v9) — Phases 0-8, Builds #1-#4

---

## 0. Initial Setup

This section describes the one-time setup required before any tests can be run, whether locally or in CI.

### 0.1 System Prerequisites

**Windows (C# development and all integration/regression tests):**

- .NET Framework 4.8 Developer Pack
- MSBuild (via Visual Studio Build Tools 2022 or Visual Studio 2022)
- NuGet CLI (`nuget.exe` on PATH)
- `dumpbin.exe` (ships with VS Build Tools; used for DLL export verification)
- Python 3.8+ (for `compare_golden.py` and `prepare-test-data.py`)

**Linux (C++ unit tests only):**

- GCC 11+ or Clang 14+ (C++20 support required)
- CMake 3.20+
- ccache (strongly recommended; CI uses it for incremental builds)
- Python 3.8+

### 0.2 Clone Repository with Submodules

The OpenMS engine is a Git submodule. Always clone recursively:

```bash
git clone --recursive https://github.com/kohlbacherlab/FLASHIda.git
cd FLASHIda
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

### 0.3 NuGet Package Restoration

```powershell
nuget restore FlashIDA/src/Flash.sln
```

This restores all NuGet dependencies (NUnit, NUnit3TestAdapter, etc.) into the `packages/` directory.

### 0.4 Proprietary Dependencies Setup

Thermo iAPI DLLs (`API-2.0.dll`, `Fusion.API-1.0.dll`, etc.) are required for building `Flash.exe` and running regression tests. These are proprietary and not committed to the repository.

See **Section 3.3** for detailed instructions on obtaining and configuring these DLLs for both local development and CI.

### 0.5 OpenMS DLL Procurement

The C# tests and regression suite require pre-built OpenMS DLLs (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`). Two options:

1. **From CI (preferred):** Download the latest artifact from the `build-openms-dll.yml` workflow run. Place all DLLs in `FlashIDA/dll/`.

2. **Local build (slow, 30-60 min):** Follow the build instructions in `OpenMS/CLAUDE.md`. Copy output DLLs to `FlashIDA/dll/`.

### 0.6 Test Data Setup

If test data files do not yet exist under `FlashIDA/test-data/`, generate them from source mzML files:

```bash
python prepare-test-data.py <source.mzML> FlashIDA/test-data/spectra/ms1_standard.txt
```

See Section 8 for full test data requirements. Once generated, test data files are committed to the repository.

### 0.7 Build Flash.sln

```powershell
msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```

Verify that `Flash.exe` is produced in the output directory.

### 0.8 First Local Test Run

Run the smoke test to verify the full toolchain:

```powershell
# Unit tests
nunit3-console FlashIDA/src/Flash.Tests/bin/Debug/Flash.Tests.dll

# Regression test (test mode)
FlashIDA/src/Flash/bin/Debug/Flash.exe -t test-data/spectra/ms1_standard.txt output.tsv test-data/configs/method_default.xml
```

### 0.9 CI-Specific Setup

**GitHub Actions secrets required:**

| Secret Name | Purpose | See Section |
|-------------|---------|-------------|
| `THERMO_IAPI_DLLS_BASE64` | Base64-encoded Thermo iAPI DLLs (Strategy A) | 3.3 |
| `THERMO_DLL_PASSPHRASE` | Decryption passphrase for encrypted DLL blob (Strategy B) | 3.3 |

**Runner requirements:**

- `windows-latest` — for C# build, integration tests, regression tests
- `ubuntu-latest` — for C++ unit tests only

**First-run checklist:**

1. Ensure secrets are configured in repository settings
2. Trigger `build-openms-dll.yml` manually to create the initial DLL artifact
3. Trigger `flashida-ci.yml` and verify all jobs pass
4. Verify golden file comparison produces `PASS` output

---

## 1. Testing Philosophy

FLASHIda operates at the intersection of two codebases (C# and C++), has no instrument hardware in CI, and has zero existing automated tests. The strategy therefore focuses on:

- **Test what can be tested offline.** Every piece of logic that does not require `IFusionInstrumentAccess` is testable. This includes all deconvolution, scoring, configuration parsing, struct marshaling, queue behavior, and mode routing.
- **Golden-file regression is the safety net.** `Flash.exe -t` already exists as an offline deconvolution harness. Its output, captured to files, becomes the regression baseline that gates every PR.
- **C++ tests are gated by pre-built artifacts.** Building OpenMS from source takes 30-60 minutes on a beefy runner. CI uses cached DLL artifacts from `build_dlls.yml` for the C# test tier, and only rebuilds OpenMS when C++ source changes.
- **Bridge correctness is paramount.** The P/Invoke boundary is the single most fragile surface. It gets its own dedicated test binary and validation suite.
- **Every phase adds tests; no phase removes them.** The test suite is purely additive. Phase N's tests become Phase N+1's regression suite.
- **All tests run on every commit.** There is no nightly-only tier. Every push triggers the full test suite. Stress tests use reduced iteration counts to stay within time budgets.

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

### Tier 4: Stress Tests (every PR, < 10 min)

**What:** Tests that validate behavior under load or edge conditions. These use reduced iteration counts to fit within the per-commit time budget.

- Queue saturation: 1,000 rapid `ProcessScan` calls, verify no memory leaks, all tracking IDs unique.
- FAIMS CV cycling: simulate 50 scan events across 3 CVs, verify CV transition counts match expectations.
- Exploration engine: verify variant explosion limits (MaxQueueForExploration) are respected.
- Thread safety: concurrent `ProcessScan` + `GetNextScanCommand` from 2 threads, verify `queue_mutex_` prevents corruption.

**When:** On every push to any PR branch. Runs on `windows-latest`.

---

## 3. Test Infrastructure

### 3.1 GitHub Actions Workflow Structure

```
.github/workflows/
  flashida-ci.yml          # Main CI workflow (Tiers 1-4, all tests)
  build-openms-dll.yml     # OpenMS DLL build (triggered only on C++ changes)
```

**Branch strategy:** Development uses coordinated dual branches:

- **FlashIDA:** `flashida-v9-migration` (branched from `develop`)
- **OpenMS submodule:** `flashida-v9-bridge` (branched from `FIdevelop`)

CI triggers include these branches alongside `main` and `develop`.

**`flashida-ci.yml`** is the PR gate. It has four jobs covering all tiers:

```yaml
name: flashida-ci
on:
  push:
    branches: [main, develop, flashida-v9-migration, 'phase-*']
  pull_request:
    branches: [main, develop, flashida-v9-migration]

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

  stress-tests:
    runs-on: windows-latest
    needs: [csharp-tests]           # reuses build artifacts
    steps:
      - run stress test suite (reduced iterations: 1k ProcessScan, 50 FAIMS events)
      - run thread safety validation
```

### 3.2 Handling the C++ Build

The OpenMS build is extremely expensive. The strategy:

1. **`build-openms-dll.yml`** already exists on the `FIdevelop` branch (see `OpenMS/.github/workflows/build_dlls.yml`). It builds on `windows-2022`, produces `OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll` as artifacts.

2. **Artifact caching:** The `flashida-ci.yml` workflow downloads the latest DLL artifact from `build-openms-dll.yml` using `actions/download-artifact` (cross-workflow) or a GitHub release asset. DLLs are cached with a key derived from the OpenMS submodule commit hash:

   ```bash
   git -C OpenMS rev-parse HEAD
   ```

3. **Conditional rebuild:** The CI workflow checks the submodule commit hash against the cached artifact key. If the hash matches, it skips the C++ build entirely and uses cached DLLs. If the hash differs, a rebuild is triggered.

4. **C++ unit tests** are built separately — they only compile the test binaries, not the full OpenMS library. This is faster (~10 min vs 30-60 min) when using ccache from the existing workflow.

**Cache key implementation:**

```yaml
- name: Get OpenMS submodule commit hash
  id: openms-hash
  run: |
    echo "hash=$(git -C OpenMS rev-parse HEAD)" >> $GITHUB_OUTPUT

- name: Restore cached OpenMS DLLs
  id: dll-cache
  uses: actions/cache@v4
  with:
    path: FlashIDA/dll/
    key: openms-dlls-${{ steps.openms-hash.outputs.hash }}

- name: Download OpenMS DLLs from build workflow
  if: steps.dll-cache.outputs.cache-hit != 'true'
  uses: dawidd6/action-download-artifact@v3
  with:
    workflow: build_dlls.yml
    name: openms-dlls
    path: FlashIDA/dll/
    branch: flashida-v9-bridge
```

### 3.3 Handling Proprietary DLLs

Thermo iAPI DLLs (`API-2.0.dll`, `Fusion.API-1.0.dll`, etc.) are proprietary and cannot be committed to the repository in plaintext. Two strategies are available depending on the total DLL size.

#### Strategy A: Base64 Secrets (for DLLs < 32 KB each)

Suitable when individual DLL files are small enough to fit within GitHub's secret size limit.

**One-time setup (local machine with access to the DLLs):**

```powershell
# Encode each DLL as base64 and copy to clipboard for GitHub secret creation
$dllDir = "FlashIDA\dependencies"
$dlls = @("API-2.0.dll", "Fusion.API-1.0.dll")  # Add all required DLLs

foreach ($dll in $dlls) {
    $bytes = [System.IO.File]::ReadAllBytes("$dllDir\$dll")
    $b64 = [Convert]::ToBase64String($bytes)
    Write-Host "=== $dll (length: $($b64.Length) chars) ==="
    Set-Clipboard $b64
    Read-Host "Base64 for $dll copied to clipboard. Add as GitHub secret, then press Enter"
}
```

Add each base64 string as a GitHub repository secret. For a single combined secret (`THERMO_IAPI_DLLS_BASE64`), zip the DLLs first, then base64-encode the zip.

**CI workflow step:**

```yaml
- name: Restore Thermo iAPI DLLs
  shell: powershell
  env:
    THERMO_DLLS_B64: ${{ secrets.THERMO_IAPI_DLLS_BASE64 }}
  run: |
    $bytes = [Convert]::FromBase64String($env:THERMO_DLLS_B64)
    [System.IO.File]::WriteAllBytes("thermo-dlls.zip", $bytes)
    Expand-Archive -Path "thermo-dlls.zip" -DestinationPath "FlashIDA\dependencies" -Force
    Remove-Item "thermo-dlls.zip"
    Write-Host "Restored Thermo DLLs to FlashIDA\dependencies"
    Get-ChildItem "FlashIDA\dependencies\*.dll" | ForEach-Object { Write-Host "  $_" }
```

#### Strategy B: Encrypted Blob (for larger DLLs)

Suitable when DLLs exceed the GitHub secrets size limit. The encrypted archive is committed to the repository; only the passphrase is a secret.

**One-time setup:**

```powershell
# Create AES-256 encrypted 7z archive of all proprietary DLLs
# Requires 7-Zip installed (available on all GitHub Actions Windows runners)
$passphrase = [System.Guid]::NewGuid().ToString()  # Generate strong passphrase
Write-Host "Passphrase (add as THERMO_DLL_PASSPHRASE secret): $passphrase"

7z a -p"$passphrase" -mhe=on -t7z `
    "FlashIDA\dependencies\thermo-iapi-encrypted.7z" `
    "FlashIDA\dependencies\API-2.0.dll" `
    "FlashIDA\dependencies\Fusion.API-1.0.dll"
    # Add all required DLLs

Write-Host "Encrypted archive created. Commit thermo-iapi-encrypted.7z to the repo."
Write-Host "Add passphrase as GitHub secret THERMO_DLL_PASSPHRASE"
```

**CI workflow step:**

```yaml
- name: Decrypt Thermo iAPI DLLs
  shell: powershell
  env:
    THERMO_PASSPHRASE: ${{ secrets.THERMO_DLL_PASSPHRASE }}
  run: |
    7z x "FlashIDA\dependencies\thermo-iapi-encrypted.7z" `
      -p"$env:THERMO_PASSPHRASE" `
      -o"FlashIDA\dependencies" -aoa
    Write-Host "Decrypted Thermo DLLs:"
    Get-ChildItem "FlashIDA\dependencies\*.dll" | ForEach-Object { Write-Host "  $_" }
```

#### Local Development Setup

For local development, simply place the Thermo iAPI DLLs directly in `FlashIDA/dependencies/`. Obtain them from:

1. An existing Thermo instrument control installation
2. A team member via secure file transfer (see onboarding below)
3. The Thermo iAPI NuGet package (if licensed)

Verify the DLLs are present:

```powershell
# Quick check — should list API-2.0.dll, Fusion.API-1.0.dll, etc.
Get-ChildItem FlashIDA\dependencies\*.dll | Select-Object Name
```

#### Security Notes

- GitHub Actions automatically redacts secret values from log output. Do not echo secrets directly.
- The encrypted 7z archive (Strategy B) uses AES-256 with header encryption (`-mhe=on`), so file names inside the archive are also encrypted.
- Onboard new developers by sharing the DLLs via a secure channel (encrypted email, shared drive with access control, or direct transfer). Never share via unencrypted channels.
- `.gitignore` should contain `FlashIDA/dependencies/*.dll` to prevent accidental commits of plaintext DLLs.

### 3.4 Handling the C# Build

```yaml
- name: Setup MSBuild
  uses: microsoft/setup-msbuild@v2

- name: Restore NuGet packages
  run: nuget restore FlashIDA/src/Flash.sln

- name: Build solution
  run: msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```

**Test project setup:**

```
FlashIDA/src/Flash.Tests/
  Flash.Tests.csproj          # References Flash.csproj, NUnit
  SmokeTests.cs               # Phase 0 smoke tests
  BridgeSmokeTests.cs         # Phase 0 bridge smoke tests
  JsonConfigTests.cs
  ScanCommandLayoutTests.cs
  MethodParameterTests.cs
  TrackingIdTests.cs
```

The test project targets .NET Framework 4.8 and uses NUnit 3 as the test framework. It references the main `Flash.csproj` and adds `nunit3-console` for CLI execution in CI.

### 3.5 Test Data Management

Test data lives in a dedicated directory:

```
FlashIDA/test-data/
  spectra/
    ms1_smoke_test.txt        # Minimal spectrum for Phase 0 smoke test
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
    README.md                 # Documents golden file provenance and update procedure
    baseline_phase0.tsv       # Phase 0 baseline capture (current behavior)
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

### Phase 0: Establish Baseline

**Purpose:** Capture the current behavior of the existing codebase before any migration changes. This phase creates the safety net that all subsequent phases rely on.

**Tests added:**

| Test ID | Tier | Description | Expected Outcome |
|---------|------|-------------|------------------|
| P0-U01 | 1 (C#) | `Flash.sln` compiles without error | MSBuild exit code 0, no errors in output |
| P0-U02 | 1 (C#) | `Flash.exe` exists in build output | File exists at expected path after build |
| P0-U03 | 3 | `Flash.exe -t` runs with minimal spectrum, exits cleanly | Process exit code 0, no unhandled exceptions |
| P0-U04 | 3 | `Flash.exe -t` output is non-empty valid TSV | Output file has header row + at least 1 data row, all columns present |
| P0-I01 | 2 | `CreateFLASHIda()` does not crash | Bridge call returns non-null pointer, no access violation |
| P0-I02 | 2 | `DisposeFLASHIda()` does not crash | Bridge call completes without exception after `CreateFLASHIda()` |
| P0-R01 | 3 | Golden file captured as `baseline_phase0.tsv` | `Flash.exe -t` output saved; this becomes the regression baseline for Phase 1 |

**Files created:**

| File | Purpose |
|------|---------|
| `Flash.Tests.csproj` | NUnit test project, references Flash.csproj |
| `SmokeTests.cs` | P0-U01 through P0-U04 |
| `BridgeSmokeTests.cs` | P0-I01, P0-I02 |
| `ms1_smoke_test.txt` | Minimal spectrum (5-10 peaks with a recognizable charge envelope) |
| `baseline_phase0.tsv` | Captured output, committed as first golden file |
| `golden/README.md` | Documents golden file provenance, how to update, and review expectations |

**Working Product Verification automation:**
- WPV-1 ("Solution builds"): Automated by P0-U01, P0-U02.
- WPV-2 ("Test mode runs"): Automated by P0-U03, P0-U04.
- WPV-3 ("Bridge doesn't crash"): Automated by P0-I01, P0-I02.
- WPV-4 ("Baseline captured"): Automated by P0-R01.

---

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
| P1-R01 | 3 | `Flash.exe -t` with JSON config path | Output matches `baseline_phase0.tsv` golden file |
| P1-R02 | 3 | `Flash.exe -t` with legacy config (regression) | Output matches `baseline_phase0.tsv` — auto-detect fallback works |

**Regression from Phase 0:** All P0-* tests must pass.

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
| P2-R01 | 3 | `Flash.exe -t` unchanged behavior | Output matches Phase 0/1 golden files exactly (no metadata populated yet) |

**Regression from Phases 0-1:** All P0-* and P1-* tests must pass.

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

**Regression from Phases 0-2:** All P0-* through P2-* tests must pass.

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

**Regression from Phases 0-3:** All P0-* through P3-* tests must pass.

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

**Regression from Phases 0-4:** All P0-* through P4-* tests must pass.

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
| P6-S01 | 4 | Stress: rapid scan events during CV transition | 50 rapid ProcessScan calls across 3 CVs, verify no mutex deadlock, no data corruption |

**Regression from Phases 0-5:** All P0-* through P5-* tests must pass.

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

**Regression from Phases 0-6:** All P0-* through P6-* tests must pass.

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

**Regression from Phases 0-7:** All P0-* through P7-* tests must pass.

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

| Mode | P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 |
|------|----|----|----|----|----|----|----|----|----|
| Standard DDA | **BASE** | R | R | R | **NEW** | R | R | R | R |
| Deep mode | - | R | R | R | **NEW** | R | R | R | R |
| Inclusion list | - | R | R | R | **NEW** | R | R | R | R |
| Exclusion list | - | R | R | R | **NEW** | R | R | R | R |
| Tag-based targeting | - | - | - | - | **NEW** | R | R | R | R |
| Conditional MS2 | - | - | - | - | **NEW** | R | R | R | R |
| Isobaric quant | - | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 1 (SPS) | - | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 2 (CID) | - | - | - | - | **NEW** | R | R | R | R |
| MS3 mode 3 (HCD) | - | - | - | - | **NEW** | R | R | R | R |
| FAIMS (multi-CV) | - | - | - | - | - | R | **NEW** | R | R |
| FAIMS adaptive skip | - | - | - | - | - | - | **NEW** | R | R |
| Exploration (CE opt) | - | - | - | - | - | - | - | **NEW** | R |
| Exploration (MS3) | - | - | - | - | - | - | - | **NEW** | R |

**Legend:** **BASE** = baseline capture (current behavior, used as regression anchor). **NEW** = mode first tested at this phase with dedicated test cases. **R** = regression (must still pass, using golden files from when mode was first tested). **-** = not yet applicable.

---

## 8. Test Data Requirements

### 8.1 Spectrum Data Files

| File | Format | Description | Source |
|------|--------|-------------|--------|
| `ms1_smoke_test.txt` | TSV (mz, intensity per line) | Minimal spectrum (5-10 peaks) for Phase 0 smoke test. Must contain at least one recognizable charge envelope. | Construct synthetically or extract a single scan from existing data. |
| `ms1_standard.txt` | TSV (mz, intensity per line, spectra delimited by header lines) | Representative MS1 spectra from a top-down experiment. Must contain identifiable charge envelopes for deconvolution. | Extract from an existing mzML file using pyOpenMS, convert to the tab-delimited format `FLASHIdaWrapper.Main()` expects. |
| `ms2_hcd_fragment.txt` | TSV (mz, intensity) | Single MS2 HCD fragmentation spectrum with known fragment ions matching a known protein sequence. | Extract a good MS2 spectrum from existing test data. |
| `ms1_faims_3cv.txt` | TSV | MS1 spectra with header annotations indicating CV values. Simulates FAIMS cycling. | Construct synthetically or extract from FAIMS experiment data. |
| `ms1_high_density.txt` | TSV | MS1 spectrum with 50+ deconvolvable proteoforms. Used for queue saturation stress tests. | Extract from a complex top-down sample. |

### 8.2 Method Configuration Files

All method configs listed in Section 3.5 must be created. Each is a variant of the base `method.xml` with specific mode settings enabled. These are small XML files (< 5 KB each) and are committed to the repository.

### 8.3 Golden Output Files

One `.tsv` per (spectrum, config) combination. Created by running `Flash.exe -t` with the corresponding inputs on a known-good build. Committed to the repository. Phase 0 produces `baseline_phase0.tsv` as the initial golden file.

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

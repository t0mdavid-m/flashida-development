# Environment and Workflows — FLASHIda v9 Migration

**Applies to:** All phases (0–8), all four C++ builds.
**Cross-references:**
- [implementation-roadmap.md](implementation-roadmap.md) — CI Environment Requirements, Build Batching
- [testing-strategy.md](testing-strategy.md) — Test tiers, DLL strategies (Sections 3.1, 3.2, 3.3)
- Per-phase plans `Phase_0/` through `Phase_8/implementation-plan.md` — phase-specific CI notes

---

## 1. CI Environment Overview

### Runner Types

| Runner | Purpose | Active jobs |
|--------|---------|-------------|
| `ubuntu-latest` | C++ unit tests only | `cpp-unit-tests` |
| `windows-latest` | C# build, integration, regression, stress | `windows-tests` |

The two runner types are independent and execute in parallel whenever both have work to do.

**No local Windows machine is required.** All C# builds, integration tests, and regression runs happen exclusively on `windows-latest`. The `windows-latest` runner provides everything needed: MSBuild (via VS Build Tools 2022), NuGet CLI, .NET Framework 4.8, `dumpbin.exe`, Python 3.8+, and openssl.

### Pre-Installed Software

**`windows-latest`:**
- Visual Studio Build Tools 2022 (MSBuild + `dumpbin.exe`)
- .NET Framework 4.8 Developer Pack
- NuGet CLI (`nuget.exe` on PATH)
- Python 3.8+
- openssl (for Strategy B DLL decryption; `openssl enc -aes-256-cbc -pbkdf2`)

**`ubuntu-latest`:**
- GCC 11+ or Clang 14+ (C++20 support)
- CMake 3.20+
- ccache (for incremental C++ builds)
- Python 3.8+
- **Required apt packages for `cpp-unit-tests` (Phase 2+):** `build-essential ccache ninja-build qt6-base-dev libeigen3-dev libboost-random-dev libboost-regex-dev libboost-iostreams-dev libboost-date-time-dev libboost-math-dev libxerces-c-dev zlib1g-dev libsvm-dev libbz2-dev liblzma-dev libzstd-dev coinor-libcoinmp-dev`. This full list was discovered iteratively during Phase 2 (XercesC initially missing, then liblzma missing).

---

## 2. Required Secrets and Artifacts

### Thermo iAPI DLLs

`Flash.csproj` has compile-time references to five Thermo assemblies:
`API-2.0.dll`, `Fusion.API-1.0.dll`, `Spectrum-1.0.dll`, `Thermo.TNG.Factory.dll`, `Thermo.TNG.Client.API.dll`.

These are proprietary and not committed to the repository. They must be present in `FlashIDA/dependencies/` before MSBuild runs.

**Chosen strategy: openssl-encrypted archive (`THERMO_DLL_PASSPHRASE`)**
- The five Thermo DLLs compress to a 75 KB zip. Base64 encoding produces 101 KB, exceeding GitHub's 48 KB per-secret limit, so Strategy A (base64 secret) is not viable.
- The encrypted archive is committed at `FlashIDA/dependencies/thermo-dlls.zip.enc`, encrypted with `openssl enc -aes-256-cbc -pbkdf2`. The passphrase is stored as the `THERMO_DLL_PASSPHRASE` GitHub repository secret.
- CI step: `openssl enc -d -aes-256-cbc -pbkdf2` to decrypt → `Expand-Archive` to `FlashIDA\dependencies\` → delete zip.
- GPG encryption does not work on Windows CI runners (digest algorithm incompatibility). Always use openssl.
- See [testing-strategy.md Section 3.3](testing-strategy.md#33-handling-proprietary-dlls) for the one-time setup commands.

> **Note (`.gitattributes`):** `FlashIDA/.gitattributes` has `* text eol=crlf`, which forces CRLF conversion on all files. Binary files (`.enc`, `.zip`, `.gpg`) are silently corrupted by this conversion. Ensure `.gitattributes` contains `*.enc binary`, `*.zip binary`, and `*.gpg binary` entries before committing any encrypted or compressed archives. (Phase 0 lesson #4)

After restoring, the CI step also copies Thermo DLLs into the build output directory alongside `Flash.exe`. This prevents `FileNotFoundException` at runtime if the .NET CLR attempts to resolve Thermo assemblies during JIT compilation of `FLASHIdaWrapper`.

### OpenMS DLL Artifacts

Pre-built Windows DLLs (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`) are already committed in `FlashIDA/dll/`. MSBuild copies these to the build output directory (`FlashIDA/bin/`) alongside `Flash.exe` via `CopyToOutputDirectory` in `Flash.csproj`. **No cache or cross-workflow download step is needed in CI.** (Phase 0 lesson #5)

> **When DLLs need rebuilding:** If the OpenMS submodule is advanced and the C++ bridge API changes, the DLLs must be rebuilt. At that point, a `build-openms-dll.yml` workflow and cache/download steps should be reintroduced. Until then, the committed DLLs are used as-is.

---

## 3. CI Workflow Architecture

### Workflow Files

```
.github/workflows/
  flashida-ci.yml          # Main workflow: all test tiers, PR gate
  build-openms-dll.yml     # OpenMS DLL build (C++ changes only; not needed while DLLs are committed in FlashIDA/dll/)
```

### `flashida-ci.yml` Jobs

```
cpp-unit-tests  (ubuntu-latest)       windows-tests  (windows-latest)
        |                                      |
        |            [parallel]                |
        |                                      |
   C++ unit tests                     Steps (sequential):
   (ctest -R ClassName)                1. Build (MSBuild)
                                       2. NUnit tests (Tiers 1+2)
                                       3. Bridge verification (if: always())
                                       4. Regression suite (Tier 3)
                                       5. Stress tests (Tier 4, conditional)
```

**`cpp-unit-tests`** (Tier 1, ubuntu-latest):
- Installs apt dependencies (see Section 1 for the full list).
- Restores ccache; builds only the FLASH test binaries (not the full OpenMS library).
- CMake flags for test-only builds: `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`. These flags produce an efficient build that skips the GUI and Python bindings.
- ccache key uses `hashFiles('OpenMS/CMakeLists.txt')` for cache invalidation (not `executables.cmake`).
- Runs `ctest -R ClassName --output-on-failure` (e.g., `ctest -R DeconvolvedSpectrum_OptimizationMetadata`). Test names follow the OpenMS `ClassName_test.cpp` convention, not a `FLASH` prefix.
- No Thermo or .NET dependency.
- Active starting Phase 2 (first C++ tests); disabled with `if: false` in Phase 0.

**`windows-tests`** (Tiers 1–4, windows-latest):
- Restores Thermo DLLs from secret. OpenMS DLLs are already committed in `FlashIDA/dll/` (no download needed).
- Builds solution via MSBuild; copies DLLs to build output (`FlashIDA/bin/`).
- Runs NUnit tests by full path from the NuGet packages directory (e.g., `packages\NUnit.ConsoleRunner.3.x.x\tools\nunit3-console.exe`), with working directory set to `FlashIDA/bin/` so that native DLLs are found by the .NET runtime. Uses `--where "class =~ ..."` filter (not `--where "cat == ..."`) for bridge test selection. Passes `--agents=1 --timeout=300000` to prevent cold-cache timeouts on `calculateAveragine` and avoid parallel process interference. Covers Tier 1 (unit) and Tier 2 (integration/bridge) tests. (Phase 1 lessons #8, #9.)
- Sets `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS` as an environment variable on the NUnit test step. This is required for all steps that invoke OpenMS functionality via P/Invoke; without it the DLL cannot locate chemistry data files (residue masses, isotope distributions, modifications database) and crashes. A DLL rebuild can silently change data path resolution behaviour, making this variable mandatory regardless of whether prior phases needed it. (Phase 1 lesson #5.)
- Verifies bridge smoke tests passed (inline result check, `if: always()`).
- In Phase 3+: runs `dumpbin /exports` verification of `OpenMS.dll`.
- In Phase 3+: verifies `[TRACK-CREATE]` audit entries are present in shadow validation output. **This check now hard-fails** (`exit 1`) if no entries are found, ensuring shadow validation is active. (Updated per Phase 3 compliance report CI-1 fix, 2026-03-29. Previously was warning-only.)
- Runs regression suite (`regression-runner.ps1`): executes `Flash.exe <input_file> <output_file> <method.xml>` for each config, compares output to golden files via `compare_golden.py`.
- Runs stress tests (conditional step, activated in Phase 3): reduced iterations (1k ProcessScan calls, 50 FAIMS events) to stay within the 10-minute budget. Note: CT31/CT32 run inside NUnit (not as a separate CI step); the dedicated stress test CI step prints a stub message but the actual tests run within the NUnit step. (CI-3, Phase 3 compliance report, 2026-03-29.)
- Uploads regression output and NUnit results as artifacts.
- Note: ScanCommandLayout output is not captured as a separate CI artifact (CI-2 from Phase 3 compliance report — optional per spec, not implemented).

### Trigger Conditions

```yaml
on:
  push:
    branches: [main, develop, flashida-v9-migration, 'phase-*']
  pull_request:
    branches: [main, develop, flashida-v9-migration]
```

Every push to the migration branch or any `phase-*` feature branch triggers the full suite. All tests run on every commit; no subset runs are defined. The cumulative test count grows from 35 at Phase 0 (7 P0-* + 28 AL-CT) to 130 at Phase 8 (98 P*-* across all phases + 32 AL-CT).

---

## 4. Build Batching Strategy

C++ builds take 30–60 minutes. Phases are grouped to minimize the number of full rebuilds:

| Build | Phases | First phase with new C++ code | OpenMS submodule advances |
|-------|--------|-------------------------------|---------------------------|
| (none) | Phase 0 | — | No |
| Build #1 | Phases 1 + 2 + 3 | Phase 2 (OptimizationMetadata) | Yes |
| Build #2 | Phase 4 | Phase 4 (full ProcessScan routing) | Yes |
| (none) | Phase 5 | — | No (C#-only) |
| Build #3 | Phase 6 | Phase 6 (FAIMS state machine) | Yes |
| Build #4 | Phases 7 + 8 | Phase 7 (exploration engine) | Yes |

**Phase 0 and Phase 5 require no C++ build.** Phase 0 is test infrastructure only. Phase 5 is a C#-only refactor; it reuses the cached Build #2 DLLs unchanged.

**Before starting a build batch:** Verify that the prior batch's CI is green on `flashida-v9-migration` and that the OpenMS submodule has been updated to the new commit. Then manually trigger `build-openms-dll.yml` to produce the DLL artifact before pushing any FlashIDA C# changes for that batch.

---

## 5. Golden File Capture Workflow

This procedure applies to every phase that introduces a new golden file. The process is the same each time; only the file names and method configs differ.

**When it applies:** Phase 0 (`baseline_phase0.tsv`), Phase 1 (JSON golden files), Phase 4 (mode-specific golden files), Phase 6 (FAIMS golden files), Phase 7 (`method_exploration.xml` golden file).

**Standard procedure:**

1. **Commit test data, configs, and code — but not the golden file.** The CI `windows-tests` job always runs `Flash.exe <input_file> <output_file> <method.xml>` and uploads the output regardless of whether a golden file exists yet.

2. **Push.** CI runs on `windows-latest`. The `windows-tests` job produces a `golden-capture` artifact containing the raw TSV output(s). (The regression step may fail on this first push if comparing against a non-existent golden file — that is expected and acceptable.)

3. **Download the artifact** from the GitHub Actions UI (navigate to the workflow run → Artifacts → download `golden-capture`).

4. **Review the output.** Verify:
   - The file has a header row and at least one data row.
   - All expected columns are present.
   - For behavioral changes (e.g., Phase 4 mode switch-over): the output is in the expected direction — same for regression anchor, different for mode-specific variants.
   - The data is not synthetic and not empty.

5. **Commit.** Copy the reviewed file(s) to `FlashIDA/test-data/golden/<name>.tsv` and commit.

6. **Push again.** On this second push, `compare_golden.py` finds the committed golden file and the regression step passes.

> **CI budget note (Phase 0 lesson #15):** Golden-file capture requires a minimum of 2 commits (one to produce the artifact, one to commit it). Phases with multiple golden files should batch captures into a single CI run to minimize round-trips.

**What to document per golden file (in the PR description or in `golden/README.md`):**
- Source `.mzML` file name and scan number used to produce the input spectrum.
- Phase and test ID that first committed this file.
- Whether the golden file represents new behavior or a regression anchor.

---

## 6. Git Workflow

### Branch Naming

| Branch | Purpose |
|--------|---------|
| `flashida-v9-migration` | Main migration branch. All phase work merges here. PR target for each completed phase. |
| `phase-N` (e.g., `phase-3`) | Optional feature branch for a single phase or phase within a build batch. |
| `flashida-v9-bridge` | OpenMS submodule branch. C++ changes go here; `build-openms-dll.yml` targets this branch. |

### Developing Phases in a Build Batch

Phases within the same build batch (e.g., Phases 1 + 2 + 3 in Build #1) can be developed in parallel on separate `phase-N` branches. However:

- All branches in the batch must share the same OpenMS submodule commit — the one that will be built by `build-openms-dll.yml` for that batch.
- C++ changes from multiple phases must be combined into the submodule before triggering the build. Coordinate C++ commits on `flashida-v9-bridge` before opening individual PRs.
- The final merge into `flashida-v9-migration` should happen after all phases in the batch pass CI individually. Merge in phase order (Phase 1 → 2 → 3) to keep the history clean.

### Submodule Churn and CI Round-Trips (Phase 0 lesson #15)

- **Submodule pointer updates** accounted for ~48% of Phase 0 commits (13 of 27). Batch same-side changes (all C# changes together, or all C++ changes together) before updating the submodule pointer to reduce churn.
- **Thermo interface mocking** required 9 iterative commits in Phase 0 due to undocumented proprietary interfaces. Budget 2-3 extra CI round-trips per phase that touches Thermo interfaces.
- **Submodule pointer must be committed** when new C++ files are added. New files in the OpenMS submodule are invisible to CI until the FlashIDA repo's submodule pointer is updated and the updated pointer is committed. (Phase 1 lesson #1.)

### Merge Policy

- A phase is ready to merge when all its CI jobs are green: no test failures, regression comparison passes.
- Merges are squash-or-merge (team preference). Either is acceptable; consistency matters more than method.
- Golden file changes in a PR must be explained in the PR description (see Section 5).
- Never merge a phase whose golden file diffs are unexplained.

### Tagging

Tag after each build batch ships to `flashida-v9-migration` and CI is green:

| Tag | After | Notes |
|-----|-------|-------|
| `v9-build1` | Phases 1+2+3 merged and CI green | First C++ build complete |
| `v9-build2` | Phase 4 merged and CI green | Switch-over verified for all modes |
| `v9-build3` | Phase 6 merged and CI green | FAIMS absorbed, ScanScheduler deleted |
| `v9-build4` | Phases 7+8 merged and CI green | Final form — 5 bridge functions |

No tag for Phase 0 or Phase 5 (no C++ build, no external release needed).

---

## 7. Test Data Management

### Directory Layout

```
FlashIDA/test-data/
  spectra/          # Input spectra for Flash.exe test mode (committed)
  configs/          # Method XML configs for test runs (committed)
  golden/           # Reference output files for regression (committed)
    README.md       # Provenance, update procedure, review expectations
FlashIDA/test-scripts/
  compare_golden.py         # TSV comparison with numeric tolerance
  regression-runner.ps1     # Orchestrates Flash.exe + comparison
  prepare-test-data.py      # Extracts scans from .mzML files
```

All files in `spectra/`, `configs/`, and `golden/` are committed to the repository. The total size should remain below 50 MB; migrate to Git LFS if it exceeds that.

### Real Experimental Data Only

Spectrum files in `spectra/` must contain real measured isotope patterns from actual top-down acquisitions. Do not construct peaks synthetically. The developer provides real `.mzML` files; `prepare-test-data.py` extracts the required scans:

```bash
python prepare-test-data.py <source.mzML> FlashIDA/test-data/spectra/<output_name>.txt
```

The script takes a source `.mzML` file and an output path. Extracted scans are tab-delimited (m/z, intensity) pairs with a tab-separated header line (`Spec scan=N\t<rt_seconds>`), where RT is a bare numeric value in seconds. The developer specifies which scans to extract based on the data requirements documented in each phase plan.

### Spectrum File Requirements (per phase)

| Phase | File(s) | Requirements |
|-------|---------|--------------|
| 0 | `ms1_smoke_test.txt` | Minimum 2 scans from the main elution region (~6,588 + ~21 peaks). Must contain protein charge envelopes detectable by FLASHDeconv. A single-scan file or a scan with 10–200 peaks produces zero output. (Phase 0 lessons #6, #7.) |
| 4 | Mode-specific files (`ms1_deep.txt`, etc.) | One file per acquisition mode being tested |
| 6 | `ms1_faims_3cv.txt` | Real FAIMS acquisition; scans at ≥2 CV values; precursor count variation sufficient to trigger adaptive skip threshold |
| 7 | `ms1_exploration.txt` | High-quality precursors; scores high enough to trigger exploration |

Detailed requirements for each file are in the corresponding phase plan.

### Golden File Rules

- Golden files are created by the CI capture procedure (Section 5) — never hand-constructed.
- Golden files for phases claiming zero behavioral change (Phase 0, Phase 2, Phase 3) must match the prior-phase baseline exactly (`compare_golden.py` reports `PASS`).
- Golden files for behavioral phases (Phase 4, Phase 6, Phase 7) reflect the new behavior and must be reviewed before committing.
- `compare_golden.py` applies tolerance: absolute 1e-6 or relative 1e-4 for float columns; exact match for string and integer columns.

---

## 8. Per-Phase Environment Summary

| Phase | Build | `cpp-unit-tests` active | Stress step active | New golden files | Special environment notes |
|-------|-------|-------------------------|-------------------|------------------|---------------------------|
| 0 | None | No (`if: false`) | No (`if: false`) | `baseline_phase0.tsv` | First CI run; golden capture artifact needed before second push |
| 1 | Build #1 (batched) | No | No | `config_default.json`, `config_full.json` | Build #1 DLL must be available before `windows-tests` can run |
| 2 | Build #1 (batched) | Yes (first activation) | No | None | New test entry added to `executables.cmake`; apt deps include XercesC, liblzma; CMake flags: `-DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`; ccache key hashes `CMakeLists.txt` |
| 3 | Build #1 | Yes | Yes (first activation) | None | `dumpbin /exports` check added to `windows-tests`; `ScanCommandLayoutTest` cross-artifact from ubuntu to windows (not implemented; CI-2 — optional per spec) |
| 4 | Build #2 | Yes | Yes | 9 new mode-specific golden files (`phase4_*.tsv`); P4-R01 reuses `baseline_phase0.tsv` | Regression may approach 20-min budget; monitor and parallelize if needed |
| 5 | None (reuse Build #2) | Yes (no new C++ tests; existing tests run against Build #2 DLLs) | Yes | `faims_3cv.tsv`, `faims_skip.tsv` | P5-R02 captures FAIMS baselines while `ScanScheduler.cs` is still active; these become Phase 6 regression targets |
| 6 | Build #3 | Yes | Yes (FAIMS stress) | None (uses Phase 5 FAIMS baselines) | Stress test uses 50 scan events; mutex correctness required |
| 7 | Build #4 (batched) | Yes | Yes | Exploration golden file | Phase with most C++ tests (10); `method_exploration.xml` must be committed |
| 8 | Build #4 | Yes | Yes | None (reuses Phase 7 files) | Full regression (12+ configs); `dumpbin` must show exactly 5 exports; `/warnaserror` build |

**`cpp-unit-tests` activation:** Remove `if: false` from the job in `flashida-ci.yml` when Phase 2 begins. Once active, the job runs on every push for all subsequent phases. Phase 2 requires the full apt dependency list (see Section 1) and CMake flags `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja` for efficient test-only builds.

**Stress test step activation:** Remove `if: false` from the stress test step inside `windows-tests` when Phase 3 begins. Once active, it runs on every push for all subsequent phases.

---

## Phase 4 Addendum (2026-04-04)

*Corrections and clarifications discovered during Phase 4 implementation. The original spec text above is preserved as-is.*

### build-dlls workflow location

The `build-dlls` workflow lives in the **OpenMS submodule repo** (`OpenMS/.github/workflows/build_dlls.yml`), NOT in the FlashIDA repo. It auto-triggers on push to the `flashida-v9-bridge` branch.

### DLL artifact download

```bash
gh run download <run-id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts
```

The `-R` flag is required because the workflow runs in the OpenMS repo, not the FlashIDA parent repo.

### Workflow activation status (as of Phase 4)

| Workflow/Step | Status | Since |
|---------------|--------|-------|
| `cpp-unit-tests` | ACTIVE | Phase 2 |
| Stress tests | Run within NUnit (not a separate CI step) | Phase 3 |
| `build-dlls` (OpenMS repo) | ACTIVE | Phase 3 |

### Additional CI steps not in original spec

The following CI steps were added during implementation but not specified in the original environment doc:

- **Phase 4 golden capture**: Captures process-scan TSV golden files as CI artifacts
- **Phase 1 JSON golden capture**: Captures JSON config golden files
- **Test data directory verification**: Validates that all expected test data files exist before running tests
- **Continuity golden artifact uploads**: Uploads continuity JSON golden files for cross-platform comparison

### cpp-unit-tests targets

The C++ test job runs a hardcoded pattern filter:

```
ctest -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout"
```

New C++ test classes must be added to this pattern in `flashida-ci.yml` to be picked up by CI.

---

## Phase 5 Addendum (2026-04-05)

*Corrections and clarifications discovered during Phase 5 implementation. The original spec text above is preserved as-is.*

### No build required (confirmed)

Phase 5 is C#-only. No C++ code changes, no new bridge functions, no struct modifications. Build #2 DLLs reused unchanged.

### Workflow activation status (unchanged from Phase 4)

| Workflow/Step | Status | Since | Phase 5 changes |
|---------------|--------|-------|-----------------|
| `cpp-unit-tests` | ACTIVE | Phase 2 | No new C++ tests; existing tests run against Build #2 DLLs |
| Stress tests | Run within NUnit | Phase 3 | Still active, no changes |
| `build-dlls` (OpenMS repo) | ACTIVE | Phase 3 | Not triggered in Phase 5 |

### Per-Phase Environment Summary correction

The original table (line 286) listed Phase 5 golden files as `faims_3cv.tsv`, `faims_skip.tsv` captured via P5-R02. This is **incorrect**:

| Original spec | Actual |
|---------------|--------|
| `faims_3cv.tsv` via regression runner | NOT captured — Flash.exe ignores FAIMS CVs |
| `faims_skip.tsv` via regression runner | NOT captured — same reason |
| (not listed) | `continuity_faims_skip.json` captured via ContinuityTestHarness |

The corrected Phase 5 row for the Per-Phase Environment Summary table:

| Phase | Build | `cpp-unit-tests` active | Stress step active | New golden files | Special environment notes |
|-------|-------|-------------------------|-------------------|------------------|---------------------------|
| 5 | None (reuse Build #2) | Yes (no new C++ tests) | Yes | `continuity_faims_skip.json` | FAIMS regression configs should NOT be added to `regression-runner.ps1` — Flash.exe bypasses FAIMS pipeline entirely (see Lesson 1 in `Phase_5/lessons-learned.md`) |

### FAIMS regression runner rule

**Do not add FAIMS method configs** (`method_faims_3cv.xml`, `method_faims_skip.xml`) to `regression-runner.ps1`. `Flash.exe` test mode feeds scans directly to the C++ `ProcessScan` bridge in a single stream, ignoring the `cv=` field entirely. Both FAIMS configs produce output identical to non-FAIMS runs. FAIMS behavior is only testable through continuity tests (`ContinuityTestHarness`), which create a real `FAIMSScanProcessor` + `ScanScheduler` pipeline with mock instrument interfaces.

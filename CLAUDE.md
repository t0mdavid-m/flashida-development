# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This workspace contains two tightly coupled projects for real-time intelligent data acquisition in top-down proteomics:

- **FlashIDA/** — C# application that controls acquisition on Thermo Scientific tribrid instruments
- **OpenMS/** — C++ library fork (`FIdevelop` branch) providing the deconvolution engine that FlashIDA calls at runtime

Each sub-project has its own `CLAUDE.md` with detailed architecture and build instructions. Refer to those when working within a single project.

## How the Projects Connect

FlashIDA's `FLASHIdaWrapper.cs` calls into `OpenMS.dll` via P/Invoke (~20 exported C functions). The bridge functions are defined on the C++ side in `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` and consumed on the C# side in `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`. Changes to the bridge API must be synchronized across both projects.

## Build Commands

### FlashIDA (C# / .NET 4.8, Windows only)
```
msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```
Requires Thermo iAPI DLLs in `FlashIDA/dependencies/` (proprietary, not in repo) and OpenMS DLLs in `FlashIDA/dll/`.

### OpenMS (C++20 / CMake)
**Do NOT build unless explicitly asked** — extremely resource-intensive.
```bash
cmake -DCMAKE_PREFIX_PATH=<vcpkg-installed-path> <source-dir>
cmake --build <build-dir> --config Release
```

## Testing

### FlashIDA
C# NUnit tests in `src/Flash/Flash.Tests/`. Run via NUnit console runner in CI. Also has test mode for offline deconvolution:
```
Flash.exe <input_file> <output_file> <method.xml> [ms2_file]
```

### OpenMS
```bash
ctest                       # All tests
ctest -R ClassName_test     # Single class test
ctest -R FLASH              # All FLASH-related tests
```
Active FLASHIda test binaries in `executables.cmake`: `DeconvolvedSpectrum_OptimizationMetadata_test`, `FLASHIdaQueueTracking_test`, `FLASHIda_ProcessScan_test`, `ScanCommandLayout_test`, `FLASHIdaFAIMS_test`. Phase 7 adds `FLASHIda_exploration_test`.

## Key Development Concerns

- **Cross-project bridge changes**: When modifying the P/Invoke interface between FlashIDA and OpenMS, update both `FLASHIdaBridgeFunctions.cpp/.h` and `FLASHIdaWrapper.cs` in lockstep.
- **FLASH code location**: All FLASH algorithms live in `OpenMS/src/openms/{include,source}/OpenMS/ANALYSIS/TOPDOWN/`.
- **Method configuration**: Acquisition parameters are in XML format (`FlashIDA/src/Flash/etc/method.xml`).
- **Code style**: OpenMS uses clang-format (LLVM-based, 150 col, 2-space indent, Allman braces). FlashIDA follows standard C# conventions.

## Current State (Phase 7)

Phases 0-6 are complete. Phase 7 (Exploration Engine) is the current active phase.

**Pipeline status:** All acquisition paths route through `UnifiedScanProcessor` → C++ `processScan()` → `getNextScanCommand()`. `ScanScheduler.cs` and `FAIMSScanProcessor.cs` were deleted in Phase 6. FAIMS CV cycling is fully in C++.

**Phase 7 scope:** Per-MS-level selection/exploration framework. Two independent concerns per MSn level:
- **Selection** (required): How targets are ranked for MSn+1. Metrics: `intensity`, `qscore`, `none`.
- **Exploration** (optional, MS2+): CE sweep optimization. Metrics: `mass_count`, `remaining_precursor`, `fragment_count`.

Key files to modify:
- **C++ (OpenMS, `flashida-v9-bridge` branch):**
  - `FLASHIda.h` — enums (`SelectionMetric`, `ExplorationMetric`), `MSLevelConfig` struct, `ExplorationGroup`/`ExplorationVariant` structs, `level_configs_` map
  - `FLASHIda.cpp` — JSON config parsing (`parseLevelConfig_`), `initiateExploration_()`, `feedExplorationResult_()`, `initiateNextLevel_()`, scoring helpers
  - New: `FLASHIda_exploration_test.cpp` (13 tests: P7-U01–U12, P7-R01, P7-R02)
  - `executables.cmake` — register `FLASHIda_exploration_test`
- **C# (FlashIDA, `phase-7` branch):**
  - `Parameter.cs` — serialize `<SelectionStrategy>` XML to JSON `selection_strategy` object
  - `test-data/configs/method_exploration.xml` — new config file
  - All existing method XMLs — add `<SelectionStrategy>` blocks (crash if missing)
- **CI (parent repo, `phase-7` branch):**
  - `flashida-ci.yml` — add `FLASHIda_exploration_test` to build targets and CTest filter

**Build batching:** Phase 7 + Phase 8 are Build #4 (final C++ build). Batch all C++ changes before pushing to `flashida-v9-bridge` (~40 min DLL build).

**ScanCommand is 1248 bytes** with `faims_cv` at offset 1240 (Phase 6). Phase 7 does not modify the struct. If needed, the 6-file lockstep rule applies.

## Development Plan

Implementation is organized into 9 phases (Phase 0-8), each with its own detailed plan:

    plans/development/Phase_0/ through Phase_8/implementation-plan.md

These per-phase implementation plans are the **working documents**. All edits during implementation go here.

The following files in `plans/development/` are **read-only reference documents** — do NOT edit them:
- `baseline-plan.md` — Architecture design and issue specifications (v9)
- `testing-strategy.md` — Test tiers, CI infrastructure, per-phase test matrices
- `implementation-roadmap.md` — High-level phase overview, build batching, CI requirements
- `verification-report.md` — Cross-document consistency verification

**WARNING — Archived plans:** The `plans/` directory contains older iterations (`v2-parameter-optimization.md` through `v9-parameter-optimization.md`). These are SUPERSEDED and kept only for historical reference.

## Lessons Learned

Append reusable lessons here when discovered during implementation. Date-prefix each entry. These apply to this repo (FlashIDA + OpenMS cross-project work). For broader lessons, update `~/.claude/CLAUDE.md` instead.

- (2026-03-23) Flash.exe entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()`. No `-t` flag. Invocation: `Flash.exe <input> <output> <method.xml> [ms2_file]`.
- (2026-03-23) Spectrum TSV files use tab-separated headers with RT in seconds (`Spec scan=N\t<seconds>`), not the space-separated minutes format in test-file-specification.md.
- (2026-03-23) Binary files (`.enc`, `.zip`, `.dll`) need explicit `binary` attribute in `.gitattributes` — the repo's `* text eol=crlf` corrupts them silently.
- (2026-03-23) OpenMS DLLs are committed in `FlashIDA/dll/` and copied by MSBuild. No download step needed in CI.
- (2026-03-23) Flash.exe's parser only processes scan N when scan N+1's header is read. Single-scan files produce zero output. Test files need 2+ scans.
- (2026-03-23) When deconvolution returns 0 results unexpectedly, log input data characteristics (RT, peak count, m/z range) before investigating engine internals. The bridge doesn't distinguish "no results" from "malformed input."
- (2026-03-27) Submodule pointer must be updated in parent repo after every push to submodule branches, or CI won't see the new code.
- (2026-03-29) OpenMS ClassTest framework: use `NOT_TESTABLE` for deferred test stubs, not `ABORT_IF(true)` (which counts as failure).
- (2026-03-29) `build-dlls` workflow in OpenMS repo auto-triggers on push to `flashida-v9-bridge`. Download artifact: `gh run download <id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts`.
- (2026-03-29) When testing modes with sub-options (strict/non-strict inclusion, conditional/unconditional MS2), always test both variants with separate config files.
- (2026-03-31) MS2 scan descriptions live in `Trailer["Scan Description"]`, not `Header["Scan"]`. Header["Scan"] is the scan number. When the C++ engine gets a scan number instead of a tracking ID (e.g. "1" instead of "_0|2063.61@4"), it silently returns 0 follow-ups — no error, just empty results.
- (2026-03-31) Unified bridge uses 0-based tracking IDs (`_0`, `_1`...) and descriptive quant ScanDescriptions (`_N|mass@charge`), unlike the old bridge which used 1-based IDs and bare `"quant"`. All golden files must be re-captured when switching bridge paths.
- (2026-03-31) When re-capturing golden files after a bridge change, always diff old vs new before overwriting. Categorize changes (ID rebase, format change, structural) and verify non-changing fields are identical. Unexpected structural changes (e.g. MS3 mode1/2 gaining records) may be correct but need explicit verification.
- (2026-04-01) The C++ deconvolution engine (`SpectralDeconvolution`) needs multiple MS1 scans to accumulate state before producing results. A single scan (even with 520 peaks) returns 0 commands. Push all available scans (e.g. all 50 from `ms1_standard.txt`) to match the Windows continuity test behavior.
- (2026-04-01) CTest runs from the build directory (`OpenMS/build/`). Relative paths to FlashIDA test data are `../../FlashIDA/test-data/...`. Guard with `NOT_TESTABLE; break;` when files aren't found for local dev without the full workspace layout.
- (2026-04-02) When changing P/Invoke struct layout (e.g. ScanCommand), the full commit sequence is: (1) commit+push C++ changes to OpenMS, (2) wait for `build-dlls` workflow to succeed, (3) download artifact and update DLLs in `FlashIDA/dll/`, (4) commit C# changes + DLLs in FlashIDA, (5) then update parent submodule pointers. Skipping step 3 causes CI to fail with struct size mismatch.
- (2026-04-02) P/Invoke struct changes require updating **5 files** in lockstep, not just the obvious 3: (1) `FLASHIda.h` (C++ struct + static_assert), (2) `FLASHIda.cpp` (populate new fields), (3) `ScanCommandLayout_test.cpp` (C++ offsetof printer — easy to forget), (4) `FLASHIdaWrapper.cs` (C# struct), (5) `ScanCommandLayoutTests.cs` (C# size + offset assertions).
- (2026-04-02) In the old bridge's `getIsolationWindows`, `precursorIntensities` maps to `PeakGroup::getChargeIntensity(charge)` (per-charge), while `peakgroupIntensities` maps to `PeakGroup::getIntensity()` (total). The names are misleading — "precursor" means charge-specific, not the overall precursor.

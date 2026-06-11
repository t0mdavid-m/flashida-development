# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@docs/kb/index.md

## Repository Structure

This workspace is a parent repo with **two git submodules** — tightly coupled projects for real-time intelligent data acquisition in top-down proteomics:

- **FlashIDA/** (submodule `t0mdavid-m/FlashIDA`) — C# / .NET Framework 4.8 application that controls acquisition on Thermo Scientific tribrid instruments. Has its own `FlashIDA/CLAUDE.md` with detailed architecture.
- **OpenMS/** (submodule `t0mdavid-m/OpenMS`) — C++20 fork of OpenMS providing the FLASH deconvolution engine FlashIDA calls at runtime. No sub-project `CLAUDE.md` — its guidance lives in this file and in `docs/kb/`.

`.gitmodules` pins OpenMS's tracking branch to `FIdevelop`, but both submodules are currently checked out on **`august_pre`** (matching the parent). CI checks out with `submodules: recursive`. Because these are submodules, `git` from the parent root does **not** show their committed files (DLLs, sources) — run `git` from inside `FlashIDA/` or `OpenMS/` to inspect them.

## How the Projects Connect

FlashIDA's `FLASHIdaWrapper.cs` P/Invokes `OpenMS.dll`. The C bridge is **exactly 5** `extern "C"` exports, defined in `OpenMS/src/openms/{include,source}/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.{h,cpp}` and consumed via `[DllImport("OpenMS.dll")]` in `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`:

`CreateFLASHIda` · `DisposeFLASHIda` · `ProcessScan` (enqueue a spectrum) · `GetNextScanCommand` (drain the next instrument command by priority; returns `1` if one was filled, `0` if the queue is empty) · `GetNextTrackingId`. There are **no** separate MS2/MS3/exclusion-list exports — everything flows through `ProcessScan` (enqueue) + `GetNextScanCommand` (drain).

**The load-bearing ABI contract is the `ScanCommand` struct: exactly 2048 bytes, embedding `IsolationStage stages[10]` at 80 bytes each.** C++ defines it in `.../TOPDOWN/FLASHIda/ScanCommand.h` (guarded by `static_assert(sizeof(ScanCommand)==2048)`); C# mirrors it at the top of `FLASHIdaWrapper.cs` (`[StructLayout(Sequential, Pack=8, CharSet=Ansi)]` with a trailing `Reserved` byte block). **When adding a bridge field, carve bytes from `Reserved` — never change the 2048-byte total — and update both sides in lockstep.** Drift is caught by `ScanCommandLayout_test` (C++) and `ScanCommandLayoutTests` (C#), both run in CI.

## Build

**Build in CI, not locally** (`.github/workflows/flashida-ci.yml`); local builds are for rare manual verification. Build sparsely; at a minimum push once at the **end** of a run so the work lands verified. CI runs on push to `main`, `develop`, `flashida-v9-migration`, `phase-*`, `august_pre`.

### FlashIDA (C# / .NET Framework 4.8, C# 7.3, x64, Windows only)
```
nuget restore FlashIDA/src/Flash.sln
msbuild       FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /m
```
Solution is at `FlashIDA/src/Flash.sln`. Projects: `Flash` → `Flash.exe`, `Flash.Tests` → `Flash.Tests.dll`; both output to `FlashIDA/bin/`. `PlatformTarget` is x64 despite the `Any CPU` switch.

DLL dependencies:
- **OpenMS runtime DLLs** are committed in the FlashIDA submodule at `FlashIDA/dll/` (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`, `zlib.dll`) and copied to `bin/` by MSBuild (`CopyToOutputDirectory`). There is **no** OpenMS-artifact download step — CI does not hand off a freshly built `OpenMS.dll`; to update it, rebuild OpenMS and commit the DLL into `FlashIDA/dll/`.
- **Thermo iAPI DLLs** are proprietary and **not** committed: `FlashIDA/dependencies/` holds only XML doc stubs plus `thermo-dlls.zip.enc` (openssl AES-256). CI decrypts it with secret `THERMO_DLL_PASSPHRASE` and copies the DLLs into `bin/`. Local builds need the real DLLs placed in `dependencies/` (see `FlashIDA/Installation.md`).

### OpenMS (C++20 / CMake) — **Do NOT build unless explicitly asked** (resource-intensive; CI handles it)
Matches CI (Debug, Ninja, no GUI/pyOpenMS, system apt deps — **not** vcpkg). CI compiles ~13 named FLASH test binaries, not the whole library:
```bash
cmake -S OpenMS -B OpenMS/build -DCMAKE_BUILD_TYPE=Debug -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja
cmake --build OpenMS/build --target FLASHIdaFAIMS_test ScanCommandLayout_test FragmentAnalysis_test  # etc.
```

## Testing

Set `OPENMS_DATA_PATH=<repo>/OpenMS/share/OpenMS` for the NUnit, regression, and ctest runs.

### FlashIDA (C# NUnit — tests in `FlashIDA/src/Flash.Tests/`)
Console runner is restored via NuGet (`NUnit.ConsoleRunner 3.16.3`).
```
# all tests (CI additionally excludes two flaky MS3 continuity tests via --where)
FlashIDA\src\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe FlashIDA\bin\Flash.Tests.dll
# a single test
... nunit3-console.exe FlashIDA\bin\Flash.Tests.dll --where "test=='Flash.Tests.BridgeSmokeTests.<Method>'"
```
Other CI-driven suites:
- **Offline / test-mode deconvolution** — `Flash.exe <input_spectrum> <output.tsv> <method.json> [ms2_spectrum]` (positional, exact order; runs `FLASHIdaWrapper.Main`). The `-t/--test` CLI flag routes into the same path.
- **Regression + golden** — `powershell FlashIDA\test-scripts\regression-runner.ps1 -FlashExe FlashIDA\bin\Flash.exe -TestDataDir FlashIDA\test-data -OutputDir FlashIDA\test-output [-captureMode]`. Iterates ~15 mode configs and diffs TSV output against `FlashIDA/test-data/golden/*.tsv` via `python FlashIDA/test-scripts/compare_golden.py` (`-captureMode` regenerates goldens; needs Python on PATH).

### OpenMS (C++ ctest) — active FLASH targets are in `OpenMS/src/tests/class_tests/openms/executables.cmake`
```bash
# the FLASH suite as CI runs it (no -E; the -R alternation lists every target that runs)
ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration|FLASHIda_LegacyConfig|FLASHIda_Logging|ScanCommandQueue_Concurrent|FragmentAnalysis|MS3FragmentMatcher|FLASHIda_ChargeBasedExclusion|ScanConfig_applyOverrides" --output-on-failure
# a single test
ctest --test-dir OpenMS/build -R FLASHIdaFAIMS --output-on-failure
```
**A C++ test runs in CI only if it is added in BOTH places**: the build `--target` list in `.github/workflows/flashida-ci.yml` AND the `ctest -R` alternation. Registering it in `executables.cmake` alone is *not* enough — it will compile but never execute (or not even build). `ctest -R FLASH` alone is **insufficient** — it misses `FragmentAnalysis_*`, `ScanCommandLayout_test`, `ScanCommandQueue_Concurrent_test`, `MS3FragmentMatcher_*`, `ScanConfig_applyOverrides_test`, and `DeconvolvedSpectrum_OptimizationMetadata_test` (names that don't start with `FLASH`). The previously-documented `-E "FLASHIda_ProcessScan|FLASHIda_exploration|FLASHIda_Logging"` exclusion no longer exists — those three run.

## Key Development Concerns

- **Cross-project bridge changes** — keep the 5 exports and the 2048-byte `ScanCommand` struct in sync across `FLASHIdaBridgeFunctions.{h,cpp}` and `FLASHIdaWrapper.cs` (see *How the Projects Connect*), and run the layout tests on both sides.
- **FLASH code location** — `OpenMS/src/openms/{include,source}/OpenMS/ANALYSIS/TOPDOWN/`. `FLASHIda.cpp` (real-time IDA driver; its `processScan` runs deconvolution + precursor selection) and `FLASHIdaBridgeFunctions.cpp` sit directly under `TOPDOWN/`; most runtime helpers (`Config`, `Exploration`, `FAIMS`, `FragmentAnalysis`, `MS3FragmentMatcher`, `PrecursorSelection`, `Quantification`, `ScanCommand`, `ScanCommandQueue`) live in the nested `TOPDOWN/FLASHIda/` subdirectory.
- **Scan processing is unified** — `UnifiedScanProcessor` is the *sole* production `IScanProcessor` (single `void ProcessMS(IMsScan)`); all MS levels route through `FLASHIdaWrapper.ProcessScan` → C++ `processScan`, and commands are drained separately via `GetNextScanCommand` in `Flash.cs`. (`ScanScheduler.cs`, `FAIMSScanProcessor.cs`, `IDAScanProcessor.cs`, and `QuantScanProcessor.cs` do **not** exist.)
- **Method configuration is JSON** — `FlashIDA/src/Flash/etc/method.json` (**not** XML). Top-level sections map to `[JsonKey]` classes in `MethodConfig.cs` (`global`, `deconvolution`, `precursor_selection`, `tagging`, `quantification`, `faims`, `ms_settings`, `scheduling`, `selection_strategy`, `ms3`, `files`, `runtime`), plus a synthetic `developer` section into which `[Developer]`-marked fields are routed. Loading is reflection-driven (`MethodConfigSerializer.cs`); FlashIDA then re-serializes to a *different* C++-facing schema via `MethodParameters.ToCppJson()` before crossing the bridge. See `docs/kb/config-flow/`.
- **Acquisition modes** — `precursor_selection.targeting_mode`: `none` (standard DDA), `inclusion`, `exclusion`, `deep` (mapped to ints 0–3 for C++). Orthogonal, config-flag-driven feature modes (all through the unified pipeline, not separate processors): MS2 sequence tagging, conditional MS2, isobaric quantification, targeted MS3 characterization. See `docs/kb/`.
- **Code style** — OpenMS uses clang-format (LLVM-based, 150 col, 2-space indent, Allman braces; `OpenMS/.clang-format`). FlashIDA follows standard C# conventions.

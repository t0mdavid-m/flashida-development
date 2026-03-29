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
No automated test suite. Use test mode for offline deconvolution without an instrument:
```
Flash.exe <input_file> <output_file> <method.xml> [ms2_file]
```

### OpenMS
```bash
ctest                       # All tests
ctest -R ClassName_test     # Single class test
ctest -R FLASH              # All FLASH-related tests
```
Note: FLASH test entries are currently commented out in `OpenMS/src/tests/class_tests/openms/executables.cmake`.

## Key Development Concerns

- **Cross-project bridge changes**: When modifying the P/Invoke interface between FlashIDA and OpenMS, update both `FLASHIdaBridgeFunctions.cpp/.h` and `FLASHIdaWrapper.cs` in lockstep.
- **FLASH code location**: All FLASH algorithms live in `OpenMS/src/openms/{include,source}/OpenMS/ANALYSIS/TOPDOWN/`.
- **Method configuration**: Acquisition parameters are in XML format (`FlashIDA/src/Flash/etc/method.xml`).
- **Code style**: OpenMS uses clang-format (LLVM-based, 150 col, 2-space indent, Allman braces). FlashIDA follows standard C# conventions.

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

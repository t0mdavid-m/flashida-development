# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@docs/kb/index.md

## Repository Structure

This workspace contains two tightly coupled projects for real-time intelligent data acquisition in top-down proteomics:

- **FlashIDA/** — C# application that controls acquisition on Thermo Scientific tribrid instruments
- **OpenMS/** — C++ library fork (`FIdevelop` branch) providing the deconvolution engine that FlashIDA calls at runtime

Each sub-project has its own `CLAUDE.md` with detailed architecture and build instructions. Refer to those when working within a single project.

## How the Projects Connect

FlashIDA's `FLASHIdaWrapper.cs` calls into `OpenMS.dll` via P/Invoke. The bridge functions are defined on the C++ side in `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` and consumed on the C# side in `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`. Changes to the bridge API must be synchronized across both projects.

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
Active FLASHIda test binaries are listed in `OpenMS/src/tests/class_tests/openms/executables.cmake`. Run a single one via `ctest -R <test_name>`.

## Key Development Concerns

- **Cross-project bridge changes**: When modifying the P/Invoke interface between FlashIDA and OpenMS, update both `FLASHIdaBridgeFunctions.cpp/.h` and `FLASHIdaWrapper.cs` in lockstep.
- **FLASH code location**: All FLASH algorithms live in `OpenMS/src/openms/{include,source}/OpenMS/ANALYSIS/TOPDOWN/`.
- **Method configuration**: Acquisition parameters are in XML format (`FlashIDA/src/Flash/etc/method.xml`).
- **Code style**: OpenMS uses clang-format (LLVM-based, 150 col, 2-space indent, Allman braces). FlashIDA follows standard C# conventions.

# Phase 0: Establish Baseline — Implementation Plan

**Date:** 2026-03-21
**Phase:** 0 of 8
**Build:** None (no C++ build required)
**Source documents:**
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 0 section and CI Environment Requirements
- [../baseline-plan.md](../baseline-plan.md) — architecture context and design invariants
- [../testing-strategy.md](../testing-strategy.md) — Phase 0 test plan, initial setup, and CI infrastructure

---

## Goal

Capture the current behavior of the unmodified codebase before any migration changes. Create the NUnit test project, minimal test data, and CI workflow skeleton. Phase 0 produces no behavioral changes to the application — its sole purpose is to establish the safety net that all subsequent phases rely on.

At the end of Phase 0, the following must exist and be committed:
- A working NUnit test project (`Flash.Tests.csproj`) that builds alongside `Flash.sln`.
- A minimal spectrum file (`ms1_smoke_test.txt`) that `Flash.exe -t` accepts without error.
- A captured golden file (`baseline_phase0.tsv`) recording the current deconvolution output.
- A CI workflow (`flashida-ci.yml`) with skeleton jobs that pass on the current codebase.

---

## Prerequisites

Phase 0 is the starting point. There are no phase-level code prerequisites. However, the following environmental prerequisites must be satisfied before development begins:

1. **Repository cloned with submodules.** The OpenMS engine is a Git submodule. Clone with:
   ```bash
   git clone --recursive https://github.com/kohlbacherlab/FLASHIda.git
   ```
   Or if already cloned: `git submodule update --init --recursive`

2. **Thermo iAPI DLLs available locally.** The five assemblies (`API-2.0.dll`, `Fusion.API-1.0.dll`, `Spectrum-1.0.dll`, `Thermo.TNG.Factory.dll`, `Thermo.TNG.Client.API.dll`) must be present in `FlashIDA/dependencies/`. MSBuild cannot compile `Flash.sln` without them. See [../testing-strategy.md Section 3.3](../testing-strategy.md#33-handling-proprietary-dlls) for procurement instructions.

3. **OpenMS DLLs available locally.** Pre-built `OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll` must be in `FlashIDA/dll/`. Download from the latest `build-openms-dll.yml` CI artifact, or build locally (30-60 min). See [../testing-strategy.md Section 0.5](../testing-strategy.md#05-openms-dll-procurement).

4. **CI environment.** The CI environment (`windows-latest` GitHub Actions runner) provides MSBuild, NuGet, .NET 4.8, and Python. No local Windows machine is required.

5. **Existing solution builds cleanly.** Before creating any new files, verify the baseline:
   ```powershell
   msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
   ```
   This must exit with code 0. Resolve any pre-existing build errors before proceeding.

6. **GitHub repository secrets configured** (for CI). One of the two strategies from [../testing-strategy.md Section 3.3](../testing-strategy.md#33-handling-proprietary-dlls) must be set up:
   - Strategy A: `THERMO_IAPI_DLLS_BASE64` secret (preferred for DLLs < GitHub secret size limit)
   - Strategy B: Encrypted 7z archive committed to repo + `THERMO_DLL_PASSPHRASE` secret

---

## Detailed Implementation Steps

### Step 1 — Verify Existing Build

Before creating any files, confirm the current solution builds and runs.

1.1. Run MSBuild on the existing solution:
```powershell
msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```
Expected: exit code 0, `Flash.exe` present at `FlashIDA/src/Flash/bin/Debug/Flash.exe`.

1.2. Copy OpenMS DLLs to the build output directory so `Flash.exe` can load them at runtime:
```powershell
Copy-Item FlashIDA\dll\*.dll FlashIDA\src\Flash\bin\Debug\
```

1.3. Verify `Flash.exe` exists:
```powershell
Test-Path FlashIDA\src\Flash\bin\Debug\Flash.exe
```

If either step fails, do not proceed until the issue is resolved. Record any pre-existing build warnings — they are part of the baseline.

---

### Step 2 — Create the NUnit Test Project

Create the NUnit test project that will hold all Phase 0 tests and be extended throughout the migration.

2.1. Create the test project directory:
```
FlashIDA/src/Flash.Tests/
```

2.2. Create `FlashIDA/src/Flash.Tests/Flash.Tests.csproj` with the following content:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.CSharp.targets" />
  <PropertyGroup>
    <Configuration Condition=" '$(Configuration)' == '' ">Debug</Configuration>
    <Platform Condition=" '$(Platform)' == '' ">AnyCPU</Platform>
    <ProjectGuid>{REPLACE-WITH-NEW-GUID}</ProjectGuid>
    <OutputType>Library</OutputType>
    <AppDesignerFolder>Properties</AppDesignerFolder>
    <RootNamespace>Flash.Tests</RootNamespace>
    <AssemblyName>Flash.Tests</AssemblyName>
    <TargetFrameworkVersion>v4.8</TargetFrameworkVersion>
    <FileAlignment>512</FileAlignment>
    <AutoGenerateBindingRedirects>true</AutoGenerateBindingRedirects>
    <NuGetPackageImportStamp />
  </PropertyGroup>
  <PropertyGroup Condition=" '$(Configuration)|$(Platform)' == 'Debug|AnyCPU' ">
    <DebugSymbols>true</DebugSymbols>
    <DebugType>full</DebugType>
    <Optimize>false</Optimize>
    <OutputPath>bin\Debug\</OutputPath>
    <DefineConstants>DEBUG;TRACE</DefineConstants>
    <ErrorReport>prompt</ErrorReport>
    <WarningLevel>4</WarningLevel>
  </PropertyGroup>
  <PropertyGroup Condition=" '$(Configuration)|$(Platform)' == 'Release|AnyCPU' ">
    <DebugType>pdbonly</DebugType>
    <Optimize>true</Optimize>
    <OutputPath>bin\Release\</OutputPath>
    <DefineConstants>TRACE</DefineConstants>
    <ErrorReport>prompt</ErrorReport>
    <WarningLevel>4</WarningLevel>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="System" />
    <Reference Include="System.Core" />
    <Reference Include="nunit.framework">
      <HintPath>..\..\..\packages\NUnit.3.13.3\lib\net45\nunit.framework.dll</HintPath>
    </Reference>
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\Flash\Flash.csproj">
      <Project>{REPLACE-WITH-FLASH-PROJECT-GUID}</Project>
      <Name>Flash</Name>
    </ProjectReference>
  </ItemGroup>
  <ItemGroup>
    <Compile Include="SmokeTests.cs" />
    <Compile Include="BridgeSmokeTests.cs" />
  </ItemGroup>
  <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
  <Import Project="..\..\..\packages\NUnit3TestAdapter.4.3.1\build\net35\NUnit3TestAdapter.targets"
          Condition="Exists('..\..\..\packages\NUnit3TestAdapter.4.3.1\build\net35\NUnit3TestAdapter.targets')" />
</Project>
```

Notes on this file:
- Replace `{REPLACE-WITH-NEW-GUID}` with a freshly generated GUID (use `[System.Guid]::NewGuid()` in PowerShell).
- Replace `{REPLACE-WITH-FLASH-PROJECT-GUID}` with the GUID from `Flash.csproj` (search for `<ProjectGuid>` in that file).
- The NuGet package versions (`NUnit.3.13.3`, `NUnit3TestAdapter.4.3.1`) should match what is restored by the solution; adjust if the repo uses different versions.

2.3. Create `FlashIDA/src/Flash.Tests/packages.config`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="NUnit" version="3.13.3" targetFramework="net48" />
  <package id="NUnit3TestAdapter" version="4.3.1" targetFramework="net48" />
  <package id="NUnitConsoleRunner" version="3.16.3" targetFramework="net48" />
</packages>
```

2.4. Add the new test project to `FlashIDA/src/Flash.sln`. Open the solution file in a text editor and add a `Project(...)` entry for `Flash.Tests.csproj` alongside the existing projects. Follow the exact formatting of other project entries in the `.sln` file. The test project must appear in the `Debug|Any CPU` and `Release|Any CPU` solution configurations.

Alternatively, use Visual Studio or `dotnet sln add` to add the project to the solution, then verify the `.sln` format is correct.

---

### Step 3 — Create the Smoke Test Files

Create the two test source files that implement the Phase 0 tests (P0-U01 through P0-U04 and P0-I01, P0-I02).

3.1. Create `FlashIDA/src/Flash.Tests/SmokeTests.cs`:

```csharp
using System;
using System.Diagnostics;
using System.IO;
using NUnit.Framework;

namespace Flash.Tests
{
    /// <summary>
    /// Phase 0 smoke tests: verify that the solution builds and that Flash.exe -t
    /// runs without error. These tests establish the pre-migration baseline.
    /// </summary>
    [TestFixture]
    public class SmokeTests
    {
        private static readonly string BuildOutputDir =
            Path.GetFullPath(Path.Combine(
                TestContext.CurrentContext.TestDirectory, ".."));

        private static readonly string FlashExePath =
            Path.Combine(BuildOutputDir, "Flash.exe");

        private static readonly string TestDataDir =
            Path.GetFullPath(Path.Combine(
                TestContext.CurrentContext.TestDirectory,
                @"..\..\..\..\test-data"));

        private static readonly string SmokeSpectrumPath =
            Path.Combine(TestDataDir, @"spectra\ms1_smoke_test.txt");

        private static readonly string DefaultMethodPath =
            Path.Combine(TestDataDir, @"configs\method_default.xml");

        // P0-U01: Flash.sln compiles without error.
        // This test is validated by the fact that this assembly was compiled.
        // If the build failed, this test would not exist in the runner.
        [Test]
        [Category("Tier1")]
        public void P0_U01_SolutionCompilesWithoutError()
        {
            // If we reach this test, the assembly compiled.
            Assert.Pass("Assembly compiled successfully — build is clean.");
        }

        // P0-U02: Flash.exe exists in the build output directory.
        [Test]
        [Category("Tier1")]
        public void P0_U02_FlashExeExistsInBuildOutput()
        {
            Assert.IsTrue(
                File.Exists(FlashExePath),
                $"Flash.exe not found at: {FlashExePath}");
        }

        // P0-U03: Flash.exe -t runs with the minimal smoke spectrum and exits cleanly.
        [Test]
        [Category("Tier3")]
        public void P0_U03_TestModeRunsAndExitsCleanly()
        {
            string outputPath = Path.Combine(
                Path.GetTempPath(), "p0_u03_output.tsv");

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = FlashExePath,
                    Arguments = $"-t \"{SmokeSpectrumPath}\" \"{outputPath}\" \"{DefaultMethodPath}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using (var process = Process.Start(psi))
                {
                    process.WaitForExit(timeoutMilliseconds: 60_000);
                    Assert.AreEqual(0, process.ExitCode,
                        $"Flash.exe exited with code {process.ExitCode}.\n" +
                        $"STDOUT: {process.StandardOutput.ReadToEnd()}\n" +
                        $"STDERR: {process.StandardError.ReadToEnd()}");
                }
            }
            finally
            {
                if (File.Exists(outputPath))
                    File.Delete(outputPath);
            }
        }

        // P0-U04: Flash.exe -t output is a non-empty valid TSV with expected columns.
        [Test]
        [Category("Tier3")]
        public void P0_U04_TestModeOutputIsNonEmptyValidTsv()
        {
            string outputPath = Path.Combine(
                Path.GetTempPath(), "p0_u04_output.tsv");

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = FlashExePath,
                    Arguments = $"-t \"{SmokeSpectrumPath}\" \"{outputPath}\" \"{DefaultMethodPath}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using (var process = Process.Start(psi))
                {
                    process.WaitForExit(timeoutMilliseconds: 60_000);
                }

                Assert.IsTrue(File.Exists(outputPath),
                    "Output file was not created.");

                string[] lines = File.ReadAllLines(outputPath);
                Assert.GreaterOrEqual(lines.Length, 2,
                    "Output must have at least a header row and one data row.");

                // Verify expected TSV columns are present in the header.
                string[] expectedColumns = {
                    "rt", "mz1", "mz2", "qScore", "charges", "monoMasses",
                    "ccos", "csnr", "cos", "snr", "cScore", "ppm",
                    "precursorIntensity", "massIntensity", "hcd"
                };
                string header = lines[0];
                foreach (string col in expectedColumns)
                {
                    Assert.IsTrue(header.Contains(col),
                        $"Expected column '{col}' not found in TSV header: {header}");
                }
            }
            finally
            {
                if (File.Exists(outputPath))
                    File.Delete(outputPath);
            }
        }
    }
}
```

3.2. Create `FlashIDA/src/Flash.Tests/BridgeSmokeTests.cs`:

```csharp
using System;
using System.IO;
using System.Runtime.InteropServices;
using NUnit.Framework;

namespace Flash.Tests
{
    /// <summary>
    /// Phase 0 bridge smoke tests: verify that CreateFLASHIda and DisposeFLASHIda
    /// do not crash. No assertion about return values beyond non-null.
    /// </summary>
    [TestFixture]
    public class BridgeSmokeTests
    {
        // The DLL name must match the value used in FLASHIdaWrapper.cs.
        private const string DllName = "OpenMS";

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr CreateFLASHIda(string config);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
        private static extern void DisposeFLASHIda(IntPtr ptr);

        private static readonly string TestDataDir =
            Path.GetFullPath(Path.Combine(
                TestContext.CurrentContext.TestDirectory,
                @"..\..\..\..\test-data"));

        private static readonly string DefaultMethodPath =
            Path.Combine(TestDataDir, @"configs\method_default.xml");

        // P0-I01: CreateFLASHIda() returns a non-null pointer and does not crash.
        [Test]
        [Category("Tier2")]
        public void P0_I01_CreateFLASHIda_DoesNotCrash()
        {
            // Use the legacy config format that the current codebase expects.
            // Phase 0 tests the current behavior — no JSON yet.
            string legacyConfig = BuildLegacyConfigString();

            IntPtr ptr = IntPtr.Zero;
            Assert.DoesNotThrow(() =>
            {
                ptr = CreateFLASHIda(legacyConfig);
            }, "CreateFLASHIda threw an exception.");

            Assert.AreNotEqual(IntPtr.Zero, ptr,
                "CreateFLASHIda returned a null pointer.");

            // Clean up to avoid memory leak in the test process.
            if (ptr != IntPtr.Zero)
                DisposeFLASHIda(ptr);
        }

        // P0-I02: DisposeFLASHIda() completes without exception after CreateFLASHIda().
        [Test]
        [Category("Tier2")]
        public void P0_I02_DisposeFLASHIda_DoesNotCrash()
        {
            string legacyConfig = BuildLegacyConfigString();
            IntPtr ptr = CreateFLASHIda(legacyConfig);

            Assume.That(ptr, Is.Not.EqualTo(IntPtr.Zero),
                "Skipping dispose test: CreateFLASHIda returned null.");

            Assert.DoesNotThrow(() =>
            {
                DisposeFLASHIda(ptr);
            }, "DisposeFLASHIda threw an exception.");
        }

        /// <summary>
        /// Builds the legacy space-delimited config string that CreateFLASHIda
        /// currently expects. This mirrors what FLASHIdaWrapper.cs currently
        /// passes to the bridge. Adjust this method to match the actual
        /// Parameter.ToFLASHDeconvInput() output from the existing codebase.
        /// </summary>
        private static string BuildLegacyConfigString()
        {
            // Read the current format from the existing FLASHIdaWrapper.cs
            // and replicate it here. This is a placeholder — replace with
            // the actual default parameter string once the existing code is inspected.
            //
            // Example format (adjust to match actual FLASHIdaWrapper output):
            // "-1 1 100 10 10 5 5.0 300 2000"
            //
            // The test must use valid parameters so that CreateFLASHIda
            // initializes without error.
            return "-1 1 100 10 10 5 5.0 300 2000";
        }
    }
}
```

**Important note on `BridgeSmokeTests.cs`:** The `BuildLegacyConfigString()` method must be adjusted to match the actual parameter string that `FLASHIdaWrapper.cs` currently passes to `CreateFLASHIda`. Before writing the final test, inspect `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` and `FlashIDA/src/Flash/IDA/Parameter.cs` to find the `ToFLASHDeconvInput()` method and replicate its default output. This is addressed in Step 5 (inspection step) below.

---

### Step 4 — Create Test Data

Create the minimal spectrum file and method configuration needed for Phase 0 tests.

4.1. Create the test data directory structure:
```
FlashIDA/test-data/
  spectra/
  configs/
  golden/
```

4.2. Create `FlashIDA/test-data/spectra/ms1_smoke_test.txt`.

This file must contain a real MS1 scan extracted from an existing top-down `.mzML` file using `prepare-test-data.py` (see [../testing-strategy.md Section 8.6](../testing-strategy.md#86-data-preparation-script)). Do NOT construct peaks synthetically.

**Requirements for the extracted scan:**
- Format: one header line (`Spec scan=N rt=R.RRRR`) followed by tab-delimited (m/z, intensity) pairs, one per line.
- Must contain at least one charge envelope resolvable by FLASHDeconv (i.e., real measured isotope patterns from a top-down experiment).
- 10–200 peaks (small enough for a fast smoke test).
- Must produce at least 1 row of output when run through `Flash.exe -t`.

**Note:** `ms1_smoke_test.txt` must be committed with real data **before** the CI golden capture step (Step 6) can produce a valid baseline. See Step 6 for the ordering of commits.

Acceptance criterion: `Flash.exe -t ms1_smoke_test.txt output.tsv method_default.xml` must produce at least one row in `output.tsv`.

4.3. Inspect the existing `FlashIDA/src/Flash/etc/method.xml` file to understand the current method configuration format. Then create `FlashIDA/test-data/configs/method_default.xml` as a copy of the existing `method.xml` with standard DDA settings (the simplest operating mode, no FAIMS, no exploration, no inclusion/exclusion lists). This file will be used for all Phase 0 tests and as the regression anchor.

If `method.xml` already contains the correct defaults for standard DDA, simply copy it to the test data directory:
```powershell
Copy-Item FlashIDA/src/Flash/etc/method.xml FlashIDA/test-data/configs/method_default.xml
```

4.4. Create `FlashIDA/test-data/golden/README.md` documenting golden file provenance, the update procedure, and review expectations. Content:

```markdown
# Golden Files

This directory contains reference output files for regression testing.
Each file captures the output of `Flash.exe -t` for a specific
(spectrum file, method config) combination.

## Provenance

Each golden file is generated from real experimental data (top-down
proteomics `.mzML` files). The source `.mzML` file and the scan number
used to produce the input spectrum should be documented alongside each
golden file entry. Golden files are created by capturing CI output
(see "How to Update" below) and must not be constructed synthetically.

## How to Update

When an intentional behavioral change is made (e.g., a scoring change
in Phase 4), update golden files as follows:

1. Trigger CI on the branch containing the code change.
2. When the `csharp-tests` job completes, download the `regression-output`
   artifact from the Actions UI.
3. Inspect the diffs between the artifact output and the current golden files.
4. If the diffs are expected, copy the updated files to `test-data/golden/`
   and commit them.
5. In the PR description, list each changed golden file and explain
   why the output changed.

## Review Expectations

PR reviewers must verify:
- Golden file changes are accompanied by a code change that explains them.
- The diff is in the expected direction (e.g., different scores if
  scoring logic changed, same scores if only refactoring occurred).
- No golden file changes occur in phases that claim zero behavioral change
  (e.g., Phase 0, Phase 2, Phase 3).
```

---

### Step 5 — Inspect Existing Code (Required Before Bridge Tests)

Before finalizing the bridge smoke tests, read the existing source files to understand the current API.

5.1. Read `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` to:
- Find the `DllImport` attribute on `CreateFLASHIda` — confirm the DLL name (likely `"OpenMS"` without extension).
- Find where `CreateFLASHIda` is called — identify what string argument is passed (either inline or via `Parameter.ToFLASHDeconvInput()`).

5.2. Read `FlashIDA/src/Flash/IDA/Parameter.cs` to:
- Find `ToFLASHDeconvInput()` — this is the method that generates the config string.
- Record the default parameter values and their ordering so `BridgeSmokeTests.cs` can replicate them.

5.3. Update `BridgeSmokeTests.cs` `BuildLegacyConfigString()` with the actual format found. The test must pass valid parameters that `CreateFLASHIda` accepts without error.

5.4. Read `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` to find the exact path logic for `Flash.exe -t` test mode — confirm what command-line arguments the test mode accepts. Update `SmokeTests.cs` `P0_U03_*` and `P0_U04_*` if the argument format differs from the assumed `-t <ms1_file> <output_file> <method.xml>`.

---

### Step 6 — Capture the Golden Baseline via CI

The golden baseline is captured through CI, not by running `Flash.exe` locally. Follow this ordering carefully — `ms1_smoke_test.txt` must contain real data before this step can produce a valid baseline.

6.1. Commit and push the following to the branch, **without** `baseline_phase0.tsv`:
- `FlashIDA/test-data/spectra/ms1_smoke_test.txt` (real MS1 scan from Step 4.2)
- `FlashIDA/test-data/configs/method_default.xml`
- `FlashIDA/src/Flash.Tests/` (test project files from Steps 2–3)
- `FlashIDA/test-scripts/compare_golden.py` and `regression-runner.ps1`
- `.github/workflows/flashida-ci.yml`

6.2. The pushed commit triggers CI. The `csharp-tests` job builds the solution, runs `Flash.exe -t`, and uploads the output as a `golden-capture` artifact.

6.3. In the GitHub Actions UI, navigate to the completed `csharp-tests` run and download the `golden-capture` artifact. Inspect the TSV output:
- The file must contain a header row and at least one data row.
- All expected columns must be present (`rt`, `mz1`, `mz2`, `qScore`, `charges`, `monoMasses`, `ccos`, `csnr`, `cos`, `snr`, `cScore`, `ppm`, `precursorIntensity`, `massIntensity`, `hcd`).

If the output is empty or missing expected columns, the input spectrum (Step 4.2) does not satisfy the requirements. Replace it with a scan that yields at least one deconvolution result and repeat from 6.1.

6.4. Copy the downloaded TSV to `FlashIDA/test-data/golden/baseline_phase0.tsv` and commit it. This file is the regression anchor for all future phases.

6.5. Push again. On this second push, the CI regression comparison step finds `baseline_phase0.tsv` in the repository and `compare_golden.py` passes.

---

### Step 7 — Create the Comparison Script

Create the Python script used by CI to compare TSV outputs against golden files. This script is used by all regression tests from Phase 0 onward.

7.1. Create `FlashIDA/test-scripts/compare_golden.py` with the content specified in [../testing-strategy.md Section 6.2](../testing-strategy.md#62-comparison-logic). The script takes two positional arguments (golden file path, actual file path) and exits with code 1 on mismatch.

Key comparison rules (from the testing strategy):
- Row count must match exactly.
- String columns (e.g., `charges`): exact match.
- Float columns (`rt`, `mz1`, `mz2`, `qScore`, `monoMasses`, `ccos`, `csnr`, `cos`, `snr`, `cScore`, `ppm`, `precursorIntensity`, `massIntensity`): absolute tolerance 1e-6, or relative tolerance 1e-4 for values > 1.0.
- Integer columns (`hcd`): exact match.

7.2. Create `FlashIDA/test-scripts/regression-runner.ps1` that runs `Flash.exe -t` for each configured (spectrum, method) pair and calls `compare_golden.py`. For Phase 0, only the smoke test configuration is included; subsequent phases add entries to this script.

```powershell
# regression-runner.ps1
param (
    [string]$FlashExe = "FlashIDA\src\Flash\bin\Debug\Flash.exe",
    [string]$TestDataDir = "FlashIDA\test-data",
    [string]$OutputDir = "FlashIDA\test-output"
)

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$configs = @(
    @{
        name    = "baseline_phase0"
        method  = "method_default.xml"
        ms1     = "ms1_smoke_test.txt"
        golden  = "baseline_phase0.tsv"
    }
    # Subsequent phases add entries here.
)

$failures = 0

foreach ($cfg in $configs) {
    $outputFile = Join-Path $OutputDir "$($cfg.name).tsv"
    $ms1File    = Join-Path $TestDataDir "spectra\$($cfg.ms1)"
    $methodFile = Join-Path $TestDataDir "configs\$($cfg.method)"
    $goldenFile = Join-Path $TestDataDir "golden\$($cfg.golden)"

    Write-Host "Running: $($cfg.name) ..."
    & $FlashExe -t $ms1File $outputFile $methodFile

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: Flash.exe exited with code $LASTEXITCODE for $($cfg.name)"
        $failures++
        continue
    }

    python FlashIDA\test-scripts\compare_golden.py $goldenFile $outputFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: Golden comparison failed for $($cfg.name)"
        $failures++
    } else {
        Write-Host "PASS: $($cfg.name)"
    }
}

if ($failures -gt 0) {
    Write-Host "$failures test(s) failed."
    exit 1
}
Write-Host "All regression tests passed."
exit 0
```

---

### Step 8 — Create the CI Workflow

Create the GitHub Actions workflow skeleton. In Phase 0, only the jobs that can succeed without a C++ build are active. The `cpp-unit-tests` job is present but conditionally skipped (there are no C++ tests yet).

8.1. Create `.github/workflows/flashida-ci.yml`:

```yaml
name: flashida-ci

on:
  push:
    branches: [main, develop, flashida-v9-migration, 'phase-*']
  pull_request:
    branches: [main, develop, flashida-v9-migration]

jobs:
  # ----------------------------------------------------------------
  # C++ unit tests — ubuntu-latest, no Thermo or .NET dependency.
  # Skipped in Phase 0 (no C++ tests exist yet).
  # Activated in Phase 2 when OptimizationMetadata tests are added.
  # ----------------------------------------------------------------
  cpp-unit-tests:
    runs-on: ubuntu-latest
    if: false  # Phase 0: no C++ tests yet. Remove this line in Phase 2.
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Restore CMake cache
        uses: actions/cache@v4
        with:
          path: OpenMS/build
          key: cmake-${{ runner.os }}-${{ hashFiles('OpenMS/CMakeLists.txt') }}

      - name: Build C++ test binaries only
        run: |
          cmake -S OpenMS -B OpenMS/build -DCMAKE_BUILD_TYPE=Release
          cmake --build OpenMS/build --target FLASHIda_test --config Release

      - name: Run FLASH C++ unit tests
        run: ctest --test-dir OpenMS/build -R FLASH --output-on-failure

  # ----------------------------------------------------------------
  # C# unit tests + regression — windows-latest.
  # Requires Thermo DLLs (build only) + OpenMS DLLs (runtime).
  # ----------------------------------------------------------------
  csharp-tests:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      # --- Restore Thermo iAPI DLLs (proprietary, from secret) ---
      # Strategy A: base64 secret. Switch to Strategy B if DLLs are large.
      # See testing-strategy.md Section 3.3 for setup instructions.
      - name: Restore Thermo iAPI DLLs
        shell: powershell
        env:
          THERMO_DLLS_B64: ${{ secrets.THERMO_IAPI_DLLS_BASE64 }}
        run: |
          $bytes = [Convert]::FromBase64String($env:THERMO_DLLS_B64)
          [System.IO.File]::WriteAllBytes("thermo-dlls.zip", $bytes)
          Expand-Archive -Path "thermo-dlls.zip" -DestinationPath "FlashIDA\dependencies" -Force
          Remove-Item "thermo-dlls.zip"
          Write-Host "Restored Thermo DLLs:"
          Get-ChildItem "FlashIDA\dependencies\*.dll" | ForEach-Object { Write-Host "  $($_.Name)" }

      # --- Restore or download OpenMS DLLs ---
      - name: Get OpenMS submodule commit hash
        id: openms-hash
        shell: bash
        run: echo "hash=$(git -C OpenMS rev-parse HEAD)" >> $GITHUB_OUTPUT

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

      # --- Build ---
      - name: Setup MSBuild
        uses: microsoft/setup-msbuild@v2

      - name: Restore NuGet packages
        run: nuget restore FlashIDA/src/Flash.sln

      - name: Build solution (Debug)
        run: |
          msbuild FlashIDA/src/Flash.sln `
            /p:Configuration=Debug `
            /p:Platform="Any CPU" `
            /m

      # Copy OpenMS DLLs to Flash.exe output directory for runtime loading.
      - name: Copy OpenMS DLLs to build output
        shell: powershell
        run: |
          Copy-Item FlashIDA\dll\*.dll FlashIDA\src\Flash\bin\Debug\
          Copy-Item FlashIDA\dll\*.dll FlashIDA\src\Flash.Tests\bin\Debug\

      # Copy Thermo DLLs to build output for Flash.exe runtime.
      # See CI Environment Requirements in implementation-roadmap.md.
      - name: Copy Thermo DLLs to build output
        shell: powershell
        run: |
          Copy-Item FlashIDA\dependencies\*.dll FlashIDA\src\Flash\bin\Debug\

      # --- Unit tests (Tier 1: NUnit) ---
      - name: Run NUnit unit tests
        run: |
          nunit3-console `
            FlashIDA\src\Flash.Tests\bin\Debug\Flash.Tests.dll `
            --result=TestResults.xml

      - name: Upload NUnit results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: nunit-results
          path: TestResults.xml

      # --- Golden capture (first push, before baseline_phase0.tsv exists) ---
      # Run Flash.exe -t directly and upload the raw output as an artifact.
      # The developer downloads this artifact, inspects it, and commits it
      # as baseline_phase0.tsv (see Step 6).
      - name: Capture golden output
        shell: powershell
        run: |
          New-Item -ItemType Directory -Force -Path FlashIDA\test-output | Out-Null
          FlashIDA\src\Flash\bin\Debug\Flash.exe -t `
            FlashIDA\test-data\spectra\ms1_smoke_test.txt `
            FlashIDA\test-output\baseline_phase0.tsv `
            FlashIDA\test-data\configs\method_default.xml

      - name: Upload golden capture
        uses: actions/upload-artifact@v4
        with:
          name: golden-capture
          path: FlashIDA/test-output/baseline_phase0.tsv

      # --- Regression tests (Tier 3: Flash.exe -t) ---
      # Skipped on the first push (no baseline_phase0.tsv committed yet).
      # Passes on the second push (after baseline_phase0.tsv is committed).
      - name: Run regression tests
        shell: powershell
        run: |
          python FlashIDA\test-scripts\compare_golden.py `
            --help > $null 2>&1  # verify script is present
          powershell FlashIDA\test-scripts\regression-runner.ps1 `
            -FlashExe FlashIDA\src\Flash\bin\Debug\Flash.exe `
            -TestDataDir FlashIDA\test-data `
            -OutputDir FlashIDA\test-output

      - name: Upload regression output
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: regression-output
          path: FlashIDA/test-output/

  # ----------------------------------------------------------------
  # Bridge smoke tests (Tier 2) — windows-latest.
  # Reuses build artifacts from csharp-tests job.
  # Phase 0: only CreateFLASHIda/DisposeFLASHIda smoke tests.
  # ----------------------------------------------------------------
  bridge-tests:
    runs-on: windows-latest
    needs: [csharp-tests]
    steps:
      - uses: actions/checkout@v4

      # The NUnit tests in BridgeSmokeTests.cs already exercise the bridge.
      # The bridge test job re-runs only the Tier2-categorized tests.
      # In Phase 3+, dumpbin /exports verification is added here.
      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: nunit-results

      - name: Verify bridge smoke tests passed
        shell: powershell
        run: |
          # P0-I01 and P0-I02 are run as part of the csharp-tests job above.
          # This step confirms the artifact exists (tests ran) and the
          # results file reports no failures for Tier2 tests.
          [xml]$results = Get-Content TestResults.xml
          $tier2Failures = $results.SelectNodes(
            "//test-case[@result='Failed'][contains(@categories,'Tier2')]")
          if ($tier2Failures.Count -gt 0) {
              Write-Host "Bridge smoke tests failed:"
              $tier2Failures | ForEach-Object { Write-Host "  $($_.name)" }
              exit 1
          }
          Write-Host "Bridge smoke tests passed."

  # ----------------------------------------------------------------
  # Stress tests (Tier 4) — windows-latest.
  # Phase 0: no stress tests. Job is defined but skipped.
  # Activated in Phase 3 when queue/tracking tests are added.
  # ----------------------------------------------------------------
  stress-tests:
    runs-on: windows-latest
    needs: [csharp-tests]
    if: false  # Phase 0: no stress tests yet. Remove this line in Phase 3.
    steps:
      - run: echo "Stress tests not yet active in Phase 0."
```

8.2. Verify the workflow YAML is syntactically valid:
```bash
# If you have the GitHub CLI installed:
gh workflow view flashida-ci
# Or validate with a YAML linter:
python -c "import yaml; yaml.safe_load(open('.github/workflows/flashida-ci.yml'))"
```

8.3. Note on `dawidd6/action-download-artifact`: This is a community action for cross-workflow artifact downloads. Verify the version pinned in the workflow matches the currently available version at time of setup. Pin to a specific commit SHA for supply chain security if required by team policy.

---

### Step 9 — Add .gitignore Entries

Ensure proprietary DLLs and build output are not accidentally committed.

9.1. Verify or add the following entries to the repository root `.gitignore`:
```gitignore
# Proprietary Thermo iAPI DLLs — never commit plaintext
FlashIDA/dependencies/*.dll

# Build output
FlashIDA/src/Flash/bin/
FlashIDA/src/Flash/obj/
FlashIDA/src/Flash.Tests/bin/
FlashIDA/src/Flash.Tests/obj/

# Regression test output (generated, not committed)
FlashIDA/test-output/

# NuGet restore output
packages/
```

---

### Step 10 — Verification via CI

Verification is performed by CI. After pushing to the branch (including `baseline_phase0.tsv` as captured in Step 6), verify that the `csharp-tests` and `bridge-tests` jobs both pass (green) in GitHub Actions. No local Windows build is required to confirm Phase 0 completion.

---

## Files to Create or Modify

### New Files

| File | Description |
|------|-------------|
| `FlashIDA/src/Flash.Tests/Flash.Tests.csproj` | NUnit test project targeting .NET 4.8. References `Flash.csproj` and NUnit 3. |
| `FlashIDA/src/Flash.Tests/packages.config` | NuGet package declarations for NUnit 3, NUnit3TestAdapter, NUnitConsoleRunner. |
| `FlashIDA/src/Flash.Tests/SmokeTests.cs` | P0-U01 through P0-U04: build verification and test-mode execution tests. |
| `FlashIDA/src/Flash.Tests/BridgeSmokeTests.cs` | P0-I01, P0-I02: CreateFLASHIda/DisposeFLASHIda bridge smoke tests. |
| `FlashIDA/test-data/spectra/ms1_smoke_test.txt` | Real MS1 scan (10–200 peaks) extracted from an existing top-down `.mzML` file. Must yield at least 1 deconvolution result. |
| `FlashIDA/test-data/configs/method_default.xml` | Standard DDA method configuration (copy of existing `method.xml` defaults). |
| `FlashIDA/test-data/golden/README.md` | Documents golden file provenance, update procedure, and review expectations. |
| `FlashIDA/test-data/golden/baseline_phase0.tsv` | Captured output of `Flash.exe -t` on the current codebase, downloaded from the CI `golden-capture` artifact (Step 6). First golden file. |
| `FlashIDA/test-scripts/compare_golden.py` | Python script for TSV golden file comparison with numeric tolerance. |
| `FlashIDA/test-scripts/regression-runner.ps1` | PowerShell script that runs `Flash.exe -t` for each config and calls compare_golden.py. |
| `.github/workflows/flashida-ci.yml` | Main CI workflow. Phase 0 skeleton: `csharp-tests` and `bridge-tests` active, `cpp-unit-tests` and `stress-tests` skipped. |

### Modified Files

| File | Change |
|------|--------|
| `FlashIDA/src/Flash.sln` | Add `Flash.Tests.csproj` as a project in the solution. Add it to Debug and Release solution configurations. |
| `.gitignore` (root) | Add entries for `FlashIDA/dependencies/*.dll`, build output dirs, `FlashIDA/test-output/`, and NuGet packages. |

### Files Read (Inspection Only, No Modification)

| File | Why Read |
|------|---------|
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Determine DLL name for `[DllImport]`, find `CreateFLASHIda` call site, confirm test mode argument format. |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Find `ToFLASHDeconvInput()` to replicate the legacy config string in `BridgeSmokeTests.cs`. |
| `FlashIDA/src/Flash/etc/method.xml` | Source for `method_default.xml` test config. |

---

## Test Cases

All 7 Phase 0 tests. No C++ tests in this phase. No stress tests in this phase.

### Tier 1 — Unit Tests (windows-latest, < 5 min)

| Test ID | Name | Description | Expected Outcome | Runner |
|---------|------|-------------|------------------|--------|
| P0-U01 | `P0_U01_SolutionCompilesWithoutError` | Asserts that the test assembly was compiled — if the build failed, this test would not exist in the runner. | Test passes by reaching execution (assembly compiled). MSBuild exit code 0 in CI. | `windows-latest` |
| P0-U02 | `P0_U02_FlashExeExistsInBuildOutput` | Checks that `Flash.exe` is present at `FlashIDA/src/Flash/bin/Debug/Flash.exe` after build. | `File.Exists(FlashExePath)` is true. | `windows-latest` |

### Tier 2 — Integration (Bridge Smoke) Tests (windows-latest, < 15 min)

| Test ID | Name | Description | Expected Outcome | Runner |
|---------|------|-------------|------------------|--------|
| P0-I01 | `P0_I01_CreateFLASHIda_DoesNotCrash` | Calls `CreateFLASHIda(legacyConfig)` via P/Invoke. Validates that the bridge call completes without access violation and returns a non-null pointer. | No exception thrown. Return value is not `IntPtr.Zero`. | `windows-latest` |
| P0-I02 | `P0_I02_DisposeFLASHIda_DoesNotCrash` | Calls `DisposeFLASHIda(ptr)` on the pointer returned by `CreateFLASHIda`. Validates clean teardown. | No exception thrown. No access violation. | `windows-latest` |

These tests require both OpenMS DLLs (`FlashIDA/dll/`) and Thermo DLLs (`FlashIDA/dependencies/`) to be present on the CI runner. The C# test assembly links against `Flash.csproj` which references the Thermo assemblies at compile time.

### Tier 3 — Regression Tests (windows-latest, < 20 min)

| Test ID | Name | Description | Expected Outcome | Runner |
|---------|------|-------------|------------------|--------|
| P0-U03 | `P0_U03_TestModeRunsAndExitsCleanly` | Launches `Flash.exe -t ms1_smoke_test.txt output.tsv method_default.xml` as a subprocess. Waits up to 60 seconds. | Process exit code 0. No unhandled exception output on stderr. | `windows-latest` |
| P0-U04 | `P0_U04_TestModeOutputIsNonEmptyValidTsv` | Launches `Flash.exe -t` and inspects the output file. Verifies it is a valid TSV with the expected column header and at least one data row. | Output file exists. `lines.Length >= 2`. All 15 expected column names present in header row. | `windows-latest` |
| P0-R01 | Regression: golden baseline capture | Runs `Flash.exe -t ms1_smoke_test.txt baseline_phase0.tsv method_default.xml`. Compares output to the committed `baseline_phase0.tsv` using `compare_golden.py`. | `compare_golden.py` exits with code 0. Output is `PASS`. | `windows-latest` |

Note: P0-U03 and P0-U04 are classified as Tier 1 tests in their NUnit category but they exercise `Flash.exe` as a subprocess, so they are grouped here with the regression tier for DLL dependency purposes.

P0-R01 is automated by the `regression-runner.ps1` script in the `csharp-tests` CI job. `baseline_phase0.tsv` must be committed before CI runs so that the comparison has a reference file.

---

## CI Configuration

### What Phase 0 Activates

| CI Job | Status in Phase 0 | Notes |
|--------|-------------------|-------|
| `cpp-unit-tests` (ubuntu-latest) | Skipped (`if: false`) | No C++ tests exist yet. Activated in Phase 2. |
| `csharp-tests` (windows-latest) | Active | Builds solution, runs NUnit tests, runs regression suite. |
| `bridge-tests` (windows-latest) | Active (lightweight) | Verifies P0-I01/P0-I02 passed in csharp-tests job. No additional tests. |
| `stress-tests` (windows-latest) | Skipped (`if: false`) | No stress tests yet. Activated in Phase 3. |

### Secrets Required in Phase 0

| Secret | Strategy | Required by |
|--------|----------|-------------|
| `THERMO_IAPI_DLLS_BASE64` | Strategy A (base64) | All `windows-latest` jobs: MSBuild cannot compile without Thermo DLLs. |

If Thermo DLLs exceed the GitHub secret size limit, switch to Strategy B (encrypted 7z) and use `THERMO_DLL_PASSPHRASE` instead. The CI workflow step must be updated to use the decrypt procedure from [../testing-strategy.md Section 3.3](../testing-strategy.md#33-handling-proprietary-dlls).

### OpenMS DLL Caching

The `csharp-tests` job caches OpenMS DLLs keyed by the OpenMS submodule commit hash. On the first CI run (no cache), it downloads the DLL artifact from the `build-openms-dll.yml` workflow. Subsequent runs with no OpenMS submodule changes will hit the cache and skip the download.

If no `build-openms-dll.yml` artifact is available for the current submodule hash (e.g., after advancing the submodule), a new build must be triggered manually before CI can pass.

### Branch Trigger Strategy

The workflow triggers on:
- Pushes to: `main`, `develop`, `flashida-v9-migration`, and any `phase-*` branch.
- Pull requests targeting: `main`, `develop`, `flashida-v9-migration`.

The migration work is done on `flashida-v9-migration`. Each phase can optionally use a dedicated `phase-N` branch for isolation.

---

## Working Product Verification

At the end of Phase 0, the following must all be true before the phase is considered complete.

**WPV-1: Solution builds without error.**
- Automated by: CI job `csharp-tests` (step: "Build solution (Debug)"). MSBuild must exit with code 0 and `Flash.exe` must be present in the build output.
- Confirmed by: P0-U01, P0-U02 passing in CI.

**WPV-2: `Flash.exe -t` runs and produces valid TSV output.**
- Automated by: CI job `csharp-tests` (steps: "Run NUnit unit tests" for P0-U03/P0-U04, and "Run regression tests" for P0-R01).
- Confirmed by: P0-U03 and P0-U04 passing in CI (exit code 0, header row + at least 1 data row, all 15 columns present).

**WPV-3: Bridge calls (Create/Dispose) complete without crash.**
- Automated by: CI job `csharp-tests` (step: "Run NUnit unit tests") and CI job `bridge-tests` (step: "Verify bridge smoke tests passed").
- Confirmed by: P0-I01 and P0-I02 passing in CI (non-null pointer returned; no crash on dispose).

**WPV-4: Golden baseline captured and committed.**
- Verify: `FlashIDA/test-data/golden/baseline_phase0.tsv` exists in the repository (committed following the CI artifact workflow in Step 6).
- Automated by: CI job `csharp-tests` (step: "Run regression tests") running `compare_golden.py`. Confirmed by: P0-R01 passing in CI.

**WPV-5: CI workflow runs and all active jobs pass.**
- Push to `flashida-v9-migration` branch.
- Verify: `csharp-tests` job passes (green). `bridge-tests` job passes (green).
- `cpp-unit-tests` and `stress-tests` jobs are skipped (not failed).

---

## Definition of Done

- [ ] `Flash.Tests.csproj` created and added to `Flash.sln`. Solution builds with the test project included.
- [ ] `SmokeTests.cs` created with P0-U01, P0-U02, P0-U03, P0-U04.
- [ ] `BridgeSmokeTests.cs` created with P0-I01, P0-I02. `BuildLegacyConfigString()` replicates actual `Parameter.ToFLASHDeconvInput()` output (verified by Step 5 inspection).
- [ ] `ms1_smoke_test.txt` created and committed. Contains a real MS1 scan (10–200 peaks) extracted from an existing top-down `.mzML` file using `prepare-test-data.py`. Not synthetically constructed. Produces at least 1 row of deconvolution output.
- [ ] `method_default.xml` created and committed under `test-data/configs/`.
- [ ] `baseline_phase0.tsv` captured via the CI artifact workflow (Step 6): downloaded from the `golden-capture` artifact of the first CI run and committed to `test-data/golden/`.
- [ ] `golden/README.md` created and committed.
- [ ] `compare_golden.py` created and committed. `compare_golden.py X X` (same file) outputs `PASS`.
- [ ] `regression-runner.ps1` created and committed.
- [ ] `.github/workflows/flashida-ci.yml` created with the Phase 0 skeleton. `cpp-unit-tests` and `stress-tests` jobs are explicitly skipped with `if: false`.
- [ ] `.gitignore` updated: `FlashIDA/dependencies/*.dll` is excluded.
- [ ] All 7 Phase 0 tests pass in CI: P0-U01 through P0-U04 (4 unit/smoke) + P0-I01, P0-I02 (2 bridge) + P0-R01 (1 regression).
- [ ] CI workflow passes on `flashida-v9-migration` branch: `csharp-tests` and `bridge-tests` jobs are green. No jobs are red.
- [ ] No code in `FlashIDA/src/Flash/` has been modified. Phase 0 is test infrastructure only — zero changes to production code.

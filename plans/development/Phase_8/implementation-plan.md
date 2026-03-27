# Phase 8: Cleanup + Documentation — Implementation Plan

**Date:** 2026-03-21
**Build:** Build #4 (ships together with Phase 7)
**Status:** Final phase of the FLASHIda v9 migration
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 7 and Phase 8 specification
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 8 roadmap entry
- [../testing-strategy.md](../testing-strategy.md) — Phase 8 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative format, content, and naming specification for all test data files (spectrum files, golden TSVs, config XMLs, test scripts)

---

## Goal

Remove all legacy bridge infrastructure and dead C# code, leaving exactly 5 exported bridge
functions. Eliminate the legacy config parsing path so JSON is the only accepted format.
Add `MethodDocGenerator.cs` as a reflection utility for `[Description]` attribute-driven
documentation. This phase produces the permanent, final form of the bridge API.

After this phase:

- `OpenMS.dll` exports exactly 5 symbols: `CreateFLASHIda`, `DisposeFLASHIda`, `ProcessScan`,
  `GetNextScanCommand`, `GetNextTrackingId`.
- `FLASHIdaWrapper.cs` contains exactly 5 `[DllImport]` declarations.
- No C# code references removed bridge functions, `ToFLASHDeconvInput()`, or legacy parsing.
- The C++ constructor rejects non-JSON input (no `parseLegacy` fallback).
- `MethodDocGenerator.cs` is present and produces correct output.
- The full regression suite passes against Phase 7 golden files.

---

## Prerequisites

The following must be true before starting Phase 8:

1. **Phase 7 is complete and verified.** The exploration engine is implemented, all Phase 7
   working product verification criteria pass, and Phase 7 golden files are committed to
   `FlashIDA/test-data/golden/`.

2. **Build #4 C++ compilation of Phase 7 has succeeded.** The exploration engine changes are
   compiled into `OpenMS.dll` and the DLL artifact is committed in `FlashIDA/dll/` (OpenMS
   DLLs are committed to the repo, not downloaded — Phase 0 lesson #5).

3. **All prior regression tests pass.** Every test from P0 through P7 passes on the
   Build #4 artifact. No test regressions are open.

4. **No callers of the old bridge functions remain.** Phase 4 (ProcessScan full routing),
   Phase 5 (C# simplification), and Phase 6 (FAIMS absorption) must have removed all C#-side
   calls to the 13 functions being deleted in this phase. Verify with the dead-code grep
   described in Step 1 below before touching any C++ code.

5. **Legacy config format is no longer passed from C#.** Phase 1 (JSON Configuration)
   switched `FLASHIdaWrapper.cs` to pass JSON via `Parameter.ToJSON()`. The legacy
   space-delimited string path must not be reachable from any live C# code path.

### User-Provided Inputs

No new user-provided data is required for Phase 8. All spectrum files, golden files, and config files were established in prior phases. Phase 8 is a cleanup and documentation phase.

---

## The 13 Functions to Remove and the 5 That Remain

### 13 bridge exports to remove

These are removed from both `FLASHIdaBridgeFunctions.h/.cpp` (C++ declarations and
definitions) and `FLASHIdaWrapper.cs` (C# P/Invoke declarations):

| # | Function name | Original purpose |
|---|---------------|-----------------|
| 1 | `GetPeakGroupSize` | Returns count of deconvolved peak groups from last MS1 |
| 2 | `GetIsolationWindows` | Fills arrays of m/z and charge for top-N isolation targets |
| 3 | `DeconvolveMS2` | Runs MS2 deconvolution for a single spectrum |
| 4 | `ProcessMS2ForTagBasedTargeting` | Routes MS2 results into tag-based targeting state |
| 5 | `GetBestMS2Masses` | Returns ranked fragment masses after MS2 deconvolution |
| 6 | `ClearMS2Deconvolution` | Resets MS2 deconvolution state between scans |
| 7 | `GetRepresentativeMass` | Returns representative (most abundant) mass for a peak group |
| 8 | `GetAllMonoisotopicMasses` | Returns all monoisotopic masses for a peak group |
| 9 | `RemoveFromExclusionList` | Removes an m/z from the runtime exclusion list |
| 10 | `AddToInclusionList` | Adds a mass to the runtime inclusion list |
| 11 | `GetMS1ScanResult` | Returns scored MS1 scan result metadata |
| 12 | `ResetScanState` | Resets per-scan internal state (formerly called between events) |
| 13 | `GetDeconvolutionQuality` | Returns a quality metric for the last deconvolution |

Note: The exact set of 13 must be confirmed against the current `FLASHIdaBridgeFunctions.h`
before deletion. If the count or names differ from what was originally counted as ~20
functions minus the 5 keepers, adjust accordingly. The invariant is: after Phase 8,
exactly 5 exports remain.

### 5 bridge exports that remain

| Function | C++ signature | C# P/Invoke |
|----------|---------------|-------------|
| `CreateFLASHIda` | `FLASHIda* CreateFLASHIda(const char* jsonConfig)` | `static extern IntPtr CreateFLASHIda(string jsonConfig)` |
| `DisposeFLASHIda` | `void DisposeFLASHIda(FLASHIda* ptr)` | `static extern void DisposeFLASHIda(IntPtr ptr)` |
| `ProcessScan` | `int ProcessScan(FLASHIda* obj, double* mzs, double* ints, int length, double rt_min, int ms_level, const char* scan_description)` | `static extern int ProcessScan(IntPtr ptr, double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc)` |
| `GetNextScanCommand` | `int GetNextScanCommand(FLASHIda* obj, ScanCommand* output)` | `static extern int GetNextScanCommand(IntPtr ptr, ref ScanCommand output)` |
| `GetNextTrackingId` | `int GetNextTrackingId(FLASHIda* obj)` | `static extern int GetNextTrackingId(IntPtr ptr)` |

---

## Detailed Implementation Steps

### Step 1 — Verify no live callers exist before touching C++ (pre-condition check)

These checks are automated by **P8-U01** and **P8-U02** in the `windows-tests` CI job.
Do not proceed to Steps 2+ unless P8-U01 and P8-U02 pass in CI on the current state of
the branch.

The scripts below are reference implementations of what those tests check. They run in CI,
not locally.

**C# call-site verification (reference — runs in CI as part of P8-U01/P8-U02):**

```powershell
$funcs = @(
    "GetPeakGroupSize", "GetIsolationWindows", "DeconvolveMS2",
    "ProcessMS2ForTagBasedTargeting", "GetBestMS2Masses", "ClearMS2Deconvolution",
    "GetRepresentativeMass", "GetAllMonoisotopicMasses", "RemoveFromExclusionList",
    "AddToInclusionList", "GetMS1ScanResult", "ResetScanState", "GetDeconvolutionQuality"
)
foreach ($f in $funcs) {
    $hits = Select-String -Path "FlashIDA\src\**\*.cs" -Pattern $f -Recurse |
            Where-Object { $_.Filename -ne "FLASHIdaWrapper.cs" }
    if ($hits) { Write-Host "BLOCKER: $f still called from: $($hits.Filename)" }
    else { Write-Host "OK: $f has no C# callers outside wrapper" }
}
```

**C++ caller verification (reference — runs in CI on `ubuntu-latest`):**

```bash
for func in GetPeakGroupSize GetIsolationWindows DeconvolveMS2 \
            ProcessMS2ForTagBasedTargeting GetBestMS2Masses ClearMS2Deconvolution \
            GetRepresentativeMass GetAllMonoisotopicMasses RemoveFromExclusionList \
            AddToInclusionList GetMS1ScanResult ResetScanState GetDeconvolutionQuality; do
    hits=$(grep -rn "$func" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/ \
           --include="*.cpp" --include="*.h" \
           | grep -v "FLASHIdaBridgeFunctions")
    if [ -n "$hits" ]; then
        echo "BLOCKER: $func has callers outside bridge file:"
        echo "$hits"
    else
        echo "OK: $func clear"
    fi
done
```

**`ToFLASHDeconvInput` absence check (reference — runs in CI as part of P8-U02):**

```powershell
Select-String -Path "FlashIDA\src\**\*.cs" -Pattern "ToFLASHDeconvInput" -Recurse |
    Where-Object { $_.Filename -ne "Parameter.cs" }
```

---

### Step 2 — Remove the 13 C++ bridge exports from the header

File: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h`

For each of the 13 functions, remove the `extern "C" OPENMS_DLLAPI` declaration. Leave only
the 5 keeper declarations and any file-level includes or guards that remain valid.

The header after this step contains exactly these 5 declarations (plus any necessary includes
and `#ifdef`/`#pragma` guards):

```cpp
extern "C" OPENMS_DLLAPI FLASHIda* CreateFLASHIda(const char* json_config);
extern "C" OPENMS_DLLAPI void      DisposeFLASHIda(FLASHIda* obj);
extern "C" OPENMS_DLLAPI int       ProcessScan(FLASHIda* obj,
                                               double* mzs, double* ints, int length,
                                               double rt_min, int ms_level,
                                               const char* scan_description);
extern "C" OPENMS_DLLAPI int       GetNextScanCommand(FLASHIda* obj,
                                                      ScanCommand* output);
extern "C" OPENMS_DLLAPI int       GetNextTrackingId(FLASHIda* obj);
```

---

### Step 3 — Remove the 13 C++ bridge function definitions

File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp`

Delete the entire function body for each of the 13 functions. Do not leave stub bodies,
`/* removed */` comments, or `#if 0` blocks. The removed code is in version control; leaving
dead stubs is noise.

After this step, `FLASHIdaBridgeFunctions.cpp` contains only the 5 keeper definitions.

---

### Step 4 — Remove internal C++ methods that were only called by the old bridge functions

File: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Audit the private methods of `FLASHIda` for any that are now unreachable. A method is safe
to remove if:

- It was called only from one or more of the 13 deleted bridge wrapper functions.
- It is not called from `processScan_()`, `getNextScanCommand_()`, `feedExplorationResult_()`,
  or any other method reachable from the 5 keeper exports.

Common candidates (confirm by grep before deletion):

- `getPeakGroupSize_()` — served `GetPeakGroupSize`
- `fillIsolationWindows_()` — served `GetIsolationWindows`
- `deconvolveMS2_()` — may have been superseded by the MS2 path inside `processScan_()`
- `resetScanState_()` — served `ResetScanState`

Do not remove methods that are still referenced from anywhere in `FLASHIda.cpp` or
`FLASHIdaBridgeFunctions.cpp` (post-deletion). When in doubt, leave the method and note it
for a follow-up cleanup; the priority is shipping a correct bridge, not perfect internal
cleanliness.

---

### Step 5 — Remove legacy config parsing from C++

File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Locate the constructor of `FLASHIda` (or the config parsing entry point, depending on how
it was structured). It currently contains an auto-detect branch introduced in Phase 1:

```cpp
if (arg[0] == '{')
    parseJSON_(arg);
else
    parseLegacy_(arg);
```

Remove the `else` branch entirely. The constructor should now call `parseJSON_()` directly
or simply assert/throw if the input is not JSON. Choose the approach that is most consistent
with the existing error handling style in the file:

- **Preferred (throw):** `throw std::invalid_argument("FLASHIda: config must be JSON");`
- **Alternative (log + abort):** Log an error via OpenMS log macros and return early, leaving
  the object in an uninitialized state that causes subsequent bridge calls to return
  safe-failure values.

Also remove the `parseLegacy_()` method declaration from `FLASHIda.h` and its definition
from `FLASHIda.cpp`.

---

### Step 6 — Remove 13 old C# P/Invoke declarations from FLASHIdaWrapper.cs

File: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

Remove the `[DllImport(dllName)]` declaration line and its associated static extern method
signature for each of the 13 functions. Do not remove any helper methods in `FLASHIdaWrapper`
that wrap the 5 keeper functions (e.g., any public methods that call `ProcessScan` internally).

After this step, the file contains exactly 5 `[DllImport(dllName)]` lines. The count is
verifiable by test P8-U01.

The 5 declarations that remain (from Issue 7 in baseline-plan.md). Note: `dllName` must
resolve to `"OpenMS.dll"` (with extension), matching the actual P/Invoke constant:

```csharp
[DllImport(dllName)] static extern IntPtr CreateFLASHIda(string jsonConfig);
[DllImport(dllName)] static extern void   DisposeFLASHIda(IntPtr ptr);
[DllImport(dllName)] static extern int    ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc);
[DllImport(dllName)] static extern int    GetNextScanCommand(IntPtr ptr,
    ref ScanCommand output);
[DllImport(dllName)] static extern int    GetNextTrackingId(IntPtr ptr);
```

---

### Step 7 — Remove Parameter.ToFLASHDeconvInput()

File: `FlashIDA/src/Flash/IDA/Parameter.cs`

Delete the `ToFLASHDeconvInput()` method. This is the legacy space-delimited token
serializer that was replaced by `ToJSON()` in Phase 1.

Also remove any `using` directives, private helper methods, or string-formatting constants
that exist solely to support `ToFLASHDeconvInput()` and are not used elsewhere in the file.

The `[Description]` attributes added in Phase 1, and the `ToJSON()` method, must be left
intact.

---

### Step 8 — Create MethodDocGenerator.cs

File: `FlashIDA/src/Flash/IDA/MethodDocGenerator.cs` (new file)

`MethodDocGenerator` is a reflection utility that reads `[Description]` attributes from
properties in `Parameter.cs` and `MethodConfig.cs` and formats them as documentation.
It is approximately 30 lines long, as specified in Issue 8 of baseline-plan.md.

The class must:

1. Accept a `Type` argument (or default to scanning `Parameter` and `MethodConfig`).
2. Iterate over all public properties of the type using `System.Reflection`.
3. For each property that has a `[System.ComponentModel.Description]` attribute, emit a
   line of the form: `PropertyName: <description text>`.
4. Return or print the result. Provide both a static `Generate(Type t)` method that returns
   a `string` (used by test P8-U03) and optionally a `GenerateToConsole()` convenience
   overload.

Minimal reference implementation shape (fill in details to match project style):

```csharp
using System;
using System.ComponentModel;
using System.Reflection;
using System.Text;

namespace Flash.IDA
{
    public static class MethodDocGenerator
    {
        public static string Generate(Type type)
        {
            var sb = new StringBuilder();
            foreach (PropertyInfo prop in type.GetProperties(
                BindingFlags.Public | BindingFlags.Instance))
            {
                var attr = prop.GetCustomAttribute<DescriptionAttribute>();
                if (attr != null)
                    sb.AppendLine($"{prop.Name}: {attr.Description}");
            }
            return sb.ToString();
        }

        public static void GenerateToConsole(Type type)
            => Console.Write(Generate(type));
    }
}
```

Place `MethodDocGenerator.cs` in the same directory as `Parameter.cs` and include it in
`Flash.csproj` under the appropriate `<Compile>` item group (or rely on the wildcard glob
if the project uses one).

---

### Step 9 — Build and verify compilation

After all code changes are complete, build the C++ library and C# solution:

**C++ (part of Build #4, batched with Phase 7):**

```bash
cmake --build <build-dir> --config Release
```

The build must succeed with zero errors. No warnings about undefined symbols or missing
exports are acceptable.

**C# (CI `windows-latest` — `windows-tests` job):**

```powershell
msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror
```

The `/warnaserror` flag is required here. Zero warnings must remain after the removed code
is gone. Common warning sources to resolve:

- Unreferenced `using` directives left behind after method removal.
- Variables or parameters that were only used by now-deleted call sites.
- Nullable reference warnings if the project has that analyzer enabled.

---

### Step 10 — Update DLL export verification test data

File: `FlashIDA/test-data/` (update any hard-coded export counts or lists)

The integration test P8-I01 checks `dumpbin /exports` for exactly 5 bridge symbols and
verifies that none of the removed names are present. If the test script contains a hard-coded
list of expected absent names, add all 13 removed function names to it. See Section 5.4 of
`testing-strategy.md` for the baseline `dumpbin` CI step; extend the `findstr` block to also
assert absence:

```cmd
dumpbin /exports FlashIDA\dll\OpenMS.dll > exports.txt
rem Verify 5 keeper functions present
findstr /C:"CreateFLASHIda"     exports.txt || exit /b 1
findstr /C:"DisposeFLASHIda"    exports.txt || exit /b 1
findstr /C:"ProcessScan"        exports.txt || exit /b 1
findstr /C:"GetNextScanCommand" exports.txt || exit /b 1
findstr /C:"GetNextTrackingId"  exports.txt || exit /b 1
rem Verify 13 removed functions are absent
findstr /C:"GetPeakGroupSize"               exports.txt && exit /b 1
findstr /C:"GetIsolationWindows"            exports.txt && exit /b 1
findstr /C:"DeconvolveMS2"                  exports.txt && exit /b 1
findstr /C:"ProcessMS2ForTagBasedTargeting" exports.txt && exit /b 1
findstr /C:"GetBestMS2Masses"               exports.txt && exit /b 1
findstr /C:"ClearMS2Deconvolution"          exports.txt && exit /b 1
findstr /C:"GetRepresentativeMass"          exports.txt && exit /b 1
findstr /C:"GetAllMonoisotopicMasses"       exports.txt && exit /b 1
findstr /C:"RemoveFromExclusionList"        exports.txt && exit /b 1
findstr /C:"AddToInclusionList"             exports.txt && exit /b 1
findstr /C:"GetMS1ScanResult"               exports.txt && exit /b 1
findstr /C:"ResetScanState"                 exports.txt && exit /b 1
findstr /C:"GetDeconvolutionQuality"        exports.txt && exit /b 1
```

---

### Step 11 — Run the full regression suite

The full regression suite is automated by **P8-R01** in the `windows-tests` CI job. Do not
proceed to committing until P8-R01 passes in CI for the current branch state.

**Debugging note (Phase 0 lesson #14):** The C++ bridge returns 0 results silently when
input data is malformed — there is no distinct error code for "bad input" vs "no results
found." If a regression config unexpectedly produces an empty output file, log the input
data characteristics (RT, peak count, first/last m/z) before investigating engine internals.

The authoritative orchestration for this step is `regression-runner.ps1`
(`FlashIDA/test-scripts/regression-runner.ps1`). Its full config array, correct golden file
names, and per-config spectrum file assignments are specified in
[../test-file-specification.md §4.2](../test-file-specification.md). The canonical config
array as of Phase 8 (all 13 entries) is reproduced there; use that as the single source of
truth when extending or verifying the script. Note in particular:

- `ms2_hcd_fragment.txt` (spec §1.3) is the required second spectrum argument for
  `method_tag_targeting.xml`, `method_quant.xml`, `method_ms3_mode1.xml`,
  `method_ms3_mode2.xml`, and `method_ms3_mode3.xml`.
- `ms1_faims_3cv.txt` (spec §1.4) is the required spectrum for `method_faims_3cv.xml` and
  `method_faims_skip.xml`.
- All other configs use `ms1_standard.txt` (spec §1.2).
- All spectrum files use **tab-separated** format with **RT in seconds** (Phase 0 lesson #2):
  `Spec scan=N\t<rt_seconds>`, followed by tab-separated `m/z\tintensity` data lines.
  Flash.exe's parser divides RT by 60 internally.

Golden file canonical names follow the `phase4_*` / `faims_*` / `phase7_*` convention
defined in spec §2.2. All 12 configurations must produce `PASS`. Any failure indicates a
regression introduced during cleanup.

For reference, the runner invokes `Flash.exe` and `compare_golden.py` in the pattern:

```powershell
# Reference — runs in CI as part of P8-R01 (windows-tests job, windows-latest)
# Canonical config array and golden file names: see test-file-specification.md §4.2
# Four-argument form used when ms2 is non-null (entry point is FLASHIdaWrapper.Main(), no -t flag):
& $FlashExe $ms1File $outputFile $methodFile [$ms2File]
python compare_golden.py "$TestDataDir\golden\$goldenFile" "$OutputDir\$name.tsv"
```

The `compare_golden.py` tolerance rules (absolute 1e-6 for |v| ≤ 1.0, relative 1e-4 for
|v| > 1.0; exact match for `charges` and `hcd`) are defined in
[../test-file-specification.md §4.1](../test-file-specification.md).

---

## Files to Create or Modify

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` | Modify | Remove 13 `extern "C" OPENMS_DLLAPI` declarations. Leave 5. |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Modify | Remove 13 function bodies. Leave 5. |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Remove declarations of private methods that are now orphaned (e.g., `getPeakGroupSize_`, `parseLegacy_`). |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Remove `parseLegacy_()` definition; remove the `else parseLegacy_(arg)` branch in the constructor; remove orphaned private method bodies. |
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | Remove 13 `[DllImport]` declarations. Leave exactly 5. |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Remove `ToFLASHDeconvInput()` method and any helpers that exist solely for it. |
| `FlashIDA/src/Flash/IDA/MethodDocGenerator.cs` | Create (new) | ~30-line reflection utility for `[Description]`-based documentation. |
| `.github/workflows/flashida-ci.yml` | Modify | Extend the `dumpbin` export verification step to also assert absence of the 13 removed symbols (see Step 10). |

No other files should require changes. If a file outside this list needs modification, that
indicates an unresolved call site from Step 1 that must be addressed first.

**`.gitattributes` note (Phase 0 lesson #4):** If any new binary file extensions are
introduced (e.g., `.enc`, `.zip`, `.gpg`), add corresponding `*.ext binary` entries to
`FlashIDA/.gitattributes` before committing. The existing `* text eol=crlf` rule will
silently corrupt binary files without these entries. Phase 8 does not introduce new binary
extensions, but this must be checked if the file list changes.

---

## Test Cases

All 7 tests added in this phase. They run as part of the full cumulative suite (96 tests
total including all prior phases).

**Tier convention (Phase 0 lesson #12):** Tests that load `OpenMS.dll` (via P/Invoke or
bridge calls) are Tier 2, not Tier 1. Pure C# tests without DLL dependencies are Tier 1.
If any test is added that exercises bridge functions, label it Tier 2.

**Multi-scan parser note (Phase 0 lesson #9):** Any new test code that loads spectrum TSV
files must stop at the first scan boundary (`if (started) break;` on encountering a second
`Spec` line). Failing to do so mixes peaks from multiple scans and silently produces wrong
results (see also silent zero-result failure mode, lesson #14).

### Test Summary (Quick Reference)

| Test | Summary |
|------|---------|
| P8-U01 | Counts `[DllImport]` declarations in `FLASHIdaWrapper.cs` and asserts exactly 5 remain. Ensures no legacy P/Invoke declaration was accidentally left behind after the 13 removals. |
| P8-U02 | Scans all C# source files for any reference to `ToFLASHDeconvInput` and asserts zero hits outside `Parameter.cs`. Confirms the legacy serialization method and all its call sites are fully gone. |
| P8-U03 | Calls `MethodDocGenerator.Generate(typeof(Parameter))` and verifies the returned string is non-empty and contains at least 3 known `[Description]`-annotated property names. Validates that the new reflection utility works correctly on real `Parameter` properties. |
| P8-U04 | Passes a non-JSON (legacy space-delimited) string to the `FLASHIda` C++ constructor and asserts that it throws `std::invalid_argument`. Confirms the `parseLegacy_` fallback was removed and invalid input is rejected rather than silently accepted. |
| P8-I01 | Runs `dumpbin /exports` on the built `OpenMS.dll` and asserts all 5 keeper functions are present and all 13 removed functions are absent. Verifies the compiled DLL export table matches the intended final bridge API exactly. |
| P8-I02 | Builds `Flash.sln` with `/warnaserror` and asserts the build exits with zero warnings. Confirms that removing dead declarations and methods left no dangling references or orphaned `using` directives. |
| P8-R01 | Runs `Flash.exe` against all 12 method configuration files and compares each output to the corresponding Phase 7 golden file. Verifies that the cleanup phase changed no observable behaviour across every supported acquisition mode. |

---

### P8-U01 — Exactly 5 P/Invoke declarations (Tier 1, C#, `windows-latest`)

**Description:** Count `[DllImport` attribute occurrences in `FLASHIdaWrapper.cs` via
reflection or text scan. Verify the count equals exactly 5.

**Implementation:** NUnit test in `Flash.Tests/CleanupTests.cs`. Read `FLASHIdaWrapper.cs`
as text and count lines matching `[DllImport`; or use reflection to count methods on
`FLASHIdaWrapper` decorated with `DllImportAttribute`.

**Expected outcome:** Count equals 5. Any count other than 5 fails the test.

**Rationale:** Enforces the invariant that the bridge API is permanently locked at 5
functions and no one accidentally re-adds a legacy declaration.

---

### P8-U02 — No reference to ToFLASHDeconvInput (Tier 1, C#, `windows-latest`)

**Description:** Verify that no file in `FlashIDA/src/` references `ToFLASHDeconvInput`.
The method definition itself is deleted; this test confirms no call sites were overlooked.

**Implementation:** NUnit test that searches the source tree for the string
`ToFLASHDeconvInput` and asserts zero hits, excluding any test file that contains the
assertion string itself.

Alternatively implemented as a PowerShell step in CI:

```yaml
- name: Verify ToFLASHDeconvInput removed
  shell: powershell
  run: |
    $hits = Select-String -Path "FlashIDA\src\**\*.cs" `
            -Pattern "ToFLASHDeconvInput" -Recurse |
            Where-Object { $_.Filename -notmatch "CleanupTests" }
    if ($hits) { Write-Host "FAIL: $hits"; exit 1 }
    Write-Host "PASS: ToFLASHDeconvInput not found"
```

**Expected outcome:** Zero matches. Any hit is a test failure.

---

### P8-U03 — MethodDocGenerator produces correct output (Tier 1, C#, `windows-latest`)

**Description:** Instantiate `MethodDocGenerator`, call `Generate(typeof(Parameter))`,
verify the returned string is non-empty and contains at least 3 known field names that have
`[Description]` attributes in `Parameter.cs`.

**Implementation:** NUnit test in `Flash.Tests/CleanupTests.cs`:

```csharp
[Test]
public void MethodDocGenerator_ProducesOutputForParameter()
{
    string output = MethodDocGenerator.Generate(typeof(Parameter));
    Assert.IsNotEmpty(output);
    // Verify known fields with [Description] attributes appear
    Assert.That(output, Does.Contain("ScoreThreshold"));
    Assert.That(output, Does.Contain("MaxMassCount"));
    Assert.That(output, Does.Contain("HCDEnergy"));
}
```

The exact field names used in the assertion must match property names in `Parameter.cs` that
have `[Description]` attributes. Adjust to match what was added in Phase 1.

**Expected outcome:** `output` is non-empty; all three field name assertions pass.

---

### P8-U04 — Legacy config parsing removed (Tier 1, C++, `ubuntu-latest`)

**Description:** Attempt to create a `FLASHIda` instance by passing a non-JSON string
(e.g., the old space-delimited format). Verify that the call fails rather than silently
accepting the input via the now-deleted legacy path.

**Implementation:** C++ test via the OpenMS ClassTest framework:

```cpp
// In FLASHIda_test.cpp or a new file Phase8_test.cpp
START_SECTION(legacy_config_rejected)
{
    // The legacy format started with a number or keyword, never '{'
    const char* legacy_input = "10 100 1 10 5 0.5 -1";
    FLASHIda* obj = nullptr;
    bool threw = false;
    try {
        obj = new FLASHIda(legacy_input);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    TEST_EQUAL(threw, true)
    TEST_EQUAL(obj, nullptr)
}
END_SECTION
```

If the constructor logs and returns a partially-initialized object rather than throwing,
adjust the test to call a method that reflects the invalid state (e.g., `ProcessScan`
returning -1 immediately).

**Expected outcome:** Constructor throws `std::invalid_argument` (or equivalent failure
mode). The legacy input is not silently accepted.

**Runner:** `ubuntu-latest` via CTest. No Thermo DLL dependency.

---

### P8-I01 — DLL exports: exactly 5 bridge functions (Tier 2, `windows-latest`)

**Description:** Run `dumpbin /exports` on the built `OpenMS.dll`. Verify that all 5 keeper
functions are present and all 13 removed functions are absent.

**Implementation:** Bridge verification step in `windows-tests` job of `flashida-ci.yml` (see Step 10 for
the full cmd script). This test replaces and extends the Phase 3 DLL export check (P3-I05).

**Expected outcome:** All 5 presence checks pass (`findstr` finds each name). All 13 absence
checks pass (`findstr` returns non-zero for each removed name). Any deviation from this exact
set is a build failure.

**Runner:** `windows-latest`. Requires `dumpbin.exe` from VS Build Tools (already required by
Phase 3 P3-I05; no new dependency).

---

### P8-I02 — C# compiles with zero warnings (Tier 2, `windows-latest`)

**Description:** Build `Flash.sln` with `/warnaserror` (treat all warnings as errors). The
build must succeed, demonstrating that removing dead code and dead declarations left no
dangling references that the compiler silently accepted with a warning.

**Implementation:** CI step in the `windows-tests` job:

```yaml
- name: Build with warnings-as-errors
  run: |
    msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror
```

This is a separate build step from the normal debug build. If the normal build already uses
`/warnaserror`, this test is redundant and can be merged.

**Expected outcome:** MSBuild exits 0. No warnings are emitted. If any warnings remain,
they must be resolved before this phase is considered done.

**Runner:** `windows-latest`. Requires Thermo iAPI DLLs (decrypted via Strategy B /
openssl from `FlashIDA/dependencies/thermo-dlls.zip.enc`, same as all C# build steps).

---

### P8-R01 — Full regression: every mode config against Phase 7 golden files (Tier 3, `windows-latest`)

**Description:** Run `Flash.exe` with every method configuration file and compare each
output to the corresponding Phase 7 golden file using `compare_golden.py`. This is the
comprehensive validation that cleanup removed only dead code and changed no behavior.

**Configurations covered (minimum 12):**

Canonical golden file names are defined in [../test-file-specification.md §2.2](../test-file-specification.md).
Spectrum file assignments per config are defined in spec §1.2–§1.4 and §4.2.

| Config file | Spectrum file(s) | Golden file (canonical name from spec §2.2) |
|-------------|-----------------|---------------------------------------------|
| `method_default.xml` | `ms1_standard.txt` | `phase4_standard_dda.tsv` |
| `method_deep.xml` | `ms1_standard.txt` | `phase4_deep_mode.tsv` |
| `method_inclusion.xml` | `ms1_standard.txt` | `phase4_inclusion.tsv` |
| `method_exclusion.xml` | `ms1_standard.txt` | `phase4_exclusion.tsv` |
| `method_tag_targeting.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_tag_targeting.tsv` |
| `method_quant.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_quant.tsv` |
| `method_ms3_mode1.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode1.tsv` |
| `method_ms3_mode2.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode2.tsv` |
| `method_ms3_mode3.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode3.tsv` |
| `method_faims_3cv.xml` | `ms1_faims_3cv.txt` | `faims_3cv.tsv` |
| `method_faims_skip.xml` | `ms1_faims_3cv.txt` | `faims_skip.tsv` |
| `method_exploration.xml` | `ms1_standard.txt` | `phase7_exploration.tsv` |

**Implementation:** The `regression-runner.ps1` script (Section 6.1 of `testing-strategy.md`;
canonical config array in [../test-file-specification.md §4.2](../test-file-specification.md))
covers all 12 configs. Each invocation uses `compare_golden.py` for numeric comparison with
tolerances defined in [../test-file-specification.md §4.1](../test-file-specification.md)
(absolute 1e-6 for |v| ≤ 1.0, relative 1e-4 for |v| > 1.0; exact match for `charges` and `hcd`).
The golden TSV column schema (15 columns) is specified in spec §2.1.

**Expected outcome:** All 12 configs produce `PASS`. Any single failure is a regression.
Golden files are the Phase 7 outputs; they are not updated in this phase unless a deliberate
behavioral change was made (none is expected in a cleanup phase). If golden files do need
updating, remember that golden-file capture requires a 2-commit minimum: the first commit
runs CI and produces the golden artifact, the second commit includes the captured golden
file (Phase 0 lesson #15).

**Runner:** `windows-latest`. Requires OpenMS DLLs (committed in `FlashIDA/dll/`, no
download needed — Phase 0 lesson #5) and Thermo iAPI DLLs (decrypted via Strategy B /
openssl — Phase 0 lesson #3).

**Timing note:** 12 `Flash.exe` invocations may approach the 20-min Tier 3 budget.
If timing is tight, parallelize by splitting configs across two PowerShell jobs that run
concurrently, or run the 4 fastest configs sequentially and batch the rest.

---

## CI Configuration Changes

These changes to `.github/workflows/flashida-ci.yml` are required for Phase 8:

### 1. Extend DLL export verification in the bridge verification step in `windows-tests`

Replace the Phase 3 verification step (P3-I05: "exports include new functions") with the
Phase 8 step (P8-I01: "exactly 5 exports, 13 absent"). The new step both asserts presence
of the 5 keepers and asserts absence of the 13 removed functions. See Step 10 for the
complete `cmd` script.

### 2. Add zero-warnings build step to the `windows-tests` job

Add a dedicated MSBuild invocation with `/warnaserror` for P8-I02. Place it after the
normal build succeeds, so the normal build output (artifacts, test DLLs) is available for
subsequent test steps regardless of warning status.

### 3. Add CleanupTests.cs to the NUnit test run

The new test class `CleanupTests.cs` (containing P8-U01, P8-U02, P8-U03) is automatically
picked up by the NUnit console runner if it is included in `Flash.Tests.csproj`.
Invoke the runner by its full NuGet packages path and set the working directory to
`FlashIDA/bin/` so native DLLs (OpenMS.dll and dependencies) are found by the .NET
runtime's DLL search path (Phase 0 lesson #12):

```powershell
& "packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe" Flash.Tests.dll --work=FlashIDA\bin
```

Verify that `Flash.Tests.csproj` includes the new file (or uses a wildcard glob that picks
it up).

### 4. Add Phase 8 C++ test to the `cpp-unit-tests` job

The test for P8-U04 (legacy config rejection) runs on `ubuntu-latest`. It must be registered
in `OpenMS/src/tests/class_tests/openms/executables.cmake`. Add an entry for the test binary
alongside the other FLASH test entries that were uncommented in Phase 2. The `ctest -R FLASH`
invocation in the `cpp-unit-tests` job will pick it up automatically.

### 5. Regression suite covers all 12+ configs

The regression runner script must include all 12 method configs listed in P8-R01. If the
script was built incrementally (each phase adds its new configs), confirm the Phase 8 version
runs all prior configs plus any new ones. The canonical full config array (names, spectrum
file assignments, golden file names) is defined in
[../test-file-specification.md §4.2](../test-file-specification.md). No new method configs
are added in Phase 8 itself.

### Workflow trigger branches

No changes to trigger branches are needed. Phase 8 commits go to `flashida-v9-migration`,
which is already in the trigger list.

### Commit strategy — submodule batching (Phase 0 lesson #15)

Phase 8 touches both C++ (Steps 2-5) and C# (Steps 6-8) code. Batch all C++ changes
into a single OpenMS submodule commit before updating the submodule pointer, then batch
all C# changes together. This minimizes submodule pointer update churn.

---

## Working Product Verification

The following checks verify the working product after Phase 8 is complete. All are automated
by the test suite; this section maps each check to its test.

| Verification | Test | CI verification method |
|-------------|------|------------------------|
| `Flash.exe` runs in final form | P8-R01 | `windows-tests` job on `windows-latest`; check run logs and artifacts for `regression-runner` step |
| Exactly 5 DLL exports | P8-I01 | Bridge verification step in `windows-tests` on `windows-latest`; inspect the "Verify DLL exports" step output in CI run artifacts |
| Zero C# compile warnings | P8-I02 | `windows-tests` job on `windows-latest`; "Build with warnings-as-errors" step must exit 0 |
| MethodDocGenerator produces output | P8-U03 | Automated by P8-U03 NUnit test that asserts the generator returns a non-empty string; see `windows-tests` job NUnit results |
| No legacy P/Invoke declarations | P8-U01 | `windows-tests` job NUnit results for `CleanupTests.P8_U01` |
| ToFLASHDeconvInput absent | P8-U02 | `windows-tests` job NUnit results for `CleanupTests.P8_U02` |
| Legacy config rejected by C++ | P8-U04 | `cpp-unit-tests` job on `ubuntu-latest`; `ctest -R FLASH` output |
| Full regression passes | P8-R01 | Automated by P8-R01 in the `windows-tests` CI job. All 12 regression configs pass in CI. |

---

## Definition of Done

Phase 8 is complete when all of the following are true:

- [ ] Step 1 pre-condition check passes: zero live callers of any of the 13 removed functions
      and zero callers of `ToFLASHDeconvInput` outside of `Parameter.cs` itself.

- [ ] `FLASHIdaBridgeFunctions.h` contains exactly 5 `extern "C" OPENMS_DLLAPI` declarations.

- [ ] `FLASHIdaBridgeFunctions.cpp` contains exactly 5 function definitions; no removed
      function names appear anywhere in the file.

- [ ] `FLASHIda.cpp` contains no `parseLegacy_()` definition and no `else parseLegacy_(arg)`
      branch in the constructor. The constructor rejects non-JSON input.

- [ ] `FLASHIda.h` contains no declaration for `parseLegacy_()` or any other private method
      deleted in Step 4.

- [ ] `FLASHIdaWrapper.cs` contains exactly 5 `[DllImport(dllName)]` lines (verified by
      P8-U01).

- [ ] `Parameter.cs` contains no `ToFLASHDeconvInput()` method and no helpers that existed
      solely for it (verified by P8-U02).

- [ ] `MethodDocGenerator.cs` exists, compiles, and produces non-empty output from
      `[Description]` attributes on `Parameter` (verified by P8-U03).

- [ ] C++ build succeeds with zero errors and zero warnings.

- [ ] `msbuild Flash.sln /warnaserror` succeeds with zero warnings (verified by P8-I02).

- [ ] `dumpbin /exports OpenMS.dll` shows exactly 5 bridge symbols; all 13 removed symbols
      are absent (verified by P8-I01).

- [ ] P8-U04 passes: C++ unit test confirms non-JSON input is rejected.

- [ ] P8-R01 passes: all 12+ method configuration variants produce output matching Phase 7
      golden files.

- [ ] All prior tests P0 through P7 (89 tests) continue to pass. No regressions introduced.

- [ ] The `flashida-ci.yml` CI workflow changes (DLL export verification extension, zero-
      warnings build step, Phase 8 C++ test registration) are committed and passing in CI.

- [ ] Phase 8 changes are merged to `flashida-v9-migration` and Build #4 artifact (Phase 7 +
      Phase 8) is tagged and recorded.

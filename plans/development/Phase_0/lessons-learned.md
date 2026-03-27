# Phase 0 — Lessons Learned

**Date:** 2026-03-23
**CI runs to green:** 7 (4 fixes required after initial push)

---

## 1. Flash.exe Entry Point — No `-t` Flag

**Issue:** The implementation plan and CLAUDE.md describe `Flash.exe -t` for test mode. In reality, `Flash.csproj` sets `<StartupObject>Flash.IDA.FLASHIdaWrapper</StartupObject>`, so `FLASHIdaWrapper.Main()` is the entry point — not `Flash.Main()`. The Mono.Options parsing in `Flash.cs` (which handles `-t`) is never reached.

**Correct invocation:**
```
Flash.exe <input_file> <output_file> <method.xml> [ms2_file]
```

**Impact:** SmokeTests.cs, regression-runner.ps1, and the CI golden-capture step all needed the `-t` flag removed.

**Action for future phases:** Update CLAUDE.md and the implementation plans to document the actual entry point. If `Flash.Main()` is ever restored as the entry point, the `-t` flag invocations will need to be reinstated.

---

## 2. Spectrum File Format — Tab-Separated Header with RT in Seconds

**Issue:** The test-file-specification.md §1 defines the header format as:
```
Spec <native_id> rt=<rt_minutes>
```
(space-separated, RT in minutes with `rt=` prefix)

Flash.exe's parser (`FLASHIdaWrapper.cs:924,1090`) does:
```csharp
var token = line.Split('\t');
rt = double.Parse(token[1]) / 60.0;
```

This requires **tab separation** and a **bare numeric RT in seconds** (no `rt=` prefix):
```
Spec scan=N\t<rt_seconds>
```

**Impact:** `prepare-test-data.py` outputs the tab-separated format with RT in seconds (directly from pyopenms `getRT()`, no conversion). This deviates from the test-file-specification format.

**Action for future phases:** Either update the test-file-specification to match the actual parser, or update Flash.exe's parser to accept the spec format (in a phase that allows behavioral changes). For Phase 0, matching the existing parser is mandatory.

---

## 3. Thermo DLL Secret — Strategy B Required

**Issue:** The 5 Thermo DLLs compress to a 75 KB zip. Base64 encoding produces 101 KB, exceeding GitHub's 48 KB per-secret limit. Strategy A (base64 secret) was the plan's default.

**Resolution:** Switched to Strategy B — openssl-encrypted zip committed to the repo (`FlashIDA/dependencies/thermo-dlls.zip.enc`), with the passphrase stored as `THERMO_DLL_PASSPHRASE` secret.

**Additional issue:** GPG encryption (first attempt) failed on the Windows CI runner due to digest algorithm incompatibility (`unknown digest algorithm 13` — SHA-512/256 not supported). Switched to `openssl enc -aes-256-cbc -pbkdf2` which is portable across all platforms.

**Action for future phases:** Always use openssl for CI secret encryption. Document the passphrase securely.

---

## 4. Binary File Corruption via `.gitattributes`

**Issue:** `FlashIDA/.gitattributes` has `* text eol=crlf`, which forces CRLF conversion on ALL files. The encrypted archive (`.enc`) was silently corrupted during git add/checkout, causing `bad decrypt` / `wrong final block length` errors on CI.

**Resolution:** Added `*.enc binary`, `*.gpg binary`, `*.zip binary` to `.gitattributes`.

**Action for future phases:** Any new binary file extensions must be added to `.gitattributes` before committing.

---

## 5. OpenMS DLLs — Already Committed, No Download Needed

**Issue:** The CI workflow included cache + cross-workflow artifact download steps for OpenMS DLLs (`dawidd6/action-download-artifact@v3` from `build_dlls.yml`). This failed because (a) the workflow doesn't exist, and (b) the DLLs are already committed in `FlashIDA/dll/`.

**Resolution:** Removed all OpenMS DLL cache/download steps. MSBuild copies the committed DLLs to the build output via `CopyToOutputDirectory` in `Flash.csproj`.

**Action for future phases:** If the OpenMS submodule is updated and DLLs need to be rebuilt, a `build_dlls.yml` workflow and the cache/download steps should be reintroduced at that time.

---

## 6. Spectrum Data Selection — Elution Region Required

**Issue:** The mzML file (`GOOD_MS3__cyt_20260106121704.mzML`) contains 819 MS1 scans. Most have only 21 peaks (preview/calibration scans with fragment-range m/z). Only ~150 scans have 800+ peaks with protein charge envelopes. FLASHDeconv confirmed: scan 352 (1177 peaks, RT=55s) produced only 9 low-quality results that Flash.exe's bridge filtered out, yielding 0 output rows.

**Resolution:** Used scan 421 (6588 peaks, RT=70.58s) — the richest MS1 scan in the main elution region. FLASHDeconv found 68 deconvolved masses for this scan. Flash.exe produces 1 output row (cytochrome c at 12,351 Da, charge 14, qScore 0.968).

**Deviation from spec:** The test-file-specification says ms1_smoke_test.txt should have 10–200 peaks. The actual file has 6588+21 peaks across 2 scans. This was unavoidable — no scan in the 10–200 peak range contains protein charge envelopes detectable by the engine.

---

## 7. Last-Scan-Not-Processed Parser Behavior

**Issue:** Flash.exe's parser only processes a scan's accumulated data when the NEXT `Spec` header line is encountered. The last scan in the file is never processed (no trigger). A single-scan file produces zero data rows.

**Resolution:** Extract 2 MS1 scans. The first scan's data is processed when the second scan's header is read. The second scan's data is discarded (never processed).

**Deviation from spec:** The test-file-specification §1.1 says ms1_smoke_test.txt should be "single-scan." It must be multi-scan (at least 2) for the current parser.

---

## 8. Input Format Deviation Kept for Backwards Compatibility

**Issue:** The test-file-specification defines the spectrum header format as space-separated with RT in minutes (`Spec scan=N rt=R.RRRR`). The actual Flash.exe parser requires tab-separated headers with RT in seconds (`Spec scan=N\t<seconds>`), dividing by 60 internally.

**Decision:** The tab+seconds format is kept intentionally. Changing the parser would alter behavior of the production entry points that share this parsing code, and all existing test data and regression golden files use this format.

**Action for future phases:** If the parser is ever refactored, update test-file-specification.md to match. Do not change the input format to match the spec — the spec should be updated instead.

---

## 9. Multi-Scan Spectrum Files — Parsers Must Stop at First Scan Boundary

**Issue:** `ms1_smoke_test.txt` contains 2 scans (see lesson 7). Three independent `LoadSpectrum`/`FromTsv` parsers (`BridgeMS2Tests`, `MockMsScan.FromTsv`, `DiagnosticTests`) all read past the first `Spec` header, overwriting RT with scan 2's value and mixing peaks from both scans. The C++ engine received wrong RT (1.191 vs 1.176 minutes) and ~6609 mixed peaks instead of ~6588 single-scan peaks, causing `GetPeakGroupSize` to return 0.

This produced a baffling failure mode: `CreateFLASHIda` succeeded, the config string was identical to Flash.exe's, but deconvolution silently returned 0 results. The root cause was only found by adding a diagnostic test that logged the actual RT and peak count values reaching the engine.

**Resolution:** Added `if (started) break;` when encountering a second `Spec` line in all three parsers.

**Action for future phases:**
- Any new code that loads spectrum TSV files must handle multi-scan files (stop at the first scan boundary, or explicitly select a scan by index).
- Flash.exe's `Main()` parser handles multi-scan correctly (processes scan N when scan N+1's header is encountered). Test parsers must match this behavior for single-scan loading.
- When deconvolution returns 0 results unexpectedly, verify the input data (RT, peak count, first/last m/z) before investigating engine internals.

---

## 10. NUnit Diagnostics — Console.WriteLine Appears in XML, TestContext.Error Does Not

**Issue:** When debugging test failures in CI, `TestContext.Error.WriteLine()` output did not appear in the NUnit XML results file. Only `Console.WriteLine()` output appeared (in the `<output>` element of each `<test-case>`).

**Action for future phases:** Use `Console.WriteLine()` for diagnostic output that must be visible in CI artifacts. Use `TestContext.Progress.WriteLine()` or `Console.WriteLine()` rather than `TestContext.Error.WriteLine()`.

---

## 11. NUnit OneTimeSetUp Failures Skip All Tests in the Fixture

**Issue:** A diagnostic test added to `BridgeMS2Tests` never ran because the fixture's `[OneTimeSetUp]` failed (`Assume.That(ms1Size > 0)`), which marks ALL tests in the fixture as inconclusive with `site="Parent"` — including tests that don't depend on setup state.

**Action for future phases:** Diagnostic or independent tests must go in their own `[TestFixture]` class, not in a fixture with `[OneTimeSetUp]` that may fail.

---

## 12. Undocumented Deviations from Implementation Plan

**Issue:** Seven deviations from the Phase 0 implementation plan were discovered during the compliance audit but not documented in the original lessons-learned entries. These are all minor structural differences between the plan and the actual implementation.

**Deviations:**

1. **Build output path:** The actual build output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/` as described in the plan. This affects the .csproj configuration, CI workflow, test paths, and the regression runner.
2. **DLL name in P/Invoke:** The actual DLL import uses `"OpenMS.dll"` (with extension), not `"OpenMS"` as the plan describes.
3. **Extra .csproj references:** `Flash.Tests.csproj` requires references to Thermo DLLs, `Microsoft.CSharp`, and `log4net` that the plan does not mention. These were discovered during build troubleshooting.
4. **NUnit runner invocation:** CI invokes the NUnit console runner by full path (from NuGet packages directory) rather than assuming it is on PATH.
5. **Bridge verification filter:** CI uses `@classname` filter instead of `@categories` for NUnit bridge test selection.
6. **`compare_golden.py --help` check:** The plan's CI sanity check for compare_golden.py was removed; not needed since the script is only invoked by regression-runner.ps1.
7. **NUnit working directory:** NUnit must be run from `FlashIDA/bin/` so that native DLLs (OpenMS.dll and dependencies) are found by the .NET runtime's DLL search path. Relative paths in tests (e.g., `..\\test-data\\`) depend on this specific working directory.

**Action for future phases:** Read this list before writing CI workflow steps or .csproj modifications. The regression-runner.ps1 and CI workflow are the authoritative references for correct paths.

---

## 13. Stress Tests CT31/CT32 Deferred to Phase 3

**Issue:** The acquisition-loop-testing-strategy specifies CT31 (1000 scans sequential) and CT32 (concurrent processing) as "Introduced: Phase 0." Both are present as `[Ignore]`d stubs with `Assert.Inconclusive`.

**Rationale:** These stress tests require the concurrent pipeline infrastructure (DataPipe with real async timing) that the ContinuityTestHarness does not exercise. Phase 3 introduces the ScanCommand struct and refactors the pipeline, making it the natural place to implement meaningful stress tests.

**Action for future phases:** Implement CT31/CT32 in Phase 3 when the DataPipe is testable. Remove the `[Ignore]` attributes and replace the `Assert.Inconclusive` stubs with real test logic.

---

## 14. Silent Zero-Result P/Invoke Failures

**Issue:** The C++ deconvolution engine (via P/Invoke bridge) returns 0 results without an error code when the input data format is wrong. In Phase 0, this produced baffling failures where `CreateFLASHIda` succeeded, the config string was correct, but `GetPeakGroupSize` returned 0 — because the spectrum data (RT, peak count) was subtly wrong due to multi-scan parsing issues (see lesson #9).

**Action for future phases:** When deconvolution returns 0 results unexpectedly, log the input data characteristics (RT, peak count, first/last m/z, precursor mass/charge for MS2) before investigating engine internals. The bridge functions do not distinguish "no results found" from "input data is malformed."

---

## 15. CI and Workflow Patterns

**Issue:** Several patterns emerged during Phase 0 CI development that are not obvious from the implementation plan:

1. **Golden-file capture requires 2 commits minimum:** The first commit runs CI and produces the golden artifact; the second commit includes the captured golden file. Phases with multiple golden files should batch captures into a single CI run.
2. **Submodule update churn:** 48% of Phase 0 commits (13 of 27) were submodule pointer updates. Batch same-side changes (all C# changes or all C++ changes) before updating the submodule pointer to reduce churn.
3. **Thermo interface mocking iterations:** Mocking proprietary interfaces without public documentation required 9 iterative commits. Budget 2–3 extra CI round-trips per phase that touches Thermo interfaces.

**Action for future phases:** Plan for these CI patterns when estimating effort. Read `.github/workflows/flashida-ci.yml` (the `windows-tests` job) for the current CI structure before modifying it.

---

## Summary of Deviations from Plan

| Item | Plan Says | Actual | Reason |
|------|-----------|--------|--------|
| Flash.exe invocation | `Flash.exe -t <args>` | `Flash.exe <args>` | StartupObject is FLASHIdaWrapper, not Flash |
| Spectrum header format | `Spec scan=N rt=R.RRRR` (spaces, minutes) | `Spec scan=N\t<seconds>` (tab, seconds) | Flash.exe parser requires tab + numeric seconds |
| ms1_smoke_test.txt peaks | 10–200 peaks, single-scan | 6588+21 peaks, 2 scans | No small scan has charge envelopes; parser needs 2+ scans |
| Thermo DLL secret | Strategy A (base64) | Strategy B (openssl-encrypted zip) | Base64 exceeds 48 KB GitHub secret limit |
| OpenMS DLL download | Cache + cross-workflow download | Removed (DLLs in repo) | DLLs already committed in FlashIDA/dll/ |
| NuGet package name | `NUnitConsoleRunner` (plan §2.3) | `NUnit.ConsoleRunner` | Correct NuGet package ID |
| `MS3AllCharges` in config string | `0` (plan §Step 4) | `1` | method_default.xml has `<MS3AllCharges>true</MS3AllCharges>` |
| Test tier labels | AL-CT tests are "Tier 1" (acq-loop strategy §5) | `Tier2` | Tests load OpenMS.dll, matching existing Tier 2 convention for DLL-dependent tests |
| CT08 config | `method_default.xml` (MaxMs2CountPerMs1=1) | `method_default_topn5.xml` (MaxMs2CountPerMs1=5) | TopN=1 makes the assertion trivially true; TopN=5 is the non-trivial test |
| CT12 deep mode | No deep mode config, compared against self | `method_deep.xml` vs `method_default_topn5.xml` | Spec requires comparing deep vs standard DDA with same TopN |

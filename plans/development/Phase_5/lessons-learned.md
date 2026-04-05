# Phase 5 Lessons Learned

## Lesson 1: FAIMS Tests Must Use Acquisition Loop (Continuity Tests), Not Regression Runner

**Context:** When preparing Phase 5 FAIMS test infrastructure, the initial approach was to add FAIMS method configs (`method_faims_3cv.xml`, `method_faims_skip.xml`) to the regression runner (`regression-runner.ps1`) for golden file capture via `Flash.exe`.

**Problem:** `Flash.exe` test mode (`FLASHIdaWrapper.Main()`) bypasses the entire C# acquisition loop — it feeds scans directly to the C++ `ProcessScan` bridge in a single stream. The test-mode parser reads `Spec scan=N\t<rt>` headers but ignores the `cv=` field entirely. There is no `ScanScheduler`, no `FAIMSScanProcessor`, no per-CV routing. Both `method_faims_3cv.xml` (MaxCVSkip=0) and `method_faims_skip.xml` (MaxCVSkip=2) produce identical deconvolution output because the FAIMS scheduling parameters are C#-only and never reach the C++ engine in test mode.

**Correct approach:** FAIMS behavior is only testable through the **acquisition loop continuity tests** (AL-CT09, CT10, CT11, CT27, CT28) which use the `ContinuityTestHarness`. The harness creates a real `FAIMSScanProcessor` + `ScanScheduler` pipeline with mock instrument interfaces, exercises per-CV routing, and captures `ScanCommandRecord` output. This is where FAIMS CV cycling, adaptive skipping, and CV-stamped MS2 commands are verified.

**Rule:** Never add FAIMS configs to the regression runner. FAIMS coverage belongs exclusively in the continuity test suite.

# Phase 5 Lessons Learned

## Lesson 1: FAIMS Tests Must Use Acquisition Loop (Continuity Tests), Not Regression Runner

**Context:** When preparing Phase 5 FAIMS test infrastructure, the initial approach was to add FAIMS method configs (`method_faims_3cv.xml`, `method_faims_skip.xml`) to the regression runner (`regression-runner.ps1`) for golden file capture via `Flash.exe`.

**Problem:** `Flash.exe` test mode (`FLASHIdaWrapper.Main()`) bypasses the entire C# acquisition loop — it feeds scans directly to the C++ `ProcessScan` bridge in a single stream. The test-mode parser reads `Spec scan=N\t<rt>` headers but ignores the `cv=` field entirely. There is no `ScanScheduler`, no `FAIMSScanProcessor`, no per-CV routing. Both `method_faims_3cv.xml` (MaxCVSkip=0) and `method_faims_skip.xml` (MaxCVSkip=2) produce identical deconvolution output because the FAIMS scheduling parameters are C#-only and never reach the C++ engine in test mode.

**Correct approach:** FAIMS behavior is only testable through the **acquisition loop continuity tests** (AL-CT09, CT10, CT11, CT27, CT28) which use the `ContinuityTestHarness`. The harness creates a real `FAIMSScanProcessor` + `ScanScheduler` pipeline with mock instrument interfaces, exercises per-CV routing, and captures `ScanCommandRecord` output. This is where FAIMS CV cycling, adaptive skipping, and CV-stamped MS2 commands are verified.

**Rule:** Never add FAIMS configs to the regression runner. FAIMS coverage belongs exclusively in the continuity test suite.

## Lesson 2: "Per-CV Wrapper" Limitation Was a Myth — Single Wrapper Architecture

**Context:** CT27/CT28 were `[Ignore]`d since Phase 4 with the comment "per-CV wrapper architecture prevents proper queue draining." CT09/CT10 had similar comments and used conditional assertions (`if (results.Count > 0)`).

**Problem:** Investigation of `FAIMSScanProcessor.cs` revealed there are no per-CV `FLASHIdaWrapper` instances. There is a single shared wrapper. FAIMS CV cycling is handled entirely at the C# `ScanScheduler` level. The harness's `PushScan` method (else branch, line 237) calls `Processor.ProcessMS()` → drains `GetNextScanCommand` from the same single wrapper. The supposed limitation did not exist.

**Root cause of low/zero results:** The old tests pushed only 9-15 scans with identical peaks across all CVs. The C++ deconvolution engine needs many scans to accumulate state before producing results — especially when split across 5 CVs with adaptive skip active.

**Fix:** Use real per-CV spectral data from `ms1_faims_3cv.txt` (300 scans, 5 CVs). Push all 300 scans for adaptive skip tests (CT27/CT28). 50 scans is sufficient for non-skip tests (CT09/CT10).

**Rule:** Don't accept architectural limitation claims at face value — read the actual code. Test infrastructure problems are often just insufficient test data.

## Lesson 3: Capture Golden Files Before Architecture Transitions (TDD)

**Context:** CT28 was deferred to Phase 6 with the rationale that it "depends on CT27 FAIMS adaptive skip fix." The plan assumed golden files would be captured after the C++ FAIMS state machine was implemented.

**Problem:** This defeats the purpose of golden file regression testing. The golden file should capture the **current working behavior** before a transition, so the new implementation can be verified against it. Capturing after the transition provides no regression baseline.

**Correct approach:** Un-ignore CT28 in Phase 5, capture the golden file via the legacy bridge path (the working implementation), commit it. Phase 6 must then match this baseline after moving FAIMS to C++.

**Rule:** Golden files are captured BEFORE transitions, not after. If the feature works today, lock in the behavior now.

## Lesson 4: FAIMS Adaptive Skip Needs 300 Scans, Not 50

**Context:** CT27 initially pushed 50 scans from `ms1_faims_3cv.txt`. With 5 CVs, that's ~10 scans per CV.

**Problem:** CI showed CT27 failing — only 1 distinct CV (-30) in results. With adaptive skip active (MaxCVSkip=2), the scheduler skips low-precursor CVs aggressively. 10 scans per CV is not enough for the engine to accumulate state and produce results across multiple CVs.

**Fix:** Push all 300 scans (~60 per CV). CT27 then produced results from 3+ distinct CVs.

**Rule:** Adaptive skip tests need significantly more data than non-skip FAIMS tests because the scheduler actively reduces how many scans each CV receives.

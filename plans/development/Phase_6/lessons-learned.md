# Phase 6: FAIMS Absorption — Lessons Learned

**Date:** 2026-04-07
**Scope:** Implementation of FAIMS CV cycling state machine in C++, deletion of ScanScheduler and FAIMSScanProcessor from C#.

---

## 1. Plan vs. Reality: Per-CV State Machine

**What happened:** The Phase 6 implementation plan described a simplified FAIMS state machine with a single global `cv_skip_count_` and `precursor_count_for_cv_`. The actual C# code (`ScanScheduler.cs`) uses **per-CV** arrays: `CVSkipAmount[]` (skip spacing that doubles on low precursor count, caps at MaxCVSkip) and `CVSkipCount[]` (counter that tracks how many cycles have been skipped). These are fundamentally different behaviors — the plan's model would have produced incorrect CV cycling.

**Lesson:** When porting stateful logic from one language to another, always audit the source implementation line-by-line before designing the target. Simplified pseudocode in a plan document can mask critical per-element state that changes algorithmic behavior. The audit step (Step 1) was the most valuable step in the entire phase.

---

## 2. getNextScanCommand Must Return 0 on Empty Queue

**What happened:** The plan specified changing `getNextScanCommand()` to return an MS1 fallback (return 1) when the queue is empty, replacing the C# `ScanScheduler.getNextScan()` fallback. This caused **all 41 continuity tests + 2 smoke tests to hang** because the C# `ProcessSpectrum` while-loop (`while (GetNextScanCommand == 1)`) entered an infinite loop — it never got the 0 return value it needs to stop draining.

**Fix:** Reverted to returning 0 on empty queue. The FAIMS CV-transition MS1 is pushed into the queue by `processScan()` at priority 0, so it gets dequeued normally in the priority loop. The C# startup "magic scan" is built directly via `ScanFactory` instead of via `GetNextScanCommand`.

**Lesson:** When changing the return semantics of a function used as a loop termination condition, trace all callers before changing. The `while (result == 1)` pattern is a producer-consumer contract — the consumer depends on 0 to stop. This is the kind of bug that doesn't show up in unit tests (which call the function a fixed number of times) but breaks every integration test.

---

## 3. CV Stamping: Build Time, Not Dequeue Time

**What happened:** The original plan specified that `injectCVIntoCommand_()` should stamp `faims_cv` on every command at dequeue time in `getNextScanCommand()`. This would have re-stamped MS2 commands with the current cycling CV, overwriting the parent MS1's CV. This is scientifically incorrect — MS2 fragmentation must happen at the same FAIMS CV where the precursor was detected, or the precursor ion won't pass through the FAIMS device.

**Fix:** MS2 commands get `faims_cv` set at build time (in `buildMS2Command_` / the processScan loop) from the parent MS1's CV. Only on-the-fly MS1 commands (AGC, cycle-time) get the current cycling CV at creation. No `injectCVIntoCommand_` helper — direct assignment at each creation point, matching the C# pattern of pre-built per-CV scans.

**Lesson:** When designing CV/voltage stamping for mass spec scans, remember that MS2 scans are physically dependent on their parent MS1's instrument state. Re-stamping at dequeue time breaks the parent-child CV relationship. The C# code made this obvious by setting `FAIMS_CV = cv` from the scan header at MS2 creation — the C++ design should have mirrored this from the start.

---

## 4. Two-Function Split: updateCV vs. getFAIMSMS1Scan

**What happened:** The C# ScanScheduler separates skip policy updates (`updateCV`) from CV cycling (`getFAIMSMS1Scan`). The plan initially proposed merging these into a single `updateCV_()` with a `cv_transition_pending_` flag. The actual implementation preserved the two-function split (`updateCVSkip_` and `advanceToNextCV_`) because they serve genuinely different purposes and are called at different points in the flow.

**Lesson:** When porting logic, preserve the source code's function boundaries unless there's a clear reason to merge. The two-function split made the behavioral audit straightforward — each function could be verified against its C# counterpart independently.

---

## 5. MassThreshold Not in JSON Config

**What happened:** The C# `IDA.MassThreshold` (default 15) — the precursor count threshold for adaptive skip decisions — was not being serialized in `Parameter.ToJSON()`. Only `cv_values` and `max_cv_skip` were sent to C++. The C++ parser had no `cv_precursor_threshold` field. This would have caused the C++ state machine to use a hardcoded default with no way for the user to configure it.

**Lesson:** When porting config-driven behavior, trace every config value from XML → MethodParameters → JSON → C++ to verify the full pipeline. The `MassThreshold` was in `DeveloperFAIMSConfig` (MethodConfig.cs) and `IDA.MassThreshold` (Parameter.cs) but never reached the JSON. A simple grep for the field name across both codebases would have caught this.

---

## 6. ScanCommandRecord.FromScanCommand Missing FaimsCV

**What happened:** The `ScanCommandRecord.FromScanCommand()` method (used by continuity tests to capture raw struct data) did not populate the `FaimsCV` property from the `ScanCommand.FaimsCv` field. It was only populated in `FromCustomScan()` by reading `IFusionCustomScan.Values["FAIMS CV"]`. After Phase 6, the `FromScanCommand` path is the primary capture path, so this gap would have caused all FAIMS CV assertions in continuity tests to see 0.0.

**Lesson:** When adding a new field to a P/Invoke struct, search for all serialization/deserialization paths — not just the struct definition. The `FromScanCommand` → `FromCustomScan` duality is a common pattern where one path gets updated and the other is forgotten.

---

## 7. Golden File Changes Are Expected on Bridge Migration

**What happened:** CT28's golden file `continuity_faims_skip.json` was captured via the legacy bridge (FAIMSScanProcessor → GetIsolationWindows). After migrating to the unified bridge (UnifiedScanProcessor → ProcessScan → GetNextScanCommand), the output changed in two ways: (1) ScanDescription fields populated with tracking IDs instead of empty strings, (2) 8 records instead of 6 because the C++ engine accumulates more state across CV cycles than the per-call legacy bridge.

**Lesson:** Bridge migrations always change golden files. The ScanDescription change is a format difference (tracking IDs vs empty). The record count change is a behavioral difference — the unified bridge's state accumulation produces more precursors across CV cycles. Both are correct; the golden file just needs re-capture. Always diff and categorize changes before accepting.

---

## 8. ScanScheduler.cs Path Is Not in IDA/ Subdirectory

**What happened:** The implementation plan referenced `Flash/IDA/ScanScheduler.cs` in several places. The actual file is at `Flash/ScanScheduler.cs` (not in the IDA subdirectory). The `Flash.csproj` entry is `<Compile Include="ScanScheduler.cs" />`, not `<Compile Include="IDA\ScanScheduler.cs" />`. This caused initial confusion when locating the file for the audit.

**Lesson:** Always verify file paths via `Glob` or `grep` before referencing them in plans. The IDA subdirectory contains `FAIMSScanProcessor.cs`, `FLASHIdaWrapper.cs`, `UnifiedScanProcessor.cs`, and `Parameter.cs` — but `ScanScheduler.cs` is at the Flash project root alongside `Flash.cs`, `DataPipe.cs`, and `ScanFactory.cs`.

---

## 9. Increment-First CV Cycling Means Index 0 Is Skipped Initially

**What happened:** The C# `getFAIMSMS1Scan()` does `currentCV++` before checking — so with `currentCV = 0` at init, the first call advances to index 1. The first CV-transition MS1 is for the second configured CV, not the first. The instrument starts at the first CV implicitly (the first MS1 scan from the instrument has that CV). This increment-first behavior must be preserved exactly in C++.

**Lesson:** Off-by-one in CV cycling would produce a different CV order, invalidating all FAIMS experiments. When porting cycling logic, verify: (a) initial index value, (b) increment-before-use vs use-before-increment, (c) wrap-around boundary.

---

## Summary of Plan Deviations

| # | Plan Specification | Actual Implementation | Impact |
|---|---|---|---|
| 1 | Single global `cv_skip_count_` | Per-CV `cv_skip_amount_[]` + `cv_skip_count_[]` | Would have produced wrong skip behavior |
| 2 | `getNextScanCommand` returns MS1 fallback on empty | Returns 0 (unchanged); CV-transition MS1 pushed by processScan | Would have caused infinite loop in all tests |
| 3 | `injectCVIntoCommand_` at dequeue time | Direct `faims_cv` assignment at build time | Would have broken MS2 parent CV relationship |
| 4 | `cv_transition_pending_` flag | CV-transition MS1 pushed to priority-0 queue | Simpler, no flag state to manage |
| 5 | No ProcessScan signature change mentioned | Added `double faims_cv` parameter to bridge | Required for C++ to know which CV produced each scan |
| 6 | `cv_precursor_threshold` not in JSON | Added to JsonFaimsConfig + Parameter.ToJSON | Would have used hardcoded default only |
| 7 | ScanCommandRecord.FromScanCommand unchanged | Added `record.FaimsCV = cmd.FaimsCv` | Would have lost CV data in test captures |
| 8 | `ScanScheduler.cs` at `Flash/IDA/` | Actual path is `Flash/ScanScheduler.cs` | Confusion during audit |
| 9 | ScanCommand 1248 bytes (correct) | Confirmed: pad2 (4) + faims_cv (8) = +8 | No deviation |
| 10 | DeadCodeTests.cs (P6-U07/U08) | Removed from scope per user direction | Manual grep verification instead |

---

## Post-Implementation: Compliance Audit Lessons

The following lessons were discovered during a 7-agent compliance audit run after Phase 6 implementation was complete.

---

## 10. New C++ Test Binaries Must Be Added to CI Workflow

**What happened:** `FLASHIdaFAIMS_test` was registered in `executables.cmake` (line 452) during Phase 6 but never added to the CI workflow's build target list or CTest filter in `flashida-ci.yml`. The parent repo CI selectively builds and runs only named test targets — it does not discover new tests automatically. The FAIMS tests never ran in CI.

**Fix:** Added `FLASHIdaFAIMS_test` to both the `cmake --build --target` list (line 58) and the `ctest -R` regex (line 63) in `flashida-ci.yml`.

**Lesson:** When adding a new C++ test file and registering it in `executables.cmake`, also update `flashida-ci.yml` in the same commit. The CI uses an explicit allowlist, not test discovery. A test that only exists in `executables.cmake` will never run.

---

## 11. C++ Tests Are Not Validated by the DLL Build Workflow

**What happened:** The `build_dlls.yml` workflow in the OpenMS repo runs `ctest -S cibuild.cmake`, which calls `ctest_start`, `ctest_configure`, and `ctest_build` — but has **no `ctest_test()` call**. It only builds the DLL; it never executes unit tests. The parent repo's `flashida-ci.yml` is the only place C++ tests run.

**Lesson:** Do not assume a successful DLL build means C++ tests pass. The DLL build workflow only compiles. Test execution depends entirely on the parent repo CI pipeline. When debugging test issues, check the parent repo CI, not the DLL build logs.

---

## 12. Off-by-One in Test Assertions Can Hide Behind Coincidental Passes

**What happened:** P6-U01's assertion used `expected_cvs[(i+1) % size]` instead of `expected_cvs[i]`. Three of four iterations would fail, but the fourth passed by coincidence (the shifted index happened to land on the same value). Because the test never ran in CI (lesson 10), the bug was never caught. A compliance audit agent traced through all 4 iterations against the actual implementation to discover the mismatch.

**Lesson:** When writing loop-based test assertions with index arithmetic, trace at least 3 iterations by hand against the actual implementation code. Coincidental passes on a single iteration can mask systematic off-by-one errors. Also: if a test isn't running in CI, it might as well not exist.

---

## 13. Separate Input and Output Values in Cycling Tests

**What happened:** P6-U01 used a single `expected_cvs` array for both the input `faims_cv` parameter to `processScan` (what the instrument scanned at) and the expected output (what the state machine should produce next). These are different sequences: the input starts at the initial CV (-40) and follows the previous transition, while the output is the next CV in the cycle.

**Fix:** Split into `input_cvs = {-40, -50, -60, -40}` and `expected_cvs = {-50, -60, -40, -50}`.

**Lesson:** When testing a state machine that has both input (observed state) and output (next action), use separate arrays. Reusing a single array obscures the test's intent and makes bugs in the assertion formula harder to spot.

---

## 14. Queue Passthrough Tests Don't Verify Behavioral Guards

**What happened:** P6-U06 tested non-FAIMS mode by pushing a pre-stamped MS2 via `pushCommandForTest` and verifying it came back with `faims_cv=0.0`. This tests queue passthrough (commands retain their fields), not the behavioral property it claims to verify: that `processScan` skips CV cycling when `faims_enabled_=false`.

**Fix:** Replaced with a test that calls `processScan` and asserts the queue is empty (no CV-transition MS1 pushed).

**Lesson:** When testing a mode-dependent behavior (FAIMS on/off), the test must exercise the actual code path that checks the mode flag. Pushing pre-built commands via test helpers bypasses the production logic and only tests the queue data structure.

---

## 15. Struct Offset Assertions Must Cover All Fields

**What happened:** `ScanCommandLayoutTests.cs` P3-U03 had offset assertions for all ScanCommand fields through `Pad2` at offset 1236, but stopped there. The Phase 6 `FaimsCv` field at offset 1240 was missing. If the C# struct layout drifted from C++ (e.g., due to a packing change), the gap wouldn't be caught.

**Lesson:** When adding a new field to the P/Invoke ScanCommand struct, add its offset assertion to `ScanCommandLayoutTests.cs` in the same commit. The 5-file lockstep rule (CLAUDE.md) should be extended to include the offset assertion as a 6th file.

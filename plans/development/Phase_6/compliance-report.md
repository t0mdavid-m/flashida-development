# Phase 6: FAIMS Absorption — Compliance & Feedback Report

**Date:** 2026-04-07
**Auditor:** Automated multi-agent audit (7 parallel agents)
**Scope:** Specification compliance, test quality, pipeline routing

---

## Executive Summary

Phase 6 implementation is **structurally complete** — the FAIMS CV cycling state machine is correctly ported to C++, dead code is removed, and all production paths route through the unified pipeline. However, there are **critical test quality issues**: the C++ unit tests have never been run in CI (the DLL build workflow only builds, doesn't execute CTest), and at least one test (P6-U01) has an assertion bug that would cause it to fail if executed.

| Category | Status |
|----------|--------|
| Struct layout (ScanCommand 1248 bytes) | PASS |
| Bridge API (ProcessScan + faims_cv) | PASS |
| FAIMS state machine (per-CV skip logic) | PASS |
| Dead code removal (ScanScheduler, FAIMSScanProcessor) | PASS |
| Pipeline routing (all paths unified) | PASS |
| C++ test quality (P6-U01–U06) | **FAIL** (2 broken, 2 weak) |
| C# test quality (continuity + other) | **PARTIAL** (1 missing offset, soft guards) |
| CI test coverage | **PARTIAL** (C++ FAIMS tests missing from CI filter) |

---

## 1. Specification Compliance

### 1.1 General Specifications (baseline-plan.md, implementation-roadmap.md)

All general requirements PASS:

- ScanCommand struct: 1248 bytes, `static_assert` in C++ (line 109), `Marshal.SizeOf` test in C# (line 21)
- `double faims_cv` field present in both C++ (`FLASHIda.h:107`) and C# (`FLASHIdaWrapper.cs:79`)
- ProcessScan bridge: `double faims_cv` parameter added (`FLASHIdaBridgeFunctions.h:192-194`)
- `getNextScanCommand` returns 0 on empty queue (`FLASHIda.cpp:4098`)
- Per-CV state machine: `cv_skip_amount_[]` and `cv_skip_count_[]` arrays (`FLASHIda.h:879-880`)
- Thread safety: `queue_mutex_` in both `processScan()` and `getNextScanCommand()`
- JSON config: `cv_precursor_threshold` parsed with default 15 (`FLASHIda.cpp:3343`)
- `ScanCommandRecord.FromScanCommand` populates `FaimsCV` (`ScanCommandRecord.cs:99`)

### 1.2 Phase 6 Implementation Plan (step-by-step)

| Step | Description | Status |
|------|-------------|--------|
| 1 | Audit C# FAIMS behavior | PASS |
| 2a | Add `faims_cv` to ScanCommand | PASS |
| 2b | Add FAIMS state machine fields | PASS |
| 3 | Parse FAIMS config from JSON | PASS |
| 4 | Implement updateCVSkip_ and advanceToNextCV_ | PASS |
| 5 | Integrate CV cycling into processScan() | PASS |
| 6 | Integrate CV state into getNextScanCommand() | PASS |
| 7 | Update C# JSON serialization | PASS |
| 8 | Remove ScanScheduler from Flash.cs | PASS |
| 9 | Delete ScanScheduler.cs + FAIMSScanProcessor.cs | PASS |
| 10 | C++ unit tests (P6-U01–U06) | PASS (created; quality issues below) |
| 11 | C# dead code tests (P6-U07/U08) | **FAIL — not created** |
| 12 | Continuity test verification | PASS |

All 10 documented deviations from the original plan are correctly addressed in code and documented in `lessons-learned.md`.

---

## 2. Pipeline Routing Verification

**Status: ALL CLEAN**

| Check | Result |
|-------|--------|
| `ScanScheduler` in production C# code | CLEAN (comment-only refs) |
| `FAIMSScanProcessor` in production C# code | CLEAN (comment-only refs) |
| `GetIsolationWindows` in production paths | CLEAN (retained for legacy testing) |
| ContinuityTestHarness uses UnifiedScanProcessor | CLEAN (line 85) |
| Flash.cs uses UnifiedScanProcessor exclusively | CLEAN (line 289) |
| Flash.csproj references to deleted files | CLEAN (removed) |
| ProcessScan bridge accepts faims_cv | CLEAN (verified C++/C# match) |

Full data flow verified:
```
Instrument → Flash.ProcessSpectrum → DataPipe → UnifiedScanProcessor.ProcessMS
  → FLASHIdaWrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc, faimsCv)
  → C++ ProcessScan bridge → FLASHIda::processScan(... faims_cv)
  → FLASHIdaWrapper.GetNextScanCommand → ScanFactory.BuildFromCommand → Instrument
```

---

## 3. Test Quality Audit

### 3.1 C++ FAIMS Tests Not in CI Filter

The parent repo CI (`flashida-ci.yml`) does run C++ tests via CTest, but the build target list (line 58) and CTest filter (line 63) only include:

```
DeconvolvedSpectrum_OptimizationMetadata | FLASHIdaQueueTracking | FLASHIda_ProcessScan | ScanCommandLayout
```

**`FLASHIdaFAIMS_test` is missing from both the build targets and the CTest filter.** The pre-Phase-6 tests (P3-U05–U10, ProcessScan, ScanCommandLayout) are executed in CI, but the new Phase 6 FAIMS tests (P6-U01–U06) are not built or run.

**Impact:** FAIMS test bugs go undetected. At least P6-U01 has an assertion error (see below).

**Recommendation:** Add `FLASHIdaFAIMS_test` to the build target list and CTest `-R` filter in `flashida-ci.yml`.

### 3.2 C++ FAIMS Tests (P6-U01–U06)

| Test | Rating | Issue |
|------|--------|-------|
| P6-U01 | **FAIL** | Assertion index bug: `expected_cvs[(i+1) % size]` should be `expected_cvs[i]` — the expected sequence {-50,-60,-40,-50} matches the dequeue order, but the shifted index compares against the wrong value |
| P6-U02 | WEAK | Only tests 0 precursors; no boundary test at threshold=15; doesn't verify skip mechanism in action |
| P6-U03 | WEAK | Verifies all CVs appear but doesn't verify skip counts or cap enforcement |
| P6-U04 | GOOD | Correctly tests MS2 CV preservation via pushCommandForTest; lacks processScan integration |
| P6-U05 | GOOD | Priority ordering well-tested; missing assertion on MS1's faims_cv value |
| P6-U06 | **FAIL** | Only pushes a pre-stamped MS2 via pushCommandForTest — doesn't call processScan, so doesn't test that non-FAIMS mode skips CV cycling or sets parent_cv=0.0 |

**P6-U01 detailed trace (max_cv_skip=0, CVs=[-40,-50,-60]):**
- Iteration i=0: `advanceToNextCV_()` increments index 0→1, returns CV[1]=-50
- Test asserts: `expected_cvs[(0+1)%4] = expected_cvs[1] = -60` — **mismatch** (-50 != -60)
- This bug was never caught because CTest doesn't run in CI

### 3.3 C++ Queue/Tracking Tests (P3-U05–U10)

| Test | Rating | Issue |
|------|--------|-------|
| P3-U05 | GOOD | Base-36 encoding edge cases well covered |
| P3-U06 | GOOD | 10K sequential IDs verified unique |
| P3-U07 | GOOD | Empty queue returns 0 — Phase 6 compliant |
| P3-U08 | GOOD | Priority dequeue order verified (minor 30s timing risk) |
| P3-U09 | GOOD | AGC priority verified; missing second dequeue to confirm MS2 still queued |
| P3-U10 | WEAK | Only tests "doesn't crash" with timeout disabled — no actual cleanup verification |

### 3.4 C# Continuity Tests

| Test | Rating | Issue |
|------|--------|-------|
| CT09 | GOOD | Hard assertion on Count > 0 (hardened in Phase 6 Step 0) |
| CT10 | GOOD | Hard assertion; verifies MS2 parent CV |
| CT27 | WEAK | Only checks 2+ distinct CVs exist; doesn't verify skip frequency pattern |
| CT28 | GOOD | Golden file regression comparison |
| CT22 | **FAIL** | if-guarded assertions; can pass with zero MS3 results |
| CT18 | WEAK | Assume.That soft guards; test skips if Count <= 0 |

Overall continuity suite: 27 GOOD, 12 WEAK, 1 FAIL out of 40 tests.

### 3.5 C# Other Tests

| File | Rating | Issue |
|------|--------|-------|
| ScanCommandLayoutTests | **WEAK** | Missing FaimsCv offset assertion at 1240 — only Pad2 at 1236 is verified |
| ProcessorTests | WEAK | P5-U01 constructs with null and asserts non-null — always passes |
| BridgePhase3Tests | WEAK | P3-I01/I03 test empty-queue zeroed values — tautological |
| BridgeMS2Tests | GOOD | P0-I04 `Is.TypeOf<bool>()` is tautological but others are solid |
| All others | GOOD | SmokeTests, JsonConfigTests, DataPipeTests, GoldenCaptureTests all adequate |

No references to deleted `ScanScheduler` or `FAIMSScanProcessor` found in any test file.

---

## 4. Findings Summary

### Critical (must fix)

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| C1 | C++ FAIMS tests not in CI filter | `flashida-ci.yml:58,63` | Add `FLASHIdaFAIMS_test` to build targets and CTest `-R` filter |
| C2 | P6-U01 assertion index bug | `FLASHIdaFAIMS_test.cpp:277` | Change `expected_cvs[(i+1) % size]` to `expected_cvs[i]` |
| C3 | P6-U06 doesn't test non-FAIMS processScan | `FLASHIdaFAIMS_test.cpp:422-445` | Replace with test that calls processScan and verifies no CV-transition MS1 generated |

### High (should fix)

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| H1 | Missing FaimsCv offset assertion | `ScanCommandLayoutTests.cs` P3-U03 | Add `Assert.AreEqual(1240, Marshal.OffsetOf<ScanCommand>("FaimsCv"))` |
| H2 | P6-U07/U08 dead code tests not created | — | Create `DeadCodeTests.cs` or verify via CI grep step |
| H3 | CT22 has if-guarded assertions | `ContinuityTests.cs:587-612` | Replace if-guards with hard Assert; provide proper MS3 test data |

### Medium (improve)

| # | Finding | Location | Note |
|---|---------|----------|------|
| M1 | P6-U02 skip threshold boundary not tested | `FLASHIdaFAIMS_test.cpp:287` | Add test with precursor_count=15 (should NOT trigger) |
| M2 | P6-U03 skip cap not explicitly verified | `FLASHIdaFAIMS_test.cpp:319` | Verify skip_amount <= max_cv_skip after saturation |
| M3 | P6-U05 missing CV value assertion on MS1 | `FLASHIdaFAIMS_test.cpp:405` | Add `TEST_REAL_SIMILAR(out.faims_cv, -50.0)` for CV-transition MS1 |
| M4 | CT27 weak adaptive skip verification | `ContinuityTests.cs:728` | Add frequency analysis per CV |
| M5 | P3-U10 tests nothing meaningful | `FLASHIdaQueueTracking_test.cpp:244` | Delete or implement real timeout cleanup test |
| M6 | ProcessorTests P5-U01 always passes | `ProcessorTests.cs` | Expand or delete |

### Low (nice-to-have)

| # | Finding | Location |
|---|---------|----------|
| L1 | P3-U09 missing second dequeue to verify MS2 still queued | `FLASHIdaQueueTracking_test.cpp:239` |
| L2 | BridgeMS2Tests P0-I04 `Is.TypeOf<bool>()` is tautological | `BridgeMS2Tests.cs:197` |

---

## 5. Recommendations

1. **Immediate:** Fix P6-U01 assertion bug and run C++ tests locally to verify all 6 pass
2. **Before Phase 7:** Add `FLASHIdaFAIMS_test` to CI build targets and CTest filter in `flashida-ci.yml`
3. **Before Phase 7:** Add FaimsCv offset assertion to ScanCommandLayoutTests.cs
4. **Backlog:** Harden CT22, CT18, CT27 soft guards; create P6-U07/U08 dead code tests
5. **Backlog:** Strengthen P6-U02 (boundary), P6-U03 (cap), P6-U06 (processScan integration)

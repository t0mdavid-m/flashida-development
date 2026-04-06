# Phase 5: C# Simplification — Compliance & Feedback Report

**Date:** 2026-04-05
**Scope:** Code vs. spec verification across implementation plan, baseline plan, testing strategy

---

## 1. Implementation Plan Compliance (8/8 PASS)

| Step | Description | Status |
|------|-------------|--------|
| 1 | UnifiedScanProcessor.cs created | **PASS** — constructor, FTMS guard, centroid extraction, ProcessScan delegation, ScanDescription handling all correct |
| 2 | IScanProcessor simplified to 1 method | **PASS** — `void ProcessMS(IMsScan)` only; no OutputMS, no Wrapper property |
| 3 | IDAScanProcessor + QuantScanProcessor deleted | **PASS** — files gone, zero references in csproj or production code |
| 4 | DataPipe collapsed to 2 stages | **PASS** — BufferBlock + ActionBlock; Complete() + WaitForCompletion() added; no TransformManyBlock |
| 5 | Flash.cs updated | **PASS** — static wrapper field, correct processor routing, UseUnifiedBridge removed from ProcessSpectrum |
| 6 | FAIMSScanProcessor retains legacy path | **PASS** — uses GetIsolationWindows → ScanFactory → ScanScheduler; does NOT delegate to UnifiedScanProcessor |
| 7 | UseUnifiedBridge removed everywhere | **PASS** — zero hits in production code, MethodParameters, method.xml, test configs |
| 8 | Null-sentinel pattern removed | **PASS** — zero hits for `scans.Add(null)`, `TransformManyBlock`, `OutputMS` |

**Note:** One comment in `regression-runner.ps1` (line 34) mentions UseUnifiedBridge — non-functional, acceptable.

---

## 2. Baseline Plan Compliance (8 PASS + 2 Known Deviations)

| Item | Status | Notes |
|------|--------|-------|
| IScanProcessor interface | **PASS** | Matches Issue 6 spec |
| UnifiedScanProcessor | **PASS** | Matches Issue 6 spec |
| DataPipe 2-stage | **PASS** | No TransformManyBlock |
| IDAScanProcessor deleted | **PASS** | |
| QuantScanProcessor deleted | **PASS** | |
| OutputMS removed | **PASS** | Zero hits across codebase |
| Flash.cs simplified | **PASS** | |
| UseUnifiedBridge removed | **PASS** | |
| ScanScheduler deleted | **KNOWN DEVIATION** | Retained for FAIMS CV cycling until Phase 6 (documented in plan line 750) |
| FAIMSScanProcessor deleted | **KNOWN DEVIATION** | Retained with legacy pipeline until Phase 6 (ScanCommand lacks faims_cv field) |

Both known deviations are explicitly documented in the Phase 5 implementation plan with clear technical rationale.

---

## 3. Testing Strategy Compliance

| Test ID | Spec | Status | Notes |
|---------|------|--------|-------|
| P5-U01 | UnifiedScanProcessor instantiates | **EXISTS** | Tier 1, in csproj |
| P5-U02 | IScanProcessor reflection check | **EXISTS** | Tier 1, in csproj |
| P5-U03 | No QuantScanProcessor references | **MISSING** | `DeadCodeTests.cs` never created |
| P5-U04 | DataPipe completion propagation | **EXISTS** | Tier 1, in csproj |
| P5-R01 | All 9 modes match golden files | **EXISTS** | Via `regression-runner.ps1` in CI (13 configs total) |
| P5-R02 | FAIMS mode regression | **REMOVED** | Justified: Flash.exe test mode bypasses ScanScheduler/FAIMS; replaced by CT09/CT10/CT27/CT28 |

### GAP: P5-U03 is specified in both `testing-strategy.md` and the implementation plan (line 294, DoD line 475) but was not implemented.

---

## 4. Test Quality Assessment

### Tier 1 Tests

| Test | Rating | Assessment |
|------|--------|------------|
| P5-U01 | **WEAK** | Tests `new UnifiedScanProcessor(null)` + IsNotNull. This is a tautology — `new` never returns null in C#. Passes even if ProcessMS contains `throw new NotImplementedException()`. The most important Phase 5 deliverable has zero behavioral coverage at Tier 1. |
| P5-U02 | **ADEQUATE** | Correctly guards "no OutputMS" via reflection. Thorough signature check. Minor brittleness: counts methods rather than asserting absence of `OutputMS` by name. |
| P5-U04 | **STRONG** | Tests real TPL Dataflow completion propagation — the specific behavior that motivated the pipeline change. Clean mock, concrete assertion, appropriate timeout. |

### Tier 2/3 Tests

| Category | Rating |
|----------|--------|
| Continuity tests (non-FAIMS) | **STRONG** — 16 golden-file tests through UnifiedScanProcessor |
| Continuity tests (FAIMS) | **MIXED** — CT27/CT28 hard assertions; CT09/CT10 have soft `if (results.Count > 0)` guards |
| Regression runner (P5-R01) | **STRONG** — 13 configs with golden file comparison |

### Soft Guards Found

| Location | Guard Type | Severity |
|----------|-----------|----------|
| CT09 (line 302) | `if (results.Count > 0)` | **HIGH** — passes silently with zero results |
| CT10 (line 335) | `if (results.Count > 0)` | **HIGH** — passes silently with zero results |
| CT06 (line 207) | `Assume.That(results.Count > 0)` | **MEDIUM** — golden file test becomes Inconclusive |
| CT07 (line 237) | `Assume.That(results.Count > 0)` | **LOW** — tracking ID uniqueness test |
| CT18 (line 519) | `Assume.That(ms2Commands.Count > 0)` | **MEDIUM** — conditional MS2 precondition |
| CT22 (line 586) | `Assume.That(ms2Commands.Count > 0)` | **MEDIUM** — MS3 precondition |

---

## 5. Pipeline Routing Verification

**All correct.** Every test routes through the correct pipeline:

- **Non-FAIMS** (CT01-CT08, CT11-CT26, CT33-CT42): `UnifiedScanProcessor` → `ProcessScan` → `GetNextScanCommand`
- **FAIMS** (CT09, CT10, CT27, CT28): `FAIMSScanProcessor` → `GetIsolationWindows` → `ScanFactory` (legacy)
- **Stress** (CT31, CT32): Direct wrapper bypass — intentional and correct

Test harness routing (line 186-189) exactly mirrors production Flash.cs (line 410-413).

**Zero dead references:** No mentions of `IDAScanProcessor`, `QuantScanProcessor`, or `OutputMS` remain in test code.

---

## 6. Plan-Internal Inconsistency

The implementation plan has a self-contradiction in Step 6:
- One section says: "Ensure ProcessMS delegates to the inner processor's ProcessMS"
- Another section says: "For Phase 5, retain the legacy deconvolution path in FAIMSScanProcessor"

The code correctly follows the second instruction (legacy path retained). This inconsistency should be cleaned up in the plan.

---

## 7. Action Items

### Required (spec gaps)

1. **Implement P5-U03 (`DeadCodeTests.cs`)** — NUnit test that searches production `.cs` files for `QuantScanProcessor`, `OutputMS`, and `UseUnifiedBridge` references. Guards against re-introduction.

### Recommended (test quality)

2. **Strengthen P5-U01** — Either:
   - a) Test FTMS guard: verify non-FTMS scan is rejected (no ProcessScan call), or
   - b) Test with a spy wrapper to verify ProcessScan receives correct arguments, or
   - c) At minimum, call ProcessMS with a mock scan and verify it doesn't throw

3. **Harden CT09/CT10** — Replace `if (results.Count > 0)` with hard `Assert.That(results.Count, Is.GreaterThan(0))`, matching CT27/CT28 pattern. If the legacy bridge needs more scans, add them to the test data.

### Housekeeping

4. **Clean up plan Step 6 inconsistency** — Remove the "delegates to inner processor" language, since the actual decision is "retain legacy path."

5. **Remove UseUnifiedBridge comment** from `regression-runner.ps1` line 34.

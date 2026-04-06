# Phase 4 Compliance & Test Effectiveness Report

**Generated**: 2026-04-02
**Scope**: Baseline spec, Phase 4 plan, testing strategy, all test tiers, unified bridge routing

---

## Executive Summary

Phase 4 implementation is **substantially complete** with the unified bridge (`ProcessScan` + `GetNextScanCommand`) working end-to-end in production, test mode, and most continuity tests. However, the audit identified **1 critical bug**, **3 high-priority gaps**, and **several medium-priority deviations** from spec.

| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Bridge routing bugs | 1 | — | — | — |
| Spec deviations | — | 3 | 5 | 4 |
| Test effectiveness | — | 2 | 4 | 3 |
| Missing test coverage | — | 1 | 3 | 2 |

---

## 1. Critical Findings

### CRIT-01: FAIMS Continuity Tests Pass Vacuously (CT09, CT10)

**Severity**: CRITICAL — tests exist but validate nothing

**Root cause**: `ContinuityTestHarness.PushScan()` line 207 has the condition:
```csharp
if (MethodParams.UseUnifiedBridge && !UseFaimsCycling)
```
When `UseFaimsCycling=true` (FAIMS tests), the harness falls to the `else` branch which calls `Processor.ProcessMS()`. But `FAIMSScanProcessor.ProcessMS()` with `UseUnifiedBridge=true` calls `ProcessScan` and returns an **empty list** — it never drains `GetNextScanCommand`. Commands accumulate in the C++ queue, unretrieved.

Both CT09 and CT10 guard their assertions with `if (results.Count > 0)`, so they silently pass with 0 results.

**Impact**: FAIMS CV cycling behavior is completely untested under the unified bridge. CT27/CT28 (ignored, Phase 6) would have the same issue once unignored.

**Fix**: When `UseFaimsCycling=true && UseUnifiedBridge=true`, the harness should drain `GetNextScanCommand` after `ProcessScan`, same as the non-FAIMS unified path.

---

## 2. High-Priority Findings

### HIGH-01: `getNextScanCommand` Missing Cycle Time Check

**Spec**: baseline-plan.md Step 2 of `getNextScanCommand` pseudocode: `if (cycle_time_enabled_ && msSinceLastMS1_() > cycle_time_ms_) return makeMS1Command_()`

**Actual**: The cycle time check does not exist in `getNextScanCommand()` (FLASHIda.cpp:3901-3930). `cycle_time_enabled_` and `cycle_time_ms_` are parsed from JSON config but never used in `getNextScanCommand`.

**Impact**: When the MS2 queue is full and processing takes longer than the configured cycle time, no forced MS1 scan is injected. On real instruments, this could cause extended periods without MS1 survey scans.

### HIGH-02: `getNextScanCommand` Returns 0 When Empty (Spec Says MS1)

**Spec**: baseline-plan.md Step 5: When all priority queues are empty, return `makeMS1Command_()` with return value 1.

**Actual**: Returns 0 (no command). C# `Flash.cs` falls back to `ScanScheduler.getNextScan()` to send a default scan.

**Impact**: Acceptable as long as `ScanScheduler` exists (Phase 5+), but deviates from the spec's intent of C++ owning the full scan queue. Must be resolved before ScanScheduler deletion.

### HIGH-03: AGC Command Magic Values Differ from Spec

**Spec**: `scan_id=41`, `agc_target=30000`, `max_it=1`

**Actual**: `scan_id` = dynamic tracking ID, `agc_target=0`, `max_it=0`

**Impact**: On real instruments, these values configure how the AGC pre-scan behaves. Incorrect values could affect ion count calibration. Needs verification against Thermo iAPI documentation.

---

## 3. Spec Compliance Matrix

### Baseline Spec (Phase 4-relevant items)

| Requirement | Status | Notes |
|-------------|--------|-------|
| ProcessScan signature & MS1 routing | COMPLIANT | All 6 scoring branches, mass exclusion, top-N selection |
| ProcessScan MS2 routing (all modes) | COMPLIANT | Tag targeting, quant, conditional, MS3 (all 4 modes) |
| Tracking ID (4-char base-36) | PARTIAL | Mutex-guarded int (not std::atomic); integer IDs in scan_description instead of base-36 |
| Audit log events (TRACK-CREATE/RESOLVE/EXPIRE) | COMPLIANT | All trigger points covered |
| ScanCommand struct | COMPLIANT+ | 1240 bytes (88 more than spec due to scoring fields) |
| IsolationStage struct | PARTIAL | `first_mass`/`last_mass` moved to ScanCommand (documented deviation) |
| GetNextScanCommand: AGC first | COMPLIANT | |
| GetNextScanCommand: Cycle time MS1 | **NON-COMPLIANT** | Missing entirely (HIGH-01) |
| GetNextScanCommand: Empty→MS1 | **NON-COMPLIANT** | Returns 0, not MS1 (HIGH-02) |
| AGC command values | **PARTIAL** | Magic values differ (HIGH-03) |
| UseUnifiedBridge feature flag | COMPLIANT | Correctly gates all paths |
| Flash.cs GetNextScanCommand loop | COMPLIANT | |
| ScanFactory.BuildFromCommand | COMPLIANT | Note: CollisionEnergy cast to int (precision loss) |
| JSON config parsing (all sections) | COMPLIANT | |
| P/Invoke declarations (5 new) | COMPLIANT | Old ~18 still declared (Phase 8 removal) |

### Phase 4 Implementation Plan

| Task | Status | Deviation |
|------|--------|-----------|
| Step 0: Pre-switch golden baselines | DONE | 10+ golden files (plan specified 9) |
| Step 1: UseUnifiedBridge flag | DONE | Default is `true` in method.xml (plan says `false`); missing from JSON output |
| Step 2: MS1 path in processScan | DONE | Delegates to getPeakGroups() instead of inlining |
| Step 2b: buildMS2Command_ scoring fields | DONE+ | Added 12 scoring fields beyond plan (struct 1240 vs 1152) |
| Step 3: MS2 path in processScan | DONE | Conditional MS2 has no per-scan criteria check (always fires when enabled) |
| Step 4: ProcessScan returns count | DONE | |
| Step 5: C# switch-over | DONE | |
| Step 6: TRACK audit trail | DONE | Missing TRACK-CREATE for AGC/MS1 commands from getNextScanCommand |
| Step 7: Thread safety | DONE | Full lock (acceptable per plan) |
| Step 8: Behavioral equivalence | PARTIAL | CI captures golden files but no comparison step visible |
| Step 9: Continuity harness switch | DONE | FAIMS path broken (CRIT-01) |
| Scan description format | DEVIATED | Uses integer IDs, not base-36 |
| Plan progress tracking | STALE | Batches C-E marked PENDING but are substantially complete |

---

## 4. Test Effectiveness by Tier

### Tier 1: Layout & Config Tests

| Test File | Tests | Effective | Vacuous | Notes |
|-----------|-------|-----------|---------|-------|
| ScanCommandLayoutTests.cs | 4 | 4 | 0 | All 12 scoring fields covered. No vacuous tests. |
| ScanCommandLayout_test.cpp | 1 binary | 0 | 1 | Prints offsets but never asserts. Always returns 0 / PASSED. |
| JsonConfigTests.cs | 6 | 4 | 0 | P1_U02 misses `ms3`/`conditional_ms2` keys (checks 9 of 11). P1_U03 only compares 3 of 11 JSON sections. |
| FLASHIdaQueueTracking_test.cpp | 6 | 5 | 1 | P3-U10 (timeout) only tests disabled path. |

### Tier 2: Bridge Integration Tests

| Test File | Tests | Effective | Vacuous | Notes |
|-----------|-------|-----------|---------|-------|
| BridgeSmokeTests.cs | 5 | 3 | 0 | P0_I01 and P1_I02 are near-duplicates. P1_I03 has 2 Assert.Ignore escape hatches. |
| BridgePhase3Tests.cs | 5 | 4 | 0 | **No positive-path test** — unified bridge never tested with real data producing actual commands. |
| BridgePhase4Tests.cs | 1 | 0 | 1 | Asserts `>= 0` — always passes. |
| BridgeMS2Tests.cs | 6 | 1 | 4 | 4 tests assert `count >= 0`. Only P0_I03 asserts `> 0`. All test **legacy** path. |

### Tier 2b: Continuity/Integration Tests

| Test File | Tests | Effective | Vacuous | Notes |
|-----------|-------|-----------|---------|-------|
| ContinuityTests.cs | 28 active | 22 | 4 | CT01-03,CT11 use Assume guards (silent skip on 0 results). CT09,CT10 pass vacuously (CRIT-01). |
| GoldenCaptureTests.cs | 2 | 2 | 0 | Config serialization smoke tests (not integration). |

### Tier 3: Regression Tests (Golden File)

| Mechanism | Coverage | Notes |
|-----------|----------|-------|
| CI golden capture | 10 modes | All Phase 4 modes captured as artifacts |
| CI comparison | **UNCLEAR** | `regression-runner.ps1` runs but no visible comparison step that would fail on mismatch |
| `compare_golden.py` | **MISSING** | Spec requires it but does not exist |

### Tier 4: Stress Tests

| Test | Effective | Notes |
|------|-----------|-------|
| CT31 (1000 sequential) | PARTIAL | Synthetic data → 0 commands returned. Tests no-crash only. |
| CT32 (4 threads concurrent) | PARTIAL | Same synthetic data issue. |

### C++ Engine Tests

| Test File | Tests | Effective | Weak | Notes |
|-----------|-------|-----------|------|-------|
| FLASHIda_ProcessScan_test.cpp | 13 | 9 | 4 | P4-U07 (MS3): silent pass if 0 fragments. P4-U11: `<=` too weak. P4-U12 (Quant): double-guarded, never validates quant. P4-U13 (Tag): asserts `>= 0`. |

---

## 5. Bridge Routing Matrix

| Test File | Path | Correct? |
|-----------|------|----------|
| BridgeSmokeTests.cs | NEITHER (construction only) | N/A |
| BridgePhase3Tests.cs | **UNIFIED** | Yes |
| BridgePhase4Tests.cs | **LEGACY** (intentional backward compat) | Yes |
| BridgeMS2Tests.cs | **LEGACY** (Phase 0 smoke tests) | Intentional, but testing dead code |
| ContinuityTests (non-FAIMS) | **UNIFIED** via harness | Yes |
| ContinuityTests (FAIMS: CT09,CT10) | **BROKEN** — calls ProcessScan but never drains queue | **No** (CRIT-01) |
| SmokeTests (P0_U03, P0_U04) | **UNIFIED** via Flash.exe subprocess | Yes |
| GoldenCaptureTests | NEITHER (JSON serialization) | N/A |
| ScanCommandLayoutTests | NEITHER (struct layout) | N/A |
| JsonConfigTests | NEITHER (config parsing) | N/A |
| Stress (CT31, CT32) | **UNIFIED** (direct calls) | Yes |

**35 of 37 active bridge-calling tests correctly route through the unified bridge.** The 2 exceptions are CT09 and CT10 (CRIT-01).

---

## 6. Missing Test Coverage (Prioritized)

### High Priority

1. **P4-U09: TRACK audit trail completeness** — No test feeds 10 MS1 + 10 MS2 scans and verifies every command has TRACK-CREATE and every resolution has TRACK-RESOLVE. Only covered by CI `TRACK-CREATE > 0` check (weaker than spec).

2. **Unified bridge positive-path integration test** — No C# test pushes real spectrum data through `ProcessScan` and verifies that `GetNextScanCommand` returns populated `ScanCommand` structs with non-zero scoring fields, valid strings, correct stage data.

### Medium Priority

3. **CI golden file comparison** — `compare_golden.py` does not exist. CI captures golden files but may not fail on mismatch.

4. **UseUnifiedBridge=true config parsing test** — Only the `false` case is tested (`BridgePhase4Tests.cs`). No test verifies `true` is parsed correctly from XML.

5. **FAIMS + unified bridge command drain** — Even after CRIT-01 is fixed, no test validates the production FAIMS path where `Flash.cs` drains commands via `GetNextScanCommand` after FAIMS processor calls `ProcessScan`.

6. **Timeout expiry test** — P3-U10 only tests disabled timeout. No test verifies expired commands are actually cleaned up.

### Low Priority

7. **`ms3`/`conditional_ms2` JSON keys** — P1_U02 checks 9 of 11 top-level keys.
8. **Golden file staleness** — `config_default.json` has 9 keys but actual output has 11.
9. **Stress tests with real data** — CT31/CT32 use synthetic peaks that never produce commands.

---

## 7. Spec Deviations Requiring Decision

These deviations may be intentional design decisions but should be explicitly acknowledged:

| # | Deviation | Spec Says | Actual | Impact |
|---|-----------|-----------|--------|--------|
| D1 | Scan description format | Base-36 4-char ID | Integer ID (`_0`, `_1`...) | Functional; base-36 functions exist but unused |
| D2 | Conditional MS2 criteria | `meetsConditionalCriteria_()` gate | Always fires when enabled | Over-triggers conditional follow-ups |
| D3 | UseUnifiedBridge default | `false` | `true` in method.xml | Correct for Phase 4 post-switchover |
| D4 | `use_unified_bridge` in JSON | Include in ToJSON() | Not included | C++ doesn't need it; C#-only flag |
| D5 | CollisionEnergy in BuildFromCommand | double | Cast to int | Precision loss for non-integer CE |
| D6 | MS3 commands in pending_scan_map_ | Store for tracking | Not stored | MS3 results not tracked back |
| D7 | Tracking ID counter | std::atomic | Mutex-guarded int | Functionally equivalent |

---

## 8. Recommendations

### Immediate (before Phase 5)

1. **Fix CRIT-01**: Update `ContinuityTestHarness.PushScan()` to drain `GetNextScanCommand` when `UseFaimsCycling=true && UseUnifiedBridge=true`.
2. **Strengthen vacuous assertions**: Change `>= 0` to `> 0` in P4_I01, BridgeMS2Tests (P0_I05-I08), and C++ tests P4-U12/P4-U13.
3. **Add unified bridge positive-path test**: Load `ms1_standard.txt`, push through `ProcessScan`, verify `GetNextScanCommand` returns populated commands.

### Before Phase 5 starts

4. **Implement cycle time check** in `getNextScanCommand` (HIGH-01) or formally defer with rationale.
5. **Verify AGC magic values** against Thermo iAPI docs (HIGH-03).
6. **Add CI golden comparison step** or document why capture-only is sufficient.
7. **Update Phase 4 plan progress** — Batches C-E are marked PENDING but are complete.

### Ongoing

8. **Replace `Assume.That` with `Assert.That`** in CT01-03, CT11 now that golden baselines exist.
9. **Use real spectrum data** in stress tests CT31/CT32.
10. **Decide on D1-D7 deviations** — accept and document, or fix.

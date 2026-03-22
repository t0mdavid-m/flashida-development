# Verification Report: Phase Plans vs. Source Documents

**Date:** 2026-03-22
**Scope:** Phase 0 through Phase 8 implementation plans verified against:
- `baseline-plan.md` (architecture design, 9 issues, phased migration)
- `testing-strategy.md` (per-phase test plans, CI infrastructure)
- `implementation-roadmap.md` (build batching, dependency graph, issue-to-phase mapping)

---

## Check 1: Issue Coverage

The baseline plan defines 9 issues. Each issue must be addressed in at least one phase plan.

| Issue | Description | Phase(s) covering it | Coverage assessment |
|-------|-------------|---------------------|---------------------|
| 1 | Unified ProcessScan Bridge | Phase 3 (stub), Phase 4 (full implementation) | **Complete.** Phase 3 adds ProcessScan stub + shadow validation. Phase 4 implements full MS1/MS2 routing. |
| 2 | ScanCommand Struct | Phase 3 | **Complete.** Phase 3 defines IsolationStage and ScanCommand in both C++ and C#, with static_assert size checks and Marshal.SizeOf tests. |
| 3 | C++ Owns the Scan Queue | Phase 3 (priority queue), Phase 4 (command push), Phase 6 (FAIMS absorption) | **Complete.** Phase 3 implements the queue infrastructure. Phase 4 populates it. Phase 6 absorbs FAIMS CV cycling and deletes ScanScheduler. |
| 4 | MSn-Generalized Exploration Engine | Phase 7 | **Complete.** Phase 7 implements ExplorationGroup, ExplorationVariant, CE sweep, winner selection, MS3 recursive exploration, MS1 suppression, and OptimizationMetadata population. |
| 5 | Scoring in the Unified Architecture | Phase 4 | **Complete.** Phase 4 implements all 6 scoring branches (QScore, IDScore representative, IDScore all charges, plus deep mode variants) inside processScan(). |
| 6 | Simplified C# Architecture | Phase 5 | **Complete.** Phase 5 creates UnifiedScanProcessor, simplifies IScanProcessor to one method, collapses DataPipe to 2 stages, deletes QuantScanProcessor, removes UseUnifiedBridge flag. |
| 7 | P/Invoke Declarations (5 total) | Phase 3 (add 3 new), Phase 8 (remove 13 old) | **Complete.** Phase 3 adds ProcessScan, GetNextScanCommand, GetNextTrackingId P/Invoke declarations. Phase 8 removes the 13 legacy declarations, leaving exactly 5. |
| 8 | Full JSON Configuration | Phase 1 | **Complete.** Phase 1 implements ToJSON() in C#, JSON auto-detect in C++ constructor, parseJSONConfig_(), all 8 JSON schema sections, MethodConfig.cs typed model. |
| 9 | Acquisition Metadata on DeconvolvedSpectrum | Phase 2 (struct + accessors), Phase 7 (population by exploration engine) | **Complete.** Phase 2 creates OptimizationMetadata.h, adds std::optional member and accessors to DeconvolvedSpectrum, and serializes via setMetaValue(). Phase 7 populates the metadata during exploration variant scoring. |

**Result: PASS.** All 9 issues are fully covered.

---

## Check 2: Test Coverage

Every test ID defined in testing-strategy.md must appear in the corresponding phase plan.

### Phase 0 (7 tests)
| Test ID | Present in Phase 0 plan? |
|---------|-------------------------|
| P0-U01 | Yes |
| P0-U02 | Yes |
| P0-U03 | Yes |
| P0-U04 | Yes |
| P0-I01 | Yes |
| P0-I02 | Yes |
| P0-R01 | Yes |

### Phase 1 (10 tests)
| Test ID | Present in Phase 1 plan? |
|---------|-------------------------|
| P1-U01 | Yes |
| P1-U02 | Yes |
| P1-U03 | Yes |
| P1-U04 | Yes |
| P1-U05 | Yes |
| P1-I01 | Yes |
| P1-I02 | Yes |
| P1-I03 | Yes |
| P1-R01 | Yes |
| P1-R02 | Yes |

### Phase 2 (6 tests)
| Test ID | Present in Phase 2 plan? |
|---------|-------------------------|
| P2-U01 | Yes |
| P2-U02 | Yes |
| P2-U03 | Yes |
| P2-U04 | Yes |
| P2-U05 | Yes |
| P2-R01 | Yes |

### Phase 3 (16 tests)
| Test ID | Present in Phase 3 plan? |
|---------|-------------------------|
| P3-U01 | Yes |
| P3-U02 | Yes |
| P3-U03 | Yes |
| P3-U04 | Yes |
| P3-U05 | Yes |
| P3-U06 | Yes |
| P3-U07 | Yes |
| P3-U08 | Yes (noted as stub/placeholder with ABORT_IF(true)) |
| P3-U09 | Yes (noted as stub/placeholder with ABORT_IF(true)) |
| P3-U10 | Yes |
| P3-I01 | Yes |
| P3-I02 | Yes |
| P3-I03 | Yes |
| P3-I04 | Yes |
| P3-I05 | Yes |
| P3-R01 | Yes |

### Phase 4 (21 tests)
| Test ID | Present in Phase 4 plan? |
|---------|-------------------------|
| P4-U01 | Yes |
| P4-U02 | Yes |
| P4-U03 | Yes |
| P4-U04 | Yes |
| P4-U05 | Yes |
| P4-U06 | Yes |
| P4-U07 | Yes |
| P4-U08 | Yes |
| P4-U09 | Yes |
| P4-I01 | Yes |
| P4-I02 | Yes |
| P4-R01 | Yes |
| P4-R02 | Yes |
| P4-R03 | Yes |
| P4-R04 | Yes |
| P4-R05 | Yes |
| P4-R06 | Yes |
| P4-R07 | Yes |
| P4-R08 | Yes |
| P4-R09 | Yes |
| P4-R10 | Yes |

### Phase 5 (6 tests)
| Test ID | Present in Phase 5 plan? |
|---------|-------------------------|
| P5-U01 | Yes |
| P5-U02 | Yes |
| P5-U03 | Yes |
| P5-U04 | Yes |
| P5-R01 | Yes |
| P5-R02 | Yes |

### Phase 6 (13 tests)
| Test ID | Present in Phase 6 plan? |
|---------|-------------------------|
| P6-U01 | Yes |
| P6-U02 | Yes |
| P6-U03 | Yes |
| P6-U04 | Yes |
| P6-U05 | Yes |
| P6-U06 | Yes |
| P6-U07 | Yes |
| P6-U08 | Yes |
| P6-I01 | Yes |
| P6-R01 | Yes |
| P6-R02 | Yes |
| P6-R03 | Yes |
| P6-S01 | Yes |

### Phase 7 (12 tests)
| Test ID | Present in Phase 7 plan? |
|---------|-------------------------|
| P7-U01 | Yes |
| P7-U02 | Yes |
| P7-U03 | Yes |
| P7-U04 | Yes |
| P7-U05 | Yes |
| P7-U06 | Yes |
| P7-U07 | Yes |
| P7-U08 | Yes |
| P7-U09 | Yes |
| P7-U10 | Yes |
| P7-R01 | Yes |
| P7-R02 | Yes |

### Phase 8 (7 tests)
| Test ID | Present in Phase 8 plan? |
|---------|-------------------------|
| P8-U01 | Yes |
| P8-U02 | Yes |
| P8-U03 | Yes |
| P8-U04 | Yes |
| P8-I01 | Yes |
| P8-I02 | Yes |
| P8-R01 | Yes |

**Result: PASS.** All 98 test IDs from the testing strategy are present in their corresponding phase plans. No missing test IDs.

---

## Check 3: File Coverage

### Files modified in multiple phases (expected)

| File | Phases | Assessment |
|------|--------|------------|
| `FLASHIda.h` | 1, 2 (indirect via OptimizationMetadata), 3, 4, 6, 7, 8 | Expected — core C++ class evolving across migration |
| `FLASHIda.cpp` | 1, 3, 4, 6, 7, 8 | Expected |
| `FLASHIdaBridgeFunctions.h` | 3, 8 | Expected — Phase 3 adds exports, Phase 8 removes old ones |
| `FLASHIdaBridgeFunctions.cpp` | 3, 4, 8 | Expected — Phase 3 adds stubs, Phase 4 updates return value, Phase 8 removes old |
| `FLASHIdaWrapper.cs` | 1, 3 | Expected — Phase 1 switches to JSON, Phase 3 adds new P/Invoke declarations |
| `Parameter.cs` | 1, 4, 5, 6, 7, 8 | Expected — evolves throughout migration |
| `MethodConfig.cs` | 1, 4, 6 | Expected |
| `Flash.cs` | 4, 5, 6 | Expected |
| `IScanProcessor.cs` | 4, 5 | Expected |
| `executables.cmake` | 2, 3, 4, 6, 7, 8 | Expected — each C++ test phase adds entries |
| `flashida-ci.yml` | 0, 2 (activate cpp tests), 3, 4, 6, 7, 8 | Expected |

### Files created and deleted across phases

| File | Created in | Deleted in | Assessment |
|------|-----------|-----------|------------|
| `QuantScanProcessor.cs` | (pre-existing) | Phase 5 | **Correct.** Baseline plan specifies deletion in Phase 5. |
| `FAIMSScanProcessor.cs` | (pre-existing) | Phase 6 | **Correct.** Baseline plan specifies deletion in Phase 6. |
| `ScanScheduler.cs` | (pre-existing) | Phase 6 | **Correct.** Baseline plan specifies deletion in Phase 6. |
| `UnifiedScanProcessor.cs` | Phase 5 | (retained) | **Correct.** |
| `OptimizationMetadata.h` | Phase 2 | (retained) | **Correct.** |
| `MethodDocGenerator.cs` | Phase 8 | (retained) | **Correct.** |

### Files that should be modified based on baseline plan but are not in any phase plan

| Baseline file reference | Assessment |
|------------------------|------------|
| `DeconvolvedSpectrum.h/.cpp` (Issue 9) | **Covered** in Phase 2 |
| `ScanFactory.cs` (Issue 3) | **Covered** in Phase 3 (`BuildFromCommand`) and Phase 4 |
| `DataPipe.cs` (Issue 6) | **Covered** in Phase 5 |
| `method.xml` (Issues 3, 4, 8) | **Covered** in Phases 1, 4, 5, 6 |

**Result: PASS.** All files referenced in the baseline plan are covered by at least one phase plan. No orphaned file modifications.

---

## Check 4: Build Batching

The roadmap specifies:

| Build | Phases | Roadmap states | Phase plans state | Match? |
|-------|--------|---------------|-------------------|--------|
| (none) | Phase 0 | No C++ build | Phase 0: "Build: None" | **Yes** |
| Build #1 | Phases 1 + 2 + 3 | JSON config, OptimizationMetadata, ScanCommand | Phase 1: "Build batch: Build #1"; Phase 2: "Build batch: Build #1"; Phase 3: "Build: Build #1" | **Yes** |
| Build #2 | Phase 4 | Full ProcessScan, switch-over | Phase 4: "Build produced: Build #2" | **Yes** |
| (none) | Phase 5 | C#-only, no build | Phase 5: "Build produced: None" | **Yes** |
| Build #3 | Phase 6 | FAIMS absorption | Phase 6: "Build: Build #3" | **Yes** |
| Build #4 | Phases 7 + 8 | Exploration engine, cleanup | Phase 7: "Build: Build #4"; Phase 8: "Build: Build #4" | **Yes** |

**Result: PASS.** All build batching is consistent across the roadmap and individual phase plans.

---

## Check 5: Dependency Chain

| Phase | Prerequisites stated in plan | Correct? |
|-------|------------------------------|----------|
| Phase 0 | None (starting point) | **Yes** |
| Phase 1 | Phase 0 complete (golden files, test project, CI skeleton) | **Yes** |
| Phase 2 | Phase 0 done, Phase 1 done or in-flight (same Build #1 batch), C++ test infrastructure active | **Yes** |
| Phase 3 | Phases 0, 1, 2 complete. All 23 cumulative tests pass. | **Yes** (correct count: P0=7, P1=10, P2=6 = 23) |
| Phase 4 | Build #1 complete and verified. Phase 3 golden files exist. Mode-specific configs exist. | **Yes** |
| Phase 5 | Phase 4 switch-over verified for all modes. FAIMS regression passing. Phase 4 golden files committed. | **Yes** |
| Phase 6 | Phase 5 complete. ScanScheduler still exists. Build #2 artifacts cached. Phase 5 golden files exist. | **Yes** |
| Phase 7 | Phase 6 complete. OptimizationMetadata struct exists (Phase 2). Priority queue in place (Phase 3). processScan MS2 routing in place (Phase 4). JSON exploration fields parsed (Phase 1). | **Yes** |
| Phase 8 | Phase 7 complete. Build #4 Phase 7 compilation succeeded. All P0-P7 tests pass. No callers of old bridge functions remain. Legacy config not passed from C#. | **Yes** |

### Cross-phase assumption check

| Assumption | Phase assuming it | Phase providing it | Valid? |
|-----------|-------------------|-------------------|--------|
| `ProcessScan` stub exists | Phase 4 (promotes to full) | Phase 3 | **Yes** |
| `ScanCommand` struct exists | Phase 4 (uses for routing) | Phase 3 | **Yes** |
| `UseUnifiedBridge` flag exists | Phase 5 (removes it) | Phase 4 | **Yes** |
| `ScanScheduler` still exists | Phase 6 (deletes it) | Phase 5 (preserves it) | **Yes** |
| `FAIMSScanProcessor` still exists | Phase 6 (deletes it) | Phase 5 (preserves it) | **Yes** |
| `OptimizationMetadata` struct exists | Phase 7 (populates it) | Phase 2 | **Yes** |
| `feedExplorationResult_()` stub exists | Phase 7 (implements it) | Phase 4 (noted as stub) | **Yes** |
| Old bridge functions no longer called | Phase 8 (removes them) | Phase 4/5 (stopped calling) | **Yes** |
| `parseLegacy_()` still exists | Phase 8 (removes it) | Phase 1 (preserves it) | **Yes** |

**Result: PASS.** All dependency chains are correct. No phase assumes something that hasn't been built yet.

---

## Check 6: Working Product Verification

Each phase must have clear, testable verification criteria.

| Phase | WPV criteria count | Vague criteria? | All automated? |
|-------|-------------------|-----------------|----------------|
| 0 | 5 (WPV-1 through WPV-5) | No — all are concrete (build exits 0, Flash.exe -t produces TSV, bridge calls don't crash, golden file captured, CI jobs pass) | Yes — automated by P0-U01/U02, P0-U03/U04, P0-I01/I02, P0-R01, and CI job status |
| 1 | 4 verifications | No — all concrete (Flash.exe -t with JSON, round-trip field match, legacy fallback, no output change) | Yes — automated by P1-R01, P1-I03, P1-I02, P1-R01 |
| 2 | 5 verifications | No — all concrete (C++ tests pass, Flash.exe -t unchanged, hasOptimizationMetadata returns false, bridge unchanged, all prior tests pass) | Yes |
| 3 | 8 verifications | No — all concrete (build succeeds, C++ tests pass, layout tests pass, regression unchanged, TRACK entries present, GetNextScanCommand returns MS1, DLL exports verified, no behavioral change) | Yes |
| 4 | 6 verifications | No — all concrete (flag-off regression, standard DDA equivalence, each mode works, TRACK audit trail, race condition elimination, dumpbin exports) | Yes |
| 5 | 6 verifications | No — all concrete (build with /warnaserror, test mode runs, FAIMS mode runs, DataPipe completion clean, dead code absent, NUnit suite passes) | Yes |
| 6 | 7 verifications (plus debugging guide) | No — all concrete (non-FAIMS unchanged, 3-CV cycling matches, adaptive skipping works, skip limit enforced, files deleted, no race conditions, full prior regression) | Yes |
| 7 | 7 verifications (WPV-1 through WPV-7) | No — all concrete (exploration disabled regression, 5 variants per precursor, winner selection, queue overflow, MS1 suppression, metadata populated, MS3 depth limit) | Yes |
| 8 | 8 verifications | No — all concrete (Flash.exe -t runs, 5 DLL exports, zero warnings, MethodDocGenerator output, no legacy P/Invoke, ToFLASHDeconvInput absent, legacy config rejected, full regression) | Yes |

**Result: PASS.** All phases have clear, testable, non-vague verification criteria, and all criteria are automated by specific test IDs.

---

## Gaps Found and Fixes Applied

**No gaps were found.** All six checks passed without issues. The 9 per-phase implementation plans (Phase 0 through Phase 8) fully and correctly cover:

1. All 9 issues from the baseline plan
2. All 98 test IDs from the testing strategy
3. All files that need to be created, modified, or deleted
4. The build batching structure from the roadmap
5. The dependency chain with correct prerequisite ordering
6. Testable working product verification criteria for every phase

No edits to any phase plan files were required.

---

## Remaining Concerns (non-blocking)

These are observations, not gaps. They do not require plan changes but may warrant attention during implementation:

1. **P3-U08 and P3-U09 are stub tests.** The Phase 3 plan explicitly notes that these tests use `ABORT_IF(true)` because the push-to-queue path is not yet active. They are expected to be fully enabled in Phase 4. This is documented and acceptable.

2. **MS3 mode 4 (EThcD-triggered) test coverage.** The Phase 4 plan notes that MS3 mode 4 is covered by unit tests (P4-U05) but does not have a dedicated regression test (P4-R11). The plan explicitly acknowledges this: "added as P4-R11 if resources allow." The testing strategy lists only 3 MS3 mode regression tests (P4-R08 through P4-R10), consistent with the phase plan.

3. **Phase 0 not mentioned in baseline plan.** The baseline plan's "Phased Migration" section numbers phases 1-8. Phase 0 (baseline capture) is defined in the implementation roadmap and testing strategy but not in the baseline plan. This is by design — Phase 0 is infrastructure setup with no architectural changes — but it is worth noting that the baseline plan text jumps from the "Phased Migration" guiding principles directly to "Phase 1."

4. **Cumulative test counts are consistent.** The roadmap table shows: P0=7, P1=17, P2=23, P3=39, P4=60, P5=66, P6=79, P7=91, P8=98. This matches the per-phase new test counts: 7, 10, 6, 16, 21, 6, 13, 12, 7 = 98 total.

5. **Golden file naming conventions.** Different phase plans use slightly different naming for golden files (e.g., `baseline_phase0.tsv` vs. `standard_dda.tsv` vs. `phase4_standard_dda.tsv`). This is expected as golden files evolve across phases, but implementors should ensure the regression runner script references the correct golden file for each phase's regression tests.

---

## Summary

| Check | Result |
|-------|--------|
| 1. Issue coverage (9 issues) | **PASS** |
| 2. Test coverage (98 test IDs) | **PASS** |
| 3. File coverage | **PASS** |
| 4. Build batching | **PASS** |
| 5. Dependency chain | **PASS** |
| 6. Working product verification | **PASS** |
| Gaps found | **0** |
| Fixes applied | **0** |

# Phase 7: Exploration Engine — Compliance & Feedback Report

**Date:** 2026-04-07
**Scope:** Post-implementation verification of Phase 7 against `implementation-plan.md`, lessons-learned compliance, test quality audit, and pipeline routing verification.

---

## Executive Summary

Phase 7 implementation achieves **overall compliance** with the specification. All critical components (enums, structs, engine methods, JSON parsing, C# serialization, CI registration, golden files) are present and correctly integrated. The pipeline transition from legacy `ms3_enabled_`/`top_n_` to unified `level_configs_` is functional.

**4 tests rated WEAK** due to incomplete behavioral verification (P7-U03, P7-U07, P7-U11, P7-U12). These tests pass CI but verify configuration or side effects rather than the behavioral contracts specified in the plan.

| Category | Status |
|----------|--------|
| Spec compliance (types, methods, parsing) | PASS |
| Lessons learned applied | PASS (all 9) |
| CI registration | PASS |
| Pipeline routing | PASS |
| Tier 1 tests (C++ unit) | 7/11 GOOD+, 4/11 WEAK |
| Tier 3 tests (regression) | PASS |

---

## 1. Specification Compliance

### 1.1 Types and Enums (Steps 1-2) — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| `SelectionMetric` enum (None, Intensity, QScore) | PASS | FLASHIda.h:461-466 |
| `ExplorationMetric` enum (None, MassCount, RemainingPrecursor, FragmentCount) | PASS | FLASHIda.h:469-475 |
| `MSLevelConfig` struct (selection, max_targets, exploration, ce_min/max/step as double, activation, overrides) | PASS | FLASHIda.h:478-489 |
| `hasExploration()` static helper | PASS | FLASHIda.h:494 |
| `ExplorationGroup` struct (all 10 fields) | PASS | FLASHIda.h:933-948 |
| `ExplorationVariant` struct (all 8 fields, collision_energy as double) | PASS | FLASHIda.h:918-930 |
| `VariantRef` struct | PASS | FLASHIda.h:955 |
| Private members (level_configs_, exploration_enabled_, active_exploration_groups_, etc.) | PASS | FLASHIda.h |
| `getLevelConfig_()` accessor with static default | PASS | FLASHIda.h |
| **Lesson #2:** Enums and MSLevelConfig in PUBLIC section | PASS | FLASHIda.h:458-495 |

### 1.2 OptimizationMetadata (Step 1) — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| `exploration_metric` field (int, 19th field) | PASS | OptimizationMetadata.h:31 |
| `toSpectrum()` serializes via setMetaValue | PASS | DeconvolvedSpectrum.cpp:157 |

### 1.3 JSON Parsing (Step 1) — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| `parseSelectionMetric_()` helper | PASS | FLASHIda.cpp |
| `parseExplorationMetric_()` helper | PASS | FLASHIda.cpp |
| `parseLevelConfig_()` helper | PASS | FLASHIda.cpp |
| `selection_strategy` parsing iterates msN keys | PASS | FLASHIda.cpp:3391-3443 |
| `exploration_enabled_` computed from level_configs_ | PASS | FLASHIda.cpp |
| **Lesson #1:** No `ss` variable collision — uses `sel_strategy` | PASS | FLASHIda.cpp:3396 |
| **Lesson #3:** Null guard on exploration: `!level_obj["exploration"].is_null()` | PASS | FLASHIda.cpp:3416 |
| No backwards compat — crash if selection_strategy absent | PASS | FLASHIda.cpp:3392-3394 |

### 1.4 Core Engine Methods (Steps 3-6) — PASS

| Method | Status | Evidence |
|--------|--------|----------|
| `buildCEVariants_()` (vector\<double\>, epsilon guard) | PASS | FLASHIda.cpp:4002-4008 |
| `buildMS2Command_()` overload with explicit CE | PASS | FLASHIda.cpp:4010 |
| `applyOverrides_()` | PASS | FLASHIda.cpp:4046-4057 |
| `initiateExploration_()` | PASS | FLASHIda.cpp:4059-4110 |
| `computeExplorationScore_()` dispatcher | PASS | FLASHIda.cpp:4112 |
| `computeMassCount_()` | PASS | FLASHIda.cpp:4128 |
| `computeRemainingPrecursorScore_()` | PASS | FLASHIda.cpp:4133 |
| `computeFragmentCount_()` | PASS | FLASHIda.cpp:4142 |
| `computeTICCoverage_()` | PASS | FLASHIda.cpp:4147 |
| `feedExplorationResult_()` (full implementation) | PASS | FLASHIda.cpp:4156-4243 |
| `initiateNextLevel_()` | PASS | FLASHIda.cpp |

### 1.5 Pipeline Integration (Steps 5, 7-9) — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Variant tracking before pending_scan_map_ | PASS | FLASHIda.cpp:4302 |
| MS1 cycle time suppression | PASS | FLASHIda.cpp:4427 |
| MS1 branch wires initiateExploration_ | PASS | FLASHIda.cpp:3664-3675 |
| MS3 via initiateNextLevel_ | PASS | FLASHIda.cpp:4371-4392 |

### 1.6 C# Changes (Steps 10, 12c) — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| XML deserialization classes | PASS | MethodConfig.cs |
| JSON serialization classes | PASS | MethodConfig.cs:297-319 |
| `Parameter.ToJSON()` emits selection_strategy | PASS | Parameter.cs:277 |
| Crash if SelectionStrategy absent | PASS | Parameter.cs:305-308 |
| **Lesson #3:** Default exploration block (metric:"none") | PASS | Parameter.cs:338-344 |
| **Lesson #4:** int not int? for max_precursors/max_fragments | PASS | MethodConfig.cs |

### 1.7 Config Files — PASS

| Requirement | Status |
|-------------|--------|
| method_exploration.xml exists with MS2 exploration (mass_count, CE 20-40 step 5) | PASS |
| method_exploration_ms3.xml exists with MS2+MS3 exploration | PASS |
| All 20 method XMLs have SelectionStrategy blocks | PASS |
| phase7_exploration.tsv golden file exists | PASS |

### 1.8 CI Registration — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| FLASHIda_exploration_test in executables.cmake | PASS | Line 456 |
| FLASHIda_exploration_test in flashida-ci.yml build targets | PASS | Line 58 |
| FLASHIda_exploration_test in flashida-ci.yml ctest regex | PASS | Line 63 |
| p7_exploration in regression-runner.ps1 | PASS | Lines 114-120 |

### 1.9 Test Helpers — PASS

All 6 ForTest helpers present with proper `std::lock_guard<std::mutex>` thread safety:
- `getActiveExplorationGroupCountForTest()`, `getExplorationGroupForTest()`, `getLevelConfigForTest()`, `getQueueSizeForTest()`, `initiateExplorationForTest()`, `feedExplorationResultForTest()`

### 1.10 Pipeline Transition (Step 12) — PASS

| Legacy variable | Status | Notes |
|-----------------|--------|-------|
| `top_n_` | REMOVED | Replaced by level_configs_[1].max_targets |
| `exploration_max_depth_` | REMOVED | |
| `exploration_max_variants_` | REMOVED | |
| `ms3_enabled_` | RETAINED | Intentional fallback for legacy configs |

**Note:** `ms3_enabled_` is retained as a controlled fallback path (lines 3887, 4376, 4388). Three-tier MS3 routing: (1) new exploration path via `getLevelConfig_(3)`, (2) legacy fallback via `ms3_enabled_`, (3) new selection-only path. This is acceptable for backward compatibility.

---

## 2. Lessons Learned Compliance

All 9 lessons from `Phase_7/lessons-learned.md` verified as applied:

| # | Lesson | Applied |
|---|--------|---------|
| 1 | Variable name collision (ss → sel_strategy) | YES |
| 2 | Enums must be public | YES |
| 3 | JavaScriptSerializer null → default exploration block + C++ null guard | YES |
| 4 | No nullable int? → plain int | YES |
| 5 | BridgeSmokeTests missing SelectionStrategy | YES |
| 6 | DLL update sequence | YES (documented) |
| 7 | PeakGroup API (getMonoMass, getMzRange, no setIntensity) | YES |
| 8 | Golden file 2-commit capture | YES |
| 9 | Exploration variants produce zero deconvolution in test mode | YES (expected) |

---

## 3. Tier 1: C++ Unit Test Review

### Per-test ratings

| Test | Rating | Key Finding |
|------|--------|-------------|
| **P7-U01** | **STRONG** | All 5 CE values verified individually. Group state assertions complete. |
| **P7-U02** | **STRONG** | Queue population + dequeue verified. Priority 0 confirmed. Scan description checked. |
| **P7-U03** | **WEAK** | Missing `group.winner_index==3` and `group.complete==true` verification. Only checks group removal (side effect). No EXPL-WINNER log check. |
| **P7-U05** | **GOOD** | Correctly verifies MS1 suppression — returned command is exploration variant (msn_level==2), not MS1. |
| **P7-U06** | **GOOD** | Full completion path exercised. MS1 resumes (msn_level==1) confirmed. |
| **P7-U07** | **WEAK** | Only counts child groups (>0, <=3). Missing assertions on msn_level==3, exploration_metric==FragmentCount, parent_tracking_id, queue[0] command count. |
| **P7-U08** | **GOOD** | Correctly distinguishes MS3 selection (queue[1]) from MS3 exploration (queue[0]). Dequeues and verifies msn_level==3, priority==1. |
| **P7-U09** | **GOOD** | All metadata fields verified. Minor deviation: uses 5 variants instead of spec's 2 (total_variants==5 vs spec's 2). |
| **P7-U10** | **STRONG** | Follows all Phase 2 lessons (PeakGroup push, toSpectrum by value, (void)var). MetaValues verified. |
| **P7-U11** | **WEAK** | Only verifies config parsing (getLevelConfigForTest). Does NOT call processScan() or feed MS2 results. Does NOT verify MS3 exploration groups are created. Spec requires behavioral verification. |
| **P7-U12** | **WEAK** | Only verifies config parsing. Does NOT create synthetic MS1 data with differing intensity/qscore order. Does NOT call processScan() to verify actual ranking behavior. |

### Critical gaps

**P7-U03 — Winner selection:** The test verifies the winner was selected (group removed from map) but never inspects `group.winner_index` or `group.complete`. The spec explicitly requires these assertions. This means a bug that selects the wrong winner would not be caught.

**P7-U07 — MS3 exploration child groups:** The test confirms child groups exist but doesn't verify their properties. A bug that creates MS3 groups with wrong exploration_metric or wrong msn_level would pass.

**P7-U11 — Chaining rule:** The spec requires proving that "MS3 exploration triggers immediately from each MS2 result" by calling processScan() and verifying MS3 groups appear. The test only checks config state — it does not exercise the actual triggering logic.

**P7-U12 — Selection metric ranking:** The spec requires creating 5 precursors where intensity order differs from qscore order, then calling processScan() to verify different selections. The test only reads config values.

### Quality rules compliance

| Rule | Status |
|------|--------|
| No soft guards (NOT_TESTABLE, Assume.That, if-guards) | PASS — all assertions hard |
| Separate input/output arrays | PASS |
| No queue passthrough bypassing production logic | PASS — ForTest helpers call production methods |
| (void)var for MSVC /WX | PASS |
| DeconvolvedSpectrum(scan_number) | PASS |
| toSpectrum() returns by value | PASS |
| PeakGroup push before toSpectrum() | PASS (P7-U10) |

### Test count

- **Spec requires:** 11 unit tests (U01-U12, no U04)
- **Implemented:** 11 unit tests
- **Match:** Correct

---

## 4. Tier 3: Regression Test Review

### P7-R01 — Exploration disabled regression — STRONG

- `phase4_standard_dda` entry in regression-runner.ps1 tests `method_default.xml` + `ms1_standard.txt` against `phase4_standard_dda.tsv`
- `method_default.xml` has `<SelectionStrategy>` with no `<Exploration>` sub-elements
- Comparison via `compare_golden.py` with float tolerances (ABS_TOL=1e-6 for |val|<=1.0, REL_TOL=1e-4 for |val|>1.0)

### P7-R02 — Exploration enabled regression — STRONG

- `p7_exploration` entry in regression-runner.ps1 tests `method_exploration.xml` + `ms1_standard.txt` against `phase7_exploration.tsv`
- Golden file: 37 lines (header + 36 data rows), 6 precursors x 6 rows each
- Pattern per precursor: 5 exploration variants (qScore=0, monoMasses=0) + 1 standard MS2 (real deconvolution)
- Exploration variant zero-results are expected behavior in test mode (lesson #9)

### Golden file analysis

- Standard 15-column TSV format (rt, mz1, mz2, qScore, charges, monoMasses, ccos, csnr, cos, snr, cScore, ppm, precursorIntensity, massIntensity, hcd)
- OptimizationMetadata columns NOT present in golden file (test mode serialization doesn't include them in TSV output)
- All 6 standard MS2 rows have qScores in 0.35-0.77 range — realistic
- Same precursor m/z values as phase4_standard_dda.tsv — confirms same input data

### Gap

**No Phase 7 golden capture step in CI.** The spec mentions an "exploration golden candidate upload step" but `flashida-ci.yml` lacks it. Phase 4 has an explicit capture step (lines 142-154) but Phase 7 does not. Impact: medium — regenerating the golden file requires manual artifact extraction.

**`method_exploration_ms3.xml` not tested by regression runner.** The file exists (MS2+MS3 exploration config) but has no regression runner entry. MS3 exploration is covered by C++ unit tests (P7-U07) but not by end-to-end regression.

---

## 5. Pipeline Routing Verification

### Legacy variable scan

| Variable | Status |
|----------|--------|
| `top_n_` | REMOVED |
| `exploration_max_depth_` | REMOVED |
| `exploration_max_variants_` | REMOVED |
| `ms3_enabled_` | RETAINED (intentional fallback) |

### Test JSON configs

**21/21** test JSON configs across all 4 C++ test files include `selection_strategy`. No config will crash the parser.

### Production routing

All tests route through production logic:

| Test file | Tests | Uses processScan/getNextScanCommand | Status |
|-----------|-------|-------------------------------------|--------|
| FLASHIda_exploration_test.cpp | 11 | Yes (ForTest → production methods) | COMPLIANT |
| FLASHIda_ProcessScan_test.cpp | 10 | Yes (processScan + getNextScanCommand) | COMPLIANT |
| FLASHIdaFAIMS_test.cpp | 7 | Yes (processScan + getNextScanCommand) | COMPLIANT |
| FLASHIdaQueueTracking_test.cpp | 6 | Yes (production queue methods) | COMPLIANT |
| BridgeSmokeTests.cs | 5 | Yes (SelectionStrategy in config) | COMPLIANT |

No test bypasses the unified pipeline by setting legacy member variables directly.

### Pipeline trace

| Pipeline point | New config used | Evidence |
|----------------|-----------------|----------|
| MS1 → exploration check | `getLevelConfig_(2)` | FLASHIda.cpp:3665 |
| MS2 → variant routing | `variant_tracking_to_group_` | FLASHIda.cpp:4302 |
| MS2 → MS3 exploration | `getLevelConfig_(3)` | FLASHIda.cpp:4371 |
| MS1 cycle suppression | `active_exploration_groups_` | FLASHIda.cpp:4427 |

---

## 6. Findings Summary

### Issues requiring attention

| # | Severity | Test | Issue |
|---|----------|------|-------|
| 1 | HIGH | P7-U03 | Missing winner_index and group.complete assertions — cannot catch wrong-winner bugs |
| 2 | HIGH | P7-U11 | Config-only test — does not exercise chaining rule behavior |
| 3 | HIGH | P7-U12 | Config-only test — does not exercise selection ranking behavior |
| 4 | MEDIUM | P7-U07 | Missing child group property assertions (msn_level, exploration_metric, parent_tracking_id) |
| 5 | LOW | P7-U09 | Uses 5 variants instead of spec's 2 (total_variants=5 vs spec's 2) — minor param deviation |
| 6 | LOW | CI | No Phase 7 golden capture step in CI workflow |
| 7 | LOW | Regression | method_exploration_ms3.xml not covered by regression runner |

### Strengths

1. All 9 lessons learned properly applied in code
2. Complete type system (enums, structs, maps) matching spec
3. All 21 test JSON configs include selection_strategy
4. All tests route through production pipeline — no bypasses
5. Golden file correctly captures expected exploration pattern (5 variants + 1 standard per precursor)
6. Thread safety maintained (lock_guard on all test helpers)
7. CI registration complete (executables.cmake + both CI lists)
8. Defense-in-depth on null serialization (C# default blocks + C++ null guard)

---

## 7. Definition of Done Checklist

### CI registration
- [x] FLASHIda_exploration_test in executables.cmake
- [x] FLASHIda_exploration_test in flashida-ci.yml build targets
- [x] FLASHIda_exploration_test in flashida-ci.yml ctest regex
- [x] All three in same commit as test file

### Test quality
- [x] All P7-U* use hard assertions (TEST_EQUAL, TEST_REAL_SIMILAR)
- [x] No soft guards or Assume.That
- [x] (void)var for MSVC compliance
- [ ] **P7-U03:** Missing winner_index assertion
- [ ] **P7-U07:** Missing child group property assertions
- [ ] **P7-U11:** Does not exercise behavior (config-only)
- [ ] **P7-U12:** Does not exercise behavior (config-only)

### Functional completeness
- [x] All 13 tests exist (11 unit + 2 regression)
- [x] All enums, structs, methods implemented
- [x] processScan() MS1 branch uses getLevelConfig_
- [x] Cycle time suppression during exploration
- [x] Variant tracking before pending_scan_map_
- [x] feedExplorationResult_ with exploration-metric-based scoring
- [x] initiateNextLevel_ for generic MSn+1
- [x] OptimizationMetadata populated on variants
- [x] Parameter.ToJSON() emits selection_strategy
- [x] method_exploration.xml and golden file committed
- [x] regression runner entry present

### Pipeline transition
- [x] top_n_ removed
- [x] exploration_max_depth_ removed
- [x] exploration_max_variants_ removed
- [x] ms3_enabled_ retained as controlled fallback
- [x] All method XMLs have SelectionStrategy
- [x] All test JSON configs have selection_strategy
- [x] P7-R01 regression gate (exploration disabled = identical output)

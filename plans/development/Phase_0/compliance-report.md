# Phase 0 — Final Compliance Report

**Date:** 2026-03-27
**Sources:** 6 agent reports (lessons learned, test sensibility, impl plan, testing strategy, acq-loop strategy, test file spec)

## Executive Summary

Phase 0 substantially exceeds its original scope. The plan specified 7 test IDs (P0-U01 through U04, P0-I01 through I02, plus the golden baseline); the implementation delivers 39 tests (7 original + 6 extra bridge tests + 28 continuity tests + 2 stress stubs), authorized by a DoD Override on 2026-03-24. All mandated test IDs are present. CI runs green. The golden baseline is captured and committed. Infrastructure (compare_golden.py, regression-runner.ps1, prepare-test-data.py, NUnit project, CI workflow) is functional and passing.

However, the quality of assertions in many continuity tests is weaker than their names and specifications promise. Five tests are rated PROBLEMATIC (CT13, CT14, CT17, CT22, CT27) -- their assertions are either tautological, vacuously satisfiable, or entirely absent. Nine additional tests are rated WEAK, with assertions that are too lenient (>= 0 instead of > 0) or that verify a weaker property than the test name claims. The golden-file behavioral reference tests (9 total) partially compensate for these weak inline assertions, but the gap between test names and actual verification remains a concern for future phases that will rely on these tests as regression guards. Additionally, the continuity test harness bypasses the DataPipe async pipeline entirely, meaning no Phase 0 test exercises the actual production data flow path.

Seven documented deviations and seven undocumented deviations from the implementation plan were identified. All documented deviations are justified and recorded in lessons-learned.md. The undocumented deviations are minor (build output paths, .csproj structural details, CI runner paths) but should be noted for future-phase implementers. The test-file-specification.md still describes a spectrum header format that does not match the working code, and the acquisition-loop-testing-strategy.md specifies Tier 1 labels for tests that are implemented as Tier 2.

## Findings by Severity

### Critical

No critical findings. All mandated deliverables are present and CI is green.

### High

**H-1. Five PROBLEMATIC tests have assertions that cannot fail on behavioral grounds**
- **CT13 (InclusionList_OnlyListedMasses):** Claims to verify only included masses produce MS2; actually checks `PrecursorMz > 0`, which is trivially true for any scan command. (Agents 1, 4)
- **CT14 (ExclusionList_ExcludedMassesSuppressed):** Same issue -- checks `PrecursorMz > 0` instead of verifying excluded masses are absent. (Agents 1, 4)
- **CT17 (TagTargeting_TriggersFollowUpMS2):** Only pushes MS1 and checks `ScanType == "MSn"`, which is true for all DDA modes. Does not exercise the MS1->MS2->follow-up chain the spec requires. (Agents 1, 4)
- **CT22 (MS3Enabled_MsnLevel3RecordsExist):** Filters results to MsnLevel==3, then asserts they are MsnLevel==3 (tautology). Does not require ms3Results.Count > 0, so it passes silently when no MS3 records are produced. (Agents 1, 4)
- **CT27 (FAIMSAdaptiveSkip_LowPrecursorCVLessFrequent):** Ends with `Assert.Pass()` -- unconditionally passes. Collected results are never analyzed. (Agents 1, 4)
- **Mitigation:** Golden-file tests (CT15, CT16, CT19, CT24-26, CT28) partially compensate by capturing full behavioral output. However, golden-file changes in future phases could silently break these invariants.

**H-2. ContinuityTestHarness bypasses DataPipe -- no async pipeline coverage**
- The acquisition-loop-testing-strategy specifies the harness should wrap `DataPipe` for full async pipeline testing. The actual implementation calls `Processor.ProcessMS()` and `OutputMS()` directly, bypassing async timing, ordering, and backpressure behavior entirely. (Agent 4)
- **Impact:** Phase 3 (ScanCommand), Phase 4 (unified bridge), and Phase 5 (processor refactor) all modify the DataPipe path. No baseline test exercises it.

**H-3. Continuity golden-file comparison uses exact string equality instead of tolerance-based comparison**
- The acquisition-loop-testing-strategy specifies 1e-4 relative tolerance for float fields (masses, collision energies). The implementation serializes `ScanCommandRecord` to JSON and uses exact string comparison. Any floating-point drift (e.g., from compiler or runtime changes) will cause spurious failures. (Agent 4)

**H-4. Tier label mismatch: all 28 AL-CT tests labeled Tier2, spec says Tier1**
- The acquisition-loop-testing-strategy Section 5 classifies AL-CT01 through CT28 as Tier 1 (unit tests). The implementation labels them `Category("Tier2")`. (Agent 4)
- **Documented in lessons-learned:** Yes -- rationale is that tests load OpenMS.dll, matching the existing Tier 2 convention for DLL-dependent tests. This is a reasonable practical decision but creates a discrepancy with the spec.

### Medium

**M-1. Nine WEAK tests with overly lenient assertions**
- **I03 (DeconvolveMS2_ReturnsNonNegativePeakGroups):** Asserts `>= 0` instead of `> 0`. Would pass if engine returned 0 (silent failure). (Agent 1)
- **I04 (ProcessMS2ForTagBasedTargeting_DoesNotCrash):** Contains dead assertion `Is.TypeOf<bool>()` -- compile-time guaranteed. (Agent 1)
- **I05 (GetBestMS2Masses_ReturnsResults):** Name says "ReturnsResults" but asserts `>= 0`. (Agent 1)
- **I06, I07, I08:** Valid crash guards but assertions do not match names implying functional verification. (Agent 1)
- **CT09 (FAIMS_CVCycling_3CVsInOrder):** Spec requires verifying cycling ORDER; implementation only checks set membership. (Agents 1, 4)
- **CT10 (FAIMS_MS2CarriesParentCV):** Spec requires per-CV linkage verification; implementation only checks set membership. (Agents 1, 4)
- **CT18 (ConditionalMS2_FollowUpOnlyWhenTagsDetected):** Only checks initial batch count, not the tag success/failure follow-up flow. (Agents 1, 4)
- **CT01 (StandardDDA_PrecursorMasses):** Spec requires matching against deconvolved targets within 0.01 Da; implementation only checks within scan range. (Agent 4)

**M-2. Seven undocumented deviations from the implementation plan**
- Build output path `FlashIDA/bin/` vs plan's `FlashIDA/src/Flash/bin/Debug/` (pervasive, affects .csproj, CI, tests, regression runner). (Agents 0, 2)
- DLL name `"OpenMS.dll"` vs plan's `"OpenMS"` in P/Invoke declarations. (Agent 2)
- NUnit3TestAdapter.targets import omitted from .csproj. (Agent 2)
- Extra .csproj references (Thermo DLLs, Microsoft.CSharp, log4net) needed for compilation. (Agent 2)
- NUnit runner invoked by full path in CI. (Agent 2)
- Bridge verification uses `@classname` filter instead of `@categories`. (Agent 2)
- `compare_golden.py --help` sanity check removed from CI. (Agent 2)

**M-3. Test-file-specification still documents wrong spectrum header format**
- Spec says `Spec <id> rt=<minutes>` (space-separated, minutes, `rt=` prefix). Actual working format is `Spec <id>\t<seconds>` (tab-separated, seconds, no prefix). Lessons-learned #8 says the spec should be updated. (Agents 0, 5)

**M-4. `Flash.exe -t` references persist in Phase 1-3 plans and root CLAUDE.md**
- Phase 1: 10+ references, Phase 2: 8 references, Phase 3: 5+ references. Root CLAUDE.md line 38 also affected. (Agent 0)
- Implementers following these plans verbatim will hit the same issue discovered in Phase 0.

**M-5. CT08 (TopN) uses `<=` assertion instead of spec's "exactly 5"**
- Spec says "verify exactly 5 MS2 records returned." Implementation asserts `results.Count <= maxPerMs1 * ms2Types`, which is weaker. Also multiplies by ms2Types, which the spec does not mention. (Agent 4)

**M-6. Stress tests CT31/CT32 stubbed with [Ignore], spec says "Introduced: Phase 0"**
- Both tests are present but `[Ignore]`d with `Assert.Inconclusive`. The acquisition-loop-testing-strategy says they are introduced in Phase 0. Deferral to Phase 3 is not formally documented. (Agent 4)

### Low

**L-1. P0_U01 (SolutionCompilesWithoutError) uses `Assert.Pass()` -- cannot fail at test time**
- The test is a build-gate sentinel: if the test assembly loaded, the build succeeded. But `Assert.Pass()` is trivially true at runtime. Better served by a CI build step. (Agent 1)

**L-2. `compare_golden.py` has narrow column classification**
- Only classifies `charges` as string and `hcd` as integer. All other columns treated as float. New columns added in future phases may be incorrectly parsed. (Agent 0)

**L-3. CT07 (TrackingIDs) checks full ScanDescription uniqueness, not tracking ID substrings**
- Spec says to extract tracking ID substrings from ScanDescription. Implementation checks full string uniqueness. This is a stronger assertion but deviates from the spec. (Agent 4)

**L-4. CT12 (DeepMode_MorePrecursors) uses `>=` instead of `>`**
- If deep mode produces the same count as standard DDA, the test still passes. With rich enough test data, `>` would be a stronger assertion. (Agent 1)

**L-5. `.gitignore` structure differs from plan but is functionally equivalent**
- Root `.gitignore` only has `FlashIDA/test-output/`. Plan's other entries are covered by `FlashIDA/.gitignore`. (Agent 2)

**L-6. `method_deep.xml` parameter names do not match spec**
- Spec says "Higher MaxMassCount, lower ScoreThreshold." Actual mechanism is `TargetingMode=Deep` with `MaxMs2CountPerMs1=5` and unchanged `QScoreThreshold=.0`. The spec's parameter names (`MaxMassCount`) do not correspond to any XML element. (Agent 5)

**L-7. `method_exclusion.xml` has empty exclusion list**
- Spec says it should contain "a mass present in `ms1_standard.txt`." Since `ms1_standard.txt` does not exist yet (Phase 4), the exclusion list is empty. (Agent 5)

**L-8. regression-runner.ps1 default FlashExe path differs from spec**
- Spec: `FlashIDA\src\Flash\bin\Debug\Flash.exe`. Actual: `FlashIDA\bin\Flash.exe`. Functionally correct. (Agents 2, 5)

### Info

**I-1. Documented deviations (all justified)**
- Flash.exe invocation: no `-t` flag (LL #1)
- Spectrum header format: tab + seconds (LL #2, #8)
- ms1_smoke_test.txt: 6588 peaks, 2 scans (LL #6, #7)
- Thermo DLL encryption: Strategy B / openssl (LL #3)
- OpenMS DLLs: committed in repo, no download (LL #5)
- NuGet package name: `NUnit.ConsoleRunner` (LL table)
- Tier labels: Tier2 for DLL-dependent tests (LL table)

**I-2. Extra deliverables (authorized by DoD Override 2026-03-24)**
- BridgeMS2Tests.cs: 6 additional bridge tests (P0-I03 through I08)
- ms2_smoke_test.txt: 4781-line MS2 spectrum
- Mock infrastructure: 6 files (MockMsScan, MockScanFactory, ContinuityTestHarness, etc.)
- ContinuityTests.cs: 28 functional + 2 stub tests
- 11 mode-specific config files + 2 supporting data files
- 9 continuity golden JSON files
- Production code modifications: ScanFactory.cs virtual, 3 processors with wrapper param

**I-3. Unspecified files that should be documented**
- `ms2_smoke_test.txt`, `method_default_topn5.xml`, `test_inclusion_list.txt`, `test_fasta.fasta` are not in the test-file-specification but are required by implemented tests. (Agent 5)
- 9 continuity golden JSON files use a different schema (scan command objects) than the TSV golden files the spec describes. (Agent 5)

**I-4. ms1_smoke_test.txt exceeds spec size target**
- 143 KB actual vs spec's < 20 KB target. Direct consequence of needing 6588 peaks for detectable charge envelopes. (Agent 5)

**I-5. cpp-unit-tests CI job has never executed**
- Has `if: false` in workflow. Phase 2 is the first phase to activate it. Build resource requirements (7 GB RAM, 2-core runner) are untested. (Agent 0)

**I-6. Submodule update workflow doubles commit count**
- 13 of 27 Phase 0 fix commits (48%) are "Update FlashIDA submodule" commits. Expected to continue in future phases. (Agent 0)

**I-7. `.gitattributes` `* text eol=crlf` is a persistent hazard for new binary types**
- Current exceptions cover .enc, .gpg, .zip, .dll, .pdf. Any new binary file type must be added before committing. (Agent 0)

**I-8. OpenMP/CLR thread pool interaction is an unresolved concern**
- Not the root cause in Phase 0 (multi-scan parsing was), but remains a plausible failure mode for Phase 3+ concurrent pipeline testing. (Agent 0)

**I-9. MockScanFactory deviation from spec**
- Spec shows `List<CapturedScan>` with timestamp wrapper. Implementation uses `List<IFusionCustomScan>` directly (no timestamp). (Agent 4)

## Cross-Report Conflicts Resolved

**Conflict 1: CT01 -- SENSIBLE (Agent 1) vs DEVIATED (Agent 4)**
Agent 1 rated CT01 as SENSIBLE because it validates precursor masses are positive and within scan range. Agent 4 rated it DEVIATED because the spec requires matching against deconvolved targets within 0.01 Da tolerance. Resolution: **DEVIATED from spec, but not senseless.** The test checks a real property (scan-range bounds) that is weaker than specified. Classified as MEDIUM (M-1) rather than HIGH because the golden-file test (CT06) captures the exact precursor masses for regression.

**Conflict 2: CT08 -- SENSIBLE (Agent 1) vs DEVIATED (Agent 4)**
Agent 1 rated CT08 as SENSIBLE because the `<=` assertion with the ms2Types multiplier is a correct upper-bound invariant. Agent 4 rated it DEVIATED because the spec says "verify exactly 5 MS2 records." Resolution: **DEVIATED from spec but tests a valid invariant.** The `<=` assertion is less strict than the spec's "exactly 5" but prevents false negatives from test data that might not produce exactly 5 targets. Classified as MEDIUM (M-5).

**Conflict 3: CT31/CT32 -- SENSIBLE (Agent 1) vs DEVIATED (Agent 4)**
Agent 1 rated the stubs as SENSIBLE (properly marked as `[Ignore]` placeholders). Agent 4 rated them DEVIATED because the spec says "Introduced: Phase 0." Resolution: **Both are correct in their framing.** The stubs are well-formed placeholders (Agent 1's point), but they deviate from the spec which expects actual implementation in Phase 0 (Agent 4's point). Classified as MEDIUM (M-6) because deferral to Phase 3 is a reasonable scope decision that should be formally documented.

**Conflict 4: Tier labels -- documented vs undocumented**
Agent 3 does not flag the tier label mismatch as a concern. Agent 4 flags it as a systematic deviation. The existing lessons-learned.md documents the rationale. Resolution: Classified as HIGH (H-4) because it is a systematic mismatch across 28 tests, but mitigated by the documented rationale.

**Conflict 5: CT24-26 -- SENSIBLE (Agent 1) vs DEVIATED (Agent 4)**
Agent 1 rated the MS3 behavioral reference tests as SENSIBLE. Agent 4 notes they use `Take(1)` and bypass the harness. Resolution: The `Take(1)` limits output capture and direct Factory access means these tests do not flow through the standard harness. Classified as part of the broader DataPipe bypass issue (H-2) rather than a standalone finding.

## Additional Lessons Learned (from Agent 0)

The following findings from Agent 0 are NOT already documented in `plans/development/Phase_0/lessons-learned.md`:

1. **Flash.exe -t references persist in Phase 1-3 plans** (Agent 0, finding #1): 10+ references in Phase 1, 8 in Phase 2, 5+ in Phase 3, plus root CLAUDE.md. These will mislead future implementers.

2. **Build output path discrepancy is pervasive but undocumented** (Agent 0, finding #2): The `FlashIDA/bin/` vs `FlashIDA/src/Flash/bin/Debug/` discrepancy affects Phase 0 plan Steps 1.1, 7.2, 8 and also Phase 3 line 1361 and test-file-specification.md lines 443, 453.

3. **Thermo interface mocking took 9 iterative commits** (Agent 0, finding #3): Proprietary interfaces without public documentation require CI-based trial-and-error. Budget 2-3 extra CI round-trips per phase that touches Thermo interfaces.

4. **NUnit working directory and DLL search path** (Agent 0, finding #4): NUnit must be run from `FlashIDA/bin/` for native DLLs to be found. Relative paths in tests depend on this specific working directory.

5. **CI golden-file capture requires 2 commits minimum** (Agent 0, finding #6): First commit runs CI and produces the artifact; second commit includes the golden file for comparison. Phases with multiple golden files should batch captures.

6. **cpp-unit-tests job is untested** (Agent 0, finding #7): Phase 2 should do a dry-run activation before adding code changes. Resource constraints on ubuntu-latest runners are unknown.

7. **`.gitattributes` blanket CRLF rule** (Agent 0, finding #8): Current binary exceptions are minimal. New binary file types will be silently corrupted if not excluded before committing.

8. **Submodule update churn** (Agent 0, finding #9): 48% of Phase 0 commits were submodule pointer updates. Batch same-side changes to reduce churn in Phases 1-3.

9. **`compare_golden.py` narrow column classification** (Agent 0, finding #10): Only `charges` and `hcd` are classified. New columns in future phases must update this script.

10. **Phase 0 plan inaccuracies were NOT corrected in the plan document** (Agent 0, finding #11): Wrong entry point, NuGet name, build paths, CI strategy, and spectrum spec remain in the plan. The lessons-learned is the authoritative correction layer.

11. **Silent zero-result failures from P/Invoke calls** (Agent 0, finding #5): The C++ engine returns 0 results without error codes when data format is wrong. Future phases should log input data characteristics when deconvolution returns 0.

12. **OpenMP/CLR thread interaction** (Agent 0, finding #12): Not the root cause in Phase 0 but a valid diagnostic hypothesis for Phase 3+ concurrent pipeline testing.

## Recommendations

Ordered by priority. Items marked (Phase 0) should be addressed before Phase 1 begins. Items marked (Phase 1+) are inputs to future phase planning.

### Before Phase 1

1. **Document the stress test deferral** (M-6): Add a note to lessons-learned.md explaining that CT31/CT32 are deferred to Phase 3, with rationale.

2. **Update root CLAUDE.md** (M-4): Replace `Flash.exe -t` with the correct invocation pattern `Flash.exe <input> <output> <method.xml> [ms2_file]`.

3. **Document undocumented deviations** (M-2): Add a supplemental note to lessons-learned.md covering the build output path (`FlashIDA/bin/`), DLL name format, and extra .csproj references.

4. **Update test-file-specification.md spectrum header format** (M-3): Change the documented format from `Spec <id> rt=<minutes>` to `Spec <id>\t<seconds>` per lessons-learned #8.

### During Phase 1

5. **Fix `Flash.exe -t` references in Phase 1 plan** (M-4): Replace all 10+ occurrences before beginning implementation.

6. **Add unspecified test files to test-file-specification.md** (I-3): Document `ms2_smoke_test.txt`, `method_default_topn5.xml`, `test_inclusion_list.txt`, `test_fasta.fasta`, and the 9 continuity golden JSON files.

### During Phase 3

7. **Strengthen PROBLEMATIC test assertions** (H-1): When Phase 3 refactors scan processing, strengthen CT13, CT14, CT17, CT22, and CT27 to test the invariants their names claim. Add `Assert.That(count, Is.GreaterThan(0))` where applicable; replace `Assert.Pass()` with actual behavioral checks.

8. **Implement stress tests CT31/CT32** (M-6): As originally deferred to Phase 3.

9. **Consider tolerance-based golden comparison for continuity tests** (H-3): Implement float-tolerance comparison for JSON golden files, or document why exact string match is acceptable.

### During Phase 4

10. **Update `compare_golden.py` column classification** (L-2): When new columns are added to TSV output, add them to the STRING_COLUMNS or INT_COLUMNS sets as appropriate.

### Long-term / Continuous

11. **Read previous phase's lessons-learned before starting a new phase** (Agent 0, finding #11): The lessons-learned is the authoritative correction layer over implementation plans.

12. **Budget extra CI round-trips for Thermo interface mocking** (Agent 0, finding #3): 2-3 extra cycles per phase that touches proprietary interfaces.

13. **Consider DataPipe integration testing** (H-2): No current test exercises the async pipeline. Consider adding harness-level DataPipe wrapping when Phase 3 or 4 modifies the pipeline path.

14. **Add binary extensions to .gitattributes proactively** (I-7): Before committing any new binary file type (mzML, protobuf, compiled resources), add the extension with `binary` attribute.

15. **Dry-run cpp-unit-tests CI activation in Phase 2** (I-5): Activate the job with `if: true` in a separate commit before adding Phase 2 code, to validate build times and resource constraints.

# Phase 8: Cleanup + Documentation — Implementation Plan

**Date:** 2026-03-21 (updated 2026-04-07 with Phase 6 and Phase 7 lessons)
**Build:** Build #4 (ships together with Phase 7). Build #4 is the final C++ build. Phase 7 adds the exploration engine; Phase 8 polishes and hardens everything. All C++ changes for both phases should be batched to minimize DLL rebuild cycles (~40 min each).
**Status:** Final phase of the FLASHIda v9 migration
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 7 and Phase 8 specification
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 8 roadmap entry
- [../testing-strategy.md](../testing-strategy.md) — Phase 8 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative format, content, and naming specification for all test data files (spectrum files, golden TSVs, config XMLs, test scripts)
- [../Phase_6/lessons-learned.md](../Phase_6/lessons-learned.md) — 15 lessons from Phase 6 (FAIMS absorption)
- [../Phase_6/compliance-report.md](../Phase_6/compliance-report.md) — Phase 6 compliance audit findings
- [../Phase_5/lessons-learned.md](../Phase_5/lessons-learned.md) — 4 lessons from Phase 5 (C# simplification)
- [../Phase_7/lessons-learned.md](../Phase_7/lessons-learned.md) — 9 lessons from Phase 7 (exploration engine)
- [../Phase_7/compliance-report.md](../Phase_7/compliance-report.md) — Phase 7 compliance audit findings (4 WEAK tests, method name corrections)

---

## Goal

Remove all legacy bridge infrastructure and dead C# code, leaving exactly 5 exported bridge
functions. Eliminate the legacy config parsing path so JSON is the only accepted format.
Add `MethodDocGenerator.cs` as a reflection utility for `[Description]` attribute-driven
documentation. This phase produces the permanent, final form of the bridge API.

After this phase:

- `OpenMS.dll` exports exactly 5 symbols: `CreateFLASHIda`, `DisposeFLASHIda`, `ProcessScan`,
  `GetNextScanCommand`, `GetNextTrackingId`.
- `FLASHIdaWrapper.cs` contains exactly 5 `[DllImport]` declarations.
- No C# code references removed bridge functions, `ToFLASHDeconvInput()`, or legacy parsing.
- The C++ constructor rejects non-JSON input (no `parseLegacy` fallback).
- `MethodDocGenerator.cs` is present and produces correct output.
- The full regression suite passes against Phase 7 golden files.
- `msbuild Flash.sln /warnaserror` succeeds with zero warnings.

---

## Prerequisites

The following must be true before starting Phase 8:

1. **Phase 7 is complete and verified.** The exploration engine is implemented: `ExplorationGroup`/`ExplorationVariant` structs in `FLASHIda.h`, `initiateExploration_()`, `feedExplorationResult_()` (4-parameter: group_id, variant_index, ms2_deconv, rt), `initiateNextLevel_()`, `computeExplorationScore_()`, `buildCEVariants_()` in `FLASHIda.cpp`, MS1 cycle time suppression during active exploration, `variant_tracking_to_group_` lookup routing in `processScan()` MS2 path. All Phase 7 working product verification criteria pass. Phase 7 golden files are committed to `FlashIDA/test-data/golden/` (including `phase7_exploration.tsv`). `method_exploration.xml` exists in `FlashIDA/test-data/configs/`. `Parameter.ToJSON()` serializes the full `<SelectionStrategy>` block. The Phase 7 implementation plan is marked done.

2. **Build #4 C++ compilation of Phase 7 has succeeded.** The exploration engine changes are
   compiled into `OpenMS.dll` and the DLL artifact is committed in `FlashIDA/dll/` (OpenMS
   DLLs are committed to the repo, not downloaded -- Phase 0 lesson #5). Verify
   `build_dlls.yml` passed on the `flashida-v9-bridge` branch before starting Phase 8 C++
   changes; each failed DLL build wastes ~40 minutes (Phase 1 lesson #10). Note: the
   `build_dlls.yml` workflow only builds, it never runs CTest (Phase 6 lesson 11). C++
   tests only execute in the parent repo CI. Batch all Phase 8 C++ edits (Steps 2-5) into
   a single push to minimise rebuild cycles.

3. **All prior regression tests pass.** Every test from P0 through P7 passes on the
   Build #4 artifact. No test regressions are open. Cumulative test counts: Phase 2 = 59,
   Phase 4 = ~70, Phase 5 = 77, Phase 6 = ~90, Phase 7 = ~103 (13 new: 11 unit + 2 regression). Phase 8 adds 7 more,
   bringing the final cumulative count to ~110.
   Note: P5-U03 (`DeadCodeTests.cs`) was never implemented. P6-U07/U08 (dead code tests)
   were removed from scope per user direction; dead code verification was done via manual
   grep instead. Phase 8's P8-U02 serves as the automated dead code verification test.

4. **No callers of the old bridge functions remain.** Phase 4 (ProcessScan full routing),
   Phase 5 (C# simplification), and Phase 6 (FAIMS absorption) removed all C#-side
   calls to the 18 functions being deleted in this phase. Phase 6 deleted both
   `ScanScheduler.cs` and `FAIMSScanProcessor.cs`, which were the last callers of
   `GetIsolationWindows`, `GetAllMonoisotopicMasses`, `GetAllPeakGroupSize`,
   `GetRepresentativeMass`, and `RemoveFromExclusionList`. Verify with the dead-code grep
   described in Step 1 below before touching any C++ code.

5. **Legacy config format is no longer passed from C#.** Phase 1 (JSON Configuration)
   switched `FLASHIdaWrapper.cs` to pass JSON via `Parameter.ToJSON()`. The legacy
   space-delimited string path must not be reachable from any live C# code path.

6. **ScanCommand struct is in its final form (1248 bytes).** The struct includes all fields
   accumulated through Phases 3-6: `scan_id` as the first field (Phase 3 cache alignment
   deviation), `uint64_t enqueue_timestamp_ms` and 11 scoring fields (added in Phase 4,
   total +96 bytes over Phase 3, bringing ScanCommand from 1144 to 1240 bytes), `double
   faims_cv` at offset 1240 (added in Phase 6, bringing ScanCommand to 1248 bytes).
   `static_assert(sizeof(ScanCommand) == 1248)` in `FLASHIda.h` line 109.
   `IsolationStage` has `collision_energy` as `double` (not `int`) and `activation_type` as
   `char[32]` (not `char[16]`), totaling 80 bytes. Both C++ `static_assert` values and C#
   `Marshal.SizeOf` expectations reflect the final sizes. Phase 7 does NOT modify the struct.
   Phase 8 does NOT modify the struct. If any late-breaking need arises, the 6-file lockstep
   rule applies (Phase 6 lesson 15): `FLASHIda.h`, `FLASHIda.cpp`, `ScanCommandLayout_test.cpp`,
   `FLASHIdaWrapper.cs`, `ScanCommandLayoutTests.cs` (size assertion), `ScanCommandLayoutTests.cs`
   (offset assertion for new field). See "Phase 3-7 Deviations Impact" section below for the
   complete layout.

7. **CI includes all Phase 7 C++ test binaries.** After Phase 7, `flashida-ci.yml` must
   include 6 test binaries in both `cmake --build --target` and `ctest -R`:
   `DeconvolvedSpectrum_OptimizationMetadata_test`, `FLASHIdaQueueTracking_test`,
   `FLASHIda_ProcessScan_test`, `ScanCommandLayout_test`, `FLASHIdaFAIMS_test`,
   `FLASHIda_exploration_test`. Verify this before starting Phase 8.

8. **ProcessScan bridge accepts `double faims_cv` parameter.** The bridge function signature
   was extended in Phase 6. All pipeline paths route through:
   `Instrument -> Flash.ProcessSpectrum -> DataPipe -> UnifiedScanProcessor.ProcessMS
   -> FLASHIdaWrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc, faimsCv)
   -> C++ ProcessScan bridge -> FLASHIda::processScan(... faims_cv)
   -> FLASHIdaWrapper.GetNextScanCommand -> ScanFactory.BuildFromCommand -> Instrument`

### User-Provided Inputs

No new user-provided data is required for Phase 8. All spectrum files, golden files, and config files were established in prior phases. Phase 8 is a cleanup and documentation phase.

---

## Phase 3-7 Deviations Impact

Phase 8 inherits accumulated struct changes and CI policy changes from Phases 3-7. All verification tests in this phase must use the final struct layouts, not the originally planned layouts from the Phase 3 spec.

### Struct Layout: Final State After All Phases

**IsolationStage (80 bytes, verified by `static_assert`):**

| Field | Type | Phase 3 deviation |
|-------|------|-------------------|
| `precursor_mz` | double | Unchanged |
| `isolation_width` | double | Unchanged |
| `collision_energy` | **double** | Was `int` in original plan; supports fractional CE values (Phase 7 uses fractional CE for exploration variants) |
| `reaction_time` | double | Reordered |
| `reagent_max_it` | double | Reordered |
| `reagent_agc_target` | int32_t | Unchanged type |
| `charge_state` | int32_t | Renamed from `charge` |
| `activation_type` | **char[32]** | Was `char[16]` in original plan; accommodates longer names like EThcD |

**ScanCommand (1248 bytes, verified by `static_assert` in `FLASHIda.h` line 109):** The struct size is NOT the original 1144 bytes (nor 1152). Phase 4 added `uint64_t enqueue_timestamp_ms` (8 bytes) AND 11 scoring fields (totaling 88 bytes of data + `Pad2` for alignment), bringing the struct from 1144 to **1240 bytes**. Phase 6 added `double faims_cv` (8 bytes at offset 1240), bringing the struct to **1248 bytes**. Phase 7 does NOT modify the struct. The Phase 8 `static_assert` and C# `Marshal.SizeOf` tests must verify the final size that includes all additions. The `FaimsCv` offset assertion at 1240 must be present in `ScanCommandLayoutTests.cs` (Phase 6 lesson 15). Key field order and additions:

| Field | Type | Notes |
|-------|------|-------|
| `scan_id` | int32_t | **First field** (not `msn_level` — Phase 3 cache alignment deviation) |
| `msn_level` | int32_t | Moved from offset 0 |
| `num_stages` | int32_t | Renamed from `num_isolation_stages` |
| `stages[10]` | IsolationStage[10] | 80 bytes each = 800 bytes |
| `max_it` | double | |
| `agc_target` | int32_t | |
| `orbitrap_resolution` | int32_t | |
| `analyzer` | char[32] | |
| `faims_cv` | **double** | **Added in Phase 6** (deferred from Phase 3) |
| `scan_description` | char[256] | |
| `priority` | int32_t | |
| `enqueue_timestamp_ms` | **uint64_t** | **Added in Phase 4** |
| `is_agc` | int32_t | |
| `quality_score` | **double** | **Added in Phase 4** (scoring field) |
| `total_snr` | **double** | **Added in Phase 4** (scoring field) |
| `monoisotopic_snr` | **double** | **Added in Phase 4** (scoring field) |
| `charge_score` | **double** | **Added in Phase 4** (scoring field) |
| `isotope_cosine` | **double** | **Added in Phase 4** (scoring field) |
| `avg_mass_ppm_error` | **double** | **Added in Phase 4** (scoring field) |
| `mass_count` | **int32_t** | **Added in Phase 4** (scoring field) |
| `avg_mass` | **double** | **Added in Phase 4** (scoring field) |
| `charge_range_low` | **int32_t** | **Added in Phase 4** (scoring field) |
| `charge_range_high` | **int32_t** | **Added in Phase 4** (scoring field) |
| `representative_charge` | **int32_t** | **Added in Phase 4** (scoring field) |
| `Pad2` | **int32_t** | **Added in Phase 4** (alignment padding) |

Note: The exact field order and offsets within `ScanCommand` may differ from the table above due to alignment padding. Consult the Phase 4 and Phase 6 implementation plans for the authoritative field order. The key invariant is that Phase 8 verification tests must use the actual final layout, not any intermediate version.

**Phase 5 confirmed:** ScanCommand size unchanged through Phase 5 (still 1240 bytes post-Phase 4). Phase 5 is C#-only; no struct changes. The `faims_cv` field was added in Phase 6, bringing ScanCommand to 1248 bytes (`static_assert(sizeof(ScanCommand) == 1248)` in `FLASHIda.h` line 109, `faims_cv` at offset 1240). Phase 7 does NOT modify the struct. Phase 5 compliance flagged CT09/CT10 soft guards (HIGH severity) -- these were hardened in Phase 6. CT22 (if-guarded MS3) and CT18 (Assume.That) remain in the backlog.

### CI Policy: TRACK-CREATE Hard-Fail

The CI `[TRACK-CREATE]` check is a **hard-fail gate** (established by Phase 3 compliance finding F-5, carried forward through all subsequent phases). All Phase 8 regression tests (P8-R01) must produce `[TRACK-CREATE]` entries in stdout or CI will fail. This applies to every one of the 10 regression config runs.

### Fractional Collision Energy

`collision_energy` is `double` throughout the system. Phase 7's exploration engine uses fractional CE values (e.g., CE sweep from 20.0 to 40.0 with step 5.0). The Phase 8 full regression suite (P8-R01) includes `method_exploration.xml` which exercises fractional CE. The `compare_golden.py` tolerance rules handle this correctly (floating-point comparison with relative tolerance 1e-4 for values > 1.0).

---

## Phase 5 Addendum (2026-04-05)

*Updates based on Phase 5 actual outcomes and lessons learned. See `Phase_5/compliance-report.md` and `Phase_5/lessons-learned.md` for full details.*

**Phase 5 status: COMPLETE.** FAIMSScanProcessor retained with full legacy path (`GetIsolationWindows` -> `ScanFactory` -> `ScanScheduler`). ScanScheduler also retained. Both were deleted in Phase 6. By Phase 8, all callers of the legacy bridge functions are gone.

**Cumulative test count at Phase 5: 77.** 5 new tests (P5-U01, P5-U02, P5-U04, CT27 activated, CT28 activated). P5-U03 (`DeadCodeTests.cs`) was not implemented -- gap carried forward; P6-U07/U08 also removed from scope; P8-U02 provides automated dead code verification.

**FAIMS TSV golden files not captured.** `Flash.exe` test mode bypasses the entire C# acquisition loop -- it ignores the `cv=` field, has no per-CV routing. P8-R01 regression configs for FAIMS cannot produce meaningful FAIMS-specific output. FAIMS coverage for Phase 8 final verification relies on continuity tests (CT09/CT10/CT27/CT28).

**Test quality expectations.** Phase 5 compliance found P5-U01 rated WEAK (tautological: `new X(null)` + `IsNotNull`). Phase 8's P8-U01/U02/U03 tests must test meaningful behavioral properties:
- P8-U01: counts DllImport declarations (structural, non-tautological)
- P8-U02: scans source tree for dead references (structural, non-tautological)
- P8-U03: calls MethodDocGenerator and verifies output contains known field names (behavioral)

**Legacy bridge functions now fully removed.** Phase 6 deleted `ScanScheduler.cs` and `FAIMSScanProcessor.cs`, which were the last callers of `GetIsolationWindows`, `GetAllMonoisotopicMasses`, `GetAllPeakGroupSize`, `GetRepresentativeMass`, and `RemoveFromExclusionList`. By Phase 8, all callers are gone -- confirming the function removal list is still valid.

**CT09/CT10 soft guards resolved in Phase 6.** CT09 was hardened to hard assertion on `Count > 0` in Phase 6 Step 0. CT10 now has hard assertion verifying MS2 parent CV. Both rated GOOD in the Phase 6 compliance audit. **Remaining test quality issues:** CT22 has if-guarded assertions (can pass with zero MS3 results). CT18 has `Assume.That` soft guards (test skips if Count <= 0). These are in the backlog but do not block Phase 8.

---

## Phase 6 Addendum (2026-04-07)

*Updates based on Phase 6 actual outcomes, compliance report, and 15 lessons learned. See `Phase_6/lessons-learned.md` and `Phase_6/compliance-report.md` for full details.*

**Phase 6 status: COMPLETE.** FAIMS CV cycling state machine ported to C++. `ScanScheduler.cs` and `FAIMSScanProcessor.cs` are deleted and removed from `Flash.csproj`. The only remaining reference is a comment in `Flash.cs` (line 283). All FAIMS CV cycling is handled by C++ via `processScan()` and `getNextScanCommand()`. The unified pipeline is:
```
Instrument -> Flash.ProcessSpectrum -> DataPipe -> UnifiedScanProcessor.ProcessMS
  -> FLASHIdaWrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc, faimsCv)
  -> C++ ProcessScan bridge -> FLASHIda::processScan(... faims_cv)
  -> FLASHIdaWrapper.GetNextScanCommand -> ScanFactory.BuildFromCommand -> Instrument
```

**Cumulative test count at Phase 6: ~90.** Six new C++ FAIMS tests (P6-U01 through P6-U06). P6-U07/U08 (dead code tests) removed from scope per user direction; manual grep verification used instead. Phase 8's P8-U02 closes this gap with an automated source-tree scan.

**Files deleted in Phase 6 (do NOT reference these in Phase 8):**
- `Flash/ScanScheduler.cs` -- deleted in Phase 6 Step 9 (note: actual path is `Flash/ScanScheduler.cs`, NOT `Flash/IDA/ScanScheduler.cs` -- Phase 6 lesson 8)
- `Flash/IDA/FAIMSScanProcessor.cs` -- deleted in Phase 6 Step 9
- Both removed from `Flash.csproj`
- `ProcessorTests.cs` was never created (P5-U03 gap carried forward)

**Test quality standards established by Phase 6 compliance audit.** All Phase 8 tests must follow these rules:

1. **No soft guards:** Use `TEST_EQUAL` / `Assert.That` / `Assert.AreEqual`, never `if (x > 0)` conditional validation or `Assume.That` (Phase 6 lessons 12-14).
2. **Separate input and output arrays:** State machine tests with both input (observed state) and output (next action) must use separate arrays (Phase 6 lesson 13).
3. **No queue passthrough tests:** Tests must exercise production logic paths, not bypass them by pushing pre-built commands via test helpers (Phase 6 lesson 14).
4. **Trace loop assertions for 3+ iterations:** For any loop-based test assertion with index arithmetic, trace at least 3 iterations by hand against the actual implementation (Phase 6 lesson 12).
5. **Hard assertions only:** All continuity tests must have hard assertions. CT22 (if-guarded MS3) and CT18 (Assume.That) remain in the backlog but Phase 8 must not introduce new instances.

**6-file lockstep rule for ScanCommand changes.** Phase 8 does NOT modify ScanCommand (confirmed: 1248 bytes, `faims_cv` at offset 1240). If any late-breaking need arises to change the struct, the 6-file lockstep rule (Phase 6 lesson 15) applies:
1. `FLASHIda.h` (C++ struct + `static_assert`)
2. `FLASHIda.cpp` (populate new field)
3. `ScanCommandLayout_test.cpp` (C++ offsetof printer)
4. `FLASHIdaWrapper.cs` (C# struct)
5. `ScanCommandLayoutTests.cs` (C# `Marshal.SizeOf` assertion)
6. `ScanCommandLayoutTests.cs` (offset assertion for new field)

**CI explicit allowlist for C++ tests.** `flashida-ci.yml` uses explicit `--target` and `-R` lists, NOT test discovery (Phase 6 lesson 10). After Phase 7, the CI targets are: `DeconvolvedSpectrum_OptimizationMetadata_test`, `FLASHIdaQueueTracking_test`, `FLASHIda_ProcessScan_test`, `ScanCommandLayout_test`, `FLASHIdaFAIMS_test`, `FLASHIda_exploration_test`. If Phase 8 adds a new C++ test binary (P8-U04), it must be added to BOTH `cmake --build --target` and `ctest -R` in the **same commit** as the test file creation.

**DLL build workflow only builds, never tests.** The `build_dlls.yml` in the OpenMS repo has no `ctest_test()` call (Phase 6 lesson 11). C++ tests only execute in the parent repo's `flashida-ci.yml`. Do not assume a successful DLL build means tests pass.

---

## Phase 7 Addendum (2026-04-07)

*Updates based on Phase 7 actual outcomes, compliance report, and 9 lessons learned. See `Phase_7/lessons-learned.md` and `Phase_7/compliance-report.md` for full details.*

**Phase 7 status: COMPLETE.** The per-MS-level selection and exploration framework is implemented. Pipeline transition from hardcoded `ms3_enabled_`/`top_n_` to unified `level_configs_` is functional.

**Method name corrections (spec vs actual).** The Phase 7 spec used different method names than the actual implementation. All references in this Phase 8 plan have been corrected:

| Spec name (original) | Actual name (implemented) |
|---|---|
| `initiateMS2Exploration_()` | `initiateExploration_()` |
| `initiateMS3Exploration_()` | `initiateNextLevel_()` |
| `computeFragmentationQuality_()` | `computeExplorationScore_()` |
| `feedExplorationResult_(ctx, ms2_deconv)` | `feedExplorationResult_(group_id, variant_index, ms2_deconv, rt)` |

**Config structure: `<SelectionStrategy>` replaces `<ParameterOptimization>`.** The C# XML block is `<SelectionStrategy>` with per-level `<MSLevel>` sub-elements, not `<ParameterOptimization>`. `Parameter.ToJSON()` serializes this as `selection_strategy` in JSON. All 20+ method XML files include `<SelectionStrategy>` blocks. The C++ parser crashes if `selection_strategy` is absent from the JSON (no backwards-compat default).

**Actual test counts.** Phase 7 added 13 new tests: 11 C++ unit tests (P7-U01 through P7-U12, no U04) and 2 regression tests (P7-R01, P7-R02). Cumulative count after Phase 7: ~103.

**4 WEAK tests identified by compliance audit.** P7-U03 (missing winner_index assertion), P7-U07 (missing child group property assertions), P7-U11 (config-only, does not exercise chaining rule behavior), P7-U12 (config-only, does not exercise selection ranking behavior). These are not blocking for Phase 8 but noted for backlog.

**Pipeline transition outcomes:**
- `top_n_` removed, replaced by `level_configs_[1].max_targets`
- `exploration_max_depth_` and `exploration_max_variants_` removed
- `ms3_enabled_` retained as controlled fallback (not removed in Phase 7) -- three-tier MS3 routing: (1) new exploration path via `getLevelConfig_(3)`, (2) legacy fallback via `ms3_enabled_`, (3) new selection-only path

**ScanCommand: unchanged at 1248 bytes.** Phase 7 did NOT modify the struct. `static_assert(sizeof(ScanCommand) == 1248)` in `FLASHIda.h` line 109. `faims_cv` at offset 1240.

**Variant routing uses `variant_tracking_to_group_` lookup, not `EXPL:` prefix.** The spec anticipated `EXPL:` prefix routing in `processScan()` MS2 path. The actual implementation uses a `variant_tracking_to_group_` map lookup instead.

**New files created in Phase 7:**
- `FlashIDA/test-data/configs/method_exploration.xml` -- MS2 exploration (mass_count, CE 20-40 step 5)
- `FlashIDA/test-data/configs/method_exploration_ms3.xml` -- MS2+MS3 exploration
- `FlashIDA/test-data/golden/phase7_exploration.tsv` -- golden file (37 lines: header + 36 data rows)
- `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` -- 11 C++ unit tests

**Golden file pattern.** 6 precursors x 6 rows each: 5 exploration variants (qScore=0, monoMasses=0, zero deconvolution results expected in test mode -- lesson #9) + 1 standard MS2 (real deconvolution). `method_exploration_ms3.xml` is not covered by the regression runner.

**AL-CT29/CT30 (exploration continuity tests) NOT implemented.** Deferred -- these require actual instrument data or full acquisition loop simulation.

**9 lessons learned.** See `Phase_7/lessons-learned.md` for full details. Key lessons affecting Phase 8:
- Lesson #1: Variable name collision in `parseJSONConfig_()` (MSVC-only). Use descriptive names, not short abbreviations like `ss`.
- Lesson #3/4: `JavaScriptSerializer` writes null for unset reference properties and nullable ints. Always emit defaults.
- Lesson #5: When adding required fields to `MethodParameters`, grep for `new MethodParameters` in test code.
- Lesson #6: DLL must be updated before pushing parent submodule pointer.

**Build #4 partial.** Phase 7 C++ shipped and DLLs committed. Phase 8 C++ changes (dead code removal, legacy config rejection) still pending in Build #4.

---

## The 18 Functions to Remove and the 5 That Remain

### 18 bridge exports to remove

These are removed from `FLASHIdaBridgeFunctions.h/.cpp` (C++ declarations and
definitions). The corresponding C# P/Invoke declarations in `FLASHIdaWrapper.cs` are
also removed (17 C# removals — one C++ export has no C# counterpart):

| # | Function name | Original purpose |
|---|---------------|-----------------|
| 1 | `GetPeakGroupSize` | Returns count of deconvolved peak groups from last MS1 |
| 2 | `IsDifferentiallyAbundant` | Checks if a peak group shows differential abundance for quant |
| 3 | `GetIsolationWindows` | Fills arrays of m/z and charge for top-N isolation targets |
| 4 | `RemoveFromExclusionList` | Removes an m/z from the runtime exclusion list |
| 5 | `GetAllPeakGroupSize` | Returns total peak group count across all charge states |
| 6 | `GetAllMonoisotopicMasses` | Returns all monoisotopic masses for a peak group |
| 7 | `GetRepresentativeMass` | Returns representative (most abundant) mass for a peak group |
| 8 | `ProcessMS2ForTagBasedTargeting` | Routes MS2 results into tag-based targeting state |
| 9 | `DeconvolveMS2` | Runs MS2 deconvolution for a single spectrum |
| 10 | `GetBestMS2Masses` | Returns ranked fragment masses after MS2 deconvolution |
| 11 | `HasMS2Deconvolution` | Checks if MS2 deconvolution results are available |
| 12 | `GetMS2PeakGroupCount` | Returns number of peak groups from last MS2 deconvolution |
| 13 | `ClearMS2Deconvolution` | Resets MS2 deconvolution state between scans |
| 14 | `GetTopFragmentMatches` | Returns top fragment ion matches for MS3 targeting |
| 15 | `GetAmbiguityEnclosingIons` | Returns enclosing ions for ambiguity resolution |
| 16 | `GetTerminalFragmentIons` | Returns terminal fragment ions for sequence tagging |
| 17 | `GetConfigInt` | Phase 2 diagnostic: reads integer config value by key |
| 18 | `GetConfigDouble` | Phase 2 diagnostic: reads double config value by key |

The invariant is: after Phase 8, exactly 5 C++ exports remain (`CreateFLASHIda`,
`DisposeFLASHIda`, `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`) and
exactly 5 C# `[DllImport]` declarations remain.

### 5 bridge exports that remain

| Function | C++ signature | C# P/Invoke |
|----------|---------------|-------------|
| `CreateFLASHIda` | `FLASHIda* CreateFLASHIda(const char* jsonConfig)` | `static extern IntPtr CreateFLASHIda(string jsonConfig)` |
| `DisposeFLASHIda` | `void DisposeFLASHIda(FLASHIda* ptr)` | `static extern void DisposeFLASHIda(IntPtr ptr)` |
| `ProcessScan` | `int ProcessScan(FLASHIda* obj, double* mzs, double* ints, int length, double rt_min, int ms_level, const char* scan_description, double faims_cv)` | `static extern int ProcessScan(IntPtr ptr, double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc, double faimsCv)` |
| `GetNextScanCommand` | `int GetNextScanCommand(FLASHIda* obj, ScanCommand* output)` | `static extern int GetNextScanCommand(IntPtr ptr, ref ScanCommand output)` |
| `GetNextTrackingId` | `int GetNextTrackingId(FLASHIda* obj)` | `static extern int GetNextTrackingId(IntPtr ptr)` |

**Note:** The `ProcessScan` signature includes `double faims_cv` added in Phase 6. The C++ declaration in `FLASHIdaBridgeFunctions.h` (lines 192-194) already has this parameter. The C# `[DllImport]` in `FLASHIdaWrapper.cs` already has `double faimsCv`.

---

## Detailed Implementation Steps

### Step 1 — Verify no live callers exist before touching C++ (pre-condition check)

These checks are automated by **P8-U01** and **P8-U02** in the `windows-tests` CI job.
Do not proceed to Steps 2+ unless P8-U01 and P8-U02 pass in CI on the current state of
the branch.

The scripts below are reference implementations of what those tests check. They run in CI,
not locally.

**C# call-site verification (reference — runs in CI as part of P8-U01/P8-U02):**

```powershell
$funcs = @(
    "GetPeakGroupSize", "IsDifferentiallyAbundant", "GetIsolationWindows",
    "RemoveFromExclusionList", "GetAllPeakGroupSize", "GetAllMonoisotopicMasses",
    "GetRepresentativeMass", "ProcessMS2ForTagBasedTargeting", "DeconvolveMS2",
    "GetBestMS2Masses", "HasMS2Deconvolution", "GetMS2PeakGroupCount",
    "ClearMS2Deconvolution", "GetTopFragmentMatches", "GetAmbiguityEnclosingIons",
    "GetTerminalFragmentIons", "GetConfigInt", "GetConfigDouble"
)
foreach ($f in $funcs) {
    $hits = Select-String -Path "FlashIDA\src\**\*.cs" -Pattern $f -Recurse |
            Where-Object { $_.Filename -ne "FLASHIdaWrapper.cs" }
    if ($hits) { Write-Host "BLOCKER: $f still called from: $($hits.Filename)" }
    else { Write-Host "OK: $f has no C# callers outside wrapper" }
}
```

**C++ caller verification (reference — runs in CI on `ubuntu-latest`):**

```bash
for func in GetPeakGroupSize IsDifferentiallyAbundant GetIsolationWindows \
            RemoveFromExclusionList GetAllPeakGroupSize GetAllMonoisotopicMasses \
            GetRepresentativeMass ProcessMS2ForTagBasedTargeting DeconvolveMS2 \
            GetBestMS2Masses HasMS2Deconvolution GetMS2PeakGroupCount \
            ClearMS2Deconvolution GetTopFragmentMatches GetAmbiguityEnclosingIons \
            GetTerminalFragmentIons GetConfigInt GetConfigDouble; do
    hits=$(grep -rn "$func" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/ \
           --include="*.cpp" --include="*.h" \
           | grep -v "FLASHIdaBridgeFunctions")
    if [ -n "$hits" ]; then
        echo "BLOCKER: $func has callers outside bridge file:"
        echo "$hits"
    else
        echo "OK: $func clear"
    fi
done
```

**`ToFLASHDeconvInput` absence check (reference — runs in CI as part of P8-U02):**

```powershell
Select-String -Path "FlashIDA\src\**\*.cs" -Pattern "ToFLASHDeconvInput" -Recurse |
    Where-Object { $_.Filename -ne "Parameter.cs" }
```

---

### Step 2 — Remove the 18 C++ bridge exports from the header

File: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h`

For each of the 18 functions, remove the `extern "C" OPENMS_DLLAPI` declaration. Leave only
the 5 keeper declarations and any file-level includes or guards that remain valid.

The header after this step contains exactly these 5 declarations (plus any necessary includes
and `#ifdef`/`#pragma` guards):

```cpp
extern "C" OPENMS_DLLAPI FLASHIda* CreateFLASHIda(const char* json_config);
extern "C" OPENMS_DLLAPI void      DisposeFLASHIda(FLASHIda* obj);
extern "C" OPENMS_DLLAPI int       ProcessScan(FLASHIda* obj,
                                               double* mzs, double* ints, int length,
                                               double rt_min, int ms_level,
                                               const char* scan_description,
                                               double faims_cv);
extern "C" OPENMS_DLLAPI int       GetNextScanCommand(FLASHIda* obj,
                                                      ScanCommand* output);
extern "C" OPENMS_DLLAPI int       GetNextTrackingId(FLASHIda* obj);
```

Note: `ProcessScan` includes `double faims_cv` (added in Phase 6, `FLASHIdaBridgeFunctions.h` lines 192-194).

---

### Step 3 — Remove the 18 C++ bridge function definitions

File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp`

Delete the entire function body for each of the 18 functions. Do not leave stub bodies,
`/* removed */` comments, or `#if 0` blocks. The removed code is in version control; leaving
dead stubs is noise.

After this step, `FLASHIdaBridgeFunctions.cpp` contains only the 5 keeper definitions.

---

### Step 4 — Remove internal C++ methods that were only called by the old bridge functions

File: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Audit the private methods of `FLASHIda` for any that are now unreachable. A method is safe
to remove if:

- It was called only from one or more of the 18 deleted bridge wrapper functions.
- It is not called from `processScan_()`, `getNextScanCommand_()`, `feedExplorationResult_(group_id, variant_index, ms2_deconv, rt)`,
  `initiateExploration_()`, `initiateNextLevel_()`, or any other method reachable from the 5 keeper exports.

Common candidates (confirm by grep before deletion):

- `getPeakGroupSize_()` -- served `GetPeakGroupSize`
- `fillIsolationWindows_()` -- served `GetIsolationWindows`
- `deconvolveMS2_()` -- may have been superseded by the MS2 path inside `processScan_()`
- `resetScanState_()` -- served `ResetScanState`

**Do NOT remove these Phase 7 exploration methods** (they are reachable from the 5 keeper
exports via `processScan_()` / `getNextScanCommand_()`):
- `initiateExploration_()`, `feedExplorationResult_()` (4-parameter: group_id, variant_index, ms2_deconv, rt), `initiateNextLevel_()`
- `computeExplorationScore_()`, `computeMassCount_()`, `computeRemainingPrecursorScore_()`, `computeFragmentCount_()`, `computeTICCoverage_()`, `buildCEVariants_()`
- `buildMS2Command_()` overload (explicit CE version), `applyOverrides_()`
- `parseLevelConfig_()`, `parseSelectionMetric_()`, `parseExplorationMetric_()`, `getLevelConfig_()`
- All `ForTest` helpers: `getActiveExplorationGroupCountForTest()`, `getExplorationGroupForTest()`, `getLevelConfigForTest()`, `getQueueSizeForTest()`, `initiateExplorationForTest()`, `feedExplorationResultForTest()`

Do not remove methods that are still referenced from anywhere in `FLASHIda.cpp` or
`FLASHIdaBridgeFunctions.cpp` (post-deletion). When in doubt, leave the method and note it
for a follow-up cleanup; the priority is shipping a correct bridge, not perfect internal
cleanliness.

---

### Step 5 — Remove legacy config parsing from C++

File: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Locate the constructor of `FLASHIda` (or the config parsing entry point, depending on how
it was structured). It currently contains an auto-detect branch introduced in Phase 1:

```cpp
if (arg[0] == '{')
    parseJSON_(arg);
else
    parseLegacy_(arg);
```

Remove the `else` branch entirely. The constructor should now call `parseJSON_()` directly
or simply assert/throw if the input is not JSON. Choose the approach that is most consistent
with the existing error handling style in the file:

- **Preferred (throw):** `throw std::invalid_argument("FLASHIda: config must be JSON");`
- **Alternative (log + abort):** Log an error via OpenMS log macros and return early, leaving
  the object in an uninitialized state that causes subsequent bridge calls to return
  safe-failure values.

Also remove the `parseLegacy_()` method declaration from `FLASHIda.h` and its definition
from `FLASHIda.cpp`.

---

### Step 6 — Remove 17 old C# P/Invoke declarations from FLASHIdaWrapper.cs

File: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

Remove the `[DllImport(dllName)]` declaration line and its associated static extern method
signature for each of the 17 functions (the C# file has 22 `DllImport` lines total; 5 keepers
= 17 to remove; the C++ side has 18 removals because one export has no C# counterpart).
Do not remove any helper methods in `FLASHIdaWrapper`
that wrap the 5 keeper functions (e.g., any public methods that call `ProcessScan` internally).

After this step, the file contains exactly 5 `[DllImport(dllName)]` lines. The count is
verifiable by test P8-U01.

The 5 declarations that remain (from Issue 7 in baseline-plan.md). Note: `dllName` must
resolve to `"OpenMS.dll"` (with extension), matching the actual P/Invoke constant:

```csharp
[DllImport(dllName)] static extern IntPtr CreateFLASHIda(string jsonConfig);
[DllImport(dllName)] static extern void   DisposeFLASHIda(IntPtr ptr);
[DllImport(dllName)] static extern int    ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc,
    double faimsCv);
[DllImport(dllName)] static extern int    GetNextScanCommand(IntPtr ptr,
    ref ScanCommand output);
[DllImport(dllName)] static extern int    GetNextTrackingId(IntPtr ptr);
```

Note: `ProcessScan` includes `double faimsCv` (added in Phase 6). When counting `[DllImport]`
lines for P8-U01, ensure the count is exactly 5 regardless of multi-line formatting.

---

### Step 7 — Remove Parameter.ToFLASHDeconvInput()

File: `FlashIDA/src/Flash/IDA/Parameter.cs`

Delete the `ToFLASHDeconvInput()` method. This is the legacy space-delimited token
serializer that was replaced by `ToJSON()` in Phase 1.

Also remove any `using` directives, private helper methods, or string-formatting constants
that exist solely to support `ToFLASHDeconvInput()` and are not used elsewhere in the file.

The `[Description]` attributes added in Phase 1, and the `ToJSON()` method, must be left
intact.

---

### Step 8 — Create MethodDocGenerator.cs

File: `FlashIDA/src/Flash/IDA/MethodDocGenerator.cs` (new file)

`MethodDocGenerator` is a reflection utility that reads `[Description]` attributes from
properties in `Parameter.cs` and `MethodConfig.cs` and formats them as documentation.
It is approximately 30 lines long, as specified in Issue 8 of baseline-plan.md.

The class must:

1. Accept a `Type` argument (or default to scanning `Parameter` and `MethodConfig`).
2. Iterate over all public properties of the type using `System.Reflection`.
3. For each property that has a `[System.ComponentModel.Description]` attribute, emit a
   line of the form: `PropertyName: <description text>`.
4. Return or print the result. Provide both a static `Generate(Type t)` method that returns
   a `string` (used by test P8-U03) and optionally a `GenerateToConsole()` convenience
   overload.

Minimal reference implementation shape (fill in details to match project style):

```csharp
using System;
using System.ComponentModel;
using System.Reflection;
using System.Text;

namespace Flash.IDA
{
    public static class MethodDocGenerator
    {
        public static string Generate(Type type)
        {
            var sb = new StringBuilder();
            foreach (PropertyInfo prop in type.GetProperties(
                BindingFlags.Public | BindingFlags.Instance))
            {
                var attr = prop.GetCustomAttribute<DescriptionAttribute>();
                if (attr != null)
                    sb.AppendLine($"{prop.Name}: {attr.Description}");
            }
            return sb.ToString();
        }

        public static void GenerateToConsole(Type type)
            => Console.Write(Generate(type));
    }
}
```

Place `MethodDocGenerator.cs` in the same directory as `Parameter.cs` and include it in
`Flash.csproj` under the appropriate `<Compile>` item group (or rely on the wildcard glob
if the project uses one).

---

### Step 9 — Build and verify compilation

After all code changes are complete, build the C++ library and C# solution:

**C++ (part of Build #4, batched with Phase 7):**

```bash
cmake --build <build-dir> --config Release
```

The build must succeed with zero errors. No warnings about undefined symbols or missing
exports are acceptable. MSVC's `/WX` flag (warnings-as-errors, already enabled in the
OpenMS build) will surface unused parameters (`C4100`) and unused variables (`C4189`)
introduced by the removals — fix these before pushing (Phase 1 lesson #3). In
particular, never comment out a call to an OpenMS singleton initializer
(`ModificationsDB::getInstance()`, `ResidueDB::getInstance()`, etc.) to silence a
C4189 warning; use a `(void)` cast instead (Phase 1 lesson #4).

**C# (CI `windows-latest` -- `windows-tests` job):**

```powershell
msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror
```

The `/warnaserror` flag is a Phase 8 goal. Zero warnings must remain after the removed code
is gone. Common warning sources to resolve before enabling `/warnaserror`:

- Unreferenced `using` directives left behind after method removal (e.g., `using System.Text`
  that was only needed by `ToFLASHDeconvInput()`).
- Variables or parameters that were only used by now-deleted call sites.
- Nullable reference warnings if the project has that analyzer enabled.
- `CS0169` (field never used) for any private fields that were only read by deleted methods.

**Approach:** First build without `/warnaserror` to collect the full list of warnings.
Fix them all in the same commit as the code removal. Then enable `/warnaserror` as a
separate CI step (P8-I02) to lock in the zero-warning state permanently. This two-step
approach avoids a commit that removes code AND enables `/warnaserror` simultaneously,
which makes debugging harder if warnings arise.

Note: The `.csproj` currently uses `<WarningLevel>4</WarningLevel>` without
`<TreatWarningsAsErrors>`. P8-I02 adds `/warnaserror` as a CI-only flag rather than
modifying the `.csproj`, so local developer builds are not affected.

---

### Step 10 — Update DLL export verification test data

File: `FlashIDA/test-data/` (update any hard-coded export counts or lists)

The integration test P8-I01 checks `dumpbin /exports` for exactly 5 bridge symbols and
verifies that none of the removed names are present. If the test script contains a hard-coded
list of expected absent names, add all 18 removed function names to it. See Section 5.4 of
`testing-strategy.md` for the baseline `dumpbin` CI step; extend the `findstr` block to also
assert absence.

**Note:** The 5 keeper exports use the final struct layouts (including `enqueue_timestamp_ms`
+ 11 scoring fields from Phase 4 [1240 bytes] and `faims_cv` from Phase 6 [1248 bytes]).
The `dumpbin` check verifies symbol presence only, not struct ABI — struct size verification
is handled by `static_assert` in C++ and `Marshal.SizeOf` in C# (P3-U01/P3-U02, updated in
Phases 4 and 6 to reflect the final sizes).

```cmd
dumpbin /exports FlashIDA\dll\OpenMS.dll > exports.txt
rem Verify 5 keeper functions present
findstr /C:"CreateFLASHIda"     exports.txt || exit /b 1
findstr /C:"DisposeFLASHIda"    exports.txt || exit /b 1
findstr /C:"ProcessScan"        exports.txt || exit /b 1
findstr /C:"GetNextScanCommand" exports.txt || exit /b 1
findstr /C:"GetNextTrackingId"  exports.txt || exit /b 1
rem Verify all 18 removed functions are absent
findstr /C:"GetPeakGroupSize"               exports.txt && exit /b 1
findstr /C:"IsDifferentiallyAbundant"       exports.txt && exit /b 1
findstr /C:"GetIsolationWindows"            exports.txt && exit /b 1
findstr /C:"RemoveFromExclusionList"        exports.txt && exit /b 1
findstr /C:"GetAllPeakGroupSize"            exports.txt && exit /b 1
findstr /C:"GetAllMonoisotopicMasses"       exports.txt && exit /b 1
findstr /C:"GetRepresentativeMass"          exports.txt && exit /b 1
findstr /C:"ProcessMS2ForTagBasedTargeting" exports.txt && exit /b 1
findstr /C:"DeconvolveMS2"                  exports.txt && exit /b 1
findstr /C:"GetBestMS2Masses"               exports.txt && exit /b 1
findstr /C:"HasMS2Deconvolution"            exports.txt && exit /b 1
findstr /C:"GetMS2PeakGroupCount"           exports.txt && exit /b 1
findstr /C:"ClearMS2Deconvolution"          exports.txt && exit /b 1
findstr /C:"GetTopFragmentMatches"          exports.txt && exit /b 1
findstr /C:"GetAmbiguityEnclosingIons"      exports.txt && exit /b 1
findstr /C:"GetTerminalFragmentIons"        exports.txt && exit /b 1
findstr /C:"GetConfigInt"                   exports.txt && exit /b 1
findstr /C:"GetConfigDouble"               exports.txt && exit /b 1
```

---

### Step 11 — Run the full regression suite

The full regression suite is automated by **P8-R01** in the `windows-tests` CI job. Do not
proceed to committing until P8-R01 passes in CI for the current branch state.

**CI TRACK-CREATE gate (Phase 3 compliance F-5):** Every regression run must produce at
least one `[TRACK-CREATE]` entry in stdout. This is a hard-fail CI gate inherited from
Phase 3. If any config produces zero `[TRACK-CREATE]` entries, the CI job fails even if the
golden file comparison passes. The exploration config (`method_exploration.xml`) should
produce multiple `[TRACK-CREATE]` entries for both the initial MS2 commands and the
exploration variant commands.

**Debugging note (Phase 0 lesson #14):** The C++ bridge returns 0 results silently when
input data is malformed — there is no distinct error code for "bad input" vs "no results
found." If a regression config unexpectedly produces an empty output file, log the input
data characteristics (RT, peak count, first/last m/z) before investigating engine internals.

The authoritative orchestration for this step is `regression-runner.ps1`
(`FlashIDA/test-scripts/regression-runner.ps1`). Its full config array, correct golden file
names, and per-config spectrum file assignments are specified in
[../test-file-specification.md §4.2](../test-file-specification.md). The canonical config
array as of Phase 8 (all 10 entries, FAIMS configs excluded) is reproduced there; use that
as the single source of truth when extending or verifying the script. Note in particular:

- `ms2_hcd_fragment.txt` (spec §1.3) is the required second spectrum argument for
  `method_tag_targeting.xml`, `method_quant.xml`, `method_ms3_mode1.xml`,
  `method_ms3_mode2.xml`, and `method_ms3_mode3.xml`.
- All other configs use `ms1_standard.txt` (spec §1.2).
- FAIMS configs (`method_faims_3cv.xml`, `method_faims_skip.xml`) are excluded from the
  regression runner because Flash.exe test mode ignores CVs (Phase 5 Lesson 1). FAIMS
  behavioral verification is provided by continuity tests CT09/CT10/CT27/CT28.
- All spectrum files use **tab-separated** format with **RT in seconds** (Phase 0 lesson #2):
  `Spec scan=N\t<rt_seconds>`, followed by tab-separated `m/z\tintensity` data lines.
  Flash.exe's parser divides RT by 60 internally.

Golden file canonical names follow the `phase4_*` / `faims_*` / `phase7_*` convention
defined in spec §2.2. All 10 configurations must produce `PASS`. Any failure indicates a
regression introduced during cleanup.

For reference, the runner invokes `Flash.exe` and `compare_golden.py` in the pattern:

```powershell
# Reference — runs in CI as part of P8-R01 (windows-tests job, windows-latest)
# Canonical config array and golden file names: see test-file-specification.md §4.2
# Four-argument form used when ms2 is non-null (entry point is FLASHIdaWrapper.Main(), no -t flag):
& $FlashExe $ms1File $outputFile $methodFile [$ms2File]
python compare_golden.py "$TestDataDir\golden\$goldenFile" "$OutputDir\$name.tsv"
```

The `compare_golden.py` tolerance rules (absolute 1e-6 for |v| ≤ 1.0, relative 1e-4 for
|v| > 1.0; exact match for `charges` and `hcd`) are defined in
[../test-file-specification.md §4.1](../test-file-specification.md).

---

## Files to Create or Modify

### C++ (OpenMS) -- Build #4, batched with Phase 7

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` | Modify | Remove 18 `extern "C" OPENMS_DLLAPI` declarations. Leave 5 (including `ProcessScan` with `double faims_cv` parameter). |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Modify | Remove 18 function bodies. Leave 5. |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Remove declarations of private methods that are now orphaned (e.g., `getPeakGroupSize_`, `parseLegacy_`). **Do NOT remove** Phase 7 exploration methods or Phase 6 FAIMS methods (they are reachable from the 5 keeper exports). |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Remove `parseLegacy_()` definition; remove the `else parseLegacy_(arg)` branch in the constructor; remove orphaned private method bodies. |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp` | Create (new) | C++ test for P8-U04 (legacy config rejection). |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Add entry for `FLASHIda_LegacyConfig_test` (or chosen test binary name). |

### C# (FlashIDA)

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | Remove 17 `[DllImport]` declarations. Leave exactly 5 (including `ProcessScan` with `double faimsCv`). |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Remove `ToFLASHDeconvInput()` method and any helpers that exist solely for it. |
| `FlashIDA/src/Flash/IDA/MethodDocGenerator.cs` | Create (new) | ~30-line reflection utility for `[Description]`-based documentation. |
| `FlashIDA/src/Flash.Tests/CleanupTests.cs` | Create (new) | NUnit tests P8-U01, P8-U02, P8-U03. |
| `FlashIDA/src/Flash.Tests/Flash.Tests.csproj` | Modify | Add `<Compile Include="CleanupTests.cs" />` to the item group (the project uses explicit `<Compile>` includes, NOT wildcard globs). |

### CI workflow

| File | Action | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | **(1)** Add `FLASHIda_LegacyConfig_test` to BOTH `cmake --build --target` and `ctest -R` (Phase 6 lesson 10). **(2)** Extend `dumpbin` export verification to assert 5 present + 18 absent (Step 10). **(3)** Add `/warnaserror` build step (P8-I02). |

**Files NOT modified (already deleted or never created):**
- `Flash/ScanScheduler.cs` -- deleted in Phase 6 Step 9
- `Flash/IDA/FAIMSScanProcessor.cs` -- deleted in Phase 6 Step 9
- `ProcessorTests.cs` -- never created (P5-U03/P6-U07/U08 gaps)

No other files should require changes. If a file outside this list needs modification, that
indicates an unresolved call site from Step 1 that must be addressed first.

**`.gitattributes` note (Phase 0 lesson #4):** If any new binary file extensions are
introduced (e.g., `.enc`, `.zip`, `.gpg`), add corresponding `*.ext binary` entries to
`FlashIDA/.gitattributes` before committing. The existing `* text eol=crlf` rule will
silently corrupt binary files without these entries. Phase 8 does not introduce new binary
extensions, but this must be checked if the file list changes.

---

## Test Cases

All 7 tests added in this phase. They run as part of the full cumulative suite (including
all prior phases; ~103 cumulative tests were delivered through Phase 7. Phase 8 adds 7,
bringing the cumulative total to ~110).

**Tier convention (Phase 0 lesson #12):** Tests that load `OpenMS.dll` (via P/Invoke or
bridge calls) are Tier 2, not Tier 1. Pure C# tests without DLL dependencies are Tier 1.
If any test is added that exercises bridge functions, label it Tier 2.

**Multi-scan parser note (Phase 0 lesson #9):** Any new test code that loads spectrum TSV
files must stop at the first scan boundary (`if (started) break;` on encountering a second
`Spec` line). Failing to do so mixes peaks from multiple scans and silently produces wrong
results (see also silent zero-result failure mode, lesson #14).

**Test quality standards (Phase 6 compliance, mandatory for all Phase 8 tests):**
- **No soft guards:** Hard `Assert` / `TEST_EQUAL` only. No `if (x > 0)` conditional
  validation, no `Assume.That`, no `NOT_TESTABLE` (Phase 6 lessons 12-14).
- **No tautological tests:** Every assertion must be capable of failing with incorrect
  implementation. `new X(null)` + `IsNotNull` is tautological (Phase 5 compliance).
- **No queue passthrough:** Tests must exercise production code paths, not push pre-built
  commands via test helpers (Phase 6 lesson 14).
- **`Flash.Tests.csproj` uses explicit `<Compile>` includes:** New test files must be
  added to the `<ItemGroup>` with `<Compile Include="CleanupTests.cs" />`. The project
  does NOT use wildcard globs.

### Test Summary (Quick Reference)

| Test | Summary |
|------|---------|
| P8-U01 | Counts `[DllImport]` declarations in `FLASHIdaWrapper.cs` and asserts exactly 5 remain. Ensures no legacy P/Invoke declaration was accidentally left behind after the 17 removals. |
| P8-U02 | Scans all C# source files for any reference to `ToFLASHDeconvInput` and asserts zero hits outside `Parameter.cs`. Confirms the legacy serialization method and all its call sites are fully gone. |
| P8-U03 | Calls `MethodDocGenerator.Generate(typeof(Parameter))` and verifies the returned string is non-empty and contains at least 3 known `[Description]`-annotated property names. Validates that the new reflection utility works correctly on real `Parameter` properties. |
| P8-U04 | Passes a non-JSON (legacy space-delimited) string to the `FLASHIda` C++ constructor and asserts that it throws `std::invalid_argument`. Confirms the `parseLegacy_` fallback was removed and invalid input is rejected rather than silently accepted. |
| P8-I01 | Runs `dumpbin /exports` on the built `OpenMS.dll` and asserts all 5 keeper functions are present and all 18 removed functions are absent. Verifies the compiled DLL export table matches the intended final bridge API exactly. |
| P8-I02 | Builds `Flash.sln` with `/warnaserror` and asserts the build exits with zero warnings. Confirms that removing dead declarations and methods left no dangling references or orphaned `using` directives. |
| P8-R01 | Runs `Flash.exe` against all 10 method configuration files (FAIMS configs excluded -- see P8-R01 detail) and compares each output to the corresponding Phase 7 golden file. Verifies that the cleanup phase changed no observable behaviour across every supported acquisition mode. |

---

### P8-U01 — Exactly 5 P/Invoke declarations (Tier 1, C#, `windows-latest`)

**Description:** Count `[DllImport` attribute occurrences in `FLASHIdaWrapper.cs` via
reflection or text scan. Verify the count equals exactly 5.

**Implementation:** NUnit test in `Flash.Tests/CleanupTests.cs`. Read `FLASHIdaWrapper.cs`
as text and count lines matching `[DllImport`; or use reflection to count methods on
`FLASHIdaWrapper` decorated with `DllImportAttribute`.

If `CleanupTests.cs` needs to reference any file on disk (e.g., source files for text
scanning), locate them via `Path.Combine(TestContext.CurrentContext.TestDirectory, "..",
"test-data")` — one level up from `FlashIDA/bin/` (Phase 1 lesson #2). Do not use
`"..\\..\\test-data"` which resolves to the parent repo root.

**Expected outcome:** Count equals 5. Any count other than 5 fails the test.

**Rationale:** Enforces the invariant that the bridge API is permanently locked at 5
functions and no one accidentally re-adds a legacy declaration.

---

### P8-U02 — No reference to ToFLASHDeconvInput (Tier 1, C#, `windows-latest`)

**Description:** Verify that no file in `FlashIDA/src/` references `ToFLASHDeconvInput`.
The method definition itself is deleted; this test confirms no call sites were overlooked.

**Implementation:** NUnit test that searches the source tree for the string
`ToFLASHDeconvInput` and asserts zero hits, excluding any test file that contains the
assertion string itself.

Alternatively implemented as a PowerShell step in CI:

```yaml
- name: Verify ToFLASHDeconvInput removed
  shell: powershell
  run: |
    $hits = Select-String -Path "FlashIDA\src\**\*.cs" `
            -Pattern "ToFLASHDeconvInput" -Recurse |
            Where-Object { $_.Filename -notmatch "CleanupTests" }
    if ($hits) { Write-Host "FAIL: $hits"; exit 1 }
    Write-Host "PASS: ToFLASHDeconvInput not found"
```

**Expected outcome:** Zero matches. Any hit is a test failure.

---

### P8-U03 — MethodDocGenerator produces correct output (Tier 1, C#, `windows-latest`)

**Description:** Instantiate `MethodDocGenerator`, call `Generate(typeof(Parameter))`,
verify the returned string is non-empty and contains at least 3 known field names that have
`[Description]` attributes in `Parameter.cs`.

**Implementation:** NUnit test in `Flash.Tests/CleanupTests.cs`:

```csharp
[Test]
public void MethodDocGenerator_ProducesOutputForParameter()
{
    string output = MethodDocGenerator.Generate(typeof(Parameter));
    Assert.IsNotEmpty(output);
    // Verify known fields with [Description] attributes appear
    Assert.That(output, Does.Contain("ScoreThreshold"));
    Assert.That(output, Does.Contain("MaxMassCount"));
    Assert.That(output, Does.Contain("HCDEnergy"));
}
```

The exact field names used in the assertion must match property names in `Parameter.cs` that
have `[Description]` attributes. Adjust to match what was added in Phase 1.

**Expected outcome:** `output` is non-empty; all three field name assertions pass.

---

### P8-U04 — Legacy config parsing removed (Tier 1, C++, `ubuntu-latest`)

**Description:** Attempt to create a `FLASHIda` instance by passing a non-JSON string
(e.g., the old space-delimited format). Verify that the call fails rather than silently
accepting the input via the now-deleted legacy path.

**Implementation:** C++ test via the OpenMS ClassTest framework:

```cpp
// In FLASHIda_test.cpp or a new file Phase8_test.cpp
START_SECTION(legacy_config_rejected)
{
    // The legacy format started with a number or keyword, never '{'
    const char* legacy_input = "10 100 1 10 5 0.5 -1";
    FLASHIda* obj = nullptr;
    bool threw = false;
    try {
        obj = new FLASHIda(legacy_input);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    TEST_EQUAL(threw, true)
    TEST_EQUAL(obj, nullptr)
}
END_SECTION
```

If the constructor logs and returns a partially-initialized object rather than throwing,
adjust the test to call a method that reflects the invalid state (e.g., `ProcessScan`
returning -1 immediately).

**Expected outcome:** Constructor throws `std::invalid_argument` (or equivalent failure
mode). The legacy input is not silently accepted.

**Runner:** `ubuntu-latest` via CTest (`ctest -R ClassName --output-on-failure`). No Thermo
DLL dependency.

**MSVC `/WX` note (Phase 2 lesson #8):** If variables in the test (e.g., `obj`, `threw`)
are used only in `TEST_EQUAL` assertions, MSVC may warn about unused variables. Use
`(void)var;` after the assertion to suppress the warning.

---

### P8-I01 — DLL exports: exactly 5 bridge functions (Tier 2, `windows-latest`)

**Description:** Run `dumpbin /exports` on the built `OpenMS.dll`. Verify that all 5 keeper
functions are present and all 18 removed functions are absent.

**Implementation:** Bridge verification step in `windows-tests` job of `flashida-ci.yml` (see Step 10 for
the full cmd script). This test replaces and extends the Phase 3 DLL export check (P3-I05).

**Expected outcome:** All 5 presence checks pass (`findstr` finds each name). All 18 absence
checks pass (`findstr` returns non-zero for each removed name). Any deviation from this exact
set is a build failure.

**Runner:** `windows-latest`. Requires `dumpbin.exe` from VS Build Tools (already required by
Phase 3 P3-I05; no new dependency).

---

### P8-I02 — C# compiles with zero warnings (Tier 2, `windows-latest`)

**Description:** Build `Flash.sln` with `/warnaserror` (treat all warnings as errors). The
build must succeed, demonstrating that removing dead code and dead declarations left no
dangling references that the compiler silently accepted with a warning.

**Implementation:** CI step in the `windows-tests` job:

```yaml
- name: Build with warnings-as-errors
  run: |
    msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror
```

This is a separate build step from the normal debug build. If the normal build already uses
`/warnaserror`, this test is redundant and can be merged.

**Expected outcome:** MSBuild exits 0. No warnings are emitted. If any warnings remain,
they must be resolved before this phase is considered done.

**Runner:** `windows-latest`. Requires Thermo iAPI DLLs (decrypted via Strategy B /
openssl from `FlashIDA/dependencies/thermo-dlls.zip.enc`, same as all C# build steps).

---

### P8-R01 — Full regression: every mode config against Phase 7 golden files (Tier 3, `windows-latest`)

**Description:** Run `Flash.exe` with every method configuration file and compare each
output to the corresponding Phase 7 golden file using `compare_golden.py`. This is the
comprehensive validation that cleanup removed only dead code and changed no behavior.

**CI gate note:** Every regression run must produce `[TRACK-CREATE]` entries in stdout
(hard-fail gate from Phase 3 compliance finding F-5). If any config produces zero
`[TRACK-CREATE]` entries, the CI job fails even if the golden file comparison passes.

**Fractional CE note:** `method_exploration.xml` uses fractional collision energy values
(Phase 7 CE sweep). `collision_energy` is `double` throughout the struct chain
(`IsolationStage.collision_energy`), so fractional values are correctly represented.
The `compare_golden.py` relative tolerance (1e-4 for |v| > 1.0) handles these correctly.

**Configurations covered (minimum 10):**

Canonical golden file names are defined in [../test-file-specification.md §2.2](../test-file-specification.md).
Spectrum file assignments per config are defined in spec §1.2–§1.4 and §4.2.

| Config file | Spectrum file(s) | Golden file (canonical name from spec §2.2) |
|-------------|-----------------|---------------------------------------------|
| `method_default.xml` | `ms1_standard.txt` | `phase4_standard_dda.tsv` |
| `method_deep.xml` | `ms1_standard.txt` | `phase4_deep_mode.tsv` |
| `method_inclusion.xml` | `ms1_standard.txt` | `phase4_inclusion.tsv` |
| `method_exclusion.xml` | `ms1_standard.txt` | `phase4_exclusion.tsv` |
| `method_tag_targeting.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_tag_targeting.tsv` |
| `method_quant.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_quant.tsv` |
| `method_ms3_mode1.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode1.tsv` |
| `method_ms3_mode2.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode2.tsv` |
| `method_ms3_mode3.xml` | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `phase4_ms3_mode3.tsv` |
| `method_exploration.xml` | `ms1_standard.txt` | `phase7_exploration.tsv` |

**FAIMS configs excluded:** `method_faims_3cv.xml` and `method_faims_skip.xml` are not included in P8-R01 because Flash.exe test mode ignores CVs (Phase 5 Lesson 1). Both configs produce output identical to standard DDA on the same input data. FAIMS behavioral verification in Phase 8 is provided by continuity tests CT09/CT10/CT27/CT28, which run within NUnit and are included in the cumulative test suite.

**Implementation:** The `regression-runner.ps1` script (Section 6.1 of `testing-strategy.md`;
canonical config array in [../test-file-specification.md §4.2](../test-file-specification.md))
covers all 10 configs. Each invocation uses `compare_golden.py` for numeric comparison with
tolerances defined in [../test-file-specification.md §4.1](../test-file-specification.md)
(absolute 1e-6 for |v| ≤ 1.0, relative 1e-4 for |v| > 1.0; exact match for `charges` and `hcd`).
The golden TSV column schema (15 columns) is specified in spec §2.1.

**Expected outcome:** All 10 configs produce `PASS`. Any single failure is a regression.
Golden files are the Phase 7 outputs; they are not updated in this phase unless a deliberate
behavioral change was made (none is expected in a cleanup phase). If golden files do need
updating, remember that golden-file capture requires a 2-commit minimum: the first commit
runs CI and produces the golden artifact, the second commit includes the captured golden
file (Phase 0 lesson #15).

**Runner:** `windows-latest`. Requires OpenMS DLLs (committed in `FlashIDA/dll/`, no
download needed — Phase 0 lesson #5) and Thermo iAPI DLLs (decrypted via Strategy B /
openssl — Phase 0 lesson #3).

**Timing note:** 10 `Flash.exe` invocations may approach the 20-min Tier 3 budget.
If timing is tight, parallelize by splitting configs across two PowerShell jobs that run
concurrently, or run the 4 fastest configs sequentially and batch the rest.

---

## CI Configuration Changes

These changes to `.github/workflows/flashida-ci.yml` are required for Phase 8.

**CRITICAL (Phase 6 lesson 10):** New C++ test binaries must be added to BOTH the
`cmake --build --target` list AND the `ctest -R` regex. The CI uses an explicit allowlist
-- it does not discover tests automatically.

### 1. Extend DLL export verification in the bridge verification step in `windows-tests`

Replace the Phase 3 verification step (P3-I05: "exports include new functions") with the
Phase 8 step (P8-I01: "exactly 5 exports, 18 absent"). The new step both asserts presence
of the 5 keepers and asserts absence of the 18 removed functions. The `dumpbin` check
verifies exactly 5 bridge functions by name. See Step 10 for the complete `cmd` script.

### 2. Add zero-warnings build step to the `windows-tests` job

Add a dedicated MSBuild invocation with `/warnaserror` for P8-I02. Place it **after** the
normal build succeeds, so the normal build output (artifacts, test DLLs) is available for
subsequent test steps regardless of warning status. This ensures that if `/warnaserror`
fails, the regular test suite still runs and provides diagnostic information.

```yaml
- name: Build with warnings-as-errors
  run: |
    msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror
```

### 3. Add CleanupTests.cs to the NUnit test run

The new test class `CleanupTests.cs` (containing P8-U01, P8-U02, P8-U03) must be included
in `Flash.Tests.csproj` via an explicit `<Compile Include="CleanupTests.cs" />` entry in
the `<ItemGroup>`. The project does NOT use wildcard globs -- it has explicit includes
for every test file (see current csproj: `SmokeTests.cs`, `JsonConfigTests.cs`,
`GoldenCaptureTests.cs`, `BridgeSmokeTests.cs`, `BridgeMS2Tests.cs`,
`ScanCommandLayoutTests.cs`, `BridgePhase3Tests.cs`, `BridgePhase4Tests.cs`,
`InterfaceShapeTests.cs`, `DataPipeTests.cs`, `AcquisitionLoop\ContinuityTests.cs`).

The NUnit console runner picks up all test classes compiled into `Flash.Tests.dll`.
Invoke the runner by its full NuGet packages path and set the working directory to
`FlashIDA/bin/` so native DLLs (OpenMS.dll and dependencies) are found by the .NET
runtime's DLL search path (Phase 0 lesson #12). Use `--agents=1` and
`--timeout=300000` to avoid parallel cold-cache timeouts from `calculateAveragine`
(Phase 1 lesson #8). Set `OPENMS_DATA_PATH` so the DLL can locate chemistry data
(Phase 1 lessons #5-#6):

```yaml
- name: Run NUnit tests
  env:
    OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS
  run: |
    & "packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe" `
        Flash.Tests.dll `
        --work=FlashIDA\bin `
        --agents=1 `
        --timeout=300000
```

### 4. Add Phase 8 C++ test to the `cpp-unit-tests` job (Phase 6 lesson 10)

The test for P8-U04 (legacy config rejection) runs on `ubuntu-latest`. It must be registered
in `OpenMS/src/tests/class_tests/openms/executables.cmake`. Add the test binary to BOTH
CI locations in the **same commit** as the test file creation:

**Build targets** (add to existing list -- after Phase 7, there are 6 targets):
```yaml
cmake --build OpenMS/build --target DeconvolvedSpectrum_OptimizationMetadata_test FLASHIdaQueueTracking_test FLASHIda_ProcessScan_test ScanCommandLayout_test FLASHIdaFAIMS_test FLASHIda_exploration_test FLASHIda_LegacyConfig_test
```

**CTest filter** (add to existing regex -- after Phase 7, there are 6 patterns):
```yaml
ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration|FLASHIda_LegacyConfig" --output-on-failure
```

This brings the total C++ test binaries to 7 (5 pre-Phase 7 + 1 Phase 7 + 1 Phase 8).

### 5. Regression suite covers all 10 configs

The regression runner script must include all 10 method configs listed in P8-R01 (including
`method_exploration.xml` added by Phase 7 with golden file `phase7_exploration.tsv`). If the
script was built incrementally (each phase adds its new configs), confirm the Phase 8 version
runs all prior configs plus Phase 7's. The canonical full config array (names, spectrum
file assignments, golden file names) is defined in
[../test-file-specification.md §4.2](../test-file-specification.md). No new method configs
are added in Phase 8 itself.

### Workflow trigger branches

No changes to trigger branches are needed. Phase 8 commits go to `flashida-v9-migration`,
which is already in the trigger list. The `phase-*` wildcard in the trigger list also covers
the current `phase-4` branch.

### Build #4 batching implications

Phase 8 is batched with Phase 7 in Build #4. This means:
- Phase 7's C++ changes (exploration engine) and Phase 8's C++ changes (dead code removal,
  legacy config rejection) can be pushed in the same batch to `flashida-v9-bridge`.
- The DLL rebuild (~40 min) covers both phases. Only one rebuild cycle is needed.
- The `build_dlls.yml` workflow only builds, it never runs CTest (Phase 6 lesson 11).
  C++ tests only execute in the parent repo CI.
- Phase 8's regression suite (P8-R01) runs against Phase 7 golden files, so Phase 7
  must be fully complete (golden files committed) before Phase 8 regression tests run.

### Commit strategy -- submodule batching (Phase 0 lesson #15, Phase 1 lesson #1)

Phase 8 touches both C++ (Steps 2-5) and C# (Steps 6-8) code. Batch all C++ changes
into a single OpenMS submodule commit before updating the submodule pointer, then batch
all C# changes together. This minimizes submodule pointer update churn.

After pushing to any submodule branch (`flashida-v9-bridge` for C++,
`flashida-v9-migration` for C#), always update the parent repo's submodule pointer
(`git add FlashIDA OpenMS` and push) before expecting CI to pick up the changes. The
CI workflow checks out submodules at the pointer commit, not at the branch HEAD -- new
files are silently invisible to CI until the pointer is updated (Phase 1 lesson #1).

---

## Working Product Verification

The following checks verify the working product after Phase 8 is complete. All are automated
by the test suite; this section maps each check to its test.

| Verification | Test | CI verification method |
|-------------|------|------------------------|
| `Flash.exe` runs in final form | P8-R01 | `windows-tests` job on `windows-latest`; check run logs and artifacts for `regression-runner` step |
| Exactly 5 DLL exports | P8-I01 | Bridge verification step in `windows-tests` on `windows-latest`; inspect the "Verify DLL exports" step output in CI run artifacts |
| Zero C# compile warnings | P8-I02 | `windows-tests` job on `windows-latest`; "Build with warnings-as-errors" step must exit 0 |
| MethodDocGenerator produces output | P8-U03 | Automated by P8-U03 NUnit test that asserts the generator returns a non-empty string; see `windows-tests` job NUnit results |
| No legacy P/Invoke declarations | P8-U01 | `windows-tests` job NUnit results for `CleanupTests.P8_U01` |
| ToFLASHDeconvInput absent | P8-U02 | `windows-tests` job NUnit results for `CleanupTests.P8_U02` |
| Legacy config rejected by C++ | P8-U04 | `cpp-unit-tests` job on `ubuntu-latest`; `ctest -R FLASHIda_LegacyConfig` output (Phase 2 lesson #4) |
| Full regression passes (incl. exploration) | P8-R01 | All 10 regression configs pass in CI, including Phase 7's `method_exploration.xml` with golden file `phase7_exploration.tsv` |
| Phase 7 exploration engine unaffected | P8-R01 | `method_exploration.xml` regression produces `EXPL-WINNER` log entries and matches `phase7_exploration.tsv` |
| FAIMS continuity tests still pass | CT09/CT10/CT27/CT28 | Continuity tests in NUnit suite verify FAIMS CV cycling (unified pipeline route) |
| ScanCommand struct unchanged | P3-U01/P3-U02 | `static_assert(sizeof(ScanCommand) == 1248)` in C++; `Marshal.SizeOf` = 1248 in C# |
| No dead code references | P8-U02 | Source-tree scan for `ToFLASHDeconvInput` returns zero hits |

---

## Definition of Done

Phase 8 is complete when all of the following are true:

### Functional completeness

- [ ] Step 1 pre-condition check passes: zero live callers of any of the 18 removed functions
      and zero callers of `ToFLASHDeconvInput` outside of `Parameter.cs` itself.

- [ ] `FLASHIdaBridgeFunctions.h` contains exactly 5 `extern "C" OPENMS_DLLAPI` declarations
      (including `ProcessScan` with `double faims_cv` parameter from Phase 6).

- [ ] `FLASHIdaBridgeFunctions.cpp` contains exactly 5 function definitions; no removed
      function names appear anywhere in the file.

- [ ] `FLASHIda.cpp` contains no `parseLegacy_()` definition and no `else parseLegacy_(arg)`
      branch in the constructor. The constructor rejects non-JSON input.

- [ ] `FLASHIda.h` contains no declaration for `parseLegacy_()` or any other private method
      deleted in Step 4. Phase 7 exploration methods and Phase 6 FAIMS methods are preserved.

- [ ] `FLASHIdaWrapper.cs` contains exactly 5 `[DllImport(dllName)]` lines (verified by
      P8-U01). `ProcessScan` includes `double faimsCv` parameter.

- [ ] `Parameter.cs` contains no `ToFLASHDeconvInput()` method and no helpers that existed
      solely for it (verified by P8-U02).

- [ ] `MethodDocGenerator.cs` exists, compiles, and produces non-empty output from
      `[Description]` attributes on `Parameter` (verified by P8-U03).

### Build quality

- [ ] C++ build succeeds with zero errors and zero warnings (MSVC `/WX`).

- [ ] `msbuild Flash.sln /warnaserror` succeeds with zero warnings (verified by P8-I02).

- [ ] `dumpbin /exports OpenMS.dll` shows exactly 5 bridge symbols; all 18 removed symbols
      are absent (verified by P8-I01).

### Test suite

- [ ] P8-U04 passes: C++ unit test confirms non-JSON input is rejected.

- [ ] P8-R01 passes: all 10 method configuration variants (including Phase 7's
      `method_exploration.xml`) produce output matching Phase 7 golden files. All runs
      emit `[TRACK-CREATE]` entries (CI hard-fail gate).

- [ ] All prior tests P0 through P7 continue to pass (~103 cumulative). No regressions
      introduced. In particular, struct size tests (P3-U01/P3-U02, updated in Phases 4 and 6)
      still pass with the final `ScanCommand` (1248 bytes) and `IsolationStage` (80 bytes)
      sizes, including `FaimsCv` offset assertion at 1240 in `ScanCommandLayoutTests.cs`.

- [ ] All P8-U* tests follow test quality standards: hard assertions only, no soft guards,
      no tautological tests, no queue passthrough (Phase 6 compliance standards).

### CI registration (Phase 6 lesson 10 -- must not be deferred)

- [ ] `FLASHIda_LegacyConfig_test` (or chosen name) is listed in `executables.cmake`.
- [ ] `FLASHIda_LegacyConfig_test` is in the `cmake --build --target` list in `flashida-ci.yml`.
- [ ] `FLASHIda_LegacyConfig_test` is in the `ctest -R` regex in `flashida-ci.yml`.
- [ ] All three CI registration items are in the **same commit** as the test file creation.
- [ ] Total C++ test binaries in CI after Phase 8: 7 (5 pre-Phase 7 + 1 Phase 7 + 1 Phase 8).

### CI workflow changes

- [ ] The `flashida-ci.yml` CI workflow includes: DLL export verification (5 present, 18
      absent), zero-warnings build step (`/warnaserror`), Phase 8 C++ test registration,
      and all 10 regression configs in the runner.

- [ ] `Flash.Tests.csproj` includes `<Compile Include="CleanupTests.cs" />` in the
      `<ItemGroup>` (explicit include, not wildcard).

### Build #4 and release

- [ ] Phase 8 changes are merged to `flashida-v9-migration` and Build #4 artifact (Phase 7 +
      Phase 8) is tagged and recorded. Build #4 is the final C++ build of the v9 migration.

### Regression verification

- [ ] ScanCommand struct unchanged: 1248 bytes, `static_assert` passes, `faims_cv` at
      offset 1240.
- [ ] Phase 7 exploration engine unaffected: `method_exploration.xml` regression passes,
      `EXPL-WINNER` log entries appear, `phase7_exploration.tsv` golden file comparison passes.
- [ ] FAIMS continuity tests (CT09/CT10/CT27/CT28) continue to pass.
- [ ] No references to `ScanScheduler`, `FAIMSScanProcessor`, or `ProcessorTests` remain
      in production code (comment references in `Flash.cs` are acceptable).

---

## Phase 0–7 Lessons Applied

The following lessons from Phases 0 through 7 were applied when authoring or revising this
plan. Each entry identifies where the lesson is reflected.

| Lesson | Source | Applied in Phase 8 plan |
|--------|--------|-------------------------|
| `Flash.exe` entry point is `FLASHIdaWrapper.Main()`; no `-t` flag | Phase 0 #1 | All `Flash.exe` invocations use `Flash.exe <input_file> <output_file> <method.xml> [ms2_file]` (Step 11, P8-R01 runner comment) |
| Build output is `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/` | Phase 0 #12 | `--work=FlashIDA\bin` in NUnit runner (CI section §3); working-directory references throughout |
| Thermo DLL secret requires Strategy B (openssl-encrypted zip) | Phase 0 #3 | P8-I02 and P8-R01 runner notes reference "Strategy B / openssl" |
| OpenMS DLLs are committed in `FlashIDA/dll/`; no download step needed | Phase 0 #5 | Prerequisites §2 and P8-R01 runner note confirm DLLs are in-repo |
| Test data path is one level up: `Path.Combine(TestDirectory, "..", "test-data")` | Phase 1 #2 | P8-U01 implementation note; do not use `"..\\..\\test-data"` |
| NUnit runner flags: `--agents=1 --timeout=300000` | Phase 1 #8 | CI section §3 NUnit YAML snippet |
| `OPENMS_DATA_PATH` must be set in any CI step that invokes OpenMS | Phase 1 #5–#6 | CI section §3 NUnit YAML snippet |
| Submodule pointer must be updated after every push to a submodule branch | Phase 1 #1 | Commit strategy section (submodule batching) |
| DLL build takes ~40 min; batch all C++ changes to minimise rebuild cycles | Phase 1 #10 | Prerequisites §2; Step 9 preamble |
| MSVC `/WX`: never silence C4189 by removing singleton initializer calls | Phase 1 #3–#4 | Step 9 build note warns against removing `ModificationsDB::getInstance()` |
| `dllName` constant must be `"OpenMS.dll"` with extension | Phase 0 #12 | Step 6 note: "Note: `dllName` must resolve to `"OpenMS.dll"` (with extension)" — already present |
| Both `FLASHIdaWrapper(IDAParameters)` and `FLASHIdaWrapper(MethodParameters)` exist; prefer the latter | Phase 1 #11 | Step 6 does not change constructor signatures; preference documented in existing text |
| Multi-scan spectrum parsers must stop at the first scan boundary | Phase 0 #9 | Test cases preamble: "Multi-scan parser note" |
| Silent zero-result failure mode from malformed input | Phase 0 #14 | Step 11 debugging note |
| Golden-file capture requires 2 commits minimum | Phase 0 #15 | P8-R01 golden file update note at end of description |
| `toSpectrum()` returns `MSSpectrum` by value, not void with out-param | Phase 2 #1 | No direct `toSpectrum()` call in Phase 8 tests, but noted for consistency if P8-U04 test code evolves to inspect spectra |
| `DeconvolvedSpectrum` constructor takes `scan_number`, not `ms_level` | Phase 2 #2 | No direct `DeconvolvedSpectrum` construction in Phase 8, but noted for consistency |
| `toSpectrum()` requires at least one PeakGroup pushed first | Phase 2 #3 | No direct `toSpectrum()` call in Phase 8 tests, but noted for any future test that exercises `toSpectrum()` |
| CTest naming: use `-R ClassName`, not `-R FLASH` | Phase 2 #4 | CI section §4 and P8-U04 runner note updated to use `-R ClassName` pattern |
| CI apt dependencies: full list established for ubuntu-latest | Phase 2 #5 | Implicit in CI configuration (references `environment-and-workflows.md` Section 1) |
| CMake flags: `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja` | Phase 2 #6 | No CMake invocation in Phase 8 plan, but noted for consistency with `cpp-unit-tests` job |
| ccache key uses `hashFiles('OpenMS/CMakeLists.txt')`, not `executables.cmake` | Phase 2 #7 | No direct ccache key reference in Phase 8, but noted for consistency with `cpp-unit-tests` job |
| `(void)var;` suppresses MSVC unused variable warnings under `/WX` | Phase 2 #8 | P8-U04 test section includes MSVC `/WX` note about `(void)var;` usage |
| Phase 2 cumulative: 59 tests (OptimizationMetadata, GetConfigInt/GetConfigDouble, 5 C++ unit tests) | Phase 2 #9 | Prerequisites §3 updated to reflect Phase 2 actual deliverables |
| `ScanCommand.scan_id` is the first field, not `msn_level` | Phase 3 | Phase 3-7 Deviations Impact section; all struct references use actual field order |
| `IsolationStage.collision_energy` is `double`, not `int` | Phase 3 | Phase 3-7 Deviations Impact section; P8-R01 fractional CE note |
| `IsolationStage.activation_type` is `char[32]`, not `char[16]` | Phase 3 | Phase 3-7 Deviations Impact section |
| `IsolationStage` size = 80 bytes | Phase 3 | Phase 3-7 Deviations Impact section |
| CI TRACK-CREATE check is hard-fail | Phase 3 F-5 | Phase 3-7 Deviations Impact section; P8-R01 CI gate note |
| `enqueue_timestamp_ms` (uint64_t) + 11 scoring fields + Pad2 added to ScanCommand (1144 → 1240 bytes) | Phase 4 | Phase 3-7 Deviations Impact section; struct size is not 1144 (nor 1152) |
| `faims_cv` (double) added to ScanCommand (1240 → 1248 bytes) | Phase 6 | Phase 3-7 Deviations Impact section; struct size is not 1144 |
| Phase 7 exploration engine uses fractional CE values | Phase 7 | P8-R01 fractional CE note; `method_exploration.xml` regression config |
| FAIMS tests must use continuity tests, not regression runner | Phase 5 #1 | P8-R01 FAIMS regression note; FAIMS configs produce identical non-FAIMS output through `Flash.exe` |
| No tautological tests (P5-U01 rated WEAK) | Phase 5 compliance | P8-U01/U02/U03 test design: all test meaningful behavioral or structural properties |
| No soft guards (CT09/CT10 HIGH severity, resolved in P6) | Phase 5 compliance | Phase 8 test expectations: no `if (results.Count > 0)` guards in Phase 8 tests |
| Golden files captured before transitions (TDD) | Phase 5 #3 | P8-R01 uses Phase 7 golden files captured before Phase 8 cleanup |
| Single wrapper architecture confirmed | Phase 5 #2 | No direct impact on Phase 8 (FAIMS already absorbed in Phase 6); noted for consistency |
| Adaptive skip needs 300 scans | Phase 5 #4 | No direct impact on Phase 8 (no new FAIMS tests added); noted for consistency |
| Phase 5 cumulative test count: 77 (not 76) | Phase 5 compliance | Prerequisites §3; Phase 5 Addendum; cumulative counts updated throughout |
| New C++ test binaries must be added to CI build targets AND CTest filter | Phase 6 #10 | CI section §4: `FLASHIda_LegacyConfig_test` added to both lists; same-commit rule enforced in DoD |
| DLL build workflow only builds, never runs CTest | Phase 6 #11 | Prerequisites §2; Phase 6 Addendum; Build #4 batching note |
| Off-by-one in loop assertions -- trace 3+ iterations by hand | Phase 6 #12 | Test cases preamble: test quality standards; no loop-based assertions in P8-U01/U02/U03 |
| Separate input and output values in state machine tests | Phase 6 #13 | Test cases preamble: test quality standards (no state machine tests in Phase 8) |
| No queue passthrough tests -- exercise production logic | Phase 6 #14 | Test cases preamble: test quality standards |
| 6-file lockstep rule for P/Invoke struct changes | Phase 6 #15 | Phase 6 Addendum; Prerequisites §6 (Phase 8 does NOT modify ScanCommand) |
| ScanScheduler.cs and FAIMSScanProcessor.cs deleted in Phase 6 | Phase 6 #8-9 | Phase 6 Addendum (deleted file references); Files to Create/Modify (NOT modified list); Step 4 (do NOT remove Phase 6 FAIMS methods) |
| CT09/CT10 hardened in Phase 6, CT22/CT18 remain in backlog | Phase 6 compliance | Phase 5 Addendum (CT09/CT10 section); DoD regression verification |
| P6-U07/U08 dead code tests removed from scope | Phase 6 deviation | Phase 6 Addendum; P8-U02 serves as automated dead code verification |
| ProcessScan bridge now accepts `double faims_cv` | Phase 6 #5 | Prerequisites §8; 5 keeper exports table; Step 6 C# declarations; Step 2 C++ header |
| `Flash.Tests.csproj` uses explicit `<Compile>` includes, not wildcard globs | Phase 8 discovery | CI section §3; Files to Create/Modify; DoD CI workflow changes |
| Variable name collision in `parseJSONConfig_()` -- use descriptive names, not `ss` | Phase 7 #1 | Phase 7 Addendum; no direct impact on Phase 8 code (Phase 8 removes `parseLegacy_`, not `parseJSONConfig_`) |
| Enums and structs used by tests must be in `public:` section | Phase 7 #2 | Phase 7 Addendum; Step 4 must NOT move Phase 7 enums to `private:` during cleanup |
| `JavaScriptSerializer` writes null for unset reference properties -- emit defaults | Phase 7 #3 | Phase 7 Addendum; no new JSON sub-objects in Phase 8, but pattern noted |
| No nullable `int?` in JSON serialization classes consumed by C++ | Phase 7 #4 | Phase 7 Addendum; no new JSON fields in Phase 8 |
| When adding required fields to `MethodParameters`, grep for `new MethodParameters` in tests | Phase 7 #5 | Phase 7 Addendum; Phase 8 does not add new required fields, but pattern noted |
| DLL must be updated before pushing parent submodule pointer | Phase 7 #6 | Phase 7 Addendum; Build #4 commit sequence (same as Phase 4 lesson, re-confirmed) |
| PeakGroup API: no `setIntensity()`, no `getMZ()` -- use `getMonoMass()` | Phase 7 #7 | Phase 7 Addendum; no new PeakGroup interaction in Phase 8 |
| Golden file capture requires regression runner entry first | Phase 7 #8 | Phase 7 Addendum; Phase 8 does not add new golden files |
| Exploration variants produce zero deconvolution in test mode -- expected | Phase 7 #9 | Phase 7 Addendum; P8-R01 `method_exploration.xml` regression expects this pattern |
| Method names differ from spec: `initiateExploration_` not `initiateMS2Exploration_` | Phase 7 compliance | Phase 7 Addendum; Step 4 "Do NOT remove" list corrected |
| `<SelectionStrategy>` replaces `<ParameterOptimization>` XML block | Phase 7 compliance | Phase 7 Addendum; Prerequisites §1 corrected |
| `variant_tracking_to_group_` lookup, not `EXPL:` prefix routing | Phase 7 compliance | Phase 7 Addendum; Prerequisites §1 corrected |
| 4 WEAK tests (P7-U03, U07, U11, U12) -- not blocking Phase 8 | Phase 7 compliance | Phase 7 Addendum; noted for backlog |

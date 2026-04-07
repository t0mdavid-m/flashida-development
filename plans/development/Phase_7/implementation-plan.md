# Phase 7: Exploration Engine — Implementation Plan

**Date:** 2026-03-21 (updated 2026-04-07 with Phase 6 lessons)
**Build:** Build #4 (batched with Phase 8). Build #4 is the final C++ build. All C++ changes for Phases 7 and 8 should be batched to minimize DLL rebuild cycles (~40 min each). The `build-dlls` workflow triggers automatically on push to `flashida-v9-bridge`.
**Source documents:**
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 7 section
- [../baseline-plan.md](../baseline-plan.md) — Issue 4 (MSn-Generalized Exploration Engine), Issue 9 (OptimizationMetadata)
- [../testing-strategy.md](../testing-strategy.md) — Phase 7 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative formats for spectrum files, golden files, config files, and test infrastructure scripts

---

## Goal

Implement a **per-MS-level model with two independent concerns** — **selection** and **exploration** — that unifies precursor selection, parameter exploration, and MS3 targeting under a single configurable framework. Each MS level (MS1, MS2, MS3) is independently configurable with:

- **Selection** (required at every level): How targets are ranked and picked for MSn+1. Uses simple metrics: `intensity` (rank by raw intensity) or `qscore` (rank by deconvolution quality score). Always present — every level needs a way to rank candidates. Set to `None` only at MS3 to disable MS3 entirely.
- **Exploration** (optional, MS2+ only): Whether to optimize scan parameters (CE sweep) at this level, and what metric to optimize for. Uses exploration metrics: `mass_count` (most deconvolved masses), `remaining_precursor` (least remaining precursor intensity), `fragment_count` (most fragment ions). Not applicable at MS1 (nothing to sweep). Defaults to `None` (disabled).

These are independent concerns. You can have:
- **Selection without exploration**: standard DDA (pick targets, single-shot). This is the default.
- **Selection with exploration**: pick targets, then CE sweep for each target at this level.
- **Exploration without selection at the next level**: CE sweep at MS2 but no MS3 targeting (MS3 selection = None).

The per-level model replaces three previously separate mechanisms:
1. **MS1 top-N selection** — The existing hardcoded top-N precursor ranking becomes `MS1.selection` (`intensity` or `qscore`) with `MS1.max_precursors` replacing the old top-N parameter. Existing mode-dependent filters (deep mode, inclusion/exclusion list, tag targeting, mass exclusion, thresholds) remain orthogonal — they control *which* precursors are candidates, while the selection metric controls *how* candidates are ranked. MS1 has no exploration (nothing to sweep).
2. **MS2 parameter optimization** — CE exploration via the optional `Exploration` block within the MS2 level config, replacing the old `ParameterOptimization` config. The MS2 `selection` metric (`intensity`/`qscore`) determines how MS2 deconvolution fragments are ranked when picking MS3 targets.
3. **MS3 targeting** — The old `ms3_enabled_` flag is replaced by setting MS3 `selection` to any metric (`intensity` or `qscore`), while `None` disables it. MS3 can independently have its own `Exploration` block for CE sweeps at the MS3 level.

All method configs must include `<SelectionStrategy>`. There is no backwards compatibility with old config formats — missing `<SelectionStrategy>` blocks cause a crash. All existing method XML files are updated as part of the pipeline transition (Step 12c).

There is no `depth` concept. Per-level selection and exploration fields control behavior explicitly. If MS2 has `exploration = mass_count` and MS3 has `exploration = fragment_count`, both levels explore independently, subject to the **chaining rule**: MS3 (regardless of its own exploration setting) always waits for the MS2 exploration winner before triggering when MS2 has exploration enabled; if MS2 has no exploration, MS3 triggers immediately from each MS2 result.

After this phase, FLASHIda can automatically sweep a range of collision energies for selected precursors, score each variant by the exploration metric, select a winner, optionally chain into MS3 exploration or targeting, and record the optimization outcome in `OptimizationMetadata` on the resulting `DeconvolvedSpectrum`.

This phase has no existing behavior to migrate. All code added here is additive to the C++ core that Phase 6 left in its final form.

---

## Prerequisites

The following must be complete and verified before starting Phase 7:

1. **Phase 6 delivered and all tests passing.** C++ fully owns the scan queue including FAIMS CV cycling. `ScanScheduler.cs` and `FAIMSScanProcessor.cs` have been deleted (confirmed: only a comment reference remains in `Flash.cs` line 283). `GetNextScanCommand` is the sole source of all scan commands including CV injection. The `ProcessScan` bridge now accepts `double faims_cv` as a parameter. ScanCommand is 1248 bytes with `faims_cv` at offset 1240.

2. **`OptimizationMetadata` struct exists** (delivered in Phase 2, Build #1). `OptimizationMetadata.h` is already present in the OpenMS source tree with 18 fields. `DeconvolvedSpectrum` already carries `std::optional<OptimizationMetadata> opt_metadata_` and the accessor methods `getOrCreateOptimizationMetadata()`, `getOptimizationMetadata()`, `hasOptimizationMetadata()`. The `toSpectrum()` method already serializes metadata fields via `setMetaValue()` when present. Phase 2 also delivered `GetConfigInt`/`GetConfigDouble` bridge functions and 5 C++ unit tests (cumulative: 59 tests after Phase 2; ~70 after Phase 4, 77 after Phase 5, ~90 after Phase 6). P5-U03 (`DeadCodeTests.cs`) and P6-U07/U08 (dead code tests) were never implemented — both gaps are closed (manual verification used instead). Key Phase 2 API details that Phase 7 must respect:
   - **`toSpectrum()` returns `MSSpectrum` by value** (`MSSpectrum toSpectrum(int to_charge, double tol = 10.0, bool retain_undeconvolved = false)`), NOT void with an out-parameter. All code must use `MSSpectrum out = ds.toSpectrum(1);`.
   - **`DeconvolvedSpectrum` constructor takes `scan_number`** (`explicit DeconvolvedSpectrum(int scan_number)`), NOT `ms_level`.
   - **`toSpectrum()` requires at least one PeakGroup** — it unconditionally accesses `peak_groups_[0].isPositive()`. Any test calling `toSpectrum()` must push a default `PeakGroup` first to avoid undefined behavior.

3. **Priority queue infrastructure in place** (Phase 3). `FLASHIda` already has `std::deque<ScanCommand> queues_[4]`, `queue_mutex_`, `pending_scan_map_`, and `cleanupExpiredCommands_()`. Priority 0 is already reserved for exploration (defined in Phase 3 / Phase 4 comments) but was never populated.

4. **`processScan()` MS2 routing in place** (Phase 4). The MS2 path already resolves a tracking ID from `pending_scan_map_` and routes by mode (tag targeting, quant, conditional follow-up, MS3 targeting). The exploration branch stub `if (ctx.exploration_group_id > 0) feedExplorationResult_(ctx, ms2_deconv)` was noted in the Issue 5 pseudocode but not implemented. This phase implements `feedExplorationResult_()` and all supporting state.

5. **JSON config exploration fields parsed** (Phase 1). The `exploration` object in the JSON schema (`enabled`, `max_depth`, `max_variants`) is already parsed by `FLASHIda`'s JSON constructor and stored. The full `<ParameterOptimization>` XML block is serialized to JSON by `Parameter.ToJSON()`. Phase 7 replaces the old exploration config model entirely with the per-level selection/exploration framework. The old Phase 1 fields (`max_variants_per_precursor`, `max_exploration_depth`, `ms2_exploration`, `ms3_exploration`, `scoring.metric_type`) are superseded. Phase 7 must read the new `selection_strategy` JSON object (see Step 1) and also handle the old `exploration` object for backwards compatibility.

6. **ms3 array parsing deferred from Phase 1.** Phase 1's JSON config parsing implemented `ms["ms2"]` array parsing into `ms2_configs_` but did not implement the corresponding `ms["ms3"]` array parsing. The Phase 1 pseudocode comment (`// ms2 and ms3 arrays are parsed into vectors for later use`) flagged this as pending. Phase 7 must implement ms3 array parsing in `FLASHIda.cpp`'s JSON constructor (`ms3_configs_` vector, mirroring the ms2 pattern) so that `buildMS3Command_()` can use ms3 activation and CE settings from the config.

7. **`method_exploration.xml` does not yet exist.** It must be created and committed as part of this phase alongside its golden file. The file's canonical location (`FlashIDA/test-data/configs/`), XML schema sections, and key parameter values are specified in [../test-file-specification.md](../test-file-specification.md) §3.1 and §3.2. The golden file is named `phase7_exploration.tsv` (see [../test-file-specification.md](../test-file-specification.md) §2.2).

### User-Provided Inputs

No new user-provided spectrum data is required for Phase 7 (reuses `ms1_standard.txt` from Phase 4). The new config file `method_exploration.xml` is created during implementation. The golden file `phase7_exploration.tsv` is captured via CI artifact.

---

## Phase 0–2 Lessons Learned — Cross-References

The following lessons from [../Phase_0/lessons-learned.md](../Phase_0/lessons-learned.md), [../Phase_1/lessons-learned.md](../Phase_1/lessons-learned.md), and Phase 2 apply to Phase 7. Read these before implementation.

1. **Flash.exe entry point (lesson #1):** The entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()`. There is no `-t` flag. Correct invocation: `Flash.exe <input_file> <output_file> <method.xml> [ms2_file]`.

2. **Build output path (lesson #12):** The actual build output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/`. All CI paths, test paths, and regression runner references must use `FlashIDA/bin/`.

3. **DLL name in P/Invoke (lesson #12):** The actual DLL import uses `"OpenMS.dll"` (with extension), not `"OpenMS"`. Any P/Invoke `[DllImport]` references must use the full filename.

4. **NUnit runner invocation (lesson #12):** CI invokes the NUnit console runner by full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.16.3/tools/nunit3-console.exe`), not by assuming it is on PATH. Working directory must be `FlashIDA/bin/` so that native DLLs (`OpenMS.dll` and dependencies) are found by the .NET runtime's DLL search path.

5. **Spectrum file format (lesson #2):** Spectrum files use tab-separated headers with RT in seconds (`Spec scan=N\t<seconds>`), not the space-separated format with RT in minutes described in test-file-specification.md. The parser divides by 60 internally.

6. **Thermo DLL strategy (lesson #3):** Thermo DLLs use Strategy B — openssl-encrypted zip committed to the repo (`FlashIDA/dependencies/thermo-dlls.zip.enc`), with the passphrase stored as `THERMO_DLL_PASSPHRASE` secret. Do not use base64 (exceeds GitHub secret limit) or GPG (Windows CI incompatibility).

7. **OpenMS DLLs (lesson #5):** OpenMS DLLs are already committed in `FlashIDA/dll/`. Do not add cache/download steps for OpenMS DLLs. MSBuild copies them to the build output via `CopyToOutputDirectory` in `Flash.csproj`.

8. **Golden file capture (lesson #15):** Golden-file capture requires a 2-commit minimum. The first commit runs CI and produces the golden artifact; the second commit includes the captured golden file. Phases with multiple golden files should batch captures into a single CI run.

9. **Test tier labels (lesson #12):** C# tests that load `OpenMS.dll` via P/Invoke (AL-CT / bridge tests) are Tier 2, not Tier 1, matching the convention that DLL-dependent tests are Tier 2.

10. **Silent P/Invoke failures (lesson #14):** The C++ deconvolution engine returns 0 results without an error code when input data is malformed. When deconvolution returns 0 results unexpectedly, log the input data characteristics (RT, peak count, first/last m/z, precursor mass/charge for MS2) before investigating engine internals. The bridge functions do not distinguish "no results found" from "input data is malformed."

11. **Submodule batching (lesson #15):** Batch same-side changes (all C# changes or all C++ changes) before updating the submodule pointer to reduce churn. In Phase 0, 48% of commits were submodule pointer updates.

12. **Multi-scan parser (lesson #9):** Any new code that loads spectrum TSV files must stop at the first scan boundary (`if (started) break;` on encountering a second `Spec` line). Flash.exe's `Main()` parser handles multi-scan correctly (processes scan N when scan N+1's header is encountered), but test parsers must stop at the first scan for single-scan loading.

13. **`.gitattributes` (lesson #4):** `FlashIDA/.gitattributes` has `* text eol=crlf`, which forces CRLF conversion on ALL files. Any new binary file extensions (`.enc`, `.gpg`, `.zip`, etc.) must be added to `.gitattributes` as `binary` before committing to prevent silent corruption.

The following lessons from [../Phase_1/lessons-learned.md](../Phase_1/lessons-learned.md) also apply:

14. **Submodule pointer update required for CI to see new files (Phase 1 lesson #1):** CI checks out submodules at the pointer commit, not at the branch HEAD. After pushing to either the `FlashIDA` or `OpenMS` sub-repo, always `git add FlashIDA OpenMS` in the parent repo and push the pointer update before expecting CI to pick up the changes. Without this step, new files (test classes, `.cs` source, C++ headers) are silently invisible to the CI build.

15. **Test data path: one level up from `bin/` (Phase 1 lesson #2):** `TestContext.CurrentContext.TestDirectory` resolves to `FlashIDA/bin/`. The correct relative path to test data is `Path.Combine(TestDirectory, "..", "test-data")` — one level up, not two. All existing test classes use this pattern; new test classes must follow it.

16. **NUnit runner flags: `--agents=1 --timeout=300000` (Phase 1 lesson #8):** `SpectralDeconvolution::calculateAveragine` takes ~3.5 minutes on the first call in a CI process (cold cache). Set `--agents=1` to prevent parallel cold-cache computations and `--timeout=300000` (5 minutes) to prevent the first-call timeout. Keep these flags in all NUnit invocations.

17. **`OPENMS_DATA_PATH` required in CI (Phase 1 lesson #5):** Any CI step that invokes OpenMS functionality via P/Invoke must set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`. Without it the DLL crashes with `Cannot find shared data! OpenMS cannot function without it!`. This applies to NUnit test steps and `Flash.exe` regression runs.

18. **DLL build takes ~40 minutes; batch all C++ changes (Phase 1 lesson #10):** Each push to the OpenMS submodule branch triggers a full MSVC build (~40 min). Batch all C++ changes for Phase 7 into a single push to minimize rebuild cycles. Verify code compiles locally for obvious MSVC issues before pushing.

19. **MSVC `/WX` treats warnings as errors (Phase 1 lesson #3):** MSVC's `/WX` flag is active. Unused parameters (`C4100`) and initialized-but-unreferenced variables (`C4189`) are build errors on Windows even if they compile cleanly under GCC/Clang. Fix these before pushing.

20. **`ModificationsDB::getInstance()` has initialization side effects — never remove (Phase 1 lesson #4):** Calls to `ModificationsDB::getInstance()` (and other OpenMS singleton initializers: `ResidueDB::getInstance()`, `ElementDB::getInstance()`) must not be removed or commented out, even if their return values are unused. These calls initialize the OpenMS shared data path resolver as a side effect; removing them causes a fatal crash at runtime. Use `(void)` cast to suppress unused-variable warnings while preserving the call.

21. **Constructor preference: `FLASHIdaWrapper(MethodParameters)` (Phase 1 lesson #11):** Both `FLASHIdaWrapper(IDAParameters)` and `FLASHIdaWrapper(MethodParameters)` constructors exist. The `MethodParameters` overload uses `ToJSON()` (full JSON config including exploration fields). Prefer this constructor in Phase 7 test code. The `IDAParameters` overload remains for backward compatibility with bridge tests and legacy paths.

22. **ms3 array parsing deferred from Phase 1 (Phase 1 lesson, deferred work):** Phase 1's JSON config parsing parsed the `ms["ms2"]` array into `ms2_configs_` but did not implement the corresponding ms3 array parsing. The comment in the pseudocode (`// ms2 and ms3 arrays are parsed into vectors for later use`) acknowledged ms3 parsing as pending. Phase 7 is the appropriate phase to implement ms3 array parsing in the JSON config path, since `buildMS3Command_()` (Step 8) needs ms3 activation and CE settings from the config.

The following lessons from Phase 2 also apply:

23. **`toSpectrum()` returns `MSSpectrum` by value (Phase 2 lesson #1):** The API is `MSSpectrum toSpectrum(int to_charge, double tol = 10.0, bool retain_undeconvolved = false)`. It does NOT use an out-parameter. All Phase 7 code and tests that call `toSpectrum()` must use the return-value pattern: `MSSpectrum out = ds.toSpectrum(1);`. This is directly relevant to P7-U10 and any code that serializes `OptimizationMetadata`.

24. **`DeconvolvedSpectrum` constructor takes `scan_number` (Phase 2 lesson #2):** The constructor signature is `explicit DeconvolvedSpectrum(int scan_number)`, NOT `ms_level`. Phase 7 test code creating `DeconvolvedSpectrum` instances must use `scan_number` as the parameter name and semantics.

25. **PeakGroup prerequisite for `toSpectrum()` (Phase 2 lesson #3):** `toSpectrum()` unconditionally accesses `peak_groups_[0].isPositive()`. Any test calling `toSpectrum()` must push a default `PeakGroup` into the `DeconvolvedSpectrum` first to avoid undefined behavior. This applies to P7-U10 and any Phase 7 test that exercises metadata serialization via `toSpectrum()`.

26. **CTest naming convention (Phase 2 lesson #4):** Use `-R ClassName` pattern (e.g., `-R FLASHIda_exploration`) for specific tests, not `-R FLASH`. Test binaries follow the OpenMS `ClassName_test.cpp` convention.

27. **CI apt dependencies (Phase 2 lesson #5):** The full apt list for `cpp-unit-tests` on `ubuntu-latest` is: `build-essential ccache ninja-build qt6-base-dev libeigen3-dev libboost-random-dev libboost-regex-dev libboost-iostreams-dev libboost-date-time-dev libboost-math-dev libxerces-c-dev zlib1g-dev libsvm-dev libbz2-dev liblzma-dev libzstd-dev coinor-libcoinmp-dev`.

28. **CMake flags for test-only builds (Phase 2 lesson #6):** Use `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`. These flags skip GUI and Python bindings.

29. **ccache key uses `hashFiles('OpenMS/CMakeLists.txt')` (Phase 2 lesson #7):** The ccache key hashes `OpenMS/CMakeLists.txt` for cache invalidation, not `executables.cmake`.

30. **`(void)var;` for MSVC `/WX` compliance in test code (Phase 2 lesson #8):** When a variable is used only in a `TEST_EQUAL` assertion but not otherwise referenced, MSVC will warn about unused variables under `/WX`. Use `(void)var;` after the assertion to suppress the warning. This applies to all Phase 7 C++ unit tests (P7-U01 through P7-U11). Example: `(void)meta;` after asserting on metadata fields.

31. **Cumulative test counts (Phase 2 lesson #9, updated with Phase 5 actuals):** After Phase 2, there were 59 cumulative tests. Actual counts after subsequent phases: Phase 4 ~70, Phase 5 77, Phase 6 ~90. Phase 7 adds 13 tests (P7-U01 through P7-U12 + P7-R01, P7-R02), bringing the cumulative total to ~103.

The following lessons from [../Phase_5/lessons-learned.md](../Phase_5/lessons-learned.md) and [../Phase_5/compliance-report.md](../Phase_5/compliance-report.md) also apply:

32. **FAIMS tests must use continuity tests, not regression runner (Phase 5 lesson #1):** `Flash.exe` test mode bypasses the entire C# acquisition loop — it ignores the `cv=` field, has no `ScanScheduler`, no `FAIMSScanProcessor`, no per-CV routing. FAIMS behavior is only testable through acquisition loop continuity tests (CT09/CT10/CT27/CT28). Never add FAIMS configs to the regression runner. Phase 7's P7-R01/P7-R02 regression tests do not cover FAIMS — FAIMS coverage is via continuity tests only.

33. **Single wrapper architecture — no per-CV limitation (Phase 5 lesson #2):** `FAIMSScanProcessor` uses a single shared `FLASHIdaWrapper`, not per-CV wrappers. The supposed "per-CV wrapper limitation" was a myth. The actual root cause of prior low/zero results was insufficient test data (9-15 scans). Don't accept architectural limitation claims at face value — read the actual code.

34. **Capture golden files BEFORE architecture transitions (Phase 5 lesson #3):** Golden files should capture the current working behavior before a transition, so the new implementation can be verified against it. Capturing after the transition provides no regression baseline.

35. **Adaptive skip needs 300 scans, not 50 (Phase 5 lesson #4):** FAIMS adaptive skip tests (CT27/CT28) need all 300 scans from `ms1_faims_3cv.txt`. 50 scans is insufficient because the scheduler actively reduces how many scans each CV receives. Phase 7 does not add FAIMS tests, but this principle applies to any new test that depends on engine state accumulation.

36. **No tautological tests (Phase 5 compliance finding):** P5-U01 was rated WEAK — it tested `new UnifiedScanProcessor(null)` + IsNotNull, which is a tautology (`new` never returns null in C#). Phase 7's new tests (P7-U01 through P7-U11) must test behavioral properties (scoring logic, queue placement, state transitions), not just object instantiation or field existence.

37. **No soft guards in tests (Phase 5 compliance finding):** CT09/CT10 had `if (results.Count > 0)` conditional validation (HIGH severity). These pass silently with zero results. Phase 7 tests must use hard assertions (`Assert`, `TEST_EQUAL`) with proper test data, never conditional validation or `Assume.That` guards.

---

## Phase 3–6 Deviations Impact

The following deviations discovered or introduced during Phases 3–6 affect Phase 7 implementation. All code in this phase must use the actual types and sizes listed here, not the original plan values.

1. **ScanCommand field order** — `scan_id` is the first field (not `msn_level`). Done for cache alignment in Phase 3. Phase 7 code must not assume `msn_level` is at offset 0.

2. **`IsolationStage.collision_energy` is `double` (not `int`)** — This is critical for Phase 7's exploration engine. Fractional CE values (e.g., 22.5 NCE) are valid and must be supported. All CE-related variables, parameters, and return types in Phase 7 must use `double`, not `int`. This affects `ExplorationVariant.collision_energy`, `buildCEVariants_()` return type, and the CE config fields (`ms2_ce_min_`, `ms2_ce_max_`, `ms2_ce_step_`, and their MS3 counterparts).

3. **`IsolationStage.activation_type` is `char[32]` (not `char[16]`)** — Accommodates longer activation names like EThcD. Phase 7's multi-activation exploration must use 32-byte buffers when constructing activation type strings for `ScanCommand.stages[].activation_type`.

4. **`IsolationStage` size = 80 bytes** — Unchanged from Phase 3. No impact on Phase 7 beyond awareness.

5. **`ScanCommand.enqueue_timestamp_ms` already present (from Phase 4)** — `uint64_t enqueue_timestamp_ms` was added to `ScanCommand` in Phase 4, along with 11 scoring fields that brought the struct from 1144 bytes (Phase 3) to **1240 bytes**. Phase 7 exploration commands should populate this field (e.g., via `currentTimeMs_()`) for consistency with the audit trail. The `ExplorationGroup.start_ms` field is separate (group-level timestamp), but each individual `ScanCommand` also carries its own enqueue timestamp.

6. **`ScanCommand.faims_cv` already present (from Phase 6)** — `double faims_cv` was added to `ScanCommand` in Phase 6. Phase 7 exploration commands must populate `faims_cv` via `currentCV_()` (or 0.0 in non-FAIMS mode). The `ExplorationGroup.faims_cv` field already captures this (see Step 4), and child MS3 groups inherit the parent's CV (see Step 8).

7. **ScanCommand size** — The struct size progression: 1144 (Phase 3) -> **1240** (Phase 4, added `enqueue_timestamp_ms` + 11 scoring fields) -> **1248** (Phase 6, added `faims_cv`). Phase 7 must use the current post-Phase-6 size (1248) in any size assertions or layout assumptions. Do not hard-code 1144 (Phase 3) or 1240 (Phase 4).

8. **CI `[TRACK-CREATE]` is hard-fail (from Phase 4)** — Every regression test must produce `[TRACK-CREATE]` entries in stdout or CI will fail. Phase 7's exploration commands are pushed via `queues_[0]` with `logTrackCreate_(cmd)` calls (Step 4, Step 8). The `P7-R02` regression test must emit `[TRACK-CREATE]` entries for all exploration variant commands. Failure to emit these entries will cause the CI gate to fail, independent of golden-file comparison.

9. **FAIMSScanProcessor and ScanScheduler deleted in Phase 6 (confirmed)** — Both `FAIMSScanProcessor.cs` and `ScanScheduler.cs` were deleted in Phase 6 Step 9. Removed from `Flash.csproj`. The only remaining reference is a comment in `Flash.cs` line 283. All FAIMS CV cycling is handled by the C++ state machine via `processScan()` and `getNextScanCommand()`. The `ProcessScan` bridge now accepts `double faims_cv` as a parameter.

10. **Test quality: no tautological tests or soft guards (from Phase 5-6 compliance)** — Phase 5 compliance rated P5-U01 as WEAK (tautological). CT09/CT10 soft guards were hardened in Phase 6 (now rated GOOD). Phase 6 compliance additionally identified: P6-U01 off-by-one assertion bug, P6-U06 queue passthrough bypassing production logic. CT22 and CT18 soft guards remain in backlog. Phase 7 tests must not repeat any of these patterns. All P7-U* tests must test behavioral properties (scoring, queue placement, state transitions). All assertions must be hard (`TEST_EQUAL`, `Assert.That`), never conditional.

11. **P5-U03 gap carried forward; P6-U07/U08 removed from scope** — `DeadCodeTests.cs` was never created in Phase 5. Phase 6 removed P6-U07/U08 (dead code tests) from scope per user direction; dead code verification was done via manual grep instead. Phase 7 should not introduce additional dead code test gaps.

12. **CI explicit allowlist for C++ tests (from Phase 6 compliance audit)** — `flashida-ci.yml` uses explicit `--target` and `-R` lists, NOT test discovery. When Phase 7 creates `FLASHIda_exploration_test.cpp` and registers it in `executables.cmake`, it must ALSO be added to both CI lists in the same commit. Current targets (as of Phase 6): `DeconvolvedSpectrum_OptimizationMetadata_test`, `FLASHIdaQueueTracking_test`, `FLASHIda_ProcessScan_test`, `ScanCommandLayout_test`, `FLASHIdaFAIMS_test`.

13. **Test quality standards from Phase 6 compliance audit** — The audit identified specific failure patterns: (a) off-by-one in loop assertions using shifted indices (P6-U01), (b) shared input/output arrays hiding assertion bugs (P6-U01/U02), (c) queue passthrough tests that bypass production logic (P6-U06). All Phase 7 tests must avoid these patterns. See Phase 6 Addendum for specific test-by-test guidance.

14. **Existing test helpers in FLASHIda.h** — Phase 3-6 added public test-only methods: `encodeBase36ForTest()`, `pushCommandForTest()`, `getPendingScanMapSizeForTest()`, `decodeBase36ForTest()`, `updateCVSkipForTest()`, `getCVSkipAmountForTest()`. Phase 7 will likely need new helpers for exploration state inspection (e.g., `getActiveExplorationGroupCountForTest()`, `getExplorationGroupForTest(int group_id)`).

---

## Phase 5 Addendum (2026-04-05)

*Updates based on Phase 5 actual outcomes, compliance report, and lessons learned. See `Phase_5/compliance-report.md` and `Phase_5/lessons-learned.md` for full details.*

**Phase 5 status: COMPLETE.** `FAIMSScanProcessor` retained with full legacy path (not delegating to `UnifiedScanProcessor`). `ScanScheduler` retained. Both are deleted in Phase 6. By the time Phase 7 begins, neither file exists — all FAIMS CV cycling is handled by the C++ state machine.

**Cumulative test count at Phase 5: 77** (not 76). Five new tests: P5-U01, P5-U02, P5-U04, CT27 activated, CT28 activated. P5-U03 (`DeadCodeTests.cs`) was not implemented — gap carried forward through Phase 6.

**FAIMS TSV golden files not captured.** `Flash.exe` test mode bypasses FAIMS entirely — it ignores the `cv=` field, has no `ScanScheduler`, no per-CV routing (Phase 5 Lesson 1). FAIMS coverage is via continuity tests only (CT09/CT10/CT27/CT28). This means Phase 7's P7-R01/P7-R02 regression tests do not cover FAIMS via TSV. FAIMS continuity tests provide that coverage.

**CT09/CT10 soft guards resolved in Phase 6.** CT09 was hardened to hard assertion on `Count > 0` in Phase 6 Step 0. CT10 now has hard assertion verifying MS2 parent CV. Both rated GOOD in the Phase 6 compliance audit. Phase 7 inherits these fixes. Note: CT22 (if-guarded MS3 assertions) and CT18 (Assume.That soft guards) remain in the backlog — Phase 7 tests must not introduce new soft guards of either type.

**Test quality expectations from Phase 5 compliance.** P5-U01 was rated WEAK (tautological constructor test — `new` never returns null in C#). No tautological tests in Phase 7. All P7-U01 through P7-U11 must test behavioral properties: scoring logic, queue placement, state transitions, metadata population. No soft guards — all tests must have hard assertions with proper test data.

**Adaptive skip data requirements.** FAIMS adaptive skip tests need 300 scans, not 50 (Phase 5 Lesson 4). Phase 7 does not add FAIMS tests, but this principle applies to any new test that depends on engine state accumulation. Exploration tests (P7-U01 through P7-U11) use synthetic data and are not affected, but P7-R01/P7-R02 regression tests use `ms1_standard.txt` which has 50 scans — sufficient for non-FAIMS exploration.

**Exploration commands must populate `faims_cv`.** Phase 6 adds `faims_cv` to `ScanCommand`. Exploration commands pushed to `queues_[0]` via `initiateExploration_()` must populate `faims_cv` via `currentCV_()` (or 0.0 in non-FAIMS mode). This is already noted in Step 4 and the Phase 3-6 Deviations Impact section (item 6), but is reinforced here because Phase 5 confirmed the single-wrapper architecture — all commands, including exploration variants, share the same FAIMS CV context.

---

## Phase 6 Addendum (2026-04-07)

*Updates based on Phase 6 actual outcomes, compliance report, and 15 lessons learned. See `Phase_6/lessons-learned.md` and `Phase_6/compliance-report.md` for full details.*

**Phase 6 status: COMPLETE.** FAIMS CV cycling state machine ported to C++. `ScanScheduler.cs` and `FAIMSScanProcessor.cs` are deleted. All FAIMS CV cycling now handled by C++ via `processScan()` and `getNextScanCommand()`. The unified pipeline is:
```
Instrument -> Flash.ProcessSpectrum -> DataPipe -> UnifiedScanProcessor.ProcessMS
  -> FLASHIdaWrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc, faimsCv)
  -> C++ ProcessScan bridge -> FLASHIda::processScan(... faims_cv)
  -> FLASHIdaWrapper.GetNextScanCommand -> ScanFactory.BuildFromCommand -> Instrument
```

**Cumulative test count at Phase 6: ~90.** Six new C++ FAIMS tests (P6-U01 through P6-U06), continuity tests re-verified.

**ProcessScan bridge now accepts `faims_cv` parameter.** The bridge function signature was extended with `double faims_cv`. All Phase 7 code calling `processScan()` for testing must provide this parameter (0.0 for non-FAIMS).

### Pre-implementation checklist (MUST complete before starting Phase 7 code)

The following items were identified as critical by the Phase 6 compliance audit and must be verified before Phase 7 implementation begins:

1. **CI filter includes all existing test binaries.** Verify that `flashida-ci.yml` line 58 (`cmake --build --target`) and line 63 (`ctest -R`) include `FLASHIdaFAIMS_test`. As of Phase 6 completion, the targets are: `DeconvolvedSpectrum_OptimizationMetadata_test`, `FLASHIdaQueueTracking_test`, `FLASHIda_ProcessScan_test`, `ScanCommandLayout_test`, `FLASHIdaFAIMS_test`. Phase 7 will add `FLASHIda_exploration_test` to both lists.

2. **6-file lockstep rule acknowledged.** Phase 7 does NOT modify `ScanCommand` — the struct is already at 1248 bytes with all needed fields (`enqueue_timestamp_ms` from Phase 4, `faims_cv` from Phase 6). However, if any late-breaking need arises to change the struct, the 6-file lockstep rule applies:
   - `FLASHIda.h` (C++ struct + `static_assert`)
   - `FLASHIda.cpp` (populate new field)
   - `ScanCommandLayout_test.cpp` (C++ offsetof printer)
   - `FLASHIdaWrapper.cs` (C# struct)
   - `ScanCommandLayoutTests.cs` (C# `Marshal.SizeOf` assertion)
   - `ScanCommandLayoutTests.cs` (offset assertion for new field)

3. **Test quality standards enforced.** All P7-U01 through P7-U11 must follow these rules from Phase 6 compliance:
   - **No soft guards:** Use `TEST_EQUAL` / `Assert.That`, never `if (x > 0)` conditional validation or `Assume.That` (Phase 6 lesson 12-14).
   - **Separate input and output values:** State machine tests with both input (observed state) and output (next action) must use separate arrays, not a single shared array (Phase 6 lesson 13).
   - **No queue passthrough tests:** Tests must exercise production logic paths (e.g., call `processScan()`), not bypass them by pushing pre-built commands via test helpers (Phase 6 lesson 14).
   - **Trace loop assertions by hand:** For any loop-based test assertion with index arithmetic, trace at least 3 iterations by hand against the actual implementation to catch off-by-one errors (Phase 6 lesson 12).

4. **ScanCommand size is 1248 bytes.** Confirmed in `FLASHIda.h` line 109 via `static_assert(sizeof(ScanCommand) == 1248)`. Do not use old sizes (1144 from Phase 3, 1240 from Phase 4).

5. **Per-phase test helpers pattern.** `FLASHIda.h` has public test-only methods: `encodeBase36ForTest()`, `pushCommandForTest()`, `getPendingScanMapSizeForTest()`, `decodeBase36ForTest()`, `updateCVSkipForTest()`, `getCVSkipAmountForTest()`. Phase 7 may need additional test helpers for exploration engine testing (e.g., `getActiveExplorationGroupsForTest()`, `initiateMS2ExplorationForTest()`). Add these following the same pattern: public method name ending in `ForTest`, documented with `/// Test-only:` comment.

6. **DLL build workflow only builds, never tests.** The `build_dlls.yml` in the OpenMS repo has no `ctest_test()` call (Phase 6 lesson 11). C++ tests only execute in the parent repo's `flashida-ci.yml`. Do not assume a successful DLL build means tests pass.

7. **Golden file re-capture expectations.** Phase 7 adds new behavior (exploration variants) that produces new golden files. Existing golden files (`phase4_standard_dda.tsv`, `continuity_faims_skip.json`) should NOT change because exploration is disabled in those configs. If they do change, it indicates a regression. Always diff old vs new before accepting any golden file changes (Phase 6 lesson 7).

### Phase 6 lessons applied to Phase 7 test specifications

The Phase 6 compliance audit identified specific test quality failures. Phase 7 test specifications already avoid these patterns, but the following checks must be applied during implementation:

- **P7-U01 (CE variant creation):** Verify all 5 CE values individually by index, not via shifted-index loop. Do NOT use `expected_ces[(i+1) % size]` pattern (Phase 6 lesson 12 — this exact bug hit P6-U01).
- **P7-U03 (winner selection):** Use separate `input_scores` and `expected_winner_index` variables. Do not reuse a single array for both feeding scores and checking the winner.
- **P7-U05/U06 (cycle time suppression/resumption):** These are state machine tests. Verify each state transition individually, not in a loop with index arithmetic.
- **P7-U07 (MS3 exploration):** Verify child group properties (msn_level, exploration_metric, parent_tracking_id) with direct assertions, not indirect queue inspection that might pass by coincidence.

### Deleted file references cleaned up

The following files referenced in earlier plan drafts no longer exist as of Phase 6:
- `Flash/ScanScheduler.cs` — deleted in Phase 6 Step 9
- `Flash/IDA/FAIMSScanProcessor.cs` — deleted in Phase 6 Step 9
- Both are removed from `Flash.csproj`
- The only remaining reference is a comment in `Flash.cs` (line 283): *"ScanScheduler and FAIMSScanProcessor are deleted."*
- `ProcessorTests.cs` and `DeadCodeTests.cs` were never created (P5-U03 gap carried forward; P6-U07/U08 removed from scope per user direction)

---

## Detailed Implementation Steps

### Step 1: Extend JSON config parsing for per-level selection and exploration config

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Phase 1 stored only the top-level `exploration.enabled`, `exploration.max_depth`, and `exploration.max_variants` fields. Phase 7 replaces the old per-flag model with a **per-MS-level model with two independent concerns** — selection and exploration. Add the following types and member variables to `FLASHIda.h` under a clearly marked `// --- Selection and exploration config ---` comment block:

```cpp
// --- Selection metric enum: how targets are ranked for MSn+1 ---
enum class SelectionMetric
{
    None = 0,    // No selection at this level — don't select targets for MSn+1
    Intensity,   // rank by raw intensity
    QScore       // rank by deconvolution quality score
};

// --- Exploration metric enum: what to optimize during CE sweep (MS2+ only) ---
enum class ExplorationMetric
{
    None = 0,            // no exploration at this level (default)
    MassCount,           // optimize for most deconvolved masses
    RemainingPrecursor,  // optimize for least remaining precursor intensity
    FragmentCount        // optimize for most fragment ions
};

// --- Per-level config: selection (required) + exploration (optional, MS2+ only) ---
struct MSLevelConfig
{
    // Selection: how targets are ranked for MSn+1
    SelectionMetric selection = SelectionMetric::Intensity;
    int max_targets = 10;     // MS1: max precursors (replaces old top-N); MS2/MS3: max fragments for next level

    // Exploration (optional, MS2+ only): CE sweep at THIS level
    ExplorationMetric exploration = ExplorationMetric::None;
    double ce_min = 20.0;       // double: IsolationStage.collision_energy is double (Phase 3 deviation)
    double ce_max = 40.0;       // double: supports fractional CE steps
    double ce_step = 5.0;       // double: e.g., step=2.5 for fine-grained sweeps
    std::string activation = "HCD";

    // Exploration parameter overrides (optional): scan parameters that differ
    // during exploration sweeps vs production scans. Any ScanCommand field name
    // can be overridden (e.g., "agc_target", "max_injection_time_ms",
    // "isolation_width"). During exploration, variants use the overridden values
    // (e.g., lower AGC for faster sweeps). After the winner is selected, a
    // production scan is pushed with the winning CE but original (non-overridden)
    // parameters. The production scan goes through the normal processScan() path,
    // triggering standard downstream processing (MS3 targeting, output, etc.).
    std::unordered_map<std::string, std::string> overrides;  // field_name -> value (as string, parsed at apply time)
};

// Helper: returns true if this level has exploration enabled
static bool hasExploration(const MSLevelConfig& cfg)
{
    return cfg.exploration != ExplorationMetric::None;
}
```

Note: `max_targets` replaces both the old top-N parameter (at MS1 level) and `max_fragments_to_explore` (at MS3 level). This unifies the "how many targets to select" concept across all levels. Selection and exploration are independent — a level can have selection without exploration (standard DDA), selection with exploration (CE sweep), or exploration without selection at the next level. MS1 never has exploration (nothing to sweep).

Add the following private member variables:

```cpp
// --- Per-level config (indexed by MSn level: 1, 2, 3, ...) ---
// Using a map allows arbitrary MSn levels without hardcoding MS1/MS2/MS3.
std::unordered_map<int, MSLevelConfig> level_configs_;
bool exploration_enabled_ = false;  // convenience: true if any level has exploration != None

// Accessor: returns config for a given MSn level, or a default (selection=None,
// exploration=None) if the level is not configured.
const MSLevelConfig& getLevelConfig_(int msn_level) const
{
    static const MSLevelConfig default_config{SelectionMetric::None, 10,
        ExplorationMetric::None, 20.0, 40.0, 5.0, "HCD", {}};
    auto it = level_configs_.find(msn_level);
    return (it != level_configs_.end()) ? it->second : default_config;
}
```

Default initialization (in constructor or after config parsing):
```cpp
// level_configs_[1]: selection=QScore, max_targets=10, exploration=None
// level_configs_[2]: selection=Intensity, max_targets=3, exploration=None
// level_configs_[3]: selection=None (MS3 disabled), exploration=None
```

Note: `level_configs_[1].selection` defaults to `QScore` (matching the current FLASHIda behavior of ranking precursors by deconvolution quality). `level_configs_[3].selection` defaults to `None` (MS3 disabled). When parsing old configs without `<SelectionStrategy>`, if `ms3_enabled_` was true, set `level_configs_[3].selection = Intensity`. The `exploration_enabled_` convenience boolean is computed after parsing by scanning all levels.

In the JSON parsing branch in `FLASHIda.cpp`, read the new `selection_strategy` object. The parser is generalized — it iterates over any `msN` key, parsing the level number from the key name. This allows arbitrary MSn levels without hardcoding:

```cpp
// Helper: parse a single level config from a JSON object
void FLASHIda::parseLevelConfig_(MSLevelConfig& cfg, const json& obj, int msn_level)
{
    cfg.selection = parseSelectionMetric_(
        obj.value("selection", msn_level == 1 ? std::string("qscore") : std::string("intensity")));
    cfg.max_targets = obj.value("max_targets",
        obj.value("max_precursors",      // alias for MS1
        obj.value("max_fragments", 10)));  // alias for MS2/MS3
    if (obj.contains("exploration") && msn_level > 1) {
        auto& ex = obj["exploration"];
        cfg.exploration = parseExplorationMetric_(ex.value("metric", std::string("none")));
        cfg.ce_min = ex.value("ce_min", 20.0);
        cfg.ce_max = ex.value("ce_max", 40.0);
        cfg.ce_step = ex.value("ce_step", 5.0);
        cfg.activation = ex.value("activation", std::string("HCD"));
        // Optional overrides
        if (ex.contains("overrides")) {
            for (auto& [key, val] : ex["overrides"].items())
                cfg.overrides[key] = val.get<std::string>();
        }
    }
}

// --- New selection_strategy config ---
if (j.contains("selection_strategy")) {
    auto& ss = j["selection_strategy"];
    // Parse each "msN" key (ms1, ms2, ms3, ...)
    for (auto& [key, val] : ss.items()) {
        if (key.substr(0, 2) == "ms" && key.size() > 2) {
            int level = std::stoi(key.substr(2));
            parseLevelConfig_(level_configs_[level], val, level);
        }
    }
}
// Compute convenience boolean
exploration_enabled_ = false;
for (const auto& [level, cfg] : level_configs_)
    if (hasExploration(cfg)) { exploration_enabled_ = true; break; }
```

Add private helpers to parse metric strings:

```cpp
SelectionMetric FLASHIda::parseSelectionMetric_(const std::string& s) const
{
    if (s == "intensity") return SelectionMetric::Intensity;
    if (s == "qscore") return SelectionMetric::QScore;
    if (s == "none") return SelectionMetric::None;
    return SelectionMetric::Intensity;  // safe default
}

ExplorationMetric FLASHIda::parseExplorationMetric_(const std::string& s) const
{
    if (s == "mass_count") return ExplorationMetric::MassCount;
    if (s == "remaining_precursor") return ExplorationMetric::RemainingPrecursor;
    if (s == "fragment_count") return ExplorationMetric::FragmentCount;
    if (s == "none") return ExplorationMetric::None;
    return ExplorationMetric::None;  // safe default
}
```

Also update `Parameter.ToJSON()` in `FlashIDA/src/Flash/IDA/Parameter.cs` to serialize the `<SelectionStrategy>` XML subtree into the `selection_strategy` JSON object with the key names used above. This ensures the full round-trip: `method_exploration.xml` -> `ToJSON()` -> C++ parse -> all fields correct. For backwards compatibility, if the XML contains the old `<ParameterOptimization>` block without `<SelectionStrategy>`, `ToJSON()` should emit the legacy `exploration` JSON object so the C++ fallback path handles it.

---

### Step 2: Define ExplorationGroup and ExplorationVariant structs

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add these structs inside the `FLASHIda` class as private nested types (or as file-scope structs in the header, immediately before the class declaration). Keep them in the same translation unit — they are not part of the bridge API and do not need to appear in `FLASHIdaBridgeFunctions.h`.

```cpp
struct ExplorationVariant
{
    int variant_index = -1;       // 0-based position in the CE sweep
    double collision_energy = 0.0; // the CE value for this variant (double: matches IsolationStage.collision_energy, Phase 3 deviation)
    std::string activation_type;  // "HCD", "CID", etc. (note: IsolationStage.activation_type is char[32], Phase 3 deviation)
    std::string tracking_id;      // 4-char base-36 tracking ID of the submitted scan command
    double score = -1.0;          // -1 = not yet received; scoring metric depends on group.exploration_metric
    float tic_coverage = 0.0f;
    int fragment_count = 0;
    bool received = false;        // true once ProcessScan has matched and scored this variant
    DeconvolvedSpectrum result;   // deconvolution result for this variant; stored so the winner's
                                  // spectrum is available after selection (e.g., for MS3 fragment
                                  // selection, output, metadata). Initialized empty.
};

struct ExplorationGroup
{
    int group_id = 0;             // unique, monotonically increasing
    int msn_level = 2;            // the MSn level being explored (2 for MS2, 3 for MS3)
    ExplorationMetric exploration_metric = ExplorationMetric::MassCount;  // determines scoring metric
    std::string parent_tracking_id; // tracking ID of the scan that triggered this group
    double precursor_mz = 0.0;
    double precursor_mass = 0.0;
    int precursor_charge = 0;
    double isolation_width = 0.0;
    double faims_cv = 0.0;
    uint64_t start_ms = 0;        // wall-clock ms when group was created
    std::vector<ExplorationVariant> variants;
    int winner_index = -1;        // index into variants; -1 = winner not yet selected
    bool complete = false;        // true once winner is selected
};
```

Note: the `depth` field has been removed. Exploration depth is no longer tracked — per-level selection and exploration fields control which levels explore. The `exploration_metric` field is added so that `feedExplorationResult_()` knows which scoring metric to apply when variants return.

Add the following private members to `FLASHIda`:

```cpp
std::unordered_map<int, ExplorationGroup> active_exploration_groups_;
int next_exploration_group_id_ = 1;   // atomic increment; protected by queue_mutex_

// Maps tracking_id (int) -> {group_id, variant_index} so ProcessScan can look up
// the group when a variant result returns. Uses the same integer tracking ID
// that pending_scan_map_ uses — extracted from the scan_description "{id}|EXPL CE=... mass@charge" format
// via the standard decodeBase36_() path.
struct VariantRef { int group_id; int variant_index; };
std::unordered_map<int, VariantRef> variant_tracking_to_group_;
```

Both maps are accessed only inside `queue_mutex_`-protected regions (either within `processScan()` or `getNextScanCommand()`), so no additional locking is needed beyond the existing mutex.

---

### Step 3: Implement the CE variant generation helper

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Add a private helper `buildCEVariants_()` that generates the list of collision energy values for a CE sweep. **Uses `double` throughout** because `IsolationStage.collision_energy` is `double` (Phase 3 deviation), enabling fractional CE steps (e.g., step=2.5):

```cpp
std::vector<double> FLASHIda::buildCEVariants_(double ce_min, double ce_max, double ce_step) const
{
    std::vector<double> ces;
    for (double ce = ce_min; ce <= ce_max + 1e-9; ce += ce_step)  // epsilon guard for floating-point
        ces.push_back(ce);
    return ces;
}
```

For CE 20.0-40.0 step 5.0 this produces {20.0, 25.0, 30.0, 35.0, 40.0} — exactly 5 variants. Fractional steps (e.g., CE 20.0-30.0 step 2.5) produce {20.0, 22.5, 25.0, 27.5, 30.0}.

---

### Step 4: Implement exploration initiation from high-scoring precursors

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

This logic belongs in `processScan()` inside the MS1 branch. The MS1 branch itself must be updated to use the per-level config framework: the existing top-N precursor ranking is replaced by `getLevelConfig_(1).selection` (`Intensity` ranks by raw intensity; `QScore` ranks by deconvolution quality score), and the hardcoded top-N count is replaced by `getLevelConfig_(1).max_targets`. The existing mode-dependent filters (deep mode, inclusion/exclusion list, tag targeting, mass exclusion, thresholds) remain orthogonal — they run before the ranking step and are unaffected by the selection metric.

After the MS1 ranking/selection loop pushes standard MS2 commands, the exploration path is taken only when MS2 has exploration enabled (`hasExploration(getLevelConfig_(2))`).

Pseudocode (to be implemented as a private helper `initiateExploration_()`):

```cpp
// Generic exploration initiation for any MSn level.
// msn_level: the level being explored (2 for MS2 CE sweep, 3 for MS3 CE sweep, etc.)
// precursor_mz, precursor_mass, precursor_charge: the target being explored
// faims_cv: CV from the parent scan
void FLASHIda::initiateExploration_(
    int msn_level, double precursor_mz, double precursor_mass,
    int precursor_charge, double faims_cv)
{
    const auto& cfg = getLevelConfig_(msn_level);

    // (1) Guard: only initiate if this level has exploration enabled
    if (!hasExploration(cfg)) return;

    // (2) Build CE variants (double: fractional CE support, Phase 3 deviation)
    std::vector<double> ces = buildCEVariants_(cfg.ce_min, cfg.ce_max, cfg.ce_step);
    if (ces.empty()) return;

    // (3) Create ExplorationGroup
    ExplorationGroup group;
    group.group_id = next_exploration_group_id_++;
    group.msn_level = msn_level;
    group.exploration_metric = cfg.exploration;  // scoring metric for this group
    group.precursor_mz = precursor_mz;
    group.precursor_mass = precursor_mass;
    group.precursor_charge = precursor_charge;
    group.isolation_width = getIsolationWidth_(precursor_charge);
    group.faims_cv = faims_cv;
    group.start_ms = currentTimeMs_();

    // (4) For each CE value: build ScanCommand at priority 0, assign tracking ID
    for (int i = 0; i < (int)ces.size(); i++) {
        ExplorationVariant v;
        v.variant_index = i;
        v.collision_energy = ces[i];
        v.activation_type = cfg.activation;

        // Build command using the appropriate MSn command builder
        ScanCommand cmd = buildMSnCommand_(msn_level, precursor_mz,
            precursor_charge, ces[i], cfg.activation);
        cmd.priority = 0;
        cmd.faims_cv = faims_cv;
        // Apply exploration overrides (e.g., lower AGC, shorter injection time)
        applyOverrides_(cmd, cfg.overrides);

        // Use the standard scan description format: "{base36_id}|EXPL CE={ce} {mass}@{charge}"
        // Matching works via tracking ID lookup in variant_tracking_to_group_,
        // not by parsing the payload. The payload is for human readability
        // and log inspection only.
        int id_int = nextTrackingIdInt_();
        std::string id_str = encodeBase36_(id_int);
        v.tracking_id = id_str;
        cmd.scan_id = id_int;
        snprintf(cmd.scan_description, sizeof(cmd.scan_description),
                 "%s|EXPL CE=%.1f %.2f@%d", id_str.c_str(),
                 ces[i], group.precursor_mass, group.precursor_charge);

        group.variants.push_back(v);
        variant_tracking_to_group_[id_int] = {group.group_id, i};
        queues_[0].push_back(cmd);
        logTrackCreate_(cmd);  // CI TRACK-CREATE hard-fail: must emit for every exploration command
    }

    active_exploration_groups_[group.group_id] = std::move(group);
}
```

The call to `initiateExploration_()` is added at the end of the top-N loop in the MS1 branch, after `pushCommand_()` for the standard MS2 has already been called:

```cpp
if (hasExploration(getLevelConfig_(2)))
    initiateExploration_(2, selected_peak_group.getRepresentativeMz(),
        selected_peak_group.getMonoisotopicMass(), charge, faims_cv);
```

Note that standard MS2 commands for the precursor still go into the queue at priority 1 (normal processing). Exploration variants go in at priority 0. They will be dequeued after all higher-priority scans are exhausted, meaning the instrument will handle urgent MS3 follow-ups, conditional scans, and standard MS2 scans before exploration sweeps.

---

### Step 5: Implement variant tracking in ProcessScan MS2 routing

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

The `processScan()` MS2 path currently resolves tracking IDs from `pending_scan_map_` using the standard `{base36_id}|{payload}` scan description format. Exploration variants use the same format with payload `EXPL CE={ce} {mass}@{charge}` (e.g., `wxyz|EXPL CE=25.0 2063.61@3`). Detection does not rely on parsing the payload — instead, after extracting the tracking ID via the standard `decodeBase36_()` path, check `variant_tracking_to_group_` to determine whether this is an exploration variant:

```cpp
// In processScan(), MS2 path, after deconvolution:
// Standard tracking ID extraction (already exists):
Size pipe_pos = desc_str.find('|');
std::string id_str = desc_str.substr(0, pipe_pos);
int tracking_id = decodeBase36_(id_str);

// Check if this is an exploration variant (before checking pending_scan_map_)
auto vit = variant_tracking_to_group_.find(tracking_id);
if (vit != variant_tracking_to_group_.end())
{
    int group_id = vit->second.group_id;
    int variant_index = vit->second.variant_index;
    variant_tracking_to_group_.erase(vit);
    feedExplorationResult_(group_id, variant_index, ms2_deconv, rt);
    return commands_pushed_;
}

// ... existing routing for non-exploration MS2 (pending_scan_map_ lookup)
```

This integrates cleanly with the existing tracking system — no special-case scan description parsing, no prefix detection. The only difference is which map the tracking ID is found in.

---

### Step 6: Implement winner selection and OptimizationMetadata population

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

`feedExplorationResult_()` is the core scoring function. It:
1. Scores the returning variant using the exploration-metric-specific scorer stored in `group.exploration_metric`.
2. Marks the variant as received.
3. Checks whether all variants for the group have been received.
4. If complete: selects the winner, populates `OptimizationMetadata` on the winning `DeconvolvedSpectrum`, and triggers MS3 follow-up (exploration or simple targeting, depending on MS3 config).
5. Removes the group from `active_exploration_groups_` and cleans up `variant_tracking_to_group_`.

```cpp
void FLASHIda::feedExplorationResult_(
    int group_id, int variant_index,
    const DeconvolvedSpectrum& ms2_deconv, double rt)
{
    auto git = active_exploration_groups_.find(group_id);
    if (git == active_exploration_groups_.end()) return;
    ExplorationGroup& group = git->second;

    if (variant_index < 0 || variant_index >= (int)group.variants.size()) return;
    ExplorationVariant& v = group.variants[variant_index];
    if (v.received) return;  // Duplicate; ignore

    // Store the deconvolution result and score this variant
    v.result = ms2_deconv;  // copy — needed so winner's spectrum is available after selection
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv);
    v.tic_coverage = computeTICCoverage_(ms2_deconv);
    v.fragment_count = (int)ms2_deconv.size();
    v.received = true;

    // Populate OptimizationMetadata on the stored spectrum
    auto& meta = v.result.getOrCreateOptimizationMetadata();
    meta.group_id = group.group_id;
    meta.variant_index = variant_index;
    meta.total_variants = (int)group.variants.size();
    meta.is_best_variant = false;   // updated below once winner is known
    meta.msn_level_optimized = group.msn_level;
    meta.exploration_metric = static_cast<int>(group.exploration_metric);  // record which exploration metric was used
    meta.parent_tracking_id = std::stoi(group.parent_tracking_id, nullptr, 36);
    meta.collision_energy = v.collision_energy;
    meta.activation_type = v.activation_type;
    meta.precursor_mass = group.precursor_mass;
    meta.precursor_charge = group.precursor_charge;
    meta.fragmentation_quality_score = v.score;
    meta.tic_coverage = v.tic_coverage;
    meta.fragment_count = v.fragment_count;
    meta.start_ms = group.start_ms;
    meta.complete_ms = currentTimeMs_();
    meta.exploration_scans = (int)group.variants.size();

    // Check completion
    bool all_received = std::all_of(group.variants.begin(), group.variants.end(),
                                    [](const ExplorationVariant& x){ return x.received; });
    if (!all_received) return;

    // Select winner: highest score (all exploration metric scores are oriented so higher = better)
    int best_idx = 0;
    double best_score = group.variants[0].score;
    for (int i = 1; i < (int)group.variants.size(); i++) {
        if (group.variants[i].score > best_score) {
            best_score = group.variants[i].score;
            best_idx = i;
        }
    }
    group.winner_index = best_idx;
    group.complete = true;

    logInfo_("EXPL-WINNER group=" + std::to_string(group_id)
             + " winner_idx=" + std::to_string(best_idx)
             + " CE=" + std::to_string(group.variants[best_idx].collision_energy)
             + " score=" + std::to_string(best_score));

    // --- Production scan or direct use of winner ---
    // If exploration used parameter overrides, the winner was acquired with
    // non-standard parameters (e.g., lower AGC). Push a production scan with
    // the winning CE and original parameters. It goes through the normal
    // processScan() path, triggering all downstream processing.
    //
    // If no overrides were configured, the winner was already acquired with
    // full-quality parameters — no production scan needed. Route the winner's
    // stored spectrum directly into the standard MS2 processing path.
    const auto& level_config = getLevelConfig_(group.msn_level);
    if (!level_config.overrides.empty())
    {
        // Overrides were active: push production scan with original parameters
        double winning_ce = group.variants[best_idx].collision_energy;
        ScanCommand prod_cmd = buildMS2Command_(
            group.precursor_mz, group.precursor_charge, winning_ce,
            group.variants[best_idx].activation_type);
        // Do NOT apply overrides — production scan uses original parameters.
        prod_cmd.faims_cv = group.faims_cv;
        prod_cmd.priority = 1;  // normal priority, not exploration priority 0
        queues_[1].push_back(prod_cmd);
        logTrackCreate_(prod_cmd);
    }
    else
    {
        // No overrides: winner's result is already production quality.
        // Trigger MSn+1 follow-up directly from the winner's stored spectrum.
        initiateNextLevel_(group.msn_level,
            group.variants[best_idx].result, group.faims_cv);
    }

    // Clean up variant tracking map (entries already erased on lookup in Step 5,
    // but erase any remaining for variants that were never received)
    for (auto& v2 : group.variants)
        variant_tracking_to_group_.erase(decodeBase36_(v2.tracking_id));

    active_exploration_groups_.erase(git);
}
```

**Exploration-metric-specific scoring.** Add a private dispatcher `computeExplorationScore_()` and per-metric scoring helpers:

```cpp
double FLASHIda::computeExplorationScore_(
    ExplorationMetric metric,
    const DeconvolvedSpectrum& spec) const
{
    switch (metric) {
        case ExplorationMetric::MassCount:
            return computeMassCount_(spec);
        case ExplorationMetric::RemainingPrecursor:
            return computeRemainingPrecursorScore_(spec);
        case ExplorationMetric::FragmentCount:
            return computeFragmentCount_(spec);
        default:
            return computeMassCount_(spec);  // fallback
    }
}

double FLASHIda::computeMassCount_(const DeconvolvedSpectrum& spec) const
{
    // Score = number of deconvolved masses (peak groups)
    return static_cast<double>(spec.size());
}

double FLASHIda::computeRemainingPrecursorScore_(const DeconvolvedSpectrum& spec) const
{
    // Score = negative of remaining precursor intensity (lower remaining = higher score)
    // The remaining precursor intensity is estimated from the unfragmented precursor peak
    // in the deconvolved spectrum. For now, use a simple heuristic: TIC minus fragment TIC.
    if (spec.empty()) return 0.0;
    double tic = 0.0;
    for (const auto& peak : spec)
        tic += peak.getIntensity();
    // Higher fragmentation = lower remaining precursor = better score
    // Return negative remaining (i.e., higher score = better fragmentation efficiency)
    return tic;  // Placeholder: in practice, compare against precursor intensity
}

double FLASHIda::computeFragmentCount_(const DeconvolvedSpectrum& spec) const
{
    // Score = number of fragment ions
    return static_cast<double>(spec.size());
}
```

The `computeTICCoverage_()` helper is retained unchanged — it is still useful for metadata population regardless of exploration metric.

**Override application helper.** Add `applyOverrides_()` that applies exploration parameter overrides to a `ScanCommand`:

```cpp
void FLASHIda::applyOverrides_(ScanCommand& cmd,
    const std::unordered_map<std::string, std::string>& overrides) const
{
    for (const auto& [key, val] : overrides) {
        // Map field names to ScanCommand fields. Example fields:
        // "agc_target", "max_injection_time_ms", "isolation_width", etc.
        // Parse val as the appropriate type and assign to cmd.
        // Unknown field names are silently ignored (forward compatibility).
        if (key == "agc_target") cmd.agc_target = std::stod(val);
        else if (key == "max_injection_time_ms") cmd.max_injection_time_ms = std::stoi(val);
        // ... additional fields as needed
    }
}
```

The full set of overridable fields matches the `ScanCommand` struct fields. This is intentionally open-ended — any field can be overridden by name. The production scan (pushed after winner selection) does NOT call `applyOverrides_()`, so it uses the original parameters with only the winning CE changed.

Note: the old `triggerSimpleMS3Targeting_()` helper is superseded by the generic `initiateNextLevel_()` (Step 8), which handles both exploration and simple targeting for any MSn+1 level.

---

### Step 7: Implement MS1 cycle time suppression during active exploration

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

In `getNextScanCommand()`, step (2) already handles MS1 cycle time injection:

```cpp
// (2) MS1 cycle time
if (cycle_time_enabled_ && msSinceLastMS1_() > cycle_time_ms_)
    { out = makeMS1Command_(); return 1; }
```

Add a suppression guard immediately before this check:

```cpp
// (2) MS1 cycle time — suppressed while any exploration group is active
bool exploration_active = !active_exploration_groups_.empty();
if (cycle_time_enabled_ && !exploration_active
    && msSinceLastMS1_() > cycle_time_ms_)
    { out = makeMS1Command_(); return 1; }
```

This prevents the instrument from inserting an MS1 scan in the middle of a CE sweep. The sweep may take many scan events if the CE range produces many variants; suppressing cycle time ensures continuity. Once all groups complete (the map empties), the cycle time check resumes normally on the next `getNextScanCommand()` call.

---

### Step 8: Implement MSn+1 follow-up after MSn processing

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

After processing an MSn result, the engine checks whether MSn+1 is configured. The logic is generic — it applies to any level transition (MS1→MS2, MS2→MS3, etc.):

```cpp
// Generic MSn+1 follow-up after processing an MSn result.
// msn_level: the level just processed (e.g., 2 for MS2)
// result: the deconvolution result from the MSn scan
// faims_cv: CV from the parent scan chain
void FLASHIda::initiateNextLevel_(
    int msn_level, const DeconvolvedSpectrum& result, double faims_cv)
{
    int next_level = msn_level + 1;
    const auto& next_cfg = getLevelConfig_(next_level);
    if (next_cfg.selection == SelectionMetric::None) return;  // next level disabled

    // Select top targets from the MSn result for MSn+1
    std::vector<std::pair<double, double>> targets; // (mz, intensity)
    for (const auto& peak : result)
        targets.push_back({peak.getMZ(), peak.getIntensity()});
    // TODO: sort by next_cfg.selection metric (Intensity or QScore)
    std::sort(targets.begin(), targets.end(),
              [](auto& a, auto& b){ return a.second > b.second; });
    int num_targets = std::min((int)targets.size(), next_cfg.max_targets);

    if (hasExploration(next_cfg))
    {
        // MSn+1 has exploration: create exploration groups per target
        for (int ti = 0; ti < num_targets; ti++)
            initiateExploration_(next_level, targets[ti].first,
                0.0 /* mass unknown */, 0 /* charge unknown */, faims_cv);
    }
    else
    {
        // MSn+1 has selection but no exploration: push single-shot commands
        for (int ti = 0; ti < num_targets; ti++)
            pushCommand_(buildMSnCommand_(next_level, targets[ti].first,
                0, getLevelConfig_(next_level).ce_min, next_cfg.activation));
    }
}
```

This replaces the separate `initiateExploration_()` and `initiateNextLevel_()` functions. Both are now handled by the generic `initiateNextLevel_()`. The old `ms3_enabled_` flag maps to `getLevelConfig_(3).selection = Intensity` with `exploration = None`, which takes the single-shot path above.

#### Chaining rule and production scan flow

The chaining rule determines when MSn+1 triggers relative to MSn. It is generic — the same logic applies to MS1→MS2, MS2→MS3, etc.:

- **MSn has exploration enabled**: `feedExplorationResult_()` selects the winner and then:
  - **If overrides are configured**: pushes a **production scan** — a normal MSn command with the winning CE and original (non-overridden) parameters. When the production scan's result returns via `processScan()`, it enters the standard MSn path and calls `initiateNextLevel_(msn_level, result, faims_cv)` for MSn+1 follow-up.
  - **If no overrides**: the winner was already acquired with full-quality parameters. The winner's stored `DeconvolvedSpectrum` is passed directly to `initiateNextLevel_()` inline without re-scanning.

- **MSn has no exploration**: MSn+1 triggers immediately from each MSn result (no waiting). The standard processing path calls `initiateNextLevel_(msn_level, result, faims_cv)`.

In both cases, the standard MSn path in `processScan()` handles MSn+1 follow-up via a single call:

  ```cpp
  // After standard MSn processing (non-exploration result — includes production scans)
  initiateNextLevel_(msn_level, deconv_result, faims_cv);
  ```

This replaces the old `if (ms3_enabled_) { selectMS3Targets_(...) }` check. The backwards-compatible config maps `ms3_enabled_=true` to `getLevelConfig_(3).selection = SelectionMetric::Intensity` with `getLevelConfig_(3).exploration = ExplorationMetric::None`, which takes the single-shot path in `initiateNextLevel_()`.

Note: `feedExplorationResult_()` does not trigger MSn+1 directly. After winner selection, it either pushes a production scan (if overrides were active) or routes the winner's stored spectrum through `initiateNextLevel_()` (if no overrides). In both cases, downstream processing flows through the standard pipeline.

---

### Step 9: Update processScan MS2 routing for exploration variants

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Extend the MS3 path to handle the case where an exploration-generated MS3 scan returns. MS3 exploration variants also use the `{id}|EXPL CE=... mass@charge` scan description format and are registered in `variant_tracking_to_group_`, so the tracking ID lookup added in Step 5 already handles them. The `feedExplorationResult_()` function is generic across MSn levels — it uses `group.msn_level` to determine context.

The standard MS2 processing path (non-exploration) now uses the chaining rule from Step 8 to determine MS3 behavior based on `getLevelConfig_(3).selection` and `getLevelConfig_(3).exploration`. When `is_exploration_variant` is false (standard MS2 result), the MS3 follow-up is determined by the config: `hasExploration(getLevelConfig_(3))` triggers `initiateExploration_()`, selection without exploration triggers `initiateNextLevel_()`, `selection = None` does nothing. This replaces the old `if (ms3_enabled_)` check.

---

### Step 10: Create method_exploration.xml and update Parameter.ToJSON()

**File:** `FlashIDA/test-data/configs/method_exploration.xml`

All method config files follow the XML schema described in [../test-file-specification.md](../test-file-specification.md) §3.1. `method_exploration.xml` is listed in the config inventory in [../test-file-specification.md](../test-file-specification.md) §3.2, where its key parameters are summarized. The full XML content is specified here.

Create this config as a variant of `method_default.xml` with `<SelectionStrategy>` enabled. The new XML block replaces the old `<ParameterOptimization>` structure. Selection and exploration are independent concerns at each level:

```xml
<SelectionStrategy>
  <MS1>
    <Selection>qscore</Selection>
    <MaxPrecursors>10</MaxPrecursors>
  </MS1>
  <MS2>
    <Selection>intensity</Selection>
    <MaxFragments>3</MaxFragments>
    <Exploration>
      <Metric>mass_count</Metric>
      <CEMin>20</CEMin>
      <CEMax>40</CEMax>
      <CEStep>5</CEStep>
      <Activation>HCD</Activation>
      <Overrides>
        <!-- Optional: scan parameters that differ during exploration sweeps.
             Any ScanCommand field can be overridden. After the winner is selected,
             a production scan is pushed with the winning CE but original parameters. -->
        <!-- <AGCTarget>1e4</AGCTarget> -->
        <!-- <MaxInjectionTimeMs>10</MaxInjectionTimeMs> -->
      </Overrides>
    </Exploration>
  </MS2>
  <MS3>
    <Selection>intensity</Selection>
    <!-- No Exploration tag = no CE sweep at MS3 -->
  </MS3>
</SelectionStrategy>
```

For the MS3-exploration config (`method_exploration_ms3.xml`), both MS2 and MS3 levels have exploration enabled with independent metrics:

```xml
<SelectionStrategy>
  <MS1>
    <Selection>qscore</Selection>
    <MaxPrecursors>10</MaxPrecursors>
  </MS1>
  <MS2>
    <Selection>intensity</Selection>
    <MaxFragments>3</MaxFragments>
    <Exploration>
      <Metric>mass_count</Metric>
      <CEMin>20</CEMin>
      <CEMax>40</CEMax>
      <CEStep>5</CEStep>
      <Activation>HCD</Activation>
    </Exploration>
  </MS2>
  <MS3>
    <Selection>intensity</Selection>
    <Exploration>
      <Metric>fragment_count</Metric>
      <CEMin>15</CEMin>
      <CEMax>35</CEMax>
      <CEStep>5</CEStep>
      <Activation>CID</Activation>
    </Exploration>
    <MaxFragments>3</MaxFragments>
  </MS3>
</SelectionStrategy>
```

The old `<ParameterOptimization>` config was never released — only the new `<SelectionStrategy>` format is supported.

**File:** `FlashIDA/src/Flash/IDA/Parameter.cs`

Ensure `ToJSON()` serializes the `<SelectionStrategy>` block into the `selection_strategy` JSON object, including the `ms1` sub-object for precursor ranking selection and max_precursors. The JSON key names must exactly match what the C++ parser expects (established in Step 1). The C# serialization should produce:

```json
"selection_strategy": {
  "ms1": {
    "selection": "qscore",
    "max_precursors": 10
  },
  "ms2": {
    "selection": "intensity",
    "max_fragments": 3,
    "exploration": {
      "metric": "mass_count",
      "ce_min": 20.0,
      "ce_max": 40.0,
      "ce_step": 5.0,
      "activation": "HCD",
      "overrides": {}
    }
  },
  "ms3": {
    "selection": "intensity"
  },
}
```

The old `<ParameterOptimization>` config was never released — no backwards compatibility needed. Only the new `<SelectionStrategy>` format is supported.

---

### Step 11: Capture the Phase 7 golden file

The golden file for exploration-enabled output is named **`phase7_exploration.tsv`** (canonical name per [../test-file-specification.md](../test-file-specification.md) Section 2.2). It lives in `FlashIDA/test-data/golden/` alongside all other golden files. Its format is the standard 15-column TSV defined in [../test-file-specification.md](../test-file-specification.md) Section 2.1, extended with `OptimizationMetadata` metavalue columns for exploration variant rows (see WPV-6 for the additional column names). Note: spectrum input files use tab-separated headers with RT in seconds (Phase 0 lesson #2); the golden file is also tab-separated.

Because there is no Windows machine available for local development, `phase7_exploration.tsv` is captured via a CI-artifact workflow rather than a local `Flash.exe` invocation. Golden-file capture requires a 2-commit minimum (Phase 0 lesson #15): the first commit runs CI and produces the golden artifact; the second commit includes the captured golden file.

1. Batch same-side changes before updating the submodule pointer (Phase 0 lesson #15). Commit the Phase 7 code changes (C++, C#, `method_exploration.xml`) **without** `test-data/golden/phase7_exploration.tsv`.
2. Push the branch. The `windows-tests` CI job runs `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` and uploads the produced TSV as a build artifact named `exploration-golden-candidate`.
3. Download the artifact from the GitHub Actions run page, inspect it: confirm that extra rows corresponding to exploration variant scans are present and that `OptimizationMetadata` fields appear as additional TSV columns (or mzML metavalues, depending on how test mode serializes them). Follow the general golden file inspection checklist in [../test-file-specification.md](../test-file-specification.md) Section 2.3 (steps 3–5).
4. Once the output looks correct, commit the file as `FlashIDA/test-data/golden/phase7_exploration.tsv` and update `FlashIDA/test-data/golden/README.md` to document its provenance.

The `windows-tests` job must be updated to upload the candidate artifact when the golden file is absent (or always, keyed by run ID). Add a step in `.github/workflows/flashida-ci.yml` such as:

```yaml
- name: Upload exploration golden candidate
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: exploration-golden-candidate
    path: FlashIDA/test-data/golden/phase7_exploration.tsv
```

The regression golden file for `P7-R01` (exploration disabled) is the existing `phase4_standard_dda.tsv` — no new capture needed. (Note: this file is named `phase4_standard_dda.tsv` in the spec, not `standard_dda.tsv`. It uses `ms1_standard.txt` as input, not `ms1_smoke_test.txt`. See [../test-file-specification.md](../test-file-specification.md) Section 2.2 for the distinction between `baseline_phase0.tsv` and `phase4_standard_dda.tsv`.)

---

### Step 12: Transition existing pipeline to unified selection/exploration framework

**Files:**
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`
- `FlashIDA/src/Flash/IDA/Parameter.cs`

After Steps 1-11 implement the new exploration engine alongside the existing pipeline, this step transitions all existing scan selection and targeting logic to use the `level_configs_` / `getLevelConfig_()` / `initiateNextLevel_()` framework. The goal is a single unified pipeline — no "old path for standard DDA" and "new path for exploration."

#### 12a: MS1 precursor selection

**Current state (Phase 4-6):** `processScan()` MS1 branch uses hardcoded top-N logic with a dedicated `top_n_` member variable and hardcoded quality-score ranking.

**Transition:**
- Replace `top_n_` with `getLevelConfig_(1).max_targets`
- Replace the hardcoded scoring/ranking with a switch on `getLevelConfig_(1).selection`:
  - `Intensity`: sort candidate peak groups by `getIntensity()`
  - `QScore`: sort by the existing quality score (current default behavior)
- The mode-dependent filters (deep mode, inclusion/exclusion list, tag targeting, mass exclusion, thresholds) remain unchanged — they run before the ranking step
- Remove the old `top_n_` member variable after migration

#### 12b: MS2→MS3 targeting

**Current state (Phase 4-6):** `processScan()` MS2 path has a hardcoded `if (ms3_enabled_)` check that calls `selectMS3Targets_()` → `buildMS3Command_()`.

**Transition:**
- Replace `if (ms3_enabled_)` with `initiateNextLevel_(2, ms2_deconv, faims_cv)`, which internally checks `getLevelConfig_(3).selection != None`
- `initiateNextLevel_()` handles both exploration (CE sweep) and simple targeting (single-shot) paths based on `getLevelConfig_(3)`
- Remove the old `ms3_enabled_` member variable after migration
- The existing `selectMS3Targets_()` function is still called internally by `initiateNextLevel_()` for the simple-targeting path — it does not need to be rewritten, just called from the new framework

#### 12c: JSON config — strict, no backwards compatibility

**Current state:** `Parameter.ToJSON()` serializes MS3 config as a flat `ms3_enabled` boolean and top-N as a standalone field.

**Transition:**
- `Parameter.ToJSON()` emits ONLY the `selection_strategy` JSON object. It requires `<SelectionStrategy>` in the method XML.
- If `<SelectionStrategy>` is absent from the method XML, `Parameter.ToJSON()` must throw / crash. This is intentional — all method configs must be updated to use the new format. Invalid or incomplete configs should fail loudly so tests catch them immediately.
- The C++ parser only reads `selection_strategy` — if the key is missing from JSON, the engine crashes with a clear error message (not silent defaults).
- Remove parsing of old `ms3_enabled`, `exploration.enabled`, `exploration.max_depth` fields from C++.
- **All existing method XML files** in `FlashIDA/test-data/configs/` must be updated to include `<SelectionStrategy>` blocks as part of this step. This includes `method_default.xml` and all mode-specific configs.

#### 12d: Existing test migration

All existing tests that exercise MS1 precursor selection or MS3 targeting must continue to pass after the transition. The behavioral contract is unchanged — only the internal code path differs. Specific tests to verify:

**C++ tests (verify via `cpp-unit-tests` CI job):**
- `FLASHIda_ProcessScan_test` — all MS1→MS2 precursor selection tests must produce the same commands. If any test configures top-N directly via a member variable, update it to use `level_configs_[1].max_targets`.
- `FLASHIdaFAIMS_test` — FAIMS CV cycling is orthogonal to selection/exploration; no changes expected, but must pass.
- `FLASHIdaQueueTracking_test` — queue behavior unchanged; must pass.

**C# tests (verify via `windows-tests` CI job):**
- All continuity tests (CT01-CT32) — these exercise the full pipeline end-to-end via mock data. The unified pipeline must produce identical scan commands. Any test that asserts on MS3 command generation is directly affected by the `ms3_enabled_` → `getLevelConfig_(3).selection` transition.
- Bridge smoke tests — must pass unchanged.

**Regression tests:**
- P7-R01 (exploration disabled, `method_default.xml`) — the output must be identical to `phase4_standard_dda.tsv`. This is the primary regression gate for the transition: if the unified pipeline changes output for a non-exploration config, the transition has a bug.
- All Phase 4 regression configs — must produce identical golden file output.

**Test config files:**
- All existing method XML files (`method_default.xml`, `method_*.xml`) must be updated to include `<SelectionStrategy>` blocks (Step 12c). Without this, `Parameter.ToJSON()` will crash — this is intentional to ensure no config is silently using legacy paths.

---

### Step 13: Validation — deploy agents to verify complete transition

After Step 12 is implemented and all tests pass, deploy validation agents to verify that no legacy code paths remain:

#### Agent 1: C++ dead code scan
Search `FLASHIda.h` and `FLASHIda.cpp` for:
- `ms3_enabled_` — should not exist as a member variable (removed in 12b)
- `top_n_` — should not exist as a standalone member variable (replaced by `level_configs_[1].max_targets` in 12a)
- `exploration_enabled_` as the old Phase 1 boolean (distinct from the Phase 7 convenience bool, which is computed from `level_configs_`)
- `exploration_max_depth_`, `exploration_max_variants_` — old Phase 1 fields, should be removed
- Any `if (ms3_enabled_)` code path — should be replaced by `initiateNextLevel_()` or `getLevelConfig_(3).selection != None`
- Direct references to `ms2_configs_` or `ms3_configs_` vectors (the old Phase 1 parsed config arrays) — should be replaced by `level_configs_`

#### Agent 2: C# dead code scan
Search `Parameter.cs`, `FLASHIdaWrapper.cs`, and all test files for:
- `ms3_enabled` or `MS3Enabled` — should be replaced by `selection_strategy.ms3.selection`
- `exploration.enabled`, `exploration.max_depth`, `exploration.max_variants` in JSON serialization — should be replaced by `selection_strategy` object
- `TopN` or `top_n` as a standalone config field — should be replaced by `selection_strategy.ms1.max_precursors`

#### Agent 3: Config completeness
Search all method XML files in `FlashIDA/test-data/configs/` and verify:
- `Parameter.ToJSON()` correctly emits `selection_strategy` for every existing config (including those without `<SelectionStrategy>` XML blocks)
- The emitted JSON round-trips correctly: parse → `getLevelConfig_()` returns the expected defaults for each level

#### Agent 4: Test coverage verification
For each existing test that was identified in 12d, verify:
- The test still exercises the intended code path through the unified pipeline
- No test bypasses the unified pipeline by setting old member variables directly (e.g., `ms3_enabled_ = true` instead of `level_configs_[3].selection = Intensity`)
- All test helpers that set up FLASHIda state use `level_configs_[]` instead of legacy variables

Each agent reports findings. Any remaining legacy references are either removed (dead code) or migrated (live code using old variables).

---

## Files to Create or Modify

### OpenMS (C++) — Build #4

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Add `SelectionMetric` enum, `ExplorationMetric` enum, `MSLevelConfig` struct (with `selection` + optional `exploration` fields, `max_targets` replacing old top-N and max_fragments), `hasExploration()` helper, `ExplorationGroup` (with `exploration_metric` field, no `depth` field), `ExplorationVariant` nested structs (note: `collision_energy` fields are `double`, matching `IsolationStage` Phase 3 deviation); add `level_configs_` map (indexed by MSn level), `getLevelConfig_()` accessor, `exploration_enabled_` convenience bool; add `active_exploration_groups_`, `variant_tracking_to_group_`, `next_exploration_group_id_`; declare new private methods. **Do not modify `ScanCommand`** — `enqueue_timestamp_ms` (Phase 4) and `faims_cv` (Phase 6) are already present. |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Implement `buildCEVariants_()` (returns `vector<double>`), `initiateExploration_()`, `feedExplorationResult_()`, `initiateNextLevel_()`, `buildMSnCommand_()`, `computeExplorationScore_()`, `computeMassCount_()`, `computeRemainingPrecursorScore_()`, `computeFragmentCount_()`, `computeTICCoverage_()`, `parseSelectionMetric_()`, `parseExplorationMetric_()`, `applyOverrides_()`; extend JSON config parsing for `selection_strategy` (MS1 + MS2 + MS3 with nested `exploration` blocks) with `parseLevelConfig_()` helper; refactor `processScan()` MS1 branch to use `getLevelConfig_(1).selection` for precursor ranking and `getLevelConfig_(1).max_targets` for top-N; modify `processScan()` MS2 path for chaining rule; modify `getNextScanCommand()` MS1 suppression. All `logTrackCreate_()` calls required for CI hard-fail gate. |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | Create | C++ unit tests P7-U01 through P7-U11 (see Test Cases section). **Must follow test quality rules** from Phase 6 Addendum: no soft guards, separate input/output arrays, trace loop assertions by hand. |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Add entry for `FLASHIda_exploration_test` so CTest discovers it |
| `.github/workflows/flashida-ci.yml` (cross-listed) | Modify | **Same commit as test file creation:** Add `FLASHIda_exploration_test` to BOTH `cmake --build --target` (line 58) AND `ctest -R` regex (line 63). Phase 6 lesson 10: unregistered CI tests never run. |

### FlashIDA (C#) — no new C++ bridge API changes

**Note:** Although Phase 7 adds no new bridge functions, the existing P/Invoke bridge has a silent zero-result failure mode (Phase 0 lesson #14). The C++ engine returns 0 results without an error code when input data is malformed. If exploration variants return 0 deconvolved fragments unexpectedly, log the input data characteristics (RT, peak count, first/last m/z) before investigating engine internals. P/Invoke DLL imports use `"OpenMS.dll"` (with `.dll` extension, lesson #12). NUnit tests must run from `FlashIDA/bin/` working directory so native DLLs are found (lesson #12).

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Extend `ToJSON()` to serialize the `<SelectionStrategy>` XML subtree into the `selection_strategy` JSON object with all sub-keys matching the C++ parser (MS1 selection + max_precursors, MS2 selection + max_fragments + optional exploration block with metric + CE params, MS3 selection + max_fragments + optional exploration block). The old `<ParameterOptimization>` config is not supported — only the new `<SelectionStrategy>` format. |

### Test data and configuration

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/test-data/configs/method_exploration.xml` | Create | Method config with `<SelectionStrategy>` containing MS2 exploration = `mass_count` and CE 20-40 step 5 |
| `FlashIDA/test-data/configs/method_exploration_ms3.xml` | Create | Method config with MS2 exploration = `mass_count` and MS3 exploration = `fragment_count` (`MaxFragments=3`); used by WPV-7 (per-level exploration activation) |
| `FlashIDA/test-data/golden/phase7_exploration.tsv` | Create | Golden file captured from `Flash.exe` with `method_exploration.xml` after Build #4 (canonical name per [test-file-specification.md](../test-file-specification.md) §2.2) |

### CI workflow

| File | Action | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | **(1)** Add `FLASHIda_exploration_test` to the `cmake --build --target` list (line 58) AND the `ctest -R` regex (line 63) — both required, see Phase 6 lesson 10. **(2)** Add `method_exploration.xml` and `phase7_exploration.tsv` to the regression runner's config list (entry name `p7_exploration`). **(3)** Add exploration golden candidate artifact upload step. |

---

## Test Cases

All 13 tests for Phase 7 are listed below with full descriptions, expected outcomes, and the CI job that runs them. Tests P7-U01 through P7-U12 are C++ unit tests (Tier 1); P7-R01 and P7-R02 are regression tests (Tier 3). Note: any C# tests that load `OpenMS.dll` via P/Invoke (AL-CT / bridge tests) are Tier 2, not Tier 1, per Phase 0 lesson #9 — the tier convention is that DLL-dependent tests are Tier 2.

> **Phase 2 lessons applicable to all C++ unit tests (P7-U01 through P7-U12):**
>
> - **`(void)var;` for MSVC `/WX` (lesson #8):** Use `(void)var;` after assertions on variables that are not otherwise referenced, to suppress C4189 warnings under MSVC `/WX`.
> - **PeakGroup prerequisite for `toSpectrum()` (lesson #3):** Any test calling `toSpectrum()` (specifically P7-U10) must push a default `PeakGroup` into the `DeconvolvedSpectrum` first. `toSpectrum()` unconditionally accesses `peak_groups_[0].isPositive()`.
> - **`toSpectrum()` returns `MSSpectrum` by value (lesson #1):** Use `MSSpectrum out = ds.toSpectrum(1);`, not an out-parameter.
> - **`DeconvolvedSpectrum` constructor takes `scan_number` (lesson #2):** Use `DeconvolvedSpectrum ds(1);` (scan number), not `ms_level`.
> - **CTest invocation (lesson #4):** Run with `ctest -R FLASHIda_exploration --output-on-failure`, not `ctest -R FLASH`.

### Test Summary (Quick Reference)

| Test ID | What it verifies and why |
|---------|--------------------------|
| P7-U01 | `initiateExploration_()` creates an `ExplorationGroup` with exactly the expected CE variants (20.0, 25.0, 30.0, 35.0, 40.0 — `double`, Phase 3 deviation) and correct initial state (`complete=false`, `winner_index=-1`). Validates the core group-construction path before any results arrive. |
| P7-U02 | All five exploration variant commands are enqueued at priority 0, leaving higher-priority queues untouched. Confirms the priority-0 reservation is honoured so exploration scans never preempt urgent follow-up scans. |
| P7-U03 | `feedExplorationResult_()` selects the variant with the highest exploration metric score as the winner. Exercises the end-to-end scoring and winner-selection logic with deterministic synthetic scores using `MassCount` exploration metric. |
| P7-U05 | MS1 cycle-time injection is suppressed while at least one exploration group is active. Ensures the instrument does not insert an MS1 scan in the middle of a CE sweep, which would break variant continuity. |
| P7-U06 | MS1 cycle-time injection resumes once all exploration groups have completed. Ensures normal MS1 survey pacing is restored after each sweep finishes. |
| P7-U07 | After an MS2 exploration winner is selected (MS2 exploration = `mass_count`), `initiateExploration_()` creates one child `ExplorationGroup` per top-N fragment ion when MS3 has exploration = `fragment_count`. Verifies the MS3 exploration branch is triggered correctly and child groups carry the right exploration metric and parent reference. |
| P7-U08 | When MS3 has selection (`intensity`) but no exploration, `feedExplorationResult_()` calls `initiateNextLevel_()` instead of `initiateExploration_()`. Verifies that standard MS3 commands (not exploration groups) are created after MS2 winner selection. |
| P7-U11 | When MS2 has no exploration and MS3 has exploration = `fragment_count`, MS3 exploration triggers immediately from each MS2 result (no waiting for MS2 winner, since there is no MS2 exploration). Validates the chaining rule for the no-exploration-MS2 + exploration-MS3 combination. |
| P7-U09 | `OptimizationMetadata` is populated on a variant's `DeconvolvedSpectrum` as soon as `feedExplorationResult_()` processes it — even before the group is complete. Validates all expected metadata fields (group_id, variant_index, collision_energy, activation_type, exploration_metric, scores, timestamps). |
| P7-U10 | `toSpectrum()` serializes `OptimizationMetadata` fields as named metavalues on the resulting `MSSpectrum` (return-value API, not out-param). Test must push a default `PeakGroup` before calling `toSpectrum()` (Phase 2 lesson #3). Ensures downstream consumers can read optimization results from the standard spectrum object. |
| P7-U12 | `getLevelConfig_(1).selection` controls precursor ranking: `Intensity` selects by raw intensity, `QScore` selects by deconvolution quality score. `max_targets` limits the number of precursors selected. Mode-dependent filters (deep, inclusion, exclusion, tag targeting) are orthogonal and unaffected by selection metric. |
| P7-R01 | With exploration disabled (`method_default.xml`), output is byte-for-byte identical to the Phase 4 standard DDA golden file. Guards against any regression introduced by the new exploration code paths when they are inactive. |
| P7-R02 | With exploration enabled (`method_exploration.xml`, CE 20-40 step 5), output matches the committed `phase7_exploration.tsv` golden file, including exploration variant rows, `EXPL-WINNER` log entries, and `OptimizationMetadata` metavalue columns. End-to-end validation of the full exploration pipeline. |

### P7-U01 — ExplorationGroup creation with CE variants

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure `level_configs_[2]` with `exploration = ExplorationMetric::MassCount`, CE min=20.0, max=40.0, step=5.0 (all `double`). Call `initiateExploration_()` for a synthetic high-scoring precursor. Inspect the resulting `ExplorationGroup` stored in `active_exploration_groups_`.
**Expected outcome:** Exactly 5 `ExplorationVariant` entries with `collision_energy` values {20.0, 25.0, 30.0, 35.0, 40.0} (double, not int — Phase 3 deviation). `group_id` is non-zero. `exploration_metric == ExplorationMetric::MassCount`. `complete == false`. `winner_index == -1`. `variants[i].received == false` for all i.

### P7-U02 — Exploration variants pushed at priority 0

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** After calling `initiateExploration_()`, inspect `queues_[0]`.
**Expected outcome:** `queues_[0].size() == 5`. All five commands have `priority == 0`. `queues_[1]`, `queues_[2]`, `queues_[3]` are unaffected by the exploration initiation.

### P7-U03 — Winner selection by exploration metric score

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Create an `ExplorationGroup` with 5 variants (CE 20.0-40.0, step 5.0) and `exploration_metric = ExplorationMetric::MassCount`. Call `feedExplorationResult_()` for each variant with synthetic `DeconvolvedSpectrum` objects whose `computeMassCount_()` returns known scores: {1.0, 3.0, 2.0, 5.0, 0.0} (corresponding to different numbers of deconvolved masses). Check the group after all 5 have been received.
**Expected outcome:** `group.complete == true`. `group.winner_index == 3` (score 5.0, CE=35.0). `logInfo_` output contains `EXPL-WINNER` with `winner_idx=3` and `CE=35.0` (note: `std::to_string(double)` output).

### P7-U05 — MS1 cycle time suppression during exploration

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Enable cycle time (`cycle_time_enabled_ = true`, `cycle_time_ms_ = 1000`). Create an active exploration group (do not call `feedExplorationResult_()` so the group remains incomplete). Advance the mock clock by 2000 ms (past the cycle time deadline). Call `getNextScanCommand()`.
**Expected outcome:** The returned command has `msn_level != 1` unless the queue is also empty. Specifically, the MS1 injection from the cycle time check is bypassed because `!active_exploration_groups_.empty()`. The command returned is one of the exploration variants from `queues_[0]`, not an injected MS1.

### P7-U06 — MS1 resumes after exploration completes

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Continuing from P7-U05 state (or fresh setup): complete all variants in the exploration group by calling `feedExplorationResult_()` for each. After the last call, `active_exploration_groups_` should be empty. Advance the clock past cycle time. Call `getNextScanCommand()`.
**Expected outcome:** The returned command has `msn_level == 1` and `is_agc == 0` — the MS1 cycle time injection resumes because there are no active exploration groups.

### P7-U07 — MS3 exploration creates exploration groups for MS2 winner's fragments

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure MS2 with `exploration = ExplorationMetric::MassCount` and MS3 with `exploration = ExplorationMetric::FragmentCount` (`getLevelConfig_(3).max_targets = 3`). Create an MS2 exploration group with 3 CE variants. Feed all 3 variants with known scores so one is selected as winner. The winning `DeconvolvedSpectrum` contains 5 fragment ions. Verify what happens in `feedExplorationResult_()` after MS2 winner selection.
**Expected outcome:** After the MS2 group completes, `active_exploration_groups_` contains 3 new child groups (one per fragment, up to `getLevelConfig_(3).max_targets`). Each child group has `msn_level == 3`, `exploration_metric == ExplorationMetric::FragmentCount`, and `parent_tracking_id` matching the MS2 group's `group_id`. Total new commands in `queues_[0]`: 3 fragments * (number of MS3 CE variants) entries.

### P7-U08 — MS3 with selection but no exploration triggers standard MS3 targeting

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure MS2 with `exploration = ExplorationMetric::MassCount` and MS3 with `selection = SelectionMetric::Intensity` but no exploration (`exploration = ExplorationMetric::None`). Create an MS2 exploration group with 3 CE variants. Feed all 3 variants with known scores so one is selected as winner. The winning `DeconvolvedSpectrum` contains 5 fragment ions. Verify the MS3 follow-up after MS2 winner selection.
**Expected outcome:** After the MS2 group completes, `initiateNextLevel_()` is called (not `initiateExploration_()`). Standard MS3 commands are pushed to `queues_[1]` (normal priority, not priority 0), not exploration groups. `active_exploration_groups_` does NOT contain any new MS3 exploration groups — the MS3 path is simple targeting, not exploration.

### P7-U11 — MS2 without exploration + MS3 with exploration triggers MS3 exploration immediately

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure MS2 with `selection = Intensity`, `exploration = None` (no CE sweep at MS2) and MS3 with `exploration = ExplorationMetric::FragmentCount`. Process an MS1 scan that produces standard MS2 commands (no MS2 exploration groups). When the MS2 result returns via `processScan()`, verify that MS3 exploration is triggered immediately from the MS2 result.
**Expected outcome:** Since MS2 has no exploration, there is no MS2 CE sweep and no waiting for a winner. The standard MS2 processing path detects `hasExploration(getLevelConfig_(3))` is true and calls `initiateExploration_()` directly. `active_exploration_groups_` contains MS3 exploration groups with `msn_level == 3` and `exploration_metric == ExplorationMetric::FragmentCount`. MS3 CE variant commands appear in `queues_[0]`. No MS2 exploration groups exist at any point.

### P7-U09 — OptimizationMetadata populated on exploration variant spectra

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Create an exploration group with 2 variants (CE 20.0, CE 25.0 — `double`) and `exploration_metric = ExplorationMetric::MassCount`. Call `feedExplorationResult_()` for variant 0 with a synthetic `DeconvolvedSpectrum`. Inspect the metadata on the spectrum after the call.
**Expected outcome:** `ms2_deconv.hasOptimizationMetadata() == true`. `meta.group_id == <expected group id>`. `meta.variant_index == 0`. `meta.total_variants == 2`. `meta.collision_energy == 20.0` (double, not int — Phase 3 deviation). `meta.activation_type == "HCD"`. `meta.exploration_metric == static_cast<int>(ExplorationMetric::MassCount)`. `meta.is_best_variant == false` (winner not determined yet — only 1 of 2 received). `meta.fragmentation_quality_score > -1.0`. `meta.start_ms > 0`. `meta.exploration_scans == 2`.

### P7-U10 — Metadata serialized to MSSpectrum via setMetaValue

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Starting from P7-U09's spectrum (which has `OptimizationMetadata` set), call `toSpectrum()` and inspect the resulting `MSSpectrum`. **IMPORTANT:** `toSpectrum()` returns `MSSpectrum` by value (Phase 2 lesson #1) — use `MSSpectrum out = ds.toSpectrum(1);`, NOT an out-parameter. **CRITICAL:** `toSpectrum()` unconditionally accesses `peak_groups_[0]` (Phase 2 lesson #3) — the test must push a default `PeakGroup` into the `DeconvolvedSpectrum` before calling `toSpectrum()`. Use `(void)var;` to suppress any unused variable warnings under MSVC `/WX` (Phase 2 lesson #8).
**Expected outcome:** `out_spec.getMetaValue("optimization_group_id")` returns the correct integer. `out_spec.getMetaValue("optimization_collision_energy")` returns 20.0. `out_spec.getMetaValue("optimization_is_best_variant")` returns `"false"`. `out_spec.getMetaValue("optimization_quality_score")` returns the computed score. `out_spec.getMetaValue("optimization_precursor_mass")` returns the precursor mass.

### P7-U12 — MS1 selection metric controls precursor ranking

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure `level_configs_[1]` with `selection = SelectionMetric::Intensity` and `max_targets = 3`. Create a synthetic MS1 deconvolution result with 5 precursors at known intensities and known quality scores (arranged so intensity order differs from qscore order). Call `processScan()` with this data. Verify which precursors are selected. Then reconfigure to `selection = SelectionMetric::QScore` and repeat.
**Expected outcome:** With `selection = Intensity`: the 3 precursors with highest raw intensity are selected (MS2 commands pushed for those 3). With `selection = QScore`: the 3 precursors with highest quality score are selected. The mode-dependent filters (deep mode, inclusion/exclusion, etc.) are not active — this tests pure ranking. The `max_targets` parameter limits the count to 3 in both cases.

### P7-R01 — Exploration disabled regression

**Tier:** 3 (regression)
**CI runner:** `windows-latest`, `windows-tests` job
**Description:** Run `Flash.exe ms1_standard.txt output.tsv method_default.xml` (exploration disabled — no `<SelectionStrategy>` section and no `<ParameterOptimization>` section; defaults to selection-only at each level). Entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1). Spectrum input: `ms1_standard.txt` (see [../test-file-specification.md](../test-file-specification.md) §1.2 for content requirements). Comparison is performed by `compare_golden.py` using the tolerances defined in [../test-file-specification.md](../test-file-specification.md) §2.1.
**Expected outcome:** Output matches the Phase 4 standard DDA golden file (`test-data/golden/phase4_standard_dda.tsv`). Zero deviation in row count, string fields, and floating-point fields within tolerance. No `|EXPL` scan descriptions in the console log. `active_exploration_groups_` remains empty throughout.

### P7-R02 — Exploration enabled produces variant scans in output

**Tier:** 3 (regression)
**CI runner:** `windows-latest`, `windows-tests` job
**Description:** Run `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` (CE 20-40 step 5, producing 5 variants). Entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1). Spectrum input: `ms1_standard.txt` (see [../test-file-specification.md](../test-file-specification.md) §1.2). Config file format and key parameters for `method_exploration.xml` are specified in [../test-file-specification.md](../test-file-specification.md) §3.2. Comparison is performed by `compare_golden.py` using the standard tolerances from [../test-file-specification.md](../test-file-specification.md) §2.1.
**Expected outcome:** Output file matches the committed golden file `test-data/golden/phase7_exploration.tsv`. The golden file contains more rows than `phase4_standard_dda.tsv` — specifically, for each selected precursor there are up to 5 exploration variant scan records in addition to the standard MS2 record. `EXPL-WINNER` log entries appear in console output. `OptimizationMetadata` fields appear as metavalues in the output (verifiable from the TSV columns, if the test mode serializes them, or from inspecting mzML output if `Flash.exe` produces mzML). This is a new golden file created fresh at this phase, not a comparison against a prior phase. **CI hard-fail gate:** `[TRACK-CREATE]` entries must appear in stdout for every exploration variant command (Phase 4 F-5 fix). The regression runner checks this independently of golden-file comparison.

---

## CI Configuration

### Changes to `.github/workflows/flashida-ci.yml`

**CRITICAL (Phase 6 lesson 10):** New C++ test binaries must be added to BOTH the `cmake --build --target` list AND the `ctest -R` regex in `flashida-ci.yml`. The CI uses an explicit allowlist — it does not discover tests automatically. A test registered only in `executables.cmake` will never run in CI.

#### 1. Build targets and CTest filter for exploration tests

In the `cpp-unit-tests` job, update BOTH locations:

**Line 58 — build targets** (add `FLASHIda_exploration_test` to the existing list):
```yaml
cmake --build OpenMS/build --target DeconvolvedSpectrum_OptimizationMetadata_test FLASHIdaQueueTracking_test FLASHIda_ProcessScan_test ScanCommandLayout_test FLASHIdaFAIMS_test FLASHIda_exploration_test
```

**Line 63 — CTest filter** (add `FLASHIda_exploration` to the existing regex):
```yaml
ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration" --output-on-failure
```

Both changes must be in the same commit as the C++ test file creation. Do NOT defer the CI update — an unregistered test is equivalent to no test (Phase 6 lesson 10).

#### 2. Regression runner: add exploration config

In the PowerShell regression runner block (`regression-runner.ps1` or inline YAML), add an entry for `method_exploration.xml`. The runner script format and the full config array are documented in [../test-file-specification.md](../test-file-specification.md) §4.2:

```powershell
@{ name="p7_exploration"; method="method_exploration.xml";
   ms1="ms1_standard.txt"; ms2=$null; golden="phase7_exploration.tsv" },
```

The comparison step already loops over all entries and calls `compare_golden.py`; adding the entry here is sufficient.

#### 3. Golden file for P7-R02 must exist before CI runs

`test-data/golden/phase7_exploration.tsv` must be committed before the `P7-R02` regression test can pass in CI. Because no Windows machine is available locally, the file is captured via the CI-artifact workflow described in Step 11:

1. Push the Phase 7 code changes (without the golden file). The `windows-tests` CI job uploads the produced TSV as the `exploration-golden-candidate` artifact.
2. Download the artifact from the GitHub Actions run page and inspect it: confirm variant rows and metadata fields are present and reasonable. Follow the inspection checklist in [../test-file-specification.md](../test-file-specification.md) §2.3.
3. Commit the downloaded file as `test-data/golden/phase7_exploration.tsv` alongside the Phase 7 code changes.

Also note that `method_exploration_ms3.xml` (used in WPV-7) must be committed to `test-data/configs/` before the corresponding CI step can run — it cannot be created ad-hoc on a local machine.

#### 4. No new CI jobs are required

Phase 7 adds only C++ unit tests (existing `cpp-unit-tests` job, `ubuntu-latest`) and one new regression config (existing `windows-tests` job, `windows-latest`). No new runner, no new job, no new secrets. The existing Build #4 artifact cache key (OpenMS submodule hash) automatically handles the DLL rebuild when the C++ source advances.

#### 5. CI infrastructure reminders (Phase 0–2 lessons)

- **Thermo DLLs (Phase 0 lesson #3):** Use Strategy B — decrypt `FlashIDA/dependencies/thermo-dlls.zip.enc` with `openssl enc -d -aes-256-cbc -pbkdf2` using `THERMO_DLL_PASSPHRASE` secret. Do not use base64 or GPG.
- **OpenMS DLLs (Phase 0 lesson #5):** Already committed in `FlashIDA/dll/`. Do not add cache/download steps. MSBuild copies them via `CopyToOutputDirectory`.
- **NUnit runner (Phase 0 lesson #12):** Invoke by full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.16.3/tools/nunit3-console.exe`). Working directory must be `FlashIDA/bin/`.
- **NUnit flags (Phase 1 lesson #8):** Always pass `--agents=1 --timeout=300000` to the NUnit console runner. Required to avoid cold-cache timeouts from `calculateAveragine` (~3.5 min first call).
- **`OPENMS_DATA_PATH` (Phase 1 lesson #5):** All CI steps that invoke OpenMS via P/Invoke must set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`. Applies to NUnit test steps and `Flash.exe` regression runs.
- **Build output (Phase 0 lesson #12):** Output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/`.
- **Test data path (Phase 1 lesson #2):** `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/`.
- **Submodule pointer updates (Phase 1 lesson #1):** After pushing to either sub-repo, update the parent repo's submodule pointer immediately. New files are silently invisible to CI until the pointer is updated.
- **Submodule batching (Phase 0 lesson #15):** Batch same-side changes (all C++ or all C#) before updating the submodule pointer to minimize churn.
- **DLL build time (Phase 1 lesson #10):** ~40 min per push with no ccache hit. Batch all C++ changes and verify for MSVC `/WX` issues before pushing.
- **`ModificationsDB::getInstance()` (Phase 1 lesson #4):** Never remove or comment out OpenMS singleton initializer calls. Use `(void)` cast if the return value is unused.
- **`.gitattributes` (Phase 0 lesson #4):** If any new binary file extensions are introduced, add them to `FlashIDA/.gitattributes` as `binary` before committing.
- **CTest naming (Phase 2 lesson #4):** Use `ctest -R ClassName` pattern (e.g., `-R FLASHIda_exploration`), not `-R FLASH`.
- **ccache key (Phase 2 lesson #7):** Uses `hashFiles('OpenMS/CMakeLists.txt')` for cache invalidation, not `executables.cmake`.
- **CMake flags (Phase 2 lesson #6):** `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`.
- **`(void)var;` for MSVC `/WX` (Phase 2 lesson #8):** Use `(void)var;` in C++ test code to suppress unused variable warnings under MSVC `/WX`.

---

## Working Product Verification

Because there is no Windows machine available, all WPV items are verified via CI jobs rather than local `Flash.exe` invocations (entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()` — there is no `-t` flag; see Phase 0 lesson #1). Each item maps to a CI job that produces observable evidence (log output, artifact output, or test pass/fail status).

**WPV-1: Exploration disabled — identical to Phase 6**
Verified by the `P7-R01` regression test in the `windows-tests` CI job (`windows-latest`). The job runs `Flash.exe ms1_standard.txt output.tsv method_default.xml` and compares output against `test-data/golden/phase4_standard_dda.tsv` using `compare_golden.py` (comparison tolerances: [../test-file-specification.md](../test-file-specification.md) §2.1). The CI step must report `PASS`.

**WPV-2: CE optimization produces 5 variant scans per precursor**
Verified by the `P7-R02` regression test in the `windows-tests` CI job (`windows-latest`). The job runs `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` and compares output against `test-data/golden/phase7_exploration.tsv`. Inspect the golden file (captured via the CI-artifact workflow in Step 11) to confirm that for each precursor selected by standard DDA scoring there are 5 additional rows with `|EXPL` scan descriptions, and that `EXPL-WINNER` log entries appear in the CI job log.

**WPV-3: Winner is selected by exploration metric score**
Verified by inspecting the `EXPL-WINNER` log lines in the `windows-tests` CI job log for the `P7-R02` run. Confirm that the logged CE value corresponds to the variant with the highest exploration metric score (in this case, `mass_count` = most deconvolved masses) across the 5 variant rows visible in the `phase7_exploration.tsv` artifact.

**WPV-5: MS1 cycle time suppressed during exploration, resumes after**
Verified by the `windows-tests` CI job using a config committed to `test-data/configs/` with `<CycleTime><Active>True</Active><Seconds>1</Seconds></CycleTime>` and exploration enabled, run with a spectrum that takes multiple scan events. The CI job log must show no MS1 cycle-time injection between the first exploration variant submission and the `EXPL-WINNER` log entry for that group, and then resumed MS1 injection afterwards.

**WPV-6: OptimizationMetadata populated and serialized**
Verified from the `phase7_exploration.tsv` artifact produced by `P7-R02` in the `windows-tests` CI job. The standard 15-column golden file format is defined in [../test-file-specification.md](../test-file-specification.md) §2.1. Exploration variant rows extend this with additional metavalue columns written by `toSpectrum()` when `OptimizationMetadata` is present. Inspect the artifact for `optimization_group_id`, `optimization_collision_energy`, `optimization_is_best_variant`, `optimization_quality_score`, and `optimization_precursor_mass` columns — they must be present and non-empty for exploration variant rows.

**WPV-7: Per-level exploration activation — both MS2 and MS3 explore independently**
Verified by the `windows-tests` CI job using `method_exploration_ms3.xml` (committed to `test-data/configs/`) with MS2 exploration = `mass_count` and MS3 exploration = `fragment_count` (`MaxFragments=3`), run with an MS1+MS2 test spectrum. The CI job log must show:
- MS2 exploration groups created with `exploration_metric=MassCount`.
- After MS2 winner selection, MS3 exploration groups created with `exploration_metric=FragmentCount` for the winner's top 3 fragments.
- Both levels explore independently using their own exploration metrics.
- Total exploration scans per MS2 precursor: (5 MS2 CE variants) + (3 fragments * 5 MS3 CE variants) = 20 scans.

This is also verified structurally by P7-U07 (MS3 exploration creates groups) and P7-U08 (MS3 selection without exploration triggers standard targeting) in the `cpp-unit-tests` CI job (`ubuntu-latest`).

---

## Definition of Done

### CI registration (Phase 6 lesson 10 — must not be deferred)
- [ ] `FLASHIda_exploration_test` is listed in `executables.cmake`.
- [ ] `FLASHIda_exploration_test` is in the `cmake --build --target` list in `flashida-ci.yml` (line 58).
- [ ] `FLASHIda_exploration_test` is in the `ctest -R` regex in `flashida-ci.yml` (line 63).
- [ ] All three CI registration items are in the **same commit** as the test file creation.

### Test quality (Phase 6 lessons 12-14)
- [ ] All P7-U* tests use hard assertions (`TEST_EQUAL`, `TEST_REAL_SIMILAR`), no soft guards or `Assume.That`.
- [ ] State machine tests (P7-U05/U06) use separate input and output values, not shared arrays.
- [ ] No queue passthrough tests — all tests exercise production logic paths (`processScan`, `getNextScanCommand`, etc.), not just `pushCommandForTest`.
- [ ] Loop-based assertions (if any) have been traced by hand for at least 3 iterations against the actual implementation.

### Functional completeness
- [ ] All 13 Phase 7 tests pass: P7-U01 through P7-U12 (C++, `ubuntu-latest`) and P7-R01, P7-R02 (`windows-latest`).
- [ ] All prior phase tests (P0 through P6, cumulative total ~90 tests) continue to pass — no regressions introduced.
- [ ] `SelectionMetric` enum, `ExplorationMetric` enum, `MSLevelConfig` struct (with `selection` + optional `exploration`, `max_targets` for MS1 top-N and MS3 fragment count), `ExplorationGroup`, and `ExplorationVariant` structs are defined in `FLASHIda.h`.
- [ ] `processScan()` MS1 branch uses `getLevelConfig_(1).selection` for precursor ranking (`Intensity` or `QScore`) and `getLevelConfig_(1).max_targets` for top-N selection, replacing the hardcoded top-N logic.
- [ ] `initiateExploration_()`, `feedExplorationResult_()`, `initiateNextLevel_()`, `buildMSnCommand_()`, `computeExplorationScore_()`, `computeMassCount_()`, `computeRemainingPrecursorScore_()`, `computeFragmentCount_()`, `buildCEVariants_()`, `parseSelectionMetric_()`, `parseExplorationMetric_()` are implemented in `FLASHIda.cpp`.
- [ ] `getNextScanCommand()` suppresses MS1 cycle time injection when `active_exploration_groups_` is non-empty.
- [ ] `processScan()` MS2 path checks `variant_tracking_to_group_` after tracking ID extraction and routes exploration variants to `feedExplorationResult_()`.
- [ ] `feedExplorationResult_()` scores variants using `computeExplorationScore_()` which dispatches to the correct metric based on `group.exploration_metric`.
- [ ] After MSn exploration winner selection, MSn+1 follow-up is handled by `initiateNextLevel_()` (either from production scan via `processScan()`, or directly from the winner's stored spectrum if no overrides). The logic is generic across levels.
- [ ] When MS2 has no exploration, MS3 (if selection != None) triggers immediately from each MS2 result (chaining rule).
- [ ] `OptimizationMetadata` is populated on every exploration variant's `DeconvolvedSpectrum` before `feedExplorationResult_()` returns, including the `exploration_metric` field.
- [ ] `Parameter.ToJSON()` serializes the `<SelectionStrategy>` XML subtree into the `selection_strategy` JSON object with all sub-keys (selection, optional exploration blocks).
- [ ] `method_exploration.xml` exists in `FlashIDA/test-data/configs/` (format and key parameters per [../test-file-specification.md](../test-file-specification.md) §3.2).
- [ ] `test-data/golden/phase7_exploration.tsv` exists and is committed (canonical name per [../test-file-specification.md](../test-file-specification.md) §2.2).
- [ ] `.github/workflows/flashida-ci.yml` regression runner includes `method_exploration.xml` with golden file `phase7_exploration.tsv` (entry name `p7_exploration`, per [../test-file-specification.md](../test-file-specification.md) §4.2 config array).
- [ ] `Flash.exe ms1_standard.txt output.tsv method_default.xml` with exploration disabled produces output identical to `phase4_standard_dda.tsv` (P7-R01 passes in CI (`windows-tests` job); comparison uses `compare_golden.py` tolerances from [../test-file-specification.md](../test-file-specification.md) §2.1).
- [ ] `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` produces EXPL-WINNER log entries and variant rows in output matching `phase7_exploration.tsv` (P7-R02 passes in CI).
- [ ] All regression tests (P7-R01, P7-R02) produce `[TRACK-CREATE]` entries in stdout (CI hard-fail gate — Phase 4 F-5 fix).
- [ ] MS3 with exploration enabled creates exploration groups after MS2 winner (P7-U07 passes in CI (`cpp-unit-tests` job)).
- [ ] MS3 with selection but no exploration triggers standard MS3 targeting, not exploration groups (P7-U08 passes in CI).
- [ ] MS2 no exploration + MS3 exploration triggers MS3 exploration immediately from MS2 result (P7-U11 passes in CI).
- [ ] MS1 selection metric controls precursor ranking: `Intensity` selects by raw intensity, `QScore` selects by quality score (P7-U12 passes in CI).
- [ ] No new C++ compiler warnings introduced (existing `/Wall` or `-Wall` build flags must remain clean).

### Pipeline transition (Step 12)
- [ ] `top_n_` member variable removed; MS1 precursor count uses `getLevelConfig_(1).max_targets`.
- [ ] MS1 precursor ranking uses `getLevelConfig_(1).selection` (Intensity or QScore), not hardcoded scoring.
- [ ] `ms3_enabled_` member variable removed; MS3 targeting uses `getLevelConfig_(3).selection != None`.
- [ ] All MS2→MS3 targeting goes through `initiateNextLevel_(2, ...)`, not direct `if (ms3_enabled_)` checks.
- [ ] `Parameter.ToJSON()` requires `<SelectionStrategy>` in method XML and crashes if absent. All existing method XML files updated with `<SelectionStrategy>` blocks.
- [ ] Old Phase 1 fields (`exploration_max_depth_`, `exploration_max_variants_`, `exploration_enabled_` as old boolean) removed from C++.
- [ ] P7-R01 passes (exploration disabled output identical to `phase4_standard_dda.tsv`) — primary regression gate for the transition.
- [ ] All existing C++ tests (`FLASHIda_ProcessScan_test`, `FLASHIdaFAIMS_test`, `FLASHIdaQueueTracking_test`, `ScanCommandLayout_test`) pass without modification or with only config variable renames.
- [ ] All existing C# continuity tests (CT01-CT32) and bridge smoke tests pass.
- [ ] All Phase 4 regression configs produce identical golden file output.

### Validation (Step 13)
- [ ] Agent 1 (C++ dead code scan) reports zero references to `ms3_enabled_`, `top_n_`, `exploration_max_depth_`, `exploration_max_variants_`, or `if (ms3_enabled_)` code paths.
- [ ] Agent 2 (C# dead code scan) reports zero references to old `ms3_enabled`/`TopN`/`exploration.enabled` JSON fields in `Parameter.cs` and test files.
- [ ] Agent 3 (config completeness) confirms `Parameter.ToJSON()` emits valid `selection_strategy` for every method XML in `test-data/configs/`.
- [ ] Agent 4 (test coverage) confirms no test bypasses the unified pipeline by setting legacy member variables directly.

### Build #4 batching
- [ ] Phase 7 is batched with Phase 8 in Build #4. All C++ changes for Phase 7 are pushed in a single batch to minimize DLL rebuild cycles (~40 min each).
- [ ] If the ScanCommand struct is NOT modified (expected), no DLL update in `FlashIDA/dll/` is needed for struct layout. However, the DLL must still be rebuilt to include the new exploration engine code. The `build-dlls` workflow triggers automatically on push to `flashida-v9-bridge`.
- [ ] Phase 8 prerequisites are satisfied: Phase 7 golden files committed, all WPV items checked off. Build #4 development can proceed to Phase 8 (cleanup) on the same branch.
- [ ] Code review complete: `SelectionMetric` enum, `ExplorationMetric` enum, `MSLevelConfig` struct, `ExplorationGroup` / `ExplorationVariant` structs, `feedExplorationResult_()` exploration-metric-based winner logic, `computeExplorationScore_()` dispatcher, chaining rule, and MS1 suppression logic reviewed by at least one other developer.

---

## Phase 0–6 Lessons Applied

This section records which Phase 0–6 lessons are directly reflected in this implementation plan, so future plan reviews can verify coverage.

| Lesson | Source | Where Applied in This Plan |
|--------|--------|---------------------------|
| Flash.exe entry point — no `-t` flag | Phase 0 #1 | Cross-References item 1; WPV section preamble; P7-R01, P7-R02 test descriptions; DoD |
| Build output path `FlashIDA/bin/` | Phase 0 #12 | Cross-References item 2; CI reminders §5 |
| DLL name `"OpenMS.dll"` with extension | Phase 0 #12 | Cross-References item 3; Files to Create/Modify note |
| NUnit working directory `FlashIDA/bin/` | Phase 0 #12 | Cross-References item 4; CI reminders §5 |
| Spectrum file format (tab + seconds) | Phase 0 #2 | Cross-References item 5 |
| Thermo DLL Strategy B (openssl) | Phase 0 #3 | Cross-References item 6; CI reminders §5 |
| OpenMS DLLs committed in `FlashIDA/dll/` | Phase 0 #5 | Cross-References item 7; CI reminders §5 |
| Golden file capture requires 2-commit minimum | Phase 0 #15 | Cross-References item 8; Step 11 golden capture workflow; CI §3 |
| DLL-dependent tests are Tier 2 | Phase 0 #12 | Cross-References item 9; Test Cases preamble |
| Silent zero-result P/Invoke failures | Phase 0 #14 | Cross-References item 10; Files to Create/Modify note |
| Submodule batching | Phase 0 #15 | Cross-References item 11; Step 11; CI reminders §5 |
| Multi-scan parser stop at first boundary | Phase 0 #9 | Cross-References item 12 |
| `.gitattributes` binary extensions | Phase 0 #4 | Cross-References item 13; CI reminders §5 |
| Submodule pointer update required for CI | Phase 1 #1 | Cross-References item 14; CI reminders §5 |
| Test data path one level up from `bin/` | Phase 1 #2 | Cross-References item 15; CI reminders §5 |
| NUnit `--agents=1 --timeout=300000` | Phase 1 #8 | Cross-References item 16; CI reminders §5 |
| `OPENMS_DATA_PATH` required in CI | Phase 1 #5 | Cross-References item 17; CI reminders §5 |
| DLL build ~40 min; batch C++ changes | Phase 1 #10 | Cross-References item 18; CI reminders §5 |
| MSVC `/WX` warnings-as-errors | Phase 1 #3 | Cross-References item 19 |
| `ModificationsDB::getInstance()` side effects | Phase 1 #4 | Cross-References item 20; CI reminders §5 |
| Prefer `FLASHIdaWrapper(MethodParameters)` | Phase 1 #11 | Cross-References item 21 |
| ms3 array parsing deferred from Phase 1 | Phase 1 (deferred) | Prerequisites item 6; Cross-References item 22 |
| `toSpectrum()` returns `MSSpectrum` by value | Phase 2 #1 | Cross-References item 23; Prerequisites item 2; P7-U10 description; Test Cases preamble |
| `DeconvolvedSpectrum` constructor takes `scan_number` | Phase 2 #2 | Cross-References item 24; Prerequisites item 2; Test Cases preamble |
| PeakGroup prerequisite for `toSpectrum()` | Phase 2 #3 | Cross-References item 25; Prerequisites item 2; P7-U10 description; Test Cases preamble |
| CTest `-R ClassName` naming convention | Phase 2 #4 | Cross-References item 26; CI Configuration §1; Test Cases preamble |
| CI apt dependencies (full list) | Phase 2 #5 | Cross-References item 27 |
| CMake flags for test-only builds | Phase 2 #6 | Cross-References item 28 |
| ccache key uses `hashFiles('OpenMS/CMakeLists.txt')` | Phase 2 #7 | Cross-References item 29 |
| `(void)var;` for MSVC `/WX` in test code | Phase 2 #8 | Cross-References item 30; P7-U10 description; Test Cases preamble |
| Cumulative test counts (59 after P2, ~70 P4, 77 P5, ~90 P6) | Phase 2 #9 + Phase 5 actuals | Cross-References item 31 |
| `ScanCommand.scan_id` is first field (not `msn_level`) | Phase 3 deviation | Phase 3–6 Deviations Impact §1 |
| `IsolationStage.collision_energy` is `double` (not `int`) | Phase 3 deviation | Phase 3–6 Deviations Impact §2; Step 1 (CE config fields); Step 2 (`ExplorationVariant.collision_energy`); Step 3 (`buildCEVariants_` signature); Step 4 (CE vector type); Step 8 (MS3 CE vector); P7-U01, P7-U03, P7-U09 expected outcomes |
| `IsolationStage.activation_type` is `char[32]` (not `char[16]`) | Phase 3 deviation | Phase 3–6 Deviations Impact §3; Step 2 (`ExplorationVariant.activation_type` comment) |
| `IsolationStage` size = 80 bytes | Phase 3 | Phase 3–6 Deviations Impact §4 |
| `ScanCommand.enqueue_timestamp_ms` added in Phase 4 | Phase 4 | Phase 3–6 Deviations Impact §5; Step 4 (command-building comment) |
| `ScanCommand.faims_cv` added in Phase 6 | Phase 6 | Phase 3–6 Deviations Impact §6; Step 4 (command-building comment); Step 8 (MS3 command comment) |
| ScanCommand size: 1144 -> 1240 (P4) -> 1248 (P6) | Phase 3–6 | Phase 3–6 Deviations Impact §7; Phase 6 Addendum pre-implementation checklist item 4 |
| CI `[TRACK-CREATE]` is hard-fail | Phase 4 (F-5 fix) | Phase 3–6 Deviations Impact §8; Step 4 (`logTrackCreate_` comment); Step 8 (`logTrackCreate_` comment); P7-R02 expected outcome; DoD checklist |
| FAIMS tests must use continuity tests, not regression runner | Phase 5 lesson #1 | Cross-References item 32; Phase 5 Addendum (FAIMS TSV golden files not captured) |
| Single wrapper architecture — no per-CV limitation | Phase 5 lesson #2 | Cross-References item 33; Phase 5 Addendum (exploration commands faims_cv) |
| Capture golden files BEFORE architecture transitions | Phase 5 lesson #3 | Cross-References item 34 |
| Adaptive skip needs 300 scans, not 50 | Phase 5 lesson #4 | Cross-References item 35; Phase 5 Addendum (adaptive skip data requirements) |
| No tautological tests — test behavioral properties | Phase 5 compliance | Cross-References item 36; Phase 3–6 Deviations Impact §10; Phase 5 Addendum (test quality expectations) |
| No soft guards — use hard assertions | Phase 5 compliance | Cross-References item 37; Phase 3–6 Deviations Impact §10; Phase 5 Addendum (CT09/CT10 soft guards) |
| FAIMSScanProcessor legacy path retained in Phase 5, deleted in Phase 6 | Phase 5 deviation | Phase 3–6 Deviations Impact §9; Phase 5 Addendum (Phase 5 status) |
| P5-U03 gap carried forward | Phase 5 gap | Phase 3–6 Deviations Impact §11; Phase 5 Addendum (cumulative test count) |
| New C++ test binaries must be added to CI build targets AND CTest filter | Phase 6 lesson 10 | Phase 6 Addendum pre-implementation checklist item 1; CI Configuration §1 (CRITICAL callout); Files to Create/Modify (cross-listed); DoD CI registration section |
| DLL build workflow only builds, never runs CTest | Phase 6 lesson 11 | Phase 6 Addendum pre-implementation checklist item 6 |
| Off-by-one in loop assertions — trace 3+ iterations by hand | Phase 6 lesson 12 | Phase 6 Addendum pre-implementation checklist item 3; Phase 6 Addendum test specifications (P7-U01 warning); DoD test quality section |
| Separate input and output values in state machine tests | Phase 6 lesson 13 | Phase 6 Addendum pre-implementation checklist item 3; Phase 6 Addendum test specifications (P7-U03 note); DoD test quality section |
| No queue passthrough tests — exercise production logic | Phase 6 lesson 14 | Phase 6 Addendum pre-implementation checklist item 3; DoD test quality section |
| 6-file lockstep rule for P/Invoke struct changes | Phase 6 lesson 15 | Phase 6 Addendum pre-implementation checklist item 2 |
| Per-CV state machine (not single global counter) | Phase 6 lesson 1 | Phase 6 Addendum (FAIMS state machine description) |
| ProcessScan bridge accepts faims_cv parameter | Phase 6 lesson 5 | Phase 6 Addendum (ProcessScan bridge note); Step 4 (faims_cv population) |
| Golden file re-capture on bridge migration | Phase 6 lesson 7 | Phase 6 Addendum pre-implementation checklist item 7 |
| ScanScheduler.cs and FAIMSScanProcessor.cs deleted | Phase 6 (steps 8-9) | Phase 6 Addendum (deleted file references); Prerequisites item 1 |

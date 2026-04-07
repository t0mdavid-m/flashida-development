# Phase 7: Exploration Engine — Lessons Learned

**Date:** 2026-04-07
**Scope:** Implementation of per-MS-level selection and exploration framework (CE sweep optimization) in C++, SelectionStrategy XML/JSON pipeline in C#, pipeline transition from hardcoded `ms3_enabled_`/`top_n_` to `level_configs_`.

---

## 1. Variable Name Collision in Long Functions Causes MSVC-Only Failures

**What happened:** The JSON config parser `parseJSONConfig_()` in `FLASHIda.cpp` already had a `std::stringstream ss` at line ~3198. The new `selection_strategy` parsing code used `auto& ss = config["selection_strategy"]` at line ~3396 in the same function scope. GCC compiled fine (different scoping rules or deferred error), but MSVC produced `error C2040: 'ss': 'auto &' differs in levels of indirection from 'std::stringstream'`. This was only caught by the DLL build CI (MSVC), not by the local Ubuntu compilation.

**Fix:** Renamed to `sel_strategy` and used explicit iterator variables instead of short abbreviations.

**Lesson:** In long functions (~400 lines), always use descriptive variable names, not short abbreviations like `ss`, `it`, `cfg`. Search for existing variables with the same name before adding new ones. The `parseJSONConfig_()` function is a known hotspot for this — it has multiple sections that each introduce local variables in the same scope.

---

## 2. Enums and Structs Used by Tests Must Be Public

**What happened:** `SelectionMetric`, `ExplorationMetric`, and `MSLevelConfig` were initially placed in the `private:` section of `FLASHIda.h` alongside other member variables. The test file `FLASHIda_exploration_test.cpp` referenced these types directly (e.g., `FLASHIda::ExplorationMetric::MassCount`), causing 8 GCC compilation errors: `'enum class OpenMS::FLASHIda::ExplorationMetric' is private within this context`.

**Fix:** Moved the enums and `MSLevelConfig` struct to the `public:` section of the class, alongside the existing test helpers.

**Lesson:** When adding nested types that tests need to reference (for assertions, construction, or comparison), they must be in the `public:` section. The existing pattern of `ForTest()` methods works for calling private methods, but types themselves must be public if tests reference them by name. Consider this during the header design phase, not after CI fails.

---

## 3. JavaScriptSerializer Writes Null for Unset Reference Properties

**What happened:** `JsonMsLevelConfig.exploration` (type `JsonExplorationBlockConfig`, a reference type) was left unset when no exploration was configured. C#'s `JavaScriptSerializer` serialized this as `"exploration": null` in the JSON output. The C++ nlohmann::json parser's `level_obj.contains("exploration")` returned `true` (the key exists), but `level_obj["exploration"].value("metric", ...)` threw `type_error.306: cannot use value() with null`. This crashed `CreateFLASHIda()`, leaving the engine uninitialized. Every subsequent `ProcessScan()` call caused `AccessViolationException`.

**Fix (C# side):** Always emit a default exploration block with `metric: "none"` instead of leaving it null. Applied to all three levels (ms1, ms2, ms3).

**Fix (C++ side):** Added defensive null guard: `if (level_obj.contains("exploration") && !level_obj["exploration"].is_null() && level > 1)`.

**Lesson:** `JavaScriptSerializer` has no `[JsonIgnore]` or conditional serialization — null reference properties are always written as `null`. Either: (a) always initialize reference properties to a default non-null value, or (b) guard against null on the C++ parsing side. Both fixes were applied for defense in depth. This pattern will recur for any new optional JSON sub-object.

---

## 4. Nullable Int Serializes as JSON Null, Crashes C++ value()

**What happened:** `JsonMsLevelConfig` initially declared `max_precursors` and `max_fragments` as `int?` (nullable). When only one was set (e.g., `max_precursors` for ms1), the other serialized as `null`. The C++ parser's `val.value("max_precursors", val.value("max_fragments", 10))` found the key but couldn't convert `null` to `int`, throwing `type_error.302: type must be number, but is null`.

**Fix:** Changed `int?` to `int` and always set both fields to the same value in `BuildSelectionStrategy()`.

**Lesson:** Never use nullable types (`int?`, `double?`) in JSON serialization classes consumed by C++. `JavaScriptSerializer` writes `null` for nullable types with no value, and nlohmann::json's `value()` method does not treat `null` as "key absent" — it treats it as "key present with incompatible type." Use plain `int`/`double` with explicit defaults.

---

## 5. Manually-Built MethodParameters in Tests Miss New Required Fields

**What happened:** `BridgeSmokeTests.BuildJsonConfigString()` manually constructs a `MethodParameters` object but never set `mp.SelectionStrategy`. After Phase 7 made `<SelectionStrategy>` required, `ToJSON()` → `BuildSelectionStrategy()` threw `InvalidOperationException: Method XML must contain <SelectionStrategy> block`.

**Fix:** Added `mp.SelectionStrategy = new SelectionStrategyConfig { ... }` to the test helper.

**Lesson:** When adding a required field to `MethodParameters`, search for all `new MethodParameters()` calls in test code — not just XML files. The XML files are updated by bulk edit, but manually-constructed objects in tests are easy to miss. A grep for `new MethodParameters` across the test directory catches these.

---

## 6. DLL Must Be Updated Before Pushing Parent Submodule Pointer

**What happened:** On the first push attempt, C# changes (emitting `selection_strategy` JSON) were committed and pushed along with submodule pointers, but the DLLs in `FlashIDA/dll/` still contained the old C++ code that didn't understand `selection_strategy`. The `windows-tests` CI job built the C# successfully but crashed at runtime when the old DLL encountered the new JSON structure.

**Lesson:** The commit sequence for cross-project changes is: (1) push C++ to OpenMS, (2) wait for DLL build, (3) download and commit DLLs in FlashIDA, (4) then push FlashIDA + parent. This was already documented as a lesson from Phase 4 (CLAUDE.md lesson from 2026-04-02), but was not followed strictly. The C# fix for null exploration happened to make the JSON compatible with the old DLL (by emitting `metric: "none"` instead of null), but this was luck — the proper fix required the updated DLL.

---

## 7. PeakGroup API: No setIntensity, No getMZ

**What happened:** The test helper `makeSyntheticDeconv()` initially called `pg.setIntensity(intensity)` and the `initiateNextLevel_()` method called `result[i].getMZ()`. Neither method exists on `PeakGroup`. The actual API is: `getIntensity()` (returns `float`, read-only), `getMonoMass()` (monoisotopic mass), `getMzRange(int abs_charge)` (returns m/z range tuple). There is no `setIntensity()` — PeakGroup intensity is computed internally during deconvolution.

**Fix:** Changed `makeSyntheticDeconv()` to just push default PeakGroups (score = count, via `computeMassCount_` = `spec.size()`). Changed `initiateNextLevel_()` to use `getMonoMass()` instead of `getMZ()`.

**Lesson:** Always verify the PeakGroup/DeconvolvedSpectrum API before writing code that interacts with it. The class has unusual asymmetries: `getIntensity()` exists but `setIntensity()` doesn't; there's no single `getMZ()` — only `getMzRange(charge)` which requires a charge parameter. Check the header file, not just what seems natural.

---

## 8. Golden File Capture Requires Regression Runner Entry First

**What happened:** The first CI run with the exploration DLL and C# changes passed all NUnit tests, but produced no `p7_exploration.tsv` artifact because the regression runner didn't have a `p7_exploration` config entry yet. The golden file capture is done by the regression runner, not by a standalone CI step.

**Fix:** Added the `p7_exploration` entry to `regression-runner.ps1` before the golden capture run.

**Lesson:** The golden file 2-commit capture sequence is: (1) add regression runner entry + push (CI fails on missing golden, but produces the output file in the `regression-output` artifact), (2) download output, commit as golden file, push (CI passes). The regression runner entry must be committed before the first capture attempt. This is an extension of Phase 0 lesson #15 (2-commit golden capture).

---

## 9. Exploration Variants Produce Zero Deconvolution Results with Standard Test Data

**What happened:** The golden file `phase7_exploration.tsv` shows all 5 CE variant rows per precursor with `qScore=0` and `monoMasses=0` — the exploration variants produced no deconvolution results. Only the standard MS2 row (the 6th per precursor) has real deconvolution data. This is because `Flash.exe` test mode feeds MS1 spectra through the deconvolution engine but doesn't simulate instrument responses for the exploration MS2 commands — the variants are queued but never receive spectral data.

**Lesson:** This is expected behavior for test mode. The exploration engine's scoring and winner selection logic is verified by the C++ unit tests (P7-U03, P7-U09) which feed synthetic DeconvolvedSpectrum data directly. The regression golden file verifies the pipeline integration (commands are generated and output is produced), not the scoring logic. Real exploration results require actual instrument data or a full acquisition loop simulation via continuity tests.

---

## Summary of CI Fix Iterations

| Iteration | Error | Root Cause | Fix |
|-----------|-------|-----------|-----|
| 1 | MSVC `C2040: 'ss' differs` | Variable name collision with `std::stringstream ss` | Rename to `sel_strategy` |
| 2 | GCC `enum is private` | Enums in private section | Move to public section |
| 2 | `type_error.302: type must be number, but is null` | `int?` serialized as `null` | Change to `int`, set both fields |
| 2 | `InvalidOperationException: SelectionStrategy` | BridgeSmokeTests missing field | Add `SelectionStrategy` to test |
| 3 | `type_error.306: cannot use value() with null` | Null `exploration` property | Always emit default block + C++ null guard |
| 4 | Regression: missing golden file | Expected — 2-commit capture | Add runner entry, capture, commit golden |

# Phase 1 — Lessons Learned

**Date:** 2026-03-27
**CI runs to green:** 10 (8 fixes required after initial push)

---

## 1. Submodule Pointer Updates Are Required for CI

**Issue:** After pushing C++ changes to the `flashida-v9-bridge` branch and C# changes to the `flashida-v9-migration` branch, the `flashida-ci.yml` workflow ran against the **old** submodule commits because the parent repo's submodule pointer hadn't been updated. The new test files (`JsonConfigTests.cs`) and `System.Web.Extensions` reference were invisible to CI — it compiled the old code and ran 42 tests instead of 51.

**Resolution:** After pushing to sub-repos, always `git add FlashIDA OpenMS` in the parent repo and push before expecting CI to pick up the changes.

**Action for future phases:** The CI workflow checks out submodules at the pointer commit, not at the branch HEAD. Every push to a submodule branch must be followed by a submodule pointer update in the parent repo. This was called out in Phase 0 lesson #15 but the specific failure mode (new files silently missing from CI) was not documented.

---

## 2. Test Data Paths — One Level Up from `bin/`, Not Two

**Issue:** `JsonConfigTests.cs` and `BridgeSmokeTests.cs` used `Path.Combine(TestDirectory, "..", "..", "test-data")` to locate test data. `TestContext.CurrentContext.TestDirectory` resolves to `FlashIDA/bin/`, so `../../test-data` goes to the parent repo root (`flashida-development/test-data`), not `FlashIDA/test-data`.

**Correct path:** `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/` to `FlashIDA/`.

**Action for future phases:** All existing test classes (`BridgeMS2Tests`, `ContinuityTests`, `SmokeTests`) use `"..", "test-data"`. New test classes must follow this convention. See Phase 0 lesson #12 item 7 for the working-directory dependency.

---

## 3. Pre-Existing MSVC Build Errors on `flashida-v9-bridge`

**Issue:** The `build_dlls.yml` workflow had not run successfully on `flashida-v9-bridge` (or `FIdevelop`) since January 2026. Two pre-existing MSVC errors blocked the DLL build:

1. **`FLASHHelperClasses.cpp` lines 393/397/401:** `C4100: unreferenced parameter` — empty `operator<`, `operator>`, `operator==` stubs for `MassTag` (from `FLASHGappedTaggerAlgorithm` commit).
2. **`FLASHExtenderAlgorithm.cpp` line 563:** `C4189: local variable is initialized but not referenced` — unused `mod` variable from `ModificationsDB::getInstance()->getModification(...)`.

**Resolution:** Fixed `FLASHHelperClasses.cpp` with `(void)a; return false;` stubs. Fixed `FLASHExtenderAlgorithm.cpp` with `(void)` cast on the return value (important: see lesson #4).

**Action for future phases:** Before starting C++ work that requires a DLL rebuild, verify that `build_dlls.yml` passes on the current branch. Run it manually via `workflow_dispatch` to catch pre-existing build failures early. MSVC's `/WX` (warnings-as-errors) setting catches unused variables and parameters that GCC/Clang would only warn about.

---

## 4. `ModificationsDB::getInstance()` Has a Critical Side Effect

**Issue:** `FLASHExtenderAlgorithm.cpp` line 563 had:
```cpp
auto mod = ModificationsDB::getInstance()->getModification("Carbamidomethyl (M)");
```
This looked like dead code (unused variable), so it was commented out to fix the C4189 warning. This caused a **fatal crash**: `Cannot find shared data! OpenMS cannot function without it!`

**Root cause:** `ModificationsDB::getInstance()` triggers initialization of the OpenMS shared data path resolver as a side effect. Without it, subsequent `ResidueDB` lookups (for ion mass calculations in `FLASHExtender`) fail because the data path is unresolved. The call sequence is:
1. `ModificationsDB::getInstance()` → initializes `File::getOpenMSDataPath()`
2. `Residue::getInternalToAIon()` → calls `ResidueDB` → needs data path already initialized

**Resolution:** Restored the call with `(void)` cast: `(void)ModificationsDB::getInstance()->getModification(...)`.

**Action for future phases:** Never remove or comment out calls to OpenMS singleton initializers (`ModificationsDB::getInstance()`, `ResidueDB::getInstance()`, `ElementDB::getInstance()`) even if the return value is unused. These have initialization side effects that other subsystems depend on. If fixing unused-variable warnings, use `(void)` cast to suppress the warning while keeping the call.

---

## 5. `OPENMS_DATA_PATH` Must Be Set in CI

**Issue:** Even after restoring the `ModificationsDB` call, the `Cannot find shared data` crash persisted. The OpenMS data path resolver searches for `share/OpenMS/` relative to the executable location. In CI, the NUnit agent process runs from the NUnit packages directory, not from `FlashIDA/bin/`, so the relative path search fails.

In Phase 0 this wasn't visible because the Phase 0 DLL (built January 2026) apparently had a different data path resolution behavior, or the specific code path that triggers the check wasn't exercised (see lesson #6).

**Resolution:** Added `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS` as an environment variable in the NUnit test step. The OpenMS submodule contains the full `share/OpenMS/` directory with chemistry data (residue masses, isotope distributions, modifications database).

**Action for future phases:** Any CI step that invokes OpenMS functionality (directly or via P/Invoke) must have `OPENMS_DATA_PATH` set. This includes:
- NUnit tests (via `FLASHIdaWrapper`)
- `Flash.exe` regression runs (already works because `Flash.exe` runs from `FlashIDA/bin/` where it can find the DLL, but explicit env var is safer)
- Future C++ unit tests on Ubuntu (if they need chemistry data)

---

## 6. DLL Rebuild Can Change Which Code Paths Trigger Data Path Resolution

**Issue:** Phase 0's DLL (built from `FIdevelop` January 2026) passed all tests including `P0_I04_ProcessMS2ForTagBasedTargeting` without `OPENMS_DATA_PATH` set. The Phase 1 DLL (built from `flashida-v9-bridge` March 2026) crashed on the same test.

The difference: the January DLL's data path resolution succeeded via relative-path search from the DLL location. The March DLL build (different ccache state, different dependency versions, potentially different link order) produced a binary where the relative-path search failed. The data files aren't bundled in the DLL — they're searched for at runtime.

**Action for future phases:** After any DLL rebuild, set `OPENMS_DATA_PATH` explicitly rather than relying on implicit path resolution. This makes CI deterministic regardless of which DLL build is used.

---

## 7. NUnit Agent Process Crash Masks the Real Error

**Issue:** When the C++ DLL calls `exit(1)` (via OpenMS's `FATAL ERROR` handler), it kills the NUnit test agent process. NUnit reports this as `System.Net.Sockets.SocketException: An existing connection was forcibly closed by the remote host` with `Test Count: 0` — giving no indication of which test caused the crash or what the error was.

Five consecutive CI runs showed only `SocketException` with no useful diagnostics. The actual error (`Cannot find shared data!`) was only revealed by adding `--inprocess` to the NUnit console runner, which runs tests in the same process as the console and captures the stderr output before the process exits.

**Resolution:** Used `--inprocess` temporarily for debugging, then fixed the root cause. The `--inprocess` flag is not suitable for production CI because it doesn't isolate the test process from the console runner.

**Action for future phases:** When NUnit shows `SocketException` / `Agent Process was terminated` with `Test Count: 0`:
1. Re-run with `--inprocess` to capture the actual error
2. Look for `OpenMS FATAL ERROR` in the output — this means the C++ code called `exit()`
3. Common causes: missing `OPENMS_DATA_PATH`, corrupt DLL, missing dependency DLL

---

## 8. NUnit Timeout Must Accommodate `calculateAveragine` Cold Cache

**Issue:** `SpectralDeconvolution::calculateAveragine(false)` takes ~3.5 minutes on the first call in a CI process (computing isotope distribution tables). Subsequent calls in the same process are fast (cached). With the default NUnit timeout, tests that happen to be the first to call `calculateAveragine` (which depends on test execution order) would timeout.

Adding `--timeout=120000` (2 minutes) caused CT07 (1000-scan test) to fail because it was the first test to construct a `FLASHIdaWrapper` after the 3.5-minute cold cache computation.

**Resolution:** Set `--timeout=300000` (5 minutes) and `--agents=1` (single-threaded execution to avoid parallel cold cache computations).

**Action for future phases:** Keep `--timeout=300000` and `--agents=1` in the NUnit runner. If new tests are added that take longer than 5 minutes, increase the timeout. The `calculateAveragine` cold cache is a fixed cost per process — it happens once and then all subsequent calls are fast.

---

## 9. `Console.WriteLine` of JSON Config Floods NUnit Output

**Issue:** The `FLASHIdaWrapper(MethodParameters)` constructor initially called `Console.WriteLine(arg)` to print the JSON config string. Each JSON string is ~800 characters. With 30+ tests constructing wrappers, this produced 24,000+ characters of JSON output captured by NUnit, contributing to agent communication issues.

The C++ side also had `std::cout << sd_defaults << std::endl;` in the `parseJSONConfig_` method, producing ~50 lines of SpectralDeconvolution parameter dump per construction.

**Resolution:** Removed `Console.WriteLine(arg)` from the new constructor. Removed `std::cout << sd_defaults` from the JSON parsing path. The legacy constructor's `Console.WriteLine(arg)` was left as-is (it prints the shorter space-delimited string).

**Action for future phases:** Avoid verbose stdout logging in code paths that run during test setup. NUnit captures all stdout per test case, and large captured output increases memory pressure on the agent process. Use a dedicated logger (log4net IDAlog) for detailed config output instead.

---

## 10. DLL Build Cycle Takes ~40 Minutes with No ccache Hit

**Issue:** Each push to `flashida-v9-bridge` triggers a full OpenMS build on `windows-2022` that takes 35-40 minutes. The ccache key includes the branch name (`flashida-v9-bridge`), and since this was the first build on this branch, there was no cache hit. This meant every build fix (3 fixes across 3 builds) cost ~40 minutes each.

**Resolution:** No mitigation available for the first build. Subsequent builds on the same branch benefit from ccache (build 3 was faster than build 1). The `workflow_dispatch` trigger added in step A0 allows manual builds without needing to push code.

**Action for future phases:** When a phase requires DLL changes, batch ALL C++ changes into a single push to minimize rebuild cycles. Verify the code compiles locally (or check for obvious MSVC issues like unused variables/parameters) before pushing. Each failed build wastes 40 minutes.

---

## 11. Constructor Overloading Preserves Backward Compatibility

**Issue:** The plan called for modifying `FLASHIdaWrapper`'s constructor to accept `MethodParameters` instead of `IDAParameters`. However, several code paths (bridge tests, the legacy `BuildLegacyConfigString()` helper) need to construct wrappers from `IDAParameters` directly.

**Resolution:** Added `FLASHIdaWrapper(MethodParameters mp)` as a new overload while keeping the existing `FLASHIdaWrapper(IDAParameters param)` constructor. Both work: the old one uses `ToFLASHDeconvInput()` (legacy string), the new one uses `ToJSON()` (JSON). C++ auto-detects the format.

**Action for future phases:** When changing how data is passed across the P/Invoke bridge, prefer adding new overloaded constructors/methods over modifying existing ones. The old path serves as an immediate fallback if the new path fails.

---

## Summary of CI Fixes

| # | Fix | Root Cause | CI Runs |
|---|-----|-----------|---------|
| 1 | Update submodule pointers | CI uses pointer commit, not branch HEAD | 1 |
| 2 | Fix test data path (`..` not `../..`) | `TestDirectory` is `bin/`, not `src/Flash.Tests/` | 1 |
| 3 | Fix `FLASHHelperClasses.cpp` C4100 | Pre-existing MSVC error from empty stubs | 1 |
| 4 | Fix `FLASHExtenderAlgorithm.cpp` C4189 | Commented out line with critical side effect | 1 |
| 5 | Remove `Console.WriteLine` of JSON | Agent communication issues from large output | 1 |
| 6 | Remove `std::cout << sd_defaults` from JSON path | Verbose C++ output flooding NUnit capture | 1 |
| 7 | Set `OPENMS_DATA_PATH` in CI | OpenMS can't find chemistry data files | 1 |
| 8 | Increase NUnit timeout to 300s + single agent | `calculateAveragine` takes 3.5 min on cold cache | 1 |

---

## Summary of Deviations from Plan

| Item | Plan Says | Actual | Reason |
|------|-----------|--------|--------|
| Constructor strategy | Modify existing constructor | Added overload, kept old | Backward compat for bridge tests |
| `ScanSchedulingConfig` XML class | Add to MethodConfig.cs | Deferred | No XML source yet; scheduling stored as JSON defaults |
| `ParameterOptimizationConfig` XML class | Add to MethodConfig.cs | Deferred | Same reason |
| `TestBridgeHelper` class | Extract P/Invoke helpers | Inline in `BridgeSmokeTests` | Simpler; existing pattern sufficient |
| Golden JSON files | Commit `config_default.json`, `config_full.json` | Deferred to golden capture run | Requires separate CI capture step |
| NUnit runner flags | Default | `--agents=1 --timeout=300000` | Prevent cold cache timeout and parallel issues |
| `OPENMS_DATA_PATH` | Not mentioned in plan | Required in CI | DLL rebuild changed data path resolution |
| `ContinuityTestHarness` constructor | Use `FLASHIdaWrapper(MethodParameters)` | Same (after brief revert for debugging) | Reverted temporarily to isolate crash, then re-enabled |
| `FLASHHelperClasses.cpp` fix | Not in scope | Required | Pre-existing build error blocked DLL build |
| `FLASHExtenderAlgorithm.cpp` fix | Not in scope | Required | Pre-existing build error blocked DLL build |

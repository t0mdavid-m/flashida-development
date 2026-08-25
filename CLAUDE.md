# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@docs/kb/index.md

## Repository Structure

This workspace is a parent repo with **two git submodules** — tightly coupled projects for real-time intelligent data acquisition in top-down proteomics:

- **FlashIDA/** (submodule `t0mdavid-m/FlashIDA`) — C# / .NET Framework 4.8 application that controls acquisition on Thermo Scientific tribrid instruments. Has its own `FlashIDA/CLAUDE.md` with detailed architecture.
- **OpenMS/** (submodule `t0mdavid-m/OpenMS`) — C++20 fork of OpenMS providing the FLASH deconvolution engine FlashIDA calls at runtime. Has its own `OpenMS/CLAUDE.md` scoped to the FLASH real-time engine.

`.gitmodules` pins OpenMS's tracking branch to `FIdevelop`, but both submodules are currently checked out on **`august_pre`** (matching the parent). CI checks out with `submodules: recursive`. Because these are submodules, `git` from the parent root does **not** show their committed files (DLLs, sources) — run `git` from inside `FlashIDA/` or `OpenMS/` to inspect them.

## How the Projects Connect

FlashIDA's `FLASHIdaWrapper.cs` P/Invokes `OpenMS.dll`. The C bridge is **exactly 5** `extern "C"` exports, declared in `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` and defined in `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` (note the OpenMS layout: headers live under `include/OpenMS/…`, sources under `source/…` with **no** `OpenMS/` segment), and consumed via `[DllImport("OpenMS.dll")]` in `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`:

`CreateFLASHIda` · `DisposeFLASHIda` · `ProcessScan` (enqueue a spectrum) · `GetNextScanCommand` (drain the next instrument command by priority) · `GetNextTrackingId`. There are **no** separate MS2/MS3/exclusion-list exports — everything flows through `ProcessScan` (enqueue) + `GetNextScanCommand` (drain).

> **`GetNextScanCommand` never returns 0 for an empty queue.** Every path in `FLASHIda::getNextScanCommand` returns `1`: when all four priority queues drain, Step 5 mints a fresh **idle survey** — an MS1 at priority 3 — pushes it, re-enters `dequeue()` and returns it, so the instrument is never left idle. `0` reaches the caller only from the bridge's null-argument guard (`FLASHIdaBridgeFunctions.cpp:73-80`) or the C# `catch`. **Consequence: `while (GetNextScanCommand(…) == 1)` never terminates.** Every sanctioned drain loop carries its own bound — break on `cmd.MsnLevel == 1 && cmd.Priority == 3`, or cap iterations. This is the single most common way to hang a test. Pinned by `BridgePhase3Tests` ("never returns 0").
>
> ⚠️ **The idle path emits no AGC prescan, and `IsAgc` is NOT a drain sentinel** (ADR-0031). Step 5 used to fabricate a prescan as filler — and, because it also called `recordAGCTime()`, reset the very timer Step 1 reads, so `agc_interval_seconds` never governed the real cadence. Prescans now come from `agc_interval_seconds` alone (production default **1 s**; all 41 committed test configs pin it at `9999999` so goldens stay wall-clock independent). Priority 3 is the sentinel because `makeMS1()` sets it and every other caller overrides to 0 — MS2 is 2, MS3 is 1 — so a priority-3 MS1 *is* "Step 5 fabricated this". Pinned on both CI paths: `FLASHIda_ProcessScan_test::only_the_idle_survey_is_emitted_at_priority_3` ∥ `IdleSurveySentinelTests`. A *scheduled* prescan can still arrive mid-drain; breaking on it truncates the drain.

**The load-bearing ABI contract is the `ScanCommand` struct: exactly 2048 bytes, embedding `IsolationStage stages[10]` at 80 bytes each.** C++ defines it in `.../TOPDOWN/FLASHIda/ScanCommand.h` (guarded by `static_assert(sizeof(ScanCommand)==2048)` and `static_assert(sizeof(IsolationStage)==80)`); C# mirrors it at the top of `FLASHIdaWrapper.cs` (`[StructLayout(Sequential, Pack=8, CharSet=Ansi)]` with a trailing `Reserved` byte block). **When adding a bridge field, carve bytes from `Reserved` — never change the 2048-byte total — and update both sides in lockstep.** Drift is caught by `ScanCommandLayout_test` (C++) and `ScanCommandLayoutTests` (C#), both run in CI.

Four ADRs constrain what may cross this struct — read them before designing a bridge field: **0008** (a scan's handshake channel and identity channel are separate; never conflate them), **0009** (a scan config fully determines a scan's instrument parameters, as scoped by **0011**: source-region parameters are shared by the whole cycle and inherit the survey's value), **0010** (per-stage instrument arrays are positional; structural and optional parameters differ), **0012** (`faims_enabled` — the worked example of carving a field from `Reserved`: 600 → 596 bytes, total unchanged at 2048, no existing offset moved, both layout tests updated in the same push).

## Build

**Build in CI, not locally** (`.github/workflows/flashida-ci.yml`); local builds are for rare manual verification. Build sparsely; at a minimum push once at the **end** of a run so the work lands verified. CI runs on push to `main`, `develop`, `flashida-v9-migration`, `phase-*`, `august_pre`.

### FlashIDA (C# / .NET Framework 4.8, C# 7.3, x64, Windows only)
```
nuget restore FlashIDA/src/Flash.sln
msbuild       FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /m
```
Solution is at `FlashIDA/src/Flash.sln`. Projects: `Flash` → `Flash.exe`, `Flash.Tests` → `Flash.Tests.dll`; both output to `FlashIDA/bin/`. `PlatformTarget` is x64 despite the `Any CPU` switch.

DLL dependencies:
- **OpenMS runtime DLLs** are committed in the FlashIDA submodule at `FlashIDA/dll/` (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`, `zlib.dll`) and copied to `bin/` by MSBuild (`CopyToOutputDirectory`). To update them for local runs, rebuild OpenMS and commit the DLLs into `FlashIDA/dll/`.
  **In CI the committed DLLs are overwritten before the C# build**: the `build` job uploads a freshly compiled `OpenMS.dll`/`OpenSwathAlgo.dll`/`Qt6*.dll` as artifact `openms-fresh-dll`, and `windows-tests` copies them over `FlashIDA/dll/` (only `zlib.dll` stays committed). That is deliberate bridge/ABI drift detection — the C# suite always runs against the OpenMS submodule SHA, not the committed binary. It also means **every CI run links a different `OpenMS.dll`**, so floating-point score columns jitter run-to-run; golden comparison is tolerance-based for floats and exact for ints/strings/structure.
- **Thermo iAPI DLLs** are proprietary and **not** committed: `FlashIDA/dependencies/` holds only XML doc stubs plus `thermo-dlls.zip.enc` (openssl AES-256). CI decrypts it with secret `THERMO_DLL_PASSPHRASE` and copies the DLLs into `bin/`. Local builds need the real DLLs placed in `dependencies/` (see `FlashIDA/Installation.md`).

### OpenMS (C++20 / CMake) — **Do NOT build unless explicitly asked** (resource-intensive; CI handles it)
CI builds on **`windows-2022`** (all three jobs do) with the MSVC toolchain via a Visual Studio shell, `choco install ninja cmake ccache 7zip eigen`, `install-qt-action` (Qt 6.8.3), and a **prebuilt contrib tarball** downloaded from the `OpenMS/contrib` releases (`submodules: true`, *not* recursive, so OpenMS's nested `contrib` stays empty for the tarball to extract into) — **not** apt and **not** vcpkg. The pipeline is one `build` job (compiles OpenMS once + packages the build tree as artifact `cpp-test-build`) feeding two parallel test jobs: `windows-tests` (C# / NUnit / regression) ∥ `cpp-tests` (ctest).

The build is **Release** (not Debug), Ninja, no GUI/pyOpenMS, static Boost, and after `--target OpenMS` it compiles **23 named FLASH test binaries**, not the whole library:
```bash
cmake -S OpenMS -B OpenMS/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -DBOOST_USE_STATIC=ON \
  -DOPENMS_CONTRIB_LIBS=<repo>/OpenMS/contrib -DCMAKE_PREFIX_PATH="$QT_ROOT_DIR/lib/cmake;$QT_ROOT_DIR" \
  -DEigen3_DIR=C:/ProgramData/chocolatey/lib/eigen/share/cmake -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build OpenMS/build --target OpenMS
cmake --build OpenMS/build --target FLASHIdaFAIMS_test ScanCommandLayout_test FragmentAnalysis_test  # …22 total
```
Two consequences of Release: `OPENMS_PRECONDITION` and debug asserts are **compiled out** (accepted tradeoff — it matches the production toolchain), and test exes land in `OpenMS/build/src/tests/class_tests/bin/` (the class-test `RUNTIME_OUTPUT_DIRECTORY` override), **not** `OpenMS/build/bin/` (library output). Running one on Windows needs the 5-DLL set staged beside it, including `zlib.dll` — `OpenMS.dll`'s own load-time dep; without it you get `0xc0000135 STATUS_DLL_NOT_FOUND`. Do **not** pass `ENABLE_CLASS_TESTING=OFF`.

## Testing

Set `OPENMS_DATA_PATH=<repo>/OpenMS/share/OpenMS` for the ctest run. **It is ignored by every C# process**: `FLASHIdaWrapper`'s static constructor unconditionally overwrites it with `<assembly dir>/share/OpenMS` (`FLASHIdaWrapper.cs:135-139`), which MSBuild populates from FlashIDA's *own* committed `FlashIDA/share/OpenMS` tree — a pruned copy (148 files) that has drifted from `OpenMS/share/OpenMS` (254 files). So NUnit and regression runs read `FlashIDA/bin/share/OpenMS` no matter what you export. Only tests that P/Invoke `OpenMS.dll` without touching `FLASHIdaWrapper` (`BridgeSmokeTests`, `BridgePhase3Tests`) never trigger that initializer.

### FlashIDA (C# NUnit — tests in `FlashIDA/src/Flash.Tests/`)
Console runner is restored via NuGet (`NUnit.ConsoleRunner 3.16.3`).
```
# all tests (CI runs exactly this, unfiltered — see below)
FlashIDA\src\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe FlashIDA\bin\Flash.Tests.dll
# a single test
... nunit3-console.exe FlashIDA\bin\Flash.Tests.dll --where "test=='Flash.Tests.BridgeSmokeTests.<Method>'"
```
CI runs with `--agents=1 --timeout=300000` and **no `--where` and no category filter** — the whole suite executes. `ContinuityTests.P4_AL_CT35_MS3Mode1_MS2ReturnPipeline` and `…CT36_MS3Mode2_MS2ReturnPipeline` were excluded for a period as data-dependent and flaky; both are re-enabled and green, and the two goldens only they can write (`continuity_ms3_mode{1,2}_real.json`) have been recaptured. An exclusion here silently freezes those goldens, so don't re-add one without a plan for regenerating them.

Other CI-driven suites:
- **Offline / test-mode deconvolution** — `Flash.exe <input_spectrum> <output.tsv> <method.json> [ms2_spectrum]`, positional and in exactly that order. **There are no CLI flags.** `Flash.csproj:38` pins `<StartupObject>Flash.IDA.FLASHIdaWrapper</StartupObject>`, so **as CI builds it** the assembly's entry point *is* `FLASHIdaWrapper.Main`, and passing `-t` makes it `args[0]` — the input filename — so the run dies with `Cannot open input file: -t`.
  ⚠️ **That does NOT make `Flash.Flash.Main` dead code.** It owns the Mono.Options set (`-t/--test`, `-m`, `-o`, …) **and the entire Thermo instrument path**, and it is what runs on the hardware — owner-confirmed. The `StartupObject` is a developer toggle flipped at deploy time and back, **outside version control**: `git log -L 37,39:src/Flash/Flash.csproj` in the submodule shows the file created at `Flash.Flash` (2021-07-01) and **21 flips** since, the last to the offline harness in 2025-07. So the deployed binary is built from a tree that differs from `HEAD` in exactly this line, and no CI job has ever executed the production entry point. Treat a defect in `Flash.cs` as a live production bug. See `FlashIDA/CLAUDE.md` for the consequences.
- **Regression + golden** — `powershell FlashIDA\test-scripts\regression-runner.ps1 -FlashExe FlashIDA\bin\Flash.exe -TestDataDir FlashIDA\test-data -OutputDir FlashIDA\test-output [-captureMode]`. Iterates 14 mode cases and diffs TSV output against `FlashIDA/test-data/golden/*.tsv` via `python FlashIDA/test-scripts/compare_golden.py` (`-captureMode` regenerates goldens; needs Python on PATH).

**`windows-tests` also runs three non-test gates that can fail an otherwise-green suite.** All three are deliberately fail-closed — a missing input file is a failure, not a skip:
- *Verify bridge smoke tests* — re-parses `TestResults.xml` and requires **at least one** `BridgeSmokeTests` case with every match `Passed`. Renaming or category-filtering that class breaks CI even though nothing regressed; `Skipped`/`Inconclusive` count as failures.
- *Verify TRACK-CREATE entries* — greps `FlashIDA/test-output/regression-stdout.txt` for `[TRACK-CREATE]`; **zero entries fails**. (Skipped only when the regression step itself didn't run.)
- *Verify test data directories* — requires `FlashIDA/test-data/configs/method_default.json` and `method_json_roundtrip.json` to exist.

### Goldens — three separate sets, recapture each on its own path
A behaviour change usually moves more than one set. Know which you touched:

| Set | Location | How to recapture |
|---|---|---|
| Log goldens (largest surface) | `FlashIDA/test-data/golden/logs/<mode>/<stream>.golden.tsv` — 22 modes × 5 streams | Re-run `FLASHIdaLogGolden_test` with env `LOG_GOLDEN_CAPTURE=1`, or promote CI artifact `log-golden-capture` (`<mode>/<stream>.normalized` is byte-identical to a local capture) |

The five `<stream>` basenames are fixed **in the engine** (`IdaLogger`'s `k*Name` constants,
mirrored by `LogGoldenComparer.FileNames`); only their location is configurable, via the single
`runtime.log_dir` key. Renaming one is a golden-moving change on both sides. A capture run now
refuses to write when the engine did not produce all five streams — it performs no comparison at
all, and a missing file normalizes to `""`, so an unguarded capture over a mislocated run would
blank the goldens and pass.
| Regression TSVs | `FlashIDA/test-data/golden/phase4_*.tsv`, `baseline_*.tsv` | `regression-runner.ps1 -captureMode` |
| Continuity JSONs | `FlashIDA/test-data/golden/continuity_*.json` | continuity-golden capture; CI artifact `continuity-golden-capture` |

The 5 log streams per mode are `ida.log`, `scan_commands.tsv`, `scan_results.tsv`, `identification.tsv`, `pooled_identification.tsv` — each has a distinct role (command detail / pure event / per-ID + coverage / cumulative). Golden comparison matches columns **by header name**, so reordering log columns needs no recapture; adding, removing, or changing a value does. Column inventory: `LOG_COLUMN_ORDER_REFERENCE.md`.

**Writing a golden is gated by a repo hook, not just by judgement.** `.claude/settings.json` wires six hooks that fire on every session in this repo:

| Event | Matcher | Hook | Effect |
|---|---|---|---|
| PreToolUse | `Edit\|Write\|Bash` | `golden-write-guard.sh` | **Can deny the call** — a blocked golden write is the gate working, not a tooling bug |
| PreToolUse | `Edit\|Write` | `log-impact-reminder.sh`, `driver-sync-reminder.sh`, `config-schema-drift-reminder.sh` | Advisory: flags edits that move log output, drive sites, or the config schema |
| PostToolUse | `Edit\|Write\|Bash` | `golden-change-detector.sh` | Reports goldens the turn touched |
| Stop | — | `archive-implemented-specs.sh` | Moves implemented specs into `docs/superpowers/specs/archive/` |

If `golden-write-guard.sh` blocks a write, surface the golden diff and get sign-off rather than routing around the hook.

### OpenMS (C++ ctest) — active FLASH targets are in `OpenMS/src/tests/class_tests/openms/executables.cmake`
```bash
# the FLASH suite as CI runs it (no -E; the -R alternation lists every target that runs)
ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration|FLASHIda_LegacyConfig|ConfigSchemaParity|FLASHIda_LoggingFields|FLASHIda_Logging|ScanCommandQueue_Concurrent|FragmentAnalysis|MS3FragmentMatcher|FLASHIda_ChargeModes|ScanConfig_applyOverrides|Config_SchemaProjection|ProteoformTracker_CEOptimization|ProteoformTracker_Trajectory|ProteoformTracker_Localization|ProteoformTracker_WinnerContext|ProteoformTracker_NonWinnerRematch" --output-on-failure
# a single test
ctest --test-dir OpenMS/build -R FLASHIdaFAIMS --output-on-failure
```
**A C++ test runs in CI only if it is added in BOTH places**: the build `--target` list in `.github/workflows/flashida-ci.yml` AND the `ctest -R` alternation *in the same file*. Registering it in `executables.cmake` alone is *not* enough — it will compile but never execute (or not even build). `ctest -R FLASH` alone is **insufficient**: it misses `FragmentAnalysis_*`, `ScanCommandLayout_test`, `ScanCommandQueue_Concurrent_test`, `MS3FragmentMatcher_*`, `ScanConfig_applyOverrides_test`, `ConfigSchemaParity_test`, `ProteoformTracker_*` (5), and `DeconvolvedSpectrum_OptimizationMetadata_test` — every name that doesn't start with `FLASH`. There is no `-E` exclusion; the `-R` alternation is the whole active set.

C++ tests read fixtures from `../../FlashIDA/test-data` relative to `OpenMS/build`, so the FlashIDA submodule must be checked out to run them.

## Key Development Concerns

- **Cross-project bridge changes** — keep the 5 exports and the 2048-byte `ScanCommand` struct in sync across `FLASHIdaBridgeFunctions.{h,cpp}` and `FLASHIdaWrapper.cs` (see *How the Projects Connect*), and run the layout tests on both sides.
- **FLASH code location** — headers under `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/`, sources under `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/` (the `source` tree has **no** `OpenMS/` segment — `source/OpenMS/…` does not exist). `FLASHIda.cpp` (real-time IDA driver; its `processScan` runs deconvolution + precursor selection) and `FLASHIdaBridgeFunctions.cpp` sit directly under `TOPDOWN/`; the 13 runtime helpers live in the nested `TOPDOWN/FLASHIda/` subdirectory: `Config`, `Deconvolution`, `Exploration`, `FAIMS`, `FragmentAnalysis`, `IdaLogger`, `MS3FragmentMatcher`, `Ms2Params`, `PrecursorSelection`, `ProteoformTracker`, `Quantification`, `ScanCommand`, `ScanCommandQueue`. See `OpenMS/CLAUDE.md` for what each owns.
- **Scan processing is unified** — `UnifiedScanProcessor` is the *sole* production `IScanProcessor` (single `void ProcessMS(ScanData)`); all MS levels route through `FLASHIdaWrapper.ProcessScan` → C++ `processScan`, and commands are drained separately via `GetNextScanCommand` in `Flash.cs`. (`ScanScheduler.cs`, `FAIMSScanProcessor.cs`, `IDAScanProcessor.cs`, and `QuantScanProcessor.cs` do **not** exist.)
  - **`ProcessMS` takes an owned snapshot, not an `IMsScan`.** `DataPipe.Push` copies the six values the engine needs (`ScanData.From`) on the *arrival* thread, while the handle is still live, and queues that. An `IMsScan` is a window onto framework-owned memory the iAPI frees once its `LastScan` advances, so a queued handle is only safe while the queue stays ~1 deep — which it was purely because the command drain blocked behind the deconvolution. The signature is pinned by `InterfaceShapeTests`, and `ContinuityTestHarness` (which produces the log goldens) must convert through the *same* `ScanData.From`, or the goldens encode the harness's reading of a scan rather than the engine's.
- **Method configuration is JSON** — `FlashIDA/src/Flash/etc/method.json` (**not** XML). Top-level sections map to `[JsonKey]` classes in `FlashIDA/src/Flash/MethodConfig.cs` (note: directly under `src/Flash/`, there is no `Configuration/` directory): `global`, `deconvolution`, `precursor_selection`, `flashtnt`, `tagging`, `quantification`, `faims`, `ms_settings`, `scheduling`, `characterization`, `files`, `runtime`, plus a synthetic `developer` section into which `[Developer]`-marked fields are routed. Loading is reflection-driven (`FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs`); FlashIDA then re-serializes to a *different* C++-facing schema via `MethodParameters.ToCppJson()` before crossing the bridge. See `docs/kb/config-flow/`.
  - **`selection_strategy` no longer exists** (ADR-0014). Selectivity lives in two decision sections and scan parameters stay in `ms_settings`: `precursor_selection` answers *which species do we fragment* (`rank_by`, `max_precursors`, `min_precursor_charge`, `precursor_charges`, `additional_scans`, `exploration`, `tag_expansion`), `characterization` answers *whether and how we characterize* (`mode`, `protein_sequence`, `max_targets`, `min_fragment_charge`, `fragment_charges`, `exploration`).
  - **Charge-state co-isolation** (ADR‑0016) is `precursor_selection.precursor_charges` and `characterization.fragment_charges`, both `single | separate | multiplexed`, both defaulting to `single`. `multiplexed` co-isolates a species' SNR-positive charge states as **notches** in one scan; because every notch is the same neutral mass the spectrum is not chimeric, which is why no part of the 1-scan-1-precursor identity model changed. `fragment_charges` **replaces the bool `ms3_all_charges`** (`false`→`single`, `true`→`separate`); the old key throws a migration error.
  - **To pick SPECIFIC charge states the knob is the inclusion list, not `precursor_charges`** (ADR-0028). `precursor_charges` is all-or-one; an **authored charge set** in the inclusion TSV's charge column names which ones: `10;13;16`, `;`-separated (not `,` — a comma-decimal locale writes `12351,3`), with `-1`/empty meaning unrestricted. It **restricts and never extends** — a named charge still has to clear the SNR gate to be co-isolated, and one the survey never resolved is skipped outright because isolation geometry must be measured. The anchor becomes the highest-SNR named charge (overriding `consider_all_charges`), the logged qscore becomes that charge's own, and exclusion is re-keyed to `(nominal mass, charge)` **for those species only** — which is what lets `single` walk the set across successive surveys instead of retiring the mass on its first acquisition. Rows naming the same mass and active at the same RT **union** their sets, so one row `10;13;16` equals three rows `10`/`13`/`16`. Emits `[CHARGE-SET]`; pinned by `FLASHIda_ChargeModes_test` CM-04..CM-08.
  ⚠️ **The budget counts species/fragments in all three modes.** `separate` (N scans) and `multiplexed` (1 scan) both acquire one species' whole envelope for **one** `max_precursors` / `max_targets` slot — they differ only in scan count, never in how much budget a species buys. Counting acquisitions instead is the pathology the modes exist to avoid: it makes `max_targets: 3` spend everything on the first fragment that happens to have three charges. Enforced by a species/fragment counter in `PrecursorSelection` and `planNextScans`, not by `selected_peak_groups_.size()`. `ms1`/`ms2`/`ms3` now appear only under `ms_settings`, all three as **bare objects**; extra MS2 configs go in `ms_settings.additional_ms2` as a name→object map and reach the dispatch roster only by being referenced. `cycle_time` and `scan_timeout` nest under `scheduling`.
  - **The schema is strict on both sides**: unknown keys are hard-rejected by `MethodConfigSerializer.cs` (C#) *and* `Config.cpp` (C++) — ADR 0007, and `ms_settings` field names are snake_case only. A typo'd key fails loudly rather than being silently ignored. `FlashIDA/test-data/config_schema_reference.json` is generated from the schema, so it can never go stale — regenerate rather than hand-edit.
  - **Strictness is asymmetric, and the C# side is the tighter one.** C++ `kScanKeys` (`Config::scanKeys()`) admits 17 keys for *every* scan object and `parseScanConfig` reads all of them; the C# structs decide what can actually be written. A key missing from `MS2Parameters`/`MS3Parameters`/`JsonMs2Config` is **unreachable from `method.json`** no matter how completely C++ supports it — that is how `rf_lens`/`source_cid`/`source_cid_scaling`/`scan_rate` silently stopped reaching MSn scans (ADR-0011, reversing an ADR-0007 consequence). `ConfigSchemaParity_test::GeneratedReference_CarriesEveryScanKey` now pins the two sets together. When adding a scan key, add it to the C# struct **and** the emit DTO **and** regenerate the reference **in one commit** — `ConfigSchemaParityTests.Emit_And_Reload_PreserveEveryKey` loads the regenerated reference through the strict loader and throws if the model has not caught up.
  - **Source-region vs analyzer-side** (ADR-0011, `CONTEXT.md`): `rf_lens`/`source_cid`/`source_cid_scaling` act before the analyzer and so are shared by every scan in a cycle — an MSn scan that leaves them at 0 inherits the survey's value (resolved in `ToJsonScanConfig`, so what crosses the bridge is always concrete), and `ScanFactory` sends them unconditionally because 0 is a real setting. Everything else is per-scan, never inherited, and 0/`""` means "use the instrument method default".
  - **`faims.cv_values` decides whether FAIMS runs at all** (ADR-0012): empty = off (and `FAIMS Voltages = "off"` is actively commanded), one CV = on at a fixed CV with no cycling, two or more = cycling. It used to be `size() > 1`, so a single-CV method silently ran with no FAIMS; 27 committed configs carried single-CV boilerplate and are now `[]`.
- **Acquisition modes** — `precursor_selection.targeting`, a **string enum**: `none` (standard DDA), `inclusion`, `in_depth`, `exclusion_masses`. It was an int (`target_mode`) whose 2/3 meanings were documented backwards in three files; the enum takes its mapping from the code and unknown values are rejected.
  The 2/3 mapping used to be **backwards in every doc comment in the tree**, and all three are now
  corrected (`MethodConfig.cs`, `Config.h`'s `TargetingConfig::mode`, and the `// deep mode` above the
  mode-3 branch in `PrecursorSelection.cpp`). The mapping, from the code: mode 2 loads `Mass` lines
  into `target_mass_rt_map_`, builds the tqscore product map and runs the extra `iteration == 0` pass,
  logging `"in-depth mode"`; mode 3 loads `AllMass` lines into `exclusion_rt_masses_map_` and hard-skips
  matches (`if (to_exclude) continue;`), logging `"exclusion mode"`. That mislabelling cost real time —
  `method_deep.json` and `method_exclusion.json` were each *named for the mode they did not set*, and
  the goldens and continuity tests downstream inherited the error, so three independent naming layers
  agreed with each other and disagreed with the engine (ADR-0014).
  ⚠️ **`in_depth` is a SOFT reorder, not an exclusion.** Iteration 0 skips tqscore-exceeding masses and
  **iteration 1 back-fills them**, so it changes nothing unless the per-scan slot budget is contended.
  Two gates must both hold: `1 - ∏(1-qscore) > tqscore_threshold` (which needs *repeated* target-log
  observations — a single one peaks at `1-qscore`), and a saturated budget. `ms1_standard` satisfies
  neither, which is why `phase4_deep_mode.tsv` is row-identical to `phase4_standard_dda.tsv` and why
  `ContinuityTests.CT42` is `[Ignore]`d. To observe it, use a rich survey with a tiny cap, as
  `FLASHIda_LoggingFields_test::exclusion_mode2_tqscore_suppresses_target_mass` does
  (`ms1_ecoli_rich`, ≥9 selectable masses/scan, `max_targets: 1`).
  Orthogonal, config-flag-driven feature modes (all through the unified pipeline, not separate processors): MS2 sequence tagging, conditional MS2, isobaric quantification, targeted MS3 characterization. See `docs/kb/`.
- **What drives targeted MS3** — **one** knob now (ADR-0013), where there used to be three:
  - `characterization.mode` (`off | ambiguity | coverage | exhaustive`) is the whole gate *and* chooses the targets — each of the **three** on-values *is* an objective, one for one. Unknown values **throw**; the old `objective` key is gone. Reading a method, this single line answers "does this run MS3, and against what?". `exhaustive` (ADR-0023) is the newest and the odd one: its target pool is **every deconvolved mass of the winner MS2 scan**, not only the masses that matched the winning proteoform, so a mass with no ion identity is acquired and logged rather than matched. Its pool floor is `characterization.min_target_mass` (Da, `0` = off), a genuinely new filter — `deconvolution.min_mass`/`min_charge` do not reach MSn output.
  - `characterization.max_targets` is the MS3 budget and `.min_fragment_charge` the fragment-charge floor. Both are still **read off level 2** (`ProteoformTracker.cpp:354`, `Exploration.cpp:800`) — `Config::applyCharacterizationMode_` projects them there — but they are now *authored* where the feature is.
  - `ms_settings.ms3` supplies only the **scan parameters**. It is required when `mode != off` (otherwise `Exploration::initiateNextLevel` OOB-reads `scans[0]`) and permitted, though inert, when `mode == off`, so toggling MS3 off stays a one-word edit.
  - `characterization.exploration.metric` decides **how much MS3 costs and whether the sweep yields anything** (ADR-0020). `fragment_count` is a *reading* metric — it identifies every variant in order to score it. `remaining_precursor` and `mass_count` are *measuring* — they never match fragments, so at MS3 their pre-scans leave no evidence, and the engine closes such a sweep with one extra production MS3 at the winning CE. Budget it as `targets × (sweep points + 2)`, not `+1`. A measuring sweep that produced 66 MS3 scans and zero identifications is the defect ADR-0020 fixes; no committed config used a measuring metric at MS3, which is why CI never saw it.
  ⚠ **The projection must assign level 1 too.** `MSLevelConfig::selection` defaults to `None`, so an unassigned level 1 makes `FLASHIda.cpp:168` short-circuit every MS1 — the instrument acquires *nothing*, with no wrong value anywhere to notice. Pinned by `Config_SchemaProjection_test`.
- **Code style** — OpenMS uses clang-format (LLVM-based, 150 col, 2-space indent, Allman braces; `OpenMS/.clang-format`). FlashIDA follows standard C# conventions.

## Docs Map

- `docs/kb/` — the agent-facing knowledge base, imported above. Packet README first, then drill down. Entries carry `last_verified` + `code_anchors`; if the anchors don't resolve, the entry is stale — fix or remove it rather than relying on it.
- `docs/adr/` — accepted architecture decisions, **twenty-nine files** spanning 0001–0030 (0006 is used twice; 0022 and 0024 are unused; 0017 is superseded by 0019, and 0018 by 0021): direct-infusion precursor scope, ProteoformTracker dispatch authority, two-stage MS3 parameter sourcing, characterization config reshape, MS3-target-is-a-containing-fragment, single bridge config schema, winner-anchored fragment pooling, strict config-schema rejection, separate scan identity channels, scan-config-determines-instrument-parameters, positional stage arrays, source-region-parameters-are-survey-scoped, FAIMS-enablement-is-explicit, characterization-mode-is-the-single-MS3-switch, two-decision-sections-and-named-scan-configs, log-dir-is-resolved-host-side, co-isolated-charges-are-one-detection, notches-occupy-spare-stage-slots, charge-keyed-exclusion-is-a-fallback, notches-get-their-own-array-and-a-per-stage-cap, a-measuring-MS3-sweep-must-be-closed-by-a-follow-up, precursor-charges-is-the-only-acquisition-geometry, exhaustive-characterization-targets-unassigned-masses, the-drain-acquires-no-analysis-lock, a-remaining-precursor-sweep-scans-only-the-window-it-reads, identification-is-gated-by-the-sequence-not-the-MS3-switch, an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion, a-baseline-belongs-to-its-activation, activation-decides-whether-a-coupled-parameter-is-emitted. Read the relevant ADR before re-litigating one of these.
  ⚠️ **An exploration baseline is per swept ACTIVATION, not per group** (ADR-0029). It is that
  activation's own variant with the swept axis alone turned off — so an ETD baseline keeps
  `ms_settings.msN.collision_energy` — placed at the head of that activation's block, and *suppressed*
  when the block's sweep already contains its turn-off point (`ce_min: 0` / `reaction_time_min: 0.03`),
  which is what stops the same command being acquired twice.
  ⚠️ **The two coupled axes do not turn off at the same value.** CE 0 is commandable and simply does
  not fragment; **reaction time 0 is REJECTED by the instrument**, so "no reaction" is
  `Config.h`'s `MIN_REACTION_TIME_MS` (0.03 ms). The authored sweep *grid* is never floored — instead
  `Config::validate` throws on a `reaction_time_min` below it **when an ETD-family activation is
  swept**, which is what keeps the grid and the baseline able to coincide. Gated on the activation, so
  a CE-only sweep leaving `reaction_time_min` at its 0 default is untouched — that is every committed
  config but `method_exploration_etd.json`. An activation whose reference returns empty has
  its variants **acquired anyway** and scored `-1.0` so they cannot win; nothing is cancelled, and its
  siblings are unaffected. The `-1.0` is not decorative: winner selection seeds `best_score = -1.0` and
  takes `score > best_score`, so a `0.0` there **wins** the group at zero.
  ⚠️ **`reaction_time = 0` means two different things and only the ACTIVATION separates them**
  (ADR-0030). `ScanFactory` emits the `ReactionTime` key when any stage is ETD-family, never on the
  value — a value gate dropped the key entirely, so the instrument silently substituted its own method
  default (10 ms) while the engine logged 0. The reagent keys deliberately keep their `> 0` gate.
  `Config::validate` no longer throws on an authored zero for either coupled axis — so an
  `ms_settings` ETD block at `reaction_time: 0` loads and is refused *at the device*, on every scan of
  the run. Accepted gap, deliberately narrower than the sweep guard above; do not read
  `zero_on_a_coupled_axis_is_accepted` as an endorsement. The ETD-family
  set now has one definition per language; both are pinned as *exact sets*
  (`Config_SchemaProjection_test` ∥ `ScanFactoryTests`), because an over-broad predicate would start
  commanding a reaction time on scans that have none, invisibly.
  ⚠️ **0016–0019 are implemented.** Charge-state multiplexing is live for MS2 and MS3, defaulted off (`precursor_charges` / `fragment_charges` = `single`). Goldens exist for all 20 modes, including the three charge-mode ones (`multiplexed_ms2`, `multiplexed_ms3`, `separate_charges`).
  ⚠️ **`precursor_charges` is the ONLY source of acquisition geometry** (ADR-0021), and the story of how it wasn't is worth knowing because the shape recurs. `separate` was implemented *only* as a suppressed `break` over `charges_to_process` — a list that was multi-valued **only** under `charge_based_exclusion`, an unrelated exclusion-keying developer flag defaulting to off. So geometry was sourced from an exclusion flag, `separate` silently equalled `single` in every shipped config, and CI stayed green because the mode's one behavioural test configured that flag on. Both non-single modes now read the same `peakGroupNotchCandidates` + `selectNotches` pair (`NotchSelection.h`), which is what makes ADR-0016's "differ only in scan count" true rather than aspirational. `charge_based_exclusion` is **deleted**; exclusion is mass-keyed and a retired-key hint in `MethodConfigSerializer` names the replacement. Pinned by `FLASHIda_ChargeModes_test`.
  ⚠️ **The candidate loop must not expand per charge.** The mass-level bookkeeping above it runs once per species and both its guards key on `nominal_mass`, so a second pass `continue`s on every sibling charge. Fan-out happens at the emit loop *below* that bookkeeping — which is why "just populate the list" does not work.
  ⚠️ **0017 amends 0010's emit clause.** A per-stage array is now `num_stages` semicolon *groups*, each `1 + notch_count` comma-separated values — not `num_stages` values.
  ⚠️ **0019 supersedes 0017's layout and capacity** (the emit clause and the `num_stages`-never-counts-notches invariant stand). Notches live in a dedicated `Notch notches[18]` (24 B each) at @1464 with `pad4` @1460 and `reserved_` down to 152 — **not** in `stages[num_stages…]` — in fixed per-stage blocks capped at 9 each, so either stage of an MS3 can be a full 10-plex and the two never contend. There are **two different tens**: `MAX_ISOLATION_STAGES` is the `;`-axis cascade limit, `MAX_NOTCHES_PER_STAGE + 1` is `MSXTargets`' `,`-axis window limit per fragmentation stage. Notches rank by **intensity**; SNR is only the admission gate.
  ⚠️ **0011 amends 0007 and scopes 0009.** It reverses 0007's "trim four always-default emit-only keys" consequence, and narrows 0009's "never inherit from another scan" rule to analyzer-side parameters. Both older files carry a pointer at the amended text; don't cite them without it.
  ⚠️ **`0006` is used twice** — `0006-single-bridge-config-schema.md` (2026-07-13) and `0006-winner-anchored-fragment-pooling.md` (2026-07-09). Cite them by filename, never by bare number, until one is renumbered.
- `docs/superpowers/plans/` and `docs/superpowers/specs/` — approved designs, several of them **signed off but not yet implemented**; check here before assuming a described behaviour exists in the code. `specs/archive/` holds specs the Stop hook has retired.
- `CONTEXT.md` — domain glossary for the proteoform-tracking model (Precursor, nominal mass, representative charge, the detect-once/exclude-immediately rule). Conceptual, not a code reference.
### The three CLAUDE.md files are one doc set

| File | Scope |
|---|---|
| `CLAUDE.md` (this file) | The workspace: submodule wiring, the bridge/ABI contract, CI, testing, goldens, config flow. Authoritative when it conflicts with a submodule file. |
| `FlashIDA/CLAUDE.md` | C# side only — acquisition loop, component roles, P/Invoke wrapper, logging, test suite. |
| `OpenMS/CLAUDE.md` | C++ FLASH real-time engine only — `processScan`, queue, selection, characterization, and the FLASHDeconv/FLASHTnT no-go boundary. |

**Keep them in sync, and treat editing the submodule files as in-scope.** They live in
separate git repos, so a doc fix there is a separate commit inside `FlashIDA/` or `OpenMS/`
plus a gitlink bump in the parent — that friction is why they drift. When a change makes any
of the three wrong, update all three in the same run; do not leave a known-stale claim
standing on the grounds that it lives in a submodule. Each file should state facts that need
multiple files to discover, and avoid restating what the other two own.

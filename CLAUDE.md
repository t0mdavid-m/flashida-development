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
> ⚠️ **The idle path emits no AGC prescan, and `IsAgc` is NOT a drain sentinel** (ADR-0031). Step 5 used to fabricate a prescan as filler — and, because it also called `recordAGCTime()`, reset the very timer Step 1 reads, so `agc_interval_seconds` never governed the real cadence. Prescans now come from `agc_interval_seconds` alone (production default **1 s**; all 41 committed test configs pin it at `9999999` so goldens stay wall-clock independent). Priority 3 is the sentinel because `makeMS1()` sets it and every other caller overrides to 0 — MS2 is 2, MS3 is 1 — so a priority-3 MS1 *is* "Step 5 fabricated this". Pinned on both test paths — containers and CI: `FLASHIda_ProcessScan_test::only_the_idle_survey_is_emitted_at_priority_3` ∥ `IdleSurveySentinelTests`. A *scheduled* prescan can still arrive mid-drain; breaking on it truncates the drain.

**The load-bearing ABI contract is the `ScanCommand` struct: exactly 2048 bytes, embedding `IsolationStage stages[10]` at 80 bytes each.** C++ defines it in `.../TOPDOWN/FLASHIda/ScanCommand.h` (guarded by `static_assert(sizeof(ScanCommand)==2048)` and `static_assert(sizeof(IsolationStage)==80)`); C# mirrors it at the top of `FLASHIdaWrapper.cs` (`[StructLayout(Sequential, Pack=8, CharSet=Ansi)]` with a trailing `Reserved` byte block). **When adding a bridge field, carve bytes from `Reserved` — never change the 2048-byte total — and update both sides in lockstep.** Drift is caught by `ScanCommandLayout_test` (C++) and `ScanCommandLayoutTests` (C#), both run in CI **and in the containers** — the C++ one in either container, the C# one in the Windows container. A local run never leaves the 2048-byte ABI unguarded.

Four ADRs constrain what may cross this struct — read them before designing a bridge field: **0008** (a scan's handshake channel and identity channel are separate; never conflate them), **0009** (a scan config fully determines a scan's instrument parameters, as scoped by **0011**: source-region parameters are shared by the whole cycle and inherit the survey's value), **0010** (per-stage instrument arrays are positional; structural and optional parameters differ), **0012** (`faims_enabled` — the worked example of carving a field from `Reserved`: 600 → 596 bytes, total unchanged at 2048, no existing offset moved, both layout tests updated in the same push).

## Build

**Build and test locally in the two Docker containers; CI on push is the backstop.** The **Linux** container (gcc 13.3, every dep from apt, no contrib tarball) builds `libOpenMS.so` + the FLASH test exes and runs ctest — the fast inner loop; it cannot produce `OpenMS.dll` and is **never** authoritative for a number or a golden. The **Windows** container reproduces the CI toolchain (MSVC 14.44 + Qt 6.8.3 + the pinned contrib tarball) to produce a real `OpenMS.dll` and runs the whole C# side. **Build often.** See `## Local verification (two containers)` below for the images, the `ci` dispatcher and the exit-code contract.

**The containers verify your working tree, dirty; CI verifies a commit from a clean recursive checkout** — "green containers" is never "green at this SHA". `.github/workflows/flashida-ci.yml` is **unchanged** and still runs on push to `main`, `develop`, `flashida-v9-migration`, `phase-*`, `august_pre` **and on `pull_request`** to `main`/`develop`/`flashida-v9-migration`. It remains the only verifier of the clean checkout, the `cpp-test-build` tarball round trip, the `openms-fresh-dll` bundle layout, cold-cache compilation, and MSVC-vs-goldens. Land a push once the containers are green — and still watch the run.

### FlashIDA (C# / .NET Framework 4.8, C# 7.3, x64, Windows only)
```
nuget restore FlashIDA/src/Flash.sln
msbuild       FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /m
```
Solution is at `FlashIDA/src/Flash.sln`. Projects: `Flash` → `Flash.exe`, `Flash.Tests` → `Flash.Tests.dll`; both output to `FlashIDA/bin/`. `PlatformTarget` is x64 despite the `Any CPU` switch.

DLL dependencies:
- **OpenMS runtime DLLs** are committed in the FlashIDA submodule at `FlashIDA/dll/` (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`, `zlib.dll`) and copied to `bin/` by MSBuild (`CopyToOutputDirectory`). To update them for local runs, rebuild OpenMS and commit the DLLs into `FlashIDA/dll/`.
  **In CI the committed DLLs are overwritten before the C# build**: the `build` job uploads a freshly compiled `OpenMS.dll`/`OpenSwathAlgo.dll`/`Qt6*.dll` as artifact `openms-fresh-dll`, and `windows-tests` copies them over `FlashIDA/dll/` (only `zlib.dll` stays committed). That is deliberate bridge/ABI drift detection — the C# suite always runs against the OpenMS submodule SHA, not the committed binary. It also means **every CI run links a different `OpenMS.dll`**, so floating-point score columns jitter run-to-run; golden comparison is tolerance-based for floats and exact for ints/strings/structure.
- **Thermo iAPI DLLs** are proprietary and **not** committed: `FlashIDA/dependencies/` holds only XML doc stubs plus `thermo-dlls.zip.enc` (openssl AES-256). CI decrypts it with secret `THERMO_DLL_PASSPHRASE` and copies the DLLs into `bin/`.
  The Windows container consumes the same five DLLs CI does. **Decrypt on the HOST** — `openssl enc -aes-256-cbc -d -pbkdf2 -in FlashIDA/dependencies/thermo-dlls.zip.enc -pass env:THERMO_DLL_PASSPHRASE` into `FlashIDA/dependencies/` (gitignored) — and let the bind mount carry them. **Never a Dockerfile `ARG`/`ENV`**, which bakes the passphrase into a recoverable image layer. They are **host state**: `ci clean` never touches them, and on a fresh clone `ci doctor` reports them absent as a hard **FAILURE**, not a skip. `Thermo.TNG.Client.API.dll` is **not** on the public Thermo repo (it ships with Tune) and is a compile-time dependency of *both* projects, so the encrypted zip is the only complete source. The image is never pushed to any registry. (Background: `FlashIDA/Installation.md`.)

### OpenMS (C++20 / CMake) — build it in the Linux container; it is the fast loop
`ci cpp` configures and builds it there and runs the FLASH ctests; `ci dll` builds the MSVC `OpenMS.dll` in the Windows container. Neither needs a flag or a permission — the resource cost that made this "do not build" is now the container's, and the fast tier answers in seconds.

CI builds on **`windows-2022`** (all three jobs do) with the MSVC toolchain via a Visual Studio shell, `choco install ninja cmake ccache 7zip eigen`, `install-qt-action` (Qt 6.8.3), and a **prebuilt contrib tarball** downloaded from the `OpenMS/contrib` releases (`submodules: true`, *not* recursive, so OpenMS's nested `contrib` stays empty for the tarball to extract into) — **not** apt and **not** vcpkg. The pipeline is one `build` job (compiles OpenMS once + packages the build tree as artifact `cpp-test-build`) feeding two parallel test jobs: `windows-tests` (C# / NUnit / regression) ∥ `cpp-tests` (ctest).

The configure flags, the build `--target` list, the `ctest -R` alternation and the pinned tool versions are **not reproduced here**. Both containers and CI read them out of `.github/workflows/flashida-ci.yml` — there is exactly one copy, and `docker/ci-lists.sh` is the only thing that parses it. **Any such list you find written out in prose is stale by construction** (the copy that used to sit here said 23 targets against the yml's 26, and had the `WITH_GUI` flag backwards). The yml's **own prose comments are historical too** — they say "25" and "13" where the `--target` block says 26; only its `--target` block, its `-R` line and its version pins are authoritative. `ci lists` prints what the parser actually sees.

Two consequences of the **Release** build (CI's, and both containers' default): `OPENMS_PRECONDITION` and debug asserts are **compiled out** (accepted tradeoff — it matches the production toolchain), and test exes land in `<build>/src/tests/class_tests/bin/` (the class-test `RUNTIME_OUTPUT_DIRECTORY` override), **not** `<build>/bin/` (library output). Running one on **Windows** needs the 5-DLL set staged beside it, including `zlib.dll` — `OpenMS.dll`'s own load-time dep; without it you get `0xc0000135 STATUS_DLL_NOT_FOUND`. That staging is Windows-only; the Linux container resolves `libOpenMS.so` through the build tree's rpath. Do **not** pass `ENABLE_CLASS_TESTING=OFF`, and never set `ENABLE_STYLE_TESTING` — it is either/or with `class_tests`, so ON makes the whole FLASH suite silently vanish.

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
- **Regression + golden** — `powershell FlashIDA\test-scripts\regression-runner.ps1 -FlashExe FlashIDA\bin\Flash.exe -TestDataDir FlashIDA\test-data -OutputDir FlashIDA\test-output [-captureMode]`. Iterates 14 mode cases and diffs TSV output against `FlashIDA/test-data/golden/*.tsv` via `python FlashIDA/test-scripts/compare_golden.py` (`-captureMode` regenerates goldens; needs Python on PATH) — which is a **container-provisioning requirement**: on this host `python`/`py` are Microsoft Store stubs, so `compare_golden.py` runs only inside the Windows container. `-captureMode` writes only to its own `-OutputDir`; **the non-capture pass WIPES `FlashIDA/test-output` first**, so anything under it must be captured before that pass runs.

**`windows-tests` runs FOUR non-test gates that can fail an otherwise-green suite** — not three; the fourth was missing from this file. All four are deliberately fail-closed — a missing input file is a failure, not a skip — and the Windows container runs all four, in CI's order:
- *Verify bridge smoke tests* — re-parses `TestResults.xml` and requires **at least one** `BridgeSmokeTests` case with every match `Passed`. Renaming or category-filtering that class breaks CI even though nothing regressed; `Skipped`/`Inconclusive` count as failures.
- *Verify TRACK-CREATE entries* — greps `FlashIDA/test-output/regression-stdout.txt` for `[TRACK-CREATE]`; **zero entries fails**. (Skipped only when the regression step itself didn't run.)
- *Verify test data directories* — requires `FlashIDA/test-data/configs/method_default.json` and `method_json_roundtrip.json` to exist.
- *Verify JSON golden capture* (`flashida-ci.yml:442-457`) — exits 1 if `FlashIDA/test-output/json/config_default.json` or `config_full.json` is missing. Those are written only by `GoldenCaptureTests` during the ordinary suite, so a filtered run cannot satisfy this gate — one reason a filtered `ci cs` reports `PARTIAL` and exits non-zero.

### Goldens — three separate sets, recapture each on its own path
A behaviour change usually moves more than one set. Know which you touched:

| Set | Location | How to recapture |
|---|---|---|
| Log goldens (largest surface) | `FlashIDA/test-data/golden/logs/<mode>/<stream>.golden.tsv` — **25 modes × 5 streams = 125 files** | Run `FLASHIdaLogGolden_test` in the Windows container and take the `.normalized` files it **always** writes to `FlashIDA/bin/log-golden-output/<case>/` — byte-identical to a capture. The container therefore **never sets `LOG_GOLDEN_CAPTURE`** and never writes into the golden tree. Promoting CI artifact `log-golden-capture` remains a fallback. **Assert 25 case dirs × 5 non-empty `.normalized` files before promoting** — the capture guard does not cover this path; see below. |
| Regression TSVs (13) | `FlashIDA/test-data/golden/phase4_*.tsv`, `baseline_*.tsv` | `regression-runner.ps1 -captureMode` stages into its own `-OutputDir` — but **prefer the CI artifact `phase4-golden-capture` for this set**: `compare_golden.py` uses `REL_TOL=1e-4`, ten times tighter than the C# comparer, leaving only ~2.6× headroom over the worst observed cross-build drift. **That artifact carries only the 10 `phase4_*` cases** — `flashida-ci.yml:437-439` uploads `phase4-golden/phase4_*.tsv` and the runner names each output after its *case*, so `baseline_phase0.tsv`, `baseline_phase3.tsv` and `phase7_exploration.tsv` are not in it |
| Continuity JSONs (17) | `FlashIDA/test-data/golden/continuity_*.json` | `ContinuityTests.AssertGolden` always stages to `FlashIDA/bin/continuity-output/` and never touches the golden dir; CI artifact `continuity-golden-capture` is the fallback |

The five `<stream>` basenames are fixed **in the engine** (`IdaLogger`'s `k*Name` constants,
mirrored by `LogGoldenComparer.FileNames`); only their location is configurable, via the single
`runtime.log_dir` key. Renaming one is a golden-moving change on both sides.

⚠️ **The all-five-streams guard does NOT protect the `.normalized` promotion path above.** A
`LOG_GOLDEN_CAPTURE=1` run refuses to write when the engine did not produce all five streams — it
performs no comparison at all, and a missing file normalizes to `""`, so an unguarded capture over a
mislocated run would blank the goldens and pass. But that refusal lives *inside* the `if (Capture)`
branch of `FLASHIdaLogGolden_test`, while `WriteNormalized` runs **unconditionally, ahead of it** — so
the container path the table recommends carries no such check. Thirteen of the cases additionally
`Assert.Pass` when their fixtures are absent, so a fully green run can leave a case directory short a
stream. **Assert 25 case directories × 5 non-empty `.normalized` files yourself before promoting any
of them.**

The 5 log streams per mode are `ida.log`, `scan_commands.tsv`, `scan_results.tsv`, `identification.tsv`, `pooled_identification.tsv` — each has a distinct role (command detail / pure event / per-ID + coverage / cumulative). Golden comparison matches columns **by header name**, so reordering log columns needs no recapture; adding, removing, or changing a value does. Column inventory: `LOG_COLUMN_ORDER_REFERENCE.md`.

**Writing a golden is gated by a repo hook, not just by judgement.** `.claude/settings.json` wires six hooks that fire on every session in this repo:

| Event | Matcher | Hook | Effect |
|---|---|---|---|
| PreToolUse | `Edit\|Write\|Bash` | `golden-write-guard.sh` | **Can deny the call** — a blocked golden write is the gate working, not a tooling bug |
| PreToolUse | `Edit\|Write` | `log-impact-reminder.sh`, `driver-sync-reminder.sh`, `config-schema-drift-reminder.sh` | Advisory: flags edits that move log output, drive sites, or the config schema |
| PostToolUse | `Edit\|Write\|Bash` | `golden-change-detector.sh` | Reports goldens the turn touched |
| Stop | — | `archive-implemented-specs.sh` | Moves implemented specs into `docs/superpowers/specs/archive/` |

If `golden-write-guard.sh` blocks a write, surface the golden diff and get sign-off rather than routing around the hook.

⚠️ **Neither the containers nor the CI artifacts bypass the sign-off gate, and the hook cannot enforce it alone.** A PreToolUse hook only ever sees *this agent's* tool calls — it is blind to the same command typed in the owner's own terminal, and it was blind to a `docker run` that names the golden directory. So promotion is deliberately a bare host-side `cp`, per moved cell, **after the owner has seen the diff in cells**; there is no `ci` promote subcommand, because a wrapper is the one command shape the guard does not gate. What actually holds regardless of who typed it is mechanical: the containers never write into `FlashIDA/test-data/golden` (they stage), and every `ci` subcommand ends with an unconditional `git -C FlashIDA status --porcelain -uall -- test-data` assertion that has no bypass flag. **A green CI run on the push carrying the golden is the acceptance test for every local capture.**

### OpenMS (C++ ctest) — active FLASH targets are in `OpenMS/src/tests/class_tests/openms/executables.cmake`
```bash
# the whole FLASH suite, locally (the -R string comes from the yml, never from here)
ci cpp --full
# the fast tier — everything under the slow threshold, ~5 s
ci cpp
# one test, by name
ci cpp FLASHIdaFAIMS_test
# or, from inside the container that built it, straight at that lane's build dir:
ctest --test-dir <build> -R FLASHIdaFAIMS --output-on-failure
```
**A C++ test runs ANYWHERE — CI or either container — only if it is added in BOTH places** in `.github/workflows/flashida-ci.yml`: the build `--target` list AND the `ctest -R` alternation, in that same file — **and then you run `ci lists` and confirm the parser sees it**. The containers parse those same two lists, so registering it in `executables.cmake` alone still gets you nothing (it compiles but never executes, or does not even build), and a missed registration now costs a local run as well as a CI run. There is no `-E` exclusion; **the `-R` alternation is the whole active set**, and its branches are *unanchored regex searches* — `FLASHIda_Logging` also matches `FLASHIda_LoggingFields_test`, which is why the branch count is legitimately lower than the target count and why a parser that treats a branch as a name silently drops tests. `ctest -R FLASH` alone is **insufficient**: the majority of the active set does not start with `FLASH`.

C++ tests read fixtures from `../../FlashIDA/test-data` **relative to the build directory** (`add_test(… WORKING_DIRECTORY ${CMAKE_BINARY_DIR})`), so the build dir must sit directly under `OpenMS/` with `FlashIDA/` beside it — that is why the container build dirs are `OpenMS/cmake-build-*` and why the FlashIDA submodule must be checked out to run them.

## Local verification (two containers)

Everything in this section is parent-repo tooling: the images and their entrypoints under `docker/`, the `ci` dispatcher (bash, Git Bash) and its `ci.ps1` shim at the root. **No container file lives in either submodule**, and `.github/workflows/flashida-ci.yml` is untouched by it. `docker/README.md` carries the operational detail — the calibration record, the documented divergences from CI, and the trust-revocation rule.

**One-time host prerequisites.** `ci doctor` verifies each one and names the fix in the failure message; it never reports a missing prerequisite as a skip:

| Prerequisite | Why | Check |
|---|---|---|
| Windows `Containers` optional feature enabled, then a **reboot** | Ships `cexecsvc` and `C:\ProgramData\Docker`; Docker Desktop does not self-enable it | elevated `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All` |
| Docker Desktop, both engines reachable | The two legs run on different daemons | `ci doctor` prints engine mode + isolation |
| Thermo DLLs decrypted into `FlashIDA/dependencies/` | The C# build cannot start without them | **absent = hard FAIL**, never a skip |
| `THERMO_DLL_PASSPHRASE` in the environment only | Never in a committed file, an image layer, or a log line | supplied at run time, never echoed |

**The two images.**

| | Linux | Windows |
|---|---|---|
| Base | `ubuntu:24.04` (digest-pinned), gcc 13.3, every dep from apt | `mcr.microsoft.com/dotnet/framework/sdk:4.8-…-windowsservercore-ltsc2022` + VS BuildTools 17.14.39 (MSVC 14.44.35207) + Win SDK 10.0.26100 + Qt 6.8.3 + the pinned contrib tarball. **These four numbers are a convenience copy, not the source** — the authoritative pins are parsed out of the yml (`docker/ci-lists.sh pins`) and the image build fails if a Dockerfile pin disagrees |
| Produces | `libOpenMS.so` + the FLASH test exes | a real `OpenMS.dll`, swapped into `FlashIDA/dll/` exactly as CI does |
| Runs | the FLASH ctests | ctest on demand, then nuget → msbuild → the **unfiltered** NUnit suite → the 14-case regression runner → all four fail-closed gates |
| Cost | ~5 s fast tier, ~23–35 min full | ~25–50 min — a pre-push gate, not an inner loop |
| Deps | no contrib tarball, no Qt install action | the tarball at its pinned tag, extracted to `C:\contrib` — **never** into `OpenMS/contrib`, which on a local clone holds the contrib SOURCE tree (CI leaves that submodule unchecked-out and extracts the tarball there instead -- see the CI note above; extracting over a populated source tree breaks find_package) |

The Windows image configures `WITH_GUI=OFF` where CI uses `ON`, so **the `OpenMS.dll` your local bridge/ABI check runs against comes from a differently-configured library build than CI's.** `WITH_GUI` gates GUI targets rather than `OpenMS`'s own sources, so a behavioural difference is not expected — but "not expected" is not "asserted". `ci doctor --compare-ci` prints both DLL sha256 and both configure lines side by side; it is informational, never a gate (CI links a different DLL every run by construction). If a golden ever disagrees between container and CI, re-run the container leg once with `--with-gui` before blaming the code.

**Authority boundary — a green Linux run is the easiest thing in this system to over-trust:**

| Question | Linux | Windows | GitHub CI |
|---|---|---|---|
| Does it compile under gcc? | **authoritative** | no | no |
| Does it compile under MSVC? | no | strong | **authoritative** |
| Does the C++ logic behave? | strong | strong | authoritative |
| Is `sizeof(ScanCommand)==2048` still true? | yes | yes | yes |
| Does the C#↔C++ P/Invoke round-trip work? | **impossible** | **authoritative locally** | authoritative |
| Is this float value right? | **never** | strong | **authoritative** |
| May this golden be committed? | **never** | may CAPTURE, never PROMOTE | **must confirm after promotion** |

Why Linux may never adjudicate a number: `compiler_flags.cmake` gives MSVC `/arch:AVX` (256-bit) and non-MSVC `-mssse3` (128-bit) as PUBLIC options on every target, and different vector width changes FP reduction order — `-ffp-contract=off` does not touch that. Reassuringly, **no C++ ctest reads a golden file**, so cross-toolchain drift can produce Linux ctest noise but can never corrupt a golden. Treat a Linux-only ranking disagreement as a **lead**, not a verdict.

**Working tree vs commit.** The containers verify the tree as it sits, dirty. CI verifies a commit, from a clean recursive checkout. **"Green containers" therefore means "green with my uncommitted edits on this machine", never "green at this SHA".**

**What stays exclusively remote** — named here so nobody discovers a hole later:
- the **`pull_request` trigger** (`main`/`develop`/`flashida-v9-migration`). No container reproduces a merge gate.
- the **`cpp-test-build` round trip** — CI runs ctest against a *packaged, uploaded, downloaded and unpacked* build tree with the runtime DLLs staged beside the exes; the containers run it in a live build dir.
- the **`openms-fresh-dll` bundle assertions** — `CHEMISTRY/unimod.xml`, `qt.conf`, `platforms/qwindows.dll`, the 7-DLL Qt closure.
- **cold-cache compilation** — CI is at `CCACHE_MAXSIZE=400M` (effectively near-cold), the containers at 30G (always warm). "This tree compiles from scratch" is only ever proven on GitHub.
- **MSVC as the goldens oracle**, and the FLASHDeconvWizard delivery.

**The command surface.** One dispatcher; every C++ entry point runs the parser self-test as its first step.

| Command | Engine | Cost | What it does |
|---|---|---|---|
| `ci doctor` | — | s | prerequisites, images, Thermo DLL identity gate, `git status` across all three repos, locale, ccache size, disk footprint |
| `ci lists` | — | ms | parser self-test + reconciliation against `executables.cmake` |
| `ci cpp <name…>` | Linux | s–min | build + run only those targets — **the real inner loop** |
| `ci cpp` | Linux | ~5 s | fast tier: the parsed set minus anything over `--slow-threshold` (2 s) in the last run's JUnit timings |
| `ci cpp --full` | Linux | ~23–35 min | all of them, `-j 6`, `OMP_NUM_THREADS=1` |
| `ci cpp --debug` | Linux | slower | separate build dir; the only Linux configuration ever proven green |
| `ci cpp --msvc <name…>` | Windows | min | **targeted triage only** — there is deliberately no `--msvc --full` |
| `ci dll` | Windows | 20–30 min cold / ~1 min warm | build `OpenMS.dll`, swap the 4, assert provenance |
| `ci cs [filter]` | Windows | ~28 min | `ci dll` + restore + msbuild + **unfiltered** NUnit + all four gates + regression + cleanup. A *filter* forces `PARTIAL` |
| `ci golden-diff` | Windows | ~28 min | full compare, cell-level diffs, **read-only**; prints the exact `cp` lines for the cells that moved |
| `ci all [--resume]` | both | ~1 h | Linux first, Windows last; exits with the worst of the two. If only one engine is reachable it writes phase state, says so, and exits **non-zero** — `--resume` completes the run and only then can the aggregate pass |
| `ci clean` | — | s | wipe build dirs, `bin/`, `test-output/`; restore `FlashIDA/dll/`; delete the stray root files. **Never touches `FlashIDA/dependencies/`** |

The slow set is **derived, not committed** — from the previous run's `--output-junit` timings. With no prior run the fast tier falls back to full and says so. A hand-maintained second list is exactly what the parser exists to prevent.

**The exit-code and verdict contract, for the whole tool.** Every subcommand exits **0 only if every gate it ran passed**; there is no `|| true` anywhere. Every subcommand's **last line** is one of exactly three verdicts — `PASS: <what was verified>`, `FAIL: <first failing gate>`, or `PARTIAL: <what did not run> — NOT CI-EQUIVALENT` — so a human reading only the last line is never misled. **`PARTIAL` always exits non-zero**: a filtered `ci cs` cannot satisfy the bridge-smoke, TRACK-CREATE or JSON-capture gates, so it reports PARTIAL and writes its `TestResults.xml` somewhere the gate cannot read it. `ci all` exits with the worst of its two legs. Run `ci` with no arguments for the exit-code table — it is the authority, not this file.

**Defaults, and the one exception.** C++ is **Release** by default, matching CI; `--debug` selects a *separate* build dir rather than reconfiguring the Release one. **C# is always `Debug` / `Any CPU` and there is no flag for it** — both values are load-bearing (`Release|AnyCPU` sends `Flash.exe` to `src/Flash/bin/Release/` while `Flash.Tests.dll` stays in `FlashIDA/bin/`; `Debug|x64` redirects to `bin\x64\Debug\`), so the Release default applies to C++ only.

**The workflow file is parsed, never copied.** `docker/ci-lists.sh` is the single reader of `flashida-ci.yml`, and it is fail-closed: it exits non-zero if the file is absent, if it does not contain **exactly one** `ctest … -R "…"` invocation, if zero branches parse, or if the target count falls below the floor — then reconciles targets against branches by substring relation and cross-checks `executables.cmake`. An empty `-R` is version-dependent and silently green on some ctest builds, which is why "zero branches" is a hard error rather than a warning. Of the toolchain pins, only Qt's three (`qt_version`, `qt_arch`, `qt_archives`) are in the yml at all; they are parsed the same way and the Windows image build **fails** if a Dockerfile literal disagrees. The contrib tag, VC toolset, Win SDK and VS build version are **not in the yml** — CI takes an untagged `gh release download` and gets MSVC from the runner image on a floating channel — so those are Dockerfile `ARG`s asserted against reality at build time (tarball byte count, `cl.exe` version), not against a parsed value. `docker/ci-lists.sh pins` reports each absent pin and why. **Do not write a second parser** — the PowerShell shim calls the same sh script.

**The container must be en-US, and it asserts the pin before running anything.** `MockMsScan` parses every spectrum fixture value with a bare, culture-sensitive `double.Parse`, and `FromTsv`/`FromTsvAsMS2`/`FromTsvAsMSn` feed the whole golden and continuity suite. Under `de-DE` — this host's locale — `double.Parse("674.6919")` returns **6746919**.

**Bridge/ABI drift detection is emergent in CI and asserted locally.** CI gets it from a fresh checkout + `needs: build` + a one-shot filesystem; all three vanish locally, so the Windows leg runs a three-part provenance gate before NUnit — `sha256(FlashIDA/bin/OpenMS.dll)` equals the freshly built one, the DLL in `bin/` **differs** from the committed `dll/OpenMS.dll`, and its mtime is newer than the newest file under `OpenMS/src/openms/{source,include}/`. The first catches `PreserveNewest` skipping a copy (`Copy-Item -Force` preserves the *source* mtime, so a fresh DLL can be older than a stale `bin/` one), the second catches testing the known-stale committed binary, the third catches "edited the engine, forgot to rebuild" — locally the default failure mode, in CI unreachable.

**Tree hygiene — the containers write into this tree, and several of those writes are invisible unless the runner cleans up.** `FlashIDA/dll/` is **tracked** (6 files) and the Windows leg modifies 4 of them, so every run restores them in a `finally` and asserts the restore; there is no opt-out flag. `regression-runner.ps1` drops `test_inclusion_list.txt`, `test_fasta.fasta` and `test_target_log.log` into the *current working directory*, and `TestResults.xml`/`RegenResults.xml` land at the repo root — all deleted in the same `finally`. Build directories are `OpenMS/cmake-build-{linux,msvc}-{release,debug}`, already covered by `OpenMS/.gitignore`; **never reuse `OpenMS/build`**, which is reserved for a CI-shaped tree — reusing it lets a container build masquerade as a CI one. Keeping `git status` clean is not cosmetic: it is the layer that survives a human typing the command in their own terminal.

Two line-ending facts, both load-bearing on Linux only. The root `.gitattributes` pins the shell and awk files, everything under `docker/`, and the `ci` dispatcher itself to LF — `core.autocrlf=true` otherwise produces `bad interpreter: /bin/bash^M`. It deliberately carries no repo-wide `* text=auto`, and it has no authority over either submodule. And `FlashIDA/.gitattributes` forces **CRLF into the working tree on every platform**; a Windows text-mode `ifstream` strips the `\r`, a Linux one does not, so a fixture-reading test can fail under gcc for that reason alone. **Do not "fix" that by normalising fixtures to LF** — it changes what CI and the Windows container see.

**// DEFECT-IN-WAITING: MSBuild and NuGet walk UP past the submodule boundary.** There is no `Directory.Build.props`, `Directory.Packages.props`, `nuget.config` or root `.editorconfig` at the parent root or above it today, and **none may ever be created at either level** — one would silently reconfigure the C# build for CI and the container alike. Relatedly, the parent `.gitignore` contains a bare `CLAUDE.md` line, which matches at **any** depth: never name a file `docker/CLAUDE.md`.

**Operating the two engines.** Address them by their stable named pipes (`npipe:////./pipe/dockerDesktopLinuxEngine`, `…WindowsEngine`), never by `docker context use` — Docker Desktop re-points the generic pipe on switch. Never call `docker desktop engine use` from tooling: it stops the other daemon and kills every running container. Never `docker system prune` from tooling — pruning images and volumes is the user's call, which is why `ci doctor` prints the footprint. From Git Bash, `MSYS_NO_PATHCONV=1` is required or container paths are rewritten to drive letters. A second Claude session shares this workspace, so `git pull --rebase` in all three repos before each push and check the `Claude-Session:` trailer on anything unexpected.

**Green containers before you push — and CI is still the acceptance test.** The expected numbers are the calibration anchor recorded in `docker/README.md`: C# `total=181 passed=180 failed=0 skipped=1` (the skip is `ContinuityTests.P4_AL_CT42_DeepMode_TargetLogEffect`) and ctest 26/26. When a container and CI disagree, the written rule is in `docker/README.md` — in outline: a float-only CI red means the container's DLL is a different binary (discard the local capture, promote the CI artifact, carry on); a **structural** CI red means stop capturing goldens locally until a fresh calibration against a new green run reproduces both numbers exactly; and container-red/CI-green means the container is wrong — fix the container, never edit a test to make it agree.

## Key Development Concerns

- **Cross-project bridge changes** — keep the 5 exports and the 2048-byte `ScanCommand` struct in sync across `FLASHIdaBridgeFunctions.{h,cpp}` and `FLASHIdaWrapper.cs` (see *How the Projects Connect*), and run the layout tests on both sides.
- **FLASH code location** — headers under `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/`, sources under `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/` (the `source` tree has **no** `OpenMS/` segment — `source/OpenMS/…` does not exist). `FLASHIda.cpp` (real-time IDA driver; its `processScan` runs deconvolution + precursor selection) and `FLASHIdaBridgeFunctions.cpp` sit directly under `TOPDOWN/`; the 13 runtime helpers live in the nested `TOPDOWN/FLASHIda/` subdirectory: `Config`, `Deconvolution`, `Exploration`, `FAIMS`, `FragmentAnalysis`, `IdaLogger`, `MS3FragmentMatcher`, `Ms2Params`, `PrecursorSelection`, `ProteoformTracker`, `Quantification`, `ScanCommand`, `ScanCommandQueue`. See `OpenMS/CLAUDE.md` for what each owns.
- **Scan processing is unified** — `UnifiedScanProcessor` is the *sole* production `IScanProcessor` (single `void ProcessMS(ScanData)`); all MS levels route through `FLASHIdaWrapper.ProcessScan` → C++ `processScan`, and commands are drained separately via `GetNextScanCommand` in `Flash.cs`. (`ScanScheduler.cs`, `FAIMSScanProcessor.cs`, `IDAScanProcessor.cs`, and `QuantScanProcessor.cs` do **not** exist.)
  - **`ProcessMS` takes an owned snapshot, not an `IMsScan`.** `DataPipe.Push` copies the seven values the engine needs (`ScanData.From`) on the *arrival* thread, while the handle is still live, and queues that. (Seven since ADR-0035 added the instrument scan number; anything an eighth is needed for is added *there*, never read lazily at the consumer.) An `IMsScan` is a window onto framework-owned memory the iAPI frees once its `LastScan` advances, so a queued handle is only safe while the queue stays ~1 deep — which it was purely because the command drain blocked behind the deconvolution. The signature is pinned by `InterfaceShapeTests`, and `ContinuityTestHarness` (which produces the log goldens) must convert through the *same* `ScanData.From`, or the goldens encode the harness's reading of a scan rather than the engine's.
- **Method configuration is JSON** — `FlashIDA/src/Flash/etc/method.json` (**not** XML). Top-level sections map to `[JsonKey]` classes in `FlashIDA/src/Flash/MethodConfig.cs` (note: directly under `src/Flash/`, there is no `Configuration/` directory): `global`, `deconvolution`, `precursor_selection`, `flashtnt`, `tagging`, `quantification`, `faims`, `ms_settings`, `scheduling`, `characterization`, `files`, `runtime`, plus a synthetic `developer` section into which `[Developer]`-marked fields are routed. Loading is reflection-driven (`FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs`); FlashIDA then re-serializes to a *different* C++-facing schema via `MethodParameters.ToCppJson()` before crossing the bridge. See `docs/kb/config-flow/`.
  - **`selection_strategy` no longer exists** (ADR-0014). Selectivity lives in two decision sections and scan parameters stay in `ms_settings`: `precursor_selection` answers *which species do we fragment* (`rank_by`, `max_precursors`, `min_precursor_charge`, `precursor_charges`, `additional_scans`, `exploration`, `tag_expansion`), `characterization` answers *whether and how we characterize* (`mode`, `protein_sequence`, `max_targets`, `min_fragment_charge`, `fragment_charges`, `exploration`).
  - **Charge-state co-isolation** (ADR‑0016) is `precursor_selection.precursor_charges` and `characterization.fragment_charges`, both `single | separate | multiplexed`, both defaulting to `single`. `multiplexed` co-isolates a species' SNR-positive charge states as **notches** in one scan; because every notch is the same neutral mass the spectrum is not chimeric, which is why no part of the 1-scan-1-precursor identity model changed. `fragment_charges` **replaces the bool `ms3_all_charges`** (`false`→`single`, `true`→`separate`); the old key throws a migration error.
  - **To pick SPECIFIC charge states the knob is the inclusion list, not `precursor_charges`** (ADR-0028). `precursor_charges` is all-or-one; an **authored charge set** in the inclusion TSV's charge column names which ones: `10;13;16`, `;`-separated (not `,` — a comma-decimal locale writes `12351,3`), with `-1`/empty meaning unrestricted. It **restricts and never extends** — a named charge still has to clear the SNR gate to be co-isolated, and one the survey never resolved is skipped outright because isolation geometry must be measured. The anchor becomes the highest-SNR named charge (overriding `consider_all_charges`), the logged qscore becomes that charge's own, and exclusion is re-keyed to `(nominal mass, charge)` **for those species only** — which is what lets `single` walk the set across successive surveys instead of retiring the mass on its first acquisition. Rows naming the same mass and active at the same RT **union** their sets, so one row `10;13;16` equals three rows `10`/`13`/`16`. Emits `[CHARGE-SET]`; pinned by `FLASHIda_ChargeModes_test` CM-04..CM-08.
  ⚠️ **The budget counts species/fragments in all three modes.** `separate` (N scans) and `multiplexed` (1 scan) both acquire one species' whole envelope for **one** `max_precursors` / `max_targets` slot — they differ only in scan count, never in how much budget a species buys. Counting acquisitions instead is the pathology the modes exist to avoid: it makes `max_targets: 3` spend everything on the first fragment that happens to have three charges. Enforced by a species/fragment counter in `PrecursorSelection` and `planNextScans`, not by `selected_peak_groups_.size()`. `ms1`/`ms2`/`ms3` now appear only under `ms_settings`, all three as **bare objects**; extra MS2 configs go in `ms_settings.additional_ms2` as a name→object map and reach the dispatch roster only by being referenced. `cycle_time` and `scan_timeout` nest under `scheduling`, alongside `agc_interval_seconds` and `target_depth` (ADR-0033) — the last is the one `scheduling` key the **engine parses and ignores**, because it sizes the instrument's queue and only `Flash.cs` can do that.
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
- `docs/adr/` — accepted architecture decisions, **thirty-seven files** spanning 0001–0038 (0006 is used twice; 0022 and 0024 are unused; 0017 is superseded by 0019, 0018 by 0021, 0032's submission threshold is amended by 0033, 0008's two-channel model is extended by 0035, 0028's per-survey species guard plus 0016's one-scan clause are amended by 0036, **0037 is withdrawn**, and 0014's name-reference rule is taken the other way for one case by 0038): direct-infusion precursor scope, ProteoformTracker dispatch authority, two-stage MS3 parameter sourcing, characterization config reshape, MS3-target-is-a-containing-fragment, single bridge config schema, winner-anchored fragment pooling, strict config-schema rejection, separate scan identity channels, scan-config-determines-instrument-parameters, positional stage arrays, source-region-parameters-are-survey-scoped, FAIMS-enablement-is-explicit, characterization-mode-is-the-single-MS3-switch, two-decision-sections-and-named-scan-configs, log-dir-is-resolved-host-side, co-isolated-charges-are-one-detection, notches-occupy-spare-stage-slots, charge-keyed-exclusion-is-a-fallback, notches-get-their-own-array-and-a-per-stage-cap, a-measuring-MS3-sweep-must-be-closed-by-a-follow-up, precursor-charges-is-the-only-acquisition-geometry, exhaustive-characterization-targets-unassigned-masses, the-drain-acquires-no-analysis-lock, a-remaining-precursor-sweep-scans-only-the-window-it-reads, identification-is-gated-by-the-sequence-not-the-MS3-switch, an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion, a-baseline-belongs-to-its-activation, activation-decides-whether-a-coupled-parameter-is-emitted, agc-prescans-are-interval-scheduled-only, only-a-commanded-scan-earns-a-command, an-idle-instrument-acquires-its-own-method, flashdeconv-targets-the-toppic-1-8-feature-layout, ida-log-is-compatible-with-its-consumer-not-its-history, a-split-envelope-is-one-precursor-acquired-in-parts, a-matched-inclusion-target-is-barred-by-its-score, quantification-screens-and-identification-is-what-it-buys. Read the relevant ADR before re-litigating one of these.
  ⚠️ **0038 inverted which MS2 quantification measures, and the old arrangement never worked.** The
  engine used to measure the base MS2 and acquire a "quant follow-up" it never read — while the base
  MS2's activation (ETD, in the only config that enabled the feature) cannot release a TMT reporter
  ion. Now `ms_settings.ms2_quant` is the **quantification scan**: rostered once per selected
  precursor, marked `'Q'`, and the only scan measured. `ms_settings.ms2` is the **identification
  scan** a differential verdict buys, marked `'R'` exactly as in every other mode — so what changes
  between modes is only *when* it fires. The `'F'` marker is retired; `quantification.follow_up_scan`
  and `only_one_condition` are retired with migration errors; and `labelling` (seven OpenMS schemes),
  `conditions` (an **array** of exactly two, by channel **name**, whose order IS the ratio direction)
  and `correction_matrix` are new. Three config states now throw: `enabled` without `ms2_quant`,
  `conditions` ≠ 2, and quantification together with level-2 exploration.
  ⚠️ **0036 is ACCEPTED BUT NOT YET IMPLEMENTED; 0037 is WITHDRAWN** (amended 2026-08-28). Both
  address inclusion mode's blind spot when several deconvolved PeakGroups fall inside one row's
  `±2 × tolerance_ppm` window (0.247 Da at 10 ppm / 12 kDa — wider than the ~1 Da nominal-mass bin
  every acquisition-memory map keys on); the collapse that would merge them is deliberately skipped
  for targeted features, so **22 of 25 productive surveys** of `ms1_cytc.txt` carry 2–6 of them.
  **0036** governs *within* a survey: those PeakGroups are ONE Precursor, and its acquisition may be
  completed across them, so a target whose charge envelope arrives split no longer loses the charges
  the first PeakGroup could not resolve. It is scoped to rows that **name charges** — a `-1` row has
  no intended charge set and behaves exactly as it does today, in every charge mode, which is what
  makes "no golden moved" the acceptance test for the change.
  **0037** proposed the *across*-survey half: a matched target would stop reading the two
  `tqscore_exceeding_*` bars, making the qscore ratchet in `mass_qscore_map_` reachable. It was
  withdrawn because that ratchet is **not unreachable** — it dates to the original soft-exclusion
  work and is gated by `precursor_selection.tqscore_threshold`, two statements below it. Raise the
  threshold above a species' qscore and the ratchet governs; every committed config simply sits
  below (production 0.1, seventeen configs 0.0, twenty-three 0.9, against cytC's 0.94–0.98). The ADR
  would have removed that choice rather than added a capability, and implemented it moved thirteen
  log goldens on qscore improvements of +0.0002 to +0.0042 — build jitter buying an MS2 each time.
  `CONTEXT.md`'s **Split envelope** and **Intended charge set** entries are written against 0036 and
  so are ahead of the code; **Qscore bar** describes the existing knob and is current.
  ⚠️ **A scan carries THREE identity channels, not two** (ADR-0035, extending 0008). Alongside the
  instrument job number and the tracking id there is the **instrument scan number** — the one
  FLASHIda neither mints nor requests, and the only one that survives into the converted mzML, which
  is what makes it the join between an acquisition and its later analysis. `ida.log`'s `MS1 Scan#`
  carries it; `Access ID` on that same line keeps the **tracking id**, because that is the join key
  to the other four streams. It reaches the engine as a trailing `int` on `ProcessScan` — **appended,
  never inserted**, so a stale 8-parameter `OpenMS.dll` ignores argument 9 rather than reading an
  `int` as `faims_cv`. Export count is still 5 and `ScanCommand` is untouched. `<= 0` means "not
  supplied" and the log falls back to the tracking id.
  ⚠️ **The `ida.log` goldens cannot see a wrong `Mass=`.** `NormalizeIdaLog` masks `Scan# \d+` and
  the Access ID outright, and `Mass=` is compared at `RelTol 1e-3` — **±12.35 Da at 12 kDa**. The
  4-significant-digit port regression (`Mass=1.235e+04` against an `AllMass=` of `12351.3933`) passed
  with nine times the headroom; it is fixed (ADR-0035 decision 5), and the only thing that would
  catch its return is `FLASHIda_LoggingFields_test::ida_log_mass_matches_allmass_byte_for_byte`,
  which asserts every `Mass=` token appears **verbatim** in its own entry's `AllMass=` list — no
  golden can. Never cite an `ida.log` golden as coverage for a mass value or for either identifier.
  ⚠️ **0034 is the one ADR that is not about FLASHIda.** It pins FLASHDeconv's offline
  `*_ms2.feature` writer to TopPIC 1.8.x's 17-column layout — TopPIC parses that file positionally
  with no bounds check, so the previous 16-column form crashed it. It lives here because there is
  no other ADR home in the workspace, not because the FLASHDeconv no-go boundary moved.
  ⚠️ **An idle instrument is not a quiet one** (ADR-0033, amending 0032). A Tribrid whose
  custom-scan queue is empty acquires its *own method's* scans, so pinning the queue at depth 1 —
  which 0032 did — hands the instrument every host round trip. Measured on an Eclipse: **53 % of the
  duty cycle**, 144 method scans against FLASHIda's 47 in 17 s, and a lab report of "only AGC scans".
  The drain now tops up to `scheduling.target_depth` (**default 2**, `1` = 0032's behaviour) in a
  loop — one send per arrival oscillates 0↔1 and can never *reach* 2. The key is **host-only**:
  `Config.cpp` accepts it and ignores it, because only `Flash.cs` can size the instrument's queue.
  The watch metric for backing it out is MS1 injection time railing at `ms_settings.ms1.max_it`
  (the depth-1 baseline is 79-90 ms against a 246 ms ceiling).
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
- `docker/README.md` — the operating manual for the two containers: the prerequisite checklist, the calibration record (anchor SHA + CI run id + the expected counts), the documented divergences from CI, and the trust-revocation rule for when a container and CI disagree. `## Local verification (two containers)` above is the summary; that file is the detail.
### The three CLAUDE.md files are one doc set

| File | Scope |
|---|---|
| `CLAUDE.md` (this file) | The workspace: submodule wiring, the bridge/ABI contract, CI, **the local container system**, testing, goldens, config flow. Authoritative when it conflicts with a submodule file. |
| `FlashIDA/CLAUDE.md` | C# side only — acquisition loop, component roles, P/Invoke wrapper, logging, test suite. |
| `OpenMS/CLAUDE.md` | C++ FLASH real-time engine only — `processScan`, queue, selection, characterization, and the FLASHDeconv/FLASHTnT no-go boundary. |

**Keep them in sync, and treat editing the submodule files as in-scope.** They live in
separate git repos, so a doc fix there is a separate commit inside `FlashIDA/` or `OpenMS/`
plus a gitlink bump in the parent — that friction is why they drift. When a change makes any
of the three wrong, update all three in the same run; do not leave a known-stale claim
standing on the grounds that it lives in a submodule. Each file should state facts that need
multiple files to discover, and avoid restating what the other two own.

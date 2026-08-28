# Local verification in two containers

Two Docker containers do the day-to-day verifying of this workspace. A **Linux** container is the
fast inner loop (gcc, ctest, seconds). A **Windows** container is the pre-push gate (a real
`OpenMS.dll`, the whole C# side, all four fail-closed gates). `.github/workflows/flashida-ci.yml` is
**unchanged and still runs on every push** — it stays the authority for everything the two containers
cannot see.

Full design, and every measurement quoted below:
[`docs/superpowers/specs/2026-08-27-dockerized-local-ci-design.md`](../docs/superpowers/specs/2026-08-27-dockerized-local-ci-design.md).
This file is the operating manual; the spec is the argument.

---

## Prerequisites — every box, before the first run

`ci doctor` checks rows 1, 2, 4, 5, 6 and 7 and names the exact fix for each; run it first on any
machine. It does **not** check row 3 (it reports the isolation actually in effect instead, once the
Windows engine is up), row 8 (the image asserts its own locale at run time) or row 9 (optional).
**An absent input is a hard FAIL, never a skip** — that is the convention everywhere in this repo.

| # | Requirement | Verify | Fix |
|---|---|---|---|
| 1 | Docker Desktop, Linux engine reachable | `docker -H npipe:////./pipe/dockerDesktopLinuxEngine version --format '{{.Server.Os}}'` → `linux` | Install/start Docker Desktop |
| 2 | **Windows `Containers` optional feature** | `Get-CimInstance Win32_OptionalFeature -Filter "Name='Containers'"` → `InstallState = 1`, and `Get-Service cexecsvc` exists | See below — elevated command **plus a reboot** |
| 3 | Hyper-V present (the isolation fallback) | `(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` → `True`; `Win32_OptionalFeature Name='Microsoft-Hyper-V-All'` → `1` | `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All`, reboot |
| 4 | Disk: **≥ 60 GB free** | `docker system df` plus the free space on the Docker data root; `ci doctor` prints the current footprint | ~20 GB of first-run downloads, 40–60 GB steady state — see *What it costs* |
| 5 | Submodules checked out | `git submodule status` shows both populated | `git submodule update --init --recursive`. The C++ tests read `../../FlashIDA/test-data`; without `FlashIDA/` they fail at runtime, not at configure |
| 6 | `docker/**` and `ci` are **LF** in the working tree | `ci doctor` measures the CR bytes on disk (which is what the container executes, and works whether or not the files are tracked). By hand: `git ls-files --eol docker ci` → every row `w/lf` — but **zero rows means they are untracked, and a git-based check then passes vacuously** | A tree checked out before the root `.gitattributes` landed still has CRLF (`core.autocrlf=true`). With no local edits there: `rm -rf docker ci && git checkout -- docker ci` |
| 7 | Thermo DLLs decrypted (Windows leg only) | `ci doctor` runs the assembly identity gate on all five | See below — host-side decrypt, **never** an image layer |
| 8 | Locale | The image pins `en-US` and the entrypoint asserts it | Nothing on the host. Do **not** "fix" a container to your host locale — see below |
| 9 | *(optional)* Docker Desktop `SimultaneousWindowsAndLinuxContainers` | `docker context ls` shows a Windows context | Decides whether `ci all` is one command or two phases — see *Troubleshooting* |

### 2 — the `Containers` feature, in detail

This is the one that surprised us on the machine this system was built on, and it is invisible until
it bites. On that host `Containers` was `InstallState=2` (disabled), `C:\ProgramData\Docker` did not
exist, `cexecsvc` was absent, and **both docker contexts reported `linux`** — so a Windows
`docker run` fails with an error that reads like a Docker problem. **Docker Desktop's own binary
carries the refusal string and does not self-enable it.** Nothing on the Windows leg runs before this.

In an **elevated** PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
```

**Then reboot.** The feature is not usable before the restart, whether or not you pass `-NoRestart`.
Afterwards, verify **unelevated**:

```powershell
Get-CimInstance Win32_OptionalFeature -Filter "Name='Containers'"   # InstallState must be 1
Get-Service cexecsvc                                                # must exist
```

### 7 — Thermo DLLs, and where the passphrase may live

The five Thermo iAPI DLLs are licensed and **must never enter an image layer**. They are decrypted on
the host into `FlashIDA/dependencies/` (gitignored, and `.dockerignore`d) and reach the container by
bind mount. From Git Bash at the repo root:

```sh
read -rs -p 'passphrase: ' THERMO_DLL_PASSPHRASE && export THERMO_DLL_PASSPHRASE && echo
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in FlashIDA/dependencies/thermo-dlls.zip.enc -out "${TMPDIR:-/tmp}/thermo.zip" \
  -pass env:THERMO_DLL_PASSPHRASE
unzip -o "${TMPDIR:-/tmp}/thermo.zip" -d FlashIDA/dependencies/ && rm -f "${TMPDIR:-/tmp}/thermo.zip"
unset THERMO_DLL_PASSPHRASE
```

`THERMO_DLL_PASSPHRASE` never goes into a committed file, a `Dockerfile` `ARG`/`ENV`, or a log line —
read it at run time, and do not put it on a command line where your shell history keeps it.

**Lifecycle: these DLLs are HOST state, not container state.** `ci clean` never touches
`FlashIDA/dependencies/`. On a fresh clone they are absent and `ci doctor` reports that as a
**failure**, with the command above in the message. `Thermo.TNG.Client.API.dll` ships with Tune and is
**not** on the public Thermo repo, so the encrypted zip is the primary source and the public repo is
an audit fallback only.

### 8 — locale

`Mocks/MockMsScan.cs` parses every spectrum fixture value with a bare, culture-sensitive
`double.Parse`, and `FromTsv`/`FromTsvAsMS2`/`FromTsvAsMSn` feed the whole golden and continuity
suite. Under `de-DE`, `double.Parse("674.6919")` returns **6746919** — every m/z off by four orders of
magnitude, with no error anywhere. The image runs `Set-Culture en-US` and the entrypoint asserts
`(Get-Culture).Name` before any test runs. `ScanFactoryCultureTests` asserts its own `[SetCulture]`
premise and is therefore **not** a canary for container locale.

---

## The two containers

**Linux — the fast loop.** `ubuntu:24.04` (digest-pinned) + gcc 13.3, every dependency from apt, no
contrib tarball, ~357 MB image. Configures with `--network none` (`ENABLE_TDL` would otherwise
`FetchContent`-clone yaml-cpp at configure time; noble ships 0.8.0, which is why 24.04 and not
22.04), builds `libOpenMS.so` and the FLASH test exes, runs ctest. **It cannot produce `OpenMS.dll`**,
so it never exercises the bridge, the C# side, or anything a golden depends on.

**Windows — the pre-push gate.** `dotnet/framework/sdk:4.8-…-windowsservercore-ltsc2022` + VS 2022
BuildTools 17.14.39 (MSVC 14.44.35207, Win SDK 10.0.26100.0) + Qt 6.8.3 + the pinned contrib tarball.
Produces a real `OpenMS.dll`, **swaps four DLLs into `FlashIDA/dll` exactly as CI does** (`zlib.dll`
stays committed), then `nuget` → `msbuild` → the **unfiltered** 181-test NUnit suite → the 14-case
regression runner → all four fail-closed gates. ~25–50 min: a gate, not an inner loop.

**Neither container duplicates a test list.** Both parse `.github/workflows/flashida-ci.yml` through
`docker/ci-lists.awk` — the `--target` block and the `ctest -R` alternation. Any such list written out
in prose anywhere in this repo is stale by construction. Adding a C++ test still means editing **both**
lists in the yml, and then running `ci lists` to confirm the parser sees it.

**Nor are the toolchain pins authoritative here** — and only **one** of them is parseable out of the
yml. `install-qt-action`'s `version: '6.8.3'` is, so the parser reads it and the image build **fails**
if a Dockerfile pin disagrees. The rest the yml simply does not carry: it runs
`gh release download -R OpenMS/contrib` with **no tag**, so CI takes whatever release is latest at run
time, and it resolves the VC toolset and the Windows SDK from the floating `aka.ms/vs/17/release`
channel. Those are Dockerfile pins with nothing in the yml to check them against, so the container
asserts the built `cl.exe` equals CI's recorded `14.44.35207` and **warns loudly** rather than
failing. The values actually used are on the image as `LABEL`s (`vs.buildversion`, `vctools`,
`winsdk`, `contrib.tag`, `qt`). Read those and `docker/ci-lists.sh pins`, not this paragraph — and the
same goes for every count below: `ci lists` is what knows how many targets there are.

### Authority boundary — read this before trusting a green run

A green Linux run is the easiest thing in this system to over-trust.

| Question | Linux | Windows | GitHub CI |
|---|---|---|---|
| Does it compile under gcc? | **authoritative** | no | no |
| Does it compile under MSVC? | no | strong | **authoritative** |
| Does the C++ logic behave? | strong | strong | authoritative |
| Is `sizeof(ScanCommand)==2048` still true? | yes | yes | yes |
| Does the C#↔C++ P/Invoke round-trip work? | **impossible** | **authoritative locally** | authoritative |
| Is this float value right? | **never** | strong | **authoritative** |
| May this golden be committed? | **never** | may CAPTURE, never PROMOTE | **must confirm after promotion** |

**Why Linux may never adjudicate a number.** `OpenMS/cmake/compiler_flags.cmake:87-92` gives MSVC
`/arch:AVX` (256-bit) and non-MSVC `-mssse3` (128-bit) as PUBLIC options on every target, and Linux's
`x86_64` matches the `x64_CPU` pattern. Different vector width changes FP reduction order, and
`-ffp-contract=off` does not touch that. Reassuringly, **no C++ ctest reads a golden file** — every
`golden` occurrence in the 26 test sources is a comment — so cross-toolchain drift can produce Linux
ctest noise but can never corrupt a golden. A second divergence: `ProteoformTracker.cpp:789` documents
that `fragments` is an `unordered_map` whose order is "reproducible within a build and not across
them", and only that one site was hardened with a tie-break. **Treat a Linux-only ranking
disagreement as a lead, not a verdict.**

---

## The containers verify your working tree; CI verifies a commit

The containers run against the tree as it sits, **dirty**. CI runs a clean recursive checkout of a
commit. "Green containers" therefore means *"green with my uncommitted edits on this machine"* — never
*"green at this SHA"*.

**What stays exclusively remote,** named so nobody discovers a hole later:

- the **`pull_request` trigger** (`flashida-ci.yml:3-7`, PRs to `main`/`develop`/`flashida-v9-migration`). No container reproduces a merge gate.
- the **`cpp-test-build` round trip** — CI runs ctest against a packaged, uploaded, downloaded and unpacked build tree with the runtime DLLs staged beside the exes. The container runs ctest in a live build dir; the packaging/staging/relocation path is exercised only remotely.
- the **`openms-fresh-dll` bundle assertions** — `CHEMISTRY/unimod.xml`, `qt.conf`, `platforms/qwindows.dll`, the 7-DLL Qt closure. Fail-closed steps no container reproduces.
- **cold-cache compilation** — CI runs at `CCACHE_MAXSIZE=400M` (effectively near-cold), the containers at 30G (always warm). "This tree compiles from scratch" is only ever proven on GitHub.
- **MSVC as the goldens oracle**, and the FLASHDeconvWizard delivery.

---

## The command surface

One dispatcher at the repo root: `./ci` (bash, for Git Bash) and `.\ci.ps1` (a thin PowerShell shim
that calls it — there is no second command surface and no second parser).

| Command | Engine | Cost | What it does |
|---|---|---|---|
| `ci doctor` | — | s | Engine mode + isolation, `Containers` feature state, images, **Thermo DLL identity gate (absent = FAIL, never skip)**, `git status` across all 3 repos, contrib, python-in-image, locale, ccache size, total disk footprint |
| `ci doctor --compare-ci` | — | s | Fetches the latest green `openms-fresh-dll`; prints both DLL `sha256` values and both configure lines. **Informational, never a gate** |
| `ci lists` | — | ms | Parser self-test + reconciliation against the yml, under container mawk. The **Linux** entry points run it automatically as step 1; the **Windows** lane (`ci dll`, `ci cs`, `ci golden-diff`, `ci cpp --msvc`) deliberately does not — it needs the Linux engine, and Docker Desktop runs one at a time — so run this yourself after editing the workflow file or the parser |
| `ci cpp <name…>` | Linux | s–min | Build + run only those targets — **the real inner loop** |
| `ci cpp` | Linux | **~5 s** after build | Fast tier: the 26 minus anything over `--slow-threshold` (default 2 s) in the last run's JUnit timings. With no prior run it falls back to full and says so |
| `ci cpp --full` | Linux | ~25–35 min | All 26, `ctest -j 6`, `OMP_NUM_THREADS=1` |
| `ci cpp --debug` | Linux | slower | Separate build dir. The only Linux configuration ever proven green |
| `ci cpp --msvc <name…>` | Windows | min | **Targeted triage only.** There is deliberately no `--msvc --full`: running all 26 on MSVC locally duplicates CI's `cpp-tests` job on the toolchain CI is authoritative for |
| `ci dll` | Windows | 20–30 min cold / ~1 min warm | Build `OpenMS.dll`, swap the four DLLs, assert provenance |
| `ci cs` | Windows | ~28 min | `ci dll` + restore + msbuild + **unfiltered** NUnit + all 4 gates + regression + cleanup |
| `ci cs <filter>` | Windows | s–min | Filtered. **Always exits non-zero** with `PARTIAL: bridge-smoke and TRACK-CREATE gates did not run — NOT CI-EQUIVALENT`, and writes `TestResults.xml` where the gate cannot read it |
| `ci golden-diff` | Windows | ~28 min | Full compare, cell-level rendered diffs, **read-only**. Ends by printing the exact `cp` lines for the cells that moved |
| `ci all` | both | **~1 h** | Linux first, Windows last. Exits with the worst of the two |
| `ci clean` | — | s | Wipe build dirs, `bin/`, `test-output/`; restore `FlashIDA/dll/`; delete the five stray root files. **Never touches `FlashIDA/dependencies/`** |

### Exit codes and the verdict line

- Every subcommand exits **0 only if every gate it ran passed**, and non-zero otherwise. No `|| true` in the runner ever swallows a gate result: where one appears it is a `set -e` guard on a command substitution, and the failure it defers to is still fatal on the next line. Every bash wrapper starts `set -euo pipefail`; `docker/ci-lists.sh` is POSIX `sh` (`#!/bin/sh`, no bashisms, no arrays) and starts `set -eu`.
- Every subcommand's **last line** is exactly one of `PASS: <what was verified>`, `FAIL: <first failing gate>`, `PARTIAL: <what did not run> — NOT CI-EQUIVALENT`. A human reading only the last line is never misled.
- **`PARTIAL` always exits non-zero.** A skipped gate is a failure, not a note. Tell `FAIL` from `PARTIAL` by the verdict line — the tool does not distinguish them by exit number, only 0 from non-zero.
- `ci all` prints a two-line summary and exits with the **worst** of the two legs — never 0 if either was `FAIL` or `PARTIAL`.
- Every filtered NUnit and ctest invocation **asserts its selected count**. NUnit's `--where` fails *open*: an unrecognised selector, or a class name missing its namespace, yields `Test Count: 0, Overall result: Passed, exit 0`. (`ContinuityTests` lives in `Flash.Tests.AcquisitionLoop`, not `Flash.Tests`.)

### Load-bearing defaults, and what is deliberately absent

- **C++ defaults to Release**; `--debug` selects a separate build dir.
- **C# is always `Debug /p:Platform="Any CPU"` and there is no flag for it.** `Release|AnyCPU` sends `Flash.exe` to `src/Flash/bin/Release/` while `Flash.Tests.dll` stays in `FlashIDA/bin/`, and `Debug|x64` redirects to `bin\x64\Debug\`; either separation breaks nunit3-console, `regression-runner.ps1 -FlashExe`, and the test-data path. **The Release default is for C++ only.**
- **No `ci golden-promote`.** A wrapper is the one command shape the golden write guard does not gate. Promotion is a bare host-side `cp` of the moved cells.
- **No `--keep-dll`.** `FlashIDA/dll/` is restored in a `finally`, with no opt-out. Updating the committed DLLs is a rare, manual, diff-reviewed act — not a flag on the one mechanism whose silent failure is worst.
- **Address engines by their stable named pipes** — `npipe:////./pipe/dockerDesktopLinuxEngine` and `…WindowsEngine` — never `docker context use`, which re-points the generic `docker_engine` pipe.

---

## What it costs, honestly

| | |
|---|---|
| First-run downloads | **~20 GB** (the Windows base alone is 3.76 GiB compressed / 8.98 GiB uncompressed) |
| Steady-state disk | **40–60 GB** of images + volumes |
| Engineer time to first green on a new machine | realistically 4–12 h |
| `ci all` | **~1 h** — against CI's **57–68 min** |

**This does not beat CI's wall clock, and it is not meant to.** The payoff is elsewhere:

1. **No queue.** Run `32984975738` sat queued for **24 h**.
2. **A ~5 s fast tier** for the edit-compile-test loop — the thing that actually changes how you work.
3. **Local golden capture** (staged, never promoted — see below).
4. **Learning a build broke without a push.**

Why a *fast tier* rather than `-j`: measured on the production toolchain, the full ctest run is
**2109 s**, of which `FLASHIda_LoggingFields_test` alone is **1392 s (66 %)**, `FLASHIda_Logging`
265 s, `FLASHIda_exploration` 199 s, `FLASHIda_ProcessScan` 135 s, `FLASHIda_ChargeModes` 76 s,
`FLASHIdaFAIMS` 17 s, `FragmentAnalysis` 10 s, `FLASHIdaQueueTracking` 10 s and
`ProteoformTracker_Exhaustive` 4 s — nine tests over the 2 s cutoff, and **the other 17 total under
one second combined**. `ctest -j` cannot beat the longest single test, so parallelism alone
floors at ~23 min. The fast tier drops anything over `--slow-threshold`, derived from the previous
run's `--output-junit` timings; there is **no committed slow-test list**, because a second
hand-maintained list is exactly the rot the yml parser exists to prevent.

**Pruning is the user's call alone.** Tooling never runs `docker system prune` — a second Claude
session may share this workspace and its images. `ci doctor` prints the footprint so a human can
decide. **Never `docker push` either image**: the Windows one carries a licensed toolchain, and the
Thermo DLLs that must never reach a layer sit one bind mount away.

---

## Calibration record

The containers cannot have been verified by themselves. They are calibrated against a SHA whose
GitHub verdict is already published — and **from a `git worktree` at that SHA, never the live tree**,
or another session's in-flight work contaminates the comparison.

| Date | Anchor SHA | CI run | Expected C# | Expected ctest | Image labels (`vs.buildversion` / `contrib.tag` / `qt`) | Result |
|---|---|---|---|---|---|---|
| 2026-08-27 | parent `9bcfc82` | **33083942633** (success) | `total=181 passed=180 failed=0 skipped=1` — the skip is `ContinuityTests.P4_AL_CT42_DeepMode_TargetLogEffect` | **26/26**, `Total Test time (real) = 2109.38 sec` | *(record at first green)* | *(pending)* |

**Acceptance:** the Windows container reproduces those two numbers **exactly**. The Linux container
reproduces the *set* of 26, and its failures are **triaged, not assumed** — 13 of the 26 targets have
never been built under GCC and 13 have never been run; the 13 that did run passed on 2026-06-10 in
**Debug**, and Release compiles `OPENMS_PRECONDITION` out. Note also that
`src/tests/class_tests/openms/CMakeLists.txt:33-35` forces `-O0` for GCC/Clang even in Release, so the
Linux test binaries are unoptimised where the Windows ones are not.

**Append a row here on every recalibration** — including the one the trust-revocation rule below
demands after a structural disagreement.

---

## Documented divergences from CI

| Thing | CI | Container | Why |
|---|---|---|---|
| `WITH_GUI` | `ON` | **`OFF`** | CI needs `ON` only to ship `FLASHDeconvWizard.exe`, a delivery artifact. `OFF` skips 151 GUI TUs, AUTOUIC over 32 `.ui` files and four Qt components (−6 m 25 s) |
| FLASHDeconvWizard bundle | built | **not built** | Delivery, not verification. CI keeps producing `openms-fresh-dll` unchanged |
| `qtimageformats` | *believed* installed | not installed | It is a Qt **module**, not an aqt archive, and aqt silently drops unknown archive names — **so CI has been installing qtbase+qtsvg all along.** Harmless (`OpenMS_QT_COMPONENTS` is `Core Network`); the container matches CI's *effective* behaviour |
| contrib tarball | used, **untagged** | **Linux: dropped**; Windows: tag `2026-03-25-183345` | The tarball is `contrib_build-Windows.tar.gz`; Linux gets everything from apt. CI's `gh release download` passes no tag and takes whatever release is latest, so the container is *stricter* here, not identical — and CI extracts into `OpenMS/contrib` where the container uses `C:\contrib` |
| ccache | `400M` (near-cold) | `30G` (warm) | See *cold-cache compilation* under what stays remote-only |
| ctest input tree | packaged/uploaded/unpacked | live build dir | The relocation path is remote-only |

**The consequence, stated rather than implied:** the `OpenMS.dll` the local bridge/ABI check and any
local golden capture depend on is produced by a **differently configured library build than CI's**.
`WITH_GUI` gates GUI targets, not `OpenMS`'s own sources, so a behavioural difference is not
expected — but "not expected" is not "asserted". `ci doctor --compare-ci` makes a suspected divergence
checkable in one command: it prints both `sha256` values and both configure lines. It is
**informational and never a gate**, because CI links a different DLL every run by construction and the
shas will always differ. **If a golden ever disagrees between container and CI, re-run the Windows leg
once with `--with-gui` before blaming the code.**

---

## Goldens: the containers stage, they never promote

- **The container never sets `LOG_GOLDEN_CAPTURE`.** `FLASHIdaLogGolden_test` writes `<stream>.normalized` into `FlashIDA/bin/log-golden-output/<case>/` **unconditionally**, from the same normalized string a capture would write — so a *failing comparison run is already the capture*, and promotion is a rename. The golden tree can therefore be mounted read-only on every entrypoint.
- **The runner asserts what the in-test guard cannot.** The all-five-streams capture guard lives inside `if (Capture)`, which is never set, and **12 of the 31 log-golden tests `Assert.Pass` and return when their fixtures are absent**. So the runner asserts the fixture inventory *first*, and afterwards exactly **25 case directories × 5 non-empty `.normalized` files**.
- **Promotion is a bare host-side `cp`** of the moved cells, printed for you by `ci golden-diff`. Patch cells; never promote whole files — a whole-file promotion also rewrites column order and bakes in that run's float jitter.
- **The hooks never see your own terminal.** PreToolUse hooks observe an *agent's* tool calls only. Exactly two layers survive a human typing `./ci`: the mechanical one above — nothing ever sets `LOG_GOLDEN_CAPTURE`, so no run writes into `test-data/golden` in the first place — and the runner's own unconditional `git status` assertion, the last foreground action of every subcommand, with no flag that disables it and no code path that skips it. That second layer has one known blind spot: `FlashIDA/.gitignore:86 *.tmp` hides a `.tmp` file dropped into the golden tree from it. Do not run any repo-writing container step in the background either: the PostToolUse golden detector would fire before the write lands.
- **Prefer the CI artifact for the 13 regression TSVs.** `compare_golden.py` uses `REL_TOL=1e-4` — ten times tighter than the C# comparer's `1e-3`, leaving only ~2.6× headroom over the worst observed cross-build drift (3.79e-5).
- **A green CI run on the push carrying the golden is the acceptance test for every local capture.** A ccache-warm container relinks a bit-identical DLL, so local float jitter goes to zero — **that is not evidence the tolerance is unnecessary.** And the real hazard is not the tolerance but the cliff: rows, ids, counts and ordering compare *exactly* in all three comparers, so a jittered score crossing a selection threshold flips a discrete outcome no tolerance absorbs.

---

## When CI and a container disagree — the trust-revocation rule

This is policy, not a suggestion.

1. **Container green, CI red on a FLOAT-ONLY diff** → the container's DLL is a different binary. Discard the local capture, promote the CI artifact, carry on using the containers.
2. **Container green, CI red on a STRUCTURAL diff** (rows, ids, counts, ordering, or a test that passes locally and fails remotely) → **stop capturing goldens locally immediately.** Record the container's `vs.buildversion` / `contrib.tag` / `qt` labels and the CI run id in the calibration table above, and treat the Windows container as **compile-and-smoke only** until a fresh calibration against a new green CI run reproduces its two numbers exactly. Golden capture resumes only after that recalibration.
3. **Container red, CI green** → the container is wrong. Fix the container. **Never edit a test to make it agree.**
4. **Kill switch.** `ci` is a committed script and `flashida-ci.yml` is untouched, so backing the whole thing out is `git revert` of the `docker:` commits plus the two `.claude/` hook commits. Nothing in the build, the tests or the goldens depends on the containers existing.

**Standing rule:** prefer a container-side change (flags, `-isystem`, build scope, not using
`-Werror`) over **any** source change. A container change is a parent commit with no CI round trip; a
source change is a ~60 min cycle against the shipped engine — and every change under `OpenMS/src/**`
or `FlashIDA/src/**`, tests included, is asked about first, with the exact hunk.

---

## Troubleshooting

**`bad interpreter: /bin/bash^M`** — the tree was checked out before the root `.gitattributes` existed
and `core.autocrlf=true` gave you CRLF. Prerequisite 6. Do **not** "fix" it by normalising
`FlashIDA/test-data` to LF: `FlashIDA/.gitattributes:4` is `* text eol=crlf` deliberately, and
changing it changes what CI and the Windows container see.

**The Windows container will not start / `docker run` reports a Linux daemon.** Docker Desktop cannot
serve both engines at once by default. Address engines by their **named pipes**, never by
`docker context use`. From tooling, **never** call `docker desktop engine use` — it explicitly *stops*
the other daemon and kills every running container, including one you are inside; the legacy
`DockerCli.exe -SwitchDaemon` is documented not to, and takes 20–60 s and may prompt for elevation.
If `SimultaneousWindowsAndLinuxContainers` is off, `ci all` runs everything possible on the current
engine, writes phase state, prints one line telling you to switch, and **exits non-zero** with:

```
PARTIAL: the Windows leg did not run — no DLL build, no ABI provenance gate, no 181-test suite, no gates, no regression. NOT CI-EQUIVALENT.
```

Only `ci all --resume` completing the Windows leg can make the aggregate exit 0. Someone who never
resumes gets a failure, not a line of text.

**Hyper-V vs process isolation.** Docker defaults to **hyperv** on a Windows client SKU, so process
isolation is opt-in (`--isolation=process`) and Microsoft still labels it preview. Verify what you
actually got rather than what you asked for:
`docker inspect -f '{{.HostConfig.Isolation}}' flashida-win`. Under hyperv, pass
`--memory 24g --cpus 20` explicitly and expect bind-mount I/O to cross VSMB; under process isolation
there is no utility VM and no VSMB at all. Do **not** conclude Hyper-V is mandatory from the
image/host build mismatch — no MCR tag matches a Windows 11 build, and Microsoft's compatibility table
grants process isolation for WS2022 images from 24H2 onward regardless.

**`CS0246` on a Thermo type, or a run that cannot load `Flash.exe`'s dependencies.** The decrypted
DLLs are gone from `FlashIDA/dependencies/`. `ci clean` never removes them, so this means a fresh
clone or a manual delete — re-run the decrypt in prerequisite 7. All five are re-checked by an
assembly identity gate on every Windows run, because both csprojs carry
`<SpecificVersion>False</SpecificVersion>` and `App.config` has no binding redirect: **nothing else in
this system can detect `Thermo.TNG.Client.API.dll` version drift.** Note also that the public Thermo
repo ships two same-sized `Fusion.API-1.0.dll` files and only the `TribridSeries4pt2-and-previous/`
one (1.3.0.0) has `IFusionCustomScan` — another reason the encrypted zip is primary.

**Docker refuses to create the build-dir mountpoint.** The repo is bound `:ro` on the Linux side, so
Docker cannot auto-create it — `mkdir -p OpenMS/cmake-build-linux-release` on the host first. (The
name is already covered by `OpenMS/.gitignore`'s `cmake-build-*`, so no submodule `.gitignore` commit
is needed.) Never reuse the name `OpenMS/build` — that is reserved for a CI-shaped tree, and reusing
it lets a container build masquerade as a CI one.

**Files owned by `root:root` after a Linux run**, and **paths rewritten to drive letters from Git
Bash** — pass `--user` or chown afterwards, and set `MSYS_NO_PATHCONV=1`.

**ctest reports success and ran nothing.** `ctest -R ""` from an empty parse is version-dependent and
*both* outcomes are catastrophic: on the container's 3.28.3 it prints `No tests were found!!!` and
**exits 0**; on 4.3.3 it matches every test. Hence `--no-tests=error`, a fail-closed floor in
`ci-lists.sh`, and a gate on the JUnit `status="run"` attribute rather than on `failures` (a missing
test binary is reported as `notrun` under `skipped`, with `failures="0"`). If `ci lists` fails, fix it
before running anything else.

**A C++ test that builds but never runs** — it must appear in **both** the `--target` block and the
`ctest -R` alternation in `flashida-ci.yml`, and then in `ci lists`. `-R` branches are unanchored
regex searches, so `FLASHIda_Logging` also matches `FLASHIda_LoggingFields_test`; a parser that treats
branches as names silently drops 2 of the 26.

**A dirty `git status` after a run is a signal, never noise.** Local runs otherwise pollute the tree
in five places — `regression-runner.ps1` copies `test_inclusion_list.txt`, `test_fasta.fasta` and
`test_target_log.log` into the CWD, and NUnit writes `TestResults.xml` / `RegenResults.xml` at the
root. The runner deletes all five in a `finally` and the root `.gitignore` covers them as
belt-and-braces, precisely so that a dirty status keeps meaning something.

**Never create `Directory.Build.props`, `Directory.Packages.props`, `nuget.config` or a root
`.editorconfig`** at the parent root or above it. MSBuild and NuGet walk **up** past the submodule
boundary, and none exists today. Related: the parent `.gitignore` contains a bare `CLAUDE.md` line
that matches at **any** depth — never name a file `docker/CLAUDE.md`.

---

## Footnote: ADR-0025's ThreadSanitizer argument is MSVC-scoped

ADR-0025 (*the drain acquires no analysis lock*) records that the container race "is fixed by the
language rules and demonstrated by no test", partly because **"no tool substitutes: MSVC offers only
`/fsanitize=address`, which is not a race detector, and enabling it invalidates the ccache and poisons
the `openms-fresh-dll` artifact."**

That argument is about MSVC, and it stays true there. The Linux container changes its *premise*, not
the decision: gcc has `-fsanitize=thread`, and a Linux build dir produces **no `OpenMS.dll`**, so a
TSan build poisons no artifact. Nobody has run TSan on this fork; the option merely stopped being
unavailable, and ADR-0025's structural protection (decision 2 makes an unlocked access fail to
compile) is unchanged either way.

This note lives here rather than in the ADR **on purpose.** The ADR records an engine decision; new
tooling that could probe one of its two argued properties is not an amendment to it, and there is no
precedent in `docs/adr/` for a tooling or build-environment ADR.

---

## Constraints that are not negotiable

- **Never `docker push` either image.** A licensed toolchain lives in one of them, and the Thermo DLLs must never reach a layer or a registry.
- **`THERMO_DLL_PASSPHRASE` never appears in a committed file, an image layer, or a log line.**
- **No absolute host path in any file under `docker/`.** The dispatcher resolves the repo root from its own location and mounts relative to it — these containers must run on a machine that is not the one they were built on.
- **`.github/workflows/flashida-ci.yml` is frozen.** Both containers parse it; neither edits it, and it must keep working as a real testing path. A container result never overrides a CI result.
- **Never `docker system prune` from tooling.** Images carry a session-unique tag; a second session may share this workspace.
- **A missing input is an error, not a skip** — everywhere in this tooling, as everywhere else in this repo.

## See also

- [`docs/superpowers/specs/2026-08-27-dockerized-local-ci-design.md`](../docs/superpowers/specs/2026-08-27-dockerized-local-ci-design.md) — the full design, with the measurement behind every number here.
- `CLAUDE.md` → `## Local verification (two containers)`.
- `.github/workflows/flashida-ci.yml` — the single source of the build-target and ctest lists.

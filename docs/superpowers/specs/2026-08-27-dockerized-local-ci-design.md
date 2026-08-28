# Dockerized local CI for FLASHIda — design

**Date:** 2026-08-27  
**Status:** proposed, awaiting sign-off  
**Origin:** 25-agent planning workflow `wf_b35de471-459` (11 investigations, each adversarially verified, then drafted → critiqued → revised). 4.58M tokens, 0 agent errors.


---

## TL;DR

**Before:** the only way to learn whether a change compiles, passes 26 C++ ctests, passes 181 C# tests and leaves 155 goldens alone is to push to `august_pre` and wait — 57–68 min of CI on a good day, and one run in the last 48 h sat queued for 24 h. Nothing verifies locally: no restored NuGet packages, no net48 reference assemblies, encrypted Thermo DLLs, and two CLAUDE.md files that say "do not build" (parent `:32`/`:46`, OpenMS `:13`).

**After:** two local Docker containers do the day-to-day verifying. A **Linux** container (ubuntu:24.04 + gcc 13.3, every dep from apt, no contrib tarball) builds `libOpenMS.so` + the FLASH test exes and runs ctest — a compile/logic/crash gate whose fast tier answers in seconds. A **Windows** container (servercore-ltsc2022 + VS 2022 BuildTools 17.14.39 + Qt 6.8.3 + the pinned contrib tarball) produces a real `OpenMS.dll`, swaps it into `FlashIDA/dll` exactly as CI does, then runs nuget → msbuild → the unfiltered 181-test NUnit suite → the 14-case regression runner → all **four** fail-closed gates. Neither container duplicates a test list: both parse `.github/workflows/flashida-ci.yml`, which stays byte-unchanged and still runs on every push.

**What the containers do NOT replace, named rather than implied:** the clean recursive checkout, the `cpp-test-build` tarball round trip (CI runs ctest against a packaged-uploaded-downloaded-unpacked tree with DLLs staged beside the exes; the container runs it in a live build dir), the `openms-fresh-dll` bundle layout assertions, cold-cache compilation (CI is at `CCACHE_MAXSIZE=400M`, the container at 30G), MSVC as the goldens oracle, the `pull_request` gate on main/develop/flashida-v9-migration, and the FLASHDeconvWizard delivery. And the containers verify the **dirty working tree**; CI verifies a **commit** — "green containers" is never "green at this SHA".

The honest payoff is **not** a wall-clock win: `ci all` is ~1 h against CI's 57–68 min. It is a **~5 s fast tier** for the edit-compile-test loop, **no queue** (measured at 24 h), **local golden capture**, and learning a build broke without a push.


---

## Owner decisions (2026-08-27)

These answers were given after the spec was drafted and **override anything below that
disagrees with them**. D1-D4 came from the decision round; **D2 was then broadened, and D5-D6
added, by the owner's follow-up: _"ask me before all source changes. we still want to try to enable
local runs anywhere. ci should still work though for testing."_**

| # | Question | Decision | Consequence |
|---|---|---|---|
| **D1** | Gate 0 needs an elevated feature-enable + reboot | **Land Linux first; Windows follows** | Landing 1 splits into **1a (Linux)** and **1b (Windows)**. Gate-0 milestones M0/M4/M5 defer to 1b; M2/M3/M6 run now. Nothing blocks on the reboot. |
| **D2** *(broadened)* | May source changes land without asking? | **No. Ask before EVERY source change, with the exact diff** | Superseded the narrower untouchable-boundary-only rule. Scope is defined in *§What counts as a source change* below. Applies to all of `OpenMS/src/**` and `FlashIDA/src/**` — engine, bridge, **and tests** — whether or not the file sits inside the FLASHDeconv/FLASHTnT boundary. Prefer a container-side fix over any source fix, always. Any needed edit → **STOP**, show file + line + hunk, wait for a per-file yes. |
| **D3** | The two `.claude/` changes | **Guard fix authorized; allowlist declined** | `golden-write-guard.sh` + the `settings.json` PreToolUse matcher land in **1a**. **No `permissions.allow` block is added** — every `docker` call will prompt, by choice. Do not propose it again. |
| **D4** | Landing branch | **`phase-containers`, off `august_pre`** | Still gets a full CI run via the existing `phase-*` trigger. Keeps this landing from interleaving with the other session's in-flight ADR-0036/0037 work. |
| **D5** | How far should local capability go, and on which machines? | **Keep pursuing full local runs, and make them portable** | The Windows leg is **not** dropped — D1 sequences it, it does not cancel it. Additionally the containers must run on *any* dev machine, not just this host: no absolute host paths baked anywhere, the Thermo passphrase supplied at run time, the contrib tarball fetched anonymously, and the one-time host prerequisites documented as a checklist. See *§Portability requirements*. |
| **D6** | What is GitHub CI's status afterwards? | **It must keep working as a real testing path** | `flashida-ci.yml` stays byte-unchanged **and functional** — not a vestige. No change in this plan may break it, `phase-containers` is covered by the existing `phase-*` trigger, and CI stays the authoritative oracle for MSVC compilation, float values and golden confirmation. A container result never overrides a CI result. |

### Revised landing sequence

| Landing | Contents | Branch | CI | Gated on |
|---|---|---|---|---|
| **1a** | `golden-write-guard.sh` + matcher fix · `ci-lists.awk` parser · Linux container · `ci` dispatcher · doc rewrite (3 × CLAUDE.md, kb, plan headers) · both gitlink bumps | `phase-containers` | one run, predeclared success | Gate 0 **M2/M3/M6** only |
| **1b** | Windows container · `entrypoint.ps1` · Windows half of the dispatcher · `FlashIDA/dll` swap parity | `phase-containers` | one run | **M0 (your reboot)** + M1/M4/M5 |
| **2** | Memory rewrites (grep-driven sweep, 105 files) | — | none | after 1a |
| **3** *(conditional)* | OpenMS portability fixes — **every one D2-gated, boundary or not** | `phase-containers` | CI is the primary oracle (only GitHub compiles MSVC) | only if M3/M6 demand source changes |
| **4** *(conditional)* | Golden recapture | `phase-containers` | own push, always last | after 1b |

**D3 note:** the guard fix lands in **1a** even though the Linux container never captures a golden.
The hole is pre-existing and also blinds the guard to the owner's own terminal, so it is a standalone
safety fix that should not wait for the lane that happens to need it.

### What counts as a source change (D2)

| Ask first — **STOP and show the hunk** | Proceed — this is the approved deliverable |
|---|---|
| Any file under `OpenMS/src/**` (`.cpp`, `.h`, `.cmake`, `executables.cmake`) | New files under `docker/` |
| Any file under `FlashIDA/src/**` (`.cs`, `.csproj`, `.sln`) | The `ci` / `ci.ps1` dispatchers |
| **Test sources included** — already the standing rule, now restated | `docker/README.md` |
| `FlashIDA/test-data/**` fixtures, configs and goldens | `.gitignore`, `.gitattributes`, `.dockerignore` |
| `.github/workflows/flashida-ci.yml` (D6 freezes it anyway) | The three `CLAUDE.md` files and `docs/**` |
| `.claude/hooks/**`, `.claude/settings.json` (D3 pre-authorized only the guard fix) | The memory directory |

If a case is genuinely ambiguous, it counts as a source change: ask.

### Portability requirements (D5)

The containers must be reproducible on a machine that is not this one. Concretely:

| Requirement | Why | How it is met |
|---|---|---|
| No absolute host paths in any committed file | `C:/FLASHIda/flashida-development` is this box only | The dispatcher resolves the repo root from its own location; mounts are relative |
| Thermo DLLs never baked into an image layer | Licensing, and an image must not carry them | Decrypted host-side at run time; passed by bind mount; the image is never pushed to a registry |
| `THERMO_DLL_PASSPHRASE` never in a committed file, a layer, or a log | Secret hygiene | Read from the environment at run time; the dispatcher must not echo it |
| Contrib tarball fetched without credentials | A `GITHUB_TOKEN` would not be portable | Verified anonymous — 206 range GET, 149,253,674 B, tag `2026-03-25-183345` |
| Toolchain versions pinned identically to CI | Otherwise "portable" means "differently wrong on each machine" | Qt 6.8.3, VS BuildTools 17.14.39, MSVC 14.44.35207, Win SDK 10.0.26100.0 — **and see the RISK below** |
| One-time host prerequisites are a documented checklist, not tribal knowledge | The `Containers` feature + reboot surprised us here | `docker/README.md` opens with the prerequisite checklist and a `ci doctor` command that verifies each and names the fix |

⚠ **Open risk carried forward, unchanged by D5:** the toolchain pins above are currently
hard-coded into the Dockerfiles while the same values also live in `flashida-ci.yml`, with no parse
linking them. That is the exact duplication `ci-lists.awk` exists to prevent, reappearing one level
down. The implementation plan must either extend the parser to cover the pins or document why not.


---

## Feasibility

### Linux container
**GO.** Verified short of a link: a real `cmake` configure of this exact fork returned exit 0 inside `ubuntu:24.04` with `--network none`; all 26 CI build targets appear in the ninja graph and `ctest -N -R "<CI's alternation>"` selects exactly 26; all 39 FLASH TUs (13 engine + 26 test sources) pass `g++ -fsyntax-only` with the real per-file flags, including ScanCommand.h's three `static_assert`s (2048/80/24 hold under GCC x86-64 SysV). The fork ALSO has a green Linux history: job `cpp-unit-tests` on ubuntu-24.04/GCC 13.3 built the whole library + 13 FLASH exes and ran 11 ctests with '100% tests passed' on 2026-06-10 (run 27258966384), and was deleted for build consolidation (commit 374d141), not because it failed. The delta since is 64 files, only two of them non-test sources outside TOPDOWN. **Unproven and settled first:** nobody has ever built this fork at `-O3` on Linux (every green Linux build was Debug), and 13 of today's 26 targets have never been built and 13 never run under GCC. Both are closed by Milestone M1/M2, which cost minutes, not days.


### Windows container
**GO-WITH-CAVEATS.** The prerequisite is a hard gate nobody anticipated: the `Containers` Windows optional feature is **InstallState=2 (disabled)**, `C:\ProgramData\Docker` does not exist, `cexecsvc` is absent, and both docker contexts currently report `linux 29.4.3` — so no Windows container can run until an elevated `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All` plus a **reboot**. Docker Desktop's own binary carries the refusal string and does not self-enable. Everything downstream then checks out: Hyper-V is already fully enabled and `HypervisorPresent=True`; `mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-ltsc2022` exists (3.76 GiB compressed / 8.98 GiB uncompressed, measured from gzip ISIZE) and already ships VS **2022** BuildTools + the v4.8 targeting pack + NuGet; `aka.ms/vs/17/release/channel` currently returns 17.14.39, byte-identical to the VS version CI's runner used (MSVC 14.44.35207, SDK 10.0.26100.0); the contrib tarball downloads anonymously (verified 206 range GET, 149,253,674 B at tag 2026-03-25-183345); and the encrypted Thermo zip is proven complete — the CI log prints all five inflated DLLs including `Thermo.TNG.Client.API.dll`, which is NOT on the public Thermo repo. Real caveats: process isolation is documented-but-preview on this host and must be requested explicitly (Docker defaults to hyperv on a client SKU); modify-in-place of the image's gutted VS instance is untested (second-instance fallback specced); the container's `OpenMS.dll` is built `WITH_GUI=OFF` where CI's is `ON` (see §4); and the whole Windows leg is a ~25–50 min pre-push gate, not an inner loop.


### Verdict
**GO-WITH-CAVEATS.** The Linux container is a clear win and low risk. The Windows container is high-value but expensive: one reboot, ~20 GB of first-run downloads, 40–60 GB steady-state disk, and realistically 4–12 h of engineer time to first green — and it does **not** beat the CI critical path. Its value is (a) learning a build broke without a push, (b) capturing goldens locally, (c) removing GitHub queue time, measured at 24 h. Three findings force plan changes rather than notes: the golden write guard **does not fire** on any containerised capture (or on any quoted command, or on the PowerShell tool at all) **and only ever sees this agent's tool calls, never the human's own terminal**; CI's bridge/ABI drift detection is **emergent** from a fresh checkout + `needs: build` + a one-shot filesystem, all three of which vanish locally; and the toolchain pins (Qt, contrib tag, VC toolset, Win SDK) are duplicated out of the yml with no parse, which is the exact rot the parser exists to stop.


---

## 1. Architecture: two containers, one workflow, one authority boundary

> **TL;DR** Before: one remote verifier that answers every question in 68 minutes. After: two local verifiers with explicitly bounded authority, plus the same remote one, unchanged, still answering the questions only it can.

```
  .github/workflows/flashida-ci.yml   (FROZEN — still runs on push AND on pull_request)
            |  parsed, never copied
            v
     docker/ci-lists.awk  ---> 26 build targets, 24 ctest -R branches
            |                        |
   +--------+--------+      +--------+--------+
   |  LINUX (fast)   |      | WINDOWS (gate)  |
   | ubuntu:24.04    |      | servercore ltsc2022 + VS17.14 + Qt6.8.3
   | gcc 13.3, apt   |      | MSVC 14.44, contrib tarball
   | libOpenMS.so    |      | OpenMS.dll -> FlashIDA/dll swap
   | ctest (26)      |      | + nuget + msbuild + NUnit(181)
   |                 |      | + regression(14) + 4 gates
   +-----------------+      +-----------------+
        compile /                 everything, incl. golden capture
        logic / crash              (staging only, never in place)
```

**Authority boundary.** Write it into `docker/README.md` and into `CLAUDE.md`; a green Linux run is the easiest thing in this system to over-trust.

| Question | Linux | Windows | GitHub CI |
|---|---|---|---|
| Does it compile under gcc? | **authoritative** | no | no |
| Does it compile under MSVC? | no | strong | **authoritative** |
| Does the C++ logic behave? | strong | strong | authoritative |
| Is `sizeof(ScanCommand)==2048` still true? | yes | yes | yes |
| Does the C#↔C++ P/Invoke round-trip work? | **impossible** | **authoritative locally** | authoritative |
| Is this float value right? | **never** | strong | **authoritative** |
| May this golden be committed? | **never** | may CAPTURE, never PROMOTE | **must confirm after promotion** |

**Two consequences that must be stated, not implied.**

*Working tree vs commit.* The containers verify the tree as it sits, dirty. CI verifies a commit, from a clean recursive checkout. "Green containers" therefore means "green with my uncommitted edits on this machine", never "green at this SHA". One sentence in `CLAUDE.md`'s new section, verbatim.

*What stays exclusively remote.* Name it, so nobody discovers a hole later:
- the **`pull_request` trigger** — `flashida-ci.yml:3-7` fires on PRs to `main`/`develop`/`flashida-v9-migration` as well as on push. No container reproduces a merge gate. (Note `august_pre` is push-only, so no PR gate exists for today's branch.)
- the **`cpp-test-build` round trip** — CI's `cpp-tests` job runs ctest against a **packaged, uploaded, downloaded and unpacked** build tree with the runtime DLLs staged beside the exes (yml:256). The container runs ctest in a live build dir. The packaging/staging/relocation path is exercised only remotely.
- the **`openms-fresh-dll` bundle assertions** — `test -f .../CHEMISTRY/unimod.xml`, qt.conf, `platforms/qwindows.dll`, the 7-DLL Qt closure (yml:166-199). Fail-closed steps no container reproduces.
- **cold-cache compilation** — CI runs at `CCACHE_MAXSIZE=400M` (effectively near-cold), the container at 30G (always warm). "This tree compiles from scratch" is only ever proven on GitHub.
- MSVC-as-goldens-oracle and the FLASHDeconvWizard delivery.

**Why Linux may never adjudicate a number:** `OpenMS/cmake/compiler_flags.cmake:87-92` gives MSVC `/arch:AVX` (256-bit) and non-MSVC `-mssse3` (128-bit) as PUBLIC options on every target, and `x64_CPU` is `"x86|AMD64"`, which Linux's `x86_64` matches. Different vector width changes FP reduction order; `-ffp-contract=off` does not touch that. Reassuringly, **no C++ ctest reads a golden file** — every `golden` occurrence in the 26 test sources is a comment — so cross-toolchain drift can produce Linux ctest noise but can never corrupt a golden. A second divergence: `ProteoformTracker.cpp:789` documents that `fragments` is an `unordered_map` whose order is "reproducible within a build and not across them", and only that one site was hardened with a tie-break. Treat a Linux-only ranking disagreement as a **lead**, not a verdict.

**Ownership: every container FILE lives in the parent repo under `docker/`. No container file goes in either submodule.** Five reasons: the Windows container spans both submodules; both containers read a parent-repo file; even the Linux container needs the sibling submodule (`../../FlashIDA/test-data`); `OpenMS/` already ships `dockerfiles/Dockerfile` and `.gitpod.Dockerfile`, so a second one is upstream merge surface; and a submodule commit costs a gitlink bump. **This is a claim about container files only** — the landing still carries one OpenMS and one FlashIDA doc commit plus two gitlink bumps (§11).

**Verified inert:** `flashida-ci.yml` has no path filters, `Flash.sln` references only the two csprojs, every `..\..\` in `Flash.csproj` resolves inside `FlashIDA/`, and there is no `Directory.Build.props`, `Directory.Packages.props`, `nuget.config` or root `.editorconfig` at the parent root or at `C:/FLASHIda/`. **// DEFECT-IN-WAITING:** MSBuild and NuGet walk UP past the submodule boundary. Write into `CLAUDE.md` that none of those files may ever be created at either level. Also: the parent `.gitignore` contains a bare `CLAUDE.md` line, which matches at **any** depth — never name a file `docker/CLAUDE.md`.


---

## 2. Gate 0: settle the riskiest unknowns before spending anything

> **TL;DR** Before: the plan's two most expensive steps (a Windows image build, a full OpenMS compile) both rest on unproven assumptions. After: six probes, none longer than 15 minutes, retire every blocker-class unknown first.

Ordered riskiest-cheapest-first. **Do not start M4 until M0 is green; do not start M5 until M3 is green.**

| # | Probe | Cost | Settles | Failure means |
|---|---|---|---|---|
| **M0** | Elevated `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart`, **reboot**, then unelevated `Get-CimInstance Win32_OptionalFeature -Filter "Name='Containers'"` → InstallState 1 and `Get-Service cexecsvc` exists | 1 UAC + reboot | The entire Windows lane | Windows lane is dead; Linux lane proceeds alone |
| **M1** | Host-side: `openssl enc -aes-256-cbc -d -pbkdf2 -in FlashIDA/dependencies/thermo-dlls.zip.enc -out /tmp/t.zip -pass env:THERMO_DLL_PASSPHRASE && unzip -l /tmp/t.zip` | 60 s | Whether the C# build is possible at all | Windows lane blocked on a Tune machine |
| **M2** | Write `docker/ci-lists.awk`, run it under **mawk in ubuntu:24.04** (never on the host — see §5) | 20 min | The parser | Fix before anything reads it |
| **M3** | Linux container: `cmake --build cmake-build-linux-release --target OpenMS` then `--target ScanCommandLayout_test` | ~10 min | Does this fork LINK at `-O3` on gcc — the one thing nobody has ever done | §3's portability triage becomes real work |
| **M4** | `docker pull mcr.microsoft.com/windows/nanoserver:ltsc2022` (~130 MB); run once with `--isolation=hyperv`, once with `--isolation=process`; `docker inspect -f '{{.HostConfig.Isolation}}'`; then a 10-minute bind-vs-container-local compile benchmark | 20 min | Isolation mode, memory flags, and whether the bind mount is actually slow | Fall back to hyperv + `--memory 24g --cpus 20` |
| **M5** | Enable Docker Desktop's `SimultaneousWindowsAndLinuxContainers`; `docker context ls` should gain a Windows context; re-run `docker -c desktop-linux run --rm ubuntu:24.04 true` | 10 min | Whether §10's one-command UX is real or two-phase | §10's fail-closed two-phase mode |
| **M6** | Linux container: full 26-test `ctest`, triage | ~35 min | Which of the 13 never-run tests actually pass under GCC | Widen ranges *or* fix comparators — never on Linux evidence alone |

**M0 detail.** Verified today: `Containers`=2, `Containers-HNS`=2, `Microsoft-Hyper-V-All`=1, `HypervisorPresent=True`, `Test-Path C:\ProgramData\Docker`=False, `com.docker.service` Stopped/Manual. The user is a split-token local admin, so this is one UAC prompt. `docker manifest inspect` (metadata only) confirms no MCR tag matches host build 26200 — ltsc2022 is 10.0.20348.5499, ltsc2025 is 10.0.26100.33296.

**M4 detail — do not conclude Hyper-V is mandatory from the build mismatch.** Microsoft's version-compatibility table, Windows 11 client rows, grants process isolation for **both** WS2022 and WS2025 images from Windows 11 24H2 onward; this host is 25H2/26200. But Docker's dockerd reference states "on Windows client, the default is hyperv", so process isolation is **opt-in** (`--isolation=process`). MS still labels it preview. Attempt process, commit to hyperv as the costed fallback, verify what you actually got. **Measure the bind-mount cost here** — no Microsoft page documents any Windows bind-mount throughput figure, and under process isolation there is no utility VM and no VSMB at all.

**M5 detail.** `com.docker.backend.exe` contains the settings key `SimultaneousWindowsAndLinuxContainers` and the pipe name `dockerDesktopWindowsEngine` alongside the `dockerDesktopLinuxEngine` in use today. The key is absent from `settings-store.json`, i.e. off by default. **// TRAP:** `docker desktop engine use` explicitly stops the other daemon; the legacy `DockerCli.exe -SwitchDaemon` is documented not to. Never use the former in tooling.

**M6 detail — a discovery exercise, not a gate.** 13 of 26 targets were never built under GCC and 13 never run; the 13 that did run passed on 2026-06-10 in **Debug**, and Release compiles out `OPENMS_PRECONDITION`. Note `src/tests/class_tests/openms/CMakeLists.txt:33-35` forces `CMAKE_CXX_FLAGS_RELEASE="-O0"` for GCC/Clang/Intel but not MSVC — Linux test binaries are unoptimised where the Windows ones are not.


---

## 3. The Linux container

> **TL;DR** Before: `OpenMS/CLAUDE.md:13` says "do not build this project — CI handles it". After: a 357 MB image, a verified-offline configure, and a fast tier that answers in seconds.

**Dockerfile** (`docker/linux/Dockerfile`) — every package name verified to install on noble, and this exact set produced a green offline configure:

```dockerfile
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++ make git ca-certificates \
      cmake ninja-build ccache rsync gawk \
      qt6-base-dev libeigen3-dev \
      libboost-date-time-dev libboost-regex-dev libboost-iostreams-dev \
      libboost-math-dev libboost-random-dev \
      libxerces-c-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
      libsvm-dev coinor-libcoinmp-dev libyaml-cpp-dev \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
```

**Configure line** (exit 0 verified under `--network none`):

```
cmake -S /work/OpenMS -B /work/OpenMS/cmake-build-linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -DENABLE_DOCS=OFF \
  -DBOOST_USE_STATIC=ON -DGIT_TRACKING=OFF -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
```

`--debug` flips only `CMAKE_BUILD_TYPE` and the `-B` dir to `cmake-build-linux-debug`. Configure both from the same source (8.5 s each).

**Run configure with `--network none` permanently.** `ENABLE_TDL` defaults ON, and `tdl-config.cmake:26-44` does `find_package(yaml-cpp 0.8.0 QUIET)` then falls back to a configure-time `FetchContent` clone of `github.com/jbeder/yaml-cpp`. Noble ships 0.8.0; jammy ships 0.7.0 — **this is the reason 24.04 and not 22.04**. Proven negatively: purging `libyaml-cpp-dev` and configuring offline gives `Could not resolve host: github.com` → `Configuring incomplete`.

**Divergences from CI's configure, each with a reason:**

| Flag | CI | Here | Why |
|---|---|---|---|
| `WITH_GUI` | ON | **OFF** | CI needs ON only to ship `FLASHDeconvWizard.exe`, a Windows deliverable. OFF skips 151 GUI TUs, AUTOUIC over 32 `.ui` files and four Qt components. |
| `OPENMS_CONTRIB_LIBS` | set | **dropped** | The tarball is `contrib_build-Windows.tar.gz`. Linux gets everything from apt. |
| `CMAKE_PREFIX_PATH` / `Eigen3_DIR` | set | **dropped** | Chocolatey/aqt-specific; apt configs are where CMake looks. |
| `BOOST_USE_STATIC` | ON | **ON** | Kept deliberately: it is the `CMakeLists.txt:54` default, it is what CI passes, and it is what the last **green** Linux job actually linked. The lzma/zstd/bz2 link closure is covered by the apt list. |
| `ENABLE_DOCS` / `GIT_TRACKING` | — | **OFF** | Additive; docs self-disable anyway, and `GIT_TRACKING=ON` re-triggers regeneration on every branch switch. |

**Never set `ENABLE_STYLE_TESTING`.** `src/tests/CMakeLists.txt:20-36` makes it either/or: ON adds only `coding` and `class_tests` is never configured — the 26 FLASH tests would silently vanish.

**Mounts** (verified working, including `../..` traversal across the mount boundary and a read-only canary):

```
-v <repo>:/work:ro
-v flashida-build-linux-rel:/work/OpenMS/cmake-build-linux-release
-v flashida-ccache-linux:/ccache
-e CCACHE_DIR=/ccache -e CCACHE_BASEDIR=/work -e CCACHE_MAXSIZE=30G
-e OPENMS_DATA_PATH=/work/OpenMS/share/OpenMS
-w /work/OpenMS/cmake-build-linux-release
```

The nesting is load-bearing: `add_test(... WORKING_DIRECTORY ${CMAKE_BINARY_DIR})` (`class_tests/openms/CMakeLists.txt:44`) means the 17 distinct `"../../FlashIDA/test-data/..."` literals resolve only if the build dir sits directly under `<root>/OpenMS/` with `<root>/FlashIDA/` beside it. **The repo bind is `:ro` and that is safe**: all 17 fixture literals are read-only inputs, and every test write is relative to CWD (`freshLogDir(tag)` → `testlogs/<tag>`, `testlogs/pt_trajectory`, `lf_f8excl_target.log`, `runtime.log_dir`) and therefore lands on the ext4 volume. **// RUNNER MUST DO THIS:** with a `:ro` bind, Docker cannot auto-create the mountpoint, so `ci` must `mkdir -p OpenMS/cmake-build-linux-release` on the host first. That name is already covered by `OpenMS/.gitignore:29 cmake-build-*` — **no `.gitignore` commit is needed in either submodule.**

**I/O, in one line:** the Windows bind reaches the Linux VM over 9p with no working page cache (~2.1–2.7 ms per small-file open vs 23 µs on the ext4 volume), which is why the **source stays on the bind and the build tree and ccache live on named volumes**. That costs a ~4 s no-op `ninja` and ~10 s of source reads per full build — the honest price of not forking the tree, and small next to a ~5 s fast-tier ctest. Relocating the checkout into WSL2 ext4 would remove the 9p hop entirely and is 250x faster on stat/read, but it forks the tree the Windows container, the `.claude` hooks, the golden guard and the editor all operate on; recorded as the escape hatch, not adopted, and **no staging/rsync mode is built until M4 says the numbers demand one**.

**Test tiering — this is what makes it a fast loop, not `-j`.** Measured on the production toolchain (run 33083942633): total 2109 s, of which `FLASHIda_LoggingFields_test` alone is **1392 s (66 %)**, `FLASHIda_Logging` 265 s, `FLASHIda_exploration` 199 s, `FLASHIda_ProcessScan` 135 s, `FLASHIda_ChargeModes` 76 s, `FLASHIdaFAIMS` 17 s, `FragmentAnalysis` 10 s, `FLASHIdaQueueTracking` 10 s, `ProteoformTracker_Exhaustive` 4 s — and **the other 17 tests total under 1 second combined**. `ctest -j` cannot beat the longest single test, so parallelism alone floors at ~23 min.

| Tier | Content | Expected |
|---|---|---|
| `--tier fast` (default) | the 26 parsed tests **minus** any whose last recorded runtime exceeded `--slow-threshold` (default 2 s) | ~5 s |
| `--tier full` | all 26, `ctest -j 6`, `OMP_NUM_THREADS=1` | ~23–35 min |

**The slow set is derived, not committed.** The runner reads the previous run's `--output-junit` timings from `<build>/flci-ctest.xml` and excludes anything over the threshold; with no prior run it falls back to `--tier full` and says so. There is no committed `slow-tests.txt` — a hand-maintained second list is exactly what §5 exists to prevent.

`ctest -j` is path-safe today: `RUN_SERIAL` appears once (`StopWatch_test`, not in our 26); all 41 `freshLogDir` tag literals are distinct; `File::makeDir` is `QDir::mkpath` (idempotent); `removeDirRecursively` only targets the tag subdir; the three bare-CWD `.log` files belong to one binary. **// HAZARD:** 16 `#pragma omp` sites live under TOPDOWN, so `-j` oversubscribes — set `OMP_NUM_THREADS=1` (note `FLASHIda.cpp:66-69` calls `omp_set_num_threads(4)` unconditionally at construction, so the env only governs tests that never build a FLASHIda).

**Portability triage (M3/M6).** Expected source fixes: **zero**. Prefer a container-side change (flags, `-isystem`, build scope) over any source change, always. **// SCOPE COLLISION RISK:** a static scan flagged `Qvalue.cpp` (`std::sort` at 73-75/119-121, `std::accumulate` at 80 with no `<algorithm>`/`<numeric>`), plus FLASHDeconv/FLASHTagger/FLASHTnT/FLASHExtender files — five of which are inside the untouchable boundary. If M3 needs an `#include` there, **STOP and ask the owner before editing**.

**// CRLF HAZARD — this only bites on Linux.** `FlashIDA/.gitattributes:4` is `* text eol=crlf`, which forces CRLF into the working tree on **every** platform. On Windows a text-mode `ifstream` strips `\r`; on Linux it does not. Three of the never-run tests read those fixtures (`ConfigSchemaParity_test` slurps the reference JSON via `in.rdbuf()` and does substring/`==` comparisons; `FLASHIda_ChargeModes_test`; `FLASHIda_LoggingFields_test`). Run those three FIRST in M6. **Do not "fix" this by normalising fixtures to LF** — that changes what CI and the Windows container see.


---

## 4. The Windows container

> **TL;DR** Before: `CLAUDE.md:44` says local builds need Thermo DLLs you cannot get and a toolchain nobody has. After: one image, one long-lived container, and a docker exec sequence that is CI's windows-tests job step for step — with its one deliberate divergence asserted rather than hoped.

**Base:** `mcr.microsoft.com/dotnet/framework/sdk:4.8-20250909-windowsservercore-ltsc2022` (pin the dated tag). Measured 3.76 GiB compressed / **8.98 GiB uncompressed** across 9 layers. It already carries VS **2022** BuildTools, `Microsoft.Net.Component.4.8.SDK`, NuGet 6.14.0, and it bootstraps from `aka.ms/vs/17/release` — the same channel we want.

| Rejected base | Why |
|---|---|
| floating `:4.8` | now resolves only to ltsc2016/ltsc2019 — process isolation unsupported on Win11 |
| `:4.8.1-*` | ships VS **18** BuildTools and only the **4.8.1** targeting pack; both csprojs pin `v4.8` |
| plain `servercore` | saves 1.98 GiB, costs MSBuild + NuGet + net48 + the .NET runtime |

**Dockerfile additions, in order** (few RUN layers, each ending `Remove-Item $Env:TEMP\*`):

1. **C++ toolchain**, modifying the existing 2022 instance (Microsoft's own documented pattern, same `--installPath`; exit code **3010 = success-with-reboot and MUST be swallowed**): `--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100`, flags `--quiet --wait --norestart --nocache`. **// UNTESTED:** the image's build history guts the VS Installer to `vswhere.exe` and deletes the Package Cache; the bootstrapper re-installs the setup engine and `_Instances` survives, so modify should work — keep a second-instance-at-`C:\BuildTools` fallback specced.
2. **VC++ redistributable, unconditionally.** A real PE import-table walk shows `OpenMS.dll` load-time-imports `MSVCP140.dll`, `VCOMP140.DLL`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`; `Qt6Core.dll` adds **`MSVCP140_1.dll`**. `vc_redist.x64.exe /install /quiet /norestart`, then a build-time assert (`where msvcp140.dll` plus a one-line P/Invoke of `CreateFLASHIda`) so a missing runtime fails the *image build*.
3. **choco:** `ninja cmake ccache 7zip eigen python312`. Python is not optional — `regression-runner.ps1:203` shells out to a bare `python`, and on this host `python`/`py` are Store stubs.
4. **Qt:** `aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 --archives qtbase qtsvg -O C:\Qt`; `ENV QT_ROOT_DIR=C:\Qt\6.8.3\msvc2022_64`. **Deliberately two archives, not three.** `qtimageformats` is a MODULE, not an archive, and aqt's filter silently drops unknown names — so CI has been installing qtbase+qtsvg all along. Harmless (`OpenMS_QT_COMPONENTS` is `Core Network`); we match CI's *effective* behaviour and say so.
5. **contrib:** pinned tag `2026-03-25-183345` (149,253,674 B, anonymous), extracted to `C:\contrib`. **Never into `OpenMS/contrib`** — that is a nested submodule, populated with source locally, and CI deliberately leaves it empty.
6. **Locale pin + assertion.** `Set-Culture en-US` in the image, and the entrypoint **asserts** `(Get-Culture).Name -eq 'en-US'` before running anything. `Mocks/MockMsScan.cs` parses every spectrum fixture value with a bare culture-sensitive `double.Parse` (:265, :274, :275, :338, :354, :355), and `FromTsv`/`FromTsvAsMS2`/`FromTsvAsMSn` feed the whole golden and continuity suite. Demonstrated on the local .NET 8 SDK: under `de-DE`, `double.Parse("674.6919")` returns **6746919**. This host is de-DE.
7. **LABELs + a pin assertion.** Record `vs.buildversion`, `vctools`, `winsdk`, `contrib.tag`, `qt`.

**// TOOLCHAIN PINS ARE PARSED, NOT COPIED.** Qt `6.8.3`, the contrib tag, the VC toolset and the Win SDK all appear in `flashida-ci.yml` too. `docker/ci-lists.awk` extracts them alongside the test lists (`install-qt-action`'s `version:`, the `gh release download -R OpenMS/contrib` tag, and the two `--add` component ids if/when they land in the yml). The image build **fails** if a Dockerfile pin disagrees with the parsed value; where the yml carries no pin (the VC component id, which CI resolves from the floating channel), the container's entrypoint asserts the built `cl.exe` version equals CI's recorded `14.44.35207` and **warns loudly** rather than failing. LABELs make a disagreement diagnosable; the assertion makes it *prevented*. This is the same rule as §5, applied to the toolchain.

**Never in the image:** the repo, the Thermo DLLs, `THERMO_DLL_PASSPHRASE`. Decrypt on the host into `FlashIDA/dependencies/` (gitignored at `.gitignore:31`) and let the bind mount carry them. Add `FlashIDA/dependencies/*.dll` to `.dockerignore` and a pre-build guard. **Lifecycle:** the DLLs are host state, not container state — `ci clean` never touches `dependencies/`, and on a fresh clone `ci doctor` reports them **ABSENT = hard failure**, never a skip, with the exact decrypt command in the message.

**Thermo DLL sourcing — the brief's premise is inverted.** PRIMARY is the encrypted zip; the public repo is a FALLBACK/audit source only. The CI log prints five `inflating:` lines including `Thermo.TNG.Client.API.dll`, which is **absent from the entire `thermofisherlsms/iapi` repo** (583 tree entries scanned) because it ships with Tune. It is a compile-time dependency of BOTH projects. **// TRAP for a fetch script:** the repo ships two `Fusion.API-1.0.dll` files of identical size (7680 B) with identical XML docs — `TribridSeries4pt2-and-previous/` is 1.3.0.0 (correct), `previous-versions/` is 1.2.0.0 (lacks `IFusionCustomScan`). Pin the path AND the sha256 (`bc85d937…`). Add a post-restore identity gate asserting name/version/PKT of all five with `[System.Reflection.AssemblyName]::GetAssemblyName` — both csprojs carry `<SpecificVersion>False</SpecificVersion>` and `App.config` has no binding redirect, so **nothing else in the system can ever detect Client.API version drift.**

**C++ configure (Release):**
```
cmake -S C:\repo\OpenMS -B C:\repo\OpenMS\cmake-build-msvc-release -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -DBOOST_USE_STATIC=ON ^
  -DOPENMS_CONTRIB_LIBS=C:\contrib ^
  -DCMAKE_PREFIX_PATH="%QT_ROOT_DIR%/lib/cmake;%QT_ROOT_DIR%" ^
  -DEigen3_DIR=C:\ProgramData\chocolatey\lib\eigen\share\cmake ^
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
```
`--debug` MUST add `-DCMAKE_POLICY_DEFAULT_CMP0141=NEW -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded`: ccache's `argprocessing.cpp:1741` bails on `/Zi` and `/ZI` (only `/Z7` caches), and OpenMS's `cmake_minimum_required(VERSION 3.21)` is below 3.25 so CMP0141 defaults OLD and the format variable would be silently ignored.

**// THE `WITH_GUI` DIVERGENCE AND ITS CONSEQUENCE.** CI configures `WITH_GUI=ON`; the container configures `OFF`, saving 6 m 25 s and the whole Qt GUI closure. **The consequence must be written down: the `OpenMS.dll` the local bridge/ABI check runs against is produced by a differently-configured library build than CI's.** `WITH_GUI` gates GUI targets, not `OpenMS`'s own sources, so a behavioural difference is not expected — but "not expected" is not "asserted". Mitigation, cheap and exact: `ci doctor --compare-ci` downloads the latest green `openms-fresh-dll` artifact and prints `sha256` of both DLLs side by side with the two configure lines. It is **informational, never a gate** (CI links a different DLL every run by construction, so the shas will differ), and its job is to make a suspected divergence checkable in one command instead of unfalsifiable. If a golden ever disagrees between container and CI, re-run the container leg once with `--with-gui` before blaming the code.

**Run model:** ONE long-lived container driven by `docker exec`, so scratch and ccache survive: `docker run -d --name flashida-win --isolation=<process|hyperv> --memory 24g --cpus 20 -v C:\FLASHIda\flashida-development:C:\repo -v flashida-ccache-msvc:C:\ccache flashida-win:latest ping -t localhost`. Repo bind is **rw** — the C# leg legitimately writes `bin/`, `obj/`, `packages/`, `dependencies/`, `test-output/` and `dll/`, and those must reach the host for review. `CCACHE_MAXSIZE=30G`, `CCACHE_COMPILERCHECK=content`, same `CCACHE_SLOPPINESS` as CI.

**The C# leg — CI's steps, in CI's order, with CI's per-step `env:`, plus four assertions CI never needed:**

| # | Step | Note |
|---|---|---|
| 0 | `Remove-Item -Recurse -Force FlashIDA\bin` | **// DEFECT CI CANNOT HIT:** `Copy-Item -Force` preserves the SOURCE mtime (measured), so a freshly built `OpenMS.dll` can be *older* than a stale `bin/` copy, and `CopyToOutputDirectory=PreserveNewest` (`Flash.csproj:135-154`) then SKIPS it. The suite silently tests the old engine and reports green. |
| 1 | swap **4** DLLs: `OpenMS`, `OpenSwathAlgo` from the build; `Qt6Core`, `Qt6Network` from `%QT_ROOT_DIR%\bin`; **zlib stays committed**. Touch all four to `Get-Date`. | `git -C FlashIDA ls-files dll/` shows all 6 files are **tracked** — see §6 for cleanup. Qt6 DLLs are NOT produced by the OpenMS build. |
| 2 | Thermo DLLs already present (host-decrypted) | + the identity gate |
| 3 | `nuget restore FlashIDA/src/Flash.sln` | warm this into the image so test runs need no network |
| 4 | `msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /m` | **Both values are load-bearing.** `Release\|AnyCPU` sends `Flash.exe` to `src/Flash/bin/Release/` while `Flash.Tests.dll` stays in `FlashIDA/bin/`. `Debug\|x64` redirects to `bin\x64\Debug\`. **The plan's Release default applies to C++ ONLY.** Add `/p:LangVersion=7.3` — neither project pins LangVersion on the AnyCPU configs CI builds, so a newer Roslyn would accept source CI rejects. |
| 5 | **PROVENANCE GATE** (see §8) | three assertions |
| 6 | `Copy-Item FlashIDA\dependencies\*.dll FlashIDA\bin\ -Force` | for `Flash.exe` runtime |
| 7 | `nunit3-console.exe FlashIDA\bin\Flash.Tests.dll --result=TestResults.xml --agents=1 --timeout=300000` — **unfiltered**, CWD = repo root, **`env: OPENMS_DATA_PATH` set exactly as yml:369** | assert `total=181 passed=180 failed=0 skipped=1`; the skip is `ContinuityTests.P4_AL_CT42_DeepMode_TargetLogEffect`. The env var is inert (`FLASHIdaWrapper.cs:173-177` overwrites it) but is set for fidelity — dropping it silently is a divergence from the thing being reproduced. |
| 8 | *(opt-in, default OFF)* `REGEN_CONFIG_REFERENCE=1` single-test run, **with yml:402's `env:`** | **MUST be after step 7** — the yml's own comment says otherwise "the gate would then pass against its own output". |
| 9 | `Flash.exe <ms1_smoke_test.txt> <baseline_phase0.tsv> <method_default.json>` | positional, no flags |
| 10 | `regression-runner.ps1 -captureMode -OutputDir FlashIDA\test-output\phase4-golden`, **with yml:430's `env:`** | |
| 11 | **GATE 1** JSON golden capture — `test-output\json\{config_default,config_full}.json` must exist | **the fourth gate `CLAUDE.md` omits** |
| 12 | **GATE 2** test data directories | |
| 13 | `regression-runner.ps1` (compare) piped through `Tee-Object` + `if ($LASTEXITCODE -ne 0) { exit }` | **// ORDERING IS LOAD-BEARING:** this WIPES `FlashIDA\test-output` (`regression-runner.ps1:11-13`), destroying what steps 9–11 produced. |
| 14 | **GATE 3** bridge smoke tests — reparse `TestResults.xml`, ≥1 `BridgeSmokeTests` case, every one `Passed` | Skipped/Inconclusive count as failures |
| 15 | **GATE 4** `[TRACK-CREATE]` in `regression-stdout.txt`, zero = fail | |
| 16 | `finally`: restore `dll/`, delete strays, assert clean | §6 |


---

## 5. Sourcing the test lists from CI: parse, never copy

> **TL;DR** Before: the test list exists in four places and all four disagree — the yml says 26, its own comments say 25 and 13, and CLAUDE.md says 23 with a 21-branch ctest filter. After: one committed awk parser, fail-closed, self-tested on every run, and every prose copy deleted.

**Today's reality, re-verified at HEAD:** the build `--target` block (`flashida-ci.yml:220-246`) names **26** targets; the `ctest -R` alternation (line **608**, the file's last line) has **24** branches. They agree exactly — 0 uncovered targets, 0 dead branches — because branches are *unanchored regex searches*: `FLASHIda_Logging` covers `FLASHIda_LoggingFields_test` too, `FragmentAnalysis` covers `FragmentAnalysis_toProForma_test`, `MS3FragmentMatcher` covers `MS3FragmentMatcher_identification_test`, and `FLASHIda_LoggingFields` is a redundant branch. **A parser that treats `-R` branches as names silently drops 2 of 26 tests.** All 26 are registered exactly once in `executables.cmake:452-479`.

**Implementation: one POSIX-awk file + one sh wrapper, committed at `docker/ci-lists.awk` and `docker/ci-lists.sh`.** awk is the only language present with zero installs on all three surfaces — mawk 1.3.4 in the ubuntu base, gawk 5.4.0 via Git for Windows. Byte-identical output was demonstrated across gawk/LF, mawk/LF and mawk/CRLF. PowerShell wrappers call the sh script; do not write a second parser.

**Rule 1 — strip `\r+$` from every record FIRST, and validate the parser in the LINUX container, never on the host.** The worktree yml **is CRLF right now** (`git ls-files --eol` → `i/lf w/crlf`, 608 CRs), because `core.autocrlf=true` comes from the system gitconfig with no root `.gitattributes`. On this host gawk, GNU sed and GNU grep all **silently strip CR**, so a naive parser reads 26 targets here and **0 targets under container mawk, exit 0**. `BRANCHES` still parses (the CR sits outside the `-R "[^"]*"` match), so the failure mode is *build nothing, then ctest 24 branches against an empty build dir* → **full silent green**. This is the single most dangerous bug in the whole design.

**Rule 2 — do not use grep for the continuation shape.** `grep 'cmake --build OpenMS/build --target *\\$'` (BRE) returns **0** matches on the real file; ERE and awk return 1. Ship the parser as a `.awk` file invoked with `awk -f`, never as an inline shell string.

**Rule 3 — reconcile by matching relation, not set equality.** 24 ≠ 26 legitimately. Every target must substring-match ≥1 branch; every branch must substring-match ≥1 target. Redundant and 1:many branches are INFO. Cross-check against `executables.cmake` — **dedupe first** (588 unique names from 608 matching lines).

**Three fail-closed conditions, and no bespoke taxonomy.** The parser exits non-zero with a one-line reason on:
1. the workflow file is absent, or does not contain exactly ONE `ctest … -R "…"` invocation (0 = the anchor moved or the quoting changed; >1 = CI grew a second step — **do not let the runner pick one**);
2. zero branches parsed, or a branches string consisting only of delimiters;
3. fewer than `FLCI_MIN_TARGETS` (20) targets parsed.
Plus one reconciliation message that names every uncovered target and every dead branch, and a cross-check against `executables.cmake`. That is the whole guarantee; a version-controlled manifest ratchet and an eight-code error vocabulary buy nothing for a list inside a frozen file that changes a couple of times a year.

**Why condition 2 matters and why the intuition is backwards:** an empty `-R` is version-dependent. On ctest **4.3.3** (this host) `-R ""` matches EVERY test; on ctest **3.28.3** (the container) it prints `No tests were found!!!` and exits **0** — a silent green.

**Ongoing re-validation — the parser is not a one-shot M2 exercise.** Two mechanisms, both cheap:
- `docker/ci-lists.sh --self-test` runs the parser under **container mawk** against the committed yml and asserts the three conditions plus the reconciliation. It is the **first step of every C++ entry point** (`ci cpp`, `ci cpp --full`, `ci dll`, `ci all`), so any `ci` invocation after a yml edit re-validates it. Cost: milliseconds.
- The documented add-a-C++-test ritual (`CLAUDE.md:120`, rewritten) gains a third line: *"then run `ci lists` and confirm the new target appears"*. That is the only place a human touches the two lists, and it is the natural moment to check.
CI itself cannot run the self-test — the yml is frozen and no job invokes `docker/` — and that is accepted: the yml is CI's own source of truth, so a parse failure is a *local* failure by construction.

**Invocation — run the RAW `-R` string verbatim** (so a future over-broad branch is visible), plus local hardening CI does not have:
```
ctest --test-dir <build> -R "<RAW from line 608>" --output-on-failure \
      --no-tests=error --output-junit <build>/flci-ctest.xml
```
`--no-tests=error` is verified on ctest 3.28.3: no-match → exit 0 without it, **exit 8 with it**.

**Post-run gate — never gate on JUnit `failures`.** Verified on 3.28.3: a missing test binary yields ctest **exit 8** but JUnit `tests="2" failures="0" skipped="1"` with `status="notrun"`. Gate on: ctest exit 0 **AND** `<testsuite tests=N>` == |parsed targets| **AND** every target appears once as `<testcase>` **AND** every testcase carries `status="run"`. Also assert every `<build>/src/tests/class_tests/bin/<name>[.exe]` exists after the build (forbid keep-going flags; do NOT use mtime — ccache/ninja legitimately skip relinking). `ctest -N` always exits 0 — parse its lines, never its exit code.

**The yml's prose is not authoritative.** Its own comments say "25 FLASH C++ test exes" (line 19) and "the 13 FLASH C++ test exes" (line 206), and lines 382-385 still assert "A local build cannot produce it either… this is the only path that exists." Since the yml is frozen, `CLAUDE.md` must state: **only the `--target` block, the `-R` line and the pinned tool versions are authoritative; the comments are history.**

**Also parse, do not copy:** the toolchain pins (§4), the `windows-tests` STEP ORDER and per-step `env:` (§4), and `regression-runner.ps1`'s `$configs` name→golden mapping (§7). And note the yml has a **second** `nunit3-console` invocation at line 402 with `--where "test=='…ConfigSchemaParityTests.Reference_IsNeverStale'"` — the C# contract is not "unfiltered only".


---

## 6. Mounts, tree hygiene, and the exit-code contract

> **TL;DR** Before: nothing writes to this tree but git and MSBuild. After: two container engines write into it, three of those writes are invisible to `git status` unless the runner cleans up, and every subcommand has to say plainly whether it passed.

**Build directory names — chosen so NO `.gitignore` commit is needed in either submodule** (verified with `git check-ignore`):

| Path | Ignored by |
|---|---|
| `OpenMS/cmake-build-{linux,msvc}-{release,debug}` | `OpenMS/.gitignore:29 cmake-build-*` |
| `FlashIDA/bin/**` (incl. `log-golden-output/`, `continuity-output/`) | `FlashIDA/.gitignore:26 [Bb]in/` |
| `FlashIDA/test-output/**` | `FlashIDA/.gitignore:34` + parent `.gitignore` |
| `FlashIDA/dependencies/*.dll` | `FlashIDA/.gitignore:31` |
| `FlashIDA/src/packages/**`, `**/obj/` | `:192`, `:27` |

**Never reuse `OpenMS/build`** — that name is reserved for a CI-shaped tree, and reusing it lets a container build masquerade as a CI one.

**// TREE POLLUTION — four sources, all of which the runner must handle:**

1. **`FlashIDA/dll/` is TRACKED** (6 files). CI's drift swap therefore leaves **4 modified tracked files in the submodule after every Windows run**. → `finally`: `git -C FlashIDA checkout -- dll/`, then assert `git -C FlashIDA status --porcelain -- dll/` is empty. **There is no opt-out flag.** The deliberate "update the committed DLLs" workflow is done by hand, once, with the diff shown — inventing a `--keep-dll` lever on the one mechanism whose silent failure is worst is not worth the convenience. Do **not** "improve" the restore into a post-msbuild copy straight into `bin/` — it would work, but it diverges from the only path CI exercises.
2. **`regression-runner.ps1:23-31` copies three files into the CURRENT WORKING DIRECTORY** — `test_inclusion_list.txt`, `test_fasta.fasta`, `test_target_log.log` — none gitignored at the parent root. → runner deletes them in `finally`.
3. **`TestResults.xml` and `RegenResults.xml`** land at the repo root and are not ignored. → same.
4. **The parent `.gitignore` is three lines.** Add `/TestResults.xml`, `/RegenResults.xml`, `/test_inclusion_list.txt`, `/test_fasta.fasta`, `/test_target_log.log`, `/.container-out/` as belt-and-braces. Keeping `git status` clean is not cosmetic — §7's compensating control depends on a dirty status always meaning something.

**Add a root `.gitattributes` BEFORE writing any shell script** (none exists; `core.autocrlf=true`): `*.sh text eol=lf`, `docker/** text eol=lf`, `Dockerfile* text eol=lf`. Otherwise the checkout produces CRLF and the Linux container dies with `bad interpreter: /bin/bash^M`.

**`.dockerignore`:** keep the Dockerfiles in `docker/` and build with `docker/` as the context — BuildKit transferred **2 B** from the 1.6 GB repo root when no `COPY` referenced it. Add a root `.dockerignore` anyway in case a `COPY` is added later.

**Container writes land as root:root on Linux** (`id` → `uid=0`). Pass `--user` or chown afterwards. From Git Bash, `MSYS_NO_PATHCONV=1` is required or container paths are rewritten to drive letters.

**// THE EXIT-CODE AND VERDICT CONTRACT — stated once, for the whole tool.**
- Every `ci` subcommand exits **0 only if every gate it ran passed**, and non-zero otherwise. There is no `|| true` anywhere in the runner; every wrapper starts `set -euo pipefail`.
- Every subcommand's **last line** is one of exactly three verdicts: `PASS: <what was verified>`, `FAIL: <first failing gate>`, or `PARTIAL: <what did not run> — NOT CI-EQUIVALENT`. A human reading only the last line is never misled.
- `PARTIAL` always exits **non-zero**. It is used by `ci cs <filter>`, by `ci all` when one engine is unavailable (§10), and by any run that skipped a gate.
- `ci all` aggregates: it runs Linux, then Windows, prints a two-line summary, and exits with the **worst** of the two — never 0 if either leg was FAIL or PARTIAL.

**// CONCURRENCY AND OWNERSHIP:** a second Claude session shares this workspace and is actively pushing. Tag every image with a session-unique suffix, **never `docker system prune` from tooling** (image and volume pruning is the user's call alone, and `ci doctor` prints the current 40–60 GB footprint so they can make it), `git pull --rebase` in all three repos immediately before each push, and check the `Claude-Session:` trailer before touching any unexpected change.


---

## 7. The golden gate — which currently does not fire, and which only ever sees this agent

> **TL;DR** Before: the brief assumes `golden-write-guard.sh` keeps firing and the diff reaches the user. After: it is proven not to, its scope is proven narrower than assumed, and the guarantee is rebuilt from layers that survive both.

**Finding 1 — the hook does not fire on the container paths.** Executed against realistic payloads:

| Command | Verdict today |
|---|---|
| `cp out.tsv FlashIDA/test-data/golden/phase4_x.tsv` | **GATED** ✓ |
| Write/Edit tool to a golden path | **GATED** ✓ |
| `docker exec flashwin powershell -File capture-goldens.ps1` | **ALLOWED** ✗ |
| `docker run -v .../FlashIDA/test-data/golden:/g img capture` | **ALLOWED** ✗ (names the dir!) |
| `docker run -e LOG_GOLDEN_CAPTURE=1 … nunit3-console.exe` | **ALLOWED** ✗ |
| `bash -c "cp a.tsv FlashIDA/test-data/golden/x.golden.tsv"` | **ALLOWED** ✗ — no docker involved |
| Anything at all through the **PowerShell tool** | **NOT EVALUATED** ✗ |

Three independent root causes: `.claude/settings.json` matchers are the literal string `Edit|Write|Bash` and the shell tool here is named **`PowerShell`**; the extractor `grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"'` **truncates at the first escaped quote**, so any quoted command evades it; and the write-verb `case` has no `docker`, so even a hit falls through to `*) exit 0`.

**Finding 2 — and this one bounds the whole design.** PreToolUse hooks only ever see **this agent's** tool calls. The entire point of local verification is that the human runs `ci` in their own terminal, where **no hook exists on any path**. So of the four layers below, only **L1** and **L4** survive a direct human invocation. That must be written into `docker/README.md` and `CLAUDE.md` rather than discovered.

**The compensating control — four layers, cheapest first.**

**L0 (host, must land BEFORE the first container capture; protects agent-initiated writes only).** `.claude/settings.json`: the PreToolUse matcher → `Edit|Write|Bash|PowerShell`. `golden-write-guard.sh`: fix the extractor to handle `\"`; add `docker|docker compose|podman|robocopy|xcopy|Copy-Item|Move-Item|Set-Content|Out-File|msbuild|nunit3-console|ctest|regression-runner` to the verb list; add case-insensitive `golden` plus the tokens `LOG_GOLDEN_CAPTURE|REGEN_CONFIG_REFERENCE|captureMode`. **These files are under `.claude/` and only the user may authorize the change.** Re-run the 12-case matrix afterwards. (Widening `golden-change-detector.sh`'s pathspec beyond `test-data/golden` is deliberately **deferred** — it would fire on ordinary fixture edits its author excluded, and it pre-empts the unresolved question of whether the container may regenerate `config_schema_reference.json` at all.)

**L1 — never set `LOG_GOLDEN_CAPTURE` at all.** The key simplification, and it needs **zero code changes**. `FLASHIdaLogGolden_test` writes `<stream>.normalized` into `FlashIDA/bin/log-golden-output/<case>/` **unconditionally**, from the same `normalized` string `CaptureGolden` would write — promotion is a pure rename `.normalized` → `.golden.tsv`. A *failing* comparison run is therefore already the capture. Consequence: the container never writes into `test-data/golden`, and the golden tree can be mounted `:ro` on every entrypoint. The other two sets are already staging-only — `regression-runner.ps1 -captureMode` writes only to its `-OutputDir`, and `ContinuityTests.AssertGolden` always writes `bin/continuity-output/` and never touches `GoldenDir`. **L1 is mechanical: it holds no matter who typed the command.**

**// COST OF L1:** the all-five-streams capture guard (`FLASHIdaLogGolden_test.cs:1595-1613`) only runs inside `if (Capture)`. The runner must therefore assert it itself: exactly **25** case directories × **5** non-empty `.normalized` files. It must also assert the fixture inventory first (24 `ms3_cytc_*_scan*.txt`, 17 `ms3_cytc2_*`, 6 `ms2_cytc_ce*`, `configs/method_exploration_etd.json`), because **12 of the 31 log-golden tests `Assert.Pass` and return when their fixtures are absent**.

**L2 — mount `FlashIDA/test-data/golden` read-only** on every entrypoint. moby's `daemon/oci_windows.go:110-118` does emit `ro` for non-writable Windows bind mounts. **// UNPROVEN on Windows:** a `:ro` overlay on a subdirectory of an rw bind is untested. L2 is an optimisation; L1+L4 are the guarantee.

**L3 — promotion is a plain host-side Bash `cp`, and there is no `ci` subcommand for it.** This resolves a real contradiction: `./ci golden-promote …` would set the guard's `hit=1` via the `*[Gg]olden*` fallback and then fall straight through the write-verb `case` to `*) exit 0` — **allowed**, even after L0 as specced. The one command shape verified gated is a bare `cp`. So: `ci golden-diff` renders the before/after **in cells** and, at the end, **prints the exact `cp` lines** for the cells that moved; the operator (or the agent) runs them. Deliberately not `robocopy`, not `Copy-Item`, not a wrapper. "Patch, do not promote" — a whole-file promotion also rewrites column order and bakes in that run's float jitter.

**L4 — an unconditional `git status` assertion inside every runner invocation.** `git -C FlashIDA status --porcelain -uall -- test-data`, run as the **last foreground action of every subcommand**, with **no flag that disables it** and no code path that skips it. Non-empty on a non-capture run → print the paths, `git -C FlashIDA checkout -- test-data/golden`, exit non-zero. This is the only layer that survives someone reaching for the PowerShell tool or their own terminal, so it carries no bypass. **// FORBID `run_in_background` for any container step that writes into the repo** — the PostToolUse detector runs before the container has written. **// KNOWN HOLE:** `FlashIDA/.gitignore:86 *.tmp` blinds the detector to `.tmp` files in the golden tree.

**The three sets and their promotion rules:**

| Set | Files | Staging | Promotion |
|---|---|---|---|
| Log goldens | 125 (25 modes × 5 streams — `CLAUDE.md`'s "22" is stale) | `bin/log-golden-output/<case>/*.normalized` | per-file `cp`, rename to `.golden.tsv` |
| Regression TSVs | 13 | `test-output/phase4-golden/*.tsv` | **prefer the CI artifact — see below** |
| Continuity JSONs | 17 | `bin/continuity-output/*.json` | per-file `cp` |
| *(4th, outside the guard)* `config_schema_reference.json` | 1 | rewritten in place by `REGEN_CONFIG_REFERENCE=1` | opt-in flag, default OFF, only after the unfiltered suite |

**RECOMMENDATION: do not promote regression TSVs from a local capture.** `compare_golden.py` uses `REL_TOL=1e-4` — ten times tighter than the C# comparer's `1e-3` — leaving only ~2.6x headroom over the worst observed cross-build drift (3.79e-5). Prefer the CI `phase4-golden-capture` artifact. That one decision also removes the `$configs` mapping trap (3 of 14 cases are non-identity: `p1_json` → `baseline_phase0.tsv`, `p4_legacy_path` → `baseline_phase3.tsv`, `p7_exploration` → `phase7_exploration.tsv`, and `baseline_phase0.tsv` is shared by two cases).

**Determinism, honestly.** A ccache-warm container relinks a bit-identical DLL, so local float jitter goes to zero. **That is not evidence the tolerance is unnecessary** — CI links a different DLL every run by construction. Conversely a locally pinned MSVC introduces a *systematic* offset CI has never seen. And the real hazard is not the tolerance but the **cliff**: rows, ids, counts and ordering compare exactly in all three comparers, so a jittered score crossing a selection threshold flips a discrete outcome no tolerance absorbs. Mitigation is free: **a green CI run on the push carrying the golden is the acceptance test for every local capture.**


---

## 8. The bootstrap paradox, the provenance gate, and when to stop trusting a container

> **TL;DR** Before: the change that introduces the containers cannot have been verified by them, and there is no answer to "CI and the container disagree, now what". After: the question is split in three, the old system answers the part that needs answering at commit time, and disagreement has a written rule.

**(a) "Do the containers work?" — answered BEFORE any commit, by calibration.** Iterate both Dockerfiles entirely uncommitted against a SHA whose GitHub verdict is already published. The anchor is **run 33083942633** (parent `9bcfc82`, completed **success** 2026-08-27): C# NUnit `total=181 passed=180 failed=0 skipped=1` (the skip is `ContinuityTests.P4_AL_CT42_DeepMode_TargetLogEffect`) and ctest **26/26**, `Total Test time (real) = 2109.38 sec`. Acceptance: the Windows container reproduces those two numbers exactly; the Linux container reproduces the *set* of 26 and its failures are triaged, not assumed. Record the SHA + run id in `docker/README.md`.

**// BUILD FROM A CLEAN SHA, NOT THE LIVE TREE.** The OpenMS submodule currently has uncommitted work from the concurrent session. Calibration must use `git worktree add` (or `git archive`) at the anchor SHA, or you are comparing a published CI result against a tree that includes another agent's in-flight ADR-0036/0037 work.

**(b) "Did committing them break anything?" — answered by the EXISTING CI.** Every file in the first landing is either a new parent-root file no build step reads, or markdown, or a `.claude/` hook. Verified inert: no path filters, no `Directory.Build.*`/`nuget.config` walk-up anywhere, `Flash.sln` references only two csprojs, and the only MSBuild wildcard resolves inside `FlashIDA/`. **Predeclare the expected verdict** — 3/3 jobs green, C# 181/180/0/1, ctest 26/26, zero golden movement — so anything else is a finding rather than something to fix forward.

**(c) "What may the containers decide, forever?" — bounded at design time.** Authoritative for "gcc compiles this" and "the C# suite passes here". NEVER authoritative for "MSVC still compiles this" or "the goldens are right". Those stay CI-gated for the life of the tooling (§1's table).

**THE PROVENANCE GATE (§4 step 5), corrected.** CI gets bridge/ABI drift detection emergently from a fresh checkout + `needs: build` + a one-shot filesystem; all three vanish locally, so it must be asserted. Three checks, run before NUnit, printing all three values every run:

| # | Assertion | Catches | Limitation, stated |
|---|---|---|---|
| a | `sha256(FlashIDA/bin/OpenMS.dll) == sha256(<build>/bin/OpenMS.dll)` | the `PreserveNewest` skip, an interrupted swap | — |
| b | **`FlashIDA/bin/OpenMS.dll` differs from `git -C FlashIDA show HEAD:dll/OpenMS.dll`** | testing the committed, known-stale June-2026 DLL | **false-red if someone deliberately commits a rebuilt DLL.** Because there is no `--keep-dll` flag (§6) that workflow is a rare, manual, diff-reviewed act; when it happens, re-run after committing and the check passes on the new HEAD. A gate that cries wolf is a gate people bypass, so this one is *scoped* rather than softened. |
| c | `mtime(<build>/bin/OpenMS.dll)` newer than the newest file under **`OpenMS/src/openms/{source,include}/`** *(the whole library tree, not only `.../ANALYSIS/TOPDOWN/`)* | "edited the engine, forgot to rebuild" — locally the DEFAULT failure mode, in CI unreachable | still blind to changes **outside** the OpenMS source tree that affect the DLL: CMake flags, the contrib tarball, the toolchain. Those are covered instead by §4's toolchain-pin assertion and by rebuilding on any `cmake-build-*/CMakeCache.txt` change. Say so at the call site. |

**Where CI is the PRIMARY oracle, not a backstop.** Landing 3 (OpenMS portability fixes, if M3/M6 need any): only GitHub compiles MSVC. A Linux-green source change is *unverified* until CI confirms MSVC still accepts it and the goldens still match. Any red → STOP and re-plan; no fix-forward.

**// TRUST REVOCATION — the written rule for "they disagree".** Not a risk-row mitigation; a policy, in `docker/README.md`:
1. **Container green, CI red on a FLOAT-ONLY diff** → the container's DLL is a different binary. Discard the local capture, promote the CI artifact, continue using the containers.
2. **Container green, CI red on a STRUCTURAL diff** (rows, ids, counts, ordering, a test that passes locally and fails remotely) → **stop capturing goldens locally immediately.** Record the container's `vs.buildversion` / `contrib.tag` / `qt` labels and the CI run id in `docker/README.md`, and treat the Windows container as compile-and-smoke only until a fresh calibration against a new green CI run reproduces its two numbers exactly. Golden capture resumes only after that recalibration.
3. **Container red, CI green** → the container is wrong. Fix the container; never edit a test to make it agree.
4. **Kill switch.** `ci` is a committed script and `.github/workflows/flashida-ci.yml` is untouched, so backing the whole thing out is `git revert` of the `docker:` commits plus reverting the two `.claude/` hook commits. Nothing in the build, the tests or the goldens depends on the containers existing.

**Standing rule that keeps Landing 3 small:** prefer a container-side change (flags, `-isystem`, build scope, not using `-Werror`) over ANY source change — a container change is a parent commit with no CI round trip while a source change is a ~60 min cycle against the shipped engine.


---

## 9. The AI-instruction rewrite

> **TL;DR** Before: two CLAUDE.md files say "do not build", a third carries four CI-locality claims, six plan documents tell implementers not to build, and the parent hand-copies a build command and a test list that are already wrong. After: the containers are the inner loop, every duplicated list is deleted rather than corrected, and the sweep is grep-driven rather than sampled.

**Ownership rule, verbatim from `CLAUDE.md:243-256`:** the parent owns "CI, testing, goldens, config flow" and is authoritative on conflict; `FlashIDA/CLAUDE.md` is C# only; `OpenMS/CLAUDE.md` is the C++ engine only. **So the container system as a system belongs entirely in the parent.**

**The principle that decides most of these edits: delete duplicated lists, do not correct them.** Four numbers in the parent file are wrong today (`:49` "23 named FLASH test binaries" vs 26; `:56` "…22 total"; `:116` a 21-branch ctest filter vs 24; `:52` `-DWITH_GUI=OFF` vs the yml's `ON`). **Correcting them and then deleting them in the same landing is pure churn** — so there is no separate "fix the numbers" commit; the deletion in the docs commit is the fix. Replacement text: *"The build targets and the ctest `-R` alternation are NOT reproduced here. Both containers and CI read them out of `.github/workflows/flashida-ci.yml`. Any such list you find written out in prose is stale by construction. The yml's own prose comments are historical — only its `--target` block, its `-R` line and its pinned tool versions are authoritative."*

**Parent `CLAUDE.md` — the load-bearing rewrites** (full list in `instructionChanges`): line 32 → the containers are the inner loop and CI is the clean-checkout backstop; line 46 → build it in the Linux container; lines 49/51-54/56/116 deleted; line 89/98 (golden recapture) → local capture primary, CI artifact fallback, sign-off unchanged; line 44 (Thermo DLLs) → decrypt on the host, bind-mount, **never a Dockerfile ARG/ENV**; line 120 (both-lists rule) **strengthened**, plus the new third line "then run `ci lists`"; lines 24/26 s/CI paths/test paths/. **New section `## Local verification (two containers)`** — images, wrapper scripts, the exit-code/verdict contract, Release-default with `--debug`, **the C#-is-always-Debug|Any CPU exception**, the yml-parsing contract, the locale pin, the golden path, **"the containers verify your working tree; CI verifies a commit"**, **what stays remote-only** (§1's list), and "green containers before you push".

**`FlashIDA/CLAUDE.md` — 8 edits, not 4.** The four already identified: `:188` (the container **must pin en-US and assert the pin**, because `MockMsScan` parses every fixture value with a bare culture-sensitive `double.Parse` and this host is de-DE); `:360-361` (a ccache-warm container can relink an identical DLL, so **zero local jitter is not evidence the tolerance is unnecessary**); `:374-379` (the container must **reproduce** the DLL swap, not skip it); `:44-45` ("no CI job" → "neither a CI job nor a container"). Plus four CI-locality claims the first pass missed: **`:6`** ("parent owns CI, build commands" → "…and the local container system"), **`:23`** ("this is what CI builds and tests" → "…what CI and the Windows container build and test"), **`:46`** ("the CI golden-capture step" → "the CI and container golden-capture steps"), **`:159`** ("CI paths" → "test paths").

**`OpenMS/CLAUDE.md` — 4 edits.** Line 13 → build it in the Linux container; it cannot produce `OpenMS.dll`. Lines 552-555 → s/executes in CI/executes at all — in CI or in either container, which parse those same two lists/. Lines 568-571 → the **two-toolchain reality**: MSVC/Release ships the DLL and compiles out `OPENMS_PRECONDITION`; the Linux container is gcc/clang with Debug behind a flag; a Linux-green change is not MSVC-green; Linux class-test TUs are **`-O0` even in Release**. Line 558-559 → the 5-DLL staging is **Windows-only**.

**// DEBUNK, do not repeat:** "a Debug Linux build adds `OPENMS_PRECONDITION` coverage" is a bad justification — `grep OPENMS_PRECONDITION` over the whole TOPDOWN tree returns **0**, and the single `assert(` there is commented out. Sell Debug on assertions in OpenMS *core* and on being the only Linux configuration ever proven green.

**`docs/kb` — exactly two lines.** `scan-pipeline/bridge-functions.md:71` "Rebuild `OpenMS.dll` (CI does this)" → name the Windows container. `config-flow/config-flow.md:173` s/CI-gated/test-gated/. **No new KB packet** — the parent's new section holds it; proposing an 8th packet is speculative future work, not a plan item.

**`docs/adr` — KEEP AS A CLASS, and no ADR is edited.** No ADR prescribes CI-only verification; every hit is descriptive history. ADR-0025's "no tool substitutes" TSan argument is now MSVC-scoped (a Linux build dir produces no DLL and gcc has `-fsanitize=thread`) — that observation goes in `docker/README.md`, **not** into the ADR. Editing an accepted ADR to add a tooling footnote is unrelated to making verification local, and there is zero precedent for tooling ADRs. **Whether a new ADR is even the right vehicle is an open question** — all 36 record engine/acquisition decisions; `docs/superpowers/specs/` may be the conventional home.

**`.claude/skills/validate-flashida-config/SKILL.md:122-125`** — "A local build cannot regenerate it … so CI does it" → the Windows container regenerates it directly. **Preserve the ordering warning verbatim.**

**`docs/superpowers/plans/` — six files, not one.** All carry live "CI-only build" / "do NOT build locally" directives that a future implementer will follow: `2026-06-24-characterization-proteoform-tracker.md:20,35,276` (APPROVED, not implemented — the one that will actually be executed), `2026-08-12-exhaustive-characterization-mode.md:9,191`, `2026-06-11-test-falsepass-mitigation.md:507`, `2026-06-19-processscan-cleanup.md:101`, `2026-04-20-charge-based-exclusion.md:410,752`, `2026-04-20-kb-scan-pipeline.md:343`. Rewrite the Working-Agreement lines in the approved-not-implemented one; for the completed-work records, a one-line header note ("the CI-only build rule in this document was superseded on <date>") is enough — they are point-in-time records.

**Memory (outside git, no CI cost) — grep-driven, not sampled.** The directory holds **105** files, of which **65 mention CI**. The honest scope is a single sweep for the phrasings *"CI is the only"*, *"cannot build locally"*, *"no local build"*, *"CI round trip"*, *"push to verify"*, *"resource-intensive"*, across all 105 — **report the count checked**, per the citation-drift lesson. Known targets from that sweep: DELETE/replace `reference-no-local-build.md`, which is cited by **7 files / 9 lines** (`deployed-dll-is-stale-vs-august-abi.md:34`, `feedback-always-watch-ci-after-push.md:16`, `lesson-citation-drift-needs-a-separate-pass.md:28`, `lesson-raw-string-delimiter-mod-names.md:39,:43`, `MEMORY.md:57`, `project-adr-0026-scan-range-binding.md:43`, `reference-csharp-config-typecheck-harness.md:11,:59`) — no skill cites it. Also `reference-toppic-feature-file-verification.md:11` ("No local build exists in this workspace"), which the first pass missed. Rewrite: `reference-golden-recapture-promotion.md` (container-first; **preserve** the `.normalized` byte-identity proof and the skip-the-2-non-golden-modes warning), `feedback-always-watch-ci-after-push.md` (**demote, do not delete**), `feedback-fine-grained-commits-and-ci-push.md`, `ci-green-baseline-2026-08-08.md` (record *how to derive*, not a number), `ci-windows-build-once-split-and-test-exe-gotchas.md` (13→26; the deleted Ubuntu job is what the Linux container resurrects), `reference-csharp-config-typecheck-harness.md` (**keep the harness** — 2 s beats any container msbuild). Keep intact: `feedback-never-write-goldens-without-showing-diff.md` (more important, not less), the two golden-diff-methodology lessons, `lesson-gh-run-watch-rate-limit.md`, `python-via-uv.md`.

**Also:** `.superpowers/sdd/` (untracked) carries subagent BRIEF TEMPLATES saying "Build CI-only", "Verify (reason, do not build)", "You cannot run tests (CI-only)" — rewrite or delete, or future implementers will be told not to use the containers.


---

## 10. The local command surface

> **TL;DR** Before: five commands with load-bearing flags and a load-bearing order, none runnable here. After: one dispatcher with a tiered default, every load-bearing detail encoded in it, and one verdict line at the end of every run.

One dispatcher: `ci` (bash, repo root, for Git Bash) and `ci.ps1` (a thin shim that calls it). **Address engines by their stable named pipes, never by `docker context use`** — Docker Desktop re-points the generic `docker_engine` pipe on switch: `docker -H npipe:////./pipe/dockerDesktopLinuxEngine …` and `docker -H npipe:////./pipe/dockerDesktopWindowsEngine …`.

| Command | Engine | Cost | What it does |
|---|---|---|---|
| `ci doctor` | — | s | engine mode + isolation, `Containers` feature state, images, **Thermo DLL identity gate (absent = FAIL, never skip)**, `git status` across all 3 repos, contrib, python-in-image, locale, ccache size, total disk footprint |
| `ci doctor --compare-ci` | — | s | fetch the latest green `openms-fresh-dll`, print both DLL sha256 and both configure lines (informational; §4) |
| `ci lists` | — | ms | parser self-test + reconciliation; **runs automatically as step 1 of every C++ entry point** |
| `ci cpp <name…>` | Linux | s–min | build + run only those targets — **the real inner loop** |
| `ci cpp` | Linux | ~5 s (after build) | fast tier: the 26 minus anything over `--slow-threshold` in the last run's JUnit timings |
| `ci cpp --full` | Linux | ~25–35 min | all 26, `-j 6`, `OMP_NUM_THREADS=1` |
| `ci cpp --debug` | Linux | slower | separate build dir; the only Linux config ever proven green |
| `ci cpp --msvc <name…>` | Windows | min | **targeted triage only.** There is no `--msvc --full`: running all 26 on MSVC locally duplicates CI's `cpp-tests` job on the toolchain CI is authoritative for, for ~35 min. The Windows container's job is the DLL and the C# side. |
| `ci dll` | Windows | 20–30 min cold / ~1 min warm | build `OpenMS.dll`, swap 4, assert provenance |
| `ci cs` | Windows | ~28 min | `ci dll` + restore + msbuild(Debug\|Any CPU) + **unfiltered** NUnit + all 4 gates + regression + cleanup |
| `ci cs <filter>` | Windows | s–min | filtered. Exits **non-zero** with `PARTIAL: bridge-smoke and TRACK-CREATE gates did not run — NOT CI-EQUIVALENT`, and writes `TestResults.xml` to a different path so the gate cannot read it |
| `ci golden-diff` | Windows | ~28 min | full compare, rendered cell-level diffs, **read-only**; ends by printing the exact `cp` lines for the cells that moved |
| `ci all` | both | ~1 h | Linux first, Windows last; exits with the worst of the two |
| `ci clean` | — | s | wipe build dirs, `bin/`, `test-output/`; restore `FlashIDA/dll/`; delete the 5 stray root files. **Never touches `FlashIDA/dependencies/`** — those are host state (§4) |

There is deliberately **no `ci golden-promote`** (§7 L3: the wrapper form is the one shape the guard does not gate) and **no `--keep-dll`** (§6).

Defaults: **Release** for C++, `--debug` selects a separate build dir. **C# is always `Debug /p:Platform="Any CPU"` and there is no flag for it** — that is the exception, and the reason is in §4.

**Every filtered NUnit and ctest invocation asserts its selected count.** Verified against real NUnit 3.16.3: `--where "bogusselector == 'Foo'"` and an unqualified `class == 'FLASHIdaLogGolden_test'` **both** produce `Test Count: 0, Overall result: Passed, exit 0`. `class` needs the fully namespace-qualified name — and `ContinuityTests` lives in `Flash.Tests.AcquisitionLoop`, not `Flash.Tests`. Always pass `--result=<xml>` and parse `total=`.

**The engine switch, and its fail-closed mode.** M5 decides which of three worlds we are in:

| M5 outcome | `ci all` behaviour |
|---|---|
| `SimultaneousWindowsAndLinuxContainers` works | both pipes live; `ci all` fans out Linux-ctest ∥ Windows-build with **zero user interaction**, exits 0 on full green |
| Only `DockerCli.exe -SwitchDaemon` leaves both reachable | same, after a one-time switch the user performs once |
| Neither | **`ci all` runs everything possible on the current engine, writes phase state, prints one line telling the user to switch and re-run `ci all --resume`, and exits NON-ZERO with `PARTIAL: the Windows leg did not run — no DLL build, no ABI provenance gate, no 181-test suite, no gates, no regression. NOT CI-EQUIVALENT.`** A user who never resumes gets a failure, not a line of text. `--resume` completes the run and only then can the aggregate exit 0. |

**Never switch the daemon from inside a script the user is watching** — `-SwitchDaemon` takes 20–60 s, may prompt for elevation, and kills every running container including the one you are in. Order Windows LAST in every case — it produces the artifacts a human then reviews.

**Explicitly out of scope for this plan:** wiring the two unwired scripts (`check_cpp_config_fixtures.py`, `prepare-test-data.py`). `check_cpp_config_fixtures.py` is a genuine pre-existing gap — it exists because a re-indent turned `R"({…})"` into a string starting with a newline and broke **120 C++ tests** in a way the value gate structurally could not see — but folding it in is a separate change riding along on the container work, and it collides with Landing 1's no-test-changes commitment. Record it as a follow-up, do not do it here.


---

## 11. Delivery

> **TL;DR** Before: a pile of commits across 3 repos with no obvious safe order. After: one push that CI can vet, two conditional follow-ons, and an explicit rule that fine-grained COMMITS do not mean one push each.

**Batching rule, stated as a decision.** `flashida-ci.yml` has **no path filters**, so every parent push costs a full ~57–68 min run — and run 32984975738 sat **queued for 24 h**. The fine-grained-commits agreement is about reviewability and revertability of *commits*, not push count, and recent history already lands multi-file doc sets in single pushes (`d884f4b`, `58f80a5`, `9bcfc82`). **Fine-grained commits, batched landings.**

**Pre-flight (before Landing 1):** wait for run 33089853328 (`e1b5587`) to complete — otherwise the baseline is ambiguous; `git pull --rebase` in all three repos; confirm all three clean and the gitlinks in sync; check `Claude-Session:` trailers on anything unexpected.

**LANDING 1 — 8 commits, 3 repos, 3 git pushes, 1 CI run.** Push submodules first (or the gitlinks dangle).

| # | Repo | Subject |
|---|---|---|
| 1 | parent | `hooks: gate golden writes that arrive through a container or PowerShell` — settings matcher + guard extractor/verbs/tokens. **Needs explicit user authorization (`.claude/`).** Must precede the first capture. |
| 2 | parent | `docker: derive the C++ target and ctest lists from flashida-ci.yml` — `ci-lists.awk`, `ci-lists.sh`, the reconciliation, the self-test. **Its own commit**: highest chance of a subtle bug, most likely to need reverting alone. |
| 3 | parent | `docker: a Linux container that builds libOpenMS.so and runs the FLASH ctests` |
| 4 | parent | `docker: a Windows container that reproduces the CI toolchain end to end` |
| 5 | parent | `docker: one dispatcher for both containers` — `ci`, `ci.ps1`, `.gitattributes`, `.dockerignore`, `.gitignore` |
| 6 | **OpenMS** | `CLAUDE.md: building is local now — the container, not CI, is the inner loop` |
| 7 | **FlashIDA** | `CLAUDE.md: the test host must be en-US, and the container reproduces the DLL swap` — the 8 edits from §9 |
| 8 | parent | `docs: local containers as the day-to-day gate` — `CLAUDE.md` rewrite + new Local-verification section + `docs/kb` ×2 + `SKILL.md` + the six plan-doc headers + `docker/README.md` + **both** gitlink bumps |

Commands: `git -C OpenMS pull --rebase && push` → `git -C FlashIDA pull --rebase && push` → `git pull --rebase && push` → **one** `gh run watch <id> --exit-status` in the background.

**Note there is no "fix the CLAUDE.md counts" commit.** §9's rule is delete-don't-correct, and commit 8 deletes exactly the lines a correction commit would have touched.

**Predeclared success:** 3/3 jobs green; C# `total=181 passed=180 failed=0 skipped=1`; ctest **26/26**; zero golden movement; `git status --porcelain` clean in all three repos after a container run. Anything else is a **finding** → STOP, re-enter plan mode, re-approval. No fix-forward.

**LANDING 2 — memory rewrites.** Outside git, no CI, no push. Do it alongside Landing 1's CI wait: the grep-driven sweep across all 105 memory files (report the count checked), the `reference-no-local-build` replacement + its 9 citations, the 7 rewrites, the `MEMORY.md` index lines and the `## CI / build` → `## Build / verification` heading. Plus `.superpowers/sdd/` templates.

**LANDING 3 (CONDITIONAL) — OpenMS portability fixes.** Only if M3/M6 need source changes. **Check the file against `OpenMS/CLAUDE.md`'s untouchable-boundary table FIRST** — a hit is a plan collision → STOP and ask, enumerating the exact files. One OpenMS commit per logical fix class, push OpenMS, then a parent `Bump gitlink: <what>`, push, watch. **CI is the PRIMARY oracle here**: only GitHub compiles MSVC. Expect ≥1 round.

**LANDING 4 (CONDITIONAL) — goldens. Own push, always last.** Non-golden landings fully green → run the suite normally in the Windows container → collect `.normalized` / `continuity-output/` → `ci golden-diff` → **show the owner concrete before/after in cells** → fresh sign-off → **run the printed `cp` lines** on the host, patching only the moved cells (the write trips the guard; that is the gate working) → FlashIDA submodule commit + parent gitlink bump → push → CI confirms against its own freshly-linked DLL. **Prefer the CI artifact over a local capture for the 13 regression TSVs** (§7). If CI comes back red on a structural diff, §8's trust-revocation rule applies.

**Process obligations to carry into execution:** native plan mode (`EnterPlanMode` → plan file → `ExitPlanMode`); **test-change sign-off at Landing 1's planning stage**, covering the explicit scope commitment that **no existing NUnit or ctest file — and no test helper — is created, edited, migrated or deleted** (this is why the `freshLogDir` drift-guard assertion and the `check_cpp_config_fixtures.py` pre-step were both cut from this plan); any failure → STOP + re-plan in the 5-part structure; and one `gh run watch` at a time.


---

## File manifest

| Action | Repo | Path | Purpose |
|---|---|---|---|
| create | `parent` | `docker/ci-lists.awk` | The single reader of .github/workflows/flashida-ci.yml. CR-stripping first, backslash-continuation walk, -R extraction, and the toolchain pins (Qt version, contrib tag). Invoked with `awk -f`, never inline. |
| create | `parent` | `docker/ci-lists.sh` | sh wrapper: reconciliation by substring relation, three fail-closed conditions (no file / not exactly one -R / count below floor), one reconciliation message, and --self-test which runs the parser under container mawk. Called as step 1 of every C++ entry point. |
| create | `parent` | `docker/linux/Dockerfile` | ubuntu:24.04 pinned by digest + the verified 20-package apt set. No contrib tarball, no Qt install action. |
| create | `parent` | `docker/linux/entrypoint.sh` | Configure under --network none, build, tier the ctest set from the previous run's JUnit timings, run with --no-tests=error --output-junit, JUnit status=run gate, fixture-inventory assertion, verdict line. |
| create | `parent` | `docker/windows/Dockerfile` | framework/sdk:4.8-20250909-windowsservercore-ltsc2022 + VCTools 14.44.17.14 + Win11SDK 26100 + vc_redist + choco(ninja cmake ccache 7zip eigen python312) + aqt Qt 6.8.3 (qtbase qtsvg) + pinned contrib + Set-Culture en-US + toolchain LABELs. Build fails if a pin disagrees with the parsed yml value. |
| create | `parent` | `docker/windows/entrypoint.ps1` | The windows-tests step sequence in CI's order WITH CI's per-step env:, plus the locale assertion, the three-part provenance gate, the four gates, the cl.exe version warning, and the finally-block cleanup. |
| create | `parent` | `docker/README.md` | The authority boundary table, what stays remote-only, working-tree-vs-commit, the calibration record (SHA + CI run id + expected counts), the documented divergences from CI (WITH_GUI=OFF, no wizard, qtimageformats), the ADR-0025 TSan scoping note, the trust-revocation policy, and the never-push constraint. |
| create | `parent` | `ci` | The dispatcher (bash). Named-pipe engine addressing, tiering, count assertions, the PASS/FAIL/PARTIAL verdict contract with non-zero exit on PARTIAL, unconditional git-status assertion as the last foreground action. |
| create | `parent` | `ci.ps1` | Thin PowerShell shim over `ci` so no second parser or second command surface exists. |
| create | `parent` | `.gitattributes` | NEW at root (none exists, core.autocrlf=true). `*.sh text eol=lf`, `docker/** text eol=lf`, `Dockerfile* text eol=lf` — without it the Linux container dies with `bad interpreter: ...^M`. |
| create | `parent` | `.dockerignore` | Belt-and-braces; the build context is docker/ so BuildKit transfers ~2 B today, but a future COPY would pull 1.6 GB. |
| modify | `parent` | `.gitignore` | Add /TestResults.xml, /RegenResults.xml, /test_inclusion_list.txt, /test_fasta.fasta, /test_target_log.log, /.container-out/. Currently 3 lines and covers none of the container-run byproducts. |
| modify | `parent` | `.claude/settings.json` | PreToolUse golden-guard matcher Edit|Write|Bash -> Edit|Write|Bash|PowerShell. PROVEN gap: the PowerShell tool matches none today. Optionally a narrow permissions.allow for docker + the two wrappers. NEEDS USER AUTHORIZATION. |
| modify | `parent` | `.claude/hooks/golden-write-guard.sh` | Fix the command extractor (grep -o '"command"..."[^"]*"' truncates at the first escaped quote, so any quoted cp evades it); add docker/podman/robocopy/Copy-Item/Move-Item/Set-Content/Out-File/msbuild/nunit3-console/ctest/regression-runner to the write-verb case; case-insensitive golden + LOG_GOLDEN_CAPTURE|REGEN_CONFIG_REFERENCE|captureMode tokens. NEEDS USER AUTHORIZATION. |
| modify | `parent` | `CLAUDE.md` | Rewrite :32/:46/:44/:89/:98/:120, caveat :24/:26/:77, DELETE the duplicated configure block :51-54 and the ctest alternation :116 and the counts :49/:56, add the `## Local verification (two containers)` section incl. the C#-is-always-Debug rule, the exit-code contract, working-tree-vs-commit, what stays remote-only, and the yml-comments-are-history note. |
| modify | `parent` | `docs/kb/scan-pipeline/bridge-functions.md` | Line 71: 'Rebuild OpenMS.dll (CI does this)' -> the Windows container, or CI. |
| modify | `parent` | `docs/kb/config-flow/config-flow.md` | Line 173: s/CI-gated/test-gated/ so the guard is not read as locally unreachable. |
| modify | `parent` | `.claude/skills/validate-flashida-config/SKILL.md` | Lines 122-125: 'A local build cannot regenerate it, so CI does it' -> the Windows container regenerates it. PRESERVE the after-the-unfiltered-suite ordering warning verbatim. |
| modify | `parent` | `docs/superpowers/plans/2026-06-24-characterization-proteoform-tracker.md` | APPROVED-but-not-implemented, so a session WILL execute it. Rewrite the Working Agreement lines at :20, :35, :276 ('Build/test in CI only. One push -> one CI run'). |
| modify | `parent` | `docs/superpowers/plans/2026-08-12-exhaustive-characterization-mode.md` | One-line superseded header note; :9 and :191 carry CI-only build directives. Completed-work record, so no body rewrite. Same treatment for 2026-06-11-test-falsepass-mitigation.md:507, 2026-06-19-processscan-cleanup.md:101, 2026-04-20-charge-based-exclusion.md:410/:752, 2026-04-20-kb-scan-pipeline.md:343. |
| modify | `OpenMS` | `CLAUDE.md` | Line 13 ('Do not build this project') -> build it in the Linux container; :552-555 s/executes in CI/executes at all, in CI or either container/; :568-571 the two-toolchain reality incl. Linux class tests being -O0 in Release; :558-559 the 5-DLL staging is Windows-only. |
| modify | `FlashIDA` | `CLAUDE.md` | 8 edits (not 4): :6 parent owns the container system too; :23 'what CI and the Windows container build and test'; :44-45 neither a CI job nor a container can execute Flash.Flash; :46 the CI AND container golden-capture steps; :159 s/CI paths/test paths/; :188 the container MUST pin and assert en-US (MockMsScan uses bare double.Parse; de-DE turns 674.6919 into 6746919); :360-361 a ccache-warm container can relink an identical DLL so zero local jitter proves nothing; :374-379 the container must reproduce the DLL swap, not skip it. |
| delete | `memory` | `memory/reference-no-local-build.md` | The root of the stale graph ('CI on push is the only end-to-end verification'). Replace with reference-local-container-build.md and sweep the 9 citations across 7 files in the same pass. |
| create | `memory` | `memory/reference-local-container-build.md` | How to run each container, what each covers, what NEITHER covers (the Thermo instrument path; a clean recursive-submodule checkout; the cpp-test-build tarball round trip; cold-cache compilation; MSVC on Linux), the working-tree-vs-commit distinction, and the ladder: validate-flashida-config (~200ms) -> net8 config type-check (~2s) -> Linux fast tier (~5s) -> Linux full -> Windows full -> CI on push. |
| modify | `memory` | `memory/reference-toppic-feature-file-verification.md` | Line 11 'No local build exists in this workspace' -> the Windows container builds locally. Missed by the first inventory pass; found by the grep-driven sweep. |
| modify | `memory` | `memory/reference-golden-recapture-promotion.md` | Container-first, and record that the container never sets LOG_GOLDEN_CAPTURE. PRESERVE the .normalized byte-identity proof and the skip-the-2-non-golden-modes warning. |
| modify | `memory` | `memory/feedback-always-watch-ci-after-push.md` | DEMOTE, do not delete: containers green before you push; CI remains the clean-checkout backstop and must still be watched; a red CI after a green container triggers the trust-revocation rule. |
| modify | `memory` | `memory/ci-green-baseline-2026-08-08.md` | ctest 25/25 -> 26/26 (run 33083942633). Record HOW to derive the baseline rather than a number. |
| modify | `memory` | `memory/MEMORY.md` | Index lines :30, :54, :57, :59, :75, :76; heading :49 '## CI / build' -> '## Build / verification'. Plus whatever the 105-file grep sweep surfaces. |

---

## AI-instruction changes

### 1. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
**Build in CI, not locally** (`.github/workflows/flashida-ci.yml`); local builds are for rare manual verification. Build sparsely; at a minimum push once at the **end** of a run so the work lands verified.
```

**Replacement:**

```
**Build and test locally in the two Docker containers; CI on push is the backstop.** The Linux container (gcc 13.3, apt deps, no contrib tarball) builds `libOpenMS.so` + the FLASH test exes and runs ctest -- the fast inner loop; it cannot produce `OpenMS.dll` and is never authoritative for a number or a golden. The Windows container reproduces the CI toolchain (MSVC 14.44 + Qt 6.8.3 + the pinned contrib tarball) to produce a real `OpenMS.dll` and runs the whole C# side. Build often. **The containers verify your working tree, dirty; CI verifies a commit from a clean recursive checkout** -- 'green containers' is never 'green at this SHA'. `.github/workflows/flashida-ci.yml` is UNCHANGED and still runs on push AND on pull_request to main/develop/flashida-v9-migration; it remains the only verifier of the clean checkout, the cpp-test-build tarball round trip, the openms-fresh-dll bundle layout, cold-cache compilation, and MSVC-vs-goldens. Land a push once the containers are green, and still watch the run.
```

### 2. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
### OpenMS (C++20 / CMake) - **Do NOT build unless explicitly asked** (resource-intensive; CI handles it)
```

**Replacement:**

```
### OpenMS (C++20 / CMake) - build it in the Linux container; it is the fast loop
```

### 3. `CLAUDE.md (parent)` — **DELETE**

**Stale text:**

```
The 4-line `cmake -S OpenMS -B OpenMS/build -G Ninja ...` block containing `-DWITH_GUI=OFF`, plus 'it compiles **23 named FLASH test binaries**' (:49) and the '# ...22 total' comment (:56)
```

**Note:** Replace the whole fenced block with: 'The configure flags, the build `--target` list, the `ctest -R` alternation and the pinned tool versions are NOT reproduced here. Both containers and CI read them out of `.github/workflows/flashida-ci.yml` -- there is exactly one copy. Any such list you find written out in prose is stale by construction. The yml's own prose comments are historical (they say 25 and 13 where the list says 26); only its `--target` block, its `-R` line and its version pins are authoritative.' Do NOT land a separate commit correcting 23->26 and 22->26 first; deleting the block IS the fix, and correcting-then-deleting in one landing is churn. NOTE the doc's copy is also wrong on the flag: the yml sets `-DWITH_GUI=ON`.

### 4. `CLAUDE.md (parent)` — **DELETE**

**Stale text:**

```
The 21-name `ctest --test-dir OpenMS/build -R "..."` alternation
```

**Note:** Delete. It is missing FLASHDeconvFeatureFile, FLASHIda_CandidateAdmission and ProteoformTracker_Exhaustive against the yml's 24 branches. Keep only the single-test form `ctest --test-dir <build> -R FLASHIdaFAIMS --output-on-failure`, which encodes no list.

### 5. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
**A C++ test runs in CI only if it is added in BOTH places**: the build `--target` list in `.github/workflows/flashida-ci.yml` AND the `ctest -R` alternation *in the same file*.
```

**Replacement:**

```
**A C++ test runs ANYWHERE -- CI or either container -- only if it is added in BOTH places** in `.github/workflows/flashida-ci.yml`, **and then you run `ci lists` to confirm the parser sees it**. The containers parse those same two lists, so registering it in `executables.cmake` alone still gets you nothing, and a missed registration now costs a local run as well as a CI run. There is no `-E` exclusion; the `-R` alternation is the whole active set, and its branches are unanchored regex searches -- `FLASHIda_Logging` also matches `FLASHIda_LoggingFields_test`.
```

### 6. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
Re-run `FLASHIdaLogGolden_test` with env `LOG_GOLDEN_CAPTURE=1`, or promote CI artifact `log-golden-capture`
```

**Replacement:**

```
Run `FLASHIdaLogGolden_test` in the Windows container and take the `.normalized` files it always writes to `FlashIDA/bin/log-golden-output/<case>/` -- byte-identical to a capture, and the container therefore never sets `LOG_GOLDEN_CAPTURE` and never writes into the golden tree. Promoting CI artifact `log-golden-capture` remains a fallback, and is the PREFERRED source for the 13 regression TSVs (compare_golden.py's REL_TOL=1e-4 leaves only ~2.6x headroom over observed cross-build drift). NEITHER bypasses the sign-off gate: promotion is a bare host-side `cp` after the owner has seen the diff in cells. There is deliberately no wrapper subcommand for promotion -- a wrapper is the one command shape the golden write guard does not gate.
```

### 7. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
Local builds need the real DLLs placed in `dependencies/` (see `FlashIDA/Installation.md`).
```

**Replacement:**

```
The Windows container consumes the same five DLLs CI does. **Decrypt on the HOST** with `openssl enc -aes-256-cbc -d -pbkdf2 -in FlashIDA/dependencies/thermo-dlls.zip.enc -pass env:THERMO_DLL_PASSPHRASE` into `FlashIDA/dependencies/` (gitignored) and let the bind mount carry them -- never a Dockerfile `ARG`/`ENV`, which bakes the passphrase into a recoverable image layer. They are HOST state: `ci clean` never touches them, and on a fresh clone `ci doctor` reports them absent as a hard FAILURE, not a skip. `Thermo.TNG.Client.API.dll` is NOT on the public Thermo repo (it ships with Tune) and is a compile-time dependency of BOTH projects, so the encrypted zip is the only complete source. This image is never pushed to any registry.
```

### 8. `CLAUDE.md (parent)` — **KEEP-WITH-CAVEAT**

**Stale text:**

```
"Pinned on both **CI paths**" (:24) and "both **run in CI**" (:26)
```

**Replacement:**

```
s/CI paths/test paths (both containers and CI)/ and s/both run in CI/both run in CI and in the containers/, so nobody concludes a local run leaves the 2048-byte ABI unguarded.
```

### 9. `CLAUDE.md (parent)` — **KEEP-WITH-CAVEAT**

**Stale text:**

```
regression runner "(`-captureMode` regenerates goldens; needs Python on PATH)"
```

**Replacement:**

```
Append: '-- which is a container-provisioning requirement: on this host `python`/`py` are Microsoft Store stubs, so `compare_golden.py` runs only inside the Windows container. `-captureMode` writes only to its own `-OutputDir`; the non-capture pass WIPES `FlashIDA/test-output` first, so anything under it must be captured before that pass runs.'
```

### 10. `CLAUDE.md (parent)` — **REWRITE**

**Stale text:**

```
(missing) - 'three non-test gates that can fail an otherwise-green suite'
```

**Replacement:**

```
There are **FOUR** fail-closed gates, not three. The omitted one is **Verify JSON golden capture** (`flashida-ci.yml:442-457`): it exits 1 if `FlashIDA/test-output/json/config_default.json` or `config_full.json` is missing, and those are written only by `GoldenCaptureTests` during the ordinary suite. Also note 25 log-golden modes x 5 streams = 125 files, not 22 x 5.
```

### 11. `FlashIDA/CLAUDE.md` — **REWRITE**

**Stale text:**

```
**CI runners are `en-US`**, so only `ScanFactoryCultureTests`, which *imposes* `de-DE` via `[SetCulture]`, can catch it.
```

**Replacement:**

```
**The test host must be `en-US`, and the Windows container must pin it and ASSERT the pin.** CI runners are en-US; this workspace is de-DE. `Mocks/MockMsScan.cs` parses every spectrum fixture value with a bare culture-sensitive `double.Parse` (:265, :274, :275, :338, :354, :355), and `FromTsv`/`FromTsvAsMS2`/`FromTsvAsMSn` are what the whole golden and continuity suite feeds through -- under de-DE, `double.Parse("674.6919")` returns 6746919. `ScanFactoryCultureTests` imposes de-DE deliberately and asserts that its own `[SetCulture]` took effect, so it is NOT a canary for container locale.
```

### 12. `FlashIDA/CLAUDE.md` — **REWRITE**

**Stale text:**

```
Golden comparison tolerates float drift (ints/strings/structure stay exact) **because CI links a freshly built `OpenMS.dll` on every run**.
```

**Replacement:**

```
...because a fresh `OpenMS.dll` is linked on every CI run and is not bit-reproducible. **A ccache-warm container can relink an identical DLL, so zero local jitter is not evidence the tolerance is unnecessary** -- and a container DLL gone stale against the OpenMS SHA reintroduces exactly the bridge/ABI drift the fresh-DLL swap exists to detect. Note also that the container's DLL is configured `WITH_GUI=OFF` where CI's is `ON`. A golden captured locally must still survive a CI run before it is trusted.
```

### 13. `FlashIDA/CLAUDE.md` — **REWRITE**

**Stale text:**

```
CI overwrites 4 of the 5 with a freshly built engine before the C# build; `zlib.dll` stays committed.
```

**Replacement:**

```
CI **and the Windows container** overwrite 4 of the 5 before the C# build; `zlib.dll` stays committed. **The container must reproduce that swap, not skip it** -- it is the bridge/ABI drift detector. Two local-only hazards CI cannot hit: `FlashIDA/dll/` is a TRACKED directory, so the swap leaves 4 modified tracked files (restore in a `finally`, with no opt-out flag); and `Copy-Item -Force` preserves the SOURCE mtime, so a fresh DLL can be older than a stale `bin/` copy and `PreserveNewest` skips it -- delete `FlashIDA/bin` before every build.
```

### 14. `FlashIDA/CLAUDE.md` — **REWRITE**

**Stale text:**

```
Four further CI-locality claims the first inventory missed: :6 ('parent owns CI, build commands'), :23 ('this is what CI builds and tests'), :46 ('the CI golden-capture step'), :159 ('CI paths')
```

**Replacement:**

```
:6 -> 'the parent owns CI, the local container system, build commands, goldens and config flow'; :23 -> 'this is what CI and the Windows container build and test'; :46 -> 'the CI and container golden-capture steps'; :159 -> s/CI paths/test paths/. Each is a one-phrase edit; leaving them makes the file quietly contradict the parent's new section.
```

### 15. `OpenMS/CLAUDE.md` — **REWRITE**

**Stale text:**

```
**Do not build this project unless explicitly asked** - it is resource-intensive and CI handles it.
```

**Replacement:**

```
**Build this project in the Linux container** -- it is the fast inner loop (gcc 13.3, ctest, fast tier ~5 s). It cannot produce `OpenMS.dll`; the Windows container does that. Build commands and container specifics live in `../CLAUDE.md`, which owns them.
```

### 16. `OpenMS/CLAUDE.md` — **REWRITE**

**Stale text:**

```
Note **CI builds Release**, so `OPENMS_PRECONDITION` and debug asserts are compiled out - an accepted tradeoff to match the production toolchain.
```

**Replacement:**

```
**Two toolchains now build this code.** CI and the Windows container: MSVC, Release -- `OPENMS_PRECONDITION` and debug asserts compiled out, matching the production toolchain. The Linux container: gcc 13.3, Release by default with Debug behind a flag in a separate build dir. Consequences: (a) a Linux-green change is NOT MSVC-green -- no CI job has exercised gcc since the ubuntu `cpp-unit-tests` job was removed on 2026-06-10, so expect toolchain-only diagnostics in both directions; (b) `compiler_flags.cmake:87-92` gives MSVC `/arch:AVX` (256-bit) and gcc `-mssse3` (128-bit), so FP reduction order differs and **Linux never adjudicates a numeric disagreement**; (c) `class_tests/openms/CMakeLists.txt:33-35` forces `-O0` on gcc/clang even in Release, so the Linux test binaries are different binaries from the Windows ones. There are zero `OPENMS_PRECONDITION` in TOPDOWN -- Debug buys assertions in OpenMS core only.
```

### 17. `OpenMS/CLAUDE.md` — **REWRITE**

**Stale text:**

```
A C++ test executes **in CI** only if it appears in **both** places in `../.github/workflows/flashida-ci.yml`
```

**Replacement:**

```
A C++ test executes **at all -- in CI or in either container, which parse those same two lists --** only if it appears in **both** places in `../.github/workflows/flashida-ci.yml`. Miss the first and it never builds; miss the second and it builds but never runs. Also: the 5-DLL staging beside the test exes is **Windows-only**; on Linux the equivalent is rpath/`LD_LIBRARY_PATH` to `libOpenMS.so` and there is no `zlib.dll`.
```

### 18. `docs/kb/scan-pipeline/bridge-functions.md` — **REWRITE**

**Stale text:**

```
3. Rebuild `OpenMS.dll` (CI does this; see parent `CLAUDE.md`).
```

**Replacement:**

```
3. Rebuild `OpenMS.dll` -- the Windows container (`ci dll`), or CI; see parent `CLAUDE.md`.
```

### 19. `.claude/skills/validate-flashida-config/SKILL.md` — **REWRITE**

**Stale text:**

```
**A local build cannot regenerate it** (no restored packages, no net48 reference assemblies, encrypted Thermo DLLs), so CI does it
```

**Replacement:**

```
The Windows container regenerates it directly (`REGEN_CONFIG_REFERENCE=1`, opt-in, default OFF); CI's `config-schema-reference-capture` artifact remains a fallback. **PRESERVE VERBATIM the ordering warning:** it must run AFTER the unfiltered suite, or the gate passes against its own output and the schema silently drifts. Note this file is NOT under `test-data/golden`, so the golden write guard does not see it -- widening the change detector to cover it is deferred until the owner rules on whether the container may regenerate it at all.
```

### 20. `docs/superpowers/plans/ (six files)` — **REWRITE**

**Stale text:**

```
'Build/test in CI only. One push -> one CI run' (2026-06-24-characterization-proteoform-tracker.md:20,:35,:276) and CI-only build directives at 2026-08-12-exhaustive-characterization-mode.md:9,:191; 2026-06-11-test-falsepass-mitigation.md:507; 2026-06-19-processscan-cleanup.md:101; 2026-04-20-charge-based-exclusion.md:410,:752; 2026-04-20-kb-scan-pipeline.md:343
```

**Replacement:**

```
Only ONE of the six is approved-but-not-implemented and will actually be executed (2026-06-24-characterization-proteoform-tracker.md) -- rewrite its Working Agreement to 'Build and test in the containers; batch the landing into one push -> one CI run.' The other five are completed-work records: add a one-line header note ('the CI-only build rule in this document was superseded on <date> -- see CLAUDE.md, Local verification') and change nothing else. Point-in-time records are not retro-edited.
```

### 21. `memory/reference-no-local-build.md` — **DELETE**

**Stale text:**

```
A local FlashIDA build is impossible in this workspace - CI is the only end-to-end gate. ... a plan step that says "run the tests locally" is not executable here.
```

**Note:** Replaced by reference-local-container-build.md. Do this as a GREP-DRIVEN sweep across all 105 memory files (phrasings: 'CI is the only', 'cannot build locally', 'no local build', 'CI round trip', 'push to verify', 'resource-intensive') and REPORT THE COUNT CHECKED -- 65 of 105 mention CI, so a sampled pass will miss files. Known citations to fix in the same commit: deployed-dll-is-stale-vs-august-abi.md:34, feedback-always-watch-ci-after-push.md:16, lesson-citation-drift-needs-a-separate-pass.md:28, lesson-raw-string-delimiter-mod-names.md:39/:43, MEMORY.md:57, project-adr-0026-scan-range-binding.md:43, reference-csharp-config-typecheck-harness.md:11/:59. No skill cites it. Also fix reference-toppic-feature-file-verification.md:11 ('No local build exists in this workspace').

### 22. `docs/adr/0025-the-drain-acquires-no-analysis-lock.md` — **KEEP-AS-IS**

**Stale text:**

```
'no tool substitutes: MSVC offers only /fsanitize=address ... ' (:73-79) is now MSVC-scoped, since a Linux build dir produces no DLL and gcc has -fsanitize=thread
```

**Note:** Do NOT edit the ADR. Editing an accepted decision record to add a tooling footnote is unrelated to making verification local, and there is zero precedent for tooling ADRs in the set. Put the observation in `docker/README.md` instead, and keep TSan off the critical path.


---

## Delivery plan

PRE-FLIGHT (no commits): wait for run 33089853328 (e1b5587) to complete; `git pull --rebase` in parent, FlashIDA and OpenMS; confirm all three clean and gitlinks in sync; check `Claude-Session:` trailers on anything unexpected (a second Claude session is active in this workspace).

GATE 0 (no commits, before any container work): M0 elevated `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All` + reboot; M1 host-side Thermo decrypt + `unzip -l` (must list five DLLs incl. Thermo.TNG.Client.API.dll); M2 write and validate `ci-lists.awk` UNDER MAWK IN THE LINUX CONTAINER; M3 Linux Release link of libOpenMS.so + ScanCommandLayout_test; M4 nanoserver isolation probe + 10-min bind-vs-container-local compile benchmark; M5 dual-engine probe; M6 full Linux ctest triage. Calibrate both containers, still uncommitted, against run 33083942633 (parent 9bcfc82) via a `git worktree` at that SHA -- expected C# total=181 passed=180 failed=0 skipped=1, ctest 26/26.

LANDING 1 -- 8 commits, 3 repos, 3 pushes, 1 CI run.
  Submodules first:
    C6. OpenMS: `CLAUDE.md: building is local now -- the container, not CI, is the inner loop`
        -> `git -C OpenMS pull --rebase && git -C OpenMS push`
    C7. FlashIDA: `CLAUDE.md: the test host must be en-US, and the container reproduces the DLL swap` (the 8 edits)
        -> `git -C FlashIDA pull --rebase && git -C FlashIDA push`
  Parent, in this order:
    C1. `hooks: gate golden writes that arrive through a container or PowerShell`   [NEEDS USER AUTHORIZATION -- .claude/]
    C2. `docker: derive the C++ target and ctest lists from flashida-ci.yml`        (its own commit -- most likely to need reverting alone)
    C3. `docker: a Linux container that builds libOpenMS.so and runs the FLASH ctests`
    C4. `docker: a Windows container that reproduces the CI toolchain end to end`
    C5. `docker: one dispatcher for both containers` (+ .gitattributes, .dockerignore, .gitignore)
    C8. `docs: local containers as the day-to-day gate` (CLAUDE.md rewrite + kb x2 + SKILL.md + 6 plan-doc headers + docker/README.md + BOTH gitlink bumps)
    -> `git pull --rebase && git push`
  -> ONE `gh run watch <id> --exit-status` in the background. PREDECLARED SUCCESS: 3/3 jobs green, C# 181/180/0/1, ctest 26/26, zero golden movement, `git status --porcelain` clean in all three repos after a container run. Anything else = a finding -> STOP, re-enter plan mode, re-approval. No fix-forward.
  NOTE: there is deliberately NO separate "correct the CLAUDE.md counts" commit. C8 deletes the very lines a correction would have touched; correcting-then-deleting in one landing is churn against the plan's own delete-don't-correct rule. There is also no commit widening golden-change-detector.sh -- that is deferred until the config_schema_reference.json regen question is answered.

LANDING 2 -- memory rewrites. Outside git, no push, no CI. Do during Landing 1's CI wait: a GREP-DRIVEN sweep across all 105 memory files (report the count checked), replacing reference-no-local-build.md and its 9 citations across 7 files, plus reference-toppic-feature-file-verification.md:11; rewrite the 6 memories listed in fileManifest; fix MEMORY.md's index lines and the `## CI / build` heading; rewrite the `.superpowers/sdd/` brief templates.

LANDING 3 (CONDITIONAL) -- OpenMS portability fixes, only if M3/M6 demand source changes. Prefer a container-side change over any source change. Check the file against OpenMS/CLAUDE.md's untouchable-boundary table FIRST; a hit -> STOP and ask, enumerating exact files. One OpenMS commit per logical fix class -> push OpenMS -> parent `Bump gitlink: <what>` -> push -> watch. CI is the PRIMARY oracle here (only GitHub compiles MSVC). Expect >=1 round; any red -> STOP + re-plan.

LANDING 4 (CONDITIONAL) -- goldens. Own push, always last. Windows container runs the suite normally -> collect `.normalized` / `continuity-output/` -> `ci golden-diff` -> show the owner concrete before/after IN CELLS -> fresh sign-off -> run the exact `cp` lines it printed, patching only the moved cells (the write trips golden-write-guard.sh; that is the gate working) -> FlashIDA submodule commit -> push FlashIDA -> parent `Bump gitlink: recaptured <set>` -> push -> CI confirms against its own freshly-linked DLL. Prefer the CI `phase4-golden-capture` artifact over a local capture for the 13 regression TSVs. If CI comes back red on a STRUCTURAL diff, apply the trust-revocation rule: discard the local capture, promote the CI artifact, and stop capturing locally until a fresh calibration against a new green CI run reproduces both numbers exactly.

BATCHING RULE, stated as a decision: flashida-ci.yml has no path filters, so every parent push costs a full ~57-68 min run and one run recently sat queued for 24 h. Fine-grained COMMITS, batched LANDINGS -- the agreement is about reviewability and revertability of commits, not push count, and recent history already lands multi-file doc sets in single pushes.

KILL SWITCH: `ci` is a committed script and the workflow is untouched, so backing the whole thing out is `git revert` of the `docker:` commits plus the two `.claude/` hook commits. Nothing in the build, the tests or the goldens depends on the containers existing.


---

## Risks

| Severity | Risk | Mitigation |
|---|---|---|
| **blocker** | The `Containers` Windows optional feature is DISABLED (InstallState=2), `C:\ProgramData\Docker` does not exist, and both docker contexts report `linux`. No Windows container can start, and Docker Desktop refuses rather than self-enabling. | Gate 0 / M0: elevated `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart` + REBOOT. Verify unelevated: InstallState 1 and `Get-Service cexecsvc` exists. Scripted precheck in `ci doctor` so nothing downstream runs against the Linux daemon and silently produces Linux results. |
| **blocker** | golden-write-guard.sh fires on NONE of the container paths (three proven causes: the PowerShell tool matches no matcher; the extractor truncates at the first escaped quote; `docker` is absent from the write-verb list) AND, more fundamentally, PreToolUse hooks only ever see THIS AGENT's tool calls -- the human running `ci` in their own terminal is invisible to every hook. The 2026-08-05 incident the hook exists to prevent is reproducible again through two doors. | Layers that survive both facts. L1 (mechanical, human-proof): never set LOG_GOLDEN_CAPTURE -- the unconditional `.normalized` files are byte-identical, so the container never writes into the golden tree; zero code change. L4 (in-runner, unconditional, flagless, the LAST foreground action of every subcommand): assert `git -C FlashIDA status --porcelain -uall -- test-data` empty, else print, revert, exit non-zero. L0 (agent-only): fix the matcher, extractor, verb list and tokens -- needs user authorization. L2 (optimisation): mount the golden tree :ro. L3: promotion is a bare host-side `cp`, never a `ci` subcommand -- a wrapper is the one shape the guard does not gate even after L0. `run_in_background` is forbidden for any container step that writes into the repo. |
| **blocker** | Bridge/ABI drift detection degrades silently. CI gets it emergently from a fresh checkout + `needs: build` + a one-shot filesystem; ALL THREE vanish locally. A `--skip-build`, an interrupted run, or a `git checkout -- FlashIDA/dll` and the 181-test suite runs against the committed 2026-06-19 OpenMS.dll -- already known stale vs the August ABI -- with every test green. ScanCommandLayoutTests cannot catch it (it only reads the C# struct, never opens the DLL). | Assert it explicitly before NUnit, hard-fail unless all three hold, printing all three values: (a) sha256(FlashIDA/bin/OpenMS.dll) == sha256(<build>/bin/OpenMS.dll); (b) that sha != sha256(`git -C FlashIDA show HEAD:dll/OpenMS.dll`); (c) mtime(<build>/bin/OpenMS.dll) newer than the newest file under OpenMS/src/openms/{source,include}/ -- the WHOLE library tree, not only .../ANALYSIS/TOPDOWN/. State both limitations at the call site: (b) false-reds after a deliberate dll/ commit (rare, manual, diff-reviewed -- and there is no --keep-dll flag to make it routine), and (c) is blind to non-source inputs (CMake flags, contrib, toolchain), which §4's toolchain-pin assertion covers instead. |
| **high** | The toolchain pins -- Qt 6.8.3, the contrib tag, the VC toolset id, the Win SDK, the base-image date -- are hard-coded into the Dockerfiles, duplicated from the same yml the parser exists to stop duplicating. LABELs make a later disagreement diagnosable, not prevented. This is the same failure class as the stale test list. | The parser extracts every pin the yml carries (Qt version, contrib tag) alongside the test lists, and the IMAGE BUILD fails if a Dockerfile pin disagrees. Where the yml carries no pin -- the VC component id, which CI resolves from the floating 17-release channel -- the entrypoint asserts the built `cl.exe` version equals CI's recorded 14.44.35207 and warns loudly. Record all pins as image LABELs on top of that, not instead of it. |
| **high** | Nothing re-validates the parser after a yml edit. M2 validates it once, by hand; CI never invokes docker/; the documented add-a-C++-test ritual edits both yml lists. The plan's own 'single most dangerous bug' (silent zero-target parse -> build nothing -> ctest against an empty dir -> full green) would have no ongoing guard. | `docker/ci-lists.sh --self-test` runs the parser under container mawk against the committed yml and asserts the three fail-closed conditions plus the reconciliation, and it is the FIRST step of every C++ entry point -- so any `ci` invocation after a yml edit re-validates it, for milliseconds. The rewritten CLAUDE.md:120 ritual gains a third line: 'then run `ci lists` and confirm the new target appears'. CI cannot run the self-test (the yml is frozen) and that is accepted: a parse failure is local by construction. |
| **medium** | The container's OpenMS.dll is configured `WITH_GUI=OFF` where CI's is `ON`, so the exact binary the local bridge/ABI and golden results depend on comes from a differently-configured library build, and nothing compares the two. | State the consequence in docker/README.md rather than only the divergence. `ci doctor --compare-ci` downloads the latest green `openms-fresh-dll` and prints both sha256 values with both configure lines -- informational, never a gate (CI links a different DLL every run by construction). If a golden ever disagrees between container and CI, re-run the Windows leg once with `--with-gui` before blaming the code. The wizard bundle stays a CI deliverable. |
| **high** | A Release C# build breaks every downstream path. Flash.csproj's `Release|AnyCPU` sets OutputPath to `bin\Release\` (relative to src/Flash/) while Flash.Tests.csproj uses `..\..\bin\` in all four configs -- so Flash.exe and Flash.Tests.dll separate, and nunit3-console, regression-runner's -FlashExe and TestDirectory/../test-data all break. | The plan's Release-default applies to the C++ build ONLY. Hardcode `/p:Configuration=Debug /p:Platform="Any CPU"` in the Windows entrypoint with no flag to change it, and say why at the call site. Add `/p:LangVersion=7.3` -- neither project pins LangVersion on the AnyCPU configs CI actually builds, so a newer Roslyn would silently accept source CI's VS17 rejects. |
| **high** | The Windows container's locale is unpinned. `Mocks/MockMsScan.cs` parses every fixture value with a bare culture-sensitive `double.Parse`, and `FromTsv`/`FromTsvAsMS2`/`FromTsvAsMSn` feed the whole golden and continuity suite. Under de-DE (this host's locale), `double.Parse("674.6919")` returns 6746919 -- every m/z off by 10^4. | `Set-Culture en-US` in the image AND an entrypoint ASSERTION that `(Get-Culture).Name -eq 'en-US'` before any test runs. Update FlashIDA/CLAUDE.md:188. Note ScanFactoryCultureTests asserts its own `[SetCulture]` premise and is therefore NOT a canary for container locale. |
| **high** | `FlashIDA/dll/` is a TRACKED directory (6 files), so CI's pre-msbuild 4-DLL swap leaves 4 modified tracked files in the submodule after EVERY Windows run. Separately, `Copy-Item -Force` preserves the SOURCE mtime, so PreserveNewest can skip a fresh DLL that is older than a stale bin/ copy -- and the suite reports green against the old engine. | `Remove-Item -Recurse -Force FlashIDA\bin` as step 0 AND touch the swapped DLLs to `Get-Date` after copying. `finally`: `git -C FlashIDA checkout -- dll/` then assert `git -C FlashIDA status --porcelain -- dll/` empty, with NO opt-out flag -- the deliberate 'update the committed DLLs' workflow is done by hand with the diff shown, because inventing a fail-open lever on the one mechanism whose silent failure is worst is not worth the convenience. Do NOT 'improve' this into a post-msbuild copy into bin/ -- it works but diverges from the only path CI exercises. |
| **high** | A Linux portability fix lands inside the untouchable FLASHDeconv/FLASHTnT boundary. A static scan flagged missing `<algorithm>`/`<numeric>` in Qvalue.cpp plus FLASHDeconvAlgorithm/FLASHTagger/FLASHTnT/FLASHExtender -- five files inside the no-go scope. A missing-#include fix does not respect that boundary. | Standing rule: prefer a container-side change (flags, -isystem, build scope, no -Werror) over ANY source change. If unavoidable, check the file against OpenMS/CLAUDE.md's boundary table FIRST; a hit is a plan collision -> STOP and AskUserQuestion enumerating exact files. Mitigating evidence: all 39 FLASH TUs pass `g++ -fsyntax-only` with the real flags, and the upstream files last linked green on gcc at aef618c2 with only 2 non-test sources changed since -- so expected fixes are 0. |
| **high** | `ctest -R ""` (an empty parse) is version-dependent and both outcomes are catastrophic: on ctest 4.3.3 it matches EVERY test; on ctest 3.28.3, which the Linux container ships, it prints 'No tests were found!!!' and exits 0 -- a silent green. And JUnit reports a missing test binary as status=notrun under `skipped` with failures="0". | Fail closed BEFORE invoking ctest on zero-or-delimiters-only branches and on a target count below 20. Always pass `--no-tests=error` (verified: exit 8 vs 0 on 3.28.3). Gate on ctest exit code AND `tests` == |parsed targets| AND every target appears once AND every testcase carries `status="run"` -- NEVER on JUnit `failures`. Never trust `ctest -N`'s exit code (always 0). |
| **high** | The 'fast inner loop' premise fails at the ctest layer, not the build layer. Measured: 2109 s total, of which FLASHIda_LoggingFields_test alone is 1392 s (66%). `ctest -j` floors at the longest single test, so a full local pass can never beat ~23 min. | Tier the suite by MEASURED runtime, derived from the previous run's `--output-junit` timings against a `--slow-threshold` (default 2 s) -- not from a committed second list, which would rot the way every other duplicated list here has. Default `ci cpp` = the fast tier (~5 s); `--full` = all 26 with `-j 6` and `OMP_NUM_THREADS=1`; `ci cpp <name>` for the true edit-compile-test cycle. With no prior run, fall back to `--full` and say so. |
| **medium** | Windows-engine-unavailable becomes a silent partial pass: a user told to 'switch and re-run `ci all --resume`' who never resumes has skipped the DLL build, the ABI provenance gate, the 181-test suite, all four gates and the regression run -- and got a line of text. | `ci all` in that mode exits NON-ZERO with `PARTIAL: the Windows leg did not run -- no DLL build, no ABI provenance gate, no 181-test suite, no gates, no regression. NOT CI-EQUIVALENT.` Same treatment as `ci cs <filter>`. Only `--resume` completing the Windows leg can make the aggregate exit 0. This is one instance of the tool-wide contract: every subcommand ends in exactly one of PASS / FAIL / PARTIAL, PARTIAL always exits non-zero, and `ci all` exits with the worst of the two legs. |
| **medium** | 12 of the 31 log-golden tests `Assert.Pass` and return when their fixtures are absent, and the all-five-streams capture guard lives inside `if (Capture)` -- which the plan deliberately never sets. A container image with a pruned test-data would refresh roughly half the 25 modes and still report success. | Carry FlashIDA/test-data whole (23 MB, 63 spectra, 41 configs). The runner asserts the fixture inventory FIRST (24 ms3_cytc_*_scan*.txt, 17 ms3_cytc2_*, 6 ms2_cytc_ce*, configs/method_exploration_etd.json) and, after the run, exactly 25 case directories x 5 non-empty `.normalized` files. Do not trust the in-test guard for this. |
| **medium** | A locally captured golden bakes in a systematic toolchain offset CI has never seen, or a jittered score crosses a discrete selection threshold. Rows, ids, counts and ordering compare EXACTLY in all three comparers, so no tolerance absorbs a flipped selection. compare_golden.py's REL_TOL=1e-4 is 10x tighter than the C# comparer and leaves only ~2.6x headroom over the observed 3.79e-5 drift. | A green CI run on the push carrying the golden is the acceptance test for every local capture. Patch only moved cells, never promote whole files. Prefer the CI artifact for the 13 regression TSVs. Record the container's VS buildVersion alongside any local capture. And apply the written trust-revocation rule: CI red on a FLOAT-only diff -> discard local, promote the artifact, carry on; CI red on a STRUCTURAL diff -> stop capturing goldens locally entirely until a fresh calibration against a new green CI run reproduces both numbers exactly. |
| **medium** | A filtered local run silently bypasses the gates. CI runs the C# suite unfiltered on purpose, and the bridge-smoke gate exists specifically to catch a rename or category filter. Separately, NUnit's `--where` fails OPEN: an unrecognised selector, or a class name missing its namespace, yields `Test Count: 0, Overall result: Passed, exit 0`. | `ci cs <filter>` exits non-zero with a PARTIAL verdict naming the gates that did not run, and writes TestResults.xml to a path the gate cannot read. Every filtered NUnit and ctest invocation asserts its selected count from `--result` XML against a number derived from the parse. Note ContinuityTests lives in `Flash.Tests.AcquisitionLoop`, not `Flash.Tests`. |
| **medium** | Thermo DLL and image lifecycle is unowned. After `ci clean` or on a fresh clone the decrypted DLLs may be absent and the failure surfaces as a confusing CS0246; and the 40-60 GB steady-state image/volume footprint sits on a machine a second Claude session shares. | The DLLs are HOST state: `ci clean` never touches `FlashIDA/dependencies/`, and `ci doctor` treats their absence as a hard FAILURE (not a skip) with the exact decrypt command in the message. Pruning is the USER's call alone: tooling never runs `docker system prune`, images carry a session-unique tag, and `ci doctor` prints the current footprint so the user can decide. |
| **medium** | Process isolation is documented-but-preview for WS2022 images on Windows 11, and Docker defaults to hyperv on a client SKU. If Hyper-V isolation is forced, bind-mount I/O goes over VSMB -- but no Microsoft page documents any figure, so the penalty is unmeasured in both directions. | M4 probes both isolations with a ~130 MB nanoserver pull and `docker inspect -f '{{.HostConfig.Isolation}}'`, and takes a 10-minute benchmark (50 TUs on the bind vs a container-local path) BEFORE any robocopy-into-scratch complexity is designed. Under hyperv, pass `--memory 24g --cpus 20` explicitly. Under process isolation there is no utility VM and no VSMB at all. |
| **medium** | A second Claude session is actively pushing to these repos (HEAD moved mid-analysis; a run is in flight; the OpenMS submodule has uncommitted ADR-0036/0037 work). Container images were also created and deleted underneath the investigation. | Hard-gate Landing 1 on the in-flight run finishing. `git pull --rebase` in all three repos immediately before each push; never force-push; read the `Claude-Session:` trailer before touching any unexpected change. Calibrate from a `git worktree` at a clean SHA, never the live tree. Tag every image with a session-unique suffix and never prune from tooling. |
| **low** | Local runs dirty the parent tree in five places nothing ignores: regression-runner.ps1 copies three support files into CWD, and nunit writes TestResults.xml / RegenResults.xml at the root. This trains the operator to ignore a dirty `git status` -- precisely the signal L4 of the golden control depends on. | Runner deletes all five in a `finally`, AND add them to the parent .gitignore as belt-and-braces. Also add a root .gitattributes BEFORE any shell script is committed, or checkout produces CRLF and the Linux container dies with `bad interpreter: ...^M`. |

---

## Open questions for the owner

1. GATE 0 / M0 needs your admin password and a REBOOT: `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All`. Nothing on the Windows side is possible before it. Do you want to do that now, or should the Linux container land first on its own?

2. Do you have THERMO_DLL_PASSPHRASE to hand for the 60-second host-side decrypt (M1)? CI's log proves the zip holds all five DLLs, but nobody has confirmed which Tune version's `Thermo.TNG.Client.API.dll` is inside -- and because both csprojs carry `<SpecificVersion>False</SpecificVersion>` with no binding redirect, NOTHING in the system can currently detect that version drifting.

3. The two `.claude/` changes (settings.json matcher, golden-write-guard.sh) need your explicit authorization -- a subagent cannot change hook or permission configuration. They must land BEFORE the first container capture. Approve? (I have deliberately NOT included the golden-change-detector.sh widening -- see the next question.)

4. May the Windows container regenerate `FlashIDA/test-data/config_schema_reference.json` (REGEN_CONFIG_REFERENCE=1), or is that CI-only like the goldens? It rewrites a committed fixture in place and sits OUTSIDE both hooks' scope. Answering this also decides whether golden-change-detector.sh's pathspec should widen from `test-data/golden` to all of `test-data` -- which I have deferred because it would otherwise start firing on ordinary fixture edits its author deliberately excluded.

5. Do you want a `permissions.allow` block added to the project `.claude/settings.json` for docker plus the two wrapper scripts? There is no allowlist anywhere today. I would add narrow prefixes (`Bash(docker build:*)`, `Bash(./ci:*)`) rather than `Bash(docker:*)`, which would grant arbitrary bind-mounted writes through an elevated daemon.

6. Is a new ADR the right vehicle? 0038 is the next free number, but all 36 existing ADRs record engine or acquisition-behaviour decisions -- there is zero precedent for a tooling or build-environment ADR. `docs/superpowers/specs/` plus the three CLAUDE.md edits may be the conventional home. (I have NOT proposed editing ADR-0025; its TSan footnote goes in docker/README.md instead.)

7. Ruling needed BEFORE the Linux lane starts: if a Linux build needs a missing `#include` in Qvalue.cpp, FLASHDeconvAlgorithm.cpp, FLASHTaggerAlgorithm.cpp, FLASHTnTAlgorithm.cpp or FLASHExtenderAlgorithm.cpp -- all inside the untouchable FLASHDeconv/FLASHTnT boundary -- may I make it, or must the Linux container build a reduced target set instead?

8. Should the Windows container ever reproduce the FLASHDeconvWizard + FLASHDeconv bundle (WITH_GUI=ON, +6m25s, the whole Qt GUI closure, the unimod.xml layout check)? My recommendation is no -- it is delivery, not verification, and CI keeps producing `openms-fresh-dll` unchanged. The cost of that answer is the divergence described in section 4: the local DLL is built from a different configure than CI's.

9. Landing 1 straight onto `august_pre`, or onto a `phase-containers` branch? `phase-*` is in the CI trigger list so it still gets full CI, and it would stop the 8-commit landing interleaving with the other session's engine work -- at the cost of a more confusing gitlink story.

10. `.superpowers/sdd/` is untracked scratch containing subagent brief templates that say 'Build CI-only' and 'You cannot run tests'. Is it live working state for the other session, or safe for me to rewrite/delete?

11. `FLASHDeconvFeatureFile_test` is in both CI lists and the containers will therefore build and run it, but memory records the standing rule 'only the real-time bridge; offline FLASHDeconv library tests stay disabled, never restored'. Is running it intended, or should the parser carry a documented exclusion?

12. Follow-up, deliberately excluded from this plan: `FlashIDA/test-scripts/check_cpp_config_fixtures.py` is wired into nothing, and it exists because a re-indent broke 120 C++ tests in a way the value gate structurally could not see. Wiring it into the container entry points would collide with Landing 1's no-test-changes commitment. Do you want it as a separate follow-up change?


---

## Completeness critique (applied)

Critic verdict on the draft: **needs-revision**. The revision below was produced in response.


### Gaps closed

- NOT ALL TESTING BECOMES LOCAL, AND SOME OF WHAT STAYS IS UNNAMED. Named honestly: the FLASHDeconvWizard/FLASHDeconv bundle (WITH_GUI=ON), the clean-checkout proof, MSVC-as-goldens-oracle. NOT named anywhere: (1) the `pull_request` trigger — `.github/workflows/flashida-ci.yml:3-7` fires on `pull_request` to main/develop/flashida-v9-migration as well as push, and §1 asserts 'no path filters (`on: push: branches:` only)', which is factually wrong about the trigger set; (2) the `cpp-test-build` tarball round trip — CI's `cpp-tests` job (lines 581-608) runs ctest against a PACKAGED, uploaded, downloaded and UNPACKED build tree with runtime DLLs staged beside the exes (line 256), while the container runs ctest in a live build dir; the packaging/staging/relocation path is exercised only remotely; (3) the `openms-fresh-dll` bundle layout assertions (`test -f .../CHEMISTRY/unimod.xml`, qt.conf, platforms/qwindows.dll, the 7-DLL Qt closure at lines 166-199) — fail-closed steps that no container reproduces; (4) cold-cache compilation — CI runs at CCACHE_MAXSIZE=400M (effectively near-cold), the container at 30G (always warm), so 'this tree compiles from scratch' is only ever proven on GitHub.
- THE CONTAINER'S OpenMS.dll IS NOT CONFIGURED THE SAME WAY AS CI'S. §4 drops `WITH_GUI=ON` to save 6m25s, so the exact binary the bridge/ABI drift check depends on is produced by a different configure than the one CI swaps in. The plan discloses the divergence as 'delivery, not verification' but never states the consequence: a local ABI/behaviour result is from a differently-configured library build, and no assertion compares the container's OpenMS.dll against CI's `openms-fresh-dll` artifact.
- TOOLCHAIN VERSIONS ARE DUPLICATED FROM THE YML WITH NO PARSE AND NO ASSERTION. The entire justification for `ci-lists.awk` is 'never duplicate a list that can rot'. The Dockerfiles then hard-code Qt 6.8.3, contrib tag `2026-03-25-183345`, `VC.14.44.17.14`, `Windows11SDK.26100`, base-image date tag — every one of them also present in the yml, none parsed, none asserted equal. LABELs make a later disagreement 'diagnosable', not prevented. This is the same failure class the parser exists to stop.
- NOTHING RE-VALIDATES THE PARSER AFTER A YML EDIT. M2 validates `ci-lists.awk` once, by hand, in the Linux image. The documented workflow for adding a C++ test edits both yml lists, and CLAUDE.md is being strengthened to say so. No surface re-runs the parser self-test: CI doesn't (the yml is frozen and no job invokes `docker/`), and `ci lists` only runs when a human types it. The plan's own 'single most dangerous bug in the whole design' (silent zero-target parse → build nothing → ctest against an empty dir → full green) has no ongoing regression guard.
- THE PROVENANCE GATE HAS A FALSE-RED AND A SCOPE HOLE. Assertion (b) 'built sha != sha256(git show HEAD:dll/OpenMS.dll)' fails spuriously the instant anyone uses the plan's own `--keep-dll` workflow to commit a rebuilt DLL — a gate that cries wolf is a gate people learn to bypass. Assertion (c)'s mtime scope is only `.../ANALYSIS/TOPDOWN/`; an engine-affecting change outside that directory (shared OpenMS headers the bridge pulls in, CMake flags, contrib) does not trip the staleness check. Neither limitation is stated.
- NO EXIT-CODE / RESULT CONTRACT FOR THE DISPATCHER. Every gate is described as fail-closed individually, but the plan never states that every `ci` subcommand exits non-zero on any gate failure, how `ci all` aggregates two engines' results, or what a partial run prints as its final verdict. 'Fail-closed' is asserted per-check and never as a property of the tool a human will actually read the last line of.
- WINDOWS-ENGINE-UNAVAILABLE IS NOT FAIL-CLOSED. §10's third M5 outcome ('run everything possible on the current engine, write phase state, print ONE line telling the user to switch and re-run `ci all --resume`') is a documented silent partial pass: a user who never resumes has skipped the DLL build, the ABI provenance gate, the 181-test suite, all four gates and the regression run, and got a line of text. It needs the same treatment as `ci cs <filter>`: non-zero exit plus an explicit NOT-CI-EQUIVALENT verdict.
- THE GOLDEN GATE IS CLAUDE-TOOL-SCOPED BY CONSTRUCTION, AND THE PLAN DOES NOT SAY SO. PreToolUse hooks only see tool calls from this agent. The whole point of local verification is that the human runs `ci` in their own terminal, where NO hook exists on any path. Of the four layers, only L1 (never set LOG_GOLDEN_CAPTURE) and L4 (in-runner `git status` assertion) survive direct human invocation — and L4 lives inside the same script that already carries bypass flags (`--keep-dll`, `--skip-build`). The plan must state that L4 is unconditional, flagless, and the last foreground action of every subcommand, and that L0/L3 protect only agent-initiated writes.
- INSTRUCTION-REWRITE COVERAGE IS SHORT IN THREE PLACES. (a) `docs/superpowers/plans/` — at least five more files carry live 'CI-only build' / 'do NOT build locally' directives beyond the one named: `2026-08-12-exhaustive-characterization-mode.md:9,191`, `2026-06-11-test-falsepass-mitigation.md:507`, `2026-06-19-processscan-cleanup.md:101`, `2026-04-20-charge-based-exclusion.md:410,752`, `2026-04-20-kb-scan-pipeline.md:343` (the last is a duplicate of the kb line the plan does fix). (b) `FlashIDA/CLAUDE.md` carries CI-locality claims the 4-edit list misses: `:6` ('parent owns CI, build commands'), `:23` ('this is what CI builds and tests'), `:46` ('the CI golden-capture step'), `:159` ('CI paths'). (c) Memory: 65 of 106 files mention CI; the plan sweeps only the 9 citations of the one deleted file. A grep-driven sweep for the 'CI is the only gate / cannot build locally / push to verify' phrasing across all 106 is the honest scope, with the count reported.
- NO ROLLBACK OR TRUST-REVOCATION TRIGGER. There is no stated answer to 'the containers and CI disagree — now what', no kill switch, and no criterion for when a container result stops being trusted (beyond the static authority table). Given a locally captured golden can bake in a systematic MSVC-pin offset, the plan needs an explicit 'CI red on a structural diff after a local capture → discard local, promote artifact, and stop capturing locally until X' rule stated as policy, not as a risk-row mitigation.
- WORKING TREE vs COMMIT IS NEVER STATED PLAINLY. The containers verify the dirty working tree (that is the point); CI verifies a commit. 'Green containers' will be read as 'green at this SHA'. One sentence in CLAUDE.md's new section, and the plan does not have it.
- PER-STEP `env:` FIDELITY IS NOT ENUMERATED. For a plan whose premise is 'CI's steps, in CI's order', §4's 16-row table omits the env blocks CI actually sets — `OPENMS_DATA_PATH` on the NUnit step (line 369), on the config-schema regen (line 402) and on the phase-4 capture (line 430). Even if `FLASHIdaWrapper`'s static ctor overwrites it, dropping it silently is a divergence from the thing being reproduced.
- THERMO DLL LIFECYCLE AFTER `ci clean` / ON A FRESH CLONE IS UNSPECIFIED, and `ci doctor`'s identity gate is listed as a check without stating that absence is a hard failure rather than a skip. Same for who is allowed to prune images/volumes: the plan forbids `docker system prune` from tooling and names no owner for the 40-60 GB steady state on a machine shared with a second Claude session.

### Contradictions resolved

- §7 L3 vs §10 `ci golden-promote`. L3 says 'promotion is a separate, hook-visible, host-side Bash `cp` — deliberately not robocopy, not Copy-Item; only the Bash cp shape is verified gated.' §10 then lists `ci golden-promote <set> <case…>` as 'the ONE command that copies staging → test-data/golden, via Bash cp; the hook fires here.' Traced against the real hook (`.claude/hooks/golden-write-guard.sh:33-56`): the tool call text is `./ci golden-promote …`, which sets hit=1 via the `*[Gg]olden*` + `*./*` fallback, then falls through the write-verb `case` (cp|mv|tee|rsync|install|>|sed -i|python|uv run|checkout|restore) to `*) exit 0` — ALLOWED. The proposed L0 verb additions (docker/robocopy/Copy-Item/…) do not include `ci` or `golden-promote`. So the plan's single sanctioned promotion command is the one promotion path the guard does not gate, even after L0 as specced.
- §9's stated principle 'delete duplicated lists, do not correct them — correcting them just resets the clock' vs Landing 1 commit C3 `CLAUDE.md: the FLASH C++ suite is 26 targets and 24 ctest regex branches`, which corrects exactly the numbers (`:49`, `:56`, `:116`) that C9's own instructionChanges then DELETE in the same landing. Pure churn against the plan's own rule.
- Landing 1's scope commitment 'no existing NUnit or ctest file is created, edited, migrated or deleted' vs §3's 'Add a drift-guard assertion that no two tests request the same `freshLogDir` tag' and §10's 'Run `check_cpp_config_fixtures.py` as a pre-step of every C++ entry point'. Both are test-side changes; at minimum they need the test-change sign-off the plan says it is deferring.
- 'The containers PARSE `flashida-ci.yml` so the test lists are never duplicated' vs the Dockerfiles hard-coding Qt 6.8.3 / contrib tag / VC toolset / Win SDK / base-image date — all duplicated from the same yml with no parse, no assertion, and the same rot risk the parser exists to eliminate.
- The stated payoff is inconsistent. `feasibility.verdict` claims the containers beat the CI critical path 'by roughly 2x'; §10's own table gives `ci all` ≈ 1 h against CI's 57-68 min (≈ 1.1x), and `ci cs` ≈ 28 min against a 68-min CI. The real win the plan argues elsewhere — no queue (24 h observed), fast tier in ~5 s, local golden capture — is undermined by an inflated headline number.
- The tldr says 'three CLAUDE.md files that say "do not build"'; §11 then says `FlashIDA/CLAUDE.md` 'carries no "build in CI" claim, so no commit is REQUIRED'. Both are loose: FlashIDA/CLAUDE.md carries CI-locality claims at :6, :23, :44 and :46, but not a 'do not build' directive. Only two files carry the directive (parent `:32`/`:46`, OpenMS `:13`).
- §1 'Zero new files in either submodule' and 'parent ownership lets the containers be iterated with zero submodule churn' vs a delivery plan whose Landing 1 opens with an OpenMS submodule commit + gitlink bump and optionally a second FlashIDA commit + second gitlink bump. The ownership argument is about container FILES, but it is written as if the whole change avoids submodule churn, which it does not.

### Scope cut (YAGNI)

- `ci cpp --msvc [--full]` — running all 26 ctests on MSVC locally (~35 min) exactly duplicates CI's `cpp-tests` job on the toolchain the plan itself declares CI authoritative for. The Windows container's job is the DLL + the C# side. Cut it, or reduce it to `ci cpp --msvc <name>` for targeted triage.
- §6's `--stage` rsync-onto-a-volume mode — a performance escape hatch designed before M4 measures anything, for a workload (long compile-heavy Linux sessions) that has not been demonstrated. The plan even says 'measure in M4, do not design around it yet' about the Windows equivalent, then designs around it on Linux. Defer.
- §5's eight-code `FLCI-nnn` taxonomy plus `.flci-manifest` persistence plus `--accept-list-change` — a version-controlled ratchet with a bespoke error vocabulary for a list inside a frozen file that changes a couple of times a year. Three fail-closed conditions (no file / no `-R` / count below floor) plus one reconciliation message deliver the whole guarantee.
- §9's ADR-0025 amendment note — editing an accepted ADR to add a TSan footnote is unrelated to making verification local, and the plan itself flags that there is zero precedent for tooling ADRs. Drop it; put the note in `docker/README.md`.
- §9's proposed 8th `docs/kb` packet — speculative future work stated as a plan item.
- Commit C2 (widen `golden-change-detector.sh` from `test-data/golden` to all of `test-data`) — it pre-empts the plan's own unresolved question about whether the container may regenerate `config_schema_reference.json` at all, and it will now fire on ordinary fixture edits (configs, spectra) that the guard's author deliberately excluded (`golden-write-guard.sh:26`). Decide the regen question first.
- §10's 'fold in the two unwired scripts' (`check_cpp_config_fixtures.py`, `prepare-test-data.py`) — a genuine pre-existing defect, but it is a separate change riding along on the container work and it collides with the no-test-changes commitment.
- The `--keep-dll` flag — an invented fail-open lever for the rare 'update the committed DLLs' workflow, added to the one mechanism the plan itself calls the worst thing to lose silently. Do that workflow by hand, deliberately, with the diff shown.
- `docker/slow-tests.txt` as a committed second list plus a subset-assertion — the tiering is justified (one test is 66 % of runtime), the hand-maintained file is not. Derive the exclusion from the previous run's ctest JUnit timings, or from a single `--exclude-slow` threshold.
- §6's 'explicitly rejected: relocating the checkout into WSL2' and the 9p-vs-ext4 microbenchmark tables — good research, but as plan content it is a rejected alternative rendered at the same weight as decisions. Compress to one line.
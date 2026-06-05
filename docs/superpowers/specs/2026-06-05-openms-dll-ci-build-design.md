---
title: Build OpenMS.dll in FlashIDA CI for drift detection
date: 2026-06-05
status: approved
branch: august_pre
---

# Build `OpenMS.dll` in FlashIDA CI for drift detection

## Problem

The FlashIDA C# CI (`.github/workflows/flashida-ci.yml`, job `windows-tests`) builds and
tests the C# application against the **committed** native binary
`FlashIDA/dll/OpenMS.dll` (~21 MB, Release). That DLL is hand-rebuilt and recommitted
(~25 "update dlls" commits in the last month). Nothing in CI verifies that the committed
DLL still matches the pinned OpenMS submodule SHA, so a divergence between the C# bridge
(the 2048-byte `ScanCommand` ABI, the 5 `extern "C"` exports) and the actual OpenMS source
is only caught if a human remembers to rebuild and recommit.

We want CI to **catch that drift early** by building `OpenMS.dll` fresh from the pinned
submodule SHA on every run and exercising the existing C# test suite against it.

## Decisions (locked during brainstorming)

1. **Goal — catch drift early.** Build `OpenMS.dll` fresh from the pinned OpenMS submodule
   SHA each run and run the C# tests against *that*. Fail CI on mismatch. The committed
   DLL in the repo is left untouched (we overwrite only the ephemeral runner copy).
2. **Gating — blocking on every push/PR.** `windows-tests` gains `needs: build-openms-dll`.
   Nothing merges against a stale/mismatched bridge.
3. **Committed DLL — fresh only.** CI validates only the source-built DLL. Whether the
   committed `FlashIDA/dll/OpenMS.dll` is up to date is out of CI scope (kept current by
   the existing manual rebuild/recommit process). Single test pass against the fresh DLL.
4. **Architecture — separate job + artifact handoff (Approach A).** A new `windows-2022`
   `build-openms-dll` job produces the fresh DLLs and uploads them as an artifact;
   `windows-tests` consumes the artifact and swaps the DLLs into the working tree before
   `msbuild`.

## Existing assets this builds on

- **`OpenMS/.github/workflows/build_dlls.yml`** already builds `OpenMS.dll` on
  `windows-2022`: Release, `WITH_GUI=OFF`, tests off, Qt **6.8.3** via
  `jurplel/install-qt-action@v4`, prebuilt **contrib** from the public `OpenMS/contrib`
  release via `gh release download`, **ccache**, and uploads `OpenMS.dll` +
  `OpenSwathAlgo.dll` + `FLASHDeconv.exe` + `Qt6Core.dll` + `Qt6Network.dll` as an artifact.
  It has **no `workflow_call:`** and is hardwired to OpenMS-repo paths/branches, so it
  cannot be `uses:`-reused — we port its proven steps into a FlashIDA job that builds from
  the **exact pinned submodule SHA** (the only way to truly match what ships).
- **`FlashIDA/src/Flash/Flash.csproj`** (lines ~134–153) references the five runtime DLLs
  with `CopyToOutputDirectory=PreserveNewest`, so overwriting `FlashIDA/dll/*` before
  `msbuild` makes the fresh DLLs flow into `bin/` automatically — no csproj or test changes.
- **Bridge / ABI under test** — `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`
  (`[DllImport("OpenMS.dll")]`, the 5 exports, the blittable 2048-byte `ScanCommand`).
  The existing NUnit `BridgeSmokeTests` + `ScanCommandLayoutTests`, golden capture, Phase-4
  regression, and `[TRACK-CREATE]` checks become the drift detector when run against fresh.

## Architecture

```
checkout (submodules: recursive — OpenMS at pinned SHA)
        │
        ├──────────────────────────────┐
        ▼                              ▼
cpp-unit-tests (ubuntu-latest)   build-openms-dll (windows-2022)   ← NEW, runs in parallel
  (unchanged)                      • Qt 6.8.3, VS shell, ccache
                                   • contrib from OpenMS/contrib
                                   • cmake Release, --target OpenMS
                                   • artifact: openms-fresh-dll
                                          │
                                          ▼  needs: build-openms-dll
                                   windows-tests (windows-latest)   ← MODIFIED
                                     • download openms-fresh-dll
                                     • overwrite FlashIDA/dll/*  (before msbuild)
                                     • existing suite, unchanged
```

Critical path ≈ OpenMS build + artifact handoff + C# tests. The Linux `cpp-unit-tests`
job is untouched and runs concurrently.

### Job 1 — `build-openms-dll` (new, `windows-2022`)

Pinned to `windows-2022` to match the MSVC/Qt toolchain that produced the committed DLL.
Steps (ported from `build_dlls.yml`, adapted to the parent-repo layout where the submodule
already lives at `./OpenMS`):

1. `actions/checkout@v4` with `submodules: recursive` → OpenMS at the pinned SHA.
2. Emulate VS shell: `egor-tensin/vs-shell@v2` (`arch: x64`).
3. Install Qt: `jurplel/install-qt-action@v4` (`version: '6.8.3'`, `arch: 'win64_msvc2022_64'`,
   `archives: 'qtsvg qtimageformats qtbase'`).
4. `choco install ninja cmake ccache 7zip eigen -y --no-progress`.
5. **contrib cache + download**:
   - `actions/cache@v4`, `path: <ws>/OpenMS/contrib`, `key: ${{ runner.os }}-contrib3`.
   - On cache miss: `gh release download -R OpenMS/contrib --pattern 'contrib_build-Windows.tar.gz'`
     (public repo; default `GITHUB_TOKEN`) and extract into `OpenMS/contrib`.
6. **ccache cache**: `actions/cache@v4`, `path: .ccache`, key
   `${{ runner.os }}-${{ runner.arch }}-ccache-<run_name>-${{ github.run_number }}` with the
   same `restore-keys` fallback chain as `build_dlls.yml`
   (`…-<run_name>` → `…-nightly` → `…-`). `<run_name>` is the PR number or branch ref,
   derived by mirroring `build_dlls.yml`'s `extract_branch` step.
7. **Configure** (plain CMake, Ninja, Release):
   ```
   cmake -S OpenMS -B OpenMS/build -G Ninja \
     -DCMAKE_BUILD_TYPE=Release \
     -DWITH_GUI=OFF -DPYOPENMS=OFF \
     -DOPENMS_CONTRIB_LIBS=<ws>/OpenMS/contrib \
     -DBOOST_USE_STATIC=ON \
     -DCMAKE_PREFIX_PATH=$QT_ROOT_DIR \
     -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
   ```
   with `CCACHE_DIR`, `CCACHE_MAXSIZE=400M`, `CCACHE_COMPILERCHECK=content`,
   `CCACHE_SLOPPINESS=time_macros,include_file_ctime,include_file_mtime` env (mirrors
   `build_dlls.yml`). `Eigen3_DIR` set to the choco eigen cmake dir if CMake doesn't find it.
8. **Build**: `cmake --build OpenMS/build --target OpenMS` (`OpenSwathAlgo` is built
   transitively). This skips the ~185 TOPP executables — the main wall-clock win over the
   full `cibuild.cmake` build.
9. **Collect & upload** artifact `openms-fresh-dll`:
   - `OpenMS.dll` + `OpenSwathAlgo.dll` from the build's `bin/` output dir.
   - `Qt6Core.dll` + `Qt6Network.dll` from `$QT_ROOT_DIR/bin`.
   - `actions/upload-artifact@v4`.

**Documented fallback.** If assembling the plain-configure flags proves finicky (contrib/Qt
discovery, missing cache var), fall back to mirroring `build_dlls.yml`'s build step verbatim
— `ctest -S OpenMS/tools/ci/cibuild.cmake` with its full env block (`BUILD_TYPE=Release`,
`OPENMS_CONTRIB_LIBS`, `CMAKE_GENERATOR=Ninja`, `ENABLE_*_TESTING=OFF`, `WITH_GUI=OFF`,
`BOOST_USE_STATIC=ON`, ccache env) — and take the four DLLs from `OpenMS/bld/bin/`. This path
is already green on `august_pre`; it costs the extra TOPP-tool build time.

### Job 2 — `windows-tests` (modified)

- Add `needs: build-openms-dll` to the job.
- New step after `actions/checkout`, **before** `Setup MSBuild` / `msbuild`:
  1. `actions/download-artifact@v4` with `name: openms-fresh-dll` into a temp dir.
  2. `Copy-Item -Force` the four DLLs over `FlashIDA/dll/{OpenMS.dll, OpenSwathAlgo.dll,
     Qt6Core.dll, Qt6Network.dll}`. **Leave the committed `zlib.dll`.**
- Everything else is unchanged. `CopyToOutputDirectory=PreserveNewest` carries the fresh DLLs
  into `bin/`; NUnit, golden capture, Phase-4 regression, bridge smoke verification, and
  `[TRACK-CREATE]` checks all now exercise the freshly built DLL.

If `build-openms-dll` fails (genuine source break, ABI mismatch surfacing at link, or a flaky
contrib download), `windows-tests` is skipped via `needs` and the whole run is red — the
intended drift signal.

## Deliberately out of scope

- Modifying the repo's committed `FlashIDA/dll/*` (we overwrite only the runner copy).
- Validating the committed DLL (fresh-only, per decision 3).
- Building `FLASHDeconv.exe` / TOPP tools or wiring `THIRDPARTY` (not needed for the library).
- Swapping `zlib.dll` (stable third-party; the committed copy is retained).
- Making `build_dlls.yml` reusable / extracting a composite action (Approach C) — possible
  future refactor, no payoff now since the submodule's copy can't share it.

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| **Cold ccache** on first run per branch ≈ full Release `libOpenMS` compile (tens of minutes), on every push's critical path since blocking. | `restore-keys` fallback chain (branch → any) seeds the cache from prior runs; warm runs are much faster. Target-narrowing to `--target OpenMS` avoids building TOPP tools. |
| **Qt version mismatch** — fresh `OpenMS.dll` links Qt 6.8.3. | Ship the 6.8.3 `Qt6Core.dll`/`Qt6Network.dll` from the artifact; committed Qt6 DLLs are unused in CI. |
| **zlib compatibility** — fresh DLL vs committed `zlib.dll`. | Same contrib provenance as before; first green run confirms load. If it ever mismatches, add `zlib.dll` to the artifact from contrib. |
| **Toolchain drift** — `windows-latest` may roll past 2022. | Pin `build-openms-dll` to `windows-2022` (matches Qt `msvc2022` + committed-DLL provenance). `windows-tests` stays `windows-latest` — managed C# loading a native DLL only needs the VC++ redist already present on the runner. |
| **Flaky `OpenMS/contrib` download.** | Contrib is cached (`Windows-contrib3`); download only runs on cache miss. |

## Acceptance criteria

1. A new `build-openms-dll` job builds `OpenMS.dll` from the pinned OpenMS submodule SHA on
   `windows-2022` and uploads `openms-fresh-dll` (`OpenMS.dll`, `OpenSwathAlgo.dll`,
   `Qt6Core.dll`, `Qt6Network.dll`).
2. `windows-tests` `needs:` that job, swaps the four DLLs into `FlashIDA/dll/` before
   `msbuild`, and the existing NUnit + golden + Phase-4 + bridge-smoke suite passes against
   the fresh DLL.
3. The repo's committed `FlashIDA/dll/*` is unchanged by the run (verified: no git diff in
   the submodule from CI).
4. A deliberate ABI break (e.g., changing `ScanCommand` size on one side) makes the run red.
5. CI remains green on `august_pre` end-to-end.

---
title: KB Packet — Scan Pipeline (C++ creation → ABI bridge → C# consumer)
status: draft
date: 2026-04-20
author: Tom
---

# Scan Pipeline KB Packet — Design

## Goal

Document the *plumbing* layer that sits between FLASHIda's acquisition decisions and the Thermo instrument: how `ScanCommand` objects are built and queued in C++, how they cross the ABI via five `extern "C"` bridge exports, and how the C# side turns them into `IFusionCustomScan` submissions.

This packet fills a gap: existing KB packets (`ms1-acquisition/`, `exploration/`, `config-flow/`) cover the *decisions* that drive what scans to run; none cover the data structure that carries those decisions or the ABI that moves them.

## Non-goals

- `FLASHIda::processScan` body internals (MS1 deconvolution + precursor selection orchestration). Line-level walkthrough deferred to a future packet — this packet gives only a one-line body summary with a pointer.
- `FLASHIda::getNextScanCommand` body internals (AGC opportunism, cycle-time MS1 injection, expired-command cleanup). Same — one-line summary plus pointer.
- C# acquisition-loop mechanics (error handling, shutdown, submission timing in `Flash.cs`). Deferred.
- Thermo `IFusionCustomScan` submission details beyond "this is the next hop after `ScanFactory.BuildFromCommand`".

The packet documents **contracts and data structures**, not the orchestration logic that uses them. By design.

## Packet layout

**Location:** `docs/kb/scan-pipeline/`

**Files (4):**

1. `README.md` — landing page, one-paragraph orientation, pipeline flow in text, read order, cross-refs.
2. `scan-command.md` — `ScanCommand` struct, `ScanCommandQueue`, build helpers, tracking-ID encoding, priorities.
3. `bridge-functions.md` — the 5 `extern "C"` exports, their signatures/contracts, body one-liners, ABI sync gotchas.
4. `csharp-consumer.md` — P/Invoke mirror, wrapper methods, acquisition-loop entry pointer, `ScanFactory.BuildFromCommand` field-mapping walkthrough, Thermo submission pointer.

**Conventions** (follow existing pilot packets):

- YAML frontmatter on every file: `title`, `applies_to`, `last_verified: 2026-04-20`, `code_anchors`, `see_also`.
- Paths in anchors are relative to the parent-repo root (`OpenMS/...`, `FlashIDA/...`).
- Pointers over paste. No multi-line code blocks; short inline ``snippets`` are fine.
- File size target: 50-150 lines; `csharp-consumer.md` closer to 100-130 given the field-mapping section.

## `README.md` — detail

~30-40 lines. Contents:

- **Frontmatter** with `applies_to` covering `FLASHIdaBridgeFunctions.cpp`, `ScanCommand.h`, `ScanCommandQueue.h`, `FLASHIdaWrapper.cs`, `ScanFactory.cs`. Top-level `code_anchors`: `ProcessScan` export (`FLASHIdaBridgeFunctions.cpp:62`), `GetNextScanCommand` export (`:73`), C# main loop (`Flash.cs:461`).
- **One-paragraph orientation** framing the packet as the plumbing layer, with cross-refs to `../ms1-acquisition/`, `../exploration/`, `../config-flow/` for the decisions layer.
- **Pipeline-in-text:**

  ```
  C# raw spectrum → ProcessScan (bridge) → FLASHIda::processScan
    → precursor selection / exploration → queue.buildMS*() → enqueue

  C# acquisition loop → GetNextScanCommand (bridge) → queue.dequeue
    → ScanCommand crosses ABI → ScanFactory.BuildFromCommand
    → IFusionCustomScan → instrument
  ```

- **Read order:** (1) `scan-command.md` — the data structure and its queue. (2) `bridge-functions.md` — how it crosses the ABI. (3) `csharp-consumer.md` — what the C# side does with it.
- **Related packets:** `ms1-acquisition/`, `exploration/`, `config-flow/`.

## `scan-command.md` — detail

~100-130 lines.

**Frontmatter:** `applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h, .../ScanCommandQueue.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp`. `code_anchors`: `ScanCommand.h:48` (`IsolationStage`), `:59` (IsolationStage size assertion), `:64` (`ScanCommand`), `:107` (ScanCommand size assertion), `ScanCommandQueue.h:64` (class), `:122` (`nextTrackingId`), `:171` (`tracking_alphabet_`), `:174` (`nextTrackingIdInt_` private), `ScanCommandQueue.cpp:48` (alphabet definition — 94 printable ASCII), `:83` (`nextTrackingIdInt_` impl), `:93` (`nextTrackingId` public wrapper). `see_also`: `bridge-functions.md`, `../ms1-acquisition/precursor-selection.md`, `../exploration/variants-and-sweeps.md`.

**Sections:**

1. **`ScanCommand` struct.** One-sentence purpose ("one blittable, 2048-byte record describing a single scan"). Field *groups*:
   - **Identity** — `scan_id` (int32 counter, encoded 3-char in `scan_description` for MS2/MS3/follow-ups; zero for `makeMS1`/`makeAGC`), `msn_level`, `scan_description` (carries the encoded tracking ID and a human-readable annotation — exact format per helper, see Tracking IDs section), `parent_scan_id[4]` (3 chars + null; empty for MS1; carries MS1 ID on MS2, MS2 ID on MS3; `buildFollowUp` inherits unchanged).
   - **Instrument** — `analyzer[32]`, `first_mass` / `last_mass`, `orbitrap_resolution`, `agc_target`, `max_it`, `microscans`, `rf_lens`, `source_cid` / `source_cid_scaling`, `scan_rate[32]`, `data_type[32]`.
   - **Isolation** — `IsolationStage stages[10]` (each 80B: 5 doubles + 2 int32 + char[32]), `num_stages`.
   - **Precursor scoring** (diagnostic — populated by `buildMS2`, not written to instrument) — `qscore`, `mono_mass`, `charge_cos`/`charge_snr`/`iso_cos`/`snr`, `charge_score`, `ppm_error`, `precursor_intensity`, `peakgroup_intensity`.
   - **Environment** — `hcd_energy`, `faims_cv`.
   - **Bookkeeping** — `priority` (0=highest), `is_agc`, `enqueue_timestamp_ms` / `dequeue_timestamp_ms` (steady_clock ms), `reserved[692]`.
   - Critical invariant: `static_assert(sizeof(ScanCommand) == 2048)` at `:107`. Byte-layout contract is enforced by `bridge-functions.md` — cross-reference there.

2. **`ScanCommandQueue` — state.** Four priority queues (0=highest, 3=lowest); `pending_scan_map_` keyed by tracking_id for in-flight tracking (scans that were dequeued but not yet completed on the instrument); `tracking_id_counter_` monotonic int; all access guarded by `queue_mutex_`.

3. **Build helpers** — one paragraph per (five total):
   - `makeMS1()` / `makeAGC()` (const, no lock — read only immutable config). Neither assigns a tracking ID (`scan_id` stays 0); `scan_description` is the literal `"S"` / `"A"`.
   - `buildMS2(PeakGroup, charge, ScanConfig, priority=2, parent_scan_id=0)` — populates precursor-scoring fields from the `PeakGroup`, builds a single isolation stage from the selected precursor m/z.
   - `buildMS3(ms2_ctx, ScanConfig, frag_mz, frag_charge, iso_width, ion_type='\0', frag_index=0, priority=1)` — two-stage isolation inherited from the MS2 context plus the fragment stage.
   - `buildFollowUp(ctx, ScanConfig, suffix, priority=0)` — clones a prior scan with a fresh tracking ID and a suffix letter embedded after the encoded ID.

4. **Tracking IDs.** The monotonic int counter is encoded base-94 into 3 printable ASCII chars (`tracking_alphabet_` at `ScanCommandQueue.cpp:48`, verified 94 chars `!`–`~`). The `scan_description` format is per-helper: `makeMS1` writes literal `"S"` and `makeAGC` writes literal `"A"` (neither assigns a tracking ID — `scan_id` stays 0); `buildMS2` writes `{encoded}R{mass_kDa}@{charge}`; `buildMS3` writes the same with an optional `{ion_type}{frag_index}` suffix when a specific fragment is targeted; `buildFollowUp` writes `{encoded}{suffix}{mass_kDa}@{charge}` (the only helper embedding a suffix letter after the encoded ID). `parent_scan_id[4]` carries the parent scan's 3-char ID + null — empty for MS1, MS1's ID on MS2, MS2's ID on MS3; `buildFollowUp` inherits unchanged. Thread-safe via `queue_mutex_`.

5. **Queue API.** `push` / `dequeue` (priority-ordered) / `registerPending` / `resolvePending` / `peekPending`. One line each.

6. **Gotchas.**
   - Priority 0 is **highest** (inverted from typical intuition).
   - `parent_scan_id[4]` is 3 chars + null, not 4 chars.
   - Timestamps are set on enqueue/dequeue, not on build.
   - Precursor-scoring fields (qscore, mono_mass, …) ride along for logging/diagnostics and are not used to configure the instrument.

## `bridge-functions.md` — detail

~80-110 lines.

**Frontmatter:** `applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp`. `code_anchors`: each of the 5 exports at `.h:49/52/55/60/63` and `.cpp:39/53/62/73/82`; `ScanCommand.h:107` (size assertion); `ScanCommand.h:59` (IsolationStage size assertion); `FLASHIdaWrapper.cs:31` (C# mirror struct). `see_also`: `scan-command.md`, `csharp-consumer.md`.

**Sections:**

1. **The five exports.** Table with columns `Name | Signature | Returns | Effect`:
   - `CreateFLASHIda(char* arg)` → `FLASHIda*` — constructs engine from method string; null on error.
   - `DisposeFLASHIda(FLASHIda*)` → `void` — deletes engine.
   - `ProcessScan(FLASHIda*, double* mzs, double* ints, int length, double rt_min, int ms_level, const char* scan_description, double faims_cv)` → `int` — ingest one raw spectrum; returns advisory count.
   - `GetNextScanCommand(FLASHIda*, ScanCommand* out)` → `int` — 1 if `out` filled, 0 if queue empty.
   - `GetNextTrackingId(FLASHIda*)` → `int` — thread-safe ID allocator.

2. **Body summaries** (per scope decision — one line + forward pointer):
   - `ProcessScan`: "deconvolves the input spectrum, runs precursor selection and exploration, enqueues resulting commands; return value is advisory. Body internals — future packet."
   - `GetNextScanCommand`: "may inject an AGC or cycle-time MS1 opportunistically, cleans up expired commands, dequeues the highest-priority pending command. Body internals — future packet."

3. **ABI sync — the byte-layout contract.** This is the critical section.
   - C++ `ScanCommand` is 2048 bytes (`static_assert` at `ScanCommand.h:107`). C++ `IsolationStage` is 80 bytes (`:59`). Both assertions fail the build if a field change breaks the size.
   - C# mirror declared `[StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Ansi)]` with `[MarshalAs(UnmanagedType.ByValTStr, SizeConst=N)]` for each char buffer and `[MarshalAs(UnmanagedType.ByValArray, SizeConst=10)]` for the `IsolationStage` array. No runtime size assertion on the C# side — a mismatch produces **silent memory corruption**, not an exception.
   - `Pad1` / `Pad2` / `Pad3` exist purely to match natural alignment on both sides — don't reorder or remove.
   - `reserved[692]` is the tail absorbing future additions. When adding a field, shrink `reserved` by the field size on both sides, keep the totals at 2048.
   - Adding a field ritual: update C++ struct → rebuild OpenMS.dll → update C# struct to mirror exactly → ship both in lockstep (see global `CLAUDE.md` note on DLL-export staging).

4. **Error contracts.** Only `CreateFLASHIda` has a `try/catch (std::exception&)`; the other four exports have no exception handling (UB if their C++ methods throw across the P/Invoke boundary). Four exports null-check `FLASHIda*` (`CreateFLASHIda` takes `char*`); `GetNextScanCommand` additionally null-checks its `ScanCommand*` output. Null-argument return values differ: `DisposeFLASHIda` no-ops, `GetNextScanCommand` returns `0`, `ProcessScan` and `GetNextTrackingId` return `-1`. No structured error channel — stderr is the log.

5. **Gotchas.**
   - `CharSet.Ansi` + `[ByValTStr]`: a Unicode string across the boundary silently corrupts.
   - DLL name is hardcoded as `"OpenMS.dll"` on the C# side — must be resolvable at load time (PATH or alongside `Flash.exe`).
   - `ProcessScan` is **not** thread-safe against `GetNextScanCommand` at the bridge level — caller must serialize or rely on FLASHIda's internal locking (to be documented in the future internals packet).

## `csharp-consumer.md` — detail

~100-130 lines.

**Frontmatter:** `applies_to: FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs, FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/ScanFactory.cs`. `code_anchors`: `FLASHIdaWrapper.cs:31` (`ScanCommand` mirror), `:99` (P/Invoke block), `:179` (wrapper methods), `Flash.cs:379` (startup first MS1), `:461` (steady-state submit), `ScanFactory.cs:57` (class), `:153` (`BuildFromCommand`). `see_also`: `bridge-functions.md`, `scan-command.md`.

**Sections:**

1. **P/Invoke layer.** Brief: the five `[DllImport]` declarations at `FLASHIdaWrapper.cs:99-116` match the five exports one-for-one; the blittable `ScanCommand` mirror at `:31-87` matches the C++ struct byte-for-byte per `bridge-functions.md`. One sentence on why the struct is declared twice.

2. **Wrapper methods.** Brief: `ProcessScan(double[] mzs, double[] ints, …)`, `GetNextScanCommand(out ScanCommand)`, `GetNextTrackingId()` at `:179-211`. Thin pass-throughs.

3. **Acquisition-loop entry.** Pointer-only: `Flash.cs:379` sends the first MS1 at startup; `Flash.cs:461` is the steady-state submit — calls `wrapper.GetNextScanCommand(ref cmd)` and, on return `== 1`, invokes `scanFactory.BuildFromCommand(cmd)` and submits the result. "Loop mechanics (error handling, shutdown, submission timing) — future packet."

4. **`ScanFactory.BuildFromCommand` field mapping** (the core of this file, per scope decision).
   - **Intro paragraph:** `BuildFromCommand` (at `ScanFactory.cs:153`) reads each `ScanCommand` field and writes the corresponding Thermo `ScanParameters` / `IFusionCustomScan` property. The mapping is reflection-driven: field names on the C# `ScanCommand` struct must match property names on `ScanParameters`. This is the *second* ABI contract — C#-internal, but a rename breaks the mapping silently (no compile error).
   - **Mapping table**, three columns (ScanCommand field → ScanParameters / Thermo property → notes). Groups:
     - Instrument: `Analyzer`, `FirstMass`, `LastMass`, `OrbitrapResolution`, `AgcTarget`, `MaxIt`, `Microscans`, `RfLens`, `SourceCid` / `SourceCidScaling`, `ScanRate`, `DataType`.
     - Isolation: `Stages[]` → how the array-of-`IsolationStage` becomes the isolation + activation configuration on the custom scan; `HcdEnergy` applied per stage.
     - Environment: `FaimsCv`.
     - Identity: `ScanDescription` carries the tracking-id+suffix and is essential for round-trip identification on the returning scan — **do not strip**; `ParentScanId` for MS2→MS3 lineage.
     - Diagnostic-only (not mapped to instrument): `Qscore`, `MonoMass`, `ChargeCos`, `ChargeSnr`, `IsoCos`, `Snr`, `ChargeScore`, `PpmError`, `PrecursorIntensity`, `PeakgroupIntensity` — passed across the ABI for TSV logging, not written to the custom scan.

5. **Thermo submission.** Closing pointer: `BuildFromCommand` returns an `IFusionCustomScan`; submission is via the Thermo instrument API (scope-ends-here). Thermo internals out of scope.

6. **Gotchas.**
   - Reflection field-name match fails silently — rename C++ `ScanCommand` field → rename C# mirror → ensure `ScanParameters` has a matching property.
   - `ScanDescription`'s tracking-id suffix (`A` / `S` / none) is the identity that round-trips with the scan result. Don't strip it.
   - Precursor-scoring fields cross the ABI but are diagnostic — not used for instrument commands.

## Writing order (for the plan)

The plan will execute these in order; each task is a fresh subagent invocation producing one file plus any necessary cross-ref updates.

1. Create `docs/kb/scan-pipeline/` directory structure.
2. Write `scan-command.md` — the central data structure first.
3. Write `bridge-functions.md` — depends on `scan-command.md` for cross-refs.
4. Write `csharp-consumer.md` — depends on `bridge-functions.md` for ABI section cross-ref.
5. Write `README.md` — depends on all three (cross-refs to final file state).
6. Add `Scan pipeline` entry to `docs/kb/index.md`.
7. Verify all `code_anchors` resolve and all cross-packet links work.

## Success criteria

- New packet at `docs/kb/scan-pipeline/` with 4 files, each under its line cap and following pilot-packet conventions.
- Every `code_anchor` verified against current code.
- `docs/kb/index.md` updated to list the new packet.
- No duplication of content already in `ms1-acquisition/`, `exploration/`, or `config-flow/` (cross-link instead).
- Anyone wanting to change the ABI can read `bridge-functions.md` and understand the full byte-layout contract without reading source.
- Anyone wanting to add a new `ScanCommand` field can read `scan-command.md` + `bridge-functions.md` + `csharp-consumer.md` and know every site that needs updating.

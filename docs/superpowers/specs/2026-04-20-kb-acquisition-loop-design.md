# KB Packet: Acquisition Loop (design)

**Date:** 2026-04-20
**Status:** Approved for implementation
**Branch:** phase-11

## Motivation

The knowledge base currently has four packets: `scan-pipeline/` (ABI plumbing),
`ms1-acquisition/` (selection + FAIMS cycling), `exploration/` (MS2/MS3 variant
sweeps), and `config-flow/` (`method.json` → engine config). Each covers a
self-contained subsystem, but no packet documents how they *run together* at
runtime. `scan-pipeline/` explicitly deferred two topics to "a future packet":

1. Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand`.
2. C# acquisition-loop mechanics (error handling, shutdown, submission timing).

This packet fills both gaps by documenting the end-to-end round-trip at a high
level: how an incoming instrument scan flows into the C++ engine, how follow-up
commands are produced, and how they return to the instrument.

## Scope

**In scope:**

- C# event-driven orchestration: startup sequence, per-scan event handler
  (`ProcessSpectrum`), `DataPipe` async staging, shutdown sequence, error
  patterns.
- C++ engine entry points: step outlines for `FLASHIda::processScan` (3-branch
  by `ms_level`) and `FLASHIda::getNextScanCommand` (5-step decision tree).
- Round-trip diagram showing one scan cycle end-to-end.
- Cross-packet integration: update sibling `see_also` lists and convert
  `scan-pipeline/`'s "future packet" notes into real pointers.

**Out of scope (deferred / not this packet):**

- Plumbing details (`ScanCommand` struct, queue, bridge exports, P/Invoke) —
  already covered by `../scan-pipeline/`.
- Precursor selection algorithms, FAIMS CV cycling mechanics — covered by
  `../ms1-acquisition/`.
- Exploration variant initiation/scoring — covered by `../exploration/`.
- `method.json` → engine config flow — covered by `../config-flow/`.
- Thermo API (`IFusionCustomScan`, `IMsScan`, `IFusionScans`) internals — out of
  KB scope entirely.
- The "magic scan" startup handshake — user plans to remove; documentation
  should describe the stable shape of the loop, not transient startup quirks.

## Architecture

**New top-level packet:** `docs/kb/acquisition-loop/`.

**Three files (depth-A shallow per engine-entry-points; orchestration narrative
in csharp-orchestration):**

```
docs/kb/acquisition-loop/
├── README.md                 # landing: round-trip overview
├── csharp-orchestration.md   # C# side: startup, event flow, DataPipe, shutdown
└── engine-entry-points.md    # C++ side: processScan + getNextScanCommand
```

**Rationale:**

- Matches the pilot-packet style (scan-pipeline has 4 files, config-flow has 4,
  exploration has 6). Three files is appropriate for a higher-level
  orchestration packet with less surface area than the detail packets.
- Language-based split (C# side / C++ side) matches the existing pattern in
  `scan-pipeline/` (`csharp-consumer.md` vs. `scan-command.md` +
  `bridge-functions.md`).
- Keeps the README readable as a single orientation doc; detail files are
  drill-downs for a given role.

## File specifications

### `README.md` (~60–80 lines)

**Frontmatter:**

```yaml
title: Acquisition Loop Packet
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs,
            OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:430      # ProcessSpectrum
  - FlashIDA/src/Flash/Flash.cs:461      # steady-state drain
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700     # processScan entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1091    # getNextScanCommand entry
see_also:
  - ../scan-pipeline/README.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
```

**Sections:**

1. **Overview** — 2–3 sentences framing the packet as the orchestration layer
   above `scan-pipeline/`. Cross-cutting: C# event handlers + C++ engine entry
   points. Component details live in sibling packets.

2. **Round-trip at a Glance** — ASCII diagram of one scan cycle, showing:
   - `Instrument → MsScanArrived → ProcessSpectrum` (entry)
   - `ProcessSpectrum → DataPipe.Push → UnifiedScanProcessor.ProcessMS →
     wrapper.ProcessScan → FLASHIda::processScan` (forward: ingest + enqueue)
   - `ProcessSpectrum → wrapper.GetNextScanCommand → FLASHIda::getNextScanCommand
     → ScanFactory.BuildFromCommand → scanControl.SetFusionCustomScan →
     Instrument` (return: dequeue + submit)
   - Caption noting that both half-paths fire within a single `ProcessSpectrum`
     invocation.

3. **Read Order** — two bullets pointing to `csharp-orchestration.md` and
   `engine-entry-points.md` with one-line summaries.

4. **Out of Scope** — pointers to `../scan-pipeline/` (plumbing),
   `../ms1-acquisition/` (selection/FAIMS), `../exploration/` (variants),
   `../config-flow/` (config loading), and the Thermo API (out of KB scope).

### `csharp-orchestration.md` (~130–160 lines)

**Frontmatter:**

```yaml
title: C# Orchestration — startup, per-scan event flow, shutdown
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:191      # Main's stopRequest spin-wait
  - FlashIDA/src/Flash/Flash.cs:202      # InstrumentConnected
  - FlashIDA/src/Flash/Flash.cs:357      # OnContactClosure
  - FlashIDA/src/Flash/Flash.cs:430      # ProcessSpectrum
  - FlashIDA/src/Flash/Flash.cs:476      # HandleAcqError
  - FlashIDA/src/Flash/Flash.cs:484      # StopExecution
  - FlashIDA/src/Flash/DataPipe.cs:12    # 2-stage TPL Dataflow
  - FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:15   # ProcessMS adapter
see_also:
  - ../scan-pipeline/csharp-consumer.md
  - engine-entry-points.md
```

**Sections:**

1. **Overview** — The C# side is event-driven, not polling. No scan-pulling
   worker thread. `MsScanArrived` fires per incoming scan; the handler performs
   both the forward (ingest into C++) and return (dequeue one command) halves
   of the round-trip within its callback. The `Main` thread just spins on
   `stopRequest`.

2. **Startup sequence** — After `InstrumentConnected`: `scanControl` and
   `scanFactory` initialized, `method.json` loaded, `FLASHIdaWrapper` +
   `UnifiedScanProcessor` + `DataPipe` constructed. Then via `OnContactClosure`
   (or the `OverrideCC` shortcut): `MsScanArrived` subscribed,
   `AcquisitionErrorsArrived` subscribed, duration timer armed, first command
   pulled via `GetNextScanCommand` and submitted via `BuildFromCommand`.
   **Do not** describe the magic-scan handshake or the `inCustom` flag
   mechanism — the magic scan is planned for removal.

3. **Per-scan event flow (`ProcessSpectrum`, Flash.cs:430)** — Two
   responsibilities per invocation:
   - **Ingest**: `dataPipe.Push(msScan)` routes the scan async into
     `UnifiedScanProcessor.ProcessMS` → `wrapper.ProcessScan` (C++ engine).
   - **Drain**: `wrapper.GetNextScanCommand(ref cmd)` → if return == 1,
     `SendCustomScan(scanFactory.BuildFromCommand(cmd))`.

   Runs on the instrument's callback thread — must return quickly. The drain
   pulls at most one command per incoming scan (natural rate match).

4. **DataPipe async staging (`DataPipe.cs:12`)** — 2-stage TPL Dataflow:
   `BufferBlock<IMsScan>` → `ActionBlock<IMsScan>(processor.ProcessMS)`.
   Decouples the instrument callback thread from the C++ analysis thread so
   `ProcessSpectrum` returns promptly. Unbounded buffer — no back-pressure
   signal to the instrument.

5. **`UnifiedScanProcessor.ProcessMS` adapter (`UnifiedScanProcessor.cs:15`)** —
   Pulls `mzs` / `ints` from `Centroids`, parses `StartTime` / `MSOrder` /
   `Scan Description` / `FAIMS CV` from `Header` and `Trailer`, hands to
   `wrapper.ProcessScan`. The only C# → C++ call site (already noted in
   `scan-pipeline/csharp-consumer.md`).

6. **Shutdown sequence** — `StopExecution` (timer callback, Flash.cs:484) sets
   `stopRequest = true` and closes the timer. `Main`'s
   `while (!stopRequest) {}` spin-wait (Flash.cs:191) exits and the process
   returns. No explicit `DataPipe.Complete()` or pipeline-join — any in-flight
   scans and queued commands are dropped at process exit.

7. **Error patterns** — Try/catch wrapping every Thermo-API boundary: instrument
   container creation, `ScanControl` acquisition, method load, `DataPipe`
   creation, custom-scan submission. `AcquisitionErrorsArrived` handler
   (`HandleAcqError`, Flash.cs:476) logs instrument-side errors (spray
   instability, etc.) but doesn't retry. The code comment at Flash.cs:256
   warns that unhandled exceptions in the "instrument part" don't crash the
   software normally — they produce undefined behavior.

8. **Gotchas:**
   - `msScan.Dispose()` at end of `ProcessSpectrum` is mandatory — Thermo
     `IMsScan` holds unmanaged resources.
   - `DataPipe`'s `BufferBlock` is unbounded; if `ProcessScan` falls behind the
     instrument rate, memory grows.
   - `SendCustomScan` auto-increments `currentNumber` → this becomes the
     `RunningNumber` that comes back as `Access ID`. Do not assign
     `RunningNumber` elsewhere.
   - The drain in `ProcessSpectrum` is single-command-per-invocation.
     Multi-command drains would require a loop on `GetNextScanCommand` —
     currently not done.
   - Spin-wait shutdown (`while (!stopRequest) {}`) burns a CPU core but is
     intentional; don't "improve" it without tracing the Thermo API
     requirements.

### `engine-entry-points.md` (~110–140 lines)

**Frontmatter:**

```yaml
title: Engine Entry Points — processScan and getNextScanCommand
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700    # processScan
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1091   # getNextScanCommand
see_also:
  - csharp-orchestration.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../scan-pipeline/scan-command.md
```

**Sections:**

1. **Overview** — Both entry points are called synchronously on the C# thread
   via P/Invoke (through the `ProcessScan` / `GetNextScanCommand` bridge
   exports — see `../scan-pipeline/bridge-functions.md`). Neither loops.
   `processScan` is the analysis entry (spectrum in, follow-up commands
   enqueued). `getNextScanCommand` is the dequeue entry (next command out,
   or idle-fallback). They share state via `analysis_mutex_` (held by
   `processScan`) and atomics (read lock-free by `getNextScanCommand`).

2. **`processScan` (FLASHIda.cpp:700, ~390 lines)** — step outline:
   - **Preamble** (:704–:734): acquire `analysis_mutex_`; decode 3-char
     tracking ID from `scan_description` (return 0 if < 3 chars);
     short-circuit AGC scans (4th char `'A'`, calibration-only, no data);
     capture receive + enqueue + dequeue timestamps.
   - **Branch by `ms_level`**:
     - **MS1** (:736–:830): if `selection == None`, resolve pending and
       return. Else `selection_.filterAndRank` → top-N → two sub-paths.
       Normal: for each selected precursor × each MS2 scan config,
       `queue_.buildMS2` → push. Exploration: `exploration_.initiate` →
       CE-sweep variants (see `../exploration/variants-and-sweeps.md`).
       Write IDA log + MS1 results TSV. Resolve pending. FAIMS CV cycling
       tail if enabled — push next MS1 at priority 0 (see
       `../ms1-acquisition/faims-cycling.md`). Update `exploration_active_`
       and `current_faims_cv_` atomics.
     - **MS2** (:831–:982): exploration-variant lookup →
       `exploration_.feedResult` (scoring/winner; see
       `../exploration/scoring-and-winner.md`). Else: resolve pending →
       `deconv_.deconvolveMSn` with precursor context → tag-based targeting
       → optional quantification follow-up → optional conditional MS2 →
       `exploration_.initiateNextLevel` for MS3 targeting → write MS2
       identification row if proteoform matched.
     - **MS3** (:983–:1088): exploration-variant lookup →
       `exploration_.feedResult`. Else: resolve pending → `deconveMSn` →
       `MS3FragmentMatcher::calibrateAndScore` using cached MS2 context →
       write identification row.
   - **Return**: number of commands enqueued.

3. **`getNextScanCommand` (FLASHIda.cpp:1091, ~107 lines)** — no mutex held;
   5-step decision tree:
   1. **AGC if needed** (`queue_.needsAGC()`): build AGC, stamp tracking ID +
      timestamps, `registerPending`, return 1.
   2. **Cycle-time MS1 injection** (if `cycle_time_enabled` and
      `msSinceLastMS1` exceeds threshold): build MS1 at priority 0, push
      — does **not** return immediately; falls through to Step 4.
   3. **Cleanup expired** (`queue_.cleanupExpired()`).
   4. **Dequeue by priority** (0 highest → 3 lowest): if a command is
      available, stamp `recordMS1Time` for MS1 drains, return 1.
   5. **Idle fallback**: build an AGC command (return immediately) and push
      a priority-3 MS1 into the queue for the next call — instrument never
      starves.
   - **Return**: 1 if a command was produced, 0 otherwise (unreachable in
     normal operation).

4. **Gotchas:**
   - **Mutex asymmetry**: `processScan` holds `analysis_mutex_` for the full
     call; `getNextScanCommand` acquires no mutex (queue methods self-lock;
     exploration/FAIMS state read via atomics). The split exists so command
     fetch never blocks on analysis — violating it would stall the
     acquisition loop.
   - **Tracking ID parsing** at the top of `processScan` is the only
     correlation mechanism between a returning spectrum and the command that
     produced it; `scan_description` is the sole carrier (see
     `../scan-pipeline/scan-command.md`).
   - **AGC short-circuit** (`scan_description[3] == 'A'`) is critical — AGC
     calibration scans contain no analytical data; deconvolving them produces
     noise.
   - **Cycle-time MS1** is pushed at priority 0 (ahead of pending MS2s) so
     survey coverage takes precedence after extended MSN activity.
   - **Idle fallback always returns 1** — `getNextScanCommand == 0` is
     effectively unreachable in normal operation. The C# defensive guard
     (`if (wrapper.GetNextScanCommand(ref cmd) == 1)`) is a belt-and-braces
     check.
   - **Atomics as the cross-call channel**: `processScan` writes
     `exploration_active_` and `current_faims_cv_` with `memory_order_release`;
     `getNextScanCommand` reads them with `memory_order_acquire`. This is
     the only lock-free state coupling between the two entry points.

## Cross-cutting updates

Beyond the three new files, the packet must update existing files so the KB
integrates cleanly:

### Index

`docs/kb/index.md`: add one line after the scan-pipeline entry:

```
- [Acquisition loop](acquisition-loop/README.md) — end-to-end round-trip:
  startup, per-scan event flow, C++ engine entry points, shutdown.
```

### Scan-pipeline packet

`docs/kb/scan-pipeline/README.md` "Out of Scope" — convert the two "a future
packet" notes to real pointers:

```markdown
## Out of Scope

- Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand` —
  see [`../acquisition-loop/engine-entry-points.md`](../acquisition-loop/engine-entry-points.md).
- C# acquisition-loop mechanics (error handling, shutdown, submission timing) —
  see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).
- Thermo `IFusionCustomScan` submission internals — out of scope.
```

`docs/kb/scan-pipeline/csharp-consumer.md` — two inline "Loop mechanics — out
of scope for this packet" notes gain a back-pointer:

- Under "Input direction": `Loop mechanics (pipeline staging, error handling,
  shutdown) — see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).`
- Under "Output direction — acquisition-loop entry": `Loop mechanics (timing,
  backpressure, shutdown) — see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).`

### Sibling packet see_also cross-linking

Add `- ../acquisition-loop/README.md` to the `see_also` frontmatter of each of
the 4 sibling packet READMEs (the new packet orchestrates all of them, so
back-references are warranted):

- `docs/kb/ms1-acquisition/README.md`
- `docs/kb/exploration/README.md`
- `docs/kb/config-flow/README.md`
- `docs/kb/scan-pipeline/README.md`

## Conventions

- Every file starts with YAML frontmatter; `last_verified: 2026-04-20`.
- No H1 in body; first heading is `## Overview`.
- Title Case headings (matches pilot packets).
- Inline code anchors as `file:line` (e.g., `Flash.cs:430`).
- `see_also` lists use relative paths from the file's location.
- Gotchas section at the end of each detail file.

## Verification

Before committing each file, the implementer must verify every `code_anchor`
and every inline `file:line` reference resolves to the claimed symbol. A
stale anchor means the packet is already wrong on day zero.

The quickest verification: `Read` each anchored line, confirm the symbol or
construct named in the comment still matches. `Grep` for any rename that may
have shifted line numbers.

## Deliverables

**New files:**

- `docs/kb/acquisition-loop/README.md`
- `docs/kb/acquisition-loop/csharp-orchestration.md`
- `docs/kb/acquisition-loop/engine-entry-points.md`

**Modified files:**

- `docs/kb/index.md` (+1 line)
- `docs/kb/scan-pipeline/README.md` (2 out-of-scope items reworded, 1 see_also entry)
- `docs/kb/scan-pipeline/csharp-consumer.md` (2 loop-mechanics notes reworded)
- `docs/kb/ms1-acquisition/README.md` (+1 see_also entry)
- `docs/kb/exploration/README.md` (+1 see_also entry)
- `docs/kb/config-flow/README.md` (+1 see_also entry)

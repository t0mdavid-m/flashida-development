# KB Packet: Acquisition Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new top-level KB packet `docs/kb/acquisition-loop/` documenting the end-to-end C#↔C++ scan round-trip at a high level, plus propagate cross-references to sibling packets.

**Architecture:** 3 new files in `docs/kb/acquisition-loop/` (README + csharp-orchestration.md + engine-entry-points.md), frontmatter-driven, no H1 in body, Title Case headings (pilot-packet style). Depth A (shallow — engine step outlines link out to sibling packets for details). Round-trip ASCII diagram in the README. No mention of the magic-scan handshake — user is removing it.

**Tech Stack:** Markdown + YAML frontmatter. No build/test impact.

---

## Conventions Applied

- Each file has YAML frontmatter with `title`, `applies_to`, `last_verified: 2026-04-20`, `code_anchors`, `see_also`.
- Body starts with `## Overview`; no H1.
- Inline references as `file:line` (e.g., `Flash.cs:430`).
- Detail files end with a `## Gotchas` section.
- Paths in `see_also` and markdown links are relative to the file's directory.

## Pre-flight: Anchor Verification Table

Every anchor in the new files must resolve to the claimed symbol. Task 1 below verifies all of them; subsequent tasks rely on that verification.

| File:line | Claimed symbol | Source of truth |
|---|---|---|
| `FlashIDA/src/Flash/Flash.cs:191` | `while (!stopRequest)` spin-wait | spec |
| `FlashIDA/src/Flash/Flash.cs:202` | `InstrumentConnected` handler | spec |
| `FlashIDA/src/Flash/Flash.cs:357` | `OnContactClosure` handler | spec |
| `FlashIDA/src/Flash/Flash.cs:393` | `SendCustomScan` | additional inline |
| `FlashIDA/src/Flash/Flash.cs:430` | `ProcessSpectrum` handler | spec |
| `FlashIDA/src/Flash/Flash.cs:461` | steady-state `GetNextScanCommand` call | spec |
| `FlashIDA/src/Flash/Flash.cs:476` | `HandleAcqError` | spec |
| `FlashIDA/src/Flash/Flash.cs:484` | `StopExecution` timer callback | spec |
| `FlashIDA/src/Flash/DataPipe.cs:12` | 2-stage TPL Dataflow constructor | spec |
| `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:15` | `ProcessMS` adapter | spec |
| `OpenMS/.../FLASHIda.cpp:700` | `processScan` entry | spec |
| `OpenMS/.../FLASHIda.cpp:1091` | `getNextScanCommand` entry | spec |
| `OpenMS/.../FLASHIda.cpp:713` | AGC short-circuit | spec (gotcha) |
| `OpenMS/.../FLASHIda.cpp:807` | FAIMS CV cycling tail | spec |
| `OpenMS/.../FLASHIda.cpp:1097` | Step 1 AGC check | spec |
| `OpenMS/.../FLASHIda.cpp:1123` | Step 2 cycle-time injection | spec |
| `OpenMS/.../FLASHIda.cpp:1143` | Step 3 cleanup expired | spec |
| `OpenMS/.../FLASHIda.cpp:1146` | Step 4 dequeue | spec |
| `OpenMS/.../FLASHIda.cpp:1160` | Step 5 idle fallback | spec |

---

### Task 1: Verify all code anchors

**Files:**
- Read-only: `FlashIDA/src/Flash/Flash.cs`, `FlashIDA/src/Flash/DataPipe.cs`, `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs`, `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

- [ ] **Step 1: Verify each C# anchor**

Run each `Read` with the relevant line range and confirm the symbol matches the claim:

```
Flash.cs:189-195        → expect: while (!stopRequest) { }
Flash.cs:200-210        → expect: private static void InstrumentConnected(object sender, EventArgs e)
Flash.cs:355-365        → expect: private static void OnContactClosure(object sender, ContactClosureEventArgs e)
Flash.cs:391-400        → expect: private static void SendCustomScan(IFusionCustomScan scan)
Flash.cs:428-435        → expect: private static void ProcessSpectrum(object sender, MsScanEventArgs e)
Flash.cs:459-465        → expect: var cmd = new ScanCommand(); if (wrapper.GetNextScanCommand(ref cmd) == 1) { ... }
Flash.cs:474-480        → expect: private static void HandleAcqError(object sender, AcquisitionErrorsArrivedEventArgs e)
Flash.cs:482-490        → expect: private static void StopExecution(object sender, ElapsedEventArgs args)
DataPipe.cs:10-20       → expect: public DataPipe(IScanProcessor processor) constructor with BufferBlock + ActionBlock
UnifiedScanProcessor.cs:13-20 → expect: public void ProcessMS(IMsScan msScan)
```

If a line number has drifted (e.g., code was inserted earlier in the file), update the anchor to the current line and note the shift in the commit message.

- [ ] **Step 2: Verify each C++ anchor**

```
FLASHIda.cpp:698-704    → expect: int FLASHIda::processScan(const double* mzs, ...
FLASHIda.cpp:711-716    → expect: if (desc_str.size() >= 4 && desc_str[3] == 'A') { ... }
FLASHIda.cpp:805-812    → expect: if (faims_.isEnabled()) { double current_cv = faims_.currentCV(); faims_.updateSkip ...
FLASHIda.cpp:1089-1094  → expect: int FLASHIda::getNextScanCommand(ScanCommand& out)
FLASHIda.cpp:1095-1100  → expect: if (queue_.needsAGC()) { out = queue_.makeAGC(); ...
FLASHIda.cpp:1121-1128  → expect: if (config_.scheduling().cycle_time_enabled && queue_.msSinceLastMS1() > ...
FLASHIda.cpp:1141-1145  → expect: queue_.cleanupExpired();
FLASHIda.cpp:1144-1150  → expect: auto dequeued = queue_.dequeue();
FLASHIda.cpp:1158-1165  → expect: idle fallback block (5a AGC + 5b MS1)
```

If a line has shifted, update the anchor. If a symbol is missing entirely, STOP and surface to the user — the spec needs revision.

- [ ] **Step 3: Record verified anchors**

Produce a short report (inline in the implementer response; not a committed file) with one line per anchor:

```
✓ Flash.cs:430  → ProcessSpectrum event handler
✓ Flash.cs:461  → steady-state drain call (wrapper.GetNextScanCommand)
...
```

No commit in this task — it is a pre-flight verification. Subsequent tasks use the verified anchor list.

---

### Task 2: Create `docs/kb/acquisition-loop/README.md`

**Files:**
- Create: `docs/kb/acquisition-loop/README.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p docs/kb/acquisition-loop
```

- [ ] **Step 2: Write the file**

Write this complete content to `docs/kb/acquisition-loop/README.md`:

````markdown
---
title: Acquisition Loop Packet
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs,
            OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:430      # ProcessSpectrum event handler
  - FlashIDA/src/Flash/Flash.cs:461      # steady-state drain call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700     # processScan entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1091    # getNextScanCommand entry
see_also:
  - ../scan-pipeline/README.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
---

## Overview

This packet covers the event-driven orchestration layer *above* the
[`../scan-pipeline/`](../scan-pipeline/README.md) plumbing: how the C# side
wires the instrument-callback loop and how the C++ engine responds per call
via two entry points. Component details (selection, FAIMS, exploration,
config loading) live in the sibling packets this orchestrates.

## Round-trip at a Glance

```
Instrument ──MsScanArrived──▶ ProcessSpectrum (Flash.cs:430)
                                    │
                                    ├──▶ DataPipe.Push ──▶ UnifiedScanProcessor.ProcessMS
                                    │                          └─▶ wrapper.ProcessScan (P/Invoke)
                                    │                                  └─▶ FLASHIda::processScan
                                    │                                      (analyze + enqueue follow-ups)
                                    │
                                    └──▶ wrapper.GetNextScanCommand (P/Invoke)
                                            └─▶ FLASHIda::getNextScanCommand
                                                    └─▶ ScanFactory.BuildFromCommand
                                                            └─▶ scanControl.SetFusionCustomScan
                                                                    └─▶ Instrument
```

Both half-paths (forward ingestion + command return) fire within a single
`ProcessSpectrum` invocation. There is no separate polling thread — the
"loop" is the chain of instrument callbacks.

## Read Order

1. [csharp-orchestration.md](csharp-orchestration.md) — C# side: startup,
   per-scan event flow, DataPipe async staging, shutdown, error patterns.
2. [engine-entry-points.md](engine-entry-points.md) — C++ side: step outlines
   for `processScan` (3 branches by `ms_level`) and `getNextScanCommand`
   (5-step decision tree).

## Out of Scope

- Plumbing details (`ScanCommand` struct, queue, bridge exports, P/Invoke) —
  see [`../scan-pipeline/`](../scan-pipeline/README.md).
- Precursor selection, FAIMS CV cycling mechanics — see
  [`../ms1-acquisition/`](../ms1-acquisition/README.md).
- Exploration variant initiation/scoring — see
  [`../exploration/`](../exploration/README.md).
- `method.json` → engine config loading — see
  [`../config-flow/`](../config-flow/README.md).
- Thermo `IFusionCustomScan` / `IMsScan` / `IFusionScans` internals — out of
  KB scope entirely.
````

- [ ] **Step 3: Verify the file renders**

```bash
cat docs/kb/acquisition-loop/README.md | head -40
```

Expected: frontmatter is valid YAML (no tab characters, no broken indentation), ASCII box diagram is intact.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/acquisition-loop/README.md
git commit -m "docs(kb): add acquisition-loop packet README"
```

---

### Task 3: Create `docs/kb/acquisition-loop/csharp-orchestration.md`

**Files:**
- Create: `docs/kb/acquisition-loop/csharp-orchestration.md`

- [ ] **Step 1: Pre-verify anchors used in this file**

Use `Read` to confirm each of these lines still points at the claimed symbol:

- `Flash.cs:154` → `static void Main(string[] args)`
- `Flash.cs:172` → try/catch around instrument container creation
- `Flash.cs:191` → `while (!stopRequest) { }` spin-wait
- `Flash.cs:202` → `InstrumentConnected` handler signature
- `Flash.cs:235` → ScanControl acquisition try block
- `Flash.cs:256` → comment about unhandled exceptions
- `Flash.cs:269` → method load try block
- `Flash.cs:299` → DataPipe creation try block
- `Flash.cs:357` → `OnContactClosure` handler signature
- `Flash.cs:393` → `SendCustomScan` method signature
- `Flash.cs:430` → `ProcessSpectrum` handler signature
- `Flash.cs:476` → `HandleAcqError` handler signature
- `Flash.cs:484` → `StopExecution` timer callback
- `DataPipe.cs:12` → `public DataPipe(IScanProcessor processor)`
- `UnifiedScanProcessor.cs:15` → `public void ProcessMS(IMsScan msScan)`

If any line has drifted, update the anchor value in the content below before writing the file.

- [ ] **Step 2: Write the file**

Write this complete content to `docs/kb/acquisition-loop/csharp-orchestration.md`:

````markdown
---
title: C# Orchestration — startup, per-scan event flow, shutdown
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:191      # Main's stopRequest spin-wait
  - FlashIDA/src/Flash/Flash.cs:202      # InstrumentConnected
  - FlashIDA/src/Flash/Flash.cs:357      # OnContactClosure
  - FlashIDA/src/Flash/Flash.cs:393      # SendCustomScan
  - FlashIDA/src/Flash/Flash.cs:430      # ProcessSpectrum
  - FlashIDA/src/Flash/Flash.cs:476      # HandleAcqError
  - FlashIDA/src/Flash/Flash.cs:484      # StopExecution
  - FlashIDA/src/Flash/DataPipe.cs:12    # 2-stage TPL Dataflow
  - FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:15   # ProcessMS adapter
see_also:
  - ../scan-pipeline/csharp-consumer.md
  - engine-entry-points.md
---

## Overview

The C# side is **event-driven, not polling**. There is no scan-pulling worker
thread; `MsScanArrived` fires per incoming scan from the instrument, and the
handler performs both halves of the round-trip — ingest into C++ and dequeue
one command out — within its callback. The `Main` thread just waits on a
shutdown flag.

## Startup Sequence

`Main` (`Flash.cs:154`) kicks off instrument-container creation; the Thermo
runtime fires `InstrumentConnected` (`Flash.cs:202`) once it attaches. That
handler:

1. Obtains `acquisition` + `control` + `scanControl` interfaces; detects FAIMS
   capability by scanning `scanControl.PossibleParameters`.
2. Builds `scanFactory` (for constructing `IFusionCustomScan`s from
   `ScanCommand`s — see
   [`../scan-pipeline/csharp-consumer.md`](../scan-pipeline/csharp-consumer.md)).
3. Loads `method.json` into `methodParams` (see
   [`../config-flow/README.md`](../config-flow/README.md)).
4. Constructs `FLASHIdaWrapper`, `UnifiedScanProcessor`, and `DataPipe`.
5. Subscribes `AcquisitionErrorsArrived` to `HandleAcqError`.
6. Waits for contact closure (or skips via `--nocc`).

`OnContactClosure` (`Flash.cs:357`) — or the `OverrideCC` branch inside
`InstrumentConnected` if contact-closure is disabled — then:

1. Subscribes `MsScanArrived` to `ProcessSpectrum`.
2. Arms a `System.Timers.Timer` (`duration`) for the total method duration;
   elapsed callback is `StopExecution`.
3. Submits the first command via `scanControl.SetFusionCustomScan` to kick
   the instrument out of idle.

## Per-Scan Event Flow

`ProcessSpectrum` (`Flash.cs:430`) is the acquisition loop's heartbeat. Called
on the Thermo callback thread, it performs two independent actions per
invocation:

**1. Ingest** — push the scan into the async processing pipeline:

```csharp
dataPipe.Push(msScan);
```

The scan flows through `DataPipe` → `UnifiedScanProcessor.ProcessMS` →
`wrapper.ProcessScan` (P/Invoke into `FLASHIda::processScan`; see
[engine-entry-points.md](engine-entry-points.md)).

**2. Drain** — pull one command from the C++ queue and submit it:

```csharp
var cmd = new ScanCommand();
if (wrapper.GetNextScanCommand(ref cmd) == 1)
{
    SendCustomScan(scanFactory.BuildFromCommand(cmd));
}
```

`SendCustomScan` (`Flash.cs:393`) increments `currentNumber` (becomes the
`RunningNumber` on the submitted scan) and logs a one-line summary before
calling `scanControl.SetFusionCustomScan`.

Each `ProcessSpectrum` invocation drains **at most one** command. The rate
match is natural: one scan arrives from the instrument, one command is sent
back. A burst of commands produced by a single `processScan` call accumulates
in the C++ queue and drains over subsequent `ProcessSpectrum` invocations.

## DataPipe Async Staging

`DataPipe` (`DataPipe.cs:12`) is a 2-stage TPL Dataflow:

```csharp
inputScans  = new BufferBlock<IMsScan>();
processBlock = new ActionBlock<IMsScan>(scan => processor.ProcessMS(scan));
inputScans.LinkTo(processBlock,
    new DataflowLinkOptions { PropagateCompletion = true });
```

Purpose: decouple the instrument callback thread from the C++ analysis
thread. `ProcessSpectrum` calls `dataPipe.Push(msScan)` (a cheap
`BufferBlock.Post`) and returns; the `ActionBlock` later drains the buffer
on a separate worker and calls `processor.ProcessMS`, which performs the
P/Invoke into `FLASHIda::processScan`.

The buffer is **unbounded** — there is no back-pressure signal to the
instrument. If `ProcessScan` falls behind the instrument rate, memory grows.

## UnifiedScanProcessor Adapter

`UnifiedScanProcessor.ProcessMS` (`UnifiedScanProcessor.cs:15`) is the only
C# → C++ call site:

```csharp
double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();
double rt = double.Parse(msScan.Header["StartTime"]);
int msLevel = int.Parse(msScan.Header["MSOrder"]);
string scanDesc = "";
msScan.Trailer.TryGetValue("Scan Description", out scanDesc);

double faimsCv = 0.0;
if (msScan.Trailer.TryGetValue("FAIMS CV", out var cvStr))
    double.TryParse(cvStr, out faimsCv);

wrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc ?? "", faimsCv);
```

See also [`../scan-pipeline/csharp-consumer.md`](../scan-pipeline/csharp-consumer.md)
for the P/Invoke surface.

## Shutdown Sequence

Shutdown is initiated by the duration timer:

1. `duration.Elapsed` fires `StopExecution` (`Flash.cs:484`), which sets
   `stopRequest = true` and calls `duration.Close()`.
2. `Main`'s spin-wait (`Flash.cs:191`):

   ```csharp
   while (!stopRequest) { }
   log.Info("Exiting");
   ```

   exits, the process unwinds.

There is **no explicit pipeline join** — no `DataPipe.Complete()`, no wait on
in-flight scans, no drain of the C++ queue. Commands still in the queue and
scans still in the pipeline are dropped at process exit. This is intentional:
the instrument already stopped producing scans before the timer fires, so
the tail work is not useful.

## Error Patterns

Try/catch wraps every Thermo-API boundary:

- Instrument container creation (`Flash.cs:172`–`:187`)
- `ScanControl` acquisition (`Flash.cs:235`–`:260`)
- Method load (`Flash.cs:269`–`:279`)
- `DataPipe` creation (`Flash.cs:299`–`:307`)
- First custom-scan submission (in `OnContactClosure` and the `OverrideCC`
  branch inside `InstrumentConnected`)

`AcquisitionErrorsArrived` → `HandleAcqError` (`Flash.cs:476`) logs
instrument-side errors (spray instability, etc.) but does not retry.

The code comment at `Flash.cs:256` warns: *"unhandled exception does not
crash the software the usual way, but lead to weird behavior"*. That is why
the try/catch density is high in the instrument-facing paths.

## Gotchas

- **`msScan.Dispose()` at end of `ProcessSpectrum` is mandatory.** Thermo
  `IMsScan` holds unmanaged resources.
- **`DataPipe`'s `BufferBlock` is unbounded.** If `ProcessScan` falls behind
  the instrument rate, memory grows without bound.
- **`SendCustomScan` owns `RunningNumber` assignment.** It auto-increments
  `currentNumber` before submit; this value round-trips as the `Access ID`
  on the returning scan. Do not assign `RunningNumber` elsewhere.
- **Per-invocation drain is single-command.** `ProcessSpectrum` calls
  `GetNextScanCommand` exactly once; if the C++ queue has a burst, it
  drains over subsequent scans. A multi-command drain would require a loop
  — currently not done.
- **Spin-wait shutdown (`while (!stopRequest) {}`) burns a CPU core.** This
  is intentional; do not "improve" it without tracing the Thermo API
  thread-affinity requirements.
````

- [ ] **Step 3: Verify the file**

```bash
cat docs/kb/acquisition-loop/csharp-orchestration.md | head -50
wc -l docs/kb/acquisition-loop/csharp-orchestration.md
```

Expected: frontmatter is valid, code fences intact, roughly 150–170 lines total.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/acquisition-loop/csharp-orchestration.md
git commit -m "docs(kb): add acquisition-loop csharp-orchestration.md"
```

---

### Task 4: Create `docs/kb/acquisition-loop/engine-entry-points.md`

**Files:**
- Create: `docs/kb/acquisition-loop/engine-entry-points.md`

- [ ] **Step 1: Pre-verify anchors used in this file**

Use `Read` to confirm each of these lines still points at the claimed symbol:

- `FLASHIda.cpp:700` → `int FLASHIda::processScan(...)`
- `FLASHIda.cpp:704` → `std::lock_guard<std::mutex> lock(analysis_mutex_);`
- `FLASHIda.cpp:713` → `if (desc_str.size() >= 4 && desc_str[3] == 'A')`
- `FLASHIda.cpp:736` → `if (ms_level == 1)`
- `FLASHIda.cpp:807` → `if (faims_.isEnabled())`
- `FLASHIda.cpp:831` → `else if (ms_level == 2)`
- `FLASHIda.cpp:983` → the MS3 block entry (comment `// MS3 (or higher)`)
- `FLASHIda.cpp:1091` → `int FLASHIda::getNextScanCommand(ScanCommand& out)`
- `FLASHIda.cpp:1097` → `if (queue_.needsAGC())`
- `FLASHIda.cpp:1123` → cycle-time branch
- `FLASHIda.cpp:1143` → `queue_.cleanupExpired();`
- `FLASHIda.cpp:1146` → `auto dequeued = queue_.dequeue();`
- `FLASHIda.cpp:1160` → idle fallback block

If any line number has drifted, update the value inline in the file below. Keep the claim (symbol) matching the actual code.

- [ ] **Step 2: Write the file**

Write this complete content to `docs/kb/acquisition-loop/engine-entry-points.md`:

````markdown
---
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
---

## Overview

Both entry points are called synchronously on the C# thread via P/Invoke
(through the `ProcessScan` / `GetNextScanCommand` bridge exports — see
[`../scan-pipeline/bridge-functions.md`](../scan-pipeline/bridge-functions.md)).
Neither loops internally. `processScan` is the analysis entry (spectrum in
→ follow-up commands enqueued). `getNextScanCommand` is the dequeue entry
(next command out, or idle-fallback).

They share state two ways:

- `analysis_mutex_` — held by `processScan` for its full duration.
  `getNextScanCommand` never touches it; queue methods self-lock, and
  exploration/FAIMS state is read via atomics.
- Atomics — `processScan` writes `exploration_active_` and
  `current_faims_cv_` with `memory_order_release`; `getNextScanCommand`
  reads them with `memory_order_acquire`.

The split exists so command fetch never blocks on analysis.

## `processScan` (FLASHIda.cpp:700, ~390 lines)

Called once per incoming instrument scan from the C# side.

### Preamble (`:704`–`:734`)

1. Acquire `analysis_mutex_`.
2. Decode 3-char tracking ID from `scan_description`. If `scan_description`
   is shorter than 3 chars, return 0.
3. **AGC short-circuit** (`:713`): if `scan_description[3] == 'A'`, the scan
   is a calibration-only AGC with no data — resolve pending and return 0.
4. Capture timestamps: enqueue + dequeue (from pending map) and receive
   (now).

### Branch by `ms_level`

**MS1 (`:736`–`:830`):**

1. If `config_.level(1).selection == SelectionMetric::None`, resolve and
   return 0.
2. `selection_.filterAndRank(...)` → top-N precursors (see
   [`../ms1-acquisition/precursor-selection.md`](../ms1-acquisition/precursor-selection.md)).
3. Two sub-paths:
   - **Exploration**: `exploration_.initiate(2, ...)` produces CE-sweep
     variants. Each gets the MS1's encoded tracking ID stamped as
     `parent_scan_id`. See
     [`../exploration/variants-and-sweeps.md`](../exploration/variants-and-sweeps.md).
   - **Normal**: for each selected precursor × each MS2 scan config,
     `queue_.buildMS2` → push. MS2 `faims_cv` carries parent MS1's CV.
4. Write IDA log entry + MS1 row to `results.tsv`; resolve the MS1 from the
   pending map.
5. **FAIMS CV cycling tail** (if `faims_.isEnabled()`, `:807`): call
   `faims_.updateSkip(current_cv, commands_pushed)` → `advanceToNextCV` →
   construct the next MS1 at priority 0 with the new CV and push. See
   [`../ms1-acquisition/faims-cycling.md`](../ms1-acquisition/faims-cycling.md).
6. Update `exploration_active_` and `current_faims_cv_` atomics.

**MS2 (`:831`–`:982`):**

1. If `exploration_.isExplorationVariant(tracking_id)` → route to
   `exploration_.feedResult(...)` for scoring / winner selection (see
   [`../exploration/scoring-and-winner.md`](../exploration/scoring-and-winner.md)).
2. Otherwise:
   - Resolve pending → get MS2's precursor context (mono mass, charge).
   - `deconv_.deconvolveMSn(...)` with that context.
   - Tag-based targeting via `selection_.processMS2ForTagBasedTargeting`.
   - Optional quantification follow-up (`quant_.isDifferentiallyAbundant`
     → `queue_.buildFollowUp(..., 'F')`).
   - Optional conditional MS2 (if tags found and
     `conditional_ms2_enabled` → `queue_.buildFollowUp(..., 'C')`).
   - MS3 targeting: `exploration_.initiateNextLevel` (cached MS2 context is
     stashed for MS3 identification lookup).
   - Write MS2 identification row if a proteoform was matched.
3. Update `exploration_active_` atomic.

**MS3 (`:983`–`:1088`):**

1. If `exploration_.isExplorationVariant(tracking_id)` → route to
   `exploration_.feedResult(...)`.
2. Otherwise:
   - Resolve pending → MS3's precursor context.
   - `deconv_.deconvolveMSn(...)`.
   - Look up cached MS2 context; run `MS3FragmentMatcher::calibrateAndScore`
     for identification; write identification row.
3. No commands pushed; return 0.

Return value: number of commands enqueued during the call.

## `getNextScanCommand` (FLASHIda.cpp:1091, ~107 lines)

Called on every `ProcessSpectrum` invocation to pull the next command.
Holds no mutex — queue methods self-lock; exploration/FAIMS state is read
via atomics.

Five-step decision tree:

1. **AGC if needed** (`:1097`): if `queue_.needsAGC()`, build an AGC via
   `queue_.makeAGC()`, stamp it with the current FAIMS CV + a fresh
   tracking ID + timestamps, encode the `scan_description` as `{id}A`,
   `registerPending`, return 1.
2. **Cycle-time MS1 injection** (`:1123`): if `cycle_time_enabled` and
   `queue_.msSinceLastMS1()` exceeds `cycle_time_ms`, build an MS1 at
   priority 0, push it into the queue. **Does not return immediately** —
   falls through to Step 4 so the MS1 is dequeued via the normal path.
3. **Cleanup expired** (`:1143`): `queue_.cleanupExpired()` discards stale
   pending entries.
4. **Dequeue by priority** (`:1146`): `queue_.dequeue()` walks priority
   queues 0 → 3 (0 highest). If a command is available, stamp
   `recordMS1Time` for MS1 drains and return 1.
5. **Idle fallback** (`:1160`): queue was empty — build an AGC command for
   immediate return AND push a priority-3 MS1 into the queue for the next
   call. The instrument never starves.

Return value: 1 if a command was produced, 0 otherwise. Because Step 5
always produces an AGC, `0` is effectively unreachable in normal operation.

## Gotchas

- **Mutex asymmetry is load-bearing.** `processScan` holds `analysis_mutex_`
  for its entire body; `getNextScanCommand` never acquires it. If a future
  refactor adds a shared lock, command fetch will block on analysis and the
  acquisition loop will stall.
- **Tracking ID parsing at the top of `processScan` is the only correlation
  mechanism.** `scan_description` is the sole carrier that links a
  returning spectrum to the command that produced it. If a scan arrives
  without a 3-char prefix, `processScan` returns 0 — the scan is silently
  dropped from the analysis side (see
  [`../scan-pipeline/scan-command.md`](../scan-pipeline/scan-command.md)).
- **AGC short-circuit is critical.** `scan_description[3] == 'A'` identifies
  AGC calibration scans, which have no analytical data. Deconvolving them
  produces noise; the short-circuit resolves pending and returns.
- **Cycle-time MS1 is pushed at priority 0.** It jumps ahead of pending MS2
  commands so survey coverage takes precedence after extended MSN activity.
- **Idle fallback always returns 1.** The C# defensive guard
  `if (wrapper.GetNextScanCommand(ref cmd) == 1)` is a belt-and-braces
  check against future changes.
- **Atomics are the lock-free cross-call channel.** `exploration_active_`
  and `current_faims_cv_` are the only state coupling between the two
  entry points that does not go through `analysis_mutex_` or
  queue-internal locks.
````

- [ ] **Step 3: Verify the file**

```bash
cat docs/kb/acquisition-loop/engine-entry-points.md | head -50
wc -l docs/kb/acquisition-loop/engine-entry-points.md
```

Expected: frontmatter valid, ~140–170 lines total.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/acquisition-loop/engine-entry-points.md
git commit -m "docs(kb): add acquisition-loop engine-entry-points.md"
```

---

### Task 5: Add acquisition-loop to `docs/kb/index.md`

**Files:**
- Modify: `docs/kb/index.md`

- [ ] **Step 1: Read the current index**

```
Read docs/kb/index.md
```

Confirm the current "Packets" list ends with the scan-pipeline entry on line 12:

```
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.
```

- [ ] **Step 2: Add the new entry**

Use `Edit` to insert one line after the scan-pipeline entry:

```
old_string:
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.

new_string:
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.
- [Acquisition loop](acquisition-loop/README.md) — end-to-end round-trip: startup, per-scan event flow, C++ engine entry points, shutdown.
```

- [ ] **Step 3: Verify**

```
Read docs/kb/index.md
```

Expected: the Packets list has 5 entries, acquisition-loop right after scan-pipeline.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): list acquisition-loop in kb index"
```

---

### Task 6: Update `docs/kb/scan-pipeline/README.md` "Out of Scope" + see_also

**Files:**
- Modify: `docs/kb/scan-pipeline/README.md`

- [ ] **Step 1: Read the current file**

```
Read docs/kb/scan-pipeline/README.md
```

Confirm:
- Line 10-12 area has `see_also:` listing `../ms1-acquisition/README.md`, `../exploration/README.md`, `../config-flow/README.md`.
- Line 38-41 area has the "Out of Scope" section with two "a future packet" bullets.

- [ ] **Step 2: Update the two "Out of Scope" bullets**

Use `Edit` with `replace_all: false`:

```
old_string:
- Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand` — a future packet.
- C# acquisition-loop mechanics (error handling, shutdown, submission timing) — a future packet.

new_string:
- Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand` —
  see [`../acquisition-loop/engine-entry-points.md`](../acquisition-loop/engine-entry-points.md).
- C# acquisition-loop mechanics (error handling, shutdown, submission timing) —
  see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).
```

- [ ] **Step 3: Add acquisition-loop to see_also**

Use `Edit` to append one entry to the see_also list:

```
old_string:
see_also:
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../config-flow/README.md

new_string:
see_also:
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
  - ../acquisition-loop/README.md
```

- [ ] **Step 4: Verify**

```
Read docs/kb/scan-pipeline/README.md
```

Confirm:
- Out of Scope section shows the two reworded bullets with real links (no "future packet" text).
- `see_also` frontmatter now has 4 entries including `../acquisition-loop/README.md`.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/scan-pipeline/README.md
git commit -m "docs(kb): link scan-pipeline Out of Scope notes to acquisition-loop"
```

---

### Task 7: Update `docs/kb/scan-pipeline/csharp-consumer.md` loop-mechanics pointers

**Files:**
- Modify: `docs/kb/scan-pipeline/csharp-consumer.md`

- [ ] **Step 1: Read the current file**

```
Read docs/kb/scan-pipeline/csharp-consumer.md
```

Locate the two "Loop mechanics ... — out of scope for this packet." notes (one under "Input direction", one under "Output direction — acquisition-loop entry").

- [ ] **Step 2: Update the input-direction note**

Use `Edit` with `replace_all: false`:

```
old_string:
Loop mechanics (pipeline staging, error handling, shutdown) — out of scope for this packet.

new_string:
Loop mechanics (pipeline staging, error handling, shutdown) —
see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).
```

- [ ] **Step 3: Update the output-direction note**

Use `Edit` with `replace_all: false`:

```
old_string:
Loop mechanics (timing, backpressure, shutdown) — out of scope for this packet.

new_string:
Loop mechanics (timing, backpressure, shutdown) —
see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).
```

- [ ] **Step 4: Verify**

```
Read docs/kb/scan-pipeline/csharp-consumer.md
```

Confirm: neither "out of scope for this packet" phrase remains; both notes now point to `../acquisition-loop/csharp-orchestration.md`.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/scan-pipeline/csharp-consumer.md
git commit -m "docs(kb): link csharp-consumer loop-mechanics notes to acquisition-loop"
```

---

### Task 8: Cross-link sibling packets' see_also

**Files:**
- Modify: `docs/kb/ms1-acquisition/README.md`
- Modify: `docs/kb/exploration/README.md`
- Modify: `docs/kb/config-flow/README.md`

- [ ] **Step 1: Read each file's frontmatter**

```
Read docs/kb/ms1-acquisition/README.md   (first 20 lines)
Read docs/kb/exploration/README.md        (first 20 lines)
Read docs/kb/config-flow/README.md        (first 20 lines)
```

Note each file's current `see_also` list. For each file, the new entry will be appended as `- ../acquisition-loop/README.md`.

- [ ] **Step 2: Update `ms1-acquisition/README.md`**

Current see_also (from verification in Step 1):
```
see_also:
  - ../scan-pipeline/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
```

Use `Edit`:

```
old_string:
see_also:
  - ../scan-pipeline/README.md
  - ../exploration/README.md
  - ../config-flow/README.md

new_string:
see_also:
  - ../scan-pipeline/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
  - ../acquisition-loop/README.md
```

- [ ] **Step 3: Update `exploration/README.md`**

Current see_also:
```
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
```

Use `Edit`:

```
old_string:
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md

new_string:
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
```

- [ ] **Step 4: Update `config-flow/README.md`**

Current see_also:
```
see_also:
  - ../ms1-acquisition/README.md
```

Use `Edit`:

```
old_string:
see_also:
  - ../ms1-acquisition/README.md

new_string:
see_also:
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
```

- [ ] **Step 5: Verify all three**

```
Read docs/kb/ms1-acquisition/README.md   (first 20 lines)
Read docs/kb/exploration/README.md        (first 20 lines)
Read docs/kb/config-flow/README.md        (first 20 lines)
```

Each should now have `- ../acquisition-loop/README.md` in `see_also`.

- [ ] **Step 6: Commit**

```bash
git add docs/kb/ms1-acquisition/README.md docs/kb/exploration/README.md docs/kb/config-flow/README.md
git commit -m "docs(kb): add acquisition-loop see_also to sibling packet READMEs"
```

---

### Task 9: Holistic review

**Files:**
- Read-only: all files in `docs/kb/acquisition-loop/` + all 4 sibling READMEs + `scan-pipeline/csharp-consumer.md` + `docs/kb/index.md`

- [ ] **Step 1: Read the whole new packet**

```
Read docs/kb/acquisition-loop/README.md
Read docs/kb/acquisition-loop/csharp-orchestration.md
Read docs/kb/acquisition-loop/engine-entry-points.md
```

Confirm:
- All three have valid YAML frontmatter.
- All `code_anchors` appear in the source (spot-check 2-3 per file with `Read` against the target file:line).
- ASCII diagram in README is intact.
- No H1 in body of any file.
- `see_also` paths resolve.

- [ ] **Step 2: Verify cross-references round-trip**

For each external reference in the new packet:
- `../scan-pipeline/README.md` exists
- `../scan-pipeline/csharp-consumer.md` exists
- `../scan-pipeline/scan-command.md` exists
- `../scan-pipeline/bridge-functions.md` exists
- `../ms1-acquisition/README.md` exists
- `../ms1-acquisition/precursor-selection.md` exists
- `../ms1-acquisition/faims-cycling.md` exists
- `../exploration/README.md` exists
- `../exploration/variants-and-sweeps.md` exists
- `../exploration/scoring-and-winner.md` exists
- `../config-flow/README.md` exists

If any link dangles, fix it (either point at a different existing file or remove the reference).

- [ ] **Step 3: Verify sibling cross-links updated**

```
Grep "acquisition-loop" docs/kb/
```

Expected matches:
- `docs/kb/index.md` (1 entry in Packets list)
- `docs/kb/scan-pipeline/README.md` (2 Out-of-Scope bullets + 1 see_also entry)
- `docs/kb/scan-pipeline/csharp-consumer.md` (2 loop-mechanics notes)
- `docs/kb/ms1-acquisition/README.md` (1 see_also entry)
- `docs/kb/exploration/README.md` (1 see_also entry)
- `docs/kb/config-flow/README.md` (1 see_also entry)
- All files in `docs/kb/acquisition-loop/` (frontmatter + body)

- [ ] **Step 4: Check for dead phrases**

```
Grep "future packet" docs/kb/scan-pipeline/
Grep "out of scope for this packet" docs/kb/scan-pipeline/csharp-consumer.md
```

Expected: both return **no matches**. If any match remains, update it.

- [ ] **Step 5: Verify git log is clean**

```bash
git log --oneline phase-11 -15
```

Expected: 8 commits from this plan (one per Task 2–8), spec commit (`af89ac8`), plan commit.

- [ ] **Step 6: Report status**

Summarize in the implementer response:
- ✓ 3 files created in `docs/kb/acquisition-loop/`
- ✓ `docs/kb/index.md` updated
- ✓ `docs/kb/scan-pipeline/README.md` Out-of-Scope + see_also updated
- ✓ `docs/kb/scan-pipeline/csharp-consumer.md` loop-mechanics pointers added
- ✓ 3 sibling READMEs have `acquisition-loop` in see_also
- ✓ All anchors verified
- ✓ No "future packet" / "out of scope for this packet" phrases remain

No commit in this task — it is verification-only.

---

## Self-Review Notes

- Every spec section is covered by a task: README (Task 2), csharp-orchestration (Task 3), engine-entry-points (Task 4), index (Task 5), scan-pipeline cross-links (Tasks 6–7), sibling see_alsos (Task 8), verification (Task 9).
- All file contents are complete (no placeholders, no "similar to task N").
- No `inCustom`, no `scanId == "41"`, no "magic scan" anywhere — verified against the csharp-orchestration body.
- Task 1 establishes verified anchors as a pre-flight so Tasks 2–4 can use them without re-verifying.
- Task 9 is a belt-and-braces holistic check since sibling packets have drifted in past sessions and the scan-pipeline packet's cross-links must stay consistent.

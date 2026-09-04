---
title: C# Orchestration — startup, per-scan event flow, shutdown
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs
last_verified: 2026-09-04
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:178      # Main (CLI, method load, run folder, log4net)
  - FlashIDA/src/Flash/Flash.cs:291      # Main's stopRequest spin-wait, and the teardown after it
  - FlashIDA/src/Flash/Flash.cs:331      # InstrumentConnected
  - FlashIDA/src/Flash/Flash.cs:468      # OnContactClosure
  - FlashIDA/src/Flash/Flash.cs:567      # SendCustomScan
  - FlashIDA/src/Flash/Flash.cs:621      # OnAcquisitionStreamClosing
  - FlashIDA/src/Flash/Flash.cs:636      # ProcessSpectrum
  - FlashIDA/src/Flash/Flash.cs:811      # HandleAcqError
  - FlashIDA/src/Flash/Flash.cs:846      # ArmRunClock (run clock; arm vs restart)
  - FlashIDA/src/Flash/Flash.cs:878      # StopExecution
  - FlashIDA/src/Flash/Flash.cs:895      # RequestStop
  - FlashIDA/src/Flash/LogPathResolver.cs   # run-folder composition
  - FlashIDA/src/Flash/DataPipe.cs:12    # 2-stage TPL Dataflow
  - FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:16   # ProcessMS adapter
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

`Main` first parses the CLI, then **loads `method.json` and resolves this run's log
folder** — `LogPathResolver.Compose(runtime.log_dir, --rawname, now)`, `CreateDirectory`,
and the absolute result written back into `Config.Runtime.LogDir`. That has to happen
before `XmlConfigurator.Configure`, because configuring log4net opens the two appender
files immediately; the method load used to sit inside `InstrumentConnected`, roughly one
async event later, where its folder could never have reached them. A method file that
fails to load, or a log folder that cannot be created, exits 1 here via `Console.Error`
(`log` does not exist yet). See [ADR-0015](../../adr/0015-log-dir-is-resolved-host-side.md).

`Main` then kicks off instrument-container creation; the Thermo runtime fires
`InstrumentConnected` once it attaches. That handler:

1. Obtains `acquisition` + `control` + `scanControl` interfaces; detects FAIMS
   capability by scanning `scanControl.PossibleParameters`.
2. Builds `scanFactory` (for constructing `IFusionCustomScan`s from
   `ScanCommand`s — see
   [`../scan-pipeline/csharp-consumer.md`](../scan-pipeline/csharp-consumer.md)).
3. Consumes the already-loaded `methodParams` (see
   [`../config-flow/README.md`](../config-flow/README.md)) — the load itself moved to
   `Main`, above.
4. Constructs `FLASHIdaWrapper`, `UnifiedScanProcessor`, and `DataPipe`.
5. Subscribes `AcquisitionErrorsArrived` to `HandleAcqError`.
6. Waits for contact closure (or skips via `--nocc`).

`OnContactClosure` (`Flash.cs:468`) — or the `OverrideCC` branch inside
`InstrumentConnected` if contact-closure is disabled — then:

1. Subscribes `MsScanArrived` to `ProcessSpectrum`.
2. **Arms** the run clock via `ArmRunClock()` — a `System.Timers.Timer`
   (`duration`) whose elapsed callback is `StopExecution`. Armed, not started:
   see step 4.
3. Submits the first command via `scanControl.SetFusionCustomScan` to kick
   the instrument out of idle.
4. Later, when the handshake **echoes**, the `inCustom` latch in
   `ProcessSpectrum` calls `ArmRunClock()` again, which **restarts** the timer
   (ADR-0043). `global.duration` is therefore measured from the echo, and the
   wait for custom control is not charged against the run. The arm in step 2 is
   what still bounds a run whose handshake never echoes — load-bearing, because
   the send is wrapped in a `catch` that logs and carries on and
   `OnAcquisitionStreamClosing` is armed on `inCustom`, so that timer is the
   only stop trigger left besides `^C`.

   Deliberately **not** keyed to `IAcquisition.AcquisitionStreamOpening`, the
   event actually named for "the acquisition started": a scan executes and
   echoes with no acquisition open at all, and `InstrumentConnected` commands
   exactly that state via `SetMode(CreateOnMode())`. Worst-case process
   lifetime is `duration + (send → echo)`.

## Per-Scan Event Flow

`ProcessSpectrum` (`Flash.cs:636`) is the acquisition loop's heartbeat. Called
on the Thermo callback thread, it performs two independent actions per
invocation:

**1. Ingest** — push the scan into the async processing pipeline:

```csharp
dataPipe.Push(msScan);
```

The scan flows through `DataPipe` → `UnifiedScanProcessor.ProcessMS` →
`wrapper.ProcessScan` (P/Invoke into `FLASHIda::processScan`; see
[engine-entry-points.md](engine-entry-points.md)).

**2. Drain** — top the instrument up to `scheduling.target_depth`:

```csharp
int targetDepth = Math.Max(1, methodParams.Config.Scheduling.TargetDepth);

for (int sent = 0; !stopRequest && outstanding < targetDepth && sent < targetDepth; sent++)
{
    var cmd = new ScanCommand();
    if (wrapper.GetNextScanCommand(ref cmd) != 1) break;
    try
    {
        if (!SendCustomScan(scanFactory.BuildFromCommand(cmd))) break;
        outstanding++;
    }
    catch (InvalidOperationException ex) { log.Fatal(...); break; }
}
```

A **loop**, default target 2 (ADR-0033). This section used to say "at most
one command per invocation" — that was true until 0033 and is the thing 0033
exists to fix: one send per arrival can only oscillate the depth between 0
and 1 and can never *reach* 2, so a single `if` reads like the fix and
changes nothing. At depth 1 the instrument's queue is empty between every
pair of scans and a Tribrid does not wait — it runs its own method, measured
at 53 % of the duty cycle.

Three independent bounds, none redundant: `outstanding < targetDepth` is the
intent, `sent < targetDepth` guards against a throwing `BuildFromCommand`
spinning the instrument event thread, and `!stopRequest` is the latch half of
latch-then-cancel (ADR-0041). `GetNextScanCommand` is **no bound at all** —
it never returns 0.

`SendCustomScan` (`Flash.cs:567`) increments `currentNumber` (becomes the
`RunningNumber` on the submitted scan), logs a one-line summary, calls
`scanControl.SetFusionCustomScan`, and **returns whether the instrument
accepted it**. A refusal breaks the loop and is not counted (ADR-0041).

A burst of commands produced by a single `processScan` call accumulates in
the C++ queue and drains over subsequent `ProcessSpectrum` invocations.

## DataPipe Async Staging

`DataPipe` (`DataPipe.cs:12`) is a 2-stage TPL Dataflow:

```csharp
inputScans   = new BufferBlock<ScanData>();
processBlock = new ActionBlock<ScanData>(scan => { try { processor.ProcessMS(scan); } catch ... },
    new ExecutionDataflowBlockOptions { MaxDegreeOfParallelism = 1 });
inputScans.LinkTo(processBlock,
    new DataflowLinkOptions { PropagateCompletion = true });
```

**`ScanData`, not `IMsScan`** — the queue holds an owned snapshot. `Push`
runs `ScanData.From` synchronously on the *arrival* thread, while the handle
is still live, so it is not the cheap `BufferBlock.Post` this section used to
describe. That placement is the point: an `IMsScan` is a window onto
framework-owned memory the iAPI releases once the next scan replaces it as
`LastScan`, so a queued *handle* is only safe while the queue stays ~1 deep —
which it was by accident, because the drain blocked behind the deconvolution.

`MaxDegreeOfParallelism = 1` is stated rather than left to the TPL default,
because the engine leans on it: `processScan` is serialised against itself by
this block and by nothing else.

The buffer is **unbounded** — there is no back-pressure signal to the
instrument. If `ProcessScan` falls behind the instrument rate, memory grows.
Bounding it was considered and rejected: a dropped exploration variant wedges
its group for the rest of the run and leaks its pending-map entry.

## UnifiedScanProcessor Adapter

`UnifiedScanProcessor.ProcessMS` (`UnifiedScanProcessor.cs:16`) is the only
C# → C++ call site. It takes an **owned `ScanData` snapshot**, not an
`IMsScan` — the handle is read in `ScanData.From`, on the arrival thread,
while it is still live:

```csharp
public void ProcessMS(ScanData scan)
{
    int rc = wrapper.ProcessScan(scan.Mzs, scan.Intensities, scan.RetentionTime,
                                 scan.MsLevel, scan.ScanDescription, scan.FaimsCv,
                                 scan.InstrumentScanNumber);
    if (rc == -1) log.Error("ProcessScan was not successful (bridge returned -1)");
}
```

Seven arguments, not six: `InstrumentScanNumber` was appended by ADR-0035 as
the third identity channel — the only one that survives into the converted
mzML. `-1` is an already-handled failure (the wrapper logged it with a stack
trace); `0` is a normal gate rejection, not an error.

See also [`../scan-pipeline/csharp-consumer.md`](../scan-pipeline/csharp-consumer.md)
for the P/Invoke surface.

## Shutdown Sequence

**Three triggers, one path** (ADR-0041). Each calls `RequestStop`
(`Flash.cs:895`), which is one-shot and returns whether *this* call latched:

| Trigger | Reason logged |
|---|---|
| `duration.Elapsed` → `StopExecution` — the **run clock**, which starts at the handshake echo, not at startup (ADR-0043) | `Time is over` |
| `IAcquisition.AcquisitionStreamClosing` → `OnAcquisitionStreamClosing` (`:623`) | `Acquisition ended` |
| `Console.CancelKeyPress`, registered in `Main` as soon as `log` exists | `Ctrl+C` |

The `DataPipe` abort path is a fourth caller and inherits all of this.

`RequestStop` records the reason and closes the timer **first**, publishing
`stopRequest` in a `finally`. That order is load-bearing: the flag releases
`Main` into a teardown that returns from the process, so publishing it first
lets the line saying *why* the run stopped lose the race — and on the `^C`
path that is the only record there is. The `finally` keeps what the old
flag-first ordering protected: a throwing logger still latches.

**Teardown is the tail of `Main`** (`Flash.cs:291`) — one thread, once, in
written order, rather than inside `RequestStop`, which is called from four
different threads:

```csharp
while (!stopRequest) { }

try { if (msscans != null) msscans.MsScanArrived -= ProcessSpectrum; }
catch (Exception ex) { log.Error(...); }

try { if (scanControl != null) scanControl.CancelCustomScan(); }
catch (Exception ex) { log.Error(...); }

log.Info(String.Format("Exiting (depth {0})", outstanding));
```

`ProcessSpectrum`'s drain loop also reads `!stopRequest` — the **latch** half
of latch-then-cancel. Without it the cancel buys nothing, because the next
arrival tops the queue straight back up to `target_depth`, and the iAPI
guarantees arrivals continue after an acquisition closes.

Both steps are null-guarded because `msscans`/`scanControl` are null if the
instrument never connected — a `^C` during connection falls straight through
the spin loop, and so does `-t` test mode.

There is still **no explicit pipeline join** — no `DataPipe.Complete()`, no
wait on in-flight scans, no drain of the C++ queue, and no
`DisposeFLASHIda`. That is now deliberate on a ground that actually holds:
every one of the engine's five streams `.flush()`es per row and
`FLASHIda::~FLASHIda()` is `= default`, so nothing is lost by exiting and
there is no tail for a join to wait for. (It previously read *"the instrument
already stopped producing scans before the timer fires"* — a precondition
nothing enforces, since the **run clock** and the Xcalibur method are
independent clocks.)

## Error Patterns

Try/catch wraps every Thermo-API boundary:

- Instrument container creation (`Flash.cs:273`–`:289`)
- `ScanControl` acquisition (`Flash.cs:369`–`:394`)
- Method load + log-folder creation (in `Main`, before log4net is configured; reports via
  `Console.Error` rather than `log`)
- `DataPipe` creation (`Flash.cs:424`–`:433`)
- First custom-scan submission (in `OnContactClosure` and the `OverrideCC`
  branch inside `InstrumentConnected`)
- Each teardown step separately (`Flash.cs:291`–`:321`)

`AcquisitionErrorsArrived` → `HandleAcqError` (`Flash.cs:811`) logs
instrument-side errors (spray instability, etc.) but does not retry.

The code comment at `Flash.cs:390` warns: *"unhandled exception does not
crash the software the usual way, but lead to weird behavior"*. That is why
the try/catch density is high in the instrument-facing paths — and why
teardown guards its two iAPI calls individually rather than sharing one
`try`.

## Gotchas

- **NOBODY disposes the `IMsScan`** — this entry previously said disposal was
  *mandatory*, and that is the inversion that killed real runs. An `IMsScan`
  is a handle to **framework-owned** shared memory the iAPI releases itself
  once the next scan replaces it as the container's `LastScan`; our only job
  is to stop reading it. `ProcessSpectrum` says so explicitly. Disposing on
  the arrival thread frees memory the pool thread is still lazily
  enumerating; disposing on the pool thread instead faulted the `ActionBlock`
  on the first scan of the run. Pinned by `DataPipe_DoesNotDisposeScan`.
- **`DataPipe`'s `BufferBlock` is unbounded.** If `ProcessScan` falls behind
  the instrument rate, memory grows without bound. Deliberate — a dropped
  exploration variant wedges its group for the rest of the run.
- **`SendCustomScan` owns `RunningNumber` assignment.** It auto-increments
  `currentNumber` before submit; this value round-trips as the `Access ID`
  on the returning scan. Do not assign `RunningNumber` elsewhere.
  It also **returns whether the instrument accepted the command**, and that
  return must be honoured — a declined command counted as outstanding is
  never discharged, and two of them stop the drain loop for the rest of the
  run (ADR-0041).
- **The drain is a LOOP, not one command per arrival.** This entry used to
  say the opposite. `ProcessSpectrum` tops the instrument up to
  `scheduling.target_depth` (default 2) — one send per arrival can only
  oscillate the count between 0 and 1 and can never *reach* 2, which is why
  a single `if` reads like the fix and changes nothing (ADR-0033). The loop
  is bounded three ways: `outstanding < targetDepth`, `sent < targetDepth`,
  and `!stopRequest`. `GetNextScanCommand` is no bound at all — it never
  returns 0.
- **Spin-wait shutdown (`while (!stopRequest) {}`) burns a CPU core.** This
  is intentional; do not "improve" it without tracing the Thermo API
  thread-affinity requirements. Note the code **after** it is the run's
  teardown, so the loop is not the last thing `Main` does.

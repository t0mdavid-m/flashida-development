---
title: C# Orchestration — startup, per-scan event flow, shutdown
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs
last_verified: 2026-08-09
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:163      # Main (CLI, method load, run folder, log4net)
  - FlashIDA/src/Flash/Flash.cs:255      # Main's stopRequest spin-wait
  - FlashIDA/src/Flash/Flash.cs:266      # InstrumentConnected
  - FlashIDA/src/Flash/Flash.cs:401      # OnContactClosure
  - FlashIDA/src/Flash/Flash.cs:471      # SendCustomScan
  - FlashIDA/src/Flash/Flash.cs:508      # ProcessSpectrum
  - FlashIDA/src/Flash/Flash.cs:570      # HandleAcqError
  - FlashIDA/src/Flash/Flash.cs:578      # StopExecution
  - FlashIDA/src/Flash/LogPathResolver.cs   # run-folder composition
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

`OnContactClosure` (`Flash.cs:401`) — or the `OverrideCC` branch inside
`InstrumentConnected` if contact-closure is disabled — then:

1. Subscribes `MsScanArrived` to `ProcessSpectrum`.
2. Arms a `System.Timers.Timer` (`duration`) for the total method duration;
   elapsed callback is `StopExecution`.
3. Submits the first command via `scanControl.SetFusionCustomScan` to kick
   the instrument out of idle.

## Per-Scan Event Flow

`ProcessSpectrum` (`Flash.cs:508`) is the acquisition loop's heartbeat. Called
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

`SendCustomScan` (`Flash.cs:471`) increments `currentNumber` (becomes the
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

1. `duration.Elapsed` fires `StopExecution` (`Flash.cs:578`), which sets
   `stopRequest = true` and calls `duration.Close()`.
2. `Main`'s spin-wait (`Flash.cs:255`):

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

- Instrument container creation (`Flash.cs:236`–`:252`)
- `ScanControl` acquisition (`Flash.cs:299`–`:324`)
- Method load + log-folder creation (in `Main`, before log4net is configured; reports via
  `Console.Error` rather than `log`)
- `DataPipe` creation (`Flash.cs:354`–`:363`)
- First custom-scan submission (in `OnContactClosure` and the `OverrideCC`
  branch inside `InstrumentConnected`)

`AcquisitionErrorsArrived` → `HandleAcqError` (`Flash.cs:570`) logs
instrument-side errors (spray instability, etc.) but does not retry.

The code comment at `Flash.cs:320` warns: *"unhandled exception does not
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

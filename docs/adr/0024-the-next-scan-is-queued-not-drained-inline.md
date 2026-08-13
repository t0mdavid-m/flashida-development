# 0024. The next scan command is queued ahead, not drained on the instrument event thread

Status: Accepted (2026-08-13).

## Context

The instrument idles between scans. Three facts, none visible from the C# loop alone:

**We submit at the latest moment the API offers.** The iAPI raises `CanAcceptNextCustomScan` once the
instrument has processed a custom scan, and accepts the next one "until the `SingleProcessingDelay`
has expired or an instrument specific delay of few milliseconds has passed. After this time, the
instrument continues with the previous action, usually a method." We submit from `MsScanArrived`
instead, a whole readout later.

**Neither standard remedy is available here.** `SingleProcessingDelay` is not supported when running
LC-MS. `CanAcceptNextCustomScan` was already tried — `Flash.cs` still carries the subscription,
commented out, noting *"never fires as of current version of API, apparently fixed in API 3.5"* — and
where it does fire it is itself delayed. So the submission instant is pinned to `MsScanArrived`, and
the only latency under our control is what happens between that event and `SetFusionCustomScan`.

**That interval is expensive, and not because of lock contention.** Every
`FLASHIda::getNextScanCommand` flushes a `scan_commands.tsv` row to disk (`IdaLogger.cpp`, under
`analysis_mutex_`) and writes `[TRACK-CREATE] … std::endl` to stdout on the AGC and idle paths. It can
*additionally* park behind a whole deconvolution, because `processScan` holds `analysis_mutex_` for
its entire body. The old ordering made that self-inflicted: `ProcessSpectrum` pushed the arriving scan
into the pipeline and then immediately asked for the mutex `processScan` on that very scan was about
to take.

Vendor guidance on the event being blocked: *"Any listener to this event must handle the event as fast
as possible. It is good practice by analyzing tool to enqueue the scan into queue and process that
queue in another thread."* We obeyed that for the ingest half and violated it for the drain half.

## Decision

**Keep the next instrument request already drained and already built, in a `ConcurrentQueue` on
`Flash`, so the event handler only submits.** Four steps in `ProcessSpectrum`:

1. if the queue holds one or fewer, start a background thread to drain, build and enqueue;
2. post the arriving scan to the pipeline;
3. send the next queued request;
4. if the queue is empty, send a filler scan instead.

The queue is primed once at handshake-send, on both startup paths. That drain is synchronous and its
cost does not matter — nothing is being acquired yet.

`BuildFillerScan` is a separate method from `BuildHandshakeScan` despite identical parameters,
because the handshake stamps `id: HandshakeJobNumber` and its echo hits the latch in
`ProcessSpectrum`, which reassigns `currentNumber` and re-issues job numbers already used in the run.

**Deliberately kept small.** No abstraction layer, no injected seams: one field and two private
helpers in `Flash.cs`. This is the acquisition loop, and the cost of indirection here is higher than
the cost of the duplication it would remove.

## Consequences

**Every command is decided one scan earlier than it is sent.** Still exactly one drain per arriving
scan, so scan counts and AGC/survey rates are unchanged — a phase shift, not a throughput change.

**FAIMS CV transitions lag one scan.** Cycling advances the CV inside `processScan`'s MS1 branch and
then stores `current_faims_cv_`. Commands with a decided CV — MS2 (parent's), transition MS1 (next) —
set it at build time and cannot go stale; only the atomic-readers can (AGC, cycle-time MS1, idle
AGC/MS1). Nothing is mis-attributed: the returning scan reports its real `FAIMS CV` trailer.

**A command enqueued after the queue was filled waits one extra scan.** Priority inversion by one
slot.

**Exactly one fill runs at a time, enforced by an `Interlocked` flag — the depth check alone is not
enough.** This was got wrong first and is the single most important thing to preserve. A fill blocks
*inside* `getNextScanCommand`, before it can enqueue anything, so the queue stays empty for the whole
deconvolution; every arriving scan then passes the depth check and spawns another blocked thread,
while the filler each one sends generates the next arrival. Self-driving. And because the depth check
runs before the dequeue, at steady state `Count` is exactly 1, so the unguarded version created a
thread on *every* scan of the run.

The concurrency mattered beyond thread count. `getNextScanCommand` holds no lock across its body and
is documented as being called from the instrument event thread alone; its steps are check-then-act
across separate `queue_mutex_` acquisitions. Concurrent callers therefore mint duplicate AGC commands
(`needsAGC` → `recordAGCTime`), duplicate priority-0 cycle-time surveys, and one Step-5 AGC+MS1 pair
each. Each blocked thread had also *already* dequeued a real command and registered it pending before
parking, so a swarm drained the engine's backlog into limbo. With one fill in flight, `nextScans` also
stays FIFO in drain order, so the engine's priority ranking survives the hand-off.

**The handshake and the filler use AGC group 2, not the default group 1.** An AGC scan gain-corrects
the other scans in its group. Both of these are cheap IonTrap probes built directly rather than
through `BuildFromCommand`, so they command neither the configured source region (ADR-0011) nor a
FAIMS CV (ADR-0012) — in group 1 they would be the flux prescan for real acquisitions while measuring
a different ion population.

**Two known-open items, deliberately not fixed.** `nextScans` is static and never cleared, so on a
service reconnect `InstrumentConnected` re-runs, builds a fresh engine whose tracking-id counter
restarts at 0, and stale commands from the previous engine remain queued. And priming runs *after*
the handshake is sent while `MsScanArrived` is already subscribed, so the echo can beat it and make
the first scan of a run a filler.

**One command is orphaned per run.** Whatever is queued at shutdown was already registered pending and
already has its `scan_commands.tsv` row, and is never acquired. Consistent with the existing
no-drain-at-shutdown policy.

**Filler scans exist in the raw file and in no engine log.** They carry no `ScanDescription`, so the
engine rejects their echo at gate 1 exactly as it does the handshake's. Each filler echo re-enters
`ProcessSpectrum` and retries the queue, so a long deconvolution produces a run of them.

**`FillQueue` must never throw.** It is the whole body of a thread: an escaping exception kills it,
the queue never refills, and the run sends fillers for the rest of the gradient with the instrument
busy and the logs clean. Same failure shape `DataPipe`'s `ActionBlock` already documents.

**`ProcessSpectrum`'s body stays inside one `catch (Exception)`**, and this is stricter than what it
replaced — the original caught only `InvalidOperationException` from `BuildFromCommand`. It has to be
broader now because the change introduced two new throw sites on the instrument event thread:
`Thread.Start()`, which throws if the process cannot create a thread and is therefore most likely
under precisely the pile-up this design permits, and `BuildFillerScan`'s reflection. An unhandled
exception there does not crash the process the usual way; it leaves the API in a weird state.

**Nothing here is covered by a test.** `ProcessSpectrum` has none — `class Flash` is internal with
private statics and no `InternalsVisibleTo`. A testable seam was built and rejected as too much
machinery for this part of the loop; the tradeoff is deliberate, and verification is on the
instrument. No goldens move: neither `runInterleaved` nor `PushScanAndDrainFull` passes through
`ProcessSpectrum`.

## Verification

**Do not use `instrument_duration_ms`.** It is `received_ts - dequeue_ts`, and dequeue now happens
before submission rather than at it, so it includes the host-side queue residency and no longer
measures instrument time. `duration_received_ms` is the end-to-end figure that stays trustworthy;
`scan_commands.tsv` also now contains rows for commands stranded in `nextScans` at shutdown, which
were logged but never executed.

Nothing here is measured yet. The change exists to shorten the gap between a scan arriving and the
next command going out; compare `duration_received_ms` against a pre-change run of the same method.

# 0024. The next scan command is armed off the instrument event thread

Status: Accepted (2026-08-13) — **design accepted, not yet implemented**. Revisits one judgement in
[ADR-0015 (log dir is resolved host-side)](0015-log-dir-is-resolved-host-side.md), which put the
engine's per-row `flush()` on the instrument event thread and judged it acceptable; this ADR does
not remove the flush, it moves the caller.

## Context

The instrument idles between scans. Chasing why turned up three facts, none of them visible from
the C# loop alone.

**We submit at the latest moment the API offers, not the earliest.** The iAPI raises
`CanAcceptNextCustomScan` "once after the instrument has processed a custom scan," and will accept
the next one "until the `SingleProcessingDelay` has expired or an instrument specific delay of few
milliseconds has passed. After this time, the instrument continues with the previous action, usually
a method or a repetition." FLASHIda submits from `MsScanArrived` instead (`Flash.cs:517`), which
fires a whole readout later. Thermo's own reference implementation, embedded in
`dependencies/API-2.0.xml`, does the opposite on both counts: it sets `SingleProcessingDelay = 0.50`
("we will answer as fast as possible, so this is a maximum value") and drives the next scan from
`CanAcceptNextCustomScan`.

**Neither of those remedies is available here.** `SingleProcessingDelay` is not supported when
running LC-MS. `CanAcceptNextCustomScan` was already tried — `Flash.cs:336` carries the
subscription, commented out, with the note *"never fires as of current version of API, apparently
fixed in API 3.5"* — and where it does fire it is itself delayed. So the submission instant is
pinned to `MsScanArrived`, and the only latency left under our control is everything between that
event firing and `SetFusionCustomScan` returning.

**That interval is not cheap, and not because of lock contention.** Every
`FLASHIda::getNextScanCommand` (`FLASHIda.cpp:641`) performs blocking I/O:

| Cost | Site | Fires on |
|---|---|---|
| `commands_tsv_stream_.flush()` after formatting 32 columns | `IdaLogger.cpp:369`, under `analysis_mutex_` | **every** drain, all three log sites |
| `std::cout << "[TRACK-CREATE] …" << std::endl` — `endl` flushes | `FLASHIda.cpp:664, 691, 739, 750` | AGC (Step 1) and idle (Step 5), the common paths |

On top of that, `analysis_mutex_` is held by `processScan` for its entire body (`FLASHIda.cpp:84`),
and the dequeue-site log write needs it (`FLASHIda.cpp:707-716`) — for a real reason, not just
logging: `precursorIdForTracking_()` reads a map `processScan` writes. So the drain can additionally
park behind a whole deconvolution.

The current ordering makes that contention self-inflicted: `ProcessSpectrum` pushes the arriving
scan into the pipeline (`Flash.cs:552`) and *then* asks for the mutex that `processScan` on that very
scan is about to take (`Flash.cs:558`).

The vendor's own guidance on the event we are blocking: *"Any listener to this event must handle the
event as fast as possible. It is good practice by analyzing tool to enqueue the scan into queue and
process that queue in another thread."* `ProcessSpectrum` obeys that for the ingest half and
violates it for the drain half.

> Not yet measured. `scan_results.tsv` already carries `dequeue_ts`, `received_ts` and
> `instrument_duration_ms`, which quantify the round trip per scan; the mechanism above is derived
> from the API contract and the code, not from those numbers.

## Decision

**The host holds exactly one *armed command* — drained from the engine and built into an
`IFusionCustomScan` ahead of time — so the event handler only submits.**

```
OnContactClosure / the OverrideCC branch:
    SetFusionCustomScan(BuildHandshakeScan())      // unchanged; never taken from the queue
    arm the queue                                   // one drain, off the critical path

ProcessSpectrum(S_k):   [only when inCustom]
    1. if queue.Count <= 1  → spawn a background thread:
           drain → BuildFromCommand → enqueue (ScanCommand, IFusionCustomScan)
    2. dataPipe.Push(S_k)
    3. dequeue → SendCustomScan(built)
       └─ empty → send a filler AGC scan
```

**Arming happens at handshake-send.** The wait for contact closure can be minutes, which is
acceptable because no data is being acquired yet.

**The filler is a sibling of the handshake, never `BuildHandshakeScan()` itself.** Same cheap shape
— IonTrap, Turbo, `MaxIT = 1`, `Microscans = 1`, `IsAGC: true`, AGC group 1 — but submitted through
`SendCustomScan` so it takes a normal `++currentNumber`. Re-sending the handshake would echo back
with `Access ID == HandshakeJobNumber` and hit the latch at `Flash.cs:539`, which assigns
`currentNumber = HandshakeJobNumber` unconditionally, re-issuing instrument job numbers already used
earlier in the run.

**Fillers are dedicated background threads, not `Task.Run`.** A filler blocked on `analysis_mutex_`
that occupies a thread-pool slot competes with the `ActionBlock` task that has to run to release it;
the pool injects replacements at roughly 1–2/sec.

**The filler thread must never let an exception escape.** `BuildFromCommand` refuses a command whose
stage geometry is incomplete (`InvalidOperationException`, per
[ADR-0010](0010-positional-stage-arrays.md) — m/z 0 is malformed, not unused). On refusal: log FATAL,
drop, do not retry, go back to waiting. An escaping exception kills the thread, the queue never
refills, and `ProcessSpectrum` sends filler AGCs for the rest of the run — the instrument stays busy,
the logs stay clean, and nothing is acquired. This is the same failure shape `DataPipe`'s
`ActionBlock` already documents.

**The consume-refill logic lives in an extracted, injectable seam**, not in `Flash`'s private statics
— and the seam owns the armed-vs-filler decision, not `Flash`. Its `Next()` returns the armed command
if there is one and a filler otherwise, so `ProcessSpectrum` reduces to three lines and the one
branch worth testing sits where a test can reach it. Drain, build, filler-build and thread-spawn are
all injected; production passes `a => new Thread(a){ IsBackground = true }.Start()` and tests pass
`a => a()`, which is what keeps the suite free of sleeps. Because `Next()` makes armed and filler
indistinguishable to the caller, the run-dry observability required below lives in the seam too: WARN
on the first filler of each dry run, with the run length reported when it ends — not one line per
filler, which a long deconvolution would turn into dozens.

**Arming at handshake is synchronous**, not routed through the spawn path. The handshake is a
`MaxIT = 1` Turbo IonTrap scan whose echo can return in ~10–20 ms; an asynchronous arm would race it
for no benefit, and at that point nothing is acquiring and no `processScan` has ever run, so the
drain is uncontended.

**The filler is built fresh on each dry send**, never cached and re-stamped. `SendCustomScan` assigns
`RunningNumber` immediately before submitting, and mutating a `FusionCustomScan` the iAPI may still
hold from the previous submission is a race for no gain; `FillParameters` is tens of microseconds and
only runs on the dry path.

## Consequences

**Every command is decided one scan earlier than it is sent.** Nothing is acquired that would not
otherwise have been: it is still exactly one drain per arriving scan, so scan counts and AGC/survey
rates are unchanged. It is a phase shift, not a throughput change.

**FAIMS CV transitions lag by one scan.** Cycling advances the CV inside `processScan`'s MS1 branch
(`FLASHIda.cpp:244-266`), pushing a priority-0 MS1 stamped with the next CV and then storing
`current_faims_cv_`. Commands with a *decided* CV — MS2 (parent's), transition MS1 (next) — set it at
build time and cannot go stale. Only the atomic-readers can: AGC, cycle-time MS1, idle AGC and idle
MS1. So a transition decided during scan `k` reaches commands armed at `k+1`. **Nothing is
mis-attributed** — the returning scan reports its real `FAIMS CV` trailer, which
`UnifiedScanProcessor` passes across, so the engine's record matches physics. The one non-cosmetic
effect: an AGC prescan acquired at the outgoing CV estimates ion flux for a population the following
scans will not see, and with `PAGCGroupIndex = 1` shared by everything that is one imprecise fill
time per transition ([ADR-0012](0012-faims-enablement-is-explicit.md)).

**A command enqueued after arming waits one extra scan.** Priority inversion by exactly one slot — a
priority-0 follow-up pushed while a priority-3 survey is armed fires one scan later than today.

**Two refills can overlap**, because the guard is on queue depth rather than on whether a refill is
already in flight. While the drain is slow the queue stays empty, so successive arriving scans each
spawn another filler. Nothing is lost — each one drains and enqueues independently — and they recover
a stall *faster* than a single-occupancy filler would, since N of them drain back-to-back once the
mutex frees rather than one per arriving scan. That is why the simpler guard was kept. Two costs
follow. Each filler independently evaluates Steps 1 and 5 of `getNextScanCommand`, so two can mint an
AGC where one would do — benign, an extra cheap scan. And `ConcurrentQueue` orders by *completion*,
not by drain order, so a later-drained command can be submitted before an earlier one: priority
inversion beyond the one-slot case above, bounded, and only while the drain is slow.

**One orphan per run.** The armed command at shutdown was drained, so it already has its
`scan_commands.tsv` row and its `pending_scan_map_` entry, and it is never acquired. Consistent with
the existing deliberate no-drain-at-shutdown policy. The same accounting is why a drained command may
never be silently discarded.

**The startup arm produces one outlier log row.** Its `scan_commands.tsv` row is written at arm time,
so its `instrument_duration_ms` in `scan_results.tsv` covers the whole contact-closure wait. Expected,
not a defect.

**Filler AGCs appear in the `.raw` file and nowhere in the engine logs.** They carry no
`ScanDescription`, so their echo hits `processScan` gate 1 (`desc.size() < 3`) and returns silently —
no `scan_results.tsv` row, no `[TRACK-RESOLVE]` trace, exactly like the handshake. Correct (a control
signal, not data), but it means "how often did we run dry" is only answerable from a host-side
counter, which is therefore required.

**Each filler echo re-enters `ProcessSpectrum`**, spawning a filler check and retrying the queue — a
self-paced retry at roughly the AGC's own duration. A long deconvolution can therefore produce a run
of filler AGCs rather than one.

**`BuildFromCommand` is safe off the event thread, and this was verified rather than assumed.** It
terminates at `CreateFusionCustomScan` (`ScanFactory.cs:419` → `:115`), which is `new
FusionCustomScan()` — a plain object. It never touches `controler`, and `ScanFactory`'s only field is
set once in the constructor, so the event thread building a filler and a filler thread building a
real command cannot interfere. The two framework-calling creators (`ScanFactory.cs:93`, `:134`) are
not on this path; putting one there would break the guarantee.

**No golden moves, and no existing test covers this.** The log goldens drive through C++
`runInterleaved` and the continuity goldens through C# `PushScanAndDrainFull`; neither goes through
`ProcessSpectrum`, which has zero coverage today (`class Flash` is internal, all members private
static, no `InternalsVisibleTo`). That is the whole reason for the extracted seam.

## Alternatives considered

**`SingleProcessingDelay > 0`.** The one-line fix, and what Thermo's reference implementation does.
Rejected: unsupported when running LC-MS.

**Subscribe to `CanAcceptNextCustomScan`.** The correct hook in principle — it fires at the earliest
instant the instrument can accept, and a pre-armed command is what would make the required
"handled as fast as possible" achievable. Rejected: it did not fire on the API version this was
written against (`Flash.cs:335-336`), and where it does fire it is itself delayed.

**Drain at the tail of the `ActionBlock` delegate**, immediately after `processScan` releases
`analysis_mutex_`. Strictly the best on paper: zero contention *and* zero staleness, because the
armed command would see the just-processed scan. Rejected for coupling the cache refill to the
processing pipeline; the simpler trigger was preferred and the one scan of staleness accepted.

**Drain inline at the end of `ProcessSpectrum`, on the event thread.** Same staleness as the chosen
design, no thread — but it keeps the expensive drain on the event thread, merely after the send
instead of before. Rejected once the cost was understood to be blocking I/O rather than a rare mutex
collision.

**One long-lived filler thread gated by a semaphore.** Single-occupancy by construction, no in-flight
flag to reason about. Rejected in favour of per-scan spawn, which needs no cancellation or join at
shutdown and recovers faster from a stall: N blocked fillers all drain back-to-back once the mutex
frees, refilling the queue in one go rather than over N scans.

**A synchronous fallback drain when the queue is empty.** Never leaves the instrument unfed — but the
queue is empty precisely because a drain is blocked, so the fallback blocks on the same mutex, and it
double-drains, growing queue depth by one permanently each time it fires. The filler AGC does the
same job without either cost.

**Bounding the filler burst, or giving fillers their own AGC group.** Considered because a long
deconvolution can produce a run of prescans feeding group 1. Rejected for now in favour of matching
the engine's own idle behaviour exactly; revisit if fill times on post-filler scans look wrong.

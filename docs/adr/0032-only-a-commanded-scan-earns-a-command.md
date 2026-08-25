# 0032. Only a commanded scan earns a command

Status: Accepted (2026-08-25), implementation pending.
Related: [ADR-0008](0008-scan-identity-channels-are-separate.md) — the instrument job number, which
is the channel this decision reads. It is *not* the tracking id, and that distinction is the whole
reason a correct predicate exists.
[ADR-0031](0031-agc-prescans-are-interval-scheduled-only.md) — declared the handshake scan's
`IsAGC: true` out of scope and unchanged. This ADR changes its **PAGC group** while leaving `IsAGC`
alone; the prescan *schedule* is untouched.

## Context

`Flash.cs:ProcessSpectrum` does two things with an arriving scan: it ingests it, and it answers it
with one `GetNextScanCommand` drain. The ingest half checks provenance — `FLASHIda::processScan`
rejects a description shorter than three characters (`FLASHIda.cpp:87`) and rejects a tracking id
the engine never minted (`:111`, `status=not_found`). **The answer half checked nothing.** A scan
not good enough to deconvolve was good enough to buy a new command.

The instrument acquires scans FLASHIda did not ask for, *while custom control is latched*. This is
not a fallback after a lapse, and having work queued does not suppress it: the events appear at
depths where the queue provably cannot have been empty. Each such arrival produces one submission
with no matching execution, so

```
depth = 1 + arrivals — our_receipts = 1 + uncommanded_arrivals
```

which is monotonic, with no path that decrements it.

| Run | arrivals | uncommanded | predicted end depth |
|---|---|---|---|
| E. coli R1 | 20 160 | 12 | 13 |
| E. coli R2 | 20 364 | 8 | 9 |
| E. coli R3 | 20 275 | 10 | **11** |
| ProtMix | 13 557 | 7 | 8 |

Instrument-side telemetry from R3 measured depth stepping 2 → 4 → 9 -> **11**, with no
down-steps. Zero of the 74 356 receipts across the four runs carried an absent or empty
`Access ID`; the uncommanded ones carried the literal `"0"`, the value the iAPI reserves and which
we therefore never send.

Thermo documents the consequence directly (`dependencies/API-2.0.xml`, `IScans.SetCustomScan`):

> The operation on the instrument is undefined if several custom scans are set without having the
> instrument dealt with the previous custom scans. However, the instrument will not stop to run,
> choke or show any other fatal error.

So the state this produces is vendor-undefined *and specified to fail silently*. The observed
symptoms — MS1 injection time railing at its 246 ms ceiling on 12–25 % of scans, local ion
population varying 57–566× against 1.5× for the on-device method on the same sample, and the AGC
prescan's own p95 injection time rising from 0.9 ms to the 10 ms hardware clamp despite a commanded
`max_it` of 1 ms — are consistent with it. They are measurements, not claims this repository can
verify.

Two further facts shape the decision. `ScanFactory.cs:460` hardcodes `AGCgroup: 1` for every command
it builds, so **there is exactly one PAGC group in the system** and the prescan gain-corrects
everything in it. And `BuildHandshakeScan` (`Flash.cs:474-489`) is bit-identical to `makeAGC()` in
everything that makes the instrument treat it as a prescan — `IsAGC: true`, group 1, IonTrap/Turbo,
`AGCTarget 30000`, `MaxIT 1`, one microscan — while sending **no** RF lens, source CID, source CID
scaling or FAIMS keys. It therefore publishes a flux estimate taken through the instrument method's
source region and FAIMS state into the group that gain-corrects the first real scans of every run,
which are acquired through ours.

## Decision

**A command is answered to the scan that earned it.** An uncommanded arrival is ingested and not
answered.

The predicate is the instrument job number being the iAPI-reserved `"0"`, and the drain is gated on
a derived count of outstanding commands rather than on the predicate alone:

- an arrival whose `Access ID` is not `"0"` has spent one of our commands;
- a command is submitted only while the outstanding count is at or below zero;
- the count is incremented **inside** the success path, after submission returns.

**The handshake scan moves to its own PAGC group** (`AGCgroup: 2`). `IsAGC` stays `true`.

Depth is reported on the existing per-arrival log line, and a skipped drain is logged at `Warn`.

## Why

**The safe error direction is the permissive one, which is counter-intuitive.** Over-answering
ratchets depth and degrades the run — bad, survivable, and exactly the status quo. Under-answering
drives depth to zero, at which point the instrument acquires only its own scans, every subsequent
arrival is uncommanded, and a pure predicate never sends again: `inCustom` stays latched, the log
keeps writing, and acquisition is over. That failure is **absorbing**. Every way of misreading the
trailer must therefore land on "answer it", which rules out a range check on the job number and
rules out keying on the tracking id — both fail closed on a truncated or absent value.

**The counter exists because the guard promotes an existing tolerated failure into a fatal one.**
`Flash.cs:580-587` catches `InvalidOperationException` from `BuildFromCommand`, logs `Fatal`, and
carries on having dequeued a command and submitted nothing. Today the next arrival — of any kind -
recovers it. Under a bare predicate the next arrival is uncommanded, and the run is dead. The same
holds for `SetFusionCustomScan` returning false, whose return value `Flash.cs:512` discards while
`currentNumber` has already advanced. Incrementing only on the success path makes both self-heal on
the following arrival.

**Deriving depth rather than accumulating it** keeps a single bad tick from being permanent: the
instrument executes our custom scans in submission order, so a receipt of job number `A` means every
command we sent at or below `A` is done.

**The handshake's group changes and its `IsAGC` does not**, because the smaller change is the one
with a known blast radius. `IsAGC: false` would be cleaner — nothing reads the handshake's spectrum
and `processScan` discards it — but the handshake is submitted before custom control is established,
and a run whose latch never fires acquires nothing at all. That is the worst failure this codebase
has, and ADR-0008 records it happening once already. Moving the group removes the polluted estimate
from group 1 without changing whether the instrument treats the scan as a prescan.

## Consequences

### Group 1 has no prescan until the first scheduled one

With the handshake moved out, the opening scans of a run are gain-corrected by whatever the
instrument does for a PAGC group with no measurement yet, rather than by a measurement taken through
the wrong source region. This is expected to be better and is not verified. At
`scheduling.agc_interval_seconds: 1` the gap is about one second.

### No golden moves, and the reason is itself a finding

Both changes are confined to `Flash.cs`. `PAGCGroupIndex` is not in `scan.Values`, is not logged and
does not cross the bridge. Log goldens are produced by `ContinuityTestHarness`, which never routes
through `ProcessSpectrum`. Byte-identical, zero recapture, one push.

But every harness drive site drains **many** commands per pushed scan -
`ContinuityTestHarness.cs:115` (`while ... == 1`), `:196` (bounded, idle-counting), `:301` (capped
at 8) — whereas production sends **one** command per arrival. The harness models an instrument with
no queue depth, so this defect was not merely untested but **structurally unobservable** to the
suite. Twenty-two modes × five streams of green goldens were never evidence about it. Closing that
gap is the harness-conformance migration in `docs/superpowers/plans/`, which is golden-moving and
much larger than this change.

### Acceptance is a log read, because no test can reach this code

No file in `Flash.Tests` references `ProcessSpectrum`, `SendCustomScan` or `BuildHandshakeScan`, and
`Flash.csproj` pins the offline harness as the assembly entry point, so CI has never executed the
production entry point at all. The next instrument run is the verification: depth on the per-arrival
line must never exceed one, and the count of `Warn` skips must equal the count of literal-`"0"`
receipts.

### A command that never returns still deadlocks

Not covered by this decision: an aborted scan, a spray dropout, or any command of ours that is never
echoed. The outstanding count stays high and nothing is submitted again. Only a watchdog catches
that, and one was considered and rejected below. This is a knowingly accepted gap, not an oversight.

### The deployed engine is not the engine this was reasoned about

`FlashIDA/dll/OpenMS.dll` is dated 2026-06-19, 198 OpenMS commits behind, and predates ADR-0031 — so
the runs quoted above came from an engine that emitted a prescan from the idle path on every empty
drain (4 560 prescans in R3, one per 0.77 s). Shipping this change means shipping a fresh DLL and
therefore a different prescan cadence. Attribution of any improvement should account for that.

## Alternatives rejected

- **The bare predicate with no counter.** One line, and correct in accounting. Rejected because the
  `catch` at `Flash.cs:584` and the discarded submit return at `:512` each convert it into a silent
  dead run, and both are reachable today.
- **A watchdog** ("no submission in K arrivals ⇒ force one"). The only thing that catches a command
  which never returns. Rejected as machinery the acquisition loop has explicitly refused before; the
  counter recovers the two reachable triggers without it, and forcing a submission on a timer
  re-introduces the unpaired send this ADR exists to remove.
- **Driving the drain from `CanAcceptNextCustomScan`** (`Flash.cs:336`, commented out). This is the
  *structurally* correct clock — the instrument raises it once per custom scan it consumed, and an
  uncommanded scan cannot raise it, so no predicate would be needed. Rejected for now because the
  comment beside it records that it never fired on the API version FlashIDA was written against,
  `CustomScanListner` no longer exists, and re-wiring the loop onto an event we cannot test is a
  larger change than the evidence demands. It remains the better long-term shape.
- **A range check on the job number**, or keying on the tracking id instead. Both are more precise,
  and both fail in the absorbing direction on a malformed value. Precision is the wrong objective
  here.
- **Setting the handshake to `IsAGC: false`.** Cleaner, and arguably what the scan should always have
  been. Deferred: it changes the handshake itself, and a handshake that fails to latch is a run that
  acquires nothing.

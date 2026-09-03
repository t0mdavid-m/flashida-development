# 0041. A run ends where its acquisition ends

Status: Accepted (2026-09-03)
Related: [ADR-0032](0032-only-a-commanded-scan-earns-a-command.md) and
[ADR-0033](0033-an-idle-instrument-acquires-its-own-method.md) — this ADR does not change the depth
*threshold* either of them set, but it does correct the accounting 0032 introduced and 0033 kept
(see *Decision 8*). [ADR-0008](0008-separate-scan-identity-channels.md) — the `inCustom` latch this
ADR reuses as an arming predicate is the handshake echo 0008 defines.

## Context

FLASHIda's stop path was four statements:

```csharp
private static void RequestStop(string reason)
{
    if (Interlocked.Exchange(ref stopRequested, 1) != 0) return;
    stopRequest = true;
    log.Info(reason);
    if (duration != null) duration.Close();
}
```

`Main`'s spin loop then exited, logged `"Exiting"`, and returned. That was the whole of it. A grep
across `FlashIDA/src` found **zero production call sites** for every API that would end a run
tidily:

| API | Call sites in production |
|---|---|
| `msscans.MsScanArrived -=` | 0 (subscribed at two sites, never removed) |
| `IScans.CancelCustomScan` | 0 |
| `IAcquisition.CancelAcquisition` | 0 |
| `wrapper.Dispose()` → `DisposeFLASHIda` | 0 (finalizer only) |
| `dataPipe.Complete()` / `WaitForCompletion()` | 0 (tests only) |
| `IAcquisition.AcquisitionStreamClosing` | never subscribed |

Two consequences followed.

**The instrument kept our commands.** At `scheduling.target_depth: 2` (ADR-0033's default) the
instrument holds up to two submitted-but-unexecuted commands at any moment. Nothing dropped them at
a stop, so they executed after the host was gone — into whatever raw file was open by then. In a
sequence, that is the *next sample's*.

**The instrument ending the acquisition was invisible.** `global.duration` and the Xcalibur method
are independent clocks and neither constrains the other. The acquisition-loop KB entry justified the
missing teardown with *"the instrument already stopped producing scans before the timer fires, so
the tail work is not useful"* — a precondition nothing enforces, and which fails in **both**
directions. Shorter than the method: FLASHIda exits and the instrument runs its own method for the
remainder (ADR-0033's pathology, at full scale). Longer: the acquisition closes and FLASHIda keeps
commanding into a file that is no longer there.

The iAPI is explicit that the boundary is soft rather than quiet:

> Scans may be created without an explicite acquisition, so further scans may arrive after an
> acquisition stopped. It may even be possible that few scans belonging to the last acquisition may
> arrive and that an opened rawfile will gather them because of a flushing data queue on the
> transport layer.
> — `dependencies/API-2.0.xml:194-207`, `AcquisitionStreamClosing`

That sentence is why a cancel needs a latch in front of it, and why *any* design that waits for
quiescence is unimplementable: there is no quiescent state to detect.

### Why "survive the boundary" was not an option

Treating `AcquisitionStreamClosing` as a boundary FLASHIda resets across, rather than as terminal,
means undoing five independent single-run assumptions:

| # | Assumption | Where |
|---|---|---|
| 1 | contact closure unsubscribes itself on first fire, so a second run can never latch | `OnContactClosure` |
| 2 | `duration` is `AutoReset = false`, started once, `Close()`d at stop — the clock cannot re-arm | `InstrumentConnected` / `RequestStop` |
| 3 | the run folder and all seven log files are minted once in `Main`, before the instrument connects | `LogPathResolver.Compose` |
| 4 | `inCustom`, `currentNumber`, `outstanding` are statics with no reset path | `Flash.cs` fields |
| 5 | engine state — exclusion map, `ProteoformTracker`, tracking-id counter — lives in one `CreateFLASHIda` | C++ |

Row 5 has no bridge export and would need a sixth, changing an ABI that four ADRs constrain. That is
a different project.

## Decision

1. **Scope is the instrument-side queue** — the outstanding commands of `CONTEXT.md`'s
   *Outstanding command*, never the engine's `ScanCommandQueue`. The engine queue has no empty state
   to drain to: Step 5 of `getNextScanCommand` mints an idle survey rather than returning 0, so
   "flush it" is an infinite loop, not a terminating condition.
2. **Three triggers, one path**: the existing duration timer, `IAcquisition.AcquisitionStreamClosing`,
   and `Console.CancelKeyPress`. The `DataPipe` abort path inherits it by already routing through
   `RequestStop`. `StateChanged` was rejected — it also fires for Standby/Off transitions unrelated
   to a run ending.
3. **`AcquisitionStreamClosing` is terminal**, for the five reasons tabled above.
4. **Latch first, then cancel**, uniformly across all three triggers. Order is load-bearing, not
   stylistic: `ProcessSpectrum` tops the queue back up to `target_depth` on the next arrival, and
   the iAPI guarantees arrivals continue past the close, so a cancel with no latch in front of it
   buys nothing. Per-trigger divergence — flushing on the timer, cancelling on the other two — was
   rejected: it preserves at most two MS2 scans at the tail of a gradient and costs two stop paths
   that can only ever be exercised on hardware.
5. **Teardown lives in `Main`, after the spin loop.** `RequestStop` is called from four different
   threads (timer pool, `DataPipe` pool, instrument event, `^C` handler); `Main`'s tail is one
   thread, once, in written order.
6. **`RequestStop` publishes its latch last, in a `finally`**, and returns whether *this* call
   latched. See *Why the flag order reversed* below.
7. **`AcquisitionStreamClosing` is armed on `inCustom`.** The event carries no identity, and
   FLASHIda never calls `StartAcquisition`, so it has no handle on "its own" acquisition to compare
   against. Unarmed, a previous sample's stream closing while we wait for contact closure stops a
   run that has not started — and logs a sentence that is true about somebody else's acquisition.
   Armed, the failure direction is the old behaviour.
8. **A declined command is not an outstanding one.** `SetFusionCustomScan`'s documented `bool` was
   discarded; a refusal now `break`s the drain for that arrival and is not counted, and the
   decrement is clamped at 0.
9. **No `DisposeFLASHIda`, no `DataPipe` join, ingestion left running.** All five engine streams
   `.flush()` per row (`IdaLogger.cpp:317,473,669,850,917`) and `FLASHIda::~FLASHIda()` is
   `= default` (`FLASHIda.cpp:132`) — nothing is lost by exiting, there is no tail for a join to
   wait for, and because teardown disposes nothing there is no use-after-free for one to prevent.
10. **Unconditional — no config key.** A knob would move `config_schema_reference.json` and require
    the three-site update, and there is no coherent *off* value: "do not cancel on stop" means
    "leave commands queued into the next acquisition". Unlike ADR-0033's `target_depth`, this is not
    a tuning dial with an operational trade-off; its escape hatch is not deploying the build.

## Why the flag order reversed

The code being replaced carried an explicit, opposite instruction:

```csharp
//set the flag FIRST: a throw in the logging or timer teardown below must not be able to
//strand the run in the Main spin loop.
stopRequest = true;
```

That was correct for as long as **nothing followed the spin loop**. Setting the flag then meant only
"stop waiting". It now also means "begin teardown, then return from `Main`" — so the two statements
after it were racing a process on its way out, and the one that loses is `log.Info(reason)`: the
line recording *why* the run stopped, and on the `^C` path the only record there is.

The `finally` gets both properties rather than trading one for the other. The reason is written
before the latch is visible; a throwing logger or a throwing `Close()` still latches, so a systemic
logging failure still cannot strand the run in the spin loop. The cost is that the latch is delayed
by one log call, during which `ProcessSpectrum` may send once more — which is exactly the old
behaviour, so the failure direction is "no worse".

## Why a refusal must `break` rather than retry

Decision 8 has a failure mode in each direction, and only the `break` survives both. Writing
*honest false* for "the command really did not go" and *lying false* for "it went, the return value
is wrong":

| | honest false | lying false |
|---|---|---|
| **count it anyway** (the old code) | depth inflates +1 permanently; two of those and the real queue is 0 while the counter reads `target_depth` — **absorbing**, because no queued command means no commanded arrival, no decrement, and the loop never fires again | correct |
| **don't count it, keep looping** | self-heals | re-sends within the arrival; the counter drifts negative, and when the return value recovers the negative base makes the loop send its full allowance every arrival while one executes — **unbounded ratchet** |
| **don't count it, `break`** | one attempt per arrival, next arrival retries — self-heals | one command sent per arrival, one arrival per command → the real queue parks at depth 1 | 

The `break` is not invented for this; it is the shape the neighbouring `InvalidOperationException`
path already uses, and for the same reason — one report per arrival, the next arrival retries.

The clamp closes the remaining hole in the bottom-right cell: a counter left at −10 would, on
recovery, do exactly what the middle row does. Clamped, recovery costs a one-time overshoot to
`target_depth + 1` and then holds. It must be **nested** rather than folded into the condition as
`scanId != "0" && outstanding > 0` — that version sends a commanded scan arriving at depth 0 into
the `else`, where it logs itself as uncommanded.

## Consequences

### No automated coverage exists, and none was added

`class Flash` is internal, every member is a `private static`, and the assembly has **no
`InternalsVisibleTo`** — a constraint `ScanFactory.cs:159` and `:200` already record. CI compiles
`Flash.cs` and executes not one line of it; no test file references `Flash.Flash`,
`ProcessSpectrum`, `RequestStop`, `StopExecution` or `SendCustomScan`.

Of this change, only `RequestStop`'s one-shot return is testable without an instrument, and it is
`Interlocked.Exchange`-grade logic — a test over it would pass under every bug it could plausibly
have. Adding `InternalsVisibleTo` to reach the rest was considered and rejected: it buys coverage of
that one part and opens `Flash.cs` to the test-driven seams this codebase deliberately keeps out of
the acquisition loop.

The acceptance test is therefore an instrument checklist, of which this is the decisive item:

> Stop the run from Xcalibur mid-gradient, let the sequence advance, and confirm the **next**
> sample's raw file contains zero scans whose `Scan Description` begins with a FLASHIda tracking id.

Supporting items: the duration path must log `Time is over` **then** `Exiting (depth N)`, in that
order (a missing or trailing reason line means the `finally` ordering did not hold); a single `^C`
must exit without needing a second; and launching while a previous acquisition is still finishing
must log `Acquisition stream closed before custom control latched - ignoring` and then run normally.

### FLASHIda now exits mid-sequence

Previously, a `Flash.exe` whose `global.duration` outlasted a sample kept running across the
boundary — by accident, since it could not observe it. It now stops. That is a behaviour change for
anyone running one long-lived process over a multi-sample sequence, not merely a cleanup, and it is
the direct consequence of Decision 3.

### No golden moves

No golden path executes `Flash.cs`. Log goldens and continuity JSONs drive `ContinuityTestHarness`;
the 13 regression TSVs run `Flash.exe`, whose `StartupObject` is pinned to
`Flash.IDA.FLASHIdaWrapper` (`Flash.csproj:38`), not `Flash.Flash`. No config key was added, so
`config_schema_reference.json` is untouched.

### Three risks only an instrument can settle

- **R1 — does returning from `Main` actually end the process?** If any iAPI thread is a *foreground*
  thread it does not, and the process lingers. The `MsScanArrived` unsubscribe exists for this case
  and this case alone: on the normal path it is redundant against the latch, but if the process
  lingers it is the only thing stopping `ProcessSpectrum` ingesting — and the engine appending to
  five log files — indefinitely, with no run and nobody watching. **Record the answer here when it
  is known.**
- **R2 — can two acquisitions overlap?** If a previous sample's `Closing` can arrive *after* our
  handshake has echoed, the `inCustom` arming does not save us. It narrows the window; it cannot
  close it, because the event carries nothing to match against.
- **R3 — `CancelCustomScan` at depth 2 is vendor-undefined**, in exactly the way `SetCustomScan` is
  (ADR-0033): it is documented against a one-outstanding-command model, so it may clear one command
  or both and will not say which. The latch bounds the damage either way; `scheduling.target_depth: 1`
  sidesteps it entirely with no rebuild.

### What is still not covered

Closing the console window, `taskkill /F`, and an unhandled exception all still leave the queue
behind. `Console.CancelKeyPress` covers `^C` and `Ctrl+Break` only. `AppDomain.ProcessExit` would
add the console-close case, but under a short and version-dependent budget, and it would give
teardown a second entry point able to interleave with `Main`'s own — an accepted, stated gap rather
than an oversight.

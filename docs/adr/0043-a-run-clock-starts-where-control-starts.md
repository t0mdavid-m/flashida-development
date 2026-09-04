# 0043. A run clock starts where control starts

Status: Accepted (2026-09-04)
Related: [ADR-0041](0041-a-run-ends-where-its-acquisition-ends.md) — the symmetric half, and
deliberately **asymmetric**: a run *ends* where its acquisition ends, but does not *begin* where its
acquisition begins. [ADR-0008](0008-separate-scan-identity-channels.md) — the handshake echo this
ADR keys on is the latch 0008 defines. [ADR-0033](0033-an-idle-instrument-acquires-its-own-method.md)
— the `SetMode(CreateOnMode())` whose transition time this ADR stops charging to the run.

## Context

`global.duration` is authored as *"Acquisition duration in minutes"*. The timer enforcing it was
started before the handshake scan was even sent — at `Flash.cs:438-442` (`--nocc`) and
`Flash.cs:478-482` (contact closure), in both cases four statements ahead of the
`SetFusionCustomScan` that asks the instrument for custom control. Everything between asking and
receiving was charged against the run.

Usually that is one scan round trip. `InstrumentConnected` makes it unbounded in one real case,
because it commands the instrument on and does not wait:

```csharp
// Flash.cs:348-352
if (acquisition.State.SystemMode == SystemMode.Off || acquisition.State.SystemMode == SystemMode.Standby)
{
    log.Info("Switching instrument on...");
    acquisition.SetMode(acquisition.CreateOnMode());   // fire-and-forget
}
…                                        // ~80 lines later, in the SAME call:
duration.Start();                        // the clock, while the instrument is still in transition
scanControl.SetFusionCustomScan(BuildHandshakeScan());   // cannot execute yet
```

On the `--nocc` path both sit inside one `InstrumentConnected` invocation, so a launch from Standby
bills the whole On transition to the gradient. On the contact-closure path the arm happens in
`OnContactClosure`, long after the instrument was switched on, so the same code costs sub-second.
The defect is real but its size is entirely path-dependent — which is why the change ships with a
log line that measures it rather than an assumption about it.

### Why not `AcquisitionStreamOpening`

The obvious key is the event actually named for the thing: `IAcquisition.AcquisitionStreamOpening`,
*"fired when a new acquisition is started and the system is about to open rawfiles"*. Its sibling
`AcquisitionStreamClosing` is already subscribed one line away (`Flash.cs:346`), so wiring it is a
one-liner and any future reader will reach for it.

It was rejected, and the disqualifying sentence is in the same doc block:

> Scans may be created without an explicite acquisition if the instrument is 'just' set to running.
> — `dependencies/API-2.0.xml:179-192`, `AcquisitionStreamOpening`

FLASHIda **manufactures exactly that state itself**, in `InstrumentConnected`, ~90 lines before it
sends the handshake. So the two events answer different questions, and only one of them is the
question `global.duration` asks:

| Event | Answers |
|---|---|
| handshake echo (`inCustom`) | *is the instrument under our control?* |
| `AcquisitionStreamOpening` | *has the instrument opened an acquisition?* |

`global.duration` bounds how long **FLASHIda** goes on acquiring, and FLASHIda cannot acquire
anything before it holds custom control. Keying the clock to the acquisition would also have
redefined `--nocc` — today *"ignore contact closure, start now"*, then *"ignore contact closure,
wait for an acquisition instead"* — so a `--nocc` launch on an idle instrument that never received a
sequence would wait forever rather than exiting after `duration`. That is a larger behavioural
change than the defect being fixed, and it is not what the flag means.

A composite (*both must hold*) was also considered and rejected for the same reason plus a second
way to never start.

## Decision

1. **The run clock starts at the handshake echo** — the `inCustom` latch in `ProcessSpectrum`, not
   at the send and not at the first commanded scan. This is the first instant at which any
   FLASHIda-commanded scan can exist.
2. **Armed before the send, restarted at the latch.** `ArmRunClock()` serves three sites with two
   meanings, told apart by `duration == null`. The arm is what keeps a run whose handshake never
   echoes bounded — load-bearing, because the send is wrapped in a `catch` that logs and carries on
   (`Flash.cs:495-498`) and `OnAcquisitionStreamClosing` is armed on `inCustom` (ADR-0041,
   Decision 7), so if the latch never fires this timer is the **only** stop trigger left besides
   `^C`. A handshake failing to latch is not hypothetical: ADR-0008 records it happening.
3. **Worst-case process lifetime becomes `duration + (send → echo)`.** Accepted deliberately: the
   alternative that bounds it tighter is a second, short watchdog timer, which needs a number
   nobody can justify without hardware and puts a second timer in the acquisition loop.
4. **Guarded by `!stopRequest` *and* `catch (ObjectDisposedException)`.** `RequestStop` calls
   `duration.Close()`, the iAPI goes on delivering scans after a stop, and `Main` does not
   unsubscribe `ProcessSpectrum` until after the spin loop releases — so a `^C` during the
   send→echo window can land a restart on a disposed timer, on the arrival thread, where an
   unhandled exception *"does not crash the software the usual way, but lead[s] to weird
   behavior"*. `^C` is the only reachable trigger for it — the other three all need `inCustom` or
   the full duration — and it is precisely the one ADR-0041 wired early. The `stopRequest` check
   states the intent; it cannot be made atomic against `Close()`, which is what the catch is for.
5. **One `ArmRunClock()` rather than two inline blocks.** The four-line timer setup existed twice
   and its meaning changed, which is when duplication drifts. `BuildHandshakeScan()` is the local
   precedent, extracted for exactly this reason after the two startup paths drifted apart and the
   contact-closure run acquired nothing.
6. **The restart logs its own cost**, based at the **arm** and measured with a monotonic
   `Stopwatch`: `Run clock restarted at the custom control latch - N s armed but not charged`. The
   base is the arm rather than the send because arm→latch is exactly the interval the old code
   charged and the new one does not; send→latch would measure only the round trip. `Flash.cs` has
   no automated coverage, so this line is the acceptance test.
7. **Unconditional — no config key.** There is no coherent *off* value: "charge the wait for
   control against the run" is the defect.

## Consequences

### Its value is path-dependent, and the log line is what tells you which path you are on

On the contact-closure path with the instrument already On, the arm→latch gap is one scan round
trip and **this change buys sub-second**. It pays off from Standby and on `--nocc`. Do not cite it
as a fix for a run that ended early without first reading `N` out of the log.

### No automated coverage exists, and none was added

`class Flash` is internal, every member is a `private static`, and the assembly has no
`InternalsVisibleTo` — ADR-0041 considered adding one and rejected it. CI compiles `Flash.cs` and
executes not one line of it. The acceptance test is an instrument checklist:

| # | Scenario | Assertion |
|---|---|---|
| 1 | Contact closure, instrument already On | `Run clock restarted … N s armed but not charged`, **N < ~2 s** — confirms inertness on the production path |
| 2 | `--nocc` from **Standby** | N ≈ the On-transition time; the run ends `duration` after the **latch**, not after the arm |
| 3 | Ordering, both paths | `Run clock armed` appears **before** `Sent the handshake scan` — the arm is unconditional, so a handshake that never echoes still bounds the run |
| 4 | `^C` during the send→echo window | exits on one press; logs `Ctrl+C` then `Exiting (depth N)`; **no `ObjectDisposedException`** — the only exercise of Decision 4 |

### No golden moves, and nothing crosses the bridge

No golden path executes `Flash.cs`: log goldens and continuity JSONs drive `ContinuityTestHarness`,
and the 13 regression TSVs run `Flash.exe` with its `StartupObject` pinned to
`Flash.IDA.FLASHIdaWrapper`. `global.duration` is **host-only** — `Config.cpp:321` accepts the key
in `rejectUnknownKeys` and no engine code ever reads it — so no config key was added, the bridge is
untouched, and `config_schema_reference.json` does not move.

### What was deliberately left alone

`currentNumber = HandshakeJobNumber` stays *outside* the one-shot `!inCustom` guard, exactly as
before. A second id-41 arrival would reset the running number mid-run and reuse job numbers already
in flight — suspect, pre-existing, and orthogonal to the clock. Noted here so the next reader of
that block does not have to rediscover it.

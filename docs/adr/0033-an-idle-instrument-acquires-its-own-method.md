# 0033. An idle instrument acquires its own method

Status: Accepted (2026-08-25)
Amends: [ADR-0032](0032-only-a-commanded-scan-earns-a-command.md) — specifically its clause
"a command is submitted only while the outstanding count is at or below zero". Everything else in
0032 stands: the predicate, its fail-open direction, the derived (not accumulated) count, and the
increment inside the success path. This ADR changes the **threshold**, not the accounting.
Related: [ADR-0031](0031-agc-prescans-are-interval-scheduled-only.md) — the prescan schedule is
untouched, but `agc_interval_seconds` is the other knob that spends duty cycle, so the two are read
together.

## Context

ADR-0032 shipped and was run on an Orbitrap Eclipse the same day
(`FLASHIda_methodLCMS_TEST_Wash.raw`, 2026-08-25, gitlink `8613c38`). It did what it set out to do:
depth held at 1 for the whole run, and MS1 injection times sat at 79-90 ms against a 246 ms ceiling
rather than railing.

It also cost more than half the instrument.

FLASHIda drove for 17.02 s (RT 11.2063 → 11.4901 min) before the operator stopped it. Measured from
consecutive mzML scan start times over that window:

| Kind | N | median duration | total | share |
|---|---:|---:|---:|---:|
| **instrument method's own `ITMS + c NSI Full ms [110-130]`** | 144 | 71.2 ms | 9 174 ms | **53.3 %** |
| FLASHIda MS2 (Orbitrap) | 16 | 224.8 ms | 3 598 ms | 20.9 % |
| FLASHIda MS1 survey (Orbitrap) | 17 | 196.9 ms | 3 393 ms | 19.7 % |
| FLASHIda AGC prescan (IonTrap) | 13 | 74.0 ms | 973 ms | 5.6 % |
| handshake | 1 | 82.3 ms | 82 ms | 0.5 % |

158 ion-trap scans against 33 Orbitrap ones. The lab's report was "es werden nur AGC Scans
ausgeführt", which is what that looks like on a scrolling display.

The pattern is regular and it is **sequential, not parallel**. Our MS2 at index 9429 occupies
11.483126 → 11.486944 (229 ms); three method scans then fill 11.486944 → 11.490055 (186 ms); our
next command starts. Exactly three, between every pair of ours, all run to completion. That 186 ms
is the host round trip — arrival event, snapshot, drain, `SetFusionCustomScan` — and the instrument
does not wait through it. **A Tribrid with an empty custom-scan queue acquires its method's scans.**

At depth 1 the queue is empty after every single scan, by construction. There is no gap the
instrument can be prevented from filling, because the gap *is* the design.

This is also the explanation for a number in ADR-0032 that looked like a curiosity at the time. Its
four reference runs recorded **8-12 uncommanded arrivals per ~20 000**; this run recorded **144 in
191**. Four orders of magnitude. The ratchet 0032 removed was, as a side effect, keeping the
instrument saturated: over-answering meant there was always another command queued, so the method
never got a slot. Removing the ratchet removed the saturation with it, and nothing replaced it.

The instrument method is not at fault and cannot fix this. A Thermo method must define some scan;
this one is a deliberately minimal 110-130 m/z, 32-peak, 25 ms placeholder. Making it *longer* makes
matters worse — a placeholder that has started cannot be pre-empted, so a 500 ms one would block a
186 ms gap for 500 ms. Making it shorter increases the count without reducing the lost time. The
lever is on our side.

## Decision

**The drain tops the instrument up to a target depth rather than to exactly one.**

`scheduling.target_depth`, default **2**: one command executing, one queued behind it.

- `1` reproduces ADR-0032 exactly and is the documented fallback.
- The drain is a **loop**, bounded by the target. A single submission per arrival can only
  oscillate the count between 0 and 1 — it can never *reach* 2 — so topping up is what
  bootstraps and holds the depth.
- The count stays **derived** from arrivals and is still incremented only inside the success path,
  so it cannot climb past the target. The loop carries a second, independent bound on attempts,
  because the increment lives in the success path and a throwing `BuildFromCommand` would otherwise
  spin it forever on the instrument event thread.
- The value is clamped to at least 1 at the point of use. A configured `0` would make the drain
  body unreachable, and that failure is absorbing: no send, no arrival, no next chance to send.

The key is **host-only**. `Config.cpp` accepts it and does nothing with it, because the queue it
describes belongs to the instrument and `Flash.cs:ProcessSpectrum` is the only thing that can size
it. It is listed in the C++ schema solely because the schema is strict on both sides (ADR-0007) and
`config_schema_reference.json` is generated from the C# model.

## Why

**Because the alternative to a bounded queue is not "no queue", it is the instrument's queue.**
Thermo's warning that depth > 1 is undefined (`dependencies/API-2.0.xml`, `IScans.SetCustomScan`)
was read in 0032 as an argument for depth 1. It is not — it is an argument against *unbounded*
depth. Depth 1 does not remove the second scan from the instrument's pipeline; it hands the choice
of that scan to the instrument method. We were not avoiding an undefined state, we were declining
to specify it.

**A knob rather than a constant, because 0032's evidence is real and this run does not refute it.**
The telemetry behind 0032 — injection railing, ion population varying 57-566×, prescan p95 injection
climbing to the 10 ms clamp — came from a ratchet reaching depth 11, not from a steady depth 2, and
nothing here establishes that 2 is safe. What this run does provide is a clean depth-1 baseline to
compare against. `scheduling.target_depth: 1` backs the change out on the instrument, in a method
file, with no rebuild — and on a system where each experiment costs a gradient and a sample, that is
the difference between one session and several.

**The threshold is the only thing that moves.** Every safety property 0032 argued for is a property
of the *accounting*, not of the number it is compared against: derived rather than accumulated so a
bad tick cannot become permanent; incremented after submission returns so a failed send self-heals
on the next arrival; a fail-open predicate so every misreading of the trailer degrades throughput
instead of ending the run. All four survive unchanged.

## Consequences

### The placeholder will not go to zero

Depth 2 removes the *gap*; it cannot abort a placeholder already in flight. Expect the share to fall
from 53 % to low single digits, not to nothing. A run that still shows tens of percent means the
round trip is longer than one placeholder period and the depth needs to be higher — or that
something else is wrong.

### This is the metric to watch, and it is not the one we changed

If depth 2 harms AGC the symptom is MS1 injection time railing at `ms_settings.ms1.max_it` instead
of sitting under it. This run's 79-90 ms against a 246 ms ceiling is the reference. Note that pwiz
attributes each FLASHIda scan's injection time to the *following* method scan, so read it offset by
one; the 16 values of exactly 118 ms on method scans in that file are the 16 MS2 scans railing at
their own `max_it`, not the method scan doing anything unusual.

### No golden moves

`Flash.cs` is not exercised by any golden path — the five log streams are written by the C++
`IdaLogger` and the continuity goldens are produced by `ContinuityTestHarness`, neither of which
submits a custom scan. `config_schema_reference.json` gains one key and is regenerated, not edited.

### It remains untestable

`Flash.Flash` needs a live Thermo `IFusionInstrumentAccess`, so no CI job can execute this loop. The
change ships verified by inspection and by the instrument run that follows it, and a seam introduced
to make it testable would be reverted (it has been before). The `target_depth` knob is the
concession: it makes the *instrument* the test harness, which is where the evidence has to come from
anyway.

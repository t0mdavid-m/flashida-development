# 0031. An AGC prescan is emitted on its schedule and nowhere else

Status: Accepted (2026-08-25), implemented.
Related: [ADR-0001](0001-direct-infusion-precursor-scope.md) — the direct-infusion assumption is what
makes a 1 s cadence a judgement call rather than a chromatography constraint.
[ADR-0011](0011-source-region-parameters-are-survey-scoped.md) — why the prescan copies the survey's
source region but not its analyzer settings.
[ADR-0025](0025-the-drain-acquires-no-analysis-lock.md) — the drain restructured here is the same one
that acquires no analysis lock; that property is preserved.

## Context

`FLASHIda::getNextScanCommand` had two callers of `ScanCommandQueue::makeAGC()`, and they meant
different things:

| Site | Trigger | Character |
|---|---|---|
| Step 1 | `scheduling.agc_interval_seconds` has elapsed | **scheduled** — a flux measurement taken on purpose |
| Step 5a | all four priority queues drained | **filler** — something cheap to hand an idle instrument |

The second one was doing nearly all the work, and it was self-concealing. Step 5a called
`recordAGCTime()`, so every idle drain **reset the timer Step 1 reads**. Step 1 could therefore only
fire in a run whose queue stayed non-empty for a whole interval. The authored
`agc_interval_seconds: 30` never governed the real cadence, which was instead "one prescan every time
the queue happens to empty" — roughly every other scan on the instrument.

The concealment extended to the test suite. All 41 committed configs sat at 30 s and no test run
lasts thirty seconds, so **every `scan_type=agc` row in every log golden came from Step 5a** — about
1,250 rows across 25 modes. Four C++ sections whose subject was the prescan could not distinguish
Step 1 from Step 5a, because Step 5a supplied one either way; two of them set
`agc_interval_seconds: 0` and never slept, and one used a 9999 s interval and got its prescan purely
from the filler path.

## Decision

**The engine emits an AGC prescan on exactly one trigger: the `agc_interval_seconds` timer.**

A drained queue emits an **idle survey** — an MS1 at priority 3 — and no prescan. Step 5 pushes that
survey and re-enters `dequeue()` to return it, rather than returning the local copy.

The startup handshake scan (`Flash.cs:BuildHandshakeScan`, `IsAGC: true`) is out of scope and
unchanged. It is a control signal that switches the instrument into custom control, not part of the
engine's scan schedule.

## Why

**Re-entering `dequeue()` rather than returning the survey directly** is what makes the idle survey
inherit the whole Step 4 tail: `recordMS1Time()`, its enqueue/dequeue timestamps, `pending_scan_map_`
registration, and the log row carrying `precursor_id`. A bypass would get none of those, and the
missing `recordMS1Time()` would silently stop resetting the cycle-time clock. It is also the correct
read under a concurrent `processScan`: work pushed between the two dequeues wins on priority and the
survey waits at 3.

**The idle survey rate roughly doubles** — one survey per empty drain instead of one per two — which
is the direct consequence of dropping the filler scan and is intended.

## Consequences

### The drain sentinel is now priority 3

Three drain loops used `IsAgc` as their only "the engine has nothing left" signal, two of them in
production code: `FLASHIdaWrapper.cs:434` and `:452` (the offline harness, which is the assembly
entry point CI's `regression-runner.ps1` executes) and `ContinuityTestHarness.PushScan`, an otherwise
unbounded `while (GetNextScanCommand == 1)`. Without a prescan on the idle path all three spin
forever.

They break on `MsnLevel == 1 && Priority == 3` instead. `makeMS1()` sets priority 3 and every other
caller overrides it to 0 (cycle-time, CV-transition); MS2 is 2, MS3 is 1. So an MS1 at priority 3 is
by construction "Step 5 fabricated this because nothing was queued".

This is a convention, not a type, so it is pinned on **both** CI paths:
`FLASHIda_ProcessScan_test::only_the_idle_survey_is_emitted_at_priority_3` (C++, engine-emitted
commands via `runInterleaved`) and `IdleSurveySentinelTests` (C#, across the P/Invoke boundary). A
guard that only exists on the side that changed is not a guard.

It also removes a latent truncation: a *scheduled* prescan arriving mid-drain used to stop the
offline loop and drop the MS2 commands behind it. At the new 1 s interval, with offline runs lasting
many seconds, that would have become routine.

`PushScanAndDrainFull` and its C++ mirror `runInterleaved` are deliberately **not** changed. Their
idle predicate keeps its `IsAgc` clause — still correct for scheduled prescans — and its third clause
(`level <= 1 && ms1Fed >= nMs1`) already catches the idle survey. The two halves stay byte-for-byte
mirrors.

### The interval is load-bearing for the first time, so it was chosen

Production default: **30 s → 1 s** (`Config.h`, `MethodConfig.cs`, `etc/method.json`). 1 s is close to
the cadence the filler was actually delivering, and costs about 1% duty cycle — a prescan is
IonTrap/Turbo at `max_it = 1 ms`, `microscans = 1`.

Under ADR-0001's direct-infusion assumption the ion flux itself is quasi-constant, so this is not a
chromatography argument. What argues for a short interval on *this* system is FAIMS CV cycling
changing the transmitted population, and acknowledged spray instability — both on a seconds scale —
against `PAGCGroupIndex = 1`, which puts every real acquisition in the group the prescan gain-corrects.

**This value is invisible to CI by construction.** No test run lasts long enough to fire either 30 s
or 1 s. It is a domain choice wanting an instrument check, not a verified one.

### Committed test configs pin the timer off

All 41 `test-data/configs/*.json` are set to `9999999`, matching what every C++ test config already
did. Without Step 5a resetting it the timer accumulates, so at 1 s a golden capture run — some modes
deconvolve 500+ commands from real cytC spectra — would emit prescans at wall-clock-dependent
positions, adding rows *and* renumbering every normalized `T<n>` differently on each run. The largest
golden surface in the repo would become timing-dependent.

JSON has no comments and the loader is strict, which is why this rationale lives here rather than
beside the key. Interval behaviour is covered instead by
`FLASHIda_ProcessScan_test::interval_agc_fires_once_per_interval`, which is timing-tolerant by
construction: it sleeps against a 50 ms interval with loose asymmetric bounds, so a loaded runner can
only push it further inside them.

### Goldens

85 files move: 68 log goldens (25 `scan_commands` — rows deleted *and* ids renumbered; 25
`scan_results`, 13 `identification`, 5 `pooled_identification` — renumbering only) and 17
`continuity_*.json`, whose `ScanDescription` carries the raw base-94 id. `ida.log` carries no ids and
does not move; the regression TSVs have no id columns and do not move.

**This could not be split into a byte-identical push and a golden-moving one.** Applying the priority-3
sentinel while Step 5a still existed makes `PushScan` record *both* the prescan and the survey before
breaking, so the goldens move on the first commit either way.

The diff was validated by *proving* it mechanical rather than reading it: transform each committed
golden the way the change should (drop `scan_type == agc` rows, re-sequence `T<n>` by order of first
appearance across that mode's five streams, since `LogGoldenComparer` builds one shared `idMap` per
case) and diff that against the fresh capture. Anything left over is a real behavioural delta and is
what gets reviewed.

Final classification of the 125 log-golden files: **96 clean · 24 differing only by trailing idle
surveys · 5 residue · 0 missing**. All 24 tail cases carry **exactly 2** extra surveys, uniformly —
the idle cycle now emits one survey per drain, so the harness reaches `idle >= 3` after a different
number of tail commands. The 5 residue files are both understood, and both are **pre-existing
fragilities this change exposed rather than caused**:

- **`exploration_hcd` — the deconvolution list ORDER is build-nondeterministic.** An adjacent pair
  in `deconv_masses` / `deconv_charges` / `deconv_intensities` swaps position with the entries
  otherwise intact. Proven by comparing two of *our own* CI runs whose only code delta was the
  tracking-id counter, which cannot reach FLASHDeconv: the same pair flips. `GoldenNumericComparer`
  tolerates value drift but **not ordering**, so whichever order is captured, a later build can flip
  it back. Expect intermittent failure here until the list gets a total order.
- **`separate_charges` has never captured a complete acquisition.** Its drive is bound by
  `PushScanAndDrainFull`'s `maxIters = 600`, and was before this change too. Its golden spent 32 of
  those iterations on AGC commands; removing them frees that budget for ~32 more real commands, so
  the file grew. Its content will keep shifting with anything that changes command density.

Two further consequences worth knowing, both found the hard way:

- **Tracking id 0 was a latent landmine, and the prescan was standing on it.** `buildMS2` writes a
  parent only `if (parent_scan_id > 0)` and `FLASHIda.cpp` passes a literal `0` for a root MS2, so 0
  is the "no parent" sentinel — while the allocator also issued it as a real id. The prescan was the
  first command minted on every fresh engine and absorbed 0, which is why this never showed. Removing
  it handed 0 to the first survey and stripped the parent from every MS2 of that survey. The
  allocator now starts at 1 and wraps to 1; see the counter's declaration in `ScanCommandQueue.h`.
- **An external oracle must not be keyed on a scan id.** `test-data/reference/ms3_leaf_expected.tsv`
  anchored the MS3 flip-localization ground truth on a raw tracking id; both anchors shifted by one
  and the check reported a localization regression when the proteoforms were byte-identical. It is
  now keyed on (precursor mass, fragment ion) — the ion alone is insufficient, because an adjacent
  isotopologue emits its own `b80`/`b70` leaves.

## Alternatives rejected

- **A config flag to keep the old behaviour reachable.** Adds a schema key on both sides plus an
  orthogonal config axis the goldens would only ever cover at its default — the shape that hid two
  real defects in the exploration × multiplexing intersection.
- **Return 0 from `getNextScanCommand` on an empty queue.** Tempting because it fixes the three
  hanging loops for free. It breaks the documented never-returns-0 bridge contract, and on the
  instrument `Flash.cs` would send no command and custom control would lapse.
- **Carve an `is_idle` field from `ScanCommand.Reserved`** (ADR-0012's worked example) as an explicit
  sentinel. New cross-language ABI surface, added for a drain-loop convenience, needing both layout
  tests updated in lockstep. `priority == 3` already carries the fact.
- **Normalize `agc` rows out of the goldens** and leave the test configs at the production interval.
  Restores determinism, but permanently blinds the largest golden surface to an entire scan type.

---
title: FAIMS CV Cycling
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FAIMS.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:810   # faims_.updateSkip call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:812   # faims_.advanceToNextCV call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:814   # next MS1 command carries new CV
see_also:
  - precursor-selection.md
---

# FAIMS CV Cycling

## Overview

FAIMS CV cycling drives systematic rotation through the configured compensation-voltage
list, one CV per MS1 scan. Since Phase 6 deleted `FAIMSScanProcessor.cs`, the entire
cycling loop lives in C++ — there is no complementary C# state machine to look for.
Each MS1 scan carries exactly one CV value; at the end of that MS1's processing block,
the engine decides which CV the *next* MS1 should carry and pushes that MS1 into the
queue before returning control to `getNextScanCommand`.

## State machine

The three steps occur sequentially inside the FAIMS-enabled branch at the end of
`processScan()` (guarded by `faims_.isEnabled()`):

1. **`faims_.updateSkip(current_cv, commands_pushed)` — `FLASHIda.cpp:810`**

   Feeds the number of precursor commands that the just-finished CV produced back into
   the FAIMS state. A CV that consistently produces few precursors will accumulate skip
   credit and be skipped on future rotation passes. This is where adaptive weighting
   happens — not in `advanceToNextCV`.

2. **`faims_.advanceToNextCV()` — `FLASHIda.cpp:812`**

   Moves the internal cursor forward by one position, wrapping at the end of the list.
   Returns the CV value that the *next* MS1 should use. This call is unconditional (once
   enabled) and purely forward — there is no back-step or random-access mechanism.

3. **`ms1.faims_cv = next_cv` — `FLASHIda.cpp:814`**

   A fresh `ScanCommand` of type MS1 is built via `queue_.makeMS1()` and the CV field is
   set. The command is pushed with `priority = 0` so it reaches the instrument before any
   pending MS2s. The description is set to `"<id>S"` to mark it as a CV-transition scan.

The sequence is: *report how the old CV did* → *select next CV* → *push MS1 with next CV*.
`FAIMS.cpp` owns the skip bookkeeping and the ring-advance logic; `FLASHIda.cpp` owns the
command construction.

## Child inheritance

MS2 `ScanCommand` objects are built from a selected precursor's parent MS1 record. The
parent's `faims_cv` field is copied into each child command so the instrument applies the
same CV to both the MS1 and all follow-up MS2 (or MS3) scans triggered from that MS1.
This ensures CV coherence across the full scan chain: every command in a group shares the
CV of the MS1 that spawned it.

If you see an MS2 with `faims_cv = 0` it means the parent MS1 was not acquired under an
active CV (FAIMS was off, or the parent pre-dates Phase 6).

## Interaction with selection

Precursor selection runs independently for each MS1. `filterAndRank` receives only the
peak groups deconvolved from the *current* MS1's spectrum; it has no visibility into peak
groups from other CVs. Consequently:

- Each CV gets its own top-N ranking. There is no cross-CV ranking or tie-breaking.
- A precursor that appears at multiple CVs will generate independent MS2 commands at each
  CV, each counted against that CV's own quota.
- The adaptive skip in `updateSkip` is the only mechanism that links CV performance across
  cycles. Selection itself is stateless with respect to CV history.

## Gotchas

- **Skip state, not ring position, determines CV frequency.** If a particular CV seems
  absent from a trace, check the FAIMS skip bookkeeping rather than the ring-advance
  logic. `advanceToNextCV` always moves forward; skipping happens at a higher level when
  `updateSkip` has accumulated enough credit for a given CV.

- **`faims_cv` is part of the `ScanCommand` blittable struct (total size 2048B,
  `static_assert` at `ScanCommand.h:107`).** Any serialization change to this field
  requires the full P/Invoke lockstep update. See [`../scan-pipeline/bridge-functions.md`](../scan-pipeline/bridge-functions.md)
  for the authoritative byte-layout contract and the "Adding a new field" ritual.

- **Post-Phase-6, there is no C# FAIMS state.** `FAIMSScanProcessor.cs` was deleted.
  Searching the C# codebase for CV state or cycling logic will yield nothing; all of it
  lives in `FAIMS.cpp` and `FLASHIda.cpp`.

- **The next MS1 is pushed *during* `processScan`, before `getNextScanCommand` is called.**
  This means the instrument always has a queued MS1 ready when the current MS2 batch
  finishes. If the queue appears empty between CV cycles, the cause is elsewhere (e.g.
  the MS1 push being skipped because `faims_.isEnabled()` returned false).

---
title: Engine Entry Points — processScan and getNextScanCommand
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-08-25
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:80     # processScan
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:675    # getNextScanCommand
see_also:
  - csharp-orchestration.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../scan-pipeline/scan-command.md
  - ../fragment-analysis/tag-follow-up.md
---

## Overview

Both entry points are called synchronously on the C# thread via P/Invoke
(through the `ProcessScan` / `GetNextScanCommand` bridge exports — see
[`../scan-pipeline/bridge-functions.md`](../scan-pipeline/bridge-functions.md)).
Neither loops internally. `processScan` is the analysis entry (spectrum in
→ follow-up commands enqueued). `getNextScanCommand` is the dequeue entry
(next command out, or idle-fallback).

They share state two ways:

- `analysis_mutex_` — held by `processScan` for its full duration.
  `getNextScanCommand` never touches it; queue methods self-lock, and
  exploration/FAIMS state is read via atomics.
- Atomics — `processScan` writes `exploration_active_` and
  `current_faims_cv_` with `memory_order_release`; `getNextScanCommand`
  reads them with `memory_order_acquire`.

The split exists so command fetch never blocks on analysis.

## `processScan` (FLASHIda.cpp:80, ~600 lines)

Called once per incoming instrument scan from the C# side.

### Preamble (`:84`–`:110`)

1. Acquire `analysis_mutex_`.
2. Decode 3-char tracking ID from `scan_description`. If `scan_description`
   is shorter than 3 chars, return 0.
3. **AGC short-circuit** (`:92`): if `scan_description[3] == 'A'`, the scan
   is a calibration-only AGC with no data — resolve pending and return 0.
4. Capture timestamps: enqueue + dequeue (from pending map) and receive
   (now).

### Branch by `ms_level`

**MS1 (`:165`–`:275`):**

1. If `config_.level(1).selection == SelectionMetric::None`, resolve and
   return 0.
2. `selection_.filterAndRank(...)` → top-N precursors (see
   [`../ms1-acquisition/precursor-selection.md`](../ms1-acquisition/precursor-selection.md)).
3. Two sub-paths:
   - **Exploration**: `exploration_.initiate(2, ...)` produces CE-sweep
     variants. Each gets the MS1's encoded tracking ID stamped as
     `parent_scan_id`. See
     [`../exploration/variants-and-sweeps.md`](../exploration/variants-and-sweeps.md).
   - **Normal**: for each selected precursor × each MS2 scan config,
     `queue_.buildMS2` → push. MS2 `faims_cv` carries parent MS1's CV.
4. Write IDA log entry + MS1 row to `results.tsv`; resolve the MS1 from the
   pending map.
5. **FAIMS CV cycling tail** (if `faims_.isCycling()` — NOT `isEnabled()`; a single-CV run would otherwise push a redundant priority-0 MS1 after every survey, ADR-0012 — `:247`): call
   `faims_.updateSkip(current_cv, commands_pushed)` → `advanceToNextCV` →
   construct the next MS1 at priority 0 with the new CV and push. See
   [`../ms1-acquisition/faims-cycling.md`](../ms1-acquisition/faims-cycling.md).
6. Update `exploration_active_` and `current_faims_cv_` atomics.

**MS2 (`:276`–`:483`):**

1. If `exploration_.isExplorationVariant(tracking_id)` → route to
   `exploration_.feedResult(...)` for scoring / winner selection (see
   [`../exploration/scoring-and-winner.md`](../exploration/scoring-and-winner.md)).
2. Otherwise:
   - Resolve pending → get MS2's precursor context (mono mass, charge).
   - `deconv_.deconvolveMSn(...)` with that context.
   - Tag-based targeting via `selection_.processMS2ForTagBasedTargeting`.
   - Optional quantification follow-up (`quant_.isDifferentiallyAbundant`
     → `queue_.buildFollowUp(..., 'F')`).
   - Optional conditional MS2 (if tags found and
     `conditional_ms2_enabled` → `queue_.buildFollowUp(..., 'C')`).
     Full mode write-up: [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md).
   - MS3 targeting: `exploration_.initiateNextLevel` (cached MS2 context is
     stashed for MS3 identification lookup).
   - Write MS2 identification row if a proteoform was matched.
3. Update `exploration_active_` atomic.

**MS3 (`:484`–`:672`):**

1. If `exploration_.isExplorationVariant(tracking_id)` → route to
   `exploration_.feedResult(...)`.
2. Otherwise:
   - Resolve pending → MS3's precursor context.
   - `deconv_.deconvolveMSn(...)`.
   - Look up cached MS2 context; run `MS3FragmentMatcher::calibrateAndScore`
     for identification; write identification row.
3. No commands pushed; return 0.

Return value: number of commands enqueued during the call.

## `getNextScanCommand` (FLASHIda.cpp:675, ~110 lines)

Called on every `ProcessSpectrum` invocation to pull the next command.
Holds no mutex — queue methods self-lock; exploration/FAIMS state is read
via atomics.

Five-step decision tree:

1. **Scheduled AGC prescan** (`:695`): if `queue_.needsAGC()` — i.e.
   `scheduling.agc_interval_seconds` has elapsed — build one via
   `queue_.makeAGC()`, stamp it with the current FAIMS CV + a fresh
   tracking ID + timestamps, encode the `scan_description` as `{id}A`,
   `registerPending`, return 1. **This is the only `makeAGC()` caller**
   (ADR-0031).
2. **Cycle-time MS1 injection** (`:722`): if `cycle_time_enabled` and
   `queue_.msSinceLastMS1()` exceeds `cycle_time_ms`, build an MS1 at
   priority 0, push it into the queue. **Does not return immediately** —
   falls through to Step 4 so the MS1 is dequeued via the normal path.
3. **Cleanup expired** (`:745`): `queue_.cleanupExpired()` discards stale
   pending entries.
4. **Dequeue by priority** (`:748`): `queue_.dequeue()` walks priority
   queues 0 → 3 (0 highest). If a command is available, stamp
   `recordMS1Time` for MS1 drains and return 1.
5. **Idle fallback** (`:753`): queue was empty — mint a priority-3 **idle
   survey** MS1, push it, and re-enter `dequeue()` to return it. No AGC
   prescan is emitted here (ADR-0031). The re-entry is what makes the survey
   inherit Step 4's `recordMS1Time()`, timestamps, pending registration and
   log row; it is also correct under a concurrent `processScan`, whose
   higher-priority push would win. The instrument never starves.

Return value: 1 if a command was produced, 0 otherwise. Because Step 5
always produces a command, `0` is effectively unreachable in normal operation.

## Gotchas

- **Mutex asymmetry is load-bearing.** `processScan` holds `analysis_mutex_`
  for its entire body; `getNextScanCommand` never acquires it. If a future
  refactor adds a shared lock, command fetch will block on analysis and the
  acquisition loop will stall.
- **Tracking ID parsing at the top of `processScan` is the only correlation
  mechanism.** `scan_description` is the sole carrier that links a
  returning spectrum to the command that produced it. If a scan arrives
  without a 3-char prefix, `processScan` returns 0 — the scan is silently
  dropped from the analysis side (see
  [`../scan-pipeline/scan-command.md`](../scan-pipeline/scan-command.md)).
- **AGC short-circuit is critical.** `scan_description[3] == 'A'` identifies
  AGC calibration scans, which have no analytical data. Deconvolving them
  produces noise; the short-circuit resolves pending and returns.
- **Cycle-time MS1 is pushed at priority 0.** It jumps ahead of pending MS2
  commands so survey coverage takes precedence after extended MSN activity.
- **Idle fallback always returns 1.** The C# defensive guard
  `if (wrapper.GetNextScanCommand(ref cmd) == 1)` is a belt-and-braces
  check against future changes.
- **Priority 3 is the drained-queue signal, and it is a contract** (ADR-0031).
  Step 5 is the only producer of a priority-3 command, so three C# drain
  loops break on `msn_level == 1 && priority == 3`. Emitting anything else at
  priority 3 truncates them silently. Do **not** use `is_agc` for this — the
  idle path emits no prescan, and a *scheduled* prescan arriving mid-drain
  would stop the loop early and drop the commands behind it.
- **Atomics are the lock-free cross-call channel.** `exploration_active_`
  and `current_faims_cv_` are the only state coupling between the two
  entry points that does not go through `analysis_mutex_` or
  queue-internal locks.

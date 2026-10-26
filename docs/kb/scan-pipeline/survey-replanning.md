---
title: Survey re-planning — staged selection, committed at dequeue (ADR-0060)
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PlanUnit.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
last_verified: 2026-10-26
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PlanUnit.h:28                  # MemoryStamp
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PlanUnit.h:71                  # PlanUnit
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PlanUnit.h:105                 # wouldBar (mirrors admitCandidate)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:207                                # runSurveyMS1_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:463                                # the one replacePlan call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:915                                # registerAdjustable (quant verdict)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:766               # dequeue_ (commit)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:948               # replacePlan
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:279               # reisolate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:1053            # rollbackAcquisitionMemory
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:1064            # applyStamps
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:1108            # rechooseCharges
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1256                   # dropGroup
see_also:
  - scan-command.md
  - offline-coupling.md
  - ../ms1-acquisition/precursor-selection.md
  - ../ms1-acquisition/faims-cycling.md
---

# Survey re-planning

A survey's MS2s are a **plan** while they wait in FLASHIda's queue. A newer survey at the same
FAIMS CV replaces whatever of that plan is still unsent, and only the drain's dequeue makes a
selection permanent. Decision record: `docs/adr/0060-…`; glossary: `CONTEXT.md` **Plan unit**,
**Staged / committed**, **Decision survey**.

## Lifecycle

```
survey N @ CV c  (analysis thread, holds analysis_mutex_)
  1  applyStamps(queue_.takeCommitted())          fold what the drain committed since survey N-1
  2  filterAndRank → journal(); rollbackAcquisitionMemory()   memory_ = committed state only
  3  one PlanUnit per nominal mass (ADR-0036 siblings share one), commands built exactly as before
  4  waitingAt(c): re-derive committed `separate` remainders; adjust waiting bought R's
  5  replacePlan(c, units, adjust, replace_remainder_of)   ── one queue_mutex_ hold
  6  outside the lock: closeGroup / dropGroup / forgetTracking_ for dropped + reconciled units;
     [REPLAN] cv= survey= kept= dropped= added= adjusted= ; ida.log entry (+ Superseded=)

drain (instrument event thread, no analysis_mutex_)
  dequeue_ ── commit the command's unit, move its stamps to inbox_   (inside the existing queue_mutex_ hold)
```

## What can change after a survey decides

| Waiting work | On a newer same-CV survey |
|---|---|
| unit with nothing sent | dropped and re-planned from scratch (species may vanish, reappear with other charges, or be replaced) |
| unit with anything sent (`single`, `multiplexed`, a sweep, a quant group) | kept exactly as decided |
| `separate` `R` remainder (non-quant) | re-derived: `min(max_charge_states, |admissible now|) − |sent|` charges by `charge_selection`, sent charges excluded; kept if none resolves |
| bought `R` (quant verdict) | moved among the charges its group's `Q`s **covered** that the newer survey resolves; a multiplexed `R` re-chooses its whole set and is kept below `min_charge_states`; kept if none resolves |
| follow-ups, MS3, every MS1 | never touched (not registered) |

Every update resets `enqueue_timestamp_ms`, so `scan_commands.tsv`'s dequeue − enqueue is the wait
since the window was last chosen.

## Logs

- `scan_commands.tsv` (36 columns): `decision_survey_id` and `isolation_purity` sit before the
  trailing `enqueue_ts`. A dropped command has no row because rows are written at dequeue.
- `ida.log`: `\tID=<tracking id>` on every `Mass=` line, plus a `Superseded=<id> …` line in the
  entry of a survey whose re-plan dropped commands. The `target_logs` loader skips superseded
  `Mass=` lines.
- `scan_results.tsv`'s MS1 `child_ids` is decision-time, so it still lists superseded ids.
- Authority for a bought `R`: its `scan_commands` row is what was **sent**; `scan_results`'
  `group_*` columns are what the verdict decided.

## Gotchas

- **Depth-1 drives never re-plan.** Both harnesses return every MS2 before the next survey, so
  in the goldens only the FAIMS-cycling mode re-plans (four commands superseded at the
  2026-10-25 recapture). Re-planning tests drive stale surveys directly (`FLASHIda_Replan_test`).
- **`takeDecisionInfo` erases.** Read `decision_survey_id` from the log after a drain, never from
  the queue.
- **A new push site is permanent by default**, and `push_site_inventory` fails until its table
  classifies the site.
- **`wouldBar` must track `admitCandidate`.** `PlanUnit_test` pins the two against each other; a
  change to the exclusion gate or the qscore bar changes both or fails the test.
- **The bought `R` keys on the nominal mass recorded at registration**, never on its current
  `mono_mass`, which `reisolate` rewrites.
- No re-planning has run on hardware.

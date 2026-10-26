# 0060. A survey re-plans the waiting work, and only the drain commits

Status: Accepted (2026-10-22) and IMPLEMENTED (2026-10-25): Push 1 plumbing (OpenMS `f643769934..3e5e58437b`,
CI run 39754982907), Push 2 switch-on (OpenMS `cad7934e97..e655c1f59e`, FlashIDA `f5db0a4`/`bab7745`, log goldens
`a6181ca`, parent `17b19db`; CI run 40167969668 green: C# 202/201/0/1, ctest 32/32). No re-planning has run on
hardware.
Spec: `docs/superpowers/specs/2026-10-22-survey-replanning-design.md`. Plan:
`docs/superpowers/plans/2026-10-22-survey-replanning.md`.
Supersedes: [ADR-0059](0059-one-ranking-chooses-a-species-charges-and-it-may-be-re-run-on-a-newer-survey.md)
decisions 4–8 (`reselect_charges`, its scope, "nothing is cancelled", "the parent stays the selecting survey", and
"what is remembered follows what was isolated"). Its decisions 1–3 (`charge_selection`, isolation purity, `purity`
refused under `multiplexed`) stand.
Amends: [ADR-0046](0046-a-commanded-scan-is-located-by-its-command-not-searched-for.md) — the join locates on
`decision_survey_id` when the column exists and walks the parent chain only without it.
[ADR-0056](0056-a-quantification-group-is-decided-by-one-test-on-its-aggregate-and-the-test-is-authored.md) — the
bought `R` is built from the group's purest window as before, but no longer stays there: a newer survey may move it
among the charges the group's `Q` scans covered.

## Context

A species was excluded the moment its MS2 was **queued**. `filterAndRank` wrote every acquisition memory —
`all_mass_rt_map_`, `mass_qscore_map_`, both `tqscore_exceeding_*` maps, ADR-0028's
`authored_acquired_rt_map_` — on admission, and the survey pushed its MS2s one at a time. Under
`scheduling.target_depth` > 1, or a FAIMS cycle, commands wait seconds in FLASHIda's queue (the 2026-10-13 iTMT runs:
median 4–6 s after their survey), and a newer survey of the same CV could not reconsider any of them. It could not
pick a better charge, drop a species that had faded, or take one that had appeared.

ADR-0059 decision 4 proposed `reselect_charges`, which patched a waiting command's charge in place. It was never
shipped. Designing it showed two problems. The patch had to fight the exclusion its own survey had already written,
and it raced the drain's dequeue for the same command.

## Decision

1. **One lifecycle, always on.** There is no flag. Exclusion at queue time is removed.
2. **Selection stages; the dequeue commits.** `filterAndRank` journals what it would have written as **stamps**
   (`PlanUnit.h`: `MemoryStamp`, `SpeciesStamps`, `SelectionJournal`). It then rolls acquisition memory back, so
   memory holds **committed** state only. `ScanCommandQueue::dequeue_` commits a unit under the `queue_mutex_` it
   already holds and moves the unit's stamps to an inbox. The analysis thread folds the inbox into memory
   (`takeCommitted` → `applyStamps`) at the start of the next survey. `memory_` stays single-threaded. The drain
   takes no new lock and no `analysis_mutex_` (ADR-0025). The lock order stays analysis → queue.
3. **A survey replaces its CV's waiting plan in one call.** `runSurveyMS1_` groups its selection into **plan units**
   (one per species, keyed by nominal mass, so ADR-0036 siblings share one unit). It hands the whole plan to
   `replacePlan(cv, units, adjust, replace_remainder_of)` under one lock hold. That call does four things:
   - It drops the CV's units that are still wholly unsent.
   - It keeps committed ones.
   - It refuses any new unit whose species committed after the survey read memory, decided by `wouldBar`, which
     mirrors `admitCandidate`'s exclusion gate and qscore bar (a drift guard pins the two together).
   - It applies the bought-`R` adjustments.

   Quant groups and sweep groups belonging to a dropped or refused unit are closed (`Quantification::closeGroup`)
   and dropped (`Exploration::dropGroup`) after the lock is released. Only a survey **at the same FAIMS CV**
   re-plans. Without FAIMS every survey re-plans everything.
4. **The commit unit, and the one rule behind it.** *A species commits when any of its commands is dequeued. A
   committed species is never dropped. Only two things in it stay adjustable: a non-quant `separate` `R`
   remainder, and a bought `R`.*

   | Unit | After its first dequeue |
   |---|---|
   | species under `single` / `multiplexed` (every roster `R`) | the rest goes out as decided |
   | exploration sweep group | runs to completion; an unsent group is dropped with its unit |
   | quantification group (`Q`s of one species) | **frozen**: every other `Q` goes out as decided |
   | `separate` `R` | each charge's stamps commit when **that** charge is dequeued; the species' remainder is re-derived on each newer survey: `min(max_charge_states, |admissible now|) − |sent|` charges by `charge_selection`, sent charges excluded, kept as decided if the newer survey resolves none |

   Every charge a multiplexed command isolates commits with it (anchor and stage-0 notches,
   `ScanCommandQueue::isolatedCharges`).
5. **The bought `R` is adjustable, never droppable.** It is registered with the charges its group's `Q` scans
   **covered** (each measured `Q`'s anchor and notches) and the species' nominal mass at registration. A newer survey
   at its CV re-runs `charge_selection` among covered charges that survey also resolves, and rewrites the window with
   `reisolate` (the anchor, the notches and the description's `@charge`). If no covered charge resolves, the `R` goes
   out as decided. A multiplexed `R` re-chooses its whole set, and is kept as decided if fewer than
   `min_charge_states` covered charges resolve. A re-confirmation on the same charge still counts as a decision. No
   other follow-up is adjusted: an exploration follow-up's energy was measured or modelled at its charge, and
   tag/conditional follow-ups ride an `R` that was already sent.
6. **Only a registered command can be dropped.** `replacePlan` touches only scan ids in its unit registry. Every other
   push site is permanent by default: follow-ups, MS3, the bought `R`, and the monitor, cycle-time, CV-transition and
   idle MS1s. A follow-up exists only once its parent returned, which needed a dequeue, which committed the parent.
   Pushing an unregistered command whose parent is still staged therefore prints `[REPLAN-INVARIANT]`.
   `push_site_inventory` pins the set of push sites in `FLASHIda.cpp`.
7. **Queue time restarts on every decision.** Replace, adjust and re-confirm reset `enqueue_timestamp_ms`, so
   `scan_commands.tsv`'s dequeue − enqueue is the wait since the window was last chosen, and `scan_timeout` ages
   from there.
8. **What the logs record.**
   - `scan_commands.tsv` gains `decision_survey_id` and `isolation_purity` before `enqueue_ts`, which stays last
     (36 columns). Rows are written at dequeue, so a dropped unit has no row.

     | Command | `parent_tracking_id` | `decision_survey_id` |
     |---|---|---|
     | re-planned or re-confirmed by survey N+1 | N+1 | N+1 |
     | committed unit's remaining members | original survey | original survey |
     | `separate` remainder re-derived on N+1 | N+1 | N+1 |
     | bought `R`, adjusted on N+1 | its `Q` | N+1 |
     | bought `R`, not adjusted | its `Q` | the `Q`'s survey |
     | follow-ups, MS3, MS1 family | unchanged | empty |

   - **Logging authority.** The `R`'s `scan_commands` row is what was **sent**: its charge, notches, decision survey
     and purity. `scan_results`' verdict columns (`group_id_charge`, …) remain the **verdict-time** record. If an
     adjust moved the `R`, the two disagree, and that disagreement is how the adjust is visible.
   - `ida.log` stays a decision-time record. Each `Mass=` line ends in `\tID=<tracking id>`. A survey whose re-plan
     dropped commands writes `Superseded=<id> <id> …` in its own entry. The `target_logs` loader reads every
     `Superseded=` id first and skips the `Mass=` lines that carry one, so a superseded decision is not counted as
     an observation in `in_depth`'s `1 − ∏(1 − qscore)`. A log with no `ID=` loads as before.
   - `scan_results.tsv`'s MS1 `child_ids` / `commands_pushed` remain decision-time. They still list a superseded id.
   - stdout prints `[REPLAN] cv= survey= kept= dropped= added= adjusted=` once per survey.
9. **`ScanCommandJoin` locates on `decision_survey_id`** when the column exists and names an MS1 row. Otherwise it
   walks `parent_tracking_id` up to the MS1 row, as ADR-0046 does. `FLASHDeconvAlgorithm.cpp` reads only
   `Located::parent_scan_number` and was not edited.
10. **`precursor_selection.reselect_charges` is retired before it shipped.** Both loaders throw a migration error
    naming this ADR, and the key left all four schema sites.

## Considered options

- **Patch waiting commands in place (ADR-0059 d.4–8).** Rejected for the two reasons in *Context*.
- **Lock the queue across the whole survey.** Rejected: the drain would wait out a deconvolution. Approach A (re-plan
  optimistically, reconcile at the swap) holds the queue lock only for the swap.
- **Let the drain write `memory_` directly.** Rejected: that needs `analysis_mutex_` on the drain, which ADR-0025
  forbids. The inbox keeps `memory_` single-threaded.
- **Keep the species but re-choose only charges.** Rejected: that is reselection again. A full re-plan costs the same
  and also drops faded species and adds new ones.
- **Treat a `separate` species' charges as independent units.** Rejected: its bars are mass-level, so the first sent
  charge would bar the species, and an "unsent units drop first" rule would drop the remainder with nothing to
  replace it. Hence the remainder rule in decision 4.

## Consequences

- **Goldens.** The harnesses drain at depth 1 and no committed config sets `cycle_time`. In the goldens, therefore, a
  survey meets waiting work of its own CV only under FAIMS cycling. The recapture (FlashIDA `a6181ca`, 165 files from
  CI run 40016569997 attempt 2) moved 32 modes mechanically: the two columns plus `ID=`, with float noise beside
  them. It moved the `faims` mode for real: four waiting MS2s were superseded by an empty same-CV re-survey
  (2063.61@4 at CV −10, 2277.25@4 at −50, 5315.13@9 at −40, 2256.18@4 at −30). Their rows left `scan_commands` and
  `scan_results`, and four `Superseded=` lines appeared.
- **Gaps in the sent tracking-id sequence are now normal.** Nothing joins on contiguity.
- **A bought `R`'s row carries the `Q`'s survey and an empty purity** unless it was adjusted. Its purity was never
  measured on a survey.
- Under fast surveys and a slow drain, a species ranked just below the cut can be re-planned away repeatedly. A fresh
  selection would do the same, but now it shows. `[REPLAN]`'s `dropped` count is the watch metric.
- The commands already on the instrument (up to `target_depth`) are never touched. One the instrument accepts and
  loses stays committed until `rt_window` expires, as before (the depth-stall defect stays separate).
- Coverage: `PlanUnit_test`, `ScanCommandQueue_Concurrent_test` (registry, reconcile, commit of every isolated
  charge, `reisolate` = `buildMS2` geometry), `FLASHIda_Replan_test` (re-plan semantics per unit type, CV scoping,
  bought `R`, two forced races: 200 ecoli rounds and 24 cytC `separate` rounds, the push-site inventory),
  `FLASHIda_Logging_test` (the join), `FLASHIda_LoggingFields_test` (columns, `ID=`, the loader), and C#
  `LogColumnReorderTests` (the comparer masks `ID=` / `Superseded=`).
  - **Open:** no test reads an engine-written `Superseded=` id back, and no test joins `ID=` to its
    `scan_commands` row.
  - **Open:** `decision_columns_on_every_survey_decided_ms2` says the columns are empty off the survey path. That is
    false for a bought `R`, and no quant drive exercises it.

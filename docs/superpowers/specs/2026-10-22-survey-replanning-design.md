# Survey re-planning: staged exclusion, committed at dequeue

Status: design approved in brainstorming 2026-10-22; spec awaiting owner review. Not implemented.
Supersedes: ADR-0059 decisions 4–8 (`reselect_charges`, its scope, "never cancel", "the parent stays the
selecting survey", the ticket design of its Push 2). ADR-0059 decisions 1–3 (`charge_selection`, purity,
the multiplexed refusal) stand and are already landed (Push 1).
Amends: ADR-0056 (the bought `R` is no longer fixed at the group's purest window), ADR-0046 (the join
locates on `decision_survey_id`, not the parent walk).

## TL;DR

Today a species is excluded the moment its MS2 is **queued**, so a newer survey cannot reconsider it,
and ADR-0059's planned charge patching has to fight both its own exclusion and the drain. Instead:

- Exclusion and all acquisition memory become **staged** when a survey decides and **committed** when
  the drain hands the command to the host — under the same `queue_mutex_` as the dequeue.
- Every new survey **re-plans** its CV's waiting work from scratch against committed memory only, and
  swaps the result in atomically. Whatever committed while the plan was being computed wins at the swap.
- Only commands a survey's plan **registered** can ever be dropped. Follow-ups are structurally invisible
  to the swap.

```
             survey N @ CV c                                 survey N+1 @ CV c
                  │                                                 │
   filterAndRank (committed memory only)            fold inbox → filterAndRank (committed only)
                  │                                                 │
   plan_N = {units + their memory stamps}                    plan_N+1
                  │                                                 │
   replacePlan(c, plan_N) ──► FLASHIda queue ◄── replacePlan(c, plan_N+1): drop unsent units of plan_N,
                                   │                                     keep frozen ones, reconcile
                       drain: dequeue()  ── commit unit, stamps → inbox  (one queue_mutex_ hold)
                                   │
                         host → instrument (≤ target_depth)   never touched again
```

## Decisions

### 1. One lifecycle, always on
There is no flag. Exclude-at-queue-time is removed; every survey re-plans. Goldens move in their own push.

### 2. A survey's selection replaces its CV's waiting work (full re-plan)
Species may be dropped, added, reordered; charges and windows re-chosen. The waiting set is therefore
never larger than one survey's selection per CV (today several surveys' MS2s can stack).

### 3. Only a survey at the same FAIMS CV re-plans
Staged plans are kept per CV. Without FAIMS, or at a single fixed CV, every survey re-plans everything.

### 4. The commit unit

| Unit | Commits when | After commit |
|---|---|---|
| species, `single` / `multiplexed` (all its roster commands: `R`, `additional_ms2` `R`s) | any member is dequeued | remaining members go out as decided |
| exploration sweep group (no special case) | any variant is dequeued | group runs as today; an **unsent** group is a plan unit and is dropped through `Exploration`'s existing group abort (`cancelByScanIds`) |
| quantification group (`Q`s of one species) | the first `Q` is dequeued | **frozen**: every other `Q` goes out exactly as decided |
| `(species, charge)`, `separate` `R` | that charge's command is dequeued | the species' **remainder** stays re-plannable (below) |

`separate` `R` remainder: on survey N+1 the species is re-ranked by `charge_selection`, charges already
sent are excluded, and the remainder is `min(max_charge_states, |admissible on N+1|) − |sent|` — re-derived,
not fixed at the original count.

### 5. The bought `R` is adjustable, never droppable
The verdict-bought `R` (ADR-0038/0039) is registered as *adjustable*. While it waits, each newer survey at
its CV re-chooses its charge and window by `charge_selection`. A replacement charge must be resolved on
**both** the `Q`'s survey and the newer one (ADR-0059 decision 6's rule, retained here); otherwise it goes
out as decided. No other follow-up is adjusted: exploration's production follow-up carries an energy
measured or modelled *at its charge*, and tag/conditional follow-ups ride an already-sent `R`.

### 6. Commit happens at dequeue (point A)
Inside `ScanCommandQueue::dequeue()`, under `queue_mutex_`: the unit is marked committed and its memory
stamps are appended to a **commit inbox**. A command the instrument accepts and loses stays excluded until
`rt_window` expires, as today (the depth-stall defect stays a separate issue).

### 7. All acquisition memory moves to commit
`all_mass_rt_map_`, `authored_acquired_rt_map_` (ADR-0028), `mass_qscore_map_`, both `tqscore_exceeding_*`
maps — everything `filterAndRank` writes on admission today — is instead recorded as the unit's
**stamps** and applied when the analysis thread folds the inbox. A replaced unit therefore spends nothing.
The RT stamped is the deciding survey's RT (what admission writes today).

### 8. Droppable only by registration
`replacePlan` removes only scan ids in its unit registry (`unit_of_[scan_id]`), filled by the survey that
built the plan. Every other push site — follow-ups, MS3, monitor / cycle-time / CV-transition / idle MS1s,
the bought `R` — is unregistered and invisible to it. A new push site defaults to permanent. Causal backstop:
a follow-up exists only after its parent's scan returned, which required a dequeue, which committed the
parent's unit; `push()` of an unregistered command whose `parent_scan_id` lies in a still-staged unit is an
invariant violation (logged `[REPLAN-INVARIANT]`, pinned by a test).

### 9. Queue time resets on every update
Replace, adjust and re-confirm all reset `enqueue_timestamp_ms`. `scan_commands.tsv`'s dequeue − enqueue is
then the wait since the window was last chosen — measurable on the device — and `cleanupExpired`'s
`scan_timeout` age restarts with it.

### 10. Logging

**`scan_commands.tsv`** (written at dequeue, so a dropped unit never has a row) gains two columns:

- `decision_survey_id` — tracking id of the MS1 whose ranking **last chose or re-prioritised** the
  command's isolation window.
- `isolation_purity` — measured on that survey (ADR-0059 decision 1's definition).

| Command | `parent_tracking_id` (lineage) | `decision_survey_id` (locate) |
|---|---|---|
| unit re-planned or re-confirmed by N+1 | N+1 | N+1 |
| frozen unit | original survey | original survey |
| `separate` `R` remainder re-planned on N+1 | N+1 | N+1 |
| bought `R`, adjusted on N+1 | its `Q` | N+1 |
| bought `R`, not adjusted | its `Q` | the `Q`'s survey |
| follow-ups, MS3, MS1-family | unchanged | empty |

**`ScanCommandJoin`** (`ScanCommandJoin.h`, `surveyScanNumber_`) locates on `decision_survey_id` when the
column is present and falls back to the parent walk for older files. `FLASHDeconvAlgorithm.cpp` consumes only
`Located::parent_scan_number` and is not edited.

**`ida.log`** stays a decision-time record. Each `Mass=` line gains a trailing `ID=<tracking id>`; a survey
whose re-plan dropped units writes a `Superseded=<id> <id> …` line in its own entry. The `target_logs`
loader (`PrecursorSelection` constructor) collects all `Superseded=` ids and skips `Mass=` lines carrying
one, so a superseded decision is not counted as an extra observation in `in_depth`'s
`1 − ∏(1 − qscore)`. Logs without `ID=` load unchanged. `NormalizeIdaLog` masks `ID=` like `Access ID`.

**`scan_results.tsv`** MS1 row `child_ids` / `commands_pushed` remain decision-time.

**stdout:** `[REPLAN] cv= survey= kept= dropped= added= adjusted=` per re-plan.

Dropped units leave gaps in the sent tracking-id sequence; nothing joins on contiguity.

### 11. `reselect_charges` is retired before it ships
No committed config sets it. The key gets a migration error naming this design; the skill's B13 rule and
the four schema sites drop it.

## Mechanism (approach A: optimistic re-plan, reconciled at the swap)

Analysis thread, in `runSurveyMS1_` (holds `analysis_mutex_`; lock order analysis → queue, queue is a leaf):

1. `queue_.takeCommitted()` → fold stamps into `PrecursorSelection::memory_` (single-threaded, as today).
2. Read the frozen set for this CV (committed units' species/charges, open quant groups).
3. `filterAndRank` against committed memory + frozen set; build the plan: units, their stamps, and
   adjustments for waiting bought `R`s.
4. Compute purity, scores, windows — all outside `queue_mutex_`.
5. `queue_.replacePlan(cv, plan)` under one `queue_mutex_` hold:
   - drop this CV's staged units that are still wholly unsent (and tell `Exploration` / `Quantification`
     to forget them — outside the lock, from the returned dropped list);
   - keep frozen units;
   - discard any new unit whose species committed since step 1 (the reconcile);
   - re-derive `separate` remainders against charges sent since step 1;
   - apply bought-`R` adjustments in place;
   - stamp `enqueue_timestamp_ms` on everything inserted, replaced, adjusted or re-confirmed.
6. Logging (`ida.log`, `[REPLAN]`) after the lock is released.

Drain thread (`getNextScanCommand`): unchanged except that `dequeue()` commits the unit and appends to the
inbox inside its existing lock hold. No `analysis_mutex_`, no new lock (ADR-0025 holds).

`ScanCommand` (2048 B ABI) is untouched — unit ids and stamps live in queue-side maps keyed by `scan_id`.

## Testing

New C++ exe(s), registered in `executables.cmake` **and** the yml `--target` list **and** the `ctest -R`
alternation, confirmed with `ci lists`:

- **Re-plan semantics:** drop / keep / add per unit type; CV scoping; frozen quant group; `separate`
  remainder re-derivation; bought `R` adjusted, and kept when the new charge is unresolved on either survey;
  unsent sweep dropped and its `Exploration` group forgotten; `enqueue_timestamp_ms` reset on each update.
- **The race:** a real concurrent drain thread commits between plan computation and swap, repeated N times:
  no species is both committed and newly queued; no tracking id is sent twice; **conservation** — every
  unregistered command pushed is dequeued exactly once or removed by an explicit `cancelByScanIds`.
- **Push-site inventory:** every `queue_.push` / `stampAndPush_` / `buildFollowUp` site in `FLASHIda.cpp`
  is classified (plan unit / adjustable / permanent); an unclassified site fails.
- **Causal invariant:** an unregistered push parented on a staged unit is flagged.
- **`ida.log` round trip:** `ID=` / `Superseded=` written, and the `target_logs` loader skips superseded
  masses; a log without `ID=` loads identically to today.
- **Join:** `ScanCommandJoin` prefers `decision_survey_id`, falls back to the walk without the column.

## Delivery

| Push | Content | Goldens |
|---|---|---|
| 1 | Plumbing: unit registry, commit inbox, memory stamps applied at commit, `replacePlan` present but called only from tests | none — all 33 modes byte-identical is the gate |
| 2 | Re-planning on; `decision_survey_id` + `isolation_purity`; `ID=` / `Superseded=` + loader; join repoint; bought-`R` adjust; queue-time reset; `reselect_charges` retired | every mode that moves; cell diff shown before any promotion |
| 3 | Docs: new ADR (supersedes 0059 d.4–8, amends 0046 / 0056), `CONTEXT.md`, the three CLAUDE.md files, KB `scan-pipeline`, `method.schema.json`, validate skill | — |

## Open risks

- Harness drives that never let a survey arrive while MS2s wait will show no re-plan at all; the semantics
  tests must use drives that do (the interleaved engine-id-echo harness, depth > 1).
- Under fast cycle-time surveys and slow drains, a species ranked just below the cut may be re-planned away
  repeatedly — the same as a fresh selection would do, but now visible. `[REPLAN]` counts are the watch metric.
- No re-planning has run on hardware.

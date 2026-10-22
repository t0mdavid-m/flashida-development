# Survey Re-planning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A survey's MS2 decisions stay provisional while they wait in FLASHIda's queue; each newer survey at the
same CV re-plans them, and only the drain's dequeue makes them permanent.

**Architecture:** `PrecursorSelection` stops writing acquisition memory in place and instead returns a journal of
**stamps** per species. `ScanCommandQueue` gains a **plan-unit registry**: a survey hands it a whole plan in one
call (`replacePlan`), which drops the CV's still-uncommitted units, keeps committed ones, and reconciles against
anything committed meanwhile. `dequeue_()` commits a unit and moves its stamps to an **inbox** that the analysis
thread folds into memory at the start of the next survey. `memory_` stays single-threaded and the drain takes no
new lock.

**Tech Stack:** C++20 (OpenMS, gcc 13 / MSVC 14.44), C# 7.3 (.NET 4.8) for the config and golden-comparer
side, ctest + NUnit, the two local containers, GitHub CI.

**Spec:** `docs/superpowers/specs/2026-10-22-survey-replanning-design.md`

## Context

Today a species is excluded the moment its MS2 is **queued**, so a newer survey can never reconsider it. ADR-0059's
planned `reselect_charges` (Push 2) would have patched waiting commands' charges while fighting its own exclusion and
racing the drain's dequeue. The brainstorm on 2026-10-22 replaced that with a **staged/committed exclusion**: decisions
stay provisional while they wait in FLASHIda's queue, every newer survey at the same CV re-plans them, and only the
drain's dequeue commits. The approved spec is `docs/superpowers/specs/2026-10-22-survey-replanning-design.md`
(parent commit 2128060). This plan is also saved at `docs/superpowers/plans/2026-10-22-survey-replanning.md`. It is
grounded in a four-way read-only audit of selection memory, the queue and its push sites, quant/exploration group
state, and the logs, join and harness.

---

## Working agreement (governs this plan)

- **Issues trigger a re-plan.** Any red test, surprising golden, or audit claim that doesn't hold → STOP, report,
  re-enter plan mode. No autonomous fix iteration.
- **Tests are frozen to the enumerated list below.** Adding, editing or deleting any other test needs sign-off.
- **Push 1 must land byte-identical and fully green** (all 33 log goldens, 13 regression TSVs, 17 continuity
  JSONs untouched). Any golden diff in Push 1 = a leak → STOP.
- **Push 2 goldens:** a golden-diff assessment of every moved cell, each delta explained by this plan, proven
  mechanical where claimed, then the owner reviews the logs by hand. Promotion is a bare host-side `cp` **after**
  sign-off. Never route around `golden-write-guard.sh`.
- **Root cause over workaround.** Fix the engine, never bend a test to agree.
- **Log value = decision value.** `decision_survey_id` / `isolation_purity` are what the engine decided on, never
  recomputed for the log.
- **FLASHDeconv / FLASHTnT are off-limits.** `FLASHDeconvAlgorithm.cpp` is not edited; the join change lives in
  `ScanCommandJoin.h`. The `ScanCommand` ABI (2048 B) and the 5 bridge exports are not touched — new per-command
  data lives in queue-side maps.
- **No `*ForTest` in production headers.** Test seams go in `FLASHIda_TestAccess.h`.
- **Verify in the containers first** (`ci cpp …` → `ci cpp --full` → `ci cs`), then push, then watch the run.
  `git pull --rebase` in all three repos before each push; a second Claude session may share this workspace.
- **Fine-grained commits**: one logical change per commit, docs separate. Submodule commit + parent gitlink bump.

---

## TL;DR

Today `filterAndRank` writes exclusion the instant a species is **admitted**, so the next survey can never reconsider
it, and a survey's MS2s go into the queue one push at a time.

```
TODAY                                              AFTER
survey N  ─ admit ─► memory_ (excluded NOW)        survey N  ─ admit ─► stamps (journal, memory_ rolled back)
          ─ push, push, push ─► queue                        ─ replacePlan(cv, plan) ─► queue   (one lock)
drain     ─ dequeue ─► instrument                  drain     ─ dequeue ─► commit unit ─► inbox ─► instrument
survey N+1  sees N's species as excluded           survey N+1 ─ fold inbox ─► memory_ ─ admit ─► replacePlan:
            (whether or not it was sent)                        drop N's uncommitted units, keep committed ones
```

Two pushes plus docs:

| Push | What | Goldens |
|---|---|---|
| 1 | Stamp journal (write-only; rollback exists but is not called, so behaviour is unchanged); queue plan registry, `replacePlan`, inbox, reconcile; `Exploration::dropGroup`. `replacePlan` is exercised only by tests. | none |
| 2 | Switch on: the survey routes through `replacePlan`; commit-at-dequeue; fold at survey start; remainder re-plan; bought-`R` adjust; two `scan_commands` columns; `ID=` / `Superseded=`; loader; join; retire `reselect_charges` | move — see Task 12 |
| 3 | New ADR, CONTEXT.md, three CLAUDE.md, KB, schema site | — |

---

## Two corrections to the spec, found by the audit

These refine the spec. Neither changes a decision you took; the second makes it precise.

1. **The harnesses drain at depth 1** (`FLASHIda_TestHelpers.h:315` `runInterleaved`, `ContinuityTestHarness.cs:191`).
   Every survey's MS2s are dequeued and returned before the next survey is fed, and **no committed config enables
   `cycle_time`**. So in the goldens a survey only meets waiting work of its own CV in the FAIMS-cycling modes. The
   semantic tests therefore drive stale surveys directly through `processScan` (Task 9), not through the harness.
2. **"The species is the unit" needs one more clause.** A `separate` species' charges each get their own selection entry
   and precursor id (`PrecursorSelection.cpp:854-901`, `FLASHIda.cpp:271`), but its exclusion stamps are
   **mass-level** (`all_mass_rt_map_`, `tqscore_exceeding_*`). Once one charge commits, the next survey bars the whole
   species — so if "drop unsent units" ran first, the remainder would be dropped and never replaced. The rule is
   therefore:

   > **A species commits when any of its commands is dequeued. A committed species is never dropped. Only two
   > things in it stay adjustable: a non-quant `separate` `R` remainder, and a bought `R`.**

   This one rule produces all three spec behaviours: a frozen quant group, an atomic sweep (including per-charge
   sweep groups under `separate`), and the `separate` remainder. Under `separate`, each charge's own authored stamp
   `(mass, z)` is applied when **that** charge's command is dequeued.

---

## Architecture

### New types: `include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PlanUnit.h` (header-only, new)

```cpp
namespace OpenMS
{
  /// One write PrecursorSelection used to make in place on admission (ADR-0028 / dynamic exclusion), now journaled.
  struct MemoryStamp
  {
    enum class Kind { AllMassRt, MassQscore, TqMassRt, TqMzRt, AuthoredAcquired, LegacyTargetChargeErase };
    Kind   kind;
    int    key = 0;        // nominal mass, or integer m/z for TqMzRt, or legacy target mass bin
    int    charge = 0;     // AuthoredAcquired / LegacyTargetChargeErase only; 0 = species-level
    double value = 0.0;    // rt (seconds) or score
    double legacy_mass = 0.0;  // LegacyTargetChargeErase: the exact target_mass_charge_map_ key
    int    seq = 0;        // write order within the survey; replay order (mass_qscore_map_ is an overwrite)
  };

  /// Everything one survey's selection wrote for one species (keyed by nominal mass; ADR-0036 siblings fold in).
  struct SpeciesStamps
  {
    int nominal_mass = 0;
    std::vector<MemoryStamp> species_level;          // applied on the species' FIRST commit
    std::map<int, std::vector<MemoryStamp>> per_charge; // charge -> stamps applied when THAT charge's command commits
  };

  /// What selection returns besides selectedPeakGroups(): per-species stamps + survey-level ones owned by no unit.
  struct SelectionJournal
  {
    std::map<int, SpeciesStamps> species;            // nominal -> stamps, admitted species only
    std::vector<MemoryStamp> survey_level;           // stamps of candidates that passed exclusion but were refused
  };

  enum class UnitRole { Plain, Quant, Sweep };       // Plain = R roster; Quant = has a Q group; Sweep = exploration groups

  /// One species of one survey's plan, at one CV.
  struct PlanUnit
  {
    int unit_id = 0;
    double faims_cv = 0.0;
    int nominal_mass = 0;
    int decision_survey_id = 0;      // tracking id of the MS1 that (last) chose it
    UnitRole role = UnitRole::Plain;
    bool separate = false;           // precursor_charges == separate (remainder may be re-planned)
    std::vector<ScanCommand> commands;   // the unit's MS2s / sweep variants, in push order
    std::vector<double> purity;          // index-parallel to commands: windowPurity on the decision survey
    std::vector<int> quant_group_ids;    // Quantification groups to close if dropped
    std::vector<int> sweep_group_ids;    // Exploration groups to drop if dropped
    SpeciesStamps stamps;
    // state, owned by the queue:
    bool committed = false;
    std::vector<int> sent_charges;
    int commands_left = 0;            // set on insert; a unit with none left is erased
  };

  /// Admission key the reconcile step tests a new unit against (mirrors CandidateAdmission's exclusion + qscore gates).
  struct UnitAdmissionKey
  {
    int nominal_mass = 0;
    int integer_mz = 0;      // anchor's rounded centre m/z
    int anchor_charge = 0;
    double score = 0.0;
    bool has_authored = false;
  };

  /// Would the committed stamps @p committed have refused @p key at admission?
  /// MUST mirror CandidateAdmission.h admitCandidate's exclusion gate (CA:474-486) and qscore bar (CA:529).
  /// Pinned against admitCandidate by a bidirectional drift-guard test (Task 3).
  bool wouldBar(const std::vector<MemoryStamp>& committed, const UnitAdmissionKey& key);
}
```

### Ownership and threads

```
FLASHIda (analysis thread, holds analysis_mutex_)
 ├── PrecursorSelection selection_   memory_ = COMMITTED memory only (after Push 2)
 │      filterAndRank(...) → selectedPeakGroups() + journal();  rollbackAcquisitionMemory() (Push 2)
 │      applyStamps(const std::vector<MemoryStamp>&)                (fold)
 ├── Exploration exploration_        + dropGroup(group_id)          (new)
 ├── Quantification quant_           closeGroup(group_id)           (exists)
 └── ScanCommandQueue queue_   ── queue_mutex_ (leaf) ──────────────────────────────┐
        units_ : unit_id -> PlanUnit                                                │
        unit_of_ : scan_id -> unit_id                                               │ drain thread
        adjustable_ : scan_id -> AdjustableR {resolved_charges on the Q survey}     │ (instrument event)
        inbox_ : vector<MemoryStamp>, committed_since_fold_ : vector<MemoryStamp>   │ dequeue_(): commit,
        decision_info_ : scan_id -> {decision_survey_id, isolation_purity}          │ stamps → inbox_
        replacePlan(cv, units, adjust) -> ReplanResult                              │
        takeCommitted() -> vector<MemoryStamp>                                      │
        takeDecisionInfo(scan_id) -> optional<DecisionInfo>  ◄────────────────────────┘
```

Lock order stays analysis → queue. `replacePlan` returns the dropped group ids, and the caller closes or drops them
**after** the queue lock is released.

---

## Global constraints

- `ScanCommand` stays 2048 B, with no new field (`ScanCommandLayout_test` / `ScanCommandLayoutTests` stay green).
- `getNextScanCommand` takes no `analysis_mutex_` (pinned: `drain_completes_while_analysis_mutex_held`).
- `getNextScanCommand` never returns 0 for an empty queue (pinned: `BridgePhase3Tests`, `IdleSurveySentinelTests`).
- Tracking id 0 is never issued (pinned: `tracking_id_zero_is_never_issued`).
- New C++ test exes are registered in `executables.cmake` **and** the yml `--target` list **and** the `ctest -R`
  alternation, then `ci lists` must show them.
- New `scan_commands.tsv` columns go **before** `enqueue_ts`, which stays last (`schema_column_counts`).
- Retention time: `processScan` works in seconds, logs carry minutes (ADR-0051). Stamps carry seconds.

## Review focus

1. **A `separate` species whose first charge is sent between plan computation and swap.** Expect: the new plan's unit
   for it is reconciled away, the old remainder is kept and then re-planned by the remainder pass. No charge is sent
   twice, and none is silently lost. → Task 7b.4 (`remainder_replacement_skips_a_charge_sent_after_waitingAt`) and Task 9, `race_separate_commit_between_plan_and_swap`.
2. **A queued command expired by `cleanupExpired` (`scan_timeout`)** while it belongs to a uncommitted unit. Expect: it
   leaves the registry; a unit that empties is discarded along with its stamps (never acquired, never excluded). → Task 4,
   `expired_member_leaves_registry`.
3. **Two PeakGroups of one species (ADR-0036 siblings) in one survey.** Expect: one unit, keyed by nominal mass, and
   one commit. → Task 2, `siblings_share_one_species_stamp_set`; Task 8, `siblings_form_one_unit`.
4. **FAIMS cycling: a survey at CV B arrives while CV A's MS2s wait.** Expect: CV A's units are untouched. → Task 9,
   `other_cv_survey_does_not_replan`.
5. **A bought `R` whose better charge was not resolved on the `Q`'s survey.** Expect: it goes out at its charge, re-confirmed
   on the newer survey if that survey resolves its current charge (otherwise `decision_survey_id` = the `Q`'s survey). → Task 10, `bought_r_keeps_charge_unresolved_on_q_survey`.

---

## File map

| File | Change |
|---|---|
| `inc/FLASHIda/PlanUnit.h` | **new**: types above + `wouldBar` |
| `inc/FLASHIda/PrecursorSelection.h`, `src/FLASHIda/PrecursorSelection.cpp` | journal stamps, snapshot/rollback, `journal()`, `applyStamps()`, `findSpecies()`, `rechooseCharges()`; loader reads `ID=`/`Superseded=` |
| `inc/FLASHIda/ScanCommandQueue.h`, `src/FLASHIda/ScanCommandQueue.cpp` | registry, `replacePlan`, commit in `dequeue_`, inbox, `takeCommitted`, `decision_info_`, `cleanupExpired` registry hygiene |
| `inc/FLASHIda/Exploration.h`, `src/FLASHIda/Exploration.cpp` | `dropGroup(int)` |
| `src/TOPDOWN/FLASHIda.cpp`, `inc/TOPDOWN/FLASHIda.h` | `runSurveyMS1_` builds the plan + calls `replacePlan`; fold at survey start; the bought `R` registered adjustable; drain writes the two columns; `forgetTracking_` |
| `inc/FLASHIda/IdaLogger.h`, `src/FLASHIda/IdaLogger.cpp` | 2 columns, `ID=`, `Superseded=` |
| `inc/FLASHIda/ScanCommandJoin.h` | optional `decision_survey_id`; `surveyScanNumber_` prefers it |
| `inc/FLASHIda/Config.h`, `src/FLASHIda/Config.cpp` | retire `reselect_charges` (migration error) |
| `FlashIDA/src/Flash/MethodConfig.cs`, `MethodParameters.cs`, `IDA/MethodConfigSerializer.cs`, `docs/site/method.schema.json`, `test-data/config_schema_reference.json` | retire the key at all four sites + the reference |
| `FlashIDA/src/Flash.Tests/LogGoldenComparer.cs` | relabel `decision_survey_id`; mask `ID=` / `Superseded=` ids |
| `.claude/skills/validate-flashida-config/{validate.py,SKILL.md}` | drop B13, add the retired-key error |
| tests | see each task |

`inc/` = `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN`, `src/` = `OpenMS/src/openms/source/ANALYSIS/TOPDOWN`,
tests = `OpenMS/src/tests/class_tests/openms/source/`.

---

# PUSH 1 — DONE 2026-10-22 (CI run 39754982907 green on attempt 3; C# 201/200/0/1, ctest 31/31)

OpenMS `f643769934..3e5e58437b`, parent `3bbb6ce` + gitlink `62b6636`. Tasks 1–5 each implemented TDD and passed an
adversarial review; the container Windows leg could not run (engine down) so CI was the Windows gate. Attempts 1–2 failed
only `Golden_Inclusion_MS3_CytC` with the known 246↔247 first-survey deconvolution flip (12320.19 / 12320.20); no
other cell moved. **What Push 1 landed, as the code actually is** (Push 2 builds on this, not on the old task text):

| Symbol | Where | Note for Push 2 |
|---|---|---|
| `PlanUnit.h` types, `wouldBar` | `inc/FLASHIda/PlanUnit.h` | last `MassQscore` **by vector position**: `committed_since_fold_` stays in commit order |
| `journal()`, `rollbackAcquisitionMemory()`, `applyStamps()`, `flatten()` | `PrecursorSelection.h:183-199` | snapshot `acq_entry_` taken at C:388-395 on the MS1 path only; `journal_` reset at C:186 **before** the `ms_level != 1` return |
| `replacePlan(cv, units, adjust, replace_remainder_of)` | `ScanCommandQueue.h:217` | returns only `reconciled_unit_ids` for reconciled units; mints ids into the moved vector; does not carry `sent_charges` |
| `AdjustRequest`, `DecisionInfo`, `ReplanResult` | namespace scope, `ScanCommandQueue.h:61-86` | not nested in the class |
| `ScanCommandQueue::Waiting`, `waitingAt`, `takeCommitted`, `takeDecisionInfo`, `registerAdjustable` | `ScanCommandQueue.h` | `Waiting::adjustable` = (cmd, resolved charges) |
| commit block | `dequeue_`, `ScanCommandQueue.cpp:720-751` | reads **only** `stages[0].charge_state` — fixed in Task 7b |
| `forgetQueued_` | `ScanCommandQueue.cpp:758` | called by `cleanupExpired` only — `cancelByScanIds` fixed in Task 7b |
| `Exploration::dropGroup`, `lastGroupId` | `Exploration.cpp:1256-1271` | `initiate` can return empty at :143 **before** minting, so `lastGroupId` then names the previous group |

---

# PUSH 2 — switch on

Order: 7b → 7 → 8 → 10 → 9 → 11 → 12. Same workflow shape as Push 1 (implementer → adversarial reviewer per task, stop
on any issue). The Windows container is unavailable, so Task 12's Windows leg is CI: push the code with goldens **unchanged**,
let CI's `log-golden-capture` artifact be the capture, assess every moved cell against Task 12's table, and promote only
after owner sign-off, in a second push. Expected: that first CI run is red in log goldens only.

### Task 7b: Push 1 review fixes (before anything calls the registry)

Five findings from the Push 1 reviews. All are unreachable today (no production caller), so this task is byte-identical
and lands as the first commits of Push 2.

**1. A multiplexed command commits every charge it isolates.** `dequeue_` reads only the anchor, so under
`multiplexed` + an authored charge set the notch charges' `AuthoredAcquired` stamps (ADR-0028, journaled at
C:752-756) are erased with the unit and never committed — after switch-on those charges would be re-selectable.

```cpp
// ScanCommandQueue.cpp, a private static helper next to forgetQueued_
static std::vector<int> isolatedCharges_(const ScanCommand& cmd)   // anchor first, then stage-0 notches
{
  std::vector<int> zs;
  if (cmd.num_stages <= 0) return zs;
  zs.push_back(std::abs(cmd.stages[0].charge_state));
  auto [n, cnt] = notchesForStage(cmd, 0);                          // ScanCommand.h:230
  for (int j = 0; j < cnt; ++j) zs.push_back(std::abs(n[j].charge_state));
  return zs;
}
// dequeue_ commit block: replace the single z with
for (int z : isolatedCharges_(cmd))
{
  auto pc = unit.stamps.per_charge.find(z);
  if (pc != unit.stamps.per_charge.end()) { /* move to inbox_ + committed_since_fold_ as today */ unit.stamps.per_charge.erase(pc); }
  unit.sent_charges.push_back(z);
}
```

**2. `cancelByScanIds` cleans the registry.** It calls `forgetQueued_(id)` for each id it removes, exactly as
`cleanupExpired` does (no unit leak, no false `[REPLAN-INVARIANT]`).

**3. `ReplanResult` reports reconciled units in full,** so Task 8 never has to keep a shadow copy keyed on ids it cannot
see. Three fields added: `reconciled_scan_ids`, `reconciled_quant_groups`, `reconciled_sweep_groups`. An empty unit
(no commands) is skipped **before** an id is minted.

**4. A remainder replacement is reconciled at the swap** (Review focus 1). For a new `committed` unit whose nominal mass
matches a unit named in `replace_remainder_of`: it inherits that unit's `sent_charges` **at swap time**, and any of its
commands whose charge is already in them is not inserted. If the named unit no longer exists (it emptied between
`waitingAt` and the swap), the new remainder is refused and reported in `reconciled_*`. So no charge is sent twice and
`count` is never exceeded.

**5. Rollback is guarded.** `acq_entry_valid_` is set where the snapshot is taken and cleared where `journal_` is
reset; `rollbackAcquisitionMemory()` is a no-op when it is false. A rollback after a non-MS1 `filterAndRank` can then
never restore an older survey's state.

**Tests** (new sections, `ScanCommandQueue_Concurrent_test.cpp`):
```
START_SECTION(multiplexed_command_commits_every_notch_charge)
  U(A: one cmd z13 with notches z14,z16; per_charge stamps for 13,14,16); dequeue
  TEST_EQUAL(takeCommitted() == species_level + per_charge[13] + [14] + [16])     // today: only [13]
END_SECTION
START_SECTION(cancelled_member_leaves_registry)
  insert U1(A, 2 cmds); cancelByScanIds({first}); dequeue second → planUnitCount == 0; push(child of first) prints no [REPLAN-INVARIANT]
END_SECTION
START_SECTION(reconciled_unit_is_reported_in_full)
  as reconcile_refuses_a_unit_committed_since_the_fold, U2 with quant_group 5, sweep_group 7
  TEST_EQUAL(r.reconciled_scan_ids == ids(U2)); reconciled_quant_groups == {5}; reconciled_sweep_groups == {7}
END_SECTION
START_SECTION(remainder_replacement_skips_a_charge_sent_after_waitingAt)
  committed separate U1(A: z14, z16 queued; z13 sent); w = waitingAt(cv); dequeue z14
  replacePlan(cv, {R(A: z14, z17, committed)}, {}, {U1}) → only z17 queued; dequeue order never repeats 14
END_SECTION
START_SECTION(remainder_replacement_refused_when_old_unit_emptied)
  as above but dequeue z14 and z16 before the swap → R refused, r.reconciled_unit_ids == {R}
END_SECTION
```
`FLASHIda_ChargeModes_test`: one new section `rollback_after_a_non_ms1_call_is_a_noop`.

- [ ] Fail → implement → `ci cpp ScanCommandQueue_Concurrent_test FLASHIda_ChargeModes_test` PASS (Concurrent ×20) →
  `ci cpp --full` → commit `fix(FLASHIda): commit every isolated charge; registry hygiene on cancel; full reconcile report`.


### Task 7: Retire `reselect_charges`

**Files:**
- `inc/FLASHIda/Config.h:327-329` delete the field; `src/FLASHIda/Config.cpp:433` drop it from the allowed set,
  `:441` delete the read, `:1650-1652` delete the warning; add a migration throw next to the other retired-key errors:
  `"precursor_selection.reselect_charges is retired: every survey now re-plans the waiting work of its CV (ADR-0060). Delete the key."`
- C#: `MethodConfig.cs:122-124` and `:803` delete; `MethodParameters.cs:151` and `:599` delete; `MethodConfigSerializer.cs`
  gets the retired-key hint with the same message; `docs/site/method.schema.json` deletes the `reselect_charges` entry.
- Regenerate `FlashIDA/test-data/config_schema_reference.json` (`REGEN_CONFIG_REFERENCE=1` in the Windows container, or
  CI artifact `config-schema-reference-capture`).
- Skill: `validate.py:356-366` drops B13 and adds an A-error for the key; `SKILL.md:107` updated.
- Tests (**changed, needs your sign-off**): `Config_SchemaProjection_test.cpp:454-458` `reselect_charges_parses` →
  replaced by `reselect_charges_is_a_migration_error` (`TEST_EXCEPTION` on true and on false, message names the ADR);
  `ConfigSchemaParity_test.cpp:317` the line deleted.

The ADR number is assigned in Push 3. Use `ADR-0060` here, and Task 13 creates `docs/adr/0060-…`.

- [ ] Fail → implement → `ci cpp Config_SchemaProjection_test ConfigSchemaParity_test` PASS → commit (OpenMS and FlashIDA
  separately) `refactor(config): retire reselect_charges before it ships`.

### Task 8: The survey builds a plan and calls `replacePlan`

**Files:** `src/TOPDOWN/FLASHIda.cpp` `runSurveyMS1_` (:205-352), `inc/TOPDOWN/FLASHIda.h` (helpers);
`src/FLASHIda/PrecursorSelection.cpp` (`unitKey` helper).

**Interfaces:**
- Consumes: Task 2 `journal()` / `applyStamps`; Task 4 `replacePlan` / `takeCommitted` / `waitingAt`; Task 5 `dropGroup`;
  `FragmentAnalysis::windowPurity` (`FragmentAnalysis.cpp:1379`).
- Produces: `void FLASHIda::forgetTracking_(const std::vector<int>& ids)` (erases from `precursor_id_by_tracking_`
  under `precursor_map_mutex_`).

New `runSurveyMS1_` order:

```
0. fold:     selection_.applyStamps(queue_.takeCommitted());                   // committed since the last survey
             selection_.applyStamps(previous survey's survey_level stamps)     // kept from the last call (member)
1. n = selection_.filterAndRank(...); selection_.rollbackAcquisitionMemory()      // journal kept, memory = committed
     // the ONLY rollback call; it follows an MS1 filterAndRank by construction (and is guarded, Task 7b.5)
2. build units: group entries i by nominal mass (SpectralDeconvolution::getNominalMass(selected[i].getMonoMass()))
     for each species: PlanUnit{cv=faims_cv, nominal, decision_survey_id=parent_tracking_id,
                                role = quant ? Quant : (exploration ? Sweep : Plain),
                                separate = (precursor_charges == Separate && !quant),
                                stamps = journal.species[nominal]}
     commands built EXACTLY as today (buildMS2 / exploration_.initiate), window_snr as today,
     purity[k] = FragmentAnalysis::windowPurity(raw_ms1, mz ± half, cmd.precursor_intensity)
     precursor ids allocated as today; setPrecursorForTracking_ for every command BEFORE replacePlan (happens-before
     edge preserved: replacePlan releases queue_mutex_, dequeue acquires it)
     quant: addMember as today (it needs scan_id and window_snr, both final); record group id in unit.quant_group_ids
     sweep: after each initiate, IF it returned a non-empty command list, unit.sweep_group_ids.push_back(lastGroupId())
            (an empty return exits before the id is minted, Exploration.cpp:143, so lastGroupId would name the previous group)
3. remainder + adjust (Task 10) → std::vector<AdjustRequest> adjust, plus remainder units appended to `units`
4. r = queue_.replacePlan(faims_cv, std::move(units), adjust, replace_remainder_of)
5. outside the queue lock:
     for g in r.dropped_quant_groups: quant_.closeGroup(g)
     for g in r.dropped_sweep_groups: exploration_.dropGroup(g)
     for g in r.reconciled_quant_groups: quant_.closeGroup(g)      // Task 7b.3 fields
     for g in r.reconciled_sweep_groups: exploration_.dropGroup(g)
     forgetTracking_(r.dropped_scan_ids) ; forgetTracking_(r.reconciled_scan_ids)
     publishExplorationState_()
     std::cout << "[REPLAN] cv=" << faims_cv << " survey=" << enc(parent_tracking_id) << " kept=" << r.kept
               << " dropped=" << r.dropped_scan_ids.size() << " added=" << r.added << " adjusted=" << r.adjusted << std::endl;
6. ida.log entry: ms2_commands = the commands actually inserted (not reconciled ones), Superseded = r.dropped_scan_ids
7. survey_level stamps of THIS survey held in a member, folded at step 0 of the next survey
```

`// ISSUE: survey_level stamps (refused candidates' AllMassRt) were visible immediately; holding them to the next
survey's fold is identical, because no read happens between this survey's end and the next survey's fold.`

The quant `addMember` and exploration `initiate` side effects happen before `replacePlan`. A reconciled unit
therefore has to undo them, which is why step 5 treats reconciled units like dropped ones.

The FAIMS CV-transition MS1 push (:329-345) stays exactly as it is, after `replacePlan`.

- [ ] **Step 1: Failing tests** (new exe `FLASHIda_Replan_test.cpp`, registered in all three lists — Task 9 holds the
  full list; this task adds the first sections):
```
START_SECTION(siblings_form_one_unit)
  method_inclusion_charge_set + ms1_cytc: survey N → [REPLAN] added == number of distinct nominal masses selected
END_SECTION
START_SECTION(depth1_drive_is_unchanged_without_a_stale_survey)
  runFullCycle(method_default, ms1_standard) → scan_commands rows identical (all columns except the 2 new) to a capture
  taken at the Push 1 tip (no rollback) — re-planning never fires at depth 1 without a waiting same-CV unit
END_SECTION
```
- [ ] Steps 2–4: fail → implement → `ci cpp FLASHIda_Replan_test` + `ci cpp --full` PASS.
- [ ] **Step 5:** Commit `feat(FLASHIda): a survey re-plans its CV's waiting work`.

### Task 9: Re-plan semantics and the race (`FLASHIda_Replan_test.cpp`)

**Files:** test `FLASHIda_Replan_test.cpp` (registered in `executables.cmake`, the yml `--target` and `-R` lists — `|FLASHIda_Replan`); helper
`driveStaleSurvey(ida, ms1_a, ms1_b)` in `FLASHIda_TestHelpers.h`: feed survey A, dequeue **k** commands without feeding
their responses, feed survey B, then drain.

Each test, in the linear form:

**`newer_survey_replaces_unsent_species`**
- *Purpose:* re-planning replaces an uncommitted plan.
- *In practice:* method_default_topn5 + ms1_ecoli_rich; A selects S1..S5; dequeue 0; B (same spectrum, rt +2 s).
- *Pseudocode:* `TEST_EQUAL([REPLAN].dropped, 5)`; after the drain, every dequeued MS2's `parent_tracking_id` and
  `decision_survey_id` are B; no `scan_commands` row exists for any of A's MS2 ids.

**`sent_species_is_never_dropped_and_not_reselected`**
- dequeue 1 after A (S1 sent); B. `TEST`: S1 is never re-sent (no second row for nominal(S1) within rt_window), S2..S5
  were dropped and re-added under B.

**`quant_group_frozen_after_first_q`**
- method_quant_separate; A → species X has Q z13, Q z14; dequeue Q z13 only; B.
- `TEST`: Q z14 is dequeued with parent A and `decision_survey_id` A; `quant_.openGroupCount()` sees X's group still
  open; no new group for X under B.

**`separate_r_remainder_is_rederived`**
- method_cytc_separate_charges, max_charge_states 3; A → X: z13, z14, z16; dequeue z13; B resolves z13..z17.
- `TEST`: the remaining rows are X at charges = B's top `min(3, |admissible on B|) − 1` excluding 13; parent and
  `decision_survey_id` are B; `enqueue_ts` > B's processing time.

**`separate_r_remainder_kept_when_unresolved`**
- as above, but B is a spectrum without X (`ms1_standard`). `TEST`: z14 and z16 go out with parent A.

**`unsent_sweep_dropped_and_group_forgotten`**
- method_exploration; A → sweep group G for X; dequeue 0; B. `TEST`: `explorationActive` reflects only B's groups;
  `[EXPL-DROP] group=G`; no variant of G is dequeued.

**`started_sweep_runs_to_completion`**
- dequeue 1 variant of G; B. `TEST`: every variant of G is dequeued, G completes, and B adds no sweep for X.

**`other_cv_survey_does_not_replan`**
- method_faims_3cv; A @ −40 selects; B @ −60. `TEST`: A's units are all dequeued with parent A.

**`race_commit_between_plan_and_swap`**
- Repeat 200×: drain thread dequeues in a loop while the analysis thread runs `processScan(B)`. Use a test seam
  `FLASHIdaTestAccess::onBeforeReplan(ida, fn)` that runs `fn` between step 3 and step 4 (implemented as a
  `std::function` member in **FLASHIda_TestAccess.h's friend access**, not as a production hook: the production
  `runSurveyMS1_` calls a private `beforeReplan_` that is an empty inline unless the test access sets it).
  Owner ruling 2026-10-22: the private hook.
- `TEST`: no nominal mass is dequeued twice within rt_window; every unregistered command is dequeued exactly once;
  `[REPLAN-INVARIANT]` never printed.

**`race_separate_commit_between_plan_and_swap`** — the same, with `separate` and the seam dequeuing X's first charge.

**`follow_up_parent_is_never_staged`** — run method_tag_targeting through `driveStaleSurvey`; `TEST`: no
`[REPLAN-INVARIANT]`, and every `C` follow-up row's parent has its own `scan_commands` row.

**`push_site_inventory`** — reads `FLASHIda.cpp` at test time (`OPENMS_SOURCE_DIR`) and lists every `stampAndPush_(`,
`queue_.push(`, `queue_.pushAndDequeue(`, `queue_.replacePlan(` and `queue_.registerAdjustable(` call. It compares the
set of call lines (by enclosing function name plus call text, not by line number) against an expected table:
`replacePlan` once (`runSurveyMS1_`), `registerAdjustable` once (quant verdict), `stampAndPush_` at 6 permanent sites
(refine, exploration MS2 return, bought R, tag follow-up, MS3 targeting, exploration MS3 return), and `queue_.push` at 3
MS1-family sites. A new or moved site fails until the table is updated.

- [ ] Steps: write all → fail → (implementation is Tasks 8 and 10) → PASS; `ctest -R FLASHIda_Replan --repeat until-fail:10`.
- [ ] Commit `test(FLASHIda): re-plan semantics, races, push-site inventory`.

### Task 10: Remainder re-plan and bought-`R` adjust

**Files:** `src/FLASHIda/PrecursorSelection.cpp` / `.h` (two new pure-ish functions); `src/TOPDOWN/FLASHIda.cpp`
(the quant verdict at :714-730 registers the R; `runSurveyMS1_` step 3).

**Interfaces:**

```cpp
/// The PeakGroups of this survey's deconvolution whose nominal mass is within ±1 of @p nominal (ADR-0059 d.6, ADR-0036).
std::vector<const PeakGroup*> PrecursorSelection::findSpecies(int nominal) const;

/// Re-rank the SNR-admissible charges of those PeakGroups by config charge_selection (Push 1 of ADR-0059's
/// rankCharges / chargeRankKey, NotchSelection.h:49-63). Each charge is measured from the PeakGroup that resolved it.
/// Excludes @p exclude, keeps only charges in @p allowed when non-empty, returns at most @p count.
std::vector<std::pair<int, const PeakGroup*>> PrecursorSelection::rechooseCharges(
    int nominal, const std::vector<int>& exclude, const std::vector<int>& allowed, int count) const;
```

Step 3 of `runSurveyMS1_`:

```
w = queue_.waitingAt(faims_cv)
for unit in w.committed_units with unit.separate && unit.role == Plain && unit has queued commands:
    count = min(max_charge_states (0 → all), |admissible on this survey|) − |unit.sent_charges|
    picks = selection_.rechooseCharges(unit.nominal, unit.sent_charges, {}, count)
    if picks.empty(): continue                                   // keep as decided (spec d.5 / ADR-0059 d.6)
    new PlanUnit{same nominal, decision_survey_id = this survey, separate, committed = true (species already committed),
                 sent_charges = unit.sent_charges, stamps.per_charge = authored per-charge stamps for picked charges}
    commands = buildMS2(pg, z, roster…, parent_tracking_id = this survey)  // a remainder is a new decision: parent = this survey
    the old remainder's queued commands → into the drop set: replacePlan drops them via `remainder_of` (its 4th argument)
for (r, resolved_on_q) in w.adjustable:
    picks = selection_.rechooseCharges(nominal(r), {}, resolved_on_q, 1)  // must be resolved on BOTH surveys
    if picks.empty(): continue                                        // keep as decided; decision survey unchanged
    // owner 2026-10-22: a re-confirm on the SAME charge counts as re-chosen -> rewritten from this survey too,
    // decision_survey_id = this survey, enqueue_ts reset
    // owner 2026-10-22: a MULTIPLEXED bought R re-chooses its whole SET: count = max_charge_states (0 → all), anchor =
    // picks[0], notches = picks[1..]; a single-charge R uses count 1
    picks = selection_.rechooseCharges(nominal(r), {}, resolved_on_q, r has notches ? cap : 1)
    rewritten = ScanCommandQueue::reisolate(r, picks, marker 'R')   // see below
    adjust.push_back({r.scan_id, rewritten, this survey, windowPurity(raw_ms1, anchor window, anchor intensity)})
```

The old remainder is named in `replacePlan`'s `replace_remainder_of`: its **queued** commands are dropped. The caller sets
the new unit's `sent_charges = unit.sent_charges` from `waitingAt`, and `replacePlan` re-syncs them at the swap (Task 7b.4),
so a charge sent in between is neither re-sent nor counted twice.

**`reisolate` (new, `ScanCommandQueue`).** `buildMS2` mints a tracking id under the lock (SCQ.cpp:306-308), so it cannot
build a rewrite. Factor its geometry out, byte-identically, into two private statics that `buildMS2` then calls:
`applyIsolation_(cmd, pg, z, margin)` (SCQ.cpp:344-353: centre, width, `stages[0].charge_state`) and the multiplexed notch
write (:379-401, from an explicit charge list). The public
`static ScanCommand reisolate(const ScanCommand& r, const std::vector<std::pair<int, const PeakGroup*>>& picks, double margin, char marker)`
copies `r`, applies the anchor geometry from `picks[0]`, clears and rewrites stage-0 notches from `picks[1..]` (each from
the PeakGroup that resolved it), and **rebuilds `scan_description`** keeping `r`'s 3-char id: `replacePlan`'s adjust does
not touch the description, so a stale `@z` would otherwise reach the instrument and every log.

Owner ruling 2026-10-22: a bought R re-confirmed on the same charge resets `decision_survey_id` and `enqueue_ts`, exactly
like a re-confirmed survey unit.

Quant verdict (:721-723): after `stampAndPush_(ident, …)`, add
`queue_.registerAdjustable(ident.scan_id, resolvedChargesOf(cons.winner_cmd's survey PeakGroup), q_survey_id)`. The
resolved charges are captured at `addMember` time. Add `std::vector<int> resolved_charges` to `GroupMember`, filled
from the PeakGroup's SNR-admissible charges when the `Q` is built, and `int survey_id` (the `Q`'s parent).

- [ ] Tests: in `FLASHIda_Replan_test.cpp`:
  - `separate_r_remainder_is_rederived` and `…_kept_when_unresolved` (Task 9);
  - `bought_r_adjusted_to_better_charge`: method_quant_welch; verdict buys R at z22; B ranks z23 first and both surveys
    resolve it → the R row's charge is 23, `decision_survey_id` is B, its parent is still the winning Q, and `enqueue_ts`
    is reset;
  - `bought_r_reconfirmed_same_charge_resets_decision`: B ranks z22 first again → the R stays at z22, `decision_survey_id`
    is B, `enqueue_ts` reset;
  - `bought_r_keeps_charge_unresolved_on_q_survey`: B ranks z24, which the Q survey didn't resolve → the R goes out at
    z22 with `decision_survey_id` = the Q's survey.
  - `bought_r_multiplexed_set_rechosen` (owner 2026-10-22): method_quant_multiplexed (cap 3); the verdict buys an R
    isolating {a,b,c}; B ranks a different top-3 within the charges both surveys resolved → the R's anchor + notches are B's
    top 3, its `scan_description` `@z` is the new anchor, `decision_survey_id` is B.
  - `reisolate_matches_buildMS2_geometry` (`ScanCommandQueue_Concurrent_test`): for a PeakGroup and charge set, `reisolate`
    of any command yields the same stage-0 geometry, notches and description suffix as `buildMS2` on that set.
- [ ] Commit `feat(FLASHIda): separate R remainder re-plan and bought R adjust`.

### Task 11: Logging, loader, join, comparer

**Files and changes:**

`IdaLogger.cpp`:
- header (:71-106): insert `decision_survey_id`, `isolation_purity` before `enqueue_ts` → 36 columns;
- `writeScanCommandRow` (:348-492): new trailing parameter `const DecisionInfo* decision` (namespace scope, `ScanCommandQueue.h:61-74`).
  It writes `encode(decision_survey_id)` or empty, and `isolation_purity` at fixed 4 decimals or empty. The drain
  (:1296) passes `queue_.takeDecisionInfo(out.scan_id)`;
- `writeIDALogEntry` (:226-334): Mass= line gets `<< "\tID=" << encode(cmd.scan_id)` before `"\n"`. A new parameter
  `const std::vector<int>& superseded` writes `Superseded=` + space-joined encoded ids on its own line right after the
  MS1 header, only when non-empty.

`PrecursorSelection` constructor loader (C:56-147) becomes two passes: read all lines, collect `Superseded=` ids,
then parse as today, skipping any `Mass` line whose `ID=` value is in the set. A log without `ID=` is unaffected.

`ScanCommandJoin.h`: `Row` gains `std::string decision_survey_id;`. `parse` reads it if the column exists (not
required). `surveyScanNumber_` becomes:
```cpp
if (!row.decision_survey_id.empty())
{
  auto r = rows.find(row.decision_survey_id);
  if (r != rows.end() && r->second.ms_level == 1)
  { auto s = scan_of.find(row.decision_survey_id); return s == scan_of.end() ? -1 : s->second->scan_number; }
}
/* existing parent walk, unchanged */
```

`LogGoldenComparer.cs`: `CmdIdColNames` (:50) adds `"decision_survey_id"`. `NormalizeIdaLog` (:219-229) adds
`Regex.Replace(text, @"\tID=\S+", "\tID=<ID>")` and
`Regex.Replace(text, @"^Superseded=.*$", m => "Superseded=" + string.Join(" ", m.Value.Substring(11).Split(' ').Select(_ => "<ID>")), RegexOptions.Multiline)`.

**Tests (changed ones need your sign-off; flagged ✎):**
- ✎ `FLASHIda_LoggingFields_test::schema_column_counts` — 34 → 36; `enqueue_ts` still last; pinned indices unchanged.
- ✎ `FLASHIda_LoggingFields_test::ida_log_target_line_precision_is_pinned` — field count 9 → 10; `ID` has no decimals.
- ✎ `FLASHIda_Logging_test.cpp:49-54` `kCmdHeader` — the two columns added.
- new `FLASHIda_Logging_test::scan_commands_join_prefers_decision_survey_id` — a row whose parent walk lands on survey
  S1 but whose `decision_survey_id` is S2 → `parent_scan_number` is S2's scan.
- new `…::scan_commands_join_falls_back_to_the_walk_without_the_column` — the existing pre-ADR-0046 fixture, unchanged
  results.
- new `FLASHIda_LoggingFields_test::decision_columns_on_every_survey_decided_ms2` — every MS2 row with marker R/Q/E
  that a survey decided: `decision_survey_id` non-empty, `isolation_purity` in [0,1] and equal to `windowPurity`
  recomputed on that survey; follow-ups/MS3/MS1 have both empty.
- new `FLASHIda_LoggingFields_test::target_log_skips_superseded_masses` — write a log with two entries, the second
  `Superseded=` naming the first's mass id; `in_depth` drive → that mass contributes no tqscore observation.
- new C# `LogColumnReorderTests.NormalizeIdaLog_MasksIdAndSuperseded`.

- [ ] Fail → implement → `ci cpp FLASHIda_Logging_test FLASHIda_LoggingFields_test` PASS → commit per repo
  `feat(logging): decision_survey_id, isolation_purity, ida.log ID= and Superseded=`.

### Task 12: Push 2 gate and goldens

Predicted golden movement. Any cell outside this table → STOP:

| Stream | Modes | Change | How it's proven |
|---|---|---|---|
| `scan_commands` | all 33 | +2 columns | strip the 2 columns → byte-identical to the old golden, **except** the FAIMS modes |
| `ida.log` | every mode with a `Mass=` line | `\tID=<ID>` appended | strip `\tID=<ID>` → identical, except FAIMS |
| all 5 streams | `faims` (3-CV cycling) | real re-planning: a CV-transition MS1 runs ahead of waiting MS2s, and the same-CV survey that comes back re-plans them | cell diff shown; `[REPLAN]` counts quoted from stdout |
| all | `faims_single_cv` | none beyond the columns (single CV, no cycling) | mechanical |

- [ ] `ci cpp --full` PASS; `ci cs` → expected red only in log goldens; `ci golden-diff` → the mechanical proof script
  (in the scratchpad) over all 33 modes; the FAIMS diff presented in cells.
- [ ] **STOP for your manual review.** After sign-off: host-side `cp` of the `.normalized` files (assert 33 dirs × 5
  non-empty first); continuity JSONs and regression TSVs re-checked (`ci cs` green).
- [ ] Push (OpenMS, FlashIDA, parent), watch CI. A float-only CI red → promote the CI artifact per `docker/README.md`.

---

# PUSH 3 — docs

### Task 13: ADR-0060 and the doc set

- [ ] `docs/adr/0060-a-survey-re-plans-waiting-work-and-only-the-drain-commits.md`: the spec's decisions, plus both
  audit corrections. It supersedes ADR-0059 d.4–8 and amends 0046 (the join) and 0056 (the bought R window). It
  carries a pointer line in 0059, 0046 and 0056.
- [ ] `CONTEXT.md`: new **Plan unit**, **Staged / committed** and **Decision survey** entries; retire **Charge
  reselection**.
- [ ] `CLAUDE.md` (parent): the `GetNextScanCommand` box gains "dequeue commits"; the scan_commands column count
  becomes 36; the goldens table is unchanged. `OpenMS/CLAUDE.md`: the queue section, the lock order, and the stale
  `cancelByScanIds` and baseline lines. `FlashIDA/CLAUDE.md`: the logging columns.
- [ ] `docs/kb/scan-pipeline/` and `docs/kb/ms1-acquisition/`: the lifecycle, refreshing `last_verified` and
  `code_anchors`.
- [ ] `FlashIDA/docs/site/method.schema.json`: the `precursor_selection` description mentions re-planning (no key).
- [ ] Commit per repo; push; CI green (a push to `phase-containers` republishes the public site).

---

## Test inventory (frozen; changes need sign-off)

| Exe | New | Changed ✎ | Deleted |
|---|---|---|---|
| *(Push 1, landed)* `PlanUnit_test`, `FLASHIda_ChargeModes_test`, `ScanCommandQueue_Concurrent_test`, `FLASHIda_exploration_test` | as planned | | |
| `ScanCommandQueue_Concurrent_test` | **Task 7b:** `multiplexed_command_commits_every_notch_charge`, `cancelled_member_leaves_registry`, `reconciled_unit_is_reported_in_full`, `remainder_replacement_skips_a_charge_sent_after_waitingAt`, `remainder_replacement_refused_when_old_unit_emptied`; **Task 10:** `reisolate_matches_buildMS2_geometry` | | |
| `FLASHIda_ChargeModes_test` | **Task 7b:** `rollback_after_a_non_ms1_call_is_a_noop` | | |
| `FLASHIda_Replan_test` (new exe) | 18 sections (Tasks 8–10; + `bought_r_multiplexed_set_rechosen`) | | |
| `Config_SchemaProjection_test` | `reselect_charges_is_a_migration_error` | | `reselect_charges_parses` |
| `ConfigSchemaParity_test` | | the `reselect_charges` line removed | |
| `FLASHIda_Logging_test` | 2 join sections | `kCmdHeader` | |
| `FLASHIda_LoggingFields_test` | `decision_columns_on_every_survey_decided_ms2`, `target_log_skips_superseded_masses` | `schema_column_counts`, `ida_log_target_line_precision_is_pinned` | |
| C# `LogColumnReorderTests` | `NormalizeIdaLog_MasksIdAndSuperseded` | | |
| C# `FLASHIdaLogGolden_test` | | goldens recaptured (Task 12) | |

## Open calls flagged inline (`// ISSUE`)

0. ~~Multiplexed bought R~~ — resolved 2026-10-22: it re-chooses its whole set (Task 10).

1. ~~Task 9 seam~~ — resolved: the private hook.
2. ~~Task 10 re-confirm~~ — resolved: re-confirm resets.
3. **Task 2:** the legacy `.log` target charge erase is journaled as it behaves today, including its stale-pointer
   quirk, and is not fixed here.

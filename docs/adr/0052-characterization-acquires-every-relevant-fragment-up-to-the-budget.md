# 0052. Characterization acquires every relevant fragment up to the budget

Status: Accepted (2026-10-12), implemented 2026-10-13. Amends
[ADR-0005](0005-ms3-target-is-a-containing-fragment.md) (its clause "the separate Coverage objective
analogously targets containers of uncovered gaps"). Extends
[ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) with a fifth `characterization.mode`
value. Leaves [ADR-0023](0023-exhaustive-characterization-targets-unassigned-masses.md) unchanged.

## Context

On the 2026-10-12 Eclipse ubiquitin run (`methodDirectInfusionUbiquitinMS3.json`,
`characterization.mode: coverage`, `max_targets: 1000`) the MS2 winner mapped 67 fragments and left 26
of its 75 backbone bonds unwitnessed, yet `[MS3-PLAN]` planned **2** targets. Coverage was a greedy set
cover: strongest first, a fragment kept only if its interior added a bond no earlier pick had
*optimistically* claimed, on the assumption that an MS3 witnesses every bond inside its parent. y58
claimed bonds 19–75 and b76 claimed 1–18, so the other 65 were skipped. b76 was 8541.59 Da, the
precursor (8559.58) minus water, so one of the two MS3 scans re-fragmented the intact protein.

The operator's budget was never what limited the plan. A set cover spends as few scans as possible on
an assumption that no single MS3 meets, which is the wrong economy for a project at the stage of
finding out what MS3 yields at all.

## Decision

1. **Coverage acquires every coverage target**, strongest best-MS2 intensity first, until
   `max_targets`. A coverage target is an observed fragment whose interior holds at least one bond
   no MS2 fragment witnesses. One pick never excuses another because their interiors overlap. The
   uncovered set is computed once, from MS2, and is not updated as targets are chosen.
2. **Ambiguity is unchanged.** It targets containers of ambiguous modifications, round-robin across
   modifications so that a short budget still gives every site its strongest container. A model with
   nothing ambiguous plans no MS3 (`all_mods_localized`). It does not fall back to coverage, so
   `mode` keeps naming exactly one objective.
3. **A new mode, `fragments`, acquires every mapped fragment** that carries an MS2 observation and
   has a bond inside it, strongest first, until `max_targets`, with no coverage test. A one-residue
   ion (b1, y1) is skipped because its MS3 cleaves nothing. It is exhaustive without the unassigned
   masses, and coverage without the uncovered-bond test.
4. **A full-length ion (b_L, y_L) is never a target** under `coverage`, `ambiguity` or `fragments`:
   it is the precursor, and re-fragmenting it yields nothing an MS2 cannot. `exhaustive` is exempt,
   because its contract is every deconvolved mass. `discriminating` (ADR-0049) falls through to the
   ambiguity branch once its decision has fired, and inherits the rule there.

## Considered options

- *Keep the set cover and only drop full-length ions.* Rejected: on ubiquitin it would still have
  planned about three targets against a budget of 1000.
- *Ambiguity falls back to coverage when nothing is ambiguous.* Rejected: it creates a third
  objective under an existing name, and `coverage` already exists for that case.
- *Ambiguity as one intensity-ranked pool.* Rejected: when the budget binds, a site whose containers
  are all weak gets no MS3 at all.

## Consequences

- Two coverage goldens move: the log golden `ms3_coverage_cytc` and the continuity golden
  `continuity_ms3_mode2_real.json` (CT36, `method_ms3_mode2_hcd.json`). Both configs keep
  `max_targets: 3`, so the count stays capped and only the choice of fragments changes. No committed
  golden ever picked a full-length ion, so no ambiguity golden moves.
- `fragments` becomes log-golden mode 33 (after refine_discriminating_cytc, ADR-0049), `ms3_fragments_cytc` (`method_ms3_cytc_fragments.json`, the
  coverage config with `mode` changed). Under a cap of 3 it may well pick the same ions as `coverage`,
  so the C++ `planNextScans` sections, on a model rich enough to separate the two, are what tell them
  apart.
- **The scan count now scales with the budget.** Every target runs the whole MS3 exploration grid:
  67 targets on a 1–50/1 grid is 3350 exploration MS3 scans for one precursor, and the cycle-time MS1
  is skipped while the sweep runs. `max_targets` and the grid are the operator's levers. This ADR
  adds no limit of its own.

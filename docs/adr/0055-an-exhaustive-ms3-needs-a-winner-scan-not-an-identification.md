# 0055. An exhaustive MS3 needs a winner scan, not an identification

Status: Accepted and implemented (2026-10-13, OpenMS 9780683452). Grilled 2026-10-13; every decision
below is the owner's.
Amends: [ADR-0023](0023-exhaustive-characterization-targets-unassigned-masses.md) decision 10 —
"Identification is still required. `no_plan("unidentified_precursor")` stands (ADR-0002)."
Related: [ADR-0027](0027-identification-is-gated-by-the-sequence-not-the-ms3-switch.md) (the
sequence gate, which stands); [ADR-0054](0054-an-ms3-is-acquired-behind-any-activation-and-annotated-only-on-a-b-or-y-precursor.md)
(lifts the ETD refusal on the same pool — together the two make an unidentified ETD MS2's masses
acquirable); [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md) (reading vs
measuring metrics).

## Context

`exhaustive` targets every deconvolved mass of the winner MS2 scan, mapped or not. Its pool, its
labels and its MS3 scoring were all built to work without a proteoform: a mass no mapped fragment
claims is labelled `u`/0, and an unassigned target's MS3 sweep is scored by a measuring metric
(0023 d.11), which needs no ion frame. Yet the mode refused every Precursor whose MS2 matched
nothing, through four gates in sequence: the non-exploration path built no model without a match,
`finalizeMS2` chose no winner without an identification score (so the pool was never captured),
`dispatchFromModel` skipped an unidentified model, and `planNextScans` returned
`reason=unidentified_precursor`.

Decision 10 justified the refusal by a division of labour — "an unidentified Precursor is the
escalation ladder's problem — change the chemistry at MS2". That ladder was never built: nothing in
the real-time engine re-acquires an unidentified Precursor under different chemistry. So the
division of labour was one-sided, and an unidentified Precursor under `exhaustive` simply received
nothing — exactly the species whose masses are least explained, and so most worth fragmenting
further.

## Decision

1. **Scope: a sequence is still required.** `characterization.protein_sequence` remains mandatory
   whenever `mode != off`, and ADR-0027's sequence gate is untouched. What changes is the
   *per-Precursor* outcome: an MS2 that did not match the configured sequence no longer bars that
   Precursor from exhaustive MS3. Every other objective is unchanged — their targets are ions of
   the proteoform, so they still require one.

2. **The winner scan of an unidentified Precursor is the scan the MS2 decision already chose.**
   With an identification the winner stays the highest-identification-score scan. Without one it is
   the scan the cascade dispatches from: the exploration metric's winner, or — when exploration
   overrides exist — the production follow-up MS2; on the non-exploration path, the one MS2. The
   pool is that scan's deconvolved masses and stage 0 of every MS3 replays that scan's parameters.
   No third "best scan" rule is introduced, and the union of variants is rejected because stage 0
   must name one parameter set.
   Accepted consequence: under `fragment_count`, a reading metric, every variant of an unidentified
   sweep scores 0 and the first variant (`ce_min`) wins. That is the metric being honest about
   having nothing to read; it is logged, not corrected.

3. **The model stays unidentified.** It carries the winner scan's masses and parameters but no
   proteoform. It contributes no row to `pooled_identification.tsv`, and returning MS3s are not folded
   into it. Every target is `u`/0, so the matcher refuses each one and `identification.tsv` gains no
   MS3 row; the MS3s appear in `scan_commands.tsv` and `scan_results.tsv` and join back to their MS2
   by `parent_tracking_id`. The `[MS3-PLAN]` marker reports `identified=0` in place of
   `reason=unidentified_precursor`.

## Consequences

- MS3 budget is now spent on unidentified Precursors under `exhaustive`. That is the point of the
  change, but the budget is per Precursor, so a run with many unidentified species acquires more
  MS3s in total than it used to.
- A Precursor with several MS2s and no identification (`additional_scans`, a conditional follow-up,
  a production MS2 after a sweep) re-points its model at **each** MS2 as it is dispatched from, and
  plans that scan's masses, minus the species already fragmented for that Precursor. The budget is
  per planning call, not per Precursor, so the MS3 count is up to (number of MS2s) × `max_targets` —
  exactly what an identified exhaustive Precursor already does, which is why no per-Precursor cap was
  added. A later MS2 that does identify takes the model over by the ordinary path.
- Mechanism: the one site that builds the model on the dispatch path (`initiateNextLevel`) feeds
  the dispatching scan and calls `finalizeMS2` with that scan's id as a fallback winner, used only
  when nothing identified. Because the regular MS2, the sweep's cascade and the production follow-up
  all pass through that site with the dispatching scan as context, decision 2 needs no knowledge of
  the metric inside the tracker.
- "Identified" can no longer be read off "has a model with a pool". Readers that used an empty
  `proteoform_sequence` as "no model worth acting on" keep doing so for every purpose except
  exhaustive planning.
- Golden-moving: `ms3_exhaustive_cytc` has MS2 rows that do not identify, and each such Precursor
  now plans up to `max_targets` MS3s.

## Coverage (agreed at grilling)

- `ProteoformTracker_Exhaustive_test`: `unidentified_precursor_plans_from_its_winner_scan` (pool,
  `u`/0 labels, stage 0 from that scan); `unidentified_precursor_stays_unidentified` (no sequence,
  no pooled row, no fold); `other_objectives_still_refuse_an_unidentified_precursor` (ambiguity,
  coverage, fragments, discriminating keep `reason=unidentified_precursor` — the guard against the
  change leaking past exhaustive).
- `FLASHIda_exploration_test`: `unidentified_ms2_sweep_dispatches_exhaustive_ms3_from_the_metric_winner`
  (the metric winner must NOT be variant 0, or the test cannot tell decision 2 from "first staged
  scan"); `unidentified_regular_ms2_dispatches_exhaustive_ms3`.
- `ms3_exhaustive_cytc` log golden recaptured, promoted only after the owner has seen the cell diff.

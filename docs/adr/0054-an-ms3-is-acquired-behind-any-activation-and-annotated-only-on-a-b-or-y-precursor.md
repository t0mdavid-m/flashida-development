# 0054. An MS3 is acquired behind any activation, and annotated only on a b- or y-precursor

Status: Accepted, implemented 2026-10-13. Grilled 2026-10-13; every decision below is the owner's.
Amends: [ADR-0023](0023-exhaustive-characterization-targets-unassigned-masses.md) decision 3 — "if
the rung was ETD, every mass in it is MS3-incapable … so the mode plans nothing". And
[ADR-0049](0049-a-mass-shift-is-detected-before-the-path-and-flashtnt-stays-a-method.md)'s
consequence that a winner scan which "cannot be isolated for MS3 (an ETD MS2 among them)" falls a
`discriminating` round through with `reason=winner_scan_not_ms3_capable`.
Related: [ADR-0003](0003-two-stage-ms3-parameter-sourcing.md) (stage 0 replays the MS2 that made the
fragment — it never said ETD cannot be replayed); [ADR-0030](0030-activation-decides-whether-a-coupled-parameter-is-emitted.md)
(the activation-coupled sets ETciD is added to); [ADR-0045](0045-a-trap-pre-scan-is-measured-never-identified.md)
(the "score 0, `ce_min` wins" shape — deliberately accepted here, not refused).

## Context

"MS2 ETD → MS3 HCD is not supported" was true in two of five modes and false in three.
`ProteoformTracker::winnerIsMs3Capable` — a hardcoded `"" | HCD | CID` whitelist on the winner MS2's
activation — refuses `exhaustive` outright and falls `discriminating` through to `ambiguity`; but
`ambiguity`, `coverage` and `fragments` never consulted it, and already dispatch `ETD;HCD` MS3s on the
c/z fragments an ETD MS2 maps. Those MS3s were then annotated by `MS3FragmentMatcher`, whose
sub-ion chemistry is a b/y-precursor's: a c-precursor's suffix sub-ions are predicted ~17 Da low, a
z-precursor's prefix sub-ions are wrong, and a/x (UVPD) are off by CO the same way. Nothing threw;
the miscount fed coverage, modification narrowing, the `fragment_count` score and the Refine piece
test. No golden contained an MS3 behind an ETD MS2, because no committed ETD fixture identifies.

## Decision

1. **The activation of the MS2 never refuses an MS3.** `winnerIsMs3Capable` is removed; `exhaustive`
   and `discriminating` plan behind an ETD-family winner like any other.
2. **Annotatability is a property of the targeted ion's type, never of an activation** — see
   *Annotatable MS3 precursor* in `CONTEXT.md`. Only a **b- or y-precursor** is annotated against its
   own sub-ions. A c, z, a or x precursor is acquired and logged and **not annotated**: no matched
   sub-ions, no coverage, no modification narrowing, no MS3 fold, no piece-test evidence. An EThcD
   MS2's b/y targets stay annotated. a/x are included although they arise only from UVPD, because the
   matcher is wrong for them in the same way. **Not covered by this rule:** the whole-protein
   identifier an MS3 *exploration variant* also runs through (`Exploration::computeFragmentMatch_`)
   never reads the precursor's ion type and matches full-protein ions, whose masses are right whatever
   the precursor was (a c precursor's b sub-ions are genuine full-protein b ions). It is left as is, so
   such a variant can still write an `identification.tsv` `E` row at ms_level 3.
3. **"Has a frame" and "is annotatable" are two predicates.** `MS3FragmentMatcher::isKnownIonClass`
   (a b c x y z) is unchanged — a c/z fragment still has a span, so it is a containing fragment or a
   coverage target. The new predicate gates every MS3 annotator. Narrowing `isKnownIonClass` instead
   would also trip `Exploration.cpp`'s ADR-0023 forced `remaining_precursor` sweep, which decision 5
   rejects.
4. **A `discriminating` round behind an ETD-family winner runs.** Its MS3s are acquired and close the
   round. A record side whose ion is not annotatable contributes no piece evidence. **If no
   dispatched record had an annotatable side, the round keeps path a without a recount** and prints
   `[DISCRIMINATING] … decided=kept reason=no_annotatable_pieces`: with both `confirmed` terms 0,
   `Refine::recount` degenerates to shared-mass count minus jump penalty, which can flip the winner
   to the lower-S path on no MS3 evidence at all. With some annotatable records the recount runs as
   before.
5. **An MS3 exploration sweep on an unannotatable target runs its configured metric unchanged.**
   Under `fragment_count` every variant scores 0 and `ce_min` wins; without overrides the sweep
   cascades and no production MS3 follows. Accepted knowingly — the scans are wanted, the verdict is
   not.
6. **Nothing new in the log streams.** The ion type already sits in `scan_commands.tsv`
   (`ion_type`/`ion_index`) and `identification.tsv` (`precursor_ion`), so "not annotated" is read
   off the type. A stdout marker `[MS3-UNANNOTATED] precursor_id=… ion=… scan=…` is added.
7. **ETciD joins both activation-coupled sets** — `needsReactionTime` **and** `needsCollisionEnergy`,
   on both sides (`Config.cpp`, `ScanFactory.cs`), spelled `ETciD`. Until now an ETciD scan sent no
   `ReactionTime` and an ETciD sweep fell to the single-variant branch.

## Consequences

- **Verification is synthetic tests only** — no golden mode, so no golden moves. Pinned by:
  `MS3FragmentMatcher_test` (`annotatable_ms3_precursor_is_b_and_y_only`,
  `calibrate_and_score_annotates_only_a_b_or_y_precursor`); `Refine_test`
  (`piece_test_ignores_an_unannotatable_side`); `ProteoformTracker_Exhaustive_test`
  (`every_winner_activation_plans_alike`, rewritten from the ETD refusal);
  `ProteoformTracker_Discriminating_test` (`etd_winner_runs_the_round`, rewritten from the
  `winner_scan_not_ms3_capable` fall-through, and `no_annotatable_pieces_keeps_path_a_without_recount`);
  `FLASHIda_exploration_test` (`ms3_sweep_on_a_c_ion_keeps_its_configured_metric`); the exact-set pins
  `Config_SchemaProjection_test` ∥ `ScanFactoryTests` (ETciD in, `EtCID` out); and
  `ScanFactoryTests.ReactionTime_IsPositional_ForEtdThenHcd` for the `ETD;HCD` wire strings. The
  three new engine gates were each mutated out and the matching assertions failed.
  **Not covered:** the `[MS3-UNANNOTATED]` print, and the end-to-end path — a real ETD MS2 mapping c/z
  fragments that become MS3 targets — for want of an identifying ETD fixture.
- **Open on hardware:** an `ETD;HCD` MS3 sends `ReactionTime "7;0"`. The instrument rejects a reaction
  time of 0 on an ETD stage (ADR-0048); whether it accepts `0` on the HCD stage is unverified — the
  mirror `HCD;ETD` is the only order tested. The first ETD→HCD run is the check.
- **An unannotated MS3 costs a scan and buys only raw data.** Under `coverage`/`fragments` its bonds
  stay uncovered, so the model's coverage does not rise from it.
- The stale `upsertMappedObservation_` cross-reference in `winnerIsMs3Capable`'s comment and
  `CONTEXT.md`'s `best_ms2_ms3_capable` under *Unobserved fragment* go with the predicate.
- A real c/z/a/x MS3 matcher is the change that removes the skip; it is out of scope here.

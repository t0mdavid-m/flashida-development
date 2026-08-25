# 0029. A baseline belongs to its activation

Status: Accepted (2026-08-25), implemented.
Related: [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md),
[ADR-0026](0026-a-remaining-precursor-sweep-scans-only-the-window-it-reads.md),
[ADR-0030](0030-activation-decides-whether-a-coupled-parameter-is-emitted.md).

## Context

An exploration sweep varies one axis of one scan config and picks the best result. Since the
Phase-2 decision of 2026-07-06 every sweep also acquires a **baseline**: an un-fragmented reference
scan, skipped in winner selection and excluded from the pooled proteoform model, whose isolation-window
intensity is the denominator of every variant's `remaining_ratio` and the reference
`ExplorationMetric::RemainingPrecursor` scores against.

`Exploration::initiate` created exactly one, by prepending it to the variant list:

```cpp
variant_params.insert(variant_params.begin(), {base_config.activation, 0.0, 0.0});
```

`exploration.activations` has always been a **list**. `buildVariants_` walks it and emits each
activation's whole sweep before starting the next, so a group can contain three independent sweeps.
Against that, one prepended baseline is wrong in three separate ways, and a user sweeping
`["CID", "HCD", "ETD"]` with `ce_min: 0` met all three at once:

**1. It is stamped with the wrong activation.** `base_config.activation` is `ms_settings.ms2`'s,
which need not be any of the swept ones. A method whose MS2 config says HCD while it sweeps CID and
ETD produced an HCD reference and no other.

**2. It duplicates a real sweep point.** With `ce_min: 0` the HCD block's first variant is *already*
`HCD @ CE 0` — the same command the baseline just issued. The instrument acquired it twice. This is
what the sweep looked like from the outside, and what prompted this ADR:

```
HCD 0            <- prepended baseline
CID 0 .. CID 50
HCD 0 .. HCD 50  <- HCD 0 for the second time
ETD RT0 .. RT50
```

**3. It measures the wrong thing for two of the three activations.** This is the substantive one.
An ETD scan is acquired through a different ion path from an HCD scan — reagent ions are injected
and the ion-ion reaction cell is engaged — so its intact-precursor window intensity can differ
systematically from HCD's even with no fragmentation at all. Ratioing an ETD variant against an HCD
reference mixes two measurements that were never comparable. A single `double baseline_intensity`
on `ExplorationGroup` made that mixing unrepresentable-as-a-bug: there was nowhere to put a second
reference, and whichever baseline arrived last silently became the denominator for everything.

There is also a cost question underneath. Three references cost three scans, and the whole point of
the report was that the sweep was acquiring *more* scans than it needed.

## Decision

**A baseline belongs to an activation, not to a group.** Concretely:

1. **One reference per swept activation**, at the head of that activation's own block.
   `buildVariants_` owns baseline placement; `initiate` prepends nothing.

2. **A baseline is that activation's variant template with the swept axis alone set to zero.**
   CE 0 for a CE-swept activation, reaction time 0 for an RT-swept one, both for EThcD. Every other
   parameter is exactly what its siblings carry — so an ETD baseline keeps
   `base_config.collision_energy`, and does **not** drop it to 0.

3. **If a block's sweep already contains its own zero-point, that variant *is* the baseline.** No
   second scan is synthesized; the existing one is flagged. The test compares the two *emitted
   commands* rather than checking `ce_min == 0`, so one rule covers CE-only, RT-only and EThcD's
   cross-product, and decision 2 is what makes the flagged and synthesized forms provably identical.

4. **An activation that sweeps neither axis gets no baseline** and competes normally. A baseline is
   "this scan with fragmentation turned off"; with no swept axis there is nothing to turn off.

5. **Each activation's variants ratio against their own reference.**
   `ExplorationGroup::baseline_intensity` becomes `std::map<std::string, double>`, keyed by
   activation, carrying three states in one container: absent (not yet returned), `> 0` (usable
   denominator), `<= 0` (returned empty).

6. **An empty reference bars its activation from winning; it cancels nothing.** Its variants are
   still acquired and score `-1.0` — not `0.0`. Sibling activations are unaffected. When every
   activation is de-referenced, no variant is eligible and the group ends with no winner.

Decision 6 replaces a whole-group abort that cancelled every queued and in-flight child. The
`-1.0` is load-bearing and is not a stylistic choice of sentinel: winner selection seeds
`best_score = -1.0` and takes `score > best_score`, so `-1.0` is excluded by the existing
comparison and needs no new flag, no new field and no new branch — while `0.0` **wins**. That was
the live hazard in the naive version of decision 6: an unscoreable variant taking the group at
score zero, and at MS3 a measuring metric then firing a production scan at that coin-flip CE.
`-1.0` is also `ExplorationVariant::score`'s own "not scored" default and matches
`remaining_ratio`'s existing `-1 = N/A`, so the logs read consistently.

## Consequences

- **The reported duplicate is gone**, and a sweep with zero floors gets *cheaper*: the myoglobin
  method above goes from 154 scans per precursor to 153, with three references instead of one.
- **A multi-activation sweep costs one extra scan per additional activation** when the floors are
  non-zero. That is the price of decision 3's correctness, and it is bounded by the number of
  activations, not by sweep length.
- **`has_baseline` and `baseline_failed` are gone.** Both were scalar facts about a group that are
  now per-activation facts; the map's three states carry them.
- **`ScanCommandQueue::cancelByScanIds` loses its only production caller** and is deliberately
  kept: it is an independently useful queue primitive with five dedicated sections in
  `ScanCommandQueue_Concurrent_test`.
- **Nothing recaptures.** Every committed exploration config sweeps exactly one activation with a
  non-zero floor, and in each the scan config's activation already equals the swept one and the
  non-swept axis is already 0 — so the new rule synthesizes one baseline at index 0 with the same
  activation and the same CE/RT. Byte-identical, `dda_etd` and `exploration_etd` included.
- **`variant_index -1` may now appear more than once per group.** It is a marker, not an identity;
  variants are routed by tracking id, and the logged column distinguishes baselines by activation.
- **The FIFO invariant survives** — each block's baseline is its first member, so it still dequeues
  ahead of the siblings it is the denominator for.

Pinned by `FLASHIda_exploration_test`: `baseline_is_one_per_swept_activation`,
`baseline_suppressed_when_sweep_contains_zero_point`, `baseline_matches_the_non_swept_axis`,
`remaining_ratio_uses_its_own_activation_baseline`, `empty_baseline_bars_only_its_own_activation`,
`non_swept_activation_gets_no_baseline`.

## Alternatives rejected

**Keep one baseline, just stop it duplicating a sweep point.** A three-line fix for symptoms 1 and
2 that leaves symptom 3 — the substantive one — untouched, and leaves the group with a single
denominator it has no honest way to key.

**One reference per activation, but a shared denominator.** Pays for the scans and uses one of
them. Strictly worse than either coherent option.

**Cancel only the de-referenced activation's variants.** Coherent, and it collapses to today's
behaviour for a single activation so no pinned test moves. Rejected in favour of decision 6 on the
grounds that it reintroduces cancellation machinery — a queue sweep, a removed-child reconciliation
and a routing erase — to save instrument time on a path that is already a failure. The scans are
acquired and discarded instead.

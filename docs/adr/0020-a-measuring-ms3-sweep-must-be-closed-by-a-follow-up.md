# 0020. A measuring MS3 sweep must be closed by a follow-up scan

Status: Accepted (2026-08-10), implemented. Corrects shipped behaviour of MS3 CE exploration.
Related: [ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md),
[ADR-0002](0002-proteoform-tracker-dispatch-authority.md).

## Context

An exploration group sweeps a fragmentation parameter (today: collision energy) over N pre-scans and
picks a winner by an `ExplorationMetric`. Three metrics exist, and they divide into two kinds that
nothing in the code named until now:

- **Reading** — `FragmentCount`. It scores a variant by *matching it against the proteoform*, so
  producing an identification is how it computes its score. Identification is a side effect of
  scoring.
- **Measuring** — `MassCount`, `RemainingPrecursor`. They score from peak counts and isolation-window
  intensity. They never invoke a matcher.

At **MS2** this distinction is invisible: `Exploration::computeFragmentMatch_` runs the whole-protein
matcher for every metric, and at MS2 that is the correct matcher, so every variant is identified
regardless of which metric was chosen.

At **MS3** it is decisive. An MS3 spectrum holds sub-fragments of one fragment ion; matching it needs
the calibrated subsequence matcher (`ProteoformTracker::scoreCalibratedVariants`, seeded with the
proteoform context and the parent's `fragment_ion_type`/`index`). The whole-protein matcher run
against such a spectrum finds nothing. And that calibrated matcher was invoked from exactly one
place — `Exploration.cpp`'s batch re-score, guarded by
`group.exploration_metric == ExplorationMetric::FragmentCount`.

The consequences compounded, all silent:

1. `ExplorationVariant::identification_result` has a **single write site**, inside that guard. Under a
   measuring metric it stays default-constructed for every variant.
2. The inline fold at group completion — the branch written specifically for "MS3 group, no
   production scan", whose own comment says it exists because *nothing else will fold this group's
   result into the trajectory* — is gated on `!identification_result.fragments.empty()`. Under a
   measuring metric that condition is unreachable, so `feedScan`/`foldMs3` never run and nothing
   reaches `pooled_identification.tsv`.
3. The per-scan identification row falls back to `computeFragmentMatch_`'s whole-protein match of an
   MS3 spectrum, which is empty, so no `ms_level=3` row is written to `identification.tsv` either.

A production run made the cost concrete: `characterization.mode: coverage` with
`characterization.exploration.metric: remaining_precursor`. Three MS3 targets × 22 scans = **66 MS3
scans acquired**, all with real deconvolved sub-fragments (1–49 masses each), three CE winners
correctly selected at CE 23 — and **zero** MS3 identification rows, `ms3_fragment_coverage = -1` on
every row, no MS3 contribution to the pooled model. MS3 occupied RT 0.54–2.96 min of a 3.3-minute
run and produced nothing.

The post-sweep production scan, which would have rescued this, was gated on
`!level_config.overrides.empty()`. That gate is itself coherent: `overrides` patches the *pre-scan*
config (`Exploration.cpp` builds variants from `scans[0] + overrides`, while the production scan is
built from `scans[0]` alone), so its meaning is *"the pre-scans ran at degraded settings."* When they
did, no variant is production-grade and a re-acquisition is required. When they did not, the winning
variant already **is** a production-grade scan — which is true, but only matters if something read it.

CI never caught this because every committed MS3-exploration fixture uses `fragment_count`. Of 37
configs, 19 enable MS3; 16 of those use fixed-CE MS3 (the regular path, which identifies correctly)
and the remaining 3 all sweep on `fragment_count`. `remaining_precursor` and `mass_count` at level 3
are legal, pass `Config::validate()`, pass the config validator clean, and were exercised nowhere.

## Decision

**Whether a sweep reads its own pre-scans is a property of its metric, and an MS3 sweep that reads
nothing must be closed by a follow-up scan that does.**

Concretely:

1. `isMeasuringMetric(ExplorationMetric)` is added to `Config.h` beside the enum, naming the
   reading/measuring split so it is a classification rather than a `== FragmentCount` comparison
   scattered across the file.
2. The post-winner production scan fires when **either** condition holds:
   - `overrides` is non-empty (unchanged — the pre-scans were degraded), at any level; **or**
   - the metric is measuring **and** the level is MS3 (new).
3. The follow-up returns on the **regular** MS3 path, where it is matched by the calibrated matcher
   against the live tracker winner (ADR-0002). `ms2_context_cache` is seeded for it, exactly as the
   overrides path already did — without that seed the scan is acquired and then silently
   unidentified.
4. The metric continues to gate identification of the *pre-scans* themselves. A measuring sweep
   still produces no per-variant MS3 identification rows; its evidence comes from the follow-up.

Deliberately **not** changed:

- **MS2 sweeps.** Their variants are already identified under every metric, so a follow-up would buy
  no evidence and would cost one extra scan per precursor while delaying the MS3 cascade. An MS2
  group with no overrides keeps cascading to MS3.
- **`FragmentCount` at MS3.** It keeps the old rule and the inline fold, which now becomes the only
  way to reach that branch. Re-acquiring would spend an extra MS3 per target for data the group
  already holds.

Separately, `ProteoformTracker::planNextScans` gains a `[MS3-PLAN]` line naming which of its nine
zero-target causes fired (`no_model`, `unidentified_precursor`, `no_ms2_context`, `zero_budget`,
`empty_sequence`, `empty_region`, `all_mods_localized`, `no_containing_fragment`,
`no_fragment_adds_coverage`) plus a success line carrying targets, fragments, budget and objective.
Previously every one of them returned empty silently, and "why did this run fire no MS3?" had to be
inferred from empty TSV columns. `all_mods_localized` is the *expected* end state of a successful
ambiguity run, so the line is an explanation and carries no severity.

## Consequences

**A measuring MS3 sweep costs one extra scan per target and now produces evidence.** For the run
above: 3 targets × 23 scans instead of 3 × 22, in exchange for the MS3 identifications the previous
66 scans failed to yield.

**The winning pre-scan's data is still discarded.** Under a measuring metric its spectrum is never
matched, even though the follow-up re-acquires at the same settings when `overrides` is empty. This
is the **Pre-scan** contract (*not kept as the final measurement*) applied consistently, and it is
the accepted cost of keeping the metric as the identification gate rather than always running the
calibrated matcher.

**No golden moves.** No committed config uses a measuring metric at MS3, so no log-golden mode, no
regression TSV and no continuity JSON changes. Verified by enumerating all 37 configs.
`method_exploration_ms3_remaining.json` is added to pin the combination, and
`FLASHIda_exploration_test` gains three assertions: a measuring MS3 group re-acquires (both
`mass_count` and `remaining_precursor`), and a `fragment_count` group still does not.

**`[MS3-PLAN]` is invisible on the instrument.** It is `std::cout`, and the engine's stdout is
discarded during a real acquisition — verified against the two run folders that prompted this ADR,
in which 66 `[TRACK-CREATE]` and 4 `[EXPL-WINNER]` lines were emitted and none survive. It is
therefore a development and CI aid only. This is a pre-existing limitation of *every* engine marker,
not one introduced here; routing engine stdout into the run folder would fix all of them at once and
is left as separate work. Writing to `ida.log` instead was considered and rejected: it would move all
17 log goldens for a diagnostic line.

**`mass_count` at MS3 is fixed by the same rule** even though no config uses it, because the rule is
keyed on the reading/measuring split rather than on `remaining_precursor` by name.

# 0026. A remaining-precursor sweep scans only the window it reads

Status: Accepted (2026-08-24), not yet implemented.
Amends: [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md).
Related: [ADR-0009](0009-scan-config-fully-determines-instrument-parameters.md),
[ADR-0016](0016-co-isolated-charges-are-one-detection.md),
[ADR-0019](0019-notches-get-their-own-array-and-a-per-stage-cap.md),
[ADR-0021](0021-precursor-charges-is-the-only-acquisition-geometry.md).

## Context

`ExplorationMetric::RemainingPrecursor` scores a variant from one number: the raw peak intensity
inside `[precursor_mz +/- isolation_width/2]`, ratioed against the CE-0 baseline's sum over the same
interval (`Exploration::precursorWindowIntensity_`). Everything else the pre-scan returns is
discarded. Under a measuring metric at MS3 the pre-scan is not even identified (ADR-0020), and its
winner is re-acquired by a production scan built from the un-overridden config.

So the sweep pays for a full-range acquisition and reads roughly 2 Th of it. On an **ion trap**,
where scan time is proportional to the m/z range swept, a 200-2000 pre-scan costs ~900x the scan
time of the window it actually reads. ADR-0020 measured the shape of that cost on real hardware: 66
MS3 pre-scans occupying RT 0.54-2.96 min, ~2.2 s each.

The knob is not missing. `ScanConfig::applyOverrides` already has `first_mass` and `last_mass`
branches, `exploration.overrides` is reachable end-to-end from `method.json`, and `Exploration`
applies it to the pre-scan base config. What is missing is **dynamism**: the window is computed per
target and per charge from the measured peak group, sixteen lines *after* `applyOverrides` has run,
so a static `"first_mass": "800"` is wrong for every other precursor.

Three obstacles stood in the way of simply binding one to the other.

**1. "The isolation window" was ambiguous at MS2.** `ScanCommandQueue::buildMS2` widens the measured
m/z range by `optimal_window_margin_` (0.4 Th) on each side before commanding it. `Exploration` does
not. So the interval the metric summed was **0.8 Th narrower than the interval the instrument was
told to isolate** -- on a precursor spanning ~1 Th, roughly 44% of the isolated range excluded from
the measurement. The comment above that line claimed it matched the commanded isolation; it did not.
At MS3 the two already agreed, because `Exploration` passes its own width straight into `buildMS3`.
Binding a scan range to the narrower of two disagreeing windows would have clipped ions that were
isolated on purpose.

**2. Narrowing an MS2 pre-scan destroys the MS3 target list.** An MS2 exploration group with empty
overrides cascades by feeding `initiateNextLevel` the **winner variant's deconvolved spectrum**. A
window-only spectrum contains no fragments, so the cascade yields zero MS3 targets -- no throw, no
warning, `[MS3-PLAN]` reporting `no_containing_fragment`, and a user concluding their protein did
not fragment. At MS3 this cannot happen: ADR-0020 gate #2 already re-acquires unconditionally.

The invariant that resolves it: **narrowing a pre-scan is safe exactly when a production
re-acquisition follows it** -- which is precisely ADR-0020's gate. The temptation is to let that
safety come from convention, since an ion-trap pre-scan necessarily carries an `analyzer` override
and therefore trips gate #1 anyway. That is the shape ADR-0021 was written about: acquisition
geometry sourced from an unrelated key, correct in every shipped config, silently wrong in
principle, CI green throughout.

**3. A multiplexed variant's readout is not contiguous.** `[first_mass, last_mass]` is one interval;
a notch set is not. For the cytochrome c in the committed configs, charge states 10-16 span m/z
773-1237 -- a 463 Th spread of 2 Th windows. Binding to the anchor alone would isolate seven charge
states and read one; spanning them all would cut the speed win from ~900x to ~4x. `separate` is
unaffected, since it fans out into one anchor per scan.

## Decision

**A remaining-precursor sweep declares that its pre-scans are measurements, and scans only what it
measures.**

1. **The binding.** For an exploration sweep whose metric is `RemainingPrecursor`, each pre-scan's
   `first_mass`/`last_mass` are set to `precursor_mz -/+ isolation_width/2` -- exactly the window, no
   pad and no floor added at this site. Applies at **MS2 and MS3**, to every variant **including the
   CE-0 baseline** (a full-range trap fill and a narrow trap fill are not comparable denominators).
   It never applies to the post-winner production scan, which is rebuilt from `level_config.scans[0]`
   and keeps its configured range, nor to any regular MS2/MS3.

   It gates on the group's **resolved** metric (`ExplorationGroup::exploration_metric`), never on the
   configured one (`level_config.exploration`). The two differ on exactly one input: the ADR-0023
   forcing inside `Exploration::initiate`, where an exhaustive-mode **unassigned** mass -- ion class
   `'u'`, which fails `MS3FragmentMatcher::isKnownIonClass` -- is dragged onto `RemainingPrecursor`
   whatever the config asked for, because a reading metric cannot score a target the matcher refuses
   to project. Those pre-scans read a 2 Th window like any other; gating on the configured metric
   would leave the one sweep that never had a config entry paying the full 200-2000 range.

   **No third rejection is added for that path, and one would be redundant.** Decision 3 buys the
   *configured* sweep its production re-acquisition from the schema; the forced sweep gets the same
   guarantee by construction:

   ```
   force fires  =>  msn_level >= 3  AND  metric == RemainingPrecursor (measuring)
                =>  measuring_ms3_sweep
                =>  ADR-0020 gate #2  =>  full-range production scan re-acquires
   ```

   The force's own precondition **is** gate #2's condition, and the metric it forces is measuring by
   definition -- so the close-out scan is entailed, not a convention the path happens to honour.
   Obstacle 2 does not reach it either: MS3 is terminal at the `< 3` MS4 wall, so a narrowed MS3
   pre-scan has no cascade to strand, and "a window-only spectrum yields zero next-level targets" is
   an MS2-only hazard that decision 3 covers at the only level where it exists. A third rejection
   would also have nothing to reject -- the forced metric has no config entry -- and rejecting the
   `exhaustive` mode that triggers it would delete ADR-0023.

2. **One window.** `Exploration` applies `optimal_window_margin_` exactly as `buildMS2` does, so the
   interval the metric sums **is** the interval the instrument was commanded to isolate. "The
   isolation window" now denotes one value. This also removes any need for a separate floor: a
   single-isotope charge yields a 0.8 Th window rather than a degenerate 0, and a charge with no
   peaks yields bounds that are **both** non-positive, which `ScanFactory` drops entirely in favour
   of the instrument default (`ScanFactory.cs:241-250`; see the gap noted in *Consequences* for the
   half-dropped case).

   `optimal_window_margin_` is promoted to a single shared definition in `NotchSelection.h`, next to
   `peakGroupNotchCandidates`, which already takes it as a parameter. It exists today as **three**
   independent TU-local definitions -- `ScanCommandQueue.cpp:50` (`static const`, commented "same
   constant used in FLASHIda.cpp"), `PrecursorSelection.cpp:55` and `FragmentAnalysis.cpp:59` (both
   `inline const`, the last inside an anonymous namespace) -- all `.4`, with nothing keeping them in
   step and no test that would notice if one moved. This decision adds a fourth reader, which is one
   too many: a drift guard accompanies the collapse, per the standing rule that merging N definitions
   into one requires a permanent test asserting the merge held. **The promotion lands in a later push
   than the binding.** It is value-preserving on its own -- all three sites already read `.4`, so the
   collapse moves no golden -- but it touches three translation units the binding does not, and the
   push that changes acquisition geometry is easier to review without a cross-file refactor sitting
   in the same diff.

3. **Overrides are mandatory.** `exploration.metric == remaining_precursor` with an empty `overrides`
   map is **rejected at config load**, at both levels. A metric that never keeps its pre-scans must
   say so in the config, so that the follow-up is guaranteed by the schema rather than by the
   author's habit of writing one.

4. **Level-matched multiplexing is rejected.** `precursor_selection.exploration.metric ==
   remaining_precursor` with `precursor_charges == multiplexed` throws; `characterization.exploration
   .metric == remaining_precursor` with `fragment_charges == multiplexed` throws. Two separate
   messages naming the specific pair. `separate` stays legal in both, and so does the cross-level
   combination -- an MS3 sweep under `precursor_charges: multiplexed` still reads a single contiguous
   stage-1 window, because stage-0 notches change which precursors are fragmented, not where the MS3
   readout sits.

5. **An explicit range wins.** `first_mass`/`last_mass` present in `exploration.overrides` suppress
   the binding rather than being overwritten by it. This is the escape hatch for tuning against real
   hardware without a rebuild, and it is the one place where "automatic" is conditional.

6. **The range becomes observable.** `first_mass` and `last_mass` are added as columns to
   `scan_commands.tsv` for **every** command, not only exploration ones. Without them a bound range
   and a hand-overridden range produce identical rows, and the escape hatch in (5) is invisible. An
   `[EXPL-*]` stdout marker was rejected for this purpose: ADR-0020 verified those do not survive a
   real acquisition, which is the only place the scan time being optimised is observable.

## Consequences

**ADR-0020's `remaining_precursor` half becomes unreachable by config.** Decision 3 means a
remaining-precursor sweep always trips gate #1, so gate #2 (`measuring_ms3_sweep`) is exercised only
by `mass_count`. The gate is not removed -- it remains correct and reachable -- but
`FLASHIda_exploration_test`'s `ms3_measuring_metric_always_reacquires_without_overrides` is
retargeted onto `mass_count` and gains an assertion that the remaining-precursor form now throws.
`method_exploration_ms3_remaining.json` -- whose own description read *"with no overrides -- the
ADR-0020 always-follow-up case"*, i.e. named a config that can no longer load -- gains an
`overrides` block and a description that says the map is mandatory and points gate #2 at
`mass_count`. ADR-0020 carries a pointer to this file at the amended text; do not cite gate #2's
scope without it.

**Two golden movements, of different kinds.** The margin correction in (2) changes `remaining_ratio`,
which is computed on the metric-*independent* path and is column 13 of `scan_results.tsv` -- so it
moves that stream for all **six** golden modes that run MS2 exploration (`exploration_hcd`,
`exploration_etd`, `exploration_followup`, `exploration_ms3`, `exploration_ms3_followup`,
`exploration_multiplexed`), regardless of their metric. The columns in (6) move `scan_commands.tsv`
for all **22** modes. The first needs reading; the second is additive. They are delivered as separate
pushes so the mechanical diff does not bury the numeric one. The binding and the rejections
themselves move nothing -- no golden mode uses `remaining_precursor`.

**Multiplexed remaining-precursor is no longer expressible.** Accepted deliberately. A metric that
measures one charge state's depletion while co-isolating six others asks a question its own geometry
undermines, and saying so at load time is better than scanning 2 Th of a 463 Th isolation in silence.

**The escape hatch is quiet by design.** Decision 5 means "automatic" has an exception that changes
acquisition geometry, and decision 6 is what keeps it from being silent. If the columns are ever
dropped, the exception becomes undetectable from a run folder.

**A known gap in `ScanFactory`, recorded and not fixed.** `BuildFromCommand` writes `ScanRangeMode`
from two branches only -- `DefineMZRange` when both bounds are positive, `DefineFirstMass` when only
`first_mass` is (`ScanFactory.cs:243-250`). There is no `else if (cmd.LastMass > 0)`, so a command
carrying `last_mass > 0` with `first_mass <= 0` sends `LastMass` to the instrument with **no**
`ScanRangeMode` at all: the parameter is present and the mode that would give it meaning is not.
Hence the phrasing in decision 2 -- `ScanFactory` drops a bound pair only when **both** bounds are
non-positive, not whenever one is. The binding is the only producer that can emit a non-positive
`first_mass` beside a positive `last_mass`, and only when `precursor_mz < isolation_width/2`, which
after the margin of decision 2 means a precursor below ~0.4 Th (below ~1.0 Th at MS3, where
`isolation_width` is floored at 2.0). No deconvolved peak group sits there, so the branch is noted
rather than added -- an unreachable case has no test that could show the fix works.

**No ABI or schema change.** `first_mass`/`last_mass` already exist on both sides of the 2048-byte
`ScanCommand`, and no new config key is introduced -- the rules are rejections over existing keys, so
`config_schema_reference.json` does not regenerate and the layout tests are untouched.

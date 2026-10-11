---
title: Exploration — Scoring, Winner Selection and the Kinetic Model
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-10-11
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:79    # ExplorationVariant::precursor_share (ADR-0048)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:84    # ExplorationVariant::measured_only (ADR-0045)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:139   # ExplorationGroup::kinetic_fit / kinetic_max / kinetic_k2 (ADR-0047)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:221   # FeedResultInfo::metric.precursor_share
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:227   # FeedResultInfo::KineticInfo
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:300   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:360   # last_result_deconvolved_ (ADR-0045)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:311         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:351         # measured_only = isTrapAnalyzer(cmd.analyzer)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:369         # feedResultImpl_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:610         # the kinetic / winner fork at group completion
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:617         # KineticModel::fitGompertz at completion
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:666         # [EXPL-ABORT] reason=no-fit | no-winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:749         # post-decision dispatch gate (ADR-0020 + ADR-0047 d.5)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1230        # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1257        # computeMassCount_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1262        # precursorShare_ (the anchor-window share)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1269        # computeRemainingPrecursorScore_ definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/KineticModel.h:105  # KineticModel::precursorShare
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/KineticModel.h:122  # KineticModel::fitGompertz
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/KineticModel.h:131  # KineticModel::modeledMaximum
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:87         # ExplorationMetric enum (KineticModel = 4)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:114        # isMeasuringMetric
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:229        # MSLevelConfig::kinetic_k2
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:1444             # kinetic sweep names exactly one activation
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:1464             # k2 required for the swept activation
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
  - ../fragment-analysis/ms2-matching.md
  - ../fragment-analysis/ms3-matching.md
  - ../../adr/0047-a-sweep-decides-by-the-modeled-maximum-not-by-a-measured-point.md
  - ../../adr/0048-precursor-share-replaces-the-remaining-ratio-and-a-sweep-has-no-baseline.md
---

## `feedResult` flow

`Exploration::feedResult` (decl `Exploration.h:300`, def `Exploration.cpp:311`) is called by the orchestrator whenever a returning MS2/MS3 scan carries an exploration tracking ID. It routes via `variant_tracking_map_` to `{group_id, variant_index}`, reads the variant's **precursor share** from the raw arrays (`precursorShare_`, `Exploration.cpp:1262` → `KineticModel::precursorShare`), deconvolves the spectrum with the per-level `exploration_tolerance_ppm` unless the variant is measured-only, calls `computeExplorationScore_` (`Exploration.cpp:1230`), stores score and share on the variant, marks `received=true`, and tests whether all variants have been received. Once they have, the group is **decided** (below). On MS3 with the `FragmentCount` metric, `MS3FragmentMatcher::calibrateAndScore` runs first (see `ms3-exploration.md`).

## The precursor share (ADR-0048)

Every variant, under every metric, on the trap and on the Orbitrap, carries `ExplorationVariant::precursor_share` (`Exploration.h:79`): Σ raw intensity inside the **anchor's** isolation window (`group.precursor_mz ± isolation_width/2` — at MS3 the stage-1 fragment window) over Σ raw intensity of the **same scan**; `-1.0` when the scan carried nothing. It needs no reference scan, which is why **no sweep acquires a CE-0 baseline any more** (ADR-0029 is superseded; `is_baseline`, `baseline_intensity` and the empty-baseline abort are gone). It is logged on every MS2/MS3 row of `scan_results.tsv` as `precursor_share`, so a dense Orbitrap MS3 run is a share dataset by itself.

## A trap pre-scan is measured, never identified (ADR-0045)

Before scoring, `feedResult` reads the variant's **own command**: `measured_only = isTrapAnalyzer(cmd.analyzer)` (`Exploration.cpp:351`). A measured-only variant is **not deconvolved, not matched and not fed to the ProteoformTracker**; the only thing read from it is its precursor share, so under `remaining_precursor` it scores `computeRemainingPrecursorScore_`, under `kinetic_model` it contributes its share to the fit like any other variant, and under a counting metric it scores the `-1.0` "not scored" sentinel (unreachable from config — `Config::validate` refuses an `IonTrap` override under a counting metric, because with nothing deconvolved `mass_count`/`fragment_count` would score every variant 0 and `ce_min` would always win). The flag is set from the **command**, never from the returning scan (ADR-0042); `last_result_deconvolved_` (`Exploration.h:360`) makes the deconv accessors report nothing after such a feed, so the `scan_results` row does not show the previous variant's masses.

## `computeExplorationScore_` dispatcher

A `switch` at `Exploration.cpp:1230` over `ExplorationMetric` (`Config.h:87`). Every arm but one first calls `computeFragmentMatch_` (which populates match metadata used downstream) and then returns a metric-specific score; higher is better.

## Per-metric scoring

- **`MassCount` — `computeMassCount_` (`Exploration.cpp:1257`)**: counts deconvolved masses in the variant's spectrum (`spec.size()`). A spectral-richness proxy.
- **`RemainingPrecursor` — `computeRemainingPrecursorScore_` (`Exploration.cpp:1269`)**: `share < 0 ? -1.0 : max(0, 1 − |share − remaining_precursor_target|)`. The key kept its name and its value is now a **share** (ADR-0048 d.2): `0.1` means "10 % of the scan's signal is still precursor". A share equal to the target scores `1.0`; both over- and under-depletion lose score; a fully depleted precursor (share 0) is a legitimate reading and competes; an unmeasured variant (share −1, an empty scan) scores `-1.0` and cannot win. The share sums the **anchor's** window only, which is why share-based metrics are refused at load together with `multiplexed` charges at the same level (ADR-0026 d.4, re-grounded by ADR-0044, extended by ADR-0048).
- **`FragmentCount` — inlined**: returns `total_match_count` of the `computeFragmentMatch_` result. For the MS2 fragment-matching integration see [`../fragment-analysis/ms2-matching.md`](../fragment-analysis/ms2-matching.md); on MS3 it pairs with `MS3FragmentMatcher::calibrateAndScore` (`ms3-exploration.md`).
- **`KineticModel` — returns `-1.0` for every pre-scan.** No variant is scored because no variant wins: the group is decided by the fit at completion (below). `computeFragmentMatch_` still runs at MS2, so a kinetic pre-scan is identified like any other MS2 variant.

## Group completion: a winner, or a modeled maximum

Inside `feedResultImpl_`, once all variants have been received, the fork at `Exploration.cpp:610` reads the metric.

**Every metric but `kinetic_model` picks a winner.** A linear scan tracks `best_score` (seeded `-1.0`) and `best_idx` with a strict `>`, so a `-1.0` variant can never win and ties go to the lowest index (lowest CE on the default sweep). `group.winner_index` is recorded, `winner_tracking_id` is set, and `[EXPL-WINNER]` logs the decision. If nothing scored above `-1.0` the group ends with `[EXPL-ABORT] reason=no-winner` (`Exploration.cpp:666`), no follow-up, and is cleaned up normally.

**`kinetic_model` fits and takes the modeled maximum (ADR-0047).** `KineticModel::fitGompertz` (`Exploration.cpp:617`) fits `P(CE) = P₀·exp(−exp((CE − c)/w))` to the (CE, share) points — the study's **lattice search ported verbatim** (c on 0..60/0.5, w on 41 log-spaced widths 0.25–25 NCE, closed-form P₀ clipped to 1.1× the highest share, a ±0.5/×1.3 refinement; ≥ 3 finite shares), not Levenberg-Marquardt, because LM matched the study's pipeline on only 941 of 1080 fits where the lattice matches 1080/1080 (`KineticModel_test`). `KineticModel::modeledMaximum` then runs the fragment-pool recursion `B(k) = e^{−k₂}·B(k−1) + s_k·(1 − e^{−k₂})/k₂` on the fitted rate `s = −dP/dCE` at every integer energy 1..`ce_max`, with `k₂ = kinetic_k2[activation]` from the config (`Config.h:229`; never defaulted), and takes the integer argmax — which **may lie below `ce_min`**, is never clamped, and is flagged when it sits at 1 or `ce_max`. `winner_index` stays −1 and `winner_tracking_id` empty. A fit that fails ends the group with `[EXPL-ABORT] reason=no-fit` and **no follow-up** — no fallback to the authored energy (owner decision, d.7). `[EXPL-MODELED]` prints the whole fit on stdout; `FeedResultInfo::KineticInfo` (`Exploration.h:227`) carries `p0/ce_max_s/width/rss/k2/modeled_ce/modeled_b/fit_points/energy_source` to the `scan_results` row that completes the group (sentinels on every other row). `energy_source` is `modeled | modeled_edge_lower | modeled_edge_upper` here, `measured` on another metric's completing row, `none` on an abort.

## Follow-up dispatch and `overrides`

`MSLevelConfig::overrides` is applied to the sweep's **base config** in `initiate`, so every variant inherits it; the production scan is always built from the **un-overridden** `scans[0]`, so a trap sweep's follow-up is an Orbitrap scan. The dispatch gate at `Exploration.cpp:749` is
`kinetic || !overrides.empty() || (msn_level >= 3 && isMeasuringMetric(metric))`:
the first disjunct is ADR-0047 d.5 (the modeled energy is computed, so there is never a pre-scan to cascade from — the Kinetic Model follows up at **both** levels), the second is "the pre-scans ran degraded", the third is ADR-0020's rule that a measuring MS3 sweep is closed by a follow-up. The follow-up copies the chosen energy (the winner's, or `modeled_ce`) and the reference variant's activation/reaction time (`ref_idx` = the winner, or variant 0 under `kinetic_model`, whose stage-0 context the whole group shares). Otherwise an MS2 group cascades to MS3 from its winner, and an MS3 `FragmentCount` group folds its winner's evidence inline.

## Gotchas

- **Score `-1.0` is a sentinel in two places.** A variant keeps `-1.0` until it is received; a received variant also carries `-1.0` when it could not be scored (empty scan under `remaining_precursor`, trap pre-scan under a counting metric, every pre-scan under `kinetic_model`). Winner selection's seed and strict `>` exclude all of them with no extra flag; a `0.0` there would **win** the group at zero.
- **`remaining_precursor_target` is a share, not a ratio to a reference.** A config written for the pre-ADR-0048 ratio (`0.1` = "10 % of the CE-0 window intensity") now means "10 % of the scan's signal is precursor" — numerically close for a clean isolation, not identical.
- **No per-group timeout.** A dropped variant leaves the group pending indefinitely; `feedResult` never fires the decision path.
- **k₂ is measured for HCD only** (study LOPO 0.0364–0.0390, all-in 0.0388). The MS3 golden's CID value is a placeholder; a dense Orbitrap MS3 run's `precursor_share` column is what an MS3 k₂ will be fitted from. No kinetic sweep has run on hardware.

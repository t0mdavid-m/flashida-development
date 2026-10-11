# 0048. Precursor share replaces the remaining ratio, and a sweep has no baseline

Status: Proposed (grilled 2026-10-11), **not implemented**.
Supersedes: [ADR-0029](0029-a-baseline-belongs-to-its-activation.md) in full, and the Phase-2
decision of 2026-07-06 that gave every metric a baseline.
Amends: [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md) — its
measuring metric `remaining_precursor` now scores the share, not a ratio to a baseline.
[ADR-0026](0026-a-remaining-precursor-sweep-scans-only-the-window-it-reads.md) decision 4, as
kept by ADR-0044 — the single-window argument transfers unchanged to the share, so the
multiplexed rejection stands. [ADR-0045](0045-a-trap-pre-scan-is-measured-never-identified.md)
— "the remaining-precursor ratio is the one metric that can score a trap sweep" becomes "the
precursor share is the one quantity, and the two metrics built on it".
Related: [ADR-0047](0047-a-sweep-decides-by-the-modeled-maximum-not-by-a-measured-point.md)
— the metric that needs this quantity.

## Context

Every sweep today acquires one **baseline** per swept activation: a pre-scan with the swept
axis turned off (CE 0, or reaction time 0.03 ms), whose isolation-window intensity is the
denominator of every sibling's `remaining_ratio` and the reference the `remaining_precursor`
metric scores against (ADR-0029). The baseline is skipped in winner selection, excluded from the
pooled model, and exists under **every** metric, so under `mass_count` and `fragment_count` its
only product is the `remaining_ratio` column.

The offline study (progress report of 2026-09-30, and the corpus glossary's **Precursor share**)
established a quantity that needs no reference: the raw intensity inside the commanded isolation
window divided by the intensity of the whole spectrum **of the same scan**. Both sums carry the
scan's ion supply — fill, transmission, the state the previous scan left the optics in — so the
supply drops out. The CE-0 baseline, by contrast, is a *single noisy sample*: the study measured
the pre-depletion level at 0.5–1.5 of it (p10–p90), uncorrelated with MS1 spray drift, which is
exactly the noise a ratio to it inherits. The Kinetic Model of ADR-0047 is fitted to the share
and its six-point rule excludes CE 0; P₀ is a fitted parameter, not a measurement.

The engine computes the window sum from raw peaks already (`precursorWindowIntensity_`); it has
never computed the whole-spectrum sum.

## Decision

1. **The precursor share replaces the remaining-precursor ratio as the engine's measure of
   depletion.** Share = Σ raw peak intensity inside the anchor isolation window / Σ raw peak
   intensity of all peaks the engine received for that scan, both from the same arrays as
   passed to `processScan`. No instrument TIC header, no bridge change. At MS3 the window is
   the stage-1 fragment window over the MS3 spectrum. It remains a single-window measurement of
   **one charge state**, so ADR-0026 decision 4 and the multiplexed rejections transfer to it
   verbatim.

2. **The `remaining_precursor` metric keeps its name and its target key, and scores the share.**
   `score = max(0, 1 − |share − remaining_precursor_target|)`. The key `remaining_precursor_target`
   is **kept with a changed meaning** (owner's decision): a target of 0.1 now means "one tenth
   of the scan's signal is still precursor", where it used to mean "one tenth of the
   unfragmented window remains". Since an intact precursor reads about four fifths of its own
   spectrum, the two are different points on the curve. Both committed configs that author the
   key keep the value 0.1; `exploration_iontrap`'s golden moves on it.

3. **No sweep acquires a baseline, under any metric or activation.** ADR-0029 is superseded in
   full: no per-activation reference, no synthesized CE-0 or RT-0.03 variant, no
   baseline-coincides-with-grid rule. A grid that is authored to start at CE 0 acquires that
   point as an ordinary pre-scan, and it enters a kinetic fit like any other. A sweep is exactly
   its grid points (plus the follow-up).

4. **`remaining_ratio` is retired from `scan_results.tsv`; `precursor_share` takes its place**,
   filled on every MS2 and MS3 row that has an isolation window — pre-scans, follow-ups and
   ordinary production scans alike, under every metric — and empty on MS1 rows. This is what
   makes a dense Orbitrap MS3 sweep a model-building dataset without re-reading the mzML.

5. **The de-referenced activation rule is retired with the baseline.** There is nothing to
   de-reference. A kinetic sweep with fewer than three finite shares has no fit (ADR-0047
   decision 7); under the other metrics a variant with no signal simply scores what its
   metric gives it.

6. **Validation of the authored reaction-time grid stands.** The throw on a swept
   `reaction_time_min` below the instrument minimum (0.03 ms) was introduced so grid and
   baseline could coincide; it remains as plain instrument-minimum validation, because a grid
   point the instrument rejects is still a config that cannot work (ADR-0007).

## Consequences

- **Scan counts drop by one per swept activation** in every exploration config: the seven
  committed exploration golden modes lose their baseline rows across `scan_commands`,
  `scan_results` and `identification`, and `ida.log`'s per-survey `N targets` count drops
  with them. These are structural golden moves, to be reviewed row by row against the removed
  variant and nothing else.
- **`exploration_iontrap`'s scores and possibly its winner change**: the committed ratios
  1.20 / 0.71 / 0.28 / 0.056 / 0.009 at NCE 20–40 become shares, and the 0.1 target is met at a
  different energy. The engine test `remaining_precursor_target_aware_scoring` and its
  siblings are rewritten on shares, under the planning-stage approval test changes require.
- **The `scan_results` header changes in all 29 modes** (one column removed, one added, plus
  ADR-0047's fit columns); header-only for the 22 non-exploration modes and mechanically
  provable.
- **The glossary** retires Baseline variant, Remaining-precursor ratio and De-referenced
  activation (kept as retired entries so their _Avoid_ lists keep warning) and gains Precursor
  share.
- **`ms3_remaining` has no golden**; its config migrates by meaning only (the key is unchanged).

## Alternatives rejected

- *Keep the baseline under the counting metrics.* A scan whose only product is a column being
  replaced is pure cost, and a half-removed concept is harder to reason about than none.
- *Keep `remaining_ratio` as an always-empty column.* A column nobody fills is a column somebody
  will one day read.
- *Rename the target key to force authors to re-read it.* Offered (the ADR-0014 pattern for a
  changed meaning); the owner chose to keep the key. The change of meaning is therefore recorded
  here and in the glossary, and the two committed configs are the only authored uses.
- *Fit the Gompertz on the ratio to the baseline instead.* Inherits the baseline's noise and
  needs a scan the fit does not use.
- *Denominator from the instrument's TIC header.* Needs a new `ProcessScan` argument for a
  number the engine can compute from what it already receives, and diverges from the study's
  definition under the engine's own centroiding.

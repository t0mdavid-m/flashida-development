# 0056. A quantification group is decided by one test on its aggregate, and the test is authored

Status: Accepted (2026-10-15), **not yet implemented**.
Supersedes: [ADR-0040](0040-quantification-votes-across-charge-states.md) — the directional
majority vote, the dissent exclusion, the `window_snr` tie-break, the ballot floor and the
`consensus_*` columns. What 0040 added to *acquisition* — the authored floor and cap on the
acquisition charge set (`min_charge_states`, `max_charge_states`, `snr_threshold`) and the sibling
exemption — stands untouched; only its decision half is replaced.
Amends: [ADR-0038](0038-quantification-screens-and-identification-is-what-it-buys.md) — its
"a wholly-empty condition is `differential`" rule becomes the **default** of an authored key, its
`fold_change = mean(conditions[0]) / mean(conditions[1])` becomes the **geometric** ratio, and its
"differential means the ratio clears `fold_change_threshold`" becomes one of three authored tests.
The role inversion, the `'Q'`/`'R'` markers, the bare `ms_settings.ms2_quant` slot, the
two-condition rule and the partial-condition rejection all stand.
Related: [ADR-0039](0039-the-quantification-objective-decides-what-a-verdict-buys.md) —
`identify` and `enriched_in` are untouched; they cut on the group verdict exactly as they cut on
the consensus verdict, and `enriched_in` still reads the condition means.
Amended by: [ADR-0057](0057-channel-normalisation-is-authored-and-corrects-only-what-the-test-reads.md) —
the pipeline's run-wide channel-median normalisation, which this ADR could not reproduce live,
enters as authored per-channel factors applied only to what the test reads.

## Context

The offline evaluation of the first iodoTMT hardware runs
(`Measurements/20261014/analysis/itmt_precursor/`, pipeline `run_itmt_precursor.py` +
`core/statistics.py`) decides differential abundance by a **Welch t-test on log2 reporter
intensities**, 3 vs 3 channels, two-sided, with a volcano rule: significant means
`q ≤ 0.05 AND |log2FC| ≥ 0.58` (1.5-fold), where the fold change is `mean(log2 g1) − mean(log2 g2)`.
Per precursor group it keeps only scans with all six channels, normalises every scan to reporter
share (sum = 1), takes the **median** over the scans per channel, and tests once. It has no vote:
a charge state whose window held another population is averaged in and the median is the whole
defence.

The live engine decides on the arithmetic ratio of channel means against a 1.4 threshold, per scan,
and under `precursor_charges: separate` reconciles the charge states of one survey by ADR-0040's
directional majority vote. The two disagree on the hardware in both directions. Over the three
2026-10-08 runs, of the Q scans with all six channels present:

| run | tested | ratio > 1.4 only | both | p ≤ 0.05 only | neither |
|---|---|---|---|---|---|
| singleCharge | 556 | 100 | 135 | 27 | 294 |
| multiplexed | 1459 | 232 | 292 | 47 | 888 |
| separate | 1301 | 295 | 363 | 28 | 615 |

Welch df is 2–4 (median 3.1); the within-condition SD on log2 is ~0.35. At α 0.05 Welch buys
roughly 40 % fewer identification scans than the ratio rule, refusing the scattered ratio-only
hits and admitting a few percent of tight 1.1–1.4-fold species the ratio rule never buys.

The owner's reproducibility study of 2026-10-15 found that exactly this 2–4-df Welch is what makes
the offline hit lists flip between replicates, and that the better offline statistic is a
moderated t with an intensity-trended prior. That statistic needs the population of a whole run
and is unavailable at decision time. **The live test is a purchase screen, not the final
statistic**: its job is to decide which species are worth an identification scan, using the
same arithmetic the offline pipeline applies to the same channels, so that a live purchase and an
offline hit are the same number read at different times.

## Decision

**1. The test is authored.** `quantification.test` is a string enum, unknown values throw:

| `test` | `differential` when |
|---|---|
| `fold_change` **(default)** | the ratio clears `fold_change_threshold` (strict `>`, either direction) — today's behaviour |
| `welch` | two-sided Welch p ≤ `p_value_threshold` |
| `welch_and_fold_change` | both |

The threshold a test does not read is a `[CONFIG-WARN]` when authored non-default (ADR-0039's
`enriched_in` treatment), never a throw, so flipping `test` never invalidates a template.
`p_value_threshold` defaults to **0.05** (the pipeline's `Q_CUTOFF`, applied to raw p: there is no
population to correct over live). `fold_change_threshold` keeps its **1.4** default; the
pipeline-faithful config authors 1.5. The comparison is `p <= threshold`, the ratio gate stays
strict, matching the pipeline's `q <= Q_CUTOFF`.

**2. The statistic is the pipeline's.** `t` on the per-channel **log2** corrected intensities,
Welch–Satterthwaite degrees of freedom, p two-sided from the Student t distribution
(`boost::math::students_t`, already linked by OpenMS). Direction is read from the means, as
`enriched_in` does, so `enriched_in` restricts a two-sided hit and never changes the test. A
Welch test needs **≥ 2 channels per condition** (the pipeline's `min_valid = 2`); fewer under
`welch` or `welch_and_fold_change` is a load error. When both within-condition variances are zero
the statistic is undefined and takes scipy's answer: unequal means p = 0, equal means p = 1,
logged as used, never as a sentinel.

**3. The ratio is geometric, under every test.** `quant_fold_change` becomes
`2^(mean log2 g1 − mean log2 g2)`, the pipeline's `log2_diff_g1_g2` on the linear scale. One
definition of one logged column; the arithmetic ratio of means is retired.

**4. An empty condition is authored.** `quantification.empty_condition: "differential"`
(default; ADR-0038's rule) `| "incomplete"`. Evaluated **before** any test, where the wholly-absent
rule sits today, so `welch` with `differential` buys an absent species without running a test it
could not run, and `fold_change` with `incomplete` stops buying them. Under `incomplete` the
verdict is `incomplete_channels`; no fifth verdict is minted. A *partially* empty condition stays
`incomplete_channels` unconditionally: channels are all-or-nothing, there is no channel dropping.

**5. The group is decided by one test on its aggregate; there is no vote.** A member is **usable**
when every assigned channel is present (the pipeline's `COMPLETE_ONLY`). Usable members are
combined per channel after each is normalised to reporter share (`quantification.scan_normalize`,
default **true**) by `quantification.aggregate` (`sum` | `mean` | `median`, default **`median`**),
and the group verdict is the authored test on those six aggregated channels. No member is excluded
for disagreeing; the identification scan is built from the **highest-`window_snr` usable member**.
Under `single` and `multiplexed` the group has one member and the aggregate is that scan, so
normalisation rescales its channels by a constant and nothing about the ratio or the test changes.

**6. Complete members decide; absence only when none is complete.** If at least one member is
usable, the group is their aggregate and absent-condition members are not usable. If no member is
usable and at least `min_usable_scans` are wholly-absent-against-full, `empty_condition` decides,
buying from the highest-`window_snr` such member under `differential`. Otherwise
`incomplete_channels`. *(Owner, 2026-10-15, at plan review: the floor counts absent members on the
absence path too, so one rule governs both paths. With a floor of 2, one absent member against a
member that returned no reporters is `incomplete_channels`, not `differential`.)*

**7. The floor is its own key.** `quantification.min_usable_scans` (default **1**): a group
decides only when at least that many members are usable. It is independent of
`precursor_selection.min_charge_states`, which is an acquisition floor and no longer doubles as a
decision floor. A value above 1 under `precursor_charges: single` or `multiplexed` throws: such a
group has one member and could never decide. *(Owner, 2026-10-15, at plan review:)* a value
above `precursor_selection.max_charge_states` (when that is > 0) also throws, because no group can
ever hold that many members; a value above `min_charge_states` is a `[CONFIG-WARN]`, because only
species that resolve more charges than admission requires can reach it. The decision-time cap
`min(floor, members)` that ADR-0040 needed is gone with the vote.

**8. The log carries the decision values.** `quant_p_value` joins the per-scan block after
`quant_fold_change` (the scan's own two-sided Welch p, computed whenever ≥ 2 channels per
condition are present, **under every test**: it is a measurement, like `quant_fold_change` under
Welch, and a `fold_change` run then shows what Welch would have bought). The `consensus_*` block is
renamed **`group_*`** and gains the numbers the group was decided on:

| column | row that completes the group |
|---|---|
| `group_verdict` | the group's verdict |
| `group_fold_change` | geometric ratio of the aggregated channels; −1 when none |
| `group_p_value` | Welch p on the aggregated channels; −1 when not computable |
| `group_channels` | the six aggregated channels (shares when normalised) |
| `group_usable` | `usable/members`, e.g. `2/3` |
| `group_charges` | `;`-joined charges of the usable members, no stars |
| `group_id_charge` | charge of the member the identification scan was built from; 0 = nothing bought (written only when the scan is bought; ADR-0040's column wrote the winner's charge unconditionally, so its own "0 = nothing bought" was false for every non-buying group) |

Per-scan rows keep raw channels; only the group row carries the aggregate.

**9. An undecided group still names its identification window.** *(Owner, 2026-10-15, at plan
review.)* Every group whose members returned has a winner: the highest-`window_snr` member of the set
that decided (the usable members, else the absent ones, else every received member). So
`identify: "all"` buys an identification scan for a group that reached `incomplete_channels`, which is
what ADR-0039 defines `all` to mean ("every screened precursor, verdict irrelevant"). Under ADR-0040
such a group had no winner and bought nothing even under `all`, a hole no test pinned.
`quantified` and `differential` still refuse it through the verdict.

## Why

**Pipeline-identical, not merely similar.** Every arithmetic choice above — log2, two-sided
Welch, geometric ratio, `p <= α`, complete scans only, share normalisation, median, no exclusion,
≥ 2 channels — is the pipeline's default. A live purchase and an offline hit computed from the
same `quant_channels` must agree to the last digit, or every disagreement between them is a
debugging session about which of two statistics moved.

**The vote went because `not_differential` stopped meaning dissent.** ADR-0040's ballot key was
(verdict, enriched condition) and `not_differential` was its own bloc, which was right for a ratio:
a 1.1-fold member and a 2.0-fold member of one species *are* evidence of different populations.
Under Welch `not_differential` is a statement about counts, not about direction: a dim charge state
at p 0.3 beside a bright one at p 0.01 in the same direction is not chimeric, and letting two dim
charges outvote one bright one refuses exactly the species the test can see. A direction-only vote
with an aggregate test was considered and declined in favour of the pipeline's shape: the median
absorbs a dissenting window, and the identification scan still goes to the purest window by
`window_snr`. What is given up is explicit chimericity detection; what is gained is that the live
and offline numbers are the same number.

**A key for the empty condition rather than a derived rule.** Deriving it from the test (absent is
`differential` under `fold_change` and `incomplete` under Welch, because a t-test has nothing to
test) would make a change of test silently change what absence buys. More than half of all Q rows
on the hardware `separate` runs have a missing channel, so this is the largest single population
the rule governs; it gets its own word.

**Geometric everywhere rather than a key.** The ratio is a definition, not an experiment
parameter. Two definitions of one logged column, selected by config, is the kind of thing that
costs a reader a day; the four quant goldens move in this change anyway.

**`group_*` rather than keeping `consensus_*`.** The columns no longer report a consensus, and a
name that says "vote" over a block that holds an aggregate is the ADR-0038 class of error — names
that describe the opposite of the mechanism. The cost is real and accepted: the pipeline's
`realtime_loader.py` reads `consensus_verdict` by name and needs a one-line rename, and every run
folder on disk keeps the old header.

**Why Welch at all, given the study.** Because it is what the pipeline runs, and because a
moderated t cannot be run on one scan. The ADR records the study's finding so that nobody reads
the live p as a calibrated statistic: it is a screen, and ADR-0039's `identify` is what spends it.

## Consequences

### Every scan_results golden moves, four of them substantively

A new column fails the header-width check in every one of the 33 log modes; for 29 the diff is one
`quant_p_value` sentinel column and the renamed, sentinel-valued `group_*` headers, mechanically
provable. The four quant modes move on value: the geometric ratio, real `quant_p_value`s
(verified by recomputing Welch offline from the logged channels, not by a constant), and the
aggregate replacing the vote. `quant_separate_chimeric` — whose subject was a recorded dissent —
is retired with the C# assertion on `consensus_agreement`. `phase4_quant.tsv` and the two quant
continuity JSONs recapture on the same push. There is no byte-identical first push to split off.

### A new golden mode on a real Q scan

`method_quant_welch.json` is the pipeline-faithful config (`test: welch_and_fold_change`,
`fold_change_threshold: 1.5`, `scan_normalize: true`, `aggregate: median`,
`precursor_charges: separate`) over `ms1_cytc.txt`, with the MS2 fixture a real iodoTMT Q scan
centroided from the 2026-10-13 `separate` R1 run
(`Measurements/20261014/iTMT/allscans/…separate_ida.mzML`; 4,793 of its 24,351 Q rows carry all
six channels), chosen so all six channels are present and both gates clear, documented in
`spectra/FIXTURES.md`. The existing synthetic `ms2_quant_tmt.txt` stays on the four existing
modes: its ratio 0.51 is `differential` at 1.4 while its p ≈ 0.2 is not, which is the right
fixture to pin that the two tests disagree.

### Config surface, both sides

Five keys join `quantification` on both sides of the bridge (`MethodConfig.cs`, `ToCppJson`,
`BuildFullReferenceConfig` at non-default values, `Config.cpp`'s allowlist and parse) and the
schema reference regenerates: `test`, `p_value_threshold`, `empty_condition`, `scan_normalize`,
`aggregate`, `min_usable_scans`. The validate skill gains the three throws (Welch under a
<2-channel condition, unknown `test`/`empty_condition`/`aggregate`, `min_usable_scans > 1`
without `separate`) and the one warning.

### What this deliberately does not do

- **No multiple-testing correction live.** There is no population at decision time. A run's hit
  list is still the pipeline's to compute; the live p decides purchases.
- **No moderated t, no variance floor.** Both were considered (the study's remedy; the permutation
  FDR's `S0`) and declined because the pipeline's default path uses neither.
- **No chimericity detection.** A dissenting window is absorbed by the median and never named.
  ADR-0040's reasoning about sequencing the interference still holds; the mitigation is now the
  `window_snr` choice of the identification member rather than exclusion.
- **No change to the presence floor.** An assigned channel is present above 1e-3 corrected counts,
  as before. Under log2 a sub-count channel that clears it (an isotope-correction residual of 0.01)
  dominates a geometric mean: {10000, 10000, 0.01} averages to 100, not 6667. The owner kept the floor
  (2026-10-15) because the pipeline treats every logged channel above 0 as present, so the two read
  such a scan identically; a unit test pins the behaviour so it is a known quantity.
- **No pooling of scans as samples.** The degrees of freedom of the logged p are those of one
  3-vs-3 test whatever the group's size, so every group's p is on the same footing.

# 0057. Channel normalisation is authored, and it corrects only what the test reads

Status: Accepted (2026-10-16), implemented 2026-10-16 (OpenMS `27bdc6d37e` engine + `7488132d4c`
tests, FlashIDA `c7ff7bc`).
Amends: [ADR-0056](0056-a-quantification-group-is-decided-by-one-test-on-its-aggregate-and-the-test-is-authored.md) —
adds the one step of the offline pipeline 0056 could not reproduce. Everything 0056 decided stands.

## Context

The offline evaluation (`Measurements/20261014/analysis/itmt_precursor/`,
`tmt/realtime_loader.py` `aggregate_groups`) divides every reporter channel by its **median over
all quantified groups** after aggregation (`MEDIAN_NORMALIZE = True`, `NORM_REFERENCE = "all"`).
That removes run-wide loading and labelling-efficiency differences between the six samples. It
shifts every species' log2 fold change by one constant, and — because the three channels of one
condition no longer carry different offsets — it lowers the within-condition variance the Welch
test reads. ADR-0056 matched the pipeline's shares, aggregate, geometric ratio and test, but not
this step, and the live engine cannot compute it: a median over every species of the run exists
only once the run is over. So the live verdict was decided on unnormalised channels while the
pipeline decides on normalised ones.

## Decision

1. **The factors are authored, never estimated.** `quantification.channel_normalization` is an
   object mapping a channel **name** (the vocabulary `conditions` uses) to a positive divisor.
   The user supplies it from a previous run — the pipeline's `norm_factors` paste in unchanged.
   Only the factors' ratios matter, because a common scale changes neither the geometric fold
   change nor the Welch test. Absent or `{}` means every factor is 1, so no committed config and
   no golden moves.
2. **It corrects only the numbers the test reads.** The factors are applied in `evaluate()`, the
   single channels → verdict function, to the log2 values, the condition means, the fold change
   and the p-value. For a group they therefore apply to the aggregate, after the member shares
   and the per-channel combination — the pipeline's order.
3. **Emptiness is judged on the raw value.** Whether a channel is empty, a member usable, or a
   condition wholly absent never depends on the factors. A factor cannot make a measurement
   appear or disappear.
4. **The log carries raw channels and corrected decisions.** The channel columns of
   `scan_results.tsv` stay the measurement as made; `fold_change`, the p-values and the condition
   means are the corrected values the verdict was decided on. The pipeline reads those channel
   columns and applies its own channel-median normalisation, so logging corrected channels would
   normalise twice and make the offline result depend on the authored factors. The verdict stays
   reproducible from the raw channels plus the method's factors.
5. **Validation, at load.** When authored, the object must name every **assigned** channel; a
   missing one is an error (a silent 1 would compare a corrected channel against an uncorrected
   one inside one condition). An unassigned channel valid for the `labelling` scheme is accepted
   and inert, so the pipeline's six-channel output pastes in whole. A name the scheme does not
   have, or a value that is not finite and positive, is an error. No spread between factors is
   flagged.

## Considered options

- **One ratio offset for the fold change.** Fixes `fold_change` only; within-condition channel
  offsets would still inflate the Welch variance, so `test: welch` stays biased.
- **A log2 offset per channel.** Same mathematics, but not what the pipeline prints.
- **Dividing the channel vector before the empty check.** Simpler code, but a factor of 0.17 turns
  a raw 9e-4 (empty under `kEmptyChannel = 1e-3`) into a measured 5.3e-3, so a group's usable and
  absent sets would depend on the factors.
- **Logging corrected channels**, or raw and corrected side by side. The first double-normalises
  offline; the second adds twelve columns to a 53-column file that the first option makes
  reconstructible anyway.

## Consequences

- The key enters the C# model, `ToCppJson` **and** `BuildFullReferenceConfig` (non-default
  values), and `config_schema_reference.json` is regenerated.
- Coverage is ctest and C# parity only — no golden mode switches it on. The factor's effect on a
  real run is therefore pinned by unit tests, not by a golden.
- The factors are a property of a sample set and its loading, not of the label lot; they are
  distinct from `correction_matrix` (isotope impurity) and are stale the moment the samples are
  re-prepared.

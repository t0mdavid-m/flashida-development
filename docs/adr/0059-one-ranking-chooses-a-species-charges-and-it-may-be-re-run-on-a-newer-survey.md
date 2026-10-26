# 0059. One ranking chooses a species' charges, and it may be re-run on a newer survey

Status: Accepted (2026-10-20). Decisions 1–3 IMPLEMENTED (Push 1, 2026-10-21: OpenMS 4993f8d993, FlashIDA
2bc5ab6 + 048b8b8, parent 24e499a; CI run 39600077058 green). Decisions 4–8 were never implemented and are
**superseded** by [ADR-0060](0060-a-survey-re-plans-waiting-work-and-only-the-drain-commits.md): a newer survey
re-plans the waiting work instead of patching a waiting command's charge, and `reselect_charges` is retired.
Amends: [ADR-0016](0016-co-isolated-charges-are-one-detection.md) /
[ADR-0040](0040-quantification-votes-across-charge-states.md) and the notch policy recorded in
`OpenMS/CLAUDE.md` ("SNR admits and intensity ranks") — the ranking of an acquisition charge set
becomes authored and is shared with the anchor; the SNR gate and the cap stand.
Extends: [ADR-0028](0028-an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion.md) —
an authored charge set still only narrows; the rule that chooses within it is no longer hardcoded
to charge SNR.

## Context

Which window a selected species is isolated in was decided by three unrelated rules: the anchor
is the highest charge-SNR charge (`getRepAbsCharge`), or the best-qscore charge under
`consider_all_charges` — which also reorders species, so one bool decided two things — or, for an
inclusion row naming charges, the highest charge-SNR named charge. The rest of an acquisition
charge set was ranked by intensity. None of them looked at what else the window would transmit.

The 2026-10-13 iodoTMT runs (`Measurements/20261014/iTMT/`, `separate`, `target_depth` 4) measured
it offline: purity = the species' own isotope peaks in the isolation window over every MS1 peak in
it. Persistent per-charge quantification deviations track low purity (r 0.43 below 0.6, ~0.05
above 0.9). The same analysis found a second effect: an MS2 is sent a median 4–6 s after the survey
that selected it, and on the survey nearest the scan the median purity is 0.48 against 0.58–0.60
on the selecting survey — a species is selected where it stands out, so the selecting survey is
the optimistic one.

The engine already computes the ingredients: `FragmentAnalysis::windowSnr` is the species'
intensity at a charge over the rest of the raw MS1 signal in the commanded window — but only after
the command is built, for logging and for quantification's "purest window".

## Decision

1. **Isolation purity** is the PeakGroup's own intensity at a charge over the summed raw MS1
   intensity inside the window the engine would command for that charge (measured extent plus
   the margin), on one named survey. It is `window_snr`'s ingredients as a 0–1 fraction,
   evaluated per candidate charge before the anchor is chosen.
2. **One ranking, `precursor_selection.charge_selection`: `snr | qscore | intensity | purity`,
   default `snr`.** Among the charges that pass the SNR gate (and an authored charge set, which
   only narrows), the first-ranked is the anchor and the first `max_charge_states` are the set.
   Highest wins; ties fall to intensity, then charge. `consider_all_charges` keeps only its
   species-ranking role. Production `etc/method.json` gains `charge_selection: "qscore"`, which
   reproduces its current behaviour exactly (it runs `single`).
3. **`purity` is refused under `precursor_charges: multiplexed`.** All notches share one fill, so
   what decides a multiplexed scan is the combined purity of all its windows, which is not
   defined; ranking notches by their own purity would mean something else under the same name.

*Decisions 4–8 below are superseded by [ADR-0060](0060-a-survey-re-plans-waiting-work-and-only-the-drain-commits.md) and were never implemented.*

4. **`precursor_selection.reselect_charges` (bool, default `false`)** re-runs the ranking on each
   newer processed survey while a command still waits in FLASHIda's queue. It runs on the
   analysis thread when the survey is processed (the drain holds no analysis lock, ADR-0025);
   commands already handed to the instrument are never touched.
5. **Scope:** `R` and `Q` under `single`; `R` only under `separate` — a `separate` `Q` exists to
   measure the charges it was given. Never exploration variants, `multiplexed` sets, follow-ups,
   the bought `R`, or MS3, whose windows do not come from a survey.
6. **A replacement charge must be resolved on both surveys, and nothing is cancelled.** The
   species is found on the newer survey by nominal mass ±1, every matching PeakGroup counting as
   one Precursor (ADR-0036); each candidate charge is measured from the PeakGroup that resolved it.
   With no eligible replacement, or no match at all, the command goes out as decided — a vanished
   charge is as likely an isotope error or a split envelope as a real loss. Under `separate` a
   replacement excludes every charge a sibling has sent or holds.
7. **The parent stays the selecting survey.** Tracking id, precursor id and `parent_tracking_id`
   are unchanged; the charge, m/z, width, scores and the description's `@charge` token are
   rewritten. `scan_commands.tsv` gains the choosing survey's tracking id and the isolation
   purity measured there, written on **every** survey-decided MS2 row whatever the settings (the
   choosing survey equals the parent when nothing was reselected).
8. **What is remembered follows what was isolated.** A `single` `Q`'s quantification-group member
   record is updated, and under an authored charge set the spent `(mass, charge)` is the
   reselected charge. `ida.log` keeps the selecting survey's decision.

## Considered options

- **Purity as a species ranking, a gate, or a window-shaping rule.** Rejected: the question was
  which window a chosen species gets; a gate adds a threshold without evidence, and shaping a
  window around neighbours contradicts "measured, never derived".
- **The offline numerator (theoretical isotope ladder at 10 ppm).** Rejected for the PeakGroup's
  own peaks, which the engine already has; the offline script remains the validation.
- **Purity weighted by intensity, or an intensity floor.** No physical reading; while the fill
  completes under `max_it` the precursor ion count is AGC target × purity whatever the intensity.
  Add a floor only if hardware shows injection times railing.
- **A separate `anchor_charge` key beside the set's intensity ranking.** Two rankings of the same
  charges; collapsed into one at the owner's call, accepting that the default set ranking moves.
- **Repointing the parent to the newer survey.** Would make FLASHDeconv locate on the survey that
  chose the window, but changes what `parent_tracking_id` means for every reader. Kept; decision
  6's both-surveys rule is what keeps FLASHDeconv's locate on the parent sound, since its window
  test (ADR-0046) would otherwise hand the scan to a neighbour or a one-peak rebuild.
- **Cancelling a waiting scan whose charge vanished.** Rejected for the reason in decision 6.
- **An enum `charge_selection_survey: decided | latest`.** A bool was preferred.

## Consequences

- **Goldens move, in a separate push with the diff shown first.** Every `scan_commands` header
  (33 modes) gains two columns. Under the `snr` default the `separate` and `multiplexed` modes may
  change set membership under the cap and scan order (intensity → SNR); `single` modes keep their
  anchors.
- Two keys enter the four sites (C# model, `ToCppJson`, `BuildFullReferenceConfig`,
  `method.schema.json`) and `config_schema_reference.json` is regenerated.
- The live purity is the selecting survey's (or, reselected, the newer one's), never the scan
  time's; it stays optimistic by construction. The logged value on every run is what tells, before
  instrument time is spent, whether `purity` would have chosen differently.
- The first scans of every survey (up to `target_depth`) are already on the instrument and always
  go out on the selecting survey's choice.
- No reselection or purity-ranked acquisition has run on hardware.

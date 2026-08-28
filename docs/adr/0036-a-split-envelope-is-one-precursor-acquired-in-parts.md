# 0036. A split envelope is one Precursor acquired in parts

Status: Accepted (2026-08-27), **amended 2026-08-28**, not yet implemented.
Amends: [ADR-0028](0028-an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion.md) — its
per-survey species guard and the invariant that guard's comment asserts. The rest of 0028 stands:
the set restricts and never extends, the anchor is the highest-SNR named charge, rows union, and
exclusion is `(nominal mass, charge)`-keyed for these species.
Amends: [ADR-0016](0016-co-isolated-charges-are-one-detection.md) — its "multiplexed is one scan"
clause becomes "one scan per PeakGroup of the species", **for rows that name charges only**. The
budget clause is untouched and is in fact what this ADR leans on.
Related: [ADR-0037](0037-a-matched-inclusion-target-is-barred-by-its-score.md), **withdrawn** — it
proposed the across-survey half of "several masses can sit inside one row's tolerance". This ADR is
the within-survey half and stands on its own.

## Context

Inclusion mode is the only mode in which one Precursor reaches selection as **several PeakGroups**.
`SpectralDeconvolution::removeOverlappingPeakGroups_` collapses overlapping features down to the
local SNR maximum, **except** for `isTargeted()` ones, which it passes through untouched. So the
split is structural and systematic rather than incidental: measured on `ms1_cytc.txt`, **22 of the
25 productive surveys** carry two to six PeakGroups inside the target's ±0.247 Da match window, one
of them at `12351.3034 / .3035 / .3032 / .3041 / .3108`. The untargeted goldens carry none.

Everything downstream is written against one PeakGroup per species. The anchor loop reads
`pg.getMzRange(c)` for one `pg`; `peakGroupNotchCandidates` takes one `const PeakGroup&`; and a
per-survey species guard retires a species after the first of its PeakGroups is selected.

The reported failure: a row naming `12;13;14;15;16;17;18`, a survey resolving z12-14 on one PeakGroup
and z15-18 on another 0.1 Da away. The first acquires 12-14; the second is dropped by the per-survey
species guard, a set of **nominal masses** inserted after the first acquisition.

Whether that loses data or merely delays it depends on the run. The winner's charge span varies
survey to survey in the committed fixture — `z8…18`, then `z8…22`, then `z9,10,11` — so a charge
missing from one survey's winner usually arrives in another, and the named set completes without any
of this. But when the split is **systematic** — the same PeakGroup winning every survey with the
same charges missing — no later survey rescues the rest, and they are lost outright. That is the
reported case, and it is the case this ADR exists for.

ADR-0028 introduced the per-survey guard and its comment states *"Only bites under `single`:
separate/multiplexed spend the whole set in one pass anyway."* That is true only when a single
PeakGroup carries the whole envelope, which is exactly what inclusion mode does not guarantee. The
`[CHARGE-SET]` diagnostic compounds it: it reports the missing charges as `not resolved`, because
`getMzRange` is empty **on that PeakGroup** — blaming the instrument for a charge the survey
resolved perfectly well on a sibling.

## Decision

**Two PeakGroups within the mass tolerance are one Precursor, and one Precursor's acquisition may be
completed across several of them within a single survey — for rows that name charges explicitly.**

A Precursor has an **intended charge set** exactly when its inclusion row names charges: the authored
set, intersected with what the PeakGroup resolved. A row carrying `-1` has no intended set, no
sibling is ever admitted for it, and its behaviour is unchanged in every charge mode. Consequences,
each decided rather than inherited:

- **A sibling PeakGroup is admitted only to complete the intended set** — only for members that no
  already-selected PeakGroup of that species resolved. It is never admitted for scoring well, and a
  completed set admits nothing. This is what preserves 0028's deferral: a sibling that resolves only
  charges the first one also resolved is refused, so `single` still walks a named set one charge per
  survey.
- **The budget counts species, but the cap stays hard.** An admitted sibling costs no
  `max_precursors` slot — that is the rule `separate` already relies on (ADR-0016), and the
  alternative is self-contradicting, since the admission predicate has just declared the two
  PeakGroups one species. But a sibling is **not** examined once the cap has ended the candidate
  loop. Headroom is bought with configuration, not with a special case: under
  `precursor_selection.strict_inclusion` a non-target never reaches selection and so never spends a
  slot, and a sibling spends none either, so `max_precursors: 2` leaves a single target's siblings
  reachable for the whole candidate list while the cap remains a cap.
- **A sibling's scan is reduced by what the species already acquired this survey**, so the scans
  **partition** the envelope instead of overlapping. Re-isolating a charge already isolated in the
  same survey halves its ions across two scans; ADR-0016's SNR gate exists for that reason.
- **An admitted sibling is exempt from the score bar.** Completion is what earns it a scan, so a
  score comparison there can only refuse work already justified on other grounds. Siblings rank below
  the winner by construction, so any score test would turn every one of them away.
- **`single` means one anchor per detection, not per species per survey.** A split target legitimately
  yields two anchors. The invariant was never about species; it read that way because a species was
  one PeakGroup.
- **When the cap costs a named charge, the run says so.** If the candidate loop ended on the budget
  while a species in the survey ledger still had a named charge neither acquired nor spent,
  `[CHARGE-SET]` records it. Silent when it costs nothing; the alternative — rejecting
  `max_precursors: 1` at load — would refuse method files that work today and whose behaviour this
  ADR does not change.

## Consequences

**Two PeakGroups within tolerance are one Precursor by fiat.** A genuinely split envelope and two
co-eluting species that close in mass are indistinguishable to the engine — an isolation window must
be measured, and mass is the only thing it can key on. Both are treated as one species. This is
forced, not chosen, and it is why the glossary says so explicitly.

**Unrestricted rows are deliberately excluded, and that is the whole scope decision.** The same split
reaches them, and under `multiplexed` or `separate` a sibling could complete their envelope too. It
is not done, because for a `-1` row acquiring the best-scoring mass is the stated intent, and because
scoping the change to authored rows is what keeps every existing golden byte-identical — making "no
golden moved" the acceptance test for the whole delivery. Extending it later is a scope change with
its own goldens, not a bug fix.

**Merging the PeakGroups into one candidate was rejected**, though it is the tidier model — it keeps
"one target is one scan" and needs no guard changes. It requires the notch **geometry** to cross the
selector-to-queue boundary: `allowed_charges` is a filter and cannot add a charge the selected
PeakGroup has no `getMzRange` for, so both walks of `peakGroupNotchCandidates` would have to widen
together or the "recorded set equals isolated set by construction" invariant reopens.

**Fixing `removeOverlappingPeakGroups_` was rejected outright.** It is shared with the offline
FLASHDeconv tool, which is outside this workspace's change boundary, and it *picks and discards*
rather than merges — applying it to targets would throw away the sibling's charges entirely, which is
the bug rather than the fix.

**No committed golden moves, and none can.** The one authored-charge fixture names `10;13;16`, and
its winning PeakGroup carries all three in 18 of 25 surveys; in the 7 where it does not, the missing
charges had already been spent by earlier surveys. So the fixture never leaves a sibling anything to
complete. The same spectrum against a row naming `12;…;18` is a different story — the winner is
complete in 12 of 25 surveys, the species' PeakGroups collectively carry all seven in 23 of 25, and a
sibling would add something in 11 surveys, recovering 37 charge-observations. Verification therefore
lives in `FLASHIda_ChargeModes_test` beside the existing authored-set cases, on that wide row, and
must assert completion **within a single survey** — because across surveys the fixture's split is
random enough that the set completes either way.

**`[CHARGE-SET]` gains a reason that distinguishes "this PeakGroup did not resolve it, a sibling did"
from "the survey never resolved it", and the first test that asserts on the tag.** Nothing in either
suite asserts on it today, and CI captures engine stdout only from the regression runner, whose
fourteen modes all use unrestricted lists — so the tag is never even emitted there. That is why a
diagnostic naming the wrong cause survived.

**The generalisable lesson.** ADR-0028's guard was correct against the model it was written for and
wrong against the data, and its comment recorded the assumption as though it were an invariant. An
assumption stated confidently in a comment is the hardest kind to notice, because it answers the
question a reader would otherwise ask.

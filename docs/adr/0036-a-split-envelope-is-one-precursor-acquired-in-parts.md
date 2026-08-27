# 0036. A split envelope is one Precursor acquired in parts

Status: Accepted (2026-08-27), **not yet implemented**.
Amends: [ADR-0028](0028-an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion.md) — its
per-survey species guard and the invariant that guard's comment asserts. The rest of 0028 stands:
the set restricts and never extends, the anchor is the highest-SNR named charge, rows union, and
exclusion is `(nominal mass, charge)`-keyed for these species.
Amends: [ADR-0016](0016-co-isolated-charges-are-one-detection.md) — its "multiplexed is one scan"
clause becomes "one scan per PeakGroup of the species". The budget clause is untouched and is in
fact what this ADR leans on.
Related: [ADR-0037](0037-a-matched-inclusion-target-is-barred-by-its-score.md) — the other half of
"several masses can sit inside one row's tolerance". Independently reversible.

## Context

Inclusion mode is the only mode in which one Precursor reaches selection as **several PeakGroups**.
`SpectralDeconvolution::removeOverlappingPeakGroups_` collapses overlapping features down to the
local SNR maximum, **except** for `isTargeted()` ones, which it passes through untouched. Counting
within-tolerance pairs in the committed `AllMass=` lines: **85 across 821 masses** in the inclusion
goldens, **0** in the untargeted ones, and every one of the 85 at the target mass. One survey
carries five PeakGroups at `12351.3034 / .3035 / .3032 / .3041 / .3108`.

Everything downstream is written against one PeakGroup per species. The anchor loop reads
`pg.getMzRange(c)` for one `pg`; `peakGroupNotchCandidates` takes one `const PeakGroup&`; and three
separate guards retire a species after the first of its PeakGroups is selected.

The reported failure: a row naming `12;13;14;15;16;17;18`, a survey resolving z12-14 on one PeakGroup
and z15-18 on another 0.1 Da away. The first acquires 12-14; the second is dropped by the per-survey
species guard, a set of **nominal masses** inserted after the first acquisition. z15-18 are deferred
until the first PeakGroup's charges are spent — three surveys under `single` — and lost outright if
the peak stops eluting before then.

The same defect exists on the unrestricted path, where the second PeakGroup is dropped first by the
`tqscore_exceeding_*` pair and then by the mass-keyed qscore comparison. It is one defect wearing
three guards.

ADR-0028 introduced the per-survey guard and its comment states *"Only bites under `single`:
separate/multiplexed spend the whole set in one pass anyway."* That is true only when a single
PeakGroup carries the whole envelope, which is exactly what inclusion mode does not guarantee. The
`[CHARGE-SET]` diagnostic compounds it: it reports the missing charges as `not resolved`, because
`getMzRange` is empty **on that PeakGroup** — blaming the instrument for a charge the survey
resolved perfectly well on a sibling.

## Decision

**Two PeakGroups within the mass tolerance are one Precursor, and one Precursor's acquisition may be
completed across several of them within a single survey.**

A Precursor has an **intended charge set** — the authored charge set when the row names charges, the
whole signal-bearing envelope when the acquisition mode asks for several charges, the anchor alone
when it does not. Consequences, each decided rather than inherited:

- **A sibling PeakGroup is admitted only to complete the intended set** — only for members that no
  already-selected PeakGroup of that species resolved. It is never admitted for scoring well, and a
  completed set admits nothing. This is what preserves 0028's deferral: a sibling that resolves only
  charges the first one also resolved is refused, so `single` still walks a named set one charge per
  survey.
- **The budget counts species.** An admitted sibling costs no `max_precursors` slot. This is the rule
  `separate` already relies on (ADR-0016) — one species, N scans, one slot — and the alternative is
  self-contradicting: the admission predicate has just declared the two PeakGroups one species.
- **A sibling's scan is reduced by what the species already acquired this survey**, so the scans
  **partition** the envelope instead of overlapping. Re-isolating a charge already isolated in the
  same survey halves its ions across two scans; ADR-0016's SNR gate exists for that reason.
- **An admitted sibling is exempt from every score bar**, this survey's or an earlier survey's.
  Completion is what earns it a scan, so a score comparison there can only refuse work already
  justified on other grounds.
- **`single` means one anchor per detection, not per species per survey.** A split target legitimately
  yields two anchors. The invariant was never about species; it read that way because a species was
  one PeakGroup.

## Consequences

**Two PeakGroups within tolerance are one Precursor by fiat.** A genuinely split envelope and two
co-eluting species that close in mass are indistinguishable to the engine — an isolation window must
be measured, and mass is the only thing it can key on. Both are treated as one species. This is
forced, not chosen, and it is why the glossary says so explicitly.

**Merging the PeakGroups into one candidate was rejected**, though it is the tidier model — it keeps
"one target is one scan" and needs no guard changes. It requires the notch **geometry** to cross the
selector-to-queue boundary: `allowed_charges` is a filter and cannot add a charge the selected
PeakGroup has no `getMzRange` for, so both walks of `peakGroupNotchCandidates` would have to widen
together or the "recorded set equals isolated set by construction" invariant reopens.

**Fixing `removeOverlappingPeakGroups_` was rejected outright.** It is shared with the offline
FLASHDeconv tool, which is outside this workspace's change boundary, and it *picks and discards*
rather than merges — applying it to targets would throw away the sibling's charges entirely, which is
the bug rather than the fix.

**No committed fixture reproduces this.** `ms1_cytc.txt` resolves cytC at 13 charges in one PeakGroup,
and the `inclusion_charge_set_multiplexed` golden co-isolates ten from a single one. The duplicate
PeakGroups in the goldens are weak leftovers, not envelope halves. So an end-to-end golden could not
have caught this defect and cannot verify the fix; verification is a C++ test over synthetic
PeakGroups, against an extraction of the per-candidate admission decision out of the selection loop.

**`[CHARGE-SET]` gains a reason that distinguishes "this PeakGroup did not resolve it, a sibling did"
from "the survey never resolved it", and the first test that asserts on the tag.** Nothing in either
suite asserts on it today, and CI captures engine stdout only from the regression runner, whose
fourteen modes all use unrestricted lists — so the tag is never even emitted there. That is why a
diagnostic naming the wrong cause survived.

**The generalisable lesson.** ADR-0028's guard was correct against the model it was written for and
wrong against the data, and its comment recorded the assumption as though it were an invariant. An
assumption stated confidently in a comment is the hardest kind to notice, because it answers the
question a reader would otherwise ask.

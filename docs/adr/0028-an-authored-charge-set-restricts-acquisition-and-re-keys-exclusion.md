# 0028. An authored charge set restricts acquisition and re-keys exclusion

Status: Accepted (2026-08-25). Amends [ADR-0021](0021-precursor-charges-is-the-only-acquisition-geometry.md)
(scopes its "no replacement" consequence — see below for why this is not a reversal) and
[ADR-0016](0016-co-isolated-charges-are-one-detection.md) (its "differ only in scan count" now holds
over the authored subset). Adds **Authored charge set** to `CONTEXT.md` and un-retires its
**Charge-keyed exclusion** entry in scoped form.

## Context

There was no way to ask FLASHIda to fragment a chosen set of charge states. The whole charge surface
reachable from `method.json` is `deconvolution.min_charge`/`max_charge` (contiguous and global),
`precursor_selection.min_precursor_charge` (a floor), `consider_all_charges` (ranking only), and
`precursor_charges` (`single | separate | multiplexed` — all-or-one). None expresses `{10, 13, 16}`.

The inclusion TSV has had a `charge` column since it was introduced, but it held one integer and its
matcher was mass-blind: `PrecursorSelection.cpp` walked **every** RT-active target row and took the
first whose charge fell inside the observed envelope *without checking that row's mass*, then broke.
So the isolated charge could be supplied by an unrelated target, and which row won depended on
`std::sort`'s unspecified order among equal masses. Nothing caught it, because all 38 committed
configs write `-1`, which hits the `charge < 0` arm on the first row and returns before any of that
matters.

The obvious workaround — repeating the mass on several rows with different charges — does not work
either. One anchor is emitted per species per survey, so the extra rows only made *which* single
charge you got arbitrary.

## Decision

**A charge set named on an inclusion row is a RESTRICTION on the acquisition charge set, and never an
extension of it.** The column takes `10;13;16` as well as a single charge or `-1`; `;` rather than
`,` because the file is tab-separated but a spreadsheet in a comma-decimal locale writes `12351,3`,
and a comma list would be indistinguishable from a mangled number.

Consequences of "restriction", each decided rather than inherited:

- **Membership is still judged, not granted.** The set narrows the candidate pool *before* the SNR
  gate; it does not replace it. A named charge that the deconvolution never resolved is skipped
  outright, because an isolation window must be **measured** (`NotchSelection.h`) and there is
  nothing to measure.
- **The anchor is the highest-SNR named charge**, unconditionally — which overrides
  `consider_all_charges`' charge pick for such species. SNR *orders* the set here; it does not gate
  it, because a matched target's anchor is already exempt from the SNR threshold and an authored
  target should not be lost to one weak survey. The notch side keeps the gate.
- **The score is the anchor's own per-charge qscore**, via the existing `PeakGroup::getAllQscores()`.
  Previously charge and score were bound together and then the charge alone reassigned, so a scan
  could be logged and excluded on the score of a charge it never isolated.
- **Rows naming the same mass union their sets**, restricted to the rows active at the current
  retention time. One row `10;13;16` and three rows `10`/`13`/`16` are therefore the same method,
  while rows whose RT windows differ stay independent. This mirrors what `target_priority_map_`
  already does for priority, and it is what replaces the mass-blind matcher above.
- **Exclusion is re-keyed to `(nominal mass, charge)` for these species only.** Without it `single`
  retires the mass on its first acquisition and the second and third named charges are unreachable.
  Every species without an authored set stays mass-keyed.

**Why this is not a reversal of ADR-0021.** What 0021 removed was acquisition **geometry** being
sourced from an exclusion-**keying** flag: `"separate"` fanned out only when `charge_based_exclusion`
happened to be on, so a mode's behaviour depended on an unrelated switch that defaulted off in every
shipped config. Here geometry comes from `precursor_charges` plus the authored restriction, and the
per-charge map decides nothing about what a scan isolates — only about when a mass stops being
selectable. 0021's other objection, that the flag was developer-only and unused, does not apply to a
column a method actually writes.

**Visibility is a stdout tag, not a log column.** `[CHARGE-SET]` reports what was named, what was
acquired, and why each remaining charge went unacquired — following `[NOTCH-CLAMP]`, whose stated
reason is that a silent drop reads as "we isolated everything you asked for" when we did not. It
distinguishes *deferred* (under `single`, the other named charges are coming on later surveys) from
*refused* (below SNR, below the charge floor, never resolved). Adding a golden column instead would
have moved all 22 modes' `scan_commands.tsv` to carry a field empty in 19 of them.

## Consequences

**Every committed config is byte-identical.** All new behaviour gates on the row naming at least one
charge, and all 38 write `-1`. No existing golden moves; the two new modes
(`inclusion_charge_set`, `inclusion_charge_set_multiplexed`) are new files, not recaptures.

**`single` acquires one named charge per species per survey, not the whole set at once.** Getting all
three takes three surveys, and per-charge exclusion is what delivers them. Non-strict inclusion runs
the selection loop twice per survey, so a call-local guard stops phase 1 taking a second named charge
in the same survey — otherwise `single`'s "one anchor per species per survey" invariant would hold
for every species except the ones a method targeted deliberately.

**A named charge below `min_precursor_charge` is not acquired.** The restriction cannot smuggle a
charge past a floor the config set; that would be the set adding rather than subtracting. The floor
is now also applied to notches for authored species — deliberately not for anyone else, since doing
so unconditionally would move existing goldens for an unrelated reason.

**Termination needs no bookkeeping.** When every named charge is spent, absent, or below the floor,
the filtered candidate set is empty, there is no anchor to pick, and the species is skipped. There is
deliberately no fallback to an unnamed charge.

**The generalisable lesson repeats one this repo has learned twice.** A field can be parsed, stored,
round-tripped and documented while the code that consumes it never checks the thing it was keyed on.
`InclusionTarget::charge` was read, compared and acted upon — against the wrong row. Round-trip tests
prove a value survives; only a behavioural test proves it *decides* anything, which is why CM-07
asserts the three-row and one-row spellings agree rather than asserting the parser produced a set.

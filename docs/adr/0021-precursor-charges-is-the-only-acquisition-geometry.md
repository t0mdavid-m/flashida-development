# 0021. `precursor_charges` is the only source of acquisition geometry

Status: Accepted (2026-08-11). **Supersedes [ADR-0018](0018-charge-keyed-exclusion-is-a-fallback.md)**,
which is now historical: the flag it governed no longer exists. Related:
[ADR-0016](0016-co-isolated-charges-are-one-detection.md).

## Context

ADR-0018 split one question into two knobs and expected them to stay independent:

- `precursor_selection.charge_based_exclusion` — an exclusion-**keying** developer flag. A mass
  fragmented at one charge stays eligible at another on a *later* survey.
- `precursor_selection.precursor_charges` — the acquisition **geometry** of a single scan:
  `single | separate | multiplexed`.

`Config.h` stated the separation explicitly: *"This is an acquisition-geometry question, deliberately
separate from `charge_based_exclusion`, which is an exclusion-KEYING question."*

**The code did not honour it.** `"separate"` was implemented as nothing but a suppressed `break` at
the bottom of a loop over `charges_to_process` — "keep walking the list". That list was built
multi-charge *only* inside `if (config_.targeting().charge_based_exclusion)`; otherwise it held one
element. So `"separate"` fanned out only when the exclusion flag happened to be on, and the flag
defaults to `false` in all 38 committed configs. **`"separate"` was identical to `"single"`
everywhere it was actually used.**

Nothing caught it. The mode's one behavioural test built its config from a fixture with
`charge_based_exclusion: true` — the single combination in which the mode worked. The suite was green
while the feature did nothing, and the `separate_charges` log golden had been captured against the
broken behaviour, so the golden agreed too.

The measured gap on cytC: `multiplexed` acquired 9–10 charge states per species; `separate`, on the
same spectra and a config differing by one word, acquired one.

## Decision

**`precursor_charges` is the sole source of acquisition geometry**, and both non-`single` modes derive
their acquisition charge set from the same `peakGroupNotchCandidates` + `selectNotches` pair in
`NotchSelection.h` — one call, two modes. `multiplexed` co-isolates the set as notches in one scan;
`separate` emits one scan per member. They therefore differ only in scan count, never in which
charges, which is what ADR-0016 asserted and what the MS3 side (`ProteoformTracker::planNextScans`)
already did.

**`charge_based_exclusion` is deleted**, along with its three per-`(nominal_mass, charge)` containers
and their RT eviction. Exclusion is mass-keyed. Asking for several charge states of one species is
now a direct request rather than a side effect of an exclusion flag.

**Removal is announced, not silent.** The key throws a migration message naming `precursor_charges` as
the replacement. That message lives on the **C#** side (`MethodConfigSerializer`'s retired-key hint
table) because C# validates `method.json` first — a migration message existing only in `Config.cpp`
would be unreachable from the normal path. `Config.cpp` carries one too, for hand-written C++ fixtures.

## Consequences

**Cross-survey charge sampling is gone and has no replacement.** `separate` and `multiplexed` are
*within-survey*. Under the old flag a mass fragmented at z17 could be re-selected at z16 on a later
survey; now it is mass-excluded. This is the real cost and it is accepted: the flag was
developer-only, off in every committed config, and its documented behaviour was not what it did.

  > **Scoped 2026-08-25 by [ADR-0028](0028-an-authored-charge-set-restricts-acquisition-and-re-keys-exclusion.md).**
  > "No replacement" now holds only for species that did not ask for one. An inclusion row naming a
  > charge set gets `(nominal mass, charge)` exclusion keys back, so `single` walks that set across
  > successive surveys. The decision above is untouched: geometry still comes from
  > `precursor_charges` plus the authored restriction, never from an exclusion flag, so the defect
  > this ADR removed does not return. Every species without an authored set stays mass-keyed.

**Zero goldens moved for the deletion** — all 38 configs set the flag `false`, so removing it is
value-preserving. The `separate_charges` golden moved for the *fix* (26 → 130 MS2 commands, 33 → 222
identification rows), which landed alongside.

**A whole test file was deleted and its coverage re-landed.** `FLASHIda_ChargeBasedExclusion_test`
(CBE-01…08) went with the flag. Its two mode-relevant sections became `FLASHIda_ChargeModes_test`
CM-03 (`single` acquires one charge per mass per survey) and CM-01 (`separate` fans out) — the latter
now run under a *default* config, which is the assertion that was missing.

**The generalisable lesson**: a mode wired at parse time and asserted only for round-trip is
indistinguishable from a mode that does nothing. `Config_SchemaProjection_test` proved
`precursor_charges` *parsed* into the enum correctly the whole time. Test what a value makes the
engine DO, under a config that sets nothing else unusual — and be suspicious when the only test of a
feature configures an unrelated flag to make it work.

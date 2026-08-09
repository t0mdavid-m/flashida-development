# 0018. Charge-keyed exclusion is a fallback, not a fan-out

Status: Accepted (2026-08-09), **not yet implemented**. Corrects shipped behaviour of
`precursor_selection.charge_based_exclusion`. Related:
[ADR-0016](0016-co-isolated-charges-are-one-detection.md).

## Context

`charge_based_exclusion` is documented in `Config.h` as *"Treat each (mass, charge) as an independent
exclusion target (developer flag)"*, and six of its seven consumers are exclusion keying — the
per-`(nominal_mass, charge)` maps, their RT eviction, and the exclusion tests. The seventh
(`PrecursorSelection.cpp:417`) builds `charges_to_process` from every charge in the PeakGroup's range
that has a qscore, sorted by per-charge qscore descending. That list exists so per-charge exclusion
has something to discriminate between.

**The loop over that list has no `break` after a successful push.** After selecting `(P1, z17)` it
inserts the window's centre m/z into `current_selected_mzs`, but z16 has a different m/z so the
`:596` guard misses; the `charge_based_exclusion` branch deliberately performs no mass-level write
(*"No mass-level writes — the mass is never globally excluded"*, `:627`); and
`tqscore_exceeding_mass_charge_set_` holds only `(mass, z17)`. So z16 and z15 fall through to the
push. One PeakGroup yields several `selected_peak_groups_` entries, each its own `precursor_id`, each
consuming a slot of `max_precursors`.

The practical effect is that `charge_based_exclusion: true` with `max_precursors: 3` spends the
entire survey budget on three charge states of one proteoform, and P2 and P3 are never fragmented.
That was never the intent — the flag is meant to let a mass be sampled at a *different* charge on a
*later* survey, not at several charges on the same one.

Nothing in the test suite distinguishes the two behaviours. All six `FLASHIda_ChargeBasedExclusion_test`
sections drive the full scan sequence through one engine, and under fallback semantics a mass still
accumulates different charges *across* surveys, so the multi-charge assertions (CBE-03, CBE-05) hold
either way. `charge_based_exclusion` is also not one of the 17 log-golden modes and no regression
golden covers it.

## Decision

**`charge_based_exclusion` means per-`(mass, charge)` exclusion keying plus a next-best-unexcluded
fallback.** `charges_to_process` becomes a preference-ordered fallback list rather than a work list:
the loop takes the best charge that is not excluded and stops. It is already sorted by descending
per-charge qscore, so this is "the best charge still available".

**The fan-out is not deleted — it becomes `precursor_selection.precursor_charges: "separate"`.** The
behaviour is occasionally wanted; what was wrong was that it happened as an unnamed side effect of an
exclusion flag. Naming it makes every combination meaningful, and in particular removes the
contradiction that would otherwise exist between the flag implying a fan-out and the mode saying one
charge.

**A scan that co-isolates a charge set records every member it isolated as acquired.** Without this
the next survey's fallback would land on a charge that was already fragmented. This is not a change
to the exclusion mechanism — it still keys on `(mass, charge)`; it records the charges actually
fragmented rather than only the anchor.

## Consequences

**A new test is required, because none of the existing six would fail under the bug.** The
distinguishing assertion is *within* a single survey: a mass appears at most once, regardless of the
flag. That absence is itself the finding — the suite pinned cross-survey behaviour and left the
within-survey question uncovered, which is how the fan-out survived.

**CBE-02 (`flag_on_emits_more_acquisitions_than_flag_off`) is the one section at risk.** It should
still pass — flag-off hard-excludes a mass once it crosses `tqscore_threshold`, while flag-on keeps
acquiring it at fresh charges on later surveys — but the outcome is data-dependent. If it fails, the
fix is to point its config at `"separate"`, which preserves the assertion's meaning rather than
weakening it.

**Zero goldens move**, which is why this lands as its own commit ahead of the multiplexing work. It
is a behaviour change with no golden surface, so it can be verified in isolation rather than tangled
with new code.

**`method_charge_based_exclusion.json` keeps working unchanged** and now expresses the fallback. To
get the old fan-out it must set `precursor_charges: "separate"` explicitly.

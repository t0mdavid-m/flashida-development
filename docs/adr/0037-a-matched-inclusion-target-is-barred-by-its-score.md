# 0037. A matched inclusion target is barred by its score, not by exclusion

Status: Accepted (2026-08-27), **not yet implemented**.
Related: [ADR-0036](0036-a-split-envelope-is-one-precursor-acquired-in-parts.md) — the other half of
"several masses can sit inside one row's tolerance". 0036 governs what happens **within** a survey,
this one what happens **across** surveys. Independently reversible: either can be backed out without
the other.
Amends: the **Precursor** entry in `CONTEXT.md` — its clause "once it has been acquired well enough,
not even that reopens it" stops being true for a species that matched an inclusion row.

## Context

The rule "re-acquire only if this survey resolves the species at least as well as the one that
acquired it" is already implemented, in `mass_qscore_map_`, and already documented in the glossary.
It is also unreachable.

Roughly a hundred lines earlier, the same loop hard-skips any species sitting in
`tqscore_exceeding_mass_rt_map_` or `tqscore_exceeding_mz_rt_map_`. Those two are armed together
whenever an acquisition's score exceeds `tqscore_threshold` — which production sets to **0.1**, against
observed qscores of 0.48 to 0.98. So the first acquisition always arms them, and the score comparison
downstream is never consulted again until the retention-time window expires.

Measured on the flagship inclusion golden: the target is **resolved in 25 of 25 surveys** and
**acquired once**, across a 63 s run sitting entirely inside a 180 s `rt_window`. Nothing expires;
nothing reopens.

`tqscore_threshold` cannot express the intended behaviour. It is a single global number, and keeping
the score comparison reachable for a target scoring 0.98 requires setting it near 1.0 — which
disables the bar for every non-target species in the run. One knob, two behaviours needed.

## Decision

**A species that matched an inclusion row is not subject to the two `tqscore_exceeding_*` bars. Its
re-acquisition is governed by the qscore bar alone: a survey that resolves it better reopens it, a
survey that resolves it worse does not, and the bar only ever rises.**

- Matched targets do not **read** either bar. They still **arm** them, on the **first** acquisition
  only — never refreshed by a re-acquisition.
- Everything else keeps today's behaviour exactly. The maps hold what they hold today, so a
  non-target species sharing the target's nominal bin or its integer-m/z bucket is suppressed for the
  same window it is suppressed for now.
- The bar is a **cross-survey** rule alone. Within a survey, what earns a PeakGroup a scan is
  ADR-0036's intended-set rule, and the bar is the maximum over the survey.

## Consequences

**A re-acquisition is a new Precursor,** with its own `precursor_id`, its own proteoform model, its
own exploration group and its own MS3 budget. Its MS2 evidence does not pool with the earlier
acquisition's. Pooling was considered and rejected: under `single` the anchor is the representative
charge, which can move from survey to survey, so pooling across re-acquisitions would pool MS2 across
charges — the cross-charge pathology the **Precursor** glossary entry lists under _Avoid_, which once
produced physically impossible MS3 charge pairings.

The cost is real and is accepted rather than hidden: several shallow models of one species instead of
one deep one, and an MS3 cascade per model. `separate_charges` is the worked example already in the
tree — ten models per nominal mass, 433 MS3 scans from 32 surveys, every one converging separately on
the same coverage a single model reaches.

**Exempting only the mass bar was rejected.** The m/z bar keys on the integer isolation centre of the
**anchor**, which is stable whenever the anchor charge repeats — usually. Re-acquisition would then
fire only when the representative charge happened to wander into a fresh bucket: intermittent,
irreproducible from the method file, and indistinguishable from a bug in either direction.

**Dropping the arming was rejected too**, and so was refreshing it. Dropping it frees the target's bin
and window neighbours to compete for slots, changing which non-targets get fragmented as a side effect
of a target being present. Refreshing it on every re-acquisition suppresses those neighbours for the
target's whole elution — longer than today. Arming once is the only variant under which non-target
acquisition is unchanged in both directions.

**Authored rows are untouched.** They neither read nor write these maps; they reopen on an unspent
named charge and on nothing else. A survey that resolves a completed named set at 0.99 acquires
nothing. Score governs unrestricted rows, completion governs authored ones, and the two never meet.

**Seeding the bar from outside the run was rejected as a separable change.** `target_mass_qscore_map_`
is already populated in inclusion mode and read only in the in-depth branch, so per-mass scores from
`files.target_logs` are parsed and discarded today. Wiring that up, or adding a sixth column to the
inclusion TSV, would let a method say "don't bother unless you beat 0.85" — worth having, and
orthogonal to this decision.

**Retention-time expiry still reopens everything,** for both kinds of row. This ADR changes what bars
a target inside the window; it does not change the window.

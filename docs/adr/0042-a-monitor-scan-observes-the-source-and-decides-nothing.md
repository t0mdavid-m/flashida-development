# 0042. A monitor scan observes the source and decides nothing

Status: Accepted (2026-09-04)
Related: [ADR-0031](0031-agc-prescans-are-interval-scheduled-only.md) — the failure mode this ADR's
drain-tail guard exists to avoid, and the reason its cadence is untestable end-to-end.
[ADR-0025](0025-the-drain-acquires-no-analysis-lock.md) — the new drain step holds only
`queue_mutex_`. [ADR-0008](0008-separate-scan-identity-channels.md) and
[ADR-0035](0035-ida-log-is-compatible-with-its-consumer-not-its-history.md) — this ADR names which
copy of a scan's *role* is authoritative, which neither of them settled.
[ADR-0007](0007-strict-config-schema-rejection.md) — the new key is strict on both sides.

## Context

During an exploration sweep, FLASHIda stops acquiring MS1s entirely. Two independent mechanisms
cause it, and neither is a bug:

| Path | Where | Behaviour during a sweep |
|---|---|---|
| Step 2 — cycle-time MS1 | `FLASHIda.cpp` | explicitly suppressed by `!exploration_active_` |
| Step 5 — idle survey | `FLASHIda.cpp` | unreachable — the sweep keeps the queue non-empty (MS2 variants at priority 2, MS3 variants at priority 1; the idle MS1 is priority 3) |

And `scheduling.cycle_time.enabled` is `false` in `etc/method.json` **and in all 43 committed test
configs**, so on real hardware Step 5 is the *only* MS1 mechanism there is. An MS3 sweep is
`max_targets × (sweep points + 2)` scans. For its whole duration the operator is blind, and cannot
tell a genuine absence of precursors from a dying spray, a blocked emitter, or a sample that stopped
eluting ten minutes ago.

The ask was an opt-in periodic MS1 during a sweep, purely so the source can be watched. It must be
deconvolved and logged — the numbers are wanted live, in the FLASHIda logs — and it must drive **no
acquisition decision**.

**"Deconvolve but decide nothing" was not a state the code could express.**
`PrecursorSelection::filterAndRank` deconvolves *and* commits acquisition memory in one call, and
`processScan`'s `ms_level == 1` branch fused deconvolution, ranking, command emission, `ida.log`
writing and the FAIMS CV advance into one 139-line straight line. Implementing the feature the
obvious way means an `if (!monitoring)` at every write site — and the failure mode of forgetting one
is silent corruption of acquisition memory, invisible in every log, discovered as an unexplained
change in what a later run selected.

So the seam came first and the feature second.

## Decision

**1. A monitor scan is a first-class kind of scan, not a survey with a flag.** Marker `'M'` at
`scan_description[3]`, `scan_type` `"monitor"` in `scan_commands.tsv`, and a **Monitor scan** entry
in `CONTEXT.md`. All four layers use the same word deliberately: ADR-0014 is the cautionary tale,
where `method_deep.json` and `method_exclusion.json` were each named for the mode they did *not*
set and the goldens inherited the error.

**2. The MS1 branch forks into a deciding arm and an observing arm, with nothing after the fork.**
`runSurveyMS1_()` is the survey arm, extracted verbatim. A side effect added to it in 2027 is
unreachable from a monitor scan *by default*, because control never gets there.

**3. The observing arm is a private `static` member function, and the `static` is the guarantee.**
A static member has no `this`, so inside `observeMonitoringMS1_` the names `selection_`, `queue_`,
`faims_`, `tracker_`, `quant_` and `exploration_` do not resolve — reaching for one is
`error: invalid use of non-static data member`, not a code-review conversation. Its parameter list
*is* its complete capability list, and widening it is a header diff.

A separate translation unit was considered and rejected: it gives the same no-`this` guarantee for
two new files and two `sources.cmake` edits, and its only extra benefit — a small file reviews more
easily than a function inside a 970-line one — is not worth that.

**4. The monitor scan gets its own `Deconvolution` instance.** `deconv_` holds ONE
`SpectralDeconvolution` shared between MS1 and MSn, and `deconvolveMS1` restores the global charge
window on it (the code flags this `// LOAD-BEARING`). Routing a monitor scan through it mid-sweep
resets that window under the running sweep. It self-corrects, because `deconvolveMSn` re-narrows on
every call — but that is an inference across two call sites, and a private instance makes it
impossible instead. `monitor_deconv_` is null unless a level enables the feature, so off costs
nothing, not even a second averagine table.

**5. `ScanRole` makes the wire marker a type with a traits table.** Four hand-written `char`
comparisons in two files plus a six-case `switch` become one decoder carrying
`{marker, log_name, observes, decides}` per role, with a `constexpr` totality `static_assert` — a
new role cannot compile until someone has said whether it decides. An **undecodable** description
resolves as a survey does (both predicates true), which is what keeps every migrated read site
byte-identical; failing closed there would silently stop processing every scan the engine did not
mint.

`log_name` is not a naming opportunity. Those seven strings are `scan_commands.tsv`'s `scan_type`
column. `"recording"` is a poor name for an identification MS2 and must stay.

**6. `PrecursorSelection`'s cross-survey containers group into `SurveyMemory`, with a defaulted
`operator==`.** A monitor scan is defined by what it does not write, so asserting that means
comparing this state across one. Hand-listing the containers in the test would leave the eleventh —
added years from now — silently unchecked. The compiler-generated `==` covers every member, so a
container added *inside* the struct joins the drift-guard the moment it is declared.

Deliberately **not** a transaction. Intra-survey read-after-write is load-bearing:
`authored_acquired_rt_map_` is read back within one survey by ADR-0036 siblings, and
`mass_qscore_map_` / `tqscore_exceeding_mass_rt_map_` by the iteration re-walks. The struct buys the
fingerprint, not deferred writes.

**7. The cadence is wall-clock and per exploration level.**
`precursor_selection.exploration.monitor_ms1` governs MS2 sweeps and
`characterization.exploration.monitor_ms1` governs MS3 sweeps, each
`{ enabled: false, interval_ms: 30000 }`. Per level because the two blocks are authored separately
and their sweeps differ in length by an order of magnitude — enabling it on
`characterization.exploration` alone is the intended production shape.

One **anchor** scan when a level starts sweeping, then one per `interval_ms` while it keeps
sweeping, re-armed when it goes quiet. The anchor is independent of the interval: a sweep shorter
than one interval still gets the one reading that says what the source looked like while it ran.

**8. Priority 0, pushed rather than returned, and it must not reset the survey clock.** Priority 3
is ADR-0031's idle-survey sentinel and five role-blind drain loops break on it; 1 and 2 are the
sweep's own lanes, so a monitor scan would queue behind the sweep it is meant to interrupt. Pushing
rather than returning makes it inherit `registerPending`, the timestamps and the
`scan_commands.tsv` row.

The drain tail's `recordMS1Time()` gains a `roleDecides` conjunct. A monitor scan satisfies
`msn_level == 1 && is_agc == 0` exactly as a survey does, so without it the scan stands in for one —
character-for-character the ADR-0031 bug, where the idle path called `recordAGCTime()` and the
authored AGC interval stopped governing the cadence. Here the victim would be
`scheduling.cycle_time`: monitoring a long sweep would starve the very survey the cycle time exists
to force.

**9. Which copy of a scan's ROLE is authoritative: the engine's.** Two copies exist. The
**observe** gate reads the instrument's echo, because it must run before `resolvePending` and there
is no engine record yet. Every **decision** gate reads `parent_ctx`, the engine's own queued
command, because that copy cannot be truncated or lost by the trailer round trip. ADR-0008 and
ADR-0035 separate the identity channels but never said which copy of the *role* wins; this does.

A practical consequence: a monitor scan that returns *after* its sweep has ended is still recognised
as one. Re-reading `exploration_active_` at return time would make behaviour depend on when the
instrument got round to answering.

**10. No `ida.log` entry.** That file is the record of acquisition *decisions* and the FLASHDeconv
coupling file; a monitor scan makes none and must not couple. Its entry would read `- 0 targets`,
which **both** readers (`IdaLogger::parseFLASHIdaLog` and `PrecursorSelection`'s `target_log_files`
loader) skip by design — so it would carry nothing to any consumer while adding noise to the one
stream with an outside reader. A monitor scan appears in `scan_commands.tsv` and `scan_results.tsv`,
where `rt`, `mass_count` and the four `deconv_*` columns already are the readout.

**11. `ms_settings.ms1` verbatim, no dedicated scan config.** A monitor reading is meant to be
directly comparable with the run's real surveys, and that comparability is the point. At production
settings (240 000 resolution, 4 microscans) each reading costs roughly two seconds, which makes this
a switch-it-on-while-investigating feature rather than one to leave on. `ms_settings`' named-entry
map is the escape hatch if a cheaper monitoring scan is ever wanted, and it would need no change to
the seam.

## What was rejected

**Global scope.** Exploration is not the only thing that starves MS1s, and an unconditional interval
would be simpler. Rejected: it widens the blast radius for a debugging aid, and every other MS1
starvation source already has `scheduling.cycle_time`.

**A fragmentation-scan-count cadence.** Deterministic, and it would have made an end-to-end golden
mode possible — the feature's five-stream output is now never regression-tested. Rejected in favour
of the operator's natural unit. The cost is real and is stated here rather than hidden: like
`agc_interval_seconds`, which all 43 configs pin at `9999999`, the interval branch can only be
reached through a test-only clock accessor.

**A `scheduling` home for the key.** One flat key instead of two. Rejected because the per-level
split buys a real capability — monitor the long MS3 sweeps and leave short MS2 sweeps undisturbed —
and because a key under `scheduling` governing exploration behaviour is the cross-section action
ADR-0014's two-decision-section reshape exists to prevent.

**A `MONITOR` record in `ida.log`.** Structurally skipped by both parsers, and it would give the
monitor scan an instrument scan number — the only hard join into the converted mzML. Rejected: RT
is a sufficient join for reading a spray trace, and `scan_results.tsv` already carries it.

**A `scan_type` column on `scan_results.tsv`.** It would make a monitor row self-describing on the
stream the operator reads. Rejected: it revalues 28 golden files for information derivable by
joining `tracking_id` to `scan_commands.tsv`. Named here as a residual inconsistency rather than
silently dropped.

**A bridge export, a `ScanCommand` field, or a `Reserved` carve.** Unnecessary — the role rides the
existing `scan_description`. `ScanCommand` stays exactly 2048 bytes, the exports stay at 5, and
neither layout test needed an edit.

## Consequences

Feature-off is the state of `etc/method.json` and all 43 committed configs, so **no golden moves**:
`'M'` is a new *value* in an existing column, reachable only when the feature is on.

Two `if`s remain rather than none — the fork itself, and the `roleDecides` conjunct at the drain
tail. Both are single-site and commented with the failure they prevent. The honest claim is
"reduced to two structural choke points", not "eliminated". The ~90 lines above the fork (the lock,
the timestamps, `resolvePending`, the `results_row` prefill) run for both arms and nothing
structural guards them; they are not decision-bearing today.

The residual failure mode is inverted, which is the real win: it is no longer "forgot to suppress a
decision" — silent acquisition-memory corruption — but "forgot to add an observation to a TSV column
the operator is watching".

`FAIMS::currentCV()` was found during this work to be a bare `cv_values_[current_cv_index_]` with no
empty-vector guard. Every production caller happens to write `isEnabled() ? currentCV() : 0.0`, so
nothing is broken today, but the guard lives in the callers rather than in the function. Recorded
here as a known hazard; not changed by this ADR.

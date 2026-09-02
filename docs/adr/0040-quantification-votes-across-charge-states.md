# 0040. Quantification votes across charge states, and the vote picks the identification charge

Status: Accepted (2026-09-02), **not yet implemented**.
Amends: [ADR-0038](0038-quantification-screens-and-identification-is-what-it-buys.md) — its
"rostered once per selected precursor" clause and its screen-then-buy mechanism become
**per-group** rather than per-scan. What is measured, the `'Q'`/`'R'` markers, the four
`scan_results.tsv` columns, the two-condition rule and the wholly-absent verdict all stand.
Amends: [ADR-0016](0016-co-isolated-charges-are-one-detection.md) — the **acquisition charge set**
gains an authored floor and an authored cap. Its budget clause is untouched and is leaned on.
Related: [ADR-0021](0021-precursor-charges-is-the-only-acquisition-geometry.md) — deliberately
**not** amended: geometry keeps exactly one owner, and this ADR adds none.
Related: [ADR-0036](0036-a-split-envelope-is-one-precursor-acquired-in-parts.md) — the sibling
exemption below, and the qscore-bar exemption it is modelled on.
Related: [ADR-0039](0039-the-quantification-objective-decides-what-a-verdict-buys.md) —
`quantification.identify` is untouched; it now cuts on the **consensus** verdict.

## Context

Isobaric quantification measures reporter ions in **one isolation window** per species. A ratio
taken from one window cannot be told apart from a ratio contaminated by a co-isolated species: both
are six numbers, and nothing in the spectrum says which it is. `window_snr` estimates the window's
purity from the MS1, but it is a prediction about *resolved* species, and it cannot see an
unresolved or isobaric contaminant at all.

There is one piece of evidence available in-run, and it costs no new hardware:

> **The reporter ion is charge-independent.** TMT 126–131 is released at the same m/z whatever the
> precursor's charge, so its ratio is a property of *what was in the window*, not of the charge. A
> clean species must therefore give the **same ratio at every charge state**. Two charges
> disagreeing is direct evidence that their windows held different populations.

That asymmetry is the whole basis of this ADR, and it is also its safety argument. Pooling
**reporter** measurements across charge states is sound; pooling **fragments** across them is not,
and `CONTEXT.md` already forbids the latter, having been written against a defect that produced
physically impossible MS3 charge pairings.

Three facts about the code as it stands.

**`separate` + quantification is silently wrong today, not merely unimplemented.**
`precursor_charges: "separate"` already emits one MS2 per charge state
(`PrecursorSelection.cpp:853-880`). With quantification on, roster slot 0 is the `'Q'`
(`FLASHIda.cpp:279`), so each charge produces a `'Q'`, each is measured in isolation, and each
independently buys its own `'R'` (`:445-451`) — N unjoined measurements and N identification scans.
Worse, the join needed to fix it does not exist: `precursor_id` is allocated per selected *entry*
(`FLASHIda.cpp:269`) and `separate` pushes one entry per charge, so the charges of one species carry
**different** `precursor_id`s; and `survey_ledger` (`PrecursorSelection.cpp:310`), which *is*
species-keyed, is a local in `filterAndRank` and dies before any `'Q'` returns.

**`separate`'s scan count is bounded by a wire array it never writes into.**
`adm_ctx.max_notches = MAX_NOTCHES_PER_STAGE` (`PrecursorSelection.cpp:686`) is a literal constant
with no config lookup anywhere in the chain, and that constant is an **ABI dimension** —
`MAX_NOTCHES = 2 * MAX_NOTCHES_PER_STAGE` gives `Notch notches[18]` (`ScanCommand.h:60,65`,
ADR-0019). It describes the instrument's ten MSX windows per fragmentation stage. But `buildMS2`
writes notches **only** under `Multiplexed` (`ScanCommandQueue.cpp:316`), so under `separate` every
scan carries zero notches — the cap survives only because `separate` calls `selectNotches` upstream
to compute its charge *list*. Measured on `separate_charges/scan_commands.tsv.golden.tsv`, grouping
MS2 rows by (parent MS1, rounded `mono_mass`):

| distinct charges acquired | species-surveys | MS2 scans |
|---|---|---|
| 1 | 3 | 3 |
| 3 / 6 / 7 | 1 each | 16 |
| 8 | 2 | 16 |
| **10** | **10** | **100** |
| | 18 | **135** |

**Ten of eighteen species sit at exactly the cap**, and 100 of that mode's 135 MS2 scans come from
species pinned at a number that means nothing for the mode they are in.

**The SNR gate is real but unauthorable, and would stomp anyone who tried.**
`targeting_.snr_threshold = 1.0` (`Config.cpp:1011`, comment: *"hardcoded in original
parseJSONConfig_"*) is the **only** assignment in the engine, it runs **after** every section is
parsed and immediately before `validate()`, and the key appears nowhere in `MethodConfig.cs` or
`config_schema_reference.json`. Adding a JSON key without deleting that line would leave it bound,
documented and inert — the `only_one_condition` failure shape ADR-0038 had to clean up.

## Decision

**The quantification scans of one species form a GROUP; the group votes; and the winning ballot is
the charge the identification scan is acquired at.**

### 1. Geometry keeps one owner

`precursor_charges` decides how many `'Q'` scans a species gets — `single` one, `separate` one per
charge, `multiplexed` one co-isolating the set. **No quantification key influences geometry**, so
ADR-0021 is preserved rather than amended. The aggregation policy *is* configurable, but its key is
`precursor_charges`: `separate` votes, `multiplexed` pools, `single` does neither.

### 2. The group is a second identity, beside `precursor_id` and never replacing it

A group id is minted once per species per survey and carried in an engine-side
`quant_group_by_tracking_` map — the same shape as `precursor_id_by_tracking_`
(`FLASHIda.h:195`), which is **not on the 2048-byte `ScanCommand`**. So this costs **no `Reserved`
bytes, no layout-test change, and no bridge export**.

Two ids because there are genuinely two groupings. `precursor_id` means *"one Precursor, one
proteoform model"*; the group id means *"these scans measure the same reporter population"*.
Collapsing them would drag fragment pooling along with reporter pooling and recreate the impossible
charge pairings `CONTEXT.md` warns about. The `Precursor` term is therefore **unchanged**: under
`separate` the charges remain independent Precursors, and the group spans them.

### 3. The vote is directional; abstentions are not dissent

Each returning `'Q'` is measured exactly as today and writes its own per-scan row unchanged. It
then deposits a **ballot** — its verdict *together with its direction*, i.e. which condition its
`condition_means` say it is enriched in. A member whose verdict is `IncompleteChannels` or
`ExtractionFailed` **abstains**: it is evidence of nothing, not evidence of disagreement.

Voting on the verdict enum alone is insufficient, and the failure is silent. Three charges at fold
changes 2.50 / 2.50 / 0.42 are all `Differential` and vote 3–0 unanimous, while disagreeing about
*which condition is enriched* — precisely the interference this feature exists to detect.

The majority's verdict is the **consensus verdict**. The reported number is an
**intensity-weighted** aggregate over the **agreeing** members only: their `condition_means` are
summed and ratioed, rather than their ratios averaged. The two weightings differ deliberately — the
vote is unweighted because a weak charge's opinion is still evidence of interference, while the
number is weighted because the charge carrying the most ion current is the better-measured one.
That is `selectNotches`' own split: SNR admits, intensity ranks.

### 4. The vote picks the identification charge

The identification charge is drawn from the **agreeing** set — the highest `window_snr` among them,
tie-broken by descending intensity then ascending charge. Acquiring the `'R'` at a dissenting charge
would sequence the interference and attribute the ratio to the wrong molecule, which is worse than
not identifying at all because it is confidently wrong.

This needs no new mechanism. `buildFollowUp` already does `ScanCommand cmd = ctx`
(`ScanCommandQueue.cpp:550`), deliberately carrying *"what makes this a follow-up of that
precursor — the targeting (mono_mass, precursor_mz, isolation_width, charge_state)"*. Choosing the
ID charge is choosing **which member's stored `ScanCommand` is passed as `ctx`**.

⚠ **The `'R'` must also inherit the WINNER's `precursor_id`, not the returning scan's.** The group
completes when the last `'Q'` returns, and that may be a dissenter. Building from the winner's
command while stamping the dissenter's `precursor_id` would fragment one charge and file the
identification — and every MS3 target downstream of it — under another charge's proteoform model.

`window_snr` is the right comparator here because it is **scale-free**: it is
`signal / max(noise, 1e-3 * signal)` over the commanded window (`FragmentAnalysis.cpp:1218-1233`)
with `precursor_intensity = pg.getChargeIntensity(charge)` (`ScanCommandQueue.cpp:360`), i.e. a
per-charge purity *ratio*, comparable across charge states.

⚠ **It saturates at exactly `1000.0`.** With `noise ≈ 0` the denominator is `1e-3 × signal`, so
every clean window scores the identical value. Ties at the ceiling are the **expected** case for a
well-separated species, not a corner case, so the full order — `window_snr` → intensity → charge —
decides most selections in practice.

### 5. No new verdict vocabulary; a tie is broken by `window_snr`

The consensus verdict draws from the **existing four values**. Every case lands:

| situation | consensus verdict |
|---|---|
| majority among directional ballots | `differential` (with the winning direction) or `not_differential` |
| dissent short of a tie | the majority's, with the dissent reported as an agreement ratio |
| exact tie (1–1, 1–1–1) | the bloc holding the **highest-`window_snr` ballot** wins |
| fewer usable ballots than the floor | `incomplete_channels` — *"no honest ratio exists"* |
| nothing usable returned | `extraction_failed` |

⚠️ **The ballot floor is `min(min_charge_states, group size)`, not `min_charge_states` flat.**
`min_charge_states` is a requirement on the acquisition charge **set** and is enforced once, at MS1
admission; this is its decision-time half — *"too many members abstained to trust the vote"* — and
the two are the same number only under `separate`. `multiplexed` co-isolates the whole set into
**one** measurement, so an uncapped floor rejects its single ballot and that mode can never produce
a result at all. Shipped uncapped for one CI run and measured as `incomplete_channels | 0/1` on
every row of `quant_multiplexed`, directly contradicting this ADR's own mode table above. A geometry
that can only ever produce one measurement satisfies the floor with one. Pinned by
`quant_multiplexed_group_of_one_still_reaches_a_consensus`.

There is **no `chimeric` verdict**. Chimericity is handled by the vote, which is what a vote is for;
a species whose members disagreed still has a majority result, and that result is what it gets.
Folding "too few ballots" into `incomplete_channels` follows ADR-0039's own reasoning that the
failure values *"differ only in why"*, and the per-scan rows already report each why.

`quantification.identify` therefore needs **no change**: it cuts on the consensus verdict, and the
under-ballot cases fall below `differential` and `quantified` on their own.

⚠ Breaking the tie by `window_snr` rather than by intensity makes the tie-breaking ballot **the ID
charge, by construction** — the highest-`window_snr` ballot among the tied members is, once its bloc
wins, also the highest-`window_snr` member of the winning bloc. One computation, two uses, and no
way for the two to name different charges. An intensity-based tiebreak could.

### 6. Three GENERAL keys, all in `precursor_selection`

| key | default | effect |
|---|---|---|
| `min_charge_states` | `1` | a species whose acquisition charge set is smaller is **not selected**; refused in `admitCandidate`, so it costs no `max_precursors` slot |
| `max_charge_states` | `0` = all | caps the set, keeping the most intense — the missing bound on `separate` |
| `snr_threshold` | `1.0` | makes the existing gate authorable; **`Config.cpp:1011` must be deleted in the same commit** |

They are general rather than quantification-scoped because `separate` ships over-firing today
whether or not anyone enables quantification, and `snr_threshold` is a hardcoded-and-stomped value
regardless. The defaults are all inert, so **no golden moves from their existence** — the quant
configs author `min_charge_states: 2` explicitly.

`min_charge_states` is inert under `single` (the set is always size 1) and meaningful under both
other modes, with one definition covering all three: **the minimum size of a species' acquisition
charge set for that species to be quantified at all.** Under `separate` that yields ballots; under
`multiplexed` it yields a richer single fill. `min > max` is unsatisfiable and is a load error.

⚠ **A sibling is exempt from `min_charge_states`.** ADR-0036 reduces a sibling's acquisition set by
what the species already isolated, so a sibling supplying the last charge of a split envelope
presents a set of size 1 and the floor would refuse exactly the charge ADR-0036 exists to recover.
The exemption is modelled on the one already beside it: *"the sibling is exempt from the qscore bar
entirely, because its admission was earned by completing the intended set rather than by scoring
well"* (`CandidateAdmission.h:165-168`). The floor judges whether a species is worth screening, and
that judgement was made when its first PeakGroup passed.

### 7. Five `consensus_*` columns, on the completing scan's row

Empty on every other row, exactly as ADR-0038's four `quant_*` columns are empty off a `'Q'`.

| column | content |
|---|---|
| `consensus_verdict` | `differential` / `not_differential` / `incomplete_channels` / `extraction_failed` |
| `consensus_fold_change` | intensity-weighted over agreeing members; `-1` sentinel rules inherited |
| `consensus_agreement` | winning ballots / total ballots, e.g. `2/3` |
| `consensus_charges` | the balloting charges, winners marked |
| `consensus_id_charge` | the charge the `'R'` was acquired at; `0` if nothing was bought |

Named `consensus_*` and not `quant_*` so they cannot be misread as per-scan: the row they sit on is
whichever `'Q'` happened to return last, which is **not** necessarily the row the decision was
about. `consensus_id_charge` is carried explicitly so a reader never has to infer that.

### 8. Completion is all-received, with no timeout

The group decides when every member has returned — `all_of(members, received)`, mirroring
`Exploration.cpp:643-645`. There is deliberately **no escape hatch**, and the reasons the obvious
ones were declined are worth recording: `scheduling.scan_timeout` is `enabled: false` in **41 of 41**
committed configs (`Config.h:233`), so reusing it would be a bound that is off everywhere including
production; and a wall-clock deadline would make the quant golden nondeterministic, in a suite that
pins `agc_interval_seconds: 9999999` in all 41 configs precisely to stay wall-clock independent.

The accepted cost: a `'Q'` the instrument never returns leaves its species screened but never
identified, and leaks the group — the same way an exploration group leaks today.

## Why

**The mechanism already existed; what was missing was a join and a decision point.** Fan-out, SNR
gating, intensity ranking, per-charge geometry and the follow-up buy are all shipped. This ADR adds
one engine-side map and moves one decision from per-scan to per-group. That is also why `single` is
byte-identical: a group of one completes on its first return, and the consensus of one measurement
is that measurement.

**Reporters pool where fragments do not, and that is a physical fact rather than a convention.** It
is what makes cross-charge agreement a valid purity test, and simultaneously what makes it safe to
pool across charges here while `CONTEXT.md` forbids pooling fragment evidence across them. Any
future change that starts pooling *fragments* across a group's members is a different decision and
must be argued separately.

**Agreement is better evidence than `window_snr`, so `window_snr` is used only where agreement
cannot speak.** Agreement is measured on the returning spectra; `window_snr` is predicted from the
MS1 about resolved species. So agreement selects the *pool* of candidate ID charges, and
`window_snr` picks within it and breaks ties — each used where it is the stronger signal.

**The count bounds are general because the defect is general.** Putting `max_charge_states` in
`quantification` would have required arguing that a restricting filter is not a second source of
geometry — winnable, but beside the point, since `separate` needs the bound anyway. Placing both in
`precursor_selection` costs a quantification author one extra section and buys a fix that stands on
its own.

## Consequences

### The feature is switched on from `precursor_selection`, and `quantification` gains no key

`precursor_charges: "separate"` + `min_charge_states: 2` is the whole activation. That is surprising
enough to be the first thing this ADR should be cited for. It follows from geometry having one owner
(ADR-0021) and from the vote needing no policy knob once chimericity is handled by the vote itself.

### Goldens: 125 recaptured, 15 new, log goldens only

The five new columns change the `scan_results.tsv` header width, and
`GoldenListCanonicalizer.PermuteColumnsToReference` fails closed on that — so **all 25 modes × 5
streams** recapture. For 24 the diff is constant empty columns and is mechanically provable. **The
existing `quant` mode changes in content**, because its group-of-one completes and its consensus
columns are populated.

Three new modes: `quant_separate`, `quant_separate_chimeric`, `quant_multiplexed`.

⚠ **Log goldens only — deliberately not the regression TSVs.** `compare_golden.py` runs at
`REL_TOL=1e-4`, ten times tighter than the C# comparer and with roughly 2.6× headroom over the worst
observed cross-build drift. A consensus fold change is a ratio of sums across several charges, so it
**compounds** per-charge float drift rather than averaging it away — the tightest tolerance in the
system applied to the most drift-prone number in the feature.

⚠ **The tie case belongs in a C++ ctest, not a golden**, because `window_snr` saturates at exactly
`1000.0` and a golden whose outcome turns on which of two ceiling-tied values wins will flip on
build jitter. That is the `inclusion_ms3_cytc` knife-edge failure shape.

### The dissent path is testable, and needs no new fixture

`ContinuityTestHarness.PushScanAndDrainFull` already selects an MS2 response per command via
`ms2CeMap`, keyed on rounded stage-0 collision energy with **no fallback** — an unmapped key throws
(`ContinuityTestHarness.cs:260-273`). A charge-keyed `ms2ChargeMap` is a structural copy, and
`cmd.Stages[0].ChargeState` is already extracted two lines above the dispatch. It is described as
the *"C# twin of the C++ `runInterleaved ms2_ce_map`"*, so it must be added to **both** harnesses
with the drift guard the test-harness packet requires.

The three committed TMT fixtures already carry opposing directions, so a 2–1 chimeric case is
`ms2_quant_tmt.txt` on two charges and `ms2_quant_tmt_treated_absent.txt` on the third.

### Duty cycle multiplies, and the budget does not

ADR-0016's budget clause holds: a species costs one `max_precursors` slot in every mode. But
`separate` spends N `'Q'` scans plus one bought `'R'` on that one slot. `max_charge_states` is the
control, and on the measured `separate_charges` distribution a cap of 3 would take that mode from
135 MS2 to roughly 40.

### What this deliberately does not fix

- **A group that loses a member never decides.** See decision 8. The `pending_scan_map_` leak behind
  it is pre-existing and independent: `cleanupExpired()` walks only the four priority queues despite
  its declaration saying otherwise (`ScanCommandQueue.h:157` vs `.cpp:682`).
- **`multiplexed` still cannot detect chimericity.** One blended fill yields one measurement, so the
  group has one ballot and `consensus_agreement` is `1/1`. `min_charge_states` there buys richer
  signal, not a purity check. This is inherent, not an omission.
- **Agreement is not proof of purity.** Charges agree whenever their windows hold the same
  population — including a co-eluting contaminant carrying the *same* reporter ratio, which is
  entirely possible within one sample. Agreement excludes *differential* interference only.
- **The consensus still does not join to its proteoform in one file.** ADR-0039's three-file join is
  unchanged; `consensus_id_charge` narrows it but does not close it.
- **No verdict-aware exclusion.** A `NotDifferential` species is still re-screened when its RT window
  lapses — now at N× the scan cost. ADR-0039 already named this as the change that would recover
  duty cycle rather than redirect it, and this ADR makes it more valuable, not less.

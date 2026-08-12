# 0023. Exhaustive characterization targets unassigned masses

Status: Accepted (2026-08-12). Extends
[ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) (`characterization.mode` is the
single MS3 switch) with a fourth value. Related:
[ADR-0002](0002-proteoform-tracker-dispatch-authority.md),
[ADR-0003](0003-two-stage-ms3-parameter-sourcing.md),
[ADR-0005](0005-ms3-target-is-a-containing-fragment.md),
ADR-0022 (escalation ladder — cited by the code, file not present in this tree at the time of
writing; see *Open items*).

> Numbering note: this is **0023**, not 0022. `Config.h:294` and `ProteoformTracker.h:208/229` cite
> ADR-0022 for the escalation ladder, but no `0022-*.md` exists here. 0022 is treated as taken.

## Context

Every MS3 target the engine has ever dispatched is a **mapped fragment** — a deconvolved MS2 mass
that matched a theoretical fragment of the winning proteoform. `ProteoformTracker::planNextScans`
walks `ProteoformModel::fragments`, a map keyed by `FragmentKey{ion_type, ion_index}`, and both
objectives select within it: `ambiguity` picks fragments that *contain* an unlocalized modification
(ADR-0005), `coverage` picks fragments whose interior adds an unwitnessed backbone bond.

That leaves the majority of the measured signal unused. In the reference cytochrome-C run
(`FlashIDA/test-data/golden/logs/ms3_cytc`), MS2 scan `T4` deconvolves **117 masses** and maps
**44**; the run's 25 MS2 scans average **109.6** deconvolved masses each. The 73 unassigned masses of
`T4` are logged into `scan_results.tsv`'s `deconv_masses` and then dropped.

They are not noise. `T4`'s **most intense** deconvolved mass, 7177.56 Da, is unassigned — and appears
in another scan's identification row as `b61` of the co-isolated 12307 Da proteoform. Two of `T4`'s
top three masses by intensity are unassigned, five of the top ten, and 73 of 117 overall. An
unassigned mass is routinely a real fragment of a *different* species, or of the winner under a
modification the hypothesis did not model.

The raw material is already retained: `feedScan` builds a `PeakRecord` — mono mass, representative
charge, isolation m/z and width, stage-1 scores, and the full `by_charge` envelope — for **every**
deconvolved PeakGroup, matched or not (`ProteoformTracker.cpp:271-299`), and since the escalation
ladder those staged scans live for the whole Precursor. Nothing reads the unmapped ones.

What blocks targeting them is not data but **identity**. A mapped fragment carries an ion type and
index, and those two fields do real work: they compose the scan-description payload
(`…@{charge}{ion_type}{index}`), they render `identification.tsv`'s `ms2_precursor_ion` (`b80`), and
`MS3FragmentMatcher::extractSubsequence` uses them to cut the parent's subsequence out of the
proteoform so MS3 sub-fragments can be projected back to the full-protein frame. An unassigned mass
has neither.

## Decision

**A fourth `characterization.mode` value, `exhaustive`, whose target pool is every deconvolved mass
of the winner MS2 scan rather than only the mapped ones.** A mass that maps is targeted, acquired and
matched exactly as today; a mass that does not is targeted and acquired identically, and its MS3 is
logged rather than matched.

1. **A mode value, not an orthogonal pool switch.** `exhaustive` replaces the objective ordering with
   one flat ranking; it does not layer a wider pool underneath `ambiguity`/`coverage`. `mode` keeps
   its ADR-0013 meaning — the single MS3 switch, whose on-values are the objectives.

2. **`exhaustive` is not a superset of `ambiguity`.** The round-robin over ambiguous modifications
   and the coverage marginal-skip do not run. A faint but *unique* containing fragment can lose its
   slot to any brighter unassigned mass.

3. **Pool = the winner MS2 scan's deconvolved masses.** One scan, one pool. When an escalation rung
   wins the identification, the pool is that rung's scan; if the rung was ETD, every mass in it is
   MS3-incapable (`isMs3CapableActivation` is `HCD || CID`, because an MS3's `stage[0]` replays the
   MS2 that made the fragment — ADR-0003), so the mode plans nothing for that Precursor.

4. **Ranking is intensity, descending, with no tiebreak.** The same rule as every other target-ranking
   site in the engine, for ADR-0003's reason: more fragment ion means more MS3 precursor. It needs no
   conversion between the two halves of the pool — `FragmentObservation::intensity` is assigned
   straight from `PeakRecord::intensity` (`ProteoformTracker.cpp:1233`), so a mapped fragment ranks on
   the identical number it ranks on today.

5. **An unassigned target is labelled `ion_type = 'u'`, `ion_index = 0`**, and `MS3FragmentMatcher`
   gains a **positive check for a known ion class**. The index-0 exit in `extractSubsequence`
   (`:274`) already declines to project, but `getMS3IonTypes`' `default:` silently returns the
   *suffix* ion set, and `extractSubsequence`'s `else` is likewise the suffix branch — so any sentinel
   carrying a non-zero index would fabricate a suffix frame of that length and match against it,
   producing confident wrong identifications instead of nothing. The guard makes the refusal explicit
   rather than a consequence of two unrelated conditions both holding.

   *Amended 2026-08-12, two clauses:*

   **(5a) The refusal keys on the ion CLASS and never on the index.** `ion_type` and `ion_index` are
   two independent fields that travel independently, and nothing in the engine ties `'u'` to `0`. An
   index-only guard therefore leaves a `'u'` arriving with a plausible index free to cut a real
   suffix out of the proteoform and match against it — precisely the failure the positive check
   exists to prevent, reintroduced by the guard meant to stop it. So *every* `MS3FragmentMatcher`
   function taking an ion type refuses an unknown class on its first line, ahead of any index or
   range test, and the refusal is pinned by an index sweep over `0..region_length` rather than by a
   single index-0 case.

   **(5b) `'u'` is an in-engine sentinel that never reaches the wire** (amendment D-f). The
   scan-description payload is built by `ScanCommandQueue::buildMS3`, whose ion suffix is guarded by
   `ion_type != '\0' && frag_index > 0` (`:479`). An unassigned target's index is `0`, so it takes
   the **no-ion branch** (`:485-490`) and is commanded as `{id}R{mass}k@{charge}` — on the instrument
   indistinguishable from any other ion-less isolation. The wire format is not changed by this ADR.

6. **Unassigned MS3 results are logged by the existing streams, joined on `tracking_id`.**
   `scan_commands.tsv` records what was isolated and why it looked worth isolating — `mono_mass`,
   `charge`, `precursor_mz`, `isolation_width`, `qscore`, `snr`, `precursor_intensity`, plus an
   **empty `ion_type` and `ion_index = 0`** in columns 26–27. *(Corrected 2026-08-12: this said
   `ion_type = u`. It cannot be — those two columns are not read off the command struct at all;
   `IdaLogger.cpp:304-325` re-parses them back out of `scan_description`, starting from `""`/`0`, and
   decision 5b's no-ion branch writes no ion characters for the logger to find. `u` in that column
   would mean the sentinel had reached the wire.)* `scan_results.tsv` records what came back —
   `deconv_masses` / `_qscores` / `_charges` / `_intensities`. **No new stream and no blank rows in
   `identification.tsv`**: a row there continues to mean *this scan identified something*.

7. **Dispatch memory is per-Precursor and nominal-mass keyed.** `ProteoformModel` gains the set of
   already-dispatched nominal masses (`round(mono_mass × 0.999497)` — the key exclusion and Precursor
   identity already use), consulted in `exhaustive` only. Dispatched-but-never-returned counts as
   done, for ADR-0022's reason for placing `next_rung` on the model: a step with no record that it
   was tried is re-dispatched forever.

8. **One shot per Precursor.** `max_targets` is the whole per-Precursor allowance, not a batch width;
   the pool is not drained across successive plans. Truncation is reported on the existing
   `[MS3-PLAN]` marker, extended to carry the figure that actually matters — commands, not targets:
   `pool=105 targets=20 truncated=85 variants=5 commands≈100`. *(Amended by D-e: those figures are
   emitted, but on **two** markers rather than one. `variants`/`commands` cannot be printed where
   `pool`/`targets`/`truncated` are, because `buildVariants_` is private to `Exploration` and the
   tracker holds no reference to it.)*

9. **Exactly two pool filters**: `characterization.min_target_mass` (new, default `0` = off) and
   `characterization.min_fragment_charge` (existing, already enforced at `Exploration.cpp:950`).
   No precursor-identity skip and no above-precursor-mass skip.

10. **Identification is still required.** `no_plan("unidentified_precursor")` stands (ADR-0002).
    Division of labour: an unidentified Precursor is the escalation ladder's problem — change the
    chemistry at MS2 — and an identified one is this mode's.

11. **An unassigned target's MS3 CE sweep is scored by `remaining_precursor`, whatever the config
    asked for.** `fragment_count` is a *reading* metric in ADR-0020's sense — it scores a variant by
    identifying its fragments — and decision 5's class guard makes the matcher refuse an unassigned
    target outright. Combining the two gives the worst available outcome, and it is silent: every
    variant scores `0`, so the winner is whichever the tie-break reaches first, and because a reading
    metric earns no ADR-0020 close-out, the sweep also ends with nothing acquired at that winning CE.
    Five scans, nothing learned — the same shape as the defect ADR-0020 was written to fix, arriving
    from the other direction.

    `remaining_precursor` scores from isolation-window intensity alone, so it needs no proteoform and
    no ion frame. It is also a *measuring* metric, so `isMeasuringMetric` is already true and the
    ADR-0020 close-out production scan is dispatched by existing code with no further change. The
    reference it scores against always exists: a CE-0 baseline is prepended to every exploration
    group regardless of metric.

    **The override is gated `msn_level >= 3`, and that gate is load-bearing.**
    `Exploration::initiate`'s `ion_type` parameter defaults to `'\0'`, which is not a known ion class,
    and the MS2 call site passes nothing — so an ungated class test would read "unknown class" on
    every MS2 exploration group and force `remaining_precursor` onto all of them, moving the
    `exploration_hcd`, `exploration_etd`, `exploration_followup` and `exploration_multiplexed`
    goldens. The override is per-target, not per-mode: a *mapped* target in `exhaustive` keeps the
    configured metric, because it has the ion frame a reading metric needs.

## Amendments (2026-08-12)

Seven decisions the implementation had to make that the Decision section above does not state. They
are recorded here because each one resolves an ambiguity in a direction that is not the obvious one,
and the obvious one is wrong.

| # | Amendment | Why this direction |
|---|---|---|
| **D-a** | `CharacterizationObjective` gains an `Exhaustive` enumerator, assigned by the **mode parse**, not derived later. | `characterization().mode` has **zero engine read sites**. Every reference to it outside `Config.cpp` is none; inside `Config.cpp` it is only parsed, projected (`:871`), and quoted in error text. The engine branches on `.objective` (`ProteoformTracker.cpp:421` in `objectiveUnmet`, `:524` in `planNextScans`), which had two values and defaulted to `Ambiguity`. A mode-only addition would therefore ship a fourth mode that is byte-identical to `ambiguity` — accepted, green, and inert. |
| **D-b** | The winner scan's MS3-capability gate is `!activation_type.empty() && !isMs3CapableActivation(...)` — an empty activation is treated as **capable**. | Mirrors the engine's only existing capability test (`ProteoformTracker.cpp:1032-1033`), whose comment records the reason at length: `""` is not "ETD", it is "no activation recorded", and it reaches that code from every hand-built C++ fixture and from any scan config omitting the key. Failing closed on `""` returns zero MS3 targets for all of them — a quieter failure than the one being prevented. Decision 3's wording ("if the rung was ETD") reads as fail-closed; it is not. |
| **D-c** | The mapped/unassigned label replay binds **in-tolerance only** — no nearest-peak fallback. | `mapScanOntoModel_` deliberately falls back to "closest overall" (`:947`) so that *"a matched fragment is never dropped for lack of a peak"*. That is the right rule for its question (does this known fragment have intensity here?) and the wrong rule for this one (does this peak deserve a known fragment's name?). Copying it would stamp a real `b61` onto an arbitrarily distant peak: a confident wrong label, which decision 5 exists to make impossible. |
| **D-d** | Every pool filter — `min_target_mass`, the charge floor, `mz > 0 && charge > 0` — runs **inside** the planner, before the dispatch memory is stamped. | `min_fragment_charge` is enforced at `Exploration.cpp:950`, *after* `planNextScans` has already returned. Stamping the nominal mass first would therefore burn it on a target that is then dropped downstream — and because decision 7's memory is monotone and "dispatched-but-never-returned counts as done", that mass is unreachable for the rest of the Precursor's life. Filters → stamp → budget, in that order. |
| **D-e** | The `[MS3-PLAN]` marker is **split** across two emitters: the tracker prints `pool/targets/truncated/budget`, `Exploration` prints `variants/commands` on a separate `[MS3-DISPATCH]` line. | Decision 8 asks for one line carrying `variants=` and `commands≈`, which cannot be written where it is specified: `buildVariants_` is private to `Exploration` and the tracker holds no reference to it. The figures still both get emitted; they land on two markers instead of one. |
| **D-f** | The wire format is **not** changed. An unassigned MS3 carries no ion token and logs an empty `ion_type` with `ion_index = 0`. | Owner's call, and the cheaper half of a real trade: a `u` on the wire would need 2 of the 15 scan-description characters and a decoder change on the C# side, to distinguish an unassigned MS3 from an ion-less one in a column that is already reconstructed by parsing. `'u'` stays an in-engine sentinel whose only job is to drive the decision-5 matcher guard. Folded into decisions 5b and 6 above. |
| **D-g** | Decision 11's metric override is gated `msn_level >= 3`. | `initiate`'s `ion_type` defaults to `'\0'` and the MS2 call site passes nothing, so an ungated class test fires on every MS2 exploration group and moves four goldens. Stated in full under decision 11. |

## Consequences

**`exhaustive` diverges from the existing modes at `max_targets: 3`.** Two of `T4`'s top three
masses are unassigned, so the mode is observable at the smallest realistic budget. This is not a given
— `in_depth` (ADR-0014) shipped with `phase4_deep_mode.tsv` row-identical to `phase4_standard_dda.tsv`
and a permanently `[Ignore]`d continuity test, because its effect needed a contended budget the
fixture never produced.

**A mass floor is not inheritable from deconvolution.** `deconvolution.min_mass: 500` and
`min_charge: 4` are set in the reference config, yet `T4`'s MS2 output contains 248.15 Da and charge-1
species — those floors do not reach MSn output. `min_target_mass` is therefore a real new key, not a
duplicate of an existing one, and `min_fragment_charge` is doing work nothing else does.

**The intact precursor will often be target #1.** Surviving precursor is frequently the most intense
species in an MS2 — that is what the `remaining_precursor` exploration metric measures — and its MS3
is `stage[0]` isolate-and-fragment followed by `stage[1]` isolate-and-fragment-again. On an ETD rung,
charge-reduced precursor species are dominant and each is a distinct mass, so several top slots go the
same way. Decision 9 accepts this deliberately: the alternative was a physics-based skip that no
config key governs, and the budget is authored explicitly.

**Cost multiplies along three independent axes, and `max_targets` bounds only one of them.** It bounds
*targets*, not *commands* (`Exploration.cpp:942-946`). For one `T4`-like Precursor with the budget
sized to the pool: ~105 commands alone; ~152 with `fragment_charges: separate` (its masses resolve at
1–3 charges, mean 1.44); ~105 with `multiplexed` (charges become notches); ~525 with a 5-point CE
sweep; ~735 with a 5-point sweep under a *measuring* metric, whose ADR-0020 close-out adds two per
target. The last figure across the reference run's 17 identified Precursors is ~12 500 MS3 scans.
These combinations are permitted, not gated — a CE sweep over unassigned masses is a real experiment,
and this codebase's characteristic failure has been configs accepted and then silently ignored, not
configs wrongly refused. The protection is the `[MS3-PLAN]` line, which is **stdout only** and
therefore invisible during an instrument acquisition, as every engine marker already is.

**No ABI movement — and the reason is the scan description, not a struct field.** *(Corrected
2026-08-12. This paragraph previously read "`ScanCommand::fragment_ion_type` is already a `char`".
There is no such member — `grep fragment_ion_type ScanCommand.h` returns nothing. The conclusion was
right and the stated reason was wrong, which is worse than saying nothing: it points a future reader
at a struct field to widen, and widening a `ScanCommand` field is the one edit this codebase treats
as load-bearing.)*

The ion type and index never occupy a `ScanCommand` member at all. They reach the instrument only as
characters inside `scan_description`, and **that is where the real budget is**: the field is declared
`char scan_description[256]` (`ScanCommand.h:120`), but every site that writes it passes a size of
**16** to `snprintf` — `ScanCommandQueue.cpp:329` (MS2), `:482`/`:488` (MS3), `:569` (follow-up),
`Exploration.cpp:232`/`:238` (variants) — i.e. a hard **15-character budget** plus the NUL.
`ScanCommandQueue::formatMassToken` is written against exactly that number
(`ScanCommandQueue.cpp:90-96`: `token_budget = 15 - 5 - charge_digits - ion_part`, the mass token
giving up decimals so the trailing ion is never what the cap truncates).

An unassigned target spends **none** of that budget: with `ion_index == 0` it takes `buildMS3`'s
no-ion branch (`ScanCommandQueue.cpp:485-490`) and is commanded as `{id}R{mass}k@{charge}`, the same
shape as every other ion-less isolation. So the 15-character budget is untouched, and so are the
2048-byte struct and the five bridge exports.

**Golden impact is 21 → 22 directories × 5 streams.** *(Corrected 2026-08-12: this said "the 20
existing golden mode directories". `FlashIDA/test-data/golden/logs/` holds **21** — counted
2026-08-12: `dda_etd`, `dda_hcd`, `exclusion`, `exploration_etd`, `exploration_followup`,
`exploration_hcd`, `exploration_ms3`, `exploration_ms3_followup`, `exploration_multiplexed`, `faims`,
`faims_single_cv`, `inclusion`, `inclusion_ms3_cytc`, `inclusion_strict`, `ms3_coverage_cytc`,
`ms3_cytc`, `multiplexed_ms2`, `multiplexed_ms3`, `quant`, `separate_charges`, `tag`.)*

All 21 stay byte-identical — the only cross-cutting edit is `min_target_mass`, which every config
will emit as `0`, moving `config_schema_reference.json` (generated, never hand-edited) but no log
golden. The 22nd directory is `FlashIDA/test-data/golden/logs/ms3_exhaustive_cytc/` with its five
streams.

**Level projection is the silent failure mode.** `Config::applyCharacterizationMode_` must assign
levels 1, 2 *and* 3 for `exhaustive`. `MSLevelConfig::selection` defaults to `None`, and an unassigned
level 1 makes `FLASHIda.cpp:168` short-circuit every MS1 — the instrument acquires nothing, with no
wrong value anywhere to notice. Pinned by `Config_SchemaProjection_test`.

## Open items

- **ADR-0022 is cited by the code but absent from `docs/adr/`.** `Config.h:294`,
  `ProteoformTracker.h:208` and `:229` reference it for the escalation ladder. Either it is unwritten
  or it lives outside this tree. This ADR reserves 0023 rather than assume 0022 is free; the gap is
  flagged, not filled.

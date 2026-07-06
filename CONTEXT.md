# FLASHIda — Proteoform Tracking

Domain glossary for the FLASHIda real-time intelligent data-acquisition engine,
with emphasis on the per-Precursor proteoform-tracking model under design. Terms
here are conceptual; verify code anchors before relying on them.

## Language

**Precursor**:
A molecular species selected from MS1 for fragmentation, identified by its
*nominal mass* — the averagine-adjusted, rounded integer mass
`round(monoisotopic_mass × 0.999497)` (`SpectralDeconvolution::getNominalMass`,
`SpectralDeconvolution.cpp:79`), the same key DDA mass-exclusion uses. A Precursor
is detected **once** at MS1 at a single **representative charge** (highest-SNR
`getRepAbsCharge`, one m/z isolation window); that one detection schedules the
whole downstream cascade — its MS2 (plus any CE-sweep exploration variants at that
*same* charge) and the MS3 scans that increase coverage — and the mass is put on
**dynamic exclusion immediately** so it is never re-detected/re-selected (in
particular not at a different charge state), including for inclusion targets. So
in practice **one charge state's** evidence feeds the proteoform model; the
nominal-mass key remains, but cross-charge-state pooling no longer occurs.
Coverage is deepened by **MS3**, not by acquiring multiple charge states.
_Avoid_: pooling MS2 from different charge states of the same mass (an artifact of
deferred exclusion — the same molecule re-selected at charges 8/10/15 — which
produced physically-impossible MS3 charge pairings); PeakGroup (one survey scan's
ephemeral deconvolved feature); tracking_id (per-scan); ExplorationGroup
(per-precursor-per-MSn-level CE-sweep state, erased on group completion).

**Charge ceiling (fragment ≤ precursor)**:
A fragment ion's charge can never exceed the charge of the precursor it was
produced from — a charge-`z` precursor yields fragments of charge `1..z`, and an
MS3 sub-fragment cannot exceed its MS2-fragment charge. Enforced at the **root**:
when deconvolving an MSn scan, the deconvolution's `max_charge` is set to the
**precursor's charge** (`Deconvolution::deconvolveMSn`, configuring
SpectralDeconvolution per call — not modifying it), so no fragment is ever
*assigned* a charge above its precursor. This makes the MS3 stage-0/stage-1 charge
pairing physically valid by construction.
_Avoid_: a post-hoc dispatch filter that drops over-charged fragments after the
fact (treats the symptom); deconvolving MSn with the global MS1 `max_charge` (50),
which is what let a fragment be assigned a charge above its precursor.

**Proteoform model** (`ProteoformModel`):
The pooled, evolving best-known identification of a single Precursor: the winning
proteoform (sequence + region bounds + PTM sites) chosen across all MS2 parameter
sets, with each mapped fragment annotated by the MS2 parameters that produced its
highest-intensity observation. One per Precursor, held by the Proteoform tracker
for the whole run. Distinct from the per-scan `ProteoformMatch`, which is
transient and recomputed every MS2.
_Avoid_: ProteoformMatch (single-scan, no pooling), MS2Context (per-MS3 cache of
one MS2's bounds + PTMs), "identification" (per-scan in current code).

**Proteoform tracker** (`ProteoformTracker`):
The engine component — owned by the FLASHIda instance, whole-run lifetime — that
holds one Proteoform model per Precursor and acts as the **dispatch authority**
for downstream scans: every new MS3 scan and every follow-up MS2 scan is
dispatched *via* the tracker. Exploration and other paths consult it rather than
building those commands directly. It is also the **identification authority**: it
runs the fragment matching (`FragmentAnalysis` / `MS3FragmentMatcher`) and owns the
resulting `ProteoformMatch` — fragment ions, fragment-ion count, coverage, and the
per-variant + calibrated variant matches. Other code that needs an
identification-derived quantity **consults the tracker** rather than invoking a
matcher itself.
_Avoid_: Exploration (sweeps MS2/MS3 fragmentation parameters for one target; does
not pool across scans) — note Exploration keeps the **scoring** role (the metric
math + winner selection in `computeExplorationScore_`) and consults the tracker for
identification inputs; the tracker does **not** compute the exploration metric
score. PrecursorSelection (MS1 → MS2 ranking).

**Identification score**:
The scalar used to pick the single best proteoform across a Precursor's MS2
parameter sets: the **FLASHExtender proteoform hit score**
(`proteoform_hits[0].getScore()`, surfaced into `ProteoformMatch`). Single-best
wins (no consensus); ties break by `total_match_count`, then lower collision
energy. If no variant scan identifies anything, the Precursor has no proteoform
and therefore no MS3 plan.
_Avoid_: the ExplorationMetric scores (MassCount / RemainingPrecursor /
FragmentCount) — those are parameter-sweep objectives, only comparable within one
exploration group, NOT identification quality.

**MS2 parameter set**:
The concrete tuple of fragmentation parameters under which one MS2 acquisition was
run: collision energy, activation type, reaction time. The unit a Precursor's MS2
exploration sweeps over, and the provenance recorded on each fragment observation.
_Avoid_: "variant" used loosely (an ExplorationVariant is exactly one point in the
sweep, not a collection), "scan config" (the static method.json template, not the
as-run parameters).

**Fragment observation**:
One sighting of a fragment ion in one scan: its MS level (MS2 or MS3), observed
deconvolved mass, intensity, the source scan's tracking id, and the MS2 parameter
set it was acquired under (for an MS3 sighting, the parent MS2's parameters). The
raw evidence the model pools.

**Mapped fragment**:
A theoretical fragment ion of the winning proteoform onto which observed masses
have been assigned, annotated with prefix/suffix coverage and — per MS level — the
highest-intensity Fragment observation. MS2 and MS3 sightings share one table via
the proteoform frame (MS3 ions fold in through their full-protein equivalent
indices). The best *MS2* observation supplies the parameters for an MS3 dispatch.
_Avoid_: FragmentMatch (single-scan, transient, carries no intensity or
provenance), peak (pre-deconvolution).

**Modification state** (a.k.a. resolving a sequence ambiguity):
A modification of known mass whose location is known only to a residue *range*
[start, end], narrowed toward a single residue by bracketing fragments that match
with vs. without the shift at the given tolerance. Carries bidirectional intensity
support (one value per boundary) so conflicting evidence resolves to the
higher-intensity mass. start == end means localized.
_Avoid_: PTMSite (a single-scan snapshot from FLASHExtender with no cross-scan
narrowing); treating it as a per-residue probability list (it is a contiguous
range, not a candidate set).

**Containing fragment (MS3 target)**:
The fragment the model selects for MS3 to resolve an ambiguous modification over
residues `[s,e]`: an observed fragment whose coverage **contains** the range
(`cover_start ≤ s AND cover_end ≥ e`) — a b-ion with index `k ≥ e`, or a y-ion with
`k ≥ L−s+1`. Its MS3 re-fragments the span and yields the internal cleavages that
localize the PTM. The model picks the highest-`best_ms2`-intensity container,
round-robin across ambiguous mods, bounded by `ms2.max_targets`; no container ⇒ no
MS3 (MS3 cannot narrow a range nothing spans). See ADR-0005.
_Avoid_: a fragment that cleaves *inside* `[s,e]` (that is what `narrowModifications_`
matches to *narrow* the range — it cannot be a *target*, since its existence would
already have narrowed the range); the retired legacy intensity-scatter MS3 selection.

**MS3 scan (two-stage)**:
A single instrument command performing two sequential fragmentations: `stage[0]`
isolates and fragments the precursor (the **MS2 fragmentation**, which *produces*
the target fragment ion), then `stage[1]` isolates that fragment ion and fragments
it again (the **MS3 fragmentation**). The model supplies `stage[0]` with the
target ion's **best MS2 parameters** — maximizing how much of the fragment (the
MS3 precursor) is produced. `stage[1]` uses the **user-configured MS3 parameters**,
with the optional CE sweep centered on them.
_Avoid_: thinking the best-MS2 parameters set the MS3 fragmentation chemistry —
they set the MS2 fragmentation (`stage[0]`) that *feeds* the MS3 (`stage[1]`).
More fragment ion = more MS3 precursor = strictly better.

**Pre-scan**:
An exploration scan acquired solely to optimize an MSn parameter — not kept as the
final measurement. Example: a CE sweep under the RemainingPrecursor metric, whose
pre-scans find the collision energy that leaves the target remaining-precursor
ratio. Pre-scans feed winner selection; the Follow-up MSn is then acquired at the
chosen parameters.
_Avoid_: confusing a pre-scan with the production scan it informs.

**Baseline variant**:
A special CE-0 / RT-0 pre-scan prepended (index 0) to an exploration group. It
measures the *un-fragmented* reference (for RemainingPrecursor, the intact-precursor
intensity the CE variants are ratioed against) and is **skipped in winner
selection** (`is_baseline`). As of `august_pre` a baseline is prepended to **every**
exploration metric, not only RemainingPrecursor (Phase-2 decision 2026-07-06) — so
every exploration group now fires one extra pre-scan and emits one extra variant row.
It is **excluded from the ProteoformTracker feed** (an `is_baseline` guard), so a
CE-0 baseline never contributes to the pooled proteoform model.
_Avoid_: treating the baseline as a scorable variant (it never wins); assuming it
exists only for RemainingPrecursor (that was the pre-`august_pre` behavior); letting
it feed the pooled model.

**Follow-up MSn**:
The production MSn scan emitted at the parameters chosen by a parameter-optimizing
pre-scan exploration (e.g. the CE that hit the target remaining-precursor ratio).
Dispatched via the model. Today this is the Exploration "production scan" emitted
when the level's overrides are non-empty after winner selection.
_Avoid_: treating follow-up MSn as ad-hoc re-acquisition for a missing fragment —
it is specifically the optimized production scan that *follows* pre-scans.

**Pooled identification log**:
A new optional output — enabled, like every other FLASHIda log, by a non-empty
`runtime` path (no mode/verbosity/flag; on iff path set) — that writes the
Proteoform tracker's evolving per-Precursor model. One row is re-emitted each time
a Precursor's model updates (a *trajectory*), so sequence coverage visibly climbs
over the run. Columns mirror the per-scan `identification` log but at per-Precursor
granularity: ProForma sequence, FLASHExtender score, % coverage, localized vs.
ambiguous modifications, contributing scan ids, and — **always** — the grouped
combined per-fragment mass table: aligned lists of **adjusted**
(`combined_ms2_frame_masses`), the **ion label** (`combined_ms2_fragment_ions`,
e.g. `b22;y13`), **measured**, **theoretical**, and the residual in **Da and ppm**
(see *Fragment masses (measured / adjusted / theoretical)*). Emitted by the tracker,
not the per-scan `processScan` path — it is the engine's first cross-scan log.
_Avoid_: `identification.tsv` (the per-scan, per-identification leaf it sits
beneath); treating it as a per-scan log or giving it an enable flag (paths are the
idiom).

**Fragment masses (measured / adjusted / theoretical)**:
Every mapped fragment carries three distinct masses; keeping them separate is the
fragment-representation contract.
- **Measured** — the raw deconvolved monoisotopic mass of the fragment as seen in
  its *own* scan. An MS2 fragment is already a protein-frame b/y ion; an MS3
  sub-fragment is in its precursor-**subsequence** frame (`identification.tsv`
  `ms3_fragment_masses`; the model's `FragmentObservation.measured_mass`).
- **Adjusted** — the measured mass re-expressed in the full-protein (MS2)
  coordinate frame **with the fragment's real modifications retained**:
  `observed + (theo_equiv − ms3_theoretical) + ambiguous_included`. For a *trivial*
  frame (a b sub-fragment of a b precursor) `adjusted == measured`. This is the
  value the model pools and the `combined_ms2_frame_masses` list reports
  (`FragmentMatch.adjusted_mass` via `equiv_type`/`equiv_index`;
  `identification.tsv` `ms2_fragment_masses`).
- **Theoretical** — the mass the **proteoform predicts** for the fragment ion,
  computed for **both** levels (not just MS3): for an **MS2** fragment it is the
  matcher's PTM-adjusted theoretical (`best_theo`, `FragmentAnalysis.cpp`); for an
  **MS3** fragment it is the mod-inclusive equivalent-ion theoretical
  (`calibrateAndScore`). Carried per-scan onto `FragmentObservation.theoretical_mass`
  / `FragmentMatch.theoretical_mass`, so `combined_theoretical` and the
  identification `theoretical_masses` are real for MS2 fragments too (not `0`).
- **Residual** — `adjusted − theoretical`, reported in **Da and ppm** (for MS2,
  `observed − theoretical`; for MS3, the subsequence-frame match error
  `measured − ms3_theoretical`). Contract: `|residual| ≤ tolerance` — the measured
  evidence, re-framed, must agree with the proteoform prediction.

_Avoid_: reporting the raw sub-sequence-frame mass as the adjusted (MS2-frame)
mass; **stripping modifications from `adjusted`** (the bare-backbone defect —
`computeProteinPrefixMasses` dropped still-ambiguous mods from `theo_equiv`, making
`adjusted = observed − ambiguous_mods`, ~526 Da low for cytC, so it matched no
modified ladder); conflating the per-scan theoretical (that scan's wider
proteoform) with the pooled theoretical (the refined, localized one).

**Identification row (`identification.tsv`) — the identified species**:
An identification row describes the species the scan **identified** — its
`proteoform`/`start_pos`/`end_pos`/`fragments` all come from the per-scan match
(`FragmentAnalysis::ProteoformMatch`). For an **MS2** scan that species is the MS2
proteoform. For an **MS3** scan it is the **fragment** the MS3 precursor covers: the
sub-sequence over `[start_pos, end_pos)` + its mods (parent mods clipped/rebased into
the fragment; `MS3FragmentMatcher::calibrateAndScore` fills `proteoform_sequence`/`ptm_sites`).
Invariant: an MS3 row's `proteoform` bare-residue count == `end_pos − start_pos`. The
paired `MS2Context` (`ctx`) supplies only the **acquisition context** — MS1/MS2/MS3
precursor identity + isolation — never the identified proteoform.
_Avoid_: logging the **parent** proteoform on an MS3 identification row (the old
`use_ctx_proteoform` special-case — inconsistent with the fragment `start_pos`/`end_pos`);
pasting fragment-frame `ptm_sites` onto the parent sequence. NOTE the **four logs** split by role
(after the scan_results slim-down):
- **`scan_commands.tsv`** (per fired command) carries the MS3 target's **wide clipped b/y fragment**
  proteoform in the `ms3_proteoform` column — rendered at command-build time by
  `MS3FragmentMatcher::fragmentProForma` (stashed in `ScanCommandQueue`'s `ms3_cmd_proteoform_` side-map,
  drained by `takeMS3Proteoform`), so it is present for **every** MS3 command (regular + exploration),
  even ones that never return. `""` on MS1/MS2/AGC rows.
- **`scan_results.tsv`** (per scan) is now a **pure acquisition-event** log — timing, deconv masses,
  parent lineage, exploration sweep bookkeeping. It carries **no identification payload** (the former
  `tag_count`/`matched_protein`/`proteoform_sequence`/`tic_coverage`/`fragment_count` columns were removed).
- **`identification.tsv`** (per matched scan) is the identification leaf: the annotated b/y ion, its
  `ms3_fragment_coverage` (distinct backbone bonds / (L−1)), and `tic_coverage` (moved here from
  scan_results). Its MS3 `proteoform` mods are **narrowed by that scan's own evidence**.
- **`pooled_identification.tsv`** is the per-Precursor **cross-scan cumulative** narrowed trajectory.

The **narrowing gradient** on an MS3 ambiguous modification: `scan_commands` renders it **wide** (the
clipped parent MS2 range); `identification` renders it narrowed by **only that scan's own matched
sub-fragments** (`FragmentAnalysis::narrowFragmentPTMSites`, mirroring the MS3 pass of
`ProteoformTracker::narrowModifications_`, applied to a local copy in `IdaLogger::writeIdentificationRow`);
`pooled` renders the cumulative narrowing. All three are correct at their own granularity — a per-scan
leaf legitimately stays wider than pooled when *that scan* adds no bracketing evidence. Do **not** feed
the **pooled** (cross-scan) narrowed range back into the per-scan leaf; the leaf uses per-scan evidence
only.

**Characterization**:
The feature umbrella and the method.json config section (`characterization`) for the
per-Precursor proteoform model: its `objective` (`ambiguity | coverage`) and the
target `protein_sequence` (relocated out of `ms3.*`). The model engages whenever an
MS2 selection strategy is configured; every other knob is reused from existing
config (mapping tolerance = `deconvolution.tol[]`; MS3 budget =
`selection_strategy.ms2.max_targets`; best proteoform = highest FLASHExtender score).
_Avoid_: the legacy `ms3.*` control keys (the C++ parser throws on them); a separate
enable flag (engagement is implicit).

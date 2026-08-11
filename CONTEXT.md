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
is detected **once** at MS1 and acquired at one **acquisition charge set** — by
default a single **representative charge** (highest-SNR `getRepAbsCharge`, one m/z
isolation window). That one detection schedules the whole downstream cascade — its
MS2 (plus any CE-sweep exploration variants over that *same* charge set) and the
MS3 scans that increase coverage — and the mass is put on **dynamic exclusion
immediately** so it is never re-detected as a *new* Precursor, including for
inclusion targets. So one Precursor's evidence comes from **one charge set**, never
from separate detections of the same mass at different charges.
_Avoid_: pooling MS2 from **separate detections** at different charge states (an
artifact of deferred exclusion — the same molecule re-selected at charges 8/10/15 —
which produced physically-impossible MS3 charge pairings; charges *co-isolated
within one detection* are a different thing, see **Acquisition charge set**);
PeakGroup (one survey scan's
ephemeral deconvolved feature); tracking_id (per-scan); ExplorationGroup
(per-precursor-per-MSn-level CE-sweep state, erased on group completion).

**Charge ceiling (fragment ≤ precursor)**:
A fragment ion's charge can never exceed the charge of the precursor it was
produced from — a charge-`z` precursor yields fragments of charge `1..z`, and an
MS3 sub-fragment cannot exceed its MS2-fragment charge. Enforced at the **root**:
when deconvolving an MSn scan, the deconvolution's `max_charge` is set to the
**highest charge the scan actually isolated** — the anchor charge for a
single-charge acquisition, the **maximum of the acquisition charge set** when
charges were co-isolated (`Deconvolution::deconvolveMSn`, configuring
SpectralDeconvolution per call — not modifying it), so no fragment is ever
*assigned* a charge above every precursor present in the isolation. This keeps the
MS3 stage-0/stage-1 charge pairing physically valid by construction: a co-isolated
stage-0 replays the same charge set, so the charge that produced a fragment is
present again when that fragment is re-isolated.
_Avoid_: a post-hoc dispatch filter that drops over-charged fragments after the
fact (treats the symptom); deconvolving MSn with the global MS1 `max_charge` (50),
which is what let a fragment be assigned a charge above its precursor; using the
anchor charge as the ceiling when a higher charge was co-isolated (that discards
real fragments).

**Acquisition charge set**:
The charge states of one Precursor — or of one target fragment — that a single scan
isolates. Size one by default: the representative charge. Membership is a
signal-to-noise judgement, a charge joining only if its own envelope rises above
noise, because a charge contributing no signal still consumes part of the scan's
ion budget. A set may be **co-isolated** — all members isolated together in one
scan as separate **notches**, sharing one isolation event and one identity — or
acquired as one scan per member, which yields that many independent Precursors
rather than one. The instrument caps the set's size.
_Avoid_: "all charge states" unqualified (the set is SNR-gated and capped);
treating co-isolation and one-scan-per-charge as interchangeable — the first is one
Precursor, the second is several.

**Anchor charge**:
The member of an acquisition charge set that a scan's **identity and per-charge
scores** are attributed to — the highest-SNR member. What a scan is *keyed* by is
the anchor's (its tracking id, its scan description, the charge on its
identification row); what the scan *isolates* is the whole set. A single-charge
acquisition acquires the anchor and nothing else.
_Avoid_: reading a scan's logged charge as the only charge it isolated; equating
the anchor with the representative charge — the representative charge is a property
of the deconvolved feature, the anchor is a property of the acquisition, and
per-charge qscore or an exclusion fallback can make them differ.

**Charge-keyed exclusion**:
The variant of dynamic exclusion that keys on `(nominal mass, charge)` rather than
on nominal mass alone, so a mass already fragmented at one charge stays eligible at
another. Its effect is a **fallback**, not a fan-out: a Precursor is still acquired
once per detection, but at the best charge not yet excluded, so a species seen
across several surveys is sampled at a different charge each time. When a scan
co-isolates a charge set, **every member it isolated** is recorded as acquired —
otherwise the next survey falls back onto a charge already fragmented.
_Avoid_: expecting it to acquire several charges of one mass within a single survey
(that is one-scan-per-charge acquisition, a separate choice).

**Proteoform model** (`ProteoformModel`):
The pooled, evolving best-known identification of a single Precursor: the winning
proteoform (sequence + region bounds + PTM sites) chosen across all MS2 parameter
sets, with each mapped fragment annotated by the MS2 parameters that produced its
highest-intensity observation. One per Precursor, held by the Proteoform tracker
for the whole run. The winner scan's own FLASHTnT fragments are trusted verbatim;
**non-winner MS2 scans contribute only by re-matching their raw deconvolved masses
against the winner ladder** (never their own hypothesis), so every pooled fragment is
winner-consistent and the reported ProForma regenerates its own fragment masses
(ADR-0006). MS3 is likewise scored against the *live* winner, not the triggering scan.
Distinct from the per-scan `ProteoformMatch`, which is
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

**QScore**:
FLASHDeconv's confidence that a deconvolved mass is real — a fixed logistic over five
features (isotope cosine, the per-charge cosine deficit, per-charge SNR, that SNR's
excess over the whole group's, and the average ppm error), all sharing one weight vector
(`PeakGroupScoring::weight_`, `PeakGroupScoring.cpp:16`). It is **one model with three
read points**, not three scores: `getQscore()` evaluates it at the **representative
charge**, `getAllQscores()[z]` at charge `z` (only for charges carrying intensity), and
`getBestQScore()` takes the maximum over those. So the per-mass value is an *element* of
the per-charge set, never an aggregate of it, and the two cannot disagree about the
representative charge. Which one gates MS1 selection is
`precursor_selection.consider_all_charges` — off in every shipped config, i.e. the
representative-charge value, which is also what ranks the survey list. Recomputed per
scan at every MS level against that level's minimum isotope cosine, so MSn fragments
carry real scores too.
_Avoid_: the ExplorationMetric scores and the **Identification score** — different
quantities entirely, see those entries; `getQscore2D()`, a feature-trace refinement
written only by MassFeatureTrace / FLASHTnT / FLASHDeconvAlgorithm, none of which run in
real time, so it is identical to `getQscore()` here and its name misleads; comparing
scores across runs at full precision (CI relinks OpenMS every run, so the low digits
jitter); assuming the representative charge is the most intense one — it is the highest
**ChargeSNR** one (see **Anchor charge**).

**Identification score**:
The scalar used to pick the single best proteoform across a Precursor's MS2
parameter sets: the **FLASHExtender proteoform hit score**
(`proteoform_hits[0].getScore()`, surfaced into `ProteoformMatch`). Single-best
wins (no consensus); ties break by `total_match_count`, then lower collision
energy. If no variant scan identifies anything, the Precursor has no proteoform
and therefore no MS3 plan.
_Avoid_: the ExplorationMetric scores (MassCount / RemainingPrecursor /
FragmentCount) — those are parameter-sweep objectives, only comparable within one
exploration group, NOT identification quality. Note the one place the two touch:
a metric never *measures* identification quality, but at MS3 it does decide whether
a pre-scan is identified at all (**Pre-scan**, reading vs measuring metrics).

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
A non-winner MS2 mass becomes a mapped fragment only if it matches the winner ladder
(base, or base+shift for a bracketed ambiguous mod); off-ladder masses and
base-and-base+shift double-matches are dropped, and a mass within tolerance of two
distinct winner ions goes to the closest by ppm (ADR-0006).
_Avoid_: FragmentMatch (single-scan, transient, carries no intensity or
provenance), peak (pre-deconvolution).

**Modification state** (a.k.a. resolving a sequence ambiguity):
A modification of known mass whose location is known only to a residue *range*
[start, end], narrowed toward a single residue by bracketing fragments that match
with vs. without the shift at the given tolerance. Carries bidirectional intensity
support (one value per boundary) so conflicting evidence resolves to the
higher-intensity mass. start == end means localized. **MS2 evidence is authoritative;
MS3 only refines *within* the MS2-narrowed range** (tighten-only, never reversing an
MS2-set boundary).
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

**Notch**:
One of several isolation windows a single scan opens **in parallel within one
fragmentation stage** — as against a *stage*, which is a further fragmentation
performed **in sequence** (see **MS3 scan (two-stage)**). All notches of a stage
fire into the same fragmentation event and are read out as one spectrum, so a
three-notch scan yields one spectrum, not three. Every notch of a stage holds a
different charge state of the *same* species, so a multi-notch spectrum is **not
chimeric**: all its fragments belong to one neutral mass, and it carries one
Precursor identity.
_Avoid_: calling a notch a stage (a stage descends to the next MS level, a notch
widens the current one); assuming several notches means several precursors.

**Pre-scan**:
An exploration scan acquired solely to optimize an MSn parameter — not kept as the
final measurement. Example: a CE sweep under the RemainingPrecursor metric, whose
pre-scans find the collision energy that leaves the target remaining-precursor
ratio. Pre-scans feed winner selection; the Follow-up MSn is then acquired at the
chosen parameters.
**Whether a sweep also *reads* its pre-scans is a property of its metric, not of the
scans.** A **reading** metric (FragmentCount) matches every variant against the
proteoform to score it, so its pre-scans leave identifications behind as a side
effect. A **measuring** metric (RemainingPrecursor, MassCount) only weighs bulk
signal and never matches fragments, so at MS3 its pre-scans leave *no* evidence
whatsoever — which is why a measuring MS3 sweep must always be closed by a
Follow-up MSn. This asymmetry is MS3-only: at MS2 every variant is matched under
every metric, because the whole-protein matcher used there is the right one.
_Avoid_: confusing a pre-scan with the production scan it informs; assuming a
completed sweep has produced evidence (a measuring metric produces a *parameter*,
not a measurement).

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
Dispatched via the model, and — unlike a pre-scan — identified on the ordinary MSn
path, so it is the scan that actually contributes evidence.
It is emitted when **either** of two conditions holds after winner selection:
- the pre-scans were **degraded** relative to production (**Exploration overrides**
  non-empty), so no variant was acquired at production settings; or
- the sweep's metric never read its pre-scans (**Pre-scan**, a measuring metric —
  MassCount or RemainingPrecursor) and the level is **MS3**. An MS3 sweep that
  leaves no evidence must be closed by a scan that does.
An MS2 sweep is exempt from the second condition: its variants are already
identified, and it cascades to MS3 rather than re-acquiring itself.
_Avoid_: treating follow-up MSn as ad-hoc re-acquisition for a missing fragment —
it is specifically the optimized production scan that *follows* pre-scans; assuming
"overrides empty" implies "no follow-up" (that was the rule before the metric
condition was added).

**Exploration overrides**:
The scan settings a sweep's **pre-scans** run under, expressed as a patch on the
level's scan config. Their purpose is to make pre-scans *cheaper* than the real
measurement (lower resolution, fewer microscans), so a sweep costs less than the
production scan it informs. Their presence is therefore also a statement about
fidelity: with overrides, no pre-scan was acquired at production settings, so a
**Follow-up MSn** is mandatory; without them, the pre-scans ran at production
settings and the winner is production-grade — provided the metric read it.
_Avoid_: reading overrides as settings for the follow-up scan (the follow-up is
built from the *un-overridden* config, plus the winning parameters); treating an
empty overrides map as "nothing special" rather than as "pre-scans ran at
production fidelity".

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
- **Measured** — the deconvolved monoisotopic mass of the fragment as seen in
  its *own* scan. An MS2 fragment is already a protein-frame b/y ion; an MS3
  sub-fragment is in its precursor-**subsequence** frame (and is the
  calibration-corrected mass — `md.observed_mass` after the two-pass ppm
  correction, not literally raw) (`identification.tsv` `ms3_fragment_masses`;
  the model's `FragmentObservation.measured_mass`).
- **Adjusted** — the measured mass re-expressed in the full-protein (MS2)
  coordinate frame **with the fragment's real modifications retained**, via a
  **ppm-honest** (multiplicative) projection: scale the mod-inclusive equivalent
  theoretical by the sub-fragment's measured fractional error —
  `theoretical_equiv × (observed / ms3_theoretical)`, *not* the Da-additive
  `observed + (theo_equiv − ms3_theoretical) + ambiguous_included` (that asserted
  the un-measured complement was error-free and deflated the ppm). For a *trivial*
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
- **Residual** — `adjusted − theoretical`, reported in **Da and ppm**. For MS2 it
  is `observed − theoretical`. For MS3, because the projection is multiplicative,
  the **ppm** residual equals the subsequence-frame measured ppm exactly
  (`(observed − ms3_theoretical) / ms3_theoretical`, == the matcher's own per-ion
  error), and the **Da** residual is the equivalent-frame *projected* Da
  (`theoretical × (ratio − 1)`, larger than the raw sub-frame Da). Contract:
  `|ppm residual| ≤ tolerance` — the measured evidence, re-framed, must agree with
  the proteoform prediction.

_Avoid_: reporting the raw sub-sequence-frame mass as the adjusted (MS2-frame)
mass; **carrying the sub-frame Da error into the MS2 frame as an additive offset**
(the ppm-deflation defect — `adjusted = observed + Da_offset` reports the small
sub-frame Da error over the large equivalent mass, flattering the match; project
multiplicatively instead); **stripping modifications from `adjusted`** (the bare-backbone defect —
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
clipped triggering-scan MS2 range, built pre-acquisition — it cannot know the MS3 ions yet);
`identification` renders a **fresh per-scan** ambiguity — `FragmentAnalysis::narrowFragmentPTMSites` (in
`IdaLogger::writeIdentificationRow`) brackets each mod over **that scan's own EQUIVALENT (full-protein) ions**
(`fm.equiv_type`/`fm.equiv_index` + the flip/mod-aware verdict shared with pooled Pass B, **not** the raw
sub-frame ion), seeded **wide over the fragment region `[1,L]`** and tightened inward, then **merges** any
mods that scan cannot separate into one **summed** shift over their union (a gap-partition: overlapping
brackets == a shared gap == co-observed); `pooled` renders the cumulative **one-directional** narrowing folded
on every full MS3. All three are correct at their own granularity — the per-scan leaf reflects **exactly what
that scan's ions resolve**, so it can be **wider OR narrower than pooled** and **may exceed the `scan_commands`
a-priori base** (there is **no** leaf-⊆-`scan_commands` guarantee; the `wide_sites` base is a classification
reference, not an output clamp). Do **not** feed the **pooled** (cross-scan) narrowed range back into the
per-scan leaf; the leaf uses per-scan evidence only.

**Characterization**:
The feature umbrella and the method.json config section (`characterization`) for the
per-Precursor proteoform model. It holds **decisions only** — no scan parameters — and
its `mode` (`off | ambiguity | coverage`) is the **single switch** that decides whether
MS3 happens at all. The two on-values *are* the objectives, so there is no separate
`objective` key and no way to express "on, but with no objective"; unknown values are
rejected rather than defaulted. The section also carries the target `protein_sequence`,
the MS3 budget (`max_targets`) and the fragment-charge floor (`min_fragment_charge`).
Mapping tolerance is still reused from `deconvolution.tol[]`, and the best proteoform is
still the highest FLASHExtender score (ADR-0013, ADR-0014).
_Avoid_: the legacy `ms3.*` control keys and `selection_strategy` (the C++ parser throws
on both, with migration messages); the idea that engagement is implicit — it was, and
that produced three gates in two sections; treating `characterization.objective` as a
live key.

**Scan config name**:
A user-authored identifier for one scan config in `ms_settings.additional_ms2`,
referenced from wherever that scan is wanted — `precursor_selection.additional_scans`
to fire it after every survey, or a `follow_up_scan` to fire it conditionally. The
**reference is the selectivity**; the block is only parameters. A block nobody names is
never acquired, which is what stops a follow-up's scan config from also firing as an
unconditional MS2. Names are snake_case identifiers, and resolution happens at config-load
time, so nothing downstream of `Config` ever sees a name.
_Avoid_: assuming definition order matters (dispatch order comes from the reference
array, never from the definition map); a name for the common case (`ms_settings.ms2` and
`.ms3` are unnamed bare objects — only extras are named).

## Language — instrument control

A scan carries **two independent identity channels**. Conflating them is what produced the
contact-closure startup defect, so the two are named separately and deliberately.

**Instrument job number**:
The integer FLASHIda stamps on an outbound custom scan as `RunningNumber`, which the
instrument echoes back on the returning scan as `Trailer["Access ID"]`. It exists for the
custom-control handshake and for human-readable log correlation. The C++ engine never reads
it. `0` is reserved by the iAPI and must never be sent.
_Avoid_: scan id, Access ID / RunningNumber as separate concepts (one value, two directional
names); and never as a synonym for the tracking id.

**Tracking id**:
The engine-minted base-94 identifier occupying the first three characters of
`Trailer["Scan Description"]`. It is the **sole** key `FLASHIda::processScan` decodes and
looks up in `pending_scan_map_`; a scan whose tracking id the engine did not mint is
rejected before deconvolution. Minted by `ScanCommandQueue::nextTrackingId`.
_Avoid_: scan id, Access ID, instrument job number.

**Handshake scan**:
The single scan whose echoed **instrument job number** proves the instrument has entered
custom control. Its spectrum is discarded — it is a control signal, not data.
_Avoid_: magic scan (the historical name; it describes the constant, not the purpose).

**Custom control mode**:
The latched state in which FLASHIda drives acquisition. Latching requires the *echo* of the
handshake scan, not merely having sent it: scans arriving before custom control engages
belong to the instrument's own method and must be ignored.
_Avoid_: connected (connection strictly precedes it); acquisition mode.

## Language — scan configuration

**Scan config**:
One fully-specified set of instrument parameters for a scan (analyzer, resolution, AGC,
injection time, mass range, activation and its parameters). Every one lives under
`ms_settings` — `ms1`, `ms2`, `ms3` (bare objects) and any number of named entries in
`additional_ms2` — and means the same thing at every one of them: **the config fully
determines the scan's instrument parameters**. The two `follow_up_scan` keys are no longer
scan configs; they are *references* to one (ADR-0014). For an
analyzer-side parameter a value left unset means "use the instrument method default", never
"inherit from another scan"; a source-region parameter left unset takes the survey's, resolved
while the config is built so that the config still fully determines the scan.
_Avoid_: treating any occurrence as a patch or delta on another scan.

**Source-region parameter**:
A parameter of the ion source and transfer optics — RF lens, source CID energy, source CID
scaling — which act on ions *before* the analyzer and therefore govern **which ions arrive**
rather than how they are measured. It is a property of the ion population an acquisition cycle
draws from, not of any single scan, so every scan in a cycle shares one value: a survey that
declusters at some source CID and a fragment scan that isolates from an un-declustered
population are not measuring the same species. Zero is a real setting for these, not an absence.
_Avoid_: calling these "MS1 parameters" (they apply to every scan); treating a zero as unset.

**Analyzer-side parameter**:
A parameter governing **how the arriving ions are measured** — resolution, AGC target, injection
time, microscans, data type, scan rate, and the activation and its coupled parameters. Belongs
to one scan, is never inherited from another, and reads zero or empty as "use the instrument
method default".
_Avoid_: assuming a per-scan parameter can be defaulted from a neighbouring scan.

**Activation-coupled parameter**:
A scan parameter that is meaningful only for particular activation types, and which must
therefore travel with the activation whenever it is set: `collision_energy` for HCD / CID /
EThcD, and `reaction_time` + `reagent_max_it` + `reagent_agc_target` for ETD / EThcD (the
ion–ion reaction settings). Carrying one activation's coupled parameters onto a scan using a
different activation is incoherent — e.g. an HCD scan has no reagent and nothing to react.
_Avoid_: "ETD settings" (they also apply to EThcD); treating reaction time as a generic
scan parameter.

**Follow-up scan**:
A second MS2 of a precursor already fragmented, dispatched from the regular-MS2 path to apply
a *different* fragmentation regime — quantification (`'F'`, when the precursor is
differentially abundant) or conditional MS2 (`'C'`, when sequence tags were found). It inherits
the precursor's identity, targeting, scoring and FAIMS CV from the triggering MS2; everything
about the instrument comes from the scan config it **names** in `ms_settings.additional_ms2`.
Depth is exactly one — a follow-up cannot trigger another.
_Avoid_: "second MS2" (exploration variants are also second MS2s but are not follow-ups);
conflating the `'F'` and `'C'` kinds, which have different triggers but identical mechanics;
expecting the referenced block to also fire unconditionally — it is deliberately absent from the
dispatch roster, and that absence is the whole mechanism.

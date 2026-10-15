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
MS3 scans that increase coverage — and the mass enters **acquisition memory**
at once, so it is not re-detected as a *new* Precursor unless a later survey
resolves it **better** than the survey that acquired it did; once it has been
acquired well enough, not even that reopens it. Both halves apply to inclusion
targets too. So one Precursor's evidence comes from **one charge set**, never
from separate detections of the same mass at different charges. One detection is
not one PeakGroup: an inclusion target's envelope can arrive **split** across
several, and those are one detection (see **Split envelope**).
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
ion budget. When the Precursor matched an inclusion row that names its charges,
that **authored charge set** narrows the candidates before that judgement runs; it
can only subtract, never extend. A set may be **co-isolated** — all members
isolated together in one scan as separate **notches**, sharing one isolation event and one identity — or
acquired as one scan per member, which yields that many independent Precursors
rather than one. The set's size is bounded at both ends, and both bounds are authored: a **floor**,
below which the species is not acquired at all, its charge states being too few to be worth the
scans; and a **cap** on how many are kept, which keeps the most intense and drops the rest.
Co-isolation additionally meets a hard instrument limit on simultaneous windows. One scan per
member meets no such limit — there its size is a scan count rather than a geometry — so leaving
the cap unauthored leaves that count unbounded.
_Avoid_: "all charge states" unqualified (the set is SNR-gated and capped);
treating co-isolation and one-scan-per-charge as interchangeable — the first is one
Precursor, the second is several.

**Authored charge set**:
The charge states named on an inclusion row for one target mass. It **restricts**
the acquisition charge set and never extends it — a named charge is acquired only
if it also clears the gates every candidate faces, and naming a charge the survey
never resolved acquires nothing, because an isolation window must be measured. A
row naming no charge leaves the set unrestricted. Where several rows name the same
mass, the sets of the rows active at this retention time are unioned.
_Avoid_: reading it as a demand for those charges (it cannot add one); "requested
charges"; conflating it with the **acquisition charge set**, which is what a scan
actually isolates once the gates have run.

**Split envelope**:
One Precursor's charge states arriving from the deconvolution as **several
PeakGroups**, each carrying part of the envelope, so no one of them can supply the
whole **intended charge set**. It is specific to inclusion targets: the collapse
that merges near-identical features down to the strongest one is deliberately
skipped for targeted ones, so only targets survive it in numbers. Two PeakGroups
within the mass tolerance **are one Precursor** — a split envelope is
indistinguishable from two co-eluting species that close in mass, and both are
treated as one.
_Avoid_: "duplicate peak groups" (the later ones carry charges the first does not);
reading a Precursor's charge states off any single PeakGroup.

**Intended charge set**:
What one Precursor should be acquired at within a single survey, and therefore what
"acquired in full" is measured against: its **authored charge set**, narrowed to the
members a given PeakGroup actually resolved. Only a Precursor whose inclusion row
**names charges** has one — a row naming none has no opinion about charge, so
nothing about it is ever incomplete and no PeakGroup of it is ever owed a scan. A
PeakGroup of an already-acquired Precursor earns a scan only by completing the set,
never by scoring well.
_Avoid_: conflating it with the **acquisition charge set**, which is what one scan
isolates — completing one intended set may take several scans, and under a **split
envelope** several PeakGroups; assuming an acquisition mode that asks for several
charges creates one (that decides how many charges a scan isolates, not which ones
the Precursor is owed).

**Anchor charge**:
The member of an acquisition charge set that a scan's **identity and per-charge
scores** are attributed to — the highest-SNR member. Under an **authored charge
set** it is the highest-SNR *authored* member, chosen there even when that member
does not clear the signal-to-noise gate, since a matched target's anchor is exempt
from it. What a scan is *keyed* by is the anchor's (its tracking id, its scan
description, the charge on its identification row); what the scan *isolates* is
the whole set. A single-charge
acquisition acquires the anchor and nothing else.
_Avoid_: reading a scan's logged charge as the only charge it isolated; equating
the anchor with the representative charge — the representative charge is a property
of the deconvolved feature, the anchor is a property of the acquisition, and
per-charge qscore, an authored charge set, or an exclusion fallback can make them
differ.

**Commanded precursor**:
The species a scan command was built to fragment — its mass and **anchor charge**, as the engine
resolved them in the survey the command was decided from. For a commanded scan it *is* the
scan's precursor, by construction: the isolation exists because of it. A later analysis may
**measure** that species better than the engine could — it re-reads the same survey with the
whole run in hand — but it may not **choose** a different one. The record answers *which
species, from which survey*; the analysis answers *how well is it known*. Merging the two
questions fails quietly: an analysis that re-derives the choice from the spectrum alone reads
the most recent survey, which is routinely not the one the command came from, and reports
whatever is strongest in the window by then.
_Avoid_: "logged precursor mass" (the record is a locator, not a measurement — the mass worth
reporting is the analysis's own); "the precursor in the isolation window" (several species
usually are, and one was commanded); assuming the survey acquired before a scan is the survey
behind it.

**Charge-keyed exclusion**:
The variant of dynamic exclusion that keys on `(nominal mass, charge)` rather than
on nominal mass alone, so a mass already fragmented at one charge stays eligible at
another. It is **scoped to Precursors carrying an authored charge set**; every
other species is excluded on nominal mass alone. Its effect is a **fallback**, not
a fan-out: a Precursor is still acquired once per detection, but at the best charge
not yet excluded, so a species seen across several surveys is sampled at a
different charge each time. When a scan
co-isolates a charge set, **every member it isolated** is recorded as acquired —
otherwise the next survey falls back onto a charge already fragmented.
_Avoid_: expecting it to acquire several charges of one mass within a single survey
(that is one-scan-per-charge acquisition, a separate choice); expecting it of a
species with no authored charge set.

**Qscore bar**:
The best score a Precursor has been acquired at: a survey resolving it better
reopens it, a survey resolving it worse does not, and the bar only ever rises.
Whether it governs anything is a **configuration** question, because it is consulted
only for a species dynamic exclusion has not already barred, and whether an
acquisition bars a species is decided by a single score threshold shared by the
whole run. Above that threshold the species is barred for the **retention-time window**
and the bar is never reached; below it, the bar governs. It is a **cross-survey**
rule alone — within one survey what earns a PeakGroup a scan is what it adds to the
**intended charge set**, never its score against a sibling's.
_Avoid_: reading it as an exclusion (it gates selection, but a species barred
outright is a different record — see **Acquisition memory**); comparing two
PeakGroups of one Precursor against it; assuming it is reachable — at commonly
configured thresholds it is not.

**Acquisition memory**:
What a run has already done to a species, keyed by *nominal mass*, together with
the rule for when that stops mattering. Several such records coexist, each
answering one question and carrying its own expiry: whether a mass is barred from
selection, whether an m/z is, the best score a mass has been acquired at, which of
its charges are spent, and which fragment masses a Precursor has already had
dispatched. Only some of them bar anything — **a record that a species was acquired
is not the same as a rule that it may not be acquired again**, and the two are
easily confused because they are written at the same moment.
_Avoid_: "the exclusion list", which names one of these records as though it were
all of them, and mis-describes the two that merely record; treating the qscore
ledger or the MS3 dispatch record as exclusions.

**Retention-time window**:
How long a record of **acquisition memory** stands: it stops mattering once the surveys
have moved on by more than the window in retention time — the time the instrument stamps
on each scan, counted from the start of its acquisition and reported in minutes. The
window itself is written in seconds.
_Avoid_: reading the window in minutes because retention times are shown in minutes;
measuring it on the **run clock** or on wall time; "exclude for the rest of the run" as a
meaning of it — that is a window longer than the run, written explicitly; "RT" alone,
which also names ion–ion reaction time.

**Acquisition effect**:
The set of writes one species' selection makes to acquisition memory in a single
survey, together with the scans that selection produced. It is the unit that can be
undone, and it belongs to the **species**, not to any one scan: a species is
fragmented at mass level once, however many scans that acquisition takes.
_Avoid_: treating it as per-scan — one selection can produce several scans (one per
co-isolated charge, one per named MS2 configuration, one per exploration variant),
and they share a single effect.

**Retaining / releasing an effect**:
The two ways an acquisition effect ends. It is **retained** when any scan built from
it comes back: the acquisition happened, so the memory stands and can never be
undone. It is **released** when every scan built from it was dropped before reaching
the instrument: nothing was acquired, so the species is given back and becomes
selectable again. A scan that was sent but never returned does neither — its effect
simply ages out.
_Avoid_: "commit/abort", which imports transaction vocabulary for something that is
not a transaction; reading a release as a failure — a species released is a species
rescued, not an error recorded.

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
**Identified** and **has a winner scan** are separate properties. Under
`characterization.mode: exhaustive` a model whose MS2 matched nothing still has a
winner scan — the scan the MS2 decision chose — and its deconvolved masses are acquired
at MS3 as **Unassigned masses**. Such a model stays **unidentified**: it has no
proteoform, contributes no row to the **Pooled identification log**, and its MS3s are
acquisitions on record, not evidence folded into it.
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

**Sequence tag count**:
How many sequence tags FLASHTagger read off one MS2 spectrum — short residue strings
inferred from the mass gaps between deconvolved peaks, **before any protein is
consulted**. It measures the spectrum's fragment ladder, not a match: the count is taken
the moment the tagger returns, so a rich spectrum scores non-zero even when nothing
matches. Sentinels are load-bearing — `-1` means no tag count is reported for this row
(every MS1 row, and every MS3 row); `0` means the tagger ran and read nothing, which for a
real protein is a meaningful negative result about that spectrum.
The MS3 `-1` is a **policy, not an absence of tagging**: MS3 exploration variants *are*
tagged, but a tag count taken on an MS3 spectrum measures the sub-fragment ladder rather
than the precursor's identifiability, which is not what the quantity means. Reading it as
"nothing tagged at MS3" is the mistake this sentence exists to prevent.
_Avoid_: conflating it with the **tag-targeting hit count** — how many tags matched a
FASTA target database, which is a *gate* (it decides whether a conditional MS2 follow-up
fires), reports zero when tags existed but matched no protein, and is computed at a
different tolerance against a different protein source; reading `0` without checking the
MS level; assuming a tag count implies an identification (tags are read before, and
independently of, any proteoform).

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

**Unassigned mass**:
A deconvolved mass of an MSn scan that matched **no** theoretical fragment of the
winning proteoform — the complement of **Mapped fragment** within the same scan's
deconvolution output. It is real measured signal, not noise: a rich MS2 resolves on
the order of a hundred masses of which fewer than half typically map (a cytochrome-C
MS2 in the reference data: 117 deconvolved, ~44 mapped). An unassigned mass has an
intensity, a charge envelope and an isolation window like any other, but **no ion
type and no ion index**, so it has no frame to project MS3 sub-fragments back
through. It is therefore addressable as an acquisition target while remaining
un-matchable as evidence.
_Avoid_: "unmatched peak" (pre-deconvolution); "contaminant" or "noise" (an
unassigned mass is frequently a real fragment of a proteoform *other* than the
winner, or of the winner under an unmodelled modification); treating it as a defect
of the identification.

**Unobserved fragment**:
A theoretical fragment ion of the winning proteoform carrying **no Fragment
observation at any MS level** — the exact dual of **Unassigned mass**, and together
with it a partition of the MS2 into measured-unexplained and predicted-unseen. Where
an unassigned mass has an intensity and a measured isolation window but no ion type
and no ion index, an unobserved fragment has an ion type and index but no intensity
and no measured window: **matchable as evidence, addressable only through theory**.
Its absence is a claim scoped to one m/z window over one scan range — "predicted, and
not seen *within the MS2's own scan range*" — so a charge state whose m/z fell outside
that range was never observable and its absence carries no information. Every MS3
target the model selects today is drawn from the complement of this set (a target needs
an MS2 observation to isolate), which is why the middle of a proteoform can be
unreachable: the fragments that span it are all unobserved.
_Avoid_: "missing peak" (pre-deconvolution, and a peak carries no ion identity);
reading absence as proof the cleavage did not occur (dynamic range and charge
partitioning both hide real fragments); conflating it with an **unwitnessed bond** — a
bond can be witnessed by the complementary ion while this ion stays unobserved.

**Caged bond**:
A backbone bond enclosed by an intact cross-link — a disulfide, or the two thioethers of
heme c — so that cleaving it alone releases no free b or y ion: the two halves stay tethered.
A fragment that cuts a caged bond is observable only when the cross-link also breaks, and
then in whichever form the broken link leaves behind. The link's atoms are not shared out
evenly: after a C–S cleavage one cysteine keeps both sulfurs (persulfide, 31.97207 Da above
the linear mass) and the other is left as dehydroalanine (33.98772 Da below); after an S–S
cleavage one side is the thiol at the linear mass and the other the thioaldehyde, 2.01565 Da
lighter; for heme c the whole heme leaves with one cysteine's sulfur and that cysteine becomes
dehydroalanine. Which side keeps the sulfur is decided per cleavage event, so the same fragment
appears in both forms. The two sides of any severed link sum to the link's delta. A fragment
that encloses **both** anchors carries the full delta exactly; the linear ladder, which treats
every Cys as a free thiol, misses it by 2 Da.
_Avoid_: "impossible fragment" (it is observable whenever the link breaks, and how often it
matches is a measurement of link cleavage, not an error); a linear ladder as the only mass;
reading a match on a caged bond as a wrong pairing before comparing it with the chance rate;
assuming the link's atoms split evenly between the two fragments; reading a 1 or 2 Da lighter form as
chemistry before the deconvolution's monoisotope error rate is known.

**Complementary ion pair**:
`b_k` and `y_(L−k)` — the two halves of **one** backbone cleavage of a proteoform of
length `L`. Observing either half proves the cleavage occurred; *which* half is seen is
decided by charge partitioning, not by whether the bond broke. An observed `y_(L−k)` is
therefore direct evidence that `b_k` exists and merely lost the charge to the other
side, which makes it the strongest available evidence about an **Unobserved fragment** —
strictly stronger than the presence of same-series ions nearby. The same relation
already appears one frame down, between an MS3 sub-ion and its complement within the
parent fragment (`FragmentObservation::is_complement_flip`); this is that relation in
the proteoform frame.
_Avoid_: reading a complementary pair as two independent sightings (it is one cleavage
seen twice); assuming the two halves carry comparable intensities.

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
MS3 (MS3 cannot narrow a range nothing spans). A full-length ion (b_L, y_L) contains every range
and is never a container: it is the precursor, not a fragment. See ADR-0005, ADR-0052.
_Avoid_: a fragment that cleaves *inside* `[s,e]` (that is what `narrowModifications_`
matches to *narrow* the range — it cannot be a *target*, since its existence would
already have narrowed the range); the retired legacy intensity-scatter MS3 selection.

**Uncovered bond**:
An inter-residue bond of the winner region that no MS2 fragment of the model witnesses (a b_k
witnesses bond k, a y_k bond L−k).
_Avoid_: uncovered residue (coverage is counted in bonds, not residues).

**Coverage target**:
An observed fragment whose interior — the bonds inside its span — holds at least one
**uncovered bond**. Under `characterization.mode: coverage` every coverage target is acquired,
strongest MS2 intensity first, until `max_targets`; one target never excuses another because
its interior overlaps.
_Avoid_: reading coverage as a set cover (it was one, and stopped at two targets on ubiquitin).

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

**Annotatable MS3 precursor**:
A **Mapped fragment** whose MS3 sub-ions FLASHIda can predict correctly: a **b- or y-ion**, and
nothing else. A c, z, a or x fragment has a frame — a known prefix or suffix span, so it can be a
**Containing fragment** or a **Coverage target** and its MS3 is acquired like any other — but its
MS3 is **acquired and logged, never annotated**: no matched sub-ions, no coverage, no modification
narrowing, no MS3 fold, no piece test. (An MS3 exploration variant's whole-protein match is a
different reading — full-protein ions, right whatever the precursor — and is unaffected.) Annotatability is a property of the targeted
ion's type, never of the activation that produced it: an EThcD MS2 yields b, c, y and z fragments,
and only its b/y targets are annotated. An MS3 exploration sweep on an unannotatable target runs
its configured metric unchanged — under a reading metric every variant scores 0.
_Avoid_: "ETD MS3 is unsupported" (it is acquired; only its annotation is missing); reading an
unannotated MS3 as an empty one (it carries real sub-ions nobody predicted); conflating it with an
**Unassigned mass**, which has no frame at all.

**Isolation window**:
The m/z interval a fragmentation stage transmits — the ions that will be fragmented and whose
products the scan reads out. It is **measured, never derived from theory**: centre and width
come from the observed m/z extent of the selected species at the acquisition charge, widened
by a fixed margin on each side so the envelope is transmitted whole rather than clipped at its
edges. A scan opens one isolation window per **Notch** per stage.
The window a scan was **commanded** to isolate and any window a measurement later sums over are
the same interval. Where the two have drifted apart, the commanded one is authoritative — it is
what decided which ions exist in the spectrum at all, so a measurement summing a narrower
interval is discarding signal it paid to isolate.
The window the instrument **acquires** is a third thing, and not quite the commanded one: the
instrument sets a width on a coarser grid than it accepts, rounding down, so the acquired window
sits on the commanded centre and is narrower by up to one grid step. The margin is several
times wider than that step, so the envelope still arrives whole — but the commanded and the
acquired width are different numbers, and nothing may depend on their being equal.
_Avoid_: "isolation width" as a synonym (the width is one of the window's two numbers; a width
without a centre is not a window); confusing it with the **Scan range**, which is what the
analyzer reads out rather than what the stage transmits; reconstructing a window from a charge
and a theoretical mass; recognising a commanded scan in the data file by its window bounds — a
scan is recognised by its **tracking id**, which is an identity, where a pair of bounds is only
a coincidence waiting to be rounded.

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
final measurement. Example: a CE sweep under the **Kinetic model**, whose pre-scans
measure how the **Precursor share** falls along collision energy so the **Modeled
maximum** can be computed. Pre-scans feed the sweep's decision; the Follow-up MSn is
then acquired at the chosen parameters.
**Whether a sweep also *reads* its pre-scans is a property of its metric, not of the
scans.** A **reading** metric (FragmentCount) matches every variant against the
proteoform to score it, so its pre-scans leave identifications behind as a side
effect. A **measuring** metric (RemainingPrecursor, MassCount, the Kinetic model) only
weighs bulk signal and never matches fragments, so at MS3 its pre-scans leave *no*
evidence whatsoever — which is why a measuring MS3 sweep must always be closed by a
Follow-up MSn. This asymmetry is MS3-only: at MS2 every variant is matched under
every metric, because the whole-protein matcher used there is the right one — with
one exception that belongs to the analyzer rather than the metric, the **Trap
pre-scan**, which is never matched at any level. A sweep acquires **no reference
scan**: the Precursor share needs none (see **Baseline variant**, retired).
_Avoid_: confusing a pre-scan with the production scan it informs; assuming a
completed sweep has produced evidence (a measuring metric produces a *parameter*,
not a measurement); "baseline" (nothing is ratioed against a separate scan any more).

**Trap pre-scan**:
A **Pre-scan** read out by the ion trap rather than the Orbitrap, chosen to make a sweep
cheap. It is **measured, never identified**: unit-resolution peaks cannot enter an
identification that works at parts per million, so a trap pre-scan is neither deconvolved nor
matched, and it contributes nothing to a Precursor's pooled model. The only thing read from it
is raw signal — which is why the **Precursor share** is the one quantity that can score a trap
sweep, and the two metrics built on it (RemainingPrecursor and the **Kinetic model**) the only
ones allowed to decide one. A metric that counts deconvolved masses or matched fragments would
score every variant zero and crown the first. A trap sweep is always closed by a **Follow-up
MSn** on the Orbitrap, and that scan carries all of the sweep's evidence.
_Avoid_: expecting identification rows or pooled evidence from a trap pre-scan; pairing a trap
sweep with a counting metric; treating "measured, never identified" as a property of the
*metric* (that is the reading/measuring distinction above — this one belongs to the analyzer,
and holds under every metric).

**Precursor share**:
The fraction of one scan's signal that is still the isolated species: the raw signal inside the
anchor **Isolation window** over the raw signal of the whole spectrum of that **same scan**.
Both sums carry the scan's ion supply (fill, transmission, whatever state the previous scan left
the optics in), so the supply cancels and no reference scan is needed; an intact precursor reads
about four fifths of its own spectrum, not one. Like the **Remaining-precursor ratio** it
replaces, it is a **single-window** measurement — it reports *one charge state's* depletion, not
the species', which is why it may not decide a sweep whose stage co-isolates several charge
states as **Notches** — and it is read from raw peaks, never from a deconvolution, which is what
lets a **Trap pre-scan** carry it. Recorded on every MSn scan that has an isolation window; at
MS3 the window is the target fragment's. Its symbol is P.
_Avoid_: remaining ratio (the retired quantity, ratioed against a reference scan that no longer
exists); "precursor depletion" without saying of which charge state; TIC fraction (the
denominator is the signal the engine received, not an instrument header); treating a scan's
share as comparable across charge states or species.

**Fragmentation rate**:
The **Precursor share** lost per unit of collision energy, and zero where the share rises.
It is the change of the extent of fragmentation per unit of energy, as the rate of a reaction
is to its extent, and it is what feeds the fragments in the **Kinetic model**. Under that
model it is the derivative of the fitted **Gompertz curve**, so it is defined at every energy,
not only at the acquired ones. Its symbol is s.
_Avoid_: feed, depletion rate, slope (the quantity is a rate of the share, not of a ratio to a
reference scan), precursor loss.

**Gompertz curve**:
The curve fitted to the Precursor shares of a sweep's pre-scans: the share falls from the
**initial precursor share** P₀ toward zero, and its relative fragmentation rate s/P rises
exponentially along collision energy — that rise is the curve's one assumption. Its two other
parameters are the **inflection point**, the energy of the highest Fragmentation rate, where
P₀/e of the share remains, and the **width** w, the energy step over which s/P grows by the
factor e. It is fitted within a fixed box — P₀ at most 1.1 × the highest acquired share, w
between a quarter and twenty-five energy units — on at least three pre-scans with a finite
share; fewer than three, or no convergence, and the sweep has **no fit**. The acquired points
are a fixed grid that always includes both ends of the authored range; nothing about where the
curve falls moves where the next pre-scan is placed.
_Avoid_: sigmoid, logistic, survival-yield curve (a different curve from the literature),
decay fit; CE50 for the inflection point (half the share remains earlier than P₀/e).

**Overfragmentation rate**:
The chance per unit of collision energy that a fragment breaks again — the rate constant k₂ of
the **Kinetic model**, with the unit per NCE. It is **authored**, per activation and per MSn
level, and **never defaulted**: it differs by an order of magnitude between activations and is
unknown wherever no sweep has been measured, so a sweep whose activation has no authored value
is refused at load rather than run with another activation's constant. It is never fitted at run
time; its value comes from offline fits on sweeps of **other** proteins.
_Avoid_: decay constant; overfragmentation ratio (it has a unit); a global k₂; reading the
authored value as something the engine measured.

**Kinetic model**:
The exploration metric that chooses a sweep's energy from the **Precursor share** alone:
fragments are fed at the **Fragmentation rate** and break again at the **Overfragmentation
rate**, and the energy chosen is the **Modeled maximum** of the resulting fragment pool. No
fragment is matched and no target is hit — the decision is a computed energy, which may be one
no pre-scan ran at. It is a **measuring** metric, so it may decide a **Trap pre-scan** sweep and
its pre-scans at MS3 leave no evidence. The branching ratio between fragments and
over-fragmentation only scales the pool, so the chosen energy does not depend on it.
_Avoid_: chain (the deck's word); kinetic metric; "target" (there is nothing to hit); treating
the best-scoring pre-scan as the result (no pre-scan wins under this metric).

**Modeled maximum**:
The energy the **Kinetic model** chooses: the integer collision energy, from one up to the top
of the authored range, at which the modeled fragment pool is largest. It may lie **below** the
first acquired pre-scan — the curve is fitted, not read at grid points — and when it sits at
either end of its range that is recorded, because an edge maximum says the range was placed
wrong. A **Follow-up MSn** is always acquired at it, at every level, since no pre-scan need
have run there. Distinct from the *measured maximum*, where the fragment share actually peaks,
which only an offline analysis with matched fragments can know.
_Avoid_: winner (a winner is a measured variant that scored best; the modeled maximum is a
computed energy), optimum (nothing proves it optimal), measured maximum.

**Baseline variant** (retired):
Formerly a pre-scan that measured one activation's un-fragmented reference, the denominator
of every sibling's **Remaining-precursor ratio**, one per swept activation. It is gone: the
**Precursor share** is referenced against the scan's own spectrum, so no metric reads a
reference scan any more and none is acquired, under any metric or activation. A sweep is
therefore exactly its grid points.
_Avoid_: "baseline" for anything a sweep acquires; assuming a CE-0 point exists unless the
authored grid starts there (then it is an ordinary pre-scan and enters the fit like any other);
expecting the retired per-activation reference behaviour (ADR-0029) anywhere.

**Remaining-precursor ratio** (retired):
Formerly the signal inside a variant's **Isolation window** over the same window's signal in its
activation's **Baseline variant**. Replaced by the **Precursor share**, which keeps everything
this quantity was good for (a single-window, raw-signal, trap-readable measure of one charge
state's depletion) and drops the reference scan. The metric that scored this quantity against a
target keeps its name and its target key and now scores the share, so a target of 0.1 means
"one tenth of the scan's signal is still precursor", not "one tenth of the unfragmented window".
_Avoid_: reading an old target value as if its meaning had not changed; using this term for the
share.

**De-referenced activation** (retired):
Formerly an activation whose **Baseline variant** returned no signal, so its variants were
acquired but could never win. With no reference scan there is nothing to de-reference; a sweep
with too few finite shares has **no fit** instead, and a sweep with no fit emits no Follow-up MSn.
_Avoid_: reading a `-1.0` score as this condition (it now only ever means "not scored", e.g. a
trap pre-scan under a counting metric).

**Follow-up MSn**:
The production MSn scan emitted at the parameters a pre-scan exploration chose (e.g. the
**Modeled maximum**, or the pre-scan whose Precursor share came closest to a target).
Dispatched via the model, and — unlike a pre-scan — identified on the ordinary MSn
path, so it is the scan that actually contributes evidence.
It is emitted when **any** of three conditions holds after the sweep's decision:
- the pre-scans were **degraded** relative to production (**Exploration overrides**
  non-empty), so no variant was acquired at production settings; or
- the sweep's metric never read its pre-scans (**Pre-scan**, a measuring metric —
  MassCount or RemainingPrecursor) and the level is **MS3**. An MS3 sweep that
  leaves no evidence must be closed by a scan that does; or
- the sweep decided by the **Kinetic model**, at **any** level: the chosen energy is computed,
  and in general no pre-scan ran at it, so there is nothing to cascade from.
An MS2 sweep under a measured-point metric is exempt from the second condition: its variants
are already identified, and it cascades to MS3 rather than re-acquiring itself. A sweep with
**no fit** emits no follow-up and the target is not acquired at this level.
_Avoid_: treating follow-up MSn as ad-hoc re-acquisition for a missing fragment —
it is specifically the optimized production scan that *follows* pre-scans; assuming
"overrides empty" implies "no follow-up" (two of the three conditions do not read the
overrides); expecting a follow-up at the authored collision energy when a fit failed (there is
none).

**Exploration overrides**:
The scan settings a sweep's **pre-scans** run under, expressed as a patch on the
level's scan config. Their purpose is to make pre-scans *cheaper* than the real
measurement (lower resolution, fewer microscans), so a sweep costs less than the
production scan it informs. Their presence is therefore also a statement about
fidelity: with overrides, no pre-scan was acquired at production settings, so a
**Follow-up MSn** is mandatory; without them, the pre-scans ran at production
settings and the winner is production-grade — provided the metric read it.
Overrides are optional under **every** metric. A sweep that omits them is making the ordinary
claim — its pre-scans ran at production fidelity — and whether its winner is nonetheless
re-acquired is decided by the **Follow-up MSn** rule (the metric and the level), never by
obliging the author to write a patch. They were once mandatory for a metric that never reads
its pre-scans; that rule existed only to make a window-bound **Scan range** safe, and was
withdrawn with it.
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
its `mode` (`off | ambiguity | coverage | fragments | exhaustive | discriminating`) is the **single
switch** that decides whether MS3 happens at all. The on-values *are* the objectives — containers of
ambiguous modifications, coverage targets, every mapped fragment, every deconvolved mass, the masses
that tell Refine's paths apart — so there is no separate
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

**Key**:
One named entry of `method.json`, addressed by its dotted path (`quantification.identify`,
`ms_settings.ms2.collision_energy`). A key is what the strict loaders accept or reject, what
the schema reference enumerates, and what the key documentation describes. Some keys set a
scan parameter; a key is never itself a parameter.
_Avoid_: parameter (reserved for an instrument parameter a scan carries, as in "scan
parameter" and "source-region parameter"); option, setting, field (the C# property behind a
key, which can differ in name).

## Language — annotation without a search (the Refine method)

The terms of the `refine` annotation method (ADR-0049, Proposed). The owner's fuller glossary for
the publication lives outside the repo; these are the terms the engine needs.

**Annotation method**:
Which of two procedures turns a deconvolved MS2 into a proteoform against the one supplied
sequence: `flashtnt` (sequence tags, extended along the sequence, with blind shifts opened one
fragment at a time) or `refine` (mass shifts detected first over all fragments at an FDR, then a
path of levels aligned through them). The method decides how the model is seeded; it does not
decide whether MS3 happens (that stays with `characterization.mode`).
_Avoid_: identification workflow, search (no sequence database is searched by either), engine.

**Observed matches / Expected matches / Signal**:
For one trial mass shift: Observed is the number of distinct b and y ions of the supplied sequence
that match an observed mass once offset by the shift; Expected is the same count over only the
masses the unshifted ladder already explains, so it holds exactly the internal coincidences (an
unmodified ion also matches every other ion at the mass of the residues between them); the Signal
is Observed minus Expected, never negative. A real mass shift shows as a peak of the Signal.
_Avoid_: expectation in the statistical sense (it is a count on the scan at hand), internal-ion
subtraction (no internal fragment is matched or removed).

**Shuffled sequence**:
The residues of the supplied sequence in random order, run through the same scan by the same
rules. It keeps composition, length and fragment count and loses the fragment masses, which makes
it the decoy of the Cut.
_Avoid_: decoy database, decoy residue (for an unknown shift no residue is impossible).

**Cut**:
The number of ions a peak of the Signal needs to become a level: the smallest count at which the
false discovery rate of such peaks — mean peaks per shuffled sequence over peaks of the Signal — is
at most the authored level (`characterization.refine.fdr`, default 20 %). The report used 50 % so
that MS3 could test the levels; on the corpus scans that let through pairs of chance jumps that buy
three to six ions, and MS3 can only adjudicate them while the true path still ranks second, which
holds at 20 % and not at 50 %. The shuffled sequences are matched once, against the masses the
unshifted ladder does not explain (the single pass): a proteoform whose fragments mostly carry a
shift leaves nearly every mass in the decoy pool and earns a high Cut — a known limit, kept because
a second pass feeds the chance levels of pass one back into the decoys and drops the Cut to the floor.
_Avoid_: threshold without saying where it comes from, ceiling.

**Level**:
What the fragments of one stretch carry: the sum of the mass shifts whose sites lie inside them. It
shows as a peak of the Signal that passes the Cut, and in the spectral alignment it is a diagonal.
0 is a level (where every path starts). A level belongs to the ion types attached to it: b, y or
both. A level need not be a mass shift — on cytochrome c +526.13 Da is the sum of −89.03 and
+615.16, and no fragment carries +615.16 alone. A level one water or one ammonia below 0, or below
a level of higher Signal, is a neutral loss and is not a level. A level one, two or three neutron
masses (1.00335 Da each) away from 0 or from a level of higher Signal is a **neutron satellite**
and is not a level either: it is the same ions deconvolved with the wrong monoisotopic peak (on the
September 2026 cytochrome c scan the true level +657.17 with 16 b ions sits beside +655.14 with 15
and +654.13 with 11). Of the levels left, at most `characterization.refine.max_levels` (default 20)
of highest Signal are kept, ties by the summed intensity of the masses attached, then the smaller
shift; the cap bounds the number of candidate totals, not the answer.
_Avoid_: mass shift for a peak whose steps are not yet known, PTM, fold (the report's Version 75
word for removing such a level; the engine excludes, it never merges).

**Mass shift**:
A step between two consecutive levels of one ion type along the sequence, 0 included. It carries
a mass and a site range, not an identity; naming the modification is an interpretation added
afterwards. A truncation, a substitution, a label and a cross-link are mass shifts too.
_Avoid_: PTM, modification (when the identity is not known), level (a level is a sum of shifts).

**Stretch**:
The residues between two neighbouring mass shifts. Every cleavage site in one stretch gives the
same two sums — its b ion shows the stretch's b level, its y ion the Total shift minus it — so a
stretch is a piece of one diagonal. From one stretch to the next, one mass shift moves from the y
ion to the b ion.
_Avoid_: window (a window is where one shift can sit, between two stretches).

**Total shift**:
The sum of all mass shifts of a path, λk: the level behind the last shift, what the b ion and the y
ion of any one cleavage site show together. It is unknown in advance, so every combination of a b
level and a y level (0 included) is a candidate and is tried in a DP matrix of its own; the
precursor mass is never read to set it.
_Avoid_: precursor mass minus sequence mass (that comparison is the Precursor mass difference),
target.

**Path**:
A sequence of levels from 0 to a Total shift along the supplied sequence; its steps are the mass
shifts; its score is matched ions minus the **jump penalty** (`characterization.refine.jump_penalty`,
default 2; the report wrote 1) times the number of jumps, and the recount after MS3 charges the same
penalty. The best path of each candidate total is a
**candidate proteoform**; the best path of the best total is what an MS2 reports; the best paths
of the two best totals are what MS3 tests.
_Avoid_: solution, alignment (the alignment is the search, a path is one of its results).

**Precursor mass difference**:
The measured precursor mass minus the supplied sequence's mass plus the reported Total shift. Logged
on every annotated scan, never a gate: a large value names a supplied sequence that does not fit
the measured protein, an adduct, or a shift no fragment shows.
_Avoid_: rest, sequence guard (the publication's name for the same comparison), booking it into a
shift.

**Discriminating mass**:
An observed MS2 mass that the best paths of the two best Total shifts explain differently — one
explains it and the other does not, or they name different ions. A mass both paths give the same
ion is shared. Ranked by intensity, it is what MS3 isolates under `characterization.mode:
discriminating`; its pieces (prefixes and suffixes, predicted per path) say which path it holds for,
or, when they fit neither, that it was a false positive such as an internal fragment.
_Avoid_: target (overloaded: targeting modes, target log, the Containing fragment), contested site
(the cleavage sites on which the two paths differ, a different thing).

**Shift-carrying fragment**:
A fragment observed at the mass of a fragment of the supplied sequence plus a non-zero shift. It is
the only kind of fragment, at MS2 or MS3, that counts as evidence for a shift under `refine`. A
fragment observed without the shift counts for nothing, because a labile group leaves without a
trace.
_Avoid_: modified fragment (an identity claim), site-determining ion.

## Language — instrument control

A scan carries **three independent identity channels**. Conflating them is what produced the
contact-closure startup defect and, separately, an acquisition log that its own consumer could
never join — so the three are named separately and deliberately. Two are ours; the third is not.

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
It outlives the acquisition: the scan description is preserved when the data file is converted,
so the tracking id is still readable on the converted spectrum. That makes it the join from a
spectrum back to the **command that caused it** — and, through that command's parent, to the
survey the command was decided from — for every scan FLASHIda commanded, at every MS level.
It identifies a scan only **within its own run**: every run mints from the same starting point,
so the same id names a different scan in every acquisition.
_Avoid_: scan id, Access ID, instrument job number; treating it as unique across runs; assuming
a scan's survey is the survey acquired just before it — commands queue, so newer surveys
routinely sit between a scan and the one it was decided from.

**Instrument scan number**:
The number the instrument itself assigns to a scan as it acquires it. Unlike the other two
channels FLASHIda neither mints it nor asks for it — it exists only on the scan coming *back*.
It survives into the converted data file, as the tracking id also does, but the two join
different things: the instrument scan number places a spectrum in the **acquisition's order**
and exists for every scan, commanded or not, while the tracking id ties a spectrum to the
**command** that caused it and exists only for scans FLASHIda asked for. Neither can stand in
for the other, which is why a log that claimed to carry one while carrying the other was
unusable rather than merely inaccurate.
_Avoid_: scan id, Access ID, tracking id; and "scan index", which names a position within a file
rather than something the instrument assigned; calling it the *only* identity that survives
conversion — it was believed to be, and the belief cost a consumer its exact join.

**Handshake scan**:
The single scan whose echoed **instrument job number** proves the instrument has entered
custom control. Its spectrum is discarded — it is a control signal, not data.
_Avoid_: magic scan (the historical name; it describes the constant, not the purpose).

**Custom control mode**:
The latched state in which FLASHIda drives acquisition. Latching requires the *echo* of the
handshake scan, not merely having sent it. It is **not exclusive**: the instrument goes on
acquiring scans of its own while the latch is set, so belonging to custom control is a property
of *each individual scan*, never of a period of time.
_Avoid_: connected (connection strictly precedes it); acquisition mode; reading the latch as a
window inside which every arriving scan is ours.

**Run clock**:
FLASHIda's own bound on how long it will go on acquiring, authored as `global.duration`. It is
**armed** before the handshake is sent — so a handshake that never echoes still bounds the run —
and **restarted** when that handshake echoes, so the wait for control is not charged against the
run. Expiring is one of three ways a run stops, and the only one that does not depend on the
instrument.
_Avoid_: "duration", which names the config key rather than the clock; "method start", which is
Xcalibur's own independent clock; and "acquisition start" — the instrument's acquisition may open
before or after this clock starts, and deliberately does not gate it (ADR-0043).

**Outstanding command**:
A scan command FLASHIda has submitted that the instrument has not yet executed. Their count is
the acquisition's **depth**, and it is the difference between two things FLASHIda already knows:
what it has sent, and what has come back. Depth above one is outside what the instrument
guarantees — the vendor defines submitting a further command before the previous one has been
dealt with as undefined, and it fails silently rather than erroring, so depth is a quantity that
must be maintained deliberately and can never be inferred from the absence of complaint.
The count is FLASHIda's **belief** about the instrument, not a measurement of it — it is derived
from what was sent and what came back, so a command the instrument declines is believed
outstanding while nothing will ever arrive to discharge it. A belief that runs ahead of reality
is absorbing: it drives the believed depth to its target, the real one to zero, and removes the
arrivals that were the only thing that could correct it. At a stop, outstanding commands are
cancelled rather than awaited.
_Avoid_: conflating it with the engine's own command queue, which is a different queue on the far
side of the bridge and drains in the opposite direction — a command *leaves* the first to *enter*
the second, so "the queue got deeper" is true of one and false of the other at the same moment.

**Acquisition stop**:
The end of the **instrument's** acquisition — the point at which it ends the acquisition it was
performing, in most cases closing a data file. It is not the same event as the **run clock**
expiring, and neither causes the other: the two are independent and either may come first.
FLASHIda observes it rather than commanding it, and treats it as terminal — a run does not
survive the end of the acquisition it was acquiring into.
_Avoid_: "run end", which names FLASHIda's own clock; "shutdown", which names the process;
and reading it as a guarantee of quiet — scans continue to arrive after it.

## Language — kinds of scan

**AGC prescan**:
A short scan acquired solely to **measure ion flux**, so the instrument can set injection times
for the scans that follow it. It carries no analysable data — it is discarded on return rather
than deconvolved — and it is not part of any acquisition decision: nothing is selected from it
and nothing is excluded by it. It is emitted on a **fixed interval**, never as filler for an idle
instrument, so its cadence is a property of the method rather than of how busy the queue happens
to be. Being a measurement of the population, not of a species, it belongs to a whole group of
scans rather than to one.
_Avoid_: "AGC scan" unqualified, which reads as a scan *of* the AGC; **AGC target**, which is a
scan parameter (how much charge to fill to) and not a kind of scan at all; "idle AGC", which named
the filler role this no longer has.

**Idle survey**:
The survey MS1 emitted because **nothing else was waiting** — the acquisition equivalent of a
default, so the instrument is never left without a command. It is an ordinary survey in every
respect except why it exists, and it yields to any real work: it is the lowest-ranked thing the
engine can ask for.
_Avoid_: "idle cycle", which used to name a *pair* of scans and so quietly changes meaning; "AGC
scan", which it never was.

**Uncommanded scan**:
A scan the instrument acquired without FLASHIda having asked for it. It carries none of our
instrument job numbers and no engine-minted tracking id, so it is not analysable and nothing may
be concluded from it. Rare but not exceptional — a handful per run — and it arrives *during*
custom control, not only before it.
_Avoid_: "unsolicited", which suggests we could have declined it; "instrument-method scan", since
the origin is not knowable from the scan itself — internal calibration produces one too.

**Quantification scan**:
The MS2 acquired to **measure reporter ions**, not to sequence anything. Its fragmentation is chosen
for one purpose — releasing the isobaric label's reporter group, which needs collisional activation
— so its fragment ions are a by-product and nothing reads them. It is what a labelled run spends
*first* on every selected precursor — one scan per member of the **acquisition charge set** — and
the only kind of scan in the run that is measured. What one of them produces is a verdict about one
species *as seen through one isolation window*; what the **quantification group** produces is that
species' **consensus verdict**.
_Avoid_: calling the scan a quantification result *buys* the quantification scan — it is the scan
that does the measuring, and the one it buys is an identification scan; assuming an MS2 is a
quantification scan because a run is labelled, which is what makes the distinction from the
identification scan worth having; expecting its reporter region to exist under an activation that
cannot release the label, or in a scan whose mass range begins above it.

**Quantification objective**:
Which quantification verdicts are worth an identification scan — the run's answer to "what am I
here to sequence": only what moved, everything I could measure, everything at all, or nothing.
It is a **cut point on the verdict ladder**, not a list of verdicts, because the verdicts are
ordered by how much is known about the species. Because a quantification scan raises no tags and no
MS3 targets of its own, the objective also decides which species are characterized.
_Avoid_: calling it a *filter on quantification* — every selected precursor is screened either way,
and the objective spends the results rather than restricting them; reading "nothing" as the feature
being off, which is what `quantification.enabled` says.

**Enriched-in condition**:
The condition a species must be **more abundant in** for a differential verdict to count as the
result the run is looking for. Named as one of the two conditions, never as a direction: the ratio's
numerator is whichever condition was declared first, so "up" is only meaningful relative to a
declaration order that is nowhere in sight at the point of use, and reverses if that order changes.
A species absent from one condition entirely is enriched in the other — the extreme case, not an
exception to it — but only when the other condition was measured in **every** one of its channels.
Absence is read against a presence; a condition seen in only some of its replicates is a partial
measurement, so the pair says nothing about which condition holds the species.
_Avoid_: "up-regulated" / "down-regulated", which name a direction rather than a condition and
invert silently; concluding a species was not enriched from the fold change alone, which carries no
finite value when a condition is wholly absent.

**Quantification group**:
Every quantification scan measuring **one species' reporter population** in one survey, together
with the single verdict they reach. One species, one group, whatever the acquisition charge set's
size: co-isolated, the group is one scan measuring the whole set at once; acquired one scan per
charge, it is one scan per member, each measuring the same population through a different window.
The group is what buys an **identification scan** — never a member on its own — so the
identification is bought once however many charge states were spent screening. Pooling reporter
measurements across charge states is sound where pooling **fragments** across them is not: the
reporter ion is released at the same m/z whatever the precursor's charge, so its ratio is a property
of what was in the window rather than of the charge — which is exactly what makes disagreement
between charges meaningful.
_Avoid_: calling it a Precursor (one scan per charge yields several, and the group spans them);
reading it as pooled fragment evidence, which is a different thing and unsound; expecting a group to
reach a verdict before every one of its members has returned.

**Consensus verdict**:
A **quantification group's** single verdict, decided by majority vote over its members' verdicts,
each read *with its direction* — so "differential" alone never counts as agreement when the members
disagree about which condition is enriched. A member that measured nothing usable abstains rather
than dissents. It is the consensus verdict, never a member's own, that the **quantification
objective** cuts on, and the number reported beside it is weighted towards the members carrying the
most ion current, those being the best measured. Too few usable votes is not a verdict about the
species but about the measurement, and reads as one.
_Avoid_: treating a member's verdict as the species' verdict; counting a member that could not be
measured as disagreement; expecting a vote where only one charge state was ever acquired.

**Chimericity**:
Members of one **quantification group** disagreeing about the same species' reporter ratio —
evidence that their isolation windows did not hold the same population, since one clean species must
give the same ratio at every charge. It is the reason to acquire more than one charge state at all.
Disagreement short of a tie is settled by the majority and reported as such: the dissenting member
is discarded rather than averaged in, and is deliberately never the window the identification is
acquired from, because sequencing the interference would attribute the ratio to the wrong molecule.
_Avoid_: reading it as a property of a single scan (it exists only *between* measurements);
"co-isolation", which names an acquisition geometry and not a disagreement; treating a species whose
members disagreed as unmeasured — the majority still carries a result.

**Identification scan**:
The MS2 acquired to **sequence a proteoform** — the ordinary MS2 of every mode, with the
fragmentation the method chose for informative backbone cleavage. It is where tags are found,
where a conditional MS2 is triggered, and where MS3 targets are picked; it means the same thing and
carries the same marker in every mode. What changes between modes is only *when* it fires: normally
once per selected precursor, and in a labelled run only for the precursors whose quantification
verdict satisfies the run's quantification objective.
_Avoid_: treating "the default MS2" as a statement about dispatch — it names the scan's job, not
its unconditionality; supposing an identification scan is skipped because a species was
uninteresting, when it may simply not have been measured yet, or may have been measured and found
uninteresting *in a direction the objective did not ask for*.

**Monitor scan**:
An MS1 acquired during a **sweep** solely so the operator can watch the *source* — spray stability,
contamination, whether the sample is still eluting at all. It is **observed and never acted upon**:
it is deconvolved and its masses recorded, but nothing is selected from it, nothing is excluded by
it, and no later acquisition decision reads anything it wrote. That neutrality is what makes it safe
to insert into a sweep at all — a sweep's variants are measurements of *one eluting precursor*, and
an ordinary survey landing between them would both consume the budget and shift what the run does
next. It exists because a sweep suppresses surveys completely, so a long one leaves the operator
blind for its whole duration. Being a picture of the source rather than an observation of a species,
it belongs to no **Precursor** and enters no **acquisition memory**.
_Avoid_: any name containing *survey* — a survey is the scan acquisition decisions are made from,
and this one makes none; reading its deconvolved masses as evidence about a species, or as grounds
for having detected one; expecting it in `ida.log`, which is the record of decisions; confusing it
with a **pre-scan**, which is also not kept as a final measurement but *is* read, and by the engine.

## Language — scan configuration

**Scan config**:
One fully-specified set of instrument parameters for a scan (analyzer, resolution, AGC,
injection time, mass range, activation and its parameters). Every one lives under
`ms_settings` — `ms1`, `ms2`, `ms2_quant`, `ms3` (bare objects) and any number of named entries in
`additional_ms2` — and means the same thing at every one of them: **the config fully
determines the scan's instrument parameters**. The `tagging.follow_up_scan` key is not a
scan config; it is a *reference* to one (ADR-0014). For an
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
EThcD / ETciD, and `reaction_time` + `reagent_max_it` + `reagent_agc_target` for ETD / EThcD /
ETciD (the ion–ion reaction settings). `ETciD` is the one spelling (PSI-MS MS:1003182, and
what the instrument's method editor shows); `EtCID` is not. Carrying one activation's coupled parameters onto a scan using a
different activation is incoherent — e.g. an HCD scan has no reagent and nothing to react.
_Avoid_: "ETD settings" (they also apply to EThcD and ETciD); treating reaction time as a generic
scan parameter.

**Follow-up scan**:
A second MS2 of a precursor already fragmented, dispatched from the regular-MS2 path because
something **found in the returning scan** justified spending another — an identification scan
(`'R'`, bought when the quantification screen's verdict satisfied the objective) or a conditional MS2 (`'C'`,
bought when sequence tags were found). The trigger is always a measurement of the scan that
returned, never a property known when it was queued; a follow-up is what a result *buys*. It
inherits the precursor's identity, targeting, scoring and FAIMS CV from the triggering MS2, and
takes every instrument parameter from its own scan config. Depth is exactly one.
_Avoid_: "second MS2" (exploration variants are also second MS2s but are not follow-ups); reading
the key that names one as naming a *kind* of scan — `tagging.follow_up_scan` is the scan tagging
causes, not "a tagging scan", and the same grammar governs everywhere; expecting a block that only
backs a follow-up to also fire unconditionally — it is deliberately absent from the dispatch
roster, and that absence is the whole mechanism.

**Scan range** (a.k.a. scan bounds):
The m/z interval the analyzer reads out, bounding the spectrum a scan returns. Orthogonal to the
**Isolation window**: the window decides which ions are transmitted and fragmented, the range
decides which of the resulting ions are recorded. Neither narrows the other, and neither changes
how many ions were injected. Unset means "use the instrument method default".
The asymmetry is what makes it safe to reason about: a range **wider** than the interval a
measurement reads costs only time, because the surplus peaks fall outside the summed interval
and contribute nothing; a range **narrower** than it silently truncates the measurement. So a
range may be padded freely and clipped never.
A **Pre-scan** has no range of its own: it reads out its level's configured range, like any
other scan parameter, unless its **Exploration overrides** name another. That holds even for a
pre-scan whose measurement reads a single **Isolation window**.
On a trapping analyzer that scans m/z sequentially, only the *readout* part of a scan's duration
scales with the range — injection, isolation, activation and fixed overhead do not — so
narrowing the range buys far less than the ratio of the two widths suggests. Bounding a
pre-scan to the window it reads was tried on that premise and withdrawn: it gave no worthwhile
gain on the instrument, and it discarded the rest of the spectrum.
_Avoid_: "mass range" (these are m/z; the deconvolution mass bounds are a different quantity in
different units); "full range" without saying full *relative to what* (it means the level's
configured range, not the analyzer's limit and not unset); assuming a narrowed range narrows the
isolation, reduces the injected population, or changes AGC; estimating a trapping analyzer's
scan time from its range width alone; reading a range of zero as a real setting — for this
parameter, unset genuinely means unset.

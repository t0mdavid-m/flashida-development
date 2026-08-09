# 0016. Co-isolated charge states are one detection

Status: Accepted (2026-08-09), **not yet implemented**. Narrows a prohibition recorded in
`CONTEXT.md`'s **Precursor** entry and scopes the ceiling in its **Charge ceiling** entry; both were
rewritten when this was accepted.

## Context

`CONTEXT.md` stated as settled domain law that a Precursor *"is detected **once** at MS1 at a single
**representative charge**"*, that *"**one charge state's** evidence feeds the proteoform model"*, and
— flatly — that *"Coverage is deepened by **MS3**, not by acquiring multiple charge states."* Its
`_Avoid_` list named the reason: *"pooling MS2 from different charge states of the same mass (an
artifact of deferred exclusion — the same molecule re-selected at charges 8/10/15 — which produced
physically-impossible MS3 charge pairings)"*.

That prohibition is right about the failure it was written for and wrong as a general rule, because
it conflates two different things:

- **Separate detections** of one mass at different charges, each an independent selection, whose MS2
  evidence was then pooled under a nominal-mass key. An MS3 target derived from the charge-15 scan
  could be paired with a charge-8 `stage[0]` — physically impossible. The fix was making
  `precursor_id` the model key instead of nominal mass (`ProteoformTracker.h`: *"so a fragment can
  never out-charge its precursor"*).
- **Co-isolated charges within one detection** — several charge states of one species isolated
  together in a single scan, one isolation event, one spectrum, one `precursor_id`. The pairing
  failure cannot arise: the charge that produced a fragment was present in the isolation.

The prohibition, written for the first, forbade the second. Published evidence says the second is
worth having: Lu, Scalf, Shortreed & Smith, *"Mesh Fragmentation Improves Dissociation Efficiency in
Top-down Proteomics"*, JASMS 32(6):1319–1325, 2021, doi:10.1021/jasms.0c00462, co-isolates one
proteoform's charge states (`MetaDrive`, `ChargeEnvelop.mzs_box` — one m/z per selected charge state
of a single proteoform) and reports improved dissociation efficiency. Its second axis is stepped
collision energies, which FLASHIda already has as the exploration CE sweep.

## Decision

**The unit of acquisition is a Precursor's *acquisition charge set*, not a single charge.** The set
is size one by default — the representative charge. Membership is SNR-gated: a charge joins only if
`getChargeSNR(charge) >= snr_threshold`, the gate that already exists at
`PrecursorSelection.cpp:594` with `snr_threshold` defaulting to `1.0`. A charge below noise still
consumes part of the scan's ion budget, so admitting it is a net loss.

**The prohibition is narrowed, not lifted.** Pooling across *separate detections* at different
charges stays forbidden. Co-isolating charges *within one detection* is sanctioned, and the two are
distinguished in the glossary so the boundary is explicit rather than remembered.

**The charge ceiling becomes the maximum of the acquisition charge set** rather than *the*
precursor's charge. It stays valid by construction, for a reason that has to hold for the whole
design to be sound: an MS3's `stage[0]` replays the MS2 context's charge set (ADR-0003's copy),
so the charge that produced a fragment is present again when that fragment is re-isolated. Using
the anchor charge as the ceiling instead would discard real fragments.

## Consequences

**Three `CONTEXT.md` claims became false and were rewritten**: the single-representative-charge
detection, "one charge state's evidence", and "coverage is deepened by MS3, not by acquiring
multiple charge states". Four terms were added — **Acquisition charge set**, **Anchor charge**,
**Charge-keyed exclusion**, **Notch** — because the scalar→set change is only safe if the vocabulary
distinguishes what a scan *isolates* from what it is *keyed by*.

**The ceiling weakens from an equality to an upper bound over a set.** A fragment at charge 16 is
now admissible whenever any co-isolated charge reaches 16, so the constraint no longer pins fragment
charge to one precursor charge. This is the real cost of the decision and it is accepted: the
alternative — ceiling at the anchor — throws away fragments of the higher-charge members that were
genuinely isolated.

**Two pre-existing statements in `CONTEXT.md` were already inaccurate** and were corrected in the
same pass. Charge-keyed exclusion (`precursor_selection.charge_based_exclusion`) has always allowed
a mass to be re-selected at another charge, so *"never re-detected/re-selected (in particular not at
a different charge state)"* described only the mass-keyed default path.

**MS2 co-isolation buys fragmentation diversity, not signal.** On tribrids `MaxIT` is a single
scalar and MSX performs N *sequential* fills sharing one ion budget with equal injection time per
notch, so the neutral fragment signal after deconvolution is unchanged — different charge states
cleave differently at one NCE, and that is the gain. MS3 co-isolation (synchronous precursor
selection) is one simultaneous waveform and is additive at no time cost. Success criteria for the
two levels are therefore different, and MS2's must not be stated as sensitivity.

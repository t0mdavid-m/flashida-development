# 0006. Winner-anchored fragment pooling: non-winner scans re-match against the winner ladder; MS3 scores against the live winner

Status: Accepted (2026-07-09)

## Context

The pooled proteoform model (`ProteoformTracker`) picks one winner scan (highest FLASHExtender
score) and reports its proteoform, but then pooled **every** staged scan's already-matched
fragments onto the winner frame, carrying each scan's **own** theoretical mass verbatim
(`mapScanOntoModel_`: `obs.theoretical_mass = fm.theoretical_mass`). Each staged scan's match was
computed against **that scan's own proteoform hypothesis**, so the pooled table could contain
fragments and theoreticals belonging to a *different* proteoform than the reported ProForma. This
inflated `coverage_pct` / `n_fragments` with fragments that don't belong to the reported species and
made the row **not reproducible** by external top-down tools (ProSight/TDPortal): the reported
ProForma could not regenerate its own reported fragment masses. The same flaw applied to MS3, which
was matched against the *triggering* scan's `ProteoformContext`, not the winner.

## Decision

- **Trust the winner (augment, not replace).** The winner scan's own FLASHTnT-matched fragments are
  pooled verbatim — FLASHTnT did the heavy lifting for that scan.
- **Re-match non-winner MS2 scans against the winner ladder.** A non-winner MS2 scan contributes by
  matching its **raw deconvolved masses** (`PendingScan.peaks`) against the winner theoretical ladder
  (`FragmentAnalysis::computePTMAdjustedFragmentMasses` on the winner region). A mass becomes a
  fragment only if it lands **uniquely** on one winner ion. Theoretical is the winner's *by
  construction*; the pooled table is self-consistent and ProSight-reproducible.
- **Matching rules (a mass is dropped unless it maps cleanly):**
  - no winner-ladder match → **dropped**;
  - a new winner position → new fragment (coverage ↑);
  - a position the winner already has → merged into the same key; `best_ms2` stays the
    highest-intensity observation across scans (drives MS3 stage-0 params);
  - a bracketing mass within tolerance of **both** base and base+shift → **dropped** (too ambiguous);
  - within tolerance of **≥2 distinct** winner ions → **closest-ppm** wins.
- **MS3 scores against the LIVE winner.** A new `ProteoformTracker::buildWinnerProteoformContext(pid)`
  renders the current (narrowed-so-far) winner model — region + **all** modifications, localized *and*
  ambiguous — as the `ProteoformContext`. It replaces the triggering-scan context at **both** MS3
  build sites (production return and exploration variants), discharging the standing
  `@Claude … move into ProteoformTracker` TODOs. Empty context when there is no finalized winner ⇒
  MS3 matches nothing.
- **Narrowing is unchanged; MS2 stays authoritative.** Merged fragments land as `best_ms2` and flow
  into the existing `narrowModifications_` Pass A (per-mod base-vs-shift). MS3 remains Pass B —
  subordinate, tighten-only, never reversing an MS2-set boundary — and MS3-only fragments are never
  scheduled for fragmentation.
- **No ABI change.** No `ScanCommand` field is added; the 2048-byte struct and the five bridge exports
  are untouched.

## Consequences

`coverage_pct` / `n_fragments` now count only winner-consistent fragments, so pooled goldens for
multi-MS2 exploration modes and every MS3-bearing mode change (values, not columns), and the MS3
context swap also moves the per-scan `identification.tsv` MS3 rows and the `scan_commands`
`ms3_proteoform` cell. In CE-sweep exploration modes the augment can alter which MS3 targets fire
(real acquisition), because `planNextScans` selects from the winner-consistent fragment pool. Goldens
are recaptured only after a manual golden-diff review and explicit sign-off. FLASHDeconv / FLASHTnT /
FLASHExtender remain untouchable.

# 0001. Direct-infusion Precursor scope: key on nominal integer mass, whole-run lifetime

Status: Accepted (2026-06-24)

## Context

The per-Precursor proteoform-tracking model needs a stable identity to pool MS2/MS3
evidence across scans. FLASHIda has no `Precursor` entity today — identity flows
only through per-scan tracking ids and `parent_scan_id` back-references
(`ScanCommand.h:66,104`), and the one piece of per-scan state (`pending_scan_map_`)
is erased when `processScan` returns. Pooling across scans requires a key that two
different scans can agree on.

## Decision

A **Precursor is keyed solely on its nominal integer mass** —
`round(monoisotopic_mass × 0.999497)` (`SpectralDeconvolution::getNominalMass`,
`SpectralDeconvolution.cpp:79`), the same key DDA mass-exclusion already uses.
Charge states fold into one Precursor (mass only, not mass+charge); there is **no
RT and no FAIMS component** in the key. Under a **direct-infusion assumption** — we
do not run MS2 exploration or MS3 at LC-MS timescales yet — a Precursor lives for
the **entire run with no eviction or TTL**.

## Why / Consequences

This deliberately trades LC robustness for simplicity. A mass-only, never-evicted
key is trivial to implement and reason about under direct infusion; a chromatographic
deployment would need an RT/charge component and an eviction policy, and co-eluting
near-isobaric species could collide in one bucket. Recorded so a future LC-capable
design treats the missing RT/charge/eviction as a known scope cut, not an oversight.

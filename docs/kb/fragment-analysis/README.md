---
title: Fragment Analysis Packet
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-10-13
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:733         # Mode 1 entry: conditional follow-up gate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1304  # Mode 2 entry: computeFragmentMatch_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:568   # Mode 3 entry: scoreCalibratedVariants -> calibrateAndScore
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:76    # ProteoformMatch struct
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:949  # characterization.method switch (Refine vs FLASHTnT)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:65   # ProteoformContext struct
see_also:
  - ../exploration/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../config-flow/README.md
---

## Overview

FLASHIda's fragment-matching machinery (`FragmentAnalysis`, `MS3FragmentMatcher`, `Refine`) drives four distinct acquisition contexts. This packet covers each mode's integration points — where they wire in, what functions they call, what data flows — plus the shared data model they all return.

The four modes live in one packet because they share `FragmentAnalysis::ProteoformMatch` as the unified result type. Which annotator fills it on an MS2 is `characterization.method`'s choice (ADR-0049): `flashtnt` (the default; the tag-matching functions below) or `refine`, switched in exactly one place, `FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.cpp:949`). They live *outside* `../exploration/` because tag+follow-up is not an exploration path.

## Four-mode map

| Mode | Entry point | Purpose |
|---|---|---|
| Tag + follow-up | `FLASHIda.cpp:733` | After MS2, if the precursor tag-matches the configured protein, enqueue a conditional follow-up MS2 scan |
| MS2 matching | `Exploration.cpp:1304` (`computeFragmentMatch_`) | Populate `ProteoformMatch` for an exploration variant (every metric at MS2; the `FragmentCount` score) |
| MS3 matching | `Exploration.cpp:568` (`ProteoformTracker::scoreCalibratedVariants` → `MS3FragmentMatcher::calibrateAndScore`) | Two-pass calibration + tight rematch, batch-re-score MS3 variants post-all-received |
| Refine + discriminating MS3 | `FragmentAnalysis.cpp:794` (`runRefineMatching_`); round in `ProteoformTracker` | Annotate the MS2 by detected shift levels + one DP per total; under `mode: "discriminating"` spend one MS3 round on the masses the two best totals explain differently, then decide |

## Ion-type reference

MS2 ion types, selected per fragmentation method via `FragmentAnalysis::getIonTypesForFragmentationMethod` (`FragmentAnalysis.h:168`):

| Fragmentation method | MS2 ion types |
|---|---|
| HCD, CID | `b`, `y` |
| ETD | `c`, `z` |
| EThcD, ETciD | `b`, `c`, `y`, `z` |
| UVPD | `a`, `b`, `c`, `x`, `y`, `z` |
| Any other / unknown | `b`, `y` (default) |

MS3-local ion types, selected per precursor-fragment class via `MS3FragmentMatcher::getMS3IonTypes` (`MS3FragmentMatcher.h:89`):

| Precursor fragment class | MS3-local ion types |
|---|---|
| `a` / `b` / `c` — N-terminal subsequence | `a`, `b`, `yb`, `ya` |
| `y` / `x` / `z` — C-terminal subsequence (also default) | `a`, `b`, `y` |

The cross-direction ion types (`yb`, `ya`) are MS3-only and only appear for N-terminal-subsequence precursors (`a`/`b`/`c`). They carry no water loss.

**Only a `b` or `y` precursor is annotated** (ADR-0054, `MS3FragmentMatcher::isAnnotatableMs3Precursor`). The table reads `c`/`a` as if they were `b` and `z`/`x` as if they were `y`, so for those classes it predicts the sub-ions wrong (a `c` precursor's `yb`/`ya` ~17 Da low). Their MS3 — what an ETD, EThcD, ETciD or UVPD MS2 feeds — is acquired and logged but `calibrateAndScore` and `Refine::pieceTest` match nothing for it, and the regular MS3 return prints `[MS3-UNANNOTATED]`. They still have a frame (`isKnownIonClass`), so they are targeted like any other fragment.

## Read Order

1. [data-model.md](data-model.md) — `ProteoformMatch`, `FragmentMatch`, `PTMSite`, `toProForma`, MS3-local types.
2. Whichever mode you need:
   - [tag-follow-up.md](tag-follow-up.md) — Mode 1.
   - [ms2-matching.md](ms2-matching.md) — Mode 2.
   - [ms3-matching.md](ms3-matching.md) — Mode 3.
   - [refine.md](refine.md) — Mode 4 (ADR-0049).
3. [pooled-vs-nonpooled-log-semantics.md](pooled-vs-nonpooled-log-semantics.md) — how `identification.tsv` (per-event) and `pooled_identification.tsv` (cumulative winner-anchored) relate; the by-design seams (n_fragments vs array length, raw vs frame masses, coverage/nominal-mass definitions, `flash_extender_score`).

## Out of Scope

- FLASHTagger / FLASHExtender algorithm internals — named and referenced, but internals (tag generation, sequence extension, PTM localization algorithm) are not explained here.
- Theoretical-mass calculation internals — only the "what" and "when" of computation; the "how" is deferred.
- Calibration math beyond the two-pass description (loose → tight; median ppm error → correction factor).
- Quantification (`FLASHIda.cpp:682`, marker `'Q'`) — tag-independent, and after ADR-0038 no longer a "follow-up" at all: `ms_settings.ms2_quant` is ROSTERED per precursor and measured, and what it buys is the ordinary `'R'` identification scan. **Which verdicts buy is authored** (`quantification.identify`, ADR-0039): `differential` (the default, and ADR-0038's behaviour) | `quantified` | `all` | `none`, refined for the differential case by `quantification.enriched_in`. Deferred to a future quantification packet.
- Deconvolution internals — upstream subsystem; separate packet candidate.

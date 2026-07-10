---
title: Fragment Analysis Packet
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:914         # Mode 1 entry: conditional follow-up gate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:793   # Mode 2 entry: computeFragmentMatch_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400   # Mode 3 entry: calibrateAndScore call
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:69    # ProteoformMatch struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:58   # ProteoformContext struct
see_also:
  - ../exploration/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../config-flow/README.md
---

## Overview

FLASHIda's fragment-matching machinery (`FragmentAnalysis`, `MS3FragmentMatcher`) drives three distinct acquisition contexts. This packet covers each mode's integration points — where they wire in, what functions they call, what data flows — plus the shared data model they all return.

The three modes live in one packet because they share `FragmentAnalysis::ProteoformMatch` as the unified result type and use the same underlying tag-matching functions. They live *outside* `../exploration/` because tag+follow-up is not an exploration path.

## Three-mode map

| Mode | Entry point | Purpose |
|---|---|---|
| Tag + follow-up | `FLASHIda.cpp:914` | After MS2, if the precursor tag-matches the configured protein, enqueue a conditional follow-up MS2 scan |
| MS2 matching | `Exploration.cpp:793` (`computeFragmentMatch_`) | Populate `ProteoformMatch` for the `FragmentCount` exploration metric |
| MS3 matching | `Exploration.cpp:400` (`calibrateAndScore`) | Two-pass calibration + tight rematch, batch-re-score MS3 variants post-all-received |

## Ion-type reference

MS2 ion types, selected per fragmentation method via `FragmentAnalysis::getIonTypesForFragmentationMethod` (`FragmentAnalysis.h:100-104`):

| Fragmentation method | MS2 ion types |
|---|---|
| HCD, CID | `b`, `y` |
| ETD | `c`, `z` |
| EThcD, EtCID | `b`, `c`, `y`, `z` |
| UVPD | `a`, `b`, `c`, `x`, `y`, `z` |
| Any other / unknown | `b`, `y` (default) |

MS3-local ion types, selected per precursor-fragment class via `MS3FragmentMatcher::getMS3IonTypes` (`MS3FragmentMatcher.h:71`):

| Precursor fragment class | MS3-local ion types |
|---|---|
| `a` / `b` / `c` — N-terminal subsequence | `a`, `b`, `yb`, `ya` |
| `y` / `x` / `z` — C-terminal subsequence (also default) | `a`, `b`, `y` |

The cross-direction ion types (`yb`, `ya`) are MS3-only and only appear for N-terminal-subsequence precursors (`a`/`b`/`c`). They carry no water loss.

## Read Order

1. [data-model.md](data-model.md) — `ProteoformMatch`, `FragmentMatch`, `PTMSite`, `toProForma`, MS3-local types.
2. Whichever mode you need:
   - [tag-follow-up.md](tag-follow-up.md) — Mode 1.
   - [ms2-matching.md](ms2-matching.md) — Mode 2.
   - [ms3-matching.md](ms3-matching.md) — Mode 3.
3. [pooled-vs-nonpooled-log-semantics.md](pooled-vs-nonpooled-log-semantics.md) — how `identification.tsv` (per-event) and `pooled_identification.tsv` (cumulative winner-anchored) relate; the by-design seams (n_fragments vs array length, raw vs frame masses, coverage/nominal-mass definitions, `flash_extender_score`).

## Out of Scope

- FLASHTagger / FLASHExtender algorithm internals — named and referenced, but internals (tag generation, sequence extension, PTM localization algorithm) are not explained here.
- Theoretical-mass calculation internals — only the "what" and "when" of computation; the "how" is deferred.
- Calibration math beyond the two-pass description (loose → tight; median ppm error → correction factor).
- Quantification follow-up mode (`FLASHIda.cpp:900-908`, suffix `'F'`) — sibling mechanism, tag-independent; deferred to a future quantification packet.
- Deconvolution internals — upstream subsystem; separate packet candidate.

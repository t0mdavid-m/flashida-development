---
title: MS2 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753    # hasExploration(2) branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760    # initiate(2, ...) call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:836    # isExplorationVariant routing on MS2 results
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115   # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:189   # queue.buildMS2 variant build
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229   # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:477   # queue.buildMS2 production scan from winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504   # initiateNextLevel definition (MS3 cascade)
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms3-exploration.md
  - ../ms1-acquisition/precursor-selection.md
---

## Trigger

MS2 exploration is triggered from MS1 precursor selection. After `PrecursorSelection::filterAndRank` picks precursors for this MS1 cycle, each selected precursor is routed through the branch at `FLASHIda.cpp:753`: if `config_.hasExploration(2)` is true, the engine calls `Exploration::initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx)` at `FLASHIda.cpp:760` *instead of* the direct `queue_.buildMS2` path. The two paths are mutually exclusive per scan cycle.

## Context plumbing

The `ms_ctx` argument is a pointer to `ms1_ctx`, the `ScanCommand` that produced the MS1 scan feeding this selection. It provides parent-scan tracking so returning variants correlate with the MS1 that begat them. MS2 exploration carries no fragment-level context — the precursor came from MS1 deconvolution; there is nothing "more specific" to target.

## Variant construction

Inside `Exploration::initiate` (`Exploration.cpp:115`), each variant's scan command is built via `queue.buildMS2(pg, charge, variant_config, expl_priority)` (`Exploration.cpp:189`). Each variant gets a unique tracking ID that later routes results back via `feedResult`. After winner selection, a separate production MS2 scan is built with another `queue.buildMS2` call at `Exploration.cpp:477` — but only when the level's `overrides` map is non-empty (see `scoring-and-winner.md` for emission-gate semantics).

## Result routing

When an MS2 scan completes and is surfaced to `FLASHIda::processScan`, the check at `FLASHIda.cpp:836` (`if (exploration_.isExplorationVariant(tracking_id))`) diverts it from the normal MS2 result path into `Exploration::feedResult` (`Exploration.cpp:229`). Ordinary MS2 results continue through the regular handler.

## Handoff / MS3 cascade

Once an MS2 group completes and the winner is selected, `feedResult` calls `Exploration::initiateNextLevel(2, ...)` (`Exploration.cpp:504`) if MS3 is configured on the next level. The MS3 branch is shared with the non-exploration MS2 path — both callers of `initiateNextLevel` converge on the same setup code. See `ms3-exploration.md`.

## MS2-specific pitfall

Exploration does not re-rank or filter precursors. Every precursor that `filterAndRank` selected gets its own group; exploration operates downstream of selection. The selection metric (intensity / mass / charge / tqscore) and the exploration metric are orthogonal — changing the exploration metric does not change which precursors are chosen.

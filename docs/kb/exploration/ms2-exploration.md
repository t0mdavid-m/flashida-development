---
title: MS2 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-09-22
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:488    # isExplorationVariant routing on MS2 results
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:500    # scan_results row reads explorationDeconvMassCount()
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:167   # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:357   # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:397   # trap pre-scan: measured_only (ADR-0045)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:771   # post-winner production scan gate
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

Inside `Exploration::initiate` (`Exploration.cpp:167`), each variant's scan command is built via `queue.buildMS2(pg, charge, variant_config, expl_priority)` from `scans[0]` patched by the level's `overrides`. **A pre-scan has no scan range of its own**: it reads out `ms_settings.ms2`'s `first_mass`/`last_mass` unless the overrides name another (ADR-0044; ADR-0026's narrowing of a `remaining_precursor` pre-scan to its ~2 Th isolation window was withdrawn — it bought no scan time on the trap and discarded the rest of every spectrum). Each variant gets a unique tracking ID that later routes results back via `feedResult`. After winner selection, a separate production MS2 scan is built from the **un-overridden** `scans[0]` — only when the level's `overrides` map is non-empty at MS2 (`Exploration.cpp:771`; see `scoring-and-winner.md`).

### Trap pre-scans (ADR-0045)

`"overrides": {"analyzer": "IonTrap", …}` puts the sweep on the ion trap. Such a variant is **measured, never identified**: `feedResult` reads the variant's own command (`Exploration.cpp:397`) and skips deconvolution, matching and the tracker feed, reading only the precursor-window sum. Consequences for this level: the sweep must use `remaining_precursor` (refused at load otherwise), the `scan_results` row of an `E` variant carries `mass_count 0` and empty `deconv_*` columns (`FLASHIda.cpp:500` reads accessors that report nothing after a measured-only feed), no trap variant appears in `identification.tsv` or a pooled model, and the Orbitrap follow-up carries all of the sweep's evidence. Golden: `exploration_iontrap`.

## Result routing

When an MS2 scan completes and is surfaced to `FLASHIda::processScan`, the check at `FLASHIda.cpp:488` (`if (exploration_.isExplorationVariant(parent_tracking_id))`) diverts it from the normal MS2 result path into `Exploration::feedResult` (`Exploration.cpp:357`). Ordinary MS2 results continue through the regular handler.

## Handoff / MS3 cascade

Once an MS2 group completes and the winner is selected, `feedResult` calls `Exploration::initiateNextLevel(2, ...)` (`Exploration.cpp:504`) if MS3 is configured on the next level. The MS3 branch is shared with the non-exploration MS2 path — both callers of `initiateNextLevel` converge on the same setup code. See `ms3-exploration.md`.

## MS2-specific pitfall

Exploration does not re-rank or filter precursors. Every precursor that `filterAndRank` selected gets its own group; exploration operates downstream of selection. The selection metric (intensity / mass / charge / tqscore) and the exploration metric are orthogonal — changing the exploration metric does not change which precursors are chosen.

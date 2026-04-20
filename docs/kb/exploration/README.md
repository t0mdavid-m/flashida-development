---
title: Exploration Packet
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753    # MS1 -> MS2 exploration branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760    # MS2 exploration.initiate call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927    # non-exploration MS2 -> MS3 initiateNextLevel call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115   # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229   # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504   # initiateNextLevel definition
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
---

## Overview

Exploration runs an autonomous CE/RT/activation sweep per selected precursor (MS2) or per selected fragment (MS3); returning variants are scored with a configurable metric and the winner drives the production scan. Both levels share the same state machine — variant enumeration, async result collection, scoring, winner selection. Level-specific behavior (what triggers exploration, what context it carries, what happens post-winner) lives in the per-level files.

## Read Order

- `exploration.md` — shared lifecycle, state machine, per-level config surface, validation, gotchas.
- `variants-and-sweeps.md` — how variants are enumerated from CE/RT/activation axes; `ExplorationVariant` field reference.
- `scoring-and-winner.md` — per-metric scoring (`MassCount` / `RemainingPrecursor` / `FragmentCount`), winner selection, `overrides` application.
- `ms2-exploration.md` — triggered from MS1 precursor selection; handoff to MS3.
- `ms3-exploration.md` — two trigger paths; fragment-ion targeting; `MS3FragmentMatcher` batch re-scoring.

## Entry Points

- MS1-triggered MS2 exploration: `FLASHIda.cpp:753` (branch) -> `FLASHIda.cpp:760` (`Exploration::initiate(2, ...)` call).
- Non-exploration MS2 -> MS3 exploration: `FLASHIda.cpp:927` (`Exploration::initiateNextLevel(2, ...)` call from the non-exploration result path).
- Exploration-winner -> next level: `Exploration::feedResult` (`Exploration.cpp:229`) calls `initiateNextLevel` (`Exploration.cpp:504`) when the winning variant has MS3 configured.

## Related Packets

- `../config-flow/` — how the JSON keys (`ms_settings.ms2.exploration`, `ce_min`, `activations`, `overrides`, `exploration_tolerance_ppm`) get from `method.json` into `MSLevelConfig`.
- `../ms1-acquisition/` — precursor selection and targeting are upstream; exploration does not re-rank, it optimizes fragmentation conditions for precursors that selection already picked.

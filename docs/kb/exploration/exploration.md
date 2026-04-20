---
title: Exploration — Lifecycle and State Machine
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65    # ExplorationVariant struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:100   # ExplorationGroup struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178   # initiate decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:200   # initiateNextLevel decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115         # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504         # initiateNextLevel definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59         # ExplorationMetric enum
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:100        # MSLevelConfig::exploration field
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:422              # Config::validate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:494              # Config::hasExploration
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753                     # MS1 -> MS2 exploration branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760                     # MS2 initiate call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927                     # non-exploration MS2 -> MS3 initiateNextLevel call
see_also:
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
  - ../config-flow/README.md
---

# Exploration — Lifecycle and State Machine

## Overview

Exploration is a sweep-and-pick strategy for fragmentation parameters. Operators typically do not know ex ante which collision energy (and activation type, and RT window) best fragments a given precursor — the answer depends on mass, charge, modification state, and secondary structure. Rather than committing to one guess, exploration schedules several candidate scans across a parameter grid, scores the returned spectra against an operator-chosen metric, and promotes the best variant to a production scan.

Both MS2 and MS3 exploration share the same algorithm, the same state machine, and the same `Exploration` class. What differs per level is only the trigger (what selected target enters `initiate`) and the post-winner handoff (what happens to the winner's deconvolved result). See `ms2-exploration.md` and `ms3-exploration.md` for the per-level specifics.

## Lifecycle

One exploration cycle walks the following states, each keyed to a call site:

- **Initiate.** `Exploration::initiate(msn_level, ...)` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115`, declared at `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178`) is called once per target — per selected precursor for MS2 exploration, per selected fragment for MS3 exploration. It constructs an `ExplorationGroup` (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:100`), enumerates variants along the configured CE × RT × activation axes into `ExplorationVariant` entries (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65`), and returns the list of scan commands for the caller to enqueue.

- **Dispatch and return.** The caller enqueues the commands on the scan queue. Variants run on the instrument asynchronously and return in arbitrary order. Each returning scan's tracking ID is routed through `Exploration::feedResult` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229`, declared at `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186`). `feedResult` deconvolves the variant spectrum, scores it against the configured metric, and records the result on the owning `ExplorationGroup`.

- **Completion and winner.** When every variant in a group has `received=true`, the group completes. The highest-scoring variant becomes the winner (stored in `group.winner_index`). A production scan is built from the winner and enqueued; the per-level `overrides` map is applied at this point so the production scan can depart from the explored parameters (e.g., a longer max injection time than any sweep variant used).

- **Next level.** If the next MSn level is configured for exploration, `Exploration::initiateNextLevel` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504`, declared at `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:200`) is called with the winner's deconvolved result. For an MS2 winner this starts an MS3 exploration group rooted at a selected MS2 fragment.

## State machine

State lives in two structures on `Exploration`: `active_groups_`, an `unordered_map<int, ExplorationGroup>` keyed by group ID; and `variant_tracking_map_`, which maps a variant's tracking ID to `{group_id, variant_index}` so `feedResult` can do constant-time routing. `FLASHIda` additionally carries an atomic `exploration_active_` flag consulted by scan-cycle gating (it prevents interleaving unrelated MS1 work while variants are in flight).

Group lifetime: a group is created in `initiate` with one `ExplorationVariant` entry per enumerated point on the sweep grid. Every variant begins with `received=false`. `feedResult` flips `received=true` on exactly one variant per call and writes the metric score. When all variants have been received the group is marked complete, the winner is chosen, and the production scan plus any next-level initiation are enqueued. The group entry and its tracking-map rows are then erased.

## Per-level config surface

Exploration is driven entirely by fields on `MSLevelConfig`. The key field is `ExplorationMetric exploration` (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:100`), whose enum values are declared at `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59`: `None` (exploration off), `MassCount`, `RemainingPrecursor`, `FragmentCount`. The sweep-shape neighbors on `MSLevelConfig` are `ce_min` / `ce_max` / `ce_step` (collision energy grid), `rt_min` / `rt_max` / `rt_step` (reaction time grid), `activations` (list of activation types to sweep), `overrides` (the map applied to the winner's production scan), and `exploration_tolerance_ppm` (deconvolution tolerance used specifically for variant spectra, kept separate from the base tolerance used for non-exploration deconvolution).

`Config::hasExploration(msn_level)` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:494`) is the cheap gate: it returns true whenever `levels_[msn_level].exploration != ExplorationMetric::None`. Callers use it to decide between the exploration code path and the direct-scan code path without inspecting the full config. For how the JSON method file lands in these fields, see `../config-flow/`.

## Entry points

Two call sites in `FLASHIda.cpp` reach exploration from the main acquisition loop:

- **MS1 -> MS2.** At `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753` the loop branches on `config_.hasExploration(2)`. When true, each selected precursor flows into `Exploration::initiate(2, ...)` at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760` instead of taking the direct `queue_.buildMS2` path. See `ms2-exploration.md` for the target-selection integration.

- **MS2 -> MS3 (non-exploration MS2).** At `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927`, when MS2 exploration is off but MS3 is configured, the non-exploration MS2 result path calls `Exploration::initiateNextLevel(2, ...)` directly with the stored MS2 deconvolved spectrum. See `ms3-exploration.md`.

The exploration-winner path — `feedResult` detecting completion and internally calling `initiateNextLevel` when the next level is configured — is internal to `Exploration.cpp` and fires automatically. External callers do not drive the MS2-winner -> MS3 handoff.

## Validation

`Config::validate()` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:422`) enforces cross-cutting rules that single-field defaults cannot express. Relevant to exploration: (a) IDScore-based selection and exploration are mutually exclusive on the same level — they are alternative optimization strategies, so configuring both is a user error; (b) exploration levels must have exactly one entry in `level(n).scans` — the sweep grid and the production `overrides` are attached to that single entry; (c) activation sweep ranges must be consistent with the metric — for example, `RemainingPrecursor` requires a baseline reference to compute "remaining" against. Violations throw `std::invalid_argument`, which surfaces on stderr before the C# caller sees `CreateFLASHIda` return null.

## Gotchas

- **Command load multiplication.** Each selected target produces N variants. With `max_targets=10`, `ce_step=5`, and range 20–40, that is 10 × 5 = 50 MS2 commands per MS1 cycle — not 10.

- **Blocking on all variants.** Winner selection only fires when every variant in a group has `received=true`. A dropped or long-delayed variant leaves the group open indefinitely; there is no per-group timeout in the current implementation. Monitor scan-queue health in long runs.

- **Baseline adds to load.** The `RemainingPrecursor` metric prepends a CE=0 reference scan (invisible in `ce_min` / `ce_max` / `ce_step`), adding one variant per group beyond the CE-grid count.

- **IDScore + exploration mutual exclusion.** Configuring both IDScore-based selection and exploration on the same level is rejected at `Config::validate()`. Pick one optimization strategy per level.

- **Per-level tolerance.** `exploration_tolerance_ppm` can differ from the base deconvolution tolerance. Exploration variant deconvolutions use this field, not the base — useful when variants need looser matching than the primary MS2 pipeline.

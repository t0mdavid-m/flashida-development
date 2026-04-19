---
title: MS2 Exploration Engine
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753   # hasExploration(2) branch in processScan
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760   # exploration_.initiate call
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65   # ExplorationVariant struct
see_also:
  - precursor-selection.md
  - faims-cycling.md
---

# MS2 Exploration Engine

## Overview

When `ms2.exploration` is set to anything other than `None`, the exploration engine takes
over from the standard MS2 command build for every selected precursor. Instead of issuing
one MS2 per target, it enqueues a sweep of N MS2 variants spanning a collision-energy (CE)
range (and optionally reaction-time or activation-type axes). Each variant is an independent
acquisition that returns its own deconvolved result. Once all variants for a precursor have
been received and scored, an `ExplorationMetric` policy picks the winner; the winner can then
trigger an MS3 via `initiateNextLevel()`. The goal is autonomous optimization of fragmentation
conditions without operator intervention.

## Activation

Enable exploration by setting the metric in the JSON method config under the MS2 level block:

```json
"ms2": {
  "exploration": "MassCount",   // or "RemainingPrecursor" | "FragmentCount" | "None"
  "ce_min": 20,
  "ce_max": 40,
  "ce_step": 5
}
```

`Config::hasExploration(msn_level)` (`Config.cpp:494`) returns true whenever
`levels_[msn_level].exploration != ExplorationMetric::None`. The branch that gates the entire
path lives at `FLASHIda.cpp:753`:

```cpp
if (config_.hasExploration(2))
{
    // Exploration path: initiate CE sweep variants INSTEAD of regular MS2
    for (int i = 0; i < n; i++)
    {
        ...
        auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx);
```

When the branch is NOT taken, the code falls through to the standard `queue_.buildMS2` path.
The two paths are mutually exclusive per scan cycle.

The sweep dimensions are configured per MSn level in `MSLevelConfig` (`Config.h:~95`):
- `ce_min` / `ce_max` / `ce_step` — CE sweep range (eV).
- `rt_min` / `rt_max` / `rt_step` — optional reaction-time sweep (ms; ETD-class).
- `activations` — optional list of activation types to sweep (e.g. `["HCD","ETD"]`).

## Variant Generation

`Exploration::initiate()` (`Exploration.cpp:115`, signature at `Exploration.h:178`) is the
entry point per selected precursor. It:

1. Calls `buildVariants_()` to enumerate all (CE, reaction_time, activation) combinations
   from the configured sweep parameters.
2. If the metric is `RemainingPrecursor`, prepends a baseline variant at CE=0 so the engine
   can measure precursor depletion relative to an un-fragmented reference.
3. Creates an `ExplorationGroup` — the container that tracks all variants for one precursor
   through to winner selection.
4. For each variant, builds a `ScanCommand` via `queue_.buildMS2(...)`, assigns a unique
   tracking ID, and populates an `ExplorationVariant`.
5. Returns the commands to the caller; the caller (orchestrator at `FLASHIda.cpp:762`) is
   responsible for enqueuing them.

The `ExplorationVariant` struct (`Exploration.h:65`) carries state for one sweep point:

| Field | Purpose |
|---|---|
| `variant_index` | 0-based position in the sweep; `-1` for the baseline |
| `collision_energy` | CE chosen for this variant (eV) |
| `reaction_time` | Ion/ion reaction time (ms); `0` if unused |
| `activation_type` | HCD, ETD, EThcD, etc. |
| `tracking_id` | String-encoded scan ID used to match returning results |
| `is_baseline` | `true` for the CE=0 reference scan (RemainingPrecursor only) |
| `score` | Assigned after result arrives; `-1.0` until scored |
| `fragment_count` | Fragment-ion count from the returning deconvolved result |
| `received` | `false` until `feedResult()` processes this variant's MS2 result |
| `result` | Full `DeconvolvedSpectrum` stored for downstream use |
| `identification_result` | Populated at batch evaluation with per-fragment match details |

Active groups are stored in `Exploration::active_groups_` (an `unordered_map<int, ExplorationGroup>`).
The `VariantRef` lookup map (`tracking_id -> {group_id, variant_index}`) lets `feedResult()`
route each returning MS2 to the right slot in constant time.

## Winner Selection

Results return asynchronously. `Exploration::feedResult()` (`Exploration.h:186`) is called
whenever the orchestrator processes an MS2 scan whose tracking ID belongs to an active
exploration group (`isExplorationVariant()` returns true). It:

1. Deconvolves the raw spectrum with the correct precursor context for this variant.
2. Calls `computeExplorationScore_()` (`Exploration.h:240`) with the configured metric.
3. Marks `variant.received = true` and stores the score.
4. Checks whether all variants in the group are now received (`group.complete`).
5. When complete, selects the variant with the highest score as `group.winner_index`.

The three scoring policies (`Config.h:59`):

| Metric | What is maximized | Notes |
|---|---|---|
| `MassCount` | Count of deconvolved masses in the MS2 | Via `computeMassCount_()` |
| `RemainingPrecursor` | Depletion of precursor signal | Score = `1 - remaining/baseline`; higher depletion scores better; requires baseline variant |
| `FragmentCount` | Raw fragment-ion count in the MS2 | Simplest proxy for fragmentation efficiency |

After winner selection, `feedResult()` optionally calls `initiateNextLevel()` if MS3
exploration or selection is configured for the next level (see next section).

## Interaction with Precursor Selection

Exploration operates downstream of selection, not in parallel with it. The sequence within
one MS1 scan cycle is:

```
MS1 arrives
  -> SpectralDeconvolution (deconvolve MS1)
  -> filterAndRank() selects N precursors
  -> for each selected precursor:
       if hasExploration(2):
           exploration_.initiate(...)   // issues M variants per precursor
       else:
           queue_.buildMS2(...)         // issues 1 MS2
```

Exploration does not re-rank or filter precursors. Every precursor that passes `filterAndRank`
gets its own `ExplorationGroup`; exploration then independently determines the best CE for
each one. The selection metric (intensity, mass, charge, etc.) and the exploration metric are
orthogonal configuration axes.

## MS3 Trigger via initiateNextLevel

When the winner has been selected and the MS3 level is configured with a non-None selection
metric (`config_.level(2).selection != SelectionMetric::None`), `feedResult()` calls:

```cpp
nlr = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);
```

This is a next-level decision that belongs entirely to exploration — it is not part of MS1
precursor selection. The MS3 commands are built from the winner's deconvolved result, using
the originating MS2 `ScanCommand` stored in `group.originating_cmd` for isolation context.

The call site in the non-exploration path (`FLASHIda.cpp:924`) handles the same MS3 trigger
for ordinary (non-exploration) MS2 results, so `initiateNextLevel` is reused across both code
paths.

## Gotchas

- **Command load multiplication.** Each selected precursor produces M variant commands instead
  of 1. At `max_targets=10`, `ce_step=5`, `ce_min=20`, `ce_max=40`, that is 10 × 5 = 50 MS2
  commands per MS1 cycle. Queue depth and cycle time grow proportionally.

- **Blocking on all variants.** Winner selection only fires when every variant in a group
  has `received=true`. If the instrument drops or delays one MS2 result — due to a scan
  timeout, queue overrun, or AGC stall — the group stays open indefinitely. There is no
  per-group timeout in the current implementation.

- **Baseline variant counts toward command load.** The CE=0 baseline scan required by
  `RemainingPrecursor` adds one extra command per precursor beyond the sweep count. This is
  invisible in the config (`ce_min`/`ce_max`/`ce_step` do not include it).

- **MS3 belongs to exploration, not to MS1 selection.** An MS3 triggered after an exploration
  winner is selected is a second-level decision rooted in the MS2 result, not a direct
  consequence of which precursor was chosen at the MS1 stage.

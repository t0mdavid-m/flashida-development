---
title: Exploration — Variants and Sweeps
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65    # ExplorationVariant struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178   # initiate decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:237   # buildVariants_ decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:59          # buildVariants_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115         # initiate definition
see_also:
  - exploration.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
  - ../fragment-analysis/data-model.md
---

# Exploration — Variants and Sweeps

This packet entry covers how `Exploration::initiate` turns a single precursor
target into a set of `ExplorationVariant` scans that span CE, reaction-time,
and activation-type axes.

## `Exploration::initiate` walkthrough

`Exploration::initiate` (`Exploration.cpp:115`) receives the MSn level, the
target (`PeakGroup` for MS2; for MS3 the fragment is identified by an
`ion_type`/`frag_index` pair plus the caller's `ms_ctx`), the charge, the FAIMS
CV, the scan-command queue, and a context pointer (`ms_ctx`) carrying the
parent MS2's `ProteoformContext`. It constructs a fresh `ExplorationGroup`,
pulls the level's config via `config_.level(msn_level)`, enumerates variants
(see below), and appends scan commands through the queue's level-appropriate
builder — `queue.buildMS2` for MS2, `queue.buildMS3` for MS3 (see
`ms2-exploration.md` / `ms3-exploration.md`). Commands are returned to the
caller, which enqueues them on the acquisition side.

## Variant enumeration

`Exploration::buildVariants_` (`Exploration.cpp:59`; declared at
`Exploration.h:237`) enumerates the Cartesian product across three axes:

- **CE axis** — `[ce_min, ce_max]` stepped by `ce_step`. Always produces at
  least one value (degenerate sweep when `ce_min == ce_max`).
- **RT (reaction-time) axis** — `[rt_min, rt_max]` stepped by `rt_step`. Only
  produces more than one value for activation types that use an ion/ion
  reaction time (ETD, EThcD). For HCD-only sweeps the axis collapses to a
  single zero.
- **Activation axis** — the `activations` config list. If empty, defaults to
  the level's primary activation. When multiple entries are configured (e.g.
  `["HCD","ETD"]`), the full CE × RT sweep repeats for each activation.

Invariants: at least one variant is always produced, and the axis nesting
order is stable so that `variant_index` is deterministic across runs — read
the loop structure in `buildVariants_` to confirm.

## `ExplorationVariant` struct (`Exploration.h:65`)

Field reference for the struct that tracks one variant through its lifecycle:

| Field | Populated when | Purpose |
|---|---|---|
| `variant_index` | at construction | 0-based sweep position; `-1` for the baseline |
| `collision_energy` | at construction | CE for this variant (eV) |
| `reaction_time` | at construction | ETD/EThcD reaction time (ms); `0` for HCD-only |
| `activation_type` | at construction | HCD / ETD / EThcD / etc. |
| `tracking_id` | at construction | unique scan ID used by `feedResult` to match results |
| `is_baseline` | at construction | `true` for the CE=0 reference scan (RemainingPrecursor only) |
| `cmd` | at construction | the `ScanCommand` emitted for this variant |
| `score` | on `feedResult` | from `computeExplorationScore_`; `-1.0` sentinel until received; MS3 FragmentCount overwrites after batch re-score |
| `tic_coverage` | on `feedResult` | fraction of TIC explained by deconvolved peaks (used by some metrics) |
| `fragment_count` | on `feedResult` | fragment-ion count from the deconvolved result |
| `received` | on `feedResult` | `false` until the variant's scan result arrives |
| `result` | on `feedResult` | deconvolved spectrum stored for downstream use |
| `identification_result` | post-all-received (MS3 FragmentCount only) | `FragmentAnalysis::ProteoformMatch` from `MS3FragmentMatcher::calibrateAndScore` batch eval |

## Baseline variant for `RemainingPrecursor`

When the metric is `RemainingPrecursor`, `initiate` prepends a single CE=0
scan with `is_baseline=true` and `variant_index=-1` (`Exploration.cpp:133-136`
— `variant_params.insert(variant_params.begin(), {...})`). Winner selection
ignores baseline variants; they exist only as the denominator for
`computeRemainingPrecursorScore_`. Without the baseline the metric has no
reference TIC to divide against.

## Activation-sweep validation

`Config::validate()` enforces per-activation sweep ranges: HCD/CID/EThcD
require `ce_min < ce_max`, and ETD/EThcD additionally require
`rt_min < rt_max`. Invalid axis configurations throw at config-load time —
the error message identifies both the offending MSn level and the activation
type, which makes misconfiguration fail loudly rather than silently producing
a single-variant sweep.

---
title: Exploration — Variants and Sweeps
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-10-11
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:68    # ExplorationVariant struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:274   # initiate decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:399   # buildVariants_ decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:58          # buildVariants_ definition (grid rule)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:123         # initiate definition
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

`Exploration::initiate` (`Exploration.cpp:123`) receives the MSn level, the
target (`PeakGroup` for MS2; for MS3 the fragment is identified by an
`ion_type`/`frag_index` pair plus the caller's `ms_ctx`), the charge, the FAIMS
CV, the scan-command queue, and a context pointer (`ms_ctx`) carrying the
parent MS2's `ProteoformContext`. It constructs a fresh `ExplorationGroup`,
pulls the level's config via `config_.level(msn_level)`, enumerates variants
(see below), and appends scan commands through the queue's level-appropriate
builder — `queue.buildMS2` for MS2, `queue.buildMS3` for MS3 (see
`ms2-exploration.md` / `ms3-exploration.md`). Commands are returned to the
caller, which enqueues them on the acquisition side. `initiate` prepends
**nothing**: a group is exactly its grid points (ADR-0048).

## Variant enumeration

`Exploration::buildVariants_` (`Exploration.cpp:58`; declared at
`Exploration.h:399`) enumerates the Cartesian product across three axes:

- **CE axis** — `[ce_min, ce_max]` stepped by `ce_step`, as **index
  arithmetic with the top edge appended** (ADR-0047 d.8):
  `n = floor((max − min)/step + 1e-9) + 1` points from `min`, then `max` if the
  last point fell short of it. `15..40/2` is therefore 15, 17, …, 39, **40** —
  fourteen points, not thirteen; a dividing grid such as `20..40/5` is unchanged.
  (The old `ce += step; ce <= max + 1e-9` loop accumulated drift and dropped
  the edge; the decimation study's result rests on both edges being acquired.)
- **RT (reaction-time) axis** — `[reaction_time_min, reaction_time_max]`
  stepped by `reaction_time_step`, same rule. Only produces more than one value
  for activation types that use an ion/ion reaction time (ETD, EThcD). For
  HCD-only sweeps the axis collapses to a single zero.
- **Activation axis** — the `activations` config list. If empty, defaults to
  the level's primary activation. When multiple entries are configured (e.g.
  `["HCD","ETD"]`), the full CE × RT sweep repeats for each activation, as one
  contiguous block per activation. A `kinetic_model` sweep names exactly one
  activation, and it must be CE-swept (`Config::validate`, ADR-0047).

Invariants: at least one variant is always produced, no reference scan is
synthesized under any metric or activation (ADR-0048 superseded ADR-0029's
per-activation CE-0 baseline), and the axis nesting order is stable so that
`variant_index` — one running counter from 0 — is deterministic across runs.

## `ExplorationVariant` struct (`Exploration.h:68`)

Field reference for the struct that tracks one variant through its lifecycle:

| Field | Populated when | Purpose |
|---|---|---|
| `variant_index` | at construction | 0-based sweep position |
| `collision_energy` | at construction | CE for this variant (NCE) |
| `reaction_time` | at construction | ETD/EThcD reaction time (ms); `0` for HCD-only |
| `activation_type` | at construction | HCD / CID / ETD / EThcD |
| `tracking_id` | at construction | engine-minted scan id used by `feedResult` to match results |
| `cmd` | at construction | the `ScanCommand` emitted for this variant |
| `measured_only` | on `feedResult`, from the **command** | the ion trap read it out: window sum only, never deconvolved or matched (ADR-0045) |
| `precursor_share` | on `feedResult` | anchor-window raw signal over the whole scan's; `-1.0` = no measurement (ADR-0048) |
| `score` | on `feedResult` | from `computeExplorationScore_`; `-1.0` until received and `-1.0` when not scorable (every pre-scan under `kinetic_model`); MS3 FragmentCount overwrites after batch re-score |
| `tic_coverage` | on `feedResult` | fraction of TIC explained by matched fragments |
| `fragment_count` | on `feedResult` | fragment-ion count from the match |
| `received` | on `feedResult` | `false` until the variant's scan result arrives |
| `result` | on `feedResult` | deconvolved spectrum stored for downstream use |
| `identification_result` | post-all-received (MS3 FragmentCount only) | `FragmentAnalysis::ProteoformMatch` from `MS3FragmentMatcher::calibrateAndScore` |

## What replaced the baseline

Until ADR-0048 every activation block began with a CE-0 (or minimum-reaction-time)
reference scan whose window intensity was the denominator of the remaining-precursor
ratio. The precursor share is referenced against the scan's **own** total instead, so
the reference scan, `is_baseline`, `variant_index == -1`, `baseline_intensity` and the
empty-baseline abort are all gone, and a sweep costs exactly its grid points plus the
follow-up. The one rule from that era that survives is the reaction-time floor:
`Config::validate` still rejects a `reaction_time_min` below `MIN_REACTION_TIME_MS`
(0.03 ms) when an ETD-family activation is swept, because the instrument refuses a
reaction time of 0.

## Activation-sweep validation

`Config::validate()` enforces per-activation sweep ranges: HCD/CID/EThcD
require `ce_min < ce_max`, and ETD/EThcD additionally require
`reaction_time_min < reaction_time_max`. Under `kinetic_model` it further
requires exactly one CE-swept activation and a `kinetic_model.k2` entry for it
(never defaulted; an entry for an unswept activation is a `[CONFIG-WARN]`), and
it refuses the `kinetic_model` object under any other metric. Invalid axis
configurations throw at config-load time — the error message identifies both
the offending MSn level and the activation type.

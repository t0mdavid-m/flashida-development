---
title: MS1 Precursor Selection
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177   # filterAndRank entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:238   # deconvolveMS1 call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:246   # ranking branch start (filterPeakGroupsUsingMassExclusion_)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:381   # phase loop entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:432   # min_charge filter
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:572   # SNR filter
see_also:
  - targeting-modes.md
  - exploration.md
---

# MS1 Precursor Selection

## Pipeline Overview

`filterAndRank` (`:177`) is the single entry point called for every MS1 scan. It orchestrates three
steps in sequence: (1) deconvolve the raw MS1 spectrum via `deconvolveMS1` (`:238`), yielding a
sorted list of peak groups; (2) apply mass-based inclusion/exclusion filtering according to the
active targeting mode; (3) iterate the filtered candidates through a multi-phase ranking and
per-candidate filter loop (`:381`) that selects up to `max_targets` peak groups. On exit, the
following members are populated and consumed by the caller to build MS2 scan commands:
`selected_peak_groups_` (ranked peak groups), `trigger_charges_` (per-selection charge),
`trigger_hcds_` (per-selection collision energy), `trigger_scores_` (the score that won the
slot), plus `trigger_left_isolation_mzs_` / `trigger_right_isolation_mzs_` (isolation window
bounds) and `trigger_ids_` (monotonically increasing acquisition IDs for exclusion bookkeeping).

## Ranking Basis

The sort applied to `deconvolvedMS1()` before the selection loop is determined by four branches
inside `filterPeakGroupsUsingMassExclusion_` (`:246`). All four operate on the full candidate
list before any per-candidate filtering runs, so only sort order — not candidate presence — is
affected here.

- **`use_idscore=true`** — calls `sortByIDScoreRepresentative()` or `sortByIDScoreAllCharges()`.
  When `hcd_energy < 0` the best HCD is chosen per peak group; when `hcd_energy >= 0` scores are
  evaluated at that fixed energy. WHY: IDScore integrates fragment-match evidence from prior
  acquisitions; ranking by it promotes previously-identified masses.

- **Default (QScore, per-charge)** — `sortByQscore()` (`:272`). The representative charge's
  QScore drives order. This is the most common production path.

- **`consider_all_charges=true`** — `sortByQScoreAllCharges()` (`:269`). Best QScore across
  every observed charge state is used. WHY: finds the globally most confident assignment
  regardless of which charge the engine tagged as representative.

- **`SelectionMetric::Intensity`** — `sortByIntensity()` (`:264`). Used when the level config
  explicitly requests intensity-based ordering rather than quality-score ordering.

When TSV targets are loaded and `mode == 1`, a `stable_sort` (`:282`) runs after the primary sort
to promote higher-priority targets within a configurable `tie_threshold` window.

## Phase Logic

The selection loop runs up to three phases (`:370–381`), controlled by `selection_phase` in
`[0, 2]`. The loop breaks early unless specific conditions allow phase 1.

- **Phase 0** — Selects peak groups that are either target-matched (inclusion mode) or whose
  accumulated tqscore has not yet exceeded `tqscore_threshold`. In inclusion mode this means
  only targets advance; non-targets hit `continue` at `:533`.

- **Phase 1** — Runs only when `mode == 1` (inclusion), `strict_inclusion == false`, and at
  least one target mass is active (`:388`). Non-target candidates that passed phase 0's sort are
  reconsidered here, allowing the instrument to fill remaining slots with untargeted masses.
  Without active targets this phase is skipped entirely via the break at `:388`.

- **Phase 2** — The permissive fallback: all remaining candidates are eligible, and the
  same-m/z avoidance rule is relaxed (see Filters section). Without an active inclusion list,
  phases collapse to a single pass through this final phase.

The outer iteration loop (`:379`) exists solely for exclusion mode (`mode == 2`): it first
collects candidates that are on the exclusion list, then repeats for those that are not, producing
the most novel precursor choices first.

## Filters Applied Per Candidate

Each candidate in the inner loop is tested against the following gates in order (`:400`–):

- **`min_charge`** (`:432`) — `charge < config_.level(ms_level).min_charge` → `continue`.
  Prevents very low charge states from consuming MS2 slots; threshold is per-MS-level.

- **Target match** (`:461`–`:530`) — In inclusion mode, the candidate's monoisotopic mass is
  checked against `target_masses_` with ±`tolerance_ppm` tolerance. For TSV targets, the charge
  must also fall within the target's specified range (or the target specifies `charge < 0` for
  any-charge). A successful match sets `target_matched = true`, which waives both SNR and QScore
  thresholds for this candidate.

- **`qscore_threshold`** (`:569`) — `score < qscore_threshold` → `break` (exits the candidate
  loop entirely, because the list is sorted descending and no later candidate can pass). Waived
  (threshold set to 0) for target-matched candidates at `:531`.

- **SNR** (`:572`) — `pg.getChargeSNR(charge) < snr_threshold` → `continue`. Individually
  skips low-SNR candidates without breaking the loop. Also waived for explicit targets.

- **Same-m/z avoidance** (`:574`–`:581`) — if `center_mz` is already in
  `current_selected_mzs`, the candidate is skipped in phases 0 and 1. In phase 2 (`selection_phase
  == selection_phase_end`) the check is relaxed: an already-selected m/z is allowed if the
  mass differs (different charge state of the same m/z range) AND the candidate is not
  target-matched. WHY: avoids redundant isolation windows while still permitting truly distinct
  masses that happen to share an m/z centroid.

- **tqscore gate** (`:594`) — in phases 0 and 1, candidates whose nominal mass or integer m/z
  appears in the tqscore-exceeding maps are deferred to phase 2. This is the "dynamic exclusion
  within a run" mechanism: masses seen with high quality too recently are deprioritized.

## Output Fields

All five output vectors are written atomically at `:643`–`:655` when a candidate passes all
filters.

- **`selected_peak_groups_`** — The accepted peak groups in rank order. Downstream MS2 command
  builders iterate this directly; rank order is guaranteed.

- **`trigger_charges_`** — The charge selected for this acquisition. May differ from the peak
  group's representative charge when `consider_all_charges=true` or when a TSV target specifies
  an explicit charge that overrides the engine's choice (`:488`).

- **`trigger_hcds_`** — Per-selection HCD collision energy. Set to `config_.targeting().hcd_energy`
  by default; overridden by IDScore branches that pick the energy that maximizes the score
  (`:406`, `:412`). The MS2 command builder reads this to set the fragmentation energy
  consistently with the branch intent.

- **`trigger_scores_`** — The QScore or IDScore value that secured this slot. Used for logging,
  downstream tqscore accumulation, and exclusion list management via `removeFromExclusionList`.

## Gotchas

- Per-charge QScore ranking (`sortByQscore`) is the default, not "best charge across all states".
  Enabling `consider_all_charges` changes both sort order and the `trigger_charges_` value —
  these two must be understood together, not separately.

- SNR threshold is fully waived for explicit target matches. A target with a charge-SNR of 0
  will still be selected and trigger an MS2. This is intentional: target coverage takes
  priority over signal quality.

- `selected_peak_groups_` is in descending rank order (highest score first). Consumers that
  iterate it can assume this ordering without re-sorting.

- Same-m/z avoidance is permissive in phase 2 by design: if two structurally distinct masses
  map to the same isolation-window center (isobaric or near-isobaric species), the second will
  be acquired in phase 2. This is a deliberate coverage choice, not a bug.

- The `break` at `:569` on `qscore_threshold` exits the entire candidate loop, not just the
  current candidate. Because candidates are sorted descending, this is safe — but it also means
  that any `continue` between `:569` and the actual selection commit can leave higher-scored
  candidates stranded if later filters reject them without `break`. SNR failure uses `continue`
  for exactly this reason: a low-SNR peak group may be followed by a high-SNR one at the same
  or lower score.

- `charge_based_exclusion` (developer flag, default off) changes the accumulation
  block at `:596-630` to use a per-`(nominal_mass, charge)` key
  (`mass_charge_qscore_map_`) and replaces the mass-level write into
  `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_` with an insert into
  `tqscore_exceeding_mass_charge_set_`. When on, the mass is never globally
  excluded; instead, specific charges are excluded individually. The candidate
  loop also expands per-peak-group to one iteration per observed charge. See
  `docs/superpowers/specs/2026-04-19-charge-based-exclusion-design.md`.

---
title: Targeting Modes
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:143        # TargetingConfig::mode
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:187  # inclusion target list load
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:222  # deep RT-window exclusion load
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:320  # tqscore accumulation loop
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:378  # outer iteration loop (mode 2)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:458  # exclusion skip rule
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:277  # priority tie-break
see_also:
  - precursor-selection.md
  - ../exploration/ms2-exploration.md
---

# Targeting Modes

## Overview

`TargetingConfig::mode` selects one of four acquisition behaviors for MS1-driven precursor selection.
All four modes flow through the same `filterAndRank` function in `PrecursorSelection.cpp`, but they
diverge in how candidates are filtered in or out before the per-mass-slot ranking loop. Mode 0 is
the default and leaves the selection engine idle; modes 1-3 engage progressively richer target-list
logic.

## Mode 0 — None

`mode = 0` means **no target list is active**: neither an inclusion list nor an exclusion map is
loaded or consulted. `filterAndRank` still runs in full — it deconvolves the MS1 spectrum, scores
every peak group, and selects the top-N candidates ranked by whichever `SelectionMetric` is
configured (typically `QScore`). What is absent is any target-list influence: no priority
tie-break, no SNR waiver for explicit targets, and no tqscore-based suppression.

> **Note — `mode = 0` is not the same as `SelectionMetric::None`.** These are two orthogonal
> config dimensions. `SelectionMetric::None` (set on the level-1 `selection` field) is the
> short-circuit that causes `processScan` to skip MS1 precursor selection entirely
> (`FLASHIda.cpp:739`). `TargetingConfig::mode = 0` leaves selection running; it only disables
> target-list machinery. Confusing the two produces hard-to-debug "no MS2 commands" symptoms.

## Mode 1 — Inclusion

Precursors are ranked against an explicit target list. Two list formats are supported:

- **TSV file** (`inclusion_list_file`): parsed once at initialization (:144) into
  `inclusion_targets_`. Each entry carries a mass, optional charge, RT window, and an integer
  `priority` field.
- **Log/out files** (`target_log_files`): legacy format populated into `target_mass_rt_map_` and
  `target_mass_qscore_map_` (:100).

On each MS1 scan, active targets (those whose RT window covers the current RT) are extracted into
`target_masses_` (:187-220) and passed to the deconvolution engine via `setTargetMasses`.

**Priority tie-break** (:277): after sorting by QScore (or IDScore), a `stable_sort` re-orders
pairs of peaks whose score difference is within `tie_threshold` so that the candidate with the
higher `priority` in `target_priority_map_` sorts first.

**SNR waiver**: when a peak group matches a target mass (`:530`), `snr_threshold` is set to 0.0
for that candidate. Low-SNR explicit targets are never silently dropped.

**Strict vs non-strict inclusion** (`strict_inclusion`): strict mode (`:540`) restricts the
ranking loop to targets only — non-target peaks are not considered even if target slots remain
unfilled. Non-strict mode (`:388`) runs a second selection phase that backfills from non-target
peaks.

## Mode 2 — Exclusion

Precursors that have already been selected with high cumulative confidence are suppressed to
steer acquisition toward unexplored masses. The suppression decision uses a per-nominal-mass
accumulated tqscore.

**tqscore accumulation** (:320-337): before the ranking loop, `filterAndRank` iterates
`target_mass_rt_map_` (populated from log files). For each (mass, RT, QScore) triplet whose RT
falls within `rt_window` of the current scan, the cumulative product `1 - QScore` is folded
into `t_mass_score_map_[nominal_mass]`.

**Two-pass outer loop** (:378): the ranking loop runs twice for mode 2 only — `iteration` starts
at 0 (exclusions active) and then 1 (exclusions lifted). This "fix-and-look-again" design ensures
that masses which exceed the exclusion threshold on the first pass can still be selected on the
second pass if no better candidates exist.

**Exclusion skip rule** (:454-458): inside the ranking loop, on `iteration == 0`, a mass is
skipped if `1 - tqscore_factor_for_exclusion > tqscore_threshold`. Here
`tqscore_factor_for_exclusion` is the product of `(1 - qscore)` terms accumulated over the RT
window — i.e., the running unexplained fraction. Therefore `1 - tqscore_factor_for_exclusion` is
the explained fraction; the skip fires when the explained fraction exceeds `tqscore_threshold`,
meaning the mass has already been sufficiently characterised.

## Mode 3 — Deep

Mode 3 is an exclusion variant driven by a dynamically populated RT-keyed map rather than log
files containing per-mass QScores. The exclusion map (`exclusion_rt_masses_map_`) is built from
"AllMass" entries in log files (:115).

On each MS1 scan, mode 3 loads `excluded_masses_` from the RT-keyed map (:222-231), skipping
any entry whose RT distance from the current scan exceeds `rt_window`. The ranked exclusion is
then applied through the standard exclusion path at (:546).

The key difference from mode 2: mode 3 does not compute tqscore accumulation. Masses in the
exclusion map are treated as binary (excluded or not, based on RT proximity). The two-pass outer
loop does not apply — mode 3 runs only the single `iteration = 1` pass.

## Configurable Knobs

| Key | Effect |
|---|---|
| `qscore_threshold` | Global lower bound on QScore for any candidate to be selected. |
| `snr_threshold` | Per-charge SNR cutoff; waived (set to 0.0) when a peak matches an explicit target. |
| `tie_threshold` | QScore delta within which `priority` breaks ties (Mode 1 TSV only). |
| `rt_window` | Seconds; governs which RT-keyed list entries are active in Modes 2 and 3. |
| `tqscore_threshold` | Cumulative exclusion threshold for Mode 2; mass is skipped if `1 - tqscore > threshold`. |
| `inclusion_list_file` | Path to TSV target file (Mode 1). |
| `tag_based_enabled` | Enables protein-family tag expansion of target masses. |
| `fasta_file` | FASTA database for tag-based target expansion. |

> Related but distinct: the MS1-side tag-biased precursor selection controlled by the two keys above is different from the MS2-side tag confirmation + conditional follow-up scan, which is covered in [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md).
| `consider_all_charges` | Ranks across all charge states rather than only the representative charge. |
| `hcd_energy` | Fixed HCD energy for all targets; `-1` means auto-select per peak group. |

## Gotchas

- **SNR is waived for explicit targets.** When `inclusion_list_file` is used and a peak group
  matches a target mass, `snr_threshold` is zeroed out. Don't assume low-SNR targets are dropped
  before they reach the final selection step.

- **Mode 2's outer loop runs twice.** The `iteration = 0` pass suppresses excluded masses; the
  `iteration = 1` pass lifts exclusions. Code that modifies candidate state (e.g. score updates
  or priority overrides) inside the loop body can interact with the fix-and-look-again pattern
  in non-obvious ways.

- **Mode 3's RT map decays outside `rt_window`.** Masses whose log-file RT entry is more than
  `rt_window` seconds from the current scan are silently skipped when building `excluded_masses_`.
  If `rt_window` is too small, the exclusion list effectively empties every scan.

- **Log files serve different roles in mode 2 vs mode 3.** Mode 2 reads per-mass QScore entries
  to build `t_mass_score_map_`. Mode 3 reads "AllMass" entries into `exclusion_rt_masses_map_`.
  Supplying mode-2 log files to a mode-3 run (or vice versa) loads nothing useful and produces
  no error.

- **Priority is per-nominal-mass, highest wins.** When multiple TSV targets share the same
  nominal mass, only the highest `priority` value is stored in `target_priority_map_`. Lower-
  priority duplicates for the same mass have no effect on tie-breaking.

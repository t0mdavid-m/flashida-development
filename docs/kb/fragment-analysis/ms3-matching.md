---
title: MS3 Fragment Matching
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-07-03
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400          # calibrateAndScore call in feedResult
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:115   # calibrateAndScore declaration
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp:397   # calibrateAndScore definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:66    # LOOSE_TOLERANCE_PPM constant
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp:287   # rebasePTMSites definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:71    # getMS3IonTypes declaration
see_also:
  - README.md
  - data-model.md
  - ms2-matching.md
  - ../exploration/ms3-exploration.md
---

## Overview

MS3 fragment matching is the post-all-received batch re-score for MS3 exploration variants. After all MS3 variants in an exploration group have returned, `MS3FragmentMatcher::calibrateAndScore` performs its own two-pass matching against theoretical masses computed from the precursor's subsequence (not the full protein), using the cached `ProteoformContext` from MS2 tag-matching.

This is distinct from MS2 matching (which hits the full protein sequence and reuses `FragmentAnalysis::getTopFragmentMatches`) and from the exploration-side view (which covers how `calibrateAndScore` fits into the feedResult winner-selection flow — see `../exploration/ms3-exploration.md`).

## Context

`calibrateAndScore` fires **MS3-only, `FragmentCount`-metric-only**, inside `Exploration::feedResult` at `Exploration.cpp:400`. The gate:

```
group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3
```

For MS3 with `MassCount`, `RemainingPrecursor`, or any other metric, `calibrateAndScore` is skipped and the initial per-variant `computeExplorationScore_` result stands.

## Flow

1. **Setup (before MS3 variants even fire).** When an MS2 completes and tag-matches, the `ProteoformContext` (region bounds + PTM sites) is cached on the parent `ExplorationGroup`. See `../exploration/ms3-exploration.md` for the group-level plumbing.
2. **All MS3 variants received.** `feedResult` flips `all_received` → invokes:
   ```cpp
   auto calibrated_scores = MS3FragmentMatcher::calibrateAndScore(
       variant_spectra, protein_sequence, proteoform_ctx,
       fragment_ion_type, fragment_ion_index,
       MS3FragmentMatcher::LOOSE_TOLERANCE_PPM,
       config_.level(group.msn_level).tolerance_ppm,
       &detailed_results);
   ```
3. **Pass 1 — calibration.** For each variant, match observed deconvolved masses against theoretical masses computed from the precursor subsequence, using the **loose tolerance** `LOOSE_TOLERANCE_PPM = 500.0` (compile-time constant, `MS3FragmentMatcher.h:66`). Collect PPM errors of matched pairs; compute the median → `ppm_offset`. Derive `correction_factor = 1 / (1 + ppm_offset * 1e-6)`.
4. **Pass 2 — tight rematch.** Apply `correction_factor` to observed masses; rematch at the **tight tolerance** `config_.level(group.msn_level).tolerance_ppm` (note: `tolerance_ppm`, not `exploration_tolerance_ppm`, and the level is taken dynamically from the group — typically 3). The resulting match count becomes the variant's calibrated score.
5. **Return.** Two aligned outputs, one entry per variant:
   - `calibrated_scores[vi]` — overwrites `group.variants[vi].score` and casts to `int` into `fragment_count`.
   - `detailed_results[vi]` — a `FragmentAnalysis::ProteoformMatch` (with `ppm_offset` and `correction_factor` populated) copied into each variant's `identification_result` field.
6. Winner selection then runs on the **calibrated** scores, not the initial ones.

## Ion types

`MS3FragmentMatcher::getMS3IonTypes(char precursor_ion_class)` at `MS3FragmentMatcher.h:71` returns ion types based on whether the MS3 precursor subsequence originated from a b-ion or y-ion MS2 fragment. The switch groups `'a'`/`'b'`/`'c'` precursors together, and `'y'`/`'x'`/`'z'` (and default) together:

- **N-terminal-subsequence precursors** (`'a'`, `'b'`, `'c'`): `a`, `b`, `yb`, `ya`.
- **C-terminal-subsequence precursors** (`'y'`, `'x'`, `'z'`, plus default): `a`, `b`, `y`.

The cross-direction ion types `yb` and `ya` are MS3-only. `yb` is "what would be a y-ion if the subsequence were the full protein, but read in the b-direction of the subsequence"; `ya` is analogous for a-ions. No water loss (the cleavage that created the MS3 precursor already broke the amide bond).

## PTM-aware dual theoreticals

For each ambiguous PTM site in the proteoform (where `start_position != end_position`), `calibrateAndScore` generates **two theoretical masses** per fragment: one with the PTM mass shift included, one without. Either can match an observed peak.

The `includes_ptm` bool on `TheoreticalMass` and the matched `MatchDetail` records which variant matched. Localized PTMs (`start == end`) produce a single theoretical with `includes_ptm = true` for positions at/after the PTM and `false` before.

## Subsequence vs. full-protein indexing

Fragment indices produced internally are **subsequence-local** (1-based from the relevant terminus of the precursor subsequence). For reporting, they are mapped back to full-protein coordinates:

- `FragmentMatch::ion_type` / `ion_index` — subsequence-local.
- `FragmentMatch::equiv_type` / `equiv_index` — full-protein equivalent ion.
- `FragmentMatch::observed_mass` — **measured** (subsequence frame); `adjusted_mass` — **adjusted** to the full-protein (MS2) frame **with modifications**; `theoretical_mass` + `diff_da` / `diff_ppm` — the proteoform's **theoretical** prediction and the residual. See the **Fragment masses** term in the repo-root `CONTEXT.md`.

The mod-inclusive `adjusted_mass` = `observed + (theo_equiv − ms3_theoretical) + ambiguous_included`. Crucially `theo_equiv` (from `computeProteinPrefixMasses`) drops still-**ambiguous** mods (`if (start_position != end_position) continue;`), so `ambiguous_included` — the ambiguous mass the matched theoretical folded in — must be re-added; otherwise `adjusted_mass` = bare backbone (the mod stripped, ~526 Da low for cytC). A trivial b→b frame therefore gives `adjusted == observed`.

The PTM-site rebasing logic lives in `MS3FragmentMatcher::rebasePTMSites` at `MS3FragmentMatcher.cpp:287`. The mapping for ion positions (subsequence → full-protein) is applied during match result population.

## Log surfaces: scan_commands fragment proteoform + identification coverage

The MS3 fragment identity surfaces across the logs (after the scan_results slim-down, `scan_results` carries **no** proteoform — it is a pure acquisition-event log):

- **`scan_commands.tsv` `ms3_proteoform`** (per MS3 command; `""` on MS1/MS2/AGC) = the **wide clipped b/y fragment** of the target being fired, rendered by `MS3FragmentMatcher::fragmentProForma(protein, ctx, ion_type, ion_index)` = `extractSubsequence` + `rebasePTMSites` + `FragmentAnalysis::toProForma`. Computed at command-BUILD time (in the 3 `Exploration.cpp` `buildMS3` call sites, which hold the `ProteoformContext`), stashed in `ScanCommandQueue::ms3_cmd_proteoform_` (`scan_id → string`), drained by `takeMS3Proteoform` in `FLASHIda::getNextScanCommand`. So it is present for **every** MS3 command (regular + exploration variants), even ones that never return; `""` when the context is unpopulated. ABI-safe (rides the log row, not the 2048-byte `ScanCommand` struct).
- **`identification.tsv` `ms3_fragment_coverage`** (matched MS3 rows; `-1` on MS2) = the fraction of the fragment's `(L−1)` backbone bonds covered by **distinct** matched MS3 sub-fragments, `L` = fragment length (`== fragment_ion_index`). Bond mapping: a prefix sub-ion (`a`/`b`/`c`) of subseq-index `p` cleaves bond `p`; a suffix sub-ion (`y`/`x`/`z`, incl. `yb`/`ya`) of index `p` cleaves bond `L−p`. Computed in `calibrateAndScore`, stored on `ProteoformMatch::ms3_fragment_coverage`, clamped `[0,1]`.
- **`identification.tsv` `proteoform`** (matched MS3 rows) = the clipped b/y fragment, but its ambiguous PTM ranges are **narrowed by only that scan's own matched sub-fragments** — distinct from the wide `scan_commands.ms3_proteoform` render. `IdaLogger::writeIdentificationRow` narrows a **local copy** of `match.ptm_sites` via `FragmentAnalysis::narrowFragmentPTMSites(match.ptm_sites, match.proteoform_sequence.size(), match.fragments)` before `toProForma`, gated on `ms_level==3`. That one site covers all three MS3 identification-row sinks (regular `R` + exploration `E`-primary + `E`-winner-batch). Because it narrows a copy in the writer, and pooled seeds its ranges from the MS2 winner (`ProteoformTracker.cpp:251`, never from an MS3 match) while `scan_commands` renders the wide fragment, **pooled and scan_commands are untouched**.

### `narrowFragmentPTMSites` — per-scan MS3 narrowing

`FragmentAnalysis::narrowFragmentPTMSites` is a pure function (subsequence frame): for each wide site `[s,e]` (1-based) and each matched sub-fragment that **brackets** it (backbone cleavage strictly inside), tighten the constrained boundary from the fragment's `includes_ptm` verdict. Prefix (`a`/`b`/`c`) covers `[1,k]`; suffix (`y`/`x`/`z`, incl. composite `yb`/`ya`) covers `[L−k+1, L]` (`k` = `ion_index`, subseq space). Prefix/suffix is decided by the **first char only** (`== isPrefixIonType`), so `yb`/`ya` classify as suffix — never by substring. Inward-only; single-scan `includes_ptm` verdicts are self-consistent so there is no intensity conflict resolution. It deliberately **mirrors `ProteoformTracker::narrowModifications_` Pass B** (the MS3 localization pass), scoped to one scan — it is **not** the cumulative pooled pass.

**Narrowing gradient** on an MS3 ambiguous mod (e.g. cytC heme, MS2 says residues 15–26):

| log | render | source |
|-----|--------|--------|
| `scan_commands.tsv` `ms3_proteoform` | **wide** `(CAQCHTVEKGGK)[+615]` (15–26) | `fragmentProForma(ctx)` at build time (parent MS2 clip) |
| `identification.tsv` `proteoform` | **this-scan** `(CAQCHTVE)[+615]` (15–22) | `narrowFragmentPTMSites` (own `b22` evidence) |
| `pooled_identification.tsv` | **cumulative** (15–22) | `ProteoformTracker::narrowModifications_` |

A per-scan leaf legitimately stays wider than pooled when *that scan* contributes no bracketing fragment for the mod.

## Gotchas

- **Cross-direction ion types only apply to N-terminal-subsequence precursors.** A C-terminal-subsequence MS3 never sees `yb`/`ya` matches; only `a`/`b`/`y`. Do not add `yb`/`ya` to `getMS3IonTypes`'s C-terminal case without understanding what a "y of a y" would mean physically.

- **Calibration pass can match spurious peaks.** At 500 ppm, random mass coincidences can match. The tight pass filters these, but per-variant intermediate state exposed during debugging (e.g. `[calibrateAndScore]` log lines at `MS3FragmentMatcher.cpp:437`+) may show Pass-1 matches that do not survive Pass 2. Trust the Pass-2 result.

- **`ppm_offset` / `correction_factor` are MS3-only.** MS2 paths leave these at default (`0.0` / `1.0`). Do not compare or aggregate these fields across MS2 and MS3 `ProteoformMatch` values.

- **`detailed_results` is populated only for `FragmentCount` metric.** If the MS3 metric is anything else, `identification_result` on each variant stays at default — no fragment-level identification data is available post-scoring.

- **`ProteoformContext` lifetime bound to the group.** The context lives on `ExplorationGroup` (see `../exploration/ms3-exploration.md`). If you hold a reference to `ptm_sites` after the group is cleaned up, you are dereferencing freed memory. Snapshot what you need.

- **y-ion (C-terminal) MS3 precursors are code-supported but data-untested end-to-end.** The engine emits y-ion MS3 commands correctly (the `ms3_cytc` `scan_commands` golden carries `y40`/`y56`/`y71`), the decoder's y-branch is parity-tested, and the fragment sub-sequence path (`extractSubsequence` suffix branch + `fragmentProForma`) is unit-tested (`MS3FragmentMatcher_test`, cytC y40/y56/y71). But no acquisition has captured a cytC y-ion MS3 **peak** spectrum, so end-to-end y consumption (matched sub-fragments → `ms3_fragment_coverage`) is unvalidated. Close it with a real C-terminal-isolating cytC MS3 acquisition — not a fabricated fixture.

---
title: Fragment Analysis — Data Model
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h
last_verified: 2026-07-03
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:60   # PTMSite
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:69   # ProteoformMatch
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:79   # FragmentMatch (nested)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:110  # toProForma + windowSnr (I2)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:126                          # identification.tsv header (25 cols, I2)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:97         # MS2Context window-SNR fields (I2)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:38  # TheoreticalMass
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:47  # MatchDetail
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:58  # ProteoformContext
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp:287       # rebasePTMSites
see_also:
  - README.md
  - tag-follow-up.md
  - ms2-matching.md
  - ms3-matching.md
---

## Overview

All three modes produce or consume the same core result type: `FragmentAnalysis::ProteoformMatch`. MS3 extends the type with calibration fields. `PTMSite` is the ambiguity-aware modification locator. None of these types cross the C++/C# ABI — they are internal to the engine.

## `FragmentAnalysis::ProteoformMatch`

Declared at `FragmentAnalysis.h:69`. Unified result of any fragment-matching operation (MS2 or MS3).

| Field | Type | MS2 | MS3 | Meaning |
|---|---|---|---|---|
| `total_match_count` | `int` | ✓ | ✓ | Total fragments matched (uncapped). Used as `FragmentCount` score in exploration. |
| `region_start` | `int` | ✓ | ✓ | 0-based proteoform start in protein sequence; `-1` = full sequence |
| `region_end` | `int` | ✓ | ✓ | 0-based exclusive proteoform end; `-1` = full sequence |
| `ptm_sites` | `std::vector<PTMSite>` | ✓ | ✓ | MS2: FLASHExtender PTM sites (parent-frame, 1-based). MS3: the parent mods **clipped/rebased into the fragment** (`calibrateAndScore` writes `rebased_ptms`). |
| `matched_protein` | `std::string` | ✓ | — | Protein file / DB name (MS2 only; `calibrateAndScore` leaves it empty on MS3). |
| `proteoform_sequence` | `std::string` | ✓ | ✓ | MS2: the matched protein slice. MS3: the **fragment sub-sequence** the MS3 precursor covers (`calibrateAndScore` writes `subseq`) — so `match` is the identified species for both levels. `score` stays −1 on MS3 (ProteoformTracker winner-select skips MS3 via `score<0`). |
| `fragments` | `std::vector<FragmentMatch>` | ✓ | ✓ | Per-fragment match details |
| `ppm_offset` | `double` | — | ✓ | Median PPM error from MS3 calibration pass |
| `correction_factor` | `double` | — | ✓ | `1 / (1 + ppm_offset * 1e-6)`; applied in tight pass |
| `ms3_fragment_coverage` | `float` | — | ✓ | Distinct backbone bonds covered / (L−1) over the matched MS3 sub-fragments (`calibrateAndScore`); `-1` = non-MS3/none. Logged as `identification.tsv` `ms3_fragment_coverage`. |

Default values for MS3-only fields: `ppm_offset = 0.0`, `correction_factor = 1.0`. MS2 paths leave them at these defaults — do not use them as signal for MS2 results.

## `FragmentAnalysis::ProteoformMatch::FragmentMatch`

Nested struct declared at `FragmentAnalysis.h:79`. One entry per matched fragment ion.

| Field | Type | MS2 | MS3 | Meaning |
|---|---|---|---|---|
| `ion_type` | `std::string` | ✓ | ✓ | MS2: `a`/`b`/`y`/etc. (per fragmentation method). MS3-local: adds `yb`/`ya` for N-terminal subsequence precursors. |
| `ion_index` | `int` | ✓ | ✓ | 1-based. MS2: proteoform-space. MS3: subsequence-space. |
| `observed_mass` | `double` | ✓ | ✓ | **Measured** — deconvolved observed mass in the fragment's own scan frame; calibrated for MS3 (pass-2). MS3 = subsequence frame. |
| `equiv_type` | `std::string` | — | ✓ | MS3 only: full-protein equivalent ion type (`b` or `y`). |
| `equiv_index` | `int` | — | ✓ | MS3 only: full-protein equivalent ion index. |
| `adjusted_mass` | `double` | — | ✓ | **Adjusted** — measured re-expressed in the full-protein (MS2) frame **with mods**: `observed + offset + ambiguous_included` (`MS3FragmentMatcher.cpp` calibrateAndScore). Re-adding `ambiguous_included` is the bare-backbone fix — without it a still-ambiguous mod is stripped, ~526 Da low for cytC. Trivial b→b frame ⇒ `adjusted == observed`. |
| `theoretical_mass` | `double` | ✓ | ✓ | **Theoretical** — mass the proteoform predicts for the ion. MS2: the matcher's PTM-adjusted `best_theo` (`FragmentAnalysis.cpp:716`). MS3: mod-inclusive equivalent-ion theoretical = `offset + md.theoretical_mass + ambiguous_included`. Populated for **both** levels. |
| `diff_da` | `double` | ✓ | ✓ | Residual (Da). MS2: `observed − theoretical`. MS3: `adjusted − theoretical`. |
| `diff_ppm` | `double` | ✓ | ✓ | Residual in ppm = `diff_da / theoretical_mass * 1e6` (0 when `theoretical_mass == 0`). |

The three masses (measured / adjusted / theoretical) + residual are the fragment-representation contract — see the **Fragment masses** term in the repo-root `CONTEXT.md`. They surface per-fragment in `identification.tsv` (MS3 rows: `ms3_fragment_masses`=measured, `ms2_fragment_masses`=adjusted; `theoretical_masses`/`diff_da`/`diff_ppm` populated on **both** MS2 and MS3 rows) and, aligned, in the pooled log's grouped table (`combined_ms2_frame_masses`=adjusted, `combined_ms2_fragment_ions`=ion labels, `combined_measured`/`combined_theoretical`/`combined_diff_da`/`combined_diff_ppm`).

See `README.md` for the full MS2 and MS3-local ion-type domains.

## `FragmentAnalysis::PTMSite`

Declared at `FragmentAnalysis.h:60`. A modification locator that can express ambiguity.

| Field | Type | Meaning |
|---|---|---|
| `position` | `int` | Midpoint position (1-based) |
| `start_position` | `int` | Start of the region where the PTM could localize (1-based) |
| `end_position` | `int` | End of the region where the PTM could localize (1-based) |
| `mass_shift` | `double` | Observed mass shift (modification mass) in Da |

**Localized** PTM: `start_position == end_position`. Position is known exactly.

**Ambiguous** PTM: `start_position != end_position`. The modification could be on any residue in the range `[start_position, end_position]`; observation alone cannot narrow it further.

Positions are 1-based in whatever sequence frame the owning `ProteoformMatch` represents. When carried in `ProteoformContext::ptm_sites` (see below), positions are relative to the proteoform (not the full protein). The helper `MS3FragmentMatcher::rebasePTMSites` (`MS3FragmentMatcher.cpp:287`) converts between frames.

## `toProForma` rendering

Static helper at `FragmentAnalysis.h:97` (defined at `FragmentAnalysis.cpp:1316`). Formats a proteoform sequence with PTM annotations using ProForma notation:

- **Localized** PTM (`start == end`): `PEPTK[+79.9663]IDE`
- **Ambiguous** PTM (`start != end`): `PEP(TKI)[+79.9663]DE`

Mass shifts are rendered with their sign. Multiple PTMs render independently at their respective positions.

## Logging: identification.tsv & scan_results.tsv reporting (I1–I3)

The engine writes four log streams in `FLASHIda.cpp` (`writeIdentificationRow_` / `writeScanResultRow_`). Three reporting fixes affect what they carry — all log-stream-only. (One value, `window_snr`, is now carried on the `ScanCommand` ABI struct via a `reserved_` carve — see below — but it is C++-internal; C# mirrors the field for layout parity only and never consumes it.)

- **MS3 proteoform sub-range** (`identification.tsv` `start_pos`/`end_pos`). For an MS3 row the precursor is a *fragment* of the parent proteoform, so these now report that fragment's sub-range, not the parent's full range. `MS3FragmentMatcher::calibrateAndScore` stores the sub-range into the result's `region_start`/`region_end` (0-based, exclusive end; it converts its internally-computed 1-based `prot_start/prot_end` — `MS3FragmentMatcher.cpp` ~:513), and the writer sources MS3 positions from `match` (`FLASHIda.cpp` ~:504) whenever populated (`>= 0`). The sub-range length equals the precursor fragment ion index.

- **`identification.tsv` isolation-window columns** — 6 new, appended after `ms3_fragment_masses` (19→25): `ms2_isolation_width`, `ms2_window_snr`, `ms2_charge_intensity`, and the MS3 trio. Width = `IsolationStage.isolation_width` (commanded, margin-inclusive; MS3 floored at 2.0 Da). charge_intensity = `precursor_intensity` / `precursor_intensity_s1` (= `PeakGroup::getChargeIntensity`). **`window_snr` is a NEW metric**: `signal / (noise + ε)` over the ACTUAL commanded window, where signal = the selected charge's intensity and noise = the remaining in-window intensity (co-isolation) summed on the SOURCE spectrum (MS1 for the MS2 window, MS2 `DeconvolvedSpectrum::getOriginalSpectrum()` for the MS3 window). Computed by `FragmentAnalysis::windowSnr` and carried **on the command itself** via the `ScanCommand.window_snr` field (8 bytes carved from `reserved_`, total still 2048; mirrored in C# `FLASHIdaWrapper.cs` + both `ScanCommandLayout` tests, default `-1.0` = not computed). It is stamped at command-build time (inside `Exploration::initiate` for variants; in the MS1 branch for regular MS2) and read back off the command into the in-memory `Exploration::MS2Context` fields. (The former `ScanCommandQueue` `scan_id → double` side-map was removed.)

- **`scan_results.tsv` `tag_count` and `proteoform_sequence`.** `tag_count` now logs the identification tagger's real count (`ProteoformMatch.tag_count`) when a proteoform matched — not the FASTA-DB-gated `tags_count` (which is 0 without a tag-targeting DB). For an **MS3** scan `proteoform_sequence` is the **clipped b/y fragment** — rendered from the acquisition context via `MS3FragmentMatcher::fragmentProForma` (extractSubsequence + rebasePTMSites + `toProForma`), so it is present for **every** scan even when identification is deferred/failed, and it uses the same fragment frame as `identification.tsv` (parent recoverable via `matched_protein` + `parent_tracking_id`). MS2 rows render the matched proteoform through `toProForma`.

- **`identification.tsv` `ms3_fragment_coverage`** — appended LAST (29→30 columns). On MS3 rows = distinct backbone bonds covered / (L−1) over the matched sub-fragments (prefix sub-ion index `p` → bond `p`; suffix → bond `L−p`), clamped `[0,1]`; `-1` on MS2. Computed in `calibrateAndScore`.

## MS3-local types

### `MS3FragmentMatcher::TheoreticalMass`

Declared at `MS3FragmentMatcher.h:38`. One theoretical fragment mass entry used during MS3 matching.

| Field | Type | Meaning |
|---|---|---|
| `mass` | `double` | Theoretical fragment mass (Da) |
| `position` | `int` | 1-based fragment index from the relevant terminus |
| `ion_type` | `std::string` | `a`, `b`, `y`, `yb`, `ya` |
| `includes_ptm` | `bool` | For ambiguous PTMs: `true` = this theoretical includes the PTM shift; `false` = no shift. Dual theoreticals generated per ambiguous site. |
| `ambiguous_included` | `double` | Sum of ambiguous PTM mass folded into this ion's `mass`: with-variant = fully-covered + partial; without-variant / no-overlap = fully-covered only. Copied onto `MatchDetail` and re-added to the equiv-frame offset so `FragmentMatch.adjusted_mass`/`theoretical_mass` retain the mods (the bare-backbone fix). |

### `MS3FragmentMatcher::MatchDetail`

Declared at `MS3FragmentMatcher.h:47`. Detail of a single observed-to-theoretical match.

| Field | Type | Meaning |
|---|---|---|
| `observed_mass` | `double` | Deconvolved observed mass |
| `theoretical_mass` | `double` | Matched theoretical mass |
| `ppm_error` | `double` | Signed ppm error: `(obs - theo) / theo * 1e6` |
| `ambiguous_included` | `double` | Ambiguous PTM mass folded into the matched theoretical (copied from `TheoreticalMass`); consumed in `calibrateAndScore` to build the mod-inclusive `adjusted_mass`/`theoretical_mass`. |
| `position` | `int` | 1-based fragment index from the relevant terminus |
| `ion_type` | `std::string` | As above |
| `includes_ptm` | `bool` | Whether the matched theoretical included an ambiguous PTM |

### `MS3FragmentMatcher::ProteoformContext`

Declared at `MS3FragmentMatcher.h:58`. Cached context carried from MS2 tag-matching into MS3 calibration.

| Field | Type | Meaning |
|---|---|---|
| `region_start` | `int` | 0-based start in protein sequence |
| `region_end` | `int` | 0-based exclusive end in protein sequence |
| `ptm_sites` | `std::vector<PTMSite>` | 1-based positions *relative to the proteoform* (not the full protein) |

Lifetime: populated when MS2 tag-matching identifies a proteoform; lives on the `ExplorationGroup` (see `../exploration/ms3-exploration.md`); consumed by `MS3FragmentMatcher::calibrateAndScore` post-all-received. Do not borrow references across group cleanup — snapshot the bounds and sites before the group is removed.

## Lifecycle summary

| Type | Constructed by | Consumed by | Crosses ABI? |
|---|---|---|---|
| `ProteoformMatch` | `FragmentAnalysis::getTopFragmentMatches`, `MS3FragmentMatcher::calibrateAndScore` | Exploration scoring, identification row writer | No |
| `FragmentMatch` | Same as parent `ProteoformMatch` | Same | No |
| `PTMSite` | FLASHExtender (via `FragmentAnalysis`) | `ProteoformMatch`, `ProteoformContext`, `toProForma` | No |
| `TheoreticalMass` | `MS3FragmentMatcher` internal | `MS3FragmentMatcher` internal | No |
| `MatchDetail` | `MS3FragmentMatcher` internal | `MS3FragmentMatcher` internal | No |
| `ProteoformContext` | MS2 result path in `FLASHIda::processScan` | `MS3FragmentMatcher::calibrateAndScore` via `ExplorationGroup` | No |

All types are internal C++. No P/Invoke blittable mirrors required.

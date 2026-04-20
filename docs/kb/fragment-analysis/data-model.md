---
title: Fragment Analysis — Data Model
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:60   # PTMSite
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:69   # ProteoformMatch
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:79   # FragmentMatch (nested)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:97   # toProForma
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
| `ptm_sites` | `std::vector<PTMSite>` | ✓ | ✓ | PTM sites from FLASHExtender (localized or ambiguous) |
| `matched_protein` | `std::string` | ✓ | ✓ | Protein file / DB name (set to `fasta_file` when match count > 0) |
| `proteoform_sequence` | `std::string` | ✓ | ✓ | Matched protein sequence slice |
| `fragments` | `std::vector<FragmentMatch>` | ✓ | ✓ | Per-fragment match details |
| `ppm_offset` | `double` | — | ✓ | Median PPM error from MS3 calibration pass |
| `correction_factor` | `double` | — | ✓ | `1 / (1 + ppm_offset * 1e-6)`; applied in tight pass |

Default values for MS3-only fields: `ppm_offset = 0.0`, `correction_factor = 1.0`. MS2 paths leave them at these defaults — do not use them as signal for MS2 results.

## `FragmentAnalysis::ProteoformMatch::FragmentMatch`

Nested struct declared at `FragmentAnalysis.h:79`. One entry per matched fragment ion.

| Field | Type | MS2 | MS3 | Meaning |
|---|---|---|---|---|
| `ion_type` | `std::string` | ✓ | ✓ | MS2: `a`/`b`/`y`/etc. (per fragmentation method). MS3-local: adds `yb`/`ya` for N-terminal subsequence precursors. |
| `ion_index` | `int` | ✓ | ✓ | 1-based. MS2: proteoform-space. MS3: subsequence-space. |
| `observed_mass` | `double` | ✓ | ✓ | Deconvolved observed mass; calibrated for MS3 (pass-2). |
| `equiv_type` | `std::string` | — | ✓ | MS3 only: full-protein equivalent ion type (`b` or `y`). |
| `equiv_index` | `int` | — | ✓ | MS3 only: full-protein equivalent ion index. |
| `adjusted_mass` | `double` | — | ✓ | MS3 only: offset-adjusted to full-protein frame. |

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

## MS3-local types

### `MS3FragmentMatcher::TheoreticalMass`

Declared at `MS3FragmentMatcher.h:38`. One theoretical fragment mass entry used during MS3 matching.

| Field | Type | Meaning |
|---|---|---|
| `mass` | `double` | Theoretical fragment mass (Da) |
| `position` | `int` | 1-based fragment index from the relevant terminus |
| `ion_type` | `std::string` | `a`, `b`, `y`, `yb`, `ya` |
| `includes_ptm` | `bool` | For ambiguous PTMs: `true` = this theoretical includes the PTM shift; `false` = no shift. Dual theoreticals generated per ambiguous site. |

### `MS3FragmentMatcher::MatchDetail`

Declared at `MS3FragmentMatcher.h:47`. Detail of a single observed-to-theoretical match.

| Field | Type | Meaning |
|---|---|---|
| `observed_mass` | `double` | Deconvolved observed mass |
| `theoretical_mass` | `double` | Matched theoretical mass |
| `ppm_error` | `double` | Signed ppm error: `(obs - theo) / theo * 1e6` |
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

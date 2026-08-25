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

> **Column order (reordered 2026-07 for live-log legibility).** The four streams' physical column order was permuted (IDs first, related fields grouped); the authoritative current order is [`LOG_COLUMN_ORDER_REFERENCE.md`](../../../LOG_COLUMN_ORDER_REFERENCE.md) (repo root). Golden fixtures stay in the OLD order and are matched **by header name** at compare time (`LogGoldenComparer` + `GoldenListCanonicalizer`), so the reorder needed **no recapture**. The positional phrases below (`appended LAST`, index ranges) describe how each column was ADDED historically — *not* its current physical position; resolve current positions by name against the reference file.

- **MS3 proteoform sub-range** (`identification.tsv` `start_pos`/`end_pos`). For an MS3 row the precursor is a *fragment* of the parent proteoform, so these now report that fragment's sub-range, not the parent's full range. `MS3FragmentMatcher::calibrateAndScore` stores the sub-range into the result's `region_start`/`region_end` (0-based, exclusive end; it converts its internally-computed 1-based `prot_start/prot_end` — `MS3FragmentMatcher.cpp` ~:513), and the writer sources MS3 positions from `match` (`FLASHIda.cpp` ~:504) whenever populated (`>= 0`). The sub-range length equals the precursor fragment ion index.

- **`identification.tsv` isolation-window columns** — 6 new, following `ms3_fragment_masses` (current order: identification cols 21–26): `ms2_isolation_width`, `ms2_window_snr`, `ms2_charge_intensity`, and the MS3 trio. Width = `IsolationStage.isolation_width` (commanded, margin-inclusive; MS3 floored at 2.0 Da). charge_intensity = `precursor_intensity` / `precursor_intensity_s1` (= `PeakGroup::getChargeIntensity`). **`window_snr` is a NEW metric**: `signal / (noise + ε)` over the ACTUAL commanded window, where signal = the selected charge's intensity and noise = the remaining in-window intensity (co-isolation) summed on the SOURCE spectrum (MS1 for the MS2 window, MS2 `DeconvolvedSpectrum::getOriginalSpectrum()` for the MS3 window). Computed by `FragmentAnalysis::windowSnr` and carried **on the command itself** via the `ScanCommand.window_snr` field (8 bytes carved from `reserved_`, total still 2048; mirrored in C# `FLASHIdaWrapper.cs` + both `ScanCommandLayout` tests, default `-1.0` = not computed). It is stamped at command-build time (inside `Exploration::initiate` for variants; in the MS1 branch for regular MS2) and read back off the command into the in-memory `Exploration::MS2Context` fields. (The former `ScanCommandQueue` `scan_id → double` side-map was removed.)

- **`scan_results.tsv` is a pure acquisition-event log (slim-down: 34→29 columns).** The former identification payload — `tag_count`, `matched_protein`, `proteoform_sequence`, `tic_coverage`, `fragment_count` — was **removed**. The MS3 fragment proteoform moved to **`scan_commands.tsv` `ms3_proteoform`** (see below); `tic_coverage` moved to `identification.tsv`; `tag_count` was dropped entirely (no home). **That last clause is no longer true:** `tag_count` returned, alongside `fragment_count` and a second copy of `tic_coverage`, as the identification-YIELD block at `scan_results` cols 13-15 (29→32), and `tag_count` also landed on `identification.tsv` (32→34, with `fragment_qscores`). It reports `ProteoformMatch::tag_count` — taken before any protein is consulted — and **not** the FASTA-gated targeting return, which is a detection gate. Sentinels: `-1` no count reported (MS1, MS3), `0` ran and read nothing, `>0` real.
- **`scan_commands.tsv` `ms3_proteoform`** (a 30→31 column addition; current order: scan_commands col 27, followed by `scan_description`/`faims_cv`/`faims_enabled`/`first_mass`/`last_mass`/`enqueue_ts` — the log is 34 columns wide as of ADR-0026 decision 6). On MS3 command rows = the **wide clipped b/y fragment** ProForma of the target being fired — rendered at command-build time via `MS3FragmentMatcher::fragmentProForma`, stashed in `ScanCommandQueue::ms3_cmd_proteoform_` (a `scan_id → string` side-map), drained by `takeMS3Proteoform` in `FLASHIda::getNextScanCommand`. Present for **every** MS3 command (regular + exploration), even ones that never return; `""` on MS1/MS2/AGC. No ABI change (the 2048-byte `ScanCommand` struct is untouched — the proteoform rides the log row, not the struct).
- **`identification.tsv` `tic_coverage`** (a 31→32 column addition; the trailing identification column in the current order). The per-scan TIC / matched-fragment coverage, moved here from scan_results; the exact value the engine used for that scan (`expl_result.tic_coverage` / `ms3_targeting.tic_coverage` / the MS3-reg `ms3_tic`), threaded onto the id-row descriptor.

- **`identification.tsv` `ms3_fragment_coverage`** — on MS3 rows = distinct backbone bonds covered / (L−1) over the matched sub-fragments (prefix sub-ion index `p` → bond `p`; suffix → bond `L−p`), clamped `[0,1]`; `-1` on MS2. Computed in `calibrateAndScore`. (Now second-to-last; `tic_coverage` is the trailing column.)

- **`identification.tsv` `proteoform` — MS3 mods are per-scan NARROWED.** An MS3 identification row renders the same clipped b/y fragment as the `scan_commands.ms3_proteoform` target, but its ambiguous PTM ranges are tightened by **only that scan's own matched sub-fragments** — distinct from the wide `scan_commands` render and from the pooled cumulative trajectory. `IdaLogger::writeIdentificationRow` narrows a **local copy** of `match.ptm_sites` via `FragmentAnalysis::narrowFragmentPTMSites(match.ptm_sites, match.proteoform_sequence.size(), match.fragments)` (gated `ms_level==3`), which mirrors the MS3 pass of `ProteoformTracker::narrowModifications_` in the subsequence frame. One writer site covers all three MS3 id-row sinks (`R` + `E`-primary + `E`-winner). Pooled (seeded from the MS2 winner, `ProteoformTracker.cpp:251`) and the `scan_commands` render are untouched. **Narrowing gradient:** `scan_commands` wide → `identification` this-scan-narrow → `pooled` cumulative-narrow.

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

# Fragment Analysis KB Packet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new top-level KB packet `docs/kb/fragment-analysis/` covering fragment-spectra analysis across three acquisition modes (tag+follow-up, MS2 matching, MS3 matching), plus propagate see_also / pointer updates to existing packets.

**Architecture:** Five new files in a new top-level packet at integration-layer depth. Shared data structures centralized in `data-model.md`; each of three mode files is self-contained. Cross-cutting updates propagate to 4 existing packets.

**Tech Stack:** Markdown, YAML frontmatter. All documentation work — no code changes.

---

## Pre-flight: Anchor Verification

All code anchors cited in this plan have been verified against the current checkout at commit `3a452e0` (phase-11 branch). If any anchor fails to resolve when an implementer reads the file, stop and re-verify before writing.

Verified anchor table (source of truth for all `code_anchors` entries):

| Anchor | Verified content |
|--------|------------------|
| `FragmentAnalysis.h:60` | `struct PTMSite` declaration |
| `FragmentAnalysis.h:69` | `struct ProteoformMatch` declaration |
| `FragmentAnalysis.h:79` | `struct FragmentMatch` (nested) declaration |
| `FragmentAnalysis.h:97` | `toProForma` signature |
| `FragmentAnalysis.h:100-104` | `getIonTypesForFragmentationMethod` comment + signature |
| `FragmentAnalysis.h:127` | `getBestMS2Masses` signature |
| `FragmentAnalysis.h:154` | `getTopFragmentMatches` signature |
| `FragmentAnalysis.h:190` | `getTerminalFragmentIons` signature |
| `FragmentAnalysis.cpp:380` | `runTagBasedFragmentMatching_` definition |
| `FragmentAnalysis.cpp:759` | `getTopFragmentMatches` definition |
| `FragmentAnalysis.cpp:843` | `getAmbiguityEnclosingIons` definition |
| `FragmentAnalysis.cpp:1151` | `getTerminalFragmentIons` definition |
| `FragmentAnalysis.cpp:1316` | `toProForma` definition |
| `MS3FragmentMatcher.h:58` | `struct ProteoformContext` |
| `MS3FragmentMatcher.h:66` | `LOOSE_TOLERANCE_PPM` constant |
| `MS3FragmentMatcher.h:107` | `rebasePTMSites` declaration |
| `MS3FragmentMatcher.h:115` | `calibrateAndScore` declaration |
| `MS3FragmentMatcher.cpp:287` | `rebasePTMSites` definition |
| `MS3FragmentMatcher.cpp:397` | `calibrateAndScore` definition |
| `Exploration.cpp:400` | `MS3FragmentMatcher::calibrateAndScore` call in `feedResult` |
| `Exploration.cpp:716` | `computeExplorationScore_` dispatcher |
| `Exploration.cpp:734` | `FragmentCount` case (inlined) |
| `Exploration.cpp:793` | `computeFragmentMatch_` definition |
| `FLASHIda.cpp:891` | `tags_found` declaration |
| `FLASHIda.cpp:897` | `processMS2ForTagBasedTargeting` call |
| `FLASHIda.cpp:900-908` | Quantification follow-up emit |
| `FLASHIda.cpp:913-916` | Conditional MS2 follow-up emit |
| `ScanCommandQueue.cpp:344` | `buildFollowUp` signature |
| `Config.cpp:140-148` | `tagging.follow_up_scan` parse |
| `MethodParameters.cs:137-148` | C# `Tagging.FollowUpScan` config |

---

## Task 1: Commit the plan

**Files:**
- Commit: `docs/superpowers/plans/2026-04-20-kb-fragment-analysis.md`

- [ ] **Step 1: Commit the plan**

```bash
git add docs/superpowers/plans/2026-04-20-kb-fragment-analysis.md
git commit -m "plan: KB packet for fragment-spectra analysis"
```

---

## Task 2: Create `docs/kb/fragment-analysis/README.md`

**Files:**
- Create: `docs/kb/fragment-analysis/README.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p docs/kb/fragment-analysis
```

- [ ] **Step 2: Write README.md**

File contents:

````markdown
---
title: Fragment Analysis Packet
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:913         # Mode 1 entry: conditional follow-up emit
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:793   # Mode 2 entry: computeFragmentMatch_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400   # Mode 3 entry: calibrateAndScore call
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:69    # ProteoformMatch struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:58   # ProteoformContext struct
see_also:
  - ../exploration/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../config-flow/README.md
---

## Overview

FLASHIda's fragment-matching machinery (`FragmentAnalysis`, `MS3FragmentMatcher`) drives three distinct acquisition contexts. This packet covers each mode's integration points — where they wire in, what functions they call, what data flows — plus the shared data model they all return.

The three modes live in one packet because they share `FragmentAnalysis::ProteoformMatch` as the unified result type and use the same underlying tag-matching functions. They live *outside* `../exploration/` because tag+follow-up is not an exploration path.

## Three-mode map

| Mode | Entry point | Purpose |
|---|---|---|
| Tag + follow-up | `FLASHIda.cpp:913` | After MS2, if the precursor tag-matches the configured protein, enqueue a conditional follow-up MS2 scan |
| MS2 matching | `Exploration.cpp:793` (`computeFragmentMatch_`) | Populate `ProteoformMatch` for the `FragmentCount` exploration metric |
| MS3 matching | `Exploration.cpp:400` (`calibrateAndScore`) | Two-pass calibration + tight rematch, batch-re-score MS3 variants post-all-received |

## Ion-type reference

MS2 ion types, selected per fragmentation method via `FragmentAnalysis::getIonTypesForFragmentationMethod` (`FragmentAnalysis.h:100-104`):

| Fragmentation method | MS2 ion types |
|---|---|
| HCD, CID | `b`, `y` |
| ETD | `c`, `z` |
| EThcD, EtCID | `b`, `c`, `y`, `z` |
| UVPD | `a`, `b`, `c`, `x`, `y`, `z` |
| Any other / unknown | `b`, `y` (default) |

MS3-local ion types, selected per precursor-fragment class via `MS3FragmentMatcher::getMS3IonTypes` (`MS3FragmentMatcher.h:71`):

| Precursor fragment class | MS3-local ion types |
|---|---|
| `b`-precursor (subsequence from N-terminus) | `a`, `b`, `yb`, `ya` |
| `y`-precursor (subsequence from C-terminus) | `a`, `b`, `y` |

The cross-direction ion types (`yb`, `ya`) are MS3-only and only appear for b-precursor subsequences. They carry no water loss.

## Read Order

1. [data-model.md](data-model.md) — `ProteoformMatch`, `FragmentMatch`, `PTMSite`, `toProForma`, MS3-local types.
2. Whichever mode you need:
   - [tag-follow-up.md](tag-follow-up.md) — Mode 1.
   - [ms2-matching.md](ms2-matching.md) — Mode 2.
   - [ms3-matching.md](ms3-matching.md) — Mode 3.

## Out of Scope

- FLASHTagger / FLASHExtender algorithm internals — named and referenced, but internals (tag generation, sequence extension, PTM localization algorithm) are not explained here.
- Theoretical-mass calculation internals — only the "what" and "when" of computation; the "how" is deferred.
- Calibration math beyond the two-pass description (loose → tight; median ppm error → correction factor).
- Quantification follow-up mode (`FLASHIda.cpp:900-908`, suffix `'F'`) — sibling mechanism, tag-independent; deferred to a future quantification packet.
- Deconvolution internals — upstream subsystem; separate packet candidate.
````

- [ ] **Step 3: Verify frontmatter parses and anchors resolve**

Run (Grep output mode content):

```
Grep pattern "^title: " docs/kb/fragment-analysis/README.md
Grep pattern "^last_verified: " docs/kb/fragment-analysis/README.md
```

Expected: each returns exactly one line.

Spot-check one code anchor: `Grep pattern "conditional_ms2_enabled && tags_found" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`. Expected: one match at line 913-914.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/fragment-analysis/README.md
git commit -m "docs(kb): add fragment-analysis packet README"
```

---

## Task 3: Create `docs/kb/fragment-analysis/data-model.md`

**Files:**
- Create: `docs/kb/fragment-analysis/data-model.md`

- [ ] **Step 1: Write data-model.md**

File contents:

````markdown
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
| `ion_type` | `std::string` | ✓ | ✓ | MS2: `a`/`b`/`y`/etc. (per fragmentation method). MS3-local: adds `yb`/`ya` for b-precursor. |
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
````

- [ ] **Step 2: Commit**

```bash
git add docs/kb/fragment-analysis/data-model.md
git commit -m "docs(kb): add fragment-analysis data-model.md"
```

---

## Task 4: Create `docs/kb/fragment-analysis/tag-follow-up.md`

**Files:**
- Create: `docs/kb/fragment-analysis/tag-follow-up.md`

- [ ] **Step 1: Write tag-follow-up.md**

File contents:

````markdown
---
title: Tag Matching & Conditional Follow-Up Scan
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp, FlashIDA/src/Flash/MethodParameters.cs
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:891    # tags_found declaration
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:897    # processMS2ForTagBasedTargeting call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:913    # conditional follow-up emit
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:900    # sibling: quantification follow-up
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:344   # buildFollowUp signature
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:140             # tagging.follow_up_scan parse
  - FlashIDA/src/Flash/MethodParameters.cs:137                                    # C# Tagging.FollowUpScan
see_also:
  - README.md
  - data-model.md
  - ms2-matching.md
  - ../config-flow/config-flow.md
  - ../ms1-acquisition/targeting-modes.md
  - ../acquisition-loop/engine-entry-points.md
---

## Overview

After a normal MS2 returns, if the precursor tag-matches the configured protein, an additional MS2 scan is enqueued with different fragmentation parameters. This is the "conditional follow-up" mode, flagged by suffix character `'C'` in the enqueued command's type.

## Trigger

Three conditions must all hold:

1. **Config: `targeting.conditional_ms2_enabled` is true.** Gate flag; without it, the branch at `FLASHIda.cpp:913` never fires.
2. **Config: `tagging.follow_up_scan` block populated** with at least `analyzer`, `activation`, `collision_energy`, and `resolution`. Parsed at `Config.cpp:140-148`.
3. **Runtime: `tags_found` is true.** Set to `true` by `PrecursorSelection::processMS2ForTagBasedTargeting(precursor_mass, ms2_activation)` at `FLASHIda.cpp:897`; requires `targeting.protein_sequence` to be non-empty (tag matching has nothing to match against otherwise).

`Config::validate()` catches the common misconfiguration: conditional MS2 enabled without a `follow_up_scan` block throws `std::invalid_argument` at construction time (see `../config-flow/config-flow.md` Stage 9).

## Flow

Numbered sequence inside `FLASHIda::processScan`'s MS2 branch (non-exploration path):

1. MS2 returns to `processScan`; `tracking_id` is *not* an exploration variant.
2. Precursor context resolved; `deconv_.deconvolveMSn(...)` runs with the stored MS2 result.
3. `PrecursorSelection::processMS2ForTagBasedTargeting(precursor_mass, ms2_activation)` runs tag match against the configured protein. Returns `bool tags_found`.
4. *(Separately, at `FLASHIda.cpp:900-908`)* quantification follow-up check runs — see Gotchas.
5. Branch at `FLASHIda.cpp:913-916`:
   ```cpp
   if (config_.targeting().conditional_ms2_enabled && tags_found)
   {
     auto cond = queue_.buildFollowUp(ctx, config_.targeting().tagging_follow_up_scan, 'C');
     queue_.push(cond);
     // ...
   }
   ```
6. MS3 targeting continues downstream (`initiateNextLevel`).

## Follow-up scan shape

The enqueued scan is a standard MS2 on the same precursor isolation, using the `follow_up_scan.*` block as its scan config:

- `analyzer` — Orbitrap / IonTrap / etc.
- `activation` — HCD / CID / ETD / EThcD / etc. (new activation type, typically different from the first MS2)
- `collision_energy` — fixed CE for the follow-up
- `resolution` — Orbitrap resolution

No fragment-ion-level targeting — the follow-up fragments the whole precursor. `buildFollowUp` (`ScanCommandQueue.cpp:344`) takes the parent context, the config block, and a suffix char:

```cpp
ScanCommand buildFollowUp(const ScanCommand& ctx,
                          const ScanConfig& follow_up_config,
                          char suffix,
                          int priority = /* default */);
```

The suffix char goes into the `type` field of the emitted command; `'C'` marks this as "conditional" (from tag match) vs. `'F'` for quantification follow-up. The suffix appears in log lines (`ScanCommandQueue.cpp:367`) and downstream TSV output.

## Config keys

`method.json` (user-facing):

```json
{
  "targeting": {
    "protein_sequence": "...",
    "conditional_ms2": true
  },
  "tagging": {
    "min_tag_length": 3,
    "max_tag_length": 7,
    "max_ptm_count": 1,
    "max_flanking_mass_diff": 500.0,
    "follow_up_scan": {
      "analyzer": "Orbitrap",
      "activation": "ETD",
      "collision_energy": 0,
      "resolution": 60000
    }
  }
}
```

See `../config-flow/config-flow.md` for how these keys become the C# `MethodParameters` tree and the C++ `Config::targeting_` / `Config::tagging_` structs.

## C# side

Briefly — see `../config-flow/` for full detail:

- `MethodParameters.Tagging.FollowUpScan` — C# POCO mirror of the `follow_up_scan` JSON block (`MethodParameters.cs:137-148`).
- `MethodParameters.Tagging.ConditionalMS2` → wire key `conditional_ms2` in the C++ JSON (`MethodParameters.cs:247`).

## Gotchas

- **Silently-off on missing protein sequence.** `conditional_ms2_enabled = true` + empty `protein_sequence` means `tags_found` will never be `true`. The mode is configured but never fires. `Config::validate()` does *not* catch this — it only checks that `follow_up_scan` is populated when `conditional_ms2_enabled` is set. An operator may see zero conditional follow-ups and have no diagnostic.

- **Sibling: quantification follow-up.** At `FLASHIda.cpp:900-908` there is a parallel mechanism that uses the same `buildFollowUp` machinery with suffix `'F'` (gated by `quantification.enabled` and `isDifferentiallyAbundant`, independent of tags). It is a different acquisition mode and is out of scope for this packet — a future quantification packet will cover it.

- **Priority ordering.** Follow-ups land at the same queue priority tier as MS2/MS3; specific ordering depends on `buildFollowUp`'s `priority` argument. See `../acquisition-loop/engine-entry-points.md` for how `getNextScanCommand` picks from the queue (AGC and cycle-time MS1 can preempt).
````

- [ ] **Step 2: Commit**

```bash
git add docs/kb/fragment-analysis/tag-follow-up.md
git commit -m "docs(kb): add fragment-analysis tag-follow-up.md"
```

---

## Task 5: Create `docs/kb/fragment-analysis/ms2-matching.md`

**Files:**
- Create: `docs/kb/fragment-analysis/ms2-matching.md`

- [ ] **Step 1: Write ms2-matching.md**

File contents:

````markdown
---
title: MS2 Fragment Matching
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:716   # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:734   # FragmentCount case (inlined)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:793   # computeFragmentMatch_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:759   # getTopFragmentMatches definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:154   # getTopFragmentMatches signature
see_also:
  - README.md
  - data-model.md
  - ms3-matching.md
  - ../exploration/scoring-and-winner.md
---

## Overview

MS2 fragment matching in this packet refers to the specific call inside exploration's `FragmentCount` metric scoring: `Exploration::computeFragmentMatch_` delegates to `FragmentAnalysis::getTopFragmentMatches` against the configured protein sequence. The returned `total_match_count` is the metric score.

This is a read of the match count — the engine does not act on the matched fragments themselves at this level. For actual fragment-ion-targeted scan building, see `../exploration/ms3-exploration.md` and `tag-follow-up.md`.

## Context

The exploration scoring dispatcher `Exploration::computeExplorationScore_` (`Exploration.cpp:716`) switches on `ExplorationMetric`. The `FragmentCount` case is inlined at `:734`:

```cpp
case ExplorationMetric::FragmentCount:
  return static_cast<double>(fmr.total_match_count);
```

`fmr` is a `FragmentAnalysis::ProteoformMatch` produced upstream in the dispatcher by a call to `computeFragmentMatch_`.

## Flow

Inside `Exploration::computeFragmentMatch_` at `Exploration.cpp:793`:

1. Read `config_.targeting().protein_sequence` and the input `DeconvolvedSpectrum`.
2. **Short-circuit** on empty protein sequence OR empty spectrum → return an empty `ProteoformMatch` (`total_match_count == 0`).
3. Otherwise, call:
   ```cpp
   fragments_.getTopFragmentMatches(
       seq, /*max_matches=*/100,
       masses.data(), qscores.data(), charges.data(),
       wstarts.data(), wends.data(),
       ion_types.data(), frag_indices.data(),
       spec_copy, result, activation_type,
       config_.level(msn_level).exploration_tolerance_ppm);
   ```
   — with `result` as the output `ProteoformMatch` populated in place.
4. If `result.total_match_count > 0`, set `result.matched_protein = config_.targeting().fasta_file`.
5. Return `result` to the dispatcher; `total_match_count` becomes the `FragmentCount` score.

## Tolerance source

`config_.level(msn_level).exploration_tolerance_ppm`, NOT `level(msn_level).tolerance_ppm`. These are separate per-level config fields — `exploration_tolerance_ppm` is used by exploration scoring (here and in MS3 calibration); `tolerance_ppm` is used elsewhere in the MS2 deconvolution and matching pipeline.

When debugging tolerance-related behavior in MS2 exploration scoring, check `exploration_tolerance_ppm` in the relevant level config first.

## Max matches

Hardcoded `100` inside `computeFragmentMatch_`. The caller-facing `FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.h:154`) accepts an `n` parameter; the internal call always passes 100. The returned `total_match_count` is *uncapped* (reflects actual matches), but the per-fragment arrays are capped at 100.

## Underlying matching function

`FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.cpp:759`) runs tag-based fragment matching using the stored MS2 deconvolution results. It is the same function invoked (with different tolerance parameters) by the tag+follow-up mode's `PrecursorSelection::processMS2ForTagBasedTargeting` path. Internals (FLASHTagger / FLASHExtender orchestration, fragment indexing) are out of scope for this packet; see the OpenMS source or a future deep-dive packet.

## Gotchas

- **Silent zero-score on missing config.** An empty `protein_sequence` returns an empty `ProteoformMatch` with `total_match_count = 0`. This is indistinguishable downstream from a legitimate zero-match result. Empty protein + `FragmentCount` metric means all variants score 0 and winner selection picks the first non-baseline variant (strict `>` comparator; see `../exploration/scoring-and-winner.md`).

- **Shared function, different tolerance paths.** `getTopFragmentMatches` is also used for tag detection in tag+follow-up mode (via `PrecursorSelection::processMS2ForTagBasedTargeting`). That caller reaches it with a *different* tolerance argument — check the specific call site when debugging tolerance drift across modes.

- **`exploration_tolerance_ppm` vs. `tolerance_ppm`.** Config divergence risk. When adjusting `method.json` for MS2 scoring tolerance, the relevant key is `ms_settings.ms2.exploration_tolerance_ppm` (not `tolerance_ppm`). Both exist; both flow from config-flow into per-level config; only the former is read by `computeFragmentMatch_`.
````

- [ ] **Step 2: Commit**

```bash
git add docs/kb/fragment-analysis/ms2-matching.md
git commit -m "docs(kb): add fragment-analysis ms2-matching.md"
```

---

## Task 6: Create `docs/kb/fragment-analysis/ms3-matching.md`

**Files:**
- Create: `docs/kb/fragment-analysis/ms3-matching.md`

- [ ] **Step 1: Write ms3-matching.md**

File contents:

````markdown
---
title: MS3 Fragment Matching
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
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
       config_.level(3).exploration_tolerance_ppm,
       &detailed_results);
   ```
3. **Pass 1 — calibration.** For each variant, match observed deconvolved masses against theoretical masses computed from the precursor subsequence, using the **loose tolerance** `LOOSE_TOLERANCE_PPM = 500.0` (compile-time constant, `MS3FragmentMatcher.h:66`). Collect PPM errors of matched pairs; compute the median → `ppm_offset`. Derive `correction_factor = 1 / (1 + ppm_offset * 1e-6)`.
4. **Pass 2 — tight rematch.** Apply `correction_factor` to observed masses; rematch at the **tight tolerance** `config_.level(3).exploration_tolerance_ppm`. The resulting match count becomes the variant's calibrated score.
5. **Return.** Two aligned outputs, one entry per variant:
   - `calibrated_scores[vi]` — overwrites `group.variants[vi].score` and casts to `int` into `fragment_count`.
   - `detailed_results[vi]` — a `FragmentAnalysis::ProteoformMatch` (with `ppm_offset` and `correction_factor` populated) copied into each variant's `identification_result` field.
6. Winner selection then runs on the **calibrated** scores, not the initial ones.

## Ion types

`MS3FragmentMatcher::getMS3IonTypes(char precursor_ion_class)` at `MS3FragmentMatcher.h:71` returns ion types based on whether the MS3 precursor subsequence originated from a b-ion or y-ion MS2 fragment:

- **b-precursor** (`precursor_ion_class == 'b'`, subsequence from N-terminus): `a`, `b`, `yb`, `ya`.
- **y-precursor** (`precursor_ion_class == 'y'`, subsequence from C-terminus): `a`, `b`, `y`.

The cross-direction ion types `yb` and `ya` are MS3-only. `yb` is "what would be a y-ion if the subsequence were the full protein, but read in the b-direction of the subsequence"; `ya` is analogous for a-ions. No water loss (the cleavage that created the MS3 precursor already broke the amide bond).

## PTM-aware dual theoreticals

For each ambiguous PTM site in the proteoform (where `start_position != end_position`), `calibrateAndScore` generates **two theoretical masses** per fragment: one with the PTM mass shift included, one without. Either can match an observed peak.

The `includes_ptm` bool on `TheoreticalMass` and the matched `MatchDetail` records which variant matched. Localized PTMs (`start == end`) produce a single theoretical with `includes_ptm = true` for positions at/after the PTM and `false` before.

## Subsequence vs. full-protein indexing

Fragment indices produced internally are **subsequence-local** (1-based from the relevant terminus of the precursor subsequence). For reporting, they are mapped back to full-protein coordinates:

- `FragmentMatch::ion_type` / `ion_index` — subsequence-local.
- `FragmentMatch::equiv_type` / `equiv_index` / `adjusted_mass` — full-protein equivalent.

The PTM-site rebasing logic lives in `MS3FragmentMatcher::rebasePTMSites` at `MS3FragmentMatcher.cpp:287`. The mapping for ion positions (subsequence → full-protein) is applied during match result population.

## Gotchas

- **Cross-direction ion types only apply to b-precursors.** A y-precursor MS3 never sees `yb`/`ya` matches; only `a`/`b`/`y`. Do not add `yb`/`ya` to `getMS3IonTypes`'s y-precursor case without understanding what a "y of a y" would mean physically.

- **Calibration pass can match spurious peaks.** At 500 ppm, random mass coincidences can match. The tight pass filters these, but per-variant intermediate state exposed during debugging (e.g. `[calibrateAndScore]` log lines at `MS3FragmentMatcher.cpp:437`+) may show Pass-1 matches that do not survive Pass 2. Trust the Pass-2 result.

- **`ppm_offset` / `correction_factor` are MS3-only.** MS2 paths leave these at default (`0.0` / `1.0`). Do not compare or aggregate these fields across MS2 and MS3 `ProteoformMatch` values.

- **`detailed_results` is populated only for `FragmentCount` metric.** If the MS3 metric is anything else, `identification_result` on each variant stays at default — no fragment-level identification data is available post-scoring.

- **`ProteoformContext` lifetime bound to the group.** The context lives on `ExplorationGroup` (see `../exploration/ms3-exploration.md`). If you hold a reference to `ptm_sites` after the group is cleaned up, you are dereferencing freed memory. Snapshot what you need.
````

- [ ] **Step 2: Commit**

```bash
git add docs/kb/fragment-analysis/ms3-matching.md
git commit -m "docs(kb): add fragment-analysis ms3-matching.md"
```

---

## Task 7: Update `docs/kb/index.md`

**Files:**
- Modify: `docs/kb/index.md`

- [ ] **Step 1: Add fragment-analysis line to packet list**

Use Edit to insert the new bullet after the acquisition-loop entry:

old_string:
```
- [Acquisition loop](acquisition-loop/README.md) — end-to-end round-trip: startup, per-scan event flow, C++ engine entry points, shutdown.
```

new_string:
```
- [Acquisition loop](acquisition-loop/README.md) — end-to-end round-trip: startup, per-scan event flow, C++ engine entry points, shutdown.
- [Fragment analysis](fragment-analysis/README.md) — tag+follow-up mode, MS2 fragment matching, MS3 fragment matching + calibration.
```

- [ ] **Step 2: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): list fragment-analysis in kb index"
```

---

## Task 8: Update exploration packet

**Files:**
- Modify: `docs/kb/exploration/scoring-and-winner.md`
- Modify: `docs/kb/exploration/ms3-exploration.md`
- Modify: `docs/kb/exploration/variants-and-sweeps.md`
- Modify: `docs/kb/exploration/README.md`

- [ ] **Step 1: Add pointer + see_also to `scoring-and-winner.md`**

Edit 1 of 2 on this file — pointer inside `FragmentCount` bullet.

old_string:
```
- **`FragmentCount` — inlined (`Exploration.cpp:734-739`)**: no separate helper function. The dispatcher's case inlines `return static_cast<double>(fmr.total_match_count);` using the `FragmentMatchResult` produced by `computeFragmentMatch_`. On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (`Exploration.cpp:400`), which re-scores variants with calibrated per-variant fragment m/z tolerance **after** the initial winner is selected (see `ms3-exploration.md`).
```

new_string:
```
- **`FragmentCount` — inlined (`Exploration.cpp:734-739`)**: no separate helper function. The dispatcher's case inlines `return static_cast<double>(fmr.total_match_count);` using the `FragmentMatchResult` produced by `computeFragmentMatch_`. For the MS2 fragment-matching integration (what it calls, tolerance source, gotchas), see [`../fragment-analysis/ms2-matching.md`](../fragment-analysis/ms2-matching.md). On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (`Exploration.cpp:400`), which re-scores variants with calibrated per-variant fragment m/z tolerance **after** the initial winner is selected (see `ms3-exploration.md` for the exploration-flow view; [`../fragment-analysis/ms3-matching.md`](../fragment-analysis/ms3-matching.md) for the matcher-side view).
```

Edit 2 of 2 on this file — see_also update.

old_string:
```
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
---
```

new_string:
```
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
  - ../fragment-analysis/ms2-matching.md
  - ../fragment-analysis/ms3-matching.md
---
```

- [ ] **Step 2: Add pointer + see_also to `ms3-exploration.md`**

Edit 1 of 2 — pointer at top of the `calibrateAndScore` section.

old_string:
```
## Post-all-received: `MS3FragmentMatcher::calibrateAndScore`

MS3-only, `FragmentCount`-metric-only. After `all_received` flips true but **before** winner selection, `feedResult` calls `MS3FragmentMatcher::calibrateAndScore(...)` at `Exploration.cpp:400`. The gate is `group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3`.
```

new_string:
```
## Post-all-received: `MS3FragmentMatcher::calibrateAndScore`

> For the matcher-side view (two-pass calibration mechanics, MS3 ion types, dual theoreticals), see [`../fragment-analysis/ms3-matching.md`](../fragment-analysis/ms3-matching.md).

MS3-only, `FragmentCount`-metric-only. After `all_received` flips true but **before** winner selection, `feedResult` calls `MS3FragmentMatcher::calibrateAndScore(...)` at `Exploration.cpp:400`. The gate is `group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3`.
```

Edit 2 of 2 — see_also update.

old_string:
```
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
---
```

new_string:
```
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ../fragment-analysis/ms3-matching.md
---
```

- [ ] **Step 3: Add see_also to `variants-and-sweeps.md`**

old_string:
```
see_also:
  - exploration.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
---
```

new_string:
```
see_also:
  - exploration.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
  - ../fragment-analysis/data-model.md
---
```

- [ ] **Step 4: Add see_also to `exploration/README.md`**

old_string:
```
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
---
```

new_string:
```
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../fragment-analysis/README.md
---
```

- [ ] **Step 5: Commit**

```bash
git add docs/kb/exploration/scoring-and-winner.md docs/kb/exploration/ms3-exploration.md docs/kb/exploration/variants-and-sweeps.md docs/kb/exploration/README.md
git commit -m "docs(kb): link exploration packet to fragment-analysis"
```

---

## Task 9: Update ms1-acquisition packet

**Files:**
- Modify: `docs/kb/ms1-acquisition/README.md`
- Modify: `docs/kb/ms1-acquisition/targeting-modes.md`

- [ ] **Step 1: Add see_also to `ms1-acquisition/README.md`**

old_string:
```
see_also:
  - ../scan-pipeline/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
  - ../acquisition-loop/README.md
---
```

new_string:
```
see_also:
  - ../scan-pipeline/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
  - ../acquisition-loop/README.md
  - ../fragment-analysis/README.md
---
```

- [ ] **Step 2: Add pointer note below `tag_based_enabled` / `fasta_file` rows in `targeting-modes.md`**

old_string:
```
| `tag_based_enabled` | Enables protein-family tag expansion of target masses. |
| `fasta_file` | FASTA database for tag-based target expansion. |
```

new_string:
```
| `tag_based_enabled` | Enables protein-family tag expansion of target masses. |
| `fasta_file` | FASTA database for tag-based target expansion. |

> Related but distinct: the MS1-side tag-biased precursor selection controlled by the two keys above is different from the MS2-side tag confirmation + conditional follow-up scan, which is covered in [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md).
```

- [ ] **Step 3: Commit**

```bash
git add docs/kb/ms1-acquisition/README.md docs/kb/ms1-acquisition/targeting-modes.md
git commit -m "docs(kb): link ms1-acquisition targeting-modes to fragment-analysis"
```

---

## Task 10: Update acquisition-loop packet

**Files:**
- Modify: `docs/kb/acquisition-loop/README.md`
- Modify: `docs/kb/acquisition-loop/engine-entry-points.md`

- [ ] **Step 1: Add see_also to `acquisition-loop/README.md`**

old_string:
```
see_also:
  - ../scan-pipeline/README.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
---
```

new_string:
```
see_also:
  - ../scan-pipeline/README.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../fragment-analysis/README.md
---
```

- [ ] **Step 2: Add pointer in `engine-entry-points.md` to the conditional-follow-up line**

Read the current frontmatter `see_also` first. Then edit the MS2 branch to reference fragment-analysis.

Edit 1 of 2 — add pointer in the MS2 step list.

old_string:
```
   - Optional conditional MS2 (if tags found and
     `conditional_ms2_enabled` → `queue_.buildFollowUp(..., 'C')`).
```

new_string:
```
   - Optional conditional MS2 (if tags found and
     `conditional_ms2_enabled` → `queue_.buildFollowUp(..., 'C')`).
     Full mode write-up: [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md).
```

Edit 2 of 2 — add see_also entry if the file has a see_also block; otherwise skip this edit. Check first with:

```
Grep pattern "^see_also:" docs/kb/acquisition-loop/engine-entry-points.md
```

If present, add `../fragment-analysis/tag-follow-up.md` entry. If absent, skip this edit (the README see_also from Step 1 is sufficient).

- [ ] **Step 3: Commit**

```bash
git add docs/kb/acquisition-loop/README.md docs/kb/acquisition-loop/engine-entry-points.md
git commit -m "docs(kb): link acquisition-loop to fragment-analysis tag-follow-up mode"
```

---

## Task 11: Update config-flow packet

**Files:**
- Modify: `docs/kb/config-flow/README.md`
- Modify: `docs/kb/config-flow/config-flow.md`

- [ ] **Step 1: Add see_also to `config-flow/README.md`**

old_string:
```
see_also:
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
---
```

new_string:
```
see_also:
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../fragment-analysis/README.md
---
```

- [ ] **Step 2: Add pointer at `config-flow.md:136` conditional-MS2 mention**

old_string:
```
cannot both be active (they are mutually exclusive strategies for HCD energy
selection); conditional MS2 requires a `follow_up_scan` to be configured; and any
MS level configured for exploration must have exactly one scan config entry. Any
```

new_string:
```
cannot both be active (they are mutually exclusive strategies for HCD energy
selection); conditional MS2 requires a `follow_up_scan` to be configured (see [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md) for the downstream mode mechanics); and any
MS level configured for exploration must have exactly one scan config entry. Any
```

- [ ] **Step 3: Commit**

```bash
git add docs/kb/config-flow/README.md docs/kb/config-flow/config-flow.md
git commit -m "docs(kb): link config-flow conditional-MS2 to fragment-analysis"
```

---

## Final verification

After all 11 tasks committed:

- [ ] **Step 1: Verify all 5 new files exist**

```
Glob pattern "docs/kb/fragment-analysis/*.md"
```

Expected: 5 files (README.md, data-model.md, tag-follow-up.md, ms2-matching.md, ms3-matching.md).

- [ ] **Step 2: Spot-check frontmatter across new files**

```
Grep pattern "^last_verified: 2026-04-20" path "docs/kb/fragment-analysis/"
```

Expected: 5 matches (one per file).

- [ ] **Step 3: Spot-check see_also propagation**

```
Grep pattern "fragment-analysis" path "docs/kb/" output_mode "files_with_matches"
```

Expected matches:
- All 5 new files (self-refs in see_also)
- docs/kb/index.md
- docs/kb/exploration/scoring-and-winner.md
- docs/kb/exploration/ms3-exploration.md
- docs/kb/exploration/variants-and-sweeps.md
- docs/kb/exploration/README.md
- docs/kb/ms1-acquisition/README.md
- docs/kb/ms1-acquisition/targeting-modes.md
- docs/kb/acquisition-loop/README.md
- docs/kb/acquisition-loop/engine-entry-points.md
- docs/kb/config-flow/README.md
- docs/kb/config-flow/config-flow.md

- [ ] **Step 4: No broken anchors**

No step here — verification is inherent to the Edit operations (they fail if old_string doesn't match) and the pre-flight anchor table. If any Edit fails, the implementer stops and re-verifies.

---

## Plan self-review

Spec-to-plan coverage check:

- Spec § Architecture packet structure → Tasks 2–6 (one per file)
- Spec § README.md specification → Task 2
- Spec § data-model.md specification → Task 3
- Spec § tag-follow-up.md specification → Task 4
- Spec § ms2-matching.md specification → Task 5
- Spec § ms3-matching.md specification → Task 6
- Spec § Cross-cutting: KB index → Task 7
- Spec § Cross-cutting: Exploration packet → Task 8
- Spec § Cross-cutting: MS1-acquisition packet → Task 9
- Spec § Cross-cutting: Acquisition-loop packet → Task 10
- Spec § Cross-cutting: Config-flow packet → Task 11
- Spec § Deliverables → all tasks collectively

No placeholders. No "TBD", no "similar to Task N", no hand-waving. Every file's full content is in the plan.

Consistency check: `ProteoformMatch`, `FragmentMatch`, `PTMSite`, `ProteoformContext`, `TheoreticalMass`, `MatchDetail` spelled and cased identically across all references. `calibrateAndScore`, `computeFragmentMatch_`, `getTopFragmentMatches`, `processMS2ForTagBasedTargeting`, `buildFollowUp` all consistent. Line numbers consistent with verification table.

Open questions from spec § "Open questions / known verifications" resolved in pre-flight table above.

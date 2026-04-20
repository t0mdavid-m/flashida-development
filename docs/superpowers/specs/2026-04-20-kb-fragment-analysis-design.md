# Fragment Analysis KB Packet Design

**Date:** 2026-04-20
**Scope:** new top-level KB packet covering fragment-spectra analysis across three acquisition modes
**Depth:** integration layer only (agent-oriented KB)

## Problem

FLASHIda's fragment-matching machinery (`FragmentAnalysis`, `MS3FragmentMatcher`) drives three distinct acquisition contexts:

1. **Tag-based identification with conditional follow-up MS2 scan** — after a normal MS2, if the precursor tag-matches the configured protein, enqueue an additional MS2 with different fragmentation parameters.
2. **MS2 fragment matching for exploration scoring** — `Exploration::computeFragmentMatch_` drives the `FragmentCount` metric by calling `FragmentAnalysis::getTopFragmentMatches`.
3. **MS3 fragment matching with two-pass calibration** — `MS3FragmentMatcher::calibrateAndScore` batch-re-scores MS3 variants post-all-received.

The existing KB covers integration touchpoints thinly:
- `exploration/scoring-and-winner.md` names `computeFragmentMatch_` in a single sentence (`:27`).
- `exploration/ms3-exploration.md` documents the `calibrateAndScore` handoff but not matcher internals.
- Tag+follow-up mode is not documented anywhere.
- Shared data model (`ProteoformMatch`, `PTMSite`, `FragmentMatch`, `ProForma` rendering, MS3-local types) is not centralized.

A future agent working on any of these three modes currently has to reverse-engineer shared structures and cross-mode wiring from source.

## Motivation

A future agent tasked with:
- Modifying the tag+follow-up trigger condition
- Changing which ion types are included in MS2 matching
- Debugging why an MS3 variant's calibration produced a spurious ppm offset
- Changing how PTM ambiguity affects ProForma rendering

...should find one packet that separates the three modes clearly, cross-references shared data structures, and points to existing packets for the scoring/exploration-flow sides.

## Scope

### In scope

- **Integration-layer documentation** of the three modes: trigger conditions, entry points, call graph, inputs/outputs, tolerance sources, config keys.
- **Shared data-model reference**: `ProteoformMatch`, nested `FragmentMatch`, `PTMSite`, `toProForma` rendering; MS3-local `TheoreticalMass`, `MatchDetail`, `ProteoformContext`.
- **Ion-type taxonomy** — reference table at packet entry, one row per fragmentation method × MS2 vs MS3-local ion sets.
- **Cross-mode gotchas**: tolerance config divergences (`exploration_tolerance_ppm` vs `level(N).tolerance_ppm`), silent-no-match behavior when protein sequence missing, suffix-char ('C' vs 'F') conventions.

### Out of scope

- **FLASHTagger / FLASHExtender algorithm internals** — black-boxed. Named and referenced as upstream algorithms; internals not explained.
- **Theoretical-mass calculation internals** — only the "what" and "when"; the "how" is deferred.
- **Calibration math** beyond two-pass description (loose → tight; median ppm → correction factor).
- **Quantification follow-up** mechanics (`FLASHIda.cpp:900-908`, suffix 'F') — flagged in tag-follow-up.md gotchas as sibling concept; deferred to future quantification packet (already identified as gap).
- **Deconvolution internals** — upstream; separate packet candidate per gap analysis.
- **Full-protein sequence alignment algorithm** — opaque; we document the inputs/outputs, not the algorithm.

## Architecture

### Packet location

Top-level: `docs/kb/fragment-analysis/`. Parallel to the 5 existing packets. Not nested under `exploration/` because tag+follow-up is not an exploration path.

### File structure

```
docs/kb/fragment-analysis/
├── README.md           # Packet entry + 3-mode map + ion-type reference
├── data-model.md       # Shared structs + MS3-local structs + ProForma
├── tag-follow-up.md    # Mode 1: tag match → conditional follow-up MS2
├── ms2-matching.md     # Mode 2: MS2 fragment matching in FragmentCount scoring
└── ms3-matching.md     # Mode 3: MS3 fragment matching + two-pass calibration
```

### Mode separation

The three mode files are deliberately independent — each covers one integration context, with cross-refs only for shared data-model items. A reader of `ms3-matching.md` should not need to read `tag-follow-up.md` to understand the MS3 path.

### Cross-cutting sharing

Four cross-cutting concepts are centralized:
- **Data structures** → `data-model.md`
- **Ion-type taxonomy** → ion-type reference table in `README.md`
- **PTM handling** → split: struct shape + ProForma rendering in `data-model.md`; per-mode detection/use in each mode file
- **Tolerance sources** → each mode file states its own source; `README.md` notes they diverge

## File specifications

### README.md

**Frontmatter:**
- `applies_to`: FragmentAnalysis.h/cpp, MS3FragmentMatcher.h/cpp, FLASHIda.cpp (tag-follow-up emit), Exploration.cpp (MS2/MS3 match call sites)
- `code_anchors`: one per mode entry point (3) + one per major type declaration (2-3)
- `see_also`: exploration/README.md, ms1-acquisition/README.md, acquisition-loop/README.md, config-flow/README.md

**Sections:**
1. **Overview** (~100 words) — three modes, why one packet, why not under exploration.
2. **Three-mode map** — small table: mode name → entry point (`file:line`) → one-sentence purpose.
3. **Ion-type reference table** — rows: HCD, CID, ETD, EThcD, EtCID, UVPD; columns: MS2 ion types (from `getIonTypesForFragmentationMethod`), MS3-local ion types (from `getMS3IonTypes(precursor_ion_class)`). Footnote: MS3 cross-direction ions (`yb`, `ya`) only appear for b-precursor subsequences.
4. **Read Order** — `data-model.md` first, then the mode(s) you need.
5. **Out of Scope** — FLASHTagger/FLASHExtender algorithm internals; quantification follow-up; deconvolution upstream.

### data-model.md

**Frontmatter:**
- `applies_to`: FragmentAnalysis.h (structs), MS3FragmentMatcher.h (MS3-local structs)
- `code_anchors`: one per struct declaration (5-6)
- `see_also`: README.md; each mode file

**Sections:**
1. **`FragmentAnalysis::ProteoformMatch`** — field-by-field table. Columns: field name, type, MS2-used?, MS3-used?, meaning. Explicitly flag `ppm_offset` and `correction_factor` as MS3-only.
2. **`FragmentAnalysis::ProteoformMatch::FragmentMatch`** (nested) — field-by-field table; flag `equiv_type`, `equiv_index`, `adjusted_mass` as MS3-only. Describe `ion_type` domain per mode (MS2: `a`/`b`/`y`/etc. from fragmentation method; MS3: also `yb`/`ya` for b-precursor).
3. **`FragmentAnalysis::PTMSite`** — localized (`start_position == end_position`) vs ambiguous semantics; position is 1-based protein-sequence index (or region-local — clarify from source).
4. **`toProForma` rendering** — two rules with examples from the header doc:
   - Localized: `PEPTK[+79.9663]IDE`
   - Ambiguous: `PEP(TKI)[+79.9663]DE`
5. **MS3-local types**: `TheoreticalMass`, `MatchDetail`, `ProteoformContext`. `ProteoformContext` is the lifecycle bridge — cached when MS2 tag match produces PTM sites, consumed by `calibrateAndScore`. Note `rebasePTMSites` helper at `MS3FragmentMatcher.cpp:287`.
6. **Lifecycle summary** — who constructs each, who consumes it, whether it crosses the ABI (none do — all internal C++).

### tag-follow-up.md

**Frontmatter:**
- `applies_to`: FLASHIda.cpp (emit), PrecursorSelection.cpp (tag matching entry), ScanCommandQueue.cpp (buildFollowUp), Config.cpp (parsing), MethodParameters.cs (C# config)
- `code_anchors`:
  - `FLASHIda.cpp:891` — `tags_found` declaration
  - `FLASHIda.cpp:897` — `processMS2ForTagBasedTargeting` call
  - `FLASHIda.cpp:913-916` — conditional follow-up emit
  - `ScanCommandQueue.cpp:344` — `buildFollowUp` signature
  - `Config.cpp:140` — `tagging.follow_up_scan` parse
  - `MethodParameters.cs:137-148` — C# tagging config
- `see_also`: data-model.md; ms2-matching.md; config-flow/config-flow.md; ms1-acquisition/targeting-modes.md

**Sections:**
1. **Trigger** — config prerequisites: `targeting.conditional_ms2_enabled` + `tagging.follow_up_scan` populated + `targeting.protein_sequence` non-empty; runtime gate: `tags_found` from PrecursorSelection.
2. **Flow** — numbered steps:
   1. MS2 returns to `processScan`.
   2. `PrecursorSelection::processMS2ForTagBasedTargeting(precursor_mass, ms2_activation)` runs tag match against configured protein.
   3. If `tags_found`, branch at `FLASHIda.cpp:913-916` enqueues conditional follow-up.
   4. `queue_.buildFollowUp(ctx, tagging_follow_up_scan, 'C')` — `'C'` marks it "conditional".
3. **Follow-up scan shape** — standard MS2 on same precursor with `follow_up_scan.{analyzer, activation, collision_energy, resolution}`. No special ion targeting at this stage.
4. **Config reference** — method.json keys: `tagging.follow_up_scan.*` and `targeting.conditional_ms2`.
5. **C# side** — brief, pointer to config-flow packet; `MethodParameters.Tagging.FollowUpScan` + `ConditionalMS2`.
6. **Gotchas**:
   - `conditional_ms2_enabled` + empty `protein_sequence` → `tags_found` never true; mode silently never fires.
   - **Quantification follow-up** (`FLASHIda.cpp:900-908`, suffix `'F'`) is a sibling mechanism — same `buildFollowUp` machinery, but tag-independent (gated by `quantification.enabled`). Out of scope here; deferred to future quantification packet.
   - Priority ordering: follow-ups slot before MS3/MS2 per default queue priorities — cross-ref `acquisition-loop/engine-entry-points.md`.

### ms2-matching.md

**Frontmatter:**
- `applies_to`: Exploration.cpp:computeFragmentMatch_, FragmentAnalysis.cpp:getTopFragmentMatches
- `code_anchors`:
  - `Exploration.cpp:716` — `computeExplorationScore_` dispatcher
  - `Exploration.cpp:734` — `FragmentCount` metric case
  - `Exploration.cpp:793` — `computeFragmentMatch_` definition
  - `FragmentAnalysis.cpp:759` — `getTopFragmentMatches` definition
- `see_also`: data-model.md; ms3-matching.md; exploration/scoring-and-winner.md

**Sections:**
1. **Context** — exploration's `FragmentCount` metric scoring; dispatcher at `Exploration.cpp:716`; metric case inlines `total_match_count` as the score at `:734`.
2. **Flow**:
   1. Variant MS2 deconvolved; surfaces to `computeFragmentMatch_`.
   2. If `config_.targeting().protein_sequence` empty OR spec empty → empty `ProteoformMatch` (score 0).
   3. Else: `fragments_.getTopFragmentMatches(seq, max_matches=100, …, exploration_tolerance_ppm)` with tolerance from `config_.level(msn_level).exploration_tolerance_ppm`.
   4. Result populated in-place; `matched_protein = fasta_file` on success.
   5. Caller reads `result.total_match_count` as `FragmentCount` score.
3. **Tolerance source** — `config_.level(msn_level).exploration_tolerance_ppm`, NOT `level(N).tolerance_ppm`. Per-level configurable.
4. **Max matches** — hardcoded `100` in `computeFragmentMatch_`; differs from caller-facing `getTopFragmentMatches` which takes `n` parameter.
5. **Gotchas**:
   - **Silent zero-score** on missing protein sequence — score of 0 is indistinguishable from "real zero matches."
   - Same `getTopFragmentMatches` function also used by tag-follow-up's tag-detection path (via PrecursorSelection) — different tolerance config reaches it from there.
   - `exploration_tolerance_ppm` ≠ `level(2).tolerance_ppm` — config divergence risk; check both when debugging tolerance behavior.

### ms3-matching.md

**Frontmatter:**
- `applies_to`: Exploration.cpp (calibrateAndScore call), MS3FragmentMatcher.h/cpp
- `code_anchors`:
  - `Exploration.cpp:400` — `calibrateAndScore` call site
  - `MS3FragmentMatcher.h:115` — `calibrateAndScore` signature (verify line)
  - `MS3FragmentMatcher.h:66` — `LOOSE_TOLERANCE_PPM` constant
  - `MS3FragmentMatcher.cpp:287` — `rebasePTMSites`
  - `MS3FragmentMatcher.cpp:405` — `calibrateAndScore` definition (verify line)
- `see_also`: data-model.md; ms2-matching.md; exploration/ms3-exploration.md

**Sections:**
1. **Context** — MS3 exploration's `FragmentCount` metric, post-all-received batch re-score. Gate from exploration side: `group.exploration_metric == FragmentCount && group.msn_level >= 3`.
2. **Flow**:
   1. Earlier: MS2 tag match produces `ProteoformContext` (region bounds + PTM sites), cached per group.
   2. All MS3 variants received → `feedResult` calls `MS3FragmentMatcher::calibrateAndScore(variants, ctx, …)` at `Exploration.cpp:400`.
   3. **Pass 1 (calibration)**: theoretical masses computed against subsequence with `LOOSE_TOLERANCE_PPM = 500`; median ppm error of matched pairs → `ppm_offset`, `correction_factor = 1 / (1 + ppm_offset * 1e-6)`.
   4. **Pass 2 (tight scoring)**: observed masses corrected; rematch at `level(3).exploration_tolerance_ppm`.
   5. Produces `scores[]` per variant + `detailed_results[]` (`ProteoformMatch` per variant).
3. **Ion types** — `getMS3IonTypes(precursor_ion_class)` behavior:
   - `b`-precursor: `a`, `b`, `yb`, `ya` (yb/ya are cross-direction, no water)
   - `y`-precursor: `a`, `b`, `y`
4. **PTM-aware dual theoreticals** — for ambiguous PTMs (`start != end`), two theoretical masses are computed per fragment (with and without PTM shift). Either can match; `includes_ptm` field flags which.
5. **Subsequence vs. full-protein indexing** — fragment indices inside MS3 `MatchDetail` are subsequence-local; `equiv_type`/`equiv_index`/`adjusted_mass` map back to full-protein space for reporting. The mapping logic is in `rebasePTMSites` (`MS3FragmentMatcher.cpp:287`).
6. **Gotchas**:
   - Cross-direction ion types (`yb`, `ya`) only appear for b-precursor subsequences; y-precursor MS3 scans use conventional ion types only.
   - Calibration pass at 500 ppm can match spurious peaks — these are filtered out in the tight pass but may appear in per-variant intermediate state if inspected mid-flow.
   - `ppm_offset` / `correction_factor` populated only by MS3 path; MS2 leaves them at default (`0.0` / `1.0`). Do not compare these fields across modes.

## Cross-cutting updates

### KB index
- `docs/kb/index.md` — add one line:
  `- [Fragment analysis](fragment-analysis/README.md) — tag+follow-up mode, MS2 fragment matching, MS3 fragment matching + calibration.`

### Exploration packet
- `docs/kb/exploration/scoring-and-winner.md`:
  - At `:27`, after the mention of `computeFragmentMatch_`, add pointer: "For the MS2 fragment-matching integration (what it calls, tolerance source, gotchas), see `../fragment-analysis/ms2-matching.md`."
  - Add `../fragment-analysis/ms2-matching.md` to frontmatter `see_also`.
- `docs/kb/exploration/ms3-exploration.md`:
  - At top of "Post-all-received: MS3FragmentMatcher::calibrateAndScore" section (`:51`), add pointer: "For the matcher-side view (two-pass calibration, MS3 ion types, dual theoreticals), see `../fragment-analysis/ms3-matching.md`."
  - Add `../fragment-analysis/ms3-matching.md` to frontmatter `see_also`.
- `docs/kb/exploration/variants-and-sweeps.md`:
  - Add `../fragment-analysis/data-model.md` to frontmatter `see_also`.
- `docs/kb/exploration/README.md`:
  - Add `../fragment-analysis/README.md` to frontmatter `see_also`.

### MS1-acquisition packet
- `docs/kb/ms1-acquisition/README.md`:
  - Add `../fragment-analysis/README.md` to `see_also`.
- `docs/kb/ms1-acquisition/targeting-modes.md`:
  - Near the `tag_based_enabled` / `fasta_file` rows (`:114-115`), add a note: "Related but distinct: the MS2-side tag confirmation + follow-up scan is covered in `../fragment-analysis/tag-follow-up.md`."
  - Add `../fragment-analysis/tag-follow-up.md` to `see_also`.

### Acquisition-loop packet
- `docs/kb/acquisition-loop/README.md`:
  - Add `../fragment-analysis/README.md` to `see_also`.
- `docs/kb/acquisition-loop/engine-entry-points.md`:
  - In the MS2 post-processing description (where tag match + follow-up emit happens at `FLASHIda.cpp:913`), add a one-line pointer to `../fragment-analysis/tag-follow-up.md` for the mode-side view.
  - Add `../fragment-analysis/tag-follow-up.md` to `see_also`.

### Config-flow packet
- `docs/kb/config-flow/README.md`:
  - Add `../fragment-analysis/README.md` to `see_also`.
- `docs/kb/config-flow/config-flow.md` (if it enumerates `tagging.follow_up_scan` keys):
  - Add a pointer to `../fragment-analysis/tag-follow-up.md` for downstream-flow detail.

### Not touched
- `scan-pipeline/` — no direct fragment-matching references.

## Deliverables

- **5 new files** under `docs/kb/fragment-analysis/`:
  - `README.md`
  - `data-model.md`
  - `tag-follow-up.md`
  - `ms2-matching.md`
  - `ms3-matching.md`
- **Updates to existing KB**:
  - `docs/kb/index.md` (+1 line)
  - 4 exploration files (see_also + 2 substantive pointers)
  - 2 ms1-acquisition files (see_also + 1 substantive pointer)
  - 2 acquisition-loop files (see_also + 1 substantive pointer)
  - 1-2 config-flow files (see_also)
- **Frontmatter discipline** — every new file carries:
  - `last_verified: 2026-04-20`
  - verified `code_anchors` (all must resolve before write)
  - correct `see_also` entries

## Open questions / known verifications

These need verification during implementation (plan stage):

1. **Exact line numbers for `MS3FragmentMatcher::calibrateAndScore`** — header and source. Plan pre-flight should confirm `:115` and `:405` (or update).
2. **`PTMSite::position` semantics** — 1-based protein-sequence index vs. 1-based region-local index. Resolve from source; header comment says "1-based, midpoint" and "1-based relative to proteoform" (`ProteoformContext`). Disambiguate in `data-model.md`.
3. **Whether `config-flow.md` already mentions `tagging.follow_up_scan`** — if yes, add pointer; if not, skip inline change.
4. **Whether `acquisition-loop/engine-entry-points.md` currently describes the conditional follow-up emit** — if yes, attach pointer; if not, consider a one-sentence addition.

These are minor-scope, plan-stage tasks — none affect the architecture or scope above.

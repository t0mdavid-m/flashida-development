---
title: Migration Illustration Slides — Design Spec
date: 2026-04-21
status: draft
scope: Three illustrative PowerPoint slides contrasting FLASHIda `mass_targeting` branch with OpenMS `FIdevelop` branch
---

## Problem

We need three presentation-grade slides that illustrate — at a glance — what changed between the pre-migration FLASHIda implementation (`FLASHIda:mass_targeting`) and the current state (OpenMS `FIdevelop` + thin-shell FlashIDA). The slides target a technical proteomics/MS audience and must each stand alone on a single slide.

## Audience & Tone

- Technical audience: proteomics researchers and adjacent developers familiar with MS workflows, not FLASHIda internals.
- Illustrative, not exhaustive: each slide picks a small set of high-contrast bullets plus one visual that makes the change obvious without reading the bullets.
- Each slide has one primary message; supporting bullets reinforce rather than enumerate.

## In Scope

- Title, bullet content, and visual description for three slides.
- Verification of every substantive claim against a code anchor in this repo.
- Markdown spec that a downstream renderer (human or tool) can convert to `.pptx`.

## Out of Scope

- Actual `.pptx` generation (deferred to the plan stage — option: `python-pptx` script vs. manual).
- Full migration narrative (additional slides, timelines, benchmarks).
- Any slide beyond the three specified below.

## Slide 1 — Architectural Change

### Primary message
The algorithm moved from C# (scattered across processors) into a single C++ engine; the C# side became a thin command pump with no intermediate queue.

### Title
**From C#-embedded algorithm to C++ engine + thin C# shell**

### Bullets

**Before — `FLASHIda:mass_targeting`**
- Algorithm logic spread across C#: `IDAScanProcessor`, `FAIMSScanProcessor`, `QuantScanProcessor`.
- C# `ScanScheduler` owned a `ConcurrentQueue<IFusionCustomScan>` — scheduled scans **accumulated in C#**.
  - Anchor: `FlashIDA:mass_targeting:src/Flash/ScanScheduler.cs` (declares `customScans`).
- Once a scan was enqueued in C#, the C++ side could no longer invalidate it — stale decisions shipped to the instrument.
- XML `method.xml`, loaded by `MethodConfig.cs`.
- Single algorithmic call into C++: `GetPeakGroupSize` (deconvolution helper).

**After — `OpenMS:FIdevelop` + current FlashIDA**
- Algorithm lives entirely in C++: deconvolution, targeting, exploration, fragment matching, selection, quantification.
- Single `UnifiedScanProcessor` on the C# side. No C# queue — C# pulls on demand via `GetNextScanCommand`.
- C++ owns the queue (`ScanCommandQueue`) and calls `queue_.cleanupExpired()` before every dispatch — **commands invalidated by fresh information are dropped before C# sees them**.
  - Anchors: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1143`, `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:114`, `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:421`.
- JSON `method.json` with reflection-driven `MethodConfigSerializer` + `[Developer]` / `[JsonKey]`.
- Five P/Invoke exports: `CreateFLASHIda`, `DisposeFLASHIda`, `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`.

### Visual

Two-panel side-by-side diagram.

**Left panel (Before).**
- `Flash.exe` box at top.
- Three stacked processor boxes (`IDAScanProcessor`, `FAIMSScanProcessor`, `QuantScanProcessor`) sharing a `ScanScheduler` queue box drawn as a **filled buffer** (several queued items visible, shaded to suggest staleness).
- Thin arrow from one processor to a small "C++ deconvolution helper" box labeled `GetPeakGroupSize`.
- Red annotation near the queue: *"buffered decisions — no invalidation path"*.

**Right panel (After).**
- `Flash.exe` box at top with one `UnifiedScanProcessor` below.
- Large C++ engine box labeled `FLASHIda (C++)` containing sub-labels: *Deconvolution · Targeting · Exploration · Fragment matching · Selection*.
- `ScanCommandQueue` drawn **inside** the C++ engine box, with a small sweep icon or broom labeled `cleanupExpired()` showing items being removed.
- Single arrow from `UnifiedScanProcessor` labeled `GetNextScanCommand` pulling one command at a time from the queue.
- Green annotation near `cleanupExpired()`: *"stale commands dropped before C# sees them"*.

Both panels use the same color for the C# tier and the same color for the C++ tier so the shift of mass from one to the other is visually unmistakable.

## Slide 2 — Exploration Mode

### Primary message
New capability: parameter variants are generated, scored by fragment count, and a winner is picked — applied at both MS2 and MS3.

### Title
**Parameter exploration: scored variant search at MS2 and MS3**

### Bullets

**Before:** No exploration. One fixed MS2 (single fragmentation method / energy / analyzer) per precursor. No MS3.

**After — per-level exploration**
- **Variant generation:** configurable sweeps over fragmentation method, HCD energy, MS analyzer, charge state, isolation width.
- **Routing:** each variant carries a `scan_description` tag; the result is routed back on completion.
- **Scoring:** `FragmentCount` (theoretical ions matched within tolerance) ranks variants.
- **Winner selection:** first scored variant dispatched; pending-set bookkeeping suppresses losers.
- **Two tiers:**
  - *MS2 exploration* picks the fragmentation for a precursor isolated from MS1.
  - *MS3 exploration* picks the refragmentation for a subsequence selected from an MS2.
- Config lives under `level(n).explore.*`; tolerance: `exploration_tolerance_ppm`.

### Visual

Fan-out diagram spanning both tiers, top to bottom:

1. **Top row — MS1 spectrum.** Single intact-protein peak highlighted (the picked precursor).
2. **Middle row — MS2 exploration fan-out.** The picked precursor fans into N variant MS2 scans (e.g., three labeled tiles: `HCD 20 eV`, `HCD 30 eV`, `ETD`). Each tile shows a small spectrum thumbnail. A score badge (ions matched) sits on each tile. One tile is outlined in green (winner); the others are greyed.
3. **Bottom row — MS3 exploration fan-out.** From the winning MS2, one fragment is circled and fans into M variant MS3 scans (e.g., three tiles: `HCD 20 eV`, `HCD 35 eV`, `CID`). Again each shows a thumbnail + score; one is outlined in green.
4. Arrows between rows labeled `scan_description` → pending → resolved.

The diagram must make clear that **the same exploration machinery runs at both tiers**, just with different inputs (precursor vs. MS2 subsequence).

## Slide 3 — Fragment Ion Matching at MS2 and MS3 Level

### Primary message
New capability: theoretical fragments are matched against acquired spectra in real time, at MS2 and MS3, with an MS3 self-calibration pass.

### Title
**Real-time fragment analysis: tag confirmation, MS2 scoring, MS3 calibration**

### Bullets

**Before:** None. The pipeline did not match theoretical fragments against acquired MS2/MS3 spectra during acquisition.

**After — three coordinated modes**

1. **Tag + follow-up (MS2)**
   - `FLASHTagger` → `FLASHExtender` produce candidate sequence tags from the MS2.
   - On match, a conditional MS2 follow-up is emitted (suffix `'C'`).
   - Gated at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:914`; requires `protein_sequence` / `fasta_file`.

2. **MS2 fragment counting (exploration-driven)**
   - `FragmentAnalysis::getTopFragmentMatches` scores ion matches inside exploration scoring.
   - Ion types depend on activation: HCD/CID → b, y; ETD → c, z; EThcD → b, y, c, z.
   - Tolerance: `exploration_tolerance_ppm`.

3. **MS3 fragment matching + calibration**
   - `MS3FragmentMatcher::calibrateAndScore`: two-pass — loose (500 ppm) derives per-scan correction factor, then tight re-match.
   - Ion types grouped by the **MS3-local** N/C terminus of the selected subsequence (a/b/c → N-term; y/x/z + default → C-term).
   - Tolerance: `tolerance_ppm` (distinct from MS2's `exploration_tolerance_ppm`).
   - Supports PTM-aware dual theoreticals and ambiguous-site localization.

**Unified result:** `ProteoformMatch` (with nested `FragmentMatch[]` and `PTMSite[]`) — shared across all three modes; MS3-only fields (`ppm_offset`, `correction_factor`) carry calibration output.

### Visual

A three-stage illustration reading left → right, showing **how a single proteoform is inspected at progressively finer resolution**:

1. **Stage 1 — MS1 intact proteoform.**
   - Spectrum thumbnail showing a single high-mass charge-state envelope highlighted.
   - Label: *"Intact proteoform selected"*.

2. **Stage 2 — MS2 fragments of the intact proteoform.**
   - Fragment spectrum thumbnail with several b/y ions marked.
   - Overlay: theoretical b/y ladder aligned with observed peaks; matched peaks highlighted.
   - Callouts: *"Tag match → conditional follow-up (mode 1)"* and *"FragmentCount scoring (mode 2)"*.
   - One fragment peak is circled and labeled *"fragment selected for MS3"*.

3. **Stage 3 — MS3 fragments of the MS2 fragment.**
   - Fragment-of-fragment spectrum thumbnail for the circled peak.
   - Overlay: MS3-local theoretical ladder (a/b/c or y/x/z depending on terminus), matched peaks highlighted.
   - Small inset: loose-pass (500 ppm) with scattered matches + arrow + tight-pass with calibrated matches on target. Caption: *"two-pass calibration (mode 3)"*.

Stage labels along the top read `MS1` → `MS2` → `MS3` to make the hierarchy (intact → fragment → fragment-of-fragment) unmistakable. A shared horizontal color band underneath all three stages carries the `ProteoformMatch` label to emphasize that one result struct accumulates across modes.

## Deliverable Format

- Markdown spec (this document) committed to `docs/superpowers/specs/`.
- Implementation plan (next step) decides rendering path. Two options:
  - **(a)** `python-pptx` script producing a `.pptx` with text blocks and placeholder shapes for the visuals (visuals drawn separately in Inkscape/PowerPoint).
  - **(b)** Manual PowerPoint authoring from this spec; plan delivers speaker notes and bullet transcripts only.

Choice deferred to the plan stage.

## Claim Provenance (Code Anchors)

All architectural claims above are grounded in the following anchors (verified 2026-04-21):

| Claim | Anchor |
| --- | --- |
| Old C# queue — `customScans` | `FlashIDA:mass_targeting:src/Flash/ScanScheduler.cs` |
| Old C# entry into C++ (`GetPeakGroupSize`) | `FlashIDA:mass_targeting:src/Flash/IDA/FLASHIdaWrapper.cs` |
| Current C++ queue | `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` |
| `cleanupExpired` dispatch-time call | `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1143` |
| `cleanupExpired` implementation | `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:421` |
| Conditional MS2 follow-up emit (suffix `'C'`) | `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:914` |
| MS3 calibrate-and-score tolerance | `docs/kb/fragment-analysis/ms3-matching.md` (see `Exploration.cpp:400-408`) |
| MS2/MS3 ion-type taxonomy | `docs/kb/fragment-analysis/README.md` |

## Open Questions

- None blocking. Rendering-format choice (python-pptx vs. manual) will be settled in the plan.

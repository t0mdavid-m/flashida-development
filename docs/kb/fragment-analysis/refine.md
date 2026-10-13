---
title: Refine — the second MS2 annotation method and the discriminating MS3 round
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Refine.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Refine.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-10-13
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Refine.h:71                 # class Refine (static functions only)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Refine.h:216                # struct RefineCandidates
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/RefineSettings.h:27         # struct RefineSettings (the seven knobs + tolerance)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:121      # ProteoformMatch::refine
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:931            # getTopFragmentMatches (the method switch at :950)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:794            # runRefineMatching_
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.h:192     # DiscriminatingRecord
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.h:202     # RefineState
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp:441           # finalize step 3b: the round's records
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp:550           # planNextScans: discriminating -> ambiguity after the decision or the fall-through
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp:1014          # planDiscriminating_ (dead_end: decided=fallthrough)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp:1116          # recordDiscriminatingScan (false once decided)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp:1161          # decideRefine
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:391                             # refineRoundClose_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:956                             # empty MS3 clears the stored deconvolution
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:1064                # dispatchFromModel (re-dispatch after the decision)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:1345                     # validate: the three refine refusals
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp:200                   # identification.tsv: the seven refine columns
  - FlashIDA/src/Flash/MethodConfig.cs:416                                                 # C# RefineBlockConfig
see_also:
  - README.md
  - data-model.md
  - ms2-matching.md
  - ms3-matching.md
  - ../../adr/0049-a-mass-shift-is-detected-before-the-path-and-flashtnt-stays-a-method.md
---

## Overview

`characterization.method` chooses which annotator interprets an MS2 scan against
`characterization.protein_sequence`: `flashtnt` (the default — FLASHTagger + FLASHExtender, see
[ms2-matching.md](ms2-matching.md)) or `refine` (ADR-0049). Refine needs no search: **Detect** offsets
every theoretical ion by a trial shift, subtracts what the unshifted ladder already explains, and keeps
the shift regions that pass an FDR against shuffled sequences as *levels*; **Assemble** runs one
dynamic programme per candidate total (λ_b + λ_y) and scores each best path as
`S = ions − jump_penalty × jumps`. The fourth MS3 objective, `characterization.mode: "discriminating"`
(refine only), spends one MS3 round on the masses that tell the two best totals apart, then decides.

The ADR owns the *why* and the decisions; this page is where the code lives and how the pieces join.

## Where it plugs in

| Step | Entry point | What it does |
|---|---|---|
| Method switch | `FragmentAnalysis::getTopFragmentMatches` (`FragmentAnalysis.cpp:931`, switch at `:950`) | `AnnotationMethod::Refine` → `runRefineMatching_`, else `runTagBasedFragmentMatching_`. Resets `result.refine` first |
| MS2 annotation | `runRefineMatching_` (`FragmentAnalysis.cpp:794`) | masses ascending → `Refine::ladder` → `detect` → `assemble`; prints `[LEVELS]`/`[CANDIDATES]`; the best path fills the `ProteoformMatch` |
| Round setup | `finalizeMS2` step 3b (`ProteoformTracker.cpp:441`) | winner's `RefineCandidates` → `RefineState`; with ≥ 2 totals, `Refine::discriminating` → `DiscriminatingRecord`s |
| Planning | `planNextScans` (`:550`) → `planDiscriminating_` (`:1014`) | undecided: the records not yet dispatched, intensity-desc, up to `max_targets` species (a b-only record goes out **unassigned**, `'u'`/0); decided (or no record): **ambiguity**. A round that can never close — pool exhausted with nothing outstanding — is decided **without recount or pooled row** (`[DISCRIMINATING] … decided=fallthrough reason=pool_exhausted`) and ambiguity is planned in the same call (an ETD winner is no longer a reason: its round runs, ADR-0054); a dispatched record still unreturned makes it wait instead |
| MS3 return | `recordDiscriminatingScan` (`:1116`), called from `FLASHIda.cpp`'s regular MS3 branch | `Refine::pieceTest` pools fits per record; true when every dispatched record has returned; false once the decision has fired (the record is frozen) |
| Decision | `FLASHIda::refineRoundClose_` (`FLASHIda.cpp:391`) → `decideRefine` (`ProteoformTracker.cpp:1161`) | `Refine::recount` over every record; a flip re-seeds mods + fragments from path b; pooled row trigger `MS3-DECIDE`. If no dispatched record has a b/y side (an ETD winner's c/z records, whose pieces `pieceTest` cannot predict), path a is kept **without** a recount: `[DISCRIMINATING] … decided=kept reason=no_annotatable_pieces`, no `[MS3-DECIDE]`, no pooled row (ADR-0054) |
| Re-dispatch | `Exploration::dispatchFromModel` (`Exploration.cpp:1064`) | the `initiateNextLevel` tail, extracted byte-identical, replaying `winner_cmd` as stage 0 |

Both MS2 routes reach the switch — the regular MS2 through `ProteoformTracker::selectNextLevelTargets`,
every exploration variant through `Exploration::computeFragmentMatch_` →
`ProteoformTracker::identifyExplorationFragments` — so the exploration model is seeded from the variant
with the highest S exactly as it is seeded from the highest extender score under `flashtnt`.

## Data

- `RefineSettings` (`RefineSettings.h:27`): `fdr 0.2`, `shuffles 300`, `grid_da 0.01`,
  `max_shift_da 700`, `min_ions 3`, `max_levels 20`, `jump_penalty 2`; the shuffle seed and the
  same-shift tolerance are constants. `tolerance_ppm` is level 2's, copied in by `Config`, never
  authored. Its own header breaks the `Config.h → Refine.h → FragmentAnalysis.h → Config.h` cycle.
- `Refine::Detect`: `cut`, every `Level` with its `excluded` reason (`None | NeutralLoss |
  NeutronSatellite | Capped`), `fdr_by_height`, `observed_at_zero`, `n_kept`.
- `Refine::Path`: `total`, `score`, `ions`, `jumps`, `levels`, one `windows` entry per jump, and
  `ions_explained` read at the placement with every jump at its window's first residue.
- `RefineCandidates` (`Refine.h:216`): Detect + every candidate path + `precursor_mass_difference`
  (measured precursor − (sequence mass + best total)), carried on `ProteoformMatch::refine`.

## Logging

`identification.tsv` gains seven appended columns (41 in all): `annotation_score`, `total_shift`,
`second_total_shift`, `second_score`, `cut`, `n_levels` (= `Detect::n_kept`),
`precursor_mass_difference`. They carry values on the regular and the exploration self-identification
MS2 rows under `refine`; everywhere else the sentinels `-1`, empty, empty, `-1`, `-1`, `-1`, empty.
A real score of −1 is distinguished from the sentinel by a non-empty `total_shift`. `tag_count` and
`flash_extender_score` stay −1 under `refine`. Column inventory: `LOG_COLUMN_ORDER_REFERENCE.md`.

Markers are stdout only: `[REFINE]` (attribution line, regular MS2 path only), `[LEVELS]`,
`[CANDIDATES]` (one per total), `[DISCRIMINATING]`, `[MS3-DECIDE]`, `[MS3-REDISPATCH]`. `ida.log`
carries none of them.

## Config

`characterization.method` (`flashtnt | refine`, exact spellings) and the `characterization.refine`
object. `Config::validate` (`Config.cpp:1337`) refuses a `refine` block under `flashtnt`,
`mode: "discriminating"` under `flashtnt`, and `discriminating` with an enabled level-3 exploration.
C# forwards the block verbatim or as `null` (`RefineBlockConfig`, `MethodConfig.cs:416`;
`ToJsonRefine` in `MethodParameters.cs`), so the refusal happens in C++. The validate skill mirrors the
refusals as A31–A33.

## Tests

- `Refine_test` — unit sections, the report's cytochrome c scan pinned at the engine's defaults, the
  seven corpus rows, the `FragmentAnalysis` switch. Reads `FlashIDA/test-data/refine/`.
- `ProteoformTracker_Discriminating_test` — the planner, pooling and the decision.
- Golden mode `refine_discriminating_cytc` (`FLASHIdaLogGolden_test.Golden_Refine_Discriminating_CytC`,
  guarded by `AssertRefineDecided`). Its round is b61 / y71 / y79; the two y-ion targets have no
  fixture and are answered by `ms3_empty_scan0.txt`.
- The expectation tables were written once by `FlashIDA/test-scripts/refine/make_refine_tables.py`
  from the vendored prototype. No test runs the prototype.

## Gotchas

- **An empty MS3 used to read back the previous scan's deconvolution**, in every mode
  (`FLASHIda.cpp:952` is the fix, OpenMS `3ea17e49cb`). No unit test; the refine golden's
  `mass_count 0` MS3 rows are the witness.
- **The recount needs every record**, dispatched or not: `Refine::recount` throws `InvalidParameter`
  when the two paths' shared counts disagree, which a partial target list produces.
- **The round closes only when every dispatched record has returned.** An MS3 that deconvolves to
  nothing still returns its record (with no evidence). A harness that skips an unfixtured MS3 leaves
  the round open forever — which is why the golden answers it empty.
- **A piece fits a path only if it carries a non-zero shift** (decision 8), and under `refine`
  `narrowModifications_` likewise moves a boundary only on a shift-carrying fragment.
- Accepted limits: MS3 evidence folded during the round is dropped on a flip; `Refine::assemble`
  returns empty without a message on a ladder size mismatch; a re-matched non-winner is stale after a
  flip; `[REFINE]` is not printed on the exploration MS2 path.
- `getAmbiguityEnclosingIons` / `getTerminalFragmentIons` (unreachable from config) still call the
  tag path directly and ignore the method.

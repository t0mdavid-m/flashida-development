---
title: KB Packet — MS2 / MS3 Exploration
status: implemented
created: 2026-04-20
---

# KB Packet — Exploration

## Purpose

Promote the existing `docs/kb/ms1-acquisition/exploration.md` into its own KB packet at `docs/kb/exploration/`, and deepen coverage so that both MS2 and MS3 exploration are first-class subjects. "Exploration" is a cross-cutting subsystem that spans MSn levels; filing it under `ms1-acquisition/` was convenient when it was MS2-only but is awkward now that MS3-specific work (fragment-ion targeting, proteoform context, batch re-scoring via `MS3FragmentMatcher`) is landed on `main`.

The packet follows the conventions established by the MS1-acquisition pilot (`2026-04-19-kb-ms1-acquisition-design.md`) and the config-flow packet (`2026-04-19-kb-config-flow-design.md`): frontmatter with `code_anchors`, `last_verified` dates, paths relative to the parent-repo root, pointers over paste, ≤200 lines per file. No infrastructure changes — only content.

## Goals

- **One home for exploration.** Agents asking "how does MS3 exploration work?" land on a packet named `exploration/`, not `ms1-acquisition/`.
- **Level parity.** MS2 and MS3 exploration each have a dedicated file; shared material (variant generation, scoring) is cross-cutting and cited from both.
- **Surface the two MS3 trigger paths.** MS3 exploration is reached both from MS2 exploration's winner (`Exploration::initiateNextLevel` called after winner selection) *and* from a regular non-exploration MS2 result (`FLASHIda.cpp:924`). Both paths converge on the same setup code. Miss this and MS3 behavior looks inconsistent.
- **Document MS3-specific machinery.** Fragment-ion targeting (`fragment_ion_type`, `fragment_ion_index`), `proteoform_ctx` cache, and `MS3FragmentMatcher::calibrateAndScore` batch re-scoring (FragmentCount metric only) are MS3-only — they need explicit coverage that the current doc does not provide.

## Non-goals

- **Semantic tuning guide.** The packet documents mechanism. It does not say "use `RemainingPrecursor` for phosphopeptide analysis" — that is user-facing analytical guidance and belongs elsewhere.
- **In-flight work.** Unmerged plans (`move-hcdenergy-to-developer`, `ms3-explore-scan-description`) are out of scope. Their docs updates will land with the plans.
- **Fragment analysis deep-dive.** The packet links into `MS3FragmentMatcher` but does not re-document the fragment analysis subsystem — that warrants its own packet.
- **Code migration.** No moves or refactors to `Exploration.cpp` / `.h`. Documentation only.

## Architecture

### Directory layout

```
docs/
  kb/
    index.md                        ← one-line update (rewrite the MS1 entry's exploration mention, add packet entry)
    exploration/                    ← new packet
      README.md                     ← landing page
      exploration.md                ← shared narrative (lifecycle, state machine, config, entry points, gotchas)
      variants-and-sweeps.md        ← initiate → variants → buildVariants_ → ExplorationVariant struct
      scoring-and-winner.md         ← feedResult → per-metric scoring → winner selection → overrides
      ms2-exploration.md            ← MS2-specific behavior and trigger path
      ms3-exploration.md            ← MS3-specific behavior, two trigger paths, MS3FragmentMatcher
    ms1-acquisition/
      exploration.md                ← DELETED (superseded by the new packet)
      README.md                     ← see_also updated
      precursor-selection.md        ← see_also updated
      targeting-modes.md            ← see_also updated
  superpowers/
    specs/
      2026-04-20-kb-exploration-design.md   ← this file
```

Six new files in a new packet directory; one deletion in `ms1-acquisition/`; `see_also:` entries updated in three existing files; one `index.md` line appended. No code changes.

### Frontmatter

Each new `.md` file uses the standard schema:

```yaml
---
title: <human-readable title>
applies_to: <primary code path this entry documents>
last_verified: 2026-04-20
code_anchors:
  - <path>:<line>   # <short description>
see_also:
  - <relative path to another KB file>
---
```

Same schema as the two existing packets — no new conventions.

## Content specs

### `README.md`

Landing page. Target ≤40 lines. Sections:

1. **Overview** — one paragraph: exploration is an autonomous CE/RT/activation sweep that runs per selected precursor (MS2) or per selected fragment (MS3), scores returning variants with a configurable metric, and picks the winner to drive the production scan. Both levels share the same state machine; level-specific behavior lives in the `ms2-exploration.md` / `ms3-exploration.md` files.
2. **Read order** — `exploration.md` → `variants-and-sweeps.md` → `scoring-and-winner.md` → `ms2-exploration.md` → `ms3-exploration.md`.
3. **Entry points** — code_anchors for the three call sites that reach into exploration: MS1-triggered MS2 exploration (`FLASHIda.cpp:753`), non-exploration MS2 result triggering MS3 (`FLASHIda.cpp:924`), and the exploration-winner-triggers-next-level path (inside `Exploration::feedResult`).
4. **Related packets** — `config-flow/` (how the JSON gets into `MSLevelConfig::exploration`), `ms1-acquisition/precursor-selection.md` (what feeds MS1-triggered exploration).

### `exploration.md`

Shared narrative. Target ≤150 lines. Sections:

1. **Overview** — what exploration does, why it exists: operator does not know the optimal CE ex ante; the engine does a sweep and picks.
2. **Lifecycle** — `initiate` → build variants → enqueue commands → async results → `feedResult` per variant → all received → score → pick winner → hand off (production scan or next-level).
3. **State machine** — `Exploration::active_groups_` (`unordered_map<int, ExplorationGroup>`), `variant_tracking_map_` (tracking_id → `{group_id, variant_index}`), `exploration_active_` atomic flag on `FLASHIda`. How groups are created, marked complete, and cleaned up.
4. **Per-level config surface** — MSLevelConfig fields driving exploration: `exploration` (ExplorationMetric enum: None | MassCount | RemainingPrecursor | FragmentCount), `ce_min` / `ce_max` / `ce_step`, `rt_min` / `rt_max` / `rt_step`, `activations`, `overrides`, `exploration_tolerance_ppm`. Link to `config-flow/` for wiring details.
5. **Entry points** — the two call sites and how the exploration-triggered next-level recurses: `FLASHIda.cpp:753` (MS1 → MS2 exploration), `FLASHIda.cpp:924` (non-exploration MS2 → MS3 via `initiateNextLevel`), `Exploration::feedResult` → `initiateNextLevel` post-winner.
6. **Validation** — `Config::validate()` rejects (a) IDScore + exploration on the same level (mutually exclusive optimization modes), (b) exploration without exactly one scan config per level.
7. **Gotchas** — command load multiplication (N variants per precursor), no per-group timeout (blocks forever if one variant drops), baseline variant adds to command load invisibly, IDScore+exploration mutual exclusion.

### `variants-and-sweeps.md`

Variant generation deep-dive. Target ≤100 lines. Sections:

1. **`Exploration::initiate` walkthrough** — receives precursor/fragment + level + context; constructs `ExplorationGroup`; enumerates variants; returns scan commands.
2. **`buildVariants_` enumeration** — Cartesian product of CE × RT × activation axes with the configured bounds/steps. Invariants: at least one variant produced; variants are stable-ordered (CE inner, RT middle, activation outer — confirmable against source at plan-verification time).
3. **`ExplorationVariant` struct** — field-by-field table mirroring the existing MS1 doc's table. Noting which fields are populated at construction vs. post-result.
4. **Baseline variant** — `RemainingPrecursor` prepends a CE=0 reference scan (`is_baseline=true`, `variant_index=-1`). Baseline is excluded from winner selection.
5. **Activation sweep rules** — when `activations` contains multiple entries (`["HCD","ETD"]`), each activation repeats the CE (and optionally RT) sweep. Reaction-time axis only meaningful for ETD-class activations; validation enforces this.

### `scoring-and-winner.md`

Scoring and winner selection. Target ≤100 lines. Sections:

1. **`feedResult` flow** — triggered when an MS2/MS3 with an exploration tracking ID arrives; deconvolves with the correct precursor context; scores via `computeExplorationScore_`; marks variant received; checks group completion.
2. **`computeExplorationScore_` dispatcher** — switches on `ExplorationMetric` to call metric-specific scorers.
3. **Per-metric scorers**:
   - `computeMassCount_` — count of deconvolved masses in the MS2 (heuristic for spectral richness).
   - `computeRemainingPrecursor_` — `1 - remaining / baseline` precursor signal; requires baseline variant; higher depletion = better.
   - `computeFragmentCount_` — raw fragment-ion count from the deconvolved spectrum. On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (see `ms3-exploration.md`).
4. **Winner selection** — highest score wins. Ties broken by variant_index ascending (confirm at verification time). `group.winner_index` recorded; group marked complete.
5. **`overrides` application** — the `overrides` map on `MSLevelConfig` overlays onto the winner's production-scan `ScanCommand` before enqueue (e.g., fix isolation width post-exploration). Overrides apply only to the winner, not to exploration variants.
6. **Gotchas** — no per-group timeout (re-stated from `exploration.md`); score of `-1.0` sentinel before variant is received; metric-specific preconditions (RemainingPrecursor without baseline = bug).

### `ms2-exploration.md`

MS2-specific behavior. Target ≤60 lines. Sections:

1. **Trigger** — from MS1 precursor selection. After `filterAndRank` picks precursors, each selected precursor flows into `Exploration::initiate(2, ...)` at `FLASHIda.cpp:753-770`, bypassing the direct `queue_.buildMS2` path.
2. **Context plumbing** — `ms_ctx` = MS1 scan ID for parent tracking; no fragment-level context at MS2.
3. **Variant construction** — variants built with `queue_.buildMS2(...)`.
4. **Winner handoff** — production MS2 scan enqueued (with `overrides` applied) and, if MS3 is configured, `initiateNextLevel(3, ...)` is called from the winner's deconvolved result. The MS3 path is shared with the non-exploration flow (see `ms3-exploration.md`).

### `ms3-exploration.md`

MS3-specific behavior. Target ≤120 lines. Sections:

1. **Two trigger paths** — both reach `Exploration::initiateNextLevel`:
   - **Exploration-winner path**: MS2 exploration completes → `feedResult` → `initiateNextLevel(3, ...)` with the winner's deconvolved result.
   - **Non-exploration path**: regular MS2 result completes with MS3 configured → `FLASHIda.cpp:924` calls `initiateNextLevel(3, ...)` directly.
   Both callers pass the same argument shape: (level, deconvolved_MS2, faims_cv, queue, context). Downstream behavior is identical.
2. **Context plumbing** — `ms_ctx` = originating MS2 `ScanCommand` (not a scan ID — two-stage context needed by `buildMS3` for isolation window); `fragment_ion_type` + `fragment_ion_index` identify which fragment from the MS2 is being targeted; `proteoform_ctx` (protein sequence bounds + PTM sites) is cached on the group for batch re-scoring.
3. **Variant construction** — variants built with `queue_.buildMS3(...)`. CE/RT/activation axes are the same as MS2; the MS3 level has its own `MSLevelConfig` entries in `levels_`.
4. **Post-winner: `MS3FragmentMatcher::calibrateAndScore`** — MS3-only, FragmentCount-metric-only. After winner selection, the matcher re-scores all variants in the group using calibrated fragment-ion m/z tolerances derived from the winner. This updates `ExplorationVariant::identification_result` for downstream `identification.tsv` export. Doesn't re-pick the winner; only enriches metadata.
5. **Gotchas** — `proteoform_ctx` lifetime is the group's lifetime; never borrow it across group cleanup. `buildMS3` requires the originating MS2 `ScanCommand`, not the MS2 scan ID; using the ID silently produces a malformed isolation request.

## Index update

Append one line to `docs/kb/index.md` under `## Packets`, below the existing Config-flow entry:

```
- [Exploration](exploration/README.md) — MS2 and MS3 exploration: variants, scoring, winner selection.
```

Also update the MS1-acquisition entry to drop its exploration mention (currently reads `precursor selection, targeting modes, exploration, FAIMS cycling.` → `precursor selection, targeting modes, FAIMS cycling.`).

## Handling the existing `ms1-acquisition/exploration.md`

Option B from brainstorming: delete, not stub.

- **Delete** `docs/kb/ms1-acquisition/exploration.md`.
- **Update `see_also` pointers** in three files:
  - `docs/kb/ms1-acquisition/README.md` — remove the exploration bullet; add a pointer to `../exploration/README.md` under a brief "related packets" note.
  - `docs/kb/ms1-acquisition/precursor-selection.md` — replace `exploration.md` in `see_also` with `../exploration/ms2-exploration.md` (the closest single-file match for cross-reference intent).
  - `docs/kb/ms1-acquisition/targeting-modes.md` — same treatment.
- **Salvage content.** The existing file is well-written but MS2-only. Its sections map cleanly onto the new packet:
  - Overview → `exploration.md` overview
  - Activation → `exploration.md` per-level config surface (deepened)
  - Variant Generation → `variants-and-sweeps.md`
  - Winner Selection → `scoring-and-winner.md`
  - Interaction with Precursor Selection → `ms2-exploration.md` trigger section
  - MS3 Trigger via initiateNextLevel → `ms3-exploration.md` two-trigger-paths section (now expanded to cover the non-exploration path too)
  - Gotchas → distributed to `exploration.md` + `scoring-and-winner.md` per topic

## Anchor plan (summary)

Minimum code_anchors across the packet (each doc picks its subset). Line numbers are targets to verify at plan-task time:

- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` — `exploration_` member, `exploration_active_` atomic flag
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753` — `hasExploration(2)` branch (MS1 → MS2 exploration)
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760` — `Exploration::initiate(2, ...)` call
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:836` — `isExplorationVariant()` check + `feedResult` routing
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:924` — non-exploration MS2 → MS3 `initiateNextLevel` call
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:986` — MS3 exploration routing
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65` — `ExplorationVariant` struct
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:100` — `ExplorationGroup` struct
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178` — `initiate` declaration
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186` — `feedResult` declaration
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:240` — `computeExplorationScore_` declaration
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115` — `Exploration::initiate` definition
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:181` — MS3 context wiring
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400` — `MS3FragmentMatcher::calibrateAndScore` call
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:491` — `initiateNextLevel` definition
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:716` — per-metric scorers (`computeMassCount_` et al.)
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59` — `ExplorationMetric` enum
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:100` — `MSLevelConfig::exploration` field and neighbors
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:494` — `Config::hasExploration`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:422` — `Config::validate` (exploration checks live inside)
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h` — `calibrateAndScore` signature + `ProteoformContext` struct

Exact line numbers are pinned at plan-task verification time (same convention as config-flow).

## Verification

- After content lands, `@docs/kb/index.md` loads automatically; grep the index for the new `exploration` entry and confirm the MS1-acquisition entry no longer mentions exploration.
- Every `code_anchor` in the six new files resolves (one Read per anchor — cheap; budget ~30 reads).
- `docs/kb/ms1-acquisition/exploration.md` is gone; `grep -r "ms1-acquisition/exploration"` returns zero matches under `docs/kb/`.
- `see_also:` frontmatter in `ms1-acquisition/precursor-selection.md`, `ms1-acquisition/targeting-modes.md`, `ms1-acquisition/README.md` points at the new packet.
- No code changes; no build required.

## Spec lifecycle

- `status: draft` on write.
- User approves the spec → flip to `status: approved` in-place.
- All plan tasks complete + merged → flip to `status: implemented`. Stop hook archives the spec at session end.

## Deliverables

- `docs/kb/exploration/README.md`
- `docs/kb/exploration/exploration.md`
- `docs/kb/exploration/variants-and-sweeps.md`
- `docs/kb/exploration/scoring-and-winner.md`
- `docs/kb/exploration/ms2-exploration.md`
- `docs/kb/exploration/ms3-exploration.md`
- `docs/kb/index.md` — one-line addition under `## Packets`, one-word edit to MS1 entry
- `docs/kb/ms1-acquisition/exploration.md` — deleted
- `docs/kb/ms1-acquisition/README.md` — see_also / related update
- `docs/kb/ms1-acquisition/precursor-selection.md` — see_also update
- `docs/kb/ms1-acquisition/targeting-modes.md` — see_also update

## Open questions

None at design time. Any implementation-level decisions (exact wording, precise anchor lines, how deep `calibrateAndScore` coverage goes without re-documenting fragment analysis) are deferred to the implementation plan.

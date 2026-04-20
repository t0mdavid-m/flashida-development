# KB Packet — Exploration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new `docs/kb/exploration/` packet with six markdown files that document MS2 and MS3 exploration (CE/RT/activation sweeps, scoring metrics, winner selection, level-specific trigger paths, MS3 fragment-ion targeting and `MS3FragmentMatcher::calibrateAndScore`). Delete the now-superseded `docs/kb/ms1-acquisition/exploration.md`, update `see_also:` pointers in three existing ms1-acquisition files, and register the new packet in `docs/kb/index.md`.

**Architecture:** All documentation. Six new markdown files in one new packet directory, one deletion, three `see_also:` updates, one index update, one spec status flip. Follows the conventions of the existing `ms1-acquisition/` and `config-flow/` packets: YAML frontmatter with `last_verified` + `code_anchors`, paths relative to the parent-repo root, pointers over paste, ≤200 lines per file, no multi-line pasted code blocks in deep-dive docs.

**Tech Stack:** Markdown + YAML frontmatter. No build/test tooling; verification is anchor resolution via `sed`/`grep`.

**Linked spec:** `docs/superpowers/specs/2026-04-20-kb-exploration-design.md`

---

## File structure

**Create:**
- `docs/kb/exploration/README.md` — packet landing page
- `docs/kb/exploration/exploration.md` — shared lifecycle / state-machine / config narrative
- `docs/kb/exploration/variants-and-sweeps.md` — `Exploration::initiate`, variant generation, `ExplorationVariant` field reference
- `docs/kb/exploration/scoring-and-winner.md` — `feedResult`, per-metric scoring, winner selection, overrides
- `docs/kb/exploration/ms2-exploration.md` — MS2-specific trigger, context, handoff
- `docs/kb/exploration/ms3-exploration.md` — MS3-specific trigger paths (exploration winner + non-exploration MS2), fragment-ion targeting, `MS3FragmentMatcher::calibrateAndScore`

**Modify:**
- `docs/kb/index.md` — append one line under `## Packets` (new entry), drop "exploration" from the MS1-acquisition entry's description
- `docs/kb/ms1-acquisition/README.md` — update the "Read Order" list (drop `exploration.md` line) and the "Related Packets" section to link the new packet
- `docs/kb/ms1-acquisition/precursor-selection.md` — update `see_also:` (replace `exploration.md` with `../exploration/ms2-exploration.md`)
- `docs/kb/ms1-acquisition/targeting-modes.md` — update `see_also:` (replace `exploration.md` with `../exploration/ms2-exploration.md`)
- `docs/superpowers/specs/2026-04-20-kb-exploration-design.md` — flip `status: approved` → `status: implemented` after everything else lands (Stop hook archives at session end)

**Delete:**
- `docs/kb/ms1-acquisition/exploration.md` — content salvaged into the new packet per the spec's salvage map

**Parallelizable:** Tasks 2–6 (five content files) are independent of each other once Task 1 creates the directory. Task 7 (delete + update see_also) and Task 8 (index update) are independent of each other but both depend on Tasks 1–6 existing first (so link targets resolve). Task 9 is the final verification + spec flip and depends on everything.

---

### Task 1: Packet scaffold + `README.md`

**Files:**
- Create: `docs/kb/exploration/` (directory, via mkdir)
- Create: `docs/kb/exploration/README.md`

- [ ] **Step 1: Create the packet directory**

```bash
mkdir -p docs/kb/exploration
```

- [ ] **Step 2: Verify the entry-point anchors resolve**

```bash
sed -n '753p;760p;927p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '115p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
sed -n '229p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
sed -n '504p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
```

Expected output (symbol match, exact whitespace irrelevant):
- `FLASHIda.cpp:753` → `if (config_.hasExploration(2))`
- `FLASHIda.cpp:760` → `auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx);`
- `FLASHIda.cpp:927` → `nlr = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);`
- `Exploration.cpp:115` → `std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,`
- `Exploration.cpp:229` → `Exploration::FeedResultInfo Exploration::feedResult(int tracking_id,`
- `Exploration.cpp:504` → `Exploration::NextLevelResult Exploration::initiateNextLevel(int msn_level,`

If any anchor diverges, `grep -n "Exploration::feedResult(int" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` (and analogous searches) to find the current line number and update the anchor in this step and in the README frontmatter below before writing.

- [ ] **Step 3: Write `docs/kb/exploration/README.md`**

Frontmatter:

```yaml
---
title: Exploration Packet
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753    # MS1 → MS2 exploration branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760    # MS2 exploration.initiate call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927    # non-exploration MS2 → MS3 initiateNextLevel call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115   # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229   # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504   # initiateNextLevel definition
see_also:
  - ../config-flow/README.md
  - ../ms1-acquisition/README.md
---
```

Body sections (≤40 lines total):

1. **Overview** — one paragraph. Frame the subsystem: exploration runs an autonomous CE/RT/activation sweep per selected precursor (MS2) or per selected fragment (MS3); returning variants are scored with a configurable metric and the winner drives the production scan. Both levels share the same state machine (variant enumeration, async result collection, scoring, winner selection). Level-specific behavior — what triggers exploration, what context it carries, what happens post-winner — lives in the per-level files.

2. **Read order** — bullet list, one sentence per file:
   - `exploration.md` — shared lifecycle, state machine, per-level config surface, validation, gotchas.
   - `variants-and-sweeps.md` — how variants are enumerated from CE/RT/activation axes; `ExplorationVariant` field reference.
   - `scoring-and-winner.md` — per-metric scoring (`MassCount` / `RemainingPrecursor` / `FragmentCount`), winner selection, `overrides` application.
   - `ms2-exploration.md` — triggered from MS1 precursor selection; handoff to MS3.
   - `ms3-exploration.md` — two trigger paths; fragment-ion targeting; `MS3FragmentMatcher` batch re-scoring.

3. **Entry points** — bullet list with `file:line`:
   - MS1-triggered MS2 exploration: `FLASHIda.cpp:753` (branch) → `FLASHIda.cpp:760` (`Exploration::initiate(2, ...)` call).
   - Non-exploration MS2 → MS3 exploration: `FLASHIda.cpp:927` (`Exploration::initiateNextLevel(2, ...)` call from the non-exploration result path).
   - Exploration-winner → next level: `Exploration::feedResult` (`Exploration.cpp:229`) calls `initiateNextLevel` (`Exploration.cpp:504`) when the winning variant has MS3 configured.

4. **Related packets** — bullet list:
   - `../config-flow/` — how the JSON keys (`ms_settings.ms2.exploration`, `ce_min`, `activations`, `overrides`, `exploration_tolerance_ppm`) get from `method.json` into `MSLevelConfig`.
   - `../ms1-acquisition/` — precursor selection and targeting are upstream; exploration does not re-rank, it optimizes the fragmentation conditions for precursors that selection already picked.

**Body style:** pointers over paste. No multi-line code blocks.

- [ ] **Step 4: Verify length and frontmatter**

```bash
wc -l docs/kb/exploration/README.md
head -15 docs/kb/exploration/README.md
```

Expected: `wc` reports ≤ 40 lines. `head` shows the frontmatter starting with `---` and closing with `---`.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/exploration/README.md
git commit -m "docs(kb/exploration): add packet README"
```

---

### Task 2: `exploration.md` — shared lifecycle and state machine

**Files:**
- Create: `docs/kb/exploration/exploration.md`

- [ ] **Step 1: Verify every anchor the doc will use**

```bash
sed -n '65p;100p;178p;186p;200p;240p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
sed -n '115p;229p;504p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
sed -n '59p;100p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
sed -n '422p;495p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
sed -n '753p;760p;927p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
```

Expected:
- `Exploration.h:65` → `struct ExplorationVariant`
- `Exploration.h:100` → `struct ExplorationGroup`
- `Exploration.h:178` → `std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,`
- `Exploration.h:186` → `FeedResultInfo feedResult(int tracking_id,`
- `Exploration.h:200` → `NextLevelResult initiateNextLevel(int msn_level, const DeconvolvedSpectrum& result,`
- `Exploration.h:240` → `double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,`
- `Exploration.cpp:115` → `std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,`
- `Exploration.cpp:229` → `Exploration::FeedResultInfo Exploration::feedResult(int tracking_id,`
- `Exploration.cpp:504` → `Exploration::NextLevelResult Exploration::initiateNextLevel(int msn_level,`
- `Config.h:59` → `enum class ExplorationMetric`
- `Config.h:100` → `ExplorationMetric exploration = ExplorationMetric::None;`
- `Config.cpp:422` → `void Config::validate() const` (function definition)
- `Config.cpp:495` → `bool Config::hasExploration(int msn_level) const` (function definition)
- `FLASHIda.cpp:753` → `if (config_.hasExploration(2))`
- `FLASHIda.cpp:760` → `auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx);`
- `FLASHIda.cpp:927` → `nlr = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);`

If any anchor diverges (e.g., a header was reformatted and line numbers shifted), grep for the symbol name (e.g., `grep -n "struct ExplorationGroup" OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h`) and update the anchor in both the verification command above and the frontmatter below.

- [ ] **Step 2: Write `docs/kb/exploration/exploration.md`**

Frontmatter:

```yaml
---
title: Exploration — Lifecycle and State Machine
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65    # ExplorationVariant struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:100   # ExplorationGroup struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178   # initiate decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:200   # initiateNextLevel decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115         # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504         # initiateNextLevel definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59         # ExplorationMetric enum
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:100        # MSLevelConfig::exploration field
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:422              # Config::validate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:495              # Config::hasExploration
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753                     # MS1 → MS2 exploration branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760                     # MS2 initiate call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927                     # non-exploration MS2 → MS3 initiateNextLevel call
see_also:
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
  - ../config-flow/README.md
---
```

Body sections (≤150 lines total). Prose only — no multi-line code pastes. Each section one to three paragraphs.

1. **Overview.** What exploration is and why it exists. Operators don't know ex ante which CE fragments best for a given precursor; exploration runs a sweep and lets the scoring metric pick. Both MS2 and MS3 exploration share the same algorithm and state machine; only the trigger and post-winner handoff differ per level.

2. **Lifecycle.** Narrative pass through one exploration cycle, keyed to file:line:
   - `Exploration::initiate(msn_level, ...)` (`Exploration.cpp:115`) — called once per target (selected precursor for MS2, selected fragment for MS3). Builds an `ExplorationGroup`, enumerates variants along CE × RT × activation axes, returns scan commands to the caller.
   - Caller enqueues the commands. Variants run on the instrument asynchronously.
   - Each returning scan's tracking ID is checked via `Exploration::isExplorationVariant` (declared alongside `feedResult` in `Exploration.h`). If it belongs to an active group, `feedResult` (`Exploration.cpp:229`) deconvolves the result, scores the variant, and records it.
   - When every variant in the group has `received=true`, the group completes. The highest-scoring variant becomes the winner (`group.winner_index`). A production scan is built from the winner and enqueued; `overrides` from the per-level config are applied at this point.
   - If the next level is configured, `Exploration::initiateNextLevel` (`Exploration.cpp:504`) is called with the winner's deconvolved result to start the next-level group (e.g., MS2-winner → MS3 exploration).

3. **State machine.** Data lives in `Exploration::active_groups_` (an `unordered_map<int, ExplorationGroup>` keyed by group ID) and `variant_tracking_map_` (tracking ID → `{group_id, variant_index}`) for constant-time result routing. `FLASHIda` also maintains an atomic `exploration_active_` flag (updated on every `processScan` boundary with `exploration_.activeGroupCount() > 0`) intended for lock-free read by scan-cycle gating; as of today the flag is written but never loaded — a future gating hook, not a currently exercised one. Group lifetime: created in `initiate`, entries added on every variant; marked complete in `feedResult` once all variants received; cleaned up after the winner's production scan (and any next-level initiation) has been enqueued.

4. **Per-level config surface.** Exploration is driven by fields on `MSLevelConfig` (`Config.h:100` — `exploration` field itself plus neighbors): `ExplorationMetric exploration` (`Config.h:59`: `None` / `MassCount` / `RemainingPrecursor` / `FragmentCount`), `ce_min` / `ce_max` / `ce_step`, `rt_min` / `rt_max` / `rt_step`, `activations` (list of activation types to sweep), `overrides` (map applied to the **variant base config** at `initiate` time, and also acts as a gate: a separate post-winner production scan is emitted only when `overrides` is non-empty), `exploration_tolerance_ppm` (separate from the base tolerance used for non-exploration deconvolution). `Config::hasExploration(msn_level)` (`Config.cpp:495`) returns true whenever `levels_[msn_level].exploration != ExplorationMetric::None`. For the JSON-to-struct wiring, see `../config-flow/`.

5. **Entry points.** The two call sites that reach exploration:
   - `FLASHIda.cpp:753` → `FLASHIda.cpp:760` — when `hasExploration(2)` is true, each selected precursor flows into `Exploration::initiate(2, ...)` instead of the direct `queue_.buildMS2` path. See `ms2-exploration.md`.
   - `FLASHIda.cpp:927` — when MS2 exploration is off but MS3 is configured, the non-exploration MS2 result path calls `Exploration::initiateNextLevel(2, ...)` directly. See `ms3-exploration.md`.
   The exploration-winner path — `feedResult` → `initiateNextLevel` — is internal to `Exploration.cpp` and fires automatically when a group completes and the next level is configured.

6. **Validation.** `Config::validate()` (`Config.cpp:422`) enforces cross-cutting rules that single-field defaults cannot: (a) **IDScore vs. exploration** — global `targeting_.use_idscore` and any-level `exploration_enabled_` are mutually exclusive (IDScore decides HCD analytically; exploration decides it empirically); (b) **Conditional MS2** — if `targeting_.conditional_ms2_enabled` is set, `tagging_follow_up_scan.activation` must be configured; (c) **Exactly one scan config per exploration level** — `exploration != None` requires `cfg.scans.size() == 1`; (d) **`FragmentCount` needs a protein sequence** — any level with `ExplorationMetric::FragmentCount` requires a non-empty `targeting_.protein_sequence`; (e) **Selection at MSn ≥ 2 needs a protein sequence** — same reason (fragment matching is the default scoring); (f) **Per-activation sweep ranges** — for each configured activation, HCD/CID/EThcD require `ce_min < ce_max`, ETD/EThcD require `rt_min < rt_max`. Violations throw `std::invalid_argument`, surfacing on stderr before C# sees the `CreateFLASHIda` null return.

7. **Gotchas.**
   - **Command load multiplication.** Each selected target produces N variants. At `max_targets=10`, `ce_step=5`, range 20–40, that's 10 × 5 = 50 MS2 commands per MS1 cycle.
   - **Blocking on all variants.** Winner selection only fires when every variant has `received=true`. A dropped or long-delayed variant leaves the group open indefinitely — there is no per-group timeout in the current implementation.
   - **Baseline adds to load.** `RemainingPrecursor` prepends a CE=0 reference scan (invisible in `ce_min`/`ce_max`/`ce_step`), adding one variant per group.
   - **IDScore + exploration mutual exclusion.** Configuring both on one level rejects at `Config::validate()`.
   - **Per-level tolerance.** `exploration_tolerance_ppm` can differ from the base deconvolution tolerance; exploration variant deconvolutions use this field, not the base.

- [ ] **Step 3: Verify length, frontmatter, and no pasted code blocks**

```bash
wc -l docs/kb/exploration/exploration.md
head -25 docs/kb/exploration/exploration.md
awk '/^```/{if (in_block) {print NR-start+1" lines"; in_block=0} else {in_block=1; start=NR}}' docs/kb/exploration/exploration.md
```

Expected: `wc` reports ≤ 150 lines. Frontmatter opens and closes with `---`. The `awk` command prints nothing (no fenced code blocks) or only short blocks (≤ 5 lines each).

- [ ] **Step 4: Commit**

```bash
git add docs/kb/exploration/exploration.md
git commit -m "docs(kb/exploration): document shared lifecycle and state machine"
```

---

### Task 3: `variants-and-sweeps.md` — variant generation

**Files:**
- Create: `docs/kb/exploration/variants-and-sweeps.md`

- [ ] **Step 1: Verify anchors**

```bash
sed -n '65p;178p;237p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
sed -n '59p;115p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
```

Expected:
- `Exploration.h:65` → `struct ExplorationVariant`
- `Exploration.h:178` → `std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,`
- `Exploration.h:237` → `std::vector<VariantParams> buildVariants_(const MSLevelConfig& cfg, const ScanConfig& base_config) const;`
- `Exploration.cpp:59` → `std::vector<Exploration::VariantParams> Exploration::buildVariants_(`
- `Exploration.cpp:115` → `std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,`

If any anchor diverges, `grep -n "buildVariants_" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` and update the line numbers in this step and in the frontmatter below.

- [ ] **Step 2: Write `docs/kb/exploration/variants-and-sweeps.md`**

Frontmatter:

```yaml
---
title: Exploration — Variants and Sweeps
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65    # ExplorationVariant struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:178   # initiate decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:237   # buildVariants_ decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:59          # buildVariants_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115         # initiate definition
see_also:
  - exploration.md
  - scoring-and-winner.md
  - ms2-exploration.md
  - ms3-exploration.md
---
```

Body sections (≤100 lines total). A short table is allowed for field reference; no multi-line source pastes.

1. **`Exploration::initiate` walkthrough.** Receives level, target (`PeakGroup` for MS2, effectively a fragment descriptor for MS3 via `DeconvolvedSpectrum` context), charge, FAIMS CV, the scan command queue, and a context pointer (`ms_ctx`). Constructs a fresh `ExplorationGroup`, pulls the level's config (`config_.level(msn_level)`), enumerates variants, and appends scan commands via the queue's level-appropriate builder (`buildMS2` for MS2; `buildMS3` for MS3 — see `ms2-exploration.md` / `ms3-exploration.md`). Returns the commands to the caller; the caller enqueues them.

2. **Variant enumeration.** Cartesian product across three axes:
   - **CE axis** — `[ce_min, ce_max]` stepped by `ce_step`. Always has at least one value.
   - **RT (reaction-time) axis** — `[rt_min, rt_max]` stepped by `rt_step`. Only produces > 1 value for activation types that use ion/ion reaction time (ETD, EThcD). For HCD-only sweeps, the axis is a single zero.
   - **Activation axis** — the `activations` config field. If empty, defaults to the level's primary activation. When multiple entries (e.g., `["HCD","ETD"]`), the full CE × RT sweep repeats for each activation.
   - Invariant: at least one variant is produced. The axis order (loop nesting) is stable so that `variant_index` is deterministic across runs — confirmable by reading the loop structure in `Exploration::buildVariants_` (`Exploration.cpp:59`).

3. **`ExplorationVariant` struct (`Exploration.h:65`).** Field reference:

| Field | Populated when | Purpose |
|---|---|---|
| `variant_index` | at construction | 0-based sweep position; `-1` for the baseline |
| `collision_energy` | at construction | CE for this variant (eV) |
| `reaction_time` | at construction | ETD/EThcD reaction time (ms); `0` for HCD-only |
| `activation_type` | at construction | HCD / ETD / EThcD / etc. |
| `tracking_id` | at construction | unique scan ID used by `feedResult` to match results |
| `is_baseline` | at construction | `true` for the CE=0 reference scan (RemainingPrecursor only) |
| `received` | on `feedResult` | `false` until the variant's scan result arrives |
| `result` | on `feedResult` | deconvolved spectrum stored for downstream use |
| `score` | on `feedResult` | assigned by `computeExplorationScore_`; `-1.0` sentinel until received |
| `fragment_count` | on `feedResult` | fragment-ion count from the deconvolved result |
| `identification_result` | post-winner (MS3 only) | per-fragment match metadata from `MS3FragmentMatcher::calibrateAndScore` |

4. **Baseline variant for `RemainingPrecursor`.** When the metric is `RemainingPrecursor`, `initiate` prepends a single CE=0 scan with `is_baseline=true` and `variant_index=-1`. Winner selection ignores baseline variants (they are reference signal, not candidates). Without the baseline, `computeRemainingPrecursor_` has no denominator.

5. **Activation-sweep validation.** `Config::validate()` enforces that RT range fields are meaningful only with ETD-class activations; for pure HCD sweeps, `rt_min == rt_max == 0` is expected. Mixing invalid axis configurations throws — the error message identifies the offending level.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/exploration/variants-and-sweeps.md
head -20 docs/kb/exploration/variants-and-sweeps.md
```

Expected: `wc` reports ≤ 100 lines. Frontmatter present.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/exploration/variants-and-sweeps.md
git commit -m "docs(kb/exploration): document variant generation and sweep axes"
```

---

### Task 4: `scoring-and-winner.md` — scoring and winner selection

**Files:**
- Create: `docs/kb/exploration/scoring-and-winner.md`

- [ ] **Step 1: Verify anchors**

```bash
sed -n '186p;240p;248p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
sed -n '229p;716p;734p;747p;752p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
sed -n '59p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
```

Expected:
- `Exploration.h:186` → `FeedResultInfo feedResult(int tracking_id,`
- `Exploration.h:240` → `double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,`
- `Exploration.h:248` → `double computeMassCount_(const DeconvolvedSpectrum& spec) const;`
- `Exploration.cpp:229` → `Exploration::FeedResultInfo Exploration::feedResult(int tracking_id,`
- `Exploration.cpp:716` → `double Exploration::computeExplorationScore_(ExplorationMetric metric,`
- `Exploration.cpp:734` → `case ExplorationMetric::FragmentCount:` (FragmentCount is inlined — no separate helper)
- `Exploration.cpp:747` → `double Exploration::computeMassCount_(const DeconvolvedSpectrum& spec) const`
- `Exploration.cpp:752` → `double Exploration::computeRemainingPrecursorScore_(const ExplorationGroup& group,`
- `Config.h:59` → `enum class ExplorationMetric`

Note the scorer topology: there is **no** `computeFragmentCount_` or `computeRemainingPrecursor_` helper. The dispatcher at `:716` has three `case` arms; `FragmentCount` inlines `return static_cast<double>(fmr.total_match_count);` at `:738` using the `computeFragmentMatch_` result that is computed uniformly for all three metrics. The only per-metric helpers are `computeMassCount_` (`:747`) and `computeRemainingPrecursorScore_` (`:752`).

If any line diverges, grep for the symbol (`grep -n "Exploration::computeMassCount_\|Exploration::computeRemainingPrecursorScore_" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp`) and update the anchors in this step and in the frontmatter below.

- [ ] **Step 2: Write `docs/kb/exploration/scoring-and-winner.md`**

Frontmatter:

```yaml
---
title: Exploration — Scoring and Winner Selection
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:186   # feedResult decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:240   # computeExplorationScore_ decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:248   # computeMassCount_ decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229         # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:716         # computeExplorationScore_ dispatcher
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:734         # FragmentCount inlined case
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:747         # computeMassCount_ definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:752         # computeRemainingPrecursorScore_ definition
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:59         # ExplorationMetric enum
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - ms3-exploration.md
---
```

Body sections (≤100 lines total):

1. **`feedResult` flow.** Called by the orchestrator whenever a returning MS2/MS3 scan carries an exploration tracking ID (`isExplorationVariant(tracking_id)` is true). Routes via `variant_tracking_map_` to find `{group_id, variant_index}`, deconvolves the raw spectrum with the correct precursor context and the per-level `exploration_tolerance_ppm`, calls `computeExplorationScore_` (`Exploration.h:240`), stores the score on the variant, marks `received=true`, and tests `group.complete`. When complete, runs winner selection (step 4 below). On MS3 with the `FragmentCount` metric, also triggers `MS3FragmentMatcher::calibrateAndScore` (see `ms3-exploration.md`).

2. **`computeExplorationScore_` dispatcher (`Exploration.cpp:716`).** A single `switch` on `ExplorationMetric` (`Config.h:59`) with three cases plus a default fallback. All three cases first call `computeFragmentMatch_` (which populates match metadata used by downstream logging and by MS3's `calibrateAndScore`), then return a metric-specific score. Returns a `double`; higher is better.

3. **Per-metric scoring:**
   - **`MassCount` — `computeMassCount_` (`Exploration.cpp:747`)**: counts deconvolved masses in the variant's spectrum (`spec.size()`). A spectral-richness proxy: more distinct masses = better fragmentation. Cheap; no reference needed.
   - **`RemainingPrecursor` — `computeRemainingPrecursorScore_` (`Exploration.cpp:752`)**: score derived from `1 - (remaining / baseline)` of the precursor's signal intensity. Requires the baseline variant (`is_baseline=true`) to have been received so the denominator exists. Higher depletion = better. Produces `0.0` for empty inputs; the `out_ratio` out-parameter is set to `-1.0` when the ratio can't be computed.
   - **`FragmentCount` — inlined (`Exploration.cpp:734-739`)**: no separate helper function. The dispatcher's case inlines `return static_cast<double>(fmr.total_match_count);` using the `FragmentMatchResult` produced by `computeFragmentMatch_`. On MS3, pairs with `MS3FragmentMatcher::calibrateAndScore` (`Exploration.cpp:400`), which re-scores variants with calibrated per-variant fragment m/z tolerance **after** the initial winner is selected (see `ms3-exploration.md`).

4. **Winner selection.** `feedResult` iterates the group's variants; the one with the highest `score` wins. `group.winner_index` is recorded, the group is marked complete, and the production scan is built from the winner's result. Baseline variants are excluded from winner ranking. Ties are broken by `variant_index` ascending (lowest CE at the front, since the sweep is CE-inner by default).

5. **`overrides` application.** `MSLevelConfig::overrides` is a key-value map that `Exploration::initiate` applies to the variant sweep's **base config** via `base_config.applyOverrides(cfg.overrides)` (`Exploration.cpp:127`) — so every variant inherits the overrides, not just a winner. The map *also* gates whether a separate post-winner production scan is emitted at all: the branch at `Exploration.cpp:460` (`if (!level_config.overrides.empty())`) builds a fresh production `ScanCommand` from `level_config.scans[0]` with the winner's CE/RT/activation copied onto it; otherwise no post-winner production scan is enqueued. Net effect: overrides shape every variant, and their presence doubles as a flag to request an additional explicit production scan on top of the winner's variant scan.

6. **Gotchas.**
   - **Score sentinel `-1.0`.** Un-received variants carry `-1.0`; do not treat this as a legitimate low score. Winner selection only runs after `group.complete`, so this matters only for mid-lifecycle inspection.
   - **Metric preconditions.** `RemainingPrecursor` without a baseline is a configuration bug; `FragmentCount` on MS3 presumes fragment analysis is configured. `Config::validate()` catches obvious misconfigurations; metric-vs.-level mismatches not caught by validation will surface as all-zero scores.
   - **No per-group timeout.** Restated from `exploration.md`: a dropped variant leaves the group pending indefinitely; `feedResult` never fires the winner path.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/exploration/scoring-and-winner.md
head -22 docs/kb/exploration/scoring-and-winner.md
```

Expected: `wc` reports ≤ 100 lines. Frontmatter present.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/exploration/scoring-and-winner.md
git commit -m "docs(kb/exploration): document per-metric scoring and winner selection"
```

---

### Task 5: `ms2-exploration.md` — MS2-specific behavior

**Files:**
- Create: `docs/kb/exploration/ms2-exploration.md`

- [ ] **Step 1: Verify anchors**

```bash
sed -n '753p;760p;836p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '115p;189p;229p;477p;504p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
```

Expected:
- `FLASHIda.cpp:753` → `if (config_.hasExploration(2))`
- `FLASHIda.cpp:760` → `auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx);`
- `FLASHIda.cpp:836` → `if (exploration_.isExplorationVariant(tracking_id))`
- `Exploration.cpp:115` → `std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,`
- `Exploration.cpp:189` → `cmd = queue.buildMS2(pg, charge, variant_config, expl_priority);` (MS2 variant build inside `initiate`)
- `Exploration.cpp:229` → `Exploration::FeedResultInfo Exploration::feedResult(int tracking_id,`
- `Exploration.cpp:477` → `prod_cmd = queue.buildMS2(group.precursor_pg, group.precursor_charge, prod_config, 2);` (MS2 production scan from winner)
- `Exploration.cpp:504` → `Exploration::NextLevelResult Exploration::initiateNextLevel(int msn_level,`

Note: the queue is a reference parameter to `initiate`, so calls are `queue.buildMS2(...)` — not `queue_.buildMS2`. If any line diverges, `grep -n "queue.buildMS2" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` and update.

- [ ] **Step 2: Write `docs/kb/exploration/ms2-exploration.md`**

Frontmatter:

```yaml
---
title: MS2 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753    # hasExploration(2) branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760    # initiate(2, ...) call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:836    # isExplorationVariant routing on MS2 results
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:115   # initiate definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:189   # queue.buildMS2 variant build
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229   # feedResult definition
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:477   # queue.buildMS2 production scan from winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504   # initiateNextLevel definition (MS3 cascade)
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms3-exploration.md
  - ../ms1-acquisition/precursor-selection.md
---
```

Body sections (≤60 lines total):

1. **Trigger.** MS2 exploration is triggered from MS1 precursor selection. After `PrecursorSelection::filterAndRank` picks the precursors for this MS1 cycle, each selected precursor is routed through the branch at `FLASHIda.cpp:753`: if `config_.hasExploration(2)` is true, the engine calls `Exploration::initiate(2, selected[i], sel_charges[i], faims_cv, queue_, &ms1_ctx)` at `FLASHIda.cpp:760` *instead of* taking the direct `queue_.buildMS2` path. The two paths are mutually exclusive per scan cycle.

2. **Context plumbing.** The `ms_ctx` argument is a pointer to `ms1_ctx`, the `ScanCommand` that produced the MS1 scan feeding this selection. It provides parent-scan tracking so returning variants can be correlated with the MS1 that begat them. MS2 exploration carries no fragment-level context — the precursor came from MS1 deconvolution; there is nothing "more specific" to target.

3. **Variant construction.** Inside `Exploration::initiate` (`Exploration.cpp:115`), each variant's scan command is built via `queue.buildMS2(pg, charge, variant_config, expl_priority)` (`Exploration.cpp:189`). Each variant receives a unique tracking ID that is later used to route results back via `feedResult`. After winner selection, the production MS2 scan is built with a separate `queue.buildMS2` call at `:477`.

4. **Result routing.** When an MS2 scan completes and is surfaced to `FLASHIda::processScan`, the check at `FLASHIda.cpp:836` (`if (exploration_.isExplorationVariant(tracking_id))`) diverts it from the normal MS2 result path into `Exploration::feedResult` (`Exploration.cpp:229`). Ordinary (non-exploration) MS2 results continue through the regular handler.

5. **Handoff / MS3 cascade.** Once an MS2 group completes and the winner is selected, `feedResult` calls `Exploration::initiateNextLevel(2, ...)` (`Exploration.cpp:504`) if MS3 is configured on the next level. The MS3 branch is shared with the non-exploration MS2 path — both callers of `initiateNextLevel` converge on the same setup code. See `ms3-exploration.md`.

6. **MS2-specific pitfall.** Exploration does not re-rank or filter precursors. Every precursor that `filterAndRank` selected gets its own group; exploration operates downstream of selection. The selection metric (intensity / mass / charge / tqscore) and the exploration metric are orthogonal — changing the exploration metric does not change which precursors are chosen.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/exploration/ms2-exploration.md
head -18 docs/kb/exploration/ms2-exploration.md
```

Expected: `wc` reports ≤ 60 lines. Frontmatter present.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/exploration/ms2-exploration.md
git commit -m "docs(kb/exploration): document MS2 trigger and handoff"
```

---

### Task 6: `ms3-exploration.md` — MS3-specific behavior

**Files:**
- Create: `docs/kb/exploration/ms3-exploration.md`

- [ ] **Step 1: Verify anchors**

```bash
sed -n '927p;986p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '181p;183p;400p;470p;504p;658p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
sed -n '92p;93p;119p;120p;121p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
sed -n '58p;115p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h
```

Expected:
- `FLASHIda.cpp:927` → `nlr = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);`
- `FLASHIda.cpp:986` → `if (exploration_.isExplorationVariant(tracking_id))` (MS3 result routing branch)
- `Exploration.cpp:181` → `if (msn_level >= 3 && ms_ctx != nullptr)` (MS3 context wiring inside `initiate`)
- `Exploration.cpp:183` → `cmd = queue.buildMS3(*ms_ctx, variant_config,` (MS3 variant build)
- `Exploration.cpp:400` → `auto calibrated_scores = MS3FragmentMatcher::calibrateAndScore(` (batch re-scoring call)
- `Exploration.cpp:470` → `prod_cmd = queue.buildMS3(group.variants[best_idx].cmd, prod_config,` (MS3 production scan from winner)
- `Exploration.cpp:504` → `Exploration::NextLevelResult Exploration::initiateNextLevel(int msn_level,`
- `Exploration.cpp:658` → `cmd = queue.buildMS3(*ms_ctx, next_scan_config, frag_mz, frag_charge, iso_width,` (MS3 variant build inside `initiateNextLevel`)
- `Exploration.h:92`/`:93` → `char fragment_ion_type = '\0';` / `int fragment_ion_index = 0;` (fields on `ExplorationVariant`)
- `Exploration.h:119`/`:120`/`:121` → `char fragment_ion_type` / `int fragment_ion_index` / `MS3FragmentMatcher::ProteoformContext proteoform_ctx` (fields on `ExplorationGroup`)
- `MS3FragmentMatcher.h:58` → `struct ProteoformContext`
- `MS3FragmentMatcher.h:115` → `static std::vector<double> calibrateAndScore(`

Note: the queue is a reference parameter, so calls are `queue.buildMS3(...)` — not `queue_.buildMS3`. If any anchor diverges, grep for the symbol name and update.

- [ ] **Step 2: Write `docs/kb/exploration/ms3-exploration.md`**

Frontmatter:

```yaml
---
title: MS3 Exploration
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:927                     # non-exploration MS2 → MS3 initiateNextLevel call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:986                     # MS3 isExplorationVariant routing
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:181         # MS3 context wiring inside initiate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:183         # queue.buildMS3 variant build
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:400         # MS3FragmentMatcher::calibrateAndScore call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:470         # queue.buildMS3 production scan from winner
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:504         # initiateNextLevel definition (shared with MS2-winner path)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:658         # queue.buildMS3 inside initiateNextLevel
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:119   # ExplorationGroup::fragment_ion_type
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:120   # ExplorationGroup::fragment_ion_index
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:121   # ExplorationGroup::proteoform_ctx
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:58    # ProteoformContext struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h:115   # calibrateAndScore signature
see_also:
  - exploration.md
  - variants-and-sweeps.md
  - scoring-and-winner.md
  - ms2-exploration.md
---
```

Body sections (≤120 lines total):

1. **Two trigger paths.** MS3 exploration is reached via `Exploration::initiateNextLevel` (`Exploration.cpp:504`), which has two callers:
   - **Exploration-winner path.** When an MS2 exploration group completes, `feedResult` calls `initiateNextLevel(2, winner.result, ctx.faims_cv, queue_, ms_ctx)` with the winner's deconvolved spectrum. This path triggers only when MS2 exploration is enabled.
   - **Non-exploration path.** When MS2 exploration is **disabled** but MS3 is configured, the regular (non-exploration) MS2 result handler at `FLASHIda.cpp:927` calls `initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx)` with the stored MS2 result. This path exists so MS3 exploration can be used on its own — it does not require MS2 exploration upstream.
   
   Both paths pass the same argument shape `(msn_level=2, MS2 deconvolved spectrum, FAIMS CV, queue, ScanCommand context)`. Inside `initiateNextLevel`, behavior is identical regardless of origin. The source-level caller is the only difference.

2. **Context plumbing.** `ms_ctx` at MS3 is the originating MS2 `ScanCommand` (not a scan ID — `buildMS3` needs two-stage isolation context). When `msn_level >= 3 && ms_ctx != nullptr` (checked at `Exploration.cpp:181`), the MS3-specific fields on `ExplorationGroup` (`Exploration.h:119-121`) are populated: `fragment_ion_type` and `fragment_ion_index` identify which fragment from the parent MS2 is the target of this MS3 group; `proteoform_ctx` (type `MS3FragmentMatcher::ProteoformContext`, defined at `MS3FragmentMatcher.h:58`) caches the candidate protein sequence bounds and PTM sites so batch re-scoring does not need to re-run identification.

3. **Variant construction.** `Exploration::initiate` builds MS3 variants via `queue.buildMS3(*ms_ctx, variant_config, ...)` (`Exploration.cpp:183`). The CE / RT / activation axes work the same as at MS2 (see `variants-and-sweeps.md`), but the per-level `MSLevelConfig` fields come from `config_.level(3)`. After winner selection, the production MS3 scan is built with a separate `queue.buildMS3` call at `:470`. A third `queue.buildMS3` inside `initiateNextLevel` at `:658` handles the fragment-targeting path when an MS2 winner has its next-level MS3 initiated. MS3 variants share the exploration state machine and scoring path with MS2; the level-specific difference is *what* is being fragmented and *what context* rides along.

4. **Post-winner: `MS3FragmentMatcher::calibrateAndScore`.** MS3-only, `FragmentCount`-metric-only. After winner selection, `feedResult` calls `MS3FragmentMatcher::calibrateAndScore(...)` at `Exploration.cpp:400`. This function takes the group's variants + `proteoform_ctx` + the winner's calibration data, computes calibrated per-variant fragment m/z tolerances, and re-scores each variant's fragment-ion matches against the candidate sequence. The output is written back into each variant's `identification_result` field, which downstream `identification.tsv` export consumes. **This step does not re-pick the winner** — winner selection has already happened. Its purpose is to enrich per-variant match metadata with calibrated scores.

5. **Result routing.** When an MS3 scan completes, `FLASHIda.cpp:986` checks `isExplorationVariant(tracking_id)` to divert exploration variants into `feedResult`. Non-exploration MS3 results (regular `selection_strategy.ms3` path) use the standard MS3 handler.

6. **Gotchas.**
   - **`proteoform_ctx` lifetime.** Cached on the `ExplorationGroup`; valid only while the group is in `active_groups_`. Never borrow it across group cleanup; downstream consumers must snapshot what they need before the group is removed.
   - **`buildMS3` needs the `ScanCommand`, not the scan ID.** Passing the MS2 scan ID where the `ScanCommand` is expected produces a malformed isolation request — the C++ side does not catch this, the instrument returns garbage.
   - **Non-exploration path only fires if MS3 is configured.** At `FLASHIda.cpp:927`, the surrounding branch checks `config_.level(2).selection != SelectionMetric::None` (which effectively means "MS3 is enabled"). MS3 configuration is per-level and independent of MS2 exploration configuration.
   - **`FragmentCount` + `calibrateAndScore` coupling.** Only the `FragmentCount` metric triggers the batch re-score; other metrics skip it. If the selected metric for MS3 is `MassCount` or `RemainingPrecursor`, `identification_result` is not populated.

- [ ] **Step 3: Verify length, frontmatter, no pasted code blocks**

```bash
wc -l docs/kb/exploration/ms3-exploration.md
head -22 docs/kb/exploration/ms3-exploration.md
awk '/^```/{if (in_block) {print NR-start+1" lines"; in_block=0} else {in_block=1; start=NR}}' docs/kb/exploration/ms3-exploration.md
```

Expected: `wc` reports ≤ 120 lines. Frontmatter present. The `awk` command prints nothing or only short blocks (≤ 5 lines).

- [ ] **Step 4: Commit**

```bash
git add docs/kb/exploration/ms3-exploration.md
git commit -m "docs(kb/exploration): document MS3 trigger paths and fragment matching"
```

---

### Task 7: Remove old `ms1-acquisition/exploration.md`, update `see_also:` pointers and the MS1 README

**Files:**
- Delete: `docs/kb/ms1-acquisition/exploration.md`
- Modify: `docs/kb/ms1-acquisition/README.md`
- Modify: `docs/kb/ms1-acquisition/precursor-selection.md`
- Modify: `docs/kb/ms1-acquisition/targeting-modes.md`

- [ ] **Step 1: Confirm the new packet exists**

```bash
ls docs/kb/exploration/README.md docs/kb/exploration/exploration.md docs/kb/exploration/variants-and-sweeps.md docs/kb/exploration/scoring-and-winner.md docs/kb/exploration/ms2-exploration.md docs/kb/exploration/ms3-exploration.md
```

Expected: all six files listed without error. If any is missing, return to the corresponding task before proceeding.

- [ ] **Step 2: Delete the old file**

```bash
git rm docs/kb/ms1-acquisition/exploration.md
```

- [ ] **Step 3: Update `docs/kb/ms1-acquisition/README.md`**

Use the `Edit` tool. Replace:

```markdown
- `targeting-modes.md` — the four `TargetingConfig::mode` values and how each
  constrains which precursors are eligible.
- `exploration.md` — CE-sweep variants and the metric used to pick the
  exploration winner after multiple injections.
- `faims-cycling.md` — per-MS1 FAIMS CV cycling state machine and how child
  MS2 scans inherit the CV value.
```

with:

```markdown
- `targeting-modes.md` — the four `TargetingConfig::mode` values and how each
  constrains which precursors are eligible.
- `faims-cycling.md` — per-MS1 FAIMS CV cycling state machine and how child
  MS2 scans inherit the CV value.

Exploration (MS2 and MS3) now has its own packet — see
`../exploration/README.md`.
```

Also replace:

```markdown
## Related Packets

None yet; see [index](../index.md).
```

with:

```markdown
## Related Packets

- [`../exploration/`](../exploration/README.md) — MS2 and MS3 exploration: variants, scoring, winner selection. Selection and targeting here are upstream of MS2 exploration.
- [`../config-flow/`](../config-flow/README.md) — how `method.json` becomes the `Config` structs that this packet's code reads.
```

- [ ] **Step 4: Update `docs/kb/ms1-acquisition/precursor-selection.md` frontmatter**

Use the `Edit` tool. Replace:

```yaml
see_also:
  - targeting-modes.md
  - exploration.md
```

with:

```yaml
see_also:
  - targeting-modes.md
  - ../exploration/ms2-exploration.md
```

- [ ] **Step 5: Update `docs/kb/ms1-acquisition/targeting-modes.md` frontmatter**

Use the `Edit` tool. Replace:

```yaml
see_also:
  - precursor-selection.md
  - exploration.md
```

with:

```yaml
see_also:
  - precursor-selection.md
  - ../exploration/ms2-exploration.md
```

- [ ] **Step 6: Verify no dangling references to `ms1-acquisition/exploration.md` or bare `exploration.md` remain**

```bash
grep -rn "ms1-acquisition/exploration\|- exploration\.md" docs/kb/ms1-acquisition/
```

Expected: no output. If `ms1-acquisition/exploration.md` still appears anywhere under `docs/kb/ms1-acquisition/`, find and update it.

- [ ] **Step 7: Commit**

```bash
git add docs/kb/ms1-acquisition/README.md docs/kb/ms1-acquisition/precursor-selection.md docs/kb/ms1-acquisition/targeting-modes.md
git commit -m "docs(kb/ms1-acquisition): redirect see_also pointers to new exploration packet"
```

---

### Task 8: Register the new packet in `docs/kb/index.md`, drop "exploration" from MS1 entry

**Files:**
- Modify: `docs/kb/index.md`

- [ ] **Step 1: Read current index**

```bash
cat docs/kb/index.md
```

Expected content includes:

```markdown
## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
```

- [ ] **Step 2: Edit the MS1-acquisition entry and append the new packet**

Use the `Edit` tool. Replace:

```markdown
- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
```

with:

```markdown
- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
- [Exploration](exploration/README.md) — MS2 and MS3 exploration: variants, scoring, winner selection.
```

- [ ] **Step 3: Verify length and content**

```bash
wc -l docs/kb/index.md
grep -c "exploration/README.md" docs/kb/index.md
grep "ms1-acquisition/README.md" docs/kb/index.md
```

Expected: `wc` ≤ 80 lines. `grep -c "exploration/README.md"` returns `1` (exactly one entry for the new packet). The MS1 line should read `precursor selection, targeting modes, FAIMS cycling.` — no `exploration`.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): register exploration packet; drop exploration from MS1 summary"
```

---

### Task 9: Final verification + spec status flip

**Files:**
- Modify: `docs/superpowers/specs/2026-04-20-kb-exploration-design.md` (flip `status: approved` → `status: implemented`)

- [ ] **Step 1: Verify every new-packet file exists and has frontmatter**

```bash
ls docs/kb/exploration/
for f in docs/kb/exploration/*.md; do
  echo "=== $f ==="
  head -1 "$f"
done
```

Expected: six files (`README.md`, `exploration.md`, `variants-and-sweeps.md`, `scoring-and-winner.md`, `ms2-exploration.md`, `ms3-exploration.md`); each starts with `---`.

- [ ] **Step 2: Verify index points to the new packet and MS1 summary no longer lists exploration**

```bash
grep "exploration/README.md" docs/kb/index.md
grep "ms1-acquisition/README.md" docs/kb/index.md
```

Expected: one line for `exploration/README.md`; the MS1 line says `precursor selection, targeting modes, FAIMS cycling.` (no `exploration`).

- [ ] **Step 3: Verify the old file is gone and no stale links remain**

```bash
ls docs/kb/ms1-acquisition/exploration.md 2>&1 || echo "confirmed deleted"
grep -rn "ms1-acquisition/exploration\|- exploration\.md" docs/kb/
```

Expected: `ls` prints "No such file or directory" (or our "confirmed deleted" fallback). The `grep` prints no matches anywhere under `docs/kb/`.

- [ ] **Step 4: Resolve every `code_anchor` declared in the new files**

For each code_anchor entry in any file under `docs/kb/exploration/`, verify that `sed -n '<line>p' <path>` prints non-empty output. Commented-out anchors (lines starting with `#`) are exempt — but if a commented-out placeholder was left behind from Task 3 / Task 4 / Task 6 because Step 1 of that task could not resolve the line, it indicates an unfixed gap. Flag it here.

```bash
for f in docs/kb/exploration/*.md; do
  echo "=== $f ==="
  awk '
    /^code_anchors:/{flag=1; next}
    /^see_also:|^---/{flag=0}
    flag && /^  - / {
      line = $0
      sub(/^  - /, "", line)
      sub(/ *#.*$/, "", line)
      print line
    }
  ' "$f"
done
```

For each anchor printed:
- If it contains `:<line>`, run `sed -n '<line>p' <path>` and confirm non-empty output.
- If it is a bare `<path>` (no line), run `ls <path>` and confirm the file exists.
- If any entry starts with `#` (commented placeholder), search the source file with `grep -n <symbol>` to resolve it and edit the frontmatter before proceeding.

None should produce empty output or "No such file".

- [ ] **Step 5: Verify no multi-line pasted code blocks in the deep-dive docs**

```bash
for f in docs/kb/exploration/exploration.md docs/kb/exploration/variants-and-sweeps.md docs/kb/exploration/scoring-and-winner.md docs/kb/exploration/ms2-exploration.md docs/kb/exploration/ms3-exploration.md; do
  echo "=== $f ==="
  awk '/^```/{if (in_block) {print NR": close ("NR-start+1" lines)"; in_block=0} else {in_block=1; start=NR}} END{if(in_block) print "unclosed block"}' "$f"
done
```

Expected: each fenced block closes within ≤ 5 lines (or the output is empty). A block > 5 lines violates the "pointers over paste" rule established in the MS1 packet. If found, replace the block with a one-line `file:line` reference.

- [ ] **Step 6: Flip the spec's status to implemented**

Use the `Edit` tool on `docs/superpowers/specs/2026-04-20-kb-exploration-design.md`. The frontmatter has `status: approved` and the "Spec lifecycle" section has the literal string `status: approved` as a descriptive bullet. Only flip the frontmatter instance (line 3). To disambiguate, anchor the edit on the surrounding frontmatter lines:

Replace:

```
title: KB Packet — MS2 / MS3 Exploration
status: approved
created: 2026-04-20
```

with:

```
title: KB Packet — MS2 / MS3 Exploration
status: implemented
created: 2026-04-20
```

- [ ] **Step 7: Commit the status flip**

```bash
git add docs/superpowers/specs/2026-04-20-kb-exploration-design.md
git commit -m "docs(specs): mark kb-exploration design as implemented"
```

- [ ] **Step 8: Confirm the phase-11 branch log shows all expected commits**

```bash
git log --oneline phase-11 ^main | head -20
```

Expected: the new commits appear in reverse order — spec-implemented flip, index update, ms1-acquisition redirect, six deep-dive-doc commits, README commit, then the spec-approval and spec-add commits from the brainstorming phase.

The Stop hook will archive the now-`implemented` spec into `docs/superpowers/specs/archive/` at session end; no action needed here.

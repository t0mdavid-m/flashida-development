---
title: Agent-facing Knowledge Base for MS1 Acquisition (Pilot)
status: implemented
created: 2026-04-19
---

# Agent-facing Knowledge Base for MS1 Acquisition (Pilot)

## Purpose

Stand up a reusable, agent-facing knowledge base (KB) at `docs/kb/` in the parent repo. The first packet — `ms1-acquisition/` — documents the MS1 decision loop (precursor selection, targeting, exploration, FAIMS). The design is explicitly a pilot: subsequent packets (MS2, MS3, bridge API, deconvolution, config) follow the same conventions and grow the KB horizontally without reshuffling.

KB content is complementary to code, not a paraphrase of it. It answers *where to look* and *why*; the code answers *what*.

## Goals

- **Discoverability.** An agent starting any task in this repo sees the KB index without having to know it exists.
- **Freshness.** Every claim is dated and anchored to a `file:line`; stale entries announce themselves.
- **Low ambient token cost.** Only the index is auto-loaded; deep-dives are pulled on demand.
- **Clean growth.** New subsystems become new packets without disturbing existing content.

## Non-goals

- Auto-generated prose from source code. KB is curated, not extracted.
- Exhaustive API reference. The code is the API reference.
- Cross-submodule imports. Submodules keep their own `CLAUDE.md` hierarchies; the KB references submodule paths as text anchors only.

## Architecture

### Directory layout

```
docs/
  kb/
    index.md                          ← auto-loaded via @import
    ms1-acquisition/
      README.md                       ← packet landing page
      precursor-selection.md
      targeting-modes.md
      exploration.md
      faims-cycling.md
  superpowers/
    specs/
      2026-04-19-kb-ms1-acquisition-design.md   ← this file
      archive/                                  ← cleanup target (created on first move)
```

### CLAUDE.md integration

Add a single line to the parent-repo `CLAUDE.md`:

```
@docs/kb/index.md
```

This loads `index.md` into every agent session. No other `CLAUDE.md` changes are made; submodule `CLAUDE.md` files are untouched.

### Submodule policy

KB files reference paths inside submodules as text (e.g. `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700`) but never `@import` submodule content. Rationale: submodule pointers in the parent can drift; an `@import` into a moved or renamed submodule file would fail silently or load stale content.

## File conventions

### Frontmatter

Every `.md` file under `docs/kb/` *except* `index.md` opens with:

```yaml
---
title: <human-readable title>
applies_to: <primary code path this entry documents>
last_verified: YYYY-MM-DD
code_anchors:
  - <path>:<line>   # <short description>
  - <path>:<line>   # <short description>
see_also:
  - <relative path to another KB file>
---
```

Fields:

- `title` — used in indexes and cross-references.
- `applies_to` — the single primary file or directory this entry documents.
- `last_verified` — ISO date of the last time an agent checked that claims still match code. Required.
- `code_anchors` — `file:line` pointers that (a) let agents jump into the code cheaply and (b) serve as staleness detectors. If an anchor fails to resolve, the entry is stale.
- `see_also` — intra-KB cross-links. Optional.

### Body style

- **WHY/WHERE over WHAT.** The code expresses *what*. KB explains motivation, invariants, gotchas, and points at the code.
- **Pointers over paste.** `filterAndRank()` at `PrecursorSelection.cpp:177-242` — not an 80-line excerpt.
- **≤250 lines per file.** Split the packet if a topic would push past that.
- **No generated-from-code prose.** If the code already says it, the KB doesn't say it again.
- **Paths relative to parent-repo root.** All `file:line` references use paths from the parent repo (`OpenMS/src/...`, not `src/openms/source/...`). Anchors remain valid from any working directory.

## Freshness contract

- `last_verified` is required on every entry.
- When an agent modifies code a KB entry covers, it reads the entry first and decides: still accurate → bump `last_verified` to today. Drifted → update the prose, then bump `last_verified`.
- Before relying on any specific claim, an agent verifies the named `code_anchors` resolve. If any anchor doesn't resolve, the entry is stale and must be updated or flagged before acting.
- No automated verifier. The `code_anchors` make one-read verification cheap; the contract is trust-but-verify.

## Index

`docs/kb/index.md` is the only always-loaded KB file. Under 80 lines. Pure hooks — no deep content. Pattern mirrors the existing `MEMORY.md`.

Template:

```markdown
# KB Index

Agent-facing knowledge base for FLASHIda. Each packet is a self-contained
subsystem guide — read the packet README first, drill down as needed.

## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.

## Conventions

- Frontmatter `last_verified` dates claims to a point in time; verify
  `code_anchors` before acting on a KB claim.
- If `code_anchors` don't resolve, the entry is stale — update or remove
  it before relying on it.
- File paths are relative to the parent-repo root.
```

## Packet README

Each packet's `README.md` is the landing page. Under 100 lines. Sections:

1. **Overview** — one paragraph framing the subsystem.
2. **Read order** — 3-5 KB files in recommended sequence.
3. **Entry points** — top-level code pointers (function + `file:line`).
4. **Related packets** — cross-links to other KB areas.

## Pilot content — `ms1-acquisition/`

Five files seed the packet.

### `README.md`

Overview of the MS1 decision loop: deconvolution → filter/rank → commands enqueued. Entry points `FLASHIda::processScan` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700`) and `PrecursorSelection::filterAndRank` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177`). Read order: precursor-selection → targeting-modes → exploration → faims-cycling.

### `precursor-selection.md`

Ranking pipeline in `filterAndRank()`: quality metrics (QScore / IDScore / Intensity), filters (`min_charge`, SNR, `qscore_threshold`, same-m/z avoidance), phase logic (targets → non-targets → all), output into `selected_peak_groups_`, `trigger_charges_`, `trigger_hcds_`, `trigger_scores_`. How `consider_all_charges` and `use_idscore` change the ranking basis.

### `targeting-modes.md`

The four values of `TargetingConfig::mode`:

- **None (0)** — selection disabled; `processScan` short-circuits.
- **Inclusion (1)** — TSV/log target list; priority tie-break when QScores are within `tie_threshold`; SNR filter waived for targets.
- **Exclusion (2)** — mass exclusion list; two-pass iteration (with/without exclusions); skip masses whose cumulative `tqscore` exceeds `tqscore_threshold`.
- **Deep (3)** — Exclusion variant with RT-windowed dynamic lists loaded per active RT.

Covers: `qscore_threshold`, `snr_threshold`, `tie_threshold`, `rt_window`, `inclusion_list_file`, `tag_based_enabled`, `fasta_file`, `use_idscore`, `consider_all_charges`, `hcd_energy`.

### `exploration.md`

When `ms2.exploration` is not `None`: `exploration_.initiate()` replaces the standard MS2 command build. Generates CE-sweep variants per precursor; after variants return, winner is chosen by `ExplorationMetric` (MassCount, RemainingPrecursor, FragmentCount). Can trigger MS3 via `initiateNextLevel()` from the winning variant.

### `faims-cycling.md`

Per-MS1 FAIMS CV state machine: `faims_.updateSkip(current_cv, pushed)` adapts CV skip based on precursor count; `faims_.advanceToNextCV()` moves to the next CV (forward-only, wraps). Child MS2 commands inherit the parent MS1's `faims_cv`. Interaction with selection: each MS1 carries exactly one CV; selection is per-CV, not across CVs.

All five files use the full frontmatter schema and the ≤250 line cap. Pilot budget: ~1000-1500 lines total.

## Growth plan

Adding a new packet later (bridge API, deconvolution, config, MS2/MS3):

1. Create `docs/kb/<name>/README.md` plus deep-dive files, all with standard frontmatter.
2. Add one hook line to `docs/kb/index.md` under `## Packets`.
3. Done — the `@docs/kb/index.md` import picks up the change next session.

Never reshuffle existing packets to accommodate a new one.

## Spec lifecycle & automatic cleanup

### Status field

Every spec under `docs/superpowers/specs/` carries in its frontmatter:

```yaml
status: draft            # draft | approved | implemented | superseded
created: YYYY-MM-DD
```

Transitions (agent-owned):

- `draft` → `approved` when the user approves the spec.
- `approved` → `implemented` once the corresponding plan's tasks are complete and merged.
- any → `superseded` when a newer spec replaces it. The newer spec adds `supersedes: <path>` in its own frontmatter.

### Archive via Stop hook

`.claude/settings.json` registers a Stop hook that:

1. Scans `docs/superpowers/specs/*.md` (top level only — ignores `archive/`).
2. For each file whose frontmatter `status:` is `implemented` or `superseded`, moves it into `docs/superpowers/specs/archive/`.
3. Creates `archive/` if it doesn't exist.
4. Never deletes.

### Why

- Active directory stays small; globs and greps are cheap.
- Archive preserves history and rationale.
- Agents don't think about cleanup — changing `status:` is enough; the hook handles the move at session end.

## Verification

This design is infrastructural; verification is manual.

- After setup, confirm `@docs/kb/index.md` loads in a fresh agent session.
- Create a scratch spec with `status: implemented`, end the session, confirm it lands in `archive/`.
- Verify every `code_anchor` in the pilot content resolves (one Read per anchor).

## Open questions

None at design time. Implementation-level decisions (exact Stop hook script, frontmatter parser choice) are deferred to the implementation plan.

## Deliverables

- `docs/kb/index.md`
- `docs/kb/ms1-acquisition/README.md`
- `docs/kb/ms1-acquisition/precursor-selection.md`
- `docs/kb/ms1-acquisition/targeting-modes.md`
- `docs/kb/ms1-acquisition/exploration.md`
- `docs/kb/ms1-acquisition/faims-cycling.md`
- `.claude/settings.json` — Stop hook entry
- Parent `CLAUDE.md` — `@docs/kb/index.md` line

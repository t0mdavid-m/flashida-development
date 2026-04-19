# Agent-facing Knowledge Base for MS1 Acquisition (Pilot) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a `docs/kb/` knowledge base at the parent-repo level, seed the `ms1-acquisition/` packet with 5 deep-dive files, auto-load the index via a single `@import` in parent `CLAUDE.md`, and register a Stop hook that archives specs whose frontmatter `status:` is `implemented` or `superseded`.

**Architecture:** Parent-repo-only KB using a packet-per-subsystem layout. Every KB file carries frontmatter with `last_verified` + `code_anchors` for trust-but-verify freshness. The index (always-loaded) is pure hooks; packets are self-contained. Spec cleanup is a shell script invoked by Claude Code's Stop hook — reads YAML frontmatter, moves archived specs into a sibling `archive/` directory.

**Tech Stack:** Markdown + YAML frontmatter, Bash (Stop hook script), Claude Code `@<path>` import syntax and hooks configuration.

**Linked spec:** `docs/superpowers/specs/2026-04-19-kb-ms1-acquisition-design.md`

---

## File structure

**Create:**
- `docs/kb/index.md` — always-loaded KB index
- `docs/kb/ms1-acquisition/README.md` — packet landing page
- `docs/kb/ms1-acquisition/precursor-selection.md`
- `docs/kb/ms1-acquisition/targeting-modes.md`
- `docs/kb/ms1-acquisition/exploration.md`
- `docs/kb/ms1-acquisition/faims-cycling.md`
- `.claude/hooks/archive-implemented-specs.sh` — Stop hook script
- `docs/superpowers/specs/archive/.gitkeep` — ensures archive dir is tracked before first move

**Modify:**
- `CLAUDE.md` (parent repo) — append `@docs/kb/index.md`
- `.claude/settings.json` — add Stop hook entry

---

### Task 1: Skeleton — KB directories + index.md

**Files:**
- Create: `docs/kb/index.md`
- Create: `docs/kb/ms1-acquisition/` (via mkdir)

- [ ] **Step 1: Create the directory tree**

```bash
mkdir -p docs/kb/ms1-acquisition
```

- [ ] **Step 2: Write `docs/kb/index.md`**

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

- [ ] **Step 3: Verify length**

```bash
wc -l docs/kb/index.md
```
Expected: ≤ 80 lines. (Current draft: ~18.)

- [ ] **Step 4: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): scaffold knowledge base with empty index"
```

---

### Task 2: ms1-acquisition packet README

**Files:**
- Create: `docs/kb/ms1-acquisition/README.md`

- [ ] **Step 1: Verify the entry-point anchors resolve**

```bash
sed -n '700p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '177p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
```
Expected: both lines print (non-empty output). If either fails, update the line numbers to the current location of `FLASHIda::processScan` and `PrecursorSelection::filterAndRank` before proceeding.

- [ ] **Step 2: Write `docs/kb/ms1-acquisition/README.md`**

Frontmatter:
```yaml
---
title: MS1 Acquisition Packet
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700   # FLASHIda::processScan entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177  # filterAndRank entry
see_also: []
---
```

Body sections (≤100 lines total):

1. **Overview** — one paragraph: MS1 scans arrive → `processScan` orchestrates deconvolution and selection → `filterAndRank` produces ranked precursors → commands enqueued as `ScanCommand`s. State that everything runs through `UnifiedScanProcessor` post-Phase-6.
2. **Read order** — bullet list: `precursor-selection.md` → `targeting-modes.md` → `exploration.md` → `faims-cycling.md`. One sentence per file explaining what it covers.
3. **Entry points** — bullet list of function + `file:line`:
   - `FLASHIda::processScan` — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700`
   - `PrecursorSelection::filterAndRank` — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177`
4. **Related packets** — "None yet; see index."

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/ms1-acquisition/README.md
head -8 docs/kb/ms1-acquisition/README.md
```
Expected: ≤ 100 lines; frontmatter includes `title`, `applies_to`, `last_verified`, `code_anchors`, `see_also`.

- [ ] **Step 4: Update index to link the packet**

The line is already in `docs/kb/index.md` from Task 1 — verify it points at `ms1-acquisition/README.md`. No change needed.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/ms1-acquisition/README.md
git commit -m "docs(kb/ms1-acquisition): add packet README"
```

---

### Task 3: `precursor-selection.md`

**Files:**
- Create: `docs/kb/ms1-acquisition/precursor-selection.md`

- [ ] **Step 1: Read the primary code region**

```bash
sed -n '177,300p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
```
Use the output to ground the prose. Note any line numbers used as `code_anchors`.

- [ ] **Step 2: Write `docs/kb/ms1-acquisition/precursor-selection.md`**

Frontmatter:
```yaml
---
title: MS1 Precursor Selection
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177   # filterAndRank entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:238   # deconvolve call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:244   # ranking branch
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:381   # phase filter
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:432   # min_charge filter
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:572   # SNR filter
see_also:
  - targeting-modes.md
  - exploration.md
---
```

Body sections (≤250 lines total):

1. **Pipeline overview** — one paragraph: deconvolve → mass-filter → rank → apply filters across three phases → select top-N. Call out `selected_peak_groups_`, `trigger_charges_`, `trigger_hcds_`, `trigger_scores_` as outputs.
2. **Ranking basis** — explain the three branches:
   - `use_idscore=true` → `getBestIDScore()` (possibly per-charge or per-HCD variant)
   - default (`use_idscore=false`, per-charge) → `sortByQscore()`
   - `consider_all_charges=true` → best QScore across all charges
   - fallback / explicit `Intensity` → `sortByIntensity()`
   Include the `code_anchors:244` region as the pointer.
3. **Phase logic** — explain the three passes (`Phase 0` targets + tqscore-filtered, `Phase 1` non-targets when non-strict, `Phase 2` everything). Non-obvious: phases run only when targets are active.
4. **Filters applied per candidate** — bullet list with `file:line` for each:
   - `min_charge` — `PrecursorSelection.cpp:432`
   - Target match by monoisotopic mass ±`tolerance_ppm`
   - SNR (`getChargeSNR(charge) < snr_threshold`) — `:572`; **waived** for targets
   - `qscore_threshold` — `:569`
   - Same-m/z avoidance — `:574-581`; exceptions when final phase or mass differs
5. **Output fields** — list the populated members. For each, one-sentence WHY (e.g. `trigger_hcds_` records the HCD the selection branch chose, so downstream MS2 gets the right CE).
6. **Gotchas**:
   - Per-charge ranking is the default, not "best charge"; forgetting this leads to surprising rankings.
   - SNR filter is skipped for explicit targets — a low-SNR target will still fire.
   - `selected_peak_groups_` order is the rank order; downstream consumers can rely on it.

- [ ] **Step 3: Verify all `code_anchors` resolve**

For each anchor in frontmatter:
```bash
sed -n '<LINE>p' <PATH>
```
Expected: non-empty output for every anchor. If any anchor doesn't resolve, update before continuing.

- [ ] **Step 4: Verify length**

```bash
wc -l docs/kb/ms1-acquisition/precursor-selection.md
```
Expected: ≤ 250 lines.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/ms1-acquisition/precursor-selection.md
git commit -m "docs(kb/ms1-acquisition): document precursor selection pipeline"
```

---

### Task 4: `targeting-modes.md`

**Files:**
- Create: `docs/kb/ms1-acquisition/targeting-modes.md`

- [ ] **Step 1: Read the config struct and mode-switch regions**

```bash
sed -n '143,168p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
sed -n '187,230p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
sed -n '320,340p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
```
Confirm `TargetingConfig::mode` enum members and the branches that consume them.

- [ ] **Step 2: Write `docs/kb/ms1-acquisition/targeting-modes.md`**

Frontmatter:
```yaml
---
title: Targeting Modes
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:143   # TargetingConfig::mode
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:187   # target list load
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:224   # Deep RT-window load
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:320   # tqscore loop
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:458   # Exclusion skip rule
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:277   # priority tie-break
see_also:
  - precursor-selection.md
---
```

Body sections (≤250 lines):

1. **Overview** — one paragraph: `TargetingConfig::mode` selects one of four behaviors; every mode goes through the same `filterAndRank` but diverges in which candidates it filters in/out.
2. **Mode 0 — None** — `processScan` short-circuits; no selection happens. Used when the instrument is in a non-selection mode.
3. **Mode 1 — Inclusion** — TSV or log-file target list; ranking includes priority tie-break (within `tie_threshold` QScore delta, higher `priority` wins); SNR filter is **waived** for targets. Entry points for list loading at `:187-220`.
4. **Mode 2 — Exclusion** — two-pass iteration (line 378): pass 0 applies exclusions, pass 1 runs without them. Per nominal mass, compute cumulative `tqscore` across RT window (`:320-337`); skip if `1 - tqscore > tqscore_threshold` (`:458`).
5. **Mode 3 — Deep** — Exclusion variant with dynamic, RT-windowed lists loaded per-scan (`:224-231`).
6. **Configurable knobs** — single table:
   | Key | Effect |
   |-----|--------|
   | `qscore_threshold` | global QScore cutoff |
   | `snr_threshold` | per-charge SNR cutoff (waived for targets) |
   | `tie_threshold` | QScore delta for priority tie-break |
   | `rt_window` | seconds; applies to Mode 2/3 RT-keyed lists |
   | `inclusion_list_file` | TSV path (Mode 1) |
   | `tag_based_enabled` | turn on protein-family tag expansion |
   | `fasta_file` | FASTA for tag-based targeting |
   | `use_idscore` | switch ranking from QScore to IDScore |
   | `consider_all_charges` | rank across all charges, not just representative |
   | `hcd_energy` | fixed HCD for all targets (-1 = auto per peak group) |
7. **Gotchas**:
   - SNR is waived for targets — don't assume low-SNR targets are dropped.
   - Mode 2 runs its outer loop twice; fix-and-look-again interactions can surprise.
   - Deep mode's RT-keyed map decays outside `rt_window`.

- [ ] **Step 3: Verify all `code_anchors` resolve**

For each anchor in frontmatter, run:
```bash
sed -n '<LINE>p' <PATH>
```
Expected: non-empty output for every anchor. If any anchor doesn't resolve, update the line number or the referenced file before continuing.

- [ ] **Step 4: Verify length**

```bash
wc -l docs/kb/ms1-acquisition/targeting-modes.md
```
Expected: ≤ 250 lines.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/ms1-acquisition/targeting-modes.md
git commit -m "docs(kb/ms1-acquisition): document the four targeting modes"
```

---

### Task 5: `exploration.md`

**Files:**
- Create: `docs/kb/ms1-acquisition/exploration.md`

- [ ] **Step 1: Read the exploration region**

```bash
sed -n '753,770p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '65,80p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h
```
Confirm `ExplorationVariant` struct layout and `exploration_.initiate()` entry.

- [ ] **Step 2: Write `docs/kb/ms1-acquisition/exploration.md`**

Frontmatter:
```yaml
---
title: MS2 Exploration Engine
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:753   # exploration branch in processScan
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:760   # exploration_.initiate call
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:65   # ExplorationVariant
see_also:
  - precursor-selection.md
  - faims-cycling.md
---
```

Body (≤250 lines):

1. **Overview** — when `ms2.exploration` is not `None`, the exploration engine replaces the direct MS2 command build. Per selected precursor, it issues CE-sweep variants; after variants come back, it picks a winner by an `ExplorationMetric`.
2. **Activation** — config: `ms2.exploration = MassCount | RemainingPrecursor | FragmentCount`. The branch at `FLASHIda.cpp:753` checks this and calls `exploration_.initiate(2, selected[i], ...)` at `:760`.
3. **Variant generation** — for each precursor, the engine enqueues N MS2 commands spanning a CE range. `ExplorationVariant` fields (from `Exploration.h:65-80`) carry the originating precursor, the chosen CE, and slots for returned metrics.
4. **Winner selection** — once all variants report back (fragment counts, remaining-precursor intensity, identified mass count), the metric chooses the best variant. The winner can initiate an MS3 via `initiateNextLevel()`.
5. **Interaction with selection** — exploration does not change which precursors are selected; it changes what happens to them after selection.
6. **Gotchas**:
   - Variant count multiplies the MS2 command load — `max_targets × variants_per_precursor`.
   - Winner is chosen only after *all* variants return; a missing variant blocks scoring.
   - MS3 trigger is a next-level decision, not part of MS1 selection.

- [ ] **Step 3: Verify all `code_anchors` resolve**

For each anchor in frontmatter, run:
```bash
sed -n '<LINE>p' <PATH>
```
Expected: non-empty output for every anchor. If any anchor doesn't resolve, update the line number or the referenced file before continuing.

- [ ] **Step 4: Verify length**

```bash
wc -l docs/kb/ms1-acquisition/exploration.md
```
Expected: ≤ 250 lines.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/ms1-acquisition/exploration.md
git commit -m "docs(kb/ms1-acquisition): document exploration engine"
```

---

### Task 6: `faims-cycling.md`

**Files:**
- Create: `docs/kb/ms1-acquisition/faims-cycling.md`

- [ ] **Step 1: Read the FAIMS cycling region**

```bash
sed -n '807,823p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
```
Confirm the `updateSkip` / `advanceToNextCV` call sequence.

- [ ] **Step 2: Write `docs/kb/ms1-acquisition/faims-cycling.md`**

Frontmatter:
```yaml
---
title: FAIMS CV Cycling
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FAIMS.cpp
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:810   # faims_.updateSkip call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:812   # faims_.advanceToNextCV call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:814   # next MS1 command carries new CV
see_also:
  - precursor-selection.md
---
```

Body (≤250 lines):

1. **Overview** — FAIMS CV cycling runs once per MS1 in C++ (post-Phase-6 — `FAIMSScanProcessor.cs` is deleted). Each MS1 carries exactly one CV; cycling means the next MS1 is scheduled with the next CV in the list.
2. **State machine** — at end of each MS1:
   - `faims_.updateSkip(current_cv, commands_pushed)` — `FLASHIda.cpp:810` — adapts CV skip based on how many precursors the current CV produced. Fewer precursors → skip more often.
   - `faims_.advanceToNextCV()` — `:812` — forward-only, wraps at list end.
   - New MS1 command is built with `ms1.faims_cv = next_cv` — `:814`.
3. **Child inheritance** — MS2 commands built from the current MS1's selection carry the parent MS1's `faims_cv`. This keeps the CV coherent through the scan chain.
4. **Interaction with selection** — selection runs *per CV*: `filterAndRank` sees only the current MS1's peak groups. There is no cross-CV ranking.
5. **Gotchas**:
   - `updateSkip` is adaptive — a CV that produces few precursors will eventually be skipped more often. Debugging a missing CV means checking skip state, not ring position.
   - Struct field `faims_cv` sits at byte offset 1240 in `ScanCommand` (post-Phase-6; struct size 1248). Serialization changes here need P/Invoke-lockstep updates — see the existing cross-project CLAUDE.md guidance.
   - Post-Phase-6, all cycling is in C++; no C# state.

- [ ] **Step 3: Verify all `code_anchors` resolve**

For each anchor in frontmatter, run:
```bash
sed -n '<LINE>p' <PATH>
```
Expected: non-empty output for every anchor. If any anchor doesn't resolve, update the line number or the referenced file before continuing.

- [ ] **Step 4: Verify length**

```bash
wc -l docs/kb/ms1-acquisition/faims-cycling.md
```
Expected: ≤ 250 lines.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/ms1-acquisition/faims-cycling.md
git commit -m "docs(kb/ms1-acquisition): document FAIMS CV cycling"
```

---

### Task 7: Wire the KB into parent CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (parent repo root)

- [ ] **Step 1: Read the current CLAUDE.md**

```bash
cat CLAUDE.md
```
Note the structure; the `@import` line should go near the top, directly after the H1 heading and the one-line description, before `## Repository Structure`.

- [ ] **Step 2: Insert the import line**

Add this line after the existing opening paragraph:

```
@docs/kb/index.md
```

Final top-of-file should look like:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@docs/kb/index.md

## Repository Structure
...
```

- [ ] **Step 3: Verify**

```bash
grep -n '^@docs/kb/index.md' CLAUDE.md
```
Expected: one match.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: auto-load KB index via CLAUDE.md @import"
```

---

### Task 8: Archive-specs Stop hook — write and test the script

**Files:**
- Create: `.claude/hooks/archive-implemented-specs.sh`
- Create: `docs/superpowers/specs/archive/.gitkeep`

This task uses TDD: write a failing scratch-spec test first, then the script, then confirm it passes.

- [ ] **Step 1: Create the archive directory placeholder**

```bash
mkdir -p docs/superpowers/specs/archive
touch docs/superpowers/specs/archive/.gitkeep
```

- [ ] **Step 2: Write a failing test — scratch spec + manual check**

Create a temporary test spec:
```bash
cat > docs/superpowers/specs/_scratch-implemented.md <<'EOF'
---
title: Scratch Implemented Spec
status: implemented
created: 2026-04-19
---

# Scratch
EOF
```

Before writing the script, try running it (it doesn't exist yet):
```bash
bash .claude/hooks/archive-implemented-specs.sh
```
Expected: `bash: .claude/hooks/archive-implemented-specs.sh: No such file or directory`.

- [ ] **Step 3: Create the hooks directory and script**

```bash
mkdir -p .claude/hooks
```

Write `.claude/hooks/archive-implemented-specs.sh`:

```bash
#!/usr/bin/env bash
# Archive specs whose frontmatter status is "implemented" or "superseded".
# Invoked as a Stop hook — exit 0 even if nothing to do.

set -euo pipefail

SPEC_DIR="docs/superpowers/specs"
ARCHIVE_DIR="${SPEC_DIR}/archive"

# Nothing to do if the spec dir doesn't exist (e.g. fresh clone).
[ -d "${SPEC_DIR}" ] || exit 0

mkdir -p "${ARCHIVE_DIR}"

shopt -s nullglob
for spec in "${SPEC_DIR}"/*.md; do
  # Extract the frontmatter (between first two '---' lines) and look for status:.
  status=$(awk '
    BEGIN { in_fm = 0; count = 0 }
    /^---[[:space:]]*$/ {
      count++
      if (count == 1) { in_fm = 1; next }
      if (count == 2) { in_fm = 0; exit }
    }
    in_fm && /^status:/ {
      sub(/^status:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")    # strip inline comment
      sub(/[[:space:]]+$/, "")       # trim trailing whitespace
      print
      exit
    }
  ' "${spec}")

  case "${status}" in
    implemented|superseded)
      mv "${spec}" "${ARCHIVE_DIR}/"
      echo "archived: $(basename "${spec}") (status=${status})" >&2
      ;;
  esac
done

exit 0
```

Make it executable:
```bash
chmod +x .claude/hooks/archive-implemented-specs.sh
```

- [ ] **Step 4: Run the script — verify the scratch spec moves**

```bash
bash .claude/hooks/archive-implemented-specs.sh
ls docs/superpowers/specs/_scratch-implemented.md 2>&1
ls docs/superpowers/specs/archive/_scratch-implemented.md 2>&1
```
Expected:
- First `ls`: `ls: cannot access ...` (file moved).
- Second `ls`: prints the path (file present in archive).
- Script stderr: `archived: _scratch-implemented.md (status=implemented)`.

- [ ] **Step 5: Verify the approved spec is left alone**

```bash
ls docs/superpowers/specs/2026-04-19-kb-ms1-acquisition-design.md
```
Expected: the approved spec (this plan's own spec) is still in place, not in `archive/`. Its status is `approved`, not `implemented`.

- [ ] **Step 6: Clean up the scratch spec**

```bash
rm docs/superpowers/specs/archive/_scratch-implemented.md
```

- [ ] **Step 7: Commit the script**

```bash
git add .claude/hooks/archive-implemented-specs.sh docs/superpowers/specs/archive/.gitkeep
git commit -m "feat(hooks): add archive-implemented-specs Stop hook script"
```

---

### Task 9: Register the Stop hook in .claude/settings.json

**Files:**
- Modify: `.claude/settings.json` (may not exist; create if missing)

- [ ] **Step 1: Confirm settings.json does not exist, then create it**

```bash
ls .claude/settings.json 2>&1
```
Expected at plan-authoring time: `No such file or directory`. If the file exists, STOP and reconcile — read its contents, merge a `Stop` hook entry into the existing `hooks` object without dropping other hooks, and skip the unconditional-create step below.

Otherwise, create `.claude/settings.json` with exactly this content:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/archive-implemented-specs.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -c "import json; json.load(open('.claude/settings.json'))"
```
Expected: no output, exit 0. Any JSON error → fix before proceeding.

- [ ] **Step 3: End-to-end test via a fresh scratch spec**

```bash
cat > docs/superpowers/specs/_scratch-end-to-end.md <<'EOF'
---
title: End-to-end Test Spec
status: implemented
created: 2026-04-19
---

# Scratch
EOF
```

Then end the current Claude Code session (or wait for the next Stop event). When the Stop hook fires, the file should move to `archive/`.

If running the hook manually (skipping the Stop-event wait):
```bash
bash .claude/hooks/archive-implemented-specs.sh
ls docs/superpowers/specs/archive/_scratch-end-to-end.md
```
Expected: file is in `archive/`.

Clean up:
```bash
rm docs/superpowers/specs/archive/_scratch-end-to-end.md
```

- [ ] **Step 4: Commit**

```bash
git add .claude/settings.json
git commit -m "feat(hooks): register archive-implemented-specs as a Stop hook"
```

---

### Task 10: Final verification

- [ ] **Step 1: Verify all pilot files exist and have valid frontmatter**

```bash
for f in docs/kb/index.md \
         docs/kb/ms1-acquisition/README.md \
         docs/kb/ms1-acquisition/precursor-selection.md \
         docs/kb/ms1-acquisition/targeting-modes.md \
         docs/kb/ms1-acquisition/exploration.md \
         docs/kb/ms1-acquisition/faims-cycling.md; do
  echo "=== $f ==="
  head -12 "$f"
  echo "lines: $(wc -l < "$f")"
done
```
Expected: every packet file (excluding `index.md`) has frontmatter with `title`, `applies_to`, `last_verified`, `code_anchors`, `see_also`; every file is under its line cap.

- [ ] **Step 2: Verify every `code_anchor` resolves across all pilot files**

```bash
grep -rhE '^\s*- OpenMS/' docs/kb/ms1-acquisition/ | \
  sed -E 's/^\s*-\s*//; s/\s*#.*$//' | \
  while IFS=: read -r path line; do
    out=$(sed -n "${line}p" "$path" 2>/dev/null || true)
    if [ -z "$out" ]; then
      echo "STALE: $path:$line"
    fi
  done
```
Expected: no `STALE:` lines printed. If any appear, update the anchor or the line number before merging.

- [ ] **Step 3: Verify CLAUDE.md has the import line**

```bash
grep -n '^@docs/kb/index.md' CLAUDE.md
```
Expected: one match.

- [ ] **Step 4: Flip this spec's status to `implemented`**

Edit `docs/superpowers/specs/2026-04-19-kb-ms1-acquisition-design.md`:
```yaml
status: implemented
```

- [ ] **Step 5: Commit the status flip**

```bash
git add docs/superpowers/specs/2026-04-19-kb-ms1-acquisition-design.md
git commit -m "docs(specs): mark kb-ms1-acquisition design as implemented"
```

The Stop hook will archive this spec at the end of the next session.

---

## Notes for the implementer

- **Branch:** The user is currently on `phase-11`. Check with them whether this work belongs on that branch or a dedicated `kb-pilot` / `docs/kb-ms1` branch before starting Task 1.
- **Commit style:** No `Co-Authored-By: Claude` lines (per user preference).
- **No DLL rebuild:** Nothing in this plan touches C++ sources. No OpenMS submodule updates; no DLL rebuild cycle.
- **CLAUDE.md `@import` syntax:** This is a Claude Code feature. If the `@docs/kb/index.md` line doesn't load in a fresh session (verify manually in Task 10), fall back to an explicit instruction line in CLAUDE.md pointing at the index and document the discrepancy.

# 0013. `characterization.mode` is the single MS3 switch

Status: Accepted (2026-08-08)

Supersedes the "there is no enable flag" decision in
[0004-characterization-config-reshape.md](0004-characterization-config-reshape.md).

## Context

ADR-0004 decided that the characterization model "engages whenever an MS2 selection strategy is
configured — there is no enable flag", and listed avoiding one as a virtue. In practice the
opposite happened: MS3 ended up gated by **three** keys in **two** sections, none of them named
`enable`, plus a fourth that decided the objective by being absent.

Reading a committed `method.json` and answering *"does this run MS3, and against what?"* required
knowing five things, three of which are only discoverable in C++ source:

1. `selection_strategy.ms3.selection != "none"` short-circuits MS3 (`Exploration.cpp:730`)
2. `selection_strategy.ms2.selection != "none"` is a **second** gate (`FLASHIda.cpp:366`,
   `Exploration.cpp:728`)
3. `ms_settings.ms3` must be non-empty
4. `characterization.objective` absent silently means `ambiguity` — a word appearing nowhere in the
   file (`Config.cpp:285`, parsed as `if (== "coverage") … else Ambiguity`)
5. the budget beside the on-switch, `selection_strategy.ms3.max_targets`, is **dead**; the engine
   spends `selection_strategy.ms2.max_targets`

The failure directions were also inconsistent, which made typos worse than useless: an unknown
`selection` value fell through to `Intensity` and **enabled** MS3, while an unknown
`exploration.metric` fell through to `None` and silently collapsed a sweep.

Measured on the committed corpus: 18 of 32 configs carried a full MS3 scan block and a placeholder
protein sequence while running no MS3 at all, and four stated a budget of 200 while executing 3.

## Decision

One key. `characterization.mode`, with values `off | ambiguity | coverage`, is the **only** thing
that turns MS3 on, and its on-values **are** the objectives — so `objective` is deleted rather than
kept alongside.

- **Unknown values are hard-rejected.** With `mode` carrying the on/off bit, a typo'd `"Off"` under
  the old lenient parse would have silently *enabled* MS3. The same strictness is applied to the
  other three enums that guessed (`rank_by`, `targeting`, `exploration.metric`).
- **Every level's selection state is derived from `mode`** by a post-parse projection
  (`Config::applyCharacterizationMode_`), not authored per level. MS3 requires *both* level 2 and
  level 3 non-`None`; driving both from one enum makes incoherent states — MS3 on with MS2 off —
  unrepresentable rather than merely discouraged.
- **`MSLevelConfig::selection` defaults to `None`**, not `Intensity`. `ms_settings.msN` materialises
  a level before any selection is parsed, so the old default meant that merely *defining* a scan
  config switched that level on.
- **`mode != off` requires `ms_settings.ms3`.** `Exploration::initiateNextLevel` reads
  `next_cfg.scans[0]` unguarded, so a reachable MS3 with no level-3 scan config is an OOB read, not
  a no-op. `mode: off` does *not* forbid the block, so toggling MS3 off stays a one-word edit.
- **The `protein_sequence` requirement is re-keyed onto `mode`.** It previously fired off the
  upstream gate, which is why those 18 no-MS3 configs had to carry a placeholder.

## Why / Consequences

The trade ADR-0004 made was that reusing existing knobs avoids a new config surface. That held for
the *knobs*; it did not hold for the *gate*, because "engagement is implicit" turned into
"engagement is implied by three unrelated keys". One explicit key is a smaller surface than three
implicit ones, and it is the only shape in which the question has a one-line answer.

**Capability removed, deliberately:** `terminal_fragments` and `ambiguity_resolution` were legal
`selection` values selecting alternative MS2 matchers. A three-valued `mode` cannot express them and
they are now unreachable from config. Zero committed configs used either, and the matcher functions
remain in the engine — but this is a removal, not a no-op, and reversing it means adding a key.

**Level 1 is the hazard this creates.** Because the default is now `None`, a projection that fails to
assign level 1 leaves it `None`, and `FLASHIda.cpp:168` short-circuits before MS1 selection: the
instrument acquires *nothing*, silently, with no wrong value in any log to notice. The hazard is
documented at the declaration and pinned by
`Config_SchemaProjection_test::projection_covers_all_three_levels`.

Related: [0014-two-decision-sections-and-named-scan-configs.md](0014-two-decision-sections-and-named-scan-configs.md).

# 0027. Identification is gated by the sequence, not by the MS3 switch

Status: Accepted (2026-08-25). Narrows
[ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) (`characterization.mode` is the
single MS3 switch) — `mode` remains that switch, but it no longer also gates identification.
Related: [ADR-0012](0012-faims-enablement-is-explicit.md) (the `-1`/`0` sentinel precedent),
[ADR-0014](0014-two-decision-sections-and-named-scan-configs.md) (the matcher chooser this removes
the last consequence of).

## Context

`characterization.mode` is documented as the single MS3 switch. It was doing more than that.

`Exploration::initiateNextLevel` owns **two** jobs: it matches fragments against the configured
protein, and it selects and builds MS3 targets. Identification sits above dispatch in the function
body, but the entry gate — which bailed when the level-2 selection was `None`, i.e. when
`characterization.mode` was `off` — sat above **both**. So turning MS3 off also turned off sequence
tagging, fragment matching, proteoform identification, and every `identification.tsv` row.

The cost was measurable rather than theoretical. Of 22 log-golden modes, **nine had header-only
`identification.tsv` and `pooled_identification.tsv` goldens** — zero data rows. Among them was
`tag`, the only one of 38 configs that loads a FASTA and the single mode named for tagging. It
reported nothing about tags.

A second-order effect made this hard to see. `ProteoformTracker::selectNextLevelTargets` chooses its
matcher by switching on the **next** level's metric and returns `0` from its `default:` arm. Config
projects `mode` onto that metric, so under `mode: off` it is `None` and the switch matches nothing.
Relaxing the entry gate alone therefore changes nothing observable — the two defects had to be found
together or neither would appear fixed.

Seventeen `mode: off` configs also carried a placeholder `protein_sequence` of `"SEQUENCE"`, eight
residues. `Config::validate`'s own comment records these as fossils of a validation rule already
removed, noting that "nothing downstream ever read the sequence". Under a sequence-keyed gate they
would have become load-bearing overnight.

## Decision

**Identification is gated by `characterization.protein_sequence`. Dispatch is gated by
`characterization.mode`.**

1. `initiateNextLevel`'s entry gate bails only on an empty sequence. With no sequence there is
   nothing to match against, so that is the honest gate.
2. The matcher is named explicitly when the next level's metric is `None`.
   `getTopFragmentMatches` is the only matcher reachable from `method.json` since ADR-0014 deleted
   the chooser, and it is what every MS3-enabled config already resolves to, so this is inert
   wherever the metric is set.
3. The four dispatch conditions are **re-asserted immediately above the `next_cfg.scans[0] read**,
   not at the door. Everything above that line is measurement; everything below it acquires.
4. The 17 placeholder sequences are blanked to `""`.

This makes `mode: off` **with** a real sequence a supported configuration meaning *identify, but
acquire no MS3* — a capability that did not previously exist and had no representation in any config.

### Why the gate sits where it does

`Config::validate` requires an `ms_settings.ms3` block only when `mode != off`, and its own comment
calls the reverse case *"the direction that segfaults"*, because `initiateNextLevel` indexes
`next_cfg.scans[0]` unguarded. That validation covered the read only for as long as `mode: off`
could never reach the function — precisely what this change alters. Placing the gate one line lower,
below that read, reintroduces an out-of-bounds access on a `mode: off` config with no MS3 block. The
guard has to travel with the read rather than stay at the entrance.

### Sentinels

The five new log columns adopt one vocabulary on both streams:

| value | meaning |
|---|---|
| `-1` | no count reported for this row — every MS1 row, every MS3 row |
| `0` | the tagger ran and read nothing; for a real protein, a real negative result |
| `>0` | real count |

Collapsing the first two into a plain `0` recreates exactly the ambiguity ADR-0012 had to add a
whole column (`faims_enabled`) to undo, once `faims_cv = 0.0` turned out to mean both "no FAIMS" and
"FAIMS at 0 V".

The MS3 `-1` is a **policy, not an absence of tagging**. MS3 exploration variants *are* tagged; a tag
count taken on an MS3 spectrum would measure the sub-fragment ladder rather than the precursor's
identifiability, which is not what the column means.

## Consequences

- **`mode` keeps its ADR-0013 meaning.** This narrows what it gates; it adds no knob. The
  on/off/objective semantics are untouched.
- **The engine change is byte-identical on every golden.** After blanking, the nine `mode: off`
  modes return at the new gate and the thirteen others already identified. Nothing observes it
  except a dedicated test and the new `identify_only` golden mode — which is why both exist.
- **An MS2 cascade under `mode: off` now runs a discarded tagger pass.** When an MS2 exploration
  group completes, `initiateNextLevel` matches fragments before discovering it has no commands to
  build, and the caller reads only `.commands` and `.ms3_contexts`. Redundant rather than wrong —
  every variant was already identified per-variant — and deliberately not fixed by duplicating the
  dispatch condition at the call site, because two copies of one decision drift apart. ADR-0021
  documents what that costs.
- **`characterization.max_targets` now caps a value it did not previously reach.** On the
  identification-only path it still bounds `found`, and therefore `tic_coverage`, while
  `fragment_count` is uncapped by construction.
- **`MS2Context::tag_count` is deleted.** With MS3 rows reporting `-1`, carrying a parent's count is
  exactly what the sentinel exists to prevent.

## Alternatives considered

- **Add a separate `identify` flag.** Rejected: `protein_sequence` already answers "is there
  anything to identify against", and the repo's standing preference is to reuse an existing knob
  rather than add one. A second switch would also make "sequence set, identify off" representable
  and meaningless.
- **Log the FASTA-gated targeting count instead.** Rejected: it reports `0` both when no tags
  existed and when tags existed but matched no protein, so it is a detection gate that happens to be
  integral, not a measurement. It is also live in exactly one of 38 configs.
- **Keep identification gated and accept the blind spot.** Rejected: it makes the mode named for
  tagging report nothing about tags, and leaves nine golden modes unable to observe a path the
  engine runs.

# 0039. The quantification objective decides what a verdict buys

Status: Accepted (2026-09-02)
Amends: [ADR-0038](0038-quantification-screens-and-identification-is-what-it-buys.md) — specifically
its clause "a differential verdict buys the identification scan". Everything else in 0038 stands:
the role inversion, the `'Q'`/`'R'` markers, the bare `ms_settings.ms2_quant` slot, the four
`scan_results.tsv` columns, the two-condition rule and the wholly-absent verdict. This ADR changes
**which verdicts buy**, not what is measured or how.
Related: [ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) — the source of the
"required when the feature is on, permitted though inert when it is off, so toggling stays a
one-word edit" rule this ADR applies twice.

## Context

ADR-0038 left quantification with every measurement parameter authored and the **decision**
hardcoded. `FLASHIda.cpp`:

```cpp
if (q.verdict == Quantification::Result::Verdict::Differential)
{
  auto ident = queue_.buildFollowUp(parent_ctx, config_.quantification().identification_scan, 'R');
  ...
}
```

That single comparison was the only consumer of the verdict, and it made three reasonable
experiments unauthorable:

- **"Identify everything I could quantify."** A `NotDifferential` species is a *successful*
  measurement — the engine knows its ratio and knows it did not move — and it buys nothing. Its
  MS2 slot is spent on the screen and the species is never sequenced, so the run cannot say what
  the unchanged proteins *were*.
- **"Quantify only."** There is no way to run a labelled survey that never identifies, which is
  what a lab wants when identification comes from a library or a separate DDA run. Every
  differential hit costs a second MS2 whether or not anyone will read it.
- **"Only the ones enriched in treated."** The ratio test is symmetric —
  `fc > t || 1/fc > t` — so a one-sided experiment pays for both sides.

The verdict enum was already four-way and already had the shape of a quality ladder. Nothing was
missing except a way to say where to cut it.

There is also a **latent defect** in the same block. `Config.cpp` assigns
`quant_.identification_scan = primary_ms2` only `if (has_primary_ms2)`, and nothing rejects a quant
config with no `ms_settings.ms2` — the pre-existing guard
(`level(1).selection != None && level(2).scans.empty()`) reads the **roster**, which in a quant
config is non-empty because the `'Q'` scan holds it. So today such a config loads and the bought
scan is built from a **default-constructed `ScanConfig`**. It has never fired because it needs a
`Differential` verdict to reach it.

## Decision

**`quantification.identify` names a cut point on the verdict quality ladder, and
`quantification.enriched_in` names the condition a differential species must be enriched in.**

```jsonc
"quantification": {
  "enabled": true,
  "labelling": "tmt6plex",
  "identify": "differential",      // differential | quantified | all | none
  "enriched_in": "either",         // either | <one of the two condition names>
  "fold_change_threshold": 1.4,
  "conditions": [
    { "name": "control", "channels": ["126", "127", "128"] },
    { "name": "treated", "channels": ["129", "130", "131"] }
  ]
}
```

| `identify` | buys `ms_settings.ms2` for |
|---|---|
| `differential` **(default)** | `Differential`, subject to `enriched_in` — ADR-0038's behaviour exactly |
| `quantified` | `Differential` \| `NotDifferential` — anything cleanly measured |
| `all` | every screened precursor, verdict irrelevant |
| `none` | nothing; the run measures and never identifies |

`IncompleteChannels` and `ExtractionFailed` are **not** separate cut points. Both mean "no usable
quant number" and differ only in why, which `quant_verdict` already reports for diagnosis; a knob
whose two settings differ only on misconfigured runs is not worth the surface.

**Direction is named by CONDITION, never as up/down.** `fold_change = mean(conditions[0]) /
mean(conditions[1])`, so on `method_quant.json` as written — control first — `"up"` would mean
*enriched in control*, the opposite of what anyone authoring it intends, and would invert silently
the moment someone reordered the array. `enriched_in: "treated"` cannot be read backwards, survives
a reorder, and resolves to an ordinal at load, so an unknown name is a load error listing the two
valid names rather than a silently inverted experiment. `"either"` is an explicit value rather than
an omission, which is why a condition may not be **named** `"either"`.

**`enriched_in` must be evaluated on `condition_means`, never on `fold_change`.** A wholly-absent
condition is `Differential` with `fold_change == -1.0` — a **sentinel, not a ratio** (ADR-0038:
"a species present in one condition and absent in the other is the strongest result the experiment
can produce"). Any `fold_change`-based direction test reads `-1`, finds it below any threshold, and
silently drops exactly those species. Since the direction test is reached only when the verdict is
already `Differential`, comparing the two means with a plain `>` is both sufficient and correct.

**An inert `enriched_in` is a `[CONFIG-WARN]`, not a throw.** It restricts only `differential`;
under the other three objectives it does nothing. Rejecting that combination would force a second
edit every time `identify` is flipped and would invalidate a lab template that sets the direction
once and switches objectives between runs. This is `ms_settings.ms3`-under-`mode: off`, which
ADR-0013 explicitly permits — **not** `only_one_condition`, which ADR-0038 deleted because it was
unreachable in *every possible* config. `enriched_in` is live under `differential`.

**`ms_settings.ms2` is required whenever `quantification.enabled`,** closing the latent defect
above — and required-but-inert under `identify: "none"` rather than optional, so all four objective
values stay interchangeable and flipping one can never invalidate a config. The guard sits inside
the existing `if (quant_.enabled)` block alongside its three ADR-0038 siblings, which is also what
keeps `config_schema_reference.json` (quantification off) unaffected by it.

**Unknown `identify` values throw.** Same reasoning as `characterization.mode`: a typo'd
`"Differential"` or a reached-for `"off"` must not silently select a different acquisition policy.

## Why

**The mechanism already existed; only the predicate was fixed.** ADR-0038 established that a
quantification scan screens and buys. This ADR does not add a scan, a marker, a column or a state —
it replaces one hardcoded comparison with an authored one, and the default reproduces the
comparison exactly. That is why the whole change moves no golden.

**Quantification-driven characterization comes free.** Tagging and MS3 targeting are suppressed on
a `'Q'` scan and ride the bought `'R'` (ADR-0038), so `identify` transitively decides which species
are *characterized* as well as which are identified — with no MS3 code touched. A run can now
say "MS3 only what moved" in one word, which previously required no mechanism at all because it
was the only behaviour available.

**A cut point rather than a set of verdicts.** The four verdicts are ordered by how much is known
about the species, so a single enum naming where to cut is both smaller and unable to express
nonsense (`differential` + `extraction_failed` but not `not_differential`). It also reads as one
sentence, which is the property ADR-0013 valued in `characterization.mode`.

**`identify` rather than `objective` or `mode`.** `objective` is the key ADR-0013 *deleted* from
`characterization`, so re-using the token would make a grep for it return a migration error and a
live key. `mode` would be a false parallel: `characterization.mode` is both the gate and the
objective, whereas here `enabled` is the gate, so a reader would reasonably write `mode: "off"` and
get "quantify but never identify" instead of "stop quantifying". `identify` states what the key
controls, and every value reads as a true sentence.

## Consequences

### The change is byte-identical, and that is the acceptance test

Defaults reproduce ADR-0038 exactly, and the separation of concerns is what guarantees it:
`quant_verdict` reports the **measurement**, `identify` decides the **purchase**. No log column is
added, renamed or revalued, so no log golden, continuity JSON or regression TSV moves. The
bought/not-bought decision is already observable through `commands_pushed` and `child_ids` on the
`'Q'` row, so it needs no column of its own. **A moved golden cell means a default changed
behaviour** — it is a defect, not a recapture.

`FlashIDA/test-data/config_schema_reference.json` is the only committed data file that changes, by
two keys. It carries both at **non-default** values (`"quantified"`, `"reference_b"`), which proves
the emitter carries the authored value rather than merely round-tripping a default. The two can be
non-default simultaneously only because their mutual constraint is a warning gated on `enabled`,
which the reference sets to `false`.

### No committed config migrates

All 41 carry a `quantification` block; none authors either key, and both have defaults. The new
`ms_settings.ms2` requirement is satisfied by every config that enables quantification — which is
`method_quant.json` alone, and it has always had one.

### Two fixtures, because one direction of absence is not enough

The wholly-absent trap needs a spectrum whose condition channels are empty, and it needs **both**
directions. With `conditions[0]` absent (`condition_means == [0, X]`) a bug spelled
`fold_change < 1.0` happens to give the right answer — `-1` is indeed below `1` — so the two
implementations agree. Only the mirror (`[X, 0]`) separates them, because there the correct answer
is "enriched in `conditions[0]`" and every `fold_change`-based spelling reads the sentinel as a tiny
ratio and refuses. Hence `ms2_quant_tmt_absent.txt` **and**
`ms2_quant_tmt_treated_absent.txt`, each `ms2_quant_tmt.txt` minus three reporter rows.

Both bug spellings were introduced deliberately against the finished suite and confirmed to fail
it — the threshold-based one at the direction and trap assertions, the `< 1.0` one at the mirror
assertions and nowhere else.

### Quantification still cannot express more than two groups

`conditions` remains exactly two and `fold_change_threshold` remains a ratio test. `identify`
changes what a verdict buys, not what a verdict can say. A time course or dose series still needs a
different statistic, which ADR-0038 declined to guess and this ADR does not revisit.

### What this deliberately does not fix

- **A `NotDifferential` species is still re-screened.** Exclusion is RT-windowed
  (`precursor_selection.rt_window`, 180 s in `method_quant.json`), nothing remembers a verdict, and
  the species returns and is spent on another `'Q'` scan to learn the same thing. `identify:
  "quantified"` makes that second screen *buy* something, which softens the cost but does not
  remove it. Verdict-aware exclusion is the obvious next change and is the only one of these that
  recovers duty cycle rather than redirecting it.
- **A fold change still does not join to its proteoform in one file.** The quant columns sit on
  `scan_results.tsv` keyed by the `'Q'` scan's `tracking_id`, while the proteoform is on the `'R'`
  scan's `identification.tsv` row; connecting them means a three-file join through
  `scan_commands.tsv` for the `precursor_id`. Carrying the verdict onto the identification row
  needs a per-precursor memory and a header-width change, so it was kept out of a byte-identical
  push.
- **An `IncompleteChannels` result still spends a scan and buys nothing** (unless `identify` is
  `all`). Re-acquiring the screen at a higher injection time would work — the gate keys on the
  scan's own `'Q'` marker, so a bought `'Q'` is re-screened automatically — but it needs a retry
  counter or it loops.
- **Every selected precursor is still screened.** Restricting *which* precursors get a `'Q'` scan
  would mean making the level-2 roster per-precursor rather than config-load-time; this ADR is
  entirely downstream of the screen.

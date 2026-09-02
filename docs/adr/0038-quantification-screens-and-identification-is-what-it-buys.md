# 0038. The quantification scan is the screen, and identification is what it buys

Status: Accepted and IMPLEMENTED (2026-08-28). The `scan_results.tsv` quant columns landed first,
sentinel-valued, so the 25-golden recapture they force could be reviewed on its own; the role
inversion, the schema and the behaviour followed in the next push.
Related: [ADR-0014](0014-two-decision-sections-and-named-scan-configs.md) — the two-decision-section
split and the "scan configs referenced by name" rule. This ADR keeps the split and takes the
*other* branch on the reference: the quantification scan gets a bare `ms_settings` slot, the way
`ms_settings.ms3` already serves `characterization`, rather than a name reference.
Related: [ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) — the pairing of a
decision section with a bare scan slot is copied from it verbatim.
Related: [ADR-0009](0009-scan-config-fully-determines-instrument-parameters.md) — the reason the
scan parameters stay in `ms_settings` and never move into `quantification`.

## Context

FLASHIda's isobaric-quantification feature has never worked on an instrument, and the reason is a
role inversion that every layer of the code and config agreed on except the one that mattered.

The engine measures TMT reporter ions on the **returning base MS2** (`FLASHIda.cpp:365` reads that
scan's own `mzs`/`ints`), and on a positive differential-abundance verdict acquires a follow-up
(`:368`). The follow-up is never itself measured — `:363`'s `!is_follow_up_scan` guarantees it.

Everything *named* in the feature describes the opposite arrangement. The config key is
`quantification.follow_up_scan`; the block it points at in the one committed config that enables the
feature is called `quant_follow_up`; the descriptor marker is `'F'`; `IdaLogger.cpp:268` renders it
as `followup`; and `CONTEXT.md:743-746` states the rule as "quantification (`'F'`, when the
precursor is differentially abundant)" — a clause that cannot be true, because a precursor cannot be
known to be differentially abundant before the scan that measures it has been acquired.

The naming won, and the config was authored to match it: `method_quant.json` puts **ETD** on the
base MS2 and **HCD** on the follow-up. ETD cleaves N–Cα backbone bonds and does not release the TMT
reporter; HCD does. So the scan that gets screened cannot produce reporter ions, and the scan that
can is acquired and then ignored. On real data the screen finds six near-empty channels, the
completeness gate at `Quantification.cpp:166-170` rejects the spectrum, and no follow-up is ever
acquired. The committed golden passes only because the fixture `ms2_quant_tmt.txt` is a synthetic
spectrum carrying six TMT reporter peaks, handed to the engine as the ETD scan.

Git history rules out a regression: the activations have been ETD-base / HCD-follow-up since the
feature landed, and the two-decision-section migration (`b33f9be`) was value-preserving. This was
never right.

The feature also carries three artefacts of the same confusion. `only_one_condition` is authorable,
bound, and reaches no emit DTO, so its fully-written branch (`Quantification.cpp:131-163`) is
unreachable on every path. The labelling scheme is hardcoded to TMT-6plex under a literal
`// TODO: Variable channel extractors` (`:86-87`), with a hardcoded 3-vs-3 condition split. And
`Quantification.cpp:118-119` m/z-sorts the extracted channels to recover an ordering that
`IsobaricChannelExtractor.cpp:554-608` had already stated explicitly, by tagging every channel with
its `map_index`.

## Decision

> ⚠ **Amended by [ADR-0039](0039-the-quantification-objective-decides-what-a-verdict-buys.md).**
> *Which* verdicts buy is now authored: `quantification.identify`
> (`differential` | `quantified` | `all` | `none`) plus `quantification.enriched_in`, which names
> the condition a differential species must be enriched in rather than a direction. `differential`
> and `either` are the defaults and reproduce everything below exactly. What is measured, which
> scan is marked `'Q'` and which `'R'`, and the four `scan_results.tsv` columns are untouched —
> 0039 also adds the fourth structural rejection (`enabled` without `ms_settings.ms2`) that the
> three below were missing.

**The quantification scan is the screen. The identification scan is what a differential result
buys.**

Per selected precursor:

```
survey selects a precursor
  → ms_settings.ms2_quant   HCD    dispatched, rostered, priority 2   → labelled 'Q'
  → returns; reporter ions measured; result written to scan_results.tsv
  → differential?
       yes → ms_settings.ms2         ETD    bought, priority 0                 → labelled 'R'
       no  → nothing further for this precursor
```

The engine's existing mechanism is unchanged — a screened primary MS2 buying a conditional
follow-up. Only the two scan configs swap roles.

**`ms_settings.ms2` means "the identification MS2" in every mode.** In quant mode it leaves the
unconditional dispatch roster and becomes the bought scan; its instrument parameters and its `'R'`
label are identical to every other mode. That `ms_settings.ms2` is conditional in a quant config is
left implicit — `quantification.enabled` is in the same file, and the arrangement reads as a
sentence.

**The quantification scan gets a bare slot, not a name reference.** `ms_settings.ms2_quant`
sits beside `ms2` and `ms3`. There is no `quantification.scan: "…"` key, exactly as there is no
`characterization.scan: "ms3"` key.

**A `Q` scan does two things: it is measured, and it buys the identification scan.** It does not
raise tagging follow-ups and does not spawn MS3 targets. Its activation and energy were chosen to
release reporter ions, not to fragment informatively. The `R` identification scan keeps the full
behaviour of a normal MS2 — tagging, conditional follow-ups, MS3 targeting — because it is the scan
chosen to fragment informatively.

**The screen gate becomes `scan_description[3] == 'Q'`,** replacing `!is_follow_up_scan` on the
quantification path. A returning `R` can therefore never be re-screened and never buys another scan,
which preserves depth-one without the marker having to distinguish a follow-up from a primary.

**The labelling scheme is config-declared,** taking the seven schemes OpenMS already ships and
`TopDownIsobaricQuantification.cpp:45` already pins: `itraq4plex`, `itraq8plex`, `tmt6plex`,
`tmt10plex`, `tmt11plex`, `tmt16plex`, `tmt18plex`. `none` is deliberately **not** among them —
`quantification.enabled` is the switch, so `enabled: true, labelling: "none"` cannot be written.

**Conditions are declared by channel name, in an array of exactly two.**

```jsonc
"quantification": {
  "enabled": true,
  "labelling": "tmt6plex",
  "reporter_mz_tol": 0.002,
  "fold_change_threshold": 1.4,
  "conditions": [
    { "name": "control", "channels": ["126", "127", "128"] },
    { "name": "treated", "channels": ["129", "130", "131"] }
  ],
  "correction_matrix": []
},
"ms_settings": {
  "ms2":                { "activation": "ETD", "reaction_time": 7 },
  "ms2_quant": { "activation": "HCD", "collision_energy": 30 }
}
```

An **array**, never an object: `nlohmann`'s `object_t` is a `std::map`, so an object would sort the
two conditions alphabetically and silently decide which is the numerator — the trap
`Config.cpp:612-615` already documents for `additional_ms2`. Array order **is** the ratio direction:
`fold_change = mean(conditions[0]) / mean(conditions[1])`.

Names resolve to channel ordinals at load time via `getChannelInformation()`; the intensity is then
read at that ordinal from the `map_index` the extractor already assigned. The m/z sort at
`Quantification.cpp:118-119` is deleted rather than generalised — it re-derives information the
extractor had already stated.

**Only channels named in a condition are gated.** A channel mentioned in neither is unassigned:
ignored by the completeness gate, still emitted to the log. This is what makes a bridge channel, or
a kit run below capacity, legal — today's gate reads every channel in the scheme, so four samples in
six-plex chemistry rejects every spectrum.

**A wholly-empty condition is `differential`, not a rejection.** A species present in one condition
and absent in the other is the strongest result the experiment can produce; `fold_change` has no
finite value and is logged as `-1`, with `quant_condition_means` carrying the truth. A *partially*
empty condition is still rejected — a zero dragged into a mean biases the ratio and there is no
honest number to report. This makes `only_one_condition`'s intent unconditional and correct, so the
key is **deleted** rather than revived.

**Isotope correction is applied by default,** via `IsobaricQuantifier` with the selected method's
stock matrix. `quantification.correction_matrix` overrides it, and an all-zeros matrix turns
correction off. `normalization` stays at its `false` default, so the quantifier corrects for label
impurity and does nothing else.

⚠ **"All-zeros turns it off" is implemented by FLASHIda, not delegated — and an earlier draft of
this ADR was wrong about that.** `IsobaricQuantitationMethod.cpp:57` does skip `"0.0"`, `"-1"` and
`"NA"`, so such a matrix genuinely builds to the identity — but `IsobaricIsotopeCorrector.cpp:85`
then **throws** on an identity matrix ("*…leading to no correction. Please provide a valid
isotope_correction matrix as it was provided with the sample kit!*"). Handing one through would
therefore abort the measurement of **every scan**, not skip the correction. So `Quantification`
detects the all-zero case itself and sets the quantifier's own `isotope_correction: false` instead.
This is exactly why FLASHDeconv exposes correction as a boolean rather than through the matrix; the
authored surface here stays a single knob, and the engine absorbs the difference.

**Four columns on `scan_results.tsv`,** populated on `Q` rows only:

| column | `Q` row | elsewhere |
|---|---|---|
| `quant_channels` | `;`-joined, all N corrected intensities in `getChannelInformation()` order | `""` |
| `quant_condition_means` | two values, `;`-joined, in `conditions` order | `""` |
| `quant_fold_change` | the computed ratio; `-1` when a condition is wholly empty | `-1` |
| `quant_verdict` | `differential` / `not_differential` / `incomplete_channels` / `extraction_failed` | `""` |

**Three config states are rejected at load:** `enabled: true` without `ms_settings.ms2_quant`;
`conditions` absent or not exactly two; and `quantification.enabled` together with
`precursor_selection.exploration` at level 2.

## Why

**The mechanism was right and the names were wrong, so the names moved.** The engine already
implements screen-then-buy correctly. Reading it the other way — that the follow-up is the
quantification scan — leaves the trigger incoherent, because it requires knowing a differential
result before acquiring the scan that produces one. There is no arrangement of the existing code in
which the *names* are right; there is exactly one in which the *mechanism* is.

`tagging.follow_up_scan` settles it independently. That key does not name "a tagging scan" — tags
are detected in the base MS2 and the follow-up is what the detection buys. Both keys sit on the same
`buildFollowUp` mechanism, so `<trigger>.follow_up_scan` means "the scan this trigger causes", and
quantification was the odd one out only because its name was read as a noun.

**A bare `ms_settings` slot rather than a name reference, because `characterization` already works
that way.** ADR-0014 routed follow-ups through names so that scan parameters would leave the
decision sections and so that an unreferenced block would never fire. The first reason is honoured —
the parameters stay in `ms_settings`. The second does not apply: under this ADR the quantification
scan is *rostered* and fires unconditionally, and it is `ms_settings.ms2` that has become
conditional, so the inversion removes the mechanism the reference was protecting. What is left is
`characterization.mode` + `ms_settings.ms3`: a decision section holding no scan config, paired by
structure with a bare slot, required when the feature is on and inert when it is off.

**Exactly two conditions, because `fold_change_threshold` is a ratio test.** Three or more groups
needs a different statistic, and silently ratioing the first pair would be the same class of error
this ADR exists to fix.

**No activation or tolerance guard.** Requiring the quantification scan's activation to satisfy
`needsCollisionEnergy` (`Config.cpp:208` — the exact HCD/CID/EThcD set) would make the ETD
misconfiguration unauthorable, and the legal `reporter_mz_tol` bound is computable from the
selected scheme's channel spacing (< 3.16 mDa for any N/C scheme, against the flat 0.5 Th the
extractor permits). Both were considered and declined: the user is trusted to know their chemistry.
The cost is that `quant_verdict` is now the sole route by which a misconfigured screen is
discovered, which is why it is a four-way enum rather than a boolean.

## Consequences

### Exactly ONE config migrates, and the activations were already right

All 41 committed configs carry a `quantification` block, but only **`method_quant.json`** authors
either retired key: `follow_up_scan` appears in that one config and `only_one_condition` in none.
The other 40 carry `enabled`/`reporter_mz_tol`/`fold_change_threshold`, all of which the new
allowlist still accepts, and `labelling` has a default while `conditions` is required only when
`enabled` — so they load unchanged.

And the migration is a **pure relocation**: `additional_ms2.quant_follow_up` (HCD, CE 30) becomes
`ms_settings.ms2_quant`, `ms_settings.ms2` keeps its ETD, and no activation moves. The config's
activations were never wrong *for the roles* — HCD is the right screen and ETD the right
identification. What was wrong is which scan the engine measured. That is worth stating plainly
because it narrows the defect: nothing about the authored method needed fixing, only the engine's
idea of what it had been handed.

`MethodConfigSerializer`'s `RetiredKeyHints` still gains entries for both keys — the point of a hint
is the config that has not been migrated yet, not the ones in this repo — and for the `active` →
`enabled` rename in FlashIDA `79caf4b`, which landed without one.

### Twenty-five goldens move for a change that concerns one mode

`GoldenListCanonicalizer.PermuteColumnsToReference` fails closed on any header-width change — "a
rename/add/drop is a schema change, not a permutation" — so four new columns on `scan_results.tsv`
force a recapture of all 25 modes, not just `quant`'s. For 24 of them the diff is four constant
columns (`""`, `""`, `-1`, `""`) appended to every row and is mechanically provable; only `quant`'s
rows need reading. `quant`'s `scan_commands.tsv` moves too, for the label and for the swapped
activations.

### The published numbers change value, not just format

Turning isotope correction on changes the fold change on the existing fixture from its current
`0.512627`. The `quant` golden must be captured after that decision takes effect, never before.

### The label alphabet gains a letter and loses one

`'Q'` joins `S`/`A`/`R`/`E`/`C`; `'F'` is retired along with the `followup` scan-type string.
`FLASHIda.cpp:145-146`'s `is_follow_up_scan` keeps `'C'` for the tagging path only. Note that
`FLASHIda.cpp:734` writes `scan_description[3] = 'C'` on a cycle-time MS1 and is overwritten two
lines later by `snprintf(…, "%sS", …)` — dead today, and a trap for anyone grepping the alphabet.

### Quantification is still measured on a spectrum nobody deconvolves for it

The `Q` scan is deconvolved like any MS2, but its fragment ions are not used — no tagging, no MS3.
Whether an HCD screen's fragments should feed identification alongside the ETD scan's is a real
question this ADR does not answer.

### The 3-vs-3 default disappears with no replacement

`conditions` has no meaningful default, so it is required whenever the feature is on. There is
deliberately nothing behind it: the positional split it replaces was correct only for six-plex and
silently wrong for every scheme this ADR enables.

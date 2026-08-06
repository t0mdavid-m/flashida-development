# 0009. A scan config fully determines a scan's instrument parameters

Status: Accepted (2026-08-05). Extended by [ADR-0010](0010-stage-arrays-are-positional.md), which
carries the same principle into the per-stage arrays and discharges two items deferred below: the
522-row stage-0 `collision_energy`/`hcd_energy` disagreement, and the missing assertion on the
built `ScanCommand`.

## Context

`method.json` carries a scan config at five places — `ms_settings.ms1`, `ms_settings.ms2[]`,
`ms_settings.ms3[]`, `tagging.follow_up_scan`, `quantification.follow_up_scan` — and all five are
validated against the same 17-key `kScanKeys` allowlist. But the two builders that turn a scan
config into a `ScanCommand` had drifted into **two different models**:

- `ScanCommandQueue::buildMS2` starts from a zero-initialised command and sets **every** instrument
  parameter from the config, including `reaction_time` / `reagent_max_it` / `reagent_agc_target`.
- `ScanCommandQueue::buildFollowUp` starts from `ScanCommand cmd = ctx` — a verbatim copy of the
  triggering MS2 — and overrides only `analyzer`, `resolution`, `collision_energy` and
  `activation_type`.

So a follow-up **switched activation without the parameters coupled to that activation**. The
committed goldens contain the result: `golden/logs/tag/scan_commands.tsv.golden.tsv` rows T23/T31
are `activation=HCD, collision_energy=30` carrying `reaction_time=7, reagent_max_it=200,
reagent_agc_target=700000` inherited from the ETD MS2 that triggered them; `golden/logs/quant/`
has six more. On the instrument this reaches the API — `ScanFactory.cs:216` attaches
`ReactionTime = [7.0]` to an HCD custom-scan request.

Two further layers dropped the same keys, so the defect could not be worked around from config:
`Config.cpp` validated all 17 keys but its two `follow_up_scan` parsers read only 8, and
`MethodParameters.ToCppJson` emitted only 4 of `MS2Parameters`' 13 fields, so the keys never
reached C++ at all.

## Decision

- **A scan config fully determines the scan's instrument parameters, at all five sites.** An unset
  value means "use the instrument method default" — the convention `ScanCommand.h` already
  documents (`reaction_time 0 = not used`, `microscans 0 = use method default`) — and never
  "inherit from another scan". Rejected alternatives: making `follow_up_scan` a *patch* on the
  triggering MS2 (would require declared-vs-defaulted tracking that exists nowhere else in the
  config system, and would make `follow_up_scan` the only block with patch semantics), and a
  surgical fix of only the three reaction parameters (leaves `agc_target`/`max_it`/`first_mass`/
  `last_mass` parsed-but-never-applied, and keeps two builder models alive).
- **A follow-up inherits precursor context, not instrument settings.** From the triggering MS2 it
  keeps the precursor targeting (`mono_mass`, `precursor_mz`, `isolation_width`, `charge_state`),
  the precursor scoring fields (`qscore`, `charge_cos`, `charge_snr`, `iso_cos`, `snr`,
  `charge_score`, `ppm_error`, `precursor_intensity`, `peakgroup_intensity`) and — load-bearing —
  `faims_cv`, since a follow-up acquired at a different compensation voltage would sample a
  different ion population entirely. It is therefore implemented as *copy the context, then
  override every instrument parameter*, **not** as a zero-initialised rebuild.
- **Parsing and validation share one source of truth.** One `parseScanConfig` helper reads exactly
  the key set `kScanKeys` admits, used by all five sites, so the two can never diverge again. This
  is what let nine keys pass validation and be silently discarded.
- **Activation-coupled parameters are validated.** `Config::validate()` rejects an activation that
  lacks a parameter it requires — `reaction_time` for ETD/EThcD, `collision_energy` for
  HCD/CID/EThcD — at **all five** scan-config sites, not only on follow-ups. The `needs_ce` /
  `needs_rt` predicate already existed inline in `validate()` for exploration sweeps and is hoisted
  into named helpers rather than duplicated. A silent fallback to the instrument method default is
  exactly the failure mode this ADR exists to prevent, so it is a hard `std::invalid_argument`,
  consistent with ADR-0007.

## Consequences

**Golden impact, as measured after the fact** (an independent two-arm diff review corrected the
original estimate of "eight rows across four goldens"): **12 follow-up commands** move — 6
`scan_type=conditional` in `tag`, 6 `scan_type=followup` in `quant`, rows 24/32/82/92/106/112 in
both. That is **24 changed row-instances across 4 log goldens** (`scan_commands`: `hcd_energy`,
`reaction_time`, `reagent_max_it`, `reagent_agc_target`; `scan_results`: `reaction_time`) plus
**12 changed rows across 2 continuity goldens** (`continuity_{tag,quant}_ms2return.json`,
`HcdEnergy` only — `ToJsonObject` omits `ReactionTime`). No deconvolution, selection, identification
or pooling value moves; `identification.tsv` and `pooled_identification.tsv` are value-identical in
all 16 modes, and there are zero row-count and zero column-set changes.

**Two goldens are knowingly left in the pre-fix state.** `continuity_ms3_mode1_real.json` and
`continuity_ms3_mode2_real.json` are written only by `ContinuityTests` CT35/CT36, which CI excluded,
so they could not be regenerated and were invisible to the golden review. Both hold 10 rows of
`ActivationType=HCD, CollisionEnergy=30, HcdEnergy=0` — exactly the incoherence this ADR removes —
and every scoring field in them is `0`, i.e. they are degenerate independently of this decision
(their sibling `continuity_ms3_mode3_real.json` carries real values). CT35/CT36 have been re-enabled
so their diff can be analysed and a disposition agreed.

**Not covered by any golden.** The log streams expose only 5 of the ~13 instrument parameters this
ADR reasserts — there is no `analyzer`/`resolution`/`agc_target`/`max_it`/`microscans`/`first_mass`/
`last_mass`/`data_type` column anywhere. Both fixtures' `follow_up_scan` shape keys are also
byte-identical to their `ms_settings.ms2`, so those parameters would look unchanged even if the
builder still inherited them. A green golden diff is therefore evidence about the four exposed
columns, **not** proof that nothing else moved on the wire. Assurance for the scan-shape half needs
an assertion on the built `ScanCommand`, or a fixture whose `follow_up_scan` shape deliberately
differs from its `ms_settings.ms2`.

**Same defect class, left standing elsewhere** (pre-existing, unchanged by this ADR, each owed an
explicit decision): `exploration_etd` emits a 6th ETD variant at `reaction_time=0` — outside its
configured sweep range `[3,11]` — while `reagent_max_it=200` / `reagent_agc_target=700000` stay
armed; and 522 MS3 rows across `exploration_ms3` (258) and `exploration_ms3_followup` (264) carry a
stage-0 `collision_energy` that disagrees with stage-0 `hcd_energy` (e.g. 40 vs 35). Both are
synthesised at variant/command-build time, downstream of the config sites `validate()` inspects.

The validate rule makes a bare `ETD` scan config with no `reaction_time` **unloadable**. No shipped
or committed JSON config violates it; twelve inline scan configs in four C++ test files do, and are
updated with the reaction time their comments and fixtures imply. `config_schema_reference.json` is
regenerated from `BuildFullReferenceConfig`, whose `tagging.follow_up_scan` must become coherent.

Unlogged instrument parameters (`microscans`, `data_type`, `rf_lens`, `source_cid*`, `scan_rate`)
now come from the follow-up's own config. The two fixtures that relied on inheriting them declare
them explicitly, so acquisition behaviour is unchanged and the fixture states the intent it
previously got by accident.

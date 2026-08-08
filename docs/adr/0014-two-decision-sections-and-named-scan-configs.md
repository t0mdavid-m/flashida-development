# 0014. Two decision sections, and scan configs referenced by name

Status: Accepted (2026-08-08)

## Context

`selection_strategy` named every key for the level it was **read at**, while the value governed the
level **below**. Every key therefore read exactly one level off its effect:

| key | reads as | actually governs |
|---|---|---|
| `ms1.max_targets` | targets per MS1 | the **MS2** count |
| `ms2.max_targets` | targets per MS2 | the **MS3** budget |
| `ms3.max_targets` | targets per MS3 | an **MS4** budget — nothing |

That is internally consistent, and it still misled: four committed configs set
`ms3.max_targets: 200` believing they had widened the MS3 budget, and silently ran the default 3.
Two of the nine keys were dead by construction, and `ms2.selection`/`ms3.selection` turned out to be
booleans in disguise — only `None`-vs-non-`None` was ever read. Only `ms1.selection` was
value-sensitive (`PrecursorSelection.cpp:246`).

Separately, a scan config appeared at **five** sites with identical shape and one meaning, two of
which (`tagging.follow_up_scan`, `quantification.follow_up_scan`) described MS2 scans that
`ms_settings.ms2` could already express — so a follow-up repeated a 17-key block instead of pointing
at one.

## Decision

**Two decision sections, named for the question they answer**, and scan parameters left where they are:

- **`precursor_selection`** — which intact species do we fragment? Absorbs `selection_strategy.ms1`
  as `rank_by` / `max_precursors` / `min_precursor_charge`, plus the MS2 sweep.
- **`characterization`** — whether and how do we characterize? Absorbs the MS3 budget and
  fragment-charge floor (previously `selection_strategy.ms2.*`), plus the MS3 sweep. See
  [0013](0013-characterization-mode-is-the-single-ms3-switch.md).
- **`ms_settings`** keeps every scan config. Only *selectivity* moved. Moving the MS3 block into
  `characterization` was considered and rejected: it would make `ms3` the odd one out among the
  scan-config sites that ADR-0009 treats as one concept.
- `selection_strategy` is **deleted**, with a dedicated migration error naming all seven destinations.

**Keys are named for what they produce**, so the shift-by-one has nowhere to hide:
`max_precursors` is the MS2 count; `characterization.max_targets` is the MS3 budget.

**Scan configs are referenced by name.** `ms_settings.ms2` and `.ms3` become bare objects like
`ms1`; extras live in a name-keyed `additional_ms2` map and are reached by reference from
`precursor_selection.additional_scans`, `tagging.follow_up_scan` or `quantification.follow_up_scan`.
`Config` resolves names at parse time and materialises `MSLevelConfig::scans` as the ordered
**dispatch roster**, so no downstream consumer learns that names exist and `FLASHIda.cpp:207-225`
changes by zero executable lines.

**Full snake_case.** Every key matches `^[a-z][a-z0-9_]*$`. This reverses a clause in
[0006-single-bridge-config-schema.md](0006-single-bridge-config-schema.md) — see the amendment
there. It binds **keys only**: instrument-facing values (`analyzer`, `data_type`, `scan_rate`,
`activation`) are a wire contract with the Thermo API and keep their casing.

## Why / Consequences

**Order must come from the reference array, never from map iteration.** `nlohmann`'s `object_t` is a
`std::map`, so iterating `additional_ms2` sorts names alphabetically — which would silently reorder
MS2 dispatch, and with it `scan_commands` row order and `child_ids`. Pinned by
`Config_SchemaProjection_test::scan_name_resolution`, whose fixture names are chosen so that
alphabetical order is *wrong*.

**Names are user-authored, so they cannot be allowlisted.** They are validated as identifiers
(`^[a-z][a-z0-9_]{0,31}$`, reserved words rejected) and their *values* still go through the 17-key
scan allowlist. Referential closure replaces allowlisting: a typo in a reference is a hard error, a
typo in a definition surfaces as an unreferenced-block warning.

**An unreferenced definition never fires**, which is the entire mechanism keeping a follow-up-backing
block from becoming an unconditional MS2. It warns rather than throws, because commenting a scan out
of the roster while tuning is normal.

**This makes ADR-0006 easier, not harder.** `MethodParameters.BuildSelectionStrategy()` — its largest
remaining non-identity transform, which synthesised a whole section and shared one `defaultExpl`
instance across three levels — is deleted, and five scan-config parse sites become three.

**Migration was value-preserving and machine-checked**, not asserted: `migrate_config_schema.py`
reduces both schemas to the values the engine actually uses and compares per file. 34 configs and 56
C++ fixture blocks, zero effective-behaviour changes. The gate is kept in the repo for the next
schema move.

The int→string `targeting` enum takes its mapping from the **code** (`2=in_depth`, `3=exclusion_masses`
per `PrecursorSelection.cpp:138-141`); `MethodConfig.cs`, `Config.h` and `PrecursorSelection.cpp:564`
all had 2 and 3 the wrong way round.

**The four `200` budgets were not restored, and that is deliberate.** `method_exploration_followup`,
`method_ms3_cytc_coverage`, `method_ms3_cytc_new` and `method_ms3_cytc_real` each wrote
`ms3.max_targets: 200` into a key with zero read sites, so no run has ever executed a budget other
than the default 3 and every golden reflects 3. Migration wrote the *effective* value. Raising them
to a real 200 was considered and declined: it would be a large untested acquisition change — up to
200 MS3 targets per precursor — made to honour a number that only ever existed in a key that did
nothing. If a wider budget is wanted, it should be chosen from evidence and land as its own
golden-moving change, not inherited from a typo.

**`precursor_selection.HCDEnergy` is gone along with the plumbing behind it.** Its only export,
`PrecursorSelection::getIsolationWindows()`, had zero callers repo-wide, so `trigger_hcds_`,
`triggerHcds()`, the `TargetingConfig::hcd_energy` field and the `ChargeCandidate::hcd` member were
all removed with it. ⚠ Do not confuse this with `ScanCommand::hcd_energy`, which is **alive and
unrelated**: it mirrors `stages[0].collision_energy` into the log schema and is part of the
2048-byte ABI.

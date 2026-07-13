# 0007. Strict config schema: snake_case-only `ms_settings`, hard rejection of unknown keys, self-generating reference

Status: Accepted (2026-07-13)

## Context

ADR-0006 collapsed FLASHIda's two config schemas into one bridge schema, but left three
soft spots that let drift persist:

- **`ms_settings` stayed PascalCase on disk** (`FirstMass`, `OrbitrapResolution`, …) while
  every other section is snake_case and the engine only ever reads snake_case. It "worked"
  only because the C# loader had a tolerant heuristic (`NormalizeFieldName`: strip `_` +
  lowercase, plus a `resolution`→`OrbitrapResolution` alias) that silently accepted **both**
  spellings — the exact mechanism that hid the inconsistency and would swallow any typo.
- **Unknown keys were silently ignored** on both sides. A mistyped key (`FirstMass`,
  `IDScore`, a legacy `developer{}` block) parsed to nothing with no error — the same class
  of foot-gun ADR-0006 set out to kill, still present at the key level.
- **The drift-guard reference was hand-authored** (`config_schema_reference.json` with
  per-key sentinels), so it could itself go stale relative to the code.

## Decision

Make the single schema **strict and self-describing**.

- **snake_case-only `ms_settings`, bound by explicit `[JsonKey]`.** Each `MS1/MS2/MS3Parameters`
  struct field carries an explicit snake_case `[JsonKey]` (`FirstMass`→`first_mass`,
  `OrbitrapResolution`→`resolution`, …). `PopulateStruct` and `SerializeStruct` both bind by
  that key; the `NormalizeFieldName` heuristic and the `resolution` alias are **deleted**.
  snake_case is now the only accepted spelling (consistent with the ADR-0006 hard cutover).
  All 31 config files migrate value-preserving (a pure key re-casing).
- **`IsolationMode` dropped.** It was the one `ms_settings` field the bridge never carried
  (`ToCppJson` never emitted it; no C# reader) — removed from the structs and every config.
- **Unknown keys are hard-rejected on both sides, with informative messages.** The C# loader
  (`MethodConfigSerializer.ValidateNoUnknownKeys`) walks the raw JSON against the model and
  throws, naming every offending dotted path. The C++ `Config` constructor calls
  `rejectUnknownKeys` per object against a per-section allowlist and throws
  `std::invalid_argument`. The dynamic `exploration.overrides` map is the sole exemption.
- **The reference is self-generated.** `MethodParameters.GenerateReferenceConfigJson()` emits
  the complete bridge JSON (default values) from a fully-populated config; the committed
  `config_schema_reference.json` **is** that output. A C# staleness test
  (`Reference_IsNeverStale`) asserts committed == generated; the C++ read-proof
  (`EveryKey_ParsesToOnDiskValue`) asserts each parsed field == the on-disk value (no
  hard-coded sentinels to drift).

## Considered Options

- **Keep the tolerant loader + add a config-lint test.** Rejected: leaves the
  normalization crutch (the mechanism that hid the drift) in the code, and keeps two
  accepted spellings — weaker than the owner's "can never diverge" requirement.
- **Allowlist `IsolationMode` (and other dead keys) rather than remove them.** Rejected:
  tolerating non-schema keys reintroduces exactly the silent-accept behavior being removed,
  and creates a C#/C++ strictness divergence.
- **Hand-maintain the sentinel reference fixture.** Rejected: a second, manually-kept source
  of truth can go stale; generating it from code makes staleness a test failure.

## Consequences

- **Any config with a PascalCase `ms_settings` key, a stray/legacy key, or a mistyped key
  now fails loudly** on load (C#) and on `Config` construction (C++) — a stricter cutover
  than ADR-0006. Pre-existing dead keys had to be scrubbed from the C++ test corpus
  (`IDScore`, the legacy top-level `exploration` block, a singular `activation`).
- **Value-preserving, zero golden recapture.** The engine sees byte-identical values (the
  loader already normalized both spellings identically; `ToCppJson` already emitted
  snake_case); dropped keys were always constant defaults the reader re-defaults identically.
- **The scan-config key set is now symmetric** (struct field ⇄ emit ⇄ on-disk ⇄ C++ read).
  Four always-default emit-only keys (`scan_rate`; `rf_lens`/`source_cid`/`source_cid_scaling`
  on ms2/ms3) were trimmed so the emitted schema equals the struct field set.
- **Hard to reverse** (operators' PascalCase/legacy configs now fail — a stricter public
  contract), **surprising** (a config that "looks fine" throws on an unknown key), and a
  **genuine trade-off**: strictness + a loud failure mode was chosen over lenient tolerance
  specifically so the two sides can never silently diverge again, at the cost of zero
  forgiveness for typos or stale keys.

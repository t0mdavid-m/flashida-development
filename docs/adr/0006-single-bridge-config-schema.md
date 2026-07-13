# 0006. One bridge config schema: C# and C++ read the same JSON; ToCppJson becomes identity

Status: Accepted (2026-07-13)

## Context

FLASHIda configuration crossed **two deliberately different JSON schemas** (ADR-0004
named them "two deliberately different schemas"):

- a **user-facing** schema — what the operator edited in `method.json`: lowercase keys,
  a nested `developer{}` block populated by `[Developer]` reflection routing,
  `targeting_mode:"none"` as a string, PascalCase `ms_settings`, and flat
  `scheduling.cycle_time_enabled` — read by `MethodParameters.Load` /
  `MethodConfigSerializer`; and
- a **bridge** schema — `RT_window`, `target_mode:0` (int), `AllCharges` / `HCDEnergy`,
  snake_case `ms_settings.first_mass`, and nested `scheduling.cycle_time.enabled` — emitted
  by `MethodParameters.ToCppJson()` and parsed by C++ `Config.cpp`. This is the **only**
  schema the engine ever sees.

The two silently drifted. A config authored in the bridge shape — the shape the engine
actually reads — **lost most of its keys** when fed to the production loader, which keyed
off the user-facing names (the "only the old upper-case configs actually get read"
symptom). Conversely, a key added on one side and forgotten on the other was dropped with
no error (the schema-mismatch foot-gun documented in `docs/kb/config-flow/`). The
hand-maintained `ToCppJson()` rename map was the standing source of that divergence.

## Decision

Collapse the two schemas into **one canonical schema = the bridge schema** — a hard
cutover with no backward-compat shim (Option B below). The operator now writes the bridge
schema, C# reads the bridge schema, and C++ reads the bridge schema, with **no translation
between them**.

- **`ToCppJson()` becomes ~identity.** The C# POCO **property** names stay stable
  (`Config.Faims.CVValues`, `MsSettings.MS1.FirstMass`, …) so the ~40 tests that read them
  do not ripple; only the `[JsonKey]`s are re-pointed at the bridge keys, plus a few
  structural transforms in the loader (int `target_mode` ↔ string `TargetingMode`, nested
  `scheduling`, snake_case `ms_settings` matching). `ToCppJson()` then emits the same bridge
  JSON the loader read; `ToCppJson(Load(x))` round-trips.
- **The `developer{}` wrapper is gone.** `[Developer]` routing is retired; former
  developer-only fields (`AllCharges`, `HCDEnergy`, `ChargeBasedExclusion`,
  `cv_precursor_threshold`, `max_cv_skip`) sit flat in their sections.
- **Legacy upper-case keys are kept as-is** (`RT_window` / `AllCharges` / `HCDEnergy`) —
  *not* normalized to snake_case — to minimize churn.
- **New `flashtnt` block** exposes the live FLASHTagger/FLASHExtender knobs (`min_length`,
  `max_length`, `max_ptm_count`, `max_flanking_mass_diff`, `allow_gap`, `max_aa_in_gap`,
  `fixed_mod`, `max_blind_mod_count`, `max_mod_mass`). The four old
  `tagging.min_tag_length…` algorithm keys **move** here; `tagging` retains only the
  acquisition-workflow `follow_up_scan`.
- **New `global.duration`** key — the only C#-consumed value (the acquisition timer in
  `Flash.cs`) the bridge schema previously lacked.
- **Dead keys removed:** `IDScore`, the flat `exploration:{enabled,max_depth,max_variants}`
  block, and `quantification.only_one_condition`.

## Considered Options

- **Option A — user-facing schema as canonical** (teach C++ to read the user-facing keys).
  Rejected: the engine (`Config.cpp`) already reads the bridge schema, and the C++ FLASH
  test corpus is authored against it; making C++ the side that changes maximizes churn in
  the untouchable-adjacent engine glue.
- **Option B — bridge schema as canonical** (chosen). C++ is unchanged in shape; only the
  C# loader re-points and the config files migrate. Minimizes C++/engine churn.
- **Keep both schemas behind a stricter translator.** Rejected: the translator itself was
  the drift source; a second source of truth cannot be made drift-proof, only drift-noisy.

## Consequences

- **Old user-facing `method.json` files no longer load** — a hard cutover. Every operator
  method must be re-authored in the bridge schema.
- **All 30 `test-data/configs/method_*.json`** (plus the shipped `etc/method.json`) migrate
  **value-preserving** via `bridge = ToCppJson(OldLoad(file)) + global.duration`, so the
  engine sees byte-identical values and **no golden moves**.
- A **permanent drift guard** replaces the discipline that used to hold the two schemas in
  sync: a shared sentinel reference fixture (`config_schema_reference.json`, where every
  bridge key holds a unique value), a C# emit-equality test (`ConfigSchemaParityTests`)
  proving C# emits exactly the reference key-set, a C++ per-field parse test
  (`ConfigSchemaParity_test`) proving C++ reads every reference key, and a PreToolUse hook
  (`config-schema-drift-reminder.sh`) that fires when a schema file is edited. Add a key on
  only one side → a test fails.
- The decision is **hard to reverse** (the schema is a public, operator-facing contract),
  **surprising** (two schemas existed *on purpose* — bridge keys were engine-controlled and
  evolved independently of the operator-facing names), and a **genuine trade-off**:
  bridge-as-canonical was chosen over user-facing-as-canonical specifically to keep
  C++/engine churn minimal, at the cost of a one-time operator migration.

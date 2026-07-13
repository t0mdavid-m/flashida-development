---
title: Config Flow — one bridge schema, C# to C++ engine
applies_to: FlashIDA/src/Flash/MethodParameters.cs, FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-07-13
code_anchors:
  - FlashIDA/src/Flash/MethodParameters.cs:92   # Load
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:136   # PopulateObject
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:176   # ConvertValue
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:315   # PopulateStruct
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson (≈ identity emit)
  - FlashIDA/src/Flash/MethodParameters.cs:269   # BuildSelectionStrategy
  - FlashIDA/src/Flash/MethodConfig.cs:389   # MethodConfig root
  - FlashIDA/src/Flash/MethodConfig.cs:639   # JsonMethodConfig root
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:100   # CreateFLASHIda P/Invoke decl
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:130   # wrapper ctor
  - FlashIDA/src/Flash/Flash.cs:135   # CLI default method.json path
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39   # CreateFLASHIda C++
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:62   # FLASHIda ctor
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:111   # tolerance fallback
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:132   # flashtnt section parse
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:192   # legacy ms3.* key rejection
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:445   # Config::validate definition
see_also:
  - adding-a-config-field.md
  - developer-attribute.md
---

# Config Flow — one bridge schema, C# to C++ engine

## Overview

Configuration travels through **one canonical JSON schema — the *bridge* schema — and four
language boundaries** before reaching the C++ engine's typed structs. Both the C# loader and
the C++ engine read the same keys; there is no longer a separate user-facing schema
(ADR-0006). The journey has five conceptual hand-offs: (1) disk load into a C# POCO tree via
reflection-driven deserialization keyed on the bridge keys; (2) re-serialization of that
tree back into the *same* bridge JSON for the engine — an **≈ identity emit**, not a rename;
(3) a P/Invoke call that marshals the JSON string across the language boundary; (4) the C++
bridge constructing a `FLASHIda` object with the string; and (5) `Config::Config` parsing
that string into strongly-typed structs, after which every subsystem reads those structs for
the entire run. Because load and emit use the same schema, a config round-trips:
`ToCppJson(Load(x))` is stable.

## Stage 1 — Disk Load

`MethodParameters.Load(path)` (`FlashIDA/src/Flash/MethodParameters.cs:92`) reads
the file with `File.ReadAllText` and delegates immediately to
`MethodConfigSerializer.Deserialize(json)` (`MethodConfigSerializer.cs:23`). No
validation or transformation happens here — this stage is purely I/O. The Flash CLI
default: when no method path is provided, the runtime resolves `method.json` in the
program folder (`Flash.cs:135`), so dropping a bridge-schema `method.json` next to
`Flash.exe` is all that is needed for bare invocations.

## Stage 2 — C# POCO Tree

The deserialized result is a `MethodConfig` instance (`MethodConfig.cs:389`), the root of
the POCO hierarchy. Sections map directly to top-level JSON objects: `Global`,
`Deconvolution`, `PrecursorSelection`, `FlashTnT`, `Tagging`, `Quantification`, `Faims`,
`MsSettings`, `Scheduling`, `SelectionStrategy`, `Characterization`, `Files`, and `Runtime`.
Each section class carries a class-level `[JsonKey("...")]` naming its JSON key; each
property also carries `[JsonKey("...")]`. The `[JsonKey]`s now point at the **bridge** keys
(e.g. `RT_window`, `AllCharges`, `HCDEnergy`), but the POCO **property** names stay stable
(`ConsiderAllChargeStates`, `HCDEnergy`, …) so C# read sites don't churn. There is no
`developer` sub-object and no `[Developer]` routing — all fields are flat in their section
(see `developer-attribute.md`).

## Stage 3 — Reflection-Based Deserialization

`PopulateObject` (`MethodConfigSerializer.cs:136`) is the engine of Stage 2. It
walks every public instance property and reads the `[JsonKey]` to determine the JSON
key name. Type coercion happens in `ConvertValue` (`MethodConfigSerializer.cs:176`),
which handles primitives, `double[]` (from `ArrayList`), `List<string>`,
`List<MS2Parameters>`, value-type structs (dispatched field-by-field through
`PopulateStruct` at `MethodConfigSerializer.cs:315`), and nested config class objects via
recursive `PopulateObject` calls. A handful of structural transforms live here because the
schema is legacy-shaped: `target_mode` int is mapped to the `TargetingMode` string, the
snake_case `ms_settings` keys are matched to PascalCase struct fields, and `scheduling` is
read from its nested form. Unknown keys are silently ignored — the C# tree only sees what
its properties declare.

## Stage 4 — Re-Serialization for C++ (≈ identity)

`MethodParameters.ToCppJson()` (`MethodParameters.cs:100`) rebuilds the object graph rooted
at `JsonMethodConfig` (`MethodConfig.cs:639`) and serializes it to JSON — the string the
C++ engine receives. Because the loader now reads the bridge schema, **this emit is ≈ the
identity of what was loaded**: the same bridge keys go back out, not a renamed set. The POCO
property names are PascalCase C#; the emitted JSON keys are the bridge keys. A few residual
transforms remain: the `TargetingMode` string (`none|inclusion|exclusion|deep`) is written
back as a `target_mode` integer (0–3); `BuildSelectionStrategy` (`MethodParameters.cs:269`)
flattens the selection-strategy sub-trees into arrays; nullable `FollowUpScan` becomes a
JSON object-or-null. New in the single schema: the emit carries a `flashtnt` block (the
tagger/extender knobs) and `global.duration`. Any new field must still be present in both
the POCO/`[JsonKey]` (load) and the `JsonMethodConfig` proxy (emit) — see
`adding-a-config-field.md`.

## Stage 5 — P/Invoke Bridge

`FLASHIdaWrapper(MethodParameters mp)` (`FLASHIdaWrapper.cs:130`) calls
`CreateFLASHIda(mp.ToCppJson())`. The P/Invoke declaration at `FLASHIdaWrapper.cs:100`
marks the function as returning `IntPtr`; a `null` (`IntPtr.Zero`) return causes an
immediate `InvalidOperationException`. The C++ side is responsible for printing the
error to stderr before returning null, so the exception message is intentionally
terse — the diagnostic detail appears in the console before the C# exception.

## Stage 6 — C++ Entry

`CreateFLASHIda(char*)` (`FLASHIdaBridgeFunctions.cpp:39`) is the sole entry point
from managed code. It constructs `new FLASHIda(arg)` inside a try/catch and returns
null if any exception propagates. The `FLASHIda` constructor at `FLASHIda.cpp:62`
member-initializes `config_(std::string(arg))` as the first initializer, before
`queue_`, `deconv_`, `fragments_`, `selection_`, `quant_`, `faims_`, and
`exploration_`. Every other subsystem depends on `config_` being ready, which is why
`Config` construction is ordered first in the initializer list.

## Stage 7 — C++ JSON Parsing

`Config::Config(const std::string&)` (`Config.cpp:84`) does the actual JSON parse.
Its first act is a guard: if the string is empty or does not start with `{`, it
throws `std::invalid_argument` immediately — this surfaces P/Invoke misuse (e.g.
a null string marshaled as an empty C++ string). After the guard, `nlohmann/json`
parses the string and the constructor populates `DeconvolutionConfig`,
`TargetingConfig`, `FAIMSConfig`, `SchedulingConfig`, `QuantConfig`, `RuntimeConfig`,
and `std::map<int, MSLevelConfig> levels_`. The `flashtnt` section
(`Config.cpp:132`) fills the FLASHTagger/FLASHExtender fields on `TargetingConfig`
(`min_tag_length`, `max_tag_length`, `max_total_ptm_count`, `max_flanking_mass_diff`,
`allow_gap`, `max_aa_in_gap`, `max_blind_mod_count`, `max_mod_mass`, `fixed_mod`). Every
scalar field uses `.value(key, default)`, so missing keys silently take the compiled-in
default — no exception for absent optional keys. One default is load-bearing:
`flashtnt.max_mod_mass` defaults to **700**, not the extender's own 500, to preserve the
existing MS2 fragment-matching behavior.

## Stage 8 — Legacy-Key Rejection

After filling the main config, the constructor explicitly rejects five keys that were
once valid under the `ms3` section: `enabled`, `active`, `mode`, `all_charges`, and
`max_per_ms2` (`Config.cpp:192`). Any of these present in the parsed JSON throws
`std::invalid_argument` with a migration message pointing the operator toward
`selection_strategy.ms2`. The user sees this as `CreateFLASHIda error: Config:
ms3.<key> is no longer supported...` on stderr before the C# `InvalidOperationException`.
(This is a per-section legacy guard, distinct from the schema collapse — those keys are
rejected outright, not migrated.)

## Stage 9 — Validation

`validate()` is called at the end of `Config::Config` (`Config.cpp:442`; definition at `:445`). It enforces
constraints that cannot be expressed as individual defaults: conditional MS2 requires a
`follow_up_scan` to be configured (see [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md) for the downstream mode mechanics); and any
MS level configured for exploration must have exactly one scan config entry. Any
violation throws `std::invalid_argument` with a diagnostic message, surfacing on
stderr before C# sees a null return.

## Stage 10 — Consumer Wiring

Every subsystem constructed in `FLASHIda::FLASHIda` (`FLASHIda.cpp:62`) receives
`config_` by const-reference and stores that reference. Stable read paths used
throughout the codebase: `config_.targeting().hcd_energy` for fragmentation energy,
`config_.targeting().max_mod_mass` and `config_.targeting().min_tag_length` for the tagger/
extender, `config_.level(2).selection` for MS2 selection metric, and
`config_.faims().cv_values` for FAIMS cycling. Because `config_` is const after
construction, no subsystem can mutate it — divergence between the parsed state and runtime
behavior requires looking at state held by individual subsystems, not at config.

## Schema Drift Guard

One schema wired on two sides (C# loader/emitter, C++ parser) can still lose a key on one
side if a field is added to only one. A permanent, CI-gated guard makes that a test failure
rather than a silent default:

- `FlashIDA/test-data/config_schema_reference.json` — a maximal bridge config; every key a
  unique sentinel value. Single source of truth for both tests.
- `ConfigSchemaParityTests` (C# / NUnit) — `ToCppJson(Load(reference))` must emit exactly
  the reference key-set (set-equality both directions, minus the allowlisted C#-only
  `global.method_name/description`), and every sentinel must survive the round-trip.
- `ConfigSchemaParity_test` (C++ / ctest) — per-field `TEST_EQUAL(cfg.<section>().<field>,
  <sentinel>)` for every C++-owned field, proving C++ reads every reference key.
- `.claude/hooks/config-schema-drift-reminder.sh` (PreToolUse) — reminds you to update the
  reference fixture and both parity assertions when a schema file is edited.

## Gotchas

- **One schema, but two sides.** The JSON is now a single schema, but a field still lives in
  both the C# POCO/`[JsonKey]` + `ToCppJson` emit *and* the C++ struct + parser. Forget
  either side and the value is silently dropped — the engine applies its compiled-in
  default with no warning. The drift guard (above) now turns that into a failing test.

- **`[Developer]` routing is retired.** There is no `developer{}` block in `method.json` and
  no `[Developer]` attribute in the flow. Fields formerly routed there (`AllCharges`,
  `HCDEnergy`, `ChargeBasedExclusion`, `cv_precursor_threshold`, `max_cv_skip`) are flat in
  their sections. See `developer-attribute.md` for the retired mechanism.

- **`flashtnt.max_mod_mass` defaults to 700.** The FLASHExtender's own default is 500;
  `Config.cpp` overrides it to 700 to preserve the historical MS2 fragment-matching
  behavior. Lowering it (or dropping the key so the extender default applies) shifts every
  FragmentAnalysis result.

- **Tolerance array fallback.** If `tol` is absent or empty, the engine substitutes
  `[10, 10]`; if it has exactly one entry, that entry is duplicated to produce two
  (`Config.cpp:111`). Relying on this silently for MS3 will break once three-entry
  arrays are required.

- **`FAIMSConfig::enabled` is derived.** There is no `enabled` key in the C++ FAIMS
  config. Enabled is true iff `cv_values.size() > 1`. Setting `enabled: true` in the
  method without multiple CV values has no effect.

---
title: Config Flow Packet
applies_to: FlashIDA/src/Flash/MethodParameters.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-07-13
code_anchors:
  - FlashIDA/src/Flash/MethodParameters.cs:92   # MethodParameters.Load entry
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize (reads the bridge schema)
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson (≈ identity: bridge POCO -> same bridge JSON)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39   # C++ entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config parse (single bridge schema)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:132   # flashtnt section parse
see_also:
  - ../ms1-acquisition/README.md
  - ../acquisition-loop/README.md
  - ../fragment-analysis/README.md
---

## Overview

Configuration flows through **one canonical JSON schema — the *bridge* schema — read by
both C# and C++** (ADR-0006). An operator edits `method.json` in the bridge schema
(`RT_window`, `target_mode:0`, `first_mass`, `cycle_time.enabled`, a `flashtnt` block,
`global.duration`, …); FlashIDA reads it into a C# POCO tree via reflection-driven
deserialization keyed on the bridge keys, then re-emits *the same* bridge JSON for the C++
engine — `ToCppJson()` is now an **≈ identity** step, not a rename/translation. The engine
parses that JSON once, stores the result in strongly-typed structs, and every subsystem
reads those parsed structs for the rest of the run.

There is **no longer a separate user-facing schema and no `developer{}` wrapper.** Before
this collapse, the operator-facing keys and the engine-facing keys were two deliberately
different sets that silently drifted; the single schema removes the translation layer that
caused that drift. The POCO *property* names stay stable (`Config.Faims.CVValues`,
`MsSettings.MS1.FirstMass`, …) so C# read sites and their tests do not churn — only the
`[JsonKey]`s point at the bridge keys.

## Read Order

- `config-flow.md` — end-to-end data path, stage by stage, with anchors at each handoff.
- `adding-a-config-field.md` — how-to recipes for a new field and a new MS-level entry (plus the drift-guard step).
- `developer-attribute.md` — how `[JsonKey]` reflection routing works, and why the `[Developer]` attribute is retired.

## Entry Points

- `MethodParameters.Load` — `FlashIDA/src/Flash/MethodParameters.cs:92`
- `MethodConfigSerializer.Deserialize` — `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23`
- `MethodParameters.ToCppJson` (≈ identity) — `FlashIDA/src/Flash/MethodParameters.cs:100`
- `CreateFLASHIda` (C++) — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39`
- `Config::Config` — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`

## Schema Drift Guard

Because a single snake_case schema is wired on two sides (C# loader/emitter and C++ parser),
a permanent guard prevents them from silently diverging again. Keys are case-sensitive and
unknown keys are hard-rejected on both sides. See ADR-0007.

- `FlashIDA/test-data/config_schema_reference.json` — the complete bridge config, **generated**
  by `MethodParameters.GenerateReferenceConfigJson()` (never hand-edited; regenerate with
  `REGEN_CONFIG_REFERENCE=1`).
- `ConfigSchemaParityTests` (C# / NUnit) — `Reference_IsNeverStale` (committed == generated),
  `Emit_And_Reload_PreserveEveryKey` (strict loader accepts it, `ToCppJson` re-emits every key),
  `Reject_UnknownKey_Throws`.
- `ConfigSchemaParity_test` (C++ / ctest) — `EveryKey_ParsesToOnDiskValue` (each parsed field ==
  the on-disk value — a read-proof with no hard-coded sentinels), `UnknownKey_Throws`.
- `.claude/hooks/config-schema-drift-reminder.sh` (PreToolUse) — fires when `Config.{cpp,h}`,
  `MethodConfig.cs`, `MethodParameters.cs`, or `MethodConfigSerializer.cs` is edited.

## Related Packets

- `../ms1-acquisition/README.md` — MS1 selection, FAIMS cycling, and exploration are consumers that read the parsed configuration via `config_.targeting()`, `config_.faims()`, and `config_.level(n)`.

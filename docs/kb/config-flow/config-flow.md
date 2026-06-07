---
title: Config Flow — method.json to C++ engine
applies_to: FlashIDA/src/Flash/MethodParameters.cs, FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-04-19
code_anchors:
  - FlashIDA/src/Flash/MethodParameters.cs:92   # Load
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:136   # PopulateObject
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:176   # ConvertValue
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:315   # PopulateStruct
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson
  - FlashIDA/src/Flash/MethodParameters.cs:266   # BuildSelectionStrategy
  - FlashIDA/src/Flash/MethodConfig.cs:344   # MethodConfig root
  - FlashIDA/src/Flash/MethodConfig.cs:569   # JsonMethodConfig root
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:100   # CreateFLASHIda P/Invoke decl
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:130   # wrapper ctor
  - FlashIDA/src/Flash/Flash.cs:135   # CLI default method.json path
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39   # CreateFLASHIda C++
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:62   # FLASHIda ctor
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:111   # tolerance fallback
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:172   # legacy-key rejection
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:422   # Config::validate definition
see_also:
  - adding-a-config-field.md
  - developer-attribute.md
---

# Config Flow — method.json to C++ engine

## Overview

Configuration travels through two distinct JSON schemas and four language boundaries
before reaching the C++ engine's typed structs. The journey has five conceptual
hand-offs: (1) disk load into a C# POCO tree via reflection-driven deserialization;
(2) re-serialization of that tree into a *different* JSON schema keyed for the C++
engine; (3) a P/Invoke call that marshals the JSON string across the language
boundary; (4) the C++ bridge constructing a `FLASHIda` object with the string; and
(5) `Config::Config` parsing that string into strongly-typed structs, after which
every subsystem reads those structs for the entire run. The two-schema design is
intentional: user-facing keys are descriptive and stable across method versions;
C++-facing keys are compact and controlled by the engine team independently.

## Stage 1 — Disk Load

`MethodParameters.Load(path)` (`FlashIDA/src/Flash/MethodParameters.cs:92`) reads
the file with `File.ReadAllText` and delegates immediately to
`MethodConfigSerializer.Deserialize(json)` (`MethodConfigSerializer.cs:23`). No
validation or transformation happens here — this stage is purely I/O. The Flash CLI
default: when no method path is provided, the runtime resolves `method.json` in the
program folder (`Flash.cs:135`), so dropping a `method.json` next to `Flash.exe` is
all that is needed for bare invocations.

## Stage 2 — C# POCO Tree

The deserialized result is a `MethodConfig` instance (`MethodConfig.cs:344`), which
is the root of the user-facing POCO hierarchy. Sections map directly to top-level
JSON objects: `Global`, `Deconvolution`, `PrecursorSelection`, `Tagging`,
`Quantification`, `Faims`, `MsSettings`, `Scheduling`, `SelectionStrategy`, `Ms3`,
`Files`, and `Runtime`. Each section class carries a class-level `[JsonKey("...")]`
attribute naming its JSON key; each property on those classes also carries
`[JsonKey("...")]` and optionally `[Developer]` to route it to or from a separate
`developer` sub-object. The attribute system is described in `developer-attribute.md`.

## Stage 3 — Reflection-Based Deserialization

`PopulateObject` (`MethodConfigSerializer.cs:136`) is the engine of Stage 2. It
walks every public instance property, reads the `[JsonKey]` to determine the JSON
key name, and checks for `[Developer]` to decide whether to pull the value from the
main dict or the developer dict. The actual type coercion happens in `ConvertValue`
(`MethodConfigSerializer.cs:176`), which handles primitives, `double[]` (from
`ArrayList`), `List<string>`, `List<MS2Parameters>`, value-type structs (dispatched
field-by-field through `PopulateStruct` at `MethodConfigSerializer.cs:315`), and
nested config class objects via recursive `PopulateObject` calls. Unknown keys are
silently ignored — the C# tree only sees what its properties declare.

## Stage 4 — Re-Serialization for C++

`MethodParameters.ToCppJson()` (`MethodParameters.cs:100`) builds a *second, entirely
different* object graph rooted at `JsonMethodConfig` (`MethodConfig.cs:569`) and
serializes it to JSON. This is the output the C++ engine will receive. The schemas
diverge significantly: user-facing sections use PascalCase C# names, while C++-facing
classes use snake_case fields matching what `nlohmann/json` expects. Key
transformations: `TargetingMode` string (`none|inclusion|exclusion|deep`) is
converted to a `target_mode` integer (0–3) via a 4-branch switch; `BuildSelectionStrategy`
(`MethodParameters.cs:266`) normalizes `MS1/MS2/MS3.Selection` to lowercase and
flattens the selection-strategy sub-trees into arrays; nullable `FollowUpScan`
becomes JSON object-or-null. Because this is a manual mapping, every new field
must be wired in both directions — see `adding-a-config-field.md`.

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
and `std::map<int, MSLevelConfig> levels_`. Every field uses `.value(key, default)`,
so missing keys silently take the compiled-in default — no exception for absent
optional keys.

## Stage 8 — Legacy-Key Rejection

After filling the main config, the constructor explicitly rejects five keys that were
once valid under the `ms3` section: `enabled`, `active`, `mode`, `all_charges`, and
`max_per_ms2` (`Config.cpp:172`). Any of these present in the parsed JSON throws
`std::invalid_argument` with a migration message pointing the operator toward
`selection_strategy.ms2`. The user sees this as `CreateFLASHIda error: Config:
ms3.<key> is no longer supported...` on stderr before the C# `InvalidOperationException`.

## Stage 9 — Validation

`validate()` is called at the end of `Config::Config` (`Config.cpp:418`; definition at `:422`). It enforces
constraints that cannot be expressed as individual defaults: conditional MS2 requires a
`follow_up_scan` to be configured (see [`../fragment-analysis/tag-follow-up.md`](../fragment-analysis/tag-follow-up.md) for the downstream mode mechanics); and any
MS level configured for exploration must have exactly one scan config entry. Any
violation throws `std::invalid_argument` with a diagnostic message, surfacing on
stderr before C# sees a null return.

## Stage 10 — Consumer Wiring

Every subsystem constructed in `FLASHIda::FLASHIda` (`FLASHIda.cpp:62`) receives
`config_` by const-reference and stores that reference. Stable read paths used
throughout the codebase: `config_.targeting().hcd_energy` for fragmentation energy,
`config_.level(2).selection` for MS2 selection metric, and `config_.faims().cv_values`
for FAIMS cycling. Because `config_` is const after construction, no subsystem can
mutate it — divergence between the parsed state and runtime behavior requires looking
at state held by individual subsystems, not at config.

## Gotchas

- **Two schemas.** The JSON the operator edits and the JSON the C++ engine parses have
  *different key names*. Changing the user-facing schema without updating `ToCppJson`,
  or vice versa, silently drops the value — the engine applies its compiled-in default
  with no warning.

- **`[Developer]` routing.** Developer-only fields live under a top-level `developer`
  JSON key, not adjacent to their sibling fields. The serializer routes them
  automatically via `[Developer]` attribute, but only at one level of nesting — see
  `developer-attribute.md` for the constraint.

- **Tolerance array fallback.** If `tol` is absent or empty, the engine substitutes
  `[10, 10]`; if it has exactly one entry, that entry is duplicated to produce two
  (`Config.cpp:111`). Relying on this silently for MS3 will break once three-entry
  arrays are required.

- **`FAIMSConfig::enabled` is derived.** There is no `enabled` key in the C++ FAIMS
  config. Enabled is true iff `cv_values.size() > 1`. Setting `enabled: true` in the
  method without multiple CV values has no effect.

---
title: Config Flow Packet
applies_to: FlashIDA/src/Flash/MethodParameters.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-04-19
code_anchors:
  - FlashIDA/src/Flash/MethodParameters.cs:92   # MethodParameters.Load entry
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39   # C++ entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config parse
see_also:
  - ../ms1-acquisition/README.md
---

## Overview

Configuration flows through two distinct JSON schemas bridged by the P/Invoke boundary. An operator edits `method.json` in the user-facing schema; FlashIDA reads it into a C# POCO tree via reflection-driven deserialization (treating JSON keys as property names), then serializes into a *different* JSON schema for the C++ engine. The engine parses that JSON once, stores the result in strongly-typed structs, and every subsystem reads those parsed structs for the rest of the run. The user-facing and C++-facing JSON schemas deliberately use different key names — this is intentional and the primary reason why adding a configuration field requires careful coordination between both projects.

## Read Order

- `config-flow.md` — end-to-end data path, stage by stage, with anchors at each handoff.
- `adding-a-config-field.md` — how-to recipes for user-facing fields, developer-only fields, and new MS-level entries.
- `developer-attribute.md` — how `[JsonKey]` and `[Developer]` reflection routing work.

## Entry Points

- `MethodParameters.Load` — `FlashIDA/src/Flash/MethodParameters.cs:92`
- `MethodConfigSerializer.Deserialize` — `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23`
- `MethodParameters.ToCppJson` — `FlashIDA/src/Flash/MethodParameters.cs:100`
- `CreateFLASHIda` (C++) — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39`
- `Config::Config` — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`

## Related Packets

- `../ms1-acquisition/README.md` — MS1 selection, FAIMS cycling, and exploration are consumers that read the parsed configuration via `config_.targeting()`, `config_.faims()`, and `config_.level(n)`.

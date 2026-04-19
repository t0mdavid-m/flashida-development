---
title: [JsonKey] and [Developer] Routing
applies_to: FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
last_verified: 2026-04-19
code_anchors:
  - FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs
  - FlashIDA/src/Flash/IDA/DeveloperAttribute.cs
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:81
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:363
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:449
see_also:
  - config-flow.md
  - adding-a-config-field.md
---

## What It Is

Two C# attributes live under `FlashIDA/src/Flash/IDA/` (not top-level `FlashIDA/src/Flash/`):

- `JsonKeyAttribute` — `FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs`
- `DeveloperAttribute` — `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs`

Both are read by `MethodConfigSerializer` at serialize/deserialize time to route properties between user-facing and developer sections of `method.json`.

## Class-Level vs. Property-Level [JsonKey]

A class-level `[JsonKey("deconvolution")]` names the top-level JSON section the class maps to (e.g., `root["deconvolution"]`). A property-level `[JsonKey("score_threshold")]` names the key inside that section (e.g., `root["deconvolution"]["score_threshold"]`). Both are read by `MethodConfigSerializer.PopulateObject()` during deserialization.

## How [Developer] Routing Works

At serialize time, `Serialize()` (`MethodConfigSerializer.cs:81`) walks each section. For each, `SerializeObject()` (`MethodConfigSerializer.cs:363`) partitions the section's properties into two dictionaries: `mainDict` (unmarked) and `devDict` (marked with `[Developer]`). `Serialize()` then nests `devDict` under `root["developer"][<class-level JsonKey>]`.

At deserialize time, `Deserialize()` (`MethodConfigSerializer.cs:23`) picks each section's main and developer dictionaries from `raw[<section>]` and `raw["developer"][<section>]`, then calls `PopulateObject()` (`MethodConfigSerializer.cs:136`) which pulls each property from whichever dict matches its `[Developer]` attribute.

## Why Bother

User-facing `method.json` stays clean — operators see tuning knobs grouped together. Developer/internal knobs live in a parallel `developer` namespace, using the same POCO structure, with no duplication.

## Top-Level-Only Routing Gotcha

`[Developer]` routing fires **only at the top level** of `MethodConfig`. For nested config classes (e.g., a child config inside `PrecursorSelectionConfig`), developer properties on the child merge back into the parent dict (`MethodConfigSerializer.cs:449-453`) rather than nesting into `developer`. If this matters, mark the property at the top level instead of nesting.

## C++ Side Has No Developer Section

`MethodParameters.ToCppJson()` writes the flat C++-facing schema — all keys in their section, regardless of `[Developer]`. The `developer` partition is a C#-serialization convenience only. Don't look for `developer` in `Config.cpp`; it isn't there.

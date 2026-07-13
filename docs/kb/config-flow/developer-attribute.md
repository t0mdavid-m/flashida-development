---
title: [JsonKey] routing (and the retired [Developer] attribute)
applies_to: FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
last_verified: 2026-07-13
code_anchors:
  - FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:136   # PopulateObject
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson (≈ identity emit)
see_also:
  - config-flow.md
  - adding-a-config-field.md
---

## What It Is

`JsonKeyAttribute` (`FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs`, under `FlashIDA/src/Flash/IDA/`,
not top-level `FlashIDA/src/Flash/`) is read by `MethodConfigSerializer` at deserialize time
to map POCO properties to the (single, bridge-schema) `method.json` keys. Since the
single-schema collapse (ADR-0006), `[JsonKey]` is the **only** routing attribute — the
sibling `[Developer]` attribute is retired (see below).

## Class-Level vs. Property-Level [JsonKey]

A class-level `[JsonKey("deconvolution")]` names the top-level JSON section the class maps to
(e.g., `root["deconvolution"]`). A property-level `[JsonKey("score_threshold")]` names the
key inside that section (e.g., `root["deconvolution"]["score_threshold"]`). Both are read by
`MethodConfigSerializer.PopulateObject()` (`MethodConfigSerializer.cs:136`) during
deserialization. In the single schema, the property-level `[JsonKey]`s name the **bridge**
keys (e.g. `RT_window`, `AllCharges`, `HCDEnergy`), while the POCO property names stay stable
so C# read sites don't churn.

## Retired: [Developer] Routing

Before the single-schema collapse, a `[Developer]`-marked property was routed into a separate
top-level `developer{}` JSON block (nested under `root["developer"][<class-level JsonKey>]`)
so operator-facing knobs and internal knobs stayed visually separated in the user-facing
`method.json`. That user-facing schema no longer exists: there is one flat bridge schema, no
`developer{}` wrapper, and the `[Developer]` attribute is retired. Fields that used to be
developer-routed (`AllCharges`, `HCDEnergy`, `ChargeBasedExclusion`, `cv_precursor_threshold`,
`max_cv_skip`) now sit flat in their sections, keyed by an ordinary property-level `[JsonKey]`.

If you find a lingering `[Developer]`-decorated property while editing, migrate it: drop the
attribute and give the property a `[JsonKey("...")]` naming its flat bridge key (Scenario 1
in `adding-a-config-field.md`).

## C++ Side Never Had a Developer Section

`MethodParameters.ToCppJson()` (`MethodParameters.cs:100`) has always written a flat schema —
all keys in their section, with no `developer` partition. That has not changed; there is no
`developer` block in `Config.cpp` to look for. With the single schema, the emit is now an
≈ identity of what the loader read (same bridge keys), so a flat `method.json` on disk maps
directly to a flat JSON on the wire.

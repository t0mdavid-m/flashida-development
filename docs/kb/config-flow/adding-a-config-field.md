---
title: Adding a Config Field
applies_to: FlashIDA/src/Flash/MethodConfig.cs, FlashIDA/src/Flash/MethodParameters.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-07-13
code_anchors:
  - FlashIDA/src/Flash/MethodConfig.cs:389   # MethodConfig root
  - FlashIDA/src/Flash/MethodConfig.cs:463   # JsonPrecursorSelectionConfig proxy (bridge-emit side)
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson mapping point (≈ identity)
  - FlashIDA/src/Flash/MethodParameters.cs:269   # BuildSelectionStrategy
  - FlashIDA/src/Flash/MethodParameters.cs:346   # ToLogString (sanity log dump)
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:399   # test-mode CLI signature
  - FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs   # [JsonKey] attr
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:93   # MSLevelConfig
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:152   # TargetingConfig
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:45   # default_level_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config parse
  - FlashIDA/test-data/config_schema_reference.json   # drift-guard sentinel fixture
see_also:
  - config-flow.md
  - developer-attribute.md
---

# Adding a Config Field

## One Schema, Two Sides

There is now a single (bridge) schema (ADR-0006), but a field still lives on **two sides**:
the C# side (the section POCO + its `[JsonKey]`, plus the matching property on the
`JsonMethodConfig` emit proxy) and the C++ side (the config struct + the parser). The
on-disk key is the **same** on both sides — no rename. Forget the C++ parser and the C#
side still emits the key but the engine ignores it (defaults silently). Forget the C# emit
proxy and the key never leaves `method.json`. Always touch both halves, then update the
drift-guard fixture so parity tests keep the two sides honest.

---

## Scenario 1 — Field on an Existing Section

Example: add `precursor_selection.new_knob: double = 0.5`.

1. **C# POCO (`FlashIDA/src/Flash/MethodConfig.cs`).** Add a property on the section class
   (e.g., `PrecursorSelectionConfig`) with `[JsonKey("new_knob")]` — use the **bridge** key
   name you want on disk. After adding it, grep for every aggregate or brace initializer of
   that class: `grep -rn "PrecursorSelectionConfig" FlashIDA/src/Flash/`. Update each init
   site to include the new field. Missed init sites compile silently and produce a field
   stuck at its type default rather than the method value.

2. **C# JSON proxy class (`FlashIDA/src/Flash/MethodConfig.cs:463`).**
   Add the matching `new_knob` property (no attribute needed) to `JsonPrecursorSelectionConfig`.

3. **C# re-serialization (`FlashIDA/src/Flash/MethodParameters.cs:100`, `ToCppJson`).** Inside
   the `precursor_selection = new JsonPrecursorSelectionConfig { ... }` block, add
   `new_knob = c.PrecursorSelection.NewKnob`. (Because the emit is ≈ identity, the key name
   matches step 1 exactly.)

4. **C++ struct (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:152`).** Add
   `double new_knob = 0.5;` to `TargetingConfig`.

5. **C++ parser (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`,
   `Config::Config`).** In the `precursor_selection` parse block, add
   `targeting_.new_knob = ps.value("new_knob", 0.5);` alongside the existing `ps.value(...)` calls.

6. **Consumer.** Read via `config_.targeting().new_knob` at the call site. The config object is
   immutable after construction; no setter is needed.

7. **Drift guard.** Add `new_knob` (with a unique sentinel value) to
   `FlashIDA/test-data/config_schema_reference.json`, and add its per-field assertion to the
   C++ `ConfigSchemaParity_test`. The C# `ConfigSchemaParityTests` emit-equality check picks
   up the new key automatically; if you wired only one side, one of the parity tests fails.

8. **Test-mode sanity.** Add the key to a `method.json` test fixture. Run:
   `Flash.exe input_file output_file method.json [ms2_spectrum_file]`
   (signature per `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:399`). Confirm the new field
   appears in the `--- Method Parameters ---` log dump (`ToLogString`,
   `FlashIDA/src/Flash/MethodParameters.cs:346`). Confirm no `CreateFLASHIda error:` on stderr.

---

## Scenario 2 — (Retired) Developer-Only Fields

Developer-only fields **no longer exist.** The single-schema collapse (ADR-0006) removed the
`developer{}` wrapper and retired the `[Developer]` attribute; every field is flat in its
section. Fields that used to be developer-routed (`AllCharges`, `HCDEnergy`,
`ChargeBasedExclusion`, `cv_precursor_threshold`, `max_cv_skip`) are now ordinary
Scenario-1 fields. If you are migrating an old `[Developer]`-decorated property, drop the
attribute and give it a `[JsonKey("...")]` naming the flat bridge key. See
`developer-attribute.md` for the retired mechanism.

---

## Scenario 3 — New MS-Level Entry

Use this when adding a new MS level (e.g., MS4) or a new field on the shared `MSLevelConfig`.

1. **C# POCO (`FlashIDA/src/Flash/MethodConfig.cs`).** Add the new level block or field to
   `SelectionStrategyConfig`. Add the corresponding block or field to the C++-facing proxy
   classes `JsonSelectionStrategyConfig` / `JsonMsLevelConfig`.

2. **C# re-serialization (`FlashIDA/src/Flash/MethodParameters.cs:269`,
   `BuildSelectionStrategy`).** For a new level, add a branch constructing the new level's
   `JsonMsLevelConfig`. Match the defaults and exploration wiring used for the existing `ms1`,
   `ms2`, `ms3` levels. For a new field on an existing level, add the field mapping within the
   corresponding level's construction block.

3. **C++ struct (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:93`).** Add
   the field to `MSLevelConfig`. Update `default_level_`
   (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:45`) to include the new
   field at its default value. Missed `default_level_` updates cause the field to default to
   zero-initialization rather than the intended default.

4. **C++ parser (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`).** For a
   new MS level, add an `ms_settings.ms4` parse block alongside the existing `ms1`, `ms2`,
   `ms3` blocks. For a new field on an existing level, add `.value("new_field", default)`
   within each level's parse block.

5. **Consumers.** Grep `config_.levels()` and `config_.level(` to enumerate every call site
   that iterates MS levels or indexes a specific level. Each site that needs to act on the new
   field (or the new level) must be extended.

6. **Drift guard + test-mode sanity.** Add the new level/field sentinel to
   `config_schema_reference.json` and its C++ parity assertion (as in Scenario 1, step 7),
   then run the Flash test-mode CLI as in Scenario 1, step 8.

---

## Test It in Isolation

Run the Flash test-mode CLI against a recorded `.mzML` before integrating:
`Flash.exe input_file output_file method.json [ms2_spectrum_file]`

No instrument connection is required. Check:

- The new field appears in the `--- Method Parameters ---` log dump.
- No `CreateFLASHIda error:` on stderr.
- The field value matches what is written in `method.json` (not silently defaulted).
- The `ConfigSchemaParity` tests (C# + C++) pass — proof both sides read/emit the new key.

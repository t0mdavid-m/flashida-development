---
title: Adding a Config Field
applies_to: FlashIDA/src/Flash/MethodConfig.cs, FlashIDA/src/Flash/MethodParameters.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
last_verified: 2026-04-19
code_anchors:
  - FlashIDA/src/Flash/MethodConfig.cs:344   # MethodConfig root
  - FlashIDA/src/Flash/MethodParameters.cs:100   # ToCppJson mapping point
  - FlashIDA/src/Flash/MethodParameters.cs:266   # BuildSelectionStrategy
  - FlashIDA/src/Flash/MethodParameters.cs:346   # ToLogString (sanity log dump)
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:399   # test-mode CLI signature
  - FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs   # [JsonKey] attr
  - FlashIDA/src/Flash/IDA/DeveloperAttribute.cs   # [Developer] attr
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:93   # MSLevelConfig
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:143   # TargetingConfig
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:45   # default_level_
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84   # Config::Config parse
see_also:
  - config-flow.md
  - developer-attribute.md
---

# Adding a Config Field

## Schema-Mismatch Warning

A field only exists where you wire it. Forget the C++ parser and the C# side silently produces
JSON that the engine ignores — the field is absent from all C++ config structs, no error is
raised at runtime, the engine just runs with its default. Forget the C# re-serializer and the
field is present in `method.json` but never forwarded to the engine. Always touch both halves:
the C# POCO and re-serializer, and the C++ struct and parser.

---

## Scenario 1 — User-Facing Field on an Existing Section

Example: add `precursor_selection.new_knob: double = 0.5`.

1. **C# POCO (`FlashIDA/src/Flash/MethodConfig.cs`).** Add a property on the section class
   (e.g., `PrecursorSelectionConfig`) with `[JsonKey("new_knob")]`. After adding it, grep for
   every aggregate or brace initializer of that class: `grep -rn "PrecursorSelectionConfig"
   FlashIDA/src/Flash/`. Update each init site to include the new field. Missed init sites
   compile silently and produce a field stuck at its type default rather than the method value.

2. **C# JSON proxy class (`FlashIDA/src/Flash/MethodConfig.cs:412`).**
   Add the matching `new_knob` property (no attribute needed) to `JsonPrecursorSelectionConfig`.

3. **C# re-serialization (`FlashIDA/src/Flash/MethodParameters.cs:100`, `ToCppJson`).** Inside
   the `precursor_selection = new JsonPrecursorSelectionConfig { ... }` block (starts at
   `MethodParameters.cs:126`), add `new_knob = c.PrecursorSelection.NewKnob`.

4. **C++ struct (`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:143`).** Add
   `double new_knob = 0.5;` to `TargetingConfig`.

5. **C++ parser (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`,
   `Config::Config`).** In the `precursor_selection` parse block, add
   `targeting_.new_knob = ps.value("new_knob", 0.5);` alongside the existing `ps.value(...)` calls.

6. **Consumer.** Read via `config_.targeting().new_knob` at the call site. The config object is
   immutable after construction; no setter is needed.

7. **Test-mode sanity.** Add the key to a `method.json` test fixture. Run:
   `Flash.exe input_file output_file method.json [ms2_spectrum_file]`
   (signature per `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:399`). Confirm the new field
   appears in the `--- Method Parameters ---` log dump (`ToLogString`,
   `FlashIDA/src/Flash/MethodParameters.cs:346`) — extend `ToLogString` to print it if you
   want explicit verification. Confirm no `CreateFLASHIda error:` on stderr.

---

## Scenario 2 — Developer-Only Field

Same as Scenario 1 with these differences:

- **Step 1 addition:** decorate the property on the section class with `[Developer]`. The
  attribute is defined at `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs` — note the `IDA/`
  subfolder; it is *not* at the top-level `FlashIDA/src/Flash/` directory.

- **Step 1 side-effect:** the field lands in `method.json` under
  `developer.<section_key>.new_knob` rather than `<section_key>.new_knob`. The
  `MethodConfigSerializer.Serialize` / `Deserialize` methods route it automatically, using
  the class-level `[JsonKey]` on `PrecursorSelectionConfig`.

- **Step 2 (unchanged):** `JsonPrecursorSelectionConfig` still needs the matching property.
  `[Developer]` routes the C#-facing JSON only; the C++-facing schema produced by `ToCppJson`
  is flat regardless.

- **Step 3 unchanged — most common foot-gun:** `ToCppJson` still writes the field into the
  flat, C++-facing JSON schema exactly as in Scenario 1. There is no `developer` top-level
  section on the C++ side. The `developer` partition is a C#-side routing convenience only.
  Engineers who expect a mirrored `developer` block in the C++ JSON parser will wire it
  wrong and never see an error — the field silently defaults.

- Steps 4–7 are identical to Scenario 1.

- See `developer-attribute.md` for the full serialization mechanics.

---

## Scenario 3 — New MS-Level Entry

Use this when adding a new MS level (e.g., MS4) or a new field on the shared `MSLevelConfig`.

1. **C# POCO (`FlashIDA/src/Flash/MethodConfig.cs`).** Add the new level block or field to
   `SelectionStrategyConfig`. Add the corresponding block or field to the C++-facing proxy
   classes `JsonSelectionStrategyConfig` (MethodConfig.cs:541) / `JsonMsLevelConfig` (MethodConfig.cs:533).

2. **C# re-serialization (`FlashIDA/src/Flash/MethodParameters.cs:266`,
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

6. **Test-mode sanity.** Same as Scenario 1, Step 7. Run the Flash test-mode CLI against a
   recorded `.mzML`; no instrument is needed (see `FlashIDA/CLAUDE.md`). Watch for the
   `--- Method Parameters ---` log dump with the new field populated, and no
   `CreateFLASHIda error:` on stderr.

---

## Test It in Isolation

Run the Flash test-mode CLI against a recorded `.mzML` before integrating:
`Flash.exe input_file output_file method.json [ms2_spectrum_file]`

No instrument connection is required. Check:

- The new field appears in the `--- Method Parameters ---` log dump.
- No `CreateFLASHIda error:` on stderr.
- The field value matches what is written in `method.json` (not silently defaulted).

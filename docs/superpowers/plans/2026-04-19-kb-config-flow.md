# KB Packet — Config Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `docs/kb/config-flow/` packet with 4 markdown files that document the config pipeline from `method.json` through the C# POCO layer, re-serialization, the P/Invoke bridge, and the C++ `Config` parser. Add a one-line entry to `docs/kb/index.md`. Fix the stale XML-era paragraphs in `FlashIDA/CLAUDE.md`.

**Architecture:** All documentation — four new markdown files, one index edit, targeted CLAUDE.md edits. Follows the conventions of the existing `ms1-acquisition/` packet: YAML frontmatter with `last_verified` + `code_anchors`, paths relative to the parent-repo root, pointers over paste, ≤250 lines per file.

**Tech Stack:** Markdown + YAML frontmatter. No build/test tooling; verification is anchor resolution via `sed`/`grep`.

**Linked spec:** `docs/superpowers/specs/2026-04-19-kb-config-flow-design.md`

---

## File structure

**Create:**
- `docs/kb/config-flow/README.md` — packet landing page
- `docs/kb/config-flow/config-flow.md` — end-to-end data path
- `docs/kb/config-flow/adding-a-config-field.md` — how-to recipes
- `docs/kb/config-flow/developer-attribute.md` — reflection routing reference

**Modify:**
- `docs/kb/index.md` — append one line under `## Packets`
- `FlashIDA/CLAUDE.md` — targeted edits per caveat-1 fix
- `docs/superpowers/specs/2026-04-19-kb-config-flow-design.md` — flip `status: approved` → `status: implemented` after everything else lands (Stop hook archives at session end)

**Parallelizable:** Tasks 2, 3, 4 (three deep-dive docs) are independent of each other and of Task 1 once the packet directory exists. Tasks 5 and 6 are independent of each other and of 2–4. Task 7 depends on 1–6 completing.

---

### Task 1: Packet scaffold + README.md

**Files:**
- Create: `docs/kb/config-flow/` (directory, via mkdir)
- Create: `docs/kb/config-flow/README.md`

- [ ] **Step 1: Create the packet directory**

```bash
mkdir -p docs/kb/config-flow
```

- [ ] **Step 2: Verify the entry-point anchors resolve**

```bash
sed -n '92p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '23p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '100p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '39p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
sed -n '84p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
```

Expected output:
- `MethodParameters.cs:92` → `        public static MethodParameters Load(string path)`
- `MethodConfigSerializer.cs:23` → `        public static MethodConfig Deserialize(string json)`
- `MethodParameters.cs:100` → `        public string ToCppJson()`
- `FLASHIdaBridgeFunctions.cpp:39` → `  FLASHIda *CreateFLASHIda(char *arg)`
- `Config.cpp:84` → `  Config::Config(const std::string& json_str)`

If any line diverges, re-grep for the symbol (`grep -n "public static MethodParameters Load" FlashIDA/src/Flash/MethodParameters.cs`) and update the anchor before proceeding.

- [ ] **Step 3: Write `docs/kb/config-flow/README.md`**

Frontmatter:

```yaml
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
```

Body sections (≤60 lines total):

1. **Overview** — one paragraph. Frame the two-schema pipeline: operator edits `method.json`; FlashIDA reads it into a C# POCO tree via reflection-driven deserialization, then re-serializes into a *different* JSON schema for the C++ engine; the engine parses that once and every subsystem reads the parsed structs for the rest of the run. State explicitly that the user-facing JSON and the C++-facing JSON use different key names — this is deliberate and is the main reason adding a knob needs careful handling.

2. **Read order** — bullet list, one sentence per file:
   - `config-flow.md` — end-to-end data path, stage by stage, with anchors at each handoff.
   - `adding-a-config-field.md` — how-to recipes for user-facing fields, developer-only fields, and new MS-level entries.
   - `developer-attribute.md` — how `[JsonKey]` and `[Developer]` reflection routing work.

3. **Entry points** — bullet list with `file:line`:
   - `MethodParameters.Load` — `FlashIDA/src/Flash/MethodParameters.cs:92`
   - `MethodConfigSerializer.Deserialize` — `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23`
   - `MethodParameters.ToCppJson` — `FlashIDA/src/Flash/MethodParameters.cs:100`
   - `CreateFLASHIda` (C++) — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39`
   - `Config::Config` — `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`

4. **Related packets** — one bullet linking `../ms1-acquisition/README.md` with a one-sentence note that MS1 selection/FAIMS/exploration are consumers that read via `config_.targeting()`, `config_.faims()`, `config_.level(n)`.

**Body style:** WHY/WHERE over WHAT (the code is the source of truth for what). No pasted code blocks. Paths relative to parent-repo root.

- [ ] **Step 4: Verify length and frontmatter**

```bash
wc -l docs/kb/config-flow/README.md
head -15 docs/kb/config-flow/README.md
```

Expected: `wc` reports ≤ 60 lines. `head` shows the frontmatter starting with `---` and ending with `---`.

- [ ] **Step 5: Commit**

```bash
git add docs/kb/config-flow/README.md
git commit -m "docs(kb/config-flow): add packet README"
```

---

### Task 2: `config-flow.md` — the end-to-end data path

**Files:**
- Create: `docs/kb/config-flow/config-flow.md`

- [ ] **Step 1: Verify every anchor the doc will use**

```bash
sed -n '92p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '23p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '136p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '176p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '315p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '100p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '266p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '344p' FlashIDA/src/Flash/MethodConfig.cs
sed -n '569p' FlashIDA/src/Flash/MethodConfig.cs
sed -n '100p' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
sed -n '130p' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
sed -n '135p' FlashIDA/src/Flash/Flash.cs
sed -n '39p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
sed -n '62p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
sed -n '84p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
sed -n '111p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
sed -n '172p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
```

Expected: each line prints a non-empty, semantically-sensible line. The critical symbols to see (possibly on the line itself or immediately following, since attributes precede declarations): `public static MethodParameters Load`, `PopulateObject`, `ConvertValue`, `PopulateStruct`, `ToCppJson()`, `BuildSelectionStrategy()`, `public class MethodConfig`, `public class JsonMethodConfig`, `[DllImport(dllName)]` for `FLASHIdaWrapper.cs:100` (the P/Invoke attribute — `CreateFLASHIda` decl is line 101), `FLASHIdaWrapper(MethodParameters mp)` for `:130`, `Path.Combine(selfLocation, "method.json")` for `Flash.cs:135`, `FLASHIda *CreateFLASHIda` at `FLASHIdaBridgeFunctions.cpp:39`, `FLASHIda::FLASHIda(char* arg)` at `FLASHIda.cpp:62`, `Config::Config(const std::string& json_str)` at `Config.cpp:84`, `if (tol_values.empty())` at `:111`, `static const std::vector<std::string> legacy_ms3_keys` at `:172`.

If any anchor diverges, grep for the symbol and update the line number before writing the body.

- [ ] **Step 2: Write `docs/kb/config-flow/config-flow.md`**

Frontmatter:

```yaml
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
see_also:
  - adding-a-config-field.md
  - developer-attribute.md
---
```

Body sections (≤200 lines total). Each section one paragraph of prose pointing at code; **no** pasted code blocks longer than one line.

1. **Overview** — one paragraph restating the two-schema pipeline, one sentence each on the five hand-offs.

2. **Stage 1 — Disk load.** `MethodParameters.Load(path)` (`FlashIDA/src/Flash/MethodParameters.cs:92`) reads the file and delegates to `MethodConfigSerializer.Deserialize(json)` (`FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23`). Note the Flash CLI default: `method.json` in the program folder (`FlashIDA/src/Flash/Flash.cs:135`).

3. **Stage 2 — C# POCO tree.** Hierarchy rooted at `MethodConfig` (`FlashIDA/src/Flash/MethodConfig.cs:344`). Sections: `Global`, `Deconvolution`, `PrecursorSelection`, `Tagging`, `Quantification`, `Faims`, `MsSettings`, `Scheduling`, `SelectionStrategy`, `Ms3`, `Files`, `Runtime`. Each section class carries a class-level `[JsonKey("...")]` attribute naming the top-level JSON section. Each property carries its own `[JsonKey("...")]` and may carry `[Developer]` to route it to/from the `developer` sub-object. Details of the attribute system live in `developer-attribute.md`.

4. **Stage 3 — Reflection-based deserialization.** `MethodConfigSerializer.PopulateObject` (`MethodConfigSerializer.cs:136`) walks properties, reads `[JsonKey]` and `[Developer]`, pulls from `mainDict` or `devDict`. `ConvertValue` (`MethodConfigSerializer.cs:176`) handles primitives, `double[]`, `List<string>`, `List<MS2Parameters>`, value-type structs (field-based via `PopulateStruct`, `MethodConfigSerializer.cs:315`), and nested config classes.

5. **Stage 4 — Re-serialization for C++.** `MethodParameters.ToCppJson()` (`MethodParameters.cs:100`) builds a **second, different** schema (`JsonMethodConfig` et al., defined at `MethodConfig.cs:569`) with snake_case keys. Key transformations to call out: `TargetingMode` string → `target_mode` integer via a 4-branch switch (`none|inclusion|exclusion|deep` → `0|1|2|3`); `SelectionStrategy.{MS1,MS2,MS3}.Selection` normalized to lowercase in `BuildSelectionStrategy` (`MethodParameters.cs:266`); `MS2`/`MS3` lists flattened to arrays; nullable `FollowUpScan` becomes object-or-null.

6. **Stage 5 — P/Invoke bridge.** `FLASHIdaWrapper(MethodParameters mp)` (`FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:130`) calls `CreateFLASHIda(mp.ToCppJson())`. Bridge declaration at `FLASHIdaWrapper.cs:100`. A null return throws `InvalidOperationException` — the C++ side prints the error to stderr first.

7. **Stage 6 — C++ entry.** `CreateFLASHIda(char*)` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39`) constructs `new FLASHIda(arg)`; the ctor at `FLASHIda.cpp:62` member-initializes `config_(std::string(arg))` before any subsystem.

8. **Stage 7 — C++ parsing.** `Config::Config(const std::string&)` at `Config.cpp:84`. First guard: input must start with `{`, else `std::invalid_argument`. Parses with `nlohmann/json`. Fills `DeconvolutionConfig`, `TargetingConfig`, `FAIMSConfig`, `SchedulingConfig`, `QuantConfig`, `RuntimeConfig`, and `std::map<int, MSLevelConfig> levels_`. Defaults applied per-field via `.value(key, default)` so missing keys don't throw.

9. **Stage 8 — Legacy-key rejection.** `ms3.{enabled,active,mode,all_charges,max_per_ms2}` throw with a migration message (`Config.cpp:172`). Agents editing a pre-migration method will see `CreateFLASHIda error: Config: ms3.<key> is no longer supported...` on stderr.

10. **Stage 9 — Validation.** `Config::validate()` runs consistency checks (selection metric vs. `min_charge`, exploration sanity). Called after construction; throws `std::invalid_argument` on conflict.

11. **Stage 10 — Consumer wiring.** Every subsystem takes `config_` by const-reference in its ctor: `deconv_(config_, ...)`, `selection_(config_, deconv_)`, `faims_(config_)`, `exploration_(config_, fragments_)` (`FLASHIda.cpp:62-70`). Stable read paths: `config_.targeting().hcd_energy`, `config_.level(2).selection`, `config_.faims().cv_values`.

12. **Gotchas** — short bulleted list at the end:
    - **Two schemas.** User-facing JSON (what you edit) and C++-facing JSON (what the engine parses) have *different key names*. Changing one without the other silently drops the value.
    - **`[Developer]` routing.** Developer-only fields live under a top-level `developer` section, not alongside their siblings. Routed automatically by the serializer — but only at the top level (see `developer-attribute.md`).
    - **Tolerance array fallback.** Empty `tol` → `[10, 10]`; single-element → duplicated to 2 entries (`Config.cpp:111`).
    - **`FAIMSConfig::enabled` is derived.** Not a config key. True iff `cv_values.size() > 1`.

**Body style:** pointers over paste. Brief inline mentions of `file:line` are fine; multi-line code excerpts are not.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/config-flow/config-flow.md
head -25 docs/kb/config-flow/config-flow.md
```

Expected: `wc` reports ≤ 200 lines. Frontmatter block opens and closes with `---`. No pasted multi-line code blocks (search with `grep -n '^```' docs/kb/config-flow/config-flow.md` — each opening fence should have a matching close, and the total count should be 0 or only short inline examples; if any block exceeds 2 lines, trim it to a pointer).

- [ ] **Step 4: Commit**

```bash
git add docs/kb/config-flow/config-flow.md
git commit -m "docs(kb/config-flow): document end-to-end config pipeline"
```

---

### Task 3: `adding-a-config-field.md` — how-to recipes

**Files:**
- Create: `docs/kb/config-flow/adding-a-config-field.md`

- [ ] **Step 1: Verify anchors the how-to will reference**

```bash
sed -n '92p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '100p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '126p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '266p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '346p' FlashIDA/src/Flash/MethodParameters.cs
sed -n '344p' FlashIDA/src/Flash/MethodConfig.cs
ls FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs
ls FlashIDA/src/Flash/IDA/DeveloperAttribute.cs
sed -n '93p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
sed -n '143p' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
sed -n '45p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
sed -n '84p' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
sed -n '399p' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
```

Expected: each `sed` prints a semantically-correct line (`Load`, `ToCppJson`, `precursor_selection =`, `BuildSelectionStrategy`, `ToLogString` or the `--- Method Parameters ---` format string near it, `public class MethodConfig`, `struct OPENMS_DLLAPI MSLevelConfig`, `struct OPENMS_DLLAPI TargetingConfig`, `const MSLevelConfig Config::default_level_`, `Config::Config`, `"Usage: input_file output_file method.json [ms2_spectrum_file]"` or similar). Both `ls` lines print the file path (attributes exist under `IDA/`).

- [ ] **Step 2: Write `docs/kb/config-flow/adding-a-config-field.md`**

Frontmatter:

```yaml
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
```

Body sections (≤200 lines total):

1. **Schema-mismatch warning** — one paragraph at the top: a field only exists where you wire it. Forget the C++ parser and the C# side silently produces JSON the engine ignores (no error at runtime; it's just missing from the config structs). Forget the C# re-serializer and the field is in `method.json` but never reaches the engine. Always touch both halves.

2. **Scenario 1 — user-facing field on an existing section.** Example header: "Add `precursor_selection.new_knob: double = 0.5`." Then an ordered checklist, each item naming the file and what to add:

   1. **C# POCO (`MethodConfig.cs`).** Add a property on the section class (e.g., `PrecursorSelectionConfig`) with `[JsonKey("new_knob")]`. If the section class uses an aggregate initializer anywhere, grep for it (`grep -n "PrecursorSelectionConfig" FlashIDA/src/Flash/`) and update each init site. *Gotcha: missed init sites cause compile errors or silently-default values.*

   2. **C# re-serialization (`MethodParameters.ToCppJson`, `MethodParameters.cs:100`).** Add a `new_knob = c.PrecursorSelection.NewKnob` line inside the `precursor_selection = new JsonPrecursorSelectionConfig { ... }` block (starts at `MethodParameters.cs:126`). The `JsonPrecursorSelectionConfig` class lives near `MethodConfig.cs:569`; add the matching `new_knob` property there too.

   3. **C++ struct (`Config.h`).** Add `double new_knob = 0.5;` to `TargetingConfig` (`Config.h:143`).

   4. **C++ parser (`Config.cpp`).** In the `--- precursor_selection section ---` block (starts at `Config.cpp:119`), add `targeting_.new_knob = ps.value("new_knob", 0.5);` alongside the existing `ps.value(...)` calls.

   5. **Consumer.** Read via `config_.targeting().new_knob` wherever the value is needed. The config is immutable after construction; no setter needed.

   6. **Test-mode sanity.** Run the Flash test-mode CLI with an updated `method.json` containing the new key. Signature per `FLASHIdaWrapper.cs:399` is `Flash.exe input_file output_file method.json [ms2_spectrum_file]`. Confirm the new field appears in the `--- Method Parameters ---` log dump (`ToLogString`, `MethodParameters.cs:346`) — extend `ToLogString` to print it if you want verification there. Confirm no `CreateFLASHIda error:` on stderr.

3. **Scenario 2 — developer-only field.** Same as Scenario 1 but:

   - **Step 1 addition**: decorate the property with `[Developer]`. The attribute is defined at `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs` — note the `IDA/` subfolder; it is *not* at top-level `FlashIDA/src/Flash/`.
   - **Step 1 side-effect**: the field lands in `method.json` under `developer.<section_key>.new_knob` rather than `<section_key>.new_knob`. `MethodConfigSerializer.Serialize` and `Deserialize` route it automatically, using the class-level `[JsonKey]` on `PrecursorSelectionConfig`.
   - **Step 2 unchanged**: `ToCppJson` still writes the field into the flat C++-facing schema — the `developer` partition is a C#-side convenience only. On the C++ side, the key sits in the normal section block. **This is the most common foot-gun**: agents expect a top-level `developer` section on the C++ side too. There isn't one.
   - Steps 3–6 unchanged.
   - Reference `developer-attribute.md` for the full mechanics.

4. **Scenario 3 — new MS-level entry.** Adding an MS4 level, or adding a new field on `MSLevelConfig`.

   1. **C# POCO.** Add the block or field in `SelectionStrategyConfig` within `MethodConfig.cs`, and the corresponding block in the C++-facing `JsonSelectionStrategyConfig` / `JsonMsLevelConfig` classes (near `MethodConfig.cs:569`).

   2. **C# re-serialization (`BuildSelectionStrategy`, `MethodParameters.cs:266`).** Add a branch constructing the new level's `JsonMsLevelConfig`. Match the defaults and exploration wiring used for existing levels.

   3. **C++ struct (`Config.h`).** Add the field on `MSLevelConfig` (`Config.h:93`). Update `default_level_` (`Config.cpp:45`) to include the new field.

   4. **C++ parser (`Config.cpp`).** For a new MS-level, add an `ms_settings.ms4` block alongside the existing `ms1`, `ms2`, `ms3` blocks. For a new field on an existing level, add `.value("new_field", default)` within each level's block.

   5. **Consumers.** Anyone iterating `config_.levels()` or calling `config_.level(n)` for the new level needs the new field. Grep `config_.levels()` and `config_.level(` to enumerate call sites.

5. **Test it in isolation** — run the Flash test-mode CLI against a recorded `.mzML`; no instrument needed per `FlashIDA/CLAUDE.md`. Watch for the `--- Method Parameters ---` log dump with the new field populated, and no `CreateFLASHIda error:` on stderr.

**Body style:** ordered lists, file paths + line numbers, no pasted source-code excerpts.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/config-flow/adding-a-config-field.md
head -20 docs/kb/config-flow/adding-a-config-field.md
```

Expected: `wc` reports ≤ 200 lines. Frontmatter block present.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/config-flow/adding-a-config-field.md
git commit -m "docs(kb/config-flow): add how-to for adding a config field"
```

---

### Task 4: `developer-attribute.md` — reflection routing reference

**Files:**
- Create: `docs/kb/config-flow/developer-attribute.md`

- [ ] **Step 1: Verify anchors**

```bash
wc -l FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs
wc -l FlashIDA/src/Flash/IDA/DeveloperAttribute.cs
sed -n '23p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '363p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
sed -n '449,453p' FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
```

Expected: both `wc` calls print a small line count (both attributes are short files). `sed 23` shows `public static MethodConfig Deserialize(string json)`; `sed 363` shows `private static void SerializeObject(...)`; the 449–453 range shows the nested-merge comment and loop that merges `devDummy` into `dict`.

- [ ] **Step 2: Write `docs/kb/config-flow/developer-attribute.md`**

Frontmatter:

```yaml
---
title: [JsonKey] and [Developer] Routing
applies_to: FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs
last_verified: 2026-04-19
code_anchors:
  - FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs   # [JsonKey] attr
  - FlashIDA/src/Flash/IDA/DeveloperAttribute.cs   # [Developer] attr
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23   # Deserialize
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:363   # SerializeObject
  - FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:449   # nested dev-merge
see_also:
  - config-flow.md
  - adding-a-config-field.md
---
```

Body sections (≤80 lines total):

1. **What it is.** Two C# attributes:
   - `JsonKeyAttribute` — `FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs`
   - `DeveloperAttribute` — `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs`

   Both live under `IDA/`, alongside the serializer that reads them. **Not** at top-level `FlashIDA/src/Flash/`. This is easy to miss when searching for "JsonKey".

2. **Class-level vs. property-level `[JsonKey]`.** A class-level `[JsonKey("deconvolution")]` names the top-level JSON section the class maps to. A property-level `[JsonKey("score_threshold")]` names the key inside that section. Both are read by `MethodConfigSerializer`.

3. **How `[Developer]` routing works.** At serialize time, `MethodConfigSerializer.SerializeObject` (`MethodConfigSerializer.cs:363`) partitions a class's properties into two dictionaries: `mainDict` (normal) and `devDict` (marked `[Developer]`). `devDict` is nested under `root["developer"][<class-level JsonKey>]`. At deserialize time, `MethodConfigSerializer.Deserialize` (`MethodConfigSerializer.cs:23`) pulls each property from either `raw[<section>]` or `raw["developer"][<section>]` depending on `[Developer]`.

4. **Why bother.** User-facing `method.json` stays concise — operators see tuning knobs grouped together. Developer/internal knobs live in a parallel `developer` namespace, same POCO tree, no duplication.

5. **Top-level-only routing gotcha.** `[Developer]` routing only fires at the **top level** of `MethodConfig`. For nested config classes (e.g., if `PrecursorSelectionConfig` contained a child config class of its own), developer properties on the child merge back into the parent dict rather than nesting into `developer` (`MethodConfigSerializer.cs:449-453`). If this matters for a new field, mark it at the top level instead of nesting the owning class.

6. **C++ side has no `developer` section.** `MethodParameters.ToCppJson()` writes the flat C++-facing schema — all keys in their section, regardless of `[Developer]`. The `developer` partition is a C#-serialization convenience only. Don't look for `developer` in `Config.cpp` — it isn't there.

**Body style:** short; pointers over paste.

- [ ] **Step 3: Verify length and frontmatter**

```bash
wc -l docs/kb/config-flow/developer-attribute.md
head -18 docs/kb/config-flow/developer-attribute.md
```

Expected: `wc` reports ≤ 80 lines. Frontmatter present.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/config-flow/developer-attribute.md
git commit -m "docs(kb/config-flow): document [JsonKey]/[Developer] reflection routing"
```

---

### Task 5: Register the new packet in `docs/kb/index.md`

**Files:**
- Modify: `docs/kb/index.md`

- [ ] **Step 1: Read current index**

```bash
cat docs/kb/index.md
```

Expected content includes the existing `## Packets` section with the MS1 entry:

```
## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.
```

- [ ] **Step 2: Append the new packet entry**

Use the `Edit` tool to modify `docs/kb/index.md`. Change the `## Packets` block from:

```markdown
## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.
```

to:

```markdown
## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, exploration, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
```

- [ ] **Step 3: Verify length and content**

```bash
wc -l docs/kb/index.md
grep -c "config-flow/README.md" docs/kb/index.md
```

Expected: `wc` reports ≤ 80 lines. `grep -c` returns `1` (exactly one entry for the new packet).

- [ ] **Step 4: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): register config-flow packet in index"
```

---

### Task 6: Fix `FlashIDA/CLAUDE.md` — replace stale XML-era text

**Files:**
- Modify: `FlashIDA/CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md**

```bash
cat FlashIDA/CLAUDE.md
```

Expected: contains the four stale passages that will be edited (line numbers approximate; match by content):

- Line 39 — `**Flash.cs** — ... loads XML method config, ...`
- Line 49 — `**IDA/Parameter.cs** — Serializes method XML config to JSON ...`
- Line 55 — `**MethodParameters.cs** / **MethodConfig.cs** — Loads and structures the XML method file. Hierarchical config: ...`
- Line 61 — `Configured via \`TargetingMode\` in the method XML: None ...`
- Line 75 — `XML-based (\`src/Flash/etc/method.xml\`). Sections: ...`

- [ ] **Step 2: Edit 1 — fix `Flash.cs` bullet (XML → JSON)**

Use the `Edit` tool. Replace:

```
- **Flash.cs** — Entry point. Connects to instrument via Thermo Fusion API, manages instrument state, loads XML method config, creates the scan processor, and runs the main acquisition loop.
```

with:

```
- **Flash.cs** — Entry point. Connects to instrument via Thermo Fusion API, manages instrument state, loads JSON method config (`method.json`), creates the scan processor, and runs the main acquisition loop.
```

- [ ] **Step 3: Edit 2 — remove `Parameter.cs` bullet (file no longer exists)**

Use the `Edit` tool. Replace:

```
- **IDA/Parameter.cs** — Serializes method XML config to JSON for the C++ engine via `ToJSON()`, including `<SelectionStrategy>` serialization.

- **DataPipe.cs** — Three-stage TPL Dataflow async pipeline (buffer → process → output) for concurrent scan processing.
```

with:

```
- **DataPipe.cs** — Three-stage TPL Dataflow async pipeline (buffer → process → output) for concurrent scan processing.
```

(The replacement collapses the `Parameter.cs` bullet and the trailing blank line into nothing.)

- [ ] **Step 4: Edit 3 — rewrite `MethodParameters.cs / MethodConfig.cs` bullet**

Use the `Edit` tool. Replace:

```
- **MethodParameters.cs** / **MethodConfig.cs** — Loads and structures the XML method file. Hierarchical config: GlobalParameters, PrecursorSelection, AcquisitionModes (targeting, quantification, MS3), MSSettings (MS1/MS2/MS3 parameters, FAIMS CVs).
```

with:

```
- **MethodParameters.cs** / **MethodConfig.cs** / **IDA/MethodConfigSerializer.cs** — Load and structure the JSON method file (`method.json`). Reflection-driven via `[JsonKey]` + `[Developer]` attributes. Sections: `global`, `deconvolution`, `precursor_selection`, `tagging`, `quantification`, `faims`, `ms_settings`, `scheduling`, `selection_strategy`, `ms3`, `files`, `runtime`. See `docs/kb/config-flow/` for the end-to-end flow.
```

- [ ] **Step 5: Edit 4 — fix Acquisition Modes intro**

Use the `Edit` tool. Replace:

```
Configured via `TargetingMode` in the method XML: None (standard DDA), Inclusion, Exclusion, Deep. Additional modes: MS2 Tagging (protein-family detection), Conditional MS2 (tag-based method routing), Isobaric Quantification, MS3 Characterization (3 sub-modes).
```

with:

```
Configured via `precursor_selection.targeting_mode` in `method.json`: None (standard DDA), Inclusion, Exclusion, Deep. Additional modes: MS2 Tagging (protein-family detection), Conditional MS2 (tag-based method routing), Isobaric Quantification, MS3 Characterization (3 sub-modes).
```

- [ ] **Step 6: Edit 5 — replace Method Configuration paragraph**

Use the `Edit` tool. Replace:

```
XML-based (`src/Flash/etc/method.xml`). Sections: GlobalParameters, PrecursorSelection, AcquisitionModes, MSSettings (MS1/MS2/MS3Parameters, FAIMSParameters).
```

with:

```
JSON-based (`src/Flash/etc/method.json`). See `docs/kb/config-flow/` for the end-to-end flow from `method.json` to the C++ engine's `Config` structs.
```

- [ ] **Step 7: Verify the stale strings are gone**

```bash
grep -n "method.xml\|method XML\|Parameter.cs\|<SelectionStrategy>\|XML-based\|XML method" FlashIDA/CLAUDE.md
```

Expected: **no output** (the grep finds nothing). If any match is left, re-do the corresponding Edit.

- [ ] **Step 8: Verify the file still parses as valid Markdown**

```bash
head -80 FlashIDA/CLAUDE.md | tail -60
```

Expected: no broken headings, no orphaned blank lines clustered 3+ deep, the bulleted list under `### Key Components` reads cleanly with the new wording.

- [ ] **Step 9: Commit**

```bash
git add FlashIDA/CLAUDE.md
git commit -m "docs(FlashIDA): replace stale XML-era config notes with JSON + KB pointer"
```

---

### Task 7: Final verification + spec status flip

**Files:**
- Modify: `docs/superpowers/specs/2026-04-19-kb-config-flow-design.md` (flip `status: approved` → `status: implemented`)

- [ ] **Step 1: Verify every packet file exists and has frontmatter**

```bash
ls docs/kb/config-flow/
for f in docs/kb/config-flow/*.md; do
  echo "=== $f ==="
  head -1 "$f"
done
```

Expected: four files (`README.md`, `config-flow.md`, `adding-a-config-field.md`, `developer-attribute.md`); each starts with `---` (YAML frontmatter open).

- [ ] **Step 2: Verify index points to the new packet**

```bash
grep "config-flow/README.md" docs/kb/index.md
```

Expected: exactly one line matching.

- [ ] **Step 3: Verify stale CLAUDE.md strings are purged**

```bash
grep -n "method.xml\|method XML\|Parameter.cs\|<SelectionStrategy>\|XML-based\|XML method" FlashIDA/CLAUDE.md
```

Expected: no output.

- [ ] **Step 4: Resolve every `code_anchor` declared in the new files**

For each line of the form `  - <path>:<line>   # <comment>` or `  - <path>   # <comment>` in the frontmatter of any file under `docs/kb/config-flow/`, verify the file exists and (if a `:line` is given) the line prints non-empty:

```bash
for f in docs/kb/config-flow/*.md; do
  echo "=== $f ==="
  awk '/^code_anchors:/{flag=1; next} /^see_also:|^---/{flag=0} flag{print $2}' "$f"
done
```

For each anchor printed, verify:
- If the anchor has the form `<path>:<line>` — run `sed -n '<line>p' <path>` and confirm non-empty output.
- If the anchor is a bare `<path>` (no line number) — run `ls <path>` and confirm the file exists.

None should produce empty output or "No such file".

If any anchor fails, read the source file to find the current line number for the symbol, update the frontmatter, and re-commit the fix on top before proceeding.

- [ ] **Step 5: Verify no multi-line pasted code blocks in deep-dive docs**

```bash
for f in docs/kb/config-flow/config-flow.md docs/kb/config-flow/adding-a-config-field.md docs/kb/config-flow/developer-attribute.md; do
  echo "=== $f ==="
  awk '/^```/{if (in_block) {print NR": close ("NR-start+1" lines)"; in_block=0} else {in_block=1; start=NR}} END{if(in_block) print "unclosed block"}' "$f"
done
```

Expected: each fenced block closes within ≤ 5 lines (or the output is empty — no fenced blocks at all). A block > 5 lines indicates pasted source code, which violates the "pointers over paste" rule established in the MS1 packet (commit `e882634`). If found, replace the block with a one-line reference to the `file:line`.

- [ ] **Step 6: Flip the spec's status to implemented**

Use the `Edit` tool on `docs/superpowers/specs/2026-04-19-kb-config-flow-design.md`. Replace:

```
status: approved
```

with:

```
status: implemented
```

- [ ] **Step 7: Commit the status flip**

```bash
git add docs/superpowers/specs/2026-04-19-kb-config-flow-design.md
git commit -m "docs(specs): mark kb-config-flow design as implemented"
```

- [ ] **Step 8: Confirm phase-11 log shows all expected commits**

```bash
git log --oneline phase-11 ^main | head -15
```

Expected: the new commits appear in reverse order — spec-implemented flip, CLAUDE.md fix, index update, four deep-dive-doc commits, README commit, spec-approved flip, spec-add commit (from the brainstorming phase).

The Stop hook will archive the now-`implemented` spec into `docs/superpowers/specs/archive/` at session end; no action needed here.

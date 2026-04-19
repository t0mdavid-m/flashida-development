---
title: KB Packet — Config Flow (method.json → C# → C++ bridge)
status: approved
created: 2026-04-19
---

# KB Packet — Config Flow

## Purpose

Add a second KB packet at `docs/kb/config-flow/` that explains how an operator's edits in `method.json` become live parameters inside the C++ engine, and gives future agents a single recipe for adding a new configuration knob end-to-end.

The packet follows the conventions established by the MS1-acquisition pilot (`2026-04-19-kb-ms1-acquisition-design.md`): frontmatter with `code_anchors`, `last_verified` dates, paths relative to the parent-repo root, pointers over paste, ≤250 lines per file. No infrastructure changes — only content.

## Goals

- **Traceability.** An agent asking "where does `tqscore_threshold` come from?" can follow a single document from `method.json` to the line that parses it, without reading both halves of the bridge.
- **Actionable how-to.** An agent adding a new knob has a checklist that walks all five files they need to touch, in order.
- **Flag the schema mismatch.** The user-facing JSON and the C++-facing JSON are deliberately different. This is the single most common source of confusion; the packet surfaces it front-and-centre.

## Non-goals

- **Semantic reference.** The packet does not explain what a "good" `tqscore_threshold` is or how to tune it. It explains where the value lives and who reads it.
- **Attribute-system expansion.** The `[JsonKey]` / `[Developer]` reflection scheme is documented as-is. No proposals to change, replace, or auto-generate it.
- **Second bridge.** The packet only covers `CreateFLASHIda` (config handoff). Runtime bridge calls (`ProcessScan`, `GetNextScanCommand`) are out of scope — they belong in a future bridge-API packet.

## Architecture

### Directory layout

```
docs/
  kb/
    index.md                            ← one-line addition
    config-flow/
      README.md                         ← packet landing page
      config-flow.md                    ← end-to-end data path
      adding-a-config-field.md          ← how-to recipe
      developer-attribute.md            ← reflection-based routing reference
    ms1-acquisition/                    ← unchanged
  superpowers/
    specs/
      2026-04-19-kb-config-flow-design.md   ← this file
```

Four new files in a new packet directory; one line appended to `docs/kb/index.md`; one targeted edit to `FlashIDA/CLAUDE.md` (caveat-1 fix, see below). No changes to the MS1 packet, no changes to `.claude/hooks/`, no changes to the parent `CLAUDE.md` import.

### Frontmatter

Each of the four new `.md` files uses the standard schema:

```yaml
---
title: <human-readable title>
applies_to: <primary code path this entry documents>
last_verified: 2026-04-19
code_anchors:
  - <path>:<line>   # <short description>
see_also:
  - <relative path to another KB file>
---
```

Same schema as the MS1 packet — no new conventions.

## Content specs

### `README.md`

Landing page. Under 60 lines. Sections:

1. **Overview** — one paragraph framing the two-schema pipeline: a user edits `method.json`; the C# side reads it into a POCO tree via reflection, then re-serializes to a *different* JSON schema for the C++ engine; the C++ engine parses that second schema into typed config structs consumed by every subsystem.
2. **Read order** — `config-flow.md` → `adding-a-config-field.md` → `developer-attribute.md`.
3. **Entry points** — five `file:line` anchors marking the pipeline's hand-off points (listed below under anchor plan).
4. **Related packets** — link to `ms1-acquisition/README.md` (selection/FAIMS/exploration read config via `config_.targeting()`, `config_.level(n)`, `config_.faims()`).

### `config-flow.md`

The end-to-end story, one pass through the pipeline. Target ≤200 lines. Sections:

1. **Disk load.** `MethodParameters.Load(path)` (`FlashIDA/src/Flash/MethodParameters.cs:92`) reads the file and delegates to `MethodConfigSerializer.Deserialize(json)` (`FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23`). Note the Flash CLI default: `method.json` in the program folder (`FlashIDA/src/Flash/Flash.cs:135`).
2. **C# POCO tree.** `MethodConfig` (`FlashIDA/src/Flash/MethodConfig.cs:344`) hierarchical object graph: `Global`, `Deconvolution`, `PrecursorSelection`, `Tagging`, `Quantification`, `Faims`, `MsSettings`, `Scheduling`, `SelectionStrategy`, `Ms3`, `Files`, `Runtime`. Each section class carries a class-level `[JsonKey("...")]` attribute. Each property carries its own `[JsonKey("...")]` and may carry `[Developer]` to route it into the `developer` sub-object at parse/serialize time.
3. **Reflection-based deserialization.** `MethodConfigSerializer.PopulateObject` (`MethodConfigSerializer.cs:136`) walks properties, reads `[JsonKey]` and `[Developer]`, pulls from `mainDict` or `devDict` accordingly. `ConvertValue` (`MethodConfigSerializer.cs:176`) handles primitives, `double[]`, `List<string>`, `List<MS2Parameters>`, value-type structs (field-based via `PopulateStruct`, `MethodConfigSerializer.cs:315`), nested config classes.
4. **Re-serialization for C++.** `MethodParameters.ToCppJson()` (`FlashIDA/src/Flash/MethodParameters.cs:100`) builds a second schema (`JsonMethodConfig` et al., defined in `MethodConfig.cs:569+`) with snake_case keys. Key transformations: `TargetingMode` string → `target_mode` integer (0/1/2/3 switch), `SelectionStrategy.{MS1,MS2,MS3}.Selection` normalized to lowercase (`BuildSelectionStrategy`, `MethodParameters.cs:266`). `MS2/MS3` lists → arrays. `FollowUpScan` Nullable → object or null.
5. **P/Invoke bridge.** `FLASHIdaWrapper(MethodParameters mp)` (`FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:130`) calls `CreateFLASHIda(mp.ToCppJson())`. Bridge decl at `FLASHIdaWrapper.cs:100`. Null return → `InvalidOperationException`.
6. **C++ entry.** `CreateFLASHIda(char*)` (`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39`) constructs `new FLASHIda(arg)`; ctor at `FLASHIda.cpp:62` member-initializes `config_(std::string(arg))` before any subsystem.
7. **C++ parsing.** `Config::Config(const std::string&)` at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84`. First check: must start with `{`, else `std::invalid_argument`. Uses `nlohmann/json`. Fills `DeconvolutionConfig`, `TargetingConfig`, `FAIMSConfig`, `SchedulingConfig`, `QuantConfig`, `RuntimeConfig`, and `std::map<int, MSLevelConfig> levels_`. Defaults applied per field via `.value(key, default)`.
8. **Legacy-key rejection.** `ms3.{enabled,active,mode,all_charges,max_per_ms2}` throw with a migration message (`Config.cpp:172`). Mentioned because agents editing old methods will hit this.
9. **Validation.** `Config::validate()` runs consistency checks (selection metric vs. `min_charge`, exploration sanity). Called after construction; throws `std::invalid_argument` on conflict.
10. **Consumer wiring.** Every subsystem takes `config_` by const-ref in its ctor: `deconv_(config_, ...)`, `selection_(config_, deconv_)`, `faims_(config_)`, `exploration_(config_, fragments_)` (`FLASHIda.cpp:62-70`). Read paths are stable: `config_.targeting().hcd_energy`, `config_.level(2).selection`, `config_.faims().cv_values`.

Gotcha sidebars interspersed: two schemas, `[Developer]` routing splits at serialize time, tolerance array must have one entry per MS level (min 2 enforced at `Config.cpp:111`), `FAIMSConfig::enabled` is derived (`cv_values.size() > 1`, not a config key).

### `adding-a-config-field.md`

Ordered recipes. Target ≤200 lines. Opens with a **schema-mismatch warning** (a field exists only where you wire it — forgetting the C++ parser means the C# side silently produces JSON the engine ignores). Then three scenarios:

**Scenario 1 — user-facing field on an existing section.** Example: adding `precursor_selection.new_knob: double = 0.5`.

1. C# POCO: add property on the section class in `MethodConfig.cs`, decorate with `[JsonKey("new_knob")]`. Touch the aggregate initializer if the class uses one (global feedback: *always grep for aggregate-init sites after adding fields*).
2. C# re-serialization: map in `MethodParameters.ToCppJson()` under the section's `JsonPrecursorSelectionConfig` block (`MethodParameters.cs:126-135`).
3. C++ struct: add field + default in `TargetingConfig` (`Config.h:143`).
4. C++ parser: `.value("new_knob", <default>)` in the appropriate section block of `Config.cpp`.
5. Downstream consumer: read via `config_.targeting().new_knob` wherever it's needed.
6. Test-mode sanity: run the Flash test-mode CLI (see `FlashIDA/CLAUDE.md`; the signature is `Flash.exe <input> <output> method.json [ms2_file]`, `FLASHIdaWrapper.cs:399`). The new value should appear in the `--- Method Parameters ---` log dump (`MethodParameters.cs:346 ToLogString`) and no `CreateFLASHIda error:` should appear on stderr.

**Scenario 2 — developer-only field.** Same as Scenario 1 but:

- Step 1: additionally decorate the property with `[Developer]` (attribute defined at `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs`, not at top-level `Flash/`).
- The property lands in `method.json` under `developer.<section_key>.new_knob` rather than `<section_key>.new_knob`. `MethodConfigSerializer.Serialize` and `Deserialize` route it automatically via `JsonKeyAttribute` on the class.

**Scenario 3 — new MS-level entry.** Adding, e.g., an MS4 level or a new field on `MSLevelConfig`.

1. `SelectionStrategy` block in `MethodConfig.cs` and the corresponding `JsonSelectionStrategyConfig` in `BuildSelectionStrategy()` (`MethodParameters.cs:266`).
2. C++ `MSLevelConfig` (`Config.h:93`). Update `default_level_` (`Config.cpp:45`) to match.
3. C++ parser block in `Config.cpp` — look for the `ms_settings` and `selection_strategy` sections.
4. Any consumer iterating `config_.levels()` needs the new field.

Closes with **"test it in isolation"** — run the Flash test-mode CLI (signature at `FLASHIdaWrapper.cs:399`); no instrument needed per `FlashIDA/CLAUDE.md`. Watch for the `--- Method Parameters ---` log dump with the new field populated, and no `CreateFLASHIda error:` on stderr.

### `developer-attribute.md`

Focused reference on the reflection-based routing. Target ≤80 lines. Sections:

1. **What it is.** Two C# attributes: `JsonKeyAttribute` (`FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs`) and `DeveloperAttribute` (`FlashIDA/src/Flash/IDA/DeveloperAttribute.cs`). Note the `IDA/` subfolder — attributes live with the serializer, not at top-level `Flash/`.
2. **Class-level vs property-level `[JsonKey]`.** Class-level `[JsonKey("deconvolution")]` names the top-level JSON section. Property-level `[JsonKey("score_threshold")]` names the key inside the section.
3. **How `[Developer]` routing works.** At serialize time, `MethodConfigSerializer.SerializeObject` (`MethodConfigSerializer.cs:363`) partitions properties into `mainDict` (non-dev) and `devDict` (dev). `devDict` is then nested under `root["developer"][<class-level JsonKey>]`. At deserialize time, `MethodConfigSerializer.Deserialize` (`MethodConfigSerializer.cs:23`) pulls from either `raw[<section>]` or `raw["developer"][<section>]` based on `[Developer]`.
4. **Why bother.** User-facing methods stay concise; developer/internal tuning knobs live in a separate namespace. Same POCO tree backs both; no duplication.
5. **Gotcha.** Nested (non-top-level) objects with `[Developer]` properties merge developer keys into the parent dict — developer routing only fires at the top level (`MethodConfigSerializer.cs:451-452`).

## Index update

Append one line to `docs/kb/index.md` under `## Packets`, below the existing MS1 entry:

```
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
```

Index remains well under the 200-line auto-load truncation.

## Caveat-1 fix: `FlashIDA/CLAUDE.md`

`FlashIDA/CLAUDE.md` currently describes the method config as XML and references removed files (`Parameter.cs`, `ScanScheduler.cs`, `FAIMSScanProcessor.cs`, `IDAScanProcessor.cs`, `<SelectionStrategy>` XML). The packet depends on it being accurate.

Targeted edits (no wholesale rewrite):

- **"Architecture → Key Components"**: remove the `Parameter.cs` bullet. Replace `MethodParameters.cs` / `MethodConfig.cs` bullet text to match current reality (JSON, not XML; `MethodConfigSerializer`, not XML parsing). The "No-longer-present" paragraph already flags `ScanScheduler.cs` / `FAIMSScanProcessor.cs` / `IDAScanProcessor.cs` — it stays.
- **"Architecture → Acquisition Modes"**: change `Configured via TargetingMode in the method XML` to `Configured via precursor_selection.targeting_mode in method.json`.
- **"Method Configuration"**: replace the XML paragraph with: `JSON-based (src/Flash/etc/method.json). See docs/kb/config-flow/ for the end-to-end flow.`

Unchanged: Build, Data Flow (still accurate — the pipeline description doesn't mention XML), External Dependencies, Logging.

## Caveat-2 call-out

`adding-a-config-field.md` step 1 (Scenario 2) and `developer-attribute.md` section 1 both state explicitly that `JsonKeyAttribute.cs` and `DeveloperAttribute.cs` live under `FlashIDA/src/Flash/IDA/`, not at the top-level `FlashIDA/src/Flash/`. Avoids "where is this attribute defined?" grepping on future reads.

## Anchor plan (summary)

Minimum code_anchors across the packet (each doc picks its subset):

- `FlashIDA/src/Flash/MethodParameters.cs:92` — `MethodParameters.Load`
- `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:23` — `Deserialize`
- `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs:136` — `PopulateObject`
- `FlashIDA/src/Flash/MethodParameters.cs:100` — `ToCppJson`
- `FlashIDA/src/Flash/MethodParameters.cs:266` — `BuildSelectionStrategy`
- `FlashIDA/src/Flash/MethodConfig.cs:344` — `MethodConfig` root class
- `FlashIDA/src/Flash/MethodConfig.cs:569` — `JsonMethodConfig` root class
- `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:100` — `CreateFLASHIda` P/Invoke decl
- `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:130` — wrapper ctor
- `FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs` — `JsonKeyAttribute` (whole file)
- `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs` — `DeveloperAttribute` (whole file)
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39` — `CreateFLASHIda` C++ entry
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:62` — `FLASHIda` ctor
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:93` — `MSLevelConfig`
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:143` — `TargetingConfig`
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:195` — `Config` class
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:84` — `Config::Config`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:172` — legacy-key rejection

## Verification

- After content lands, `@docs/kb/index.md` loads automatically; grep the index for the new entry.
- Every `code_anchor` in the four new files resolves (one Read per anchor — cheap; budget ~20 reads).
- `FlashIDA/CLAUDE.md` no longer contains the strings `method.xml`, `Parameter.cs`, or `<SelectionStrategy>`.
- Run `gh` / local build not required — this is pure documentation.

## Spec lifecycle

- `status: draft` on write.
- User approves the spec → flip to `status: approved` in-place.
- All plan tasks complete + merged → flip to `status: implemented`. The existing Stop hook archives the spec at session end.

## Deliverables

- `docs/kb/config-flow/README.md`
- `docs/kb/config-flow/config-flow.md`
- `docs/kb/config-flow/adding-a-config-field.md`
- `docs/kb/config-flow/developer-attribute.md`
- `docs/kb/index.md` — one-line addition under `## Packets`
- `FlashIDA/CLAUDE.md` — targeted edits per Caveat-1 fix

## Open questions

None at design time. Any implementation-level decisions (exact wording, precise anchor selection, test-mode input file choice) are deferred to the implementation plan.

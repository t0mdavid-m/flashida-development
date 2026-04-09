# JSON Config Migration Design

## Goal

Replace XML method configuration with JSON as the sole config format on the C# side. C# classes define the user-facing JSON schema with `[Description]`, `[Developer]`, and `[JsonKey]` attributes that drive both serialization and GitHub.io documentation generation. The C++ JSON format is unchanged.

## Architecture

```
method.json (user-facing, mirrors XML structure in JSON)
    |  MethodConfigSerializer.Deserialize()
    v
MethodConfig classes (with [Description], [Developer], [JsonKey] attributes)
    |  ToCppJson() — transform + serialize
    v
C++ JSON string (unchanged format)
    |  CreateFLASHIda(json)
    v
C++ parseJSONConfig_() (no changes)
```

C# reads a JSON config file into typed classes, uses them for runtime needs (Duration, logging), transforms them to the existing C++ JSON format, and passes the string to the C++ bridge. The C++ side sees no change whatsoever.

## Key Decisions

- **JSON only** — XML support is dropped entirely. No fallback, no auto-detection.
- **User-facing JSON schema differs from C++ JSON schema** — the user-facing format mirrors the current XML structure (familiar to existing users). A transform layer in C# maps it to the C++ format.
- **`[Developer]` attribute controls JSON structure** — properties tagged `[Developer]` are automatically routed to/from a `developer` section in the JSON file. Promoting a parameter to user-facing = remove the attribute. One line change.
- **`[JsonKey]` attribute for explicit naming** — every property declares its JSON key name explicitly. No automatic PascalCase-to-snake_case conversion. All mappings are searchable in source.
- **C# classes are the single source of truth** — the schema, defaults, documentation, and validation all derive from the annotated C# classes.

## `[Developer]` Attribute Behavior

Properties tagged `[Developer]` live on the class where they logically belong but are serialized into a separate `developer` section in the JSON file:

```csharp
public class PrecursorSelectionConfig
{
    [JsonKey("qscore_threshold")]
    [Description("Quality score threshold")]
    public double QScoreThreshold { get; set; } = 0.9;

    [Developer]
    [JsonKey("use_id_score")]
    [Description("Use identification-based scoring instead of QScore")]
    public bool UseIDScore { get; set; }

    [Developer]
    [JsonKey("hcd_energy")]
    [Description("HCD collision energy")]
    public int HCDEnergy { get; set; } = 29;
}
```

Produces:

```json
{
  "precursor_selection": {
    "qscore_threshold": 0.9
  },
  "developer": {
    "precursor_selection": {
      "use_id_score": false,
      "hcd_energy": 29
    }
  }
}
```

**Promoting a developer parameter to user-facing:** Remove `[Developer]`. The property stays on the same class. The serializer stops routing it to the `developer` section. JSON structure, documentation, and behavior all update from that one attribute change.

## C# Class Hierarchy

### MethodParameters (existing, modified)

`MethodParameters` remains the top-level class that the rest of the codebase interacts with (`Flash.cs`, `FLASHIdaWrapper.cs`, tests). It gains a `Config` property holding the new typed config, and its `Load()` method switches from `XmlSerializer` to `MethodConfigSerializer`. `ToCppJson()` replaces the old `IDA.ToJSON(mp)` call chain.

```csharp
public class MethodParameters
{
    public MethodConfig Config { get; private set; }

    public static MethodParameters Load(string path) { /* JSON deserialize */ }
    public string ToCppJson() { /* transform to C++ format */ }
    public string ToLogString() { /* diagnostic output */ }
}
```

No backward-compatible accessors. Callers access config values through `Config` directly (e.g., `methodParams.Config.Global.Duration`). `ToLogString()` reads from `Config` internally.

### MethodConfig (new, the config schema)

The new config classes replace both the XML classes and `IDAParameters`:

```csharp
public class MethodConfig
{
    public GlobalConfig Global { get; set; }
    public DeconvolutionConfig Deconvolution { get; set; }
    public PrecursorSelectionConfig PrecursorSelection { get; set; }
    public TaggingConfig Tagging { get; set; }
    public QuantificationConfig Quantification { get; set; }
    public FaimsConfig Faims { get; set; }
    public MsSettingsConfig MsSettings { get; set; }
    public SchedulingConfig Scheduling { get; set; }
    public SelectionStrategyConfig SelectionStrategy { get; set; }
    public Ms3Config Ms3 { get; set; }
    public FilesConfig Files { get; set; }
}
```

Key characteristics:

- **Flat-ish hierarchy** — no `AcquisitionModes` wrapper, no `IDAParameters` intermediate.
- **Developer properties live on their parent class** — e.g., `UseIDScore` on `PrecursorSelectionConfig`, `MaxCVSkip` on `FaimsConfig`, tagged `[Developer]`.
- **`GlobalConfig`** holds `Duration` (the only field C# reads at runtime beyond passing to C++).
- **`MS1Parameters`, `MS2Parameters`, `MS3Parameters` structs stay** in `MsSettingsConfig` as the instrument parameter contract.
- **Every property** has `[JsonKey]` and `[Description]`. Developer properties additionally have `[Developer]`.

## Serialization / Deserialization

### MethodConfigSerializer

A custom serializer class handles `[Developer]`-aware JSON round-trip using `JavaScriptSerializer` (already in the project).

**Deserialize flow:**
1. Read JSON file as string.
2. `JavaScriptSerializer.Deserialize<Dictionary<string, object>>()` to get raw structure.
3. For each config class, reflect over properties:
   - Non-`[Developer]` properties: read from main section (e.g., `precursor_selection.qscore_threshold`).
   - `[Developer]` properties: read from `developer` section (e.g., `developer.precursor_selection.use_id_score`).
4. Return populated `MethodConfig` object.

**Serialize flow:**
1. Reflect over each config class.
2. Non-`[Developer]` properties: write to main section.
3. `[Developer]` properties: write to `developer` section.
4. `JavaScriptSerializer.Serialize()` to produce JSON string.

### ToCppJson()

Replaces `InitializeIDA()` + `IDAParameters.ToJSON()`. Lives on `MethodConfig`. Builds the `JsonMethodConfig` object (the existing C++-facing classes) from the new config classes. Same mapping logic as today, consolidated into one transform. Output is the identical JSON string that C++ already parses.

### Property Naming

C# properties use PascalCase (`QScoreThreshold`). The user-facing JSON uses snake_case (`qscore_threshold`). Each property declares its JSON key explicitly via `[JsonKey("qscore_threshold")]`.

## C# Runtime Config Usage

After the migration, C# reads config values in only two places:

1. **`Duration`** — `Flash.cs` reads `methodParams.Config.Global.Duration` to set the method timer (`Duration * 60000` ms).
2. **`ToLogString()`** — reads config fields for diagnostic logging output.

All other config consumption (instrument control, precursor selection, FAIMS cycling, exploration) flows through C++ via `ToCppJson()` and comes back as `ScanCommand` structs.

The dead `CustomScanListner` in `Flash.cs` (which accessed `MS1` parameters directly) is deleted.

## Documentation Pipeline (GitHub.io)

`MethodDocGenerator` reflects over the config classes and produces structured Markdown:

- `[JsonKey]` provides the parameter name as it appears in the config file.
- `[Description]` provides the human-readable explanation.
- `[Developer]` tags the parameter as advanced (separate section in docs).
- Default value from property initializer.
- Type from property type.

Example output:

```markdown
## Deconvolution

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `score_threshold` | double | 0.0 | Quality score threshold for accepting deconvolved peaks |
| `min_charge` | int | 4 | Minimum precursor charge state |

## Precursor Selection

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `qscore_threshold` | double | 0.9 | Quality score threshold |

### Developer Settings

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `use_id_score` | bool | false | Use identification-based scoring instead of QScore |
| `hcd_energy` | int | 29 | HCD collision energy |
```

A GitHub Actions workflow runs the generator and publishes to GitHub Pages.

## File Changes

### Deleted

- `IDAParameters` class in `Parameter.cs` (flat intermediate, `ToJSON()`, constructor)
- `InitializeIDA()` in `MethodParameters.cs`
- XML config classes in `MethodConfig.cs` top half (`GlobalParameters`, `PrecursorSelectionParameters`, `AcquisitionModesConfig`, `DeveloperConfig`, etc.)
- All XML method files (`src/Flash/etc/method.xml`, `test-data/configs/method_*.xml`)
- `CustomScanListner` in `Flash.cs` (dead code)
- `MethodParameters.Save()` (XML serialization)

### Modified

- **`MethodConfig.cs`** — replace XML config classes with new `[Description]`/`[Developer]`/`[JsonKey]`-annotated classes. Keep `Json*Config` C++-facing classes as internal transform targets.
- **`MethodParameters.cs`** — `Load()` calls `MethodConfigSerializer.Deserialize()` instead of `XmlSerializer`. Add `ToCppJson()`. Update `ToLogString()` to read from new config classes.
- **`FLASHIdaWrapper.cs`** — call `ToCppJson()` instead of `mp.IDA.ToJSON(mp)`.
- **`Flash.cs`** — `Duration` accessed from new config. Remove dead `CustomScanListner`.
- **`MethodDocGenerator.cs`** — updated to read `[Description]`, `[Developer]`, `[JsonKey]` and produce structured Markdown output.
- **`Flash.csproj`** — add new files, remove XML-related references if any.

### Created

- **`MethodConfigSerializer.cs`** — custom `[Developer]`-aware JSON serializer/deserializer.
- **`DeveloperAttribute.cs`** — the `[Developer]` custom attribute.
- **`JsonKeyAttribute.cs`** — the `[JsonKey]` custom attribute.
- **`method.json`** — default method config (replaces `method.xml`).
- **`test-data/configs/method_*.json`** — test configs (replace XML equivalents).

### Untouched

- All C++ code (OpenMS) — zero changes.
- `ScanFactory.cs`, `DataPipe.cs`, `UnifiedScanProcessor.cs`.
- `MS1Parameters`, `MS2Parameters`, `MS3Parameters` structs.
- Golden JSON files (`config_default.json`, `config_full.json`) — these validate `ToCppJson()` output stability.

## Testing

### Unit Tests

- **Deserialization:** Load each `method_*.json` test config, verify all properties populated correctly.
- **`[Developer]` routing:** Verify developer-tagged properties are read from `developer` section, non-developer from main section.
- **`ToCppJson()` output:** Deserialize a test config, call `ToCppJson()`, verify output matches existing golden files (`config_default.json`, `config_full.json`).
- **Round-trip:** Deserialize, serialize, deserialize — verify identical config.
- **Missing required fields:** Verify `SelectionStrategy` absence throws.
- **`MethodDocGenerator`:** Verify output contains `[Description]` text, `[Developer]` grouping, and `[JsonKey]` names.

### Integration Tests

- **`BridgeSmokeTests`:** Update to build config from JSON — same assertions on C++ bridge behavior.
- **`ContinuityTests`:** Update to load `.json` configs — same end-to-end assertions.

### Not Affected

- C++ tests — completely unchanged.
- `ScanFactory`, `DataPipe` tests — not affected.

Golden files (`config_default.json`, `config_full.json`) serve dual purpose: test fixtures for `ToCppJson()` output AND reference for C++ format stability.

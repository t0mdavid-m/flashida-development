# JSON Config Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace XML method configuration with JSON as the sole config format on the C# side, with `[Description]`/`[Developer]`/`[JsonKey]` attributes driving both serialization and documentation generation.

**Architecture:** New `MethodConfig` class hierarchy with custom attributes defines the user-facing JSON schema. `MethodConfigSerializer` handles `[Developer]`-aware JSON serialization. `ToCppJson()` transforms to the existing C++ JSON format (unchanged). `IDAParameters` and all XML infrastructure are deleted.

**Tech Stack:** C# / .NET Framework 4.8, `JavaScriptSerializer` (System.Web.Extensions), NUnit 3.13

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/Flash/IDA/JsonKeyAttribute.cs` | Create | `[JsonKey("name")]` custom attribute |
| `src/Flash/IDA/DeveloperAttribute.cs` | Create | `[Developer]` custom attribute |
| `src/Flash/MethodConfig.cs` | Modify | Replace XML classes with `[JsonKey]`/`[Description]`/`[Developer]`-annotated schema classes; keep `Json*Config` C++-facing classes |
| `src/Flash/IDA/MethodConfigSerializer.cs` | Create | `[Developer]`-aware JSON serializer/deserializer |
| `src/Flash/MethodParameters.cs` | Modify | Switch `Load()` from XML to JSON, add `ToCppJson()`, update `ToLogString()`, delete `InitializeIDA()` and backward-compat accessors |
| `src/Flash/IDA/Parameter.cs` | Modify | Delete `IDAParameters` class entirely |
| `src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | Call `mp.ToCppJson()` instead of `mp.IDA.ToJSON(mp)` |
| `src/Flash/Flash.cs` | Modify | Duration via `Config.Global.Duration`, remove `CustomScanListner` |
| `src/Flash/IDA/MethodDocGenerator.cs` | Modify | Read `[JsonKey]`, `[Description]`, `[Developer]` to produce Markdown |
| `src/Flash/Flash.csproj` | Modify | Add new `.cs` files, change `method.xml` → `method.json` |
| `src/Flash/etc/method.json` | Create | Default method config (replaces `method.xml`) |
| `test-data/configs/method_*.json` | Create | 20 JSON test configs replacing XML equivalents |
| `src/Flash.Tests/JsonConfigTests.cs` | Modify | Load JSON, test `ToCppJson()` against golden files |
| `src/Flash.Tests/BridgeSmokeTests.cs` | Modify | Build config from new classes |
| `src/Flash.Tests/GoldenCaptureTests.cs` | Modify | Use `ToCppJson()` |
| `src/Flash.Tests/CleanupTests.cs` | Modify | Update MethodDocGenerator test |
| `src/Flash.Tests/Mocks/ContinuityTestHarness.cs` | Modify | `IDA.*` → `Config.*` |
| `src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs` | Modify | `IDA.*` → `Config.*`, `MS1`/`MS2` → `Config.MsSettings.*` |
| `src/Flash.Tests/BridgePhase3Tests.cs` | Modify | Load JSON instead of XML |
| `src/Flash.Tests/Flash.Tests.csproj` | Modify | Add new test files if needed |
| `src/Flash/etc/method.xml` | Delete | Replaced by `method.json` |
| `test-data/configs/method_*.xml` | Delete | Replaced by JSON equivalents |

---

## Task 1: Custom Attributes

**Files:**
- Create: `FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs`
- Create: `FlashIDA/src/Flash/IDA/DeveloperAttribute.cs`
- Modify: `FlashIDA/src/Flash/Flash.csproj`

- [ ] **Step 1: Create JsonKeyAttribute.cs**

```csharp
using System;

namespace Flash.IDA
{
    /// <summary>
    /// Specifies the JSON key name for a property in the user-facing config file.
    /// </summary>
    [AttributeUsage(AttributeTargets.Property | AttributeTargets.Class, AllowMultiple = false)]
    public sealed class JsonKeyAttribute : Attribute
    {
        public string Key { get; }

        public JsonKeyAttribute(string key)
        {
            Key = key;
        }
    }
}
```

- [ ] **Step 2: Create DeveloperAttribute.cs**

```csharp
using System;

namespace Flash.IDA
{
    /// <summary>
    /// Marks a config property as a developer/advanced setting.
    /// Developer-tagged properties are serialized into a separate "developer"
    /// section in the user-facing JSON config file.
    /// </summary>
    [AttributeUsage(AttributeTargets.Property, AllowMultiple = false)]
    public sealed class DeveloperAttribute : Attribute
    {
    }
}
```

- [ ] **Step 3: Add both files to Flash.csproj**

In `FlashIDA/src/Flash/Flash.csproj`, inside the `<ItemGroup>` containing `<Compile>` entries (after the `<Compile Include="IDA\MethodDocGenerator.cs" />` line), add:

```xml
    <Compile Include="IDA\JsonKeyAttribute.cs" />
    <Compile Include="IDA\DeveloperAttribute.cs" />
```

- [ ] **Step 4: Build to verify**

Run: `msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /v:minimal`

Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add FlashIDA/src/Flash/IDA/JsonKeyAttribute.cs FlashIDA/src/Flash/IDA/DeveloperAttribute.cs FlashIDA/src/Flash/Flash.csproj
git commit -m "Add JsonKey and Developer custom attributes for JSON config"
```

---

## Task 2: MethodConfig Schema Classes

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs`

Replace the XML config classes (lines 1-167: `GlobalParameters` through `SelectionStrategyConfig`) with new `[JsonKey]`/`[Description]`/`[Developer]`-annotated classes. Keep the `Json*Config` C++-facing classes (lines 196-349) and the `ScanSchedulingConfig`/`ParameterOptimizationConfig` scheduling classes unchanged.

**Important:** The `MS1Parameters`, `MS2Parameters`, `MS3Parameters` structs remain in `MethodParameters.cs` — they are the instrument API contract and are still used by `ScanFactory`/`ScanCommand`. `MsSettingsConfig` references them.

- [ ] **Step 1: Add using directives**

At the top of `MethodConfig.cs`, add:

```csharp
using System.ComponentModel;
using Flash.IDA;
```

- [ ] **Step 2: Replace XML config classes with new MethodConfig hierarchy**

Replace everything from `public class GlobalParameters` through `public class SelectionStrategyConfig` (lines 7-167) with:

```csharp
    // ====================================================================
    // User-facing JSON config schema — annotated for serialization and docs
    // ====================================================================

    [JsonKey("global")]
    public class GlobalConfig
    {
        [JsonKey("method_name")]
        [Description("Name of the acquisition method")]
        public string MethodName { get; set; } = "";

        [JsonKey("method_description")]
        [Description("Description of the acquisition method")]
        public string MethodDescription { get; set; } = "";

        [JsonKey("duration")]
        [Description("Acquisition duration in minutes")]
        public double Duration { get; set; } = 90;
    }

    [JsonKey("deconvolution")]
    public class DeconvolutionConfig
    {
        [JsonKey("score_threshold")]
        [Description("Quality score threshold for accepting deconvolved peaks (0.0-1.0)")]
        public double ScoreThreshold { get; set; } = -1;

        [JsonKey("tqscore_threshold")]
        [Description("Target quality score threshold for precursor filtering")]
        public double TQScoreThreshold { get; set; } = 0.9;

        [JsonKey("min_charge")]
        [Description("Minimum precursor charge state")]
        public int MinCharge { get; set; } = 4;

        [JsonKey("max_charge")]
        [Description("Maximum precursor charge state")]
        public int MaxCharge { get; set; } = 50;

        [JsonKey("min_mass")]
        [Description("Minimum precursor mass in Da")]
        public double MinMass { get; set; } = 500;

        [JsonKey("max_mass")]
        [Description("Maximum precursor mass in Da")]
        public double MaxMass { get; set; } = 50000;

        [JsonKey("tol")]
        [Description("Mass tolerance array [down, up] in ppm")]
        public double[] Tolerances { get; set; } = new double[] { 10, 10 };
    }

    [JsonKey("precursor_selection")]
    public class PrecursorSelectionConfig
    {
        [JsonKey("rt_window")]
        [Description("Retention time window in seconds for precursor tracking")]
        public double RTWindow { get; set; } = 180;

        [JsonKey("targeting_mode")]
        [Description("Targeting mode: none, inclusion, exclusion, or deep")]
        public string TargetingMode { get; set; } = "none";

        [JsonKey("strict_inclusion")]
        [Description("If true, only acquire targets from the inclusion list")]
        public bool StrictInclusion { get; set; }

        [JsonKey("tie_threshold")]
        [Description("Tie-breaking threshold for precursor ranking")]
        public double TieThreshold { get; set; } = 0.1;

        [Developer]
        [JsonKey("use_id_score")]
        [Description("Use identification-based scoring instead of QScore")]
        public bool UseIDScore { get; set; }

        [Developer]
        [JsonKey("consider_all_charges")]
        [Description("Consider all charge states for precursor selection")]
        public bool ConsiderAllChargeStates { get; set; }

        [Developer]
        [JsonKey("ms3_all_charges")]
        [Description("Consider all charge states for MS3 selection")]
        public bool MS3AllCharges { get; set; }

        [Developer]
        [JsonKey("hcd_energy")]
        [Description("HCD collision energy for charge-state determination")]
        public int HCDEnergy { get; set; } = 29;
    }

    [JsonKey("tagging")]
    public class TaggingConfig
    {
        [JsonKey("active")]
        [Description("Enable MS2 sequence tagging")]
        public bool Active { get; set; }

        [JsonKey("conditional_ms2")]
        [Description("Use conditional MS2 based on tag results")]
        public bool ConditionalMS2 { get; set; }

        [JsonKey("min_tag_length")]
        [Description("Minimum sequence tag length")]
        public int MinTagLength { get; set; } = 3;

        [JsonKey("max_tag_length")]
        [Description("Maximum sequence tag length")]
        public int MaxTagLength { get; set; } = 8;

        [JsonKey("max_ptm_count")]
        [Description("Maximum number of PTMs to consider per tag")]
        public int MaxPtmCount { get; set; } = 3;

        [JsonKey("max_flanking_mass_diff")]
        [Description("Maximum flanking mass difference in Da")]
        public double MaxFlankingMassDiff { get; set; } = 50000;
    }

    [JsonKey("quantification")]
    public class QuantificationConfig
    {
        [JsonKey("active")]
        [Description("Enable isobaric labeling quantification")]
        public bool Active { get; set; }

        [JsonKey("reporter_mz_tol")]
        [Description("Reporter ion m/z tolerance in Da")]
        public double ReporterMZTol { get; set; }

        [JsonKey("fold_change_threshold")]
        [Description("Fold-change threshold for differential quantification")]
        public double FoldChangeThreshold { get; set; }

        [JsonKey("only_one_condition")]
        [Description("Only quantify targets present in one condition")]
        public bool OnlyOneCondition { get; set; }
    }

    [JsonKey("faims")]
    public class FaimsConfig
    {
        [JsonKey("cv_values")]
        [Description("FAIMS compensation voltage values to cycle through")]
        public double[] CVValues { get; set; } = new double[] { -50 };

        [Developer]
        [JsonKey("max_cv_skip")]
        [Description("Maximum number of FAIMS CV cycles to skip")]
        public int MaxCVSkip { get; set; }

        [Developer]
        [JsonKey("mass_threshold")]
        [Description("Mass threshold for FAIMS CV precursor grouping")]
        public int MassThreshold { get; set; } = 15;
    }

    [JsonKey("ms_settings")]
    public class MsSettingsConfig
    {
        [JsonKey("ms1")]
        public MS1Parameters MS1 { get; set; }

        [JsonKey("ms2")]
        public List<MS2Parameters> MS2 { get; set; } = new List<MS2Parameters>();

        [JsonKey("ms3")]
        public List<MS3Parameters> MS3 { get; set; } = new List<MS3Parameters>();
    }

    [JsonKey("scheduling")]
    public class SchedulingConfig
    {
        [JsonKey("cycle_time_enabled")]
        [Description("Enable cycle time limit")]
        public bool CycleTimeEnabled { get; set; }

        [JsonKey("cycle_time_ms")]
        [Description("Maximum cycle time in milliseconds")]
        public double CycleTimeMs { get; set; } = 60000;

        [JsonKey("timeout_enabled")]
        [Description("Enable scan timeout")]
        public bool TimeoutEnabled { get; set; }

        [JsonKey("timeout_ms")]
        [Description("Scan timeout in milliseconds")]
        public double TimeoutMs { get; set; } = 30000;
    }

    [JsonKey("ms3")]
    public class Ms3Config
    {
        [JsonKey("active")]
        [Description("Enable MS3 characterization")]
        public bool Active { get; set; }

        [JsonKey("mode")]
        [Description("MS3 characterization mode (1, 2, or 3)")]
        public int Mode { get; set; }

        [JsonKey("max_per_ms2")]
        [Description("Maximum MS3 scans per MS2 scan")]
        public int MaxPerMs2 { get; set; } = 4;

        [JsonKey("all_charges")]
        [Description("Consider all charge states for MS3")]
        public bool AllCharges { get; set; }

        [JsonKey("protein_sequence")]
        [Description("Protein sequence for MS3 targeted characterization")]
        public string ProteinSequence { get; set; } = "";
    }

    [JsonKey("files")]
    public class FilesConfig
    {
        [JsonKey("target_logs")]
        [Description("Log files containing target or excluded masses")]
        public List<string> TargetLogs { get; set; } = new List<string>();

        [JsonKey("fasta")]
        [Description("FASTA file path for sequence tagging")]
        public string FastaFile { get; set; } = "";

        [JsonKey("inclusion_list")]
        [Description("Inclusion list file path")]
        public string InclusionList { get; set; } = "";

        [JsonKey("ptm_list")]
        [Description("PTM list file path")]
        public string PtmList { get; set; } = "";
    }

    // SelectionStrategy classes — keep existing names, add [JsonKey]/[Description]
    [JsonKey("exploration")]
    public class ExplorationBlockConfig
    {
        [JsonKey("metric")]
        [Description("Exploration metric: none, qscore, or intensity")]
        public string Metric { get; set; } = "none";

        [JsonKey("ce_min")]
        [Description("Minimum collision energy for exploration sweep")]
        public double CEMin { get; set; } = 20;

        [JsonKey("ce_max")]
        [Description("Maximum collision energy for exploration sweep")]
        public double CEMax { get; set; } = 40;

        [JsonKey("ce_step")]
        [Description("Collision energy step size")]
        public double CEStep { get; set; } = 5;

        [JsonKey("activation")]
        [Description("Activation method for exploration (HCD or CID)")]
        public string Activation { get; set; } = "HCD";
    }

    [JsonKey("ms1")]
    public class MS1SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS1 precursor selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "qscore";

        [JsonKey("max_precursors")]
        [Description("Maximum number of precursors to select per MS1 scan")]
        public int MaxPrecursors { get; set; } = 10;
    }

    [JsonKey("ms2")]
    public class MS2SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS2 fragment selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "intensity";

        [JsonKey("max_fragments")]
        [Description("Maximum number of fragments to select per MS2 scan")]
        public int MaxFragments { get; set; } = 3;

        [JsonKey("exploration")]
        public ExplorationBlockConfig Exploration { get; set; }
    }

    [JsonKey("ms3")]
    public class MS3SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS3 fragment selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "none";

        [JsonKey("max_fragments")]
        [Description("Maximum number of fragments to select per MS3 scan")]
        public int MaxFragments { get; set; } = 3;

        [JsonKey("exploration")]
        public ExplorationBlockConfig Exploration { get; set; }
    }

    [JsonKey("selection_strategy")]
    public class SelectionStrategyConfig
    {
        [JsonKey("ms1")]
        public MS1SelectionConfig MS1 { get; set; } = new MS1SelectionConfig();

        [JsonKey("ms2")]
        public MS2SelectionConfig MS2 { get; set; } = new MS2SelectionConfig();

        [JsonKey("ms3")]
        public MS3SelectionConfig MS3 { get; set; } = new MS3SelectionConfig();
    }

    /// <summary>
    /// Root method configuration — user-facing JSON schema.
    /// </summary>
    public class MethodConfig
    {
        [JsonKey("global")]
        public GlobalConfig Global { get; set; } = new GlobalConfig();

        [JsonKey("deconvolution")]
        public DeconvolutionConfig Deconvolution { get; set; } = new DeconvolutionConfig();

        [JsonKey("precursor_selection")]
        public PrecursorSelectionConfig PrecursorSelection { get; set; } = new PrecursorSelectionConfig();

        [JsonKey("tagging")]
        public TaggingConfig Tagging { get; set; } = new TaggingConfig();

        [JsonKey("quantification")]
        public QuantificationConfig Quantification { get; set; } = new QuantificationConfig();

        [JsonKey("faims")]
        public FaimsConfig Faims { get; set; } = new FaimsConfig();

        [JsonKey("ms_settings")]
        public MsSettingsConfig MsSettings { get; set; } = new MsSettingsConfig();

        [JsonKey("scheduling")]
        public SchedulingConfig Scheduling { get; set; } = new SchedulingConfig();

        [JsonKey("selection_strategy")]
        public SelectionStrategyConfig SelectionStrategy { get; set; } = new SelectionStrategyConfig();

        [JsonKey("ms3")]
        public Ms3Config Ms3 { get; set; } = new Ms3Config();

        [JsonKey("files")]
        public FilesConfig Files { get; set; } = new FilesConfig();
    }
```

- [ ] **Step 3: Remove old XML classes**

Delete the original XML config classes that were replaced (lines 7-167 of the original file): `GlobalParameters`, `PrecursorSelectionParameters`, `MS2TaggingConfig`, `TargetedInclusionConfig`, `TargetedExclusionConfig`, `DeepModeConfig`, `LabelingQuantConfig`, `MS3CharacterizationConfig`, `DeveloperFAIMSConfig`, `DeveloperPrecursorSelectionConfig`, `DeveloperConfig`, `AcquisitionModesConfig`, `FAIMSSettings`, and the old `MSSettingsConfig`.

Also delete the old `ScanSchedulingConfig` and `ParameterOptimizationConfig` classes (lines 175-194) — their fields are now in `SchedulingConfig`.

Keep the `[Serializable]` attribute removal from `ExplorationBlockConfig`, `MS1SelectionConfig`, `MS2SelectionConfig`, `MS3SelectionConfig`, `SelectionStrategyConfig` — they're replaced by the new versions above.

- [ ] **Step 4: Build to verify**

Run: `msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /v:minimal`

Expected: Build will FAIL because `MethodParameters.cs`, `Parameter.cs`, test files, etc. still reference old classes (`GlobalParameters`, `PrecursorSelectionParameters`, `AcquisitionModesConfig`, etc.). This is expected — we'll fix those in later tasks. The point is to verify the new classes compile syntactically.

To verify syntax only, temporarily comment out the body of `InitializeIDA()` and any lines in `MethodParameters.cs` that reference deleted classes. Or just verify there are no errors in `MethodConfig.cs` itself by checking the error list.

- [ ] **Step 5: Commit (WIP)**

```bash
git add FlashIDA/src/Flash/MethodConfig.cs
git commit -m "WIP: Replace XML config classes with JSON schema classes"
```

---

## Task 3: MethodConfigSerializer

**Files:**
- Create: `FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs`
- Modify: `FlashIDA/src/Flash/Flash.csproj`

The serializer uses reflection to route `[Developer]`-tagged properties to/from a `developer` section in the JSON, and uses `[JsonKey]` for property-to-JSON-key mapping.

- [ ] **Step 1: Create MethodConfigSerializer.cs**

```csharp
using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Web.Script.Serialization;
using Flash.IDA;

namespace Flash
{
    /// <summary>
    /// Custom JSON serializer/deserializer that routes [Developer]-tagged
    /// properties to/from a separate "developer" section in the JSON file.
    /// Uses [JsonKey] attributes for property-to-JSON-key mapping.
    /// </summary>
    public static class MethodConfigSerializer
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        /// <summary>
        /// Deserialize a JSON string into a MethodConfig object.
        /// [Developer]-tagged properties are read from the "developer" section.
        /// </summary>
        public static MethodConfig Deserialize(string json)
        {
            var raw = Serializer.Deserialize<Dictionary<string, object>>(json);
            var devSection = raw.ContainsKey("developer")
                ? (Dictionary<string, object>)raw["developer"]
                : new Dictionary<string, object>();

            var config = new MethodConfig();
            PopulateObject(config, raw, devSection);
            return config;
        }

        /// <summary>
        /// Serialize a MethodConfig object to a JSON string.
        /// [Developer]-tagged properties are written to a "developer" section.
        /// </summary>
        public static string Serialize(MethodConfig config)
        {
            var main = new Dictionary<string, object>();
            var dev = new Dictionary<string, object>();

            SerializeObject(config, main, dev);

            if (dev.Count > 0)
                main["developer"] = dev;

            return Serializer.Serialize(main);
        }

        private static void PopulateObject(object target, Dictionary<string, object> mainSection,
            Dictionary<string, object> devSection)
        {
            foreach (var prop in target.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                if (keyAttr == null) continue;

                string jsonKey = keyAttr.Key;
                bool isDev = prop.GetCustomAttribute<DeveloperAttribute>() != null;

                // Determine which section to read from
                var classKey = GetClassJsonKey(target.GetType());
                Dictionary<string, object> source;

                if (isDev)
                {
                    // Developer properties: read from developer.<class_key>.<prop_key>
                    if (classKey != null && devSection.ContainsKey(classKey))
                        source = (Dictionary<string, object>)devSection[classKey];
                    else
                        source = new Dictionary<string, object>();
                }
                else
                {
                    source = mainSection;
                }

                if (!source.ContainsKey(jsonKey)) continue;

                object rawValue = source[jsonKey];

                if (rawValue == null) continue;

                Type propType = prop.PropertyType;

                // Nested config object (has [JsonKey] on class)
                if (propType.GetCustomAttribute<JsonKeyAttribute>() != null && rawValue is Dictionary<string, object> nestedDict)
                {
                    object nested = prop.GetValue(target) ?? Activator.CreateInstance(propType);
                    PopulateObject(nested, nestedDict, devSection);
                    prop.SetValue(target, nested);
                }
                // List<T> of nested objects (e.g., List<MS2Parameters>)
                else if (propType.IsGenericType && propType.GetGenericTypeDefinition() == typeof(List<>)
                    && rawValue is ArrayList rawList)
                {
                    Type itemType = propType.GetGenericArguments()[0];
                    var list = (IList)Activator.CreateInstance(propType);
                    foreach (var item in rawList)
                    {
                        if (item is Dictionary<string, object> itemDict)
                        {
                            object listItem = Activator.CreateInstance(itemType);
                            PopulateStructOrObject(listItem, itemDict, itemType);
                            list.Add(listItem);
                        }
                    }
                    prop.SetValue(target, list);
                }
                // double[] array
                else if (propType == typeof(double[]) && rawValue is ArrayList arr)
                {
                    var result = new double[arr.Count];
                    for (int i = 0; i < arr.Count; i++)
                        result[i] = Convert.ToDouble(arr[i]);
                    prop.SetValue(target, result);
                }
                // List<string>
                else if (propType == typeof(List<string>) && rawValue is ArrayList strArr)
                {
                    var result = new List<string>();
                    foreach (var item in strArr)
                        result.Add(item?.ToString() ?? "");
                    prop.SetValue(target, result);
                }
                // Struct (MS1Parameters, MS2Parameters, MS3Parameters)
                else if (propType.IsValueType && !propType.IsPrimitive && propType != typeof(decimal)
                    && rawValue is Dictionary<string, object> structDict)
                {
                    object boxed = prop.GetValue(target);
                    PopulateStructOrObject(boxed, structDict, propType);
                    prop.SetValue(target, boxed);
                }
                // Primitive types
                else
                {
                    prop.SetValue(target, ConvertValue(rawValue, propType));
                }
            }

            // Also populate nested config objects that are properties of MethodConfig
            foreach (var prop in target.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                if (keyAttr == null) continue;
                if (prop.GetCustomAttribute<DeveloperAttribute>() != null) continue;

                string jsonKey = keyAttr.Key;
                Type propType = prop.PropertyType;

                // If this property type has [JsonKey] on the class, it's a nested config section
                if (propType.GetCustomAttribute<JsonKeyAttribute>() != null
                    && mainSection.ContainsKey(jsonKey)
                    && mainSection[jsonKey] is Dictionary<string, object> sectionDict)
                {
                    object nested = prop.GetValue(target) ?? Activator.CreateInstance(propType);
                    PopulateObject(nested, sectionDict, devSection);
                    prop.SetValue(target, nested);
                }
            }
        }

        /// <summary>
        /// Populate a struct or plain object from a dictionary using field name matching.
        /// Used for MS1Parameters, MS2Parameters, MS3Parameters which use public fields.
        /// </summary>
        private static void PopulateStructOrObject(object target, Dictionary<string, object> dict, Type type)
        {
            // Try public fields (structs like MS1Parameters use fields)
            foreach (var field in type.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                // Check for [JsonKey] first, fall back to field name (case-insensitive)
                string key = null;
                var keyAttr = field.GetCustomAttribute<JsonKeyAttribute>();
                if (keyAttr != null)
                    key = keyAttr.Key;
                else
                {
                    // Case-insensitive lookup
                    foreach (var k in dict.Keys)
                    {
                        if (k.Equals(field.Name, StringComparison.OrdinalIgnoreCase))
                        {
                            key = k;
                            break;
                        }
                    }
                }

                if (key != null && dict.ContainsKey(key))
                    field.SetValue(target, ConvertValue(dict[key], field.FieldType));
            }

            // Try public properties
            foreach (var prop in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!prop.CanWrite) continue;
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                string key = keyAttr?.Key;
                if (key == null)
                {
                    foreach (var k in dict.Keys)
                    {
                        if (k.Equals(prop.Name, StringComparison.OrdinalIgnoreCase))
                        {
                            key = k;
                            break;
                        }
                    }
                }

                if (key != null && dict.ContainsKey(key))
                    prop.SetValue(target, ConvertValue(dict[key], prop.PropertyType));
            }
        }

        private static object ConvertValue(object raw, Type targetType)
        {
            if (raw == null) return targetType.IsValueType ? Activator.CreateInstance(targetType) : null;
            if (targetType == typeof(string)) return raw.ToString();
            if (targetType == typeof(bool)) return Convert.ToBoolean(raw);
            if (targetType == typeof(int)) return Convert.ToInt32(raw);
            if (targetType == typeof(double)) return Convert.ToDouble(raw);
            if (targetType == typeof(float)) return Convert.ToSingle(raw);
            return raw;
        }

        private static string GetClassJsonKey(Type type)
        {
            var attr = type.GetCustomAttribute<JsonKeyAttribute>();
            return attr?.Key;
        }

        private static void SerializeObject(object source, Dictionary<string, object> main,
            Dictionary<string, object> dev)
        {
            foreach (var prop in source.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                if (keyAttr == null) continue;

                string jsonKey = keyAttr.Key;
                bool isDev = prop.GetCustomAttribute<DeveloperAttribute>() != null;
                object value = prop.GetValue(source);

                Type propType = prop.PropertyType;

                // Nested config object with its own [JsonKey] class attribute
                if (propType.GetCustomAttribute<JsonKeyAttribute>() != null)
                {
                    var childMain = new Dictionary<string, object>();
                    var childDev = new Dictionary<string, object>();
                    if (value != null)
                        SerializeObject(value, childMain, childDev);

                    if (childMain.Count > 0)
                        main[jsonKey] = childMain;

                    // Merge child dev into parent dev under the class key
                    string classKey = GetClassJsonKey(propType);
                    if (childDev.Count > 0 && classKey != null)
                    {
                        if (!dev.ContainsKey(classKey))
                            dev[classKey] = new Dictionary<string, object>();
                        foreach (var kv in childDev)
                            ((Dictionary<string, object>)dev[classKey])[kv.Key] = kv.Value;
                    }
                    continue;
                }

                // Determine target dictionary
                if (isDev)
                {
                    string classKey = GetClassJsonKey(source.GetType());
                    if (classKey != null)
                    {
                        if (!dev.ContainsKey(classKey))
                            dev[classKey] = new Dictionary<string, object>();
                        ((Dictionary<string, object>)dev[classKey])[jsonKey] = SerializeValue(value);
                    }
                }
                else
                {
                    main[jsonKey] = SerializeValue(value);
                }
            }
        }

        private static object SerializeValue(object value)
        {
            if (value == null) return null;
            Type type = value.GetType();

            if (type == typeof(string) || type.IsPrimitive || type == typeof(decimal))
                return value;

            if (type == typeof(double[]))
                return value;

            if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(List<>))
            {
                var list = (IList)value;
                if (list.Count == 0) return new ArrayList();

                Type itemType = type.GetGenericArguments()[0];
                if (itemType == typeof(string))
                    return value;

                // List of structs/objects — serialize each
                var result = new ArrayList();
                foreach (var item in list)
                    result.Add(SerializeStructOrObject(item));
                return result;
            }

            // Struct (MS1Parameters etc.)
            if (type.IsValueType && !type.IsPrimitive)
                return SerializeStructOrObject(value);

            return value;
        }

        private static Dictionary<string, object> SerializeStructOrObject(object source)
        {
            var dict = new Dictionary<string, object>();
            Type type = source.GetType();

            foreach (var field in type.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                var keyAttr = field.GetCustomAttribute<JsonKeyAttribute>();
                string key = keyAttr?.Key ?? field.Name;
                dict[key] = field.GetValue(source);
            }

            foreach (var prop in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!prop.CanRead) continue;
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                string key = keyAttr?.Key ?? prop.Name;
                dict[key] = prop.GetValue(source);
            }

            return dict;
        }
    }
}
```

- [ ] **Step 2: Add to Flash.csproj**

In `FlashIDA/src/Flash/Flash.csproj`, in the `<Compile>` group, add:

```xml
    <Compile Include="IDA\MethodConfigSerializer.cs" />
```

- [ ] **Step 3: Build to verify**

Run: `msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /v:minimal`

Expected: Build succeeds (serializer has no dependencies on other changes).

- [ ] **Step 4: Commit**

```bash
git add FlashIDA/src/Flash/IDA/MethodConfigSerializer.cs FlashIDA/src/Flash/Flash.csproj
git commit -m "Add MethodConfigSerializer with [Developer]-aware JSON routing"
```

---

## Task 4: Create JSON Test Configs

**Files:**
- Create: `FlashIDA/test-data/configs/method_default.json`
- Create: `FlashIDA/test-data/configs/method_json_roundtrip.json`
- Create: all other `method_*.json` files (18 more)

Convert each XML config to the user-facing JSON format. Developer-tagged properties go in the `developer` section. The JSON keys match the `[JsonKey]` attributes from Task 2.

- [ ] **Step 1: Create method_default.json**

```json
{
  "global": {
    "method_name": "MethodName",
    "method_description": "Description",
    "duration": 120
  },
  "deconvolution": {
    "score_threshold": 0.0,
    "tqscore_threshold": 0.9,
    "min_charge": 4,
    "max_charge": 50,
    "min_mass": 500,
    "max_mass": 50000,
    "tol": [10, 10]
  },
  "precursor_selection": {
    "rt_window": 180,
    "targeting_mode": "none",
    "strict_inclusion": false,
    "tie_threshold": 0.1
  },
  "tagging": {
    "active": false,
    "conditional_ms2": false,
    "min_tag_length": 3,
    "max_tag_length": 8,
    "max_ptm_count": 3,
    "max_flanking_mass_diff": 50000
  },
  "quantification": {
    "active": false,
    "reporter_mz_tol": 0.002,
    "fold_change_threshold": 1.4,
    "only_one_condition": false
  },
  "faims": {
    "cv_values": [-50]
  },
  "ms_settings": {
    "ms1": {
      "Analyzer": "Orbitrap",
      "FirstMass": 500,
      "LastMass": 2000,
      "OrbitrapResolution": 120000,
      "AGCTarget": 800000,
      "MaxIT": 246,
      "Microscans": 1,
      "DataType": "Centroid",
      "RFLens": 30,
      "SourceCID": 15,
      "SourceCIDScaling": 0
    },
    "ms2": [
      {
        "Analyzer": "Orbitrap",
        "FirstMass": 100,
        "LastMass": 2000,
        "OrbitrapResolution": 120000,
        "AGCTarget": 500000,
        "MaxIT": 100,
        "Microscans": 4,
        "DataType": "Centroid",
        "Activation": "ETD",
        "ReactionTime": 7,
        "ReagentAGCTarget": 700000,
        "ReagentMaxIT": 200,
        "CollisionEnergy": 0
      }
    ],
    "ms3": [
      {
        "Analyzer": "Orbitrap",
        "IsolationMode": "Quadrupole",
        "FirstMass": 200,
        "LastMass": 2000,
        "OrbitrapResolution": 240000,
        "AGCTarget": 50000000,
        "MaxIT": 500,
        "Microscans": 8,
        "DataType": "Centroid",
        "Activation": "CID",
        "CollisionEnergy": 25
      }
    ]
  },
  "scheduling": {
    "cycle_time_enabled": false,
    "cycle_time_ms": 60000,
    "timeout_enabled": false,
    "timeout_ms": 30000
  },
  "selection_strategy": {
    "ms1": {
      "selection": "qscore",
      "max_precursors": 1
    },
    "ms2": {
      "selection": "intensity"
    },
    "ms3": {
      "selection": "none"
    }
  },
  "ms3": {
    "active": false,
    "mode": 1,
    "max_per_ms2": 1000,
    "all_charges": true,
    "protein_sequence": "SEQUENCE"
  },
  "files": {
    "target_logs": [],
    "fasta": "",
    "inclusion_list": "",
    "ptm_list": ""
  },
  "developer": {
    "precursor_selection": {
      "use_id_score": false,
      "consider_all_charges": false,
      "ms3_all_charges": false,
      "hcd_energy": 29
    },
    "faims": {
      "max_cv_skip": 0,
      "mass_threshold": 15
    }
  }
}
```

- [ ] **Step 2: Create method_json_roundtrip.json**

This config has non-default values and multiple MS2 entries:

```json
{
  "global": {
    "method_name": "JsonRoundTrip",
    "method_description": "Phase 1 JSON round-trip test: non-default values, multiple MS2, FAIMS CVs",
    "duration": 180
  },
  "deconvolution": {
    "score_threshold": 0.5,
    "tqscore_threshold": 0.85,
    "min_charge": 5,
    "max_charge": 40,
    "min_mass": 600,
    "max_mass": 40000,
    "tol": [8, 12]
  },
  "precursor_selection": {
    "rt_window": 120,
    "targeting_mode": "none",
    "strict_inclusion": true,
    "tie_threshold": 0.2
  },
  "tagging": {
    "active": false,
    "conditional_ms2": false,
    "min_tag_length": 4,
    "max_tag_length": 10,
    "max_ptm_count": 5,
    "max_flanking_mass_diff": 40000
  },
  "quantification": {
    "active": false,
    "reporter_mz_tol": 0.003,
    "fold_change_threshold": 2.0,
    "only_one_condition": true
  },
  "faims": {
    "cv_values": [-40, -50, -60]
  },
  "ms_settings": {
    "ms1": {
      "Analyzer": "Orbitrap",
      "FirstMass": 400,
      "LastMass": 2500,
      "OrbitrapResolution": 240000,
      "AGCTarget": 1000000,
      "MaxIT": 300,
      "Microscans": 2,
      "DataType": "Centroid",
      "RFLens": 35,
      "SourceCID": 20,
      "SourceCIDScaling": 0
    },
    "ms2": [
      {
        "Analyzer": "Orbitrap",
        "FirstMass": 150,
        "LastMass": 2500,
        "OrbitrapResolution": 120000,
        "AGCTarget": 500000,
        "MaxIT": 150,
        "Microscans": 4,
        "DataType": "Centroid",
        "Activation": "HCD",
        "CollisionEnergy": 35
      },
      {
        "Analyzer": "Orbitrap",
        "FirstMass": 100,
        "LastMass": 2000,
        "OrbitrapResolution": 60000,
        "AGCTarget": 300000,
        "MaxIT": 100,
        "Microscans": 2,
        "DataType": "Centroid",
        "Activation": "ETD",
        "ReactionTime": 10,
        "ReagentAGCTarget": 700000,
        "ReagentMaxIT": 200,
        "CollisionEnergy": 0
      }
    ],
    "ms3": [
      {
        "Analyzer": "Orbitrap",
        "IsolationMode": "Quadrupole",
        "FirstMass": 200,
        "LastMass": 2000,
        "OrbitrapResolution": 240000,
        "AGCTarget": 50000000,
        "MaxIT": 500,
        "Microscans": 8,
        "DataType": "Centroid",
        "Activation": "CID",
        "CollisionEnergy": 30
      }
    ]
  },
  "scheduling": {
    "cycle_time_enabled": false,
    "cycle_time_ms": 60000,
    "timeout_enabled": false,
    "timeout_ms": 30000
  },
  "selection_strategy": {
    "ms1": {
      "selection": "qscore",
      "max_precursors": 3
    },
    "ms2": {
      "selection": "intensity"
    },
    "ms3": {
      "selection": "none"
    }
  },
  "ms3": {
    "active": false,
    "mode": 2,
    "max_per_ms2": 500,
    "all_charges": false,
    "protein_sequence": "TESTSEQUENCE"
  },
  "files": {
    "target_logs": [],
    "fasta": "",
    "inclusion_list": "",
    "ptm_list": ""
  },
  "developer": {
    "precursor_selection": {
      "use_id_score": true,
      "consider_all_charges": true,
      "ms3_all_charges": false,
      "hcd_energy": 35
    },
    "faims": {
      "max_cv_skip": 2,
      "mass_threshold": 20
    }
  }
}
```

- [ ] **Step 3: Create remaining JSON configs**

For each of the remaining 18 XML configs, create a corresponding JSON file following the same structure. The key differences per file (read the XML source and translate):

| JSON file | Key differences from `method_default.json` |
|-----------|---------------------------------------------|
| `method_default_topn5.json` | `selection_strategy.ms1.max_precursors`: 5 |
| `method_default_legacy.json` | Same as default (legacy XML format test — may not be needed in JSON world; create with default values) |
| `method_inclusion.json` | `precursor_selection.targeting_mode`: "inclusion", `files.inclusion_list` populated |
| `method_inclusion_strict.json` | Same as inclusion + `precursor_selection.strict_inclusion`: true |
| `method_exclusion.json` | `precursor_selection.targeting_mode`: "exclusion", `files.target_logs` populated |
| `method_deep.json` | `precursor_selection.targeting_mode`: "deep" |
| `method_faims_3cv.json` | `faims.cv_values`: [-40, -50, -60] |
| `method_faims_skip.json` | `faims.cv_values`: [-40, -50, -60], `developer.faims.max_cv_skip`: 2 |
| `method_quant.json` | `quantification.active`: true, with quant values |
| `method_tag_targeting.json` | `tagging.active`: true, `tagging.conditional_ms2`: true, `files.fasta` and `files.ptm_list` populated |
| `method_ms3_mode1.json` | `ms3.active`: true, `ms3.mode`: 1 |
| `method_ms3_mode1_hcd.json` | Same + HCD activation MS2 |
| `method_ms3_mode2.json` | `ms3.active`: true, `ms3.mode`: 2 |
| `method_ms3_mode2_hcd.json` | Same + HCD activation MS2 |
| `method_ms3_mode3.json` | `ms3.active`: true, `ms3.mode`: 3 |
| `method_ms3_mode3_hcd.json` | Same + HCD activation MS2 |
| `method_exploration.json` | `selection_strategy.ms2.exploration` block with `metric`: "intensity" |
| `method_exploration_ms3.json` | Same + `selection_strategy.ms3.exploration` block |

Read each XML file from `FlashIDA/test-data/configs/` and translate all values. Every field must match the XML source exactly. Use `method_default.json` as the template and modify only the differing fields.

- [ ] **Step 4: Commit**

```bash
git add FlashIDA/test-data/configs/method_*.json
git commit -m "Add JSON test configs (converted from XML)"
```

---

## Task 5: ToCppJson() Transform + Golden File Tests

**Files:**
- Modify: `FlashIDA/src/Flash/MethodParameters.cs`
- Modify: `FlashIDA/src/Flash.Tests/JsonConfigTests.cs`

Add `ToCppJson()` to `MethodParameters` that transforms `MethodConfig` → C++ JSON format. Test by comparing output to existing golden files.

- [ ] **Step 1: Add ToCppJson() to MethodParameters**

In `MethodParameters.cs`, add the following method. This replaces `IDAParameters.ToJSON()` + `InitializeIDA()`:

```csharp
        /// <summary>
        /// Transform user-facing MethodConfig to C++ engine JSON format.
        /// Replaces the old InitializeIDA() + IDA.ToJSON() pipeline.
        /// </summary>
        public string ToCppJson()
        {
            var c = Config;

            // Map targeting_mode string → int
            int targetMode;
            switch (c.PrecursorSelection.TargetingMode?.ToLower())
            {
                case "deep": targetMode = 3; break;
                case "exclusion": targetMode = 2; break;
                case "inclusion": targetMode = 1; break;
                default: targetMode = 0; break;
            }

            var ms2List = c.MsSettings.MS2 ?? new List<MS2Parameters>();

            var config = new JsonMethodConfig
            {
                deconvolution = new JsonDeconvolutionConfig
                {
                    score_threshold = c.Deconvolution.ScoreThreshold,
                    tqscore_threshold = c.Deconvolution.TQScoreThreshold,
                    min_charge = c.Deconvolution.MinCharge,
                    max_charge = c.Deconvolution.MaxCharge,
                    min_mass = c.Deconvolution.MinMass,
                    max_mass = c.Deconvolution.MaxMass,
                    tol = c.Deconvolution.Tolerances
                },
                precursor_selection = new JsonPrecursorSelectionConfig
                {
                    RT_window = c.PrecursorSelection.RTWindow,
                    target_mode = targetMode,
                    IDScore = c.PrecursorSelection.UseIDScore,
                    AllCharges = c.PrecursorSelection.ConsiderAllChargeStates,
                    MS3AllCharges = c.PrecursorSelection.MS3AllCharges,
                    HCDEnergy = c.PrecursorSelection.HCDEnergy,
                    strict_inclusion = c.PrecursorSelection.StrictInclusion,
                    tie_threshold = c.PrecursorSelection.TieThreshold
                },
                tagging = new JsonTaggingConfig
                {
                    min_tag_length = c.Tagging.MinTagLength,
                    max_tag_length = c.Tagging.MaxTagLength,
                    max_ptm_count = c.Tagging.MaxPtmCount,
                    max_flanking_mass_diff = c.Tagging.MaxFlankingMassDiff
                },
                quantification = new JsonQuantificationConfig
                {
                    enabled = c.Quantification.Active,
                    reporter_mz_tol = c.Quantification.ReporterMZTol,
                    fold_change_threshold = c.Quantification.FoldChangeThreshold
                },
                faims = new JsonFaimsConfig
                {
                    cv_values = c.Faims.CVValues,
                    max_cv_skip = c.Faims.MaxCVSkip,
                    cv_precursor_threshold = c.Faims.MassThreshold
                },
                ms_settings = new JsonMsSettingsConfig
                {
                    ms1 = new JsonMs1Config
                    {
                        analyzer = c.MsSettings.MS1.Analyzer ?? "",
                        first_mass = c.MsSettings.MS1.FirstMass,
                        last_mass = c.MsSettings.MS1.LastMass,
                        resolution = c.MsSettings.MS1.OrbitrapResolution,
                        agc_target = c.MsSettings.MS1.AGCTarget,
                        max_it = c.MsSettings.MS1.MaxIT
                    },
                    ms2 = ms2List.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution
                    }).ToArray()
                },
                scheduling = new JsonSchedulingConfig
                {
                    cycle_time = new JsonCycleTimeConfig
                    {
                        enabled = c.Scheduling.CycleTimeEnabled,
                        value_ms = c.Scheduling.CycleTimeMs
                    },
                    scan_timeout = new JsonScanTimeoutConfig
                    {
                        enabled = c.Scheduling.TimeoutEnabled,
                        value_ms = c.Scheduling.TimeoutMs
                    },
                    agc_interval_seconds = 30
                },
                exploration = new JsonExplorationConfig
                {
                    enabled = false,
                    max_depth = 1,
                    max_variants = 5
                },
                selection_strategy = BuildSelectionStrategy(),
                ms3 = new JsonMs3Config
                {
                    enabled = c.Ms3.Active,
                    mode = c.Ms3.Mode,
                    max_per_ms2 = c.Ms3.MaxPerMs2,
                    protein_sequence = c.Ms3.ProteinSequence ?? ""
                },
                conditional_ms2 = c.Tagging.ConditionalMS2,
                files = new JsonFilesConfig
                {
                    target_logs = (c.Files.TargetLogs ?? new List<string>()).ToArray(),
                    fasta = c.Files.FastaFile ?? "",
                    inclusion_list = c.Files.InclusionList ?? "",
                    ptm_list = c.Files.PtmList ?? ""
                }
            };

            return new JavaScriptSerializer().Serialize(config);
        }

        /// <summary>
        /// Build selection_strategy JSON for C++ from MethodConfig.SelectionStrategy.
        /// </summary>
        private JsonSelectionStrategyConfig BuildSelectionStrategy()
        {
            var ss = Config.SelectionStrategy;
            if (ss == null)
                throw new InvalidOperationException(
                    "Method config must contain selection_strategy block.");

            int ms1Max = ss.MS1?.MaxPrecursors ?? 10;
            int ms2Max = ss.MS2?.MaxFragments ?? 3;
            int ms3Max = ss.MS3?.MaxFragments ?? 3;

            var result = new JsonSelectionStrategyConfig
            {
                ms1 = new JsonMsLevelConfig
                {
                    selection = (ss.MS1?.Selection ?? "qscore").ToLower(),
                    max_precursors = ms1Max,
                    max_fragments = ms1Max
                },
                ms2 = new JsonMsLevelConfig
                {
                    selection = (ss.MS2?.Selection ?? "intensity").ToLower(),
                    max_precursors = ms2Max,
                    max_fragments = ms2Max
                },
                ms3 = new JsonMsLevelConfig
                {
                    selection = (ss.MS3?.Selection ?? "none").ToLower(),
                    max_precursors = ms3Max,
                    max_fragments = ms3Max
                }
            };

            // Always emit exploration blocks (null crashes C++ nlohmann::json)
            var defaultExpl = new JsonExplorationBlockConfig
            {
                metric = "none", ce_min = 20, ce_max = 40, ce_step = 5, activation = "HCD"
            };
            result.ms1.exploration = defaultExpl;
            result.ms2.exploration = defaultExpl;
            result.ms3.exploration = defaultExpl;

            if (ss.MS2?.Exploration != null && ss.MS2.Exploration.Metric != "none")
            {
                result.ms2.exploration = new JsonExplorationBlockConfig
                {
                    metric = ss.MS2.Exploration.Metric.ToLower(),
                    ce_min = ss.MS2.Exploration.CEMin,
                    ce_max = ss.MS2.Exploration.CEMax,
                    ce_step = ss.MS2.Exploration.CEStep,
                    activation = ss.MS2.Exploration.Activation ?? "HCD"
                };
            }

            if (ss.MS3?.Exploration != null && ss.MS3.Exploration.Metric != "none")
            {
                result.ms3.exploration = new JsonExplorationBlockConfig
                {
                    metric = ss.MS3.Exploration.Metric.ToLower(),
                    ce_min = ss.MS3.Exploration.CEMin,
                    ce_max = ss.MS3.Exploration.CEMax,
                    ce_step = ss.MS3.Exploration.CEStep,
                    activation = ss.MS3.Exploration.Activation ?? "CID"
                };
            }

            return result;
        }
```

Also add `using System.Linq;` and `using System.Web.Script.Serialization;` to the top of `MethodParameters.cs` if not already present.

- [ ] **Step 2: Rewrite JsonConfigTests to test ToCppJson() against golden files**

Replace the content of `FlashIDA/src/Flash.Tests/JsonConfigTests.cs` with:

```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using Flash;
using NUnit.Framework;

namespace Flash.Tests
{
    [TestFixture]
    public class JsonConfigTests
    {
        private static readonly string TestDataDir = Path.Combine(
            TestContext.CurrentContext.TestDirectory, "..", "test-data");

        private static readonly string ConfigsDir = Path.Combine(TestDataDir, "configs");

        private MethodParameters LoadJsonMethod(string jsonName)
        {
            string path = Path.Combine(ConfigsDir, jsonName);
            Assert.IsTrue(File.Exists(path), "Test config not found: " + path);
            return MethodParameters.Load(path);
        }

        [Test, Category("Tier1")]
        public void ToCppJson_ProducesValidJson()
        {
            var mp = LoadJsonMethod("method_default.json");
            string json = mp.ToCppJson();

            Assert.IsNotNull(json);
            Assert.IsNotEmpty(json);
            Assert.IsTrue(json.StartsWith("{"), "JSON must start with '{'");

            var serializer = new JavaScriptSerializer();
            var parsed = serializer.Deserialize<Dictionary<string, object>>(json);
            Assert.IsNotNull(parsed, "JSON could not be deserialized");
        }

        [Test, Category("Tier1")]
        public void ToCppJson_ContainsAllTopLevelKeys()
        {
            var mp = LoadJsonMethod("method_default.json");
            string json = mp.ToCppJson();

            var serializer = new JavaScriptSerializer();
            var parsed = serializer.Deserialize<Dictionary<string, object>>(json);

            string[] requiredKeys = new[]
            {
                "deconvolution", "precursor_selection", "tagging",
                "quantification", "faims", "ms_settings",
                "scheduling", "exploration", "files"
            };

            foreach (var key in requiredKeys)
                Assert.IsTrue(parsed.ContainsKey(key), "Missing key: " + key);
        }

        [Test, Category("Tier1")]
        public void ToCppJson_DefaultMatchesGoldenFile()
        {
            var mp = LoadJsonMethod("method_default.json");
            string json = mp.ToCppJson();

            string goldenPath = Path.Combine(TestDataDir, "json", "config_default.json");
            Assert.IsTrue(File.Exists(goldenPath), "Golden file not found: " + goldenPath);

            string goldenJson = File.ReadAllText(goldenPath);
            var serializer = new JavaScriptSerializer();
            var actual = serializer.Deserialize<Dictionary<string, object>>(json);
            var expected = serializer.Deserialize<Dictionary<string, object>>(goldenJson);

            CompareJsonSection(actual, expected, "deconvolution",
                "score_threshold", "tqscore_threshold", "min_charge", "max_charge",
                "min_mass", "max_mass", "tol");
            CompareJsonSection(actual, expected, "precursor_selection",
                "RT_window", "target_mode", "IDScore", "AllCharges",
                "MS3AllCharges", "HCDEnergy", "strict_inclusion", "tie_threshold");
            CompareJsonSection(actual, expected, "tagging",
                "min_tag_length", "max_tag_length", "max_ptm_count", "max_flanking_mass_diff");
        }

        [Test, Category("Tier1")]
        public void ToCppJson_FullMatchesGoldenFile()
        {
            var mp = LoadJsonMethod("method_json_roundtrip.json");
            string json = mp.ToCppJson();

            string goldenPath = Path.Combine(TestDataDir, "json", "config_full.json");
            Assert.IsTrue(File.Exists(goldenPath), "Golden file not found: " + goldenPath);

            string goldenJson = File.ReadAllText(goldenPath);
            var serializer = new JavaScriptSerializer();
            var actual = serializer.Deserialize<Dictionary<string, object>>(json);
            var expected = serializer.Deserialize<Dictionary<string, object>>(goldenJson);

            CompareJsonSection(actual, expected, "deconvolution",
                "score_threshold", "tqscore_threshold", "min_charge", "max_charge",
                "min_mass", "max_mass", "tol");
            CompareJsonSection(actual, expected, "precursor_selection",
                "RT_window", "target_mode", "IDScore", "AllCharges",
                "HCDEnergy", "strict_inclusion", "tie_threshold");

            // Verify multiple MS2 entries
            var msSettings = (Dictionary<string, object>)actual["ms_settings"];
            var ms2Array = (System.Collections.ArrayList)msSettings["ms2"];
            Assert.AreEqual(2, ms2Array.Count, "Should have 2 MS2 entries");

            // Verify FAIMS
            var faims = (Dictionary<string, object>)actual["faims"];
            var cvValues = (System.Collections.ArrayList)faims["cv_values"];
            Assert.AreEqual(3, cvValues.Count, "Should have 3 FAIMS CVs");
        }

        [Test, Category("Tier1")]
        public void Deserialize_DeveloperRouting()
        {
            var mp = LoadJsonMethod("method_json_roundtrip.json");

            // Developer properties should be populated from developer section
            Assert.IsTrue(mp.Config.PrecursorSelection.UseIDScore,
                "UseIDScore should be true (from developer section)");
            Assert.AreEqual(35, mp.Config.PrecursorSelection.HCDEnergy,
                "HCDEnergy should be 35 (from developer section)");
            Assert.AreEqual(2, mp.Config.Faims.MaxCVSkip,
                "MaxCVSkip should be 2 (from developer section)");
        }

        [Test, Category("Tier1")]
        public void Deserialize_RoundTrip()
        {
            var mp = LoadJsonMethod("method_default.json");
            string serialized = MethodConfigSerializer.Serialize(mp.Config);
            var config2 = MethodConfigSerializer.Deserialize(serialized);

            Assert.AreEqual(mp.Config.Deconvolution.MinCharge, config2.Deconvolution.MinCharge);
            Assert.AreEqual(mp.Config.Deconvolution.MaxCharge, config2.Deconvolution.MaxCharge);
            Assert.AreEqual(mp.Config.PrecursorSelection.RTWindow, config2.PrecursorSelection.RTWindow);
            Assert.AreEqual(mp.Config.PrecursorSelection.HCDEnergy, config2.PrecursorSelection.HCDEnergy);
            Assert.AreEqual(mp.Config.Faims.CVValues.Length, config2.Faims.CVValues.Length);
        }

        private static void CompareJsonSection(
            Dictionary<string, object> actual,
            Dictionary<string, object> expected,
            string section,
            params string[] fields)
        {
            var actSection = (Dictionary<string, object>)actual[section];
            var expSection = (Dictionary<string, object>)expected[section];
            foreach (var field in fields)
            {
                var exp = expSection[field];
                var act = actSection[field];
                if (exp is bool)
                    Assert.AreEqual((bool)exp, (bool)act,
                        string.Format("{0}.{1} mismatch", section, field));
                else if (exp is System.Collections.ArrayList)
                    CompareJsonArray((System.Collections.ArrayList)exp,
                        (System.Collections.ArrayList)act,
                        string.Format("{0}.{1}", section, field));
                else
                    Assert.AreEqual(Convert.ToDouble(exp), Convert.ToDouble(act), 0.001,
                        string.Format("{0}.{1} mismatch", section, field));
            }
        }

        private static void CompareJsonArray(System.Collections.ArrayList expected,
            System.Collections.ArrayList actual, string path)
        {
            Assert.AreEqual(expected.Count, actual.Count, path + " length mismatch");
            for (int i = 0; i < expected.Count; i++)
                Assert.AreEqual(Convert.ToDouble(expected[i]), Convert.ToDouble(actual[i]), 0.001,
                    string.Format("{0}[{1}] mismatch", path, i));
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add FlashIDA/src/Flash/MethodParameters.cs FlashIDA/src/Flash.Tests/JsonConfigTests.cs
git commit -m "Add ToCppJson() transform and golden file tests"
```

---

## Task 6: Wire Up Pipeline (MethodParameters.Load, FLASHIdaWrapper, Flash.cs)

**Files:**
- Modify: `FlashIDA/src/Flash/MethodParameters.cs`
- Modify: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:115-118`
- Modify: `FlashIDA/src/Flash/Flash.cs:316,329-330,368,394-409`
- Modify: `FlashIDA/src/Flash/Flash.csproj:128-131`

- [ ] **Step 1: Rewrite MethodParameters.Load() for JSON**

Replace the existing `Load()` method in `MethodParameters.cs`:

```csharp
        /// <summary>
        /// Deserialize MethodParameters from a JSON config file.
        /// </summary>
        public static MethodParameters Load(string path)
        {
            string json = File.ReadAllText(path);
            var mp = new MethodParameters();
            mp.Config = MethodConfigSerializer.Deserialize(json);
            return mp;
        }
```

- [ ] **Step 2: Remove InitializeIDA(), IDA property, backward-compat accessors, Save()**

In `MethodParameters.cs`, remove:
- The `[XmlIgnore] public IDAParameters IDA { get; private set; }` property
- The `InitializeIDA()` method entirely
- The `Save(string path)` method
- All the XML-oriented properties (`GlobalParameter`, `PrecursorSelection`, `AcquisitionModes`, `MSSettings`, `SelectionStrategy`) and their backward-compat `[XmlIgnore]` accessors (`Duration`, `MS1`, `MS2`, `MS3`, `isobaricQuantification`)
- The `IsActive()` helper
- The default constructor that initializes XML objects

Replace with:

```csharp
    public class MethodParameters
    {
        public MethodConfig Config { get; set; }

        public MethodParameters()
        {
            Config = new MethodConfig();
        }

        public static MethodParameters Load(string path)
        {
            string json = File.ReadAllText(path);
            var mp = new MethodParameters();
            mp.Config = MethodConfigSerializer.Deserialize(json);
            return mp;
        }

        // ToCppJson() and BuildSelectionStrategy() from Task 5 go here

        // ToLogString() — updated below
    }
```

- [ ] **Step 3: Update ToLogString()**

Rewrite `ToLogString()` to read from `Config` instead of `IDA`:

```csharp
        public string ToLogString()
        {
            var sb = new StringBuilder();
            sb.AppendLine("--- Method Parameters ---");

            var c = Config;
            sb.AppendFormat("Global: Duration={0}min\n", c.Global.Duration);

            sb.AppendFormat("Deconv: QScore>={0}, TQScore>={1}, Charge=[{2},{3}], Mass=[{4},{5}], Tol=[{6}]\n",
                c.Deconvolution.ScoreThreshold, c.Deconvolution.TQScoreThreshold,
                c.Deconvolution.MinCharge, c.Deconvolution.MaxCharge,
                c.Deconvolution.MinMass, c.Deconvolution.MaxMass,
                String.Join(",", c.Deconvolution.Tolerances));

            sb.AppendFormat("Precursor: RTWindow={0}s, TargetMode={1}\n",
                c.PrecursorSelection.RTWindow, c.PrecursorSelection.TargetingMode);

            sb.AppendFormat("Inclusion: Strict={0}, TieThreshold={1}\n",
                c.PrecursorSelection.StrictInclusion, c.PrecursorSelection.TieThreshold);

            if (c.Tagging.Active)
                sb.AppendFormat("Tagging: ConditionalMS2={0}, Tags=[{1},{2}], MaxPtm={3}\n",
                    c.Tagging.ConditionalMS2, c.Tagging.MinTagLength, c.Tagging.MaxTagLength, c.Tagging.MaxPtmCount);
            else
                sb.AppendLine("Tagging: Off");

            if (c.Quantification.Active)
                sb.AppendFormat("Quant: MZTol={0}, FoldChange={1}\n",
                    c.Quantification.ReporterMZTol, c.Quantification.FoldChangeThreshold);
            else
                sb.AppendLine("Quant: Off");

            if (c.Ms3.Active)
                sb.AppendFormat("MS3: Mode={0}, MaxPerMS2={1}, AllCharges={2}\n",
                    c.Ms3.Mode, c.Ms3.MaxPerMs2, c.Ms3.AllCharges);
            else
                sb.AppendLine("MS3: Off");

            sb.AppendFormat("Developer: IDScore={0}, AllCharges={1}, HCDEnergy={2}, MaxCVSkip={3}\n",
                c.PrecursorSelection.UseIDScore, c.PrecursorSelection.ConsiderAllChargeStates,
                c.PrecursorSelection.HCDEnergy, c.Faims.MaxCVSkip);

            sb.AppendFormat("FAIMS: CV=[{0}]\n", String.Join(",", c.Faims.CVValues));

            var ms1 = c.MsSettings.MS1;
            sb.AppendFormat("MS1: {0} {1}k, mz=[{2},{3}], AGC={4}, MaxIT={5}ms\n",
                ms1.Analyzer, ms1.OrbitrapResolution / 1000, ms1.FirstMass, ms1.LastMass,
                ms1.AGCTarget, ms1.MaxIT);

            var ms2List = c.MsSettings.MS2 ?? new List<MS2Parameters>();
            for (int i = 0; i < ms2List.Count; i++)
            {
                var m = ms2List[i];
                var activation = m.Activation ?? "";
                if (activation.Equals("ETD", StringComparison.OrdinalIgnoreCase))
                    sb.AppendFormat("MS2[{0}]: {1} {2}k, {3} RT={4}ms\n",
                        i, m.Analyzer, m.OrbitrapResolution / 1000, activation, m.ReactionTime);
                else
                    sb.AppendFormat("MS2[{0}]: {1} {2}k, {3} CE={4}\n",
                        i, m.Analyzer, m.OrbitrapResolution / 1000, activation, m.CollisionEnergy);
            }

            return sb.ToString().TrimEnd();
        }
```

- [ ] **Step 4: Update FLASHIdaWrapper constructor**

In `FLASHIdaWrapper.cs` line 117, change:

```csharp
            string arg = mp.IDA.ToJSON(mp);
```

to:

```csharp
            string arg = mp.ToCppJson();
```

- [ ] **Step 5: Update Flash.cs Duration access**

In `Flash.cs`, change both Duration lines:

Line 316:
```csharp
            duration = new Timer(methodParams.Config.Global.Duration * 60000);
```

Line 368:
```csharp
            duration = new Timer(methodParams.Config.Global.Duration * 60000);
```

- [ ] **Step 6: Remove magic scan MS1 access in Flash.cs**

Lines 329-330 use `methodParams.MS1.FirstMass` and `methodParams.MS1.LastMass` for the magic scan. Change to:

```csharp
                    FirstMass = new double[] { methodParams.Config.MsSettings.MS1.FirstMass },
                    LastMass = new double[] { methodParams.Config.MsSettings.MS1.LastMass },
```

- [ ] **Step 7: Delete CustomScanListner in Flash.cs**

Remove the entire `CustomScanListner` method (lines 394-409). It's dead code that references `methodParams.MS1.*`.

- [ ] **Step 8: Update Flash.csproj method.xml → method.json**

Change line 128-131 in `Flash.csproj` from:

```xml
    <None Include="etc\method.xml">
      <Link>method.xml</Link>
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
```

to:

```xml
    <None Include="etc\method.json">
      <Link>method.json</Link>
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
```

- [ ] **Step 9: Create etc/method.json**

Create `FlashIDA/src/Flash/etc/method.json` with the same content as `method_default.json` from Task 4, but with `max_precursors: 1` (matching the old method.xml's `<MaxPrecursors>1</MaxPrecursors>`).

- [ ] **Step 10: Commit**

```bash
git add FlashIDA/src/Flash/MethodParameters.cs FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs FlashIDA/src/Flash/Flash.cs FlashIDA/src/Flash/Flash.csproj FlashIDA/src/Flash/etc/method.json
git commit -m "Wire up JSON config pipeline: Load, ToCppJson, Duration access"
```

---

## Task 7: Update Test Infrastructure

**Files:**
- Modify: `FlashIDA/src/Flash.Tests/Mocks/ContinuityTestHarness.cs`
- Modify: `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs`
- Modify: `FlashIDA/src/Flash.Tests/BridgeSmokeTests.cs`
- Modify: `FlashIDA/src/Flash.Tests/GoldenCaptureTests.cs`
- Modify: `FlashIDA/src/Flash.Tests/BridgePhase3Tests.cs`

- [ ] **Step 1: Update ContinuityTestHarness**

In `Mocks/ContinuityTestHarness.cs`, change all `MethodParams.IDA.*` references:

```csharp
// Line 49: Load now handles JSON
MethodParams = MethodParameters.Load(methodXmlPath);  // parameter name is still methodXmlPath but loads JSON

// Line 52:
double[] CVs = MethodParams.Config.Faims.CVValues;

// Lines 57-59:
ResolveRelativePath(configDir, () => MethodParams.Config.Files.InclusionList, v => MethodParams.Config.Files.InclusionList = v);
ResolveRelativePath(configDir, () => MethodParams.Config.Files.FastaFile, v => MethodParams.Config.Files.FastaFile = v);
ResolveRelativePath(configDir, () => MethodParams.Config.Files.PtmList, v => MethodParams.Config.Files.PtmList = v);

// Lines 62-72: TargetLogs
if (MethodParams.Config.Files.TargetLogs != null)
{
    for (int i = 0; i < MethodParams.Config.Files.TargetLogs.Count; i++)
    {
        string path = MethodParams.Config.Files.TargetLogs[i];
        // ... rest of resolve logic, replacing MethodParams.IDA.TargetLogs[i] with
        // MethodParams.Config.Files.TargetLogs[i]
    }
}
```

Also rename the constructor parameter from `methodXmlPath` to `methodConfigPath` for clarity.

- [ ] **Step 2: Update ContinuityTests.cs**

Change all `MethodParams.*` accessor references to use `Config`:

| Old accessor | New accessor |
|--------------|-------------|
| `harness.MethodParams.MS1.FirstMass` | `harness.MethodParams.Config.MsSettings.MS1.FirstMass` |
| `harness.MethodParams.MS1.LastMass` | `harness.MethodParams.Config.MsSettings.MS1.LastMass` |
| `harness.MethodParams.MS2` | `harness.MethodParams.Config.MsSettings.MS2` |
| `harness.MethodParams.MS2.Count` | `harness.MethodParams.Config.MsSettings.MS2.Count` |
| `harness.MethodParams.SelectionStrategy.MS1.MaxPrecursors` | `harness.MethodParams.Config.SelectionStrategy.MS1.MaxPrecursors` |
| `harness.MethodParams.IDA.CVValues` | `harness.MethodParams.Config.Faims.CVValues` |
| `harness.MethodParams.IDA.ConditionalMS2` | `harness.MethodParams.Config.Tagging.ConditionalMS2` |
| `harness.MethodParams.IDA.MaxCVSkip` | `harness.MethodParams.Config.Faims.MaxCVSkip` |

Also update `CreateHarness()` helper to pass `.json` path instead of `.xml`:

```csharp
private ContinuityTestHarness CreateHarness(string configName)
{
    // Change extension from .xml to .json
    string path = Path.Combine(ConfigsDir, configName);
    return new ContinuityTestHarness(path);
}
```

And update all `CreateHarness("method_*.xml")` calls to `CreateHarness("method_*.json")`.

- [ ] **Step 3: Update BridgeSmokeTests.cs**

Rewrite `BuildJsonConfigString()` to use the new config classes:

```csharp
        private static string BuildJsonConfigString()
        {
            var mp = new MethodParameters();
            mp.Config = new MethodConfig
            {
                Deconvolution = new DeconvolutionConfig
                {
                    ScoreThreshold = 0,
                    TQScoreThreshold = 0.9,
                    MinCharge = 4,
                    MaxCharge = 50,
                    MinMass = 500,
                    MaxMass = 50000,
                    Tolerances = new double[] { 10, 10 }
                },
                PrecursorSelection = new PrecursorSelectionConfig
                {
                    RTWindow = 180,
                    HCDEnergy = 29
                },
                Faims = new FaimsConfig { CVValues = new double[] { -50 } },
                MsSettings = new MsSettingsConfig
                {
                    MS1 = new MS1Parameters { Analyzer = "Orbitrap", FirstMass = 500, LastMass = 2000, OrbitrapResolution = 120000, AGCTarget = 800000, MaxIT = 246 },
                    MS2 = new List<MS2Parameters>
                    {
                        new MS2Parameters { Analyzer = "Orbitrap", Activation = "ETD", OrbitrapResolution = 120000, CollisionEnergy = 0 }
                    }
                },
                SelectionStrategy = new SelectionStrategyConfig
                {
                    MS1 = new MS1SelectionConfig { Selection = "qscore", MaxPrecursors = 1 },
                    MS2 = new MS2SelectionConfig { Selection = "intensity" },
                    MS3 = new MS3SelectionConfig { Selection = "none" }
                }
            };
            return mp.ToCppJson();
        }
```

Also update line 114 (`MethodParameters.Load(roundtripPath)`) to load `.json` instead of `.xml`.

- [ ] **Step 4: Update GoldenCaptureTests.cs**

Change `MethodParameters.Load` paths from `.xml` to `.json`, and `mp.IDA.ToJSON(mp)` to `mp.ToCppJson()`:

```csharp
        [Test]
        public void CaptureConfigDefault()
        {
            var mp = MethodParameters.Load(Path.Combine(TestDataDir, "configs", "method_default.json"));
            string json = mp.ToCppJson();
            // ... rest unchanged
        }

        [Test]
        public void CaptureConfigFull()
        {
            string jsonPath = Path.Combine(TestDataDir, "configs", "method_json_roundtrip.json");
            Assume.That(File.Exists(jsonPath), Is.True,
                "method_json_roundtrip.json not present — skipping capture");
            var mp = MethodParameters.Load(jsonPath);
            string json = mp.ToCppJson();
            // ... rest unchanged
        }
```

- [ ] **Step 5: Update BridgePhase3Tests.cs**

Change `MethodParameters.Load(configPath)` at line 51 to load `.json`. Update the config path resolution to look for `.json` files.

- [ ] **Step 6: Build and run tests**

Run: `msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /v:minimal`

Expected: Build succeeds. Run tests to verify golden file comparisons pass.

- [ ] **Step 7: Commit**

```bash
git add FlashIDA/src/Flash.Tests/
git commit -m "Update all tests for JSON config pipeline"
```

---

## Task 8: Update MethodDocGenerator

**Files:**
- Modify: `FlashIDA/src/Flash/IDA/MethodDocGenerator.cs`
- Modify: `FlashIDA/src/Flash.Tests/CleanupTests.cs`

- [ ] **Step 1: Rewrite MethodDocGenerator**

Replace the content of `MethodDocGenerator.cs`:

```csharp
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Reflection;
using System.Text;

namespace Flash.IDA
{
    /// <summary>
    /// Generates Markdown documentation from [Description], [Developer], and [JsonKey]
    /// attributes on config classes.
    /// </summary>
    public static class MethodDocGenerator
    {
        /// <summary>
        /// Generate Markdown documentation for a config class and its nested types.
        /// Developer-tagged properties are grouped in a separate subsection.
        /// </summary>
        public static string Generate(Type rootType)
        {
            var sb = new StringBuilder();
            sb.AppendLine("# FLASHIda Method Configuration Reference\n");

            foreach (var prop in rootType.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                var sectionKey = prop.GetCustomAttribute<JsonKeyAttribute>();
                if (sectionKey == null) continue;

                Type sectionType = prop.PropertyType;
                GenerateSection(sb, sectionKey.Key, sectionType);
            }

            return sb.ToString();
        }

        private static void GenerateSection(StringBuilder sb, string sectionName, Type type)
        {
            var userProps = new List<(string key, string typeName, string defaultVal, string desc)>();
            var devProps = new List<(string key, string typeName, string defaultVal, string desc)>();

            object defaultInstance = null;
            try { defaultInstance = Activator.CreateInstance(type); } catch { }

            foreach (var prop in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                var keyAttr = prop.GetCustomAttribute<JsonKeyAttribute>();
                var descAttr = prop.GetCustomAttribute<DescriptionAttribute>();
                if (keyAttr == null || descAttr == null) continue;

                string defaultVal = "";
                if (defaultInstance != null)
                {
                    var val = prop.GetValue(defaultInstance);
                    if (val is double[] arr)
                        defaultVal = "[" + string.Join(", ", arr) + "]";
                    else if (val != null)
                        defaultVal = val.ToString();
                }

                string typeName = GetFriendlyTypeName(prop.PropertyType);
                var entry = (keyAttr.Key, typeName, defaultVal, descAttr.Description);

                if (prop.GetCustomAttribute<DeveloperAttribute>() != null)
                    devProps.Add(entry);
                else
                    userProps.Add(entry);
            }

            if (userProps.Count == 0 && devProps.Count == 0) return;

            sb.AppendFormat("## {0}\n\n", sectionName);

            if (userProps.Count > 0)
            {
                sb.AppendLine("| Parameter | Type | Default | Description |");
                sb.AppendLine("|-----------|------|---------|-------------|");
                foreach (var p in userProps)
                    sb.AppendFormat("| `{0}` | {1} | {2} | {3} |\n", p.key, p.typeName, p.defaultVal, p.desc);
                sb.AppendLine();
            }

            if (devProps.Count > 0)
            {
                sb.AppendLine("### Developer Settings\n");
                sb.AppendLine("| Parameter | Type | Default | Description |");
                sb.AppendLine("|-----------|------|---------|-------------|");
                foreach (var p in devProps)
                    sb.AppendFormat("| `{0}` | {1} | {2} | {3} |\n", p.key, p.typeName, p.defaultVal, p.desc);
                sb.AppendLine();
            }
        }

        private static string GetFriendlyTypeName(Type type)
        {
            if (type == typeof(int)) return "int";
            if (type == typeof(double)) return "double";
            if (type == typeof(bool)) return "bool";
            if (type == typeof(string)) return "string";
            if (type == typeof(double[])) return "double[]";
            return type.Name;
        }
    }
}
```

- [ ] **Step 2: Update CleanupTests.P8_U03**

Replace the existing test to use `MethodConfig`:

```csharp
        [Test]
        public void P8_U03_MethodDocGeneratorProducesOutput()
        {
            string output = MethodDocGenerator.Generate(typeof(MethodConfig));

            Assert.IsNotEmpty(output, "MethodDocGenerator returned empty string");
            Assert.That(output, Does.Contain("score_threshold"),
                "Output should contain score_threshold");
            Assert.That(output, Does.Contain("min_charge"),
                "Output should contain min_charge");
            Assert.That(output, Does.Contain("hcd_energy"),
                "Output should contain hcd_energy");
            Assert.That(output, Does.Contain("Developer Settings"),
                "Output should contain Developer Settings section");
        }
```

- [ ] **Step 3: Commit**

```bash
git add FlashIDA/src/Flash/IDA/MethodDocGenerator.cs FlashIDA/src/Flash.Tests/CleanupTests.cs
git commit -m "Update MethodDocGenerator to read JsonKey/Developer/Description attributes"
```

---

## Task 9: Delete Dead Code and Old Files

**Files:**
- Modify: `FlashIDA/src/Flash/IDA/Parameter.cs` — delete `IDAParameters` class entirely
- Delete: `FlashIDA/src/Flash/etc/method.xml`
- Delete: `FlashIDA/test-data/configs/method_*.xml` (all 20 XML configs)
- Modify: `FlashIDA/src/Flash/Flash.csproj` — verify no XML references remain
- Modify: `FlashIDA/src/Flash.Tests/Flash.Tests.csproj` — verify no changes needed

- [ ] **Step 1: Delete IDAParameters class**

In `Parameter.cs`, delete the entire `IDAParameters` class (the whole file content except the namespace and using statements). If `Parameter.cs` becomes empty, delete the file and remove its `<Compile>` entry from `Flash.csproj`.

Remove from `Flash.csproj`:
```xml
    <Compile Include="IDA\Parameter.cs" />
```

- [ ] **Step 2: Remove XML using directives from MethodParameters.cs**

Remove `using System.Xml.Serialization;` from `MethodParameters.cs` if no longer used.

- [ ] **Step 3: Delete method.xml**

```bash
rm FlashIDA/src/Flash/etc/method.xml
```

- [ ] **Step 4: Delete all XML test configs**

```bash
rm FlashIDA/test-data/configs/method_*.xml
```

- [ ] **Step 5: Build and run all tests**

Run: `msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /v:minimal`

Expected: Build succeeds. No references to `IDAParameters`, `InitializeIDA()`, `XmlSerializer`, or XML config files remain.

- [ ] **Step 6: Verify no stale references**

Search the codebase for any remaining references to deleted types:

```bash
grep -r "IDAParameters\|InitializeIDA\|XmlSerializer\|method\.xml\|\.IDA\." FlashIDA/src/ --include="*.cs" | grep -v "\.json"
```

Expected: No hits (or only comments/documentation).

- [ ] **Step 7: Commit**

```bash
git add -A FlashIDA/
git commit -m "Delete IDAParameters, XML configs, and all XML infrastructure"
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Requirement | Task |
|------------------|------|
| JSON only — drop XML | Task 9 (delete XML) |
| User-facing JSON schema mirrors XML structure | Task 2 (MethodConfig classes), Task 4 (JSON configs) |
| `[Developer]` attribute controls JSON structure | Task 1 (attribute), Task 2 (applied to properties), Task 3 (serializer routing) |
| `[JsonKey]` for explicit naming | Task 1 (attribute), Task 2 (applied to all properties) |
| C# classes are single source of truth | Task 2 (schema classes) |
| `ToCppJson()` replaces `InitializeIDA()` + `ToJSON()` | Task 5 |
| C++ JSON format unchanged | Task 5 (golden file tests) |
| `MethodParameters.Load()` reads JSON | Task 6 |
| Duration accessed from `Config.Global.Duration` | Task 6 |
| `CustomScanListner` deleted | Task 6 |
| `MethodDocGenerator` updated | Task 8 |
| `BridgeSmokeTests` updated | Task 7 |
| `ContinuityTests` updated | Task 7 |
| No backward-compatible accessors | Task 6 (all accessors removed) |

### Placeholder Scan

No TBDs, TODOs, or "implement later" found. All steps contain concrete code.

### Type Consistency

- `MethodConfig` used consistently as the top-level schema class
- `Config` property on `MethodParameters` used in all accessor patterns
- `[JsonKey]`, `[Developer]`, `[Description]` attribute names consistent throughout
- `ToCppJson()` method name consistent in `MethodParameters.cs`, `FLASHIdaWrapper.cs`, and all tests
- `MethodConfigSerializer.Deserialize()` and `.Serialize()` used consistently

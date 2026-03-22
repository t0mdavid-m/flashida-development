# Phase 1: JSON Configuration — Implementation Plan

**Date:** 2026-03-21
**Phase:** 1 of 8
**Build batch:** Build #1 (batched with Phases 2 and 3)
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 8 specification (authoritative)
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 1 section and CI requirements
- [../testing-strategy.md](../testing-strategy.md) — Phase 1 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative format requirements for all test files (spectrum files, golden TSVs, config XMLs, JSON reference files)

---

## Goal

Replace the fragile space-delimited token string (`ToFLASHDeconvInput()`) that C# currently passes to `CreateFLASHIda` with a structured JSON payload containing the complete `method.xml` content. The C++ constructor gains a JSON parsing branch that is triggered by auto-detection (`arg[0] == '{'`). The legacy parsing path is untouched and continues to work. After this phase, all method configuration — including `ms_settings`, `scheduling`, `faims`, and `exploration` sections — travels to C++ in a single structured, versioned, human-readable JSON string. No behavioral change to deconvolution or scan selection occurs in this phase.

---

## Prerequisites

### Phase 0 completion

The following must exist and pass before Phase 1 work begins:

- `FlashIDA/src/Flash/Flash.Tests/Flash.Tests.csproj` — NUnit test project compiles and runs.
- `FlashIDA/test-data/spectra/ms1_smoke_test.txt` — Minimal test spectrum committed. See [test-file-specification.md](../test-file-specification.md) Section 1.1 for exact format requirements.
- `FlashIDA/test-data/golden/baseline_phase0.tsv` — Golden file captured from current `Flash.exe -t` run and committed. See [test-file-specification.md](../test-file-specification.md) Sections 2.1 and 2.3 for column layout, comparison tolerances, and capture procedure.
- `FlashIDA/test-data/golden/README.md` — Documents golden file provenance.
- All P0-U01 through P0-I02 and P0-R01 pass in CI.

### Infrastructure

- `FlashIDA/dll/` contains a valid `OpenMS.dll` artifact (from `build-openms-dll.yml`).
- `FlashIDA/dependencies/` contains Thermo iAPI DLLs (from secret).
- CI workflow `flashida-ci.yml` is operational (skeleton from Phase 0).
- `nlohmann_json` is already bundled in the OpenMS source tree (it is; see `OpenMS/src/openms/thirdparty/`). No new dependency needed.

### Branch state

Working on branch `flashida-v9-migration` (FlashIDA) with OpenMS submodule on branch `flashida-v9-bridge`.

### User-Provided Inputs

No new user-provided data is required for Phase 1. All inputs (`ms1_smoke_test.txt`, `baseline_phase0.tsv`, Thermo DLLs, OpenMS DLLs) were established in Phase 0.

---

## Detailed Implementation Steps

### Step 1 — Create `MethodConfig.cs` typed serialization model

**File:** `FlashIDA/src/Flash/MethodConfig.cs` (modify existing file — this file already exists but currently contains only XML deserialization classes)

The existing `MethodConfig.cs` contains `GlobalParameters`, `PrecursorSelectionParameters`, `AcquisitionModesConfig`, `MSSettingsConfig`, `FAIMSSettings`, and the `MS1Parameters`/`MS2Parameters`/`MS3Parameters` structs are in `MethodParameters.cs`. The `MethodConfig.cs` file needs a new `JsonMethodConfig` class that is the serialization target for `ToJSON()`.

Add to the bottom of `FlashIDA/src/Flash/MethodConfig.cs` a new class `JsonMethodConfig` with nested classes matching the JSON schema from Issue 8. This class is a plain data container — no logic, just properties annotated with `[Description]` attributes for the auto-doc feature that arrives in Phase 8. The nested structure must match the JSON schema exactly:

```csharp
// Top-level class for JSON serialization
public class JsonMethodConfig
{
    public JsonDeconvolutionConfig deconvolution { get; set; }
    public JsonPrecursorSelectionConfig precursor_selection { get; set; }
    public JsonQuantificationConfig quantification { get; set; }
    public JsonFaimsConfig faims { get; set; }
    public JsonMsSettingsConfig ms_settings { get; set; }
    public JsonSchedulingConfig scheduling { get; set; }
    public JsonExplorationConfig exploration { get; set; }
    public JsonFilesConfig files { get; set; }
}
```

Nested classes required (each a separate public class in the same file, or nested inside `JsonMethodConfig`):

| Class | Fields | Source in MethodParameters |
|-------|--------|---------------------------|
| `JsonDeconvolutionConfig` | `score_threshold` (double), `min_charge` (int), `max_charge` (int), `tol` (double[]) | `PrecursorSelection.QScoreThreshold`, `PrecursorSelection.MinCharge`, `PrecursorSelection.MaxCharge`, `PrecursorSelection.Tolerances` |
| `JsonPrecursorSelectionConfig` | `max_mass_count` (int), `RT_window` (double), `target_mode` (int), `IDScore` (bool), `HCDEnergy` (int) | `MSSettings.MaxMs2CountPerMs1`, `PrecursorSelection.RTWindow`, targeting mode enum, `Developer.PrecursorSelection.UseIDScore`, `PrecursorSelection.HCDEnergy` |
| `JsonQuantificationConfig` | `enabled` (bool), `reporter_mz_tol` (double), `fold_change_threshold` (double) | `AcquisitionModes.LabelingBasedQuantification.*` |
| `JsonFaimsConfig` | `cv_values` (double[]), `max_cv_skip` (int) | `MSSettings.FAIMS.CVValues`, `AcquisitionModes.Developer.FAIMS.MaxCVSkip` |
| `JsonMs1Config` | `Analyzer` (string), `FirstMass` (double), `LastMass` (double), `OrbitrapResolution` (int), `AGCTarget` (int), `MaxIT` (double) | `MSSettings.MS1.*` |
| `JsonMs2Config` | `Analyzer` (string), `Activation` (string), `CollisionEnergy` (int), `OrbitrapResolution` (int) | Each entry in `MSSettings.MS2` list |
| `JsonMs3Config` | `Analyzer` (string), `Activation` (string), `CollisionEnergy` (int), `OrbitrapResolution` (int) | Each entry in `MSSettings.MS3` list |
| `JsonMsSettingsConfig` | `ms1` (`JsonMs1Config`), `ms2` (`List<JsonMs2Config>`), `ms3` (`List<JsonMs3Config>`) | Composed above |
| `JsonSchedulingConfig` | `cycle_time_enabled` (bool), `cycle_time_seconds` (double), `timeout_enabled` (bool), `timeout_seconds` (double) | `method.xml` `<ScanScheduling>` section (new XML section; see Step 3) |
| `JsonExplorationConfig` | `enabled` (bool), `max_depth` (int), `max_variants` (int) | `method.xml` `<ParameterOptimization>` section (parsed but not yet acted upon) |
| `JsonFilesConfig` | `fasta` (string, nullable), `inclusion_list` (string, nullable) | `AcquisitionModes.TargetedInclusion.InclusionList`, `AcquisitionModes.TargetedInclusion.MS2Tagging.FastaFile` |

All property names use the exact casing shown in the Issue 8 JSON schema (lowercase with underscores). Use `JavaScriptSerializer` from `System.Web.Extensions` for serialization — it is already available in .NET 4.8 and is used elsewhere in the project. No new NuGet packages are needed.

Note: `JsonMs1Config` includes only the fields that C++ needs to construct scan commands in later phases. The full `MS1Parameters` struct (with `Microscans`, `DataType`, `RFLens`, `SourceCID`, etc.) is preserved in `MethodParameters.cs` for the Thermo API calls. The JSON subset carries only what the C++ deconvolution engine requires now or in later phases.

---

### Step 2 — Add `ToJSON()` to `IDAParameters`

**File:** `FlashIDA/src/Flash/IDA/Parameter.cs`

Add a new public method `ToJSON(MethodParameters mp)` to the `IDAParameters` class. This method takes the full `MethodParameters` object (which has already been initialized via `InitializeIDA()`) and produces the JSON string.

```
public string ToJSON(MethodParameters mp)
```

Implementation strategy:
1. Construct a `JsonMethodConfig` instance, populating each nested object from `mp` and `this` (the `IDAParameters` instance).
2. Map `TargetMode` integer back to a numeric value: 0=None, 1=Inclusion, 2=Exclusion, 3=Deep (matching `InitializeIDA()` logic in `MethodParameters.cs`).
3. For `scheduling`: read from `mp.MSSettings.ScanScheduling` if that XML section exists (see Step 3), otherwise use defaults (`cycle_time_enabled=false`, `cycle_time_seconds=60`, `timeout_enabled=false`, `timeout_seconds=30`).
4. For `exploration`: read from `mp.AcquisitionModes.ParameterOptimization` if that XML section exists (see Step 3), otherwise use defaults (`enabled=false`, `max_depth=1`, `max_variants=5`).
5. For `files.fasta`: use `FastaFile` if non-null and non-empty, else serialize as JSON `null`.
6. For `files.inclusion_list`: use `InclusionList` if non-null and non-empty, else `null`.
7. Serialize via `new JavaScriptSerializer().Serialize(config)`.
8. Return the resulting JSON string.

The method must not throw. If `mp` is null, fall back to `ToFLASHDeconvInput()` behavior by returning the legacy format. This ensures Phase 1 cannot break Phase 0 behavior even if called incorrectly.

`ToFLASHDeconvInput()` is NOT removed in this phase. It remains in `Parameter.cs` and is still the method called by `FLASHIdaWrapper.cs` until Step 4 below switches the call site.

---

### Step 3 — Add `ScanSchedulingConfig` and `ParameterOptimizationConfig` XML classes

**File:** `FlashIDA/src/Flash/MethodConfig.cs`

The JSON schema includes `scheduling` and `exploration` sections that do not currently have corresponding XML classes. Add two new XML-serializable classes:

```csharp
public class ScanSchedulingCycleTime
{
    public bool Active = false;
    public double Seconds = 60;
}

public class ScanSchedulingTimeout
{
    public bool Active = false;
    public double Seconds = 30;
}

public class ScanSchedulingConfig
{
    public ScanSchedulingCycleTime CycleTime;
    public ScanSchedulingTimeout ScanTimeout;
}

public class ParameterOptimizationScanLimits
{
    public int MaxVariantsPerPrecursor = 5;
    public int MaxQueueForExploration = 50;
    public int MaxExplorationDepth = 1;
}

public class ParameterOptimizationConfig
{
    public bool Active = false;
    public ParameterOptimizationScanLimits ScanLimits;
}
```

Add `ScanScheduling` and `ParameterOptimization` fields to `MSSettingsConfig`:

```csharp
public class MSSettingsConfig
{
    public int MaxMs2CountPerMs1 = 4;
    public FAIMSSettings FAIMS;
    public MS1Parameters MS1;
    public List<MS2Parameters> MS2;
    public List<MS3Parameters> MS3;
    // New in Phase 1:
    public ScanSchedulingConfig ScanScheduling;
    public ParameterOptimizationConfig ParameterOptimization;
}
```

These fields are optional in existing XML files — `XmlSerializer` leaves them null when absent. `ToJSON()` in Step 2 uses null-safe access with defaults.

**Important:** Do not modify `method.xml` in `FlashIDA/src/Flash/etc/` in this step. The existing file does not need the new sections to work correctly — the defaults in `ToJSON()` handle their absence. The test config `method_json_roundtrip.xml` (created in Step 5) will exercise the full schema.

---

### Step 4 — Switch `FLASHIdaWrapper.cs` to pass JSON

**File:** `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

The current `CreateFLASHIda` call is inside `FLASHIdaWrapper`'s constructor (or initialization method). Find the call site where `p.ToFLASHDeconvInput()` is passed to `CreateFLASHIda` and replace it with `p.ToJSON(methodParameters)`.

The call site is in `FLASHIdaWrapper` where the `IDAParameters` object's string is assembled. Based on reading the file:
- `CreateFLASHIda` is declared at line 33: `static private extern IntPtr CreateFLASHIda(string arg);`
- The constructor of `FLASHIdaWrapper` calls `CreateFLASHIda` with the legacy string.

Change:
```csharp
// Before:
flashIda_ = CreateFLASHIda(parameters.ToFLASHDeconvInput());

// After:
flashIda_ = CreateFLASHIda(parameters.ToJSON(methodParameters));
```

Where `methodParameters` is the `MethodParameters` instance available at the call site. If `FLASHIdaWrapper` does not currently hold a reference to `MethodParameters`, pass it as an additional constructor argument or thread it through as needed. The `MethodParameters` object is already loaded in `Flash.cs` before `FLASHIdaWrapper` is constructed, so threading it through is straightforward.

The `DllImport` declaration for `CreateFLASHIda` does not change — it still takes a `string arg`. The C++ function receives a `char*`; .NET marshals `string` as a null-terminated ANSI char array by default, which is correct.

---

### Step 5 — Add test data files

The following files must be created and committed to the repository. See [test-file-specification.md](../test-file-specification.md) for the canonical directory layout (Section 5), config file inventory (Section 3.2), and JSON reference file format (Section 3.3).

**`FlashIDA/test-data/configs/method_json_roundtrip.xml`**

A full-featured `method.xml` variant that exercises every JSON field. The canonical description of this file (key parameters, purpose) is in [test-file-specification.md](../test-file-specification.md) Section 3.2. In summary: start from `FlashIDA/src/Flash/etc/method.xml` and add values for:
- `PrecursorSelection`: non-default values for `MinCharge`, `MaxCharge`, `HCDEnergy`, `Tolerances`
- `AcquisitionModes`: `TargetingMode=None`, `Developer.PrecursorSelection.UseIDScore=False`
- `MSSettings.FAIMS`: `CVValues` with 3 values (e.g., `[-40, -50, -60]`)
- `MSSettings.ScanScheduling`: `CycleTime.Active=False`, `ScanTimeout.Active=False`
- `MSSettings.ParameterOptimization`: `Active=False`
- Multiple MS2 entries (at least 2) to verify the `ms2` JSON array

File must be < 5 KB. Stored in `FlashIDA/test-data/configs/`.

**`FlashIDA/test-data/json/config_default.json`**

The expected JSON output when `ToJSON()` is called on a `MethodParameters` loaded from `FlashIDA/src/Flash/etc/method.xml` (the default config). See [test-file-specification.md](../test-file-specification.md) Section 3.3 for format requirements: standard JSON, UTF-8, 2-space indentation; keys must exactly match the JSON schema in `baseline-plan.md` Issue 8.

Generated via CI artifact capture:
1. Push the implementation branch with a temporary CI step that writes `ToJSON()` output to an artifact.
2. The CI `windows-tests` job runs, uploads the generated JSON as a build artifact.
3. Developer downloads the artifact from the GitHub Actions run, reviews it, and commits it as the golden file.

This is the same CI-artifact-based golden file capture workflow used in Phase 0. No local Windows execution is required.

**`FlashIDA/test-data/json/config_full.json`**

The expected JSON output when `ToJSON()` is called on `method_json_roundtrip.xml`. Generated via the same CI artifact capture procedure. This exercises all array fields and non-default values. See [test-file-specification.md](../test-file-specification.md) Section 3.3 for format: standard JSON, UTF-8, 2-space indentation; keys match `baseline-plan.md` Issue 8 schema.

Both JSON files are stored in `FlashIDA/test-data/json/` (see Section 5 directory layout in the spec). The P1-U03 and P1-U05 comparison tests perform semantic comparison (deserialize both and compare field values), not string comparison, so formatting differences between a 2-space-indented golden file and minified actual output do not cause false failures.

---

### Step 6 — Add C++ JSON parsing branch in `FLASHIda::FLASHIda(char* arg)`

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

The constructor currently starts at line 326. It immediately begins tokenizing `arg` with `std::strtok`. Add a JSON detection check at the very beginning of the constructor body, before any existing logic:

```cpp
FLASHIda::FLASHIda(char* arg)
{
#ifdef _OPENMP
    omp_set_num_threads(4);
#endif

    std::string arg_str(arg);

    if (!arg_str.empty() && arg_str[0] == '{')
    {
        parseJSONConfig_(arg_str);
        return;
    }

    // Existing legacy parsing path follows unchanged...
    std::unordered_map<std::string, std::vector<double>> inputs;
    // ...rest of current constructor body...
}
```

The `parseJSONConfig_` method is a new private method on `FLASHIda`. It is responsible for:
1. Parsing the JSON string via `nlohmann::json`.
2. Extracting fields and storing them in the same member variables that the legacy path populates.
3. Calling the same post-parsing initialization code (averagine setup, target log loading, etc.) that the legacy path calls at the end of the constructor.

The `return` after `parseJSONConfig_` exits the constructor early, skipping the entire legacy tokenization block. This is the clean separation point.

**Important:** The legacy `std::strtok` block and all code after it must remain completely unchanged. The JSON branch only adds new code; it does not touch existing lines.

---

### Step 7 — Implement `parseJSONConfig_` in C++

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

**Header declaration:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add a private method declaration to `FLASHIda.h`:

```cpp
private:
    void parseJSONConfig_(const std::string& json_str);
```

Implementation in `FLASHIda.cpp`:

```cpp
void FLASHIda::parseJSONConfig_(const std::string& json_str)
{
    auto j = nlohmann::json::parse(json_str);

    // deconvolution section
    if (j.contains("deconvolution"))
    {
        auto& d = j["deconvolution"];
        if (d.contains("score_threshold"))
            qscore_threshold_ = d["score_threshold"].get<double>();
        if (d.contains("min_charge"))
            min_charge_ = d["min_charge"].get<int>();
        if (d.contains("max_charge"))
            max_charge_ = d["max_charge"].get<int>();
        if (d.contains("tol") && d["tol"].is_array() && d["tol"].size() == 2)
        {
            tol_[0] = d["tol"][0].get<double>();
            tol_[1] = d["tol"][1].get<double>();
        }
    }

    // precursor_selection section
    if (j.contains("precursor_selection"))
    {
        auto& ps = j["precursor_selection"];
        if (ps.contains("max_mass_count"))
            max_mass_count_ = ps["max_mass_count"].get<int>();
        if (ps.contains("RT_window"))
            rt_window_ = ps["RT_window"].get<double>();
        if (ps.contains("target_mode"))
            target_mode_ = ps["target_mode"].get<int>();
        if (ps.contains("IDScore"))
            use_idscore_ = ps["IDScore"].get<bool>();
        if (ps.contains("HCDEnergy"))
            hcd_energy_ = ps["HCDEnergy"].get<int>();
    }

    // quantification section
    if (j.contains("quantification"))
    {
        auto& q = j["quantification"];
        if (q.contains("enabled"))
            quant_enabled_ = q["enabled"].get<bool>();
        if (q.contains("reporter_mz_tol"))
            reporter_mz_tol_ = q["reporter_mz_tol"].get<double>();
        if (q.contains("fold_change_threshold"))
            fold_change_threshold_ = q["fold_change_threshold"].get<double>();
    }

    // faims section
    if (j.contains("faims"))
    {
        auto& f = j["faims"];
        if (f.contains("cv_values") && f["cv_values"].is_array())
        {
            faims_cv_values_.clear();
            for (auto& cv : f["cv_values"])
                faims_cv_values_.push_back(cv.get<double>());
        }
        if (f.contains("max_cv_skip"))
            max_cv_skip_ = f["max_cv_skip"].get<int>();
    }

    // ms_settings section — stored for future use (Phases 3+)
    // ms_settings values are parsed and stored but not yet used to build
    // scan commands (that work is done in Phase 3).
    if (j.contains("ms_settings"))
    {
        auto& ms = j["ms_settings"];
        if (ms.contains("ms1"))
        {
            auto& ms1 = ms["ms1"];
            if (ms1.contains("Analyzer"))
                ms1_analyzer_ = ms1["Analyzer"].get<std::string>();
            if (ms1.contains("FirstMass"))
                ms1_first_mass_ = ms1["FirstMass"].get<double>();
            if (ms1.contains("LastMass"))
                ms1_last_mass_ = ms1["LastMass"].get<double>();
            if (ms1.contains("OrbitrapResolution"))
                ms1_resolution_ = ms1["OrbitrapResolution"].get<int>();
            if (ms1.contains("AGCTarget"))
                ms1_agc_target_ = ms1["AGCTarget"].get<int>();
            if (ms1.contains("MaxIT"))
                ms1_max_it_ = ms1["MaxIT"].get<double>();
        }
        // ms2 and ms3 arrays are parsed into vectors for later use
        if (ms.contains("ms2") && ms["ms2"].is_array())
        {
            ms2_configs_.clear();
            for (auto& m2 : ms["ms2"])
            {
                MS2ConfigJson cfg;
                if (m2.contains("Analyzer")) cfg.analyzer = m2["Analyzer"].get<std::string>();
                if (m2.contains("Activation")) cfg.activation = m2["Activation"].get<std::string>();
                if (m2.contains("CollisionEnergy")) cfg.collision_energy = m2["CollisionEnergy"].get<int>();
                if (m2.contains("OrbitrapResolution")) cfg.resolution = m2["OrbitrapResolution"].get<int>();
                ms2_configs_.push_back(cfg);
            }
        }
    }

    // scheduling section — stored for future use (Phase 3)
    if (j.contains("scheduling"))
    {
        auto& s = j["scheduling"];
        if (s.contains("cycle_time_enabled"))
            cycle_time_enabled_ = s["cycle_time_enabled"].get<bool>();
        if (s.contains("cycle_time_seconds"))
            cycle_time_ms_ = s["cycle_time_seconds"].get<double>() * 1000.0;
        if (s.contains("timeout_enabled"))
            timeout_enabled_ = s["timeout_enabled"].get<bool>();
        if (s.contains("timeout_seconds"))
            timeout_ms_ = s["timeout_seconds"].get<double>() * 1000.0;
    }

    // exploration section — stored for future use (Phase 7)
    if (j.contains("exploration"))
    {
        auto& e = j["exploration"];
        if (e.contains("enabled"))
            exploration_enabled_ = e["enabled"].get<bool>();
        if (e.contains("max_depth"))
            exploration_max_depth_ = e["max_depth"].get<int>();
        if (e.contains("max_variants"))
            exploration_max_variants_ = e["max_variants"].get<int>();
    }

    // files section
    if (j.contains("files"))
    {
        auto& fi = j["files"];
        if (fi.contains("fasta") && !fi["fasta"].is_null())
        {
            std::string fasta = fi["fasta"].get<std::string>();
            if (!fasta.empty())
                loadFastaFile_(fasta);
        }
        if (fi.contains("inclusion_list") && !fi["inclusion_list"].is_null())
        {
            std::string inc = fi["inclusion_list"].get<std::string>();
            if (!inc.empty())
                loadInclusionList_(inc);
        }
    }

    // Call the same post-initialization that the legacy path calls
    initializeAveragine_();
}
```

**Member variable additions to `FLASHIda.h`:**

The new member variables needed for JSON-parsed config that do not already exist in the class must be declared in the private section of `FLASHIda.h`. Cross-check the current member variables in `FLASHIda.h` against the list above. Only add variables that are genuinely new. At minimum these are likely new:
- `std::string ms1_analyzer_`
- `double ms1_first_mass_`, `ms1_last_mass_`, `ms1_max_it_`
- `int ms1_resolution_`, `ms1_agc_target_`
- `struct MS2ConfigJson { std::string analyzer, activation; int collision_energy, resolution; }` and `std::vector<MS2ConfigJson> ms2_configs_`
- `bool cycle_time_enabled_`, `timeout_enabled_`, `exploration_enabled_`
- `double cycle_time_ms_`, `timeout_ms_`
- `int exploration_max_depth_`, `exploration_max_variants_`

For variables that already exist (such as `max_mass_count_`, `rt_window_`, `target_mode_`, `use_idscore_`, etc.) do not re-declare them. Read `FLASHIda.h` carefully before adding declarations to avoid duplicates.

**nlohmann_json include:** Add `#include <nlohmann/json.hpp>` to `FLASHIda.cpp`. The header is already available in the OpenMS source tree at `src/openms/thirdparty/json/include/nlohmann/json.hpp`. No CMakeLists.txt change is needed as `nlohmann_json` is already linked by the OpenMS library target.

**Error handling:** Wrap the entire `parseJSONConfig_` body in a `try/catch(const nlohmann::json::exception&)`. On parse failure, log an error and fall through to default values. This prevents a malformed JSON string from crashing the application:

```cpp
void FLASHIda::parseJSONConfig_(const std::string& json_str)
{
    try
    {
        auto j = nlohmann::json::parse(json_str);
        // ... all field extraction ...
    }
    catch (const nlohmann::json::exception& e)
    {
        // Log error; member variables retain their default-initialized values
        std::cerr << "[FLASHIda] JSON parse error: " << e.what() << std::endl;
    }
    initializeAveragine_();
}
```

---

### Step 8 — Verify `nlohmann_json` include path in OpenMS build

**File:** `OpenMS/src/openms/CMakeLists.txt` (or the appropriate target definition)

Verify that the `nlohmann_json` header path is in the include directories for the OpenMS library target. If it is already used elsewhere in the FLASH code or other OpenMS source files, no change is needed. Run:

```bash
grep -r "nlohmann" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/ --include="*.cpp" -l
grep -r "nlohmann" OpenMS/src/openms/include/ --include="*.h" -l
```

If `nlohmann/json.hpp` is already included in any TOPDOWN file, the include path is confirmed working. If not, verify the path is accessible from the TOPDOWN source files by checking whether other OpenMS source files use it.

---

### Step 9 — Write Phase 1 unit tests

**File:** `FlashIDA/src/Flash/Flash.Tests/JsonConfigTests.cs` (new file)

This file contains all 5 C# unit tests (P1-U01 through P1-U05). Create the file from scratch:

```csharp
using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using NUnit.Framework;
using Flash;
using Flash.IDA;

namespace Flash.Tests
{
    [TestFixture]
    public class JsonConfigTests
    {
        private static MethodParameters LoadDefault()
        {
            return MethodParameters.Load("test-data/configs/method_default.xml");
        }

        private static MethodParameters LoadFullRoundTrip()
        {
            return MethodParameters.Load("test-data/configs/method_json_roundtrip.xml");
        }

        [Test]
        public void P1_U01_ToJSON_ProducesValidJson()
        {
            var mp = LoadDefault();
            string json = mp.IDA.ToJSON(mp);
            Assert.DoesNotThrow(() =>
            {
                var ser = new JavaScriptSerializer();
                ser.DeserializeObject(json);
            }, "ToJSON() output must be parseable by JavaScriptSerializer");
        }

        [Test]
        public void P1_U02_ToJSON_ContainsAllRequiredSections()
        {
            var mp = LoadDefault();
            string json = mp.IDA.ToJSON(mp);
            var ser = new JavaScriptSerializer();
            var obj = ser.Deserialize<Dictionary<string, object>>(json);

            string[] requiredKeys = {
                "deconvolution", "precursor_selection", "quantification",
                "faims", "ms_settings", "scheduling", "exploration", "files"
            };
            foreach (var key in requiredKeys)
                Assert.IsTrue(obj.ContainsKey(key),
                    $"JSON must contain top-level key '{key}'");
        }

        [Test]
        public void P1_U03_ToJSON_FieldValuesMatchXmlSource()
        {
            var mp = LoadFullRoundTrip();
            string json = mp.IDA.ToJSON(mp);

            // Load the golden JSON reference
            string golden = System.IO.File.ReadAllText(
                "test-data/json/config_full.json");

            // Semantic comparison: deserialize both and compare key fields
            var ser = new JavaScriptSerializer();
            var actual = ser.Deserialize<Dictionary<string, object>>(json);
            var expected = ser.Deserialize<Dictionary<string, object>>(golden);

            // Spot-check critical fields
            var actDeconv = (Dictionary<string, object>)actual["deconvolution"];
            var expDeconv = (Dictionary<string, object>)expected["deconvolution"];
            Assert.AreEqual(expDeconv["min_charge"], actDeconv["min_charge"],
                "deconvolution.min_charge must match XML");
            Assert.AreEqual(expDeconv["max_charge"], actDeconv["max_charge"],
                "deconvolution.max_charge must match XML");

            var actPs = (Dictionary<string, object>)actual["precursor_selection"];
            var expPs = (Dictionary<string, object>)expected["precursor_selection"];
            Assert.AreEqual(expPs["HCDEnergy"], actPs["HCDEnergy"],
                "precursor_selection.HCDEnergy must match XML");
        }

        [Test]
        public void P1_U04_ToJSON_Ms2IsArray()
        {
            // Use the round-trip config which has multiple MS2 entries
            var mp = LoadFullRoundTrip();
            string json = mp.IDA.ToJSON(mp);
            var ser = new JavaScriptSerializer();
            var obj = ser.Deserialize<Dictionary<string, object>>(json);

            var msSettings = (Dictionary<string, object>)obj["ms_settings"];
            Assert.IsTrue(msSettings.ContainsKey("ms2"),
                "ms_settings must contain 'ms2'");
            var ms2 = msSettings["ms2"] as System.Collections.ArrayList;
            Assert.IsNotNull(ms2, "ms_settings.ms2 must be an array");
            Assert.GreaterOrEqual(ms2.Count, 1,
                "ms2 array must have at least 1 entry");
            // Verify array length matches XML MS2 child count
            Assert.AreEqual(mp.MS2.Count, ms2.Count,
                "ms2 array length must match XML MS2 entry count");
        }

        [Test]
        public void P1_U05_MethodConfig_RoundTrip()
        {
            // Full round-trip: MethodParameters -> ToJSON() -> deserialize -> verify
            var mp = LoadFullRoundTrip();
            string json = mp.IDA.ToJSON(mp);

            var ser = new JavaScriptSerializer();
            var obj = ser.Deserialize<Dictionary<string, object>>(json);

            // Verify FAIMS cv_values array survived
            var faims = (Dictionary<string, object>)obj["faims"];
            var cvValues = faims["cv_values"] as System.Collections.ArrayList;
            Assert.IsNotNull(cvValues, "faims.cv_values must be an array");
            Assert.AreEqual(mp.MSSettings.FAIMS?.CVValues?.Length ?? 0,
                cvValues.Count, "faims.cv_values count must match XML");

            // Verify scheduling section has expected structure
            var sched = (Dictionary<string, object>)obj["scheduling"];
            Assert.IsTrue(sched.ContainsKey("cycle_time_enabled"),
                "scheduling must contain cycle_time_enabled");
            Assert.IsTrue(sched.ContainsKey("timeout_enabled"),
                "scheduling must contain timeout_enabled");
        }
    }
}
```

Note: The test working directory must be set so that relative paths to `test-data/` resolve correctly. In NUnit, the working directory is typically the directory containing the test assembly. The CI script copies or symlinks test data to the output directory, or sets the working directory explicitly. See the CI configuration section below.

---

### Step 10 — Write Phase 1 integration tests

**File:** `FlashIDA/src/Flash/Flash.Tests/BridgeSmokeTests.cs` (extends existing file from Phase 0)

Add three new test methods to the existing `BridgeSmokeTests` class. These tests exercise the C++ constructor with JSON and legacy inputs via the bridge:

```csharp
[Test]
public void P1_I01_CreateFLASHIda_WithJsonConfig_DoesNotCrash()
{
    var mp = MethodParameters.Load("test-data/configs/method_default.xml");
    string json = mp.IDA.ToJSON(mp);
    // Call the bridge directly
    IntPtr handle = TestBridgeHelper.CreateFLASHIda(json);
    Assert.AreNotEqual(IntPtr.Zero, handle,
        "CreateFLASHIda(jsonString) must return non-null pointer");
    TestBridgeHelper.DisposeFLASHIda(handle);
}

[Test]
public void P1_I02_CreateFLASHIda_WithLegacyConfig_StillWorks()
{
    var mp = MethodParameters.Load("test-data/configs/method_default.xml");
    string legacy = mp.IDA.ToFLASHDeconvInput();
    IntPtr handle = TestBridgeHelper.CreateFLASHIda(legacy);
    Assert.AreNotEqual(IntPtr.Zero, handle,
        "CreateFLASHIda(legacyString) must still work via auto-detect fallback");
    TestBridgeHelper.DisposeFLASHIda(handle);
}

[Test]
public void P1_I03_CreateFLASHIda_JsonConfigValuesReachCpp()
{
    // This test requires a diagnostic bridge function to echo back parsed values.
    // If no such function exists yet, this test verifies via Flash.exe -t
    // that the application does not crash and produces valid output.
    // A future phase may add a dedicated echo function; for now, non-crash
    // plus regression output matching serves as functional verification.
    var mp = MethodParameters.Load("test-data/configs/method_json_roundtrip.xml");
    string json = mp.IDA.ToJSON(mp);
    IntPtr handle = TestBridgeHelper.CreateFLASHIda(json);
    Assert.AreNotEqual(IntPtr.Zero, handle,
        "CreateFLASHIda(json with non-default values) must return non-null pointer");
    TestBridgeHelper.DisposeFLASHIda(handle);
}
```

`TestBridgeHelper` is a small static helper class (add to `BridgeSmokeTests.cs` or create `TestBridgeHelper.cs`) that wraps the P/Invoke calls:

```csharp
internal static class TestBridgeHelper
{
    const string dllName = "OpenMS.dll";
    [DllImport(dllName)] public static extern IntPtr CreateFLASHIda(string arg);
    [DllImport(dllName)] public static extern void DisposeFLASHIda(IntPtr ptr);
}
```

---

## Files to Create or Modify

### C# files (FlashIDA)

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/MethodConfig.cs` | Modify | Add `JsonMethodConfig` and all nested JSON serialization classes; add `ScanSchedulingConfig` and `ParameterOptimizationConfig` XML classes; add new fields to `MSSettingsConfig` |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Add `ToJSON(MethodParameters mp)` method to `IDAParameters`; `ToFLASHDeconvInput()` remains unchanged |
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | Change `CreateFLASHIda` call site to use `ToJSON()` instead of `ToFLASHDeconvInput()` |
| `FlashIDA/src/Flash/Flash.Tests/JsonConfigTests.cs` | Create | P1-U01 through P1-U05 unit tests |
| `FlashIDA/src/Flash/Flash.Tests/BridgeSmokeTests.cs` | Modify | Add P1-I01, P1-I02, P1-I03 integration tests; add `TestBridgeHelper` |

### C++ files (OpenMS)

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Add `parseJSONConfig_(const std::string&)` private method declaration; add new member variable declarations for JSON-parsed config fields not already present |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Add JSON auto-detection at the top of the constructor; implement `parseJSONConfig_()` method; add `#include <nlohmann/json.hpp>` |

### Test data files

See [test-file-specification.md](../test-file-specification.md) for exact format requirements: Section 3.2 for config XML files, Section 3.3 for JSON reference files, and Section 5 for the expected directory layout under `FlashIDA/test-data/`.

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/test-data/configs/method_json_roundtrip.xml` | Create | Full-featured method config exercising all JSON schema fields; multiple MS2 entries; non-default values. See spec Section 3.2. |
| `FlashIDA/test-data/json/config_default.json` | Create | Expected `ToJSON()` output for `method_default.xml`; committed golden file. See spec Section 3.3 for format (UTF-8, 2-space indent, keys from Issue 8 schema). |
| `FlashIDA/test-data/json/config_full.json` | Create | Expected `ToJSON()` output for `method_json_roundtrip.xml`; committed golden file. See spec Section 3.3. |

### No changes to these files

| File | Reason |
|------|--------|
| `FlashIDA/src/Flash/etc/method.xml` | Existing XML is unchanged; new XML sections are optional |
| `FlashIDA/src/Flash/MethodParameters.cs` | `InitializeIDA()` is unchanged; no new logic needed |
| `FlashIDA/src/Flash/Flash.cs` | No change; `FLASHIdaWrapper` constructor change is transparent |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Constructor signature unchanged; `CreateFLASHIda(char*)` just passes `arg` to `FLASHIda` constructor |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` | No change; bridge API signature unchanged |
| `FlashIDA/src/Flash/ScanFactory.cs` | No change in Phase 1 |
| `FlashIDA/src/Flash/ScanScheduler.cs` | No change in Phase 1 |

---

## Test Cases

All 10 Phase 1 tests plus full regression of Phase 0 (7 tests) must pass.

### Test Summary (Quick Reference)

| Test ID | Summary |
|---------|---------|
| P1-U01 | Verifies that `ToJSON()` produces a string that is syntactically valid JSON. This is the baseline sanity check — if serialization is broken entirely, all downstream tests catch it here first. |
| P1-U02 | Verifies that the JSON output contains all 8 required top-level section keys (`deconvolution`, `precursor_selection`, `quantification`, `faims`, `ms_settings`, `scheduling`, `exploration`, `files`). Ensures no section is accidentally omitted during construction of `JsonMethodConfig`. |
| P1-U03 | Spot-checks that concrete field values parsed from a known XML config (`method_json_roundtrip.xml`) appear correctly in the JSON string. Catches field-mapping mistakes such as a wrong property name or off-by-one in array indexing. |
| P1-U04 | Verifies that `ms_settings.ms2` is serialized as a JSON array and that its length matches the number of MS2 entries in the source XML. Specifically guards against the MS2 list being collapsed to a single object or dropped entirely. |
| P1-U05 | Full round-trip test: `MethodParameters` loaded from `method_json_roundtrip.xml` is serialized to JSON and then deserialized; the FAIMS CV values array count and the `scheduling` section keys are checked. Confirms that both array types and the new XML sections survive the full serialize/deserialize cycle. |
| P1-I01 | Calls `CreateFLASHIda` via P/Invoke with a JSON string and asserts a non-null handle is returned. Verifies that the C++ JSON parsing branch does not crash and correctly initializes the `FLASHIda` object end-to-end. |
| P1-I02 | Calls `CreateFLASHIda` with the legacy space-delimited token string and asserts a non-null handle. Verifies that the auto-detect fallback (`arg[0] != '{'`) continues to work correctly after the JSON branch is introduced, so existing behavior is not broken. |
| P1-I03 | Calls `CreateFLASHIda` with a JSON string derived from `method_json_roundtrip.xml` (non-default values, multiple FAIMS CVs, multiple MS2 entries) and asserts a non-null handle. Confirms that a more complex, non-trivial JSON payload does not trigger a parse error or crash in C++. |
| P1-R01 | Runs `Flash.exe -t` end-to-end with the JSON config path active (default method config) and compares the deconvolution output against `baseline_phase0.tsv`. Verifies that switching from the legacy string to JSON does not change any deconvolution results. |
| P1-R02 | Runs `Flash.exe -t` with the legacy string format forced via the auto-detect fallback and compares output against `baseline_phase0.tsv`. Verifies that the legacy path still produces bit-identical results after the JSON branch is added alongside it. |

### Tier 1 — C# Unit Tests

| Test ID | Class/Method | Description | Expected Outcome | Runner |
|---------|-------------|-------------|-----------------|--------|
| P1-U01 | `JsonConfigTests.P1_U01_ToJSON_ProducesValidJson` | `Parameter.ToJSON()` produces valid JSON parseable by `JavaScriptSerializer` | Deserialization does not throw; output starts with `{` | `windows-latest` |
| P1-U02 | `JsonConfigTests.P1_U02_ToJSON_ContainsAllRequiredSections` | All 8 top-level JSON keys present | `deconvolution`, `precursor_selection`, `quantification`, `faims`, `ms_settings`, `scheduling`, `exploration`, `files` all present | `windows-latest` |
| P1-U03 | `JsonConfigTests.P1_U03_ToJSON_FieldValuesMatchXmlSource` | Round-trip: XML values appear correctly in JSON | `min_charge`, `max_charge`, `HCDEnergy` in JSON match values parsed from `method_json_roundtrip.xml` | `windows-latest` |
| P1-U04 | `JsonConfigTests.P1_U04_ToJSON_Ms2IsArray` | `ms_settings.ms2` is a JSON array with correct length | Array length equals `MethodParameters.MS2.Count` | `windows-latest` |
| P1-U05 | `JsonConfigTests.P1_U05_MethodConfig_RoundTrip` | Full model round-trip preserves FAIMS CV array and scheduling keys | `faims.cv_values` count matches XML; `scheduling` has `cycle_time_enabled` and `timeout_enabled` keys | `windows-latest` |

### Tier 2 — Integration Tests

| Test ID | Class/Method | Description | Expected Outcome | Runner |
|---------|-------------|-------------|-----------------|--------|
| P1-I01 | `BridgeSmokeTests.P1_I01_CreateFLASHIda_WithJsonConfig_DoesNotCrash` | `CreateFLASHIda(jsonString)` returns non-null pointer; no access violation | `IntPtr != IntPtr.Zero`, `DisposeFLASHIda` also completes without exception | `windows-latest` |
| P1-I02 | `BridgeSmokeTests.P1_I02_CreateFLASHIda_WithLegacyConfig_StillWorks` | Legacy format auto-detect still works | `IntPtr != IntPtr.Zero` when legacy token string passed | `windows-latest` |
| P1-I03 | `BridgeSmokeTests.P1_I03_CreateFLASHIda_JsonConfigValuesReachCpp` | Non-default JSON config parsed without crash | `IntPtr != IntPtr.Zero` for `method_json_roundtrip.xml` config | `windows-latest` |

### Tier 3 — Regression Tests

Both P1-R01 and P1-R02 use `ms1_smoke_test.txt` as the spectrum input and `baseline_phase0.tsv` as the golden reference. See [test-file-specification.md](../test-file-specification.md) Section 1.1 for the exact format of `ms1_smoke_test.txt`, Section 2.1 for the 15-column TSV format and comparison tolerances of `baseline_phase0.tsv`, and Section 4.1 for `compare_golden.py` usage and tolerance rules.

| Test ID | Script / Config | Description | Expected Outcome | Runner |
|---------|----------------|-------------|-----------------|--------|
| P1-R01 | CI `windows-tests` job, `method_default.xml` via JSON path | `Flash.exe -t` with JSON config active produces identical output to Phase 0 golden | `compare_golden.py baseline_phase0.tsv output.tsv` exits 0; automated by CI job `windows-tests` | `windows-latest` |
| P1-R02 | CI `windows-tests` job, legacy string override | `Flash.exe -t` with legacy format (auto-detect fallback) produces identical output | `compare_golden.py baseline_phase0.tsv output.tsv` exits 0; automated by CI job `windows-tests` | `windows-latest` |

**Regression from Phase 0:** All 7 P0-* tests must pass as part of the Phase 1 CI run. No Phase 0 test is removed.

**Note on P1-R02:** To exercise the legacy fallback path in regression, a test variant that calls `CreateFLASHIda` with a legacy string is needed. This can be done either via a separate test harness invocation or by temporarily passing `ToFLASHDeconvInput()` output in a test mode. The simplest approach is a small dedicated test in `BridgeSmokeTests` that calls `CreateFLASHIda` with the legacy string and then runs a minimal deconvolution — but for the regression test, `Flash.exe -t` itself is the harness. A future phase may provide a flag for this; for Phase 1, P1-I02 covering the bridge call and the fact that `ToFLASHDeconvInput()` is still present (even if not called by default) satisfies this requirement. P1-R02 can be implemented as a CI step that explicitly passes the legacy string by temporarily reverting the call in a dedicated test-mode wrapper.

---

## CI Configuration

### What changes in `flashida-ci.yml`

Phase 1 does not require a new CI job structure. The existing `windows-tests` job from Phase 0 is extended:

1. **Add `JsonConfigTests.cs` to the test run.** Since the new file is in the same `Flash.Tests.csproj`, it is automatically picked up by `nunit3-console Flash.Tests.dll`. No workflow change needed.

2. **Add JSON golden files to the test data check.** The CI step that verifies test data presence should be extended to check for:
   - `FlashIDA/test-data/json/config_default.json`
   - `FlashIDA/test-data/json/config_full.json`
   - `FlashIDA/test-data/configs/method_json_roundtrip.xml`

3. **Add P1-R01 and P1-R02 regression steps** to the `windows-tests` job (or the `regression` sub-step within it). These run `Flash.exe -t` with the default method config (which now uses JSON) and compare against `baseline_phase0.tsv`.

The regression runner script `regression-runner.ps1` must be updated to include the P1 configs. See [test-file-specification.md](../test-file-specification.md) Section 4.2 for the full `regression-runner.ps1` parameter schema, config array format, and exit behavior. The Phase 1 addition to the config array is:

```powershell
$configs = @(
    # Phase 0
    @{ name="baseline"; method="method_default.xml"; ms1="ms1_smoke_test.txt"; ms2=$null; golden="baseline_phase0.tsv" },
    # Phase 1 (same golden as Phase 0 — verifying no behavioral change)
    @{ name="p1_json";  method="method_default.xml"; ms1="ms1_smoke_test.txt"; ms2=$null; golden="baseline_phase0.tsv" },
)
```

Note: the `ms2` field is required in the runner's config object schema (see spec Section 4.2); set it to `$null` for configs that do not use an MS2 spectrum file.

4. **DLL placement.** OpenMS DLLs (`OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`) must be in `FlashIDA/dll/`. Thermo DLLs must be in `FlashIDA/dependencies/`. Both are restored via secrets/cache as established in Phase 0. No change to secret strategy.

5. **OpenMS DLL cache key.** Because Phase 1 modifies C++ source files (`FLASHIda.cpp`, `FLASHIda.h`), the OpenMS submodule commit hash changes when the Phase 1 C++ changes are committed to the `flashida-v9-bridge` branch. This triggers a C++ rebuild via `build-openms-dll.yml`. The cache invalidation happens automatically — no CI workflow change is needed; only the submodule pointer in the FlashIDA repo must be updated to point to the new OpenMS commit.

6. **No new CI secrets** are needed for Phase 1.

### Runner requirements for Phase 1 tests

| Test IDs | Runner | DLL requirements |
|----------|--------|-----------------|
| P1-U01 through P1-U05 | `windows-latest` | Thermo DLLs for build only; OpenMS DLL not needed at runtime for unit tests |
| P1-I01 through P1-I03 | `windows-latest` | Both Thermo DLLs (for build) and OpenMS DLL (for runtime P/Invoke) |
| P1-R01, P1-R02 | `windows-latest` | Both Thermo DLLs and OpenMS DLL |

No `ubuntu-latest` tests are added in Phase 1. The first C++ unit tests appear in Phase 2.

### `build-openms-dll.yml` trigger

Phase 1 requires a C++ rebuild (Build #1 prep) because `FLASHIda.cpp` and `FLASHIda.h` are modified. The `build-openms-dll.yml` workflow must be triggered (manually or by push to the `flashida-v9-bridge` OpenMS branch). The FlashIDA CI then picks up the new artifact via the cache key mechanism.

---

## Working Product Verification

After all implementation steps are complete, verify the working product by inspecting CI job output. No local Windows execution is required or expected.

**Verification 1: `Flash.exe -t` runs with JSON config**

Automated by: CI job `windows-tests`. Verify by inspecting CI job output for the P1-R01 regression step. Expected: exit code 0, `output.tsv` produced, `compare_golden.py` reports no differences against `baseline_phase0.tsv`.

**Verification 2: Round-trip field match**

Automated by: CI job `windows-tests`. Verify by inspecting CI job output and confirming P1-U03 is green. This verifies that a specific non-default field value (e.g., `MinCharge=4`, `HCDEnergy=29`) survives the path:

```
MethodParameters.Load(method_json_roundtrip.xml)
  -> IDAParameters.ToJSON(mp)
  -> JSON string
  -> JavaScriptSerializer.Deserialize
  -> field value matches original XML value
```

**Verification 3: Legacy format fallback**

Automated by: CI job `windows-tests`. Verify by inspecting CI job output and confirming P1-I02 is green: `CreateFLASHIda` with a legacy token string returns a non-null pointer.

**Verification 4: No output change**

Automated by: CI job `windows-tests`. Verify by inspecting the P1-R01 regression step output and confirming `compare_golden.py` exits 0.

---

## Definition of Done

The following checklist must be fully complete before Phase 1 is considered done and Phase 2 begins:

- [ ] `MethodConfig.cs` contains `JsonMethodConfig` and all 11 nested JSON config classes.
- [ ] `MethodConfig.cs` contains `ScanSchedulingConfig` and `ParameterOptimizationConfig` XML classes.
- [ ] `MSSettingsConfig` has `ScanScheduling` and `ParameterOptimization` fields (optional, null-safe).
- [ ] `Parameter.cs` (`IDAParameters`) has `ToJSON(MethodParameters mp)` method that produces valid JSON.
- [ ] `ToFLASHDeconvInput()` remains in `Parameter.cs` and is not modified.
- [ ] `FLASHIdaWrapper.cs` calls `ToJSON()` at the `CreateFLASHIda` call site instead of `ToFLASHDeconvInput()`.
- [ ] `FLASHIda.h` declares `parseJSONConfig_(const std::string&)` as a private method.
- [ ] `FLASHIda.h` declares new member variables for ms_settings, scheduling, and exploration fields.
- [ ] `FLASHIda.cpp` has JSON auto-detect at the top of the constructor: `if (!arg_str.empty() && arg_str[0] == '{')`.
- [ ] `FLASHIda.cpp` has `parseJSONConfig_()` implementing all 8 JSON sections from the Issue 8 schema.
- [ ] `FLASHIda.cpp` JSON branch has `try/catch(nlohmann::json::exception)` error handling.
- [ ] `FLASHIda.cpp` legacy constructor path is completely unchanged.
- [ ] `Flash.Tests/JsonConfigTests.cs` exists and contains P1-U01 through P1-U05.
- [ ] `Flash.Tests/BridgeSmokeTests.cs` contains P1-I01 through P1-I03 and `TestBridgeHelper`.
- [ ] `test-data/configs/method_json_roundtrip.xml` committed with multiple MS2 entries and non-default FAIMS CVs.
- [ ] `test-data/json/config_default.json` committed (golden JSON for default config).
- [ ] `test-data/json/config_full.json` committed (golden JSON for round-trip config).
- [ ] CI `windows-tests` job passes with all 10 Phase 1 tests (P1-U01 through P1-R02) green.
- [ ] CI `windows-tests` job passes with all 7 Phase 0 tests (P0-U01 through P0-R01) still green (no regression).
- [ ] CI job output for the P1-R01 regression step shows `compare_golden.py` exiting 0 (JSON config output matches `baseline_phase0.tsv`).
- [ ] CI job output for the P1-R02 regression step shows `compare_golden.py` exiting 0 (legacy fallback output matches `baseline_phase0.tsv`).
- [ ] CI job output confirms `Flash.exe -t` runs to completion without unhandled exceptions.
- [ ] `OpenMS.dll` artifact updated to Build #1 DLL (includes JSON parsing branch).
- [ ] OpenMS submodule pointer in FlashIDA repo updated to the Phase 1 OpenMS commit.
- [ ] No new compiler warnings introduced in either C# or C++ code.

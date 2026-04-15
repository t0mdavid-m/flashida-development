# Per-Level Exploration PPM Tolerance

## Goal

Allow exploration scans to use a different PPM mass tolerance than regular scans at the same MS level, for both deconvolution and fragment matching (tagging/characterization). Each MS level's exploration block can independently override its base tolerance.

## Background

Currently, PPM tolerance is set globally via `deconvolution.tol` as a 2-element array `[ms1_ppm, ms2_ppm]`. All MS2+ levels share `tol[1]`. There is no way to:

1. Set different base tolerances per MS level (MS2 vs MS3)
2. Set a different tolerance for exploration scans vs regular scans at the same level

The tolerance is consumed in three places:

- **`Deconvolution` constructor** (Deconvolution.cpp:48-57): builds `SpectralDeconvolution` with `DoubleList{level(1).tolerance_ppm, level(2).tolerance_ppm}`. One shared instance for all scan types.
- **`FragmentAnalysis::runTagBasedFragmentMatching_`** (FragmentAnalysis.cpp:409): hardcodes `config_.level(2).tolerance_ppm` for FLASHTagger/FLASHExtender.
- **`Exploration::feedResult`** (Exploration.cpp:181): calls `deconv_.deconvolveMSn()` which uses the shared engine's tolerance.

## Design

### JSON Config Changes

**1. Extended `tol` array:** One entry per configured MS level, mandatory.

```json
"deconvolution": {
  "tol": [10, 10, 20]
}
```

Index 0 = MS1, index 1 = MS2, index 2 = MS3. If the config defines MSn scans (via `ms_settings` or `selection_strategy`), `tol` must have at least n entries. Missing entries → `throw std::invalid_argument`.

**2. Exploration tolerance override:** Via the existing `overrides` dictionary in the exploration block.

```json
"selection_strategy": {
  "ms2": {
    "exploration": {
      "metric": "mass_count",
      "ce_min": 20.0,
      "ce_max": 40.0,
      "ce_step": 5.0,
      "overrides": {
        "tolerance_ppm": "15"
      }
    }
  },
  "ms3": {
    "exploration": {
      "metric": "remaining_precursor",
      "ce_min": 20.0,
      "ce_max": 40.0,
      "ce_step": 5.0
    }
  }
}
```

When `overrides["tolerance_ppm"]` is present, exploration at that level uses it. Otherwise, exploration uses the base `tol[level-1]`. The `tolerance_ppm` key is extracted from overrides during parsing and stored separately — it is not passed through to `ScanConfig::applyOverrides()` (which handles instrument parameters only).

**Tolerance resolution:**
- Non-exploration scans: `tol[level-1]` (mandatory, validated)
- Exploration scans: `overrides["tolerance_ppm"]` if present, else `tol[level-1]`

### C# Side

No changes needed. `DeconvolutionConfig.Tolerances` (`double[]`, MethodConfig.cs:57) already accepts arbitrary-length arrays. `ExplorationBlockConfig.Overrides` (`Dictionary<string, string>`, MethodConfig.cs:249) already accepts arbitrary key-value pairs. Both serialize/deserialize through existing generic handlers in `MethodConfigSerializer.cs`.

### Config.h — New field on MSLevelConfig

Add `exploration_tolerance_ppm` to `MSLevelConfig`:

```cpp
struct MSLevelConfig
{
  // ... existing fields ...
  double tolerance_ppm = 10.0;
  double exploration_tolerance_ppm = 10.0;  // NEW: resolved exploration tolerance
  // ...
};
```

### Config.cpp — Parsing changes

**1. tol assignment (replacing lines 348-352):** Direct index per level instead of ms1/ms2 split. Also set `exploration_tolerance_ppm` to the same base value — the exploration block parser overrides it later if `overrides["tolerance_ppm"]` is present:

```cpp
for (auto& [lvl, cfg] : levels_)
{
  cfg.tolerance_ppm = tol_values[lvl - 1];
  cfg.exploration_tolerance_ppm = tol_values[lvl - 1];
}
```

**2. tol validation (new, after level assignment):** Check that `tol` has enough entries:

```cpp
int max_level = 0;
for (const auto& [lvl, _] : levels_)
  max_level = std::max(max_level, lvl);
if (static_cast<int>(tol_values.size()) < max_level)
  throw std::invalid_argument("deconvolution.tol must have at least "
    + std::to_string(max_level) + " entries when MS" + std::to_string(max_level) + " is configured");
```

**3. Exploration tolerance extraction (in exploration parsing block, ~lines 326-344):** After parsing overrides, extract `tolerance_ppm` if present:

```cpp
if (cfg.overrides.count("tolerance_ppm"))
{
  cfg.exploration_tolerance_ppm = std::stod(cfg.overrides["tolerance_ppm"]);
  cfg.overrides.erase("tolerance_ppm");
}
else
{
  cfg.exploration_tolerance_ppm = cfg.tolerance_ppm;
}
```

The tol assignment loop (step 1) already initializes `exploration_tolerance_ppm = tolerance_ppm` for all levels, so levels without exploration get the correct default.

### Deconvolution.h/.cpp — Single constructor with explicit tolerances

Remove the current `Deconvolution(const Config& config)` constructor. Replace with:

```cpp
Deconvolution(const Config& config, const DoubleList& tolerance_ppm_values);
```

The constructor uses `tolerance_ppm_values` directly instead of reading from config levels:

```cpp
Deconvolution::Deconvolution(const Config& config, const DoubleList& tolerance_ppm_values)
{
  Param sd_defaults = SpectralDeconvolution().getDefaults();
  sd_defaults.setValue("min_charge", config.deconvolution().min_charge);
  sd_defaults.setValue("max_charge", config.deconvolution().max_charge);
  sd_defaults.setValue("min_mass", config.deconvolution().min_mass);
  sd_defaults.setValue("max_mass", config.deconvolution().max_mass);
  sd_defaults.setValue("tol", tolerance_ppm_values);
  fd_.setParameters(sd_defaults);
  fd_.calculateAveragine(false);
}
```

**Call sites to update:**

| Location | Current | After |
|----------|---------|-------|
| `FLASHIda.cpp:55` (initializer list) | `deconv_(config_)` | `deconv_(config_, buildToleranceList_(config_))` |
| `FLASHIda_exploration_test.cpp` (15 sites) | `Deconvolution deconv(cfg)` | `Deconvolution deconv(cfg, {10.0, 10.0})` (or appropriate values) |
| `FragmentAnalysis_test.cpp` (5 sites) | `Deconvolution deconv(cfg)` | `Deconvolution deconv(cfg, {10.0, 10.0})` |

`FLASHIda` gets a small private helper to build the list:

```cpp
static DoubleList buildToleranceList_(const Config& config)
{
  DoubleList tol;
  for (const auto& [lvl, cfg] : config.levels())
    tol.push_back(cfg.tolerance_ppm);
  return tol;
}
```

### Exploration.h/.cpp — Own Deconvolution, drop shared reference

**Constructor change:**

```cpp
// Before:
Exploration(const Config& config, Deconvolution& deconv, FragmentAnalysis& fragments);

// After:
Exploration(const Config& config, FragmentAnalysis& fragments);
```

**New member:**

```cpp
std::unique_ptr<Deconvolution> exploration_deconv_;
```

Remove `Deconvolution& deconv_` member.

**Constructor body:**

```cpp
Exploration::Exploration(const Config& config, FragmentAnalysis& fragments)
  : config_(config), fragments_(fragments)
{
  DoubleList expl_tol;
  for (const auto& [lvl, cfg] : config.levels())
    expl_tol.push_back(cfg.exploration_tolerance_ppm);
  exploration_deconv_ = std::make_unique<Deconvolution>(config, expl_tol);
}
```

**`feedResult` update (Exploration.cpp:181-183):**

```cpp
// Before:
deconv_.deconvolveMSn(mzs, ints, length, rt, group.precursor_mass, group.precursor_charge);
ms2_deconv = deconv_.storedMS2();

// After:
exploration_deconv_->deconvolveMSn(mzs, ints, length, rt, group.precursor_mass, group.precursor_charge);
ms2_deconv = exploration_deconv_->storedMS2();
```

**Call sites to update:**

| Location | Current | After |
|----------|---------|-------|
| `FLASHIda.cpp:60` (initializer list) | `exploration_(config_, deconv_, fragments_)` | `exploration_(config_, fragments_)` |
| `FLASHIda_exploration_test.cpp` (15 sites) | `Exploration exploration(cfg, deconv, fragments)` | `Exploration exploration(cfg, fragments)` |
| `FragmentAnalysis_test.cpp` (2 sites) | `Exploration exploration(cfg, deconv, fragments)` | `Exploration exploration(cfg, fragments)` |

### FragmentAnalysis.h/.cpp — Explicit tolerance parameter

Add `double tolerance_ppm = 0.0` parameter to the three public methods and the private workhorse:

```cpp
int getTopFragmentMatches(const String& protein_sequence, int n,
                          double* masses, double* qscores, int* charges,
                          double* window_starts, double* window_ends,
                          char* ion_types, int* fragment_indices,
                          DeconvolvedSpectrum& stored_ms2,
                          const String& fragmentation_method = "HCD",
                          double tolerance_ppm = 0.0);
```

Same for `getTerminalFragmentIons`, `getAmbiguityEnclosingIons`, and their `*Py` variants, plus `runTagBasedFragmentMatching_`.

Inside `runTagBasedFragmentMatching_`:

```cpp
// Before:
double ppm_tolerance = config_.level(2).tolerance_ppm;

// After:
double ppm_tol = (tolerance_ppm > 0.0) ? tolerance_ppm : config_.level(2).tolerance_ppm;
```

**Exploration caller (`computeFragmentMatch_`):** passes the exploration tolerance explicitly:

```cpp
double expl_tol = config_.level(group.msn_level).exploration_tolerance_ppm;
fragments_.getTopFragmentMatches(seq, n, ..., "HCD", expl_tol);
```

Existing non-exploration callers pass no tolerance argument (default 0.0 → config fallback). No changes needed at those call sites.

## Files to modify

| File | Change |
|------|--------|
| `Config.h` | Add `exploration_tolerance_ppm` to `MSLevelConfig` |
| `Config.cpp` | Extended tol parsing, validation, exploration tolerance extraction |
| `Deconvolution.h` | Replace constructor: `(const Config&, const DoubleList&)` |
| `Deconvolution.cpp` | Use caller-provided tolerance list |
| `Exploration.h` | Drop `Deconvolution&` param, add `unique_ptr<Deconvolution>` member |
| `Exploration.cpp` | Own deconvolution instance, use exploration tolerance for fragment matching |
| `FragmentAnalysis.h` | Add `double tolerance_ppm` param to public methods + private workhorse |
| `FragmentAnalysis.cpp` | Use explicit tolerance when provided |
| `FLASHIda.h` | Add `buildToleranceList_` helper |
| `FLASHIda.cpp` | Update initializer list for `deconv_` and `exploration_` |
| `FLASHIda_exploration_test.cpp` | Update all `Deconvolution`/`Exploration` construction sites, add tolerance test |
| `FragmentAnalysis_test.cpp` | Update `Deconvolution`/`Exploration` construction sites |

## Testing

### Existing test impact

All existing test configs use `"tol": [10, 10]` and only configure MS1+MS2. These remain valid — 2 entries for 2 levels. No assertions on tolerance values exist.

Call site changes are mechanical (add tolerance list to `Deconvolution`, drop `deconv` from `Exploration`). Existing test behavior is unchanged since `exploration_tolerance_ppm` falls back to `tolerance_ppm` when no override is set.

### New tests

1. **tol validation:** Config with MS3 defined but only `"tol": [10, 10]` → `std::invalid_argument`
2. **tol 3-entry parsing:** Config with `"tol": [10, 10, 20]` and MS3 → `config.level(3).tolerance_ppm == 20.0`
3. **exploration tolerance override:** Config with `"overrides": {"tolerance_ppm": "15"}` at MS2 exploration → `config.level(2).exploration_tolerance_ppm == 15.0`, `config.level(2).tolerance_ppm == 10.0`
4. **exploration tolerance fallback:** Config with exploration but no tolerance override → `exploration_tolerance_ppm == tolerance_ppm`
5. **tolerance_ppm removed from overrides map:** After parsing, `cfg.overrides` should not contain `"tolerance_ppm"` key

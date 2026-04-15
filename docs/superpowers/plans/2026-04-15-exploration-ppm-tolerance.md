# Per-Level Exploration PPM Tolerance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow exploration scans to use a different PPM mass tolerance than regular scans, for both deconvolution and fragment matching, configurable per MS level.

**Architecture:** Extend the `tol` array to one entry per MS level (mandatory), add `exploration_tolerance_ppm` to `MSLevelConfig` (extracted from `overrides["tolerance_ppm"]` or falls back to base), give `Exploration` its own `Deconvolution` instance parameterized with exploration tolerances, and thread an explicit `tolerance_ppm` parameter through `FragmentAnalysis` public methods.

**Tech Stack:** C++20, OpenMS ClassTest framework

**Spec:** `docs/superpowers/specs/2026-04-15-exploration-ppm-tolerance-design.md`

---

### Task 1: Config — extended tol array, validation, and exploration_tolerance_ppm

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:101`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:91-105` (tol parsing)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:338-344` (exploration overrides)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:348-352` (tol assignment)

- [ ] **Step 1: Add `exploration_tolerance_ppm` field to `MSLevelConfig`**

In `Config.h`, after line 101 (`double tolerance_ppm = 10.0;`), add:

```cpp
    double exploration_tolerance_ppm = 10.0;  ///< Resolved exploration tolerance (from overrides or base tol)
```

- [ ] **Step 2: Replace tol parsing with extended array support**

In `Config.cpp`, replace lines 91-105 (from `// Tolerance values:` through `double tol_ms2 = ...`):

```cpp
    // Tolerance values: one entry per MS level, indexed by level-1
    std::vector<double> tol_values;
    if (deconv.contains("tol") && deconv["tol"].is_array())
    {
      for (const auto& v : deconv["tol"])
        tol_values.push_back(v.get<double>());
    }
    if (tol_values.empty())
      tol_values = {10.0, 10.0};
    if (tol_values.size() == 1)
      tol_values.push_back(tol_values[0]);
```

And replace line 107-108 (`// Use MS2 tolerance for tag matching` + assignment):

```cpp
    // Use MS2 tolerance for tag matching (index 1, guaranteed to exist)
    targeting_.tag_matching_tolerance_ppm = tol_values.size() >= 2 ? tol_values[1] : tol_values[0];
```

- [ ] **Step 3: Replace tol assignment loop with validation + exploration tolerance resolution**

In `Config.cpp`, replace lines 348-352 (the `// Set per-level tolerance values` block) with:

```cpp
    // Validate tol array length covers all configured MS levels
    int max_level = 0;
    for (const auto& [lvl, unused_cfg] : levels_)
      max_level = std::max(max_level, lvl);
    if (static_cast<int>(tol_values.size()) < max_level)
      throw std::invalid_argument("deconvolution.tol must have at least "
        + std::to_string(max_level) + " entries when MS" + std::to_string(max_level) + " is configured");

    // Set per-level tolerance values (direct index)
    for (auto& [lvl, cfg] : levels_)
    {
      cfg.tolerance_ppm = tol_values[lvl - 1];
      // Default exploration tolerance to base; overrides (parsed above) take precedence
      if (cfg.overrides.count("tolerance_ppm"))
      {
        cfg.exploration_tolerance_ppm = std::stod(cfg.overrides["tolerance_ppm"]);
        cfg.overrides.erase("tolerance_ppm");
      }
      else
      {
        cfg.exploration_tolerance_ppm = tol_values[lvl - 1];
      }
    }
```

The overrides map is already populated by the exploration parsing block (lines 338-343), so extracting `tolerance_ppm` here (after overrides are set but during tol assignment) avoids ordering issues. The key is removed from overrides after extraction so `ScanConfig::applyOverrides()` never sees it.

- [ ] **Step 4: Remove dead variables**

In `Config.cpp`, delete lines 103-105 (the `tol_ms1`/`tol_ms2` variables):

```cpp
    // DELETE these lines:
    // Store tolerance per level (will be set on MSLevelConfig after level parsing)
    double tol_ms1 = tol_values[0];
    double tol_ms2 = tol_values.size() >= 2 ? tol_values[1] : tol_values[0];
```

- [ ] **Step 5: Verify build compiles**

```bash
cd OpenMS/build && cmake --build . --target FLASHIda_exploration_test 2>&1 | head -40
```

- [ ] **Step 6: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git commit -m "Config: extended tol array, validation, exploration_tolerance_ppm"
```

---

### Task 2: Deconvolution — explicit tolerance constructor

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h:59-60`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp:48-59`

- [ ] **Step 1: Change constructor declaration**

In `Deconvolution.h`, replace lines 59-60:

```cpp
    /// Constructor: initialise SpectralDeconvolution from config and precalculate averagine
    explicit Deconvolution(const Config& config);
```

with:

```cpp
    /// Constructor: initialise SpectralDeconvolution with explicit tolerance values
    /// @param tolerance_ppm_values PPM tolerances indexed by MS level (index 0 = MS1, 1 = MS2, ...)
    Deconvolution(const Config& config, const DoubleList& tolerance_ppm_values);
```

- [ ] **Step 2: Change constructor implementation**

In `Deconvolution.cpp`, replace lines 48-59:

```cpp
  Deconvolution::Deconvolution(const Config& config)
  {
    Param sd_defaults = SpectralDeconvolution().getDefaults();
    sd_defaults.setValue("min_charge", config.deconvolution().min_charge);
    sd_defaults.setValue("max_charge", config.deconvolution().max_charge);
    sd_defaults.setValue("min_mass", config.deconvolution().min_mass);
    sd_defaults.setValue("max_mass", config.deconvolution().max_mass);
    DoubleList tol_values = {config.level(1).tolerance_ppm, config.level(2).tolerance_ppm};
    sd_defaults.setValue("tol", tol_values);
    fd_.setParameters(sd_defaults);
    fd_.calculateAveragine(false);
  }
```

with:

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

- [ ] **Step 3: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp
git commit -m "Deconvolution: replace constructor with explicit tolerance list"
```

---

### Task 3: Exploration — own Deconvolution instance, drop shared reference

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:136,172-173`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:47-50,181-183`

- [ ] **Step 1: Update Exploration.h constructor and members**

In `Exploration.h`, replace line 136:

```cpp
    explicit Exploration(const Config& config, Deconvolution& deconv, FragmentAnalysis& fragments);
```

with:

```cpp
    explicit Exploration(const Config& config, FragmentAnalysis& fragments);
```

Replace lines 172-174 (the private members):

```cpp
    const Config& config_;
    Deconvolution& deconv_;
    FragmentAnalysis& fragments_;
```

with:

```cpp
    const Config& config_;
    FragmentAnalysis& fragments_;
    std::unique_ptr<Deconvolution> exploration_deconv_;
```

Add include at top of `Exploration.h` (after `#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h>`):

```cpp
#include <memory>
```

- [ ] **Step 2: Update Exploration.cpp constructor**

In `Exploration.cpp`, replace lines 47-50:

```cpp
  Exploration::Exploration(const Config& config, Deconvolution& deconv, FragmentAnalysis& fragments)
    : config_(config), deconv_(deconv), fragments_(fragments)
  {
  }
```

with:

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

Add include at top of `Exploration.cpp` (after existing includes):

```cpp
#include <OpenMS/DATASTRUCTURES/ListUtils.h>
```

(for `DoubleList` — check if already included; if so, skip)

- [ ] **Step 3: Update feedResult to use owned deconvolution**

In `Exploration.cpp`, replace lines 181-183:

```cpp
      deconv_.deconvolveMSn(mzs, ints, length, rt,
                            group.precursor_mass, group.precursor_charge);
      ms2_deconv = deconv_.storedMS2();
```

with:

```cpp
      exploration_deconv_->deconvolveMSn(mzs, ints, length, rt,
                                         group.precursor_mass, group.precursor_charge);
      ms2_deconv = exploration_deconv_->storedMS2();
```

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Exploration: own Deconvolution instance with exploration tolerances"
```

---

### Task 4: FragmentAnalysis — explicit tolerance parameter

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:116-126,150-160,182-192,206-215,217-226,228-237,271-275`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:380-384,409,748-758,840-844,1146-1150`

- [ ] **Step 1: Add `tolerance_ppm` parameter to all public method declarations in FragmentAnalysis.h**

In `FragmentAnalysis.h`, replace `getTopFragmentMatches` declaration (lines 116-126):

```cpp
    int getTopFragmentMatches(const String& protein_sequence,
                              int n,
                              double* masses,
                              double* qscores,
                              int* charges,
                              double* window_starts,
                              double* window_ends,
                              char* ion_types,
                              int* fragment_indices,
                              DeconvolvedSpectrum& stored_ms2,
                              const String& fragmentation_method = "HCD");
```

with:

```cpp
    int getTopFragmentMatches(const String& protein_sequence,
                              int n,
                              double* masses,
                              double* qscores,
                              int* charges,
                              double* window_starts,
                              double* window_ends,
                              char* ion_types,
                              int* fragment_indices,
                              DeconvolvedSpectrum& stored_ms2,
                              const String& fragmentation_method = "HCD",
                              double tolerance_ppm = 0.0);
```

Replace `getTerminalFragmentIons` declaration (lines 150-160):

```cpp
    int getTerminalFragmentIons(const String& protein_sequence,
                                int n,
                                double* masses,
                                double* qscores,
                                int* charges,
                                double* window_starts,
                                double* window_ends,
                                char* ion_types,
                                int* fragment_indices,
                                DeconvolvedSpectrum& stored_ms2,
                                const String& fragmentation_method = "HCD");
```

with:

```cpp
    int getTerminalFragmentIons(const String& protein_sequence,
                                int n,
                                double* masses,
                                double* qscores,
                                int* charges,
                                double* window_starts,
                                double* window_ends,
                                char* ion_types,
                                int* fragment_indices,
                                DeconvolvedSpectrum& stored_ms2,
                                const String& fragmentation_method = "HCD",
                                double tolerance_ppm = 0.0);
```

Replace `getAmbiguityEnclosingIons` declaration (lines 182-192):

```cpp
    int getAmbiguityEnclosingIons(const String& protein_sequence,
                                  int n,
                                  double* masses,
                                  double* qscores,
                                  int* charges,
                                  double* window_starts,
                                  double* window_ends,
                                  char* ion_types,
                                  int* fragment_indices,
                                  DeconvolvedSpectrum& stored_ms2,
                                  const String& fragmentation_method = "HCD");
```

with:

```cpp
    int getAmbiguityEnclosingIons(const String& protein_sequence,
                                  int n,
                                  double* masses,
                                  double* qscores,
                                  int* charges,
                                  double* window_starts,
                                  double* window_ends,
                                  char* ion_types,
                                  int* fragment_indices,
                                  DeconvolvedSpectrum& stored_ms2,
                                  const String& fragmentation_method = "HCD",
                                  double tolerance_ppm = 0.0);
```

Replace `runTagBasedFragmentMatching_` private declaration (lines 271-275):

```cpp
    int runTagBasedFragmentMatching_(const String& protein_sequence,
                                    std::vector<TagBasedFragmentMatch>& matches,
                                    DeconvolvedSpectrum& stored_ms2,
                                    std::vector<PTMSite>* ptm_sites = nullptr,
                                    const String& fragmentation_method = "HCD");
```

with:

```cpp
    int runTagBasedFragmentMatching_(const String& protein_sequence,
                                    std::vector<TagBasedFragmentMatch>& matches,
                                    DeconvolvedSpectrum& stored_ms2,
                                    std::vector<PTMSite>* ptm_sites = nullptr,
                                    const String& fragmentation_method = "HCD",
                                    double tolerance_ppm = 0.0);
```

**Note:** The Py variants (`getTopFragmentMatchesPy`, `getTerminalFragmentIonsPy`, `getAmbiguityEnclosingIonsPy`) do NOT need the parameter — they are Python-facing and always use config defaults.

- [ ] **Step 2: Update implementations in FragmentAnalysis.cpp**

Update `runTagBasedFragmentMatching_` signature (line 380-384):

```cpp
  int FragmentAnalysis::runTagBasedFragmentMatching_(const String& protein_sequence,
                                                     std::vector<TagBasedFragmentMatch>& matches,
                                                     DeconvolvedSpectrum& stored_ms2,
                                                     std::vector<PTMSite>* ptm_sites,
                                                     const String& fragmentation_method)
```

with:

```cpp
  int FragmentAnalysis::runTagBasedFragmentMatching_(const String& protein_sequence,
                                                     std::vector<TagBasedFragmentMatch>& matches,
                                                     DeconvolvedSpectrum& stored_ms2,
                                                     std::vector<PTMSite>* ptm_sites,
                                                     const String& fragmentation_method,
                                                     double tolerance_ppm)
```

Replace line 409:

```cpp
    double ppm_tolerance = config_.level(2).tolerance_ppm;
```

with:

```cpp
    double ppm_tolerance = (tolerance_ppm > 0.0) ? tolerance_ppm : config_.level(2).tolerance_ppm;
```

Update `getTopFragmentMatches` signature (lines 748-758) — add `double tolerance_ppm` parameter after `fragmentation_method`:

```cpp
  int FragmentAnalysis::getTopFragmentMatches(const String& protein_sequence,
                                              int n,
                                              double* masses,
                                              double* qscores,
                                              int* charges,
                                              double* window_starts,
                                              double* window_ends,
                                              char* ion_types,
                                              int* fragment_indices,
                                              DeconvolvedSpectrum& stored_ms2,
                                              const String& fragmentation_method,
                                              double tolerance_ppm)
```

And update the delegation call at line 763:

```cpp
    runTagBasedFragmentMatching_(protein_sequence, matches, stored_ms2, nullptr, fragmentation_method);
```

with:

```cpp
    runTagBasedFragmentMatching_(protein_sequence, matches, stored_ms2, nullptr, fragmentation_method, tolerance_ppm);
```

Update `getAmbiguityEnclosingIons` signature (find the function definition around line 830-840) — add `double tolerance_ppm` after `fragmentation_method`. Update delegation call at line 844:

```cpp
    int match_count = runTagBasedFragmentMatching_(protein_sequence, fragment_ion_match, stored_ms2, &ptm_sites, fragmentation_method);
```

with:

```cpp
    int match_count = runTagBasedFragmentMatching_(protein_sequence, fragment_ion_match, stored_ms2, &ptm_sites, fragmentation_method, tolerance_ppm);
```

Update `getTerminalFragmentIons` signature (find definition around line 1140-1146) — add `double tolerance_ppm` after `fragmentation_method`. Update delegation call at line 1150:

```cpp
    runTagBasedFragmentMatching_(protein_sequence, matches, stored_ms2, nullptr, fragmentation_method);
```

with:

```cpp
    runTagBasedFragmentMatching_(protein_sequence, matches, stored_ms2, nullptr, fragmentation_method, tolerance_ppm);
```

- [ ] **Step 3: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
git commit -m "FragmentAnalysis: add explicit tolerance_ppm parameter"
```

---

### Task 5: Exploration — pass exploration tolerance to FragmentAnalysis

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:579-600`

- [ ] **Step 1: Update `computeFragmentMatch_` to pass exploration tolerance**

In `Exploration.cpp`, the `computeFragmentMatch_` method (line 579) calls `fragments_.getTopFragmentMatches()` at line 595-600. Replace:

```cpp
    int count = fragments_.getTopFragmentMatches(
        seq, max_matches,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(),
        spec_copy);
```

with:

```cpp
    int count = fragments_.getTopFragmentMatches(
        seq, max_matches,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(),
        spec_copy, "HCD",
        config_.level(2).exploration_tolerance_ppm);
```

However, `computeFragmentMatch_` doesn't know which MS level it's being called for. It needs the group's MSn level. Looking at the call sites in `computeExplorationScore_` (line 503-519), the `group` parameter carries `msn_level`. But `computeFragmentMatch_` doesn't receive the group.

Change `computeFragmentMatch_` signature to accept the MS level. In `Exploration.h`, update the declaration (around line 217):

```cpp
    FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec) const;
```

to:

```cpp
    FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level) const;
```

In `Exploration.cpp`, update the definition (line 579):

```cpp
  Exploration::FragmentMatchResult Exploration::computeFragmentMatch_(const DeconvolvedSpectrum& spec) const
```

to:

```cpp
  Exploration::FragmentMatchResult Exploration::computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level) const
```

And update the `getTopFragmentMatches` call (lines 595-600):

```cpp
    int count = fragments_.getTopFragmentMatches(
        seq, max_matches,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(),
        spec_copy, "HCD",
        config_.level(msn_level).exploration_tolerance_ppm);
```

Update call sites in `computeExplorationScore_` (lines 513, 517, 522). Replace each `computeFragmentMatch_(spec)` with `computeFragmentMatch_(spec, group.msn_level)`:

Line 513: `fmr = computeFragmentMatch_(spec);` → `fmr = computeFragmentMatch_(spec, group.msn_level);`

Line 517: `fmr = computeFragmentMatch_(spec);` → `fmr = computeFragmentMatch_(spec, group.msn_level);`

Line 522 (FragmentCount case): `auto fmr = computeFragmentMatch_(spec);` → `auto fmr = computeFragmentMatch_(spec, group.msn_level);`

(Verify exact line numbers — these are the three `case` branches in `computeExplorationScore_`.)

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Exploration: pass exploration tolerance to FragmentAnalysis"
```

---

### Task 6: FLASHIda — update initializer list and add helper

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:214-215,241`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:55,60`

- [ ] **Step 1: Add `buildToleranceList_` helper to FLASHIda.h**

In `FLASHIda.h`, add after line 241 (after `Exploration exploration_;`):

```cpp
    /// Build tolerance list from config for Deconvolution construction
    static DoubleList buildToleranceList_(const Config& config);
```

- [ ] **Step 2: Implement helper in FLASHIda.cpp**

Add before the constructor (before line 51, `/// constructor`):

```cpp
  DoubleList FLASHIda::buildToleranceList_(const Config& config)
  {
    DoubleList tol;
    for (const auto& [lvl, cfg] : config.levels())
      tol.push_back(cfg.tolerance_ppm);
    return tol;
  }

```

- [ ] **Step 3: Update FLASHIda initializer list**

In `FLASHIda.cpp`, replace line 55:

```cpp
    deconv_(config_),
```

with:

```cpp
    deconv_(config_, buildToleranceList_(config_)),
```

Replace line 60:

```cpp
    exploration_(config_, deconv_, fragments_)
```

with:

```cpp
    exploration_(config_, fragments_)
```

- [ ] **Step 4: Add `#include <OpenMS/DATASTRUCTURES/ListUtils.h>` to FLASHIda.cpp if not already present**

(Check existing includes; `DoubleList` comes from `ListUtils.h`)

- [ ] **Step 5: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "FLASHIda: update Deconvolution and Exploration construction"
```

---

### Task 7: Update test call sites

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` (15 `Deconvolution` sites, 15 `Exploration` sites)
- Modify: `OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp` (5 `Deconvolution` sites, 2 `Exploration` sites)

- [ ] **Step 1: Update FLASHIda_exploration_test.cpp**

All 15 `Deconvolution deconv(cfg);` lines become `Deconvolution deconv(cfg, {10.0, 10.0});` (the existing test configs all use `"tol": [10, 10]` with MS1+MS2 only).

Lines to change: 744, 784, 808, 852, 887, 1001, 1091, 1163, 1223, 1270, 1320, 1480, 1526, 1558, 1629.

All 15 `Exploration exploration(cfg, deconv, fragments);` lines become `Exploration exploration(cfg, fragments);`.

Lines to change: 746, 786, 810, 854, 889, 1003, 1093, 1165, 1225, 1272, 1322, 1482, 1528, 1560, 1631.

Use find-and-replace:
- `Deconvolution deconv(cfg);` → `Deconvolution deconv(cfg, {10.0, 10.0});`
- `Exploration exploration(cfg, deconv, fragments);` → `Exploration exploration(cfg, fragments);`

- [ ] **Step 2: Update FragmentAnalysis_test.cpp**

All 5 `Deconvolution deconv(cfg);` lines become `Deconvolution deconv(cfg, {10.0, 10.0});`.

Lines: 335, 370, 420, 450, 483.

Both `Exploration exploration(cfg, deconv, fragments);` lines become `Exploration exploration(cfg, fragments);`.

Lines: 452, 485.

- [ ] **Step 3: Verify tests compile and pass**

```bash
cd OpenMS/build && ctest -R FLASHIda_exploration_test -V 2>&1 | tail -30
cd OpenMS/build && ctest -R FragmentAnalysis_test -V 2>&1 | tail -30
```

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp \
        OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp
git commit -m "Update test call sites for new Deconvolution/Exploration constructors"
```

---

### Task 8: Add new tests for exploration tolerance

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add test config with MS3 and exploration tolerance override**

After the existing `ms3_remaining_precursor_config` string (find it in the test file — it ends with `})";`), add:

```cpp
  // Config with 3-entry tol and MS2 exploration tolerance override
  const char* exploration_tolerance_config = R"({
    "deconvolution": {
      "score_threshold": 0.0,
      "tqscore_threshold": 0.9,
      "min_charge": 4,
      "max_charge": 50,
      "min_mass": 500,
      "max_mass": 50000,
      "tol": [10, 10, 20]
    },
    "precursor_selection": {
      "RT_window": 180,
      "target_mode": 0,
      "IDScore": false,
      "AllCharges": false,
      "HCDEnergy": 29,
      "strict_inclusion": false,
      "tie_threshold": 0.1
    },
    "tagging": {
      "min_tag_length": 3,
      "max_tag_length": 8,
      "max_ptm_count": 3,
      "max_flanking_mass_diff": 50000
    },
    "quantification": {
      "enabled": false,
      "reporter_mz_tol": 0.002,
      "fold_change_threshold": 1.4
    },
    "faims": {
      "cv_values": [-50],
      "max_cv_skip": 0,
      "cv_precursor_threshold": 15
    },
    "ms_settings": {
      "ms1": {
        "analyzer": "Orbitrap",
        "first_mass": 500,
        "last_mass": 2000,
        "resolution": 120000,
        "agc_target": 800000,
        "max_it": 246
      },
      "ms2": [
        {
          "analyzer": "Orbitrap",
          "activation": "HCD",
          "collision_energy": 29,
          "resolution": 120000
        }
      ],
      "ms3": [
        {
          "analyzer": "Orbitrap",
          "activation": "CID",
          "collision_energy": 25,
          "resolution": 120000
        }
      ]
    },
    "scheduling": {
      "cycle_time": { "enabled": false, "value_ms": 60000 },
      "scan_timeout": { "enabled": false, "value_ms": 30000 }
    },
    "files": {
      "target_logs": [],
      "fasta": "",
      "inclusion_list": "",
      "ptm_list": ""
    },
    "ms3": {
      "protein_sequence": ""
    },
    "conditional_ms2": false,
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_targets": 3 },
      "ms2": {
        "selection": "none",
        "max_targets": 3,
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
        "selection": "none",
        "max_targets": 3,
        "exploration": {
          "metric": "mass_count",
          "ce_min": 20.0,
          "ce_max": 40.0,
          "ce_step": 5.0
        }
      }
    }
  })";
```

- [ ] **Step 2: Add test sections**

Before the final `END_TEST`, add:

```cpp
START_SECTION(tol_validation_insufficient_entries)
{
  // MS3 configured but only 2 tol entries -> must throw
  // Use remaining_precursor_config which has MS3 but tol=[10,10]
  // (This test only works if ms3_remaining_precursor_config has tol:[10,10])
  TEST_EXCEPTION(std::invalid_argument,
    Config cfg{std::string(ms3_remaining_precursor_config)})
}
END_SECTION

START_SECTION(tol_three_entry_parsing)
{
  Config cfg{std::string(exploration_tolerance_config)};
  // MS1 = 10, MS2 = 10, MS3 = 20
  TEST_REAL_SIMILAR(cfg.level(1).tolerance_ppm, 10.0)
  TEST_REAL_SIMILAR(cfg.level(2).tolerance_ppm, 10.0)
  TEST_REAL_SIMILAR(cfg.level(3).tolerance_ppm, 20.0)
}
END_SECTION

START_SECTION(exploration_tolerance_override)
{
  Config cfg{std::string(exploration_tolerance_config)};
  // MS2 exploration has overrides.tolerance_ppm = "15"
  TEST_REAL_SIMILAR(cfg.level(2).exploration_tolerance_ppm, 15.0)
  // MS2 base tolerance is still 10
  TEST_REAL_SIMILAR(cfg.level(2).tolerance_ppm, 10.0)
  // MS3 exploration has no override -> falls back to tol[2] = 20
  TEST_REAL_SIMILAR(cfg.level(3).exploration_tolerance_ppm, 20.0)
  // tolerance_ppm should be removed from overrides map
  TEST_EQUAL(cfg.level(2).overrides.count("tolerance_ppm"), 0)
}
END_SECTION

START_SECTION(exploration_tolerance_fallback)
{
  // exploration_config has exploration at MS2 but NO tolerance override
  Config cfg{std::string(exploration_config)};
  // exploration_tolerance_ppm should equal base tolerance
  TEST_REAL_SIMILAR(cfg.level(2).exploration_tolerance_ppm, 10.0)
  TEST_REAL_SIMILAR(cfg.level(2).tolerance_ppm, 10.0)
}
END_SECTION
```

**Important:** The `tol_validation_insufficient_entries` test assumes `ms3_remaining_precursor_config` has `"tol": [10, 10]` and configures MS3. Verify this is the case — if that config already has 3+ tol entries, create a minimal config string for this test instead.

- [ ] **Step 3: Run tests**

```bash
cd OpenMS/build && ctest -R FLASHIda_exploration_test -V 2>&1 | tail -40
```

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Add tests for exploration tolerance: validation, override, fallback"
```

---

### Task 9: Update ms3_remaining_precursor_config for tol validation

The `ms3_remaining_precursor_config` in the test file has `"tol": [10, 10]` but configures MS3 via `selection_strategy.ms3`. After Task 1's validation change, this config will throw. It needs to be updated to `"tol": [10, 10, 10]`.

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Update ms3_remaining_precursor_config tol array**

Find the `ms3_remaining_precursor_config` string in the test file and change:

```cpp
      "tol": [10, 10]
```

to:

```cpp
      "tol": [10, 10, 10]
```

- [ ] **Step 2: Check for any other test configs with MS3 and only 2 tol entries**

Search for configs that define `ms3` in `selection_strategy` or `ms_settings` but have `"tol": [10, 10]`. These also need updating to 3 entries. Known candidates:

- `exploration_ms3_config` (if it exists in the test file)
- Any config in `FragmentAnalysis_test.cpp` that configures MS3

Update all found instances by adding a third tol entry: `"tol": [10, 10, 10]`.

- [ ] **Step 3: Run all affected tests**

```bash
cd OpenMS/build && ctest -R FLASHIda_exploration_test -V 2>&1 | tail -40
cd OpenMS/build && ctest -R FragmentAnalysis_test -V 2>&1 | tail -40
```

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp \
        OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp
git commit -m "Update test configs: add third tol entry for MS3 validation"
```

---

### Task 10: Run full test suite and verify

- [ ] **Step 1: Run all FLASHIda tests**

```bash
cd OpenMS/build && ctest -R "FLASHIda|ScanCommand|FragmentAnalysis|DeconvolvedSpectrum" -V 2>&1 | tail -60
```

Expected: all tests pass.

- [ ] **Step 2: Verify no compiler warnings**

```bash
cd OpenMS/build && cmake --build . --target FLASHIda_exploration_test 2>&1 | grep -i "warning\|error" | head -20
```

Expected: no warnings or errors.

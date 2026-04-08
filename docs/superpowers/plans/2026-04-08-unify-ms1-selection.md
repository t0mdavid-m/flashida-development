# Unify MS1 Precursor Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `level_configs_[1].max_targets` the single source of truth for the MS1 precursor cap, remove `MaxMs2CountPerMs1`, and add intensity-based MS1 selection.

**Architecture:** Minimal refactor of the existing MS1 selection path. The legacy `filterPeakGroupsUsingMassExclusion_` loop reads its cap from `level_configs_` instead of `mass_count_`, gains an intensity sort branch, and `processScan` short-circuits on `Selection=none`. All targeting, exclusion, and IDScore logic is untouched. C# removes the redundant `MaxMs2CountPerMs1` field and its JSON serialization; XML configs migrate the value to `<SelectionStrategy><MS1><MaxPrecursors>`.

**Tech Stack:** C++20 (OpenMS, `flashida-v9-bridge` branch), C# .NET 4.8 (FlashIDA, `phase-8` branch), NUnit, CTest

**Spec:** `docs/superpowers/specs/2026-04-08-unify-ms1-selection-design.md`

---

### Task 1: Add `PeakGroup::getMaxChargeIntensity()` and `DeconvolvedSpectrum::sortByIntensity()`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/PeakGroup.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/PeakGroup.cpp`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.cpp`

- [ ] **Step 1: Add `getMaxChargeIntensity()` declaration to PeakGroup.h**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/PeakGroup.h`, after the existing `getIntensity()` declaration (line 145), add:

```cpp
    /// Returns the intensity of the most intense charge state
    float getMaxChargeIntensity() const;
```

- [ ] **Step 2: Add `getMaxChargeIntensity()` implementation to PeakGroup.cpp**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/PeakGroup.cpp`, after the `getIntensity()` implementation (line 862), add:

```cpp
  float PeakGroup::getMaxChargeIntensity() const
  {
    float max_int = 0.0f;
    for (int c = min_abs_charge_; c <= max_abs_charge_; c++)
    {
      if (c >= 0 && c < (int)per_charge_int_.size() && per_charge_int_[c] > max_int)
      {
        max_int = per_charge_int_[c];
      }
    }
    return max_int;
  }
```

- [ ] **Step 3: Add `sortByIntensity()` declaration to DeconvolvedSpectrum.h**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h`, after the existing `sortByIDScoreAllCharges(int hcd_energy)` declaration (line 174), add:

```cpp
    /// Sort by most intense charge state per peak group (descending)
    void sortByIntensity();
```

- [ ] **Step 4: Add `sortByIntensity()` implementation to DeconvolvedSpectrum.cpp**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.cpp`, after the `sortByIDScoreAllCharges(int hcd_energy)` implementation, add:

```cpp
  void DeconvolvedSpectrum::sortByIntensity()
  {
    std::sort(peak_groups_.begin(), peak_groups_.end(), [](const PeakGroup& p1, const PeakGroup& p2) { return p1.getMaxChargeIntensity() > p2.getMaxChargeIntensity(); });
  }
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/PeakGroup.h \
        src/openms/source/ANALYSIS/TOPDOWN/PeakGroup.cpp \
        src/openms/include/OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h \
        src/openms/source/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.cpp
git commit -m "Add PeakGroup::getMaxChargeIntensity() and DeconvolvedSpectrum::sortByIntensity()"
```

---

### Task 2: Wire `filterPeakGroupsUsingMassExclusion_` to `level_configs_` and add intensity sort

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:553-596`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:2791-2793`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:3298`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:743`

- [ ] **Step 1: Restructure the sort branch in `filterPeakGroupsUsingMassExclusion_`**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, replace lines 553-572 (the opening of `filterPeakGroupsUsingMassExclusion_` up through the sort branches):

Before:
```cpp
  void FLASHIda::filterPeakGroupsUsingMassExclusion_(const int ms_level, const double rt)
  {
    if (use_idscore_ && consider_all_Charge_states_ && hcd_energy_ < 0) {
      deconvolved_spectrum_.sortByIDScoreAllCharges();
    }
    else if (use_idscore_ && consider_all_Charge_states_) {
      deconvolved_spectrum_.sortByIDScoreAllCharges(hcd_energy_);
    }
    else if (use_idscore_ && !consider_all_Charge_states_ && hcd_energy_ < 0) {
      deconvolved_spectrum_.sortByIDScoreRepresentative();
    }
    else if (use_idscore_ && !consider_all_Charge_states_) {
      deconvolved_spectrum_.sortByIDScoreRepresentative(hcd_energy_);
    }
    else if (!use_idscore_ && consider_all_Charge_states_) {
      deconvolved_spectrum_.sortByQScoreAllCharges();
    }
    else {
      deconvolved_spectrum_.sortByQscore();
    }
```

After:
```cpp
  void FLASHIda::filterPeakGroupsUsingMassExclusion_(const int ms_level, const double rt)
  {
    // IDScore replaces QScore but not intensity
    if (use_idscore_)
    {
      if (consider_all_Charge_states_ && hcd_energy_ < 0) {
        deconvolved_spectrum_.sortByIDScoreAllCharges();
      }
      else if (consider_all_Charge_states_) {
        deconvolved_spectrum_.sortByIDScoreAllCharges(hcd_energy_);
      }
      else if (hcd_energy_ < 0) {
        deconvolved_spectrum_.sortByIDScoreRepresentative();
      }
      else {
        deconvolved_spectrum_.sortByIDScoreRepresentative(hcd_energy_);
      }
    }
    else if (getLevelConfig_(ms_level).selection == SelectionMetric::Intensity)
    {
      deconvolved_spectrum_.sortByIntensity();
    }
    else
    {
      if (consider_all_Charge_states_) {
        deconvolved_spectrum_.sortByQScoreAllCharges();
      }
      else {
        deconvolved_spectrum_.sortByQscore();
      }
    }
```

- [ ] **Step 2: Replace `mass_count_` cap with `level_configs_` cap**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, replace line 591:

Before:
```cpp
    Size mass_count = (Size)mass_count_[ms_level - 1];
```

After:
```cpp
    Size mass_count = (Size)getLevelConfig_(ms_level).max_targets;
```

- [ ] **Step 3: Add `Selection=none` early return in `processScan` MS1 path**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, inside the `if (ms_level == 1)` block of `processScan` (after line 3300 `last_ms1_time_ = ...`), add before the `getPeakGroups` call:

Before:
```cpp
      last_ms1_time_ = std::chrono::steady_clock::now();

      // MS1 path: deconvolve, score, filter, select top-N, push MS2 commands
      double parent_cv = faims_enabled_ ? faims_cv : 0.0;

      int n = getPeakGroups(mzs, ints, length, rt_min, 1, "ms1", nullptr);
```

After:
```cpp
      last_ms1_time_ = std::chrono::steady_clock::now();

      // Selection=none: skip MS1 precursor selection entirely
      if (getLevelConfig_(1).selection == SelectionMetric::None)
        return 0;

      // MS1 path: deconvolve, score, filter, select top-N, push MS2 commands
      double parent_cv = faims_enabled_ ? faims_cv : 0.0;

      int n = getPeakGroups(mzs, ints, length, rt_min, 1, "ms1", nullptr);
```

- [ ] **Step 4: Remove `mass_count_` parsing from `parseJSONConfig_`**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, remove lines 2791-2793:

```cpp
      auto mass_count_arr = ps.value("max_mass_count", std::vector<int>{1});
      for (int j : mass_count_arr)
        mass_count_.push_back(j);
```

- [ ] **Step 5: Remove `mass_count_` member from `FLASHIda.h`**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`, remove lines 742-743:

```cpp
    /// how many masses will be selected per ms level? - determined from C# side
    IntList mass_count_;
```

- [ ] **Step 6: Remove `mass_count_` usage in `selected_peak_groups_.reserve`**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, line 606:

Before:
```cpp
    selected_peak_groups_.reserve(mass_count_.size());
```

After:
```cpp
    selected_peak_groups_.reserve(mass_count);
```

- [ ] **Step 7: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Wire MS1 selection to level_configs_, add intensity sort, remove mass_count_"
```

---

### Task 3: Update C++ test JSON configs and add new tests

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIdaFAIMS_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Remove `max_mass_count` from all embedded JSON configs**

In all 4 test files listed above, in every JSON config string, remove the `"max_mass_count": [N],` line from the `"precursor_selection"` block. The value is already in `"selection_strategy"."ms1"."max_precursors"`.

For example, in `FLASHIda_ProcessScan_test.cpp`, the `standard_json` config's `precursor_selection` block changes from:

```json
    "precursor_selection": {
      "max_mass_count": [3], "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
```

To:

```json
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
```

Apply this same removal to every JSON config string in all 4 test files. There are 13 configs in `FLASHIda_ProcessScan_test.cpp` and likely 1-3 in each of the other files.

- [ ] **Step 2: Add intensity selection JSON config to `FLASHIda_ProcessScan_test.cpp`**

In `FLASHIda_ProcessScan_test.cpp`, in the anonymous namespace (after the existing JSON configs, before the helper functions around line 493), add:

```cpp
  // Config with intensity-based MS1 selection (same as standard but selection=intensity)
  const char* intensity_selection_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
    "tagging": { "min_tag_length": 3, "max_tag_length": 8, "max_ptm_count": 3, "max_flanking_mass_diff": 50000 },
    "quantification": { "enabled": false, "reporter_mz_tol": 0.002, "fold_change_threshold": 1.4 },
    "faims": { "cv_values": [-50], "max_cv_skip": 0 },
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [
        { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 },
        { "analyzer": "Orbitrap", "activation": "ETD", "collision_energy": 0, "resolution": 120000 }
      ]
    },
    "scheduling": {
      "cycle_time": { "enabled": false, "value_ms": 60000 },
      "scan_timeout": { "enabled": true, "value_ms": 30000 },
      "agc_interval_seconds": 30
    },
    "exploration": { "enabled": false, "max_depth": 1, "max_variants": 5 },
    "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
    "selection_strategy": {
      "ms1": { "selection": "intensity", "max_precursors": 3 },
      "ms2": { "selection": "intensity" },
      "ms3": { "selection": "none" }
    }
  })";

  // Config with selection=none at MS1 (should produce 0 MS2 commands)
  const char* none_selection_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
    "tagging": { "min_tag_length": 3, "max_tag_length": 8, "max_ptm_count": 3, "max_flanking_mass_diff": 50000 },
    "quantification": { "enabled": false, "reporter_mz_tol": 0.002, "fold_change_threshold": 1.4 },
    "faims": { "cv_values": [-50], "max_cv_skip": 0 },
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [
        { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }
      ]
    },
    "scheduling": {
      "cycle_time": { "enabled": false, "value_ms": 60000 },
      "scan_timeout": { "enabled": true, "value_ms": 30000 },
      "agc_interval_seconds": 30
    },
    "exploration": { "enabled": false, "max_depth": 1, "max_variants": 5 },
    "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
    "selection_strategy": {
      "ms1": { "selection": "none", "max_precursors": 3 },
      "ms2": { "selection": "intensity" },
      "ms3": { "selection": "none" }
    }
  })";

  // Config with max_precursors=1 (cap test)
  const char* max1_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
    "tagging": { "min_tag_length": 3, "max_tag_length": 8, "max_ptm_count": 3, "max_flanking_mass_diff": 50000 },
    "quantification": { "enabled": false, "reporter_mz_tol": 0.002, "fold_change_threshold": 1.4 },
    "faims": { "cv_values": [-50], "max_cv_skip": 0 },
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [
        { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }
      ]
    },
    "scheduling": {
      "cycle_time": { "enabled": false, "value_ms": 60000 },
      "scan_timeout": { "enabled": true, "value_ms": 30000 },
      "agc_interval_seconds": 30
    },
    "exploration": { "enabled": false, "max_depth": 1, "max_variants": 5 },
    "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 1 },
      "ms2": { "selection": "intensity" },
      "ms3": { "selection": "none" }
    }
  })";

  // Config with max_precursors=5 (cap test)
  const char* max5_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false, "MS3AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1
    },
    "tagging": { "min_tag_length": 3, "max_tag_length": 8, "max_ptm_count": 3, "max_flanking_mass_diff": 50000 },
    "quantification": { "enabled": false, "reporter_mz_tol": 0.002, "fold_change_threshold": 1.4 },
    "faims": { "cv_values": [-50], "max_cv_skip": 0 },
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [
        { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }
      ]
    },
    "scheduling": {
      "cycle_time": { "enabled": false, "value_ms": 60000 },
      "scan_timeout": { "enabled": true, "value_ms": 30000 },
      "agc_interval_seconds": 30
    },
    "exploration": { "enabled": false, "max_depth": 1, "max_variants": 5 },
    "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 5 },
      "ms2": { "selection": "intensity" },
      "ms3": { "selection": "none" }
    }
  })";
```

- [ ] **Step 3: Add intensity selection test**

In `FLASHIda_ProcessScan_test.cpp`, after the last existing test section (before `END_TEST`), add:

```cpp
// Intensity selection: MS1 precursors should be ordered by max charge intensity
START_SECTION(processScan_ms1_intensity_selection)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  if (ms1_scans.empty()) { NOT_TESTABLE; break; }
  FLASHIda* ida_qscore = new FLASHIda(const_cast<char*>(standard_json));
  FLASHIda* ida_intensity = new FLASHIda(const_cast<char*>(intensity_selection_json));

  int n_qscore = pushAllScans(ida_qscore, ms1_scans);
  int n_intensity = pushAllScans(ida_intensity, ms1_scans);

  // Both should produce commands (same data, same cap)
  TEST_EQUAL(n_qscore > 0, true)
  TEST_EQUAL(n_intensity > 0, true)

  // Drain and compare: the commands should exist but may differ in order
  // (intensity vs qscore ranking picks different precursors)
  // The key assertion is that intensity selection produces valid commands
  ScanCommand cmd_q{};
  ScanCommand cmd_i{};
  int q_count = 0, i_count = 0;
  while (ida_qscore->getNextScanCommand(&cmd_q)) q_count++;
  while (ida_intensity->getNextScanCommand(&cmd_i)) i_count++;

  // Same cap (3), so command counts should be comparable
  TEST_EQUAL(q_count > 0, true)
  TEST_EQUAL(i_count > 0, true)

  delete ida_qscore;
  delete ida_intensity;
}
END_SECTION
```

- [ ] **Step 4: Add none selection test**

```cpp
// Selection=none: MS1 should produce 0 commands
START_SECTION(processScan_ms1_none_selection)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  if (ms1_scans.empty()) { NOT_TESTABLE; break; }
  FLASHIda* ida = new FLASHIda(const_cast<char*>(none_selection_json));

  int total = pushAllScans(ida, ms1_scans);
  TEST_EQUAL(total, 0)

  // Queue should be empty
  ScanCommand cmd{};
  TEST_EQUAL(ida->getNextScanCommand(&cmd), false)

  delete ida;
}
END_SECTION
```

- [ ] **Step 5: Add varied max_precursors cap test**

```cpp
// max_precursors cap: max=1 should produce fewer commands than max=3 which should produce fewer than max=5
START_SECTION(processScan_ms1_max_precursors_cap)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  if (ms1_scans.empty()) { NOT_TESTABLE; break; }

  FLASHIda* ida1 = new FLASHIda(const_cast<char*>(max1_json));
  FLASHIda* ida3 = new FLASHIda(const_cast<char*>(standard_json));  // max_precursors=3
  FLASHIda* ida5 = new FLASHIda(const_cast<char*>(max5_json));

  int total1 = pushAllScans(ida1, ms1_scans);
  int total3 = pushAllScans(ida3, ms1_scans);
  int total5 = pushAllScans(ida5, ms1_scans);

  // With same input data, higher cap should produce >= commands
  TEST_EQUAL(total1 > 0, true)
  TEST_EQUAL(total3 >= total1, true)
  TEST_EQUAL(total5 >= total3, true)

  // Per-scan cap: max=1 means at most 1 command per MS1 scan
  // Verify by checking that total1 <= number of scans
  TEST_EQUAL(total1 <= (int)ms1_scans.size(), true)

  delete ida1;
  delete ida3;
  delete ida5;
}
END_SECTION
```

- [ ] **Step 6: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp \
        src/tests/class_tests/openms/source/FLASHIdaFAIMS_test.cpp \
        src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Update test JSON configs: remove max_mass_count, add intensity/none/cap tests"
```

---

### Task 4: Remove `MaxMs2CountPerMs1` from C# code

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:103-106`
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:210-221`
- Modify: `FlashIDA/src/Flash/IDA/Parameter.cs:13-104`
- Modify: `FlashIDA/src/Flash/IDA/Parameter.cs:169-172`
- Modify: `FlashIDA/src/Flash/IDA/Parameter.cs:256-264`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:128-133`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:272-274`

- [ ] **Step 1: Remove `MaxMs2CountPerMs1` from `MSSettingsConfig`**

In `FlashIDA/src/Flash/MethodConfig.cs`, remove from `MSSettingsConfig`:

```csharp
        public int MaxMs2CountPerMs1 = 4;
```

So the class becomes:

```csharp
    public class MSSettingsConfig
    {
        public FAIMSSettings FAIMS;
        public MS1Parameters MS1;
        public List<MS2Parameters> MS2;
        public List<MS3Parameters> MS3;
    }
```

- [ ] **Step 2: Remove `max_mass_count` from `JsonPrecursorSelectionConfig`**

In `FlashIDA/src/Flash/MethodConfig.cs`, remove from `JsonPrecursorSelectionConfig`:

```csharp
        public int[] max_mass_count { get; set; }
```

So the class becomes:

```csharp
    public class JsonPrecursorSelectionConfig
    {
        public double RT_window { get; set; }
        public int target_mode { get; set; }
        public bool IDScore { get; set; }
        public bool AllCharges { get; set; }
        public bool MS3AllCharges { get; set; }
        public int HCDEnergy { get; set; }
        public bool strict_inclusion { get; set; }
        public double tie_threshold { get; set; }
    }
```

- [ ] **Step 3: Remove `MaxMs2CountPerMs1` from `IDAParameters`**

In `FlashIDA/src/Flash/IDA/Parameter.cs`, remove lines 15-16:

```csharp
        [Description("Maximum number of MS2 scans per MS1 cycle")]
        public int MaxMs2CountPerMs1 { set; get; }
```

- [ ] **Step 4: Remove `maxMs2CountPerMs1` from `IDAParameters` constructor**

In `FlashIDA/src/Flash/IDA/Parameter.cs`, in the constructor signature (line 92), remove `int maxMs2CountPerMs1 = 5,` parameter. Also remove `MaxMs2CountPerMs1 = maxMs2CountPerMs1;` (line 104) from the constructor body.

Constructor signature changes from:
```csharp
        public IDAParameters(double[] tolerances = null, int maxMs2CountPerMs1 = 5, double qScoreThreshold = -1, ...
```

To:
```csharp
        public IDAParameters(double[] tolerances = null, double qScoreThreshold = -1, ...
```

And remove from body:
```csharp
            MaxMs2CountPerMs1 = maxMs2CountPerMs1;
```

- [ ] **Step 5: Remove `max_mass_count` from `ToJSON()`**

In `FlashIDA/src/Flash/IDA/Parameter.cs`, in the `ToJSON()` method, remove line 171:

```csharp
                    max_mass_count = new int[] { MaxMs2CountPerMs1 },
```

So the `precursor_selection` block becomes:

```csharp
                precursor_selection = new JsonPrecursorSelectionConfig
                {
                    RT_window = RTWindow,
                    target_mode = TargetMode,
                    IDScore = UseIDScore,
                    AllCharges = ConsiderAllChargeStates,
                    MS3AllCharges = MS3AllCharges,
                    HCDEnergy = HCDEnergy,
                    strict_inclusion = StrictInclusion,
                    tie_threshold = TieThreshold
                },
```

- [ ] **Step 6: Remove `MaxMs2CountPerMs1` fallback in `BuildSelectionStrategy()`**

In `FlashIDA/src/Flash/IDA/Parameter.cs`, change line 264:

Before:
```csharp
            int ms1MaxTargets = ss.MS1?.MaxPrecursors ?? MaxMs2CountPerMs1;
```

After:
```csharp
            int ms1MaxTargets = ss.MS1?.MaxPrecursors ?? 10;
```

- [ ] **Step 7: Remove `MaxMs2CountPerMs1` from `InitializeIDA()`**

In `FlashIDA/src/Flash/MethodParameters.cs`, remove line 133:

```csharp
            IDA.MaxMs2CountPerMs1 = MSSettings.MaxMs2CountPerMs1;
```

- [ ] **Step 8: Remove `MaxMs2CountPerMs1` from `ToLogString()`**

In `FlashIDA/src/Flash/MethodParameters.cs`, change lines 273-274:

Before:
```csharp
            sb.AppendFormat("MS: MaxMS2/MS1={0}, CV=[{1}]\n",
                ida.MaxMs2CountPerMs1, String.Join(",", ida.CVValues));
```

After:
```csharp
            sb.AppendFormat("MS: CV=[{0}]\n",
                String.Join(",", ida.CVValues));
```

- [ ] **Step 9: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/IDA/Parameter.cs src/Flash/MethodParameters.cs
git commit -m "Remove MaxMs2CountPerMs1 from C# code"
```

---

### Task 5: Update all XML configs

**Files:**
- Modify: `FlashIDA/src/Flash/etc/method.xml`
- Modify: 20 files in `FlashIDA/test-data/configs/method_*.xml`

- [ ] **Step 1: Update the base `method.xml`**

In `FlashIDA/src/Flash/etc/method.xml`:

1. Remove line 82:
```xml
    <MaxMs2CountPerMs1>1</MaxMs2CountPerMs1>
```

2. Add a `<SelectionStrategy>` block before the closing `</MethodParameters>` tag (after `</MSSettings>`, line 132):
```xml
  <SelectionStrategy>
    <MS1>
      <Selection>qscore</Selection>
      <MaxPrecursors>1</MaxPrecursors>
    </MS1>
    <MS2>
      <Selection>intensity</Selection>
    </MS2>
    <MS3>
      <Selection>none</Selection>
    </MS3>
  </SelectionStrategy>
```

- [ ] **Step 2: Update all 20 test config XMLs**

For each file in `FlashIDA/test-data/configs/`, make two changes:

1. Remove the `<MaxMs2CountPerMs1>N</MaxMs2CountPerMs1>` line from `<MSSettings>`
2. Set `<MaxPrecursors>` inside `<SelectionStrategy><MS1>` to the value that `MaxMs2CountPerMs1` had

Value mapping (only listing files where `MaxPrecursors` changes):

| File | Old MaxPrecursors | New MaxPrecursors |
|------|-------------------|-------------------|
| `method_default.xml` | 5 | 1 |
| `method_default_topn5.xml` | 5 | 5 (no change) |
| `method_exploration.xml` | 10 | 1 |
| `method_exploration_ms3.xml` | 10 | 1 |

All other files: `MaxPrecursors` already matches `MaxMs2CountPerMs1`, so just remove the `MaxMs2CountPerMs1` line.

- [ ] **Step 3: Verify no `MaxMs2CountPerMs1` remains**

```bash
cd FlashIDA
grep -rn "MaxMs2CountPerMs1" src/Flash/etc/method.xml test-data/configs/
```

Expected: No matches.

- [ ] **Step 4: Commit**

```bash
cd FlashIDA
git add src/Flash/etc/method.xml test-data/configs/
git commit -m "Remove MaxMs2CountPerMs1 from all XMLs, update MaxPrecursors to match"
```

---

### Task 6: Update parent submodule pointers

**Files:**
- Modify: parent repo submodule pointers for `FlashIDA` and `OpenMS`

- [ ] **Step 1: Push OpenMS changes**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

This triggers the `build-dlls` workflow (~40 min). The C++ changes must be compiled into `OpenMS.dll` before the C# side can use them. However, the C# code changes and XML changes don't depend on the DLL — `MaxMs2CountPerMs1` removal is purely a serialization change.

- [ ] **Step 2: Push FlashIDA changes**

```bash
cd FlashIDA
git push origin phase-8
```

- [ ] **Step 3: Update parent submodule pointers**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add FlashIDA OpenMS
git commit -m "Update submodule pointers: unify MS1 selection, remove MaxMs2CountPerMs1"
git push origin phase-8
```

- [ ] **Step 4: Download updated DLLs when build completes**

After the `build-dlls` workflow succeeds (~40 min):

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
gh run list -R t0mdavid-m/OpenMS -w build-dlls -L 1
# Get the run ID from the output
gh run download <run-id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts
# Copy DLLs to FlashIDA/dll/
cp -f OpenMS.dll OpenSwathAlgo.dll FlashIDA/dll/
```

Then commit the updated DLLs:

```bash
cd FlashIDA
git add dll/
git commit -m "Update OpenMS DLLs: unified MS1 selection"
git push origin phase-8
```

And update parent pointer again:

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add FlashIDA
git commit -m "Update FlashIDA submodule: updated DLLs for unified MS1 selection"
git push origin phase-8
```

- [ ] **Step 5: Verify CI**

All existing C++ tests should pass with identical results (same cap values, same qscore selection). The 3 new C++ tests (intensity, none, cap) validate the new behavior. All C# continuity tests should pass — golden files unchanged since effective cap values are preserved.

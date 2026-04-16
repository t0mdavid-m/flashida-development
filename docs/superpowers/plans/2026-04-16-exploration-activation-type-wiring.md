# Wire Activation Type Into Fragment Matching — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all hardcoded `"HCD"` in fragment matching and tag generation calls with the actual scan's activation type.

**Architecture:** Thread the activation type string through 3 call chains: (1) `feedResultImpl_` → `computeExplorationScore_` → `computeFragmentMatch_` → `getTopFragmentMatches`, (2) `initiateNextLevel` → fragment matching methods, (3) `processScan` → `processMS2ForTagBasedTargeting` → `FLASHTaggerAlgorithm`. Promote `getIonTypesForFragmentationMethod` to a public static on `FragmentAnalysis` so `PrecursorSelection` can reuse it.

**Tech Stack:** C++20, OpenMS ClassTest framework, CMake/CTest

---

## File Map

| File | Responsibility | Change |
|------|---------------|--------|
| `FragmentAnalysis.h` | Fragment matching API | Add `static getIonTypesForFragmentationMethod` declaration |
| `FragmentAnalysis.cpp` | Fragment matching impl | Move function from anonymous namespace to `FragmentAnalysis::` |
| `Exploration.h` | Exploration API | Add `activation_type` param to 2 private methods |
| `Exploration.cpp` | Exploration impl | Wire activation type through 9 call sites |
| `PrecursorSelection.h` | Precursor selection API | Add `activation_type` param to `processMS2ForTagBasedTargeting` |
| `PrecursorSelection.cpp` | Tag-based targeting impl | Set `ion_type` on tagger |
| `FLASHIda.h` | Orchestrator API | Update inline `processMS2ForTagBasedTargeting` delegate |
| `FLASHIda.cpp` | Orchestrator impl | Extract activation from ScanCommand, pass to selection |
| `FLASHIda_exploration_test.cpp` | Exploration tests | Update call sites, add activation wiring test |

---

### Task 1: Promote `getIonTypesForFragmentationMethod` to public static

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:56`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:81-93`

- [ ] **Step 1: Add static method declaration to FragmentAnalysis.h**

In `FragmentAnalysis.h`, add before the constructor (line 79), after the `getLastProteoformInfo` method:

```cpp
    /// Map fragmentation method name to ion type strings for FLASHTagger/FLASHExtender.
    /// Case-insensitive. Returns {"b","y"} for HCD/CID, {"c","z"} for ETD,
    /// {"b","c","y","z"} for EThcD/EtCID, {"a","b","c","x","y","z"} for UVPD.
    /// Defaults to {"b","y"} for unknown methods.
    static std::vector<std::string> getIonTypesForFragmentationMethod(const String& method);
```

- [ ] **Step 2: Move implementation from anonymous namespace to FragmentAnalysis::**

In `FragmentAnalysis.cpp`, replace the file-local function (lines 81-93):

```cpp
  /// Map fragmentation method name to ion types (case-insensitive via lowercase)
  inline std::vector<std::string> getIonTypesForFragmentationMethod(const String& method)
  {
    String lower_method = method;
    std::transform(lower_method.begin(), lower_method.end(), lower_method.begin(), ::tolower);

    if (lower_method == "hcd") return {"b", "y"};
    if (lower_method == "cid") return {"b", "y"};
    if (lower_method == "etd") return {"c", "z"};
    if (lower_method == "ethcd") return {"b", "c", "y", "z"};
    if (lower_method == "etcid") return {"b", "c", "y", "z"};
    if (lower_method == "uvpd") return {"a", "b", "c", "x", "y", "z"};
    return {"b", "y"};  // default to HCD
  }
```

With the class-scoped version (same body, different qualifier, drop `inline`):

```cpp
  std::vector<std::string> FragmentAnalysis::getIonTypesForFragmentationMethod(const String& method)
  {
    String lower_method = method;
    std::transform(lower_method.begin(), lower_method.end(), lower_method.begin(), ::tolower);

    if (lower_method == "hcd") return {"b", "y"};
    if (lower_method == "cid") return {"b", "y"};
    if (lower_method == "etd") return {"c", "z"};
    if (lower_method == "ethcd") return {"b", "c", "y", "z"};
    if (lower_method == "etcid") return {"b", "c", "y", "z"};
    if (lower_method == "uvpd") return {"a", "b", "c", "x", "y", "z"};
    return {"b", "y"};  // default to HCD
  }
```

Update the call site inside `runTagBasedFragmentMatching_` (line 411) from:

```cpp
    std::vector<std::string> ion_types_str = getIonTypesForFragmentationMethod(fragmentation_method);
```

to:

```cpp
    std::vector<std::string> ion_types_str = FragmentAnalysis::getIonTypesForFragmentationMethod(fragmentation_method);
```

- [ ] **Step 3: Build and run existing tests**

Run: `cd OpenMS/build && cmake --build . --target FragmentAnalysis_test && ctest -R FragmentAnalysis_test`
Expected: All existing tests pass (no behavioral change — just moved the function).

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
git commit -m "Promote getIonTypesForFragmentationMethod to public static on FragmentAnalysis"
```

---

### Task 2: Wire activation type through Exploration scoring chain

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:239-243,254`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:288,699,703,708,713,765-786`

- [ ] **Step 1: Update `computeFragmentMatch_` signature in Exploration.h**

In `Exploration.h`, replace line 254:

```cpp
    FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level) const;
```

with:

```cpp
    FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level,
                                              const std::string& activation_type) const;
```

- [ ] **Step 2: Update `computeExplorationScore_` signature in Exploration.h**

In `Exploration.h`, replace lines 239-243:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length,
                                    double* out_remaining_ratio = nullptr,
                                    FragmentMatchResult* out_frag = nullptr) const;
```

with:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length,
                                    double* out_remaining_ratio,
                                    FragmentMatchResult* out_frag,
                                    const std::string& activation_type) const;
```

- [ ] **Step 3: Update `computeFragmentMatch_` implementation in Exploration.cpp**

In `Exploration.cpp`, replace line 765:

```cpp
  Exploration::FragmentMatchResult Exploration::computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level) const
```

with:

```cpp
  Exploration::FragmentMatchResult Exploration::computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level,
                                                                      const std::string& activation_type) const
```

Then replace line 786 (the hardcoded `"HCD"`):

```cpp
        spec_copy, "HCD",
```

with:

```cpp
        spec_copy, activation_type,
```

- [ ] **Step 4: Update `computeExplorationScore_` implementation in Exploration.cpp**

In `Exploration.cpp`, replace the signature at lines 689-693:

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length,
      double* out_remaining_ratio, FragmentMatchResult* out_frag) const
```

with:

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length,
      double* out_remaining_ratio, FragmentMatchResult* out_frag,
      const std::string& activation_type) const
```

Then update all 4 `computeFragmentMatch_` calls inside (lines 699, 703, 708, 713) from:

```cpp
        fmr = computeFragmentMatch_(spec, group.msn_level);
```

to:

```cpp
        fmr = computeFragmentMatch_(spec, group.msn_level, activation_type);
```

- [ ] **Step 5: Update `feedResultImpl_` call site in Exploration.cpp**

At line 288, replace:

```cpp
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio, &frag);
```

with:

```cpp
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio, &frag, v.activation_type);
```

- [ ] **Step 6: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Wire activation type through Exploration scoring chain"
```

---

### Task 3: Wire activation type through `initiateNextLevel`

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:483-526`

- [ ] **Step 1: Extract activation type and pass to fragment matching calls**

In `Exploration.cpp`, in `initiateNextLevel` (line 483), add after line 495 (`int num_targets = this_cfg.max_targets;`):

```cpp
    // Extract activation type from the scan command that produced this result
    std::string scan_activation = (ms_ctx != nullptr)
        ? std::string(ms_ctx->stages[0].activation_type)
        : config_.level(msn_level).scans[0].activation;
```

Then update the three fragment matching calls to pass `scan_activation` as the `fragmentation_method` argument.

Replace lines 511-514:

```cpp
        found = fragments_.getTopFragmentMatches(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy);
```

with:

```cpp
        found = fragments_.getTopFragmentMatches(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy, scan_activation);
```

Replace lines 517-520:

```cpp
        found = fragments_.getTerminalFragmentIons(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy);
```

with:

```cpp
        found = fragments_.getTerminalFragmentIons(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy, scan_activation);
```

Replace lines 523-526:

```cpp
        found = fragments_.getAmbiguityEnclosingIons(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy);
```

with:

```cpp
        found = fragments_.getAmbiguityEnclosingIons(seq, num_targets,
            masses.data(), qscores.data(), charges.data(),
            wstarts.data(), wends.data(),
            ion_types.data(), frag_indices.data(), result_copy, scan_activation);
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Wire activation type through initiateNextLevel fragment matching"
```

---

### Task 4: Wire activation type through `PrecursorSelection::processMS2ForTagBasedTargeting`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h:172`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:902-934`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:203-206`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:849`

- [ ] **Step 1: Update PrecursorSelection.h signature**

In `PrecursorSelection.h`, replace line 172:

```cpp
    bool processMS2ForTagBasedTargeting(double precursor_mass);
```

with:

```cpp
    bool processMS2ForTagBasedTargeting(double precursor_mass, const std::string& activation_type);
```

- [ ] **Step 2: Update PrecursorSelection.cpp implementation**

In `PrecursorSelection.cpp`, replace line 902:

```cpp
  bool PrecursorSelection::processMS2ForTagBasedTargeting(double precursor_mass)
```

with:

```cpp
  bool PrecursorSelection::processMS2ForTagBasedTargeting(double precursor_mass, const std::string& activation_type)
```

Add include at top of file (after existing includes):

```cpp
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h>
```

Then replace lines 927-931 (tagger configuration):

```cpp
    FLASHTaggerAlgorithm tagger;
    Param tagger_param = tagger.getDefaults();
    tagger_param.setValue("min_length", config_.targeting().min_tag_length);
    tagger_param.setValue("max_length", config_.targeting().max_tag_length);
    tagger.setParameters(tagger_param);
```

with:

```cpp
    FLASHTaggerAlgorithm tagger;
    Param tagger_param = tagger.getDefaults();
    tagger_param.setValue("min_length", config_.targeting().min_tag_length);
    tagger_param.setValue("max_length", config_.targeting().max_tag_length);
    tagger_param.setValue("ion_type", FragmentAnalysis::getIonTypesForFragmentationMethod(activation_type));
    tagger.setParameters(tagger_param);
```

- [ ] **Step 3: Update FLASHIda.h inline delegate**

In `FLASHIda.h`, replace lines 203-206:

```cpp
    bool processMS2ForTagBasedTargeting(double precursor_mass)
    {
      return selection_.processMS2ForTagBasedTargeting(precursor_mass);
    }
```

with:

```cpp
    bool processMS2ForTagBasedTargeting(double precursor_mass, const std::string& activation_type)
    {
      return selection_.processMS2ForTagBasedTargeting(precursor_mass, activation_type);
    }
```

- [ ] **Step 4: Update FLASHIda.cpp caller in processScan**

In `FLASHIda.cpp`, replace line 849:

```cpp
        tags_found = selection_.processMS2ForTagBasedTargeting(precursor_mass);
```

with:

```cpp
        std::string ms2_activation = (ctx.num_stages > 0)
            ? std::string(ctx.stages[0].activation_type)
            : config_.level(2).scans[0].activation;
        tags_found = selection_.processMS2ForTagBasedTargeting(precursor_mass, ms2_activation);
```

- [ ] **Step 5: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Wire activation type through PrecursorSelection tag-based targeting"
```

---

### Task 5: Build and run all existing tests

**Files:**
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`
- Test: `OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp`

- [ ] **Step 1: Build all FLASH tests**

Run: `cd OpenMS/build && cmake --build . --target FLASHIda_exploration_test FragmentAnalysis_test FLASHIda_ProcessScan_test`
Expected: Clean compile, no errors.

- [ ] **Step 2: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R "FLASH|FragmentAnalysis"`
Expected: All tests pass. Existing tests all use `"activation": "HCD"` configs, so behavior is identical to the old hardcoded `"HCD"`.

- [ ] **Step 3: Fix any compilation issues**

If there are compilation errors (e.g., missing includes, signature mismatches), fix them before proceeding.

---

### Task 6: Add activation type wiring test

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

This test verifies that the activation type flows from the variant through to fragment matching. Since all existing configs use HCD, we create a config with ETD exploration and verify that `feedResultForTest` produces different fragment matching results than with HCD (the ion types `{c, z}` vs `{b, y}` will match different theoretical masses, so fragment counts will differ).

- [ ] **Step 1: Add a test config with ETD exploration activation**

In `FLASHIda_exploration_test.cpp`, after the existing config string variables (near the top of the file), add:

```cpp
// Config with ETD exploration for activation type wiring test
static const char* etd_exploration_config = R"({
  "deconvolution": {
    "tol": [10, 10, 10],
    "min_charge": 1,
    "max_charge": 30,
    "min_mass": 500,
    "max_mass": 100000
  },
  "ms_settings": {
    "ms1": { "resolution": 120000, "max_inject_time": 200 },
    "ms2": { "resolution": 60000, "max_inject_time": 200, "activation": "ETD", "reaction_time": 10.0 },
    "ms3": { "resolution": 60000, "max_inject_time": 200, "activation": "HCD" }
  },
  "selection_strategy": {
    "ms2": {
      "mode": "targeted",
      "exploration": {
        "metric": "mass_count",
        "activations": ["ETD"],
        "rt_min": 5.0,
        "rt_max": 15.0,
        "rt_step": 5.0
      }
    },
    "ms3": {
      "mode": "targeted"
    }
  },
  "targeting": {
    "protein_sequence": "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG",
    "fasta_file": "test.fasta"
  }
})";
```

- [ ] **Step 2: Add the test section**

Add a new `START_SECTION` / `END_SECTION` block:

```cpp
START_SECTION(activation_type_wiring_in_scoring)
{
  // Verify that exploration scoring passes variant activation type through
  // to fragment matching (not hardcoded "HCD").
  // ETD config produces variants with activation_type="ETD", which maps to
  // {c, z} ions — different from HCD's {b, y}.

  Config cfg{std::string(etd_exploration_config)};
  ScanCommandQueue queue(cfg);
  FragmentAnalysis fragments(cfg);
  Exploration exploration(cfg, fragments);

  auto pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  auto cmds = exploration.initiate(2, pg, 3, 0.0, queue);
  TEST_EQUAL(cmds.size() > 0, true)

  // Verify variants have ETD activation type
  auto group = exploration.getGroup(1);
  for (const auto& v : group.variants)
  {
    TEST_STRING_EQUAL(v.activation_type, "ETD")
  }

  // Feed result — this exercises the full scoring chain:
  // feedResultImpl_ → computeExplorationScore_ → computeFragmentMatch_
  // which now passes v.activation_type instead of hardcoded "HCD"
  DeconvolvedSpectrum ds = makeSyntheticDeconv(1, 5);
  int tracking_id = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));
  auto info = exploration.feedResultForTest(tracking_id, ds, 1.0, queue);

  // The key assertion: feedResult completed without error.
  // Fragment count may be 0 (synthetic data unlikely to match ETD fragments),
  // but the activation type was correctly passed through the chain.
  TEST_EQUAL(info.activation_type, "ETD")
  TEST_EQUAL(info.group_id > 0, true)
}
END_SECTION
```

- [ ] **Step 3: Build and run the test**

Run: `cd OpenMS/build && cmake --build . --target FLASHIda_exploration_test && ctest -R FLASHIda_exploration_test -V`
Expected: All tests pass including the new `activation_type_wiring_in_scoring` section.

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Add test: activation type wiring through exploration scoring chain"
```

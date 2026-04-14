# Conditional Fragment Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate `computeFragmentMatch_()` in exploration to only run when `ExplorationMetric::FragmentCount` is active, eliminating wasted work for MassCount/RemainingPrecursor and the redundant double-call for FragmentCount.

**Architecture:** Add a `FragmentMatchResult*` out-parameter to `computeExplorationScore_()`. The FragmentCount case stores its result there. `feedResultImpl_()` removes the unconditional `computeFragmentMatch_()` call and instead reads the out-parameter. Non-FragmentCount metrics get default (zero) fragment metadata.

**Tech Stack:** C++20, OpenMS ClassTest framework, CTest

---

## File Map

| File | Role |
|------|------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h` | Private declaration of `computeExplorationScore_` — add out-parameter |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` | Score function + `feedResultImpl_` — implementation changes |
| `OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp` | Add two test sections for conditional gating |

---

### Task 1: Add tests for conditional fragment analysis gating

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp`

- [ ] **Step 1: Add new includes**

At the top of `FragmentAnalysis_test.cpp`, after line 13 (`#include <OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h>`), add:

```cpp
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h>
#include <OpenMS/ANALYSIS/TOPDOWN/PeakGroup.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHHelperClasses.h>
```

- [ ] **Step 2: Add exploration config strings and PeakGroup helper**

In the anonymous namespace (after the `fragment_test_config` string, before the closing `}`), add two configs and a helper. These are identical to `fragment_test_config` except they add an `"exploration"` block to the ms2 `selection_strategy`:

```cpp
  // Config with fragment_count exploration metric + protein sequence
  const char* fragment_count_exploration_config = R"({
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
      "protein_sequence": "GDVEKGKKIFVQKCAQCHTVEKGGKHKTGPNLHGLFGRKTGQAPGFSYTDANKNKGITWGEETLMEYLENPKKYIPGTKMIFAGIKKKTEREDLIAYLKKATNE"
    },
    "conditional_ms2": false,
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_targets": 3 },
      "ms2": {
        "selection": "intensity",
        "max_targets": 3,
        "exploration": {
          "metric": "fragment_count",
          "ce_min": 20.0,
          "ce_max": 30.0,
          "ce_step": 10.0
        }
      },
      "ms3": { "selection": "none" }
    }
  })";

  // Config with mass_count exploration metric + protein sequence (same sequence present)
  const char* mass_count_exploration_config = R"({
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
      "protein_sequence": "GDVEKGKKIFVQKCAQCHTVEKGGKHKTGPNLHGLFGRKTGQAPGFSYTDANKNKGITWGEETLMEYLENPKKYIPGTKMIFAGIKKKTEREDLIAYLKKATNE"
    },
    "conditional_ms2": false,
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_targets": 3 },
      "ms2": {
        "selection": "intensity",
        "max_targets": 3,
        "exploration": {
          "metric": "mass_count",
          "ce_min": 20.0,
          "ce_max": 30.0,
          "ce_step": 10.0
        }
      },
      "ms3": { "selection": "none" }
    }
  })";

  PeakGroup makeSyntheticPeakGroup(double mz, double mass, int charge)
  {
    PeakGroup pg(charge, charge, true);
    pg.setMonoisotopicMass(mass);
    FLASHHelperClasses::LogMzPeak lp;
    lp.mz = mz;
    lp.abs_charge = charge;
    pg.push_back(lp);
    return pg;
  }
```

- [ ] **Step 3: Add test section `fragment_count_populated_for_fragment_count_metric`**

Before the `END_TEST` at line 261, add:

```cpp
START_SECTION(fragment_count_populated_for_fragment_count_metric)
{
  // Deconvolve real cytochrome c MS2 spectrum
  auto scans = loadTsvScans(ms2_cytc_path);
  ABORT_IF(scans.empty())

  Config cfg{std::string(fragment_count_exploration_config)};
  ScanCommandQueue queue(cfg);
  Deconvolution deconv(cfg);
  FragmentAnalysis fragments(cfg);
  Exploration exploration(cfg, deconv, fragments);

  // Deconvolve scan 149 to produce a spectrum with real fragment matches
  deconv.deconvolveMSn(scans[0].mzs.data(), scans[0].ints.data(),
                        static_cast<int>(scans[0].mzs.size()), scans[0].rt, 0.0, 0);

  // Initiate exploration group — CE variants 20 and 30
  auto pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  auto cmds = exploration.initiate(2, pg, 3, 0.0, queue);
  ABORT_IF(cmds.empty())

  // Feed deconvolved spectrum to first variant
  int tracking_id = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));
  auto info = exploration.feedResultForTest(tracking_id, deconv.storedMS2(), 1.0, queue);

  // FragmentCount metric: fragment analysis should have run
  TEST_EQUAL(info.fragment_count > 0, true)
  TEST_EQUAL(info.matched_protein.empty(), false)
  TEST_EQUAL(info.proteoform_sequence.empty(), false)
  TEST_STRING_EQUAL(info.proteoform_sequence, std::string(cytochrome_c_seq))
}
END_SECTION
```

- [ ] **Step 4: Add test section `fragment_analysis_skipped_for_mass_count_metric`**

Immediately after, add:

```cpp
START_SECTION(fragment_analysis_skipped_for_mass_count_metric)
{
  // Same real cytochrome c spectrum that produces fragment matches
  auto scans = loadTsvScans(ms2_cytc_path);
  ABORT_IF(scans.empty())

  Config cfg{std::string(mass_count_exploration_config)};
  ScanCommandQueue queue(cfg);
  Deconvolution deconv(cfg);
  FragmentAnalysis fragments(cfg);
  Exploration exploration(cfg, deconv, fragments);

  // Deconvolve — same data as above, would produce matches if fragment analysis ran
  deconv.deconvolveMSn(scans[0].mzs.data(), scans[0].ints.data(),
                        static_cast<int>(scans[0].mzs.size()), scans[0].rt, 0.0, 0);

  // Initiate exploration group with mass_count metric
  auto pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  auto cmds = exploration.initiate(2, pg, 3, 0.0, queue);
  ABORT_IF(cmds.empty())

  // Feed same deconvolved spectrum
  int tracking_id = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));
  auto info = exploration.feedResultForTest(tracking_id, deconv.storedMS2(), 1.0, queue);

  // MassCount metric: fragment analysis should NOT have run
  TEST_EQUAL(info.fragment_count, 0)
  TEST_EQUAL(info.matched_protein.empty(), true)
  TEST_EQUAL(info.proteoform_sequence.empty(), true)
}
END_SECTION
```

- [ ] **Step 5: Verify tests fail (fragment_analysis_skipped test should fail because gating is not yet implemented)**

Run from `OpenMS/build/`:
```bash
ctest -R FragmentAnalysis_test -V
```

Expected: `fragment_count_populated_for_fragment_count_metric` passes (FragmentCount metric already calls `computeFragmentMatch_` in the score function AND unconditionally at line 224). `fragment_analysis_skipped_for_mass_count_metric` **fails** — `info.fragment_count` is > 0 because line 224 still runs unconditionally.

- [ ] **Step 6: Commit failing test**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FragmentAnalysis_test.cpp
git commit -m "test: add failing tests for conditional fragment analysis gating"
```

---

### Task 2: Gate fragment analysis in `computeExplorationScore_` and `feedResultImpl_`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:194-197`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:220-225, 498-515`

- [ ] **Step 1: Update `computeExplorationScore_` declaration in header**

In `Exploration.h`, change line 194-197:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length,
                                    double* out_remaining_ratio = nullptr) const;
```

To:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length,
                                    double* out_remaining_ratio = nullptr,
                                    FragmentMatchResult* out_frag = nullptr) const;
```

- [ ] **Step 2: Update `computeExplorationScore_` implementation**

In `Exploration.cpp`, replace lines 498-515 (the entire function):

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length,
      double* out_remaining_ratio) const
  {
    switch (metric)
    {
      case ExplorationMetric::MassCount:
        return computeMassCount_(spec);
      case ExplorationMetric::RemainingPrecursor:
        return computeRemainingPrecursorScore_(group, mzs, ints, length, out_remaining_ratio);
      case ExplorationMetric::FragmentCount:
        return computeFragmentMatch_(spec).count;
      default:
        return computeMassCount_(spec);
    }
  }
```

With:

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length,
      double* out_remaining_ratio, FragmentMatchResult* out_frag) const
  {
    switch (metric)
    {
      case ExplorationMetric::MassCount:
        return computeMassCount_(spec);
      case ExplorationMetric::RemainingPrecursor:
        return computeRemainingPrecursorScore_(group, mzs, ints, length, out_remaining_ratio);
      case ExplorationMetric::FragmentCount:
      {
        auto fmr = computeFragmentMatch_(spec);
        if (out_frag) *out_frag = fmr;
        return fmr.count;
      }
      default:
        return computeMassCount_(spec);
    }
  }
```

- [ ] **Step 3: Update `feedResultImpl_` to remove unconditional call**

In `Exploration.cpp`, replace lines 220-226:

```cpp
    v.result = ms2_deconv;
    double remaining_ratio = -1.0;
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio);
    v.tic_coverage = computeTICCoverage_(ms2_deconv);
    auto frag = computeFragmentMatch_(ms2_deconv);
    v.fragment_count = static_cast<int>(frag.count);
    v.received = true;
```

With:

```cpp
    v.result = ms2_deconv;
    double remaining_ratio = -1.0;
    FragmentMatchResult frag{};
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio, &frag);
    v.tic_coverage = computeTICCoverage_(ms2_deconv);
    v.fragment_count = static_cast<int>(frag.count);
    v.received = true;
```

- [ ] **Step 4: Verify both tests pass**

Run from `OpenMS/build/`:
```bash
ctest -R FragmentAnalysis_test -V
```

Expected: all 6 tests pass (4 existing + 2 new).

- [ ] **Step 5: Commit implementation**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Gate fragment analysis to only run for FragmentCount exploration metric

Add FragmentMatchResult out-parameter to computeExplorationScore_().
Remove unconditional computeFragmentMatch_() call from feedResultImpl_().
MassCount and RemainingPrecursor metrics no longer run expensive
fragment analysis. FragmentCount eliminates the redundant double-call."
```

---

### Task 3: Push and verify CI

- [ ] **Step 1: Push to `flashida-v9-bridge`**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

- [ ] **Step 2: Update parent submodule pointer**

```bash
cd ..
git add OpenMS
git commit -m "Update OpenMS submodule: conditional fragment analysis gating"
git push origin phase-11
```

- [ ] **Step 3: Verify CI**

Wait for `flashida-ci` to run. Verify `cpp-unit-tests` passes — specifically that `FragmentAnalysis_test` passes with all 6 sections including the 2 new ones.

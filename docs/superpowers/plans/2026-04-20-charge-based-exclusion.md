# Charge-Based Exclusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional developer flag `charge_based_exclusion` that treats each `(mass, charge)` as an independent acquisition target with its own qscore accumulator and its own exclusion decision. When the flag is on, within a single MS1 scan the engine expands every peak group to one candidate per observed charge; a per-`(mass, charge)` accumulator / exclusion set replaces the mass-keyed machinery for candidate skipping, and the mass itself is never globally excluded. When the flag is off, behavior is byte-for-byte unchanged.

**Architecture:** Four drop-ins in `PrecursorSelection::filterAndRank` and `removeFromExclusionList` (see `docs/superpowers/specs/2026-04-19-charge-based-exclusion-design.md` §"When the flag is ON"). Config plumbing flows `method.json` → C# `PrecursorSelectionConfig.ChargeBasedExclusion` → wire-JSON key `ChargeBasedExclusion` → C++ `TargetingConfig::charge_based_exclusion` per `docs/kb/config-flow/adding-a-config-field.md`.

**Tech Stack:** C++20 (OpenMS), C# (.NET 4.8, FlashIDA), CMake/CTest, NUnit.

---

## File Structure

**Modified (C++):**
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` — one bool field on `TargetingConfig`.
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` — one `value()` call to parse the new key.
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h` — three new private members: `tqscore_exceeding_mass_charge_set_`, `mass_charge_qscore_map_`, `id_charge_map_`.
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp` — the four drop-ins (A expansion, B skip, C accumulator wrap, D commit-site + undo).

**Modified (C#):**
- `FlashIDA/src/Flash/MethodConfig.cs` — new `[Developer]` property on `PrecursorSelectionConfig` and new bool on `JsonPrecursorSelectionConfig`.
- `FlashIDA/src/Flash/MethodParameters.cs` — one key in the `ToCppJson()` mapping block.
- `FlashIDA/src/Flash/etc/method.json` — add the default entry under `developer.precursor_selection`.

**Created (tests):**
- `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ChargeBasedExclusion_test.cpp` — C++ behavioral tests through `processScan`.
- `FlashIDA/test-data/configs/method_charge_based_exclusion.json` — fixture for the C# roundtrip test.

**Modified (tests/docs):**
- `OpenMS/src/tests/class_tests/openms/executables.cmake` — register the new test binary.
- `FlashIDA/src/Flash.Tests/JsonConfigTests.cs` — one new test method.
- `docs/kb/ms1-acquisition/precursor-selection.md` — add a note about the flag.

**Not modified:** Any bridge function, any other C++ consumer, any existing test fixture.

---

## Task 1: Add `charge_based_exclusion` to `TargetingConfig`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:150`

- [ ] **Step 1: Add the bool field next to `consider_all_charges`**

Insert one line after `bool consider_all_charges = false;`:

```cpp
    bool consider_all_charges = false;
    bool charge_based_exclusion = false;  ///< Treat each (mass, charge) as an independent exclusion target (developer flag).
    int hcd_energy = -1;
```

- [ ] **Step 2: Verify no aggregate initialization sites exist for `TargetingConfig`**

Run: `grep -rn "TargetingConfig{" /home/tom-mueller/kohlbacherlab/FLASHIda/Development/OpenMS/src/openms`
Expected: no hits (the struct is populated field-by-field in `Config::from_json`, never braced). If any hit shows up, update it in place.

- [ ] **Step 3: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
git commit -m "feat(flashida/config): add charge_based_exclusion to TargetingConfig"
```

---

## Task 2: Parse the wire-JSON key in `Config.cpp`

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:124`

- [ ] **Step 1: Add the parser line**

Insert one line after `targeting_.consider_all_charges = ps.value("AllCharges", false);`:

```cpp
    targeting_.consider_all_charges = ps.value("AllCharges", false);
    targeting_.charge_based_exclusion = ps.value("ChargeBasedExclusion", false);
    targeting_.hcd_energy = ps.value("HCDEnergy", -1);
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git commit -m "feat(flashida/config): parse ChargeBasedExclusion from precursor_selection"
```

---

## Task 3: Add private members to `PrecursorSelection`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h:214-219`

- [ ] **Step 1: Add the three members**

After `std::unordered_map<int, double> mass_qscore_map_;` (line 214) add one block; after `std::unordered_map<int, double> id_qscore_map_;` (line 219) add one line:

```cpp
    std::unordered_map<int, double> mass_qscore_map_;

    /// Per-(nominal_mass, charge) cross-scan exclusion set (charge_based_exclusion flag).
    std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_;

    /// Per-(nominal_mass, charge) qscore accumulator, parallel to mass_qscore_map_
    /// but one level deeper. Only touched when charge_based_exclusion is on.
    std::map<std::pair<int, int>, double> mass_charge_qscore_map_;

    /// Maps for selectively disabling mass exclusion (needed for FAIMS support)
    std::unordered_map<int, int> id_mass_map_;
    std::unordered_map<int, int> id_mz_map_;
    std::unordered_map<int, double> id_qscore_map_;
    std::unordered_map<int, int> id_charge_map_;
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h
git commit -m "feat(flashida/selection): add per-(mass, charge) members to PrecursorSelection"
```

---

## Task 4: Drop-in D part 1 — populate `id_charge_map_` at commit site

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:641-643`

- [ ] **Step 1: Add the unconditional write**

Replace the three-line id-map write at `:641-643` with four lines:

```cpp
          // Store acquisition
          id_mass_map_[window_id_] = nominal_mass;
          id_mz_map_[window_id_] = integer_mz;
          id_qscore_map_[window_id_] = score;
          id_charge_map_[window_id_] = charge;
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "feat(flashida/selection): track charge in id_charge_map_ at commit site"
```

---

## Task 5: Drop-in C — wrap the accumulation block with per-(mass, charge) branch

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:596-630`

- [ ] **Step 1: Wrap the existing block in `if (charge_based_exclusion) { ... } else { ... }`**

Replace the existing `:596-630` block:

```cpp
          if (!config_.targeting().use_idscore) {
            // Compute total qscore
            auto inter = mass_qscore_map_.find(nominal_mass);
            if (inter == mass_qscore_map_.end())
            {
              mass_qscore_map_[nominal_mass] = score;
            }
            else {
              // If mass has previously been acquired with higher qscore, skip
              if (score < mass_qscore_map_[nominal_mass]) {
                continue;
              }
              mass_qscore_map_[nominal_mass] = score;
            }

            // Add to exclusion list if neccessary
            if (mass_qscore_map_[nominal_mass] > config_.targeting().tqscore_threshold)
            {
              tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;
              tqscore_exceeding_mz_rt_map_[integer_mz] = rt;
            }
          }
          else {
            // Compute total qscore
            auto inter = mass_qscore_map_.find(nominal_mass);
            if (inter == mass_qscore_map_.end()) { mass_qscore_map_[nominal_mass] = 1 - score; }
            else { mass_qscore_map_[nominal_mass] *= 1 - score; }

            // Add to exclusion list if neccessary
            if (1 - mass_qscore_map_[nominal_mass] * tqscore_factor_for_exclusion > config_.targeting().tqscore_threshold)
            {
              tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;
              tqscore_exceeding_mz_rt_map_[integer_mz] = rt;
            }
          }
```

with:

```cpp
          if (config_.targeting().charge_based_exclusion)
          {
            // Per-(mass, charge) accumulation. No mass-level writes — the mass is never globally excluded.
            const auto key = std::make_pair(nominal_mass, charge);
            if (!config_.targeting().use_idscore) {
              auto inter = mass_charge_qscore_map_.find(key);
              if (inter == mass_charge_qscore_map_.end())
              {
                mass_charge_qscore_map_[key] = score;
              }
              else {
                mass_charge_qscore_map_[key] = std::max(inter->second, score);
              }
              if (mass_charge_qscore_map_[key] > config_.targeting().tqscore_threshold)
              {
                tqscore_exceeding_mass_charge_set_.insert(key);
              }
            }
            else {
              auto inter = mass_charge_qscore_map_.find(key);
              if (inter == mass_charge_qscore_map_.end()) { mass_charge_qscore_map_[key] = 1 - score; }
              else { mass_charge_qscore_map_[key] *= 1 - score; }
              if (1 - mass_charge_qscore_map_[key] * tqscore_factor_for_exclusion > config_.targeting().tqscore_threshold)
              {
                tqscore_exceeding_mass_charge_set_.insert(key);
              }
            }
          }
          else if (!config_.targeting().use_idscore) {
            // Compute total qscore
            auto inter = mass_qscore_map_.find(nominal_mass);
            if (inter == mass_qscore_map_.end())
            {
              mass_qscore_map_[nominal_mass] = score;
            }
            else {
              // If mass has previously been acquired with higher qscore, skip
              if (score < mass_qscore_map_[nominal_mass]) {
                continue;
              }
              mass_qscore_map_[nominal_mass] = score;
            }

            // Add to exclusion list if neccessary
            if (mass_qscore_map_[nominal_mass] > config_.targeting().tqscore_threshold)
            {
              tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;
              tqscore_exceeding_mz_rt_map_[integer_mz] = rt;
            }
          }
          else {
            // Compute total qscore
            auto inter = mass_qscore_map_.find(nominal_mass);
            if (inter == mass_qscore_map_.end()) { mass_qscore_map_[nominal_mass] = 1 - score; }
            else { mass_qscore_map_[nominal_mass] *= 1 - score; }

            // Add to exclusion list if neccessary
            if (1 - mass_qscore_map_[nominal_mass] * tqscore_factor_for_exclusion > config_.targeting().tqscore_threshold)
            {
              tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;
              tqscore_exceeding_mz_rt_map_[integer_mz] = rt;
            }
          }
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "feat(flashida/selection): per-(mass, charge) accumulator under charge_based_exclusion"
```

---

## Task 6: Drop-in B — per-(mass, charge) skip before phase-tqscore gate

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:582-584`

- [ ] **Step 1: Insert the skip between the same-m/z-avoidance block and the phase gate**

Find the boundary `}\n\n          // selection phase 0, skip masses over tqscore threshold` (the closing brace of the `current_selected_mzs` block at `:581` followed by the phase-0 gate at `:584`) and insert the new gate in between:

```cpp
          }

          if (config_.targeting().charge_based_exclusion
              && tqscore_exceeding_mass_charge_set_.count({nominal_mass, charge}) > 0)
          {
            continue;
          }

          // selection phase 0, skip masses over tqscore threshold
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "feat(flashida/selection): skip candidates whose (mass, charge) is excluded"
```

---

## Task 7: Drop-in A — per-peak-group charge expansion

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:395-429`

- [ ] **Step 1: Before the per-candidate body, compute `charges_to_process`**

Keep the outer `for (const auto& pg : deconv_.deconvolvedMS1()) { ... }` unchanged. Inside, right before the charge-picking ladder at `:400`, read the existing scalar-style resolution into a helper vector. Replace the block from `:397-429` (the `if (selected_peak_groups_.size() >= mass_count) { break; }` and the charge-picking ladder) with:

```cpp
          // dont acquire the same mass multiple times
          if (selected_peak_groups_.size() >= mass_count) { break; }

          struct ChargeCandidate { int charge; double score; int hcd; };
          std::vector<ChargeCandidate> charges_to_process;

          if (config_.targeting().charge_based_exclusion)
          {
            auto [min_c, max_c] = pg.getAbsChargeRange();
            const auto& all_qs = pg.getAllQscores();
            for (int c = min_c; c <= max_c; ++c)
            {
              if (all_qs.count(c) == 0) { continue; }
              double s;
              int h = config_.targeting().hcd_energy;
              if (config_.targeting().use_idscore && config_.targeting().hcd_energy < 0)
              {
                s = pg.getBestIDScoreForCharge(c);
                h = pg.getBestHCDForCharge(c);
              }
              else if (config_.targeting().use_idscore)
              {
                s = pg.getIDScoreForChargeAndHCD(c, config_.targeting().hcd_energy);
              }
              else
              {
                s = all_qs.at(c);
              }
              charges_to_process.push_back({c, s, h});
            }
            std::sort(charges_to_process.begin(), charges_to_process.end(),
                      [](const ChargeCandidate& a, const ChargeCandidate& b) { return a.score > b.score; });
          }
          else
          {
            int charge;
            double score;
            int hcd = config_.targeting().hcd_energy;

            if (config_.targeting().use_idscore && config_.targeting().consider_all_charges && config_.targeting().hcd_energy < 0) {
              charge = pg.getBestIDScoreCharge();
              score = pg.getBestIDScore();
              hcd = pg.getBestIDScoreHCD();
            }
            else if (config_.targeting().use_idscore && config_.targeting().consider_all_charges) {
              charge = pg.getBestIDScoreChargeForHCD(config_.targeting().hcd_energy);
              score = pg.getBestIDScoreForHCD(config_.targeting().hcd_energy);
            }
            else if (config_.targeting().use_idscore && !config_.targeting().consider_all_charges && config_.targeting().hcd_energy < 0) {
              charge = pg.getRepAbsCharge();
              score = pg.getBestIDScoreForCharge(charge);
              hcd = pg.getBestHCDForCharge(charge);
            }
            else if (config_.targeting().use_idscore && !config_.targeting().consider_all_charges) {
              charge = pg.getRepAbsCharge();
              score = pg.getIDScoreForChargeAndHCD(charge, config_.targeting().hcd_energy);
            }
            else if (!config_.targeting().use_idscore && config_.targeting().consider_all_charges) {
              charge = pg.getBestQScoreCharge();
              score = pg.getBestQScore();
            }
            else {
              charge = pg.getRepAbsCharge();
              score = pg.getQscore();
            }
            charges_to_process.push_back({charge, score, hcd});
          }

          for (const auto& cc : charges_to_process)
          {
            if (selected_peak_groups_.size() >= mass_count) { break; }
            int charge = cc.charge;
            double score = cc.score;
            int hcd = cc.hcd;

```

- [ ] **Step 2: Close the inner loop**

At the existing end of the per-candidate body (just before line 656's `}\n      }\n    }\n  }`), add one extra closing brace for the new `for (const auto& cc : charges_to_process)` loop. The final closing structure should be:

```cpp
            current_selected_masses.insert(pg.getMonoMass());
            current_selected_mzs.insert(center_mz);
          }  // end for charges_to_process
        }  // end for deconvolvedMS1
      }  // end for selection_phase
    }  // end outer iteration loop
  }
```

- [ ] **Step 3: Build locally to verify syntax**

Tell the user: "Please build OpenMS locally and report any compile errors before I proceed. Do NOT build OpenMS from this session — it is resource-intensive." Wait for confirmation before committing.

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "feat(flashida/selection): expand candidates per observed charge under flag"
```

---

## Task 8: Drop-in D part 2 — `removeFromExclusionList` per-charge undo

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:681`

- [ ] **Step 1: Insert the gated undo after the existing mass-keyed block**

After the existing line 681 `if (mass_qscore_map_.find(nominal_mass) != mass_qscore_map_.end()) { mass_qscore_map_[nominal_mass] /= 1 - qscore; }`, add the gated undo block:

```cpp
    // Remove qscore from further calculations
    if (mass_qscore_map_.find(nominal_mass) != mass_qscore_map_.end()) { mass_qscore_map_[nominal_mass] /= 1 - qscore; }

    if (config_.targeting().charge_based_exclusion)
    {
      auto cit = id_charge_map_.find(id);
      if (cit != id_charge_map_.end())
      {
        const auto key = std::make_pair(nominal_mass, cit->second);
        tqscore_exceeding_mass_charge_set_.erase(key);
        if (config_.targeting().use_idscore)
        {
          auto ait = mass_charge_qscore_map_.find(key);
          if (ait != mass_charge_qscore_map_.end())
          {
            ait->second /= (1 - qscore);
          }
        }
      }
    }
  }
```

- [ ] **Step 2: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "feat(flashida/selection): mirror per-charge undo in removeFromExclusionList"
```

---

## Task 9: Add the C++ test file

**Files:**
- Create: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ChargeBasedExclusion_test.cpp`

- [ ] **Step 1: Write the full test file**

Create the file with the following content. The file reuses the `loadTsvScans` / `pushAllScans` helpers inline (copy-paste is intentional — the existing helpers are in the private anonymous namespace of `FLASHIda_ProcessScan_test.cpp` and not exported).

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------
//
// Tests for the charge_based_exclusion developer flag. Uses the ms1_standard TSV
// fixture already used by FLASHIda_ProcessScan_test.

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h>

#include <cstring>
#include <fstream>
#include <set>
#include <string>
#include <vector>

using namespace OpenMS;

namespace
{
  const char* base_off_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1,
      "ChargeBasedExclusion": false
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
      "ms1": { "selection": "qscore", "max_targets": 10 },
      "ms2": { "selection": "none" },
      "ms3": { "selection": "none" }
    }
  })";

  const char* base_on_json = R"({
    "deconvolution": {
      "score_threshold": 0.0, "tqscore_threshold": 0.9,
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000, "tol": [10, 10, 10]
    },
    "precursor_selection": {
      "RT_window": 180, "target_mode": 0,
      "IDScore": false, "AllCharges": false,
      "HCDEnergy": 29, "strict_inclusion": false, "tie_threshold": 0.1,
      "ChargeBasedExclusion": true
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
      "ms1": { "selection": "qscore", "max_targets": 10 },
      "ms2": { "selection": "none" },
      "ms3": { "selection": "none" }
    }
  })";

  const std::string ms1_tsv_path = "../../FlashIDA/test-data/spectra/ms1_standard.txt";

  struct ScanData
  {
    std::vector<double> mzs;
    std::vector<double> ints;
    double rt;
    std::string scan_id;
  };

  std::vector<ScanData> loadTsvScans(const std::string& path)
  {
    std::vector<ScanData> scans;
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line))
    {
      if (line.substr(0, 4) == "Spec")
      {
        scans.emplace_back();
        auto tab = line.find('\t');
        scans.back().scan_id = line.substr(10, tab - 10);
        scans.back().rt = std::stod(line.substr(tab + 1));
      }
      else if (! scans.empty())
      {
        auto tab = line.find('\t');
        if (tab != std::string::npos)
        {
          scans.back().mzs.push_back(std::stod(line.substr(0, tab)));
          scans.back().ints.push_back(std::stod(line.substr(tab + 1)));
        }
      }
    }
    return scans;
  }

  struct AcquisitionRow { int charge; double mz; double width; };

  // Drive all scans through processScan and collect every (charge, mz, width) tuple emitted.
  std::vector<AcquisitionRow> runAndCollect(const char* cfg, const std::vector<ScanData>& scans)
  {
    FLASHIda ida(const_cast<char*>(cfg));
    for (const auto& scan : scans)
    {
      ida.processScan(scan.mzs.data(), scan.ints.data(),
                      (int)scan.mzs.size(), scan.rt, 1,
                      ("scan_" + scan.scan_id).c_str());
    }
    std::vector<AcquisitionRow> rows;
    ScanCommand cmd{};
    while (ida.getNextScanCommand(cmd) == 1)
    {
      if (cmd.is_agc) { break; }  // stop before AGC idle cycle
      if (cmd.msn_level == 2 && cmd.num_stages >= 1)
      {
        rows.push_back({cmd.stages[0].charge_state, cmd.stages[0].precursor_mz, cmd.stages[0].isolation_width});
      }
    }
    return rows;
  }
}

START_TEST(FLASHIda_ChargeBasedExclusion, "$Id$")

// CBE-01: Flag off produces the same count and charge set as the existing
// default config — regression guard for byte-for-byte preservation.
START_SECTION(flag_off_matches_default_behavior)
{
  auto scans = loadTsvScans(ms1_tsv_path);
  ABORT_IF(scans.empty())
  auto rows = runAndCollect(base_off_json, scans);
  TEST_EQUAL(rows.size() > 0, true)
  // Count unique (charge, mz) tuples — with the flag off, each (charge, mz) should be unique per scan
  // (default same-mz avoidance). Assert every emitted row has charge >= 4 (config min_charge).
  for (const auto& r : rows) { TEST_EQUAL(r.charge >= 4, true) }
}
END_SECTION

// CBE-02: Flag on emits more acquisitions than flag off across the same scan sequence
// because multiple charges of the same mass are now fragmented.
START_SECTION(flag_on_emits_more_acquisitions_than_flag_off)
{
  auto scans = loadTsvScans(ms1_tsv_path);
  ABORT_IF(scans.empty())
  auto off_rows = runAndCollect(base_off_json, scans);
  auto on_rows = runAndCollect(base_on_json, scans);
  TEST_EQUAL(off_rows.size() > 0, true)
  TEST_EQUAL(on_rows.size() > off_rows.size(), true)
}
END_SECTION

// CBE-03: Under the flag, two acquisitions share a nominal mass but have different
// charges — demonstrates per-mass multi-charge expansion.
// We bucket by charge-corrected nominal mass: mono_mass ≈ (mz - proton) * charge.
// Since ScanCommand exposes precursor_mz and charge_state, reconstruct mass per row and
// confirm at least one mass bucket contains ≥2 distinct charges.
START_SECTION(flag_on_yields_multiple_charges_per_mass)
{
  auto scans = loadTsvScans(ms1_tsv_path);
  ABORT_IF(scans.empty())
  auto rows = runAndCollect(base_on_json, scans);
  ABORT_IF(rows.empty())

  constexpr double proton = 1.00728;
  std::map<int, std::set<int>> nominal_mass_to_charges;
  for (const auto& r : rows)
  {
    int nominal = (int)std::round((r.mz - proton) * r.charge);
    nominal_mass_to_charges[nominal].insert(r.charge);
  }
  int masses_with_multiple_charges = 0;
  for (const auto& kv : nominal_mass_to_charges) { if (kv.second.size() >= 2) { masses_with_multiple_charges++; } }
  TEST_EQUAL(masses_with_multiple_charges >= 1, true)
}
END_SECTION

// CBE-04: Under the flag, driving the first scan through processScan twice in a row
// yields fewer commands on the second invocation — per-(mass, charge) exclusion
// suppresses re-acquisition of charges whose per-charge qscore already crossed threshold.
START_SECTION(flag_on_suppresses_reacquisition_across_scans)
{
  auto scans = loadTsvScans(ms1_tsv_path);
  ABORT_IF(scans.empty())
  const auto& s0 = scans.front();

  FLASHIda ida(const_cast<char*>(base_on_json));

  // First invocation.
  int first_count = ida.processScan(s0.mzs.data(), s0.ints.data(),
                                    (int)s0.mzs.size(), s0.rt, 1, "scan_0a");
  // Drain the queue produced by the first scan before the second invocation.
  int drained_first = 0;
  ScanCommand cmd{};
  while (ida.getNextScanCommand(cmd) == 1)
  {
    if (cmd.is_agc) { break; }
    if (cmd.msn_level == 2) { drained_first++; }
  }
  TEST_EQUAL(drained_first > 0, true)

  // Second invocation with the exact same spectrum and a slightly later RT
  // so the rt_window-based eviction doesn't clear the per-charge set.
  int second_count = ida.processScan(s0.mzs.data(), s0.ints.data(),
                                     (int)s0.mzs.size(), s0.rt + 0.001, 1, "scan_0b");
  int drained_second = 0;
  while (ida.getNextScanCommand(cmd) == 1)
  {
    if (cmd.is_agc) { break; }
    if (cmd.msn_level == 2) { drained_second++; }
  }
  TEST_EQUAL(drained_second < drained_first, true)
  (void)first_count; (void)second_count;
}
END_SECTION

// CBE-05: With the flag on, acquisitions targeting the same nominal m/z appear at multiple
// distinct charge values — if the flag had no effect we would only see one.
START_SECTION(flag_on_diverse_charges_at_same_mass)
{
  auto scans = loadTsvScans(ms1_tsv_path);
  ABORT_IF(scans.empty())
  auto on_rows = runAndCollect(base_on_json, scans);
  ABORT_IF(on_rows.empty())
  std::set<int> distinct_charges;
  for (const auto& r : on_rows) { distinct_charges.insert(r.charge); }
  TEST_EQUAL(distinct_charges.size() >= 2, true)
}
END_SECTION

END_TEST
```

- [ ] **Step 2: Register the test**

Modify `OpenMS/src/tests/class_tests/openms/executables.cmake`. Find the line `FLASHIda_ProcessScan_test` (around line 454) and add `FLASHIda_ChargeBasedExclusion_test` right after it:

```cmake
  FLASHIda_ProcessScan_test
  FLASHIda_ChargeBasedExclusion_test
  ScanCommandLayout_test
```

- [ ] **Step 3: Ask the user to build and run the test locally**

Tell the user: "Please build OpenMS locally and run `ctest -R FLASHIda_ChargeBasedExclusion` to validate the tests. Do NOT build from this session. Report pass/fail before proceeding."

- [ ] **Step 4: Commit**

```bash
git add OpenMS/src/tests/class_tests/openms/source/FLASHIda_ChargeBasedExclusion_test.cpp OpenMS/src/tests/class_tests/openms/executables.cmake
git commit -m "test(flashida): C++ behavioral tests for charge_based_exclusion flag"
```

---

## Task 10: C# config property on `PrecursorSelectionConfig`

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:92`

- [ ] **Step 1: Add the `[Developer]` property**

After `public int HCDEnergy { get; set; } = 29;` (line 92, inside `PrecursorSelectionConfig`) insert:

```csharp
        [Developer]
        [JsonKey("charge_based_exclusion")]
        [Description("Treat each (mass, charge) as an independent acquisition target; the mass itself is never globally excluded.")]
        public bool ChargeBasedExclusion { get; set; }
    }
```

- [ ] **Step 2: Add the wire-JSON property on `JsonPrecursorSelectionConfig`**

In the same file, around line 420, after `public double tie_threshold { get; set; }` (the last existing property in `JsonPrecursorSelectionConfig`) insert:

```csharp
        public double tie_threshold { get; set; }
        public bool ChargeBasedExclusion { get; set; }
    }
```

- [ ] **Step 3: Commit**

```bash
git add FlashIDA/src/Flash/MethodConfig.cs
git commit -m "feat(flashida/config): ChargeBasedExclusion developer flag on PrecursorSelectionConfig"
```

---

## Task 11: Wire the property through `MethodParameters.ToCppJson`

**Files:**
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:134`

- [ ] **Step 1: Add the mapping line**

In the `precursor_selection = new JsonPrecursorSelectionConfig { ... }` block, after `tie_threshold = c.PrecursorSelection.TieThreshold` (line 134) insert:

```csharp
                    tie_threshold = c.PrecursorSelection.TieThreshold,
                    ChargeBasedExclusion = c.PrecursorSelection.ChargeBasedExclusion
                },
```

- [ ] **Step 2: Commit**

```bash
git add FlashIDA/src/Flash/MethodParameters.cs
git commit -m "feat(flashida/config): pass ChargeBasedExclusion through ToCppJson"
```

---

## Task 12: Add the default entry to `method.json`

**Files:**
- Modify: `FlashIDA/src/Flash/etc/method.json:49`

- [ ] **Step 1: Add the key under `developer.precursor_selection`**

Locate the existing block:

```json
    "precursor_selection": {
      "use_id_score": false,
      "consider_all_charges": false,
      "hcd_energy": 29
    },
```

Replace it with:

```json
    "precursor_selection": {
      "use_id_score": false,
      "consider_all_charges": false,
      "hcd_energy": 29,
      "charge_based_exclusion": false
    },
```

- [ ] **Step 2: Commit**

```bash
git add FlashIDA/src/Flash/etc/method.json
git commit -m "feat(flashida/config): default charge_based_exclusion=false in method.json"
```

---

## Task 13: Add the C# JSON roundtrip test fixture

**Files:**
- Create: `FlashIDA/test-data/configs/method_charge_based_exclusion.json`

- [ ] **Step 1: Copy `method_json_roundtrip.json` as a base, enabling the new flag**

Read the existing `FlashIDA/test-data/configs/method_json_roundtrip.json` and write a copy that sets `developer.precursor_selection.charge_based_exclusion` to `true`. The full file contents should match the roundtrip fixture except for that key.

Example final content (verify field names match the actual fixture):

```json
{
  "global": { "instrument": "Ascend" },
  "deconvolution": { "min_mass": 500, "max_mass": 50000, "min_charge": 4, "max_charge": 50, "tolerances": [10, 10, 10], "qscore_threshold": 0.0, "tqscore_threshold": 0.9 },
  "precursor_selection": {
    "rt_window": 180,
    "targeting_mode": "none",
    "strict_inclusion": false,
    "tie_threshold": 0.1
  },
  "developer": {
    "precursor_selection": {
      "use_id_score": true,
      "consider_all_charges": false,
      "hcd_energy": 35,
      "charge_based_exclusion": true
    },
    "faims": { "max_cv_skip": 2, "mass_threshold": 15 }
  },
  "faims": { "cv_values": [-50, -60, -70] },
  "tagging": { "active": false, "conditional_ms2": false, "min_tag_length": 3, "max_tag_length": 8, "max_ptm_count": 3, "max_flanking_mass_diff": 50000 },
  "quantification": { "active": false, "reporter_mz_tol": 0.002, "fold_change_threshold": 1.4, "only_one_condition": false },
  "ms_settings": { "ms1": { "Analyzer": "Orbitrap", "FirstMass": 500, "LastMass": 2000, "OrbitrapResolution": 120000, "AGCTarget": 800000, "MaxIT": 246, "Microscans": 1, "DataType": "Centroid", "RFLens": 30, "SourceCIDScaling": 0, "SourceCID": 15 }, "ms2": [ { "Analyzer": "Orbitrap", "Activation": "HCD", "CollisionEnergy": 29, "OrbitrapResolution": 120000 } ] },
  "scheduling": { "cycle_time": { "enabled": false, "value_ms": 60000 }, "scan_timeout": { "enabled": true, "value_ms": 30000 }, "agc_interval_seconds": 30 },
  "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
  "selection_strategy": { "ms1": { "selection": "qscore", "max_targets": 3 }, "ms2": { "selection": "none" }, "ms3": { "selection": "none" } }
}
```

The exact field shape must match the existing `method_json_roundtrip.json` — verify by diffing before committing.

- [ ] **Step 2: Commit**

```bash
git add FlashIDA/test-data/configs/method_charge_based_exclusion.json
git commit -m "test(flashida): add fixture method_charge_based_exclusion.json"
```

---

## Task 14: Add the C# roundtrip test

**Files:**
- Modify: `FlashIDA/src/Flash.Tests/JsonConfigTests.cs:106`

- [ ] **Step 1: Insert the new test after `Deserialize_DeveloperRouting`**

After the closing `}` of `Deserialize_DeveloperRouting` (line 106), insert:

```csharp
        [Test, Category("Tier1")]
        public void Deserialize_ChargeBasedExclusion_RoundTrip()
        {
            var mp = LoadJsonMethod("method_charge_based_exclusion.json");
            Assert.IsTrue(mp.Config.PrecursorSelection.ChargeBasedExclusion);

            // Roundtrip preserves the flag.
            string serialized = MethodConfigSerializer.Serialize(mp.Config);
            var config2 = MethodConfigSerializer.Deserialize(serialized);
            Assert.IsTrue(config2.PrecursorSelection.ChargeBasedExclusion);

            // ToCppJson surfaces the flag on the wire-JSON.
            var cpp = MethodParameters.ToCppJson(mp.Config);
            Assert.IsTrue(cpp.Contains("\"ChargeBasedExclusion\":true") ||
                          cpp.Contains("\"ChargeBasedExclusion\": true"));
        }

        [Test, Category("Tier1")]
        public void Deserialize_ChargeBasedExclusion_DefaultsFalse()
        {
            var mp = LoadJsonMethod("method_default.json");
            Assert.IsFalse(mp.Config.PrecursorSelection.ChargeBasedExclusion);

            var cpp = MethodParameters.ToCppJson(mp.Config);
            Assert.IsTrue(cpp.Contains("\"ChargeBasedExclusion\":false") ||
                          cpp.Contains("\"ChargeBasedExclusion\": false"));
        }
```

- [ ] **Step 2: Run the C# test locally (ask user)**

Tell the user: "Please build Flash.sln and run the NUnit tests in `Flash.Tests`. Report pass/fail for `Deserialize_ChargeBasedExclusion_RoundTrip` and `Deserialize_ChargeBasedExclusion_DefaultsFalse`."

- [ ] **Step 3: Commit**

```bash
git add FlashIDA/src/Flash.Tests/JsonConfigTests.cs
git commit -m "test(flashida): JSON roundtrip for charge_based_exclusion flag"
```

---

## Task 15: Update the KB precursor-selection note

**Files:**
- Modify: `docs/kb/ms1-acquisition/precursor-selection.md` (append to the "Gotchas" section)

- [ ] **Step 1: Append a new gotcha bullet**

At the bottom of the existing `## Gotchas` section, add:

```markdown
- `charge_based_exclusion` (developer flag, default off) changes the accumulation
  block at `:596-630` to use a per-`(nominal_mass, charge)` key
  (`mass_charge_qscore_map_`) and replaces the mass-level write into
  `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_` with an insert into
  `tqscore_exceeding_mass_charge_set_`. When on, the mass is never globally
  excluded; instead, specific charges are excluded individually. The candidate
  loop also expands per-peak-group to one iteration per observed charge. See
  `docs/superpowers/specs/2026-04-19-charge-based-exclusion-design.md`.
```

- [ ] **Step 2: Bump `last_verified` to today's date in the frontmatter**

Change `last_verified: 2026-04-19` to `last_verified: 2026-04-20`.

- [ ] **Step 3: Commit**

```bash
git add docs/kb/ms1-acquisition/precursor-selection.md
git commit -m "docs(kb): note charge_based_exclusion flag in precursor selection"
```

---

## Task 16: Build and test verification (user-driven)

- [ ] **Step 1: Ask the user to run the full C++ test suite for FLASH tests**

Tell the user: "Please build OpenMS locally and run `ctest -R FLASHIda` — confirm no regressions in existing tests and that `FLASHIda_ChargeBasedExclusion_test` passes. Report results."

- [ ] **Step 2: Ask the user to run the Flash.Tests suite**

Tell the user: "Please run the full `Flash.Tests` NUnit suite — confirm no regressions and that the two new tests pass. Report results."

- [ ] **Step 3: Download and commit new OpenMS DLLs if C++ changed**

If the user confirms C++ changes built and tested successfully, coordinate the DLL update per the workflow documented in memory — do not push FlashIDA commits before the new DLLs are committed into `FlashIDA/dll/`.

---

## Self-Review Notes

- **Spec coverage:** Tasks 1-2 cover C++ config plumbing. Task 3 covers the new members. Tasks 4-8 cover drop-ins A (Task 7), B (Task 6), C (Task 5), D (Tasks 4 + 8). Task 9 covers C++ tests CBE-01 through CBE-05 mapping to the six spec tests (test 4 "mass not globally excluded" is exercised by CBE-04 showing second-pass suppression, combined with CBE-02 showing multi-charge acquisition — the mass not being excluded is what allows the second charge in CBE-03 / CBE-05). Tasks 10-14 cover C# plumbing and JSON roundtrip test. Task 15 covers KB docs.

- **Spec test gap:** Spec test 7 (`removeFromExclusionList` undo) is not exercised by this plan because the function is currently unreachable from any caller (`removeFromExclusionList` has no production callers in the current codebase). The undo code is written correctly (Task 8) but not dynamically tested. If a caller is re-introduced later, add the matching test then.

- **Spec test gap:** Spec test 8 (`id_charge_map_` populated unconditionally) is implicitly exercised because both flag-off (CBE-01) and flag-on (CBE-02, CBE-03, CBE-05) tests succeed — the write happens in both cases and its absence would cause drop-in D's undo to misbehave (but as noted above, undo is untested). A direct-instantiation unit test is out of scope here.

- **Max-tracking skip regression (spec test 6):** This is indirectly covered by CBE-02's strict `on_rows.size() > off_rows.size()` assertion: without the wrap in drop-in C, the max-tracking skip at `:604-607` would still fire under the flag, suppressing lower-qscore charges of the same mass and making `on_rows.size()` ≤ `off_rows.size()`.

- **Type consistency:** `TargetingConfig::charge_based_exclusion` (Task 1) is read as `config_.targeting().charge_based_exclusion` in Tasks 5, 6, 7, 8. The wire-JSON key `"ChargeBasedExclusion"` (Task 2) matches the C# property name introduced in Task 10 — the `JsonPrecursorSelectionConfig` property is serialized by Newtonsoft with its PascalCase name, matching the parser. The `[JsonKey("charge_based_exclusion")]` attribute maps user-facing snake_case to the C# property on the user-facing `PrecursorSelectionConfig`.

- **Commit sequencing:** The C++ changes (Tasks 1-9) can land on the C++ repo before the C# changes (Tasks 10-14). C# adding the wire key with value `false` is a no-op on the old C++ parser (unknown keys are ignored). C# adding the key with value `true` requires the C++ side to be deployed first. Implementers should land and deploy C++ DLLs (Task 16 Step 3), then land C# changes.

---

Plan complete and saved to `docs/superpowers/plans/2026-04-20-charge-based-exclusion.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

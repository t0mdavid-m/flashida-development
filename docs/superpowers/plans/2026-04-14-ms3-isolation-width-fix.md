# Fix MS3 Exploration Isolation Width — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix MS3 RemainingPrecursor exploration scoring by preserving isolation window bounds in the synthetic PeakGroup and applying a 2.0 Da minimum floor to isolation width.

**Architecture:** Two changes in `Exploration.cpp`: (1) `initiateNextLevel()` pushes two peaks (`wstarts[ti]`, `wends[ti]`) instead of one center peak so `getMzRange()` returns a real range, (2) `initiate()` applies `std::max(isolation_width, 2.0)` matching `buildMS3()`'s floor. One new test section validates MS3 RemainingPrecursor scoring end-to-end.

**Tech Stack:** C++20, OpenMS ClassTest framework

**Spec:** `docs/superpowers/specs/2026-04-14-ms3-isolation-width-fix-design.md`

---

### Task 1: Fix isolation width computation and add test

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:80` (add 2.0 Da floor in `initiate()`)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:433-438` (two-peak PeakGroup in `initiateNextLevel()`)
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp:1525` (add new test section before `END_TEST`)

- [ ] **Step 1: Add MS3 RemainingPrecursor config string to test file**

In `FLASHIda_exploration_test.cpp`, after the `remaining_precursor_config` string (which ends at line 382 with `})";`), add a new config string. This is identical to `remaining_precursor_config` but adds MS3 RemainingPrecursor exploration:

After line 382 (`})";`), insert:

```cpp
  // Config with remaining_precursor exploration metric at MS3
  const char* ms3_remaining_precursor_config = R"({
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
        "max_targets": 3
      },
      "ms3": {
        "selection": "none",
        "max_targets": 3,
        "exploration": {
          "metric": "remaining_precursor",
          "ce_min": 20.0,
          "ce_max": 40.0,
          "ce_step": 5.0
        }
      }
    }
  })";
```

- [ ] **Step 2: Add test section `ms3_remaining_precursor_isolation_width`**

Before the final `END_TEST` (currently line 1529), add:

```cpp
START_SECTION(ms3_remaining_precursor_isolation_width)
{
  // MS3 RemainingPrecursor scoring requires non-zero isolation_width.
  // Before the fix, initiate() computed width=0 from single-peak PeakGroups,
  // causing all MS3 variants to score -1. The 2.0 Da floor fixes this.
  Config cfg{std::string(ms3_remaining_precursor_config)};
  ScanCommandQueue queue(cfg);
  Deconvolution deconv(cfg);
  FragmentAnalysis fragments(cfg);
  Exploration exploration(cfg, deconv, fragments);

  // Create a narrow single-peak PeakGroup (simulates MS3 fragment target)
  // getMzRange() returns (500.0, 500.0) -> width=0 before floor
  auto fragment_pg = makeSyntheticPeakGroup(500.0, 1000.0, 2);
  ScanCommand ms2_ctx = queue.buildMS2(makeSyntheticPeakGroup(800.0, 2400.0, 3), 3,
                                        cfg.level(2).scans[0]);

  auto cmds = exploration.initiate(3, fragment_pg, 2, 0.0, queue, &ms2_ctx);
  // RemainingPrecursor: 1 baseline + 5 CE variants (20,25,30,35,40) = 6
  TEST_EQUAL(static_cast<int>(cmds.size()), 6)

  auto group = exploration.getGroup(1);
  // isolation_width should be floored to 2.0 (not 0.0)
  TEST_REAL_SIMILAR(group.isolation_width, 2.0)

  double mz_center = group.precursor_mz;

  // Feed baseline (CE=0) with signal at precursor center
  std::vector<double> baseline_mzs = {mz_center};
  std::vector<double> baseline_ints = {1000.0};
  int baseline_tid = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));
  exploration.feedResult(baseline_tid, baseline_mzs.data(), baseline_ints.data(),
                         static_cast<int>(baseline_mzs.size()), 0.5, queue);

  auto group_after = exploration.getGroup(1);
  TEST_EQUAL(group_after.has_baseline, true)
  // With 2.0 Da window [499.0, 501.0], mz_center=500.0 is in-window
  TEST_REAL_SIMILAR(group_after.baseline_intensity, 1000.0)

  // Feed CE=20 variant with 100.0 intensity -> ratio = 0.1
  std::vector<double> variant_ints = {100.0};
  int ce20_tid = queue.decode(std::string(cmds[1].scan_description).substr(0, 3));
  auto info = exploration.feedResult(ce20_tid, baseline_mzs.data(), variant_ints.data(),
                                      1, 1.0, queue);

  // Score should be real (not -1.0), ratio = 100/1000 = 0.1
  TEST_REAL_SIMILAR(info.remaining_ratio, 0.1)
  TEST_REAL_SIMILAR(info.score, 1.0)  // target=0.1, deviation=0.0, score=1.0
  TEST_EQUAL(info.score > 0.0, true)
}
END_SECTION
```

- [ ] **Step 3: Apply 2.0 Da floor in `initiate()`**

In `Exploration.cpp`, change line 80 from:

```cpp
    double isolation_width = mz2 - mz1;
```

to:

```cpp
    double isolation_width = std::max(mz2 - mz1, 2.0);
```

- [ ] **Step 4: Fix PeakGroup construction in `initiateNextLevel()`**

In `Exploration.cpp`, change lines 433-438 from:

```cpp
        PeakGroup frag_pg(std::abs(charges[ti]), std::abs(charges[ti]), true);
        frag_pg.setMonoisotopicMass(masses[ti]);
        FLASHHelperClasses::LogMzPeak lp;
        lp.mz = (wstarts[ti] + wends[ti]) / 2.0;
        lp.abs_charge = std::abs(charges[ti]);
        frag_pg.push_back(lp);
```

to:

```cpp
        int abs_charge = std::abs(charges[ti]);
        PeakGroup frag_pg(abs_charge, abs_charge, true);
        frag_pg.setMonoisotopicMass(masses[ti]);
        FLASHHelperClasses::LogMzPeak lp_lo;
        lp_lo.mz = wstarts[ti];
        lp_lo.abs_charge = abs_charge;
        frag_pg.push_back(lp_lo);
        FLASHHelperClasses::LogMzPeak lp_hi;
        lp_hi.mz = wends[ti];
        lp_hi.abs_charge = abs_charge;
        frag_pg.push_back(lp_hi);
```

- [ ] **Step 5: Verify existing tests still pass**

The 2.0 Da floor changes `isolation_width` from 0.0 to 2.0 for all `makeSyntheticPeakGroup` calls (single-peak). Verify no existing assertions break:

- `remaining_precursor_target_aware_scoring` (line 1381): baseline peak at `mz_center`, window `[mz_center-1, mz_center+1]` — still in-window. Assertions unchanged.
- `remaining_precursor_score_with_raw_data` (line 1172): baseline mzs `{790, 800, 810, 900}`, window `[799, 801]` — only 800.0 in-window (same as before with point match). Assertions only check `>= 0.0` and `<= 1.0`.
- `remaining_precursor_score_no_signal_in_window` (line 1222): mzs `{400, 500, 600, 1200}`, window `[799, 801]` — still all out-of-window.
- `ms3_exploration_variants_use_buildMS3` (line 709): uses `mass_count` metric, not RemainingPrecursor. No isolation_width assertions.

```bash
cd OpenMS/build && ctest -R FLASHIda_exploration_test -V
```

Expected: all existing tests pass, new `ms3_remaining_precursor_isolation_width` passes.

- [ ] **Step 6: Commit**

```bash
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Fix MS3 exploration isolation width: two-peak PeakGroup + 2.0 Da floor"
```

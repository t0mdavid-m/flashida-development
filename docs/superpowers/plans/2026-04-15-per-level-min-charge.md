# Per-Level Min Charge Selection Filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional per-MSn-level `min_charge` filter so that targets whose selected trigger charge falls below the threshold are silently skipped.

**Architecture:** `min_charge` is added to `MSLevelConfig` (C++ struct) and parsed from the `selection_strategy` JSON. Two filtering checks are inserted: one in `PrecursorSelection` (MS1 picks precursors for MS2) and one in `Exploration::initiateNextLevel` (MS2 picks fragments for MS3). The C# side (`MethodConfig.cs`, `MethodParameters.cs`) wires the field from the method JSON through to the C++ engine via `BuildSelectionStrategy()`.

**Tech Stack:** C++20 (OpenMS), C# .NET 4.8 (FlashIDA), OpenMS ClassTest framework

**Spec:** `docs/superpowers/specs/2026-04-15-per-level-min-charge-design.md`

---

### Task 1: Add `min_charge` field to C++ Config and parse from JSON

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:91-104`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:319`

- [ ] **Step 1: Add `min_charge` field to `MSLevelConfig`**

In `Config.h`, add the field after `max_targets` (line 94):

```cpp
    int max_targets = 10;
    int min_charge = 0;  ///< Minimum charge for target selection (0 = no filter)
```

The full struct becomes:

```cpp
  struct OPENMS_DLLAPI MSLevelConfig
  {
    std::vector<ScanConfig> scans;  ///< [0]=primary, [1]=conditional follow-up
    SelectionMetric selection = SelectionMetric::Intensity;
    int max_targets = 10;
    int min_charge = 0;  ///< Minimum charge for target selection (0 = no filter)

    ExplorationMetric exploration = ExplorationMetric::None;
    double ce_min = 20.0;
    double ce_max = 40.0;
    double ce_step = 5.0;
    std::unordered_map<std::string, std::string> overrides;
    double tolerance_ppm = 10.0;
    double exploration_tolerance_ppm = 10.0;  ///< Resolved exploration tolerance (from overrides or base tol)
    double remaining_precursor_target = 0.1;  ///< Target remaining precursor ratio (0.1 = 10%)
  };
```

- [ ] **Step 2: Parse `min_charge` from JSON**

In `Config.cpp`, after the `max_targets` parsing at line 319, add:

```cpp
        // Max targets
        cfg.max_targets = level_obj.value("max_targets", 10);

        // Minimum charge for target selection
        cfg.min_charge = level_obj.value("min_charge", 0);
```

- [ ] **Step 3: Verify by reading code**

Read the changed lines in both files. Confirm:
- `min_charge` has default `0` in both the struct and the JSON parser
- The JSON key is `"min_charge"` (matches the C# side planned in Task 4)
- The field sits logically next to `max_targets` in both struct and parser

---

### Task 2: Add MS1 charge filter in PrecursorSelection and test

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:429`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp`

- [ ] **Step 1: Add test assertion for MS1 min_charge filtering**

In `FLASHIda_ProcessScan_test.cpp`, add a new test section after the existing tests. This test uses a config with `ms1.min_charge` set high enough to filter out all precursors:

```cpp
START_SECTION(processScan_ms1_min_charge_filter)
{
  // Config identical to standard_json but with ms1.min_charge = 99
  // This should filter out ALL precursors since no precursor has charge >= 99
  const char* min_charge_json = R"({
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
    "conditional_ms2": false,
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_targets": 3, "min_charge": 99 },
      "ms2": { "selection": "none" },
      "ms3": { "selection": "none" }
    }
  })";

  FLASHIda ida(const_cast<char*>(min_charge_json));

  // Load same MS1 scans that normally produce commands
  auto scans = loadTsvScans("../../FlashIDA/test-data/ms1_standard.txt");
  ABORT_IF(scans.empty())

  for (const auto& scan : scans)
  {
    ida.processScan(scan.mzs.data(), scan.ints.data(), (int)scan.mzs.size(),
                    scan.rt, 1, -50.0);
  }

  // With min_charge=99, no precursor should pass the filter
  ScanCommand cmd{};
  int result = ida.getNextScanCommand(cmd);
  TEST_EQUAL(result, 0)  // no commands generated
}
END_SECTION
```

- [ ] **Step 2: Verify the test would fail without the implementation**

Read `PrecursorSelection.cpp` lines 425-430. The current code has no charge filtering after the charge selection decision tree — all PeakGroups proceed to mass checking regardless of charge. The test assertion `TEST_EQUAL(result, 0)` would fail because commands would still be generated.

- [ ] **Step 3: Add the charge filter to PrecursorSelection**

In `PrecursorSelection.cpp`, after the charge selection decision tree (line 428) and before `double mass = pg.getMonoMass();` (line 430), add:

```cpp
          else {
            charge = pg.getRepAbsCharge();
            score = pg.getQscore();
          }

          // Per-level charge filter: ms1.min_charge controls what MS1 picks
          if (config_.level(ms_level).min_charge > 0 && charge < config_.level(ms_level).min_charge)
            continue;

          double mass = pg.getMonoMass();
```

Note: `ms_level` is always `1` in this function (guarded at line 179).

- [ ] **Step 4: Verify the fix is correct**

Read the modified `PrecursorSelection.cpp`. Confirm:
- The `continue` skips the current PeakGroup in the loop (returns to next iteration of the PeakGroup iteration loop)
- `config_.level(ms_level)` resolves to `config_.level(1)` — the MS1 config
- When `min_charge` is `0` (default), the condition is `false` and no filtering occurs
- The filter runs after charge selection but before mass exclusion logic

---

### Task 3: Add MS2→MS3 charge filter in Exploration and test

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:475-534`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add test for MS2 min_charge filtering in `initiateNextLevel`**

In `FLASHIda_exploration_test.cpp`, add a new test section. This tests that when `ms2.min_charge` is set, fragments with charge below the threshold are skipped by `initiateNextLevel()`.

First, add a new config string near the other configs (after `ms3_exploration_config`, around line 170). This config has `ms2.min_charge = 99` to filter out all fragments:

```cpp
  // Config with ms2.min_charge set impossibly high — all fragments should be filtered
  const char* ms2_min_charge_config = R"({
    "deconvolution": {
      "score_threshold": 0.0,
      "tqscore_threshold": 0.9,
      "min_charge": 1,
      "max_charge": 50,
      "min_mass": 100,
      "max_mass": 50000,
      "tol": [10, 10, 10]
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
          "activation": "HCD",
          "collision_energy": 35,
          "resolution": 60000
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
      "ms2": { "selection": "intensity", "max_targets": 3, "min_charge": 99 },
      "ms3": { "selection": "none" }
    }
  })";
```

Then add the test section:

```cpp
START_SECTION(initiateNextLevel_ms2_min_charge_filters_fragments)
{
  Config cfg{std::string(ms2_min_charge_config)};
  ScanCommandQueue queue(cfg);
  FragmentAnalysis fragments(cfg);
  Exploration exploration(cfg, fragments);

  // Load real MS2 spectrum that normally produces fragment matches
  auto scans = loadTsvScans("../../FlashIDA/test-data/ms2_hcd_fragment.txt");
  ABORT_IF(scans.empty())

  // Deconvolve the MS2 spectrum
  Deconvolution deconv(cfg, {10.0, 10.0, 10.0});
  for (const auto& scan : scans)
  {
    deconv.deconvolveMSn(scan.mzs.data(), scan.ints.data(), (int)scan.mzs.size(),
                         scan.rt, 12000.0, 10);
  }

  auto precursor_pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  ScanCommand ms2_ctx = queue.buildMS2(precursor_pg, 3, cfg.level(2).scans[0]);

  // initiateNextLevel processes MS2 results and picks fragments for MS3
  // With ms2.min_charge=99, ALL fragments should be filtered out
  auto nlr = exploration.initiateNextLevel(2, deconv.storedMS2(), -50.0, queue, &ms2_ctx);
  TEST_EQUAL(nlr.commands.size(), 0)  // no commands — all fragments filtered by charge
}
END_SECTION
```

- [ ] **Step 2: Verify the test would fail without the implementation**

Read `Exploration.cpp` lines 475-534. The current command-building loops have no charge check — all fragments returned by `getTopFragmentMatches()` produce commands. The test assertion `TEST_EQUAL(nlr.commands.size(), 0)` would fail because commands would be generated for the matched fragments.

- [ ] **Step 3: Add the charge filter to both loops in `initiateNextLevel`**

In `Exploration.cpp`, add a `charge_floor` variable before the conditional branch at line 475, and add a `continue` guard at the top of each loop.

The modified code starting at line 470:

```cpp
    num_targets = std::min(num_targets, found);

    // Build commands for each selected fragment target
    ScanConfig next_scan_config = next_cfg.scans[0];

    int charge_floor = this_cfg.min_charge;

    if (config_.hasExploration(next_level))
    {
      // Recursive exploration at next level
      for (int ti = 0; ti < num_targets; ++ti)
      {
        int abs_charge = std::abs(charges[ti]);
        if (charge_floor > 0 && abs_charge < charge_floor)
          continue;

        PeakGroup frag_pg(abs_charge, abs_charge, true);
```

And similarly for the direct command-building loop at line 500:

```cpp
    else
    {
      // Direct command building for each fragment target
      for (int ti = 0; ti < num_targets; ++ti)
      {
        double frag_mz = (wstarts[ti] + wends[ti]) / 2.0;
        int frag_charge = std::abs(charges[ti]);
        if (charge_floor > 0 && frag_charge < charge_floor)
          continue;

        double iso_width = wends[ti] - wstarts[ti];
```

- [ ] **Step 4: Verify the fix is correct**

Read the modified `Exploration.cpp`. Confirm:
- `this_cfg` is `config_.level(msn_level)` (line 396), which is the level doing the picking
- `charge_floor` is read once before the branch, used in both loops
- When `min_charge` is `0` (default), the condition is `false` and no filtering occurs
- The `continue` skips the current fragment, not the entire loop

---

### Task 4: Add `MinCharge` to C# MethodConfig and BuildSelectionStrategy

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:259-298,495-500`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:270-287`

- [ ] **Step 1: Add `MinCharge` to `MS1SelectionConfig`**

In `MethodConfig.cs`, add the property after `MaxTargets` in `MS1SelectionConfig` (after line 267):

```csharp
    [JsonKey("ms1")]
    public class MS1SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS1 precursor selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "qscore";

        [JsonKey("max_targets")]
        [Description("Maximum number of targets to select per MS1 scan")]
        public int MaxTargets { get; set; } = 10;

        [JsonKey("min_charge")]
        [Description("Minimum charge state for target selection (0 = no filter)")]
        public int MinCharge { get; set; } = 0;
    }
```

- [ ] **Step 2: Add `MinCharge` to `MS2SelectionConfig`**

In `MethodConfig.cs`, add the property after `MaxTargets` in `MS2SelectionConfig` (after line 279):

```csharp
    [JsonKey("ms2")]
    public class MS2SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS2 fragment selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "intensity";

        [JsonKey("max_targets")]
        [Description("Maximum number of targets to select per MS2 scan")]
        public int MaxTargets { get; set; } = 3;

        [JsonKey("min_charge")]
        [Description("Minimum charge state for target selection (0 = no filter)")]
        public int MinCharge { get; set; } = 0;

        [JsonKey("exploration")]
        public ExplorationBlockConfig Exploration { get; set; }
    }
```

- [ ] **Step 3: Add `MinCharge` to `MS3SelectionConfig`**

In `MethodConfig.cs`, add the property after `MaxTargets` in `MS3SelectionConfig` (after line 294):

```csharp
    [JsonKey("ms3")]
    public class MS3SelectionConfig
    {
        [JsonKey("selection")]
        [Description("MS3 fragment selection metric: qscore, intensity, or none")]
        public string Selection { get; set; } = "none";

        [JsonKey("max_targets")]
        [Description("Maximum number of targets to select per MS3 scan")]
        public int MaxTargets { get; set; } = 3;

        [JsonKey("min_charge")]
        [Description("Minimum charge state for target selection (0 = no filter)")]
        public int MinCharge { get; set; } = 0;

        [JsonKey("exploration")]
        public ExplorationBlockConfig Exploration { get; set; }
    }
```

- [ ] **Step 4: Add `min_charge` to `JsonMsLevelConfig`**

In `MethodConfig.cs`, add the field to `JsonMsLevelConfig` (after line 498):

```csharp
    public class JsonMsLevelConfig
    {
        public string selection { get; set; }
        public int max_targets { get; set; }
        public int min_charge { get; set; }
        public JsonExplorationBlockConfig exploration { get; set; }
    }
```

- [ ] **Step 5: Wire `MinCharge` in `BuildSelectionStrategy()`**

In `MethodParameters.cs`, update the three `JsonMsLevelConfig` constructors in `BuildSelectionStrategy()` (lines 272-287) to include `min_charge`:

```csharp
            var result = new JsonSelectionStrategyConfig
            {
                ms1 = new JsonMsLevelConfig
                {
                    selection = (ss.MS1?.Selection ?? "qscore").ToLower(),
                    max_targets = ms1Max,
                    min_charge = ss.MS1?.MinCharge ?? 0
                },
                ms2 = new JsonMsLevelConfig
                {
                    selection = (ss.MS2?.Selection ?? "intensity").ToLower(),
                    max_targets = ms2Max,
                    min_charge = ss.MS2?.MinCharge ?? 0
                },
                ms3 = new JsonMsLevelConfig
                {
                    selection = (ss.MS3?.Selection ?? "none").ToLower(),
                    max_targets = ms3Max,
                    min_charge = ss.MS3?.MinCharge ?? 0
                }
            };
```

- [ ] **Step 6: Verify all C# changes are consistent**

Read all modified sections. Confirm:
- All three level configs have `MinCharge` with `[JsonKey("min_charge")]` and default `0`
- `JsonMsLevelConfig` has `min_charge` (lowercase, matching JSON convention)
- `BuildSelectionStrategy()` wires all three levels with `?? 0` fallback
- No other files need changes (bridge functions unchanged)

---

### Task 5: Commit all changes

- [ ] **Step 1: Commit C++ changes (OpenMS submodule)**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git add src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp
git add src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "feat: add per-level min_charge selection filter

MSLevelConfig.min_charge controls the minimum trigger charge for target
selection at each MSn level. ms1.min_charge filters precursors for MS2,
ms2.min_charge filters fragments for MS3. Defaults to 0 (no filter)."
```

- [ ] **Step 2: Commit C# changes (FlashIDA submodule)**

```bash
cd ../FlashIDA
git add src/Flash/MethodConfig.cs
git add src/Flash/MethodParameters.cs
git commit -m "feat: add MinCharge to per-level selection config

Wires min_charge from method JSON through MethodConfig classes and
BuildSelectionStrategy() to the C++ engine JSON config."
```

- [ ] **Step 3: Update parent repo submodule pointers**

```bash
cd ..
git add OpenMS FlashIDA
git commit -m "Update submodules: per-level min_charge selection filter"
```

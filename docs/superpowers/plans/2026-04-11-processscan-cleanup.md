# processScan Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seven incremental improvements to `processScan()`, `getNextScanCommand()`, and supporting classes — fixing timing semantics, FAIMS CV propagation, exploration flow, config validation, and scan construction consolidation.

**Architecture:** All changes are C++ in `ANALYSIS/TOPDOWN/FLASHIda/`. The core refactoring consolidates `buildMS2` into a single factory receiving a fully resolved `ScanConfig`. This cascades into cleaner CE determination, exploration flow, and follow-up scan construction.

**Tech Stack:** C++20, OpenMS ClassTest framework, CMake/CTest

**Branch:** `phase-10`

**Build constraint:** Never build locally. Push to `flashida-v9-bridge` for CI builds only.

---

## File Structure

**Modify:**
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` — add `validate()`, add `follow_up_scan` to QuantConfig and tagging, add `applyOverrides()` to ScanConfig
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` — implement `validate()`, parse `follow_up_scan` from JSON
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h` — `filterAndRank` signature: `const char* cv` -> `double faims_cv`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp` — update `filterAndRank` definition and `deconvolveMS1` call
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h` — `deconvolveMS1` signature: `const char* cv` -> `double faims_cv`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp` — update `deconvolveMS1` body
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` — move `recordMS1Time`, update `filterAndRank` call, restructure MS1 path, update follow-up call sites
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` — new `buildMS2` signature, remove second overload, replace follow-up methods with `buildFollowUp`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` — new `buildMS2` body, remove second overload, `buildFollowUp` implementation
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h` — change `initiate()` signature, add PeakGroup/charge to `ExplorationGroup`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` — update `initiate()`, `feedResult()`, `initiateNextLevel()`

**Test files to modify:**
- `OpenMS/src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp` — add config validation tests
- `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` — update for new initiate() signature and dynamic isolation width
- `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` — update JSON configs for follow-up scan changes
- `OpenMS/src/tests/class_tests/openms/source/FLASHIdaFAIMS_test.cpp` — verify FAIMS CV double propagation

---

### Task 1: Config Validation

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:206`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:283`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp`

- [ ] **Step 1: Write the failing tests**

In `FLASHIda_LegacyConfig_test.cpp`, add two new test sections before the final `END_TEST`. The tests construct Config objects with invalid JSON combos and verify `std::invalid_argument` is thrown.

The first test enables both IDScore and exploration (mutual exclusion). Build a valid JSON config with `"precursor_selection": { "IDScore": true }` and `"selection_strategy": { "ms2": { "exploration": { "metric": "mass_count", ... } } }`.

The second test enables exploration with two MS2 scan configs (exploration requires exactly one). Build a valid JSON config with `"ms2": [{ ... }, { ... }]` and `"selection_strategy": { "ms2": { "exploration": { "metric": "mass_count", ... } } }`.

Test code for section 1 (IDScore + exploration mutual exclusion):
```cpp
START_SECTION(([EXTRA] Config rejects IDScore + exploration combo))
{
  // Valid base config but with both IDScore and MS2 exploration enabled
  const char* json = R"({
    "deconvolution": { "min_charge": 4, "max_charge": 50, "min_mass": 500, "max_mass": 50000, "tol": [10, 10] },
    "precursor_selection": { "IDScore": true, "HCDEnergy": -1 },
    "tagging": {},
    "quantification": { "enabled": false },
    "faims": {},
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [{ "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }]
    },
    "scheduling": { "cycle_time": { "enabled": false }, "scan_timeout": { "enabled": false }, "agc_interval_seconds": 30 },
    "files": {},
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 3 },
      "ms2": { "selection": "intensity", "exploration": { "metric": "mass_count", "ce_min": 20, "ce_max": 40, "ce_step": 5, "activation": "HCD" } }
    }
  })";
  bool threw = false;
  try { Config cfg(std::string(json)); }
  catch (const std::invalid_argument&) { threw = true; }
  TEST_EQUAL(threw, true)
  (void)threw;
}
END_SECTION
```

Test code for section 2 (exploration with multiple scan configs):
```cpp
START_SECTION(([EXTRA] Config rejects exploration with multiple scan configs))
{
  const char* json = R"({
    "deconvolution": { "min_charge": 4, "max_charge": 50, "min_mass": 500, "max_mass": 50000, "tol": [10, 10] },
    "precursor_selection": { "IDScore": false },
    "tagging": {},
    "quantification": { "enabled": false },
    "faims": {},
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [
        { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 },
        { "analyzer": "Orbitrap", "activation": "ETD", "collision_energy": 0, "resolution": 60000 }
      ]
    },
    "scheduling": { "cycle_time": { "enabled": false }, "scan_timeout": { "enabled": false }, "agc_interval_seconds": 30 },
    "files": {},
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 3 },
      "ms2": { "selection": "intensity", "exploration": { "metric": "mass_count", "ce_min": 20, "ce_max": 40, "ce_step": 5, "activation": "HCD" } }
    }
  })";
  bool threw = false;
  try { Config cfg(std::string(json)); }
  catch (const std::invalid_argument&) { threw = true; }
  TEST_EQUAL(threw, true)
  (void)threw;
}
END_SECTION
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd OpenMS/build && ctest -R FLASHIda_LegacyConfig_test -VV`
Expected: FAIL — Config constructor does not throw yet for these combos.

- [ ] **Step 3: Implement validate()**

In `Config.h`, add the declaration after the `runtime()` accessor (after line ~203, before the `levels()` accessor):
```cpp
    /// Validate config consistency. Called at end of constructor. Throws std::invalid_argument on invalid combos.
    void validate() const;
```

In `Config.cpp`, add the implementation after the constructor (after line 293, before `Config::level()`):
```cpp
  void Config::validate() const
  {
    if (targeting_.use_idscore && exploration_enabled_)
      throw std::invalid_argument(
          "IDScore and exploration cannot both be enabled. "
          "IDScore determines optimal HCD analytically; "
          "exploration determines it empirically via CE sweep.");

    for (const auto& [lvl, cfg] : levels_)
    {
      if (cfg.exploration != ExplorationMetric::None && cfg.scans.size() != 1)
        throw std::invalid_argument(
            "Exploration at level " + std::to_string(lvl) +
            " requires exactly one scan config, got " +
            std::to_string(cfg.scans.size()) + ".");
    }
  }
```

At the end of the constructor body (line 292, after `targeting_.snr_threshold = 1.0;`), add:
```cpp
    validate();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd OpenMS/build && ctest -R FLASHIda_LegacyConfig_test -VV`
Expected: PASS — both new sections pass (exceptions thrown).

Also run the full FLASH test suite to verify no existing configs are inadvertently rejected:
Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All existing tests PASS.

- [ ] **Step 5: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Add Config::validate() with IDScore/exploration mutual exclusion"
```

---

### Task 2: FAIMS CV as `double`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h:129-130`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:176-177`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h:71-72`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp:61-65`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:515`

- [ ] **Step 1: Change `Deconvolution::deconvolveMS1` signature**

In `Deconvolution.h`, change the declaration (line ~71-72):
```cpp
// Before:
DeconvolvedSpectrum deconvolveMS1(const double* mzs, const double* ints, int length,
                                  double rt, const char* cv);
// After:
DeconvolvedSpectrum deconvolveMS1(const double* mzs, const double* ints, int length,
                                  double rt, double faims_cv);
```

In `Deconvolution.cpp`, change the definition (lines 61-65):
```cpp
// Before:
DeconvolvedSpectrum Deconvolution::deconvolveMS1(const double* mzs, const double* ints,
                                                  int length, double rt, const char* cv)
{
  auto spec = makeMSSpectrum_(mzs, ints, length, rt, 1, "ms1_spectrum");
  if (cv != nullptr) { spec.setMetaValue("filter string", DataValue("cv=" + std::string(cv))); }
// After:
DeconvolvedSpectrum Deconvolution::deconvolveMS1(const double* mzs, const double* ints,
                                                  int length, double rt, double faims_cv)
{
  auto spec = makeMSSpectrum_(mzs, ints, length, rt, 1, "ms1_spectrum");
  if (faims_cv != 0.0) { spec.setMetaValue("filter string", DataValue("cv=" + std::to_string(faims_cv))); }
```

- [ ] **Step 2: Change `PrecursorSelection::filterAndRank` signature**

In `PrecursorSelection.h`, change the declaration (lines 129-130):
```cpp
// Before:
int filterAndRank(const double* mzs, const double* ints, int length,
                  double rt, int ms_level, const char* cv);
// After:
int filterAndRank(const double* mzs, const double* ints, int length,
                  double rt, int ms_level, double faims_cv);
```

In `PrecursorSelection.cpp`, change the definition (lines 176-177):
```cpp
// Before:
int PrecursorSelection::filterAndRank(const double* mzs, const double* ints, int length,
                                      double rt, int ms_level, const char* cv)
// After:
int PrecursorSelection::filterAndRank(const double* mzs, const double* ints, int length,
                                      double rt, int ms_level, double faims_cv)
```

Also update the call to `deconvolveMS1` inside `filterAndRank` (line 237):
```cpp
// Before:
deconv_.deconvolveMS1(mzs, ints, length, rt, cv);
// After:
deconv_.deconvolveMS1(mzs, ints, length, rt, faims_cv);
```

- [ ] **Step 3: Update call site in `processScan()`**

In `FLASHIda.cpp`, line 515:
```cpp
// Before:
int n = selection_.filterAndRank(mzs, ints, length, rt_min, 1, nullptr);
// After:
int n = selection_.filterAndRank(mzs, ints, length, rt_min, 1, faims_cv);
```

Note: `faims_cv` is the function parameter (line 498). When FAIMS is not enabled, the caller passes `0.0`, which correctly skips the metadata annotation.

- [ ] **Step 4: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All tests PASS. The type change is transparent — non-FAIMS tests pass 0.0 (same as nullptr semantics), FAIMS tests now propagate the CV value.

- [ ] **Step 5: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Change FAIMS CV parameter from const char* to double through filterAndRank/deconvolveMS1"
```

---

### Task 3: Move `recordMS1Time()` to Dequeue

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:506,842,868`

- [ ] **Step 1: Remove `recordMS1Time()` from `processScan()` MS1 path**

In `FLASHIda.cpp`, delete line 506:
```cpp
// Delete this line:
queue_.recordMS1Time();
```

This is in the `if (ms_level == 1)` block, just after the mutex lock.

- [ ] **Step 2: Remove `recordMS1Time()` from idle MS1 creation in `getNextScanCommand()`**

In `FLASHIda.cpp`, delete line 868:
```cpp
// Delete this line (in the idle MS1 creation block, Step 5b):
queue_.recordMS1Time();
```

This is in the `getNextScanCommand()` idle cycle path, after `ms1_cmd.priority = 0;` (line 867).

- [ ] **Step 3: Add `recordMS1Time()` to the dequeue block**

In `FLASHIda.cpp`, in `getNextScanCommand()`, after line 842 (`out = dequeued.value();`), add the recording check:
```cpp
    out = dequeued.value();
    if (out.msn_level == 1 && out.is_agc == 0)
      queue_.recordMS1Time();
```

The cycle-time forced MS1 path at line 825 (`queue_.recordMS1Time()`) stays — it bypasses the queue and returns directly.

- [ ] **Step 4: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All tests PASS. Timing semantics change from result-to-result to send-to-send, but no test relies on absolute timing values.

- [ ] **Step 5: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Move recordMS1Time() from result-arrival to command-dequeue for send-to-send timing"
```

---

### Task 4: Consolidate `buildMS2` to Single Factory

This is the largest task. It changes the `buildMS2` signature, updates all callers (processScan, Exploration), and removes the second overload.

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:68-71`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:170-297`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:66-76`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:74-89,102-104`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:58-112,190-267`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:521-528`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add `applyOverrides()` to `ScanConfig`**

In `Config.h`, add a method to the `ScanConfig` struct (after line 76, closing brace):
```cpp
struct OPENMS_DLLAPI ScanConfig
{
  std::string analyzer = "Orbitrap";
  std::string activation;
  int collision_energy = 0;
  int resolution = 0;
  int agc_target = 0;
  double first_mass = 0;
  double last_mass = 0;
  double max_it = 0;

  /// Apply string-keyed overrides to this scan config (e.g. exploration overrides)
  void applyOverrides(const std::unordered_map<std::string, std::string>& overrides);
};
```

In `Config.cpp`, add the implementation (before the constructor, after the static default_level_):
```cpp
  void ScanConfig::applyOverrides(const std::unordered_map<std::string, std::string>& overrides)
  {
    for (const auto& [key, val] : overrides)
    {
      if (key == "analyzer") analyzer = val;
      else if (key == "activation") activation = val;
      else if (key == "collision_energy") collision_energy = static_cast<int>(std::stod(val));
      else if (key == "resolution") resolution = static_cast<int>(std::stod(val));
      else if (key == "agc_target") agc_target = static_cast<int>(std::stod(val));
      else if (key == "first_mass") first_mass = std::stod(val);
      else if (key == "last_mass") last_mass = std::stod(val);
      else if (key == "max_it") max_it = std::stod(val);
    }
  }
```

- [ ] **Step 2: Change `buildMS2` signature in header**

In `ScanCommandQueue.h`, replace both overload declarations (lines 68-71):
```cpp
// Before:
    ScanCommand buildMS2(const PeakGroup& pg, int charge, int hcd);
    ScanCommand buildMS2(double precursor_mz, int charge, double ce, const std::string& activation);
// After:
    ScanCommand buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config);
```

- [ ] **Step 3: Rewrite `buildMS2` implementation and remove second overload**

In `ScanCommandQueue.cpp`, replace the first overload body (lines 170-261) with the new unified factory. The new method reads ALL instrument settings from the provided `ScanConfig` instead of from `config_.level(2).scans[0]`. CE comes from `scan_config.collision_energy` (caller sets it). The PeakGroup provides isolation width and scoring fields.

```cpp
  ScanCommand ScanCommandQueue::buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config)
  {
    ScanCommand cmd{};
    int id = nextTrackingIdInt_();
    cmd.scan_id = id;
    cmd.msn_level = 2;
    cmd.priority = 1;
    cmd.is_agc = 0;
    cmd.num_stages = 1;

    // Instrument settings from fully resolved ScanConfig
    cmd.orbitrap_resolution = scan_config.resolution;
    std::strncpy(cmd.analyzer, scan_config.analyzer.c_str(), sizeof(cmd.analyzer) - 1);
    cmd.analyzer[sizeof(cmd.analyzer) - 1] = '\0';

    // AGC/mass range from MS1 config (instrument-level, not scan-specific)
    cmd.agc_target = config_.level(1).scans[0].agc_target;
    cmd.first_mass = config_.level(1).scans[0].first_mass;
    cmd.last_mass = config_.level(1).scans[0].last_mass;
    cmd.max_it = config_.level(1).scans[0].max_it;

    // Isolation window from peak group m/z range
    auto [mz1, mz2] = pg.getMzRange(charge);
    double center_mz = (mz1 + mz2) / 2.0;
    mz1 -= optimal_window_margin_;
    mz2 += optimal_window_margin_;
    double iso_width = mz2 - mz1;

    cmd.stages[0].precursor_mz = center_mz;
    cmd.stages[0].isolation_width = iso_width;
    cmd.stages[0].charge_state = charge;

    // CE and activation from the resolved ScanConfig
    cmd.stages[0].collision_energy = static_cast<double>(scan_config.collision_energy);
    std::strncpy(cmd.stages[0].activation_type, scan_config.activation.c_str(),
                 sizeof(cmd.stages[0].activation_type) - 1);
    cmd.stages[0].activation_type[sizeof(cmd.stages[0].activation_type) - 1] = '\0';

    // Scan description: {3-char ID}R{mass_kDa:.1f}@{charge}
    std::string id_str = encode(id);
    std::snprintf(cmd.scan_description, 16, "%sR%.1f@%d", id_str.c_str(), pg.getMonoMass() / 1000.0, charge);

    // Timestamp
    cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());

    // Precursor scoring data for diagnostic TSV output
    cmd.qscore = pg.getQscore();
    cmd.mono_mass = pg.getMonoMass();
    cmd.charge_cos = pg.getChargeIsotopeCosine(std::abs(charge));
    cmd.charge_snr = pg.getChargeSNR(std::abs(charge));
    cmd.iso_cos = pg.getIsotopeCosine();
    cmd.snr = pg.getSNR();
    cmd.charge_score = pg.getChargeScore();
    cmd.ppm_error = pg.getAvgPPMError();
    cmd.precursor_intensity = pg.getChargeIntensity(std::abs(charge));
    cmd.peakgroup_intensity = pg.getIntensity();
    cmd.hcd_energy = scan_config.collision_energy;
    cmd.pad2 = 0;

    // Store in pending map for MS2 tracking resolution
    pending_scan_map_[id] = cmd;

    std::cout << "[TRACK-CREATE] id=" << id_str
              << " ms_level=2"
              << " mz=" << center_mz
              << " z=" << charge
              << " mass=" << pg.getMonoMass()
              << std::endl;

    return cmd;
  }
```

Delete the entire second overload (lines 263-297, the `buildMS2(double, int, double, string)` method).

- [ ] **Step 4: Update `applyOverrides` on ScanCommandQueue**

The existing `ScanCommandQueue::applyOverrides(ScanCommand&, ...)` at lines 508-519 applies overrides to a ScanCommand directly (setting `cmd.agc_target`, `cmd.max_it`, `cmd.stages[0].isolation_width`). Now that ScanConfig has its own `applyOverrides`, the ScanCommandQueue version is still needed for fields that don't map to ScanConfig (like `isolation_width` on stages). Keep it but update it to handle the fields that ScanConfig doesn't cover:

```cpp
  void ScanCommandQueue::applyOverrides(ScanCommand& cmd,
      const std::unordered_map<std::string, std::string>& overrides) const
  {
    for (const auto& [key, val] : overrides)
    {
      if (key == "agc_target") cmd.agc_target = static_cast<int32_t>(std::stod(val));
      else if (key == "max_injection_time_ms") cmd.max_it = std::stod(val);
      else if (key == "isolation_width") cmd.stages[0].isolation_width = std::stod(val);
    }
  }
```

No change needed here — keep as-is. The ScanConfig `applyOverrides` handles config-level overrides (analyzer, resolution, CE); the ScanCommandQueue `applyOverrides` handles command-level overrides (AGC, max_it, isolation_width).

- [ ] **Step 5: Update `Exploration::initiate()` signature and body**

In `Exploration.h`, change the signature (lines 102-104):
```cpp
// Before:
    std::vector<ScanCommand> initiate(int msn_level, double precursor_mz, double precursor_mass,
                                      int precursor_charge, double faims_cv,
                                      ScanCommandQueue& queue);
// After:
    std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,
                                      double faims_cv, ScanCommandQueue& queue);
```

Add `PeakGroup` and `charge` fields to `ExplorationGroup` (lines 74-89). Add after `int precursor_charge`:
```cpp
  PeakGroup precursor_pg;    // stored for production scan in feedResult
```

In `Exploration.cpp`, rewrite `initiate()` (lines 58-112):
```cpp
  std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,
      double faims_cv, ScanCommandQueue& queue)
  {
    std::vector<ScanCommand> commands;

    const auto& cfg = config_.level(msn_level);
    if (!config_.hasExploration(msn_level)) return commands;

    std::vector<double> ces = buildCEVariants_(cfg.ce_min, cfg.ce_max, cfg.ce_step);
    if (ces.empty()) return commands;

    ExplorationGroup group;
    group.group_id = next_group_id_++;
    group.msn_level = msn_level;
    group.exploration_metric = cfg.exploration;
    group.precursor_mz = pg.getMonoMass() > 0 ? (pg.getMzRange(charge).first + pg.getMzRange(charge).second) / 2.0 : 0.0;
    group.precursor_mass = pg.getMonoMass();
    group.precursor_charge = charge;
    group.precursor_pg = pg;
    group.faims_cv = faims_cv;
    group.start_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());

    // Build ScanConfig for exploration variants: base from config, override CE per variant
    ScanConfig base_config = cfg.scans.empty() ? ScanConfig{} : cfg.scans[0];
    base_config.applyOverrides(cfg.overrides);

    for (int i = 0; i < static_cast<int>(ces.size()); ++i)
    {
      ExplorationVariant v;
      v.variant_index = i;
      v.collision_energy = ces[i];
      v.activation_type = cfg.exploration_activation;

      ScanConfig variant_config = base_config;
      variant_config.collision_energy = static_cast<int>(ces[i]);
      variant_config.activation = cfg.exploration_activation;

      ScanCommand cmd = queue.buildMS2(pg, charge, variant_config);
      cmd.priority = 0;
      cmd.faims_cv = faims_cv;

      int id_int = cmd.scan_id;
      std::string id_str = ScanCommandQueue::encode(id_int);
      v.tracking_id = id_str;
      std::snprintf(cmd.scan_description, 16, "%sE%.1f@%d",
                   id_str.c_str(), pg.getMonoMass() / 1000.0, charge);

      group.variants.push_back(v);
      variant_tracking_map_[id_int] = {group.group_id, i};
      commands.push_back(cmd);

      std::cout << "[TRACK-CREATE] id=" << id_str
                << " ms_level=" << msn_level << " type=exploration"
                << " CE=" << ces[i] << std::endl;
    }

    active_groups_[group.group_id] = std::move(group);
    return commands;
  }
```

- [ ] **Step 6: Update `Exploration::feedResult()` production scan path**

In `Exploration.cpp`, `feedResult()` lines 191-206. The production scan path currently calls the second overload. Change it to use the stored PeakGroup:

```cpp
// Before (lines 194-199):
    ScanCommand prod_cmd = queue.buildMS2(
        group.precursor_mz, group.precursor_charge,
        group.variants[best_idx].collision_energy,
        group.variants[best_idx].activation_type);
    prod_cmd.faims_cv = group.faims_cv;
    prod_cmd.priority = 1;

// After:
    ScanConfig prod_config = config_.level(group.msn_level).scans[0];
    prod_config.collision_energy = static_cast<int>(group.variants[best_idx].collision_energy);
    prod_config.activation = group.variants[best_idx].activation_type;

    ScanCommand prod_cmd = queue.buildMS2(group.precursor_pg, group.precursor_charge, prod_config);
    prod_cmd.faims_cv = group.faims_cv;
    prod_cmd.priority = 1;
```

- [ ] **Step 7: Update `Exploration::initiateNextLevel()`**

In `Exploration.cpp`, `initiateNextLevel()` (lines 222-267). This method creates commands at the next MSn level from DeconvolvedSpectrum results. Each element in a DeconvolvedSpectrum is a PeakGroup. Update both the exploration and non-exploration paths.

For the exploration recursive path (lines 241-245):
```cpp
// Before:
      auto sub_cmds = initiate(next_level, targets[ti].first, 0.0, 0, faims_cv, queue);
// After:
      auto sub_cmds = initiate(next_level, result[sorted_indices[ti]], 0, faims_cv, queue);
```

For the non-exploration path (lines 249-263):
```cpp
// Before:
      ScanCommand cmd = queue.buildMS2(targets[ti].first, 0,
          next_cfg.ce_min, next_cfg.exploration_activation);
      cmd.msn_level = next_level;
// After:
      ScanConfig next_scan_config = next_cfg.scans.empty() ? ScanConfig{} : next_cfg.scans[0];
      ScanCommand cmd = queue.buildMS2(result[sorted_indices[ti]], 0, next_scan_config);
      cmd.msn_level = next_level;
```

The full `initiateNextLevel` rewrite needs to maintain sort indices alongside the sorted pairs. Replace the entire body:

```cpp
  std::vector<ScanCommand> Exploration::initiateNextLevel(int msn_level,
      const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue)
  {
    std::vector<ScanCommand> commands;

    int next_level = msn_level + 1;
    const auto& next_cfg = config_.level(next_level);
    if (next_cfg.selection == SelectionMetric::None) return commands;

    // Build (index, intensity) pairs for sorting
    std::vector<int> indices(result.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::sort(indices.begin(), indices.end(),
              [&result](int a, int b){ return result[a].getIntensity() > result[b].getIntensity(); });
    int num_targets = std::min(static_cast<int>(indices.size()), next_cfg.max_targets);

    if (config_.hasExploration(next_level))
    {
      for (int ti = 0; ti < num_targets; ++ti)
      {
        auto sub_cmds = initiate(next_level, result[indices[ti]], 0, faims_cv, queue);
        commands.insert(commands.end(), sub_cmds.begin(), sub_cmds.end());
      }
    }
    else
    {
      ScanConfig next_scan_config = next_cfg.scans.empty() ? ScanConfig{} : next_cfg.scans[0];
      for (int ti = 0; ti < num_targets; ++ti)
      {
        ScanCommand cmd = queue.buildMS2(result[indices[ti]], 0, next_scan_config);
        cmd.msn_level = next_level;
        cmd.faims_cv = faims_cv;
        cmd.priority = 1;

        std::string id_str = ScanCommandQueue::encode(cmd.scan_id);
        std::cout << "[TRACK-CREATE] id=" << id_str
                  << " ms_level=" << next_level << " type=next_level"
                  << std::endl;

        commands.push_back(cmd);
      }
    }

    return commands;
  }
```

Add `#include <numeric>` at the top of `Exploration.cpp` if not already present (for `std::iota`).

- [ ] **Step 8: Update call site in `processScan()` MS1 path**

In `FLASHIda.cpp`, the MS2 building loop (lines 521-528):
```cpp
// Before:
    for (int i = 0; i < n; i++)
    {
      ScanCommand cmd = queue_.buildMS2(selected[i], sel_charges[i], sel_hcds[i]);
      cmd.faims_cv = parent_cv;
      queue_.push(cmd);
      ms2_commands.push_back(cmd);
      commands_pushed++;
    }

// After:
    for (int i = 0; i < n; i++)
    {
      ScanConfig ms2_config = config_.level(2).scans[0];
      if (config_.targeting().use_idscore)
        ms2_config.collision_energy = sel_hcds[i];
      ScanCommand cmd = queue_.buildMS2(selected[i], sel_charges[i], ms2_config);
      cmd.faims_cv = parent_cv;
      queue_.push(cmd);
      ms2_commands.push_back(cmd);
      commands_pushed++;
    }
```

Also update the exploration initiation call (lines 550-552):
```cpp
// Before:
      auto cmds = exploration_.initiate(2, center_mz, selected[i].getMonoMass(),
          sel_charges[i], parent_cv, queue_);
// After:
      auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], parent_cv, queue_);
```

Remove the now-unused `center_mz` computation (lines 548-549) if it's only used by the old `initiate()` call.

- [ ] **Step 9: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: Some exploration tests may need config JSON updates if they check for `isolation_width = 2.0` (now dynamic). Fix any failures.

- [ ] **Step 10: Update exploration test expectations**

In `FLASHIda_exploration_test.cpp`, any assertions checking `isolation_width == 2.0` for exploration variants need updating. The new factory computes dynamic isolation width from PeakGroup. Since test PeakGroups may have different m/z ranges, update expected values or use `TEST_TRUE(cmd.stages[0].isolation_width > 0)` where exact width depends on synthetic PeakGroup data.

- [ ] **Step 11: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All PASS.

- [ ] **Step 12: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Consolidate buildMS2 to single factory taking PeakGroup + ScanConfig"
```

---

### Task 5: Simplify CE Logic

With the unified `buildMS2(PeakGroup, charge, ScanConfig)`, the old CE fallback chain no longer exists. CE is entirely determined by the caller who prepares the ScanConfig. This task verifies the caller logic is correct and the magic number `29` is gone.

**Files:**
- Verify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` — confirm no `hcd` parameter, no fallback chain, no `29`
- Verify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` — confirm caller CE logic

- [ ] **Step 1: Verify CE fallback chain is gone**

The old `buildMS2(PeakGroup, charge, hcd)` had this fallback at lines 210-222:
```cpp
// OLD (now deleted):
int ce = 0;
if (!config_.level(2).scans.empty())
{
  activation = config_.level(2).scans[0].activation;
  ce = config_.level(2).scans[0].collision_energy;
}
if (activation == "HCD" && ce <= 0)
{
  ce = (hcd > 0) ? hcd : 29;
}
```

The new factory at Task 4 Step 3 uses `scan_config.collision_energy` directly. Verify this is the case. No action needed if Task 4 was implemented correctly.

- [ ] **Step 2: Verify caller CE logic in processScan**

The MS2 building loop in processScan (from Task 4 Step 8) should now read:
```cpp
ScanConfig ms2_config = config_.level(2).scans[0];
if (config_.targeting().use_idscore)
  ms2_config.collision_energy = sel_hcds[i];
// Non-IDScore: ms2_config.collision_energy is already set from config
```

Three CE determination paths:
- **IDScore enabled, hcd_energy == -1**: `sel_hcds[i]` contains per-precursor dynamic HCD from `PeakGroup::getBestIDScoreHCD()`
- **IDScore enabled, hcd_energy set**: `sel_hcds[i]` contains the fixed developer value
- **IDScore disabled**: `ms2_config.collision_energy` stays as the config value (e.g. 29 from JSON)

Verify this matches the actual code. No changes needed — this was implemented in Task 4 Step 8.

- [ ] **Step 3: Grep for magic number 29**

Search for hardcoded `29` in ScanCommandQueue.cpp:
```bash
grep -n "29" OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
```

Verify no `= 29` or `: 29` fallback exists. The value `29` should only appear in test config JSON strings and in `cmd.hcd_energy = scan_config.collision_energy` (where it comes from config).

- [ ] **Step 4: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All PASS. This task is verification-only since Task 4 already removed the fallback.

- [ ] **Step 5: Commit (only if any fixes were needed)**

```bash
cd OpenMS && git add -A && git commit -m "Verify CE determination: no fallback chain, no magic number 29"
```

---

### Task 6: Reorder Exploration Before Final MS2

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:519-555`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Write a test that verifies exploration runs INSTEAD of regular MS2**

In `FLASHIda_exploration_test.cpp`, add a new section that:
1. Creates a FLASHIda instance with exploration enabled at MS2
2. Feeds MS1 data that produces precursors
3. Verifies the queue contains ONLY exploration variant commands (priority 0, 'E' prefix in description), NOT regular MS2 commands (priority 1, 'R' prefix)

```cpp
START_SECTION(([EXTRA] Exploration replaces regular MS2 commands))
{
  // Use config with MS2 exploration enabled, ce_min=20, ce_max=40, ce_step=10 => 3 variants per precursor
  FLASHIda* ida = new FLASHIda(const_cast<char*>(config_exploration));

  // Feed MS1 data to trigger precursor selection
  // (use existing test helper pattern to push MS1 spectra until precursors are selected)
  // ... (adapter-specific — depends on existing test data patterns)

  // Check queue: should have exploration variants (priority 0) but NO regular MS2 (priority 1)
  TEST_EQUAL(ida->getQueueSizeForTest(0) > 0, true)  // exploration variants at priority 0
  TEST_EQUAL(ida->getQueueSizeForTest(1), 0)          // NO regular MS2 at priority 1

  // Dequeue and verify descriptions start with 'E' (exploration), not 'R' (regular)
  ScanCommand cmd{};
  int result = ida->getNextScanCommand(cmd);
  TEST_EQUAL(result, 1)
  std::string desc(cmd.scan_description);
  TEST_EQUAL(desc.find('E') != std::string::npos, true)  // exploration variant

  delete ida;
}
END_SECTION
```

The exact test data setup depends on existing test helper patterns in the exploration test file. Adapt to match.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenMS/build && ctest -R FLASHIda_exploration_test -VV`
Expected: FAIL — currently exploration runs in ADDITION to regular MS2.

- [ ] **Step 3: Restructure MS1 path in processScan()**

In `FLASHIda.cpp`, replace the MS2 building loop + exploration initiation (approximately lines 519-555) with the exclusive branching structure:

```cpp
    int commands_pushed = 0;
    std::vector<ScanCommand> ms2_commands;

    if (config_.hasExploration(2))
    {
      // Exploration path: initiate CE sweep variants INSTEAD of regular MS2
      for (int i = 0; i < n; i++)
      {
        auto cmds = exploration_.initiate(2, selected[i], sel_charges[i], parent_cv, queue_);
        for (auto& c : cmds)
        {
          queue_.push(c);
          ms2_commands.push_back(c);
          commands_pushed++;
        }
      }
    }
    else
    {
      // Normal path: push MS2 for each precursor, for each scan config
      for (int i = 0; i < n; i++)
      {
        for (const auto& sc : config_.level(2).scans)
        {
          ScanConfig ms2_config = sc;
          if (config_.targeting().use_idscore)
            ms2_config.collision_energy = sel_hcds[i];
          ScanCommand cmd = queue_.buildMS2(selected[i], sel_charges[i], ms2_config);
          cmd.faims_cv = parent_cv;
          queue_.push(cmd);
          ms2_commands.push_back(cmd);
          commands_pushed++;
        }
      }
    }
```

Key changes:
- Exploration and regular MS2 are mutually exclusive (`if/else`)
- Normal path iterates over ALL scan configs in `level(2).scans` (multiple primary scans supported when exploration is off)
- Exploration path uses `initiate()` which internally calls `buildMS2`

- [ ] **Step 4: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All PASS including the new test.

- [ ] **Step 5: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Reorder exploration before final MS2: exploration replaces regular MS2 commands"
```

---

### Task 7: Follow-up Scan Configs Into Feature Sections

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:123-159`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:110-114,147-150,274-283`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:84-87`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:355-423`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:724-743`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp`

- [ ] **Step 1: Add `follow_up_scan` to config structs**

In `Config.h`, add `ScanConfig follow_up_scan` to `TargetingConfig` (after line ~151, at the end of the struct):
```cpp
    ScanConfig tagging_follow_up_scan;  ///< Follow-up scan config for conditional MS2 (tagging)
```

Add `ScanConfig follow_up_scan` to `QuantConfig` (after line ~159, at the end of the struct):
```cpp
    ScanConfig follow_up_scan;  ///< Follow-up scan config for quantification
```

- [ ] **Step 2: Parse `follow_up_scan` from JSON**

In `Config.cpp`, add parsing in the tagging section (after line 114, after `max_flanking_mass_diff`):
```cpp
    if (tagging.contains("follow_up_scan"))
    {
      auto fus = tagging["follow_up_scan"];
      targeting_.tagging_follow_up_scan.analyzer = fus.value("analyzer", "Orbitrap");
      targeting_.tagging_follow_up_scan.activation = fus.value("activation", "");
      targeting_.tagging_follow_up_scan.collision_energy = fus.value("collision_energy", 0);
      targeting_.tagging_follow_up_scan.resolution = fus.value("resolution", 0);
      targeting_.tagging_follow_up_scan.agc_target = fus.value("agc_target", 0);
      targeting_.tagging_follow_up_scan.first_mass = fus.value("first_mass", 0.0);
      targeting_.tagging_follow_up_scan.last_mass = fus.value("last_mass", 0.0);
      targeting_.tagging_follow_up_scan.max_it = fus.value("max_it", 0.0);
    }
```

Add parsing in the quantification section (after line 150, after `fold_change_threshold`):
```cpp
    if (quant.contains("follow_up_scan"))
    {
      auto fus = quant["follow_up_scan"];
      quant_.follow_up_scan.analyzer = fus.value("analyzer", "Orbitrap");
      quant_.follow_up_scan.activation = fus.value("activation", "");
      quant_.follow_up_scan.collision_energy = fus.value("collision_energy", 0);
      quant_.follow_up_scan.resolution = fus.value("resolution", 0);
      quant_.follow_up_scan.agc_target = fus.value("agc_target", 0);
      quant_.follow_up_scan.first_mass = fus.value("first_mass", 0.0);
      quant_.follow_up_scan.last_mass = fus.value("last_mass", 0.0);
      quant_.follow_up_scan.max_it = fus.value("max_it", 0.0);
    }
```

- [ ] **Step 3: Add validation rules to `Config::validate()`**

In `Config.cpp`, add to the `validate()` method (after the exploration validation):
```cpp
    if (targeting_.conditional_ms2_enabled && targeting_.tagging_follow_up_scan.activation.empty())
      throw std::invalid_argument(
          "Conditional MS2 is enabled but tagging.follow_up_scan is not configured.");

    if (quant_.enabled && !quant_.follow_up_scan.activation.empty())
    {
      // follow_up_scan is configured — no validation issue
    }
    // Note: quant follow-up is optional — quant can be enabled without a follow-up scan
    // (it only triggers follow-up when differential abundance is detected AND follow_up_scan is configured)
```

Wait — re-reading the spec: "If `quantification.enabled` and quant follow-up desired, `quantification.follow_up_scan` must be present." The "desired" qualifier means it's optional. Only tagging conditional MS2 requires its follow-up scan. For quant, we check at the call site.

Simplified validation (just the tagging rule):
```cpp
    if (targeting_.conditional_ms2_enabled && targeting_.tagging_follow_up_scan.activation.empty())
      throw std::invalid_argument(
          "Conditional MS2 is enabled but tagging.follow_up_scan is not configured.");
```

- [ ] **Step 4: Write validation test**

In `FLASHIda_LegacyConfig_test.cpp`, add:
```cpp
START_SECTION(([EXTRA] Config rejects conditional_ms2 without tagging follow_up_scan))
{
  const char* json = R"({
    "deconvolution": { "min_charge": 4, "max_charge": 50, "min_mass": 500, "max_mass": 50000, "tol": [10, 10] },
    "precursor_selection": {},
    "tagging": { "min_tag_length": 3 },
    "conditional_ms2": true,
    "quantification": { "enabled": false },
    "faims": {},
    "ms_settings": {
      "ms1": { "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000, "resolution": 120000, "agc_target": 800000, "max_it": 246 },
      "ms2": [{ "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }]
    },
    "scheduling": { "cycle_time": { "enabled": false }, "scan_timeout": { "enabled": false }, "agc_interval_seconds": 30 },
    "files": {},
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 3 },
      "ms2": { "selection": "intensity" }
    }
  })";
  bool threw = false;
  try { Config cfg(std::string(json)); }
  catch (const std::invalid_argument&) { threw = true; }
  TEST_EQUAL(threw, true)
  (void)threw;
}
END_SECTION
```

- [ ] **Step 5: Replace `buildFollowUpMS2` and `buildConditionalFollowUp` with single `buildFollowUp`**

In `ScanCommandQueue.h`, replace both declarations (lines 84-87):
```cpp
// Before:
    ScanCommand buildFollowUpMS2(const ScanCommand& ctx);
    ScanCommand buildConditionalFollowUp(const ScanCommand& ctx);
// After:
    ScanCommand buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix);
```

In `ScanCommandQueue.cpp`, replace both methods (lines 355-423) with:
```cpp
  ScanCommand ScanCommandQueue::buildFollowUp(const ScanCommand& ctx,
      const ScanConfig& follow_up_config, char suffix)
  {
    ScanCommand cmd = ctx;
    cmd.scan_id = nextTrackingIdInt_();
    cmd.priority = 2;

    // Apply follow-up scan settings
    std::strncpy(cmd.analyzer, follow_up_config.analyzer.c_str(), sizeof(cmd.analyzer) - 1);
    cmd.analyzer[sizeof(cmd.analyzer) - 1] = '\0';
    cmd.orbitrap_resolution = follow_up_config.resolution;
    cmd.stages[0].collision_energy = static_cast<double>(follow_up_config.collision_energy);
    std::strncpy(cmd.stages[0].activation_type, follow_up_config.activation.c_str(),
                 sizeof(cmd.stages[0].activation_type) - 1);
    cmd.stages[0].activation_type[sizeof(cmd.stages[0].activation_type) - 1] = '\0';

    std::string id_str = encode(cmd.scan_id);
    std::snprintf(cmd.scan_description, 16, "%s%c%.1f@%d",
                  id_str.c_str(), suffix, cmd.mono_mass / 1000.0, cmd.stages[0].charge_state);

    cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());

    pending_scan_map_[cmd.scan_id] = cmd;

    std::cout << "[TRACK-CREATE] id=" << id_str
              << " ms_level=2 type=followup_" << suffix
              << std::endl;

    return cmd;
  }
```

- [ ] **Step 6: Update call sites in `processMS2Path_()`**

In `FLASHIda.cpp`, update the quantification follow-up (lines 724-733):
```cpp
// Before:
    if (config_.quantification().enabled && config_.level(2).scans.size() >= 2)
    {
      if (quant_.isDifferentiallyAbundant(...))
      {
        auto followup = queue_.buildFollowUpMS2(ctx);
        queue_.push(followup);
        child_ids.push_back(ScanCommandQueue::encode(followup.scan_id));
        commands_pushed++;
      }
    }

// After:
    if (config_.quantification().enabled && !config_.quantification().follow_up_scan.activation.empty())
    {
      if (quant_.isDifferentiallyAbundant(mzs, ints, length, rt_min, 2, "ms2_quant",
              config_.quantification().reporter_mz_tol, config_.quantification().fold_change_threshold, false))
      {
        auto followup = queue_.buildFollowUp(ctx, config_.quantification().follow_up_scan, 'F');
        queue_.push(followup);
        child_ids.push_back(ScanCommandQueue::encode(followup.scan_id));
        commands_pushed++;
      }
    }
```

Update the conditional MS2 follow-up (lines 737-743):
```cpp
// Before:
    if (config_.targeting().conditional_ms2_enabled && config_.level(2).scans.size() >= 2 && tags_found)
    {
      auto cond = queue_.buildConditionalFollowUp(ctx);
      queue_.push(cond);
      child_ids.push_back(ScanCommandQueue::encode(cond.scan_id));
      commands_pushed++;
    }

// After:
    if (config_.targeting().conditional_ms2_enabled && tags_found)
    {
      auto cond = queue_.buildFollowUp(ctx, config_.targeting().tagging_follow_up_scan, 'C');
      queue_.push(cond);
      child_ids.push_back(ScanCommandQueue::encode(cond.scan_id));
      commands_pushed++;
    }
```

Note: The `scans.size() >= 2` guards are removed. For tagging, validation ensures `follow_up_scan` is configured when `conditional_ms2_enabled`. For quant, the activation-empty check serves as the guard.

- [ ] **Step 7: Update test JSON configs**

Any existing test configs that use `"ms2": [primary, secondary]` where the secondary was used for follow-ups need updating. Add `follow_up_scan` to the appropriate section.

In tests that use conditional MS2 or quant follow-ups, add the follow_up_scan to the JSON config. For example:
```json
"tagging": {
    "min_tag_length": 3,
    "conditional_ms2": true,
    "follow_up_scan": { "analyzer": "Orbitrap", "activation": "ETD", "collision_energy": 0, "resolution": 120000 }
},
"quantification": {
    "enabled": true,
    "follow_up_scan": { "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 45, "resolution": 120000 }
}
```

Search all test files for `"conditional_ms2": true` and `"quantification": { "enabled": true` to find configs that need updating.

- [ ] **Step 8: Run all FLASH tests**

Run: `cd OpenMS/build && ctest -R FLASH -VV`
Expected: All PASS.

- [ ] **Step 9: Commit**

```bash
cd OpenMS && git add -A && git commit -m "Move follow-up scan configs into tagging/quantification sections"
```

---

## Post-Implementation

After all 7 tasks are committed:

1. Run the full FLASH test suite one final time: `cd OpenMS/build && ctest -R FLASH -VV`
2. Push to `flashida-v9-bridge` for CI validation (wait for build-dlls workflow)
3. Update submodule pointer in parent repo

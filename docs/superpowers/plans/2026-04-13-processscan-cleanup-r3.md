# processScan Cleanup Round 3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Twelve fixes and improvements to scan priority ordering, MS3 pipeline correctness, exploration config/observability, and zero-CE baseline scoring.

**Architecture:** Changes span C++ (OpenMS, `flashida-v9-bridge` branch) and C# (FlashIDA, `phase-11` branch). All C++ changes ship in a single DLL build push. C# changes are independent serialization plumbing. Five phases: priority restructuring → MS3 pipeline → exploration config → observability → zero-CE baseline.

**Tech Stack:** C++20 / CMake (OpenMS), C# / .NET 4.8 (FlashIDA), OpenMS ClassTest framework, NUnit

**Key constraint:** C++ cannot be built locally (`cmake --build` is CI-only). All C++ test verification happens after pushing to `flashida-v9-bridge`. Code changes are validated by inspection during development; CI confirms correctness.

**Spec:** `docs/superpowers/specs/2026-04-13-processscan-cleanup-r3-design.md`

---

## File Map

### C++ (OpenMS, `flashida-v9-bridge`)

| File | Responsibility | Tasks |
|------|---------------|-------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` | Scan builder declarations | 3, 6 |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` | Scan builder implementations | 3, 6 |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.h` | Orchestrator declarations | 4, 9 |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp` | processScan, getNextScanCommand, logging | 3, 4, 7, 8, 9 |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h` | Exploration structs + declarations | 5, 7, 8, 9, 12 |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` | Exploration implementation | 3, 5, 7, 8, 9, 11, 12 |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` | MSLevelConfig struct | 11 |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` | Config parsing + defaults | 11 |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h` | Accessor for full deconvolved MS1 | 4 |

### C# (FlashIDA, `phase-11`)

| File | Responsibility | Tasks |
|------|---------------|-------|
| `FlashIDA/src/Flash/MethodConfig.cs` | Config model + bridge classes | 1, 2, 10, 11 |
| `FlashIDA/src/Flash/MethodParameters.cs` | JSON serialization to C++ | 1, 2, 10, 11 |

### Test Files

| File | Tasks |
|------|-------|
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` | 3, 4, 5, 6, 7, 8 |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | 3, 9, 11, 12 |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp` | 3 |

---

## Phase 1: Priority Restructuring

### Task 3: Restructure Scan Priority Assignments

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:73,77,87`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:174`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp:679,689,772-788,805-837`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:106`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp`

- [ ] **Step 1: Change buildMS2 default priority from 1 to 2**

In `ScanCommandQueue.h:73`, change default parameter:

```cpp
// Before:
ScanCommand buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority = 1);

// After:
ScanCommand buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority = 2);
```

The `.cpp` file at line 174 has the default in the definition too — change it there:

```cpp
// Before:
ScanCommand ScanCommandQueue::buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority = 1)

// After:
ScanCommand ScanCommandQueue::buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority)
```

Note: Remove the default from the `.cpp` definition (it's already in the header). MSVC allows defaults in both but Clang warns.

- [ ] **Step 2: Change buildMS3 default priority from 3 to 1**

In `ScanCommandQueue.h:77`:

```cpp
// Before:
ScanCommand buildMS3(const ScanCommand& ms2_ctx, double frag_mz, int frag_charge, double iso_width,
                     char ion_type = '\0', int frag_index = 0, int priority = 3);

// After:
ScanCommand buildMS3(const ScanCommand& ms2_ctx, double frag_mz, int frag_charge, double iso_width,
                     char ion_type = '\0', int frag_index = 0, int priority = 1);
```

- [ ] **Step 3: Change buildFollowUp default priority from 2 to 0**

In `ScanCommandQueue.h:87`:

```cpp
// Before:
ScanCommand buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix, int priority = 2);

// After:
ScanCommand buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix, int priority = 0);
```

- [ ] **Step 4: Change cycle-time MS1 from immediate return to queued at priority 0**

In `FLASHIda.cpp:772-788`, replace the immediate return with a queue push + fall-through:

```cpp
// Before (lines 772-788):
    // Step 2: Cycle time -- force MS1 if too long since last survey scan
    // Suppressed while any exploration group is active
    if (config_.scheduling().cycle_time_enabled && !exploration_active_.load(std::memory_order_acquire)
        && queue_.msSinceLastMS1() > static_cast<uint64_t>(config_.scheduling().cycle_time_ms))
    {
      out = queue_.makeMS1();
      out.faims_cv = faims_cv;
      out.scan_id = queue_.nextTrackingId();
      queue_.recordMS1Time();

      std::string id_str = ScanCommandQueue::encode(out.scan_id);
      std::snprintf(out.scan_description, 16, "%sS", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=cycle_time" << std::endl;
      writeScanCommandRow_(out);
      return 1;
    }

// After:
    // Step 2: Cycle time -- force MS1 if too long since last survey scan
    // Suppressed while any exploration group is active
    if (config_.scheduling().cycle_time_enabled && !exploration_active_.load(std::memory_order_acquire)
        && queue_.msSinceLastMS1() > static_cast<uint64_t>(config_.scheduling().cycle_time_ms))
    {
      ScanCommand ms1_cmd = queue_.makeMS1();
      ms1_cmd.faims_cv = faims_cv;
      ms1_cmd.scan_id = queue_.nextTrackingId();
      ms1_cmd.priority = 0;
      queue_.recordMS1Time();

      std::string id_str = ScanCommandQueue::encode(ms1_cmd.scan_id);
      std::snprintf(ms1_cmd.scan_description, 16, "%sS", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=cycle_time" << std::endl;
      writeScanCommandRow_(ms1_cmd);
      queue_.push(ms1_cmd);
      // Fall through to Step 3 (dequeue) instead of returning immediately
    }
```

- [ ] **Step 5: Change idle-cycle MS1 priority from 0 to 3**

In `FLASHIda.cpp:824`, change the priority override:

```cpp
// Before (line 824):
      ms1_cmd.priority = 0;

// After:
      ms1_cmd.priority = 3;
```

Also update the comment at line 820:

```cpp
// Before:
      // 5b: MS1 -- override priority to 0 (makeMS1 defaults to 3)

// After:
      // 5b: MS1 -- use default priority 3 (survey scan, lowest priority)
```

- [ ] **Step 6: Change exploration variant priority from hardcoded 0 to level-based**

In `Exploration.cpp:106`, change the priority passed to `buildMS2`:

```cpp
// Before (line 106):
      ScanCommand cmd = queue.buildMS2(pg, charge, variant_config, 0);

// After:
      int expl_priority = (msn_level >= 3) ? 1 : 2;  // MS3 variants = p1, MS2 variants = p2
      ScanCommand cmd = queue.buildMS2(pg, charge, variant_config, expl_priority);
```

- [ ] **Step 7: Update priority assertions in FLASHIda_ProcessScan_test.cpp**

Update every priority assertion to match the new scheme. Key changes (file: `FLASHIda_ProcessScan_test.cpp`):

| Line | Old assertion | New assertion | Reason |
|------|--------------|---------------|--------|
| 730 | `TEST_EQUAL(cmd.priority, 1)` | `TEST_EQUAL(cmd.priority, 2)` | Standard MS2: 1→2 |
| 854 | `TEST_EQUAL(cmd.priority, 1)` | `TEST_EQUAL(cmd.priority, 2)` | MS2 before processing |
| 869 | `!= 1` drain check | `!= 2` drain check | Drain MS2 queue (now p2) |
| 872 | `TEST_EQUAL(cmd.priority, 2)` | `TEST_EQUAL(cmd.priority, 0)` | Follow-up: 2→0 |
| 919 | `TEST_EQUAL(cmd.priority, 3)` | `TEST_EQUAL(cmd.priority, 1)` | MS3: 3→1 |
| 1126 | `!= 1` drain check | `!= 2` drain check | Drain MS2 |
| 1131 | `TEST_EQUAL(cmd.priority, 2)` | `TEST_EQUAL(cmd.priority, 0)` | Quant follow-up: 2→0 |
| 1191 | `TEST_EQUAL(cmd.priority, 3)` | Check queued behavior | Cycle-time MS1 now queued at p0 |
| 1277 | `TEST_EQUAL(cmd.priority, 1)` | `TEST_EQUAL(cmd.priority, 2)` | MS2 in tag targeting |
| 1293 | `!= 1` drain check | `!= 2` drain check | Drain MS2 |
| 1295 | `TEST_EQUAL(cmd.priority, 2)` | `TEST_EQUAL(cmd.priority, 0)` | Tag follow-up: 2→0 |
| 1358 | `priority, 1` push | `priority, 2` push | MS2 push |
| 1370 | `TEST_EQUAL(cmd.priority, 1)` | `TEST_EQUAL(cmd.priority, 2)` | MS2 dequeue |
| 1378 | `TEST_EQUAL(cmd.priority, 0)` | `TEST_EQUAL(cmd.priority, 3)` | Idle MS1: 0→3 |
| 1383 | `priority, 1` push | `priority, 2` push | MS2 push |
| 1394 | `TEST_EQUAL(cmd.priority, 0)` | `TEST_EQUAL(cmd.priority, 3)` | Idle MS1: 0→3 |
| 1402 | `TEST_EQUAL(cmd.priority, 1)` | `TEST_EQUAL(cmd.priority, 2)` | MS2 dequeue |

For the cycle-time test at line 1191: the test currently checks `cmd.priority == 3` after an immediate return. With the new behavior (queued at p0), the test logic needs restructuring — the cycle-time MS1 is now dequeued rather than immediately returned. Update the test to call `getNextScanCommand` a second time and verify the dequeued MS1 has `priority == 0`.

- [ ] **Step 8: Update priority assertions in FLASHIda_exploration_test.cpp**

In `FLASHIda_exploration_test.cpp`:

| Line | Old assertion | New assertion | Reason |
|------|--------------|---------------|--------|
| 707 | `TEST_EQUAL(cmd.priority, 0)` | `TEST_EQUAL(cmd.priority, 2)` | MS2 exploration variant: 0→2 |
| 758 | `TEST_EQUAL(cmd.priority, 0)` | Depends on test intent | Cycle-time suppression test — verify behavior is still correct |

- [ ] **Step 9: Verify FLASHIdaQueueTracking_test.cpp**

The priority ordering test at lines 163-194 tests generic queue behavior (push at p3/p1/p2, dequeue order 1/2/3). This is queue-level logic and doesn't change. The AGC test at line 247 uses explicit `priority = 1` — check if this needs updating to `priority = 2` depending on context.

- [ ] **Step 10: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp \
        src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp
git commit -m "Restructure scan priority assignments: MS2=2, MS3=1, follow-ups=0, queue cycle-time MS1"
```

---

## Phase 2: MS3 Pipeline Fix

### Task 5: Dispatch `initiateNextLevel` to Correct Builder by Target Level

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:118`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:270-366`

- [ ] **Step 1: Add `ms_ctx` parameter to `initiateNextLevel` declaration**

In `Exploration.h:118`:

```cpp
// Before:
    std::vector<ScanCommand> initiateNextLevel(int msn_level, const DeconvolvedSpectrum& result,
                                               double faims_cv, ScanCommandQueue& queue);

// After:
    std::vector<ScanCommand> initiateNextLevel(int msn_level, const DeconvolvedSpectrum& result,
                                               double faims_cv, ScanCommandQueue& queue,
                                               const ScanCommand* ms_ctx = nullptr);
```

- [ ] **Step 2: Branch on `next_level` in the direct-build path**

In `Exploration.cpp`, replace the direct command-building block (lines 339-361) with a level-aware dispatch:

```cpp
    else
    {
      // Direct command building for each fragment target
      for (int ti = 0; ti < num_targets; ++ti)
      {
        PeakGroup frag_pg(std::abs(charges[ti]), std::abs(charges[ti]), true);
        frag_pg.setMonoisotopicMass(masses[ti]);
        FLASHHelperClasses::LogMzPeak lp;
        lp.mz = (wstarts[ti] + wends[ti]) / 2.0;
        lp.abs_charge = std::abs(charges[ti]);
        frag_pg.push_back(lp);

        ScanCommand cmd;
        if (next_level >= 3 && ms_ctx != nullptr)
        {
          // MS3+: use buildMS3 for proper two-stage command
          cmd = queue.buildMS3(*ms_ctx, lp.mz, std::abs(charges[ti]),
                               next_scan_config.first_mass > 0 ? (wends[ti] - wstarts[ti]) : 2.0,
                               ion_types[ti], frag_indices[ti], 1);  // priority 1 for MS3
          cmd.faims_cv = faims_cv;
        }
        else
        {
          // MS2: use buildMS2
          cmd = queue.buildMS2(frag_pg, std::abs(charges[ti]), next_scan_config);
          cmd.faims_cv = faims_cv;
        }

        std::string id_str = ScanCommandQueue::encode(cmd.scan_id);
        std::cout << "[TRACK-CREATE] id=" << id_str
                  << " ms_level=" << next_level << " type=next_level"
                  << std::endl;

        commands.push_back(cmd);
      }
    }
```

- [ ] **Step 3: Update `initiateNextLevel` signature in private declaration**

In `Exploration.cpp`, update the function signature at line 270:

```cpp
// Before:
  std::vector<ScanCommand> Exploration::initiateNextLevel(int msn_level,
      const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue)

// After:
  std::vector<ScanCommand> Exploration::initiateNextLevel(int msn_level,
      const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue,
      const ScanCommand* ms_ctx)
```

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Dispatch initiateNextLevel to buildMS3 for level >= 3"
```

---

### Task 6: Fix `buildMS3()` CE and Activation to Use Config

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:76-77`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:249-279`

- [ ] **Step 1: Add `ms3_config` parameter to `buildMS3` declaration**

In `ScanCommandQueue.h:76-77`:

```cpp
// Before:
    ScanCommand buildMS3(const ScanCommand& ms2_ctx, double frag_mz, int frag_charge, double iso_width,
                         char ion_type = '\0', int frag_index = 0, int priority = 1);

// After:
    ScanCommand buildMS3(const ScanCommand& ms2_ctx, const ScanConfig& ms3_config,
                         double frag_mz, int frag_charge, double iso_width,
                         char ion_type = '\0', int frag_index = 0, int priority = 1);
```

- [ ] **Step 2: Update `buildMS3` implementation to read CE/activation from config**

In `ScanCommandQueue.cpp`, update the signature and the stage 1 assignments (lines 249-279):

```cpp
  ScanCommand ScanCommandQueue::buildMS3(const ScanCommand& ms2_ctx, const ScanConfig& ms3_config,
                                          double frag_mz, int frag_charge, double iso_width,
                                          char ion_type, int frag_index, int priority)
  {
    // ... (lines 252-276 unchanged) ...

    // Stage 1: Fragment target — use ms3_config instead of inheriting from stage 0
    cmd.stages[1].precursor_mz = frag_mz;
    cmd.stages[1].isolation_width = iso_width;
    cmd.stages[1].charge_state = frag_charge;
    cmd.stages[1].collision_energy = static_cast<double>(ms3_config.collision_energy);
    std::strncpy(cmd.stages[1].activation_type, ms3_config.activation.c_str(),
                 sizeof(cmd.stages[1].activation_type) - 1);
    cmd.stages[1].activation_type[sizeof(cmd.stages[1].activation_type) - 1] = '\0';

    // ... (rest unchanged) ...
```

- [ ] **Step 3: Update `buildMS3` call site in `initiateNextLevel` (task 5)**

In the code written in Task 5 Step 2, the `buildMS3` call needs the new `ms3_config` parameter. Update:

```cpp
          cmd = queue.buildMS3(*ms_ctx, next_scan_config, lp.mz, std::abs(charges[ti]),
                               wends[ti] - wstarts[ti],
                               ion_types[ti], frag_indices[ti], 1);
```

Here `next_scan_config` is `config_.level(next_level).scans[0]` (already computed at line 321), which holds the MS3 CE and activation from the config.

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "buildMS3: read CE and activation from levels_[3] config instead of hardcoding"
```

---

### Task 7: Pass MS2 ScanCommand Context to `initiateNextLevel`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:74-90,102-103`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:59-126,257-259`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp:698`

- [ ] **Step 1: Add `originating_cmd` field to `ExplorationGroup`**

In `Exploration.h`, add to the `ExplorationGroup` struct (after line 89):

```cpp
    struct ExplorationGroup
    {
      int group_id = 0;
      int msn_level = 2;
      ExplorationMetric exploration_metric = ExplorationMetric::MassCount;
      std::string parent_tracking_id;
      double precursor_mz = 0.0;
      double precursor_mass = 0.0;
      int precursor_charge = 0;
      PeakGroup precursor_pg;
      double isolation_width = 0.0;
      double faims_cv = 0.0;
      uint64_t start_ms = 0;
      std::vector<ExplorationVariant> variants;
      int winner_index = -1;
      bool complete = false;
      ScanCommand originating_cmd{};  // MS2 context for MS3 path (task 7)
    };
```

- [ ] **Step 2: Add `ms_ctx` parameter to `initiate()` and capture it**

In `Exploration.h:102-103`, update the `initiate()` declaration:

```cpp
// Before:
    std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,
                                      double faims_cv, ScanCommandQueue& queue);

// After:
    std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,
                                      double faims_cv, ScanCommandQueue& queue,
                                      const ScanCommand* ms_ctx = nullptr);
```

In `Exploration.cpp:59-60`, update signature and capture:

```cpp
  std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,
      double faims_cv, ScanCommandQueue& queue, const ScanCommand* ms_ctx)
  {
    // ... (existing code through line 89) ...

    // Capture originating MS2 command for MS3 path
    if (ms_ctx != nullptr)
      group.originating_cmd = *ms_ctx;

    // ... (rest of function unchanged) ...
```

Insert the `if (ms_ctx)` block right after `group.start_ms` assignment (line 89), before the ScanConfig setup at line 91.

- [ ] **Step 3: Pass context at the `processScan()` call site**

In `FLASHIda.cpp:698`:

```cpp
// Before:
        auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_);

// After:
        auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);
```

- [ ] **Step 4: Pass context at the `feedResultImpl_()` call site**

In `Exploration.cpp:257-258`:

```cpp
// Before:
      auto next_cmds = initiateNextLevel(group.msn_level,
          group.variants[best_idx].result, group.faims_cv, queue);

// After:
      auto next_cmds = initiateNextLevel(group.msn_level,
          group.variants[best_idx].result, group.faims_cv, queue, &group.originating_cmd);
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp
git commit -m "Pass MS2 ScanCommand context to initiateNextLevel for proper MS3 construction"
```

---

### Task 1: Serialize MS3 Config to C++ JSON (C#)

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:430-434`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:169-187`

- [ ] **Step 1: Add `ms3` property to `JsonMsSettingsConfig`**

In `MethodConfig.cs:430-434`:

```csharp
// Before:
    public class JsonMsSettingsConfig
    {
        public JsonMs1Config ms1 { get; set; }
        public JsonMs2Config[] ms2 { get; set; }
    }

// After:
    public class JsonMsSettingsConfig
    {
        public JsonMs1Config ms1 { get; set; }
        public JsonMs2Config[] ms2 { get; set; }
        public JsonMs2Config[] ms3 { get; set; }
    }
```

- [ ] **Step 2: Serialize `ms3` array in `ToCppJson()`**

In `MethodParameters.cs`, after the `ms2` array (line 186), add `ms3`:

```csharp
                ms_settings = new JsonMsSettingsConfig
                {
                    ms1 = new JsonMs1Config
                    {
                        analyzer = c.MsSettings.MS1.Analyzer ?? "",
                        first_mass = c.MsSettings.MS1.FirstMass,
                        last_mass = c.MsSettings.MS1.LastMass,
                        resolution = c.MsSettings.MS1.OrbitrapResolution,
                        agc_target = c.MsSettings.MS1.AGCTarget,
                        max_it = c.MsSettings.MS1.MaxIT
                    },
                    ms2 = ms2List.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution
                    }).ToArray(),
                    ms3 = c.MsSettings.MS3.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution
                    }).ToArray()
                },
```

Note: `c.MsSettings.MS3` is `List<MS3Parameters>` (MethodConfig.cs:178-179). `MS3Parameters` shares the same properties as `MS2Parameters` (Analyzer, Activation, CollisionEnergy, OrbitrapResolution), so the `JsonMs2Config` mapping is identical.

- [ ] **Step 3: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "Serialize ms3 config to C++ JSON (ms_settings.ms3 array)"
```

---

## Phase 3: Exploration Config

### Task 10: Expose Exploration `overrides` in C# Config (C#)

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:231-252,464-471`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:262-292`

- [ ] **Step 1: Add `Overrides` to `ExplorationBlockConfig`**

In `MethodConfig.cs`, add after line 252 (inside the class):

```csharp
    [JsonKey("exploration")]
    public class ExplorationBlockConfig
    {
        [JsonKey("metric")]
        [Description("Exploration metric: none, qscore, or intensity")]
        public string Metric { get; set; } = "none";

        [JsonKey("ce_min")]
        [Description("Minimum collision energy for exploration sweep")]
        public double CEMin { get; set; } = 20;

        [JsonKey("ce_max")]
        [Description("Maximum collision energy for exploration sweep")]
        public double CEMax { get; set; } = 40;

        [JsonKey("ce_step")]
        [Description("Collision energy step size")]
        public double CEStep { get; set; } = 5;

        [JsonKey("activation")]
        [Description("Activation method for exploration (HCD or CID)")]
        public string Activation { get; set; } = "HCD";

        [JsonKey("overrides")]
        [Description("Per-field scan config overrides for exploration variants (e.g. analyzer, resolution)")]
        public Dictionary<string, string> Overrides { get; set; }
    }
```

- [ ] **Step 2: Add `overrides` to `JsonExplorationBlockConfig`**

In `MethodConfig.cs:464-471`:

```csharp
// Before:
    public class JsonExplorationBlockConfig
    {
        public string metric { get; set; }
        public double ce_min { get; set; }
        public double ce_max { get; set; }
        public double ce_step { get; set; }
        public string activation { get; set; }
    }

// After:
    public class JsonExplorationBlockConfig
    {
        public string metric { get; set; }
        public double ce_min { get; set; }
        public double ce_max { get; set; }
        public double ce_step { get; set; }
        public string activation { get; set; }
        public Dictionary<string, string> overrides { get; set; }
    }
```

- [ ] **Step 3: Serialize `overrides` in `BuildSelectionStrategy()`**

In `MethodParameters.cs`, update the MS2 and MS3 exploration block initializers (lines 272-279 and 284-291):

```csharp
            if (ss.MS2?.Exploration != null && ss.MS2.Exploration.Metric != "none")
            {
                result.ms2.exploration = new JsonExplorationBlockConfig
                {
                    metric = ss.MS2.Exploration.Metric.ToLower(),
                    ce_min = ss.MS2.Exploration.CEMin,
                    ce_max = ss.MS2.Exploration.CEMax,
                    ce_step = ss.MS2.Exploration.CEStep,
                    activation = ss.MS2.Exploration.Activation ?? "HCD",
                    overrides = ss.MS2.Exploration.Overrides
                };
            }

            if (ss.MS3?.Exploration != null && ss.MS3.Exploration.Metric != "none")
            {
                result.ms3.exploration = new JsonExplorationBlockConfig
                {
                    metric = ss.MS3.Exploration.Metric.ToLower(),
                    ce_min = ss.MS3.Exploration.CEMin,
                    ce_max = ss.MS3.Exploration.CEMax,
                    ce_step = ss.MS3.Exploration.CEStep,
                    activation = ss.MS3.Exploration.Activation ?? "CID",
                    overrides = ss.MS3.Exploration.Overrides
                };
            }
```

The `defaultExpl` initializer (line 262-265) should set `overrides = null` — `JavaScriptSerializer` omits null values:

```csharp
            var defaultExpl = new JsonExplorationBlockConfig
            {
                metric = "none", ce_min = 20, ce_max = 40, ce_step = 5, activation = "HCD",
                overrides = null
            };
```

- [ ] **Step 4: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "Expose exploration overrides in C# config serialization"
```

---

### Task 11: Remove `exploration_activation` — Use Overrides Instead

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:84-98`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:45-55,312`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:95-106`
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:231-252,464-471`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:262-292`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Remove `exploration_activation` from `MSLevelConfig`**

In `Config.h`, remove line 94:

```cpp
// Before (lines 84-98):
  struct OPENMS_DLLAPI MSLevelConfig
  {
    std::vector<ScanConfig> scans;
    SelectionMetric selection = SelectionMetric::Intensity;
    int max_targets = 10;
    ExplorationMetric exploration = ExplorationMetric::None;
    double ce_min = 20.0;
    double ce_max = 40.0;
    double ce_step = 5.0;
    std::string exploration_activation = "HCD";   // <-- REMOVE THIS LINE
    std::unordered_map<std::string, std::string> overrides;
    double tolerance_ppm = 10.0;
    double remaining_precursor_target = 0.1;
  };

// After:
  struct OPENMS_DLLAPI MSLevelConfig
  {
    std::vector<ScanConfig> scans;
    SelectionMetric selection = SelectionMetric::Intensity;
    int max_targets = 10;
    ExplorationMetric exploration = ExplorationMetric::None;
    double ce_min = 20.0;
    double ce_max = 40.0;
    double ce_step = 5.0;
    std::unordered_map<std::string, std::string> overrides;
    double tolerance_ppm = 10.0;
    double remaining_precursor_target = 0.1;
  };
```

- [ ] **Step 2: Update `default_level_` initializer**

In `Config.cpp:45-55`, remove the `"HCD"` entry:

```cpp
// Before:
  const MSLevelConfig Config::default_level_ = {
    {},                           // scans (empty)
    SelectionMetric::None,        // selection
    10,                           // max_targets
    ExplorationMetric::None,      // exploration
    20.0, 40.0, 5.0,              // ce_min, ce_max, ce_step
    "HCD",                        // exploration_activation  <-- REMOVE
    {},                           // overrides
    10.0,                         // tolerance_ppm
    0.1                           // remaining_precursor_target
  };

// After:
  const MSLevelConfig Config::default_level_ = {
    {},                           // scans (empty)
    SelectionMetric::None,        // selection
    10,                           // max_targets
    ExplorationMetric::None,      // exploration
    20.0, 40.0, 5.0,              // ce_min, ce_max, ce_step
    {},                           // overrides
    10.0,                         // tolerance_ppm
    0.1                           // remaining_precursor_target
  };
```

- [ ] **Step 3: Remove `exploration_activation` parsing**

In `Config.cpp:312`, remove the line:

```cpp
// Remove this line:
          cfg.exploration_activation = expl_obj.value("activation", std::string("HCD"));
```

- [ ] **Step 4: Update `Exploration::initiate()` to use base config activation**

In `Exploration.cpp`, replace lines 99-104 that reference `cfg.exploration_activation`:

```cpp
// Before (lines 95-106):
    for (int i = 0; i < static_cast<int>(ces.size()); ++i)
    {
      ExplorationVariant v;
      v.variant_index = i;
      v.collision_energy = ces[i];
      v.activation_type = cfg.exploration_activation;          // REMOVE

      ScanConfig variant_config = base_config;
      variant_config.collision_energy = static_cast<int>(ces[i]);
      variant_config.activation = cfg.exploration_activation;  // REMOVE

      ScanCommand cmd = queue.buildMS2(pg, charge, variant_config, expl_priority);

// After:
    for (int i = 0; i < static_cast<int>(ces.size()); ++i)
    {
      ExplorationVariant v;
      v.variant_index = i;
      v.collision_energy = ces[i];
      v.activation_type = base_config.activation;   // reads from overridden base config

      ScanConfig variant_config = base_config;
      variant_config.collision_energy = static_cast<int>(ces[i]);
      // activation already correct from base_config (possibly overridden)

      ScanCommand cmd = queue.buildMS2(pg, charge, variant_config, expl_priority);
```

- [ ] **Step 5: Remove `Activation` from C# config classes**

In `MethodConfig.cs`, remove from `ExplorationBlockConfig` (lines 250-252):

```csharp
        // REMOVE these 3 lines:
        [JsonKey("activation")]
        [Description("Activation method for exploration (HCD or CID)")]
        public string Activation { get; set; } = "HCD";
```

Remove from `JsonExplorationBlockConfig` (line 470):

```csharp
        // REMOVE this line:
        public string activation { get; set; }
```

- [ ] **Step 6: Remove `activation` from serialization**

In `MethodParameters.cs`, remove `activation` from `defaultExpl` (line 264):

```csharp
// Before:
            var defaultExpl = new JsonExplorationBlockConfig
            {
                metric = "none", ce_min = 20, ce_max = 40, ce_step = 5, activation = "HCD",
                overrides = null
            };

// After:
            var defaultExpl = new JsonExplorationBlockConfig
            {
                metric = "none", ce_min = 20, ce_max = 40, ce_step = 5,
                overrides = null
            };
```

Remove `activation = ...` from the MS2 block (line 278) and MS3 block (line 290).

- [ ] **Step 7: Update exploration test configs**

In `FLASHIda_exploration_test.cpp`, find all embedded JSON configs with `"activation": "HCD"` or `"activation": "CID"` inside exploration blocks. Remove the `"activation"` key. Where a non-default activation is needed, add `"overrides": {"activation": "CID"}` instead.

Example (from the RemainingPrecursor config at test line ~370):

```cpp
// Before:
      "exploration": {
        "metric": "remaining_precursor",
        "ce_min": 20.0,
        "ce_max": 40.0,
        "ce_step": 5.0,
        "activation": "HCD"
      }

// After:
      "exploration": {
        "metric": "remaining_precursor",
        "ce_min": 20.0,
        "ce_max": 40.0,
        "ce_step": 5.0
      }
```

If a test needs CID activation:

```cpp
      "exploration": {
        "metric": "fragment_count",
        "ce_min": 20.0,
        "ce_max": 40.0,
        "ce_step": 5.0,
        "overrides": {"activation": "CID"}
      }
```

Also remove any assertion like `TEST_STRING_EQUAL(ms2_cfg.exploration_activation, "HCD")` (around line 1020 if present).

- [ ] **Step 8: Commit (two commits — C++ and C# separately)**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Remove exploration_activation: use overrides mechanism instead"
```

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "Remove exploration activation from C# config (now uses overrides)"
```

---

### Task 2: Expose `remaining_precursor_target` to JSON Config (C#)

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs`

- [ ] **Step 1: Add property to domain model**

In `MethodConfig.cs`, add to `ExplorationBlockConfig` (after `CEStep`):

```csharp
        [JsonKey("remaining_precursor_target")]
        [Description("Target remaining precursor ratio for exploration (0.1 = 10%)")]
        public double RemainingPrecursorTarget { get; set; } = 0.1;
```

- [ ] **Step 2: Add property to bridge class**

In `MethodConfig.cs`, add to `JsonExplorationBlockConfig`:

```csharp
        public double remaining_precursor_target { get; set; }
```

- [ ] **Step 3: Serialize in `BuildSelectionStrategy()`**

In `MethodParameters.cs`, add to `defaultExpl`:

```csharp
            var defaultExpl = new JsonExplorationBlockConfig
            {
                metric = "none", ce_min = 20, ce_max = 40, ce_step = 5,
                overrides = null, remaining_precursor_target = 0.1
            };
```

Add to the MS2 and MS3 exploration blocks:

```csharp
                    remaining_precursor_target = ss.MS2.Exploration.RemainingPrecursorTarget
```

```csharp
                    remaining_precursor_target = ss.MS3.Exploration.RemainingPrecursorTarget
```

- [ ] **Step 4: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "Expose remaining_precursor_target in C# config serialization"
```

---

## Phase 4: Observability

### Task 4: Fix AllMass IDA Log Reporting

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.h:251-253`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp:213-220`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h`

- [ ] **Step 1: Add `deconvolvedMS1()` accessor to `PrecursorSelection`**

In `PrecursorSelection.h`, add after the `selectedPeakGroups()` accessors (after line 136):

```cpp
    /// Access full deconvolved MS1 spectrum (all peak groups, not just selected)
    const DeconvolvedSpectrum& deconvolvedMS1() const { return deconv_.deconvolvedMS1(); }
```

- [ ] **Step 2: Add parameter to `writeIDALogEntry_` declaration**

In `FLASHIda.h:251-253`:

```cpp
// Before:
    void writeIDALogEntry_(double rt, const std::string& tracking_id,
                           const std::vector<ScanCommand>& ms2_commands);

// After:
    void writeIDALogEntry_(double rt, const std::string& tracking_id,
                           const std::vector<ScanCommand>& ms2_commands,
                           const DeconvolvedSpectrum& all_peak_groups);
```

- [ ] **Step 3: Update `writeIDALogEntry_` implementation**

In `FLASHIda.cpp`, update the function signature and AllMass loop (lines 213-220):

```cpp
// Before:
    // AllMass line
    const auto& selected = selection_.selectedPeakGroups();
    ida_log_stream_ << "AllMass=";
    for (size_t i = 0; i < selected.size(); i++)
    {
      if (i > 0) ida_log_stream_ << " ";
      ida_log_stream_ << std::defaultfloat << selected[i].getMonoMass();
    }

// After:
    // AllMass line — all deconvolved masses, not just selected targets
    ida_log_stream_ << "AllMass=";
    for (size_t i = 0; i < all_peak_groups.size(); i++)
    {
      if (i > 0) ida_log_stream_ << " ";
      ida_log_stream_ << std::defaultfloat << all_peak_groups[i].getMonoMass();
    }
```

- [ ] **Step 4: Update call site in `processScan()`**

Find the `writeIDALogEntry_` call site in `FLASHIda.cpp` and pass the full deconvolved spectrum:

```cpp
// Before:
    writeIDALogEntry_(rt_min, id_str, ms2_commands);

// After:
    writeIDALogEntry_(rt_min, id_str, ms2_commands, selection_.deconvolvedMS1());
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp \
        src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h
git commit -m "Fix AllMass IDA log: report all deconvolved masses, not just selected targets"
```

---

### Task 8: Populate Fragment Matching Columns in results.tsv

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:118`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:270-366`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp:698-705`

- [ ] **Step 1: Define `NextLevelResult` struct**

In `Exploration.h`, add before the class declaration (or as a public nested struct):

```cpp
    /// Return type for initiateNextLevel — commands + fragment match context
    struct NextLevelResult
    {
      std::vector<ScanCommand> commands;
      std::string matched_protein;
      std::string proteoform_sequence;
      float tic_coverage = 0.0f;
      int fragment_count = 0;
    };
```

- [ ] **Step 2: Change `initiateNextLevel` return type**

In `Exploration.h:118`:

```cpp
// Before:
    std::vector<ScanCommand> initiateNextLevel(int msn_level, const DeconvolvedSpectrum& result,
                                               double faims_cv, ScanCommandQueue& queue,
                                               const ScanCommand* ms_ctx = nullptr);

// After:
    NextLevelResult initiateNextLevel(int msn_level, const DeconvolvedSpectrum& result,
                                      double faims_cv, ScanCommandQueue& queue,
                                      const ScanCommand* ms_ctx = nullptr);
```

- [ ] **Step 3: Update implementation to return `NextLevelResult`**

In `Exploration.cpp`, update the function signature and return type:

```cpp
  Exploration::NextLevelResult Exploration::initiateNextLevel(int msn_level,
      const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue,
      const ScanCommand* ms_ctx)
  {
    NextLevelResult nlr;

    int next_level = msn_level + 1;
    const auto& this_cfg = config_.level(msn_level);
    const auto& next_cfg = config_.level(next_level);
    if (this_cfg.selection == SelectionMetric::None) return nlr;

    const auto& seq = config_.targeting().protein_sequence;
    int num_targets = this_cfg.max_targets;

    // ... (existing fragment analysis code unchanged through line 318) ...

    num_targets = std::min(num_targets, found);

    // Populate fragment match metadata
    nlr.fragment_count = found;
    if (!seq.empty() && found > 0)
    {
      nlr.matched_protein = config_.targeting().protein_accession;
      nlr.proteoform_sequence = seq;

      // TIC coverage: sum matched fragment intensities / total MS2 TIC
      double matched_intensity = 0.0;
      double total_tic = 0.0;
      for (const auto& pg : result)
        total_tic += pg.getIntensity();
      for (int i = 0; i < found; ++i)
      {
        // qscores[i] is proportional to matched intensity
        matched_intensity += qscores[i];
      }
      if (total_tic > 0.0)
        nlr.tic_coverage = static_cast<float>(matched_intensity / total_tic);
    }

    // ... (existing command-building code) ...
    // Replace all `commands.push_back(cmd)` with `nlr.commands.push_back(cmd)`
    // Replace all `commands.insert(...)` with `nlr.commands.insert(...)`
    // Return `nlr` instead of `commands`

    return nlr;
  }
```

Key: every reference to the local `commands` vector becomes `nlr.commands`.

- [ ] **Step 4: Update call sites to unpack `NextLevelResult`**

In `FLASHIda.cpp:698-705`:

```cpp
// Before:
        auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);
        for (auto& c : cmds)
        {
          queue_.push(c);
          child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
          commands_pushed++;
        }

// After:
        auto nlr = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_, &ctx);
        for (auto& c : nlr.commands)
        {
          queue_.push(c);
          child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
          commands_pushed++;
        }
```

Then at the `writeScanResultRow_` call for this MS2 scan, pass the fragment fields:

```cpp
    writeScanResultRow_(id_str, rt_min, ms2_mass_count, commands_pushed,
                        child_ids, tag_count, nlr.matched_protein, nlr.proteoform_sequence,
                        enqueue_ts, nlr.tic_coverage, nlr.fragment_count);
```

In `Exploration.cpp:257-259` (`feedResultImpl_`), update the `initiateNextLevel` call:

```cpp
// Before:
      auto next_cmds = initiateNextLevel(group.msn_level,
          group.variants[best_idx].result, group.faims_cv, queue, &group.originating_cmd);
      commands.insert(commands.end(), next_cmds.begin(), next_cmds.end());

// After:
      auto nlr = initiateNextLevel(group.msn_level,
          group.variants[best_idx].result, group.faims_cv, queue, &group.originating_cmd);
      commands.insert(commands.end(), nlr.commands.begin(), nlr.commands.end());
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp
git commit -m "Populate fragment matching columns in results.tsv from initiateNextLevel"
```

---

### Task 9: Populate Exploration Metadata in results.tsv

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:164-268`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.h:258-265`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp:96-99,306-341,625-635`

- [ ] **Step 1: Define `FeedResultInfo` struct**

In `Exploration.h`, add as a public nested struct:

```cpp
    /// Return type for feedResult — commands + exploration metadata for results.tsv
    struct FeedResultInfo
    {
      std::vector<ScanCommand> commands;
      int group_id = -1;
      int variant_index = -1;
      int total_variants = 0;
      double collision_energy = 0.0;
      double score = -1.0;
      float tic_coverage = 0.0f;
      int fragment_count = 0;
      int exploration_metric = 0;
    };
```

- [ ] **Step 2: Change `feedResult` and `feedResultForTest` return types**

In `Exploration.h`:

```cpp
// Before:
    std::vector<ScanCommand> feedResult(int tracking_id,
                                        const double* mzs, const double* ints, int length,
                                        double rt, ScanCommandQueue& queue);
    std::vector<ScanCommand> feedResultForTest(int tracking_id,
                                               const DeconvolvedSpectrum& ms2_deconv,
                                               double rt, ScanCommandQueue& queue);

// After:
    FeedResultInfo feedResult(int tracking_id,
                              const double* mzs, const double* ints, int length,
                              double rt, ScanCommandQueue& queue);
    FeedResultInfo feedResultForTest(int tracking_id,
                                     const DeconvolvedSpectrum& ms2_deconv,
                                     double rt, ScanCommandQueue& queue);
```

Also update `feedResultImpl_`:

```cpp
// Before:
    std::vector<ScanCommand> feedResultImpl_(int tracking_id, const DeconvolvedSpectrum& ms2_deconv,
                                             const double* mzs, const double* ints, int length,
                                             double rt, ScanCommandQueue& queue);

// After:
    FeedResultInfo feedResultImpl_(int tracking_id, const DeconvolvedSpectrum& ms2_deconv,
                                   const double* mzs, const double* ints, int length,
                                   double rt, ScanCommandQueue& queue);
```

- [ ] **Step 3: Update `feedResultImpl_` to populate `FeedResultInfo`**

In `Exploration.cpp`, change the return type and populate metadata before erasing the group:

```cpp
  Exploration::FeedResultInfo Exploration::feedResultImpl_(int tracking_id,
      const DeconvolvedSpectrum& ms2_deconv,
      const double* mzs, const double* ints, int length,
      double rt, ScanCommandQueue& queue)
  {
    FeedResultInfo info;

    // ... (existing lookup code, lines 172-187, unchanged) ...
    // Replace early `return commands;` with `return info;`

    // After scoring (line 192), populate per-variant metadata:
    info.group_id = group.group_id;
    info.variant_index = variant_index;
    info.total_variants = static_cast<int>(group.variants.size());
    info.collision_energy = v.collision_energy;
    info.score = v.score;
    info.tic_coverage = v.tic_coverage;
    info.fragment_count = v.fragment_count;
    info.exploration_metric = static_cast<int>(group.exploration_metric);

    // ... (existing winner selection + command building, lines 214-260) ...
    // Replace `commands` with `info.commands` throughout

    active_groups_.erase(git);
    return info;
  }
```

Also update `feedResult` and `feedResultForTest` wrappers to return `FeedResultInfo`.

- [ ] **Step 4: Add new columns to results.tsv header**

In `FLASHIda.cpp:96-99`:

```cpp
// Before:
        results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\trt\t"
                            << "mass_count\tcommands_pushed\tchild_ids\t"
                            << "tag_count\tmatched_protein\tproteoform_sequence\t"
                            << "tic_coverage\tfragment_count\n";

// After:
        results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\trt\t"
                            << "mass_count\tcommands_pushed\tchild_ids\t"
                            << "tag_count\tmatched_protein\tproteoform_sequence\t"
                            << "tic_coverage\tfragment_count\t"
                            << "exploration_group_id\texploration_metric\t"
                            << "variant_index\ttotal_variants\t"
                            << "collision_energy\texploration_score\n";
```

- [ ] **Step 5: Extend `writeScanResultRow_` signature and body**

In `FLASHIda.h:258-265`:

```cpp
    void writeScanResultRow_(const std::string& tracking_id, double rt,
                             int mass_count, int commands_pushed,
                             const std::vector<std::string>& child_ids,
                             int tag_count, const std::string& matched_protein,
                             const std::string& proteoform_sequence,
                             uint64_t enqueue_ts,
                             float tic_coverage = 0.0f, int fragment_count = 0,
                             int exploration_group_id = -1, int exploration_metric = 0,
                             int variant_index = -1, int total_variants = 0,
                             double collision_energy = 0.0, double exploration_score = -1.0);
```

In `FLASHIda.cpp`, add the new columns to the output (after line 338):

```cpp
                        << tic_coverage << "\t"
                        << fragment_count << "\t"
                        << exploration_group_id << "\t"
                        << exploration_metric << "\t"
                        << variant_index << "\t"
                        << total_variants << "\t"
                        << collision_energy << "\t"
                        << exploration_score << "\n";
```

- [ ] **Step 6: Update exploration call site to pass metadata**

In `FLASHIda.cpp:625-635`:

```cpp
// Before:
      if (exploration_.isExplorationVariant(tracking_id))
      {
        auto cmds = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);
        for (auto& c : cmds) queue_.push(c);

        int expl_mass_count = deconv_.hasStoredMS2() ? static_cast<int>(deconv_.storedMS2().size()) : 0;
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(cmds.size()),
                            {}, 0, "", "", 0);

        return commands_pushed;
      }

// After:
      if (exploration_.isExplorationVariant(tracking_id))
      {
        auto info = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);
        for (auto& c : info.commands) queue_.push(c);

        int expl_mass_count = deconv_.hasStoredMS2() ? static_cast<int>(deconv_.storedMS2().size()) : 0;
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(info.commands.size()),
                            {}, 0, "", "", 0,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score);

        return commands_pushed;
      }
```

- [ ] **Step 7: Update exploration test assertions**

In `FLASHIda_exploration_test.cpp`, update all `feedResult`/`feedResultForTest` calls to handle the new return type:

```cpp
// Before:
auto result_cmds = exploration.feedResult(tracking_id, mzs.data(), intensities.data(), ...);

// After:
auto info = exploration.feedResult(tracking_id, mzs.data(), intensities.data(), ...);
auto& result_cmds = info.commands;
```

Same pattern for `feedResultForTest`.

- [ ] **Step 8: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FLASHIda.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Populate exploration metadata columns in results.tsv"
```

---

## Phase 5: Zero-CE Baseline

### Task 12: Add Zero-CE Baseline Scan for RemainingPrecursor Metric

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:61-71,74-90`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:59-126,164-268,401-433`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add baseline fields to structs**

In `Exploration.h`, add to `ExplorationVariant`:

```cpp
    struct ExplorationVariant
    {
      int variant_index = -1;
      double collision_energy = 0.0;
      std::string activation_type;
      std::string tracking_id;
      double score = -1.0;
      float tic_coverage = 0.0f;
      int fragment_count = 0;
      bool received = false;
      bool is_baseline = false;           // NEW: CE=0 reference scan
      DeconvolvedSpectrum result{0};
    };
```

Add to `ExplorationGroup`:

```cpp
    struct ExplorationGroup
    {
      // ... (existing fields) ...
      ScanCommand originating_cmd{};
      double baseline_intensity = 0.0;    // NEW: isolation-window intensity from CE=0 scan
      bool has_baseline = false;           // NEW: whether baseline result has arrived
    };
```

- [ ] **Step 2: Prepend CE=0 baseline variant in `initiate()`**

In `Exploration.cpp`, after `buildCEVariants_()` (line 67), prepend CE=0 when metric is RemainingPrecursor:

```cpp
    std::vector<double> ces = buildCEVariants_(cfg.ce_min, cfg.ce_max, cfg.ce_step);
    if (ces.empty()) return commands;

    // Prepend CE=0 baseline for RemainingPrecursor metric
    bool needs_baseline = (cfg.exploration == ExplorationMetric::RemainingPrecursor);
    if (needs_baseline)
      ces.insert(ces.begin(), 0.0);
```

Then in the variant-building loop, set `is_baseline`:

```cpp
    for (int i = 0; i < static_cast<int>(ces.size()); ++i)
    {
      ExplorationVariant v;
      v.variant_index = needs_baseline && i == 0 ? -1 : (needs_baseline ? i - 1 : i);
      v.collision_energy = ces[i];
      v.is_baseline = (needs_baseline && i == 0);
      v.activation_type = base_config.activation;
      // ... (rest unchanged) ...
```

- [ ] **Step 3: Handle baseline arrival in `feedResultImpl_()`**

In `Exploration.cpp`, after scoring (around line 190), add baseline handling:

```cpp
    v.received = true;

    // Baseline handling for RemainingPrecursor
    if (v.is_baseline)
    {
      // Compute isolation-window intensity sum
      double iso_half = group.isolation_width / 2.0;
      double mz_low = group.precursor_mz - iso_half;
      double mz_high = group.precursor_mz + iso_half;
      double baseline_sum = 0.0;
      if (mzs != nullptr && ints != nullptr)
      {
        for (int i = 0; i < length; ++i)
        {
          if (mzs[i] >= mz_low && mzs[i] <= mz_high)
            baseline_sum += ints[i];
        }
      }
      group.baseline_intensity = baseline_sum;
      group.has_baseline = true;
      v.score = 0.0;  // baseline score is not meaningful
    }
```

- [ ] **Step 4: Skip baseline in winner selection**

In `feedResultImpl_`, update the winner selection loop (lines 218-227):

```cpp
// Before:
    int best_idx = 0;
    double best_score = group.variants[0].score;
    for (int i = 1; i < static_cast<int>(group.variants.size()); ++i)
    {
      if (group.variants[i].score > best_score)
      {
        best_score = group.variants[i].score;
        best_idx = i;
      }
    }

// After:
    int best_idx = -1;
    double best_score = -1.0;
    for (int i = 0; i < static_cast<int>(group.variants.size()); ++i)
    {
      if (group.variants[i].is_baseline) continue;  // skip baseline
      if (group.variants[i].score > best_score)
      {
        best_score = group.variants[i].score;
        best_idx = i;
      }
    }
    if (best_idx < 0) return info;  // all variants are baseline (shouldn't happen)
```

- [ ] **Step 5: Update `FeedResultInfo::total_variants` to exclude baseline**

In `feedResultImpl_`, when populating `info.total_variants`:

```cpp
    // total_variants excludes baseline
    int real_variant_count = 0;
    for (const auto& vr : group.variants)
      if (!vr.is_baseline) ++real_variant_count;
    info.total_variants = real_variant_count;
```

- [ ] **Step 6: Update `computeRemainingPrecursorScore_` to use baseline**

In `Exploration.cpp:401-433`:

```cpp
  double Exploration::computeRemainingPrecursorScore_(const ExplorationGroup& group,
      const double* mzs, const double* ints, int length) const
  {
    if (length <= 0 || mzs == nullptr || ints == nullptr)
      return 0.0;

    // Sum intensity within the precursor isolation window
    double iso_half = group.isolation_width / 2.0;
    double mz_low = group.precursor_mz - iso_half;
    double mz_high = group.precursor_mz + iso_half;

    double remaining_intensity = 0.0;
    for (int i = 0; i < length; ++i)
    {
      if (mzs[i] >= mz_low && mzs[i] <= mz_high)
        remaining_intensity += ints[i];
    }

    // Reference: baseline isolation-window intensity (CE=0 scan)
    double reference;
    if (group.has_baseline)
    {
      reference = group.baseline_intensity;
      if (reference <= 0.0)
        return 0.0;  // Baseline failed: ratio = 1/1, score = 0
    }
    else
    {
      // Baseline not yet received — shouldn't happen for scored variants
      return 0.0;  // ratio = 1/1, score = 0
    }

    double ratio = remaining_intensity / reference;
    double score = 1.0 - ratio;
    if (score < 0.0) score = 0.0;
    if (score > 1.0) score = 1.0;
    return score;
  }
```

- [ ] **Step 7: Update RemainingPrecursor tests**

In `FLASHIda_exploration_test.cpp`, update all 4 RemainingPrecursor test sections:

1. **remaining_precursor_config_parsed** — unchanged (config parsing doesn't change)

2. **remaining_precursor_score_no_raw_data** — now expects N+1 commands (1 baseline + N variants). Feed all variants. Verify baseline is never the winner.

3. **remaining_precursor_score_with_raw_data** — feed CE=0 variant first with precursor-window signal, then CE>0 variants. Verify scores use baseline intensity as reference.

4. **remaining_precursor_score_no_signal_in_window** — feed CE=0 variant with zero in-window signal. All subsequent variants should score 0.0 (baseline failure = ratio 1/1).

For example, update the config CE sweep count check:

```cpp
// Before (ce_min=20, ce_max=40, ce_step=5 → 5 variants):
TEST_EQUAL(cmds.size(), 5)

// After (5 CE variants + 1 baseline = 6):
TEST_EQUAL(cmds.size(), 6)
// Verify first command is baseline (CE=0)
TEST_REAL_SIMILAR(cmds[0].stages[0].collision_energy, 0.0)
```

Add a new test section for baseline failure:

```cpp
START_SECTION(remaining_precursor_baseline_failure)
{
  // Setup exploration with RemainingPrecursor metric
  // Feed CE=0 variant with mzs entirely outside isolation window → baseline_intensity = 0
  // Feed CE=25 variant with real data → score should be 0.0 (baseline failure)
  // Verify winner is still selected (best of all zeros, or first non-baseline)
}
END_SECTION
```

- [ ] **Step 8: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Add zero-CE baseline scan for RemainingPrecursor exploration metric"
```

---

## Final: Push and CI Verification

- [ ] **Step 1: Push all C++ commits to `flashida-v9-bridge`**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

Wait for the `build-dlls` workflow to complete (~40 min).

- [ ] **Step 2: Download DLL artifacts**

```bash
# Get the workflow run ID from the push hook output
gh run download <run-id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts -D /tmp/dll-artifacts
# Clean extraction directory
rm -rf /tmp/dll-clean && mkdir /tmp/dll-clean
# Extract and copy DLLs
cp /tmp/dll-artifacts/*.dll FlashIDA/dll/
```

- [ ] **Step 3: Commit DLLs and update submodule pointer**

```bash
cd FlashIDA
git add dll/
git commit -m "Update OpenMS DLLs (processScan cleanup R3)"
cd ..
git add OpenMS FlashIDA
git commit -m "Update submodules: processScan cleanup R3"
git push origin phase-11
```

- [ ] **Step 4: Verify CI passes**

Check that all test binaries pass:
- `FLASHIda_ProcessScan_test`
- `FLASHIda_exploration_test`
- `FLASHIdaQueueTracking_test`
- `FLASHIdaFAIMS_test`
- `FLASHIda_LegacyConfig_test`

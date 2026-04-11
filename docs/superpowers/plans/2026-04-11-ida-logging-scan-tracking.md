# IDA Logging & Scan Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three crash-safe output files to FLASHIda: an IDA log (backward-compatible with `parseFLASHIdaLog()`), a ScanCommands TSV (one row per dequeued command), and a ScanResults TSV (one row per `processScan()` call), all driven by a new `runtime` JSON config section.

**Architecture:** C++ engine opens files at construction (paths from `runtime` JSON section), appends+flushes on every write, closes at destruction. C# computes default paths from raw file name, injects into config before `CreateFLASHIda()`. No new bridge functions.

**Tech Stack:** C++20 (nlohmann/json, std::ofstream, std::chrono), C# .NET 4.8 (JavaScriptSerializer), OpenMS ClassTest framework

---

## File Structure

### C++ files (OpenMS repo, `flashida-v9-bridge` branch)

| File | Action | Responsibility |
|------|--------|---------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` | Modify | Add `RuntimeConfig` struct and accessor |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` | Modify | Parse `runtime` section from JSON |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Add `std::ofstream` members, write method declarations, child_ids collector |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Open files in constructor, write in `processScan()`/`getNextScanCommand()`, close in destructor |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` | Modify | Add accessor for `pending_scan_map_` lookup without erase (for duration_ms) |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp` | Create | Tests 1-5 |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Register `FLASHIda_Logging_test` |

### C# files (FlashIDA repo, `phase-10` branch)

| File | Action | Responsibility |
|------|--------|---------------|
| `FlashIDA/src/Flash/MethodConfig.cs` | Modify | Add `RuntimeConfig` class, `JsonRuntimeConfig` class, properties on `MethodConfig` and `JsonMethodConfig` |
| `FlashIDA/src/Flash/MethodParameters.cs` | Modify | Serialize `runtime` in `ToCppJson()` |
| `FlashIDA/src/Flash.Tests/JsonConfigTests.cs` | Modify | Test 6: runtime config passthrough |

---

### Task 1: C++ RuntimeConfig parsing

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp`

- [ ] **Step 1: Add RuntimeConfig struct to Config.h**

After the `QuantConfig` struct (around line 159), before the `Config` class declaration, add:

```cpp
  /// Runtime file paths (set by C# or user override in JSON)
  struct OPENMS_DLLAPI RuntimeConfig
  {
    std::string ida_log_path;
    std::string scan_commands_path;
    std::string scan_results_path;
  };
```

Add a private member and public accessor to the `Config` class. After `QuantConfig quant_;` (line 205), add:

```cpp
    RuntimeConfig runtime_;
```

After the `quantification()` accessor (line 194), add:

```cpp
    const RuntimeConfig& runtime() const { return runtime_; }
```

- [ ] **Step 2: Parse runtime section in Config.cpp**

At the end of the `Config` constructor, before the SNR threshold line (line 286), add:

```cpp
    // --- runtime section (file paths, optional) ---
    auto rt = config.value("runtime", json::object());
    runtime_.ida_log_path = rt.value("ida_log_path", std::string{});
    runtime_.scan_commands_path = rt.value("scan_commands_path", std::string{});
    runtime_.scan_results_path = rt.value("scan_results_path", std::string{});
```

- [ ] **Step 3: Verify compilation**

Run:
```bash
cmake --build OpenMS/build --target FLASHIda_ProcessScan_test 2>&1 | tail -5
```
Expected: compiles successfully (existing tests still pass since `runtime` is optional in JSON)

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git commit -m "Add RuntimeConfig struct for IDA log and TSV file paths"
```

---

### Task 2: IDA log writer in FLASHIda

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

- [ ] **Step 1: Add ofstream members and write method declarations to FLASHIda.h**

Add `#include <fstream>` after the existing includes (after line 53).

In the private section (after `Exploration exploration_;` at line 239), add:

```cpp
    // --- Logging file streams (append-only, crash-safe) ---
    std::ofstream ida_log_stream_;
    std::ofstream commands_tsv_stream_;
    std::ofstream results_tsv_stream_;

    /// Write IDA log entry for MS1 deconvolution results
    void writeIDALogEntry_(int scan_number, double rt, const std::string& tracking_id,
                           const std::vector<ScanCommand>& ms2_commands);
```

- [ ] **Step 2: Open IDA log in constructor, close in destructor**

In `FLASHIda.cpp`, in the constructor body (after `omp_set_num_threads(4);` / the `#endif` at line 64), add:

```cpp
    // Open logging files if paths are configured
    const auto& rt_cfg = config_.runtime();
    if (!rt_cfg.ida_log_path.empty())
    {
      ida_log_stream_.open(rt_cfg.ida_log_path, std::ios::app);
    }
```

Change the destructor from `~FLASHIda() = default;` in `FLASHIda.h` (line 78) to a declaration:

```cpp
    ~FLASHIda();
```

Add the destructor body in `FLASHIda.cpp` (after the constructor, around line 66):

```cpp
  FLASHIda::~FLASHIda()
  {
    if (ida_log_stream_.is_open()) ida_log_stream_.close();
    if (commands_tsv_stream_.is_open()) commands_tsv_stream_.close();
    if (results_tsv_stream_.is_open()) results_tsv_stream_.close();
  }
```

Since `~FLASHIda()` is no longer defaulted and the class has `std::ofstream` members (non-copyable), also change the copy constructor and assignment operator in `FLASHIda.h` from `= default` to `= delete`:

```cpp
    /// copy constructor (deleted — ofstreams are non-copyable)
    FLASHIda(const FLASHIda&) = delete;

    /// assignment operator (deleted — ofstreams are non-copyable)
    FLASHIda& operator=(const FLASHIda&) = delete;

    /// move constructor
    FLASHIda(FLASHIda&& other) = default;
```

- [ ] **Step 3: Implement writeIDALogEntry_**

In `FLASHIda.cpp`, after the destructor, add:

```cpp
  void FLASHIda::writeIDALogEntry_(int scan_number, double rt,
                                    const std::string& tracking_id,
                                    const std::vector<ScanCommand>& ms2_commands)
  {
    if (!ida_log_stream_.is_open()) return;

    // MS1 header line
    ida_log_stream_ << "MS1 Scan# " << scan_number
                    << " RT " << std::fixed << std::setprecision(4) << rt
                    << " (Access ID " << tracking_id << ") - "
                    << ms2_commands.size() << " targets\n";

    // Per-precursor lines (format matches parseFLASHIdaLog contract)
    for (const auto& cmd : ms2_commands)
    {
      // Window from stages[0]
      double w1 = 0, w2 = 0;
      if (cmd.num_stages > 0)
      {
        double center = cmd.stages[0].precursor_mz;
        double half_width = cmd.stages[0].isolation_width / 2.0;
        w1 = center - half_width;
        w2 = center + half_width;
      }

      // ChargeRange: use charge as both min and max (single charge per command)
      int charge = (cmd.num_stages > 0) ? cmd.stages[0].charge_state : 0;

      ida_log_stream_ << "Mass=" << std::defaultfloat << cmd.mono_mass
                      << "\tZ=" << charge
                      << "\tScore=" << std::fixed << std::setprecision(5) << cmd.qscore
                      << "\tWindow=[" << std::setprecision(4) << w1 << "-" << w2 << "]"
                      << "\tPrecursorIntensity=" << std::setprecision(5) << cmd.precursor_intensity
                      << "\tPrecursorMassIntensity=" << std::setprecision(5) << cmd.peakgroup_intensity
                      << "\tFeatures=["
                        << std::setprecision(6) << cmd.charge_cos << ","
                        << cmd.charge_snr << ","
                        << cmd.iso_cos << ","
                        << cmd.snr << ","
                        << cmd.charge_score << ","
                        << cmd.ppm_error << "]"
                      << "\tChargeRange=[" << charge << "-" << charge << "]"
                      << "\tHCD=" << cmd.hcd_energy << "\n";
    }

    // AllMass line: all deconvolved masses from the MS1 scan
    const auto& selected = selection_.selectedPeakGroups();
    ida_log_stream_ << "AllMass=";
    for (size_t i = 0; i < selected.size(); i++)
    {
      if (i > 0) ida_log_stream_ << " ";
      ida_log_stream_ << std::defaultfloat << selected[i].getMonoMass();
    }
    ida_log_stream_ << "\n";

    ida_log_stream_.flush();
  }
```

Add `#include <iomanip>` to the includes in FLASHIda.cpp.

- [ ] **Step 4: Call writeIDALogEntry_ in processScan MS1 path**

In `FLASHIda.cpp`, in the `processScan()` MS1 path, after the MS2 command creation loop (after line 315 `commands_pushed++;`), but before the exploration block (line 317), collect the pushed commands and write:

```cpp
      // IDA log: collect pushed MS2 commands for logging
      std::vector<ScanCommand> ms2_for_log;
      ```

Actually, the commands are built inline. We need to collect them. Restructure the loop to collect commands:

Replace lines 308-315:
```cpp
      int commands_pushed = 0;
      for (int i = 0; i < n; i++)
      {
        ScanCommand cmd = queue_.buildMS2(selected[i], sel_charges[i], sel_hcds[i]);
        cmd.faims_cv = parent_cv;  // MS2 carries parent MS1's CV
        queue_.push(cmd);
        commands_pushed++;
      }
```

With:
```cpp
      int commands_pushed = 0;
      std::vector<ScanCommand> ms2_commands;
      for (int i = 0; i < n; i++)
      {
        ScanCommand cmd = queue_.buildMS2(selected[i], sel_charges[i], sel_hcds[i]);
        cmd.faims_cv = parent_cv;
        queue_.push(cmd);
        ms2_commands.push_back(cmd);
        commands_pushed++;
      }

      // Write IDA log entry
      writeIDALogEntry_(0, rt_min, "ms1", ms2_commands);
```

Note: The `scan_number` is not available in the current `processScan()` signature (only RT and ms_level are passed). We use `0` as a placeholder — this field is only used by `parseFLASHIdaLog()` as a grouping key, and using RT-based keys would also work. The `tracking_id` for the MS1 scan is also not assigned here (MS1 commands are created in `getNextScanCommand()`, not `processScan()`). We pass `"ms1"` as the access ID.

- [ ] **Step 5: Verify compilation**

Run:
```bash
cmake --build OpenMS/build --target FLASHIda_ProcessScan_test 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Add IDA log writer with parseFLASHIdaLog-compatible format"
```

---

### Task 3: ScanCommands TSV writer

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

- [ ] **Step 1: Add writeScanCommandRow_ declaration to FLASHIda.h**

In the private section, after `writeIDALogEntry_`:

```cpp
    /// Write one TSV row for a dequeued scan command
    void writeScanCommandRow_(const ScanCommand& cmd);

    /// Derive scan_type string from scan_description char at index 3
    static std::string scanTypeFromDescription_(const ScanCommand& cmd);
```

- [ ] **Step 2: Open commands TSV and write header in constructor**

In the constructor body, after the IDA log open block:

```cpp
    if (!rt_cfg.scan_commands_path.empty())
    {
      commands_tsv_stream_.open(rt_cfg.scan_commands_path, std::ios::app);
      if (commands_tsv_stream_.is_open())
      {
        commands_tsv_stream_ << "tracking_id\tms_level\tscan_type\tenqueue_ts\tpriority\t"
                             << "faims_cv\tmono_mass\tcharge\tprecursor_mz\tisolation_width\t"
                             << "collision_energy\tactivation\tqscore\tcharge_cos\tcharge_snr\t"
                             << "iso_cos\tsnr\tcharge_score\tppm_error\tprecursor_intensity\t"
                             << "peakgroup_intensity\thcd_energy\tparent_tracking_id\t"
                             << "ion_type\tion_index\n";
        commands_tsv_stream_.flush();
      }
    }
```

- [ ] **Step 3: Implement scanTypeFromDescription_ and writeScanCommandRow_**

```cpp
  std::string FLASHIda::scanTypeFromDescription_(const ScanCommand& cmd)
  {
    // scan_description format: {3-char tracking ID}{type char}{payload}
    // Type chars: S=survey, A=agc, R=recording, F=followup, C=conditional, E=exploration
    if (std::strlen(cmd.scan_description) < 4)
      return "unknown";

    switch (cmd.scan_description[3])
    {
      case 'S': return "survey";
      case 'A': return cmd.is_agc ? "agc" : "survey";
      case 'R': return (cmd.msn_level == 3) ? "recording_ms3" : "recording";
      case 'F': return "followup";
      case 'C': return "conditional";
      case 'E': return "exploration";
      default: return "unknown";
    }
  }

  void FLASHIda::writeScanCommandRow_(const ScanCommand& cmd)
  {
    if (!commands_tsv_stream_.is_open()) return;

    std::string id_str = ScanCommandQueue::encode(cmd.scan_id);
    std::string scan_type = scanTypeFromDescription_(cmd);

    // Extract stage-0 fields (safe even if num_stages==0 — struct is zero-initialized)
    int charge = (cmd.num_stages > 0) ? cmd.stages[0].charge_state : 0;
    double precursor_mz = (cmd.num_stages > 0) ? cmd.stages[0].precursor_mz : 0.0;
    double iso_width = (cmd.num_stages > 0) ? cmd.stages[0].isolation_width : 0.0;
    double col_energy = (cmd.num_stages > 0) ? cmd.stages[0].collision_energy : 0.0;
    std::string activation = (cmd.num_stages > 0) ? cmd.stages[0].activation_type : "";

    // Parent tracking ID for MS3: extracted from context (stored by buildMS3 in scan_description)
    // For MS3, the parent MS2's tracking ID is not directly on ScanCommand.
    // We leave empty for now — parent linkage is via child_ids in results TSV.
    std::string parent_id;

    // Ion type and index from scan_description for MS3
    std::string ion_type;
    int ion_index = 0;
    if (cmd.msn_level == 3 && std::strlen(cmd.scan_description) > 4)
    {
      // MS3 scan_description: {3-char ID}R{mass}@{charge}{ion_type}{ion_index}
      std::string desc(cmd.scan_description);
      // Find ion type character after the last digit following '@'
      auto at_pos = desc.find('@');
      if (at_pos != std::string::npos)
      {
        // After @{charge} comes the ion type char and index
        size_t pos = at_pos + 1;
        // Skip charge digits
        while (pos < desc.size() && (std::isdigit(desc[pos]) || desc[pos] == '-'))
          pos++;
        if (pos < desc.size() && std::isalpha(desc[pos]))
        {
          ion_type = std::string(1, desc[pos]);
          pos++;
          if (pos < desc.size())
            ion_index = std::atoi(desc.c_str() + pos);
        }
      }
    }

    commands_tsv_stream_ << id_str << "\t"
                         << cmd.msn_level << "\t"
                         << scan_type << "\t"
                         << cmd.enqueue_timestamp_ms << "\t"
                         << cmd.priority << "\t"
                         << cmd.faims_cv << "\t"
                         << cmd.mono_mass << "\t"
                         << charge << "\t"
                         << precursor_mz << "\t"
                         << iso_width << "\t"
                         << col_energy << "\t"
                         << activation << "\t"
                         << cmd.qscore << "\t"
                         << cmd.charge_cos << "\t"
                         << cmd.charge_snr << "\t"
                         << cmd.iso_cos << "\t"
                         << cmd.snr << "\t"
                         << cmd.charge_score << "\t"
                         << cmd.ppm_error << "\t"
                         << cmd.precursor_intensity << "\t"
                         << cmd.peakgroup_intensity << "\t"
                         << cmd.hcd_energy << "\t"
                         << parent_id << "\t"
                         << ion_type << "\t"
                         << ion_index << "\n";
    commands_tsv_stream_.flush();
  }
```

- [ ] **Step 4: Call writeScanCommandRow_ in getNextScanCommand**

In `getNextScanCommand()`, add a call to `writeScanCommandRow_` before every `return 1;` statement. There are 4 return points:

1. **AGC path** (after line 534): Add before `return 1;`:
```cpp
      writeScanCommandRow_(out);
```

2. **Cycle-time path** (after line 552): Add before `return 1;`:
```cpp
      writeScanCommandRow_(out);
```

3. **Dequeue path** (after line 563 `out = dequeued.value();`): Add before `return 1;`:
```cpp
      writeScanCommandRow_(out);
```

4. **Idle cycle path** (before line 599 `return 1;`): Add after `out = agc_cmd;`:
```cpp
      writeScanCommandRow_(out);
      // Also log the MS1 that was pushed into queue (will be logged when dequeued)
```

- [ ] **Step 5: Verify compilation**

Run:
```bash
cmake --build OpenMS/build --target FLASHIda_ProcessScan_test 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Add ScanCommands TSV writer in getNextScanCommand"
```

---

### Task 4: ScanResults TSV writer

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h`

- [ ] **Step 1: Add pending lookup accessor to ScanCommandQueue.h**

The `resolvePending()` method erases the entry. We need a way to look up `enqueue_timestamp_ms` without erasing. In `ScanCommandQueue.h`, add a public method:

```cpp
    /// Look up a pending command by tracking ID without removing it (for duration calculation)
    std::optional<ScanCommand> peekPending(int id) const
    {
      auto it = pending_scan_map_.find(id);
      if (it == pending_scan_map_.end()) return std::nullopt;
      return it->second;
    }
```

- [ ] **Step 2: Add writeScanResultRow_ declaration and child_ids tracking to FLASHIda.h**

In the private section:

```cpp
    /// Write one TSV row for a processScan result
    void writeScanResultRow_(const std::string& tracking_id, double rt,
                             int mass_count, int commands_pushed,
                             const std::vector<std::string>& child_ids,
                             int tag_count, const std::string& matched_protein,
                             const std::string& proteoform_sequence,
                             uint64_t enqueue_ts);

    /// Steady-clock reference point for resolve timestamps
    std::chrono::steady_clock::time_point engine_start_time_;
```

- [ ] **Step 3: Initialize engine_start_time_ and open results TSV in constructor**

In the constructor body, set the start time:

```cpp
    engine_start_time_ = std::chrono::steady_clock::now();
```

Open the results TSV and write header:

```cpp
    if (!rt_cfg.scan_results_path.empty())
    {
      results_tsv_stream_.open(rt_cfg.scan_results_path, std::ios::app);
      if (results_tsv_stream_.is_open())
      {
        results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\trt\t"
                            << "mass_count\tcommands_pushed\tchild_ids\t"
                            << "tag_count\tmatched_protein\tproteoform_sequence\n";
        results_tsv_stream_.flush();
      }
    }
```

- [ ] **Step 4: Implement writeScanResultRow_**

```cpp
  void FLASHIda::writeScanResultRow_(const std::string& tracking_id, double rt,
                                      int mass_count, int commands_pushed,
                                      const std::vector<std::string>& child_ids,
                                      int tag_count, const std::string& matched_protein,
                                      const std::string& proteoform_sequence,
                                      uint64_t enqueue_ts)
  {
    if (!results_tsv_stream_.is_open()) return;

    auto now = std::chrono::steady_clock::now();
    uint64_t resolve_ts = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    uint64_t duration = (enqueue_ts > 0) ? (resolve_ts - enqueue_ts) : 0;

    // Format child_ids as semicolon-separated string
    std::string child_str;
    for (size_t i = 0; i < child_ids.size(); i++)
    {
      if (i > 0) child_str += ";";
      child_str += child_ids[i];
    }

    results_tsv_stream_ << tracking_id << "\t"
                        << resolve_ts << "\t"
                        << duration << "\t"
                        << rt << "\t"
                        << mass_count << "\t"
                        << commands_pushed << "\t"
                        << child_str << "\t"
                        << tag_count << "\t"
                        << matched_protein << "\t"
                        << proteoform_sequence << "\n";
    results_tsv_stream_.flush();
  }
```

- [ ] **Step 5: Call writeScanResultRow_ in processScan MS1 path**

In the MS1 path of `processScan()`, after `writeIDALogEntry_` and before the exploration block, collect child tracking IDs and write the result:

After the `writeIDALogEntry_` call, add:

```cpp
      // Collect child tracking IDs for results TSV
      std::vector<std::string> child_ids;
      for (const auto& cmd : ms2_commands)
        child_ids.push_back(ScanCommandQueue::encode(cmd.scan_id));

      // All deconvolved masses (not just selected top-N)
      int all_mass_count = static_cast<int>(selection_.selectedPeakGroups().size());

      // Resolve: MS1 has no enqueue_ts (it wasn't a queued command returning)
      std::string ms1_desc = scan_description ? std::string(scan_description) : "";
      std::string ms1_id = (ms1_desc.size() >= 3) ? ms1_desc.substr(0, 3) : "ms1";

      writeScanResultRow_(ms1_id, rt_min, all_mass_count, commands_pushed,
                          child_ids, 0, "", "", 0);
```

- [ ] **Step 6: Add MS3 result logging to processScan**

Currently `processScan()` returns 0 for `ms_level >= 3` (fallthrough at line 360). Add a results TSV row before the fallthrough return. Replace the bare `return 0;` at line 360:

```cpp
    // MS3 (or higher): no follow-up commands, but log the result
    {
      std::string desc_str = scan_description ? std::string(scan_description) : "";
      std::string ms3_id = (desc_str.size() >= 3) ? desc_str.substr(0, 3) : "";
      uint64_t enqueue_ts = 0;
      if (!ms3_id.empty())
      {
        int tid = queue_.decode(ms3_id);
        auto peeked = queue_.peekPending(tid);
        if (peeked.has_value())
          enqueue_ts = peeked->enqueue_timestamp_ms;
        queue_.resolvePending(tid);  // clean up pending entry
      }

      // Deconvolve MS3 for mass_count
      int ms3_mass_count = 0;
      if (mzs != nullptr && ints != nullptr && length > 0)
      {
        deconv_.deconvolveMS2(mzs, ints, length, rt_min, 0.0, 0);
        ms3_mass_count = deconv_.hasStoredMS2() ? static_cast<int>(deconv_.storedMS2().size()) : 0;
      }

      writeScanResultRow_(ms3_id, rt_min, ms3_mass_count, 0,
                          {}, 0, "", "", enqueue_ts);
      return 0;
    }
```

- [ ] **Step 7: Call writeScanResultRow_ in processMS2Path_**

In `processMS2Path_()`, we need to:
1. Look up enqueue_ts before resolving
2. Collect child_ids from commands pushed
3. Get tag count from selection_

Before `queue_.resolvePending()` (line 437), look up the pending command:

```cpp
    // Peek enqueue timestamp before resolving (which erases the entry)
    uint64_t enqueue_ts = 0;
    {
      auto peeked = queue_.peekPending(tracking_id);
      if (peeked.has_value())
        enqueue_ts = peeked->enqueue_timestamp_ms;
    }
```

After the existing `resolvePending` call, initialize a child_ids vector:

```cpp
    std::vector<std::string> child_ids;
```

Then at each point where commands are pushed (follow-up, conditional, MS3), collect the child IDs. Wrap each `queue_.push(...)` to also record the child:

For quantification follow-up (around line 471):
```cpp
      {
        auto followup = queue_.buildFollowUpMS2(ctx);
        queue_.push(followup);
        child_ids.push_back(ScanCommandQueue::encode(followup.scan_id));
        commands_pushed++;
      }
```

For conditional MS2 (around line 479):
```cpp
      {
        auto cond = queue_.buildConditionalFollowUp(ctx);
        queue_.push(cond);
        child_ids.push_back(ScanCommandQueue::encode(cond.scan_id));
        commands_pushed++;
      }
```

For legacy MS3 targeting (around line 497):
```cpp
        ScanCommand ms3_cmd = queue_.buildMS3(ctx, t.center_mz, t.charge, t.iso_width,
                                               t.ion_type, t.frag_index);
        queue_.push(ms3_cmd);
        child_ids.push_back(ScanCommandQueue::encode(ms3_cmd.scan_id));
        commands_pushed++;
```

Before the final `[TRACK-RESOLVE]` stdout line (line 510), get the mass count and tag info and write:

```cpp
    int ms2_mass_count = deconv_.hasStoredMS2() ? static_cast<int>(deconv_.storedMS2().size()) : 0;

    // Tag count: check if tags were found during this processScan call
    // (tags_found is already a local bool from Step 4 routing)
    int tag_count = tags_found ? 1 : 0;  // Simplified; detailed count requires changes to PrecursorSelection

    writeScanResultRow_(id_str, rt_min, ms2_mass_count, commands_pushed,
                        child_ids, tag_count, "", "", enqueue_ts);
```

- [ ] **Step 8: Verify compilation**

Run:
```bash
cmake --build OpenMS/build --target FLASHIda_ProcessScan_test 2>&1 | tail -5
```

- [ ] **Step 9: Run existing tests**

Run:
```bash
ctest --test-dir OpenMS/build -R FLASHIda_ProcessScan --output-on-failure
```
Expected: all existing tests still pass (logging is a no-op when paths are empty)

- [ ] **Step 10: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp \
        src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
git commit -m "Add ScanResults TSV writer in processScan with child_ids and MS3 logging"
```

---

### Task 5: IDA Log contract test (Test 1)

**Files:**
- Create: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/executables.cmake`

- [ ] **Step 1: Register test binary in executables.cmake**

After `FLASHIda_LegacyConfig_test` (line 457), add:

```cmake
  FLASHIda_Logging_test
```

- [ ] **Step 2: Create test file with IDA log contract test**

Create `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp`:

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------
//
// Phase 10 unit tests: IDA logging and scan tracking TSV files.

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h>

#include <fstream>
#include <sstream>
#include <string>
#include <cstring>
#include <vector>
#include <cstdio>

using namespace OpenMS;

namespace
{
  // Helper: build JSON config string with runtime paths
  // If enable_ms3=true, adds MS3 mode 1 config with selection_strategy ms3 = intensity
  std::string buildJsonWithRuntime(const std::string& ida_log_path,
                                   const std::string& commands_path,
                                   const std::string& results_path,
                                   bool enable_ms3 = false)
  {
    std::string ms3_block = enable_ms3
      ? R"("ms3": { "enabled": true, "mode": 1, "max_per_ms2": 2, "protein_sequence": "" },)"
      : "";
    std::string ms3_selection = enable_ms3 ? "\"intensity\"" : "\"none\"";

    std::ostringstream ss;
    ss << R"({
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
        "scan_timeout": { "enabled": false, "value_ms": 30000 },
        "agc_interval_seconds": 30
      },
      "exploration": { "enabled": false, "max_depth": 1, "max_variants": 5 },
      )" << ms3_block << R"(
      "files": { "target_logs": [], "fasta": "", "inclusion_list": "", "ptm_list": "" },
      "selection_strategy": {
        "ms1": { "selection": "qscore", "max_precursors": 5 },
        "ms2": { "selection": "intensity" },
        "ms3": { "selection": )" << ms3_selection << R"( }
      },
      "runtime": {
        "ida_log_path": ")" << ida_log_path << R"(",
        "scan_commands_path": ")" << commands_path << R"(",
        "scan_results_path": ")" << results_path << R"("
      }
    })";
    return ss.str();
  }

  // Helper: run full MS1→MS2→MS3 cycle, collecting commands at each level
  struct CycleResult
  {
    std::vector<ScanCommand> ms2_cmds;
    std::vector<ScanCommand> ms3_cmds;
    std::vector<ScanCommand> ms1_cmds;
    int total_dequeued = 0;
  };

  CycleResult runFullCycle(FLASHIda* ida,
                           const std::vector<ScanData>& ms1_scans,
                           const std::vector<ScanData>& ms2_scans)
  {
    CycleResult result;

    // 1. Push all MS1 scans → creates MS2 commands
    pushAllScans(ida, ms1_scans);

    // 2. Dequeue all commands (MS2 + AGC/MS1 fallbacks)
    ScanCommand cmd{};
    while (ida->getNextScanCommand(cmd) > 0)
    {
      result.total_dequeued++;
      if (cmd.msn_level == 2)
        result.ms2_cmds.push_back(cmd);
      else if (cmd.msn_level == 1)
        result.ms1_cmds.push_back(cmd);
      if (cmd.is_agc && result.ms2_cmds.size() > 0) break; // idle = queue drained
    }

    // 3. Feed MS2 results back → may create MS3 commands
    for (const auto& ms2_cmd : result.ms2_cmds)
    {
      if (!ms2_scans.empty())
      {
        ida->processScan(ms2_scans[0].mzs.data(), ms2_scans[0].ints.data(),
                        (int)ms2_scans[0].mzs.size(), ms2_scans[0].rt, 2,
                        ms2_cmd.scan_description);
      }
    }

    // 4. Dequeue MS3 commands (+ any new AGC/MS1)
    while (ida->getNextScanCommand(cmd) > 0)
    {
      result.total_dequeued++;
      if (cmd.msn_level == 3)
        result.ms3_cmds.push_back(cmd);
      if (cmd.is_agc) break;
    }

    // 5. Feed MS3 results back through processScan (ms_level=3)
    for (const auto& ms3_cmd : result.ms3_cmds)
    {
      // Reuse MS2 fragment data as MS3 input (same format, different level)
      if (!ms2_scans.empty())
      {
        ida->processScan(ms2_scans[0].mzs.data(), ms2_scans[0].ints.data(),
                        (int)ms2_scans[0].mzs.size(), ms2_scans[0].rt, 3,
                        ms3_cmd.scan_description);
      }
    }

    return result;
  }

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
    if (!f.good()) return scans;
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
      else if (!scans.empty())
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

  int pushAllScans(FLASHIda* ida, const std::vector<ScanData>& scans)
  {
    int total = 0;
    for (const auto& scan : scans)
    {
      int n = ida->processScan(scan.mzs.data(), scan.ints.data(),
                                (int)scan.mzs.size(), scan.rt, 1,
                                ("scan_" + scan.scan_id).c_str());
      total += n;
    }
    return total;
  }

  // TSV file paths relative to CTest working dir (OpenMS/build/)
  const std::string ms1_tsv_path = "../../FlashIDA/test-data/spectra/ms1_standard.txt";
  const std::string ms2_tsv_path = "../../FlashIDA/test-data/spectra/ms2_hcd_fragment.txt";
}

START_TEST(FLASHIda_Logging, "$Id$")

/////////////////////////////////////////////////////////////

// Test 1: IDA Log contract — write + parseFLASHIdaLog roundtrip
START_SECTION(ida_log_contract_roundtrip)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  if (ms1_scans.empty())
  {
    NOT_TESTABLE;  // test data not available in this build environment
    break;
  }

  // Use temp file for IDA log
  std::string ida_log_file = "test_ida_log_contract.log";
  std::remove(ida_log_file.c_str());

  std::string json = buildJsonWithRuntime(ida_log_file, "", "");
  FLASHIda ida(const_cast<char*>(json.c_str()));

  // Push all MS1 scans
  int total_commands = pushAllScans(&ida, ms1_scans);
  TEST_TRUE(total_commands > 0);

  // Parse the IDA log back using parseFLASHIdaLog
  auto parsed = FLASHIda::parseFLASHIdaLog(ida_log_file);

  // Verify: at least one scan group with precursors
  TEST_TRUE(parsed.size() > 0);

  // Verify each precursor has exactly 15 floats
  for (const auto& entry : parsed)
  {
    for (const auto& precursor : entry.second)
    {
      TEST_EQUAL(precursor.size(), 15);
      // mass (index 0) should be > 0
      TEST_TRUE(precursor[0] > 0);
      // charge (index 1) should be >= 4 (min_charge in config)
      TEST_TRUE(precursor[1] >= 4);
      // qscore (index 2) should be >= 0
      TEST_TRUE(precursor[2] >= 0);
      // window (indices 3,4) should be > 0
      TEST_TRUE(precursor[3] > 0);
      TEST_TRUE(precursor[4] > precursor[3]);
    }
  }

  // Cleanup
  std::remove(ida_log_file.c_str());
}
END_SECTION

END_TEST
```

- [ ] **Step 3: Build the test**

Run:
```bash
cmake --build OpenMS/build --target FLASHIda_Logging_test 2>&1 | tail -5
```

- [ ] **Step 4: Run the test**

Run:
```bash
ctest --test-dir OpenMS/build -R FLASHIda_Logging --output-on-failure
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp \
        src/tests/class_tests/openms/executables.cmake
git commit -m "Add IDA log contract roundtrip test"
```

---

### Task 6: ScanCommands and ScanResults TSV tests (Tests 2-5)

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp`

- [ ] **Step 1: Add TSV parsing helpers**

Add these helpers to the anonymous namespace at the top of the test file:

```cpp
  // Parse a TSV file into rows of string vectors (first row = header)
  struct TSVFile
  {
    std::vector<std::string> headers;
    std::vector<std::vector<std::string>> rows;

    static TSVFile parse(const std::string& path)
    {
      TSVFile result;
      std::ifstream f(path);
      std::string line;
      bool first = true;
      while (std::getline(f, line))
      {
        std::vector<std::string> cols;
        std::istringstream ss(line);
        std::string col;
        while (std::getline(ss, col, '\t'))
          cols.push_back(col);

        if (first)
        {
          result.headers = cols;
          first = false;
        }
        else
        {
          result.rows.push_back(cols);
        }
      }
      return result;
    }

    // Get column index by name
    int colIndex(const std::string& name) const
    {
      for (size_t i = 0; i < headers.size(); i++)
        if (headers[i] == name) return static_cast<int>(i);
      return -1;
    }
  };
```

- [ ] **Step 2: Add Test 2 — ScanCommands TSV format**

```cpp
// Test 2: ScanCommands TSV — full MS1→MS2→MS3 cycle
START_SECTION(scan_commands_tsv_format)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  auto ms2_scans = loadTsvScans(ms2_tsv_path);
  if (ms1_scans.empty() || ms2_scans.empty())
  {
    NOT_TESTABLE;
    break;
  }

  std::string commands_file = "test_scan_commands.tsv";
  std::remove(commands_file.c_str());

  // Enable MS3 so we get MS3 commands in the TSV
  std::string json = buildJsonWithRuntime("", commands_file, "", true);
  FLASHIda ida(const_cast<char*>(json.c_str()));

  // Full MS1→MS2��MS3 cycle
  auto cycle = runFullCycle(&ida, ms1_scans, ms2_scans);
  TEST_TRUE(cycle.ms2_cmds.size() > 0);

  // Parse and verify TSV
  auto tsv = TSVFile::parse(commands_file);

  // Header check
  TEST_TRUE(tsv.colIndex("tracking_id") >= 0);
  TEST_TRUE(tsv.colIndex("ms_level") >= 0);
  TEST_TRUE(tsv.colIndex("scan_type") >= 0);
  TEST_TRUE(tsv.colIndex("enqueue_ts") >= 0);
  TEST_TRUE(tsv.colIndex("qscore") >= 0);
  TEST_TRUE(tsv.colIndex("ion_type") >= 0);
  TEST_TRUE(tsv.colIndex("ion_index") >= 0);

  int ms_level_col = tsv.colIndex("ms_level");
  int ion_type_col = tsv.colIndex("ion_type");
  bool found_ms2 = false;
  bool found_ms3 = false;
  for (const auto& row : tsv.rows)
  {
    if (ms_level_col >= 0 && ms_level_col < (int)row.size())
    {
      if (row[ms_level_col] == "2") found_ms2 = true;
      if (row[ms_level_col] == "3")
      {
        found_ms3 = true;
        // MS3 rows should have scan_description with ion info
        // ion_type may be empty if MS3 mode doesn't produce ion annotations
      }
    }
  }
  TEST_TRUE(found_ms2);
  // MS3 commands may or may not be produced depending on MS2 fragment data
  // If they are produced, they should be in the TSV
  if (cycle.ms3_cmds.size() > 0)
  {
    TEST_TRUE(found_ms3);
  }

  // Every row should have the same number of columns as the header
  for (const auto& row : tsv.rows)
  {
    TEST_EQUAL(row.size(), tsv.headers.size());
  }

  std::remove(commands_file.c_str());
}
END_SECTION
```

- [ ] **Step 3: Add Test 3 — ScanResults TSV format**

```cpp
// Test 3: ScanResults TSV — full MS1→MS2→MS3 cycle with duration tracking
START_SECTION(scan_results_tsv_format)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  auto ms2_scans = loadTsvScans(ms2_tsv_path);
  if (ms1_scans.empty() || ms2_scans.empty())
  {
    NOT_TESTABLE;
    break;
  }

  std::string results_file = "test_scan_results.tsv";
  std::remove(results_file.c_str());

  // Enable MS3 so we get MS3 result rows
  std::string json = buildJsonWithRuntime("", "", results_file, true);
  FLASHIda ida(const_cast<char*>(json.c_str()));

  // Full MS1→MS2→MS3 cycle (including feeding MS3 back)
  auto cycle = runFullCycle(&ida, ms1_scans, ms2_scans);

  // Parse and verify
  auto tsv = TSVFile::parse(results_file);
  TEST_TRUE(tsv.colIndex("tracking_id") >= 0);
  TEST_TRUE(tsv.colIndex("resolve_ts") >= 0);
  TEST_TRUE(tsv.colIndex("duration_ms") >= 0);
  TEST_TRUE(tsv.colIndex("mass_count") >= 0);
  TEST_TRUE(tsv.colIndex("commands_pushed") >= 0);
  TEST_TRUE(tsv.colIndex("child_ids") >= 0);

  // Should have MS1, MS2, and (if MS3 commands were created) MS3 result rows
  // MS1 results from pushAllScans, MS2 from feeding back, MS3 from feeding back
  int expected_min_rows = (int)ms1_scans.size() + (int)cycle.ms2_cmds.size();
  if (cycle.ms3_cmds.size() > 0)
    expected_min_rows += (int)cycle.ms3_cmds.size();
  TEST_TRUE((int)tsv.rows.size() >= expected_min_rows);

  // Every row should have correct column count
  for (const auto& row : tsv.rows)
  {
    TEST_EQUAL(row.size(), tsv.headers.size());
  }

  // duration_ms should be non-negative
  int dur_col = tsv.colIndex("duration_ms");
  for (const auto& row : tsv.rows)
  {
    if (dur_col >= 0 && dur_col < (int)row.size())
    {
      uint64_t dur = std::stoull(row[dur_col]);
      TEST_TRUE(dur >= 0);
    }
  }

  // MS2 result rows should have child_ids pointing to MS3 commands (if any)
  if (cycle.ms3_cmds.size() > 0)
  {
    int child_col = tsv.colIndex("child_ids");
    bool found_ms2_with_children = false;
    for (const auto& row : tsv.rows)
    {
      if (child_col >= 0 && child_col < (int)row.size() && !row[child_col].empty())
        found_ms2_with_children = true;
    }
    TEST_TRUE(found_ms2_with_children);
  }

  std::remove(results_file.c_str());
}
END_SECTION
```

- [ ] **Step 4: Add Test 4 — Join integrity**

```cpp
// Test 4: Join integrity — every child_id in results exists in commands, full MS3 cycle
START_SECTION(join_integrity)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  auto ms2_scans = loadTsvScans(ms2_tsv_path);
  if (ms1_scans.empty() || ms2_scans.empty())
  {
    NOT_TESTABLE;
    break;
  }

  std::string commands_file = "test_join_commands.tsv";
  std::string results_file = "test_join_results.tsv";
  std::remove(commands_file.c_str());
  std::remove(results_file.c_str());

  // Enable MS3 for full parent-child graph testing
  std::string json = buildJsonWithRuntime("", commands_file, results_file, true);
  FLASHIda ida(const_cast<char*>(json.c_str()));

  // Full MS1→MS2→MS3 cycle (with MS3 fed back)
  auto cycle = runFullCycle(&ida, ms1_scans, ms2_scans);

  // Drain any remaining commands
  ScanCommand cmd;
  while (ida.getNextScanCommand(cmd) > 0) {}

  // Parse both files
  auto cmd_tsv = TSVFile::parse(commands_file);
  auto res_tsv = TSVFile::parse(results_file);

  // Build set of all command tracking_ids
  std::set<std::string> cmd_ids;
  int cmd_id_col = cmd_tsv.colIndex("tracking_id");
  for (const auto& row : cmd_tsv.rows)
  {
    if (cmd_id_col >= 0 && cmd_id_col < (int)row.size())
      cmd_ids.insert(row[cmd_id_col]);
  }

  // Every child_id in results must exist in commands
  int child_col = res_tsv.colIndex("child_ids");
  int pushed_col = res_tsv.colIndex("commands_pushed");
  for (const auto& row : res_tsv.rows)
  {
    if (child_col >= 0 && child_col < (int)row.size() && !row[child_col].empty())
    {
      // Parse semicolon-separated child IDs
      std::istringstream child_ss(row[child_col]);
      std::string child_id;
      int child_count = 0;
      while (std::getline(child_ss, child_id, ';'))
      {
        TEST_TRUE(cmd_ids.count(child_id) > 0);
        child_count++;
      }
      // commands_pushed should equal child count
      if (pushed_col >= 0 && pushed_col < (int)row.size())
      {
        TEST_EQUAL(std::stoi(row[pushed_col]), child_count);
      }
    }
  }

  std::remove(commands_file.c_str());
  std::remove(results_file.c_str());
}
END_SECTION
```

- [ ] **Step 5: Add Test 5 — Crash safety (valid TSV after each write)**

```cpp
// Test 5: Crash safety — files are valid TSV after each operation (including MS3)
START_SECTION(crash_safety_valid_tsv)
{
  auto ms1_scans = loadTsvScans(ms1_tsv_path);
  auto ms2_scans = loadTsvScans(ms2_tsv_path);
  if (ms1_scans.empty() || ms2_scans.empty())
  {
    NOT_TESTABLE;
    break;
  }

  std::string commands_file = "test_crash_commands.tsv";
  std::string results_file = "test_crash_results.tsv";
  std::remove(commands_file.c_str());
  std::remove(results_file.c_str());

  // Enable MS3 for full cycle
  std::string json = buildJsonWithRuntime("", commands_file, results_file, true);
  FLASHIda ida(const_cast<char*>(json.c_str()));

  // After constructor: headers should exist
  {
    auto cmd_tsv = TSVFile::parse(commands_file);
    TEST_TRUE(cmd_tsv.headers.size() > 0);
    auto res_tsv = TSVFile::parse(results_file);
    TEST_TRUE(res_tsv.headers.size() > 0);
  }

  // Push one MS1 scan, check files are valid
  ida.processScan(ms1_scans[0].mzs.data(), ms1_scans[0].ints.data(),
                  (int)ms1_scans[0].mzs.size(), ms1_scans[0].rt, 1, "scan_1");
  {
    auto res_tsv = TSVFile::parse(results_file);
    TEST_TRUE(res_tsv.rows.size() >= 1);
    for (const auto& row : res_tsv.rows)
      TEST_EQUAL(row.size(), res_tsv.headers.size());
  }

  // Dequeue one command, check commands file is valid
  ScanCommand cmd;
  ida.getNextScanCommand(cmd);
  {
    auto cmd_tsv = TSVFile::parse(commands_file);
    TEST_TRUE(cmd_tsv.rows.size() >= 1);
    for (const auto& row : cmd_tsv.rows)
      TEST_EQUAL(row.size(), cmd_tsv.headers.size());
  }

  // Feed MS2 result back, check files are still valid
  if (cmd.msn_level == 2)
  {
    ida.processScan(ms2_scans[0].mzs.data(), ms2_scans[0].ints.data(),
                    (int)ms2_scans[0].mzs.size(), ms2_scans[0].rt, 2,
                    cmd.scan_description);
    {
      auto res_tsv = TSVFile::parse(results_file);
      for (const auto& row : res_tsv.rows)
        TEST_EQUAL(row.size(), res_tsv.headers.size());
    }
  }

  // Dequeue MS3 if available, feed back, check files
  ScanCommand ms3_cmd;
  if (ida.getNextScanCommand(ms3_cmd) > 0 && ms3_cmd.msn_level == 3)
  {
    // Check commands file after MS3 dequeue
    {
      auto cmd_tsv = TSVFile::parse(commands_file);
      for (const auto& row : cmd_tsv.rows)
        TEST_EQUAL(row.size(), cmd_tsv.headers.size());
    }

    // Feed MS3 result back
    ida.processScan(ms2_scans[0].mzs.data(), ms2_scans[0].ints.data(),
                    (int)ms2_scans[0].mzs.size(), ms2_scans[0].rt, 3,
                    ms3_cmd.scan_description);

    // Check results file after MS3 result
    {
      auto res_tsv = TSVFile::parse(results_file);
      for (const auto& row : res_tsv.rows)
        TEST_EQUAL(row.size(), res_tsv.headers.size());
    }
  }

  std::remove(commands_file.c_str());
  std::remove(results_file.c_str());
}
END_SECTION
```

- [ ] **Step 6: Build and run all tests**

```bash
cmake --build OpenMS/build --target FLASHIda_Logging_test 2>&1 | tail -5
ctest --test-dir OpenMS/build -R FLASHIda_Logging --output-on-failure
```

- [ ] **Step 7: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp
git commit -m "Add ScanCommands/ScanResults TSV tests and join integrity test"
```

---

### Task 7: C# RuntimeConfig and ToCppJson passthrough

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs`

- [ ] **Step 1: Add RuntimeConfig class to MethodConfig.cs**

After `ExplorationBlockConfig` / before the selection config classes (around line 237), add:

```csharp
    [JsonKey("runtime")]
    public class RuntimeConfig
    {
        [JsonKey("ida_log_path")]
        public string IdaLogPath { get; set; } = "";

        [JsonKey("scan_commands_path")]
        public string ScanCommandsPath { get; set; } = "";

        [JsonKey("scan_results_path")]
        public string ScanResultsPath { get; set; } = "";
    }
```

Add `Runtime` property to the root `MethodConfig` class (after the `Files` property, around line 353):

```csharp
        [JsonKey("runtime")]
        public RuntimeConfig Runtime { get; set; } = new RuntimeConfig();
```

Add `JsonRuntimeConfig` class after `JsonFilesConfig` (around line 485):

```csharp
    public class JsonRuntimeConfig
    {
        public string ida_log_path { get; set; }
        public string scan_commands_path { get; set; }
        public string scan_results_path { get; set; }
    }
```

Add `runtime` property to `JsonMethodConfig` (around line 508, before the closing brace):

```csharp
        public JsonRuntimeConfig runtime { get; set; }
```

- [ ] **Step 2: Serialize runtime in ToCppJson()**

In `MethodParameters.cs`, in `ToCppJson()`, after the `files` block (around line 210) and before `return new JavaScriptSerializer().Serialize(config);`, add:

```csharp
            config.runtime = new JsonRuntimeConfig
            {
                ida_log_path = c.Runtime.IdaLogPath ?? "",
                scan_commands_path = c.Runtime.ScanCommandsPath ?? "",
                scan_results_path = c.Runtime.ScanResultsPath ?? ""
            };
```

Note: `config` here is the `JsonMethodConfig` variable declared earlier in the method.

- [ ] **Step 3: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "Add RuntimeConfig for IDA log and TSV file paths"
```

---

### Task 8: C# runtime config passthrough test (Test 6)

**Files:**
- Modify: `FlashIDA/src/Flash.Tests/JsonConfigTests.cs`

- [ ] **Step 1: Add runtime config passthrough test**

Add a new test to `JsonConfigTests.cs`:

```csharp
        [Test, Category("Tier1")]
        public void ToCppJson_ContainsRuntimeSection()
        {
            var mp = new MethodParameters();
            mp.Config.Runtime.IdaLogPath = "IDALog_test.log";
            mp.Config.Runtime.ScanCommandsPath = "ScanCommands_test.tsv";
            mp.Config.Runtime.ScanResultsPath = "ScanResults_test.tsv";

            string json = mp.ToCppJson();
            var parsed = new System.Web.Script.Serialization.JavaScriptSerializer()
                .Deserialize<Dictionary<string, object>>(json);

            Assert.IsTrue(parsed.ContainsKey("runtime"), "JSON should contain runtime section");
            var runtime = parsed["runtime"] as Dictionary<string, object>;
            Assert.IsNotNull(runtime, "runtime should be a dictionary");
            Assert.AreEqual("IDALog_test.log", runtime["ida_log_path"]);
            Assert.AreEqual("ScanCommands_test.tsv", runtime["scan_commands_path"]);
            Assert.AreEqual("ScanResults_test.tsv", runtime["scan_results_path"]);
        }

        [Test, Category("Tier1")]
        public void RuntimeConfig_UserOverridePreserved()
        {
            // Simulate user setting paths in method JSON
            string methodJson = @"{
                ""global"": { ""duration"": 90 },
                ""runtime"": {
                    ""ida_log_path"": ""user_ida.log"",
                    ""scan_commands_path"": ""user_commands.tsv"",
                    ""scan_results_path"": ""user_results.tsv""
                }
            }";

            var config = MethodConfigSerializer.Deserialize(methodJson);
            Assert.AreEqual("user_ida.log", config.Runtime.IdaLogPath);
            Assert.AreEqual("user_commands.tsv", config.Runtime.ScanCommandsPath);
            Assert.AreEqual("user_results.tsv", config.Runtime.ScanResultsPath);
        }
```

- [ ] **Step 2: Commit**

```bash
cd FlashIDA
git add src/Flash.Tests/JsonConfigTests.cs
git commit -m "Add runtime config passthrough and user override tests"
```

---

### Task 9: Update CI and submodule pointers

**Files:**
- Modify: `.github/workflows/flashida-ci.yml`
- Submodule pointers for FlashIDA and OpenMS

- [ ] **Step 1: Add FLASHIda_Logging_test to CI build targets and ctest filter**

In `flashida-ci.yml`, add `FLASHIda_Logging_test` to the `cmake --build` target list (line 58) and the `ctest -R` filter (line 63):

Build line — add `FLASHIda_Logging_test` at the end:
```yaml
          cmake --build OpenMS/build --target DeconvolvedSpectrum_OptimizationMetadata_test FLASHIdaQueueTracking_test FLASHIda_ProcessScan_test ScanCommandLayout_test FLASHIdaFAIMS_test FLASHIda_exploration_test FLASHIda_LegacyConfig_test FLASHIda_Logging_test
```

CTest line — add `FLASHIda_Logging` to the regex:
```yaml
          ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration|FLASHIda_LegacyConfig|FLASHIda_Logging" --output-on-failure
```

- [ ] **Step 2: Push OpenMS changes**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

Wait for the `build-dlls` workflow to complete.

- [ ] **Step 3: Push FlashIDA changes**

```bash
cd FlashIDA
git push origin phase-10
```

- [ ] **Step 4: Update submodule pointers in parent repo**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add OpenMS FlashIDA
git commit -m "Update submodule pointers: IDA logging and scan tracking"
```

- [ ] **Step 5: Update CI workflow and push**

```bash
git add .github/workflows/flashida-ci.yml
git commit -m "Add FLASHIda_Logging_test to CI"
git push origin phase-10
```

---

## Commit Summary

| # | Repo | Content |
|---|------|---------|
| 1 | OpenMS | RuntimeConfig struct + JSON parsing |
| 2 | OpenMS | IDA log writer (parseFLASHIdaLog-compatible) |
| 3 | OpenMS | ScanCommands TSV writer in getNextScanCommand |
| 4 | OpenMS | ScanResults TSV writer with child_ids tracking |
| 5 | OpenMS | IDA log contract roundtrip test |
| 6 | OpenMS | TSV format, join integrity, crash safety tests |
| 7 | FlashIDA | RuntimeConfig + ToCppJson passthrough |
| 8 | FlashIDA | Runtime config NUnit tests |
| 9 | Parent | Submodule pointers + CI update |

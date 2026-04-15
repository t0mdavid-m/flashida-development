# Granular Timing Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dequeue_timestamp_ms` to `ScanCommand` and 4 new columns to results.tsv (`dequeue_ts`, `queue_duration_ms`, `instrument_duration_ms`, `processing_duration_ms`) to break down scan timing into queue wait, instrument turnaround, and C++ processing duration.

**Architecture:** Add a single `uint64_t` field to the blittable `ScanCommand` struct (carve from `reserved_`). Move `pending_scan_map_` insertion from `push()` to `dequeue()` so the map entry carries both timestamps. Bypass commands (AGC) register directly via a new `registerPending()` method. All three durations are computed in `writeScanResultRow_()` and appended as new TSV columns.

**Tech Stack:** C++20 (OpenMS), C# .NET 4.8 (FlashIDA), P/Invoke blittable struct

---

## File Structure

| File | Role | Change |
|---|---|---|
| `OpenMS/.../ScanCommand.h` | Struct definition | Add field, shrink reserved |
| `OpenMS/.../ScanCommandQueue.h` | Queue header | Declare `registerPending()` |
| `OpenMS/.../ScanCommandQueue.cpp` | Queue implementation | Move map insert to `dequeue()`, add `registerPending()` |
| `OpenMS/.../FLASHIda.h` | Engine header | Add `dequeue_ts` param to `writeScanResultRow_()` |
| `OpenMS/.../FLASHIda.cpp` | Engine implementation | Stamp bypass commands, read `dequeue_ts`, compute + write new columns |
| `OpenMS/.../ScanCommandLayout_test.cpp` | C++ layout test | Add offset print for new field |
| `FlashIDA/.../FLASHIdaWrapper.cs` | C# struct mirror | Add `DequeueTimestampMs`, shrink reserved |
| `FlashIDA/.../ScanCommandLayoutTests.cs` | C# layout test | Add offset assertion, update reserved SizeConst |

All paths below are relative to the repo root `/home/tom-mueller/kohlbacherlab/FLASHIda/Development/`.

---

### Task 1: Add `dequeue_timestamp_ms` to ScanCommand struct (C++ and C#)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:80-104`
- Modify: `OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp:48-70`
- Modify: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:56,83-84`
- Modify: `FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs:52-78,131-135`

- [ ] **Step 1: Add the C++ struct field**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h`, add `dequeue_timestamp_ms` after `enqueue_timestamp_ms` and shrink `reserved_`.

Replace line 80-104:
```cpp
    uint64_t enqueue_timestamp_ms; ///< Timestamp when command was enqueued (steady_clock ms)

    // Precursor scoring data (populated by buildMS2Command_ for diagnostic output)
```
With:
```cpp
    uint64_t enqueue_timestamp_ms; ///< Timestamp when command was enqueued (steady_clock ms)
    uint64_t dequeue_timestamp_ms; ///< Timestamp when command was dequeued/sent to instrument (steady_clock ms)

    // Precursor scoring data (populated by buildMS2Command_ for diagnostic output)
```

And replace line 104:
```cpp
    char reserved_[700];           ///< Reserved for future fields (consume from here, never change total size)
```
With:
```cpp
    char reserved_[692];           ///< Reserved for future fields (consume from here, never change total size)
```

Also update the layout comment at lines 61-63:
```cpp
  /// Blittable struct representing a complete scan command for the instrument.
  /// Layout: 1248 (existing) + 8 (microscans+pad3) + 24 (rf_lens+source_cid+source_cid_scaling)
  ///       + 64 (data_type+scan_rate) + 4 (parent_scan_id) + 700 (reserved) = 2048.
```
With:
```cpp
  /// Blittable struct representing a complete scan command for the instrument.
  /// Layout: 1248 (existing) + 8 (dequeue_timestamp_ms) + 8 (microscans+pad3)
  ///       + 24 (rf_lens+source_cid+source_cid_scaling) + 64 (data_type+scan_rate)
  ///       + 4 (parent_scan_id) + 692 (reserved) = 2048.
```

- [ ] **Step 2: Add offset print to C++ layout test**

In `OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp`, add after line 48 (`enqueue_timestamp_ms`):

```cpp
  std::printf("ScanCommand.dequeue_timestamp_ms.offset=%zu\n", offsetof(ScanCommand, dequeue_timestamp_ms));
```

The new field is at offset 1144 + 8 = 1152. All subsequent fields shift by +8:
- `qscore` moves from 1152 to 1160
- `mono_mass` moves from 1160 to 1168
- ... and so on through `reserved_` at 1356 (was 1348)

Update ALL offset prints from `qscore` onward to reflect the +8 shift. The full replacement for lines 49-70:

```cpp
  std::printf("ScanCommand.qscore.offset=%zu\n", offsetof(ScanCommand, qscore));
  std::printf("ScanCommand.mono_mass.offset=%zu\n", offsetof(ScanCommand, mono_mass));
  std::printf("ScanCommand.charge_cos.offset=%zu\n", offsetof(ScanCommand, charge_cos));
  std::printf("ScanCommand.charge_snr.offset=%zu\n", offsetof(ScanCommand, charge_snr));
  std::printf("ScanCommand.iso_cos.offset=%zu\n", offsetof(ScanCommand, iso_cos));
  std::printf("ScanCommand.snr.offset=%zu\n", offsetof(ScanCommand, snr));
  std::printf("ScanCommand.charge_score.offset=%zu\n", offsetof(ScanCommand, charge_score));
  std::printf("ScanCommand.ppm_error.offset=%zu\n", offsetof(ScanCommand, ppm_error));
  std::printf("ScanCommand.precursor_intensity.offset=%zu\n", offsetof(ScanCommand, precursor_intensity));
  std::printf("ScanCommand.peakgroup_intensity.offset=%zu\n", offsetof(ScanCommand, peakgroup_intensity));
  std::printf("ScanCommand.hcd_energy.offset=%zu\n", offsetof(ScanCommand, hcd_energy));
  std::printf("ScanCommand.pad2.offset=%zu\n", offsetof(ScanCommand, pad2));
  std::printf("ScanCommand.faims_cv.offset=%zu\n", offsetof(ScanCommand, faims_cv));
  std::printf("ScanCommand.microscans.offset=%zu\n", offsetof(ScanCommand, microscans));
  std::printf("ScanCommand.pad3.offset=%zu\n", offsetof(ScanCommand, pad3));
  std::printf("ScanCommand.rf_lens.offset=%zu\n", offsetof(ScanCommand, rf_lens));
  std::printf("ScanCommand.source_cid.offset=%zu\n", offsetof(ScanCommand, source_cid));
  std::printf("ScanCommand.source_cid_scaling.offset=%zu\n", offsetof(ScanCommand, source_cid_scaling));
  std::printf("ScanCommand.data_type.offset=%zu\n", offsetof(ScanCommand, data_type));
  std::printf("ScanCommand.scan_rate.offset=%zu\n", offsetof(ScanCommand, scan_rate));
  std::printf("ScanCommand.parent_scan_id.offset=%zu\n", offsetof(ScanCommand, parent_scan_id));
  std::printf("ScanCommand.reserved_.offset=%zu\n", offsetof(ScanCommand, reserved_));
```

Note: These are `printf` calls — the offsets are printed at runtime, not compile-time asserted. The lines don't change textually (they use `offsetof` which computes at compile time). No line edits needed here — just add the new `dequeue_timestamp_ms` printf after line 48.

- [ ] **Step 3: Update C# struct**

In `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`, add after `EnqueueTimestampMs` (line 56):

```csharp
        public ulong DequeueTimestampMs;
```

And change the `Reserved` array size from 700 to 692 (line 83-84):

Replace:
```csharp
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 700)]
        public byte[] Reserved;
```
With:
```csharp
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 692)]
        public byte[] Reserved;
```

- [ ] **Step 4: Update C# layout test**

In `FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs`:

Add after the `EnqueueTimestampMs` assertion (line 52):
```csharp
            Assert.AreEqual(1152, (int)Marshal.OffsetOf<ScanCommand>("DequeueTimestampMs"), "DequeueTimestampMs offset");
```

Update the comment on line 54 from:
```csharp
            // Scoring fields (after EnqueueTimestampMs at 1144 + 8 = 1152)
```
To:
```csharp
            // Scoring fields (after DequeueTimestampMs at 1152 + 8 = 1160)
```

Update ALL subsequent offset assertions to add +8 (lines 55-78):
```csharp
            Assert.AreEqual(1160, (int)Marshal.OffsetOf<ScanCommand>("Qscore"), "Qscore offset");
            Assert.AreEqual(1168, (int)Marshal.OffsetOf<ScanCommand>("MonoMass"), "MonoMass offset");
            Assert.AreEqual(1176, (int)Marshal.OffsetOf<ScanCommand>("ChargeCos"), "ChargeCos offset");
            Assert.AreEqual(1184, (int)Marshal.OffsetOf<ScanCommand>("ChargeSnr"), "ChargeSnr offset");
            Assert.AreEqual(1192, (int)Marshal.OffsetOf<ScanCommand>("IsoCos"), "IsoCos offset");
            Assert.AreEqual(1200, (int)Marshal.OffsetOf<ScanCommand>("Snr"), "Snr offset");
            Assert.AreEqual(1208, (int)Marshal.OffsetOf<ScanCommand>("ChargeScore"), "ChargeScore offset");
            Assert.AreEqual(1216, (int)Marshal.OffsetOf<ScanCommand>("PpmError"), "PpmError offset");
            Assert.AreEqual(1224, (int)Marshal.OffsetOf<ScanCommand>("PrecursorIntensity"), "PrecursorIntensity offset");
            Assert.AreEqual(1232, (int)Marshal.OffsetOf<ScanCommand>("PeakgroupIntensity"), "PeakgroupIntensity offset");
            Assert.AreEqual(1240, (int)Marshal.OffsetOf<ScanCommand>("HcdEnergy"), "HcdEnergy offset");
            Assert.AreEqual(1244, (int)Marshal.OffsetOf<ScanCommand>("Pad2"), "Pad2 offset");
            Assert.AreEqual(1248, (int)Marshal.OffsetOf<ScanCommand>("FaimsCv"), "FaimsCv offset");

            // New scan parameter fields (after FaimsCv at 1248 + 8 = 1256)
            Assert.AreEqual(1256, (int)Marshal.OffsetOf<ScanCommand>("Microscans"), "Microscans offset");
            Assert.AreEqual(1260, (int)Marshal.OffsetOf<ScanCommand>("Pad3"), "Pad3 offset");
            Assert.AreEqual(1264, (int)Marshal.OffsetOf<ScanCommand>("RfLens"), "RfLens offset");
            Assert.AreEqual(1272, (int)Marshal.OffsetOf<ScanCommand>("SourceCid"), "SourceCid offset");
            Assert.AreEqual(1280, (int)Marshal.OffsetOf<ScanCommand>("SourceCidScaling"), "SourceCidScaling offset");
            Assert.AreEqual(1288, (int)Marshal.OffsetOf<ScanCommand>("DataType"), "DataType offset");
            Assert.AreEqual(1320, (int)Marshal.OffsetOf<ScanCommand>("ScanRate"), "ScanRate offset");
            Assert.AreEqual(1352, (int)Marshal.OffsetOf<ScanCommand>("ParentScanId"), "ParentScanId offset");
            Assert.AreEqual(1356, (int)Marshal.OffsetOf<ScanCommand>("Reserved"), "Reserved offset");
```

Update the Reserved SizeConst assertion (line 135):
```csharp
            Assert.AreEqual(692, reservedAttr.SizeConst, "Reserved SizeConst");
```

- [ ] **Step 5: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h \
                   src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp
git -C OpenMS commit -m "Add dequeue_timestamp_ms to ScanCommand struct (C++ side)"

git -C FlashIDA add src/Flash/IDA/FLASHIdaWrapper.cs \
                     src/Flash.Tests/ScanCommandLayoutTests.cs
git -C FlashIDA commit -m "Add DequeueTimestampMs to ScanCommand struct (C# side)"
```

---

### Task 2: Move `pending_scan_map_` insert from `push()` to `dequeue()`, add `registerPending()`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:96-112`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:368-392`

- [ ] **Step 1: Remove map insert from `push()`**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp`, replace lines 368-377:

```cpp
  void ScanCommandQueue::push(ScanCommand cmd)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
    pending_scan_map_[cmd.scan_id] = cmd;
    int p = std::clamp(cmd.priority, 0, 3);
    queues_[p].push_back(cmd);
  }
```

With:

```cpp
  void ScanCommandQueue::push(ScanCommand cmd)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
    int p = std::clamp(cmd.priority, 0, 3);
    queues_[p].push_back(cmd);
  }
```

- [ ] **Step 2: Stamp dequeue time and insert into map in `dequeue()`**

In the same file, replace lines 379-392:

```cpp
  std::optional<ScanCommand> ScanCommandQueue::dequeue()
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    for (int p = 0; p < 4; ++p)
    {
      if (!queues_[p].empty())
      {
        ScanCommand cmd = queues_[p].front();
        queues_[p].pop_front();
        return cmd;
      }
    }
    return std::nullopt;
  }
```

With:

```cpp
  std::optional<ScanCommand> ScanCommandQueue::dequeue()
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    for (int p = 0; p < 4; ++p)
    {
      if (!queues_[p].empty())
      {
        ScanCommand cmd = queues_[p].front();
        queues_[p].pop_front();
        cmd.dequeue_timestamp_ms = static_cast<uint64_t>(
          std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
        pending_scan_map_[cmd.scan_id] = cmd;
        return cmd;
      }
    }
    return std::nullopt;
  }
```

- [ ] **Step 3: Add `registerPending()` method**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp`, add after the `dequeue()` method (after the closing brace at what was line 392):

```cpp
  void ScanCommandQueue::registerPending(const ScanCommand& cmd)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    pending_scan_map_[cmd.scan_id] = cmd;
  }
```

- [ ] **Step 4: Declare `registerPending()` in the header**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h`, add after the `dequeue()` declaration (line 100):

```cpp
    /// Register a bypass command (AGC, etc.) in pending_scan_map_ without queuing it
    void registerPending(const ScanCommand& cmd);
```

- [ ] **Step 5: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
                   src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
git -C OpenMS commit -m "Move pending_scan_map_ insert from push() to dequeue(), add registerPending()"
```

---

### Task 3: Stamp bypass commands and register them in `pending_scan_map_`

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:863-877` (Step 1 AGC), `920-948` (Step 5 idle AGC)

- [ ] **Step 1: Stamp and register Step 1 AGC bypass command**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, in `getNextScanCommand()`, the Step 1 AGC block (lines 863-877). Replace:

```cpp
    // Step 1: AGC scan if needed
    if (queue_.needsAGC())
    {
      out = queue_.makeAGC();
      out.faims_cv = faims_cv;
      out.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      // Scan description: {3-char ID}A
      std::string id_str = ScanCommandQueue::encode(out.scan_id);
      std::snprintf(out.scan_description, 16, "%sA", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=agc" << std::endl;
      writeScanCommandRow_(out);
      return 1;
    }
```

With:

```cpp
    // Step 1: AGC scan if needed
    if (queue_.needsAGC())
    {
      out = queue_.makeAGC();
      out.faims_cv = faims_cv;
      out.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      uint64_t now_ms = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count());
      out.enqueue_timestamp_ms = now_ms;
      out.dequeue_timestamp_ms = now_ms;

      // Scan description: {3-char ID}A
      std::string id_str = ScanCommandQueue::encode(out.scan_id);
      std::snprintf(out.scan_description, 16, "%sA", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=agc" << std::endl;
      queue_.registerPending(out);
      writeScanCommandRow_(out);
      return 1;
    }
```

- [ ] **Step 2: Stamp and register Step 5 idle AGC bypass command**

In the same file, the Step 5 idle block (lines 920-948). Replace:

```cpp
    // Step 5: Idle cycle -- queue empty, keep the instrument busy with AGC + MS1
    // Create an AGC command (returned immediately) and push an MS1 at priority 3
    // into the queue as a fallback scan (lowest priority, behind follow-ups/MS3/MS2).
    {
      // 5a: AGC
      ScanCommand agc_cmd = queue_.makeAGC();
      agc_cmd.faims_cv = faims_cv;
      agc_cmd.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      std::string agc_id_str = ScanCommandQueue::encode(agc_cmd.scan_id);
      std::snprintf(agc_cmd.scan_description, 16, "%sA", agc_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << agc_id_str << " ms_level=1 type=idle_agc" << std::endl;

      // 5b: MS1 -- use default priority 3 (lowest, behind follow-ups/MS3/MS2)
      ScanCommand ms1_cmd = queue_.makeMS1();
      ms1_cmd.faims_cv = faims_cv;
      ms1_cmd.scan_id = queue_.nextTrackingId();
      ms1_cmd.priority = 3;

      std::string ms1_id_str = ScanCommandQueue::encode(ms1_cmd.scan_id);
      std::snprintf(ms1_cmd.scan_description, 16, "%sS", ms1_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << ms1_id_str << " ms_level=1 type=idle_ms1" << std::endl;

      // Push MS1 into priority-3 queue for next dequeue call
      queue_.push(ms1_cmd);

      out = agc_cmd;
      writeScanCommandRow_(out);
      return 1;
    }
```

With:

```cpp
    // Step 5: Idle cycle -- queue empty, keep the instrument busy with AGC + MS1
    // Create an AGC command (returned immediately) and push an MS1 at priority 3
    // into the queue as a fallback scan (lowest priority, behind follow-ups/MS3/MS2).
    {
      // 5a: AGC
      ScanCommand agc_cmd = queue_.makeAGC();
      agc_cmd.faims_cv = faims_cv;
      agc_cmd.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      uint64_t now_ms = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count());
      agc_cmd.enqueue_timestamp_ms = now_ms;
      agc_cmd.dequeue_timestamp_ms = now_ms;

      std::string agc_id_str = ScanCommandQueue::encode(agc_cmd.scan_id);
      std::snprintf(agc_cmd.scan_description, 16, "%sA", agc_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << agc_id_str << " ms_level=1 type=idle_agc" << std::endl;

      // 5b: MS1 -- use default priority 3 (lowest, behind follow-ups/MS3/MS2)
      ScanCommand ms1_cmd = queue_.makeMS1();
      ms1_cmd.faims_cv = faims_cv;
      ms1_cmd.scan_id = queue_.nextTrackingId();
      ms1_cmd.priority = 3;

      std::string ms1_id_str = ScanCommandQueue::encode(ms1_cmd.scan_id);
      std::snprintf(ms1_cmd.scan_description, 16, "%sS", ms1_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << ms1_id_str << " ms_level=1 type=idle_ms1" << std::endl;

      // Push MS1 into priority-3 queue for next dequeue call
      queue_.push(ms1_cmd);

      out = agc_cmd;
      queue_.registerPending(out);
      writeScanCommandRow_(out);
      return 1;
    }
```

- [ ] **Step 3: Commit**

```bash
git -C OpenMS add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git -C OpenMS commit -m "Stamp and register bypass commands with enqueue+dequeue timestamps"
```

---

### Task 4: Read `dequeue_ts` in `processScan()`, add new TSV columns

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:260-272`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:96-103` (header), `317-401` (writeScanResultRow_), `580-586` (processScan timestamp read), `653-654` (call site 1), `699-705` (call site 2), `782-786` (call site 3), `814-821` (call site 4), `851-853` (call site 5)

- [ ] **Step 1: Read `dequeue_ts` in `processScan()`**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, replace lines 580-586:

```cpp
    // Retrieve enqueue timestamp from pending map (set by push())
    uint64_t enqueue_ts = 0;
    {
      auto peeked = queue_.peekPending(tracking_id);
      if (peeked.has_value())
        enqueue_ts = peeked->enqueue_timestamp_ms;
    }
```

With:

```cpp
    // Retrieve timestamps from pending map (enqueue set by push(), dequeue set by dequeue())
    uint64_t enqueue_ts = 0;
    uint64_t dequeue_ts = 0;
    {
      auto peeked = queue_.peekPending(tracking_id);
      if (peeked.has_value())
      {
        enqueue_ts = peeked->enqueue_timestamp_ms;
        dequeue_ts = peeked->dequeue_timestamp_ms;
      }
    }
```

- [ ] **Step 2: Update `writeScanResultRow_()` declaration**

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`, replace lines 260-272:

```cpp
    void writeScanResultRow_(const std::string& tracking_id, double rt,
                             int mass_count, int commands_pushed,
                             const std::vector<std::string>& child_ids,
                             int tag_count, const std::string& matched_protein,
                             const std::string& proteoform_sequence,
                             uint64_t enqueue_ts, uint64_t received_ts,
                             const DeconvolvedSpectrum* deconv_spectrum,
                             const std::string& parent_tracking_id,
                             float tic_coverage = 0.0f, int fragment_count = 0,
                             int exploration_group_id = -1, int exploration_metric = 0,
                             int variant_index = -1, int total_variants = 0,
                             double collision_energy = 0.0, double exploration_score = -1.0,
                             double remaining_ratio = -1.0);
```

With:

```cpp
    void writeScanResultRow_(const std::string& tracking_id, double rt,
                             int mass_count, int commands_pushed,
                             const std::vector<std::string>& child_ids,
                             int tag_count, const std::string& matched_protein,
                             const std::string& proteoform_sequence,
                             uint64_t enqueue_ts, uint64_t dequeue_ts, uint64_t received_ts,
                             const DeconvolvedSpectrum* deconv_spectrum,
                             const std::string& parent_tracking_id,
                             float tic_coverage = 0.0f, int fragment_count = 0,
                             int exploration_group_id = -1, int exploration_metric = 0,
                             int variant_index = -1, int total_variants = 0,
                             double collision_energy = 0.0, double exploration_score = -1.0,
                             double remaining_ratio = -1.0);
```

- [ ] **Step 3: Update `writeScanResultRow_()` definition — signature and duration calculations**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`, replace lines 317-337:

```cpp
  void FLASHIda::writeScanResultRow_(const std::string& tracking_id, double rt,
                                      int mass_count, int commands_pushed,
                                      const std::vector<std::string>& child_ids,
                                      int tag_count, const std::string& matched_protein,
                                      const std::string& proteoform_sequence,
                                      uint64_t enqueue_ts, uint64_t received_ts,
                                      const DeconvolvedSpectrum* deconv_spectrum,
                                      const std::string& parent_tracking_id,
                                      float tic_coverage, int fragment_count,
                                      int exploration_group_id, int exploration_metric,
                                      int variant_index, int total_variants,
                                      double collision_energy, double exploration_score,
                                      double remaining_ratio)
  {
    if (!results_tsv_stream_.is_open()) return;

    auto now = std::chrono::steady_clock::now();
    uint64_t resolve_ts = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    uint64_t duration = (enqueue_ts > 0) ? (resolve_ts - enqueue_ts) : 0;
    uint64_t duration_received = (enqueue_ts > 0 && received_ts > 0) ? (received_ts - enqueue_ts) : 0;
```

With:

```cpp
  void FLASHIda::writeScanResultRow_(const std::string& tracking_id, double rt,
                                      int mass_count, int commands_pushed,
                                      const std::vector<std::string>& child_ids,
                                      int tag_count, const std::string& matched_protein,
                                      const std::string& proteoform_sequence,
                                      uint64_t enqueue_ts, uint64_t dequeue_ts, uint64_t received_ts,
                                      const DeconvolvedSpectrum* deconv_spectrum,
                                      const std::string& parent_tracking_id,
                                      float tic_coverage, int fragment_count,
                                      int exploration_group_id, int exploration_metric,
                                      int variant_index, int total_variants,
                                      double collision_energy, double exploration_score,
                                      double remaining_ratio)
  {
    if (!results_tsv_stream_.is_open()) return;

    auto now = std::chrono::steady_clock::now();
    uint64_t resolve_ts = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    uint64_t duration = (enqueue_ts > 0) ? (resolve_ts - enqueue_ts) : 0;
    uint64_t duration_received = (enqueue_ts > 0 && received_ts > 0) ? (received_ts - enqueue_ts) : 0;
    uint64_t queue_duration = (dequeue_ts > 0 && enqueue_ts > 0) ? (dequeue_ts - enqueue_ts) : 0;
    uint64_t instrument_duration = (received_ts > 0 && dequeue_ts > 0) ? (received_ts - dequeue_ts) : 0;
    uint64_t processing_duration = (received_ts > 0) ? (resolve_ts - received_ts) : 0;
```

- [ ] **Step 4: Add new columns to TSV header**

In the same file, replace lines 96-103:

```cpp
        results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\treceived_ts\tduration_received_ms\trt\t"
                            << "mass_count\tcommands_pushed\tchild_ids\t"
                            << "tag_count\tmatched_protein\tproteoform_sequence\t"
                            << "tic_coverage\tfragment_count\t"
                            << "exploration_group_id\texploration_metric\t"
                            << "variant_index\ttotal_variants\t"
                            << "collision_energy\texploration_score\tremaining_ratio\t"
                            << "deconv_masses\tdeconv_intensities\tdeconv_min_charge\tdeconv_max_charge\tparent_tracking_id\n";
```

With:

```cpp
        results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\treceived_ts\tduration_received_ms\trt\t"
                            << "mass_count\tcommands_pushed\tchild_ids\t"
                            << "tag_count\tmatched_protein\tproteoform_sequence\t"
                            << "tic_coverage\tfragment_count\t"
                            << "exploration_group_id\texploration_metric\t"
                            << "variant_index\ttotal_variants\t"
                            << "collision_energy\texploration_score\tremaining_ratio\t"
                            << "deconv_masses\tdeconv_intensities\tdeconv_min_charge\tdeconv_max_charge\tparent_tracking_id\t"
                            << "dequeue_ts\tqueue_duration_ms\tinstrument_duration_ms\tprocessing_duration_ms\n";
```

- [ ] **Step 5: Append new columns to TSV row**

In the same file, replace line 400:

```cpp
    results_tsv_stream_ << "\t" << parent_tracking_id << "\n";
```

With:

```cpp
    results_tsv_stream_ << "\t" << parent_tracking_id
                        << "\t" << dequeue_ts
                        << "\t" << queue_duration
                        << "\t" << instrument_duration
                        << "\t" << processing_duration << "\n";
```

- [ ] **Step 6: Update all 5 call sites to pass `dequeue_ts`**

Each call site currently passes `enqueue_ts, received_ts`. Insert `dequeue_ts` between them.

**Call site 1** — MS1 path (line 653-655):

Replace:
```cpp
      writeScanResultRow_(id_str, rt_min, all_mass_count, commands_pushed,
                          child_ids, 0, "", "", enqueue_ts, received_ts,
                          &deconv_.deconvolvedMS1(), "");
```
With:
```cpp
      writeScanResultRow_(id_str, rt_min, all_mass_count, commands_pushed,
                          child_ids, 0, "", "", enqueue_ts, dequeue_ts, received_ts,
                          &deconv_.deconvolvedMS1(), "");
```

**Call site 2** — MS2 exploration (line 699-705):

Replace:
```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            ms2_spec, parent_id,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score, info.remaining_ratio);
```
With:
```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, dequeue_ts, received_ts,
                            ms2_spec, parent_id,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score, info.remaining_ratio);
```

**Call site 3** — MS2 non-exploration (line 782-786):

Replace:
```cpp
      writeScanResultRow_(id_str, rt_min, ms2_mass_count, commands_pushed,
                          child_ids, tag_count, nlr.matched_protein, nlr.proteoform_sequence,
                          enqueue_ts, received_ts,
                          ms2_spec, parent_id,
                          nlr.tic_coverage, nlr.fragment_count);
```
With:
```cpp
      writeScanResultRow_(id_str, rt_min, ms2_mass_count, commands_pushed,
                          child_ids, tag_count, nlr.matched_protein, nlr.proteoform_sequence,
                          enqueue_ts, dequeue_ts, received_ts,
                          ms2_spec, parent_id,
                          nlr.tic_coverage, nlr.fragment_count);
```

**Call site 4** — MS3 exploration (line 814-821):

Replace:
```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count,
                            static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            ms3_spec, parent_id,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
```
With:
```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count,
                            static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, dequeue_ts, received_ts,
                            ms3_spec, parent_id,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
```

**Call site 5** — MS3 non-exploration (line 851-853):

Replace:
```cpp
      writeScanResultRow_(id_str, rt_min, ms3_mass_count, 0,
                          {}, 0, "", "", enqueue_ts, received_ts,
                          ms3_spec, parent_id);
```
With:
```cpp
      writeScanResultRow_(id_str, rt_min, ms3_mass_count, 0,
                          {}, 0, "", "", enqueue_ts, dequeue_ts, received_ts,
                          ms3_spec, parent_id);
```

- [ ] **Step 7: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
                   src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git -C OpenMS commit -m "Add dequeue_ts and 3 granular duration columns to results.tsv"
```

---

### Task 5: Update submodule pointers and push

- [ ] **Step 1: Update submodule pointers in parent repo**

```bash
git add OpenMS FlashIDA
git commit -m "Update submodules: granular timing columns in results.tsv"
```

- [ ] **Step 2: Push OpenMS submodule**

```bash
git -C OpenMS push origin flashida-v9-bridge
```

Wait for `build-dlls` workflow to trigger (auto-triggers on push to `flashida-v9-bridge`). Read hook output for the workflow run URL.

- [ ] **Step 3: Push parent repo**

```bash
git push origin phase-11
```

Wait for `flashida-ci` workflow to trigger. Read hook output for the workflow run URL.

- [ ] **Step 4: After build-dlls completes, download and commit new DLLs**

```bash
rm -rf /tmp/dll-extract && mkdir /tmp/dll-extract
gh run download <RUN_ID> -R t0mdavid-m/OpenMS -n selected-bin-artifacts -D /tmp/dll-extract
cp /tmp/dll-extract/*.dll FlashIDA/dll/
git -C FlashIDA add dll/
git -C FlashIDA commit -m "Update OpenMS DLLs with dequeue_timestamp_ms struct change"
git add FlashIDA
git commit -m "Update FlashIDA submodule: new DLLs with dequeue_timestamp_ms"
git push origin phase-11
```

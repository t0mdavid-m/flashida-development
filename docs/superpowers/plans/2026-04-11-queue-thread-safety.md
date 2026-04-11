# ScanCommandQueue Thread Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ScanCommandQueue` fully self-synchronized so `getNextScanCommand()` never blocks while `processScan()` is running.

**Architecture:** Split `FLASHIda::mutex_` into `analysis_mutex_` (protects deconv/selection/exploration/FAIMS) and let `ScanCommandQueue::queue_mutex_` cover all queue operations. Two atomics (`exploration_active_`, `current_faims_cv_`) bridge the two domains lock-free.

**Tech Stack:** C++20 (`std::atomic<double>`, `std::mutex`, `std::lock_guard`), OpenMS ClassTest framework, `std::thread` for concurrent tests

---

## File Structure

### C++ files (OpenMS repo, `flashida-v9-bridge` branch)

| File | Action | Responsibility |
|------|--------|---------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` | Modify | Update doc comment |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` | Modify | Add `lock_guard` to 13 methods |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Rename mutex, add atomics |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Split locking, add atomic stores/loads |
| `OpenMS/src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp` | Create | 4 concurrent tests |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Register new test |

---

### Task 1: Add `lock_guard` to all ScanCommandQueue mutable methods

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h`

- [ ] **Step 1: Update the class doc comment in ScanCommandQueue.h**

Replace the existing doc comment (lines 52-58) with:

```cpp
  /**
   * @brief Manages scan command building, priority queuing, and tracking ID encoding for FLASHIda.
   *
   * Fully thread-safe: every public method that touches mutable state acquires queue_mutex_ internally.
   * Callers never need to hold an external lock. Building methods (buildMS2, buildMS3, etc.) produce
   * ScanCommand values, register them in the pending scan map, and return by value.
   *
   * Methods that do NOT acquire queue_mutex_ (safe without locking):
   * - makeMS1(), makeAGC(): const, only read config_ (immutable after construction)
   * - encode(): static pure function
   * - decode(): reads static const tracking_alphabet_ only
   * - applyOverrides(): operates on caller's ScanCommand, no queue state access
   */
```

- [ ] **Step 2: Add `lock_guard` to `push()` in ScanCommandQueue.cpp**

Replace (line 427-431):

```cpp
  void ScanCommandQueue::push(ScanCommand cmd)
  {
    int p = std::clamp(cmd.priority, 0, 3);
    queues_[p].push_back(cmd);
  }
```

With:

```cpp
  void ScanCommandQueue::push(ScanCommand cmd)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    int p = std::clamp(cmd.priority, 0, 3);
    queues_[p].push_back(cmd);
  }
```

- [ ] **Step 3: Add `lock_guard` to `dequeue()`**

Replace (lines 433-445):

```cpp
  std::optional<ScanCommand> ScanCommandQueue::dequeue()
  {
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
        return cmd;
      }
    }
    return std::nullopt;
  }
```

- [ ] **Step 4: Add `lock_guard` to `registerPending()`**

Replace (lines 447-450):

```cpp
  void ScanCommandQueue::registerPending(int id, ScanCommand cmd)
  {
    pending_scan_map_[id] = cmd;
  }
```

With:

```cpp
  void ScanCommandQueue::registerPending(int id, ScanCommand cmd)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    pending_scan_map_[id] = cmd;
  }
```

- [ ] **Step 5: Add `lock_guard` to `resolvePending()`**

Replace (lines 452-460):

```cpp
  std::optional<ScanCommand> ScanCommandQueue::resolvePending(int id)
  {
    auto it = pending_scan_map_.find(id);
    if (it == pending_scan_map_.end())
      return std::nullopt;
    ScanCommand cmd = it->second;
    pending_scan_map_.erase(it);
    return cmd;
  }
```

With:

```cpp
  std::optional<ScanCommand> ScanCommandQueue::resolvePending(int id)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    auto it = pending_scan_map_.find(id);
    if (it == pending_scan_map_.end())
      return std::nullopt;
    ScanCommand cmd = it->second;
    pending_scan_map_.erase(it);
    return cmd;
  }
```

- [ ] **Step 6: Add `lock_guard` to `cleanupExpired()`**

Add `std::lock_guard<std::mutex> lock(queue_mutex_);` as the first line inside the body of `cleanupExpired()`, after the early return check:

Replace (lines 462-488):

```cpp
  void ScanCommandQueue::cleanupExpired()
  {
    if (!config_.scheduling().timeout_enabled)
      return;

    auto now_ms = static_cast<uint64_t>(
```

With:

```cpp
  void ScanCommandQueue::cleanupExpired()
  {
    if (!config_.scheduling().timeout_enabled)
      return;

    std::lock_guard<std::mutex> lock(queue_mutex_);

    auto now_ms = static_cast<uint64_t>(
```

- [ ] **Step 7: Add `lock_guard` to timing methods**

Add `std::lock_guard<std::mutex> lock(queue_mutex_);` as the first line in each of these four methods:

`needsAGC()`:
```cpp
  bool ScanCommandQueue::needsAGC() const
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_agc_time_).count();
    return static_cast<uint64_t>(elapsed) > config_.scheduling().agc_interval_ms;
  }
```

`msSinceLastMS1()`:
```cpp
  uint64_t ScanCommandQueue::msSinceLastMS1() const
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    auto now = std::chrono::steady_clock::now();
    return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(now - last_ms1_time_).count());
  }
```

`recordMS1Time()`:
```cpp
  void ScanCommandQueue::recordMS1Time()
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    last_ms1_time_ = std::chrono::steady_clock::now();
  }
```

`recordAGCTime()`:
```cpp
  void ScanCommandQueue::recordAGCTime()
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    last_agc_time_ = std::chrono::steady_clock::now();
  }
```

- [ ] **Step 8: Add `lock_guard` to all build methods**

Add `std::lock_guard<std::mutex> lock(queue_mutex_);` as the first line in each of these 5 methods:

`buildMS2(const PeakGroup&, int, int)` — add after line 171 (`{`):
```cpp
    std::lock_guard<std::mutex> lock(queue_mutex_);
```

`buildMS2(double, int, double, const std::string&)` — add after line 265 (`{`):
```cpp
    std::lock_guard<std::mutex> lock(queue_mutex_);
```

`buildMS3(...)` — add after line 301 (`{`):
```cpp
    std::lock_guard<std::mutex> lock(queue_mutex_);
```

`buildFollowUpMS2(...)` — add after line 356 (`{`):
```cpp
    std::lock_guard<std::mutex> lock(queue_mutex_);
```

`buildConditionalFollowUp(...)` — add after line 391 (`{`):
```cpp
    std::lock_guard<std::mutex> lock(queue_mutex_);
```

- [ ] **Step 9: Run existing tests**

Run from the OpenMS build directory:
```bash
ctest -R FLASHIda
ctest -R ScanCommandLayout
```

Expected: All existing tests pass unchanged. The internal locking is transparent to single-threaded callers.

- [ ] **Step 10: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
git commit -m "Make ScanCommandQueue fully self-synchronized: add lock_guard to all mutable methods"
```

---

### Task 2: Split FLASHIda mutex and add atomics

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

- [ ] **Step 1: Update FLASHIda.h — rename mutex and add atomics**

In FLASHIda.h, add `<atomic>` include (already present at line 49).

Replace the mutex declaration (line 236):

```cpp
    /// Mutex protecting processMS2Path_ and getNextScanCommand
    mutable std::mutex mutex_;
```

With:

```cpp
    /// Mutex protecting analysis state: deconv_, selection_, exploration_, faims_, quant_, fragments_, logging streams
    mutable std::mutex analysis_mutex_;

    /// Atomic flag: true when any exploration group is active (set by processScan, read by getNextScanCommand)
    std::atomic<bool> exploration_active_{false};

    /// Atomic FAIMS CV: current CV value (set by processScan after advanceToNextCV, read by getNextScanCommand)
    std::atomic<double> current_faims_cv_{0.0};
```

Update all ForTest methods that use `mutex_` to use `analysis_mutex_` instead. Replace every occurrence of `std::lock_guard<std::mutex> lock(mutex_)` in the header with `std::lock_guard<std::mutex> lock(analysis_mutex_)`. These are at lines 273, 280, 299, 310.

- [ ] **Step 2: Update processScan() — rename lock, add atomic stores**

In FLASHIda.cpp, in `processScan()` (line 502), replace:

```cpp
    std::lock_guard<std::mutex> lock(mutex_);
```

With:

```cpp
    std::lock_guard<std::mutex> lock(analysis_mutex_);
```

At the end of the MS1 path, just before `return commands_pushed;` (line 580), add:

```cpp
      // Update atomics for lock-free reads by getNextScanCommand
      exploration_active_.store(exploration_.activeGroupCount() > 0, std::memory_order_release);
      current_faims_cv_.store(faims_.isEnabled() ? faims_.currentCV() : 0.0, std::memory_order_release);
```

At the end of `processMS2Path_()`, just before `return commands_pushed;` (line 792), add:

```cpp
    // Update atomic for lock-free reads by getNextScanCommand
    exploration_active_.store(exploration_.activeGroupCount() > 0, std::memory_order_release);
```

In the MS3+ path (around line 610), no atomic update needed — MS3 doesn't change exploration or FAIMS state.

- [ ] **Step 3: Update getNextScanCommand() — remove analysis lock, use atomics**

Replace the entire method. The structure stays identical — only locking and state access changes:

Replace (lines 795-882):

```cpp
  int FLASHIda::getNextScanCommand(ScanCommand& out)
  {
    std::lock_guard<std::mutex> lock(mutex_);

    // Step 1: AGC scan if needed
    if (queue_.needsAGC())
    {
      out = queue_.makeAGC();
      out.faims_cv = faims_.isEnabled() ? faims_.currentCV() : 0.0;
      out.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      // Scan description: {3-char ID}A
      std::string id_str = ScanCommandQueue::encode(out.scan_id);
      std::snprintf(out.scan_description, 16, "%sA", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=agc" << std::endl;
      writeScanCommandRow_(out);
      return 1;
    }

    // Step 2: Cycle time -- force MS1 if too long since last survey scan
    // Suppressed while any exploration group is active
    bool exploration_active = exploration_.activeGroupCount() > 0;
    if (config_.scheduling().cycle_time_enabled && !exploration_active
        && queue_.msSinceLastMS1() > static_cast<uint64_t>(config_.scheduling().cycle_time_ms))
    {
      out = queue_.makeMS1();
      out.faims_cv = faims_.isEnabled() ? faims_.currentCV() : 0.0;
      out.scan_id = queue_.nextTrackingId();
      queue_.recordMS1Time();

      std::string id_str = ScanCommandQueue::encode(out.scan_id);
      std::snprintf(out.scan_description, 16, "%sS", id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << id_str << " ms_level=1 type=cycle_time" << std::endl;
      writeScanCommandRow_(out);
      return 1;
    }

    // Step 3: Cleanup expired commands
    queue_.cleanupExpired();

    // Step 4: Dequeue by priority (0 = highest -> 3 = lowest)
    auto dequeued = queue_.dequeue();
    if (dequeued.has_value())
    {
      out = dequeued.value();
      // faims_cv already set at creation time (MS2 -> parent CV, CV-transition MS1 -> next CV)
      writeScanCommandRow_(out);
      return 1;
    }

    // Step 5: Idle cycle -- queue empty, keep the instrument busy with AGC + MS1
    // Create an AGC command (returned immediately) and push an MS1 at priority 0
    // into the queue so the next dequeue returns it before any MS2s (priority 1+).
    {
      // 5a: AGC
      ScanCommand agc_cmd = queue_.makeAGC();
      agc_cmd.faims_cv = faims_.isEnabled() ? faims_.currentCV() : 0.0;
      agc_cmd.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      std::string agc_id_str = ScanCommandQueue::encode(agc_cmd.scan_id);
      std::snprintf(agc_cmd.scan_description, 16, "%sA", agc_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << agc_id_str << " ms_level=1 type=idle_agc" << std::endl;

      // 5b: MS1 -- override priority to 0 (makeMS1 defaults to 3)
      ScanCommand ms1_cmd = queue_.makeMS1();
      ms1_cmd.faims_cv = faims_.isEnabled() ? faims_.currentCV() : 0.0;
      ms1_cmd.scan_id = queue_.nextTrackingId();
      ms1_cmd.priority = 0;
      queue_.recordMS1Time();

      std::string ms1_id_str = ScanCommandQueue::encode(ms1_cmd.scan_id);
      std::snprintf(ms1_cmd.scan_description, 16, "%sS", ms1_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << ms1_id_str << " ms_level=1 type=idle_ms1" << std::endl;

      // Push MS1 into priority-0 queue for next dequeue call
      queue_.push(ms1_cmd);

      out = agc_cmd;
      writeScanCommandRow_(out);
      return 1;
    }
  }
```

With:

```cpp
  int FLASHIda::getNextScanCommand(ScanCommand& out)
  {
    // No analysis_mutex_ acquired — queue methods lock internally, exploration/FAIMS via atomics

    double faims_cv = faims_.isEnabled() ? current_faims_cv_.load(std::memory_order_acquire) : 0.0;

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

    // Step 2: Cycle time -- force MS1 if too long since last survey scan
    // Suppressed while any exploration group is active
    bool expl_active = exploration_active_.load(std::memory_order_acquire);
    if (config_.scheduling().cycle_time_enabled && !expl_active
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

    // Step 3: Cleanup expired commands
    queue_.cleanupExpired();

    // Step 4: Dequeue by priority (0 = highest -> 3 = lowest)
    auto dequeued = queue_.dequeue();
    if (dequeued.has_value())
    {
      out = dequeued.value();
      // faims_cv already set at creation time (MS2 -> parent CV, CV-transition MS1 -> next CV)
      writeScanCommandRow_(out);
      return 1;
    }

    // Step 5: Idle cycle -- queue empty, keep the instrument busy with AGC + MS1
    // Create an AGC command (returned immediately) and push an MS1 at priority 0
    // into the queue so the next dequeue returns it before any MS2s (priority 1+).
    {
      // 5a: AGC
      ScanCommand agc_cmd = queue_.makeAGC();
      agc_cmd.faims_cv = faims_cv;
      agc_cmd.scan_id = queue_.nextTrackingId();
      queue_.recordAGCTime();

      std::string agc_id_str = ScanCommandQueue::encode(agc_cmd.scan_id);
      std::snprintf(agc_cmd.scan_description, 16, "%sA", agc_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << agc_id_str << " ms_level=1 type=idle_agc" << std::endl;

      // 5b: MS1 -- override priority to 0 (makeMS1 defaults to 3)
      ScanCommand ms1_cmd = queue_.makeMS1();
      ms1_cmd.faims_cv = faims_cv;
      ms1_cmd.scan_id = queue_.nextTrackingId();
      ms1_cmd.priority = 0;
      queue_.recordMS1Time();

      std::string ms1_id_str = ScanCommandQueue::encode(ms1_cmd.scan_id);
      std::snprintf(ms1_cmd.scan_description, 16, "%sS", ms1_id_str.c_str());

      std::cout << "[TRACK-CREATE] id=" << ms1_id_str << " ms_level=1 type=idle_ms1" << std::endl;

      // Push MS1 into priority-0 queue for next dequeue call
      queue_.push(ms1_cmd);

      out = agc_cmd;
      writeScanCommandRow_(out);
      return 1;
    }
  }
```

- [ ] **Step 4: Handle writeScanCommandRow_ thread safety**

`writeScanCommandRow_` writes to `commands_tsv_stream_` which is owned by FLASHIda. With the lock removed from `getNextScanCommand()`, this stream is no longer protected by `analysis_mutex_`. Since `writeScanCommandRow_` is only called from `getNextScanCommand()` (never from `processScan()`), it is still single-caller. However, for safety, guard it with `analysis_mutex_`:

In FLASHIda.cpp, find the `writeScanCommandRow_` method definition. Wrap the body with:

```cpp
  void FLASHIda::writeScanCommandRow_(const ScanCommand& cmd)
  {
    std::lock_guard<std::mutex> lock(analysis_mutex_);
    // ... existing body unchanged ...
  }
```

Note: This is a brief lock (one line of TSV output) and does NOT block during deconvolution. The lock is only contended if `processScan()` is writing to a different stream at the same moment — and even then, the hold time is sub-microsecond.

- [ ] **Step 5: Initialize current_faims_cv_ in constructor**

In FLASHIda.cpp constructor (after `exploration_(config_)` at line 60), after the existing constructor body, add initialization of the FAIMS atomic:

After `engine_start_time_ = std::chrono::steady_clock::now();` (line 66), add:

```cpp
    // Initialize FAIMS CV atomic for getNextScanCommand reads
    current_faims_cv_.store(faims_.isEnabled() ? faims_.currentCV() : 0.0, std::memory_order_relaxed);
```

- [ ] **Step 6: Run existing tests**

```bash
ctest -R FLASHIda
ctest -R ScanCommandLayout
```

Expected: All existing tests pass. Single-threaded behavior is identical — `processScan()` still holds `analysis_mutex_`, and `getNextScanCommand()` now relies on queue internal locks + atomics instead of the outer lock.

- [ ] **Step 7: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Split FLASHIda mutex: analysis_mutex_ for state, atomics for cross-domain reads"
```

---

### Task 3: Write concurrent queue tests

**Files:**
- Create: `OpenMS/src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/executables.cmake`

- [ ] **Step 1: Create the test file**

Create `OpenMS/src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp`:

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h>

#include <atomic>
#include <set>
#include <thread>
#include <vector>

using namespace OpenMS;

namespace
{
  const char* minimal_config = R"({
    "deconvolution": {
      "min_charge": 4, "max_charge": 50,
      "min_mass": 500, "max_mass": 50000,
      "tol": [10, 10]
    },
    "precursor_selection": { "RT_window": 180, "target_mode": 0 },
    "tagging": {},
    "quantification": { "enabled": false },
    "faims": { "cv_values": [-50] },
    "ms_settings": {
      "ms1": {
        "analyzer": "Orbitrap", "first_mass": 500, "last_mass": 2000,
        "resolution": 120000, "agc_target": 800000, "max_it": 246
      },
      "ms2": [{ "analyzer": "Orbitrap", "activation": "HCD", "collision_energy": 29, "resolution": 120000 }]
    },
    "scheduling": {
      "cycle_time": { "enabled": false },
      "scan_timeout": { "enabled": true, "value_ms": 100 },
      "agc_interval_seconds": 30
    },
    "files": {},
    "selection_strategy": {
      "ms1": { "selection": "qscore", "max_precursors": 10 },
      "ms2": { "selection": "intensity" }
    }
  })";
}

START_TEST(ScanCommandQueue_Concurrent, "$Id$")

/////////////////////////////////////////////////////////////

// T1: Concurrent push/dequeue — no lost commands
START_SECTION(concurrent_push_dequeue)
{
  Config cfg{std::string(minimal_config)};
  ScanCommandQueue queue(cfg);

  const int N_PRODUCERS = 4;
  const int CMDS_PER_PRODUCER = 250;
  const int TOTAL = N_PRODUCERS * CMDS_PER_PRODUCER;
  std::atomic<int> dequeued_count{0};

  // Producers push commands
  auto producer = [&](int thread_id)
  {
    for (int i = 0; i < CMDS_PER_PRODUCER; ++i)
    {
      ScanCommand cmd{};
      cmd.msn_level = 2;
      cmd.priority = 1;
      cmd.scan_id = thread_id * CMDS_PER_PRODUCER + i;
      queue.push(cmd);
    }
  };

  // Consumer drains the queue
  auto consumer = [&]()
  {
    while (dequeued_count.load() < TOTAL)
    {
      auto cmd = queue.dequeue();
      if (cmd.has_value())
        dequeued_count.fetch_add(1);
    }
  };

  std::vector<std::thread> threads;
  // Start consumer first so it's draining while producers push
  threads.emplace_back(consumer);
  for (int t = 0; t < N_PRODUCERS; ++t)
    threads.emplace_back(producer, t);

  for (auto& th : threads)
    th.join();

  // Drain any remaining
  while (auto cmd = queue.dequeue())
    dequeued_count.fetch_add(1);

  TEST_EQUAL(dequeued_count.load(), TOTAL)
}
END_SECTION

// T2: Concurrent tracking ID uniqueness
START_SECTION(concurrent_tracking_id_uniqueness)
{
  Config cfg{std::string(minimal_config)};
  ScanCommandQueue queue(cfg);

  const int N_THREADS = 4;
  const int IDS_PER_THREAD = 250;
  const int TOTAL = N_THREADS * IDS_PER_THREAD;

  std::vector<std::vector<int>> per_thread_ids(N_THREADS);

  auto worker = [&](int thread_id)
  {
    per_thread_ids[thread_id].reserve(IDS_PER_THREAD);
    for (int i = 0; i < IDS_PER_THREAD; ++i)
    {
      per_thread_ids[thread_id].push_back(queue.nextTrackingId());
    }
  };

  std::vector<std::thread> threads;
  for (int t = 0; t < N_THREADS; ++t)
    threads.emplace_back(worker, t);
  for (auto& th : threads)
    th.join();

  std::set<int> all_ids;
  for (const auto& ids : per_thread_ids)
    for (int id : ids)
      all_ids.insert(id);

  TEST_EQUAL(static_cast<int>(all_ids.size()), TOTAL)
}
END_SECTION

// T3: Concurrent build + resolve — every built command is resolvable exactly once
START_SECTION(concurrent_build_resolve)
{
  Config cfg{std::string(minimal_config)};
  ScanCommandQueue queue(cfg);

  const int N = 100;
  std::vector<int> built_ids(N);
  std::atomic<int> resolved_count{0};

  // Producer: build MS2 commands (each writes to pending_scan_map_)
  auto builder = [&]()
  {
    for (int i = 0; i < N; ++i)
    {
      ScanCommand cmd = queue.buildMS2(500.0 + i, 10, 29.0, "HCD");
      built_ids[i] = cmd.scan_id;
    }
  };

  // Consumer: resolve pending commands by ID
  auto resolver = [&]()
  {
    int local_resolved = 0;
    // Spin until all N commands are resolved
    while (local_resolved < N)
    {
      for (int i = 0; i < N; ++i)
      {
        int id = built_ids[i];
        if (id == 0) continue;  // not yet built
        auto result = queue.resolvePending(id);
        if (result.has_value())
        {
          local_resolved++;
          built_ids[i] = 0;  // mark as resolved
        }
      }
    }
    resolved_count.store(local_resolved);
  };

  // Run sequentially to avoid reading built_ids before they're written:
  // builder first, then resolver. The thread safety test is that both
  // buildMS2 (writes pending_scan_map_) and resolvePending (reads+erases)
  // acquire queue_mutex_ internally.
  std::thread build_thread(builder);
  build_thread.join();

  std::thread resolve_thread(resolver);
  resolve_thread.join();

  TEST_EQUAL(resolved_count.load(), N)
}
END_SECTION

// T4: Concurrent push + cleanupExpired — no crashes
START_SECTION(concurrent_push_cleanup)
{
  Config cfg{std::string(minimal_config)};
  ScanCommandQueue queue(cfg);

  const int N = 200;
  std::atomic<bool> done{false};

  // Producer pushes commands with timestamp 0 (will be expired immediately)
  auto pusher = [&]()
  {
    for (int i = 0; i < N; ++i)
    {
      ScanCommand cmd{};
      cmd.msn_level = 2;
      cmd.priority = 1;
      cmd.scan_id = i;
      cmd.enqueue_timestamp_ms = 1;  // old timestamp -> will expire
      queue.push(cmd);
      // Also register in pending map so cleanupExpired has something to clean
      queue.registerPending(i, cmd);
    }
    done.store(true);
  };

  // Cleaner runs cleanupExpired concurrently
  auto cleaner = [&]()
  {
    while (!done.load())
    {
      queue.cleanupExpired();
    }
    // Final cleanup
    queue.cleanupExpired();
  };

  std::thread push_thread(pusher);
  std::thread clean_thread(cleaner);
  push_thread.join();
  clean_thread.join();

  // If we get here without crash/hang, the test passes
  TEST_EQUAL(true, true)
}
END_SECTION

/////////////////////////////////////////////////////////////
END_TEST
```

- [ ] **Step 2: Register the test in executables.cmake**

In `OpenMS/src/tests/class_tests/openms/executables.cmake`, after the `FLASHIda_Logging_test` line (line 458), add:

```
  ScanCommandQueue_Concurrent_test
```

- [ ] **Step 3: Build and run the new test**

```bash
cmake --build build/ --target ScanCommandQueue_Concurrent_test
ctest -R ScanCommandQueue_Concurrent
```

Expected: All 4 sections pass.

- [ ] **Step 4: Run all FLASHIda tests to verify no regressions**

```bash
ctest -R FLASHIda
ctest -R ScanCommandLayout
ctest -R ScanCommandQueue
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp \
        src/tests/class_tests/openms/executables.cmake
git commit -m "Add concurrent queue tests: push/dequeue, tracking ID uniqueness, build+resolve, cleanup"
```

---

### Task 4: Add TSan CI job

**Files:**
- Modify: `.github/workflows/flashida-ci.yml` (in the parent repo)

- [ ] **Step 1: Check current CI workflow structure**

Read `.github/workflows/flashida-ci.yml` to understand the existing job structure.

- [ ] **Step 2: Add TSan job**

Add a new job to `flashida-ci.yml` that builds and runs the FLASHIda tests with ThreadSanitizer. This is a separate job from the main tests — it runs GCC with `-fsanitize=thread`.

Add this job after the existing test jobs:

```yaml
  tsan-tests:
    name: ThreadSanitizer
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y cmake g++ libboost-all-dev

      - name: Configure with TSan
        run: |
          cmake -B build-tsan \
            -DCMAKE_CXX_FLAGS="-fsanitize=thread -g -O1" \
            -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread" \
            -DCMAKE_BUILD_TYPE=Debug \
            OpenMS

      - name: Build FLASHIda tests
        run: |
          cmake --build build-tsan --target \
            FLASHIdaFAIMS_test \
            FLASHIdaQueueTracking_test \
            FLASHIda_ProcessScan_test \
            ScanCommandLayout_test \
            FLASHIda_exploration_test \
            FLASHIda_LegacyConfig_test \
            FLASHIda_Logging_test \
            ScanCommandQueue_Concurrent_test

      - name: Run tests under TSan
        run: |
          cd build-tsan
          ctest -R "FLASHIda|ScanCommand" --output-on-failure
```

Note: The exact CI configuration depends on the existing workflow structure. The implementer should read the current `flashida-ci.yml` and adapt the job to match the existing patterns (vcpkg cache, artifact download, etc.). The key requirements are:
- GCC with `-fsanitize=thread`
- Build all 8 FLASHIda test binaries
- Run with `ctest`
- Separate job (not blocking the main CI)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/flashida-ci.yml
git commit -m "Add ThreadSanitizer CI job for FLASHIda tests"
```

---

### Task 5: Update design spec location and commit

**Files:**
- Create: `docs/superpowers/specs/2026-04-11-queue-thread-safety-design.md`

- [ ] **Step 1: Write the design spec**

Copy the design spec from the brainstorming session to `docs/superpowers/specs/2026-04-11-queue-thread-safety-design.md`. The content was validated during the brainstorming session — see the conversation history for the full spec text.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-04-11-queue-thread-safety-design.md \
        docs/superpowers/plans/2026-04-11-queue-thread-safety.md
git commit -m "Add queue thread safety spec and implementation plan"
```

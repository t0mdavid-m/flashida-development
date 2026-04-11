# ScanCommandQueue Thread Safety: Producer-Consumer Decoupling

## Goal

Make `ScanCommandQueue` fully self-synchronized so that `getNextScanCommand()` (consumer) never blocks while `processScan()` (producer) is running deconvolution. This eliminates instrument idle time during analysis without changing the bridge API or C# code.

## Architecture

Split the single `FLASHIda::mutex_` into two independent synchronization domains:

```
FLASHIda::analysis_mutex_       -- guards deconv_, selection_, exploration_, faims_, quant_, fragments_
ScanCommandQueue::queue_mutex_  -- guards ALL queue state (queues_[], pending_scan_map_,
                                   tracking_id_counter_, timing, build methods)
std::atomic<bool>   exploration_active_   -- set by processScan(), read by getNextScanCommand()
std::atomic<double> current_faims_cv_     -- set by processScan(), read by getNextScanCommand()
```

### Lock acquisition patterns

| Method | `analysis_mutex_` | `queue_mutex_` | Atomics |
|--------|-------------------|----------------|---------|
| `processScan()` | Held for full duration | Acquired briefly per queue op (internal) | Writes both |
| `getNextScanCommand()` | Never | Acquired briefly per queue op (internal) | Reads both |
| `getNextTrackingId()` | Never | Acquired internally | None |

### Key property

`getNextScanCommand()` and `processScan()` can execute concurrently. The only shared state between them is the queue (protected by `queue_mutex_` with microsecond hold times) and two atomics.

## Detailed Design

### ScanCommandQueue internal locking

Every public method on `ScanCommandQueue` that touches mutable state acquires `queue_mutex_` internally. The caller never sees the lock.

**Methods gaining `lock_guard`:**

- `push()`
- `dequeue()`
- `resolvePending()`
- `registerPending()`
- `cleanupExpired()`
- `recordMS1Time()`
- `recordAGCTime()`
- `needsAGC()`
- `msSinceLastMS1()`
- `buildMS2()` (both overloads)
- `buildMS3()`
- `buildFollowUpMS2()`
- `buildConditionalFollowUp()`

**Already locked (no change):** `nextTrackingId()`, `pendingScanMapSize()`, `queueSize()`, `peekPending()`

**Stay unlocked (safe):**

- `makeMS1()`, `makeAGC()` -- const methods, only read `config_` (immutable after construction)
- `encode()` -- static, pure function
- `decode()` -- only reads `tracking_alphabet_` (static const)
- `applyOverrides()` -- operates on caller's `ScanCommand`, reads no queue state

**Internal helper:** `nextTrackingIdInt_()` stays private and unlocked -- all callers hold `queue_mutex_`.

### Changes to `getNextScanCommand()`

The method body stays structurally identical -- same AGC/cycle-time/dequeue/idle logic, same order. Only the synchronization mechanism changes:

- Remove `std::lock_guard<std::mutex> lock(mutex_)`.
- Replace `exploration_.activeGroupCount() > 0` with `exploration_active_.load()`.
- Replace `faims_.currentCV()` with `current_faims_cv_.load()`.
- `faims_.isEnabled()` is const after construction -- no synchronization needed.
- All queue method calls (`needsAGC`, `makeMS1`, `dequeue`, `push`, etc.) lock internally.

### Changes to `processScan()`

Structurally identical. Two changes:

1. Rename lock: `std::lock_guard<std::mutex> lock(analysis_mutex_)`.
2. Add atomic stores after state changes, at the end of each path:

```cpp
// After MS1 path (exploration initiation + FAIMS advance):
exploration_active_.store(exploration_.activeGroupCount() > 0);
current_faims_cv_.store(faims_.currentCV());

// After MS2 path (exploration may have changed):
exploration_active_.store(exploration_.activeGroupCount() > 0);
```

Atomic stores happen after all analysis state is consistent.

### Atomics rationale

**`exploration_active_`**: `getNextScanCommand()` reads this to decide whether to suppress cycle-time MS1 scans. Worst-case staleness: one extra or one fewer MS1 scan during a transition window. Harmless.

**`current_faims_cv_`**: `getNextScanCommand()` stamps this onto AGC/MS1/idle commands. `faims_.isEnabled()` is const after construction. `std::atomic<double>` is supported in C++20.

## File Changes

### Modified files

| File | Change |
|------|--------|
| `FLASHIda.h` | Rename `mutex_` to `analysis_mutex_`. Add `std::atomic<bool> exploration_active_{false}`. Add `std::atomic<double> current_faims_cv_{0.0}`. |
| `FLASHIda.cpp` | `processScan()`: rename lock, add atomic stores. `getNextScanCommand()`: remove lock, replace exploration/FAIMS reads with atomic loads. Guard `writeScanCommandRow_` with `analysis_mutex_`. |
| `ScanCommandQueue.cpp` | Add `lock_guard` to 13 methods. |
| `ScanCommandQueue.h` | Update doc comment to reflect full thread safety. |

### New files

| File | Purpose |
|------|---------|
| `src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp` | 4 concurrent tests |

### Modified CI

| File | Change |
|------|--------|
| `executables.cmake` | Register `ScanCommandQueue_Concurrent_test` |
| `flashida-ci.yml` | Add separate TSan CI job for existing FLASHIda test binaries (GCC only) |

### Not modified

ScanCommand.h, Config.h/cpp, bridge functions (FLASHIdaBridgeFunctions.h/cpp), C# code, pyOpenMS bindings.

## Testing

### Layer 1: Dedicated concurrent queue test

New test binary `ScanCommandQueue_Concurrent_test` with 4 tests:

- **T1: Concurrent push/dequeue** -- N producer threads push commands, M consumer threads dequeue. Verify total in == total out, no duplicates, no lost commands.
- **T2: Concurrent tracking ID uniqueness** -- N threads call `nextTrackingId()` concurrently. Verify all IDs unique (C++ equivalent of C# CT32 stress test).
- **T3: Concurrent build + resolve** -- Producer calls `buildMS2()` (writes pending map), consumer calls `resolvePending()`. Verify all built commands resolvable exactly once.
- **T4: Concurrent push + cleanupExpired** -- Producer pushes commands with old timestamps, consumer calls `cleanupExpired()`. Verify no crashes, no data corruption.

### Layer 2: TSan on existing tests

Separate CI job running existing FLASHIda test binaries under ThreadSanitizer (`-fsanitize=thread`). GCC/Clang only (not MSVC). Catches races in full integration paths that unit tests might miss.

## Future Steps (documented, not in scope)

- **Full decoupling (B)**: Move AGC/cycle-time/idle logic out of `getNextScanCommand()` so it becomes a pure dequeue. Eliminates remaining producer logic on the consumer path.
- **Async pipeline (C)**: `processScan()` returns immediately, buffering scan data for a worker thread. Queue is the handoff point. Requires C# changes to handle async results.

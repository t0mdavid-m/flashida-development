# Granular Timing Columns Design Spec

**Date:** 2026-04-15
**Branch:** `phase-11` (parent) / `flashida-v9-bridge` (OpenMS submodule)
**Scope:** Add `dequeue_timestamp_ms` to `ScanCommand`, add 4 new columns to results.tsv (`dequeue_ts`, `queue_duration_ms`, `instrument_duration_ms`, `processing_duration_ms`). All existing columns preserved.

---

## Problem

`results.tsv` has two timing columns:

- `duration_ms` = resolve_ts - enqueue_ts (total end-to-end)
- `duration_received_ms` = received_ts - enqueue_ts (enqueue to instrument return)

These lump three distinct phases into one or two numbers:

1. **Queue wait** — how long the command sat in the priority queue before being sent to the instrument
2. **Instrument turnaround** — how long the instrument took to execute the scan and return data
3. **C++ processing** — how long deconvolution, scoring, exploration, and fragment analysis took

There is no dequeue timestamp to separate phases 1 and 2. The only way to estimate instrument time is `duration_received_ms - queue_time`, but `queue_time` is not recorded.

---

## Design

### 1. New struct field: `dequeue_timestamp_ms`

**File:** `ScanCommand.h:80`

Add `uint64_t dequeue_timestamp_ms` immediately after `enqueue_timestamp_ms`. Shrink `reserved_` from 700 to 692 bytes. Struct stays 2048 bytes.

```cpp
uint64_t enqueue_timestamp_ms;   ///< Timestamp when command was enqueued (steady_clock ms)
uint64_t dequeue_timestamp_ms;   ///< Timestamp when command was dequeued/sent to instrument (steady_clock ms)
```

Update the C# mirror in `FLASHIdaWrapper.cs`:

```csharp
public ulong EnqueueTimestampMs;
public ulong DequeueTimestampMs;
```

### 2. Stamp dequeue time in `ScanCommandQueue::dequeue()`

**File:** `ScanCommandQueue.cpp:379-392`

Stamp `cmd.dequeue_timestamp_ms = steady_clock::now()` before returning.

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
      return cmd;
    }
  }
  return std::nullopt;
}
```

### 3. Stamp bypass commands in `getNextScanCommand()`

**File:** `FLASHIda.cpp:858-950`

Commands created on-the-fly (never going through push/dequeue) must have both timestamps set to `now()` at the moment they are handed to the instrument. This applies to:

- **Step 1 AGC** (line 866): `out = queue_.makeAGC()` — stamp both `enqueue_timestamp_ms` and `dequeue_timestamp_ms` before `return 1` at line 877
- **Step 5 idle AGC** (line 922): `agc_cmd = queue_.makeAGC()` — stamp both before `return 1` at line 948

Cycle-time MS1 (Step 2, line 887) and idle MS1 (Step 5b, line 933) go through `queue_.push()` which stamps `enqueue_timestamp_ms`, then through `dequeue()` which stamps `dequeue_timestamp_ms` — no change needed.

For bypass commands: `enqueue_timestamp_ms == dequeue_timestamp_ms`, so `queue_duration_ms = 0`. Correct — they never waited.

### 4. Pass `dequeue_ts` through `processScan()` to `writeScanResultRow_()`

**File:** `FLASHIda.cpp:580-586`

`processScan()` already reads `enqueue_ts` from `queue_.peekPending(tracking_id)`. Read `dequeue_timestamp_ms` from the same lookup:

```cpp
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

Add `uint64_t dequeue_ts` parameter to `writeScanResultRow_()` signature (after `enqueue_ts`). Update all 5 call sites to pass `dequeue_ts`.

### 5. New TSV columns

**File:** `FLASHIda.cpp:96-103` (header), `FLASHIda.cpp:333-366` (row)

Append 4 new columns after the existing `parent_tracking_id` column (last current column):

| Column | Calculation | Zero when |
|---|---|---|
| `dequeue_ts` | raw `dequeue_timestamp_ms` value | never (bypass commands get `now()`) |
| `queue_duration_ms` | `dequeue_ts - enqueue_ts` | bypass commands (both equal `now()`) |
| `instrument_duration_ms` | `received_ts - dequeue_ts` | `received_ts == 0` (MS1 scans where instrument doesn't return tracked data) |
| `processing_duration_ms` | `resolve_ts - received_ts` | `received_ts == 0` |

All existing columns (`resolve_ts`, `duration_ms`, `received_ts`, `duration_received_ms`, etc.) are unchanged. The three new durations are complementary to the existing ones:

- `duration_ms` = `queue_duration_ms` + `instrument_duration_ms` + `processing_duration_ms`
- `duration_received_ms` = `queue_duration_ms` + `instrument_duration_ms`

### 6. `pending_scan_map_` timing propagation

**File:** `ScanCommandQueue.cpp:368-377` (push), `ScanCommandQueue.cpp:379-392` (dequeue)

`push()` stores the command in `pending_scan_map_[cmd.scan_id]` at line 374 **before** the command enters the priority queue. At push time, `dequeue_timestamp_ms` is 0. After `dequeue()` stamps it, the dequeued copy has the timestamp but `pending_scan_map_` still has `dequeue_timestamp_ms = 0`.

`processScan()` reads timestamps via `peekPending(tracking_id)` (line 583), which returns from `pending_scan_map_`. So the map must have the dequeue timestamp.

Fix: Update `pending_scan_map_` inside `dequeue()` after stamping:

```cpp
cmd.dequeue_timestamp_ms = static_cast<uint64_t>(...);
pending_scan_map_[cmd.scan_id] = cmd;  // update with dequeue timestamp
return cmd;
```

**Bypass commands (AGC):** Step 1 AGC (line 866) and Step 5a idle AGC (line 922) skip `push()` entirely, so they have no `pending_scan_map_` entry. When the instrument returns their results, `peekPending()` returns `nullopt` and all timestamps are 0.

Fix: After stamping both `enqueue_timestamp_ms` and `dequeue_timestamp_ms` on bypass commands, insert them into `pending_scan_map_` via a new `ScanCommandQueue::registerPending(ScanCommand)` method that only writes to the map (no queue insertion):

```cpp
void ScanCommandQueue::registerPending(const ScanCommand& cmd)
{
  std::lock_guard<std::mutex> lock(queue_mutex_);
  pending_scan_map_[cmd.scan_id] = cmd;
}
```

Call `queue_.registerPending(out)` after stamping in Step 1 and Step 5a.

---

## Files Modified

| File | Nature of change |
|---|---|
| `ScanCommand.h` | Add `dequeue_timestamp_ms` field, shrink `reserved_` 700→692 |
| `ScanCommandQueue.cpp` | Stamp `dequeue_timestamp_ms` in `dequeue()`, update `pending_scan_map_`, add `registerPending()` |
| `ScanCommandQueue.h` | Declare `registerPending()` |
| `FLASHIda.cpp` | Stamp bypass commands, read `dequeue_ts` in `processScan()`, add parameter + columns to `writeScanResultRow_()`, update header |
| `FLASHIda.h` | Update `writeScanResultRow_()` declaration (add `dequeue_ts` param) |
| `FLASHIdaWrapper.cs` | Add `DequeueTimestampMs` to C# `ScanCommand` struct, shrink reserved |
| `ScanCommandLayout_test.cpp` | Assert offset of new field, verify struct still 2048 |
| `ScanCommandLayoutTests.cs` | Assert offset of new field in C# struct |

---

## Tests

### `ScanCommandLayout_test.cpp`

Add `offsetof(ScanCommand, dequeue_timestamp_ms)` assertion (expected: offset of `enqueue_timestamp_ms` + 8). Verify total struct size still 2048.

### `ScanCommandLayoutTests.cs`

Add `Marshal.OffsetOf<ScanCommand>("DequeueTimestampMs")` assertion. Verify total struct size still 2048.

### Golden file update

`FlashIDA/test-data/golden/` files that parse results.tsv column count may need updating if the regression runner validates column count. The 4 new columns are appended at the end, so positional parsing of existing columns is unaffected.

---

## Out of Scope

- `commands.tsv` changes (already has `enqueue_ts`; could add `dequeue_ts` later)
- Removing existing `duration_ms` / `duration_received_ms` columns (kept for backwards compat)
- C# timing (all timing stays in C++ steady_clock)
- `OptimizationMetadata.start_ms` / `complete_ms` (separate exploration timing, not in results.tsv)

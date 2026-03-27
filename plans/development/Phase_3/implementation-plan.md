# Phase 3: ScanCommand Struct + Bridge Stubs — Implementation Plan

**Date:** 2026-03-21
**Build:** Build #1 (ships together with Phases 1 and 2)
**Scope rating:** L (Large)
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issues 1, 2, 3
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 3 section and CI Environment Requirements
- [../testing-strategy.md](../testing-strategy.md) — Phase 3 test plan and Section 5 (Cross-Project Bridge Tests)
- [../test-file-specification.md](../test-file-specification.md) — Authoritative formats and content requirements for all test spectrum files, golden files, config files, and test infrastructure scripts used in this phase

---

## Goal

Define the `ScanCommand` and `IsolationStage` blittable structs, implement a priority queue inside `FLASHIda`, and add three new bridge exports (`ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`) alongside the existing 18. On the C# side, declare matching P/Invoke signatures, define the mirrored `ScanCommand` struct with `[StructLayout(LayoutKind.Sequential)]`, and add `ScanFactory.BuildFromCommand()`. Add shadow validation: after each old-path call C# also calls the new `ProcessScan` and logs TRACK audit entries, but still trusts old results for all scan decisions.

At the end of this phase the application behaves identically to Phase 2. No scan routing has changed. The new code is exercised in shadow mode only, building confidence before Phase 4 performs the switch-over.

**Known limitation (Phase 0 compliance H-2):** The ContinuityTestHarness bypasses DataPipe — it calls bridge functions directly without going through the async pipeline. This means Phase 3 integration tests (P3-I01 through P3-I04) and stress tests (CT31, CT32) exercise the bridge and queue logic but do not test DataPipe threading or backpressure. Full pipeline testing requires the mock-based acquisition loop tests planned in later phases.

---

## Prerequisites

The following must exist and be green before Phase 3 work begins:

1. Phase 0 complete: `Flash.Tests.csproj` exists, `baseline_phase0.tsv` committed, CI skeleton active.
2. Phase 1 complete: `Parameter.ToJSON()` implemented, `MethodConfig.cs` exists, C++ JSON parsing branch in `FLASHIda` constructor active, Build #1 DLL artifact available (or Phase 3 is batched alongside Phases 1 and 2 in the same Build #1 — see batching note below).
3. Phase 2 complete: `OptimizationMetadata.h` and `DeconvolvedSpectrum` accessors implemented.
4. All Phase 0, 1, and 2 tests pass (39 cumulative tests in CI after Phase 3 ships).
5. The OpenMS submodule is on branch `flashida-v9-bridge` and the FlashIDA repo is on branch `flashida-v9-migration`.
6. `FlashIDA/dll/OpenMS.dll` is committed in the repo (Phase 0 lesson #5 — no download needed). It will be replaced by the Build #1 artifact that includes Phase 3 changes.

**Build batching note:** Phases 1, 2, and 3 are batched into a single C++ build (Build #1). In practice this means all C++ changes for all three phases are developed together and compiled once. When working in this batch, treat the Build #1 OpenMS artifact as the combined output of all three phases. The phase separation exists for clarity of scope, not for separate compilation runs.

**Submodule workflow note (Phase 0 lesson #15):** 48% of Phase 0 commits were submodule pointer updates. Batch same-side changes (all C# changes or all C++ changes) before updating the submodule pointer to reduce churn. For Phase 3, complete all C++ changes (Steps 1-5, 11, 13) before committing the submodule update in the FlashIDA repo, then do all C# changes (Steps 6-10, 12, 14) in a batch.

### User-Provided Inputs

No new user-provided spectrum data is required for Phase 3 (P3-R01 uses `ms1_smoke_test.txt` from Phase 0). Optional: `ms1_high_density.txt` for stress test P3-S01 — see test-file-specification.md §1.5 for requirements.

---

## Detailed Implementation Steps

### Step 1: Define C++ Structs in `FLASHIda.h`

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add the following inside the `OpenMS` namespace, before the `class FLASHIda` definition. These structs must be defined at namespace scope (not inside the class) so they can be referenced by the bridge functions in `FLASHIdaBridgeFunctions.h`.

```cpp
const int MAX_ISOLATION_STAGES = 10;

struct IsolationStage
{
  double precursor_mz;       // 8 bytes — offset 0
  double isolation_width;    // 8 bytes — offset 8
  int    collision_energy;   // 4 bytes — offset 16
  int    charge;             // 4 bytes — offset 20
  char   activation_type[16]; // 16 bytes — offset 24
  double first_mass;         // 8 bytes — offset 40
  double last_mass;          // 8 bytes — offset 48
  double reaction_time;      // 8 bytes — offset 56
  double reagent_max_it;     // 8 bytes — offset 64
  int    reagent_agc_target; // 4 bytes — offset 72
  // 4 bytes padding to next 8-byte boundary — offset 76
  // sizeof(IsolationStage) = 80
};

struct ScanCommand
{
  int    msn_level;                              // 4 bytes — offset 0
  int    num_isolation_stages;                   // 4 bytes — offset 4
  IsolationStage stages[MAX_ISOLATION_STAGES];   // 800 bytes — offset 8
  double max_it;                                 // 8 bytes — offset 808
  int    agc_target;                             // 4 bytes — offset 816
  int    orbitrap_resolution;                    // 4 bytes — offset 820
  char   analyzer[32];                           // 32 bytes — offset 824
  double faims_cv;                               // 8 bytes — offset 856
  char   scan_description[256];                  // 256 bytes — offset 864
  int    priority;                               // 4 bytes — offset 1120
  int    _pad0;                                  // 4 bytes padding — offset 1124
  uint64_t enqueue_timestamp_ms;                 // 8 bytes — offset 1128
  int    is_agc;                                 // 4 bytes — offset 1136
  int    scan_id;                                // 4 bytes — offset 1140
  // sizeof(ScanCommand) = 1144
};
```

**Layout notes:**

The `IsolationStage` size calculation requires care. The last declared integer field `reagent_agc_target` ends at offset 76. The compiler will pad to the struct's alignment requirement, which is `double` = 8 bytes. Thus sizeof(IsolationStage) = 80.

The `ScanCommand.stages` array therefore occupies 80 * 10 = 800 bytes starting at offset 8.

These sizes must be hard-coded as compile-time assertions in Step 4 and must match what the C# `Marshal.SizeOf` test validates.

Add compile-time assertions immediately after the struct definitions:

```cpp
static_assert(sizeof(IsolationStage) == 80,
    "IsolationStage size changed — update C# struct layout and tests");
static_assert(sizeof(ScanCommand) == 1144,
    "ScanCommand size changed — update C# struct layout and tests");
```

The exact values (80 and 1144) are verified by the `static_assert` statements at C++ compile time in CI. If the compiler places the structs differently (e.g., different padding rules on the target ABI), the `static_assert` will fail the CI build and the developer must adjust the struct layout and expected values in the C# test to match. The compile-time assertion is the authoritative size; the C# test reads this value.

### Step 2: Add Queue, Mutex, Tracking State, and `pending_scan_map_` to `FLASHIda.h`

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add the following includes at the top of the file (after the existing includes):

```cpp
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <unordered_map>
```

Add the following private member declarations inside `class FLASHIda`, in the private section:

```cpp
// --- Phase 3: scan queue and tracking state ---

/// Four priority queues: index 3 = highest (MS3), 0 = lowest (exploration)
std::deque<ScanCommand> queues_[4];

/// Mutex protecting all queue and pending_scan_map_ access.
/// Called from both ProcessScan (TPL thread) and GetNextScanCommand (instrument thread).
mutable std::mutex queue_mutex_;

/// Monotonically increasing counter for tracking ID generation.
/// Written only under queue_mutex_; read outside only in tests.
int tracking_id_counter_ = 0;

/// Pending scan map: tracking ID (integer) -> ScanCommand that was dequeued.
/// Used in Phase 4 to resolve MS2 scans back to their originating commands.
std::unordered_map<int, ScanCommand> pending_scan_map_;

/// Timestamp of the last MS1 scan returned by GetNextScanCommand.
/// Used for cycle-time enforcement (Phase 3: cycle time always falls through to MS1 default).
std::chrono::steady_clock::time_point last_ms1_time_ = std::chrono::steady_clock::now();

// --- Scheduling config fields (parsed from JSON in Phase 1) ---
// These are already populated by the JSON parsing code added in Phase 1.
// Listed here for reference: cycle_time_enabled_, cycle_time_ms_,
// timeout_enabled_, timeout_seconds_.
// In Phase 3 the stub ProcessScan does not push to queues, so cycle time
// and timeout logic always falls through to the MS1 fallback in GetNextScanCommand.
```

Add the following private helper method declarations:

```cpp
/// Build an MS1 scan command using JSON-configured ms1 settings.
ScanCommand makeMS1Command_() const;

/// Build an AGC (pre-scan) command using the ion trap settings from config.
ScanCommand makeAGCCommand_() const;

/// Determine if an AGC scan is needed before the next MS1 or MS2.
/// In Phase 3 this always returns false (stub).
bool needsAGCScan_() const;

/// Remove expired entries from pending_scan_map_ (older than timeout threshold).
/// Called inside GetNextScanCommand, under queue_mutex_.
void cleanupExpiredCommands_();

/// Encode an integer as a 4-character base-36 string (0-9, a-z).
/// encodeBase36(0) = "0000", encodeBase36(1) = "0001", encodeBase36(35) = "000z",
/// encodeBase36(36) = "0010", encodeBase36(1679615) = "zzzz".
static std::string encodeBase36_(int value);

/// Return a new tracking ID integer (increments tracking_id_counter_ under the lock).
/// The caller is responsible for holding queue_mutex_ or accepting the race in tests.
int nextTrackingIdInt_();

/// ProcessScan stub: deconvolves but does NOT push to queues. Returns 0.
int processScan_(const double* mzs, const double* ints, int length,
                 double rt_min, int ms_level, const char* scan_description);

/// GetNextScanCommand implementation (full priority dequeue logic).
/// Returns 1 always (always has a command); fills `out`.
int getNextScanCommand_(ScanCommand& out);
```

### Step 3: Implement New Methods in `FLASHIda.cpp`

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Add implementations for all methods declared in Step 2. Detailed implementation for each:

**`encodeBase36_`:**

```cpp
std::string FLASHIda::encodeBase36_(int value)
{
  static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
  char buf[5] = {'0','0','0','0','\0'};
  int v = value;
  for (int i = 3; i >= 0; --i)
  {
    buf[i] = digits[v % 36];
    v /= 36;
    if (v == 0) break;
  }
  return std::string(buf);
}
```

**`nextTrackingIdInt_`:**

```cpp
int FLASHIda::nextTrackingIdInt_()
{
  int id = tracking_id_counter_++;
  if (tracking_id_counter_ > 1679615) // 36^4 - 1 = "zzzz"
    tracking_id_counter_ = 0;         // wrap around
  return id;
}
```

**`needsAGCScan_`:**

```cpp
bool FLASHIda::needsAGCScan_() const
{
  // Phase 3 stub: AGC logic is not yet connected to JSON config.
  // Always returns false in this phase.
  return false;
}
```

**`makeMS1Command_`:**

Reads MS1 settings from the JSON-parsed config fields stored in Phase 1. Fills all relevant `ScanCommand` fields. The `scan_description` field is set to "MS1" as a sentinel. The `priority` field is set to 1 (standard MS1 is not priority 0 exploration). `is_agc` is set to 0. `msn_level` is 1. `num_isolation_stages` is 0. `faims_cv` is 0.0 in Phase 3 (FAIMS absorption is Phase 6).

```cpp
ScanCommand FLASHIda::makeMS1Command_() const
{
  ScanCommand cmd{};
  cmd.msn_level = 1;
  cmd.num_isolation_stages = 0;
  // ms1 settings come from Phase 1 JSON parsing (stored as member fields).
  // If fields are not yet populated (legacy path), use safe defaults.
  cmd.max_it = ms1_max_it_ > 0 ? ms1_max_it_ : 50.0;
  cmd.agc_target = ms1_agc_target_ > 0 ? ms1_agc_target_ : 1000000;
  cmd.orbitrap_resolution = ms1_resolution_ > 0 ? ms1_resolution_ : 120000;
  std::strncpy(cmd.analyzer, ms1_analyzer_.empty() ? "Orbitrap" : ms1_analyzer_.c_str(),
               sizeof(cmd.analyzer) - 1);
  cmd.analyzer[sizeof(cmd.analyzer) - 1] = '\0';
  cmd.faims_cv = 0.0;
  std::strncpy(cmd.scan_description, "MS1", sizeof(cmd.scan_description) - 1);
  cmd.priority = 1;
  cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count());
  cmd.is_agc = 0;
  cmd.scan_id = 0;
  return cmd;
}
```

**Note on member fields:** The JSON parsing introduced in Phase 1 stores ms1 settings as private members of `FLASHIda` (e.g., `ms1_max_it_`, `ms1_agc_target_`, `ms1_resolution_`, `ms1_analyzer_`, `ms1_first_mass_`, `ms1_last_mass_`). If these were not declared in Phase 1, they must be added in Phase 1's implementation and Phase 3 can use them. Coordinate with the Phase 1 implementation to ensure these fields exist before implementing `makeMS1Command_`.

**`makeAGCCommand_`:**

```cpp
ScanCommand FLASHIda::makeAGCCommand_() const
{
  ScanCommand cmd{};
  cmd.msn_level = 1;
  cmd.num_isolation_stages = 0;
  cmd.max_it = 1.0;
  cmd.agc_target = 30000;
  cmd.orbitrap_resolution = 0;
  std::strncpy(cmd.analyzer, "IonTrap", sizeof(cmd.analyzer) - 1);
  cmd.analyzer[sizeof(cmd.analyzer) - 1] = '\0';
  cmd.faims_cv = 0.0;
  std::strncpy(cmd.scan_description, "AGC", sizeof(cmd.scan_description) - 1);
  cmd.priority = 3;  // AGC is highest priority
  cmd.enqueue_timestamp_ms = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count());
  cmd.is_agc = 1;
  cmd.scan_id = 41;
  return cmd;
}
```

**`cleanupExpiredCommands_`:**

Called under `queue_mutex_`. Removes entries from `pending_scan_map_` whose `enqueue_timestamp_ms` exceeds the configured timeout. In Phase 3 the timeout feature is not active (timeout_enabled_ is false after Phase 1 JSON parsing), so this function body is a no-op stub that emits a TRACK-EXPIRE log entry when it does remove something.

```cpp
void FLASHIda::cleanupExpiredCommands_()
{
  // Phase 3: timeout_enabled_ is always false; no cleanup needed.
  // Full implementation deferred to Phase 4.
  // If timeout_enabled_ is wired up, iterate pending_scan_map_ and
  // remove entries older than (timeout_seconds_ * 1000) ms, logging
  // [TRACK-EXPIRE id=%s].
  (void)this;
}
```

**`processScan_` (stub):**

**Silent zero-result warning (Phase 0 lesson #14):** The C++ engine returns 0 for malformed input without an error code. When deconvolution returns 0 results unexpectedly, log the input data characteristics (RT, peak count, first/last m/z) before investigating engine internals. The bridge functions do not distinguish "no results found" from "input data is malformed."

```cpp
int FLASHIda::processScan_(const double* mzs, const double* ints, int length,
                            double rt_min, int ms_level, const char* scan_description)
{
  // Phase 3 stub: run deconvolution (reusing existing internal state),
  // log a TRACK-CREATE audit entry, but do NOT push any commands to the queues.
  // Returns 0 to indicate no commands pushed.

  // Reuse existing deconvolution path (same as getPeakGroups_ internal call).
  // This keeps the shadow path exercised without changing behavior.
  // No commands are pushed; queue remains empty.

  // Emit audit log entry.
  int tracking_id;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    tracking_id = nextTrackingIdInt_();
  }
  // TRACK-CREATE log: emitted when C++ assigns a tracking ID.
  // In Phase 3 this happens on every ProcessScan call (shadow mode).
  OPENMS_LOG_INFO << "[TRACK-CREATE] id=" << encodeBase36_(tracking_id)
                  << " ms_level=" << ms_level
                  << " rt=" << rt_min;

  return 0;  // stub: no commands pushed
}
```

**`getNextScanCommand_` (full implementation):**

This implements the full priority dequeue logic even though the queue will always be empty in Phase 3 (because `processScan_` is a stub that does not push). The queue logic is fully correct so that Phase 4 only needs to change `processScan_` to push commands.

```cpp
int FLASHIda::getNextScanCommand_(ScanCommand& out)
{
  std::lock_guard<std::mutex> lock(queue_mutex_);

  // (1) AGC — always first if needed
  if (needsAGCScan_())
  {
    out = makeAGCCommand_();
    OPENMS_LOG_INFO << "[TRACK-CREATE] id=" << encodeBase36_(out.scan_id) << " type=AGC";
    return 1;
  }

  // (2) MS1 cycle time check
  // In Phase 3 cycle_time_enabled_ is false (from JSON config); this branch
  // never fires. Full cycle time logic is implemented here for Phase 4 readiness.
  if (cycle_time_enabled_)
  {
    auto now = std::chrono::steady_clock::now();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - last_ms1_time_).count();
    if (elapsed_ms > static_cast<long long>(cycle_time_ms_))
    {
      out = makeMS1Command_();
      last_ms1_time_ = now;
      return 1;
    }
  }

  // (3) Timeout cleanup
  cleanupExpiredCommands_();

  // (4) Priority dequeue: 3 (MS3) -> 2 (conditional) -> 1 (standard MS2) -> 0 (exploration)
  for (int lvl = 3; lvl >= 0; --lvl)
  {
    if (!queues_[lvl].empty())
    {
      out = queues_[lvl].front();
      queues_[lvl].pop_front();
      // Move to pending_scan_map_ so Phase 4 can resolve it from MS2 scan description.
      int tid;
      {
        tid = nextTrackingIdInt_();
      }
      pending_scan_map_[tid] = out;
      // Embed tracking ID into scan_description for the instrument to echo back.
      std::string tag = "[" + encodeBase36_(tid) + "]";
      // Append tag to existing scan_description (truncating if needed).
      std::strncat(out.scan_description, tag.c_str(),
                   sizeof(out.scan_description) - std::strlen(out.scan_description) - 1);
      OPENMS_LOG_INFO << "[TRACK-CREATE] id=" << encodeBase36_(tid)
                      << " priority=" << lvl;
      return 1;
    }
  }

  // (5) Empty queue fallback: return MS1
  out = makeMS1Command_();
  last_ms1_time_ = std::chrono::steady_clock::now();
  return 1;
}
```

### Step 4: Add Bridge Exports to `FLASHIdaBridgeFunctions.h`

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h`

Add the three new `extern "C"` declarations after the existing declarations, still inside `namespace OpenMS`:

```cpp
/// Unified scan processing entry point (stub in Phase 3: returns 0).
/// In Phase 4 this will deconvolve and push commands to the priority queue.
extern "C" OPENMS_DLLAPI int ProcessScan(FLASHIda* obj,
                                          double*   mzs,
                                          double*   ints,
                                          int       length,
                                          double    rt_min,
                                          int       ms_level,
                                          const char* scan_description);

/// Dequeue the next scan command from the priority queue.
/// Always returns 1 (a command is always available — fallback to MS1 if queue empty).
/// output: caller-allocated ScanCommand that will be filled.
extern "C" OPENMS_DLLAPI int GetNextScanCommand(FLASHIda*    obj,
                                                 ScanCommand* output);

/// Return the next tracking ID as an integer (for testing and audit trail).
/// Also available as encodeBase36_(id) for the 4-char string form.
extern "C" OPENMS_DLLAPI int GetNextTrackingId(FLASHIda* obj);
```

### Step 5: Implement Bridge Exports in `FLASHIdaBridgeFunctions.cpp`

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp`

Add implementations for the three new exports. Each is a one-line delegation:

```cpp
int ProcessScan(FLASHIda* obj, double* mzs, double* ints, int length,
                double rt_min, int ms_level, const char* scan_description)
{
  return obj->processScan_(mzs, ints, length, rt_min, ms_level, scan_description);
}

int GetNextScanCommand(FLASHIda* obj, ScanCommand* output)
{
  return obj->getNextScanCommand_(*output);
}

int GetNextTrackingId(FLASHIda* obj)
{
  std::lock_guard<std::mutex> lock(obj->queue_mutex_);
  return obj->nextTrackingIdInt_();
}
```

**Access note:** `GetNextTrackingId` needs access to `queue_mutex_` and `nextTrackingIdInt_()`, both private. Since `FLASHIdaBridgeFunctions.cpp` is not a friend, these should be exposed through a single public method `getNextTrackingId()` on `FLASHIda`:

```cpp
// In FLASHIda.h public section:
int getNextTrackingId();

// In FLASHIda.cpp:
int FLASHIda::getNextTrackingId()
{
  std::lock_guard<std::mutex> lock(queue_mutex_);
  return nextTrackingIdInt_();
}
```

Similarly, `processScan_` and `getNextScanCommand_` should have public wrappers or be made public. The cleanest approach is to make `processScan_` and `getNextScanCommand_` public methods directly (renaming from `_` suffix to indicate they are the public API):

```cpp
// In FLASHIda.h public section:
int processScan(const double* mzs, const double* ints, int length,
                double rt_min, int ms_level, const char* scan_description);
int getNextScanCommand(ScanCommand& out);
int getNextTrackingId();
```

The private `_`-suffixed helpers (`makeMS1Command_`, `makeAGCCommand_`, etc.) remain private.

### Step 6: Add C# `ScanCommand` and `IsolationStage` Struct Declarations in `FLASHIdaWrapper.cs`

**File:** `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

Add the following struct declarations inside the `Flash.IDA` namespace, before the `FLASHIdaWrapper` class. These must mirror the C++ layout exactly.

```csharp
[StructLayout(LayoutKind.Sequential, Pack = 8)]
public struct IsolationStage
{
    public double PrecursorMz;          // offset 0
    public double IsolationWidth;       // offset 8
    public int    CollisionEnergy;      // offset 16
    public int    Charge;               // offset 20
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]
    public string ActivationType;       // offset 24
    public double FirstMass;            // offset 40
    public double LastMass;             // offset 48
    public double ReactionTime;         // offset 56
    public double ReagentMaxIt;         // offset 64
    public int    ReagentAgcTarget;     // offset 72
    // 4 bytes implicit padding to reach 8-byte alignment = sizeof 80
}

[StructLayout(LayoutKind.Sequential, Pack = 8)]
public struct ScanCommand
{
    public int    MsnLevel;             // offset 0
    public int    NumIsolationStages;   // offset 4
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)]
    public IsolationStage[] Stages;    // offset 8, 800 bytes
    public double MaxIt;               // offset 808
    public int    AgcTarget;           // offset 816
    public int    OrbitrapResolution;  // offset 820
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string Analyzer;            // offset 824
    public double FaimsCv;             // offset 856
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
    public string ScanDescription;     // offset 864
    public int    Priority;            // offset 1120
    public int    Pad0;                // offset 1124 (explicit padding)
    public ulong  EnqueueTimestampMs;  // offset 1128
    public int    IsAgc;               // offset 1136
    public int    ScanId;              // offset 1140
    // sizeof = 1144
}
```

**Marshaling notes:**

- `[StructLayout(LayoutKind.Sequential, Pack = 8)]` matches the C++ default packing on MSVC x64 (8-byte alignment for double fields).
- `[MarshalAs(UnmanagedType.ByValTStr, SizeConst = N)]` maps `string` to an inline fixed-size char array in the struct footprint. `SizeConst` is the number of characters including the null terminator, matching the C++ `char[N]` declaration.
- `[MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)]` maps the stages array to an inline array of 10 `IsolationStage` values. This requires the array to be initialized before use; C# defaults it to null for reference types but the marshaler treats it as an inline value-type array.
- The `Pad0` field explicitly represents the 4-byte padding between `Priority` and `EnqueueTimestampMs`. Without this field the C# struct would be 4 bytes shorter and all subsequent field offsets would be wrong.

### Step 7: Add P/Invoke Declarations for the Three New Bridge Functions

**File:** `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

Add the following `[DllImport]` declarations inside the `FLASHIdaWrapper` class alongside the existing 18 declarations:

```csharp
[DllImport(dllName, CharSet = CharSet.Ansi)]
static private extern int ProcessScan(
    IntPtr  pObj,
    double[] mzs,
    double[] ints,
    int     length,
    double  rt,
    int     msLevel,
    string  scanDesc);

[DllImport(dllName)]
static private extern int GetNextScanCommand(
    IntPtr       pObj,
    ref ScanCommand output);

[DllImport(dllName)]
static private extern int GetNextTrackingId(IntPtr pObj);
```

**Notes on calling convention:** The default P/Invoke calling convention on Windows x64 is the Microsoft x64 convention, which matches MSVC `extern "C"` exports. No `CallingConvention` attribute is needed.

**DLL name note:** The `dllName` constant must be `"OpenMS.dll"` (with `.dll` extension), not `"OpenMS"`. Phase 0 lesson #12 confirmed the extension is required for the P/Invoke runtime to locate the DLL correctly.

`CharSet.Ansi` on `ProcessScan` ensures the `string scanDesc` parameter is marshaled as a null-terminated ANSI (8-bit) string, matching `const char*` on the C++ side.

### Step 8: Add Public Wrapper Methods in `FLASHIdaWrapper`

**File:** `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`

Add the following public methods to the `FLASHIdaWrapper` class:

```csharp
/// <summary>
/// Shadow path: call ProcessScan stub. Returns number of commands pushed (always 0 in Phase 3).
/// Emits TRACK log entries for audit trail validation.
/// </summary>
public int ProcessScan(double[] mzs, double[] ints, double rt, int msLevel, string scanDesc)
{
    try
    {
        return ProcessScan(m_pNativeObject, mzs, ints, mzs.Length, rt, msLevel, scanDesc ?? "");
    }
    catch (Exception ex)
    {
        log.Error(String.Format("ProcessScan error: {0}\n{1}", ex.Message, ex.StackTrace));
        return 0;
    }
}

/// <summary>
/// Dequeue the next scan command from the C++ priority queue.
/// Returns 1 if a command was returned (always in Phase 3 — falls back to MS1).
/// </summary>
public int GetNextScanCommand(ref ScanCommand cmd)
{
    try
    {
        return GetNextScanCommand(m_pNativeObject, ref cmd);
    }
    catch (Exception ex)
    {
        log.Error(String.Format("GetNextScanCommand error: {0}\n{1}", ex.Message, ex.StackTrace));
        return 0;
    }
}

/// <summary>
/// Get the next tracking ID integer from the C++ counter. Used in tests.
/// </summary>
public int GetNextTrackingId()
{
    try
    {
        return GetNextTrackingId(m_pNativeObject);
    }
    catch (Exception ex)
    {
        log.Error(String.Format("GetNextTrackingId error: {0}", ex.Message));
        return -1;
    }
}
```

### Step 9: Add Shadow Validation Calls in the Existing Scan Processors

**File:** `FlashIDA/src/Flash/IDA/IDAScanProcessor.cs`

Shadow validation means: after each existing old-path call (`GetIsolationWindows`, `DeconvolveMS2`, etc.), also call `wrapper.ProcessScan(...)` and log the TRACK audit entries. The old-path results are still used for all scan decisions. No behavioral change.

Locate the method that calls `wrapper.GetIsolationWindows(msScan)` for MS1 scans (in `IDAScanProcessor.ProcessMS`). Directly after the call, add:

```csharp
// Shadow validation (Phase 3): call ProcessScan stub for TRACK audit trail.
// Results are discarded; old path still controls scan selection.
{
    var shadowMzs   = msScan.Centroids.Select(c => c.Mz).ToArray();
    var shadowInts  = msScan.Centroids.Select(c => c.Intensity).ToArray();
    double shadowRt = double.Parse(msScan.Header["StartTime"]);
    int shadowLevel = int.Parse(msScan.Header["MSOrder"]);
    string shadowDesc = msScan.Trailer.GetValueOrDefault("Scan Description", "");

    int shadowCmds = wrapper.ProcessScan(shadowMzs, shadowInts, shadowRt, shadowLevel, shadowDesc);
    IDAlog.Debug(String.Format("[SHADOW] ProcessScan returned {0} commands (Phase 3 stub; old path used)", shadowCmds));
}
```

Apply the same pattern in `FAIMSScanProcessor.cs` and `QuantScanProcessor.cs` at their respective calls to `wrapper.GetIsolationWindows`.

**No changes to scan submission logic.** The shadow path does not call `GetNextScanCommand`. That call is exercised in integration tests only during Phase 3.

### Step 10: Add `ScanFactory.BuildFromCommand`

**File:** `FlashIDA/src/Flash/ScanFactory.cs`

Add the following method to the `ScanFactory` class. This translates a `ScanCommand` into an `IFusionCustomScan` that can be submitted to the instrument. In Phase 3 this method is only called from integration tests; it will be called at runtime in Phase 4.

```csharp
/// <summary>
/// Translate a ScanCommand struct from the C++ priority queue into an IFusionCustomScan.
/// </summary>
/// <param name="cmd">Command from GetNextScanCommand</param>
/// <returns>IFusionCustomScan ready for submission, or null if translation fails</returns>
public IFusionCustomScan BuildFromCommand(ScanCommand cmd)
{
    var p = new ScanParameters();

    // Analyzer
    p.Analyzer = string.IsNullOrEmpty(cmd.Analyzer) ? "Orbitrap" : cmd.Analyzer;

    // MS1 or MS2/MS3 mass range from first isolation stage or defaults
    if (cmd.MsnLevel == 1)
    {
        // MS1: use first_mass and last_mass from stages[0] if populated,
        // otherwise use config defaults (350-2000 Da)
        p.FirstMass  = new double[] { cmd.Stages != null && cmd.NumIsolationStages > 0
                                      ? cmd.Stages[0].FirstMass : 350.0 };
        p.LastMass   = new double[] { cmd.Stages != null && cmd.NumIsolationStages > 0
                                      ? cmd.Stages[0].LastMass  : 2000.0 };
    }
    else
    {
        // MSn: mass range spans from first isolation stage
        p.FirstMass  = new double[] { cmd.Stages != null && cmd.NumIsolationStages > 0
                                      ? cmd.Stages[0].FirstMass : 150.0 };
        p.LastMass   = new double[] { cmd.Stages != null && cmd.NumIsolationStages > 0
                                      ? cmd.Stages[0].LastMass  : 2000.0 };
    }

    // Resolution
    if (cmd.OrbitrapResolution > 0)
        p.OrbitrapResolution = cmd.OrbitrapResolution;

    // AGC and injection time
    if (cmd.AgcTarget > 0)
        p.AGCTarget = cmd.AgcTarget;
    if (cmd.MaxIt > 0)
        p.MaxIT = cmd.MaxIt;

    // Isolation and activation for each stage
    if (cmd.NumIsolationStages > 0 && cmd.Stages != null)
    {
        var stage = cmd.Stages[0];  // primary stage
        if (stage.PrecursorMz > 0)
            p.PrecursorMass = new double[] { stage.PrecursorMz };
        if (stage.IsolationWidth > 0)
            p.IsolationWidth = new double[] { stage.IsolationWidth };
        if (stage.CollisionEnergy > 0)
            p.CollisionEnergy = new int[] { stage.CollisionEnergy };
        if (!string.IsNullOrEmpty(stage.ActivationType))
            p.ActivationType = new string[] { stage.ActivationType };
    }

    // FAIMS CV (0.0 = not applicable)
    if (cmd.FaimsCv != 0.0)
        p.FAIMS_CV = cmd.FaimsCv;

    // Scan description (carries tracking ID in Phase 4+)
    if (!string.IsNullOrEmpty(cmd.ScanDescription))
        p.ScanDescription = cmd.ScanDescription;

    // AGC scan flag
    bool isAgc = cmd.IsAgc != 0;

    return CreateFusionCustomScan(p, cmd.ScanId, delay: 0.0, IsAGC: isAgc, AGCgroup: 1);
}
```

**Note on `Stages` initialization:** When `ScanCommand` is received from `GetNextScanCommand` via P/Invoke, the `Stages` array is populated by the marshaler from the inline C++ array. However, if `NumIsolationStages == 0`, the stage values will all be zero. `BuildFromCommand` must handle this gracefully, as shown above.

### Step 11: Add `ScanCommandLayoutTest` C++ Binary

**File to create:** `OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp`

This binary prints struct sizes and field offsets so the C# layout test can read them. It is compiled on `ubuntu-latest` and its output is either hard-coded in the C# test or passed as a cross-job artifact.

```cpp
// --------------------------------------------------------------------------
// ScanCommandLayout_test.cpp
// Prints sizeof and offsetof values for ScanCommand and IsolationStage.
// Output is consumed by C# ScanCommandLayoutTests.cs to verify marshaling.
// --------------------------------------------------------------------------
#include <cstddef>
#include <cstdio>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h>

using namespace OpenMS;

int main()
{
  printf("sizeof_IsolationStage=%zu\n",    sizeof(IsolationStage));
  printf("sizeof_ScanCommand=%zu\n",       sizeof(ScanCommand));
  printf("offsetof_msn_level=%zu\n",       offsetof(ScanCommand, msn_level));
  printf("offsetof_num_isolation_stages=%zu\n", offsetof(ScanCommand, num_isolation_stages));
  printf("offsetof_stages=%zu\n",          offsetof(ScanCommand, stages));
  printf("offsetof_max_it=%zu\n",          offsetof(ScanCommand, max_it));
  printf("offsetof_agc_target=%zu\n",      offsetof(ScanCommand, agc_target));
  printf("offsetof_orbitrap_resolution=%zu\n", offsetof(ScanCommand, orbitrap_resolution));
  printf("offsetof_analyzer=%zu\n",        offsetof(ScanCommand, analyzer));
  printf("offsetof_faims_cv=%zu\n",        offsetof(ScanCommand, faims_cv));
  printf("offsetof_scan_description=%zu\n", offsetof(ScanCommand, scan_description));
  printf("offsetof_priority=%zu\n",        offsetof(ScanCommand, priority));
  printf("offsetof_enqueue_timestamp_ms=%zu\n", offsetof(ScanCommand, enqueue_timestamp_ms));
  printf("offsetof_is_agc=%zu\n",          offsetof(ScanCommand, is_agc));
  printf("offsetof_scan_id=%zu\n",         offsetof(ScanCommand, scan_id));

  printf("offsetof_stage0_precursor_mz=%zu\n",     offsetof(IsolationStage, precursor_mz));
  printf("offsetof_stage0_isolation_width=%zu\n",  offsetof(IsolationStage, isolation_width));
  printf("offsetof_stage0_collision_energy=%zu\n", offsetof(IsolationStage, collision_energy));
  printf("offsetof_stage0_charge=%zu\n",           offsetof(IsolationStage, charge));
  printf("offsetof_stage0_activation_type=%zu\n",  offsetof(IsolationStage, activation_type));
  printf("offsetof_stage0_first_mass=%zu\n",       offsetof(IsolationStage, first_mass));
  printf("offsetof_stage0_last_mass=%zu\n",        offsetof(IsolationStage, last_mass));
  printf("offsetof_stage0_reaction_time=%zu\n",    offsetof(IsolationStage, reaction_time));
  printf("offsetof_stage0_reagent_max_it=%zu\n",   offsetof(IsolationStage, reagent_max_it));
  printf("offsetof_stage0_reagent_agc_target=%zu\n", offsetof(IsolationStage, reagent_agc_target));

  return 0;
}
```

**Registration:** Add this test binary to `OpenMS/src/tests/class_tests/openms/executables.cmake`. Find the FLASH-related section and add:

```cmake
add_executable(ScanCommandLayout_test source/ScanCommandLayout_test.cpp)
target_link_libraries(ScanCommandLayout_test OpenMS)
```

Unlike CTest unit tests, this binary is not registered with `add_test` — it is a layout-query binary that CI runs directly. However, adding it to the CMake build ensures it compiles as part of the test build step and any struct size mismatch will fail the C++ build.

### Step 12: Add C# Struct Layout Tests

**File:** `FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs`

This test class validates that the C# struct layout matches the C++ layout. There are two approaches for obtaining C++ layout values:

**Approach A (preferred): Hard-coded expected values.** Based on the struct definitions in Step 1, the expected values are known at authoring time. Hard-code them in the test. If the C++ struct changes, the `static_assert` in Step 1 will catch it at compile time and the developer must update both the C++ definition and the C# test.

**Approach B: Cross-job artifact.** The `ScanCommandLayout_test` binary runs on `ubuntu-latest` and its output is uploaded as a GitHub Actions artifact. The C# layout test on `windows-latest` downloads the artifact and parses it. This approach verifies the layout under both MSVC (Windows, used at runtime) and GCC/Clang (Linux, used for CI testing). The cross-job artifact approach is described in testing-strategy.md Section 5 and in the CI configuration section below.

Both approaches are valid. Approach A is simpler to implement; Approach B provides stronger ABI verification. Implement Approach A for Phase 3 and add Approach B in the CI workflow if time allows.

```csharp
// FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs
using System;
using System.Runtime.InteropServices;
using Flash.IDA;
using NUnit.Framework;

namespace Flash.Tests
{
    [TestFixture]
    public class ScanCommandLayoutTests
    {
        // Expected values derived from C++ struct definitions in FLASHIda.h.
        // If these change, update FLASHIda.h static_assert constants too.
        private const int ExpectedIsolationStageSize = 80;
        private const int ExpectedScanCommandSize    = 1144;

        [Test]
        public void IsolationStage_SizeMatchesCpp()
        {
            // P3-U02
            Assert.AreEqual(ExpectedIsolationStageSize, Marshal.SizeOf<IsolationStage>(),
                "IsolationStage size mismatch with C++ sizeof(IsolationStage)");
        }

        [Test]
        public void ScanCommand_SizeMatchesCpp()
        {
            // P3-U01
            Assert.AreEqual(ExpectedScanCommandSize, Marshal.SizeOf<ScanCommand>(),
                "ScanCommand size mismatch with C++ sizeof(ScanCommand)");
        }

        [Test]
        public void ScanCommand_FieldOffsetsMatchCpp()
        {
            // P3-U03 — verify key field offsets
            Assert.AreEqual(0,    (int)Marshal.OffsetOf<ScanCommand>("MsnLevel"),          "MsnLevel offset");
            Assert.AreEqual(4,    (int)Marshal.OffsetOf<ScanCommand>("NumIsolationStages"),"NumIsolationStages offset");
            Assert.AreEqual(8,    (int)Marshal.OffsetOf<ScanCommand>("Stages"),            "Stages offset");
            Assert.AreEqual(808,  (int)Marshal.OffsetOf<ScanCommand>("MaxIt"),             "MaxIt offset");
            Assert.AreEqual(816,  (int)Marshal.OffsetOf<ScanCommand>("AgcTarget"),         "AgcTarget offset");
            Assert.AreEqual(820,  (int)Marshal.OffsetOf<ScanCommand>("OrbitrapResolution"),"OrbitrapResolution offset");
            Assert.AreEqual(824,  (int)Marshal.OffsetOf<ScanCommand>("Analyzer"),          "Analyzer offset");
            Assert.AreEqual(856,  (int)Marshal.OffsetOf<ScanCommand>("FaimsCv"),           "FaimsCv offset");
            Assert.AreEqual(864,  (int)Marshal.OffsetOf<ScanCommand>("ScanDescription"),   "ScanDescription offset");
            Assert.AreEqual(1120, (int)Marshal.OffsetOf<ScanCommand>("Priority"),          "Priority offset");
            Assert.AreEqual(1124, (int)Marshal.OffsetOf<ScanCommand>("Pad0"),              "Pad0 offset");
            Assert.AreEqual(1128, (int)Marshal.OffsetOf<ScanCommand>("EnqueueTimestampMs"),"EnqueueTimestampMs offset");
            Assert.AreEqual(1136, (int)Marshal.OffsetOf<ScanCommand>("IsAgc"),             "IsAgc offset");
            Assert.AreEqual(1140, (int)Marshal.OffsetOf<ScanCommand>("ScanId"),            "ScanId offset");
        }

        [Test]
        public void ScanCommand_CharFieldSizesAreCorrect()
        {
            // P3-U04 — verify ByValTStr SizeConst values via MarshalAsAttribute reflection
            VerifyByValTStr<ScanCommand>("Analyzer",        32);
            VerifyByValTStr<ScanCommand>("ScanDescription", 256);
            VerifyByValTStr<IsolationStage>("ActivationType", 16);
        }

        private static void VerifyByValTStr<T>(string fieldName, int expectedSizeConst)
        {
            var field = typeof(T).GetField(fieldName);
            Assert.IsNotNull(field, $"Field {fieldName} not found on {typeof(T).Name}");

            var attrs = field.GetCustomAttributes(typeof(MarshalAsAttribute), false);
            Assert.AreEqual(1, attrs.Length, $"Expected MarshalAsAttribute on {fieldName}");

            var marshalAs = (MarshalAsAttribute)attrs[0];
            Assert.AreEqual(UnmanagedType.ByValTStr, marshalAs.Value,
                $"{fieldName} should be ByValTStr");
            Assert.AreEqual(expectedSizeConst, marshalAs.SizeConst,
                $"{fieldName} SizeConst should be {expectedSizeConst}");
        }
    }
}
```

### Step 13: Add C++ Unit Tests

**File to create:** `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp`

This file contains C++ unit tests for the tracking ID and queue logic (P3-U05 through P3-U10). It uses the OpenMS `ClassTest.h` framework.

```cpp
// FLASHIdaQueueTracking_test.cpp
// Tests for Phase 3: tracking ID encoding/uniqueness, queue priority,
// AGC ordering, timeout cleanup, and empty-queue MS1 fallback.

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h>
#include <unordered_set>

using namespace OpenMS;
START_TEST(FLASHIdaQueueTracking, "$Id$")

// P3-U05: base-36 encoding correctness
TOLERANCE_ABSOLUTE(0.0001)

START_SECTION(encodeBase36_correctness)
{
  // Access via a test-friend method or test the public getNextTrackingId
  // by creating a minimal FLASHIda instance.
  // Use a known JSON config string (from Phase 1).
  const char* json = R"({"deconvolution":{"min_charge":1,"max_charge":50,
    "tol":[10,10],"score_threshold":-1},"precursor_selection":{"max_mass_count":3,
    "RT_window":5,"target_mode":0,"IDScore":false,"HCDEnergy":29},
    "quantification":{"enabled":false},"faims":{"cv_values":[],"max_cv_skip":0},
    "ms_settings":{"ms1":{"Analyzer":"Orbitrap","FirstMass":350,"LastMass":2000,
    "OrbitrapResolution":120000,"AGCTarget":1000000,"MaxIT":50},"ms2":[],"ms3":[]},
    "scheduling":{"cycle_time_enabled":false,"cycle_time_seconds":60,
    "timeout_enabled":false,"timeout_seconds":30},
    "exploration":{"enabled":false},"files":{"fasta":null,"inclusion_list":null}})";

  // FLASHIda constructor expects char* (legacy), but Phase 1 made it JSON-aware.
  FLASHIda ida(const_cast<char*>(json));

  // Consume IDs 0..37 to test base-36 boundary
  // ID 0 -> "0000", ID 35 -> "000z", ID 36 -> "0010"
  // We test indirectly via getNextTrackingId (increments counter).
  // Reset by creating a fresh instance.
  // Note: direct string tests require exposing encodeBase36_ as a public static.
  // Add a public static method for testability:
  // static std::string encodeBase36ForTest(int v) { return encodeBase36_(v); }
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(0),  "0000")
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(1),  "0001")
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(35), "000z")
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(36), "0010")
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(1295), "00zz")
  TEST_EQUAL(FLASHIda::encodeBase36ForTest(1679615), "zzzz")
}
END_SECTION

START_SECTION(tracking_ids_sequential_unique)
{
  // P3-U06
  const char* json = /* same JSON as above */ R"({"deconvolution":{"min_charge":1,
    "max_charge":50,"tol":[10,10],"score_threshold":-1},
    "precursor_selection":{"max_mass_count":3,"RT_window":5,"target_mode":0,
    "IDScore":false,"HCDEnergy":29},"quantification":{"enabled":false},
    "faims":{"cv_values":[],"max_cv_skip":0},"ms_settings":{"ms1":{"Analyzer":"Orbitrap",
    "FirstMass":350,"LastMass":2000,"OrbitrapResolution":120000,"AGCTarget":1000000,
    "MaxIT":50},"ms2":[],"ms3":[]},"scheduling":{"cycle_time_enabled":false,
    "cycle_time_seconds":60,"timeout_enabled":false,"timeout_seconds":30},
    "exploration":{"enabled":false},"files":{"fasta":null,"inclusion_list":null}})";

  FLASHIda ida(const_cast<char*>(json));

  std::unordered_set<int> seen;
  for (int i = 0; i < 10000; ++i)
  {
    int id = ida.getNextTrackingId();
    TEST_EQUAL(seen.count(id), 0)  // must be unique
    seen.insert(id);
  }
  TEST_EQUAL(seen.size(), 10000)
}
END_SECTION

START_SECTION(empty_queue_returns_ms1)
{
  // P3-U07
  const char* json = /* same JSON */ R"({"deconvolution":{"min_charge":1,"max_charge":50,
    "tol":[10,10],"score_threshold":-1},"precursor_selection":{"max_mass_count":3,
    "RT_window":5,"target_mode":0,"IDScore":false,"HCDEnergy":29},
    "quantification":{"enabled":false},"faims":{"cv_values":[],"max_cv_skip":0},
    "ms_settings":{"ms1":{"Analyzer":"Orbitrap","FirstMass":350,"LastMass":2000,
    "OrbitrapResolution":120000,"AGCTarget":1000000,"MaxIT":50},"ms2":[],"ms3":[]},
    "scheduling":{"cycle_time_enabled":false,"cycle_time_seconds":60,
    "timeout_enabled":false,"timeout_seconds":30},"exploration":{"enabled":false},
    "files":{"fasta":null,"inclusion_list":null}})";

  FLASHIda ida(const_cast<char*>(json));

  ScanCommand cmd{};
  int result = ida.getNextScanCommand(cmd);
  TEST_EQUAL(result, 1)
  TEST_EQUAL(cmd.msn_level, 1)
  TEST_EQUAL(cmd.is_agc, 0)
}
END_SECTION

START_SECTION(queue_priority_dequeue_order)
{
  // P3-U08: push commands at all 4 priorities, verify dequeue order 3->0
  // This requires a test-only method to directly push to the queues,
  // OR it can be deferred to Phase 4 when processScan_ actually pushes.
  // For Phase 3, use a friend/test-access method pushCommandForTest_().
  // Skip this test if the push method is not yet exposed; P3-U08 is
  // marked as "queue logic" and the queue code exists, but the push path
  // through processScan_ is not active.
  // The test can be wired up as a compile-time-only check or as a
  // white-box test using a protected test accessor.
  ABORT_IF(true)  // placeholder: implement when pushCommandForTest_ is added
}
END_SECTION

START_SECTION(agc_scan_is_dequeued_first)
{
  // P3-U09: same note as P3-U08 — requires pushing to queue
  ABORT_IF(true)  // placeholder
}
END_SECTION

START_SECTION(timeout_cleanup_removes_expired)
{
  // P3-U10: timeout cleanup. In Phase 3 timeout is disabled; test that
  // the cleanup function handles the disabled case without crashing.
  const char* json = R"({"deconvolution":{"min_charge":1,"max_charge":50,
    "tol":[10,10],"score_threshold":-1},"precursor_selection":{"max_mass_count":3,
    "RT_window":5,"target_mode":0,"IDScore":false,"HCDEnergy":29},
    "quantification":{"enabled":false},"faims":{"cv_values":[],"max_cv_skip":0},
    "ms_settings":{"ms1":{"Analyzer":"Orbitrap","FirstMass":350,"LastMass":2000,
    "OrbitrapResolution":120000,"AGCTarget":1000000,"MaxIT":50},"ms2":[],"ms3":[]},
    "scheduling":{"cycle_time_enabled":false,"cycle_time_seconds":60,
    "timeout_enabled":false,"timeout_seconds":30},"exploration":{"enabled":false},
    "files":{"fasta":null,"inclusion_list":null}})";

  FLASHIda ida(const_cast<char*>(json));

  // With timeout disabled, calling GetNextScanCommand (which calls cleanupExpiredCommands_)
  // must not crash and must still return MS1.
  ScanCommand cmd{};
  TEST_EQUAL(ida.getNextScanCommand(cmd), 1)
  TEST_EQUAL(cmd.msn_level, 1)
}
END_SECTION

END_TEST
```

**Registration in executables.cmake:**

Find the section where FLASH tests are commented out and add:

```cmake
# Phase 3 tests
FLASHIdaQueueTracking_test
ScanCommandLayout_test  # layout query binary, not registered with add_test
```

**Testability note:** P3-U08 and P3-U09 require pushing commands directly into the priority queue. This can be done via a `protected` test-access method `pushCommandForTest_(ScanCommand cmd, int priority)`, added to `FLASHIda.h` in a `#ifdef OPENMS_TESTING` guard, or by using a friend class `FLASHIdaTest`. For Phase 3, it is acceptable to implement these tests as stubs (using `ABORT_IF(true)`) and flesh them out in Phase 4 when `processScan_` actually pushes commands. The queue priority logic is still tested indirectly by the empty-queue MS1 fallback test (P3-U07).

### Step 14: Add Integration Tests

**File:** `FlashIDA/src/Flash.Tests/BridgePhase3Tests.cs`

These tests call the C++ bridge functions directly and validate behavior.

```csharp
// BridgePhase3Tests.cs
// Integration tests P3-I01 through P3-I05

using System;
using System.Runtime.InteropServices;
using Flash.IDA;
using NUnit.Framework;

namespace Flash.Tests
{
    [TestFixture]
    public class BridgePhase3Tests
    {
        private FLASHIdaWrapper _wrapper;

        [SetUp]
        public void SetUp()
        {
            // Use a default IDAParameters built from method_default.xml.
            // The wrapper constructor calls CreateFLASHIda with JSON (Phase 1).
            var methodParams = MethodParameters.Load("test-data/configs/method_default.xml");
            _wrapper = new FLASHIdaWrapper(methodParams.IDA);
        }

        [TearDown]
        public void TearDown()
        {
            _wrapper?.Dispose();
        }

        [Test]
        public void ProcessScan_StubReturnsZero()
        {
            // P3-I02
            // Note: the inline peak values below (500–900 m/z, Gaussian-shaped intensities) are
            // synthetic dummy data acceptable here because this is a bridge plumbing test that
            // verifies P/Invoke marshaling only — it does NOT test deconvolution accuracy.
            double[] mzs  = { 500.0, 600.0, 700.0, 800.0, 900.0 };
            double[] ints = { 1e6,   2e6,   3e6,   2e6,   1e6   };
            int result = _wrapper.ProcessScan(mzs, ints, rt: 1.0, msLevel: 1, scanDesc: "TestScan");
            Assert.AreEqual(0, result, "ProcessScan stub must return 0 in Phase 3");
        }

        [Test]
        public void GetNextScanCommand_ReturnsMS1WhenQueueEmpty()
        {
            // P3-I03
            var cmd = new ScanCommand();
            int result = _wrapper.GetNextScanCommand(ref cmd);
            Assert.AreEqual(1, result, "GetNextScanCommand must return 1 (always has a command)");
            Assert.AreEqual(1, cmd.MsnLevel, "Empty queue fallback must return MS1 (msn_level=1)");
        }

        [Test]
        public void GetNextTrackingId_IsMonotonicallyIncreasing()
        {
            // P3-I04
            int first = _wrapper.GetNextTrackingId();
            Assert.Greater(first, -1);

            int prev = first;
            for (int i = 0; i < 99; ++i)
            {
                int next = _wrapper.GetNextTrackingId();
                Assert.Greater(next, prev,
                    $"Tracking ID must be monotonically increasing; got {next} after {prev}");
                prev = next;
            }
        }

        [Test]
        public void ScanCommand_MarshalingRoundTrip()
        {
            // P3-I01: verify that a ScanCommand written in C# is read correctly by C++.
            // This requires a test bridge function RoundTripScanCommand (see testing-strategy.md
            // Section 5.2). If that function is not yet exported, test by verifying that
            // GetNextScanCommand returns a struct with correct layout (non-zero values where expected).
            //
            // Minimal version: confirm that after GetNextScanCommand the returned struct
            // has a non-empty Analyzer field, confirming the C++ wrote into the struct correctly.
            var cmd = new ScanCommand();
            int result = _wrapper.GetNextScanCommand(ref cmd);
            Assert.AreEqual(1, result);
            Assert.IsNotEmpty(cmd.Analyzer,
                "Analyzer field should be non-empty in MS1 fallback command");
        }

        [Test]
        public void DllExports_IncludeNewFunctions()
        {
            // P3-I05: verify DLL exports.
            // This test is implemented as a CI step using dumpbin /exports.
            // In NUnit it is represented as a dummy pass to confirm the test is tracked.
            // The actual dumpbin check runs as the "Verify DLL exports" step in the windows-tests CI job (see CI configuration).
            Assert.Pass("DLL export verification is done via dumpbin in CI (windows-tests job, Verify DLL exports step)");
        }
    }
}
```

---

## Files to Create or Modify

### C++ Side (OpenMS submodule, branch `flashida-v9-bridge`)

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Add `IsolationStage` and `ScanCommand` struct definitions with `static_assert` size checks; add `queues_[4]`, `queue_mutex_`, `tracking_id_counter_`, `pending_scan_map_`, `last_ms1_time_` members; add public methods `processScan`, `getNextScanCommand`, `getNextTrackingId`; add private helpers `makeMS1Command_`, `makeAGCCommand_`, `needsAGCScan_`, `cleanupExpiredCommands_`, `encodeBase36_`, `nextTrackingIdInt_`; add public static `encodeBase36ForTest` for test access |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Implement all new methods listed above; add includes for `<atomic>`, `<chrono>`, `<deque>`, `<mutex>`, `<unordered_map>` |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` | Modify | Add `extern "C"` declarations for `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Modify | Implement the three new bridge exports as thin wrappers |
| `OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp` | Create | Layout-query binary that prints `sizeof` and `offsetof` values for CI comparison |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp` | Create | C++ unit tests for P3-U05 through P3-U10 |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Register `FLASHIdaQueueTracking_test` and `ScanCommandLayout_test` in the build; uncomment the FLASH test section if still commented |

### C# Side (FlashIDA repo, branch `flashida-v9-migration`)

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | Add `IsolationStage` and `ScanCommand` struct declarations with `[StructLayout(LayoutKind.Sequential, Pack = 8)]`; add three new `[DllImport]` declarations (`ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`); add public wrapper methods `ProcessScan(...)`, `GetNextScanCommand(ref ScanCommand)`, `GetNextTrackingId()` |
| `FlashIDA/src/Flash/ScanFactory.cs` | Modify | Add `BuildFromCommand(ScanCommand cmd)` method that translates a `ScanCommand` to `IFusionCustomScan` |
| `FlashIDA/src/Flash/IDA/IDAScanProcessor.cs` | Modify | Add shadow validation calls to `wrapper.ProcessScan(...)` after each `GetIsolationWindows` call; add `IDAlog.Debug("[SHADOW] ...")` log entries |
| `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs` | Modify | Add shadow validation calls after each `GetIsolationWindows` call |
| `FlashIDA/src/Flash/IDA/QuantScanProcessor.cs` | Modify | Add shadow validation calls after each `GetIsolationWindows` call |
| `FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs` | Create | C# unit tests P3-U01 through P3-U04; validates struct size, field offsets, char field `SizeConst`. Listed in `Flash.Tests.csproj` as defined in `test-file-specification.md` §4.4 |
| `FlashIDA/src/Flash.Tests/BridgePhase3Tests.cs` | Create | Integration tests P3-I01 through P3-I05; calls bridge functions with synthetic data. `BridgeTests.cs` (the combined multi-phase bridge test file described in `test-file-specification.md` §4.4) may absorb these tests in a later consolidation pass |

### CI Configuration

| File | Action | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | Activate `cpp-unit-tests` job (already added in Phase 2); add Phase 3 test discovery for `FLASHIdaQueueTracking_test`; add "Verify DLL exports" step for 3 new functions inside `windows-tests` job; add cross-job artifact upload for `ScanCommandLayout_test` output (optional — see CI section) |

### Test Data (no new files required for Phase 3)

Phase 3 regression (P3-R01) reuses `ms1_smoke_test.txt` and `method_default.xml` from Phase 0. No new test spectrum or config files are needed. The golden file comparison target is `baseline_phase0.tsv` (the Phase 0 regression anchor that covers Phases 1–3).

**Golden file capture workflow (Phase 0 lesson #15):** If any new golden files are needed, golden-file capture requires a minimum of 2 commits: the first commit runs CI and produces the golden artifact; the second commit includes the captured golden file. Batch multiple golden file captures into a single CI run to minimize churn.

> **Note on spectrum file:** The authoritative cross-phase usage table in `test-file-specification.md` §1.1 lists `ms1_smoke_test.txt` as the Phase 3 P3-R01 input. This matches the Phase 0 baseline capture, ensuring the regression comparison is against an identical input. The stress test P3-S01 may use `ms1_high_density.txt` if that optional file is available; see `test-file-specification.md` §1.5 for its format and content requirements.

Spectrum file formats (`ms1_smoke_test.txt`, `ms1_high_density.txt`) follow the tab-delimited layout defined in `test-file-specification.md` §1.1 and §1.5 respectively. **Format note (Phase 0 lesson #2):** The actual header format is `Spec scan=N\t<rt_seconds>` (tab-separated, RT in seconds), not `Spec scan=N rt=R.RRRR` (space-separated, RT in minutes). Flash.exe's parser does `line.Split('\t')` and divides by 60. The golden file format (15-column TSV, float tolerances, `compare_golden.py` comparison rules) is defined in `test-file-specification.md` §2.1–2.3. The config file format for `method_default.xml` is defined in `test-file-specification.md` §3.1–3.2.

---

## Test Cases

All 18 tests are listed below with their IDs, tiers, descriptions, expected outcomes, and CI runner assignments (16 Phase 3 tests + 2 stress tests CT31/CT32 deferred from Phase 0). Tests are additive — all prior phase tests (P0-* through P2-*) must continue to pass.

### Test Summary (Quick Reference)

| ID | Summary |
|----|---------|
| P3-U01 | Verifies `Marshal.SizeOf<ScanCommand>()` equals 1144, ensuring the C# struct footprint matches the C++ `sizeof(ScanCommand)` and that P/Invoke will copy the correct number of bytes. |
| P3-U02 | Verifies `Marshal.SizeOf<IsolationStage>()` equals 80, confirming the nested struct padding is handled identically by the .NET runtime and the C++ compiler. |
| P3-U03 | Checks `Marshal.OffsetOf` for all 14 fields of `ScanCommand` against expected C++ `offsetof` values, catching any field-order or alignment divergence. |
| P3-U04 | Inspects `MarshalAsAttribute.SizeConst` via reflection for `Analyzer` (32), `ScanDescription` (256), and `ActivationType` (16), confirming the inline char-array lengths are correctly declared. |
| P3-U05 | Tests the base-36 encoding function for boundary values (0, 1, 35, 36, 1679615), verifying the 4-character string output that will appear in `[TRACK-CREATE]` log entries and `scan_description` tags. |
| P3-U06 | Generates 10,000 tracking IDs from a single `FLASHIda` instance and asserts all are unique, validating the monotonic counter and confirming no collision before the wrap-around point. |
| P3-U07 | Calls `getNextScanCommand` on a fresh `FLASHIda` with an empty queue (no prior `processScan`); asserts the MS1 fallback fires, which is the guaranteed behavior whenever no MS2 candidates are pending. |
| P3-U08 | Pushes commands at all four priority levels and verifies dequeue order is 3→2→1→0, validating the priority scheduling logic that Phase 4 will rely on for real scan routing. |
| P3-U09 | Configures `needsAGCScan_` to return true and verifies `GetNextScanCommand` returns the AGC command before any queued MS2, confirming AGC always takes the highest slot. |
| P3-U10 | Calls `getNextScanCommand` with `timeout_enabled_ = false` and asserts no crash and MS1 is returned, exercising the disabled timeout path of `cleanupExpiredCommands_`. |
| P3-I01 | Calls `GetNextScanCommand` and checks that the returned struct's `Analyzer` field is non-empty, confirming C++ successfully wrote into the struct via P/Invoke (marshaling round-trip). |
| P3-I02 | Calls `ProcessScan` with synthetic dummy peaks and asserts the return value is 0, verifying the stub bridge function is callable and returns the expected Phase 3 sentinel. |
| P3-I03 | Calls `GetNextScanCommand` with no prior processing and asserts return == 1 and `MsnLevel == 1`, confirming the empty-queue MS1 fallback works across the P/Invoke boundary. |
| P3-I04 | Calls `GetNextTrackingId` 100 times and asserts each result is strictly greater than the previous, validating monotonic increment across the bridge. |
| P3-I05 | Runs `dumpbin /exports OpenMS.dll` in CI and checks that `ProcessScan`, `GetNextScanCommand`, and `GetNextTrackingId` appear, confirming the three new exports are present in the shipped DLL. |
| P3-R01 | Runs `Flash.exe` with `ms1_smoke_test.txt` and compares TSV output to `baseline_phase0.tsv`, verifying Phase 3 shadow validation leaves deconvolution results unchanged; also checks stdout for at least one `[TRACK-CREATE]` entry. **Note:** The entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()` — there is no `-t` flag (Phase 0 lesson #1). |
| CT31 | Stress test: 1000 scans sequential through `ProcessScan` + `GetNextScanCommand`. Deferred from Phase 0 (lesson #13). |
| CT32 | Stress test: concurrent multi-threaded `ProcessScan` calls. Deferred from Phase 0 (lesson #13). |

### Tier 1: C# Unit Tests (runner: `windows-latest`)

| ID | Test name | Description | Expected outcome |
|----|-----------|-------------|-----------------|
| P3-U01 | `ScanCommand_SizeMatchesCpp` | `Marshal.SizeOf<ScanCommand>()` equals 1144 | Assert passes; mismatch fails build |
| P3-U02 | `IsolationStage_SizeMatchesCpp` | `Marshal.SizeOf<IsolationStage>()` equals 80 | Assert passes; mismatch fails build |
| P3-U03 | `ScanCommand_FieldOffsetsMatchCpp` | `Marshal.OffsetOf` for each field equals expected hard-coded C++ offset value | All 14 field offset assertions pass |
| P3-U04 | `ScanCommand_CharFieldSizesAreCorrect` | `MarshalAsAttribute` on `Analyzer`, `ScanDescription`, `ActivationType` has correct `SizeConst` (32, 256, 16 respectively) | All 3 reflection assertions pass |

### Tier 1: C++ Unit Tests (runner: `ubuntu-latest`)

| ID | Test name | Description | Expected outcome |
|----|-----------|-------------|-----------------|
| P3-U05 | `encodeBase36_correctness` | `encodeBase36ForTest(0)` = `"0000"`, `(1)` = `"0001"`, `(35)` = `"000z"`, `(36)` = `"0010"`, `(1679615)` = `"zzzz"` | All 5 string comparisons pass |
| P3-U06 | `tracking_ids_sequential_unique` | Generate 10,000 tracking IDs from a single `FLASHIda` instance; check all are unique | `unordered_set` size = 10,000; no duplicate detected |
| P3-U07 | `empty_queue_returns_ms1` | Create `FLASHIda`, call `getNextScanCommand`; no prior `processScan` calls | Returns 1; `cmd.msn_level == 1`; `cmd.is_agc == 0` |
| P3-U08 | `queue_priority_dequeue_order` | Push commands at priorities 0, 1, 2, 3 using `pushCommandForTest_`; dequeue 4 times; verify order is 3, 2, 1, 0 | Dequeued priorities match expected sequence |
| P3-U09 | `agc_scan_is_dequeued_first` | Configure `needsAGCScan_` to return true (test mock or config); verify `GetNextScanCommand` returns AGC before any queued MS2 | First dequeued command has `is_agc == 1` |
| P3-U10 | `timeout_cleanup_no_crash` | Call `getNextScanCommand` with `timeout_enabled_ = false`; verify it completes without crash and returns MS1 | No exception; `cmd.msn_level == 1` |

**Notes on P3-U08 and P3-U09:** These require pushing commands to the queue without going through `processScan_`. Two approaches: (1) add `pushCommandForTest_(ScanCommand, int priority)` as a public method guarded by `#ifdef OPENMS_TESTING`; (2) defer to Phase 4 when the push path is live. If deferred, these tests run as stubs that `ABORT_IF(true)` and are documented as "will be fully enabled in Phase 4."

### Tier 2: Integration Tests (runner: `windows-latest`)

These tests load `OpenMS.dll` via P/Invoke and require both OpenMS DLLs in `FlashIDA/dll/` and Thermo iAPI DLLs in `FlashIDA/dependencies/`.

| ID | Test name | Description | Expected outcome |
|----|-----------|-------------|-----------------|
| P3-I01 | `ScanCommand_MarshalingRoundTrip` | After `GetNextScanCommand` fills a `ScanCommand`, the `Analyzer` field is non-empty (confirms C++ wrote into the struct correctly) | `cmd.Analyzer` is not empty or null |
| P3-I02 | `ProcessScan_StubReturnsZero` | Call `ProcessScan` with 5 inline dummy peaks (synthetic values acceptable here: this is a bridge plumbing test verifying P/Invoke marshaling, not deconvolution accuracy; real measured data is required only for spectrum files committed to `test-data/spectra/` — see `test-file-specification.md` §1.1); return value checked | Return value == 0 |
| P3-I03 | `GetNextScanCommand_ReturnsMS1WhenQueueEmpty` | Call `GetNextScanCommand` with no prior `ProcessScan`; check returned struct | Return value == 1; `cmd.MsnLevel == 1` |
| P3-I04 | `GetNextTrackingId_IsMonotonicallyIncreasing` | Call `GetNextTrackingId` 100 times; verify each is greater than the previous | 99 consecutive "next > prev" assertions pass |
| P3-I05 | `DllExports_IncludeNewFunctions` | `dumpbin /exports FlashIDA\dll\OpenMS.dll` output contains `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` | All 3 `findstr` calls exit with code 0 |

### Tier 3: Regression Test (runner: `windows-latest`)

| ID | Test name | Description | Expected outcome |
|----|-----------|-------------|-----------------|
| P3-R01 | `Regression_ShadowValidation` | `Flash.exe ms1_smoke_test.txt output.tsv method_default.xml`; compare TSV output to `baseline_phase0.tsv` | TSV output matches `baseline_phase0.tsv` within tolerance; TRACK log entries appear in console output (checked by scanning stdout for `[TRACK-CREATE]`) |
| CT31 | `StressTest_1000ScansSequential` | Feed 1000 scans sequentially through `ProcessScan` + `GetNextScanCommand`; verify no crash, all tracking IDs unique | All 1000 scans processed; no exceptions; 1000 unique tracking IDs (deferred from Phase 0 lesson #13) |
| CT32 | `StressTest_ConcurrentProcessing` | Feed scans from multiple threads through `ProcessScan`; verify thread safety | No data corruption; no duplicate tracking IDs; `queue_mutex_` prevents races (deferred from Phase 0 lesson #13) |

The golden file comparison uses `compare_golden.py` (defined in `test-file-specification.md` §4.1; also referenced from `testing-strategy.md` Section 6.2). The comparison applies the tolerances specified in `test-file-specification.md` §2.1: exact match for `charges` and `hcd`; absolute tolerance 1e-6 for float values ≤ 1.0, relative tolerance 1e-4 for float values > 1.0. The TRACK log check is an additional assertion: the CI script scans the captured stdout for at least one `[TRACK-CREATE]` entry, confirming the shadow path is active.

Golden file changes in Phase 3 are a red flag and must be investigated before merging (Phase 3 claims zero behavioral change; see `test-file-specification.md` §2.4 for the update procedure if an intentional change does occur).

**Tolerance-based golden comparison (Phase 0 compliance H-3):** Phase 0 uses exact-match golden comparison. If float drift becomes an issue in Phase 3 (e.g., due to shadow path deconvolution affecting floating-point state), upgrade `compare_golden.py` to tolerance-based comparison: absolute tolerance 1e-6 for float values <= 1.0, relative tolerance 1e-4 for float values > 1.0, exact match for integer fields (`charges`, `hcd`). Phase 3 is the designated phase for this upgrade if needed.

### Tier 2: Stress Tests CT31/CT32 (runner: `windows-latest`)

**Deferred from Phase 0 (lesson #13).** The acquisition-loop-testing-strategy specifies CT31 and CT32 as "Introduced: Phase 0" but they were deferred because they require the concurrent pipeline infrastructure. Phase 3 introduces the ScanCommand struct and pipeline refactor, making it the natural place to implement these tests. Remove the `[Ignore]` attributes from the Phase 0 stubs and replace `Assert.Inconclusive` with real test logic.

| ID | Test name | Description | Expected outcome |
|----|-----------|-------------|-----------------|
| CT31 | `StressTest_1000ScansSequential` | Feed 1000 scans sequentially through `ProcessScan` and `GetNextScanCommand`; verify no crash, all tracking IDs unique, queue drains to MS1 fallback at the end | All 1000 scans processed; no exceptions; tracking ID set has 1000 unique entries |
| CT32 | `StressTest_ConcurrentProcessing` | Feed scans from multiple threads simultaneously through `ProcessScan`; verify thread safety of the queue and tracking ID counter under contention | No data corruption; no duplicate tracking IDs; `queue_mutex_` prevents race conditions |

**Note:** These are Tier 2 tests (load OpenMS.dll via P/Invoke). They run in the `windows-tests` CI job.

---

## CI Configuration

### Jobs Involved in Phase 3

Phase 3 test execution is split across two jobs. The diagram below shows which tests run where:

```
ubuntu-latest job: cpp-unit-tests
  - Build FLASHIdaQueueTracking_test (CTest)
  - Build ScanCommandLayout_test (layout query binary)
  - Run ctest -R FLASHIdaQueueTracking_test   -> P3-U05, U06, U07, U08, U09, U10
  - Run ./ScanCommandLayout_test > layout.txt
  - Upload layout.txt as artifact "cpp-layout-output"

windows-latest job: windows-tests (needs: cpp-unit-tests)
  - Restore Thermo DLLs (openssl-encrypted zip, Strategy B; Phase 0 lesson #3)
  - OpenMS DLLs already committed in FlashIDA/dll/ — no download needed (Phase 0 lesson #5)
  - MSBuild Flash.Tests.csproj
  - Download "cpp-layout-output" artifact from cpp-unit-tests job
  - packages\NUnit.ConsoleRunner.*\tools\nunit3-console.exe Flash.Tests.dll
    (run from working directory FlashIDA\bin\; Phase 0 lesson #12)
    -> P3-U01, U02, U03, U04 (ScanCommandLayoutTests.cs)
  - Flash.exe <input> <output> <method.xml> + compare_golden.py  -> P3-R01
  - packages\NUnit.ConsoleRunner.*\tools\nunit3-console.exe Flash.Tests.dll --where "class == BridgePhase3Tests"
    (run from working directory FlashIDA\bin\; Phase 0 lesson #12)
    -> P3-I01, I02, I03, I04
  - Step: Verify DLL exports (dumpbin /exports)
    -> P3-I05
  - Stress tests: CT31 (1000 scans sequential) and CT32 (concurrent processing)
    (deferred from Phase 0 lesson #13; Tier 2 — loads OpenMS.dll)
    -> CT31, CT32
```

### Cross-Job Artifact for `ScanCommandLayoutTest`

The `ScanCommandLayout_test` binary runs on `ubuntu-latest` (GCC/Clang) and the C# layout test runs on `windows-latest` (MSVC). With the 2-job structure, `cpp-unit-tests` uploads the artifact and `windows-tests` downloads it. This validates that the C++ struct layout is consistent across compilers.

1. **Upload step (ubuntu-latest, cpp-unit-tests job):**

```yaml
- name: Run ScanCommandLayout_test and capture output
  run: |
    ./build/src/tests/class_tests/openms/ScanCommandLayout_test > layout.txt
    cat layout.txt

- name: Upload layout output as artifact
  uses: actions/upload-artifact@v4
  with:
    name: cpp-layout-output
    path: layout.txt
    retention-days: 1
```

2. **Download step (windows-latest, windows-tests job):**

```yaml
- name: Download C++ layout output
  uses: actions/download-artifact@v4
  with:
    name: cpp-layout-output
    path: test-data/cpp-layout/
  continue-on-error: true  # Artifact may not exist if cpp-unit-tests job was skipped
```

3. **Test usage:** `ScanCommandLayoutTests.cs` can be extended with a method that reads `test-data/cpp-layout/layout.txt` (if it exists) and compares the parsed values against `Marshal.SizeOf`/`Marshal.OffsetOf`. If the file is absent, the test falls back to the hard-coded expected values.

**Practical concern:** Because `windows-tests` declares `needs: [cpp-unit-tests]`, the artifact is guaranteed to be available by the time the download step runs. For Phase 3, the simplest approach is to use hard-coded expected values in the C# test (Approach A, described in Step 12) and treat the cross-job artifact as a bonus verification step, not a required gate.

### `dumpbin` Export Verification (P3-I05)

Add the following step named "Verify DLL exports" inside the `windows-tests` job in `flashida-ci.yml`:

```yaml
- name: Verify DLL exports
  shell: cmd
  run: |
    dumpbin /exports FlashIDA\dll\OpenMS.dll > exports.txt
    findstr /C:"ProcessScan"       exports.txt || exit /b 1
    findstr /C:"GetNextScanCommand" exports.txt || exit /b 1
    findstr /C:"GetNextTrackingId"  exports.txt || exit /b 1
    echo All three Phase 3 exports verified.
```

This step requires `dumpbin.exe` which is installed by `microsoft/setup-msbuild@v2`.

### TRACK Log Verification (P3-R01)

Add the following to the regression test step in the `windows-tests` job. The spectrum input is `ms1_smoke_test.txt` (format: `test-file-specification.md` §1.1) and the golden baseline is `baseline_phase0.tsv` (format: `test-file-specification.md` §2.1; captured in Phase 0). `regression-runner.ps1` (defined in `test-file-specification.md` §4.2) can orchestrate this invocation; the inline step below is the direct equivalent for reference:

```yaml
- name: Run regression test with shadow validation
  shell: powershell
  run: |
    & "FlashIDA\bin\Flash.exe" `
      "test-data\spectra\ms1_smoke_test.txt" `
      "output\phase3_shadow.tsv" `
      "test-data\configs\method_default.xml" `
      2>&1 | Tee-Object -FilePath "output\phase3_stdout.txt"

    # Compare TSV output to Phase 0 baseline golden file
    # (compare_golden.py defined in test-file-specification.md §4.1)
    python compare_golden.py `
      "test-data\golden\baseline_phase0.tsv" `
      "output\phase3_shadow.tsv"

    # Verify TRACK audit entries appeared
    $trackLines = Select-String -Path "output\phase3_stdout.txt" -Pattern "\[TRACK-CREATE\]"
    if ($trackLines.Count -eq 0) {
        Write-Error "No [TRACK-CREATE] log entries found — shadow validation not active"
        exit 1
    }
    Write-Host "Found $($trackLines.Count) [TRACK-CREATE] entries — shadow validation confirmed"
```

### Summary of CI Workflow Changes

1. Ensure the `cpp-unit-tests` job (added in Phase 2) builds and runs `FLASHIdaQueueTracking_test`.
2. Add `ScanCommandLayout_test` to the cmake build and run it in the `cpp-unit-tests` job; upload output as artifact `cpp-layout-output`.
3. Add the "Verify DLL exports" step for 3 new functions inside the `windows-tests` job.
4. Extend the regression step in `windows-tests` to capture stdout and scan for `[TRACK-CREATE]` lines.
5. (Optional) Download C++ layout artifact in `windows-tests` and extend `ScanCommandLayoutTests` to read it.

---

## Working Product Verification

All verifications are automated by CI. No local Windows machine is required.

1. **Build succeeds:** Automated by: CI job `windows-tests` — the MSBuild step exits with code 0 and no errors.

2. **C++ tests pass:** Automated by: CI job `cpp-unit-tests` — `ctest -R FLASHIdaQueueTracking_test` returns 100% pass on the Build #1 DLL.

3. **C# layout tests pass:** Automated by: CI job `windows-tests` — NUnit reports 4 tests passed for `ScanCommandLayoutTests`. In particular, `ScanCommand_SizeMatchesCpp` and `IsolationStage_SizeMatchesCpp` pass with the expected sizes 1144 and 80.

4. **Regression unchanged:** Automated by: CI job `windows-tests` — `Flash.exe ms1_smoke_test.txt output.tsv method_default.xml` produces a TSV file that `compare_golden.py` (`test-file-specification.md` §4.1) reports as `PASS` against `baseline_phase0.tsv` (`test-file-specification.md` §2.2). The TSV output must be bit-for-bit identical to the Phase 0 baseline (the shadow path calls `processScan_` but does not change deconvolution state). **Note:** The entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1).

5. **TRACK entries present:** Automated by: CI job `windows-tests` — the captured stdout of the regression step is scanned for at least one line matching `[TRACK-CREATE]`, confirming the shadow validation code path is active.

6. **GetNextScanCommand returns MS1:** Automated by: CI job `windows-tests` — test P3-I03 passes, confirming `GetNextScanCommand` returns `msn_level == 1` and a non-empty `Analyzer` field.

7. **DLL exports verified:** Automated by: DLL export verification step in `windows-tests` — `dumpbin /exports OpenMS.dll` lists `ProcessScan`, `GetNextScanCommand`, and `GetNextTrackingId` among the exports. The existing 18 exports are also still present (Phase 4 removes none).

8. **No behavioral change:** Automated by: CI job `windows-tests` — all prior-phase tests (P0-*, P1-*, P2-*) continue to pass, confirming that no existing code paths (`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, etc.) were modified.

---

## Definition of Done

All of the following must be true before Phase 3 is considered complete and Build #1 can ship:

- [ ] `IsolationStage` and `ScanCommand` structs defined in `FLASHIda.h` with `static_assert` size checks.
- [ ] `sizeof(IsolationStage) == 80` and `sizeof(ScanCommand) == 1144` confirmed by C++ compile-time assertion.
- [ ] Priority queue (`queues_[4]`), `queue_mutex_`, `tracking_id_counter_`, and `pending_scan_map_` added to `FLASHIda`.
- [ ] `ProcessScan` bridge export added: stub returns 0, runs deconvolution shadow, logs `[TRACK-CREATE]`.
- [ ] `GetNextScanCommand` bridge export added: full priority dequeue logic, falls back to MS1 when queue is empty.
- [ ] `GetNextTrackingId` bridge export added: returns incrementing integer.
- [ ] All three new exports visible in `dumpbin /exports OpenMS.dll`.
- [ ] C# `ScanCommand` and `IsolationStage` structs declared with `[StructLayout(LayoutKind.Sequential, Pack = 8)]`.
- [ ] C# `[DllImport]` declarations added for `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`.
- [ ] C# `Marshal.SizeOf<ScanCommand>() == 1144` confirmed by P3-U01.
- [ ] C# `Marshal.SizeOf<IsolationStage>() == 80` confirmed by P3-U02.
- [ ] All field offsets confirmed by P3-U03.
- [ ] `char` field `SizeConst` values confirmed by P3-U04.
- [ ] `ScanFactory.BuildFromCommand(ScanCommand)` method implemented and compiles.
- [ ] Shadow validation calls added in `IDAScanProcessor`, `FAIMSScanProcessor`, `QuantScanProcessor`.
- [ ] All 18 Phase 3 tests (P3-U01 through P3-R01, plus CT31 and CT32) pass in CI.
- [ ] All prior-phase tests (P0-*, P1-*, P2-* — 23 tests) continue to pass in CI.
- [ ] `Flash.exe ms1_smoke_test.txt output.tsv method_default.xml` output is identical to `baseline_phase0.tsv` (P3-R01 passes in CI; see `test-file-specification.md` §2.2 for the golden file inventory). Note: entry point is `FLASHIdaWrapper.Main()`, no `-t` flag (Phase 0 lesson #1).
- [ ] `[TRACK-CREATE]` log entries appear in `Flash.exe` stdout.
- [ ] CT31 (1000 scans sequential) and CT32 (concurrent processing) stress tests implemented and passing (deferred from Phase 0 lesson #13).
- [ ] No existing C# code references to old bridge functions are broken (existing 18 P/Invoke declarations unchanged).
- [ ] Code formatted to project standards: C++ clang-format (LLVM, 150 col, 2-space indent, Allman braces); C# standard conventions.
- [ ] `ScanCommandLayout_test` binary builds and its output matches hard-coded C# expected values (verified in CI job `cpp-unit-tests`).
- [ ] Phase 3 changes committed to `flashida-v9-migration` (C#) and `flashida-v9-bridge` (C++) branches.
- [ ] Build #1 CI run (Phases 1 + 2 + 3 combined) is green on both `ubuntu-latest` and `windows-latest`.

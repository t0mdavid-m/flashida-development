# Parameter Optimization Plan — v3 (Bidirectional, C++ as Brain)

**Date:** 2026-03-20
**Revision:** 3
**Design principle:** C++ is the decision-maker. C# is a thin executor that reports instrument state to C++ and queues whatever C++ commands. Communication is bidirectional via a polling-based command channel — no callbacks, no delegate lifetime issues, same P/Invoke pattern as all existing bridge functions.

**Key change from v2:** Instead of C# orchestrating calls to C++ per-scan-type, C++ receives queue state with every spectrum and produces a command queue that C# drains blindly. C++ can schedule scans proactively — not just in response to "which precursor should I target?" but "the queue is short, add another MS1" or "I've seen enough exploration results, queue the final scan now."

---

## Issue 1 — Queue-Aware Spectrum Processing (C++ Receives Instrument State)

### Desired behaviour
Every time C# sends a spectrum to C++ for processing, it also reports the current scan queue state: total queue length, number of MS1s pending, number of MS2s pending. C++ uses this to make informed scheduling decisions — e.g., "queue has 8 scans, don't add more exploration variants" or "queue is empty, the exploration results I need are about to be acquired."

### Limitations of current design
C++ functions (`GetPeakGroupSize`, `DeconvolveMS2`, etc.) receive only spectrum data. They have no visibility into the instrument's scan queue. Scheduling decisions that depend on queue occupancy (e.g., "should I request more scans or wait?") can only be made on the C# side, which defeats the goal of C++ control.

### Proposed change
Add a bridge function that C# calls once per scan cycle, before any other processing:

```cpp
// Bridge function — called at the start of each ProcessMS cycle
extern "C" OPENMS_DLLAPI void SetQueueState(
    FLASHIda* object,
    int queue_length,       // total scans in queue
    int ms1_pending,        // MS1 scans pending
    int ms2_pending);       // MS2 scans pending
```

C++ stores this in simple member variables:

```cpp
// In FLASHIda (private)
int queue_length_ = 0;
int ms1_pending_ = 0;
int ms2_pending_ = 0;
```

C# calls this at the top of `ProcessMS()`:

```csharp
wrapper.SetQueueState(
    scanScheduler.customScans.Count,
    scanScheduler.MS1Count,
    scanScheduler.MS2Count);
```

This is a one-line addition to `ProcessMS()`. All existing bridge functions can now internally read `queue_length_` to modulate their behaviour without signature changes.

**Files:** `FLASHIdaBridgeFunctions.h`, `FLASHIdaBridgeFunctions.cpp`, `FLASHIda.h`, `FLASHIda.cpp`, `IDAScanProcessor.cs`, `FLASHIdaWrapper.cs`

---

## Issue 2 — Command Channel (C++ Schedules Scans)

### Desired behaviour
C++ can produce scan commands at any point during processing. After C# finishes a bridge call, it drains all pending commands from C++ and queues them. Commands specify full scan parameters (scan type, precursor m/z, isolation width, CE, charge, etc.). C# builds Thermo API scan objects from these parameters without interpreting them. C++ decides what to schedule; C# just executes.

### Limitations of current design
Communication is strictly C#→C++. C++ returns data (isolation windows, scores, peak counts) that C# interprets and converts to scans. C++ cannot say "queue this specific scan" — it can only answer questions. The scan creation logic (which parameters, how many scans, what type) lives in C# (`IDAScanProcessor.ProcessMS()`), which means any new scan scheduling strategy requires C# changes.

### Proposed change
Add an internal command queue to `FLASHIda` and two bridge functions to drain it:

```cpp
// In FLASHIda (private)
struct ScanCommand
{
    int command_type;         // 1=MS1, 2=MS2, 3=MS3
    double precursor_mz;     // 0 for MS1
    double isolation_width;
    int collision_energy;
    int charge;
    double first_mass;        // scan range start
    double last_mass;         // scan range end
    int scan_id;              // tracking ID for scan description
    int priority;             // 0=normal, 1=high (C++-initiated)
};

std::vector<ScanCommand> pending_commands_;
```

Bridge functions (same two-phase pattern as `GetPeakGroupSize` + `GetIsolationWindows`):

```cpp
extern "C" OPENMS_DLLAPI int GetPendingCommandCount(FLASHIda* object);

extern "C" OPENMS_DLLAPI void GetPendingCommands(
    FLASHIda* object,
    int* command_types,
    double* precursor_mzs,
    double* isolation_widths,
    int* collision_energies,
    int* charges,
    double* first_masses,
    double* last_masses,
    int* scan_ids,
    int* priorities);
```

`GetPendingCommands` fills caller-allocated arrays (blittable, zero-copy via pinning) and clears the internal queue. C# drains at the end of every `ProcessMS()` call:

```csharp
// At the end of ProcessMS(), regardless of scan type:
int cmdCount = wrapper.GetPendingCommandCount();
if (cmdCount > 0)
{
    var commands = wrapper.DrainPendingCommands(cmdCount);
    foreach (var cmd in commands)
    {
        var scan = BuildScanFromCommand(cmd);
        if (cmd.Priority > 0)
            scans.Insert(0, scan);  // high-priority: front of return list
        else
            scans.Add(scan);
    }
}
```

This means C++ can inject scans during *any* processing call — MS1 processing, MS2 processing, even during exploration result handling. C# always checks.

**Files:** `FLASHIda.h`, `FLASHIda.cpp`, `FLASHIdaBridgeFunctions.h`, `FLASHIdaBridgeFunctions.cpp`, `FLASHIdaWrapper.cs`, `IDAScanProcessor.cs`

---

## Issue 3 — Priority Queue in ScanScheduler

### Desired behaviour
C++-initiated scans are dequeued before regular scans. When `getNextScan()` is called, it first checks the priority queue; only when that is empty does it fall back to the regular FIFO queue. Default MS1/AGC fallback behaviour is unchanged.

### Limitations of current design
`ScanScheduler` has a single `ConcurrentQueue<IFusionCustomScan>` with FIFO ordering. All scans — MS1 defaults, ProcessMS-generated MS2s, and (future) C++-commanded scans — compete in the same queue. There is no way to express "this scan should go before everything else." The FAIMS mode has a queue-length cap of 7, but no priority mechanism.

### Proposed change
Add a second `ConcurrentQueue` for priority scans:

```csharp
// In ScanScheduler
public ConcurrentQueue<IFusionCustomScan> priorityScans
    = new ConcurrentQueue<IFusionCustomScan>();

public int AddPriorityScan(IFusionCustomScan scan)
{
    priorityScans.Enqueue(scan);
    return priorityScans.Count;
}
```

Modify `getNextScan()` to drain priority first:

```csharp
public IFusionCustomScan getNextScan()
{
    // Priority queue first — C++ commanded scans
    if (priorityScans.TryDequeue(out var priorityScan))
    {
        log.Debug(String.Format("POP priority scan // Queue: {0}, Priority: {1}",
            customScans.Count, priorityScans.Count));
        return priorityScan;
    }

    // Then existing logic (regular queue, default fallback)
    if (customScans.IsEmpty)
    {
        // ... existing empty-queue handling (unchanged) ...
    }
    else
    {
        // ... existing dequeue logic (unchanged) ...
    }
}
```

`OutputMS()` routes scans based on a priority flag:

```csharp
public void OutputMS(IFusionCustomScan scan)
{
    if (scan == null)
    {
        scanScheduler.AddDefault();
    }
    else if (scan.Values.ContainsKey("Priority") && scan.Values["Priority"] == "1")
    {
        scanScheduler.AddPriorityScan(scan);
    }
    else
    {
        scanScheduler.AddScan(scan, 2);
    }
}
```

**Files:** `ScanScheduler.cs`, `IDAScanProcessor.cs`

---

## Issue 4 — C++ Exploration Engine (Internal to FLASHIda)

### Desired behaviour
When C++ processes an MS1 spectrum and identifies a precursor suitable for optimization, it pushes exploration scan commands into its pending command queue (Issue 2). When exploration MS2 results arrive (fed via a dedicated bridge function), C++ deconvolves, scores, and tracks them internally. When all variants are collected, C++ pushes the final optimized scan command as a priority command. The entire exploration lifecycle is managed by C++ — C# just relays spectra and drains commands.

### Limitations of current design
Same as v2 Issue 1: no session concept, no multi-scan accumulation, no comparative scoring. Additionally, no command channel exists for C++ to push scan requests.

### Proposed change
Internal state (private to `FLASHIda`):

```cpp
struct ExplorationVariant
{
    double collision_energy;
    double isolation_width;
    DeconvolvedSpectrum deconv_result;
    double quality_score = -1;
    bool received = false;
};

struct ExplorationGroup
{
    int group_id;
    double target_mass;
    int target_charge;
    double isolation_center_mz;
    std::vector<ExplorationVariant> variants;
    int received_count = 0;
};

std::unordered_map<int, ExplorationGroup> exploration_groups_;
int next_exploration_group_id_ = 0;
```

**How it integrates with the command channel:**

During MS1 processing (`getPeakGroups` / `getIsolationWindows`), if optimization is enabled and `queue_length_` has capacity, C++ creates an `ExplorationGroup`, generates variant parameters from the config grid, and pushes scan commands into `pending_commands_`:

```cpp
// Inside getIsolationWindows or a post-processing step
if (optimization_enabled_ && queue_length_ < max_queue_for_exploration_)
{
    auto& group = createExplorationGroup_(mass, charge, iso_mz);
    for (int i = 0; i < group.variants.size(); i++)
    {
        pending_commands_.push_back({
            .command_type = 2,  // MS2
            .precursor_mz = iso_mz,
            .isolation_width = group.variants[i].isolation_width,
            .collision_energy = (int)group.variants[i].collision_energy,
            .charge = charge,
            .scan_id = encodeExplorationId_(group.group_id, i),
            .priority = 0  // normal priority for exploration variants
        });
    }
}
```

One new bridge function for feeding results (reuses the same pattern as `DeconvolveMS2` but targets the exploration group):

```cpp
extern "C" OPENMS_DLLAPI int FeedExplorationResult(
    FLASHIda* object,
    int group_id,
    int variant_index,
    double* mzs, double* ints, int length,
    double rt);
```

When the last variant is received, C++ internally calls `getOptimizedScanParams_()` and pushes the final scan as a **priority command**:

```cpp
int FLASHIda::feedExplorationResult(int group_id, int variant_index,
                                     const double* mzs, const double* ints,
                                     int length, double rt)
{
    auto& group = exploration_groups_[group_id];
    auto& variant = group.variants[variant_index];

    // Deconvolve into variant's own DeconvolvedSpectrum
    auto spec = makeMSSpectrum_(mzs, ints, length, rt, 2, "exploration");
    variant.deconv_result = fd_.deconvolve(spec);  // simplified
    variant.quality_score = scoreFragmentationQuality(variant.deconv_result,
                                                       group.target_mass,
                                                       group.target_charge);
    variant.received = true;
    group.received_count++;

    if (group.received_count == (int)group.variants.size())
    {
        // Pick winner
        auto& best = *std::max_element(group.variants.begin(), group.variants.end(),
            [](const auto& a, const auto& b) { return a.quality_score < b.quality_score; });

        // Push final scan as PRIORITY command
        pending_commands_.push_back({
            .command_type = 2,
            .precursor_mz = group.isolation_center_mz,
            .isolation_width = best.isolation_width,
            .collision_energy = (int)best.collision_energy,
            .charge = group.target_charge,
            .scan_id = 0,  // regular tracked scan
            .priority = 1  // HIGH PRIORITY — goes to front of queue
        });

        exploration_groups_.erase(group_id);
        return 1;  // complete
    }
    return 0;  // more results expected
}
```

C# side is minimal — just route `~`-prefixed scan descriptions to `FeedExplorationResult` and drain commands as usual (Issue 2 handles the rest).

**Files:** `FLASHIda.h`, `FLASHIda.cpp`, `FLASHIdaBridgeFunctions.h`, `FLASHIdaBridgeFunctions.cpp`

---

## Issue 5 — Fragmentation Quality Scoring

### Desired behaviour
Same as v2: C++ can score an MS2 spectrum's fragmentation quality to rank exploration variants.

### Limitations of current design
Same as v2: no MS2 spectral quality metric exists.

### Proposed change
Same as v2. Add to `PeakGroupScoring`:

```cpp
static double scoreFragmentationQuality(const DeconvolvedSpectrum& deconv_ms2,
                                         double precursor_mass,
                                         int precursor_charge);
```

Combines: weighted fragment count, intensity coverage, mass spread. Returns `double` in [0, 1].

**Files:** `PeakGroupScoring.h`, `PeakGroupScoring.cpp`

---

## Issue 6 — P/Invoke Declarations

### Desired behaviour
C# can call all new bridge functions.

### Limitations of current design
No declarations for `SetQueueState`, `GetPendingCommandCount`, `GetPendingCommands`, or `FeedExplorationResult`.

### Proposed change

```csharp
[DllImport(dllName)]
static private extern void SetQueueState(IntPtr ptr,
    int queueLength, int ms1Pending, int ms2Pending);

[DllImport(dllName)]
static private extern int GetPendingCommandCount(IntPtr ptr);

[DllImport(dllName)]
static private extern void GetPendingCommands(IntPtr ptr,
    int[] commandTypes, double[] precursorMzs, double[] isolationWidths,
    int[] collisionEnergies, int[] charges,
    double[] firstMasses, double[] lastMasses,
    int[] scanIds, int[] priorities);

[DllImport(dllName)]
static private extern int FeedExplorationResult(IntPtr ptr,
    int groupId, int variantIndex,
    double[] mzs, double[] ints, int length, double rt);
```

Plus a public `DrainPendingCommands()` wrapper that allocates arrays, calls the bridge, and returns a typed list.

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 7 — Thin C# Routing in IDAScanProcessor

### Desired behaviour
`ProcessMS()` becomes thinner. It: (1) reports queue state, (2) sends spectrum to C++, (3) routes exploration results by `~` prefix, (4) drains the command channel. All scan creation decisions come from C++.

### Limitations of current design
`ProcessMS()` currently builds MS2 scans in C# from `GetIsolationWindows` output, manages tracking IDs, and handles MS2→MS3 routing logic. Adding exploration on top of this would further bloat the method.

### Proposed change
Add three blocks to `ProcessMS()`:

**Block 1 — Top of method (all scan types):**
```csharp
wrapper.SetQueueState(scanScheduler.customScans.Count,
                      scanScheduler.MS1Count, scanScheduler.MS2Count);
```

**Block 2 — MS2 handling (new branch, before existing `_` prefix handler):**
```csharp
if (scanDesc != null && scanDesc.StartsWith("~") &&
    TryExtractExplorationIds(scanDesc, out int groupId, out int variantIndex))
{
    wrapper.FeedExplorationResult(groupId, variantIndex, mzs, ints, length, rt);
    // Don't add scans here — C++ pushed commands via the command channel
}
```

**Block 3 — Bottom of method (all scan types):**
```csharp
int cmdCount = wrapper.GetPendingCommandCount();
if (cmdCount > 0)
{
    var commands = wrapper.DrainPendingCommands(cmdCount);
    foreach (var cmd in commands)
    {
        var scan = BuildScanFromCommand(cmd);
        scans.Add(scan);  // OutputMS will route priority vs normal
    }
}
```

The existing MS1→MS2 path and `_` prefix MS2→MS3 path are **untouched**. The command drain (Block 3) catches anything C++ wants to schedule during any processing call.

**Files:** `IDAScanProcessor.cs`

---

## Issue 8 — Method XML Configuration

### Desired behaviour
Same as v2: method XML controls whether optimization is enabled and sets the parameter grid bounds. Config is passed to C++ via constructor arg string.

### Limitations of current design
Same as v2: no config section exists.

### Proposed change
Same as v2:

```xml
<ParameterOptimization Active="false">
  <CollisionEnergy Min="20" Max="40" Step="5" />
  <IsolationWidth Values="1.0,2.0,4.0" />
  <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
  <MaxQueueForExploration>10</MaxQueueForExploration>
</ParameterOptimization>
```

New: `MaxQueueForExploration` — C++ won't start new exploration groups if queue exceeds this. Gives C++ queue-aware throttling.

**Files:** `MethodConfig.cs`, `Parameter.cs`, `method.xml`

---

## Issue 9 — Acquisition Metadata on PeakGroup (Optional, Deferred)

Same as v2 Issue 6. Optional fields for recording optimization results.

**Files:** `PeakGroup.h`

---

## Dependency Graph

```
Issue 8 (method config)    ── no deps, can land first
Issue 5 (scoring)          ── no deps
Issue 1 (queue state)      ── no deps
Issue 2 (command channel)  ── no deps
Issue 3 (priority queue)   ── no deps
Issue 4 (C++ engine)       ── depends on Issues 1, 2, 5, 8
Issue 6 (P/Invoke)         ── depends on Issues 1, 2, 4
Issue 7 (C# routing)       ── depends on Issues 3, 6
Issue 9 (metadata)         ── no deps, optional/deferred
```

Issues 1, 2, 3, 5, 8 can all be developed in parallel (no interdependencies).
Issue 4 integrates them on the C++ side.
Issues 6, 7 wire up the C# side.

---

## Design Invariants

1. **If `ParameterOptimization` is absent or `Active=false`**: `SetQueueState` still runs (harmless — writes three ints), command channel is always empty, priority queue is always empty. Code path is functionally identical to today.
2. **Existing bridge functions are never modified**: all signatures and behaviour unchanged.
3. **Existing scan routing is never modified**: `_` prefix handling, MS3, conditional MS2, tag-based targeting — all untouched.
4. **No callbacks, no delegates, no GCHandle**: all communication is polling-based via the same flat-array P/Invoke pattern used by all existing bridge functions.
5. **C# never decides** what parameter variants to try, when exploration is complete, or which variant won. It reports state, relays spectra, and drains commands.
6. **C++ is queue-aware**: it can throttle exploration based on instrument load, avoiding queue overflow.

---

## Architectural Diagram

```
                    ┌─────────────────────────────────────┐
                    │          C# (Thin Executor)          │
                    │                                       │
  Instrument ──►    │  ProcessMS()                          │
  (scan arrives)    │    1. SetQueueState(len, ms1, ms2) ──────► C++ stores state
                    │    2. Send spectrum to C++ ──────────────► C++ processes
                    │    3. Route ~prefix → FeedExploration ──► C++ accumulates
                    │    4. DrainPendingCommands() ◄────────── C++ returns commands
                    │    5. Build scans from commands          │
                    │    6. Return scans to pipeline           │
                    │                                       │
                    │  OutputMS()                            │
                    │    priority=1 → priorityScans queue    │
                    │    priority=0 → customScans queue      │
                    │                                       │
                    │  getNextScan()                         │
  Instrument ◄──    │    priorityScans first, then custom    │
  (wants next scan) │    fallback: default MS1 + AGC         │
                    └─────────────────────────────────────┘
                                    │ ▲
                         SetQueueState │ │ GetPendingCommands
                      FeedExploration │ │ GetPendingCommandCount
                        GetPeakGroups │ │
                    GetIsolationWindows│ │
                                    ▼ │
                    ┌─────────────────────────────────────┐
                    │          C++ (Decision Maker)         │
                    │                                       │
                    │  queue_length_, ms1_pending_, ms2_   │
                    │                                       │
                    │  getPeakGroups() ── existing          │
                    │  getIsolationWindows() ── existing    │
                    │                                       │
                    │  if optimization_enabled:             │
                    │    create ExplorationGroup            │
                    │    push variant commands ──► pending_ │
                    │                                       │
                    │  feedExplorationResult()              │
                    │    deconvolve, score, track           │
                    │    if complete:                       │
                    │      push PRIORITY final cmd ──► pending_│
                    │                                       │
                    │  pending_commands_ ──► drained by C#  │
                    └─────────────────────────────────────┘
```

## What Each Existing Mode Gets

| Mode | Impact |
|------|--------|
| Normal IDA | `SetQueueState` runs (harmless). Command channel empty. Priority queue empty. No behavioural change. |
| Deep mode | Same — targeting is orthogonal to command channel. |
| Inclusion/Exclusion | Same — precursor selection unchanged. |
| FAIMS CV cycling | `FAIMSScanProcessor` untouched. FAIMS queue cap (7) is orthogonal to priority queue. |
| Isobaric quantification | `QuantScanProcessor` untouched entirely. |
| Conditional MS2 | `_` prefix path untouched. |
| MS3 characterization | `DeconvolveMS2` + related functions untouched. |
| Tag-based targeting | `ProcessMS2ForTagBasedTargeting` untouched. |
| Test mode (-t) | `FLASHIdaWrapper.Main()` unchanged. |

## Files Changed vs. Unchanged

| File | Changed? | What |
|------|----------|------|
| `IScanProcessor.cs` | **No** | |
| `DataPipe.cs` | **No** | |
| `Flash.cs` | **No** | |
| `FAIMSScanProcessor.cs` | **No** | |
| `QuantScanProcessor.cs` | **No** | |
| `ScanScheduler.cs` | **Yes** | Add `priorityScans` queue + drain-first in `getNextScan()` |
| `ScanFactory.cs` | **No** | Already supports all parameters via ScanParameters struct |
| `IDAScanProcessor.cs` | **Yes** | Add queue state reporting, `~` prefix routing, command drain |
| `FLASHIdaWrapper.cs` | **Yes** | Add 4 new P/Invoke declarations + wrappers |
| `FLASHIdaBridgeFunctions.h/.cpp` | **Yes** | Add 4 new exports |
| `FLASHIda.h/.cpp` | **Yes** | Add queue state, command queue, exploration engine |
| `PeakGroupScoring.h/.cpp` | **Yes** | Add fragmentation quality scoring |
| `MethodConfig.cs` / `Parameter.cs` | **Yes** | Parse `<ParameterOptimization>` section |
| `method.xml` | **Yes** | Add template section |
| `PeakGroup.h` | **Optional** | Metadata fields |

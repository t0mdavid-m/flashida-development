# Parameter Optimization Plan — v4 (Bidirectional, Unified Bridge)

**Date:** 2026-03-20
**Revision:** 4
**Design principle:** C++ is the decision-maker. C# is a thin executor. All MS2 routing, exploration tracking, and scan scheduling decisions live in C++. Communication is bidirectional via a polling-based command channel. Existing bridge functions are modified where beneficial.

---

## Pushback on Feedback

### Feedback 1: "Shouldn't SetQueueState be called GetQueueState?"

**No — `SetQueueState` is the correct name.** The codebase convention names bridge functions from the C# caller's perspective:
- `Get*` = C# retrieves data FROM C++ (`GetPeakGroupSize`, `GetIsolationWindows`, `GetBestMS2Masses`)
- `Set*`/`Process*`/`Clear*` = C# pushes data TO C++ or triggers an action

C# is *sending* queue state *to* C++, so `Set` is correct. That said, per feedback 0 we fold queue state directly into `GetPeakGroupSize`, so this separate function is eliminated entirely (see Issue 1).

---

## Issue 1 — Modified Bridge Functions (Queue-Aware, Unified MS2)

### Desired behaviour
C++ receives instrument queue state with every spectrum and handles all MS2 routing internally. C# makes fewer, broader bridge calls instead of orchestrating multiple specialized calls per scan type.

### Limitations of current design
- Bridge functions receive only spectrum data; no queue visibility.
- MS2 processing requires C# to orchestrate: `DeconvolveMS2` → check mode → `ProcessMS2ForTagBasedTargeting` → check result → `GetBestMS2Masses` / `GetTopFragmentMatches`. This scatters domain logic across C#.
- Scan description tags (`_<id>|<mass>@<charge>`) are set by C# and parsed by C#; C++ never sees them.

### Proposed change

**Modify `GetPeakGroupSize`** — add queue state:
```cpp
// BEFORE
int GetPeakGroupSize(FLASHIda* obj, double* mzs, double* ints, int length,
                     double rt_min, int ms_level, char* name, char* cv);

// AFTER
int GetPeakGroupSize(FLASHIda* obj, double* mzs, double* ints, int length,
                     double rt_min, int ms_level, char* name, char* cv,
                     int queue_length, int ms1_pending, int ms2_pending);
```
C++ stores queue state internally. Existing callers pass `0, 0, 0` (no behavioural change). Eliminates the need for a separate `SetQueueState` function.

**New unified `ProcessMS2`** — replaces `DeconvolveMS2` + `ProcessMS2ForTagBasedTargeting` as separate calls:
```cpp
extern "C" OPENMS_DLLAPI int ProcessMS2(
    FLASHIda* obj,
    double* mzs, double* ints, int length,
    double rt_min,
    double precursor_mass, int precursor_charge,
    const char* scan_description,    // carries tracking ID, mode, mass@charge
    int queue_length, int ms1_pending, int ms2_pending);
```

C++ internally:
1. Parses `scan_description` to determine mode (standard `_`, exploration `~`, etc.)
2. Deconvolves the MS2 spectrum
3. Routes based on parsed mode:
   - Standard: stores in `ms2_deconvolved_spectrum_` (existing behaviour)
   - Tag-based: runs `processMS2ForTagBasedTargeting` automatically
   - Exploration: feeds into exploration group, scores, tracks completion
4. If exploration or any other logic produces new scan commands: pushes them to `pending_commands_`

Return value: number of peak groups (same as `DeconvolveMS2` today). Additional results (tags found, MS3 targets, exploration status) available via the command channel (Issue 2) and existing getter functions (`GetBestMS2Masses`, `GetTopFragmentMatches`, etc.).

**Existing functions `DeconvolveMS2`, `ProcessMS2ForTagBasedTargeting` are kept** as thin wrappers calling the unified implementation with default parameters. This allows phased migration — callers can switch one at a time.

**C# impact on IDAScanProcessor:** The current ~200 lines of MS2 routing (check pending mode → deconvolve → check tags → schedule follow-ups) reduces to:
```csharp
int peakCount = wrapper.ProcessMS2(msScan, scanDesc, mass, charge, queueLen, ms1, ms2);
// Everything else comes via command channel (Issue 2)
```

**Files:** `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`, `IDAScanProcessor.cs`

---

## Issue 2 — Command Channel with Atomic Drain (C++ Schedules Scans)

### Desired behaviour
C++ produces scan commands at any point during processing. C# drains all pending commands in a single atomic call after each bridge invocation and queues them. Commands describe full MSn scans including multi-stage isolation.

### Limitations of current design
Communication is strictly C#→C++. C++ returns data that C# interprets and converts into scans. C++ cannot directly say "queue this scan."

### Proposed change

**ScanCommand struct** with nested isolation stages for MSn support:

```cpp
struct IsolationStage
{
    double precursor_mz;
    double isolation_width;
    int collision_energy;
    int charge;
    char activation_type[16];   // "HCD", "ETD", "UVPD", etc.
    double first_mass;
    double last_mass;
    double reaction_time;       // ETD-specific
    double reagent_max_it;      // ETD-specific
    int reagent_agc_target;     // ETD-specific
};

struct ScanCommand
{
    int msn_level;              // 1=MS1, 2=MS2, 3=MS3
    int num_isolation_stages;   // 1 for MS2, 2 for MS3
    IsolationStage stages[4];   // max 4 nested stages

    // Global scan settings
    double max_it;
    int agc_target;
    int orbitrap_resolution;
    char analyzer[32];
    double faims_cv;
    char scan_description[256];
    int priority;               // 0=normal, 1=high (C++-initiated final scans)
};
```

**Atomic drain bridge function** (solves feedback 3 — memory overflow):
```cpp
extern "C" OPENMS_DLLAPI int GetAndClearPendingCommands(
    FLASHIda* obj,
    int max_count,              // C# buffer size
    ScanCommand* commands);     // C# pre-allocated array
```

C++ implementation uses a mutex to atomically copy up to `max_count` commands and clear the internal queue. Returns actual count filled. No race condition between count and fill — single call does both.

**C# side:**
```csharp
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct IsolationStage { /* mirrors C++ */ }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct ScanCommand { /* mirrors C++ */ }

[DllImport(dllName)]
static private extern int GetAndClearPendingCommands(
    IntPtr ptr, int maxCount,
    [Out] ScanCommand[] commands);
```

Drained at the end of every `ProcessMS()` call (Issue 7).

**Files:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 3 — ScanScheduler: Priority Queue, Timeout, and AGC/FAIMS Safety

### Desired behaviour
- C++-initiated scans are dequeued before regular scans.
- Scans that have been in the queue longer than a configurable timeout are discarded.
- AGC scans still fire at the correct frequency regardless of queue depth.
- FAIMS CV cycling is not blocked by a non-empty queue.

### Limitations of current design
- Single `ConcurrentQueue`, FIFO only, no priority or timeout.
- AGC scans only fire when queue is empty (`getNextScan` line 246-254). A priority queue that keeps the queue non-empty would starve AGC.
- FAIMS CV cycling triggers only when queue empties (`getFAIMSMS1Scan` called from line 258). A non-empty queue blocks CV transitions indefinitely.
- `ConcurrentQueue` cannot remove from the middle (needed for timeout).

### Proposed change

**Replace `ConcurrentQueue` with `LinkedList<T>` + `lock(sync)`:**
The `sync` lock already exists in ScanScheduler (line 24) and is used by `AddScan` and `getFAIMSMS1Scan`. Extend it to cover all queue operations.

**Two linked lists:** `priorityScans` and `standardScans`.

**Revised `getNextScan()` flow:**
```
1. ALWAYS check AGC duty first
   → if AGC scan is due (count-based), return agcScan directly

2. Check MS1 cycle time (Issue 4)
   → if elapsed > cycleTimeSeconds, inject MS1 at front

3. Lazy timeout cleanup
   → walk both lists, remove scans where (now - enqueueTime) > timeoutSeconds
   → log each removal

4. Dequeue with priority
   → if priorityScans is non-empty: remove first, return it
   → if standardScans is non-empty: remove first, return it

5. Queue empty fallback
   → if !useFAIMS: enqueue defaultScan, return agcScan
   → if useFAIMS: call getFAIMSMS1Scan()

6. FAIMS CV cycling guard (NEW)
   → track scansSinceLastCVChange
   → if scansSinceLastCVChange > CV_CYCLE_MAX (e.g., 10), force CV change
     even if queue is non-empty
```

**Timestamp on scans:** `scan.Values["EnqueueTimestamp"] = DateTime.UtcNow.Ticks.ToString()` — set in `AddScan()` and `AddPriorityScan()`.

**FAIMS queue cap interaction:** Priority scans respect the FAIMS cap (7 items total across both lists). If combined count exceeds cap and `force=false`, reject the scan.

**Files:** `ScanScheduler.cs`

---

## Issue 4 — MS1 Cycle Time Guarantee

### Desired behaviour
After a configurable time interval, an MS1 scan must occur regardless of queue state. This ensures C++ always has fresh MS1 deconvolution data. The feature is enabled/disabled via method.xml.

### Limitations of current design
MS1 scans only fire when the queue empties. If the queue stays populated (e.g., many exploration variants), MS1 data becomes stale. There is no time-based trigger.

### Proposed change

**C# concern only** — ScanScheduler tracks `lastMS1Time`:

```csharp
private DateTime lastMS1Time = DateTime.Now;
private bool cycleTimeEnabled = false;
private double cycleTimeSeconds = 60.0;
```

In `getNextScan()`, after AGC check (step 2 in Issue 3):
```csharp
if (cycleTimeEnabled && (DateTime.Now - lastMS1Time).TotalSeconds > cycleTimeSeconds)
{
    log.Info($"Cycle time exceeded ({cycleTimeSeconds}s) — forcing MS1");
    lastMS1Time = DateTime.Now;
    if (!useFAIMS)
    {
        standardScans.AddLast(defaultScan);
        MS1Count++;
        return agcScan;
    }
    else
    {
        return getFAIMSMS1Scan();
    }
}
```

Update `lastMS1Time` whenever an MS1 scan is dequeued.

**Why not C++?** C++ doesn't track real-time acquisition timing. Timing is an instrument control concern that belongs in C#.

**Method XML** (in `<MSSettings>`):
```xml
<CycleTime>
  <Enabled>False</Enabled>
  <CycleTimeSeconds>60</CycleTimeSeconds>
</CycleTime>
```

**Files:** `ScanScheduler.cs`, `MethodConfig.cs`, `Parameter.cs`, `MethodParameters.cs`, `method.xml`

---

## Issue 5 — C++ Exploration Engine

### Desired behaviour
When C++ processes an MS1 spectrum and identifies a precursor for optimization, it pushes exploration scan commands into the command queue (Issue 2). When exploration MS2 results arrive (via the unified `ProcessMS2` from Issue 1), C++ deconvolves, scores, and tracks them internally. When all variants are collected, C++ pushes the final optimized scan as a priority command. C# never manages exploration groups.

### Limitations of current design
No session concept, no multi-scan accumulation, no comparative scoring.

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

**Recognition happens in C++ via scan description tags** (feedback 7):
- C++ sets `scan_description` = `~<groupId>|<variantIndex>|<mass>@<charge>` when pushing exploration commands
- When `ProcessMS2` receives a scan with `~` prefix, C++ parses it and routes to `feedExplorationResult_()` internally
- C# never checks for `~` — it just passes the description through

**Queue-aware throttling:** During `getIsolationWindows`, if `queue_length_ > max_queue_for_exploration_`, skip creating new exploration groups.

**Completion:** When last variant arrives, C++ picks the winner and pushes a priority `ScanCommand` with the optimal parameters.

**Files:** `FLASHIda.h/.cpp`

---

## Issue 6 — Fragmentation Quality Scoring

### Desired behaviour
C++ can score an MS2 spectrum's fragmentation quality to rank exploration variants. The scoring function has access to the raw spectrum, isolation windows, and fragmentation parameters.

### Limitations of current design
`PeakGroupScoring` scores MS1 peak groups only. No MS2 spectral quality metric exists.

### Proposed change

```cpp
static double scoreFragmentationQuality(
    const DeconvolvedSpectrum& deconv_ms2,
    double precursor_mass,
    int precursor_charge);
```

All needed data is accessible from `DeconvolvedSpectrum`:
- **Raw spectrum:** `deconv_ms2.getOriginalSpectrum()` — all original m/z + intensity peaks
- **Isolation window:** via `getOriginalSpectrum().getPrecursors()[0].getIsolationWindowLowerOffset()` / `Upper()`
- **Activation method:** `deconv_ms2.getActivationMethod()` or `getPrecursors()[0].getActivationMethods()`
- **Collision energy:** `getPrecursors()[0].getActivationEnergy()`

No additional parameters needed — `DeconvolvedSpectrum` already stores everything. The convenience signature keeps the interface clean; if callers have extra context (e.g., a specific precursor from the raw scan), they can set it on the spectrum's precursor before calling.

The score combines:
1. Weighted fragment count (peak groups above qScore threshold, weighted by individual qScores)
2. Intensity coverage (fraction of TIC explained by deconvolved peaks)
3. Mass spread (observed vs theoretical mass range coverage)

Returns `double` in [0, 1].

**Files:** `PeakGroupScoring.h/.cpp` (or new `FLASHFragmentationQuality.h/.cpp`)

---

## Issue 7 — Thin C# Routing in IDAScanProcessor

### Desired behaviour
`ProcessMS()` becomes a thin relay: report queue state, send spectrum to C++, drain commands. All scan creation decisions come from C++ via the command channel.

### Limitations of current design
`ProcessMS()` is ~770 lines with interleaved mode-specific routing for MS1 targets, conditional MS2, MS3 modes, tagging, and exploration. Adding optimization on top would further bloat it.

### Proposed change

**MS1 processing** — existing flow remains (GetPeakGroupSize + GetIsolationWindows), but with queue state:
```csharp
int targets = wrapper.GetPeakGroupSize(msScan, queueLen, ms1Count, ms2Count);
// ... existing GetIsolationWindows + scan creation ...
// THEN drain commands (C++ may have added exploration scans):
DrainAndQueueCommands(scans);
```

**MS2 processing** — unified submission:
```csharp
msScan.Trailer.TryGetValue("Scan Description", out var scanDesc);
int peakCount = wrapper.ProcessMS2(msScan, scanDesc, precursorMass, charge,
                                    queueLen, ms1Count, ms2Count);
// C++ has already routed internally (exploration, tagging, MS3 prep, etc.)
// Results come via command channel + existing getter functions
DrainAndQueueCommands(scans);
```

**Command drain** — at the end of every ProcessMS call:
```csharp
private void DrainAndQueueCommands(List<IFusionCustomScan> scans)
{
    int count = wrapper.GetAndClearPendingCommands(commandBuffer, MAX_COMMANDS);
    for (int i = 0; i < count; i++)
    {
        var scan = BuildScanFromCommand(commandBuffer[i]);
        scans.Add(scan);
    }
}
```

`OutputMS()` routes scans by priority:
```csharp
public void OutputMS(IFusionCustomScan scan)
{
    if (scan == null)
        scanScheduler.AddDefault();
    else if (scan.Values.ContainsKey("Priority") && scan.Values["Priority"] == "1")
        scanScheduler.AddPriorityScan(scan);
    else
        scanScheduler.AddScan(scan, 2);
}
```

**Migration path:** Existing MS2 routing (conditional MS2 → check tags → schedule follow-ups) continues to work via the unified `ProcessMS2` + command channel. The C++ side internally replicates the current C# routing logic. Each mode can be migrated incrementally.

**Files:** `IDAScanProcessor.cs`

---

## Issue 8 — P/Invoke Declarations

### Desired behaviour
C# can call all new and modified bridge functions.

### Proposed change

```csharp
// Modified
[DllImport(dllName)]
static private extern int GetPeakGroupSize(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel,
    string name, string cv,
    int queueLength, int ms1Pending, int ms2Pending);

// New — unified MS2 processing
[DllImport(dllName)]
static private extern int ProcessMS2(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt,
    double precursorMass, int precursorCharge,
    string scanDescription,
    int queueLength, int ms1Pending, int ms2Pending);

// New — atomic command drain
[DllImport(dllName)]
static private extern int GetAndClearPendingCommands(IntPtr ptr,
    int maxCount, [Out] ScanCommand[] commands);
```

Plus `[StructLayout]` definitions for `IsolationStage` and `ScanCommand` matching the C++ layout.

Existing `DeconvolveMS2` and `ProcessMS2ForTagBasedTargeting` declarations are kept as-is for backwards compatibility during phased migration.

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 9 — Expanded Nested Method XML Configuration

### Desired behaviour
Parameter optimization is configured via a rich, nested XML structure following existing patterns (Active flags, per-feature enable/disable, array elements for multi-valued parameters). Each optimizable parameter type (CE, isolation width, reaction time, activation type) has its own sub-section.

### Limitations of current design
No configuration section exists for parameter optimization. The v3 flat structure (`<CollisionEnergy Min="20" Max="40" Step="5" />`) is too shallow for the complexity needed.

### Proposed change

Following existing patterns in `method.xml` (e.g., `AcquisitionModes` → `MS3Characterization` → `Active` + params; `MSSettings` → `FAIMS` → `CVValues` array):

```xml
<ParameterOptimization>
  <Active>False</Active>
  <OptimizationStrategy>Exhaustive</OptimizationStrategy>

  <ScanLimits>
    <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
    <MaxQueueForExploration>10</MaxQueueForExploration>
  </ScanLimits>

  <CollisionEnergyOptimization>
    <Enabled>true</Enabled>
    <MS2>
      <Min>20</Min>
      <Max>40</Max>
      <Step>5</Step>
      <Activation>HCD</Activation>
    </MS2>
    <MS3>
      <Min>15</Min>
      <Max>35</Max>
      <Step>5</Step>
      <Activation>CID</Activation>
    </MS3>
  </CollisionEnergyOptimization>

  <IsolationWidthOptimization>
    <Enabled>true</Enabled>
    <Values>
      <double>1.0</double>
      <double>2.0</double>
      <double>4.0</double>
    </Values>
  </IsolationWidthOptimization>

  <ReactionTimeOptimization>
    <Enabled>false</Enabled>
    <ETD>
      <Min>1</Min>
      <Max>10</Max>
      <Step>1</Step>
    </ETD>
  </ReactionTimeOptimization>

  <ActivationTypeOptimization>
    <Enabled>false</Enabled>
    <ActivationTypes>
      <string>HCD</string>
      <string>ETD</string>
      <string>UVPD</string>
    </ActivationTypes>
  </ActivationTypeOptimization>

  <Scoring>
    <MetricType>FragmentationQuality</MetricType>
  </Scoring>
</ParameterOptimization>
```

**C# classes** (in `MethodConfig.cs`):

```csharp
public class RangeConfig
{
    public int Min;
    public int Max;
    public int Step;
    public string Activation;
}

public class CollisionEnergyOptConfig
{
    public string Enabled = "False";
    public RangeConfig MS2;
    public RangeConfig MS3;
}

public class IsolationWidthOptConfig
{
    public string Enabled = "False";
    [XmlArray("Values")] public double[] Values;
}

public class ReactionTimeOptConfig
{
    public string Enabled = "False";
    public RangeConfig ETD;
}

public class ActivationTypeOptConfig
{
    public string Enabled = "False";
    [XmlArray("ActivationTypes")] public List<string> ActivationTypes;
}

public class ScanLimitsConfig
{
    public int MaxVariantsPerPrecursor = 5;
    public int MaxQueueForExploration = 10;
}

public class ScoringConfig
{
    public string MetricType = "FragmentationQuality";
}

public class ParameterOptimizationConfig
{
    public string Active = "False";
    public string OptimizationStrategy = "Exhaustive";
    public ScanLimitsConfig ScanLimits;
    public CollisionEnergyOptConfig CollisionEnergyOptimization;
    public IsolationWidthOptConfig IsolationWidthOptimization;
    public ReactionTimeOptConfig ReactionTimeOptimization;
    public ActivationTypeOptConfig ActivationTypeOptimization;
    public ScoringConfig Scoring;
}
```

Placed in `AcquisitionModesConfig` alongside `MS3Characterization` and `LabelingBasedQuantification`. Parsed in `MethodParameters.InitializeIDA()`, serialized to the C++ constructor string so C++ owns the grid generation logic.

**Files:** `MethodConfig.cs`, `Parameter.cs`, `MethodParameters.cs`, `method.xml`

---

## Issue 10 — Acquisition Metadata on PeakGroup (Optional, Deferred)

Same as v3. Optional fields for recording optimization results.

**Files:** `PeakGroup.h`

---

## Dependency Graph

```
Issue 9  (method XML)       ── no deps, can land first
Issue 6  (scoring)          ── no deps
Issue 4  (cycle time)       ── depends on Issue 3 (scheduler changes)
Issue 3  (scheduler)        ── no deps (infrastructure)
Issue 5  (C++ engine)       ── depends on Issues 6, 9
Issue 1  (bridge functions) ── depends on Issue 5 (C++ must handle unified routing)
Issue 2  (command channel)  ── depends on Issue 5 (C++ produces commands)
Issue 8  (P/Invoke)         ── depends on Issues 1, 2
Issue 7  (C# routing)       ── depends on Issues 1, 2, 3, 8
Issue 10 (metadata)         ── no deps, optional
```

Parallel development tracks:
- **Track A (C++ engine):** Issues 6 → 5 → 1 → 2
- **Track B (C# scheduler):** Issues 3 → 4
- **Track C (configuration):** Issue 9 (independent)
- **Integration:** Issues 8 → 7 (wires everything together)

---

## Backwards Compatibility Summary

### Risk by Mode

| Mode | Risk | Key Concern |
|------|------|-------------|
| Normal IDA | Medium | Bridge signature changes (A); pass `0,0,0` for queue state when optimization disabled |
| Deep mode | Medium | Same as Normal IDA |
| Inclusion/Exclusion | Medium | Same as Normal IDA; C++ inclusion logic untouched |
| FAIMS CV cycling | **High** | Queue replacement (LinkedList+lock) directly affects CV cycling trigger; must guard against starvation |
| Isobaric quantification | Medium | Uses `IsDifferentiallyAbundant` not `DeconvolveMS2`; queue changes affect scheduling only |
| MS2 Tagging | Medium | `ProcessMS2ForTagBasedTargeting` absorbed into unified `ProcessMS2`; must preserve behaviour |
| Conditional MS2 | **High** | Most complex MS2 routing; two-step tag-check-then-schedule logic moves to C++ |
| MS3 Characterization | **High** | 4 sub-modes build two-stage isolation arrays; ScanCommand struct must handle this correctly |
| Tag-based targeting | Medium | Similar to MS2 Tagging; unified function handles it |
| Test mode (-t) | Low | Pass dummy queue state; unified function works with `scan_description = ""` |

### Migration Strategy

**Phase 1: Infrastructure (no behavioral change)**
- Replace ConcurrentQueue with LinkedList+lock (Issue 3)
- Add cycle time tracking (Issue 4)
- Add ParameterOptimization XML section (Issue 9, defaults to Active=false)

**Phase 2: C++ engine (internal only)**
- Implement exploration engine and scoring (Issues 5, 6)
- Add command queue with mutex (Issue 2, internal to FLASHIda)

**Phase 3: Bridge evolution (backwards-compatible overloads)**
- Add new `GetPeakGroupSize` overload with queue params (Issue 1)
- Add `ProcessMS2` bridge function (Issue 1)
- Keep old `DeconvolveMS2` + `ProcessMS2ForTagBasedTargeting` as wrappers
- Add `GetAndClearPendingCommands` (Issue 2)

**Phase 4: C# migration (mode by mode)**
- Update Normal IDA to use new bridge + command drain
- Update FAIMS mode (most complex — test extensively)
- Update Conditional MS2 and MS3 modes
- Test mode last (lowest risk)

**Phase 5: Cleanup**
- Remove old bridge function wrappers once all callers migrated
- Remove `pendingMS2s` dictionary and C# routing logic

---

## Design Invariants

1. **If `ParameterOptimization` is absent or `Active=false`:** Command channel is always empty. Priority queue is always empty. Unified `ProcessMS2` routes to standard deconvolution path. Behaviour is identical to today.
2. **No callbacks, no delegates:** All communication is polling-based via the same flat-array / blittable-struct P/Invoke pattern.
3. **Atomic command drain:** Single `GetAndClearPendingCommands` call with mutex — no race condition between count and fill.
4. **AGC never starved:** `getNextScan()` checks AGC duty first, before any dequeue.
5. **FAIMS CV cycling guaranteed:** Scan count guard forces CV change even if queue is non-empty.
6. **Old bridge functions remain:** `DeconvolveMS2`, `ProcessMS2ForTagBasedTargeting`, `GetBestMS2Masses`, etc. are preserved as wrappers during migration. No forced breakage.

---

## Architectural Diagram

```
                    ┌──────────────────────────────────────────┐
                    │           C# (Thin Executor)              │
                    │                                            │
  Instrument ──►    │  ProcessMS()                               │
  (scan arrives)    │    MS1: GetPeakGroupSize(+queue state)     │
                    │         GetIsolationWindows                 │
                    │         DrainAndQueueCommands()             │
                    │                                            │
                    │    MS2: ProcessMS2(spec, scanDesc, queue)   │
                    │         DrainAndQueueCommands()             │
                    │                                            │
                    │  OutputMS()                                 │
                    │    priority=1 → priorityScans (LinkedList)  │
                    │    priority=0 → standardScans (LinkedList)  │
                    │    null       → AddDefault()                │
                    │                                            │
                    │  getNextScan()                              │
  Instrument ◄──    │    1. AGC check (always)                   │
  (wants next scan) │    2. MS1 cycle time check                 │
                    │    3. Lazy timeout cleanup                  │
                    │    4. Priority queue first                  │
                    │    5. Standard queue second                 │
                    │    6. Empty → default MS1 / FAIMS CV cycle │
                    └──────────────────────────────────────────┘
                                    │ ▲
                    GetPeakGroupSize │ │ (returns count)
                   GetIsolationWindows │ │ (fills arrays)
                         ProcessMS2 │ │ (returns peak count)
              GetAndClearPendingCommands │ │ (fills ScanCommand[])
                                    ▼ │
                    ┌──────────────────────────────────────────┐
                    │           C++ (Decision Maker)            │
                    │                                            │
                    │  queue_length_, ms1_pending_, ms2_pending_ │
                    │                                            │
                    │  getPeakGroups() ── deconvolve MS1         │
                    │  getIsolationWindows() ── precursor targets│
                    │    if optimization_enabled && queue OK:    │
                    │      create ExplorationGroup               │
                    │      push exploration commands → pending_  │
                    │                                            │
                    │  processMS2() ── unified entry point       │
                    │    parse scan_description tag               │
                    │    route:                                   │
                    │      standard → deconvolve, store           │
                    │      tagging  → deconvolve + tag match     │
                    │      exploration → deconvolve, score, track│
                    │        if complete: push PRIORITY cmd      │
                    │      MS3 prep → deconvolve, store          │
                    │                                            │
                    │  pending_commands_ ── drained by C#        │
                    │  std::mutex commands_mutex_                 │
                    └──────────────────────────────────────────┘
```

## Files Changed vs. Unchanged

| File | Changed? | What |
|------|----------|------|
| `IScanProcessor.cs` | **No** | |
| `DataPipe.cs` | **No** | |
| `Flash.cs` | **No** | |
| `FAIMSScanProcessor.cs` | **Yes** | Update `GetIsolationWindows` call to pass queue state |
| `QuantScanProcessor.cs` | **Yes** | Update `GetIsolationWindows` call to pass queue state |
| `ScanScheduler.cs` | **Yes** | LinkedList+lock, priority queue, timeout, cycle time |
| `ScanFactory.cs` | **No** | Already supports all parameters via ScanParameters struct |
| `IDAScanProcessor.cs` | **Yes** | Unified ProcessMS2, command drain, simplified routing |
| `FLASHIdaWrapper.cs` | **Yes** | Modified GetPeakGroupSize, new ProcessMS2, new GetAndClearPendingCommands, struct defs |
| `FLASHIdaBridgeFunctions.h/.cpp` | **Yes** | Modified GetPeakGroupSize, new ProcessMS2, new GetAndClearPendingCommands |
| `FLASHIda.h/.cpp` | **Yes** | Queue state, command queue+mutex, exploration engine, unified processMS2 |
| `PeakGroupScoring.h/.cpp` | **Yes** | Fragmentation quality scoring |
| `MethodConfig.cs` | **Yes** | New nested ParameterOptimization classes, CycleTime class |
| `Parameter.cs` | **Yes** | New IDAParameters fields |
| `MethodParameters.cs` | **Yes** | Parse new XML sections |
| `method.xml` | **Yes** | Add ParameterOptimization + CycleTime sections |
| `PeakGroup.h` | **Optional** | Metadata fields |

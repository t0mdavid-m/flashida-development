# Parameter Optimization Plan — v5 (Unified Bridge, C++ Brain)

**Date:** 2026-03-20
**Revision:** 5
**Design principle:** One unified bridge entry point (`ProcessScan`). C++ makes all decisions. C# is a thin relay that extracts spectrum data, calls `ProcessScan`, drains scan commands, and builds Thermo API objects. AGC and MS1 scans bypass the queue entirely. FAIMS CV cycling lives in C++.

---

## Pushback on Feedback

### Feedback 3: "GetPeakGroupSize should be renamed to GetQueueSize"

**This rename is semantically incorrect.** `GetPeakGroupSize` returns the number of deconvolved and filtered peak groups from a spectrum — not the scan queue size. The queue is a C# concept that the C++ function knows nothing about. "GetQueueSize" would conflate deconvolution output with scheduling state.

However, the point is **moot**: feedback 1 requests a unified `ProcessScan` function that absorbs both `GetPeakGroupSize` (MS1) and `DeconvolveMS2` (MS2). Under this design, `GetPeakGroupSize` ceases to exist as a standalone function — it becomes an internal dispatch path within `ProcessScan`. No rename needed.

---

## Issue 1 — Unified ProcessScan Bridge Function

### Desired behaviour
A single C++ entry point handles all scan levels. C# calls `ProcessScan` with spectrum data, MS level, scan description, and queue state. C++ internally dispatches: MS1 triggers deconvolution + precursor selection; MS2 triggers deconvolution + mode routing (tagging, exploration, MS3 prep). Results flow back via the command channel (Issue 2) and existing query functions.

### Limitations of current design
Two separate entry points (`GetPeakGroupSize` for MS1, `DeconvolveMS2` for MS2) with different signatures. MS2 routing logic (conditional, tagging, MS3) scattered across C#. C++ never sees the scan description tag. Fragmentation metadata (CE, isolation window, activation type) is never passed to C++ (confirmed missing — see Issue 6).

### Proposed change

```cpp
extern "C" OPENMS_DLLAPI int ProcessScan(
    FLASHIda* obj,
    double* mzs, double* ints, int length,
    double rt_min,
    int ms_level,
    const char* name,                // spectrum name
    const char* cv,                  // FAIMS CV (empty if not FAIMS)
    const char* scan_description,    // carries tracking ID, mode tag, user content
    int queue_length,
    int ms1_pending,
    int ms2_pending,
    double precursor_mass,           // 0 for MS1
    int precursor_charge,            // 0 for MS1
    double isolation_window_lower,   // 0 for MS1
    double isolation_window_upper,   // 0 for MS1
    int collision_energy,            // 0 for MS1
    const char* activation_type);    // empty for MS1
```

C++ internally:
1. Stores queue state (`queue_length_`, `ms1_pending_`, `ms2_pending_`)
2. If `ms_level == 1`: calls `getPeakGroups()` → `filterPeakGroupsUsingMassExclusion_()` → populates isolation targets. If optimization enabled and queue has capacity, creates exploration groups and pushes variant commands.
3. If `ms_level == 2`: creates `MSSpectrum` with full `Precursor` annotation (MZ, charge, isolation window, CE, activation). Parses `scan_description` to determine mode. Routes to standard deconvolution, tag-based targeting, exploration accumulation, etc.
4. Pushes any resulting scan commands into `pending_commands_`.

**Return value:** number of peak groups (for MS1: precursor targets; for MS2: deconvolved fragments). `GetIsolationWindows` remains as a post-MS1 query to fill output arrays. Existing MS2 query functions (`GetBestMS2Masses`, `GetTopFragmentMatches`, etc.) remain as post-MS2 queries.

**Old functions kept as wrappers** during migration:
```cpp
int GetPeakGroupSize(...) { return ProcessScan(..., /*ms_level=*/1, ...); }
int DeconvolveMS2(...)    { return ProcessScan(..., /*ms_level=*/2, ...); }
```

### Scan description format

All FLASHIda-generated scans use a new description format with a unique alphanumeric ID and user-facing content:

```
FI-<alphaId> <userContent> [<machineTag>]
```

- `FI-` — fixed prefix identifying FLASHIda-generated scans.
- `<alphaId>` — base-36 encoded tracking counter (4 chars = 1.6M unique values per run). Example: `a1b2`.
- `<userContent>` — human-readable summary visible in Xcalibur/FreeStyle:
  - MS2: `MS2 14037.90Da 19+ HCD`
  - MS3: `MS3 b12 1234.56Da 3+`
  - Exploration: `MS2opt 14037.90Da 19+ CE25`
  - Quant: `Quant 14037.90Da`
- `[<machineTag>]` — parseable metadata: `[t=a1b2,m=14037.90,z=19,mode=std]`

C++ parses the `[machineTag]` to extract tracking ID and mode. The `mode` key determines routing:
- `std` — standard MS2 (deconvolve, store)
- `tag` — tag-based targeting (deconvolve, match, expand)
- `cond` — conditional MS2 (deconvolve, check tags, decide follow-ups)
- `opt` — exploration variant (deconvolve, score, accumulate)
- `ms3` — MS3 trigger (deconvolve, prepare fragment targets)

**Files:** `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`, `IDAScanProcessor.cs`

---

## Issue 2 — Command Channel with Atomic Drain

### Desired behaviour
C++ produces scan commands during any `ProcessScan` call. C# drains all pending commands in a single atomic call. Commands describe full MSn scans with up to 10 isolation stages (supporting MSn up to MS10 on Thermo tribrid instruments).

### Proposed change

**ScanCommand struct** with nested isolation stages:

```cpp
const int MAX_ISOLATION_STAGES = 10;

struct IsolationStage
{
    double precursor_mz;
    double isolation_width;
    int collision_energy;
    int charge;
    char activation_type[16];
    double first_mass;
    double last_mass;
    double reaction_time;
    double reagent_max_it;
    int reagent_agc_target;
};

struct ScanCommand
{
    int msn_level;                              // 1=MS1, 2=MS2, ..., 10=MS10
    int num_isolation_stages;                   // 1 for MS2, 2 for MS3, etc.
    IsolationStage stages[MAX_ISOLATION_STAGES];

    double max_it;
    int agc_target;
    int orbitrap_resolution;
    char analyzer[32];
    double faims_cv;
    char scan_description[256];
    int priority;                               // 0=normal, 1=high
};
```

**C++ must zero-initialize** all `ScanCommand` structs (`ScanCommand cmd = {};`). C# reads only `stages[0..num_isolation_stages-1]`.

**C# validation** when converting `ScanCommand` → `ScanParameters`:
- `num_isolation_stages >= 1 && <= 10`
- `msn_level == num_isolation_stages + 1`
- Build arrays of exactly `num_isolation_stages` length (unused stages ignored)

**Atomic drain bridge:**
```cpp
extern "C" OPENMS_DLLAPI int GetAndClearPendingCommands(
    FLASHIda* obj,
    int max_count,
    ScanCommand* commands);   // C# pre-allocated, blittable
```

Mutex-protected: copies up to `max_count` commands, clears internal queue, returns actual count. No race condition.

**Files:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 3 — ScanScheduler: Priority Queue, Timeout, AGC/MS1 Bypass, Cycle Time, FAIMS CV in C++

### Desired behaviour
- AGC scans and MS1 scans bypass the queue entirely when they are due — returned directly from `getNextScan()` before any dequeue.
- C++-initiated scans (priority=1) dequeue before regular scans.
- Stale scans are dropped based on configurable timeout.
- FAIMS CV selection logic lives in C++ (adaptive skip based on precursor counts).
- After a configurable cycle time, an MS1 scan is guaranteed regardless of queue depth.
- All of this is configurable and can be enabled/disabled via method.xml.

### Proposed change

**Replace `ConcurrentQueue` with `LinkedList<IFusionCustomScan>` + `lock(sync)`.**

**Two linked lists:** `priorityScans` and `standardScans`. FAIMS queue cap (7) applies to combined count.

**FAIMS CV cycling moves to C++:**
```cpp
extern "C" OPENMS_DLLAPI double GetNextCV(
    FLASHIda* obj,
    double current_cv,
    int precursor_count);
```
C++ maintains adaptive skip state (skip amounts, skip counts per CV). Returns the next CV to use. C# retains pre-built scan object tables (`faimsDefaultScans[]`, `faimsAgcScans[]`) indexed by CV.

**Revised `getNextScan()` flow:**
```
lock(sync):
  1. AGC duty check → if due, return agcScan directly (bypasses queue)
  2. MS1 cycle time check → if (now - lastMS1Time) > cycleTimeSeconds:
       if FAIMS: call wrapper.GetNextCV() → return faimsAgcScans[cv]
       else: enqueue defaultScan, return agcScan
  3. Lazy timeout cleanup → walk both lists, remove expired scans
  4. Priority dequeue → if priorityScans non-empty, remove first
  5. Standard dequeue → if standardScans non-empty, remove first
  6. Empty fallback →
       if FAIMS: call wrapper.GetNextCV() → enqueue MS1, return AGC
       else: enqueue defaultScan, return agcScan
  7. FAIMS CV cycling guard → if scansSinceLastCVChange > threshold, force CV change
```

**Timestamp on scans:** `scan.Values["EnqueueTimestamp"] = DateTime.UtcNow.Ticks.ToString()` set in `AddScan()`.

**Method XML** (in `<MSSettings>`):
```xml
<CycleTime>
  <Enabled>False</Enabled>
  <CycleTimeSeconds>60</CycleTimeSeconds>
</CycleTime>

<ScanTimeout>
  <Enabled>False</Enabled>
  <TimeoutSeconds>30</TimeoutSeconds>
</ScanTimeout>
```

**Files:** `ScanScheduler.cs`, `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`, `MethodConfig.cs`, `Parameter.cs`, `MethodParameters.cs`, `method.xml`

---

## Issue 4 — C++ Exploration Engine

### Desired behaviour
When C++ identifies a precursor for optimization during MS1 processing, it creates an exploration group and pushes variant scan commands. When exploration MS2 results arrive (recognized via scan description `mode=opt`), C++ deconvolves, scores, tracks. When all variants are collected, C++ pushes the final optimized scan as a priority command.

### Proposed change

Internal state (private to `FLASHIda`):

```cpp
struct ExplorationVariant
{
    double collision_energy;
    double isolation_width;
    std::string activation_type;
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

**Recognition happens entirely in C++:** When `ProcessScan` receives an MS2 with `mode=opt` in the scan description, it parses the group ID and variant index, routes to `feedExplorationResult_()` internally. C# never inspects the mode.

**Queue-aware throttling:** C++ checks `queue_length_` before creating new exploration groups.

**Completion:** When last variant arrives, C++ picks the winner (highest `scoreFragmentationQuality`) and pushes a priority `ScanCommand`.

**Files:** `FLASHIda.h/.cpp`

---

## Issue 5 — Fragmentation Quality Scoring

### Desired behaviour
C++ scores MS2 spectral quality for exploration variant ranking. The scorer accesses the raw spectrum, isolation windows, CE, and activation type.

### Limitations identified (feedback 9 — confirmed correct)
The v4 plan claimed this data was already available on `DeconvolvedSpectrum`. **This was wrong.** Currently, `DeconvolveMS2` only sets `Precursor.MZ` and `Precursor.charge` on the MSSpectrum. Isolation window offsets, CE, and activation method are **never stored**. C# has this data (in `PendingMS2Info` and `MS2Parameters`) but never passes it through the bridge.

### Proposed change
**Fix in `ProcessScan`:** The unified bridge (Issue 1) now receives `isolation_window_lower`, `isolation_window_upper`, `collision_energy`, and `activation_type` as explicit parameters. Inside `FLASHIda::processScan()`, these are set on the `Precursor` object before deconvolution:

```cpp
Precursor precursor;
precursor.setMZ(precursor_mz);
precursor.setCharge(precursor_charge);
precursor.setIsolationWindowLowerOffset(isolation_window_lower);
precursor.setIsolationWindowUpperOffset(isolation_window_upper);
precursor.setActivationEnergy(collision_energy);
precursor.getActivationMethods().insert(parseActivation(activation_type));
spec.getPrecursors().push_back(precursor);
```

Now the scoring function can access everything via existing getters:

```cpp
static double scoreFragmentationQuality(
    const DeconvolvedSpectrum& deconv_ms2,
    double precursor_mass,
    int precursor_charge);
```

Internally accesses: `deconv_ms2.getOriginalSpectrum().getPrecursors()[0].getActivationEnergy()`, `.getIsolationWindowLowerOffset()`, `.getActivationMethods()`.

Combines: weighted fragment count, intensity coverage, mass spread. Returns `double` in [0, 1].

**Files:** `FLASHIda.cpp` (processScan annotation), `PeakGroupScoring.h/.cpp`

---

## Issue 6 — Unified C# ProcessMS (Thin Relay)

### Desired behaviour
`IDAScanProcessor.ProcessMS()` is a thin relay: extract spectrum data once, call `ProcessScan`, drain commands, build scans. All mode routing lives in C++. The method is ~50-80 lines instead of ~770.

### Proposed change

```csharp
public IEnumerable<IFusionCustomScan> ProcessMS(IMsScan msScan)
{
    var scans = new List<IFusionCustomScan>();

    // 1. Extract spectrum data once
    double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
    double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();
    double rt = double.Parse(msScan.Header["StartTime"]);
    int msLevel = int.Parse(msScan.Header["MSOrder"]);
    string analyzer = msScan.Header["MassAnalyzer"];
    msScan.Trailer.TryGetValue("Scan Description", out var scanDesc);

    if (analyzer != "FTMS") return scans;

    // 2. Gather queue state
    int qLen = scanScheduler.QueueLength;
    int ms1P = scanScheduler.MS1Count;
    int ms2P = scanScheduler.MS2Count;

    // 3. Extract precursor info (MS2+ only)
    double precMass = 0, isoLower = 0, isoUpper = 0;
    int precCharge = 0, ce = 0;
    string activation = "";
    if (msLevel >= 2 && scanDesc != null)
    {
        // Parse from pending info or scan header
        ExtractPrecursorInfo(msScan, scanDesc, out precMass, out precCharge,
                             out isoLower, out isoUpper, out ce, out activation);
    }

    // 4. Single bridge call
    int peakCount = wrapper.ProcessScan(mzs, ints, mzs.Length, rt, msLevel,
        msScan.Header["Scan"], cvString, scanDesc ?? "",
        qLen, ms1P, ms2P, precMass, precCharge,
        isoLower, isoUpper, ce, activation);

    // 5. For MS1: fill isolation windows (existing query)
    if (msLevel == 1 && peakCount > 0)
    {
        var targets = wrapper.GetIsolationWindows(peakCount);
        foreach (var target in targets)
            scans.Add(BuildMS2ScanFromTarget(target));
    }

    // 6. Drain all C++ commands (MS1 exploration variants, MS2 follow-ups, MS3 targets)
    DrainAndQueueCommands(scans);

    // 7. Null sentinel for default MS1 scheduling
    if (msLevel == 1) scans.Add(null);

    return scans;
}
```

`FAIMSScanProcessor` and `QuantScanProcessor` remain separate for now. `QuantScanProcessor` uses `IsDifferentiallyAbundant` which is orthogonal to the unified ProcessScan. `FAIMSScanProcessor` is absorbed into `IDAScanProcessor` once FAIMS CV cycling moves to C++ (Phase 4 of migration).

**Files:** `IDAScanProcessor.cs`

---

## Issue 7 — P/Invoke Declarations

```csharp
// Unified ProcessScan
[DllImport(dllName)]
static private extern int ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel,
    string name, string cv, string scanDescription,
    int queueLength, int ms1Pending, int ms2Pending,
    double precursorMass, int precursorCharge,
    double isoLower, double isoUpper, int collisionEnergy, string activationType);

// Atomic command drain
[DllImport(dllName)]
static private extern int GetAndClearPendingCommands(IntPtr ptr,
    int maxCount, [Out] ScanCommand[] commands);

// FAIMS CV cycling
[DllImport(dllName)]
static private extern double GetNextCV(IntPtr ptr,
    double currentCV, int precursorCount);
```

Plus `[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]` for `IsolationStage` and `ScanCommand`.

Old declarations kept during migration (marked `[Obsolete]`).

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 8 — Method XML Configuration (Expanded Nested Structure)

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
    <MS2><Min>20</Min><Max>40</Max><Step>5</Step><Activation>HCD</Activation></MS2>
    <MS3><Min>15</Min><Max>35</Max><Step>5</Step><Activation>CID</Activation></MS3>
  </CollisionEnergyOptimization>

  <IsolationWidthOptimization>
    <Enabled>true</Enabled>
    <Values><double>1.0</double><double>2.0</double><double>4.0</double></Values>
  </IsolationWidthOptimization>

  <ReactionTimeOptimization>
    <Enabled>false</Enabled>
    <ETD><Min>1</Min><Max>10</Max><Step>1</Step></ETD>
  </ReactionTimeOptimization>

  <ActivationTypeOptimization>
    <Enabled>false</Enabled>
    <ActivationTypes><string>HCD</string><string>ETD</string></ActivationTypes>
  </ActivationTypeOptimization>

  <Scoring>
    <MetricType>FragmentationQuality</MetricType>
  </Scoring>
</ParameterOptimization>
```

All configuration classes annotated with `[Description("...")]` attributes for auto-documentation:

```csharp
[Description("Controls real-time parameter optimization via exploration scans")]
public class ParameterOptimizationConfig
{
    [Description("Enable or disable parameter optimization (True/False)")]
    public string Active = "False";

    [Description("Strategy: Exhaustive (try all variants) or Adaptive (stop early)")]
    public string OptimizationStrategy = "Exhaustive";
    // ...
}
```

Auto-doc generator: reflection-based utility that walks config classes and produces Markdown documentation.

**Files:** `MethodConfig.cs`, `Parameter.cs`, `MethodParameters.cs`, `method.xml`

---

## Issue 9 — Acquisition Metadata on PeakGroup (Detailed)

### Metadata fields (24+ fields in 5 categories)

**A. Optimization Context:**
```cpp
int optimization_group_id_ = 0;          // 0 = not part of optimization
int variant_index_ = -1;                 // which variant in the group
int total_variants_tested_ = 0;          // how many variants total
bool is_best_variant_ = false;           // won the comparison
int rank_among_variants_ = 0;            // 1=best, 2=second, etc.
```

**B. Acquisition Parameters Used:**
```cpp
double collision_energy_used_ = 0.0;
double isolation_width_used_ = 0.0;
std::string activation_type_used_;        // "HCD", "ETD", etc.
double reaction_time_ms_ = 0.0;          // ETD-specific
double precursor_monoisotopic_mass_ = 0.0;
int precursor_charge_ = 0;
double precursor_mz_ = 0.0;
int precursor_scan_number_ = 0;
```

**C. Quality Scoring:**
```cpp
double fragmentation_quality_score_ = -1.0;  // [0,1], -1 = not scored
double variant_score_rank_ = -1.0;           // this score / best score
float variant_tic_explained_ratio_ = 0.0f;   // TIC coverage
int variant_fragment_count_ = 0;             // high-quality fragments
float variant_mass_range_coverage_ = 0.0f;   // mass spread
```

**D. Timing:**
```cpp
uint64_t optimization_start_ms_ = 0;     // epoch ms when group created
uint64_t optimization_complete_ms_ = 0;  // epoch ms when winner determined
int acquisition_duration_ms_ = 0;        // start → complete
```

**E. Cost Tracking:**
```cpp
int total_exploration_scans_ = 0;         // MS2 scans used for exploration
int exploration_overhead_factor_ = 1;     // total / expected (e.g., 5x)
```

All fields default to "not set" values. `bool hasOptimizationMetadata() const { return optimization_group_id_ > 0; }` gates downstream access.

**Serialization:** Optional CVParams in mzML output. Logging via IDALog. pyOpenMS exposure via `.pxd` bindings.

**Downstream queries enabled:** Compare CE effectiveness across a run, audit exploration cost per precursor mass range, train parameter prediction models.

**Files:** `PeakGroup.h/.cpp`, `DeconvolvedSpectrum.cpp` (toSpectrum serialization)

---

## Backwards Compatibility

| Mode | Risk | Key Concern |
|------|------|-------------|
| Normal IDA | Low | Bridge signature change; pass defaults for new params |
| Deep IDA | None | Configuration variant of Normal IDA |
| Inclusion | Low | C++ inclusion logic untouched |
| Exclusion | Low | C++ exclusion logic untouched |
| FAIMS CV cycling | **Medium** | CV state machine moves to C++; queue replacement |
| Isobaric quantification | Low | Uses `IsDifferentiallyAbundant`, orthogonal to ProcessScan |
| MS2 Tagging | Low | Absorbed into ProcessScan mode routing |
| Conditional MS2 | Low | Mode flag in scan description, C++ handles routing |
| MS3 (all modes) | Low | Fragment selection functions remain as post-ProcessScan queries |
| Tag-based targeting | Low | Side effect of ProcessScan tag mode |
| Test mode (-t) | Low | Pass empty/default params; old functions kept as wrappers |

---

## Phased Migration Plan

### Phase 1: C++ Foundation (No C# Changes)

**Goal:** Add PeakGroup metadata fields, fragmentation scoring stub, and ProcessScan stub to C++.

**Changes:**
- `PeakGroup.h/.cpp` — add 24+ metadata fields with getters/setters
- `PeakGroupScoring.h/.cpp` — add `scoreFragmentationQuality` (stub returning 0.0)
- `FLASHIdaBridgeFunctions.h/.cpp` — add `ProcessScan` export (internally calls existing `getPeakGroups`/`deconvolveMS2`)
- `FLASHIda.h/.cpp` — add `processScan()` dispatcher, command queue with mutex

**Unchanged:** All C# files. All existing bridge functions.

**Verify:** `Flash.exe -t` produces identical output. New C++ unit tests for PeakGroup metadata.

**Scope:** M

---

### Phase 2: C# Infrastructure (No C++ Build)

**Goal:** Rewrite ScanScheduler, add new scan description format, expand method XML.

**Changes:**
- `ScanScheduler.cs` — LinkedList+lock, priority queue, timeout, AGC/MS1 bypass, cycle time
- `IDAScanProcessor.cs` — new `BuildScanDescription` using `FI-<alphaId>` format; parse both old and new formats
- `MethodConfig.cs` / `Parameter.cs` / `MethodParameters.cs` — add `ParameterOptimization`, `CycleTime`, `ScanTimeout` config classes with `[Description]` attributes
- `method.xml` — add template sections (all disabled by default)

**Unchanged:** All C++ code. `FLASHIdaWrapper.cs`. `Flash.cs`. `DataPipe.cs`.

**Verify:** `Flash.exe -t` works. Old method XML loads. New method XML loads. ScanScheduler unit tests.

**Scope:** L

---

### Phase 3: Wire Unified Bridge End-to-End

**Goal:** Connect `ProcessScan` C++ bridge to C# `ProcessMS`. Annotate spectra with CE/isolation/activation.

**Changes:**
- `FLASHIdaBridgeFunctions.h/.cpp` — `ProcessScan` now receives full parameter set including CE, isolation window, activation type. Annotates Precursor on MSSpectrum.
- `FLASHIda.cpp` — `processScan()` sets Precursor metadata before deconvolution
- `FLASHIdaWrapper.cs` — add `ProcessScan` P/Invoke + `ScanCommand`/`IsolationStage` struct defs + `GetAndClearPendingCommands`
- `IDAScanProcessor.cs` — refactor MS1 path to use ProcessScan. MS2 path migrated mode-by-mode (standard first, then conditional, then MS3).
- Old bridge functions remain as `[Obsolete]` wrappers

**Unchanged:** `FAIMSScanProcessor.cs` (still on old bridge). `QuantScanProcessor.cs`. `ScanScheduler.cs` (Phase 2 already done).

**Verify:** `Flash.exe -t` with enriched output. IDALog diff: isolation windows and QScores identical; new metadata columns appear.

**Scope:** L

---

### Phase 4: FAIMS CV to C++ + Absorb FAIMSScanProcessor

**Goal:** Move FAIMS CV cycling to C++. Merge `FAIMSScanProcessor` into `IDAScanProcessor`.

**Changes:**
- `FLASHIda.h/.cpp` — add `getNextCV()` with adaptive skip state machine
- `FLASHIdaBridgeFunctions.h/.cpp` — add `GetNextCV` export
- `FLASHIdaWrapper.cs` — add `GetNextCV` P/Invoke
- `ScanScheduler.cs` — remove `updateCV`, `CVSkipAmount`, `CVSkipCount`. `getFAIMSMS1Scan` calls `wrapper.GetNextCV()`
- `IDAScanProcessor.cs` — add `useFAIMS` branch, absorb FAIMS-specific logic
- Delete `FAIMSScanProcessor.cs`
- `Flash.cs` — remove FAIMSScanProcessor instantiation; IDAScanProcessor handles both paths

**Verify:** On-instrument with multiple CVs: CV cycling matches pre-migration. IDALog comparison. All non-FAIMS modes unaffected.

**Scope:** M (highest-risk phase — test extensively)

---

### Phase 5: Exploration Engine + Fragmentation Scoring

**Goal:** The core scientific contribution: real-time parameter optimization.

**Changes:**
- `PeakGroupScoring.cpp` — implement real `scoreFragmentationQuality` algorithm
- `FLASHIda.h/.cpp` — exploration engine (ExplorationGroup, variant tracking, completion logic, priority command push)
- `IDAScanProcessor.cs` — optimization-enabled path: ProcessScan creates exploration variants, DrainCommands queues them, results flow back via ProcessScan mode=opt
- `MethodConfig.cs` — wire `ParameterOptimization` config to C++ constructor string

**Verify:** `Flash.exe -t` with optimization disabled: identical. With optimization enabled: log shows fragmentation scores, variant tracking, winner selection.

**Scope:** L (new feature, cross-repo)

---

### Phase 6: Cleanup + Final Command Channel

**Goal:** Remove deprecated bridge functions, finalize ScanCommand struct.

**Changes:**
- `FLASHIdaBridgeFunctions.h/.cpp` — remove old exports (`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, etc.)
- `FLASHIdaWrapper.cs` — remove `[Obsolete]` declarations
- `IDAScanProcessor.cs` — remove legacy code paths, `pendingMS2s` dictionary
- Update `CLAUDE.md` files

**Verify:** Full regression across all modes. `Flash.exe -t`. On-instrument tests.

**Scope:** M (mostly deletion)

---

### Phase Summary

| Phase | Name | C++ Build | C# Changes | Scope | Risk |
|-------|------|-----------|------------|-------|------|
| 1 | C++ Foundation | Yes | None | M | Low |
| 2 | C# Infrastructure | No | Major | L | Medium (scheduler) |
| 3 | Wire Unified Bridge | Yes | Major | L | Medium (cross-repo) |
| 4 | FAIMS to C++ | Yes | Moderate | M | **High** (FAIMS) |
| 5 | Exploration Engine | Yes | Major | L | Medium (new feature) |
| 6 | Cleanup | Yes | Moderate | M | Low (deletion) |

Phases 1 and 2 are fully independent — can be developed in parallel. C++ builds can be batched (1+3, 4+5) to reduce build overhead.

---

## Design Invariants

1. **If `ParameterOptimization` is absent or `Active=false`:** Command channel empty. Priority queue empty. ProcessScan dispatches to standard paths. Behavior identical to today.
2. **No callbacks, no delegates:** All communication is polling-based.
3. **Atomic command drain:** Single `GetAndClearPendingCommands` with mutex.
4. **AGC/MS1 never starved:** Bypass queue entirely when due.
5. **FAIMS CV guaranteed:** C++ adaptive skip + C# scan-count guard.
6. **Old bridge functions survive through Phase 5:** Phased migration, no forced breakage until Phase 6.
7. **Spectra annotated with fragmentation metadata:** CE, isolation window, activation type set on Precursor before deconvolution.

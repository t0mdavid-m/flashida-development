# Parameter Optimization Plan — v8

**Date:** 2026-03-20
**Revision:** 8

**Design principle:** Two bridge functions (`ProcessScan`, `GetAndClearPendingCommands`). C++ owns all decisions. C# is a stateless relay. Commands are picked up at the dequeue point (`getNextScan`), not during scan processing. Configuration via JSON. Metadata decoupled via `OptimizationMetadata`.

---

## Issue 1 — Unified ProcessScan Bridge

### Desired behaviour
A single C++ entry point handles all MSn levels. C# passes spectrum data + scan description. C++ resolves all context from its internal tracking state. Every tracking ID is logged on creation, resolution, and expiry.

### Limitations of current design
~20 specialized bridge functions. C# orchestrates multi-step call sequences. No audit trail.

### Proposed change

```cpp
extern "C" OPENMS_DLLAPI int ProcessScan(
    FLASHIda* obj,
    double* mzs,
    double* ints,
    int length,
    double rt_min,
    int ms_level,
    const char* scan_description);
```

Returns number of commands pushed to internal queue.

**Tracking ID system:** C++ owns atomic counter. 4-char base-36 encoding (1.6M unique/run). C# has `ToBase36` helper for MS1/AGC fallback. C++ has `toBase36`/`parseBase36`.

**Scan description:** `TTTT <human content>` — no prefix, no machine tag.

**Tracking audit log — when each event fires:**

| Event | Trigger | Location | Condition |
|-------|---------|----------|-----------|
| `[TRACK-CREATE]` | C++ pushes a ScanCommand to `pending_commands_` | Inside `processScan()` after deconvolution, during MS2/MS3 command generation | One per ScanCommand created. Logged immediately after `pending_scan_map_[id]` is stored. |
| `[TRACK-CREATE]` | C# requests tracking ID for MS1/AGC fallback | `ScanScheduler.getNextScan()` step 5 (empty fallback) | When `GetNextTrackingId()` is called. C# logs to IDAlog: `[TRACK-CREATE] id=TTTT type=MS1`. |
| `[TRACK-RESOLVE]` | C++ receives a returning scan with known tracking ID | Inside `processScan()` when `pending_scan_map_.find(id)` succeeds | One per returning scan. Logged after deconvolution + scoring completes. If this triggers follow-up commands (MS3, conditional), those get their own `[TRACK-CREATE]`. |
| `[TRACK-EXPIRE]` | Stale entry removed from `pending_scan_map_` | Inside `processScan()` periodic cleanup (every N calls) | When `(now_ms - creation_time) > timeout_ms`. Also logged when `getNextScan()` drops a stale scan from the C# queue. |

AGC scans (magic ID 41) are NOT tracked — they are fire-and-forget instrument probes.

**Log format:**
```
[TRACK-CREATE]  id=0a1b int=36891 msn=2 mass=14037.90 z=19 CE=25 HCD mode=std
[TRACK-RESOLVE] id=0a1b int=36891 msn=2 mass=14037.90 z=19 peaks=12 score=0.87
[TRACK-EXPIRE]  id=0a1b int=36891 age_ms=30000
```

**Functions eliminated:** `GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, `GetBestMS2Masses`, `GetTopFragmentMatches`, `GetAmbiguityEnclosingIons`, `GetTerminalFragmentIons`, `HasMS2Deconvolution`, `GetMS2PeakGroupCount`, `ClearMS2Deconvolution`, `ProcessMS2ForTagBasedTargeting`, `IsDifferentiallyAbundant`

**Files:** `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 2 — Command Channel with Atomic Drain

### Desired behaviour
C++ pushes MSn scan commands via a single queue. C# drains atomically. Up to MS10 supported. 4 priority levels.

### Limitations of current design
No command channel. C++ returns data via separate query functions.

### Proposed change

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
    int msn_level;
    int num_isolation_stages;
    IsolationStage stages[MAX_ISOLATION_STAGES];
    double max_it;
    int agc_target;
    int orbitrap_resolution;
    char analyzer[32];
    double faims_cv;
    char scan_description[256];
    int priority;                   // 0=background, 1=normal, 2=high, 3=urgent
    uint64_t enqueue_timestamp_ms;
    int is_agc;
};
```

```cpp
extern "C" OPENMS_DLLAPI int GetAndClearPendingCommands(
    FLASHIda* obj,
    int max_count,
    ScanCommand* commands);
```

**Files:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 3 — ScanScheduler: Command Drain at Dequeue, Priority Queues, AGC/MS1 Bypass

### Desired behaviour
Commands are picked up at the **dequeue point** (`getNextScan`), not during scan processing. This ensures commands are available immediately when the instrument asks for the next scan, regardless of async processing latency. AGC and MS1 scans bypass the queue. 4 priority levels. Configurable timeout and cycle time. MS1 parameters are currently pre-built in C# but will be requested from C++ in a future phase.

### Limitations of current design
v7 drained commands inside `ProcessMS()`, which runs asynchronously on the TPL thread pool. By the time commands were enqueued, `getNextScan()` had already returned a fallback scan. Commands sat idle until the next scan arrived.

### Proposed change

**`getNextScan()` drains C++ commands at the START, before any dequeue logic:**

```
getNextScan()
│
▼
┌─[lock(sync)]──────────────────────────────────────────┐
│                                                        │
│  (0) DRAIN C++ COMMANDS                                │
│  count = wrapper.GetAndClearPendingCommands(buffer)    │
│  for each cmd:                                         │
│    scan = scanFactory.BuildFromCommand(cmd)            │
│    queues[cmd.priority].AddLast(scan)                  │
│                                                        │
│  (1) AGC BYPASS                                        │
│  Is AGC due? ──YES──► return pre-built agcScan         │
│       │                                                │
│       NO                                               │
│       ▼                                                │
│  (2) MS1 CYCLE TIME                                    │
│  Elapsed > cycleTimeSeconds?                           │
│    YES ──► id = wrapper.GetNextTrackingId()            │
│            stamp defaultScan with "TTTT MS1"           │
│            return pre-built agcScan + enqueue MS1      │
│       │                                                │
│       NO                                               │
│       ▼                                                │
│  (3) TIMEOUT CLEANUP                                   │
│  Walk all 4 queues:                                    │
│    drop if (now_ms - enqueue_timestamp_ms) > timeout   │
│       │                                                │
│       ▼                                                │
│  (4) PRIORITY DEQUEUE (3 → 2 → 1 → 0)                 │
│  For level = 3 downto 0:                               │
│    if queue[level] non-empty → return first            │
│       │                                                │
│       NO (all empty)                                   │
│       ▼                                                │
│  (5) EMPTY FALLBACK                                    │
│  id = wrapper.GetNextTrackingId()                      │
│  stamp + enqueue defaultScan                           │
│  return pre-built agcScan                              │
│                                                        │
└────────────────────────────────────────────────────────┘
```

**Key change from v7:** Step (0) is new. Commands drained synchronously on the instrument thread BEFORE any dequeue. `ProcessMS()` only calls `ProcessScan()` — it returns empty and does NOT drain commands.

**MS1 scan parameters:** Currently pre-built in C# at startup from method XML (static). AGC uses magic ID 41 (never changes). Future Phase 2: `RequestMS1Scan` bridge for C++-decided adaptive parameters. Documented as TODO.

**Method XML** (under `<MSSettings>`, 2-space indent, one tag per line):

```xml
<ScanScheduling>
  <CycleTime>
    <Active>False</Active>
    <Seconds>60</Seconds>
  </CycleTime>
  <ScanTimeout>
    <Active>False</Active>
    <Seconds>30</Seconds>
  </ScanTimeout>
</ScanScheduling>
```

**Files:** `ScanScheduler.cs`, `FLASHIdaWrapper.cs`, `MethodConfig.cs`, `MethodParameters.cs`, `method.xml`

---

## Issue 4 — MSn-Generalized Exploration Engine

### Desired behaviour
C++ autonomously manages parameter exploration at any MSn level. MS2 winner triggers MS3 exploration (if configured). Recursive, depth-limited. C# is not involved.

### Limitations of current design
No exploration concept. No comparative scoring. No MSn chaining.

### Proposed change

MSn-aware `ExplorationGroup` and `ExplorationVariant` with `msn_level` and `parent_tracking_id`. Recursive group creation: MS2 winner → MS3 exploration → MS3 winner → MS4 (depth-limited by config).

Recognition via tracking ID in scan description. C++ parses ID → looks up `pending_scan_map_` → routes to exploration handler if `exploration_group_id > 0`.

**Config** (2-space indent, one tag per line):

```xml
<ParameterOptimization>
  <Active>False</Active>
  <OptimizationStrategy>Exhaustive</OptimizationStrategy>
  <ScanLimits>
    <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
    <MaxQueueForExploration>50</MaxQueueForExploration>
    <MaxExplorationDepth>2</MaxExplorationDepth>
  </ScanLimits>
  <MS2Exploration>
    <Enabled>true</Enabled>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>20</Min>
      <Max>40</Max>
      <Step>5</Step>
      <Activation>HCD</Activation>
    </CollisionEnergyOptimization>
    <IsolationWidthOptimization>
      <Enabled>false</Enabled>
      <Values>
        <double>1.0</double>
        <double>2.0</double>
        <double>4.0</double>
      </Values>
    </IsolationWidthOptimization>
  </MS2Exploration>
  <MS3Exploration>
    <Enabled>false</Enabled>
    <TriggerAfterMS2Winner>true</TriggerAfterMS2Winner>
    <MaxFragmentsToExplore>3</MaxFragmentsToExplore>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>15</Min>
      <Max>35</Max>
      <Step>5</Step>
      <Activation>CID</Activation>
    </CollisionEnergyOptimization>
  </MS3Exploration>
  <Scoring>
    <MetricType>FragmentationQuality</MetricType>
  </Scoring>
</ParameterOptimization>
```

**Files:** `FLASHIda.h/.cpp`

---

## Issue 5 — Scoring in the Unified Architecture

### Desired behaviour
The existing QScore and IDScore mechanisms drive precursor selection and command generation through the unified `ProcessScan` entry point.

### Limitations of current design
QScore and IDScore already exist and work. The limitation is that they are currently consumed by separate bridge functions (`GetIsolationWindows` returns scored targets). In the unified architecture, they must drive ScanCommand generation inside `ProcessScan`.

### Proposed change

**How existing scoring flows through the new architecture:**

1. **QScore** (logistic regression, 5-feature vector): Computed by `PeakGroupScoring::getQscore()` during deconvolution in `SpectralDeconvolution`. Stored on each `PeakGroup`. Used in `DeconvolvedSpectrum::sortByQscore()` to rank precursors.

2. **IDScore** (HCD-energy-aware, combines QScore + mass + charge): Computed by `PeakGroupScoring::getIDscores()`. Used in `DeconvolvedSpectrum::sortByIDScoreRepresentative()`.

3. **Scoring dispatch** in `filterPeakGroupsUsingMassExclusion_()`:
   - `use_idscore_ && consider_all_Charge_states_` → sort by IDScore across all charges
   - `use_idscore_` → sort by IDScore for representative charge
   - Default → sort by QScore

4. **Threshold filtering**: `qscore_threshold_` gates candidate selection. `tqscore_threshold` gates cumulative score for mass exclusion.

5. **In ProcessScan**: After deconvolution and scoring, the top-ranked peak groups are converted to `ScanCommand` structs and pushed to `pending_commands_`. The score ranking determines command order and which precursors get selected.

**Configuration** (existing, passed via constructor):
- `use_idscore`: Enable IDScore instead of QScore for ranking
- `consider_all_Charge_states`: Score across all charge states
- `qscore_threshold`: Minimum QScore for precursor selection
- `tqscore_threshold`: Cumulative score threshold for mass exclusion
- `HCDEnergy`: HCD energy for IDScore weight selection

No new scoring algorithms are introduced. The existing models drive command generation.

**Files:** `FLASHIda.cpp` (scoring dispatch inside processScan)

---

## Issue 6 — Unified C# Scan Processor

### Desired behaviour
One `IScanProcessor` handles all modes. `ProcessMS()` only calls `ProcessScan()` and returns empty — it does NOT drain commands. All command pickup happens in `getNextScan()` (Issue 3). C# is a stateless forwarder.

### Limitations of current design
v7 drained commands inside `ProcessMS()`, creating a timing gap: commands were enqueued asynchronously via `OutputMS()`, but `getNextScan()` was called synchronously before `ProcessMS()` completed on the TPL thread pool.

### Proposed change

```csharp
public class UnifiedScanProcessor : IScanProcessor
{
    public IEnumerable<IFusionCustomScan> ProcessMS(IMsScan msScan)
    {
        if (msScan.Header["MassAnalyzer"] != "FTMS")
            return Enumerable.Empty<IFusionCustomScan>();

        double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
        double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();
        double rt = double.Parse(msScan.Header["StartTime"]);
        int msLevel = int.Parse(msScan.Header["MSOrder"]);
        msScan.Trailer.TryGetValue("Scan Description", out var scanDesc);

        // Fire and forget — C++ queues commands internally
        wrapper.ProcessScan(mzs, ints, mzs.Length, rt, msLevel, scanDesc ?? "");

        // Return empty — commands are picked up by getNextScan()
        return Enumerable.Empty<IFusionCustomScan>();
    }

    public void OutputMS(IFusionCustomScan scan)
    {
        // Only handles null sentinel for AddDefault
        if (scan == null) scanScheduler.AddDefault();
    }
}
```

`Flash.cs` simplified: `flashIDAProcessor = new UnifiedScanProcessor(...)`.

`QuantScanProcessor` and `FAIMSScanProcessor` eliminated — all modes routed through C++ ProcessScan.

**Files:** `IDAScanProcessor.cs` (rewritten), `Flash.cs`

---

## Issue 7 — P/Invoke Declarations

### Desired behaviour
Minimal bridge surface supporting MSn. Multiple priority levels. JSON config.

### Limitations of current design
~20 bridge functions. No MSn generalization. Space-delimited config.

### Proposed change

```csharp
// Lifecycle
[DllImport(dllName)] static extern IntPtr CreateFLASHIda(string arg); // auto-detects JSON vs legacy
[DllImport(dllName)] static extern void DisposeFLASHIda(IntPtr ptr);

// Core operations
[DllImport(dllName)] static extern int ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc);
[DllImport(dllName)] static extern int GetAndClearPendingCommands(IntPtr ptr,
    int maxCount, [Out] ScanCommand[] commands);

// Utility
[DllImport(dllName)] static extern int GetNextTrackingId(IntPtr ptr);
```

5 bridge functions total (down from ~20). Old functions kept as `[Obsolete]` wrappers during migration.

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 8 — JSON Configuration

### Desired behaviour
New configuration parameters use JSON format. The existing constructor auto-detects format. Nested, human-readable structure. Backwards compatible with legacy space-delimited format.

### Limitations of current design
`CreateFLASHIda(char* arg)` parses a space-delimited key-value string via `strtok`. No nesting, no escaping, fragile for complex structures like arrays and sub-objects.

### Proposed change

**Auto-detection in constructor:** If arg starts with `{`, parse as JSON. Otherwise, parse as legacy space-delimited.

**C++ uses bundled `nlohmann_json`** (already in OpenMS at `src/openms/extern/nlohmann_json/`).

**C# uses `JavaScriptSerializer`** (built into .NET 4.8 via `System.Web.Extensions`).

**JSON schema:**

```json
{
  "deconvolution": {
    "score_threshold": -1,
    "min_charge": 1,
    "max_charge": 100,
    "min_mass": 50,
    "max_mass": 100000,
    "tol": [10, 10]
  },
  "precursor_selection": {
    "max_mass_count": 5,
    "RT_window": 5,
    "tqscore_threshold": 0.9,
    "target_mode": 0,
    "IDScore": false,
    "AllCharges": false,
    "HCDEnergy": 29
  },
  "quantification": {
    "enabled": false,
    "reporter_mz_tol": 0.002,
    "fold_change_threshold": 1.4,
    "only_one_condition": false
  },
  "faims": {
    "cv_values": [-40, -50, -60],
    "max_cv_skip": 0,
    "mass_threshold": 15
  },
  "exploration": {
    "enabled": false,
    "max_depth": 1,
    "max_variants": 5,
    "ms2": {
      "ce_min": 20,
      "ce_max": 40,
      "ce_step": 5,
      "activation": "HCD"
    }
  },
  "tagging": {
    "enabled": false,
    "min_tag_length": 3,
    "max_tag_length": 8,
    "fasta_file": null
  },
  "ms3": {
    "enabled": false,
    "mode": 0,
    "max_per_ms2": 4,
    "protein_sequence": null
  }
}
```

**C# serialization** (`Parameter.cs`):

```csharp
public string ToJSON()
{
    var jss = new JavaScriptSerializer();
    var config = new Dictionary<string, object>
    {
        ["deconvolution"] = new Dictionary<string, object> {
            ["score_threshold"] = QScoreThreshold,
            ["min_charge"] = MinCharge,
            // ...
        },
        ["quantification"] = new Dictionary<string, object> {
            ["enabled"] = isobaricQuantification,
            ["reporter_mz_tol"] = QuantReporterMZTol,
            // ...
        },
        // ... all sections
    };
    return jss.Serialize(config);
}
```

**C++ parsing** (`FLASHIda.cpp`):

```cpp
FLASHIda::FLASHIda(char* arg)
{
    std::string s(arg);
    s.erase(0, s.find_first_not_of(" \t\n\r"));
    if (!s.empty() && s[0] == '{')
    {
        auto j = nlohmann::json::parse(s);
        parseJSONConfig_(j);
    }
    else
    {
        parseSpaceDelimitedConfig_(arg); // existing code
    }
}
```

**Method XML auto-doc:** Config classes annotated with `[Description("...")]`. NEW `MethodDocGenerator.cs` (~30 lines) generates Markdown via reflection. Pre-existing: `System.ComponentModel.DescriptionAttribute`. New: the generator utility and output file.

**Files:** `FLASHIda.h/.cpp`, `Parameter.cs`, `FLASHIdaWrapper.cs`, `MethodConfig.cs`, NEW `MethodDocGenerator.cs`

---

## Issue 9 — Acquisition Metadata (Decoupled OptimizationMetadata)

### Desired behaviour
Optimization metadata decoupled from core PeakGroup via a separate `OptimizationMetadata` struct. Zero overhead when disabled. Survives the full pipeline: acquisition → mzML → post-hoc analysis.

### Limitations of current design
PeakGroup has no metadata infrastructure. It doesn't inherit from `MetaInfoInterface`. Adding 24 fields directly would bloat every PeakGroup even when optimization is off.

### Proposed change

**NEW `OptimizationMetadata.h`:**

```cpp
struct OptimizationMetadata
{
    // Context
    int group_id = 0;
    int variant_index = -1;
    int total_variants = 0;
    bool is_best_variant = false;
    int rank = 0;
    int msn_level_optimized = 0;
    int parent_tracking_id = 0;

    // Parameters used
    double collision_energy = 0;
    double isolation_width = 0;
    std::string activation_type;
    double precursor_mass = 0;
    int precursor_charge = 0;

    // Quality
    double fragmentation_quality_score = -1;
    float tic_coverage = 0;
    int fragment_count = 0;

    // Timing
    uint64_t start_ms = 0;
    uint64_t complete_ms = 0;

    // Cost
    int exploration_scans = 0;
    int overhead_factor = 1;
};
```

**PeakGroup attachment:**

```cpp
class PeakGroup
{
    std::optional<OptimizationMetadata> opt_metadata_;
public:
    OptimizationMetadata& getOrCreateOptimizationMetadata();
    const OptimizationMetadata* getOptimizationMetadata() const;
    bool hasOptimizationMetadata() const;
};
```

### Concrete use case

**Scenario:** A researcher runs a top-down acquisition with parameter optimization enabled. Afterwards, they want to answer: "What collision energy was optimal for large proteins (>30 kDa) vs. small proteins (<10 kDa)?"

**How the metadata flows:**

1. **During acquisition:** C++ exploration engine populates `OptimizationMetadata` on each variant's PeakGroups (setting CE, score, rank, etc.)

2. **On mzML export:** `DeconvolvedSpectrum::toSpectrum()` writes metadata via `setMetaValue`:
   ```xml
   <userParam name="optimization_group_id" value="5" type="xsd:int"/>
   <userParam name="optimization_collision_energy" value="25" type="xsd:double"/>
   <userParam name="optimization_is_best_variant" value="true" type="xsd:boolean"/>
   <userParam name="optimization_quality_score" value="0.847" type="xsd:double"/>
   <userParam name="optimization_precursor_mass" value="14038.52" type="xsd:double"/>
   ```

3. **Post-hoc analysis in Python (pyOpenMS):**
   ```python
   import pyopenms as oms
   from collections import defaultdict

   exp = oms.MSExperiment()
   oms.MzMLFile().load("optimized_run.mzML", exp)

   mass_bins = {"large": (30000, 200000, []), "small": (0, 10000, [])}

   for spec in exp:
       if spec.getMSLevel() != 2:
           continue
       try:
           mass = float(spec.getMetaValue("optimization_precursor_mass"))
           ce = float(spec.getMetaValue("optimization_collision_energy"))
           is_best = spec.getMetaValue("optimization_is_best_variant") == "true"
           if not is_best:
               continue
           for label, (lo, hi, results) in mass_bins.items():
               if lo <= mass < hi:
                   results.append(ce)
       except:
           pass

   for label, (_, _, ces) in mass_bins.items():
       if ces:
           print(f"{label}: optimal CE = {sum(ces)/len(ces):.1f} V "
                 f"(n={len(ces)}, range={min(ces)}-{max(ces)})")
   ```

   **Output:**
   ```
   large: optimal CE = 22.3 V (n=47, range=15-30)
   small: optimal CE = 28.7 V (n=123, range=20-40)
   ```

This demonstrates that large proteins fragment better at lower CE, while small proteins need higher CE — actionable information for method development.

**Files:** NEW `OptimizationMetadata.h`, `PeakGroup.h/.cpp`, `DeconvolvedSpectrum.cpp`

---

## Backwards Compatibility

| Mode | Risk | Key Concern |
|------|------|-------------|
| Standard DDA | Low | ProcessScan replaces old calls 1:1 |
| Deep/Inclusion/Exclusion | Low | C++ internal |
| MS2 Tagging | Medium | Absorbed into ProcessScan routing |
| Conditional MS2 | Medium | Follow-up decisions move to C++ |
| Isobaric Quant | Medium | IsDifferentiallyAbundant called internally |
| MS3 (all modes) | Medium | Fragment selection via command channel |
| FAIMS (multi-CV) | **High** | CV state machine moves to C++ |
| Test mode | Low | Old functions kept as wrappers |

---

## Phased Migration

### Phase 1: C++ Foundation (C++ build #1)

**Goal:** ProcessScan stub, command queue, tracking system, JSON constructor, OptimizationMetadata struct.

**C++ files:**
- `FLASHIda.h/.cpp` — `processScan()` (dispatches to existing functions), `pending_scan_map_`, `pending_commands_`, mutex, atomic tracking counter, base36 utilities, TRACK logging, JSON constructor auto-detect via `nlohmann_json`
- `FLASHIdaBridgeFunctions.h/.cpp` — `ProcessScan`, `GetAndClearPendingCommands`, `GetNextTrackingId` exports
- NEW `OptimizationMetadata.h`
- `PeakGroup.h/.cpp` — `std::optional<OptimizationMetadata>`

**C# files:**
- `FLASHIdaWrapper.cs` — P/Invoke declarations, ScanCommand struct, `ToBase36`
- `Parameter.cs` — `ToJSON()` method

**Verify:** `Flash.exe -t` unchanged. New functions callable.
**Scope:** M

### Phase 2: C# Infrastructure (no C++ build)

**Goal:** ScanScheduler with command drain at dequeue, method XML expansion.

**C# files:**
- `ScanScheduler.cs` — command drain at top of `getNextScan()`, 4 priority queues (LinkedList+lock), timeout, AGC/MS1 bypass, cycle time
- NEW `UnifiedScanProcessor.cs` (behind feature flag)
- `MethodConfig.cs` — `ScanSchedulingConfig`, `ParameterOptimizationConfig`, `[Description]` attrs
- `method.xml` — template sections

**Verify:** Feature flag on: standard DDA works. Flag off: old behavior.
**Scope:** L

### Phase 3: Wire ProcessScan + Eliminate Quant (C++ build #2, batched with Phase 1)

**Goal:** ProcessScan handles MS1+MS2+quant. QuantScanProcessor eliminated.

**C++ files:**
- `FLASHIda.cpp` — `processScan()` routes MS1 (deconvolve + push MS2 commands), MS2 (deconvolve + tagging/conditional/MS3/quant internally). Internal `isDifferentiallyAbundant` for quant.

**C# files:**
- `Flash.cs` — remove QuantScanProcessor branch, use UnifiedScanProcessor
- Delete `QuantScanProcessor.cs`

**Verify:** Standard DDA + quant produce identical results.
**Scope:** L

### Phase 4: FAIMS Absorption (highest risk, C++ build #3)

**Goal:** FAIMS CV cycling in C++. FAIMSScanProcessor eliminated.

**C++ files:** `FLASHIda.h/.cpp` — CV state machine, adaptive skip, FAIMS command generation
**C# files:** Delete `FAIMSScanProcessor.cs`. Remove FAIMS state from `ScanScheduler.cs`.

**Verify:** Multi-CV dataset: identical CV sequence and skip patterns.
**Scope:** M (highest risk)

### Phase 5: Exploration Engine (C++ build #4, batched with Phase 4)

**Goal:** MSn-generalized parameter optimization.

**C++ files:** `FLASHIda.h/.cpp` — MSn-aware ExplorationGroup/Variant, recursive group creation, scoring, winner selection, OptimizationMetadata population, mzML serialization via `setMetaValue`.

**Verify:** Optimization disabled: identical. Enabled: variant scoring in logs.
**Scope:** L

### Phase 6: Cleanup + Documentation

**Goal:** Remove deprecated bridge functions, generate docs.

**C++ files:** Remove 12 old exports.
**C# files:** Remove `[Obsolete]` declarations, `pendingMS2s`, old tracking code. NEW `MethodDocGenerator.cs`.

**Verify:** Full regression. `Flash.exe -t`.
**Scope:** M

### Build Batching

| C++ Build | Phases |
|-----------|--------|
| Build 1 | Phase 1 + 3 |
| Build 2 | Phase 4 + 5 |
| Build 3 | Phase 6 |

---

## Design Invariants

1. **Two operational bridge functions:** `ProcessScan` + `GetAndClearPendingCommands`
2. **Commands drained at dequeue point** (`getNextScan`), not during processing
3. **C++ resolves everything from tracking ID**
4. **AGC/MS1 bypass queue** — pre-built, returned directly when due
5. **4 priority levels:** 0=background, 1=normal, 2=high, 3=urgent
6. **JSON config** via auto-detection in constructor (legacy format still works)
7. **OptimizationMetadata decoupled** via `std::optional` on PeakGroup
8. **Audit trail:** TRACK-CREATE, TRACK-RESOLVE, TRACK-EXPIRE on every tracked scan
9. **Old bridge functions survive through Phase 5**
10. **MSn exploration is recursive**, depth-limited by config

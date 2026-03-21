# Parameter Optimization Plan — v9

**Date:** 2026-03-20
**Revision:** 9

**Design principle:** C++ owns the scan queue. C# calls `ProcessScan` to feed spectra and `GetNextScanCommand` to retrieve one command at a time. C# translates ScanCommand→IFusionCustomScan and submits to the instrument. ScanScheduler eliminated. Full method config passed as JSON.

---

## Issue 1 — Unified ProcessScan Bridge

### Desired behaviour
A single C++ entry point handles all MSn levels. C# passes spectrum data + scan description. C++ resolves all context from its tracking state. Every tracking ID is audit-logged.

### Limitations of current design
~20 specialized bridge functions. C# orchestrates multi-step call sequences. No audit trail.

### Proposed change

```cpp
extern "C" OPENMS_DLLAPI int ProcessScan(
    FLASHIda* obj,
    double* mzs, double* ints, int length,
    double rt_min, int ms_level,
    const char* scan_description);
```

Returns number of commands pushed. Tracking ID: 4-char base-36, C++ atomic counter.

**Audit log:**

| Event | Trigger | Condition |
|-------|---------|-----------|
| `[TRACK-CREATE]` | C++ pushes ScanCommand | After `pending_scan_map_[id]` stored |
| `[TRACK-CREATE]` | C++ generates MS1/AGC | When `GetNextScanCommand` returns MS1/AGC |
| `[TRACK-RESOLVE]` | `ProcessScan` matches ID | After deconvolution + scoring |
| `[TRACK-EXPIRE]` | Stale entry cleanup | When `(now - creation_time) > timeout` |

**Files:** `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 2 — ScanCommand Struct

### Desired behaviour
C++ communicates scan requests via a flat, blittable struct. Up to MS10. 4 priority levels. Includes AGC magic fields.

### Limitations of current design
No command struct exists.

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
    int priority;
    uint64_t enqueue_timestamp_ms;
    int is_agc;
    int scan_id;
};
```

**Files:** `FLASHIda.h`, `FLASHIdaWrapper.cs`

---

## Issue 3 — C++ Owns the Scan Queue

### Desired behaviour
C++ manages the entire scan queue: priority, timeout, MS1 cycle time, AGC, FAIMS CV. C# retrieves ONE command at a time. ScanScheduler eliminated.

### Limitations of current design
ScanScheduler in C# manages ConcurrentQueue. C++ has no queue visibility. AGC/MS1/FAIMS scheduling in C#.

### Proposed change

```cpp
extern "C" OPENMS_DLLAPI int GetNextScanCommand(
    FLASHIda* obj,
    ScanCommand* output);
```

Returns 1 if command available, 0 if not.

**Internal C++ logic:**

```cpp
int FLASHIda::getNextScanCommand(ScanCommand& out)
{
    std::lock_guard<std::mutex> lock(queue_mutex_);

    // (1) AGC — always first
    if (needsAGCScan_())
        { out = makeAGCCommand_(); return 1; }

    // (2) MS1 cycle time
    if (cycle_time_enabled_ && msSinceLastMS1_() > cycle_time_ms_)
        { out = makeMS1Command_(); return 1; }

    // (3) Timeout cleanup
    cleanupExpiredCommands_();

    // (4) Priority dequeue (3→0)
    for (int lvl = 3; lvl >= 0; lvl--)
        if (!queues_[lvl].empty())
            { out = queues_[lvl].front(); queues_[lvl].pop_front(); return 1; }

    // (5) Empty → MS1
    out = makeMS1Command_();
    return 1;
}
```

C++ knows all scan parameters (MS1 analyzer, m/z range, resolution, AGC target, FAIMS CVs) via JSON config. AGC command: `analyzer="IonTrap"`, `scan_id=41`, `is_agc=1`, `agc_target=30000`, `max_it=1`.

**C# side (Flash.cs):**

```csharp
private static void ProcessSpectrum(object sender, MsScanEventArgs e)
{
    IMsScan msScan = e.GetScan();
    if (inCustom)
    {
        dataPipe.Push(msScan);
        var cmd = new ScanCommand();
        if (wrapper.GetNextScanCommand(ref cmd) == 1)
            SendCustomScan(scanFactory.BuildFromCommand(cmd));
    }
    msScan.Dispose();
}
```

**ScanScheduler.cs DELETED.**

**Method XML:**

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

**Files:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`, `Flash.cs`, DELETE `ScanScheduler.cs`

---

## Issue 4 — MSn-Generalized Exploration Engine

### Desired behaviour
C++ manages parameter exploration at any MSn level. Recursive, depth-limited. CE optimization only (IsolationWidth optimization removed). C++ controls MS1 timing — can suppress cycle time during exploration.

### Limitations of current design
No exploration. No comparative scoring. No MSn chaining.

### Proposed change

MSn-aware `ExplorationGroup`/`ExplorationVariant` with `msn_level`, `parent_tracking_id`. Recursive group creation.

**Config:**

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
Existing QScore/IDScore drive precursor selection and command generation inside ProcessScan.

### Limitations of current design
Scoring exists but consumed by separate bridge functions.

### Proposed change — C++ pseudocode:

```cpp
int FLASHIda::processScan(...)
{
    if (ms_level == 1)
    {
        // DECONVOLVE
        deconvolved_spectrum_ = fd_.performDeconvolution(spec);

        // SCORE & SORT (existing dispatch)
        if (use_idscore_ && consider_all_Charge_states_)
            deconvolved_spectrum_.sortByIDScoreAllCharges(hcd_energy_);
        else if (use_idscore_)
            deconvolved_spectrum_.sortByIDScoreRepresentative(hcd_energy_);
        else
            deconvolved_spectrum_.sortByQscore();

        // FILTER (mass exclusion, targeting, thresholds)
        filterPeakGroupsUsingMassExclusion_(1, rt);

        // SELECT TOP N → PUSH MS2 COMMANDS
        for (each selected_peak_group)
        {
            ScanCommand cmd = buildMS2Command_(peak_group, charge, hcd);
            pushCommand_(cmd);
        }
    }
    else if (ms_level == 2)
    {
        // RESOLVE from pending_scan_map_
        auto& ctx = pending_scan_map_[parseBase36(scan_desc)];

        // DECONVOLVE with full precursor annotation
        ms2_deconv = fd_.performDeconvolution(spec_with_precursor);

        // ROUTE BY MODE
        if (ctx.exploration_group_id > 0)
            feedExplorationResult_(ctx, ms2_deconv);
        else if (tag_based_targeting_enabled_)
            processMS2ForTagBasedTargeting(ctx.precursor_mass);
        else if (quant_enabled_)
            if (isDifferentiallyAbundant(...))
                pushFollowUpMS2_(ctx);

        // MS3 TARGETING
        if (ms3_enabled_)
            for (auto& target : selectMS3Targets_(ms2_deconv))
                pushCommand_(buildMS3Command_(ctx, target));
    }
}
```

**Files:** `FLASHIda.cpp`

---

## Issue 6 — Simplified C# Architecture

### Desired behaviour
`ProcessMS` calls `ProcessScan`, returns void. OutputMS removed. DataPipe simplified to `ActionBlock<IMsScan>`. Single scan processor.

### Limitations of current design
Three-stage DataPipe. OutputMS/null sentinel pattern. Three processor implementations.

### Proposed change

**IScanProcessor:**
```csharp
public interface IScanProcessor
{
    void ProcessMS(IMsScan msScan);
}
```

**UnifiedScanProcessor:**
```csharp
public class UnifiedScanProcessor : IScanProcessor
{
    public void ProcessMS(IMsScan msScan)
    {
        if (msScan.Header["MassAnalyzer"] != "FTMS") return;
        double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
        double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();
        wrapper.ProcessScan(mzs, ints, mzs.Length,
            double.Parse(msScan.Header["StartTime"]),
            int.Parse(msScan.Header["MSOrder"]),
            msScan.Trailer.GetValueOrDefault("Scan Description", ""));
    }
}
```

**DataPipe:**
```csharp
inputScans = new BufferBlock<IMsScan>();
scanProcessor = new ActionBlock<IMsScan>(processor.ProcessMS);
inputScans.LinkTo(scanProcessor, new DataflowLinkOptions { PropagateCompletion = true });
```

**Deleted:** `ScanScheduler.cs`, `FAIMSScanProcessor.cs`, `QuantScanProcessor.cs`, `OutputMS` method.

**Files:** `IScanProcessor.cs`, `DataPipe.cs`, `Flash.cs`, NEW `UnifiedScanProcessor.cs`

---

## Issue 7 — P/Invoke Declarations

### Desired behaviour
5 bridge functions total.

### Proposed change

```csharp
[DllImport(dllName)] static extern IntPtr CreateFLASHIda(string jsonConfig);
[DllImport(dllName)] static extern void DisposeFLASHIda(IntPtr ptr);
[DllImport(dllName)] static extern int ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc);
[DllImport(dllName)] static extern int GetNextScanCommand(IntPtr ptr,
    ref ScanCommand output);
[DllImport(dllName)] static extern int GetNextTrackingId(IntPtr ptr);
```

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 8 — Full JSON Configuration

### Desired behaviour
Full method.xml serialized to JSON, passed to `CreateFLASHIda`. C++ parses what it needs. Auto-detect format.

### Limitations of current design
Custom `ToFLASHDeconvInput()` — space-delimited tokens, fragile, no nesting. MSSettings never reach C++.

### Proposed change

C++ auto-detects: `if (arg[0] == '{') parseJSON; else parseLegacy;`

**JSON schema:**
```json
{
  "deconvolution": {
    "score_threshold": -1,
    "min_charge": 1,
    "max_charge": 100,
    "tol": [10, 10]
  },
  "precursor_selection": {
    "max_mass_count": 5,
    "RT_window": 5,
    "target_mode": 0,
    "IDScore": false,
    "HCDEnergy": 29
  },
  "quantification": {
    "enabled": false,
    "reporter_mz_tol": 0.002,
    "fold_change_threshold": 1.4
  },
  "faims": {
    "cv_values": [-40, -50, -60],
    "max_cv_skip": 0
  },
  "ms_settings": {
    "ms1": {
      "Analyzer": "Orbitrap",
      "FirstMass": 350,
      "LastMass": 2000,
      "OrbitrapResolution": 120000,
      "AGCTarget": 1000000,
      "MaxIT": 50
    },
    "ms2": [
      {
        "Analyzer": "Orbitrap",
        "Activation": "HCD",
        "CollisionEnergy": 25,
        "OrbitrapResolution": 60000
      }
    ],
    "ms3": []
  },
  "scheduling": {
    "cycle_time_enabled": false,
    "cycle_time_seconds": 60,
    "timeout_enabled": false,
    "timeout_seconds": 30
  },
  "exploration": {
    "enabled": false,
    "max_depth": 1,
    "max_variants": 5
  },
  "files": {
    "fasta": null,
    "inclusion_list": null
  }
}
```

C# uses `JavaScriptSerializer`. C++ uses bundled `nlohmann_json`.

**Auto-doc:** `[Description]` attributes + NEW `MethodDocGenerator.cs` (~30 lines reflection utility).

**Files:** `Parameter.cs`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`, `MethodConfig.cs`

---

## Issue 9 — Acquisition Metadata on DeconvolvedSpectrum

### Desired behaviour
Optimization metadata on `DeconvolvedSpectrum` (spectrum level). Serialized via `MSSpectrum.setMetaValue()` for mzML export. Zero overhead when disabled.

### Limitations of current design
No optimization metadata exists. `DeconvolvedSpectrum` has no dedicated metadata struct. Its embedded `MSSpectrum spec_` inherits `MetaInfoInterface` (via `SpectrumSettings`), enabling `setMetaValue`/`getMetaValue`.

### Proposed change

**NEW `OptimizationMetadata.h`:**
```cpp
struct OptimizationMetadata
{
    int group_id = 0;
    int variant_index = -1;
    int total_variants = 0;
    bool is_best_variant = false;
    int rank = 0;
    int msn_level_optimized = 0;
    int parent_tracking_id = 0;
    double collision_energy = 0;
    double isolation_width = 0;
    std::string activation_type;
    double precursor_mass = 0;
    int precursor_charge = 0;
    double fragmentation_quality_score = -1;
    float tic_coverage = 0;
    int fragment_count = 0;
    uint64_t start_ms = 0;
    uint64_t complete_ms = 0;
    int exploration_scans = 0;
};
```

**On DeconvolvedSpectrum:**
```cpp
class DeconvolvedSpectrum
{
    std::optional<OptimizationMetadata> opt_metadata_;
public:
    OptimizationMetadata& getOrCreateOptimizationMetadata();
    const OptimizationMetadata* getOptimizationMetadata() const;
    bool hasOptimizationMetadata() const;
};
```

**mzML serialization** in `toSpectrum()`:
```cpp
if (opt_metadata_)
{
    out_spec.setMetaValue("optimization_group_id", (int)opt_metadata_->group_id);
    out_spec.setMetaValue("optimization_collision_energy", opt_metadata_->collision_energy);
    out_spec.setMetaValue("optimization_is_best_variant",
                          opt_metadata_->is_best_variant ? "true" : "false");
    out_spec.setMetaValue("optimization_quality_score",
                          opt_metadata_->fragmentation_quality_score);
    out_spec.setMetaValue("optimization_precursor_mass", opt_metadata_->precursor_mass);
}
```

**Concrete use case:** Post-acquisition, analyze optimal CE by protein mass range:

```python
import pyopenms as oms
exp = oms.MSExperiment()
oms.MzMLFile().load("optimized_run.mzML", exp)

results = {"large": [], "small": []}
for spec in exp:
    if spec.getMSLevel() != 2: continue
    try:
        mass = float(spec.getMetaValue("optimization_precursor_mass"))
        ce = float(spec.getMetaValue("optimization_collision_energy"))
        is_best = spec.getMetaValue("optimization_is_best_variant") == "true"
        if not is_best: continue
        results["large" if mass > 30000 else "small"].append(ce)
    except: pass

for label, ces in results.items():
    if ces:
        print(f"{label}: optimal CE = {sum(ces)/len(ces):.1f} V (n={len(ces)})")
# large: optimal CE = 22.3 V (n=47)
# small: optimal CE = 28.7 V (n=123)
```

**Files:** NEW `OptimizationMetadata.h`, `DeconvolvedSpectrum.h/.cpp`

---

## Backwards Compatibility

| Mode | Risk | Key Concern |
|------|------|-------------|
| Standard DDA | Low | ProcessScan + GetNextScanCommand replace old flow |
| Deep/Inclusion/Exclusion | Low | C++ internal |
| MS2 Tagging | Medium | Absorbed into ProcessScan |
| Conditional MS2 | Medium | Follow-ups in C++ |
| Isobaric Quant | Medium | isDifferentiallyAbundant internal |
| MS3 (all modes) | Medium | Fragment selection via queue |
| FAIMS (multi-CV) | **High** | CV state machine in C++ |
| Test mode | Low | Old wrappers during migration |

---

## Phased Migration

### Phase 1: C++ Foundation (Build #1)

ProcessScan stub, GetNextScanCommand with queue, JSON constructor, OptimizationMetadata, TRACK logging.

**C++:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, NEW `OptimizationMetadata.h`, `DeconvolvedSpectrum.h/.cpp`
**C#:** `FLASHIdaWrapper.cs`, `Parameter.cs` (ToJSON), `ScanFactory.cs` (BuildFromCommand)
**Scope:** L

### Phase 2: C# Simplification (no C++ build)

UnifiedScanProcessor, simplified DataPipe, feature-flagged.

**C#:** NEW `UnifiedScanProcessor.cs`, `IScanProcessor.cs`, `DataPipe.cs`, `Flash.cs`, `MethodConfig.cs`
**Scope:** M

### Phase 3: Wire All Modes + Eliminate Quant (batched with Build #1)

ProcessScan handles all MS1+MS2 modes. QuantScanProcessor deleted.

**C++:** `FLASHIda.cpp` full routing
**C#:** Delete `QuantScanProcessor.cs`
**Scope:** L

### Phase 4: FAIMS Absorption (Build #2, highest risk)

FAIMS CV cycling in C++. FAIMSScanProcessor eliminated. ScanScheduler deleted.

**C++:** `FLASHIda.h/.cpp` — CV state machine
**C#:** Delete `FAIMSScanProcessor.cs`, `ScanScheduler.cs`
**Scope:** M

### Phase 5: Exploration Engine (batched with Build #2)

MSn-generalized parameter optimization.

**C++:** `FLASHIda.h/.cpp` — ExplorationGroup, variant tracking, scoring
**Scope:** L

### Phase 6: Cleanup (Build #3)

Remove 12+ old bridge exports, dead C# code. NEW `MethodDocGenerator.cs`.

**Scope:** M

### Build Batching

| Build | Phases |
|-------|--------|
| Build 1 | Phase 1 + 3 |
| Build 2 | Phase 4 + 5 |
| Build 3 | Phase 6 |

---

## Design Invariants

1. **C++ owns the queue.** `GetNextScanCommand` returns one command.
2. **`ProcessScan`** is the only input. **`GetNextScanCommand`** is the only output.
3. **JSON config** carries full method.xml to C++.
4. **AGC/MS1** generated by C++ — no pre-built scans in C#.
5. **4 priority levels:** 0-3.
6. **OptimizationMetadata on DeconvolvedSpectrum**, serialized via `setMetaValue`.
7. **TRACK-CREATE/RESOLVE/EXPIRE** audit trail.
8. **Thread safety:** `queue_mutex_` protects ProcessScan (TPL) + GetNextScanCommand (instrument).
9. **Old bridge functions survive through Phase 5.**
10. **ScanScheduler eliminated** in Phase 4.

# Parameter Optimization Plan — v7

**Date:** 2026-03-20
**Revision:** 7
**Design principle:** Two operational bridge functions (`ProcessScan`, `GetAndClearPendingCommands`). C++ owns all decisions. C# is a stateless relay. MSn-generalized exploration. Decoupled metadata. Unified configuration via constructor string.

---

## Issue 1 — Unified ProcessScan Bridge

### Desired behaviour
A single C++ entry point handles all MSn levels. C# passes spectrum data + scan description. C++ resolves all context from its internal tracking state. Every tracking ID and its associated properties are logged for audit.

### Limitations of current design
~20 specialized bridge functions. C# orchestrates multi-step call sequences. Precursor/fragmentation parameters scattered between sides. No audit trail for scan tracking.

### Proposed change

**Bridge signature:**
```cpp
extern "C" OPENMS_DLLAPI int ProcessScan(
    FLASHIda* obj,
    double* mzs, double* ints, int length,
    double rt_min, int ms_level,
    const char* scan_description);
```

Returns number of commands pushed. C++ resolves everything from the 4-char tracking ID in `scan_description` via `pending_scan_map_`.

**Tracking ID system:**

C++ owns a single atomic counter. IDs are encoded as 4-char base-36 strings (36^4 = 1.6M unique per run).

```cpp
// C++ encode: int → base-36
static std::string toBase36(int id) {
    static const char d[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    std::string s(4, '0');
    for (int i = 3; i >= 0; --i) { s[i] = d[id % 36]; id /= 36; }
    return s;
}
// C++ decode: base-36 → int
static int parseBase36(const char* s) {
    int v = 0;
    for (int i = 0; i < 4; ++i) {
        char c = s[i];
        v = v * 36 + ((c >= '0' && c <= '9') ? (c - '0') : (c - 'a' + 10));
    }
    return v;
}
```

C# needs a `ToBase36` helper for MS1/AGC fallback scans:
```csharp
static string ToBase36(int id) {
    const string d = "0123456789abcdefghijklmnopqrstuvwxyz";
    char[] r = new char[4];
    for (int i = 3; i >= 0; i--) { r[i] = d[id % 36]; id /= 36; }
    return new string(r);
}
```

**Lifecycle:**
1. C++ generates int ID (atomic++) → converts to base-36 → embeds in `ScanCommand.scan_description`
2. C# receives ScanCommand, builds Thermo scan with description as-is
3. Instrument echoes description back in scan trailer
4. C# reads trailer → passes to ProcessScan
5. C++ parses base-36 → looks up `pending_scan_map_[id]`

For MS1/AGC fallbacks created by C#: C# calls `GetNextTrackingId()` (returns int) → converts via `ToBase36` → stamps on pre-built scan.

**Audit logging** (in C++ ProcessScan):
```
[TRACK-CREATE] id=0a1b int=36891 mass=14037.90 z=19 mz=740.52 iso=2.0 CE=25 HCD mode=std
[TRACK-RESOLVE] id=0a1b int=36891 mass=14037.90 z=19 peaks=12 score=0.87
[TRACK-EXPIRE] id=0a1b int=36891 age_ms=30000
```

Optional `DumpPendingScanMap` bridge function behind method.xml debug flag for deep diagnostics.

**Scan description format:** `TTTT <human content>` (no prefix, no machine tag)

| Scan | Example | Chars |
|------|---------|-------|
| MS2 HCD | `0a1b 14038 19+ HCD` | 19 |
| MS3 | `0a1c MS3 b12 3547 5+` | 21 |
| Exploration | `0a1d OPT 14038 19+ CE25` | 25 |
| MS1 | `0a1e MS1` | 8 |
| AGC | (magic ID 41, no description) | 0 |

**Functions eliminated** (replaced by ProcessScan + command channel):
`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, `GetBestMS2Masses`, `GetTopFragmentMatches`, `GetAmbiguityEnclosingIons`, `GetTerminalFragmentIons`, `HasMS2Deconvolution`, `GetMS2PeakGroupCount`, `ClearMS2Deconvolution`, `ProcessMS2ForTagBasedTargeting`, `IsDifferentiallyAbundant`

**Files:** `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIda.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 2 — Command Channel with Atomic Drain

### Desired behaviour
C++ pushes MSn scan commands (up to MS10) via a single queue. C# drains atomically. Multiple priority levels (0-3) control dequeue order.

### Limitations of current design
No command channel exists. C++ returns data via separate query functions.

### Proposed change

```cpp
const int MAX_ISOLATION_STAGES = 10;

struct IsolationStage {
    double precursor_mz, isolation_width;
    int collision_energy, charge;
    char activation_type[16];
    double first_mass, last_mass;
    double reaction_time, reagent_max_it;
    int reagent_agc_target;
};

struct ScanCommand {
    int msn_level;                              // 1-10
    int num_isolation_stages;                   // msn_level - 1
    IsolationStage stages[MAX_ISOLATION_STAGES];
    double max_it;
    int agc_target, orbitrap_resolution;
    char analyzer[32];
    double faims_cv;
    char scan_description[256];
    int priority;                               // 0=background, 1=normal, 2=high, 3=urgent
    uint64_t enqueue_timestamp_ms;
    int is_agc;
};
```

C++ zero-initializes. C# reads only `stages[0..num_isolation_stages-1]`. Validation: `msn_level == num_isolation_stages + 1`.

**Atomic drain:**
```cpp
extern "C" OPENMS_DLLAPI int GetAndClearPendingCommands(
    FLASHIda* obj, int max_count, ScanCommand* commands);
```

**Files:** `FLASHIda.h/.cpp`, `FLASHIdaBridgeFunctions.h/.cpp`, `FLASHIdaWrapper.cs`

---

## Issue 3 — ScanScheduler: Priority Queues, Timeout, AGC/MS1 Bypass

### Desired behaviour
4 priority levels (0=background, 1=normal, 2=high, 3=urgent). AGC and MS1 scans bypass the queue (returned directly when due). AGC scans are pre-built at startup. Stale scans dropped via `enqueue_timestamp_ms`. Configurable cycle time.

### Limitations of current design
Single FIFO ConcurrentQueue. No priority. No timeout. AGC only fires when queue empties.

### Proposed change

**4 queues** (one per priority level), implemented as `LinkedList<IFusionCustomScan>` + shared `lock(sync)`. Dequeue from highest non-empty first.

**AGC and default MS1 remain pre-built in C#** (static parameters, never change during a run). AGC uses magic ID 41 — no tracking ID consumed. FAIMS per-CV AGC/MS1 also pre-built at startup.

**Hybrid model:** C++ pushes MS2/MS3/exploration/FAIMS-targeted commands. C# keeps pre-built AGC/MS1 for bypass and empty-queue fallback.

**`getNextScan()` flow:**

```
getNextScan()
│
▼
┌─[lock(sync)]──────────────────────────────────────────┐
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

**Method XML** (under `<MSSettings>`):
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
C++ autonomously manages parameter exploration at ANY MSn level. MS2 exploration winner triggers MS3 exploration (if configured). MS3 winner can trigger MS4. Recursive, depth-limited. C# is not involved.

### Limitations of current design
No exploration concept. No comparative scoring across variants. No MSn chaining.

### Proposed change

**MSn-aware data structures:**

```cpp
struct ExplorationVariant {
    int msn_level;
    double precursor_mz, precursor_mass;
    int precursor_charge;
    int parent_tracking_id;       // references parent MSn scan
    double collision_energy, isolation_width;
    std::string activation_type;
    DeconvolvedSpectrum deconv_result;
    double quality_score = -1;
    bool received = false;
};

struct ExplorationGroup {
    int group_id;
    int msn_level;                // which level is being explored
    int parent_tracking_id;       // tracking ID of parent scan
    double target_mass;
    int target_charge;
    std::vector<ExplorationVariant> variants;
    int received_count = 0;
    uint64_t creation_time_ms;
};
```

**Recursive lifecycle:**
1. MS1 → ProcessScan → create MS2 ExplorationGroup → push MS2 variant commands (priority 1)
2. MS2 variants return → score → pick winner → push priority MS2 winner (priority 2)
3. If `MS3Exploration.Enabled` && `TriggerAfterMS2Winner`: select top fragments from winner deconv → create MS3 ExplorationGroups → push MS3 variant commands (priority 1)
4. MS3 variants return → score → pick MS3 winner → push priority MS3 winner (priority 2)
5. Repeat for MS4 if configured (limited by `MaxExplorationDepth`)

**Recognition:** When ProcessScan receives an MSn result, it parses the tracking ID → looks up `pending_scan_map_[id]` → if `exploration_group_id > 0`, routes to `feedExplorationResult_()`. All handled internally in C++.

**Error handling:**
- Missing/corrupt description → standard mode fallback
- Group not found → log + standard processing
- Timeout → evaluate with partial results

**Scoring at untrained MSn levels:** If QScore weight vectors only exist for MS1/MS2, MS3+ exploration falls back to intensity-only ranking with a logged warning.

**Config:**
```xml
<ParameterOptimization>
  <Active>False</Active>
  <ScanLimits>
    <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
    <MaxQueueForExploration>50</MaxQueueForExploration>
    <MaxExplorationDepth>2</MaxExplorationDepth>
  </ScanLimits>
  <MS2Exploration>
    <Enabled>true</Enabled>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>20</Min><Max>40</Max><Step>5</Step><Activation>HCD</Activation>
    </CollisionEnergyOptimization>
    <!-- IsolationWidth, ReactionTime, ActivationType optimization sub-sections -->
  </MS2Exploration>
  <MS3Exploration>
    <Enabled>false</Enabled>
    <TriggerAfterMS2Winner>true</TriggerAfterMS2Winner>
    <MaxFragmentsToExplore>3</MaxFragmentsToExplore>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>15</Min><Max>35</Max><Step>5</Step><Activation>CID</Activation>
    </CollisionEnergyOptimization>
  </MS3Exploration>
  <Scoring>
    <MetricType>FragmentationQuality</MetricType>
  </Scoring>
</ParameterOptimization>
```

**Files:** `FLASHIda.h/.cpp`

---

## Issue 5 — MSn-Aware Fragmentation Quality Scoring

### Desired behaviour
Score fragmentation quality at any MSn level. Use level-appropriate weight vectors when available. Fall back to intensity-only ranking when trained weights don't exist for a given level.

### Limitations of current design
`PeakGroupScoring::getQscore()` uses MS1-trained logistic regression weights. No MS2/MS3 weight vectors exist. The 5-feature vector (isotope cosine, charge SNR, etc.) is MS-level-agnostic, but the trained model is not.

### Proposed change

```cpp
static double scoreFragmentationQuality(
    const DeconvolvedSpectrum& deconv,
    double precursor_mass, int precursor_charge,
    int ms_level);
```

**Level dispatch:**
- `ms_level == 1`: use existing `weight_` vector (MS1-trained)
- `ms_level == 2`: use `weight_ms2_` if trained, else fall back to weighted fragment count + TIC coverage
- `ms_level >= 3`: intensity-only ranking (sum of qScore-weighted peak intensities / TIC). Log warning: "MS3+ scoring using intensity fallback — no trained weights available"

**Future:** Train dedicated weight vectors for MS2 and MS3 using labeled fragmentation data.

**Spectrum annotation:** ProcessScan sets CE, isolation window, activation type on the `Precursor` object via `pending_scan_map_` lookup before deconvolution. The scorer accesses these via `deconv.getOriginalSpectrum().getPrecursors()[0]`.

**Files:** `PeakGroupScoring.h/.cpp`, `FLASHIda.cpp`

---

## Issue 6 — Unified C# Scan Processor

### Desired behaviour
One `IScanProcessor` handles ALL modes: DDA, inclusion, exclusion, deep, tagging, conditional MS2, MS3, quant, FAIMS, exploration. ~50 lines. All mode decisions in C++.

### Limitations of current design
Three separate processors (~1200 lines total). Duplicated spectrum extraction. Mode-specific routing in C#.

### Proposed change

```csharp
public class UnifiedScanProcessor : IScanProcessor
{
    public IEnumerable<IFusionCustomScan> ProcessMS(IMsScan msScan)
    {
        var scans = new List<IFusionCustomScan>();
        if (msScan.Header["MassAnalyzer"] != "FTMS") return scans;

        double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
        double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();
        double rt = double.Parse(msScan.Header["StartTime"]);
        int msLevel = int.Parse(msScan.Header["MSOrder"]);
        msScan.Trailer.TryGetValue("Scan Description", out var scanDesc);

        int cmdCount = wrapper.ProcessScan(mzs, ints, mzs.Length, rt, msLevel, scanDesc ?? "");

        if (cmdCount > 0)
        {
            var commands = wrapper.DrainPendingCommands(cmdCount);
            foreach (var cmd in commands)
                scans.Add(BuildScanFromCommand(cmd));
        }

        if (msLevel == 1) scans.Add(null);
        return scans;
    }

    public void OutputMS(IFusionCustomScan scan)
    {
        if (scan == null) scanScheduler.AddDefault();
        else scanScheduler.AddScan(scan, scan.Priority);
    }
}
```

`Flash.cs` simplified: `flashIDAProcessor = new UnifiedScanProcessor(...)`.

**QuantScanProcessor** eliminated — `IsDifferentiallyAbundant` called internally by C++.
**FAIMSScanProcessor** eliminated — FAIMS CV cycling and commands handled by C++.

**Files:** `IDAScanProcessor.cs` (rewritten), `Flash.cs`

---

## Issue 7 — P/Invoke Declarations

### Desired behaviour
Minimal bridge surface supporting MSn. Multiple priority levels. No per-mode config setters — all config through constructor.

### Limitations of current design
~20 bridge functions. Priority is binary (0/1). Separate config setters proposed.

### Proposed change

**Core bridge (4 functions):**
```csharp
[DllImport(dllName)] static extern IntPtr CreateFLASHIda(string arg);
[DllImport(dllName)] static extern void DisposeFLASHIda(IntPtr ptr);
[DllImport(dllName)] static extern int ProcessScan(IntPtr ptr,
    double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc);
[DllImport(dllName)] static extern int GetAndClearPendingCommands(IntPtr ptr,
    int maxCount, [Out] ScanCommand[] commands);
```

**Utility (2 functions):**
```csharp
[DllImport(dllName)] static extern int GetNextTrackingId(IntPtr ptr);
[DllImport(dllName)] static extern int DumpPendingScanMap(IntPtr ptr,
    [Out] byte[] buffer, int maxLength);  // debug only
```

**No separate config setters.** All configuration (quant params, FAIMS CVs, exploration config, priority defaults) flows through the `CreateFLASHIda(char* arg)` constructor string. The existing `IDAParameters.ToFLASHDeconvInput()` is extended with new tokens.

**ScanCommand.priority supports 4 levels:** 0=background, 1=normal, 2=high, 3=urgent.

**MSn support:** `stages[10]` + `msn_level` up to 10 already in the struct.

**C# struct unpacking:**
```csharp
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct IsolationStage { /* mirrors C++ */ }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct ScanCommand {
    public int msn_level, num_isolation_stages;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)]
    public IsolationStage[] stages;
    // ... remaining fields ...
}
```

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 8 — Configuration (NEW — separated from Issue 7)

### Desired behaviour
One unified configuration mechanism. All mode parameters (quant, FAIMS, exploration, scoring, targeting) pass through a single config string at construction time.

### Limitations of current design
`CreateFLASHIda(char* arg)` already receives a space-delimited key-value string from `IDAParameters.ToFLASHDeconvInput()`. But new parameters (quant reporter_mz_tol, FAIMS CVs, exploration depth) would need to be added to this string. The format is fragile (strtok-based parsing, no nesting, no escaping).

### Proposed change

**Immediate (v7):** Extend `ToFLASHDeconvInput()` with new tokens:
```
... existing tokens ...
-quant_enabled 1 -reporter_mz_tol 0.002 -fold_change_threshold 1.4 -only_one_condition 0
-faims_cvs -50,-40,-30 -max_cv_skip 4 -cv_mass_threshold 3
-exploration_enabled 0 -max_exploration_depth 1 -max_variants 5
```

C++ parser extended to handle these in the constructor.

**Future (separate tracked issue):** Migrate to JSON config string using bundled `nlohmann_json`. Enables nesting, arrays, and proper escaping:
```json
{"min_charge":1,"max_charge":100,"quant":{"enabled":true,"reporter_mz_tol":0.002},...}
```

**Method XML auto-documentation:** All `MethodConfig.cs` classes annotated with `[Description("...")]` (pre-existing .NET attribute). A NEW ~30-line reflection utility generates Markdown documentation.

```csharp
[Description("Minimum precursor charge state")]
public int MinCharge = 4;
```

Generator walks config classes via `typeof(T).GetFields()`, reads `[Description]`, outputs Markdown. Uses same reflection pattern as `ScanFactory.FillParameters()`.

**Files:** `Parameter.cs`, `MethodConfig.cs`, `MethodParameters.cs`, NEW `MethodDocGenerator.cs`, `FLASHIda.cpp` (constructor parser)

---

## Issue 9 — Acquisition Metadata (Decoupled OptimizationMetadata)

### Desired behaviour
Optimization metadata is decoupled from the core PeakGroup struct using a separate `OptimizationMetadata` class, optionally attached. Zero overhead when optimization is disabled.

### Limitations of current design
PeakGroup is a lightweight struct with no metadata infrastructure. It does not inherit from `MetaInfoInterface` (OpenMS's key-value metadata system used by `Feature`, `SpectrumSettings`, etc.).

### Proposed change

**Approach: Separate struct with `std::optional` attachment.**

OpenMS has `MetaInfoInterface` (string-keyed, `DataValue`-typed) used throughout the library. However, for optimization metadata that is **structured** and **typed**, a dedicated struct is better than string-based key-value pairs.

**NEW `OptimizationMetadata.h`:**
```cpp
struct OptimizationMetadata {
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
    double reaction_time_ms = 0;
    double precursor_mass = 0;
    int precursor_charge = 0;

    // Quality
    double fragmentation_quality_score = -1;
    double variant_score_rank = -1;
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
class PeakGroup {
    // existing members...
    std::optional<OptimizationMetadata> opt_metadata_;
public:
    OptimizationMetadata& getOrCreateOptimizationMetadata();
    const OptimizationMetadata* getOptimizationMetadata() const;
    bool hasOptimizationMetadata() const { return opt_metadata_.has_value(); }
};
```

**Why not MetaInfoInterface directly?**
- PeakGroup is used in tight loops — string-based lookup adds overhead
- Optimization fields are structured and predictable — typed struct is safer
- MetaInfoInterface is better for unstructured, variable metadata

**Why not direct member fields?**
- 24+ fields on every PeakGroup wastes memory when optimization is off
- Tight coupling between deconvolution result and acquisition optimization
- `std::optional` costs ~0 bytes until metadata is created

**Files:** NEW `OptimizationMetadata.h`, `PeakGroup.h/.cpp`

---

## Backwards Compatibility

| Mode | Risk | Key Concern |
|------|------|-------------|
| Standard DDA | Low | ProcessScan replaces old calls 1:1 |
| Deep/Inclusion/Exclusion | Low | C++ internal, no C# change |
| MS2 Tagging | Medium | Tag detection absorbed into ProcessScan |
| Conditional MS2 | Medium | Follow-up decisions move to C++ |
| Isobaric Quant | Medium | IsDifferentiallyAbundant called internally |
| MS3 (all modes) | Medium | Fragment selection via command channel |
| FAIMS (multi-CV) | **High** | CV state machine moves to C++ |
| Test mode | Low | Old functions kept as wrappers during migration |

---

## Phased Migration

### Phase 1: Tracking + Metadata Foundation (C++ build #1)

**Goal:** Add tracking ID system, audit logging, OptimizationMetadata struct, ProcessScan stub.

**C++ changes:**
- `FLASHIda.h/.cpp` — atomic tracking counter, `pending_scan_map_`, base36 utilities, `[TRACK-CREATE]`/`[TRACK-RESOLVE]` logging, `processScan()` stub (internally calls existing functions)
- `FLASHIdaBridgeFunctions.h/.cpp` — export `ProcessScan`, `GetAndClearPendingCommands`, `GetNextTrackingId`
- NEW `OptimizationMetadata.h` — struct with fields
- `PeakGroup.h/.cpp` — add `std::optional<OptimizationMetadata>`

**C# changes:**
- `FLASHIdaWrapper.cs` — P/Invoke declarations, ScanCommand struct, `ToBase36` utility

**Verify:** `Flash.exe -t` unchanged. New functions callable. TRACK logs appear.

**Scope:** M

### Phase 2: ScanScheduler + Method XML (C# only)

**Goal:** 4 priority queues, timeout, AGC/MS1 bypass, cycle time, expanded XML.

**C# changes:**
- `ScanScheduler.cs` — LinkedList+lock × 4 priority levels, timeout via `enqueue_timestamp_ms`, AGC/MS1 bypass, cycle time
- `MethodConfig.cs` — `ScanSchedulingConfig`, `ParameterOptimizationConfig`, `[Description]` attributes
- `method.xml` — template sections

**Verify:** `Flash.exe -t` works. Priority dequeue order correct.

**Scope:** L

### Phase 3: Wire ProcessScan + Eliminate Quant (C++ build #2)

**Goal:** ProcessScan handles MS1+MS2+quant. QuantScanProcessor eliminated.

**C++ changes:**
- `FLASHIda.cpp` — `processScan()` dispatches by ms_level, routes by scan description mode. Internal `isDifferentiallyAbundant` for quant mode. MS3 fragment selection → push ScanCommands.
- Constructor parser — new config tokens (quant, FAIMS, exploration)

**C# changes:**
- NEW `UnifiedScanProcessor.cs`
- `Flash.cs` — single processor instantiation
- `Parameter.cs` — extend `ToFLASHDeconvInput()` with new tokens
- Delete `QuantScanProcessor.cs`

**Verify:** Standard DDA + quant produce identical results via unified processor.

**Scope:** L

### Phase 4: FAIMS Absorption (highest risk)

**Goal:** FAIMS CV cycling in C++. FAIMSScanProcessor eliminated.

**C++ changes:**
- `FLASHIda.h/.cpp` — CV state machine, adaptive skip, FAIMS command generation

**C# changes:**
- `ScanScheduler.cs` — remove FAIMS CV state
- Delete `FAIMSScanProcessor.cs`

**Verify:** FAIMS multi-CV: identical CV sequence and skip patterns.

**Scope:** M (**highest risk**)

### Phase 5: MSn Exploration Engine + Scoring (C++ build #3)

**Goal:** Recursive MSn exploration with quality scoring.

**C++ changes:**
- `FLASHIda.h/.cpp` — MSn-aware ExplorationGroup/Variant, recursive group creation, winner selection
- `PeakGroupScoring.cpp` — `scoreFragmentationQuality` with ms_level dispatch

**C# changes:** None (flows through existing ProcessScan + DrainCommands).

**Verify:** Exploration disabled: identical. Enabled: variant scoring visible in logs.

**Scope:** L

### Phase 6: Cleanup + Documentation

**Goal:** Remove deprecated functions, generate docs.

**C++ changes:** Remove 12 old bridge exports.

**C# changes:**
- Remove `[Obsolete]` declarations, `pendingMS2s` dict, old tracking code
- NEW `MethodDocGenerator.cs`

**Verify:** Full regression. `Flash.exe -t`.

**Scope:** M

### Build Batching

| C++ Build | Phases | Scope |
|-----------|--------|-------|
| Build 1 | Phase 1 | Foundation |
| Build 2 | Phase 3 + 4 | ProcessScan + FAIMS |
| Build 3 | Phase 5 + 6 | Exploration + cleanup |

---

## Design Invariants

1. **Two operational bridge functions:** `ProcessScan` + `GetAndClearPendingCommands`
2. **C++ resolves everything from tracking ID:** No runtime params cross the bridge except spectrum data + description
3. **Atomic command drain** with mutex
4. **AGC/MS1 bypass queue** — returned directly when due, pre-built at startup
5. **4 priority levels:** 0=background, 1=normal, 2=high, 3=urgent
6. **MSn exploration is recursive** — depth-limited by config
7. **OptimizationMetadata decoupled** from PeakGroup via `std::optional`
8. **Single config mechanism:** `CreateFLASHIda(char* arg)` extended (JSON migration deferred)
9. **Old bridge functions survive through Phase 5**
10. **Audit trail:** Every tracking ID logged on creation, resolution, and expiry

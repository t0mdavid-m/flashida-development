# Parameter Optimization Plan — v2 (C++-Driven)

**Date:** 2026-03-20
**Revision:** 2
**Design principle:** C++ owns all exploration logic. C# is a thin relay — it sends spectra in, receives scan parameters out, and queues whatever C++ tells it to.

---

## Issue 1 — C++ Exploration Session Management

### Desired behaviour
When C# encounters a precursor eligible for parameter optimization, it calls a single bridge function. C++ returns a list of scan parameter sets (CE, isolation width, etc.) that C# should queue. As each exploration MS2 result comes back, C# feeds the raw spectrum to C++ via another bridge function. C++ internally tracks progress, and when all variants are collected, the next call returns the final optimized scan parameters. C# never decides what variants to try, never tracks group membership, and never picks the winner.

### Limitations of current design
The existing bridge API is request-response with no session concept. `GetIsolationWindows` returns precursor targets after MS1 deconvolution; `DeconvolveMS2` processes a single MS2. There is no way to: (a) ask C++ "what parameter variants should I try for this precursor?", (b) feed multiple MS2 results back for comparison, or (c) ask C++ "is the group complete and what won?". All multi-scan coordination would have to live in C#.

### Proposed change
Add three new methods to `FLASHIda` and corresponding bridge functions:

| Bridge function | C++ method | Purpose |
|-----------------|------------|---------|
| `GetExplorationScans(ptr, mass, charge, isolationMz, outCount, outCEs, outIsoWidths)` | `getExplorationScans()` | C++ generates the parameter grid for this precursor. Returns N parameter sets as flat arrays. C# blindly builds one scan per set. |
| `FeedExplorationResult(ptr, groupId, variantIndex, mzs, ints, length, rt)` | `feedExplorationResult()` | C# sends a raw MS2 spectrum. C++ deconvolves it internally, stores the quality metric, and updates the group's received count. Returns a status flag: `0` = more results expected, `1` = group complete. |
| `GetOptimizedScanParams(ptr, groupId, outCE, outIsoWidth, outIsoCenter, outCharge)` | `getOptimizedScanParams()` | Called only after `FeedExplorationResult` returns `1`. C++ returns the single best parameter set. C# builds and queues the final production scan. |

Internal C++ state (all private to `FLASHIda`, invisible to C#):

```cpp
struct ExplorationVariant
{
  double collision_energy;
  double isolation_width;
  DeconvolvedSpectrum deconv_result;  // filled when result arrives
  double quality_score = -1;          // computed after deconvolution
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
  bool complete = false;
};

// In FLASHIda:
std::unordered_map<int, ExplorationGroup> exploration_groups_;
int next_exploration_group_id_ = 0;
```

The existing `ms2_deconvolved_spectrum_` / `ms2_deconv_valid_` state is **untouched**. Exploration uses its own `DeconvolvedSpectrum` per variant inside `ExplorationGroup`.

**Files:** `FLASHIda.h`, `FLASHIda.cpp`, `FLASHIdaBridgeFunctions.h`, `FLASHIdaBridgeFunctions.cpp`

---

## Issue 2 — Fragmentation Quality Scoring

### Desired behaviour
C++ can score an MS2 spectrum's fragmentation quality — not just count deconvolved masses, but assess how useful the fragmentation is for identification. This score is what `FeedExplorationResult` uses internally to rank variants.

### Limitations of current design
`PeakGroupScoring` scores individual MS1 peak groups (qScore = charge fit + isotope fit + intensity). There is no metric for MS2 spectral quality that captures fragment coverage, signal distribution, or sequence information content. `DeconvolveMS2` returns peak group count, but count alone is a poor proxy — 10 low-quality fragments may be worse than 5 high-quality ones.

### Proposed change
Add a static scoring function (in `PeakGroupScoring` or a new utility):

```cpp
static double scoreFragmentationQuality(const DeconvolvedSpectrum& deconv_ms2,
                                         double precursor_mass,
                                         int precursor_charge);
```

The score combines:
1. **Weighted fragment count** — number of peak groups above a qScore threshold, weighted by their individual qScores.
2. **Intensity coverage** — fraction of total ion current explained by deconvolved peaks.
3. **Mass spread** — how well fragments cover the precursor mass range (ratio of observed mass range to theoretical).

Returns a single `double` in [0, 1]. This is what gets stored in `ExplorationVariant::quality_score` and used by `GetOptimizedScanParams` to pick the winner.

**Files:** `PeakGroupScoring.h`, `PeakGroupScoring.cpp`

---

## Issue 3 — P/Invoke Declarations for New Bridge Functions

### Desired behaviour
C# can call the three new bridge functions from Issue 1.

### Limitations of current design
`FLASHIdaWrapper.cs` has ~20 `[DllImport]` declarations for existing functions. No declarations exist for exploration-related functions.

### Proposed change
Add three new `[DllImport]` entries and thin public wrappers:

```csharp
[DllImport(dllName)]
static private extern int GetExplorationScans(
    IntPtr ptr, double mass, int charge, double isolationMz,
    double[] outCEs, double[] outIsoWidths, int maxVariants);

[DllImport(dllName)]
static private extern int FeedExplorationResult(
    IntPtr ptr, int groupId, int variantIndex,
    double[] mzs, double[] ints, int length, double rt);

[DllImport(dllName)]
static private extern void GetOptimizedScanParams(
    IntPtr ptr, int groupId,
    out double outCE, out double outIsoWidth,
    out double outIsoCenter, out int outCharge);
```

Public wrappers handle marshalling and null-check `m_pNativeObject`. Existing declarations are untouched.

**Files:** `FLASHIdaWrapper.cs`

---

## Issue 4 — Exploration Routing in IDAScanProcessor

### Desired behaviour
`IDAScanProcessor.ProcessMS()` has a new code path for parameter optimization. On MS1: for eligible precursors, it calls `GetExplorationScans` and queues the returned variants. On MS2: if the scan belongs to an exploration group, it feeds the spectrum to `FeedExplorationResult` and, if complete, calls `GetOptimizedScanParams` to build the final scan. C# logic is minimal — it delegates all decisions to C++.

### Limitations of current design
`ProcessMS()` for MS1 creates MS2 scans directly from `GetIsolationWindows` output. For MS2, it routes based on the `_` prefix in scan descriptions. There is no branching for exploration scans and no mechanism to distinguish exploration results from standard tracked results.

### Proposed change

**MS1 path** — after the existing precursor loop, for precursors flagged for optimization:

```csharp
// C++ decides what to try — C# just queues
int variantCount = wrapper.GetExplorationScans(
    mass, charge, isolationMz, outCEs, outIsoWidths, MAX_VARIANTS);

for (int v = 0; v < variantCount; v++)
{
    var scan = ScanFactory.CreateMS2Scan(isolationMz, outIsoWidths[v], outCEs[v], charge);
    scan.Values["ScanDescription"] = $"~{groupId}|{v}";  // ~ prefix = exploration
    scans.Add(scan);
}
```

**MS2 path** — new branch before the existing `_` prefix handler:

```csharp
if (scanDesc != null && scanDesc.StartsWith("~") &&
    TryExtractExplorationIds(scanDesc, out int groupId, out int variantIndex))
{
    int status = wrapper.FeedExplorationResult(groupId, variantIndex, mzs, ints, length, rt);
    if (status == 1) // C++ says group is complete
    {
        wrapper.GetOptimizedScanParams(groupId, out double ce, out double isoWidth,
                                        out double isoCenter, out int charge);
        var finalScan = ScanFactory.CreateMS2Scan(isoCenter, isoWidth, ce, charge);
        scans.Add(finalScan);
    }
    // else: return empty, instrument keeps cycling
}
```

The existing `_` prefix path is untouched. `FAIMSScanProcessor` and `QuantScanProcessor` are untouched (they never see `~` prefixes).

**Files:** `IDAScanProcessor.cs`

---

## Issue 5 — Method XML Configuration

### Desired behaviour
Parameter optimization is controlled by the method XML. When absent or disabled, the entire feature is invisible — no new objects created, no new bridge functions called, exact same code path as before.

### Limitations of current design
No configuration section exists for parameter optimization. Without a flag, the new code path cannot be conditionally enabled.

### Proposed change
Add to the method XML schema:

```xml
<ParameterOptimization Active="false">
  <CollisionEnergy Min="20" Max="40" Step="5" />
  <IsolationWidth Values="1.0,2.0,4.0" />
  <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
</ParameterOptimization>
```

Parsed in `MethodConfig.cs` into a typed object. This config is passed to C++ via the constructor argument string (same mechanism as existing parameters — `FLASHIda(char* arg)` already parses a parameter string). C++ uses it to generate the exploration grid in `getExplorationScans()`.

C# only checks `Active` to decide whether to enter the exploration path in Issue 4. All parameter grid logic lives in C++.

**Files:** `MethodConfig.cs`, `Parameter.cs`, `method.xml` (template)

---

## Issue 6 — Acquisition Metadata on PeakGroup (Optional, Deferred)

### Desired behaviour
After optimization, the system records which parameters were chosen and the comparative scores, enabling downstream analysis.

### Limitations of current design
`PeakGroup` has no fields for acquisition parameters or optimization metadata.

### Proposed change
Add optional fields to `PeakGroup`:

```cpp
double optimal_collision_energy_ = 0;
double optimal_isolation_width_ = 0;
double exploration_quality_score_ = 0;
int exploration_variant_count_ = 0;
```

Populated only when exploration is active; default to zero otherwise. Existing serialization ignores zero-valued fields.

**Files:** `PeakGroup.h`

---

## Dependency Graph

```
Issue 5 (method config)  ── no deps, can land first
Issue 2 (scoring)        ── no deps
Issue 1 (C++ session)    ── depends on Issue 2, Issue 5
Issue 3 (P/Invoke)       ── depends on Issue 1
Issue 4 (C# routing)     ── depends on Issues 1, 3, 5
Issue 6 (metadata)       ── no deps, optional/deferred
```

## Design Invariants

1. **If `ParameterOptimization` is absent or `Active=false`**: zero new objects created, zero new bridge calls made, zero new scan prefixes emitted. Code path is byte-for-byte identical to today.
2. **Existing bridge functions are never modified**: `DeconvolveMS2`, `GetBestMS2Masses`, `ClearMS2Deconvolution`, `GetIsolationWindows`, etc. — all signatures and behavior unchanged.
3. **Existing scan routing is never modified**: `_` prefix handling, MS3, conditional MS2, tag-based targeting — all untouched.
4. **C# never decides**: what parameter variants to try, when exploration is complete, or which variant won. It calls C++ and follows instructions.
5. **No interface changes**: `IScanProcessor`, `DataPipe`, `ScanScheduler`, `Flash.cs` — all unchanged.

## What Each Existing Mode Gets

| Mode | Impact |
|------|--------|
| Normal IDA | None — optimization flag off |
| Deep mode | None — targeting is orthogonal |
| Inclusion/Exclusion | None — precursor selection unchanged |
| FAIMS CV cycling | None — `FAIMSScanProcessor` untouched |
| Isobaric quantification | None — `QuantScanProcessor` untouched |
| Conditional MS2 | None — `_` prefix path untouched |
| MS3 characterization | None — `DeconvolveMS2` + related functions untouched |
| Tag-based targeting | None — `ProcessMS2ForTagBasedTargeting` untouched |
| Test mode (-t) | None — `FLASHIdaWrapper.Main()` unchanged |

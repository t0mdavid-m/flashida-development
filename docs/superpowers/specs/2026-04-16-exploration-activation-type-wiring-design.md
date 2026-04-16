# Wire Activation Type Into Fragment Matching

## Goal

Replace all hardcoded `"HCD"` in fragment matching and tag generation calls with the actual activation type of the scan being analyzed, so that ETD spectra are searched with `{c, z}` ions, EThcD with `{b, c, y, z}`, etc.

## Background

`FragmentAnalysis` already supports dynamic ion type selection via a `fragmentation_method` parameter on all public methods. The mapping (`getIonTypesForFragmentationMethod`) converts method names to ion types:

| Method | Ion Types |
|--------|-----------|
| HCD / CID | `{b, y}` |
| ETD | `{c, z}` |
| EThcD / EtCID | `{b, c, y, z}` |
| UVPD | `{a, b, c, x, y, z}` |

The activation type is also already tracked per exploration variant (`ExplorationVariant.activation_type`) and stored in scan commands (`IsolationStage.activation_type`). The data exists everywhere it's needed -- it's just not passed through the last mile to `FragmentAnalysis`.

### Call sites in scope

| # | File | Function | Line | Calls | Current behavior |
|---|------|----------|------|-------|------------------|
| 1 | `Exploration.cpp` | `initiateNextLevel` | 479 | `getTopFragmentMatches` | No `fragmentation_method` passed (defaults to `"HCD"`) |
| 2 | `Exploration.cpp` | `initiateNextLevel` | 485 | `getTerminalFragmentIons` | Same |
| 3 | `Exploration.cpp` | `initiateNextLevel` | 491 | `getAmbiguityEnclosingIons` | Same |
| 4 | `Exploration.cpp` | `computeFragmentMatch_` | 715 | `getTopFragmentMatches` | Hardcoded `"HCD"` |
| 5 | `PrecursorSelection.cpp` | `processMS2ForTagBasedTargeting` | 927-931 | `FLASHTaggerAlgorithm` | Does not set `ion_type` param (uses tagger default) |

### Out of scope

- Py variants (`getTopFragmentMatchesPy`, `getTerminalFragmentIonsPy`, `getAmbiguityEnclosingIonsPy`) -- hardcode `"HCD"` but serve the Python API, not real-time acquisition
- `FragmentAnalysis` interface -- no changes needed, already accepts `fragmentation_method`
- C# side -- no changes needed

## Design

### FragmentAnalysis.h -- Make `getIonTypesForFragmentationMethod` public static

Currently a file-local function in `FragmentAnalysis.cpp` (lines 80-93). Promote to a public static method on `FragmentAnalysis` so other classes (`PrecursorSelection`) can reuse the mapping:

```cpp
/// Map fragmentation method name to ion type strings for FLASHTagger/FLASHExtender
static std::vector<std::string> getIonTypesForFragmentationMethod(const String& method);
```

Move the implementation from the anonymous namespace in `FragmentAnalysis.cpp` to `FragmentAnalysis::getIonTypesForFragmentationMethod`. No logic changes -- just visibility.

### PrecursorSelection.h/.cpp -- Pass activation type to tag generation

**`processMS2ForTagBasedTargeting`:** Add `const std::string& activation_type` parameter:

```cpp
// Before:
bool processMS2ForTagBasedTargeting(double precursor_mass);

// After:
bool processMS2ForTagBasedTargeting(double precursor_mass, const std::string& activation_type);
```

In the implementation (line 927-931), set ion types on the tagger:

```cpp
// Before:
FLASHTaggerAlgorithm tagger;
Param tagger_param = tagger.getDefaults();
tagger_param.setValue("min_length", config_.targeting().min_tag_length);
tagger_param.setValue("max_length", config_.targeting().max_tag_length);
tagger.setParameters(tagger_param);

// After:
FLASHTaggerAlgorithm tagger;
Param tagger_param = tagger.getDefaults();
tagger_param.setValue("min_length", config_.targeting().min_tag_length);
tagger_param.setValue("max_length", config_.targeting().max_tag_length);
tagger_param.setValue("ion_type", FragmentAnalysis::getIonTypesForFragmentationMethod(activation_type));
tagger.setParameters(tagger_param);
```

### FLASHIda.h/.cpp -- Pass activation type from ScanCommand context

**`FLASHIda::processMS2ForTagBasedTargeting`** (inline in FLASHIda.h:203): Add parameter and pass through:

```cpp
// Before:
bool processMS2ForTagBasedTargeting(double precursor_mass)
{
  return selection_.processMS2ForTagBasedTargeting(precursor_mass);
}

// After:
bool processMS2ForTagBasedTargeting(double precursor_mass, const std::string& activation_type)
{
  return selection_.processMS2ForTagBasedTargeting(precursor_mass, activation_type);
}
```

**`FLASHIda.cpp:778`** (caller in processScan): Extract activation from the resolved `ScanCommand ctx` and pass it:

```cpp
// Before:
tags_found = selection_.processMS2ForTagBasedTargeting(precursor_mass);

// After:
std::string ms2_activation = (ctx.num_stages > 0)
    ? std::string(ctx.stages[0].activation_type)
    : config_.level(2).scans[0].activation;
tags_found = selection_.processMS2ForTagBasedTargeting(precursor_mass, ms2_activation);
```

### Exploration.h -- Update 2 private method signatures

**`computeFragmentMatch_`:** Add `const std::string& activation_type` parameter (no default value -- force callers to be explicit):

```cpp
// Before:
FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level) const;

// After:
FragmentMatchResult computeFragmentMatch_(const DeconvolvedSpectrum& spec, int msn_level,
                                          const std::string& activation_type) const;
```

**`computeExplorationScore_`:** Add same parameter:

```cpp
// Before:
double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
    const ExplorationGroup& group, const double* mzs, const double* ints, int length,
    double* out_remaining_ratio, FragmentMatchResult* out_frag) const;

// After:
double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
    const ExplorationGroup& group, const double* mzs, const double* ints, int length,
    double* out_remaining_ratio, FragmentMatchResult* out_frag,
    const std::string& activation_type) const;
```

### Exploration.cpp -- Update 7 call sites

**`computeFragmentMatch_` (line 715):** Replace `"HCD"` with `activation_type` parameter:

```cpp
// Before:
spec_copy, "HCD",

// After:
spec_copy, activation_type,
```

**`computeExplorationScore_` (lines 628, 632, 637, 642):** Pass `activation_type` through to all 4 `computeFragmentMatch_` calls:

```cpp
// Before:
fmr = computeFragmentMatch_(spec, group.msn_level);

// After:
fmr = computeFragmentMatch_(spec, group.msn_level, activation_type);
```

**`feedResultImpl_` (line 288):** Pass `v.activation_type` when calling `computeExplorationScore_`:

```cpp
// Before:
v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group,
    mzs, ints, length, &remaining_ratio, &frag);

// After:
v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group,
    mzs, ints, length, &remaining_ratio, &frag, v.activation_type);
```

**`initiateNextLevel` (lines 479, 485, 491):** Extract activation type from the scan command that produced this result, then pass to all three fragment matching calls:

```cpp
// Before the switch statement, extract activation type:
std::string scan_activation = (ms_ctx != nullptr)
    ? std::string(ms_ctx->stages[0].activation_type)
    : config_.level(msn_level).scans[0].activation;
```

Fallback to config when `ms_ctx` is null (defensive; in practice `ms_ctx` is always provided from `finalizeGroup_`).

Then pass as `fragmentation_method` argument to all three calls:

```cpp
found = fragments_.getTopFragmentMatches(seq, num_targets,
    masses.data(), qscores.data(), charges.data(),
    wstarts.data(), wends.data(),
    ion_types.data(), frag_indices.data(), result_copy, scan_activation);
```

Same pattern for `getTerminalFragmentIons` and `getAmbiguityEnclosingIons`.

## Files to modify

| File | Change |
|------|--------|
| `FragmentAnalysis.h` | Add `static getIonTypesForFragmentationMethod` public method declaration |
| `FragmentAnalysis.cpp` | Move function from anonymous namespace to `FragmentAnalysis::` static method |
| `PrecursorSelection.h` | Add `const std::string& activation_type` param to `processMS2ForTagBasedTargeting` |
| `PrecursorSelection.cpp` | Set `ion_type` on tagger using `FragmentAnalysis::getIonTypesForFragmentationMethod` |
| `FLASHIda.h` | Update inline `processMS2ForTagBasedTargeting` to pass activation type through |
| `FLASHIda.cpp` | Extract activation from `ctx` and pass to `processMS2ForTagBasedTargeting` |
| `Exploration.h` | Add `const std::string& activation_type` to `computeFragmentMatch_` and `computeExplorationScore_` signatures |
| `Exploration.cpp` | Update 2 method signatures + 7 call sites |

## Testing

### Existing test impact

All existing exploration tests configure `"activation": "HCD"`. Since `getIonTypesForFragmentationMethod("HCD")` returns `{b, y}` (same as the old hardcoded behavior), existing tests are unchanged. `processMS2ForTagBasedTargeting` is not directly unit-tested; its behavior flows through processScan integration tests which all use HCD configs.

### New tests

1. **`getIonTypesForFragmentationMethod` static method:** Verify the mapping returns correct ion types for each supported method (HCD, CID, ETD, EThcD, EtCID, UVPD) and the default fallback.

2. **Activation type passthrough in exploration scoring:** Create an exploration group with an ETD variant. Verify that `computeExplorationScore_` passes the activation type through to fragment matching (can be verified indirectly by checking that fragment count differs between ETD and HCD on the same spectrum, or by inspecting ion_types in match results).

3. **Activation type in `initiateNextLevel`:** Create a ScanCommand context with `activation_type = "ETD"`. Call `initiateNextLevel` and verify fragment matching output contains c/z ions rather than b/y ions.

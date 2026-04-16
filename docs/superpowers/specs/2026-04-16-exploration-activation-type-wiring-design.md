# Wire Activation Type Into Exploration Fragment Matching

## Goal

Replace all hardcoded `"HCD"` in Exploration's fragment matching calls with the actual activation type of the scan being analyzed, so that ETD spectra are searched with `{c, z}` ions, EThcD with `{b, c, y, z}`, etc.

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

All 4 are in `Exploration.cpp`:

| # | Function | Line | Calls | Current behavior |
|---|----------|------|-------|------------------|
| 1 | `initiateNextLevel` | 479 | `getTopFragmentMatches` | No `fragmentation_method` passed (defaults to `"HCD"`) |
| 2 | `initiateNextLevel` | 485 | `getTerminalFragmentIons` | Same |
| 3 | `initiateNextLevel` | 491 | `getAmbiguityEnclosingIons` | Same |
| 4 | `computeFragmentMatch_` | 715 | `getTopFragmentMatches` | Hardcoded `"HCD"` |

### Out of scope

- Py variants (`getTopFragmentMatchesPy`, `getTerminalFragmentIonsPy`, `getAmbiguityEnclosingIonsPy`) -- hardcode `"HCD"` but serve the Python API, not real-time acquisition
- `PrecursorSelection::processMS2ForTagBasedTargeting` -- calls `FLASHTaggerAlgorithm` directly without setting `ion_type`; separate concern
- `FragmentAnalysis` interface -- no changes needed, already accepts `fragmentation_method`
- C# side -- no changes needed

## Design

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
| `Exploration.h` | Add `const std::string& activation_type` to `computeFragmentMatch_` and `computeExplorationScore_` signatures |
| `Exploration.cpp` | Update 2 method signatures + 7 call sites |

## Testing

### Existing test impact

All existing exploration tests configure `"activation": "HCD"`. Since `getIonTypesForFragmentationMethod("HCD")` returns `{b, y}` (same as the old hardcoded behavior), existing tests are unchanged.

### New tests

1. **Activation type passthrough in `computeExplorationScore_`:** Create an exploration group with an ETD variant. Call `computeExplorationScore_` and verify the fragment matching uses `{c, z}` ion types (not `{b, y}`). This can be verified indirectly by checking that fragment count differs between ETD and HCD on the same spectrum, or by inspecting the ion_types in the match results.

2. **Activation type in `initiateNextLevel`:** Create a ScanCommand context with `activation_type = "ETD"`. Call `initiateNextLevel` and verify the fragment matching output contains c/z ions rather than b/y ions.

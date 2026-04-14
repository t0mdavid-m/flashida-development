# Scan Parameter Expansion — Design Spec

**Date:** 2026-04-14
**Scope:** Add per-scan control of Microscans, DataType, ScanRate, RFLens, SourceCID, SourceCIDScaling; fix FirstMass/LastMass per-level routing; make ScanCommand expandable via reserved block.

## Problem

Six scan parameters (Microscans, DataType, ScanRate, RFLens, SourceCID, SourceCIDScaling) exist in C# method configs but never reach the C++ engine. They are defined in `MethodParameters` structs, present in JSON config files, but `ToCppJson()` doesn't serialize them, `ScanConfig` doesn't store them, `ScanCommand` doesn't carry them, and `BuildFromCommand()` doesn't apply them.

Additionally, FirstMass/LastMass are in the ScanCommand struct and flow correctly for MS1, but MS2 builders hardcode MS1 values and MS3 builders inherit from the MS2 context. The per-level config values are ignored.

Finally, every ScanCommand expansion requires lockstep updates across 5 files due to the fixed-size blittable struct with a tight static_assert.

## Design Decisions

1. **Full C++ routing** — all parameters flow through `ToCppJson()` → `ScanConfig` → builder → `ScanCommand` → `BuildFromCommand()`. C++ has full per-scan control.
2. **Reserved block** — ScanCommand grows to 2048 bytes with a `reserved_[]` tail. Future fields consume from reserved space without changing the struct size or static_assert.
3. **Char arrays for string params** — `data_type[32]` and `scan_rate[32]`, consistent with `analyzer[32]`.
4. **Zero = unset** — all new fields default to zero/empty. `BuildFromCommand()` skips them with `> 0` / non-empty guards. The Thermo API inherits from the method default.
5. **FirstMass/LastMass** — MS2/MS3 builders use their own `ScanConfig` values. If not configured (0), they are not set on the ScanCommand — no MS1 fallback.

## Changes by File

### C++ ScanCommand.h

Append after `faims_cv` (offset 1240):

```
Offset 1248:  int32_t   microscans          (4)
Offset 1252:  int32_t   pad3                (4)
Offset 1256:  double    rf_lens             (8)
Offset 1264:  double    source_cid          (8)
Offset 1272:  double    source_cid_scaling  (8)
Offset 1280:  char      data_type[32]       (32)
Offset 1312:  char      scan_rate[32]       (32)
Offset 1344:  char      reserved_[704]      (704)
Offset 2048:  — end —
```

Update static_assert to 2048.

### C++ Config.h — ScanConfig struct

Add fields:

```cpp
int microscans = 0;
double rf_lens = 0;
double source_cid = 0;
double source_cid_scaling = 0;
std::string data_type;
std::string scan_rate;
```

### C++ Config.cpp — JSON parsing

Parse new keys from each MSn level's JSON object:

```cpp
scan.microscans = json.value("microscans", 0);
scan.data_type = json.value("data_type", "");
scan.scan_rate = json.value("scan_rate", "");
scan.rf_lens = json.value("rf_lens", 0.0);
scan.source_cid = json.value("source_cid", 0.0);
scan.source_cid_scaling = json.value("source_cid_scaling", 0.0);
```

Applied to MS1, MS2, and MS3 parsing loops.

### C++ ScanCommandQueue.cpp — builders

**`makeMS1()`**: Populate all new fields from `config_.level(1).scans[0]`.

**`buildMS2()`**:
- `first_mass` / `last_mass`: use `scan_config.first_mass` / `scan_config.last_mass` directly (0 if not configured — no MS1 fallback).
- `microscans`, `data_type`, `scan_rate`: from `scan_config`.
- `rf_lens`, `source_cid`, `source_cid_scaling`: from `scan_config` (typically 0 for MS2).

**`buildMS3()`**:
- `first_mass` / `last_mass`: use `ms3_config.first_mass` / `ms3_config.last_mass` directly (0 if not configured — no MS2 fallback).
- All other new fields: from `ms3_config`.

### C# FLASHIdaWrapper.cs — ScanCommand struct

Add matching fields after `FaimsCv`:

```csharp
public int Microscans;
public int Pad3;
public double RfLens;
public double SourceCid;
public double SourceCidScaling;
[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
public string DataType;
[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
public string ScanRate;
[MarshalAs(UnmanagedType.ByValArray, SizeConst = 704)]
public byte[] Reserved;
```

### C# MethodParameters.cs — ToCppJson()

Add to MS1 serialization: `microscans`, `data_type`, `scan_rate`, `rf_lens`, `source_cid`, `source_cid_scaling`.

Add to MS2/MS3 serialization: `microscans`, `data_type`, `scan_rate`, `rf_lens`, `source_cid`, `source_cid_scaling`. (Values will be 0/empty for fields not in the MS2/MS3 config — C++ ignores zeros.)

### C# ScanFactory.cs — BuildFromCommand()

Add mappings:

```csharp
if (cmd.Microscans > 0)
    p.Microscans = cmd.Microscans;

if (cmd.RfLens > 0)
    p.SrcRFLens = new double[] { cmd.RfLens };

if (cmd.SourceCid > 0)
    p.SourceCIDEnergy = cmd.SourceCid;

if (cmd.SourceCidScaling > 0)
    p.SourceCIDScalingFactor = cmd.SourceCidScaling;

if (!string.IsNullOrEmpty(cmd.DataType))
    p.DataType = cmd.DataType;

if (!string.IsNullOrEmpty(cmd.ScanRate))
    p.ScanRate = cmd.ScanRate;
```

**FirstMass/LastMass**: no change needed in `BuildFromCommand()` — the existing `> 0` guards already handle the case where the value is 0 (unset).

## Tests

### Currently passing (must remain green)

| Test | Impact | Action |
|---|---|---|
| `ScanCommandLayout_test` | Struct size changes 1248→2048, new field offsets | Update expected size, add offset checks for new fields |
| `FLASHIdaQueueTracking_test` | Uses ScanCommand but doesn't check new fields | Should pass as-is (new fields default to 0) |
| `FLASHIdaFAIMS_test` | Uses ScanCommand but doesn't check new fields | Should pass as-is |
| `DeconvolvedSpectrum_OptimizationMetadata_test` | Unrelated | No change |
| `ScanCommandQueue_Concurrent_test` | Uses builders, may check field values | Verify; may need updates if it asserts first_mass/last_mass values |
| `FragmentAnalysis_test` | Unrelated | No change |

### Currently skipped (not our concern)

| Test | Status |
|---|---|
| `FLASHIda_ProcessScan_test` | Skipped in CI, pre-existing |
| `FLASHIda_exploration_test` | Skipped in CI, pre-existing |
| `FLASHIda_Logging_test` | Skipped in CI, pre-existing |

### New tests to add

**C++ `ScanCommandLayout_test`** — extend existing test:
- Verify `sizeof(ScanCommand) == 2048`
- Verify offsets of all new fields (microscans at 1248, pad3 at 1252, rf_lens at 1256, source_cid at 1264, source_cid_scaling at 1272, data_type at 1280, scan_rate at 1312, reserved_ at 1344)

**C# `ScanCommandLayoutTests`** — extend existing test:
- Verify `Marshal.SizeOf<ScanCommand>() == 2048`
- Verify offsets of new fields match C++ layout

**C++ `ScanCommandQueue` builder tests** — extend or add:
- `makeMS1()` populates new fields from config
- `buildMS2()` uses MS2 config's first_mass/last_mass (not MS1's)
- `buildMS2()` populates microscans, data_type, scan_rate from MS2 config
- `buildMS3()` uses MS3 config's first_mass/last_mass (not MS2's)
- Zero-valued config fields → zero in ScanCommand (not inherited from another level)

**C++ Config parser test** — extend or add:
- JSON with new keys parses correctly into ScanConfig
- Missing keys default to 0/empty

## Files changed (complete list)

### C++ (OpenMS)
1. `src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h` — new fields, reserved block, static_assert
2. `src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` — ScanConfig fields
3. `src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` — JSON parsing
4. `src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` — builders
5. `src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp` — layout assertions
6. `src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp` — verify builders (if needed)

### C# (FlashIDA)
7. `src/Flash/IDA/FLASHIdaWrapper.cs` — ScanCommand struct
8. `src/Flash/MethodParameters.cs` — ToCppJson() serialization
9. `src/Flash/ScanFactory.cs` — BuildFromCommand() mapping
10. `src/Flash/Flash.Tests/ScanCommandLayoutTests.cs` — C# layout assertions

## Deployment sequence

1. Push C++ changes to `flashida-v9-bridge` → triggers `build-dlls` workflow (~40 min)
2. Download DLL artifact, commit to `FlashIDA/dll/`
3. Commit C# changes in FlashIDA
4. Update parent repo submodule pointers
5. Push parent → triggers `flashida-ci.yml`

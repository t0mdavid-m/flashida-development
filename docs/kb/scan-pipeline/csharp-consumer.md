---
title: C# Consumer — wrapper, loop entry, and ScanFactory mapping
applies_to: FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs, FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs, FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/ScanFactory.cs
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:31      # C# ScanCommand mirror struct
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:99      # P/Invoke block
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:179     # wrapper methods
  - FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:28 # wrapper.ProcessScan call site (C#→C++ input)
  - FlashIDA/src/Flash/Flash.cs:379                   # startup first MS1
  - FlashIDA/src/Flash/Flash.cs:461                   # steady-state drain loop
  - FlashIDA/src/Flash/ScanFactory.cs:57              # ScanFactory class
  - FlashIDA/src/Flash/ScanFactory.cs:102             # CreateFusionCustomScan helper
  - FlashIDA/src/Flash/ScanFactory.cs:153             # BuildFromCommand entry
  - FlashIDA/src/Flash/ScanFactory.cs:262             # BuildFromCommand terminal submit
see_also:
  - bridge-functions.md
  - scan-command.md
---

## P/Invoke layer

`FLASHIdaWrapper.cs` hosts both halves of the C# bridge:

- **Five `[DllImport]` declarations** at `FLASHIdaWrapper.cs:99-116` mirror the five `extern "C"` exports one-for-one (see [bridge-functions.md](bridge-functions.md)). The DLL name is the compile-time constant `"OpenMS.dll"`.
- **Blittable `ScanCommand` mirror struct** at `FLASHIdaWrapper.cs:31-87`. Declared twice (C++ + C#) because there is no tool that generates one from the other — the second declaration is the C# side of the byte-layout contract documented in [bridge-functions.md](bridge-functions.md). Every field is in the same order and byte size as the C++ struct.

## Wrapper methods

Thin pass-throughs at `FLASHIdaWrapper.cs:179-211`:

- `ProcessScan(double[] mzs, double[] ints, double rt, int msLevel, string scanDesc, double faimsCv = 0.0) → int` — derives `mzs.Length` internally and forwards to the DllImport overload. Wrapped in try/catch; returns `-1` on exception.
- `GetNextScanCommand(ref ScanCommand cmd) → int` — wrapped in try/catch; forwards to the DllImport. Returns `1` if `cmd` was filled, `0` if the queue is empty or on exception.
- `GetNextTrackingId() → int` — wrapped in try/catch; returns `-1` on exception. Rarely used.

## Input direction (C# → C++)

`UnifiedScanProcessor.cs:28` is the single call site that drives the input direction: on every incoming `IMsScan` from the instrument, the processor calls `wrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc ?? "", faimsCv)`. This ingests the raw spectrum into the C++ engine, which runs deconvolution/selection and enqueues resulting `ScanCommand`s.

Loop mechanics (pipeline staging, error handling, shutdown) — out of scope for this packet.

## Output direction — acquisition-loop entry

The C# drain loop has two sites, both in `Flash.cs`:

- **Startup** (`Flash.cs:379-380`): the very first MS1 is pulled via `wrapper.GetNextScanCommand(ref startupCmd2)` and submitted directly through `scanControl.SetFusionCustomScan(scanFactory.BuildFromCommand(startupCmd2))`. This kicks the instrument out of idle.
- **Steady state** (`Flash.cs:461-463`): the main loop tests `if (wrapper.GetNextScanCommand(ref cmd) == 1)` and on success calls `SendCustomScan(scanFactory.BuildFromCommand(cmd))`.

Loop mechanics (timing, backpressure, shutdown) — out of scope for this packet.

## `ScanFactory.BuildFromCommand` — the field mapping

`ScanFactory.BuildFromCommand(ScanCommand cmd) → IFusionCustomScan` at `ScanFactory.cs:153-263` is the second translation layer. It allocates a `ScanParameters`, copies relevant `ScanCommand` fields into its properties (conditionally, so zero/empty values use the method default), and terminates at `CreateFusionCustomScan(p, cmd.ScanId, delay: 0.0, IsAGC: (cmd.IsAgc != 0), AGCgroup: 1)` (`:262`).

The `ScanParameters` → Thermo custom-scan mapping elsewhere in `ScanFactory.cs` is reflection-driven (see the utility at `:130-145` that writes `ScanParameters` fields into a `scan.Values` dictionary). This is the *second* ABI contract — not a C++↔C# one, but a C#-internal name-match between `ScanCommand` property names and `ScanParameters` property names. A rename on either side fails silently.

**Field-by-field mapping** (source: `ScanCommand` field → `ScanParameters` property → note):

| ScanCommand field | ScanParameters property | Note |
| --- | --- | --- |
| `Analyzer` | `Analyzer` | Set only if non-empty. |
| `FirstMass` | `FirstMass` (as `double[]` single-element) | Also sets `ScanRangeMode = "DefineFirstMass"` or `"DefineMZRange"` depending on whether `LastMass` is set. |
| `LastMass` | `LastMass` (as `double[]` single-element) | Combined with `FirstMass` triggers `ScanRangeMode = "DefineMZRange"`. |
| `OrbitrapResolution` | `OrbitrapResolution` | Set only if `> 0`. |
| `AgcTarget` | `AGCTarget` | Set only if `> 0`. |
| `MaxIt` | `MaxIT` | Set only if `> 0`. |
| `MsnLevel` | `ScanType` | `"MSn"` if `> 1`, `"Full"` otherwise. No direct field copy — derived. |
| `Stages[i].PrecursorMz` | `PrecursorMass[]` | Per-stage arrays; entries with `> 0` appended. Valid stages: `Stages[0..Min(NumStages, 10)-1]`. |
| `Stages[i].IsolationWidth` | `IsolationWidth[]` | Append if `> 0`. |
| `Stages[i].CollisionEnergy` | `CollisionEnergy[]` (rounded to `int`) | Append if `>= 0`. |
| `Stages[i].ActivationType` | `ActivationType[]` | Append if non-empty. |
| `Stages[i].ChargeState` | `ChargeStates[]` | Append if `> 0`; clamped to `Min(25)`. |
| `Stages[i].ReactionTime` | `ReactionTime[]` | Append if `> 0`. |
| `Stages[i].ReagentMaxIt` | `ReagentMaxIT[]` | Append if `> 0`. |
| `Stages[i].ReagentAgcTarget` | `ReagentAGCTarget[]` | Append if `> 0`. |
| `ScanDescription` | `ScanDescription` | Set only if non-empty. **Carries the encoded tracking ID + annotation — critical for round-trip identification of the returning scan. Do not strip.** |
| `FaimsCv` | `FAIMS_CV` | Set if `|value| > 0.001`; also sets `FAIMS_Voltages = "on"`. |
| `Microscans` | `Microscans` | Set only if `> 0`. |
| `RfLens` | `SrcRFLens` (as `double[]` single-element) | Set only if `> 0`. |
| `SourceCid` | `SourceCIDEnergy` | Set only if `> 0`. |
| `SourceCidScaling` | `SourceCIDScalingFactor` | Set only if `> 0`. |
| `DataType` | `DataType` | Set only if non-empty. |
| `ScanRate` | `ScanRate` | Set only if non-empty. |
| `ScanId` | `ICustomScan.RunningNumber` (via `CreateFusionCustomScan`) | Passed as `id` to the terminal helper — this is how the instrument returns the ID on scan completion. |
| `IsAgc` | `CreateFusionCustomScan(..., IsAGC: ...)` | Non-zero → true; controls the Thermo AGC code path. |

**Diagnostic-only fields** — cross the ABI but are NOT mapped to any `ScanParameters` property: `Qscore`, `MonoMass`, `ChargeCos`, `ChargeSnr`, `IsoCos`, `Snr`, `ChargeScore`, `PpmError`, `PrecursorIntensity`, `PeakgroupIntensity`, `HcdEnergy`. All ride along for TSV logging / diagnostics only — see the test-mode TSV write at `FLASHIdaWrapper.cs:372-376`. The actual instrument collision energy is driven per-stage through `Stages[].CollisionEnergy` (emitted as `ActivationType[]` + `CollisionEnergy[]` arrays).

**Bookkeeping fields** not in the mapping: `Priority`, `NumStages` (used to bound the stage loop, not copied), `EnqueueTimestampMs` / `DequeueTimestampMs` (diagnostic), `ParentScanId` (holds the parent's encoded ID; currently not mapped to any `ScanParameters` property, reserved for future lineage work).

## Thermo submission

`BuildFromCommand` returns an `IFusionCustomScan` via `CreateFusionCustomScan` (`ScanFactory.cs:102`). Submission is via the Thermo instrument API at `Flash.cs:380` (`scanControl.SetFusionCustomScan(...)`) or the equivalent `SendCustomScan` helper at `:463`. Thermo API internals — out of scope.

## Gotchas

- **Reflection / name-match is silent on failure.** Renaming a C++ `ScanCommand` field requires renaming the C# mirror (byte-layout contract) *and* checking the `BuildFromCommand` mapping *and* verifying `ScanParameters` has a property with the same name (for reflection-driven emission elsewhere in `ScanFactory`).
- **`ScanDescription` is the scan identity**. It round-trips with the scan result and is the only channel by which the C++ engine re-identifies a returning scan (the encoded tracking ID is re-parsed out of the string on the return path). Don't strip it or transform it before submission.
- **Diagnostic-only fields cross the ABI**. They are emitted to TSV logs but not to any instrument parameter. Do not remove them just because they're absent from `BuildFromCommand`.
- **Conditional writes default to method.** Zero / empty `ScanCommand` fields leave `ScanParameters` unset, letting the Thermo method config provide the default. This is intentional — do not "helpfully" force values to zero for "clean" output.

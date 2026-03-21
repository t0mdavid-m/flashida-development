# Parameter Optimization Plan — v9

**Date:** 2026-03-20
**Revision:** 9
**Supersedes:** v8

**Design principle:** C++ owns the scan queue. One bridge function sends spectra in (`ProcessScan`), one pulls commands out (`GetNextScanCommand`). C# is a thin instrument adapter: extract arrays from `IMsScan`, call `ProcessScan`; call `GetNextScanCommand`, convert `ScanCommand` to `IFusionCustomScan` via `ScanFactory`, send to instrument. `ScanScheduler` is deleted. Configuration via full JSON (including MSSettings). Metadata on `DeconvolvedSpectrum`, not `PeakGroup`.

---

## Deliverable 1 — Contradictions, Cascading Dependencies, and Resolutions

### 1.1 C++ owns the queue => C++ MUST know scan parameters (cascade from fb1+2+3 into fb8)

**v8 state:** JSON config (Issue 8) transmitted deconvolution, precursor selection, exploration, tagging, and FAIMS settings to C++. MSSettings (MS1/MS2/MS3 instrument parameters) stayed in C# because C# built IFusionCustomScan objects directly.

**v9 contradiction:** If C++ owns the queue and generates `ScanCommand` structs including `precursor_mz`, `isolation_width`, `collision_energy`, `analyzer`, `orbitrap_resolution`, `agc_target`, `max_it`, `first_mass`, `last_mass`, `reaction_time`, `reagent_max_it`, `reagent_agc_target` (all currently sourced from `MS1Parameters`, `MS2Parameters`, `MS3Parameters` in C#), then C++ needs the full MSSettings. The JSON config is no longer optional -- it is **required** for the queue-owning architecture to function.

**Resolution:** Expand the JSON schema (Issue 8) to include `ms_settings`:

```json
{
  "ms_settings": {
    "max_ms2_per_ms1": 5,
    "ms1": {
      "analyzer": "FTMS",
      "first_mass": 600,
      "last_mass": 2000,
      "orbitrap_resolution": 120000,
      "agc_target": 500000,
      "max_it": 50,
      "microscans": 3,
      "data_type": "Profile",
      "rf_lens": 30,
      "source_cid": 0,
      "source_cid_scaling": 0
    },
    "ms2": [
      {
        "analyzer": "FTMS",
        "isolation_mode": "Quadrupole",
        "first_mass": 200,
        "last_mass": 2000,
        "orbitrap_resolution": 60000,
        "agc_target": 500000,
        "max_it": 200,
        "microscans": 3,
        "data_type": "Profile",
        "activation": "HCD",
        "collision_energy": 25,
        "reaction_time": 0,
        "reagent_max_it": 0,
        "reagent_agc_target": 0
      }
    ],
    "ms3": [],
    "faims": {
      "cv_values": [-50]
    }
  }
}
```

C# still reads MSSettings from method XML (needed for `ScanFactory` to convert `ScanCommand` to `IFusionCustomScan`), but also serializes it into JSON for C++. C++ stores it in `ms_settings_` struct and uses it when building `ScanCommand` structs.

### 1.2 GetNextScanCommand is synchronous on instrument thread; ProcessScan is asynchronous on TPL thread (thread safety)

**v8 state:** `GetAndClearPendingCommands` drained atomically under a lock. `ProcessScan` pushed to the queue under the same lock. Thread safety was achieved by mutex on `pending_commands_`.

**v9 change:** `GetNextScanCommand` returns a single command (not batch drain). It is called from the instrument thread (the `ProcessSpectrum` handler in `Flash.cs`). `ProcessScan` is called from the TPL `ActionBlock` thread inside `DataPipe`. Both access the same internal priority queue in C++.

**Resolution:** The C++ `std::mutex queue_mutex_` guards all access to the priority queue. `GetNextScanCommand` locks, dequeues one command (priority order, timeout cleanup), unlocks. `ProcessScan` locks, pushes N commands, unlocks. No change from v8's mutex design -- just confirming it handles the single-command pull pattern.

### 1.3 OutputMS removal (fb7) cascades into DataPipe and IScanProcessor

**v8 state:** `IScanProcessor.OutputMS(IFusionCustomScan)` was the second stage of DataPipe. `ProcessMS` returned `IEnumerable<IFusionCustomScan>` which flowed through `TransformManyBlock` into `ActionBlock(OutputMS)`. The null sentinel in ProcessMS triggered `AddDefault()` in OutputMS.

**v9 change:** `ProcessMS` calls `ProcessScan` (fire-and-forget) and returns empty. There are no scans to output. `OutputMS` has nothing to do. The `TransformManyBlock` and `ActionBlock` stages are pointless.

**Resolution:** `DataPipe` becomes a single `ActionBlock<IMsScan>` that calls `ProcessScan` directly. No `TransformManyBlock`, no `OutputMS`, no null sentinel. The `IScanProcessor` interface is replaced by direct `ProcessScan` invocation. Alternatively, if keeping the interface for test mode compatibility, `OutputMS` becomes a no-op.

### 1.4 ScanScheduler deletion cascades into Flash.cs instrument loop

**v8 state:** `Flash.cs:ProcessSpectrum()` calls `scanScheduler.getNextScan()` which returns an `IFusionCustomScan` ready for the instrument. The scheduler managed AGC, MS1 defaults, FAIMS CV cycling, and the command queue.

**v9 change:** `ScanScheduler` is deleted. C++ owns all scheduling decisions.

**Resolution:** `Flash.cs:ProcessSpectrum()` calls `wrapper.GetNextScanCommand(out ScanCommand cmd)`, then `scanFactory.BuildFromCommand(cmd)` to get `IFusionCustomScan`, then `scanControl.SetFusionCustomScan(scan)`. AGC is encoded in `ScanCommand.is_agc` (magic ID 41). MS1 is a regular command from C++. FAIMS CV is in `ScanCommand.faims_cv`. The entire scheduling logic moves to C++.

### 1.5 IsolationWidthOptimization removal (fb4+5) is consistent

**v8 state:** `IsolationWidthOptimization` was a config section under `ParameterOptimization > MS2Exploration`.

**v9 change:** Since C++ owns the queue and controls all scan parameters, isolation width is just another field in `ScanCommand.stages[].isolation_width`. The exploration engine can vary it without a separate optimization flag.

**Resolution:** Remove `IsolationWidthOptimization` from the XML config and JSON schema. If the exploration engine wants to vary isolation width, it does so internally via its variant generation logic.

### 1.6 OptimizationMetadata on DeconvolvedSpectrum, not PeakGroup (fb9 cascade)

**v8 state:** `OptimizationMetadata` was an `std::optional` on `PeakGroup`. Rationale: optimization metadata describes the fragmentation parameters used and resulting quality for a specific precursor.

**v9 change:** Acquisition parameters (CE, isolation width, activation type) describe the **spectrum**, not individual peaks within it. All PeakGroups in a deconvolved spectrum share the same acquisition parameters. Storing per-PeakGroup is wasteful and semantically wrong.

**Resolution:** `OptimizationMetadata` attaches to `DeconvolvedSpectrum` instead. `DeconvolvedSpectrum::spec_` (an `MSSpectrum`) inherits `MetaInfoInterface` via `SpectrumSettings`. For mzML export, call `spec_.setMetaValue("optimization_collision_energy", ...)` directly. No new file needed -- the struct definition goes in `DeconvolvedSpectrum.h` or remains in `OptimizationMetadata.h` and is held as `std::optional<OptimizationMetadata> opt_metadata_` on `DeconvolvedSpectrum`.

PeakGroup retains scoring data (QScore, IDScore) which is per-peak-group. Only acquisition-level metadata moves.

---

## Deliverable 2 — Backwards Compatibility Assessment

| Mode | Risk | What changes | What could break |
|------|------|--------------|------------------|
| Standard DDA | Low | ProcessScan replaces GetPeakGroupSize+GetIsolationWindows. C++ pushes MS2 ScanCommands directly. | Regression if command field mapping (analyzer, resolution, etc.) differs from C# originals. |
| Deep/Inclusion/Exclusion | Low | Targeting logic already in C++. ProcessScan now also generates commands. | None expected; targeting is internal to C++. |
| MS2 Tagging | Medium | ProcessScan handles deconvolve+tag+expand internally. No separate DeconvolveMS2/ProcessMS2ForTagBasedTargeting calls. | Tag detection timing could differ if ProcessScan ordering changes. |
| Conditional MS2 | Medium | First MS2 result triggers follow-up MS2 commands in C++. No C# PendingMS2Info tracking. | Follow-up scan parameters must exactly match current C# construction. Verify activation types, charge capping at 25. |
| Isobaric Quant | Medium | IsDifferentiallyAbundant called internally by ProcessScan on MS2 return. Follow-up HCD scan pushed as ScanCommand. | QuantScanProcessor currently requires exactly 2 MS2 parameter sets. C++ must enforce same constraint. |
| MS3 (modes 0-3) | Medium | Fragment selection + MS3 ScanCommand generation in C++. Two-stage isolation arrays encoded in ScanCommand stages[0]+stages[1]. | MS3 scans use dual-stage PrecursorMass/IsolationWidth/ActivationType/CollisionEnergy arrays. Verify ScanFactory correctly maps multi-stage ScanCommands. |
| FAIMS (multi-CV) | **High** | CV cycling, adaptive skip, queue length gating all move to C++. FAIMSScanProcessor+ScanScheduler FAIMS code deleted. | CV sequencing, skip doubling logic, queue saturation guard (9-2 limit), PAGC group assignment must replicate exactly. Most complex state machine. |
| Static FAIMS (single CV) | Low | Single CV applied to all ScanCommands by C++. | Verify FAIMS_Voltages="on" set correctly. |
| Test mode (`-t`) | Low | Old bridge functions kept as deprecated wrappers through migration. FLASHIdaWrapper.Main() unchanged. | None if wrappers delegate to existing code. |

---

## Deliverable 3 — Migration Plan (6 Phases, 3 C++ Builds)

### Phase 1: C++ Foundation (C++ build #1)

**Goal:** `ProcessScan` stub, `GetNextScanCommand`, tracking system, JSON constructor with full MSSettings, `OptimizationMetadata` on `DeconvolvedSpectrum`.

**C++ files changed:**
- `FLASHIda.h/.cpp` -- Add `processScan()` that dispatches to existing `getPeakGroups()`/`deconvolveMS2()` etc. Add `pending_commands_` priority queue (4 levels, `std::mutex`). Add `pending_scan_map_` for tracking ID resolution. Add atomic tracking counter + base36 encode/decode. Add `parseJSONConfig_()` using `nlohmann_json`, including `ms_settings_` struct to store MS1/MS2/MS3/FAIMS params. Add TRACK audit logging. Add `getNextScanCommand()` method: lock, timeout cleanup, priority dequeue, AGC/MS1 fallback logic. Add `ms1_cycle_timer_` for cycle time enforcement.
- `FLASHIdaBridgeFunctions.h/.cpp` -- Add 3 new exports: `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`. Keep all existing exports.
- `DeconvolvedSpectrum.h/.cpp` -- Add `std::optional<OptimizationMetadata> opt_metadata_` with accessors. Update `toSpectrum()` to serialize metadata via `setMetaValue`.
- NEW `OptimizationMetadata.h` -- Struct definition (context, parameters, quality, timing, cost fields).

**C# files changed:**
- `FLASHIdaWrapper.cs` -- Add P/Invoke for `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`. Add `ScanCommand` struct (blittable, matching C++ layout). Add `ToBase36` helper. Keep all existing P/Invoke declarations.
- `Parameter.cs` -- Add `ToJSON()` method on `IDAParameters`. Include full MSSettings section from `MethodParameters`.

**Verify:** `Flash.exe -t` produces identical output. New functions callable but not yet wired into live path.
**Scope:** L

### Phase 2: C# Infrastructure (no C++ build)

**Goal:** New `UnifiedScanProcessor`, simplified `DataPipe`, `ScanFactory.BuildFromCommand()`. Feature-flagged.

**C# files changed:**
- NEW `UnifiedScanProcessor.cs` -- Implements `IScanProcessor`. `ProcessMS()` extracts arrays, calls `wrapper.ProcessScan()`, returns empty. `OutputMS()` is a no-op.
- `ScanFactory.cs` -- Add `BuildFromCommand(ScanCommand cmd)` that maps `ScanCommand` fields to `ScanParameters` and calls `CreateFusionCustomScan`. Handle multi-stage (MS3) via `stages[]` array. Handle `is_agc` flag (magic ID 41, IonTrap, PAGC settings).
- `DataPipe.cs` -- Add alternate constructor taking `FLASHIdaWrapper` directly, creating single `ActionBlock<IMsScan>` that calls `ProcessScan`. Old 3-stage constructor kept for feature flag off.
- `Flash.cs` -- Add feature flag (e.g., config bool `UseUnifiedProcessor`). When on: create `UnifiedScanProcessor`, simplified `DataPipe`, and replace `scanScheduler.getNextScan()` with `wrapper.GetNextScanCommand()` + `scanFactory.BuildFromCommand()` in `ProcessSpectrum`. When off: old code path unchanged.
- `MethodConfig.cs` -- Add `ScanSchedulingConfig` (CycleTime, ScanTimeout), `ParameterOptimizationConfig`. Add `[Description]` attributes.
- `MethodParameters.cs` -- Wire new config sections into `InitializeIDA()`.

**Verify:** Feature flag on: standard DDA works end-to-end with C++ owning queue. Flag off: identical to v8.
**Scope:** L

### Phase 3: Wire All Modes + Eliminate Quant (C++ build #2, batched with Phase 1 into Build 1)

**Goal:** `processScan()` handles MS1 (deconvolve, select topN, push MS2 commands), MS2 (parse tracking ID, deconvolve, route by mode: standard/tagging/conditional/MS3/quant), MS3 (deconvolve, score). `QuantScanProcessor` eliminated.

**C++ files changed:**
- `FLASHIda.cpp` -- Full `processScan()` implementation:
  - **MS1 path:** Call `getPeakGroups()` + `filterPeakGroupsUsingMassExclusion_()`. For top-N precursors: build `ScanCommand` per MS2 parameter set (from `ms_settings_.ms2[]`), stamp tracking ID, push to `pending_commands_`. For quant mode: push only first MS2 type, mark as quant-trigger in `pending_scan_map_`.
  - **MS2 path:** Parse tracking ID from `scan_description`. Look up `pending_scan_map_` entry. Call `deconvolveMS2()`. Route:
    - **Standard:** Tag if enabled (`processMS2ForTagBasedTargeting`), MS3 if enabled (call appropriate getBestMS2Masses/getTopFragmentMatches/etc, push MS3 ScanCommands with 2-stage isolation).
    - **Conditional:** Tag check. If tags found, push remaining MS2 types for same precursor. If not, skip.
    - **Quant:** Call `isDifferentiallyAbundant()` internally. If true, push second MS2 type ScanCommand.
  - **MS3 path:** Deconvolve, score, log. (No follow-up commands currently.)

**C# files changed:**
- `Flash.cs` -- Remove `QuantScanProcessor` branch. `UnifiedScanProcessor` is now the only path (feature flag removed or defaulted on).
- Delete `QuantScanProcessor.cs`.

**Verify:** Standard DDA, quant mode, MS2 tagging, conditional MS2, MS3 modes 0-3 all produce identical scan sequences. Compare log outputs.
**Scope:** L

### Phase 4: FAIMS Absorption (C++ build #3, highest risk)

**Goal:** FAIMS CV cycling + adaptive skip in C++. `FAIMSScanProcessor` eliminated. FAIMS state removed from C# entirely.

**C++ files changed:**
- `FLASHIda.h/.cpp` -- Add FAIMS state machine:
  - `cv_values_[]`, `cv_skip_amount_[]`, `cv_skip_count_[]`, `current_cv_index_` (mirror of current `ScanScheduler` fields).
  - `updateCV(double cv, int precursors)` -- identical skip-doubling logic from `ScanScheduler.updateCV`.
  - `getNextScanCommand()` extended: when queue empty and FAIMS enabled, cycle to next non-skipped CV, push AGC + MS1 commands with that CV, return AGC.
  - Queue length gating: reject MS2 commands if queue > 7 (matching current 9-2 limit). On reject, remove from exclusion list (existing `removeFromExlusionList`).
  - PAGC group assignment: `cv_to_pagc_group_` map built at init from `ms_settings_.faims.cv_values`.
  - MS2 commands stamped with `faims_cv` matching the CV of the triggering MS1.
  - `processScan()` for FAIMS MS1: pass CV string from scan description to `getPeakGroups()`.

**C# files changed:**
- Delete `FAIMSScanProcessor.cs`.
- `ScanScheduler.cs` -- DELETE entirely. All scheduling now in C++.
- `Flash.cs` -- Remove all `ScanScheduler` creation and references. Remove FAIMS-specific scan pre-building (faimsDefaultScans, faimsAgcScans, faimsPAGCGroups). `BuildFromCommand` in ScanFactory handles PAGC group from `ScanCommand`.
- `ScanFactory.cs` -- `BuildFromCommand` sets `IsPAGCScan` and `PAGCGroupIndex` from `ScanCommand.is_agc` and `ScanCommand.pagc_group`.

**Verify:** Multi-CV FAIMS dataset: identical CV sequence, skip pattern doubling, queue saturation behavior, PAGC group assignments. This is the highest-risk phase. Test with 3+ CV values and a dataset that triggers adaptive skipping.
**Scope:** M (highest risk due to state machine replication)

### Phase 5: Exploration Engine (C++ build #4, batched with Phase 4 into Build 2)

**Goal:** MSn-generalized parameter exploration.

**C++ files changed:**
- `FLASHIda.h/.cpp` -- Add `ExplorationGroup` and `ExplorationVariant` structs (MSn-aware, with `parent_tracking_id` and `msn_level`). Recursive group creation: MS2 winner triggers MS3 exploration (if configured, depth-limited). Scoring: `FragmentationQuality` metric from deconvolved MS2. Winner selection: best score across variants. `OptimizationMetadata` populated on `DeconvolvedSpectrum` for each variant. Config parsed from JSON `exploration` section.

**Verify:** Optimization disabled: identical to Phase 4 output. Enabled: variant commands appear in queue, scoring logged, winner metadata populated.
**Scope:** L

### Phase 6: Cleanup + Documentation (C++ build #5, batched with Phase 5 into Build 2, or separate Build 3)

**Goal:** Remove deprecated bridge functions, clean up C# remnants.

**C++ files changed:**
- `FLASHIdaBridgeFunctions.h/.cpp` -- Remove 12 old exports: `GetPeakGroupSize`, `GetIsolationWindows`, `GetAllPeakGroupSize`, `GetAllMonoisotopicMasses`, `GetRepresentativeMass`, `RemoveFromExclusionList`, `DeconvolveMS2`, `GetBestMS2Masses`, `HasMS2Deconvolution`, `GetMS2PeakGroupCount`, `ClearMS2Deconvolution`, `ProcessMS2ForTagBasedTargeting`. Also remove `IsDifferentiallyAbundant`, `GetTopFragmentMatches`, `GetAmbiguityEnclosingIons`, `GetTerminalFragmentIons`.
- `FLASHIda.h` -- Remove public methods that were only exposed for bridge: `getIsolationWindows()`, `getAllMonoisotopicMasses()`, `GetAllPeakGroupSize()`, `getRepresentativeMass()`, `removeFromExlusionList()`. Make them private or inline into `processScan()`.

**C# files changed:**
- `FLASHIdaWrapper.cs` -- Remove all `[Obsolete]` P/Invoke declarations. Remove `MS3Target` class. Remove `GetIsolationWindows(IMsScan)`, `IsDifferentiallyAbundant(IMsScan)`, etc. Remove `Main()` test harness or update to use new API.
- `IDAScanProcessor.cs` -- DELETE (replaced by `UnifiedScanProcessor`).
- `IScanProcessor.cs` -- DELETE or keep as minimal interface for test mode.
- `PrecursorTarget.cs` -- DELETE (no longer returned across bridge; C++ uses internally).
- Remove `pendingMS2s` dictionary, `PendingMS2Info` class, all tracking ID management from C#.
- NEW `MethodDocGenerator.cs` -- ~30 lines, generates Markdown from `[Description]` attributes via reflection.

**Verify:** Full regression across all modes. `Flash.exe -t` updated for new API.
**Scope:** M

### Build Batching

| C++ Build | Phases | Risk | Estimated Effort |
|-----------|--------|------|------------------|
| Build 1 | Phase 1 + 3 (foundation + all-mode wiring) | Medium | Large -- most new C++ code |
| Build 2 | Phase 4 + 5 (FAIMS + exploration) | High | Medium -- FAIMS state machine is complex |
| Build 3 | Phase 6 (cleanup) | Low | Medium -- many deletions, regression testing |

C# phases (2, portions of 3-6) do not require C++ builds and can be developed in parallel once Build 1 DLL is available.

---

## Updated Design Invariants (v9)

1. **Two operational bridge functions:** `ProcessScan` (input) + `GetNextScanCommand` (output, one at a time)
2. **C++ owns the queue:** Priority, timeout, cycle time, FAIMS CV, AGC, MS1 -- everything
3. **C# is a stateless adapter:** Extract IMsScan arrays, call ProcessScan; call GetNextScanCommand, convert ScanCommand to IFusionCustomScan, send to instrument
4. **ScanScheduler is deleted:** All scheduling logic in C++
5. **Full JSON config required:** MSSettings (MS1/MS2/MS3/FAIMS) included so C++ can build complete ScanCommands
6. **AGC bypass inside C++:** GetNextScanCommand checks AGC timer, returns AGC command with `is_agc=true`, `scan_id=41`
7. **4 priority levels:** 0=background, 1=normal, 2=high, 3=urgent
8. **OptimizationMetadata on DeconvolvedSpectrum:** Not PeakGroup. Serialized via `spec_.setMetaValue()` for mzML export.
9. **Audit trail:** TRACK-CREATE, TRACK-RESOLVE, TRACK-EXPIRE on every tracked scan
10. **Old bridge functions survive through Phase 5** for test mode compatibility
11. **Thread safety:** Single `std::mutex` guards priority queue. ProcessScan (TPL thread) and GetNextScanCommand (instrument thread) contend on same lock.

---

## Structural Delta from v8

| Aspect | v8 | v9 |
|--------|----|----|
| Command retrieval | `GetAndClearPendingCommands` (batch drain) | `GetNextScanCommand` (single pull) |
| Scheduling | ScanScheduler in C# (drain at dequeue) | C++ owns queue; ScanScheduler deleted |
| MS1/AGC | Pre-built in C#, returned by ScanScheduler | Generated by C++ as ScanCommands |
| FAIMS CV | ScanScheduler manages cycling | C++ manages cycling internally |
| JSON config | Optional (deconv+selection params) | Required (includes full MSSettings) |
| DataPipe | 3-stage (Buffer+Transform+Action) | Single ActionBlock (fire-and-forget ProcessScan) |
| IScanProcessor | UnifiedScanProcessor (ProcessMS returns empty, OutputMS handles null) | UnifiedScanProcessor (ProcessMS calls ProcessScan, OutputMS is no-op) |
| OptimizationMetadata | `std::optional` on PeakGroup | `std::optional` on DeconvolvedSpectrum |
| IsolationWidthOptimization | Explicit config section | Removed (exploration engine varies internally) |

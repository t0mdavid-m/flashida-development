# Phase 4: ProcessScan Full Routing — The Switch-Over

**Build produced:** Build #2
**Date:** 2026-03-21
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issues 1 (completion) and 5 (Scoring in Unified Architecture)
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 4 section, CI Environment Requirements
- [../testing-strategy.md](../testing-strategy.md) — Phase 4 test plan

---

## Goal

This is the critical switch-over phase. `ProcessScan` is promoted from a stub (Phase 3) to a fully functional entry point that handles every MS1 and MS2 acquisition mode. Once the full implementation is verified, C# stops calling the old bridge functions and trusts `ProcessScan` + `GetNextScanCommand` exclusively for all scan decisions.

The old bridge functions (`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, etc.) remain exported from the DLL but are no longer called by C# after the switch-over. They will be removed in Phase 8.

After this phase, the full scan decision loop — deconvolution, scoring, filtering, command generation, priority management, MS3 targeting, conditional follow-ups, quant routing, tag-based targeting — lives entirely in C++. C# is responsible only for extracting spectrum data from `IMsScan` objects and forwarding it to `ProcessScan`, then translating returned `ScanCommand` structs into `IFusionCustomScan` objects.

This phase completes Issues 1 (Unified ProcessScan Bridge) and 5 (Scoring in Unified Architecture).

---

## Prerequisites

The following must be in place before beginning Phase 4 implementation:

1. **Build #1 is complete and verified.** Phases 1, 2, and 3 are merged and all their tests pass:
   - P0-* through P3-* tests all pass in CI.
   - `Flash.exe -t` runs with shadow validation, producing TRACK log entries.
   - `GetNextScanCommand` returns MS1 when queue is empty (stub behavior).
   - `ScanCommand` struct marshaling is verified (C# and C++ agree on layout, size, and field offsets).
   - JSON configuration is parsed by C++ and legacy auto-detect fallback works.
   - `OptimizationMetadata` struct exists on `DeconvolvedSpectrum`.

2. **Phase 3 golden files exist.** `baseline_phase3.tsv` (or equivalent per-mode golden files from Phase 3) is committed to `FlashIDA/test-data/golden/`. These are the regression baseline for P4-R01.

3. **Mode-specific method config files exist** or are created as part of this phase before golden files are captured:
   - `test-data/configs/method_default.xml`
   - `test-data/configs/method_deep.xml`
   - `test-data/configs/method_inclusion.xml`
   - `test-data/configs/method_exclusion.xml`
   - `test-data/configs/method_tag_targeting.xml`
   - `test-data/configs/method_quant.xml`
   - `test-data/configs/method_ms3_mode1.xml`
   - `test-data/configs/method_ms3_mode2.xml`
   - `test-data/configs/method_ms3_mode3.xml`

4. **Corresponding test spectrum files exist:**
   - `test-data/spectra/ms1_standard.txt`
   - `test-data/spectra/ms2_hcd_fragment.txt`

   **`ms1_standard.txt` specification (DATA-5):** Must be real top-down MS1 data meeting all of the following criteria:
   - At least 5 independently deconvolvable charge envelopes.
   - Masses spanning the 5–100 kDa range.
   - Precursor intensity dynamic range covering at least 2 orders of magnitude.
   - Do not fabricate values — extract from existing lab .mzML data using `prepare-test-data.py`.

   **`ms2_hcd_fragment.txt` specification (DATA-6):** Must be a real MS2 HCD spectrum meeting all of the following criteria:
   - Acquired from a known protein (protein identity documented alongside the file).
   - Precursor mass known and matching an entry in the inclusion list used for the corresponding regression tests.
   - Real measured fragment ions — not simulated.
   - If isobaric labeling was used during acquisition, reporter ions must be present in the spectrum to support quant mode tests (P4-R07, P4-U07).

5. **OpenMS submodule is on the `flashida-v9-bridge` branch** and the Build #1 commit is the working base.

---

## Modes That Must Work After Switch-Over

All of the following must produce correct, verifiable output when `UseUnifiedBridge=True`:

| Mode | Key behavior in ProcessScan |
|------|-----------------------------|
| Standard DDA | MS1 deconvolution -> top-N MS2 commands pushed at priority 1 |
| Deep mode | Extended MS2 targeting: more precursors per cycle, lower score threshold |
| Inclusion list | Only listed masses generate MS2 commands; unlisted masses suppressed |
| Exclusion list | Listed masses suppressed; all others follow standard DDA |
| Tag-based targeting | MS2 deconvolution results expand the inclusion list for conditional follow-ups |
| Conditional MS2 follow-ups | MS2 that meets `IsConditional` criteria pushes follow-up MS2 at priority 2 |
| Isobaric quant | MS2 route: `isDifferentiallyAbundant` gate before pushing follow-up MS2 |
| MS3 mode 1 (Source CID) | After MS2, push MS3 at priority 3 targeting top source fragments |
| MS3 mode 2 (SPS) | After MS2, push SPS-MS3 at priority 3 targeting selected precursor ions |
| MS3 mode 3 (HCD-triggered) | After MS2 with HCD, push MS3 at priority 3 for sequence-informative fragments |
| MS3 mode 4 (EThcD-triggered) | After MS2 with EThcD, push MS3 at priority 3 for charge-reduced fragments |

Note: the roadmap lists 4 MS3 modes. The test plan covers modes 1, 2, and 3 explicitly in regression tests P4-R08, P4-R09, P4-R10. MS3 mode 4 (EThcD-triggered) is included in the unit test coverage (P4-U05 exercises the general MS3 targeting path) and should be covered by the same `method_ms3_mode4.xml` config if one is prepared; otherwise it is tested implicitly through the MS3 unit tests and added as P4-R11 if resources allow.

---

## Detailed Implementation Steps

### Step 1: Add `UseUnifiedBridge` Feature Flag

**Files:** `FlashIDA/src/Flash/etc/method.xml`, `FlashIDA/src/Flash/Parameter.cs`, `FlashIDA/src/Flash/MethodConfig.cs`

Add the flag to `method.xml`:

```xml
<UseUnifiedBridge>False</UseUnifiedBridge>
```

Default is `False`. This means the old bridge path remains active until the developer deliberately sets it to `True`. The flag is read in C# on startup and controls which code path is taken in `ProcessSpectrum`.

In `Parameter.cs`: add a public `bool UseUnifiedBridge` property parsed from XML.

In `MethodConfig.cs` (the typed JSON model): add `"use_unified_bridge": false` to the JSON schema. Include it in `ToJSON()` output so C++ has visibility if needed (C++ does not act on this flag — it is a C#-side gate only).

This flag is removed in Phase 5 once the unified path is the only path.

---

### Step 2: Implement the MS1 Path in `processScan()`

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Replace the Phase 3 stub with the full MS1 implementation. The pseudocode from Issue 5 defines the structure:

```
processScan(mzs, ints, length, rt_min, ms_level=1, scan_desc):
    1. Build MSSpectrum from (mzs, ints, rt_min)
    2. Deconvolve: deconvolved_spectrum_ = fd_.performDeconvolution(spec)
    3. Score and sort via one of 6 branches (see Step 2a)
    4. Apply mass exclusion filter: filterPeakGroupsUsingMassExclusion_(1, rt)
    5. Apply targeting filter (inclusion/exclusion list if active)
    6. Select top N peak groups (max_mass_count from config)
    7. For each selected peak group: buildMS2Command_(peak_group, charge, hcd)
    8. pushCommand_(cmd) at priority 1
    9. Return total commands pushed
```

#### Step 2a: Implement All 6 Scoring Branches

The scoring dispatch from Issue 5 pseudocode must handle the full 2x3 matrix of `use_idscore_` and `consider_all_charge_states_` flags, plus pure QScore as the fallback:

```cpp
if (use_idscore_ && consider_all_charge_states_)
    deconvolved_spectrum_.sortByIDScoreAllCharges(hcd_energy_);
else if (use_idscore_ && !consider_all_charge_states_)
    deconvolved_spectrum_.sortByIDScoreRepresentative(hcd_energy_);
else
    deconvolved_spectrum_.sortByQscore();
```

The baseline plan's pseudocode shows 3 explicit branches; the test plan (P4-U02) references "all 6 scoring sort branches" as `use_idscore_ x consider_all_charge_states_` = 4 combinations, plus QScore alone = additional variants. Ensure the implementation dispatches correctly for every valid combination. The `consider_all_charge_states_` flag has no effect when `use_idscore_` is false — in that case only `sortByQscore()` is called regardless.

Concretely, the 6 testable branches are:
1. `!use_idscore_`: `sortByQscore()` (default)
2. `use_idscore_ && !consider_all_charge_states_`: `sortByIDScoreRepresentative(hcd_energy_)`
3. `use_idscore_ && consider_all_charge_states_`: `sortByIDScoreAllCharges(hcd_energy_)`
4. Deep mode with QScore (lower threshold)
5. Deep mode with IDScore representative
6. Deep mode with IDScore all charges

Test P4-U02 must exercise each branch with a hard-coded real peak array from characterized experimental data and verify the sort order is deterministic.

#### Step 2b: Implement `buildMS2Command_()`

A private helper that constructs a `ScanCommand` from a peak group:

- `msn_level = 2`
- `num_isolation_stages = 1`
- `stages[0].precursor_mz` from peak group representative m/z
- `stages[0].isolation_width` from MS2 settings in config
- `stages[0].collision_energy` from `hcd_energy_` in config
- `stages[0].charge` from peak group representative charge
- `stages[0].activation_type` from MS2 activation setting (e.g., "HCD")
- `max_it`, `agc_target`, `orbitrap_resolution`, `analyzer` from MS2 settings
- `faims_cv = 0.0` (populated by FAIMS logic in Phase 6; not yet active)
- `scan_description`: base-36 tracking ID (4 chars, from atomic counter)
- `priority = 1`
- `enqueue_timestamp_ms`: current time in milliseconds
- `is_agc = 0`
- `scan_id`: next scan ID counter

After creating the command, store it in `pending_scan_map_[tracking_id]` before pushing to the queue. Log `[TRACK-CREATE]` after storage.

#### Step 2c: Implement `pushCommand_()`

Pushes a `ScanCommand` to the correct priority queue under `queue_mutex_`:

```cpp
void FLASHIda::pushCommand_(ScanCommand cmd)
{
    std::lock_guard<std::mutex> lock(queue_mutex_);
    int p = std::clamp(cmd.priority, 0, 3);
    queues_[p].push_back(cmd);
}
```

Priority levels:
- 3 — MS3 commands and any urgent follow-ups
- 2 — Conditional MS2 follow-ups
- 1 — Standard MS2 commands
- 0 — Exploration variant scans (not yet used, reserved for Phase 7)

---

### Step 3: Implement the MS2 Path in `processScan()`

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

When `ms_level == 2`:

```
processScan(mzs, ints, length, rt_min, ms_level=2, scan_desc):
    1. Parse tracking ID from scan_desc (first 4 chars, base-36)
    2. Look up context: ctx = pending_scan_map_[tracking_id]
       - If not found: log [TRACK-EXPIRE] and return 0
    3. Remove from pending_scan_map_
    4. Log [TRACK-RESOLVE]
    5. Build MSSpectrum with precursor annotation from ctx
    6. Deconvolve: ms2_deconv = fd_.performDeconvolution(spec_with_precursor)
    7. Route by mode (Steps 3a-3d below)
    8. MS3 targeting if enabled (Step 3e)
    9. Return commands pushed
```

#### Step 3a: Tag-Based Targeting Route

If `tag_based_targeting_enabled_`:

```cpp
processMS2ForTagBasedTargeting(ctx.precursor_mass);
```

This expands the inclusion list based on fragment tag matches from the MS2 deconvolution result. The function already exists in the codebase — it is being absorbed from the old bridge into the `processScan` MS2 path. Verify that `processMS2ForTagBasedTargeting` has access to `ms2_deconv` (pass it as a parameter or ensure `fd_` state is correct after deconvolution).

#### Step 3b: Isobaric Quant Route

If `quant_enabled_`:

```cpp
if (isDifferentiallyAbundant(ms2_deconv, ctx.precursor_mass,
                              reporter_mz_tol_, fold_change_threshold_))
    pushFollowUpMS2_(ctx);
```

`pushFollowUpMS2_` builds a new MS2 command from `ctx` (same precursor, potentially different CE or isolation) and pushes it. The follow-up gets priority 2 if it also satisfies `IsConditional` criteria, otherwise priority 1.

#### Step 3c: Exploration Route

If `ctx.exploration_group_id > 0`:

```cpp
feedExplorationResult_(ctx, ms2_deconv);
```

This function is a stub in Phase 4. It logs the result but takes no further action. The exploration engine is fully implemented in Phase 7. The routing branch must exist and be reachable in Phase 4 to ensure no regression when Phase 7 activates it.

#### Step 3d: Conditional MS2 Follow-Up Route

If the scan context has `IsConditional` set (derived from the original command's scan description or a flag in `ctx`):

```cpp
if (ctx.is_conditional && meetsConditionalCriteria_(ms2_deconv, ctx))
    pushConditionalFollowUp_(ctx, ms2_deconv);
```

`pushConditionalFollowUp_` builds a follow-up MS2 command and pushes it at priority 2.

#### Step 3e: MS3 Targeting

After all routing decisions, if `ms3_enabled_`:

```cpp
for (auto& target : selectMS3Targets_(ms2_deconv))
{
    ScanCommand ms3_cmd = buildMS3Command_(ctx, target);
    ms3_cmd.priority = 3;
    pushCommand_(ms3_cmd);
}
```

`selectMS3Targets_` returns up to N fragment ions from `ms2_deconv` that meet MS3 targeting criteria (intensity threshold, charge, m/z range). The selection logic varies by MS3 mode:

- **Mode 1 (Source CID):** Select top-N fragments by intensity from source CID spectrum.
- **Mode 2 (SPS):** Select top-N fragments for synchronous precursor selection; `buildMS3Command_` sets `num_isolation_stages = 2` with both precursor and fragment isolation windows.
- **Mode 3 (HCD-triggered):** Select fragments that are charge-reduced precursor ions (specific to HCD fragmentation pattern).
- **Mode 4 (EThcD-triggered):** Select charge-reduced fragments from EThcD spectrum.

`buildMS3Command_` sets:
- `msn_level = 3`
- `stages[0]` from `ctx` (the MS2 precursor)
- `stages[1]` from `target` (the MS3 precursor)
- `collision_energy` from MS3 settings in config
- `activation_type` from MS3 mode settings
- `scan_description`: new tracking ID for this MS3 command
- `priority = 3`

Log `[TRACK-CREATE]` for each MS3 command after storing in `pending_scan_map_`.

---

### Step 4: Update `FLASHIdaBridgeFunctions.cpp` — ProcessScan Returns Real Count

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp`

The Phase 3 stub returned 0. Phase 4's `ProcessScan` bridge function must return the actual command count from `obj->processScan(...)`. No signature change — only the forwarded return value changes.

```cpp
extern "C" OPENMS_DLLAPI int ProcessScan(
    FLASHIda* obj,
    double* mzs, double* ints, int length,
    double rt_min, int ms_level,
    const char* scan_description)
{
    return obj->processScan(mzs, ints, length, rt_min, ms_level, scan_description);
}
```

This is a one-line change. Verify it does not break the stub behavior expected by P3-I02 — that test specifically checks that the stub returns 0. P3-I02 must be updated or superseded by P4-I02, which validates the new non-zero return behavior.

---

### Step 5: C# Switch-Over — Replace Old Bridge Call Sequences

**File:** `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`
**File:** `FlashIDA/src/Flash/Flash.cs`
**File:** `FlashIDA/src/Flash/IDA/IScanProcessor.cs` (and implementations)

This is the switch-over commit. It replaces every multi-step old bridge call sequence with a single `ProcessScan` + `GetNextScanCommand` loop, gated by the `UseUnifiedBridge` flag.

#### Step 5a: Add `UseUnifiedBridge` Branch in `ProcessSpectrum`

In `Flash.cs`, the `ProcessSpectrum` callback (called on every `MsScanEventArgs`):

```csharp
private static void ProcessSpectrum(object sender, MsScanEventArgs e)
{
    IMsScan msScan = e.GetScan();
    if (inCustom)
    {
        dataPipe.Push(msScan);

        if (parameter.UseUnifiedBridge)
        {
            // New path: ProcessScan has already been called by the scan processor.
            // Retrieve commands pushed by C++ and submit them.
            var cmd = new ScanCommand();
            while (wrapper.GetNextScanCommand(ref cmd) == 1)
            {
                SendCustomScan(scanFactory.BuildFromCommand(cmd));
                cmd = new ScanCommand(); // reset for next iteration
            }
        }
        else
        {
            // Old path: legacy multi-step bridge calls (unchanged from Phase 3)
            // ... existing OutputMS / ScanScheduler calls
        }
    }
    msScan.Dispose();
}
```

The scan processor (called via `dataPipe.Push(msScan)`) calls `ProcessScan` directly when `UseUnifiedBridge` is true. The separation of concerns is:
- Scan processor extracts centroids and calls `ProcessScan` (feeds data to C++).
- `ProcessSpectrum` retrieves commands from C++ via `GetNextScanCommand` and submits them.

#### Step 5b: Update Scan Processors to Call `ProcessScan`

The existing scan processors (`MS1ScanProcessor`, `MS2ScanProcessor`, or whichever classes implement `IScanProcessor`) must be updated to call `wrapper.ProcessScan(...)` when `UseUnifiedBridge` is true, in addition to (or instead of) their existing bridge calls.

When `UseUnifiedBridge=True`:
- The processor extracts `mzs`, `ints`, `length` from `msScan.Centroids`.
- Reads `rt_min` from `msScan.Header["StartTime"]`.
- Reads `ms_level` from `msScan.Header["MSOrder"]`.
- Reads `scan_description` from `msScan.Trailer.GetValueOrDefault("Scan Description", "")`.
- Calls `wrapper.ProcessScan(mzs, ints, length, rt_min, ms_level, scan_description)`.
- Does NOT call any old bridge functions.

When `UseUnifiedBridge=False`:
- The processor runs its existing old-path logic unchanged.

The shadow validation from Phase 3 (calling both old and new paths in parallel) is replaced in Phase 4 by a clean branch: exactly one path runs depending on the flag.

#### Step 5c: Verify `ScanFactory.BuildFromCommand()` Handles All Modes

`BuildFromCommand` was created in Phase 3. Verify it correctly translates every `ScanCommand` variant:
- Standard MS2 (single isolation stage, HCD)
- MS3 (two isolation stages, different CE)
- AGC scan (`is_agc=1`, `analyzer="IonTrap"`)
- MS1 fallback (returned when queue is empty)

If any mode requires scan parameters not yet mapped in `BuildFromCommand`, add the necessary mappings. For SPS-MS3, `num_isolation_stages=2` must produce the correct `IFusionCustomScan` with synchronized precursor selection.

---

### Step 6: Implement TRACK Audit Trail Logging

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

All four audit events must be logged. The log output goes to `std::cout` (or the OpenMS logger, whichever the existing code uses):

| Event | Where | Format |
|-------|-------|--------|
| `[TRACK-CREATE]` | After storing in `pending_scan_map_` (in `buildMS2Command_` and `buildMS3Command_`) | `[TRACK-CREATE] id=XXXX ms_level=2 precursor_mz=1234.56` |
| `[TRACK-CREATE]` | When `GetNextScanCommand` returns MS1 or AGC command | `[TRACK-CREATE] id=XXXX ms_level=1 type=MS1_FALLBACK` |
| `[TRACK-RESOLVE]` | After removing from `pending_scan_map_` in MS2 path | `[TRACK-RESOLVE] id=XXXX rt=12.34 commands_pushed=2` |
| `[TRACK-EXPIRE]` | In `cleanupExpiredCommands_()` | `[TRACK-EXPIRE] id=XXXX age_ms=31000` |

The `cleanupExpiredCommands_()` function is called inside `getNextScanCommand()` under `queue_mutex_` (see Phase 3 design). It iterates `pending_scan_map_` and removes entries where `(now - creation_time_ms) > timeout_ms_`. `timeout_ms_` comes from `scheduling.timeout_seconds * 1000` in the JSON config, or a hardcoded default (e.g., 30 seconds) if the config does not specify one.

Test P4-U09 feeds 10 MS1 + 10 MS2 scans and verifies that every pushed command has `[TRACK-CREATE]` in the log and every resolved scan has `[TRACK-RESOLVE]`. The test reads log output (redirected to a string stream or file) and counts occurrences.

---

### Step 7: Thread Safety Verification

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Verify that `queue_mutex_` correctly protects all shared state accessed by both `processScan()` (called from TPL/DataPipe thread) and `getNextScanCommand()` (called from instrument thread in real operation; called sequentially in test mode).

Shared state requiring lock protection:
- `queues_[4]` (the priority queues)
- `pending_scan_map_`
- `last_ms1_time_ms_` (for cycle time tracking)

The `atomic` tracking ID counter does not require `queue_mutex_` — it is already atomic.

In the C++ implementation, `processScan` must acquire `queue_mutex_` only when pushing to the queue (in `pushCommand_`), not during the deconvolution computation. Deconvolution is not thread-safe if it mutates `fd_` state — verify whether `fd_.performDeconvolution()` is safe to call concurrently with `getNextScanCommand()`. If `fd_` contains mutable state, the deconvolution call itself must be serialized (acquire mutex before deconvolution begins, not just before queue push). This has performance implications for high-scan-rate scenarios but is the safe default. Document the locking strategy in a comment.

---

### Step 8: Capture Phase 4 Golden Files via CI Artifact

Before merging, capture golden output for every mode with `UseUnifiedBridge=True`. These are new golden files (not updates to Phase 3 files):

```
test-data/golden/phase4_standard_dda.tsv
test-data/golden/phase4_deep_mode.tsv
test-data/golden/phase4_inclusion.tsv
test-data/golden/phase4_exclusion.tsv
test-data/golden/phase4_tag_targeting.tsv
test-data/golden/phase4_quant.tsv
test-data/golden/phase4_ms3_mode1.tsv
test-data/golden/phase4_ms3_mode2.tsv
test-data/golden/phase4_ms3_mode3.tsv
```

Golden files are captured entirely through CI — there is no local `Flash.exe -t` invocation. The capture workflow is:

1. Push the Phase 4 implementation branch to GitHub.
2. The CI `capture-golden` job (or a manually triggered workflow dispatch) runs the regression suite in golden-capture mode: instead of comparing against an existing golden file, it writes the output to a named artifact.
3. Download the artifact from the GitHub Actions run summary page.
4. Inspect the downloaded `.tsv` files to confirm correctness (the standard DDA output must match the Phase 3 standard DDA golden; mode-specific files must show expected mode behavior).
5. Commit the reviewed `.tsv` files to `FlashIDA/test-data/golden/` and push.

Subsequent CI runs use the committed files as the comparison baseline for P4-R01 through P4-R10.

The regression runner script (`regression-runner.ps1`) must be updated to include Phase 4 configs and golden files, and must support a `-captureMode` switch that writes output files rather than comparing them.

---

## Files to Create or Modify

### C++ Files (OpenMS submodule)

| File | Change | Description |
|------|--------|-------------|
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Full `processScan()` implementation: MS1 path (all 6 scoring branches, filtering, command building), MS2 path (tracking resolution, all routing modes, MS3 targeting). Add `buildMS2Command_()`, `buildMS3Command_()`, `pushCommand_()`, `selectMS3Targets_()`, `processMS2ForTagBasedTargeting()` (absorb from old bridge or refactor in place), `isDifferentiallyAbundant()` (absorb), `pushFollowUpMS2_()`, `pushConditionalFollowUp_()`, `feedExplorationResult_()` (stub), `cleanupExpiredCommands_()` (refine), audit log calls. |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Declare new private methods added to `FLASHIda.cpp`. No public API change. |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Modify | `ProcessScan` bridge function returns actual command count from `obj->processScan(...)` instead of 0. |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` | Create | C++ unit tests P4-U01 through P4-U09. Exercises MS1 path, all 6 scoring branches, mass exclusion, MS2 tracking resolution, MS3 target generation, conditional follow-ups, quant routing, tag targeting, and audit trail completeness. Peak arrays are hard-coded real measured values from characterized experimental data (no file I/O). A provenance comment block at the top of the file documents the source of every embedded array. |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Uncomment or add entry for `FLASHIda_ProcessScan_test`. (Phase 2 notes that FLASH test entries are currently commented out — they must be active by this phase.) |

### C# Files (FlashIDA)

| File | Change | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/etc/method.xml` | Modify | Add `<UseUnifiedBridge>False</UseUnifiedBridge>` element. |
| `FlashIDA/src/Flash/Parameter.cs` | Modify | Add `public bool UseUnifiedBridge` property, parsed from XML. Include in JSON output via `MethodConfig`. |
| `FlashIDA/src/Flash/MethodConfig.cs` | Modify | Add `"use_unified_bridge"` field to JSON schema class. |
| `FlashIDA/src/Flash/Flash.cs` | Modify | `ProcessSpectrum` callback: add `UseUnifiedBridge` branch. When true, loop `GetNextScanCommand` and call `SendCustomScan(scanFactory.BuildFromCommand(cmd))` for each returned command. When false, run existing old-path logic unchanged. |
| `FlashIDA/src/Flash/IDA/IScanProcessor.cs` | Modify | Update implementing classes to call `wrapper.ProcessScan(...)` in the `UseUnifiedBridge=True` path instead of old bridge functions. |
| `FlashIDA/src/Flash/IDA/ScanFactory.cs` | Modify | Verify and extend `BuildFromCommand()` to handle all mode variants: standard MS2, MS3 (two isolation stages), SPS-MS3, AGC, MS1 fallback. |
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | No change | P/Invoke declarations for `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` already added in Phase 3. Old bridge declarations remain but are no longer called when `UseUnifiedBridge=True`. |

### Test Data Files

| File | Change | Description |
|------|--------|-------------|
| `FlashIDA/test-data/configs/method_default.xml` | Verify/create | Standard DDA config with `UseUnifiedBridge=True` for Phase 4 regression tests. |
| `FlashIDA/test-data/configs/method_deep.xml` | Verify/create | Deep mode config. |
| `FlashIDA/test-data/configs/method_inclusion.xml` | Verify/create | Inclusion list mode config with a sample inclusion list entry. |
| `FlashIDA/test-data/configs/method_exclusion.xml` | Verify/create | Exclusion list mode config with a sample exclusion list entry. |
| `FlashIDA/test-data/configs/method_tag_targeting.xml` | Verify/create | Tag-based targeting mode config. |
| `FlashIDA/test-data/configs/method_quant.xml` | Verify/create | Isobaric quant mode config with reporter m/z settings. |
| `FlashIDA/test-data/configs/method_ms3_mode1.xml` | Verify/create | MS3 Source CID mode config. |
| `FlashIDA/test-data/configs/method_ms3_mode2.xml` | Verify/create | MS3 SPS mode config. |
| `FlashIDA/test-data/configs/method_ms3_mode3.xml` | Verify/create | MS3 HCD-triggered mode config. |
| `FlashIDA/test-data/golden/phase4_*.tsv` | Create | Per-mode golden output files captured from a verified build (see Step 8). |
| `FlashIDA/test-data/golden/README.md` | Modify | Document Phase 4 golden file provenance and the meaning of the `UseUnifiedBridge=True` golden files. |

### CI Files

| File | Change | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | Add Phase 4 regression configs to the regression runner. Add P4-I01, P4-I02 integration steps. Monitor regression timing (see CI Configuration section). |
| `FlashIDA/scripts/regression-runner.ps1` | Modify | Add Phase 4 mode configs and their golden file paths. |

---

## Test Cases

All 19 tests added in this phase, with full descriptions, expected outcomes, and CI runner assignments.

### Unit Tests — C++ (Tier 1, `ubuntu-latest`)

These tests run entirely within C++ using the OpenMS ClassTest framework. They require no Thermo DLLs, no Windows, and no Flash.exe build. They exercise `FLASHIda::processScan()` directly with peak arrays hard-coded in the test file.

**Real peak value requirement:** All peak arrays in `FLASHIda_ProcessScan_test.cpp` must use real measured values extracted from characterized experimental data — not arbitrary or simulated values. A provenance comment block must appear at the top of `FLASHIda_ProcessScan_test.cpp` documenting the source of every embedded peak array (e.g., "MS1 array — extracted from `ms1_standard.txt` scan 42 using `prepare-test-data.py`"). This ensures that score ranking differences observed across branches and mode comparisons reflect genuine instrument behavior, not artificial distributions.

| Test ID | Description | Expected Outcome |
|---------|-------------|------------------|
| P4-U01 | ProcessScan MS1 path: deconvolve + score + push commands | Feed a real MS1 peak array (hard-coded from characterized experimental data) containing 3 charge envelopes with known m/z and charge. Call `processScan` with `ms_level=1`. Verify return value > 0 (commands pushed). Verify `getNextScanCommand` returns MS2 commands with `msn_level=2` and `precursor_mz` matching the known envelope masses. This test also directly validates that `ProcessScan` returns an atomic count — the race condition with the old `GetPeakGroupSize` / `GetIsolationWindows` pattern is structurally eliminated. |
| P4-U02 | All 6 scoring branches produce deterministic output | Create a `FLASHIda` instance for each of the 6 scoring configurations. Feed the same real MS1 peak array (characterized experimental data, hard-coded) to each. Verify that: (a) each branch runs without crash, (b) each branch returns > 0 commands, (c) the sort order for a multi-peak spectrum is deterministic (run twice, same order both times), (d) QScore branch and IDScore branch produce different orderings for the peak array, confirming distinct code paths are active. Because the peak values are from real instrument measurements, the score distribution is meaningful and the ordering differences are genuine. |
| P4-U03 | Mass exclusion filtering works | Push a precursor at a known mass into the exclusion state (by processing one MS1 + one MS2 with the same mass, using real measured peak arrays). Then process a second MS1 peak array containing that mass within the RT exclusion window. Verify that no MS2 command is pushed for the excluded mass. Verify that masses outside the window are still targeted. |
| P4-U04 | MS2 path resolves tracking ID from scan_description | Call `processScan` with a real MS1 peak array to push an MS2 command. Read the tracking ID from the returned command's `scan_description`. Call `processScan` with `ms_level=2` and `scan_description` set to that tracking ID, using a real MS2 peak array. Verify `[TRACK-RESOLVE]` is logged (check log output or a counter on the `FLASHIda` object). Verify the command is removed from `pending_scan_map_` (no double-resolve). |
| P4-U05 | MS3 targets are generated from MS2 deconvolution | Configure `FLASHIda` with MS3 enabled (any mode). Call `processScan` with a real MS1 peak array to push MS2 commands. Call `processScan` with `ms_level=2` (matching tracking ID) using a real MS2 HCD peak array. Verify that `getNextScanCommand` returns MS3 commands with `msn_level=3` and `priority=3`. Verify the MS3 precursor m/z matches a fragment from the real MS2 peak array. |
| P4-U06 | Conditional MS2 follow-ups pushed at priority 2 | Configure with conditional MS2 enabled. Use a real MS2 peak array that meets the conditional criteria (e.g., fragment intensity above threshold, verified from characterized data). Call `processScan` with `ms_level=2`. Verify a follow-up command is pushed with `priority=2`. Dequeue all commands and verify the priority-2 command arrives before any priority-1 commands. |
| P4-U07 | `isDifferentiallyAbundant` routing in ProcessScan | Configure with quant enabled, `fold_change_threshold=1.4`. Use two real MS2 peak arrays: one with reporter ions at a ratio above threshold, one below threshold (both from characterized experimental data with known reporter ion intensities, hard-coded). Verify `pushFollowUpMS2_` is called only for the above-threshold spectrum (one command pushed vs. zero commands pushed). |
| P4-U08 | Tag-based targeting in ProcessScan | Configure with tag-based targeting enabled. Use a real MS2 peak array with fragment masses matching a tag pattern (extracted from characterized data, hard-coded). Call `processScan` with `ms_level=2`. Verify that the tag-based targeting function runs (log output or mock call count). Verify that the inclusion list is expanded with the matched precursor mass. A subsequent MS1 call with a peak array containing that mass must produce an MS2 command for it even if it would otherwise be ranked below the top-N threshold. |
| P4-U09 | TRACK audit trail completeness | Feed 10 MS1 peak arrays (each generating 1 MS2 command) followed by 10 MS2 peak arrays (one for each pending command, using the correct tracking IDs). All arrays are real measured values, hard-coded from characterized experimental data. Capture log output to a string stream. Verify: exactly 10 `[TRACK-CREATE]` entries from MS2 command creation, exactly 10 `[TRACK-RESOLVE]` entries from MS2 processing, zero `[TRACK-EXPIRE]` entries (no timeouts in this test), and zero unresolved entries remaining in `pending_scan_map_`. Also verify that when a stale entry is created (by not consuming a command within the timeout), `cleanupExpiredCommands_` emits `[TRACK-EXPIRE]`. |

### Integration Tests — C# + OpenMS DLL (Tier 2, `windows-latest`)

These tests load `OpenMS.dll` via P/Invoke and exercise the bridge from the C# side with known inputs. They require Thermo DLLs (for build) and OpenMS DLLs (for runtime).

| Test ID | Description | Expected Outcome |
|---------|-------------|------------------|
| P4-I01 | Feature flag `UseUnifiedBridge=False` produces old behavior | Load a `FLASHIda` instance with `method_default.xml` where `UseUnifiedBridge=False`. Run the old bridge call sequence (`GetPeakGroupSize`, `GetIsolationWindows`) against `ms1_standard.txt`. Verify output matches Phase 3 behavior (same scan commands as Phase 3 integration tests). This confirms the flag gate is functional and the old path is not broken. |
| P4-I02 | Feature flag `UseUnifiedBridge=True` produces matching behavior | Load a `FLASHIda` instance with `method_default.xml` where `UseUnifiedBridge=True`. Call `ProcessScan` with the same `ms1_standard.txt` data. Call `GetNextScanCommand` to retrieve commands. Verify: `ProcessScan` returns > 0 (non-stub), returned commands have `msn_level=2`, `precursor_mz` values match what the old path would generate. This is the primary integration-level correctness check for the switch-over. |

### Regression Tests — `Flash.exe -t` Golden File Comparison (Tier 3, `windows-latest`)

All regression tests run `Flash.exe -t` with a method config and compare output against a committed golden file using `compare_golden.py`. All require Thermo DLLs and OpenMS DLLs.

**Note on golden file provenance:** P4-R02 through P4-R10 golden files are created fresh by running the verified Phase 4 build with `UseUnifiedBridge=True`. They are not updated versions of Phase 3 golden files. If the Phase 4 output for standard DDA differs from Phase 3 output, the difference must be investigated and explained before committing the golden file. In the ideal case, standard DDA output is identical to Phase 3.

| Test ID | Description | Expected Outcome |
|---------|-------------|------------------|
| P4-R01 | Regression gate: `UseUnifiedBridge=False` | `Flash.exe -t ms1_standard.txt output.tsv method_default.xml` with `UseUnifiedBridge=False`. Output must match the Phase 3 golden file line-for-line (within `compare_golden.py` numeric tolerances). This test confirms the flag gate works and the old path is completely undisturbed by the Phase 4 changes. |
| P4-R02 | Standard DDA: `UseUnifiedBridge=True` | `Flash.exe -t ms1_standard.txt output.tsv method_default.xml` with `UseUnifiedBridge=True`. Compare to `phase4_standard_dda.tsv` golden. Row count and deconvolution values must match. This is the primary behavioral equivalence check for the switch-over. |
| P4-R03 | Deep mode: `UseUnifiedBridge=True` | `Flash.exe -t ms1_standard.txt output.tsv method_deep.xml` with `UseUnifiedBridge=True`. Compare to `phase4_deep_mode.tsv`. Verify that deep mode produces more precursor targets than standard DDA (expected given lower score threshold). |
| P4-R04 | Inclusion list mode | `Flash.exe -t ms1_standard.txt output.tsv method_inclusion.xml` with `UseUnifiedBridge=True`. Compare to `phase4_inclusion.tsv`. Verify only listed masses appear as targets. |
| P4-R05 | Exclusion list mode | `Flash.exe -t ms1_standard.txt output.tsv method_exclusion.xml` with `UseUnifiedBridge=True`. Compare to `phase4_exclusion.tsv`. Verify listed masses are absent from targets. |
| P4-R06 | Tag-based targeting mode | `Flash.exe -t ms1_standard.txt output.tsv method_tag_targeting.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_tag_targeting.tsv`. Verify tag-matched masses appear in targets. |
| P4-R07 | Isobaric quant mode | `Flash.exe -t ms1_standard.txt output.tsv method_quant.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_quant.tsv`. Verify quant routing is reflected in output. |
| P4-R08 | MS3 mode 1 (Source CID / SPS) | `Flash.exe -t ms1_standard.txt output.tsv method_ms3_mode1.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode1.tsv`. Verify MS3 commands appear at priority 3 in log. |
| P4-R09 | MS3 mode 2 | `Flash.exe -t ms1_standard.txt output.tsv method_ms3_mode2.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode2.tsv`. |
| P4-R10 | MS3 mode 3 | `Flash.exe -t ms1_standard.txt output.tsv method_ms3_mode3.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode3.tsv`. |

**Timing budget note:** 10 regression configs (P4-R01 through P4-R10) each invoke `Flash.exe -t` as a separate process. With process startup overhead, this easily reaches 10-20 minutes of the 20-minute Tier 3 budget. Monitor CI wall time on the first run. If the budget is exceeded:
1. Parallelize: split the 10 configs across two jobs (`bridge-tests` and a new `regression-extended` job) using `needs` to share build artifacts.
2. Reduce: identify configs that are functionally redundant in test mode (e.g., if exclusion and inclusion list modes exercise the same code paths on the same small spectrum, they may be fast). Optimize test spectrum size.
3. The flag-off regression (P4-R01) should be kept as a single fast run using the minimal smoke test spectrum, not the full `ms1_standard.txt`, to minimize its overhead.

---

## CI Configuration Changes

### `flashida-ci.yml` Changes

The following changes are required to support Phase 4 tests:

#### 1. Add `cpp-unit-tests` Test Binary Registration

The new C++ test file `FLASHIda_ProcessScan_test.cpp` must be compiled and registered with CTest. In `OpenMS/src/tests/class_tests/openms/executables.cmake`, add or uncomment:

```cmake
add_executable(FLASHIda_ProcessScan_test source/FLASHIda_ProcessScan_test.cpp)
target_link_libraries(FLASHIda_ProcessScan_test OpenMS)
add_test(NAME FLASHIda_ProcessScan_test COMMAND FLASHIda_ProcessScan_test)
```

The `cpp-unit-tests` CI job already runs `ctest -R FLASH` on `ubuntu-latest`. This entry is picked up automatically once added.

#### 2. Update Regression Runner with Phase 4 Configs

In the CI `csharp-tests` job, the regression step that calls `regression-runner.ps1` must include all 10 Phase 4 configs. The script already loops over a `$configs` array — add the Phase 4 entries:

```powershell
@{ name="p4_standard_dda"; method="method_default.xml"; unified=$true; ms1="ms1_standard.txt"; ms2=$null; golden="phase4_standard_dda.tsv" },
@{ name="p4_deep_mode";    method="method_deep.xml";    unified=$true; ms1="ms1_standard.txt"; ms2=$null; golden="phase4_deep_mode.tsv" },
# ... (all 10 Phase 4 configs)
@{ name="p4_flag_off";     method="method_default.xml"; unified=$false; ms1="ms1_smoke_test.txt"; ms2=$null; golden="baseline_phase3.tsv" },
```

The `unified` parameter controls whether `UseUnifiedBridge=True` or `False` is injected. If `method.xml` files are committed with the flag hardcoded, the runner simply uses them as-is. If the flag is injected at runtime, the runner must patch the XML before each invocation. The simpler approach is to commit separate `method_*_unified.xml` copies with `UseUnifiedBridge=True` and use them directly.

#### 3. Regression Parallelization (if needed)

If P4-R01 through P4-R10 exceed the 20-minute Tier 3 budget, split into two parallel jobs:

```yaml
regression-core:
  runs-on: windows-latest
  needs: [csharp-tests]
  steps:
    - run: regression-runner.ps1 -configs core  # P4-R01, P4-R02, P4-R03

regression-extended:
  runs-on: windows-latest
  needs: [csharp-tests]
  steps:
    - run: regression-runner.ps1 -configs extended  # P4-R04 through P4-R10
```

Both jobs download the same build artifacts from `csharp-tests` using `actions/download-artifact`.

#### 4. Add P4-I01 and P4-I02 to `bridge-tests` Job

The integration tests P4-I01 and P4-I02 are added to the `bridge-tests` job alongside the existing Phase 3 bridge tests:

```yaml
bridge-tests:
  runs-on: windows-latest
  needs: [csharp-tests]
  steps:
    - run: bridge-test-runner.exe  # existing Phase 3 tests
    - run: bridge-test-runner.exe --phase4  # P4-I01, P4-I02
    - run: dumpbin /exports FlashIDA\dll\OpenMS.dll  # DLL export verification
```

#### 5. Cache Key Unchanged

The OpenMS DLL cache key is the submodule commit hash. Since Phase 4 advances the OpenMS submodule (new C++ changes in `FLASHIda.cpp`), the cache will miss on the first Phase 4 build and trigger a full rebuild via `build-openms-dll.yml`. This is expected and correct.

---

## Working Product Verification

All verification is performed by inspecting CI job results — there is no local `Flash.exe -t` or `dumpbin` invocation required from a developer workstation.

### Verification 1: Flag-Off Regression (No Behavioral Change)

Covered by the `regression-core` CI job (test P4-R01). The job runs the regression runner on `windows-latest` with `method_default.xml` (`UseUnifiedBridge=False`) and compares against the Phase 3 golden file using `compare_golden.py`. A green check on P4-R01 confirms the flag gate is functional and the old path is completely undisturbed.

### Verification 2: Standard DDA Equivalence (Flag-On)

Covered by the `regression-core` CI job (test P4-R02). A green check confirms that the standard DDA output with `UseUnifiedBridge=True` matches `phase4_standard_dda.tsv`. Any discrepancy indicates a scoring or filtering difference in the new `processScan` path — investigate the CI log diff output before re-running.

### Verification 3: Each Mode Works Individually

Covered by the `regression-core` and `regression-extended` CI jobs (tests P4-R03 through P4-R10). A green check on each test confirms that mode-specific behavior is present. CI log output from each run shows the command count and any golden file diff lines, which can be inspected in the Actions run summary.

### Verification 4: TRACK Audit Trail

Covered by the C++ unit test P4-U09 running in the `cpp-unit-tests` CI job on `ubuntu-latest`. A green check confirms all `[TRACK-CREATE]` and `[TRACK-RESOLVE]` counts are correct. The CI job captures CTest output as a log artifact if needed for manual inspection.

### Verification 5: Race Condition Elimination

Confirmed structurally by the passing of P4-I02 in the `bridge-tests` CI job: `ProcessScan` returning a non-zero count from a single call (no `GetPeakGroupSize` / `GetIsolationWindows` pair needed) is the observable proof. Document the elimination explicitly in the switch-over commit message.

### Verification 6: DLL Exports Still Include All Old Functions

Automated by the `bridge-tests` CI job on `windows-latest`. The job runs `dumpbin /exports FlashIDA\dll\OpenMS.dll` as a step and asserts that all 5 new bridge functions (`ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`, `CreateFLASHIda`, `DisposeFLASHIda`) and all legacy bridge functions (`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, etc.) are present in the export table. A green check on this step confirms the DLL export surface is correct without any local tooling.

---

## Definition of Done

The following checklist must be fully satisfied before Phase 4 is considered complete and Phase 5 may begin:

### Code

- [ ] `FLASHIda::processScan()` is fully implemented for MS1 path: deconvolution, all 6 scoring branches, mass exclusion filter, targeting filter, top-N selection, `buildMS2Command_()`, `pushCommand_()`.
- [ ] `FLASHIda::processScan()` is fully implemented for MS2 path: tracking ID resolution, deconvolution with precursor annotation, all routing modes (exploration stub, tag targeting, quant, conditional follow-up), MS3 targeting (all 4 modes), `[TRACK-RESOLVE]` logging.
- [ ] `pushCommand_()` correctly populates queues at priorities 3, 2, 1, 0.
- [ ] `cleanupExpiredCommands_()` emits `[TRACK-EXPIRE]` and is called inside `getNextScanCommand()`.
- [ ] `FLASHIdaBridgeFunctions.cpp::ProcessScan` returns actual command count (not 0).
- [ ] `method.xml` has `<UseUnifiedBridge>False</UseUnifiedBridge>`.
- [ ] `Parameter.cs` parses `UseUnifiedBridge`.
- [ ] `Flash.cs::ProcessSpectrum` has `UseUnifiedBridge` branch: old path when false, `GetNextScanCommand` loop when true.
- [ ] `ScanFactory.BuildFromCommand()` handles all modes: standard MS2, MS3 (2 isolation stages), SPS-MS3, AGC, MS1.
- [ ] No changes to the 5 bridge function signatures in `FLASHIdaBridgeFunctions.h` — API is frozen for Phase 4.

### Tests

- [ ] P4-U01 through P4-U09 (9 C++ unit tests) all pass on `ubuntu-latest`.
- [ ] P4-I01 (feature flag off = old behavior) passes on `windows-latest`.
- [ ] P4-I02 (feature flag on = new behavior) passes on `windows-latest`.
- [ ] P4-R01 (flag-off regression) passes — output matches Phase 3 golden.
- [ ] P4-R02 (standard DDA, flag on) passes — output matches phase4 standard DDA golden.
- [ ] P4-R03 through P4-R10 (deep, inclusion, exclusion, tag, quant, MS3 x3) all pass.
- [ ] All P0-* through P3-* tests still pass (full regression suite not broken).

### Test Data

- [ ] All 9 mode-specific method config files exist in `test-data/configs/`.
- [ ] All Phase 4 golden files exist in `test-data/golden/`.
- [ ] `test-data/golden/README.md` documents Phase 4 golden file provenance.

### CI

- [ ] `FLASHIda_ProcessScan_test` is registered in `executables.cmake` and runs under `ctest -R FLASH`.
- [ ] `regression-runner.ps1` includes all 10 Phase 4 configs.
- [ ] CI total wall time for `csharp-tests` + regression jobs stays within budget (investigate parallelization if > 20 min).
- [ ] `flashida-ci.yml` triggers on `phase-4` branch and `flashida-v9-migration` branch.

### Documentation

- [ ] Commit message for the switch-over commit explains: what was switched, the feature flag location, how to revert if needed, and confirms the race condition is eliminated.
- [ ] `CLAUDE.md` (root) does not need updating — Phase 4 does not change the overall architecture description beyond what baseline-plan.md already specifies.

### Build Artifact

- [ ] `OpenMS.dll` from Build #2 is available as a CI artifact keyed to the Phase 4 OpenMS submodule commit hash.
- [ ] Build #2 DLL is used for all Phase 4 regression and integration tests.
- [ ] Phase 5 may begin once all items above are checked off and the PR is merged to `flashida-v9-migration`.

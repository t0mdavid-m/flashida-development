# Phase 4: ProcessScan Full Routing — The Switch-Over

**Build produced:** Build #2
**Date:** 2026-03-21
**Implementation status (2026-03-31):** Batches A-E complete. All C++ (processScan, helpers, tests) and C# (struct update, UseUnifiedBridge, switch-over, harness, CI) implemented. Pending: DLL rebuild, copy to FlashIDA/dll/, test activation, and CI verification.
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issues 1 (completion) and 5 (Scoring in Unified Architecture)
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 4 section, CI Environment Requirements
- [../testing-strategy.md](../testing-strategy.md) — Phase 4 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative format, content requirements, and size constraints for all test data files: spectrum files (§1), golden files (§2), config files (§3), and test infrastructure scripts (§4)

---

## Phase 3 Deviations Impact

Phase 3 compliance review identified several deviations from the original plan that affect Phase 4 implementation. All Phase 4 code must use the actual Phase 3 layouts, not the originally planned layouts.

### Struct Layout Deviations (from Phase 3 compliance report)

**ScanCommand actual layout (1144 bytes)** — field order and types differ from the Phase 3 plan:

| Field | Type | Offset | Plan deviation |
|-------|------|--------|----------------|
| `scan_id` | int32_t | 0 | **First field** (plan had `msn_level` first) |
| `msn_level` | int32_t | 4 | Moved from offset 0 |
| `priority` | int32_t | 8 | Moved from offset 1120 |
| `is_agc` | int32_t | 12 | Moved from offset 1136 |
| `num_stages` | int32_t | 16 | Renamed from `num_isolation_stages` |
| `orbitrap_resolution` | int32_t | 20 | Moved from offset 820 |
| `agc_target` | int32_t | 24 | Moved from offset 816 |
| `pad1` | int32_t | 28 | Alignment padding |
| `first_mass` | double | 32 | Moved into ScanCommand (was only in IsolationStage) |
| `last_mass` | double | 40 | Moved into ScanCommand (was only in IsolationStage) |
| `max_it` | double | 48 | Moved from offset 808 |
| `analyzer` | char[32] | 56 | Moved from offset 824 |
| `scan_description` | char[256] | 88 | Moved from offset 864 |
| `stages` | IsolationStage[10] | 344 | Moved from offset 8 |

**Missing fields**: `enqueue_timestamp_ms` and `faims_cv` were **not included** in the Phase 3 implementation. `enqueue_timestamp_ms` must be added in Phase 4 (see Step 2b). `faims_cv` is deferred to Phase 6 and should NOT be added in Phase 4.

**IsolationStage actual layout (80 bytes)** — field types and names differ:

| Field | Type | Plan deviation |
|-------|------|----------------|
| `precursor_mz` | double | Unchanged |
| `isolation_width` | double | Unchanged |
| `collision_energy` | **double** | Was `int` in plan |
| `reaction_time` | double | Reordered (was offset 56) |
| `reagent_max_it` | double | Reordered (was offset 64) |
| `reagent_agc_target` | int32_t | Unchanged type |
| `charge_state` | int32_t | Renamed from `charge` |
| `activation_type` | **char[32]** | Was `char[16]` in plan |

**C# struct matches the actual C++ layout** (verified in `FLASHIdaWrapper.cs`). C# uses `CollisionEnergy` as `double`, `ActivationType` with `SizeConst = 32`, field order matches C++ exactly.

### Deferred Phase 3 Tests

- **P3-U08 (priority dequeue order)** — implemented as `NOT_TESTABLE` stub in Phase 3 because `processScan_` did not push commands. Phase 4 must **activate this test** with real assertions once `processScan()` pushes commands. Replace the stub with the actual priority-order verification.
- **P3-U09 (AGC first)** — same situation as P3-U08. Phase 4 must **activate this test** when `needsAGCScan_()` is wired up.
- **P3-R01 regression** — deferred from Phase 3. Phase 4 must implement the regression comparison using `baseline_phase3.tsv`.

### CI Changes from Phase 3

- **F-5 fix**: The CI `TRACK-CREATE` check is now **hard-fail**. All Phase 4 regression tests must produce `[TRACK-CREATE]` entries in stdout or CI will fail. This applies to P4-R01 through P4-R10. Ensure every regression run emits at least one `[TRACK-CREATE]` log line.
- **F-3 fix**: P3-I01 now tests 6 additional `ScanCommand` fields (`MsnLevel`, `FirstMass`, `OrbitrapResolution`, `NumStages`, `Analyzer`, `ScanDescription`). Phase 4's bridge tests build on this stronger marshaling foundation.
- **CT14 and CT22 assertions**: Fixed from tautological to meaningful. CT14 checks `Count > 0` + exclusion diff. CT22 checks `ms2Commands.Count > 0`. Phase 4 tests should follow this pattern.

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
   - P0-* through P3-* tests all pass in CI (59 cumulative tests from Phases 0-2, plus Phase 3 tests).
   - `Flash.exe` runs with shadow validation (entry point is `FLASHIdaWrapper.Main()`, no `-t` flag — see Phase 0 lesson #1), producing TRACK log entries. Correct invocation: `Flash.exe <input_file> <output_file> <method.xml> [ms2_file]`.
   - **Phase 2 specifically delivered:** `OptimizationMetadata` struct (18 fields, stored as `std::optional` on `DeconvolvedSpectrum`) with accessors (`hasOptimizationMetadata()`, `getOrCreateOptimizationMetadata()`, `getOptimizationMetadata()`); `GetConfigInt`/`GetConfigDouble` bridge functions exported from `OpenMS.dll`; 5 C++ unit tests passing via `ctest -R DeconvolvedSpectrum_OptimizationMetadata`; `cpp-unit-tests` CI job active on `ubuntu-latest` (no longer gated by `if: false`).
   - **Phase 3 specifically delivered:** the `ProcessScan` and `GetNextScanCommand` bridge functions exported from `OpenMS.dll`; the `ScanCommand` struct (actual field order: `scan_id` first, not `msn_level` — see Phase 3 Deviations Impact section above); the `ScanFactory.BuildFromCommand()` stub in C#; the shadow validation wiring in scan processors; `GetNextScanCommand` returning MS1 when queue is empty; the priority queue data structure (`queues_[4]`) and `queue_mutex_`; the `pending_scan_map_` and tracking ID counter; and the Phase 3 golden file (`baseline_phase3.tsv`) committed to `test-data/golden/`. **Note:** `enqueue_timestamp_ms` and `faims_cv` fields were NOT included in Phase 3 structs — `enqueue_timestamp_ms` must be added in Phase 4, `faims_cv` is deferred to Phase 6. **Note:** P3-U08 (priority dequeue) and P3-U09 (AGC first) are stubs (`NOT_TESTABLE`) that must be activated in Phase 4.
   - `GetNextScanCommand` returns MS1 when queue is empty (stub behavior).
   - `ScanCommand` struct marshaling is verified (C# and C++ agree on layout, size = 1144 bytes, and field offsets — actual field order starts with `scan_id`, see Phase 3 Deviations Impact section).
   - JSON configuration is parsed by C++ and legacy auto-detect fallback works.

2. **Phase 3 golden files exist.** `baseline_phase3.tsv` (or equivalent per-mode golden files from Phase 3) is committed to `FlashIDA/test-data/golden/`. These are the regression baseline for P4-R01.

3. **Mode-specific method config files exist** or are created as part of this phase before golden files are captured. The XML schema, key parameters, and per-file descriptions for all Phase 4 configs are defined in [`../test-file-specification.md §3`](../test-file-specification.md) (§3.1 for the XML section structure, §3.2 for the full inventory including the `UseUnifiedBridge` lifecycle). Files required:
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

   **Multi-scan parser caveat (Phase 0 lesson #9):** Spectrum files may contain multiple scans. Any test code that loads spectrum TSV files must stop at the first scan boundary (`Spec` header line) to avoid mixing peaks and RT values from different scans. Flash.exe's own parser handles multi-scan correctly (processes scan N when scan N+1's header appears), but test-side `LoadSpectrum`/`FromTsv` parsers must break on the second `Spec` line. Failure to do so produces silent zero-result deconvolution (see lesson #14).

   **Spectrum header format (Phase 0 lesson #2):** Flash.exe's parser requires tab-separated headers with RT in seconds: `Spec scan=N\t<rt_seconds>` (no `rt=` prefix). The parser splits on `\t` and divides the second token by 60. This deviates from the test-file-specification's space-separated `rt=R.RRRR` format. Use the tab+seconds format for all spectrum files.

   **`ms1_standard.txt` specification (DATA-5):** The full format definition, size constraints, extraction command, and content requirements are in [`../test-file-specification.md §1.2`](../test-file-specification.md). Summary of mandatory content criteria:
   - At least 5 independently deconvolvable charge envelopes across all scans.
   - Masses spanning the 5–100 kDa range.
   - Precursor intensity dynamic range covering at least 2 orders of magnitude.
   - Must include scans that produce targets for all scoring branches (QScore, IDScore representative, IDScore all-charges), so that all 6 scoring paths in `processScan()` are reachable during regression tests.
   - Do not fabricate values — extract from existing lab .mzML data using `prepare-test-data.py` (see `test-file-specification.md §4.3` for script details and invocation).

   **`ms2_hcd_fragment.txt` specification (DATA-6):** The full format definition, size constraints, extraction command, and content requirements are in [`../test-file-specification.md §1.3`](../test-file-specification.md). Summary of mandatory content criteria:
   - Acquired from a known protein (protein identity documented in `FlashIDA/test-data/golden/README.md`).
   - Precursor mass known and matching an entry in the inclusion list used for the corresponding regression tests.
   - Real measured fragment ions — not simulated.
   - If isobaric labeling was used during acquisition, reporter ions must be present in the spectrum to support quant mode tests (P4-R07, P4-U07).
   - At least 5 high-intensity fragment ions, so that `selectMS3Targets_()` has candidates to return for MS3 mode tests (P4-R08 through P4-R10).

5. **OpenMS submodule is on the `flashida-v9-bridge` branch** and the Build #1 commit is the working base.

### User-Provided Inputs

Before golden file capture can proceed, the following real data files must be committed to `FlashIDA/test-data/spectra/`:

- [ ] `ms1_standard.txt` — real top-down MS1 data with 5+ deconvolvable envelopes, 5-100 kDa, 2+ orders intensity range; extract from lab .mzML using `prepare-test-data.py` (spec §1.2)
- [ ] `ms2_hcd_fragment.txt` — single HCD MS2 scan from a known protein with reporter ions; extract from .mzML (spec §1.3)
- Note: Both must be committed before golden file capture can proceed.

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

### Step 0: Capture Pre-Switch Golden Baselines

**Rationale:** The deconvolution engine doesn't change in Phase 4 — only the dataflow changes (routing through `ProcessScan` instead of per-mode C# bridge paths). Golden files must be captured **before** the switch-over so that regression tests can prove the unified bridge produces identical output to the old path. Capturing after the switch would be self-referential — "whatever the new code produces" — and would not prove behavioral equivalence.

**Prerequisite:** All mode-specific method config files (§3 of test-file-specification.md) and test spectrum files (`ms1_standard.txt`, `ms2_hcd_fragment.txt`) must be committed first.

**Procedure:**

1. Create all 9 mode-specific method config files (see Prerequisites §3) **without** the `UseUnifiedBridge` flag (it doesn't exist yet — the old bridge path is the only path).
2. Push the config and test data files. The CI `windows-tests` job runs `Flash.exe` for each configuration via the regression runner in capture mode (`regression-runner.ps1 -captureMode`).
3. Download the golden capture artifacts from the GitHub Actions run summary.
4. Inspect each `.tsv` file per the checklist in `test-file-specification.md §2.3` (header row matches 15-column format, row count non-zero, float values in plausible ranges).
5. Commit the reviewed `.tsv` files to `FlashIDA/test-data/golden/` and push.
6. Update `FlashIDA/test-data/golden/README.md` with provenance: branch, CI run URL, OpenMS commit hash, spectrum source, and the note **"Captured from old bridge path (pre-switch) to serve as behavioral equivalence baseline for the unified bridge switch-over."**

These golden files become the regression targets for P4-R02 through P4-R10. After the switch-over, each regression test runs `Flash.exe` with `UseUnifiedBridge=True` and compares output against these pre-switch baselines. A match proves the unified bridge is behaviorally equivalent to the old path.

**Golden files captured in this step:**

```
test-data/golden/phase4_standard_dda.tsv    — old bridge, method_default.xml
test-data/golden/phase4_deep_mode.tsv       — old bridge, method_deep.xml
test-data/golden/phase4_inclusion.tsv       — old bridge, method_inclusion.xml
test-data/golden/phase4_exclusion.tsv       — old bridge, method_exclusion.xml
test-data/golden/phase4_tag_targeting.tsv   — old bridge, method_tag_targeting.xml
test-data/golden/phase4_quant.tsv           — old bridge, method_quant.xml
test-data/golden/phase4_ms3_mode1.tsv       — old bridge, method_ms3_mode1.xml
test-data/golden/phase4_ms3_mode2.tsv       — old bridge, method_ms3_mode2.xml
test-data/golden/phase4_ms3_mode3.tsv       — old bridge, method_ms3_mode3.xml
```

**2-commit minimum (Phase 0 lesson #15):** Golden file capture inherently requires at least 2 commits: the first runs CI and produces the golden artifact; the second includes the captured golden file. Batch all 9 captures into a single CI run.

**`compare_golden.py` column classification (Phase 0 compliance lesson L-2):** Before capturing, update `compare_golden.py`'s column classification table to include any mode-specific output columns with appropriate comparison types (exact, numeric, ignore). Mode-specific golden files may have different column sets than standard DDA — each file's column set is validated independently.

After Step 0 is complete, proceed to Step 1 to implement the unified bridge. The golden files are now committed and ready to serve as regression targets.

---

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

A private helper that constructs a `ScanCommand` from a peak group.

**IMPORTANT — Use actual Phase 3 struct layout** (see Phase 3 Deviations Impact section). Key differences from the original plan:
- Field order starts with `scan_id`, then `msn_level`, `priority`, `is_agc`, `num_stages`, etc.
- `collision_energy` is `double` (not `int`)
- `activation_type` is `char[32]` (not `char[16]`)
- `charge` field is named `charge_state`
- `num_isolation_stages` is renamed to `num_stages`
- `first_mass` and `last_mass` are on `ScanCommand` directly (not on `IsolationStage`)

Fields to populate:
- `scan_id`: next scan ID counter (from `nextTrackingIdInt_()`)
- `msn_level = 2`
- `priority = 1`
- `is_agc = 0`
- `num_stages = 1`
- `orbitrap_resolution`, `agc_target` from MS2 settings
- `first_mass`, `last_mass` from MS2 scan range settings
- `max_it` from MS2 settings
- `analyzer` from MS2 settings
- `scan_description`: base-36 tracking ID (4 chars, from atomic counter)
- `stages[0].precursor_mz` from peak group representative m/z
- `stages[0].isolation_width` from MS2 settings in config
- `stages[0].collision_energy` from `hcd_energy_` in config (**double**, not int)
- `stages[0].charge_state` from peak group representative charge
- `stages[0].activation_type` from MS2 activation setting (e.g., "HCD") — **char[32]**

**Phase 4 must also add `enqueue_timestamp_ms` to `ScanCommand`** (deferred from Phase 3). This requires:
1. Add `uint64_t enqueue_timestamp_ms;` field to the C++ `ScanCommand` struct in `FLASHIda.h`. Place it after the last current field or repurpose `pad1` (currently at offset 28) to minimize size change. If added at the end, the struct size will increase from 1144 to 1152 bytes (8 bytes for uint64_t, aligned).
2. Add matching `public ulong EnqueueTimestampMs;` field to the C# `ScanCommand` struct at the same position.
3. Update `static_assert` for the new struct size (will no longer be 1144).
4. Update C# `Marshal.SizeOf` test expectations (P3-U01 expected 1144; must be updated to new size).
5. Update all P3-U03 field offset expectations that shift due to the new field.
6. Set the value to `std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()`

**Size coordination:** Adding `enqueue_timestamp_ms` changes the confirmed 1144-byte struct size. Both C++ `static_assert` and C# layout tests must be updated in the same commit. The `ScanCommandLayout_test` binary output will also change.

**Do NOT add `faims_cv`** — it is deferred to Phase 6.

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
- **Mode 2 (SPS):** Select top-N fragments for synchronous precursor selection; `buildMS3Command_` sets `num_stages = 2` with both precursor and fragment isolation windows.
- **Mode 3 (HCD-triggered):** Select fragments that are charge-reduced precursor ions (specific to HCD fragmentation pattern).
- **Mode 4 (EThcD-triggered):** Select charge-reduced fragments from EThcD spectrum.

`buildMS3Command_` sets (using actual Phase 3 struct field names):
- `scan_id`: new tracking ID
- `msn_level = 3`
- `priority = 3`
- `is_agc = 0`
- `num_stages = 2` (MS3 has both precursor and fragment isolation)
- `stages[0]` from `ctx` (the MS2 precursor)
- `stages[1]` from `target` (the MS3 precursor)
- `stages[*].collision_energy` from MS3 settings in config (**double**, not int)
- `stages[*].activation_type` from MS3 mode settings (**char[32]**)
- `scan_description`: new tracking ID for this MS3 command
- `enqueue_timestamp_ms`: current time in ms (field added in Phase 4)

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

**Silent zero-result failures (Phase 0 lesson #14):** The C++ engine returns 0 without an error code when input data is malformed (wrong RT, mixed peaks from multi-scan parsing, etc.). When `ProcessScan` returns 0 unexpectedly, log the input data characteristics (RT, peak count, first/last m/z) before investigating engine internals. The bridge does not distinguish "no results found" from "input data is malformed."

**`ModificationsDB` singleton calls (Phase 1 lesson #4):** Never remove or comment out calls to OpenMS singleton initializers (`ModificationsDB::getInstance()`, `ResidueDB::getInstance()`, `ElementDB::getInstance()`) even if the return value appears unused. These calls have initialization side effects (the data path resolver, residue mass tables, isotope distributions) that downstream subsystems depend on. If MSVC's `/WX` flags an unused-variable warning (`C4189`) on a singleton call, suppress it with a `(void)` cast rather than removing the call. Removing such a call produces a fatal crash at runtime (`Cannot find shared data! OpenMS cannot function without it!`) that is difficult to correlate with the removed line.

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

If any mode requires scan parameters not yet mapped in `BuildFromCommand`, add the necessary mappings. For SPS-MS3, `num_stages=2` (note: renamed from `num_isolation_stages` in actual Phase 3 implementation) must produce the correct `IFusionCustomScan` with synchronized precursor selection. Also note that `collision_energy` is `double` in the actual struct (C# property `CollisionEnergy` is also `double`), so the `BuildFromCommand` code that maps `stage.CollisionEnergy` to the Thermo API must handle `double` values, not `int`.

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

**CI hard-fail (Phase 3 F-5 fix):** The CI `TRACK-CREATE` check is now a hard-fail gate. Every regression test (P4-R01 through P4-R10) must produce at least one `[TRACK-CREATE]` entry in stdout, or CI will fail the run. This was previously a soft warning. Ensure the `processScan()` implementation emits `[TRACK-CREATE]` for every command it pushes, and that the regression runner captures stdout for the check.

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

### Step 8: Verify Behavioral Equivalence Against Pre-Switch Golden Files

Golden files were already captured in **Step 0** (before the unified bridge implementation) from the old bridge path. This step verifies that the unified bridge produces identical output.

After completing Steps 1-7, push the implementation and verify that all regression tests (P4-R02 through P4-R10) pass — each compares `UseUnifiedBridge=True` output against the pre-switch golden files committed in Step 0. A match proves the unified bridge is behaviorally equivalent to the old path.

If any regression test fails (output differs from pre-switch baseline):
1. Inspect the diff in the CI log (`compare_golden.py` output).
2. Determine if the difference is a bug in the unified bridge (fix it) or an intentional behavioral change (document it in `README.md` and update the golden file with `regression-runner.ps1 -captureMode`).
3. Intentional differences should be rare — the goal is exact equivalence.

**DLL build cost (Phase 1 lesson #10):** Each push to the `flashida-v9-bridge` branch that changes C++ code triggers a full OpenMS build on `windows-2022` taking ~40 minutes with no ccache hit. Phase 4 has substantial C++ changes (full `processScan` implementation, new private methods, updated bridge return value). Batch all C++ changes into a single push to minimize DLL rebuild cycles. Before pushing, check for obvious MSVC issues: unused parameters (`C4100`) and unused local variables (`C4189`) are errors under `/WX`. Use `(void)param;` suppressions where needed. After the first successful build on a new branch, subsequent builds benefit from ccache.

**Submodule batching and pointer updates (Phase 0 lesson #15, Phase 1 lesson #1):** Phase 4 has substantial changes on both C++ and C# sides. Batch all same-side changes before updating the submodule pointer to reduce churn (48% of Phase 0 commits were submodule pointer updates). After pushing to a sub-repo (`OpenMS` or `FlashIDA`), always update the parent repo's submodule pointer immediately (`git add OpenMS FlashIDA` and push); CI checks out submodules at the pointer commit, not at the branch HEAD, so new files pushed to a sub-repo are invisible to CI until the pointer is updated. Recommended commit sequence: (1) golden files and test data from Step 0, (2) all C++ changes to FLASHIda.cpp/h and bridge functions, (3) update submodule pointer, (4) all C# changes to Flash.cs/Parameter.cs/ScanFactory.cs.

---

### Step 9: Switch Continuity Test Harness to Unified Bridge

**Files:** `FlashIDA/src/Flash.Tests/Mocks/ContinuityTestHarness.cs`

**Rationale:** The acquisition loop continuity tests (CT01–CT46) currently call `Processor.ProcessMS(msScan)` which runs the OLD multi-step bridge path through the C# processor layer (`IDAScanProcessor`, `QuantScanProcessor`, `FAIMSScanProcessor`). After the switch-over, this is dead code. The test harness must be updated to call the unified bridge directly so tests validate the active code path.

**Prerequisite:** Steps 1–8 complete. `ProcessScan` returns real command counts, `GetNextScanCommand` dequeues real commands, and behavioral equivalence is verified against pre-switch golden baselines.

All building blocks already exist:
- `FLASHIdaWrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc)` — line 769
- `FLASHIdaWrapper.GetNextScanCommand(ref ScanCommand cmd)` — line 785
- `ScanFactory.BuildFromCommand(ScanCommand cmd)` — line 152, virtual, inherits through `MockScanFactory` → calls overridden `CreateFusionCustomScan` → adds to `CreatedScans`

#### Step 9a: Replace `PushScan` Implementation

Replace the body of `ContinuityTestHarness.PushScan(IMsScan)` to call the unified bridge instead of `Processor.ProcessMS`:

```csharp
public List<IFusionCustomScan> PushScan(IMsScan msScan)
{
    // Extract spectrum data from IMsScan
    int msLevel = int.Parse(msScan.Header["MSOrder"]);
    double rt = double.Parse(msScan.Header["StartTime"]);
    double[] mzs = msScan.Centroids.Select(c => c.Mz).ToArray();
    double[] ints = msScan.Centroids.Select(c => c.Intensity).ToArray();

    // Scan description: MS2+ uses tracking ID from trailer, MS1 uses scan number
    string scanDesc = msScan.Header["Scan"];
    if (msLevel >= 2)
    {
        msScan.Trailer.TryGetValue("Scan Description", out var desc);
        if (!string.IsNullOrEmpty(desc)) scanDesc = desc;
    }

    // Call unified bridge
    Wrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc);

    // Drain command queue
    var scanList = new List<IFusionCustomScan>();
    var cmd = new ScanCommand();
    while (Wrapper.GetNextScanCommand(ref cmd) == 1)
    {
        scanList.Add(Factory.BuildFromCommand(cmd));
        cmd = new ScanCommand();
    }

    return scanList;
}
```

No `Processor.ProcessMS`, no `OutputMS`, no `ScanScheduler` involvement. The C++ engine handles all routing.

#### Step 9b: Simplify Constructor

Remove from the constructor:
- AGC scan creation, default scan creation, FAIMS per-CV scan creation
- `ScanScheduler` instantiation
- `IScanProcessor` instantiation (`IDAScanProcessor`, `FAIMSScanProcessor`, `QuantScanProcessor`)

Keep:
- `MethodParameters.Load(methodXmlPath)` + file path resolution
- `MockScanFactory` creation
- `FLASHIdaWrapper(MethodParams)` creation
- `Factory.CreatedScans.Clear()`

The `Processor`, `Scheduler`, and `UseFaimsCycling` properties can be removed or nulled. Any test code that accessed `harness.Processor` directly (CT22 accesses `harness.Factory.CreatedScans` which is unaffected) needs review.

#### What Changes for Existing Tests

- **CT01–CT42**: Zero test code changes. They call `PushScan` / `PushSmokeSpectrumAndCollect` / `PushStandardSpectrumAndCollect` which all route through the updated `PushScan`.
- **CollectResults / CollectAllResults**: Unchanged — reads `Factory.CreatedScans` populated by `BuildFromCommand`.
- **Golden file assertions**: Unchanged — same comparison logic.
- **Structural assertions** (CT34 follow-up check, CT42 deep mode comparison): Unchanged — they inspect `ScanCommandRecord` fields which `BuildFromCommand` populates identically.

---

## Files to Create or Modify

### C++ Files (OpenMS submodule)

| File | Change | Description |
|------|--------|-------------|
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Full `processScan()` implementation: MS1 path (all 6 scoring branches, filtering, command building), MS2 path (tracking resolution, all routing modes, MS3 targeting). Add `buildMS2Command_()`, `buildMS3Command_()`, `pushCommand_()`, `selectMS3Targets_()`, `processMS2ForTagBasedTargeting()` (absorb from old bridge or refactor in place), `isDifferentiallyAbundant()` (absorb), `pushFollowUpMS2_()`, `pushConditionalFollowUp_()`, `feedExplorationResult_()` (stub), `cleanupExpiredCommands_()` (refine), audit log calls. |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Declare new private methods added to `FLASHIda.cpp`. No public API change. **Also add `uint64_t enqueue_timestamp_ms` field to `ScanCommand` struct** (deferred from Phase 3) and update `static_assert` for new struct size. Do NOT add `faims_cv` (Phase 6). |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | Modify | `ProcessScan` bridge function returns actual command count from `obj->processScan(...)` instead of 0. |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` | Create | C++ unit tests P4-U01 through P4-U09. Exercises MS1 path, all 6 scoring branches, mass exclusion, MS2 tracking resolution, MS3 target generation, conditional follow-ups, quant routing, tag targeting, and audit trail completeness. Peak arrays are hard-coded real measured values from characterized experimental data (no file I/O). A provenance comment block at the top of the file documents the source of every embedded array. |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp` | Modify | **Activate P3-U08 and P3-U09 stubs**: replace `NOT_TESTABLE` placeholders with real test assertions. P3-U08 must push commands at all 4 priorities and verify dequeue order 3->2->1->0 (now possible since `processScan()` pushes commands). P3-U09 must verify AGC scan is dequeued first when `needsAGCScan_()` returns true. |
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
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | P/Invoke declarations for `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId` already added in Phase 3. **Add `public ulong EnqueueTimestampMs` field to C# `ScanCommand` struct** to match C++ addition. Update `Marshal.SizeOf` expectations in layout tests. Old bridge declarations remain but are no longer called when `UseUnifiedBridge=True`. |
| `FlashIDA/src/Flash.Tests/Mocks/ContinuityTestHarness.cs` | Modify | **Step 9:** Replace `PushScan` to call `Wrapper.ProcessScan` + `GetNextScanCommand` loop + `Factory.BuildFromCommand`. Remove AGC/default/FAIMS scan creation, ScanScheduler, and IScanProcessor from constructor. |

### Test Data Files

Config file format, key parameters per file, and the `UseUnifiedBridge` lifecycle are specified in [`../test-file-specification.md §3`](../test-file-specification.md). Golden file column schema, numeric tolerances, and the capture/update workflow are specified in `../test-file-specification.md §2`.

**`.gitattributes` note (Phase 0 lesson #4):** `FlashIDA/.gitattributes` has `* text eol=crlf`, which forces CRLF conversion on ALL files. Any new binary file extensions (e.g., `.enc`, `.gpg`, `.zip`) must be added as `*.ext binary` in `.gitattributes` before committing, or they will be silently corrupted.

| File | Change | Description |
|------|--------|-------------|
| `FlashIDA/test-data/configs/method_default.xml` | Verify/create | Standard DDA config with `UseUnifiedBridge=True` for Phase 4 regression tests. Key parameters: see `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_deep.xml` | Verify/create | Deep mode config: higher `MaxMassCount`, lower `ScoreThreshold`. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_inclusion.xml` | Verify/create | Inclusion list mode config. Inclusion list must contain the precursor mass from `ms2_hcd_fragment.txt`. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_exclusion.xml` | Verify/create | Exclusion list mode config. Exclusion list must contain a mass present in `ms1_standard.txt`. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_tag_targeting.xml` | Verify/create | Tag-based targeting mode config. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_quant.xml` | Verify/create | Isobaric quant mode config: reporter m/z tolerance and fold change threshold must match reporter ions in `ms2_hcd_fragment.txt`. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_ms3_mode1.xml` | Verify/create | MS3 Source CID mode config. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_ms3_mode2.xml` | Verify/create | MS3 SPS mode config. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/configs/method_ms3_mode3.xml` | Verify/create | MS3 HCD-triggered mode config. See `test-file-specification.md §3.2`. |
| `FlashIDA/test-data/golden/phase4_*.tsv` | Create (Step 0) | **Pre-switch golden baselines** captured from the old bridge path BEFORE unified bridge implementation (see Step 0). These serve as behavioral equivalence targets for P4-R02 through P4-R10. Full column schema at `test-file-specification.md §2.1`; provenance table at `test-file-specification.md §2.2`. |
| `FlashIDA/test-data/golden/README.md` | Modify | Document Phase 4 golden file provenance: captured from old bridge path (pre-switch) to serve as behavioral equivalence baselines. See `test-file-specification.md §2.3`. |

### CI Files

| File | Change | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | Add Phase 4 regression configs to the regression runner. Add P4-I01, P4-I02 integration steps. Monitor regression timing (see CI Configuration section). |
| `FlashIDA/scripts/regression-runner.ps1` | Modify | Add Phase 4 mode configs and their golden file paths. |

---

## Test Cases

All 21 tests added in this phase, with full descriptions, expected outcomes, and CI runner assignments.

### Test Summary (Quick Reference)

| Test ID | What it verifies and why |
|---------|--------------------------|
| P4-U01 | `processScan` MS1 path correctly deconvolves a real peak array and pushes MS2 commands. Confirms the atomic command-count return replaces the racy `GetPeakGroupSize`/`GetIsolationWindows` pattern. |
| P4-U02 | All 6 scoring branches (3 flag combinations × 2 depth modes) produce deterministic, distinct sort orders on the same peak array. Confirms every dispatch path is reachable and active. |
| P4-U03 | Mass exclusion filtering suppresses previously-seen masses within the RT exclusion window while still targeting unexcluded masses. Confirms the exclusion state is applied in the MS1 path. |
| P4-U04 | The MS2 path resolves a tracking ID from `scan_description`, logs `[TRACK-RESOLVE]`, and removes the entry from `pending_scan_map_`. Confirms the round-trip from MS1 command creation to MS2 tracking resolution. |
| P4-U05 | MS3 commands are generated from MS2 deconvolution results and arrive with `msn_level=3` and `priority=3`. Confirms `selectMS3Targets_` and `buildMS3Command_` are reachable for any MS3 mode. |
| P4-U06 | Conditional MS2 follow-ups satisfying the conditional criteria are pushed at `priority=2` and dequeued before `priority=1` commands. Confirms priority-queue ordering is correct. |
| P4-U07 | `isDifferentiallyAbundant` gates a follow-up MS2 command: only spectra with reporter-ion ratio above `fold_change_threshold` produce a follow-up. Confirms the quant routing branch is active and selective. |
| P4-U08 | Tag-based targeting expands the inclusion list from MS2 fragment matches so that a previously below-threshold mass receives an MS2 command on the next MS1 scan. Confirms the tag targeting integration into `processScan`. |
| P4-U09 | Ten MS1+MS2 round-trips produce exactly 10 `[TRACK-CREATE]` and 10 `[TRACK-RESOLVE]` log entries with zero `[TRACK-EXPIRE]` and zero unresolved entries. A stale entry triggers `[TRACK-EXPIRE]`. Confirms the full TRACK audit trail. |
| P4-I01 | With `UseUnifiedBridge=False`, the old bridge call sequence (`GetPeakGroupSize`, `GetIsolationWindows`) produces the same commands as Phase 3. Confirms the feature-flag gate leaves the legacy path completely intact. |
| P4-I02 | With `UseUnifiedBridge=True`, `ProcessScan` returns > 0 and the returned commands match what the old path would generate for `ms1_standard.txt`. Confirms bridge-level correctness of the switch-over. |
| P4-R01 | Flag-off (`UseUnifiedBridge=False`) regression: output must match the Phase 3 golden file line-for-line. Guards against any accidental behavioral change in the old code path from Phase 4 edits. |
| P4-R02 | Standard DDA with `UseUnifiedBridge=True` matches `phase4_standard_dda.tsv`. The primary equivalence check that the unified path reproduces legacy DDA behavior. |
| P4-R03 | Deep mode produces more precursor targets than standard DDA (lower score threshold). Confirms that the deep-mode scoring branch is active end-to-end and reflected in golden output. |
| P4-R04 | Inclusion list mode: only masses listed in the inclusion list appear as MS2 targets. Confirms that the targeting filter suppresses unlisted masses in the unified path. |
| P4-R05 | Exclusion list mode: masses in the exclusion list are absent from MS2 targets while others proceed normally. Confirms the exclusion filter applies in the unified path. |
| P4-R06 | Tag-based targeting mode: tag-matched masses appear as MS2 targets even if below the top-N threshold. Confirms the tag targeting route runs within a full `Flash.exe` invocation. |
| P4-R07 | Isobaric quant mode: differential-abundance gating is reflected in the golden output (follow-up MS2 commands present only for above-threshold spectra). Confirms the quant routing route end-to-end. |
| P4-R08 | MS3 mode 1 (Source CID): MS3 commands at `priority=3` appear in output for a known MS2 scan. Confirms source-CID MS3 target selection and command generation. |
| P4-R09 | MS3 mode 2 (SPS): MS3 commands with `num_stages=2` appear in output. Confirms SPS-specific command building end-to-end. |
| P4-R10 | MS3 mode 3 (HCD-triggered): MS3 commands targeting charge-reduced precursor ions appear in output. Confirms HCD-triggered MS3 selection logic end-to-end. |

### Unit Tests — C++ (Tier 1, `ubuntu-latest`)

These tests run entirely within C++ using the OpenMS ClassTest framework. They require no Thermo DLLs, no Windows, and no Flash.exe build. They exercise `FLASHIda::processScan()` directly with peak arrays hard-coded in the test file.

**Real peak value requirement:** All peak arrays in `FLASHIda_ProcessScan_test.cpp` must use real measured values extracted from characterized experimental data — not arbitrary or simulated values. A provenance comment block must appear at the top of `FLASHIda_ProcessScan_test.cpp` documenting the source of every embedded peak array (e.g., "MS1 array — extracted from `ms1_standard.txt` scan 42 using `prepare-test-data.py`"). This ensures that score ranking differences observed across branches and mode comparisons reflect genuine instrument behavior, not artificial distributions.

**MSVC `/WX` compliance (Phase 2 lesson #8):** Any variable in test code that is used only in a `TEST_EQUAL` assertion but not otherwise referenced will trigger MSVC unused-variable warning `C4189`, which is an error under `/WX`. Suppress with `(void)var;` after the assertion. Example: `auto result = obj.processScan(...); TEST_EQUAL(result > 0, true); (void)result;`.

**PeakGroup prerequisite for `toSpectrum()` (Phase 2 lesson #3):** Phase 4 tests primarily call `processScan()` on `FLASHIda` rather than `toSpectrum()` on `DeconvolvedSpectrum`. However, if any Phase 4 test code needs to call `toSpectrum()` (e.g., to inspect deconvolution output), it must first push a default `PeakGroup` into the `DeconvolvedSpectrum` — `toSpectrum()` unconditionally accesses `peak_groups_[0]`.

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

**NUnit runner note (Phase 0 lesson #12, Phase 1 lessons #2, #8):** The NUnit console runner must be invoked by its full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.16.3/tools/nunit3-console.exe`), not assumed to be on PATH. The working directory must be `FlashIDA/bin/` so that native DLLs (`OpenMS.dll` and dependencies) are found by the .NET runtime's DLL search path. Relative paths in tests use `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/` to `FlashIDA/` — which depends on this specific working directory. The NUnit runner must include `--agents=1 --timeout=300000`: single-agent execution avoids parallel cold-cache computations of `calculateAveragine` (~3.5 min first call), and the 5-minute per-test timeout accommodates that cold cache. The CI step that invokes the NUnit runner must also set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`; without it, any test that exercises `FLASHIdaWrapper` will crash with `Cannot find shared data!` (the OpenMS data path resolver searches relative to the executable, which is the NUnit packages directory in CI — not `FlashIDA/bin/`).

| Test ID | Description | Expected Outcome |
|---------|-------------|------------------|
**Constructor selection (Phase 1 lesson #11):** `FLASHIdaWrapper` has two constructors: `FLASHIdaWrapper(IDAParameters)` (legacy, uses `ToFLASHDeconvInput()` space-delimited string) and `FLASHIdaWrapper(MethodParameters)` (new, uses `ToJSON()`). Integration tests P4-I01 and P4-I02 must use `FLASHIdaWrapper(MethodParameters)` to exercise the JSON config path that `UseUnifiedBridge` depends on. The `IDAParameters` constructor remains available as a fallback for legacy bridge tests; do not remove it.

| P4-I01 | Feature flag `UseUnifiedBridge=False` produces old behavior | Load a `FLASHIda` instance with `method_default.xml` where `UseUnifiedBridge=False`. Run the old bridge call sequence (`GetPeakGroupSize`, `GetIsolationWindows`) against `ms1_standard.txt`. Verify output matches Phase 3 behavior (same scan commands as Phase 3 integration tests). This confirms the flag gate is functional and the old path is not broken. |
| P4-I02 | Feature flag `UseUnifiedBridge=True` produces matching behavior | Load a `FLASHIda` instance with `method_default.xml` where `UseUnifiedBridge=True`. Call `ProcessScan` with the same `ms1_standard.txt` data. Call `GetNextScanCommand` to retrieve commands. Verify: `ProcessScan` returns > 0 (non-stub), returned commands have `msn_level=2`, `precursor_mz` values match what the old path would generate. This is the primary integration-level correctness check for the switch-over. |

### Regression Tests — `Flash.exe` Golden File Comparison (Tier 3, `windows-latest`)

All regression tests run `Flash.exe <input_file> <output_file> <method.xml>` with a method config and compare output against a committed golden file using `compare_golden.py`. All require Thermo DLLs and OpenMS DLLs.

**Note on golden file provenance:** P4-R02 through P4-R10 golden files are captured in **Step 0** from the **old bridge path** (before the unified bridge exists). They represent the pre-switch behavioral baseline. Each regression test then runs the same config with `UseUnifiedBridge=True` and compares against this baseline. A match proves the unified bridge is behaviorally equivalent to the old path. Any difference must be investigated as a potential bug in the unified bridge implementation.

| Test ID | Description | Expected Outcome |
|---------|-------------|------------------|
| P4-R01 | Regression gate: `UseUnifiedBridge=False` | `Flash.exe ms1_standard.txt output.tsv method_default.xml` with `UseUnifiedBridge=False`. Output must match the Phase 3 golden file line-for-line (within `compare_golden.py` numeric tolerances). This test confirms the flag gate works and the old path is completely undisturbed by the Phase 4 changes. **Depends on P3-R01**: the `baseline_phase3.tsv` golden file must exist (P3-R01 was deferred from Phase 3 and must be implemented as part of Phase 4 prerequisites). |
| P4-R02 | Standard DDA: `UseUnifiedBridge=True` vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_default.xml` with `UseUnifiedBridge=True`. Compare to `phase4_standard_dda.tsv` (captured from old bridge in Step 0). Output must match — proves the unified bridge reproduces old-path behavior for standard DDA. |
| P4-R03 | Deep mode: `UseUnifiedBridge=True` vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_deep.xml` with `UseUnifiedBridge=True`. Compare to `phase4_deep_mode.tsv` (captured from old bridge in Step 0). Output must match — proves deep mode scoring branch works identically through the unified bridge. |
| P4-R04 | Inclusion list mode vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_inclusion.xml` with `UseUnifiedBridge=True`. Compare to `phase4_inclusion.tsv` (captured from old bridge in Step 0). Output must match — proves inclusion filtering works identically. |
| P4-R05 | Exclusion list mode vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_exclusion.xml` with `UseUnifiedBridge=True`. Compare to `phase4_exclusion.tsv` (captured from old bridge in Step 0). Output must match — proves exclusion filtering works identically. |
| P4-R06 | Tag-based targeting mode vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_tag_targeting.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_tag_targeting.tsv` (captured from old bridge in Step 0). Output must match. |
| P4-R07 | Isobaric quant mode vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_quant.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_quant.tsv` (captured from old bridge in Step 0). Output must match. |
| P4-R08 | MS3 mode 1 vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_ms3_mode1.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode1.tsv` (captured from old bridge in Step 0). Output must match. |
| P4-R09 | MS3 mode 2 vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_ms3_mode2.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode2.tsv` (captured from old bridge in Step 0). Output must match. |
| P4-R10 | MS3 mode 3 vs. pre-switch baseline | `Flash.exe ms1_standard.txt output.tsv method_ms3_mode3.xml ms2_hcd_fragment.txt` with `UseUnifiedBridge=True`. Compare to `phase4_ms3_mode3.tsv` (captured from old bridge in Step 0). Output must match. |

**Timing budget note:** 10 regression configs (P4-R01 through P4-R10) each invoke `Flash.exe` as a separate process. With process startup overhead, this easily reaches 10-20 minutes of the 20-minute Tier 3 budget. Monitor CI wall time on the first run. If the budget is exceeded:
1. Parallelize: split the 10 configs across two jobs (`windows-tests` and a new `regression-extended` job) using `needs` to share build artifacts.
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

The `cpp-unit-tests` CI job runs `ctest -R ClassName --output-on-failure` on `ubuntu-latest` (e.g., `ctest -R FLASHIda_ProcessScan`). Test names follow the OpenMS `ClassName_test.cpp` convention — use `-R ClassName`, not `-R FLASH`. This entry is picked up automatically once added.

#### 2. Update Regression Runner with Phase 4 Configs

The full `regression-runner.ps1` interface (parameters, invocation format, config array schema, `-captureMode` flag, and exit behavior) is defined in [`../test-file-specification.md §4.2`](../test-file-specification.md). The `compare_golden.py` tolerance rules applied per regression run are in `../test-file-specification.md §4.1`.

In the CI `windows-tests` job, the regression step that calls `regression-runner.ps1` must include all 10 Phase 4 configs. The script already loops over a `$configs` array — add the Phase 4 entries:

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
  needs: [windows-tests]
  steps:
    - run: regression-runner.ps1 -configs core  # P4-R01, P4-R02, P4-R03

regression-extended:
  runs-on: windows-latest
  needs: [windows-tests]
  steps:
    - run: regression-runner.ps1 -configs extended  # P4-R04 through P4-R10
```

Both jobs download the same build artifacts from `windows-tests` using `actions/download-artifact`.

#### 4. Add P4-I01 and P4-I02 as bridge verification steps in `windows-tests`

The integration tests P4-I01 and P4-I02 are added as bridge verification steps in `windows-tests` alongside the existing Phase 3 bridge tests:

```yaml
windows-tests:
  runs-on: windows-latest
  steps:
    - run: bridge-test-runner.exe  # existing Phase 3 tests
    - run: bridge-test-runner.exe --phase4  # P4-I01, P4-I02
    - run: dumpbin /exports FlashIDA\dll\OpenMS.dll  # DLL export verification
```

**Build output path (Phase 0 lesson #12):** The actual build output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/`. All CI paths, test runner invocations, and working directories must use `FlashIDA/bin/`.

#### 5. Cache Key Unchanged

The OpenMS DLL cache key is the submodule commit hash. Since Phase 4 advances the OpenMS submodule (new C++ changes in `FLASHIda.cpp`), the cache will miss on the first Phase 4 build and trigger a full rebuild via `build-openms-dll.yml`. This is expected and correct.

**ccache key (Phase 2 lesson #7):** The `cpp-unit-tests` CI job uses `hashFiles('OpenMS/CMakeLists.txt')` for ccache invalidation — not `executables.cmake`. This means adding new test entries to `executables.cmake` does not invalidate the ccache. The cache is only invalidated when `CMakeLists.txt` changes (e.g., when the OpenMS submodule is advanced with new source files).

#### 6. DLL Availability Notes

**Thermo DLLs (Phase 0 lesson #3):** Thermo DLLs are provided via Strategy B — an openssl-encrypted zip committed to the repo (`FlashIDA/dependencies/thermo-dlls.zip.enc`), decrypted in CI using the `THERMO_DLL_PASSPHRASE` secret. Do not use base64 secrets (Strategy A) as they exceed GitHub's 48 KB per-secret limit.

**OpenMS DLLs (Phase 0 lesson #5):** The OpenMS DLLs are already committed in `FlashIDA/dll/` and copied to the build output via `CopyToOutputDirectory` in `Flash.csproj`. No cache/download steps are needed unless the submodule is updated and DLLs are rebuilt.

---

## Working Product Verification

All verification is performed by inspecting CI job results — there is no local `Flash.exe` or `dumpbin` invocation required from a developer workstation.

### Verification 1: Flag-Off Regression (No Behavioral Change)

Covered by the `regression-core` CI job (test P4-R01). The job runs the regression runner on `windows-latest` with `method_default.xml` (`UseUnifiedBridge=False`) and compares against the Phase 3 golden file using `compare_golden.py`. A green check on P4-R01 confirms the flag gate is functional and the old path is completely undisturbed.

### Verification 2: Standard DDA Equivalence (Flag-On vs. Pre-Switch Baseline)

Covered by the `regression-core` CI job (test P4-R02). A green check confirms that the standard DDA output with `UseUnifiedBridge=True` matches the pre-switch golden file `phase4_standard_dda.tsv` (captured from the old bridge in Step 0). Any discrepancy indicates a behavioral difference introduced by the unified bridge — investigate the CI log diff output before re-running.

### Verification 3: Each Mode Matches Pre-Switch Baseline

Covered by the `regression-core` and `regression-extended` CI jobs (tests P4-R03 through P4-R10). Each test compares unified bridge output against the corresponding pre-switch golden file. A green check proves the unified bridge is behaviorally equivalent to the old path for that mode. CI log output from each run shows the command count and any golden file diff lines, which can be inspected in the Actions run summary.

### Verification 4: TRACK Audit Trail

Covered by the C++ unit test P4-U09 running in the `cpp-unit-tests` CI job on `ubuntu-latest`. A green check confirms all `[TRACK-CREATE]` and `[TRACK-RESOLVE]` counts are correct. The CI job captures CTest output as a log artifact if needed for manual inspection.

### Verification 5: Race Condition Elimination

Confirmed structurally by the passing of P4-I02 in the bridge verification step in `windows-tests`: `ProcessScan` returning a non-zero count from a single call (no `GetPeakGroupSize` / `GetIsolationWindows` pair needed) is the observable proof. Document the elimination explicitly in the switch-over commit message.

### Verification 6: DLL Exports Still Include All Old Functions

Automated by the bridge verification step in `windows-tests` on `windows-latest`. The step runs `dumpbin /exports FlashIDA\dll\OpenMS.dll` and asserts that all 5 new bridge functions (`ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`, `CreateFLASHIda`, `DisposeFLASHIda`) and all legacy bridge functions (`GetPeakGroupSize`, `GetIsolationWindows`, `DeconvolveMS2`, etc.) are present in the export table. A green check on this step confirms the DLL export surface is correct without any local tooling.

---

## Definition of Done

The following checklist must be fully satisfied before Phase 4 is considered complete and Phase 5 may begin:

### Code

- [ ] `FLASHIda::processScan()` is fully implemented for MS1 path: deconvolution, all 6 scoring branches, mass exclusion filter, targeting filter, top-N selection, `buildMS2Command_()`, `pushCommand_()`.
- [ ] `FLASHIda::processScan()` is fully implemented for MS2 path: tracking ID resolution, deconvolution with precursor annotation, all routing modes (exploration stub, tag targeting, quant, conditional follow-up), MS3 targeting (all 4 modes), `[TRACK-RESOLVE]` logging.
- [ ] `pushCommand_()` correctly populates queues at priorities 3, 2, 1, 0.
- [ ] `cleanupExpiredCommands_()` emits `[TRACK-EXPIRE]` and is called inside `getNextScanCommand()`.
- [ ] `FLASHIdaBridgeFunctions.cpp::ProcessScan` returns actual command count (not 0).
- [ ] `ScanCommand` struct has `enqueue_timestamp_ms` field added (C++ `uint64_t`, C# `ulong`), with updated `static_assert` and C# layout test expectations.
- [ ] `ScanCommand.faims_cv` is NOT added (deferred to Phase 6).
- [ ] `method.xml` has `<UseUnifiedBridge>False</UseUnifiedBridge>`.
- [ ] `Parameter.cs` parses `UseUnifiedBridge`.
- [ ] `Flash.cs::ProcessSpectrum` has `UseUnifiedBridge` branch: old path when false, `GetNextScanCommand` loop when true.
- [ ] `ScanFactory.BuildFromCommand()` handles all modes: standard MS2, MS3 (2 isolation stages), SPS-MS3, AGC, MS1.
- [ ] No changes to the 5 bridge function signatures in `FLASHIdaBridgeFunctions.h` — API is frozen for Phase 4. (The `ScanCommand` struct layout does change to add `enqueue_timestamp_ms`, but the function signatures themselves are unchanged.)

### Tests

- [ ] **Step 9 (continuity harness switch-over):** `ContinuityTestHarness.PushScan` calls `ProcessScan` + `GetNextScanCommand` instead of `Processor.ProcessMS`. All 63 existing continuity tests pass with the unified bridge (golden files unchanged — behavioral equivalence already verified in Step 8).
- [ ] P4-U01 through P4-U09 (9 C++ unit tests) all pass on `ubuntu-latest`.
- [ ] **P3-U08 (priority dequeue) activated** — stub `NOT_TESTABLE` replaced with real assertions verifying dequeue order 3->2->1->0 (deferred from Phase 3).
- [ ] **P3-U09 (AGC first) activated** — stub `NOT_TESTABLE` replaced with real assertions verifying AGC dequeued before MS2 (deferred from Phase 3).
- [ ] **P3-R01 regression implemented** — `Flash.exe` run with `ms1_smoke_test.txt` compared against `baseline_phase3.tsv` (deferred from Phase 3).
- [ ] P4-I01 (feature flag off = old behavior) passes on `windows-latest`.
- [ ] P4-I02 (feature flag on = new behavior) passes on `windows-latest`.
- [ ] P4-R01 (flag-off regression) passes — output matches Phase 3 golden.
- [ ] P4-R02 (standard DDA, flag on) passes — output matches pre-switch golden baseline.
- [ ] P4-R03 through P4-R10 (deep, inclusion, exclusion, tag, quant, MS3 x3) all pass.
- [ ] All regression tests produce `[TRACK-CREATE]` entries (CI hard-fail gate — Phase 3 F-5 fix).
- [ ] P3-I02 (`ProcessScan_StubReturnsZero`) is updated or removed before Phase 4 merges: Phase 4 changes `ProcessScan` to return the actual command count (non-zero), which would break this test's `Assert.AreEqual(0, result)`. Either remove the test, change the assertion to `Assert.Greater(result, -1)`, or supersede it with P4-I02. (See Step 4 callout.)
- [ ] All P0-* through P3-* tests still pass (full regression suite not broken), including any updated version of P3-I02.

### Test Data

- [ ] All 9 mode-specific method config files exist in `test-data/configs/`.
- [ ] All Phase 4 pre-switch golden baselines exist in `test-data/golden/` (captured from old bridge in Step 0, BEFORE unified bridge implementation).
- [ ] `test-data/golden/README.md` documents Phase 4 golden file provenance (pre-switch capture from old bridge path).

### CI

- [ ] `FLASHIda_ProcessScan_test` is registered in `executables.cmake` and runs under `ctest -R FLASHIda_ProcessScan` (use `-R ClassName` pattern, not `-R FLASH`).
- [ ] `regression-runner.ps1` includes all 10 Phase 4 configs.
- [ ] CI total wall time for `windows-tests` + regression jobs stays within budget (investigate parallelization if > 20 min).
- [ ] `flashida-ci.yml` triggers on `phase-4` branch and `flashida-v9-migration` branch.

### Documentation

- [ ] Commit message for the switch-over commit explains: what was switched, the feature flag location, how to revert if needed, and confirms the race condition is eliminated.
- [ ] `CLAUDE.md` (root) does not need updating — Phase 4 does not change the overall architecture description beyond what baseline-plan.md already specifies.

### Build Artifact

- [ ] `OpenMS.dll` from Build #2 is available as a CI artifact keyed to the Phase 4 OpenMS submodule commit hash.
- [ ] Build #2 DLL is used for all Phase 4 regression and integration tests.
- [ ] Phase 5 may begin once all items above are checked off and the PR is merged to `flashida-v9-migration`.

---

## Implementation Progress (2026-03-30)

### Batch A: Test Data & Config Files — COMPLETE

**Commits:** `912f9e3`, `1b73ce9` on `flashida-v9-migration`

- Extracted `ms1_standard.txt` (50 MS1 scans, E. coli top-down, 488 KB) from `Eclipse_20251016_Original_EcoliRedAlkMCWFA_60min_2ul_R1.mzML`
- Extracted `ms2_hcd_fragment.txt` (CytC HCD MS2, 3516 peaks, precursor 12358 Da, 72 KB) from `20250121_CytC_MS2HCD_MS3HCDCID_Mode2_MS2CE40_MS3CID27.mzML`
- Extracted `ms2_quant_tmt.txt` (iodoTMT MS2 with 10 reporter ions at 126-131 Da, 4 KB) from `FLASHIda_methodQuant_Ecoli_Glucose_vs_Acetat_iodoTMT_FC0_only1Cond_1ul.mzML`
- Added CytC to `test_fasta.fasta`, updated MS3 configs with CytC protein sequence
- Added 9 Phase 4 configs to `regression-runner.ps1`

### Batch B: Golden File Capture — COMPLETE

**CI runs:** `23737573239`, `23738550840`, `23739338211` on `phase-4`

- All 9 golden files captured from old bridge path via CI (Flash.exe test mode)
- Each has 1 header + 6 data rows, 15-column TSV format
- Fixed regression runner to copy supporting files (inclusion list, FASTA, TargetLog) to working directory for bare filename resolution
- Fixed TRACK-CREATE check to warning (old bridge test path doesn't call ProcessScan)
- Captured `phase4_inclusion.tsv` re-captured after fixing inclusion list format

### Batch B2: Golden File Verification & Mode Coverage Fixes — COMPLETE

**CI run:** `23741455500`, `23742235949` on `phase-4`

Verification found all 9 original golden files were functionally identical to standard DDA (modes not exercised). All 4 issues fixed:

1. **Inclusion list**: Changed from integer masses to monoisotopic masses (2063.606, 2277.254, 4297.177, 5315.129, 12358.31) for 20 ppm matching
2. **Strict inclusion**: Added `phase4_inclusion_strict` entry to regression runner. Golden shows 4 of 6 masses (only target-matched masses survive)
3. **Deep/exclusion TargetLogs**: Created `test_target_log.log` with 3 of 6 standard DDA masses. Deep golden now has 3 data rows (3 masses deprioritized). Exclusion loads TargetLog.
4. **Quant/MS3 test harness**: Extended `FLASHIdaWrapper.ProcessScan` to call `IsDifferentiallyAbundant` (quant), `GetBestMS2Masses` + `GetTopFragmentMatches` (MS3). Set `OPENMS_DATA_PATH` in CI for `ModificationsDB` (required by `FLASHExtenderAlgorithm`).

**Final golden file status (10 files):**

| File | Rows | Mode exercised? | Differs from DDA? |
|------|------|-----------------|-------------------|
| `phase4_standard_dda.tsv` | 6 | Yes (baseline) | N/A |
| `phase4_deep_mode.tsv` | 3 | Yes | Yes — 3 TargetLog masses excluded |
| `phase4_inclusion.tsv` | 6 | Yes | FP differences (non-strict fills) |
| `phase4_inclusion_strict.tsv` | 4 | Yes | Yes — 2 non-target masses removed |
| `phase4_exclusion.tsv` | 6 | Partially | FP only (qscore threshold not exceeded) |
| `phase4_tag_targeting.tsv` | 6 | Partially | FP only (tagger runs, no visible effect in TSV) |
| `phase4_quant.tsv` | 6 | Yes (stdout) | FP only (IsDifferentiallyAbundant logged) |
| `phase4_ms3_mode1.tsv` | 6 | Yes (stdout) | FP only (fragment matching: CytC b/y ions) |
| `phase4_ms3_mode2.tsv` | 6 | Yes (stdout) | FP only |
| `phase4_ms3_mode3.tsv` | 6 | Yes (stdout) | FP only |

### Batch B3: End-to-End Acquisition Loop Verification — COMPLETE

All 30 AL-CT continuity tests pass (CI run `23742235949`, 53/53 tests green). B2 config changes don't break continuity golden files because smoke test CytC mass (12351.33 Da) doesn't overlap with B2 target masses (2063-5315 Da range).

**Coverage gap identified:** Continuity tests have significant gaps in MS2 return pathways:
- MS3: PARTIAL — MS2 pushed back, but MS3 generation not asserted
- Tag targeting: NOT COVERED — no MS2 pushed back, follow-up scheduling untested
- Conditional MS2: NOT COVERED — conditional decision never runs
- Quant: NOT COVERED — IsDifferentiallyAbundant never called in continuity tests
- These gaps exist since Phase 0. Phase 4 C++ unit tests (P4-U04–U09) will cover at C++ level.

### Remaining Work

- **Batch C**: C++ implementation (processScan full routing, helpers, tests) — PENDING
- **Batch D**: C# implementation (UseUnifiedBridge, switch-over) — PENDING
- **Batch E**: CI & regression runner updates — PENDING

---

## Phase 0-2 Lessons Applied

This section records which Phase 0, Phase 1, and Phase 2 lessons were applied during the writing of this plan and where each appears.

### Phase 0 Lessons

| Lesson | Source | Where Applied in This Plan |
|--------|--------|---------------------------|
| L0-1: No `-t` flag; correct `Flash.exe <input_file> <output_file> <method.xml> [ms2_file]` | Phase 0 #1 | Prerequisites §1 (entry point note); regression test table (P4-R01 through P4-R10); all regression test descriptions use correct invocation |
| L0-3: Strategy B for Thermo DLLs (openssl-encrypted zip) | Phase 0 #3 | CI Configuration §6 (Thermo DLLs note) |
| L0-4: Binary file extensions in `.gitattributes` | Phase 0 #4 | Test Data Files table note |
| L0-5: OpenMS DLLs committed in `FlashIDA/dll/`, no download needed | Phase 0 #5 | CI Configuration §6 (OpenMS DLLs note) |
| L0-9: Multi-scan parsers must stop at first scan boundary | Phase 0 #9 | Prerequisites §4 (multi-scan parser caveat) |
| L0-12: Build output `FlashIDA/bin/`; DLL name `"OpenMS.dll"` with extension; NUnit full path; working dir `bin/` | Phase 0 #12 | CI Configuration §4 (build output note); Files to Modify table (FLASHIdaWrapper.cs row); integration test NUnit runner note |
| L0-14: Silent zero-result P/Invoke failures | Phase 0 #14 | Step 4 (bridge return value) — "Silent zero-result failures" callout |
| L0-15: 2-commit minimum for golden capture; submodule pointer batching | Phase 0 #15 | Step 8 golden capture workflow; submodule batching note |
| L0 compliance L-2: `compare_golden.py` column classification for new columns | Phase 0 audit | Step 8 — "`compare_golden.py` column classification" callout |

### Phase 1 Lessons

| Lesson | Source | Where Applied in This Plan |
|--------|--------|---------------------------|
| L1-1: Submodule pointer must be updated after every sub-repo push | Phase 1 #1 | Step 8 — "Submodule batching and pointer updates" callout |
| L1-2: Test data path is `Path.Combine(TestDirectory, "..", "test-data")` (one level up from `bin/`) | Phase 1 #2 | Integration test NUnit runner note |
| L1-3: Check for pre-existing MSVC `/WX` errors before DLL build | Phase 1 #3 | Step 8 — "DLL build cost" callout |
| L1-4: Never remove `ModificationsDB::getInstance()` singleton calls | Phase 1 #4 | Step 4 — "ModificationsDB singleton calls" callout |
| L1-5: `OPENMS_DATA_PATH` must be set in all CI steps that invoke OpenMS | Phase 1 #5 | Integration test NUnit runner note |
| L1-8: NUnit `--agents=1 --timeout=300000` | Phase 1 #8 | Integration test NUnit runner note |
| L1-10: DLL build ~40 min; batch C++ changes | Phase 1 #10 | Step 8 — "DLL build cost" callout |
| L1-11: Prefer `FLASHIdaWrapper(MethodParameters)` constructor; keep old overload | Phase 1 #11 | Integration test section — "Constructor selection" note |

### Phase 2 Lessons

| Lesson | Source | Where Applied in This Plan |
|--------|--------|---------------------------|
| L2-1: `toSpectrum()` returns `MSSpectrum` by value, not void with out-param | Phase 2 | Not directly used in Phase 4 tests (Phase 4 does not call `toSpectrum()` in test code). Noted here for awareness; any future Phase 4 test that calls `toSpectrum()` must use the return-value pattern: `MSSpectrum out = ds.toSpectrum(1);` |
| L2-2: `DeconvolvedSpectrum` constructor takes `scan_number`, not `ms_level` | Phase 2 | Not directly used in Phase 4 C++ tests (Phase 4 tests call `processScan()` on `FLASHIda`, not construct `DeconvolvedSpectrum` directly). Noted here; if any Phase 4 test constructs a `DeconvolvedSpectrum`, use `DeconvolvedSpectrum(scan_number)`. |
| L2-3: `toSpectrum()` requires at least one PeakGroup (accesses `peak_groups_[0]`) | Phase 2 | Not directly used in Phase 4 tests. Noted here; any Phase 4 test calling `toSpectrum()` must push a default `PeakGroup` first to avoid undefined behavior. |
| L2-4: CTest naming uses `-R ClassName` pattern, not `-R FLASH` | Phase 2 | CI Configuration §1 (ctest invocation); Definition of Done (test registration check). All ctest invocations use `-R FLASHIda_ProcessScan`, not `-R FLASH`. |
| L2-5: CI apt dependencies (ubuntu) — full list required | Phase 2 | CI references point to `environment-and-workflows.md` Section 1 for the authoritative apt list: `build-essential ccache ninja-build qt6-base-dev libeigen3-dev libboost-random-dev libboost-regex-dev libboost-iostreams-dev libboost-date-time-dev libboost-math-dev libxerces-c-dev zlib1g-dev libsvm-dev libbz2-dev liblzma-dev libzstd-dev coinor-libcoinmp-dev` |
| L2-6: CMake flags for test-only builds | Phase 2 | CI uses `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja` for the `cpp-unit-tests` job |
| L2-7: ccache key uses `hashFiles('OpenMS/CMakeLists.txt')`, not `executables.cmake` | Phase 2 | CI Configuration §5 (cache key unchanged note) |
| L2-8: MSVC `/WX` — use `(void)var;` to suppress unused variable warnings in test code | Phase 2 | Step 8 "DLL build cost" callout (applies to all C++ test code); C++ unit test section — any variable used only in `TEST_EQUAL` assertions must have `(void)var;` after the assertion to suppress MSVC `C4189` |
| L2-9: Phase 2 delivered `OptimizationMetadata` struct, `GetConfigInt`/`GetConfigDouble` bridge functions, 5 C++ unit tests, `cpp-unit-tests` CI job active | Phase 2 | Prerequisites §1 (Phase 2 deliverables listed explicitly) |

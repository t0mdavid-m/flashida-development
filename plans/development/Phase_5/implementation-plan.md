# Phase 5: C# Simplification — Implementation Plan

**Date:** 2026-03-21
**Phase:** 5 of 8
**Build produced:** None (C#-only changes)
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 6 (Simplified C# Architecture), Phase 5 specification
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 5 section
- [../testing-strategy.md](../testing-strategy.md) — Phase 5 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative format, content, and size requirements for all test files used in this phase

---

## Phase 4 Addendum (2026-04-04)

This plan has been updated to reflect actual Phase 4 outcomes. Key changes from original estimates:
- **ScanCommand struct size**: 1240 bytes (was "expected ~1152"), with 11 scoring fields added
- **GetNextScanCommand**: Returns 0 when queue is empty (accepted deviation HIGH-02); C# ScanScheduler provides MS1 fallback
- **Test counts**: Phase 4 delivered ~31 tests (not 21), cumulative ~70 (not 60); Phase 5 target is ~76
- **Scan descriptions**: Base-36 encoded tracking IDs (`XXXX|mass@charge`), not sequential (`_N|mass@charge`)
- **ScanCommandRecord**: Expanded to 22 properties (11 original + ScanType + ChargeState + 11 scoring)
- **CT27/CT28 FAIMS tests**: `[Ignore]`d in Phase 4, deferred to Phase 6
- **UseUnifiedBridge**: Defaults to `true` in production (post-switchover, accepted deviation D3)
- **Phase 4 status**: COMPLETE in baseline-plan.md

---

## Goal

Simplify the C# architecture now that `ProcessScan` and `GetNextScanCommand` handle all scan decision logic. Three existing scan processor classes are replaced by a single `UnifiedScanProcessor`. The `DataPipe` pipeline collapses from three stages to two. The `OutputMS` method and its null-sentinel completion pattern are removed. The `UseUnifiedBridge` feature flag is removed because the unified path is now the only supported path. `QuantScanProcessor.cs` is deleted.

`ScanScheduler` is explicitly retained in this phase. It remains the owner of FAIMS CV cycling until Phase 6 absorbs that responsibility into C++. Phase 5 handles FAIMS entirely at the C# `ScanScheduler` level (CV cycling, FAIMS-aware target lists). The `faims_cv` field on `ScanCommand` is a Phase 6 struct addition — Phase 5 must NOT add it.

No C++ code is touched. The Build #2 artifact (`OpenMS.dll`) from Phase 4 is reused unchanged.

---

## Prerequisites

Phase 4 is complete. All Phase 4 work (unified bridge switch-over, `UseUnifiedBridge=True` passing all modes, Build #2 DLL committed) has been verified and merged. The following must be confirmed before beginning Phase 5 work.

1. **Phase 4 switch-over confirmed for all modes.** `UseUnifiedBridge=True` passed all Phase 4 regression tests (already verified during Phase 4):
   - P4-R02 standard DDA
   - P4-R03 deep mode
   - P4-R04 inclusion list
   - P4-R05 exclusion list
   - P4-R06 tag-based targeting
   - P4-R07 isobaric quant
   - P4-R08, P4-R09, P4-R10 MS3 modes 1–3

2. **FAIMS regression passing.** `Flash.exe ms1_faims_3cv.txt output.tsv method_faims_3cv.xml` produces correct output under `UseUnifiedBridge=True`. (FAIMS still runs through `ScanScheduler` at this point; this must be verified before that dependency is removed.) Note: the entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()` — there is no `-t` flag (see Phase 0 lesson #1).

3. **Phase 4 golden files committed.** The pre-switch golden baselines (captured from the old bridge path in Phase 4 Step 0, before the unified bridge implementation) are the regression baseline for Phase 5. They were verified as behaviorally equivalent to the unified bridge output by P4-R02 through P4-R10. They must be committed to `FlashIDA/test-data/golden/` and referenced by `P5-R01` and `P5-R02`. The specific files are: `phase4_standard_dda.tsv`, `phase4_deep_mode.tsv`, `phase4_inclusion.tsv`, `phase4_exclusion.tsv`, `phase4_tag_targeting.tsv`, `phase4_quant.tsv`, `phase4_ms3_mode1.tsv`, `phase4_ms3_mode2.tsv`, `phase4_ms3_mode3.tsv`. See [test-file-specification.md §2.2](../test-file-specification.md) for the full golden file inventory.

4. **Build #2 OpenMS DLLs available.** The OpenMS DLLs from Build #2 (Phase 4) are committed in `FlashIDA/dll/`. MSBuild copies them to the build output via `CopyToOutputDirectory` in `Flash.csproj` — no CI download or cache step is needed (see Phase 0 lesson #5). No new C++ build is triggered in this phase. **Note:** The Build #2 DLL includes the `enqueue_timestamp_ms` field and 11 scoring fields added to `ScanCommand` in Phase 4. The Phase 4 `static_assert` confirms the struct size is **1240 bytes**.

5. **All prior phase tests green.** The CI suite for Phases 0–4 must be passing on the branch before Phase 5 work begins. Phase 4 completed with ~70 cumulative tests (~31 new in Phase 4, including 10 continuity tests CT33–CT42). Confirm the parent repo submodule pointer is up to date with the merged Phase 4 commit (see Phase 1 lesson #1).

### User-Provided Inputs

- [x] `ms1_faims_3cv.txt` — real FAIMS MS1 data with 5 CV values (-10, -30, -40, -50, -60), 300 scans. Used by continuity tests CT09/CT10/CT27/CT28.
- Note: The CV values in `method_faims_3cv.xml` and `method_faims_skip.xml` match the actual CV annotations in the provided data.

---

## Phase 3/4 Deviations Impact

Phase 3 compliance review and Phase 4 implementation introduced struct layout deviations and CI changes that carry forward into Phase 5. While Phase 5 makes no C++ changes and does not modify struct layouts, the following context is relevant for any Phase 5 code that references `ScanCommand` or `IsolationStage` (e.g., `ScanFactory.BuildFromCommand()` in P5-R01/R02, `UnifiedScanProcessor` calling `ProcessScan`).

### Struct Layout Context (inherited from Phase 3/4)

**ScanCommand** — field order starts with `scan_id` (not `msn_level` as originally planned). Phase 4 added `enqueue_timestamp_ms` (`uint64_t` / C# `ulong`) and 11 scoring fields (Qscore, MonoMass, ChargeCos, ChargeSnr, IsoCos, Snr, ChargeScore, PpmError, PrecursorIntensity, PeakgroupIntensity, HcdEnergy + Pad2[8]). The Phase 4 `static_assert` and C# `Marshal.SizeOf` test confirm the struct size is **1240 bytes**. Phase 5 code must use this value — do not hardcode 1144 or 1152.

**`ScanCommandRecord` expanded** — now has 22 properties (11 original + ScanType + ChargeState + 11 scoring fields from Phase 4). Scoring fields are only populated via `FromScanCommand()` (unified bridge path); `FromCustomScan()` leaves them at 0.

**`GetNextScanCommand` returns 0 when queue is empty** — accepted deviation HIGH-02 from Phase 4. The C++ `GetNextScanCommand` does NOT return an MS1 fallback command; it returns 0 (no command available). The C# `ScanScheduler` provides the MS1 fallback behavior. Phase 5 code that calls `GetNextScanCommand` must handle the 0-return case.

**Scan description format** — Phase 4 changed tracking IDs from `_N|mass@charge` to `XXXX|mass@charge` (base-36 encoded). Any test assertions or log parsing that matches scan description patterns must use the base-36 format.

**Conditional MS2 gating** — Phase 4 established that MS2 firing now requires `processMS2ForTagBasedTargeting()` to return true before scheduling. This is handled in C++ and does not affect Phase 5 C# code directly, but is relevant context for understanding why certain modes may produce fewer commands.

**CollisionEnergy rounding** — C# uses `Math.Round()` (banker's rounding), not truncation. Relevant for any Phase 5 code that constructs or inspects `ScanCommand` collision energy values.

**IsolationStage (80 bytes)** — key type deviations from the original plan:
- `collision_energy` is `double` (not `int`). C# property `CollisionEnergy` is also `double`.
- `activation_type` is `char[32]` (not `char[16]`). C# uses `SizeConst = 32`.
- `charge` field is named `charge_state`.

These types are already correct in the Phase 4 C# structs (`FLASHIdaWrapper.cs`). Phase 5 does not modify these structs, but any new code or tests that reference field types must use the actual types above.

**`faims_cv` is NOT in `ScanCommand`** — this field is deferred to Phase 6. Phase 5 handles FAIMS exclusively at the C# `ScanScheduler` level. `FAIMSScanProcessor` delegates CV cycling to `ScanScheduler.AddScan()`, which reads CV values from the method XML config — no struct-level FAIMS field exists yet.

**`enqueue_timestamp_ms`** — added in Phase 4. Phase 5 code that constructs or inspects `ScanCommand` (e.g., in `ScanFactory.BuildFromCommand()`) should be aware this field exists. It is set by C++ at command creation time and is read-only on the C# side.

### CI Changes from Phase 3/4

- **TRACK-CREATE hard-fail**: The CI `TRACK-CREATE` check is now a hard-fail gate (Phase 3 F-5 fix). Phase 5 regression test P5-R01 must produce `[TRACK-CREATE]` entries in stdout or CI will fail. Since Phase 5 reuses the Phase 4 code paths unchanged (only removing dead code and the `UseUnifiedBridge` flag), `[TRACK-CREATE]` entries should appear automatically from `processScan()` — but verify in CI output.
- **CT14/CT22 assertions**: Fixed in Phase 3 to be meaningful (`Count > 0` + exclusion diff for CT14; `ms2Commands.Count > 0` for CT22). Phase 5 tests follow this pattern — no tautological assertions.
- **CT27/CT28 FAIMS tests**: Were `[Ignore]`d in Phase 4 due to lack of per-CV test data. **Activated in Phase 5** — now use real per-CV data from `ms1_faims_3cv.txt` via `FromTsvAllScans`. CT28 captures golden file via legacy bridge for Phase 6 regression.
- **CT09/CT10 FAIMS**: Use real per-CV FAIMS data. Conditional validation (`if results.Count > 0`) retained as the legacy bridge path may not produce results with only 50 scans depending on engine state accumulation.
- **Phase 4 new test artifacts**: Phase 4 added spectrum file `ms2_quant_tmt.txt`, configs `method_default_legacy.xml`, `method_inclusion_strict.xml`, `method_ms3_mode1_hcd.xml`, `method_ms3_mode2_hcd.xml`, `method_ms3_mode3_hcd.xml`, golden file `phase4_inclusion_strict.tsv`, and 8 continuity JSON files. These are available for Phase 5 regression testing.

---

## Detailed Implementation Steps

### Step 1: Create `UnifiedScanProcessor.cs`

Create a new file `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs`.

This class is the sole implementation of `IScanProcessor` after this phase. Its `ProcessMS` method does three things only: check the analyzer type, extract centroids, and call `ProcessScan` via `FLASHIdaWrapper`. It contains no scan scheduling, no mode-routing logic, and no FAIMS awareness — all of that now lives in C++.

The mass analyzer guard (`"FTMS"` check) is the same filter that the old processors applied before calling into the bridge, and it must be preserved here to avoid feeding ion trap scans to the deconvolution engine.

Centroid extraction uses LINQ over `IMsScan.Centroids` to produce parallel `double[]` arrays for m/z and intensity, consistent with how the old processors prepared data before calling legacy bridge functions.

The scan description string is read from `msScan.Trailer` with a key of `"Scan Description"` and defaults to an empty string when absent. This string is the mechanism by which C++ resolves a returning MS2 spectrum back to its `pending_scan_map_` entry via the embedded tracking ID.

`GetNextScanCommand` is not called inside `ProcessMS`. Command retrieval remains in `Flash.cs` (see Step 4). `UnifiedScanProcessor` is solely responsible for feeding spectra into C++.

The class takes a `FLASHIdaWrapper` instance via constructor injection. It does not hold any other state.

**File to create:** `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs`

---

### Step 2: Simplify `IScanProcessor.cs`

The existing `IScanProcessor` interface currently declares two methods: `ProcessMS(IMsScan)` and `OutputMS(IMsScan)`. The `OutputMS` method is the output stage of the old three-stage DataPipe and is no longer needed because `ActionBlock` handles completion directly.

Remove the `OutputMS` method declaration from the interface. The interface must declare exactly one method after this change:

```csharp
public interface IScanProcessor
{
    void ProcessMS(IMsScan msScan);
}
```

Any class that previously implemented `OutputMS` must have that implementation removed. After `QuantScanProcessor.cs` is deleted (Step 3) and `FAIMSScanProcessor.cs` is updated, only `UnifiedScanProcessor` and `FAIMSScanProcessor` implement this interface. `FAIMSScanProcessor` must be updated to remove its `OutputMS` implementation.

**File to modify:** `FlashIDA/src/Flash/IDA/IScanProcessor.cs`

---

### Step 3: Delete `QuantScanProcessor.cs`

`QuantScanProcessor` performed isobaric quantification filtering (`isDifferentiallyAbundant`) before deciding whether to schedule follow-up MS2 scans. This logic was absorbed into C++ `processScan()` during Phase 4 — specifically the `quant_enabled_` branch in the MS2 routing path.

Delete the file. Before deleting, verify by text search that no remaining `.cs` file references the class name `QuantScanProcessor` other than in its own file and any test files that were written to assert its absence (P5-U03). If any production code still references `QuantScanProcessor`, that reference must be removed first.

After deletion, `Flash.cs` must not contain any conditional logic that selects `QuantScanProcessor` as the active processor.

**File to delete:** `FlashIDA/src/Flash/IDA/QuantScanProcessor.cs`

---

### Step 4: Collapse `DataPipe.cs` to Two Stages

The current `DataPipe` uses three linked blocks:
- `BufferBlock<IMsScan>` (input buffer)
- `TransformManyBlock<IMsScan, IMsScan>` (the `ProcessMS` → `OutputMS` transform stage)
- `ActionBlock<IMsScan>` (output consumer connected to `OutputMS`)

The `TransformManyBlock` and its null-sentinel completion pattern exist because the old interface required `ProcessMS` to return a transformed scan (or null to signal completion). This is no longer needed.

Replace the entire DataPipe body with a two-block pipeline:

```
BufferBlock<IMsScan> inputScans
    -> ActionBlock<IMsScan> (calls processor.ProcessMS)
```

Link them with `PropagateCompletion = true` so that completing the `BufferBlock` (by calling `inputScans.Complete()`) automatically propagates the completion signal to the `ActionBlock`. The `ActionBlock.Completion` task becomes the awaitable that `Flash.cs` uses to know all queued scans have been processed.

The `DataPipe.Push(IMsScan)` method posts to the `BufferBlock` unchanged.

The `DataPipe.Complete()` / `DataPipe.WaitForCompletion()` surface must be updated to call `inputScans.Complete()` and await `scanProcessor.Completion` respectively.

Remove all references to `TransformManyBlock`, the null-sentinel check (`if (scan == null)`), the `OutputMS`-based linking code, and any `NullableOutput` wrapper types if present.

**File to modify:** `FlashIDA/src/Flash/IDA/DataPipe.cs`

---

### Step 5: Update `Flash.cs` — Remove Processor Selection Logic and Feature Flag

`Flash.cs` currently contains logic that selects which scan processor implementation to instantiate based on the mode configuration and the `UseUnifiedBridge` flag. After this phase, `UnifiedScanProcessor` is always the processor. Two changes are required:

**5a. Remove `UseUnifiedBridge` flag.**

The `UseUnifiedBridge` XML element in `method.xml` was a temporary migration switch introduced in Phase 4 to allow reverting to old bridge behavior during testing. Now that the unified path is the only path, the flag and all code that reads or branches on it must be removed. This includes:
- Removal of the `UseUnifiedBridge` property from `Parameter.cs` (or `MethodConfig.cs` if it was placed there).
- Removal of the conditional branch in `Flash.cs` that selected between old and new paths based on this flag.
- Removal of the corresponding `<UseUnifiedBridge>` element from `method.xml`.

**5b. Remove processor-type selection logic.**

The code that chose between `QuantScanProcessor`, `FAIMSScanProcessor`, and other processors based on configuration settings must be simplified to always instantiate `UnifiedScanProcessor` as the base processor. `FAIMSScanProcessor` may still wrap it for FAIMS mode, since `ScanScheduler` is still active; this delegation pattern is preserved until Phase 6.

The `ProcessSpectrum` event handler already calls `dataPipe.Push(msScan)` and then runs the `GetNextScanCommand` loop (established in Phase 4). That structure is unchanged in this step.

**Files to modify:**
- `FlashIDA/src/Flash/Flash.cs`
- `FlashIDA/src/Flash/Parameter.cs` (or `MethodConfig.cs`) — remove `UseUnifiedBridge` property
- `FlashIDA/src/Flash/etc/method.xml` — remove `<UseUnifiedBridge>` element (the `UseUnifiedBridge` lifecycle — added Phase 4, removed Phase 5 — is documented in [test-file-specification.md §3.2](../test-file-specification.md))

---

### Step 6: Update `FAIMSScanProcessor.cs` for the New Interface

`FAIMSScanProcessor` still exists and is still used in this phase. It implements `IScanProcessor` and delegates the actual deconvolution work to an inner processor. Because `IScanProcessor` no longer has `OutputMS`, the `FAIMSScanProcessor` implementation must be updated:

- Remove its `OutputMS` implementation.
- Ensure its `ProcessMS(IMsScan)` delegates to the inner processor's `ProcessMS` (which is now `UnifiedScanProcessor`). The FAIMS-specific scheduling via `ScanScheduler.AddScan()` is preserved here; this is intentional and remains until Phase 6.

`FAIMSScanProcessor` must still implement the simplified `IScanProcessor` interface (one method only). If it currently has additional helper methods, those are unaffected.

**FAIMS scope clarification:** In Phase 5, FAIMS CV values are sourced from the method XML config and managed by `ScanScheduler` in C#. The `ScanCommand` struct does NOT have a `faims_cv` field — that is added in Phase 6 when FAIMS control moves to C++. `FAIMSScanProcessor` does not set any FAIMS field on `ScanCommand`; it only calls `ScanScheduler.AddScan()` which handles CV cycling independently.

**File to modify:** `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs`

---

### Step 7: Remove Null-Sentinel Completion Pattern from All Processors

Search for all call sites of the null-sentinel pattern (posting `null` to a `BufferBlock` or `TransformManyBlock` as an end-of-stream signal). These call sites exist because the old `TransformManyBlock` used a null scan to signal that `OutputMS` should complete. With the two-stage `ActionBlock` pipeline, completion is propagated by calling `BufferBlock.Complete()` directly. Remove all null posts and any associated null checks in `ProcessMS` implementations.

This affects any scan processor that previously checked `if (msScan == null)` at the top of `ProcessMS` to handle the sentinel. Those guards must be removed because `ActionBlock` will never deliver a null item when using `PropagateCompletion`.

Verify that the overall shutdown sequence in `Flash.cs` calls `dataPipe.Complete()` (which calls `inputScans.Complete()`) and then awaits `dataPipe.WaitForCompletion()` to drain the pipeline before disposing the `FLASHIdaWrapper`. The ordering of these calls must be preserved.

**Files to verify/modify:** All `IScanProcessor` implementations, `Flash.cs` shutdown sequence.

---

### Step 8: Verify No Remaining References to Deleted Items

Ensure the following are true before pushing:

1. Search all `*.cs` files under `FlashIDA/src/` for the string `QuantScanProcessor`. Expect zero hits outside of test files that assert its absence.
2. Search for `OutputMS` in `*.cs` files. Expect zero hits outside of comments and the test file for P5-U02.
3. Search for `UseUnifiedBridge` in `*.cs` and `*.xml` files. Expect zero hits.
4. Search for `TransformManyBlock` in `*.cs` files. Expect zero hits.
5. Confirm `ScanScheduler` is still referenced (it must be — it is not removed until Phase 6).

These checks are automated by CI test P5-U03. The CI run is the authoritative verification.

---

## Files to Create / Modify / Delete

| Action | File | Description |
|--------|------|-------------|
| **Create** | `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs` | New single-responsibility processor: extracts centroids, calls `ProcessScan`, nothing else |
| **Modify** | `FlashIDA/src/Flash/IDA/IScanProcessor.cs` | Remove `OutputMS` declaration; interface has exactly 1 method: `void ProcessMS(IMsScan)` |
| **Delete** | `FlashIDA/src/Flash/IDA/QuantScanProcessor.cs` | Quant filtering absorbed into C++ `processScan`; no remaining callers |
| **Modify** | `FlashIDA/src/Flash/IDA/DataPipe.cs` | Collapse to `BufferBlock<IMsScan>` -> `ActionBlock<IMsScan>`; remove `TransformManyBlock` and null-sentinel logic |
| **Modify** | `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs` | Remove `OutputMS` implementation; retain `ProcessMS` delegation to `UnifiedScanProcessor` and `ScanScheduler` integration |
| **Modify** | `FlashIDA/src/Flash/Flash.cs` | Remove `UseUnifiedBridge` branch; always instantiate `UnifiedScanProcessor`; preserve `GetNextScanCommand` loop and shutdown sequence |
| **Modify** | `FlashIDA/src/Flash/Parameter.cs` | Remove `UseUnifiedBridge` property; remove any dead configuration accessors that referenced old processor types |
| **Modify** | `FlashIDA/src/Flash/etc/method.xml` | Remove `<UseUnifiedBridge>` element |

**Not changed in this phase:**
- `ScanScheduler.cs` — retained; deletion deferred to Phase 6. Phase 5 handles FAIMS entirely at the C# `ScanScheduler` level (CV cycling, FAIMS-aware target lists). The `faims_cv` field in `ScanCommand` is a Phase 6 struct addition — Phase 5 does NOT add it.
- `FAIMSScanProcessor.cs` FAIMS logic — retained; `ScanScheduler.AddScan()` calls preserved. FAIMS CV values come from method XML config, not from the `ScanCommand` struct.
- All C++ files — zero C++ changes in this phase
- All test data files — reused from Phase 4 (spectrum files `ms1_standard.txt`, `ms2_hcd_fragment.txt`, and `ms1_faims_3cv.txt`). Spectrum files use tab-separated format with RT in seconds (see Phase 0 lesson #2): `Spec scan=N\t<rt_seconds>`. Multi-scan files require parsers to stop at the first scan boundary (see Phase 0 lesson #9)
- Golden files — Phase 4 golden files (`phase4_standard_dda.tsv` through `phase4_ms3_mode3.tsv`) are the regression baseline for P5-R01; golden file changes in this phase are a red flag (see [test-file-specification.md §2.4](../test-file-specification.md)). **Note:** P5-R02 FAIMS golden file capture was removed — `Flash.exe` test mode ignores CVs (see `Phase_5/lessons-learned.md` Lesson 1). FAIMS golden files for Phase 6 must be captured via continuity tests or after test-mode parser is updated to pass CVs to C++.

---

## Test Summary (Quick Reference)

| Test ID | What it verifies and why |
|---------|--------------------------|
| P5-U01 | `UnifiedScanProcessor` can be constructed without error. Confirms the new class compiles correctly, its constructor dependencies are satisfied, and the runtime can load it — the most basic smoke check before any pipeline test. |
| P5-U02 | `IScanProcessor` exposes exactly one method (`ProcessMS`). Guards against accidental re-introduction of `OutputMS` or any other method that would bloat the interface and break the two-stage pipeline contract. |
| P5-U03 | No production `.cs` file references `QuantScanProcessor`. Verifies that the deleted class has been fully purged from the codebase so no dead import or lingering constructor call can cause a compile or runtime failure. |
| P5-U04 | `DataPipe` propagates completion end-to-end from `BufferBlock` to `ActionBlock`. Verifies the two-stage pipeline drains all queued items and terminates cleanly — preventing the process hang that the old null-sentinel pattern was meant to avoid. |
| P5-R01 | All nine acquisition modes (default DDA, deep, inclusion, exclusion, tag-targeting, quant, MS3 modes 1–3) produce output byte-identical to the Phase 4 golden files. Confirms that removing `QuantScanProcessor` and the `UseUnifiedBridge` flag did not change any observable deconvolution results. Each run must produce `[TRACK-CREATE]` entries (CI hard-fail gate). |
| ~~P5-R02~~ | **REMOVED.** `Flash.exe` test mode bypasses `ScanScheduler`/`FAIMSScanProcessor` entirely — CVs in the spectrum are ignored, all scans processed as a single non-FAIMS stream. Both FAIMS configs produce identical output. FAIMS verification in Phase 5 comes from the existing continuity tests (CT09, CT10, CT11) which use the real `FAIMSScanProcessor`/`ScanScheduler` pipeline. See `Phase_5/lessons-learned.md` Lesson 1. |

---

## Test Cases

All 5 tests run on `windows-latest`. No C++ unit tests exist in this phase. The `cpp-unit-tests` CI job is skipped (no C++ file path changes trigger it). P5-R02 was removed — see lessons-learned.md Lesson 1.

| Test ID | Tier | Description | Expected Outcome | Automated by |
|---------|------|-------------|------------------|--------------|
| P5-U01 | 1 (C#) | `UnifiedScanProcessor` compiles and instantiates without error | Constructor completes without throwing; no `TypeLoadException` or `FileNotFoundException` | `ProcessorTests.cs` NUnit test: construct with a mock `FLASHIdaWrapper`, assert no exception |
| P5-U02 | 1 (C#) | `IScanProcessor` interface has exactly one method with the correct signature | Reflection: `typeof(IScanProcessor).GetMethods()` returns exactly 1 entry; method name is `ProcessMS`; parameter type is `IMsScan`; return type is `void` | `InterfaceShapeTests.cs` NUnit test using `System.Reflection` |
| P5-U03 | 1 (C#) | No production code references `QuantScanProcessor` | Static search over `FlashIDA/src/**/*.cs` excluding the test file itself returns zero matches for the string `QuantScanProcessor` | `DeadCodeTests.cs` NUnit test using `System.IO.Directory.GetFiles` + `File.ReadAllText`; fails if any hit found |
| P5-U04 | 1 (C#) | `DataPipe` propagates completion from `BufferBlock` to `ActionBlock` | Post 5 synthetic `IMsScan` mocks, call `DataPipe.Complete()`, await `DataPipe.WaitForCompletion()` with a 5-second timeout; assert all 5 items were processed and no timeout occurred | `DataPipeTests.cs` NUnit test with `Moq` or a hand-rolled `IMsScan` stub |
| P5-R01 | 3 | All acquisition modes produce output identical to Phase 4 golden files | `Flash.exe <input> <output> <method.xml>` with each of the following configs matches the corresponding Phase 4 golden file: `method_default.xml`, `method_deep.xml`, `method_inclusion.xml`, `method_exclusion.xml`, `method_tag_targeting.xml`, `method_quant.xml`, `method_ms3_mode1.xml`, `method_ms3_mode2.xml`, `method_ms3_mode3.xml` — spectrum inputs are `ms1_standard.txt` (all modes) and `ms2_hcd_fragment.txt` (tag-targeting, quant, MS3 modes); comparison via `compare_golden.py` with default tolerances (see [test-file-specification.md §1.2](../test-file-specification.md), [§1.3](../test-file-specification.md), [§2.2](../test-file-specification.md), [§4.1](../test-file-specification.md)); each run must emit `[TRACK-CREATE]` entries in stdout (CI hard-fail gate — Phase 3 F-5 fix) | `regression-runner.ps1` invoked from CI `windows-tests` job |
| ~~P5-R02~~ | ~~3~~ | **REMOVED** — `Flash.exe` test mode ignores CVs; FAIMS coverage is via continuity tests (CT09, CT10, CT11) only | N/A | N/A |

**Regression inherited from Phases 0–4:** All P0-* through P4-* tests must continue to pass. Phase 4 ended at ~70 cumulative tests (~31 new in Phase 4, including 10 continuity tests CT33–CT42). P5 adds 5 tests for a cumulative total of ~75.

---

## CI Configuration

This phase requires no changes to `build-openms-dll.yml`. The C++ DLL artifact from Phase 4 (Build #2) is reused.

Changes to `flashida-ci.yml`:

### Disable `cpp-unit-tests` job for Phase 5 commits

The `cpp-unit-tests` job is conditioned on C++ file changes:

```yaml
cpp-unit-tests:
  runs-on: ubuntu-latest
  if: |
    contains(join(github.event.commits.*.modified, ' '), 'OpenMS/') ||
    contains(join(github.event.commits.*.modified, ' '), '.cpp') ||
    contains(join(github.event.commits.*.modified, ' '), '.h')
```

Phase 5 touches only `*.cs`, `*.csproj`, and `method.xml` files, so this job will be skipped automatically if the condition above is already in place. If the condition does not yet exist, it must be added to avoid unnecessary C++ build attempts.

**Note (Phase 2 established configuration):** The `cpp-unit-tests` job was activated in Phase 2 with the following configuration: CMake flags `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`, ccache key based on `hashFiles('OpenMS/CMakeLists.txt')`, CTest invocation using `-R ClassName` pattern (not `-R FLASH`), and the full apt dependency list documented in `environment-and-workflows.md` Section 1. These settings carry forward unchanged into Phase 5.

### `windows-tests` job — no structural changes needed

The `windows-tests` job already:
- Restores Thermo iAPI DLLs from secrets (Strategy B: openssl-encrypted zip, `THERMO_DLL_PASSPHRASE` secret — see Phase 0 lesson #3)
- OpenMS DLLs are committed in `FlashIDA/dll/` and copied by MSBuild — no download step needed (see Phase 0 lesson #5)
- Runs `msbuild Flash.sln`
- Runs NUnit console runner by full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.X.X/tools/nunit3-console.exe`) with `--agents=1 --timeout=300000` and working directory `FlashIDA/bin/` so native DLLs are found (see Phase 0 lesson #12, Phase 1 lesson #8)
- Sets `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS` in the NUnit test step environment (see Phase 1 lesson #5)
- Runs `regression-runner.ps1`
- Runs `compare_golden.py` for each mode config

No new job steps are required. The new test files (`ProcessorTests.cs`, `InterfaceShapeTests.cs`, `DeadCodeTests.cs`, `DataPipeTests.cs`) are picked up automatically when `Flash.Tests.csproj` is updated to include them.

### `Flash.Tests.csproj` additions

Add the four new test files to the project:

```xml
<Compile Include="ProcessorTests.cs" />
<Compile Include="InterfaceShapeTests.cs" />
<Compile Include="DeadCodeTests.cs" />
<Compile Include="DataPipeTests.cs" />
```

If a mocking library is needed for P5-U04 (e.g., `Moq`), add the NuGet reference:

```xml
<packages>
  <package id="Moq" version="4.20.69" targetFramework="net48" />
</packages>
```

Alternatively, implement a minimal hand-rolled `IMsScan` stub to avoid the dependency.

### No new secrets required

Phase 5 uses the same `THERMO_DLL_PASSPHRASE` secret (Strategy B, openssl — see Phase 0 lesson #3). OpenMS DLLs are committed in `FlashIDA/dll/` (no artifact cache — see Phase 0 lesson #5). No new secrets or caches are needed.

### Branch trigger

The CI workflow's `branches` filter already includes `'phase-*'` patterns. If the development branch is named `phase-5-cs-simplification` or similar, no trigger changes are needed.

---

## Working Product Verification

Verify the following in CI. After pushing Phase 5 changes, confirm the `windows-tests` job passes.

1. **Build succeeds with zero errors and zero warnings.**
   CI step: `msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror`
   Expected: MSBuild exit code 0. No `CS0618` (obsolete) or `CS0168` (unused variable) warnings from deleted code paths.

2. **Test mode runs end-to-end.**
   CI step: `regression-runner.ps1` invokes `Flash.exe ms1_standard.txt output.tsv method_default.xml` and compares output against `phase4_standard_dda.tsv` via `compare_golden.py` (tolerance rules: [test-file-specification.md §4.1](../test-file-specification.md)). Entry point is `FLASHIdaWrapper.Main()` — no `-t` flag (see Phase 0 lesson #1).
   Expected: Exit code 0, output matches Phase 4 golden file. Stdout must contain `[TRACK-CREATE]` entries (CI hard-fail gate — Phase 3 F-5 fix).

3. **FAIMS mode verified via continuity tests (not regression runner).**
   FAIMS regression via `Flash.exe` was removed (P5-R02) because test mode ignores CVs. FAIMS verification comes from continuity tests CT09, CT10, CT11 which exercise the real `FAIMSScanProcessor`/`ScanScheduler` pipeline with mock instruments and real per-CV spectral data from `ms1_faims_3cv.txt`.

4. **DataPipe completion is clean.**
   CI step: NUnit test P5-U04 in `DataPipeTests.cs` posts 5 synthetic `IMsScan` mocks, calls `DataPipe.Complete()`, and awaits `DataPipe.WaitForCompletion()` with a 5-second timeout.
   Expected: All 5 items processed, no timeout. A timeout here would indicate the `ActionBlock` completion is not being propagated correctly from the `BufferBlock`.

5. **Dead code confirmed absent.**
   CI step: NUnit test P5-U03 in `DeadCodeTests.cs` performs a static search over `FlashIDA/src/**/*.cs` for `QuantScanProcessor`, `OutputMS`, and `UseUnifiedBridge`. This is automated by P5-U03 in CI. No local grep required.
   Expected: Zero hits in production code for each pattern.

6. **NUnit suite passes.**
   CI step: NUnit console runner invoked by full NuGet packages path from working directory `FlashIDA/bin/` with `--agents=1 --timeout=300000` and `OPENMS_DATA_PATH` set (see Phase 0 lesson #12, Phase 1 lessons #5 and #8). Run by the `windows-tests` job.
   Expected: All prior-phase tests plus 5 Phase 5 tests pass, 0 failures, 0 errors. (Phase 4 ended at ~70 cumulative; Phase 5 target is ~75 cumulative.)

---

## Phase 0-2 Lessons Applied

The following lessons from Phase 0, Phase 1, and Phase 2 are relevant to Phase 5 implementation. Cross-references are to `Phase_0/lessons-learned.md`, `Phase_1/lessons-learned.md`, and Phase 2 implementation notes.

### Phase 0 Lessons

| Lesson | Summary | Where applied in this plan |
|--------|---------|---------------------------|
| #1 | No `-t` flag; entry point is `FLASHIdaWrapper.Main()` | Prerequisites §2, P5-R01/R02 test descriptions, Working Product Verification §2/§3 |
| #2 | Spectrum files: tab-separated, RT in seconds | "Not changed" notes on test data files |
| #3 | Thermo DLL Strategy B (openssl, `THERMO_DLL_PASSPHRASE`) | CI Configuration §No new secrets |
| #4 | `.gitattributes` binary entries for new extensions | Note below |
| #5 | OpenMS DLLs committed in `FlashIDA/dll/`, no download step | Prerequisites §4, CI Configuration §windows-tests |
| #9 | Multi-scan parsers must stop at first scan boundary | "Not changed" notes on test data files |
| #10 | Use `Console.WriteLine()` for CI-visible diagnostics | General guidance for any new test code |
| #12 | NUnit runner: full NuGet packages path, working directory `FlashIDA/bin/` | CI Configuration §windows-tests, Working Product Verification §6 |
| #14 | Silent zero-result P/Invoke failures — log input data characteristics | Note below |
| #15 | Golden-file capture: 2-commit minimum; batch same-side changes | "Not changed" golden files note; general commit strategy |

### Phase 1 Lessons

| Lesson | Summary | Where applied in this plan |
|--------|---------|---------------------------|
| #1 | Submodule pointer must be updated after every submodule push | Submodule pointer updates note above |
| #2 | Test data path: `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/` | Note below; applies to all new test classes |
| #4 | Never remove `ModificationsDB::getInstance()` calls — initialization side effect | Note below (no C++ changes this phase, but relevant if debugging DLL crashes) |
| #5 | `OPENMS_DATA_PATH` must be set in every CI step that invokes OpenMS | CI Configuration §windows-tests, Working Product Verification §6 |
| #8 | NUnit: `--agents=1 --timeout=300000` to handle `calculateAveragine` cold cache | CI Configuration §windows-tests, Working Product Verification §6 |
| #10 | DLL build takes ~40 min; batch all C++ changes before pushing | Not applicable (no DLL build this phase); note retained for cross-phase awareness |
| #11 | Both `FLASHIdaWrapper` constructors exist; prefer `FLASHIdaWrapper(MethodParameters)` | Note below |

### Phase 2 Lessons

| Lesson | Summary | Where applied in this plan |
|--------|---------|---------------------------|
| `toSpectrum()` return-value API | `DeconvolvedSpectrum::toSpectrum()` returns `MSSpectrum` by value, not void with out-param. Signature: `MSSpectrum toSpectrum(int to_charge, double tol = 10.0, bool retain_undeconvolved = false)` | Not directly applicable (no C++ tests in Phase 5), but relevant if future phases reference Phase 5 as a baseline |
| `DeconvolvedSpectrum` constructor takes `scan_number` | Constructor is `explicit DeconvolvedSpectrum(int scan_number)`, not `ms_level` | Not directly applicable (no C++ tests in Phase 5) |
| PeakGroup prerequisite for `toSpectrum()` | `toSpectrum()` unconditionally accesses `peak_groups_[0]` — any test calling `toSpectrum()` must push a `PeakGroup` first | Not directly applicable (no C++ tests in Phase 5) |
| CTest naming convention | Use `ctest -R ClassName` (e.g., `-R DeconvolvedSpectrum_OptimizationMetadata`), not `ctest -R FLASH` | CI Configuration — `cpp-unit-tests` job (Phase 5 does not add C++ tests, but existing tests continue running with this convention) |
| CI apt dependencies (ubuntu) | Full list: `build-essential ccache ninja-build qt6-base-dev libeigen3-dev libboost-random-dev libboost-regex-dev libboost-iostreams-dev libboost-date-time-dev libboost-math-dev libxerces-c-dev zlib1g-dev libsvm-dev libbz2-dev liblzma-dev libzstd-dev coinor-libcoinmp-dev` | CI Configuration — `cpp-unit-tests` job (already established, no changes needed) |
| CMake flags | `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja` | CI Configuration — `cpp-unit-tests` job |
| ccache key | Uses `hashFiles('OpenMS/CMakeLists.txt')`, not `executables.cmake` | CI Configuration — `cpp-unit-tests` job cache key |
| MSVC `/WX` compliance | Use `(void)var;` to suppress unused variable warnings in C++ test code | Not directly applicable (no C++ tests in Phase 5); relevant for Phase 6+ |
| Phase 2 deliverables | `OptimizationMetadata` struct (18 fields, `std::optional`), `GetConfigInt`/`GetConfigDouble` bridge functions, 5 C++ unit tests, `cpp-unit-tests` CI job active. Phase 2 cumulative: 59 tests; Phase 4 cumulative: ~70 tests | Prerequisites §5 |

**`.gitattributes` (lesson #4):** If any new binary file extensions are introduced in Phase 5 (unlikely, since no new test data is created), add corresponding `*.ext binary` entries to `FlashIDA/.gitattributes` before committing.

**Silent P/Invoke failures (lesson #14):** The C++ deconvolution engine returns 0 results without error when input data is malformed. If any new code calls bridge functions (e.g., `UnifiedScanProcessor.ProcessMS` calling `ProcessScan`) and receives 0 results unexpectedly, log the input data characteristics (RT, peak count, first/last m/z) before investigating engine internals. The bridge functions in `OpenMS.dll` do not distinguish "no results found" from "input data is malformed."

**Submodule pointer updates (Phase 1 lesson #1):** After pushing to any submodule branch, always `git add FlashIDA OpenMS` in the parent repo and push the pointer update. CI checks out submodules at the pointer commit, not at branch HEAD — new files are silently invisible to CI until the pointer is updated.

**Submodule batching (Phase 0 lesson #15):** Phase 5 has no C++ changes, but if any submodule pointer updates are needed (e.g., to pick up Phase 4 DLL changes), batch all C#-side changes before updating the submodule pointer to minimize churn.

**Test tier convention (Phase 0 lesson #12 addendum):** P5-U01 through P5-U04 are Tier 1 (pure C# unit tests with mocks). If any test in this phase loads `OpenMS.dll` or calls bridge functions, it must be classified as Tier 2, matching the convention established in Phase 0 for DLL-dependent tests.

**Test data path (Phase 1 lesson #2):** `TestContext.CurrentContext.TestDirectory` resolves to `FlashIDA/bin/`. All new test classes (`ProcessorTests.cs`, `InterfaceShapeTests.cs`, `DeadCodeTests.cs`, `DataPipeTests.cs`) that load files from `FlashIDA/test-data/` must use `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/`. Using `"..\..\test-data"` navigates to the parent repo root, not `FlashIDA/`.

**ModificationsDB singleton (Phase 1 lesson #4):** No C++ changes occur in this phase, so `ModificationsDB::getInstance()` is not touched. If any unexpected DLL crash occurs with `Cannot find shared data!`, do not comment out or remove any OpenMS singleton initializer call — use a `(void)` cast instead. The call has an initialization side effect even when the return value is unused.

**Constructor preference (Phase 1 lesson #11):** Both `FLASHIdaWrapper(MethodParameters)` and `FLASHIdaWrapper(IDAParameters)` constructors exist. New test code in this phase that constructs `FLASHIdaWrapper` (e.g., the mock in P5-U01) must use `FLASHIdaWrapper(MethodParameters)` — the new overload that uses JSON config. The legacy `FLASHIdaWrapper(IDAParameters)` constructor is preserved for backward compatibility only.

**DLL name in P/Invoke (Phase 0 lesson #12):** The P/Invoke `[DllImport]` attribute must use `"OpenMS.dll"` with the extension, not `"OpenMS"`. This is the form already in `FLASHIdaWrapper.cs` and must not be changed when adding any new P/Invoke declarations.

---

## Definition of Done

- [ ] `UnifiedScanProcessor.cs` created; `ProcessMS` extracts centroids, calls `wrapper.ProcessScan`, returns void
- [ ] `IScanProcessor.cs` has exactly 1 method: `void ProcessMS(IMsScan)`; `OutputMS` removed
- [ ] `QuantScanProcessor.cs` deleted; `FlashIDA/src/` contains zero references to `QuantScanProcessor` in production code
- [ ] `DataPipe.cs` uses `BufferBlock<IMsScan>` -> `ActionBlock<IMsScan>`; `TransformManyBlock` removed; null-sentinel pattern removed; `PropagateCompletion = true` set on the link
- [ ] `FAIMSScanProcessor.cs` updated to remove `OutputMS` implementation; delegates `ProcessMS` to `UnifiedScanProcessor`; `ScanScheduler` integration preserved
- [ ] `Flash.cs` no longer contains `UseUnifiedBridge` conditional; always uses `UnifiedScanProcessor` as the base processor; `GetNextScanCommand` loop and shutdown sequence unchanged
- [ ] `Parameter.cs` (or `MethodConfig.cs`) no longer has `UseUnifiedBridge` property
- [ ] `method.xml` no longer contains `<UseUnifiedBridge>` element
- [ ] `ScanScheduler.cs` is still present and still used by `FAIMSScanProcessor`
- [ ] All 5 Phase 5 tests pass in CI: P5-U01, P5-U02, P5-U03, P5-U04, P5-R01
- [ ] All prior-phase tests (P0-* through P4-*) continue to pass in CI (Phase 4 ended at ~70 cumulative; Phase 5 target is ~75 cumulative)
- [ ] P5-R01 produces `[TRACK-CREATE]` entries in stdout (CI hard-fail gate — Phase 3 F-5 fix)
- [ ] CI `windows-tests` job green on `windows-latest` with Build #2 DLL artifact
- [ ] `msbuild /warnaserror` succeeds with zero warnings
- [ ] No process hang on `DataPipe.WaitForCompletion()` in test mode
- [ ] `ScanCommand` struct size matches Phase 4 value of **1240 bytes** (includes `enqueue_timestamp_ms` and 11 scoring fields; no longer 1144 bytes)
- [ ] `faims_cv` is NOT present in `ScanCommand` (deferred to Phase 6)
- [ ] Phase 5 branch merged; ready for Phase 6 (FAIMS Absorption, Build #3)

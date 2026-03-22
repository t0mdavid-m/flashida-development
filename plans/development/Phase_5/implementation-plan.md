# Phase 5: C# Simplification — Implementation Plan

**Date:** 2026-03-21
**Phase:** 5 of 8
**Build produced:** None (C#-only changes)
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 6 (Simplified C# Architecture), Phase 5 specification
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 5 section
- [../testing-strategy.md](../testing-strategy.md) — Phase 5 test plan

---

## Goal

Simplify the C# architecture now that `ProcessScan` and `GetNextScanCommand` handle all scan decision logic. Three existing scan processor classes are replaced by a single `UnifiedScanProcessor`. The `DataPipe` pipeline collapses from three stages to two. The `OutputMS` method and its null-sentinel completion pattern are removed. The `UseUnifiedBridge` feature flag is removed because the unified path is now the only supported path. `QuantScanProcessor.cs` is deleted.

`ScanScheduler` is explicitly retained in this phase. It remains the owner of FAIMS CV cycling until Phase 6 absorbs that responsibility into C++.

No C++ code is touched. The Build #2 artifact (`OpenMS.dll`) from Phase 4 is reused unchanged.

---

## Prerequisites

All of the following must be verified before beginning Phase 5 work.

1. **Phase 4 switch-over confirmed for all modes.** `UseUnifiedBridge=True` must pass all Phase 4 regression tests:
   - P4-R02 standard DDA
   - P4-R03 deep mode
   - P4-R04 inclusion list
   - P4-R05 exclusion list
   - P4-R06 tag-based targeting
   - P4-R07 isobaric quant
   - P4-R08, P4-R09, P4-R10 MS3 modes 1–3

2. **FAIMS regression passing.** `Flash.exe -t` with `method_faims_3cv.xml` produces correct output under `UseUnifiedBridge=True`. (FAIMS still runs through `ScanScheduler` at this point; this must be verified before that dependency is removed.)

3. **Phase 4 golden files committed.** The golden files produced with `UseUnifiedBridge=True` are the regression baseline for Phase 5. They must be committed to `FlashIDA/test-data/golden/` and referenced by `P5-R01` and `P5-R02`.

4. **Build #2 OpenMS DLL artifact available.** The cached artifact from `build-openms-dll.yml` keyed to the Phase 4 OpenMS submodule commit hash must be downloadable by CI. No new C++ build is triggered in this phase.

5. **All prior phase tests green.** The CI suite for Phases 0–4 (cumulative: 58 tests) must be passing on the branch before Phase 5 work begins.

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
- `FlashIDA/src/Flash/etc/method.xml` — remove `<UseUnifiedBridge>` element

---

### Step 6: Update `FAIMSScanProcessor.cs` for the New Interface

`FAIMSScanProcessor` still exists and is still used in this phase. It implements `IScanProcessor` and delegates the actual deconvolution work to an inner processor. Because `IScanProcessor` no longer has `OutputMS`, the `FAIMSScanProcessor` implementation must be updated:

- Remove its `OutputMS` implementation.
- Ensure its `ProcessMS(IMsScan)` delegates to the inner processor's `ProcessMS` (which is now `UnifiedScanProcessor`). The FAIMS-specific scheduling via `ScanScheduler.AddScan()` is preserved here; this is intentional and remains until Phase 6.

`FAIMSScanProcessor` must still implement the simplified `IScanProcessor` interface (one method only). If it currently has additional helper methods, those are unaffected.

**File to modify:** `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs`

---

### Step 7: Remove Null-Sentinel Completion Pattern from All Processors

Search for all call sites of the null-sentinel pattern (posting `null` to a `BufferBlock` or `TransformManyBlock` as an end-of-stream signal). These call sites exist because the old `TransformManyBlock` used a null scan to signal that `OutputMS` should complete. With the two-stage `ActionBlock` pipeline, completion is propagated by calling `BufferBlock.Complete()` directly. Remove all null posts and any associated null checks in `ProcessMS` implementations.

This affects any scan processor that previously checked `if (msScan == null)` at the top of `ProcessMS` to handle the sentinel. Those guards must be removed because `ActionBlock` will never deliver a null item when using `PropagateCompletion`.

Verify that the overall shutdown sequence in `Flash.cs` calls `dataPipe.Complete()` (which calls `inputScans.Complete()`) and then awaits `dataPipe.WaitForCompletion()` to drain the pipeline before disposing the `FLASHIdaWrapper`. The ordering of these calls must be preserved.

**Files to verify/modify:** All `IScanProcessor` implementations, `Flash.cs` shutdown sequence.

---

### Step 8: Verify No Remaining References to Deleted Items

Before committing, run the following checks locally to confirm clean deletion:

1. Search all `*.cs` files under `FlashIDA/src/` for the string `QuantScanProcessor`. Expect zero hits outside of test files that assert its absence.
2. Search for `OutputMS` in `*.cs` files. Expect zero hits outside of comments and the test file for P5-U02.
3. Search for `UseUnifiedBridge` in `*.cs` and `*.xml` files. Expect zero hits.
4. Search for `TransformManyBlock` in `*.cs` files. Expect zero hits.
5. Confirm `ScanScheduler` is still referenced (it must be — it is not removed until Phase 6).

These checks are also automated by CI test P5-U03 (grep for `QuantScanProcessor`) but running them locally before push avoids a wasted CI round-trip.

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
- `ScanScheduler.cs` — retained; deletion deferred to Phase 6
- `FAIMSScanProcessor.cs` FAIMS logic — retained; `ScanScheduler.AddScan()` calls preserved
- All C++ files — zero C++ changes in this phase
- All test data files — reused from Phase 4
- Golden files — Phase 4 golden files are the regression baseline; no new golden files needed for P5-R01 and P5-R02 beyond those already committed

---

## Test Cases

All 6 tests run on `windows-latest`. No C++ unit tests exist in this phase. The `cpp-unit-tests` CI job is skipped (no C++ file path changes trigger it).

| Test ID | Tier | Description | Expected Outcome | Automated by |
|---------|------|-------------|------------------|--------------|
| P5-U01 | 1 (C#) | `UnifiedScanProcessor` compiles and instantiates without error | Constructor completes without throwing; no `TypeLoadException` or `FileNotFoundException` | `ProcessorTests.cs` NUnit test: construct with a mock `FLASHIdaWrapper`, assert no exception |
| P5-U02 | 1 (C#) | `IScanProcessor` interface has exactly one method with the correct signature | Reflection: `typeof(IScanProcessor).GetMethods()` returns exactly 1 entry; method name is `ProcessMS`; parameter type is `IMsScan`; return type is `void` | `InterfaceShapeTests.cs` NUnit test using `System.Reflection` |
| P5-U03 | 1 (C#) | No production code references `QuantScanProcessor` | Static search over `FlashIDA/src/**/*.cs` excluding the test file itself returns zero matches for the string `QuantScanProcessor` | `DeadCodeTests.cs` NUnit test using `System.IO.Directory.GetFiles` + `File.ReadAllText`; fails if any hit found |
| P5-U04 | 1 (C#) | `DataPipe` propagates completion from `BufferBlock` to `ActionBlock` | Post 5 synthetic `IMsScan` mocks, call `DataPipe.Complete()`, await `DataPipe.WaitForCompletion()` with a 5-second timeout; assert all 5 items were processed and no timeout occurred | `DataPipeTests.cs` NUnit test with `Moq` or a hand-rolled `IMsScan` stub |
| P5-R01 | 3 | All acquisition modes produce output identical to Phase 4 golden files | `Flash.exe -t` with each of the following configs matches the corresponding Phase 4 golden file: `method_default.xml`, `method_deep.xml`, `method_inclusion.xml`, `method_exclusion.xml`, `method_tag_targeting.xml`, `method_quant.xml`, `method_ms3_mode1.xml`, `method_ms3_mode2.xml`, `method_ms3_mode3.xml` — comparison via `compare_golden.py` with default tolerances | `regression-runner.ps1` invoked from CI `csharp-tests` job |
| P5-R02 | 3 | FAIMS mode still works via `ScanScheduler` | `Flash.exe -t` with `method_faims_3cv.xml` matches the Phase 4 FAIMS golden file; CV transition log entries present; no crash or missing output rows | `regression-runner.ps1` FAIMS config entry |

**Regression inherited from Phases 0–4:** All P0-* through P4-* tests (58 tests) must continue to pass. P5 adds 6 tests for a cumulative total of 64.

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

### `csharp-tests` job — no structural changes needed

The `csharp-tests` job already:
- Restores Thermo iAPI DLLs from secrets
- Downloads the OpenMS DLL artifact (cached by submodule hash)
- Runs `msbuild Flash.sln`
- Runs `nunit3-console Flash.Tests.dll`
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

Phase 5 uses the same `THERMO_IAPI_DLLS_BASE64` (or `THERMO_DLL_PASSPHRASE`) and OpenMS DLL artifact cache that were established in earlier phases. No new secrets or caches are needed.

### Branch trigger

The CI workflow's `branches` filter already includes `'phase-*'` patterns. If the development branch is named `phase-5-cs-simplification` or similar, no trigger changes are needed.

---

## Working Product Verification

After all implementation steps are complete and CI is green, verify the following manually on a Windows development machine before declaring Phase 5 done:

1. **Build succeeds with zero errors and zero warnings.**
   Run: `msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU" /warnaserror`
   Expected: MSBuild exit code 0. No `CS0618` (obsolete) or `CS0168` (unused variable) warnings from deleted code paths.

2. **Test mode runs end-to-end.**
   Run: `Flash.exe -t test-data/spectra/ms1_standard.txt output.tsv test-data/configs/method_default.xml`
   Expected: Exit code 0, `output.tsv` is non-empty, row count matches Phase 4 golden file.

3. **FAIMS mode runs end-to-end.**
   Run: `Flash.exe -t test-data/spectra/ms1_standard.txt output_faims.tsv test-data/configs/method_faims_3cv.xml`
   Expected: Exit code 0, CV transition log entries appear in stdout, output matches FAIMS golden file.

4. **DataPipe completion is clean.**
   Confirm no process hangs after all spectra are processed. The `WaitForCompletion()` call must return promptly (within 2 seconds) after the input file is exhausted. A hang here would indicate that the `ActionBlock` completion is not being propagated correctly from the `BufferBlock`.

5. **Dead code confirmed absent.**
   Run the following searches in `FlashIDA/src/`:
   - `grep -r "QuantScanProcessor" --include="*.cs"` — expect 0 hits in production code, exactly 1 hit in the P5-U03 test
   - `grep -r "OutputMS" --include="*.cs"` — expect 0 hits in production code
   - `grep -r "UseUnifiedBridge" --include="*.cs" --include="*.xml"` — expect 0 hits everywhere

6. **NUnit suite passes.**
   Run: `nunit3-console FlashIDA/src/Flash.Tests/bin/Debug/Flash.Tests.dll`
   Expected: 64 tests pass, 0 failures, 0 errors.

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
- [ ] All 6 Phase 5 tests pass: P5-U01, P5-U02, P5-U03, P5-U04, P5-R01, P5-R02
- [ ] All 58 prior-phase tests (P0-* through P4-*) continue to pass
- [ ] CI `csharp-tests` job green on `windows-latest` with Build #2 DLL artifact
- [ ] `msbuild /warnaserror` succeeds with zero warnings
- [ ] No process hang on `DataPipe.WaitForCompletion()` in test mode
- [ ] Phase 5 branch merged; ready for Phase 6 (FAIMS Absorption, Build #3)

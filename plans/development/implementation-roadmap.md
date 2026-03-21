# Implementation Roadmap

**Date:** 2026-03-21
**Source documents:**
- [baseline-plan.md](baseline-plan.md) -- architecture design and phased migration (v9)
- [testing-strategy.md](testing-strategy.md) -- per-phase test plans and CI infrastructure

---

## Overview

This roadmap migrates FLASHIda from a ~20-function P/Invoke bridge with C#-side scan orchestration to a 5-function bridge where C++ owns the scan queue. The two entry points after migration are `ProcessScan` (C# feeds spectra) and `GetNextScanCommand` (C# retrieves one command at a time). All scan scheduling, priority management, FAIMS CV cycling, and parameter exploration move into C++. Full method configuration is passed as JSON.

**Why:** The current architecture splits decision-making across languages, creates race conditions (e.g., `GetPeakGroupSize`/`GetIsolationWindows` size mismatch), prevents C++ from owning queue priorities, and makes new MSn modes difficult to add. The unified architecture eliminates these problems while enabling parameter exploration (CE optimization) as new functionality.

**Build batching strategy:** C++ builds are expensive (30-60 min). The 9 phases (0-8) are grouped into 4 C++ builds. Phases that require no C++ build (Phase 0 baseline capture, Phase 5 C#-only refactor) ship without a build. Each phase produces a working, testable product -- the application must pass all prior-phase regression tests plus new phase-specific tests.

---

## Build Batching Summary

| Build | Phases | What ships | Risk | C++ changes |
|-------|--------|------------|------|-------------|
| (none) | Phase 0 | Test infrastructure, baseline golden files | None | None |
| Build #1 | Phases 1 + 2 + 3 | JSON config, OptimizationMetadata, ScanCommand struct, ProcessScan stub, shadow validation | Low -- no behavioral change, old path still active | JSON parsing, metadata struct, bridge stubs, priority queue |
| Build #2 | Phase 4 | Full ProcessScan routing, switch-over from old bridge | **High** -- all modes must work through new path | Full processScan implementation, all mode routing |
| (none) | Phase 5 | C# simplification, UnifiedScanProcessor | Low -- C#-only refactor | None |
| Build #3 | Phase 6 | FAIMS CV cycling in C++, ScanScheduler deleted | **High** -- adaptive CV logic must be exact | FAIMS state machine, updateCV logic |
| Build #4 | Phases 7 + 8 | Exploration engine, old bridge cleanup, final form | Medium -- new functionality + dead code removal | Exploration engine, legacy removal |

See [baseline-plan.md SS Build Batching](baseline-plan.md#build-batching) for the original table.

---

## Phase 0: Establish Baseline

**Goal:** Capture current behavior before any migration. Create test infrastructure.

**Issues addressed:** None (preparation only).

**What changes:**
- Create NUnit test project (`Flash.Tests.csproj`).
- Create minimal test spectrum (`ms1_smoke_test.txt`).
- Capture golden file (`baseline_phase0.tsv`) from `Flash.exe -t` output.
- Set up CI workflow skeleton.

**Test coverage (7 tests):**
- Unit/smoke: P0-U01 through P0-U04 (build verification, test mode execution).
- Integration: P0-I01, P0-I02 (bridge smoke: CreateFLASHIda/DisposeFLASHIda do not crash).
- Regression: P0-R01 (golden file capture).
- See [testing-strategy.md SS Phase 0](testing-strategy.md#phase-0-establish-baseline) for the complete test matrix.

**Working product verification:**
1. Solution builds without error.
2. `Flash.exe -t` runs and produces valid TSV output.
3. Bridge calls (Create/Dispose) complete without crash.
4. Golden baseline captured and committed.

**Build produced:** None.

**Dependencies:** None -- this is the starting point.

---

## Phase 1: JSON Configuration

**Goal:** Full JSON config serialization on C# side; C++ auto-detects JSON vs. legacy format.

**Issues addressed:** Issue 8 (JSON Configuration Bridge). See [baseline-plan.md SS Issue 8](baseline-plan.md#issue-8--full-json-configuration) for full specification.

**What changes:**
- `Parameter.cs` gains `ToJSON()` serializing the full `method.xml` content.
- `FLASHIdaWrapper.cs` passes JSON to `CreateFLASHIda`.
- C++ constructor auto-detects format: JSON parsed via `nlohmann_json`, legacy path untouched.
- New `MethodConfig.cs` typed model for JSON serialization.

**Test coverage (10 tests):**
- Unit: P1-U01 through P1-U05 (JSON validity, field completeness, round-trip).
- Integration: P1-I01 through P1-I03 (C++ accepts JSON, legacy fallback, parsed values verification).
- Regression: P1-R01, P1-R02 (JSON and legacy configs produce identical output to Phase 0 golden).
- See [testing-strategy.md SS Phase 1](testing-strategy.md#phase-1-json-configuration) for the complete test matrix.

**Working product verification:**
1. `Flash.exe -t` runs with JSON config -- results identical to legacy.
2. Round-trip: `method.xml` -> `ToJSON()` -> C++ parse -> fields match.
3. Legacy format auto-detect fallback still works.

**Build produced:** Part of Build #1 (batched with Phases 2 and 3).

**Dependencies:** Phase 0 (baseline golden files exist for regression comparison).

---

## Phase 2: OptimizationMetadata

**Goal:** Add `OptimizationMetadata` struct to `DeconvolvedSpectrum`. Purely additive, zero overhead when disabled.

**Issues addressed:** Issue 9 (Acquisition Metadata on DeconvolvedSpectrum). See [baseline-plan.md SS Issue 9](baseline-plan.md#issue-9--acquisition-metadata-on-deconvolvedspectrum) for full specification.

**What changes:**
- New `OptimizationMetadata.h` struct definition.
- `DeconvolvedSpectrum.h/.cpp` gains `std::optional<OptimizationMetadata>` and accessors.
- `toSpectrum()` serializes metadata via `setMetaValue()` when present.

**Test coverage (6 tests):**
- Unit (C++): P2-U01 through P2-U05 (default state, creation, field defaults, serialization, no-metadata case).
- Regression: P2-R01 (output unchanged -- no code populates metadata yet).
- See [testing-strategy.md SS Phase 2](testing-strategy.md#phase-2-optimizationmetadata) for the complete test matrix.

**Working product verification:**
1. `Flash.exe -t` runs with no behavioral change.
2. C++ unit tests confirm metadata accessors work correctly.
3. `hasOptimizationMetadata()` returns false in normal operation.

**Build produced:** Part of Build #1.

**Dependencies:** Phase 1 (batched together; no functional dependency).

---

## Phase 3: ScanCommand Struct + Bridge Stubs

**Goal:** Define ScanCommand/IsolationStage structs, implement ProcessScan stub and GetNextScanCommand with priority queue, implement GetNextTrackingId. Old bridge functions remain active; new functions run in shadow mode.

**Issues addressed:** Issues 1 (Unified ProcessScan Bridge), 2 (ScanCommand Struct), 3 (C++ Scan Queue) -- initial implementations. See [baseline-plan.md SS Issue 1](baseline-plan.md#issue-1--unified-processscan-bridge), [SS Issue 2](baseline-plan.md#issue-2--scancommand-struct), [SS Issue 3](baseline-plan.md#issue-3--c-owns-the-scan-queue) for full specifications.

**What changes:**
- C++ structs: `ScanCommand`, `IsolationStage`, priority queue, `queue_mutex_`, tracking ID counter, `pending_scan_map_`.
- C++ bridge exports: `ProcessScan` (stub, returns 0), `GetNextScanCommand` (full priority dequeue but queue always empty), `GetNextTrackingId`.
- C# P/Invoke declarations for 3 new functions alongside existing 18.
- C# `ScanFactory.BuildFromCommand()` translating ScanCommand to `IFusionCustomScan`.
- Shadow validation: C# calls both old and new paths, logs discrepancies, trusts old results.

**Test coverage (16 tests):**
- Unit (C#): P3-U01 through P3-U04 (struct size, field offsets, string field sizes).
- Unit (C++): P3-U05 through P3-U10 (tracking ID encoding, uniqueness, empty-queue MS1 fallback, priority order, AGC priority, timeout cleanup).
- Integration: P3-I01 through P3-I05 (marshaling round-trip, ProcessScan stub return, GetNextScanCommand struct, tracking ID incrementing, DLL export verification).
- Regression: P3-R01 (output unchanged, TRACK log entries present).
- See [testing-strategy.md SS Phase 3](testing-strategy.md#phase-3-scancommand-struct--bridge-stubs-build-1) for the complete test matrix.

**Working product verification:**
1. `Flash.exe -t` runs with all existing behavior unchanged; shadow calls produce TRACK log entries.
2. ScanCommand struct marshaling verified: C# and C++ agree on layout.
3. `GetNextScanCommand` returns MS1 (queue empty fallback).
4. Tracking IDs: sequential base-36, no collisions across 10,000 calls.

**Build produced:** Build #1 (ships Phases 1 + 2 + 3).

**Dependencies:** Phases 1 and 2 (batched into same build).

---

## Phase 4: ProcessScan Full Routing -- The Switch-Over

**Goal:** Full ProcessScan implementation handling all MS1/MS2 modes. After verification, C# switches from old bridge functions to ProcessScan + GetNextScanCommand. Feature flag `UseUnifiedBridge` controls the switch.

**Issues addressed:** Issues 1 (completion) and 5 (Scoring in Unified Architecture). See [baseline-plan.md SS Phase 4](baseline-plan.md#phase-4-processscan-full-routing--the-switch-over-build-2) and [SS Issue 5](baseline-plan.md#issue-5--scoring-in-the-unified-architecture) for full specification.

**Modes that must work after switch-over:**
- Standard DDA, deep mode, inclusion list, exclusion list
- Tag-based targeting, conditional MS2 follow-ups
- Isobaric quant filtering (`isDifferentiallyAbundant`)
- MS3 in all 4 modes (Source CID, SPS, HCD-triggered, EThcD-triggered)

**What changes:**
- C++ `processScan()`: MS1 path (deconvolve, score/sort all 6 branches, filter, select top N, push MS2 commands) and MS2 path (resolve tracking ID, deconvolve, route by mode, MS3 targeting).
- C++ command priorities: MS3 = 3, conditional follow-ups = 2, standard MS2 = 1, exploration = 0.
- C# switch-over: replace multi-step bridge call sequences with single ProcessScan + GetNextScanCommand loop.
- Feature flag: `<UseUnifiedBridge>True</UseUnifiedBridge>` in `method.xml`.

**Test coverage (19 tests):**
- Unit (C++): P4-U01 through P4-U09 (MS1 deconvolution + command push, all 6 scoring branches, mass exclusion, tracking resolution, MS3 targets, conditional follow-ups, quant routing, tag targeting, audit trail completeness).
- Integration: P4-I01, P4-I02 (feature flag off = old behavior, feature flag on = new behavior).
- Regression: P4-R01 through P4-R10 (flag-off regression, then each mode individually with flag on: standard DDA, deep, inclusion, exclusion, tag targeting, quant, MS3 modes 1-3).
- See [testing-strategy.md SS Phase 4](testing-strategy.md#phase-4-processscan-full-routing--the-switch-over-build-2) for the complete test matrix.

**Working product verification:**
1. `UseUnifiedBridge=False` produces identical output to Phase 3.
2. `UseUnifiedBridge=True` standard DDA matches old behavior.
3. Each mode works individually with unified bridge.
4. TRACK audit trail: every command has CREATE, every resolved scan has RESOLVE.
5. Race condition eliminated: atomic command count return.

**Build produced:** Build #2.

**Dependencies:** Phase 3 (Build #1 must be verified).

---

## Phase 5: C# Simplification

**Goal:** Simplify C# architecture now that ProcessScan + GetNextScanCommand handle all logic. UnifiedScanProcessor replaces 3 existing processors. DataPipe collapses to 2 stages.

**Issues addressed:** Issue 6 (Simplified C# Architecture). See [baseline-plan.md SS Issue 6](baseline-plan.md#issue-6--simplified-c-architecture) for full specification.

**What changes:**
- New `UnifiedScanProcessor.cs`: single `ProcessMS(IMsScan)` that extracts centroids and calls ProcessScan.
- `IScanProcessor` simplified to `void ProcessMS(IMsScan)` (OutputMS removed).
- `DataPipe` collapses to `BufferBlock<IMsScan>` -> `ActionBlock<IMsScan>`.
- Delete `QuantScanProcessor.cs`.
- Remove `UseUnifiedBridge` feature flag (unified path is now the only path).
- ScanScheduler remains for FAIMS CV cycling until Phase 6.

**Test coverage (6 tests):**
- Unit (C#): P5-U01 through P5-U04 (UnifiedScanProcessor instantiation, IScanProcessor interface shape, QuantScanProcessor references gone, DataPipe completion propagation).
- Regression: P5-R01 (all modes identical to Phase 4), P5-R02 (FAIMS still works via ScanScheduler).
- See [testing-strategy.md SS Phase 5](testing-strategy.md#phase-5-c-simplification-no-c-build) for the complete test matrix.

**Working product verification:**
1. All modes produce identical results to Phase 4.
2. DataPipe correctly propagates completion.
3. FAIMS mode still works (ScanScheduler still active).
4. `QuantScanProcessor` has zero remaining references.

**Build produced:** None (C#-only changes).

**Dependencies:** Phase 4 (switch-over must be verified for all modes).

---

## Phase 6: FAIMS Absorption -- Highest Risk

**Goal:** Port FAIMS CV cycling logic to C++. Delete FAIMSScanProcessor and ScanScheduler. This completes C++ ownership of the full scan queue.

**Issues addressed:** Issue 3 (completion -- C++ Owns the Scan Queue, FAIMS portion). See [baseline-plan.md SS Phase 6](baseline-plan.md#phase-6-faims-absorption--highest-risk-build-3) for full specification.

**Critical behaviors to preserve:**
- Adaptive CV skipping (precursor count threshold logic from `updateCV`).
- CV cycling order and skip limits from config.
- CV transition injects MS1 with new CV before pending MS2s.

**What changes:**
- C++ FAIMS CV state machine: `faims_cv_values_`, `current_cv_index_`, `updateCV_()` with adaptive skipping.
- `GetNextScanCommand` injects CV into every `ScanCommand.faims_cv`.
- CV transition handling at queue level.
- Delete `FAIMSScanProcessor.cs` and `ScanScheduler.cs`.

**Test coverage (13 tests):**
- Unit (C++): P6-U01 through P6-U06 (CV cycling order, adaptive skipping, skip limit, faims_cv population, CV transition MS1 injection, non-FAIMS mode).
- Unit (C#): P6-U07, P6-U08 (no remaining references to ScanScheduler or FAIMSScanProcessor).
- Integration: P6-I01 (FAIMS CV cycling through bridge).
- Regression: P6-R01 through P6-R03 (non-FAIMS regression, 3-CV cycling, adaptive skipping).
- Stress: P6-S01 (rapid scan events during CV transition -- mutex correctness).
- See [testing-strategy.md SS Phase 6](testing-strategy.md#phase-6-faims-absorption-build-3) for the complete test matrix.

**Working product verification:**
1. Non-FAIMS modes unchanged (regression).
2. 3-CV cycling matches old behavior exactly.
3. Adaptive CV skipping works: CVs skipped when precursor count below threshold.
4. Skip limit enforced: forced cycle after `max_cv_skip` consecutive skips.
5. ScanScheduler has zero remaining references.
6. Stress test: no race conditions during CV transitions.

**Build produced:** Build #3.

**Dependencies:** Phase 5 (C# simplification must be complete so ScanScheduler is the only remaining C#-side scheduling).

---

## Phase 7: Exploration Engine

**Goal:** Implement MSn-generalized parameter exploration (CE optimization). Entirely new functionality.

**Issues addressed:** Issue 4 (MSn-Generalized Exploration Engine). See [baseline-plan.md SS Issue 4](baseline-plan.md#issue-4--msn-generalized-exploration-engine) for full specification.

**What changes:**
- `ExplorationGroup` and `ExplorationVariant` structs in C++.
- Exploration initiation from high-scoring precursors.
- Variant tracking, scoring, winner selection by FragmentationQuality.
- MS1 cycle time suppression during active exploration.
- MS3 recursive exploration (MS2 winner triggers MS3 CE variants on top fragments).
- `OptimizationMetadata` populated by exploration engine.

**Test coverage (12 tests):**
- Unit (C++): P7-U01 through P7-U10 (group creation with CE variants, priority 0, winner selection, queue overflow protection, MS1 suppression, MS1 resumption, MS3 recursion, depth limit, metadata population, metadata serialization).
- Regression: P7-R01 (exploration disabled = identical to Phase 6), P7-R02 (exploration enabled = variant scans in output).
- See [testing-strategy.md SS Phase 7](testing-strategy.md#phase-7-exploration-engine-build-4) for the complete test matrix.

**Working product verification:**
1. Exploration disabled: identical to Phase 6.
2. CE optimization (20-40, step 5): 5 variant scans per precursor.
3. Winner selected by FragmentationQuality score.
4. Queue overflow protection at `MaxQueueForExploration` threshold.
5. MS1 cycle time suppressed during exploration, resumes after.
6. OptimizationMetadata populated and serialized to mzML.
7. MS3 recursive exploration respects depth limit.

**Build produced:** Part of Build #4.

**Dependencies:** Phase 6 (FAIMS absorption complete; C++ fully owns the queue).

---

## Phase 8: Cleanup + Documentation

**Goal:** Remove all old bridge function exports, dead C# code, and legacy config path. Final form: 5 bridge functions only.

**Issues addressed:** Issue 7 (P/Invoke Declarations -- completion). See [baseline-plan.md SS Issue 7](baseline-plan.md#issue-7--pinvoke-declarations) and [SS Phase 8](baseline-plan.md#phase-8-cleanup--documentation-build-4) for full specification.

**What changes:**
- Remove 13 old C++ bridge exports (GetPeakGroupSize, GetIsolationWindows, DeconvolveMS2, etc.).
- Remove legacy config parsing (`parseLegacy`); JSON is the only format.
- Remove 13 old C# P/Invoke declarations.
- Remove `Parameter.ToFLASHDeconvInput()`.
- New `MethodDocGenerator.cs` (reflection utility for `[Description]` attributes).

**Test coverage (7 tests):**
- Unit (C#): P8-U01 through P8-U03 (exactly 5 P/Invoke declarations, no ToFLASHDeconvInput references, MethodDocGenerator output).
- Unit (C++): P8-U04 (legacy config parsing removed -- non-JSON input fails).
- Integration: P8-I01 (exactly 5 DLL exports), P8-I02 (zero compile warnings).
- Regression: P8-R01 (full regression with every mode config against Phase 7 golden files).
- See [testing-strategy.md SS Phase 8](testing-strategy.md#phase-8-cleanup--documentation-build-4) for the complete test matrix.

**Working product verification:**
1. `Flash.exe -t` runs in final form.
2. `dumpbin /exports` shows exactly 5 bridge functions.
3. C# compiles with zero warnings.
4. MethodDocGenerator produces correct output.
5. Full regression: every configuration variant matches Phase 7 baseline.

**Build produced:** Build #4 (ships Phases 7 + 8).

**Dependencies:** Phase 7 (exploration engine must be complete before removing old bridge functions).

---

## Cumulative Test Count by Phase

| Phase | New tests | Cumulative | Regression base |
|-------|-----------|------------|-----------------|
| 0 | 7 | 7 | -- |
| 1 | 10 | 17 | Phase 0 golden |
| 2 | 6 | 23 | Phase 0/1 golden |
| 3 | 16 | 39 | Phase 2 golden |
| 4 | 19 | 58 | Phase 3 golden |
| 5 | 6 | 64 | Phase 4 golden |
| 6 | 13 | 77 | Phase 5 golden |
| 7 | 12 | 89 | Phase 6 golden |
| 8 | 7 | 96 | Phase 7 golden |

All tests are additive. No phase removes tests. Every push triggers the full suite.

See [testing-strategy.md SS Testing Philosophy](testing-strategy.md#1-testing-philosophy) and [SS Test Tiers](testing-strategy.md#2-test-tiers) for CI tier structure and timing budgets.

---

## Phase Dependency Graph

```
Phase 0 (baseline)
  |
  v
Phase 1 (JSON config) ---+
Phase 2 (metadata)    ---+--- Build #1
Phase 3 (ScanCommand)----+
  |
  v
Phase 4 (switch-over) -------- Build #2
  |
  v
Phase 5 (C# simplify) -------- no build
  |
  v
Phase 6 (FAIMS) --------------- Build #3
  |
  v
Phase 7 (exploration) ---+
Phase 8 (cleanup)     ---+---- Build #4
```

---

## Quick Reference: Issues to Phases

| Issue | Description | Primary phase | Completed by |
|-------|-------------|---------------|--------------|
| 1 | Unified ProcessScan Bridge | Phase 3 (stub), Phase 4 (full) | Phase 4 |
| 2 | ScanCommand Struct | Phase 3 | Phase 3 |
| 3 | C++ Owns the Scan Queue | Phase 3 (queue), Phase 6 (FAIMS) | Phase 6 |
| 4 | MSn Exploration Engine | Phase 7 | Phase 7 |
| 5 | Scoring in Unified Architecture | Phase 4 | Phase 4 |
| 6 | Simplified C# Architecture | Phase 5 | Phase 5 |
| 7 | P/Invoke Declarations (5 total) | Phase 3 (add new), Phase 8 (remove old) | Phase 8 |
| 8 | JSON Configuration | Phase 1 | Phase 1 |
| 9 | OptimizationMetadata | Phase 2 (struct), Phase 7 (populated) | Phase 7 |

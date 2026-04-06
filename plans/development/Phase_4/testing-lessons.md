# Phase 4 Testing Lessons

## 1. Test through the acquisition loop, not around it

Unit tests that call bridge functions directly (e.g., `GetIsolationWindows`, `DeconvolveMS2`) verify the C++ engine in isolation but miss the integration context: how the processor routes scans, how tracking IDs flow from MS1 commands back through MS2 returns, and how mode-specific logic (conditional follow-ups, quant gating, MS3 targeting) chains together.

The continuity tests (CT01–CT42) caught real gaps that unit tests could not:
- Tag targeting / conditional MS2 tests never pushed MS2 back — follow-up scheduling was untested
- Quant mode only tested construction — `IsDifferentiallyAbundant` was never called
- MS3 tests passed vacuously with 0 results because synthetic peaks don't deconvolve
- Inclusion filtering used a spectrum that didn't match any targets

These were invisible at the unit test level because each bridge function worked correctly in isolation. The bugs were in the *composition* — how functions chain together through the processor's scan routing logic.

**Rule:** For every acquisition mode, have at least one test that pushes real spectrum data through the full loop (MS1 → MS2 command → MS2 return → follow-up/MS3) and asserts on the final scan commands produced.

## 2. Tests must exercise the active code path

The continuity tests were coupled to the OLD multi-step bridge path (`Processor.ProcessMS` → 18 P/Invoke calls). When Phase 4 switches to the unified bridge (`ProcessScan` + `GetNextScanCommand`), the old path becomes dead code — but the tests would still exercise it and pass, giving false confidence.

Tests that validate dead code are worse than no tests: they consume CI time, pass green, and mask the fact that the *active* path is untested.

**Rule:** When the implementation switches code paths, the tests must switch with it. The test harness should call the same entry points that production code calls. After the Phase 4 switch-over, `ContinuityTestHarness.PushScan` must call `ProcessScan` + `GetNextScanCommand` directly — not route through the C# processor layer that production no longer uses.

## 3. C++ tests must match the engine's state accumulation requirements

The `FLASHIda_ProcessScan_test` never passed on CI because it pushed only scan 1 (520 peaks) from `ms1_standard.txt`. The deconvolution engine (`SpectralDeconvolution`) requires multiple scans to build internal state (mass feature traces, scoring history) before `processScan` returns any commands. A single scan always returns 0, regardless of peak count.

The Windows continuity tests passed because `PushStandardSpectrumAndCollect()` pushes all 50 scans sequentially. The C++ test needed to do the same.

The `std::abs()` fix (bare `abs()` truncates doubles to int on GCC) was also correct but was a red herring for the zero-results issue — the real cause was insufficient input data.

**Rule:** When a C++ unit test wraps the same engine that an integration test exercises successfully, replicate the integration test's data feeding pattern (all scans, in order). Don't assume a single representative scan is enough — stateful algorithms need their full input sequence.

## 4. P/Invoke struct changes have a 5-file cohesion surface

Extending `ScanCommand` with scoring fields required updating 5 files across both submodules — plans that only track the "obvious" files (C++ header, C++ source, C# struct) miss the test files that also encode layout assumptions:

1. `FLASHIda.h` — C++ struct definition + `static_assert` on size
2. `FLASHIda.cpp` — populate new fields (e.g., in `buildMS2Command_`)
3. `ScanCommandLayout_test.cpp` — C++ `offsetof` printer binary (easy to forget)
4. `FLASHIdaWrapper.cs` — C# struct mirror
5. `ScanCommandLayoutTests.cs` — C# `Marshal.SizeOf` + `Marshal.OffsetOf` assertions

The C++ layout test (#3) is the one most likely to be missed in plans because it's not part of the struct definition or the C# side — it's a standalone binary that CI uses to cross-validate offsets. If it's not updated, CI still passes (it prints stale values) but the cross-check becomes meaningless.

The commit sequence also matters: C++ must be pushed first to trigger `build-dlls`, then DLLs must be downloaded and committed into `FlashIDA/dll/` before committing the C# changes and parent submodule pointers. Attempting to commit the parent repo before the DLL update causes CI struct size mismatches at runtime.

**Rule:** When planning P/Invoke struct changes, enumerate all 5 files explicitly and include the DLL rebuild wait as a blocking step between the C++ and C# commits.

## 5. The old bridge's field names are misleading for intensity mapping

When populating `ScanCommand` scoring fields to match the legacy `GetIsolationWindows` output, the field names `precursorIntensities` and `peakgroupIntensities` suggest they might be the same value. They're not:

- `precursorIntensities` → `PeakGroup::getChargeIntensity(charge)` — intensity at the *specific charge state*
- `peakgroupIntensities` → `PeakGroup::getIntensity()` — *total* intensity across all charges

This distinction matters for behavioral equivalence between the legacy and unified bridge paths. Getting it wrong produces TSV output that passes format checks but fails golden-file comparison on the intensity columns.

**Rule:** When mapping fields between the old multi-call bridge and the new `ScanCommand` struct, verify each field's source by reading `getIsolationWindows` in `FLASHIda.cpp` — don't rely on parameter names alone.

# Phase 4 Test Improvement Plan

**Generated**: 2026-04-02
**Structure**: Each section is independent — accept or reject individually.

---

## Overview

| Category | Changes | Files touched |
|----------|---------|---------------|
| A. Silent skip → hard fail | 4 changes | ContinuityTests.cs |
| B. Vacuous C# assertions | 5 changes | BridgePhase4Tests.cs, BridgeMS2Tests.cs |
| C. Weak C++ assertions | 4 changes | FLASHIda_ProcessScan_test.cpp |
| D. Scoring field coverage gap | 2 changes | ScanCommandRecord.cs, ContinuityTestHarness.cs |
| E. Legacy path tests | 0 changes | (no action needed) |

---

## A. Assume.That → Assert.That (DONE)

Already applied in this session. Four continuity tests promoted from silent skip to hard fail.

| Test | Line | Change |
|------|------|--------|
| CT03 `StandardDDA_AllOutputsAreMSn` | 138 | `Assume.That` → `Assert.That` |
| CT01 `StandardDDA_PrecursorMasses` | 154 | `Assume.That` → `Assert.That` |
| CT02 `CollisionEnergiesMatchConfig` | 177 | `Assume.That` → `Assert.That` |
| CT11 `NonFAIMS_CVIsZero` | 359 | `Assume.That` → `Assert.That` |

**Why**: Golden baselines exist for this data. If deconvolution returns 0 results, something is broken — the test should fail, not silently skip.

**Note**: CT06 (`StandardDDA_BehavioralReference`, line 207) also has `Assume.That` but feeds into `AssertGolden` which provides the real validation. Consider promoting it too, but it's lower priority since the golden comparison is the meaningful assertion.

---

## B. Vacuous C# Assertions

### B1. `P4_I01_LegacyBridgePath_StillWorks`

**File**: `FlashIDA/src/Flash.Tests/BridgePhase4Tests.cs:164`

**Current**: `Assert.That(totalResults, Is.GreaterThanOrEqualTo(0))` — always passes since `totalResults` accumulates non-negative values.

**Why rework**: The test name says "StillWorks" but it can't detect if the legacy bridge stops producing results. With 0 results, it's a crash test masquerading as a functional test.

**Proposed change**: Switch test data from `ms1_smoke_test.txt` (2 scans, may be insufficient) to `ms1_standard.txt` (50 scans, known to produce results), then assert `> 0`:
```csharp
// ms1_standard.txt has 50 scans — sufficient for engine state accumulation
Assert.That(totalResults, Is.GreaterThan(0),
    "Legacy bridge should find at least one peak group from ms1_standard.txt");
```

**Risk**: Low with `ms1_standard.txt`. The 50-scan file is used by all other tests that need positive results.

---

### B2. `P0_I05_GetBestMS2Masses_ReturnsResults`

**File**: `FlashIDA/src/Flash.Tests/BridgeMS2Tests.cs:218`

**Current**: `Assert.That(count, Is.GreaterThanOrEqualTo(0))` — always passes.

**Why rework**: Named "ReturnsResults" but accepts 0 results. The setup already deconvolved MS2 data (`_ms2PeakGroups`), so if peak groups exist, `GetBestMS2Masses` should find masses.

**Proposed change**: Strengthen the prerequisite guard from `>= 0` to `> 0`, then assert positive results and validate output arrays:
```csharp
Assume.That(_ms2PeakGroups, Is.GreaterThan(0), "No MS2 peak groups — skipping");
Assert.That(count, Is.GreaterThan(0),
    $"GetBestMS2Masses should return > 0 when {_ms2PeakGroups} peak groups exist");
for (int i = 0; i < count; i++)
{
    Assert.That(masses[i], Is.GreaterThan(0), $"Mass[{i}] should be positive");
    Assert.That(windowEnds[i], Is.GreaterThan(windowStarts[i]),
        $"Window end[{i}] should exceed start[{i}]");
}
```

**Risk**: Low. `Assume` skips cleanly if MS2 data isn't rich enough.

---

### B3. `P0_I06_GetTopFragmentMatches_WithProteinSequence`

**File**: `FlashIDA/src/Flash.Tests/BridgeMS2Tests.cs:243`

**Current**: `Assert.That(count, Is.GreaterThanOrEqualTo(0))` — always passes.

**Why rework**: Fragment matching against Histone H3 should produce results if the MS2 data comes from a histone sample. Even if it doesn't, the returned data should be validated when present.

**Proposed change**: Add bounds check + conditional output validation:
```csharp
Assume.That(_ms2PeakGroups, Is.GreaterThan(0), "No MS2 peak groups — skipping");
Assert.That(count, Is.LessThanOrEqualTo(maxN), "Should not exceed requested N");
if (count > 0)
{
    for (int i = 0; i < count; i++)
    {
        Assert.That(masses[i], Is.GreaterThan(0), $"Mass[{i}] should be positive");
        Assert.That(ionTypes[i] == (byte)'b' || ionTypes[i] == (byte)'y',
            $"ionType[{i}] should be 'b' or 'y', got {(char)ionTypes[i]}");
    }
}
```

**Risk**: Low. 0 is still accepted (not all MS2 data matches Histone H3). The improvement is validating the data when it IS returned.

---

### B4. `P0_I07_GetAmbiguityEnclosingIons` and B5. `P0_I08_GetTerminalFragmentIons`

**File**: `FlashIDA/src/Flash.Tests/BridgeMS2Tests.cs:268, 293`

**Current**: `Assert.That(count, Is.GreaterThanOrEqualTo(0))` — always passes.

**Why rework**: Same pattern as B3. These specialized fragment selection functions may legitimately return 0 (PTM ambiguity and terminal ions are subsets of all fragment matches), but returned data should be validated.

**Proposed change**: Same pattern as B3 — bounds check + conditional validation of ion types and fragment indices.

**Risk**: Low. Identical reasoning to B3.

---

## C. Weak C++ Assertions

### C1. `processScan_tag_targeting` (P4-U13)

**File**: `OpenMS/.../FLASHIda_ProcessScan_test.cpp:756`

**Current**: `TEST_EQUAL(ms2_result >= 0, true)` — always passes.

**Why rework**: Tag targeting alone does NOT push follow-up commands. The config has `quant.enabled=false`, no `conditional_ms2`, no `ms3`. So `processMS2Path_` should return exactly 0. Asserting `>= 0` misses the point.

**Proposed change**:
```cpp
// Tag targeting updates internal state but pushes 0 commands
// (no quant, no conditional, no MS3 in this config)
TEST_EQUAL(ms2_result, 0)
```

**Risk**: Low. This is deterministic from the config — no data dependency.

---

### C2. `processScan_mass_exclusion` (P4-U11)

**File**: `OpenMS/.../FLASHIda_ProcessScan_test.cpp:677`

**Current**: `TEST_EQUAL(total_pass2 <= total_pass1, true)` — allows equal counts (exclusion broken but test passes).

**Why rework**: Replaying identical scans at identical RTs within the exclusion window MUST reduce the command count. Equality means exclusion did nothing.

**Proposed change**:
```cpp
// Same data within RT_window — exclusion must strictly reduce count
TEST_EQUAL(total_pass2 < total_pass1, true)
```

**Risk**: Low. The data and RTs are identical, well within `RT_window=180s`.

---

### C3. `processScan_ms3_commands` (P4-U07)

**File**: `OpenMS/.../FLASHIda_ProcessScan_test.cpp:527-531`

**Current**: Silent `else { STATUS(...) }` — test passes without executing ANY MS3 assertions if `ms2_result == 0`.

**Why rework**: A silently passing test is worse than no test — it gives false confidence that MS3 logic works. If the data can't trigger MS3, the test should report `NOT_TESTABLE` so it's visible in CI reports.

**Proposed change**:
```cpp
if (ms2_result == 0)
{
    STATUS("MS2 deconvolution produced 0 MS3 targets (data-dependent)")
    NOT_TESTABLE;
    break;
}
// ... existing MS3 structural assertions ...
```

**Risk**: Low. Changes CI visibility (from "passed" to "not testable") without changing behavior. If it's consistently NOT_TESTABLE, that signals the test data needs enrichment.

---

### C4. `processScan_quant_followup` (P4-U12)

**File**: `OpenMS/.../FLASHIda_ProcessScan_test.cpp:706-722`

**Current**: `TEST_EQUAL(ms2_result >= 0, true)` + double-guarded ETD check (`if (ms2_result > 0) { ... if (out.priority == 2) { ... } }`).

**Why rework**: The double guard means the ETD activation assertion may NEVER execute. If quant follow-up was pushed (`ms2_result > 0`), the priority-2 ETD command MUST be in the queue — the inner `if` should not be conditional.

**Proposed change**:
```cpp
TEST_EQUAL(ms2_result >= 0, true)
TEST_EQUAL(ms2_result <= 1, true)  // At most 1 quant follow-up per MS2

if (ms2_result > 0)
{
    ScanCommand out{};
    bool found_p2 = false;
    while (true)
    {
        int r = ida->getNextScanCommand(out);
        if (r == 0) break;
        if (out.priority == 2) { found_p2 = true; break; }
    }
    TEST_EQUAL(found_p2, true)  // Follow-up MUST exist if ms2_result > 0
    TEST_STRING_EQUAL(std::string(out.stages[0].activation_type), "ETD")
    TEST_EQUAL(out.msn_level, 2)
}
else
{
    STATUS("TMT data did not exceed fold-change threshold (data-dependent)")
}
```

**Risk**: Moderate. If `ms2_quant_tmt.txt` never triggers differential abundance, `ms2_result` is always 0 and the ETD assertions never run. But the double-guard removal means that IF it ever triggers, the check is now unconditional.

---

## D. Scoring Field Coverage Gap

### D1. Extend `ScanCommandRecord` with scoring fields

**File**: `FlashIDA/src/Flash.Tests/Mocks/ScanCommandRecord.cs`

**Current**: Captures 11 structural fields from `IFusionCustomScan.Values` (MsnLevel, PrecursorMz, IsolationWidth, CollisionEnergy, Analyzer, ScanDescription, IsAGC, FaimsCV, ActivationType, ScanType, ChargeState).

**Why rework**: Scoring fields (Qscore, MonoMass, ChargeCos, ChargeSnr, IsoCos, Snr, ChargeScore, PpmError, PrecursorIntensity, PeakgroupIntensity, HcdEnergy) are populated by the C++ engine, cross the P/Invoke boundary in `ScanCommand`, but are discarded by `BuildFromCommand` and never inspected. A C++ regression zeroing these fields would be invisible to all C# tests.

**Proposed change**: Add scoring fields to `ScanCommandRecord` and populate them from the raw `ScanCommand` before it's converted to `IFusionCustomScan`:

```csharp
// New fields in ScanCommandRecord
public double Qscore;
public double MonoMass;
public double ChargeCos;
public double ChargeSnr;
public double IsoCos;
public double Snr;
public double ChargeScore;
public double PpmError;
public double PrecursorIntensity;
public double PeakgroupIntensity;
public int HcdEnergy;
```

Include these in `ToJson()` and `FromJson()` for golden file comparison.

**Risk**: All existing golden files will need re-capture (they'll gain 11 new fields). This is a one-time cost.

---

### D2. Capture raw `ScanCommand` in `ContinuityTestHarness.PushScan`

**File**: `FlashIDA/src/Flash.Tests/Mocks/ContinuityTestHarness.cs`

**Current**: `PushScan` calls `GetNextScanCommand(ref cmd)` → `BuildFromCommand(cmd)` → scoring fields are lost.

**Why rework**: The harness has the raw `ScanCommand` in hand but only passes it to `BuildFromCommand`. The `ScanCommandRecord` should be built from the raw struct, not from the converted `IFusionCustomScan`.

**Proposed change**: Build `ScanCommandRecord` directly from `ScanCommand` instead of from `IFusionCustomScan.Values`. This requires a new constructor or factory method on `ScanCommandRecord`:

```csharp
// In PushScan unified path:
while (Wrapper.GetNextScanCommand(ref cmd) == 1)
{
    var scan = Factory.BuildFromCommand(cmd);
    var record = ScanCommandRecord.FromScanCommand(cmd);  // NEW: capture scoring fields
    scanList.Add(scan);
    cmd = new ScanCommand();
}
```

**Risk**: Requires updating `CollectResults()` to use the new records. Existing golden files must be re-captured. The structural field values should be identical — only the scoring fields are new.

---

## E. Legacy Path Tests — No Action Needed

All 7 tests calling legacy bridge functions (`BridgeMS2Tests` 6 tests + `BridgePhase4Tests` 1 test) are **valid backward-compatibility tests**. Every legacy function is still called in production when `UseUnifiedBridge=false`:

- `IDAScanProcessor.ProcessMS()` branches on `UseUnifiedBridge` and calls all legacy functions in the `false` path
- `QuantScanProcessor.ProcessMS()` same pattern
- `FAIMSScanProcessor.ProcessMS()` same pattern
- `FLASHIdaWrapper.Main()` static `ProcessScan` method uses full legacy pipeline when `UseUnifiedBridge=false`

These tests should stay as-is until the legacy path is removed entirely (planned for Phase 8).

---

## Implementation Order

1. **A** (done) — Assume→Assert in continuity tests
2. **C1, C2** — Lowest risk C++ changes (tag targeting exact 0, mass exclusion strict `<`)
3. **C3, C4** — Medium risk C++ changes (MS3 NOT_TESTABLE, quant double-guard removal)
4. **B1** — Switch `P4_I01` to `ms1_standard.txt` + assert `> 0`
5. **B2-B5** — Strengthen BridgeMS2Tests assertions
6. **D1, D2** — Scoring field gap (largest change, requires golden file re-capture)

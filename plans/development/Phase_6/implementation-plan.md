# Phase 6: FAIMS Absorption — Implementation Plan

**Date:** 2026-03-22
**Build:** Build #3
**Risk level:** Highest (FAIMS adaptive CV skipping logic must be exactly replicated)
**Source documents:**
- [../baseline-plan.md](../baseline-plan.md) — Issue 3 (C++ Owns the Scan Queue, FAIMS portion) and Phase 6 specification
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 6 section and CI Environment Requirements
- [../testing-strategy.md](../testing-strategy.md) — Phase 6 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative reference for all test file formats, content requirements, size constraints, and directory layout. Sections referenced by this plan: 1.4 (`ms1_faims_3cv.txt`), 2.1–2.3 (golden file format and capture), 3.2 (`method_faims_3cv.xml` and `method_faims_skip.xml`), 4.1 (`compare_golden.py`).

---

## Phase 4 Addendum (2026-04-04)

This plan has been updated to reflect actual Phase 4 outcomes. Key changes from original estimates:
- **ScanCommand struct size**: 1240 bytes (was "1144 + 8 for timestamp"). Phase 4 added 11 scoring fields (Qscore, MonoMass, ChargeCos, ChargeSnr, IsoCos, Snr, ChargeScore, PpmError, PrecursorIntensity, PeakgroupIntensity, HcdEnergy + Pad2[8]) plus `enqueue_timestamp_ms`. Adding `faims_cv` (double, 8 bytes) in Phase 6 increases from this 1240-byte baseline.
- **GetNextScanCommand returns 0 when empty** (accepted deviation HIGH-02): The C++ function does NOT return an MS1 fallback; it returns 0. The C# `ScanScheduler` currently provides the MS1 fallback. **CRITICAL for Phase 6**: Since Phase 6 deletes `ScanScheduler`, the empty-queue fallback behavior must be addressed — either update C++ to return MS1 when empty, or add a fallback in `Flash.cs`.
- **Test counts**: Phase 4 cumulative ~70 (not ~60). Phase 5 adds 6 → ~76. Phase 6 adds 13 → ~89.
- **Scan descriptions**: Base-36 encoded tracking IDs (`XXXX|mass@charge`), not sequential (`_N|mass@charge`). Phase 6 golden files and test assertions must use this format.
- **ScanCommandRecord**: Expanded to 22 properties (11 original + ScanType + ChargeState + 11 scoring). Phase 6's `FromScanCommand()` path must include the `faims_cv` field.
- **CT27/CT28 FAIMS adaptive skip tests**: `[Ignore]`d in Phase 4 — Phase 6 must activate them with proper per-CV test data.
- **CT09/CT10 FAIMS limitation**: Conditional validation due to per-CV wrapper architecture. Phase 6 must resolve this by unifying the wrapper, enabling hard assertions.
- **CollisionEnergy rounding**: C# uses `Math.Round()` (banker's rounding), not truncation.

---

## Goal

Port FAIMS CV cycling logic from `ScanScheduler.cs` / `FAIMSScanProcessor.cs` to a C++ state machine inside `FLASHIda`. After this phase, `GetNextScanCommand` is the sole authority over FAIMS CV state: it stamps every command with the current CV and manages CV transitions without any C#-side knowledge of CV scheduling. `FAIMSScanProcessor.cs` and `ScanScheduler.cs` are permanently deleted. This completes Issue 3 (C++ Owns the Scan Queue) from `baseline-plan.md`.

The outcome is Build #3: a fully working application where C++ owns the entire scan queue including FAIMS CV cycling, adaptive skipping, skip limit enforcement, and CV transition MS1 injection.

---

## Prerequisites

The following must be in place before starting Phase 6 work. Phase 5 is complete and its CI run is green before any Phase 6 code is written.

**Phase 2 actual deliverables (completed):**
- `OptimizationMetadata` struct (18 fields, `std::optional` on `DeconvolvedSpectrum`).
- `GetConfigInt`/`GetConfigDouble` bridge functions for diagnostic config readback.
- 5 C++ unit tests (P2-U01 through P2-U05) passing in the `cpp-unit-tests` CI job.
- `cpp-unit-tests` CI job active on `ubuntu-latest` with full apt dependency list, CMake flags `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja`, and ccache keyed on `hashFiles('OpenMS/CMakeLists.txt')`.
- Cumulative test count at Phase 2 completion: 59. Phase 4 delivered ~31 tests (cumulative ~70, including 10 continuity tests CT33–CT42). Phase 5 adds 6 (cumulative ~76).

**Phase 5 is complete — all Phase 5 tests pass in CI:**
- `UnifiedScanProcessor.cs` is the only scan processor.
- `IScanProcessor` has exactly one method: `void ProcessMS(IMsScan)`.
- `DataPipe` is a two-stage `BufferBlock<IMsScan>` -> `ActionBlock<IMsScan>` pipeline.
- `QuantScanProcessor.cs` is deleted with zero remaining references.
- `UseUnifiedBridge` feature flag is removed; unified path is the only path.
- `ScanScheduler.cs` still exists and is still active for FAIMS CV cycling (it was explicitly preserved in Phase 5).
- `FAIMSScanProcessor.cs` still exists (it was explicitly preserved in Phase 5).
- All P5-R02 regression tests for FAIMS pass (3-CV cycling through `ScanScheduler` works correctly with `UnifiedScanProcessor`).

**Build #2 artifacts committed in `FlashIDA/dll/` (Phase 0 lesson #5):**
- `OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll` in `FlashIDA/dll/`.
- These DLLs are committed to the repository; no CI cache or cross-workflow download is needed. MSBuild copies them to the build output via `CopyToOutputDirectory` in `Flash.csproj`.

**Phase 5 golden files exist:**
- `FlashIDA/test-data/golden/phase4_standard_dda.tsv` (and all other mode golden files from Phase 4/5).
- **WARNING (Phase 5 update):** `faims_3cv.tsv` and `faims_skip.tsv` were NOT captured in Phase 5. P5-R02 was removed because `Flash.exe` test mode ignores CVs — both FAIMS configs produce identical output (see `Phase_5/lessons-learned.md` Lesson 1). P6-R02 and P6-R03 cannot regress against Phase 5 golden files that don't exist. These tests must either: (a) capture golden files from the continuity test harness (which exercises real FAIMS pipeline), or (b) update `Flash.exe`'s test-mode parser to pass CVs to the C++ engine before capturing regression golden files. Option (a) is recommended — continuity tests CT09/CT10 already produce `ScanCommandRecord` output with real CV annotations.
- Both FAIMS method configs committed: `method_faims_3cv.xml` and `method_faims_skip.xml`.

**Test data must be committed:**
- `FlashIDA/test-data/spectra/ms1_faims_3cv.txt` — Real MS1 scans from a FAIMS acquisition with CV annotations in every scan header. **Format note (Phase 0 lesson #2):** the spectrum header format is tab-separated with RT in seconds (`Spec scan=N\t<seconds>`), not space-separated with RT in minutes. Flash.exe's parser (`FLASHIdaWrapper.cs`) splits on tabs and divides RT by 60 internally. Full format specification, content requirements, size constraints, and the `prepare-test-data.py --include-cv` extraction command are in `../test-file-specification.md` Section 1.4. Phase 6-specific constraint: for the adaptive skip test (P6-R03), the file must contain at least one CV value that produces fewer than `cv_precursor_threshold` deconvolvable precursors and at least one that produces more — this precursor density variation must come from the real data, not from artificially discarding peaks.
- `FlashIDA/test-data/configs/method_faims_3cv.xml` — FAIMS config with CV values matching those present in `ms1_faims_3cv.txt`, `max_cv_skip=0`. Format and CV value constraint are in `../test-file-specification.md` Section 3.2. If the real data uses different CV values than the plan's defaults (-40, -50, -60), adjust both this file and `method_faims_skip.xml` accordingly.
- `FlashIDA/test-data/configs/method_faims_skip.xml` — FAIMS config with threshold and max_cv_skip > 0 (e.g., max_cv_skip=2, cv_precursor_threshold=15). CV values must exactly match the CV annotations in `ms1_faims_3cv.txt`. Format is in `../test-file-specification.md` Section 3.2. The `cv_precursor_threshold` value to use here is the value found in `ScanScheduler.cs` during Step 1 audit (read Step 1 before committing this file).

### User-Provided Inputs

Phase 6 requires `ms1_faims_3cv.txt` (introduced in Phase 5) to already be committed. No new user-provided spectrum data is needed. The FAIMS method configs must use CV values matching the actual annotations in your `ms1_faims_3cv.txt` data.

---

## Phase 3-5 Deviations Impact

Phase 6 inherits several deviations from earlier phases that affect struct layout, field types, and CI requirements. All must be accounted for.

**Struct field deviations (from Phase 3 compliance report):**
- **`ScanCommand.scan_id` is the first field** (not `msn_level`). This was done for cache alignment. Phase 6 must preserve this field order when adding `faims_cv`.
- **`IsolationStage.collision_energy` is `double`** (not `int`). Supports fractional CE values. Phase 6 code referencing collision energy must use `double`.
- **`IsolationStage.activation_type` is `char[32]`** (not `char[16]`). Accommodates longer names like EThcD. `IsolationStage` size = 80 bytes.
- **`ScanCommand.faims_cv` was deferred FROM Phase 3 TO Phase 6.** This is a Phase 6 deliverable. Adding `faims_cv` (a `double`, 8 bytes) to `ScanCommand` changes the struct size. The `static_assert` in C++ and `Marshal.SizeOf` test in C# must be updated to the new size in the same commit.

**`enqueue_timestamp_ms` and scoring fields already present (from Phase 4):**
- Phase 4 added `uint64_t enqueue_timestamp_ms` **and** 11 scoring fields (Qscore, MonoMass, ChargeCos, ChargeSnr, IsoCos, Snr, ChargeScore, PpmError, PrecursorIntensity, PeakgroupIntensity, HcdEnergy + Pad2[8]) to `ScanCommand`. The struct size went from 1144 bytes (Phase 3) to **1240 bytes** (confirmed by Phase 4 `static_assert` and C# `Marshal.SizeOf` test). Phase 6 adds `faims_cv` (double, 8 bytes) on top of the 1240-byte baseline. The Phase 6 `static_assert` must reflect the size after `enqueue_timestamp_ms`, all scoring fields, and `faims_cv` are all present. Compute and verify the exact new size accounting for alignment.

**GetNextScanCommand returns 0 when empty (Phase 4 deviation HIGH-02):**
- The C++ `GetNextScanCommand` returns 0 (no command available) when the queue is empty. It does NOT return an MS1 fallback command. The C# `ScanScheduler` currently provides the MS1 fallback behavior when `GetNextScanCommand` returns 0. **CRITICAL for Phase 6**: Since Phase 6 deletes `ScanScheduler.cs`, the empty-queue MS1 fallback must be addressed. Options: (a) update the C++ `getNextScanCommand()` to return an MS1 when the queue is empty (restoring the original spec behavior from Step 6 item (6)), or (b) add a fallback in `Flash.cs` that submits a default MS1 scan when `GetNextScanCommand` returns 0. Option (a) is preferred since it keeps scan logic in C++. Step 6 of this plan already shows the MS1 fallback in item (6) of `getNextScanCommand()` — verify during implementation that this matches the actual C++ code or add it if missing.

**CT27/CT28 FAIMS tests must be activated (from Phase 4):**
- CT27 (FAIMS adaptive skip) and CT28 (FAIMS skip limit) are `[Ignore]`d in Phase 4 because per-CV test data was not available. Phase 6 must remove the `[Ignore]` attributes and provide proper per-CV test data via `ms1_faims_3cv.txt` to enable hard assertions.

**CT09/CT10 FAIMS conditional validation (from Phase 4):**
- CT09 and CT10 use conditional validation due to the per-CV wrapper architecture. Phase 6 unifies the wrapper by moving FAIMS CV control into C++, which should enable unconditional hard assertions on these tests. Verify and update after the FAIMS state machine is implemented.

**FAIMS handled at C# level only (from Phase 5):**
- Phase 5 preserved `ScanScheduler.cs` and `FAIMSScanProcessor.cs` for C#-only FAIMS CV cycling. The `faims_cv` field was explicitly NOT added to `ScanCommand` in Phase 5. Phase 6 absorbs FAIMS into C++ by: (1) adding `faims_cv` to the C++ and C# `ScanCommand` structs, (2) implementing the FAIMS state machine in C++, and (3) deleting `ScanScheduler.cs` and `FAIMSScanProcessor.cs`.

**CI TRACK-CREATE is now hard-fail (from Phase 3 compliance finding F-5):**
- The CI check for `[TRACK-CREATE]` entries in stdout is a hard-fail gate. Phase 6 regression tests (P6-R01, P6-R02, P6-R03) must emit `[TRACK-CREATE]` entries or the CI job fails. The FAIMS state machine's `getNextScanCommand()` must emit `[TRACK-CREATE]` for CV-transition MS1 injections just like any other generated command.

---

## The Core Risk

Phase 6 is designated highest risk for one specific reason: the adaptive CV skipping logic in `updateCV` is stateful, threshold-dependent, and currently scattered across `ScanScheduler.cs` and `FAIMSScanProcessor.cs`. The C++ reimplementation must produce identical CV transition behavior for all input patterns. A subtle difference in threshold comparisons (strict vs. non-strict inequality), skip counter resets, or cycling direction would produce different scan sequences, invalidating all FAIMS experiments. Every behavioral detail of the existing C# logic must be audited before writing a single line of C++ replacement code.

**Before writing any C++ code, the developer must:**
1. Read and annotate the full body of `ScanScheduler.AddScan()`, `ScanScheduler.GetNextScan()`, and `FAIMSScanProcessor.ProcessMS()`.
2. Write down explicitly: the threshold comparison operator, when the skip counter resets, the cycling direction (index increment vs. decrement), what happens at the last CV (wrap-around vs. stop), and exactly what constitutes a "precursor" for counting purposes.
3. Write P6-U01 through P6-U06 C++ unit tests first (test-driven), then implement the state machine to make them pass.

---

## Detailed Implementation Steps

### Step 1: Audit the existing C# FAIMS logic

Read all of the following before modifying any code. The goal is to produce a written spec that the C++ implementation will be verified against.

**Files to read:**
- `FlashIDA/src/Flash/IDA/ScanScheduler.cs` — full file
- `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs` — full file
- `FlashIDA/src/Flash/etc/method.xml` — the `<FAIMS>` section, specifically `<CVValues>` and `<MaxCVSkip>`

**Questions to answer in writing (add answers as a comment block at the top of the new C++ implementation file):**

1. When does `ScanScheduler` decide to advance the CV index? What is the trigger: scan count, precursor count, or time?
2. What is the exact threshold comparison for "precursor count too low to stay on this CV"? Is it `< threshold`, `<= threshold`, or something else?
3. When a CV is skipped (adaptive skip), is the skip counter incremented before or after the threshold check?
4. When `max_cv_skip` consecutive skips have occurred, is the forced cycle to the next CV or to a specific CV?
5. When `ScanScheduler.GetNextScan()` transitions to a new CV, does it immediately return an MS1 with the new CV, or does it return the first pending MS2 from the queue?
6. Does `FAIMSScanProcessor.ProcessMS` call `scanScheduler.AddScan()` before or after calling `wrapper.ProcessScan()`?
7. What is the cycling order — does the CV index wrap from the last CV back to index 0, or does it ping-pong?
8. What happens if `cv_values` has only one entry?
9. What CV value appears in a non-FAIMS scan? Zero, -1, or is it absent from the scan command?

Record all answers. If the existing code is ambiguous, verify against actual instrument behavior with a team member before proceeding.

---

### Step 2a: Add `faims_cv` field to `ScanCommand` struct

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

This is the core Phase 6 struct change — deferred from Phase 3. Add `double faims_cv;` to the `ScanCommand` struct. Place it after the existing fields but before `scan_description` (or at the position that maintains alignment). The `enqueue_timestamp_ms` field and 11 scoring fields (added in Phase 4) are already present. The struct is currently **1240 bytes** (Phase 4 baseline).

```cpp
struct ScanCommand
{
    int scan_id;               // First field (cache alignment, Phase 3 deviation)
    int msn_level;
    int num_isolation_stages;
    IsolationStage stages[MAX_ISOLATION_STAGES];  // IsolationStage = 80 bytes each
    double max_it;
    int agc_target;
    int orbitrap_resolution;
    char analyzer[32];
    double faims_cv;           // NEW in Phase 6 (deferred from Phase 3)
    char scan_description[256];
    int priority;
    uint64_t enqueue_timestamp_ms;  // Added in Phase 4
    int is_agc;
    // Phase 4 scoring fields (11 fields):
    double Qscore;
    double MonoMass;
    double ChargeCos;
    double ChargeSnr;
    double IsoCos;
    double Snr;
    double ChargeScore;
    double PpmError;
    double PrecursorIntensity;
    double PeakgroupIntensity;
    double HcdEnergy;
    char Pad2[8];
};
```

**Note:** The exact field order above is illustrative — the actual Phase 4 field order is authoritative. Consult the current `FLASHIda.h` `ScanCommand` struct for the definitive layout before adding `faims_cv`. Place `faims_cv` at a position that maintains 8-byte alignment.

**Field type notes (Phase 3 deviations):** `IsolationStage.collision_energy` is `double` (not `int`), `IsolationStage.activation_type` is `char[32]` (not `char[16]`). These are already in place from Phase 3. Do not change them.

**Update `static_assert`:** The ScanCommand size changes when `faims_cv` is added. Update the `static_assert(sizeof(ScanCommand) == ...)` to the new computed size. The Phase 4 baseline is **1240 bytes**; adding `double faims_cv` (8 bytes) increases it to **1248 bytes** (or different due to alignment — compute and verify with `offsetof` checks). Do NOT use the old 1144 or 1152 values.

**Update C# struct:** In `FLASHIdaWrapper.cs`, add `public double FaimsCv;` to the C# `ScanCommand` struct at the matching offset. The `[StructLayout(LayoutKind.Sequential)]` attribute ensures field order matters. The field must be at the same position as in the C++ struct.

**Update C# marshaling tests:** The `Marshal.SizeOf<ScanCommand>()` assertion (from P3-U01) must be updated to the new size. The P3-I01 round-trip marshaling test must be extended to cover `faims_cv` (write a known CV value from C#, read it back from C++ and verify).

---

### Step 2b: Add FAIMS state machine fields to FLASHIda.h

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add the following private member variables to the `FLASHIda` class, grouped under a `// FAIMS CV state` comment block:

```cpp
// FAIMS CV state
std::vector<double> faims_cv_values_;     // CV values from JSON config; empty = non-FAIMS mode
int current_cv_index_;                    // Index into faims_cv_values_; -1 if non-FAIMS
int cv_skip_count_;                       // Consecutive CVs skipped due to low precursor count
int precursor_count_for_cv_;             // Precursor count for the current CV cycle
bool cv_transition_pending_;             // True when GetNextScanCommand must inject MS1 first
```

Add the following private method declarations:

```cpp
// FAIMS CV management
bool isFAIMS_() const;
double currentCV_() const;
void updateCV_();
bool shouldSkipCV_() const;
void injectCVIntoCommand_(ScanCommand& cmd) const;
```

Add the following JSON-parsed configuration fields:

```cpp
int max_cv_skip_;                        // Max consecutive CV skips before forced advance
int cv_precursor_threshold_;            // Min precursor count to stay on current CV
```

---

### Step 3: Parse FAIMS config from JSON in FLASHIda constructor

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

In the JSON parsing section of the constructor (the branch triggered by `arg[0] == '{'`), add parsing for the `faims` object. The JSON schema is defined in `baseline-plan.md` Issue 8:

```json
"faims": {
  "cv_values": [-40, -50, -60],
  "max_cv_skip": 0
}
```

Implementation requirements:
- Parse `cv_values` into `faims_cv_values_`. If the key is absent or the array is empty, `faims_cv_values_` must remain empty (non-FAIMS mode).
- Parse `max_cv_skip` into `max_cv_skip_`. Default: 0 (no skipping allowed — always advance CV).
- `cv_precursor_threshold_` should be a separate JSON field (add `"cv_precursor_threshold": 15` to the `faims` JSON object and to the C# `MethodConfig.cs` serialization). Determine the correct default by reading the existing `ScanScheduler.cs` (Step 1).
- Initialize `current_cv_index_ = faims_cv_values_.empty() ? -1 : 0`.
- Initialize `cv_skip_count_ = 0`, `precursor_count_for_cv_ = 0`, `cv_transition_pending_ = false`.

**Important:** The `cv_precursor_threshold_` field must be added to the JSON schema in both `MethodConfig.cs` and the `Parameter.ToJSON()` serialization on the C# side (see Step 7). Coordinate these changes.

---

### Step 4: Implement the FAIMS helper methods in FLASHIda.cpp

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

**OpenMS singleton initializers must not be removed (Phase 1 lesson #4):** If any call to `ModificationsDB::getInstance()`, `ResidueDB::getInstance()`, or `ElementDB::getInstance()` appears in `FLASHIda.cpp` — even if the return value is unused — do not remove or comment it out. These calls trigger initialization of the OpenMS shared data path resolver as a side effect. Removing them causes a fatal crash (`Cannot find shared data! OpenMS cannot function without it!`) that kills the NUnit agent process. If MSVC flags the unused return value as a C4189 warning, suppress it with a `(void)` cast, not by removing the call.

Implement each helper method in full. These are the exact behaviors captured in Step 1.

#### `isFAIMS_()` — trivial check

```cpp
bool FLASHIda::isFAIMS_() const
{
  return !faims_cv_values_.empty();
}
```

#### `currentCV_()` — safe CV access

```cpp
double FLASHIda::currentCV_() const
{
  if (!isFAIMS_() || current_cv_index_ < 0)
    return 0.0;
  return faims_cv_values_[current_cv_index_];
}
```

#### `shouldSkipCV_()` — adaptive skip decision

Implement to exactly match the threshold logic found in Step 1. The general form (fill in the correct comparison operator and threshold source based on the audit):

```cpp
bool FLASHIda::shouldSkipCV_() const
{
  // Non-FAIMS or skip not configured: never skip
  if (!isFAIMS_() || max_cv_skip_ == 0)
    return false;

  // Skip limit already reached: cannot skip further
  if (cv_skip_count_ >= max_cv_skip_)
    return false;

  // Adaptive skip: precursor count below threshold
  return precursor_count_for_cv_ < cv_precursor_threshold_;
}
```

The `<` vs `<=` comparison must match the C# original exactly (verify in Step 1).

#### `updateCV_()` — advance CV state machine

This is the most critical method. It must replicate the ScanScheduler transition logic:

```cpp
void FLASHIda::updateCV_()
{
  if (!isFAIMS_())
    return;

  if (shouldSkipCV_())
  {
    // Adaptive skip: advance without resetting skip counter
    cv_skip_count_++;
  }
  else
  {
    // Normal advance or forced (skip limit hit): reset skip counter
    cv_skip_count_ = 0;
  }

  // Advance to next CV (wrap-around)
  current_cv_index_ = (current_cv_index_ + 1) % static_cast<int>(faims_cv_values_.size());

  // Reset precursor count for the new CV
  precursor_count_for_cv_ = 0;

  // Flag that the next GetNextScanCommand call must inject an MS1 with the new CV
  cv_transition_pending_ = true;
}
```

The wrap-around direction (index increment) and the skip counter reset logic must match the C# audit exactly. If the C# logic ping-pongs instead of wrapping, replicate that instead.

#### `injectCVIntoCommand_(ScanCommand& cmd)` — stamp CV on every command

```cpp
void FLASHIda::injectCVIntoCommand_(ScanCommand& cmd) const
{
  cmd.faims_cv = currentCV_();
}
```

---

### Step 5: Integrate CV cycling into processScan()

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Inside the `processScan()` method, after the MS1 deconvolution path selects top-N precursors and pushes MS2 commands, add precursor counting for FAIMS:

```cpp
// After deconvolution + command push in MS1 path:
if (isFAIMS_())
{
  int pushed_count = /* number of MS2 commands pushed this cycle */;
  precursor_count_for_cv_ += pushed_count;

  // CV cycling trigger: after each MS1, decide whether to advance CV
  updateCV_();
}
```

The trigger point must match the existing behavior. If `ScanScheduler` advances the CV after every MS1 scan regardless of precursor count (and the adaptive skip only determines whether the new CV is the same or next), implement exactly that. If the trigger is after a fixed number of MS2 scans, implement that instead. The audit in Step 1 determines this.

Note: `updateCV_()` always sets `cv_transition_pending_ = true` when advancing. The actual MS1 injection happens in `getNextScanCommand()` (Step 6).

---

### Step 6: Integrate CV state into getNextScanCommand()

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

This is the core integration point. Modify `getNextScanCommand()` to handle two FAIMS concerns:

**Concern 1: CV transition MS1 injection.**
When `cv_transition_pending_` is true, the next command returned must be an MS1 scan with the new CV, regardless of what is in the queue. This ensures the instrument receives the new CV before any pending MS2 scans from the old CV.

**Concern 2: CV stamping on every command.**
Every command returned by `getNextScanCommand()` must have `faims_cv` set to `currentCV_()`.

The modified logic (insert after the existing AGC and cycle-time checks, before the priority dequeue):

```cpp
int FLASHIda::getNextScanCommand(ScanCommand& out)
{
  std::lock_guard<std::mutex> lock(queue_mutex_);

  // (1) AGC -- always first (unchanged)
  if (needsAGCScan_())
  {
    out = makeAGCCommand_();
    injectCVIntoCommand_(out);
    return 1;
  }

  // (2) CV transition -- inject MS1 with new CV before dequeuing pending MS2s
  if (cv_transition_pending_)
  {
    cv_transition_pending_ = false;
    out = makeMS1Command_();
    injectCVIntoCommand_(out);
    // TRACK-CREATE is required for CV-transition MS1 (CI hard-fail gate, Phase 3 F-5)
    OPENMS_LOG_INFO << "[TRACK-CREATE] scan_id=" << out.scan_id << " (CV transition MS1, CV=" << currentCV_() << ")";
    OPENMS_LOG_DEBUG << "[FAIMS] CV transition -> MS1 with CV=" << currentCV_();
    return 1;
  }

  // (3) MS1 cycle time (unchanged)
  if (cycle_time_enabled_ && msSinceLastMS1_() > cycle_time_ms_)
  {
    out = makeMS1Command_();
    injectCVIntoCommand_(out);
    return 1;
  }

  // (4) Timeout cleanup (unchanged)
  cleanupExpiredCommands_();

  // (5) Priority dequeue 3->0 (unchanged logic, add CV injection)
  for (int lvl = 3; lvl >= 0; lvl--)
  {
    if (!queues_[lvl].empty())
    {
      out = queues_[lvl].front();
      queues_[lvl].pop_front();
      injectCVIntoCommand_(out);
      return 1;
    }
  }

  // (6) Empty -> MS1 (add CV injection)
  // IMPORTANT (Phase 4 deviation HIGH-02): The current C++ code returns 0 when the
  // queue is empty, and C# ScanScheduler provides the MS1 fallback. Since Phase 6
  // deletes ScanScheduler, this fallback MUST be implemented here in C++.
  // Verify the actual C++ behavior during implementation: if it already returns MS1
  // (as shown below), no change is needed. If it returns 0, add this MS1 fallback.
  out = makeMS1Command_();
  injectCVIntoCommand_(out);
  return 1;
}
```

The critical invariant: `injectCVIntoCommand_()` is called on every command before returning, without exception. There must be no early-return code path that bypasses it.

**Empty-queue behavior (Phase 4 deviation HIGH-02):** The current C++ `getNextScanCommand()` returns 0 when the queue is empty. The C# `ScanScheduler` currently provides the MS1 fallback. Phase 6 deletes `ScanScheduler`, so this fallback must move into C++. During implementation, verify the actual behavior and either: (a) add the MS1 fallback in item (6) above if it does not already exist, or (b) confirm it already exists and document. This is a **must-fix** — without the fallback, the instrument will stall when the queue is empty after `ScanScheduler` deletion.

---

### Step 7: Update C# JSON serialization to include FAIMS threshold field

**File:** `FlashIDA/src/Flash/IDA/MethodConfig.cs`

Add `cv_precursor_threshold` to the FAIMS section of the JSON model:

```csharp
public class FaimsConfig
{
    public double[] cv_values { get; set; }
    public int max_cv_skip { get; set; }
    public int cv_precursor_threshold { get; set; }  // ADD THIS
}
```

**File:** `FlashIDA/src/Flash/IDA/Parameter.cs`

Update `ToJSON()` to serialize `cv_precursor_threshold` from the corresponding `method.xml` field. Identify the XML element name by reading `ScanScheduler.cs` (Step 1) to find where it reads the threshold from the configuration.

**File:** `FlashIDA/src/Flash/etc/method.xml`

Add the `<CVPrecursorThreshold>` element (or equivalent, matching the existing XML field name) to the FAIMS section if it does not already exist.

---

### Step 8: Remove ScanScheduler usage from Flash.cs

**File:** `FlashIDA/src/Flash/Flash.cs`

Find all usages of `ScanScheduler` in `Flash.cs`. In the post-Phase 5 code, `ProcessSpectrum` already calls `dataPipe.Push(msScan)` followed by a `GetNextScanCommand` loop. The only remaining `ScanScheduler` involvement is likely:
- Initialization in the constructor or startup code.
- The `GetNextScan()` call that was feeding the scan submission loop.

Remove:
- The `ScanScheduler` field declaration.
- Any `new ScanScheduler(...)` construction.
- Any `scanScheduler.GetNextScan()` calls (the `GetNextScanCommand` loop already handles this).
- Any `scanScheduler.Start()` / `scanScheduler.Stop()` calls.
- Any event subscriptions involving `ScanScheduler`.

Do NOT remove the `GetNextScanCommand` loop itself — that remains and is now the full CV-aware source of scan commands.

This change and the deletion of `ScanScheduler.cs` (Step 9) should be a single atomic commit.

---

### Step 9: Remove ScanScheduler usage from FAIMSScanProcessor.cs and delete both files

**File:** `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs`

Before deletion, verify that `FAIMSScanProcessor.ProcessMS` calls `scanScheduler.AddScan()` to submit commands. After Phase 5, `UnifiedScanProcessor.ProcessMS` calls `wrapper.ProcessScan()` directly, and `FAIMSScanProcessor` is either:
- Already bypassed (delegating to `UnifiedScanProcessor` internally), in which case it is dead code, or
- Still referenced somewhere for FAIMS-specific routing.

If `FAIMSScanProcessor` still has live references in `Flash.cs` or `DataPipe.cs`, replace those references with `UnifiedScanProcessor` first (the CV is now embedded in the command, so no FAIMS-specific processor is needed). Then delete the file.

**Files to delete:**
- `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs`
- `FlashIDA/src/Flash/IDA/ScanScheduler.cs`

Deletion must be via `git rm`, not just removing from the solution. Remove the corresponding `<Compile Include="...">` entries from `Flash.csproj` as well.

After deletion, verify that the solution compiles without errors. Run `grep -r "ScanScheduler\|FAIMSScanProcessor" FlashIDA/src --include="*.cs"` and confirm zero hits (excluding git history and test files that explicitly check for zero hits).

---

### Step 10: Write C++ unit tests for the FAIMS state machine

**File to create:** `OpenMS/src/tests/class_tests/openms/source/FLASHIdaFAIMS_test.cpp`

Write the six C++ unit tests (P6-U01 through P6-U06) as described in the test plan section below. These tests must be written against the public behavior of the state machine methods exposed via the test API, not through internal pointer manipulation.

The tests must be runnable via CTest on `ubuntu-latest` with no Thermo or Windows dependency.

**MSVC `/WX` compliance (Phase 2 lesson #8):** When a variable is used only in a `TEST_EQUAL` assertion but not otherwise referenced, MSVC will warn about unused variables under `/WX`. Use `(void)var;` after the assertion to suppress the warning. This applies to any test variable that is checked once and not used again.

Add the test binary to `OpenMS/src/tests/class_tests/openms/executables.cmake` (uncomment the existing entry or add a new one). The test binary name must follow the OpenMS convention: `FLASHIdaFAIMS_test`.

---

### Step 11: Write C# unit tests for dead code verification

**File to modify:** `FlashIDA/src/Flash.Tests/DeadCodeTests.cs` (create if it does not exist)

Add tests P6-U07 and P6-U08 that grep the C# source directory for references to `ScanScheduler` and `FAIMSScanProcessor` respectively. These are static analysis tests that run on `windows-latest`.

```csharp
[Test]
public void ScanScheduler_HasNoRemainingReferences()
{
    // TestDirectory resolves to FlashIDA/bin/ (Phase 1 lesson #2).
    // One level up is FlashIDA/; the source tree is at FlashIDA/src/Flash/.
    var sourceDir = Path.Combine(TestContext.CurrentContext.TestDirectory,
        "..", "src", "Flash");
    var hits = Directory.GetFiles(sourceDir, "*.cs", SearchOption.AllDirectories)
        .Where(f => !f.Contains("DeadCodeTests.cs"))
        .Where(f => File.ReadAllText(f).Contains("ScanScheduler"))
        .ToList();
    Assert.IsEmpty(hits, "ScanScheduler references found: " + string.Join(", ", hits));
}

[Test]
public void FAIMSScanProcessor_HasNoRemainingReferences()
{
    // TestDirectory resolves to FlashIDA/bin/ (Phase 1 lesson #2).
    // One level up is FlashIDA/; the source tree is at FlashIDA/src/Flash/.
    var sourceDir = Path.Combine(TestContext.CurrentContext.TestDirectory,
        "..", "src", "Flash");
    var hits = Directory.GetFiles(sourceDir, "*.cs", SearchOption.AllDirectories)
        .Where(f => !f.Contains("DeadCodeTests.cs"))
        .Where(f => File.ReadAllText(f).Contains("FAIMSScanProcessor"))
        .ToList();
    Assert.IsEmpty(hits, "FAIMSScanProcessor references found: " + string.Join(", ", hits));
}
```

**Path note (Phase 1 lesson #2):** `TestContext.CurrentContext.TestDirectory` resolves to `FlashIDA/bin/`. One level up (`.."`) reaches `FlashIDA/`. The source tree lives at `FlashIDA/src/Flash/`, so the correct path is `Path.Combine(TestDirectory, "..", "src", "Flash")`. Do NOT use `../../..` or four levels up — that navigates outside the `FlashIDA/` directory.

---

### Step 12: Capture golden files for FAIMS regression tests

> **WARNING (Phase 5 update):** The original plan assumed P5-R02 would capture `faims_3cv.tsv` and `faims_skip.tsv` via the regression runner. P5-R02 was removed because `Flash.exe` test mode ignores CVs entirely — both configs produce identical non-FAIMS output. The golden files do NOT exist. This step must be redesigned before Phase 6 implementation begins. Options:
> 1. **(Recommended)** Replace P6-R02/R03 with continuity tests that capture golden output from `ContinuityTestHarness` (which exercises real FAIMS pipeline). CT09/CT10 already produce `ScanCommandRecord` output with real CV annotations.
> 2. Update `FLASHIdaWrapper.Main()` test-mode parser to pass `cv=` values from TSV headers to `ProcessScan`, then capture golden files via `Flash.exe` as originally planned.
> Either option requires implementation work before golden file capture is possible.

**Golden file format and general capture procedure:** See `../test-file-specification.md` Sections 2.1 (TSV format and column definitions), 2.2 (inventory entry for `faims_3cv.tsv` and `faims_skip.tsv`), and 2.3 (CI artifact download and review steps). Golden files are never constructed manually.

**Golden-file capture requires 2 commits minimum (Phase 0 lesson #15):** The first commit runs CI and produces the golden artifact; the second commit includes the captured golden file. Phase 6 has two golden files (`faims_3cv.tsv` and `faims_skip.tsv`) — batch both captures into a single CI run to minimize commits.

**Phase 6-specific capture workflow** (no local Windows machine available):

1. Push the Phase 5 branch with `ms1_faims_3cv.txt`, `method_faims_3cv.xml`, and `method_faims_skip.xml` committed.
2. The CI regression step runs `Flash.exe <input_file> <output_file> <method.xml>` for each config and uploads the output TSV files as artifacts.
3. Download the artifacts from the CI run, review them to confirm the CV transition log entries and skip events are present and correct.
4. Commit the downloaded files as `FlashIDA/test-data/golden/faims_3cv.tsv` and `FlashIDA/test-data/golden/faims_skip.tsv`. Update `FlashIDA/test-data/golden/README.md` with the CI run URL and OpenMS commit hash per the procedure in `../test-file-specification.md` Section 2.3.

Both golden files must be committed before the Phase 6 C++ build is triggered in CI.

**P6-R02 golden file: `faims_3cv.tsv`**
- ~~Captured from the Phase 5 CI run with `method_faims_3cv.xml` and `ms1_faims_3cv.txt`.~~ **Not available — see WARNING above.**

**P6-R03 golden file: `faims_skip.tsv`**
- ~~Captured from the Phase 5 CI run with `method_faims_skip.xml` and `ms1_faims_3cv.txt`.~~ **Not available — see WARNING above.**

---

### Step 13: Trigger Build #3 and run the full test suite

After all code changes are committed:

**Submodule batching (Phase 0 lesson #15):** Batch all C++ changes (Steps 2a, 2b, 3-4, 6, 10) into as few commits as possible before updating the submodule pointer. Similarly, batch all C# changes (Steps 2a C# portion, 7-9, 11) together. This reduces submodule pointer update churn (Phase 0 saw 48% of commits being submodule updates).

**Submodule pointer update required after every push (Phase 1 lesson #1):** After pushing to `flashida-v9-bridge` or `flashida-v9-migration`, always `git add FlashIDA OpenMS` in the parent repo and push. The CI workflow checks out submodules at the pointer commit, not at the branch HEAD. Forgetting to update the pointer causes CI to silently compile the old code — new files are invisible and the new test count does not appear, making the failure very hard to diagnose.

**Batch all C++ changes before triggering a DLL build (Phase 1 lesson #10):** Each `build-openms-dll.yml` run costs ~40 minutes with no ccache hit. Before triggering a build, ensure all C++ edits (Steps 2a, 2b, 3–4, 6, 10 in this plan) are committed and pushed. Verify the C++ code has no obvious MSVC issues: MSVC's `/WX` flag treats warnings as errors, so unused variables (`C4189`), unused parameters (`C4100`), and similar common warnings will block the build. Use `(void)var;` to suppress unused variable warnings in test code (Phase 2 lesson #8). Check these locally or in a test compile before pushing.

1. Advance the OpenMS submodule pointer in the FlashIDA repository to the commit containing the Phase 6 C++ changes.
2. Trigger `build-openms-dll.yml` manually to produce the Phase 6 `OpenMS.dll` artifact.
3. Wait for the build to complete (~40 min with no ccache hit; Phase 1 lesson #10). The ccache key uses `hashFiles('OpenMS/CMakeLists.txt')` for cache invalidation (Phase 2 lesson), not `executables.cmake` or branch name. The first build after a `CMakeLists.txt` change has no cache and takes the full ~40 min. Subsequent builds with the same `CMakeLists.txt` hash are faster.
4. Trigger `flashida-ci.yml` and verify:
   - `cpp-unit-tests` job (ubuntu-latest): P6-U01 through P6-U06 all pass.
   - `windows-tests` job (windows-latest): P6-U07, P6-U08 pass; all prior-phase C# tests pass.
   - bridge verification step in `windows-tests` (windows-latest): P6-I01 passes.
   - `windows-tests` regression step: P6-R01, P6-R02, P6-R03 all pass. `[TRACK-CREATE]` entries present in stdout (CI hard-fail gate).
   - stress test step in `windows-tests` (windows-latest): P6-S01 passes.
5. If any test fails, all debugging is done via CI. Add diagnostic logging to the relevant code paths, push a new commit, and inspect the CI job logs and uploaded artifacts to identify the failure. See the debugging guide in the Working Product Verification section.

---

## Critical Behaviors to Preserve

These behaviors are non-negotiable. The C++ implementation must match the existing C# behavior exactly for all of them.

### Adaptive CV skipping

The existing `updateCV` logic skips the current CV and advances to the next one when the precursor count for the current CV falls below a configured threshold. This is the core of FAIMS adaptive acquisition. The C++ `shouldSkipCV_()` and `updateCV_()` must replicate:
- The exact threshold comparison operator (read the C# source carefully: `<` vs `<=`).
- What constitutes a "precursor" for counting: any MS2 command pushed, or only high-quality precursors above a score threshold?
- Whether the precursor count is reset to zero at every CV transition or accumulated differently.

### CV cycling order

The CV values must cycle in the order they appear in the `cv_values` JSON array, wrapping from the last value back to the first (or the actual order found in the C# ScanScheduler — verify in Step 1). The cycling direction must be identical.

### Skip limit enforcement

When `max_cv_skip` consecutive CVs have been skipped due to low precursor count, the next CV advance must be forced (the CV advances to the next entry even if the precursor count is still below threshold). After a forced advance, the skip counter resets to zero. The C++ `shouldSkipCV_()` returns false when `cv_skip_count_ >= max_cv_skip_`.

### CV transition MS1 injection

When the CV index changes, `GetNextScanCommand` must return an MS1 scan carrying the new CV value before returning any MS2 scans from the pending queue. This ensures the instrument has the new CV applied before fragment scans arrive. The mechanism is the `cv_transition_pending_` flag set in `updateCV_()` and cleared in `getNextScanCommand()`.

The MS1 command injected at a CV transition is identical to a normal cycle-time-triggered MS1 (same m/z range, resolution, AGC target from JSON config) with one difference: `faims_cv` is set to the new CV value.

### FAIMSScanProcessor.ProcessMS call order

The existing `FAIMSScanProcessor.ProcessMS` calls `scanScheduler.AddScan()` inside `ProcessMS` (bypassing `OutputMS`), which means CV management is interleaved with spectrum processing. In the C++ implementation, `processScan()` pushes commands first and `updateCV_()` runs as part of the MS1 path inside `processScan()`. This ordering must be preserved: the CV state must be updated after the MS2 commands for the current MS1 have been pushed to the queue, not before.

---

## Files to Create or Modify

### C++ files (OpenMS submodule — `flashida-v9-bridge` branch)

| File | Change type | Description |
|------|-------------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | **Step 2a:** Add `double faims_cv` field to `ScanCommand` struct (deferred from Phase 3); update `static_assert` for new struct size (Phase 4 baseline is **1240 bytes**; adding `faims_cv` increases to ~1248 — compute and verify). **Step 2b:** Add FAIMS state machine member variables (`faims_cv_values_`, `current_cv_index_`, `cv_skip_count_`, `precursor_count_for_cv_`, `cv_transition_pending_`, `max_cv_skip_`, `cv_precursor_threshold_`) and private method declarations (`isFAIMS_`, `currentCV_`, `updateCV_`, `shouldSkipCV_`, `injectCVIntoCommand_`) |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Implement FAIMS helper methods, add CV cycling call in `processScan()` MS1 path, add CV transition injection and universal CV stamping in `getNextScanCommand()`, add `faims` JSON section parsing in constructor |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIdaFAIMS_test.cpp` | Create | C++ unit tests P6-U01 through P6-U06 for the FAIMS state machine |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Add or uncomment `FLASHIdaFAIMS_test` test binary entry |

### C# files (FlashIDA repository — `flashida-v9-migration` branch)

| File | Change type | Description |
|------|-------------|-------------|
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Modify | **Step 2a:** Add `public double FaimsCv;` to C# `ScanCommand` struct at the matching offset; update `Marshal.SizeOf` test expectation from 1240 to the new struct size (~1248) |
| `FlashIDA/src/Flash/IDA/MethodConfig.cs` | Modify | Add `cv_precursor_threshold` field to `FaimsConfig` class |
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Serialize `cv_precursor_threshold` in `ToJSON()` FAIMS section |
| `FlashIDA/src/Flash/etc/method.xml` | Modify | Add `<CVPrecursorThreshold>` element to FAIMS section if not already present |
| `FlashIDA/src/Flash/Flash.cs` | Modify | Remove all `ScanScheduler` field declarations, construction, method calls, and event subscriptions |
| `FlashIDA/src/Flash.Tests/DeadCodeTests.cs` | Create | C# unit tests P6-U07 and P6-U08 (grep for ScanScheduler and FAIMSScanProcessor references) |
| `FlashIDA/src/Flash/IDA/FAIMSScanProcessor.cs` | Delete | Remove via `git rm`; remove from `Flash.csproj` `<Compile>` entries |
| `FlashIDA/src/Flash/IDA/ScanScheduler.cs` | Delete | Remove via `git rm`; remove from `Flash.csproj` `<Compile>` entries |

### Test data and golden files

| File | Change type | Description |
|------|-------------|-------------|
| `FlashIDA/test-data/configs/method_faims_3cv.xml` | Create (if not from Phase 5) | FAIMS config: cv_values matching those in `ms1_faims_3cv.txt`, max_cv_skip=0, precursor threshold at default. Format spec: `../test-file-specification.md` Section 3.2. |
| `FlashIDA/test-data/configs/method_faims_skip.xml` | Create (if not from Phase 5) | FAIMS config: cv_values matching those in `ms1_faims_3cv.txt`, max_cv_skip=2, cv_precursor_threshold per Step 1 audit. Format spec: `../test-file-specification.md` Section 3.2. |
| `FlashIDA/test-data/spectra/ms1_faims_3cv.txt` | Provide (real data) | Real FAIMS MS1 scans with CV annotations; must include density variation across CV values for P6-R03 (see Prerequisites). Full format and extraction command: `../test-file-specification.md` Section 1.4. |
| `FlashIDA/test-data/golden/faims_3cv.tsv` | Create | Phase 5 FAIMS 3-CV output, used as Phase 6 regression baseline. TSV format and capture procedure: `../test-file-specification.md` Sections 2.1 and 2.3. Inventory entry: Section 2.2. |
| `FlashIDA/test-data/golden/faims_skip.tsv` | Create | Phase 5 FAIMS adaptive skip output, used as Phase 6 regression baseline. TSV format and capture procedure: `../test-file-specification.md` Sections 2.1 and 2.3. Inventory entry: Section 2.2. |

**`.gitattributes` (Phase 0 lesson #4):** `FlashIDA/.gitattributes` has `* text eol=crlf` which forces CRLF conversion on all files, silently corrupting binary content. Any new binary file extensions committed in Phase 6 (e.g., `.enc`, `.zip`, `.gpg`) must have corresponding `*.ext binary` entries added to `.gitattributes` before committing. Failure to do this causes `bad decrypt` / `wrong final block length` errors when the file is checked out on CI.

---

## Test Cases

### Overview

| Test ID | Tier | Runner | Description |
|---------|------|--------|-------------|
| P6-U01 | 1 (C++) | ubuntu-latest | CV cycling order matches config |
| P6-U02 | 1 (C++) | ubuntu-latest | Adaptive CV skipping: low precursor count skips CV |
| P6-U03 | 1 (C++) | ubuntu-latest | CV skip limit enforced: forced cycle after max_cv_skip |
| P6-U04 | 1 (C++) | ubuntu-latest | `ScanCommand.faims_cv` populated in every dequeued command |
| P6-U05 | 1 (C++) | ubuntu-latest | CV transition injects MS1 with new CV before pending MS2s |
| P6-U06 | 1 (C++) | ubuntu-latest | Non-FAIMS mode: `faims_cv` is 0.0 in every command |
| P6-U07 | 1 (C#) | windows-latest | No remaining references to `ScanScheduler` in source |
| P6-U08 | 1 (C#) | windows-latest | No remaining references to `FAIMSScanProcessor` in source |
| P6-I01 | 2 | windows-latest | FAIMS CV cycling verified through the P/Invoke bridge |
| P6-R01 | 3 | windows-latest | Non-FAIMS regression: all mode outputs unchanged from Phase 5 |
| P6-R02 | 3 | windows-latest | FAIMS 3-CV cycling output matches Phase 5 golden file |
| P6-R03 | 3 | windows-latest | FAIMS adaptive skipping log output matches Phase 5 golden file |
| P6-S01 | 4 | windows-latest | Stress: 50 rapid scan events during CV transition, no mutex deadlock |

Total: 13 tests (6 C++ unit, 2 C# unit, 1 integration, 3 regression, 1 stress).

---

### Test Summary (Quick Reference)

| Test ID | Summary |
|---------|---------|
| P6-U01 | Verifies that the C++ state machine cycles through the configured CV values in the correct order and wraps back to the first CV after the last, confirming the basic cycling invariant. |
| P6-U02 | Verifies that when an MS1 scan produces fewer precursors than `cv_precursor_threshold`, the adaptive skip logic fires: `shouldSkipCV_()` returns true, the skip counter increments, and the CV advances, confirming the threshold comparison is correct. |
| P6-U03 | Verifies that after `max_cv_skip` consecutive adaptive skips, the skip limit is enforced: `shouldSkipCV_()` returns false even with a still-sparse scan, the CV is force-advanced, and the skip counter resets to zero. |
| P6-U04 | Verifies that every command returned by `getNextScanCommand()` — whether dequeued from a priority queue or generated as an MS1 fallback — has `faims_cv` set to the current CV value, with no bypass code paths. |
| P6-U05 | Verifies that when a CV transition is triggered, the next command returned is an MS1 carrying the new CV value, and that all subsequent queued MS2 commands are re-stamped with the new CV at dequeue time. |
| P6-U06 | Verifies that in non-FAIMS mode (empty `cv_values`), all dequeued commands have `faims_cv == 0.0` and no FAIMS state machine code path is activated, guarding against accidental interference with standard DDA operation. |
| P6-U07 | Static analysis test confirming that `ScanScheduler.cs` has been fully excised: no `.cs` source file in the Flash project contains the string `ScanScheduler`, enforcing the deletion done in Step 9. |
| P6-U08 | Static analysis test confirming that `FAIMSScanProcessor.cs` has been fully excised: no `.cs` source file in the Flash project contains the string `FAIMSScanProcessor`, enforcing the deletion done in Step 9. |
| P6-I01 | Verifies end-to-end FAIMS CV cycling through the P/Invoke bridge: `ProcessScan` and `GetNextScanCommand` called from C# produce the correct CV-stamped command sequence across a full 3-CV cycle, confirming correct P/Invoke marshaling of the `faims_cv` field. |
| P6-R01 | Regression test confirming that Phase 6 code changes did not alter non-FAIMS output: `Flash.exe <input_file> <output_file> method_default.xml` must produce output identical to the Phase 5 `phase4_standard_dda.tsv` golden file. |
| P6-R02 | Regression test confirming that the C++ FAIMS state machine replicates the deleted `ScanScheduler.cs` exactly for 3-CV cycling: output and CV transition log entries must match the Phase 5 `faims_3cv.tsv` golden file. |
| P6-R03 | Regression test confirming that adaptive CV skipping behavior is preserved after the C# → C++ port: skip events, forced advances, and deconvolution output must match the Phase 5 `faims_skip.tsv` golden file. |
| P6-S01 | Stress test that runs 50 rapid `ProcessScan` calls and concurrent `GetNextScanCommand` calls to verify `queue_mutex_` correctness during CV transitions: no deadlock, no data corruption, and no access violations within the 10-minute budget. |

---

### P6-U01 — CV cycling order matches config

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure a `FLASHIda` instance with 3 CVs: [-40, -50, -60] and `max_cv_skip=0`. Call `processScan()` with a synthetic MS1 spectrum three times (one cycle per CV). After each MS1 call, retrieve the next MS1 command via `getNextScanCommand()` and record the `faims_cv` value. Verify the sequence is -40 -> -50 -> -60 -> -40 (full cycle wraps back to start).

**Expected outcome:** `faims_cv` values across 4 successive MS1 injections are -40, -50, -60, -40. Dequeue order is deterministic. No CV value is repeated before all three have been visited.

**Implementation note:** The test must drive the state machine by calling the correct methods in the correct order. Use a synthetic spectrum with at least one deconvolvable charge envelope so that `precursor_count_for_cv_` increments correctly and `updateCV_()` is triggered.

---

### P6-U02 — Adaptive CV skipping: low precursor count advances CV

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure FAIMS with 3 CVs, `max_cv_skip=2`, `cv_precursor_threshold=15`. Call `processScan()` with a sparse MS1 spectrum that produces fewer than 15 precursors (e.g., 3 peaks, no charge envelopes). Verify that `updateCV_()` triggers a CV skip: `shouldSkipCV_()` returns true, `cv_skip_count_` is incremented to 1, and `current_cv_index_` advances.

**Expected outcome:** After one MS1 scan with precursor_count < threshold: `shouldSkipCV_()` == true, `cv_skip_count_` == 1, CV index has advanced. After a second MS1 scan still below threshold: `cv_skip_count_` == 2. After a third: `shouldSkipCV_()` == false (skip limit reached), `cv_skip_count_` resets to 0 on the next normal advance.

---

### P6-U03 — CV skip limit enforced after max_cv_skip consecutive skips

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure `max_cv_skip=2` and drive the state machine through 2 consecutive adaptive skips (both with precursor_count < threshold). On the third call to `updateCV_()`, `shouldSkipCV_()` must return false (skip limit hit) even though precursor_count is still below threshold. Verify `cv_skip_count_` resets to 0 and the CV advances normally (forced cycle).

**Expected outcome:** After 2 skips, `shouldSkipCV_() == false`. The CV advances on the third `updateCV_()` call. `cv_skip_count_` is 0 after the forced advance.

---

### P6-U04 — `ScanCommand.faims_cv` populated in every dequeued command

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure FAIMS with CV values [-40, -50, -60]. Push 5 MS2 commands at various priorities to the queue. Call `getNextScanCommand()` 10 times (5 from queue, then 5 MS1 fallbacks). Verify every returned `ScanCommand` has `faims_cv == currentCV_()` at the time of dequeue.

**Expected outcome:** All 10 dequeued commands have non-zero `faims_cv` matching the expected current CV. The `injectCVIntoCommand_()` is called on every code path without exception. Zero commands have `faims_cv == 0.0`.

---

### P6-U05 — CV transition injects MS1 with new CV before pending MS2s

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure FAIMS with 2 CVs [-40, -50]. Push 3 MS2 commands to the queue at priority 1. Then trigger a CV transition by calling `updateCV_()` directly (simulating the end of a CV cycle). Call `getNextScanCommand()` four times. Verify the first dequeued command is an MS1 scan with `faims_cv == -50` (new CV), and the subsequent 3 are the queued MS2 commands with `faims_cv == -50`.

**Expected outcome:** Dequeue sequence: [MS1, faims_cv=-50], [MS2, faims_cv=-50], [MS2, faims_cv=-50], [MS2, faims_cv=-50]. The MS2 commands in the queue have their `faims_cv` overwritten by `injectCVIntoCommand_()` at dequeue time (they were enqueued under the old CV). `cv_transition_pending_` is false after the first dequeue.

**Important:** This test verifies that MS2 commands enqueued under the old CV are correctly re-stamped with the new CV at dequeue time. This is correct behavior — MS2 commands pushed during the old CV cycle will be executed under the new CV. The `ScanCommand.faims_cv` field is always set at dequeue time, not at enqueue time.

---

### P6-U06 — Non-FAIMS mode: `faims_cv` is 0.0 in every command

**Tier:** 1 (C++ unit test, `ubuntu-latest`)

**Description:** Configure a `FLASHIda` instance with no FAIMS CVs (empty `cv_values` array or absent `faims` key in JSON). Call `getNextScanCommand()` 5 times. Verify every returned command has `faims_cv == 0.0`.

**Expected outcome:** `isFAIMS_()` returns false. `currentCV_()` returns 0.0. All 5 dequeued commands have `faims_cv == 0.0`. `cv_transition_pending_` is never set. This is a pure non-regression check to ensure FAIMS code paths are completely bypassed when not configured.

---

### P6-U07 — No remaining references to ScanScheduler in C# source

**Tier:** 1 (C# unit test, `windows-latest`)

**Description:** Static analysis test. Recursively search all `*.cs` files in `FlashIDA/src/Flash/` for the string `ScanScheduler`. Exclude the test file itself. Verify zero matches.

**Expected outcome:** Zero hits. Test fails if any C# source file outside the test project mentions `ScanScheduler`. This test is the enforcer for Step 9.

**CI runner:** `windows-latest` (included in the `windows-tests` job).

---

### P6-U08 — No remaining references to FAIMSScanProcessor in C# source

**Tier:** 1 (C# unit test, `windows-latest`)

**Description:** Same as P6-U07 but searching for `FAIMSScanProcessor`.

**Expected outcome:** Zero hits. Test fails if any C# source file outside the test project mentions `FAIMSScanProcessor`.

**CI runner:** `windows-latest` (included in the `windows-tests` job).

---

### P6-I01 — FAIMS CV cycling through the P/Invoke bridge

**Tier:** 2 (integration test, `windows-latest`)

**Description:** From a C# test using P/Invoke, create a `FLASHIda` instance with a 3-CV FAIMS config JSON. Use the `FLASHIdaWrapper(MethodParameters)` constructor (Phase 1 lesson #11) — this overload calls `ToJSON()` and passes the JSON string to C++, which is required for FAIMS config fields. The legacy `FLASHIdaWrapper(IDAParameters)` constructor uses the space-delimited legacy string that does not carry FAIMS fields; do not use it here. Both constructors remain in the codebase for backward compatibility. Call `ProcessScan` with a synthetic MS1 spectrum that produces 5 precursors. Then call `GetNextScanCommand` in a loop to retrieve the CV-transition MS1 and the 5 MS2 commands. Verify:
1. The first command returned after the `ProcessScan` call is an MS1 with `faims_cv` matching the second CV (CV transition).
2. All subsequent MS2 commands have `faims_cv` matching the new CV.
3. Call `ProcessScan` again with the same spectrum two more times (completing a full 3-CV cycle). Verify the `faims_cv` sequence across the three injected transition-MS1 commands is [-50, -60, -40] (advancing from the initial -40).

**Note:** Synthetic data is acceptable for this test. P6-I01 is a bridge plumbing test verifying P/Invoke marshaling correctness, not a scientific accuracy test. The spectrum used here does not need to be real FAIMS experiment data.

**Multi-scan parser warning (Phase 0 lesson #9):** If using spectrum data from `ms1_faims_3cv.txt` (which contains multiple scans), any test parser loading this file must stop at the first scan boundary (`if (started) break;` on encountering a second `Spec` header). Mixing peaks from multiple scans causes the deconvolution engine to silently return 0 results with no error (see lesson #14).

**Expected outcome:** CV values cycle correctly through the bridge boundary. The P/Invoke marshaling of the `double faims_cv` field in `ScanCommand` is verified to be correct (no endian or alignment issues).

**Requirements:** Both `OpenMS.dll` and Thermo iAPI DLLs must be present. Thermo DLLs are provided via Strategy B: an openssl-encrypted zip (`FlashIDA/dependencies/thermo-dlls.zip.enc`) decrypted in CI using the `THERMO_DLL_PASSPHRASE` secret (Phase 0 lesson #3). Runs in the bridge verification step in `windows-tests` on `windows-latest`.

---

### P6-R01 — Non-FAIMS regression

**Tier:** 3 (regression, `windows-latest`)

**Description:** Run `Flash.exe <input_file> <output_file> method_default.xml` (standard DDA, no FAIMS) and compare output to the Phase 5 golden file for standard DDA. Note: entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()` — there is no `-t` flag.

**Expected outcome:** Output matches the Phase 5 `phase4_standard_dda.tsv` golden file within numeric tolerance. Zero regressions in non-FAIMS modes. This test verifies that the FAIMS state machine code paths are completely bypassed when `faims_cv_values_` is empty, and that no code change in Phase 6 accidentally perturbed the non-FAIMS logic.

**Comparison tool:** `compare_golden.py` — usage, tolerance rules, and failure conditions are specified in `../test-file-specification.md` Section 4.1.

---

### P6-R02 — FAIMS 3-CV cycling output matches Phase 5 golden file

> **WARNING (Phase 5 update):** This test as written is broken. `Flash.exe` test mode ignores CVs — there is no Phase 5 `faims_3cv.tsv` golden file to regress against. Options: (a) replace with a continuity test that captures golden output from the real FAIMS pipeline via `ContinuityTestHarness`, or (b) update the test-mode parser in `FLASHIdaWrapper.Main()` to parse `cv=` from TSV headers and pass CVs to `ProcessScan`. Option (a) is recommended. See `Phase_5/lessons-learned.md` Lesson 1.

**Tier:** 3 (regression, `windows-latest`)

**Description:** Run `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_3cv.xml`. Compare the full output (deconvolution results + CV transition log entries) to the Phase 5 `faims_3cv.tsv` golden file.

**Expected outcome:** CV transition log entries appear at the correct scan intervals and in the correct order (-40 -> -50 -> -60 -> -40). Deconvolution output rows are identical to Phase 5. This is the primary regression check verifying that the C++ state machine produces the same CV cycling behavior as the deleted `ScanScheduler.cs`.

**Note:** If the golden file includes CV transition log entries as metadata rows in the TSV, the comparison must account for them. If log output is written to stderr and not captured in the TSV, the comparison script must be extended to validate log output separately.

---

### P6-R03 — FAIMS adaptive skipping output matches Phase 5 golden file

> **WARNING (Phase 5 update):** Same issue as P6-R02. No Phase 5 `faims_skip.tsv` golden file exists. Must be replaced with continuity test approach or test-mode parser fix. See `Phase_5/lessons-learned.md` Lesson 1.

**Tier:** 3 (regression, `windows-latest`)

**Description:** Run `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_skip.xml` (low threshold, max_cv_skip=2; the sparse MS1 spectrum triggers adaptive skipping). Compare output to the Phase 5 `faims_skip.tsv` golden file.

**Expected outcome:** CV skip events appear in the log at the correct positions. The number of skips per CV matches the Phase 5 behavior. The forced advance after `max_cv_skip` consecutive skips appears at the expected scan number. Deconvolution output rows for non-skipped CVs match the golden file.

---

### P6-S01 — Stress: rapid scan events during CV transition (mutex correctness)

**Tier:** 4 (stress test, `windows-latest`)

**Description:** This is the highest-risk stress test in Phase 6. It exercises `queue_mutex_` correctness during the period when a CV transition is in-flight.

**Setup:** Create a `FLASHIda` instance configured with 3 CVs. Spawn two threads:
- Thread A (simulating TPL DataflowBlock): calls `ProcessScan` with synthetic MS1 spectra at high speed. Each `ProcessScan` call acquires `queue_mutex_` to push MS2 commands and call `updateCV_()`. Runs 50 calls total.
- Thread B (simulating the scan submission loop): calls `GetNextScanCommand` as fast as possible. Each call acquires `queue_mutex_`. Runs until 50 + 3 * (number of CV transitions) commands have been retrieved.

**Verification:**
1. No deadlock: both threads complete within the 10-minute timeout.
2. No data corruption: all retrieved `ScanCommand` structs have valid `faims_cv` values (one of -40, -50, -60, or 0 for MS1). No struct fields contain garbage values.
3. CV transition integrity: every CV transition produces exactly one injected MS1 command with the new CV, never zero or more than one.
4. No `std::terminate` or access violation: run under a watchdog timeout in C#.

**Iteration count:** 50 `ProcessScan` calls (reduced from production-scale to fit within the 10-minute Tier 4 budget).

**CI runner:** `windows-latest` (requires both DLL sets; included in the stress test step in `windows-tests`).

**Implementation:** This test is a C# NUnit test using `Task.WhenAll` with `CancellationToken` for the watchdog. The synthetic spectrum passed to `ProcessScan` must produce at least 1 precursor to ensure `precursor_count_for_cv_` increments and `updateCV_()` is called from Thread A.

---

## CI Configuration

### Workflow file: `.github/workflows/flashida-ci.yml`

Phase 6 requires one new stress test step in `windows-tests` if it was not already added in an earlier phase, and minor additions to the existing jobs. The overall structure from `testing-strategy.md` Section 3.1 is unchanged.

#### Additions to `cpp-unit-tests` job (ubuntu-latest)

The `cpp-unit-tests` job runs `ctest -R ClassName --output-on-failure` (Phase 2 lesson #4). It will automatically pick up `FLASHIdaFAIMS_test` once it is added to `executables.cmake`, using `ctest -R FLASHIdaFAIMS`. No workflow YAML change required beyond ensuring the cmake cache is valid.

If the Phase 6 C++ test binary is in a new file (`FLASHIdaFAIMS_test.cpp`), verify the CMakeLists includes it. Test names follow the OpenMS `ClassName_test.cpp` convention — use `ctest -R FLASHIdaFAIMS` (not `ctest -R FLASH`) to target only the Phase 6 FAIMS tests.

#### Additions to `windows-tests` job (windows-latest)

No structural changes to the job. `DeadCodeTests.cs` is compiled as part of `Flash.Tests.csproj` and run automatically by the NUnit console runner (invoked via full NuGet packages path from `FlashIDA/bin/` working directory, per Phase 0 lesson #12). The P6-U07 and P6-U08 tests will be picked up without YAML changes.

**NUnit runner flags (Phase 1 lesson #8):** All NUnit invocations in `windows-tests` must include `--agents=1 --timeout=300000`. The single-agent flag prevents parallel cold-cache `calculateAveragine` computations (which take ~3.5 minutes each). The 5-minute timeout accommodates the cold-cache cost on the first test that constructs a `FLASHIdaWrapper`.

**`OPENMS_DATA_PATH` (Phase 1 lesson #5):** Every CI step that invokes OpenMS functionality via P/Invoke must set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`. Without it, the C++ data path resolver may fail to find chemistry data files (residue masses, isotope distributions, modifications database), causing a fatal crash that NUnit reports as `Agent Process was terminated` with `Test Count: 0`. This is especially important after any DLL rebuild (Phase 1 lesson #6).

#### Bridge verification step in `windows-tests` job (windows-latest)

Add a step to run P6-I01:

```yaml
- name: Run FAIMS bridge integration test
  working-directory: FlashIDA/bin
  env:
    OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS
  run: |
    ..\..\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe Flash.Tests.dll --where "test == P6_I01" --agents=1 --timeout=300000
```

NUnit must be invoked by full NuGet packages path and run from `FlashIDA/bin/` so that native DLLs (OpenMS.dll and dependencies) are found by the .NET runtime's DLL search path (Phase 0 lesson #12). Adjust the filter to match the NUnit test name as defined in `BridgeTests.cs` or wherever P6-I01 is implemented.

#### Stress test step in `windows-tests` job (windows-latest)

Add a step to run P6-S01:

```yaml
- name: Run FAIMS stress test (P6-S01)
  timeout-minutes: 10
  working-directory: FlashIDA/bin
  env:
    OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS
  run: |
    ..\..\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe Flash.Tests.dll --where "test == P6_S01" --agents=1 --timeout=300000
```

The `timeout-minutes: 10` step-level timeout is in addition to the NUnit internal watchdog. If `nunit3-console` hangs (deadlock), the step-level timeout terminates it and the job fails with a clear message.

#### Regression step in `windows-tests` job

Add the following configs to the regression runner (`regression-runner.ps1` or equivalent):

```powershell
# Phase 6 regression configs (add to existing list)
@{ name="faims_3cv";   method="method_faims_3cv.xml";  ms1="ms1_faims_3cv.txt"; ms2=$null },
@{ name="faims_skip";  method="method_faims_skip.xml"; ms1="ms1_faims_3cv.txt"; ms2=$null },
```

Run `compare_golden.py` for each output against the corresponding Phase 5 golden file.

#### OpenMS DLL artifact cache

Phase 6 produces a new `OpenMS.dll` (Build #3). **Note (Phase 0 lesson #5):** The current OpenMS DLLs are committed in `FlashIDA/dll/` and do not require CI cache or cross-workflow download. When Phase 6 rebuilds `OpenMS.dll`, the new DLL must be committed to `FlashIDA/dll/` to replace the existing one. The `build-openms-dll.yml` workflow must be triggered manually (or via a push to `flashida-v9-bridge`) to produce the updated artifact, which is then committed.

#### Branch trigger list

The CI workflow triggers on `phase-*` branches. The Phase 6 development branch should follow the pattern `phase-6-faims-absorption` to be included automatically. Verify the branch filter in the workflow `on.push.branches` section.

---

## Working Product Verification

After Build #3 is complete and all CI jobs pass, verify the following via the automated tests listed in parentheses. There is no local Windows machine — all verification is done through CI job results, logs, and downloaded artifacts.

### 1. Non-FAIMS modes are unchanged

Confirmed by the `windows-tests` CI job regression step running `Flash.exe <input_file> <output_file> method_default.xml` and comparing to the Phase 5 standard DDA golden file. (Automated: P6-R01.)

If P6-R01 fails, it indicates that code changes in `getNextScanCommand()` accidentally altered behavior in the non-FAIMS code paths. The `isFAIMS_()` guard in `injectCVIntoCommand_()` must return false and inject 0.0 without any side effects.

### 2. 3-CV cycling matches old behavior exactly

Confirmed by the `windows-tests` CI job regression step running `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_3cv.xml`. Inspect the CI log output and downloaded artifact for CV transition messages. Verify:
- First CV transition: from the first CV to the second (appears after the first MS1 cycle).
- Subsequent transitions follow the configured CV order with correct wrap-around.
- Each transition is preceded by exactly one MS1 injection with the new CV.
- The total number of CV transition events across the run matches the Phase 5 golden log.

(Automated: P6-R02.)

### 3. Adaptive CV skipping works correctly

Confirmed by the `windows-tests` CI job regression step running `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_skip.xml`. Inspect the CI log output for CV skip events with the correct skip count and forced advance after `max_cv_skip` consecutive skips. (Automated: P6-R03, P6-U02, P6-U03.)

### 4. Skip limit is enforced

Confirmed by inspecting the same CI log as item 3 above. Verify that no sequence of consecutive skips exceeds `max_cv_skip` before a forced advance occurs. (Automated: P6-U03.)

### 5. ScanScheduler and FAIMSScanProcessor are fully deleted

Confirmed by the `windows-tests` CI job running P6-U07 and P6-U08. (Automated: P6-U07, P6-U08.)

### 6. No race conditions under load

P6-S01 runs as the stress test step in `windows-tests`. If P6-S01 reports a deadlock, diagnose by inspecting the CI log output for the stress test step in `windows-tests`. Check that `queue_mutex_` acquisition points in `processScan()` and `getNextScanCommand()` hold the lock for the entire duration of their queue operations, and that no code path inside `updateCV_()` attempts to re-acquire it (it must not; it is a private method that assumes the lock is already held).

### 7. Full prior-phase regression

Confirmed by the full CI run. All prior-phase tests must still pass (Phase 4 cumulative: ~70; Phase 5 cumulative: ~76). (Automated: all P0-P5 test IDs in the full CI run.)

### Debugging guide

**If P6-R02 or P6-R03 fail (CV cycling mismatch):**
1. Add verbose logging to `updateCV_()`: log `current_cv_index_`, `cv_skip_count_`, `precursor_count_for_cv_`, `shouldSkipCV_()` result, and the new `current_cv_index_` after advance.
2. Push a diagnostic commit and inspect the CI job logs to obtain the full trace.
3. Compare the log trace from Phase 6 (C++) with the expected behavior documented in the Step 1 audit.
4. The first divergence point in the traces identifies the behavioral difference. Iterate: fix the code, push a new commit, inspect CI logs again.

**If P6-S01 fails with a deadlock:**
1. Diagnose by inspecting CI log output from the stress test step in `windows-tests`.
2. Verify that `updateCV_()` is called only from within a context where `queue_mutex_` is already held (i.e., from inside `processScan()` which holds the lock, or from inside `getNextScanCommand()` which holds the lock).
3. Verify there is no call to `getNextScanCommand()` or `processScan()` from within `updateCV_()` or any method it calls.
4. Check whether the synthetic spectrum used in the stress test contains more than `MAX_ISOLATION_STAGES` peaks — oversized input could cause issues.

**If P6-U05 fails (CV transition MS1 ordering):**
1. Verify `cv_transition_pending_` is set to true inside `updateCV_()`.
2. Verify the check for `cv_transition_pending_` appears before the priority dequeue loop in `getNextScanCommand()`.
3. Verify `cv_transition_pending_` is reset to false after the injected MS1 is returned (not before, not in `updateCV_()`).

**If P6-I01 or regression tests produce 0 results with no error (Phase 0 lesson #14):**
The C++ deconvolution engine returns 0 results without an error code when input data is malformed. This silent zero-result failure mode means `CreateFLASHIda` succeeds and the config string looks correct, but `GetPeakGroupSize` returns 0. Before investigating engine internals, log the input data characteristics reaching the bridge: RT, peak count, first/last m/z, precursor mass/charge for MS2. Common causes: wrong spectrum header format (must be tab-separated with RT in seconds), multi-scan parsing mixing peaks from different scans (see lesson #9), or sparse spectra with no charge envelopes.

---

## Definition of Done

All of the following must be true before Phase 6 is considered complete:

- [ ] `double faims_cv` field added to C++ `ScanCommand` struct (Step 2a). This was deferred from Phase 3.
- [ ] `static_assert(sizeof(ScanCommand) == ...)` updated in C++ to reflect the new size (Phase 4 baseline was **1240 bytes**; adding `faims_cv` increases to ~1248 — compute and verify).
- [ ] `public double FaimsCv` field added to C# `ScanCommand` struct in `FLASHIdaWrapper.cs` at the matching offset.
- [ ] `Marshal.SizeOf<ScanCommand>()` test assertion updated to the new struct size (P3-U01 update).
- [ ] P3-I01 marshaling round-trip test extended to verify `faims_cv` field (C# writes known CV value, C++ reads back correctly).
- [ ] C++ `FLASHIda` FAIMS state machine is implemented: `faims_cv_values_`, `current_cv_index_`, `cv_skip_count_`, `precursor_count_for_cv_`, `cv_transition_pending_`, `max_cv_skip_`, `cv_precursor_threshold_` fields exist and are initialized from JSON config.
- [ ] `isFAIMS_()`, `currentCV_()`, `updateCV_()`, `shouldSkipCV_()`, `injectCVIntoCommand_()` are implemented and match the C# audit (Step 1) on all behavioral details.
- [ ] `getNextScanCommand()` injects `faims_cv` into every returned command via `injectCVIntoCommand_()`, with zero bypass code paths.
- [ ] `getNextScanCommand()` handles the `cv_transition_pending_` flag: when set, the next command is an MS1 with the new CV, returned before any queued MS2.
- [ ] `processScan()` calls `updateCV_()` in the MS1 path after pushing MS2 commands.
- [ ] `cv_precursor_threshold_` is serialized from `method.xml` in `Parameter.ToJSON()` and parsed from JSON in the C++ constructor.
- [ ] `FAIMSScanProcessor.cs` is deleted (`git rm`), removed from `Flash.csproj`, with zero remaining references in C# source files.
- [ ] `ScanScheduler.cs` is deleted (`git rm`), removed from `Flash.csproj`, with zero remaining references in C# source files.
- [ ] All 13 Phase 6 tests pass in CI: P6-U01 through P6-U08, P6-I01, P6-R01 through P6-R03, P6-S01.
- [ ] All prior-phase tests (P0 through P5) still pass in CI without modification. (Phase 4 cumulative: ~70; Phase 5 cumulative: ~76. Phase 6 adds 13 → ~89 cumulative.)
- [ ] P6-R02 CI run: `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_3cv.xml` produces CV transition log entries matching the Phase 5 golden file exactly.
- [ ] P6-R03 CI run: `Flash.exe ms1_faims_3cv.txt <output_file> method_faims_skip.xml` produces skip event log entries matching the Phase 5 golden file exactly.
- [ ] P6-R01 CI run: `Flash.exe <input_file> <output_file> method_default.xml` (non-FAIMS) produces output matching the Phase 5 standard DDA golden file exactly.
- [ ] CV-transition MS1 injections emit `[TRACK-CREATE]` log entries (CI hard-fail gate, Phase 3 compliance finding F-5).
- [ ] P6-S01 passes in the stress test step in `windows-tests` within the 10-minute budget with no deadlock, no data corruption, and no access violations.
- [ ] Build #3 `OpenMS.dll` artifact is stored in CI with cache key matching the Phase 6 OpenMS submodule commit hash.
- [ ] Phase 6 golden files (`faims_3cv.tsv`, `faims_skip.tsv`) are committed to `FlashIDA/test-data/golden/` and the `golden/README.md` is updated to document their provenance.
- [ ] CT27/CT28 FAIMS adaptive skip tests activated (remove `[Ignore]` attributes) with proper per-CV test data from `ms1_faims_3cv.txt`.
- [ ] CT09/CT10 FAIMS tests updated with hard assertions (replacing conditional validation) now that the unified wrapper eliminates the per-CV architecture limitation.
- [ ] Empty-queue MS1 fallback behavior verified: after `ScanScheduler` deletion, `getNextScanCommand()` returns an MS1 command (not 0) when the queue is empty, or `Flash.cs` provides an equivalent fallback (Phase 4 deviation HIGH-02).
- [ ] Scan description format uses base-36 tracking IDs (`XXXX|mass@charge`) in all golden files and test assertions (not `_N|mass@charge`).
- [ ] The written behavioral audit from Step 1 is preserved (as a comment block in `FLASHIda.cpp` or as a committed document in `plans/development/Phase_6/`) for future reference.

---

## Phase 0-5 Lessons Applied

This section records which Phase 0 through Phase 5 lessons were incorporated into this plan and where.

| Lesson | Source | Applied In |
|--------|--------|------------|
| No `-t` flag — `Flash.exe <input> <output> <method>` is the correct invocation | Phase 0 #1 | P6-R01/R02/R03 test descriptions; definition of done |
| Spectrum header is tab-separated with RT in seconds | Phase 0 #2 | Prerequisites (`ms1_faims_3cv.txt` format note) |
| Thermo DLL secret: Strategy B (openssl/`THERMO_DLL_PASSPHRASE`) | Phase 0 #3 | P6-I01 requirements |
| New binary file extensions must be added to `.gitattributes` before committing | Phase 0 #4 | Files to Create or Modify (`.gitattributes` note) |
| OpenMS DLLs are committed in `FlashIDA/dll/`; no CI cache/download needed | Phase 0 #5 | Prerequisites (Build #2 artifacts section); CI DLL artifact cache section |
| Multi-scan parser: stop at first scan boundary (`if (started) break;`) | Phase 0 #9 | P6-I01 multi-scan parser warning |
| Build output is `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/` | Phase 0 #12 (item 1) | CI YAML working-directory; NUnit runner paragraph |
| DLL name is `"OpenMS.dll"` with extension | Phase 0 #12 (item 2) | P6-I01 requirements |
| NUnit must run from `FlashIDA/bin/` so native DLLs are found | Phase 0 #12 (item 7) | CI YAML working-directory; NUnit runner paragraph |
| Silent zero-result P/Invoke failures: log input data before investigating | Phase 0 #14 | Debugging guide (P6-I01/regression zero-result note) |
| Golden-file capture requires 2 commits minimum; batch captures | Phase 0 #15 (item 1) | Step 12 golden file capture section |
| Submodule pointer update churn: batch same-side changes | Phase 0 #15 (item 2) | Step 13 submodule batching note |
| Submodule pointer must be updated after every push (new files invisible to CI otherwise) | Phase 1 #1 | Step 13 submodule pointer update paragraph |
| Test data path: `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/` | Phase 1 #2 | Step 11 `sourceDir` path in `DeadCodeTests.cs`; path note after Step 11 |
| MSVC `/WX`: batch all C++ changes; check for unused variables/parameters before pushing | Phase 1 #3 | Step 13 batch C++ changes paragraph |
| Never remove `ModificationsDB::getInstance()` singleton calls — they have initialization side effects | Phase 1 #4 | Step 4 singleton initializer warning |
| `OPENMS_DATA_PATH` must be set in every CI step that invokes OpenMS via P/Invoke | Phase 1 #5 | CI YAML NUnit steps (`env:`); NUnit runner paragraph |
| After any DLL rebuild, set `OPENMS_DATA_PATH` explicitly (implicit path resolution is fragile) | Phase 1 #6 | NUnit runner paragraph |
| NUnit: `--agents=1 --timeout=300000` to handle `calculateAveragine` cold cache (~3.5 min) | Phase 1 #8 | CI YAML NUnit steps; NUnit runner paragraph |
| DLL build takes ~40 min with no ccache hit; batch all C++ changes per build | Phase 1 #10 | Step 13 DLL build time estimate; batch changes paragraph |
| Both constructors exist; use `FLASHIdaWrapper(MethodParameters)` for JSON/FAIMS fields | Phase 1 #11 | P6-I01 description constructor note |
| `toSpectrum()` returns `MSSpectrum` by value, not void with out-param | Phase 2 #1 | Not directly applicable to Phase 6 (no `toSpectrum()` calls), but recorded for completeness |
| `DeconvolvedSpectrum` constructor takes `scan_number`, not `ms_level` | Phase 2 #2 | Not directly applicable to Phase 6, but recorded for completeness |
| `toSpectrum()` requires at least one PeakGroup pushed before calling | Phase 2 #3 | Not directly applicable to Phase 6, but recorded for completeness |
| CTest naming: use `-R ClassName` pattern, not `-R FLASH` | Phase 2 #4 | CI Configuration (cpp-unit-tests section); updated to `ctest -R FLASHIdaFAIMS` |
| CI apt dependencies: full list established for ubuntu-latest | Phase 2 #5 | Implicit in CI configuration (references `environment-and-workflows.md` Section 1) |
| CMake flags: `-DCMAKE_BUILD_TYPE=Release -DWITH_GUI=OFF -DPYOPENMS=OFF -G Ninja` | Phase 2 #6 | Implicit in CI configuration (cpp-unit-tests build step) |
| ccache key: uses `hashFiles('OpenMS/CMakeLists.txt')`, not `executables.cmake` | Phase 2 #7 | Step 13 ccache key reference updated |
| MSVC `/WX`: use `(void)var;` to suppress unused variable warnings in test code | Phase 2 #8 | Step 10 MSVC compliance note for C++ tests |
| Phase 2 delivered: `OptimizationMetadata` struct, `GetConfigInt`/`GetConfigDouble`, 5 C++ unit tests, `cpp-unit-tests` CI job active, 59 cumulative tests | Phase 2 #9 | Prerequisites section (Phase 2 status acknowledged) |
| `collision_energy` is `double` not `int`; `activation_type` is `char[32]` not `char[16]` | Phase 3 deviation | Phase 3-5 Deviations Impact section; Step 2a field type notes |
| `scan_id` is first field in `ScanCommand` (not `msn_level`) | Phase 3 deviation | Phase 3-5 Deviations Impact section; Step 2a struct layout |
| `faims_cv` deferred from Phase 3 to Phase 6 | Phase 3 deviation | Phase 3-5 Deviations Impact section; Step 2a; Definition of Done |
| `IsolationStage` = 80 bytes (verified by `static_assert`) | Phase 3 compliance | Step 2a field type notes |
| CI TRACK-CREATE check is now hard-fail (compliance finding F-5) | Phase 3 compliance | Phase 3-5 Deviations Impact section; Step 6 TRACK-CREATE log; Definition of Done |
| Phase 4 added `enqueue_timestamp_ms` + 11 scoring fields; struct size is **1240 bytes** (not 1144) | Phase 4 | Phase 4 Addendum; Phase 3-5 Deviations Impact section; Step 2a struct layout and `static_assert` note |
| `GetNextScanCommand` returns 0 when empty (deviation HIGH-02); C# ScanScheduler provides fallback | Phase 4 | Phase 4 Addendum; Phase 3-5 Deviations Impact (new HIGH-02 paragraph); Step 6 empty-queue note; Definition of Done |
| CT27/CT28 `[Ignore]`d in Phase 4; must be activated in Phase 6 with per-CV test data | Phase 4 | Phase 4 Addendum; Phase 3-5 Deviations Impact (new CT27/CT28 paragraph); Definition of Done |
| CT09/CT10 conditional validation; Phase 6 must resolve with unified wrapper | Phase 4 | Phase 4 Addendum; Phase 3-5 Deviations Impact (new CT09/CT10 paragraph); Definition of Done |
| Scan descriptions use base-36 `XXXX|mass@charge` format (not `_N|mass@charge`) | Phase 4 | Phase 4 Addendum; Definition of Done |
| ScanCommandRecord expanded to 22 properties; Phase 6 `FromScanCommand()` must include `faims_cv` | Phase 4 | Phase 4 Addendum |
| CollisionEnergy rounding uses `Math.Round()` (banker's rounding), not truncation | Phase 4 | Phase 4 Addendum |
| Phase 5 handles FAIMS at C# `ScanScheduler` level only; `faims_cv` not added to struct | Phase 5 | Phase 3-5 Deviations Impact section; Prerequisites |
| `ScanScheduler.cs` and `FAIMSScanProcessor.cs` preserved in Phase 5; deleted in Phase 6 | Phase 5 | Phase 3-5 Deviations Impact section; Steps 8-9 |

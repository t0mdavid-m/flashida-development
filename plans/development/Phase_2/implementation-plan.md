# Phase 2: OptimizationMetadata — Implementation Plan

**Date:** 2026-03-21
**Phase:** 2 of 9 (Phases 0–8)
**Build batch:** Build #1 (batched with Phase 1 and Phase 3)
**Source documents:**
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 2 section and CI environment requirements
- [../baseline-plan.md](../baseline-plan.md) — Issue 9 specification
- [../testing-strategy.md](../testing-strategy.md) — Phase 2 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative reference for all test file formats, golden file schema, and config file inventory (Sections 1–5)

---

## Goal

Add `OptimizationMetadata` as an optional payload on `DeconvolvedSpectrum`. The struct carries all fields needed to describe an exploration variant (collision energy, group identity, fragmentation quality score, timing, etc.) and is serialized to mzML via `MSSpectrum::setMetaValue()` when present.

This phase is purely additive. No existing code path reads, writes, or checks the new struct. `hasOptimizationMetadata()` returns false for every spectrum produced during normal operation, confirming zero runtime overhead. The struct is the data carrier that Phase 7 (exploration engine) will populate.

---

## Prerequisites

The following must be complete and passing before starting Phase 2 implementation:

1. **Phase 0 done:** `Flash.Tests.csproj` exists. `baseline_phase0.tsv` is committed to `FlashIDA/test-data/golden/`. The `flashida-ci.yml` workflow skeleton exists and the `windows-tests` job is active.
2. **Phase 1 done:** JSON config parsing is complete and CI is green (53 tests passing as of 2026-03-28). Phase 1 delivered: `MethodParameters.ToJSON()`, the new `FLASHIdaWrapper(MethodParameters)` constructor, `parseJSONConfig_()` on the C++ side, golden JSON files (`config_default.json`, `config_full.json`), and P/Invoke stubs for `GetConfigInt`/`GetConfigDouble` (C++ implementation deferred to Phase 2 — see Step 3 below). The legacy `FLASHIdaWrapper(IDAParameters)` constructor is still present for backward compatibility. Phase 2's DLL rebuild must include the `GetConfigInt`/`GetConfigDouble` C++ implementations so that the P1-I03 diagnostic bridge stubs auto-activate.
3. **C++ unit test infrastructure active:** The `cpp-unit-tests` CI job in `flashida-ci.yml` must be active and capable of building and running OpenMS class tests on `ubuntu-latest`. This is the first phase that introduces C++ unit tests; see the CI configuration section below.
4. **`executables.cmake` FLASH entries uncommented:** The FLASH test entries in `OpenMS/src/tests/class_tests/openms/executables.cmake` are currently commented out. They must be uncommented (or new entries added for the Phase 2 test binary) before `ctest -R DeconvolvedSpectrum_OptimizationMetadata` can discover and run the Phase 2 test. (Note: the actual `-R` pattern depends on the test name registered in `executables.cmake`.)
5. **Golden file baseline available:** `FlashIDA/test-data/golden/baseline_phase0.tsv` (from Phase 0) and the Phase 1 golden files (`config_default.json`, `config_full.json`, the `Flash.exe` regressions) are committed, so P2-R01 has a baseline to compare against.
6. **`ms1_smoke_test.txt` and `baseline_phase0.tsv` are committed (from Phase 0).** `ms1_standard.txt` is not required by Phase 2 — it is first needed in Phase 4.

---

### User-Provided Inputs

No new user-provided data is needed for Phase 2. C++ unit tests are self-contained (no file I/O). The regression test reuses `ms1_smoke_test.txt` from Phase 0.

---

## Detailed Implementation Steps

### Step 1 — Create `OptimizationMetadata.h`

**File to create:**
`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h`

Create the header with the struct definition exactly as specified in Issue 9 of `baseline-plan.md`. The struct must be plain C++ (no OpenMS base class inheritance, no virtual functions) so that it is trivially movable and copyable. Include it within `namespace OpenMS`.

The complete struct definition:

```cpp
#pragma once

#include <cstdint>
#include <string>

namespace OpenMS
{
  /**
   * @brief Carries acquisition and exploration metadata for one deconvolved spectrum.
   *
   * Populated by the exploration engine (Phase 7). Zero overhead when not populated
   * because DeconvolvedSpectrum stores this in std::optional.
   *
   * Serialized to mzML via MSSpectrum::setMetaValue() in DeconvolvedSpectrum::toSpectrum().
   */
  struct OptimizationMetadata
  {
    int group_id = 0;
    int variant_index = -1;
    int total_variants = 0;
    bool is_best_variant = false;
    int rank = 0;
    int msn_level_optimized = 0;
    int parent_tracking_id = 0;
    double collision_energy = 0;
    double isolation_width = 0;
    std::string activation_type;
    double precursor_mass = 0;
    int precursor_charge = 0;
    double fragmentation_quality_score = -1;
    float tic_coverage = 0;
    int fragment_count = 0;
    uint64_t start_ms = 0;
    uint64_t complete_ms = 0;
    int exploration_scans = 0;
  };
} // namespace OpenMS
```

Field-by-field notes:
- `group_id`: identifies the `ExplorationGroup` this spectrum belongs to; 0 = no group (default).
- `variant_index`: 0-based index within the group; -1 = unset (default).
- `total_variants`: total number of variants in the group; 0 = unset (default).
- `is_best_variant`: true only for the winner selected by `FragmentationQuality`; false by default.
- `rank`: rank among all variants by score (1 = best); 0 = unset (default).
- `msn_level_optimized`: MSn level being explored (2 for MS2 CE optimization).
- `parent_tracking_id`: tracking ID of the precursor scan that triggered exploration; 0 = unset.
- `collision_energy`: CE value used for this variant; 0.0 = unset (default).
- `isolation_width`: isolation window width; 0.0 = unset (default).
- `activation_type`: activation method string (e.g., "HCD", "CID"); empty = unset (default).
- `precursor_mass`: deconvolved precursor mass; 0.0 = unset (default).
- `precursor_charge`: deconvolved precursor charge; 0 = unset (default).
- `fragmentation_quality_score`: scoring metric for winner selection; -1.0 = unset (default).
- `tic_coverage`: fraction of total ion current explained by identified fragments; 0.0 = unset.
- `fragment_count`: number of matched fragment ions; 0 = unset (default).
- `start_ms`: wall-clock timestamp (milliseconds) when the scan was requested; 0 = unset.
- `complete_ms`: wall-clock timestamp (milliseconds) when the result was processed; 0 = unset.
- `exploration_scans`: total number of exploration scans submitted for the group; 0 = unset.

Default values are chosen so that a freshly default-constructed `OptimizationMetadata` is immediately recognizable as unpopulated in every field, which supports the P2-U03 test.

---

### Step 2 — Modify `DeconvolvedSpectrum.h`

**File to modify:**
`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h`

**a) Add include for `OptimizationMetadata.h` and for `<optional>`:**

In the includes section at the top of the file, add:

```cpp
#include <optional>
#include <OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h>
```

**b) Add the private member:**

Inside the `class DeconvolvedSpectrum` body, in the private members section (alongside existing private fields such as `spec_`, `precursor_peak_group_`, etc.), add:

```cpp
std::optional<OptimizationMetadata> opt_metadata_;
```

**c) Add the three public accessor declarations:**

In the public interface section, add the following declarations (implementations go in the `.cpp` file):

```cpp
/// Returns a reference to the metadata, creating it if it does not exist.
OptimizationMetadata& getOrCreateOptimizationMetadata();

/// Returns a const pointer to the metadata, or nullptr if not present.
const OptimizationMetadata* getOptimizationMetadata() const;

/// Returns true if this spectrum carries OptimizationMetadata.
bool hasOptimizationMetadata() const;
```

Keep the existing `toSpectrum()` declaration unchanged in the header; its body is modified in the `.cpp` file.

---

### Step 3 — Modify `DeconvolvedSpectrum.cpp`

**File to modify:**
`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.cpp`

**a) Implement `getOrCreateOptimizationMetadata()`:**

```cpp
OptimizationMetadata& DeconvolvedSpectrum::getOrCreateOptimizationMetadata()
{
  if (!opt_metadata_)
  {
    opt_metadata_ = OptimizationMetadata{};
  }
  return *opt_metadata_;
}
```

**b) Implement `getOptimizationMetadata()`:**

```cpp
const OptimizationMetadata* DeconvolvedSpectrum::getOptimizationMetadata() const
{
  if (opt_metadata_)
  {
    return &(*opt_metadata_);
  }
  return nullptr;
}
```

**c) Implement `hasOptimizationMetadata()`:**

```cpp
bool DeconvolvedSpectrum::hasOptimizationMetadata() const
{
  return opt_metadata_.has_value();
}
```

**d) Modify `toSpectrum()` to serialize metadata when present:**

Locate the existing `toSpectrum()` method body. At the end of the method, immediately before the `return` statement (or after all existing `out_spec` field assignments), add the following block:

```cpp
if (opt_metadata_)
{
  out_spec.setMetaValue("optimization_group_id",
                        static_cast<int>(opt_metadata_->group_id));
  out_spec.setMetaValue("optimization_collision_energy",
                        opt_metadata_->collision_energy);
  out_spec.setMetaValue("optimization_is_best_variant",
                        opt_metadata_->is_best_variant ? std::string("true") : std::string("false"));
  out_spec.setMetaValue("optimization_quality_score",
                        opt_metadata_->fragmentation_quality_score);
  out_spec.setMetaValue("optimization_precursor_mass",
                        opt_metadata_->precursor_mass);
}
```

These five keys are the ones specified in Issue 9 of `baseline-plan.md`. Additional fields can be serialized in Phase 7 when the exploration engine populates them, but the keys above must be present and correct for Phase 2 test P2-U04 to pass.

The `setMetaValue` overload accepts `(const String&, const DataValue&)`. `DataValue` has constructors from `int`, `double`, and `std::string`, so no explicit casts are required beyond the `static_cast<int>` for `group_id` (to disambiguate from `double`).

---

### Step 3b — Implement deferred `GetConfigInt` / `GetConfigDouble` bridge functions

**Deferred from Phase 1 (Phase 1 compliance report §3, §5).**

The C# side already has P/Invoke stubs for `GetConfigInt` and `GetConfigDouble` in `BridgeSmokeTests.cs`, guarded with an `EntryPointNotFoundException` catch so that P1-I03 passes without the C++ exports being present. Phase 2's DLL rebuild is the designated opportunity to implement these exports so that the P1-I03 diagnostic assertions auto-activate.

**Files to modify:**
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` — add declarations for `GetConfigInt` and `GetConfigDouble`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` — add implementations that read the stored config values from the `FLASHIda` instance

Batch this change with the `OptimizationMetadata` C++ changes in the same submodule commit to avoid a second 40-minute DLL rebuild. Both the C++ bridge file and `DeconvolvedSpectrum.cpp` can go in the same push.

**Note on DLL name:** The P/Invoke declarations in C# use `"OpenMS.dll"` (with `.dll` extension), not `"OpenMS"`. Ensure any new `[DllImport]` attributes follow this convention.

---

### Step 4 — Create the C++ unit test file

**File to create:**
`OpenMS/src/tests/class_tests/openms/source/DeconvolvedSpectrum_OptimizationMetadata_test.cpp`

This is the test binary that CTest will discover via `executables.cmake`. The file uses the OpenMS `ClassTest` macros (`START_TEST`, `END_TEST`, `TEST_EQUAL`, `TEST_NOT_EQUAL`, `TEST_REAL_SIMILAR`, `TEST_STRING_EQUAL`).

Implement the five unit tests as follows:

```cpp
// DeconvolvedSpectrum_OptimizationMetadata_test.cpp

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h>
#include <OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h>

using namespace OpenMS;

START_TEST(DeconvolvedSpectrum_OptimizationMetadata, "$Id$")

/////////////////////////////////////////////////////////////

START_SECTION(hasOptimizationMetadata_default_false)
{
  DeconvolvedSpectrum ds(1); // scan_number = 1
  TEST_EQUAL(ds.hasOptimizationMetadata(), false)
}
END_SECTION

START_SECTION(getOrCreateOptimizationMetadata_creates_and_returns_true)
{
  DeconvolvedSpectrum ds(1);
  TEST_EQUAL(ds.hasOptimizationMetadata(), false)
  OptimizationMetadata& meta = ds.getOrCreateOptimizationMetadata();
  TEST_EQUAL(ds.hasOptimizationMetadata(), true)
  // Pointer from getOptimizationMetadata should now be non-null
  TEST_NOT_EQUAL(ds.getOptimizationMetadata(), (const OptimizationMetadata*)nullptr)
}
END_SECTION

START_SECTION(metadata_field_defaults)
{
  DeconvolvedSpectrum ds(1);
  OptimizationMetadata& meta = ds.getOrCreateOptimizationMetadata();
  TEST_EQUAL(meta.group_id, 0)
  TEST_EQUAL(meta.variant_index, -1)
  TEST_EQUAL(meta.total_variants, 0)
  TEST_EQUAL(meta.is_best_variant, false)
  TEST_EQUAL(meta.rank, 0)
  TEST_EQUAL(meta.msn_level_optimized, 0)
  TEST_EQUAL(meta.parent_tracking_id, 0)
  TEST_REAL_SIMILAR(meta.collision_energy, 0.0)
  TEST_REAL_SIMILAR(meta.isolation_width, 0.0)
  TEST_STRING_EQUAL(meta.activation_type, "")
  TEST_REAL_SIMILAR(meta.precursor_mass, 0.0)
  TEST_EQUAL(meta.precursor_charge, 0)
  TEST_REAL_SIMILAR(meta.fragmentation_quality_score, -1.0)
  TEST_EQUAL(meta.fragment_count, 0)
  TEST_EQUAL(meta.exploration_scans, 0)
}
END_SECTION

START_SECTION(toSpectrum_serializes_metadata_via_setMetaValue)
{
  DeconvolvedSpectrum ds(2); // scan_number = 2
  OptimizationMetadata& meta = ds.getOrCreateOptimizationMetadata();
  meta.group_id = 42;
  meta.collision_energy = 25.0;
  meta.is_best_variant = true;
  meta.fragmentation_quality_score = 0.87;
  meta.precursor_mass = 15432.5;

  MSSpectrum out_spec = ds.toSpectrum(1);

  TEST_EQUAL((int)out_spec.getMetaValue("optimization_group_id"), 42)
  TEST_REAL_SIMILAR((double)out_spec.getMetaValue("optimization_collision_energy"), 25.0)
  TEST_STRING_EQUAL((std::string)out_spec.getMetaValue("optimization_is_best_variant"), "true")
  TEST_REAL_SIMILAR((double)out_spec.getMetaValue("optimization_quality_score"), 0.87)
  TEST_REAL_SIMILAR((double)out_spec.getMetaValue("optimization_precursor_mass"), 15432.5)
}
END_SECTION

START_SECTION(toSpectrum_without_metadata_sets_no_optimization_metavalues)
{
  DeconvolvedSpectrum ds(1);
  // Do NOT call getOrCreateOptimizationMetadata()
  TEST_EQUAL(ds.hasOptimizationMetadata(), false)

  MSSpectrum out_spec = ds.toSpectrum(1);

  // None of the optimization metakeys should be present
  TEST_EQUAL(out_spec.metaValueExists("optimization_group_id"), false)
  TEST_EQUAL(out_spec.metaValueExists("optimization_collision_energy"), false)
  TEST_EQUAL(out_spec.metaValueExists("optimization_is_best_variant"), false)
  TEST_EQUAL(out_spec.metaValueExists("optimization_quality_score"), false)
  TEST_EQUAL(out_spec.metaValueExists("optimization_precursor_mass"), false)
}
END_SECTION

/////////////////////////////////////////////////////////////

END_TEST
```

**Important:** The `toSpectrum()` call signature must match the actual existing signature in `DeconvolvedSpectrum.h`. Before writing the test, read the existing `DeconvolvedSpectrum.h` to confirm the exact parameters of `toSpectrum()`. Adjust the test call accordingly.

Similarly, the `DeconvolvedSpectrum` constructor signature (whether it takes an `MSSpectrum`, an `int ms_level`, or other arguments) must match the existing API. Read the existing header before writing the test.

---

### Step 5 — Register the test in `executables.cmake`

**File to modify:**
`OpenMS/src/tests/class_tests/openms/executables.cmake`

The FLASH test entries are currently commented out. Either uncomment the existing entries if the test binary name matches, or add a new entry for the Phase 2 test binary. The entry format follows the OpenMS convention:

```cmake
set(executables
  # ... existing entries ...
  DeconvolvedSpectrum_OptimizationMetadata_test
  # ... other FLASH entries, uncommented as needed ...
)
```

If there is a separate `FLASH_executables.cmake` or a conditional block for FLASH tests, uncomment the appropriate block or add the new entry within it.

Verify the test binary is discoverable by confirming the `cpp-unit-tests` CI job on `ubuntu-latest` picks up and runs `DeconvolvedSpectrum_OptimizationMetadata_test` without error. If it does not appear, check that the `executables.cmake` change is included by the parent `CMakeLists.txt` for the class tests directory.

---

### Step 6 — Verify `toSpectrum()` signature compatibility

Before the build, read the existing `DeconvolvedSpectrum.h` and `DeconvolvedSpectrum.cpp` to confirm:

1. The exact signature of `toSpectrum()`. The test in Step 4 and the `if (opt_metadata_)` block in Step 3 must use the same parameter names and return type.
2. Where the `return` or the final output statement is in `toSpectrum()` to ensure the metadata serialization block is inserted at the correct position.
3. Whether `out_spec` is the name used for the output `MSSpectrum` inside `toSpectrum()`. If a different name is used, update the block in Step 3 accordingly.
4. Whether `MSSpectrum::metaValueExists()` is the correct method for checking the absence of a meta key in P2-U05. The OpenMS API may use `MetaInfoInterface::metaValueExists()` as an inherited method.

These verifications ensure the diff is correct before committing.

---

## Files to Create or Modify

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h` | **Create** | Struct definition with all 18 fields and their default values. |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h` | **Modify** | Add `#include <optional>`, `#include <OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h>`, private member `std::optional<OptimizationMetadata> opt_metadata_`, and three public accessor declarations. |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.cpp` | **Modify** | Implement `getOrCreateOptimizationMetadata()`, `getOptimizationMetadata()`, `hasOptimizationMetadata()`. Add `if (opt_metadata_)` serialization block to `toSpectrum()`. |
| `OpenMS/src/tests/class_tests/openms/source/DeconvolvedSpectrum_OptimizationMetadata_test.cpp` | **Create** | Five C++ unit tests (P2-U01 through P2-U05) using the OpenMS ClassTest framework. |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | **Modify** | Uncomment FLASH test entries and/or add `DeconvolvedSpectrum_OptimizationMetadata_test`. |

No C# files change in this phase. No bridge functions change. No `method.xml` or config files change.

---

## Test Cases

All six tests for Phase 2 come from the testing strategy. Five are C++ unit tests (Tier 1) run on `ubuntu-latest`; one is a regression test (Tier 3) run on `windows-latest`.

### Test Summary (Quick Reference)

| Test ID | Tier | One-line summary |
|---------|------|-----------------|
| P2-U01 | 1 (C++ unit) | A default-constructed `DeconvolvedSpectrum` reports no metadata (`hasOptimizationMetadata()` returns `false`). |
| P2-U02 | 1 (C++ unit) | Calling `getOrCreateOptimizationMetadata()` creates the metadata object and transitions `hasOptimizationMetadata()` to `true`. |
| P2-U03 | 1 (C++ unit) | All 15 checked fields of a freshly created `OptimizationMetadata` carry the specified default values (e.g. `variant_index == -1`, `fragmentation_quality_score == -1.0`). |
| P2-U04 | 1 (C++ unit) | `toSpectrum()` writes all five `optimization_*` metavalues onto the output `MSSpectrum` when metadata is present and populated. |
| P2-U05 | 1 (C++ unit) | `toSpectrum()` sets none of the five `optimization_*` metavalues when no metadata has been created, confirming zero overhead on normal spectra. |
| P2-R01 | 3 (regression) | `Flash.exe <input> <output> <method>` with `ms1_smoke_test.txt` and `method_default.xml` produces output identical to `baseline_phase0.tsv`, confirming zero behavioral change. |

### P2-U01

| Field | Value |
|-------|-------|
| Test ID | P2-U01 |
| Tier | 1 (C++ unit) |
| Description | A default-constructed `DeconvolvedSpectrum` has no metadata |
| Implementation | Construct `DeconvolvedSpectrum`, call `hasOptimizationMetadata()` |
| Expected outcome | Returns `false` |
| CI runner | `ubuntu-latest` via CTest (`ctest -R DeconvolvedSpectrum_OptimizationMetadata_test`) |
| Test file | `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` section `hasOptimizationMetadata_default_false` |

### P2-U02

| Field | Value |
|-------|-------|
| Test ID | P2-U02 |
| Tier | 1 (C++ unit) |
| Description | `getOrCreateOptimizationMetadata()` creates the metadata object |
| Implementation | Construct `DeconvolvedSpectrum`, call `getOrCreateOptimizationMetadata()`, then call `hasOptimizationMetadata()` and `getOptimizationMetadata()` |
| Expected outcome | `hasOptimizationMetadata()` returns `true`; `getOptimizationMetadata()` returns a non-null pointer |
| CI runner | `ubuntu-latest` via CTest |
| Test file | `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` section `getOrCreateOptimizationMetadata_creates_and_returns_true` |

### P2-U03

| Field | Value |
|-------|-------|
| Test ID | P2-U03 |
| Tier | 1 (C++ unit) |
| Description | Metadata fields have correct defaults after `getOrCreateOptimizationMetadata()` |
| Implementation | Construct, create metadata, check every field against its specified default value |
| Expected outcome | `group_id == 0`, `variant_index == -1`, `fragmentation_quality_score == -1.0`, `is_best_variant == false`, all others zero/empty |
| CI runner | `ubuntu-latest` via CTest |
| Test file | `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` section `metadata_field_defaults` |

### P2-U04

| Field | Value |
|-------|-------|
| Test ID | P2-U04 |
| Tier | 1 (C++ unit) |
| Description | `toSpectrum()` serializes metadata fields via `setMetaValue()` when metadata is present |
| Implementation | Construct `DeconvolvedSpectrum`, create metadata, set `group_id=42`, `collision_energy=25.0`, `is_best_variant=true`, `fragmentation_quality_score=0.87`, `precursor_mass=15432.5`. Call `toSpectrum()`. Check the five `optimization_*` metavalues on the returned `MSSpectrum`. |
| Expected outcome | `optimization_group_id == 42`, `optimization_collision_energy == 25.0`, `optimization_is_best_variant == "true"`, `optimization_quality_score == 0.87`, `optimization_precursor_mass == 15432.5` |
| CI runner | `ubuntu-latest` via CTest |
| Test file | `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` section `toSpectrum_serializes_metadata_via_setMetaValue` |

### P2-U05

| Field | Value |
|-------|-------|
| Test ID | P2-U05 |
| Tier | 1 (C++ unit) |
| Description | `toSpectrum()` does not set any `optimization_*` metavalues when no metadata is present |
| Implementation | Construct `DeconvolvedSpectrum` without calling `getOrCreateOptimizationMetadata()`. Call `toSpectrum()`. Check that none of the five `optimization_*` keys exist on the output spectrum. |
| Expected outcome | `metaValueExists("optimization_group_id")` returns `false` (and similarly for the other four keys) |
| CI runner | `ubuntu-latest` via CTest |
| Test file | `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` section `toSpectrum_without_metadata_sets_no_optimization_metavalues` |

### P2-R01

| Field | Value |
|-------|-------|
| Test ID | P2-R01 |
| Tier | 3 (regression) |
| Description | `Flash.exe` produces output identical to the Phase 0/1 golden files |
| Implementation | Run `Flash.exe test-data/spectra/ms1_smoke_test.txt output.tsv test-data/configs/method_default.xml`. Compare `output.tsv` to `FlashIDA/test-data/golden/baseline_phase0.tsv` using `compare_golden.py`. Entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1). |
| Expected outcome | `PASS` — row count identical, all floating-point values within tolerance, all string columns exact match. No `optimization_*` keys appear in the TSV (because no code populates metadata during normal operation). |
| CI runner | `windows-latest` (requires OpenMS DLLs in `FlashIDA/dll/` and Thermo iAPI DLLs in `FlashIDA/dependencies/`) |
| Test file | `flashida-ci.yml` `windows-tests` job, regression step |

**Cross-reference note:** Resolved: P2-R01 uses `ms1_smoke_test.txt` per spec doc §1.1. Phase 2 is a zero-behavioral-change phase; using the minimal smoke test input is sufficient. The golden file format and column schema are specified in spec doc Section 2.1; `baseline_phase0.tsv` provenance is in Section 2.2. The `compare_golden.py` comparison rules (float tolerances, exact-match columns) are in spec doc Section 4.1.

---

## CI Configuration

### Jobs affected

Phase 2 activates the `cpp-unit-tests` job for the first time. The `cpp-unit-tests` job activates as a separate job (unchanged from the workflow skeleton established in Phase 0). The `windows-tests` job continues unchanged (P2-R01 is a straight `Flash.exe` regression). No new jobs are needed.

**Dry-run activation (Phase 0 compliance report I-5):** The `cpp-unit-tests` job has `if: false` in the workflow and has never executed. Its build resource requirements (RAM, core count on `ubuntu-latest`) are untested. Before adding Phase 2 code changes, activate the job by removing `if: false` in a separate commit to validate that the build infrastructure works end-to-end. If the dry-run fails, diagnose the CI setup independently before introducing C++ source changes.

### `cpp-unit-tests` job requirements

The job runs on `ubuntu-latest`. It must:

1. Check out the repository with the OpenMS submodule (`--recurse-submodules`).
2. Restore the CMake/ccache cache (keyed on the OpenMS submodule commit hash and the OS).
3. Configure CMake for the OpenMS test-only build target (does not build the full library — only the class test binaries listed in `executables.cmake`).
4. Build the `DeconvolvedSpectrum_OptimizationMetadata_test` binary (and any other FLASH test binaries newly uncommented in `executables.cmake`).
5. Run `ctest -R DeconvolvedSpectrum_OptimizationMetadata` to execute the Phase 2 test. (Note: if running all FLASH-related tests generically, the actual `-R` pattern depends on the test names registered in `executables.cmake`.)
6. Fail the job if any test exits non-zero.

The job does NOT require Windows, .NET, Thermo DLLs, or OpenMS DLLs. It is a pure C++ build-and-run on Linux.

**Submodule workflow note (Phase 0 lesson #15, Phase 1 lesson #1):** Phase 2 changes are entirely within the OpenMS submodule (C++ only). After pushing C++ changes to the submodule branch, always `git add OpenMS` in the parent repo and push the updated submodule pointer before expecting CI to pick up the changes. CI checks out submodules at the pointer commit, not at the branch HEAD — new files pushed to a submodule branch are silently invisible to CI until the pointer is updated. Batch all C++ changes into as few submodule pointer updates as possible to reduce commit churn — Phase 0 saw 48% of commits (13/27) as submodule pointer updates.

**DLL build time note (Phase 1 lesson #10):** Each push to the C++ submodule that misses the ccache triggers a full OpenMS build on `windows-2022` taking 35–40 minutes. Batch ALL C++ changes (OptimizationMetadata, `GetConfigInt`/`GetConfigDouble`, and any pre-existing MSVC fixes) into a single push to minimize rebuild cycles. Check for MSVC `/WX` issues (unused parameters `C4100`, unused variables `C4189`) locally or via a test compile before pushing — each failed build wastes 40 minutes.

### Conditional trigger

The `cpp-unit-tests` job should trigger whenever C++ files change under `OpenMS/src/openms/`. The existing `if:` condition in the workflow template (`# only when C++ files changed`) should be implemented as a path filter:

```yaml
cpp-unit-tests:
  runs-on: ubuntu-latest
  if: >
    github.event_name == 'push' ||
    contains(join(github.event.pull_request.changed_files, ','), 'OpenMS/src/openms/')
```

Alternatively, use the `paths` trigger at the workflow level or a separate per-job condition. The exact mechanism depends on the workflow structure established in Phase 0.

### ccache configuration

The C++ unit test build should use ccache to avoid rebuilding unchanged translation units. The cache key includes the OS, the OpenMS submodule commit hash, and a hash of `executables.cmake`. Example:

```yaml
- name: Restore ccache
  uses: actions/cache@v4
  with:
    path: ~/.ccache
    key: ccache-ubuntu-${{ steps.openms-hash.outputs.hash }}-${{ hashFiles('OpenMS/CMakeLists.txt') }}
    restore-keys: |
      ccache-ubuntu-${{ steps.openms-hash.outputs.hash }}-
      ccache-ubuntu-
```

### `executables.cmake` change impact

Uncommenting FLASH test entries in `executables.cmake` means CTest will attempt to build and run all previously-commented FLASH tests, not just the new Phase 2 test. Before uncommenting all of them, verify that:

- The existing FLASH test binaries compile against the current C++ source.
- No previously-passing FLASH test is inadvertently broken by the Phase 2 changes.

If older FLASH tests are broken or not yet applicable, add only the Phase 2 test entry (`DeconvolvedSpectrum_OptimizationMetadata_test`) in a minimal change, and uncomment the remaining entries incrementally in subsequent phases.

### P2-R01 in the `windows-tests` job

No changes to the `windows-tests` job configuration. The regression step already runs `Flash.exe <input> <output> <method>` and compares against golden files. P2-R01 passes when the output is byte-for-byte compatible with `baseline_phase0.tsv` (within floating-point tolerance). No new step is needed.

**NUnit configuration note (Phase 1 lessons #7, #8):** The `windows-tests` job must run NUnit with `--agents=1 --timeout=300000`. The `--agents=1` flag prevents parallel execution that can cause concurrent cold-cache computations of `calculateAveragine` (~3.5 min per process). The `--timeout=300000` (5 minutes) is required because the first test to construct a `FLASHIdaWrapper` triggers this cold cache. The `OPENMS_DATA_PATH` environment variable must be set to `${{ github.workspace }}/OpenMS/share/OpenMS` in the NUnit test step — without it, any test that exercises C++ code paths calling `ResidueDB` or `ModificationsDB` will crash the NUnit agent process with a `Cannot find shared data!` fatal error. This crash manifests as `System.Net.Sockets.SocketException` in NUnit output (Agent Process terminated) with `Test Count: 0`. If this occurs, re-run with `--inprocess` to capture the actual C++ error message before investigating further.

**compare_golden.py column classification note (Phase 0 compliance report L-2):** The script classifies only `charges` as string and `hcd` as integer — all other columns are treated as float. Phase 2 is a zero-behavioral-change phase and adds no new TSV columns, so this is not an issue here. However, if future phases add new non-float columns to the TSV output, the `STRING_COLUMNS` or `INT_COLUMNS` sets in `compare_golden.py` must be updated before running the regression comparison.

---

## Working Product Verification

After implementing all steps and before marking the phase complete:

### 1. C++ unit tests pass

Verified by the `cpp-unit-tests` CI job on `ubuntu-latest`. The job builds and runs `ctest -R DeconvolvedSpectrum_OptimizationMetadata_test`. All 5 test sections must report `OK` with no compile errors.

### 2. `Flash.exe` runs with no behavioral change

Verified by the `windows-tests` CI job on `windows-latest`. The job runs `Flash.exe <input> <output> <method>` and compares `output.tsv` against `baseline_phase0.tsv`. Expected: process exits 0, `output.tsv` is produced, content is identical to `baseline_phase0.tsv`. The 15-column TSV schema and float tolerance rules used by `compare_golden.py` are defined in [../test-file-specification.md](../test-file-specification.md) Sections 2.1 and 4.1. `baseline_phase0.tsv` provenance is documented in spec doc Section 2.2; update procedure in Section 2.4. Golden file changes during Phase 2 (a zero-behavioral-change phase) are a red flag per spec doc Section 2.4.

### 3. `hasOptimizationMetadata()` returns false in normal operation

This is confirmed by P2-U01 and by P2-R01: if any code in the normal deconvolution path accidentally called `getOrCreateOptimizationMetadata()`, the `toSpectrum()` serialization block would add `optimization_*` columns to the TSV output, causing the golden file comparison to fail.

### 4. No changes to the P/Invoke bridge

Verified by the `windows-tests` CI job on `windows-latest`. The Phase 0 bridge smoke tests (P0-I01, P0-I02) confirm that `CreateFLASHIda` and `DisposeFLASHIda` are unaffected. Expected: both P0-I01 and P0-I02 pass. **Note:** The C++ engine returns 0 results (not an error code) for malformed input — silent P/Invoke failures are possible (Phase 0 lesson #14). If bridge tests return 0 results unexpectedly, verify input data characteristics before investigating engine internals.

### 5. All prior tests still pass

Verified by the `windows-tests` CI job on `windows-latest`. Expected: all Phase 0 and Phase 1 tests pass (53 tests green after Phase 1). No regressions introduced.

**Constructor overloading note (Phase 1 lesson #11):** Phase 1 added `FLASHIdaWrapper(MethodParameters mp)` as a new overload while keeping the existing `FLASHIdaWrapper(IDAParameters param)`. Both constructors coexist and are exercised by different tests. Phase 2 adds no C# changes, but any future Phase 2 implementation work that touches `FLASHIdaWrapper.cs` must preserve both constructors. The old constructor uses `ToFLASHDeconvInput()` (legacy space-delimited string); the new constructor uses `ToJSON()`. The C++ side auto-detects the format via `arg[0] == '{'`.

### 6. Test data paths use correct relative root

Any C# test code introduced in Phase 2 that loads test data must use `Path.Combine(TestContext.CurrentContext.TestDirectory, "..", "test-data")` — one level up from `FlashIDA/bin/`. Using `"..","..","test-data"` reaches the parent repo root instead (Phase 1 lesson #2). All existing test classes use the one-level-up convention; new code must follow it.

---

## Definition of Done

The following checklist must be satisfied before Phase 2 is considered complete and before Build #1 is assembled (which also includes Phase 1 and Phase 3):

- [x] `OptimizationMetadata.h` created at `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/OptimizationMetadata.h` with all 18 fields and correct default values.
- [x] `DeconvolvedSpectrum.h` updated: `<optional>` included, `OptimizationMetadata.h` included, `opt_metadata_` private member added, three accessor declarations present.
- [x] `DeconvolvedSpectrum.cpp` updated: three accessor methods implemented, `if (opt_metadata_)` serialization block added to `toSpectrum()` with the five specified metavalue keys.
- [x] `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` created with five test sections matching P2-U01 through P2-U05.
- [x] `executables.cmake` modified to include `DeconvolvedSpectrum_OptimizationMetadata_test` (and FLASH entries uncommented as appropriate).
- [x] P2-U01 passes: `hasOptimizationMetadata()` returns `false` on default construction.
- [x] P2-U02 passes: `getOrCreateOptimizationMetadata()` transitions `hasOptimizationMetadata()` to `true`.
- [x] P2-U03 passes: all 15 checked fields have correct defaults.
- [x] P2-U04 passes: `toSpectrum()` sets all five `optimization_*` metavalues correctly when metadata is present.
- [x] P2-U05 passes: `toSpectrum()` sets none of the five `optimization_*` metavalues when metadata is absent.
- [x] P2-R01 passes: `Flash.exe` with `ms1_smoke_test.txt` and `method_default.xml` produces output matching `baseline_phase0.tsv` exactly (within tolerance).
- [x] All Phase 0 tests (P0-U01 through P0-R01) continue to pass.
- [x] All Phase 1 tests (P1-U01 through P1-R02) continue to pass.
- [x] `GetConfigInt` and `GetConfigDouble` C++ bridge exports implemented in `FLASHIdaBridgeFunctions.cpp` (deferred from Phase 1). P1-I03 diagnostic assertions auto-activate (no longer caught by `EntryPointNotFoundException`).
- [x] `cpp-unit-tests` CI job dry-run passes (job activated with `if: false` removed, no Phase 2 code yet) before C++ code is added.
- [x] `cpp-unit-tests` CI job is active and passes on `ubuntu-latest` with no Thermo or Windows dependency.
- [x] CI `cpp-unit-tests` job passes with zero warnings.
- [ ] Code review: a second developer has confirmed the `toSpectrum()` insertion point is correct and does not break any existing `MSSpectrum` field assignments above it.

---

## Phase 0-1 Lessons Applied

This section summarises the corrections and additions made to this plan based on `Phase_0/lessons-learned.md`, `Phase_1/lessons-learned.md`, `Phase_0/compliance-report.md`, and `Phase_1/compliance-report.md`. It serves as a quick reference for reviewers.

| # | Source | Topic | Correction Applied |
|---|--------|-------|--------------------|
| 1 | P0-LL #1, P0-CR M-4 | Flash.exe entry point | P2-R01 already documented the correct invocation (`Flash.exe <input> <output> <method>`). No `-t` flag was present in this plan; confirmed clean. |
| 2 | P0-LL #12.1, P0-CR M-2 | Build output path | No `FlashIDA/src/Flash/bin/Debug/` references were present in this plan. |
| 3 | P0-LL #3, P0-CR I-1 | Thermo DLL strategy | No Strategy A / base64 references present. Confirmed Strategy B (openssl-encrypted zip / `THERMO_DLL_PASSPHRASE`) is implied by Phase 0 infrastructure. |
| 4 | P0-LL #5, P0-CR I-1 | OpenMS DLLs | No download steps present. DLLs are committed in `FlashIDA/dll/` and copied by MSBuild. |
| 5 | P1-LL #2 | Test data path | Added note in Working Product Verification §6: use `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/`. |
| 6 | P1-LL #7, #8 | NUnit configuration | Added note in CI §P2-R01: `--agents=1 --timeout=300000` required; `OPENMS_DATA_PATH` must be set. `--inprocess` for debugging SocketException / Agent Process terminated. |
| 7 | P0-CR I-5 | cpp-unit-tests dry run | Added dry-run activation step: activate the job (`if: false` removed) in a separate commit before adding Phase 2 code. Added DoD checklist item. |
| 8 | P1-CR §3 (Deferred items) | GetConfigInt/GetConfigDouble | Added Step 3b: implement C++ bridge exports during Phase 2 DLL rebuild, batched with OptimizationMetadata. Added DoD checklist item. |
| 9 | P0-CR L-2 | compare_golden.py columns | Added note in CI §P2-R01: script only classifies `charges` (string) and `hcd` (int). New non-float columns in future phases must update `STRING_COLUMNS` / `INT_COLUMNS`. |
| 10 | P1-LL #3 | MSVC /WX warnings-as-errors | Added note in DLL build time section: check for C4100/C4189 before pushing to avoid 40-min wasted builds. |
| 11 | P1-LL #10 | DLL build ~40 min | Added DLL build time note in CI §submodule: batch all C++ changes into a single push. |
| 12 | P1-LL #1, P0-LL #15 | Submodule pointer update | Strengthened submodule workflow note: push submodule pointer in parent repo after every submodule branch push; CI uses pointer commit not branch HEAD. |
| 13 | P1-LL #11 | Constructor overloading | Added note in Working Product Verification §5: both `FLASHIdaWrapper(MethodParameters)` and `FLASHIdaWrapper(IDAParameters)` must be preserved; C++ auto-detects JSON vs legacy string. |
| 14 | P1-LL #7 | NUnit SocketException diagnosis | Added to NUnit configuration note: use `--inprocess` to surface the actual C++ fatal error when NUnit reports `SocketException` / `Test Count: 0`. |
| 15 | P0-LL #12.2 | DLL name in P/Invoke | Added to Step 3b: new `[DllImport]` attributes must use `"OpenMS.dll"` (with extension). |
| 16 | Prerequisites §2 | Phase 1 status | Updated prerequisite from "in-flight / same Build #1" to "complete": 53 tests passing, golden JSON files committed, `GetConfigInt`/`GetConfigDouble` stubs present, both constructors coexist. |

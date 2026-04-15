# MS3 Subsequence-Based Fragment Scoring for Exploration

**Date:** 2026-04-15
**Status:** Approved
**Scope:** C++ only — new `MS3FragmentMatcher` class, changes to `Exploration` and `ExplorationGroup`

## Problem

The `FragmentCount` exploration metric at the MS3 level currently scores CE variants by running the full FLASHTagger/FLASHExtender pipeline against the entire protein sequence. This is both inaccurate (MS3 spectra contain fragments of a *subsequence*, not the whole protein) and inefficient (tagging may fail on short MS3 spectra). The offline Python analysis (`linear_mass_calc.py`) demonstrates a better approach: compute theoretical masses directly from the precursor fragment's subsequence, handle MS3-specific ion types (including cross-direction ions yb/ya), apply two-pass mass calibration, and match deconvolved masses against the theoretical table.

## Design

### New class: `MS3FragmentMatcher`

**Files:**
- `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h`
- `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`

A stateless utility class (all static methods) that ports the Python script's theoretical mass calculation, matching, and calibration logic to C++.

#### Ion shifts

| Ion type | Shift (Da) | Direction | When used |
|----------|-----------|-----------|-----------|
| a | -27.994915 | Prefix (N→C) | b-precursor, y-precursor |
| b | 0.0 | Prefix (N→C) | b-precursor, y-precursor |
| y | +18.010565 | Suffix (C→N) | y-precursor only |
| yb | 0.0 | Suffix (C→N) | b-precursor only (no water — broken C-terminus) |
| ya | -27.994915 | Suffix (C→N) | b-precursor only (no water, minus CO) |

Constants: `PROTON_MASS = 1.007276 Da`, `WATER_MASS = 18.010565 Da`.

#### `getMS3IonTypes(char precursor_ion_class)`

- `'b'` (or `'a'`) → `{"a", "b", "yb", "ya"}`
- `'y'` (or `'x'`, `'z'`) → `{"a", "b", "y"}`

#### `TheoreticalMass` struct

```cpp
struct TheoreticalMass
{
  double mass;
  int position;          // 0-based in subsequence
  std::string ion_type;  // "a", "b", "y", "yb", "ya"
  bool includes_ptm;     // true = PTM mass included (for ambiguous PTMs)
};
```

#### `computeTheoreticalMasses(subsequence, ion_types, ptm_sites)`

Port of the Python `calculate_theoretical_masses()`. For each ion type:

1. **Prefix ions (a, b):** Cumulative sum of residue masses from the N-terminus. At position `i`, mass = `sum(residue[0..i]) + ion_shift + fixed_ptm_contribution_at_or_before[i]`.
2. **Suffix ions (y, yb, ya):** Cumulative sum from the C-terminus. At position `i` (counting from C-terminus), mass = `sum(residue[len-i..len-1]) + ion_shift + fixed_ptm_contribution_at_or_after[len-i]`.

Residue masses from OpenMS `ResidueDB::getInstance()->getResidue(aa)->getMonoWeight(Residue::Internal)`.

**PTM handling:**
- **Fixed PTMs** (`start_position == end_position`): Always added to the cumulative sum when the ion covers that position.
- **Ambiguous PTMs** (`start_position != end_position`): At positions that partially overlap the ambiguity range, two `TheoreticalMass` entries are generated — one with `includes_ptm = true` (mass includes `mass_shift`) and one with `includes_ptm = false`. Positions fully before or fully after the ambiguity region get a single entry.

#### `matchSpectrum(spectrum, theoretical, tolerance_ppm, ppm_errors*)`

For each deconvolved mass in `spectrum`, find the closest `TheoreticalMass` within `tolerance_ppm`. Greedy matching: each theoretical mass matched at most once, smallest ppm error wins. Returns the match count. If `ppm_errors` is non-null, appends signed ppm errors for all matches (used for calibration).

#### `calibrateAndScore(variant_spectra, protein_sequence, proteoform_ctx, fragment_ion_type, fragment_ion_index, loose_tol, tight_tol)`

The two-pass pipeline, called once per exploration group when all variants have returned:

1. **Extract subsequence:** Using `proteoform_ctx.region_start`, `region_end`, `fragment_ion_type`, and `fragment_ion_index`:
   - b-precursor (index N): `protein[region_start .. region_start + N)`
   - y-precursor (index N): `protein[region_end - N .. region_end)`
2. **Rebase PTM sites:** Clip and shift `proteoform_ctx.ptm_sites` to subsequence coordinates.
3. **Determine ion types:** `getMS3IonTypes(fragment_ion_type)`
4. **Compute theoretical masses** once (shared across all variants).
5. **Pass 1 — Calibration:** Call `matchSpectrum` on each variant at `loose_tol` (500 ppm), collect all ppm errors across all variants. Compute global median ppm error. Derive correction factor: `1.0 / (1.0 + median_ppm * 1e-6)`.
6. **Pass 2 — Scoring:** Apply correction factor to each variant's deconvolved masses. Call `matchSpectrum` at `tight_tol` (from `config.level(3).tolerance_ppm`). Return per-variant fragment counts.

### ProteoformContext — cached MS2 result

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h` (inside or alongside `ExplorationGroup`)

```cpp
struct ProteoformContext
{
  int region_start = -1;  // 0-based start in protein sequence
  int region_end = -1;    // 0-based exclusive end
  std::vector<FragmentAnalysis::PTMSite> ptm_sites;  // 1-based positions, as from runTagBasedFragmentMatching_
};
```

Reuses the existing `FragmentAnalysis::PTMSite` struct (fields: `position`, `start_position`, `end_position`, `mass_shift` — all 1-based).

### ExplorationGroup changes

**File:** `Exploration.h`

Add field: `ProteoformContext proteoform_ctx;`

Populated in `initiateNextLevel()` when `current_level == 2` (MS2 → MS3 transition), after `runTagBasedFragmentMatching_()` returns. The proteoform region comes from `ProteinHit` MetaValues `"StartPosition"` (1-based inclusive) and `"EndPosition"` (1-based exclusive), converted to 0-based. PTM sites come from the `ptm_sites` output parameter of `runTagBasedFragmentMatching_()`.

### Exploration scoring changes

**File:** `Exploration.cpp`

In `feedResultImpl_()`, when all variants have returned and the metric is `FragmentCount`:

- **Level >= 3 (new path):** Call `MS3FragmentMatcher::calibrateAndScore()` with the group's variant spectra and cached `proteoform_ctx`. Use the returned per-variant scores to pick the CE winner.
- **Level 2 (unchanged):** Continue calling `computeFragmentMatch_()` per-variant, which uses FLASHTagger against the full protein.

The loose calibration tolerance (500 ppm) is a compile-time constant in `MS3FragmentMatcher`. The tight tolerance comes from `config_.level(3).tolerance_ppm`.

### Output by scenario

**MS3 exploration, FragmentCount metric:**
Before: FLASHTagger against full protein, per-variant scoring, no calibration.
After: Direct theoretical matching against precursor subsequence, two-pass calibration, MS3-specific ion types, PTM-aware dual masses.

**MS3 exploration, other metrics (MassCount, RemainingPrecursor):** Unchanged.

**MS2 exploration, FragmentCount metric:** Unchanged (FLASHTagger path).

**Non-exploration MS3:** Unchanged (no fragment matching).

## Files Modified

1. **New: `MS3FragmentMatcher.h`** — Class declaration, `TheoreticalMass` struct, static method signatures.
2. **New: `MS3FragmentMatcher.cpp`** — Implementation: ion shifts, theoretical mass calculation, matching, calibration.
3. **Modify: `Exploration.h`** — Add `ProteoformContext` struct, add `proteoform_ctx` field to `ExplorationGroup`.
4. **Modify: `Exploration.cpp`**:
   - `initiateNextLevel()`: Cache proteoform region + PTM sites on each MS3 `ExplorationGroup`.
   - `feedResultImpl_()`: Route `FragmentCount` at level >= 3 to `MS3FragmentMatcher::calibrateAndScore()`.
5. **New: `MS3FragmentMatcher_test.cpp`** — Unit tests (see Testing section).
6. **Modify: `executables.cmake`** — Register `MS3FragmentMatcher_test`.

## Not Changed

- `FragmentAnalysis.h/.cpp` — No modifications. PTMSite struct reused as-is.
- `FLASHTaggerAlgorithm` / `FLASHExtenderAlgorithm` — Not called by the new code.
- `Config.h/.cpp` — No new config fields. `FragmentCount` enum value unchanged. Loose calibration tolerance is a constant, not configurable.
- `ScanCommand.h` — Struct layout unchanged.
- `FLASHIda.cpp` — `processScan()` unchanged. Non-exploration MS3 path unchanged.
- `FLASHIdaBridgeFunctions.cpp/.h` — No bridge changes.
- C# side — Unchanged.

## Testing

New test binary: `MS3FragmentMatcher_test` (self-contained, no mzML files).

| Test | What it verifies |
|------|-----------------|
| Ion type selection | `getMS3IonTypes('b')` → {a, b, yb, ya}; `getMS3IonTypes('y')` → {a, b, y} |
| Theoretical masses (no PTMs) | Known 5-residue sequence, verify prefix/suffix masses against hand-calculated values using ResidueDB weights + ion shifts |
| Theoretical masses (fixed PTM) | Fixed PTM at position 2, verify it's always included in cumulative sum past that position |
| Theoretical masses (ambiguous PTM) | Ambiguous PTM spanning positions 1-3, verify dual entries generated at overlapping positions |
| Matching | Synthetic DeconvolvedSpectrum with known masses, verify correct count and ppm errors |
| Calibration | Inject systematic 50 ppm shift into all masses, verify pass 1 recovers the shift, pass 2 matches at tight tolerance |
| Subsequence extraction | b5 from proteoform at region [10, 20) → subsequence is residues 10-14; y3 from same region → residues 17-19; PTMs rebased correctly |

## Future Work (Not in Scope)

- **Reporting:** Log matched fragments with protein-level coordinates (mass offsets, equivalent ions) to scan_results.tsv or a new file. The `TheoreticalMass` struct and match results from `matchSpectrum` provide all data needed.
- **Protein-level mapping:** Port the Python `map_fragment_to_protein()` logic (6-case mass offset calculation) for converting MS3 fragments to equivalent full-protein b/y ions.
- **Non-exploration MS3 matching:** Apply subsequence matching to non-exploration MS3 scans in `processScan()`.

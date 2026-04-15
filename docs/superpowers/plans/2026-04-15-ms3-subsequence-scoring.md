# MS3 Subsequence-Based Fragment Scoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-protein FLASHTagger-based `FragmentCount` scoring at MS3 exploration level with direct theoretical mass matching against the precursor fragment's subsequence, including MS3-specific ion types (yb, ya), PTM-aware dual masses, and two-pass mass calibration across CE variants.

**Architecture:** New `MS3FragmentMatcher` class (all static methods) handles theoretical mass calculation, matching, and calibration. `FragmentAnalysis` caches proteoform region + PTM sites from MS2 matching. `ExplorationGroup` stores this context. `feedResultImpl_()` routes `FragmentCount` at level >= 3 to the new batch scoring pipeline.

**Tech Stack:** C++20 (OpenMS), `ResidueDB` for monoisotopic masses, OpenMS ClassTest framework.

**Spec:** `docs/superpowers/specs/2026-04-15-ms3-subsequence-scoring-design.md`

**Note:** The spec lists FragmentAnalysis as "Not Changed". This plan adds a small caching mechanism (3 member variables + 1 getter) to FragmentAnalysis to expose proteoform region and PTM sites that are already computed internally. This is the minimal change needed to avoid re-running tag-based matching.

---

### Task 1: MS3FragmentMatcher header + ion type selection + test registration

**Files:**
- Create: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h`
- Create: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`
- Create: `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/sources.cmake:12-19`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/sources.cmake:12-20`
- Modify: `OpenMS/src/tests/class_tests/openms/executables.cmake:452-458`

- [ ] **Step 1: Create the header file**

Create `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h`:

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------

#pragma once

#include <OpenMS/ANALYSIS/TOPDOWN/DeconvolvedSpectrum.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h>
#include <OpenMS/OPENMS_DLLAPI.h>

#include <string>
#include <vector>

namespace OpenMS
{

  /**
   * @brief MS3 fragment matching via direct theoretical mass calculation against a precursor subsequence.
   *
   * Scores MS3 exploration CE variants by computing theoretical fragment masses from the
   * MS3 precursor's subsequence (not the full protein), matching deconvolved masses against them,
   * and applying two-pass mass calibration (loose tolerance for calibration, tight for scoring).
   *
   * Handles MS3-specific ion types:
   * - b-precursor: a, b (same direction) + yb, ya (cross-direction, no water)
   * - y-precursor: a, b, y (standard)
   *
   * Supports PTM-aware dual theoretical masses for ambiguous modification regions.
   */
  class OPENMS_DLLAPI MS3FragmentMatcher
  {
  public:
    /// A single theoretical fragment mass entry
    struct TheoreticalMass
    {
      double mass = 0.0;
      int position = 0;         ///< 1-based fragment index from the relevant terminus
      std::string ion_type;     ///< "a", "b", "y", "yb", "ya"
      bool includes_ptm = false; ///< For ambiguous PTMs: true = mass includes PTM shift
    };

    /// Cached proteoform context from MS2 tag-based matching
    struct ProteoformContext
    {
      int region_start = -1;    ///< 0-based start position in protein sequence
      int region_end = -1;      ///< 0-based exclusive end position in protein sequence
      std::vector<FragmentAnalysis::PTMSite> ptm_sites; ///< 1-based positions relative to proteoform
    };

    /// Compile-time constant: loose tolerance for calibration pass
    static constexpr double LOOSE_TOLERANCE_PPM = 500.0;

    // -- Ion type handling --

    /// Select MS3 ion types based on precursor fragment class
    static std::vector<std::string> getMS3IonTypes(char precursor_ion_class);

    /// Returns true for prefix ion types (a, b), false for suffix (y, yb, ya)
    static bool isPrefixIonType(const std::string& ion_type);

    /// Returns the ion mass shift in Da
    static double getIonShift(const std::string& ion_type);

    // -- Theoretical mass calculation --

    /// Compute theoretical fragment masses for a subsequence with optional PTM handling
    static std::vector<TheoreticalMass> computeTheoreticalMasses(
      const std::string& subsequence,
      const std::vector<std::string>& ion_types,
      const std::vector<FragmentAnalysis::PTMSite>& ptm_sites = {});

    // -- Matching --

    /// Match deconvolved masses against theoretical, return match count
    static int matchSpectrum(
      const DeconvolvedSpectrum& spectrum,
      const std::vector<TheoreticalMass>& theoretical,
      double tolerance_ppm,
      std::vector<double>* ppm_errors = nullptr);

    // -- Subsequence extraction + PTM rebasing --

    /// Extract the precursor fragment's subsequence from the protein
    static std::string extractSubsequence(
      const std::string& protein_sequence,
      const ProteoformContext& ctx,
      char fragment_ion_type,
      int fragment_ion_index);

    /// Rebase PTM sites from proteoform coordinates to subsequence coordinates
    static std::vector<FragmentAnalysis::PTMSite> rebasePTMSites(
      const std::vector<FragmentAnalysis::PTMSite>& ptm_sites,
      int subseq_start_in_proteoform,
      int subseq_length);

    // -- Two-pass calibration pipeline --

    /// Score all CE variants via two-pass calibration + matching
    static std::vector<double> calibrateAndScore(
      const std::vector<const DeconvolvedSpectrum*>& variant_spectra,
      const std::string& protein_sequence,
      const ProteoformContext& ctx,
      char fragment_ion_type,
      int fragment_ion_index,
      double loose_tolerance_ppm,
      double tight_tolerance_ppm);

  private:
    static constexpr double PROTON_MASS_ = 1.007276;
    static constexpr double WATER_MASS_ = 18.010565;
    static constexpr double CO_MASS_ = 27.994915;
  };

} // namespace OpenMS
```

- [ ] **Step 2: Create the implementation stub**

Create `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`:

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------

#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h>
#include <OpenMS/CHEMISTRY/Residue.h>
#include <OpenMS/CHEMISTRY/ResidueDB.h>

#include <algorithm>
#include <cmath>
#include <numeric>

namespace OpenMS
{

  std::vector<std::string> MS3FragmentMatcher::getMS3IonTypes(char precursor_ion_class)
  {
    switch (precursor_ion_class)
    {
      case 'b': case 'a': case 'c':
        return {"a", "b", "yb", "ya"};
      case 'y': case 'x': case 'z':
        return {"a", "b", "y"};
      default:
        return {"a", "b", "y"};
    }
  }

  bool MS3FragmentMatcher::isPrefixIonType(const std::string& ion_type)
  {
    return ion_type == "a" || ion_type == "b" || ion_type == "c";
  }

  double MS3FragmentMatcher::getIonShift(const std::string& ion_type)
  {
    if (ion_type == "a")  return -CO_MASS_;
    if (ion_type == "b")  return 0.0;
    if (ion_type == "y")  return WATER_MASS_;
    if (ion_type == "yb") return 0.0;
    if (ion_type == "ya") return -CO_MASS_;
    return 0.0;
  }

  std::vector<MS3FragmentMatcher::TheoreticalMass> MS3FragmentMatcher::computeTheoreticalMasses(
    const std::string& /*subsequence*/,
    const std::vector<std::string>& /*ion_types*/,
    const std::vector<FragmentAnalysis::PTMSite>& /*ptm_sites*/)
  {
    return {}; // stub — implemented in Task 2
  }

  int MS3FragmentMatcher::matchSpectrum(
    const DeconvolvedSpectrum& /*spectrum*/,
    const std::vector<TheoreticalMass>& /*theoretical*/,
    double /*tolerance_ppm*/,
    std::vector<double>* /*ppm_errors*/)
  {
    return 0; // stub — implemented in Task 3
  }

  std::string MS3FragmentMatcher::extractSubsequence(
    const std::string& /*protein_sequence*/,
    const ProteoformContext& /*ctx*/,
    char /*fragment_ion_type*/,
    int /*fragment_ion_index*/)
  {
    return ""; // stub — implemented in Task 4
  }

  std::vector<FragmentAnalysis::PTMSite> MS3FragmentMatcher::rebasePTMSites(
    const std::vector<FragmentAnalysis::PTMSite>& /*ptm_sites*/,
    int /*subseq_start_in_proteoform*/,
    int /*subseq_length*/)
  {
    return {}; // stub — implemented in Task 4
  }

  std::vector<double> MS3FragmentMatcher::calibrateAndScore(
    const std::vector<const DeconvolvedSpectrum*>& /*variant_spectra*/,
    const std::string& /*protein_sequence*/,
    const ProteoformContext& /*ctx*/,
    char /*fragment_ion_type*/,
    int /*fragment_ion_index*/,
    double /*loose_tolerance_ppm*/,
    double /*tight_tolerance_ppm*/)
  {
    return {}; // stub — implemented in Task 4
  }

} // namespace OpenMS
```

- [ ] **Step 3: Create the test file with ion type tests**

Create `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp`:

```cpp
// Copyright (c) 2002-present, OpenMS Inc. -- EKU Tuebingen, ETH Zurich, and FU Berlin
// SPDX-License-Identifier: BSD-3-Clause
//
// --------------------------------------------------------------------------
// $Maintainer: Tom David Mueller $
// $Authors: Tom David Mueller $
// --------------------------------------------------------------------------

#include <OpenMS/CONCEPT/ClassTest.h>
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h>
#include <OpenMS/CHEMISTRY/Residue.h>
#include <OpenMS/CHEMISTRY/ResidueDB.h>

#include <cmath>
#include <string>
#include <vector>

using namespace OpenMS;

START_TEST(MS3FragmentMatcher, "$Id$")

START_SECTION(getMS3IonTypes)
{
  // b-precursor: a, b (same direction) + yb, ya (cross-direction)
  auto b_types = MS3FragmentMatcher::getMS3IonTypes('b');
  TEST_EQUAL(b_types.size(), 4)
  TEST_EQUAL(b_types[0], "a")
  TEST_EQUAL(b_types[1], "b")
  TEST_EQUAL(b_types[2], "yb")
  TEST_EQUAL(b_types[3], "ya")

  // a-precursor: same as b-precursor
  auto a_types = MS3FragmentMatcher::getMS3IonTypes('a');
  TEST_EQUAL(a_types.size(), 4)

  // y-precursor: a, b, y (standard)
  auto y_types = MS3FragmentMatcher::getMS3IonTypes('y');
  TEST_EQUAL(y_types.size(), 3)
  TEST_EQUAL(y_types[0], "a")
  TEST_EQUAL(y_types[1], "b")
  TEST_EQUAL(y_types[2], "y")

  // z-precursor: same as y-precursor
  auto z_types = MS3FragmentMatcher::getMS3IonTypes('z');
  TEST_EQUAL(z_types.size(), 3)

  // Unknown: defaults to y-precursor behavior
  auto unk_types = MS3FragmentMatcher::getMS3IonTypes('?');
  TEST_EQUAL(unk_types.size(), 3)
}
END_SECTION

START_SECTION(isPrefixIonType)
{
  TEST_TRUE(MS3FragmentMatcher::isPrefixIonType("a"))
  TEST_TRUE(MS3FragmentMatcher::isPrefixIonType("b"))
  TEST_TRUE(! MS3FragmentMatcher::isPrefixIonType("y"))
  TEST_TRUE(! MS3FragmentMatcher::isPrefixIonType("yb"))
  TEST_TRUE(! MS3FragmentMatcher::isPrefixIonType("ya"))
}
END_SECTION

START_SECTION(getIonShift)
{
  double co = 27.994915;
  double water = 18.010565;
  TEST_REAL_SIMILAR(MS3FragmentMatcher::getIonShift("a"), -co)
  TEST_REAL_SIMILAR(MS3FragmentMatcher::getIonShift("b"), 0.0)
  TEST_REAL_SIMILAR(MS3FragmentMatcher::getIonShift("y"), water)
  TEST_REAL_SIMILAR(MS3FragmentMatcher::getIonShift("yb"), 0.0)
  TEST_REAL_SIMILAR(MS3FragmentMatcher::getIonShift("ya"), -co)
}
END_SECTION

END_TEST
```

- [ ] **Step 4: Register in CMake**

In `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/sources.cmake`, add after `FLASHIda/FragmentAnalysis.cpp` (line 16):

```cmake
        FLASHIda/MS3FragmentMatcher.cpp
```

In `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/sources.cmake`, add after `FLASHIda/FragmentAnalysis.h` (line 16):

```cmake
        FLASHIda/MS3FragmentMatcher.h
```

In `OpenMS/src/tests/class_tests/openms/executables.cmake`, add after `FLASHIda_Logging_test` (line 458):

```cmake
  MS3FragmentMatcher_test
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp \
        src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp \
        src/openms/source/ANALYSIS/TOPDOWN/sources.cmake \
        src/openms/include/OpenMS/ANALYSIS/TOPDOWN/sources.cmake \
        src/tests/class_tests/openms/executables.cmake
git commit -m "feat: add MS3FragmentMatcher skeleton with ion type selection"
```

---

### Task 2: Theoretical mass calculation

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp`

- [ ] **Step 1: Implement computeTheoreticalMasses**

In `MS3FragmentMatcher.cpp`, replace the `computeTheoreticalMasses` stub with:

```cpp
  std::vector<MS3FragmentMatcher::TheoreticalMass> MS3FragmentMatcher::computeTheoreticalMasses(
    const std::string& subsequence,
    const std::vector<std::string>& ion_types,
    const std::vector<FragmentAnalysis::PTMSite>& ptm_sites)
  {
    int n = static_cast<int>(subsequence.size());
    if (n < 2) return {};

    // Get residue masses (0-based indexing)
    std::vector<double> res_mass(n, 0.0);
    for (int i = 0; i < n; ++i)
    {
      const Residue* res = ResidueDB::getInstance()->getResidue(subsequence[i]);
      if (res != nullptr)
        res_mass[i] = res->getMonoWeight(Residue::Internal);
    }

    // Separate fixed and ambiguous PTMs (convert 1-based PTMSite to 0-based)
    struct PTM0 { int start; int end; double mass; bool fixed; };
    std::vector<PTM0> ptms;
    for (const auto& p : ptm_sites)
    {
      PTM0 pm;
      pm.start = p.start_position - 1;
      pm.end = p.end_position - 1;
      pm.mass = p.mass_shift;
      pm.fixed = (p.start_position == p.end_position);
      ptms.push_back(pm);
    }

    // Pre-compute cumulative fixed PTM contributions
    // fixed_prefix[i] = total fixed PTM mass at positions <= i
    // fixed_suffix[i] = total fixed PTM mass at positions >= i
    std::vector<double> fixed_prefix(n, 0.0);
    std::vector<double> fixed_suffix(n, 0.0);
    for (const auto& pm : ptms)
    {
      if (! pm.fixed) continue;
      if (pm.start < 0 || pm.start >= n) continue;
      for (int i = pm.start; i < n; ++i)
        fixed_prefix[i] += pm.mass;
      for (int i = 0; i <= pm.start; ++i)
        fixed_suffix[i] += pm.mass;
    }

    std::vector<TheoreticalMass> result;

    for (const auto& ion_type : ion_types)
    {
      bool is_prefix = isPrefixIonType(ion_type);
      double shift = getIonShift(ion_type);

      double cumulative = 0.0;
      for (int i = 0; i < n - 1; ++i)
      {
        double base_mass;
        int frag_start_0, frag_end_0; // 0-based inclusive range covered by this ion

        if (is_prefix)
        {
          cumulative += res_mass[i];
          base_mass = cumulative + shift + fixed_prefix[i];
          frag_start_0 = 0;
          frag_end_0 = i;
        }
        else
        {
          int idx = n - 1 - i;
          cumulative += res_mass[idx];
          base_mass = cumulative + shift + fixed_suffix[idx];
          frag_start_0 = idx;
          frag_end_0 = n - 1;
        }

        // Check ambiguous PTMs for this position
        double ambiguous_delta = 0.0;
        bool has_ambiguous = false;
        for (const auto& pm : ptms)
        {
          if (pm.fixed) continue;
          // Is the ambiguous range fully covered by this ion?
          if (pm.start >= frag_start_0 && pm.end <= frag_end_0)
          {
            base_mass += pm.mass; // fully covered, always include
          }
          // Is it partially overlapping?
          else if (pm.end >= frag_start_0 && pm.start <= frag_end_0)
          {
            ambiguous_delta += pm.mass;
            has_ambiguous = true;
          }
          // else: no overlap, skip
        }

        int position = i + 1; // 1-based from the relevant terminus

        if (has_ambiguous)
        {
          TheoreticalMass tm_with;
          tm_with.mass = base_mass + ambiguous_delta;
          tm_with.position = position;
          tm_with.ion_type = ion_type;
          tm_with.includes_ptm = true;
          result.push_back(tm_with);

          TheoreticalMass tm_without;
          tm_without.mass = base_mass;
          tm_without.position = position;
          tm_without.ion_type = ion_type;
          tm_without.includes_ptm = false;
          result.push_back(tm_without);
        }
        else
        {
          TheoreticalMass tm;
          tm.mass = base_mass;
          tm.position = position;
          tm.ion_type = ion_type;
          tm.includes_ptm = false;
          result.push_back(tm);
        }
      }
    }

    return result;
  }
```

- [ ] **Step 2: Add theoretical mass tests**

In `MS3FragmentMatcher_test.cpp`, add before `END_TEST`:

```cpp
START_SECTION(computeTheoreticalMasses_no_ptm)
{
  // Use "ACDEF" — 5 residues, expect 4 positions per ion type
  std::string seq = "ACDEF";
  int n = 5;

  // Get residue masses from ResidueDB for verification
  std::vector<double> res(n);
  for (int i = 0; i < n; ++i)
    res[i] = ResidueDB::getInstance()->getResidue(seq[i])->getMonoWeight(Residue::Internal);

  double co = 27.994915;
  double water = 18.010565;

  // Test with just b-ions first
  auto masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"b"});
  TEST_EQUAL(masses.size(), 4) // n-1 = 4 positions

  // b-ions: cumulative prefix sums, shift = 0
  double cumul = 0.0;
  for (int i = 0; i < 4; ++i)
  {
    cumul += res[i];
    TEST_REAL_SIMILAR(masses[i].mass, cumul)
    TEST_EQUAL(masses[i].position, i + 1)
    TEST_EQUAL(masses[i].ion_type, "b")
    TEST_TRUE(! masses[i].includes_ptm)
  }

  // a-ions: b - CO
  auto a_masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"a"});
  TEST_EQUAL(a_masses.size(), 4)
  for (int i = 0; i < 4; ++i)
    TEST_REAL_SIMILAR(a_masses[i].mass, masses[i].mass - co)

  // y-ions: cumulative suffix sums + water
  auto y_masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"y"});
  TEST_EQUAL(y_masses.size(), 4)
  double cumul_suffix = 0.0;
  for (int i = 0; i < 4; ++i)
  {
    cumul_suffix += res[n - 1 - i];
    TEST_REAL_SIMILAR(y_masses[i].mass, cumul_suffix + water)
    TEST_EQUAL(y_masses[i].position, i + 1)
    TEST_EQUAL(y_masses[i].ion_type, "y")
  }

  // yb-ions: same cumulative suffix but no water (shift = 0)
  auto yb_masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"yb"});
  TEST_EQUAL(yb_masses.size(), 4)
  for (int i = 0; i < 4; ++i)
    TEST_REAL_SIMILAR(yb_masses[i].mass, y_masses[i].mass - water)

  // ya-ions: cumulative suffix - CO (shift = -CO)
  auto ya_masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"ya"});
  TEST_EQUAL(ya_masses.size(), 4)
  for (int i = 0; i < 4; ++i)
    TEST_REAL_SIMILAR(ya_masses[i].mass, y_masses[i].mass - water - co)

  // Multiple ion types: should get 4 * num_types entries
  auto all_masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"a", "b", "y"});
  TEST_EQUAL(all_masses.size(), 12)

  // Verify monotonically increasing within each type
  for (int i = 1; i < 4; ++i)
    TEST_TRUE(masses[i].mass > masses[i - 1].mass)
  for (int i = 1; i < 4; ++i)
    TEST_TRUE(y_masses[i].mass > y_masses[i - 1].mass)
}
END_SECTION

START_SECTION(computeTheoreticalMasses_fixed_ptm)
{
  std::string seq = "ACDEF";
  double ptm_shift = 42.0106; // acetylation

  // Fixed PTM at position 3 (1-based) = residue D
  FragmentAnalysis::PTMSite fixed_ptm;
  fixed_ptm.start_position = 3;
  fixed_ptm.end_position = 3;
  fixed_ptm.position = 3;
  fixed_ptm.mass_shift = ptm_shift;

  auto masses_no_ptm = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"b"});
  auto masses_ptm = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"b"}, {fixed_ptm});

  // b1, b2: before PTM position 3 — should be identical
  TEST_REAL_SIMILAR(masses_ptm[0].mass, masses_no_ptm[0].mass)
  TEST_REAL_SIMILAR(masses_ptm[1].mass, masses_no_ptm[1].mass)

  // b3, b4: at or past PTM position — should include PTM mass
  TEST_REAL_SIMILAR(masses_ptm[2].mass, masses_no_ptm[2].mass + ptm_shift)
  TEST_REAL_SIMILAR(masses_ptm[3].mass, masses_no_ptm[3].mass + ptm_shift)

  // Test suffix ions: y-ions
  auto y_no_ptm = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"y"});
  auto y_ptm = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"y"}, {fixed_ptm});

  // y1 (covers pos 5), y2 (covers 4-5): PTM at pos 3 is outside — identical
  TEST_REAL_SIMILAR(y_ptm[0].mass, y_no_ptm[0].mass)
  TEST_REAL_SIMILAR(y_ptm[1].mass, y_no_ptm[1].mass)

  // y3 (covers 3-5), y4 (covers 2-5): PTM at pos 3 is inside — includes shift
  TEST_REAL_SIMILAR(y_ptm[2].mass, y_no_ptm[2].mass + ptm_shift)
  TEST_REAL_SIMILAR(y_ptm[3].mass, y_no_ptm[3].mass + ptm_shift)
}
END_SECTION

START_SECTION(computeTheoreticalMasses_ambiguous_ptm)
{
  std::string seq = "ACDEF";
  double ptm_shift = 79.966; // phosphorylation

  // Ambiguous PTM spanning positions 2-4 (1-based) = residues C, D, E
  FragmentAnalysis::PTMSite amb_ptm;
  amb_ptm.start_position = 2;
  amb_ptm.end_position = 4;
  amb_ptm.position = 3;
  amb_ptm.mass_shift = ptm_shift;

  auto masses = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"b"}, {amb_ptm});

  // b1 (covers pos 1): PTM range [2,4] outside — single entry, no PTM
  TEST_EQUAL(masses[0].ion_type, "b")
  TEST_TRUE(! masses[0].includes_ptm)

  // b2 (covers pos 1-2): PTM range [2,4] partially overlaps — dual entries
  // Find the two b2 entries
  std::vector<MS3FragmentMatcher::TheoreticalMass> b2_entries;
  for (const auto& m : masses)
    if (m.position == 2) b2_entries.push_back(m);
  TEST_EQUAL(b2_entries.size(), 2)
  // One with PTM, one without
  bool found_with = false, found_without = false;
  for (const auto& e : b2_entries)
  {
    if (e.includes_ptm) found_with = true;
    else found_without = true;
  }
  TEST_TRUE(found_with)
  TEST_TRUE(found_without)
  // Mass difference should be ptm_shift
  double diff = std::abs(b2_entries[0].mass - b2_entries[1].mass);
  TEST_REAL_SIMILAR(diff, ptm_shift)

  // b4 (covers pos 1-4): PTM range [2,4] fully covered — single entry with PTM included
  std::vector<MS3FragmentMatcher::TheoreticalMass> b4_entries;
  for (const auto& m : masses)
    if (m.position == 4) b4_entries.push_back(m);
  TEST_EQUAL(b4_entries.size(), 1)
}
END_SECTION
```

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp \
        src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp
git commit -m "feat: implement theoretical mass calculation with PTM support"
```

---

### Task 3: Spectrum matching

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp`

- [ ] **Step 1: Implement matchSpectrum**

In `MS3FragmentMatcher.cpp`, replace the `matchSpectrum` stub with:

```cpp
  int MS3FragmentMatcher::matchSpectrum(
    const DeconvolvedSpectrum& spectrum,
    const std::vector<TheoreticalMass>& theoretical,
    double tolerance_ppm,
    std::vector<double>* ppm_errors)
  {
    if (spectrum.empty() || theoretical.empty()) return 0;

    // Sort theoretical masses for binary search
    std::vector<size_t> sorted_idx(theoretical.size());
    std::iota(sorted_idx.begin(), sorted_idx.end(), 0);
    std::sort(sorted_idx.begin(), sorted_idx.end(),
      [&theoretical](size_t a, size_t b) { return theoretical[a].mass < theoretical[b].mass; });

    std::vector<bool> theo_used(theoretical.size(), false);
    int match_count = 0;

    // For each deconvolved mass, find closest unused theoretical mass within tolerance
    for (Size si = 0; si < spectrum.size(); ++si)
    {
      double obs_mass = spectrum[si].getMonoMass();
      double tol_da = obs_mass * tolerance_ppm * 1e-6;

      int best_theo_idx = -1;
      double best_ppm = tolerance_ppm + 1.0;

      // Binary search for candidates
      for (size_t k = 0; k < sorted_idx.size(); ++k)
      {
        size_t ti = sorted_idx[k];
        if (theo_used[ti]) continue;
        double theo_mass = theoretical[ti].mass;
        if (theo_mass < obs_mass - tol_da) continue;
        if (theo_mass > obs_mass + tol_da) break;

        double ppm_err = std::abs((obs_mass - theo_mass) / theo_mass) * 1e6;
        if (ppm_err < best_ppm)
        {
          best_ppm = ppm_err;
          best_theo_idx = static_cast<int>(ti);
        }
      }

      if (best_theo_idx >= 0)
      {
        theo_used[best_theo_idx] = true;
        ++match_count;
        if (ppm_errors)
        {
          double signed_ppm = (obs_mass - theoretical[best_theo_idx].mass)
                              / theoretical[best_theo_idx].mass * 1e6;
          ppm_errors->push_back(signed_ppm);
        }
      }
    }

    return match_count;
  }
```

- [ ] **Step 2: Add matching tests**

In `MS3FragmentMatcher_test.cpp`, add before `END_TEST`:

```cpp
START_SECTION(matchSpectrum)
{
  // Build theoretical masses from a known sequence
  std::string seq = "ACDEF";
  auto theoretical = MS3FragmentMatcher::computeTheoreticalMasses(seq, {"b", "y"});
  // 4 b-ions + 4 y-ions = 8 theoretical masses

  // Create a synthetic spectrum with 3 exact matches (b1, b2, y1) + 1 non-match
  std::vector<double> obs_masses;
  obs_masses.push_back(theoretical[0].mass);  // b1 — exact match
  obs_masses.push_back(theoretical[1].mass);  // b2 — exact match
  obs_masses.push_back(theoretical[4].mass);  // y1 — exact match
  obs_masses.push_back(99999.0);              // garbage — no match

  DeconvolvedSpectrum spec(0);
  for (double m : obs_masses)
  {
    PeakGroup pg(1, 1, true);
    pg.setMonoisotopicMass(m);
    spec.push_back(pg);
  }

  int count = MS3FragmentMatcher::matchSpectrum(spec, theoretical, 10.0);
  TEST_EQUAL(count, 3)

  // Test with ppm errors
  std::vector<double> ppm_errors;
  int count2 = MS3FragmentMatcher::matchSpectrum(spec, theoretical, 10.0, &ppm_errors);
  TEST_EQUAL(count2, 3)
  TEST_EQUAL(ppm_errors.size(), 3)
  // Exact matches should have ~0 ppm error
  for (double e : ppm_errors)
    TEST_TRUE(std::abs(e) < 0.01)

  // Test with a systematic shift (50 ppm)
  double shift_factor = 1.0 + 50.0e-6;
  DeconvolvedSpectrum shifted_spec(0);
  for (double m : obs_masses)
  {
    PeakGroup pg(1, 1, true);
    pg.setMonoisotopicMass(m * shift_factor);
    shifted_spec.push_back(pg);
  }

  // At 10 ppm tolerance, shifted masses should NOT match
  int count_tight = MS3FragmentMatcher::matchSpectrum(shifted_spec, theoretical, 10.0);
  TEST_EQUAL(count_tight, 0)

  // At 100 ppm tolerance, shifted masses should match
  std::vector<double> shift_errors;
  int count_loose = MS3FragmentMatcher::matchSpectrum(shifted_spec, theoretical, 100.0, &shift_errors);
  TEST_EQUAL(count_loose, 3)
  // ppm errors should be ~50
  for (double e : shift_errors)
    TEST_REAL_SIMILAR(e, 50.0)

  // Empty inputs
  DeconvolvedSpectrum empty_spec(0);
  TEST_EQUAL(MS3FragmentMatcher::matchSpectrum(empty_spec, theoretical, 10.0), 0)
  TEST_EQUAL(MS3FragmentMatcher::matchSpectrum(spec, {}, 10.0), 0)
}
END_SECTION
```

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp \
        src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp
git commit -m "feat: implement matchSpectrum with greedy matching"
```

---

### Task 4: Subsequence extraction, PTM rebasing, and calibrateAndScore

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp`
- Modify: `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp`

- [ ] **Step 1: Implement extractSubsequence and rebasePTMSites**

In `MS3FragmentMatcher.cpp`, replace the `extractSubsequence` stub with:

```cpp
  std::string MS3FragmentMatcher::extractSubsequence(
    const std::string& protein_sequence,
    const ProteoformContext& ctx,
    char fragment_ion_type,
    int fragment_ion_index)
  {
    if (ctx.region_start < 0 || ctx.region_end < 0) return "";
    int proteoform_length = ctx.region_end - ctx.region_start;
    if (fragment_ion_index <= 0 || fragment_ion_index > proteoform_length) return "";

    int subseq_start_0based; // absolute position in protein_sequence
    if (fragment_ion_type == 'b' || fragment_ion_type == 'a' || fragment_ion_type == 'c')
    {
      subseq_start_0based = ctx.region_start;
    }
    else // y, x, z
    {
      subseq_start_0based = ctx.region_end - fragment_ion_index;
    }

    if (subseq_start_0based < 0 ||
        subseq_start_0based + fragment_ion_index > static_cast<int>(protein_sequence.size()))
      return "";

    return protein_sequence.substr(subseq_start_0based, fragment_ion_index);
  }
```

Replace the `rebasePTMSites` stub with:

```cpp
  std::vector<FragmentAnalysis::PTMSite> MS3FragmentMatcher::rebasePTMSites(
    const std::vector<FragmentAnalysis::PTMSite>& ptm_sites,
    int subseq_start_in_proteoform,
    int subseq_length)
  {
    int subseq_end = subseq_start_in_proteoform + subseq_length - 1; // 1-based inclusive end

    std::vector<FragmentAnalysis::PTMSite> result;
    for (const auto& ptm : ptm_sites)
    {
      // No overlap — skip
      if (ptm.end_position < subseq_start_in_proteoform || ptm.start_position > subseq_end)
        continue;

      FragmentAnalysis::PTMSite rebased;
      rebased.start_position = std::max(ptm.start_position, subseq_start_in_proteoform)
                               - subseq_start_in_proteoform + 1;
      rebased.end_position = std::min(ptm.end_position, subseq_end)
                             - subseq_start_in_proteoform + 1;
      rebased.position = (rebased.start_position + rebased.end_position) / 2;
      rebased.mass_shift = ptm.mass_shift;
      result.push_back(rebased);
    }
    return result;
  }
```

- [ ] **Step 2: Implement calibrateAndScore**

Replace the `calibrateAndScore` stub with:

```cpp
  std::vector<double> MS3FragmentMatcher::calibrateAndScore(
    const std::vector<const DeconvolvedSpectrum*>& variant_spectra,
    const std::string& protein_sequence,
    const ProteoformContext& ctx,
    char fragment_ion_type,
    int fragment_ion_index,
    double loose_tolerance_ppm,
    double tight_tolerance_ppm)
  {
    std::vector<double> scores(variant_spectra.size(), 0.0);

    // Extract subsequence
    std::string subseq = extractSubsequence(protein_sequence, ctx, fragment_ion_type, fragment_ion_index);
    if (subseq.empty()) return scores;

    // Determine subsequence start in proteoform (1-based)
    int proteoform_length = ctx.region_end - ctx.region_start;
    int subseq_start_1based;
    if (fragment_ion_type == 'b' || fragment_ion_type == 'a' || fragment_ion_type == 'c')
      subseq_start_1based = 1;
    else
      subseq_start_1based = proteoform_length - fragment_ion_index + 1;

    // Rebase PTMs
    auto rebased_ptms = rebasePTMSites(ctx.ptm_sites, subseq_start_1based, fragment_ion_index);

    // Ion types
    auto ion_types = getMS3IonTypes(fragment_ion_type);

    // Compute theoretical masses once
    auto theoretical = computeTheoreticalMasses(subseq, ion_types, rebased_ptms);
    if (theoretical.empty()) return scores;

    // Pass 1: loose matching for calibration
    std::vector<double> all_ppm_errors;
    for (size_t vi = 0; vi < variant_spectra.size(); ++vi)
    {
      if (variant_spectra[vi] == nullptr || variant_spectra[vi]->empty()) continue;
      matchSpectrum(*variant_spectra[vi], theoretical, loose_tolerance_ppm, &all_ppm_errors);
    }

    // Compute median ppm error
    double correction_factor = 1.0;
    if (! all_ppm_errors.empty())
    {
      std::sort(all_ppm_errors.begin(), all_ppm_errors.end());
      double median_ppm;
      size_t mid = all_ppm_errors.size() / 2;
      if (all_ppm_errors.size() % 2 == 0)
        median_ppm = (all_ppm_errors[mid - 1] + all_ppm_errors[mid]) / 2.0;
      else
        median_ppm = all_ppm_errors[mid];

      correction_factor = 1.0 / (1.0 + median_ppm * 1e-6);
    }

    // Pass 2: apply correction, match at tight tolerance
    for (size_t vi = 0; vi < variant_spectra.size(); ++vi)
    {
      if (variant_spectra[vi] == nullptr || variant_spectra[vi]->empty()) continue;

      // Create corrected copy
      DeconvolvedSpectrum corrected(0);
      for (Size pi = 0; pi < variant_spectra[vi]->size(); ++pi)
      {
        PeakGroup pg = (*variant_spectra[vi])[pi];
        pg.setMonoisotopicMass(pg.getMonoMass() * correction_factor);
        corrected.push_back(pg);
      }

      scores[vi] = static_cast<double>(matchSpectrum(corrected, theoretical, tight_tolerance_ppm));
    }

    return scores;
  }
```

- [ ] **Step 3: Add tests for extraction, rebasing, and calibration**

In `MS3FragmentMatcher_test.cpp`, add before `END_TEST`:

```cpp
START_SECTION(extractSubsequence)
{
  std::string protein = "ABCDEFGHIJ"; // 10 residues

  MS3FragmentMatcher::ProteoformContext ctx;
  ctx.region_start = 2;  // 0-based: proteoform is residues 2-7 = "CDEFGH"
  ctx.region_end = 8;

  // b3: first 3 residues of proteoform = "CDE"
  std::string b3 = MS3FragmentMatcher::extractSubsequence(protein, ctx, 'b', 3);
  TEST_EQUAL(b3, "CDE")

  // y3: last 3 residues of proteoform = "FGH"
  std::string y3 = MS3FragmentMatcher::extractSubsequence(protein, ctx, 'y', 3);
  TEST_EQUAL(y3, "FGH")

  // Full proteoform as b6
  std::string b6 = MS3FragmentMatcher::extractSubsequence(protein, ctx, 'b', 6);
  TEST_EQUAL(b6, "CDEFGH")

  // Invalid: index too large
  std::string bad = MS3FragmentMatcher::extractSubsequence(protein, ctx, 'b', 7);
  TEST_EQUAL(bad, "")

  // a-precursor treated same as b-precursor
  std::string a3 = MS3FragmentMatcher::extractSubsequence(protein, ctx, 'a', 3);
  TEST_EQUAL(a3, "CDE")
}
END_SECTION

START_SECTION(rebasePTMSites)
{
  // Proteoform has 10 residues, PTM at positions 3-5 (1-based, ambiguous)
  FragmentAnalysis::PTMSite ptm;
  ptm.start_position = 3;
  ptm.end_position = 5;
  ptm.position = 4;
  ptm.mass_shift = 80.0;

  // Fixed PTM at position 7
  FragmentAnalysis::PTMSite fixed;
  fixed.start_position = 7;
  fixed.end_position = 7;
  fixed.position = 7;
  fixed.mass_shift = 42.0;

  std::vector<FragmentAnalysis::PTMSite> ptms = {ptm, fixed};

  // b5 subsequence: positions 1-5 in proteoform
  auto rebased = MS3FragmentMatcher::rebasePTMSites(ptms, 1, 5);
  TEST_EQUAL(rebased.size(), 1) // only the ambiguous PTM overlaps; fixed at 7 is outside
  TEST_EQUAL(rebased[0].start_position, 3) // 3 - 1 + 1 = 3
  TEST_EQUAL(rebased[0].end_position, 5)   // 5 - 1 + 1 = 5
  TEST_REAL_SIMILAR(rebased[0].mass_shift, 80.0)

  // y5 subsequence: positions 6-10 in proteoform
  auto rebased_y = MS3FragmentMatcher::rebasePTMSites(ptms, 6, 5);
  TEST_EQUAL(rebased_y.size(), 1) // only fixed PTM at 7 overlaps
  TEST_EQUAL(rebased_y[0].start_position, 2) // 7 - 6 + 1 = 2
  TEST_EQUAL(rebased_y[0].end_position, 2)
  TEST_REAL_SIMILAR(rebased_y[0].mass_shift, 42.0)

  // Partial overlap: subsequence positions 4-8
  auto rebased_mid = MS3FragmentMatcher::rebasePTMSites(ptms, 4, 5);
  TEST_EQUAL(rebased_mid.size(), 2) // both PTMs overlap
  // Ambiguous PTM [3,5] clipped to [4,5], rebased to [1,2]
  TEST_EQUAL(rebased_mid[0].start_position, 1)
  TEST_EQUAL(rebased_mid[0].end_position, 2)
  // Fixed PTM [7,7] rebased to [4,4]
  TEST_EQUAL(rebased_mid[1].start_position, 4)
  TEST_EQUAL(rebased_mid[1].end_position, 4)
}
END_SECTION

START_SECTION(calibrateAndScore)
{
  // Build a known sequence and theoretical masses
  std::string protein = "ACDEFGHIKLMNPQRSTVWY"; // 20 residues
  MS3FragmentMatcher::ProteoformContext ctx;
  ctx.region_start = 0;
  ctx.region_end = 20;

  // Pretend we're fragmenting b10: first 10 residues
  char frag_type = 'b';
  int frag_index = 10;

  std::string subseq = MS3FragmentMatcher::extractSubsequence(protein, ctx, frag_type, frag_index);
  TEST_EQUAL(subseq, "ACDEFGHIKL")

  auto ion_types = MS3FragmentMatcher::getMS3IonTypes(frag_type);
  auto theoretical = MS3FragmentMatcher::computeTheoreticalMasses(subseq, ion_types);

  // Create two variant spectra:
  // Variant 0: 5 matching masses with +50 ppm shift (simulating systematic instrument drift)
  // Variant 1: 3 matching masses with the same shift
  double shift_factor = 1.0 + 50.0e-6;

  DeconvolvedSpectrum var0(0);
  for (int i = 0; i < 5 && i < static_cast<int>(theoretical.size()); ++i)
  {
    PeakGroup pg(1, 1, true);
    pg.setMonoisotopicMass(theoretical[i].mass * shift_factor);
    var0.push_back(pg);
  }

  DeconvolvedSpectrum var1(0);
  for (int i = 0; i < 3 && i < static_cast<int>(theoretical.size()); ++i)
  {
    PeakGroup pg(1, 1, true);
    pg.setMonoisotopicMass(theoretical[i].mass * shift_factor);
    var1.push_back(pg);
  }

  std::vector<const DeconvolvedSpectrum*> variants = {&var0, &var1};

  auto scores = MS3FragmentMatcher::calibrateAndScore(
    variants, protein, ctx, frag_type, frag_index,
    MS3FragmentMatcher::LOOSE_TOLERANCE_PPM, 10.0);

  TEST_EQUAL(scores.size(), 2)
  // After calibration (corrects the 50 ppm shift), matching at 10 ppm should succeed
  TEST_TRUE(scores[0] >= 4.0)  // variant 0 had 5 masses, should match most
  TEST_TRUE(scores[1] >= 2.0)  // variant 1 had 3 masses
  TEST_TRUE(scores[0] > scores[1]) // variant 0 should score higher

  // Without calibration (tight tolerance only), same masses would NOT match
  // Verify by testing matchSpectrum directly at 10 ppm with unshifted theoretical
  int direct_count = MS3FragmentMatcher::matchSpectrum(var0, theoretical, 10.0);
  TEST_EQUAL(direct_count, 0) // 50 ppm shift exceeds 10 ppm tolerance
}
END_SECTION
```

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp \
        src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp
git commit -m "feat: implement calibrateAndScore with subsequence extraction and PTM rebasing"
```

---

### Task 5: FragmentAnalysis proteoform info caching

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h:56-66`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp:569-637`

- [ ] **Step 1: Add caching fields and getter to FragmentAnalysis.h**

In `FragmentAnalysis.h`, after the `PTMSite` struct definition (after line 66), add:

```cpp
    /// Cached result from the last runTagBasedFragmentMatching_ call
    struct ProteoformInfo
    {
      int region_start = -1;  ///< 0-based start position in protein sequence (-1 = full sequence)
      int region_end = -1;    ///< 0-based exclusive end position (-1 = full sequence)
      std::vector<PTMSite> ptm_sites; ///< 1-based positions relative to proteoform
    };

    /// Get the proteoform region and PTM sites from the last tag-based matching call
    const ProteoformInfo& getLastProteoformInfo() const { return last_proteoform_info_; }
```

At the bottom of the class (before the closing `};`), after line 279, add the member variable in a private section. If there is already a private section with member variables, add there. Otherwise add:

```cpp
  private:
    ProteoformInfo last_proteoform_info_;
```

Note: If `last_proteoform_info_` conflicts with an existing private section, place it alongside other member variables. The `Config& config_` reference is likely already in a private section.

- [ ] **Step 2: Cache proteoform info in runTagBasedFragmentMatching_()**

In `FragmentAnalysis.cpp`, after the region extraction at line 574 (`end_pos = ...`), and before the `if (start_pos >= 0 ...)` display block at line 576, add:

```cpp
    // Cache proteoform region
    last_proteoform_info_.region_start = start_pos;  // 0-based, or -1 if not found
    last_proteoform_info_.region_end = end_pos;       // 0-based exclusive, or -1
    last_proteoform_info_.ptm_sites.clear();
```

After the PTM extraction loop at line 638 (after the `if (ptm_sites != nullptr)` block closing brace), add:

```cpp
    // Always cache PTM sites (regardless of whether ptm_sites output was requested)
    last_proteoform_info_.ptm_sites.clear();
    for (Size i = 0; i < mod_masses.size(); ++i)
    {
      PTMSite site;
      site.start_position = mod_starts[i];
      site.end_position = mod_ends[i];
      site.position = (site.start_position + site.end_position) / 2;
      site.mass_shift = mod_masses[i];
      last_proteoform_info_.ptm_sites.push_back(site);
    }
```

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
git commit -m "feat: cache proteoform region and PTM sites in FragmentAnalysis"
```

---

### Task 6: Exploration integration

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:78-99`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:229,295-312,387-454`

- [ ] **Step 1: Add ProteoformContext to ExplorationGroup**

In `Exploration.h`, add `#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h>` to the includes at the top of the file.

In the `ExplorationGroup` struct (line 78-99), add after `int fragment_ion_index = 0;` (line 98):

```cpp
      MS3FragmentMatcher::ProteoformContext proteoform_ctx; ///< Cached MS2 proteoform for MS3 scoring
```

- [ ] **Step 2: Cache proteoform context in initiateNextLevel()**

In `Exploration.cpp`, add `#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h>` to the includes.

**2a. Add proto_ctx parameter to `initiate()` signature.**

In `Exploration.h` (line 141-144), change the declaration:

```cpp
    std::vector<ScanCommand> initiate(int msn_level, const PeakGroup& pg, int charge,
                                      double faims_cv, ScanCommandQueue& queue,
                                      const ScanCommand* ms_ctx = nullptr,
                                      char ion_type = '\0', int frag_index = 0,
                                      const MS3FragmentMatcher::ProteoformContext& proto_ctx = {});
```

In `Exploration.cpp` (line 66-68), update the definition signature to match:

```cpp
  std::vector<ScanCommand> Exploration::initiate(int msn_level, const PeakGroup& pg, int charge,
      double faims_cv, ScanCommandQueue& queue, const ScanCommand* ms_ctx,
      char ion_type, int frag_index,
      const MS3FragmentMatcher::ProteoformContext& proto_ctx)
  {
```

In `initiate()` body, after line 106 (`group.fragment_ion_index = frag_index;`), add:

```cpp
    group.proteoform_ctx = proto_ctx;
```

**2b. Build ProteoformContext in `initiateNextLevel()` and pass it through.**

In `initiateNextLevel()`, after the fragment matching switch block (after line 410), and before the `nlr.fragment_count = found;` line (before line 413), add:

```cpp
    // Cache proteoform context for MS3 subsequence scoring
    MS3FragmentMatcher::ProteoformContext proto_ctx;
    if (next_level >= 3)
    {
      const auto& pinfo = fragments_.getLastProteoformInfo();
      proto_ctx.region_start = pinfo.region_start;
      proto_ctx.region_end = pinfo.region_end;
      proto_ctx.ptm_sites = pinfo.ptm_sites;
      // If no truncation detected, use full protein sequence bounds
      if (proto_ctx.region_start < 0)
        proto_ctx.region_start = 0;
      if (proto_ctx.region_end < 0)
        proto_ctx.region_end = static_cast<int>(seq.size());
    }
```

Update the `initiate()` call at line 451 to pass `proto_ctx`:

```cpp
        auto sub_cmds = initiate(next_level, frag_pg, std::abs(charges[ti]), faims_cv, queue, ms_ctx,
                                 ion_types[ti], frag_indices[ti], proto_ctx);
```

- [ ] **Step 3: Add batch scoring in feedResultImpl_()**

In `feedResultImpl_()`, after the `all_received` check passes (line 297) and before the winner selection loop (line 299), add:

```cpp
    // MS3 FragmentCount: batch re-score with calibrated subsequence matching
    if (group.exploration_metric == ExplorationMetric::FragmentCount && group.msn_level >= 3)
    {
      std::vector<const DeconvolvedSpectrum*> variant_spectra;
      for (auto& var : group.variants)
        variant_spectra.push_back(var.received ? &var.result : nullptr);

      auto calibrated_scores = MS3FragmentMatcher::calibrateAndScore(
        variant_spectra,
        config_.targeting().protein_sequence,
        group.proteoform_ctx,
        group.fragment_ion_type,
        group.fragment_ion_index,
        MS3FragmentMatcher::LOOSE_TOLERANCE_PPM,
        config_.level(group.msn_level).tolerance_ppm);

      for (size_t vi = 0; vi < calibrated_scores.size(); ++vi)
      {
        group.variants[vi].score = calibrated_scores[vi];
        group.variants[vi].fragment_count = static_cast<int>(calibrated_scores[vi]);
      }
    }
```

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "feat: integrate MS3 subsequence scoring into exploration pipeline"
```

---

### Task 7: Push and verify CI

**Files:** None (CI verification only)

- [ ] **Step 1: Push to flashida-v9-bridge**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

This triggers the `build-dlls` workflow. Wait for CI to complete (~40 min). All tests must pass, including the new `MS3FragmentMatcher_test` and the existing `FLASHIda_exploration_test`.

- [ ] **Step 2: Verify CI result**

```bash
gh run list -R t0mdavid-m/OpenMS -b flashida-v9-bridge -L 1
```

Check that the run succeeded. If any test fails, diagnose from the CI log and fix.

- [ ] **Step 3: Update parent submodule pointer**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add OpenMS
git commit -m "Update OpenMS submodule: MS3 subsequence scoring"
git push
```

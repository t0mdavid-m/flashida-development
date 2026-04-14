# Add `remaining_ratio` Column to results.tsv — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the raw remaining precursor ratio as column 21 (`remaining_ratio`, after `exploration_score`) in results.tsv for downstream analysis consumption. Default -1.0 for non-applicable rows.

**Architecture:** Thread the ratio out of `computeRemainingPrecursorScore_()` via an output parameter, carry it through `FeedResultInfo`, write as final TSV column. No C# changes.

**Tech Stack:** C++20, OpenMS ClassTest framework, nlohmann::json

**Spec:** `docs/superpowers/specs/2026-04-14-remaining-ratio-column-design.md`

---

### Task 1: Add `remaining_ratio` to FeedResultInfo and scoring output parameters

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:118-131` (FeedResultInfo struct)
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h:192-201` (private method declarations)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:483-499` (computeExplorationScore_)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:506-542` (computeRemainingPrecursorScore_)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:211` (feedResultImpl_ score call)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:242-252` (feedResultImpl_ info population)

- [ ] **Step 1: Add `remaining_ratio` field to FeedResultInfo**

In `Exploration.h`, add after line 130 (`std::string proteoform_sequence;`):

```cpp
      double remaining_ratio = -1.0;  ///< Raw remaining_intensity / baseline_intensity (-1.0 = N/A)
```

- [ ] **Step 2: Add output parameter to `computeRemainingPrecursorScore_()` declaration**

In `Exploration.h`, change lines 200-201 from:

```cpp
    double computeRemainingPrecursorScore_(const ExplorationGroup& group,
                                           const double* mzs, const double* ints, int length) const;
```

to:

```cpp
    double computeRemainingPrecursorScore_(const ExplorationGroup& group,
                                           const double* mzs, const double* ints, int length,
                                           double* out_ratio = nullptr) const;
```

- [ ] **Step 3: Add output parameter to `computeExplorationScore_()` declaration**

In `Exploration.h`, change lines 192-194 from:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length) const;
```

to:

```cpp
    double computeExplorationScore_(ExplorationMetric metric, const DeconvolvedSpectrum& spec,
                                    const ExplorationGroup& group,
                                    const double* mzs, const double* ints, int length,
                                    double* out_remaining_ratio = nullptr) const;
```

- [ ] **Step 4: Implement output parameter in `computeRemainingPrecursorScore_()`**

In `Exploration.cpp`, change the signature at line 506-507 from:

```cpp
  double Exploration::computeRemainingPrecursorScore_(const ExplorationGroup& group,
      const double* mzs, const double* ints, int length) const
```

to:

```cpp
  double Exploration::computeRemainingPrecursorScore_(const ExplorationGroup& group,
      const double* mzs, const double* ints, int length, double* out_ratio) const
```

Then after line 536 (`double ratio = remaining_intensity / reference;`), add:

```cpp
    if (out_ratio) *out_ratio = ratio;
```

- [ ] **Step 5: Thread output parameter through `computeExplorationScore_()`**

In `Exploration.cpp`, change the signature at line 483-486 from:

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length) const
```

to:

```cpp
  double Exploration::computeExplorationScore_(ExplorationMetric metric,
      const DeconvolvedSpectrum& spec,
      const ExplorationGroup& group,
      const double* mzs, const double* ints, int length,
      double* out_remaining_ratio) const
```

Then change line 493 from:

```cpp
        return computeRemainingPrecursorScore_(group, mzs, ints, length);
```

to:

```cpp
        return computeRemainingPrecursorScore_(group, mzs, ints, length, out_remaining_ratio);
```

- [ ] **Step 6: Capture ratio in `feedResultImpl_()` and populate info**

In `Exploration.cpp`, change line 211 from:

```cpp
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length);
```

to:

```cpp
    double remaining_ratio = -1.0;
    v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv, group, mzs, ints, length, &remaining_ratio);
```

Then in the info population block (after line 252, `info.proteoform_sequence = frag.proteoform_sequence;`), add:

```cpp
    info.remaining_ratio = remaining_ratio;
```

- [ ] **Step 7: Commit**

```bash
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Add remaining_ratio output to Exploration scoring pipeline"
```

---

### Task 2: Add `remaining_ratio` column to results.tsv output

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:259-269` (writeScanResultRow_ declaration)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:96-102` (TSV header)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:309-356` (writeScanResultRow_ definition)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:641-646` (MS2 exploration call site)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:742-748` (MS3 exploration call site)

- [ ] **Step 1: Add parameter to `writeScanResultRow_()` declaration**

In `FLASHIda.h`, change line 269 from:

```cpp
                             double collision_energy = 0.0, double exploration_score = -1.0);
```

to:

```cpp
                             double collision_energy = 0.0, double exploration_score = -1.0,
                             double remaining_ratio = -1.0);
```

- [ ] **Step 2: Add `remaining_ratio` to TSV header**

In `FLASHIda.cpp`, change line 102 from:

```cpp
                            << "collision_energy\texploration_score\n";
```

to:

```cpp
                            << "collision_energy\texploration_score\tremaining_ratio\n";
```

- [ ] **Step 3: Add parameter to `writeScanResultRow_()` definition and write it**

In `FLASHIda.cpp`, change line 318 from:

```cpp
                                      double collision_energy, double exploration_score)
```

to:

```cpp
                                      double collision_energy, double exploration_score,
                                      double remaining_ratio)
```

Then change line 354 from:

```cpp
                        << exploration_score << "\n";
```

to:

```cpp
                        << exploration_score << "\t"
                        << remaining_ratio << "\n";
```

- [ ] **Step 4: Pass `info.remaining_ratio` at MS2 exploration call site**

In `FLASHIda.cpp`, change lines 641-646 from:

```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score);
```

to:

```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score, info.remaining_ratio);
```

- [ ] **Step 5: Pass `info.remaining_ratio` at MS3 exploration call site**

In `FLASHIda.cpp`, change lines 742-748 from:

```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count,
                            static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score);
```

to:

```cpp
        writeScanResultRow_(id_str, rt_min, expl_mass_count,
                            static_cast<int>(info.commands.size()),
                            {}, 0, info.matched_protein, info.proteoform_sequence, enqueue_ts, received_ts,
                            info.tic_coverage, info.fragment_count,
                            info.group_id, info.exploration_metric,
                            info.variant_index, info.total_variants,
                            info.collision_energy, info.score, info.remaining_ratio);
```

Note: The three non-exploration call sites (MS1 at line 602, MS2-normal at line 718, MS3-normal at line 774) use default parameters and will automatically get `remaining_ratio = -1.0`.

- [ ] **Step 6: Commit**

```bash
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Add remaining_ratio column to results.tsv output"
```

---

### Task 3: Add and extend C++ tests for `remaining_ratio`

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

All test changes extend existing sections. No new test sections needed.

- [ ] **Step 1: Extend `remaining_precursor_target_aware_scoring` (line 1362)**

This test has known input: baseline=1000.0 at mz_center, perfect=100.0 (ratio=0.1), over=500.0 (ratio=0.5).

After line 1388 (`double score_perfect = info_perfect.score;`), add:

```cpp
  double ratio_perfect = info_perfect.remaining_ratio;
```

After line 1394 (`double score_over = info_over.score;`), add:

```cpp
  double ratio_over = info_over.remaining_ratio;
```

After line 1398 (`TEST_REAL_SIMILAR(score_over, 0.6)`), add:

```cpp
  TEST_REAL_SIMILAR(ratio_perfect, 0.1)
  TEST_REAL_SIMILAR(ratio_over, 0.5)
```

- [ ] **Step 2: Extend `remaining_precursor_score_with_raw_data` (line 1154)**

After line 1196 (`TEST_EQUAL(group_mid.variants[1].score <= 1.0, true)`), add:

```cpp
  // remaining_ratio should be valid (>= 0.0) for RemainingPrecursor with raw data
  TEST_EQUAL(ce20_info.remaining_ratio >= 0.0, true)
  TEST_EQUAL(ce20_info.remaining_ratio <= 1.0, true)
```

Note: `ce20_info` is already captured at line 1189 but was unused (`(void)ce20_info` at line 1198). Remove the `(void)ce20_info;` line.

- [ ] **Step 3: Extend `remaining_precursor_score_no_raw_data` (line 1108)**

This test uses `feedResultForTest()` which bypasses raw data — ratio stays -1.0. After line 1146 (`TEST_EQUAL(info.total_variants, 5)`), add:

```cpp
    // No raw data path -> remaining_ratio should be -1.0 (N/A)
    TEST_REAL_SIMILAR(info.remaining_ratio, -1.0)
```

- [ ] **Step 4: Extend `remaining_precursor_score_no_signal_in_window` (line 1202)**

Baseline has zero in-window signal, so baseline_intensity=0 -> ratio not computed -> stays -1.0. After the CE=20 feedResult call (line 1234), capture the return value. Change line 1234-1235 from:

```cpp
  exploration.feedResult(ce20_tid, frag_mzs.data(), frag_ints.data(),
                         static_cast<int>(frag_mzs.size()), 1.0, queue);
```

to:

```cpp
  auto ce20_info = exploration.feedResult(ce20_tid, frag_mzs.data(), frag_ints.data(),
                                          static_cast<int>(frag_mzs.size()), 1.0, queue);
```

Then after line 1239 (`TEST_REAL_SIMILAR(group_after.variants[1].score, 0.0)`), add:

```cpp
  // Baseline failure -> ratio not computed -> -1.0
  TEST_REAL_SIMILAR(ce20_info.remaining_ratio, -1.0)
```

- [ ] **Step 5: Extend `winner_selection_by_score` (line 776) — non-RemainingPrecursor metric**

This uses `exploration_config` (mass_count metric). Capture the last feedResultForTest return value. Change line 793 from:

```cpp
    exploration.feedResultForTest(tracking_id, ds, static_cast<double>(i), queue);
```

to:

```cpp
    auto info = exploration.feedResultForTest(tracking_id, ds, static_cast<double>(i), queue);
```

After the loop (after line 794 `}`), before line 796, add:

```cpp
  // mass_count metric -> remaining_ratio should be -1.0 (N/A)
  // (info holds the last variant's result)
  TEST_REAL_SIMILAR(info.remaining_ratio, -1.0)
```

And declare `info` outside the loop scope. Change the loop (lines 789-794) from:

```cpp
  std::vector<double> scores = {1.0, 3.0, 2.0, 5.0, 0.0};
  for (int i = 0; i < 5; ++i)
  {
    DeconvolvedSpectrum ds = makeSyntheticDeconv(i + 1, static_cast<int>(scores[i]));
    int tracking_id = queue.decode(std::string(cmds[i].scan_description).substr(0, 3));
    exploration.feedResultForTest(tracking_id, ds, static_cast<double>(i), queue);
  }
```

to:

```cpp
  std::vector<double> scores = {1.0, 3.0, 2.0, 5.0, 0.0};
  Exploration::FeedResultInfo last_info;
  for (int i = 0; i < 5; ++i)
  {
    DeconvolvedSpectrum ds = makeSyntheticDeconv(i + 1, static_cast<int>(scores[i]));
    int tracking_id = queue.decode(std::string(cmds[i].scan_description).substr(0, 3));
    last_info = exploration.feedResultForTest(tracking_id, ds, static_cast<double>(i), queue);
  }

  // mass_count metric -> remaining_ratio should be -1.0 (N/A)
  TEST_REAL_SIMILAR(last_info.remaining_ratio, -1.0)
```

- [ ] **Step 6: Run tests locally (if available) or verify compilation**

```bash
cd OpenMS/build && ctest -R FLASHIda_exploration_test -V
```

Expected: all existing tests pass, new assertions pass.

- [ ] **Step 7: Commit**

```bash
git add src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Test remaining_ratio in exploration scoring across all paths"
```

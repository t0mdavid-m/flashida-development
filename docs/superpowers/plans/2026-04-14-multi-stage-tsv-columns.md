# Multi-Stage TSV Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Join per-stage fields in command.tsv with semicolons so MS3 rows include both MS2 precursor and MS3 fragment parameters.

**Architecture:** Replace 5 scalar stage extractions in `writeScanCommandRow_()` with a loop over `[0, num_stages)` that builds semicolon-joined strings. Strengthen the logging test to assert multi-stage formatting on MS3 rows and single-stage formatting on MS2 rows.

**Tech Stack:** C++20 (OpenMS), `std::ostringstream` for double formatting consistency.

**Spec:** `docs/superpowers/specs/2026-04-14-multi-stage-tsv-columns-design.md`

---

### Task 1: Add multi-stage assertions to the logging test

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp:330-363`

The existing `scan_commands_tsv_format` test verifies column count and MS2/MS3 row presence but does not check the content of stage-dependent columns. Add assertions that will fail against the current code (which only writes `stages[0]`), then pass after Task 2.

- [ ] **Step 1: Write the failing test assertions**

In `FLASHIda_Logging_test.cpp`, replace the block at lines 330–363 (from `int ms_level_col = ...` through `std::remove(commands_file.c_str());` just before `END_SECTION`) with:

```cpp
  int ms_level_col = tsv.colIndex("ms_level");
  int charge_col = tsv.colIndex("charge");
  int activation_col = tsv.colIndex("activation");
  int precursor_mz_col = tsv.colIndex("precursor_mz");
  int iso_width_col = tsv.colIndex("isolation_width");
  int col_energy_col = tsv.colIndex("collision_energy");

  bool found_ms2 = false;
  bool found_ms3 = false;
  for (const auto& row : tsv.rows)
  {
    if (ms_level_col < 0 || ms_level_col >= (int)row.size())
      continue;

    if (row[ms_level_col] == "2")
    {
      found_ms2 = true;
      // MS2 rows: single stage, no semicolons
      if (charge_col >= 0 && charge_col < (int)row.size())
        TEST_TRUE(row[charge_col].find(';') == std::string::npos);
      if (activation_col >= 0 && activation_col < (int)row.size())
        TEST_TRUE(row[activation_col].find(';') == std::string::npos);
    }

    if (row[ms_level_col] == "3")
    {
      found_ms3 = true;
      // MS3 rows: two stages, semicolons present
      if (charge_col >= 0 && charge_col < (int)row.size())
        TEST_TRUE(row[charge_col].find(';') != std::string::npos);
      if (activation_col >= 0 && activation_col < (int)row.size())
        TEST_TRUE(row[activation_col].find(';') != std::string::npos);
      if (precursor_mz_col >= 0 && precursor_mz_col < (int)row.size())
        TEST_TRUE(row[precursor_mz_col].find(';') != std::string::npos);
      if (iso_width_col >= 0 && iso_width_col < (int)row.size())
        TEST_TRUE(row[iso_width_col].find(';') != std::string::npos);
      if (col_energy_col >= 0 && col_energy_col < (int)row.size())
        TEST_TRUE(row[col_energy_col].find(';') != std::string::npos);
    }
  }
  TEST_TRUE(found_ms2);
  if (cycle.ms3_cmds.size() > 0)
  {
    TEST_TRUE(found_ms3);
  }

  // Every row should have the same number of columns as the header
  for (const auto& row : tsv.rows)
  {
    TEST_EQUAL(row.size(), tsv.headers.size());
  }

  std::remove(commands_file.c_str());
```

- [ ] **Step 2: Verify the test fails**

This test cannot be run locally (build is CI-only), but the assertions will fail because the current `writeScanCommandRow_()` writes `stages[0]` only — MS3 rows will have no semicolons in the charge/activation columns. The failure is: `TEST_TRUE(row[charge_col].find(';') != std::string::npos)` evaluates to false.

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp
git commit -m "test: add multi-stage column assertions for command.tsv MS3 rows"
```

---

### Task 2: Replace scalar stage extraction with generic loop

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:252-258` and `289-293`

Replace the 5 scalar variables extracted from `stages[0]` with a loop over all stages that builds semicolon-joined strings, then use those strings in the stream output.

- [ ] **Step 1: Replace the scalar extraction block**

In `FLASHIda.cpp`, replace lines 252–258:

```cpp
    int charge = (cmd.num_stages > 0) ? cmd.stages[0].charge_state : 0;
    double precursor_mz = (cmd.num_stages > 0) ? cmd.stages[0].precursor_mz : 0.0;
    double iso_width = (cmd.num_stages > 0) ? cmd.stages[0].isolation_width : 0.0;
    double col_energy = (cmd.num_stages > 0) ? cmd.stages[0].collision_energy : 0.0;
    std::string activation;
    if (cmd.num_stages > 0)
      activation = cmd.stages[0].activation_type;
```

With:

```cpp
    std::string charges, precursor_mzs, iso_widths, col_energies, activations;
    for (int i = 0; i < cmd.num_stages; ++i)
    {
      if (i > 0) { charges += ";"; precursor_mzs += ";"; iso_widths += ";"; col_energies += ";"; activations += ";"; }
      charges += std::to_string(cmd.stages[i].charge_state);
      std::ostringstream mz_os, iw_os, ce_os;
      mz_os << cmd.stages[i].precursor_mz;
      iw_os << cmd.stages[i].isolation_width;
      ce_os << cmd.stages[i].collision_energy;
      precursor_mzs += mz_os.str();
      iso_widths += iw_os.str();
      col_energies += ce_os.str();
      activations += cmd.stages[i].activation_type;
    }
```

- [ ] **Step 2: Update the stream output to use the new string variables**

In the same function, replace lines 289–293:

```cpp
                         << charge << "\t"
                         << precursor_mz << "\t"
                         << iso_width << "\t"
                         << col_energy << "\t"
                         << activation << "\t"
```

With:

```cpp
                         << charges << "\t"
                         << precursor_mzs << "\t"
                         << iso_widths << "\t"
                         << col_energies << "\t"
                         << activations << "\t"
```

- [ ] **Step 3: Verify the test now passes**

After this change, MS3 rows will contain semicolon-joined values like `4;2` and `HCD;CID`. The assertions from Task 1 will pass. MS2 rows remain single-valued. MS1 rows produce empty strings for all 5 columns (no stages).

Cannot run locally — will verify via CI after push.

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "feat: join per-stage fields with semicolons in command.tsv"
```

---

### Task 3: Push and verify CI

**Files:** None (CI verification only)

- [ ] **Step 1: Push to flashida-v9-bridge**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

This triggers the `build-dlls` workflow. Wait for CI to complete (~40 min). The `FLASHIda_Logging_test` must pass with the new multi-stage assertions.

- [ ] **Step 2: Verify CI result**

```bash
gh run list -R t0mdavid-m/OpenMS -b flashida-v9-bridge -L 1
```

Check that the run succeeded. If the logging test fails, diagnose from the CI log and fix.

- [ ] **Step 3: Update parent submodule pointer**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add OpenMS
git commit -m "Update OpenMS submodule: multi-stage TSV columns"
```

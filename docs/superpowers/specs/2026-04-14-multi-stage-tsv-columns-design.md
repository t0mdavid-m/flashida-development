# Multi-Stage TSV Columns for command.tsv

**Date:** 2026-04-14
**Status:** Approved
**Scope:** C++ only — `FLASHIda::writeScanCommandRow_()` + logging test

## Problem

`writeScanCommandRow_()` always reads from `stages[0]` for five columns: `charge`, `precursor_mz`, `isolation_width`, `collision_energy`, `activation`. For MS3 commands (`num_stages=2`), the fragment-level data in `stages[1]` (target m/z, fragment charge, MS3 CE, MS3 activation) is fully populated by `buildMS3()` but never written to the TSV. This makes it impossible to debug MS3 targeting from the command log alone.

## Design

### Change: `writeScanCommandRow_()` in `FLASHIda.cpp`

Replace the 5 scalar extractions (lines 251–257):

```cpp
int charge = (cmd.num_stages > 0) ? cmd.stages[0].charge_state : 0;
double precursor_mz = (cmd.num_stages > 0) ? cmd.stages[0].precursor_mz : 0.0;
double iso_width = (cmd.num_stages > 0) ? cmd.stages[0].isolation_width : 0.0;
double col_energy = (cmd.num_stages > 0) ? cmd.stages[0].collision_energy : 0.0;
std::string activation;
if (cmd.num_stages > 0)
  activation = cmd.stages[0].activation_type;
```

With a generic loop over `[0, num_stages)` building semicolon-joined strings:

```cpp
std::string charges, precursor_mzs, iso_widths, col_energies, activations;
for (int i = 0; i < cmd.num_stages; ++i)
{
  if (i > 0) { charges += ";"; precursor_mzs += ";"; iso_widths += ";"; col_energies += ";"; activations += ";"; }
  std::ostringstream mz_ss, iw_ss, ce_ss;
  mz_ss << cmd.stages[i].precursor_mz;
  iw_ss << cmd.stages[i].isolation_width;
  ce_ss << cmd.stages[i].collision_energy;
  charges += std::to_string(cmd.stages[i].charge_state);
  precursor_mzs += mz_ss.str();
  iso_widths += iw_ss.str();
  col_energies += ce_ss.str();
  activations += cmd.stages[i].activation_type;
}
```

Uses `ostringstream` for doubles to match the existing `operator<<` formatting (default precision 6 significant digits), not `std::to_string` which produces fixed notation with 6 decimal places. `charge_state` is `int32_t` so `std::to_string` is fine there.

The stream output replaces the 5 typed variables with the string versions. No changes to the TSV header.

### Output by ms_level

**MS1** (`num_stages=0`) — all five columns are empty strings:
```
ABC	1	ms1	...		 		 		 		 	...
```

**MS2** (`num_stages=1`) — single values, identical behavior to today:
```
DEF	2	ms2	...	4	523.5	3.2	25	HCD	...
```

**MS3** (`num_stages=2`) — both stages semicolon-joined:
```
GHI	3	ms3	...	4;2	523.5;312.8	3.2;2	25;30	HCD;CID	...
```

### Behavioral changes

| ms_level | Before | After |
|----------|--------|-------|
| MS1 | `0`, `0.0`, `0.0`, `0.0`, `""` | empty, empty, empty, empty, empty |
| MS2 | single stage values | identical (single stage values) |
| MS3 | stages[0] only (MS2 params leaked) | stages[0];stages[1] (both stages visible) |

The MS1 change from `0`/`0.0` to empty is more correct (MS1 has no isolation stages) and acceptable.

## Files Modified

1. **`OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`** — `writeScanCommandRow_()`: replace 5 scalar extractions with loop over stages.

2. **`OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp`** — `scan_commands_tsv_format` test: add assertions:
   - MS3 rows: `charge`, `activation` columns contain `;` (two stages)
   - MS3 rows: splitting stage columns on `;` gives exactly 2 parts
   - MS2 rows: stage columns contain no `;` (single stage)

## Not Changed

- `ScanCommand.h` — struct layout unchanged
- `ScanCommandQueue.cpp` — `buildMS2()`, `buildMS3()` unchanged
- TSV header — column names unchanged
- C# side (`FLASHIdaWrapper.cs`) — unchanged (writes its own output file, MS2 only)
- `scan_results.tsv` — unchanged (different writer, different purpose)

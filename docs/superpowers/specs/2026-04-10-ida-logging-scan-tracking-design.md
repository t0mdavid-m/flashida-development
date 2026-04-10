# IDA Logging & Scan Tracking Design

## Goal

Restore the IDA log that was lost during the C# refactoring (backward-compatible with `parseFLASHIdaLog()`) and add two new TSV files for structured scan tracking — all written by the C++ engine, all append+flush for crash safety.

## Architecture

Three output files, all written by the C++ engine inside `FLASHIda`, all append-only with `std::ofstream::flush()` after every write. No new bridge functions. File paths come from a new `"runtime"` JSON config section — C# computes defaults, user can override in the method JSON.

**Files:**
1. `IDALog_{suffix}.log` — human-readable IDA log, backward-compatible with `parseFLASHIdaLog()`
2. `ScanCommands_{suffix}.tsv` — one row per `getNextScanCommand()` dequeue
3. `ScanResults_{suffix}.tsv` — one row per `processScan()` call

## Runtime Config Section

New top-level `"runtime"` block in the JSON config:

```json
{
  "global": { ... },
  "deconvolution": { ... },
  "runtime": {
    "ida_log_path": "IDALog_sample1.log",
    "scan_commands_path": "ScanCommands_sample1.tsv",
    "scan_results_path": "ScanResults_sample1.tsv"
  }
}
```

### C# behavior

1. Deserialize user's method JSON into `MethodConfig`
2. Check if `runtime` paths are already set by user
3. For any that are empty/missing, compute from `CheckLogPath(rawFileName)` and fill in
4. Serialize to C++ JSON via `ToCppJson()` — runtime block passes through

### C++ behavior

1. Parse `runtime` section from JSON config in `CreateFLASHIda()`
2. If paths are non-empty, open `std::ofstream` in append mode
3. Write TSV headers immediately (flush)
4. If paths are empty, no files created (silent — for unit tests that don't need them)

### C# MethodConfig addition

```csharp
[JsonKey("runtime")]
public class RuntimeConfig
{
    [JsonKey("ida_log_path")]
    public string IdaLogPath { get; set; } = "";

    [JsonKey("scan_commands_path")]
    public string ScanCommandsPath { get; set; } = "";

    [JsonKey("scan_results_path")]
    public string ScanResultsPath { get; set; } = "";
}
```

No `[Description]` or `[Developer]` attributes — this section is not included in method documentation. `MethodDocGenerator` skips it.

## IDA Log Format

The IDA log contains **only** MS1 deconvolution results — the precursors selected for MS2. Three line types, matching the exact format that `parseFLASHIdaLog()` (in `FLASHIda.cpp:2316`) already parses:

**MS1 header line:**
```
MS1 Scan# {N} RT {rt:.4f} (Access ID {tracking_id}) - {N} targets
```

**Per-precursor line** (one per MS2 command created from this MS1):
```
Mass={mass}\tZ={charge}\tScore={score:.5f}\tWindow=[{w1:.4f}-{w2:.4f}]\tPrecursorIntensity={pint:.5f}\tPrecursorMassIntensity={mint:.5f}\tFeatures=[{charge_cos:.6f},{charge_snr:.6f},{iso_cos:.6f},{snr:.6f},{charge_score:.6f},{ppm_error:.6f}]\tChargeRange=[{min_z}-{max_z}]\tHCD={hcd}
```

**All-masses line** (all deconvolved masses from the MS1 scan, not just selected precursors):
```
AllMass={mass1} {mass2} ...
```

Nothing else goes in this file.

**Write point:** In `processScan()` when `msLevel == 1`, after deconvolution and MS2 command generation. Data comes from the `ScanCommand` structs that were just pushed to the queue.

**Contract:** The 15 floats parsed by `parseFLASHIdaLog()` are: mass, charge, qscore, window_low, window_high, precursor_intensity, mass_intensity, charge_min, charge_max, charge_cos, charge_snr, iso_cos, snr, charge_score, ppm_error.

## ScanCommands TSV

One row appended in `getNextScanCommand()` every time a command is dequeued and returned to C#.

**Columns:**

| Column | Type | Source |
|--------|------|--------|
| `tracking_id` | string | `encodeTracking_(scan_id)` — 3-char base-94 ID |
| `ms_level` | int | `cmd.msn_level` — 1, 2, or 3 |
| `scan_type` | string | Derived from scan_description char[3]: `agc`, `survey`, `recording`, `conditional`, `followup`, `exploration`, `cv_transition`, `idle_ms1`, `idle_agc`, `cycle_time` |
| `enqueue_ts` | uint64 | `cmd.enqueue_timestamp_ms` — steady-clock ms since engine creation |
| `priority` | int | `cmd.priority` — 0-3 |
| `faims_cv` | double | `cmd.faims_cv` — 0.0 if disabled |
| `mono_mass` | double | `cmd.mono_mass` — 0.0 for MS1/AGC |
| `charge` | int | `cmd.stages[0].charge_state` — 0 for MS1 |
| `precursor_mz` | double | `cmd.stages[0].precursor_mz` — 0.0 for MS1 |
| `isolation_width` | double | `cmd.stages[0].isolation_width` |
| `collision_energy` | double | `cmd.stages[0].collision_energy` |
| `activation` | string | `cmd.stages[0].activation_type` — HCD, ETD, CID, etc. |
| `qscore` | double | `cmd.qscore` |
| `charge_cos` | double | `cmd.charge_cos` |
| `charge_snr` | double | `cmd.charge_snr` |
| `iso_cos` | double | `cmd.iso_cos` |
| `snr` | double | `cmd.snr` |
| `charge_score` | double | `cmd.charge_score` |
| `ppm_error` | double | `cmd.ppm_error` |
| `precursor_intensity` | double | `cmd.precursor_intensity` |
| `peakgroup_intensity` | double | `cmd.peakgroup_intensity` |
| `hcd_energy` | int | `cmd.hcd_energy` |
| `parent_tracking_id` | string | From MS3 context — empty for MS1/MS2 |
| `ion_type` | string | From scan_description — `b`, `y`, etc. Empty if not MS3 |
| `ion_index` | int | From scan_description — 0 if not MS3 |

All fields are already on `ScanCommand` — no additional computation needed.

## ScanResults TSV

One row appended in `processScan()` every time a scan result is processed — MS1, MS2, and MS3.

**Columns:**

| Column | Type | Source |
|--------|------|--------|
| `tracking_id` | string | Extracted from scan_description `substr(0,3)` — join key to commands file |
| `resolve_ts` | uint64 | Steady-clock ms at `processScan()` entry — same clock as `enqueue_ts` |
| `duration_ms` | uint64 | `resolve_ts - enqueue_ts` — looked up from `pending_scan_map_` before erase |
| `rt` | double | Retention time in minutes |
| `mass_count` | int | Peak groups found by FLASHDeconv — MS1: deconvolved masses; MS2/MS3: deconvolved fragments |
| `commands_pushed` | int | Number of follow-up commands created |
| `child_ids` | string | Semicolon-separated tracking IDs of commands created — empty if 0 |
| `tag_count` | int | Sequence tags found — 0 if tagging inactive or MS1/MS3 |
| `matched_protein` | string | Protein name/accession from FASTA match — empty if no match |
| `proteoform_sequence` | string | ProForma notation from FLASHExtender — empty if not identified |

No columns redundant with ScanCommands. Join on `tracking_id`.

### Implementation notes

- `duration_ms`: Look up `pending_scan_map_[tracking_id].enqueue_timestamp_ms` before erasing the entry (erase already happens in `processScan()`).
- `child_ids`: Collect tracking IDs from `pushCommand_()` / `buildMS2Command_()` / `buildMS3Command_()` calls during this `processScan()` invocation into a vector, then format as semicolon-separated string.
- `proteoform_sequence`: Store FLASHExtender output on a member variable (currently printed to stdout), read when writing the results row.

## Crash Safety

Every write is `append + std::ofstream::flush()`. No seeks, no rewrites.

- Kill the process at any point: valid files with all rows up to the last flush
- IDA log: each MS1 block (header + precursor lines + AllMass) is flushed as a unit
- TSV files: each row is flushed individually after append
- Append cost: <0.1ms per write on both SSD and HDD

## Testing

### Test 1: IDA Log contract test (C++ unit test)

Push known MS1 spectra through `processScan()`, let engine generate MS2 commands and write IDA log to a temp file. Call `parseFLASHIdaLog()` on the written file. Verify:
- Correct number of scan groups
- Each precursor's 15 floats match: mass, charge, qscore, window_low, window_high, precursor_intensity, mass_intensity, charge_min, charge_max, charge_cos, charge_snr, iso_cos, snr, charge_score, ppm_error
- Round-trip fidelity (write then parse then compare)

### Test 2: ScanCommands TSV format test (C++ unit test)

Full MS1 then MS2 then MS3 cycle:
1. Push MS1 spectra via `processScan()` — engine creates MS2 commands
2. Dequeue MS2 commands via `getNextScanCommand()` — TSV rows written
3. Feed MS2 results back through `processScan()` — engine creates MS3 commands
4. Dequeue MS3 commands via `getNextScanCommand()` — TSV rows written
5. Feed MS3 results back through `processScan()`

Verify:
- Header row has all expected column names
- Correct number of data rows (one per dequeued command)
- MS2 rows: correct tracking_id, ms_level=2, precursor_mz, qscore, scoring fields
- MS3 rows: ms_level=3, parent_tracking_id populated, ion_type and ion_index populated
- MS1 fallback/AGC rows: appropriate scan_type, zero'd scoring fields

### Test 3: ScanResults TSV format test (C++ unit test)

Full MS1 then MS2 then MS3 cycle (same flow as Test 2). Verify:
- One row per `processScan()` call (MS1, MS2, and MS3)
- MS1 rows: `mass_count` matches deconvolution output, `child_ids` contains MS2 tracking IDs, `commands_pushed` matches child_ids count
- MS2 rows: `duration_ms` = `resolve_ts - enqueue_ts` (non-negative, plausible), `child_ids` contains MS3 tracking IDs if MS3 was triggered, `tag_count`/`matched_protein`/`proteoform_sequence` populated when tagging active
- MS3 rows: `duration_ms` populated, `mass_count` reflects fragment deconvolution

### Test 4: Join integrity test (C++ unit test)

Run full MS1 then MS2 then MS3 cycle, read both TSV files. Verify:
- Every `tracking_id` in results has a matching row in commands
- Every child_id in results exists as a tracking_id in commands
- `commands_pushed` equals length of `child_ids` for every results row
- Parent-child graph is acyclic

### Test 5: Crash safety test (C++ unit test)

Write entries across MS1 then MS2 then MS3 cycle. After each `processScan()` and `getNextScanCommand()` call, verify both files are valid TSV (no partial lines, no missing headers, parseable).

### Test 6: Runtime config passthrough (C# NUnit test)

Verify `RuntimeConfig` paths flow through `ToCppJson()` into the `runtime` section of the JSON string. Verify user-set paths are preserved (not overwritten by C# defaults).

## Files to Modify

### C++ (OpenMS, `flashida-v9-bridge` branch)

- **`FLASHIda.h`** — Add `std::ofstream` members for 3 files, `writeIDALogEntry_()`, `writeScanCommandRow_()`, `writeScanResultRow_()` private methods, member variables for last proteoform/tag results
- **`FLASHIda.cpp`** — Parse `runtime` from JSON config, open files in constructor, write in `processScan()` and `getNextScanCommand()`, close in destructor. Collect child_ids during command generation. Store tag/proteoform results on member variables instead of (or in addition to) printing to stdout.
- **New: `FLASHIda_Logging_test.cpp`** — Tests 1-5
- **`executables.cmake`** — Register `FLASHIda_Logging_test`

### C# (FlashIDA, `phase-10` branch)

- **`MethodConfig.cs`** — Add `RuntimeConfig` class, add `Runtime` property to `MethodConfig`
- **`MethodParameters.cs`** — Pass `runtime` through `ToCppJson()`
- **`MethodConfigSerializer.cs`** — Handle `runtime` section (deserialize/serialize)
- **`FLASHIdaWrapper.cs`** or **`Flash.cs`** — Compute default paths from `CheckLogPath()`, inject into config before `CreateFLASHIda()`
- **`MethodDocGenerator.cs`** — Skip `RuntimeConfig` (no `[Description]` attributes)
- **`Flash.Tests/JsonConfigTests.cs`** — Test 6 (runtime config passthrough)

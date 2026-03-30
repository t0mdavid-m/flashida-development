# Test File Specification

**Date:** 2026-03-22
**Applies to:** FLASHIda migration, Phases 0–8 (baseline-plan.md v9)

This document is the authoritative reference for every test file format used across the FLASHIda migration. For each file, it specifies the exact format, content requirements, size constraints, how to produce it, and which phases reference it. Cross-reference the per-phase implementation plans in `Phase_0/` through `Phase_8/implementation-plan.md` for usage context.

---

## 1. Spectrum Files (input data)

All spectrum files live in `FlashIDA/test-data/spectra/`. They are committed to the repository once generated and are not regenerated on each CI run.

### Spectrum File Format

All spectrum files share the following format. Individual file subsections below note any deviations.

**Per-scan structure:**

```
Spec <native_id>\t<rt_seconds>
<mz_1>\t<intensity_1>
<mz_2>\t<intensity_2>
...
```

- **Header line:** The literal string `Spec` followed by a single space, then the native scan ID (e.g., `scan=42`), then a **tab character** (`\t`), then the retention time as a bare decimal number in **seconds** (4 decimal places, e.g., `70.5800`). There is no `rt=` prefix.
- **Delimiter:** Tab (`\t`) between fields on all lines (header and peak lines).
- **M/z column:** 64-bit floating-point, 6 decimal places, no units.
- **Intensity column:** 32-bit floating-point, 2 decimal places, no units.
- **Encoding:** UTF-8, Unix line endings (`\n`) preferred; Windows line endings (`\r\n`) are also accepted by `Flash.exe`.
- **No blank lines** between the header and peaks, and no blank lines within a scan block.

**RT unit chain:** The retention time undergoes two conversions between the text file and the C++ engine:
1. **Text file** stores RT in **seconds** (e.g., `70.5800`)
2. **C# parser** (`FLASHIdaWrapper.cs`) divides by 60 → **minutes** (e.g., `1.1763`)
3. **C++ bridge** (`FLASHIdaBridgeFunctions.cpp`) multiplies by 60 → back to **seconds**

The C++ engine's `@param rt` documents "Retention time in seconds." This double-conversion exists because the C# side historically worked in minutes while the C++ engine works in seconds.

**Backwards compatibility note:** The tab-separated header format with RT in bare seconds (no `rt=` prefix) is kept intentionally. The production `FLASHIdaWrapper.cs` parser, all existing test data, and regression golden files depend on this format. Do not change the parser to match an alternative spec — update the spec to match the parser instead. (See Phase 0 lessons learned #8.)

**Single-scan files** contain exactly one header line followed by all peaks for that scan.

**Multi-scan files** contain multiple scan blocks in sequence. Each scan block begins with a header line followed by zero or more peak lines. Scan blocks are separated by the next header line (no blank-line separator is required, but a blank line between scan blocks is permitted).

```
Spec <native_id>\t<rt_seconds>
<mz_1>\t<intensity_1>
<mz_2>\t<intensity_2>
...
Spec <native_id>\t<rt_seconds>
<mz_1>\t<intensity_1>
...
```

**Parser requirement for multi-scan files:** Any code that loads a spectrum from a multi-scan file for single-scan use (e.g., unit tests, mock scan loaders) must stop reading at the first scan boundary — i.e., break when a second `Spec` header line is encountered. Failing to do so mixes peaks from multiple scans and overwrites the RT value, causing silent deconvolution failures (0 results with no error). Flash.exe's own parser handles multi-scan correctly (it processes scan N when scan N+1's header is read), but test-side parsers (`LoadSpectrum`, `FromTsv`, etc.) must explicitly implement this stop-at-boundary logic. (See Phase 0 lessons learned #9.)

---

### 1.1 `ms1_smoke_test.txt`

**Purpose:** Minimal multi-scan MS1 spectrum for Phase 0 smoke testing. Must be small enough that `Flash.exe` processes it in under 60 seconds and produces at least one row of output.

**Format:** Multi-scan (minimum 2 scans). See [Spectrum File Format](#spectrum-file-format) above. The file must contain at least 2 scans because Flash.exe's parser only processes a scan's accumulated data when the *next* `Spec` header line is encountered; the last scan in the file is never processed. A single-scan file produces zero output rows. (See Phase 0 lessons learned #7.)

**Content requirements:**

- The primary scan (scan 1) must contain enough peaks with at least one identifiable charge envelope (consecutive isotope peaks with a recognizable m/z spacing pattern), so that FLASHDeconv produces at least 1 deconvolved proteoform and `Flash.exe` writes at least one data row to the output TSV. In practice this requires a scan from the main elution region of a top-down experiment; scans in the 10-200 peak range typically lack protein charge envelopes detectable by the engine. The actual file uses a scan with ~6,588 peaks (scan 2 has ~21 peaks as a trigger). (See Phase 0 lessons learned #6.)
- Data must be real measured peaks extracted from a top-down proteomics `.mzML` file using `prepare-test-data.py`. Synthetically constructed peak arrays are not acceptable.

**Size constraints:**

- Target: < 500 KB on disk (the primary scan may have thousands of peaks).
- Actual size as committed for Phase 0: **143 KB** (2 scans: 6,588 + 21 peaks). This exceeds the original < 20 KB spec target, but that target was unreachable — no real MS1 scan with < 200 peaks contains detectable protein charge envelopes. The spec has been updated to match the actual file. (See Phase 0 lessons learned #6.)
- The file must remain small enough for the smoke test to complete in under 60 seconds on a `windows-latest` GitHub Actions runner.

**Source:** Extract 2 consecutive MS1 scans from an existing top-down `.mzML` file, where the first scan is from the main elution region:

```bash
python FlashIDA/test-scripts/prepare-test-data.py source.mzML \
    FlashIDA/test-data/spectra/ms1_smoke_test.txt \
    --scan-index <N> --max-scans 2
```

Verify that `Flash.exe ms1_smoke_test.txt output.tsv method_default.xml` exits with code 0 and `output.tsv` has at least two lines (header + one data row).

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 0 | P0-U03, P0-U04, P0-R01 | Smoke test and golden baseline capture |
| Phase 1 | P1-R01, P1-R02 | Regression: JSON config and legacy config format |
| Phase 2 | P2-R01 | Regression: unchanged behavior after metadata struct addition |
| Phase 3 | P3-R01 | Regression: shadow validation behavior |
| Phase 4 | P4-R01 | Regression gate: `UseUnifiedBridge=False` (flag-off regression uses this smaller file to keep overhead low) |

---

### 1.2 `ms1_standard.txt`

**Purpose:** Representative MS1 data for regression testing across all acquisition modes in Phase 4 and later. Must be rich enough to exercise the scoring, filtering, and command-generation logic across multiple precursors and charge states.

**Format:** Multi-scan. See [Spectrum File Format](#spectrum-file-format) above.

**Content requirements (DATA-5 from Phase 4 implementation plan):**

- At least 5 independently deconvolvable charge envelopes across all scans in the file.
- Precursor masses spanning the 5–100 kDa range (ensures the scoring dispatch and mass-range filtering are exercised).
- Precursor intensity dynamic range covering at least 2 orders of magnitude (ensures the top-N selection logic is exercised non-trivially).
- Must include scans that produce targets for all scoring branches (QScore, IDScore representative, IDScore all-charges), so that all 6 scoring paths in `processScan()` are reachable during regression tests.
- Data must be real measured peaks from characterized top-down experiment data. Do not fabricate values.

**Size constraints:**

- Target: < 5 MB on disk.
- If the file exceeds 5 MB, store it using Git LFS.
- Number of scans: no hard limit, but each regression run invokes `Flash.exe` once on the full file. Keep total processing time for a single `Flash.exe` invocation under 5 minutes on a `windows-latest` GitHub Actions runner.

**Source:**

```bash
python FlashIDA/test-scripts/prepare-test-data.py source.mzML \
    FlashIDA/test-data/spectra/ms1_standard.txt \
    --ms-level 1 --max-scans 50
```

Adjust `--max-scans` to balance coverage against CI runtime. The resulting file is committed and not regenerated.

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 4 | P4-R02 through P4-R10 | All mode regression tests with `UseUnifiedBridge=True` |
| Phase 4 | P4-I02 | Integration: bridge produces non-zero command count |
| Phase 5 | P5-R01 | Regression: all modes identical to Phase 4 output |
| Phase 6 | P6-R01 | Non-FAIMS regression: output unchanged after FAIMS absorption |
| Phase 7 | P7-R01, P7-R02 | Exploration disabled and enabled regression |
| Phase 8 | P8-R01 | Full regression: all 12+ mode configs |

---

### 1.3 `ms2_hcd_fragment.txt`

**Purpose:** Single MS2 HCD fragmentation spectrum from a known protein. Used in Phase 4 regression tests that require MS2 input: tag-based targeting (P4-R06), isobaric quant (P4-R07), and all MS3 mode tests (P4-R08 through P4-R10).

**Format:** Single-scan. See [Spectrum File Format](#spectrum-file-format) above.

**Content requirements (DATA-6 from Phase 4 implementation plan):**

- Acquired from a known protein; the protein identity must be documented in a comment at the top of the file or in `FlashIDA/test-data/golden/README.md`.
- Precursor mass known and matching an entry in the inclusion list configured in `method_inclusion.xml` and `method_tag_targeting.xml`.
- Real measured fragment ions — not simulated.
- If isobaric labeling was used during acquisition, reporter ions at the expected m/z values must be present in the spectrum (required for P4-R07, P4-U07 quant routing tests).
- Sufficient fragment ion density for MS3 target selection: at least 5 high-intensity fragment ions, so that `selectMS3Targets_()` has candidates to return.

**Size constraints:**

- Target: < 200 KB on disk. A single MS2 scan rarely exceeds 2,000 peaks.

**Source:** Extract a single MS2 HCD scan from existing characterized lab data:

```bash
python FlashIDA/test-scripts/prepare-test-data.py source.mzML \
    FlashIDA/test-data/spectra/ms2_hcd_fragment.txt \
    --ms-level 2 --scan-index <N> --max-scans 1
```

Select the scan index `<N>` for a scan where the precursor protein is known and the spectrum quality is high (abundant fragment ions, low noise).

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 4 | P4-R06 | Tag-based targeting mode regression |
| Phase 4 | P4-R07 | Isobaric quant mode regression |
| Phase 4 | P4-R08, P4-R09, P4-R10 | MS3 mode 1, 2, 3 regression |
| Phase 5 | P5-R01 | Regression: modes with MS2 input unchanged |
| Phase 6 | P6-R01 | Non-FAIMS regression (indirect; passed via regression runner) |
| Phase 7 | P7-R02 | Exploration enabled regression (MS2 context needed) |
| Phase 8 | P8-R01 | Full regression |

---

### 1.4 `ms1_faims_3cv.txt`

**Purpose:** MS1 scans from a real FAIMS acquisition covering at least 3 compensation voltage (CV) values. Required for Phase 6 FAIMS regression tests (P6-R02, P6-R03). Also used by Phase 5 P5-R02 to verify FAIMS still functions after C# simplification.

**Format:** Multi-scan. See [Spectrum File Format](#spectrum-file-format) above, with one FAIMS-specific extension:

- **`cv=<cv_value>`**: Each header line carries an additional field appended after the RT value, separated by a tab character. The compensation voltage is a signed decimal number in volts (e.g., `cv=-40`, `cv=-50.0`). Example: `Spec scan=1\t70.5800\tcv=-40`.
- If the source instrument writes the CV in the native scan header, `prepare-test-data.py` must extract it and include it verbatim.
- The CV values present in this file must exactly match the `cv_values` array in `method_faims_3cv.xml` and `method_faims_skip.xml`. The method config files must be updated if the real data uses CV values different from the plan's defaults of `-40, -50, -60`.

**Content requirements:**

- Scans at a minimum of 3 distinct CV values (one full cycle).
- Each CV value must appear in at least 2 scan blocks so that the precursor count accumulator is exercised.
- For the adaptive skip test (`method_faims_skip.xml`): some CV values must produce fewer than `cv_precursor_threshold` deconvolvable precursors, and at least one CV value must produce more. This variation in precursor density across CV values must be natural — do not discard peaks to simulate sparsity.
- Real FAIMS experiment data. Do not construct synthetically.

**Size constraints:**

- Target: < 5 MB on disk.
- If the file exceeds 5 MB, store it using Git LFS.

**Source:**

```bash
python FlashIDA/test-scripts/prepare-test-data.py source_faims.mzML \
    FlashIDA/test-data/spectra/ms1_faims_3cv.txt \
    --ms-level 1 --include-cv
```

The `--include-cv` flag causes the script to read the FAIMS CV from the spectrum's `userParam` or `scanWindowList` and append `cv=<value>` to each header line.

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 5 | P5-R02 | FAIMS still works after C# simplification; captures `faims_3cv.tsv` and `faims_skip.tsv` baselines |
| Phase 6 | P6-R02 | FAIMS 3-CV cycling regression |
| Phase 6 | P6-R03 | FAIMS adaptive skipping regression |
| Phase 8 | P8-R01 | Full regression (FAIMS mode configs) |

---

### 1.5 `ms2_smoke_test.txt`

**Purpose:** Single MS2 scan used in Phase 0 continuity tests for tag-based targeting, conditional MS2, and isobaric quantification test modes (AL-CT17–CT21). Distinct from `ms2_hcd_fragment.txt` (Phase 4 regression), which requires a protein-matched fragment spectrum.

**Format:** Single-scan. See [Spectrum File Format](#spectrum-file-format) above.

**Content requirements:**

- A real measured MS2 HCD scan from a top-down experiment.
- Sufficient fragment ion density for the continuity harness to exercise the tag-based targeting path.

**Size constraints:**

- Target: < 200 KB on disk.

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 0 | AL-CT17, AL-CT18, AL-CT19, AL-CT20, AL-CT21 | Continuity tests: tag targeting, conditional MS2, quant mode |

---

### 1.6 `ms1_high_density.txt` (optional)

**Purpose:** High-density MS1 spectrum containing 50 or more deconvolvable proteoforms. Used in queue saturation stress tests (Phase 3 P3-S01 and Phase 4 threading tests). This file is optional; if not provided, stress tests use repeated calls with `ms1_standard.txt` instead.

**Format:** Multi-scan. See [Spectrum File Format](#spectrum-file-format) above.

**Content requirements:**

- At least 50 independently deconvolvable charge envelopes in a single scan.
- Extracted from a complex top-down sample (e.g., whole-cell lysate or ribosomal protein mixture).
- Real measured data only.

**Size constraints:**

- Target: < 2 MB on disk (a single dense MS1 scan with 2,000+ peaks).
- If the file exceeds 5 MB, store it using Git LFS.

**Source:**

```bash
python FlashIDA/test-scripts/prepare-test-data.py source_complex.mzML \
    FlashIDA/test-data/spectra/ms1_high_density.txt \
    --ms-level 1 --scan-index <N> --max-scans 1
```

Select `<N>` to be a scan from a dense fraction with high spectral complexity.

**Used by:**

| Phase | Test IDs | Purpose |
|-------|----------|---------|
| Phase 3 | P3-S01 (stress) | Queue saturation: 1,000 rapid ProcessScan calls |
| Phase 4 | Threading / stress tests | Verify no memory leaks under load |

---

## 2. Golden Files (regression baselines)

All golden files live in `FlashIDA/test-data/golden/`. They are committed to the repository. `FlashIDA/test-data/golden/README.md` documents provenance and update procedures for each file (see Phase 0 implementation plan, Step 4.4, for the `README.md` content).

Golden files are never constructed manually. They are always captured by running `Flash.exe` on a known-good CI build and downloading the resulting artifact. The developer inspects the artifact before committing it.

### 2.1 Golden File Format

All golden files are **tab-separated values (TSV)** with the following properties:

- **Header row:** Present on line 1. Column names are exact strings (case-sensitive).
- **Delimiter:** Tab (`\t`).
- **Encoding:** UTF-8, no BOM.
- **Line endings:** `\r\n` (Windows, produced by `Flash.exe` on `windows-latest`) or `\n` (Unix). `compare_golden.py` normalizes line endings before comparison.
- **No trailing tab** on any line.

**Columns (in order):**

| Column | Type | Description |
|--------|------|-------------|
| `rt` | float | Retention time in minutes |
| `mz1` | float | Precursor m/z of isolation stage 1 |
| `mz2` | float | Precursor m/z of isolation stage 2 (MS3 only; empty or 0.0 for MS2) |
| `qScore` | float | Q-score from FLASHDeconv |
| `charges` | string | Semicolon-delimited list of detected charge states (e.g., `"5;6;7"`) |
| `monoMasses` | float | Monoisotopic mass (Da) |
| `ccos` | float | Charge cosine similarity score |
| `csnr` | float | Charge signal-to-noise ratio |
| `cos` | float | Isotope cosine similarity |
| `snr` | float | Signal-to-noise ratio |
| `cScore` | float | Combined score |
| `ppm` | float | Mass accuracy in ppm |
| `precursorIntensity` | float | Precursor peak intensity |
| `massIntensity` | float | Deconvolved mass intensity |
| `hcd` | int | HCD collision energy (integer) |

**Comparison rules** (enforced by `compare_golden.py`):

- Row count must match exactly between golden and actual files.
- `charges` (string): exact match.
- `hcd` (integer): exact match.
- Float columns: absolute tolerance 1e-6 for values with |v| ≤ 1.0; relative tolerance 1e-4 for values with |v| > 1.0.

### 2.2 Golden file inventory

| File | Phase captured | Spectrum input | Config input | Description |
|------|---------------|---------------|--------------|-------------|
| `baseline_phase0.tsv` | Phase 0 | `ms1_smoke_test.txt` | `method_default.xml` | Pre-migration baseline. First golden file. Regression anchor for Phases 1–3. |
| `baseline_phase3.tsv` | Phase 3 | `ms1_smoke_test.txt` | `method_default.xml` | Phase 3 zero-behavioral-change baseline. Should match `baseline_phase0.tsv` (same input, no behavioral changes). Used as P4-R01 regression target with `UseUnifiedBridge=False`. Added per Phase 3 compliance report (P3-R01 deferred to Phase 4). |
| `phase4_standard_dda.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` | `method_default.xml` | **Pre-switch baseline.** Captured from old bridge path before unified bridge implementation. Used as P4-R02 regression target to prove behavioral equivalence. |
| `phase4_deep_mode.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` | `method_deep.xml` | **Pre-switch baseline.** Deep mode via old bridge. P4-R03 regression target. |
| `phase4_inclusion.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` | `method_inclusion.xml` | **Pre-switch baseline.** Inclusion list mode via old bridge. P4-R04 regression target. |
| `phase4_exclusion.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` | `method_exclusion.xml` | **Pre-switch baseline.** Exclusion list mode via old bridge. P4-R05 regression target. |
| `phase4_tag_targeting.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `method_tag_targeting.xml` | **Pre-switch baseline.** Tag-based targeting via old bridge. P4-R06 regression target. |
| `phase4_quant.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `method_quant.xml` | **Pre-switch baseline.** Isobaric quant via old bridge. P4-R07 regression target. |
| `phase4_ms3_mode1.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `method_ms3_mode1.xml` | **Pre-switch baseline.** MS3 Source CID / SPS via old bridge. P4-R08 regression target. |
| `phase4_ms3_mode2.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `method_ms3_mode2.xml` | **Pre-switch baseline.** MS3 mode 2 via old bridge. P4-R09 regression target. |
| `phase4_ms3_mode3.tsv` | Phase 4 (Step 0) | `ms1_standard.txt` + `ms2_hcd_fragment.txt` | `method_ms3_mode3.xml` | **Pre-switch baseline.** MS3 mode 3 (HCD-triggered) via old bridge. P4-R10 regression target. |
| `faims_3cv.tsv` | Phase 5 (P5-R02) | `ms1_faims_3cv.txt` | `method_faims_3cv.xml` | FAIMS 3-CV cycling baseline captured while `ScanScheduler.cs` is still active. Used as Phase 6 regression target. |
| `faims_skip.tsv` | Phase 5 (P5-R02) | `ms1_faims_3cv.txt` | `method_faims_skip.xml` | FAIMS adaptive skipping baseline. Used as Phase 6 regression target. |
| `phase7_exploration.tsv` | Phase 7 | `ms1_standard.txt` | `method_exploration.xml` | Exploration engine active: variant scans present in output. |

**Note on `phase4_standard_dda.tsv` vs. `baseline_phase0.tsv`:** These two golden files use different input spectrum files (`ms1_standard.txt` vs. `ms1_smoke_test.txt`). They are not directly compared against each other. The Phase 4 standard DDA golden uses the larger, richer input spectrum for comprehensive mode coverage.

**Note on Phase 4 golden file capture timing:** All `phase4_*.tsv` files are captured in Phase 4 **Step 0** (before unified bridge implementation) from the old bridge path. This ensures they represent the correct baseline behavior. After the unified bridge is implemented, regression tests P4-R02 through P4-R10 verify that the new path produces identical output. This approach proves behavioral equivalence rather than just capturing "whatever the new code produces."

### 2.3 How golden files are generated

1. Push the implementation branch to GitHub. The CI `windows-tests` job runs `Flash.exe` for each configuration in capture mode.
2. In the GitHub Actions run summary, download the `golden-capture` artifact (uploaded by the `capture-golden` step in the CI workflow).
3. Inspect each `.tsv` file: verify the header row matches the 15-column format, verify row count is non-zero, verify float values are in plausible ranges for the given experiment.
4. Copy the reviewed files into `FlashIDA/test-data/golden/` and commit them alongside the code change that necessitated the new golden file.
5. Update `FlashIDA/test-data/golden/README.md` to document the new file's provenance (branch, CI run URL, OpenMS commit hash, spectrum source).

### 2.4 How golden files are updated

When an intentional behavioral change occurs (e.g., Phase 4 switch-over changes scoring output):

1. Run the regression suite locally using `regression-runner.ps1 -captureMode` (writes output instead of comparing).
2. Inspect the diff between the old golden file and the new output: `diff old_golden.tsv new_output.tsv`.
3. Verify the diff is expected and matches the stated behavioral change.
4. Commit the updated golden file in the same PR as the code change.
5. In the PR description, list each changed golden file and explain why the output changed.

Golden file changes in phases that claim zero behavioral change (Phase 0, Phase 2, Phase 3, Phase 5) are a red flag and must be investigated before merging.

### 2.5 Continuity Golden JSON Files

These are behavioral reference files used by the acquisition loop continuity tests (Section 5 of `acquisition-loop-testing-strategy.md`). They are JSON (not TSV) and capture `ScanCommandRecord` sequences produced by the full pipeline for a given input and config. They are captured in Phase 0 (first run) and asserted against in every subsequent phase.

**Location:** `FlashIDA/test-data/golden/`

> **Phase 0 lesson #15 / Phase 1 lesson #1:** Continuity golden JSON files follow the same 2-commit capture procedure as TSV golden files (Section 2.3). The first push runs CI and uploads the artifact; the second push commits the captured file. Submodule pointer must be updated and committed before the first push, or new C++ files are invisible to CI.

> **Comparison note:** Continuity golden comparison uses exact string equality on the serialized JSON (not tolerance-based field comparison). This means float fields in the JSON must match to full precision. If a DLL rebuild changes floating-point output even within tolerance, the continuity golden files must be recaptured. (Phase 0 lesson #23.)

| File | Captured by | Mode |
|------|-------------|------|
| `continuity_standard_dda.json` | AL-CT06 (Phase 0) | Standard DDA |
| `continuity_inclusion.json` | AL-CT15 (Phase 0) | Inclusion list |
| `continuity_exclusion.json` | AL-CT16 (Phase 0) | Exclusion list |
| `continuity_tag_targeting.json` | AL-CT19 (Phase 0) | Tag-based targeting |
| `continuity_quant.json` | AL-CT21 (Phase 0) | Isobaric quantification |
| `continuity_ms3_mode1.json` | AL-CT24 (Phase 0) | MS3 mode 1 |
| `continuity_ms3_mode2.json` | AL-CT25 (Phase 0) | MS3 mode 2 |
| `continuity_ms3_mode3.json` | AL-CT26 (Phase 0) | MS3 mode 3 |
| `continuity_faims_skip.json` | AL-CT28 (Phase 0) | FAIMS adaptive skip |
| `continuity_exploration.json` | AL-CT30 (Phase 7) | Exploration CE optimization |

---

## 3. Configuration Files (method XMLs / JSONs)

All method configuration files live in `FlashIDA/test-data/configs/`. They are committed to the repository and edited by hand. Each file is a variant of `FlashIDA/src/Flash/etc/method.xml` with specific settings enabled or modified.

### 3.1 Configuration File Format

All config files are XML, following the same schema as the production `method.xml`. Key sections:

- `<Deconvolution>` — charge range, mass tolerance, score threshold
- `<PrecursorSelection>` — max mass count, RT window, target mode, IDScore flag, HCD energy
- `<Quantification>` — quant enabled, reporter m/z tolerance, fold change threshold
- `<FAIMS>` — CV values, max CV skip, CV precursor threshold
- `<MSSettings>` — MS1 and MS2 analyzer, resolution, AGC target, max IT
- `<ScanScheduling>` — cycle time, scan timeout
- `<ParameterOptimization>` — exploration enabled, depth, variant count, CE range
- `<UseUnifiedBridge>` — present in Phases 4; removed in Phase 5

File size: all config files are expected to be < 5 KB each.

### 3.2 Config file inventory

| File | Introduced | Purpose | Key parameters |
|------|-----------|---------|----------------|
| `method_default.xml` | Phase 0 | Standard DDA, no special modes. Regression anchor. | `UseUnifiedBridge=False` (added Phase 4, removed Phase 5). Standard HCD, 5 top precursors. |
| `method_default_topn5.xml` | Phase 0 | Standard DDA with `MaxMs2CountPerMs1=5` (TopN=5). Used by CT08 (TopN ordering) and CT12 (deep vs standard comparison) where TopN=1 would make assertions trivially true. | Same as `method_default.xml` except `MaxMs2CountPerMs1=5`. (See Phase 0 lessons learned #12.) |
| `method_deep.xml` | Phase 4 | Deep mode: more precursors per MS1 cycle, lower score threshold. | Higher `MaxMassCount`, lower `ScoreThreshold`. Also used by CT12 for deep-vs-standard comparison against `method_default_topn5.xml`. |
| `method_inclusion.xml` | Phase 4 | Inclusion list mode: only listed masses targeted. | `TargetMode` set to inclusion. Inclusion list contains the precursor mass from `ms2_hcd_fragment.txt`. |
| `method_exclusion.xml` | Phase 4 | Exclusion list mode: listed masses suppressed. | `TargetMode` set to exclusion. Exclusion list contains a mass present in `ms1_standard.txt`. |
| `method_tag_targeting.xml` | Phase 4 | Tag-based targeting via MS2 fragment matching. | `TagBasedTargeting=True`. Points to inclusion list expanded at runtime. |
| `method_quant.xml` | Phase 4 | Isobaric quantification mode. | `Quantification.Enabled=True`, reporter m/z tolerance and fold change threshold set to values matching reporter ions in `ms2_hcd_fragment.txt`. |
| `method_ms3_mode1.xml` | Phase 4 | MS3 Source CID / SPS targeting. | `MS3.Enabled=True`, `MS3.Mode=1`. MS3 CE settings for source CID. |
| `method_ms3_mode2.xml` | Phase 4 | MS3 mode 2. | `MS3.Enabled=True`, `MS3.Mode=2`. |
| `method_ms3_mode3.xml` | Phase 4 | MS3 mode 3 (HCD-triggered). | `MS3.Enabled=True`, `MS3.Mode=3`. |
| `method_faims_3cv.xml` | Phase 5 (for P5-R02) | FAIMS with 3 CVs, no adaptive skipping. | `FAIMS.CVValues` must exactly match the CV annotations in `ms1_faims_3cv.txt`. `MaxCVSkip=0`. |
| `method_faims_skip.xml` | Phase 5 (for P5-R02) | FAIMS with adaptive CV skipping enabled. | Same `CVValues` as `method_faims_3cv.xml`. `MaxCVSkip=2`, `CVPrecursorThreshold=15` (or the value found in the existing `ScanScheduler.cs` during Phase 6 Step 1 audit). |
| `method_exploration.xml` | Phase 7 | Parameter exploration (CE optimization) enabled. | `ParameterOptimization.Active=True`. CE range 20–40 step 5, `MaxVariantsPerPrecursor=5`, `MaxQueueForExploration=50`. |
| `method_json_roundtrip.xml` | Phase 1 | Full-featured config for JSON round-trip testing. All sections populated with non-default values. | All optional fields set to non-default values. Used by P1-U03 and P1-U05. |

**`UseUnifiedBridge` lifecycle:**
- Added to `method_default.xml` and all other config files in Phase 4 (set to `False` initially; Phase 4 golden files are captured with it set to `True`).
- Removed from all config files and from the XML schema in Phase 5 (the unified path becomes the only path).

**CV value constraint:** The `cv_values` in `method_faims_3cv.xml` and `method_faims_skip.xml` must exactly match the `cv=<value>` annotations in `ms1_faims_3cv.txt`. If the real FAIMS data uses CV values other than -40, -50, -60 (the plan's defaults), update both config files to use the actual CV values present in the data.

### 3.3 JSON reference files

These are not input configs; they are expected JSON output files used in Phase 1 unit tests.

| File | Location | Purpose |
|------|----------|---------|
| `config_default.json` | `FlashIDA/test-data/json/` | Expected `Parameter.ToJSON()` output from `method_default.xml`. Used by P1-U03 for field-by-field comparison. |
| `config_full.json` | `FlashIDA/test-data/json/` | Expected `Parameter.ToJSON()` output from `method_json_roundtrip.xml`. Used by P1-U03 and P1-U05. |

Format: standard JSON, UTF-8, 2-space indentation. These files are the authoritative reference for the actual JSON schema used in Phases 2+. The schema deviates from `baseline-plan.md` Issue 8 in two documented ways: (1) a `tagging` top-level key is present (see Issue 8 Phase 1 lesson #15), and (2) `scheduling` uses nested objects with `value_ms` rather than flat `_seconds` keys (see Issue 8 Phase 1 lesson #14).

---

## 4. Test Infrastructure Files

### 4.1 `compare_golden.py`

**Location:** `FlashIDA/test-scripts/compare_golden.py`

**Purpose:** Compares a newly generated TSV output file against a committed golden file. Exits with code 0 on success (`PASS` printed to stdout), code 1 on any mismatch.

**Usage:**

```bash
python compare_golden.py <golden_file.tsv> <actual_file.tsv>
```

**Parameters:** Two positional arguments: golden file path, actual file path. No flags required for standard comparison.

**Tolerance values:**

| Column set | Type | Tolerance |
|-----------|------|-----------|
| `charges` | string | Exact match |
| `hcd` | integer | Exact match |
| All other columns (`rt`, `mz1`, `mz2`, `qScore`, `monoMasses`, `ccos`, `csnr`, `cos`, `snr`, `cScore`, `ppm`, `precursorIntensity`, `massIntensity`) | float | Absolute: 1e-6 if |golden value| ≤ 1.0. Relative: 1e-4 if |golden value| > 1.0. |

**Failure conditions:**

- Row count differs between golden and actual.
- Any string or integer column value differs.
- Any float column value exceeds the tolerance.

**Comparison algorithm:** Iterates row by row in order. Reports all mismatches found (does not stop at the first failure). Prints each failure as `FAIL row <i> col <name>: <golden> vs <actual>`. Prints `PASS` and exits 0 only if no failures were found.

**Line ending normalization:** The script normalizes `\r\n` to `\n` before parsing, so Windows-generated TSV files and Unix-generated TSV files compare correctly.

**Introduced in:** Phase 0, Step 7. Used by all regression tests from Phase 0 onward.

---

### 4.2 `regression-runner.ps1`

**Location:** `FlashIDA/test-scripts/regression-runner.ps1`

**Purpose:** Orchestrates all `Flash.exe` invocations and calls `compare_golden.py` for each output. Used both in CI (via the `windows-tests` job) and locally by developers.

**Usage:**

```powershell
powershell FlashIDA/test-scripts/regression-runner.ps1 `
    -FlashExe FlashIDA\bin\Flash.exe `
    -TestDataDir FlashIDA\test-data `
    -OutputDir FlashIDA\test-output `
    [-captureMode]  # Write output without comparing (for golden file capture)
```

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-FlashExe` | `FlashIDA\bin\Flash.exe` | Path to `Flash.exe` |
| `-TestDataDir` | `FlashIDA\test-data` | Root of the test data directory |
| `-OutputDir` | `FlashIDA\test-output` | Directory for generated output TSV files |
| `-captureMode` | (absent) | If present, write output files without running golden comparison. Used to capture new golden files. |

**Invocation format per config:**

```powershell
& $FlashExe $ms1File $outputFile $methodFile [<$ms2File>]
```

The optional fourth argument (`$ms2File`) is included only when the config's `ms2` field is non-null.

**Config array:** The script maintains an array of config objects that grows across phases. As of Phase 8, the full list covers all 12+ mode configurations:

```powershell
$configs = @(
    @{ name="baseline_phase0";  method="method_default.xml"; ms1="ms1_smoke_test.txt"; ms2=$null; golden="baseline_phase0.tsv" },
    @{ name="p4_standard_dda";  method="method_default.xml"; ms1="ms1_standard.txt";   ms2=$null; golden="phase4_standard_dda.tsv" },
    @{ name="p4_deep_mode";     method="method_deep.xml";    ms1="ms1_standard.txt";   ms2=$null; golden="phase4_deep_mode.tsv" },
    @{ name="p4_inclusion";     method="method_inclusion.xml"; ms1="ms1_standard.txt"; ms2=$null; golden="phase4_inclusion.tsv" },
    @{ name="p4_exclusion";     method="method_exclusion.xml"; ms1="ms1_standard.txt"; ms2=$null; golden="phase4_exclusion.tsv" },
    @{ name="p4_tag_targeting"; method="method_tag_targeting.xml"; ms1="ms1_standard.txt"; ms2="ms2_hcd_fragment.txt"; golden="phase4_tag_targeting.tsv" },
    @{ name="p4_quant";         method="method_quant.xml";   ms1="ms1_standard.txt";   ms2="ms2_hcd_fragment.txt"; golden="phase4_quant.tsv" },
    @{ name="p4_ms3_mode1";     method="method_ms3_mode1.xml"; ms1="ms1_standard.txt"; ms2="ms2_hcd_fragment.txt"; golden="phase4_ms3_mode1.tsv" },
    @{ name="p4_ms3_mode2";     method="method_ms3_mode2.xml"; ms1="ms1_standard.txt"; ms2="ms2_hcd_fragment.txt"; golden="phase4_ms3_mode2.tsv" },
    @{ name="p4_ms3_mode3";     method="method_ms3_mode3.xml"; ms1="ms1_standard.txt"; ms2="ms2_hcd_fragment.txt"; golden="phase4_ms3_mode3.tsv" },
    @{ name="faims_3cv";        method="method_faims_3cv.xml";  ms1="ms1_faims_3cv.txt"; ms2=$null; golden="faims_3cv.tsv" },
    @{ name="faims_skip";       method="method_faims_skip.xml"; ms1="ms1_faims_3cv.txt"; ms2=$null; golden="faims_skip.tsv" },
    @{ name="p7_exploration";   method="method_exploration.xml"; ms1="ms1_standard.txt"; ms2=$null; golden="phase7_exploration.tsv" }
)
```

**Exit behavior:** Exits with code 1 if any `Flash.exe` invocation fails or any `compare_golden.py` comparison fails. Exits with code 0 only if all configured tests pass. Prints a failure count summary.

**Introduced in:** Phase 0, Step 7. Extended at each phase that adds new regression configurations.

---

### 4.3 `prepare-test-data.py`

**Location:** `FlashIDA/test-scripts/prepare-test-data.py`

**Purpose:** One-time conversion script. Reads source `.mzML` files and writes spectrum files in the tab-delimited format expected by `Flash.exe`. Run locally by the developer; outputs are committed to the repository.

**Usage:**

```bash
python FlashIDA/test-scripts/prepare-test-data.py <source.mzML> <output.txt> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--ms-level <N>` | `1` | Only include spectra at this MS level (1 or 2) |
| `--scan-index <N>` | (all) | Extract only the scan at index N (0-based) |
| `--max-scans <N>` | (all) | Stop after N scans have been written |
| `--include-cv` | (absent) | Append `cv=<value>` to each scan header from the spectrum's FAIMS CV metadata |

**Output format:** Writes one header line per scan followed by tab-delimited peak lines (m/z and intensity), as specified in Section 1. Retention time is written in seconds (directly from pyopenms `getRT()`, no conversion).

**Dependencies:** `pyopenms` (installable via `pip install pyopenms`). Python 3.8+.

**Core logic (reference implementation from testing-strategy.md Section 8.6):**

```python
import pyopenms as oms, sys

exp = oms.MSExperiment()
oms.MzMLFile().load(sys.argv[1], exp)
with open(sys.argv[2], 'w') as f:
    for spec in exp:
        if spec.getMSLevel() != 1:
            continue
        rt = spec.getRT()  # seconds (no conversion)
        f.write(f"Spec {spec.getNativeID()}\t{rt:.4f}\n")
        for peak in spec:
            f.write(f"{peak.getMZ():.6f}\t{peak.getIntensity():.2f}\n")
```

The production script extends this reference with the options listed above.

**Introduced in:** Phase 0, Step 4 (referenced). Run once per source file to generate the committed test data.

---

### 4.4 `test_inclusion_list.txt`

**Location:** `FlashIDA/test-data/configs/test_inclusion_list.txt`

**Purpose:** A short inclusion list used by Phase 0 AL-CT13 (inclusion list mode continuity test). Contains a small number of target masses that the continuity harness uses to verify that only listed masses produce MS2 commands.

**Format:** One target mass per line (decimal, in Da). Optionally a second column for the mass tolerance window.

**Introduced in:** Phase 0 (required by AL-CT13 test; documented retroactively — see Phase 0 compliance report recommendation I-3.)

---

### 4.5 `test_fasta.fasta`

**Location:** `FlashIDA/test-data/configs/test_fasta.fasta`

**Purpose:** A small FASTA file used in Phase 0 continuity tests and JSON config round-trip tests that exercise the `files.fasta` config field. Contains one or two representative protein sequences.

**Format:** Standard FASTA format. File size: < 5 KB.

**Introduced in:** Phase 0 (required by JSON round-trip test; documented retroactively — see Phase 0 compliance report recommendation I-3.)

---

### 4.6 `Flash.Tests.csproj`

**Location:** `FlashIDA/src/Flash.Tests/Flash.Tests.csproj`

**Purpose:** NUnit test project. Targets .NET Framework 4.8. References `Flash.csproj` and NUnit 3.

**Key properties:**

| Property | Value |
|----------|-------|
| `TargetFrameworkVersion` | `v4.8` |
| `OutputType` | `Library` |
| NUnit version | `3.13.3` (or current version used by the solution) |
| NUnit3TestAdapter version | `4.3.1` |
| NUnit.ConsoleRunner version | `3.16.3` |

**Test files compiled into this project (accumulated across phases):**

| File | Introduced | Contents |
|------|-----------|---------|
| `SmokeTests.cs` | Phase 0 | P0-U01 through P0-U04 |
| `BridgeSmokeTests.cs` | Phase 0 | P0-I01, P0-I02 |
| `Mocks/MockMsScan.cs` | Phase 0 | IMsScan test double for acquisition-loop tests |
| `Mocks/MockCustomScan.cs` | Phase 0 | IFusionCustomScan test double |
| `Mocks/MockScanFactory.cs` | Phase 0 | ScanFactory override for acquisition-loop tests |
| `Mocks/MockTrailer.cs` | Phase 0 | Scan trailer dictionary mock |
| `Mocks/ScanCommandRecord.cs` | Phase 0 | Phase-independent scan command abstraction |
| `AcquisitionLoop/ContinuityTestHarness.cs` | Phase 0 | Pipeline harness for continuity tests |
| `AcquisitionLoop/ContinuityTests.cs` | Phase 0 | AL-CT01–CT32 (NEVER deleted) |
| `JsonConfigTests.cs` | Phase 1 | P1-U01 through P1-U05 |
| `ScanCommandLayoutTests.cs` | Phase 3 | P3-U01 through P3-U04 (struct size and offset validation: ScanCommand=1144 bytes, IsolationStage=80 bytes, 22 field offsets verified). Updated per Phase 3 compliance report (2026-03-29). |
| `TrackingIdTests.cs` | Phase 3 | P3-I04 (incrementing tracking IDs) |
| `MethodParameterTests.cs` | Phase 1 | P1-U03, P1-U05 (round-trip tests) |
| `DeadCodeTests.cs` | Phase 6 | P6-U07, P6-U08 (grep for deleted class references) |
| `BridgeTests.cs` | Phase 3–4 | P3-I01 through P3-I05, P4-I01, P4-I02, P6-I01. P3-I01 strengthened with 6 additional assertions (F-3); P3-I05 tests all 3 exports via DoesNotThrow (F-4). Updated per Phase 3 compliance report (2026-03-29). |
| `StressTests.cs` | Phase 3 | P3-S01, P6-S01 |

**Build command (CI):**

```powershell
msbuild FlashIDA/src/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```

**Run command (CI):**

```powershell
# Run from FlashIDA\bin\ so native DLLs are found by .NET runtime
# NUnit runner invoked by full path from NuGet packages directory
# OPENMS_DATA_PATH must be set for all P/Invoke steps (Phase 1 lesson #5)
# --agents=1 prevents simultaneous cold-cache init; --timeout=300000 allows calculateAveragine to warm up (Phase 1 lessons #8, #9)
cd FlashIDA\bin
$env:OPENMS_DATA_PATH = "..\OpenMS\share\OpenMS"
..\src\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe Flash.Tests.dll --agents=1 --timeout=300000 --result=TestResults.xml
```

> **Phase 1 lesson #7 (NUnit agent crash diagnosis):** If the NUnit agent process crashes with an ambiguous error, add `--inprocess` temporarily to run tests in-process; the error is then printed to stdout before the crash rather than being lost. Remove `--inprocess` after the root cause is identified and fixed.

> **Phase 1 lesson #5 (OPENMS_DATA_PATH):** After any DLL rebuild, data path resolution may change. Set `OPENMS_DATA_PATH` explicitly rather than relying on implicit resolution. This is required for every CI step that invokes OpenMS P/Invoke functions, including bridge tests and regression runs.

**Introduced in:** Phase 0, Step 2.

---

### 4.7 C++ Unit Test Files (OpenMS submodule)

C++ unit tests live in the OpenMS submodule under `OpenMS/src/tests/class_tests/openms/source/` and follow the OpenMS `ClassName_test.cpp` naming convention. They are registered in `OpenMS/src/tests/class_tests/openms/executables.cmake`.

**Phase 2–3 test files:**

| File | Introduced | Contents |
|------|-----------|---------|
| `DeconvolvedSpectrum_OptimizationMetadata_test.cpp` | Phase 2 | P2-U01 through P2-U05 (OptimizationMetadata struct tests) |
| `FLASHIdaQueueTracking_test.cpp` | Phase 3 | P3-U05 through P3-U10 (base-36 encoding, tracking ID uniqueness with range guard ID < 1679616, queue behavior, timeout). Updated per Phase 3 compliance report F-6 (2026-03-29). |
| `ScanCommandLayout_test.cpp` | Phase 3 | Layout query binary (sizeof/offsetof for ScanCommand and IsolationStage). Not a unit test with assertions — outputs values consumed by C# ScanCommandLayoutTests.cs. Always exits 0. |

**CTest invocation:** Use `-R ClassName` pattern for specific tests (e.g., `ctest -R DeconvolvedSpectrum_OptimizationMetadata`), not `-R FLASH`. Test names follow the OpenMS `ClassName_test.cpp` convention.

> **Phase 2 Implementation Notes (critical for C++ test authoring):**
>
> 1. **`toSpectrum()` returns `MSSpectrum` by value:** The actual signature is `MSSpectrum toSpectrum(int to_charge, double tol = 10.0, bool retain_undeconvolved = false)`. Use the return-value pattern: `MSSpectrum out = ds.toSpectrum(1);` — not void with an out parameter.
>
> 2. **PeakGroup prerequisite for `toSpectrum()`:** `toSpectrum()` unconditionally accesses `peak_groups_[0].isPositive()`. Any test calling `toSpectrum()` must push a default `PeakGroup` into the `DeconvolvedSpectrum` first to avoid undefined behavior. This is mandatory for P2-U04, P2-U05, and any future test exercising `toSpectrum()`.
>
> 3. **`DeconvolvedSpectrum` constructor takes `scan_number`:** `explicit DeconvolvedSpectrum(int scan_number)`, not `ms_level`.
>
> 4. **`(void)var;` for MSVC `/WX` compliance:** Use `(void)var;` after `TEST_EQUAL` assertions on variables not otherwise referenced, to suppress unused-variable warnings under MSVC `/WX` (e.g., `(void)meta;` in P2-U02).

---

## 5. Directory Layout

The complete expected directory tree for `FlashIDA/test-data/` as of Phase 8 (all files present):

```
FlashIDA/test-data/
├── spectra/
│   ├── ms1_smoke_test.txt          # Phase 0: minimal MS1, 2 scans (~6,588+21 peaks, 143 KB)
│   ├── ms2_smoke_test.txt          # Phase 0: single MS2 scan for continuity tests
│   ├── ms1_standard.txt            # Phase 4: representative MS1 scans, 5+ envelopes
│   ├── ms2_hcd_fragment.txt        # Phase 4: single MS2 HCD scan, known protein
│   ├── ms1_faims_3cv.txt           # Phase 5/6: FAIMS MS1 scans, 3+ CV values
│   └── ms1_high_density.txt        # Phase 3 (optional): dense MS1 for stress tests
│
├── configs/
│   ├── method_default.xml          # Phase 0: standard DDA, regression anchor
│   ├── method_default_topn5.xml    # Phase 0: standard DDA with TopN=5 (CT08, CT12)
│   ├── method_json_roundtrip.xml   # Phase 1: all fields populated, for JSON round-trip tests
│   ├── test_inclusion_list.txt     # Phase 0: target masses for AL-CT13 inclusion list test
│   ├── test_fasta.fasta            # Phase 0: FASTA for JSON round-trip files.fasta field
│   ├── method_deep.xml             # Phase 4: deep mode (also CT12 deep-vs-standard)
│   ├── method_inclusion.xml        # Phase 4: inclusion list mode
│   ├── method_exclusion.xml        # Phase 4: exclusion list mode
│   ├── method_tag_targeting.xml    # Phase 4: tag-based targeting
│   ├── method_quant.xml            # Phase 4: isobaric quantification
│   ├── method_ms3_mode1.xml        # Phase 4: MS3 Source CID / SPS
│   ├── method_ms3_mode2.xml        # Phase 4: MS3 mode 2
│   ├── method_ms3_mode3.xml        # Phase 4: MS3 mode 3 (HCD-triggered)
│   ├── method_faims_3cv.xml        # Phase 5: FAIMS 3 CVs, no adaptive skipping
│   ├── method_faims_skip.xml       # Phase 5: FAIMS adaptive skipping enabled
│   └── method_exploration.xml      # Phase 7: CE exploration enabled
│
├── golden/
│   ├── README.md                   # Provenance, update procedure, review expectations
│   ├── baseline_phase0.tsv         # Phase 0: first golden file (smoke test, current behavior)
│   ├── continuity_standard_dda.json  # Phase 0: AL-CT06 behavioral reference (Standard DDA)
│   ├── continuity_inclusion.json     # Phase 0: AL-CT15 behavioral reference (Inclusion list)
│   ├── continuity_exclusion.json     # Phase 0: AL-CT16 behavioral reference (Exclusion list)
│   ├── continuity_tag_targeting.json # Phase 0: AL-CT19 behavioral reference (Tag targeting)
│   ├── continuity_quant.json         # Phase 0: AL-CT21 behavioral reference (Isobaric quant)
│   ├── continuity_ms3_mode1.json     # Phase 0: AL-CT24 behavioral reference (MS3 mode 1)
│   ├── continuity_ms3_mode2.json     # Phase 0: AL-CT25 behavioral reference (MS3 mode 2)
│   ├── continuity_ms3_mode3.json     # Phase 0: AL-CT26 behavioral reference (MS3 mode 3)
│   ├── continuity_faims_skip.json    # Phase 0: AL-CT28 behavioral reference (FAIMS skip)
│   ├── phase4_standard_dda.tsv     # Phase 4: standard DDA with unified bridge
│   ├── phase4_deep_mode.tsv        # Phase 4: deep mode
│   ├── phase4_inclusion.tsv        # Phase 4: inclusion list mode
│   ├── phase4_exclusion.tsv        # Phase 4: exclusion list mode
│   ├── phase4_tag_targeting.tsv    # Phase 4: tag-based targeting
│   ├── phase4_quant.tsv            # Phase 4: isobaric quant mode
│   ├── phase4_ms3_mode1.tsv        # Phase 4: MS3 mode 1
│   ├── phase4_ms3_mode2.tsv        # Phase 4: MS3 mode 2
│   ├── phase4_ms3_mode3.tsv        # Phase 4: MS3 mode 3
│   ├── faims_3cv.tsv               # Phase 5 capture: FAIMS 3-CV baseline
│   ├── faims_skip.tsv              # Phase 5 capture: FAIMS adaptive skip baseline
│   ├── phase7_exploration.tsv      # Phase 7: exploration engine enabled
│   └── continuity_exploration.json  # Phase 7: AL-CT30 behavioral reference (Exploration)
│
└── json/
    ├── config_default.json         # Phase 1: expected ToJSON() for method_default.xml
    └── config_full.json            # Phase 1: expected ToJSON() for method_json_roundtrip.xml
```

**Supporting scripts** (not under `test-data/`, but part of the test infrastructure):

```
FlashIDA/test-scripts/
├── compare_golden.py               # Phase 0: golden file comparison with numeric tolerance
├── regression-runner.ps1           # Phase 0: orchestrates Flash.exe for all configs
└── prepare-test-data.py            # Phase 0: mzML -> tab-delimited spectrum converter
```

**Test project:**

```
FlashIDA/src/Flash.Tests/
├── Flash.Tests.csproj              # NUnit project, .NET 4.8
├── packages.config                 # NUnit 3, NUnit3TestAdapter, NUnit.ConsoleRunner
├── SmokeTests.cs                   # Phase 0
├── BridgeSmokeTests.cs             # Phase 0
├── JsonConfigTests.cs              # Phase 1
├── MethodParameterTests.cs         # Phase 1
├── ScanCommandLayoutTests.cs       # Phase 3
├── TrackingIdTests.cs              # Phase 3
├── BridgeTests.cs                  # Phase 3–6
├── DeadCodeTests.cs                # Phase 6
├── StressTests.cs                  # Phase 3, 6
├── Mocks/
│   ├── MockMsScan.cs               # Phase 0: IMsScan test double
│   ├── MockCustomScan.cs           # Phase 0: IFusionCustomScan test double
│   ├── MockScanFactory.cs          # Phase 0: ScanFactory override
│   ├── MockTrailer.cs              # Phase 0: Scan trailer mock
│   └── ScanCommandRecord.cs        # Phase 0: Phase-independent scan command abstraction
└── AcquisitionLoop/
    ├── ContinuityTestHarness.cs    # Phase 0: pipeline harness
    └── ContinuityTests.cs          # Phase 0: AL-CT01–CT32 (NEVER deleted)
```

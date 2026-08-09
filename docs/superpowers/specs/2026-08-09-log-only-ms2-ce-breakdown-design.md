# Log-only MS2 collision-energy breakdown plots

**Date:** 2026-08-09
**Status:** design approved, not yet implemented
**Deliverable:** `test_data/ms2_ce_breakdown_logs.py`

## Problem

`test_data/ms2_ce_breakdown.py` produces the 27 `plots/CytC_z{ms1}_{ion}.png` figures:
for each MS2 fragment FLASHIda sent to MS3, the fragment's intensity across the MS2
collision-energy ladder, with the acquired (CE, charge) circled. It reads the
acquisition structure from the TSV logs but obtains intensities by integrating
per-charge isotope envelopes out of `CytC_MS3all_final.mzML` (668 MB) via pyOpenMS.

We want the same class of figure derived from the FLASHIda output logs alone — no
mzML, no raw file, no pyOpenMS.

## What the logs actually carry

`scan_results*.tsv` logs the **entire** deconvolved spectrum for every scan —
`IdaLogger.cpp:422-447` iterates `deconv_spectrum->size()` with no top-N cap — as four
parallel `;`-delimited columns: `deconv_masses`, `deconv_intensities`,
`deconv_min_charge`, `deconv_max_charge`. MS2 exploration variants carry
`collision_energy`, `exploration_group_id`, `variant_index`, `total_variants`, and (on
the group-completing row only) `winner_tracking_id`.

`scan_commands*.tsv` MS3 rows carry the target fragment directly: `ion_type` + `ion_index`,
`mono_mass` = `MS1;fragment`, `charge` = `MS1;fragment`, `collision_energy` = `MS2;MS3`,
`precursor_intensity` = `MS1;fragment`, `peakgroup_intensity` = `MS1;fragment`, and
`parent_tracking_id` pointing at the winning MS2 scan. The fragment's neutral
monoisotopic mass is therefore read straight from the log — no sequence arithmetic and
no `pyopenms.AASequence`, which is what `ms2_ce_breakdown.py` needed pyOpenMS for
outside of spectrum access.

### Verified against the existing figure

Reconstructing b7 (precursor 2, MS1 z13, fragment mono mass 755.381 Da) from
`scan_commands_path.tsv` + `scan_results_path.tsv` only:

| CE | 30 | 32 | 34 | 36 | 38 | 40 | 42 | 44 | **46** | 48 | 50 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| logs | 8.41e4 | 9.86e4 | 1.41e5 | 2.17e5 | — | — | — | 4.81e5 | **5.198e5** | 4.56e5 | 3.96e5 |
| `plots/CytC_z13_b7.png` | 0.82e5 | 0.97e5 | 1.34e5 | 2.07e5 | 2.5e5 | 2.9e5 | 4.37e5 | 5.0e5 | **5.2e5** | 4.7e5 | 3.95e5 |

### Anchor invariant

For all **27/27** acquired ions, the MS3 command's `peakgroup_intensity[1]` equals the
deconvolved peak-group intensity found in the ladder at the winning CE, to within
floating-point printing. The acquired point therefore provably lies on the log-derived
curve, and the script can assert it.

`precursor_intensity[1]` is a different quantity: the intensity of the single charge
state that was isolated. It is ≤ `peakgroup_intensity[1]`, with equality only when the
fragment's deconvolved charge range is a single charge (b7: z1–1, both 519800; b64:
5.718e6 of 9.462e6 across z6–8).

## Fidelity differences from the mzML version

Both are real and must be visible in the output, not papered over.

1. **All-charge, not per-charge.** `deconv_intensities` is `PeakGroup::getIntensity()`,
   summed over the fragment's whole charge envelope. Per-charge decomposition is not
   logged; only the envelope's `min`/`max` charge is. The original's one-line-per-charge
   rendering is therefore not reproducible, and the y-axis quantity changes from
   "per-charge isotope-envelope intensity" to "peak-group intensity (all charges)".
2. **Gaps where FLASH did not call the mass.** At CE 38/40/42 no deconvolved mass matches
   755.38, though the raw spectra had signal there. The log-derived plot shows what the
   *engine observed*; the mzML-derived plot shows what the *instrument recorded*. For
   judging whether FLASHIda picked a good CE, the engine's own view is the relevant one —
   it cannot select on signal it never deconvolved.

## Decisions

| Decision | Choice |
|---|---|
| Generality | Generic `--logs` / `--out` / `--label`, with defaults reproducing this experiment |
| Un-called CEs | Solid line between adjacent observed CEs, dashed across gaps, `×` under the axis |
| Charge detail | Red circle on the curve + separate marker for the acquired charge's share + env range in the annotation |
| Output location | New `plots_from_logs/` directory; the mzML reference PNGs in `plots/` are never touched |

## Approach

A standalone sibling script, `test_data/ms2_ce_breakdown_logs.py`. This matches the
folder's convention — sixteen scripts, each answering one question, each self-contained —
leaves the working mzML pipeline untouched, and depends on matplotlib alone.

Rejected:

- **`--intensity {logs,mzml}` inside `ms2_ce_breakdown.py`.** The two plots differ by
  design (all-charge axis, dashed bridges, `×` marks, share marker), so the shared
  plotting function would immediately grow a mode flag; and `compare_intensity_sources.py`
  imports eight symbols from that module, so refactoring risks the validation tool.
- **A new script importing helpers from `ms2_ce_breakdown.py`.** That module does
  `import pyopenms` at top level, so importing it reintroduces the dependency the new
  script exists to avoid.

## Data model

```python
LadderPoint  = (ce, tracking_id, variant_index, masses[], intensities[], zmin[], zmax[])
Target       = (ion, precursor_id, ms1_charge, acq_charge, win_ce,
                fmass, pkgrp_int, prec_int, ladder_key)
CurvePoint   = (ce, intensity | None, zmin | None, zmax | None)
```

`CurvePoint.intensity is None` means *FLASH reported no such mass in that variant*. This
is the single flag that drives both the dashed bridge and the `×` mark; nothing else in
the script distinguishes "absent" from "zero".

## Components

1. `resolve_logs(dir)` — globs `scan_commands*.tsv` and `scan_results*.tsv`, so both the
   instrument run's `*_path.tsv` and the CI goldens' `*.tsv.golden.tsv` resolve. Raises
   naming the glob and the directory when either is missing or ambiguous.
2. `build_ladders(results)` — groups MS2 rows by `(parent_tracking_id, exploration_group_id)`
   and returns that map plus a `winner_tracking_id → ladder_key` index.
   `ms2_ce_breakdown.py` keys on the MS1 parent alone. That is equivalent in the present
   data (one exploration group per MS1) but would silently merge two precursors' ladders
   if an MS1 ever spawned two groups, so the new script keys on both.
3. `build_targets(commands, winner_index)` — MS3 rows only, deduplicated on
   `(parent_tracking_id, ion)` keeping the first occurrence, splitting the `;`-paired
   fields into MS1 and fragment components.
4. `sample_ladder(target, ladder)` — for each variant, the deconvolved mass nearest
   `target.fmass` within tolerance; emits one `CurvePoint` per variant including gaps.
5. `plot_target(target, curve, outpath)` — the figure.
6. `check_anchor(target, curve)` — verifies `curve[win_ce].intensity == target.pkgrp_int`
   within 0.5 % relative.
7. `main()` — argparse, iterate targets, write the manifest table.

## Mass matching

`IdaLogger` applies no `setprecision` to the deconvolved-mass writes on
`results_tsv_stream_`, so they print at C++ default precision — 6 significant digits,
confirmed by the data (4, 5 and 6 significant digits observed, never 7). Absolute
rounding error therefore scales with mass: ±0.0005 Da at 755 Da, ±0.05 Da at 11 315 Da.

Fixed absolute tolerance of **0.1 Da**, nearest match wins. This covers the worst case at
the largest fragment observed (b95, 11 314.70 Da) while staying far below the ~1 Da
spacing to neighbouring species. The 27/27 anchor check confirms it selects the intended
peak.

## Plot specification

- **Title:** `{ion}  ({precursor_id}, MS1 z{ms1_charge})` over
  `fragment neutral mono mass {fmass:.2f} Da` — unchanged from the original.
- **Axes:** x = `MS2 collision energy (%)`; y = `Fragment peak-group intensity (all charges)`,
  scientific notation via `ticklabel_format(axis="y", style="sci", scilimits=(0,0))`.
- **Curve:** markers at every observed CE. Solid segment between adjacent observed CEs;
  dashed segment where one or more CEs between them were not deconvolved. A fragment
  observed at exactly one CE draws that marker and no line.
- **Gaps:** an `×` below the axis at each un-called CE, with a single `not deconvolved`
  caption. No y-value is invented for these.
- **Baseline:** the CE-0 variant (`variant_index == -1`) is a standalone diamond, never
  connected to the sweep — it is an unfragmented reference scan, not a CE-0 fragmentation
  measurement. Same treatment as the original. It is frequently absent, since the
  fragment usually does not exist without fragmentation.
- **Acquired point:** red open circle at `(win_ce, pkgrp_int)` on the curve; a triangle at
  `(win_ce, prec_int)` for the acquired charge's share. Both y-values come from the MS3
  command row, not from the sampled curve, so the circle is still drawn in the pathological
  case where the winning CE is itself a gap — the anchor check reports that as a mismatch
  rather than the plot silently losing its marker. Annotation
  `acquired\nCE {win_ce:.0f}, z{acq_charge}  (env z{zmin}–{zmax})`, offset away from the
  plot edges and the legend as the original does.
- **Legend:** `peak group (all z)` and `acquired z{acq_charge} share`.

## CLI

```
ms2_ce_breakdown_logs.py [--logs DIR] [--out DIR] [--label NAME]
                         [--ion ION ...] [--precursor ID ...]
```

Defaults, as one constant block at the top of the file:
`--logs .`, `--out plots_from_logs`, `--label CytC`. A bare run in `test_data/`
reproduces this experiment as `plots_from_logs/CytC_z13_b7.png` and friends; other log
sets pass three flags. `--ion` and `--precursor` filter the target list.

## Error handling

| Condition | Behaviour |
|---|---|
| `scan_commands*.tsv` or `scan_results*.tsv` missing or ambiguous | Error naming the glob and directory, exit 1 |
| No MS3 command rows carrying an `ion_type` | `no MS3 targets in this run`, exit 0 — a DDA run legitimately has none |
| Winning MS2 not present in `scan_results`, or its ladder empty | WARN, skip that target |
| Fragment matched at zero CEs | WARN, skip that target |
| Anchor mismatch (`peakgroup_intensity[1]` ≠ ladder value at winning CE) | WARN per target, counted in the summary, not fatal — a mismatch is itself a finding |

## Testing

Manual verification, matching the folder's conventions — these are analysis scripts, and
none of the siblings carries automated tests.

1. **Default run in `test_data/`** — 27 PNGs in `plots_from_logs/`; the b7 curve equals
   the table above; anchor check reports 27/27.
2. **Portability** — `--logs ../FlashIDA/test-data/golden/logs/exploration_ms3
   --out plots_golden_ms3 --label exploration_ms3` yields 46 targets across 25 ladders of
   6 CE variants. This data is maintained by CI, so the check stays valid.
3. **No-MS3 path** — a DDA golden log directory exits 0 with the "no MS3 targets" message.
4. **Dependency** — `pyopenms` never appears in `sys.modules` after import.
5. **Visual** — spot-compare `plots_from_logs/CytC_z13_b7.png` against
   `plots/CytC_z13_b7.png`: same shape, gaps marked at CE 38/40/42.

## Non-goals

- Reproducing per-charge curves. The data is not in the logs.
- Modifying, replacing or deprecating `ms2_ce_breakdown.py`. It remains the way to get
  per-charge, gap-free curves when the mzML is available.
- Any change to FLASHIda or OpenMS. This is analysis tooling over existing log output.

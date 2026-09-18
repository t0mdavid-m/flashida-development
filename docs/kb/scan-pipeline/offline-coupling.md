---
title: Offline coupling — how FLASHDeconv finds a commanded scan's precursor
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp, OpenMS/src/openms_gui/source/VISUAL/DIALOGS/FLASHDeconvTabWidget.cpp
last_verified: 2026-09-18
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:63     # struct ScanCommandJoin
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:110    # trackingIdOf
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:117    # massRank (locator tolerance + isotope ladder)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:135    # parse (columns by header name)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:206    # join (validation, fails closed)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandJoin.h:291    # surveyScanNumber_ (parent-chain walk)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp:468    # run(): parse + join before any deconvolution
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp:547    # peakGroupFromCommand_ (rebuild from the row)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp:584    # `located` for this MS2
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp:657    # the survey the COMMAND names
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHDeconvAlgorithm.cpp:761    # the commanded mass picks the PeakGroup
  - OpenMS/src/openms_gui/source/VISUAL/DIALOGS/FLASHDeconvTabWidget.cpp:83    # findScanCommandsFiles (run-folder convention)
  - OpenMS/src/openms_gui/source/VISUAL/DIALOGS/FLASHDeconvTabWidget.cpp:135   # writes FD:scan_commands
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp:438     # mass(): mono_mass at four decimals
  - OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp:729  # first of the twenty scan_commands_* sections
see_also:
  - scan-command.md
  - ../acquisition-loop/csharp-orchestration.md
  - ../../adr/0046-a-commanded-scan-is-located-by-its-command-not-searched-for.md
---

# Offline coupling

`scan_commands.tsv` has one consumer outside the acquisition: **FLASHDeconv**
(`-FD:scan_commands <run folder>/scan_commands.tsv`). `ida.log` has none any more —
`-FD:ida_log` was removed (ADR-0046).

## The join

```
mzML spectrum  ── meta value "scan description", first 3 chars ──►  tracking id
tracking id    ──►  its scan_commands.tsv row  (mono_mass, anchor charge, parent_tracking_id)
parent chain   ──  walked UP the rows to the ms_level 1 row ──►  the survey the command was decided from
FLASHDeconv    ──  takes ITS OWN PeakGroup nearest mono_mass in THAT survey
                   · else its own PeakGroup 1–2 isotopes away · else one rebuilt from the row
```

Three facts make this shape necessary, and each was measured on a real run before it was built:

| Fact | Number |
|---|---|
| msconvert keeps the scan description, so the **tracking id survives conversion** | 18,548 / 18,548 spectra; every MS2 equals exactly one row |
| Commands queue, so the survey before a scan is usually **not** the survey behind it | 88 % of MS2 have 1–5 newer surveys in between |
| FLASHDeconv's own deconvolution of the *right* survey already holds the commanded mass | 99.8 % of MS2 |

So the row is a **locator**, not a mass source: the reported mass, charge range and feature
linkage stay FLASHDeconv's own. Searching the *latest* survey — what FLASHDeconv did — agreed with
the commanded mass 40–46 % of the time.

## Rules that are easy to get wrong

- **One hop up is not the survey.** A follow-up MS2 (`'C'`, or the `'R'` a quantification verdict
  buys) names the MS2 that *triggered* it as its parent. `surveyScanNumber_` walks until an MS1 row.
- **The join fails closed, before any deconvolution.** Tracking ids restart in every run, so a
  foreign `scan_commands.tsv` joins **100 %** of scans by id. What tells it apart is the
  row-vs-spectrum check: MS level, and the anchor `precursor_mz` within 0.01 m/z of an isolation
  target. A duplicate id, one id on two spectra, or a file that joins *nothing* aborts too — the
  last is also what a converter that drops the scan description produces.
- **Never an error:** a spectrum with no id or no row (an uncommanded scan), a survey missing from
  the data file (an RT crop), a root MS2 with no parent. All three keep FLASHDeconv's old search.
- **MS2 only.** MS3 rows are parsed and level-checked; nothing locates an MS3 — no acquired run
  exists to show how pwiz writes a two-stage precursor list.
- **Never match by isolation-window bounds.** The instrument floors the width to a 0.1 m/z grid, so
  the acquired window is up to 0.1 narrower than the commanded one. That is what broke the old
  `ida.log` join (±0.001 on both bounds passed for ~5 % of MS2).
- **Every file the engine has ever written must parse.** Columns resolve by header name; the
  locator tolerance (0.06 Da + 10 ppm) absorbs the six-significant-digit `mono_mass` of files written
  before ADR-0046.

## What runs where

| Step | Lives in | Verified by |
|---|---|---|
| parse, join, `massRank` | `FLASHIda/ScanCommandJoin.h` — header-only, stateless | `FLASHIda_Logging_test`, twenty `scan_commands_*` sections, in CI and both containers |
| locate (pick the PeakGroup) | `FLASHDeconvAlgorithm` — inside the FLASHDeconv no-go boundary | **no CI job runs FLASHDeconv**: an acceptance run on real data |
| find the run folder | `FLASHDeconvTabWidget` — `<mzML base>_<yyyy-MM-dd-HH-mm-ss>[_n]/scan_commands.tsv`, checked for every input before anything runs | compiled by CI only (`WITH_GUI=OFF` in the containers) |

⚠️ **A batch is normally mixed**, so the wizard answers the two failure modes differently:
*several* matching run folders **refuse the batch** (picking one could couple the wrong acquisition,
which is invisible in the results); *none* is **logged and the batch proceeds**, that input simply
uncoupled. An instrument-method control was never FLASHIda-driven — no scan descriptions, no run
folder, nothing to couple — and refusing a batch for its sake is decision 4's mistake at file level.

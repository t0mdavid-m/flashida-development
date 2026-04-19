---
title: MS1 Acquisition Packet
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/
last_verified: 2026-04-19
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700   # FLASHIda::processScan entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177  # filterAndRank entry
see_also: []
---

## Overview

MS1 scans arrive at the C++ engine through `FLASHIda::processScan`
(`FLASHIda.cpp:700`), which orchestrates spectral deconvolution and delegates
precursor ranking to `PrecursorSelection::filterAndRank`
(`FLASHIda/PrecursorSelection.cpp:177`). The output is a ranked list of
precursors packed into `ScanCommand` structs and enqueued for the instrument.
Since Phase 6, all acquisition paths — standard, FAIMS, and exploration — route
through this single entry point; the C# `ScanScheduler` and `FAIMSScanProcessor`
no longer exist.

## Read Order

- `precursor-selection.md` — how the ranking pipeline in `filterAndRank` selects
  and scores precursors from deconvolved peaks.
- `targeting-modes.md` — the four `TargetingConfig::mode` values and how each
  constrains which precursors are eligible.
- `exploration.md` — CE-sweep variants and the metric used to pick the
  exploration winner after multiple injections.
- `faims-cycling.md` — per-MS1 FAIMS CV cycling state machine and how child
  MS2 scans inherit the CV value.

## Entry Points

- `FLASHIda::processScan` —
  `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700`
- `PrecursorSelection::filterAndRank` —
  `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp:177`

## Related Packets

None yet; see [index](../index.md).

---
title: Acquisition Loop Packet
applies_to: FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/DataPipe.cs,
            FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs,
            OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/Flash.cs:430      # ProcessSpectrum event handler
  - FlashIDA/src/Flash/Flash.cs:461      # steady-state drain call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:700     # processScan entry
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:1091    # getNextScanCommand entry
see_also:
  - ../scan-pipeline/README.md
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
---

## Overview

This packet covers the event-driven orchestration layer *above* the
[`../scan-pipeline/`](../scan-pipeline/README.md) plumbing: how the C# side
wires the instrument-callback loop and how the C++ engine responds per call
via two entry points. Component details (selection, FAIMS, exploration,
config loading) live in the sibling packets this orchestrates.

## Round-trip at a Glance

```
Instrument ──MsScanArrived──▶ ProcessSpectrum (Flash.cs:430)
                                    │
                                    ├──▶ DataPipe.Push ──▶ UnifiedScanProcessor.ProcessMS
                                    │                          └─▶ wrapper.ProcessScan (P/Invoke)
                                    │                                  └─▶ FLASHIda::processScan
                                    │                                      (analyze + enqueue follow-ups)
                                    │
                                    └──▶ wrapper.GetNextScanCommand (P/Invoke)
                                            └─▶ FLASHIda::getNextScanCommand
                                                    └─▶ ScanFactory.BuildFromCommand
                                                            └─▶ scanControl.SetFusionCustomScan
                                                                    └─▶ Instrument
```

Both half-paths (forward ingestion + command return) fire within a single
`ProcessSpectrum` invocation. There is no separate polling thread — the
"loop" is the chain of instrument callbacks.

## Read Order

1. [csharp-orchestration.md](csharp-orchestration.md) — C# side: startup,
   per-scan event flow, DataPipe async staging, shutdown, error patterns.
2. [engine-entry-points.md](engine-entry-points.md) — C++ side: step outlines
   for `processScan` (3 branches by `ms_level`) and `getNextScanCommand`
   (5-step decision tree).

## Out of Scope

- Plumbing details (`ScanCommand` struct, queue, bridge exports, P/Invoke) —
  see [`../scan-pipeline/`](../scan-pipeline/README.md).
- Precursor selection, FAIMS CV cycling mechanics — see
  [`../ms1-acquisition/`](../ms1-acquisition/README.md).
- Exploration variant initiation/scoring — see
  [`../exploration/`](../exploration/README.md).
- `method.json` → engine config loading — see
  [`../config-flow/`](../config-flow/README.md).
- Thermo `IFusionCustomScan` / `IMsScan` / `IFusionScans` internals — out of
  KB scope entirely.

---
title: Scan Pipeline Packet
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h, FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs, FlashIDA/src/Flash/ScanFactory.cs
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:62   # ProcessScan export
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:73   # GetNextScanCommand export
  - FlashIDA/src/Flash/Flash.cs:461                                            # C# acquisition-loop submit site
see_also:
  - ../ms1-acquisition/README.md
  - ../exploration/README.md
  - ../config-flow/README.md
  - ../acquisition-loop/README.md
---

## Overview

This packet covers the *plumbing* layer between FLASHIda's acquisition decisions and the Thermo instrument: how `ScanCommand` objects are built and queued in C++, how they cross the ABI via five `extern "C"` bridge exports, and how the C# side turns them into Thermo `IFusionCustomScan` submissions.

For the *decisions* that drive what scans to run, see the sibling packets: `../ms1-acquisition/` (precursor selection, FAIMS cycling), `../exploration/` (MS2/MS3 exploration), `../config-flow/` (`method.json` → engine `Config`).

## Pipeline at a Glance

```
C# raw spectrum → ProcessScan (bridge) → FLASHIda::processScan
  → precursor selection / exploration → queue.buildMS*() → enqueue

C# acquisition loop → GetNextScanCommand (bridge) → queue.dequeue
  → ScanCommand crosses ABI → ScanFactory.BuildFromCommand
  → IFusionCustomScan → instrument
```

## Read Order

1. [scan-command.md](scan-command.md) — the `ScanCommand` struct and its queue.
2. [bridge-functions.md](bridge-functions.md) — how `ScanCommand` crosses the ABI.
3. [csharp-consumer.md](csharp-consumer.md) — what the C# side does with it.
4. [multi-notch-wire-grammar.md](multi-notch-wire-grammar.md) — the two-axis iAPI parameter grammar
   (`;` descends an MSⁿ stage, `,` widens one into co-isolation notches), why
   `PossibleParameters` documents only the first axis, and what `MSXTargets` actually is.

## Out of Scope

- Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand` —
  see [`../acquisition-loop/engine-entry-points.md`](../acquisition-loop/engine-entry-points.md).
- C# acquisition-loop mechanics (error handling, shutdown, submission timing) —
  see [`../acquisition-loop/csharp-orchestration.md`](../acquisition-loop/csharp-orchestration.md).
- Thermo `IFusionCustomScan` submission internals — out of scope.

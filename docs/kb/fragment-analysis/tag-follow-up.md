---
title: Tag Matching & Conditional Follow-Up Scan
applies_to: OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp, FlashIDA/src/Flash/MethodParameters.cs
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:891    # tags_found declaration
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:897    # processMS2ForTagBasedTargeting call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:914    # conditional follow-up gate
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:916    # buildFollowUp call
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:900    # sibling: quantification follow-up
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:344   # buildFollowUp signature
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:140             # tagging.follow_up_scan parse
  - FlashIDA/src/Flash/MethodParameters.cs:137                                    # C# Tagging.FollowUpScan
see_also:
  - README.md
  - data-model.md
  - ms2-matching.md
  - ../config-flow/config-flow.md
  - ../ms1-acquisition/targeting-modes.md
  - ../acquisition-loop/engine-entry-points.md
---

## Overview

After a normal MS2 returns, if the precursor tag-matches the configured protein, an additional MS2 scan is enqueued with different fragmentation parameters. This is the "conditional follow-up" mode, flagged by suffix character `'C'` in the enqueued command's type.

## Trigger

Three conditions must all hold:

1. **Config: `targeting.conditional_ms2_enabled` is true.** Gate flag; without it, the branch at `FLASHIda.cpp:914` never fires.
2. **Config: `tagging.follow_up_scan` block populated** with at least `analyzer`, `activation`, `collision_energy`, and `resolution`. Parsed at `Config.cpp:140-148`.
3. **Runtime: `tags_found` is true.** Set to `true` by `PrecursorSelection::processMS2ForTagBasedTargeting(precursor_mass, ms2_activation)` at `FLASHIda.cpp:897`; requires a **FASTA target database** (`precursor_selection.fasta`) to be loaded — `processMS2ForTagBasedTargeting` returns 0 immediately when `target_protein_database_` is empty. It is NOT keyed on `characterization.protein_sequence`, which gates the separate identification path.

`Config::validate()` catches the common misconfiguration: conditional MS2 enabled without a `follow_up_scan` block throws `std::invalid_argument` at construction time (see `../config-flow/config-flow.md` Stage 9).

## Flow

Numbered sequence inside `FLASHIda::processScan`'s MS2 branch (non-exploration path):

1. MS2 returns to `processScan`; `tracking_id` is *not* an exploration variant.
2. Precursor context resolved; `deconv_.deconvolveMSn(...)` runs with the stored MS2 result.
3. `PrecursorSelection::processMS2ForTagBasedTargeting(precursor_mass, ms2_activation)` runs tag match against the configured protein. Returns `bool tags_found`.
4. *(Separately, at `FLASHIda.cpp:900-908`)* quantification follow-up check runs — see Gotchas.
5. Branch at `FLASHIda.cpp:914`:
   ```cpp
   if (config_.targeting().conditional_ms2_enabled && tags_found)
   {
     auto cond = queue_.buildFollowUp(ctx, config_.targeting().tagging_follow_up_scan, 'C');
     queue_.push(cond);
     // ...
   }
   ```
6. MS3 targeting continues downstream (`initiateNextLevel`).

## Follow-up scan shape

The enqueued scan is a standard MS2 on the same precursor isolation, using the `follow_up_scan.*` block as its scan config:

- `analyzer` — Orbitrap / IonTrap / etc.
- `activation` — HCD / CID / ETD / EThcD / etc. (new activation type, typically different from the first MS2)
- `collision_energy` — fixed CE for the follow-up
- `resolution` — Orbitrap resolution

No fragment-ion-level targeting — the follow-up fragments the whole precursor. `buildFollowUp` (`ScanCommandQueue.cpp:344`) takes the parent context, the config block, and a suffix char:

```cpp
ScanCommand buildFollowUp(const ScanCommand& ctx,
                          const ScanConfig& follow_up_config,
                          char suffix,
                          int priority = /* default */);
```

The suffix char goes into the `type` field of the emitted command; `'C'` marks this as "conditional" (from tag match) vs. `'F'` for quantification follow-up. The suffix appears in log lines (`ScanCommandQueue.cpp:367`) and downstream TSV output.

## Config keys

`method.json` (user-facing):

```json
{
  "targeting": {
    "protein_sequence": "...",
    "conditional_ms2": true
  },
  "tagging": {
    "min_tag_length": 3,
    "max_tag_length": 7,
    "max_ptm_count": 1,
    "max_flanking_mass_diff": 500.0,
    "follow_up_scan": {
      "analyzer": "Orbitrap",
      "activation": "ETD",
      "collision_energy": 0,
      "resolution": 60000
    }
  }
}
```

See `../config-flow/config-flow.md` for how these keys become the C# `MethodParameters` tree and the C++ `Config::targeting_` / `Config::tagging_` structs.

## C# side

Briefly — see `../config-flow/` for full detail:

- `MethodParameters.Tagging.FollowUpScan` — C# POCO mirror of the `follow_up_scan` JSON block (`MethodParameters.cs:137-148`).
- `MethodParameters.Tagging.ConditionalMS2` → wire key `conditional_ms2` in the C++ JSON (`MethodParameters.cs:247`).

## Gotchas

- **Silently-off on missing protein sequence.** `conditional_ms2_enabled = true` + empty `protein_sequence` means `tags_found` will never be `true`. The mode is configured but never fires. `Config::validate()` catches empty `protein_sequence` via other constraints (exploration with `FragmentCount`, or any level-≥2 `SelectionMetric` — see `../config-flow/config-flow.md` Stage 9), but there is *no direct validation* tied to `conditional_ms2_enabled`. A pathological config that enables conditional MS2 with no exploration/selection metric active will silently not fire, with no startup diagnostic.

- **Sibling: quantification follow-up.** At `FLASHIda.cpp:900-908` there is a parallel mechanism that uses the same `buildFollowUp` machinery with suffix `'F'` (gated by `quantification.enabled` and `isDifferentiallyAbundant`, independent of tags). It is a different acquisition mode and is out of scope for this packet — a future quantification packet will cover it.

- **Priority ordering.** Follow-ups land at the same queue priority tier as MS2/MS3; specific ordering depends on `buildFollowUp`'s `priority` argument. See `../acquisition-loop/engine-entry-points.md` for how `getNextScanCommand` picks from the queue (AGC and cycle-time MS1 can preempt).

# 0003. Two-stage MS3 parameter sourcing: stage[0] = best MS2 params, stage[1] = user MS3 config

Status: Accepted (2026-06-24)

## Context

An MS3 scan is two sequential fragmentations in one command: `stage[0]` isolates and
fragments the precursor (the **MS2 fragmentation**, which *produces* the target
fragment ion), then `stage[1]` isolates that fragment ion and fragments it again (the
**MS3 fragmentation**). Today `buildMS3` copies `stage[0]` from the parent MS2 scan
and fills `stage[1]` from a fixed `ms3_config` (`ScanCommandQueue.cpp:335,341-344`).
It is tempting to read "dispatch MS3 with the fragment's best MS2 parameters" as
setting the MS3 *fragmentation chemistry*.

## Decision

`stage[0]` (the MS2 fragmentation) is sourced from the target fragment's **best MS2
parameters** — the per-ion argmax-intensity collision energy / activation /
reaction-time the model recorded — replacing "copy the parent MS2." `stage[1]` (the
MS3 fragmentation) keeps the **user-configured MS3 parameters**, with the optional CE
sweep centered on them.

## Why

Optimizing `stage[0]` maximizes how much of the fragment ion is produced — and that
ion *is* the MS3 precursor — so more is strictly better; the best-MS2 parameters
never touch the MS3 fragmentation chemistry. This needs **no `ScanCommand` ABI
change**: `stage[1]` already carries `collision_energy` / `activation_type` /
`reaction_time`, so the 2048-byte contract is untouched. Recorded because the two
stage roles are easy to invert (an earlier reading of this design had them backwards).

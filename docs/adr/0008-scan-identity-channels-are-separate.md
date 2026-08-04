# 0008. A scan's handshake channel and identity channel are separate; never conflate them

Status: Accepted (2026-08-04)

## Context

A custom scan round-trips through the instrument carrying two unrelated identifiers, and the
codebase had no name for the distinction:

- **`RunningNumber` → `Trailer["Access ID"]`** — the *instrument job number*. Stamped outbound by
  `SendCustomScan` (`++currentNumber`), echoed back inbound. Used only for the custom-control
  handshake (`== "41"`) and for log correlation. **The C++ engine never reads it.**
- **`Trailer["Scan Description"]`** — carries the *tracking id* in chars 0–2 (base-94, minted by
  `ScanCommandQueue::nextTrackingId`). This is the **only** key `FLASHIda::processScan` decodes and
  resolves against `pending_scan_map_`; a scan whose tracking id the engine did not mint is
  rejected before any deconvolution (the always-on MS1 gate).

The two channels were conflated in code. `ScanFactory.BuildFromCommand` assigns the engine's
`cmd.ScanId` — an identity value — into `RunningNumber`, a handshake value. When commit `f8dce19`
replaced the hand-built handshake scan with `BuildFromCommand(engineCmd)` at both startup sites,
the outbound job number became the engine's first tracking id, which is `0`
(`tracking_id_counter_` starts at 0). The latch still tested for `41`, so on the contact-closure
startup path it never fired: `inCustom` stayed false, no scan was ever pushed to the pipeline, and
acquisition produced nothing for the entire run. The follow-up commit `4a2ebf5` ("build startup
scans directly instead of via GetNextScanCommand") restored the hand-built scan in the
`-o/--nocc` branch **only**, leaving the default path broken. `RunningNumber = 0` is additionally
a value the iAPI documents as reserved.

## Decision

- **The two channels are distinct concepts with distinct names** — *instrument job number* and
  *tracking id* (see `CONTEXT.md`, "Language — instrument control"). Neither may be used as the
  other's carrier.
- **Identity stays on `Scan Description`.** The engine's round-trip key is the tracking id, and
  only the tracking id. This is why `BuildFromCommand` copying `cmd.ScanDescription` is load-bearing
  while its assignment of `cmd.ScanId` into `RunningNumber` is not.
- **The handshake stays on the job number**, keyed on a single named constant, and **every** startup
  path must stamp it. A startup path that leaves the job number to chance is a defect by
  construction.
- **The latch requires the echo.** `inCustom` may only be set by observing the handshake scan come
  *back*, never at send time — the echo is what proves the instrument entered custom control.
  Scans arriving before that belong to the instrument's own method.

## Considered alternatives

- **Use `Access ID` as the engine's identity key** and drop the `Scan Description` encoding. Rejected:
  the job number is overwritten by `SendCustomScan` on every send, is capped in width by the vendor
  API, reserves `0`, and carries no room for the scan-type marker or the MS3 mass token that the
  description payload holds.
- **Latch at send time** rather than on the echo. Rejected: it would admit pre-custom-control scans
  from the instrument's own method into the pipeline, and would silently mask a failure to enter
  custom control at all.

## Consequences

`BuildFromCommand`'s `RunningNumber = cmd.ScanId` assignment is vestigial on the steady-state path
(`SendCustomScan` immediately overwrites it) and actively harmful on any path that bypasses
`SendCustomScan`. Startup paths must therefore stamp the handshake constant explicitly. No golden
or ABI impact: neither channel is part of the 2048-byte `ScanCommand` contract's semantics beyond
the existing `scan_description[256]` field.

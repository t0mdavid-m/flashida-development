---
last_verified: 2026-06-16
code_anchors:
  - FlashIDA/src/Flash.Tests/Mocks/ContinuityTestHarness.cs   # C# PushScanAndDrainFull (canonical driver)
  - OpenMS/src/tests/class_tests/openms/source/FLASHIda_TestHelpers.h   # C++ runInterleaved (canonical driver)
  - OpenMS/src/tests/class_tests/openms/source/FLASHIda_TestHelpers.h:224   # decodeTrailingIonKey (C++ ion decoder)
  - FlashIDA/src/Flash.Tests/FLASHIdaLogGolden_test.cs:118   # DecodeIonFromScanDescription (C# ion decoder)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp   # getNextScanCommand (pacing) + processScan MS1 gate
---

# Test-acquisition harness contract — the interleaved engine-id-echo drive

This is the **single ground-truth contract** for how the FLASHIda test suites drive the real C++ engine. There
is exactly **one** drive, implemented as faithful mirrors in two languages:

- **C#:** `ContinuityTestHarness.PushScanAndDrainFull` — used by the golden suite and (via `PushMs1`) the
  behavioral `ContinuityTests`.
- **C++:** `runInterleaved` in `FLASHIda_TestHelpers.h` — the canonical driver; `runFullAcquisition` and
  `runFullCycle` are thin wrappers over it.

If you change one implementation, change the other in lockstep and re-run the ion-decode parity test. The
`.claude/hooks/driver-sync-reminder.sh` hook reminds you when you edit either driver or ion decoder.

## Why it exists

The engine does **not** mint MS1 tracking ids — it echoes the id carried on the incoming scan's "Scan
Description" trailer. On a real instrument the engine *emits* a survey-MS1 command (with a minted id) and the
instrument echoes that id back. The always-on **MS1 gate** in `processScan` enforces this: an MS1 whose decoded
id was never emitted as a command is rejected (`[TRACK-RESOLVE] … not_found`, returns 0). So a test harness must
feed back the engine's *own* ids — it cannot fabricate them. The only way to obtain an engine id for each scan
is to **pull the command first, then feed the matching response** — i.e. interleaved driving.

## The contract: pull → classify → dispatch

**Inputs:** a sequence of MS1 scans (`nMs1` = count), one MS2 spectrum, an optional per-ion MS3 manifest
(`ion_key → [spectrum]`).
**Output:** the recorded command stream (C++ `AcqResult{ms1_cmds, ms2_cmds, ms3_cmds}`; C#
`CapturedRecords`).

Loop, once per iteration:

1. **Pull** one command via `getNextScanCommand` (1 = got a command, else stop).
2. **Classify idle vs workload.** A command is **idle** iff:
   `is_agc` **OR** empty `scan_description` **OR** (`msn_level <= 1 && ms1_fed >= nMs1)` (an MS1 re-survey after
   all `nMs1` scans have been fed). Idle → `++idle`; a workload command → `idle = 0`.
3. **Dispatch the workload by level**, always echoing `cmd.scan_description` verbatim onto the fed scan:
   - **MS1** (`<= 1`): feed `ms1_scans[ms1_fed++]`.
   - **MS2** (`== 2`): feed the MS2 spectrum.
   - **MS3** (`>= 3`): decode the trailing ion (`decodeTrailingIonKey` / `DecodeIonFromScanDescription`); look it
     up in the manifest and feed it, or **skip** if absent (never fabricate). *Legacy C++ plausibility only:*
     when no manifest is supplied, the MS2 spectrum is fed back as the MS3 scan — this shortcut is **not** part
     of the cross-language contract and is never used by the golden / real-MS3 path.
4. **Record** the command; repeat.

**Termination:** `getNextScanCommand` returns ≠ 1, **or `idle >= 3`**, or a `max_iters` safety cap. The engine's
idle cycle emits an AGC plus a priority-3 re-survey indefinitely once the real queue is empty, so three
consecutive idle ticks prove production has ceased.

## Invariants

1. **Engine-emitted ids only.** Every fed scan carries the exact `scan_description` the engine emitted. No
   fabrication, no `"ms1"`/`"scan_"+id`/sentinel, no reuse of a resolved id.
2. **Feed exactly the requested count.** ≤ `nMs1` MS1 (one per survey command, in order); one MS2 per MS2
   command; one MS3 per MS3 command, or skip.
3. **The engine paces the surveys.** The harness only pulls and responds; it never decides when an MS1/CV
   happens. (FAIMS CV cycling is therefore *observed* from `cmd.faims_cv`, not dictated by the test.)
4. **Never fabricate MS3.** Absent/empty manifest entry → skip the command (log `[MS3-SKIP]`); do not feed a
   zero/placeholder spectrum.
5. **Deterministic per fresh engine.** Same config + inputs → same recorded command sequence.
6. **Engine-side MS1 gate (production code).** `processScan` rejects an MS1 whose id was never emitted, symmetric
   with the MS2/MS3 `resolvePending` gate. Pinned by `processScan_ms1_gate_rejects_unrequested_id`.

## Ion-decode parity (drift guard)

The trailing-ion parser exists twice and **must stay byte-for-byte equivalent**:
`decodeTrailingIonKey` (C++, `FLASHIda_TestHelpers.h`) and `DecodeIonFromScanDescription` (C#,
`FLASHIdaLogGolden_test.cs`). Both take `{id}R{mass}k@{charge}{ion_type}{ion_index}`, find the **last** `@`, skip
the fragment-charge digits, require `ion_type ∈ {a,b,c,x,y,z}` and an integer `index ≥ 1`. A shared
vector-table parity test asserts identical decoding in both suites; the no-ion / malformed / `@`-inside-the-id
edge cases are covered.

## Keep in sync (checklist when editing either driver)

1. Idle predicate identical: `is_agc || empty-desc || (msn_level<=1 && ms1_fed>=nMs1)`; termination `idle >= 3`.
2. Per-level dispatch identical (MS1 by index, MS2 singleton, MS3 manifest-or-skip).
3. Both echo `cmd.scan_description` verbatim.
4. Ion decoders byte-for-byte; re-run the parity test.
5. Update this doc's `last_verified` and confirm the `code_anchors` still resolve.

## Two-suite split

C++ ctests assert **plausibility** (ranges/sets/signs, drift-stable); C# NUnit asserts **golden** exact
(captured). The drive contract is identical; only the assertions differ by suite.

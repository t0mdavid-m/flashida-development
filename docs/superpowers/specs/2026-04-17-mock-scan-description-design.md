# Mock Scan Description — Data-Layer Fix for MS1 Mock Factories

**Date:** 2026-04-17
**Branch:** `phase-11` (FlashIDA submodule)
**Scope:** `FlashIDA/src/Flash.Tests/Mocks/MockMsScan.cs` (single file)

## Problem

Commit `a6f9cd5d9d` ("Centralize timing at top of processScan") in the OpenMS submodule lifted a `desc_str.size() < 3` guard out of the MS2-only branch of `processScan()` to the top of the function. The guard now rejects every scan — including MS1 — whose trailer `"Scan Description"` is absent or shorter than 3 characters. Production MS1 scans always carry a ≥4-char description (the engine stamps `<id>S` at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:819, 1135, 1185`), so real acquisitions are unaffected. Mock MS1 scans from the C# test harness never set the trailer, so every `ContinuityTest` that pushes an MS1 mock now returns zero scan commands. 29 tests fail as a direct consequence.

The chosen remedy is a data-layer fix: update the mock factories to populate `"Scan Description"` the same way the real engine does, so test MS1 inputs look indistinguishable from production MS1 inputs at the bridge.

## Goals

- Restore the 29 failing `ContinuityTest` cases without touching production C++ or C# code.
- Keep the C++ guard at `FLASHIda.cpp:708` in place (it's the right check for production; mocks simply need to satisfy it).
- Match the production description format (`<encoded_id>S`) exactly, so mocks can't drift from real-instrument behavior.

## Non-Goals

- No C++ change. The `desc_str.size() < 3` early-return at `FLASHIda.cpp:708` stays.
- No change to production C# (`FLASHIdaWrapper`, `UnifiedScanProcessor`, `Parameter`, etc.).
- No change to method JSON configs, golden files, or bridge struct layout.
- No refactor of the tracking-alphabet helper into a shared utility class. Extract later if a second consumer appears.
- No dedicated test binary for `EncodeTrackingId`. It is a 5-line port of `ScanCommandQueue::encode`, exercised indirectly by every MS1 ContinuityTest.

## Design

### Components

1. **`TrackingAlphabet` constant** — `private const string`. Verbatim copy of the alphabet defined at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:48` (94 printable-ASCII chars, `!` through `~`, excluding space). A one-line comment above the constant names the source file and line so drift is visible.

2. **`EncodeTrackingId(int value)`** — `private static string`. Port of `ScanCommandQueue::encode(int)` at `ScanCommandQueue.cpp:58-68`. Fills a 3-char buffer with `TrackingAlphabet[value % 94]`, most-significant char first. Assumes `value ≥ 0`; does not guard test inputs.

3. **`BuildMs1Description(string scanNumber)`** — `private static string`. Returns `EncodeTrackingId(int.Parse(scanNumber)) + "S"`. The trailing `'S'` mirrors the `%sS` stamp the engine writes at `FLASHIda.cpp:819, 1135, 1185`, making test MS1 descriptions indistinguishable in format from engine-enqueued ones. `int.Parse` intentionally throws on non-numeric input (hard assertion — matches the project's "no soft guards" rule).

### Call-site changes

Four MS1 factories gain one line each — `scan._trailerAccess.Set("Scan Description", BuildMs1Description(scanNumber));` placed alongside the existing `Access ID` set:

- `WithPeaks(double rt, string scanNumber, params (double mz, double intensity)[] peaks)` — line 81
- `EmptyMS1(double rt = 1.0, string scanNumber = "1")` — line 176
- `NoiseOnlyMS1(double rt = 1.0, string scanNumber = "1")` — line 188
- `FromTsvAllScans(string filePath)` — line 215, inside the `Spec scan=...` branch right after `Access ID` is set

No call-site change required for:

- `WithFaimsPeaks` — chains `WithPeaks`, inherits the description.
- `FromTsv` — chains `FromTsvAllScans`, inherits.
- `MS2WithDescription`, `FromTsvAsMS2` — MS2 factories that already set `"Scan Description"` explicitly.

### Behavior at the bridge

With the new format, a mock MS1 pushed through `FLASHIdaWrapper.ProcessScan(...)` enters C++ `processScan()` with a 4-char description like `"!!!S"`:

1. `desc_str.size() < 3` → false. Passes the guard.
2. `id_str = desc_str.substr(0, 3)` → e.g. `"!!!"`.
3. `tracking_id = queue_.decode(id_str)` → integer (e.g. 0). Matches whatever integer the C# mock encoded.
4. `desc_str.size() >= 4 && desc_str[3] == 'A'` → false (char 3 is `'S'`). AGC gating does not fire.
5. `queue_.peekPending(tracking_id)` → returns `nullopt` because the C# side never called `queue_.push()` for this tracking ID. `enqueue_ts` stays at 0. No crash, no state corruption.
6. Control flows into the `if (ms_level == 1)` branch as intended.

## Verification

- Push to `phase-11`. Expected: the 29 currently-failing `ContinuityTest` cases pass. No new failures.
- Spot-check one behavioral-reference golden (e.g. `continuity_inclusion.json`): actual output should match the committed golden byte-for-byte — confirmed safe because the output-side `ScanDescription` comes from the C++ engine's own `encode(scan_id)` on generated MS2 commands, not from the input mock's description.
- CI-only verification; no local build needed (user constraint: never run `cmake --build` locally).

## Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| `int.Parse(scanNumber)` throws on unexpected test input | A formerly-passing test would fail loudly | Grep of test code confirms `scanNumber` is always a numeric string; `FormatException` is the correct failure mode per "no soft guards" |
| Encoded ID collides with a tracking ID the C++ engine later issues → stale `peekPending` entry → wrong `enqueue_ts` in logs | Log-only; no effect on command generation or test assertions | Accepted; IDA logs are not under test |
| C++ `tracking_alphabet_` is reordered and C# port drifts silently | Mock descriptions decode to wrong IDs on C++ side | Source-line comment on the constant; if drift becomes a concern, add a 5-line test asserting `EncodeTrackingId(0) == "!!!"` and `EncodeTrackingId(93) == "!!~"` |

## Out of Scope — For Later

If a real-instrument scan ever reaches `processScan()` with `desc.size() < 3`, this fix does not help. A durable remedy is to move the guard back inside the `else if (ms_level == 2)` branch so MS1 survey scans tolerate short/absent descriptions. That change is deferred: it requires re-threading `tracking_id` and `enqueue_ts` resolution inside each branch, and there's no evidence of production short-description MS1s today.

# Mock Scan Description — Bridge-Backed Fix for MS1 Mock Factories

**Date:** 2026-04-17
**Branches:** `flashida-v9-bridge` (OpenMS submodule), `phase-11` (FlashIDA submodule + parent)
**Scope:** New `EncodeTrackingId` / `DecodeTrackingId` bridge exports; C# P/Invoke wrappers; MS1 mock factories.

## Problem

Commit `a6f9cd5d9d` ("Centralize timing at top of processScan") in the OpenMS submodule lifted a `desc_str.size() < 3` guard out of the MS2-only branch of `processScan()` to the top of the function. The guard now rejects every scan — including MS1 — whose trailer `"Scan Description"` is absent or shorter than 3 characters. Production MS1 scans always carry a ≥4-char description (the engine stamps `<id>S` at `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:819, 1135, 1185`), so real acquisitions are unaffected. Mock MS1 scans from the C# test harness never set the trailer, so every `ContinuityTest` that pushes an MS1 mock now returns zero scan commands. 29 tests fail as a direct consequence.

The remedy is a data-layer fix at the C# mock factories, populating `"Scan Description"` with the same `<encoded_id>S` pattern the engine uses. To avoid manually porting the alphabet and encode/decode logic to C# (drift risk), the encode/decode helpers are exposed as new bridge exports from `OpenMS.dll`.

## Goals

- Restore the 29 failing `ContinuityTest` cases without touching production C++ `processScan` or production C# `FLASHIdaWrapper`/`UnifiedScanProcessor` flow.
- Keep the C++ guard at `FLASHIda.cpp:708` in place (it's the right check for production; mocks simply need to satisfy it).
- Make the tracking-ID alphabet a single source of truth in C++: add two bridge exports (`EncodeTrackingId`, `DecodeTrackingId`) so C# never replicates the alphabet or encode logic.

## Non-Goals

- No change to `processScan`, the `desc_str.size() < 3` early-return, or any existing bridge function.
- No change to method JSON configs, golden files, or the `ScanCommand` struct layout.
- No change to production C# call paths (`FLASHIdaWrapper.ProcessScan`, `UnifiedScanProcessor.ProcessMS`, etc.).
- No adoption of the new bridge helpers in production C#. They exist for test mocks today; future production use is a separate decision.

## Design

### C++ changes (OpenMS submodule, branch `flashida-v9-bridge`)

1. **Make `ScanCommandQueue::decode` static.** The header comment at `ScanCommandQueue.h:62` already documents that decode reads only `static const tracking_alphabet_`. Change the declaration in `ScanCommandQueue.h` from
   ```cpp
   int decode(const std::string& s) const;
   ```
   to
   ```cpp
   static int decode(const std::string& s);
   ```
   and drop `const` on the definition in `ScanCommandQueue.cpp:70`. Grep for `.decode(` / `->decode(` call sites — no signature changes needed for instance-style calls, since static methods are callable on instances, but scope-qualified calls are now unambiguous. `encode(int)` is already static; no change there.

2. **Add two bridge exports.** In `FLASHIdaBridgeFunctions.h`:
   ```cpp
   /// Encode an integer as a 3-char base-94 tracking ID. out_buf must be ≥ 4 bytes; writes 3 chars + NUL.
   extern "C" OPENMS_DLLAPI void EncodeTrackingId(int value, char* out_buf);

   /// Decode a 3-char base-94 tracking ID back to an integer. Returns -1 for null input or any char outside the tracking alphabet.
   extern "C" OPENMS_DLLAPI int DecodeTrackingId(const char* str);
   ```
   In `FLASHIdaBridgeFunctions.cpp`:
   ```cpp
   void EncodeTrackingId(int value, char* out_buf)
   {
     if (out_buf == nullptr) return;
     std::string s = ScanCommandQueue::encode(value);   // 3 chars
     std::memcpy(out_buf, s.c_str(), s.size() + 1);     // 3 chars + NUL
   }

   int DecodeTrackingId(const char* str)
   {
     if (str == nullptr) return -1;
     return ScanCommandQueue::decode(std::string(str));
   }
   ```

### C# changes (FlashIDA submodule, branch `phase-11`)

3. **Add two P/Invokes plus public wrappers in `FLASHIdaWrapper.cs`**, beside the existing 5 declarations (keep them grouped at the top of the class). Use Q1 option A for encode (byte buffer) and Q2 option B for decode (explicit ASCII byte array), both chosen to avoid marshaller surprises:
   ```csharp
   [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
   private static extern void EncodeTrackingId(int value, [Out] byte[] outBuf);

   [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
   private static extern int DecodeTrackingId(byte[] str);

   public static string EncodeTrackingIdStr(int value)
   {
       byte[] buf = new byte[4];                 // 3 chars + NUL
       EncodeTrackingId(value, buf);
       return Encoding.ASCII.GetString(buf, 0, 3);
   }

   public static int DecodeTrackingIdStr(string s)
   {
       byte[] buf = new byte[Encoding.ASCII.GetByteCount(s) + 1];   // trailing 0 already default-init
       Encoding.ASCII.GetBytes(s, 0, s.Length, buf, 0);
       return DecodeTrackingId(buf);
   }
   ```
   Method names end with `Str` on the public wrappers to disambiguate from the `extern` declarations within the same class.

4. **Update `MockMsScan.cs`:** add a private static helper plus call-site `Set` calls.
   ```csharp
   private static string BuildMs1Description(string scanNumber)
       => FLASHIdaWrapper.EncodeTrackingIdStr(int.Parse(scanNumber)) + "S";
   ```
   Four MS1 factories gain one line each — `scan._trailerAccess.Set("Scan Description", BuildMs1Description(scanNumber));` placed alongside the existing `Access ID` set:
   - `WithPeaks(double, string, params …)` at line 81
   - `EmptyMS1(double, string)` at line 176
   - `NoiseOnlyMS1(double, string)` at line 188
   - `FromTsvAllScans(string filePath)` at line 215, inside the `Spec scan=` branch, right after `Access ID` is set

   No change to:
   - `WithFaimsPeaks` — chains `WithPeaks`, inherits the description.
   - `FromTsv` — chains `FromTsvAllScans`, inherits.
   - `MS2WithDescription`, `FromTsvAsMS2` — already set `"Scan Description"` explicitly.

### CI changes (parent repo, branch `phase-11`)

5. **Extend `dumpbin` verification in `flashida-ci.yml`** (C++ unit-tests or windows-tests job, wherever the existing dumpbin assertion lives) to require `EncodeTrackingId` and `DecodeTrackingId` in the exported symbol list of the shipped `OpenMS.dll`. This catches mismatches between the P/Invoke declarations and the actual DLL exports at CI time.

### Ship sequence

Per the "update DLLs before push" rule in feedback memory:

1. Commit on `flashida-v9-bridge` (OpenMS submodule): decode-static refactor + 2 bridge exports. Push → triggers `build-dlls` workflow (~40 min).
2. When DLL artifact is ready: download, clean-extract to `FlashIDA/dll/`, replace `OpenMS.dll` (+any sibling DLLs the workflow ships — Qt6, OpenSwathAlgo, zlib).
3. Commit on `phase-11` (FlashIDA submodule): new DLLs + `FLASHIdaWrapper.cs` P/Invoke + public wrappers + `MockMsScan.cs` call-site changes. Push.
4. Commit on parent `phase-11`: bump both submodule pointers. Push → triggers `flashida-ci` workflow.

## Verification

- New CI run on parent `phase-11` expected to:
  1. Pass `cpp-unit-tests` job (C++ bridge changes are minimal; decode-static refactor is ABI-compatible for call sites).
  2. Pass the dumpbin symbol assertion for the 2 new exports.
  3. Flip the 29 currently-failing `ContinuityTest` cases to pass. No new failures.
- Spot-check `continuity_inclusion.json` golden: actual output should match the committed golden byte-for-byte. Safe because the output-side `ScanDescription` comes from the C++ engine's `encode(scan_id)` on generated MS2 commands, not from the mock's input description.

## Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| `decode`-static refactor breaks a caller that relied on `this->decode(…)` virtual-dispatch semantics | C++ compile or test failure | `decode` was never `virtual`; grep confirms all call sites are `queue_.decode(id_str)` or similar, which remain valid for static methods |
| P/Invoke signature mismatch with C++ export | Runtime crash or silent wrong values | New `dumpbin` CI assertion; byte-array marshalling is the least marshaller-dependent option (Q1 A + Q2 B) |
| `EncodeTrackingId`'s caller passes `out_buf` shorter than 4 bytes | Buffer overrun (undefined behavior) | C# wrapper always allocates `new byte[4]`; private; no external misuse path |
| `DecodeTrackingId` called with non-ASCII string | C# explicit ASCII byte encoding would collapse non-ASCII to `?`; C++ returns -1 for unrecognized chars | Acceptable; tests build inputs in ASCII only |
| `int.Parse(scanNumber)` throws on non-numeric mock input | A formerly-silently-wrong test would fail loudly | Grep of test code confirms `scanNumber` is always numeric; `FormatException` is the correct failure mode per "no soft guards" |
| DLL rebuild cycle (~40 min) adds latency | Slower iteration | Accepted; chosen over drift-prone C# port |
| Bridge count grows from 5 → 7 | API surface growth beyond Phase 8's target | Accepted; Phase 8 is sealed, `phase-11` already exercises post-Phase-8 bridge evolution |

## Open Items

- **Position of the public wrappers in `FLASHIdaWrapper.cs`.** Idiomatic placement is right below the existing 5 `[DllImport]` declarations. Implementation plan will confirm by reading the file.
- **`dumpbin` assertion pattern.** Implementation plan will locate the existing assertion block in `flashida-ci.yml` and extend it in-place.

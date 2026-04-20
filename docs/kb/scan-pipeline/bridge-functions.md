---
title: Bridge Functions — the C++↔C# ABI
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp, FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h:49     # CreateFLASHIda decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h:52     # DisposeFLASHIda decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h:55     # ProcessScan decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h:60     # GetNextScanCommand decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h:63     # GetNextTrackingId decl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:39           # CreateFLASHIda impl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:53           # DisposeFLASHIda impl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:62           # ProcessScan impl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:73           # GetNextScanCommand impl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp:82           # GetNextTrackingId impl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:59        # IsolationStage 80B assertion
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:107       # ScanCommand 2048B assertion
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:31                                       # C# ScanCommand mirror
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:99                                       # C# P/Invoke block
see_also:
  - scan-command.md
  - csharp-consumer.md
---

## The five exports

The entire C++↔C# surface consists of exactly five `extern "C" OPENMS_DLLAPI` functions declared in `FLASHIdaBridgeFunctions.h`:

| Name | Signature (simplified) | Returns | Effect |
| --- | --- | --- | --- |
| `CreateFLASHIda` (`:49`) | `(char* arg)` | `FLASHIda*` | Constructs the engine from a method config string. Returns opaque pointer for C# to carry; null on construction failure. |
| `DisposeFLASHIda` (`:52`) | `(FLASHIda* obj)` | `void` | `delete` the engine. Caller must null its pointer. |
| `ProcessScan` (`:55`) | `(FLASHIda* obj, double* mzs, double* ints, int length, double rt_min, int ms_level, const char* scan_description, double faims_cv)` | `int` | Ingest one raw spectrum; enqueues resulting commands. Return value is advisory (not a reliable count — treat as opaque status). |
| `GetNextScanCommand` (`:60`) | `(FLASHIda* obj, ScanCommand* output)` | `int` | `1` if `output` was filled, `0` if the queue is empty. |
| `GetNextTrackingId` (`:63`) | `(FLASHIda* obj)` | `int` | Thread-safe allocator for a new tracking ID. Rarely used by C# — internal bookkeeping. |

All five implementations are in `FLASHIdaBridgeFunctions.cpp:39-90`. They are thin wrappers — null-check arguments and dispatch to the matching method on the C++ object. **Only `CreateFLASHIda` wraps its construction in a `try/catch (std::exception&)` with a `std::cerr` log**; the other four exports have no exception handling. An exception thrown from within `DisposeFLASHIda`, `ProcessScan`, `GetNextScanCommand`, or `GetNextTrackingId` propagates across the P/Invoke boundary, which is undefined behavior — the C++ methods they dispatch to must not throw across the ABI.

## Body summaries (one-liners)

Per this packet's scope, the heavy internals of `ProcessScan` and `GetNextScanCommand` live in a future packet. For this packet:

- **`ProcessScan` → `FLASHIda::processScan` (`FLASHIda.cpp:700`).** Deconvolves the input spectrum, runs precursor selection and optional exploration, enqueues resulting commands via the queue's `build*` helpers. Body walkthrough deferred.
- **`GetNextScanCommand` → `FLASHIda::getNextScanCommand` (`FLASHIda.cpp:1091`).** Opportunistically injects an AGC or cycle-time MS1, cleans up expired pending commands, dequeues the highest-priority remaining command. Body walkthrough deferred.

## ABI sync — the byte-layout contract

This is the critical section. Breaking the contract produces **silent memory corruption**, not a compile error or a runtime exception.

**C++ side:**

- `IsolationStage` is 80 bytes. Enforced by `static_assert` at `ScanCommand.h:59`.
- `ScanCommand` is 2048 bytes. Enforced by `static_assert` at `:107`.
- A failing assertion breaks the build — you cannot ship a size mismatch from the C++ side.

**C# side (`FLASHIdaWrapper.cs:31`):**

- `[StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Ansi)]` on the `ScanCommand` mirror.
- `[MarshalAs(UnmanagedType.ByValTStr, SizeConst = N)]` on every `string` field — `SizeConst` must match the C++ `char[N]` exactly.
- `[MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)]` on `Stages[]` and `SizeConst = 692` on `Reserved[]`.
- **No runtime size assertion.** The C# compiler cannot verify the 2048-byte total. A C++/C# mismatch compiles and runs — and corrupts memory.

**Alignment padding fields:**

`pad1`, `pad2`, `pad3` exist purely to achieve natural 8-byte alignment on both sides. Do not reorder them, remove them, or move their positions. `reserved_[692]` is the tail buffer absorbing future field additions.

**Adding a new field — the ritual:**

1. Add the field to the C++ `ScanCommand` struct in the appropriate group.
2. Shrink `reserved_[692]` by the field's size — the `static_assert(sizeof == 2048)` at `:107` will fail the build if the arithmetic is wrong.
3. Rebuild `OpenMS.dll` (CI does this; see parent `CLAUDE.md`).
4. Add the mirror field to the C# `ScanCommand` struct at `FLASHIdaWrapper.cs:31` in the **same relative position** with the same byte size. Adjust `Reserved[]`'s `SizeConst` to match.
5. If the new field should drive an instrument parameter, wire it through `ScanFactory.BuildFromCommand` (see [csharp-consumer.md](csharp-consumer.md)).
6. The cross-repo DLL-export staging convention applies: new exports require two commits (guarded tests, then un-guarded). Struct-field additions don't need staging since they ride the existing export surface.

## Error contracts

- **Null-checks.** Four of the five exports take a `FLASHIda*` and null-check it (`DisposeFLASHIda`, `ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`). `CreateFLASHIda` takes a `char*` and has no null-check on it. `GetNextScanCommand` also null-checks its `ScanCommand* output` argument.
- **Null-argument return values** differ per function: `DisposeFLASHIda` no-ops; `GetNextScanCommand` returns `0` (queue-empty sentinel); `ProcessScan` and `GetNextTrackingId` return `-1`.
- **Exception handling is only in `CreateFLASHIda`.** It catches `std::exception` and returns `nullptr` after a `std::cerr` log. The other four assume their C++ methods don't throw. No structured error channel back to C#.
- `GetNextScanCommand` returning `0` is ambiguous: it means either "arguments invalid" or "queue empty". Callers must treat `0` as "nothing to do, try again later".
- `ProcessScan` return value is int but **treat it as advisory**. Do not use it as a command count.

## Gotchas

- **`CharSet = CharSet.Ansi` + `[ByValTStr]`.** Any Unicode string that reaches this boundary silently corrupts the blittable layout. Use 7-bit ASCII for all `scan_description`, `analyzer`, `activation_type`, etc.
- **DLL name hardcoded.** The C# side declares `const string dllName = "OpenMS.dll"`. The DLL must resolve at runtime — either on `PATH` or alongside `Flash.exe` (see `FlashIDA/dll/`).
- **`ProcessScan` is not thread-safe against `GetNextScanCommand` at the bridge layer.** Caller-side serialization required, OR rely on the C++ engine's internal locking (documented in the future internals packet).
- **No size assertion on the C# side.** If you change the C# struct without matching C++, you get silent corruption. Keep the `SizeConst` annotations correct and keep `Reserved` the sole free-size field.

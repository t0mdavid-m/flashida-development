# Scan Pipeline KB Packet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new `docs/kb/scan-pipeline/` packet (4 files) documenting the C++-side `ScanCommand`/queue data layer, the 5 `extern "C"` bridge exports, and the C# consumer that builds Thermo `IFusionCustomScan`s.

**Architecture:** Four markdown files in a new packet directory, following the existing pilot-packet conventions (YAML frontmatter with `applies_to`/`last_verified`/`code_anchors`/`see_also`, parent-repo-root relative paths, pointers over paste, no multi-line code blocks, 50-150 line files). A cross-packet index entry added to `docs/kb/index.md`. No code changes — documentation only.

**Tech Stack:** Markdown with YAML frontmatter. Anchors point to C++ (`OpenMS/src/openms/...`) and C# (`FlashIDA/src/Flash/...`) source.

**Spec:** `docs/superpowers/specs/2026-04-20-kb-scan-pipeline-design.md` (commit `4c2632c`).

---

## File Inventory

**Create:**
- `docs/kb/scan-pipeline/README.md` — packet landing page (~30-40 lines)
- `docs/kb/scan-pipeline/scan-command.md` — `ScanCommand` struct + queue + build helpers + tracking IDs (~100-130 lines)
- `docs/kb/scan-pipeline/bridge-functions.md` — 5 exports + ABI sync contract (~80-110 lines)
- `docs/kb/scan-pipeline/csharp-consumer.md` — P/Invoke + wrappers + `BuildFromCommand` field map + Thermo pointer (~100-130 lines)

**Modify:**
- `docs/kb/index.md` — add `Scan pipeline` entry to Packets list

**Source references** (for anchor accuracy — all verified 2026-04-20):

| Path | Verified lines |
| --- | --- |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h` | `:48` IsolationStage struct; `:59` IsolationStage size assert (80B); `:64` ScanCommand struct; `:107` ScanCommand size assert (2048B) |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` | `:64` class; `:122` `nextTrackingId()`; `:171` `tracking_alphabet_` decl; `:174` `nextTrackingIdInt_()` |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` | `:48` alphabet definition (94 printable ASCII `!`..`~`); `:60-66` encode; `:72-80` decode; `:83-91` `nextTrackingIdInt_`; `:93-96` `nextTrackingId` public |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h` | `:49` CreateFLASHIda; `:52` DisposeFLASHIda; `:55-57` ProcessScan; `:60` GetNextScanCommand; `:63` GetNextTrackingId |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp` | `:39` CreateFLASHIda; `:53` DisposeFLASHIda; `:62` ProcessScan; `:73` GetNextScanCommand; `:82` GetNextTrackingId |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | `:700` `FLASHIda::processScan`; `:1091` `FLASHIda::getNextScanCommand` |
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | `:31-87` mirror `ScanCommand` struct; `:99-116` P/Invoke block; `:179-211` wrapper methods |
| `FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs` | `:28` `wrapper.ProcessScan(...)` call (C#→C++ input direction) |
| `FlashIDA/src/Flash/Flash.cs` | `:379-380` startup MS1; `:461-463` steady-state drain loop |
| `FlashIDA/src/Flash/ScanFactory.cs` | `:57` class; `:102` `CreateFusionCustomScan`; `:153-263` `BuildFromCommand` |

---

### Task 1: Create packet directory with a README landing page

**Files:**
- Create: `docs/kb/scan-pipeline/README.md`

- [ ] **Step 1: Create the directory and README file**

Write `docs/kb/scan-pipeline/README.md` with exactly the following content:

````markdown
---
title: Scan Pipeline
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
---

# Scan Pipeline

This packet covers the *plumbing* layer between FLASHIda's acquisition decisions and the Thermo instrument: how `ScanCommand` objects are built and queued in C++, how they cross the ABI via five `extern "C"` bridge exports, and how the C# side turns them into Thermo `IFusionCustomScan` submissions.

For the *decisions* that drive what scans to run, see the sibling packets: `../ms1-acquisition/` (precursor selection, FAIMS cycling), `../exploration/` (MS2/MS3 exploration), `../config-flow/` (`method.json` → engine `Config`).

## Pipeline at a glance

```
C# raw spectrum → ProcessScan (bridge) → FLASHIda::processScan
  → precursor selection / exploration → queue.buildMS*() → enqueue

C# acquisition loop → GetNextScanCommand (bridge) → queue.dequeue
  → ScanCommand crosses ABI → ScanFactory.BuildFromCommand
  → IFusionCustomScan → instrument
```

## Read order

1. [scan-command.md](scan-command.md) — the `ScanCommand` struct and its queue.
2. [bridge-functions.md](bridge-functions.md) — how `ScanCommand` crosses the ABI.
3. [csharp-consumer.md](csharp-consumer.md) — what the C# side does with it.

## Out of scope

- Bodies of `FLASHIda::processScan` and `FLASHIda::getNextScanCommand` — a future packet.
- C# acquisition-loop mechanics (error handling, shutdown, submission timing) — a future packet.
- Thermo `IFusionCustomScan` submission internals — out of scope.
````

- [ ] **Step 2: Verify anchor lines resolve**

Run:

```bash
awk 'NR==62' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==73' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==461' FlashIDA/src/Flash/Flash.cs
```

Expected: first line contains `int ProcessScan`; second contains `int GetNextScanCommand`; third contains `if (wrapper.GetNextScanCommand(ref cmd) == 1)`.

- [ ] **Step 3: Commit**

```bash
git add docs/kb/scan-pipeline/README.md
git commit -m "docs(kb): add scan-pipeline packet README"
```

---

### Task 2: Write `scan-command.md`

**Files:**
- Create: `docs/kb/scan-pipeline/scan-command.md`

- [ ] **Step 1: Write the file**

Write `docs/kb/scan-pipeline/scan-command.md` with exactly the following content:

````markdown
---
title: ScanCommand & ScanCommandQueue
applies_to: OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
last_verified: 2026-04-20
code_anchors:
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:48    # IsolationStage struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:59    # IsolationStage size assertion (80B)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:64    # ScanCommand struct
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:107   # ScanCommand size assertion (2048B)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:64    # ScanCommandQueue class
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:73    # buildMS2
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:76    # buildMS3
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:81    # makeMS1
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:84    # makeAGC
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:88    # buildFollowUp
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:122   # nextTrackingId public
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:171   # tracking_alphabet_ decl
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:174   # nextTrackingIdInt_ private
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:48   # tracking_alphabet_ definition (94 ASCII)
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:83   # nextTrackingIdInt_ impl
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:93   # nextTrackingId public wrapper
see_also:
  - bridge-functions.md
  - csharp-consumer.md
  - ../ms1-acquisition/precursor-selection.md
  - ../exploration/variants-and-sweeps.md
---

## `ScanCommand` — one 2048-byte blittable record

`ScanCommand` (`ScanCommand.h:64`) is the unit of work that moves between the C++ engine and the C# acquisition loop. It describes a single scan to run on the instrument. The whole struct is POD and blittable — no pointers, no dynamic allocation, fixed 2048-byte footprint (`static_assert` at `:107`). The byte-layout contract with the C# mirror is owned by [bridge-functions.md](bridge-functions.md).

Field groups:

- **Identity** — `scan_id` (int32 monotonic counter), `msn_level` (1/2/3), `scan_description[256]` (carries the encoded tracking ID + suffix), `parent_scan_id[4]` (3 chars + null; MS2→MS3 lineage; empty for MS1/MS2).
- **Instrument parameters** — `analyzer[32]`, `first_mass` / `last_mass`, `orbitrap_resolution`, `agc_target`, `max_it`, `microscans`, `rf_lens`, `source_cid` / `source_cid_scaling`, `scan_rate[32]`, `data_type[32]`.
- **Isolation** — `stages[10]` (`IsolationStage` — `:48`, each 80B: 5 doubles `precursor_mz` / `isolation_width` / `collision_energy` / `reaction_time` / `reagent_max_it`, 2 int32 `reagent_agc_target` / `charge_state`, `activation_type[32]`), `num_stages` (count of valid entries).
- **Precursor scoring (diagnostic only)** — `qscore`, `mono_mass`, `charge_cos`, `charge_snr`, `iso_cos`, `snr`, `charge_score`, `ppm_error`, `precursor_intensity`, `peakgroup_intensity`. Populated by `buildMS2` from the source `PeakGroup`. These ride along for TSV logging and diagnostics; they are *not* mapped to any instrument parameter (see [csharp-consumer.md](csharp-consumer.md)).
- **Environment** — `hcd_energy`, `faims_cv`.
- **Bookkeeping** — `priority` (**0 = highest**, 3 = lowest), `is_agc` (1 if calibration scan), `enqueue_timestamp_ms` / `dequeue_timestamp_ms` (`steady_clock` ms; stamped on enqueue/dequeue, not on build), `pad1`/`pad2`/`pad3` (alignment padding — do not reorder), `reserved_[692]` (future growth buffer; shrink this to add fields without changing total size).

## `ScanCommandQueue` — priority queues + pending map

`ScanCommandQueue` (`ScanCommandQueue.h:64`) owns all `ScanCommand` objects in flight. State:

- Four priority queues (0 = highest, 3 = lowest). `dequeue()` returns the highest-priority command available.
- `pending_scan_map_` keyed by `scan_id` — scans that have been dequeued (or registered as bypass) but not yet completed on the instrument.
- `tracking_id_counter_` — monotonic int used to generate fresh IDs.
- `queue_mutex_` — guards all access; the public API is thread-safe.

## Build helpers

All four helpers return a fully-populated `ScanCommand`; the caller chooses whether to `push()` or treat it as a bypass.

- `makeMS1()` (`ScanCommandQueue.h:81`) — const, no lock. Produces the survey MS1 command from the method config.
- `makeAGC()` (`:84`) — const, no lock. Produces an AGC calibration scan; `is_agc == 1`, tracking-id suffix `'A'`.
- `buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority = 2, int parent_scan_id = 0)` (`:73`) — populates precursor-scoring fields from `pg` accessors (`getQscore`, `getMonoMass`, …); builds a single `IsolationStage` from the selected precursor m/z.
- `buildMS3(const ScanCommand& ms2_ctx, const ScanConfig& ms3_config, double frag_mz, int frag_charge, double iso_width, char ion_type = '\0', int frag_index = 0, int priority = 1)` (`:76`) — two-stage isolation: inherits the MS1 precursor stage from `ms2_ctx`, appends the MS3 fragment stage. `parent_scan_id` is copied from `ms2_ctx.scan_id` encoded into 3 chars.
- `buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix, int priority = 0)` (`:88`) — clones `ctx` with a fresh tracking ID and a `scan_description` suffix character.

## Tracking IDs — base-94 into `scan_description`

The monotonic `tracking_id_counter_` int is encoded into **3 printable ASCII characters** using a 94-character alphabet (`!` through `~`, i.e. `0x21`-`0x7E`; definition at `ScanCommandQueue.cpp:48`; encode at `:60`). The encoded ID is written into `scan_description` as `{encoded}{suffix}`:

- suffix `'A'` — AGC calibration scan
- suffix `'S'` — survey / cycle-time-forced MS1
- no suffix — normal precursor-driven scan

`parent_scan_id[4]` carries the parent MS2's 3-char encoded ID plus a null terminator; it is empty for MS1 and MS2. The exploration packet's `isExplorationVariant(tracking_id)` check (see `../exploration/`) relies on this suffix convention.

ID allocation is thread-safe: `nextTrackingId()` (`ScanCommandQueue.h:122`, impl `:93`) locks `queue_mutex_`; the private `nextTrackingIdInt_()` (`:174`, impl `:83`) is called from within already-locked build paths.

## Queue API

All public methods are thread-safe (lock `queue_mutex_`):

- `push(ScanCommand)` — enqueue into the priority-appropriate queue.
- `dequeue()` — returns `std::optional<ScanCommand>`; `std::nullopt` if all four queues empty; otherwise the highest-priority command.
- `registerPending(const ScanCommand&)` — record a bypass command (e.g. AGC) in `pending_scan_map_` without queuing.
- `resolvePending(int id)` — look up and remove a pending command by tracking ID; returns `std::optional<ScanCommand>`.
- `peekPending(int id) const` — look up without removing.

## Gotchas

- **Priority 0 is *highest***. Inverted from the common "higher number = higher priority" convention.
- **`parent_scan_id[4]` is 3 chars + null**, not 4 chars. Treat it as a C string.
- **Timestamps stamped on enqueue/dequeue**, not on build. A command sitting in the pending map between dequeue and completion has non-zero `dequeue_timestamp_ms`.
- **Precursor-scoring fields are diagnostic**. They cross the ABI for TSV logging but are ignored by `ScanFactory.BuildFromCommand`.
- **Adding a field** requires updating the C++ struct, shrinking `reserved_[692]` by the new field's size, and mirroring the change byte-for-byte on the C# side. See [bridge-functions.md](bridge-functions.md) for the ABI ritual.
````

- [ ] **Step 2: Verify anchors**

Run:

```bash
awk 'NR==48' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h
awk 'NR==64' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h
awk 'NR==107' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h
awk 'NR==64' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==73' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==76' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==81' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==84' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==88' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==122' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h
awk 'NR==48' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
awk 'NR==93' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
```

Expected: each line contains the expected declaration/definition per the anchor comment.

- [ ] **Step 3: Lint the file**

Run:

```bash
wc -l docs/kb/scan-pipeline/scan-command.md
```

Expected: between 100 and 150 lines. If over 150, trim; if under 80, the content is too thin.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/scan-pipeline/scan-command.md
git commit -m "docs(kb): add scan-command.md (struct + queue + build helpers + tracking IDs)"
```

---

### Task 3: Write `bridge-functions.md`

**Files:**
- Create: `docs/kb/scan-pipeline/bridge-functions.md`

- [ ] **Step 1: Write the file**

Write `docs/kb/scan-pipeline/bridge-functions.md` with exactly the following content:

````markdown
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

All five implementations are in `FLASHIdaBridgeFunctions.cpp:39-90`. They are thin wrappers: null-check the `FLASHIda*`, dispatch to the matching method on the C++ object, and catch any `std::exception` with a `std::cerr` log.

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

- All five implementations null-check the `FLASHIda*` argument. A null pointer returns a safe default (`0` / no-op).
- All five `try/catch (const std::exception& e)` with a `std::cerr` log. No structured error channel back to C#.
- `GetNextScanCommand` returns `0` when the queue is empty — this is the normal "nothing to do" signal, not an error.
- `ProcessScan` return value is int but **treat it as advisory**. Do not use it as a command count.

## Gotchas

- **`CharSet = CharSet.Ansi` + `[ByValTStr]`.** Any Unicode string that reaches this boundary silently corrupts the blittable layout. Use 7-bit ASCII for all `scan_description`, `analyzer`, `activation_type`, etc.
- **DLL name hardcoded.** The C# side declares `const string dllName = "OpenMS.dll"`. The DLL must resolve at runtime — either on `PATH` or alongside `Flash.exe` (see `FlashIDA/dll/`).
- **`ProcessScan` is not thread-safe against `GetNextScanCommand` at the bridge layer.** Caller-side serialization required, OR rely on the C++ engine's internal locking (documented in the future internals packet).
- **No size assertion on the C# side.** If you change the C# struct without matching C++, you get silent corruption. Keep the `SizeConst` annotations correct and keep `Reserved` the sole free-size field.
````

- [ ] **Step 2: Verify anchors**

Run:

```bash
awk 'NR==49' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h
awk 'NR==52' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h
awk 'NR==55' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h
awk 'NR==60' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h
awk 'NR==63' OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.h
awk 'NR==39' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==53' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==62' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==73' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
awk 'NR==82' OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIdaBridgeFunctions.cpp
```

Expected: each line contains the expected decl/def per the anchor comment.

- [ ] **Step 3: Lint the file**

Run:

```bash
wc -l docs/kb/scan-pipeline/bridge-functions.md
```

Expected: between 80 and 130 lines.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/scan-pipeline/bridge-functions.md
git commit -m "docs(kb): add bridge-functions.md (5 exports + ABI sync contract)"
```

---

### Task 4: Write `csharp-consumer.md`

**Files:**
- Create: `docs/kb/scan-pipeline/csharp-consumer.md`

- [ ] **Step 1: Write the file**

Write `docs/kb/scan-pipeline/csharp-consumer.md` with exactly the following content:

````markdown
---
title: C# Consumer — wrapper, loop entry, and ScanFactory mapping
applies_to: FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs, FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs, FlashIDA/src/Flash/Flash.cs, FlashIDA/src/Flash/ScanFactory.cs
last_verified: 2026-04-20
code_anchors:
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:31      # C# ScanCommand mirror struct
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:99      # P/Invoke block
  - FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:179     # wrapper methods
  - FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs:28 # wrapper.ProcessScan call site (C#→C++ input)
  - FlashIDA/src/Flash/Flash.cs:379                   # startup first MS1
  - FlashIDA/src/Flash/Flash.cs:461                   # steady-state drain loop
  - FlashIDA/src/Flash/ScanFactory.cs:57              # ScanFactory class
  - FlashIDA/src/Flash/ScanFactory.cs:102             # CreateFusionCustomScan helper
  - FlashIDA/src/Flash/ScanFactory.cs:153             # BuildFromCommand entry
  - FlashIDA/src/Flash/ScanFactory.cs:262             # BuildFromCommand terminal submit
see_also:
  - bridge-functions.md
  - scan-command.md
---

## P/Invoke layer

`FLASHIdaWrapper.cs` hosts both halves of the C# bridge:

- **Five `[DllImport]` declarations** at `FLASHIdaWrapper.cs:99-116` mirror the five `extern "C"` exports one-for-one (see [bridge-functions.md](bridge-functions.md)). The DLL name is the compile-time constant `"OpenMS.dll"`.
- **Blittable `ScanCommand` mirror struct** at `FLASHIdaWrapper.cs:31-87`. Declared twice (C++ + C#) because there is no tool that generates one from the other — the second declaration is the C# side of the byte-layout contract documented in [bridge-functions.md](bridge-functions.md). Every field is in the same order and byte size as the C++ struct.

## Wrapper methods

Thin pass-throughs at `FLASHIdaWrapper.cs:179-211`:

- `ProcessScan(double[] mzs, double[] ints, int length, double rt, int msLevel, string scanDesc, double faimsCv) → int` — marshals arrays and the scan description, calls the DllImport.
- `GetNextScanCommand(ref ScanCommand output) → int` — direct pass-through; `1` means filled, `0` means queue empty.
- `GetNextTrackingId() → int` — direct pass-through; rarely used.

## Input direction (C# → C++)

`UnifiedScanProcessor.cs:28` is the single call site that drives the input direction: on every incoming `IMsScan` from the instrument, the processor calls `wrapper.ProcessScan(mzs, ints, rt, msLevel, scanDesc ?? "", faimsCv)`. This ingests the raw spectrum into the C++ engine, which runs deconvolution/selection and enqueues resulting `ScanCommand`s.

Loop mechanics (pipeline staging, error handling, shutdown) — out of scope for this packet.

## Output direction — acquisition-loop entry

The C# drain loop has two sites, both in `Flash.cs`:

- **Startup** (`Flash.cs:379-380`): the very first MS1 is pulled via `wrapper.GetNextScanCommand(ref startupCmd2)` and submitted directly through `scanControl.SetFusionCustomScan(scanFactory.BuildFromCommand(startupCmd2))`. This kicks the instrument out of idle.
- **Steady state** (`Flash.cs:461-463`): the main loop tests `if (wrapper.GetNextScanCommand(ref cmd) == 1)` and on success calls `SendCustomScan(scanFactory.BuildFromCommand(cmd))`.

Loop mechanics (timing, backpressure, shutdown) — out of scope for this packet.

## `ScanFactory.BuildFromCommand` — the field mapping

`ScanFactory.BuildFromCommand(ScanCommand cmd) → IFusionCustomScan` at `ScanFactory.cs:153-263` is the second translation layer. It allocates a `ScanParameters`, copies relevant `ScanCommand` fields into its properties (conditionally, so zero/empty values use the method default), and terminates at `CreateFusionCustomScan(p, cmd.ScanId, delay: 0.0, IsAGC: (cmd.IsAgc != 0), AGCgroup: 1)` (`:262`).

The `ScanParameters` → Thermo custom-scan mapping elsewhere in `ScanFactory.cs` is reflection-driven (see the utility at `:130-145` that writes `ScanParameters` fields into a `scan.Values` dictionary). This is the *second* ABI contract — not a C++↔C# one, but a C#-internal name-match between `ScanCommand` property names and `ScanParameters` property names. A rename on either side fails silently.

**Field-by-field mapping** (source: `ScanCommand.cs` field → `ScanParameters` property → note):

| ScanCommand field | ScanParameters property | Note |
| --- | --- | --- |
| `Analyzer` | `Analyzer` | Set only if non-empty. |
| `FirstMass` | `FirstMass` (as `double[]` single-element) | Also sets `ScanRangeMode = "DefineFirstMass"` or `"DefineMZRange"` depending on whether `LastMass` is set. |
| `LastMass` | `LastMass` (as `double[]` single-element) | Combined with `FirstMass` triggers `ScanRangeMode = "DefineMZRange"`. |
| `OrbitrapResolution` | `OrbitrapResolution` | Set only if `> 0`. |
| `AgcTarget` | `AGCTarget` | Set only if `> 0`. |
| `MaxIt` | `MaxIT` | Set only if `> 0`. |
| `MsnLevel` | `ScanType` | `"MSn"` if `> 1`, `"Full"` otherwise. No direct field copy — derived. |
| `Stages[i].PrecursorMz` | `PrecursorMass[]` | Per-stage arrays; entries with `> 0` appended. Valid stages: `Stages[0..Min(NumStages, 10)-1]`. |
| `Stages[i].IsolationWidth` | `IsolationWidth[]` | Append if `> 0`. |
| `Stages[i].CollisionEnergy` | `CollisionEnergy[]` (rounded to `int`) | Append if `>= 0`. |
| `Stages[i].ActivationType` | `ActivationType[]` | Append if non-empty. |
| `Stages[i].ChargeState` | `ChargeStates[]` | Append if `> 0`; clamped to `Min(25)`. |
| `Stages[i].ReactionTime` | `ReactionTime[]` | Append if `> 0`. |
| `Stages[i].ReagentMaxIt` | `ReagentMaxIT[]` | Append if `> 0`. |
| `Stages[i].ReagentAgcTarget` | `ReagentAGCTarget[]` | Append if `> 0`. |
| `ScanDescription` | `ScanDescription` | Set only if non-empty. **Carries the encoded tracking ID + suffix — critical for round-trip identification of the returning scan. Do not strip.** |
| `FaimsCv` | `FAIMS_CV` | Set if `|value| > 0.001`; also sets `FAIMS_Voltages = "on"`. |
| `Microscans` | `Microscans` | Set only if `> 0`. |
| `RfLens` | `SrcRFLens` (as `double[]` single-element) | Set only if `> 0`. |
| `SourceCid` | `SourceCIDEnergy` | Set only if `> 0`. |
| `SourceCidScaling` | `SourceCIDScalingFactor` | Set only if `> 0`. |
| `DataType` | `DataType` | Set only if non-empty. |
| `ScanRate` | `ScanRate` | Set only if non-empty. |
| `ScanId` | `ICustomScan.RunningNumber` (via `CreateFusionCustomScan`) | Passed as `id` to the terminal helper — this is how the instrument returns the ID on scan completion. |
| `IsAgc` | `CreateFusionCustomScan(..., IsAGC: ...)` | Non-zero → true; controls the Thermo AGC code path. |

**Diagnostic-only fields** — cross the ABI but are NOT mapped to any `ScanParameters` property: `Qscore`, `MonoMass`, `ChargeCos`, `ChargeSnr`, `IsoCos`, `Snr`, `ChargeScore`, `PpmError`, `PrecursorIntensity`, `PeakgroupIntensity`. These ride along for TSV logging / diagnostics. `HcdEnergy` is unused on the C# side (collision energy is driven per-stage through `Stages[].CollisionEnergy`).

**Bookkeeping fields** not in the mapping: `Priority`, `NumStages` (used to bound the stage loop, not copied), `EnqueueTimestampMs` / `DequeueTimestampMs` (diagnostic), `ParentScanId` (not currently mapped to instrument — reserved for future lineage work).

## Thermo submission

`BuildFromCommand` returns an `IFusionCustomScan` via `CreateFusionCustomScan` (`ScanFactory.cs:102`). Submission is via the Thermo instrument API at `Flash.cs:380` (`scanControl.SetFusionCustomScan(...)`) or the equivalent `SendCustomScan` helper at `:463`. Thermo API internals — out of scope.

## Gotchas

- **Reflection / name-match is silent on failure.** Renaming a C++ `ScanCommand` field requires renaming the C# mirror (byte-layout contract) *and* checking the `BuildFromCommand` mapping *and* verifying `ScanParameters` has a property with the same name (for reflection-driven emission elsewhere in `ScanFactory`).
- **`ScanDescription`'s tracking-id suffix is the scan identity**. It returns with the scan result and drives exploration variant detection (`isExplorationVariant`) and other round-trip logic. Don't strip it or transform it before submission.
- **Precursor-scoring fields are diagnostic**. They cross the ABI but are not mapped to any instrument parameter.
- **Conditional writes default to method.** Zero / empty `ScanCommand` fields leave `ScanParameters` unset, letting the Thermo method config provide the default. This is intentional — do not "helpfully" force values to zero for "clean" output.
````

- [ ] **Step 2: Verify anchors**

Run:

```bash
awk 'NR==31' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
awk 'NR==99' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
awk 'NR==179' FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs
awk 'NR==28' FlashIDA/src/Flash/IDA/UnifiedScanProcessor.cs
awk 'NR==379' FlashIDA/src/Flash/Flash.cs
awk 'NR==461' FlashIDA/src/Flash/Flash.cs
awk 'NR==57' FlashIDA/src/Flash/ScanFactory.cs
awk 'NR==102' FlashIDA/src/Flash/ScanFactory.cs
awk 'NR==153' FlashIDA/src/Flash/ScanFactory.cs
awk 'NR==262' FlashIDA/src/Flash/ScanFactory.cs
```

Expected: each line matches its anchor comment.

- [ ] **Step 3: Lint the file**

Run:

```bash
wc -l docs/kb/scan-pipeline/csharp-consumer.md
```

Expected: between 100 and 150 lines.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/scan-pipeline/csharp-consumer.md
git commit -m "docs(kb): add csharp-consumer.md (P/Invoke + BuildFromCommand mapping)"
```

---

### Task 5: Update `docs/kb/index.md` to list the new packet

**Files:**
- Modify: `docs/kb/index.md`

- [ ] **Step 1: Read the current file**

Run:

```bash
cat docs/kb/index.md
```

Expected: file lists three packets (MS1 acquisition, Config flow, Exploration) under `## Packets`.

- [ ] **Step 2: Apply the edit**

Edit `docs/kb/index.md`: in the `## Packets` list, append the following bullet **after** the Exploration entry:

```markdown
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.
```

The final `## Packets` list should read:

```markdown
## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
- [Exploration](exploration/README.md) — MS2 and MS3 exploration: variants, scoring, winner selection.
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.
```

- [ ] **Step 3: Verify the edit**

Run:

```bash
grep -c "scan-pipeline/README.md" docs/kb/index.md
```

Expected: `1`.

- [ ] **Step 4: Commit**

```bash
git add docs/kb/index.md
git commit -m "docs(kb): list scan-pipeline packet in index"
```

---

### Task 6: Final verification — all anchors resolve, all cross-links work

**Files:**
- (read-only verification pass; may modify files if bugs found)

- [ ] **Step 1: Verify every anchor in every new file resolves to a non-blank line**

Write a shell one-liner script in the session that extracts every `- Path:N` code_anchor entry from the four new files and verifies each line exists and is non-blank:

```bash
for f in docs/kb/scan-pipeline/README.md docs/kb/scan-pipeline/scan-command.md docs/kb/scan-pipeline/bridge-functions.md docs/kb/scan-pipeline/csharp-consumer.md; do
  echo "=== $f ==="
  grep -oE '[A-Za-z0-9_/.-]+\.(cpp|h|cs):[0-9]+' "$f" | sort -u | while read anchor; do
    path="${anchor%:*}"
    line="${anchor##*:}"
    content=$(awk "NR==$line" "$path" 2>/dev/null)
    if [ -z "$content" ]; then
      echo "STALE: $anchor"
    fi
  done
done
```

Expected: no `STALE` lines. If any stale anchors are found, read the surrounding code, correct the anchor, commit the fix.

- [ ] **Step 2: Verify cross-packet links resolve**

Run:

```bash
grep -oE '\(\.\./[a-z-]+/[A-Za-z.-]+\)' docs/kb/scan-pipeline/*.md | sort -u
```

Expected: every referenced file exists. Test each with `ls docs/kb/<target>`.

- [ ] **Step 3: Verify line counts fall within targets**

Run:

```bash
wc -l docs/kb/scan-pipeline/*.md
```

Expected:
- `README.md`: 30-60 lines
- `scan-command.md`: 100-150 lines
- `bridge-functions.md`: 80-130 lines
- `csharp-consumer.md`: 100-150 lines

If any file is substantially over, review for over-explanation; if under, the content is too thin.

- [ ] **Step 4: Sanity-check packet readability**

Read each file top-to-bottom in order (`README.md` → `scan-command.md` → `bridge-functions.md` → `csharp-consumer.md`). Confirm:
- No duplicated content between files (cross-links instead).
- Forward references (e.g. `see [bridge-functions.md](bridge-functions.md)`) all point somewhere.
- Frontmatter is valid YAML.
- Every `Gotchas` bullet is actionable — reader can do something with it.

- [ ] **Step 5: If any issues found, fix and commit**

```bash
git add docs/kb/scan-pipeline/
git commit -m "docs(kb): fix scan-pipeline anchor/link corrections"
```

If no issues: no commit needed for this step.

---

## Verification (end-to-end)

After all tasks complete, verify from the user's perspective:

1. **Packet is discoverable from the index.**

   ```bash
   grep "scan-pipeline" docs/kb/index.md
   ```

   Expected: one line pointing to `scan-pipeline/README.md`.

2. **Read path works.** Open `docs/kb/scan-pipeline/README.md` → follow the "Read order" list → verify each file opens, each cross-link resolves.

3. **ABI contract is actionable.** Read `bridge-functions.md`'s "Adding a new field — the ritual" section. An engineer who has never touched the bridge should be able to follow it.

4. **Field mapping is complete.** Read `csharp-consumer.md`'s mapping table. Cross-check against `ScanFactory.cs:153-263` — every conditional write in the code should have a row in the table; every row should correspond to code.

5. **No stale anchors.**

   ```bash
   for f in docs/kb/scan-pipeline/*.md; do
     grep -oE '[A-Za-z0-9_/.-]+\.(cpp|h|cs):[0-9]+' "$f" | sort -u | while read a; do
       p="${a%:*}"; l="${a##*:}"
       [ -z "$(awk "NR==$l" "$p" 2>/dev/null)" ] && echo "STALE: $a"
     done
   done
   ```

   Expected: no `STALE` output.

---

## Spec coverage check

| Spec section | Task |
| --- | --- |
| Packet layout — 4 files | Tasks 1, 2, 3, 4 (one file each) |
| README content detail | Task 1 |
| `scan-command.md` content detail | Task 2 |
| `bridge-functions.md` content detail | Task 3 |
| `csharp-consumer.md` content detail (including BuildFromCommand mapping) | Task 4 |
| `docs/kb/index.md` update | Task 5 |
| Success criterion: every `code_anchor` verified | Task 6 (step 1) |
| Success criterion: no duplication across packets (cross-link) | Task 6 (step 4) |
| Success criterion: 50-150 line cap per file | Task 6 (step 3); also enforced in each file's own lint step |
| Non-goal: `processScan` / `getNextScanCommand` bodies deferred | Bodies appear only as one-line summaries with forward pointer — enforced by content specs in Tasks 2, 3 |
| Non-goal: C# loop mechanics deferred | Loop-entry section in `csharp-consumer.md` restricts to the call sites only — enforced by Task 4 content spec |
| Non-goal: Thermo submission deferred | "Thermo submission" section is a closing pointer only — enforced by Task 4 content spec |

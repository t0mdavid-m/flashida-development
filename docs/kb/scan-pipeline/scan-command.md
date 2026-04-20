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

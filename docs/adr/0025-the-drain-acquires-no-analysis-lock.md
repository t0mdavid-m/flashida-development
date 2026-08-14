# 0025. The command drain acquires no analysis lock, and the queue holds no framework handle

Status: Accepted (2026-08-14).

Supersedes the two reverted attempts at ADR-0024 (`acf9c8b`/`24f2a82`, `a9f3d6d`+`fb99618`/`dc07deb`),
which addressed the same stall from the C# side. Those were reverted for reasons unrelated to the
diagnosis — one had technical defects, the other was never tested on the instrument — so this ADR
does not inherit a verdict on host-side arming, which remains open and is discussed under
*Not decided here*.

## Context

`Flash.cs ProcessSpectrum` pushes an arriving scan into the pipeline and then, on the very next
line, synchronously asks the engine for the next command. That drain took `analysis_mutex_` — the
mutex `processScan` holds function-scoped across an entire MS1 deconvolution — at all three of its
emitting paths (`FLASHIda.cpp` Step 1, Step 4, Step 5).

Two of the three guarded nothing at all: their block bodies were a single
`logger_.writeScanCommandRow(out)`, and no other thread writes that stream. The third guarded
exactly one `unordered_map::find`.

So the instrument event thread could park for the length of a deconvolution **in order to write one
TSV line and read one hash-map entry**. This was new since the port to the C++ `ScanCommandQueue`;
pre-port the drain was a lock-free `ConcurrentQueue` pop that never entered the engine.

The stall was found while investigating intermittent AGC-prescan injection-time spikes. **It does
not explain that symptom** and this ADR does not claim it does.

## Decision

**1. `getNextScanCommand` acquires no `FLASHIda` lock.** `analysis_mutex_` now has exactly one
acquisition site, `processScan`. Anything the drain needs takes a leaf lock instead.

**2. `precursor_id_by_tracking_` gets its own leaf mutex, taken inside its accessors.** The map is
unreachable outside them, so a raw subscript is a compile error.

**3. `IdaLogger` owns a mutex PER STREAM, not one shared lock.** The two threads write disjoint
streams. A single logger mutex would put the drain's `writeScanCommandRow` behind `processScan`'s
`writeScanResultRow`/`writeIdentificationRow` — each ending in a synchronous flush — and behind
`writeIDALogEntry`, which walks every peak group of an MS1. That is the same stall through a
different mutex, and the drain-blocking test **cannot see it**, because that test is scoped by mutex
identity.

**4. The pipeline queues an owned `ScanData` snapshot, not the `IMsScan` handle.** Taken in
`DataPipe.Push`, on the arrival thread, while the handle is still live.

**5. Nothing is ever dropped.** The queue stays unbounded. Bounding it was considered and rejected:
under the shipped method every production MS2 is an exploration variant, and a dropped variant
wedges its group for the rest of the run — `Exploration::active_groups_.erase` is reachable only past
the `all_received` gate, with no timeout — while its pending-map entry leaks, `resolvePending` being
the only eraser and reachable only from `processScan`.

Lock hierarchy after: `analysis_mutex_ → { queue_mutex_, precursor_map_mutex_, the five stream
mutexes }`, all leaves, all taken inside call-free critical sections. The drain acquires none of the
first, so a two-lock cycle has no second participant on that side.

## Why decision 4 was necessary rather than tidy

An `IMsScan` is a window onto framework-owned memory the iAPI releases as soon as the next scan
replaces it as the container's `LastScan`. The consumer read `Centroids`/`Header`/`Trailer` through
the queued handle at *dequeue* time, so a scan still waiting in the queue at that moment was a handle
to memory that may already be gone — lost silently and corruptly, with nothing thrown on the producer
side.

It never bit because the queue was ~1 deep, **and it was ~1 deep by accident**: the blocking drain
coupled the instrument's scan rate to the processing rate. Removing the stall is precisely what makes
a deep queue reachable. Decisions 1–3 and decision 4 are therefore one change, not two.

## Two properties that are argued, not tested

Recorded so neither is rediscovered as a defect.

**The container race is fixed by the language rules and demonstrated by no test.** Making a rehash
land inside a concurrent `find` deterministically would require a custom `Hash` or `Allocator` on the
production member — instrumenting shipped code to satisfy a test — and no tool substitutes: MSVC
offers only `/fsanitize=address`, which is not a race detector, and enabling it invalidates the ccache
and poisons the `openms-fresh-dll` artifact. A statistical version detects at ≲1% per run and its
likeliest signature is an untriageable crash. Regression protection is structural instead: decision 2
makes an unlocked access fail to compile.

Note the lock is for the **container**, not the value. Value visibility needs no lock: each map write
is immediately followed by `queue_.push()` releasing `queue_mutex_`, and the drain's `dequeue()`
acquires the same mutex — a happens-before edge. Only an *editor* can invert that ordering, which is
why `stampAndPush_` exists rather than a test.

**Lock ordering has no positive test.** Release compiles asserts out and there is no lock-hierarchy
checker. The order is written down at all four declarations, and the leaf critical sections must stay
call-free.

**One unsynchronised read survives.** `faims_.isEnabled()` on the drain path is safe only because
`FAIMS::enabled_` is assigned once in the constructor. That is now named in the code rather than
implied. A "disable FAIMS mid-run" feature would make it a real race.

## Ruled out

**Moving the map into `ScanCommandQueue`.** Two independent reasons. Its `push(cmd, pid = 0)` overload
would widen a 19-call-site method whose default argument turns a loud omission into a silent wrong
value forever. And a queue callback consulting the map would invert the lock hierarchy *and* destroy
the happens-before edge the value-visibility argument above rests on.

**Carving `precursor_id` into the `ScanCommand` ABI.** Five files in lockstep for a value that never
leaves the engine, plus an indeterminate-field hazard: `ScanCommand cmd;` is default-initialised at
four sites, so a field with no initialiser would log an arbitrary integer into a golden-pinned column
with asserts compiled out.

**Bounding the pipeline.** See decision 5.

## Not decided here

**Host-side arming** — deciding the next command off the instrument event thread. Not rejected on
merit and not settled by the ADR-0024 reverts. It addresses a different half of the problem and should
be decided on the instrument. This change makes it *safer*: an arming fill can no longer park inside
`GetNextScanCommand` holding a dequeued command.

**Step 5's ungated MS1 injection.** Step 2's cycle-time survey is gated on `!exploration_active_`;
Step 5's priority-3 survey is not. Not worsened here — `dequeue()` precedes the lock, so Step-5
frequency was never influenced by it — but gating it moves goldens across ~22 modes.

**The size of the stall on real hardware.** Unmeasured. The user approved this work without the
measurement gate. Justification therefore rests on the two vacuous acquisitions and the false comment,
not on a measured latency win. To measure it: in `scan_results.tsv`, `[received_ts, resolve_ts]` is
when `processScan` held the mutex and `dequeue_ts` is stamped before the drain's old lock, so any row
whose `dequeue_ts` falls inside another's window was a drain call that blocked.
**Do not use `instrument_duration_ms`** — `received_ts` is stamped after the lock, so that column
*contains* the stall and reports zero when it is largest.

## Evidence

Delivered as tests-first, with each production change justified by a run that failed without it.

| Run | State |
|---|---|
| `31800485093` | **P1, tests only.** `drain_completes_while_analysis_mutex_held` red on **all three** paths (`completed_while_held=0` each) — one pass would have pinned a third of the change. `DataPipe_QueuedScan_SurvivesSourceHandleInvalidation` red. |
| `31805450835` | **P2a, lock split, logger locks deliberately withheld.** Drain test green; `concurrent_drain_writes_one_wellformed_row_per_call` red at `calls=1000 rows=1000 wellformed=17 unique_ids=156`. **17 intact rows out of 1000** — this is why decision 3 is per-stream. |
| `31810586366` | **P2b, per-stream locks.** All 24 ctests green. |
| `31816452487` | **P3, snapshot.** Fully green. 20 log-golden modes and 14 regression TSVs byte-identical. |

The P2a run could not have been produced any other way: the concurrency test cannot fail before the
coarse lock is removed, so splitting the fix across two pushes is what turned decision 3 from an
argument into an observation.

**`ContinuityTests.CT32` is not coverage and must not be cited as such.** Its scans feed
`"thread{t}_scan{i}"`, which decodes to a tracking id that misses the pending map, so every one
returns at the admission gate before deconvolution, before any map insert and before any push; and
its config has no `runtime` section, so all five logger streams are closed and every writer
early-returns. It passed unchanged through a state that tore 983 of 1000 log rows. The CI step that
advertised it (`Run stress tests`, a lone `Write-Host`) is deleted.

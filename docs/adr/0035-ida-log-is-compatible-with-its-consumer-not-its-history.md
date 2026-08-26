# 0035. `ida.log` is compatible with its consumer, not with its history

Status: Accepted (2026-08-26)

## Context

`ida.log` was written by the C# host until the engine took it over. The pre-port writer is still
readable at FlashIDA `main` (`e93dbc9`, "2023Apr27 version"): `IDAScanProcessor.cs:83-87` for the
header and `PrecursorTarget.cs`'s `ToString()` for the target lines.

A forensic diff of that writer against `august_pre` found **22 grammar slots**, of which nine are
unchanged and eleven are cosmetic or actively better now. **Two do real damage**, and both arrived
as side effects of the port rather than as decisions:

- **`MS1 Scan#` became the tracking id.** `FLASHDeconvAlgorithm` keys `precursor_map_for_ida_` on
  that field (`:469`) and matches it against `getScanNumber(map, index)`, the Thermo native-id scan
  number. The result is not a mis-keyed join but a **structurally unsatisfiable** one:
  `findPrecursorPeakGroupsFormIdaLog_` walks down from `lower_bound(scan_number)` and returns at
  `iter->first < scan_number - 50` (`:539-549`). Tracking ids count 1, 2, 3…; instrument scan
  numbers run into the thousands. Past roughly the fiftieth scan the map's *greatest* key already
  sits below the cutoff, so the function returns before attempting a single isolation-window match.
  FLASHIda coupling produced no wrong answers — it produced **none**, silently. (The
  `std::out_of_range` from `scan_rt_map.at()` that aborted a real E. coli run is downstream of this;
  fixing it lives outside FLASHIda and is not part of this decision.)

- **`Mass=` lost its precision.** It is written `std::defaultfloat` with no precision of its own, so
  it inherits the header's `setprecision(4)`. The first target of every entry therefore renders at
  four *significant* digits — the committed goldens literally contain `Mass=1.235e+04` where the
  same entry's `AllMass=` says `12351.3933`, an error of 1.393 Da / 113 ppm. The code shape proves
  accident: sticky stream state, present in the writer's first version and untouched by all ten
  revisions since. It also corrupts an in-FLASHIda path — an engine-written `ida.log` fed back
  through `targeting.target_log_files` is parsed by `PrecursorSelection.cpp:58-133`, which records
  `target_mass_rt_map_[12350]` and bins the nominal mass a full Dalton off.

A third slot, `ChargeRange`, was flattened from the measured envelope to the trigger charge printed
twice, and is restored here because the value is already reachable.

The obvious framing — "restore `main`" — is wrong, and that is the substance of this ADR. Several of
`main`'s behaviours were worse, and restoring them would import defects.

## Decision

**`ida.log` is made compatible with what its consumers read, not byte-compatible with what the C#
host used to write.** Concretely:

1. **`MS1 Scan#` carries the instrument's scan number.** It crosses the bridge as a trailing `int`
   on `ProcessScan`. The export count stays **5** — a signature change is not a count change — and
   nothing enters the 2048-byte `ScanCommand`.
2. **The parameter is APPENDED to the export, never inserted.** On x64 Windows arguments 5 and
   beyond are passed on the stack, so a stale 8-parameter `OpenMS.dll` ignores argument 9 and
   degrades to tracking-id logging. Inserting it ahead of `faims_cv` would instead make that DLL
   read an `int` as a `double` and command the wrong FAIMS CV on every scan.
3. **`faims_cv` loses its default on the C++ member**, so all 24 existing call sites break at
   compile time. A defaulted trailing parameter would let every one of them keep compiling while
   passing 0, collapsing every log entry onto one map key with nothing to notice it.
4. **`instrument_scan_number <= 0` means "not supplied", and the log falls back to the tracking id**
   — with one warning per run, not one per scan. The field never carries a fabricated scan number,
   and an offline or synthetically-driven run produces exactly the log it produced before.
5. **`Mass=` is pinned at `std::fixed << setprecision(4)`**, matching `AllMass=` byte for byte.
6. **`ChargeRange` carries `PeakGroup::getAbsChargeRange()`**, read off the `DeconvolvedSpectrum`
   `writeIDALogEntry` already receives — no ABI change, and the same call the file already makes
   twice for `scan_results.tsv`.
7. **The same instrument scan number is also written to `scan_results.tsv`**, on every MS level.
   `ida.log` has MS1 entries only, so this is what makes an MS2, MS3 or exploration-variant row
   joinable to the mzML.
8. **Every change is confined to FLASHIda.** `FLASHDeconvAlgorithm`, `FLASHDeconvFeatureFile`,
   `TOPPBase` and the GUI are untouched, which is possible precisely because this fixes the
   *producer* to emit what the consumer already expects.

## Considered alternatives

**Key the consumer on RT instead** (`ida.log` records a unique, strictly increasing RT per MS1).
Rejected: it requires rewriting `findPrecursorPeakGroupsFormIdaLog_`, which is outside FLASHIda.
Fixing the producer needs no consumer change at all.

**Encode the scan number in the existing `scan_description` string**, avoiding any ABI change.
Rejected: it conflates the identity channel ADR-0008 exists to keep separate, and would have the
engine parse a number out of a string it currently reads four characters of.

**Restore `main`'s grammar byte for byte.** Rejected, and each slot for its own reason:

| Slot | `main` | Why current stays |
|---|---|---|
| `RT` | `{1:f04}` on `Header["StartTime"]` | The specifier was **inert** — `Header` is `IDictionary<string,string>` and `String` is not `IFormattable`, so `main` emitted raw instrument text under `CurrentCulture`. A comma-decimal machine wrote `0,1387`, which `atof` truncates to 0 — and mode 3 discards `prt == 0` entries. The current `fixed(4)` in the C locale is strictly safer. |
| `Access ID` | instrument job number | The current value is the **tracking id**, the join key to the other four streams. Restoring `main`'s would cost that join for no consumer gain: no reader searches for `Access ID`. |
| `Features=[…]` | six `f06`, `CurrentCulture` | Same locale hazard — comma decimals would hand the comma-walking parser twelve tokens where it reads six. C++ streams are C-locale and structurally immune. |
| `HCD=` | absent | Added deliberately in the C# era (`0343c9a`, 2025-10-10). Removing it changes the non-numeric **skeleton**, compared exactly before any tolerance — 1324 hard failures for a field `parseFLASHIdaLog` already ignores for free. |
| `AllMass=` precision | G15 | `fixed(4)` is 0.008 ppm at 12 kDa, deterministic in width, and is what `Mass=` now matches byte for byte. |
| empty `AllMass=` | line omitted | Restoring the omission deletes lines, which fails the whole-file line-count check on all 25 goldens, for no consumer benefit. |
| targets count, duplicate target lines | species count, one line each | A writer-side change with int-exact golden movement across seven modes plus a line-count change. The actual damage is in the **reader**'s `"0 targets"` substring test, which is fixed instead. |
| `Score` | charge-parameterised | `main` used `QScore::getQScore(&pg, charge)`; that class is deleted, and equivalence of `getAllQscores()[charge]` to it is unverifiable from this tree. |

**Chase byte-identity behind a config flag** (`ida_log_format: current|legacy`). Rejected for now: it
institutionalises two grammars for one stream permanently, and it cannot be validated — **no archived
`main`-era `IDALog_*.log` exists anywhere**: not on FlashIDA's 20 refs, not on OpenMS's 36, not in any
commit that ever added a file, not on the development filesystem. Revisit only if an instrument-PC
archive turns up.

## Consequences

**A third identity channel exists.** ADR-0008 named two — the *instrument job number* and the
*tracking id* — and said a scan carries "two independent identity channels". It now carries three.
The new one is categorically unlike the other two: FLASHIda neither mints it nor requests it (it
exists only on the returning scan), and it is the **only** one that survives into the converted data
file, which is exactly what makes it the right join key. `CONTEXT.md` is extended accordingly; ADR-0008's
decisions are unaffected, since neither of its channels may still carry the other's value.

**`ScanData` carries seven values, not six.** `DataPipe.cs`'s remark and the parent `CLAUDE.md` both
said six; both are corrected. The read is `int.TryParse`, deliberately unlike the two `int.Parse` /
`double.Parse` calls beside it: a throw inside `ScanData.From` routes to `onFailure`, which ends the
run, and a logging-only value must not be able to do that.

**`FlashIDA/dll/OpenMS.dll` is knowingly left stale.** It was already stale against the August
`ScanCommand` changes, and CI overwrites it before the C# build, so the pipeline cannot observe the
skew either way. Consequence 2 above is what makes that safe for the deployed binary. Refreshing it
is a separate decision.

**`BridgePhase3Tests` had already drifted** — a second, independent `[DllImport]` of `ProcessScan`
declaring seven parameters against the native eight, missing `faims_cv`. It is corrected here. The
CI "Verify bridge smoke tests" gate does not cover it: that gate filters on the `BridgeSmokeTests`
classname, which P/Invokes only `CreateFLASHIda` and `DisposeFLASHIda`.

**The goldens cannot see the `Mass=` defect, and that is why it survived.** `NormalizeIdaLog` masks
`Scan# \d+` and the Access ID outright, so decisions 1 and 4 move no golden at all. `Mass=` is
compared through `GoldenNumericComparer` at `RelTol 1e-3`, which at 12 kDa is a tolerance of
**±12.35 Da** — the 1.393 Da error passes with nine times the headroom, and the skeleton regex
swallows `1.235e+04` and `12351.3933` identically. CI was green before the fix, is green after it,
and would be green if it regressed. A dedicated assertion that every first target round-trips to one
of its own entry's `AllMass` values is therefore the only gate on decision 5, and it is required, not
optional.

**What CI here still cannot prove.** `FLASHDeconv` appears zero times in `flashida-ci.yml` and
`findPrecursorPeakGroupsFormIdaLog_` runs nowhere in this pipeline, so "the coupling now works"
remains a claim about a function no gate in this repo executes. Settling it needs
`FLASHDeconv -in <mzML> -FD:ida_log <log>` run outside this repo. Report it as unverified; do not let
a green badge stand in for it.

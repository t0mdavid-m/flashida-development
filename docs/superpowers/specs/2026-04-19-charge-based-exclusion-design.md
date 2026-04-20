# Charge-Based Exclusion for MS1 Precursor Selection — Design

**Date:** 2026-04-19
**Owner:** Tom David Mueller
**Status:** Draft (awaiting user review)

## Problem

`PrecursorSelection::filterAndRank` picks one charge per peak group per scan:
the representative charge's qscore (default) or the best-charge qscore when
`consider_all_charges=true`. Within-run dynamic exclusion
(`mass_qscore_map_` → `tqscore_exceeding_mass_rt_map_` /
`tqscore_exceeding_mz_rt_map_`, populated in `PrecursorSelection.cpp:596-616`)
is keyed by **nominal mass only**. Once a mass's tracked qscore crosses
`tqscore_threshold` the entire mass is excluded from future scans, regardless
of how many of its charge states have been fragmented.

For exhaustive charge-state coverage we want the engine to keep acquiring the
*other* charges of the same mass across MS1 scans until every observed charge
has been acquired, then exclude the mass as a whole.

## Design

A new **developer-only** boolean flag gates a candidate-expansion change inside
`filterAndRank`. Default off → byte-for-byte identical behavior to today.

- JSON key: `developer.precursor_selection.charge_based_exclusion`
- C# property: `DeveloperConfig.PrecursorSelection.ChargeBasedExclusion`
  (marked `[Developer]`)
- C++ field: `TargetingConfig::charge_based_exclusion` (bool, default `false`)

### When the flag is ON

**Design principle:** change the existing precursor-picking code as little
as possible. Every modification is a small, clearly-gated drop-in — either
a `if (config_.targeting().charge_based_exclusion)` block added at a
specific site, or a one-line guard that disables an existing skip. No
refactor into helpers; no new control flow; no reshape of the phase loop.
The outer `for (const auto& pg : deconv_.deconvolvedMS1())` at
`PrecursorSelection.cpp:395` stays.

There are **four drop-ins**, all inside `filterAndRank`. Behavior outside
the flag is byte-for-byte unchanged.

#### Drop-in A — Per-peak-group charge expansion (line ~395–429)

Today the outer loop processes each peak group once and picks one charge
via the `if/else if/... else` ladder at `:404-429`. Under the flag we want
to run the existing per-candidate filter/commit block **once per observed
charge** of the peak group.

Minimal-diff shape: wrap the existing per-candidate body in a one-level
inner `for (int charge : charges_to_process)`. When the flag is off,
`charges_to_process` is a single-element vector computed from the existing
ladder (byte-equivalent to today). When the flag is on, it is the set of
charges in `pg.getAbsChargeRange()` that are actually scored — i.e.
`pg.getAllQscores()` keys intersected with the closed `[min, max]` range —
sorted by per-charge qscore descending.

Score / HCD per charge, under the flag, mirror the branches already at
`:404-429`:

- `use_idscore && hcd_energy < 0` → `score = pg.getBestIDScoreForCharge(c)`;
  `hcd = pg.getBestHCDForCharge(c)`
- `use_idscore && hcd_energy >= 0` →
  `score = pg.getIDScoreForChargeAndHCD(c, hcd_energy)`; `hcd = hcd_energy`
- `!use_idscore` → `score = pg.getAllQscores().at(c)`; `hcd = hcd_energy`

Under the flag `consider_all_charges` has no effect on which charges are
emitted (we emit all of them) — only on the HCD-selection arm above.

Everything inside the per-candidate body (`:432-655`) is unchanged, just
indented one extra level and parameterised on the inner `charge` variable
instead of the scalar from the ladder.

**Sort scope:** per-peak-group, qscore-descending within the inner list.
The outer peak-group order is whatever `filterPeakGroupsUsingMassExclusion_`
already produced. This keeps the diff local (no cross-peak-group flat list,
no rebuild of `stable_sort`/priority-tie logic on a flat list). Practical
consequence: all charges of the top-ranked peak group are evaluated before
the next peak group. This was the trade-off you asked for: minimal change
over strictly global qscore order.

#### Drop-in B — Per-(mass, charge) cross-scan exclusion skip

Add a new `std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_`
member on `PrecursorSelection`. Immediately after the existing
same-m/z-avoidance block (`:574-581`) and before the phase-gated tqscore
check (`:584-591`), insert:

```cpp
if (config_.targeting().charge_based_exclusion
    && tqscore_exceeding_mass_charge_set_.count({nominal_mass, charge}) > 0)
{
  continue;
}
```

This is the only **new** skip added to the filter chain. It is a pure
drop-in: no existing line changes.

#### Drop-in C — One-line bypass of the `mass_qscore_map_` max-tracking skip

The existing skip at `:604-607`

```cpp
if (score < mass_qscore_map_[nominal_mass]) {
  continue;
}
```

would otherwise block any lower-qscore charge of a mass that has already
been acquired with a higher-qscore charge, defeating exhaustive acquisition.
Gate it:

```cpp
if (!config_.targeting().charge_based_exclusion
    && score < mass_qscore_map_[nominal_mass]) {
  continue;
}
```

This is a single-condition edit to one `if`. It is the one deliberate
semantic change to existing logic; nothing else in the `mass_qscore_map_`
handling is touched (the map still updates as today, per §Commit below).

#### Drop-in D — Per-(mass, charge) exclusion set insertion

Inside the existing `tqscore_threshold` trigger block (`:612-616`
non-idscore branch and `:625-629` idscore branch) — i.e. the lines that
already write `tqscore_exceeding_mass_rt_map_[nominal_mass]` — append
one line under the flag:

```cpp
if (config_.targeting().charge_based_exclusion) {
  tqscore_exceeding_mass_charge_set_.insert({nominal_mass, charge});
}
```

This reuses the **existing** mass-level threshold-crossing condition
verbatim — no separate per-charge accumulator, no second threshold. The
interpretation is: "when the mass-keyed tqscore criterion for this mass
crosses the threshold while we were acquiring charge `c`, mark `(mass, c)`
as done." Because under the flag we keep acquiring multiple charges per
mass, this insertion fires once per charge that we saw cross the
threshold boundary while selected.

This is the minimally invasive choice: no new accumulator, no parallel
idscore product map. It accepts that the per-charge "done" semantics
inherit from the mass-keyed accumulator's definition of "done."

#### What is explicitly NOT added

- **No mass-level "done" promotion.** We do not track "have all observed
  charges been acquired" and we do not write into
  `tqscore_exceeding_mass_rt_map_` on that basis. The existing
  threshold-crossing condition (mass-keyed accumulator > threshold) is the
  only writer into those maps, unchanged.
- **No new per-charge accumulator map.** We do not introduce
  `mass_charge_qscore_map_`. Per-charge state is a single `std::set`.
- **No flat global sort across peak groups.** Candidates remain grouped
  by peak group; charges are sorted within each group.
- **No changes to phase logic, mode-2 outer loop, SNR handling, target
  matching, isolation-window handling, or any output vector.**

#### Commit path & map updates (unchanged)

The commit block (`:641-:655`) runs exactly as today for every candidate,
including repeated invocations for different charges of the same peak
group. `mass_qscore_map_` updates (`:596-630`) also run unchanged — drop-in
D just piggybacks on the already-existing threshold-crossing branch to
record the per-charge entry.

**Consequence worth flagging:** `selected_peak_groups_[i]` and
`selected_peak_groups_[j]` (i ≠ j) may now reference the same `PeakGroup`
instance within one scan. Consumers that assume uniqueness must
disambiguate via `trigger_charges_[i]`. Review the MS2 command builders
(`FLASHIdaBridgeFunctions.cpp`) and `removeFromExclusionList` callers to
confirm no such assumption exists; file a follow-up only if found.

#### Knobs and surface area

| Knob | Effect under flag |
|---|---|
| `qscore_threshold` | Unchanged — still gates the inner loop via `break` at `:569`. |
| `snr_threshold` | Unchanged — per-charge SNR still filters. |
| `tqscore_threshold` | Unchanged — same threshold gates both the mass-keyed write (existing) and the new per-(mass, charge) set insert (drop-in D). |
| `consider_all_charges` | Only affects the HCD-selection branch inside drop-in A; does not affect which charges are expanded. |
| `use_idscore` | Picks the IDScore getter inside drop-in A; does not change the per-charge set mechanics. |
| `tie_threshold` | Unchanged — applied as today at `:277-282` on peak groups. |
| `mass_count` | Unchanged — same hard budget across all selections in a scan. |

No new config knob beyond `charge_based_exclusion` itself.

### When the flag is OFF

Every code path above short-circuits on `if (!charge_based_exclusion)` → fall
through to the existing loop and filters. No expansion, no per-(mass, charge)
set, no behavior change.

### Interaction with other modes

- **Mode 1 (inclusion)** — target-matched candidates already waive
  `qscore_threshold` and `snr_threshold`. The per-(mass, charge) exclusion
  set applies equally to them: a TSV target's specific charge that has
  already been acquired with qscore > threshold will not be re-acquired.
  Non-strict inclusion's phase-1 non-target backfill works unchanged because
  the flag changes candidate generation, not phase logic.
- **Mode 2 (exclusion)** — the mode-2 outer iteration loop at line 378 runs
  twice as today. The per-(mass, charge) set is consulted on both iterations;
  the second iteration (exclusions lifted) ignores
  `tqscore_exceeding_mass_rt_map_` but still skips entries in the new
  per-charge set. Rationale: if we already acquired this exact charge, the
  exclusion-lifting pass shouldn't re-acquire it — the lift applies to mass
  selection, not to charge-level replay.
- **Mode 3 (deep)** — same story as mode 2: the loaded `excluded_masses_`
  still suppresses mass-level acquisition; the per-charge set is an
  independent cross-scan gate.

## Config Flow Changes

Following `docs/kb/config-flow/adding-a-config-field.md`:

1. **`FlashIDA/src/Flash/MethodConfig.cs`** —
   add to `DeveloperConfig.PrecursorSelection`:
   ```csharp
   [Developer]
   [JsonKey("charge_based_exclusion")]
   [Description("Track exclusion per (mass, charge) instead of per mass so all observed charges of a mass can be acquired before the mass is excluded.")]
   public bool ChargeBasedExclusion { get; set; }
   ```
   Mirror in `JsonPrecursorSelectionConfig` (near line 412):
   ```csharp
   public bool charge_based_exclusion { get; set; }
   ```

2. **`FlashIDA/src/Flash/MethodParameters.cs`** — inside the
   `precursor_selection = new JsonPrecursorSelectionConfig { ... }` block at
   line 126, add:
   ```csharp
   charge_based_exclusion = c.PrecursorSelection.ChargeBasedExclusion,
   ```

3. **`OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h`** —
   inside `TargetingConfig` (at line 143), add:
   ```cpp
   bool charge_based_exclusion = false;
   ```

4. **JSON parsing** — the existing `Config::from_json` or equivalent
   populator already handles bool developer keys; confirm the new key is
   consumed without additional plumbing.

5. **`FlashIDA/src/Flash/etc/method.json`** — under `developer.precursor_selection`,
   add `"charge_based_exclusion": false` to make the key visible in the
   default config.

## Code Changes (C++)

Scope: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h`
and the corresponding `.cpp`. No header API changes — the one added member
is private.

**New member on `PrecursorSelection`:**
```cpp
// Per-(nominal_mass, charge) cross-scan exclusion set. Populated by
// drop-in D when the mass-keyed tqscore criterion trips while acquiring
// a given charge. Consulted by drop-in B to skip re-acquisition of the
// same (mass, charge) on later scans.
std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_;
```

No other members added. No new accumulator map. No new struct.

**Edits in `filterAndRank`:**

A. **Drop-in A — inner charge loop around the existing per-candidate
   body (`:400-655`).** Wrap the existing body in
   `for (int charge : charges_to_process)`. Compute `charges_to_process`
   once just inside the outer `for (pg : ...)` loop:
   - flag off → single-element vector containing the charge picked by the
     existing `:404-429` ladder (score/hcd also precomputed as today).
   - flag on → all charges in `pg.getAbsChargeRange()` that appear in
     `pg.getAllQscores()`, sorted by per-charge qscore descending, with
     per-charge score and hcd derived by the branch rules in §Drop-in A
     above.

   Everything inside the inner loop is the current per-candidate body with
   the `charge` / `score` / `hcd` variables taken from the inner iterator
   instead of from the scalar ladder.

B. **Drop-in B — new skip between `:581` and `:584`.** The two-line
   gated `continue` shown in §Drop-in B above. Pure addition.

C. **Drop-in C — gate existing `:604-607` skip.** Change the existing
   `if (score < mass_qscore_map_[nominal_mass])` to also require
   `!config_.targeting().charge_based_exclusion`. One condition added to
   one `if`.

D. **Drop-in D — one-line append inside existing `:612-616` and
   `:625-629` trigger blocks.** The gated `insert({nominal_mass, charge})`
   shown in §Drop-in D above. Added twice (once per idscore branch) so the
   per-charge set mirrors whichever mass-keyed threshold-crossing condition
   actually fired.

That is the full set of code edits in the picking loop. All other lines
in `filterAndRank` are untouched.

## Testing

### C++ (new `FLASHIdaPrecursorSelection_test.cpp` or extend existing)

1. **Flag off — behavior unchanged.** Seed a `DeconvolvedSpectrum` with one
   peak group (charges 5/6/7, representative 6). Assert `selected_peak_groups_.size() == 1`
   and `trigger_charges_[0] == 6`.

2. **Flag on — expanded candidates.** Same input. Assert all three charges
   appear in `trigger_charges_` in descending `trigger_scores_` order.

3. **Per-charge cross-scan exclusion.** Scan 1: seed scores that push
   `(mass, 6)` above `tqscore_threshold`. Scan 2: same peak group, same
   scores. Assert `trigger_charges_` on scan 2 excludes 6 but still contains
   5 and 7.

4. **Mass-level exclusion still mass-keyed.** Run scans until the
   mass-keyed tqscore criterion trips. Assert
   `tqscore_exceeding_mass_rt_map_[nominal_mass]` is set by the existing
   (unchanged) write — i.e. by the same mass-keyed condition that fires
   when the flag is off. Assert the per-charge set
   `tqscore_exceeding_mass_charge_set_` also contains the entry for the
   charge acquired on the trigger scan.

5. **Interaction with mode 2 two-pass loop.** With mode 2 enabled and the
   flag on, assert the exclusion-lifting pass still respects the per-charge
   set (i.e. does not replay an already-acquired charge).

6. **Drop-in C bypass.** With the flag on, seed a first scan that acquires
   `(mass, 6)` with qscore 0.9 (below `tqscore_threshold`). On a second
   scan, introduce `(mass, 5)` with qscore 0.7. Assert charge 5 is
   acquired — i.e. the max-tracking skip at `:604-607` does NOT block it.
   With the flag off, the same sequence must skip charge 5 (regression
   guard).

### C# (Flash.Tests)

1. **JSON roundtrip.** Extend `method_json_roundtrip.json` fixture (or add
   a dedicated fixture) with `charge_based_exclusion: true`, parse via
   `MethodConfigSerializer`, re-serialize via `MethodParameters.ToCppJson`,
   assert the key survives with the correct value.

2. **Default false.** Parse a method without the key; assert
   `ChargeBasedExclusion == false`.

## Risks & Gotchas

- **Candidate-count inflation.** A peak group with N observed charges now
  runs the filter/commit body N times. Per-scan CPU scales linearly; the
  existing `mass_count` budget still caps total selections, so end-to-end
  time is bounded. Acceptable for a developer flag.
- **Per-peak-group sort scope.** Candidates are qscore-sorted **within**
  each peak group, not globally across peak groups. This was a deliberate
  minimal-diff choice. If a later experiment shows a real coverage gap,
  a global flat sort can be added as a follow-up (with more invasive
  changes).
- **Log-file semantics unchanged.** `all_mass_rt_map_` / `mass_qscore_map_`
  writes at `:594, :601, :608, :621` still key on nominal mass. The new
  per-charge set is in-memory only; no log-file format change. Log-file
  resumption is a follow-up if needed.
- **Repeated `PeakGroup*` in outputs.** Under the flag, multiple entries
  in `selected_peak_groups_` can reference the same peak group.
  `removeFromExclusionList` and the MS2 command builders index by
  selection slot, not peak group identity, so current consumers should be
  fine — but confirm during implementation.
- **Drop-in D inherits the mass-keyed trigger.** Because we insert into
  the per-charge set exactly when the mass-keyed tqscore condition fires,
  the "done" semantics per charge match the mass-level one. If a
  finer-grained per-charge threshold is later wanted, it becomes a new
  accumulator (out of scope here).

## Out of Scope

- Persisting the per-charge exclusion state to log files for run resumption.
- Changing the `consider_all_charges` default or removing it — the new flag
  subsumes its selection semantics but both stay independent.
- A "configured charge range sweep" mode (Q5 option C) that would trigger
  MS2 on charges never observed.

## Open Questions

None at design time. Ready for implementation planning after user review.

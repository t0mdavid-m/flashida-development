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

**1. Candidate expansion.** Before entering the existing per-candidate loop
(`PrecursorSelection.cpp:395`), build a flat candidate list
`(peak_group_ptr, charge, qscore, hcd)` by iterating every peak group in
`deconv_.deconvolvedMS1()` and every charge in that peak group's
`getAbsChargeRange()` (inclusive). Use `pg.getQscore(charge)` (or the
IDScore-for-charge getter when `use_idscore=true`) to populate each
candidate's qscore, and `pg.getMzRange(charge)` for isolation windows. Sort
the flat list by qscore descending.

The main loop iterates this flat list instead of peak groups. Same-scan
bookkeeping (`current_selected_mzs`, `current_selected_masses`) is unchanged
— different charges of the same mass have different m/z and therefore do not
collide on `current_selected_mzs`, so multiple charges of one mass are
naturally permitted within a single scan.

**2. Per-(mass, charge) cross-scan exclusion.** Add
`std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_` to
`PrecursorSelection`. In the per-candidate filter block, when the flag is on,
skip the candidate if `(nominal_mass, charge)` is in this set. This check
replaces the default-mode mass-based `mass_qscore_map_` max-tracking skip at
line 605 (which would otherwise block any lower-qscore charge of the same
mass). The mass-based `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_`
consult at line 586-590 is also bypassed — those maps cover the "mass is
done" case, which we now express as "every observed charge of this mass is
in the per-charge exclusion set".

**3. Mass-level "done" gate.** After a selection is committed
(`PrecursorSelection.cpp:641-655`), if the selection's score exceeds
`tqscore_threshold`, insert `(nominal_mass, charge)` into
`tqscore_exceeding_mass_charge_set_`. Then check whether every charge in
the peak group's original `getAbsChargeRange()` now has an entry in the set
for this `nominal_mass`. If yes, also write `nominal_mass`/`integer_mz` into
`tqscore_exceeding_mass_rt_map_` / `tqscore_exceeding_mz_rt_map_`, matching
the existing mass-level exclusion semantics. This preserves the
"mass is globally excluded" state downstream consumers already rely on.

**4. `mass_qscore_map_` keying unchanged.** The map stays mass-keyed; its
update rules are preserved. Under the flag, its role is weakened — it no
longer drives candidate skipping — but it continues to update for logging
and downstream consumers (e.g. `removeFromExclusionList`).

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
and the corresponding `.cpp`.

- Add member: `std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_;`
- In `filterAndRank` before line 381, when
  `config_.targeting().charge_based_exclusion == true`, build the flat
  candidate list and iterate it instead of peak groups. Extract the current
  per-candidate filter body into a shared lambda/helper so both iteration
  styles reuse it (the helper takes `(pg, charge, score, hcd)` as inputs).
- Add the per-charge skip before line 574 when the flag is on.
- In the commit block (`641-655`) when the flag is on, insert into the set
  and promote to mass-level exclusion when the observed charge set is fully
  covered.

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

4. **Mass promotion.** Run scans until every charge in the observed range
   crosses `tqscore_threshold`. Assert
   `tqscore_exceeding_mass_rt_map_[nominal_mass]` is set and subsequent
   scans reject the mass entirely.

5. **Interaction with mode 2 two-pass loop.** With mode 2 enabled and the
   flag on, assert the exclusion-lifting pass still respects the per-charge
   set (i.e. does not replay an already-acquired charge).

### C# (Flash.Tests)

1. **JSON roundtrip.** Extend `method_json_roundtrip.json` fixture (or add
   a dedicated fixture) with `charge_based_exclusion: true`, parse via
   `MethodConfigSerializer`, re-serialize via `MethodParameters.ToCppJson`,
   assert the key survives with the correct value.

2. **Default false.** Parse a method without the key; assert
   `ChargeBasedExclusion == false`.

## Risks & Gotchas

- **Candidate-count inflation.** A peak group with 20 observed charges now
  produces 20 candidates. Per-scan CPU scales linearly; the existing
  `mass_count` budget still caps selections, so end-to-end time is bounded
  — but sort cost on the flat list grows. Acceptable for developer flag.
- **Log-file semantics.** `all_mass_rt_map_` / `mass_qscore_map_` writes at
  lines 594, 601, 608, 621 still key on nominal mass. The per-charge set
  is **in-memory only**; no log-file format change. If log-file resumption
  is later wanted, it's a follow-up.
- **IDScore branch.** The IDScore-driven accumulation at lines 618-629
  operates on `mass_qscore_map_` (mass-keyed). Under the flag, we bypass
  the line 605 skip but leave this accumulation untouched; per-charge
  exclusion uses the score of each committed candidate independently.
- **Consumer assumptions.** Downstream calls like
  `removeFromExclusionList` assume mass-keyed state. Confirm those still
  work when the per-charge set co-exists with the mass map.

## Out of Scope

- Persisting the per-charge exclusion state to log files for run resumption.
- Changing the `consider_all_charges` default or removing it — the new flag
  subsumes its selection semantics but both stay independent.
- A "configured charge range sweep" mode (Q5 option C) that would trigger
  MS2 on charges never observed.

## Open Questions

None at design time. Ready for implementation planning after user review.

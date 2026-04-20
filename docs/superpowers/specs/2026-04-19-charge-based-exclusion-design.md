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

We want an optional mode that treats every `(mass, charge)` combination as an
independent acquisition target with its own per-`(mass, charge)` qscore
accumulator and its own exclusion decision. When a specific `(mass, charge)`
accumulator crosses `tqscore_threshold`, that **charge** is excluded — the
mass itself is NOT excluded, so other charges of the same mass remain
available for acquisition on later scans. There is no mass-level "done"
promotion; the mass is effectively "done" only in the emergent sense that
all its observed charges have been individually excluded.

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

There are **four drop-ins** in the picking code (A–D): three inside
`filterAndRank` (A, B, C) and one that spans the commit site and
`removeFromExclusionList` (D). Behavior outside the flag is byte-for-byte
unchanged.

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

#### Drop-in C — Per-(mass, charge) accumulator + exclusion write

Add a new `std::map<std::pair<int, int>, double> mass_charge_qscore_map_`
member on `PrecursorSelection`, parallel to the existing
`mass_qscore_map_` but keyed by `(nominal_mass, charge)`.

Wrap the existing accumulation block at `:596-630` with a flag branch:

```cpp
if (config_.targeting().charge_based_exclusion) {
  // NEW: per-(mass, charge) accumulator, parallel to the existing
  // mass-keyed block but keyed by (nominal_mass, charge). No write
  // into tqscore_exceeding_mass_rt_map_ / _mz_rt_map_ — under the flag
  // the mass is never globally excluded.
  const auto key = std::make_pair(nominal_mass, charge);
  if (!config_.targeting().use_idscore) {
    auto it = mass_charge_qscore_map_.find(key);
    if (it == mass_charge_qscore_map_.end()) {
      mass_charge_qscore_map_[key] = score;
    } else {
      mass_charge_qscore_map_[key] = std::max(it->second, score);
    }
    if (mass_charge_qscore_map_[key] > config_.targeting().tqscore_threshold) {
      tqscore_exceeding_mass_charge_set_.insert(key);
    }
  } else {
    auto it = mass_charge_qscore_map_.find(key);
    if (it == mass_charge_qscore_map_.end()) {
      mass_charge_qscore_map_[key] = 1 - score;
    } else {
      mass_charge_qscore_map_[key] *= 1 - score;
    }
    if (1 - mass_charge_qscore_map_[key] * tqscore_factor_for_exclusion
        > config_.targeting().tqscore_threshold) {
      tqscore_exceeding_mass_charge_set_.insert(key);
    }
  }
}
else {
  // EXISTING :596-630 block, unchanged.
}
```

This is a line-for-line parallel of the existing block, with three
mechanical substitutions:
- `mass_qscore_map_` → `mass_charge_qscore_map_`
- `nominal_mass` key → `{nominal_mass, charge}` key
- `tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;`
  `tqscore_exceeding_mz_rt_map_[integer_mz] = rt;`
  → `tqscore_exceeding_mass_charge_set_.insert(key);`

The two threshold-check formulas (non-idscore `acc > threshold` and
idscore `1 - acc * factor > threshold`) are copied verbatim from the
mass-keyed block so per-charge "done" semantics match the existing
mass-keyed "done" semantics exactly, one level deeper.

**Note — the existing `:604-607` max-tracking skip is inside the else
branch under this wrap, so it no longer runs under the flag.** That
matters: without this wrap the skip would block any lower-qscore charge
of a mass already acquired with a higher-qscore charge, defeating the
feature. No separate drop-in is needed to bypass it.

**Crucially, no mass-level write under the flag.** The existing writes at
`:614-615` (non-idscore) and `:627-628` (idscore) into
`tqscore_exceeding_mass_rt_map_` / `tqscore_exceeding_mz_rt_map_` live
inside the same else branch and are therefore never executed under the
flag. Filter f (`:586-590`) therefore never fires against a mass that
only has some of its charges done — only individual charges accumulate
exclusion. `mass_qscore_map_` itself is not touched under the flag, which
means `removeFromExclusionList` at `:681` no-ops on its
`mass_qscore_map_` branch naturally.

#### Drop-in D — `id_charge_map_` + `removeFromExclusionList` mirror

`removeFromExclusionList` (`:661` region) currently reverses the
mass-keyed exclusion state when an acquired MS2 turns out to be
low-quality. Under the flag it must mirror that for per-charge state:
erase `(nominal_mass, charge)` from `tqscore_exceeding_mass_charge_set_`,
and divide `mass_charge_qscore_map_[{nominal_mass, charge}]` by
`(1 - qscore)` in the idscore branch.

This needs the charge of the original acquisition. Add a new member
`std::unordered_map<int, int> id_charge_map_` parallel to the existing
`id_mass_map_` / `id_mz_map_` / `id_qscore_map_`, and populate it at the
existing commit site (`:641-:644`) — one line:

```cpp
id_charge_map_[window_id_] = charge;
```

This write happens unconditionally (flag-off or flag-on). Keeping it
always-on avoids a second gate and is cheap; the map is only **consulted**
by the undo branch under the flag.

Inside `removeFromExclusionList`, add a gated undo at the bottom:

```cpp
if (config_.targeting().charge_based_exclusion) {
  int charge = id_charge_map_[id];
  const auto key = std::make_pair(nominal_mass, charge);
  tqscore_exceeding_mass_charge_set_.erase(key);
  if (config_.targeting().use_idscore) {
    auto it = mass_charge_qscore_map_.find(key);
    if (it != mass_charge_qscore_map_.end()) {
      it->second /= (1 - qscore);
    }
  }
}
```

The existing mass-keyed undo block (`:672-681`) still runs. Under the
flag, `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_` are empty for
masses the flag handled, and `mass_qscore_map_` doesn't contain the mass,
so those branches no-op naturally — no existing lines need gating.

#### What is explicitly NOT added

- **No mass-level "done" promotion.** Under the flag,
  `tqscore_exceeding_mass_rt_map_` / `tqscore_exceeding_mz_rt_map_` are
  never populated. The mass is never globally excluded.
- **No flat global sort across peak groups.** Candidates remain grouped
  by peak group; charges are qscore-sorted within each peak group only.
- **No changes to phase logic, mode-2 outer loop, SNR handling, target
  matching, isolation-window handling, or any output vector layout.**

#### Commit path (almost unchanged)

The commit block at `:641-:655` runs exactly as today for every candidate,
including repeated invocations for different charges of the same peak
group. Drop-in D adds the one-line `id_charge_map_[window_id_] = charge`
write alongside the existing `id_mass_map_` / `id_mz_map_` / `id_qscore_map_`
writes.

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
| `tqscore_threshold` | Unchanged numeric value. Under the flag, it gates the new per-`(mass, charge)` accumulator's insertion into the exclusion set (drop-in C) instead of the mass-keyed writes (which are skipped). Same formula, one key level deeper. |
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
  `qscore_threshold` and `snr_threshold`. The per-`(mass, charge)`
  exclusion set applies equally: a TSV target's specific charge whose
  per-`(mass, charge)` accumulator has crossed `tqscore_threshold` will
  not be re-acquired. Other charges of that same target mass remain
  available. Non-strict inclusion's phase-1 non-target backfill is
  unchanged.
- **Mode 2 (exclusion)** — the mode-2 outer iteration loop at `:378` still
  runs twice. It continues to consult the mass-keyed
  `tqscore_exceeding_mass_rt_map_` in `iteration == 0` as today — those
  entries come from **log files** loaded at init, not from the flag's
  runtime accumulator, so they are unaffected by the flag's suppression of
  in-run mass-keyed writes. The new per-`(mass, charge)` set is consulted
  on both iterations; the "exclusion-lifting" pass (`iteration == 1`)
  still skips entries in the per-charge set. Rationale: the lift applies
  to mass-level replay, not to charge-level replay of a charge we have
  already covered this run.
- **Mode 3 (deep)** — same story as mode 2: the loaded `excluded_masses_`
  still suppresses mass-level acquisition; the per-`(mass, charge)` set
  is an independent cross-scan gate layered on top.

## Config Flow Changes

Following `docs/kb/config-flow/adding-a-config-field.md`:

1. **`FlashIDA/src/Flash/MethodConfig.cs`** —
   add to `DeveloperConfig.PrecursorSelection`:
   ```csharp
   [Developer]
   [JsonKey("charge_based_exclusion")]
   [Description("Treat each (mass, charge) as an independent acquisition target with its own qscore accumulator and exclusion decision. The mass itself is never globally excluded; other charges remain available after one charge is excluded.")]
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
and the corresponding `.cpp`. No header API changes — all additions are
private members.

**New members on `PrecursorSelection`:**
```cpp
// Per-(nominal_mass, charge) cross-scan exclusion set. Populated by
// drop-in C when the per-(mass, charge) tqscore accumulator crosses
// threshold. Consulted by drop-in B to skip re-acquisition.
std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_;

// Per-(nominal_mass, charge) qscore accumulator. Parallel semantics to
// the existing mass_qscore_map_:
//   - non-idscore: running max of score per (mass, charge)
//   - idscore:     product of (1 - score) per (mass, charge)
// Only touched when the flag is on.
std::map<std::pair<int, int>, double> mass_charge_qscore_map_;

// Per-acquisition-id charge tracker, parallel to id_mass_map_ /
// id_mz_map_ / id_qscore_map_. Populated unconditionally at the commit
// site. Only consulted by removeFromExclusionList's flag-gated branch.
std::unordered_map<int, int> id_charge_map_;
```

No new struct types. No changes to any existing member's type or key.

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
   the `charge` / `score` / `hcd` variables taken from the inner iterator.

B. **Drop-in B — new skip between `:581` and `:584`.** Two-line gated
   `continue` against `tqscore_exceeding_mass_charge_set_`. Pure addition.

C. **Drop-in C — wrap existing `:596-630` accumulation block.** Add an
   outer `if (charge_based_exclusion) { per-(mass, charge) block } else
   { existing block }`. The per-`(mass, charge)` block is a line-for-line
   parallel of the existing block with the three mechanical substitutions
   called out in §Drop-in C above. No mass-level writes into
   `tqscore_exceeding_mass_rt_map_` / `tqscore_exceeding_mz_rt_map_` in
   the flag-on branch. The existing `:604-607` max-tracking skip now lives
   inside the else branch and therefore no-ops under the flag — no
   separate gate needed.

D. **Drop-in D — commit-site + `removeFromExclusionList` bookkeeping.**
   Two sub-edits:
   - At `:641-:644` (the commit block), add one unconditional line
     `id_charge_map_[window_id_] = charge;` next to the existing
     `id_mass_map_[window_id_] = nominal_mass;` write.
   - At the bottom of `removeFromExclusionList` (after `:681`), add the
     gated undo block shown in §Drop-in D above: erase the per-charge set
     entry, divide the per-charge idscore accumulator.

That is the full set of code edits. All other lines in `filterAndRank`
and `removeFromExclusionList` are untouched.

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

4. **Mass is never globally excluded under the flag.** Scan 1: acquire
   `(mass, 6)` with qscore above `tqscore_threshold`. Assert
   `tqscore_exceeding_mass_charge_set_` contains `{mass, 6}`, and assert
   `tqscore_exceeding_mass_rt_map_` and `tqscore_exceeding_mz_rt_map_` do
   NOT contain the mass. Scan 2: same peak group, same scores. Assert
   charge 6 is skipped but charges 5 and 7 are acquired (mass is NOT
   globally excluded). **With the flag off, the same sequence must
   populate `tqscore_exceeding_mass_rt_map_[mass]` (regression guard).**

5. **Interaction with mode 2 two-pass loop.** With mode 2 enabled and the
   flag on, assert the exclusion-lifting pass (`iteration == 1`) still
   respects the per-charge set (i.e. does not replay a charge whose
   per-`(mass, charge)` accumulator crossed threshold). Also assert that
   mode-2 **log-file-driven** exclusions (`tqscore_exceeding_mass_rt_map_`
   entries loaded at init from log files) still suppress candidates on
   `iteration == 0` as today.

6. **Max-tracking skip suppressed under flag.** With the flag on, seed a
   first scan that acquires `(mass, 6)` with qscore 0.7 (below
   `tqscore_threshold`). On a second scan, introduce `(mass, 5)` with
   qscore 0.5. Assert charge 5 is acquired — i.e. the `:604-607`
   max-tracking skip does NOT block it (because drop-in C's else branch
   is not entered). With the flag off, the same sequence must skip charge
   5 (regression guard).

7. **`removeFromExclusionList` undoes per-charge state (idscore branch).**
   With the flag on and `use_idscore=true`, acquire `(mass, 6)` and let
   its per-charge idscore accumulator cross threshold, inserting
   `{mass, 6}` into the per-charge set. Call
   `removeFromExclusionList(id_of_that_acquisition)`. Assert the entry
   is erased from `tqscore_exceeding_mass_charge_set_` and
   `mass_charge_qscore_map_[{mass, 6}]` is divided by `(1 - score)`.

8. **`id_charge_map_` populated unconditionally.** Commit one acquisition
   each with the flag on and off; in both cases assert
   `id_charge_map_[window_id]` equals the committed charge.

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
  each peak group, not globally across peak groups. Deliberate minimal-diff
  choice. If a later experiment shows a real coverage gap, a global flat
  sort becomes a follow-up.
- **`mass_qscore_map_` stays empty under the flag.** The flag's accumulation
  runs on the new `mass_charge_qscore_map_` instead. Downstream code that
  reads `mass_qscore_map_` outside `filterAndRank` (notably the
  `mass_qscore_map_[nominal_mass] /= 1 - qscore` line in
  `removeFromExclusionList`) no-ops naturally because the mass has no
  entry. Confirm during implementation that no other reader assumes a
  populated map.
- **Log-file semantics unchanged.** Mode 2 / mode 3 log-file load paths
  still populate `target_mass_qscore_map_` / `exclusion_rt_masses_map_` /
  `tqscore_exceeding_mass_rt_map_` as today. The new per-`(mass, charge)`
  state is in-memory only; no log-file format change. Log-file resumption
  of per-charge state is a follow-up.
- **Repeated `PeakGroup*` in outputs.** Under the flag, multiple entries
  in `selected_peak_groups_` can reference the same peak group.
  `removeFromExclusionList` and the MS2 command builders index by
  selection slot (`window_id_`), not peak-group identity, so current
  consumers should be fine — confirm during implementation.
- **Drop-in C mirrors the mass-keyed threshold formula exactly.** The
  per-`(mass, charge)` accumulator uses the same `tqscore_threshold`
  scalar and the same comparison formulas (max > threshold in non-idscore;
  `1 - acc * factor > threshold` in idscore) — just at a finer key. A
  future experiment that wants a different per-charge threshold would
  need a separate config knob.
- **Priority tie-break not extended to charges.** The existing
  `stable_sort` for inclusion-mode priority (`:277-282`) still operates
  on peak groups. Under the flag, all charges of a high-priority target
  inherit its priority uniformly (through peak-group order), but priority
  does NOT break ties between charges of the same mass. If per-charge
  priority is ever wanted it requires extending the priority map and the
  tie-break — out of scope here.

## Out of Scope

- Persisting the per-charge exclusion state to log files for run resumption.
- Changing the `consider_all_charges` default or removing it — the new flag
  subsumes its selection semantics but both stay independent.
- A "configured charge range sweep" mode (Q5 option C) that would trigger
  MS2 on charges never observed.

## Open Questions

None at design time. Ready for implementation planning after user review.

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

The change is confined to `filterAndRank`'s selection loop. Everything below
is gated by `if (config_.targeting().charge_based_exclusion)` — every
mutation to existing lines is branched so the default path is untouched.

#### 1. Candidate generation (replaces the peak-group iterator)

Replace the outer `for (const auto& pg : deconv_.deconvolvedMS1())` at
`PrecursorSelection.cpp:395` with iteration over a **flat candidate list**.

**Structure:**
```cpp
struct FlatCandidate {
  const PeakGroup* pg;
  int charge;
  double score;
  int hcd;
  double center_mz;
  double mz1;
  double mz2;
  int integer_mz;
  double mass;            // mono mass
  int nominal_mass;
};
std::vector<FlatCandidate> flat_candidates_;
```

**Population (once per scan, before the phase loop at line 381).** For each
peak group `pg` in `deconv_.deconvolvedMS1()`:

- **Charges to expand.** Iterate every charge `c` in the closed interval
  `pg.getAbsChargeRange()`. For each `c`, only emit a candidate if
  `pg.getAllQscores().count(c) > 0` — i.e. the charge was actually scored
  during deconvolution. This silently drops holes in the charge range and
  avoids fabricating candidates with undefined qscore.
- **Score per candidate, by config branch (mirrors lines 404-429):**
  - `use_idscore && consider_all_charges && hcd_energy < 0`:
    `score = pg.getBestIDScoreForCharge(c)`; `hcd = pg.getBestHCDForCharge(c)`
  - `use_idscore && consider_all_charges` (fixed hcd):
    `score = pg.getIDScoreForChargeAndHCD(c, hcd_energy)`;
    `hcd = hcd_energy`
  - `use_idscore && !consider_all_charges && hcd_energy < 0`:
    `score = pg.getBestIDScoreForCharge(c)`; `hcd = pg.getBestHCDForCharge(c)`
  - `use_idscore && !consider_all_charges` (fixed hcd):
    `score = pg.getIDScoreForChargeAndHCD(c, hcd_energy)`;
    `hcd = hcd_energy`
  - non-idscore (both `consider_all_charges` values):
    `score = pg.getAllQscores().at(c)`; `hcd = hcd_energy`

  Note that under the flag `consider_all_charges` has no effect on
  candidate generation — we emit all observed charges anyway — but it still
  affects which scoring function is chosen for consistency with the default
  path. (Specifically, whether HCD energy is picked per-charge or fixed.)

- **Geometry per candidate:** `[mz1, mz2] = pg.getMzRange(c)`;
  `center_mz = (mz1 + mz2) / 2`; `integer_mz = round(center_mz)`;
  `mass = pg.getMonoMass()`; `nominal_mass = int(round(mass))`.
- **Isolation margin:** apply `optimal_window_margin_` to `mz1` / `mz2`
  at candidate-build time (matching line 441-442 in today's loop).

**Sort.** One primary sort: `std::sort(flat_candidates_.begin(), .end(),
cmp_by_score_desc)`. Secondary priority tie-break (mode 1 TSV targets):
apply the same `stable_sort` logic as today (line 277-282) but on the flat
list — `tie_threshold` comparisons use the priority-map entry for the
candidate's `nominal_mass`. A target's priority applies uniformly to all
its (mass, charge) candidates, so the tie-break is well-defined.

**Phase-local filtering.** The three-phase loop at line 381 stays intact.
Each phase iterates the SAME `flat_candidates_`. Phase-0 / phase-1 /
phase-2 semantics (target-only vs non-target backfill vs permissive
fallback) are preserved by reusing the existing inner-loop branches — only
the iteration source changes.

**Mode 2 outer iteration.** The outer iteration loop at line 378 still
runs twice for mode 2. `flat_candidates_` is rebuilt once per scan (not
per outer iteration) — the two iterations apply different exclusion views
to the same candidate list.

#### 2. Per-candidate filter block (preserved, with two gates swapped)

Inside the main loop the existing filters run in this order. Line numbers
refer to today's code at the equivalent per-candidate site.

| # | Filter | Behavior under flag |
|---|--------|---------------------|
| a | `charge < config_.level(ms_level).min_charge` (`:432`) | **Unchanged** — `continue`. The min_charge check now fires per-charge naturally. |
| b | Inclusion-mode target match (`:461-:530`) | **Unchanged.** Target matching uses nominal mass and optional charge range; per-charge candidates honour the target's charge spec without modification. |
| c | `score < qscore_threshold` (`:569`, `break`) | **Unchanged.** Flat list is sorted descending; break is still safe. Target-matched candidates still waive via threshold=0. |
| d | `pg.getChargeSNR(charge) < snr_threshold` (`:572`, `continue`) | **Unchanged.** SNR is already per-charge. Target match still waives. |
| e | Same-m/z avoidance (`:574-:581`) | **Unchanged.** Different charges of the same mass produce different `center_mz` values and therefore do not collide. The existing phase-2 relaxation also carries over unchanged. |
| f | Mass-level `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_` gate (`:586-:590`, phase 0 and 1 only) | **Gate preserved**, but the maps are populated differently (see §4). In practice, under the flag they are only written once every observed charge of a mass has been acquired; until then they remain empty for that mass, so this gate is effectively dormant. |
| g | **NEW**: `tqscore_exceeding_mass_charge_set_.count({nominal_mass, charge})` | Insert this check immediately after filter (e) and before filter (f). If true → `continue`. This is the per-(mass, charge) cross-scan exclusion. |
| h | `mass_qscore_map_` max-tracking skip (`:605`, `continue`) | **Bypassed under flag.** Flag-on path does NOT consult `mass_qscore_map_` for skipping. See §3 for why the map itself still updates. |

Filters a-e run identically. Filter f stays in place for correctness even
though it rarely fires under the flag. Filter g is the one new early-exit.
Filter h's skip-behavior is the ONE deliberate semantic divergence: without
this bypass, the max-tracking rule would block any lower-qscore charge of
a mass that has already been acquired with a higher-qscore charge, which
defeats the feature.

#### 3. Commit path & map updates

When a candidate passes all filters, the existing commit block
(`:641-:655`) runs unchanged: `trigger_ids_`, `selected_peak_groups_`,
`trigger_charges_`, `trigger_hcds_`, `trigger_scores_`,
`trigger_left_isolation_mzs_`, `trigger_right_isolation_mzs_`,
`current_selected_masses`, `current_selected_mzs` all populate as today.

Then, **still under the flag**:

- **Update `mass_qscore_map_` (unchanged logic).** The lines 596-630 block
  runs byte-for-byte as today. The map stays mass-keyed; non-idscore branch
  still tracks max qscore; idscore branch still accumulates `(1 - score)`
  products. The only behavioral change is filter (h) no longer reads the
  map for skipping.
  - **Why keep updating it?** Downstream consumers (`removeFromExclusionList`
    called from the bridge on MS2 result, plus logging) read this map.
    Breaking its write path risks silent downstream bugs.
- **Write to `tqscore_exceeding_mass_rt_map_` / `_mz_rt_map_`
  (unchanged condition).** Lines 612-616 still fire when the mass-keyed
  accumulator crosses `tqscore_threshold`. Under the flag this will still
  happen once a mass's best charge has been acquired; §4 describes the
  extra per-charge criterion that layers on top.
- **NEW: update `tqscore_exceeding_mass_charge_set_`.** Insertion condition
  mirrors the mass-level condition, but evaluated per-charge:
  - non-idscore branch: insert `(nominal_mass, charge)` if `score > tqscore_threshold`.
  - idscore branch: insert `(nominal_mass, charge)` if
    `1 - per_charge_accumulator[(nominal_mass, charge)] *
    tqscore_factor_for_exclusion > tqscore_threshold`, where
    `per_charge_accumulator` is a new `std::map<std::pair<int,int>, double>`
    tracking per-charge product of `(1 - score)` terms (parallel to
    `mass_qscore_map_`'s idscore accumulation semantics).

  Store a per-charge accumulator map (`mass_charge_qscore_map_`) alongside
  `mass_qscore_map_`. It is only touched when the flag is on.

#### 4. Mass-level "done" promotion

After the per-charge insertion in §3, check whether every observed charge of
this peak group's original `getAbsChargeRange()` now has an entry in
`tqscore_exceeding_mass_charge_set_` for this `nominal_mass`. If yes, write
`nominal_mass` / `integer_mz` into `tqscore_exceeding_mass_rt_map_` /
`tqscore_exceeding_mz_rt_map_` (idempotent — just overwrite).

This gives a well-defined "mass fully covered" signal that future scans can
consume through filter (f) without needing to also check the per-charge set.
It also keeps the mass-level exclusion semantics the same for anything that
reads those maps from outside `filterAndRank`.

**Source of truth for "observed charges":** the peak group's
`getAbsChargeRange()` on the scan where §3 fires — i.e. the current scan.
If a later scan reports a wider range for the same mass, the "done" check
will not have seen those new charges, and the mass may exit the
`tqscore_exceeding_mass_rt_map_` state dynamically (the new charges would
need to be acquired before promotion fires again). This matches your
"minimal, dynamic" intent.

#### 5. Output invariants (unchanged)

All output vectors remain consistent with the documented guarantees in
`docs/kb/ms1-acquisition/precursor-selection.md`:

- `selected_peak_groups_` in descending rank order.
- `trigger_charges_[i]` is the charge for selection `i` (now possibly
  repeating a peak group across successive indices when multiple charges of
  the same mass are selected within one scan).
- `trigger_hcds_[i]`, `trigger_scores_[i]`, isolation m/z bounds, and
  `trigger_ids_[i]` all align by index as today.

**One consequence worth flagging:** `selected_peak_groups_[i]` and
`selected_peak_groups_[j]` (i ≠ j) may now reference the same `PeakGroup`
instance when the flag is on. Consumers that assume uniqueness need to use
`trigger_charges_[i]` to disambiguate. Scan through the MS2 command
builders and `removeFromExclusionList` callers to confirm.

#### 6. Knobs and surface area

The flag interacts with these existing config knobs:

| Knob | Effect under flag |
|---|---|
| `qscore_threshold` | Same — cuts off the low end of the flat list. |
| `snr_threshold` | Same — per-charge SNR still filters individual charges. |
| `tqscore_threshold` | Now used by BOTH the mass-keyed map (unchanged) and the new per-charge map (new). Same numeric value applies to both. |
| `consider_all_charges` | See §1 — affects only score-selection branch inside candidate generation, not the expansion itself. |
| `use_idscore` | See §1 — picks IDScore getters. §3 commit path also branches on it for per-charge accumulator semantics. |
| `tie_threshold` | Same — applied via `stable_sort` after the primary qscore sort. |
| `mass_count` | Same hard budget on total selections per scan. |

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
and the corresponding `.cpp`.

**New members on `PrecursorSelection`:**
```cpp
// Per-(nominal_mass, charge) cross-scan exclusion set.
std::set<std::pair<int, int>> tqscore_exceeding_mass_charge_set_;

// Per-(nominal_mass, charge) qscore accumulator. Parallel semantics to
// mass_qscore_map_: max for non-idscore, product of (1 - score) for idscore.
std::map<std::pair<int, int>, double> mass_charge_qscore_map_;
```

**New private type (internal to the `.cpp`):**
```cpp
struct FlatCandidate {
  const PeakGroup* pg;
  int charge;
  double score;
  int hcd;
  double center_mz;
  double mz1;
  double mz2;
  int integer_mz;
  double mass;
  int nominal_mass;
};
```

**Function-level edits in `filterAndRank`:**

1. **Extract the per-candidate filter+commit body** (currently lines
   `400-655` inside the peak-group loop) into a private helper
   `tryCommitCandidate(const FlatCandidate&, int selection_phase, ...)`.
   The helper returns `true` if the candidate was committed (so callers
   can enforce the `mass_count` break). Both the flag-off and flag-on
   paths call this helper; the only parameterization is how the candidate
   is constructed.
2. **Flag-off path:** keep the existing peak-group loop. For each `pg`,
   build a single `FlatCandidate` using the existing rep-charge / best-
   charge branch logic and invoke the helper. This is a pure refactor —
   no behavior change.
3. **Flag-on path:** before the phase loop, populate `flat_candidates_`
   as described in §1. Inside each phase, iterate `flat_candidates_` and
   invoke the helper.
4. **Inside the helper, under the flag:**
   - Between existing filters (e) and (f), consult
     `tqscore_exceeding_mass_charge_set_` and `continue` if present.
   - In the commit block, after the existing `mass_qscore_map_` update,
     also update `mass_charge_qscore_map_` and insert into
     `tqscore_exceeding_mass_charge_set_` when its per-charge threshold
     is crossed.
   - After insertion, run the "all observed charges done" check from §4
     and, if satisfied, write into `tqscore_exceeding_mass_rt_map_` /
     `tqscore_exceeding_mz_rt_map_`.
   - Skip the line 605 max-tracking `continue` when the flag is on.

**No header API changes** — all additions are private members.

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

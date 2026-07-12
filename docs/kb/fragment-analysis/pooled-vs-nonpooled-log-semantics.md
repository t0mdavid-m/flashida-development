---
title: Pooled vs non-pooled identification log semantics
last_verified: 2026-07-12
code_anchors:
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.cpp
---

# Pooled vs non-pooled identification log semantics

Two identification streams describe the same acquisition from different angles.
Reading them side by side surfaces apparent "inconsistencies" that are actually
definitional. This packet documents those seams (owner-reviewed 2026-07-10).

- **`identification.tsv`** — one row per **per-event** identification (each MS2 or
  MS3 scan). Keyed by `tracking_id`, linked to a Precursor via `precursor_id`.
- **`pooled_identification.tsv`** — one row per **cumulative winner-anchored** model
  update. Keyed by `(precursor_id, update_index)`.

## The seams (all by-design unless noted)

- **[B] `n_fragments` vs `combined_*` length.** Pooled `n_fragments` counts **distinct
  ion keys** (`m.fragments.size()`, `ProteoformTracker.cpp`); the `combined_*` arrays
  carry **one entry per observation** (`alignedCombinedLists_` pushes `best_ms2` *then*
  `best_ms3` for a key seen at both levels). So an ion observed at both MS2 and MS3
  appears twice (e.g. `b13;b13`, same theoretical, different frame masses) and the
  array length = `n_fragments` + (#ions seen at both levels). Slicing the arrays by
  `n_fragments` truncates the MS3 entries.

- **[D] `combined_measured_raw`.** Renamed from `combined_measured`: it is the **raw
  own-scan-frame** mass. For MS3 entries it is the sub-peptide-frame value, so
  `measured − theoretical ≠ diff`. `combined_diff`/`combined_theoretical` pair with
  `combined_ms2_frame_masses` (the projected MS2-frame value), not with the raw column.

- **[F] MS3 retention = max-intensity per (ion, MS-level).** `upsertMappedObservation_`
  keeps exactly one `best_ms2` and one `best_ms3` per `FragmentKey` (highest intensity).
  Lower-intensity duplicate measurements of the same ion are intentionally not retained;
  a later MS3 scan can upgrade one slot in place.

- **[G] `identification.tsv` is a per-event superset of what pooling folds.** The CE-0
  exploration baseline, E-mode CE-sweep variants, and dispatched-but-empty MS3 scans are
  logged in `identification.tsv` but are **not** pooled (only the resolved winner / R-mode
  path folds into the model). Additionally, a **non-winner, non-FLASHTnT-ID** scan whose
  masses re-match the winner ladder now DOES get an `identification.tsv` row (winner
  proteoform + re-matched fragments, `flash_extender_score = -1`) — see below.

- **[H] `coverage_pct` frame.** `coveragePct()` is fractional coverage over the **model
  winner-region length** (distinct cleavage sites). It is not reconstructable from a
  per-scan `start/end`, and is a different metric than `identification.tsv`'s per-scan
  `tic_coverage` / `ms3_fragment_coverage`.

- **[I] `nominal_mass = getNominalMass(mono) = round(mono × 0.999497)`** (FLASHDeconv
  mass-defect-scaled integer nominal mass, `ProteoformTracker.cpp` → `SpectralDeconvolution::getNominalMass`),
  **not** `round(mono)`. `mono_mass` equals each contributor's `ms1_precursor_mass` exactly.

- **[J] Backbone identities of the golden fixtures.** `exploration_hcd` is carbonic
  anhydrase II (a 259-aa protein, **not** cytC); `inclusion_ms3_cytc` is **des-Met** cytC
  (104 aa). Within each mode, pooled and identification agree — the divergence is only
  vs the M-start cytC reference. cytC Met-excision means an inclusive vs exclusive frame
  can read as an off-by-one on the (0..104) span.

- **[K] Pooled `update_index=1` may be one residue tighter than the winner's own MS2
  leaf**, because `finalizeMS2` already folds sibling non-winner MS2 evidence
  (`mapNonWinnerMs2_`) before emitting the baseline row. This is the correct direction
  (more evidence → tighter), not a discrepancy. The pooled proteoform equals a single
  contributor's per-event string only at `update_index=1`; later updates are a
  winner-backbone consensus with a jointly-narrowed localization.

- **[L] MS3 leaf mod-localization = per-scan equiv-frame gap-partition.**
  `identification.tsv`'s MS3 `proteoform` localizes each ambiguous mod over **that scan's own
  EQUIVALENT (full-protein) ions** — `FragmentAnalysis::narrowFragmentPTMSites` reads
  `fm.equiv_type`/`fm.equiv_index` + the flip/mod-aware verdict shared with pooled Pass B
  (`is_complement_flip`; `nterm_loss` keeps an N-terminal net-loss composite on residue 1),
  **not** the raw sub-frame ion (`fm.ion_type`/`fm.ion_index`). It seeds **wide over `[1,L]`**
  and tightens inward, so the leaf reflects exactly what that scan resolves — it may be
  **wider than pooled** and **may exceed the `scan_commands` a-priori base** (there is **no**
  leaf-⊆-`scan_commands` guarantee; the `wide_sites` base is a classification reference, not
  an output clamp). Two adjacent mods that **no fragment separates** (their brackets overlap —
  a shared gap) **merge** into one **summed** shift over the union (e.g.
  `−89.0302 + 615.2498 = +526.2196`) — the leaf reports what the ion physically sees. The
  pooled path (`narrowModifications_`, cumulative **one-directional** narrowing) is a
  **separate** code path and stays **byte-identical**; this is a leaf-only refinement. (It
  replaced a raw-sub-frame narrower whose complement-flipped suffix ion `yb69` — equivalent to
  prefix `b1 = 42.01 = M−89` — was misread as a suffix and pushed the −89 off residue 1.)

## `flash_extender_score` (identification.tsv)

Appended column: the FLASHExtender/FLASHTnT identification score of **this scan's own
match**. **`-1` = the scan did not self-identify** — it is a winner-re-matched non-winner
row (its masses matched the winner ladder, so it folds into the pool but has no own ID).
Score presence is the sole distinguisher between self-ID rows and re-matched rows.

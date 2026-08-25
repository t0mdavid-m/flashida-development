# Log Column Order — Reorder Reference (WORKING)

**Status:** draft during grilling session, 2026-07-15. Working reference only — not a plan.

**Approach (A):** change the **live** engine log-output column order in
`OpenMS/.../TOPDOWN/FLASHIda/IdaLogger.cpp`; **golden fixtures stay in the old order**;
a compare-time shim reorders the fresh capture back to golden order **by header name**,
so **no recapture** is required. Motivation: human readability of live acquisition logs.

**Ground truth (CURRENT order)** extracted verbatim from `IdaLogger.cpp` header emission
(lines 73–176). Column counts: Command 34 · Results 32 · Identification 34 · Pooled 19.

> **This document models a one-time permutation and is no longer the whole story.** ADR-0012
> *added* a column (`faims_enabled`) and ADR-0026 two more (`first_mass`, `last_mass`), so the
> "pure permutation" framing below holds for the 2026-07 reorder only. A schema **addition** is a
> different operation with a different cost: comparison is by header name, so a reorder is free,
> but an add makes every golden's header width wrong and `GoldenListCanonicalizer` throws rather
> than failing softly — every log-golden mode must be recaptured in the same push.

---

## 1. Command Log (`scan_commands`) — 34 columns

**Verification: ✅ COMPLETE** for the reorder. All 31 columns of the 2026-07 permutation are
present exactly once. `faims_enabled` was subsequently added at index 30 (ADR-0012), between
`faims_cv` and `enqueue_ts` — the one position that adds a column without invalidating any index
pinned by `FLASHIda_LoggingFields_test` (all of which are < 29) or the `headers.back()` assertion.
`first_mass` and `last_mass` followed at indices 31 and 32 (ADR-0026 decision 6), in that same gap —
now between `faims_enabled` and `enqueue_ts` — for the same reason: every index that test pins is
still ≤ 30 (`faims_cv` 29, `faims_enabled` 30 — `FLASHIda_LoggingFields_test.cpp`), and `enqueue_ts`
stays `headers.back()`. Like ADR-0012's, this is an **addition**, not a
permutation, so it moves `scan_commands.tsv` in all 22 golden modes, which recapture in the same
push.

New (desired) order:

1. tracking_id
2. scan_type
3. ms_level
4. parent_tracking_id
5. precursor_id
6. priority
7. mono_mass
8. charge
9. precursor_mz
10. isolation_width
11. qscore
12. charge_cos
13. charge_snr
14. iso_cos
15. snr
16. charge_score
17. activation
18. collision_energy
19. hcd_energy
20. reaction_time
21. reagent_max_it
22. reagent_agc_target
23. ppm_error
24. precursor_intensity
25. peakgroup_intensity
26. ion_type
27. ion_index
28. ms3_proteoform
29. scan_description
30. faims_cv
31. faims_enabled
32. first_mass
33. last_mass
34. enqueue_ts

Current order (for reference): tracking_id, ms_level, scan_type, enqueue_ts, priority,
faims_cv, mono_mass, charge, precursor_mz, isolation_width, collision_energy, activation,
qscore, charge_cos, charge_snr, iso_cos, snr, charge_score, ppm_error, precursor_intensity,
peakgroup_intensity, hcd_energy, parent_tracking_id, ion_type, ion_index, reaction_time,
reagent_max_it, reagent_agc_target, scan_description, precursor_id, ms3_proteoform.

---

## 2. Results Log (`scan_results`) — 32 columns

**Verification: ✅ COMPLETE** for the reorder. All columns of the 2026-07 permutation are present
exactly once; the deconv block has since been restructured and extended — see the note below.

New (desired) order:

1. tracking_id
2. ms_level
3. parent_tracking_id
4. commands_pushed
5. child_ids
6. rt
7. duration_ms
8. duration_received_ms
9. queue_duration_ms
10. instrument_duration_ms
11. processing_duration_ms
12. mass_count
13. remaining_ratio
14. exploration_group_id
15. exploration_metric
16. exploration_score
17. variant_index
18. total_variants
19. winner_tracking_id
20. activation_type
21. collision_energy
22. reaction_time
23. deconv_masses
24. deconv_qscores
25. deconv_charges
26. deconv_intensities
27. resolve_ts
28. received_ts
29. dequeue_ts

Current order (for reference): tracking_id, ms_level, resolve_ts, duration_ms, received_ts,
duration_received_ms, rt, mass_count, commands_pushed, child_ids, exploration_group_id,
exploration_metric, variant_index, total_variants, collision_energy, exploration_score,
remaining_ratio, activation_type, reaction_time, deconv_masses, deconv_qscores, deconv_charges,
deconv_intensities, parent_tracking_id, dequeue_ts, queue_duration_ms,
instrument_duration_ms, processing_duration_ms, winner_tracking_id.

**29 columns — but not the 29 this section was drafted against.** The count went 29 → 28 → 29, so an
equal column count is no evidence a golden header is current; compare the names. The per-charge
deconvolved output first replaced four columns (`deconv_masses`, `deconv_intensities`,
`deconv_min_charge`, `deconv_max_charge`) with three (`deconv_masses`, `deconv_charges`,
`deconv_intensities`): each PeakGroup contributes one `;`-group per column, with its observed charges
and their **own** intensities `,`-joined inside and index-aligned. `deconv_intensities` used to be the
PeakGroup total summed across charge states, so the log could say how much signal a mass carried but
never how it was distributed — and that distribution is exactly what decides which charges clear the
SNR gate for co-isolation. Min and max are derivable from the charge list.

`deconv_qscores` adds the 29th back. It is `PeakGroup::getQscore()` — **one value per mass, not per
charge**, so `;`-joined only, index-aligned 1:1 with `deconv_masses`, and written on every MS level
(1, 2 and 3), never level-conditionally. It is the score at the **representative** charge — the
rep-charge element of the per-charge qscore set, not an aggregate over the envelope — and it is the
same call that fills `cmd.qscore` in `ScanCommandQueue`, so a selected mass's value reappears in
`scan_commands.qscore`.

---

## 3. Identification Log (`identification`) — 34 columns

**Verification: ✅ COMPLETE.** Full 32-column order — your curated 19, then the 13 detail
columns appended in their current relative order (decision: "append after"). Pure permutation.

New (desired) order (32):

1. tracking_id
2. scan_mode
3. ms_level
4. precursor_id
5. ms1_precursor_mass
6. ms2_precursor_ion
7. proteoform
8. flash_extender_score
9. ms2_fragments
10. ms2_fragment_masses
11. ppm_offset
12. correction_factor
13. ms1_precursor_mz
14. ms1_precursor_charge
15. ms2_precursor_mass
16. ms2_precursor_mz
17. ms2_precursor_charge
18. start_pos
19. end_pos
20. ms3_fragments
21. ms3_fragment_masses
22. ms2_isolation_width
23. ms2_window_snr
24. ms2_charge_intensity
25. ms3_isolation_width
26. ms3_window_snr
27. ms3_charge_intensity
28. theoretical_masses
29. diff_da
30. diff_ppm
31. ms3_fragment_coverage
32. tic_coverage

Current order (for reference, 32): ms_level, scan_mode, tracking_id, proteoform, start_pos,
end_pos, ppm_offset, correction_factor, ms1_precursor_mass, ms1_precursor_mz,
ms1_precursor_charge, ms2_precursor_ion, ms2_precursor_mass, ms2_precursor_mz,
ms2_precursor_charge, ms2_fragments, ms2_fragment_masses, ms3_fragments, ms3_fragment_masses,
ms2_isolation_width, ms2_window_snr, ms2_charge_intensity, ms3_isolation_width, ms3_window_snr,
ms3_charge_intensity, precursor_id, theoretical_masses, diff_da, diff_ppm, ms3_fragment_coverage,
tic_coverage, flash_extender_score.

---

## 4. Pooled Identification Log (`pooled_identification`) — 19 columns

**Verification: ✅ COMPLETE.** All 19 current columns present exactly once. Pure permutation.

New (desired) order:

1. trigger_scan_id
2. trigger
3. precursor_id
4. update_index
5. mono_mass
6. proteoform
7. flash_extender_score
8. coverage_pct
9. n_fragments
10. localized_mods
11. ambiguous_mods
12. combined_ms2_frame_masses
13. combined_ms2_fragment_ions
14. combined_measured_raw
15. combined_theoretical
16. combined_diff_da
17. combined_diff_ppm
18. contributing_scan_ids
19. nominal_mass

Current order (for reference): nominal_mass, mono_mass, proteoform, flash_extender_score,
coverage_pct, n_fragments, localized_mods, ambiguous_mods, contributing_scan_ids,
combined_ms2_frame_masses, combined_ms2_fragment_ions, combined_measured_raw,
combined_theoretical, combined_diff_da, combined_diff_ppm, update_index, precursor_id,
trigger, trigger_scan_id.

---

## Open questions (grilling)

1. ~~Identification Log placement~~ — RESOLVED: 13 detail columns appended after `end_pos`
   (positions 20–32), current relative order. All 4 stream orders finalized as pure permutations.
2. Confirm the shim reorders the **fresh capture → golden (old) order** by header name as the
   first pipeline step, leaving the index-based normalizer/canonicalizer untouched.
3. Full dependency surface: every consumer that reads these logs by column index (C++ writers'
   row functions, C++ tests, C# normalizer/canonicalizer indices, other C# tests, scripts).

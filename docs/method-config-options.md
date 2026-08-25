# `method.json` options — every setting, its legal values, and its default

| Stage | Owner |
|---|---|
| Which keys may be authored, and the effective defaults | `FlashIDA/src/Flash/MethodConfig.cs` + `IDA/MethodConfigSerializer.cs` (`[JsonKey]`) |
| What crosses the bridge | `FlashIDA/src/Flash/MethodParameters.cs` → `ToCppJson()` |
| Which values are legal | `OpenMS/.../TOPDOWN/FLASHIda/Config.cpp` → `Config::Config` + `Config::validate` |
| What reaches the instrument | `FlashIDA/src/Flash/ScanFactory.cs` → `BuildFromCommand` |

## `global`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `method_name` | string | any string | `""` | Free-text label that crosses the bridge and is read by nothing on either side. |
| `method_description` | string | any string | `""` | Same — documentation only. |
| `duration` | double | any double; the `Timer` ctor rejects ≤ 0 and > ~35791 | `90` | Minutes of wall clock before the instrument path stops acquisition; read only by C#. |

## `deconvolution`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `score_threshold` | double | any double; qscore is in (0,1), so ≤ 0 admits everything and ≥ 1 rejects everything | `-1` † | Qscore floor a charge candidate must clear to be selectable. |
| `tqscore_threshold` | double | any double; compared `>` against a qscore in (0,1), so `0.0` excludes after one acquisition and ≥ 1 never excludes | `0.9` | Ceiling on a mass's best-so-far qscore, above which it stops being re-selected for `rt_window`. |
| `min_charge` | int | any int; the **sign sets ion polarity**, then both bounds are `abs()`'d and swapped if inverted | `4` | Lowest charge state MS1 deconvolution assigns, and its sign selects positive- or negative-ion mode. |
| `max_charge` | int | any int | `50` | Highest charge state considered when assembling MS1 isotope envelopes. |
| `min_mass` | double | any double (Da) | `500` | Lightest monoisotopic mass reported, so nothing below it can become a precursor. |
| `max_mass` | double | any double (Da) | `50000` | Heaviest mass considered; it also sizes the precomputed averagine table. |
| `tol` | array\<double> | **≥ 3 entries required**; ppm, indexed `tol[level−1]` | `[10, 10]` — **unloadable** | Per-MS-level ppm mass tolerance for deconvolution, matching and mass exclusion. |

## `precursor_selection` — *which species do we fragment?*

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `rt_window` | double | any double | `180` | How long a fragmented mass stays dynamically excluded before it may be picked again. |
| `targeting` | string | `none` \| `inclusion` \| `in_depth` \| `exclusion_masses` | `"none"` | Selects plain DDA, inclusion-list priority, soft de-prioritisation of already-seen masses, or hard mass exclusion. |
| `strict_inclusion` | bool | `true` / `false` | `false` | Under inclusion targeting, forbids the non-target fallback pass so only listed masses are fragmented. |
| `tie_threshold` | double | any double; compared `abs(qscore_a − qscore_b) < t` | `0.1` | Qscore gap under which two candidates count as tied, letting the inclusion list's priority column break the tie. |
| `consider_all_charges` | bool | `true` / `false` | `false` | Ranks and isolates a species at its best-scoring charge instead of the deconvolver's representative charge. |
| `precursor_charges` | string | `single` \| `separate` \| `multiplexed` (**not** lowercased on emit) | `"single"` | How much of a species' charge envelope one MS2 covers: anchor charge, one scan per charge, or all co-isolated as notches. |
| `rank_by` | string | `qscore` \| `intensity` \| `none` | `"qscore"` | Orders MS1 candidates by deconvolution quality or raw intensity; `none` switches MS1 selection off entirely. |
| `max_precursors` | int | any int; `0` selects nothing, negative throws `std::length_error` mid-survey | `10` | Per-MS1 budget of distinct **species** fragmented. |
| `min_precursor_charge` | int | any int; `≤ 0` disables the filter | `0` | Drops candidate charge states below this from MS2 selection. |
| `additional_scans` | array\<string> | keys of `ms_settings.additional_ms2`; duplicates, unknown names and double-duty names all throw | `[]` | Extra MS2 configs acquired for every selected precursor, after `ms_settings.ms2`, in array order. |

### `precursor_selection.tag_expansion`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `max_ptm_count` | int | any int | `3` | Caps how many PTMs may be stacked when enumerating modified target masses. |
| `max_flanking_mass_diff` | double | any double (Da) | `50000` | Widest flanking-mass mismatch tolerated when a real-time tag is matched to a FASTA protein. |

## `exploration` — the CE / reaction-time sweep

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `metric` | string | `none` \| `mass_count` \| `remaining_precursor` \| `fragment_count` | `"none"` | Which quantity the sweep maximises when picking the winning CE / reaction time. |
| `ce_min` | double | any double; `ce_max > ce_min` required for a CE-coupled activation | `20` | Lowest normalized collision energy tried. |
| `ce_max` | double | any double; inclusive endpoint (`≤ ce_max + 1e-9`) | `40` | Upper bound of the CE sweep. |
| `ce_step` | double | **must be > 0** whenever `metric != "none"` | `5` | Spacing between swept CE values, and therefore the variant count. |
| `reaction_time_min` | double | any double (ms); `max > min` required for an ETD-family sweep | `0` | Shortest ion-ion reaction time tried. |
| `reaction_time_max` | double | any double (ms); inclusive endpoint | `0` | Upper bound of the reaction-time sweep. |
| `reaction_time_step` | double | **must be > 0** when a reaction-time range is set | `1` | Spacing between swept reaction times. |
| `activations` | array\<string> | no allowlist; only `HCD`/`CID`/`EThcD` (sweep CE) and `ETD`/`EThcD` (sweep RT) are load-bearing | `null` | Fragmentation types the sweep tries, each contributing its own variants. |
| `overrides` | map\<string,string> | keys = the 17 scan keys; unknown keys **silently ignored**; `tolerance_ppm` throws; values must be JSON **strings** | `null` | Field-level edits applied to the base scan config before variants are built, and — by being non-empty at all — the switch that re-acquires the winner as a production scan. |
| `remaining_precursor_target` | double | any double; scored `1 − abs(ratio − target)` floored at 0 | `0.1` | The surviving-precursor fraction the `remaining_precursor` metric aims at. |
| `tolerance_ppm` | double | any double; `≤ 0` inherits `deconvolution.tol[level−1]` | `0` | Mass tolerance used to score sweep variants. |

## `characterization` — *whether and how do we pin the proteoform down?*

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `mode` | string | `off` \| `ambiguity` \| `coverage` \| `exhaustive` | `"off"` | The whole MS3 gate, and the choice of what MS3 chases: PTM-site-containing fragments, uncovered cleavage sites, or — under `exhaustive` (ADR-0023) — **every deconvolved mass of the winner MS2 scan**, mapped or not. |
| `protein_sequence` | string | any string; bare one-letter sequence, no header, **alphabet unvalidated** | `""` | The protein every MS2 identification and MS3 target choice is matched against. |
| `max_targets` | int | any int; `≤ 0` disables MS3 planning | `3` | Per-identified-precursor budget of distinct **fragments** given MS3. Under `exhaustive` it counts distinct **masses**, and it bounds *targets*, never commands — a CE sweep or `fragment_charges: separate` multiplies commands on top of it. |
| `min_fragment_charge` | int | any int; `≤ 0` disables the filter | `0` | Discards MS3 targets whose MS2 fragment charge falls below this. |
| `min_target_mass` | double | any double (Da); `0` = off | `0` | **`exhaustive` only** — deconvolved masses below this are not MS3 targets. Not inheritable from `deconvolution.min_mass`/`min_charge`: those floors do not reach MSn output, so a config with `min_mass: 500` still yields 248 Da MS2 species. Read but inert under the other three modes. |
| `fragment_charges` | string | `single` \| `separate` \| `multiplexed` (**not** lowercased on emit) | `"single"` | How much of a target fragment's charge envelope one MS3 covers. |
| `exploration` | object | the 11-key block above | `null` | An independent CE / reaction-time sweep for MS3. |

## `flashtnt`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `min_length` | int | **3–9**, enforced at tagger construction, not at load | `3` | Shortest de-novo sequence tag accepted. |
| `max_length` | int | **3–30**, enforced at tagger construction, not at load | `8` | Longest tag the search will build, and the section's main real-time cost knob. |
| `allow_gap` | bool | `true` / `false` | `false` | Lets a tag bridge one unexplained mass as a single gap unit, and gates `max_aa_in_gap`. |
| `max_aa_in_gap` | int | **2 or 3 only**, enforced at tagger construction, not at load | `2` | How many consecutive residues one gap may stand for. |
| `fixed_mod` | array\<string> | unvalidated; one modification per array element | `[]` | Nothing today — reaches both algorithm Params and neither reads it back. |
| `max_blind_mod_count` | int | any int | `2` | How many unspecified mass shifts the extender may invent per proteoform, and it multiplies `max_mod_mass` in every flanking bound. |
| `max_mod_mass` | double | any double (Da) | `700` | Largest absolute shift a single blind modification may carry. |

## `tagging`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `follow_up_scan` | string | `""` = none, else a key of `ms_settings.additional_ms2` | `""` | Names the MS2 config acquired as the conditional (`C`) follow-up when an MS2 yields tags. |
| `active` | bool | `true` / `false` | `false` | **Nothing** — accepted, never emitted, read only by a log formatter; `false` does not disable tagging. |
| `conditional_ms2` | bool | `true` / `false` | `false` | The nested spelling of the root key below; the root value wins whenever present. |

## `conditional_ms2` (root-level key)

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `conditional_ms2` | bool | `true` / `false`, at the **root** of `method.json`; `true` requires `tagging.follow_up_scan` | `false` | Fires the `tagging.follow_up_scan` MS2 whenever a returning MS2 yields sequence tags. |

## `quantification`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `enabled` | bool | `true` / `false` | `false` | Gates whether returning MS2 spectra are reporter-ion tested and can earn an `F` follow-up. |
| `reporter_mz_tol` | double | unchecked at load; enforced at first use as **0.0001–0.5 Th** | `0.0` † — **outside the legal range** | m/z half-window used to extract the reporter channels from a returning MS2. |
| `fold_change_threshold` | double | any double; applied as `fc > t \|\| 1/fc > t`, so `t ≤ 1` passes everything | `0.0` † | Minimum reporter-channel fold change, in either direction, before a precursor earns a follow-up. |
| `follow_up_scan` | string | `""` = none, else a key of `ms_settings.additional_ms2` | `""` | Names the MS2 config acquired as the quantification (`F`) follow-up. |
| `only_one_condition` | bool | `true` / `false` | `false` | **Nothing** — accepted, never emitted, no read site anywhere. |

## `faims`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `cv_values` | array\<double> | any doubles — sign, magnitude and duplicates all unvalidated; only the **length** carries meaning | `[-50]` † — **FAIMS on** | The compensation voltages the run uses; its length alone decides whether FAIMS runs at all. |
| `max_cv_skip` | int | any int; `≤ 0` disables skipping; inert with fewer than two CVs | `0` | Caps how many survey rounds a low-yielding CV is bypassed before being revisited. |
| `cv_precursor_threshold` | int | any int; `≤ 0` disables adaptive skipping; inert with fewer than two CVs | `15` | MS2-command count below which a CV counts as unproductive that cycle. |

| `cv_values` length | Behaviour |
|---|---|
| `[]` | FAIMS **off**, and actively commanded off (`FAIMS Voltages = "off"`) rather than left to the instrument method. |
| one CV | FAIMS on at a fixed voltage, with no cycling; both skip keys are inert. |
| two or more | FAIMS on and cycling; after each MS1 an extra survey is pushed at the next CV. |

## `ms_settings` — instrument parameters, and nothing that decides *whether* a scan happens

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `analyzer` | string | unvalidated; instrument names `Orbitrap`, `IonTrap` | `""` | Which mass analyzer records the scan. |
| `first_mass` | double | any double; `0` omits the key | `0` | Low end of the recorded m/z range. |
| `last_mass` | double | any double; `0` omits the key | `0` | High end of the recorded m/z range. |
| `resolution` | int | any int; `≤ 0` omits the key | `0` | Orbitrap resolving power. |
| `agc_target` | int | any int; `≤ 0` omits the key | `0` | Ion population the automatic gain control fills to. |
| `max_it` | double | any double (ms); `≤ 0` omits the key | `0` | Ceiling on injection time when the AGC target is not reached. |
| `microscans` | int | any int; `≤ 0` omits the key | `0` | How many acquisitions are averaged into one recorded spectrum. |
| `data_type` | string | unvalidated; instrument names `Centroid`, `Profile` | `""` | Whether peaks arrive centroided or as profiles. |
| `scan_rate` | string | unvalidated; `Normal`, `Enhanced`, `Zoom`, `Rapid`, `Turbo`; analyzer-side, never inherited | `""` | Ion-trap scan speed, meaningful only on `IonTrap`. |
| `activation` | string | **MSn only**; unvalidated and passed verbatim; only `HCD`/`CID`/`ETD`/`EThcD` are coupling-checked | `""` | Fragmentation method for this stage; the default `""` makes every command of that level be refused at build time. |
| `collision_energy` | int | **MSn only**; any int, but **> 0 required** for `HCD`/`CID`/`EThcD` | `0` | Normalized collision energy for the stage. |
| `reaction_time` | double | **MSn only**; any double (ms), but **> 0 required** for `ETD`/`EThcD` | `0` | Ion-ion reaction duration for ETD-family activation. |
| `reagent_max_it` | double | **MSn only**; any double (ms); **no** activation coupling enforced | `0` | Fill-time ceiling for the ETD reagent anions. |
| `reagent_agc_target` | int | **MSn only**; any int; **no** activation coupling enforced | `0` | Target reagent-anion population for ETD. |
| `rf_lens` | double | any double; `0` = **inherit the survey's value**; sent unconditionally | `0` | Source RF-lens amplitude, shared by the whole cycle. |
| `source_cid` | double | any double; `0` = **inherit the survey's value**; sent unconditionally | `0` | In-source CID energy applied before the analyzer, shared by the whole cycle. |
| `source_cid_scaling` | double | any double; `0` = **inherit the survey's value**; sent unconditionally | `0` | Mass-dependent scaling of in-source CID, shared by the whole cycle. |

| Scan object | Keys accepted | Notes |
|---|---|---|
| `ms1` | the 12 non-MSn keys | The five **MSn only** keys are rejected — a survey command carries no isolation stage. |
| `ms2` | all 17 | Fired once per MS1-selected precursor; always first in the level-2 roster. |
| `ms3` | all 17 | Required whenever `characterization.mode != "off"`; supplies stage 1 of the cascade. |
| `additional_ms2` | map of name → all 17 | Named extra MS2 configs; there is deliberately no `additional_ms3`. |

### `ms_settings.additional_ms2`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| *(map keys)* | string | `^[a-z][a-z0-9_]{0,31}$`, excluding `ms1 ms2 ms3 none off all`; enforced by **C++ only** | `null` | Names an extra MS2 scan config, which fires only where the name is referenced. |
| *(map values)* | object | the same 17 keys as `ms2`; validated by **C# only** | — | A full scan object; one referenced by nobody warns and is never acquired. |

## `scheduling`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `cycle_time.enabled` | bool | `true` / `false` | `false` | Arms a watchdog that forces a survey MS1 when none has run recently. |
| `cycle_time.value_ms` | double | any double | `60000` | Milliseconds without an MS1 before that watchdog queues one; suppressed during an exploration group. |
| `scan_timeout.enabled` | bool | `true` / `false` | `false` | Lets the queue discard commands that have waited too long to be dispatched. |
| `scan_timeout.value_ms` | double | any double | `30000` | Age in ms past which a queued command is dropped and logged `[TRACK-EXPIRE]`. |
| `agc_interval_seconds` | double | any double | `1` | How often an AGC prescan preempts the whole priority ladder. **The only thing that emits one** (ADR-0031) — a drained queue emits an idle survey MS1, not a prescan. Was `30`, but that never governed the real cadence: the drained-queue path emitted a prescan as filler *and* reset this timer with it. Committed test configs pin this at `9999999` so golden capture cannot depend on wall clock. |

## `files`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `target_logs` | array\<string> | paths; an unreadable file is **silently skipped** | `[]` | Prior-run logs supplying the mass lists that `in_depth` and `exclusion_masses` operate on. |
| `fasta` | string | path; non-empty must exist or engine construction fails | `""` | Turns on tag-based targeting by matching MS2 tags against these proteins. |
| `inclusion_list` | string | path; TSV, ≥ 5 columns (mass, charge, rt_start, rt_end, priority); RT in **minutes**, masses **monoisotopic** | `""` | Target masses that inclusion mode acquires ahead of everything else. |
| `ptm_list` | string | path; TSV, ≥ 3 columns (name, mass, max_count); throws at construction if unreadable | `""` | PTM rows that expand each FASTA-derived target mass into modified forms. |

## `runtime`

| Key | Type | Valid values | Default | What it does |
|---|---|---|---|---|
| `log_dir` | string | any string; absolute or relative to the **process** working directory | `""` | Base folder receiving this run's timestamped subfolder of five fixed-name log streams. |

## Where the C++ fallback disagrees with the effective default

| Key | Effective default (C#) | C++ fallback | Consequence |
|---|---|---|---|
| `deconvolution.score_threshold` | `-1` | `0.0` | None — both are ≤ 0, so neither gates. |
| `quantification.reporter_mz_tol` | `0.0` | `0.002` | The C# default is outside the legal range and throws at first use; the C++ one works. |
| `quantification.fold_change_threshold` | `0.0` | `1.4` | The C# default passes every spectrum; the C++ one filters. |
| `faims.cv_values` | `[-50]` — FAIMS **on** | empty — FAIMS **off** | A fixture omitting `faims` runs without it; a `method.json` omitting it runs at −50 V. |

## Combinations the loader rejects

| Change | Result |
|---|---|
| `deconvolution.tol` with fewer than 3 entries | throws — levels 1–3 are always materialised |
| `characterization.mode` not `off`, `protein_sequence` empty | throws |
| `characterization.mode` not `off`, `ms_settings.ms3` absent | throws — **C++ fixtures only**; from `method.json` it loads clean and dies at scan-build time |
| `rank_by` not `none`, `ms_settings.ms2` absent | throws — **C++ fixtures only**; same silent failure from `method.json` |
| `conditional_ms2: true`, `tagging.follow_up_scan` unset | throws |
| `ce_step ≤ 0`, or `reaction_time_step ≤ 0` with a reaction-time range | throws — the sweep loop would never terminate |
| `ce_min ≥ ce_max` with a CE-coupled activation | throws |
| `activation: ETD`/`EThcD` without `reaction_time > 0` | throws |
| `activation: HCD`/`CID`/`EThcD` with `collision_energy: 0` | throws |
| exploration active at a level dispatching more than one scan config | throws |
| a `follow_up_scan` name also listed in `additional_scans` | throws — it would fire twice at two priorities |
| a `follow_up_scan` or `additional_scans` name absent from `additional_ms2` | throws, listing the defined names |
| an `additional_ms2` key outside `^[a-z][a-z0-9_]{0,31}$` or reserved | throws — **C++ only**, so it passes the C# loader |
| `exploration.overrides` containing `tolerance_ppm` | throws — it is a first-class key |
| any unknown or PascalCase key | throws, naming the offender |
| `selection_strategy`, top-level `ms3`, `ms3_all_charges`, an inline `follow_up_scan` object | throws with a migration message |
| `characterization.max_targets: 0` with `mode` on | **loads clean and silently runs no MS3** |
| `ms_settings.ms2`/`ms3` as an **array** | **loads clean, silently discarded**, replaced by an all-default scan config |
| `faims` section omitted | **loads clean, FAIMS runs at −50 V** |
| `quantification.enabled: true` with no `follow_up_scan` | **loads clean and silently never acquires one** |

## Keys that load but do nothing

| Key | Status |
|---|---|
| `tagging.active` | Accepted, never emitted; read only by a log formatter. `false` does **not** disable tagging. |
| `quantification.only_one_condition` | Accepted, never emitted, **zero read sites** — the C++ branch it would drive is unreachable. |
| `tagging.conditional_ms2` | Accepted, but the root `conditional_ms2` overrides it whenever present. |
| `global.method_name`, `global.method_description` | Cross the bridge; no C++ struct field, no read site. |
| `flashtnt.fixed_mod` | Reaches both algorithms and is acted on by neither. |
| `precursor_selection.tie_threshold` | Inert unless `targeting: "inclusion"` **and** a TSV inclusion list actually loaded. |
| `precursor_selection.strict_inclusion` | Inert unless `targeting: "inclusion"`. |
| `precursor_selection.consider_all_charges` | Ignored when `rank_by` is `intensity`. |
| `faims.max_cv_skip`, `faims.cv_precursor_threshold` | Inert with fewer than two CVs. |
| `flashtnt.max_aa_in_gap` | Inert unless `allow_gap` is `true`. |
| `precursor_selection.tag_expansion.*` | Read only on the `files.fasta` path; a `protein_sequence` does not enable them. |
| `ms_settings.*.reagent_max_it`, `reagent_agc_target` | Not covered by activation coupling — an ETD scan with `0` loads clean and inherits the instrument method. |

# `method.json` options — every setting and its possible values

Derived from `FlashIDA/test-data/configs/method_eclipse_cytc_ambiguity.json`, and covering the whole
schema that config draws on — including the keys it leaves out.

**Bold** in the *Values* column marks the value that config actually uses. Sub-rows without a key
are further options for the key above them.

Source of truth, in the order it is applied:

| Stage | Owner |
|---|---|
| Which keys may be authored | `FlashIDA/src/Flash/MethodConfig.cs` + `IDA/MethodConfigSerializer.cs` (`[JsonKey]`) |
| What crosses the bridge | `FlashIDA/src/Flash/MethodParameters.cs` → `ToCppJson()` |
| Which values are legal | `OpenMS/.../TOPDOWN/FLASHIda/Config.cpp` → `Config::Config` + `Config::validate` |
| What reaches the instrument | `FlashIDA/src/Flash/ScanFactory.cs` → `BuildFromCommand` |

Four rules apply everywhere and are not repeated per key:

- **Unknown keys are a hard error on both sides**, and keys are case-sensitive snake_case — a typo
  fails the load rather than being ignored.
- **`0` / `""` on an analyzer-side scan parameter means "leave it to the instrument method"**, not
  "zero". The three source-region parameters are the exception (see `ms_settings`).
- **Enum *values* are case-sensitive in the engine.** FlashIDA lowercases four of them on the way out
  (`targeting`, `rank_by`, `characterization.mode`, `exploration.metric`), so `"Off"` survives a real
  run — but the same file handed straight to C++ throws. Author them lowercase.
- **A number is only a number.** `resolution: 120000` is passed through; nothing checks it against
  what the Orbitrap can do.

---

## `global`

| Key | Values | What it does |
|---|---|---|
| `method_name` | any string — **"Eclipse cytC - all proteoforms, ambiguity characterized"** | Free-text label that crosses the bridge and is read by nothing on either side. |
| `method_description` | any string | Same — documentation only. |
| `duration` | minutes, double — **120** | Arms the acquisition run timer in `Flash.cs` (`Duration × 60000` ms); the C++ engine never reads it. |

## `deconvolution`

| Key | Values | What it does |
|---|---|---|
| `score_threshold` | 0.0–1.0 — **0.0** | QScore floor: the ranked candidate list is cut at the first mass scoring below it, so `0.0` means "never cut". |
| `tqscore_threshold` | 0.0–1.0 — **0.0** | Cumulative-evidence ceiling: once a mass's accumulated `1 − ∏(1 − qscore)` exceeds it the mass stops being re-selected, and `0.0` makes that immediate. |
| `min_charge` | integer — **4** | Lowest charge state the deconvolution engine will build an envelope from. |
| `max_charge` | integer — **50** | Highest charge state it will build an envelope from. |
| `min_mass` | Da — **500** | Lowest monoisotopic mass reported. |
| `max_mass` | Da — **50000** | Highest monoisotopic mass reported. |
| `tol` | array of **≥ 3** ppm values — **[10, 10, 10]** | Mass tolerance per MS level, indexed `tol[level−1]`; fewer than three entries is an unloadable config because levels 1–3 are always materialised. |

## `flashtnt`

Tuning for FLASHTagger and FLASHExtender — the only sanctioned channel into them.

| Key | Values | What it does |
|---|---|---|
| `min_length` | integer — **3** | Shortest sequence tag the tagger will emit. |
| `max_length` | integer — **8** | Longest sequence tag the tagger will emit. |
| `allow_gap` | `true` / **`false`** | `true` lets a tag bridge a mass gap instead of requiring consecutive residues. |
| `max_aa_in_gap` | integer — **2** | How many residues one gap may span; the tagger reads it only when `allow_gap` is `true`. |
| `fixed_mod` | array of mod names — **[]** | Intended as the tagger's and extender's fixed modifications, but neither acts on it today — see below. |
| `max_blind_mod_count` | integer — **2** | How many unspecified ("blind") modifications the extender may invent per proteoform. |
| `max_mod_mass` | Da — **700** | Largest absolute mass a blind modification may take. |

Every key here is a genuine FLASHTagger/FLASHExtender parameter. The two that were **not** —
`max_ptm_count` and `max_flanking_mass_diff` — moved to `precursor_selection.tag_expansion`, because
they drive a FLASHIda feature rather than FLASHTnT.

`max_aa_in_gap` is dormant unless `allow_gap` is `true` — the tagger consults it nowhere else.

`fixed_mod` is inert **whatever you set it to**. `FLASHTaggerAlgorithm` declares the parameter and
never reads it; `FLASHExtenderAlgorithm` reads it into a local that is then unused. FLASHIda now
passes it unconditionally, so it will start working the moment those algorithms do — but today it
changes nothing. Both live in off-limits FLASHTnT code, so this is reported, not fixed.

## `conditional_ms2` (root-level key)

| Key | Values | What it does |
|---|---|---|
| `conditional_ms2` | `true` / **`false`** | `true` fires the `tagging.follow_up_scan` MS2 whenever a returning MS2 yields tags, and requires that key to name something or the load throws. |

> A nested `tagging.conditional_ms2` is *accepted* by the C# loader but is silently overridden
> whenever the root key is present — which it is in every committed config. Use the root key.

## `faims`

| Key | Values | What it does |
|---|---|---|
| `cv_values` | **`[]`** | FAIMS off, and actively commanded off rather than left to the instrument method. |
| | one CV, e.g. `[-45]` | FAIMS on at a fixed compensation voltage, with no cycling. |
| | two or more | FAIMS on and cycling through the listed voltages. |
| `max_cv_skip` | integer — **0** | Caps the skip spacing an unproductive CV can accumulate (it doubles each time), so `0` means never skip. |
| `cv_precursor_threshold` | integer — **15** | Precursor count strictly below which a CV counts as unproductive that cycle. |

Both skip keys are inert unless `cv_values` has **two or more** entries — with a single CV there is
nothing to skip to.

## `scheduling`

| Key | Values | What it does |
|---|---|---|
| `cycle_time.enabled` | `true` / **`false`** | `true` arms a watchdog that forces a survey MS1 when none has run recently. |
| `cycle_time.value_ms` | ms — **60000** | How long the engine may go without an MS1 before that watchdog fires. |
| `scan_timeout.enabled` | `true` / **`false`** | `true` lets the queue discard commands that have waited too long to be dispatched. |
| `scan_timeout.value_ms` | ms — **30000** | How long a command may sit in the queue before it is dropped and logged as `[TRACK-EXPIRE]`. |
| `agc_interval_seconds` | seconds — **30** | How often an AGC calibration scan is issued; converted to ms internally. |

## `files`

| Key | Values | What it does |
|---|---|---|
| `target_logs` | array of paths — **[]** | Previous-run logs supplying the mass lists that `in_depth` and `exclusion_masses` operate on. |
| `fasta` | path — **`""`** | Loaded via `FASTAFile` for tag matching, and doubles as the `matched_protein` label in the identification logs when set. |
| `inclusion_list` | path — **`""`** | TSV of target masses, parsed only when `targeting` is `inclusion`. |
| `ptm_list` | path — **`""`** | TSV of PTMs to look for; empty means PTMs are discovered from the fragment ladder instead. |

## `precursor_selection` — *which species do we fragment?*

| Key | Values | What it does |
|---|---|---|
| `rt_window` | seconds — **180** | How long a detected mass stays remembered for exclusion and targeting before it may be picked again. |
| `targeting` | **`none`** | Plain DDA — no external mass list is consulted. |
| | `inclusion` | Masses from `files.inclusion_list` are matched and prioritised. |
| | `in_depth` | Masses already well covered in `files.target_logs` are *de-prioritised* on the first pass — a soft reorder that iteration 1 back-fills, so it only bites when the per-scan slot budget is contended. |
| | `exclusion_masses` | Masses listed in `files.target_logs` are hard-skipped and never selected. |
| `strict_inclusion` | `true` / **`false`** | `true` restricts acquisition to inclusion-list matches only; `false` lets unmatched masses fill the remaining slots. |
| `tie_threshold` | score delta — **0.1** | QScore gap below which two candidates count as tied, letting inclusion-list priority decide the order — inert unless `targeting` is `inclusion` with targets loaded. |
| `consider_all_charges` | `true` / **`false`** | `true` ranks the survey by QScore across every observed charge state rather than one representative charge per mass. |
| `charge_based_exclusion` | `true` / **`false`** | `true` makes exclusion `(mass, charge)`-scoped so other charge states of the same mass stay selectable. |
| `rank_by` | **`qscore`** | Ranks MS1 candidates by deconvolution quality score. |
| | `intensity` | Ranks them by raw intensity. |
| | `none` | Disables MS1 selection entirely — the run acquires surveys and nothing else. |
| `max_precursors` | integer — **5** | Maximum MS2 precursors selected from one survey. |
| `min_precursor_charge` | integer, `0` = off — *(omitted, so 0)* | Charge floor below which a precursor is not selected. |
| `additional_scans` | array of `additional_ms2` names — *(omitted, so empty)* | Extra MS2 configs fired for every selected precursor, in the order listed, after `ms_settings.ms2`. |

### `precursor_selection.tag_expansion` — the FASTA target-expansion knobs

This feature observes a returning MS2, tags it, matches it against a **protein database**, enumerates
PTM variants of the precursor mass, and adds those as new MS1 targets. It is gated entirely on
`files.fasta`: `characterization.protein_sequence` does **not** enable it, because the database
vector has exactly one filler, `FASTAFile().load(files.fasta, …)`. With no FASTA, both keys below are
dormant.

| Key | Values | What it does |
|---|---|---|
| `max_ptm_count` | integer — *(omitted, so 3)* | Caps the PTMs in one enumerated target mass; also needs `files.ptm_list`, without which nothing is enumerated at all. |
| `max_flanking_mass_diff` | Da — *(omitted, so 50000)* | Largest unexplained flanking mass a tag may sit next to when matched against a database protein. |

On the `characterization.protein_sequence` path neither applies. That path still bounds flanking
mass, but with a different quantity: the extender computes `max_mod_mass × max_blind_mod_count + 1`,
so widen it via those two keys rather than this one.

### `precursor_selection.exploration` — the MS2 CE/reaction-time sweep

Requires the level to dispatch exactly one scan config, so it is mutually exclusive with a populated
`additional_scans`.

| Key | Values | What it does |
|---|---|---|
| `metric` | `none` | No sweep — one MS2 per precursor at the configured collision energy. |
| | `mass_count` | Picks the variant yielding the most deconvolved masses. |
| | `remaining_precursor` | Picks the variant leaving the least unfragmented precursor, targeting `remaining_precursor_target`. |
| | **`fragment_count`** | Picks the variant matching the most fragment ions against `characterization.protein_sequence`, which it therefore requires. |
| `ce_min` | NCE — **15** | Lowest collision energy in the sweep. |
| `ce_max` | NCE — **50** | Highest collision energy in the sweep; must exceed `ce_min` for a CE-coupled activation. |
| `ce_step` | NCE, **must be > 0** — **1** | Sweep increment; a non-positive value is rejected because it would spin forever inside `processScan`. |
| `activations` | array — **["HCD"]** | Activation types to sweep across; empty falls back to the base scan config's own activation. |
| `overrides` | string→**string** map — *(omitted)* | Per-field scan-config overrides applied to every variant; values must be JSON strings, and unknown keys are dropped silently. |
| `remaining_precursor_target` | ratio — *(omitted, 0.1)* | The remaining-precursor fraction `remaining_precursor` aims at. |
| `reaction_time_min` | ms — *(omitted, 0)* | Lowest ion-ion reaction time in an ETD-family sweep. |
| `reaction_time_max` | ms — *(omitted, 0)* | Highest reaction time; must exceed the minimum when an ETD-family activation is swept. |
| `reaction_time_step` | ms, **> 0** — *(omitted, 1)* | Reaction-time increment, rejected at ≤ 0 for the same non-termination reason as `ce_step`. |
| `tolerance_ppm` | ppm, `0` = inherit — *(omitted, 0)* | Mass tolerance used when scoring variants; `0` falls back to `deconvolution.tol` for that level. |

> **`overrides` carries a second, undocumented effect: its emptiness changes the acquisition
> topology.** With the map empty the sweep winner descends straight into MS3 characterization; with
> *any* entry present the engine instead re-acquires one production MS2 at the winning energy first,
> and MS3 follows a scan later. Adding a cosmetic override such as `{"resolution": "60000"}` silently
> takes the other branch, with no error and no log line.

## `characterization` — *whether and how do we pin the proteoform down?*

| Key | Values | What it does |
|---|---|---|
| `mode` | `off` | No MS3 at all, whatever else is configured. |
| | **`ambiguity`** | Runs MS3 on fragments that bracket an unresolved PTM site. |
| | `coverage` | Runs MS3 on fragments that extend sequence coverage. |
| `protein_sequence` | amino-acid string — **cytochrome C** | The sequence MS3 fragments are matched against; required, and non-empty, whenever `mode` is not `off`. |
| `max_targets` | integer — **3** | The MS3 budget per identified precursor; `0` loads fine and silently disables MS3 while leaving `mode` looking on. |
| `min_fragment_charge` | integer, `0` = off — *(omitted, so 0)* | Charge floor an MS2 fragment must clear to become an MS3 target. |
| `ms3_all_charges` | `true` / *(omitted, so `false`)* | `true` dispatches one MS3 per observed charge state of a target fragment instead of the single best charge. |
| `exploration` | same keys as above — *(omitted)* | An independent CE/reaction-time sweep for MS3, so MS2 and MS3 can sweep different ranges. |

`ms_settings.ms3` must exist whenever `mode` is not `off` — the MS3 builder reads `scans[0]`
unguarded. It is permitted but inert when `mode` is `off`, so switching MS3 off stays a one-word edit.

## `ms_settings` — instrument parameters, and nothing that decides *whether* a scan happens

The same 17-key vocabulary applies to every scan object, except that `ms1` **rejects** the five
stage-borne keys (`activation`, `collision_energy`, `reaction_time`, `reagent_max_it`,
`reagent_agc_target`) — a survey command carries no isolation stage, so they could never reach it.

| Key | Values | ms1 / ms2 / ms3 here | What it does |
|---|---|---|---|
| `analyzer` | `Orbitrap`, `IonTrap` | **Orbitrap** / **Orbitrap** / **Orbitrap** | Which mass analyzer records the scan; not validated by FLASHIda, so a misspelling reaches the instrument. |
| `first_mass` | m/z | **500** / **100** / **200** | Low end of the recorded m/z range. |
| `last_mass` | m/z | **2000** / **2000** / **2000** | High end of the recorded m/z range. |
| `resolution` | integer | **120000** / **120000** / **240000** | Orbitrap resolving power. |
| `agc_target` | integer | **800000** / **500000** / **50000000** | Ion count the automatic gain control fills to. |
| `max_it` | ms | **246** / **100** / **500** | Ceiling on injection time when the AGC target is not reached. |
| `microscans` | integer | **1** / **4** / **8** | How many micro-scans are averaged into one recorded spectrum. |
| `data_type` | `Centroid`, `Profile` | **Centroid** / **Centroid** / **Centroid** | Whether peaks arrive centroided or as profiles; also unvalidated. |
| `scan_rate` | `Normal`, `Turbo`, `Rapid`, `Enhanced`, `Zoom` | omitted everywhere | Ion-trap scan rate, meaningful only on `IonTrap`; analyzer-side, so it never inherits. |
| `activation` | `HCD`, `CID` | — / **HCD** / **CID** | Fragmentation method, and each carries its own required companion parameter. |
| | `ETD`, `EThcD` | | ETD-family, and the load throws unless `reaction_time > 0` travels with it. |
| | others, e.g. `UVPD` | | Passed through uncoupled — no parameter is required and none is checked. |
| `collision_energy` | NCE integer, **> 0 for HCD/CID/EThcD** | — / **30** / **25** | Normalized collision energy for the collision-based activations — but see the note on MS2 below. |
| `reaction_time` | ms, **> 0 for ETD/EThcD** | omitted | Ion-ion reaction time. |
| `reagent_max_it` | ms | omitted | Injection-time ceiling for the ETD reagent ions. |
| `reagent_agc_target` | integer | omitted | AGC target for the ETD reagent ions. |
| `rf_lens` | %, `0` = inherit survey | **30** / inherits 30 / inherits 30 | RF lens amplitude — a source-region parameter, so an MSn scan that leaves it at `0` runs at the survey's value. |
| `source_cid` | eV, `0` = inherit survey | **15** / inherits 15 / inherits 15 | In-source CID energy, inherited the same way. |
| `source_cid_scaling` | factor, `0` = inherit survey | **0** / inherits 0 / inherits 0 | Scaling applied to source CID; `0` is its correct real value and is commanded, not omitted. |

> **In this config `ms2.collision_energy: 30` never reaches the instrument.** MS2 exploration is
> active, so every dispatched MS2 is a sweep variant carrying a CE from the 15–50 range; the authored
> 30 survives only as the value that satisfies the "HCD needs `collision_energy > 0`" load gate. Set
> `precursor_selection.exploration.metric` to `none` and it becomes the real MS2 energy again.
> `ms3.collision_energy: 25` is unaffected — `characterization.exploration` is not configured here.

### `ms_settings.additional_ms2`

| Key | Values | What it does |
|---|---|---|
| *(map keys)* | `^[a-z][a-z0-9_]{0,31}$`, excluding `ms1 ms2 ms3 none off all` — *(omitted)* | Names extra MS2 scan configs, which fire only where a name is referenced; the pattern is enforced by C++ only, so a bad name passes the C# loader and throws at the bridge. |
| *(map values)* | a full scan object | Same 17 keys as `ms2`, key-checked on both sides; a defined-but-unreferenced entry warns at load and is never acquired. |

There is deliberately no `additional_ms3` — every level-3 consumer reads `scans[0]`, so a second MS3
config could never be reached. A name used in both `additional_scans` and a `follow_up_scan` is
rejected, because it would fire twice per precursor at two different priorities.

## `tagging`

| Key | Values | What it does |
|---|---|---|
| `follow_up_scan` | an `additional_ms2` name — *(**`{}`** here, so none)* | Names the MS2 config acquired as the conditional (`C`) follow-up; required when `conditional_ms2` is `true`. |
| `active` | `true`/`false` | Accepted by the loader, never emitted, read only by a log-formatting helper — it changes nothing. |
| `conditional_ms2` | `true`/`false` | Accepted, but overridden by the root `conditional_ms2` whenever that is present. |

## `quantification`

| Key | Values | What it does |
|---|---|---|
| `enabled` | `true` / **`false`** | `true` runs isobaric reporter-ion quantification on returning MS2 scans, and needs `follow_up_scan` to name a config for it to act on. |
| `reporter_mz_tol` | Da — **0.002** | Match window for reporter-ion m/z. |
| `fold_change_threshold` | ratio — **1.4** | Fold change above which a target is considered differentially abundant. |
| `follow_up_scan` | an `additional_ms2` name — *(omitted)* | Names the MS2 config acquired as the quantification (`F`) follow-up. |
| `only_one_condition` | `true`/`false` | Accepted by the loader, never emitted, and read nowhere — it changes nothing. |

## `runtime` *(omitted by this config)*

| Key | Values | What it does |
|---|---|---|
| `log_dir` | folder, **`""`** | Folder that receives **every** log file. Empty means `.` — the process working directory. |

Each run gets its own subfolder inside `log_dir`, holding all seven files under fixed names:

```
<log_dir>/sample_042_2026-08-09-14-33-02/    <- "<-r value>_<stamp>", or "<stamp>" with no -r
    ida.log                     scan_commands.tsv        scan_results.tsv
    identification.tsv          pooled_identification.tsv
    FlashLog.log                IDALog.log
```

There is no way to disable a stream and no way to place one somewhere else — the five per-stream
path keys were deleted, and a config still carrying one is rejected with a migration error. The
timestamp is minted once per process, so all seven files necessarily agree. If the folder cannot
be created the run exits 1 before touching the instrument. See
[ADR-0015](adr/0015-log-dir-is-resolved-host-side.md).

---

## Combinations the loader rejects

Each was reproduced against this config; all of them are load-time errors, not runtime surprises.

| Change | Result |
|---|---|
| `deconvolution.tol` with 2 entries | throws — levels 1–3 are always materialised |
| `characterization.mode` not `off`, `protein_sequence` empty | throws |
| `characterization.mode` not `off`, `ms_settings.ms3` absent | throws — the MS3 builder would read out of bounds |
| `rank_by` not `none`, `ms_settings.ms2` absent | throws |
| `conditional_ms2: true`, `tagging.follow_up_scan` unset | throws |
| `ce_step: 0`, or `reaction_time_step: 0` with a reaction-time range | throws — the sweep loop would never terminate |
| `ce_min ≥ ce_max` with a CE-coupled activation | throws |
| `activation: ETD` without `reaction_time` | throws |
| `activation: HCD` with `collision_energy: 0` | throws |
| exploration active at a level dispatching more than one scan config | throws |
| any unknown or PascalCase key | throws, naming the offender |
| `selection_strategy`, top-level `ms3`, `ms2`/`ms3` as arrays, an inline `follow_up_scan` object | throws with a migration message |
| `characterization.max_targets: 0` with `mode` on | **loads clean and silently runs no MS3** |

To check a config before running it: `uv run python .claude/skills/validate-flashida-config/validate.py <config.json>`.

---

## How this was validated

Every setting above was pushed along the whole path — *authored → C# loader → `ToCppJson` → bridge
JSON → `Config.cpp` → an engine read site* — by three independent means. Nothing here is asserted
from a doc comment.

**1. The C# half was executed, not read.** `MethodConfig.cs`, `MethodParameters.cs` and
`MethodConfigSerializer.cs` were compiled standalone on the .NET 8 SDK behind a
`JavaScriptSerializer` shim, so the real loader and emitter could be run without net48 or the Thermo
DLLs. The shim is not taken on trust: the harness regenerates
`FlashIDA/test-data/config_schema_reference.json` through the real
`GenerateReferenceConfigJson()` and reproduces the committed file **byte-for-byte**, and CI pins that
file to the output of the genuine serializer.

Every setting — the ones this config authors and the schema-legal ones it omits — was then mutated to
a distinctive value and the emitted bridge JSON diffed against the baseline. All but three changed it
at exactly the expected wire path; three never changed it at all.

**2. Value legality was exercised** — every option of every enum, plus a deliberately bogus one, and
seventeen edge cases — through `validate-flashida-config`, which reproduces `Config::validate()`.
That is the source of the rejection table above.

**3. Engine consumption was traced and then attacked.** A 16-agent workflow traced all 116 keys to a
read site, and a second adversarial pass re-opened every cited `file:line` with instructions to
refute. 103 verdicts came back, all confirmed, and the pass corrected several anchors and one
overstated consequence along the way.

The C++ half could not be *run*: the committed `FlashIDA/dll/OpenMS.dll` predates this schema and
still demands the deleted `selection_strategy`, and this workspace cannot build either project. CI
remains the only end-to-end execution gate.

### What the sweep found

| Setting | Finding |
|---|---|
| `tagging.active` | Loads, is never emitted, and is read only by a log formatter — it does nothing. |
| `quantification.only_one_condition` | Loads, is never emitted, and has no read site anywhere. |
| `tagging.conditional_ms2` | Loads, but the root `conditional_ms2` overwrites it whenever present. |
| `global.method_name`, `global.method_description` | Cross the bridge; no C++ struct field, no read site. |
| `flashtnt.fixed_mod` | Reaches both algorithms and is acted on by neither. |
| `precursor_selection.tag_expansion.*` | Live keys, but read only by the `files.fasta` path — a `protein_sequence` does not enable them. |
| `flashtnt.max_aa_in_gap` | Live key, dormant unless `allow_gap` is `true`. |
| `ms_settings.ms2.collision_energy` | Displaced by the active CE sweep — see the note in `ms_settings`. |
| `precursor_selection.exploration.overrides` | Emptiness silently selects the post-sweep acquisition branch. |

Every other setting in this document resolves end to end: authored, emitted, parsed, and read at a
site that changes what the instrument does or what is logged.

# Plan — `@Claude` refactor comments, two-phase (golden-neutral vs golden-moving)

_Branch: `august_pre`. Source: OpenMS commit `c3b11b7225 "add refactor comments"` (6 files, +145/−218).
Engine (FLASHDeconv + FLASHTnT/FLASHExtender) is UNTOUCHABLE. 2048-byte `ScanCommand` ABI + 5 bridge exports unchanged._

---

## TL;DR (plain language)

- The commit is ~99% **not code**: variable renames, stripped comments, and `@Claude …` TODO markers. Exactly **one** runtime change already landed (baseline prepended to every exploration) + one debug `cout` removed.
- We split the whole TODO backlog by **golden-file impact**. Two buckets, delivered as **one push** (working agreement).
- **Phase 1 = byte-identical.** ~45 markers: rename methods/vars, make `ProteoformTracker` the *identification authority* (Exploration keeps *scoring* and consults it), fold push-loops into `initiate()`, source `faims_cv` from context, collapse `window_snr` stamping, drop dead code. **No golden may move.** Any move that can't stay identical → STOP + re-plan as Phase 2.
- **Phase 2 = 3 changes that move goldens:** (1) baseline on *every* exploration metric; (2) MS2 isolation-width floor dropped (2.0 only for MS3+); (3) winner-batch MS3 identification rows carry *per-scan* tic.
- Delivery: all C++ (no C# code change — internal only, no ABI drift) in one push → iterate to **green-except-goldens** → golden-inconsistency validation workflow → **recapture (with your sign-off)** → final Windows-green.
- Tests: renames touch 6 C++ test files (identifiers only). **No test assertion changes in Phase 1.** Phase 2 recaptures goldens. Every test enumerated below for sign-off.

```
                         @Claude markers (~50)
                                 │
        ┌────────────────────────┴─────────────────────────┐
   PHASE 1  (byte-identical)                        PHASE 2 (goldens move)
   ├─ renames (feedScan STAYS)                       ├─ #18 baseline on all metrics
   ├─ #46 tracker = id authority ─┐                  ├─ #19 MS2 iso-width floor → MS3-only
   │   Exploration = scoring ─────┘ consults          └─ #14 winner-batch per-scan tic
   ├─ faims/push-loops → initiate()                          │
   ├─ window_snr / proforma / scores → builders             ▼
   └─ no-ops: has_scan_row, guard, CE-else, ...      recapture goldens (sign-off)
                    │                                        │
                    └──────────── one push ──────────────────┘
                                    ▼
                     green-except-goldens → validate → recapture → green
```

---

## Working agreement (carried forward from the prior plan)

1. **One push.** Combine ALL code (C++; no C# code change) into a single push; iterate to **green-except-goldens** (working-agreement compliant) before touching any golden.
2. **Validate before recapture.** Run the golden-inconsistency validation workflow BEFORE recapturing any golden; recapture only the streams Phase 2 legitimately moves.
3. **Recapture needs sign-off.** No golden is regenerated without your explicit go-ahead, per stream.
4. **Issues trigger re-plan.** During execution, ANY failure/surprise (a "Phase-1" move that shifts a golden, a broken test) → STOP, re-enter plan mode, present the fix (TL;DR / what-broke / offending-code / written-fix / pseudocode), get approval. No autonomous fix-iteration.
5. **Test changes need this plan's sign-off.** Every test touched is enumerated below; Phase 1 is renames only (no assertion edits).
6. **Root-cause, not workaround.** Fix the engine, not the test. Never touch FLASHDeconv/FLASHTnT.

---

## PHASE 1 — byte-identical refactors (no golden may move)

**Contract:** every item below must reproduce the current TSV logs bit-for-bit. Where a marker's anchor is verified as a no-op in this plan, that verification is stated. Where care is required, the exact invariant is called out. Anything that can't hold the line escalates to Phase 2.

### 1.1 Renames (identifiers only)

> **TL;DR:** rename for clarity; `feedScan` deliberately keeps its name (it stages MS2 *and* MS3).
> `before: pid, scan_row, ctx, model(), finalize(), emitRow_()  →  after: precursor_id, results_row, parent_ctx, getModel(), finalizeMS2(), emitPooledIDRow()`

| # | File | Rename | Note |
|---|---|---|---|
| — | FLASHIda.cpp | `ctx` → `parent_ctx` | resolved value is the parent scan's context |
| — | FLASHIda.cpp | `scan_row` → `results_row` | matches `scan_results.tsv` |
| — | FLASHIda.cpp | MS3-branch `pid` → `precursor_id` | MS2 branch already renamed in the commit; fixes the inconsistency |
| #48 | ProteoformTracker.cpp | `finalize` → `finalizeMS2` | genuinely MS2-only (MS3 folds via `foldMs3`) |
| #49 | ProteoformTracker.cpp | `emitRow_` → `emitPooledIDRow` | it writes the pooled trajectory row |
| #50 | ProteoformTracker.cpp | `model` → `getModel` | accessor |
| #9/#11 | FLASHIda.cpp | `ms3_context_cache` → `ms2_context_cache` (+ name the key/value: `scan_id → ctx`) | the cache holds MS2 contexts keyed by child scan id |
| #47 | ProteoformTracker.cpp | **`feedScan` — NOT renamed** | stages both MS2 and MS3 pending scans; `feedMS2Scan` would be wrong. |
| #45 | IdaLogger.cpp | drop redundant `tracking_id` string param on `writeIDALogEntry` | derive `encode(scan_number)` inside — **invariant:** `encode(scan_number) == parent_id_str` (round-trip of `decode`). |

### 1.2 `#46` — MOVED TO PHASE 2 (§2.4)

> **Decision 2026-07-06:** `#46`'s real goal (avoid the double-identification rerun) is **not** byte-identical
> — collapsing the MS3-FragmentCount per-variant `:1037` pass into the calibrated `:499` pass moves goldens
> (non-completing variants log the pre-calibration value). So `#46` (relocate calls into the tracker **and**
> remove the rerun) is done in **Push 2** with recapture. See §2.4. Phase 1 no longer touches identification
> ownership; the folded markers (`#16`/`#34`/`#37`–`#40`/`#10`/`#41`) move with it.

<details><summary>original Phase-1 framing (superseded)</summary>

`ProteoformTracker` is the identification authority; Exploration is the scoring authority

> **TL;DR:** move the *matching* (identification) into the tracker; leave the *scoring* (metric + winner pick) in Exploration, which now **consults** the tracker for fragment-derived numbers.
> ```
> before:  Exploration.computeExplorationScore_  → getTopFragmentMatches (runs id itself)
>          Exploration (:499)                    → calibrateAndScore     (runs id itself)
>          FLASHIda (:557)                        → calibrateAndScore     (runs id itself)
> after:   tracker.identify…()  ← single owner of FragmentAnalysis / MS3FragmentMatcher
>          Exploration.computeExplorationScore_  → consults tracker for match/frag-count, keeps metric math
> ```

**Scope of the move** (the three matcher call-sites become tracker consults):

| Site | Today | After |
|---|---|---|
| `Exploration.cpp:311`/`:1037` per-variant `getTopFragmentMatches` | Exploration runs id | tracker runs id; Exploration reads the match back and computes the metric score |
| `Exploration.cpp:499` MS3-FragmentCount batch `calibrateAndScore` | Exploration runs the calibrated batch id | tracker exposes a **"score/identify all variants"** interface returning every variant's match; **calibrated value stays canonical/logged** |
| `Exploration.cpp:734` `getTopFragmentMatches` in `initiateNextLevel` (MS2 `'R'` id row + target selection) | Exploration runs id | tracker runs id; `nlr.proteoform_match` reads the tracker's match |
| `FLASHIda.cpp:557` returning-MS3 `calibrateAndScore` | FLASHIda runs id | tracker consult |

**Hard invariants — the marker text actively steers toward violating these; each is enforced by the step-3 validation gate (any non-#18/#19/#14 golden diff = a leak = escalate):**
- **I-46a.** The MS3-FragmentCount **calibrated** batch value stays authoritative: `info.identification_result`/`info.score` come from the batch overwrite (`:499`→`:511-514`→`:518-519`), **never** the per-variant `getTopFragmentMatches` at `:1037` — those use a *different tolerance* (`exploration_tolerance_ppm` vs the batch's `LOOSE_TOLERANCE_PPM` + level tol) and no MS3-subsequence calibration, so substituting them moves goldens.
- **I-46b — HIGHEST RISK.** **Winner-only fold preserved.** Keep the `group.msn_level==2` gate at `Exploration.cpp:395` and the winner-only feed at `:647-665`; staging variant scans for *scoring/consultation* must NOT enter the `m.pending` set that `foldMs3` sweeps (`ProteoformTracker.cpp:280`, `for(ps: m.pending) mapScanOntoModel_`). Non-winner variants entering `m.pending` would move `pooled_identification` `n_fragments`/`coverage_pct`/`contributing_scan_ids`/`combined_*`/`update_index`. Variant matches live in a scoring-scoped buffer. _The marker comments (`ProteoformTracker.cpp:49`, `Exploration.cpp:394` "also what about MS3") literally read as "stage all variants" — do not._
- **I-46c.** `initiateNextLevel` must preserve the exact `getTopFragmentMatches(tol=0.0)` result (`:734`→`:773`), so `nlr.proteoform_match` (MS2 `'R'` row at `FLASHIda.cpp:412`, plus `tag_count`, `proto_ctx`, and the derived `ms3_proteoform`/`ms2_context_cache`) is unchanged.
- **I-46d.** `info.fragment_count` is copied at `:388` **before** the calibrate overwrite and not re-synced at `:518-519`; any reorder must preserve that currently-logged (pre-calibration) value.

Related structural markers folded in here: `#16` (MS3 id integrated into tracker), `#34`/`#37`/`#38`/`#39`/`#40` (selection/proto_ctx/nlr metadata move into tracker), `#10` (MS3-without-exploration is *already* the `Exploration.cpp:873` fixed-CE `else` — this is about moving the dispatch authority to the tracker, not a new feature), `#41` (bail early if no model).

</details>

### 1.3 `faims_cv` sourcing + fold push-loops into `initiate()` + atomics

> **TL;DR:** stop hand-stamping `faims_cv` and hand-pushing commands at the call sites; source CV from the context, push inside `initiate()`.
> `before: for(c: cmds){ c.faims_cv=…; queue.push(c); ms2_commands.push_back(c);}  →  after: initiate() pushes; caller just logs`

- `#4/#6/#23/#33` — `faims_cv` sourced from the (MS1) context object, not re-passed. **Invariant:** identical CV value (verified: the ground-truth drive echoes the drained command's `faims_cv` back as the `processScan` arg, and `ctx == that drained command` via `resolvePending`, so `ctx.faims_cv == param`).
- `#5/#7` — fold the `queue_.push` loops into a **shared push helper**. **CORRECTION (verification):** do **NOT** route the normal DDA MS2 `else` path through `exploration_.initiate()` as the `FLASHIda.cpp:226` marker literally reads — `initiate` early-returns empty for non-exploration (`Exploration.cpp:123`) and injects baseline/`'E'`-marker/`variant_tracking_map_` registration. Extract a shared push helper both paths call. **Invariant I-13:** identical `ScanCommand`s pushed in **identical order** (equal-priority drain is FIFO, `ScanCommandQueue.cpp:446/:456`, so push order == drain order == `scan_commands` row order == `child_ids`), and `ms2_commands` populated in identical order.
- `#8` — **CORRECTION (verification):** keep `exploration_active_.store(activeGroupCount()>0)` **unconditional at the processScan-return point** (`FLASHIda.cpp:268`); do **not** move it behind `initiate()`'s early returns, or a skipped store leaves a stale flag and a cycle-time MS1 `scan_commands` row appears/disappears (read at `getNextScanCommand:671`).

### 1.4 Value-preserving moves into the scan builders

> **TL;DR:** the builders (`buildMS2`/`buildMS3`) should own the stamping that call sites currently duplicate; collapse the per-level `window_snr` branches into one by inferring the stage index from the MS level.
> `before: if(num_stages>=2) snr over stages[1]; else if(>=1) snr over stages[0]  →  after: snr over stages[msLevelStageIndex]`

- `#24` — collapse `window_snr` stamping into one block. **Invariant (verification):** keep the **per-stage signal field** (`precursor_intensity` for stage[0]/MS2, `precursor_intensity_s1` for stage[1]/MS3) **and each caller's own source spectrum** (`raw_ms1` / `source_spectrum` / `result.getOriginalSpectrum()`); a single-signal or single-source collapse moves `identification.tsv` `ms2/ms3_window_snr`. Keep the `num_stages`/null-source guards.
- `#22` — move `MS3FragmentMatcher::fragmentProForma` inside `buildMS3`. **Invariant:** at the winner path, `buildMS3` receives the command (which carries no `proto_ctx`) — **forward `group.proteoform_ctx` explicitly**, don't derive it from the command, or `ms3_proteoform` changes.
- `#32` — **CORRECTION (verification, HIGHEST RISK in this section):** keep `buildMS3`'s explicit `frag_scores` param; only tighten the **winner path**'s `wfs = wcmd.*_s1` construction. Do **NOT** generalize "read `_s1` from the handed ms2 command" into the `buildMS3` body — the other two callers (`Exploration.cpp:187` variant, `:878` single-MS3) hand a genuine MS2 command whose `_s1` fields are zero-initialised, which would flip the post-`;` `mono_mass_s1`/`qscore_s1`/`snr_s1` to `0` on every exploration/single-MS3 `scan_commands` row.
- `#25` — move tracking-id `encode`/`v.tracking_id` into the builders; identical id string (safe: `encode` is deterministic on `cmd.scan_id`, already computed in the builders).
- `#36` — the `parent_scan_id` backfill loop (`Exploration.cpp:673-677`): **provably dead** in production (all builders stamp non-empty parents) — replace with a source fix that reproduces `info.parent_scan_id` exactly, or leave the loop; a bare delete moves goldens only if the fallback ever fires.

### 1.5 No-ops / defensive / cleanup (verified output-neutral)

| # | Item | Why output-neutral |
|---|---|---|
| #2/#13 | Drop `has_scan_row`; write the results row **in place at `:628`** | the 5 reaching branches all set it `true` (`:245/:313/:434/:496/:618`); the one processed path that leaves it false — MS1 `level(1).selection==None` — **returns at `:173` before `:628`**, so an unconditional write *at `:628`* is byte-identical. **Care:** do NOT hoist the write above the `:173` guard (that would add a spurious MS1 row). |
| #47 | Drop the `feedScan` finalize-guard | no current late-MS2 feed exists (already-finalized model short-circuits re-feed on the regular path) |
| #12 | Unify the dead MS3 CE-`else` | `stage0_activation_type` is always non-empty for MS3 variants (`buildMS3` = 2 stages), so the single-stage `else` is unreachable on the MS3 branch |
| #42 | `num_targets` bound on the target loop | `planNextScans` already caps at `config_.level(2).max_targets` (`:296/:318`) — guard is defensive |
| #20/#21 | null-check bail-earlys (`ms_ctx`) | bailing early matches current effective behavior (no row/command difference) |
| #27 | remove `(void)rt` | drop the unused param |
| #15/#17 | reuse `resolved`/`ctx` for precursor mass/charge instead of re-checking | same already-validated values |
| #28 | N-stage-generic CE logging | same MS2/MS3 output, just extensible |
| #30/#31 | simplify `parent_scan_id` copy; inline+generalize `buildMS2ContextForVariant` | identical strings/contexts |
| #26 | inline `feedResultImpl_` into `feedResult` | single-use helper; identical behavior |
| — | keep the removed `"exploration call site"` `cout` removed | stdout only; no test asserts it |

### 1.6 `#43` — `FeedResultInfo` struct cleanup (concrete redesign for sign-off)

> **TL;DR:** "feels extremely messy" — it is a flat bag of ~20 fields mixing metric, id, provenance, CE-stage, and command lists. Regroup into named sub-structs. **Pure reshape — every field preserved, same values written.**

_Proposed shape (to be finalized against the live struct at execution time; **no field dropped**):_

```cpp
struct FeedResultInfo {
  std::vector<ScanCommand> commands;            // pushed children
  std::vector<std::string> child_ids;           // pre-encoded

  struct Metric {                               // scoring/exploration bookkeeping
    int    group_id, variant_index, total_variants;
    ExplorationMetric exploration_metric;
    double score, remaining_ratio;
    std::string winner_tracking_id;             // "" except group-completing row
  } metric;

  struct Fragmentation {                        // CE/activation/reaction (stage-generic; see #28)
    double collision_energy, reaction_time;
    std::string activation_type;
    // stage0_* retained for MS3 2-stage rows (generalized to N-stage vector if #28 lands)
    double stage0_collision_energy, stage0_reaction_time;
    std::string stage0_activation_type;
  } frag;

  struct Identification {                       // what the scan identified
    FragmentAnalysis::ProteoformMatch identification_result;
    std::string proteoform_sequence, matched_protein;
    MS2Context ms2_context;
    float tic_coverage;
    std::vector<IdentificationRowInfo> additional_identification_rows; // winner-batch (gets a per-row tic in Phase 2 #14)
  } id;

  char parent_scan_id[4];
  std::vector<std::pair<int, MS2Context>> ms3_context_cache;
};
```

**Invariant:** call sites in `FLASHIda.cpp` (row fills at `:298-317`, `:470-499`) update to the nested names; every value written is unchanged.

---

## PHASE 2 — changes that move goldens (exactly 3)

### 2.1 `#18` — baseline prepended to every exploration group

> **TL;DR:** the CE-0 baseline pre-scan was RemainingPrecursor-only; now it's prepended to *every* metric. **The committed WIP does NOT compile and its golden surface is far bigger than a "+1 row".**
> `before: if(metric==RemainingPrecursor) insert baseline  →  after: always insert baseline`

**⚠ Build break to fix first.** `needs_baseline` is still referenced at `Exploration.cpp:169` (`v.variant_index = needs_baseline && i==0 ? -1 : …`) and `:172` (`v.is_baseline = needs_baseline && i==0`) but its declaration at `:133` is commented out and no member exists in `Exploration.h`. **Faithful completion:** re-declare `const bool needs_baseline = true;` at `:133` (baseline is always present now). This keeps the **baseline pinned to `variant_index = -1`** so real variants keep 0-based `variant_index`/`total_variants`. A careless completion (`v.is_baseline = (i==0)` at index 0) would renumber every real variant +1 and move **even RemainingPrecursor goldens**.

- Winner selection **skips** baseline (`is_baseline`, `:543`). RemainingPrecursor groups already had a baseline → **unchanged**. Only **MassCount(MS2) / FragmentCount(MS3)** groups gain one.
- **Golden surface — full (verification):**
  1. **Global scan-id re-indexing (dominant effect).** Each new baseline command consumes one monotonic id (`ScanCommandQueue.cpp:108 tracking_id_counter_++`), shifting **every** downstream `tracking_id`/`child_ids`/`parent_scan_id` and its base-94 `encode()` across **all five streams** (`scan_commands`, `scan_results`, `identification`, `pooled_identification`, IDA log) from the first affected group onward. Not localized.
  2. **New baseline rows.** One `scan_results` row (`variant_index=-1`, CE0/RT0/score0) + one `scan_commands` row per affected group; possible extra `identification` row only if the baseline match is non-empty.
  3. **FragmentCount MS3 winner ripple.** The baseline spectrum enters `variant_spectra[0]`; its ppm errors pool into the shared `median_ppm`/`correction_factor` (`MS3FragmentMatcher.cpp:496-517`) applied to the **real** variants → their `fragment_count`/`exploration_score`, the **winner**, `winner_tracking_id`, and `additional_identification_rows` can move **whenever the CE0 baseline deconvolves non-empty** (data-dependent). So it is NOT "only baseline rows added."
  4. **Continuity goldens affected**, not just log-goldens — any mode whose config uses MassCount(MS2)/FragmentCount(MS3) exploration (e.g. `continuity_ms3_mode*` if non-RemainingPrecursor). RemainingPrecursor-only modes unchanged.
- **Baseline excluded from the tracker feed (decided):** add an `is_baseline` guard at `Exploration.cpp:395` so the CE-0 baseline never enters the pooled model — keeps `pooled_identification` to real variants and bounds the pooled-golden surface.
- **CONTEXT.md updated** (new *Baseline variant* term).

### 2.2 `#19` — MS2 isolation-width floor dropped (2.0 only for MS3+)

> **TL;DR:** the `max(width, 2.0)` floor should apply to MS3 fragment isolation only; MS2 scores over its natural (unfloored) window — matching the actual commanded MS2 window.
> `before: group.isolation_width = max(mz2-mz1, 2.0)  →  after: MS2 = mz2-mz1 (natural); MS3 keeps the 2.0 floor`

- The emitted **MS2 command** isolation-width is **already unfloored** (`buildMS2`), so `scan_commands` MS2 `isolation_width` does **not** change.
- The floor today only bites the **RemainingPrecursor scoring window** (`:319` baseline sum, `:987` remaining intensity); MS3 stage[1] is re-floored by `buildMS3` (`ScanCommandQueue.cpp:356`) so MS3 is unaffected.
- **Golden surface:** RemainingPrecursor **MS2** `exploration_score`/`remaining_ratio` and any winner change cascading from it. No other stream.

### 2.3 `#14` — winner-batch MS3 identification rows carry per-scan tic

> **TL;DR:** the extra "winner-batch" MS3-`E` id rows all log the group-completing scan's tic; each should log its own variant's tic.
> `before: id_rows use expl_result.tic_coverage for every winner-batch row  →  after: each uses group.variants[vi].tic_coverage`

- Add `float tic` to `FeedResultInfo::IdentificationRowInfo`; populate from `group.variants[vi].tic_coverage` (`:312`); use per-row at `FLASHIda.cpp:~499`.
- **Golden surface:** `identification.tsv` `tic_coverage` on MS3-`E` **winner-batch** rows only. The primary `E` row already uses the completing variant's own tic (`:387`), so it is unchanged.

### 2.4 `#46` — relocate identification into the tracker + remove the rerun (moved from Phase 1)

> **TL;DR:** the tracker becomes the identification authority (Exploration consults it), AND the MS3-FragmentCount double-identification is collapsed — dropping the per-variant `:1037` pass in favor of the calibrated `:499` pass. The relocation alone is byte-identical, but removing the rerun changes the non-completing variants' logged scores → goldens move, so the whole thing lives in Push 2.

- **Relocation:** add a `FragmentAnalysis&` dependency to `ProteoformTracker` + thin wrappers; move the 4 matcher call-sites (`Exploration.cpp:1037`/`:499`/`:734`, `FLASHIda.cpp:557`) into the tracker. Exploration keeps the metric math + winner pick and consults the tracker for fragment-derived quantities.
- **Rerun removal:** for MS3-FragmentCount, stop scoring each variant twice; the calibrated batch (`:499`) becomes the sole identification. Non-completing variants then log the *calibrated* score instead of the pre-calibration `:1037` value.
- **Preserve I-46b/c:** winner-only `foldMs3` (variant matches never enter `m.pending`); `initiateNextLevel`'s `getTopFragmentMatches(tol=0.0)` → `nlr.proteoform_match` unchanged.
- Folds in `#16`/`#34`/`#37`–`#40`/`#10`/`#41`.
- **Golden surface:** MS3-FragmentCount `scan_results` `exploration_score`/`fragment_count` on non-completing variants; possible winner cascade. `identification.tsv` MS3-`E` rows. Recapture the MS3 FragmentCount exploration modes.

### Golden recapture set (Phase 2)

_To be finalized by the step-3 validation workflow._

| Change | Affected streams | Modes |
|---|---|---|
| #18 baseline-on-all | **all 5** streams (scan-id re-indexing) — `scan_commands`, `scan_results`, `identification`, `pooled_identification`, IDA log — **+ continuity goldens** | any mode with **MassCount(MS2) / FragmentCount(MS3)** exploration |
| #19 MS2 iso-width | `scan_results` (`exploration_score`/`remaining_ratio`) + winner cascade into `scan_commands`/`identification`/IDA log | **RemainingPrecursor MS2** exploration modes |
| #14 winner-batch tic | `identification.tsv` `tic_coverage` (MS3-`E` winner-batch rows only) | **MS3 FragmentCount** exploration modes |

Recaptured per-stream, each with sign-off, byte-identical to `LOG_GOLDEN_CAPTURE=1` promotion. #18's re-indexing means its recapture is the widest — the step-3 gate must confirm the id-shift is the *only* unexplained delta on the otherwise-Phase-1 streams.

---

## Tests touched (for sign-off)

**Phase 1 — renames only, NO assertion changes:**

| Test file | Touched because | Edit |
|---|---|---|
| `FLASHIda_exploration_test.cpp` | refs `feedResultImpl_`/`initiateNextLevel`/`FeedResultInfo`/`ExplorationTestAccess` | update to renamed symbols + nested `FeedResultInfo` names |
| `FLASHIda_LoggingFields_test.cpp` | refs moved id/feed symbols | rename refs |
| `FLASHIda_TestAccess.h` | named friend-access header | update method names (`finalizeMS2`/`getModel`), keep `feedScan` |
| `FragmentAnalysis_test.cpp` | refs matcher/feed | rename refs |
| `ProteoformTracker_CEOptimization_test.cpp` | `feedScan`/`finalize`/`model` | `finalize→finalizeMS2`, `model→getModel` |
| `ProteoformTracker_Localization_test.cpp` | same | same |
| `ProteoformTracker_Trajectory_test.cpp` | same | same |

**Phase 2 — no code edits; goldens recaptured (C# golden tests + C++ plausibility ranges re-verified).**

_No new tests proposed. If any Phase-1 move proves non-identical (escalation), a new test may be required and will come back for sign-off._

---

## Delivery sequence

1. Implement **all** Phase 1 + Phase 2 C++ in one working tree (no C# code change).
2. Push once → CI. Iterate to **green-except-goldens** (Phase-1 tests green; only Phase-2-affected goldens red).
3. Run the **golden-inconsistency validation workflow** over the red goldens — this is the **enforcement gate for every Phase-1 invariant** (I-46a-d, push-order, `exploration_active_` placement, `frag_scores` param, `window_snr` per-stage, `has_scan_row` write-in-place). A red golden on any stream/column **not** attributable to #18 scan-id re-indexing / #19 RemainingPrecursor-MS2 / #14 winner-batch-tic = a Phase-1 leak → STOP + re-plan.
4. **Recapture** the confirmed Phase-2 goldens per-stream, each with your sign-off.
5. Final Windows-green.
6. Bump submodule gitlink + parent; commit.

**NEXT ACTION:** await plan approval, then implement Phase 1 §1.1 first (renames, lowest risk), building outward to §1.2 (#46 tracker consolidation, highest risk).

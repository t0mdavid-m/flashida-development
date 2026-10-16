# Refine Annotation Method — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `characterization.method: "refine"` — the progress report's no-search annotation (shift scan at an FDR → levels → one DP per total → MS3 tests the two best paths on discriminating masses, evidence pooled across MS3 scans) — beside FLASHTnT, default off, validated on the report's cytochrome c scan and the fourteen corpus proteoforms.

**Architecture:** A new pure-function helper `FLASHIda/Refine.{h,cpp}` (Detect, Assemble, discriminating masses, piece test, recount) with no engine state, tested alone against committed deconvolved-mass fixtures. `FragmentAnalysis::getTopFragmentMatches` switches on the method and fills the same `ProteoformMatch` the tracker, the logs and the planner already consume, plus a shared candidate record the new MS3 objective reads. `ProteoformTracker` gains a `discriminating` planner modelled on `planExhaustive_`, a per-precursor evidence record, and a round-complete recount; `FLASHIda.cpp`'s MS3 return path feeds it and re-dispatches once a round is in.

**Tech Stack:** C++20 (OpenMS, nlohmann json, `std::mt19937_64`), C# 7.3 (.NET Framework 4.8), Python 3 via `uv` for the vendored prototype and the table generator, the two Docker containers, CI.

**Spec:** `docs/adr/0049-a-mass-shift-is-detected-before-the-path-and-flashtnt-stays-a-method.md` (Proposed, 2026-10-11) and the repo `CONTEXT.md` section "Language — annotation without a search (the Refine method)". Reference implementation: the owner's prototype under `C:\FLASHIda\fi_refine_publication_notes\evidence\` (`truncation_scan/trunc_core.py`, `lenient_cut/detect_fdr.py`, `lenient_cut/column_dp_v85.py`, `lenient_cut/targets_v88.py`, `lenient_cut/ms3_recount_v79.py`).

**Plan file home after approval:** `docs/superpowers/plans/2026-10-11-refine-annotation-method.md` (this content, verbatim).

---

## TL;DR in plain language

- Today an MS2 is annotated by FLASHTnT: tags first, then a path along the sequence that opens a mass shift whenever one fragment does not fit. The shift set is frozen at the winner and MS3 only narrows ranges. No error rate anywhere.
- After this plan a method file can say `characterization.method: "refine"`. The engine then (1) slides a trial shift over every b/y ion and counts matches, subtracts the internal coincidences, and keeps the peaks that pass an FDR from shuffled sequences — the **levels**; (2) for every candidate total shift runs one small DP (rows = cleavage sites, columns = levels, +1 per matched ion, −1 per jump) and ranks the totals by score; (3) reports the best path with each shift's window; (4) under the new `characterization.mode: "discriminating"` isolates the MS2 masses the two best paths explain **differently**, pools the pieces from every MS3 scan of each, recounts both scores once the round is in, and the higher score wins. After that the existing containing-fragment narrowing continues on the winner.
- `flashtnt` stays the default. No committed config changes behaviour in Push 1; Push 2 adds seven identification columns (header-moving for all 29 modes) and one new golden mode.
- Validation: the report's 150-mass cytochrome c scan pinned to the report's numbers; fourteen corpus proteoforms as committed mass-list fixtures with expectation tables the vendored prototype generates once; a log golden on the July 2026 run through the engine's own deconvolution.
- **Correction to ADR-0049 decision 10 made 2026-10-11:** the four markers go to **stdout** (like `[MS3-PLAN]`), not `ida.log`, which is the MS1 consumer format with two readers.

```
BEFORE (flashtnt)                               AFTER (refine)
MS2 masses ─► tags ─► path, shift = 1 fragment  MS2 masses ─► shift scan S(Δm) ─► FDR cut c ─► levels Λb, Λy
          ─► 1 hit, ≤2 shifts, no error rate              ─► for each λk = λb+λy: DP(sites × levels) ─► S
          ─► frozen; MS3 narrows ranges                   ─► best path + windows   (report; +precursor mass diff)
                                                          ─► 2 best λk differ on masses m₁..mₙ  ─► MS3 each
                                                          ─► pieces pooled per mass ─► round in ─► recount S
                                                          ─► higher S wins ─► ambiguity narrowing on winner
```

## Context

The report (30.09.2026, "Annotate fragments, find mass shifts") finds the FLASHTnT annotation "not dependable for localization": on cytochrome c it merges −89.03 and +615.17 into one +526.14 on a single residue, and the July 2026 instrument run reported `(1-19)[+657.17]`. The reasons are structural (one fragment opens a shift at a fixed price, tags anchor it, the joint pass must end on the precursor, at most two shifts). The owner's prototype of the alternative reproduces every number in the report on the example scan and was checked against 234 real MS3 scans. ADR-0049 records the decisions; this plan is their delivery.

## Global Constraints

- `ScanCommand` stays 2048 bytes; the 5 bridge exports are untouched. Nothing here crosses the ABI.
- FLASHDeconv, FLASHTnT and FLASHExtender sources are **not modified**. The method switch lives in the IDA engine.
- New TSV columns are **appended** at the end of `identification.tsv` only (Push 2). No `scan_results.tsv` change.
- `characterization.method` defaults to `flashtnt`; with that value every committed config is byte-identical in logs and goldens (the Push 1 acceptance test).
- `characterization.refine` is accepted only under `method: refine`; `mode: discriminating` only under `method: refine` (load errors, both sides strict).
- Shuffle seed is an engine constant (`kRefineSeed = 12345ULL`, `std::mt19937_64`); it cannot reproduce numpy's permutations, so the acceptance test pins the **cut** exactly and FDR values at a tolerance.
- Every C++ test is registered in three places (`executables.cmake`, yml `--target`, yml `ctest -R`) and `ci lists` must pass.
- Two pushes: Push 1 byte-identical for every committed config (must land CI-green), Push 2 golden-moving.
- **This plan executes only after the kinetic-model work (ADR-0047/0048) is CI-green**; every `Exploration.cpp` line number below is re-verified at execution against that tree. The two touch different functions (kinetic: `feedResultImpl_`/`buildVariants_`; this: the dispatch tail of `initiateNextLevel` and the MS3 return path).
- Line endings: `FlashIDA/` is CRLF in the working tree; never `sed -i` there. Root `CONTEXT.md` and ADRs are LF.
- Python on this host: `uv run --with numpy python -I <script>`.
- Test changes are frozen to the list in **Tests touched** below.

## Decisions carried (from ADR-0049)

| # | Decision | Where it lands |
|---|---|---|
| 1 | `characterization.method: flashtnt \| refine`, default flashtnt | `Config.{h,cpp}`, `MethodConfig.cs`, `MethodParameters.cs`, `validate.py` |
| 2 | Supplied sequence taken as given | `Refine::ladder` (no Met logic) |
| 3 | Detect: five keys under `characterization.refine`; single pass; typed levels; no fold; water/ammonia exclusion; activation-driven ion alphabet | `Refine::detect`, `Config::validate` |
| 4 | Assemble: one DP per total; score = ions − jumps; no jump into 0 / out of λk; revisits allowed; tie → fewer shifts → summed intensity | `Refine::assemble` |
| 5 | MS2 report = best path + windows + precursor mass difference; all candidates on stdout | `FragmentAnalysis::runRefineMatching_`, `[CANDIDATES]` |
| 6 | Same `ProteoformMatch` contract + per-precursor candidate record; model seeded from highest S | `ProteoformMatch::refine`, `finalizeMS2` (unchanged code) |
| 7 | `mode: discriminating` (refine-only); discriminating mass = explained differently; top `max_targets` by intensity via the raw-mass dispatch; dispatched memory | `ProteoformTracker::planDiscriminating_` |
| 8 | Piece fits a path only when shift-carrying; calibrate on shared pieces | `Refine::pieceTest`, `ProteoformTracker::recordDiscriminatingScan` |
| 9 | Evidence pooled per precursor + mass; recount + decide + re-plan when the round is in; then ambiguity narrowing on the winner | `ProteoformTracker::decideRefine_`, `FLASHIda.cpp` MS3 path, `Exploration::dispatchFromModel` |
| 10 | Four stdout markers; seven appended identification columns (Push 2) | `IdaLogger`, `FLASHIda.cpp` |
| 11 | Layer A ctest over committed mass lists; layer B golden on July fixtures; layer C hardware | Tasks 2, 3, 4, 13 |
| 12 | Kinetic first; wrong-string cleanup out of scope | Working agreement |

## File structure

**Created**

| Path | Responsibility |
|---|---|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Refine.h`, `…/source/ANALYSIS/TOPDOWN/FLASHIda/Refine.cpp` | Pure functions: ladder, shift-scan curve, Expected, shuffles, FDR/cut, levels + neutral-loss exclusion, per-total DP with tie rule, windows, explained ions, discriminating masses, shared-piece calibration, piece test, recount. No engine state. 17th runtime helper (after KineticModel). |
| `OpenMS/src/tests/class_tests/openms/source/Refine_test.cpp` | Layer A: unit sections + cytochrome c report numbers + 14 corpus sections |
| `OpenMS/src/tests/class_tests/openms/source/ProteoformTracker_Discriminating_test.cpp` | Planner, round bookkeeping, decision, flip, shift-carrying-only narrowing |
| `FlashIDA/test-scripts/refine/{refine_core.py,VENDORED.md,make_refine_tables.py}` | Prototype consolidated verbatim (trunc_core + lenient_core + column_dp_v85 + targets_v88 + ms3_recount_v79) and the one-time generator of fixtures + expectation tables |
| `FlashIDA/test-data/refine/cytc_grp1_prec1.tsv`, `refine_expected_cytc.tsv`, `corpus/<protein>.tsv` (14), `refine_expected_corpus.tsv`, `july_ms3_pieces.tsv` | Committed deconvolved-mass fixtures with provenance headers, and the expectation tables |
| `FlashIDA/test-data/configs/method_refine_cytc.json` | Layer B config (copy of `method_ms3_cytc_new.json` + method/mode/refine block) |
| `FlashIDA/test-data/golden/logs/refine_discriminating_cytc/` | Golden mode 30 (Push 2, owner-promoted) |

**Modified (engine):** `FragmentAnalysis.{h,cpp}`, `Config.{h,cpp}`, `ProteoformTracker.{h,cpp}`, `Exploration.{h,cpp}` (dispatch-tail extraction only), `FLASHIda.cpp`, `IdaLogger.{h,cpp}` (Push 2), `include/…/TOPDOWN/sources.cmake`, `source/…/TOPDOWN/sources.cmake`.
**Modified (C#):** `MethodConfig.cs`, `MethodParameters.cs`, `FLASHIdaLogGolden_test.cs` (Push 2), `test-data/config_schema_reference.json` (regenerated).
**Modified (tests):** `Config_SchemaProjection_test.cpp`, `ConfigSchemaParity_test.cpp`, `FLASHIda_LoggingFields_test.cpp` (Push 2), `executables.cmake`, `flashida-ci.yml` (two lists).
**Modified (docs):** three `CLAUDE.md`, `docs/kb/fragment-analysis/*`, `.claude/skills/validate-flashida-config/{SKILL.md,validate.py}`, `LOG_COLUMN_ORDER_REFERENCE.md` (Push 2), `FlashIDA/test-data/spectra/FIXTURES.md` (pointer to `refine/`), `docker/README.md` calibration row.

## Review Focus

Inputs the ADR implies but no decision names; each gets the test listed.

1. **A scan with no level above the cut** (clean unmodified protein, e.g. ubiquitin, myoglobin): exactly one candidate (λk = 0, path `0`), S = matched ions, `[CANDIDATES]` lists it, `discriminating` dispatches nothing with reason `single_candidate`. → Task 2 `no_level_gives_one_candidate`, Task 7 `single_candidate_dispatches_nothing`.
2. **Two totals tied on score and on shift count** must resolve by summed intensity, deterministically, before "second best" picks what MS3 isolates. → Task 2 `tie_on_score_and_shifts_resolves_by_intensity`.
3. **A discriminating mass whose MS3 never returns** (instrument drop): the round never completes; the decision does not fire on a partial round; the next MS2 of the precursor re-plans as today. → Task 7 `round_waits_for_every_dispatched_mass`.
4. **A second-path piece that coincides with a first-path piece within tolerance** is shared, not discriminating, even when the ion labels differ. → Task 2 `piece_shared_when_masses_coincide`.
5. **`method: refine` with an ETD activation** must detect on c/z, not b/y: the report states b/y but the engine's alphabet is activation-driven. → Task 2 `etd_scan_detects_on_c_and_z`.

## Working Agreement

- One logical change per commit, docs in separate commits; commit in the submodule first, then bump the gitlink in the parent. Every commit ends with the two attribution lines of this session.
- Before each push: `ci cpp` (fast), `ci cpp --full` once, `ci cs`; then push; watch the run once (`gh run list`, never concurrent `gh run watch`).
- Any failure → stop, report, re-plan. No "fix the test to agree". No golden write without the diff in front of the owner.
- Tests listed in **Tests touched** are the approved set; nothing else is touched.
- Golden promotion is the owner's `cp` after the diff; containers only stage. Assert 30 case dirs × 5 non-empty `.normalized` before promoting.
- Push 1 must be CI-green before any Push 2 commit.
- The prototype is a generator and a development oracle; the suite never calls Python.
- If a corpus row fails criterion a with the **prototype** (Task 3), stop and report before committing its expectation — the owner decides what the test pins.

---

# PUSH 1 — byte-identical for every committed config

### Task 1: `Refine` helper — Detect

**Files:**
- Create: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Refine.h`, `…/source/ANALYSIS/TOPDOWN/FLASHIda/Refine.cpp`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/sources.cmake:16` (add `FLASHIda/Refine.h` after `KineticModel.h`), `…/source/ANALYSIS/TOPDOWN/sources.cmake:16` (add `FLASHIda/Refine.cpp`)
- Create: `OpenMS/src/tests/class_tests/openms/source/Refine_test.cpp` (sections of this task)

**Interfaces (produced):**

```cpp
namespace OpenMS
{
  struct OPENMS_DLLAPI RefineSettings
  {
    double fdr = 0.5;            // characterization.refine.fdr
    int shuffles = 300;          // characterization.refine.shuffles
    double grid_da = 0.01;       // characterization.refine.grid_da
    double max_shift_da = 700.0; // characterization.refine.max_shift_da  (grid runs -max..+max)
    int min_ions = 3;            // characterization.refine.min_ions      (smallest cut tried)
    double tolerance_ppm = 10.0; // level(2).tolerance_ppm
    static constexpr uint64_t kSeed = 12345ULL;
    static constexpr double kSame = 0.004;   // two shifts within this are one (prototype SAME)
  };

  class OPENMS_DLLAPI Refine
  {
  public:
    /// Theoretical prefix/suffix ladders of one sequence for an ion alphabet (I->L, monoisotopic).
    /// prefix[n-1] = ion of cleavage site n (b_n or c_n), suffix[n-1] = y_{L-n} / z_{L-n}.
    struct Ladder { std::vector<double> prefix, suffix; std::vector<double> residues; double sequence_mass = 0; };
    static Ladder ladder(const String& sequence, const std::vector<std::string>& ion_types);

    struct Level { double shift = 0; int signal = 0; int n_prefix = 0, n_suffix = 0; double lo = 0, hi = 0; bool neutral_loss = false; };
    struct Detect
    {
      int cut = 0;                                   // smallest h >= min_ions with FDR(h) <= fdr; 0 = none passes
      std::vector<Level> levels;                     // regions of S >= cut, ascending shift, neutral losses flagged
      std::vector<double> fdr_by_height;             // index h (1..60): mean decoy peaks / signal peaks; -1 where S has none
      int observed_at_zero = 0;                      // masses the unshifted ladder explains (|M ∩ T|)
    };
    static Detect detect(const std::vector<double>& masses_sorted, const Ladder& ladder, const RefineSettings& s);

    // --- building blocks, exposed for the unit sections ---
    /// n(f, h) for every h in [1, hmax]: maximal runs of consecutive grid points with f >= h.
    static std::vector<int> regionCounts(const std::vector<int>& curve, int hmax);
    /// The curve: number of distinct ladder ions matching at least one mass, at every grid point.
    static std::vector<int> curve(const std::vector<double>& theo, const std::vector<double>& masses_sorted,
                                  double tol_ppm, double lo, double step, int n);
    /// Mask of masses the unshifted ladder explains within tolerance.
    static std::vector<bool> explained(const std::vector<double>& theo, const std::vector<double>& masses_sorted, double tol_ppm);
  };
}
```

**Algorithm notes the implementer needs (the prototype, one to one):**
- Grid: `lo = -max_shift_da`, `n = round(2*max_shift_da/grid_da) + 1`, points `lo + i*step`.
- `curve`: for each ion `t` and each mass `m` (ascending), the matching interval in grid units is `[ceil((m - tol(m) - t - lo)/step - 1e-9), floor((m + tol(m) - t - lo)/step + 1e-9)]`, clipped to `[0, n-1]`; along one ion the starts ascend, so clamp each start to `prev_end + 1` (one ion counts once); accumulate a difference array; prefix-sum.
- `S = curve(T, M) - curve(T, M[explained])`. Decoys: `Dk = curve(ladder(shuffle_k(residues)), M[!explained])`; the shuffle permutes the residue masses with `std::mt19937_64(kSeed)` and `std::shuffle`, K times, one stream.
- `regionCounts` in one pass: for `i` in 0..n-1, if `f[i] > f[i-1]` (f[-1] = 0) add 1 to counts for `h = f[i-1]+1 .. f[i]` via a difference array over h. `hmax = 60`.
- `fdr(h) = (Σk n(Dk,h)/K) / n(S,h)`; `cut = min{ h >= min_ions : n(S,h) > 0 && fdr(h) <= fdr }`; if none, `cut = 0` and `levels` empty.
- Levels: maximal runs of `S >= cut`; `shift` = grid point of the middle of the run's maximum plateau; `signal` = max; `lo/hi` = first/last grid point; `n_prefix/n_suffix` = ions of each ladder half that match at `shift` (same interval rule). A level is a neutral loss when some reference `r ∈ {0} ∪ {shift of a level with higher signal}` and loss `v ∈ {18.010565, 17.026549}` satisfy `lo - 0.005 <= r - v <= hi + 0.005`.
- Ion alphabet: `FragmentAnalysis::getIonTypesForFragmentationMethod(activation)` (b/y for HCD/CID, c/z for ETD); `ladder()` uses `FragmentAnalysis::computePTMAdjustedFragmentMasses(seq, {}, ion_types, map)` for the prefix series (the first prefix type) and the suffix series (the first suffix type), so the residue arithmetic is the engine's.

- [ ] **Step 1: Write the failing unit sections** (`Refine_test.cpp`, above `START_TEST` the fixture loader `loadMassList(path) -> {masses, intensities, charges}` reading `mass\tintensity\t#charges` with `#` comment lines skipped):

```cpp
START_SECTION(curve_counts_each_ion_once_and_respects_tolerance)
  // ladder {1000, 2000}, masses {1000.005, 1000.009, 2000.0}, 10 ppm, grid -1..+1 step 0.001
  // at dm = 0: ion 1000 matches two masses -> counts ONCE; ion 2000 matches -> curve == 2
  // at dm = +0.02: nothing within 10 ppm -> 0
END_SECTION

START_SECTION(region_counts_one_pass_equals_naive)
  // curve {0,1,3,3,2,0,4,1,0}: naive runs: h=1 ->2, h=2 ->2, h=3 ->2, h=4 ->1, h=5 ->0; regionCounts == those
END_SECTION

START_SECTION(expected_removes_internal_coincidences)
  // sequence "PEPTIDEK", masses = its b3 and b5 (explained) plus the mass of residues 4..5 (= b5-b3): at dm = b5-b3
  // Observed counts ion b3 (b3 + dm == b5) but Expected counts it too -> S == 0 at that point
END_SECTION

START_SECTION(neutral_loss_levels_are_flagged_not_dropped)
  // hand-built Detect with levels at +526.14 (signal 23) and +508.13 (signal 5): the second is flagged neutral_loss (water)
  // a level at -17.03 with no stronger reference but 0 -> flagged (ammonia below 0)
END_SECTION

START_SECTION(no_level_gives_cut_zero)            // Review Focus 1
  // masses = the ladder of "PEPTIDEK" itself: S is 0 everywhere -> cut 0, levels empty, observed_at_zero == 14
END_SECTION

START_SECTION(etd_scan_detects_on_c_and_z)        // Review Focus 5
  // ladder("PEPTIDEK", {"c","z"}).prefix[0] == c1 mass (b1 + NH3), suffix[0] == z7 mass; detect with masses = c-ions + 42.0106 finds a level at +42.01 with n_prefix > 0
END_SECTION
```

- [ ] **Step 2: Run** `ci cpp Refine_test` → FAIL (`Refine.h` not found). Register the test first in `executables.cmake` (after `KineticModel_test`), yml `--target` (after `KineticModel_test \`) and yml `-R` (`|Refine_test`); `ci lists` → PASS.
- [ ] **Step 3: Implement** `Refine.h/.cpp` as specified; `ladder` via the two `FragmentAnalysis` statics.
- [ ] **Step 4: Run** `ci cpp Refine_test` → PASS.
- [ ] **Step 5: Commit** (`OpenMS/`): `feat(refine): Detect — shift-scan curve, Expected, shuffled-sequence FDR, levels (ADR-0049)`.

---

### Task 2: `Refine` helper — Assemble, discriminating masses, piece test, recount; the cytochrome c numbers

**Files:**
- Modify: `Refine.{h,cpp}`, `Refine_test.cpp`
- Create: `FlashIDA/test-data/refine/cytc_grp1_prec1.tsv` (the 150 masses: copy of `C:\FLASHIda\fi_refine_publication_notes\evidence\truncation_scan\grp1_prec1.tsv` with a `#` provenance header), `FlashIDA/test-data/refine/july_ms3_pieces.tsv` (see Step 4)
- Create: `FlashIDA/test-scripts/refine/{refine_core.py,VENDORED.md}` (the prototype consolidated verbatim; `VENDORED.md` names each source file and its date)

**Interfaces (produced):**

```cpp
    struct Path
    {
      double total = 0;                 // λk
      int score = 0;                    // S = ions - jumps
      int ions = 0;                     // N
      int jumps = 0;
      double intensity_sum = 0;         // Σ intensity of explained masses (tie-break)
      std::vector<double> levels;       // 0, ..., λk in sequence order
      std::vector<std::pair<int,int>> windows;   // per jump: [first,last] residue (1-based) over placements keeping N
      struct Ion { char type; int index; int mass_idx; double level; double theoretical; };
      std::vector<Ion> ions_explained;  // at the lowest placement of every jump
    };
    struct Assemble { std::vector<Path> candidates; };   // ranked: score desc, jumps asc, intensity_sum desc
    static Assemble assemble(const std::vector<double>& masses_sorted, const std::vector<double>& intensities,
                             const Ladder& ladder, const Detect& d, const RefineSettings& s);

    struct Discriminating { int mass_idx; double mass; double intensity; std::optional<Path::Ion> ion_a, ion_b; };
    /// Masses the two paths explain differently (one or none, or different ions); intensity desc.
    static std::vector<Discriminating> discriminating(const Path& a, const Path& b,
                                                      const std::vector<double>& masses, const std::vector<double>& intensities);

    /// PTM sites a path implies (full-protein 1-based ranges = windows), for MS3FragmentMatcher.
    static std::vector<FragmentAnalysis::PTMSite> ptmSites(const Path& p);

    struct PieceVerdict { bool fits_a = false, fits_b = false; int shared_seen = 0; double correction = 1.0; };
    /// One MS3 scan of one discriminating mass: calibrate on shared pieces, then test discriminating,
    /// shift-carrying pieces per path (decision 8).
    static PieceVerdict pieceTest(const DeconvolvedSpectrum& ms3, const String& sequence,
                                  const Path& a, const Path& b, const Discriminating& target,
                                  double loose_ppm, double tight_ppm);

    struct Recount { int score_a = 0, score_b = 0; int confirmed_a = 0, confirmed_b = 0; bool a_wins = true; };
    static Recount recount(const Path& a, const Path& b, const std::vector<Discriminating>& targets,
                           const std::vector<std::pair<bool,bool>>& confirmed /* per target: fits a, fits b */);
```

**Algorithm notes:**
- `Λb` = non-neutral-loss levels with `n_prefix > 0`, `Λy` with `n_suffix > 0`. Totals = unique within `kSame` of `{u + w : u ∈ {0}∪Λb, w ∈ {0}∪Λy}`. Per total: `D = unique({0, λk} ∪ Λb ∪ {λk - y : y ∈ Λy})`; `i0` = index of 0, `ik` of λk.
- Cells `a(n, λ) = [idx(t_n + λ) >= 0] + [idx(m_seq - t_n + λk - λ) >= 0]`, n = 1..L−1, `idx` = the observed mass within `tol_ppm` of the value (the higher of two neighbours when both match; `-1` otherwise). `m_seq` = `ladder.sequence_mass` (residues + water).
- Forward DP with scale 1000 (ion = 1000, jump cost 1001) as the prototype: `F[0][i0] = 0`, `F[n][λ] = max(F[n-1][λ], max_{λ'≠λ, λ'≠ik} F[n-1][λ'] - cost) + a(n, λ)·1000`, no jump into `i0`; `S = F[L-1][ik] / 1000` (the quotient), `jumps = (−S·1000 − F) mod` as in the prototype's `(-S) % 1000`. Traceback from `(L-1, ik)`: prefer **stay**; among jump sources the one with the largest `F`, then the lowest column index — this is the rule that reproduces the prototype's `orders[0]` on the five best totals of the example; if Step 5 shows a top-five path differing from the report, **stop and report** (issues → re-plan).
- Windows and `ions_explained` from the path-level forward/backward DP over the chosen level order (prototype `path_dp` / `windows`), N counted unscaled; `ions_explained` at the placement with every jump at its window's first residue.
- Ranking across totals: `score` desc, `jumps` asc, `intensity_sum` desc.
- `discriminating`: build `mass_idx → Ion` per path (one ion per mass: when a path explains one mass as two ions, keep the ion in the series of the other path's ion, else the prefix ion — the report's Version 88 rule); a mass is discriminating iff the labels differ or one is absent; sort by intensity desc.
- `ptmSites(p)`: for jump j with window `[r1, r2]` and step `δj = levels[j] - levels[j-1]`: `PTMSite{position=(r1+r2)/2, start=r1, end=r2, mass_shift=δj}`.
- `pieceTest`: predicted pieces per path via `MS3FragmentMatcher::calibrateAndScore` on a one-spectrum vector with `ProteoformContext{0, L, ptmSites(path)}` and the path's ion for the target (`ion_a`/`ion_b`; a path with no ion for the mass predicts nothing). Shared set = predicted theoretical masses (both paths) within `tight_ppm` of each other. Calibration: pass 1 at `loose_ppm` against the **shared** set only, median signed ppm → `correction`; apply to a copy of the spectrum; then call `calibrateAndScore` per path with `loose = tight = tight_ppm`. A matched piece is **discriminating** when its theoretical under this path is not within `tight_ppm` of any theoretical under the other path, and **shift-carrying** when `|theoretical − bare backbone mass of the same piece| > tol` (bare = the same sub-ion with an empty PTM list). `fits_x = (#discriminating shift-carrying matched pieces under x) >= 1`.
- `recount`: `shared` = the DISTINCT observed masses both paths explain = `masses_a − |discriminating masses a explains|` (equal to the same count from b by construction, assert; Version 88 counts one ion per mass and path); `score_x = shared + confirmed_x − jumps_x`; `a_wins = score_a > score_b || (score_a == score_b && jumps_a <= jumps_b)`.

- [ ] **Step 1: Vendor the prototype.** `refine_core.py` = `trunc_core.py` + the definitions of `lenient_core.py`, `ms2_rules.py` (only what `column_dp_v85.py` executes), `column_dp_v85.py`, `targets_v88.py`, `ms3_recount_v79.py`, concatenated verbatim with a banner naming each source; pin runs: `uv run --with numpy python -I refine_core.py --cytc <masses.tsv>` prints the Version 85/88 numbers. `VENDORED.md`: source paths, dates, sha256 of each original.
- [ ] **Step 2: Commit the example fixture** `cytc_grp1_prec1.tsv` with header lines `# source: fi_refine_publication_notes/evidence/truncation_scan/grp1_prec1.tsv (150 masses of the report's cytochrome c scan, relayed 2026-09-21)` / `# sequence: M+GDVEK… (105 residues, Met-start, as the report)`.
- [ ] **Step 3: Write the failing sections:**

```cpp
START_SECTION(cytc_detect_reproduces_the_report)
  auto fx = loadMassList(FI_REFINE_CYTC);  RefineSettings s; s.tolerance_ppm = 10;   // defaults: fdr 0.5, K 300, grid 0.01, ±700, min 3
  auto L = Refine::ladder(CYTC105, {"b","y"});
  auto d = Refine::detect(fx.masses, L, s);
  TEST_EQUAL(d.observed_at_zero, 36)
  TEST_EQUAL(d.cut, 4)                                  // 73.7 % at 3, 44.4 % at 4 (K=10,000); K=300 gives the same cut
  TEST_REAL_SIMILAR_ABS(d.fdr_by_height[3], 0.737, 0.05) TEST_REAL_SIMILAR_ABS(d.fdr_by_height[4], 0.444, 0.05)
  TEST_EQUAL(d.levels.size(), 26)
  TEST_EQUAL(count_if(levels, !neutral_loss), 22)        // -18.02, -17.02, +508.12, +637.18 flagged
  TEST_EQUAL(count Λb, 11)  TEST_EQUAL(count Λy, 15)
  // the three strong levels, by shift and typed counts
  TEST level(-89.03): signal 7, n_prefix 7, n_suffix 0;  level(+526.14): signal 23, n_prefix 23, n_suffix 0;  level(-17.02): neutral_loss, n_suffix 6
END_SECTION

START_SECTION(cytc_assemble_reproduces_the_report)
  auto a = Refine::assemble(fx.masses, fx.intensities, L, d, s);
  TEST_EQUAL(a.candidates.size(), 182)                  // totals
  const auto& best = a.candidates[0];
  TEST_REAL_SIMILAR_ABS(best.total, 526.14, 0.01)  TEST_EQUAL(best.score, 63)  TEST_EQUAL(best.jumps, 2)  TEST_EQUAL(best.ions, 65)
  TEST levels == {0, -89.03, +526.14}  windows == {[1,8], [14,22]}
  TEST b/y counts over best.ions_explained == (29, 36)
  const auto& second = a.candidates[1];
  TEST_REAL_SIMILAR_ABS(second.total, 655.19, 0.01)  TEST_EQUAL(second.score, 50)  TEST_EQUAL(second.jumps, 5)  TEST_EQUAL(second.ions, 55)
  // third..fifth: +412.04 / +525.12 / +655.22 all S 49, N 52 (order among them by intensity_sum — assert the set, then that the order is intensity_sum desc)
END_SECTION

START_SECTION(cytc_discriminating_masses_reproduce_the_report)
  auto t = Refine::discriminating(a.candidates[0], a.candidates[1], fx.masses, fx.intensities);
  TEST_EQUAL(t.size(), 21)  TEST_EQUAL(count only_a, 15)  TEST_EQUAL(count only_b, 2)  TEST_EQUAL(count both_different, 4)
  TEST_REAL_SIMILAR_ABS(t[0].mass, 8111.25, 0.01)  TEST_EQUAL(t[0].ion_a->type, 'y')  TEST_EQUAL(t[0].ion_a->index, 71)
  TEST masses both paths explain as the same ion (y39, y40) are NOT in t
END_SECTION

START_SECTION(cytc_recount_after_july_ms3_reproduces_the_report)
  // july_ms3_pieces.tsv: for each of b47, b48, b51 the pooled deconvolved masses of its 14 July scans (Step 4)
  // Build a DeconvolvedSpectrum per target from those masses (PeakGroup with mono mass only; makeSyntheticPeakGroup-style)
  // pieceTest for each: fits_a true, fits_b false; every other target: untested (false,false)
  auto r = Refine::recount(best, second, t, confirmed);
  TEST_EQUAL(r.score_a, 47)  TEST_EQUAL(r.score_b, 41)   // against +655.19 (5 jumps): shared 46 = 65−19 = 52−6; the 49/45 of the V79 script was against +637.18, excluded as a water loss since V85  TEST_EQUAL(r.confirmed_a, 3)  TEST_EQUAL(r.a_wins, true)
END_SECTION

START_SECTION(tie_on_score_and_shifts_resolves_by_intensity)   // Review Focus 2: synthetic 8-residue case with two totals at equal S and jumps; the one whose explained masses sum higher ranks first
END_SECTION
START_SECTION(piece_shared_when_masses_coincide)              // Review Focus 4: two paths label one piece b3 vs c3 at masses 1 ppm apart -> shared, fits neither
END_SECTION
START_SECTION(no_level_gives_one_candidate)                   // Review Focus 1: Detect with cut 0 -> assemble returns one candidate (total 0, jumps 0, score = N)
END_SECTION
```

- [ ] **Step 4: Cut `july_ms3_pieces.tsv`** with `make_refine_tables.py --july` (Task 3's generator, first mode): read `C:\FLASHIda\flashida-fresh\scan_results_path.tsv` and `scan_commands_path.tsv`; for parents b47, b48, b51 (report numbering = engine ion index + 1; m/z and tracking ids as `refute.py` selects them) write `target_ion\tmass\tintensity` rows pooled over the parent's MS3 scans (6 significant digits as logged). Provenance header names the run and the three parents.
- [ ] **Step 5: Run** `ci cpp Refine_test` → PASS on every section; if a top-five total or any pinned count differs from the report, stop and report with the engine's table beside the prototype's (`refine_core.py --cytc`).
- [ ] **Step 6: Commit** (`OpenMS/`): `feat(refine): Assemble, discriminating masses, piece test, recount; cytochrome c pins the report (ADR-0049)`; (`FlashIDA/`): `test(refine): example scan and July MS3 piece fixtures; vendored prototype`.

---

### Task 3: Corpus fixtures and expectation tables

**Files:**
- Create: `FlashIDA/test-scripts/refine/make_refine_tables.py`, `FlashIDA/test-data/refine/corpus/<key>.tsv` ×14, `FlashIDA/test-data/refine/refine_expected_corpus.tsv`, `FlashIDA/test-data/refine/refine_expected_cytc.tsv`
- Modify: `Refine_test.cpp` (one section per corpus row), `FlashIDA/test-data/spectra/FIXTURES.md` (pointer paragraph)

- [ ] **Step 1: Generator, mode `--corpus`.** Inputs: `C:\FLASHIda\Measurements\MS2_Characterization\proteoforms.tsv` (columns `dataset`, `best_scan`, `chain`, `proforma`) and each run folder's `scan_results.tsv`. For every row except beta-casein run B: parse the tracking id from `best_scan` (first token matching `![\x21-\x7e]{2}`), take that row's `deconv_masses/deconv_intensities/deconv_charges`, write `corpus/<key>.tsv` (`key` = `ca`, `cytc`, `lysozyme`, `lysozyme_red`, `myoglobin`, `rnase`, `tia_red`, `tia`, `trypsinogen`, `ubiquitin`, `lactalbumin_red`, `lactalbumin`, `betacasein`, `betalac`) with a provenance header (run folder, tracking id, RT, activation, CE, precursor mass). Backbone = the ProForma stripped of modifications (the mature chain as the table supplies it). Expected shifts from the ProForma: N-terminal `[Acetyl]-` → `+42.0106 @ 1..1`; `C[Formula:C34H31N4O4Fe#XL1]…C[#XL1]` → `+615.1695 @ first..second cysteine`; `C[MOD:00034#XLn]…C[#XLn]` → `-2.0157 @ (second cysteine)..(second cysteine)` per bridge (plan-time derivation: a b ion carries the bridge's deficit once it encloses both cysteines; inside the loop the bond is caged); `[Phospho]^5?` → total `+399.8 (5 × 79.9663)`, no site; `[Deamidated]?` → total `+0.984`, no site. Expected total = `theoretical_mass_Da − backbone mass`.
  Output `refine_expected_corpus.tsv`: `key\tbackbone\tactivation\texpected_total\texpected_shifts (mass@lo-hi;…)\tproto_total\tproto_score\tproto_shifts\tpass_total\tpass_sites`, where `proto_*` are the vendored prototype's results on the same masses at the run's tolerance and `pass_*` the criterion-a verdicts.
- [ ] **Step 2: Run the generator; read the verdict table.** Any row with `pass_total == 0` or `pass_sites == 0` → **stop and report** (per the working agreement) before committing. Rows that pass are pinned by the test exactly as the prototype computes them (total within `2 × tol`, each expected shift present with its window containing the site).
- [ ] **Step 3: Generator, mode `--cytc`:** write `refine_expected_cytc.tsv` with the numbers Task 2 hard-codes (cut, level count, Λb/Λy, five best totals with S/jumps/N, 21 targets, recount 49/45), so the C++ test can read them from the table in later maintenance and the hard-coded asserts can be dropped then (not now).
- [ ] **Step 4: Corpus sections** in `Refine_test.cpp`, one per key, each reading its fixture and the expectation row:

```cpp
START_SECTION(corpus_<key>_meets_criterion_a)
  auto fx = loadMassList(FI_REFINE_CORPUS + "<key>.tsv"); auto e = expectations.at("<key>");
  auto L = Refine::ladder(e.backbone, ionTypesFor(e.activation));
  auto d = Refine::detect(fx.masses, L, s_at(e.tolerance)); auto a = Refine::assemble(...);
  TEST_REAL_SIMILAR_ABS(a.candidates[0].total, e.expected_total, 2 * e.tolerance_da_at_precursor)
  for each expected shift with a site: TEST some jump of a.candidates[0] has |δ - mass| <= tol AND window ⊇ [lo,hi]
  TEST_EQUAL(a.candidates[0].score, e.proto_score)     // parity with the prototype, exact
END_SECTION
```

- [ ] **Step 5: Run** `ci cpp Refine_test` → PASS (all 14 + the Task 2 sections). **Step 6: Commit** (`FlashIDA/`): `test(refine): 14 corpus proteoforms as mass-list fixtures with expectation tables (criterion a)`; (`OpenMS/`): `test(refine): corpus sections`.

---

### Task 4: Config — `characterization.method`, `characterization.refine`, `mode: discriminating`

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:341-409` (enums + struct), `…/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:93-120` (name tables), `:501-544` (parse), `:1247-1300` (validate), `:1058-1095` (`applyCharacterizationMode_`: no change — `on = mode != Off` already covers the new value)
- Modify: `OpenMS/src/tests/class_tests/openms/source/Config_SchemaProjection_test.cpp` (new sections)

**Interfaces (produced):**

```cpp
  enum class AnnotationMethod { FlashTnT, Refine };
  enum class CharacterizationMode { Off, Ambiguity, Coverage, Exhaustive, Discriminating };
  enum class CharacterizationObjective { Ambiguity, Coverage, Exhaustive, Discriminating };
  struct OPENMS_DLLAPI CharacterizationConfig {
    AnnotationMethod method = AnnotationMethod::FlashTnT;
    RefineSettings refine;          // tolerance_ppm filled from level(2) at parse end
    bool has_refine_block = false;  // the key was authored (for the load errors)
    // … existing fields unchanged …
  };
```

- [ ] **Step 1: Failing sections** (`Config_SchemaProjection_test.cpp`):

```cpp
START_SECTION(method_defaults_to_flashtnt_and_parses_refine)
  Config c1 = load(json with characterization {mode:"off", protein_sequence:"PEPTIDEK"}) -> c1.characterization().method == FlashTnT, has_refine_block false
  Config c2 = load(… method:"refine", refine:{fdr:0.2, shuffles:50, grid_da:0.02, max_shift_da:300, min_ions:4}) -> Refine, refine.fdr 0.2 … min_ions 4, refine.tolerance_ppm == level(2).tolerance_ppm
  TEST_EXCEPTION(invalid_argument, load(… method:"Refine"))        // case-sensitive, like mode
END_SECTION
START_SECTION(refine_block_under_flashtnt_throws)        // message names characterization.refine and the method
START_SECTION(discriminating_under_flashtnt_throws)      // message: 'characterization.mode "discriminating" requires characterization.method "refine"'
START_SECTION(discriminating_under_refine_projects_level_selection)  // mode != Off -> levels_[2].selection on, objective == Discriminating
START_SECTION(refine_bounds_are_validated)               // fdr (0,1], shuffles >= 1, grid_da > 0, max_shift_da > 0, min_ions >= 1 — each violation throws, message names the key
START_SECTION(refine_block_unknown_key_throws)           // {"refine":{"fdr":0.5,"alpha":0.1}} -> rejectUnknownKeys message
```

- [ ] **Step 2: Implement.** Parse: `rejectUnknownKeys(charact, {…existing…, "method", "refine"}, "characterization")`; `method` string → enum with the hard-reject message pattern of `mode`; `mode == "discriminating"` → `Mode::Discriminating` + `Objective::Discriminating`; `refine` object → `rejectUnknownKeys(ref, {"fdr","shuffles","grid_da","max_shift_da","min_ions"}, "characterization.refine")` and the five values. Validate (in the existing per-level loop area): the two cross-key throws and the five bounds. Name tables: `characterizationModeName` gains `"discriminating"`; `objectiveName` likewise. At parse end: `characterization_.refine.tolerance_ppm = levels_[2].tolerance_ppm`.
- [ ] **Step 3: Run** `ci cpp Config_SchemaProjection_test ConfigSchemaParity_test` → PASS (`ConfigSchemaParity_test::GeneratedReference_CarriesEveryScanKey` is about scan keys and is unaffected; the C# reference regeneration is Task 10).
- [ ] **Step 4: Commit** (`OpenMS/`): `feat(config): characterization.method flashtnt|refine, characterization.refine block, mode discriminating (ADR-0049)`.

---

### Task 5: `FragmentAnalysis` — the method switch and the Refine MS2 match

**Files:**
- Modify: `FragmentAnalysis.h:73-115` (`ProteoformMatch` gains `std::shared_ptr<const RefineCandidates> refine;` appended last), `:357` (declare `runRefineMatching_`), `FragmentAnalysis.cpp:791-831` (`getTopFragmentMatches` switch), new `runRefineMatching_` after `runTagBasedFragmentMatching_`
- Create (in `Refine.h`): `struct RefineCandidates { Refine::Detect detect; Refine::Assemble assemble; double precursor_mass_difference = 0; int cut = 0; }`

**Interfaces:**
- Consumes: `Refine::ladder/detect/assemble/discriminating`, `config_.characterization().method/refine`.
- Produces: `ProteoformMatch` filled for the best path — `score = best.score`, `region_start = 0`, `region_end = L`, `proteoform_sequence = protein_sequence`, `ptm_sites = Refine::ptmSites(best)`, `fragments` = `best.ions_explained` (ion_type/ion_index/observed/theoretical/diff/qscore from the PeakGroup), `total_match_count = fragments.size()`, `tag_count = -1`, `matched_protein = "input_protein"`, `refine` = the candidate record; `matches` (the `TagBasedFragmentMatch` list) filled from the same ions so `getTopFragmentMatches`'s out-arrays and `tic_coverage` work unchanged.

- [ ] **Step 1: Failing section** (`FragmentAnalysis_test.cpp` is NOT touched — the switch is pinned in `Refine_test.cpp` through `FragmentAnalysis` directly):

```cpp
START_SECTION(getTopFragmentMatches_under_refine_fills_the_contract)
  Config cfg = load(inline json: method refine, protein_sequence CYTC105, tol 10, mode off)
  FragmentAnalysis fa(cfg); DeconvolvedSpectrum ms2 = spectrumFromMassList(FI_REFINE_CYTC)  // one PeakGroup per mass, charge from the file
  ProteoformMatch r; int found = fa.getTopFragmentMatches(CYTC105, 100, …arrays…, ms2, r, "HCD", 0.0, nullptr);
  TEST_EQUAL(r.score, 63) TEST_EQUAL(r.tag_count, -1) TEST_EQUAL(r.ptm_sites.size(), 2)
  TEST ptm_sites[0] == {start 1, end 8, -89.03}  ptm_sites[1] == {start 14, end 22, +615.17 (=526.14 - (-89.03))}
  TEST_EQUAL(r.fragments.size(), 65) TEST_EQUAL(found, 65)
  TEST_NOT_EQUAL(r.refine, nullptr) TEST_EQUAL(r.refine->assemble.candidates.size(), 182)
  TEST_REAL_SIMILAR_ABS(r.refine->precursor_mass_difference, 12351.30 - (m_seq + 526.14), 0.05)   // precursor mono from the spectrum's precursor PeakGroup (12351.30 for this scan)
END_SECTION
START_SECTION(getTopFragmentMatches_under_flashtnt_is_unchanged)   // same call with method flashtnt on FI_MS2_CYTC: result.refine == nullptr, tag_count >= 0 (the existing path)
```

- [ ] **Step 2: Implement** `runRefineMatching_(sequence, matches, stored_ms2, result, activation, tol)`: masses = sorted mono masses with an index map back to PeakGroups; `ladder`, `detect`, `assemble`; stdout markers:
  `[LEVELS] precursor_id=? cut=<c> n=<levels> b=<|Λb|> y=<|Λy|> excluded=<neutral losses> shifts=<Δm:S:nb:ny;…>` (precursor_id is stamped by the caller's log line; here print `scan=<spectrum scan number>`),
  `[CANDIDATES] scan=… total=<λk> S=<S> jumps=<k> N=<N> levels=<0,…,λk> windows=<r1-r2;…>` one line per candidate (all of them — decision 5),
  then fill `result`/`matches` as above. Precursor mass difference = `dspec.getPrecursorPeakGroup().getMonoMass() − (ladder.sequence_mass + best.total)` (0 when the precursor group is empty).
- [ ] **Step 3: Switch** in `getTopFragmentMatches`: `if (config_.characterization().method == AnnotationMethod::Refine) runRefineMatching_(…) else runTagBasedFragmentMatching_(…)`; the rest of the function unchanged.
- [ ] **Step 4: Run** `ci cpp Refine_test FragmentAnalysis_test FLASHIda_exploration_test` → PASS. **Step 5: Commit** (`OpenMS/`): `feat(refine): FragmentAnalysis switches on characterization.method; Refine fills ProteoformMatch + candidates`.

---

### Task 6: Tracker — candidate record, discriminating planner, shift-carrying-only narrowing

**Files:**
- Modify: `ProteoformTracker.h` (model fields, planner decl, new public methods), `ProteoformTracker.cpp:343-408` (`finalizeMS2`: keep `refine` from the winner), `:427-470` (`planNextScans` fork), new `planDiscriminating_` after `planExhaustive_` (`:889`), `:1353-1515` (`narrowModifications_` gate)
- Create: `ProteoformTracker_Discriminating_test.cpp` (register in three places)

**Interfaces (produced):**

```cpp
  struct DiscriminatingRecord
  {
    Refine::Discriminating target;     // mass, intensity, ion_a, ion_b
    int peak_index = -1;               // into m.winner_peaks (matched by mono mass at finalize)
    bool dispatched = false, returned = false;
    bool fits_a = false, fits_b = false;   // pooled: true once ANY scan's pieces fit
    int scans = 0;
  };
  struct RefineState
  {
    std::shared_ptr<const RefineCandidates> candidates;   // from the winner match
    std::vector<DiscriminatingRecord> records;            // intensity-desc, built at finalize
    bool decided = false;              // the round's decision has fired
    int winner_candidate = 0;          // 0 = best total, 1 = second (after a flip)
  };
  // ProteoformModel gains:  std::optional<RefineState> refine;
  // ProteoformTracker gains:
  /// MS3 return under refine: pool pieces for the record whose mass matches @p fragment_mass; returns true when the
  /// round is complete (every dispatched record returned) and the decision has not fired yet.
  bool recordDiscriminatingScan(int precursor_id, double fragment_mass, const DeconvolvedSpectrum& ms3,
                                double loose_ppm, double tight_ppm);
  /// Recount, decide, re-seed on a flip, emit the pooled row, log [MS3-DECIDE]. Returns whether the model flipped.
  bool decideRefine(int precursor_id);
```

**Behaviour:**
- `finalizeMS2`: after seeding from the winner, `if (win->match.refine) { m.refine = RefineState{…}; records = Refine::discriminating(c[0], c[1], …)` when `candidates.size() >= 2`, else empty; `peak_index` by nearest `winner_peaks[i].mono_mass` within `tol` }`. `m.modifications` already come from `ptm_sites` (the windows).
- `planNextScans`: after the exhaustive fork add `if (obj == Discriminating) { if (!m.refine || m.refine->decided) fall through to the Ambiguity branch (obj treated as Ambiguity below); else return planDiscriminating_(m, precursor_id, budget); }`.
- `planDiscriminating_`: `no_plan("single_candidate")` when `records.empty()` (one total); pool = records not yet dispatched whose nominal mass is not in `dispatched_nominal_masses`; emit up to `budget` targets exactly as `planExhaustive_`'s `emitTarget` (same charge-mode handling, `stage0_params = m.winner_params`, label = `ion_a` else `ion_b`, `frag_mass = winner_peaks[peak_index].mono_mass`); mark `dispatched`, stamp the nominal mass; stdout `[DISCRIMINATING] precursor_id=… pair=<λk_a>/<λk_b> S=<Sa>/<Sb> candidates=<n records> dispatched=<k> masses=<m1:ion_a|ion_b;…>`; `[MS3-PLAN] … objective=discriminating targets=k …` as the others.
- `recordDiscriminatingScan`: find the record by `|mass − fragment_mass| <= tol`; `Refine::pieceTest(ms3, seq, path_a, path_b, target, loose, tight)`; OR the verdicts into the record; `returned = true; ++scans`; return `!decided && all dispatched records returned`.
- `decideRefine`: `Refine::recount(a, b, targets_of_dispatched_records, confirmed)`; `[MS3-DECIDE] precursor_id=… S=<Sa>/<Sb> confirmed=<ca>/<cb> winner=<λk> flipped=<0|1>`; on `!a_wins`: `winner_candidate = 1`, re-seed `m.modifications = ptmSites(b)`, rebuild `m.fragments` by re-mapping every staged scan is not possible (pending cleared) — instead rebuild from the winner match: construct a `PendingScan` from `m.winner_peaks` + a `ProteoformMatch` for path b (same construction as Task 5's result) and `mapScanOntoModel_` it after `m.fragments.clear()`; `++update_index; emitPooledIDRow(m, "MS3-DECIDE", trigger)`; `decided = true`.
- `narrowModifications_`: `const bool shift_only = config_.characterization().method == AnnotationMethod::Refine;` — in Pass A the branch that tightens on a fragment matching **without** the shift (`base` matches) is skipped when `shift_only`; in Pass B the `else // PTM is OUTSIDE` arm is skipped when `shift_only`.

- [ ] **Step 1: Failing sections** (`ProteoformTracker_Discriminating_test.cpp`, driven through `feedScan → finalizeMS2 → planNextScans → recordDiscriminatingScan → decideRefine`, synthetic 12-residue sequence `"PEPTIDEKAGRK"` with masses chosen so two totals exist):

```cpp
START_SECTION(plan_targets_are_the_masses_the_two_best_paths_explain_differently)   // records == Refine::discriminating(c0,c1); intensity order; top budget
START_SECTION(single_candidate_dispatches_nothing)                                   // Review Focus 1: reason single_candidate
START_SECTION(dispatched_masses_are_not_replanned)                                   // second planNextScans before any return -> remaining records only
START_SECTION(round_waits_for_every_dispatched_mass)                                 // Review Focus 3: 3 dispatched, 2 returned -> recordDiscriminatingScan false; 3rd -> true
START_SECTION(pieces_pool_across_scans_of_one_mass)                                  // scan 1 fits nothing, scan 2 fits a -> record.fits_a true
START_SECTION(decide_keeps_the_best_when_confirmed)                                  // recount a>b -> decided, no flip, pooled row trigger "MS3-DECIDE"
START_SECTION(decide_flips_and_reseeds_modifications)                                // b confirmed, a not -> modifications == ptmSites(b), fragments rebuilt, update_index +1
START_SECTION(after_decision_planner_falls_through_to_ambiguity)                     // planNextScans -> containing fragments of the winner's windows (existing branch)
START_SECTION(narrowing_ignores_bare_fragments_under_refine)                         // a fragment matching WITHOUT the shift moves no boundary under refine; under flashtnt the same model moves it (control)
```

- [ ] **Step 2: Implement** as specified. **Step 3: Run** `ci cpp ProteoformTracker_Discriminating_test ProteoformTracker_Exhaustive_test ProteoformTracker_Localization_test` → PASS. **Step 4: Commit** (`OpenMS/`): `feat(refine): discriminating planner, pooled MS3 evidence, round decision, shift-carrying-only narrowing`.

---

### Task 7: Dispatch tail extraction and the MS3 return path

**Files:**
- Modify: `Exploration.h` (declare `dispatchFromModel`), `Exploration.cpp:1077-1235` (move the body from `const ProteoformModel* model = …` to the final `return nlr;` into `NextLevelResult Exploration::dispatchFromModel(int precursor_id, const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue, const ScanCommand* ms_ctx, ProteoformTracker* tracker, MS3FragmentMatcher::ProteoformContext proto_ctx, const ScanConfig& next_scan_config, int charge_floor, int next_level, const std::string& proteoform_sequence)`; `initiateNextLevel` calls it — byte-identical output)
- Modify: `FLASHIda.cpp:833-886` (MS3 return path), `ProteoformModel` gains `std::shared_ptr<const DeconvolvedSpectrum> winner_spectrum` (set in `finalizeMS2` under refine only, from the winner `PendingScan`: add `std::shared_ptr<const DeconvolvedSpectrum> spectrum` to `PendingScan`, filled by `feedScan` only when `config_.characterization().method == Refine`)

- [ ] **Step 1: Extraction.** Pure move; `ci cpp FLASHIda_exploration_test FLASHIda_ProcessScan_test` → PASS unchanged; commit `refactor(exploration): extract dispatchFromModel from initiateNextLevel (no behaviour change)`.
- [ ] **Step 2: MS3 return path.** After the existing `foldMs3` block, under `config_.characterization().method == Refine && objective == Discriminating`:

```cpp
if (tracker_.recordDiscriminatingScan(precursor_id, cached_ms2_ctx.fragment_mass, *ms3_spec,
                                      MS3FragmentMatcher::LOOSE_TOLERANCE_PPM, config_.level(3).tolerance_ppm))
{
  tracker_.decideRefine(precursor_id);
  const ProteoformModel* mdl = tracker_.getModel(precursor_id);
  if (mdl && mdl->winner_spectrum && mdl->has_ms2_ctx)
  {
    auto next = exploration_.dispatchFromModel(precursor_id, *mdl->winner_spectrum, parent_ctx.faims_cv, queue_,
                                               &mdl->ms2_ctx, &tracker_, tracker_.buildWinnerProteoformContext(precursor_id),
                                               config_.level(3).scans[0], config_.level(2).min_charge, 3, seq);
    for (auto& c : next.commands) { stampAndPush_(c, precursor_id); child_ids…; commands_pushed++; }
    cache ms3_contexts as the MS2 branch does (FLASHIda.cpp:658-664)
  }
}
```
  (Dispatch guards: `level(3).scans` non-empty is guaranteed by `validate` when mode ≠ off.)
- [ ] **Step 3: Section** in `FLASHIda_ProcessScan_test.cpp`? **No** — not in the approved list. Pinned instead by Task 13's golden (MS3 commands appear after the round) and by `ProteoformTracker_Discriminating_test` (decision). Run `ci cpp` → PASS. **Step 4: Commit** (`OpenMS/`): `feat(refine): MS3 return pools discriminating evidence, decides after the round, re-dispatches`.

---

### Task 8: C# config — `method`, `refine`, `discriminating`; schema reference

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:421-457` (`CharacterizationConfig`: `[JsonKey("method")] string Method = "flashtnt"`, `[JsonKey("refine")] RefineBlockConfig Refine` (new class with the five keys, defaults as C++), `Mode` description gains `discriminating`), `:882-890` (`JsonCharacterizationConfig` + `JsonRefineBlockConfig`), `MethodParameters.cs:255-264` (emit `method`; emit `refine` only when `Method == "refine"`), `:690-700` (`BuildFullReferenceConfig`: `Method = "refine"`, `Refine = { Fdr 0.25, Shuffles 77, GridDa 0.02, MaxShiftDa 333, MinIons 5 }`, `Mode = "discriminating"` — all non-default so a dropped key is visible), `FlashIDA/test-data/config_schema_reference.json` (regenerate with `REGEN_CONFIG_REFERENCE=1` in the Windows container)
- Modify: `.claude/skills/validate-flashida-config/validate.py` (`MODE_VALUES += "discriminating"`; new checks: `refine` block iff `method == "refine"`; `discriminating` iff `method == "refine"`; the five bounds) and `SKILL.md` (one paragraph)

- [ ] **Step 1:** C# edits; `ci cs` → `ConfigSchemaParityTests.Reference_IsNeverStale` fails (expected); regenerate the reference; `ci cs` → PASS (`Emit_And_Reload_PreserveEveryKey` loads the regenerated reference through the strict loader, so `discriminating` + `refine` must round-trip).
- [ ] **Step 2:** skill edits; `uv run python -I validate.py FlashIDA/test-data/configs/method_ms3_cytc_new.json` → unchanged verdict; on a temp config with `refine` under `flashtnt` → the new error.
- [ ] **Step 3: Commit** (`FlashIDA/`): `feat(config): characterization.method/refine/discriminating on the C# side; schema reference regenerated`; (parent): `skill(validate): method/refine/discriminating checks`.

---

### Task 9: Push 1 — land byte-identical and watch CI

- [ ] `ci cpp --full` → PASS (previous count + 2 new tests); `ci cs` → PASS with the calibration counts of the kinetic anchor (read them from `docker/README.md` at execution; +0 C# tests in Push 1); `ci golden-diff` → no cell moved in any of the 29 modes.
- [ ] `git pull --rebase` ×3; gitlinks; push; `gh run list --limit 1`; poll; record the run id. Red → stop, re-plan.

---

# PUSH 2 — golden-moving

### Task 10: Seven identification columns

**Files:**
- Modify: `IdaLogger.h:209-226` (`IdRowDescriptor` gains `double annotation_score = -1, total_shift = 0, second_total_shift = 0; int second_score = -1, cut = -1, n_levels = -1; double precursor_mass_difference = 0; bool refine = false;`), `IdaLogger.cpp:153-186` (header: append `\tannotation_score\ttotal_shift\tsecond_total_shift\tsecond_score\tcut\tn_levels\tprecursor_mass_difference`), `:675-854` (writer appends the seven; under `!refine` writes `-1\t\t\t-1\t-1\t-1\t` i.e. `-1` for the ints/score and empty for the three doubles), `FLASHIda.cpp` (the MS2 identification-row sites fill the seven from `match.refine` when non-null), `FLASHIda_LoggingFields_test.cpp` (`schema_column_counts`: identification 34 → 41; new section `identification_refine_columns_are_sentinels_under_flashtnt`), `LOG_COLUMN_ORDER_REFERENCE.md` (§3: 41 columns)

- [ ] **Step 1: Failing sections:** `schema_column_counts` (34 → 41); `identification_refine_columns_are_sentinels_under_flashtnt` (run the ms3_cytc-style inline config, every MS2 row ends `-1\t\t\t-1\t-1\t-1\t`); `identification_refine_columns_carry_the_candidates` (method refine on `FI_REFINE_CYTC` through `processScan` is not possible — a mass list is not a spectrum; instead drive `IdaLogger::writeIdentificationRow` directly with a descriptor built from Task 5's match: `annotation_score 63`, `total_shift 526.14`, `second_total_shift 655.19`, `second_score 50`, `cut 4`, `n_levels 22`).
- [ ] **Step 2: Implement; run** `ci cpp FLASHIda_LoggingFields_test FLASHIda_Logging_test` → PASS. **Step 3: Commit** (`OpenMS/`): `feat(log): seven refine columns appended to identification.tsv (sentinels under flashtnt)`; (parent) `docs: LOG_COLUMN_ORDER_REFERENCE identification 41 columns`.

---

### Task 11: Layer B — config and golden mode `refine_discriminating_cytc`

**Files:**
- Create: `FlashIDA/test-data/configs/method_refine_cytc.json` = `method_ms3_cytc_new.json` with `"method": "refine"`, `"mode": "discriminating"`, `"refine": { "fdr": 0.5, "shuffles": 300, "grid_da": 0.01, "max_shift_da": 700, "min_ions": 3 }`, `max_targets: 3`; `method_description` names ADR-0049 and the July fixtures.
- Modify: `FLASHIdaLogGolden_test.cs` (new test after `Golden_Inclusion_MS3_CytC`):

```csharp
        [Test, Category("Tier2")]
        public void Golden_Refine_Discriminating_CytC()
        {
            var ms3Map = BuildMs3IonMap(SpectraDir, "ms3_cytc2_");
            Assert.That(ms3Map.Count, Is.GreaterThan(0), "refine golden needs the ms3_cytc2 fixtures (no clean skip: a fixture-less run would be vacuous)");
            RunCase("refine_discriminating_cytc", "method_refine_cytc.json", "ms1_cytc2.txt", "ms2_cytc2_scan434.txt",
                    feedMs3: true, ms3Map: ms3Map, minMs2Commands: 1, postDriveAssert: AssertRefineDecided);
        }
        // identification.tsv: >= 1 MS2 row with annotation_score >= 0 and second_score >= 0; scan_commands.tsv: >= 1 MS3 row;
        // regression-stdout: not readable here, so the decision is pinned by the pooled row with trigger "MS3-DECIDE" in pooled_identification.tsv
        private static void AssertRefineDecided(string commandsPath) { … as AssertInclusionMs3Produced, plus the pooled trigger check … }
```
  If fewer than one of the three dispatched masses has a `ms3_cytc2_<ion>` fixture, the round never completes and the pooled `MS3-DECIDE` row is absent: raise `max_targets` in the config (Q23 option 3) until b47/b48/b51 fall inside the round, and record the value in the description.
- [ ] **Step 1:** run `ci cs` → red on goldens only (29 identification headers + the new mode absent); confirm `AssertRefineDecided` passes on the staged output; **Step 2: Commit** (`FlashIDA/`): `test(golden): refine_discriminating_cytc mode on the July 2026 fixtures`.

---

### Task 12: Golden recapture, mechanical proof, promotion

- [ ] **Capture:** `ci cs` stages `FlashIDA/bin/log-golden-output/<case>/*.normalized` for 30 cases; assert 30 × 5 non-empty.
- [ ] **Prove mechanical:** for the 29 existing modes, `identification.tsv` only: transform the committed golden by appending the seven sentinel cells to the header and every row; byte-compare with the staged `.normalized` → identical. Any other stream or any value change → stop.
- [ ] **New mode:** present the five streams outright; cross-check the MS2 row's `annotation_score`/`total_shift`/`second_total_shift` against `refine_core.py --masses <the engine's deconvolved masses of scan434 from scan_results.tsv>` (the engine deconvolves scan434 itself, so these numbers are new, not the report's); the MS3 rows' `ms3_fragments`; the pooled `MS3-DECIDE` row.
- [ ] **Present** the table and the `cp` lines; wait for sign-off; **no write into `test-data/golden` by the agent.** After the owner's `cp`: `ci golden-diff` → PASS on 30 modes; `ci cs` → PASS with +1 C# test over the kinetic anchor.

---

### Task 13: Docs

- [ ] Root `CLAUDE.md`: ADR list gains 0049 with the hazards (method default; `refine` block refused under `flashtnt`; `discriminating` refine-only; identification has 41 columns; 30 golden modes; markers on stdout; the prototype is a generator, not an oracle). `OpenMS/CLAUDE.md`: `Refine` owns Detect/Assemble/pieces; `FragmentAnalysis` switches on the method; tracker's discriminating planner and round decision. `FlashIDA/CLAUDE.md`: the new golden, `refine/` fixtures, `test-scripts/refine/`. KB `docs/kb/fragment-analysis/`: a `refine.md` page + README three-mode map → four; refresh the stale anchors the audit found (`computeFragmentMatch_` :1345, `getTopFragmentMatches` :791, `calibrateAndScore` :541, identification header in `IdaLogger.cpp:153`). `FIXTURES.md` pointer. ADR-0049 status → Accepted with the landing date; CONTEXT.md unchanged.
- [ ] Key documentation: update FlashIDA/docs/site/method.schema.json for characterization.method, characterization.refine.* and mode: discriminating (ADR-0058); confirm the Pages run republished.
- [ ] Commit docs separately; push; watch; add the calibration row to `docker/README.md`; update memory `project-refine-annotation-method.md` to DONE with the run id.

---

## Tests touched (the approved set)

| Kind | File | Change |
|---|---|---|
| C++ new | `Refine_test.cpp` | unit sections, cytochrome c report pins, 14 corpus sections, FragmentAnalysis switch sections |
| C++ new | `ProteoformTracker_Discriminating_test.cpp` | 9 sections (Task 6) |
| C++ edit | `Config_SchemaProjection_test.cpp` | 6 sections (Task 4) |
| C++ edit | `FLASHIda_LoggingFields_test.cpp` | `schema_column_counts` 34→41; 2 sections (Task 10) |
| Registration | `executables.cmake`, `flashida-ci.yml` (two lists) | +2 targets, +2 `-R` branches |
| C# edit | `FLASHIdaLogGolden_test.cs` | `Golden_Refine_Discriminating_CytC` + `AssertRefineDecided` |
| C# data | `config_schema_reference.json` | regenerated (Task 8) |
| Fixtures | `test-data/refine/**`, `configs/method_refine_cytc.json`, `golden/logs/refine_discriminating_cytc/` | new |

Not touched: `FragmentAnalysis_test.cpp`, `MS3FragmentMatcher_*`, `FLASHIda_ProcessScan_test.cpp`, `FLASHIda_exploration_test.cpp`, every existing golden's non-identification streams.

## Verification (end to end)

1. `ci lists` → both new targets reconciled. `ci cpp Refine_test` → the report's numbers: cut 4, 26/22 levels, 182 totals, +526.14 S 63 windows 1–8 / 14–22, +655.19 S 50, 21 discriminating masses led by y71 8111.25, recount 47/41.
2. `ci cpp --full` and `ci cs` green at Push 1 with every golden byte-identical (`ci golden-diff` clean).
3. Push 2: identification headers +7 on 29 modes, mechanical; mode 30 reviewed; CI green after promotion.
4. Offline run: `Flash.exe <ms1_cytc2> <out.tsv> method_refine_cytc.json <ms2_cytc2_scan434>` prints `[LEVELS]`, 182 `[CANDIDATES]` lines, `[DISCRIMINATING]`, and after the round `[MS3-DECIDE]`.
5. Hardware (layer C, outside this plan's gates): first `refine` + `discriminating` run on cytochrome c; watch for the first y-ion MS3 target ever acquired.

## Self-review

- Spec coverage: decisions 1–12 each map to a task above (table "Decisions carried").
- Placeholders: none; every section names its inputs and its assertions.
- Type consistency: `RefineSettings`, `Refine::Detect/Assemble/Path/Discriminating/PieceVerdict/Recount`, `RefineCandidates`, `RefineState`, `DiscriminatingRecord`, `AnnotationMethod`, `dispatchFromModel`, `recordDiscriminatingScan`, `decideRefine` are used with the same names in Tasks 1–7 and 10–11.
- Review Focus 1–5 each have a named section.

---

## Execution notes (2026-10-12, after approval — the tree moved while the plan was written)

**The kinetic model (ADR-0047/0048) has landed**: parent `13737b8`, OpenMS `66988cc`, FlashIDA `094e9c2`, CI run 38203475586 green. Calibration anchor is now `total=187 passed=186 failed=0 skipped=1`, ctest **28/28**, **31 golden modes**. Every count in this plan shifts accordingly: Push 1 expects ctest 30/30 and C# unchanged; Push 2 expects 32 golden modes (Task 12: assert 32 × 5 `.normalized`) and C# 188/187/0/1; "29 identification headers move" reads **31**.

**Anchors re-verified against the landed tree** (the plan's numbers were taken before the landing; function shapes unchanged):

| Plan cites | Now | Note |
|---|---|---|
| `Exploration.cpp:926` `initiateNextLevel` | **:905** | |
| `Exploration.cpp:1077-1235` dispatch tail (`const ProteoformModel* model = …` → `return nlr;`) | **:1054-1212** (`[MS3-DISPATCH]` at :1203) | Task 7 extraction |
| `Exploration.cpp:625-677` MS3 batch re-score | **:568** (`scoreCalibratedVariants`), `finalizeMS2` at :658 | |
| `FLASHIda.cpp:643-649` MS2 call | **:683** | |
| `FLASHIda.cpp:833-886` MS3 return path | **:872-922** (`foldMs3` :917, `erase` :922) | Task 7 |
| `IdaLogger.cpp:153-186` identification header | **:164-197** | Task 10 |
| `IdaLogger.cpp:675` `writeIdentificationRow` | **:698** | |
| `Config.cpp:501-544` characterization parse | **:501** unchanged | |
| `Config.cpp:1247` FragmentCount/protein_sequence validation | **:1282** | Task 4 throws go beside it |
| `Config.cpp:1058` `applyCharacterizationMode_` | **:1093** | unchanged body |
| `Config.h:341-409` enums/struct | `CharacterizationObjective` **:52**, `CharacterizationMode` **:352**, `CharacterizationConfig` **:386** | |
| `ProteoformTracker.cpp` :343/:410/:427/:697/:1353 | unchanged | |
| `FragmentAnalysis.cpp` :400/:791, `.h` :114 (`ms3_fragment_coverage`, append `refine` after it) | unchanged | |
| `sources.cmake:16` (`KineticModel.{h,cpp}`) | unchanged — add `Refine.{h,cpp}` on the next line | |

**Windows leg on this host: NOT READY** (`ci doctor` 2026-10-12: Windows engine down, 5 Thermo DLLs not decrypted). The owner accepted for the kinetic landing: test Linux locally, validate Windows in CI. Apply the same here:
- Task 8 (schema reference): regenerate via the CI artifact `config-schema-reference-capture` from the Push 1 run, commit the downloaded file, re-push.
- Tasks 11–12 (golden capture + proof): reuse `.superpowers/sdd/curried-hugging-blanket/fetch_capture.sh <RUN_ID>` (asserts N×5) and `golden_proof.py <golden/logs> <capture> --out report.md` (mechanical proof) — generalize the mode count to 32 and add a `--append-identification-sentinels` transform for this plan's residue; the owner `cp`s, never the agent.
- Every "`ci cs` → PASS" line in the plan therefore reads "CI windows-tests → green"; `ci cpp` / `ci cpp --full` stay local.

**Markers**: decision 10 of ADR-0049 was amended on 2026-10-11 (stdout, not `ida.log`); the plan already reflects it.

---

## Amendments (2026-10-12, the corpus finding — ADR-0049 decisions 3, 4, 9, 11 as amended)

Task 3 ran the prototype on the fourteen corpus rows before pinning and passed three. The owner re-grilled the cut and the disulfide model (ledger, round 1 and 2 answers). Every task below is executed against **this** block where it conflicts with the task text above.

**Settings.** `characterization.refine` has **seven** keys: `fdr` **0.2**, `shuffles` 300, `grid_da` 0.01, `max_shift_da` 700, `min_ions` 3, `max_levels` **20**, `jump_penalty` **2**. `RefineSettings` gains `int max_levels = 20; int jump_penalty = 2;` and `fdr` defaults to 0.2. Bounds (Task 4): `max_levels >= 1`, `jump_penalty >= 1`. C# (Task 8): `MaxLevels`, `JumpPenalty` with the same defaults; `BuildFullReferenceConfig` sets `Fdr 0.25, Shuffles 77, GridDa 0.02, MaxShiftDa 333, MinIons 5, MaxLevels 7, JumpPenalty 3`. `validate.py` checks all seven. `method_refine_cytc.json` (Task 11) writes the seven at their defaults.

**Detect (Task 1 amendment).** After the water/ammonia exclusion, a level whose region `[lo − 0.005, hi + 0.005]` contains `r ± n × 1.003355` for `n ∈ {1, 2, 3}` and `r ∈ {0} ∪ {shift of a level with higher signal}` is a **neutron satellite** and is excluded like a neutral loss. `Level::neutral_loss` becomes `enum class Exclusion { None, NeutralLoss, NeutronSatellite } excluded` (one field, three states). Then the **cap**: of the non-excluded levels keep the `max_levels` with the highest `signal`, ties by the summed intensity of the masses the level's ions match at its shift (desc), then the smaller `|shift|`; the dropped levels stay in `Detect::levels` with `excluded = Exclusion::Capped` (a fourth state) so `[LEVELS]` can print them. `Detect` gains `int n_kept` (the levels Λb/Λy are built from). `detect()` therefore needs the intensities: signature `detect(masses_sorted, intensities, ladder, settings)`.

**Assemble (Task 2 amendment).** DP cost = `1000 × jump_penalty + 1` on the scaled matrix (ion = 1000), so the quotient is `ions − penalty × jumps` and the remainder the jump count, exactly as the prototype's `cost=1001` generalizes. `Path::score = ions − settings.jump_penalty × jumps`. Ranking unchanged (score desc, jumps asc, intensity_sum desc). `recount`: `score_x = shared + confirmed_x − jump_penalty × jumps_x` — `recount` takes the penalty as a parameter (`int jump_penalty`).

**Pins (Task 2 amendment, Q5 = 2).** The cytochrome c sections read `FlashIDA/test-data/refine/refine_expected_cytc.tsv`, regenerated by `make_refine_tables.py --cytc` **at the engine's defaults** (α 0.2, both exclusions, cap 20, penalty 2), and no number is hard-coded for a second settings set. Expected at the defaults, from the prototype preview (`.superpowers/sdd/2026-10-11-refine-annotation-method/regrill/results4b.jsonl`, key `example`): cut 5, 8 levels, 5 kept (Λb 4, Λy 2), 14 totals, best +526.14 S 61 (65 ions, 2 jumps) windows [1,8] and [14,22], second +655.19 S 46 with 3 jumps, 18 discriminating masses. The recount against the new second total with the July pieces is whatever the generator computes under penalty 2 (b47, b48, b51 still fit the best path only — the implementer reports if not). The generator applies the amendments as a documented layer **on top of** the verbatim prototype functions (new helpers in `make_refine_tables.py`, never edits inside `refine_core.py`'s vendored blocks).

**Corpus (Task 3 amendment, Q4 = 3, Q7 = 3).** Layer A has **seven** rows: `ca, cytc, myoglobin, tia_red, ubiquitin, lactalbumin_red, betacasein`. The seven other fixtures are not committed; `refine_expected_corpus.tsv` lists the seven rows, and its header names the seven excluded rows with the reason (intact disulfides are outside the step-function model; lysozyme_red's corpus row carries four bridges and the oxidized mass). `FIXTURES.md` says the same in one sentence. Criterion a as defined above (total within 2 tol; every sited shift as a jump within tol whose window holds the site; site-less shifts through the total) plus parity on `score` with the generator. Prototype preview at the defaults (`results4b.jsonl`): all seven pass.

**Logging (Task 10 amendment).** `n_levels` = `Detect::n_kept` (after both exclusions and the cap); `cut` = `Detect::cut`.

**Markers (Task 5 amendment).** `[LEVELS] … cut=<c> n=<kept> b=<|Λb|> y=<|Λy|> excluded=<neutral losses>+<satellites>+<capped> shifts=<Δm:S:nb:ny;…>`.

**Review Focus additions.** (6) A level that is both a neutral loss and a satellite is counted once, as a neutral loss (the first rule that matches). (7) A scan with fewer non-excluded levels than `max_levels` is unchanged by the cap (every retained corpus row at 20).

**Task 7 amendment (2026-10-12, review finding).** The re-dispatch after `decideRefine` passes the **winner scan's** command, not `mdl->ms2_ctx` (which is the first fed MS2's context): `PendingScan` carries `std::shared_ptr<const ScanCommand> cmd` under refine beside `spectrum`, `finalizeMS2` copies the winner's into `ProteoformModel::winner_cmd`, and the MS3 return path dispatches with `mdl->winner_cmd.get()`. Also: an MS3 that arrives empty returns its record without evidence (round may close on it); `discriminating` with an enabled level-3 exploration is refused at load (the exploration return path does not pool yet).

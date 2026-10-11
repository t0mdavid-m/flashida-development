# 0047. A sweep decides by the modeled maximum, not by a measured point

Status: Accepted, **implemented 2026-10-11** (Push 1: OpenMS `feb705f`..`802498c`, FlashIDA `4b77832`..`81edc9e`; Push 2: OpenMS `0d0273b`..`28336de`, FlashIDA `47147fd`..`8a16ff8`). Grilled 2026-10-11; every decision below is the owner's, **except decision 3's fit method, amended at implementation on evidence** (see the amendment note under decision 3).
Related: [ADR-0048](0048-precursor-share-replaces-the-remaining-ratio-and-a-sweep-has-no-baseline.md)
— the companion decision this one presupposes (the quantity the model is fitted to, and the
removal of the reference scan). [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md)
— extended: a third measuring metric, and a follow-up at **both** levels for it.
[ADR-0044](0044-a-pre-scan-reads-out-its-levels-scan-range.md) and
[ADR-0045](0045-a-trap-pre-scan-is-measured-never-identified.md) — the trap pre-scan this
metric is designed to run on. [ADR-0007](0007-strict-config-schema-rejection.md) — a config
that cannot work is refused at load. [ADR-0014](0014-two-decision-sections-and-named-scan-configs.md)
— the metric is authored where the decision belongs.

## Context

Every exploration sweep the engine runs today is a **grid search**: a fixed set of collision
energies is acquired, each pre-scan is scored as it returns, and the best-scoring pre-scan is
the winner. At MS3 that is ruinous. A production MS3 scan on the Orbitrap at 120k with 8
microscans takes ~5 s (measured 4.918 s median over 238 scans on 2026-07-08), the optimal
energy differs from fragment to fragment, and a 14-point grid per target costs 69 s per target.
The 2026-07-08 cytochrome c run spent 19.5 min of its MS3 time on 17 targets of one MS2 scan.

The offline study behind the progress report of 2026-09-30 (`Progress Report 09/2026`,
section "Precursor Tuned Fragmentation") replaces the grid search by a **Kinetic Model**. On
108 HCD sweeps of 11 proteins (NCE 1–50 in steps of 1, Orbitrap), fragments are modelled as a
pool fed at the **fragmentation rate** s(CE) = max(0, −dP/dCE) and drained at the
**overfragmentation rate** k₂:

    B(CE) = β ∫₀^CE s(u) · e^(−k₂ (CE − u)) du,        CE* = argmax B(CE)

P is the **precursor share** (window signal over whole-spectrum signal of the same scan), β
cancels, and k₂ is fitted leave-one-protein-out at 0.0364–0.0390 per NCE (0.0388 with all
eleven in). The share is fitted by a **Gompertz curve** P(CE) = P₀ · exp(−e^((CE−c)/w)) so that
six pre-scans suffice: on a fixed grid of spacing 10 plus the top edge, mean regret over the
108 sweeps is 0.149 against 0.137 from 50 scans and 0.357 for the best fixed energy in
hindsight. The report's WIP list names exactly this work: validate for ion-trap scans, then
for MS3.

Nothing of it exists in the engine: no curve fit, no derivative, no k₂, no whole-spectrum sum
(grep of the FLASHIda tree, 2026-10-11). The winner is a discrete argmax over measured grid
points, and the `remaining_precursor` metric scores a ratio to a CE-0 baseline scan against a
target. Three engine facts bound the design:

- The C# scan factory rounds every collision energy to an integer on the wire, so the chosen
  energy is an integer on the instrument regardless.
- The sweep loop `for (ce = ce_min; ce <= ce_max + 1e-9; ce += ce_step)` drops the top edge
  unless the range divides by the step. Of all committed configs only the production
  `etc/method.json` MS3 grid (15..40/2) is affected; the study's result rests on both edges
  being acquired.
- Adding a column to a TSV log stream fails the golden canonicalizer on header width for all
  29 golden modes.

## Decision

1. **A fourth exploration metric, `kinetic_model`.** Authored as `exploration.metric` at either
   level, with a sibling object `exploration.kinetic_model` that is **required** when the
   metric is set and **rejected** when it is not. It is a *measuring* metric: it may decide a
   trap sweep (ADR-0045), it never matches a fragment, and at MS3 its pre-scans leave no
   evidence (ADR-0020). Orbitrap pre-scans under it are still deconvolved, matched and pooled
   exactly as under every other metric; trap pre-scans are not.

2. **The quantity is the precursor share** of each pre-scan (ADR-0048): the sum of the raw peaks
   the engine received inside the anchor isolation window, over the sum of all raw peaks it
   received for that scan. At MS3 the window is the stage-1 fragment window. No instrument TIC
   header, no bridge change, no reference scan.

3. **The fit is the study's bounded Gompertz, by its own lattice search — ported verbatim.**
   *(Amended at implementation, 2026-10-11. As grilled, this decision said Levenberg-Marquardt;
   the original text follows the amendment.)* `KineticModel::fitGompertz` reproduces
   `curve_families.fit("Gompertz", …, A_max=plateau_bound)` of the vendored pipeline: a coarse
   lattice over c ∈ 0..60 step 0.5 and 41 log-spaced widths on (0.25, 25) NCE, the closed-form
   least-squares P₀ at each lattice point clipped to (0, 1.1 × highest acquired share), then a
   refinement pass over c ± 0.5 (51 points) and w ÷1.3..×1.3 (41 points) around the coarse
   minimum. At least three pre-scans with a finite share are required; fewer is **no fit**.
   The fit constants (cap factor, width box, lattice and refinement spans, minimum points) are
   constants of the validated algorithm, not configuration.

   *Why the amendment:* decision 10's layer A was run first with LM as written here. Against
   the pipeline's 1080 fits (108 sweeps × 10 grid offsets) LM reached the **identical** CE* on
   941, within ±1 on 1035, and missed 45 — mostly with an equal-or-lower RSS at a different
   width, because the Gompertz RSS has a **flat valley in (P₀, w)** where several (P₀, w) pairs
   fit six points equally well and the pool's argmax moves with w. A five-start LM made the
   agreement *worse* (921). The owner's acceptance test was "equivalent results" (Q6/Q15:
   CE* within ±1 on every fit, identical on ≥ 95 %); LM met the second bar and failed the
   first. The lattice port agrees with the pipeline on **1080 of 1080** fits with identical
   mean regret (0.148518 both sides), which is what `KineticModel_test` now pins. The study's
   result was obtained with this fit, so shipping it is the conservative choice; the cost is
   ~4 500 evaluations per fit, well under a millisecond at six to fifty points.

   *As grilled (superseded):* Eigen's LM on the residual P_i − P₀·exp(−e^((CE_i−c)/w)), with the
   bounds imposed exactly by reparametrization (w = w_min·(w_max/w_min)^σ(θ), P₀ = cap·σ(φ),
   c free), a landmark seed (P₀ = highest share, c at the interpolated P₀/e crossing, w from the
   0.85·P₀ crossing; c = ce_max and w = 4.2 NCE when a crossing is absent), non-convergence =
   no fit; the basin risk was to be bounded by decision 10 and remedied by a three-start LM.
   Decision 10 is what caught it.

4. **The modeled maximum is an integer energy in [1, ce_max].** s(CE) is read from the fitted
   curve on every integer energy, the pool is the study's recursion
   B(k) = e^(−k₂)·B(k−1) + s_k·(1 − e^(−k₂))/k₂, and CE* is its argmax. It **may lie below
   `ce_min`** — the curve is fitted, not read at grid points, and a maximum below the first
   acquired point is real information that the grid started too high. It is **not** clamped to
   the acquired range; when it sits at 1 or at `ce_max` that is logged.

5. **A follow-up is always acquired, at both levels.** CE* is a computed energy and in general
   no pre-scan ran at it, so there is nothing to cascade from. The follow-up is built from the
   un-overridden scan config with CE* as its collision energy, with or without overrides, at
   MS2 and at MS3. No reuse of a coincident pre-scan: one rule, one code path.

6. **k₂ is authored per activation and per level, and never defaulted.**
   `exploration.kinetic_model.k2` is a map from activation name to a rate per NCE
   (`{"HCD": 0.0388}`), validated at load against the swept activations: a swept activation
   without an entry is a **load error**; an entry for an activation not swept is a
   `[CONFIG-WARN]`. k₂ differs by an order of magnitude between HCD and CID and is unknown at
   MS3 and on the ion trap, so a default would be a silent wrong answer — the shape of the
   stomped `snr_threshold` (ADR-0040). The engine never fits k₂; it comes from offline fits on
   sweeps of **other** proteins.

7. **No fit means no follow-up.** The group ends as a no-winner group does today
   (`[EXPL-ABORT]`, with the reason), and the target is not acquired at this level. No fallback
   to the authored collision energy: an energy the model could not justify is not acquired in
   its name.

8. **Both sweep edges are always acquired.** The CE loop is corrected so `ce_max` is the last
   grid point whether or not the range divides by the step — the rule the study validated. No
   committed golden has a non-dividing grid; the production method's MS3 grid gains a scan at
   NCE 40.

9. **The live fit is logged where every other per-variant quantity lives.** `scan_results.tsv`
   gains `precursor_share` on every MSn row with an isolation window (every metric, every
   scan type), and, on the row that completes a kinetic group: `fit_p0`, `fit_ce_max_s`,
   `fit_width`, `k2`, `modeled_ce`, `modeled_b`, `fit_points`, `fit_rss`, and `energy_source`
   (`modeled` | `measured` | `none`). The follow-up command's `collision_energy` in
   `scan_commands.tsv` carries CE*; no new column there. Stdout is not a log (it is lost on the
   instrument).

10. **Validation is against the study's own data, in three layers.**
    - *A, the math alone:* a committed TSV of the 108 sweeps × 51 energies (share and the
      ±3-NCE fragment-share reading) and a committed expected table generated by the study's
      pipeline (per sweep and per grid offset: P₀, c, w, CE*, regret). The C++ test asserts,
      over all 10 grid offsets (1080 fits): CE* within ±1 NCE of the pipeline's on **every**
      sweep and identical on ≥ 95 %; mean regret within 0.005 of the pipeline's 0.1485;
      P₀ ± 0.02, c ± 0.5 NCE, w ± 15 % (the grid's own resolution); Ubiquitin 9+ at offset 0
      → NCE 35. Both tables carry a provenance header (generator, source table, date) that
      the test asserts is present. The generator and the two pipeline modules it imports
      (`pipeline.py`, `curve_families.py`) are **vendored** into `FlashIDA/test-scripts/kinetic/`
      so the reference math and the tables it produced are in one repository; the corpus
      analysis repo has no remote, and this copy is the reference until it has one. The copy
      records the corpus commit it was taken from.
    - *B, the engine:* pre-scan spectra cut from the corpus mzMLs for three sweeps
      (cytochrome c 17+, which is corpus sweep 4 of cytochrome c and already has an MS1
      fixture; ubiquitin 9+, the report's worked example; one disulfide protein), **all 50
      energies each**, so any grid and any CE* resolves; the follow-up command's CE equals the
      pipeline's CE* for that sweep and grid, the logged parameters match layer A, trap rows
      stay unidentified. At MS3, the mechanism (share on the stage-1 window, fit, CE* under
      an authored k₂, follow-up) on per-energy fixtures cut from the 2026-07-08 cytochrome c
      run's 17-parent CID sweep, with a harness selector keyed by ion **and** energy.
    - *C, goldens:* one MS2 mode (`exploration_kinetic`, cytochrome c 17+, trap overrides) and
      one MS3 mode (`exploration_kinetic_ms3`, one 2026-07-08 parent, k₂ authored as a
      **placeholder** and the config comment saying so).

## Consequences

- **MS3 has no k₂ yet.** Nothing in this ADR produces one; the `precursor_share` column
  (decision 9, and ADR-0048) is what makes an MS3 k₂ fittable from `scan_results.tsv` of a
  dense Orbitrap MS3 sweep, without re-reading the mzML. Until that fit exists, an MS3
  `kinetic_model` config carries HCD's value as a declared placeholder. The MS3 golden pins the
  mechanism, not the energy.
- **No trap pre-scan has ever been acquired on hardware.** The study's shares were read from
  the same 240k Orbitrap scan as its ground truth, which is an upper bound for any pre-scan.
  Whether the share holds on unit-resolution trap centroids is still open there, as ADR-0044
  already records.
- **Goldens move** — the `scan_results` header in all 29 modes (header-only, mechanically
  provable), and whatever ADR-0048 moves. Delivery is in two pushes: first the byte-identical
  part (decision 8, the pure helper with layer A, the fixture cuts, the harness selector), then
  everything golden-moving, each moved cell proven mechanical or explained.
- **The fitter lives in a new pure-function helper** beside the other runtime helpers, so
  layer A runs without the engine, and the glossary gains Precursor share, Fragmentation rate,
  Gompertz curve, Overfragmentation rate, Kinetic model and Modeled maximum.
- **The reference math exists twice** — in the corpus analysis repo and in the vendored copy
  under `test-scripts/kinetic/`. The vendored copy is the one the committed tables were
  generated from and the one CI can reach; if the corpus pipeline changes, the copy, the two
  tables and the expected numbers in the layer-A test move together or not at all.

## Alternatives rejected

- *Levenberg-Marquardt instead of the study's lattice.* Was the grilled choice (decision 3 as
  originally written); rejected at implementation when the equivalence test it was to be
  bounded by showed 45 of 1080 fits landing on a different CE* (flat valley in (P₀, w)). The
  lattice port — "exactly reproducible and basin-free, but ~4 500 evaluations per fit" — is
  what ships; the evaluation cost is immaterial at six to fifty points.
- *Adaptive point placement.* Not validated by any study; the decimation result is for a fixed
  grid with both edges.
- *A `decision` switch on `remaining_precursor` instead of a metric.* Leaves the target key
  meaningful on a sweep that ignores it, and every existing metric gate (trap, follow-up,
  multiplexed) would need a second predicate.
- *A default k₂.* Silent wrong answer on every activation and level it was not measured on.
- *Fallback to the authored collision energy on a failed fit.* Acquires an energy the model
  could not justify under the model's name; the owner chose to lose the target instead.
- *Penalty terms for the bounds.* A penalty moves the minimum unless its weight tends to
  infinity, which conditions the solver badly; reparametrization is exact.
- *Logging the fit to stdout only.* Lost on the instrument.

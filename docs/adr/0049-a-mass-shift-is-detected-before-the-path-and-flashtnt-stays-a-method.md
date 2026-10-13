# 0049. A mass shift is detected before the path, at an FDR, and FLASHTnT stays a method

Status: **Accepted, implemented 2026-10-13** (grilled 2026-10-11; **amended 2026-10-12 after the corpus
finding**, decisions 3, 4, 9 and 11; layer B's fixture amended at implementation, see Consequences).
Landed in three pushes: parent `6596d15` (byte-identical, CI run 38310697976 green), `072070f` (the
seven columns and the new golden mode, CI run 38356161444 red on goldens by design) and `5634488` (the
promoted goldens, CI run 38377218042 green: C# 191/190/0/1, ctest 30/30). Every decision below is the owner's. The Context section is
kept as written before implementation.
Source: the owner's Progress Report 09/2026 (30.09.2026), section "Annotate fragments, find mass
shifts", and the prototype that produced its numbers
(`C:\FLASHIda\fi_refine_publication_notes\evidence\`, outside every repo).
Related: [ADR-0013](0013-characterization-mode-is-the-single-ms3-switch.md) — `characterization.mode`
stays the single MS3 switch and gains a fourth objective. [ADR-0005](0005-ms3-target-is-a-containing-fragment.md)
— the containing-fragment objective is untouched and runs after the new one.
[`0006-winner-anchored-fragment-pooling.md`](0006-winner-anchored-fragment-pooling.md) — the pooled
model keeps its shape; only what seeds it changes under the new method. [ADR-0007](0007-strict-config-schema-rejection.md)
— the new keys are refused where they cannot act. [ADR-0047](0047-a-sweep-decides-by-the-modeled-maximum-not-by-a-measured-point.md)
/ [ADR-0048](0048-precursor-share-replaces-the-remaining-ratio-and-a-sweep-has-no-baseline.md) — land
first; this work is planned against the tree they leave.

## Context

Real-time annotation of an MS2 scan is FLASHTnT today: FLASHTagger reads sequence tags from the
deconvolved masses, FLASHExtender extends them along the one supplied sequence and returns a
truncation and up to two blind mass shifts as residue ranges, and the engine recomputes the matched
fragments from that answer (`FragmentAnalysis::runTagBasedFragmentMatching_`). The shift set is
frozen when the tracker seeds its model from the staged scan with the highest extender score;
MS3 evidence only narrows ranges and never re-estimates a shift. There is no decoy and no error rate
anywhere in the loop.

The owner's finding, stated in the report: that annotation "is not dependable for localization. It
often detects wrong mass shifts or truncations", so MS3 evidence cannot be merged into it. The reasons
are structural, not tuning (`evidence/flashtnt_mass_shift_detection.md`): a shift is opened by **one**
fragment that does not fit, at a fixed price (19 points, 28 without a UniMod match); a shifted level
must carry a tag; the joint pass has to end on the precursor mass, so the last shift takes whatever is
left; at most two shifts. On cytochrome c that merged −89.03 and +615.17 into one +526.14 placed on a
single residue, and on the July 2026 instrument run into `(1-19)[+657.17]`.

The report's alternative needs no search. The sequence is given. **Detect**: offset every theoretical
b/y ion by a trial shift and count matched ions, subtract the matches the unshifted ladder already
explains (internal coincidences), and call the peaks that pass an FDR from shuffled sequences the
levels. **Assemble**: a level is a diagonal of the spectral-alignment matrix; mass shifts are the
steps between levels along the sequence; at every cleavage site the b level and the y level add up to
the total; one dynamic programme per candidate total (rows = cleavage sites, columns = levels, +1 per
matched ion, a penalty per jump) gives the best path and its score. **MS3 tests the best paths of the
two best totals where they differ**, by isolating the observed masses they explain differently and
asking which path the pieces fit. On the report's cytochrome c scan (150 masses, 10 ppm) at the
report's settings (α 50 %, penalty 1, no satellite rule): cut 4, 22 levels after the neutral-loss
exclusion, 182 totals, best +526.14 Da at score 63 with the two shifts windowed to residues 1–8 and
14–22, second +655.19 Da at 50, 21 discriminating masses, and a recount of 47 against 41 after the
July MS3 pieces confirm b47, b48 and b51. At the engine's defaults below the same scan keeps its best
path (+526.14, the same windows) at score 61, the second total is +655.19 at 46 with three jumps, and
18 masses discriminate.

A Python prototype of all three steps exists and reproduces every number above. No C++ exists for any
of them. FLASHTnT itself is off-limits to modify (owner's rule); the IDA engine around it is not.

**The corpus finding (2026-10-12).** Before any corpus row was pinned, the prototype was run at the
report's settings on the fourteen proteoforms of the owner's MS2 characterization corpus (deconvolved
mass lists of each proteoform's best scan, 130–313 masses). It passed three. Three causes, each with
its own decision below:

- At α 50 % the DP buys chance ions with pairs of jumps (myoglobin: three jumps for six ions; ca:
  nine jumps), and on four scans 77–214 levels pass the cut, which makes 2,700–15,500 candidate totals.
  MS3 can only overturn such an excursion while the true path still ranks second, which holds at
  α 20 % and not at 50 %, where the two best totals are siblings sharing the same jumps.
- On the September cytochrome c scan the b ions after residue 20 sit on three levels, +657.17 (16
  ions), +655.14 (15) and +654.13 (11): the true level and its two- and three-neutron satellites,
  deconvolution picking the wrong monoisotopic peak on large fragments. The path jumps onto the
  satellite at residue 54 (19 ions for one jump) and the true total ranks third to tenth at every α.
  MS3 cannot repair it: the two best totals are satellites of each other, and the pieces of a 2 Da
  misassigned fragment come out at their true masses, so they fit neither path. Only Detect can refuse
  the level. The report's example scan and the engine's deconvolution of the July scan carry no such
  satellite, which is why the report never met it.
- Six corpus proteoforms carry intact disulfides. Inside a loop the proteoform is not a step function
  of levels: a fragment holding one cysteine of a bridge carries +31.97 (persulfide) or −33.99
  (dehydroalanine), not −2.016, and lysozyme has 7 cleavage sites of 128 outside every loop,
  lactalbumin 8 of 122, trypsinogen 25 of 228. The −2.016 level appears only where many fragments
  enclose a whole loop, and a total the path could end on needs a b level and a y level that both
  exist, which tia's scan does not provide.

## Decision

1. **A method, not a replacement.** `characterization.method: "flashtnt" | "refine"`, default
   `flashtnt`. No committed config and no golden moves by the switch alone. The name is the project's
   (FLASHIda:Refine): a method file that says `refine` names the workflow the paper describes.
2. **The supplied sequence is taken as given.** The engine never guesses whether an initiator Met was
   cleaved; the same proteoform reads −89.03 Da at residue 1 on a Met-start sequence and +42.01 Da on
   the mature chain, and both are correct annotations of what was supplied.
3. **Detect, as the report states it, with seven authored settings** in a nested object
   `characterization.refine: { fdr, shuffles, grid_da, max_shift_da, min_ions, max_levels,
   jump_penalty }` (defaults **0.2**, 300, 0.01, 700, 3, **20**, **2**), accepted only under
   `method: refine` (load error otherwise). Single pass: Expected is counted through the masses the
   unshifted ladder explains, and the shuffled sequences are matched once against the rest — a
   proteoform whose fragments mostly carry a shift earns a high cut (tia: 22 of 247 masses explained
   unshifted, cut 8 at α 0.2), a limit kept deliberately because a second pass feeds pass one's chance
   levels back into the decoys and drops the cut to the floor on every corpus scan. Levels are typed
   by the ions attached (b, y, or both). No merging of satellites into their reference. **Two
   exclusions, the same rule shape:** a level one water or one ammonia below 0 or below a level of
   higher signal is a neutral loss and not a level; a level one, two or three neutron masses
   (1.00335 Da) from 0 or from a level of higher signal is a neutron satellite and not a level. Of
   the levels left, at most `max_levels` of highest signal are kept (ties by the summed intensity of
   the masses attached, then the smaller shift); the cap bounds the candidate totals, it is inert on
   every retained corpus row at 20. No proton-loss rule. The shuffle seed is an engine constant. The
   ion alphabet follows the activation as it does today (c/z under ETD). α 0.2 rather than the
   report's 0.5 because the report's reason for 0.5 — MS3 tests the levels — holds only while the
   true path still ranks second.
4. **Assemble, as the report states it, with a jump penalty.** One DP per candidate total
   λk = λb + λy (0 included); score = matched ions − `jump_penalty` × jumps (the report wrote the
   penalty as 1; at 1 a pair of jumps that buys three chance ions nets +1, at 2 it nets −1, and the
   report's example is unchanged at 2); no jump into 0, none out of λk; a path may revisit a level
   (the report imposes no rule against it); on a tie within a total the path with fewer mass shifts;
   totals ranked by score, ties by fewer shifts, then by the summed intensity of the explained masses.
5. **What an MS2 reports before any MS3**: the best path of the best total, each jump as a shift whose
   range is its window (every placement with the same count), rendered as today; plus the
   **precursor mass difference** = measured precursor mass − (sequence mass + λk), logged and never a
   gate; every candidate total with its best path and score printed to the console.
6. **The contract with the rest of the engine is unchanged.** The new method fills the same
   per-scan match the tracker, the identification row and the pooled log consume (score = S, shift
   ranges = windows, fragments = explained ions, tag count −1), and keeps one extra per-precursor
   record: the ranked candidate totals with their best paths, read only by the MS3 step below. During
   an exploration sweep every variant is annotated and the model is seeded from the variant with the
   highest S, as it is seeded from the highest extender score today.
7. **A fourth MS3 objective, `characterization.mode: "discriminating"`**, valid only under `refine`
   (load error under `flashtnt`); `ambiguity | coverage | exhaustive` accept both methods. A
   **discriminating mass** is an observed MS2 mass the best paths of the two best totals explain
   differently — one explains it and the other not, or as different ions; a mass both give the same
   ion is shared. The top `max_targets` by intensity are dispatched through the raw-mass path the
   exhaustive objective already uses, b and y alike, skipping masses already dispatched for the
   precursor. Which ions a path explains is read at the first placement of its jumps; the prototype's
   assumption that no explained ion depends on the placement fails on most corpus paths.
8. **A piece fits a path only when it carries a shift.** Per path, every prefix and suffix of the
   target is predicted with that path's shifts; a piece predicted at the same mass under both paths is
   shared and decides nothing; a discriminating piece observed within the MS3 tolerance confirms the
   target for its path **only if it carries a non-zero shift** — a bare piece proves nothing, because a
   labile group leaves without a trace (the report's merge rule). Calibration uses shared pieces only.
9. **MS3 evidence is pooled and the decision waits for the round.** Pieces seen in any MS3 scan of a
   target (energy variants, repeats) count once, keyed per precursor and discriminating mass. When every
   MS3 of a `max_targets` round has been received, the score is recounted for both paths — shared
   masses plus confirmed targets minus `jump_penalty` × jumps, one definition of S throughout — the
   higher score decides, on equal scores fewer shifts, and the loop re-plans. One round decides; the
   winner's windows are then narrowed by the existing containing-fragment machinery, re-planned after
   each round.
10. **Logging**: decision markers `[LEVELS]`, `[CANDIDATES]`, `[DISCRIMINATING]`, `[MS3-DECIDE]` on
    **stdout**, where every engine marker lives (`[MS3-PLAN]`, `[EXPL-WINNER]`, `[MS3-DISPATCH]`) —
    `ida.log` is the MS1 consumer format (ADR-0032) with two readers and admits no other line — and
    new `identification.tsv` columns `annotation_score`, `total_shift`, `second_total_shift`,
    `second_score`, `cut`, `n_levels`, `precursor_mass_difference` (−1 or empty under `flashtnt`;
    `flash_extender_score` and `tag_count` stay −1 under `refine`). Adding columns moves every log
    golden's header: a golden-moving push.
11. **Validation**, three layers. **A**: ordinary ctest sections over committed deconvolved-mass
    fixtures — the report's cytochrome c scan, pinning its numbers **at the engine's defaults** (the
    cut exactly, the FDR values at a tolerance because no C++ generator reproduces numpy's
    permutations; the report's own settings are not a second pinned configuration), and **seven**
    corpus proteoforms (ca, cytochrome c, myoglobin, the reduced trypsin inhibitor, ubiquitin, reduced
    α-lactalbumin, β-casein), each asserting that the best total lies within tolerance of the
    ground-truth mass minus the backbone mass and that every sited shift is found with a window
    containing its true site (acetyl at residue 1, the heme between its cysteines; five phospho and a
    deamidation count through the total). The six proteoforms with intact disulfides (lysozyme, RNase A,
    the oxidized trypsin inhibitor, trypsinogen, α-lactalbumin, β-lactoglobulin) and the reduced
    lysozyme row (its corpus entry carries four bridges and the oxidized mass) are **outside layer A**:
    an intact disulfide is outside the step-function model, and the fixture tree says so rather than
    pinning a wrong answer. The prototype is vendored into `FlashIDA/test-scripts/refine/` as the
    one-time generator of those expectation tables, with this ADR's amendments applied on top of the
    verbatim report code, and is not an oracle the suite keeps diffing against. **B**: a log-golden
    mode on the July 2026 run fixtures (`ms2_cytc2_scan434` + the 17 `ms3_cytc2` parents) end to end;
    the engine's deconvolution of that scan is clean (two levels, best +42.01@1–4 and +615.17@14–20);
    targets without a fixture stay untested, and `max_targets` may be raised so b47, b48 and b51 fall
    inside the round. **C**: the acceptance run on hardware, where a y-ion MS3 target would be acquired
    for the first time.
12. **Order**: ADR-0047/0048 land first; this is planned against the tree they leave. The retirement
    of the mistyped cytochrome c string (S47/G60) in five configs is a separate, golden-moving decision
    and is not part of this work.

## Consequences

- An operator reading a method file sees which annotation produced the identifications and which
  objective chose the MS3; a `refine` run carries an FDR per level where a `flashtnt` run carries none.
- MS3 gains a second purpose. Under `discriminating` it adjudicates between two candidate proteoforms
  before anything is narrowed; the containing-fragment rounds that follow narrow the winner. Both
  purposes read only shift-carrying evidence, which retires the bare-fragment inference the heme finding
  invalidated — for the new method; `flashtnt` keeps its current narrowing.
- The engine's defaults differ from the report's example settings in three places (α, the penalty,
  the satellite rule); the report's headline path survives all three, its second-best total and its
  discriminating masses do not. A paper that quotes the engine quotes the defaults.
- The loop closes once per round rather than once per MS2, which the engine has not done since the
  debugging build the owner mentioned on 2026-09-22.
- A supplied sequence that does not fit the measured protein shows up as a large precursor mass
  difference on every scan, visible in the log instead of silently absorbed into a shift.
- An intact disulfide is outside the model: the method can report the total it implies where both ends
  are observed (RNase A −7.08, β-lactoglobulin −4.03 on the corpus) but not where the bridges sit. A
  disulfide-aware alphabet (the +31.97/−33.99 pair) was considered and left for a decision of its own.
- The two-spectra caveat the prototype records stands for layer A: the example MS2 and the July MS3
  scans are different spectra of the same proteoform.
- Open on hardware, carried from the report's WIP list: ion-trap pre-scans, ETD through the iAPI, and a
  y-ion MS3 target have never been acquired.

At implementation (2026-10-13):

- **Layer B runs the scan57 pair, not the July pair.** The log-golden mode `refine_discriminating_cytc`
  (the 32nd) drives `ms1_cytc.txt` + `ms2_cytc_fresh_scan57.txt` and the `ms3_cytc_*` fixtures through
  `method_refine_cytc.json` (`method_ms3_cytc_real.json` + method, mode and a `refine` block,
  `max_targets` 3), because the July scan's discriminating masses (b4–b13) have no MS3 fixtures. On it
  the engine reproduces the prototype at the defaults on the same 117 masses: cut 5, three levels kept,
  best +526.14 at S 55 (−89.03 @ 1–8, +615.17 @ 15–22), second +6.92 at S 43. The round dispatches
  b61 (real MS3 pieces), y71 and y79 — the first y-ion MS3 targets the engine has dispatched, answered
  by the committed zero-peak fixture `ms3_empty_scan0.txt` because a round closes only when every
  discriminating MS3 has returned — decides with the winner kept, and the ambiguity-narrowing MS3s
  that follow (b51 among them) tighten the heme window to 15–21.
- **The new mode found an engine bug outside this ADR.** An MS3 that arrived with zero peaks skipped
  `deconvolveMSn` and read back the previous scan's stored deconvolution — identified, folded and
  logged with it, in every mode, on the instrument too. It now clears explicitly (OpenMS
  `3ea17e49cb`). No unit test pins it; the golden's `mass_count 0` MS3 rows do.
- **Accepted limits.** MS3 evidence folded during a round is dropped when the decision flips the
  model; `Refine::assemble` returns empty without a message on a ladder size mismatch; a re-matched
  non-winner is stale after a flip; `[REFINE]` is not printed on the exploration MS2 path; the
  golden's empty-fixture MS3 rows carry rt 0.
- `identification.tsv` grows from 34 to 41 columns (decision 10); the seven are valued on the regular
  and the exploration self-identification MS2 rows under `refine`, and a real score of −1 is told from
  the sentinel by a non-empty `total_shift`.
- **A round that can never close through MS3 decides for the best path and falls through to ambiguity
  in the same call** (final review, 2026-10-13). Two cases: the pool is exhausted with nothing awaiting
  its return — every discriminating record refused by the fragment-charge floor, or already dispatched
  in an earlier survey — and a winner scan that cannot be isolated for MS3 (an ETD MS2 among them).
  Both print `[DISCRIMINATING] precursor_id=… decided=fallthrough reason=pool_exhausted|
  winner_scan_not_ms3_capable`, set the decision without a recount or a pooled row, and plan the
  containing-fragment MS3s of the best path at once. *(Amended by ADR-0054, 2026-10-13: the second case
  is gone — an ETD winner's round runs, and if no dispatched record has a b/y side it closes with
  `decided=kept reason=no_annotatable_pieces`, path a kept without a recount; `pool_exhausted` is the
  fall-through's only reason.)* A round with a dispatched MS3 still outstanding
  waits, as before. In the same pass: a discriminating mass only path b explains is dispatched with the
  unassigned ion label (as `exhaustive` marks a mass with no identity) instead of path b's label stated
  against path a's model; and a record is frozen once the decision has fired — a late MS3 of a
  discriminating mass is folded by the ambiguity path and never rewrites the round's evidence. None of
  this moves a committed golden: every dispatched record there carries path a's label and no round
  was exhausted.
- **Two findings of the final review are deferred, by ruling, to decisions of their own.** The decoy
  shuffle uses `std::shuffle` over `std::mt19937_64`, whose output is implementation-defined, so the FDR
  per height — and with it the cut — may differ between standard libraries; on the committed cytochrome c
  scan the cut's FDR sits at 0.179 against the 0.2 threshold on both toolchains today. A portable shuffle
  (Fisher–Yates spelled out) would move the layer-A pins and is a golden-moving push. And the
  ambiguity narrowing that follows the decision never reads the round's dispatched-mass memory, so it
  re-acquires a containing fragment the round already fragmented (b61 on the golden); teaching it to
  skip those masses changes the golden's post-decision MS3s and is likewise its own push.

## Alternatives rejected

- **Extending FLASHTnT** (a detect step inside the extender, an FDR per shift): the module is off-limits,
  and the differences are structural — when a shift is decided, by how many fragments, with what error
  rate — rather than parameters.
- **Replacing FLASHTnT outright**: every committed MS3 golden and the production template depend on it,
  and the new method has run on one protein's data; a switch keeps both testable.
- **Deciding after each MS3** instead of after the round: a single confirmed target would flip the
  model repeatedly inside one round; the round is the unit the budget was authored in.
- **Counting bare pieces for the path that predicts them bare**: it is the inference heme loss defeats.
- **A standalone tool or a dump mode for the corpus validation**: the repo's tests read committed
  fixtures, and nothing else; the offline replay tool the paper needs is its own decision.
- **Keeping α 0.5 with a cap on the levels alone** (2026-10-12): the cap bounds the matrices but does
  not touch the two scans that fail (10 and 24 levels after the exclusions), because the chance jumps
  are built from 6-ion levels that cut 6 admits.
- **Restoring the report's Version 75 fold** (water, ammonia, neutron and the nineteen residue
  offsets): it removes residue shadows the DP never used and gains no corpus row over the neutron rule.
- **A second Expected pass** (masses explained at the accepted levels leave the decoy pool): on every
  corpus scan it drives the FDR to near zero and the cut to the floor (tia: 33 levels → 716).
- **Pinning the six disulfide rows as the prototype computes them**: parity with a wrong answer.

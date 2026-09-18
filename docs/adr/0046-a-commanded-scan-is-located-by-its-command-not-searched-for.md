# 0046. A commanded scan is located by its command, not searched for

Status: Accepted (2026-09-18), implemented the same day. CI builds it and tests the join; the
**locate** step inside FLASHDeconv is executed by no CI job and is verified by the acceptance run
described under *Consequences*.

Amends ADR-0035 (decisions 7 and 8, and its "third identity channel" consequence).

## Context

FLASHDeconv assigns an MS2 its precursor in two steps
(`FLASHDeconvAlgorithm::findPrecursorPeakGroupsForMSnSpectra_`). It searches its own deconvolution
of the **latest preceding MS1** for the highest charge-SNR mass with a peak inside the isolation
window; only if that finds nothing does it consult FLASHIda's `ida.log`, accepting a logged target
when **both window bounds match the mzML within 0.001 m/z**, no further than 50 scans back
(`findPrecursorPeakGroupsFormIdaLog_`).

The second step fails for a mechanical reason. The instrument sets an isolation width on a 0.1 m/z
grid, rounding down, while FLASHIda logs the width it commanded: acquired − commanded was within
[−0.1, 0] on all 13,873 MS2 of the reference run and narrower on 13,738 of them. The ±0.001 test
passed for **741 of 13,873 (5.3 %)**. The owner's analysis of the 2026-09-16 corpus puts the cost at
32–33 % of fragment-bearing MS2 (118 ms arm) and 37–40 % (500 ms arm) reaching the msalign with no
precursor, an estimated 47–108 and 87–240 proteoforms per run.

The obvious repair — widen the tolerance to ~0.06 and quantize the commanded width — treats the
second step. Measuring the first step showed it is the larger defect, and that neither step needs to
be a heuristic at all.

Reference run for every number here: `20260916/FLASHIda_methodLCMS_20260912_EcoliLysateRedAlk_60min_1ul__R1`
(118 ms arm, msconvert / pwiz 3.0.26151), joined to its own `scan_commands.tsv`.

**The tracking id survives conversion.** msconvert writes the Thermo scan-description trailer as
`<userParam name="scan description" value="!!BR5.30533k@10"/>`, which OpenMS loads as the spectrum
meta value `"scan description"`. All 4,675 MS1 and all 13,873 MS2 carry one, and every MS2's
description equals exactly one `scan_commands.tsv` row (0 duplicates, 0 orphans, 0 rows never
acquired). ADR-0035 and `CONTEXT.md` both said the instrument scan number was the only identity to
survive conversion. That was wrong, and the belief is what kept this join heuristic.

**FLASHDeconv reads the wrong survey.** Commands queue, so the survey a command was decided from is
rarely the survey acquired just before its scan:

| Newer MS1 surveys between a command's parent survey and its MS2 | Share of MS2 |
|---|---|
| 0 | 12.1 % |
| 1 | 37.5 % |
| 2 | 26.5 % |
| 3 | 16.8 % |
| 4 or more | 7.0 % |

Of the 5,675 MS2 that reached the msalign, the assigned precursor agreed with the commanded mass
(same mass, or 1–3 isotopes off) for **977 of the 1,030 (94.9 %)** whose parent survey was also the
latest one, and for **40–46 %** of those with one to four newer surveys in between — an upper bound
on the search's own agreement there, since that group includes the few precursors that did arrive
through `ida.log` and agree by construction. Overall 2,689 of the 5,675 (47.4 %) carried a mass the
engine had not isolated for — 464 of them harmonics of it, 2,225 another species. The pick *rule*
is sound; the *survey* is wrong.

**Given the right survey and the right mass, FLASHDeconv already has the PeakGroup.** Following each
MS2's row to its true parent survey (`parent_tracking_id` → that MS1's own scan description) and
looking for the commanded mass in FLASHDeconv's own deconvolution of it:

| In FLASHDeconv's deconvolution of the true parent survey | MS2 |
|---|---|
| exactly one same-isotope mass within 0.06 Da + 10 ppm | 13,838 (99.75 %) |
| two such masses | 3 |
| none, but one 1–2 isotopes away | 9 |
| none at all | 23 (0.17 %) |

The two deconvolutions are the same algorithm on the same spectrum: their masses for one species
differ by a median of 0.003 ppm (99th percentile 0.017 ppm).

## Decision

1. **An mzML spectrum is joined to its `scan_commands.tsv` row by tracking id** — the first three
   characters of the `scan description` meta value. Not by the full description string, and never
   by isolation-window bounds.
2. **The commanded precursor is authoritative, and it is a locator rather than a measurement.** For
   a joined MS2 the row decides *which survey* and *which mass*; FLASHDeconv then takes **its own
   PeakGroup** for that mass from that survey — nearest same-isotope mass within 0.06 Da + 10 ppm.
   The reported mass, charge range, feature linkage and Qscore2D are therefore FLASHDeconv's, not
   the log's.
   The survey is found by **walking `parent_tracking_id` up the rows until an `ms_level == 1` row**,
   then asking which spectrum carries that id. One hop is not enough: a follow-up MS2 — the
   conditional `'C'`, or the `'R'` a quantification verdict buys — names the MS2 that *triggered* it
   as its parent (`ScanCommandQueue::buildFollowUp`), not the survey.
3. **When its deconvolution lacks that mass** (0.2 %), FLASHDeconv accepts its own PeakGroup one or
   two isotopes away, and otherwise rebuilds a single-peak PeakGroup from the row, as the `ida.log`
   path did.
4. **A spectrum with no tracking id, or an id with no row, is an uncommanded scan**, not an error.
   It keeps the existing search of the latest preceding survey, unchanged. So does a commanded scan
   whose **survey is not in the data file** — an `-min_rt`/`-max_rt` crop removes it legitimately —
   and a root MS2 that names no parent.
5. **The whole join is validated before any deconvolution, and fails closed.** Every joined scan
   must agree with its row on MS level, and — at MS2 — the row's anchor `precursor_mz` must lie
   within 0.01 m/z of one of the spectrum's isolation targets. A duplicate `tracking_id` in the file
   is an error, and so is one commanded id on two spectra. **A file that joins nothing aborts too**:
   it is the extreme foreign file, and also what a converter that drops the scan description
   produces — `-FD:scan_commands` was given, so an uncoupled run is never silent. Any violation
   aborts, naming the first offenders.
6. **`-FD:ida_log` is removed** from FLASHDeconv, together with `findPrecursorPeakGroupsFormIdaLog_`
   and the wizard's `IDALog_<base>.log` checkbox. The parameter is `-FD:scan_commands <path>`; a
   path that does not resolve to a file is an error, never a silent uncoupled run.
7. **The wizard finds the run folder FLASHIda wrote**: beside the mzML,
   `<base>_<yyyy-MM-dd-HH-mm-ss>[_n]/scan_commands.tsv` (`LogPathResolver.Compose`'s shape), the
   stamp matched strictly, exactly one match required — checked for **every** input before anything
   runs. It writes the path to **`FD:scan_commands`**, under the subsection where FLASHDeconv
   registers it.
8. **MS2 only.** MS3 rows are parsed and level-checked; MS3 spectra keep the existing search.
9. **The reader accepts every `scan_commands.tsv` already acquired.** Columns resolve by header
   name and no new column is required.
10. **The writer changes in one respect: `mono_mass` is printed at four decimals.** It was printed
    at the stream default — six *significant* digits, `12351.4` for 12351.3933 — which is the same
    defect ADR-0035 decision 5 fixed in `ida.log`. Stage-less rows keep their `0`. No column is
    added; the header stays at 34.
11. **Parsing and joining are pure functions on the FLASHIda side**, beside the writer, and are
    tested there. `FLASHDeconvAlgorithm` keeps only the last step, which needs its own objects:
    look the PeakGroup up in the survey the join names.
12. **`IdaLogger::parseFLASHIdaLog` stays where it is.** `ida.log` is still written and still has an
    in-scope reader (`PrecursorSelection`'s `targeting.target_log_files` loader); the parser's four
    test sections keep asserting the writer's grammar through it.

## Considered alternatives

**Widen the ±0.001 tolerance to ~0.06 and quantize the commanded width to the 0.1 grid.** The
repair this work started from. Rejected as the primary fix: it mends the fallback and leaves the
first step reading the wrong survey, which is where 2,689 wrong assignments come from. A 0.06
tolerance also stops separating two commands on overlapping windows within the 50-scan walk. The
quantization half is an engine-behaviour change with its own large golden footprint and is **not
part of this decision** — it is recorded as a candidate follow-up, no longer motivated by this
consumer. The margin the engine adds around a measured envelope is 0.4 m/z per side
(`NotchSelection.h`), so the instrument's rounding costs at most 0.05 per side and never clips the
envelope.

**Join on the full scan-description string.** It carries the mass token and the charge, so it would
also have refused a foreign file for free. Not chosen: the tracking id *is* the identity — the one
key the engine itself decodes — and the remainder of the description is payload whose format may
change. Decision 5 supplies the guard the full string would have.

**Keep the precursor from the log as a fallback only** (the role `ida.log` had). Rejected: it
recovers the precursor-less MS2 and leaves the 47 % wrong-survey assignments standing.

**Make the log the mass source** — always rebuild the PeakGroup from the row. Rejected: every
precursor becomes a synthetic one-scan feature, Qscore2D never applies, and the reported mass is
whatever the log printed, when FLASHDeconv holds the full PeakGroup for 99.8 % of them.

**Add `min_charge` / `max_charge` columns to `scan_commands.tsv`**, as ADR-0035 decision 6 did for
`ida.log`'s `ChargeRange`. Rejected after tracing the consumer: the range of a *rebuilt* precursor
reaches exactly one place, `Min_charge`/`Max_charge` of the synthetic row FLASHDeconv mints in
**`_ms1.feature`** (`FLASHDeconvFeatureFile.cpp`, the `ms_level == 1` branch) — a file a single-run
TopPIC search never opens: per the 2026-08-25 feature-file diagnosis it is read only in TopPIC's
multi-fraction merge path. That is ~23 scans a run, in an unread column. If a multi-fraction merge ever matters, the columns can be added then,
with a consumer to validate against.

**Degrade instead of aborting on a join inconsistency.** Rejected. Tracking ids are minted from the
same start every run, so a foreign `scan_commands.tsv` joins **100 %** of scans: pairing the
reference mzML with replicate R2's file joined 13,873 of 13,873, of which 4,905 disagreed on MS level
and 8,956 on m/z, with 12 agreeing by chance. Under an authoritative locator that poisons every
precursor in the run; a warning line is not a proportionate signal.

**Keep `-FD:ida_log` alongside the new parameter.** Not kept — the owner's call. Every run the
engine has logged also has a `scan_commands.tsv`, so the old path would serve only logs from the
2023 C# writer, and ADR-0035 already established that none of those is archived anywhere.

**Serve MS3 now.** The locator carries over unchanged one level down — the commanded precursor of an
MS3 is its last `;` group and its survey is the parent MS2. Deferred, not rejected: no acquired run
on the development machine contains an MS3 command or a multiplexed MS2, so there is no mzML showing
how pwiz writes a two-stage or MSX precursor list, and decision 5's m/z check would ship blind.

## Consequences

**ADR-0035 is amended in three places.** Its decision 7 (the instrument scan number on every
`scan_results.tsv` row) was never implemented — that file has no such column — and is no longer
needed: a converted spectrum reaches its command by tracking id, at every MS level. Its decision 8
("`FLASHDeconvAlgorithm` … and the GUI are untouched") is reversed. Its consequence that the
instrument scan number is "the **only** one that survives into the converted data file" is
corrected: the tracking id survives too, and the two join different things — acquisition order
versus the command. ADR-0035's decisions 1–6 stand; `ida.log` keeps its grammar and its
`MS1 Scan#`, for the readers it still has.

**`ida.log` no longer has a consumer outside FLASHIda.** It remains the decision record and the
`target_log_files` round trip. The comments and CLAUDE.md passages that called it "the FLASHDeconv
coupling file" were corrected with this change, and so was the `_ms2.feature` claim beside them,
which had been wrong all along — a rebuilt precursor's charge range reaches `_ms1.feature`, not
`_ms2.feature`.

**The wizard's FLASHIda checkbox had been inert.** It put `ida_log` beside the per-file output
parameters, which the wizard inserts at the tool's top level — but FLASHDeconv registers the key
only under its `FD:` subsection, and TOPPBase answers an unknown INI key with a warning. Read off the
code rather than observed in a running wizard; the command line (`-FD:ida_log`) was unaffected,
which is how the coupling was ever exercised. Decision 7's "writes to `FD:scan_commands`" is the
repair.

**The coupling depends on the converter.** Verified for msconvert (pwiz 3.0.26151) only. A converter
that drops the scan-description trailer yields spectra with no tracking id, so the file joins
nothing — which by decision 5 **aborts**, with a message naming exactly that cause beside the
foreign-file one. A run can never silently fall back to the old search because of its converter.

**A tracking id identifies a scan only within its own run.** The counter wraps at 94³ − 1 = 830,583
(the reference run used 22,153). Decision 5's duplicate check is what turns a wrap, or two runs'
files concatenated, into an error instead of a last-row-wins join.

**The edit lands inside the FLASHDeconv no-go boundary**, by the owner's decision, as ADR-0034's
did. The boundary has not moved; decision 11 is what keeps the edit there small, and the exact
lines are fixed in the implementation plan before any is written.

**No golden moves, and none can see decision 10.** `mono_mass` changes rendering on every MS2/MS3
row — 4,802 tokens across the 28 `scan_commands` goldens — but `GoldenNumericComparer` compares
floats at `max(1e-5, 1e-3·max)`, so `12351.4` against `12351.3933` passes with ~1800× headroom.
The goldens were therefore **left as they are**, on the owner's decision and by this repo's own
rule: promote only what fails the comparer, never recapture what no test can observe. The gate on
decision 10 is a C++ test instead,
`FLASHIda_Logging_test::scan_commands_mono_mass_is_written_at_four_decimals`, which compares each
written cell byte for byte with the dequeued command's own `double`. The three integer-shaped
`3954` cells pass only through the comparer's `floaty` **OR**; narrowing that to the golden token
alone would fail them closed.

**What CI still cannot prove.** CI builds `FLASHDeconv` and `FLASHDeconvWizard` and never runs
either. Parsing, joining and validation are covered by FLASHIda-side tests; the locate step is
covered only by the acceptance run — one run per arm re-deconvolved with the CI bundle, its
per-MS2 precursors checked against the predictions above (13,838 + 3 located, 9 by isotope, 23
rebuilt for the reference run), and TopPIC proteoform-level rows compared before and after at
identical settings. Report the locate step as verified by that run, not by a green badge.

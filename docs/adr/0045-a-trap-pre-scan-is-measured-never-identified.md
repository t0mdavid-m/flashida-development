# 0045. A trap pre-scan is measured, never identified

Status: Accepted (2026-09-18), implemented 2026-09-22 (OpenMS `5f80fd8`, FlashIDA `deedbee`; the `exploration_iontrap` golden is captured from CI's `log-golden-capture` artifact and promoted in a follow-up push).
Amends: [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md) — specifically its
clause that MS2 sweep variants *"are already identified under every metric"*. That remains true of
every Orbitrap variant; it is no longer true of a variant read out by the ion trap. 0020's
reading/measuring split is a property of the **metric**; the rule here is a property of the
**analyzer**, and holds under every metric.
Related: [ADR-0044](0044-a-pre-scan-reads-out-its-levels-scan-range.md) — the change that makes
this one necessary, and the same push. [ADR-0042](0042-a-monitor-scan-observes-the-source-and-decides-nothing.md)
— a decision reads the engine's own record of a scan, never the instrument's echo.
[ADR-0007](0007-strict-config-schema-rejection.md) — a config that cannot work is refused at load.
[ADR-0023](0023-exhaustive-characterization-targets-unassigned-masses.md).

## Context

A sweep is put on the ion trap to make it cheap: `"overrides": {"analyzer": "IonTrap", …}`. Under
ADR-0026 such a pre-scan came back as a ~2 Th window and nothing else. ADR-0044 withdraws that, so a
trap pre-scan is now a real, full-range spectrum — and "nothing reads the rest of the spectrum" turns
out to be true of the *score* and false of the *engine*. At MS2, every non-baseline variant, under
every metric, with or without overrides, is:

| Step | Where | What it does |
|---|---|---|
| deconvolved | `Exploration::feedResult` | `deconvolveMSn`, at the exploration ppm tolerance |
| matched | `computeExplorationScore_` | calls the whole-protein matcher `computeFragmentMatch_` in **all four** metric arms, `RemainingPrecursor` included |
| pooled | `feedResultImpl_` | `tracker->feedScan(…)` — into the ProteoformTracker with the same standing as an Orbitrap scan; `finalizeMS2` can then give non-winner variants identification rows |

The narrow range made all three inert **by accident** — a window-only spectrum deconvolves to
nothing. With the full range, unit-resolution trap centroids enter a parts-per-million identification
path for the first time, and no FLASHIda run has ever acquired one (ADR-0044, *Context*).

Three responses were weighed:

1. **Leave the path alone and watch it.** Trap centroids are off by hundreds of ppm, so at 10 ppm
   their charge series should not line up and the spectrum should deconvolve to almost nothing.
   Declined: that is an inference about FLASHDeconv on data it has never seen here, and it fails in
   exactly the case someone will try — widening `exploration.tolerance_ppm` to make the trap "work",
   at which point junk masses are matched and pooled.
2. **Keep every overridden pre-scan out of the tracker.** Principled — the glossary already says an
   overridden pre-scan was not acquired at production settings. Declined: it changes
   Orbitrap-degraded sweeps too, which *are* identifiable, and moves the `exploration_followup` and
   `exploration_ms3_followup` goldens. Far beyond the change that prompted it.
3. **Key the rule on the analyzer.** Taken.

## Decision

**A pre-scan read out by the ion trap is measured, never identified.**

1. **No deconvolution, no matching, no pooling.** A variant whose own command names the ion trap is
   not deconvolved, not run through any matcher, and not fed to the ProteoformTracker — at any level,
   under any metric. The only thing read from it is raw signal: the precursor-window sum behind the
   remaining-precursor ratio.

   The predicate reads the variant's **own `ScanCommand`** — the engine's record of what it asked
   for — never anything on the returning scan. That is ADR-0042's rule: every decision gate reads the
   engine's queued command, which cannot be truncated or lost by the trailer round trip.

2. **Only `remaining_precursor` may score a trap sweep.** An exploration block whose
   `overrides.analyzer` is the ion trap and whose metric is anything else is **rejected at config
   load**, at both levels, with level 3 guarded on `characterization.mode != "off"` as ADR-0026's
   checks are.

   The reason is decision 1's own consequence. `mass_count` scores from `spec.size()` and
   `fragment_count` from `computeFragmentMatch_`, which returns empty on an empty spectrum; the MS3
   batch re-score reads the variants' deconvolved results as well. So under either metric a trap
   sweep scores **0 on every variant**, and because winner selection seeds `best_score = -1.0` and
   takes `score > best_score`, the first grid point wins at zero. The sweep "succeeds": it spends
   N scans per precursor to pick `ce_min` every time, then fires a production follow-up there, with
   no wrong value anywhere to notice. A `[CONFIG-WARN]` was declined — ADR-0020 established that
   stdout markers do not survive a real acquisition, and the sweep would still run. Deconvolving
   after all "when the metric asks for it" was declined as reopening decision 1 for precisely the
   configs that lean on it hardest.

   The ADR-0023 forced sweep is compatible by construction: it forces `RemainingPrecursor`.

3. **`analyzer` becomes a closed set.** `"Orbitrap"`, `"IonTrap"`, or empty (= the instrument method
   default), validated at load for every scan object **and** for `overrides.analyzer`; an unknown
   value throws, as `metric`, `mode` and `targeting` already do. There is **one** predicate for "is
   the trap", in one place.

   Until now `analyzer` was a free-form string validated on neither side, copied into the command and
   passed to the instrument verbatim. With decisions 1 and 2 the engine branches on it twice, so
   `"Iontrap"` would load, miss the skip, miss the rejection, and reach the instrument as a name it
   does not know — refused, or silently run in the Orbitrap at trap settings. An exact-match
   predicate without validation leaves that hole; a lenient match hides the typo from the engine and
   still sends it to the instrument.

   It is a C++-only change. Enum validation in this system lives in `Config.cpp` and surfaces through
   `CreateFLASHIda` at startup; the C# side validates keys, never values. It breaks no fixture: every
   one of the 146 `analyzer` values in the committed configs, the production default and the schema
   reference is exactly `"Orbitrap"`, and the only `"IonTrap"` literals in the tree are the engine's
   own AGC prescan builder and `Flash.cs`'s handshake scan, neither of which is a config value.

4. **It gets the first golden a trap pre-scan has ever had.** A new log-golden mode,
   `exploration_iontrap`: cytochrome c, inclusion-pinned, an MS2 `remaining_precursor` HCD sweep with
   trap overrides, then the Orbitrap follow-up at the winning energy; `characterization.mode: off`
   with a `protein_sequence`, so the follow-up is still identified.

   | Stream | What it pins |
   |---|---|
   | `scan_commands` | `E` rows carry the level's configured `first_mass`/`last_mass` — ADR-0044 — then one `R` follow-up |
   | `scan_results` | `E` rows have a `remaining_ratio` and an empty `mass_count` / `fragment_count` / `deconv_*` block — decision 1; the `R` row has real values |
   | `identification`, `pooled_identification` | rows from the follow-up only; no trap variant among `contributing_scan_ids` |

   **Its fixtures are cut from a real sweep** — the 2026-09-06 direct-infusion cytochrome c run
   (z = 17, m/z 727.9, HCD): a CE-0 baseline plus NCE 20/25/30/35/40, with that run's MS1. The
   existing fixtures cannot carry this mode. Under `remaining_precursor` the single-fixture set gives
   a ratio of exactly 1.0 at every energy (a five-way tie, first variant wins) and the CE-keyed set a
   flat 0.0002 (a winner decided in the seventh decimal) — either golden would stay green under a
   broken metric. The real curve falls through the 0.1 target between NCE 30 (0.283) and 35 (0.056),
   so the winner is a real decision. Below ~NCE 22 that curve swings between 0.8 and 1.7 scan to
   scan, so the fixtures are cut from the smooth region and the baseline scan chosen to be
   representative.

   The analyzer itself is pinned by a **ctest assertion** (`"IonTrap"` on the variants, `"Orbitrap"`
   on the follow-up), because `scan_commands.tsv` has no analyzer column. Adding one was considered
   and declined: it is a mechanical recapture of all 28 modes for something a run folder already
   states, since `method.json` sits beside the logs and every `E` row ran under its overrides.

## Consequences

**A trap sweep is always closed by an Orbitrap follow-up, and that scan carries all of its
evidence.** Trap overrides are non-empty by construction, so ADR-0020's gate #1 fires; the follow-up
returns on the regular path, is identified there, and at MS2 is what cascades to MS3. A trap variant
leaves a `scan_results` row and nothing else.

**No existing golden moves**, so this ships with ADR-0044 as one byte-identical push plus the new
mode's five files. No ABI change, and no schema key is added — `analyzer` values become checked, not
new — so `config_schema_reference.json` does not regenerate.

**`finalizeMS2` sees no model for a trap sweep, and that is fine.** It returns early when the
precursor has none, so a sweep that feeds nothing leaves the tracker untouched until the follow-up
arrives. Recorded because the *previous* arrangement was less clearly safe: under the narrow range
each trap variant was fed as an **empty** result, which walks `finalizeMS2`'s "no scan identified
anything" branch and marks the model finalized. Whether a finalized-empty model then accepts the
follow-up's feed was **never verified**. Decision 1 makes the question moot rather than answering it.

**What the golden cannot tell us.** Its fixtures are Orbitrap spectra, because no real trap series
was available to cut. So whether the precursor-window sum holds on **unit-resolution trap
centroids** — peaks hundreds of ppm off and, at the faster scan rates, wider than the window the
Orbitrap survey measured — stays untested until the instrument. Watch for `remaining_ratio = -1` and
`[EXPL-ABORT] reason=empty-baseline` on trap sweeps: a baseline whose centroid lands outside the
window de-references its activation, and a sweep with one activation then finishes with no winner.

**A known gap, recorded and not closed.** An *unset* analyzer is treated as not-the-trap. A pre-scan
that reaches the trap through the instrument method's default rather than through an authored
`analyzer` is invisible to this rule. Every committed config names its analyzer, and a sweep that
wants the trap has to say so in `overrides` anyway.

**`validate.py` gains two checks** mirroring decisions 2 and 3.

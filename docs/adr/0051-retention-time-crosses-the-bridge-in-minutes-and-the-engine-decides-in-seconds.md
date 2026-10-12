# 0051. Retention time crosses the bridge in minutes and the engine decides in seconds

Status: Accepted (2026-10-11)
Related: [ADR-0035](0035-ida-log-is-compatible-with-its-consumer-not-its-history.md) — the `ida.log`
a run writes is read back by the target-log loader, so its `RT` stays in the unit that loader reads.
[ADR-0042](0042-a-monitor-scan-observes-the-source-and-decides-nothing.md) — acquisition memory, whose
expiry this repairs.

## Context

`precursor_selection.rt_window` is authored in seconds (180 in every quantification method; FlashLog
prints `RTWindow=180s`). The host has always passed the instrument's `StartTime` — minutes — across
`ProcessScan` as `rt_min`, and nothing converted it. Everything behind `FLASHIda::processScan` assumed
seconds: `rt_window`, the doc comments of `filterAndRank`, `Deconvolution` and `InclusionTarget`, and
the inclusion-list and target-log loaders, which multiply their files' minutes by 60. The C++ tests feed
fixture times straight to `processScan` as seconds, so they exercised the intended behaviour and passed;
every C# path — the instrument, the mock, the offline `Flash.exe` — fed minutes. It has been so since
the first engine in this fork (2022).

On the instrument four comparisons were therefore 60× off: acquisition memory never expired (a
species that cleared `tqscore_threshold` barred its nominal mass and its anchor's integer m/z for the
rest of the run, and the qscore ledger never reset); an inclusion row was active only where its window,
read as seconds, contained the run's minutes, so a 10–20 min row never was; `in_depth` and
`exclusion_masses` target logs matched only entries from the first ~4 min of the earlier run; a
tag-based target stayed active for the rest of the run.

Replaying selection from the logs of the three 2026-10-08 iodoTMT runs: a 180-minute window reproduces
the engine (0.0 % mismatch), a 180-second one does not (13 %). Bars older than 180 s refused 19–26 %
of survey appearances at qscore ≥ 0.9, and 8–11 of the Control's 67 differential proteoforms per run
were seen live but never screened.

## Decision

1. **The engine decides in seconds.** `FLASHIda::processScan` and everything behind it take retention
   time in seconds — the unit of `rt_window`, of the loaders, and of OpenMS's own spectra.
2. **The bridge keeps carrying the instrument's minutes, and the C export converts, once:**
   `ProcessScan` passes `rt_min * 60.0`. It is `processScan`'s only production caller. The host is
   unchanged, so no `Flash.exe` / `OpenMS.dll` pairing can disagree about the unit.
3. **The two log streams keep minutes.** `scan_results.tsv` `rt` and `ida.log` `RT` are written as
   `rt / 60`, because `ida.log` is read back by the target-log loader (ADR-0035) and run analyses read
   minutes. Stdout markers print the engine's seconds.
4. **The method and its files do not change.** `rt_window` stays seconds; inclusion rows and target
   logs stay minutes.

## Considered options

- *Minutes inside the engine* — convert `rt_window` where it is parsed and stop the loaders
  multiplying by 60. More edits in selection, the C++ fixture loader would have to divide by 60, and
  OpenMS spectra would carry minutes against OpenMS's convention.
- *Seconds, converted on the host* — `StartTime × 60` in `ScanData.From`. The bridge argument would
  change meaning without changing type, so a mismatched `Flash.exe` / `OpenMS.dll` pair would go wrong
  silently.

## Consequences

- The same method acquires differently: a species is selectable again once its bar is older than
  `rt_window`. "Never again" now has to be written as a window longer than the run. The shipped
  `etc/method.json` (`rt_window` 120, `tqscore_threshold` 0.1) is the most affected.
- Inclusion rows with finite windows, target logs and tag targets act at the times their files name.
- No golden moves: every golden's surveys span at most 64 s, inside a 180 s window — which is also why
  no golden ever saw expiry. Three C# tests on the host path and two C++ sections — one of them on the
  export itself — pin it now.
- Not decided here: the integer-m/z bar and its collateral refusals, and `tqscore_threshold` as the
  switch that arms bars.

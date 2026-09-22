# 0044. A pre-scan reads out its level's scan range

Status: Accepted (2026-09-18), implemented 2026-09-22 (OpenMS `5f80fd8`, FlashIDA `deedbee`; the `exploration_iontrap` golden is captured from CI's `log-golden-capture` artifact and promoted in a follow-up push).
Amends: [ADR-0026](0026-a-remaining-precursor-sweep-scans-only-the-window-it-reads.md) — withdraws
its decisions **1** (the binding) and **3** (overrides are mandatory), re-grounds decision **4**
(level-matched multiplexing is rejected) on the one reason that survives, and dissolves decision
**5** (an explicit range wins) into ordinary override semantics. Decisions **2** (one window, one
margin) and **6** (the range is a `scan_commands.tsv` column) stand unchanged.
Restores: [ADR-0020](0020-a-measuring-ms3-sweep-must-be-closed-by-a-follow-up.md)'s gate #2 to its
original scope — 0026 had made its `remaining_precursor` half unreachable by config.
Related: [ADR-0009](0009-scan-config-fully-determines-instrument-parameters.md),
[ADR-0023](0023-exhaustive-characterization-targets-unassigned-masses.md),
[ADR-0045](0045-a-trap-pre-scan-is-measured-never-identified.md) — which must ship in the same push,
because this ADR is what turns a trap pre-scan into a real spectrum.

## Context

ADR-0026 bound the `first_mass`/`last_mass` of every `remaining_precursor` pre-scan to the isolation
window the metric reads, on one premise: *"On an ion trap, where scan time is proportional to the
m/z range swept, a 200-2000 pre-scan costs ~900x the scan time of the window it actually reads."*

**The premise did not survive the instrument.** Narrow-range ion-trap scans were measured outside
FLASHIda and gave no worthwhile gain (reported 2026-09-18). No figures were kept, so this is recorded
as a qualitative finding. It is worth being plain about what that leaves unmeasured: **no FLASHIda
run has ever acquired an ion-trap pre-scan.** Of the 58 run folders on the analysis machine, 34 ran a
live sweep; 33 of them swept in the Orbitrap, and the one that named the trap (2026-09-03, lysozyme)
logged zero commands.

The arithmetic explains the finding without needing the numbers. "~900x" was a ratio of two **range
widths** (1800 Th against ~2 Th) and was never a ratio of scan times. Only the *readout* part of a
trap scan scales with the range. At the linear trap's nominal scan rates — figures from memory of the
vendor's published rates, **not verified here** — an 1800 Th readout takes roughly:

| Scan rate | nominal rate | 1800 Th readout |
|---|---|---|
| Normal | ~33 000 Th/s | ~54 ms |
| Rapid | ~66 000 Th/s | ~27 ms |
| Turbo | ~125 000 Th/s | ~14 ms |

Injection, isolation, activation and the fixed per-scan overhead do not shrink with the range. The
ceiling on what narrowing could ever save is therefore the readout itself — tens of milliseconds, on
a scan whose injection time alone is authored at 10-50 ms. ADR-0026 also leaned on ADR-0020's
"66 MS3 pre-scans … ~2.2 s each" as the shape of the cost; neither ADR records which analyzer those
scans ran on or what bounded their duration, so that figure was never evidence that readout
dominated.

Meanwhile the binding was not free. It discarded the rest of every pre-scan's spectrum, it needed two
config-load rejections as interlocks, it needed a special-case suppression test because
`base_config.first_mass != 0` cannot tell an override from an authored scan range, and it made the
range of a pre-scan depend on its *metric* — acquisition geometry sourced from a scoring choice.

## Decision

**A pre-scan has no scan range of its own. It reads out its level's configured range, like any other
scan parameter, unless its exploration overrides name another.**

1. **The binding is withdrawn.** A pre-scan is built from `scans[0]` patched by `overrides` and
   nothing else. This holds for every metric, at MS2 and MS3, for the baseline variant, and for the
   ADR-0023 forced sweep over an unassigned mass — the one path that had no config entry and was
   narrowed anyway.

   "Full range" therefore means *the level's configured range* — `ms_settings.msN.first_mass` /
   `last_mass` — not the analyzer's limit and not unset. If a trap pre-scan should read a different
   range than the Orbitrap production scan it informs, that range is authored in `overrides`.
   An engine-computed, analyzer-aware range (first mass from the precursor's low-mass cutoff, last
   mass capped at the trap's limit) was considered and declined: it would have been new machinery,
   and leaving both bounds unset was declined because the config would then no longer determine what
   was acquired (ADR-0009) and `scan_commands.tsv` would log `0`/`0`.

2. **`first_mass`/`last_mass` in `overrides` are ordinary overrides.** ADR-0026 decision 5 made them
   an escape hatch that *suppressed* the binding; with no binding there is nothing to suppress, and
   they patch the pre-scan like any other key. A **static** narrow range stays expressible this way.
   What is gone is the *dynamic*, per-target one — which is the thing shown not to pay.

3. **Overrides are optional again under every metric.** ADR-0026 decision 3 rejected
   `remaining_precursor` with an empty `overrides` map. That rule was the interlock for the
   narrowing — *"narrowing a pre-scan is safe exactly when a production re-acquisition follows it"* —
   and with no narrowing there is nothing left for it to protect. An empty-overrides
   `remaining_precursor` sweep now behaves exactly as an empty-overrides `mass_count` sweep already
   does, and that one has always been legal:

   | Level | With empty overrides | Why that is sound |
   |---|---|---|
   | MS2 | pre-scans run at production settings; the winner's spectrum cascades to MS3 | every MS2 variant is identified under every metric (but see ADR-0045 for the trap) |
   | MS3 | ADR-0020 gate #2 re-acquires a production scan | it fires for any measuring metric |

   ADR-0020's gate #2 regains its `remaining_precursor` half. Keeping the rejection "on principle"
   was considered and declined: its stated principle — a metric that never reads its pre-scans must
   declare what they run at — is false at MS2, and at MS3 the guarantee already comes from the
   metric and the level rather than from the author's patch.

4. **Level-matched multiplexing stays rejected, on the ground that survives.** ADR-0026 decision 4
   gave two reasons. The first — a notch set is not one `[first_mass, last_mass]` interval — dies with
   the binding. The second stands by itself: **the remaining-precursor ratio is a single-window
   measurement.** `precursorWindowIntensity_` sums the anchor's window and nothing else, so under
   co-isolation it reports one charge state's depletion while one collision energy depletes its
   siblings at different rates. A target met by the anchor says little about the rest.

   The engine already *records* exactly that anchor-only number, as `remaining_ratio`, for every
   variant of the `exploration_multiplexed` golden mode. The rejection stops it being *decided* on.
   Both messages are rewritten to say so; the current text ("cannot be expressed as the one scan
   range such a sweep's pre-scans are bound to") becomes false. `separate`, and the cross-level
   combination, stay legal exactly as before.

   Two ways to lift this later, neither taken now: decide on the anchor's depletion alone (the
   pre-0026 behaviour — simple, and a silently biased proxy), or sum the measurement over every notch
   window (species-level depletion, which is what a multiplexed scan actually wants — a new
   measurement, not part of a reversal).

5. **Decisions 2 and 6 of ADR-0026 stand.** The margin correction still makes the interval the
   metric sums equal the interval the instrument was commanded to isolate. The `first_mass` /
   `last_mass` columns become *more* useful, not less: they are now where a run folder shows that a
   pre-scan read out the configured range.

## Consequences

**No golden moves.** Verified against the committed log goldens: 1 488 `exploration` rows across six
modes, none carrying a narrowed range. No golden mode uses `remaining_precursor`, and
`ms3_exhaustive_cytc` runs no sweep, so the forced path is not in a golden either. No golden ever
validated the narrowing — what ADR-0026 recaptured was the margin (4 `scan_results`) and the new
columns (22 `scan_commands`); the binding itself was pinned only by ctest sections.

**No ABI or schema change.** `first_mass`/`last_mass` are untouched on both sides of the 2048-byte
`ScanCommand`, no config key is added or removed, and `config_schema_reference.json` does not
regenerate.

**The ctest sections that pinned the binding are retired or inverted** — the two
`remaining_precursor_binds_scan_range_*` sections, `forced_remaining_precursor_binds_scan_range`,
`explicit_range_override_suppresses_binding`, `single_isotope_charge_yields_non_degenerate_scan_range`,
`remaining_precursor_without_overrides_throws`, and the `remaining_precursor` half of
`ms3_measuring_metric_always_reacquires_without_overrides`. Their individual fates belong to the
implementation plan, not to this file. One thing worth carrying over rather than deleting: the
single-isotope case now needs no floor at all, because with no binding nothing can emit
`first_mass == last_mass`.

**An inert override goes away.** `method_exploration_ms3_remaining.json` carries
`"overrides": {"analyzer": "Orbitrap"}` on a level whose analyzer is already Orbitrap — a patch that
exists only to get past decision 3's throw. It is dropped. Recorded while here: **no test loads that
file**, and nothing enumerates the configs directory, so ADR-0020's claim that it "pins the
combination" has nothing behind it.

**`validate.py` follows.** The `validate-flashida-config` skill mirrors both rejections: check A17
(decision 3) is deleted, A18 (decision 4) is reworded.

**Open on the hardware, and not answerable from the code.** Trap CID has a low-mass cutoff of
roughly a quarter to a third of the precursor m/z, so an inherited `first_mass` of 200 on a precursor
at m/z 1031 asks for ions the trap cannot hold. Whether the instrument **clamps** that or **refuses**
the scan is unknown. If it clamps, decision 1 is right as it stands. If it refuses, decision 1 is
still right but authoring the trap range in `overrides` becomes required practice — and a refused
variant stalls its group until `scheduling.scan_timeout` clears it.

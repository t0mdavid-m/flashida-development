---
title: The two-axis iAPI scan-parameter grammar (';' stages, ',' notches)
applies_to: FlashIDA/src/Flash/ScanFactory.cs, OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp, OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h
last_verified: 2026-08-09
code_anchors:
  - FlashIDA/src/Flash/ScanFactory.cs:30    # MSXTargets — declared, never assigned
  - FlashIDA/src/Flash/ScanFactory.cs:32    # PrecursorMass field (double[])
  - FlashIDA/src/Flash/ScanFactory.cs:133   # FillParameters — reflection, arrays joined with ';'
  - FlashIDA/src/Flash/ScanFactory.cs:196   # per-stage block guard
  - FlashIDA/src/Flash/ScanFactory.cs:198   # int n = Math.Min(cmd.NumStages, 10)
  - OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:44   # MAX_ISOLATION_STAGES = 10
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp:256   # per-stage ';' join loop
  - OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/IdaLogger.cpp:279   # num_stages == 0 placeholder branch
---

# The two-axis iAPI scan-parameter grammar

A tribrid custom-scan parameter that takes a list carries **two orthogonal axes in one string**:

| Delimiter | Meaning | Effect |
|---|---|---|
| `;` | **descends** an MSⁿ stage | element *i* is cascade stage *i* — the MS1→MS2 transition, then MS2→MS3, … |
| `,` | **widens** a stage | parallel co-isolation windows (notches) fired into the same fragmentation event |

They compose. `PrecursorMass = "524.3;104,271,453"` is an MS3 that isolates 524.3, fragments it, then
isolates **three simultaneous windows** at 104, 271 and 453 — canonical synchronous precursor
selection. `ScanType` stays `"MSn"`; there is no mode flag. The delimiter is the only discriminator.

## Why `PossibleParameters` does not document the `,` axis

A live `IScans.PossibleParameters` dump describes `PrecursorMass` as *"The precursor m/z to isolate at
a given MS stage. The first value will be the MS1->MS2 transition, and so on. It is expressed as a
string of values, with each value separated by a ';' delimiter. A maximum of 10 values can be
defined."* — the cascade axis only, which makes MSX windows look as though their m/z comes from
nowhere.

That second sentence is a **shared constant appended to every list-valued parameter's help text**
(`thermofisherlsms/iapi`, `helios_IScans.cs:294`), glued onto `CollisionEnergy`, `FirstMass`,
`LastMass`, `SrcRFLens` and `IsolationWidth` alike. The `,` axis is undocumented boilerplate
collateral, not a missing capability. Do not conclude from a dump that notches are unsupported.

## Which axis each parameter takes

Established from Thermo's own tribrid examples (`examples/tribrid/FusionExampleClient2pt0/Form1.cs`
lines 383–473, and the incremental builder at `helios_ScanInjector.cs:488-527`).

| Axis | Parameters |
|---|---|
| `,` per notch **within** a stage | `PrecursorMass`, `IsolationWidth`, `ChargeStates`, `MSXTargets` |
| `;` per cascade stage only | `ActivationType`, `CollisionEnergy`, `ReactionTime`, `ReagentMaxIT`, `ReagentAGCTarget`, `ActivationQ` |
| scalar, **broadcasts** to all notches | any of the above given once — `IsolationWidth = "25"` against three windows |
| per scan, no list at all | `AGCTarget`, `MaxIT`, `Microscans`, `OrbitrapResolution`, `Analyzer`, `IsolationMode`, `MassRange` |

`helios_ScanInjector.cs` builds the string incrementally, which is what makes the grammar
unambiguous rather than inferred: `PrecursorMass += ("," + next)` for another notch (`:499`),
`PrecursorMass += ";" + sps` for the next stage (`:519`).

## `MSXTargets` is a per-window AGC vector, and it is optional

It is **not** a notch count. The dump reads *"AGC target values for MSX windows, in m/z order"*,
range `(0; 3.402823E+38)`, default `3000`.

Three facts constrain how to treat it:

- **Optional.** Thermo's SPS-MS3 example (`Form1.cs:463`) carries three comma-separated windows and
  never sets `MSXTargets`. So it is not the signal that enables multiplexing.
- **Set for sequential fills, omitted for simultaneous ones.** It is set for multiplexed SIM
  (`:420`) and multiplexed MS2 (`:446`, with `AGCTarget` commented out), and absent from SPS-MS3.
  That matches the physics: MSX performs N sequential quadrupole isolations accumulated in the ion
  routing multipole, each needing its own target; SPS is one simultaneous waveform.
- **Flat comma vector with no `;` axis anywhere.** No code in Thermo's repo gives it a stage
  delimiter, so its binding when two stages are both multiplexed is undetermined.

In FLASHIda it is **declared and never assigned** (`ScanFactory.cs:30`). It was added by
`d16fa4a` (2024-04-27) set to `MS2.AGCTarget` as an AGC workaround, and orphaned by `7cfc8f7`
(Phase 5) when the two processors holding the call sites were removed. `FillParameters` skips nulls,
so it costs nothing at runtime — but grepping for it gives the false impression MSX is wired up.

## Gotchas

- **`-1` is a legal isolation width.** `IsolationWidth = "3;-1,-1,-1"` (`Form1.cs:463`) uses `-1` as
  a per-window "auto" sentinel, even though the dump documents the range as `(0.4; 2000)`.
  `ScanFactory.cs` **throws** on `isolation_width <= 0`, so FLASHIda currently refuses a value
  Thermo's own example sends.
- **`MaxIT` cannot be split per notch on a tribrid.** It is a scalar, so N notches share one
  injection-time budget with equal time each — MS2 co-isolation buys fragmentation diversity, not
  signal. `MSXTargets` is the only per-window budget knob.
- **The 10-value cap is on the whole string.** `num_stages + total_notches <= 10`, which is why
  `MAX_ISOLATION_STAGES` (10) and the wire limit coincide exactly.
- **`,` is inside the base-94 tracking-id alphabet.** Encoded ids may contain both `;` and `,`, which
  is why `child_ids` and `contributing_scan_ids` join with a *space* — the only printable character
  the alphabet excludes. Numeric log columns may use `,` freely; id columns may not.

## Primary sources

- `github.com/thermofisherlsms/iapi` — `examples/tribrid/FusionExampleClient2pt0/Form1.cs` (the four
  worked cases: single SIM, MSX SIM, MSX MS2, SPS-MS3), `helios_ScanInjector.cs`, `helios_IScans.cs`
- Canterbury, Barshop, McAlister & Eliuk, *"Expanded Instrument Control Using the Orbitrap Tribrid
  IAPI"*, Thermo poster PO66127 EN0921S (2021) — states the `;` cascade meaning in prose
- A live `IScans.PossibleParameters` dump from an Orbitrap tribrid (2026-08-09). No such dump exists
  publicly; `Flash.cs:248` already walks that array for FAIMS detection and discards the rest, so
  capturing one is a few lines' change.

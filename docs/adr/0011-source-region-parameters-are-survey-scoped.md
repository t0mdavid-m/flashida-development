# 0011. Source-region parameters are survey-scoped

Status: Accepted (2026-08-07). Amends [ADR-0007](0007-strict-config-schema-rejection.md) (reverses
one of its Consequences) and scopes [ADR-0009](0009-scan-config-fully-determines-instrument-parameters.md)
(whose no-inheritance rule was written for a different class of parameter, and whose claim about
these keys was true of C++ and false end-to-end).

## Context

`source_cid` and `source_cid_scaling` were not reaching MSn scans. Two independent defects, in two
different files:

**1. The keys were unexpressible for MSn.** `rf_lens`, `source_cid` and `source_cid_scaling`
existed only on `MS1Parameters`; `scan_rate` existed nowhere in C# at any level.
`MethodConfigSerializer` validates scan objects against struct **fields**, so writing
`"source_cid": 15` under `ms_settings.ms2[0]` was a hard load error. C++ then read
`j.value("source_cid", 0.0)` → `0.0`, `ScanCommandQueue` faithfully copied `0.0`, and
`ScanFactory`'s `if (cmd.SourceCid > 0)` dropped it. Every MSn scan silently ran at the instrument
method's source settings.

The C++ side was never the constraint: `kScanKeys` admits all 17 keys, `parseScanConfig` reads
every one of them at all five scan sites, and all four `ScanCommand` builders copy them. Only the
C# emit hop was missing — and it was missing **deliberately**. Commit `45c2cf9` trimmed exactly
these four keys from `JsonMs2Config` as *"always-default emit-only keys … so emit == struct field
set"*, recorded as a Consequence of ADR-0007. Three of the four were live.

**2. `source_cid_scaling` was dead at every level, MS1 included.** Its documented correct value is
`0` (`MethodParameters.cs`, `etc/method.json`), and `ScanFactory`'s `> 0` guard discards `0`. So
`SourceCIDScalingFactor` had never been sent on any scan in this build, and the instrument applied
whatever scaling its own method carried. Fixing the schema alone does not fix this: the value
arrives correctly as `0` and is still dropped.

## Decision

**Distinguish two classes of instrument scan parameter.**

| Class | Keys | What it governs | Rule |
|---|---|---|---|
| **Source-region** | `rf_lens`, `source_cid`, `source_cid_scaling` | The ion source and transfer optics, upstream of the analyzer: *which ions arrive* | Shared by every scan in a cycle. An MSn scan that does not state its own uses the survey's. Always sent, including `0`. |
| **Analyzer-side** | `resolution`, `agc_target`, `max_it`, `microscans`, `data_type`, `scan_rate`, `activation`, `collision_energy`, `reaction_time`, `reagent_*` | *How the arriving ions are measured* | Per-scan. Never inherited. `0`/`""` means "use the instrument method default". |

Concretely:

1. `MS2Parameters`, `MS3Parameters` and `JsonMs2Config` carry all 17 `kScanKeys` entries;
   `MS1Parameters` and `JsonMs1Config` carry the 12 that are not stage-carried.
2. **Inheritance is resolved at C# emit time**, in `ToJsonScanConfig`. Zero means inherit.
3. `ScanFactory` emits the source-region group unconditionally. Analyzer-side scalars keep their
   guards.
4. `makeAGC` takes the source region from the survey's config; its analyzer-side parameters stay
   fixed to the fast-prescan identity.

### Why inheritance does not break ADR-0009

ADR-0009 says an unset value means "use the instrument method default", **never** "inherit from
another scan". That rule was written for activation-coupled parameters, where inheriting is
actively dangerous — an ETD follow-up silently running at an HCD scan's `reaction_time`. It is the
right rule for the analyzer-side class and the wrong one for the source region, because the source
region is not a property of a scan at all: it is a property of the ion population every scan in the
cycle draws from. An MS1 that declusters at source CID 15 and an MS2 that isolates from an
un-declustered population are not measuring the same species.

The invariant survives verbatim anyway, because inheritance is a **config-construction rule, not a
runtime lookup**. `ToJsonScanConfig` materialises the survey's value into the emitted JSON, so by
the time any `ScanConfig` exists — let alone any `ScanCommand` — it carries a concrete number. No
code downstream of the bridge knows inheritance happened.

It also *has* to live there. `ToCppJson` emits every key unconditionally, so there is no absent
state on the wire; C++ cannot distinguish "unset" from "explicitly 0" and could not implement the
rule even if we wanted it to.

### Why zero means inherit

Three-valued semantics (absent / 0 / V) would need nullable model fields, a `PopulateStruct`
branch, and a `ScanFactory` guard redesign — and would buy the ability to say "source CID off for
MS2 while MS1 uses it", which is not a configuration anyone has asked for. "Let the instrument
decide" remains reachable by leaving the **survey's** value unset: `0` propagates to every level
and `ScanFactory`'s unconditional emit sends `0`, which the instrument treats as no source CID.

## Consequences

`scan_rate` is added at every level even though it is IonTrap-only and no committed config selects
IonTrap. Including it makes *"the C# schema admits exactly the keys that can reach the instrument
at that level"* a checkable invariant rather than a per-key judgement — and a per-key judgement is
what produced this defect. `ConfigSchemaParity_test::GeneratedReference_CarriesEveryScanKey`
enforces it by comparing the C#-generated reference against `Config::scanKeys()`, so the two lists
cannot drift apart silently in either direction again.

`makeAGC` becomes load-bearing rather than incidental. With the guards gone, an AGC command that
left the source region at `0` would actively command RF lens 0 on the prescan that gains every scan
following it. It now copies the survey's source region, and keeps `microscans = 1` and
`data_type = "Profile"` hardcoded alongside the existing `agc_target`/`max_it`/`analyzer`/
`scan_rate` — taking `microscans` from config would quadruple a priority-0 scan, since the shipped
`method.json` asks for 4.

`buildMS2` is corrected to read `agc_target` and `max_it` from the `ScanConfig` it is handed
instead of `config_.level(2).scans[0]`. This was the same ADR-0009 violation in miniature:
`ms_settings.ms2[1..N]` acquired at `ms2[0]`'s values, and exploration overrides of those two keys
were inert at level 2.

ADR-0009's Consequences state that these keys *"now come from the follow-up's own config"*. That
was true of the C++ half and false end-to-end. It becomes true with this change.

No golden moves. None of these fields is a logged column, none enters an engine decision, and none
is serialized by `ScanCommandRecord`.

Deliberately out of scope, recorded rather than fixed: `ms_settings.ms3[1..N]` is parsed but every
MS3 build site reads index 0; `buildMS3`'s stage-0 override omits the reagent fields;
`quantification.only_one_condition` and `tagging.active` are accepted by the schema and never
emitted.

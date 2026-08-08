# 0004. Characterization config: one new section, reuse existing knobs, never resurrect ms3.*

Status: Accepted (2026-06-24) — **the "no enable flag" decision is SUPERSEDED by
[0013-characterization-mode-is-the-single-ms3-switch.md](0013-characterization-mode-is-the-single-ms3-switch.md)
(2026-08-08)**, and the section's shape by
[0014-two-decision-sections-and-named-scan-configs.md](0014-two-decision-sections-and-named-scan-configs.md).
The reuse-existing-knobs principle below still holds; the implicit-engagement clause does not.

## Context

FLASHIda configuration crosses two deliberately different schemas: `method.json` →
C# `MethodConfig` (`[JsonKey]` reflection) → `MethodParameters.ToCppJson()` →
C++ `Config`. A knob missing from any of those three places is **silently dropped**
(precedent: the entire `global` section, `tagging.Active`, `only_one_condition`,
`IsolationMode`). The C++ parser additionally **throws** on legacy `ms3.*` control
keys, because MS3 control was deliberately moved into `selection_strategy`
(`Config.cpp:171-179`).

## Decision

Add exactly **one** new top-level section, **`characterization`**, holding only:

- `objective` — `ambiguity | coverage` (no termination criterion yet; coverage is
  reported in the pooled log)
- `protein_sequence` — the target proteoform, **relocated out of `ms3.protein_sequence`**

Everything else **reuses existing knobs**: mapping tolerance = per-level
`deconvolution.tol[]`; MS3 planning budget = `selection_strategy.ms2.max_targets`;
best proteoform = highest FLASHExtender score (no floor); the MS2/MS3 parameter
sweeps stay in `selection_strategy.*.exploration`. The model **engages whenever an
MS2 selection strategy is configured** — there is no enable flag. The pooled
identification log is a **fifth `runtime` path** (`pooled_identification_log_path`),
on iff its path is non-empty, like the existing four logs.

> **SUPERSEDED (ADR-0013, ADR-0014).** Implicit engagement did not survive contact: MS3 ended up
> gated by three keys across two sections, none named `enable`, with the objective decided by a
> key's *absence*. The switch is now `characterization.mode` (`off | ambiguity | coverage`);
> `objective` is folded into it; the MS3 budget and charge floor are authored as
> `characterization.max_targets` / `.min_fragment_charge`; and `selection_strategy` no longer
> exists. The reuse-existing-knobs principle above still holds — tolerance is still
> `deconvolution.tol[]`, the proteoform is still the highest FLASHExtender score, and the pooled
> log is still a `runtime` path.

## Why / Consequences

Reusing existing knobs keeps a single source of truth and avoids the two schemas
drifting; the only genuinely new config surface is the irreducibly-new section plus
one log path. Relocating `protein_sequence` means it must be **removed from `ms3.*`
cleanly** — leaving the legacy key trips the C++ legacy-key guard and throws. Any new
knob, including `objective` and the log path, must be added in all three schema
places or it is silently lost.

# 0005. MS3 target is a *containing* fragment; the ProteoformTracker is the sole MS3 dispatch authority

Status: Accepted (2026-06-24)

## Context

T9b (ADR-0002) made the `ProteoformTracker` plan MS3, but its first `Ambiguity` objective
targeted a fragment whose backbone cleavage falls **strictly inside** the ambiguous PTM range.
That predicate is self-defeating — a fragment cleaving inside the range would *already have
narrowed it*, so for a genuinely ambiguous site none exists. The model dispatched **zero MS3**
in every MS3-capable mode (a regression caught by the golden-diff assessment and an
adversarially-verified root-cause investigation; OpenMS `0727b3de8a`).

## Decision

- **Target = a fragment that CONTAINS the range.** For an ambiguous modification over residues
  `[s,e]`, the MS3 target is an observed fragment whose coverage contains the range
  (`cover_start ≤ s AND cover_end ≥ e`). Its MS3 re-fragments the span and produces the internal
  cleavages that localize the PTM. A b-ion contains the range iff its index `k ≥ e`; a y-ion iff
  `k ≥ L−s+1`. The separate **Coverage** objective analogously targets containers of uncovered gaps.
- **Selection:** pick the highest-`best_ms2`-intensity container (strongest MS3 precursor);
  **round-robin across ambiguous mods** (one each first), bounded by `ms2.max_targets`.
- **No container → zero MS3 is correct** — MS3 physically cannot narrow a range nothing spans;
  there is **no** legacy/intensity fallback.
- **The tracker is the SOLE MS3 authority for ALL MS3 modes** (exploration *and* non-exploration):
  it is fed from the non-exploration MS2→MS3 path too, and the legacy `getTopFragmentMatches`
  MS3 emitter is **retired**.
- **`narrowModifications_` keeps the inside-cleavage predicate** — it narrows the range *from* the
  MS3 re-feed's new internal cleavages. *Contains* = pick an MS3 target; *inside* = narrow once the
  cleavages arrive. Two predicates, two jobs.
- **Multi-charge MS3 is config-gated** (`MS3AllCharges`); default is the single highest-intensity
  charge.

## Consequences

Every MS3-mode golden changes (model-driven, container-targeted MS3 replaces the legacy
intensity-scatter) and is recaptured only after a golden-diff assessment and explicit sign-off.
The legacy emitter is gone, so MS3 dispatch is one consistent path. A range with no containing
fragment yields no MS3 by design.

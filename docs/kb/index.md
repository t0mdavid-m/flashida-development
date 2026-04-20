# KB Index

Agent-facing knowledge base for FLASHIda. Each packet is a self-contained
subsystem guide — read the packet README first, drill down as needed.

## Packets

- [MS1 acquisition](ms1-acquisition/README.md) — precursor selection,
  targeting modes, FAIMS cycling.
- [Config flow](config-flow/README.md) — method.json → C# → C++ bridge → engine config.
- [Exploration](exploration/README.md) — MS2 and MS3 exploration: variants, scoring, winner selection.
- [Scan pipeline](scan-pipeline/README.md) — ScanCommand struct, queue, 5 bridge exports, C# consumer.
- [Acquisition loop](acquisition-loop/README.md) — end-to-end round-trip: startup, per-scan event flow, C++ engine entry points, shutdown.
- [Fragment analysis](fragment-analysis/README.md) — tag+follow-up mode, MS2 fragment matching, MS3 fragment matching + calibration.

## Conventions

- Frontmatter `last_verified` dates claims to a point in time; verify
  `code_anchors` before acting on a KB claim.
- If `code_anchors` don't resolve, the entry is stale — update or remove
  it before relying on it.
- File paths are relative to the parent-repo root.

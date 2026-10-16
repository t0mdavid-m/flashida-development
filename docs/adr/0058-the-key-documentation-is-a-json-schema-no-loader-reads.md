# 0058. The key documentation is a JSON Schema no loader reads, held to the model by a test

Status: Accepted (grilled 2026-10-11), implemented 2026-10-16 (FlashIDA `fb6080e`, Pages run 38945618649). Live at https://t0mdavid-m.github.io/FlashIDA/.
Plan: `docs/superpowers/plans/2026-10-16-method-json-key-documentation-site.md`.

## Context

`method.json` has 13 top-level sections and, on 2026-10-16, 189 leaf keys. The only per-key
documentation was a one-section reference sheet (`quantification`, hand-typeset in LaTeX outside
every repo) and the KB, which is written for agents. The owner asked for a public page on the
FlashIDA fork that documents every key in the sheet's style: key, type, default, values and rules,
and the value in a named committed config.

Three ways to source such a page were weighed. Hand-written HTML has no drift guard at all.
Generating the page from the C# model would guard drift but cannot produce the prose, which is the
whole value of the sheet. A structured source file plus a test sits between them.

## Decision

1. **The source is one hand-authored JSON Schema (draft 2020-12),
   `FlashIDA/docs/site/method.schema.json`.** Each key carries `type`, `default`, `enum` where the
   value set is closed, and its prose as `description`. The two objects that recur — the scan
   settings object (`ms1`, `ms2`, `ms2_quant`, `ms3`, every `additional_ms2` entry) and the
   `exploration` object (identical under `precursor_selection` and `characterization`) — are
   `$defs`, documented once. What JSON Schema has no word for (unit, ADR references, the exemplar
   config of a page) goes in `x-` keywords.
2. **No loader reads the schema.** The strict C# and C++ loaders stay the only judges of a config;
   the schema describes them. This is deliberate: a third validator in the acquisition path would be
   a third place to disagree.
3. **Drift is caught in two directions.** A C# test beside `ConfigSchemaParityTests` requires the
   schema's key paths to equal those of `GenerateReferenceConfigJson()`, so adding a key without a
   documentation entry fails CI. The Pages workflow validates every committed config against the
   schema with ajv, so a wrong type or enum in the documentation fails the deploy.
4. **The page is rendered, never written.** A dependency-free Node script turns the schema and the
   exemplar configs into the site. Exemplar values are read from the config files at render time.
5. **The site deploys from one branch by a workflow on the public fork** — the engine's
   integration branch, `phase-containers` today — so a page always corresponds to a commit.

## Consequences

- Adding a key now has a **fourth site** beside the model, `ToCppJson` and
  `BuildFullReferenceConfig`: its entry in the schema. Missing it fails the new C# test.
- The schema's `default` and `description` are claims a human wrote. The test proves a key is
  documented, not that its prose is right; the prose is as good as its last review.
- Committed configs cannot carry a `"$schema"` line: both strict loaders reject it as an unknown
  key. Editor autocompletion from the schema therefore needs a later change to both loaders.
- A rename or removal of a key moves the page on the next push, with no recapture step.

## Considered options

- **Hand-written HTML.** Rejected: no drift guard, and 189 keys drift on the first schema change.
- **Generate from the C# model and its doc comments.** Rejected: the prose is engine semantics read
  across C#, C++ and ADRs, and the C# doc comments do not carry it.
- **A bespoke YAML source.** Rejected for JSON Schema, which is the standard description of a JSON
  file, is understood by editors, and is machine-checkable by off-the-shelf validators.

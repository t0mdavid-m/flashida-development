# method.json Key Documentation Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `https://t0mdavid-m.github.io/FlashIDA/`, a GitHub Pages site on the public FlashIDA fork that documents every `method.json` key in the style of the quantification reference sheet.

**Architecture:** One hand-written JSON Schema (`FlashIDA/docs/site/method.schema.json`) holds every key's type, default, value set and prose. A C# NUnit test holds its key set equal to the model's generated reference. A Pages workflow on the fork checks every committed config against the schema with ajv, renders the schema plus named exemplar configs to static HTML with a dependency-free Node script, and deploys it.

**Tech Stack:** JSON Schema draft 2020-12; Node ≥ 20 (built-ins only, `node:test`); ajv-cli 5.0.0 (workflow only, via `npx`); C# 7.3 / .NET Framework 4.8 / NUnit 3.13.3; GitHub Actions `actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`.

**Spec:** `docs/adr/0058-the-key-documentation-is-a-json-schema-no-loader-reads.md` (the decision), the grilling answers summarised under Context below, and the style reference `C:/FLASHIda/fi_reference_sheets/quantification_reference_sheet.tex`.

---

## Context

The owner asked for a public page on the FlashIDA fork documenting every `method.json` key, in the
style of the one-page quantification reference sheet (key / type / default / values and rules /
value in a named committed config). Nothing like it exists: the fork has no Pages site, its
`main` is the 2023 XML-method era, and per-key knowledge lives in the C# model, `Config.cpp`, the
ADRs and an agent-facing KB.

Grilling outcome (2026-10-11), all settled:

| # | Decision |
|---|---|
| Q1/Q12 | Actions workflow on the fork deploys from exactly one branch, `phase-containers`, plus manual dispatch |
| Q2/Q9 | Source is a hand-authored JSON Schema 2020-12; the page is rendered from it |
| Q10/Q24 | Drift guard = a C# NUnit key-set test beside `ConfigSchemaParityTests` **and** ajv validation of committed configs in the Pages workflow |
| Q3/Q20 | Index page + one page per group + one print page. Groups: run (`global`, `files`, `runtime`, `scheduling`), deconvolution, precursor selection, exploration, characterization, scan settings, ms_settings roster, quantification, faims, tagging (`tagging`, `conditional_ms2`, `flashtnt`, `precursor_selection.tag_expansion`) |
| Q4/Q11 | Last column(s) = value in a named exemplar config per section (table in Task 3) |
| Q5 | The scan settings object and the `exploration` object are each documented once (`$defs`), with an applicability column where keys differ by level |
| Q6/Q14 | No load-error page, no load-error or retired-key footers, no load-error enumeration in rules cells |
| Q7 | Source in `FlashIDA/docs/site/`, workflow in `FlashIDA/.github/workflows/`, README links it |
| Q8 | The word is **key** (CONTEXT.md entry written) |
| Q13 | Enable Pages once the first local render looks right |
| Q15 | Header stamp from the workflow (date, commit, branch); local render says "working tree" |
| Q16 | System serif and monospace, no vendored fonts |
| Q17 | Renderer is a dependency-free Node script |
| Q18 | Sheet-depth prose for decision sections; one line for the 17 scan keys |
| Q19 | Review on the live site after publishing |
| Q21 | No `"$schema"` line in configs (both strict loaders would reject it) |
| Q22 | Docs-only: implement, test quickly locally, push to publish. No containers |
| Q23 | ADR written: ADR-0058 |

Already done in the parent working tree during planning (uncommitted): ADR-0058, the CONTEXT.md
**Key** entry, and the CLAUDE.md correction of the retired `developer` section.

## TL;DR

- We write **one file by hand**, `method.schema.json`: every key with its type, default, allowed values and a few sentences of what it does.
- A small **Node script** turns that file into the web pages. Nobody edits HTML.
- The value column shows what a **real committed config** sets. The script reads it from the config at build time, so it cannot go stale.
- The scan settings (17 keys shared by `ms1`, `ms2`, `ms2_quant`, `ms3`, extra MS2s) and the `exploration` block are **written once** and linked from where they are used.
- A **C# test** fails CI if someone adds a key to the model and forgets the docs, or if the docs list a key the model does not have.
- The same test fails if a documented key has **no description**.
- The Pages workflow runs **ajv** over all 49 committed configs plus the production `etc/method.json`. A wrong type or value list in the docs fails the deploy.
- Push to `phase-containers` in the fork, and the site **rebuilds and redeploys** in about a minute.
- No engine code, no goldens, no existing test changes. One new test file, one csproj line.
- Adding a key now has a **fourth site**: the schema. CLAUDE.md, FlashIDA/CLAUDE.md and the KB say so.
- **Every hook and checklist** that fires or is followed on a config change gains the "document it" step: the config-schema hook (which also starts firing on the schema file), the validator skill, the KB guard lists, the parity-test docstring, and the open Kinetic Model and Refine plans plus the FLASHTnT spec.

```
 MethodConfig.cs ──GenerateReferenceConfigJson──▶ test-data/config_schema_reference.json
                                                        │  (existing: Reference_IsNeverStale)
                                                        ▼
   KeyDocumentationParityTests (NEW, C#) ◀── same key paths? every key described? ──┐
                                                                                    │
   test-data/configs/method_*.json ──ajv (workflow)── obey the docs? ──▶  docs/site/method.schema.json  (hand-written)
   src/Flash/etc/method.json ────────────────────────────────────────┘             │
                                                                                    ▼
                        exemplar configs ──────────────────────────────▶  docs/site/build.js  ──▶  docs/site/_site/*.html
                                                                                                         │
                                                                     .github/workflows/pages.yml ──deploy──▶ t0mdavid-m.github.io/FlashIDA
```

## Global Constraints

- **No engine code, no golden, no existing test is changed.** The only test change is the new file `FlashIDA/src/Flash.Tests/KeyDocumentationParityTests.cs` (+ `KeyPaths.cs` helper) and its csproj lines. (owner, Q22; memory "test changes need planning approval")
- The schema is **draft 2020-12**, `$schema: "https://json-schema.org/draft/2020-12/schema"`, `$id: "https://t0mdavid-m.github.io/FlashIDA/method.schema.json"`.
- Non-standard keywords are exactly: `x-pages` (root only), `x-unit`, `x-type-text`, `x-default-text`, `x-adr`, and VS Code's `enumDescriptions` (array parallel to `enum`). No others.
- Every object node in the schema carries `"additionalProperties": false` unless it is a user-keyed map, mirroring the strict loaders (ADR-0007).
- No `required` keyword anywhere: requiredness is stated in the default column (`x-default-text`, e.g. "required when `enabled`").
- Rules cells state what the key does and how it interacts with other keys. They **do not** enumerate load errors or retired keys (Q14).
- Prose is read from the code, never from memory: `FlashIDA/src/Flash/MethodConfig.cs` (initializer = C# default, `[Description]` = seed text), `MethodParameters.ToCppJson`, `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` (parse + validate), the consuming engine site, and the ADR. When C# and C++ defaults differ for an omitted key, the default column says what an **omitted** key produces and the rules cell says "Author it", as the sheet does for `reporter_mz_tol`.
- A disagreement found between docs and engine while reading is **reported to the owner, not fixed** (no engine code in this plan).
- Renderer: Node built-ins only (`fs`, `path`, `child_process`, `node:test`, `node:assert`). Output to `FlashIDA/docs/site/_site/` (gitignored).
- ajv command, exactly (spiked 2026-10-16, exits 1 on an invalid file):
  `npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false --all-errors --errors=line -s docs/site/method.schema.json -d "test-data/configs/method_*.json" -d src/Flash/etc/method.json`
- Site title: "FLASHIda method.json keys". URL `https://t0mdavid-m.github.io/FlashIDA/`. Light theme only. System fonts.
- Deploy branch: exactly `phase-containers`. Nothing else may deploy.
- `FlashIDA/.gitattributes` forces CRLF on checkout. Never `sed -i` a file under `FlashIDA/` (memory: sed strips CRLF); use the Edit/Write tools or Node.
- Parent working tree carries **another session's** uncommitted edits (CONTEXT.md, ADR-0047, untracked files). Stage only the exact paths and hunks this plan owns.
- Push order: FlashIDA first, parent last. `git pull --rebase` in both before pushing. Never `gh run watch`; poll `gh run list` at ≥ 60 s.
- Commits end with the two attribution lines from the session's system reminder.

## Review Focus

1. **The `github-pages` environment rejects `phase-containers`.** GitHub creates it allowing only the default branch (`main`), so the first deploy fails with "Branch is not allowed to deploy". Expected: the deploy succeeds. Pinned by Task 10 Step 3 (environment branch policy created and read back) and Step 6 (deploy job green).
2. **A key whose reference value is `null` or an empty container hides its children** (e.g. `precursor_selection.exploration.kinetic_model` is `null`, its `k2` child exists only in the `characterization` instance). Expected: no false "documented but absent" report; the subtree is still checked through the other instance of the same `$def`. Pinned by Task 2 test `Compare_NullAndEmptyReferenceNodesExemptTheirSubtree`.
3. **A user-keyed map** (`ms_settings.additional_ms2` holds scan objects; `quantification.channel_normalization` and `exploration.overrides` hold scalars). Expected: a scalar map is one key; an object map documents its entry shape once under `*`. Pinned by Task 2 test `FromSchema_MapsAndObjectArrays` and the real-file tests.
4. **A level that accepts only part of a shared object** (`ms1` takes 12 of the 17 scan keys). Expected: the schema says so with `propertyNames.enum`, the drift test honours it, ajv rejects `ms1.reaction_time`, and the scan page shows an applicability column. Pinned by Task 2 test `FromSchema_RefWithPropertyNamesFiltersKeys` and Task 4 test `applicability column appears only when keys differ by user`.
5. **A committed config the docs reject** (wrong `integer` vs `double`, a missing enum value, `etc/method.json` carrying an unexpected key). Expected: the deploy fails and names the file and path; the fix goes into the schema, or is reported if the config itself is wrong. Pinned by the ajv step run locally in Task 3 Step 6 and in the workflow (Task 10).

## File Structure

| File | Repo | Status | Responsibility |
|---|---|---|---|
| `docs/site/method.schema.json` | FlashIDA | create | The single source: every key, `$defs` `scan` and `exploration`, `x-pages` layout |
| `docs/site/build.js` | FlashIDA | create | Renders schema + exemplar configs to `_site/`; strict and `--draft` modes |
| `docs/site/build.test.js` | FlashIDA | create | `node:test` tests of the renderer's pure functions and a fixture build |
| `docs/site/style.css` | FlashIDA | create | Sheet look: serif body, grey header row, mono key column, print rules |
| `.github/workflows/pages.yml` | FlashIDA | create | test → ajv → render → upload → deploy |
| `.gitignore` | FlashIDA | modify | add `docs/site/_site/` |
| `src/Flash.Tests/KeyPaths.cs` | FlashIDA | create | Pure key-path walkers for schema and reference |
| `src/Flash.Tests/KeyDocumentationParityTests.cs` | FlashIDA | create | 7 NUnit tests (5 primitive, 2 real-file) + 1 description test |
| `src/Flash.Tests/Flash.Tests.csproj` | FlashIDA | modify | two `<Compile Include>` lines |
| `README.md` | FlashIDA | modify | link to the site; fix the "XML-formatted method file" sentence |
| `CLAUDE.md` | FlashIDA | modify | adding a key: schema is the fourth site |
| `docs/adr/0058-…md`, `CONTEXT.md`, `CLAUDE.md` | parent | already edited | commit (Task 1); CLAUDE.md gets the fourth-site rule + Docs Map line (Task 11) |
| `docs/kb/config-flow/adding-a-config-field.md` | parent | modify | new step: document the key in the schema |
| `.claude/hooks/config-schema-drift-reminder.sh` | parent | modify | the reminder gains step (4) "document it", and fires on `method.schema.json` too |
| `.claude/skills/validate-flashida-config/SKILL.md` | parent | modify | Maintenance: a key change also updates the key documentation |
| `docs/kb/config-flow/config-flow.md`, `docs/kb/config-flow/README.md` | parent | modify | the drift-guard lists gain `KeyDocumentationParityTests` and the ajv step |
| `src/Flash.Tests/ConfigSchemaParityTests.cs` | FlashIDA | modify | **docstring only**: "to change the schema" names the fourth site |
| `docs/superpowers/plans/2026-10-11-kinetic-model-energy-choice.md`, `…/2026-10-11-refine-annotation-method.md` | parent | modify | their docs task gains "update `method.schema.json`" |
| `docs/superpowers/specs/2026-08-09-flashtnt-param-plumbing-design.md` | parent | modify | its file table gains the `method.schema.json` row |
| `docs/superpowers/plans/2026-10-16-method-json-key-documentation-site.md` | parent | create | copy of this plan (ADR-0058 links it) |

## Working Agreement

- **Docs-only work, owner-relaxed process (Q22):** implement, verify locally, push to publish. No Docker containers. The parent CI run triggered by the gitlink bump is still watched to green, because it is the first execution of the new C# test inside the real NUnit suite.
- **Tests are frozen to the list in Tasks 2 and 4**, plus one comment-only edit to the `ConfigSchemaParityTests` class docstring (Task 11b). Adding, editing or removing any other test needs the owner's sign-off first.
- **Every place that tells an agent how to change a key is updated in this plan** (Task 11b): the hook, both CLAUDE.md rules, the KB, the validator skill, the parity-test docstring, and the open plans and spec that will still change keys. From the first push on, nothing tells an agent to change a key without also telling it to document it.
- **A red check is fixed in the docs, never by weakening the check.** If ajv rejects a committed config, either the schema is wrong (fix the schema) or the config is wrong (report it; do not edit the config in this plan).
- **Docs-vs-engine disagreements are reported, not fixed.** Collect them in the final report.
- **Fine-grained commits, one landing:** one commit per task below, docs separate from code, then one push per repo.
- **No golden is read or written.** If the golden-write-guard hook fires, stop: something is wrong.
- Present plans in native plan mode; any failure that changes the design → back to plan mode.

---

### Task 1: Commit the decision documents (parent)

**Files:**
- Commit: `docs/adr/0058-the-key-documentation-is-a-json-schema-no-loader-reads.md` (new)
- Commit: `CLAUDE.md` (the developer-section correction only)
- Commit: `CONTEXT.md` (the **Key** entry hunk only; the rest of the file's diff belongs to another session)
- Create + commit: `docs/superpowers/plans/2026-10-16-method-json-key-documentation-site.md` (copy of this plan)

**Interfaces:** Produces the ADR number 0058 that every later doc line cites.

- [ ] **Step 1: Check what else is dirty in the two edited tracked files**

```bash
cd /c/FLASHIda/flashida-development
git diff --stat -- CLAUDE.md CONTEXT.md
git diff -- CLAUDE.md | head -40
```
Expected: CLAUDE.md diff is only the one `developer` sentence. CONTEXT.md has other hunks too.

- [ ] **Step 2: Stage only the Key entry of CONTEXT.md, without touching the working tree**

Build the index blob from `HEAD:CONTEXT.md` plus the Key paragraph, so the other session's hunks stay unstaged and the working file is never rewritten:

```bash
cd /c/FLASHIda/flashida-development
node -e '
const {execSync}=require("child_process");const fs=require("fs");
const head=execSync("git show HEAD:CONTEXT.md").toString();
const work=fs.readFileSync("CONTEXT.md","utf8");
const start=work.indexOf("**Key**:\n");const end=work.indexOf("\n## Language — instrument control");
if(start<0||end<0) throw new Error("Key entry not found");
const entry=work.slice(start,end).replace(/\s+$/,"")+"\n\n";
const anchor="## Language — instrument control";
if(head.includes("**Key**:\n")) throw new Error("HEAD already has Key");
const out=head.replace(anchor, entry+anchor);
fs.writeFileSync(process.env.CLAUDE_JOB_DIR+"/tmp/CONTEXT.staged.md",out);'
blob=$(git hash-object -w "$CLAUDE_JOB_DIR/tmp/CONTEXT.staged.md")
git update-index --cacheinfo 100644,$blob,CONTEXT.md
git diff --cached -- CONTEXT.md
```
Expected: the cached diff shows only the **Key** paragraph added before `## Language — instrument control`.

- [ ] **Step 3: Commit the three documents and the plan**

```bash
cp "/c/Users/User/.claude/plans/jolly-watching-crayon.md" docs/superpowers/plans/2026-10-16-method-json-key-documentation-site.md
git add docs/adr/0058-the-key-documentation-is-a-json-schema-no-loader-reads.md CLAUDE.md docs/superpowers/plans/2026-10-16-method-json-key-documentation-site.md
git commit -m "docs: ADR-0058 -- the key documentation is a JSON Schema no loader reads; CONTEXT.md Key; CLAUDE.md drops the retired developer section

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
git status --short -- CONTEXT.md
```
Expected: `CONTEXT.md` still shows ` M` (the other session's hunks remain unstaged in the working tree).

---

### Task 2: Key-path walkers and the drift tests (C#, TDD)

**Files:**
- Create: `FlashIDA/src/Flash.Tests/KeyPaths.cs`
- Create: `FlashIDA/src/Flash.Tests/KeyDocumentationParityTests.cs`
- Modify: `FlashIDA/src/Flash.Tests/Flash.Tests.csproj` (beside line 92, `<Compile Include="ConfigSchemaParityTests.cs" />`)

**Interfaces:**
- Produces: `internal static class Flash.Tests.KeyPaths` with
  - `static Dictionary<string, Dictionary<string, object>> FromSchema(Dictionary<string, object> schema)` — path → the property node as written (null for synthetic `*`/`[]` nodes)
  - `static Reference FromReference(Dictionary<string, object> reference, Dictionary<string, object> schema)` with `Reference.Paths : SortedSet<string>` and `Reference.Uncovered : List<string>`
  - `static List<string> Undocumented(Reference r, ICollection<string> schemaPaths)` and `static List<string> Absent(Reference r, ICollection<string> schemaPaths)`
- Path grammar used by everything downstream: dotted keys; `*` for an entry of a map whose values are objects; `[]` for an item of an array whose items are objects (`quantification.conditions[].name`). A map of scalars, a scalar array and an object with no documented children are one key.

**Test pseudocode (the approved list):**

```
TEST FromSchema_RefWithPropertyNamesFiltersKeys
  schema: props { ms1: {$ref scan, propertyNames.enum [a]}, ms2: {$ref scan} }, $defs.scan props {a, b}
  paths = FromSchema(schema)
  ASSERT paths == {ms1, ms1.a, ms2, ms2.a, ms2.b}

TEST FromSchema_MapsAndObjectArrays
  schema: props { extra: object, additionalProperties {$ref scan}     // map of objects
                  norm:  object, additionalProperties {type number}   // map of scalars
                  conds: array, items {props {name, channels}} }
  ASSERT FromSchema == {extra, extra.*, extra.*.a, extra.*.b, norm, conds, conds[], conds[].name, conds[].channels}

TEST FromSchema_DanglingRefThrows
  schema: props { x: {$ref "#/$defs/missing"} }
  ASSERT throws InvalidOperationException containing "missing"

TEST Compare_NullAndEmptyReferenceNodesExemptTheirSubtree
  schema: props { e1: {$ref expl}, e2: {$ref expl} }, $defs.expl props { km: props { k2: map number } }
  reference: { e1: { km: null }, e2: { km: { k2: { CID: 0.01 } } } }
  r = FromReference(reference, schema)
  ASSERT Undocumented(r, FromSchema) is empty
  ASSERT Absent(r, FromSchema) is empty          // e1.km.k2 exempt: e1.km was null
  reference2: { e1: { km: null }, e2: { km: null } }
  ASSERT Absent(FromReference(reference2), …) is empty   // both instances exempt: nothing to compare

TEST Compare_ReportsBothDirections
  schema: props { a, b }; reference: { a: 1, c: 2 }
  ASSERT Undocumented == [c]
  ASSERT Absent == [b]

TEST Schema_DocumentsEveryKeyOfTheReference            (real files)
  r = FromReference(config_schema_reference.json, method.schema.json)
  ASSERT Undocumented(r, FromSchema(schema)) is empty, listing each path

TEST Schema_DocumentsNoKeyTheModelLacks                 (real files)
  ASSERT Absent(r, FromSchema(schema)) is empty, listing each path

TEST Schema_EveryDocumentedKeyHasADescription           (real file)
  for each (path, node) in FromSchema(schema) where node != null
    ASSERT node.description is a non-empty string
```

- [ ] **Step 1: Write `KeyPaths.cs`**

```csharp
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

namespace Flash.Tests
{
    /// <summary>
    /// Key paths of method.json, read two ways, for the key documentation drift guard (ADR-0058).
    /// Path grammar: dotted keys; "*" is an entry of a map whose values are objects; "[]" is an item
    /// of an array whose items are objects. A map of scalars, a scalar array and an object with no
    /// documented children are one key each.
    /// </summary>
    internal static class KeyPaths
    {
        internal sealed class Reference
        {
            public readonly SortedSet<string> Paths = new SortedSet<string>(StringComparer.Ordinal);
            /// <summary>Paths whose reference value was null or an empty container: their schema
            /// subtree has no instance here to compare against.</summary>
            public readonly List<string> Uncovered = new List<string>();
        }

        private const string DefPrefix = "#/$defs/";

        public static Dictionary<string, Dictionary<string, object>> FromSchema(Dictionary<string, object> schema)
        {
            var defs = Defs(schema);
            var result = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
            WalkSchema(schema, "", defs, result, 0);
            return result;
        }

        public static Reference FromReference(Dictionary<string, object> reference, Dictionary<string, object> schema)
        {
            var r = new Reference();
            WalkReference(reference, "", schema, Defs(schema), r, 0);
            return r;
        }

        public static List<string> Undocumented(Reference r, ICollection<string> schemaPaths)
        {
            return r.Paths.Where(p => !schemaPaths.Contains(p)).ToList();
        }

        public static List<string> Absent(Reference r, ICollection<string> schemaPaths)
        {
            return schemaPaths
                .Where(p => !r.Paths.Contains(p) && !r.Uncovered.Any(u => IsUnder(p, u)))
                .OrderBy(p => p, StringComparer.Ordinal)
                .ToList();
        }

        private static bool IsUnder(string path, string prefix)
        {
            return path.Length > prefix.Length && path.StartsWith(prefix, StringComparison.Ordinal)
                && (path[prefix.Length] == '.' || path[prefix.Length] == '[');
        }

        private static Dictionary<string, object> Defs(Dictionary<string, object> schema)
        {
            object d;
            return schema.TryGetValue("$defs", out d) ? (Dictionary<string, object>)d : new Dictionary<string, object>();
        }

        private static string Join(string path, string key)
        {
            return path.Length == 0 ? key : path + "." + key;
        }

        /// <summary>Follows a $ref to its $defs target. The propertyNames.enum of the ref site
        /// (if any) is returned as the set of keys this use admits.</summary>
        private static Dictionary<string, object> Resolve(Dictionary<string, object> node,
            Dictionary<string, object> defs, out HashSet<string> admitted, int depth)
        {
            admitted = null;
            if (node == null) return null;
            if (depth > 32) throw new InvalidOperationException("$ref nesting deeper than 32");
            object pn, en;
            var pnd = node.TryGetValue("propertyNames", out pn) ? pn as Dictionary<string, object> : null;
            if (pnd != null && pnd.TryGetValue("enum", out en))
                admitted = new HashSet<string>(((IList)en).Cast<object>().Select(o => (string)o), StringComparer.Ordinal);
            object r;
            if (!node.TryGetValue("$ref", out r)) return node;
            var target = (string)r;
            if (!target.StartsWith(DefPrefix, StringComparison.Ordinal))
                throw new InvalidOperationException("Unsupported $ref " + target);
            object def;
            if (!defs.TryGetValue(target.Substring(DefPrefix.Length), out def))
                throw new InvalidOperationException("Dangling $ref " + target);
            HashSet<string> inner;
            var resolved = Resolve((Dictionary<string, object>)def, defs, out inner, depth + 1);
            if (admitted == null) admitted = inner;
            return resolved;
        }

        private static Dictionary<string, object> Child(Dictionary<string, object> node, string key)
        {
            object v;
            return node != null && node.TryGetValue(key, out v) ? v as Dictionary<string, object> : null;
        }

        private static bool HasProperties(Dictionary<string, object> resolved)
        {
            return Child(resolved, "properties") != null;
        }

        /// <summary>Value schema of a user-keyed map, or null when the node is not a map.</summary>
        private static Dictionary<string, object> MapValue(Dictionary<string, object> resolved)
        {
            if (resolved == null || HasProperties(resolved)) return null;
            return Child(resolved, "additionalProperties");
        }

        private static void WalkSchema(Dictionary<string, object> node, string path, Dictionary<string, object> defs,
            Dictionary<string, Dictionary<string, object>> result, int depth)
        {
            HashSet<string> admitted;
            var resolved = Resolve(node, defs, out admitted, depth);
            var props = Child(resolved, "properties");
            if (props != null)
            {
                foreach (var kv in props)
                {
                    if (admitted != null && !admitted.Contains(kv.Key)) continue;
                    var p = Join(path, kv.Key);
                    var child = (Dictionary<string, object>)kv.Value;
                    result[p] = child;
                    WalkSchema(child, p, defs, result, depth + 1);
                }
                return;
            }
            HashSet<string> ignored;
            var mapValue = MapValue(resolved);
            if (mapValue != null && HasProperties(Resolve(mapValue, defs, out ignored, depth + 1)))
            {
                result[path + ".*"] = null;
                WalkSchema(mapValue, path + ".*", defs, result, depth + 1);
                return;
            }
            var items = Child(resolved, "items");
            if (items != null && HasProperties(Resolve(items, defs, out ignored, depth + 1)))
            {
                result[path + "[]"] = null;
                WalkSchema(items, path + "[]", defs, result, depth + 1);
            }
        }

        private static void WalkReference(object value, string path, Dictionary<string, object> schemaNode,
            Dictionary<string, object> defs, Reference r, int depth)
        {
            HashSet<string> ignored;
            var resolved = schemaNode == null ? null : Resolve(schemaNode, defs, out ignored, depth);
            if (value == null) { r.Uncovered.Add(path); return; }

            var dict = value as Dictionary<string, object>;
            if (dict != null)
            {
                if (dict.Count == 0) { r.Uncovered.Add(path); return; }
                var mapValue = MapValue(resolved);
                if (mapValue != null)
                {
                    if (!HasProperties(Resolve(mapValue, defs, out ignored, depth + 1))) return; // map of scalars: one key
                    foreach (var kv in dict)
                    {
                        r.Paths.Add(path + ".*");
                        WalkReference(kv.Value, path + ".*", mapValue, defs, r, depth + 1);
                    }
                    return;
                }
                var props = Child(resolved, "properties");
                foreach (var kv in dict)
                {
                    var p = Join(path, kv.Key);
                    r.Paths.Add(p);
                    WalkReference(kv.Value, p, Child(props, kv.Key), defs, r, depth + 1);
                }
                return;
            }

            var list = value as IList;
            if (list != null && !(value is string))
            {
                var items = Child(resolved, "items");
                bool objectItems = items != null && HasProperties(Resolve(items, defs, out ignored, depth + 1));
                if (list.Count == 0) { if (objectItems) r.Uncovered.Add(path); return; }
                if (!(list[0] is Dictionary<string, object>)) return; // scalar array: one key
                foreach (var item in list)
                {
                    r.Paths.Add(path + "[]");
                    WalkReference(item, path + "[]", items, defs, r, depth + 1);
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write `KeyDocumentationParityTests.cs`**

```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;
using NUnit.Framework;

namespace Flash.Tests
{
    /// <summary>
    /// Key documentation drift guard (ADR-0058). docs/site/method.schema.json is hand-written; this
    /// fixture holds its key set equal to config_schema_reference.json, which Reference_IsNeverStale
    /// in turn holds equal to the C# model. Adding a key to the model therefore needs a schema entry
    /// with a description, or CI fails here.
    /// </summary>
    [TestFixture]
    public class KeyDocumentationParityTests
    {
        // Assembly location, not TestContext, so the fixture also runs under a plain reflection runner.
        private static readonly string Root = Path.Combine(
            Path.GetDirectoryName(typeof(KeyDocumentationParityTests).Assembly.Location), "..");
        private static readonly string SchemaPath = Path.Combine(Root, "docs", "site", "method.schema.json");
        private static readonly string ReferencePath = Path.Combine(Root, "test-data", "config_schema_reference.json");

        private static Dictionary<string, object> Parse(string json)
        {
            var s = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            return s.Deserialize<Dictionary<string, object>>(json);
        }

        private static Dictionary<string, object> Load(string path)
        {
            Assert.IsTrue(File.Exists(path), "File not found: " + path);
            return Parse(File.ReadAllText(path));
        }

        private static void AssertNone(List<string> problems, string what)
        {
            Assert.IsEmpty(problems, what + ":\n  " + string.Join("\n  ", problems));
        }

        [Test, Category("Tier1")]
        public void FromSchema_RefWithPropertyNamesFiltersKeys()
        {
            var schema = Parse(@"{""properties"":{
                ""ms1"":{""$ref"":""#/$defs/scan"",""propertyNames"":{""enum"":[""a""]}},
                ""ms2"":{""$ref"":""#/$defs/scan""}},
              ""$defs"":{""scan"":{""type"":""object"",""properties"":{""a"":{},""b"":{}}}}}");
            CollectionAssert.AreEquivalent(new[] { "ms1", "ms1.a", "ms2", "ms2.a", "ms2.b" },
                KeyPaths.FromSchema(schema).Keys);
        }

        [Test, Category("Tier1")]
        public void FromSchema_MapsAndObjectArrays()
        {
            var schema = Parse(@"{""properties"":{
                ""extra"":{""type"":""object"",""additionalProperties"":{""$ref"":""#/$defs/scan""}},
                ""norm"":{""type"":""object"",""additionalProperties"":{""type"":""number""}},
                ""conds"":{""type"":""array"",""items"":{""type"":""object"",""properties"":{""name"":{},""channels"":{}}}}},
              ""$defs"":{""scan"":{""type"":""object"",""properties"":{""a"":{},""b"":{}}}}}");
            CollectionAssert.AreEquivalent(
                new[] { "extra", "extra.*", "extra.*.a", "extra.*.b", "norm", "conds", "conds[]", "conds[].name", "conds[].channels" },
                KeyPaths.FromSchema(schema).Keys);
        }

        [Test, Category("Tier1")]
        public void FromSchema_DanglingRefThrows()
        {
            var schema = Parse(@"{""properties"":{""x"":{""$ref"":""#/$defs/missing""}}}");
            var ex = Assert.Throws<InvalidOperationException>(() => KeyPaths.FromSchema(schema));
            StringAssert.Contains("missing", ex.Message);
        }

        [Test, Category("Tier1")]
        public void Compare_NullAndEmptyReferenceNodesExemptTheirSubtree()
        {
            var schema = Parse(@"{""properties"":{""e1"":{""$ref"":""#/$defs/expl""},""e2"":{""$ref"":""#/$defs/expl""}},
              ""$defs"":{""expl"":{""type"":""object"",""properties"":{
                ""km"":{""type"":""object"",""properties"":{""k2"":{""type"":""object"",""additionalProperties"":{""type"":""number""}}}}}}}}");
            var schemaPaths = KeyPaths.FromSchema(schema).Keys;

            var r = KeyPaths.FromReference(Parse(@"{""e1"":{""km"":null},""e2"":{""km"":{""k2"":{""CID"":0.01}}}}"), schema);
            AssertNone(KeyPaths.Undocumented(r, schemaPaths), "undocumented");
            AssertNone(KeyPaths.Absent(r, schemaPaths), "absent");

            var r2 = KeyPaths.FromReference(Parse(@"{""e1"":{""km"":null},""e2"":{""km"":{}}}"), schema);
            AssertNone(KeyPaths.Absent(r2, schemaPaths), "absent with both instances uncovered");
        }

        [Test, Category("Tier1")]
        public void Compare_ReportsBothDirections()
        {
            var schema = Parse(@"{""properties"":{""a"":{},""b"":{}}}");
            var r = KeyPaths.FromReference(Parse(@"{""a"":1,""c"":2}"), schema);
            var schemaPaths = KeyPaths.FromSchema(schema).Keys;
            CollectionAssert.AreEqual(new[] { "c" }, KeyPaths.Undocumented(r, schemaPaths));
            CollectionAssert.AreEqual(new[] { "b" }, KeyPaths.Absent(r, schemaPaths));
        }

        [Test, Category("Tier1")]
        public void Schema_DocumentsEveryKeyOfTheReference()
        {
            var schema = Load(SchemaPath);
            var r = KeyPaths.FromReference(Load(ReferencePath), schema);
            AssertNone(KeyPaths.Undocumented(r, KeyPaths.FromSchema(schema).Keys),
                "Keys in config_schema_reference.json with no entry in docs/site/method.schema.json");
        }

        [Test, Category("Tier1")]
        public void Schema_DocumentsNoKeyTheModelLacks()
        {
            var schema = Load(SchemaPath);
            var r = KeyPaths.FromReference(Load(ReferencePath), schema);
            AssertNone(KeyPaths.Absent(r, KeyPaths.FromSchema(schema).Keys),
                "Keys documented in docs/site/method.schema.json that config_schema_reference.json does not have");
        }

        [Test, Category("Tier1")]
        public void Schema_EveryDocumentedKeyHasADescription()
        {
            var missing = new List<string>();
            foreach (var kv in KeyPaths.FromSchema(Load(SchemaPath)))
            {
                if (kv.Value == null) continue; // synthetic "*" / "[]" node
                object d;
                if (!kv.Value.TryGetValue("description", out d) || string.IsNullOrWhiteSpace(d as string))
                    missing.Add(kv.Key);
            }
            AssertNone(missing, "Documented keys with no description");
        }
    }
}
```

- [ ] **Step 3: Register both files in the csproj** — after line 92 (`<Compile Include="ConfigSchemaParityTests.cs" />`) add, with the Edit tool (CRLF file):

```xml
    <Compile Include="KeyDocumentationParityTests.cs" />
    <Compile Include="KeyPaths.cs" />
```
Then `grep -n "System.Web.Extensions\|System.Core" FlashIDA/src/Flash.Tests/Flash.Tests.csproj` — both references must already exist (the sibling test uses `JavaScriptSerializer` and LINQ). If either is missing, stop and report.

- [ ] **Step 4: Build the local runner and run it — expect the 5 primitive tests to PASS and the 3 real-file tests to FAIL (schema file not found)**

The runner lives in the job scratchpad and is never committed:

```bash
R="$CLAUDE_JOB_DIR/tmp/keydoc"; mkdir -p "$R"
cat > "$R/LocalRun.cs" <<'EOF'
using System; using System.Linq; using System.Reflection;
static class LocalRun {
  static int Main() {
    var t = typeof(Flash.Tests.KeyDocumentationParityTests); int fail = 0;
    foreach (var m in t.GetMethods().Where(x => x.GetCustomAttributes(typeof(NUnit.Framework.TestAttribute), false).Any())) {
      try { m.Invoke(Activator.CreateInstance(t), null); Console.WriteLine("PASS " + m.Name); }
      catch (TargetInvocationException e) {
        if (e.InnerException is NUnit.Framework.SuccessException) { Console.WriteLine("PASS " + m.Name); continue; }
        fail++; Console.WriteLine("FAIL " + m.Name + "\n    " + e.InnerException.Message.Replace("\n", "\n    "));
      }
    }
    Console.WriteLine(fail == 0 ? "PASS: all" : "FAIL: " + fail + " test(s)"); return fail == 0 ? 0 : 1;
  }
}
EOF
cd /c/FLASHIda/flashida-development/FlashIDA && mkdir -p bin
cp ~/.nuget/packages/nunit/3.13.3/lib/net45/nunit.framework.dll bin/
CSC="/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/Roslyn/csc.exe"
MSYS_NO_PATHCONV=1 "$CSC" /nologo /langversion:7.3 /t:exe /out:bin\\KeyDocLocal.exe \
  /r:bin\\nunit.framework.dll /r:System.Web.Extensions.dll /r:System.Core.dll \
  src\\Flash.Tests\\KeyPaths.cs src\\Flash.Tests\\KeyDocumentationParityTests.cs "$(cygpath -w "$R/LocalRun.cs")"
./bin/KeyDocLocal.exe
```
Expected: `PASS` for the five `FromSchema_*`/`Compare_*` tests; `FAIL` for the three `Schema_*` tests with "File not found: …method.schema.json"; last line `FAIL: 3 test(s)`.
If NUnit's `Assert` itself throws a `NullReferenceException` outside a runner, replace the runner's invoke with `NUnit.Framework.Internal.TestExecutionContext` setup — report it and stop rather than changing the test.

- [ ] **Step 5: Commit**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
git add src/Flash.Tests/KeyPaths.cs src/Flash.Tests/KeyDocumentationParityTests.cs src/Flash.Tests/Flash.Tests.csproj
git commit -m "test(docs): key documentation drift guard -- schema key set equals the model's reference (ADR-0058)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
```
(`bin/` is gitignored; the runner and DLL copies stay out of the commit.)

---

### Task 3: The schema skeleton — every key, typed, layout declared

**Files:**
- Create: `FlashIDA/docs/site/method.schema.json`

**Interfaces:**
- Consumes: the path grammar of Task 2.
- Produces: the schema contract Task 4's renderer reads:
  - root `properties` (13 sections), `$defs.scan` (17 keys), `$defs.exploration` (14 keys incl. `monitor_ms1.*`, `kinetic_model.k2`)
  - `ms_settings.ms1 = {"$ref":"#/$defs/scan","propertyNames":{"enum":[the 12 ms1 keys]}}`; `ms2`, `ms2_quant`, `ms3 = {"$ref":"#/$defs/scan"}`; `additional_ms2 = {"type":"object","additionalProperties":{"$ref":"#/$defs/scan"}}`
  - `precursor_selection.exploration` and `characterization.exploration = {"$ref":"#/$defs/exploration"}`
  - `quantification.channel_normalization`, `exploration.overrides`, `kinetic_model.k2` are scalar maps (`additionalProperties: {type: number|string}`); `quantification.conditions` is an array of `{name, channels}` objects
  - `x-pages`: array of `{ "slug", "title", "subtitle", "sources", "sections": [ { "ref", "heading", "exclude"?: [keys], "adr"?: [..], "exemplars": [ { "config", "label"?, "base"? } ] } ] }`, where `ref` is a dotted root path (`"quantification"`, `"precursor_selection.tag_expansion"`, `"conditional_ms2"`) or `"#/$defs/<name>"`, and `base` is the dotted path inside the config the section's keys are read from (defaults to `ref`; required for `$defs` sections)

**Exemplar table (Q11, confirmed):**

| Page slug | Section ref | Exemplar config(s) (`base` if not the ref) |
|---|---|---|
| `run` | `global`, `runtime`, `scheduling` | `method_default.json` |
| `run` | `files` | `method_tag_targeting.json` |
| `deconvolution` | `deconvolution` | `method_default.json` |
| `precursor-selection` | `precursor_selection` (exclude `tag_expansion`) | `method_cytc_separate_charges.json` |
| `exploration` | `#/$defs/exploration` | `method_exploration_ms3.json` ×2: label "level 2" base `precursor_selection.exploration`; label "level 3" base `characterization.exploration` |
| `characterization` | `characterization` | `method_ms3_cytc_exhaustive.json` |
| `scan-settings` | `#/$defs/scan` | `method_dda_etd.json` ×2: label `ms1` base `ms_settings.ms1`; label `ms2` base `ms_settings.ms2` |
| `ms-settings` | `ms_settings` | `method_default.json` |
| `quantification` | `quantification` | `method_quant.json` |
| `faims` | `faims` | `method_faims_3cv.json` |
| `tagging` | `tagging`, `conditional_ms2`, `precursor_selection.tag_expansion` | `method_tag_targeting.json` |
| `tagging` | `flashtnt` | `method_default.json` |

- [ ] **Step 1: Generate the skeleton from the reference with a scratch script (not committed)**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
cat > "$CLAUDE_JOB_DIR/tmp/scaffold.js" <<'EOF'
// One-off: emits a typed skeleton of method.schema.json from config_schema_reference.json.
// Every description is "" so the strict renderer and Schema_EveryDocumentedKeyHasADescription
// stay red until the prose is authored. Types are a first guess from the reference VALUE and
// must be checked against the C# property type while authoring.
const fs = require('fs');
const ref = JSON.parse(fs.readFileSync('test-data/config_schema_reference.json', 'utf8'));
const leaf = (v) => {
  if (typeof v === 'boolean') return { type: 'boolean' };
  if (typeof v === 'number') return { type: Number.isInteger(v) ? 'integer' : 'number' };
  if (typeof v === 'string') return { type: 'string' };
  if (Array.isArray(v)) return { type: 'array', items: v.length ? leaf(v[0]) : {} };
  return {}; // null: author the type by hand
};
const obj = (o) => {
  const properties = {};
  for (const [k, v] of Object.entries(o)) {
    if (v && typeof v === 'object' && !Array.isArray(v)) properties[k] = obj(v);
    else if (Array.isArray(v) && v.length && typeof v[0] === 'object') properties[k] = { type: 'array', items: obj(v[0]), description: '' };
    else properties[k] = { ...leaf(v), description: '' };
  }
  return { type: 'object', additionalProperties: false, properties, description: '' };
};
const ms = ref.ms_settings;
const scan = obj(Object.assign({}, ms.ms2, ms.ms3, ms.ms2_quant)); delete scan.description;
const ps = ref.precursor_selection, ch = ref.characterization;
const expl = obj(Object.assign({}, ps.exploration, ...Object.entries(ch.exploration).filter(([, v]) => v != null).map(([k, v]) => ({ [k]: v }))));
delete expl.description;
const root = obj(ref);
root.properties.ms_settings.properties = {
  ms1: { $ref: '#/$defs/scan', propertyNames: { enum: Object.keys(ms.ms1) }, description: '' },
  ms2: { $ref: '#/$defs/scan', description: '' },
  ms2_quant: { $ref: '#/$defs/scan', description: '' },
  ms3: { $ref: '#/$defs/scan', description: '' },
  additional_ms2: { type: 'object', additionalProperties: { $ref: '#/$defs/scan' }, description: '' },
};
root.properties.precursor_selection.properties.exploration = { $ref: '#/$defs/exploration', description: '' };
root.properties.characterization.properties.exploration = { $ref: '#/$defs/exploration', description: '' };
root.properties.quantification.properties.channel_normalization = { type: 'object', additionalProperties: { type: 'number' }, description: '' };
expl.properties.overrides = { type: 'object', additionalProperties: { type: 'string' }, description: '' };
expl.properties.kinetic_model = { type: 'object', additionalProperties: false, description: '',
  properties: { k2: { type: 'object', additionalProperties: { type: 'number' }, description: '' } } };
const out = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://t0mdavid-m.github.io/FlashIDA/method.schema.json',
  title: 'FLASHIda method.json',
  description: '',
  ...root,
  $defs: { scan, exploration: expl },
  'x-pages': [],
};
fs.writeFileSync('docs/site/method.schema.json', JSON.stringify(out, null, 2) + '\n');
EOF
mkdir -p docs/site && node "$CLAUDE_JOB_DIR/tmp/scaffold.js"
```

- [ ] **Step 2: Hand-correct what the scaffold cannot know**, reading `src/Flash/MethodConfig.cs`:
  - Every key's `type` from its C# property type (`double` → `number`, `int` → `integer`, `bool` → `boolean`, `string` → `string`, `List<T>`/`T[]` → `array` with `items`, `Dictionary<string,T>` → map).
  - Keys whose reference value is `null` (`exploration.activations` etc.): type from C#.
  - `enum` for every closed string value set the C# or C++ loader checks (`targeting`, `precursor_charges`, `rank_by`, `characterization.mode`, `fragment_charges`, `characterization.method`, `exploration.metric`, `activations` items, `quantification.labelling`/`identify`/`test`/`empty_condition`/`aggregate`, scan `analyzer`/`activation`/`data_type`, …). Only sets the loader actually rejects outside of; an open string stays open.
  - Remove `description` from `$defs.scan`/`$defs.exploration` roots only if the scaffold left one there (the def's own description goes in `x-type-text` usage on ref rows, see Task 4).

- [ ] **Step 3: Write `x-pages`** exactly per the exemplar table above, with page titles: Run, Deconvolution, Precursor selection, Exploration, Characterization, Scan settings, ms_settings, Quantification, FAIMS, Tagging. `subtitle` mirrors the sheet ("JSON keys of `quantification`"). `sources` names the files the page's prose was read from.

- [ ] **Step 4: Run the drift tests — expect the two key-set tests to PASS and the description test to FAIL**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA && ./bin/KeyDocLocal.exe
```
Expected: 7 PASS; `FAIL Schema_EveryDocumentedKeyHasADescription` listing every path; last line `FAIL: 1 test(s)`. Any key-set failure is a skeleton bug: fix the schema and re-run.

- [ ] **Step 5: Validate every committed config with ajv**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false --all-errors --errors=line \
  -s docs/site/method.schema.json -d "test-data/configs/method_*.json" -d src/Flash/etc/method.json
```
Expected: 50 lines `… valid`, exit 0. For each `invalid`: if the schema is wrong (type, enum, a key the C# loader does accept), fix the schema. If the config is wrong, record it for the final report and stop to ask the owner.

- [ ] **Step 6: Commit**

```bash
git add docs/site/method.schema.json
git commit -m "docs(site): method.schema.json skeleton -- every key typed, x-pages layout (ADR-0058)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
```

---

### Task 4: The renderer (Node, TDD)

**Files:**
- Create: `FlashIDA/docs/site/build.js`, `FlashIDA/docs/site/build.test.js`, `FlashIDA/docs/site/style.css`
- Modify: `FlashIDA/.gitignore` (append `docs/site/_site/`)

**Interfaces:**
- Consumes: the `x-pages` contract and keywords of Task 3.
- Produces: `node docs/site/build.js [--draft] [--out <dir>]` → writes `index.html`, `<slug>.html` per page, `print.html`, `style.css`, `method.schema.json` into `<dir>` (default `docs/site/_site`). Exit 0 on success. Strict mode exits 1 listing every key without a description and every layout error. `--draft` renders missing descriptions as a red `MISSING` and prints a per-page count, exit 0.
- Environment: `SITE_DATE`, `SITE_COMMIT`, `SITE_BRANCH` set by the workflow; absent → stamp "working tree".
- Exports (for tests): `typeText`, `defaultText`, `rulesHtml`, `exemplarCell`, `sectionRows`, `applicability`, `build`.

**Test pseudocode (the approved list):**

```
TEST typeText
  {type:integer, x-unit:"Da"}                         → "int, Da"
  {type:number}                                       → "double"
  {type:array, items:{type:string}}                   → "array of string"
  {type:object, additionalProperties:{type:number}}   → "map of name → double"
  {type:boolean, x-type-text:"bool switch"}           → "bool switch"

TEST defaultText
  {default:"tmt6plex"} → "tmt6plex"     {default:0.0} → "0"     {default:false} → "false"
  {} → "none"                            {x-default-text:"required when enabled", default:1} → "required when enabled"

TEST rulesHtml
  enum [a,b] + enumDescriptions ["one.","two."] + description "Then `x`."
      → "<code>a</code>: one. <code>b</code>: two. Then <code>x</code>."
  enum [a,b], no enumDescriptions → starts "One of <code>a</code>, <code>b</code>."
  description "<b>" → escaped "&lt;b&gt;"

TEST exemplarCell
  value undefined, node {default:2}  → "– = 2"
  value undefined, node {}           → "–"
  value {a:1,b:2,c:3}                → "set (3 keys)"
  value array of 40 numbers          → compact JSON truncated to ≤ 80 chars ending "…"
  value "tmt6plex"                   → "tmt6plex"

TEST sectionRows flattens nested objects and links refs
  section node {properties:{cycle_time:{type:object,properties:{enabled:{…},value_ms:{…}}}, ms1:{$ref scan}}}
  → rows keys ["cycle_time","cycle_time.enabled","cycle_time.value_ms","ms1"]; cycle_time is a group row;
    ms1 row has link "scan-settings.html"

TEST applicability column appears only when keys differ by user
  scan def used by ms1 (propertyNames [a]) and ms2 (all): column present; key b → "ms2"
  exploration def used twice with no filter: column absent

TEST strict build fails on a missing description and names it
  fixture schema with one key lacking description → build() throws, message contains the key path
  same with draft:true → no throw, page HTML contains "MISSING"

TEST build writes index, every page, print page
  fixture schema with two pages → out dir has index.html, a.html, b.html, print.html, style.css, method.schema.json
  index.html links both pages; print.html contains both pages' tables

TEST every exemplar config named in the real schema exists      (real file)
```

- [ ] **Step 1: Write `build.test.js`** implementing the pseudocode above with `node:test` + `node:assert/strict`. Fixtures are inline objects; the build tests write into `fs.mkdtempSync(path.join(os.tmpdir(), 'site-'))` and pass `{ schema, configDir, out, draft }` to `build()` so they never read the real tree (except the last test).

```js
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'); const os = require('os'); const path = require('path');
const b = require('./build.js');

const scanDefs = { scan: { type: 'object', additionalProperties: false, properties: {
  a: { type: 'integer', description: 'A.' }, b: { type: 'integer', description: 'B.' } } } };

test('typeText', () => {
  assert.equal(b.typeText({ type: 'integer', 'x-unit': 'Da' }), 'int, Da');
  assert.equal(b.typeText({ type: 'number' }), 'double');
  assert.equal(b.typeText({ type: 'array', items: { type: 'string' } }), 'array of string');
  assert.equal(b.typeText({ type: 'object', additionalProperties: { type: 'number' } }), 'map of name → double');
  assert.equal(b.typeText({ type: 'boolean', 'x-type-text': 'bool switch' }), 'bool switch');
});

test('defaultText', () => {
  assert.equal(b.defaultText({ default: 'tmt6plex' }), 'tmt6plex');
  assert.equal(b.defaultText({ default: 0.0 }), '0');
  assert.equal(b.defaultText({ default: false }), 'false');
  assert.equal(b.defaultText({}), 'none');
  assert.equal(b.defaultText({ 'x-default-text': 'required when enabled', default: 1 }), 'required when enabled');
});

test('rulesHtml', () => {
  assert.equal(b.rulesHtml({ enum: ['a', 'b'], enumDescriptions: ['one.', 'two.'], description: 'Then `x`.' }),
    '<code>a</code>: one. <code>b</code>: two. Then <code>x</code>.');
  assert.match(b.rulesHtml({ enum: ['a', 'b'], description: 'D.' }), /^One of <code>a<\/code>, <code>b<\/code>\./);
  assert.match(b.rulesHtml({ description: '<b>' }), /&lt;b&gt;/);
});

test('exemplarCell', () => {
  assert.equal(b.exemplarCell(undefined, { default: 2 }), '– = 2');
  assert.equal(b.exemplarCell(undefined, {}), '–');
  assert.equal(b.exemplarCell({ a: 1, b: 2, c: 3 }, {}), 'set (3 keys)');
  const long = b.exemplarCell(Array.from({ length: 40 }, (_, i) => i * 1000), {});
  assert.ok(long.length <= 80 && long.endsWith('…'));
  assert.equal(b.exemplarCell('tmt6plex', {}), 'tmt6plex');
});

test('sectionRows flattens nested objects and links refs', () => {
  const schema = { $defs: scanDefs, 'x-pages': [{ slug: 'scan-settings', sections: [{ ref: '#/$defs/scan' }] }] };
  const node = { properties: {
    cycle_time: { type: 'object', description: 'C.', properties: { enabled: { type: 'boolean', description: 'E.' }, value_ms: { type: 'number', description: 'V.' } } },
    ms1: { $ref: '#/$defs/scan', description: 'Survey.' } } };
  const rows = b.sectionRows(node, schema, []);
  assert.deepEqual(rows.map((r) => r.key), ['cycle_time', 'cycle_time.enabled', 'cycle_time.value_ms', 'ms1']);
  assert.ok(rows[0].group);
  assert.equal(rows[3].link, 'scan-settings.html');
});

test('applicability column appears only when keys differ by user', () => {
  const s1 = { $defs: scanDefs, properties: { ms: { type: 'object', properties: {
    ms1: { $ref: '#/$defs/scan', propertyNames: { enum: ['a'] } }, ms2: { $ref: '#/$defs/scan' } } } } };
  const col = b.applicability(s1, 'scan');
  assert.ok(col);
  assert.equal(col.b, 'ms2');
  assert.equal(col.a, 'ms1, ms2');
  const s2 = { $defs: scanDefs, properties: { x: { $ref: '#/$defs/scan' }, y: { $ref: '#/$defs/scan' } } };
  assert.equal(b.applicability(s2, 'scan'), null);
});

function fixture(withMissing) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'site-'));
  const configDir = path.join(dir, 'configs'); fs.mkdirSync(configDir);
  fs.writeFileSync(path.join(configDir, 'c.json'), JSON.stringify({ s1: { k: 3 }, s2: { m: true } }));
  const schema = {
    title: 'T', description: 'Orientation.', type: 'object', additionalProperties: false,
    properties: {
      s1: { type: 'object', additionalProperties: false, properties: { k: { type: 'integer', default: 1, ...(withMissing ? {} : { description: 'K.' }) } } },
      s2: { type: 'object', additionalProperties: false, properties: { m: { type: 'boolean', default: false, description: 'M.' } } } },
    'x-pages': [
      { slug: 'a', title: 'A', subtitle: 'keys of s1', sources: 'x', sections: [{ ref: 's1', exemplars: [{ config: 'c.json' }] }] },
      { slug: 'b', title: 'B', subtitle: 'keys of s2', sources: 'x', sections: [{ ref: 's2', exemplars: [{ config: 'c.json' }] }] }] };
  return { schema, configDir, out: path.join(dir, 'out') };
}

test('strict build fails on a missing description and names it', () => {
  assert.throws(() => b.build({ ...fixture(true), draft: false }), /s1\.k/);
  const f = fixture(true); b.build({ ...f, draft: true });
  assert.match(fs.readFileSync(path.join(f.out, 'a.html'), 'utf8'), /MISSING/);
});

test('build writes index, every page, print page', () => {
  const f = fixture(false); b.build({ ...f, draft: false });
  for (const n of ['index.html', 'a.html', 'b.html', 'print.html', 'style.css', 'method.schema.json'])
    assert.ok(fs.existsSync(path.join(f.out, n)), n);
  const index = fs.readFileSync(path.join(f.out, 'index.html'), 'utf8');
  assert.match(index, /href="a\.html"/); assert.match(index, /href="b\.html"/);
  const print = fs.readFileSync(path.join(f.out, 'print.html'), 'utf8');
  assert.match(print, /<code>k<\/code>/); assert.match(print, /<code>m<\/code>/);
});

test('every exemplar config named in the real schema exists', () => {
  const schema = JSON.parse(fs.readFileSync(path.join(__dirname, 'method.schema.json'), 'utf8'));
  const configDir = path.join(__dirname, '..', '..', 'test-data', 'configs');
  for (const p of schema['x-pages']) for (const s of p.sections) for (const e of s.exemplars || [])
    assert.ok(fs.existsSync(path.join(configDir, e.config)), `${p.slug}: ${e.config}`);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /c/FLASHIda/flashida-development/FlashIDA && node --test docs/site/build.test.js`
Expected: FAIL, `Cannot find module './build.js'`.

- [ ] **Step 3: Write `build.js`**

```js
#!/usr/bin/env node
// Renders the method.json key documentation (ADR-0058) from method.schema.json and the exemplar
// configs. Node built-ins only. Usage: node build.js [--draft] [--out <dir>]
'use strict';
const fs = require('fs');
const path = require('path');

const SITE_DIR = __dirname;
const REPO = path.resolve(SITE_DIR, '..', '..');
const DEF = '#/$defs/';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>');
const get = (obj, dotted) => (dotted ? dotted.split('.') : []).reduce((o, k) => (o == null ? undefined : o[k]), obj);
const defName = (ref) => (ref && ref.startsWith(DEF) ? ref.slice(DEF.length) : null);

const TYPE = { boolean: 'bool', integer: 'int', number: 'double', string: 'string', object: 'object' };
function typeText(n) {
  if (n['x-type-text']) return n['x-type-text'];
  let t;
  if (n.type === 'array') t = 'array of ' + (n.items && n.items.properties ? 'objects' : typeText(n.items || {}));
  else if (n.type === 'object' && n.additionalProperties && typeof n.additionalProperties === 'object' && !n.properties)
    t = 'map of name → ' + typeText(n.additionalProperties);
  else t = TYPE[n.type] || (n.$ref ? 'object' : '?');
  return n['x-unit'] ? t + ', ' + n['x-unit'] : t;
}

const literal = (v) => (typeof v === 'string' ? (v === '' ? '""' : v) : JSON.stringify(v));
function defaultText(n) {
  if (n['x-default-text']) return n['x-default-text'];
  return Object.prototype.hasOwnProperty.call(n, 'default') ? literal(n.default) : 'none';
}

function rulesHtml(n, draft) {
  const parts = [];
  if (Array.isArray(n.enum)) {
    if (Array.isArray(n.enumDescriptions))
      parts.push(n.enum.map((v, i) => `<code>${esc(v)}</code>: ${inline(n.enumDescriptions[i] || '')}`).join(' '));
    else parts.push('One of ' + n.enum.map((v) => `<code>${esc(v)}</code>`).join(', ') + '.');
  }
  if (n.description) parts.push(inline(n.description));
  else if (draft) parts.push('<span class="missing">MISSING</span>');
  if (Array.isArray(n['x-adr']) && n['x-adr'].length) parts.push(`<span class="adr">ADR-${n['x-adr'].join(', ADR-')}</span>`);
  return parts.join(' ');
}

function exemplarCell(value, node) {
  if (value === undefined) return Object.prototype.hasOwnProperty.call(node, 'default') || node['x-default-text']
    ? '– = ' + (node['x-default-text'] ? node['x-default-text'] : literal(node.default)) : '–';
  if (value && typeof value === 'object' && !Array.isArray(value)) return `set (${Object.keys(value).length} keys)`;
  const s = literal(value);
  return s.length > 80 ? s.slice(0, 79) + '…' : s;
}

function pageOfDef(schema, name) {
  for (const p of schema['x-pages'] || []) for (const s of p.sections) if (s.ref === DEF + name) return p.slug + '.html';
  return null;
}

// Rows of one section: nested plain objects flatten to dotted keys; a $ref or a map of objects is
// one linking row; an array of objects is a row plus one row per item key ("conditions[].name").
function sectionRows(node, schema, exclude, prefix = '', admitted = null) {
  const rows = [];
  for (const [k, n] of Object.entries(node.properties || {})) {
    if (!prefix && exclude.includes(k)) continue;
    if (admitted && !admitted.includes(k)) continue;
    const key = prefix ? prefix + '.' + k : k;
    const target = defName(n.$ref) || (n.additionalProperties && defName(n.additionalProperties.$ref));
    if (target) { rows.push({ key, node: n, link: pageOfDef(schema, target) }); continue; }
    if (n.type === 'object' && n.properties) {
      rows.push({ key, node: n, group: true });   // every key node is documented, as the C# test requires
      rows.push(...sectionRows(n, schema, [], key));
      continue;
    }
    rows.push({ key, node: n });
    if (n.type === 'array' && n.items && n.items.properties) rows.push(...sectionRows(n.items, schema, [], key + '[]'));
  }
  return rows;
}

// For a $def page: key → "ms1, ms2, …" naming the users that admit it, or null when every user
// admits every key (the column would say nothing).
function applicability(schema, name) {
  const users = [];
  const walk = (node, p) => {
    if (!node || typeof node !== 'object') return;
    if (node.$ref === DEF + name) users.push({ label: p.split('.').pop(), admitted: node.propertyNames && node.propertyNames.enum });
    if (node.additionalProperties && node.additionalProperties.$ref === DEF + name) users.push({ label: p.split('.').pop() + '.*', admitted: null });
    for (const [k, v] of Object.entries(node.properties || {})) walk(v, p ? p + '.' + k : k);
  };
  walk(schema, '');
  if (!users.some((u) => u.admitted)) return null;
  const col = {};
  for (const k of Object.keys(schema.$defs[name].properties))
    col[k] = users.filter((u) => !u.admitted || u.admitted.includes(k)).map((u) => u.label).join(', ');
  return col;
}

function sectionNode(schema, ref) {
  const d = defName(ref);
  if (d) return schema.$defs[d];
  const parts = ref.split('.');
  let n = schema;
  for (const p of parts) n = n && n.properties && n.properties[p];
  if (!n) throw new Error(`x-pages: section ref "${ref}" does not resolve`);
  return n;
}

function renderSection(schema, s, ctx) {
  const node = sectionNode(schema, s.ref);
  const isLeaf = !node.properties;
  const rows = isLeaf ? [{ key: s.ref.split('.').pop(), node, leaf: true }] : sectionRows(node, schema, s.exclude || []);
  const exemplars = (s.exemplars || []).map((e) => {
    const file = path.join(ctx.configDir, e.config);
    if (!fs.existsSync(file)) throw new Error(`x-pages: exemplar ${e.config} not found`);
    return { label: e.label || e.config, config: JSON.parse(fs.readFileSync(file, 'utf8')), base: e.base !== undefined ? e.base : (defName(s.ref) ? null : s.ref) };
  });
  for (const e of exemplars) if (e.base === null) throw new Error(`x-pages: ${s.ref} exemplar ${e.label} needs a base`);
  const appl = defName(s.ref) ? applicability(schema, defName(s.ref)) : null;
  const head = ['key', 'type', 'default', 'values and rules'].concat(appl ? ['used by'] : [], exemplars.map((e) => e.label));
  const where = defName(s.ref) ? '$defs.' + defName(s.ref) : s.ref;
  if (!isLeaf && !defName(s.ref) && !node.description) ctx.missing.push(`${ctx.slug}: ${where}`);
  const body = rows.map((r) => {
    if (!r.node.description) ctx.missing.push(`${ctx.slug}: ${r.leaf ? where : where + '.' + r.key}`);
    const more = r.link ? ` See <a href="${r.link}">${esc(path.basename(r.link, '.html').replace('-', ' '))}</a>.` : '';
    const cells = [
      `<td class="key"><code>${esc(r.key)}</code></td>`,
      `<td>${esc(typeText(r.node))}</td>`,
      `<td>${inline(defaultText(r.node))}</td>`,
      `<td>${rulesHtml(r.node, ctx.draft)}${more}</td>`]
      .concat(appl ? [`<td>${esc(appl[r.key.split('.')[0]] || '')}</td>`] : [])
      .concat(exemplars.map((e) => {
        if (r.group || r.key.includes('[]')) return '<td></td>';
        const v = r.leaf ? get(e.config, e.base) : get(e.config, e.base ? e.base + '.' + r.key : r.key);
        return `<td class="ex"><code>${esc(exemplarCell(v, r.node))}</code></td>`;
      }));
    return `<tr${r.group ? ' class="group"' : ''}>${cells.join('')}</tr>`;
  });
  const adr = s.adr && s.adr.length ? ` <span class="adr">ADR-${s.adr.join(', ADR-')}</span>` : '';
  const intro = !isLeaf && node.description ? `<p class="intro">${inline(node.description)}</p>` : '';
  return `<h2><code>${esc(s.heading || s.ref.replace(DEF, ''))}</code>${adr}</h2>${intro}
<div class="wrap"><table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
<tbody>${body.join('\n')}</tbody></table></div>`;
}

function stamp() {
  const { SITE_DATE, SITE_COMMIT, SITE_BRANCH } = process.env;
  const state = SITE_COMMIT ? `Engine state of ${SITE_DATE}, commit ${SITE_COMMIT.slice(0, 10)} on ${SITE_BRANCH}.` : 'Working tree, uncommitted.';
  return `${state} Last column(s): the value in the named config under <code>FlashIDA/test-data/configs</code>; – means the key is absent there and the default applies.`;
}

function shell(title, nav, main) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title><link rel="stylesheet" href="style.css"></head>
<body>${nav}<main>${main}</main></body></html>
`;
}

function build({ schema, configDir, out, draft }) {
  const pages = schema['x-pages'] || [];
  if (!pages.length) throw new Error('x-pages is empty');
  const missing = [];
  fs.mkdirSync(out, { recursive: true });
  const nav = `<nav><a href="index.html">FLASHIda method.json keys</a>${pages.map((p) => ` · <a href="${p.slug}.html">${esc(p.title)}</a>`).join('')} · <a href="print.html">print</a></nav>`;
  const bodies = pages.map((p) => {
    const ctx = { configDir, draft, missing, slug: p.slug };
    const sections = p.sections.map((s) => renderSection(schema, s, ctx)).join('\n');
    return `<h1>FLASHIda ${esc(p.title.toLowerCase())} <span class="sub">${inline(p.subtitle || '')}</span></h1>
<p class="stamp">${stamp()}</p>
${sections}
<p class="source">Read from ${inline(p.sources || '')}.</p>`;
  });
  if (missing.length && !draft) throw new Error('Keys without a description:\n  ' + missing.join('\n  '));
  pages.forEach((p, i) => fs.writeFileSync(path.join(out, p.slug + '.html'), shell(`FLASHIda keys: ${p.title}`, nav, bodies[i])));
  const index = `<h1>${esc(schema.title || 'FLASHIda method.json')} <span class="sub">every key, by section</span></h1>
<p class="stamp">${stamp()}</p><p>${inline(schema.description || '')}</p>
<ul class="pages">${pages.map((p) => `<li><a href="${p.slug}.html">${esc(p.title)}</a>: ${inline(p.subtitle || '')}</li>`).join('')}</ul>
<p>The schema itself: <a href="method.schema.json">method.schema.json</a>. One document for printing: <a href="print.html">print</a>.</p>`;
  fs.writeFileSync(path.join(out, 'index.html'), shell('FLASHIda method.json keys', nav, index));
  fs.writeFileSync(path.join(out, 'print.html'), shell('FLASHIda method.json keys (print)', '', bodies.map((b) => `<section class="page">${b}</section>`).join('\n')));
  fs.copyFileSync(path.join(SITE_DIR, 'style.css'), path.join(out, 'style.css'));
  fs.writeFileSync(path.join(out, 'method.schema.json'), JSON.stringify(schema, null, 2) + '\n');
  return { missing };
}

module.exports = { typeText, defaultText, rulesHtml, exemplarCell, sectionRows, applicability, build };

if (require.main === module) {
  const args = process.argv.slice(2);
  const draft = args.includes('--draft');
  const oi = args.indexOf('--out');
  const out = oi >= 0 ? path.resolve(args[oi + 1]) : path.join(SITE_DIR, '_site');
  try {
    const schema = JSON.parse(fs.readFileSync(path.join(SITE_DIR, 'method.schema.json'), 'utf8'));
    const { missing } = build({ schema, configDir: path.join(REPO, 'test-data', 'configs'), out, draft });
    if (draft) {
      const per = {};
      for (const m of missing) { const s = m.split(':')[0]; per[s] = (per[s] || 0) + 1; }
      for (const [s, n] of Object.entries(per)) console.log(`missing descriptions: ${s}: ${n}`);
    }
    console.log(`PASS: rendered to ${out}`);
  } catch (e) {
    console.error(e.message);
    console.log('FAIL: ' + e.message.split('\n')[0]);
    process.exit(1);
  }
}
```

- [ ] **Step 4: Write `style.css`** — the sheet's look:

```css
:root { --ink: #111; --rule: #8c8c8c; --head: #ebebeb; --link: #1a4f9c; --miss: #b00020; }
* { box-sizing: border-box; }
body { margin: 0; background: #fff; color: var(--ink);
  font: 15px/1.45 Georgia, "Times New Roman", serif; }
nav { padding: 8px 16px; border-bottom: 1px solid #ddd; font-size: 13px; }
nav a, a { color: var(--link); text-decoration: none; }
main { max-width: 1180px; margin: 0 auto; padding: 16px; }
h1 { font-size: 22px; margin: 8px 0 2px; }
h1 .sub { font-weight: normal; font-size: 15px; margin-left: 12px; }
h2 { font-size: 16px; margin: 22px 0 4px; }
.stamp, .source { color: var(--rule); font-size: 13px; margin: 2px 0 8px; }
.intro { margin: 2px 0 6px; }
code { font-family: ui-monospace, "Cascadia Mono", Consolas, "Courier New", monospace; font-size: 0.88em; }
.wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th { background: var(--head); text-align: left; font-weight: bold; padding: 4px 6px; }
td { vertical-align: top; padding: 4px 6px; border-bottom: 1px solid #eee; }
td.key { white-space: nowrap; }
th:nth-child(1) { width: 17%; } th:nth-child(2) { width: 11%; } th:nth-child(3) { width: 10%; }
td.ex { width: 15%; }
tr.group td { font-style: italic; border-bottom: none; }
.adr { color: var(--rule); font-size: 0.85em; }
.missing { color: var(--miss); font-weight: bold; }
ul.pages li { margin: 3px 0; }
@media print {
  @page { size: A4; margin: 1.3cm 1.4cm; }
  body { font-size: 9pt; } nav { display: none; } main { max-width: none; padding: 0; }
  table { font-size: 8.5pt; } .wrap { overflow: visible; }
  section.page + section.page { break-before: page; }
  tr { break-inside: avoid; }
}
```

- [ ] **Step 5: Ignore the output dir** — append to `FlashIDA/.gitignore` with the Edit tool:

```
# Rendered key documentation site (built by docs/site/build.js)
docs/site/_site/
```

- [ ] **Step 6: Run the tests, then a draft render**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
node --test docs/site/build.test.js
node docs/site/build.js --draft
```
Expected: `# pass 9`, `# fail 0`; the draft render prints `missing descriptions: <slug>: n` for every page and `PASS: rendered to …/_site`. Open `docs/site/_site/index.html` and one page in a browser to check the layout reads like the sheet.

- [ ] **Step 7: Commit**

```bash
git add docs/site/build.js docs/site/build.test.js docs/site/style.css .gitignore
git commit -m "docs(site): renderer -- schema + exemplar configs to static pages, strict and draft modes (ADR-0058)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
```

---

### Tasks 5–9: Author the prose, one page group per task

Each of these tasks has the same shape. Only the keys and sources differ.

**Per-key procedure (applies to every key in Tasks 5–9):**
1. Read the C# property in `FlashIDA/src/Flash/MethodConfig.cs`: type, initializer (C# default), `[Description]` text (seed only; it is sometimes stale).
2. Read how `MethodParameters.ToCppJson` emits it (renames, inheritance such as ADR-0011's source-region resolution, omit-when-default).
3. Read `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp`: the C++ default when the key is omitted, and the validation.
4. Read the consuming engine site (grep the C++ member) to say what the key **does**.
5. Read the cited ADR.
6. Write: `type` (+ `x-unit`), `default` or `x-default-text`, `enum` + `enumDescriptions` where closed, `description` (decision sections: 1–4 sentences, sheet register: facts, interactions, "Author it" where omitted ≠ literal; scan keys: one line), `x-adr` where an ADR governs the key.
7. Any engine/docs disagreement → a line in `$CLAUDE_JOB_DIR/tmp/disagreements.md`, reported at the end.

**Per-task acceptance:**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
node docs/site/build.js --draft | grep -E "missing descriptions: (<this task's slugs>)"   # expect no output
npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false --all-errors --errors=line -s docs/site/method.schema.json -d "test-data/configs/method_*.json" -d src/Flash/etc/method.json   # 50 valid
./bin/KeyDocLocal.exe   # key-set tests still PASS
```
Then commit `docs/site/method.schema.json` alone: `docs(site): <pages> keys documented (ADR-0058)` with the attribution lines.

| Task | Pages (slugs) | Keys | Primary sources beyond the per-key procedure |
|---|---|---|---|
| 5 | `run`, `deconvolution` | `global.*` (3), `files.*` (4), `runtime.log_dir`, `scheduling.*` (6), `deconvolution.*` (7); root `description` (index orientation paragraph) | ADR-0031, 0032, 0033, 0041, 0043; `LogPathResolver.cs`; README run-folder section |
| 6 | `precursor-selection`, `tagging` | `precursor_selection.*` minus exploration (13 + `tag_expansion.*` 2), `tagging.follow_up_scan`, `conditional_ms2`, `flashtnt.*` (7) | ADR-0014, 0016, 0021, 0028, 0036, 0040; `PrecursorSelection.cpp`; CLAUDE.md targeting-mode notes (in_depth is a soft reorder) |
| 7 | `exploration`, `characterization` | `$defs.exploration.*` (14 incl. `monitor_ms1.*`, `kinetic_model.k2`), `characterization.*` incl. `refine.*` (7) | ADR-0013, 0020, 0023, 0026, 0029, 0030, 0042, 0044, 0045, 0047–0049, 0052–0055; `Exploration.cpp`; `docs/kb/exploration/` |
| 8 | `scan-settings`, `ms-settings` | `$defs.scan.*` (17, one line each), `ms_settings.{ms1,ms2,ms2_quant,ms3,additional_ms2}` (roster rows) | ADR-0009, 0010, 0011, 0015/0014 (named scan configs), 0029, 0030, 0045; `ScanFactory.cs`; CONTEXT.md "Scan config name" |
| 9 | `quantification`, `faims` | `quantification.*` (16 incl. `conditions[].*`, `channel_normalization`), `faims.*` (3) | the reference sheet `.tex` (start from its text; update for ADR-0040, 0056, 0057), ADR-0012, 0038, 0039; `Quantification.cpp`, `FAIMS.cpp` |

After Task 9:

- [ ] **Strict render and the full drift guard go green**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
node --test docs/site/build.test.js && node docs/site/build.js && ./bin/KeyDocLocal.exe
```
Expected: tests pass; `PASS: rendered to …`; `PASS: all` (8 of 8).

---

### Task 10: The Pages workflow and enabling Pages on the fork

**Files:**
- Create: `FlashIDA/.github/workflows/pages.yml`

**Interfaces:** Consumes `build.js` CLI and env contract (Task 4), the ajv command (Global Constraints).

- [ ] **Step 1: Write the workflow**

```yaml
# Key documentation site (ADR-0058): checks the committed configs against the schema, renders it,
# and deploys to GitHub Pages. Exactly one branch deploys.
name: Key documentation site
on:
  push:
    branches: [phase-containers]
    paths:
      - 'docs/site/**'
      - 'test-data/configs/**'
      - 'src/Flash/etc/method.json'
      - '.github/workflows/pages.yml'
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: true
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - name: Renderer tests
        run: node --test docs/site/build.test.js
      - name: Committed configs obey the schema
        run: >-
          npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false --all-errors --errors=line
          -s docs/site/method.schema.json -d "test-data/configs/method_*.json" -d src/Flash/etc/method.json
      - name: Render
        env:
          SITE_COMMIT: ${{ github.sha }}
          SITE_BRANCH: ${{ github.ref_name }}
        run: SITE_DATE="$(git log -1 --format=%cs)" node docs/site/build.js
      - uses: actions/upload-pages-artifact@v3
        with:
          path: docs/site/_site
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 2: Rehearse the workflow's three checks locally, in its order**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
node --test docs/site/build.test.js \
 && npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false --all-errors --errors=line -s docs/site/method.schema.json -d "test-data/configs/method_*.json" -d src/Flash/etc/method.json \
 && SITE_DATE=$(git log -1 --format=%cs) SITE_COMMIT=$(git rev-parse HEAD) SITE_BRANCH=phase-containers node docs/site/build.js
```
Expected: all three succeed. Look at `docs/site/_site/index.html`, `quantification.html`, `scan-settings.html` and `print.html` (print preview) in a browser. This is the "first render looks right" gate of Q13.

- [ ] **Step 3: Enable Pages with the Actions source and allow `phase-containers` to deploy**

```bash
gh api -X POST repos/t0mdavid-m/FlashIDA/pages -f build_type=workflow
gh api -X PUT repos/t0mdavid-m/FlashIDA/environments/github-pages \
  -F "deployment_branch_policy[protected_branches]=false" -F "deployment_branch_policy[custom_branch_policies]=true"
gh api -X POST repos/t0mdavid-m/FlashIDA/environments/github-pages/deployment-branch-policies -f name=phase-containers
gh api repos/t0mdavid-m/FlashIDA/pages --jq '.build_type, .html_url'
gh api repos/t0mdavid-m/FlashIDA/environments/github-pages/deployment-branch-policies --jq '.branch_policies[].name'
```
Expected: `workflow`, `https://t0mdavid-m.github.io/FlashIDA/`, and the policy list contains exactly `phase-containers` (plus `main` only if GitHub added it; leave it).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pages.yml
git commit -m "ci(pages): deploy the key documentation site from phase-containers (ADR-0058)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
```

---

### Task 11: Documentation of the new rule and the site

**Files:**
- Modify: `FlashIDA/README.md` (line 10 + a link line), `FlashIDA/CLAUDE.md` (near line 379)
- Modify (parent): `CLAUDE.md` (Testing section "Adding a schema key means **three** sites" → four; Docs Map bullet), `docs/kb/config-flow/adding-a-config-field.md` (new step after step 7 in Scenario 1 and in step 6 of Scenario 3), `docs/adr/0058-…md` (status → implemented, with the date)

- [ ] **Step 1: FlashIDA README** — replace line 10's "XML-formatted method file" sentence with: "The acquisition parameters are specified in a JSON method file (`method.json`); every key is documented at https://t0mdavid-m.github.io/FlashIDA/ and an example is provided with the tool." Leave the stale `-m` help text alone (it is program output, not prose; report it).

- [ ] **Step 2: FlashIDA/CLAUDE.md** — after the sentence at ~line 379 about `config_schema_reference.json`, add: "Every key is also documented by hand in `docs/site/method.schema.json` (ADR-0058), which renders the public site. `KeyDocumentationParityTests` fails if a key is in the model but not documented, documented but not in the model, or documented without a description."

- [ ] **Step 3: Parent CLAUDE.md** — in the Testing section change "Adding a schema key means **three** sites plus the file: the model, `ToCppJson`, **and `BuildFullReferenceConfig`** …" to **four** sites, appending: "**and its entry in `FlashIDA/docs/site/method.schema.json`** (ADR-0058) — type, default and a description, or `KeyDocumentationParityTests` fails." In the hooks table, the `config-schema-drift-reminder.sh` row's effect becomes "Advisory: flags edits that move log output, drive sites, the config schema **or the key documentation**; the config reminder's step (4) is 'document the key'". In the Docs Map add: "- `FlashIDA/docs/site/` — the public key documentation, https://t0mdavid-m.github.io/FlashIDA/ (ADR-0058): a hand-written JSON Schema rendered by `build.js`, deployed by the fork's `pages.yml` from `phase-containers` only."

- [ ] **Step 4: KB** — in `adding-a-config-field.md` add step "7b. **Key documentation.** Add the key to `FlashIDA/docs/site/method.schema.json` with `type`, `default` and `description` (ADR-0058). `KeyDocumentationParityTests` fails otherwise." Bump `last_verified` to the execution date and add `FlashIDA/docs/site/method.schema.json` to `code_anchors`.

- [ ] **Step 5: ADR-0058 status** → `Accepted (grilled 2026-10-11), implemented <date>.`

- [ ] **Step 6: Commit** — FlashIDA: README + CLAUDE.md in one docs commit. Parent: CLAUDE.md + KB + ADR in one docs commit (stage exact paths only).

---

### Task 11b: Every config-change checklist and hook gains the documentation step

**TL;DR**
- Today an agent changing a key is told, by a hook and five written checklists, to touch the model, the emitter, the reference generator and the C++ reader. None of them says "document it".
- After this task each of them names `method.schema.json` as the fourth site, and the hook also fires when the schema itself is edited.

```
before:  edit MethodConfig.cs ──hook──▶ "(1) C# model+emit+reference (2) C++ read+allowlist (3) regenerate"
after:   edit MethodConfig.cs ──hook──▶ "... (3) regenerate (4) document it in docs/site/method.schema.json"
         edit method.schema.json ──hook──▶ "hand-written docs: key set = reference; run the three checks"
```

**Files:**
- Modify (parent): `.claude/hooks/config-schema-drift-reminder.sh`, `.claude/skills/validate-flashida-config/SKILL.md`, `docs/kb/config-flow/config-flow.md` (~line 178), `docs/kb/config-flow/README.md` (~line 58), `docs/superpowers/plans/2026-10-11-kinetic-model-energy-choice.md` (its docs task), `docs/superpowers/plans/2026-10-11-refine-annotation-method.md` (its docs task, ~line 593), `docs/superpowers/specs/2026-08-09-flashtnt-param-plumbing-design.md` (file table, ~line 140)
- Modify (FlashIDA): `src/Flash.Tests/ConfigSchemaParityTests.cs` (class docstring lines 11–22, comment only)
- Not touched, with reason: `docs/superpowers/plans/2026-06-24-characterization-proteoform-tracker.md` (superseded by ADR-0013; its keys no longer exist); `docs/superpowers/specs/2026-08-13-recovery-characterization-mode.md` (another session's untracked draft; it adds no key); `settings.json` (the matcher `Edit|Write` already covers the schema file).

- [ ] **Step 1: The hook.** Replace `config-schema-drift-reminder.sh` with the version below (Write tool; the file is LF per the root `.gitattributes`). Changes: step (4) in the existing message; a second `case` arm for the schema file; the header comment names the new guard.

```bash
#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when a file that defines or reads the unified FLASHIda config
# schema is about to be modified, inject a reminder to keep the C# model/emitter, the C++ reader
# and the key documentation in lockstep. The single snake_case bridge schema is guarded by: the
# self-generated reference FlashIDA/test-data/config_schema_reference.json (Reference_IsNeverStale),
# the C# strict loader (rejects unknown keys), the C++ Config reader (rejects unknown keys +
# read-proof vs on-disk), and the hand-written key documentation
# FlashIDA/docs/site/method.schema.json (KeyDocumentationParityTests, ADR-0058).
# Adding/renaming/moving/removing a key on one side without the others turns CI red.
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for schema paths.

input=$(cat)

path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)

case "$path" in
  *FLASHIda/Config.cpp|*FLASHIda/Config.h|*MethodConfig.cs|*MethodParameters.cs|*MethodConfigSerializer.cs)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda config-schema drift guard: this file defines or reads the ONE unified snake_case bridge config schema. Keys are case-sensitive; unknown keys are HARD-REJECTED on both sides. If this edit ADDS/RENAMES/MOVES/REMOVES a config key you MUST: (1) update the C# model (MethodConfig.cs) + ToCppJson emission (MethodParameters.cs) + BuildFullReferenceConfig, and add the key to the C# strict-loader allowlist path it lives in; (2) update the C++ read in Config.cpp AND its rejectUnknownKeys allowlist for that object; (3) regenerate the committed reference by running the C# suite with REGEN_CONFIG_REFERENCE=1 (Reference_IsNeverStale then re-passes; the C++ EveryKey_ParsesToOnDiskValue read-proof + both UnknownKey_Throws tests cover it); (4) document the key in FlashIDA/docs/site/method.schema.json -- type, default, enum, description (ADR-0058) -- or KeyDocumentationParityTests fails. If the edit changes what an EXISTING key does, its default, or its allowed values, step (4) still applies: update that key's description/default/enum, because no test can see stale prose. A scan-config (ms_settings) key must be a [JsonKey] on the MS1/MS2/MS3Parameters struct field. Miss one side and CI goes red."}}
EOF
    ;;
  *docs/site/method.schema.json)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda key documentation (ADR-0058): method.schema.json is HAND-WRITTEN documentation that no loader reads. Its key set must equal FlashIDA/test-data/config_schema_reference.json and every key needs a description (KeyDocumentationParityTests); every committed config must validate against it (ajv step of FlashIDA/.github/workflows/pages.yml). Prose is read from MethodConfig.cs, MethodParameters.ToCppJson, Config.cpp and the consuming engine site, never from memory. Before pushing: node --test docs/site/build.test.js; the ajv command in pages.yml; node docs/site/build.js. A push to phase-containers republishes https://t0mdavid-m.github.io/FlashIDA/."}}
EOF
    ;;
esac

exit 0
```

- [ ] **Step 2: Prove the hook fires on both arms and stays silent elsewhere**

```bash
cd /c/FLASHIda/flashida-development
for p in 'C:/x/FlashIDA/src/Flash/MethodConfig.cs' 'C:/x/FlashIDA/docs/site/method.schema.json' 'C:/x/README.md'; do
  printf '{"tool_input":{"file_path":"%s"}}' "$p" | bash .claude/hooks/config-schema-drift-reminder.sh | head -c 160; echo " <- $p"
done
```
Expected: the first line contains `(1) update the C# model`, the second `HAND-WRITTEN documentation`, the third prints nothing before the arrow.

- [ ] **Step 3: The validator skill** — in `SKILL.md`'s `## Maintenance`, after the paragraph ending "…promote that file.", add: "A key change also moves the key documentation: `FlashIDA/docs/site/method.schema.json` must gain, lose or re-describe the key in the same change (ADR-0058, `KeyDocumentationParityTests`). If a check in this script encodes a rule about a key, the key's description on the site should state the same rule."

- [ ] **Step 4: KB drift-guard lists** — in `config-flow.md` (~178) and `README.md` (~58), where the guards are listed, add one bullet each: "`KeyDocumentationParityTests` (C#) holds the hand-written key documentation `FlashIDA/docs/site/method.schema.json` to the reference's key set and requires a description per key; the fork's Pages workflow validates every committed config against it with ajv (ADR-0058)." Bump `last_verified` on both.

- [ ] **Step 5: The parity-test docstring (comment only)** — in `ConfigSchemaParityTests.cs`, change the sentence "To intentionally change the schema: update the model + ToCppJson + BuildFullReferenceConfig, then regenerate the committed file by running this suite with REGEN_CONFIG_REFERENCE=1." to "To intentionally change the schema: update the model + ToCppJson + BuildFullReferenceConfig + the key's entry in docs/site/method.schema.json (KeyDocumentationParityTests, ADR-0058), then regenerate the committed file by running this suite with REGEN_CONFIG_REFERENCE=1." Use the Edit tool (CRLF file). Verify with `git -C FlashIDA diff --stat` that only comment lines moved.

- [ ] **Step 6: The open plans and spec** — `git pull --rebase` first (another session may be executing them). Then add exactly one unchecked line to each, in its documentation task, never elsewhere:
  - Kinetic Model plan, in its final docs task: `- [ ] Key documentation: update FlashIDA/docs/site/method.schema.json for every key this plan changed in meaning or allowed values (exploration.metric's kinetic_model value, kinetic_model.k2, remaining_precursor_target's new reading; ADR-0058) and confirm the Pages run republished.`
  - Refine plan, beside the docs line at ~593: `- [ ] Key documentation: update FlashIDA/docs/site/method.schema.json for characterization.method, characterization.refine.* and mode: discriminating (ADR-0058); confirm the Pages run republished.`
  - FLASHTnT plumbing spec, file table (~140): row `| FlashIDA/docs/site/method.schema.json | 1 | **Document** the changed tag_expansion keys (ADR-0058) |`.

- [ ] **Step 7: Commit** — parent: hook + skill + KB in one commit `docs(config): every config-change checklist names the key documentation (ADR-0058)`; the two plans + spec in a second commit `docs(plans): open config-changing plans gain the key documentation step`. FlashIDA: the docstring edit in its own commit `docs(test): ConfigSchemaParityTests names the fourth site (ADR-0058)`. All with the attribution lines; stage exact paths only.

---

### Task 12: Push, publish, watch

- [ ] **Step 1: Final local gate**

```bash
cd /c/FLASHIda/flashida-development/FlashIDA
node --test docs/site/build.test.js && node docs/site/build.js && ./bin/KeyDocLocal.exe
rm -f bin/KeyDocLocal.exe bin/nunit.framework.dll
git status --short   # expect clean
```

- [ ] **Step 2: Push FlashIDA (this publishes)**

```bash
git -C /c/FLASHIda/flashida-development/FlashIDA pull --rebase
git -C /c/FLASHIda/flashida-development/FlashIDA push origin phase-containers
```

- [ ] **Step 3: Watch the Pages run (≈ 1–2 min), then check the live site**

```bash
gh run list -R t0mdavid-m/FlashIDA --workflow pages.yml --limit 1
# re-run the line above at >= 60 s intervals until completed; on failure: gh run view <id> -R t0mdavid-m/FlashIDA --log-failed
curl -sf https://t0mdavid-m.github.io/FlashIDA/ | grep -o "<title>[^<]*"
curl -sf https://t0mdavid-m.github.io/FlashIDA/quantification.html | grep -c "<tr"
curl -sf https://t0mdavid-m.github.io/FlashIDA/method.schema.json | head -c 120
```
Expected: run `success`; title "FLASHIda method.json keys"; the quantification page has its rows; the schema is served.

- [ ] **Step 4: Bump the gitlink in the parent and push (runs the C# test in the real suite)**

```bash
cd /c/FLASHIda/flashida-development
git pull --rebase
git add FlashIDA
git commit -m "chore: gitlink -- FlashIDA <sha> (key documentation site, ADR-0058)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014e864F71YZZhVEEirLAYeH"
git push origin phase-containers
```

- [ ] **Step 5: Watch the parent CI run** — `gh run list --branch phase-containers --limit 1` at ≥ 60 s intervals (≈ 1 h). Expected: green; NUnit total up by exactly 8 against the previous green run, all 8 `KeyDocumentationParityTests` passed. If the description or key-set test fails in CI but passed locally, compare the CI checkout's schema against the pushed SHA before touching anything.

- [ ] **Step 6: Memory + report** — write a project memory (site URL, deploy branch, the fourth-site rule, the local runner recipe), add its index line, and report: the URL, the commits, the disagreements file contents, and the owner's next step (review the live site).

---

## Verification (end to end)

| What | How | Pass |
|---|---|---|
| Walkers correct | `bin/KeyDocLocal.exe` (Task 2) | 5 primitive tests pass |
| Schema covers the model exactly, every key described | `bin/KeyDocLocal.exe` after Task 9 | `PASS: all` (8/8) |
| Docs agree with every committed config | ajv command | 50 × `valid` |
| Renderer | `node --test docs/site/build.test.js` | 9 pass, 0 fail |
| Site renders strictly | `node docs/site/build.js` | `PASS: rendered to …` |
| Published | Pages run + `curl` checks (Task 12 Step 3) | run success, pages served |
| C# test in the real suite | parent CI run | green, NUnit +8 |

## Execution

Recommended: **Native** (superpowers:executing-plans) — the tasks share one schema file and one
path grammar end to end, most of the volume is prose read from the code (Tasks 5–9), and a shipped
mistake costs a fix-forward push to a docs page, not a broken acquisition. One fresh reviewer on the
whole branch at the end.

# FLASHTnT parameter plumbing — design

**Status:** approved 2026-08-09, not implemented
**Scope:** one push, several commits

---

## TL;DR

Three `flashtnt` keys don't do what their section name promises. Two of them were never
FLASHTnT's — they belong to a FLASHIda feature — so they move to where that feature lives. The
third genuinely is FLASHTnT's, and FLASHIda currently sets it only when it happens to be non-empty;
that condition goes away, so the value is always flowing.

**Nothing changes behaviour today.** The point is the day FLASHTnT is repaired: `fixed_mod` will
already be arriving, with no second FLASHIda edit to remember.

```
BEFORE                                       AFTER
flashtnt:                                    flashtnt:                    ← now honestly
  min_length, max_length,        ─┐            min_length, max_length,      "FLASHTnT Params"
  allow_gap, max_aa_in_gap,       │            allow_gap, max_aa_in_gap,
  fixed_mod,                      │            fixed_mod,
  max_blind_mod_count,            │            max_blind_mod_count,
  max_mod_mass,                   │            max_mod_mass
  max_ptm_count,           ───────┼──┐
  max_flanking_mass_diff   ───────┘  │       precursor_selection:
                                     └────►    tag_expansion:            ← where the feature is
                                                 max_ptm_count
                                                 max_flanking_mass_diff

FragmentAnalysis  ─┐                         FragmentAnalysis  ─┐
  (6 tagger Params) │  duplicated               ├─► buildTaggerParam ─┤  one definition
PrecursorSelection ─┘                        PrecursorSelection ─┘
  (same 6 Params)                              + buildExtenderParam
  each with: if (!fixed_mod.empty())            fixed_mod set unconditionally
```

## Why

An end-to-end audit of every config key found these three reach the bridge, get parsed, and then
change nothing on the path a `characterization.protein_sequence` method actually runs:

| Key | What is actually true |
|---|---|
| `max_ptm_count` | Read **only** by `PrecursorSelection::generatePTMCombinations_` — FLASHIda's own code. FLASHTnT has no such Param. Needs `files.fasta` **and** `files.ptm_list`; no committed config sets `ptm_list`, so it has zero live read sites today. |
| `max_flanking_mass_diff` | Not a Param either — a **call argument** to the static `FLASHTaggerAlgorithm::fillMatchedPositionsAndFlankingMassDiffs`. FLASHIda already passes it at its own call site (`PrecursorSelection.cpp:979`). The extender's own call (`FLASHExtenderAlgorithm.cpp:968`) supplies `max_mod_mass_ * max_blind_mod_cntr_ + 1` instead — a different caller, not a dropped parameter. |
| `fixed_mod` | A real Param on both algorithms, already set by FLASHIda — but `FLASHTaggerAlgorithm` declares it and never reads it, and `FLASHExtenderAlgorithm.cpp:71` reads it into a local that is never used. The break is **inside off-limits code**. |

So only `fixed_mod` is a FLASHTnT problem. The other two are correctly-working FLASHIda features
whose *names* imply a reach they never had.

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | `max_flanking_mass_diff` — wire it into the extender? | **No.** Keep the mechanism; fix the naming. No FLASHTnT edit, no golden movement. |
| 2 | Where do the two keys go? | `precursor_selection.tag_expansion.{…}` |
| 3 | What does FLASHTnT get when `fixed_mod` is empty? | The config list **verbatim** (`[]`), not the declared `{""}` placeholder |
| 4 | Remove the three guards in place, or extract? | **Extract** shared param builders — removes the duplication and creates a test seam |
| 5 | Delivery | **One push**, separate commits for the mechanical and semantic parts |
| 6 | How does a stale config fail? | **Generic unknown-key error.** No migration message. |
| 7 | Adjacent cleanups | Delete dead `tag_based_enabled` only |
| 8 | The ~97 duplicated fixture blocks | **Out of scope** — belongs to the harness-conformance migration's Phase 0 |

Deliberately rejected: wiring `max_flanking_mass_diff` into the extender (would swap 1401 Da for
50000 Da across all 33 configs and move every golden set), a migration error, a validator warning
for the `max_ptm_count`/`ptm_list` dependency, CONTEXT.md glossary entries, and an ADR (this
*applies* ADR-0014's split rather than deciding anything new).

---

## Change 1 — schema

**Plain language:** two keys move to a new nested block. The values they carry are unchanged, and
the C++ code that reads them is unchanged — only the JSON path they arrive on differs.

```
precursor_selection:                     C++ storage is UNCHANGED:
  …                                        targeting_.max_total_ptm_count
  tag_expansion:                           targeting_.max_flanking_mass_diff
    max_ptm_count:          3            → every read site in PrecursorSelection.cpp
    max_flanking_mass_diff: 50000          keeps working untouched
```

Keeping the storage in `TargetingConfig` is what makes this a parse-path change only.

**C# (`MethodConfig.cs`)**

```csharp
[JsonKey("tag_expansion")]
public class TagExpansionConfig
{
    [JsonKey("max_ptm_count")]
    [Description("Maximum PTMs per enumerated target mass (tag-based target expansion)")]
    public int MaxPtmCount { get; set; } = 3;

    [JsonKey("max_flanking_mass_diff")]
    [Description("Maximum flanking mass difference when matching a tag to a FASTA protein, in Da")]
    public double MaxFlankingMassDiff { get; set; } = 50000;
}

// on PrecursorSelectionConfig — INITIALISED, so ToCppJson always emits it and a config that
// omits the block gets today's values rather than zeros:
[JsonKey("tag_expansion")]
public TagExpansionConfig TagExpansion { get; set; } = new TagExpansionConfig();
```

Remove `MaxPtmCount` / `MaxFlankingMassDiff` from `FlashTnTConfig`, and the matching fields from
`JsonFlashTnTConfig`. Add `JsonTagExpansionConfig` and hang it off `JsonPrecursorSelectionConfig`.

**C++ (`Config.cpp`)**

```cpp
// precursor_selection allowlist gains "tag_expansion"
rejectUnknownKeys(ps, {…, "additional_scans", "exploration", "tag_expansion"}, "precursor_selection");

auto te = ps.value("tag_expansion", json::object());
rejectUnknownKeys(te, {"max_ptm_count", "max_flanking_mass_diff"}, "precursor_selection.tag_expansion");
targeting_.max_total_ptm_count   = te.value("max_ptm_count", 3);
targeting_.max_flanking_mass_diff = te.value("max_flanking_mass_diff", 50000.0);

// flashtnt allowlist LOSES both names, and its two parse lines are deleted.
```

Old placements then fail through the ordinary strict-schema path on both sides — decision 6.

## Change 2 — config and fixture churn, as deletions

**Plain language:** almost everything already sits at the default, so it just loses the two keys.
Only three files gain a `tag_expansion` block.

| Carrier | Count | Action |
|---|---|---|
| Committed configs at `3` / `50000` | 31 | **Delete** both keys from `flashtnt` |
| `method_charge_based_exclusion.json`, `method_json_roundtrip.json` | 2 | Delete, then add `tag_expansion: {max_ptm_count: 5, max_flanking_mass_diff: 40000}` |
| `FlashIDA/src/Flash/etc/method.json` | 1 | Same — it also carries `5` / `40000` |
| C++ test **fixture JSON**, all at `3` / `50000` | 103 occurrences across 14 files (63 `"flashtnt"` blocks, 97 lines — 7 lines carry both keys) | **Delete** both keys |
| C++ test **assertions** — `ConfigSchemaParity_test.cpp:87-88` | 2 | **Repoint**, not delete — see Tests |
| `config_schema_reference.json` | 1 | **Regenerate** — never hand-edit |

Deletion is value-preserving because the new defaults equal the old ones on both sides: C# emits
`3`/`50000` for a config that omits the block, and a hand-written C++ fixture that omits it hits
`te.value("max_ptm_count", 3)`. A missed deletion is a hard schema error, not a silent value change
— which is why this is safer than a site-by-site move.

**The reference cannot be regenerated locally** (no restored packages, no net48 reference
assemblies, encrypted Thermo DLLs). Promote CI's `config-schema-reference-capture` artifact.

## Change 3 — `fixed_mod` reaches FLASHTnT unconditionally

**Plain language:** the same six tagger Params are built in two places, and both wrap `fixed_mod` in
an `if`. One builder replaces both, and the `if` goes.

```
BEFORE                                          AFTER
FragmentAnalysis.cpp:402-410  ─┐                 buildTaggerParam(cfg, ion_types)
  6 setValue calls             │  same 6           ← FragmentAnalysis.cpp:401
  if (!fixed_mod.empty()) …    │  keys,            ← PrecursorSelection.cpp:934
PrecursorSelection.cpp:935-943 ─┘  2 copies
  6 setValue calls                               buildExtenderParam(cfg, ion_types, max_mod_mass)
  if (!fixed_mod.empty()) …                        ← FragmentAnalysis.cpp:546
FragmentAnalysis.cpp:546-553
  if (!fixed_mod.empty()) …                      fixed_mod set unconditionally at all three
```

```cpp
// static, on FragmentAnalysis — the class PrecursorSelection already calls into for ion types
Param FragmentAnalysis::buildTaggerParam(const Config& config,
                                         const std::vector<std::string>& ion_types)
{
  FLASHTaggerAlgorithm tagger;
  Param p = tagger.getDefaults();
  p.setValue("ion_type",      ion_types);
  p.setValue("min_length",    config.targeting().min_tag_length);
  p.setValue("max_length",    config.targeting().max_tag_length);
  p.setValue("allow_gap",     config.targeting().allow_gap ? "true" : "false");
  p.setValue("max_aa_in_gap", config.targeting().max_aa_in_gap);
  p.setValue("fixed_mod",     config.targeting().fixed_mod);   // unconditional; [] when empty
  return p;
}
```

The extender builder is the same shape over `ion_type`, `max_mod_mass`, `skip_precursor_inference`,
`max_blind_mod_count`, `fixed_mod`. It has only one caller and removes no duplication — it exists
for the test seam (decision 4).

> **The one behavioural delta in the whole design.** The Param goes from the declared `{""}` to
> `[]`. Inert today, since nothing reads it. If a future FLASHTnT repair is written assuming the
> declared `{""}`, it will see `[]` — the deliberate choice (decision 3), and the safer one if that
> repair iterates the list without guarding for an empty entry.

## Change 4 — delete `tag_based_enabled`

`TargetingConfig::tag_based_enabled` (`Config.h:193`) is declared, never assigned from config, and
read nowhere in either project. One line, in code this push already touches.

---

## Tests

Three new, in `FragmentAnalysis_test.cpp` — already present in **both** the CI build-target list and
the `ctest -R` alternation, so no workflow registration is needed.

### T1 `buildTaggerParam_sets_every_key`

- **Purpose:** the extracted builder is faithful — nothing was dropped in the move from two inline blocks to one function.
- **In practice:** a reviewer diffing two deleted blocks against one new function cannot see a missing `setValue`; this can.

```
cfg = Config(json with min_length=4, max_length=9, allow_gap=true,
                       max_aa_in_gap=3, fixed_mod=["Carbamidomethyl (C)"])
p   = FragmentAnalysis::buildTaggerParam(cfg, {"b","y"})
ASSERT p["min_length"]    == 4
ASSERT p["max_length"]    == 9
ASSERT p["allow_gap"]     == "true"
ASSERT p["max_aa_in_gap"] == 3
ASSERT p["ion_type"]      == {"b","y"}
ASSERT p["fixed_mod"]     == {"Carbamidomethyl (C)"}
```

### T2 `buildTaggerParam_sets_fixed_mod_when_empty`

- **Purpose:** the regression guard for the removed guard. This is the test that fails if anyone reintroduces `if (!fixed_mod.empty())`.
- **In practice:** without it, a future tidy-up that restores the conditional is invisible — the value is inert today, so no other test can notice.

```
cfg = Config(json with flashtnt.fixed_mod = [])
p   = FragmentAnalysis::buildTaggerParam(cfg, {"b","y"})
ASSERT p.exists("fixed_mod")                  // present at all — the guard would omit it
ASSERT p["fixed_mod"].toStringVector().empty()  // [] verbatim, NOT the declared {""}
```

### T3 `buildExtenderParam_sets_fixed_mod_when_empty`

Same as T2 against `buildExtenderParam`, plus `max_blind_mod_count` and `max_mod_mass` carried
through.

### Modified

| Target | Change |
|---|---|
| 14 C++ test files | delete the two keys from inline fixture JSON — mechanical, 103 occurrences |
| `ConfigSchemaParity_test.cpp:87-88` | **Repoint the two assertions.** They currently read `j["flashtnt"]["max_ptm_count"]` and `j["flashtnt"]["max_flanking_mass_diff"]` and compare against `cfg.targeting()`. They become `j["precursor_selection"]["tag_expansion"][…]`. This is the read-proof that the new parse path lands in the same C++ fields — **the single most valuable test in the schema half, and deleting it instead of repointing would remove the only mechanical check that the move preserved values.** |
| C# `JsonConfigTests.cs:60, 76-77, 84-85` | fixture JSON moves the two keys into `precursor_selection.tag_expansion`; the three assertions repoint from `Config.FlashTnT.MaxPtmCount` / `.MaxFlankingMassDiff` to `Config.PrecursorSelection.TagExpansion.…` (non-default values 6 / 42000, so they genuinely prove binding) |
| `ConfigSchemaParityTests.Reference_IsNeverStale` | passes once the regenerated reference is promoted |

### Unchanged

Log goldens (17 modes × 5 streams), regression TSVs, continuity JSONs. The design is
value-preserving: the same numbers reach the same C++ fields, and the only Param that changes is one
nothing reads. **If any golden moves, that is a defect in this implementation, not an expected
recapture** — stop and diagnose rather than recapturing.

## Risks

| Risk | Mitigation |
|---|---|
| A missed deletion among the 103 fixture sites | Fails loudly as an unknown key on both sides; it cannot silently change a value |
| Deleting `ConfigSchemaParity_test.cpp:87-88` instead of repointing them | Would silently drop the only mechanical proof that the new path lands in the same fields — called out explicitly in Tests |
| `{""}` → `[]` matters to a future FLASHTnT repair | Documented above and pinned by T2/T3, so whoever does that repair sees the contract |
| Reference regeneration needs CI | Promote `config-schema-reference-capture`; do not hand-edit |
| No local build | CI is the only end-to-end gate — expect at least one round trip |

## Working agreement

- **Approval before applying.** Any failure re-enters planning rather than being fixed in place.
- **No golden writes** without showing the diff and getting sign-off. This design expects **zero**.
- Commits stay fine-grained inside the single push: schema, fixture churn, param builders, and the
  `tag_based_enabled` deletion are separate commits.
- FLASHDeconv and FLASHTnT stay untouched. Every change here is in FLASHIda-owned code.

## Out of scope

Repairing FLASHTnT so `fixed_mod` is honoured; wiring `max_flanking_mass_diff` into the extender's
path search; hoisting the 63 duplicated `"flashtnt"` fixture blocks (harness-conformance migration,
Phase 0); a validator warning for `max_ptm_count` without `files.ptm_list`.

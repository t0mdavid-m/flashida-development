# `characterization.mode: exhaustive` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth `characterization.mode` value, `exhaustive`, whose MS3 target pool is every deconvolved mass of the winner MS2 scan — not only the masses that matched the winning proteoform.

**Architecture:** One new branch in `ProteoformTracker::planNextScans` builds `Ms3Target`s directly from the winner `PendingScan`'s `PeakRecord`s instead of from `ProteoformModel::fragments`. A mass that also matched a theoretical fragment keeps its real `ion_type`/`ion_index` and is acquired and matched exactly as today; a mass that did not is labelled `'u'`/`0`, is acquired identically, and its MS3 is logged rather than matched. Nothing else about the acquisition changes.

**Tech Stack:** C++20 (OpenMS submodule, clang-format LLVM 150-col / 2-space / Allman), C# 7.3 / .NET Framework 4.8 (FlashIDA submodule), NUnit, ctest, CI-only builds.

**Authority:** [ADR-0023](../../adr/0023-exhaustive-characterization-targets-unassigned-masses.md), decisions 1–11. Where this plan diverges from the ADR's *wording*, the divergence is called out inline and Task 8 amends the ADR in the same push.

---

## Global Constraints

- **The 21 existing golden mode directories must not move.** `FlashIDA/test-data/golden/logs/` has 21 dirs × 5 streams. Push 1 lands fully green with zero movement there; the 22nd dir arrives in Push 2 after diff review and sign-off.
- **Never write a golden without showing the owner the diff first.** A plan-level approval is not a write approval. `.claude/settings.json` wires `golden-write-guard.sh` as a PreToolUse hook — a blocked write is the gate working.
- **No local build is possible in this workspace** (no NuGet packages, no net48 reference assemblies, Thermo DLLs encrypted). CI is the only end-to-end gate. The C# *config layer* alone type-checks locally in ~2s via the net8 SDK + `JavaScriptSerializer` shim.
- **A new C++ test runs in CI only if registered in THREE places**: `executables.cmake`, the `cmake --build --target` list in `.github/workflows/flashida-ci.yml`, and the `ctest -R` alternation in the same file. Any one alone means compiles-but-never-runs, or never builds.
- **`config_schema_reference.json` is generated, never hand-edited.** It is produced by a C# test under `REGEN_CONFIG_REFERENCE=1` and promoted from the CI artifact.
- **Unknown config keys are hard-rejected on both sides** (ADR-0007). A key added to C# and not to C++'s allow-set is a hard load failure for every config, because `ToCppJson` emits every scalar unconditionally.
- **Code style:** C++ matches `OpenMS/.clang-format`; comments in this codebase explain *why*, and load-bearing invariants get a comment naming the failure they prevent.

---

## TL;DR — what this actually does

Today the engine only ever re-fragments masses it already recognised. In a real cytochrome-C MS2, **117 masses come out and 44 are recognised**. The other 73 are thrown away — including the single most intense mass in the spectrum, which turns out to be a real fragment of a co-isolated protein.

```
            MS2 spectrum: 117 deconvolved masses
                 |
   TODAY  -------+------------------------------.
                 |                              |
          44 mapped fragments            73 unassigned masses
                 |                              |
          pick 3 by objective                DISCARDED
                 |
             3 MS3 scans

   WITH exhaustive
                 |
          all 117 ranked by intensity (filters applied)
                 |
          take max_targets, strongest first
                 |
     .-----------+-----------.
     |                       |
  mapped -> real ion      unassigned -> 'u'/0
  matched as usual        acquired, logged, not matched
```

---

## File Structure

| File | Responsibility in this change |
|---|---|
| `OpenMS/.../FLASHIda/Config.h` | `CharacterizationMode::Exhaustive`, `CharacterizationObjective::Exhaustive`, `min_target_mass` field |
| `OpenMS/.../FLASHIda/Config.cpp` | mode parse, key allow-set, error texts, no projection change |
| `OpenMS/.../FLASHIda/MS3FragmentMatcher.{h,cpp}` | `isKnownIonClass` + the positive class guard at every projection site |
| `OpenMS/.../FLASHIda/ProteoformTracker.{h,cpp}` | `planExhaustive_`, dispatch memory, `objectiveUnmet` branch, `[MS3-PLAN]` fields |
| `OpenMS/.../FLASHIda/Exploration.cpp` | decision 11: metric override for an unassigned MS3 target |
| `FlashIDA/src/Flash/MethodConfig.cs`, `MethodParameters.cs` | `min_target_mass` authoring + emit |
| `OpenMS/src/tests/.../ProteoformTracker_Exhaustive_test.cpp` | new — the mode's behaviour |
| `OpenMS/src/tests/.../MS3FragmentMatcher_test.cpp` | **reverses a pinned assertion** — see Test Changes |
| `.github/workflows/flashida-ci.yml`, `executables.cmake` | test registration (3 sites) |
| `FlashIDA/test-data/configs/method_ms3_cytc_exhaustive.json` | new fixture (Push 2) |
| `docs/adr/0023-*.md`, `docs/adr/0013-*.md`, `CLAUDE.md`, `OpenMS/CLAUDE.md`, `docs/method-config-options.md`, `.claude/skills/validate-flashida-config/validate.py` | the allowed-value set appears in all of these |

---

## Test Changes Requiring Sign-Off

Per the working agreement, every test added, edited or deleted is enumerated here and needs approval **before** implementation starts.

| Test | Change | Why |
|---|---|---|
| `MS3FragmentMatcher_test.cpp:44-50` | **EDIT — reverses an existing assertion.** Currently `// Unknown: defaults to y-precursor behavior` / `TEST_EQUAL(getMS3IonTypes('?').size(), 3)`. Becomes `TEST_EQUAL(getMS3IonTypes('?').empty(), true)` + positive cases for a/b/c/x/y/z | ADR-0023 decision 5 reverses the fallback *deliberately*. It was pinned with a comment blessing it, so this is a decision reversal, not a bug fix |
| `MS3FragmentMatcher_test.cpp` (new section) | **ADD** — `extractSubsequence(seq, ctx, 'u', k) == ""` for k = 0 **and every k in 1..region_length**; `computeEquivalentIon` with class `'u'` yields empty type / index 0 | the refusal must key on the CLASS, never on index 0 — nothing ties `'u'` to `0` |
| `ProteoformTracker_Exhaustive_test.cpp` | **NEW FILE** — 7 sections, below | the mode's behaviour |
| `Config_SchemaProjection_test.cpp` | **EXTEND** — an `exhaustive` block asserting level 1 == QScore, levels 2/3 != None, objective == Exhaustive; keep the existing typo probe | the level-1 trap; and that a fourth value did not loosen strictness |
| `FLASHIda_LegacyConfig_test.cpp` | **EXTEND** — `mode: "exhaustive"` parses; `mode: "exhaustve"` still throws; `min_target_mass` parses and defaults to 0 | schema |
| `ConfigSchemaParityTests` (C#) | **no edit** — must simply go green after the reference is regenerated | drift guard |
| `FLASHIdaLogGolden_test.cs` mode map | **EXTEND (Push 2)** — one entry for the new mode | golden |

**Not touched:** `ScanCommandLayout*` (no ABI change), `BridgeSmokeTests`, `BridgePhase3Tests`, `ContinuityTests`, the 21 existing golden dirs.

---

## Decisions this plan makes that ADR-0023 does not state

Each is implemented as written here and folded into the ADR by Task 8.

| # | Decision | Why |
|---|---|---|
| D-a | `CharacterizationObjective` gains `Exhaustive`, assigned in the mode parse | **`characterization().mode` has ZERO engine read sites.** `planNextScans` branches on `.objective` (`ProteoformTracker.cpp:421`, `:524`), which has two values and defaults to `Ambiguity`. A mode-only addition ships a mode byte-identical to `ambiguity` |
| D-b | The MS3-capability gate on the winner scan reads `!activation_type.empty() && !isMs3CapableActivation(...)` | mirrors the engine's only existing capability test (`:1032`), whose 8-line comment records that failing closed on `""` returns zero targets for every hand-built fixture |
| D-c | The mapped/unassigned replay binds **in-tolerance only** | `mapScanOntoModel_` falls back to "closest overall" (`:947`, *"never drop a matched fragment for lack of a peak"*). Copying that fallback would stamp a real `b61` onto an arbitrarily distant peak — a confident wrong label |
| D-d | Pool filters (mass floor, charge floor, `mz>0 && charge>0`) run **inside** the planner, before the memory is stamped | `min_fragment_charge` is enforced only at `Exploration.cpp:950`, *after* `planNextScans` returned. Stamping first would burn a nominal mass on a target that is then dropped, permanently |
| D-e | `[MS3-PLAN]` is split: the tracker emits `pool/targets/truncated/budget`; Exploration emits `variants/commands` | `buildVariants_` is private to `Exploration` and the tracker holds no reference to it |
| D-f | The wire format is **not** changed; unassigned MS3s carry no ion token and log empty `ion_type` / `ion_index=0` | owner's call. `'u'` stays an in-engine sentinel that drives the matcher guard |
| D-g | Decision 11's metric override is gated `msn_level >= 3` | `initiate`'s `ion_type` defaults to `'\0'` and the MS2 call site passes nothing — an ungated test would force `remaining_precursor` onto every MS2 exploration group and move 4 goldens |

---

## Task 1: C++ config — the enum values and the new key

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:52-56, :287-292, :340-341`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:427-430, :436-457, :266-268, :1049-1054`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp`, `Config_SchemaProjection_test.cpp`

**Interfaces:**
- Produces: `CharacterizationMode::Exhaustive`, `CharacterizationObjective::Exhaustive`, `Config::characterization().min_target_mass` (`double`, default `0.0`)
- Consumes: nothing

> **TL;DR:** teach the config three new words. `mode: "exhaustive"` must parse, must set the *objective* too (or the engine silently runs ambiguity), and `min_target_mass` must be accepted rather than hard-rejected.
>
> ```
>   before:  mode -> {off, ambiguity, coverage}      objective -> {Ambiguity, Coverage}
>   after :  mode -> {off, ambiguity, coverage,      objective -> {Ambiguity, Coverage,
>                     exhaustive}                                  Exhaustive}
> ```

- [ ] **Step 1: Write the failing tests**

In `FLASHIda_LegacyConfig_test.cpp`, add a section:

```cpp
START_SECTION(([EXTRA] characterization mode exhaustive parses and carries its own objective))
{
  const std::string json = R"JSON({
    "deconvolution": {"tol": [10, 10, 10]},
    "precursor_selection": {"rank_by": "qscore", "max_precursors": 2},
    "characterization": {"mode": "exhaustive", "protein_sequence": "PEPTIDEPEPTIDE",
                         "max_targets": 3, "min_target_mass": 0},
    "ms_settings": {"ms1": {}, "ms2": {"activation": "HCD"}, "ms3": {"activation": "HCD"}}
  })JSON";
  Config cfg(json);
  TEST_EQUAL(cfg.characterization().mode == Config::CharacterizationMode::Exhaustive, true)
  TEST_EQUAL(cfg.characterization().objective == CharacterizationObjective::Exhaustive, true)
  TEST_REAL_SIMILAR(cfg.characterization().min_target_mass, 0.0)
}
END_SECTION

START_SECTION(([EXTRA] a typo'd mode still throws, and min_target_mass is honoured))
{
  const std::string bad = R"JSON({
    "deconvolution": {"tol": [10, 10, 10]},
    "characterization": {"mode": "exhaustve", "protein_sequence": "PEPTIDE"},
    "ms_settings": {"ms1": {}, "ms2": {"activation": "HCD"}, "ms3": {"activation": "HCD"}}
  })JSON";
  TEST_EXCEPTION(Exception::InvalidParameter, Config(bad))

  const std::string floored = R"JSON({
    "deconvolution": {"tol": [10, 10, 10]},
    "precursor_selection": {"rank_by": "qscore", "max_precursors": 2},
    "characterization": {"mode": "exhaustive", "protein_sequence": "PEPTIDEPEPTIDE",
                         "min_target_mass": 1500.5},
    "ms_settings": {"ms1": {}, "ms2": {"activation": "HCD"}, "ms3": {"activation": "HCD"}}
  })JSON";
  Config cfg2(floored);
  TEST_REAL_SIMILAR(cfg2.characterization().min_target_mass, 1500.5)
}
END_SECTION
```

Note the exception type must match what `Config.cpp` actually throws for a bad mode — read `Config.cpp:449-452` and use that type verbatim rather than assuming.

In `Config_SchemaProjection_test.cpp`, add:

```cpp
START_SECTION(([EXTRA] exhaustive projects every level, level 1 included))
{
  Config cfg(exhaustiveJson());   // same shape as above, rank_by "qscore"
  // Level 1 MUST be assigned. MSLevelConfig::selection defaults to None, and an unassigned
  // level 1 makes FLASHIda.cpp:169 short-circuit EVERY MS1 -- the instrument acquires nothing,
  // silently, with no wrong value anywhere to notice.
  TEST_EQUAL(cfg.level(1).selection == SelectionMetric::QScore, true)
  TEST_EQUAL(cfg.level(2).selection != SelectionMetric::None, true)
  TEST_EQUAL(cfg.level(3).selection != SelectionMetric::None, true)
  TEST_EQUAL(cfg.level(2).max_targets, 3)
}
END_SECTION
```

- [ ] **Step 2: Run to verify they fail**

CI only (no local build). Expected failure: `Config` throws on `"exhaustive"` with the "must be one of" message, and on the unknown key `min_target_mass`.

- [ ] **Step 3: Add the enum values and the field**

`Config.h:52-56` — add to `CharacterizationObjective`:

```cpp
  enum class CharacterizationObjective
  {
    Ambiguity, ///< Resolve PTM site ambiguity
    Coverage,  ///< Extend sequence coverage
    Exhaustive ///< Fragment every deconvolved mass of the winner MS2 scan (ADR-0023)
  };
```

`Config.h:287-292` — add to `CharacterizationMode`:

```cpp
  enum class CharacterizationMode
  {
    Off,
    Ambiguity,
    Coverage,
    Exhaustive
  };
```

`Config.h` after `int min_fragment_charge = 0;` (:341):

```cpp
    /// Pool floor for characterization.mode == Exhaustive: a deconvolved mass below this is not a
    /// target. 0 = off, and off is the default deliberately -- the mode does exactly what its name
    /// says until told otherwise.
    ///
    /// NOT inheritable from deconvolution.min_mass: that floor is not applied to MSn output. The
    /// reference config sets min_mass 500 / min_charge 4 and its MS2 spectra still contain 248 Da
    /// and charge-1 species. This is a genuinely new floor, not a duplicate of an existing one.
    double min_target_mass = 0.0;
```

- [ ] **Step 4: Extend the parse**

`Config.cpp:427-430` — add `"min_target_mass"` to the `rejectUnknownKeys` allow-set for the `characterization` section.

`Config.cpp:436-452` — add the branch, keeping the existing if/else shape:

```cpp
      else if (m == "exhaustive")
      {
        characterization_.mode = CharacterizationMode::Exhaustive;
        // The engine reads `objective`, never `mode` -- mode has zero read sites outside this file.
        // Assigning only the mode here would ship a mode byte-identical to "ambiguity" (ADR-0023 D-a).
        characterization_.objective = CharacterizationObjective::Exhaustive;
      }
```

`Config.cpp:451` — the throw text gains the value:

```cpp
            "Config: characterization.mode must be one of \"off\", \"ambiguity\", \"coverage\", "
            "\"exhaustive\"; "
```

`Config.cpp:455-457` region — read the key beside its siblings:

```cpp
      characterization_.min_target_mass = charact.value("min_target_mass", 0.0);
```

- [ ] **Step 5: Fix the two-way ternary in the error text**

`Config.cpp:1052` currently reads:

```cpp
          std::string(characterization_.mode == CharacterizationMode::Coverage ? "coverage" : "ambiguity")
```

> `// ISSUE: with a third on-value this prints "ambiguity" for an exhaustive config -- a factually
> // wrong mode name inside an error message telling the user what their config said.`

Replace with a switch-covered helper placed in the same anonymous namespace as the file's other free helpers, so the next value is a compiler error rather than a wrong string:

```cpp
  const char* characterizationModeName(Config::CharacterizationMode m)
  {
    switch (m)
    {
      case Config::CharacterizationMode::Off: return "off";
      case Config::CharacterizationMode::Ambiguity: return "ambiguity";
      case Config::CharacterizationMode::Coverage: return "coverage";
      case Config::CharacterizationMode::Exhaustive: return "exhaustive";
    }
    return "off";
  }
```

`Config.cpp:955` — the second message enumerating on-values gains `"exhaustive"`. `Config.cpp:267` — the `selection_strategy` migration message's `(off|ambiguity|coverage)` becomes `(off|ambiguity|coverage|exhaustive)`.

- [ ] **Step 6: VERIFY, do not edit, the projection**

Read `Config.cpp:848-873`. Confirm by reading — do not change:

- level 1 is assigned from `precursor_selection.rank_by` **unconditionally and independent of mode** (`:853-861`), with a "Do not remove" comment naming the failure
- levels 2 and 3 derive from `const bool on = characterization_.mode != CharacterizationMode::Off;` (`:871-873`) — an inequality, not an enumeration of on-values, **so a fourth mode projects correctly by construction**

Add one comment at `:871` recording that the `!= Off` form is what makes new modes safe, so nobody "tidies" it into an enumeration later.

Also verify `validate()` needs no change: `:961` (ms3 activation must be HCD/CID), `:1039` (protein_sequence required), `:1049` (ms_settings.ms3 required) all key on `!= Off` and are all correct for exhaustive.

- [ ] **Step 7: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
  src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
  src/tests/class_tests/openms/source/FLASHIda_LegacyConfig_test.cpp \
  src/tests/class_tests/openms/source/Config_SchemaProjection_test.cpp
git -C OpenMS commit -m "config: characterization.mode exhaustive + min_target_mass (ADR-0023)"
```

---

## Task 2: C# config layer — authoring and emitting `min_target_mass`

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:352-354` (authored field), `:727-729` (emit DTO)
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:243` (emit assignment)

**Interfaces:**
- Consumes: nothing from Task 1 at compile time — but see the ordering constraint
- Produces: `characterization.min_target_mass` in the C++-facing JSON, emitted unconditionally

> **TL;DR:** the C# side must be able to author the key and must emit it. It emits every scalar unconditionally, and C++ hard-rejects unknown keys — so **Task 1's allow-set edit and this task must land in the same push**, or every config fails to load.
>
> ```
>   method.json          C# model            ToCppJson            C++ Config
>   min_target_mass  ->  MinTargetMass  ->   min_target_mass  ->  allow-set (Task 1)
>                                            ^ always emitted     ^ must accept
> ```

- [ ] **Step 1: Add the authored field**

`MethodConfig.cs`, in `CharacterizationConfig` beside `MinFragmentCharge` (:352-354):

```csharp
        [JsonKey("min_target_mass")]
        [Description("Exhaustive mode only: deconvolved masses below this (Da) are not MS3 targets. 0 = off.")]
        public double MinTargetMass { get; set; } = 0.0;
```

- [ ] **Step 2: Add it to the emit DTO**

`MethodConfig.cs:727-729`, in the JSON DTO beside `min_fragment_charge`:

```csharp
        public double min_target_mass { get; set; }
```

- [ ] **Step 3: Assign it in `ToCppJson`**

`MethodParameters.cs:243`, beside `min_fragment_charge`:

```csharp
                    min_target_mass = c.Characterization.MinTargetMass,
```

- [ ] **Step 4: Confirm C# does NOT validate the mode string**

Read `MethodConfigSerializer.cs`. Establish and record in the commit message whether any allowed-value check on `characterization.mode` exists. Recon says **it does not** — C# validates *keys*, never *values*, so `Config.cpp:449-452` is the only validator of the mode string in either language. If a check does exist, add `"exhaustive"` to it.

- [ ] **Step 5: Type-check the config layer locally**

Use the net8 SDK + `JavaScriptSerializer` shim harness (~2s). This is the only part of the C# side that builds in this workspace.

- [ ] **Step 6: Commit**

```bash
git -C FlashIDA add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git -C FlashIDA commit -m "config: author and emit characterization.min_target_mass (ADR-0023)"
```

---

## Task 3: The matcher's positive ion-class guard

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h` (declare `isKnownIonClass`)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp:22-37, :269-291, :~395-399, :~499-523`
- Test: `OpenMS/src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp:44-50` (**reverses a pinned assertion**)

**Interfaces:**
- Produces: `static bool MS3FragmentMatcher::isKnownIonClass(char c)` — true for `a b c x y z` only
- Consumed by: Task 4 (labelling), Task 5 (metric override)

> **TL;DR:** an unknown ion character currently falls through to the **suffix** branch everywhere. So a `'u'` paired with any non-zero index would silently cut a real suffix subsequence out of the proteoform and match against it — confident wrong identifications instead of nothing. The refusal must key on the **class**, never on the index.
>
> ```
>   today:  getMS3IonTypes('?')      -> {a, b, y}   (suffix set)   <- pinned by a test!
>           extractSubsequence(...)  -> index<=0 ? "" : SUFFIX CUT
>
>   after:  isKnownIonClass('?')     -> false
>           every projection site    -> refuses, whatever the index
> ```

- [ ] **Step 1: Write the failing tests**

Replace `MS3FragmentMatcher_test.cpp:47-49`:

```cpp
  // Unknown ion class: NO ion types. Reversed deliberately by ADR-0023 decision 5 -- the old
  // suffix fallback is what would let an unassigned target ('u') fabricate a match frame.
  auto unk_types = MS3FragmentMatcher::getMS3IonTypes('?');
  TEST_EQUAL(unk_types.empty(), true)

  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('a'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('b'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('c'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('x'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('y'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('z'), true)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('u'), false)
  TEST_EQUAL(MS3FragmentMatcher::isKnownIonClass('\0'), false)
```

Add a new section — **the index sweep is the point of this test**:

```cpp
START_SECTION(([EXTRA] an unknown ion class never projects, at ANY index))
{
  MS3FragmentMatcher::ProteoformContext ctx;
  ctx.region_start = 0;
  ctx.region_end   = 14;
  const std::string seq = "PEPTIDEPEPTIDE";

  // Nothing ties 'u' to index 0 -- ion_type and ion_index are two independent fields and
  // travel independently. If the refusal keyed on the index instead of the class, every k
  // below would cut a real suffix and match against it.
  for (int k = 0; k <= 14; ++k)
  {
    TEST_EQUAL(MS3FragmentMatcher::extractSubsequence(seq, ctx, 'u', k), "")
  }
  // Known classes are unaffected at in-range indices.
  TEST_EQUAL(MS3FragmentMatcher::extractSubsequence(seq, ctx, 'b', 4), "PEPT")
}
END_SECTION
```

- [ ] **Step 2: Run to verify they fail**

CI. Expected: `unk_types.empty()` fails (returns 3), `isKnownIonClass` does not compile.

- [ ] **Step 3: Add the predicate**

`MS3FragmentMatcher.h`, beside the other statics:

```cpp
    /// The ion classes this matcher can project an MS3 sub-fragment through.
    ///
    /// Everything else -- notably 'u', the label an exhaustive-mode unassigned target carries
    /// (ADR-0023) -- has no frame, and every projection site must refuse rather than fall through.
    /// The refusal keys on the CLASS and never on the index: the two fields are independent, so an
    /// index-only guard leaves a 'u' with a plausible index cutting a real suffix (ADR-0023 D-f).
    static bool isKnownIonClass(char ion_class);
```

```cpp
  bool MS3FragmentMatcher::isKnownIonClass(char ion_class)
  {
    return ion_class == 'a' || ion_class == 'b' || ion_class == 'c'
        || ion_class == 'x' || ion_class == 'y' || ion_class == 'z';
  }
```

- [ ] **Step 4: Apply the guard at every projection site**

`getMS3IonTypes` (`:22-37`) — the `default:` branch returns `{}`.

`extractSubsequence` (`:269-291`) — insert **above** the existing index/range checks, leaving those untouched so every known-class case is byte-identical:

```cpp
    if (!isKnownIonClass(fragment_ion_type)) return "";
```

Apply the same first-line refusal in `fragmentProFormaSites`, `fragmentProForma`, `computeEquivalentIon` and `calibrateAndScore` (returning each function's existing empty/false/zero-score value). Enumerate them by grepping for `fragment_ion_type` in the file — every function taking it must refuse, so no path can reach a suffix branch with an unknown class.

- [ ] **Step 5: Run tests to verify they pass**

CI: `ctest -R MS3FragmentMatcher --output-on-failure`. Also confirm still-green: `MS3FragmentMatcher_test`'s existing b/y/a extraction cases (`:305-340`) and `fragmentProForma('\0',0)` / `('y',0)` (`:418-419`).

- [ ] **Step 6: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.h \
  src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/MS3FragmentMatcher.cpp \
  src/tests/class_tests/openms/source/MS3FragmentMatcher_test.cpp
git -C OpenMS commit -m "ms3: refuse to project an unknown ion class (ADR-0023 decision 5)"
```

---

## Task 4: The exhaustive planner

**Files:**
- Modify: `OpenMS/.../FLASHIda/ProteoformTracker.h` — `ProteoformModel::dispatched_nominal_masses`, `planExhaustive_` declaration
- Modify: `OpenMS/.../FLASHIda/ProteoformTracker.cpp:407-443` (`objectiveUnmet`), `:497-533` (guards + fork), `:763-768` (marker)
- Test: `OpenMS/src/tests/class_tests/openms/source/ProteoformTracker_Exhaustive_test.cpp` (**new**)

**Interfaces:**
- Consumes: `CharacterizationObjective::Exhaustive`, `min_target_mass` (Task 1); `MS3FragmentMatcher::isKnownIonClass` (Task 3)
- Produces: `std::vector<Ms3Target> ProteoformTracker::planExhaustive_(ProteoformModel& m, int precursor_id, int budget)`; `ProteoformModel::dispatched_nominal_masses` (`std::set<int>`)

> **TL;DR:** the new branch reads the winner scan's raw peak list instead of the matched-fragment table. Every `PeakRecord` field maps one-to-one onto an `Ms3Target` field — the data is already there, nothing new is measured.
>
> ```
>   ambiguity/coverage:   m.fragments  (map<FragmentKey, MappedFragment>)  -> targets
>   exhaustive:           m.staged[winner].peaks  (vector<PeakRecord>)     -> targets
>                                |
>                          each PeakRecord:
>                            mz         -> frag_mz          by_charge -> notches
>                            charge     -> frag_charge      mono_mass -> frag_mass
>                            iso_width  -> iso_width        stage1_scores -> stage1_scores
>                                |
>                          matched a theoretical fragment IN TOLERANCE?
>                            yes -> real ion_type / ion_index
>                            no  -> 'u' / 0
> ```

**Where the fork goes.** After the identification guards (`:518` `no_model`, `:521` `unidentified_precursor`, `:522` `no_ms2_context`) and after the budget guard (`:526` `zero_budget`), so decision 10's reason strings report identically in all modes. **Before** the `empty_sequence`/`empty_region` guards and before the objective-keyed pool build.

**Algorithm** (implement fresh from this spec):

```
planExhaustive_(m, precursor_id, budget):
    win = the PendingScan in m.staged with scan_id == m.winner_scan_id and ms_level == 2
    if not found                                   -> no_plan("no_winner_scan")

    # D-b: empty activation means "not recorded", NOT "incapable" -- mirrors :1032
    if !win.params.activation_type.empty()
       and !isMs3CapableActivation(win.params.activation_type)
                                                   -> no_plan("winner_scan_not_ms3_capable")

    pool = []
    for pr in win.peaks:
        nominal = SpectralDeconvolution::getNominalMass(pr.mono_mass)
        # D-d: EVERY filter runs before the memory is stamped, or a dropped mass burns forever
        if pr.mono_mass < config.characterization().min_target_mass   -> skip
        if charge_floor > 0 and abs(pr.charge) < charge_floor          -> skip
        if pr.mz <= 0 or pr.charge == 0                                -> skip   # unisolatable
        if nominal in m.dispatched_nominal_masses                      -> skip
        pool.append((pr, nominal))

    if pool empty                                  -> no_plan("pool_exhausted")

    sort pool by pr.intensity DESCENDING            # decision 4, no tiebreak

    targets = []
    for (pr, nominal) in pool:
        if targets.size() == budget: break
        (ion_type, ion_index) = labelFor(m, pr)     # below
        t = Ms3Target{ ion_type, ion_index,
                       frag_mz = pr.mz, frag_charge = pr.charge,
                       frag_mass = pr.mono_mass, iso_width = pr.iso_width,
                       stage0_params = win.params,          # the winner scan's own stage[0]
                       stage1_scores = pr.stage1_scores,
                       notches = selectNotches(from pr.by_charge, anchor = pr.charge) }
        targets.append(t)
        m.dispatched_nominal_masses.insert(nominal)  # stamped AFTER all filters (D-d)

    emit [MS3-PLAN] precursor_id= objective=exhaustive pool=|pool| targets=|targets|
                    truncated=(|pool| - |targets|) budget=budget
    return targets

labelFor(m, pr):
    # D-c: IN-TOLERANCE ONLY. mapScanOntoModel_ falls back to "closest overall" so a matched
    # theoretical never loses its intensity; replaying that fallback here would stamp a real
    # ion label onto an arbitrarily distant peak. Different question, different rule.
    for (key, f) in m.fragments:
        if |f.theoretical_mass - pr.mono_mass| within level-2 tolerance_ppm:
            return (f.ion_type, f.ion_index)
    return ("u", 0)
```

**`objectiveUnmet` gains an explicit branch** at `ProteoformTracker.cpp:407-443`. It is currently `if (objective == Coverage) {...} else {...ambiguity...}` — a binary fall-through, and it is the escalation ladder's stopping condition via `takeNextEscalationStep:453`. Rewrite as a `switch` over the objective so no future value can inherit an unrelated rule silently:

```
Exhaustive => unmet iff some pool mass of the winner scan passes both filters and its
              nominal mass is not yet in dispatched_nominal_masses
```

That makes `objectiveUnmet` == "`planNextScans` would return something", which is exactly what `ProteoformTracker.h:312`'s comment already claims it means.

- [ ] **Step 1: Write the failing test file**

`ProteoformTracker_Exhaustive_test.cpp` — drive it purely through the public `feedScan → finalizeMS2 → planNextScans` sequence, as `ProteoformTracker_CEOptimization_test.cpp:328` and friends already do (there are no `*ForTest` hooks and none may be added — scaffolding lives at the test location).

| Section | Purpose | Asserts |
|---|---|---|
| 1. `pool_is_every_deconvolved_mass` | the core claim | feed an MS2 whose deconvolution has N masses of which M map; `planNextScans` with `max_targets = N` returns N targets, not M |
| 2. `unassigned_targets_are_labelled_u0` | decision 5 | every target whose mass matches no theoretical fragment has `ion_type == "u"` and `ion_index == 0`; every mapped one has a real type and `index > 0` |
| 3. `ranking_is_intensity_descending` | decision 4 | the returned order is non-increasing in the source `PeakRecord` intensity, and mapped/unassigned interleave (i.e. rank is not segregated by class) |
| 4. `filters_apply_before_the_budget` | D-d | with `min_target_mass` above the k-th mass and `min_fragment_charge` above the j-th, those masses are absent from the plan **and** absent from `dispatched_nominal_masses` — so a later plan can still reach them |
| 5. `dispatch_memory_suppresses_duplicates` | decision 7 | call `planNextScans` twice with a budget below the pool size; the second call returns a disjoint set, and a third eventually yields `no_plan("pool_exhausted")` |
| 6. `etd_winner_plans_nothing` | decision 3 + D-b | winner staged with `activation_type = "ETD"` ⇒ zero targets, reason `winner_scan_not_ms3_capable`; with `activation_type = ""` ⇒ targets ARE planned (the empty-means-unrecorded asymmetry) |
| 7. `ambiguity_and_coverage_are_untouched` | golden safety | the same fixture under `mode: ambiguity` and `mode: coverage` returns exactly what it returns on `main` — the regression guard for the 21 golden dirs |

Assert **plausibility ranges and structure** here, not exact floats: C++ ctests assert ranges, C# NUnit asserts exact goldens.

**Adversarial check before writing each section:** under what bug would this test FAIL? Section 1 fails if the pool is still `m.fragments`. Section 4 fails if filters run after the stamp. Section 6 fails if the gate is copied literally from the ADR (`""` would be rejected). If a section has no such answer, it is vacuous — rewrite it.

- [ ] **Step 2: Run to verify it fails** — CI, after Task 6 registers it. Expected: link error, then N == M.

- [ ] **Step 3: Add the model field**

`ProteoformTracker.h`, on `ProteoformModel` beside `next_rung` (:238):

```cpp
    /// Nominal masses already dispatched as exhaustive MS3 targets for this Precursor (ADR-0023 d7).
    ///
    /// Per-Precursor and monotone. Nominal-mass keyed -- the same key exclusion and Precursor
    /// identity use -- so "we have fragmented this species" means one thing engine-wide.
    ///
    /// Dispatched-but-never-returned counts as DONE, deliberately, for the same reason next_rung
    /// lives here: a target with no record that it was tried is re-dispatched forever.
    ///
    /// Unused by ambiguity/coverage, which are self-limiting by construction (a localized mod
    /// leaves the ambiguous list; a witnessed bond leaves the uncovered set). Exhaustive has no
    /// such feedback -- its pool never shrinks -- so this set IS its termination condition.
    std::set<int> dispatched_nominal_masses;
```

No signature changes are needed anywhere: `planNextScans` already takes the model by non-const reference (`:519`) and is a non-const method.

- [ ] **Step 4: Implement `planExhaustive_`, the fork, and the `objectiveUnmet` switch**

Per the algorithm above. `SpectralDeconvolution::getNominalMass` is already reachable (`SpectralDeconvolution.h` is included at `ProteoformTracker.cpp:38`); no new includes are required.

- [ ] **Step 5: Split the `[MS3-PLAN]` marker (D-e)**

Extend the success line at `:763-768` with `objective=`, `pool=`, `targets=`, `truncated=`, `budget=`. Replace its existing two-way objective ternary with a switch-covered `objectiveName()` helper. **Do not** attempt `variants=`/`commands=` here — `buildVariants_` is private to `Exploration` and the tracker holds no reference to it; that half is emitted in Task 5.

- [ ] **Step 6: Run tests to verify they pass** — CI: `ctest -R "ProteoformTracker" --output-on-failure`.

- [ ] **Step 7: Commit**

```bash
git -C OpenMS add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.h \
  src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ProteoformTracker.cpp \
  src/tests/class_tests/openms/source/ProteoformTracker_Exhaustive_test.cpp
git -C OpenMS commit -m "tracker: exhaustive target pool from the winner scan's peaks (ADR-0023)"
```

---

## Task 5: Decision 11 — score an unassigned target's sweep by remaining precursor

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:164`, and the dispatch accounting at `:947-1059`
- Test: `OpenMS/src/tests/class_tests/openms/source/ProteoformTracker_Exhaustive_test.cpp` (section 8)

**Interfaces:**
- Consumes: `MS3FragmentMatcher::isKnownIonClass` (Task 3)
- Produces: nothing new — reuses the existing metric plumbing

> **TL;DR:** a CE sweep on an unassigned target can't be scored by counting fragments, because the matcher refuses to match it. Every variant would score 0, the winner would be a coin flip, and ADR-0020's close-out scan wouldn't fire — five scans, nothing learned. Scoring by *remaining precursor* instead needs no proteoform at all, and because that's a measuring metric the close-out comes free.
>
> ```
>   fragment_count on 'u':   [0][0][0][0][0] -> arbitrary winner -> NO production scan  (5 wasted)
>   remaining_precursor:     [.2][.6][.9][.7][.3] -> real winner -> production scan     (ADR-0020)
> ```

- [ ] **Step 1: Write the failing test**

Section 8, `unassigned_ms3_sweep_is_scored_by_remaining_precursor`: build a group for an unassigned target with `characterization.exploration.metric = fragment_count`; assert the resulting group's `exploration_metric` is `RemainingPrecursor`, that variants carry distinct non-zero scores, and that a post-winner production command is emitted. Assert the converse in the same section: a **mapped** target in exhaustive keeps `fragment_count`.

Add a guard section `ms2_exploration_metric_is_never_overridden`: an MS2 exploration group (`msn_level == 2`) keeps its configured metric. **This is the regression guard for four existing goldens** — see Step 3.

- [ ] **Step 2: Run to verify it fails** — CI. Expected: metric is `FragmentCount`, scores all 0.

- [ ] **Step 3: Implement the override**

`Exploration.cpp:164` is the single metric-assignment site, and `group.fragment_ion_type = ion_type` is set at `:176` in the same function:

```cpp
    // An unassigned exhaustive target (unknown ion class) cannot be scored by a READING metric --
    // the matcher refuses to project without an ion frame, so every variant scores 0 and the winner
    // is a coin flip. RemainingPrecursor scores from isolation-window intensity alone, needs no
    // proteoform, and being a MEASURING metric it also earns the ADR-0020 close-out production scan
    // with no further edit. ADR-0023 decision 11.
    //
    // msn_level >= 3 is LOAD-BEARING: initiate()'s ion_type parameter defaults to '\0' and the MS2
    // call site (FLASHIda.cpp:200) passes nothing, so an ungated test would force this metric onto
    // EVERY MS2 exploration group and move the exploration_hcd / exploration_etd /
    // exploration_followup / exploration_multiplexed goldens.
    group.exploration_metric = (msn_level >= 3 && !MS3FragmentMatcher::isKnownIonClass(ion_type))
                                 ? ExplorationMetric::RemainingPrecursor
                                 : cfg.exploration;
```

No edit at `:667` — `isMeasuringMetric(RemainingPrecursor)` is already true, so `measuring_ms3_sweep` fires and the close-out production scan is dispatched by existing code. No edit for the baseline — a CE-0 baseline is prepended to **every** group regardless of metric (`:146-150`, `needs_baseline = true`), so `computeRemainingPrecursorScore_` always has its reference.

- [ ] **Step 4: Add the dispatch half of the marker (D-e)**

At `:947-1059`, where `sub_cmds.size()` and the command count are already in hand, emit `[MS3-DISPATCH] precursor_id= targets= variants= commands=`. This is the figure that actually matters — `max_targets` bounds targets, not commands (`:942-946`).

- [ ] **Step 5: Run tests to verify they pass** — CI: `ctest -R "FLASHIda_exploration|ProteoformTracker" --output-on-failure`.

- [ ] **Step 6: Commit**

```bash
git -C OpenMS add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
  src/tests/class_tests/openms/source/ProteoformTracker_Exhaustive_test.cpp
git -C OpenMS commit -m "exploration: score an unassigned MS3 sweep by remaining precursor (ADR-0023 d11)"
```

---

## Task 6: Register the new test in all three places

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/executables.cmake:~471-472`
- Modify: `.github/workflows/flashida-ci.yml:~153-176` (the `--target` list) and `:~544` (the `ctest -R` alternation)

> **TL;DR:** three registrations or it does not run. Miss `executables.cmake` and it never builds; miss the `--target` list and it never compiles in CI; miss the `ctest -R` alternation and it builds but never executes. The `-R` alternation is the whole active set — there is no `-E` exclusion, and `-R FLASH` alone would miss this test's name entirely.

- [ ] **Step 1: `executables.cmake`** — add `ProteoformTracker_Exhaustive_test` in the same block and format as the neighbouring `ProteoformTracker_*` entries (there are five; copy one exactly).

- [ ] **Step 2: the build target list** — append to the `cmake --build ... --target` list. **The last existing entry has no trailing backslash**; add one to it when appending, or the shell line breaks.

- [ ] **Step 3: the ctest alternation** — add `|ProteoformTracker_Exhaustive` to the `-R` string.

- [ ] **Step 4: Verify all three** — `grep -n "ProteoformTracker_Exhaustive" .github/workflows/flashida-ci.yml OpenMS/src/tests/class_tests/openms/executables.cmake` must return **three** lines.

- [ ] **Step 5: Commit**

```bash
git -C OpenMS add src/tests/class_tests/openms/executables.cmake
git -C OpenMS commit -m "test: register ProteoformTracker_Exhaustive_test"
git add .github/workflows/flashida-ci.yml OpenMS
git commit -m "ci: build and run ProteoformTracker_Exhaustive_test"
```

---

## Task 7: The fixture and its golden — PUSH 2, after sign-off

**Files:**
- Create: `FlashIDA/test-data/configs/method_ms3_cytc_exhaustive.json`
- Modify: the mode→config map in `FlashIDA/src/Flash.Tests/FLASHIdaLogGolden_test.cs`
- Create: `FlashIDA/test-data/golden/logs/ms3_exhaustive_cytc/` (5 streams)

> **TL;DR:** clone the existing cytC MS3 config, change one word plus the budget, and capture the 22nd golden mode. This lands **separately**, after Push 1 is fully green and after the owner has reviewed the actual diff.

- [ ] **Step 1: Create the fixture** — clone `method_ms3_cytc_real.json` verbatim; change `characterization.mode` to `"exhaustive"`, keep `max_targets: 3`, add `min_target_mass: 0`. Change nothing else — every other difference makes the golden diff unreadable.

`max_targets: 3` is deliberate and sufficient: in the reference MS2, **2 of the top 3 masses by intensity are unassigned**, so the mode diverges from `ambiguity`/`coverage` at the smallest realistic budget. (Contrast `in_depth`, which shipped with a golden row-identical to standard DDA and a permanently `[Ignore]`d continuity test because its effect needed a contended budget the fixture never produced.)

- [ ] **Step 2: Add the mode-map entry** — one row in the C# golden test's mode→config map, directory `ms3_exhaustive_cytc`, matching the naming of `ms3_cytc` / `ms3_coverage_cytc`.

- [ ] **Step 3: Run CI and DOWNLOAD, do not write** — the run produces artifact `log-golden-capture`. Its `<mode>/<stream>.normalized` files are byte-identical to a local capture.

- [ ] **Step 4: Review the diff WITH the owner before any write**

Present, per stream: how many MS3 commands were emitted, how many carry an empty `ion_type` (the unassigned ones), and the masses they targeted. Confirm against the expectation that ~2 of every 3 targets are unassigned. **A plan-level approval is not a write approval** — this step needs explicit sign-off on the concrete diff.

- [ ] **Step 5: Promote the capture** — copy `<mode>/<stream>.normalized` → `golden/logs/ms3_exhaustive_cytc/<stream>.golden.tsv`. If `golden-write-guard.sh` blocks the write, surface the diff and get sign-off; do not route around the hook.

- [ ] **Step 6: Commit**

```bash
git -C FlashIDA add test-data/configs/method_ms3_cytc_exhaustive.json \
  test-data/golden/logs/ms3_exhaustive_cytc src/Flash.Tests/FLASHIdaLogGolden_test.cs
git -C FlashIDA commit -m "golden: ms3_exhaustive_cytc, the 22nd log golden mode (ADR-0023)"
```

---

## Task 8: The allowed-value set appears in six places

**Files:**
- Modify: `docs/adr/0023-*.md` (two factual corrections + decisions D-a…D-g + decision 11)
- Modify: `docs/adr/0013-characterization-mode-is-the-single-ms3-switch.md` — "Extended by 0023" note
- Modify: `CLAUDE.md`, `OpenMS/CLAUDE.md` — the "two on-values are the objectives" phrasing is now wrong
- Modify: `docs/method-config-options.md:72`
- Modify: `.claude/skills/validate-flashida-config/validate.py:40`

> **TL;DR:** the list of legal `mode` values is hard-stated in six files. One of them is a validator that will report a **false error** on every exhaustive config.

- [ ] **Step 1: Correct the two factual errors in ADR-0023**
  - "No ABI movement. `ScanCommand::fragment_ion_type` is already a `char`" — **there is no such member** (`grep -c` → 0). The conclusion is right, the reason is wrong, and the wrong reason points a future reader at a struct field to widen. State the real constraint: the 15-char `scan_description` budget.
  - "The 20 existing golden mode directories" — there are **21**. Golden impact is 21 → 22 directories × 5 streams.

- [ ] **Step 2: Add decision 11 and record D-a…D-g** as amendments, each with its reason.

- [ ] **Step 3: Amend decision 4's wording** — the label is `'u'`/`0` but the refusal keys on the **class**, never the index, and `'u'` never reaches the wire (D-f): unassigned MS3s take `buildMS3`'s no-ion branch and log empty `ion_type` / `ion_index = 0`.

- [ ] **Step 4: `validate.py:40`** — `MODE_VALUES = {"off", "ambiguity", "coverage", "exhaustive"}`, and teach the checker `min_target_mass`. Without this the config-validation skill rejects every valid exhaustive config.

- [ ] **Step 5: The three CLAUDE.md files are one doc set** — update the parent and `OpenMS/CLAUDE.md` in the same run. A submodule doc fix is a separate commit inside `OpenMS/` plus a gitlink bump; that friction is exactly why these drift, and it is in scope.

- [ ] **Step 6: Commit** (docs separate from code, per the working agreement)

```bash
git -C OpenMS add CLAUDE.md && git -C OpenMS commit -m "docs: characterization.mode gains exhaustive"
git add docs/ CLAUDE.md .claude/skills/validate-flashida-config/validate.py OpenMS
git commit -m "docs: ADR-0023 corrections + exhaustive in every allowed-value list"
```

---

## Ordering Constraints — non-negotiable

1. **Task 1 ∥ Task 2 must land in the SAME push.** `ToCppJson` emits every scalar unconditionally and C++ hard-rejects unknown keys. C# alone ⇒ every config fails to load. C++ alone ⇒ the key is unreachable.
2. **Task 1 before any fixture carrying `"mode": "exhaustive"`.** `Config.cpp:449-452` is the only validator of the mode string in either language, so a fixture landing alone is a hard load failure.
3. **Task 3 before Tasks 4 and 5** — both call `isKnownIonClass`.
4. **Inside `planExhaustive_`:** filters → dispatch-memory stamp → budget increment. Any other order burns a nominal mass on a target that `Exploration.cpp:950/:957` then drops, permanently.
5. **Parse before projection** — already satisfied: the mode/objective assignment is in the characterization block, `applyCharacterizationMode_` runs once at `Config.cpp:785` after every section parse, `validate()` runs last.
6. **`config_schema_reference.json` cannot be regenerated locally.** Push 1 lands with the reference-staleness test **deliberately red**, then the regenerated reference is promoted from the CI artifact in a follow-up commit. Say so in the push message so a red build is not mistaken for a regression.
7. **Push 1 = Tasks 1–6 + 8** (byte-identical; the 21 golden dirs must not move). **Push 2 = Task 7** (the new golden), after manual diff review and sign-off.

---

## Working Agreement

- **Any failure → STOP.** Do not iterate autonomously on a red build. Re-enter planning, get the fix approved, then apply it. Every fix needs approval *before* it is applied.
- **Never write a golden without showing the owner the concrete diff.** Plan-level approval ≠ write approval.
- **Fix root causes, not tests.** If a test fails, the first question is whether the engine is wrong. Never weaken an assertion to get green.
- **Adversarially review every test fix:** ask "under what bug does this now FAIL?" If there is no answer, the test is vacuous.
- **Fine-grained commits**, one logical change each, docs separate from code. Push after implementing — pushing to CI is pre-authorised.
- **A second Claude instance may share this workspace.** Check a commit's `Claude-Session:` trailer against your own before reverting anything you did not write.
- **Do not touch FLASHDeconv or FLASHTnT** (`OpenMS/CLAUDE.md`'s untouchable table). Everything under `TOPDOWN/FLASHIda/` plus `FLASHIda.{h,cpp}` is fair game.
- **No `*ForTest` hooks in production headers.** Test scaffolding lives at the test location.

---

## Pre-flight

Two workspace conditions to resolve before starting, neither caused by this work:

- `FlashIDA/test-data/golden/logs/inclusion_ms3_cytc/{ida.log,scan_results.tsv}.golden.tsv` are **modified and uncommitted**. A capture run would fold them in silently. Resolve first.
- `docs/adr/` has **no `0022-*.md`**, yet `Config.h:294` and `ProteoformTracker.h:208/229` cite ADR-0022 for the escalation ladder. This plan takes **0023** and does not fill that gap — confirm with the owner that 0022 is someone else's in-flight work.

# Test Suite False-Pass & Disabled-Test Mitigation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every FLASHIda/OpenMS test either *run* and *fail-closed*, or be *documented* as intentionally excluded — eliminate tests that report green without verifying their condition, and tests that are compiled-but-never-executed.

**Architecture:** Two failure classes were found. (1) *Tests that don't run* — C++ targets built but absent from the ctest `-R` regex, or registered in cmake but never built. (2) *Fail-open fallbacks* — guarded assertions / vacuous loops / CI verify-steps that exit 0 on a missing precondition. Each fix converts a fail-open path to fail-closed, or documents an intentional skip.

**Tech Stack:** C# NUnit (`Flash.Tests`), C++ OpenMS ctest (`TOPDOWN/FLASHIda`), PowerShell/Python regression harness, GitHub Actions (`flashida-ci.yml`).

---

## ⚠️ Working Agreement (binding for execution)

**During execution, any failure or unexpected issue → STOP immediately, re-enter plan mode, produce a new/updated plan, and obtain re-approval before continuing. No autonomous fix-iteration loops.** A "failure/issue" includes: a fix that doesn't make the test fail-closed when expected, a CI red that wasn't predicted, a finding that turns out misdiagnosed on closer reading, or any scope creep beyond a task as written.

Supporting agreements carried into this plan:
- **Build sparsely** — do not build OpenMS locally (CLAUDE.md). C++ and CI-yml changes are verified in CI. Batch work and push **once at the end** so it lands verified.
- **Realistic scenarios only** — fail-closed proofs induce a *realistic* unmet precondition (e.g. point a test at empty/wrong data), not brute-force pile-ups.
- **Plan hygiene** — as tasks complete, strip them; keep only remaining work.

---

## How this plan was produced

A 4-way parallel audit (C# / C++ / scripts / CI) followed by per-finding adversarial verification (27 agents). Counts: **7 confirmed**, **11 partial** (real but currently mitigated/lower-impact), **5 refuted** false-pass candidates; plus **6 disabled/not-run** test situations.

**Answer to "are all tests enabled?"** — No. The C# suite has zero `[Ignore]`/`[Explicit]`/commented-out tests (CT35/CT36 are CI-`--where`-excluded; CT31/CT32 self-skip only if a committed file is missing). But the **C++ side has real gaps**: `MS3FragmentMatcher_test` + `_identification_test` are *built but never run*, and `FLASHIda_ChargeBasedExclusion_test` + `ScanConfig_applyOverrides_test` are *neither built nor run* in CI.

**Answer to "any weird fallbacks that pass when the condition isn't met?"** — Yes, 7 confirmed (below). All **5 prior-audit findings are now FIXED** (`AssertGolden` Inconclusive→Fail, regression-runner stale `$LASTEXITCODE`, `SmokeTests Assert.Pass`, `ScanCommandLayout` return-0, C++ `NOT_TESTABLE;break`).

---

## Findings matrix

> Line numbers are as-of-audit (2026-06-11) and will drift as edits land; re-anchor by reading the file before editing.

### Tier P0 — Tests that don't actually run (highest priority: silent zero-coverage)

| # | Test | Location | Problem | Fix |
|---|------|----------|---------|-----|
| 1 | `MS3FragmentMatcher_test`, `MS3FragmentMatcher_identification_test` | built `flashida-ci.yml:165-166`; **absent** from `-R` regex `:463` | Compiled every CI run but ctest never selects them → all MS3 fragment-match/identification assertions are dead in CI | Add `MS3FragmentMatcher` to the `-R` alternation |
| 2 | `FLASHIda_ChargeBasedExclusion_test` | `executables.cmake:455` active; absent from build list `:153-166` **and** `-R` `:463` | Registered in cmake but CI neither builds nor runs it → charge-based-exclusion logic untested in CI | Add to build `--target` list **and** `-R` regex |
| 3 | `ScanConfig_applyOverrides_test` | `executables.cmake:465` active; absent from build list **and** `-R` | Same: covers all 17 override keys, invisible to CI | Add to build list **and** `-R` regex |

### Tier P1 — Confirmed fail-open fallbacks (green while verifying nothing)

| # | Test | Location | Why it false-passes | Sev |
|---|------|----------|---------------------|-----|
| 4 | CT02 `…CollisionEnergiesMatchConfig` | `ContinuityTests.cs:184-193` | CE membership assert gated by `if (CollisionEnergy != 0)`; the only config is all-ETD → CE always 0 → assert never runs. Test green via `results.Count>0` alone. | MED |
| 5 | CT12 `…DeepMode_MorePrecursors` | `ContinuityTests.cs:387-389` | `deepCount >= standardCount` with no `>0` floor → `0>=0` passes if engine yields zero for both. | MED |
| 6 | `FLASHIda_Logging :: join_integrity` | `FLASHIda_Logging_test.cpp:463-526` | Child-id join loop gated on non-empty `child_ids`; uses generic data + MS3-disabled config → zero MS3 → loop body never runs, section asserts nothing. | MED |
| 7 | `FLASHIda_Logging :: crash_safety_valid_tsv` | `FLASHIda_Logging_test.cpp:574,588-608` | `enable_ms3=false` makes the `if(level==3)` MS3 block unreachable; `if(level==2)` block also has no failing else → headline MS2/MS3 crash-safety checks skipped. | MED |
| 8 | CT31/CT32 stress tests | `ContinuityTests.cs:1084-1088, 1130-1134` | `if(!File.Exists(config)){ Assert.Ignore(); return; }` on a *committed* file → silent Skip (not Fail) if test-data drifts. | MED |
| 9 | CI "Verify TRACK-CREATE" | `flashida-ci.yml:419-421` | `else { Write-Host "…skipping" }` with no `exit 1` → `if:always()` step green when regression log is absent. | MED |
| 10 | CI "Verify JSON golden capture" | `flashida-ci.yml:324-337` | WARNING-only on the negative branch; structurally **cannot fail**. | LOW |

### Tier P2 — Partial / latent (real fail-open shape, currently masked)

| # | Test | Location | Gap | Sev |
|---|------|----------|-----|-----|
| 11 | CT07 `…TrackingIDs_Unique` | `ContinuityTests.cs:241-248` | Uniqueness assert gated by non-empty `ScanDescription`; no proof any description was examined. | LOW |
| 12 | CT13 strict branch | `ContinuityTests.cs:411-417` | `results.Count==0` satisfiable by *any* zero-result cause; relies on sibling branch for "precursors exist". Misleading mass comment. | LOW |
| 13 | `…scan_commands_tsv_format` | `FLASHIda_Logging_test.cpp:347-377` | 5 format columns checked under `if(col>=0)`; a header rename silently disables the semicolon-format check. | LOW |
| 14 | CI "Verify bridge smoke tests" | `flashida-ci.yml:386-402` | `exit 0` on missing `TestResults.xml`; empty node set passes; only `Failed` counted (not Error/Inconclusive). Redundant backstop today. | MED |
| 15 | `regression-runner.ps1` hygiene | `:8 / :18-20` | OutputDir never cleaned (stale TSV can be compared) + `Copy-Item -ErrorAction SilentlyContinue` swallows missing support files. | LOW |
| 16 | CI regression `Tee-Object` | `flashida-ci.yml:376` | Exit code propagates today but only via the GHA epilogue; one careless trailing native command masks it. | LOW |
| 17 | BridgePhase3 `P3_I05_DllExports` | `BridgePhase3Tests.cs:120-141` | `Assert.DoesNotThrow` only — no return-value checks; references a CI `dumpbin` step that doesn't exist. | LOW |

### Tier P3 — Documentation drift (misleading, invites future fail-open)

| # | Where | Drift |
|---|-------|-------|
| 18 | parent `CLAUDE.md` (Testing section) | Documents `ctest … -E "FLASHIda_ProcessScan\|FLASHIda_exploration\|FLASHIda_Logging"` — that `-E` no longer exists; all three now run. Also warns MS3FragmentMatcher is missed by `ctest -R FLASH` — true of the live CI `-R` until Task 1 lands. |
| 19 | `ContinuityTests.cs:67-70` & `GoldenCaptureTests.cs:9-12` | `AssertGolden` doc still says "mark Inconclusive for first-run capture" (code now `Assert.Fail`). `GoldenCaptureTests` class doc claims "Always pass" (bodies now hard-assert). |

### Refuted / already-fixed (checked and cleared — no action)

| Candidate | Verdict |
|-----------|---------|
| `AssertGolden` Inconclusive-on-missing-golden | **FIXED** → `Assert.Fail` (`ContinuityTests.cs:89`) |
| `regression-runner` stale `$LASTEXITCODE` | **FIXED** (resets `$global:LASTEXITCODE` per iter) |
| `SmokeTests` unconditional `Assert.Pass()` | **GONE** (no `Assert.Pass` anywhere) |
| `ScanCommandLayout` return-0 success | **FIXED** (pure `TEST_EQUAL`) |
| C++ `NOT_TESTABLE;break` early-outs | **GONE** (FLASH guard is `ABORT_IF`, fail-closed) |
| CT34 conditional follow-up loop | Correctly guarded (`Count>0` before loop) |
| CT32 concurrency `catch`→bag | Correct pattern (`Assert.IsEmpty(exceptions)` after Join) |
| CI regression `Tee-Object` *masks exit* (strong claim) | Refuted — exit code propagates; see #16 for the residual fragility |

---

## ❓ Decisions needed before/at execution

**D1 — CT35 / CT36 (flaky MS3 continuity, CI-`--where`-excluded).** Real tests with committed goldens (`continuity_ms3_mode{1,2}_real.json`); excluded for data-dependent MS3 flakiness, reason lives only in CLAUDE.md/memory, not the YAML.
- *Option A (recommended, low-cost):* annotate the `--where` line with an inline reason + tracking link now; file a follow-up to re-stabilize and re-enable later.
- *Option B:* re-stabilize the MS3 goldens now and drop the exclusion (larger, data-capture work).

**D2 — Commented-out C++ targets in `executables.cmake`.** `# DeconvolvedSpectrum_test` (`:450`) is unexplained (superseded by `DeconvolvedSpectrum_OptimizationMetadata_test`?). `# FIAMSScheduler_test`, `# FLASHDeconvAlgorithm_test`, `# FLASHDeconvHelperStructs_test`, `# FLASHTaggerAlgorithm_test` (`:476-479`) are plausibly out-of-FLASH-bridge-scope but undocumented.
- *Recommended:* add a one-line `# intentionally excluded: <reason>` next to each; for `DeconvolvedSpectrum_test`, confirm the OptimizationMetadata variant subsumes its assertions before leaving it disabled (else restore).

These don't block P0–P3; resolve them when scheduling P0 (CI) and the cmake edits.

---

# Mitigation Tasks

Recommended minimum = **P0 + P1**. P2 = hardening, P3 = hygiene.

Convention: each fix flags the offending line with `// ISSUE:` (or `# ISSUE:`). Each fix has a **fail-closed proof**: induce a realistic unmet precondition and confirm the test now goes RED, then revert and confirm GREEN.

---

## Task 1: Run the built-but-unexecuted MS3FragmentMatcher tests

**Files:** Modify `.github/workflows/flashida-ci.yml:463`

- [ ] **Step 1: Add `MS3FragmentMatcher` to the ctest `-R` alternation.** The targets are already built (`:165-166`); the run filter just omits them.

```yaml
# .github/workflows/flashida-ci.yml — "Run FLASH C++ unit tests" (line 463)
# ISSUE: -R regex omits MS3FragmentMatcher, so the two built targets never execute.
run: ctest --test-dir OpenMS/build -R "DeconvolvedSpectrum_OptimizationMetadata|FLASHIdaQueueTracking|FLASHIda_ProcessScan|ScanCommandLayout|FLASHIdaFAIMS|FLASHIda_exploration|FLASHIda_LegacyConfig|FLASHIda_Logging|ScanCommandQueue_Concurrent|FragmentAnalysis|MS3FragmentMatcher" --output-on-failure
```

- [ ] **Step 2: Fail-closed proof (in CI).** After push, confirm the CI log lists `MS3FragmentMatcher_test` and `MS3FragmentMatcher_identification_test` as run (test count rises by 2). Optional local sanity if a build already exists: `ctest --test-dir OpenMS/build -R MS3FragmentMatcher --output-on-failure` shows 2 tests, not "No tests were found".

---

## Task 2: Build + run FLASHIda_ChargeBasedExclusion_test

**Files:** Modify `.github/workflows/flashida-ci.yml:153-166` (build list) and `:463` (`-R`)

- [ ] **Step 1: Add to the build `--target` list** (after `MS3FragmentMatcher_identification_test`, keep the `\` continuations correct):

```yaml
# flashida-ci.yml:153-166 — cmake --build … --target …
            MS3FragmentMatcher_test \
            MS3FragmentMatcher_identification_test \
            FLASHIda_ChargeBasedExclusion_test          # ADDED (executables.cmake:455, was never built)
```

- [ ] **Step 2: Add to the `-R` regex** (line 463, appended to the Task 1 alternation): `…|MS3FragmentMatcher|FLASHIda_ChargeBasedExclusion`

- [ ] **Step 3: Fail-closed proof (CI).** CI build log shows the new target compiling; ctest log shows `FLASHIda_ChargeBasedExclusion_test` running its CBE-01..CBE-06 sections. (The test body is already fail-closed — `ABORT_IF` on empty data, hard `TEST_EQUAL` on counts.)

---

## Task 3: Build + run ScanConfig_applyOverrides_test

**Files:** Modify `.github/workflows/flashida-ci.yml:153-166` and `:463`

- [ ] **Step 1: Add to the build list:**

```yaml
            FLASHIda_ChargeBasedExclusion_test \
            ScanConfig_applyOverrides_test              # ADDED (executables.cmake:465, was never built)
```

- [ ] **Step 2: Add to the `-R` regex:** `…|FLASHIda_ChargeBasedExclusion|ScanConfig_applyOverrides`

- [ ] **Step 3: Fail-closed proof (CI):** ctest log shows `ScanConfig_applyOverrides_test` running (all 17 override keys asserted).

---

## Task 4: CT02 — assert the collision-energy/activation contract (never zero assertions)

**Files:** Modify `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:170-195`

- [ ] **Step 1: Replace the vacuous guarded loop** so the test always verifies something about CE for the configured activation. The default config is ETD → the contract is "MS2 is ETD with CE==0"; for any non-zero configured CE, require at least one non-zero CE result before the membership check.

```csharp
var ms2 = results.Where(r => r.MsnLevel == 2).ToList();
Assert.That(ms2, Is.Not.Empty, "Expected at least one MS2 command");

bool anyConfiguredCe = configuredEnergies.Any(e => e != 0);
if (!anyConfiguredCe)
{
    // ETD/ReactionTime config: assert the engine emitted no collision energy (positive contract)
    foreach (var r in ms2)
        Assert.That(r.CollisionEnergy, Is.EqualTo(0),
            "ETD MS2 must not carry a collision energy");
}
else
{
    // HCD/CID config: require the membership check to actually run
    Assert.That(ms2.Any(r => r.CollisionEnergy != 0), Is.True,
        "Expected at least one non-zero collision energy for an HCD/CID config");
    foreach (var r in ms2.Where(r => r.CollisionEnergy != 0))
        Assert.That(configuredEnergies, Has.Member(r.CollisionEnergy),
            string.Format("Collision energy {0} not in configured values [{1}]",
                r.CollisionEnergy, string.Join(",", configuredEnergies)));
}
// ISSUE(was): the old `foreach(...) if (r.CollisionEnergy != 0) Assert...` ran ZERO asserts for the all-ETD default config.
```

- [ ] **Step 2: Fail-closed proof.** Temporarily change the test config to one whose MS2 is HCD with a CE *not* in the configured set (or stub a result with a bogus CE); confirm CT02 now FAILS. Revert; confirm PASS. Run: `nunit3-console.exe FlashIDA\bin\Flash.Tests.dll --where "test=='Flash.Tests.AcquisitionLoop.ContinuityTests.P0_AL_CT02_StandardDDA_CollisionEnergiesMatchConfig'"`

- [ ] **Step 3: Commit** (batched — see "Execution & verification").

---

## Task 5: CT12 — add a non-zero floor so deep-mode comparison isn't vacuous

**Files:** Modify `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:385-389`

- [ ] **Step 1: Assert `standardCount > 0` before the comparison** (matches CT01/CT03/CT11 which were already promoted from Assume→Assert):

```csharp
Assert.That(standardCount, Is.GreaterThan(0),
    "Standard DDA must produce at least one MS2 command for the smoke spectrum");
// ISSUE(was): only `Assert.That(deepCount, Is.GreaterThanOrEqualTo(standardCount))` — 0>=0 passed vacuously.
Assert.That(deepCount, Is.GreaterThanOrEqualTo(standardCount),
    string.Format("Deep mode ({0}) should produce >= standard DDA ({1}) MS2 scans", deepCount, standardCount));
```

- [ ] **Step 2: Fail-closed proof.** Point the standard run at empty/noise data (e.g. a fixture that yields 0 precursors); confirm CT12 now FAILS at the new floor instead of passing `0>=0`. Revert; confirm PASS.

---

## Task 6: FLASHIda_Logging join_integrity — exercise a real MS3 graph and prove it ran

**Files:** Modify `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp:463-526`

- [ ] **Step 1: Use MS3-capable cytC data + enable MS3, then hard-assert children exist and the loop executed.** Mirror the already-hardened sibling sections (`scan_commands_tsv_format` lines 311-312/380-381).

```cpp
// Inputs: switch to the cytC pair the MS3 siblings use (was generic ms1_standard/ms2_hcd_fragment -> zero MS3)
auto cycle = runFullCycle(ms1_cytc_path, ms2_cytc_fresh_scan57_path,
                          buildJsonWithRuntime("", commands_file, results_file, /*enable_ms3=*/true));

TEST_TRUE(cycle.ms3_cmds.size() > 0);           // ADDED: MS3 must actually have been produced
TEST_TRUE(!cmd_ids.empty());                    // ADDED: command id set non-empty

bool checked_any_child = false;
for (const auto& row : res_tsv.rows)
{
  if (child_col >= 0 && child_col < (int)row.size() && !row[child_col].empty())
  {
    std::istringstream child_ss(row[child_col]); std::string child_id; int child_count = 0;
    while (std::getline(child_ss, child_id, ';')) { TEST_TRUE(cmd_ids.count(child_id) > 0); child_count++; }
    if (pushed_col >= 0 && pushed_col < (int)row.size()) TEST_EQUAL(std::stoi(row[pushed_col]), child_count);
    checked_any_child = true;                    // ADDED
  }
}
TEST_TRUE(checked_any_child);                    // ADDED: fail if no child_ids row was ever validated
// ISSUE(was): generic data + MS3 off => every child_ids cell empty => join loop never ran => section passed asserting nothing.
```

- [ ] **Step 2: Fail-closed proof (CI).** With the fix, a regression that stops MS3 emission turns this section RED (the `ms3_cmds>0`/`checked_any_child` guards). Verify the section runs and passes in the CI ctest log; confirm it is NOT reported with 0 sub-checks.

---

## Task 7: FLASHIda_Logging crash_safety_valid_tsv — force MS2 then MS3 and assert their levels

**Files:** Modify `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp:530-608`

- [ ] **Step 1: Enable MS3 + cytC data; replace conditional `if(level==2)`/`if(level==3)` with positive expectations** (drain leading idle AGC first):

```cpp
auto json = buildJsonWithRuntime("", commands_file, results_file, /*enable_ms3=*/true);   // was false
// ...feed ms1_cytc + ms2_cytc_fresh_scan57 (was generic ms2_tsv_path)...

int n = ida.processScan(/* MS1 */ ...);
TEST_TRUE(n > 0);                                   // ADDED: MS1 yielded precursors

ScanCommand cmd; drainPastAgc(ida, cmd);            // helper: skip msn_level==1 idle commands
TEST_EQUAL(cmd.msn_level, 2);                       // was: if (cmd.msn_level == 2) { ... }  // ISSUE: no failing else
{ auto t = TSVFile::parse(results_file); for (auto& row : t.rows) TEST_EQUAL(row.size(), t.headers.size()); }

ScanCommand ms3_cmd; TEST_TRUE(ida.getNextScanCommand(ms3_cmd) > 0); drainPastAgc(ida, ms3_cmd);
TEST_EQUAL(ms3_cmd.msn_level, 3);                   // was: if (getNext>0 && level==3) { ... }  // ISSUE: unreachable with MS3 off
{ auto t = TSVFile::parse(results_file); for (auto& row : t.rows) TEST_EQUAL(row.size(), t.headers.size()); }
```

- [ ] **Step 2:** If a `drainPastAgc` helper doesn't already exist in the file, add a small static local that loops `getNextScanCommand` while `msn_level == 1`. Keep it local to the test.

- [ ] **Step 3: Fail-closed proof (CI):** section now executes the MS3 crash-safety path; a regression that drops MS3 fails `TEST_EQUAL(ms3_cmd.msn_level, 3)`. Verify in CI ctest log.

---

## Task 8: CT31/CT32 — fail (not skip) on a missing committed config

**Files:** Modify `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:1084-1088, 1130-1134`

- [ ] **Step 1: Replace `Assert.Ignore` with a hard failure** in both tests (the file is a committed, required fixture):

```csharp
string configPath = Path.Combine(configsDir, "method_default.json");
// ISSUE(was): if (!File.Exists(configPath)) { Assert.Ignore("method_default.json not found"); return; }  // Skip != Fail
Assert.That(File.Exists(configPath), Is.True,
    $"REQUIRED committed config missing: {configPath} (test-data layout drift is a failure, not a skip)");
```

(Equivalently: delete the existence check and let `MethodParameters.Load(configPath)` throw `FileNotFoundException` — the rest of the file already relies on that.)

- [ ] **Step 2: Fail-closed proof.** Temporarily rename `method_default.json`; confirm CT31 and CT32 report **Failed** (not Ignored). Restore; confirm Pass.

---

## Task 9: CI "Verify TRACK-CREATE" — fail on missing regression log

**Files:** Modify `.github/workflows/flashida-ci.yml:407-421`

- [ ] **Step 1: Make the missing-log branch fail-closed:**

```powershell
$regressionLog = "FlashIDA\test-output\regression-stdout.txt"
# ISSUE(was): else { Write-Host "…skipping TRACK verification." }  -> step exits 0 with nothing verified
if (-not (Test-Path $regressionLog)) {
    Write-Host "FAIL: regression stdout log not found ($regressionLog) — regression step did not run/produce output."
    exit 1
}
$trackLines = Select-String -Path $regressionLog -Pattern "\[TRACK-CREATE\]"
Write-Host "Found $($trackLines.Count) [TRACK-CREATE] entries."
if ($trackLines.Count -eq 0) { Write-Host "FAIL: zero [TRACK-CREATE] entries."; exit 1 }
```

- [ ] **Step 2: Fail-closed proof (CI):** logic review — both missing-log and zero-entry paths `exit 1`. (No realistic local repro needed; the predecessor regression step normally produces the log.)

---

## Task 10: CI "Verify JSON golden capture" — make it able to fail (or delete it)

**Files:** Modify `.github/workflows/flashida-ci.yml:324-337`

- [ ] **Step 1:** Either (a) make it fail-closed, mirroring the `:347-359` data-verify step, or (b) delete it as redundant (the `GoldenCaptureTests` NUnit tests already hard-assert and fail the job). Recommended (a):

```powershell
$jsonDir = "FlashIDA\test-output\json"
$missing = @()
foreach ($f in 'config_default.json','config_full.json') {
    if (Test-Path "$jsonDir\$f") { Write-Host "$f captured" } else { $missing += $f }
}
# ISSUE(was): else { Write-Host "WARNING: … not captured" } with no exit -> step could never fail
if ($missing.Count) { Write-Host "ERROR: JSON golden(s) not captured: $($missing -join ', ')"; exit 1 }
```

- [ ] **Step 2: Fail-closed proof (CI):** logic review confirms `exit 1` on a missing artifact.

---

## Task 11 (P2): CT07 — prove the uniqueness loop examined data

**Files:** `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:241-248`

- [ ] **Step 1:** After the loop, require every MSn result to carry a description and all to be distinct:

```csharp
int checkedCount = results.Count(r => !string.IsNullOrEmpty(r.ScanDescription));
// ISSUE(was): uniqueness only checked inside `if (!IsNullOrEmpty(...))`; nothing proved a description was ever seen.
Assert.That(checkedCount, Is.EqualTo(results.Count),
    $"Every MSn command must carry a tracking-ID description; {checkedCount}/{results.Count} were non-empty");
Assert.That(allDescriptions.Count, Is.EqualTo(results.Count),
    "All scan descriptions (tracking IDs) must be unique across 1000 scans");
```

- [ ] **Step 2: Fail-closed proof.** Stub one result with empty `ScanDescription`; confirm FAIL. Revert.

---

## Task 12 (P2): CT13 strict — prove precursors existed before asserting they were suppressed

**Files:** `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:400-417`

- [ ] **Step 1:** Establish a positive baseline in the same test, then assert strict==0; fix the misleading mass comment.

```csharp
int baseline;
using (var h = CreateHarness("method_inclusion.json")) baseline = PushSmokeSpectrumAndCollect(h).Count;
Assert.That(baseline, Is.GreaterThan(0), "precondition: spectrum yields precursors when not strict");
using (var harness = CreateHarness("method_inclusion_strict.json"))
{
    var results = PushSmokeSpectrumAndCollect(harness);
    // ISSUE(was): EqualTo(0) alone is satisfied by ANY zero-result cause (e.g. dead deconvolution), not just strict filtering.
    Assert.That(results.Count, Is.EqualTo(0),
        $"strict inclusion must suppress the {baseline} non-target precursors");
}
```

- [ ] **Step 2: Fail-closed proof.** If strict mode ever throws/returns empty for a *non-filtering* reason while the baseline is 0, the precondition now fails. Verify baseline>0 holds, strict==0 holds.

---

## Task 13 (P2): scan_commands_tsv_format — hard-assert the format columns exist

**Files:** `OpenMS/src/tests/class_tests/openms/source/FLASHIda_Logging_test.cpp:330-377`

- [ ] **Step 1:** After the existing header hard-checks (`:330-336`), assert the 5 format columns are present, then index them unconditionally:

```cpp
for (const char* c : {"charge","activation","precursor_mz","isolation_width","collision_energy"})
  TEST_TRUE(tsv.colIndex(c) >= 0);     // ADDED: a dropped/renamed column now fails here…
// …so the per-row checks no longer need the `if (col >= 0)` guard that silently skipped them.  // ISSUE(was)
```

- [ ] **Step 2: Fail-closed proof (CI):** review — a renamed column fails the new presence assert. (`row.size()==headers.size()` at `:386` already guards bounds.)

---

## Task 14 (P2): CI "Verify bridge smoke tests" — fail-closed + min-count + non-Passed

**Files:** `.github/workflows/flashida-ci.yml:386-402`

- [ ] **Step 1:**

```powershell
$ErrorActionPreference = 'Stop'
# ISSUE(was): if (-not (Test-Path TestResults.xml)) { …; exit 0 }   -> missing results = green
if (-not (Test-Path TestResults.xml)) { Write-Host "ERROR: TestResults.xml not found."; exit 1 }
$results = [xml](Get-Content TestResults.xml)
$tier2 = $results.SelectNodes("//test-case[contains(@classname,'BridgeSmokeTests')]")
if ($tier2.Count -lt 1) { Write-Host "ERROR: zero BridgeSmokeTests cases found."; exit 1 }   # ADDED
$bad = $tier2 | Where-Object { $_.result -ne 'Passed' }   # was: -eq 'Failed' only
if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host "FAIL: $($_.name) = $($_.result)" }; exit 1 }
Write-Host "Bridge smoke tests passed ($($tier2.Count) cases)."
```

- [ ] **Step 2: Fail-closed proof (CI):** review — missing file, empty set, and any non-Passed outcome all `exit 1`.

---

## Task 15 (P2): regression-runner.ps1 — clean OutputDir + freshness + strict copies

**Files:** `FlashIDA/test-scripts/regression-runner.ps1:8, 18-20, ~171-183`

- [ ] **Step 1: Clean OutputDir at startup (non-capture mode) and assert per-case freshness** before comparing:

```powershell
# near line 8
if (-not $captureMode -and (Test-Path $OutputDir)) { Remove-Item -Recurse -Force $OutputDir }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
# in the per-case loop, after the Flash.exe exit-code check, before compare_golden.py:
if (-not (Test-Path $outputFile)) { Write-Host "FAIL: no output produced"; $failures++; continue }   # ISSUE(was): only python's FileNotFoundError caught a stale/missing actual
if ((Get-Item $outputFile).Length -eq 0) { Write-Host "FAIL: empty output"; $failures++; continue }
```

- [ ] **Step 2: Make support-file staging fail-closed** (lines 18-20):

```powershell
$configDir = Join-Path $TestDataDir "configs"
foreach ($f in @("test_inclusion_list.txt","test_fasta.fasta","test_target_log.log")) {
    $src = Join-Path $configDir $f
    if (-not (Test-Path $src)) { Write-Host "FAIL: required support file missing: $src"; exit 1 }
    Copy-Item $src . -Force -ErrorAction Stop   # ISSUE(was): -ErrorAction SilentlyContinue swallowed a missing source
}
```

- [ ] **Step 3: Fail-closed proof.** Run `regression-runner.ps1` with one support file temporarily renamed → expect immediate `exit 1`. Restore; full run passes. Run: `powershell FlashIDA\test-scripts\regression-runner.ps1 -FlashExe FlashIDA\bin\Flash.exe -TestDataDir FlashIDA\test-data -OutputDir FlashIDA\test-output`

---

## Task 16 (P2): CI regression step — assert the child exit code explicitly

**Files:** `.github/workflows/flashida-ci.yml:376`

- [ ] **Step 1:** Re-assert `$LASTEXITCODE` after the pipe instead of relying on the GHA epilogue:

```powershell
powershell FlashIDA\test-scripts\regression-runner.ps1 -FlashExe FlashIDA\bin\Flash.exe -TestDataDir FlashIDA\test-data -OutputDir FlashIDA\test-output *>&1 | Tee-Object -FilePath FlashIDA\test-output\regression-stdout.txt
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }   # ADDED: explicit, robust against a future trailing native command
```

(Note `*>&1` also captures the information/Write-Host stream so the TRACK-CREATE log is always materialized — reinforces Task 9.)

- [ ] **Step 2: Fail-closed proof (CI):** review — a non-zero runner exit now propagates explicitly.

---

## Task 17 (P2, optional): BridgePhase3 P3_I05 — assert behavior, not just resolution

**Files:** `FlashIDA/src/Flash.Tests/BridgePhase3Tests.cs:120-141`

- [ ] **Step 1:** Replace `Assert.DoesNotThrow`-only with return-value assertions, and remove the dead "CI dumpbin step" comment (no such step exists):

```csharp
Assert.That(ProcessScan(nativePtr, mzs, ints, 1, 1.0, 1, "export_test"), Is.EqualTo(0));   // enqueue OK
// (similar concrete assertions for GetNextScanCommand / GetNextTrackingId per their contracts)
// ISSUE(was): DoesNotThrow proves only that the P/Invoke resolved, not that the export does anything correct.
```

- [ ] **Step 2: Fail-closed proof.** Local NUnit run of `P3_I05_DllExports_IncludeNewFunctions` passes with the stronger asserts.

---

## Task 18 (P3): Fix stale CLAUDE.md testing guidance

**Files:** `CLAUDE.md` (parent, Testing → OpenMS ctest section)

- [ ] **Step 1:** Remove the obsolete `-E "FLASHIda_ProcessScan|FLASHIda_exploration|FLASHIda_Logging"` example (those run now). Update the "`ctest -R FLASH` misses MS3FragmentMatcher_*" note to reflect that the CI `-R` regex now includes `MS3FragmentMatcher` (post-Task 1) and lists `FLASHIda_ChargeBasedExclusion` + `ScanConfig_applyOverrides` (post-Tasks 2-3).

---

## Task 19 (P3): Fix misleading test docstrings

**Files:** `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:67-70`; `FlashIDA/src/Flash.Tests/GoldenCaptureTests.cs:9-12`

- [ ] **Step 1:** `AssertGolden` doc → describe current fail-closed behavior ("missing golden ⇒ `Assert.Fail`", not "Inconclusive for first-run capture").
- [ ] **Step 2:** `GoldenCaptureTests` class doc → drop "Always pass"; state it asserts the rendered config contains `deconvolution` + `precursor_selection` and writes the artifact.

---

## Execution & verification

- **Order:** P0 (1-3) → P1 (4-10) → P2 (11-17) → P3 (18-19). P0 and the C# P1/P2 changes are independently testable; C++ and CI-yml changes verify only in CI.
- **Local C# runs** (where the bin already exists):
  `FlashIDA\src\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe FlashIDA\bin\Flash.Tests.dll --where "test=='<full.test.name>'"` (set `OPENMS_DATA_PATH` per CLAUDE.md).
- **Do NOT build OpenMS locally.** C++ test changes (Tasks 6,7,13) and all CI-yml changes (1-3,9,10,14,16) are validated by the single CI push.
- **Push once at the end** of the run so everything lands verified in one green CI cycle. If CI comes back red on anything not predicted by a task's fail-closed proof → **invoke the Working Agreement** (STOP, re-plan, re-approve).

## Self-review (done)

- **Coverage:** every confirmed finding (4-10) and the three not-run gaps (1-3) has a task; partials (11-17) and docs (18-19) tiered separately; refuted items explicitly excluded with rationale.
- **No placeholders:** each code step shows the actual change and flags the defect with `// ISSUE` / `# ISSUE`.
- **Consistency:** `-R` regex edits in Tasks 1-3 are additive to the same line 463 alternation (apply in order, or combine into one edit: append `|MS3FragmentMatcher|FLASHIda_ChargeBasedExclusion|ScanConfig_applyOverrides`); build-list edits in Tasks 2-3 target the same `:153-166` block.
- **Open decisions:** D1 (CT35/CT36) and D2 (commented-out cmake targets) are flagged, not silently resolved.

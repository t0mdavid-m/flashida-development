# Phase 3 — Lessons Learned

**Date:** 2026-03-29
**CI runs to green:** 4 (3 fixes required after initial push)

---

## 1. Struct Size Arithmetic — Verify Layout Before Writing Code

**Issue:** The implementation plan specified `IsolationStage` = 80 bytes and `ScanCommand` = 1144 bytes, with `activation_type[16]` in both structs. The arithmetic doesn't work: 8×int32 (32) + 3×double (24) + char[32] + char[256] + char[16] + 10×80 = 1160, not 1144. The plan had a 16-byte arithmetic error.

**Resolution:** Removed `activation_type[16]` from `ScanCommand` (redundant with per-stage `IsolationStage.activation_type`) and enlarged `IsolationStage.activation_type` from `char[16]` to `char[32]`. This gives IsolationStage = 5×double(40) + 2×int32(8) + char[32](32) = 80, and ScanCommand = 32 + 24 + 32 + 256 + 10×80 = 1144. Both `static_assert` checks pass.

**Action for future phases:** When a plan specifies struct sizes, independently verify the arithmetic before writing code. Compute `sum of field sizes + alignment padding` and confirm it matches the stated total. Pay special attention to char array sizes and tail padding from struct alignment.

---

## 2. OpenMS ClassTest Framework — `ABORT_IF(true)` Counts as Failure

**Issue:** The plan specified `ABORT_IF(true)` for deferred test stubs (P3-U08, P3-U09). In the OpenMS ClassTest framework, `ABORT_IF(true)` aborts the section and marks it as **failed**, not skipped. CTest reports the entire test binary as failed if any section fails.

**Resolution:** Replaced `ABORT_IF(true)` with `NOT_TESTABLE`, which marks the section as intentionally not tested and passes cleanly.

**Available OpenMS ClassTest skip mechanisms:**
- `NOT_TESTABLE` — marks section as intentionally untested (passes)
- `STATUS("message")` — prints a message but still requires assertions
- `ABORT_IF(condition)` — aborts section, counts as **failure** if condition is true

**Action for future phases:** Use `NOT_TESTABLE` for deferred test stubs. Reserve `ABORT_IF` for precondition checks where failure means the test environment is broken.

---

## 3. `dumpbin` Not on PATH in GitHub Actions Windows Runners

**Issue:** The CI step `dumpbin /exports OpenMS.dll` failed with "The term 'dumpbin' is not recognized." The `microsoft/setup-msbuild@v2` action adds MSBuild to PATH but does NOT set up the full Visual Studio developer command environment.

**Resolution:** Use `cmd` shell (not PowerShell) and call `vcvars64.bat` first:
```yaml
shell: cmd
run: |
  call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
  dumpbin /exports FlashIDA\bin\OpenMS.dll > dll_exports.txt 2>&1
```

**Action for future phases:** Any CI step that uses MSVC tools (`dumpbin`, `cl.exe`, `link.exe`, `lib.exe`) must first source `vcvars64.bat`. The path includes the VS edition (`Enterprise` on GitHub-hosted runners).

---

## 4. DLL Rebuild Has Its Own CI Workflow

**Issue:** The implementation plan assumed OpenMS.dll must be rebuilt manually on Windows. In practice, the OpenMS repo has a `build_dlls.yml` workflow that triggers automatically on push to `flashida-v9-bridge` and produces a `selected-bin-artifacts` artifact containing the built DLLs.

**Resolution:** Downloaded the artifact from the `build-dlls` workflow run (triggered by our C++ push), extracted `OpenMS.dll`, and committed it to `FlashIDA/dll/`. No manual Windows build needed.

**Workflow:** `gh run download <run-id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts`

**Action for future phases:** After pushing C++ changes to `flashida-v9-bridge`, check the `build-dlls` workflow in the OpenMS repo. Download the DLL artifact once the workflow succeeds. This replaces the manual Windows build step entirely.

---

## 5. New DLL Exports Require Staged Test Activation

**Issue:** C# code was committed with `[DllImport]` declarations for 3 new exports (`ProcessScan`, `GetNextScanCommand`, `GetNextTrackingId`), but the pre-built `OpenMS.dll` in the repo didn't have those exports yet. Tests calling these functions would throw `EntryPointNotFoundException`.

**Resolution:** Two-phase approach:
1. First commit: Add `[Ignore("Requires Phase 3 OpenMS.dll")]` to `BridgePhase3Tests` fixture and `CT31`/`CT32`. Shadow validation in processors already had try/catch, so those calls fail silently.
2. Second commit (after DLL update): Remove `[Ignore]`, promote DLL export check to hard failure.

**Action for future phases:** When adding new bridge exports:
1. Commit C# code with new tests `[Ignore]`d and new P/Invoke calls wrapped in try/catch
2. Wait for `build-dlls` workflow to produce updated DLL
3. Download and commit updated DLL
4. Remove `[Ignore]` guards and activate hard export verification
5. Shadow validation calls in processors should always be try/catch guarded regardless

---

## 6. Non-Strict vs Strict Inclusion — Test Both Modes

**Issue:** CT13 was strengthened to assert that all precursor masses match the inclusion list. This failed because the test config uses `StrictInclusion=false` (non-strict mode), which allows non-target masses to fill remaining slots when no inclusion targets match the spectrum.

**How inclusion works in the C++ engine:**
- **Non-strict** (`strict_inclusion_=false`): Phase 0 selects targets, Phase 1 fills remaining slots with non-targets. If no targets match, all results are non-target fill-ins.
- **Strict** (`strict_inclusion_=true`): Only inclusion-list masses are selected. If no targets match, zero results are returned.

**Resolution:** CT13 now tests both modes:
- Non-strict (existing `method_inclusion.xml`): Assert results are produced (non-target fill-ins)
- Strict (new `method_inclusion_strict.xml`): Assert zero results when no targets match the spectrum

**Action for future phases:** When testing modes with sub-options (strict/non-strict, conditional/unconditional), always test both variants. Create separate config files rather than modifying the existing one.

---

## 7. `gh run watch --exit-status` Returns Non-Zero After Run Completes

**Issue:** Background `gh run watch --exit-status` commands consistently reported "failed" even when the CI run succeeded. This is because the command exits with the run's conclusion status, and when polled after completion, it may return a transient error or the exit code from a failed intermediate state.

**Not a real problem:** The command is a convenience for blocking until completion. Always verify the actual run status with `gh run view <id> --json conclusion` rather than trusting the exit code of `gh run watch`.

---

## 8. Plan Discrepancies Caught During Implementation

The implementation plan included a "Critical Discrepancies" section (D1–D8) identified during planning. All were handled correctly. Additional discrepancies found during implementation:

| # | Plan Says | Actual | Resolution |
|---|-----------|--------|------------|
| D9 | `activation_type[16]` in both structs, totaling (80, 1144) | Arithmetic impossible: 360 + 10×80 = 1160 | Removed from ScanCommand, enlarged to char[32] in IsolationStage |
| D10 | `ABORT_IF(true)` for deferred stubs | Counts as test failure | Used `NOT_TESTABLE` instead |
| D11 | `dumpbin /exports` in PowerShell | dumpbin not on PATH | Use cmd shell with vcvars64.bat |
| D12 | Manual Windows DLL rebuild | build-dlls workflow exists | Download artifact from CI |

---

## Summary of CI Fix Iterations

| Run | Issue | Fix |
|-----|-------|-----|
| 1 (23704202808) | CT13 assertion too strict (non-strict inclusion), C++ ABORT_IF stubs failed, dumpbin step fatal | — |
| 2 (23704706172) | CT13 fixed, dumpbin still fatal (warning-only fix not yet pushed alongside) | — |
| 3 (23705016008) | dumpbin "not recognized" (PowerShell, no vcvars) | — |
| 4 (23705301481) | **All green** — dumpbin via cmd+vcvars, warning-only, CT13 two-mode test, NOT_TESTABLE stubs |
| 5 (23706052741) | **All green** — DLL updated, all tests activated, hard export check |
| 6 (23706815241) | **All green** — golden file committed, final state |

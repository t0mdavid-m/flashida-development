# 0012. FAIMS enablement is explicit

Status: Accepted (2026-08-07). Adds a field to the `ScanCommand` ABI; see
[ADR-0011](0011-source-region-parameters-are-survey-scoped.md) for the change it shipped with.

## Context

`Config.cpp` set `faims_.enabled = (cv_values.size() > 1)`. That answers *"is there more than one
CV to rotate between?"* and then uses the answer for a different question: *"is FAIMS in use?"*

A method with one configured CV — an ordinary fixed-CV FAIMS run — therefore reported no FAIMS.
`getNextScanCommand` stamped `faims_cv = 0.0`, `ScanFactory`'s `Math.Abs(cmd.FaimsCv) > 0.001` test
failed, and neither `FAIMS CV` nor `FAIMS Voltages` was sent. The run acquired at whatever FAIMS
state the instrument method happened to carry.

Two further consequences of inferring intent from the CV magnitude:

- **A compensation voltage of exactly 0 was unexpressible**, being indistinguishable from "no
  FAIMS". The same guard-family defect as `source_cid_scaling`.
- **FLASHIda could command FAIMS on but never off.** The `if` had no `else`, so a non-FAIMS run
  sent nothing and the instrument stayed as it was. Pre-port code sent `FAIMS_Voltages = "off"`
  explicitly (`Flash.cs@cd0d086:287`); the port dropped it.

27 of the 31 committed test configs and the shipped `etc/method.json` carried a single-element
`cv_values` — `[-50]` boilerplate, `[0]` in production — none of which is a FAIMS test and none of
which ever ran FAIMS. 51 inline C++ test configs did the same. `FLASHIdaFAIMS_test`'s own
"non-FAIMS" fixture was `[-50]`, with a comment reading *"single CV => faims_enabled_=false"*: the
suite had encoded the conflation as the way to express "no FAIMS".

## Decision

**An empty `cv_values` is the only way to say "no FAIMS".** Enablement and cycling are separate
questions:

| `cv_values` | `isEnabled()` | `isCycling()` | Behaviour |
|---|---|---|---|
| `[]` | false | false | `FAIMS Voltages = "off"` is commanded |
| `[0]` | true | false | FAIMS on at CV 0 — previously unexpressible |
| `[-50]` | true | false | Fixed CV, no transitions — previously silently off |
| `[-50, -40]` | true | true | CV cycling, unchanged |

`FAIMS::isCycling()` guards the CV-transition MS1 push and the adaptive skip policy. Both are
meaningless with a single CV, and guarding the push on `isEnabled()` would inject a priority-0 MS1
after *every* MS1 — `advanceToNextCV` would keep returning the one CV it has — silently doubling
the survey rate.

**`ScanCommand` gains `int32_t faims_enabled`**, carved from `reserved_` (offset 1448; `reserved_`
moves to 1452 and shrinks 600 → 596). The struct stays 2048 bytes and no existing offset moves.
`faims_cv` cannot carry this distinction on its own, and "FAIMS off" is an active instruction to
the instrument rather than the absence of one — so the flag has to cross the bridge. `int32_t`
rather than `bool` matches the existing `is_agc` flag and avoids P/Invoke marshalling ambiguity.

## Consequences

**Every fixture that used a single CV to mean "no FAIMS" is rewritten to `[]`** — 27 committed
configs, the shipped `etc/method.json`, and 51 inline C++ test configs. This is what keeps the
change golden-neutral, and it is done as its own commit *before* the semantic change, where it is
a provable no-op under the old rule.

That step is load-bearing, not cosmetic. `faims_cv` is column 30 of `scan_commands.tsv` and is
serialized by `ScanCommandRecord`, so without it 27 unrelated tests would have started acquiring at
CV −50, moving all 16 log-golden modes and all 17 continuity JSONs — and quietly changing what
those tests test. Verified across all 34 configs: every pre-existing one evaluates identically
under `size() > 1` and `!empty()`, and `isCycling()` equals the old `isEnabled()` for every one.

`method_faims_single_cv.json` is added for the case that was previously unreachable. It is
byte-identical to `method_faims_3cv.json` except for the CV list, so diffing their goldens isolates
cycling from enablement. Its golden is captured fresh rather than recaptured.

The shipped `etc/method.json` moves from `cv_values: [0]` to `[]`. Under the old rule `[0]` meant
off by accident; under the new one it would mean FAIMS on at CV 0.

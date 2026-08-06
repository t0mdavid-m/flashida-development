# 0010. Per-stage instrument arrays are positional; structural and optional parameters differ

Status: Accepted (2026-08-06)

Discharges two items ADR-0009 explicitly deferred: the 522-row stage-0 `collision_energy` /
`hcd_energy` disagreement, and "assurance for the scan-shape half needs an assertion on the built
`ScanCommand`".

## Context

A multi-stage `ScanCommand` (MS3 = `num_stages 2`; stage 0 replays the MS2 isolation, stage 1
isolates a fragment of it) reaches the instrument through `ScanFactory.BuildFromCommand`, which
flattens each per-stage parameter into one `';'`-joined string in a `Values` dictionary. **Array
position is the only thing binding a value to a stage**: element `i` is stage `i`.

Each parameter was appended only if it passed a filter — `if (stage.ReactionTime > 0)` and seven
siblings. That is not a design decision. `git log -L 208,229:src/Flash/ScanFactory.cs` returns four
commits ever: `11eff0c` wrote the block **single-stage** (`var stage = cmd.Stages[0]`), where the
predicate could only mean "set the field or leave it null" and no index existed to misalign;
`772fd55`, two days later, converted it to a per-stage loop and transplanted the eight guards
character-for-character into `List.Add` calls, silently changing their meaning to *which array
slot*. The code it replaced had the positional contract explicit and commented
(`git show 7cfc8f7^:src/Flash/IDA/IDAScanProcessor.cs:478-521`):

```csharp
// MS3 arrays: [0] = MS2 precursor info, [1] = MS3 fragment info
ReactionTime = ms3_params.ReactionTime != 0 ? new double[] { 0, ms3_params.ReactionTime } : null,
```

The consequence: a stage whose value is 0 is skipped, so every later stage shifts one slot forward
onto the wrong stage. The trigger is one config value away and fully legal — `Config.cpp` forces
`reaction_time > 0` for an ETD/EThcD scan config at *every* level, while an HCD MS2 legally has
`reaction_time 0`. An ETD MS3 under an HCD MS2 therefore sends `ReactionTime = "10"`, a
one-element array the instrument binds to the **MS2 replay stage**. `Config.cpp:508-510` already
names this failure — *"ScanFactory then drops the parameter entirely, and the instrument falls back
to its own method default -- invisibly"* — and ADR-0009 fixed only the C++ half, ensuring the value
is set.

Every committed config uses CID at `ms3`, so the misbinding is latent, not observed. The
configurations that work today are correct **by accident of tail position**: with the common shape
(ETD MS2 carrying `reaction_time 7`, CID MS3 carrying none) the one-element `["7"]` lands on stage 0
only because that is where the non-zero value happens to live. Invert the activations and the same
code delivers the MS3's reaction settings to the MS2 stage.

A separate question forced the distinction below. If a stage were *empty* rather than merely
unused, zero-filling would command an isolation at m/z 0 — not a fix, a different defect with
better optics. Stage 0 cannot currently be empty (`buildMS3` copies it wholesale from a real MS2
context; `processScan` gate 5 rejects any context that is not a real MS2), but **stage 1 can**:
`ProteoformTracker` initialises `matched_mz`/`matched_charge` to 0 and deliberately keeps a match
when no peak backs it ("never drop a matched fragment for lack of a peak"), and the only filter —
`Exploration.cpp`'s `charge_floor` test — is inert because `selection_strategy.ms2.min_charge`
defaults to 0.

## Decision

- **Per-stage arrays are positional.** Element `i` is stage `i`, for `i < min(num_stages, 10)`.
  Every emitted per-stage array is either absent or exactly `num_stages` long. Rejected
  alternative: emitting `null` for an unused stage — value-type arrays cannot express it without
  changing the `ScanParameters` field types, and it reaches the wire as an *empty token*
  (`";10"`), whose handling is undocumented. A literal `0` is the documented producer-side sentinel,
  was the pre-port choice, and already ships accepted (`CollisionEnergy` sends `"40;0"`).

- **Structural parameters are always emitted; a stage missing them is refused, not zero-filled.**
  `precursor_mz`, `isolation_width`, `collision_energy`, `activation_type`, `charge_state` describe
  *that a stage exists*. There is no such thing as a stage that "does not use" a precursor m/z — 0
  is malformed, not unused, and `activation_type` has no zero at all. `BuildFromCommand` therefore
  throws `InvalidOperationException` rather than emit such a request. This is a real behavioural
  change: a command that today executes as a wrong-but-executing scan now does not execute. A scan
  commanded at m/z 0 yields nothing either way, so the trade is a silent bad scan for a loud
  skipped one.

- **Optional parameters are zero-filled positionally, but their key is omitted when no stage uses
  them.** `reaction_time`, `reagent_max_it`, `reagent_agc_target` are activation-coupled
  (`needsReactionTime(act) = ETD || EThcD`); a CID stage genuinely does not use a reaction time and
  `0` is the encoding `ScanCommand.h:53-55` documents. Omitting the key when *no* stage uses one
  preserves ADR-0009's "an unset value means use the instrument method default". This is why the
  change moves no golden: all 723 committed MS3 rows carry `"0;0"` for all three.

- **`hcd_energy` is derived, not copied.** It and `hcd_energy_s1` are log-only mirrors of the
  stages' collision energies, read solely by `IdaLogger`. They are computed in
  `ScanCommandQueue::push` — the one gate every queued command passes — from
  `stages[0]`/`stages[1]`, and the three builder-side assignments are deleted. `buildMS3` refreshed
  `stages[0].collision_energy` from `stage0_params` but kept the mirror from the MS2 context, which
  is how 522 rows came to log an energy the instrument never used.

- **A target with no isolation geometry is not dispatched.** `Exploration.cpp` skips an `Ms3Target`
  whose `frag_mz <= 0` or `frag_charge == 0`, at the loop both MS3 dispatch paths flow through. It
  costs no tracking id and writes no log row. Rejected alternative: rejecting inside `buildMS3` —
  it returns `ScanCommand` by value and allocates the tracking id first, so that means an
  `std::optional` restructure across five call sites to guard a case the caller can already skip.

- **The scalar block keeps absence semantics.** `analyzer`, `first_mass`, `orbitrap_resolution`,
  `microscans`, `rf_lens`, `data_type`, `faims_cv` and the rest are untouched. `ScanCommand.h`
  draws this line itself: stage fields read `0 = not used` (`:53-55`), scalars read
  `0 = use method default` (`:97-103`). Those are different claims and only the second delegates.

## Consequences

**No golden moves for the array change, and no wire byte changes for any committed acquisition.**
Verified rather than reasoned: all 723 MS3 rows across the seven MS3 modes carry `reaction_time` /
`reagent_max_it` / `reagent_agc_target` as `"0;0"` (every stage unset → key still omitted) and
`precursor_mz` / `isolation_width` / `charge` non-zero in **both** stages (already full-length).
All MS2 rows are single-stage, where the rule is a no-op. The `hcd_energy` derivation moves 522
rows in exactly 2 goldens, `hcd_energy` stage-0 token only.

**The structural guard cannot fire on any committed test data** — 1 458 MSn rows across the 16 log
goldens and 128 MSn records across the 17 continuity goldens have non-empty activation and non-zero
mz/width/charge. It is a guard against a state no fixture reaches, which is also why it needs its
own test.

**The array change is invisible to the pre-existing suite.** It moves no golden and fails no
existing test in either direction, so it would land with zero regression evidence. Three tests are
added for that reason: a two-stage `BuildFromCommand` positional/arity test (the only prior test of
that method drives `NumStages = 1`), a refusal test, and a three-way struct ↔ built-scan ↔ TSV
equivalence test generalising the existing `scan_description` equivalence to every stage-bound
parameter. Before this, **no test observed the built request for a two-stage command at all** —
every MS3 assertion read the raw struct.

**Unknowable from the repo, and stated as such.** The vendor stubs do not settle array arity.
`API-2.0.xml:1443` says an undefined value "will be replaced by the value defined in the default
scan"; `:1763` says a partially defined scan uses "the properties of the previously executed scan".
Neither says "the instrument method default", they conflict, and neither states whether a short
array binds element 0 to stage 0 or is rejected. The positional contract is therefore justified by
the pre-port implementation and by internal consistency, not by a vendor guarantee.

**Left standing deliberately, each owed its own decision:** `selection_strategy.ms2.min_charge`
defaults to 0, which is what makes the existing charge floor inert; the `exploration_etd` baseline
emits an ETD variant at `reaction_time 0` with reagents still armed (single-stage, unaffected here);
and `MockScanFactory.FillParametersMock` is an un-guarded hand copy of the private production
`FillParameters` that has already diverged — production tolerates a null array element, the mock
throws on it.

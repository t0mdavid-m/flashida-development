# 0030. Activation decides whether a coupled parameter is emitted

Status: Accepted (2026-08-25), implemented.
**Corrected same day**: this ADR originally argued that `0` is a legitimate commanded reaction time
for ETD. **It is not — the instrument rejects it**, and the floor is `0.03` ms
(`Config.h`'s `MIN_REACTION_TIME_MS`). The decision below stands, but read the *Correction* section
before the Context: the gate is still activation-based, and it still earns its keep, on different
grounds than the ones first written down.
Amends: [ADR-0009](0009-scan-config-fully-determines-instrument-parameters.md) — narrows its emit
clause from "omit when unused" to "omit when the activation gives it no meaning".
Related: [ADR-0010](0010-stage-arrays-are-positional.md),
[ADR-0011](0011-source-region-parameters-are-survey-scoped.md),
[ADR-0029](0029-a-baseline-belongs-to-its-activation.md).

## Correction

The premise below — "an ETD exploration baseline is precisely that: reaction time 0 is how you say
*isolate this precursor and do not fragment it*" — is **false**. The instrument refuses a reaction
time of 0 outright. Owner-confirmed against the hardware, which is the only place it could have been
confirmed: the iAPI DLLs are encrypted, no test can exercise them, and this ADR shipped with the
question explicitly recorded as unverified.

Two things change, and one does not.

- **What "no reaction" means.** `MIN_REACTION_TIME_MS = 0.03` is the floor, and it is what
  Exploration's synthesized ETD/EThcD baseline now commands (ADR-0029 decision 2). The collision
  energy axis is unaffected: CE 0 *is* commandable. So the two activation-coupled axes turn off at
  different values, and that asymmetry is the instrument's rather than ours.
- **Why the activation gate is worth having.** It was justified as "0 is a real value we mean to
  send". Since we no longer send 0 for a swept ETD baseline, a value gate would in fact emit the
  same key for every reachable exploration input. What survives is narrower and still real: the
  authored path. An `ms_settings` ETD block at `reaction_time: 0` still loads (see the accepted gap
  below), and under the old value gate its key vanished and the instrument silently substituted its
  method default; under the activation gate the 0 reaches the device and is **rejected loudly**. The
  gate converts a silent wrong answer into a visible failure — which was always the point, just not
  the mechanism first written down.
- **What does not change:** the decision itself. Emit on the activation, never on the value.

The one path deliberately left exposed: an authored `ms_settings.<scan>` pairing ETD with a
reaction time below the floor is neither floored nor rejected at load. It fails at the instrument,
loudly, on every scan of the run. Only the *sweep* path is guarded — `reaction_time_min` is where a
zero is the natural way to ask for "no reaction", so that is where a load-time throw pays for
itself. Pinned by `Config_SchemaProjection_test::zero_on_a_coupled_axis_is_accepted`, whose comment
names the gap so nobody reads the section as an endorsement.

## Context

`ScanCommand`'s `reaction_time` is documented as *"Ion/ion reaction time (ms), 0 = not used"*, and
`ScanFactory` honoured that by gating the whole key on the value:

```csharp
if (reactionTimes.Any(v => v > 0)) p.ReactionTime = reactionTimes.ToArray();
```

The intent is ADR-0009's: a parameter nobody configured should be **omitted**, so the instrument
method's own value applies rather than FLASHIda commanding a zero it never meant. For an HCD-only
MS2 that is exactly right — there is no ion-ion reaction, and sending `ReactionTime = 0` would be
asserting a setting that has no meaning.

The gate breaks the moment `0` becomes a value someone *means*. An ETD exploration baseline is
precisely that: reaction time 0 is how you say "isolate this precursor and do not fragment it"
(ADR-0029 decision 2). With `reaction_time_min: 0` the sweep's own first variant is that same scan.
In both cases the array is `[0]`, `Any(v => v > 0)` is false, and the key never reaches the wire.

So the instrument fell back to whatever its method carried — 10 ms, in the report that prompted
this — while the engine logged, and `[TRACK-CREATE]` printed, `RT=0`. The ETD sweep appeared to
begin at the method default instead of at `reaction_time_min`, and **the logged value and the
commanded value disagreed with nothing anywhere to notice**. That violates the rule that a logged
column must equal the value the engine actually used for that scan.

The engine already knew. `Config::validate` carried a guard whose comment names this failure
verbatim:

> An activation must arrive with the parameters that give it meaning (ADR-0009). Without this, an
> ETD scan config that omits reaction_time silently emits 0, ScanFactory then drops the parameter
> entirely, and the instrument falls back to its own method default -- **invisibly**.

But it threw on *authored* scan configs only. Sweep variants are synthesized at runtime, long after
`validate()` has run, so `ce_min: 0` and `reaction_time_min: 0` produced exactly the scan configs
the validator was written to reject — and the ETD one hit the failure the comment describes.

Note the asymmetry that made this survivable for so long. `CollisionEnergy` is emitted positionally
and **unconditionally**, so an HCD baseline at CE 0 has always reached the instrument as a real 0.
Only the reaction-time half of the pair was value-gated.

## Decision

**`reaction_time = 0` carries two meanings, and the stage's activation is what separates them.**

- On an **HCD/CID** stage it means *"not applicable"* — omit the key, defer to the instrument method.
- On an **ETD-family** stage it means *"a literal zero reaction time"* — send it.

`ScanFactory` therefore emits `ReactionTime` when **any stage's activation is ETD-family**,
regardless of the values collected:

```csharp
if (anyStageUsesReactionTime) p.ReactionTime = reactionTimes.ToArray();
```

Three things travel with that.

1. **The reagent keys keep their value gate.** `reagent_max_it` and `reagent_agc_target` are in the
   same "activation-coupled optional" group, but a zero reagent AGC target or max injection time
   has no useful meaning — `0` there really does mean "defer to the method". The split is
   deliberate and is not an oversight.

2. **`checkActivationCoupling` is deleted — both branches.** Its purpose was to prevent a *silent*
   fallback; the fallback is no longer silent, so the guard has no purpose left. The
   collision-energy branch goes with it so ETD and HCD keep the same rule: a zero on a coupled axis
   is now simply "do not fragment", which is what an exploration baseline asks for at either axis.

3. **The activation predicates become a declared, mirrored pair.** `needsCollisionEnergy` and
   `needsReactionTime` were file-local to `Config.cpp`, so `Exploration::buildVariants_` re-inlined
   the same activation literals — two definitions of one rule, with nothing pinning them together.
   They are now declared in `Config.h` and used by both, and mirrored once in C# as
   `ScanFactory.NeedsReactionTime`. Ordinal and case-sensitive on both sides.

## Consequences

- **Whatever reaction time an ETD scan carries is commanded verbatim**, and the logged value equals
  the commanded one. In practice a swept ETD baseline carries `MIN_REACTION_TIME_MS`, not 0, because
  the instrument rejects 0 — see *Correction*. The value of the gate is that a 0 arriving from the
  authored path is now refused at the device instead of being replaced, unseen, by the instrument
  method's own default.
- **A pure HCD/CID scan is unaffected** — the key is still omitted, so ADR-0009's "a wholly unused
  parameter defers to the instrument method default" is preserved for every activation that has no
  ion-ion reaction.
- **Positional integrity is unchanged**: one element per stage, so a two-stage HCD+ETD cascade
  emits `"0;5"` and the ETD stage's value stays bound to the ETD stage.
- **An authored `ms_settings` scan config pairing ETD with `reaction_time: 0`, or HCD/CID with
  `collision_energy: 0`, now loads.** The two are not equally harmless, and that is the accepted gap
  in *Correction*: HCD at CE 0 fragments nothing but acquires, while ETD at reaction time 0 is
  refused by the instrument on every scan of the run. Both are almost certainly mistakes; both are
  now visible ones; neither is caught by the schema. The **sweep** equivalent *is* caught —
  `reaction_time_min` below the floor throws at load, because a zero there is the natural way to
  ask for "no reaction" and so is a mistake worth anticipating.
- **This is a production-path-only change.** The five golden log streams are written by the C++
  `IdaLogger` and the engine's `reaction_time` value is unchanged, so no golden moves. The
  corollary is that nothing in CI exercised the defect: it lived in the one hop CI never checks.
- **Two definitions of the ETD-family set now exist**, one per language, and drift between them
  silently changes what the instrument is told without changing anything the engine logs. Pinned on
  both CI paths — `Config_SchemaProjection_test::activation_coupling_predicates_are_the_declared_set`
  and `ScanFactoryTests.NeedsReactionTime_MatchesEngineActivationSet` — as exact sets, because the
  failure that matters is an over-broad predicate that starts emitting a reaction time on scans that
  have none.

Also pinned by `ScanFactoryTests`: `ReactionTime_IsEmittedAsZero_ForEtdStage`,
`ReactionTime_IsOmitted_ForHcdOnlyScan`, `ReactionTime_IsPositional_WhenOnlyOneStageIsEtd`; and by
`Config_SchemaProjection_test::zero_on_a_coupled_axis_is_accepted`.

## Alternatives rejected

**Emit unconditionally, exactly like `CollisionEnergy`.** The smallest diff and perfectly
symmetric, but it starts sending `ReactionTime = 0` on every pure HCD/CID scan — something this
instrument path has never done — and reverses ADR-0009's emit clause outright rather than narrowing
it.

**Re-sentinel: make `-1` mean "not used" and free `0` to be literal.** Removes the ambiguity at its
source rather than disambiguating downstream, and is the cleaner model in the abstract. Rejected on
blast radius: it touches the `ScanCommand` contract, all four `reaction_time` assignment sites, the
C++ defaults, the C# mirror, both layout tests, and the implicit `0` in every committed config —
for one exploration edge case that the activation already distinguishes.

**Relax the ETD throw only, keeping the collision-energy one.** Matches the literal request but
leaves the two branches of one rule disagreeing about whether zero is legal on a coupled axis.

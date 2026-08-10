# 0019. Notches get their own array and a per-stage 10-plex cap

Status: Accepted (2026-08-10), implemented. **Supersedes the layout decision of
[ADR-0017](0017-notches-occupy-spare-stage-slots.md)** and its capacity clause; keeps 0017's
`num_stages`-never-counts-notches invariant and its carve-from-`reserved_` discipline. Depends on
[ADR-0016](0016-co-isolated-charges-are-one-detection.md).

## Context

ADR-0017 put notch descriptors in `stages[num_stages..]` — the 80-byte slots the engine never writes,
which already carry `precursor_mz` / `isolation_width` / `charge_state`. That was cheap and it worked.
It also carried two claims that turned out to be wrong, and one consequence nobody had priced.

**The wrong claim: that the instrument's "10 values" was a joint budget.** 0017 set capacity at
`MAX_ISOLATION_STAGES - num_stages` and justified it as landing exactly on the instrument's own limit,
citing `PrecursorMass`. The `IScans.PossibleParameters` dump from the target Eclipse says the same
sentence for **every** stage-carried key:

| Key | Limit text |
|---|---|
| `PrecursorMass` | "…each value separated by a ';' delimiter. A maximum of 10 values can be defined." |
| `IsolationWidth` | identical |
| `ChargeStates` | identical |
| `ActivationType` | identical |
| `CollisionEnergy` | identical |
| `FirstMass` | identical |
| `MSXTargets` | "AGC target values for **MSX windows**, in m/z order … a maximum of 10 values" |

`ActivationType` and `CollisionEnergy` have no notch axis at all — one activation and one energy per
fragmentation event. So the documented 10 counts **`;`-groups**, i.e. cascade depth. It is not a joint
stage+notch budget, and the `,` axis is not mentioned in `PossibleParameters` at all.

The per-scan **window** limit is `MSXTargets`': one AGC value per MSX window, capped at 10. That
matches the Q Exactive method editor's "MSX count … 1 (no spectral multiplexing) to 10 fillings" and
Thermo's own tribrid SPS example, which sends three comma windows. So the real ceiling is **10
isolation windows per fragmentation stage** — a different ten, on the other axis.

**The unpriced consequence: the two stages of an MS3 competed.** With one shared pool of
`10 - num_stages` = 8 slots and stage 0 written first (it had to be — stage 1's offset depended on
stage 0's count), a fully multiplexed parent MS2 handed its 9-charge set down and took all 8. Stage 1
— the stage an MS3 exists for — got zero. Observed directly in the `multiplexed_ms2` golden mode as
`notches/stage=[8, 0]` on every MS3 row.

**And the ceiling was too low anyway.** 8 shared slots cannot express a 10-plex at either stage, let
alone both. Reaching 10-plex twice needs 2 cascade anchors + 18 notches = 20 descriptors, and
`stages[20]` is 1600 bytes: 800 more than now, against 588 left in `reserved_`. It does not fit, and
the 2048-byte total is not negotiable.

## Decision

**Notches move to a dedicated 24-byte record in their own array, in fixed per-stage blocks of 9.**

```cpp
struct Notch { double precursor_mz; double isolation_width; int32_t charge_state; int32_t pad_; };
static_assert(sizeof(Notch) == 24);

static constexpr int MAX_NOTCHES_PER_STAGE = 9;              // 10-plex minus the anchor
static constexpr int MAX_NOTCHES = 2 * MAX_NOTCHES_PER_STAGE; // 18
```

| Field | Offset | Size |
|---|---|---|
| `stage0_notch_count` | 1452 | 4 |
| `stage1_notch_count` | 1456 | 4 |
| `pad4` | 1460 | 4 |
| `notches[18]` | 1464 | 432 |
| `reserved_` | 1896 | 152 |

Total unchanged at 2048; no existing offset moves. A notch needs 3 of `IsolationStage`'s 8 fields, so
24 bytes buys 18 slots where 80-byte slots would have cost 1440.

Four consequences follow from the shape:

1. **Stage k owns `[k * MAX_NOTCHES_PER_STAGE, +MAX_NOTCHES_PER_STAGE)`.** Both stages can be a full
   10-plex at once — 20 windows in one MS3 command — and neither can starve the other.
2. **Write order stops mattering.** 0017's "write stage 0 first or stage-1's land where the accessor
   looks for stage-0's" hazard is gone by construction. `ScanCommandLayout_test` writes stage 1 first
   on purpose.
3. **A notch structurally cannot carry a collision energy or activation type.** Under 0017 the writer
   copied `stages[k]` into the notch slot, so per-notch CE existed and merely happened to agree with
   the stage's. Now the field does not exist, which is the correct encoding of "all notches of a stage
   fire into one fragmentation event".
4. **`pad4` is explicit.** `Notch` is 8-aligned and 1460 is 4 mod 8, so the compiler would insert the
   same four bytes silently and the C# mirror would have nothing to line up against.

**Notches are ranked by descending intensity, gated by SNR.** 0016 ordered by SNR so "a clamp keeps
the strongest". SNR is a purity measure, not an abundance one: a charge sitting in a clean region of
the spectrum outranks a far more abundant one in a crowded region, and under a clamp that trades away
most of the envelope's ion current for tidiness. What a co-isolated fill is *for* is harvesting that
current. So intensity ranks, SNR only admits, and equal intensities break to ascending charge so the
order is total (the source map is unordered).

**`separate` and `multiplexed` derive their charge set from one `selectNotches` call.** They acquire
the same set and differ only in scan count — N versus 1. Sharing the call makes that structural
rather than a comment; two independent gate-and-rank paths is exactly how the two modes would drift.

## Consequences

- `MAX_ISOLATION_STAGES` finally means only what its name says. The two tens are pinned apart in
  `ScanCommandLayout_test`, with a comment saying why, because collapsing them is the original error.
- `notchesForStage()` no longer depends on `num_stages` — only on `k`. It stays the single stated
  place for the block layout and keeps the bounds guard.
- The C# `ScanFactory` clamp constant `10` becomes three named consts mirroring the C++ ones.
- `reserved_` drops to 152 bytes. That is still 38 `int32_t` carves at the historical rate of one or
  two per change, but it is the first carve large enough that the *next* structural addition should
  ask whether 2048 is still the right total rather than assuming a slot is free.
- **`fragment_charges` becomes functional for the first time.** It was accepted, parsed, plumbed and
  inert in both on-values — see the sibling fix to `ProteoformTracker`, which was starving it of
  candidates independently of anything in this ADR. Fixing the slots alone would not have produced a
  single MS3 notch.
- Golden impact: the three charge-mode modes only. `single` is the default everywhere else and no
  notch exists under it, so the 17 pre-existing modes are untouched.

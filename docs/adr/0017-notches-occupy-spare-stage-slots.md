# 0017. Co-isolation notches occupy the spare stage slots

Status: **SUPERSEDED (2026-08-10) by
[ADR-0019](0019-notches-get-their-own-array-and-a-per-stage-cap.md)** as to the layout and the
capacity. Was: Accepted (2026-08-09). Amends the *emit* clause of
[ADR-0010](0010-stage-arrays-are-positional.md); follows the carve-from-`reserved_` pattern of
[ADR-0012](0012-faims-enablement-is-explicit.md). Depends on
[ADR-0016](0016-co-isolated-charges-are-one-detection.md).

> ⚠️ **Read 0019 before citing anything below.** Notches now live in a dedicated 24-byte `Notch`
> array in fixed per-stage blocks, **not** in `stages[num_stages..]`, and the cap is 9 **per stage**
> rather than `10 - num_stages` shared. What survives from this ADR: `num_stages` never counts
> notches, the carve-from-`reserved_` discipline, the ADR-0010 emit-clause amendment, and the wire
> grammar — all of which follow from the wire format rather than the byte layout.
>
> The section below titled *"Considered and rejected: parallel notch arrays in `reserved_`"* is the
> option 0019 adopted. It was rejected here on the grounds that the extra bytes bought "only the
> independent caps" — and the independent caps turned out to be the whole ballgame: with one shared
> pool, an MS3 inheriting a fully multiplexed parent left its own fragment stage with zero slots. The
> capacity paragraph is also wrong on the instrument, conflating `PrecursorMass`'s 10-value `';'`-axis
> limit with `MSXTargets`' 10-window `','`-axis one.

## Context

A co-isolated charge set needs, per notch, three measured values that cannot be derived host-side:
the window's centre m/z, its width, and its charge. The widths matter individually — `getMzRange(z)`
spans scale roughly as 1/z, so across a z=15..25 envelope they differ by about 1.7×, and a single
broadcast width either over-isolates the high charges or clips the low ones.

The `ScanCommand` ABI is fixed at 2048 bytes and the obvious place to put per-notch data is the worst
one. `IsolationStage` is exactly 80 bytes with no padding and no reserved field; growing it to 88
grows `stages[10]` from 800 to 880 and shifts **every offset from 1144 onward** — roughly 50 hard
asserted offsets across `ScanCommandLayout_test.cpp` and `ScanCommandLayoutTests.cs`.

Two things make a much cheaper option available. `stages[2..9]` — 640 bytes — is **never written**:
`num_stages` is only ever assigned 0, 1 or 2, so eight 80-byte slots already containing
`precursor_mz`, `isolation_width` and `charge_state` sit unused in every command the engine has ever
built. And `reserved_` has 596 bytes at offset 1452, which is 4 mod 8 — so an `int32_t` carve needs
no alignment pad (a `double` would).

## Decision

**Two `int32_t` counts are carved from `reserved_` (596 → 588 bytes), and the notch descriptors
occupy `stages[num_stages..]`.**

```cpp
int32_t stage0_notch_count;   // @1452  extra co-isolated notches for cascade stage 0
int32_t stage1_notch_count;   // @1456  extra co-isolated notches for cascade stage 1
char    reserved_[588];       // @1460  -> 2048
```

Notches pack immediately after the cascade stages — stage-0's first, then stage-1's — reusing the
existing `precursor_mz` / `isolation_width` / `charge_state` fields. The struct stays 2048 bytes, no
existing offset moves, and the C# mirror needs no new marshalled field.

**`num_stages` does not count notches.** This is load-bearing rather than stylistic: gate 5 of
`processScan` (`FLASHIda.cpp:133`), `syncEnergyMirrors_` (`ScanCommandQueue.cpp:172-173`),
`Exploration.cpp:200`'s `si = num_stages - 1`, and `ScanFactory.cs:198`'s clamp all key on it, and
all four stay correct only while it means cascade depth. `syncEnergyMirrors_` already guards on
`num_stages > 0` / `> 1`, so a notch parked at `stages[1]` of an MS2 command cannot pollute
`hcd_energy_s1`.

**Capacity is `10 - num_stages`** — 9 notches for an MS2 command, 8 shared between the two stages of
an MS3. That is not an artifact of the byte budget: `PrecursorMass` accepts *"a maximum of 10
values"*, so `num_stages + total_notches <= 10` is the instrument's own limit and the ABI lands
exactly on it. Overflow clamps by descending SNR and logs what was dropped.

### Considered and rejected: parallel notch arrays in `reserved_`

Two counts plus per-stage charge / m/z / width arrays, about 332 bytes, leaving `reserved_` at 264.
It buys named fields and independent per-stage caps. It was rejected because the three surrounding
changes — the ADR-0010 emit-clause amendment, `ScanFactory`'s nested group loop, and `IdaLogger`'s
notch grammar — are required **identically under both options**, since they follow from the wire
format rather than from where the notches live. The extra 324 bytes therefore buy only the
independent caps.

## Consequences

**ADR-0010's emit clause no longer holds.** Its indexing clause is scoped — *"Element `i` is stage
`i`, for `i < min(num_stages, 10)`"* — and says nothing about `i >= num_stages`, so notches there do
not contradict it. But *"Every emitted per-stage array is either absent or exactly `num_stages`
long"* becomes false: an emitted array now carries `num_stages` semicolon-separated **groups**, each
`1 + notch_count` comma-separated values. That follows from the wire grammar, so it would need
amending whichever ABI option were chosen.

**The MS3 notch budget is shared between the two stages.** With eight slots, co-isolating five
precursor charges leaves three for the fragment. Realistic SNR-gated counts are ~3–6 for a precursor
and ~2–4 for a fragment, so this fits, but it is a real coupling and the clamp must say what it
dropped rather than truncating silently.

**The layout is implicit.** `stages[3]` is "stage-0 notch 2" only by arithmetic on `num_stages` and
`stage0_notch_count`. A named accessor and a layout test pinning the packing convention are part of
the change, so no read site open-codes the arithmetic.

**Forward-compatible.** `reserved_` retains 588 bytes, so if the shared budget proves too tight an
overflow array can still be carved later — whereas the rejected option commits the bytes now.

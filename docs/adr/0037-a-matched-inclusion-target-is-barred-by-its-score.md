# 0037. A matched inclusion target is barred by its score, not by exclusion

Status: **Withdrawn (2026-08-28)** — accepted 2026-08-27, implemented on a branch, never landed.
Superseded by nothing: the behaviour it proposed is already reachable through
`precursor_selection.tqscore_threshold`, and this ADR would have removed the ability to choose.
Related: [ADR-0036](0036-a-split-envelope-is-one-precursor-acquired-in-parts.md) — the other half of
"several masses can sit inside one row's tolerance", which stands and is implemented.

## What it proposed

That a species matching an inclusion row stop reading the two `tqscore_exceeding_*` bars, so the
qscore comparison in `mass_qscore_map_` — "re-acquire only if this survey resolves it at least as
well" — would govern its re-acquisition instead of dynamic exclusion.

## Why it was withdrawn

**The ratchet is not new, and it is not unreachable.** It predates this workspace, arriving with the
original soft-exclusion work (`a76426e076`, then `4457abeb4c change algorithm to max qscore`), and
sits two statements above its own off-switch:

```cpp
// If mass has previously been acquired with higher qscore, skip
if (score < mass_qscore_map_[nominal_mass]) { continue; }
mass_qscore_map_[nominal_mass] = score;

// Add to exclusion list if neccessary
if (mass_qscore_map_[nominal_mass] > config_.targeting().tqscore_threshold)
{
  tqscore_exceeding_mass_rt_map_[nominal_mass] = rt;
  tqscore_exceeding_mz_rt_map_[integer_mz]     = rt;
}
```

Whether the ratchet or dynamic exclusion governs is decided entirely by `tqscore_threshold`. Set it
above a species' qscore and the bars never arm, so the ratchet runs on every survey; set it below and
exclusion retires the species for the `rt_window`. Every committed config sits below: production
`method.json` at 0.1, seventeen test configs at 0.0, twenty-three at 0.9 against cytC scores of
0.94–0.98. The original ADR read that as "unreachable". It is **out-ranked at the thresholds we
happen to ship**, which is a different thing and is a configuration question, not an architecture one.

**So the ADR did not add a capability — it removed a choice**, hard-coding one side of the trade for
every row an inclusion list matched, in every method file, with no way to opt out.

**And the yield did not justify it.** Implemented, it moved thirteen log goldens. The extra
acquisitions came from qscore improvements of **+0.0015, +0.0042, +0.0002 and +0.0002** — the
build-to-build jitter documented for this engine, buying an MS2 scan each time. Meanwhile the
measurement that motivated the ADR stands and is still worth knowing: on the flagship inclusion
golden the target is **resolved in 25 of 25 surveys and acquired once**, across a 63 s run inside a
180 s `rt_window`. That is real, and `tqscore_threshold` is the knob that addresses it.

**Scope was the giveaway.** Authored rows were exempt by construction — ADR-0028 re-keys their
exclusion to `(nominal mass, charge)`, so they never read these bars. Every golden the ADR moved was
an unrestricted `-1` row, and the two authored-charge modes were the only inclusion modes that did
**not** move. A change motivated by charge-state completeness that fires exactly where charges are
*not* named was aimed at the wrong defect.

## What replaces it

Nothing, deliberately. Unrestricted rows keep today's behaviour exactly. A method that wants the
ratchet raises `tqscore_threshold` above the target's qscore, accepting that the knob is global.

## Known limitations of the existing knob, recorded so they are not rediscovered

- **It is global.** `targeting().tqscore_threshold` is one value per run, so reaching the ratchet for
  a target also disables mass-keyed dynamic exclusion for every other species. If per-row control is
  ever needed, that is a new key with its own ADR — starting from "the knob is global", not from
  "matching a row overrides the knob".
- **`removeFromExclusionList` inflates the stored bar.** `mass_qscore_map_[n] /= 1 - qscore` multiplies
  it by ~16.7 at qscore 0.94, after which no real score beats it and the ratchet refuses that species
  permanently. Pre-existing, independent of this decision, and not investigated here.
- **Seeding the bar from outside the run remains unbuilt.** `target_mass_qscore_map_` is populated in
  inclusion mode and read only in the in-depth branch, so per-mass scores from `files.target_logs` are
  parsed and discarded today.

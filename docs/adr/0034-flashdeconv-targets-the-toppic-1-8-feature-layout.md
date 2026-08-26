# 0034. FLASHDeconv targets the TopPIC 1.8.x feature layout

Status: Accepted (2026-08-26)

## Context

FLASHDeconv writes `*_ms2.feature` for TopPIC. TopPIC reads it during *Finding PrSM clusters*,
after the search has already completed, and parses it **positionally with no bounds checking**:

```cpp
// src/ms/feature/spec_feature.cpp
std::vector<std::string> strs = str_util::split(line, "\t");
...
prec_inte_ = std::stod(strs[16]);   // 17 columns required
```

`SpecFeatureReader`'s constructor consumes the header line with `std::getline` and never inspects
it. Column *names* are documentation; only positions and count matter. A wrong layout produces no
warning and no error message.

The layout has changed five times, with no version marker in the file:

| TopPIC | columns |
|---|---:|
| 1.4.13 | 13 |
| 1.5.0 – 1.6.5 | 14 |
| 1.7.0 – 1.7.3 | 18 |
| 1.7.6 – 1.7.11 | 16 |
| 1.8.0 – 1.8.1 | 17 |

FLASHDeconv emitted the 16-column form, name for name — the 1.7.6–1.7.11 layout. It was not a
*wrong* format; it was a format that was correct and silently aged out. Against TopPIC 1.8.x,
`strs[16]` on a 16-element vector is undefined behaviour: measured as `0xC0000005` on Windows and
exit 139 on Linux, immediately after `Finding PrSM clusters - started.`

The workaround is `toppic --no-topfd-feature`, which exits 0. It is not free. On a run compared
side by side:

| | feature file ON | `--no-topfd-feature` |
|---|---|---|
| `Feature ID` / `intensity` / `score` / `apex time` | `365` / `1.781e+07` / `0.99826` / `3.887` | `-` `-` `-` `-` |
| `Proteoform intensity` | `17809245` | `-1` |

So the workaround drops label-free quantitation, not merely four cosmetic columns.

## Decision

**Emit the TopPIC 1.8.x layout unconditionally: 17 columns, with
`Precursor_neutral_monoisotopic_mass` inserted at position 13.** No parameter selects a target
version, and the writer contains no version branch.

The pinned target is recorded in a comment at `FLASHDeconvFeatureFile::writeTopFDFeatureHeader`
and locked by `FLASHDeconvFeatureFile_test`, which asserts the field count and the column names on
the header and the field count on every emitted row.

## Consequences

**TopPIC 1.7.6 – 1.7.11 is no longer a supported reader.** Inserting a column at 13 shifts
everything after it, so a 1.7.x reader takes `strs[14]` (the average m/z) as `prec_charge_` and
`strs[15]` (the charge) as `prec_inte_`. It does not crash — `std::stoi("681.037451")` quietly
returns `681` — and it lands only in the precursor block, which nothing in TopPIC reads. The
practical damage is expected to be nil, but the narrowing is real and deliberate: one supported
layout at a time, chosen at compile time.

**Columns 13–17 remain write-only.** `getPrecMonoMz`, `getPrecAvgMz`, `getPrecCharge` and
`getPrecInte` have no readers anywhere in TopPIC outside the file writer. Verified directly:
the PrSM table's `Precursor mass` tracks the msalign's per-spectrum `PRECURSOR_MASS` to the last
digit, not the per-feature col 13. They are emitted because the parser reaches for them and
because a file that states a mass and its own m/z should state them consistently — not because
anything consumes them.

**The next layout change will present the same way: as a crash, at the end of a completed search.**
There is no version marker to check and nothing validates on read. Spec §11 recommended making the
target configurable; that was considered and rejected here, because every supported value needs its
own emit path and its own test case, and only one TopPIC version is in use. If a second version
must be supported simultaneously, this is the decision to revisit — and the writer comment plus
this ADR are where a future reader will look for the coupling.

## Alternatives considered

**A TopPIC-version parameter on the FLASHDeconv tool**, defaulting to 1.8.x. Keeps 1.7.x working
and documents the coupling in the tool's own interface. Rejected: it multiplies the emit paths and
the test matrix for a compatibility target nobody here uses.

**Stamping the targeted version into the file.** TopPIC skips the header line without inspecting
it, so a header-borne marker costs nothing — but it is invisible to the parser and would help only
humans, who have this ADR. Rejected as ceremony.

**Staying on 16 columns and instructing users to pass `--no-topfd-feature`.** Rejected: it silently
turns off feature-based PrSM clustering and reports `Proteoform intensity = -1`.

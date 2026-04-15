# Per-Level Min Charge Selection Filter

## Problem

FLASHIda has a global deconvolution charge range (`min_charge`/`max_charge` in `DeconvolutionConfig`), but no per-MSn-level charge filtering for target selection. Users need to specify minimum charge thresholds per level — e.g., "MS1 only picks precursors with charge >= 5" or "MS2 only picks fragment ions with charge >= 2".

## Solution

Add an optional `min_charge` field to each MSn level's `selection_strategy` config. After the trigger charge is selected via the normal scoring path (`getRepAbsCharge()` for MS1->MS2, `getMaxIntensityAbsCharge()` for MS2->MS3), targets whose selected charge falls below the per-level `min_charge` are silently skipped. No fallback to alternative charges — the target is simply not triggered.

## Config Format

```json
{
  "selection_strategy": {
    "ms1": { "selection": "qscore", "max_targets": 4, "min_charge": 5 },
    "ms2": { "selection": "intensity", "max_targets": 4, "min_charge": 2 },
    "ms3": { "selection": "intensity", "max_targets": 4 }
  }
}
```

`min_charge` on a level controls what **that level picks** as targets for the next level. `ms1.min_charge = 5` means MS1 only picks precursors with charge >= 5 (for MS2). `ms2.min_charge = 2` means MS2 only picks fragments with charge >= 2 (for MS3). Defaults to `0` (no filter).

## Changes

### Layer 1: C# MethodConfig (`MethodConfig.cs`)

Add `MinCharge` property with `[JsonKey("min_charge")]` to all three level config classes:

- `MS1SelectionConfig` (line 259)
- `MS2SelectionConfig` (line 271)
- `MS3SelectionConfig` (line 286)

```csharp
[JsonKey("min_charge")]
[Description("Minimum charge state for target selection (0 = no filter)")]
public int MinCharge { get; set; } = 0;
```

Add `min_charge` to `JsonMsLevelConfig` (line 495):

```csharp
public int min_charge { get; set; }
```

### Layer 2: C# BuildSelectionStrategy (`MethodParameters.cs:259-325`)

Wire `MinCharge` into each `JsonMsLevelConfig`:

```csharp
ms1 = new JsonMsLevelConfig
{
    selection = (ss.MS1?.Selection ?? "qscore").ToLower(),
    max_targets = ms1Max,
    min_charge = ss.MS1?.MinCharge ?? 0
},
// same for ms2, ms3
```

### Layer 3: C++ Config struct (`Config.h:89-104`)

Add field to `MSLevelConfig`:

```cpp
int min_charge = 0;  ///< Minimum charge for target selection (0 = no filter)
```

### Layer 4: C++ Config parsing (`Config.cpp:319`)

After `max_targets` parsing, add:

```cpp
cfg.min_charge = level_obj.value("min_charge", 0);
```

### Layer 5: C++ MS1->MS2 filtering (`PrecursorSelection.cpp:429`)

After the charge selection decision tree (line 428), before `mass = pg.getMonoMass()`:

```cpp
// MS1 picks: skip precursors below ms1's min_charge
if (config_.level(1).min_charge > 0 && charge < config_.level(1).min_charge)
  continue;
```

### Layer 6: C++ MS2->MS3 filtering (`Exploration.cpp:478-495,500-534`)

In both command-building loops (exploration and direct), read the threshold from the current level (the one doing the picking), then skip fragments below it:

```cpp
int charge_floor = config_.level(msn_level).min_charge;

for (int ti = 0; ti < num_targets; ++ti)
{
  int abs_charge = std::abs(charges[ti]);
  if (charge_floor > 0 && abs_charge < charge_floor)
    continue;
  // ... existing command-building code ...
}
```

## What doesn't change

- Deconvolution engine — global charge range unchanged
- PeakGroup — no modifications
- ScanCommand struct — layout unchanged (1248 bytes)
- Bridge functions — no new exports
- `getRepAbsCharge()` / `getMaxIntensityAbsCharge()` — charge selection logic unchanged

## Behavior summary

| Scenario | Behavior |
|----------|----------|
| `min_charge` absent or `0` | No filtering (current behavior) |
| `min_charge = 5`, trigger charge = 7 | Target passes |
| `min_charge = 5`, trigger charge = 3 | Target skipped silently |
| PeakGroup spans 3-8, rep charge = 5, `min_charge = 4` | Passes (filter is on trigger charge, not PeakGroup range) |
| PeakGroup spans 3-8, rep charge = 3, `min_charge = 4` | Skipped (no fallback to charge 4) |

## Testing

- Set `min_charge` on MS1 level config, verify precursors with charge below threshold produce no MS2 commands
- Set `min_charge` on MS2 level config, verify fragments with charge below threshold produce no MS3 commands
- Verify `min_charge = 0` has no effect (backward compatible)

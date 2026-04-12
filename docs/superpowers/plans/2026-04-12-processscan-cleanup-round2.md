# processScan Cleanup Round 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thirteen incremental improvements to `FLASHIda::processScan()` covering exploration scoring, unified MS3 targeting under `SelectionMetric`, legacy config removal, and code simplification.

**Architecture:** Four waves: (1) independent renames/refactors, (2) exploration improvements with real scoring, (3) MS3 unification under `SelectionMetric` with `FragmentAnalysis` integration, (4) inline `processMS2Path_`. C++ changes on `flashida-v9-bridge`, C# on `phase-11`.

**Tech Stack:** C++20 (OpenMS/CMake), C# .NET 4.8, nlohmann/json, OpenMS ClassTest framework

**Spec:** `docs/superpowers/specs/2026-04-11-processscan-cleanup-design.md`

**Build constraint:** Do NOT build locally. Push to `flashida-v9-bridge` for CI build. See `CLAUDE.md` lessons.

---

## File Map

### C++ Modified
| File | Responsibility |
|------|---------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h` | SelectionMetric enum extension, MSLevelConfig field additions, TargetingConfig field removals |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` | Selection string parsing, validation rules, legacy key rejection |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h` | Deconvolution& + FragmentAnalysis& members, feedResult signature, scoring signatures |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` | feedResult deconvolves, real scoring, fragment-aware initiateNextLevel |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h` | Priority param on builders |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp` | Priority param implementation |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h` | Rename deconvolveMS2→deconvolveMSn |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp` | Rename definition |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Remove selectMS3Targets_, MS3Target, processMS2Path_; update writeScanResultRow_ |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | FAIMS guard, priority at call sites, TSV logging, exploration path, inline processMS2Path_, collapse Step 5 |
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h` | Doc comment update for deconvolveMSn |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp` | Doc comment update |

### C# Modified
| File | Responsibility |
|------|---------------|
| `FlashIDA/src/Flash/MethodConfig.cs` | Rename max_precursors/max_fragments→max_targets, remove Ms3Config legacy fields |
| `FlashIDA/src/Flash/MethodParameters.cs` | Serialize max_targets, remove ms3 legacy fields from ToCppJson |
| `FlashIDA/test-data/configs/*.json` (~21 files) | Rename max_precursors/max_fragments, remove legacy ms3 fields |
| `FlashIDA/src/Flash/etc/method.json` | Same config migration |

### Tests Modified
| File | Responsibility |
|------|---------------|
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | feedResult signature, new scoring unit tests, validation tests |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` | Priority updates, JSON config updates |
| `OpenMS/src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp` | Priority updates |

---

## Task 1: Remove FAIMS Guard + Rename deconvolveMSn (Items 1, 6)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:516`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h:84`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp:73,139`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:621,695,731`

- [ ] **Step 1: Remove FAIMS guard**

In `FLASHIda.cpp`, replace line 516:
```cpp
double parent_cv = config_.faims().enabled ? faims_cv : 0.0;
```
with:
```cpp
double parent_cv = faims_cv;
```

- [ ] **Step 2: Rename deconvolveMS2 → deconvolveMSn in Deconvolution.h**

In `Deconvolution.h:84`, rename the method declaration:
```cpp
int deconvolveMSn(const double* mzs, const double* ints, int length,
                  double rt, double precursor_mass, int precursor_charge);
```

Update the doc comment on line 75 from "Deconvolve an MS2 spectrum" to "Deconvolve an MSn (n>1) spectrum".

- [ ] **Step 3: Rename deconvolveMS2 → deconvolveMSn in Deconvolution.cpp**

In `Deconvolution.cpp:73`, rename the definition:
```cpp
int Deconvolution::deconvolveMSn(const double* mzs, const double* ints, int length,
                                  double rt, double precursor_mass, int precursor_charge)
```

In `Deconvolution.cpp:139`, update the call inside `deconvolveMS2Py`:
```cpp
return deconvolveMSn(mzs.data(), ints.data(), static_cast<int>(mzs.size()),
                     rt, precursor_mass, precursor_charge);
```

- [ ] **Step 4: Update all call sites in FLASHIda.cpp**

Three call sites — rename `deconvolveMS2` to `deconvolveMSn`:
- Line 621: `deconv_.deconvolveMSn(mzs, ints, length, rt_min, 0.0, 0);`
- Line 695: `deconv_.deconvolveMSn(mzs, ints, length, rt_min, 0.0, 0);`
- Line 731: `deconv_.deconvolveMSn(mzs, ints, length, rt_min, precursor_mass, precursor_charge);`

- [ ] **Step 5: Update doc comments in PrecursorSelection**

In `PrecursorSelection.h:160` and `PrecursorSelection.cpp:906`, update any doc comments that reference `deconvolveMS2` to `deconvolveMSn`.

- [ ] **Step 6: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.cpp \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/PrecursorSelection.cpp
git commit -m "Remove redundant FAIMS CV guard, rename deconvolveMS2 to deconvolveMSn"
```

---

## Task 2: Add Priority Parameter to Scan Builders (Item 2)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h:74,77,88`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:174,249,306`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` (all buildMS2/buildMS3/buildFollowUp call sites)
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` (all build call sites)
- Modify: `OpenMS/src/tests/class_tests/openms/source/ScanCommandQueue_Concurrent_test.cpp:171`

- [ ] **Step 1: Add priority param to ScanCommandQueue.h**

Update three signatures:

```cpp
/// Build MS2 ScanCommand from a PeakGroup + ScanConfig (unified factory)
ScanCommand buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config, int priority = 1);

/// Build MS3 ScanCommand from MS2 context + fragment target
ScanCommand buildMS3(const ScanCommand& ms2_ctx, double frag_mz, int frag_charge, double iso_width,
                     char ion_type = '\0', int frag_index = 0, int priority = 3);

/// Build follow-up MS2 using the given scan config and description suffix.
ScanCommand buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix, int priority = 2);
```

- [ ] **Step 2: Use priority param in ScanCommandQueue.cpp**

In `buildMS2` (line 181), replace `cmd.priority = 1;` with `cmd.priority = priority;`.

In `buildMS3` (line 257), replace `cmd.priority = 3;` with `cmd.priority = priority;`.

In `buildFollowUp` (line 312), replace `cmd.priority = 2;` with `cmd.priority = priority;`.

- [ ] **Step 3: Pass priority explicitly at all call sites in FLASHIda.cpp**

All existing call sites use the default priority values, so no code changes needed — the defaults match the current hardcoded values. Callers that need non-default priorities (like exploration at priority 0) already set `cmd.priority = 0` after the build call. These can optionally be migrated to pass `0` as the priority param, but this is not required for correctness.

- [ ] **Step 4: Pass priority explicitly in Exploration.cpp**

In `Exploration.cpp:104`, the exploration variant build sets `cmd.priority = 0` after calling `buildMS2`. Update to pass priority directly:

```cpp
ScanCommand cmd = queue.buildMS2(pg, charge, variant_config, 0);
```

Remove the subsequent `cmd.priority = 0;` line (line 105).

Similarly in `initiateNextLevel` (line 265), production commands use priority 1 (the default), so no change needed.

- [ ] **Step 5: Update test**

In `ScanCommandQueue_Concurrent_test.cpp:171`, the `buildMS2` call now has the same signature (default priority=1), so no change needed. Verify the test compiles.

- [ ] **Step 6: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp
git commit -m "Add priority parameter to buildMS2, buildMS3, buildFollowUp"
```

---

## Task 3: Rename max_precursors/max_fragments → max_targets (Item 4)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:292-295`
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:270-310,490-496`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:236-302`
- Modify: ~21 JSON config files
- Modify: C++ test JSON configs in exploration_test, ProcessScan_test

- [ ] **Step 1: C++ Config.cpp — remove alias chain**

Replace lines 292-295:
```cpp
cfg.max_targets = level_obj.value("max_targets",
    level_obj.value("max_precursors",
    level_obj.value("max_fragments", 10)));
```
with:
```cpp
cfg.max_targets = level_obj.value("max_targets", 10);
```

- [ ] **Step 2: C# MethodConfig.cs — rename properties**

In `MS1SelectionConfig` (line 277-279), replace:
```csharp
[JsonKey("max_precursors")]
[Description("Maximum number of precursors to select per MS1 scan")]
public int MaxPrecursors { get; set; } = 10;
```
with:
```csharp
[JsonKey("max_targets")]
[Description("Maximum number of targets to select per MS1 scan")]
public int MaxTargets { get; set; } = 10;
```

In `MS2SelectionConfig` (line 289-291), replace:
```csharp
[JsonKey("max_fragments")]
[Description("Maximum number of fragments to select per MS2 scan")]
public int MaxFragments { get; set; } = 3;
```
with:
```csharp
[JsonKey("max_targets")]
[Description("Maximum number of targets to select per MS2 scan")]
public int MaxTargets { get; set; } = 3;
```

In `MS3SelectionConfig` (line 304-306), replace:
```csharp
[JsonKey("max_fragments")]
[Description("Maximum number of fragments to select per MS3 scan")]
public int MaxFragments { get; set; } = 3;
```
with:
```csharp
[JsonKey("max_targets")]
[Description("Maximum number of targets to select per MS3 scan")]
public int MaxTargets { get; set; } = 3;
```

In `JsonMsLevelConfig` (lines 490-496), replace `max_precursors` and `max_fragments` with single `max_targets`:
```csharp
public class JsonMsLevelConfig
{
    public string selection { get; set; }
    public int max_targets { get; set; }
    public JsonExplorationBlockConfig exploration { get; set; }
}
```

- [ ] **Step 3: C# MethodParameters.cs — update BuildSelectionStrategy**

Replace lines 243-266:
```csharp
int ms1Max = ss.MS1?.MaxTargets ?? 10;
int ms2Max = ss.MS2?.MaxTargets ?? 3;
int ms3Max = ss.MS3?.MaxTargets ?? 3;

var result = new JsonSelectionStrategyConfig
{
    ms1 = new JsonMsLevelConfig
    {
        selection = (ss.MS1?.Selection ?? "qscore").ToLower(),
        max_targets = ms1Max
    },
    ms2 = new JsonMsLevelConfig
    {
        selection = (ss.MS2?.Selection ?? "intensity").ToLower(),
        max_targets = ms2Max
    },
    ms3 = new JsonMsLevelConfig
    {
        selection = (ss.MS3?.Selection ?? "none").ToLower(),
        max_targets = ms3Max
    }
};
```

- [ ] **Step 4: Update all JSON config files**

In every JSON file under `FlashIDA/test-data/configs/` and `FlashIDA/src/Flash/etc/`, within the `selection_strategy` section:
- Replace `"max_precursors"` with `"max_targets"`
- Replace `"max_fragments"` with `"max_targets"`

Also update any JSON config strings embedded in C++ test files (`FLASHIda_exploration_test.cpp`, `FLASHIda_ProcessScan_test.cpp`, etc.) — search for `max_precursors` and `max_fragments` within JSON string literals and replace with `max_targets`.

- [ ] **Step 5: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        FlashIDA/src/Flash/MethodConfig.cs FlashIDA/src/Flash/MethodParameters.cs \
        FlashIDA/test-data/configs/ FlashIDA/src/Flash/etc/ \
        OpenMS/src/tests/class_tests/openms/source/
git commit -m "Rename max_precursors/max_fragments to max_targets everywhere"
```

---

## Task 4: Move Deconvolution into Exploration::feedResult (Item 5)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:688-701`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add Deconvolution& member to Exploration.h**

Add `#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Deconvolution.h>` to the includes.

Add member variable after `const Config& config_;` (line 125):
```cpp
const Config& config_;
Deconvolution& deconv_;
```

Update constructor signature (line 100):
```cpp
Exploration(const Config& config, Deconvolution& deconv);
```

Update `feedResult` signature (line 108):
```cpp
std::vector<ScanCommand> feedResult(int tracking_id,
    const double* mzs, const double* ints, int length,
    double rt, ScanCommandQueue& queue);
```

- [ ] **Step 2: Update Exploration.cpp constructor**

Replace line 46-48:
```cpp
Exploration::Exploration(const Config& config)
  : config_(config)
{
}
```
with:
```cpp
Exploration::Exploration(const Config& config, Deconvolution& deconv)
  : config_(config), deconv_(deconv)
{
}
```

- [ ] **Step 3: Update feedResult to deconvolve internally**

Replace the `feedResult` signature and the section before variant lookup (lines 132-155) with:

```cpp
std::vector<ScanCommand> Exploration::feedResult(int tracking_id,
    const double* mzs, const double* ints, int length,
    double rt, ScanCommandQueue& queue)
{
  std::vector<ScanCommand> commands;

  auto vit = variant_tracking_map_.find(tracking_id);
  if (vit == variant_tracking_map_.end()) return commands;

  int group_id = vit->second.group_id;
  int variant_index = vit->second.variant_index;
  variant_tracking_map_.erase(vit);

  auto git = active_groups_.find(group_id);
  if (git == active_groups_.end()) return commands;
  ExplorationGroup& group = git->second;

  if (variant_index < 0 || variant_index >= static_cast<int>(group.variants.size())) return commands;
  ExplorationVariant& v = group.variants[variant_index];
  if (v.received) return commands;

  // Deconvolve with correct precursor context from the exploration group
  DeconvolvedSpectrum ms2_deconv(tracking_id);
  if (mzs != nullptr && ints != nullptr && length > 0)
  {
    deconv_.deconvolveMSn(mzs, ints, length, rt,
                          group.precursor_mass, group.precursor_charge);
    ms2_deconv = deconv_.storedMS2();
  }

  v.result = ms2_deconv;
```

The rest of `feedResult` (scoring, winner selection, etc.) stays the same from the line `v.score = computeExplorationScore_(...)` onward.

- [ ] **Step 4: Update FLASHIda construction**

In `FLASHIda.h`, the `Exploration exploration_;` member (line 250) is constructed in the initializer list. The constructor in `FLASHIda.cpp` needs to pass `deconv_` when constructing `exploration_`. Find the member initializer list and change `exploration_(config_)` to `exploration_(config_, deconv_)`.

- [ ] **Step 5: Simplify the exploration path in FLASHIda.cpp**

Replace lines 688-701:
```cpp
if (exploration_.isExplorationVariant(tracking_id))
{
  DeconvolvedSpectrum ms2_deconv(tracking_id);
  if (mzs != nullptr && ints != nullptr && length > 0)
  {
    deconv_.deconvolveMSn(mzs, ints, length, rt_min, 0.0, 0);
    ms2_deconv = deconv_.storedMS2();
  }

  auto cmds = exploration_.feedResult(tracking_id, ms2_deconv, rt_min, queue_);
  for (auto& c : cmds) queue_.push(c);
  return commands_pushed;
}
```
with:
```cpp
if (exploration_.isExplorationVariant(tracking_id))
{
  auto cmds = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);
  for (auto& c : cmds) queue_.push(c);
  return commands_pushed;
}
```

- [ ] **Step 6: Update exploration test**

In `FLASHIda_exploration_test.cpp`, update all `Exploration` constructions to pass a `Deconvolution` reference. Add a Deconvolution object alongside Config/Queue in test setup:

Where tests construct `Exploration exploration(cfg)`, change to:
```cpp
Deconvolution deconv(cfg);
Exploration exploration(cfg, deconv);
```

Update `feedResult` calls from:
```cpp
exploration.feedResult(tracking_id, ds, static_cast<double>(i), queue);
```
to passing raw arrays. For tests using `makeSyntheticDeconv`, convert to raw arrays or use nullptr for "no spectrum" cases:
```cpp
// For tests that don't need real deconvolution (score from synthetic data):
exploration.feedResult(tracking_id, nullptr, nullptr, 0, static_cast<double>(i), queue);
```

Note: With `nullptr` input, `feedResult` will create an empty `DeconvolvedSpectrum`. Tests using `makeSyntheticDeconv` to control the score will need to be restructured — either:
(a) construct real mz/int arrays that produce the desired peak group count after deconvolution, or
(b) keep a test-only overload. Approach (a) is preferred but may require reading `ms2_hcd_fragment.txt` test data. If the test data files are available, use approach (a). If not available (NOT_TESTABLE guard), use approach (b) by adding a `feedResultForTest` method that accepts `DeconvolvedSpectrum` directly.

- [ ] **Step 7: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Move MS2 deconvolution into Exploration::feedResult"
```

---

## Task 5: Real computeRemainingPrecursorScore_ (Item 7)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:313-320`
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add remaining_precursor_target to Config**

In `Config.h`, add to `MSLevelConfig` (after `tolerance_ppm` on line 94):
```cpp
double tolerance_ppm = 10.0;
double remaining_precursor_target = 0.1;  ///< Target remaining precursor ratio (0.1 = 10%)
```

In `Config.cpp`, parse it from exploration JSON (after line 309, inside the exploration block):
```cpp
cfg.remaining_precursor_target = expl_obj.value("remaining_precursor_target", 0.1);
```

Update the static default on line 53 to include the new field:
```cpp
10.0,                          // tolerance_ppm
0.1                            // remaining_precursor_target
```

- [ ] **Step 2: Update scoring signature in Exploration.h**

Replace the private method signature (line 146):
```cpp
double computeRemainingPrecursorScore_(const DeconvolvedSpectrum& spec) const;
```
with:
```cpp
double computeRemainingPrecursorScore_(const ExplorationGroup& group,
    const double* mzs, const double* ints, int length) const;
```

Also update `computeExplorationScore_` (line 140) to pass through the raw data:
```cpp
double computeExplorationScore_(ExplorationMetric metric,
    const DeconvolvedSpectrum& spec,
    const ExplorationGroup& group,
    const double* mzs, const double* ints, int length) const;
```

- [ ] **Step 3: Implement real scoring in Exploration.cpp**

Replace `computeRemainingPrecursorScore_` (lines 313-320):
```cpp
double Exploration::computeRemainingPrecursorScore_(const ExplorationGroup& group,
    const double* mzs, const double* ints, int length) const
{
  if (length <= 0 || mzs == nullptr || ints == nullptr)
    return 0.0;

  // Sum intensity within the precursor isolation window
  double iso_half = group.isolation_width / 2.0;
  double mz_low = group.precursor_mz - iso_half;
  double mz_high = group.precursor_mz + iso_half;

  double remaining_intensity = 0.0;
  for (int i = 0; i < length; ++i)
  {
    if (mzs[i] >= mz_low && mzs[i] <= mz_high)
      remaining_intensity += ints[i];
  }

  // Reference: charge-specific intensity from the precursor PeakGroup
  double reference = group.precursor_pg.getChargeIntensity(
      std::abs(group.precursor_charge));
  if (reference <= 0.0)
    reference = group.precursor_pg.getIntensity();
  if (reference <= 0.0)
    return 0.0;

  double ratio = remaining_intensity / reference;
  // Score = 1 - ratio, clamped to [0, 1]. Higher = less remaining = better fragmentation.
  double score = 1.0 - ratio;
  if (score < 0.0) score = 0.0;
  if (score > 1.0) score = 1.0;
  return score;
}
```

Update `computeExplorationScore_` to pass through the new params:
```cpp
double Exploration::computeExplorationScore_(ExplorationMetric metric,
    const DeconvolvedSpectrum& spec,
    const ExplorationGroup& group,
    const double* mzs, const double* ints, int length) const
{
  switch (metric)
  {
    case ExplorationMetric::MassCount:
      return computeMassCount_(spec);
    case ExplorationMetric::RemainingPrecursor:
      return computeRemainingPrecursorScore_(group, mzs, ints, length);
    case ExplorationMetric::FragmentCount:
      return computeFragmentCount_(spec);
    default:
      return computeMassCount_(spec);
  }
}
```

Update the call site in `feedResult` (around line 156) to pass the new args:
```cpp
v.score = computeExplorationScore_(group.exploration_metric, ms2_deconv,
                                    group, mzs, ints, length);
```

- [ ] **Step 4: Store isolation_width in ExplorationGroup**

In `Exploration.cpp::initiate()`, after setting `group.precursor_mz` (around line 82), also store the isolation width:
```cpp
auto [mz1, mz2] = pg.getMzRange(charge);
group.precursor_mz = (mz1 + mz2) / 2.0;
group.isolation_width = mz2 - mz1;  // already in ExplorationGroup struct
```

The `isolation_width` field already exists in `ExplorationGroup` (Exploration.h line 84). Verify it's being set — if not, add the assignment.

- [ ] **Step 5: Write unit tests**

Add to `FLASHIda_exploration_test.cpp`, after existing test sections:

```cpp
START_SECTION(remaining_precursor_score_no_signal)
{
  Config cfg{std::string(remaining_precursor_config)};
  Deconvolution deconv(cfg);
  Exploration exploration(cfg, deconv);

  // Create a group manually via initiate
  ScanCommandQueue queue(cfg);
  auto pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  pg.setChargeIntensity(3, 1000.0);  // reference intensity
  auto cmds = exploration.initiate(2, pg, 3, 0.0, queue);

  // Feed a spectrum with NO signal in the precursor window (800 m/z ± iso_width/2)
  // -> remaining = 0, score should be ~1.0
  std::vector<double> mzs = {400.0, 500.0, 600.0};  // all outside precursor window
  std::vector<double> intensities = {100.0, 200.0, 300.0};
  int tracking_id = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));

  // Feed first variant only — score is computed per-variant
  exploration.feedResult(tracking_id, mzs.data(), intensities.data(),
                         static_cast<int>(mzs.size()), 1.0, queue);

  // Check the variant score (access via group)
  auto group = exploration.getGroup(1);
  TEST_REAL_SIMILAR(group.variants[0].score, 1.0)
}
END_SECTION

START_SECTION(remaining_precursor_score_full_signal)
{
  Config cfg{std::string(remaining_precursor_config)};
  Deconvolution deconv(cfg);
  Exploration exploration(cfg, deconv);

  ScanCommandQueue queue(cfg);
  auto pg = makeSyntheticPeakGroup(800.0, 2400.0, 3);
  pg.setChargeIntensity(3, 1000.0);
  auto cmds = exploration.initiate(2, pg, 3, 0.0, queue);

  // Feed spectrum with 100% signal in precursor window
  std::vector<double> mzs = {799.0, 800.0, 801.0};
  std::vector<double> intensities = {300.0, 400.0, 300.0};  // 1000 total = reference
  int tracking_id = queue.decode(std::string(cmds[0].scan_description).substr(0, 3));

  exploration.feedResult(tracking_id, mzs.data(), intensities.data(),
                         static_cast<int>(mzs.size()), 1.0, queue);

  auto group = exploration.getGroup(1);
  TEST_REAL_SIMILAR(group.variants[0].score, 0.0)
}
END_SECTION
```

Add the `remaining_precursor_config` JSON string in the anonymous namespace — copy `exploration_config` but change the exploration metric to `"remaining_precursor"`.

- [ ] **Step 6: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Implement real computeRemainingPrecursorScore_ with unit tests"
```

---

## Task 6: Real computeFragmentCount_ with Sequence Matching (Item 8)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:322-325`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` (validation)
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` (constructor)
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Add FragmentAnalysis& to Exploration**

In `Exploration.h`, add include:
```cpp
#include <OpenMS/ANALYSIS/TOPDOWN/FLASHIda/FragmentAnalysis.h>
```

Add member after `Deconvolution& deconv_;`:
```cpp
Deconvolution& deconv_;
FragmentAnalysis& fragments_;
```

Update constructor:
```cpp
Exploration(const Config& config, Deconvolution& deconv, FragmentAnalysis& fragments);
```

- [ ] **Step 2: Update constructor in Exploration.cpp**

```cpp
Exploration::Exploration(const Config& config, Deconvolution& deconv, FragmentAnalysis& fragments)
  : config_(config), deconv_(deconv), fragments_(fragments)
{
}
```

- [ ] **Step 3: Implement real computeFragmentCount_**

Replace lines 322-325:
```cpp
double Exploration::computeFragmentCount_(const DeconvolvedSpectrum& spec) const
{
  const auto& seq = config_.targeting().protein_sequence;
  if (seq.empty() || spec.empty())
    return 0.0;

  // Use a local mutable copy for fragment matching (API requires non-const)
  DeconvolvedSpectrum spec_copy = spec;

  const int max_matches = 100;
  std::vector<double> masses(max_matches), qscores(max_matches);
  std::vector<double> wstarts(max_matches), wends(max_matches);
  std::vector<int> charges(max_matches);
  std::vector<char> ion_types(max_matches, '\0');
  std::vector<int> frag_indices(max_matches, 0);

  int count = fragments_.getTopFragmentMatches(
      seq, max_matches,
      masses.data(), qscores.data(), charges.data(),
      wstarts.data(), wends.data(),
      ion_types.data(), frag_indices.data(),
      spec_copy);

  return static_cast<double>(count);
}
```

- [ ] **Step 4: Add validation rule 5 to Config::validate()**

In `Config.cpp::validate()`, after the exploration scan count check (line 373), add:
```cpp
for (const auto& [lvl, cfg] : levels_)
{
  if (cfg.exploration == ExplorationMetric::FragmentCount && targeting_.protein_sequence.empty())
    throw std::invalid_argument(
        "ExplorationMetric::FragmentCount at level " + std::to_string(lvl) +
        " requires a non-empty protein_sequence in the ms3 config section.");
}
```

- [ ] **Step 5: Update FLASHIda construction**

In `FLASHIda.h`/`.cpp`, update the `exploration_` member initialization to also pass `fragments_`:
```cpp
exploration_(config_, deconv_, fragments_)
```

- [ ] **Step 6: Update exploration test constructions**

All `Exploration` constructions in the test file need a `FragmentAnalysis` reference:
```cpp
Deconvolution deconv(cfg);
FragmentAnalysis fragments(cfg);
Exploration exploration(cfg, deconv, fragments);
```

- [ ] **Step 7: Write unit test for fragment count validation**

```cpp
START_SECTION(fragment_count_requires_protein_sequence)
{
  // Config with fragment_count metric but empty protein_sequence should throw
  std::string cfg_str = std::string(exploration_config);
  // Replace mass_count with fragment_count in the config
  auto pos = cfg_str.find("\"mass_count\"");
  cfg_str.replace(pos, 12, "\"fragment_count\"");

  TEST_EXCEPTION(std::invalid_argument, Config cfg{cfg_str})
}
END_SECTION
```

- [ ] **Step 8: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Exploration.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Implement sequence-aware computeFragmentCount_ with validation"
```

---

## Task 7: Log Exploration Metrics to Results TSV (Item 9)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:268-272`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:96-98,305-336,568,625,699-701,802`

- [ ] **Step 1: Extend writeScanResultRow_ signature**

In `FLASHIda.h`, update the signature (lines 268-273):
```cpp
void writeScanResultRow_(const std::string& tracking_id, double rt,
                         int mass_count, int commands_pushed,
                         const std::vector<std::string>& child_ids,
                         int tag_count, const std::string& matched_protein,
                         const std::string& proteoform_sequence,
                         uint64_t enqueue_ts,
                         float tic_coverage = 0.0f, int fragment_count = 0);
```

- [ ] **Step 2: Extend TSV header**

In `FLASHIda.cpp`, update the results TSV header (lines 96-98):
```cpp
results_tsv_stream_ << "tracking_id\tresolve_ts\tduration_ms\trt\t"
                    << "mass_count\tcommands_pushed\tchild_ids\t"
                    << "tag_count\tmatched_protein\tproteoform_sequence\t"
                    << "tic_coverage\tfragment_count\n";
```

- [ ] **Step 3: Append columns to writeScanResultRow_ body**

In the `writeScanResultRow_` implementation (around lines 305-336), before the newline at the end of the row, append the two new columns:
```cpp
results_tsv_stream_ << "\t" << tic_coverage << "\t" << fragment_count << "\n";
```

- [ ] **Step 4: Add writeScanResultRow_ call for exploration path**

In `processMS2Path_`, after the exploration `feedResult` call (around line 699-701), before `return commands_pushed;`, add:
```cpp
if (exploration_.isExplorationVariant(tracking_id))
{
  auto cmds = exploration_.feedResult(tracking_id, mzs, ints, length, rt_min, queue_);
  for (auto& c : cmds) queue_.push(c);

  // Log exploration result to TSV
  int expl_mass_count = deconv_.hasStoredMS2() ? static_cast<int>(deconv_.storedMS2().size()) : 0;
  writeScanResultRow_(id_str, rt_min, expl_mass_count, static_cast<int>(cmds.size()),
                      {}, 0, "", "", 0);

  return commands_pushed;
}
```

Note: `tic_coverage` and `fragment_count` use default values (0.0f, 0) for now. Wiring the actual values from `ExplorationVariant` requires `feedResult` to expose them, which can be done later or by reading `deconv_.storedMS2()` metrics post-deconvolution.

- [ ] **Step 5: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Add tic_coverage and fragment_count columns to results TSV"
```

---

## Task 8: Fragment-Aware initiateNextLevel (Item 10)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp:236-280`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp` (validation rule 4)

- [ ] **Step 1: Add validation rule 4**

In `Config.cpp::validate()`, add after the `FragmentCount` validation:
```cpp
for (const auto& [lvl, cfg] : levels_)
{
  if (lvl >= 2 && cfg.selection != SelectionMetric::None && targeting_.protein_sequence.empty())
    throw std::invalid_argument(
        "SelectionMetric at level " + std::to_string(lvl) +
        " requires a non-empty protein_sequence in the ms3 config section. "
        "Fragment matching is the default for all MSn>=2 selection.");
}
```

- [ ] **Step 2: Rewrite initiateNextLevel**

Replace `Exploration::initiateNextLevel` (lines 236-280) with:

```cpp
std::vector<ScanCommand> Exploration::initiateNextLevel(int msn_level,
    const DeconvolvedSpectrum& result, double faims_cv, ScanCommandQueue& queue)
{
  std::vector<ScanCommand> commands;

  int next_level = msn_level + 1;
  const auto& next_cfg = config_.level(next_level);
  if (next_cfg.selection == SelectionMetric::None) return commands;

  const auto& seq = config_.targeting().protein_sequence;
  int num_targets = next_cfg.max_targets;

  // Use fragment matching to select targets
  DeconvolvedSpectrum result_copy = result;
  const int max_frags = 100;
  std::vector<double> masses(max_frags), qscores(max_frags);
  std::vector<double> wstarts(max_frags), wends(max_frags);
  std::vector<int> charges(max_frags);
  std::vector<char> ion_types(max_frags, '\0');
  std::vector<int> frag_indices(max_frags, 0);
  int found = 0;

  switch (next_cfg.selection)
  {
    case SelectionMetric::Intensity:
    case SelectionMetric::QScore:
      found = fragments_.getTopFragmentMatches(seq, max_frags,
          masses.data(), qscores.data(), charges.data(),
          wstarts.data(), wends.data(),
          ion_types.data(), frag_indices.data(), result_copy);
      // getTopFragmentMatches returns sorted by qscore; re-sort by intensity if needed
      if (next_cfg.selection == SelectionMetric::Intensity && found > 1)
      {
        // Build index array and sort by intensity (qscores array stores intensities for mode 1)
        std::vector<int> idx(found);
        std::iota(idx.begin(), idx.end(), 0);
        std::sort(idx.begin(), idx.end(),
                  [&qscores](int a, int b){ return qscores[a] > qscores[b]; });
        // Reorder all arrays by the new index
        auto reorder = [&idx](auto& arr, int n) {
          auto copy = std::vector<std::decay_t<decltype(arr[0])>>(arr, arr + n);
          for (int i = 0; i < n; ++i) arr[i] = copy[idx[i]];
        };
        reorder(masses.data(), found);
        reorder(qscores.data(), found);
        reorder(charges.data(), found);
        reorder(wstarts.data(), found);
        reorder(wends.data(), found);
        reorder(ion_types.data(), found);
        reorder(frag_indices.data(), found);
      }
      break;

    default:
      break;
  }

  num_targets = std::min(num_targets, found);

  // Build commands for each selected fragment target
  ScanConfig next_scan_config = next_cfg.scans.empty() ? ScanConfig{} : next_cfg.scans[0];

  if (config_.hasExploration(next_level))
  {
    for (int ti = 0; ti < num_targets; ++ti)
    {
      PeakGroup frag_pg(std::abs(charges[ti]), std::abs(charges[ti]), true);
      frag_pg.setMonoisotopicMass(masses[ti]);
      FLASHHelperClasses::LogMzPeak lp;
      lp.mz = (wstarts[ti] + wends[ti]) / 2.0;
      lp.abs_charge = std::abs(charges[ti]);
      frag_pg.push_back(lp);

      auto sub_cmds = initiate(next_level, frag_pg, std::abs(charges[ti]), faims_cv, queue);
      commands.insert(commands.end(), sub_cmds.begin(), sub_cmds.end());
    }
  }
  else
  {
    for (int ti = 0; ti < num_targets; ++ti)
    {
      double frag_mz = (wstarts[ti] + wends[ti]) / 2.0;
      double iso_width = wends[ti] - wstarts[ti];
      // For MSn+1, we need the MS2 context — create a synthetic one
      // Build as MS3 if next_level == 3, otherwise as MS2
      if (next_level == 3)
      {
        // Need an MS2 context command — get from deconv stored state
        // For now, build directly using queue.buildMS3 pattern
        // This path is used when the caller has the MS2 context available
      }

      ScanCommand cmd{};
      cmd.msn_level = next_level;
      cmd.priority = 1;
      cmd.scan_id = queue.nextTrackingId();
      cmd.num_stages = (next_level >= 3) ? 2 : 1;
      cmd.stages[next_level - 2].precursor_mz = frag_mz;
      cmd.stages[next_level - 2].isolation_width = iso_width;
      cmd.stages[next_level - 2].charge_state = charges[ti];
      cmd.stages[next_level - 2].collision_energy =
          static_cast<double>(next_scan_config.collision_energy);
      std::strncpy(cmd.stages[next_level - 2].activation_type,
                   next_scan_config.activation.c_str(),
                   sizeof(cmd.stages[0].activation_type) - 1);

      std::string id_str = ScanCommandQueue::encode(cmd.scan_id);
      cmd.faims_cv = faims_cv;

      std::cout << "[TRACK-CREATE] id=" << id_str
                << " ms_level=" << next_level << " type=next_level"
                << std::endl;

      commands.push_back(cmd);
    }
  }

  return commands;
}
```

**Important note:** The above implementation is a first draft. The `initiateNextLevel` method needs to handle both the exploration path (calling `initiate()` recursively) and the direct command-building path. The `TerminalFragments` and `AmbiguityResolution` dispatch will be added in Task 9. For now, `Intensity` and `QScore` are the only handled cases.

- [ ] **Step 3: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git commit -m "Fragment-aware initiateNextLevel with SelectionMetric sorting"
```

---

## Task 9: Extend SelectionMetric + Delete Legacy MS3 (Item 11)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:49-54`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:287-290`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp` (initiateNextLevel dispatch)
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:227-230`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:631-673,775-786`
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Extend SelectionMetric enum**

In `Config.h:49-54`, replace:
```cpp
enum class SelectionMetric
{
  None = 0,    ///< No selection at this level -- don't select targets for MSn+1
  Intensity,   ///< Rank by raw intensity
  QScore       ///< Rank by deconvolution quality score
};
```
with:
```cpp
enum class SelectionMetric
{
  None = 0,              ///< No selection at this level
  Intensity,             ///< Rank by raw intensity
  QScore,                ///< Rank by deconvolution quality score
  TerminalFragments,     ///< Innermost b/y ions, interleaved
  AmbiguityResolution    ///< PTM-site bracketing ions
};
```

- [ ] **Step 2: Add string parsing for new values**

In `Config.cpp`, in the selection metric parsing block (around lines 287-290), add:
```cpp
if (sel_str == "intensity") cfg.selection = SelectionMetric::Intensity;
else if (sel_str == "qscore") cfg.selection = SelectionMetric::QScore;
else if (sel_str == "none") cfg.selection = SelectionMetric::None;
else if (sel_str == "terminal_fragments") cfg.selection = SelectionMetric::TerminalFragments;
else if (sel_str == "ambiguity_resolution") cfg.selection = SelectionMetric::AmbiguityResolution;
else cfg.selection = SelectionMetric::Intensity;
```

- [ ] **Step 3: Add dispatch in initiateNextLevel**

In `Exploration.cpp::initiateNextLevel`, extend the switch to handle the new metrics:

```cpp
switch (next_cfg.selection)
{
  case SelectionMetric::Intensity:
  case SelectionMetric::QScore:
    found = fragments_.getTopFragmentMatches(seq, max_frags,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(), result_copy);
    // Re-sort by intensity if needed (getTopFragmentMatches sorts by qscore)
    if (next_cfg.selection == SelectionMetric::Intensity && found > 1)
    {
      // ... sorting logic from Task 8 ...
    }
    break;

  case SelectionMetric::TerminalFragments:
    found = fragments_.getTerminalFragmentIons(seq, max_frags,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(), result_copy);
    break;

  case SelectionMetric::AmbiguityResolution:
    found = fragments_.getAmbiguityEnclosingIons(seq, max_frags,
        masses.data(), qscores.data(), charges.data(),
        wstarts.data(), wends.data(),
        ion_types.data(), frag_indices.data(), result_copy);
    break;

  default:
    break;
}
```

- [ ] **Step 4: Delete selectMS3Targets_ and MS3Target**

In `FLASHIda.h`:
- Remove `using MS3Target = ScanCommandQueue::MS3Target;` (line 227)
- Remove `std::vector<MS3Target> selectMS3Targets_();` (line 230)

In `FLASHIda.cpp`:
- Delete the entire `selectMS3Targets_` method body (lines 631-673)

In `ScanCommandQueue.h`:
- Remove the `MS3Target` struct (lines 93-101) if no other code references it. Check first.

- [ ] **Step 5: Delete legacy MS3 branch in processMS2Path_**

In `FLASHIda.cpp`, delete the middle branch (lines 775-786):
```cpp
else if (config_.targeting().ms3_enabled && config_.targeting().ms3_mode > 0)
{
  // Legacy MS3 targeting (non-exploration, requires explicit ms3.enabled=true)
  auto ms3_targets = selectMS3Targets_();
  for (const auto& t : ms3_targets)
  {
    ScanCommand ms3_cmd = queue_.buildMS3(ctx, t.center_mz, t.charge, t.iso_width,
                                           t.ion_type, t.frag_index);
    queue_.push(ms3_cmd);
    child_ids.push_back(ScanCommandQueue::encode(ms3_cmd.scan_id));
    commands_pushed++;
  }
}
```

- [ ] **Step 6: Write config parsing tests**

Add to `FLASHIda_exploration_test.cpp`:

```cpp
START_SECTION(selection_metric_terminal_fragments_parsing)
{
  std::string cfg_str = std::string(exploration_config);
  // Replace ms2 selection from "intensity" to "terminal_fragments"
  // and add protein_sequence
  auto pos = cfg_str.find("\"selection\": \"intensity\"");
  cfg_str.replace(pos, 24, "\"selection\": \"terminal_fragments\"");
  pos = cfg_str.find("\"protein_sequence\": \"\"");
  cfg_str.replace(pos, 21, "\"protein_sequence\": \"ACDEFGHIKLMNPQRSTVWY\"");

  Config cfg{cfg_str};
  TEST_EQUAL(static_cast<int>(cfg.level(2).selection),
             static_cast<int>(SelectionMetric::TerminalFragments))
}
END_SECTION

START_SECTION(selection_metric_ambiguity_resolution_parsing)
{
  std::string cfg_str = std::string(exploration_config);
  auto pos = cfg_str.find("\"selection\": \"intensity\"");
  cfg_str.replace(pos, 24, "\"selection\": \"ambiguity_resolution\"");
  pos = cfg_str.find("\"protein_sequence\": \"\"");
  cfg_str.replace(pos, 21, "\"protein_sequence\": \"ACDEFGHIKLMNPQRSTVWY\"");

  Config cfg{cfg_str};
  TEST_EQUAL(static_cast<int>(cfg.level(2).selection),
             static_cast<int>(SelectionMetric::AmbiguityResolution))
}
END_SECTION

START_SECTION(terminal_fragments_requires_protein_sequence)
{
  std::string cfg_str = std::string(exploration_config);
  auto pos = cfg_str.find("\"selection\": \"intensity\"");
  cfg_str.replace(pos, 24, "\"selection\": \"terminal_fragments\"");
  // protein_sequence is empty -> should throw

  TEST_EXCEPTION(std::invalid_argument, Config cfg{cfg_str})
}
END_SECTION

START_SECTION(ambiguity_resolution_requires_protein_sequence)
{
  std::string cfg_str = std::string(exploration_config);
  auto pos = cfg_str.find("\"selection\": \"intensity\"");
  cfg_str.replace(pos, 24, "\"selection\": \"ambiguity_resolution\"");

  TEST_EXCEPTION(std::invalid_argument, Config cfg{cfg_str})
}
END_SECTION
```

- [ ] **Step 7: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Exploration.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp \
        OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.h \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Extend SelectionMetric with TerminalFragments and AmbiguityResolution, delete legacy MS3 path"
```

---

## Task 10: Remove Legacy MS3 Config Fields + Reject Keys (Item 12)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:126-155`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:159-168,323`
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:202-224`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:210-216,513-519`
- Modify: ~21 JSON config files
- Test: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp`

- [ ] **Step 1: Remove fields from TargetingConfig in Config.h**

Remove these 4 lines from `TargetingConfig`:
```cpp
bool ms3_all_charges = false;      // line 134
bool ms3_enabled = false;          // line 139
int ms3_mode = 0;                  // line 140
int max_ms3_per_ms2 = 4;          // line 141
```

Keep `std::string protein_sequence;` (line 142).

- [ ] **Step 2: Remove parsing and add legacy key rejection in Config.cpp**

Remove from the `ms3` parsing section (lines 159-168):
```cpp
targeting_.ms3_enabled = ms3.value("enabled", false);
targeting_.ms3_mode = ms3.value("mode", 0);
```
and:
```cpp
int ms3_max_per_ms2 = ms3.value("max_per_ms2", 4);
if (ms3.contains("all_charges"))
  targeting_.ms3_all_charges = ms3.value("all_charges", false);
```

Remove line 323:
```cpp
targeting_.max_ms3_per_ms2 = ms3_max_per_ms2;
```

Remove line 116 (or wherever `ms3_all_charges` is set from `precursor_selection`):
```cpp
targeting_.ms3_all_charges = ps.value("MS3AllCharges", false);
```

Add legacy key rejection after the `ms3` section parse:
```cpp
// Reject legacy MS3 keys — force migration to selection_strategy
auto ms3 = config.value("ms3", json::object());
targeting_.protein_sequence = ms3.value("protein_sequence", "");
static const std::vector<std::string> legacy_ms3_keys = {"enabled", "mode", "all_charges", "max_per_ms2"};
for (const auto& key : legacy_ms3_keys)
{
  if (ms3.contains(key))
    throw std::invalid_argument(
        "Config: ms3." + key + " is no longer supported. "
        "Migrate MS3 targeting to selection_strategy.ms2. "
        "See processScan-cleanup.md item 12 for migration guide.");
}
```

- [ ] **Step 3: Remove from all C++ code that reads these fields**

Search for `ms3_enabled`, `ms3_mode`, `ms3_all_charges`, `max_ms3_per_ms2` in all `.cpp` and `.h` files. Remove or update any remaining references. The `selectMS3Targets_` deletion in Task 9 should have removed the main consumers. Verify no dangling references remain.

- [ ] **Step 4: Update C# MethodConfig.cs**

In `Ms3Config` class (lines 202-224), remove:
- `Active` property (lines 205-207)
- `Mode` property (lines 209-211)
- `MaxPerMs2` property (lines 213-215)
- `AllCharges` property (lines 217-219)

Keep only:
```csharp
[JsonKey("ms3")]
public class Ms3Config
{
    [JsonKey("protein_sequence")]
    [Description("Protein sequence for targeted MS3 characterization")]
    public string ProteinSequence { get; set; } = "";
}
```

- [ ] **Step 5: Update C# MethodParameters.cs**

In `ToCppJson()` (lines 210-216), replace:
```csharp
ms3 = new JsonMs3Config
{
    enabled = c.Ms3.Active,
    mode = c.Ms3.Mode,
    max_per_ms2 = c.Ms3.MaxPerMs2,
    protein_sequence = c.Ms3.ProteinSequence ?? ""
},
```
with:
```csharp
ms3 = new JsonMs3Config
{
    protein_sequence = c.Ms3.ProteinSequence ?? ""
},
```

Update `JsonMs3Config` (lines 513-519):
```csharp
public class JsonMs3Config
{
    public string protein_sequence { get; set; }
}
```

- [ ] **Step 6: Migrate all JSON config files**

In every JSON file under `FlashIDA/test-data/configs/` and `FlashIDA/src/Flash/etc/`:

Remove from the `ms3` section: `"active"`, `"mode"`, `"all_charges"`, `"max_per_ms2"`. Keep `"protein_sequence"`.

For files that had `ms3.mode > 0` (e.g., `method_ms3_mode1.json`), ensure `selection_strategy.ms2` has the appropriate `selection` and `max_targets`:

Example migration for `method_ms3_mode1.json`:
```json
"ms3": {
    "protein_sequence": "GDVEKGKK..."
},
"selection_strategy": {
    "ms1": { "selection": "qscore", "max_targets": 1 },
    "ms2": { "selection": "intensity", "max_targets": 4 }
}
```

Also update embedded JSON strings in C++ test files — remove the `ms3` legacy fields from any JSON config strings.

- [ ] **Step 7: Write legacy key rejection tests**

Add to `FLASHIda_exploration_test.cpp`:

```cpp
START_SECTION(legacy_ms3_enabled_rejected)
{
  std::string cfg_str = std::string(exploration_config);
  // exploration_config has "ms3": { "enabled": false, "mode": 0, ... }
  // After migration it should only have protein_sequence.
  // Test with "enabled" present -> should throw

  // Build a config with ms3.enabled present
  std::string test_cfg = cfg_str;  // already has "enabled": false in ms3
  TEST_EXCEPTION(std::invalid_argument, Config cfg{test_cfg})
}
END_SECTION

START_SECTION(legacy_ms3_mode_rejected)
{
  // Build config with only ms3.mode present (no enabled)
  std::string test_cfg = R"({"ms3": {"mode": 1, "protein_sequence": "ABC"}, ...})";
  // Use a full valid config with only ms3.mode added
  TEST_EXCEPTION(std::invalid_argument, Config cfg{test_cfg})
}
END_SECTION

START_SECTION(ms3_protein_sequence_only_accepted)
{
  // Config with only ms3.protein_sequence should be accepted
  std::string cfg_str = std::string(exploration_config);
  // Replace ms3 section with only protein_sequence
  auto ms3_start = cfg_str.find("\"ms3\":");
  auto ms3_end = cfg_str.find("}", ms3_start) + 1;
  cfg_str.replace(ms3_start, ms3_end - ms3_start,
                  "\"ms3\": { \"protein_sequence\": \"\" }");

  Config cfg{cfg_str};  // should not throw
  TEST_EQUAL(cfg.targeting().protein_sequence.empty(), true)
}
END_SECTION
```

**Important:** The existing test JSON configs (`exploration_config`, etc.) all contain the legacy `ms3` keys. These MUST be updated first (Step 6) before any test that constructs a `Config` from them will pass. Update all JSON string literals in the test file to remove `"enabled"`, `"mode"`, `"all_charges"`, `"max_per_ms2"` from their `ms3` sections.

- [ ] **Step 8: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp \
        FlashIDA/src/Flash/MethodConfig.cs FlashIDA/src/Flash/MethodParameters.cs \
        FlashIDA/test-data/configs/ FlashIDA/src/Flash/etc/ \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp \
        OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp
git commit -m "Remove legacy MS3 config fields, reject stale keys, migrate JSON configs"
```

---

## Task 11: Collapse Step 5 MS3 Targeting (Item 13)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:763-797`

- [ ] **Step 1: Replace three branches with one**

Replace the entire Step 5 block (lines 763-797):
```cpp
// Step 5: MS3 targeting -- uses config levels when exploration is configured,
// falls back to legacy MS3 targeting path for standard MS3 targeting
if (config_.hasExploration(3))
{
  // MS3 exploration: create exploration groups for top fragments
  auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_);
  for (auto& c : cmds)
  {
    queue_.push(c);
    child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
  }
}
else if (config_.targeting().ms3_enabled && config_.targeting().ms3_mode > 0)
{
  // ... deleted by Task 9 ...
}
else if (config_.level(3).selection != SelectionMetric::None && !config_.targeting().ms3_enabled)
{
  // New selection_strategy MS3 targeting (no exploration, not legacy)
  auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_);
  for (auto& c : cmds)
  {
    queue_.push(c);
    child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
  }
}
```

with:
```cpp
// Step 5: MS3 targeting via selection_strategy
if (config_.level(2).selection != SelectionMetric::None)
{
  auto cmds = exploration_.initiateNextLevel(2, deconv_.storedMS2(), ctx.faims_cv, queue_);
  for (auto& c : cmds)
  {
    queue_.push(c);
    child_ids.push_back(ScanCommandQueue::encode(c.scan_id));
    commands_pushed++;
  }
}
```

Note: checks `config_.level(2).selection` (MS2 level) because MS3 scans are MS2 targets.

- [ ] **Step 2: Verify existing tests still pass**

The existing `FLASHIda_ProcessScan_test::processScan_ms3_commands` and exploration test MS3 sections should still pass because:
- MS3 mode 1 configs were migrated to `selection_strategy.ms2.selection = "intensity"` in Task 10
- `initiateNextLevel(2, ...)` uses `config_.level(2+1=3)` internally but checks `config_.level(2).selection` at the call site
- The exploration MS3 tests use `config_.hasExploration(3)` which routes through `initiateNextLevel` as before

Wait — verify the condition logic. The old code checked `config_.hasExploration(3)` (exploration at MS3 level) and `config_.level(3).selection != None`. The new code checks `config_.level(2).selection != None`. This is correct because "selecting targets from MS2 results" IS the MS2 level's selection config. But existing test configs may have `selection_strategy.ms2.selection = "intensity"` without `selection_strategy.ms3` — verify all MS3 test configs have the right `ms2` selection value.

- [ ] **Step 3: Commit**

```bash
git add OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Collapse Step 5 MS3 targeting to single initiateNextLevel call"
```

---

## Task 12: Inline processMS2Path_ (Item 3)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:233`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:602,675+`

- [ ] **Step 1: Inline the method body**

In `FLASHIda.cpp`, replace line 602:
```cpp
return processMS2Path_(mzs, ints, length, rt_min, scan_description);
```
with the entire body of `processMS2Path_` (starting from `int commands_pushed = 0;` through `return commands_pushed;`), using the original parameter names from `processScan` (`scan_description` instead of `scan_desc`).

- [ ] **Step 2: Delete the method definition**

Remove the entire `processMS2Path_` method definition (lines 675 to ~814).

- [ ] **Step 3: Delete the declaration**

In `FLASHIda.h`, remove line 233:
```cpp
int processMS2Path_(const double* mzs, const double* ints, int length, double rt_min, const char* scan_desc);
```

- [ ] **Step 4: Verify no references remain**

Search for `processMS2Path_` in all files — should find zero results.

- [ ] **Step 5: Commit**

```bash
git add OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Inline processMS2Path_ into processScan"
```

---

## Post-Implementation

After all 12 tasks are complete:
1. Push to `flashida-v9-bridge` for CI build
2. Wait for `build-dlls` workflow
3. Download new OpenMS DLLs and update `FlashIDA/dll/`
4. Push FlashIDA changes to `phase-11`
5. Update submodule pointer in parent repo

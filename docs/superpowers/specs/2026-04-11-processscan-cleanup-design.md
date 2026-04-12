# processScan Cleanup Design

## Goal

Seven incremental improvements to `FLASHIda::processScan()`, `getNextScanCommand()`, and supporting classes. Fixes timing semantics, FAIMS CV propagation, exploration flow ordering, config validation, and scan construction consolidation.

## Branch

`phase-10` (on top of IDA logging work)

## Architecture

All changes are in the C++ OpenMS codebase (`ANALYSIS/TOPDOWN/FLASHIda/`). No C# changes. The core refactoring is consolidating `buildMS2` into a single factory method that receives a fully resolved `ScanConfig`, which cascades into cleaner CE determination, exploration flow, and follow-up scan construction.

## Implementation Order

Dependency-ordered (foundations first, consumers second):

1. Config validation (gates invalid combos all other tasks assume won't happen)
2. FAIMS CV as `double` (independent type change)
3. Move `recordMS1Time()` to dequeue (independent)
4. Consolidate `buildMS2` (foundation for 5 and 6)
5. Simplify CE logic (consequence of unified factory)
6. Reorder exploration before final MS2 (uses unified factory)
7. Follow-up scan configs into feature sections (largest config schema change)

---

## Task 1: Config Validation

### Problem

IDScore and exploration both determine optimal fragmentation energy (analytical vs empirical). Running both is a config error that should fail at startup, not silently misbehave at runtime. Additionally, exploration at a level should require exactly one scan config (the sweep varies CE; multiple scan configs are meaningless).

### Design

Add `void validate() const` to `Config`, called at the end of the constructor after `exploration_enabled_` is computed (after line ~283 in Config.cpp).

**Rules:**
- `targeting_.use_idscore && exploration_enabled_` -> `std::invalid_argument("IDScore and exploration cannot both be enabled. IDScore determines optimal HCD analytically; exploration determines it empirically via CE sweep.")`
- For each level: if `cfg.exploration != ExplorationMetric::None && cfg.scans.size() != 1` -> `std::invalid_argument("Exploration at level N requires exactly one scan config.")`

**Files:**
- `Config.h` -- declare `void validate() const;`
- `Config.cpp` -- implement and call at end of constructor

**Testing:** Construct `Config` with invalid JSON combos, assert `std::invalid_argument` is thrown.

---

## Task 2: FAIMS CV as `double`

### Problem

`filterAndRank` takes `const char* cv` but `processScan` always passes `nullptr`. The CV value is available as a `double` (`faims_cv`) in scope. Passing it through enables proper CV annotation on `DeconvolvedSpectrum` metadata, which matters for FAIMS runs where different CVs produce different precursor populations.

### Design

Type change through the call chain:

1. `PrecursorSelection::filterAndRank` -- last param `const char* cv` -> `double faims_cv`
   - Header: `PrecursorSelection.h`
   - Source: `PrecursorSelection.cpp`
2. `Deconvolution::deconvolveMS1` -- last param `const char* cv` -> `double faims_cv`
   - Header: `Deconvolution.h`
   - Source: `Deconvolution.cpp`
   - String conversion stays internal: `if (faims_cv != 0.0) spec.setMetaValue("filter string", DataValue("cv=" + std::to_string(faims_cv)));`
3. Call site in `processScan()` (line ~515): `nullptr` -> `faims_cv`

**Testing:** Existing FAIMS tests pass. Optionally verify `"filter string"` metadata is set when CV != 0.

---

## Task 3: Move `recordMS1Time()` to Dequeue

### Problem

Cycle time is measured result-to-result (when MS1 data arrives back) rather than send-to-send (when MS1 commands leave the engine). This also causes the idle-path timer to start one AGC scan too early.

### Design

**Remove** `queue_.recordMS1Time()` from:
- `processScan()` line ~506 (MS1 result arrival)
- Idle MS1 creation in `getNextScanCommand()` line ~868 (pushed to queue, not yet sent)

**Add** to `getNextScanCommand()` dequeue block (after line ~842):
```cpp
if (out.msn_level == 1 && out.is_agc == 0)
    queue_.recordMS1Time();
```

**Keep** `queue_.recordMS1Time()` at line ~825 (cycle-time forced MS1) -- this path bypasses the queue and returns directly.

**Files:** `FLASHIda.cpp` only.

**Testing:** Existing cycle-time tests pass.

---

## Task 4: Consolidate `buildMS2`

### Problem

Two `buildMS2` overloads exist: one with `PeakGroup` (dynamic isolation width, full scoring fields) and one with raw values (hardcoded `isolation_width = 2.0`, no scoring fields). Two overloads means two places to maintain field assignments, and the simplified one loses data.

### Design

**Single factory method:**

```cpp
ScanCommand buildMS2(const PeakGroup& pg, int charge, const ScanConfig& scan_config);
```

- `pg` + `charge`: isolation width from `pg.getMzRange(charge)`, precursor mass, scoring fields
- `scan_config`: fully resolved instrument settings (analyzer, resolution, activation, collision_energy, agc_target, mass range). Caller prepares the ScanConfig with the correct CE and any overrides before calling.

**Remove** the second overload `buildMS2(double precursor_mz, int charge, double ce, const std::string& activation)`.

**Callers prepare ScanConfig:**
- Normal (no IDScore): pass `scan_config` as-is (CE already in it from config)
- IDScore: copy `scan_config`, set `collision_energy = trigger_hcd`, pass copy
- Exploration: copy `scan_config`, apply overrides + set `collision_energy = sweep_ce`, pass copy

**`Exploration::initiate()` signature** changes to accept `const PeakGroup& pg, int charge` instead of raw `precursor_mz`, `precursor_mass`, `precursor_charge`.

**`ScanConfig::applyOverrides(const std::unordered_map<std::string, std::string>& overrides)`** -- utility method that maps string keys to struct fields. Called by exploration before passing to factory.

**Files:**
- `ScanCommandQueue.h/.cpp` -- single `buildMS2`, remove second overload
- `Exploration.h/.cpp` -- updated `initiate()` signature, uses single `buildMS2`
- `FLASHIda.cpp` -- call site updates
- `Config.h` -- `applyOverrides` on `ScanConfig`

**Note:** This task requires thorough investigation of every call site and every field `buildMS2` currently sets before making changes. The plan should include an explicit investigation step.

**Testing:** Exploration tests updated for dynamic isolation width. All existing processScan tests pass.

---

## Task 5: Simplify CE Logic

### Problem

`buildMS2` has a fallback chain (config CE -> hcd param -> hardcoded 29) that obscures intent. With the unified factory receiving a fully resolved `ScanConfig`, CE determination is entirely the caller's responsibility.

### Design

CE determination moves to the caller in `processScan()`:

- **IDScore enabled**: `scan_config.collision_energy = trigger_hcds_[i]`
- **IDScore disabled**: leave `scan_config.collision_energy` as-is from config
- **Exploration**: `scan_config.collision_energy = sweep_ce`

The hardcoded `29` fallback and the fallback chain inside `buildMS2` disappear. No magic numbers. This is a direct consequence of task 4 -- once the factory just receives a resolved `ScanConfig`, there is no CE logic left inside it.

**Files:** `ScanCommandQueue.cpp` (remove fallback chain), `FLASHIda.cpp` (caller CE logic)

**Testing:** Existing tests pass. CE values in output commands match expected config/IDScore values.

---

## Task 6: Reorder Exploration Before Final MS2

### Problem

Exploration currently runs after regular MS2 commands are pushed (wrong order). It should run instead of regular MS2. The exploration CE sweep determines optimal settings; the winning variant either IS the final MS2 (no overrides) or triggers a production MS2 (with overrides).

### Design

MS1 path in `processScan()` restructures to:

```
if exploration enabled at this level:
    for each selected precursor:
        prepare ScanConfig copies with overrides + sweep CE
        call buildMS2 for each CE variant via exploration engine
    // NO regular MS2 pushed
else:
    for each selected precursor:
        for each scan_config in level.scans:
            prepare ScanConfig copy (set CE if IDScore)
            buildMS2(pg, charge, scan_config)
            push to queue
```

**`Exploration::initiate()`** accepts `const PeakGroup& pg, int charge` instead of raw precursor fields. Calls `buildMS2` internally for each CE variant.

**`feedResult()`** -- already correct:
- If overrides existed: exploration scans were cheaper, pushes production MS2 with winning CE at normal settings
- If no overrides: winning variant was full quality, no further scan needed

**Files:** `FLASHIda.cpp`, `Exploration.h/.cpp`

**Testing:** Exploration tests verify variants are pushed instead of (not alongside) regular MS2. feedResult behavior unchanged.

---

## Task 7: Follow-up Scan Configs Into Feature Sections

### Problem

Both `buildFollowUpMS2` (quant) and `buildConditionalFollowUp` (tagging) read from `config_.level(2).scans[1]` -- a shared implicit convention. They may need different settings and should each own their follow-up scan config.

### Design

**Config changes:**
- `QuantConfig` -- add `ScanConfig follow_up_scan`
- Tagging config (fields in `TargetingConfig`) -- add `ScanConfig follow_up_scan`
- JSON parsing: parse `"follow_up_scan": { ... }` from `"tagging"` and `"quantification"` sections

**JSON structure:**
```json
"tagging": {
    "min_tag_length": 3,
    "conditional_ms2": true,
    "follow_up_scan": { "analyzer": "...", "activation": "ETD", ... }
},
"quantification": {
    "enabled": true,
    "follow_up_scan": { "analyzer": "...", "activation": "HCD", "collision_energy": 45, ... }
}
```

**Validation rules** (added to `Config::validate()`):
- If `tagging.conditional_ms2_enabled`, `follow_up_scan` must be present in tagging config
- If `quantification.enabled` and quant follow-up desired, `follow_up_scan` must be present in quant config

**ScanCommandQueue changes:**
- Replace `buildFollowUpMS2` and `buildConditionalFollowUp` with single `buildFollowUp(const ScanCommand& ctx, const ScanConfig& follow_up_config, char suffix)`
- `suffix`: `'F'` for quant, `'C'` for conditional (scan description)

**Call sites in `processMS2Path_`:**
- Quant: `buildFollowUp(ctx, config_.quantification().follow_up_scan, 'F')`
- Conditional: `buildFollowUp(ctx, config_.tagging().follow_up_scan, 'C')`
- Remove `scans.size() >= 2` guards -- replaced by config validation at startup

**`ms_settings.ms2`** becomes primary scans only. `scans[1]` is no longer overloaded.

**Files:**
- `Config.h` -- add `ScanConfig follow_up_scan` to `QuantConfig` and tagging fields
- `Config.cpp` -- parse `follow_up_scan` from JSON
- `ScanCommandQueue.h/.cpp` -- replace two methods with single `buildFollowUp`
- `FLASHIda.cpp` -- pass correct follow-up config at call sites

**Testing:** Existing quant/conditional tests updated with new JSON config format. Verify follow-up scans use feature-specific settings.

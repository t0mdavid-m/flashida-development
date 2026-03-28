# Phase 7: Exploration Engine — Implementation Plan

**Date:** 2026-03-21
**Build:** Build #4 (batched with Phase 8)
**Source documents:**
- [../implementation-roadmap.md](../implementation-roadmap.md) — Phase 7 section
- [../baseline-plan.md](../baseline-plan.md) — Issue 4 (MSn-Generalized Exploration Engine), Issue 9 (OptimizationMetadata)
- [../testing-strategy.md](../testing-strategy.md) — Phase 7 test plan
- [../test-file-specification.md](../test-file-specification.md) — Authoritative formats for spectrum files, golden files, config files, and test infrastructure scripts

---

## Goal

Implement MSn-generalized parameter exploration (collision energy optimization) as entirely new functionality. After this phase, FLASHIda can automatically sweep a range of collision energies for selected precursors, score each variant by FragmentationQuality, select a winner, and record the optimization outcome in `OptimizationMetadata` on the resulting `DeconvolvedSpectrum`. MS3 recursive exploration is also supported: after an MS2 CE winner is identified, child exploration groups can be created for MS3 CE variants on the top-scoring fragment ions.

This phase has no existing behavior to migrate. All code added here is additive to the C++ core that Phase 6 left in its final form.

---

## Prerequisites

The following must be complete and verified before starting Phase 7:

1. **Phase 6 delivered and all tests passing.** C++ fully owns the scan queue including FAIMS CV cycling. `ScanScheduler.cs` and `FAIMSScanProcessor.cs` have been deleted. `GetNextScanCommand` is the sole source of all scan commands including CV injection.

2. **`OptimizationMetadata` struct exists** (delivered in Phase 2, Build #1). `OptimizationMetadata.h` is already present in the OpenMS source tree. `DeconvolvedSpectrum` already carries `std::optional<OptimizationMetadata> opt_metadata_` and the accessor methods `getOrCreateOptimizationMetadata()`, `getOptimizationMetadata()`, `hasOptimizationMetadata()`. The `toSpectrum()` method already serializes metadata fields via `setMetaValue()` when present.

3. **Priority queue infrastructure in place** (Phase 3). `FLASHIda` already has `std::deque<ScanCommand> queues_[4]`, `queue_mutex_`, `pending_scan_map_`, and `cleanupExpiredCommands_()`. Priority 0 is already reserved for exploration (defined in Phase 3 / Phase 4 comments) but was never populated.

4. **`processScan()` MS2 routing in place** (Phase 4). The MS2 path already resolves a tracking ID from `pending_scan_map_` and routes by mode (tag targeting, quant, conditional follow-up, MS3 targeting). The exploration branch stub `if (ctx.exploration_group_id > 0) feedExplorationResult_(ctx, ms2_deconv)` was noted in the Issue 5 pseudocode but not implemented. This phase implements `feedExplorationResult_()` and all supporting state.

5. **JSON config exploration fields parsed** (Phase 1). The `exploration` object in the JSON schema (`enabled`, `max_depth`, `max_variants`) is already parsed by `FLASHIda`'s JSON constructor and stored. The full `<ParameterOptimization>` XML block is serialized to JSON by `Parameter.ToJSON()`. Phase 7 must read the additional exploration fields that Phase 1 stored but did not act upon (`max_variants_per_precursor`, `max_queue_for_exploration`, `max_exploration_depth`, `ms2_exploration`, `ms3_exploration`, `scoring.metric_type`).

6. **ms3 array parsing deferred from Phase 1.** Phase 1's JSON config parsing implemented `ms["ms2"]` array parsing into `ms2_configs_` but did not implement the corresponding `ms["ms3"]` array parsing. The Phase 1 pseudocode comment (`// ms2 and ms3 arrays are parsed into vectors for later use`) flagged this as pending. Phase 7 must implement ms3 array parsing in `FLASHIda.cpp`'s JSON constructor (`ms3_configs_` vector, mirroring the ms2 pattern) so that `buildMS3Command_()` can use ms3 activation and CE settings from the config.

7. **`method_exploration.xml` does not yet exist.** It must be created and committed as part of this phase alongside its golden file. The file's canonical location (`FlashIDA/test-data/configs/`), XML schema sections, and key parameter values are specified in [../test-file-specification.md](../test-file-specification.md) §3.1 and §3.2. The golden file is named `phase7_exploration.tsv` (see [../test-file-specification.md](../test-file-specification.md) §2.2).

### User-Provided Inputs

No new user-provided spectrum data is required for Phase 7 (reuses `ms1_standard.txt` from Phase 4). The new config file `method_exploration.xml` is created during implementation. The golden file `phase7_exploration.tsv` is captured via CI artifact.

---

## Phase 0–1 Lessons Learned — Cross-References

The following lessons from [../Phase_0/lessons-learned.md](../Phase_0/lessons-learned.md) and [../Phase_1/lessons-learned.md](../Phase_1/lessons-learned.md) apply to Phase 7. Read these before implementation.

1. **Flash.exe entry point (lesson #1):** The entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()`. There is no `-t` flag. Correct invocation: `Flash.exe <input_file> <output_file> <method.xml> [ms2_file]`.

2. **Build output path (lesson #12):** The actual build output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/`. All CI paths, test paths, and regression runner references must use `FlashIDA/bin/`.

3. **DLL name in P/Invoke (lesson #12):** The actual DLL import uses `"OpenMS.dll"` (with extension), not `"OpenMS"`. Any P/Invoke `[DllImport]` references must use the full filename.

4. **NUnit runner invocation (lesson #12):** CI invokes the NUnit console runner by full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.16.3/tools/nunit3-console.exe`), not by assuming it is on PATH. Working directory must be `FlashIDA/bin/` so that native DLLs (`OpenMS.dll` and dependencies) are found by the .NET runtime's DLL search path.

5. **Spectrum file format (lesson #2):** Spectrum files use tab-separated headers with RT in seconds (`Spec scan=N\t<seconds>`), not the space-separated format with RT in minutes described in test-file-specification.md. The parser divides by 60 internally.

6. **Thermo DLL strategy (lesson #3):** Thermo DLLs use Strategy B — openssl-encrypted zip committed to the repo (`FlashIDA/dependencies/thermo-dlls.zip.enc`), with the passphrase stored as `THERMO_DLL_PASSPHRASE` secret. Do not use base64 (exceeds GitHub secret limit) or GPG (Windows CI incompatibility).

7. **OpenMS DLLs (lesson #5):** OpenMS DLLs are already committed in `FlashIDA/dll/`. Do not add cache/download steps for OpenMS DLLs. MSBuild copies them to the build output via `CopyToOutputDirectory` in `Flash.csproj`.

8. **Golden file capture (lesson #15):** Golden-file capture requires a 2-commit minimum. The first commit runs CI and produces the golden artifact; the second commit includes the captured golden file. Phases with multiple golden files should batch captures into a single CI run.

9. **Test tier labels (lesson #12):** C# tests that load `OpenMS.dll` via P/Invoke (AL-CT / bridge tests) are Tier 2, not Tier 1, matching the convention that DLL-dependent tests are Tier 2.

10. **Silent P/Invoke failures (lesson #14):** The C++ deconvolution engine returns 0 results without an error code when input data is malformed. When deconvolution returns 0 results unexpectedly, log the input data characteristics (RT, peak count, first/last m/z, precursor mass/charge for MS2) before investigating engine internals. The bridge functions do not distinguish "no results found" from "input data is malformed."

11. **Submodule batching (lesson #15):** Batch same-side changes (all C# changes or all C++ changes) before updating the submodule pointer to reduce churn. In Phase 0, 48% of commits were submodule pointer updates.

12. **Multi-scan parser (lesson #9):** Any new code that loads spectrum TSV files must stop at the first scan boundary (`if (started) break;` on encountering a second `Spec` line). Flash.exe's `Main()` parser handles multi-scan correctly (processes scan N when scan N+1's header is encountered), but test parsers must stop at the first scan for single-scan loading.

13. **`.gitattributes` (lesson #4):** `FlashIDA/.gitattributes` has `* text eol=crlf`, which forces CRLF conversion on ALL files. Any new binary file extensions (`.enc`, `.gpg`, `.zip`, etc.) must be added to `.gitattributes` as `binary` before committing to prevent silent corruption.

The following lessons from [../Phase_1/lessons-learned.md](../Phase_1/lessons-learned.md) also apply:

14. **Submodule pointer update required for CI to see new files (Phase 1 lesson #1):** CI checks out submodules at the pointer commit, not at the branch HEAD. After pushing to either the `FlashIDA` or `OpenMS` sub-repo, always `git add FlashIDA OpenMS` in the parent repo and push the pointer update before expecting CI to pick up the changes. Without this step, new files (test classes, `.cs` source, C++ headers) are silently invisible to the CI build.

15. **Test data path: one level up from `bin/` (Phase 1 lesson #2):** `TestContext.CurrentContext.TestDirectory` resolves to `FlashIDA/bin/`. The correct relative path to test data is `Path.Combine(TestDirectory, "..", "test-data")` — one level up, not two. All existing test classes use this pattern; new test classes must follow it.

16. **NUnit runner flags: `--agents=1 --timeout=300000` (Phase 1 lesson #8):** `SpectralDeconvolution::calculateAveragine` takes ~3.5 minutes on the first call in a CI process (cold cache). Set `--agents=1` to prevent parallel cold-cache computations and `--timeout=300000` (5 minutes) to prevent the first-call timeout. Keep these flags in all NUnit invocations.

17. **`OPENMS_DATA_PATH` required in CI (Phase 1 lesson #5):** Any CI step that invokes OpenMS functionality via P/Invoke must set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`. Without it the DLL crashes with `Cannot find shared data! OpenMS cannot function without it!`. This applies to NUnit test steps and `Flash.exe` regression runs.

18. **DLL build takes ~40 minutes; batch all C++ changes (Phase 1 lesson #10):** Each push to the OpenMS submodule branch triggers a full MSVC build (~40 min). Batch all C++ changes for Phase 7 into a single push to minimize rebuild cycles. Verify code compiles locally for obvious MSVC issues before pushing.

19. **MSVC `/WX` treats warnings as errors (Phase 1 lesson #3):** MSVC's `/WX` flag is active. Unused parameters (`C4100`) and initialized-but-unreferenced variables (`C4189`) are build errors on Windows even if they compile cleanly under GCC/Clang. Fix these before pushing.

20. **`ModificationsDB::getInstance()` has initialization side effects — never remove (Phase 1 lesson #4):** Calls to `ModificationsDB::getInstance()` (and other OpenMS singleton initializers: `ResidueDB::getInstance()`, `ElementDB::getInstance()`) must not be removed or commented out, even if their return values are unused. These calls initialize the OpenMS shared data path resolver as a side effect; removing them causes a fatal crash at runtime. Use `(void)` cast to suppress unused-variable warnings while preserving the call.

21. **Constructor preference: `FLASHIdaWrapper(MethodParameters)` (Phase 1 lesson #11):** Both `FLASHIdaWrapper(IDAParameters)` and `FLASHIdaWrapper(MethodParameters)` constructors exist. The `MethodParameters` overload uses `ToJSON()` (full JSON config including exploration fields). Prefer this constructor in Phase 7 test code. The `IDAParameters` overload remains for backward compatibility with bridge tests and legacy paths.

22. **ms3 array parsing deferred from Phase 1 (Phase 1 lesson, deferred work):** Phase 1's JSON config parsing parsed the `ms["ms2"]` array into `ms2_configs_` but did not implement the corresponding ms3 array parsing. The comment in the pseudocode (`// ms2 and ms3 arrays are parsed into vectors for later use`) acknowledged ms3 parsing as pending. Phase 7 is the appropriate phase to implement ms3 array parsing in the JSON config path, since `buildMS3Command_()` (Step 8) needs ms3 activation and CE settings from the config.

---

## Detailed Implementation Steps

### Step 1: Extend JSON config parsing for full exploration config

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`
**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Phase 1 stored only the top-level `exploration.enabled`, `exploration.max_depth`, and `exploration.max_variants` fields. The full `<ParameterOptimization>` XML block (see Issue 4 in [../baseline-plan.md](../baseline-plan.md)) is richer. Add the following private member variables to `FLASHIda.h` under a clearly marked `// --- Exploration config ---` comment block:

```cpp
// --- Exploration config ---
bool exploration_enabled_ = false;
int exploration_max_depth_ = 1;
int exploration_max_variants_per_precursor_ = 5;
int exploration_max_queue_for_exploration_ = 50;

// MS2 CE exploration
bool ms2_exploration_enabled_ = false;
bool ms2_ce_optimization_enabled_ = false;
int ms2_ce_min_ = 20;
int ms2_ce_max_ = 40;
int ms2_ce_step_ = 5;
std::string ms2_ce_activation_ = "HCD";

// MS3 CE exploration
bool ms3_exploration_enabled_ = false;
bool ms3_trigger_after_ms2_winner_ = true;
int ms3_max_fragments_to_explore_ = 3;
bool ms3_ce_optimization_enabled_ = false;
int ms3_ce_min_ = 15;
int ms3_ce_max_ = 35;
int ms3_ce_step_ = 5;
std::string ms3_ce_activation_ = "CID";
```

In the JSON parsing branch in `FLASHIda.cpp`, extend the `exploration` object parsing to read all of these fields. Use safe `.value()` calls with defaults so that configs missing sub-objects (e.g., no `MS3Exploration` key) do not throw. Example pattern:

```cpp
if (j.contains("exploration")) {
    auto& ex = j["exploration"];
    exploration_enabled_ = ex.value("enabled", false);
    exploration_max_depth_ = ex.value("max_depth", 1);
    exploration_max_variants_per_precursor_ = ex.value("max_variants", 5);
    exploration_max_queue_for_exploration_ = ex.value("max_queue_for_exploration", 50);
    if (ex.contains("ms2")) {
        auto& m2 = ex["ms2"];
        ms2_exploration_enabled_ = m2.value("enabled", false);
        if (m2.contains("ce")) {
            auto& ce = m2["ce"];
            ms2_ce_optimization_enabled_ = ce.value("enabled", true);
            ms2_ce_min_ = ce.value("min", 20);
            ms2_ce_max_ = ce.value("max", 40);
            ms2_ce_step_ = ce.value("step", 5);
            ms2_ce_activation_ = ce.value("activation", std::string("HCD"));
        }
    }
    if (ex.contains("ms3")) {
        auto& m3 = ex["ms3"];
        ms3_exploration_enabled_ = m3.value("enabled", false);
        ms3_trigger_after_ms2_winner_ = m3.value("trigger_after_ms2_winner", true);
        ms3_max_fragments_to_explore_ = m3.value("max_fragments_to_explore", 3);
        if (m3.contains("ce")) {
            auto& ce = m3["ce"];
            ms3_ce_optimization_enabled_ = ce.value("enabled", true);
            ms3_ce_min_ = ce.value("min", 15);
            ms3_ce_max_ = ce.value("max", 35);
            ms3_ce_step_ = ce.value("step", 5);
            ms3_ce_activation_ = ce.value("activation", std::string("CID"));
        }
    }
}
```

Also update `Parameter.ToJSON()` in `FlashIDA/src/Flash/IDA/Parameter.cs` to serialize all sub-fields of `<ParameterOptimization>` into the `exploration` JSON object with the key names used above. This ensures the full round-trip: `method_exploration.xml` -> `ToJSON()` -> C++ parse -> all fields correct.

---

### Step 2: Define ExplorationGroup and ExplorationVariant structs

**File:** `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h`

Add these structs inside the `FLASHIda` class as private nested types (or as file-scope structs in the header, immediately before the class declaration). Keep them in the same translation unit — they are not part of the bridge API and do not need to appear in `FLASHIdaBridgeFunctions.h`.

```cpp
struct ExplorationVariant
{
    int variant_index = -1;       // 0-based position in the CE sweep
    int collision_energy = 0;     // the CE value for this variant
    std::string activation_type;  // "HCD", "CID", etc.
    std::string tracking_id;      // 4-char base-36 tracking ID of the submitted scan command
    double fragmentation_quality_score = -1.0; // -1 = not yet received
    float tic_coverage = 0.0f;
    int fragment_count = 0;
    bool received = false;        // true once ProcessScan has matched and scored this variant
};

struct ExplorationGroup
{
    int group_id = 0;             // unique, monotonically increasing
    int msn_level = 2;            // the MSn level being explored (2 for MS2, 3 for MS3)
    int depth = 1;                // 1 = first-level exploration; 2 = recursive MS3 exploration
    std::string parent_tracking_id; // tracking ID of the scan that triggered this group
    double precursor_mz = 0.0;
    double precursor_mass = 0.0;
    int precursor_charge = 0;
    double isolation_width = 0.0;
    double faims_cv = 0.0;
    uint64_t start_ms = 0;        // wall-clock ms when group was created
    std::vector<ExplorationVariant> variants;
    int winner_index = -1;        // index into variants; -1 = winner not yet selected
    bool complete = false;        // true once winner is selected
};
```

Add the following private members to `FLASHIda`:

```cpp
std::unordered_map<int, ExplorationGroup> active_exploration_groups_;
int next_exploration_group_id_ = 1;   // atomic increment; protected by queue_mutex_

// Maps tracking_id -> group_id so ProcessScan can look up the group when a variant returns
std::unordered_map<std::string, int> variant_tracking_to_group_;
```

Both maps are accessed only inside `queue_mutex_`-protected regions (either within `processScan()` or `getNextScanCommand()`), so no additional locking is needed beyond the existing mutex.

---

### Step 3: Implement the CE variant generation helper

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Add a private helper `buildCEVariants_()` that generates the list of collision energy values for a CE sweep:

```cpp
std::vector<int> FLASHIda::buildCEVariants_(int ce_min, int ce_max, int ce_step) const
{
    std::vector<int> ces;
    for (int ce = ce_min; ce <= ce_max; ce += ce_step)
        ces.push_back(ce);
    // Guard: never exceed max_variants_per_precursor_
    if ((int)ces.size() > exploration_max_variants_per_precursor_)
        ces.resize(exploration_max_variants_per_precursor_);
    return ces;
}
```

For CE 20-40 step 5 this produces {20, 25, 30, 35, 40} — exactly 5 variants.

---

### Step 4: Implement exploration initiation from high-scoring precursors

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

This logic belongs in `processScan()` inside the MS1 branch, immediately after the existing `SELECT TOP N -> PUSH MS2 COMMANDS` loop. The exploration path is taken only when `exploration_enabled_` is true, `ms2_exploration_enabled_` is true, and the total queue size across all four priority levels does not exceed `exploration_max_queue_for_exploration_`.

Pseudocode (to be implemented as a private helper `initiateMS2Exploration_()`):

```cpp
void FLASHIda::initiateMS2Exploration_(
    const PeakGroup& peak_group, int charge, double rt)
{
    // (1) Guard: queue overflow protection
    int total_queued = 0;
    for (int p = 0; p <= 3; p++) total_queued += (int)queues_[p].size();
    if (total_queued >= exploration_max_queue_for_exploration_) return;

    // (2) Build CE variants
    std::vector<int> ces = buildCEVariants_(
        ms2_ce_min_, ms2_ce_max_, ms2_ce_step_);
    if (ces.empty()) return;

    // (3) Create ExplorationGroup
    ExplorationGroup group;
    group.group_id = next_exploration_group_id_++;
    group.msn_level = 2;
    group.depth = 1;
    group.precursor_mz = peak_group.getRepresentativeMz();
    group.precursor_mass = peak_group.getMonoisotopicMass();
    group.precursor_charge = charge;
    group.isolation_width = getIsolationWidth_(charge);
    group.faims_cv = current_faims_cv_();  // 0 if no FAIMS
    group.start_ms = currentTimeMs_();

    // (4) For each CE value: build ScanCommand at priority 0, assign tracking ID
    for (int i = 0; i < (int)ces.size(); i++) {
        ExplorationVariant v;
        v.variant_index = i;
        v.collision_energy = ces[i];
        v.activation_type = ms2_ce_activation_;

        ScanCommand cmd = buildMS2Command_(peak_group, charge, ces[i],
                                          ms2_ce_activation_);
        cmd.priority = 0;
        // Embed group_id and variant_index in scan_description so ProcessScan
        // can route the returning scan back to the correct group.
        // Format: "EXPL:<group_id>:<variant_index>:<base36_tracking_id>"
        std::string track_id = generateTrackingId_();
        v.tracking_id = track_id;
        snprintf(cmd.scan_description, sizeof(cmd.scan_description),
                 "EXPL:%d:%d:%s", group.group_id, i, track_id.c_str());

        group.variants.push_back(v);
        variant_tracking_to_group_[track_id] = group.group_id;
        queues_[0].push_back(cmd);
        logTrackCreate_(cmd);
    }

    active_exploration_groups_[group.group_id] = std::move(group);
}
```

The call to `initiateMS2Exploration_()` is added at the end of the top-N loop in the MS1 branch, after `pushCommand_()` for the standard MS2 has already been called:

```cpp
if (exploration_enabled_ && ms2_exploration_enabled_)
    initiateMS2Exploration_(selected_peak_group, charge, rt);
```

Note that standard MS2 commands for the precursor still go into the queue at priority 1 (normal processing). Exploration variants go in at priority 0. They will be dequeued after all higher-priority scans are exhausted, meaning the instrument will handle urgent MS3 follow-ups, conditional scans, and standard MS2 scans before exploration sweeps.

---

### Step 5: Implement variant tracking in ProcessScan MS2 routing

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

The `processScan()` MS2 path currently resolves tracking IDs from `pending_scan_map_`. Exploration variants use a different scan description format (`EXPL:<group_id>:<variant_index>:<tracking_id>`). Add a detection step at the top of the MS2 routing block:

```cpp
// In processScan(), MS2 path, after deconvolution:
bool is_exploration_variant = false;
int expl_group_id = -1;
int expl_variant_index = -1;

if (strncmp(scan_description, "EXPL:", 5) == 0)
{
    // Parse "EXPL:<group_id>:<variant_index>:<tracking_id>"
    if (sscanf(scan_description + 5, "%d:%d:", &expl_group_id, &expl_variant_index) == 2)
        is_exploration_variant = true;
}

if (is_exploration_variant)
{
    feedExplorationResult_(expl_group_id, expl_variant_index, ms2_deconv, rt);
    return commands_pushed_;
}
// ... existing routing for non-exploration MS2
```

---

### Step 6: Implement winner selection and OptimizationMetadata population

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

`feedExplorationResult_()` is the core scoring function. It:
1. Scores the returning variant using `FragmentationQuality`.
2. Marks the variant as received.
3. Checks whether all variants for the group have been received.
4. If complete: selects the winner, populates `OptimizationMetadata` on the winning `DeconvolvedSpectrum`, and triggers MS3 recursive exploration if configured.
5. Removes the group from `active_exploration_groups_` and cleans up `variant_tracking_to_group_`.

```cpp
void FLASHIda::feedExplorationResult_(
    int group_id, int variant_index,
    const DeconvolvedSpectrum& ms2_deconv, double rt)
{
    auto git = active_exploration_groups_.find(group_id);
    if (git == active_exploration_groups_.end()) return;
    ExplorationGroup& group = git->second;

    if (variant_index < 0 || variant_index >= (int)group.variants.size()) return;
    ExplorationVariant& v = group.variants[variant_index];
    if (v.received) return;  // Duplicate; ignore

    // Score this variant
    v.fragmentation_quality_score = computeFragmentationQuality_(ms2_deconv);
    v.tic_coverage = computeTICCoverage_(ms2_deconv);
    v.fragment_count = (int)ms2_deconv.size();
    v.received = true;

    // Populate OptimizationMetadata on the DeconvolvedSpectrum
    // (ms2_deconv is const here; use a local annotated copy for output)
    // The actual DeconvolvedSpectrum that will be written to mzML is the one
    // held in the deconvolution output buffer; annotate it via the non-const
    // reference in the processing pipeline.
    auto& meta = const_cast<DeconvolvedSpectrum&>(ms2_deconv)
                     .getOrCreateOptimizationMetadata();
    meta.group_id = group.group_id;
    meta.variant_index = variant_index;
    meta.total_variants = (int)group.variants.size();
    meta.is_best_variant = false;   // updated below once winner is known
    meta.msn_level_optimized = group.msn_level;
    meta.parent_tracking_id = std::stoi(group.parent_tracking_id, nullptr, 36);
    meta.collision_energy = v.collision_energy;
    meta.activation_type = v.activation_type;
    meta.precursor_mass = group.precursor_mass;
    meta.precursor_charge = group.precursor_charge;
    meta.fragmentation_quality_score = v.fragmentation_quality_score;
    meta.tic_coverage = v.tic_coverage;
    meta.fragment_count = v.fragment_count;
    meta.start_ms = group.start_ms;
    meta.complete_ms = currentTimeMs_();
    meta.exploration_scans = (int)group.variants.size();

    // Check completion
    bool all_received = std::all_of(group.variants.begin(), group.variants.end(),
                                    [](const ExplorationVariant& x){ return x.received; });
    if (!all_received) return;

    // Select winner: highest fragmentation_quality_score
    int best_idx = 0;
    double best_score = group.variants[0].fragmentation_quality_score;
    for (int i = 1; i < (int)group.variants.size(); i++) {
        if (group.variants[i].fragmentation_quality_score > best_score) {
            best_score = group.variants[i].fragmentation_quality_score;
            best_idx = i;
        }
    }
    group.winner_index = best_idx;
    group.complete = true;

    // Mark winner in the already-annotated spectrum for best_idx
    // (The metadata on each variant's DeconvolvedSpectrum was set when it arrived;
    //  we need to update the is_best_variant flag on the winner's spectrum.
    //  Because spectra have already been emitted downstream at this point, we
    //  record the winner index in the group and expose it via a query function
    //  for any post-processing that needs it. Additionally, log the winner.)
    logInfo_("EXPL-WINNER group=" + std::to_string(group_id)
             + " winner_idx=" + std::to_string(best_idx)
             + " CE=" + std::to_string(group.variants[best_idx].collision_energy)
             + " score=" + std::to_string(best_score));

    // Trigger MS3 recursive exploration if configured and depth allows
    if (ms3_exploration_enabled_
        && ms3_trigger_after_ms2_winner_
        && group.depth < exploration_max_depth_)
    {
        initiateMS3Exploration_(group, ms2_deconv, best_idx);
    }

    // Clean up variant tracking map
    for (auto& v2 : group.variants)
        variant_tracking_to_group_.erase(v2.tracking_id);

    active_exploration_groups_.erase(git);
}
```

**Fragmentation quality scoring.** Add a private helper `computeFragmentationQuality_()` that computes the quality of an MS2 deconvolution result. At minimum this should be the number of deconvolved fragments weighted by their intensities relative to the TIC. The exact implementation should mirror the existing scoring logic used for MS3 target selection in Phase 4 (`selectMS3Targets_` already has a notion of fragment quality). A suitable baseline:

```cpp
double FLASHIda::computeFragmentationQuality_(
    const DeconvolvedSpectrum& spec) const
{
    if (spec.empty()) return 0.0;
    double tic = 0.0;
    double weighted_count = 0.0;
    for (const auto& peak : spec) {
        tic += peak.getIntensity();
        weighted_count += 1.0;
    }
    // Normalize: fragment count * average intensity
    return weighted_count * (tic / std::max(weighted_count, 1.0));
}
```

This can be replaced by a more sophisticated metric in a follow-up without changing the interface.

---

### Step 7: Implement MS1 cycle time suppression during active exploration

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

In `getNextScanCommand()`, step (2) already handles MS1 cycle time injection:

```cpp
// (2) MS1 cycle time
if (cycle_time_enabled_ && msSinceLastMS1_() > cycle_time_ms_)
    { out = makeMS1Command_(); return 1; }
```

Add a suppression guard immediately before this check:

```cpp
// (2) MS1 cycle time — suppressed while any exploration group is active
bool exploration_active = !active_exploration_groups_.empty();
if (cycle_time_enabled_ && !exploration_active
    && msSinceLastMS1_() > cycle_time_ms_)
    { out = makeMS1Command_(); return 1; }
```

This prevents the instrument from inserting an MS1 scan in the middle of a CE sweep. The sweep may take many scan events if `MaxVariantsPerPrecursor` is large; suppressing cycle time ensures continuity. Once all groups complete (the map empties), the cycle time check resumes normally on the next `getNextScanCommand()` call.

---

### Step 8: Implement MS3 recursive exploration

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

`initiateMS3Exploration_()` creates a child `ExplorationGroup` targeting the top-N fragment ions from the winning MS2 spectrum. The function is called inside `feedExplorationResult_()` after winner selection, while still under `queue_mutex_`.

```cpp
void FLASHIda::initiateMS3Exploration_(
    const ExplorationGroup& parent_group,
    const DeconvolvedSpectrum& winner_ms2,
    int winner_variant_idx)
{
    // Depth limit check
    if (parent_group.depth >= exploration_max_depth_) return;

    // Queue overflow check
    int total_queued = 0;
    for (int p = 0; p <= 3; p++) total_queued += (int)queues_[p].size();
    if (total_queued >= exploration_max_queue_for_exploration_) return;

    // Select top fragments by intensity
    std::vector<std::pair<double, double>> fragments; // (mz, intensity)
    for (const auto& peak : winner_ms2)
        fragments.push_back({peak.getMZ(), peak.getIntensity()});
    std::sort(fragments.begin(), fragments.end(),
              [](auto& a, auto& b){ return a.second > b.second; });

    int num_frags = std::min((int)fragments.size(), ms3_max_fragments_to_explore_);

    std::vector<int> ms3_ces = buildCEVariants_(
        ms3_ce_min_, ms3_ce_max_, ms3_ce_step_);

    for (int fi = 0; fi < num_frags; fi++) {
        double frag_mz = fragments[fi].first;

        ExplorationGroup child;
        child.group_id = next_exploration_group_id_++;
        child.msn_level = 3;
        child.depth = parent_group.depth + 1;
        child.parent_tracking_id = std::to_string(parent_group.group_id);
        child.precursor_mz = frag_mz;
        child.precursor_mass = 0.0;   // MS3 precursor mass: unknown until deconv
        child.precursor_charge = 0;
        child.faims_cv = parent_group.faims_cv;
        child.start_ms = currentTimeMs_();

        for (int i = 0; i < (int)ms3_ces.size(); i++) {
            ExplorationVariant v;
            v.variant_index = i;
            v.collision_energy = ms3_ces[i];
            v.activation_type = ms3_ce_activation_;

            ScanCommand cmd = buildMS3Command_(parent_group, frag_mz, ms3_ces[i],
                                              ms3_ce_activation_);
            cmd.priority = 0;
            std::string track_id = generateTrackingId_();
            v.tracking_id = track_id;
            snprintf(cmd.scan_description, sizeof(cmd.scan_description),
                     "EXPL:%d:%d:%s", child.group_id, i, track_id.c_str());

            child.variants.push_back(v);
            variant_tracking_to_group_[track_id] = child.group_id;
            queues_[0].push_back(cmd);
            logTrackCreate_(cmd);
        }

        active_exploration_groups_[child.group_id] = std::move(child);
    }
}
```

The depth limit check `parent_group.depth >= exploration_max_depth_` ensures that with `MaxExplorationDepth=2`, MS2 exploration has depth=1 and is allowed to trigger MS3 exploration at depth=2, but an MS3 group (depth=2) cannot trigger further exploration.

With `MaxExplorationDepth=1`, MS3 exploration is never triggered regardless of the `MS3Exploration.Enabled` flag. The depth limit is the hard cap.

---

### Step 9: Update processScan MS2 routing for exploration variants

**File:** `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp`

Extend the MS3 path to handle the case where an exploration-generated MS3 scan returns. MS3 exploration variants also use the `EXPL:` prefix in `scan_description`, so the detection added in Step 5 already handles them. The `feedExplorationResult_()` function is generic across MSn levels — it uses `group.msn_level` to determine context.

The existing MS3 path in `processScan()` (`if (ms3_enabled_) for (auto& target : selectMS3Targets_(ms2_deconv)) pushCommand_(buildMS3Command_(...))`) is not affected. It operates on non-exploration MS2 results where `is_exploration_variant` is false. These are orthogonal code paths.

---

### Step 10: Create method_exploration.xml and update Parameter.ToJSON()

**File:** `FlashIDA/test-data/configs/method_exploration.xml`

All method config files follow the XML schema described in [../test-file-specification.md](../test-file-specification.md) §3.1. `method_exploration.xml` is listed in the config inventory in [../test-file-specification.md](../test-file-specification.md) §3.2, where its key parameters are summarized. The full XML content is specified here.

Create this config as a variant of `method_default.xml` with `<ParameterOptimization>` enabled:

```xml
<ParameterOptimization>
  <Active>True</Active>
  <OptimizationStrategy>Exhaustive</OptimizationStrategy>
  <ScanLimits>
    <MaxVariantsPerPrecursor>5</MaxVariantsPerPrecursor>
    <MaxQueueForExploration>50</MaxQueueForExploration>
    <MaxExplorationDepth>1</MaxExplorationDepth>
  </ScanLimits>
  <MS2Exploration>
    <Enabled>true</Enabled>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>20</Min>
      <Max>40</Max>
      <Step>5</Step>
      <Activation>HCD</Activation>
    </CollisionEnergyOptimization>
  </MS2Exploration>
  <MS3Exploration>
    <Enabled>false</Enabled>
    <TriggerAfterMS2Winner>true</TriggerAfterMS2Winner>
    <MaxFragmentsToExplore>3</MaxFragmentsToExplore>
    <CollisionEnergyOptimization>
      <Enabled>true</Enabled>
      <Min>15</Min>
      <Max>35</Max>
      <Step>5</Step>
      <Activation>CID</Activation>
    </CollisionEnergyOptimization>
  </MS3Exploration>
  <Scoring>
    <MetricType>FragmentationQuality</MetricType>
  </Scoring>
</ParameterOptimization>
```

**File:** `FlashIDA/src/Flash/IDA/Parameter.cs`

Ensure `ToJSON()` serializes the full `<ParameterOptimization>` block into the `exploration` JSON object. The JSON key names must exactly match what the C++ parser expects (established in Step 1). The C# serialization should produce:

```json
"exploration": {
  "enabled": true,
  "max_depth": 1,
  "max_variants": 5,
  "max_queue_for_exploration": 50,
  "ms2": {
    "enabled": true,
    "ce": {
      "enabled": true,
      "min": 20,
      "max": 40,
      "step": 5,
      "activation": "HCD"
    }
  },
  "ms3": {
    "enabled": false,
    "trigger_after_ms2_winner": true,
    "max_fragments_to_explore": 3,
    "ce": {
      "enabled": true,
      "min": 15,
      "max": 35,
      "step": 5,
      "activation": "CID"
    }
  }
}
```

---

### Step 11: Capture the Phase 7 golden file

The golden file for exploration-enabled output is named **`phase7_exploration.tsv`** (canonical name per [../test-file-specification.md](../test-file-specification.md) Section 2.2). It lives in `FlashIDA/test-data/golden/` alongside all other golden files. Its format is the standard 15-column TSV defined in [../test-file-specification.md](../test-file-specification.md) Section 2.1, extended with `OptimizationMetadata` metavalue columns for exploration variant rows (see WPV-6 for the additional column names). Note: spectrum input files use tab-separated headers with RT in seconds (Phase 0 lesson #2); the golden file is also tab-separated.

Because there is no Windows machine available for local development, `phase7_exploration.tsv` is captured via a CI-artifact workflow rather than a local `Flash.exe` invocation. Golden-file capture requires a 2-commit minimum (Phase 0 lesson #15): the first commit runs CI and produces the golden artifact; the second commit includes the captured golden file.

1. Batch same-side changes before updating the submodule pointer (Phase 0 lesson #15). Commit the Phase 7 code changes (C++, C#, `method_exploration.xml`) **without** `test-data/golden/phase7_exploration.tsv`.
2. Push the branch. The `windows-tests` CI job runs `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` and uploads the produced TSV as a build artifact named `exploration-golden-candidate`.
3. Download the artifact from the GitHub Actions run page, inspect it: confirm that extra rows corresponding to exploration variant scans are present and that `OptimizationMetadata` fields appear as additional TSV columns (or mzML metavalues, depending on how test mode serializes them). Follow the general golden file inspection checklist in [../test-file-specification.md](../test-file-specification.md) Section 2.3 (steps 3–5).
4. Once the output looks correct, commit the file as `FlashIDA/test-data/golden/phase7_exploration.tsv` and update `FlashIDA/test-data/golden/README.md` to document its provenance.

The `windows-tests` job must be updated to upload the candidate artifact when the golden file is absent (or always, keyed by run ID). Add a step in `.github/workflows/flashida-ci.yml` such as:

```yaml
- name: Upload exploration golden candidate
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: exploration-golden-candidate
    path: FlashIDA/test-data/golden/phase7_exploration.tsv
```

The regression golden file for `P7-R01` (exploration disabled) is the existing `phase4_standard_dda.tsv` — no new capture needed. (Note: this file is named `phase4_standard_dda.tsv` in the spec, not `standard_dda.tsv`. It uses `ms1_standard.txt` as input, not `ms1_smoke_test.txt`. See [../test-file-specification.md](../test-file-specification.md) Section 2.2 for the distinction between `baseline_phase0.tsv` and `phase4_standard_dda.tsv`.)

---

## Files to Create or Modify

### OpenMS (C++) — Build #4

| File | Action | Description |
|------|--------|-------------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Modify | Add `ExplorationGroup`, `ExplorationVariant` nested structs; add all exploration config member variables; add `active_exploration_groups_`, `variant_tracking_to_group_`, `next_exploration_group_id_`; declare new private methods |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Modify | Implement `buildCEVariants_()`, `initiateMS2Exploration_()`, `feedExplorationResult_()`, `initiateMS3Exploration_()`, `computeFragmentationQuality_()`, `computeTICCoverage_()`; extend JSON config parsing; modify `processScan()` MS2 path; modify `getNextScanCommand()` MS1 suppression |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | Create | C++ unit tests P7-U01 through P7-U10 (see Test Cases section) |
| `OpenMS/src/tests/class_tests/openms/executables.cmake` | Modify | Uncomment or add entry for `FLASHIda_exploration_test` so CTest discovers it |

### FlashIDA (C#) — no new C++ bridge API changes

**Note:** Although Phase 7 adds no new bridge functions, the existing P/Invoke bridge has a silent zero-result failure mode (Phase 0 lesson #14). The C++ engine returns 0 results without an error code when input data is malformed. If exploration variants return 0 deconvolved fragments unexpectedly, log the input data characteristics (RT, peak count, first/last m/z) before investigating engine internals. P/Invoke DLL imports use `"OpenMS.dll"` (with `.dll` extension, lesson #12). NUnit tests must run from `FlashIDA/bin/` working directory so native DLLs are found (lesson #12).

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/src/Flash/IDA/Parameter.cs` | Modify | Extend `ToJSON()` to serialize full `<ParameterOptimization>` XML subtree into the `exploration` JSON object with all sub-keys matching the C++ parser |

### Test data and configuration

| File | Action | Description |
|------|--------|-------------|
| `FlashIDA/test-data/configs/method_exploration.xml` | Create | Method config with `<ParameterOptimization><Active>True</Active>` and CE 20-40 step 5 |
| `FlashIDA/test-data/golden/phase7_exploration.tsv` | Create | Golden file captured from `Flash.exe` with `method_exploration.xml` after Build #4 (canonical name per [test-file-specification.md](../test-file-specification.md) §2.2) |

### CI workflow

| File | Action | Description |
|------|--------|-------------|
| `.github/workflows/flashida-ci.yml` | Modify | Add `method_exploration.xml` and `phase7_exploration.tsv` to the regression runner's config list (entry name `p7_exploration`); add `FLASHIda_exploration_test` to the CTest filter pattern |

---

## Test Cases

All 12 tests for Phase 7 are listed below with full descriptions, expected outcomes, and the CI job that runs them. Tests P7-U01 through P7-U10 are C++ unit tests (Tier 1); P7-R01 and P7-R02 are regression tests (Tier 3). Note: any C# tests that load `OpenMS.dll` via P/Invoke (AL-CT / bridge tests) are Tier 2, not Tier 1, per Phase 0 lesson #9 — the tier convention is that DLL-dependent tests are Tier 2.

### Test Summary (Quick Reference)

| Test ID | What it verifies and why |
|---------|--------------------------|
| P7-U01 | `initiateMS2Exploration_()` creates an `ExplorationGroup` with exactly the expected CE variants (20, 25, 30, 35, 40) and correct initial state (`complete=false`, `winner_index=-1`). Validates the core group-construction path before any results arrive. |
| P7-U02 | All five exploration variant commands are enqueued at priority 0, leaving higher-priority queues untouched. Confirms the priority-0 reservation is honoured so exploration scans never preempt urgent follow-up scans. |
| P7-U03 | `feedExplorationResult_()` selects the variant with the highest `FragmentationQuality` score as the winner. Exercises the end-to-end scoring and winner-selection logic with deterministic synthetic scores. |
| P7-U04 | Queue overflow guard: when total queued commands already reach `MaxQueueForExploration`, `initiateMS2Exploration_()` aborts without adding any commands or groups. Prevents runaway queue growth during dense precursor bursts. |
| P7-U05 | MS1 cycle-time injection is suppressed while at least one exploration group is active. Ensures the instrument does not insert an MS1 scan in the middle of a CE sweep, which would break variant continuity. |
| P7-U06 | MS1 cycle-time injection resumes once all exploration groups have completed. Ensures normal MS1 survey pacing is restored after each sweep finishes. |
| P7-U07 | After an MS2 winner is selected, `initiateMS3Exploration_()` creates one child `ExplorationGroup` per top-N fragment ion (up to `MaxFragmentsToExplore`). Verifies the MS3 recursive branch is triggered correctly and child groups carry the right depth and parent reference. |
| P7-U08 | When an exploration group's `depth` already equals `MaxExplorationDepth`, `initiateMS3Exploration_()` returns immediately without creating further child groups. Enforces the hard recursion cap. |
| P7-U09 | `OptimizationMetadata` is populated on a variant's `DeconvolvedSpectrum` as soon as `feedExplorationResult_()` processes it — even before the group is complete. Validates all expected metadata fields (group_id, variant_index, collision_energy, activation_type, scores, timestamps). |
| P7-U10 | `toSpectrum()` serializes `OptimizationMetadata` fields as named metavalues on the resulting `MSSpectrum`. Ensures downstream consumers (mzML writer, test comparator) can read optimization results from the standard spectrum object. |
| P7-R01 | With exploration disabled (`method_default.xml`), output is byte-for-byte identical to the Phase 4 standard DDA golden file. Guards against any regression introduced by the new exploration code paths when they are inactive. |
| P7-R02 | With exploration enabled (`method_exploration.xml`, CE 20-40 step 5), output matches the committed `phase7_exploration.tsv` golden file, including exploration variant rows, `EXPL-WINNER` log entries, and `OptimizationMetadata` metavalue columns. End-to-end validation of the full exploration pipeline. |

### P7-U01 — ExplorationGroup creation with CE variants

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Configure CE min=20, max=40, step=5. Call `initiateMS2Exploration_()` for a synthetic high-scoring precursor. Inspect the resulting `ExplorationGroup` stored in `active_exploration_groups_`.
**Expected outcome:** Exactly 5 `ExplorationVariant` entries with `collision_energy` values {20, 25, 30, 35, 40}. `group_id` is non-zero. `complete == false`. `winner_index == -1`. `variants[i].received == false` for all i.

### P7-U02 — Exploration variants pushed at priority 0

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** After calling `initiateMS2Exploration_()`, inspect `queues_[0]`.
**Expected outcome:** `queues_[0].size() == 5`. All five commands have `priority == 0`. `queues_[1]`, `queues_[2]`, `queues_[3]` are unaffected by the exploration initiation.

### P7-U03 — Winner selection by FragmentationQuality score

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Create an `ExplorationGroup` with 5 variants (CE 20-40). Call `feedExplorationResult_()` for each variant with synthetic `DeconvolvedSpectrum` objects whose `computeFragmentationQuality_()` returns known scores: {1.0, 3.5, 2.2, 4.8, 0.5}. Check the group after all 5 have been received.
**Expected outcome:** `group.complete == true`. `group.winner_index == 3` (score 4.8, CE=35). `logInfo_` output contains `EXPL-WINNER` with `winner_idx=3` and `CE=35`.

### P7-U04 — Queue overflow protection

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Set `exploration_max_queue_for_exploration_ = 50`. Directly push 51 commands into `queues_[1]` to saturate the queue. Attempt to call `initiateMS2Exploration_()` for a high-scoring precursor.
**Expected outcome:** `initiateMS2Exploration_()` returns without adding any entries to `queues_[0]`. `active_exploration_groups_` remains empty. No assertion failure or exception.

### P7-U05 — MS1 cycle time suppression during exploration

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Enable cycle time (`cycle_time_enabled_ = true`, `cycle_time_ms_ = 1000`). Create an active exploration group (do not call `feedExplorationResult_()` so the group remains incomplete). Advance the mock clock by 2000 ms (past the cycle time deadline). Call `getNextScanCommand()`.
**Expected outcome:** The returned command has `msn_level != 1` unless the queue is also empty. Specifically, the MS1 injection from the cycle time check is bypassed because `!active_exploration_groups_.empty()`. The command returned is one of the exploration variants from `queues_[0]`, not an injected MS1.

### P7-U06 — MS1 resumes after exploration completes

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Continuing from P7-U05 state (or fresh setup): complete all variants in the exploration group by calling `feedExplorationResult_()` for each. After the last call, `active_exploration_groups_` should be empty. Advance the clock past cycle time. Call `getNextScanCommand()`.
**Expected outcome:** The returned command has `msn_level == 1` and `is_agc == 0` — the MS1 cycle time injection resumes because there are no active exploration groups.

### P7-U07 — MS3 recursive exploration creates child group

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Enable MS3 exploration (`ms3_exploration_enabled_ = true`, `ms3_trigger_after_ms2_winner_ = true`, `ms3_max_fragments_to_explore_ = 3`, `exploration_max_depth_ = 2`). Create an MS2 exploration group with 3 variants. Feed all 3 variants with known scores so one is selected as winner. The winning `DeconvolvedSpectrum` contains 5 fragment ions. Verify what happens in `feedExplorationResult_()`.
**Expected outcome:** After the MS2 group completes, `active_exploration_groups_` contains 3 new child groups (one per fragment, up to `ms3_max_fragments_to_explore_`). Each child group has `depth == 2`, `msn_level == 3`, and `parent_tracking_id` matching the MS2 group's `group_id`. Total new commands in `queues_[0]`: 3 fragments * (number of MS3 CE variants) entries.

### P7-U08 — Recursive depth limit blocks further exploration

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Set `exploration_max_depth_ = 2`. Manually create an `ExplorationGroup` with `depth = 2` (simulating an MS3 exploration group at maximum depth). Call `initiateMS3Exploration_()` (or trigger `feedExplorationResult_()` for this group's last variant, which would call `initiateMS3Exploration_()` internally).
**Expected outcome:** `initiateMS3Exploration_()` returns immediately because `parent_group.depth >= exploration_max_depth_`. No new child groups are created in `active_exploration_groups_`. `queues_[0]` is not extended.

### P7-U09 — OptimizationMetadata populated on exploration variant spectra

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Create an exploration group with 2 variants (CE 20, CE 25). Call `feedExplorationResult_()` for variant 0 with a synthetic `DeconvolvedSpectrum`. Inspect the metadata on the spectrum after the call.
**Expected outcome:** `ms2_deconv.hasOptimizationMetadata() == true`. `meta.group_id == <expected group id>`. `meta.variant_index == 0`. `meta.total_variants == 2`. `meta.collision_energy == 20`. `meta.activation_type == "HCD"`. `meta.is_best_variant == false` (winner not determined yet — only 1 of 2 received). `meta.fragmentation_quality_score > -1.0`. `meta.start_ms > 0`. `meta.exploration_scans == 2`.

### P7-U10 — Metadata serialized to MSSpectrum via setMetaValue

**Tier:** 1 (C++ unit test)
**CI runner:** `ubuntu-latest`, `cpp-unit-tests` job
**Description:** Starting from P7-U09's spectrum (which has `OptimizationMetadata` set), call `toSpectrum()` and inspect the resulting `MSSpectrum`.
**Expected outcome:** `out_spec.getMetaValue("optimization_group_id")` returns the correct integer. `out_spec.getMetaValue("optimization_collision_energy")` returns 20.0. `out_spec.getMetaValue("optimization_is_best_variant")` returns `"false"`. `out_spec.getMetaValue("optimization_quality_score")` returns the computed score. `out_spec.getMetaValue("optimization_precursor_mass")` returns the precursor mass.

### P7-R01 — Exploration disabled regression

**Tier:** 3 (regression)
**CI runner:** `windows-latest`, `windows-tests` job
**Description:** Run `Flash.exe ms1_standard.txt output.tsv method_default.xml` (exploration disabled — no `<ParameterOptimization>` section or `<Active>False</Active>`). Entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1). Spectrum input: `ms1_standard.txt` (see [../test-file-specification.md](../test-file-specification.md) §1.2 for content requirements). Comparison is performed by `compare_golden.py` using the tolerances defined in [../test-file-specification.md](../test-file-specification.md) §2.1.
**Expected outcome:** Output matches the Phase 4 standard DDA golden file (`test-data/golden/phase4_standard_dda.tsv`). Zero deviation in row count, string fields, and floating-point fields within tolerance. No `EXPL:` entries in the console log. `active_exploration_groups_` remains empty throughout.

### P7-R02 — Exploration enabled produces variant scans in output

**Tier:** 3 (regression)
**CI runner:** `windows-latest`, `windows-tests` job
**Description:** Run `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` (CE 20-40 step 5, `MaxVariantsPerPrecursor=5`). Entry point is `FLASHIdaWrapper.Main()` — there is no `-t` flag (Phase 0 lesson #1). Spectrum input: `ms1_standard.txt` (see [../test-file-specification.md](../test-file-specification.md) §1.2). Config file format and key parameters for `method_exploration.xml` are specified in [../test-file-specification.md](../test-file-specification.md) §3.2. Comparison is performed by `compare_golden.py` using the standard tolerances from [../test-file-specification.md](../test-file-specification.md) §2.1.
**Expected outcome:** Output file matches the committed golden file `test-data/golden/phase7_exploration.tsv`. The golden file contains more rows than `phase4_standard_dda.tsv` — specifically, for each selected precursor there are up to 5 exploration variant scan records in addition to the standard MS2 record. `EXPL-WINNER` log entries appear in console output. `OptimizationMetadata` fields appear as metavalues in the output (verifiable from the TSV columns, if the test mode serializes them, or from inspecting mzML output if `Flash.exe` produces mzML). This is a new golden file created fresh at this phase, not a comparison against a prior phase.

---

## CI Configuration

### Changes to `.github/workflows/flashida-ci.yml`

#### 1. CTest filter for exploration tests

In the `cpp-unit-tests` job, the CTest invocation currently filters `ctest -R FLASH`. This already matches any test binary containing "FLASH" in its name. If the new test binary is named `FLASHIda_exploration_test`, it is automatically included. No pattern change is needed, but verify the test binary name matches the filter. If the binary is named `ExplorationEngine_test` or similar (without "FLASH"), either rename it or add it to the filter:

```yaml
- name: Run C++ unit tests (FLASH)
  run: ctest -R "FLASH|Exploration" --output-on-failure
```

#### 2. Regression runner: add exploration config

In the PowerShell regression runner block (`regression-runner.ps1` or inline YAML), add an entry for `method_exploration.xml`. The runner script format and the full config array are documented in [../test-file-specification.md](../test-file-specification.md) §4.2:

```powershell
@{ name="p7_exploration"; method="method_exploration.xml";
   ms1="ms1_standard.txt"; ms2=$null; golden="phase7_exploration.tsv" },
```

The comparison step already loops over all entries and calls `compare_golden.py`; adding the entry here is sufficient.

#### 3. Golden file for P7-R02 must exist before CI runs

`test-data/golden/phase7_exploration.tsv` must be committed before the `P7-R02` regression test can pass in CI. Because no Windows machine is available locally, the file is captured via the CI-artifact workflow described in Step 11:

1. Push the Phase 7 code changes (without the golden file). The `windows-tests` CI job uploads the produced TSV as the `exploration-golden-candidate` artifact.
2. Download the artifact from the GitHub Actions run page and inspect it: confirm variant rows and metadata fields are present and reasonable. Follow the inspection checklist in [../test-file-specification.md](../test-file-specification.md) §2.3.
3. Commit the downloaded file as `test-data/golden/phase7_exploration.tsv` alongside the Phase 7 code changes.

Also note that `method_exploration_overflow.xml` and `method_exploration_ms3.xml` (used in WPV-4 and WPV-7 respectively) must be committed to `test-data/configs/` before the corresponding CI steps can run — they cannot be created ad-hoc on a local machine.

#### 4. No new CI jobs are required

Phase 7 adds only C++ unit tests (existing `cpp-unit-tests` job, `ubuntu-latest`) and one new regression config (existing `windows-tests` job, `windows-latest`). No new runner, no new job, no new secrets. The existing Build #4 artifact cache key (OpenMS submodule hash) automatically handles the DLL rebuild when the C++ source advances.

#### 5. CI infrastructure reminders (Phase 0–1 lessons)

- **Thermo DLLs (Phase 0 lesson #3):** Use Strategy B — decrypt `FlashIDA/dependencies/thermo-dlls.zip.enc` with `openssl enc -d -aes-256-cbc -pbkdf2` using `THERMO_DLL_PASSPHRASE` secret. Do not use base64 or GPG.
- **OpenMS DLLs (Phase 0 lesson #5):** Already committed in `FlashIDA/dll/`. Do not add cache/download steps. MSBuild copies them via `CopyToOutputDirectory`.
- **NUnit runner (Phase 0 lesson #12):** Invoke by full NuGet packages path (e.g., `packages/NUnit.ConsoleRunner.3.16.3/tools/nunit3-console.exe`). Working directory must be `FlashIDA/bin/`.
- **NUnit flags (Phase 1 lesson #8):** Always pass `--agents=1 --timeout=300000` to the NUnit console runner. Required to avoid cold-cache timeouts from `calculateAveragine` (~3.5 min first call).
- **`OPENMS_DATA_PATH` (Phase 1 lesson #5):** All CI steps that invoke OpenMS via P/Invoke must set `OPENMS_DATA_PATH: ${{ github.workspace }}/OpenMS/share/OpenMS`. Applies to NUnit test steps and `Flash.exe` regression runs.
- **Build output (Phase 0 lesson #12):** Output goes to `FlashIDA/bin/`, not `FlashIDA/src/Flash/bin/Debug/`.
- **Test data path (Phase 1 lesson #2):** `Path.Combine(TestDirectory, "..", "test-data")` — one level up from `bin/`.
- **Submodule pointer updates (Phase 1 lesson #1):** After pushing to either sub-repo, update the parent repo's submodule pointer immediately. New files are silently invisible to CI until the pointer is updated.
- **Submodule batching (Phase 0 lesson #15):** Batch same-side changes (all C++ or all C#) before updating the submodule pointer to minimize churn.
- **DLL build time (Phase 1 lesson #10):** ~40 min per push with no ccache hit. Batch all C++ changes and verify for MSVC `/WX` issues before pushing.
- **`ModificationsDB::getInstance()` (Phase 1 lesson #4):** Never remove or comment out OpenMS singleton initializer calls. Use `(void)` cast if the return value is unused.
- **`.gitattributes` (Phase 0 lesson #4):** If any new binary file extensions are introduced, add them to `FlashIDA/.gitattributes` as `binary` before committing.

---

## Working Product Verification

Because there is no Windows machine available, all WPV items are verified via CI jobs rather than local `Flash.exe` invocations (entry point is `FLASHIdaWrapper.Main()`, not `Flash.Main()` — there is no `-t` flag; see Phase 0 lesson #1). Each item maps to a CI job that produces observable evidence (log output, artifact output, or test pass/fail status).

**WPV-1: Exploration disabled — identical to Phase 6**
Verified by the `P7-R01` regression test in the `windows-tests` CI job (`windows-latest`). The job runs `Flash.exe ms1_standard.txt output.tsv method_default.xml` and compares output against `test-data/golden/phase4_standard_dda.tsv` using `compare_golden.py` (comparison tolerances: [../test-file-specification.md](../test-file-specification.md) §2.1). The CI step must report `PASS`.

**WPV-2: CE optimization produces 5 variant scans per precursor**
Verified by the `P7-R02` regression test in the `windows-tests` CI job (`windows-latest`). The job runs `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` and compares output against `test-data/golden/phase7_exploration.tsv`. Inspect the golden file (captured via the CI-artifact workflow in Step 11) to confirm that for each precursor selected by standard DDA scoring there are 5 additional rows with `EXPL:` scan descriptions, and that `EXPL-WINNER` log entries appear in the CI job log.

**WPV-3: Winner is selected by FragmentationQuality score**
Verified by inspecting the `EXPL-WINNER` log lines in the `windows-tests` CI job log for the `P7-R02` run. Confirm that the logged CE value corresponds to the variant with the highest `fragmentation_quality_score` across the 5 variant rows visible in the `phase7_exploration.tsv` artifact.

**WPV-4: Queue overflow protection at MaxQueueForExploration=50**
Verified by the `windows-tests` CI job using `method_exploration_overflow.xml` (committed to `test-data/configs/`). This config sets `MaxQueueForExploration=5` and uses a spectrum containing many precursors. The CI job log must show that exploration is not initiated once the queue exceeds 5 entries (no `EXPL:` group creation log lines after the queue fills).

**WPV-5: MS1 cycle time suppressed during exploration, resumes after**
Verified by the `windows-tests` CI job using a config committed to `test-data/configs/` with `<CycleTime><Active>True</Active><Seconds>1</Seconds></CycleTime>` and exploration enabled, run with a spectrum that takes multiple scan events. The CI job log must show no MS1 cycle-time injection between the first exploration variant submission and the `EXPL-WINNER` log entry for that group, and then resumed MS1 injection afterwards.

**WPV-6: OptimizationMetadata populated and serialized**
Verified from the `phase7_exploration.tsv` artifact produced by `P7-R02` in the `windows-tests` CI job. The standard 15-column golden file format is defined in [../test-file-specification.md](../test-file-specification.md) §2.1. Exploration variant rows extend this with additional metavalue columns written by `toSpectrum()` when `OptimizationMetadata` is present. Inspect the artifact for `optimization_group_id`, `optimization_collision_energy`, `optimization_is_best_variant`, `optimization_quality_score`, and `optimization_precursor_mass` columns — they must be present and non-empty for exploration variant rows.

**WPV-7: MS3 recursive exploration respects depth limit**
Verified by the `windows-tests` CI job using `method_exploration_ms3.xml` (committed to `test-data/configs/`) with `MS3Exploration.Enabled=true`, `MaxExplorationDepth=2`, `MaxFragmentsToExplore=3`, run with an MS1+MS2 test spectrum. The CI job log must show:
- MS2 exploration groups created (depth=1).
- After MS2 winner selection, MS3 child groups created (depth=2).
- No depth-3 groups created.
- Total exploration scans per MS2 precursor: (5 MS2 CE variants) + (3 fragments * 5 MS3 CE variants) = 20 scans, not more.

This is also verified structurally by P7-U07 and P7-U08 in the `cpp-unit-tests` CI job (`ubuntu-latest`).

---

## Definition of Done

- [ ] All 12 Phase 7 tests pass: P7-U01 through P7-U10 (C++, `ubuntu-latest`) and P7-R01, P7-R02 (`windows-latest`).
- [ ] All prior phase tests (P0 through P6, cumulative total 79 tests) continue to pass — no regressions introduced.
- [ ] `ExplorationGroup` and `ExplorationVariant` structs are defined in `FLASHIda.h`.
- [ ] `initiateMS2Exploration_()`, `feedExplorationResult_()`, `initiateMS3Exploration_()`, `computeFragmentationQuality_()`, `buildCEVariants_()` are implemented in `FLASHIda.cpp`.
- [ ] `getNextScanCommand()` suppresses MS1 cycle time injection when `active_exploration_groups_` is non-empty.
- [ ] `processScan()` MS2 path detects `EXPL:` prefix in `scan_description` and routes to `feedExplorationResult_()`.
- [ ] `OptimizationMetadata` is populated on every exploration variant's `DeconvolvedSpectrum` before `feedExplorationResult_()` returns.
- [ ] `Parameter.ToJSON()` serializes the full `<ParameterOptimization>` XML subtree into the `exploration` JSON object with all sub-keys.
- [ ] `method_exploration.xml` exists in `FlashIDA/test-data/configs/` (format and key parameters per [../test-file-specification.md](../test-file-specification.md) §3.2).
- [ ] `test-data/golden/phase7_exploration.tsv` exists and is committed (canonical name per [../test-file-specification.md](../test-file-specification.md) §2.2).
- [ ] `FLASHIda_exploration_test` C++ test binary is listed in `executables.cmake` and discovered by CTest.
- [ ] `.github/workflows/flashida-ci.yml` regression runner includes `method_exploration.xml` with golden file `phase7_exploration.tsv` (entry name `p7_exploration`, per [../test-file-specification.md](../test-file-specification.md) §4.2 config array).
- [ ] `Flash.exe ms1_standard.txt output.tsv method_default.xml` with exploration disabled produces output identical to `phase4_standard_dda.tsv` (P7-R01 passes in CI (`windows-tests` job); comparison uses `compare_golden.py` tolerances from [../test-file-specification.md](../test-file-specification.md) §2.1).
- [ ] `Flash.exe ms1_standard.txt output.tsv method_exploration.xml` produces EXPL-WINNER log entries and variant rows in output matching `phase7_exploration.tsv` (P7-R02 passes in CI).
- [ ] MS3 recursive exploration creates child groups and respects `MaxExplorationDepth` (P7-U07, P7-U08 pass in CI (`cpp-unit-tests` job)).
- [ ] No new C++ compiler warnings introduced (existing `/Wall` or `-Wall` build flags must remain clean).
- [ ] Code review complete: `ExplorationGroup` / `ExplorationVariant` structs, `feedExplorationResult_()` winner logic, depth-limit check, and MS1 suppression logic reviewed by at least one other developer.
- [ ] Phase 8 prerequisites are satisfied: Phase 7 golden files committed, all WPV items checked off. Build #4 development can proceed to Phase 8 (cleanup) on the same branch.

---

## Phase 0–1 Lessons Applied

This section records which Phase 0 and Phase 1 lessons are directly reflected in this implementation plan, so future plan reviews can verify coverage.

| Lesson | Source | Where Applied in This Plan |
|--------|--------|---------------------------|
| Flash.exe entry point — no `-t` flag | Phase 0 #1 | Cross-References item 1; WPV section preamble; P7-R01, P7-R02 test descriptions; DoD |
| Build output path `FlashIDA/bin/` | Phase 0 #12 | Cross-References item 2; CI reminders §5 |
| DLL name `"OpenMS.dll"` with extension | Phase 0 #12 | Cross-References item 3; Files to Create/Modify note |
| NUnit working directory `FlashIDA/bin/` | Phase 0 #12 | Cross-References item 4; CI reminders §5 |
| Spectrum file format (tab + seconds) | Phase 0 #2 | Cross-References item 5 |
| Thermo DLL Strategy B (openssl) | Phase 0 #3 | Cross-References item 6; CI reminders §5 |
| OpenMS DLLs committed in `FlashIDA/dll/` | Phase 0 #5 | Cross-References item 7; CI reminders §5 |
| Golden file capture requires 2-commit minimum | Phase 0 #15 | Cross-References item 8; Step 11 golden capture workflow; CI §3 |
| DLL-dependent tests are Tier 2 | Phase 0 #12 | Cross-References item 9; Test Cases preamble |
| Silent zero-result P/Invoke failures | Phase 0 #14 | Cross-References item 10; Files to Create/Modify note |
| Submodule batching | Phase 0 #15 | Cross-References item 11; Step 11; CI reminders §5 |
| Multi-scan parser stop at first boundary | Phase 0 #9 | Cross-References item 12 |
| `.gitattributes` binary extensions | Phase 0 #4 | Cross-References item 13; CI reminders §5 |
| Submodule pointer update required for CI | Phase 1 #1 | Cross-References item 14; CI reminders §5 |
| Test data path one level up from `bin/` | Phase 1 #2 | Cross-References item 15; CI reminders §5 |
| NUnit `--agents=1 --timeout=300000` | Phase 1 #8 | Cross-References item 16; CI reminders §5 |
| `OPENMS_DATA_PATH` required in CI | Phase 1 #5 | Cross-References item 17; CI reminders §5 |
| DLL build ~40 min; batch C++ changes | Phase 1 #10 | Cross-References item 18; CI reminders §5 |
| MSVC `/WX` warnings-as-errors | Phase 1 #3 | Cross-References item 19 |
| `ModificationsDB::getInstance()` side effects | Phase 1 #4 | Cross-References item 20; CI reminders §5 |
| Prefer `FLASHIdaWrapper(MethodParameters)` | Phase 1 #11 | Cross-References item 21 |
| ms3 array parsing deferred from Phase 1 | Phase 1 (deferred) | Prerequisites item 6; Cross-References item 22 |

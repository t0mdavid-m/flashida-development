# Scan Parameter Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Microscans, DataType, ScanRate, RFLens, SourceCID, SourceCIDScaling through the full C++ engine path; fix FirstMass/LastMass per-level routing; expand ScanCommand to 2048 bytes with a reserved block for future expansion.

**Architecture:** All parameters flow through `ToCppJson()` (C#) → `Config` parser (C++) → `ScanConfig` → builders → `ScanCommand` → `BuildFromCommand()` (C#) → Thermo API. The `ScanCommand` struct grows from 1248 to 2048 bytes, with 704 bytes of reserved space. Zero/empty values mean "unset — inherit from method default."

**Tech Stack:** C++20 (OpenMS), C# .NET 4.8 (FlashIDA), P/Invoke blittable struct marshalling, nlohmann::json, CTest (C++ tests), NUnit (C# tests)

---

### Task 1: Expand ScanCommand struct (C++)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h:64-97`

- [ ] **Step 1: Add new fields and reserved block to ScanCommand**

In `ScanCommand.h`, add after `faims_cv` (line 95) and before the closing brace (line 96):

```cpp
    int32_t microscans;            ///< Number of microscans (0 = use method default)
    int32_t pad3;                  ///< Alignment padding
    double rf_lens;                ///< RF lens voltage (0 = use method default)
    double source_cid;             ///< Source CID energy (0 = use method default)
    double source_cid_scaling;     ///< Source CID scaling factor (0 = use method default)
    char data_type[32];            ///< Data type (e.g., "Centroid", "Profile"; empty = method default)
    char scan_rate[32];            ///< Scan rate (e.g., "Normal", "Turbo"; empty = method default)
    char reserved_[704];           ///< Reserved for future fields (consume from here, never change total size)
```

- [ ] **Step 2: Update the layout comment and static_assert**

Change the layout comment (line 62-63) to:

```cpp
  /// Blittable struct representing a complete scan command for the instrument.
  /// Layout: 1248 (existing) + 8 (microscans+pad3) + 24 (rf_lens+source_cid+source_cid_scaling)
  ///       + 64 (data_type+scan_rate) + 704 (reserved) = 2048.
```

Change the static_assert (line 97) to:

```cpp
  static_assert(sizeof(ScanCommand) == 2048, "ScanCommand must be 2048 bytes for P/Invoke");
```

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/ScanCommand.h
git commit -m "ScanCommand: expand to 2048 bytes with reserved block

Add microscans, rf_lens, source_cid, source_cid_scaling, data_type[32],
scan_rate[32] fields. 704-byte reserved_ tail for future expansion."
```

---

### Task 2: Update ScanCommandLayout_test (C++)

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp:61-65`

- [ ] **Step 1: Add offset prints for new fields**

After the `faims_cv` offset line (line 61), add:

```cpp
  std::printf("ScanCommand.microscans.offset=%zu\n", offsetof(ScanCommand, microscans));
  std::printf("ScanCommand.pad3.offset=%zu\n", offsetof(ScanCommand, pad3));
  std::printf("ScanCommand.rf_lens.offset=%zu\n", offsetof(ScanCommand, rf_lens));
  std::printf("ScanCommand.source_cid.offset=%zu\n", offsetof(ScanCommand, source_cid));
  std::printf("ScanCommand.source_cid_scaling.offset=%zu\n", offsetof(ScanCommand, source_cid_scaling));
  std::printf("ScanCommand.data_type.offset=%zu\n", offsetof(ScanCommand, data_type));
  std::printf("ScanCommand.scan_rate.offset=%zu\n", offsetof(ScanCommand, scan_rate));
  std::printf("ScanCommand.reserved_.offset=%zu\n", offsetof(ScanCommand, reserved_));
```

- [ ] **Step 2: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/ScanCommandLayout_test.cpp
git commit -m "ScanCommandLayout_test: add offset prints for new fields"
```

---

### Task 3: Expand ScanConfig and Config parser (C++)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h:68-81`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp:210-258`

- [ ] **Step 1: Add new fields to ScanConfig struct**

In `Config.h`, add after `double max_it = 0;` (line 77) and before the `applyOverrides` declaration (line 80):

```cpp
    int microscans = 0;
    double rf_lens = 0;
    double source_cid = 0;
    double source_cid_scaling = 0;
    std::string data_type;
    std::string scan_rate;
```

- [ ] **Step 2: Parse new keys in MS1 config block**

In `Config.cpp`, after `ms1_scan.max_it = ms1_json.value("max_it", 0.0);` (line 217), add:

```cpp
    ms1_scan.microscans = ms1_json.value("microscans", 0);
    ms1_scan.rf_lens = ms1_json.value("rf_lens", 0.0);
    ms1_scan.source_cid = ms1_json.value("source_cid", 0.0);
    ms1_scan.source_cid_scaling = ms1_json.value("source_cid_scaling", 0.0);
    ms1_scan.data_type = ms1_json.value("data_type", std::string(""));
    ms1_scan.scan_rate = ms1_json.value("scan_rate", std::string(""));
```

- [ ] **Step 3: Parse first_mass, last_mass, and new keys in MS2 config loop**

In `Config.cpp`, after `ms2_scan.max_it = m.value("max_it", 0);` (line 237), add:

```cpp
        ms2_scan.first_mass = m.value("first_mass", 0.0);
        ms2_scan.last_mass = m.value("last_mass", 0.0);
        ms2_scan.microscans = m.value("microscans", 0);
        ms2_scan.rf_lens = m.value("rf_lens", 0.0);
        ms2_scan.source_cid = m.value("source_cid", 0.0);
        ms2_scan.source_cid_scaling = m.value("source_cid_scaling", 0.0);
        ms2_scan.data_type = m.value("data_type", std::string(""));
        ms2_scan.scan_rate = m.value("scan_rate", std::string(""));
```

- [ ] **Step 4: Parse first_mass, last_mass, and new keys in MS3 config loop**

In `Config.cpp`, after `ms3_scan.max_it = m.value("max_it", 0);` (line 255), add:

```cpp
        ms3_scan.first_mass = m.value("first_mass", 0.0);
        ms3_scan.last_mass = m.value("last_mass", 0.0);
        ms3_scan.microscans = m.value("microscans", 0);
        ms3_scan.rf_lens = m.value("rf_lens", 0.0);
        ms3_scan.source_cid = m.value("source_cid", 0.0);
        ms3_scan.source_cid_scaling = m.value("source_cid_scaling", 0.0);
        ms3_scan.data_type = m.value("data_type", std::string(""));
        ms3_scan.scan_rate = m.value("scan_rate", std::string(""));
```

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda/Config.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/Config.cpp
git commit -m "Config: add scan parameters and fix MS2/MS3 first_mass/last_mass parsing

ScanConfig gains microscans, rf_lens, source_cid, source_cid_scaling,
data_type, scan_rate. MS2/MS3 parsing loops now read first_mass and
last_mass (previously only parsed for MS1)."
```

---

### Task 4: Update builders to populate new fields (C++)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp:131-309`

- [ ] **Step 1: Update makeMS1() to populate new fields**

In `ScanCommandQueue.cpp`, after `cmd.max_it = config_.level(1).scans[0].max_it;` (line 142), add:

```cpp
    cmd.microscans = config_.level(1).scans[0].microscans;
    cmd.rf_lens = config_.level(1).scans[0].rf_lens;
    cmd.source_cid = config_.level(1).scans[0].source_cid;
    cmd.source_cid_scaling = config_.level(1).scans[0].source_cid_scaling;
    std::strncpy(cmd.data_type, config_.level(1).scans[0].data_type.c_str(), sizeof(cmd.data_type) - 1);
    cmd.data_type[sizeof(cmd.data_type) - 1] = '\0';
    std::strncpy(cmd.scan_rate, config_.level(1).scans[0].scan_rate.c_str(), sizeof(cmd.scan_rate) - 1);
    cmd.scan_rate[sizeof(cmd.scan_rate) - 1] = '\0';
```

- [ ] **Step 2: Update buildMS2() to use per-level first_mass/last_mass and populate new fields**

In `ScanCommandQueue.cpp`, replace lines 190-196:

```cpp
    // Instrument defaults from MS1 config
    cmd.first_mass = config_.level(1).scans[0].first_mass;
    cmd.last_mass = config_.level(1).scans[0].last_mass;
    
    // Scan properties directly from MS2 config
    cmd.agc_target = config_.level(2).scans[0].agc_target;
    cmd.max_it = config_.level(2).scans[0].max_it;
```

With:

```cpp
    // Mass range from MS2 config (0 = unset, Thermo API inherits from method default)
    cmd.first_mass = scan_config.first_mass;
    cmd.last_mass = scan_config.last_mass;
    
    // Scan properties from MS2 config
    cmd.agc_target = config_.level(2).scans[0].agc_target;
    cmd.max_it = config_.level(2).scans[0].max_it;

    // New scan parameters from MS2 config
    cmd.microscans = scan_config.microscans;
    cmd.rf_lens = scan_config.rf_lens;
    cmd.source_cid = scan_config.source_cid;
    cmd.source_cid_scaling = scan_config.source_cid_scaling;
    std::strncpy(cmd.data_type, scan_config.data_type.c_str(), sizeof(cmd.data_type) - 1);
    cmd.data_type[sizeof(cmd.data_type) - 1] = '\0';
    std::strncpy(cmd.scan_rate, scan_config.scan_rate.c_str(), sizeof(cmd.scan_rate) - 1);
    cmd.scan_rate[sizeof(cmd.scan_rate) - 1] = '\0';
```

- [ ] **Step 3: Update buildMS3() to use per-level first_mass/last_mass and populate new fields**

In `ScanCommandQueue.cpp`, replace lines 264-266:

```cpp
    // Copy analyzer/resolution from MS2 context
    cmd.first_mass = ms2_ctx.first_mass;
    cmd.last_mass = ms2_ctx.last_mass;
```

With:

```cpp
    // Mass range from MS3 config (0 = unset, Thermo API inherits from method default)
    cmd.first_mass = ms3_config.first_mass;
    cmd.last_mass = ms3_config.last_mass;
```

Then after `cmd.analyzer[sizeof(cmd.analyzer) - 1] = '\0';` (line 272), add:

```cpp
    // New scan parameters from MS3 config
    cmd.microscans = ms3_config.microscans;
    cmd.rf_lens = ms3_config.rf_lens;
    cmd.source_cid = ms3_config.source_cid;
    cmd.source_cid_scaling = ms3_config.source_cid_scaling;
    std::strncpy(cmd.data_type, ms3_config.data_type.c_str(), sizeof(cmd.data_type) - 1);
    cmd.data_type[sizeof(cmd.data_type) - 1] = '\0';
    std::strncpy(cmd.scan_rate, ms3_config.scan_rate.c_str(), sizeof(cmd.scan_rate) - 1);
    cmd.scan_rate[sizeof(cmd.scan_rate) - 1] = '\0';
```

- [ ] **Step 4: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda/ScanCommandQueue.cpp
git commit -m "Builders: populate new scan params, fix MS2/MS3 first_mass/last_mass

makeMS1/buildMS2/buildMS3 now set microscans, rf_lens, source_cid,
source_cid_scaling, data_type, scan_rate from their respective ScanConfig.
buildMS2 uses scan_config.first_mass/last_mass instead of MS1 values.
buildMS3 uses ms3_config.first_mass/last_mass instead of ms2_ctx values."
```

---

### Task 5: Push C++ changes and trigger DLL build

- [ ] **Step 1: Push to flashida-v9-bridge**

```bash
cd OpenMS
git push origin HEAD:flashida-v9-bridge
```

Wait for the `build-dlls` workflow to trigger. The hook output will show the run ID.

- [ ] **Step 2: Wait for DLL build (~40 min)**

The `build-dlls` workflow auto-triggers on push to `flashida-v9-bridge`. Do not poll — the user will signal when to proceed.

---

### Task 6: Update C# ScanCommand struct

**Files:**
- Modify: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:37-72`

- [ ] **Step 1: Add new fields and reserved block after FaimsCv**

In `FLASHIdaWrapper.cs`, after `public double FaimsCv;` (line 71), add:

```csharp
        public int Microscans;
        public int Pad3;
        public double RfLens;
        public double SourceCid;
        public double SourceCidScaling;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DataType;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string ScanRate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 704)]
        public byte[] Reserved;
```

- [ ] **Step 2: Update the layout comment**

Change the comment (lines 31-34) to:

```csharp
    /// <summary>
    /// Blittable struct matching C++ ScanCommand (2048 bytes).
    /// Layout: 1248 (existing) + 8 (microscans+pad3) + 24 (rf_lens+source_cid+source_cid_scaling)
    ///       + 64 (data_type+scan_rate) + 704 (reserved) = 2048.
    /// </summary>
```

- [ ] **Step 3: Commit**

```bash
cd FlashIDA
git add src/Flash/IDA/FLASHIdaWrapper.cs
git commit -m "ScanCommand: expand to 2048 bytes matching C++ layout

Add Microscans, RfLens, SourceCid, SourceCidScaling, DataType[32],
ScanRate[32], Reserved[704]."
```

---

### Task 7: Update C# ScanCommandLayoutTests

**Files:**
- Modify: `FlashIDA/src/Flash.Tests/ScanCommandLayoutTests.cs:17-67`

- [ ] **Step 1: Update size assertion**

Change line 21:

```csharp
            Assert.AreEqual(2048, Marshal.SizeOf<ScanCommand>(),
                "ScanCommand must be 2048 bytes to match C++ layout");
```

- [ ] **Step 2: Add offset assertions for new fields**

After the `FaimsCv` offset assertion (line 67), add:

```csharp
            // New scan parameter fields (after FaimsCv at 1240 + 8 = 1248)
            Assert.AreEqual(1248, (int)Marshal.OffsetOf<ScanCommand>("Microscans"), "Microscans offset");
            Assert.AreEqual(1252, (int)Marshal.OffsetOf<ScanCommand>("Pad3"), "Pad3 offset");
            Assert.AreEqual(1256, (int)Marshal.OffsetOf<ScanCommand>("RfLens"), "RfLens offset");
            Assert.AreEqual(1264, (int)Marshal.OffsetOf<ScanCommand>("SourceCid"), "SourceCid offset");
            Assert.AreEqual(1272, (int)Marshal.OffsetOf<ScanCommand>("SourceCidScaling"), "SourceCidScaling offset");
            Assert.AreEqual(1280, (int)Marshal.OffsetOf<ScanCommand>("DataType"), "DataType offset");
            Assert.AreEqual(1312, (int)Marshal.OffsetOf<ScanCommand>("ScanRate"), "ScanRate offset");
            Assert.AreEqual(1344, (int)Marshal.OffsetOf<ScanCommand>("Reserved"), "Reserved offset");
```

- [ ] **Step 3: Add SizeConst assertions for new char fields**

In the `P3_U04` test method, after the `ActivationType` SizeConst assertion (line 100), add:

```csharp
            // ScanCommand.DataType should be SizeConst=32
            var dataTypeAttr = typeof(ScanCommand).GetField("DataType")
                .GetCustomAttribute<MarshalAsAttribute>();
            Assert.IsNotNull(dataTypeAttr, "DataType should have MarshalAs attribute");
            Assert.AreEqual(32, dataTypeAttr.SizeConst, "DataType SizeConst");

            // ScanCommand.ScanRate should be SizeConst=32
            var scanRateAttr = typeof(ScanCommand).GetField("ScanRate")
                .GetCustomAttribute<MarshalAsAttribute>();
            Assert.IsNotNull(scanRateAttr, "ScanRate should have MarshalAs attribute");
            Assert.AreEqual(32, scanRateAttr.SizeConst, "ScanRate SizeConst");

            // ScanCommand.Reserved should be SizeConst=704
            var reservedAttr = typeof(ScanCommand).GetField("Reserved")
                .GetCustomAttribute<MarshalAsAttribute>();
            Assert.IsNotNull(reservedAttr, "Reserved should have MarshalAs attribute");
            Assert.AreEqual(704, reservedAttr.SizeConst, "Reserved SizeConst");
```

- [ ] **Step 4: Commit**

```bash
cd FlashIDA
git add src/Flash.Tests/ScanCommandLayoutTests.cs
git commit -m "ScanCommandLayoutTests: update for 2048-byte struct with new fields"
```

---

### Task 8: Update ToCppJson() serialization (C#)

**Files:**
- Modify: `FlashIDA/src/Flash/MethodConfig.cs:416-441`
- Modify: `FlashIDA/src/Flash/MethodParameters.cs:169-197`

- [ ] **Step 1: Add new fields to JsonMs1Config**

In `MethodConfig.cs`, add after `public double max_it { get; set; }` (line 423):

```csharp
        public int microscans { get; set; }
        public double rf_lens { get; set; }
        public double source_cid { get; set; }
        public double source_cid_scaling { get; set; }
        public string data_type { get; set; }
        public string scan_rate { get; set; }
```

- [ ] **Step 2: Add new fields to JsonMs2Config**

In `MethodConfig.cs`, add after `public double max_it { get; set; }` (line 433):

```csharp
        public double first_mass { get; set; }
        public double last_mass { get; set; }
        public int microscans { get; set; }
        public double rf_lens { get; set; }
        public double source_cid { get; set; }
        public double source_cid_scaling { get; set; }
        public string data_type { get; set; }
        public string scan_rate { get; set; }
```

- [ ] **Step 3: Serialize new MS1 fields in ToCppJson()**

In `MethodParameters.cs`, replace lines 171-178:

```csharp
                    ms1 = new JsonMs1Config
                    {
                        analyzer = c.MsSettings.MS1.Analyzer ?? "",
                        first_mass = c.MsSettings.MS1.FirstMass,
                        last_mass = c.MsSettings.MS1.LastMass,
                        resolution = c.MsSettings.MS1.OrbitrapResolution,
                        agc_target = c.MsSettings.MS1.AGCTarget,
                        max_it = c.MsSettings.MS1.MaxIT
                    },
```

With:

```csharp
                    ms1 = new JsonMs1Config
                    {
                        analyzer = c.MsSettings.MS1.Analyzer ?? "",
                        first_mass = c.MsSettings.MS1.FirstMass,
                        last_mass = c.MsSettings.MS1.LastMass,
                        resolution = c.MsSettings.MS1.OrbitrapResolution,
                        agc_target = c.MsSettings.MS1.AGCTarget,
                        max_it = c.MsSettings.MS1.MaxIT,
                        microscans = c.MsSettings.MS1.Microscans,
                        rf_lens = c.MsSettings.MS1.RFLens,
                        source_cid = c.MsSettings.MS1.SourceCID,
                        source_cid_scaling = c.MsSettings.MS1.SourceCIDScaling,
                        data_type = c.MsSettings.MS1.DataType ?? "",
                        scan_rate = ""
                    },
```

- [ ] **Step 4: Serialize new MS2 fields (including first_mass/last_mass) in ToCppJson()**

In `MethodParameters.cs`, replace lines 180-188:

```csharp
                    ms2 = ms2List.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution
                        agc_target = m.AGCTarget,
                        max_it = m.MaxIT
                    }).ToArray(),
```

With:

```csharp
                    ms2 = ms2List.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution,
                        agc_target = m.AGCTarget,
                        max_it = m.MaxIT,
                        first_mass = m.FirstMass,
                        last_mass = m.LastMass,
                        microscans = m.Microscans,
                        data_type = m.DataType ?? "",
                        scan_rate = ""
                    }).ToArray(),
```

- [ ] **Step 5: Serialize new MS3 fields (including first_mass/last_mass) in ToCppJson()**

In `MethodParameters.cs`, replace lines 189-197:

```csharp
                    ms3 = c.MsSettings.MS3.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution
                        agc_target = m.AGCTarget,
                        max_it = m.MaxIT
                    }).ToArray()
```

With:

```csharp
                    ms3 = c.MsSettings.MS3.Select(m => new JsonMs2Config
                    {
                        analyzer = m.Analyzer ?? "",
                        activation = m.Activation ?? "",
                        collision_energy = m.CollisionEnergy,
                        resolution = m.OrbitrapResolution,
                        agc_target = m.AGCTarget,
                        max_it = m.MaxIT,
                        first_mass = m.FirstMass,
                        last_mass = m.LastMass,
                        microscans = m.Microscans,
                        data_type = m.DataType ?? "",
                        scan_rate = ""
                    }).ToArray()
```

- [ ] **Step 6: Commit**

```bash
cd FlashIDA
git add src/Flash/MethodConfig.cs src/Flash/MethodParameters.cs
git commit -m "ToCppJson: serialize all scan params including MS2/MS3 first_mass/last_mass

JsonMs1Config gains microscans, rf_lens, source_cid, source_cid_scaling,
data_type, scan_rate. JsonMs2Config gains first_mass, last_mass (previously
missing for MS2/MS3), microscans, data_type, scan_rate."
```

---

### Task 9: Update BuildFromCommand() mapping (C#)

**Files:**
- Modify: `FlashIDA/src/Flash/ScanFactory.cs:153-231`

- [ ] **Step 1: Add new parameter mappings**

In `ScanFactory.cs`, after the FAIMS CV block (lines 224-228), add:

```csharp
            // New scan parameters from C++ engine
            if (cmd.Microscans > 0)
                p.Microscans = cmd.Microscans;

            if (cmd.RfLens > 0)
                p.SrcRFLens = new double[] { cmd.RfLens };

            if (cmd.SourceCid > 0)
                p.SourceCIDEnergy = cmd.SourceCid;

            if (cmd.SourceCidScaling > 0)
                p.SourceCIDScalingFactor = cmd.SourceCidScaling;

            if (!string.IsNullOrEmpty(cmd.DataType))
                p.DataType = cmd.DataType;

            if (!string.IsNullOrEmpty(cmd.ScanRate))
                p.ScanRate = cmd.ScanRate;
```

- [ ] **Step 2: Commit**

```bash
cd FlashIDA
git add src/Flash/ScanFactory.cs
git commit -m "BuildFromCommand: map new scan params to Thermo API ScanParameters"
```

---

### Task 10: Download DLL and update FlashIDA

- [ ] **Step 1: Download the DLL artifact**

After the `build-dlls` workflow completes:

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
RUN_ID=<run-id-from-hook-output>
rm -rf /tmp/dll-extract
gh run download $RUN_ID -R t0mdavid-m/OpenMS -n selected-bin-artifacts -D /tmp/dll-extract
```

- [ ] **Step 2: Copy DLLs to FlashIDA**

```bash
cp /tmp/dll-extract/*.dll FlashIDA/dll/
cp /tmp/dll-extract/*.pdb FlashIDA/dll/ 2>/dev/null || true
```

- [ ] **Step 3: Commit DLLs**

```bash
cd FlashIDA
git add dll/
git commit -m "Update OpenMS DLLs: scan parameter expansion (2048-byte ScanCommand)"
```

---

### Task 11: Update submodule pointers and push

- [ ] **Step 1: Update submodule pointers in parent repo**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add OpenMS FlashIDA
git commit -m "Update submodules: scan parameter expansion

ScanCommand expanded to 2048 bytes with reserved block. New per-scan
params: microscans, data_type, scan_rate, rf_lens, source_cid,
source_cid_scaling. Fixed MS2/MS3 first_mass/last_mass routing."
```

- [ ] **Step 2: Push parent repo**

```bash
git push
```

Wait for `flashida-ci.yml` to trigger and verify all tests pass.

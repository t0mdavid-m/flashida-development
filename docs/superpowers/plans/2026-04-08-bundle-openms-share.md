# Bundle OpenMS Shared Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate manual `OPENMS_DATA_PATH` setup by bundling the OpenMS share tree in the FlashIDA repo and setting the env var automatically at startup.

**Architecture:** Copy `OpenMS/share/OpenMS/` (minus `examples/`) into `FlashIDA/share/OpenMS/`. MSBuild copies it to the output directory. `FLASHIdaWrapper` sets `OPENMS_DATA_PATH` before the first P/Invoke call. No C++ changes.

**Tech Stack:** C# .NET 4.8, MSBuild, Windows x64

**Spec:** `docs/superpowers/specs/2026-04-08-bundle-openms-share-design.md`

---

### Task 1: Copy the share tree into the FlashIDA repo

**Files:**
- Create: `FlashIDA/share/OpenMS/` (directory tree copied from `OpenMS/share/OpenMS/`, excluding `examples/`)

This is a file-system operation, not a code change. The `examples/` subdirectory is 136 MB of sample data not used at runtime — exclude it.

- [ ] **Step 1: Copy the share tree excluding examples/**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
mkdir -p FlashIDA/share/OpenMS
# Copy all subdirectories except examples/
for dir in CHEMISTRY CV DESKTOP GUISTYLE MAPPING NUXL SCHEMAS SCRIPTS THIRDPARTY TOOLS XSL; do
    cp -r OpenMS/share/OpenMS/$dir FlashIDA/share/OpenMS/
done
```

- [ ] **Step 2: Verify the copy**

```bash
ls FlashIDA/share/OpenMS/
```

Expected: 11 subdirectories (CHEMISTRY, CV, DESKTOP, GUISTYLE, MAPPING, NUXL, SCHEMAS, SCRIPTS, THIRDPARTY, TOOLS, XSL). No `examples/`.

```bash
du -sh FlashIDA/share/OpenMS/
```

Expected: ~59 MB total.

- [ ] **Step 3: Verify critical files exist**

```bash
test -f FlashIDA/share/OpenMS/CHEMISTRY/unimod.xml && echo "OK" || echo "MISSING"
test -f FlashIDA/share/OpenMS/CHEMISTRY/PSI-MOD.obo && echo "OK" || echo "MISSING"
test -f FlashIDA/share/OpenMS/CV/psi-ms.obo && echo "OK" || echo "MISSING"
```

Expected: All "OK".

- [ ] **Step 4: Commit**

```bash
cd FlashIDA
git add share/OpenMS/
git commit -m "Add OpenMS shared data (excluding examples/) for bundled deployment"
```

---

### Task 2: Wire up MSBuild and set OPENMS_DATA_PATH

**Files:**
- Modify: `FlashIDA/src/Flash/Flash.csproj:126-152` — add `<Content>` items for the share tree
- Modify: `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs:109-113` — set env var before `CreateFLASHIda()`

- [ ] **Step 1: Add the share tree Content items to Flash.csproj**

In `FlashIDA/src/Flash/Flash.csproj`, add a new `<ItemGroup>` after the existing `<ItemGroup>` containing DLL `<None>` items (after line 152, before the `<Import>` on line 153):

```xml
  <ItemGroup>
    <Content Include="..\..\share\OpenMS\**\*">
      <Link>share\OpenMS\%(RecursiveDir)%(Filename)%(Extension)</Link>
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </Content>
  </ItemGroup>
```

This uses a recursive wildcard to capture the entire tree. `%(RecursiveDir)` preserves the directory structure. `PreserveNewest` avoids unnecessary copies on incremental builds.

- [ ] **Step 2: Add the using directive and set OPENMS_DATA_PATH in FLASHIdaWrapper constructor**

In `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs`, the constructor at lines 109-113 currently reads:

```csharp
        public FLASHIdaWrapper(MethodParameters mp)
        {
            string arg = mp.IDA.ToJSON(mp);
            m_pNativeObject = CreateFLASHIda(arg);
        }
```

Change it to:

```csharp
        public FLASHIdaWrapper(MethodParameters mp)
        {
            string sharePath = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "share", "OpenMS");
            Environment.SetEnvironmentVariable("OPENMS_DATA_PATH", sharePath);

            string arg = mp.IDA.ToJSON(mp);
            m_pNativeObject = CreateFLASHIda(arg);
        }
```

`AppDomain.CurrentDomain.BaseDirectory` is the directory containing Flash.exe. This works regardless of the current working directory at launch time. Both entry points (instrument mode via `Flash.cs:288` and test mode via `FLASHIdaWrapper.Main():424`) go through this constructor.

Check whether `System.IO` is already imported at the top of the file. If so, use `Path.Combine(...)` directly. If not, use the fully qualified `System.IO.Path.Combine(...)` as shown above.

- [ ] **Step 3: Build**

```bash
msbuild FlashIDA/src/Flash/Flash.sln /p:Configuration=Debug /p:Platform="Any CPU"
```

Expected: Build succeeds. The `FlashIDA/bin/share/OpenMS/` directory should now exist with all subdirectories.

- [ ] **Step 4: Verify share tree was copied to output**

```bash
test -f FlashIDA/bin/share/OpenMS/CHEMISTRY/unimod.xml && echo "OK" || echo "MISSING"
ls FlashIDA/bin/share/OpenMS/
```

Expected: "OK" and all 11 subdirectories present.

- [ ] **Step 5: Commit**

```bash
cd FlashIDA
git add src/Flash/Flash.csproj src/Flash/IDA/FLASHIdaWrapper.cs
git commit -m "Set OPENMS_DATA_PATH automatically from bundled share data"
```

---

### Task 3: Update Installation.md

**Files:**
- Modify: `FlashIDA/Installation.md:50-57` — remove manual share copy and env var instructions

- [ ] **Step 1: Update the setup instructions**

In `FlashIDA/Installation.md`, lines 50-57 currently say:

```
* Copy the following files from OpenMS `bin` folder to the folder with the software
    + `OpenMS_GUI.dll`
    + `OpenSwathAlgo.dll`
    + `Qt5Core.dll`
    + `Qt5Network.dll`
    + `SuperHirn.dll`
* Copy `share\OpenMS` folder from OpenMS to the folder with the software, but keep the hirearchy, i.e. the software folder should contain `share` that contains `OpenMS` folder with all subfolders
* Set the enironment variable `OPENMS_DATA_PATH` to the location of `OpenMS` folder that you have copied at the previous step, i.e. if you place the softwatre to `C:\FlashIDA`, the value of the variable should be `C:\FlashIDA\share\OpenMS`. It should be possible to use existing OpenMS installation as well
```

Replace lines 50-57 with:

```
* The following runtime files are bundled with the build output and do not need to be copied manually:
    + `OpenMS.dll`, `OpenSwathAlgo.dll`, `Qt6Core.dll`, `Qt6Network.dll`, `zlib.dll` (in the application folder)
    + `share\OpenMS\` (shared data directory — `OPENMS_DATA_PATH` is set automatically at startup)
```

Also update the directory tree (lines 59-133) to remove the outdated DLL names (`OpenMS_GUI.dll`, `Qt5Core.dll`, `Qt5Network.dll`, `SuperHirn.dll`) and replace with current ones (`Qt6Core.dll`, `Qt6Network.dll`, `zlib.dll`). Remove the `examples` subtree from the listing.

- [ ] **Step 2: Commit**

```bash
cd FlashIDA
git add Installation.md
git commit -m "Update Installation.md: shared data is now bundled automatically"
```

---

### Task 4: Update parent submodule pointer

**Files:**
- Modify: parent repo submodule pointer for `FlashIDA`

- [ ] **Step 1: Update submodule pointer**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add FlashIDA
git commit -m "Update FlashIDA submodule: bundle OpenMS shared data"
```

- [ ] **Step 2: Push and verify CI**

```bash
git push
```

Watch for CI to pass — the continuity tests exercise the full pipeline including `CreateFLASHIda()` which triggers `ModificationsDB::getInstance()` which loads `CHEMISTRY/unimod.xml`. If the share tree is missing or `OPENMS_DATA_PATH` is wrong, these tests will crash with `exit(1)`.

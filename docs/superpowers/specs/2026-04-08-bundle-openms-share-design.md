# Bundle OpenMS Shared Data in FlashIDA

**Date:** 2026-04-08
**Status:** Approved

## Problem

OpenMS resolves its shared data directory (`share/OpenMS/`) via the `OPENMS_DATA_PATH` environment variable. When this variable is not set, `File::getOpenMSDataPath()` calls `exit(1)`, killing the entire hosting process — including the Thermo instrument application. This requires manual environment variable configuration on every deployment machine, which is error-prone and has caused crashes in the field.

## Goal

Eliminate the manual `OPENMS_DATA_PATH` setup by bundling the OpenMS share tree in the FlashIDA repository and setting the environment variable automatically at startup. After this change, FLASHIda works out of the box with no external configuration — the same way the DLLs in `FlashIDA/dll/` already work.

## Design

### Delivery: Commit share tree to the repo

Copy the `OpenMS/share/OpenMS/` directory into `FlashIDA/share/OpenMS/`, excluding the `examples/` subdirectory (136 MB of sample data not used at runtime).

**Included subdirectories (~59 MB):**

| Directory | Size | Purpose |
|-----------|------|---------|
| `CHEMISTRY/` | 53 MB | Unimod, PSI-MOD, XLMOD databases — required by FLASHExtender/Tagger |
| `CV/` | 4.1 MB | PSI-MS controlled vocabulary |
| `MAPPING/` | 104 KB | File format mappings |
| `SCHEMAS/` | 1.6 MB | XML schemas |
| `SCRIPTS/` | 76 KB | Utility scripts |
| `NUXL/` | 56 KB | Cross-linking data |
| `XSL/` | 48 KB | XSL transforms |
| `TOOLS/` | 124 KB | Tool metadata |
| `DESKTOP/` | 24 KB | Desktop integration files |
| `GUISTYLE/` | 8 KB | GUI style sheets |
| `THIRDPARTY/` | 8 KB | Third-party tool metadata |

### MSBuild integration

Add `<Content>` items in `Flash.csproj` that copy the share tree to `share/OpenMS/` in the output directory, preserving the subdirectory structure. This mirrors the existing DLL delivery pattern:

```xml
<ItemGroup>
  <Content Include="..\..\share\OpenMS\**\*">
    <Link>share\OpenMS\%(RecursiveDir)%(Filename)%(Extension)</Link>
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
</ItemGroup>
```

The wildcard `**\*` captures the entire tree. `%(RecursiveDir)` preserves the directory structure under `share/OpenMS/` in the output. The `<Link>` element places files under `share/OpenMS/` relative to the output directory.

### Resolution: Set env var in FLASHIdaWrapper constructor

In `FLASHIdaWrapper.cs`, set `OPENMS_DATA_PATH` before the `CreateFLASHIda()` P/Invoke call:

```csharp
public FLASHIdaWrapper(MethodParameters mp)
{
    string sharePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "share", "OpenMS");
    Environment.SetEnvironmentVariable("OPENMS_DATA_PATH", sharePath);

    string arg = mp.IDA.ToJSON(mp);
    m_pNativeObject = CreateFLASHIda(arg);
}
```

`AppDomain.CurrentDomain.BaseDirectory` resolves to the directory containing `Flash.exe`, which is where MSBuild places the `share/OpenMS/` tree. This works regardless of the current working directory.

The env var is set on every construction. This is harmless — it's a process-level variable, and the value is always the same within a process.

### Entry points covered

Both entry points go through the `FLASHIdaWrapper` constructor:

| Entry point | Call site | Path |
|-------------|-----------|------|
| Instrument mode | `Flash.cs:288` | `new FLASHIdaWrapper(methodParams)` |
| Test mode | `FLASHIdaWrapper.Main():424` | `new FLASHIdaWrapper(methodParams)` |

No other code path calls `CreateFLASHIda()`.

### Output directory layout

After build:

```
bin/
├── Flash.exe
├── OpenMS.dll
├── OpenSwathAlgo.dll
├── Qt6Core.dll
├── Qt6Network.dll
├── zlib.dll
├── method.xml
└── share/
    └── OpenMS/
        ├── CHEMISTRY/
        │   ├── unimod.xml
        │   ├── custom_mods.xml
        │   ├── PSI-MOD.obo
        │   └── XLMOD.obo
        ├── CV/
        ├── MAPPING/
        ├── SCHEMAS/
        └── ...
```

## What does NOT change

- No C++ changes. No DLL rebuild.
- `FLASHIdaBridgeFunctions.cpp` unchanged.
- `OpenMS/src/openms/source/SYSTEM/File.cpp` unchanged — the existing `OPENMS_DATA_PATH` env var resolution path is used as-is.
- The env var override still works: if a user explicitly sets `OPENMS_DATA_PATH` before launching Flash.exe, it will be overwritten by the constructor. This is intentional — the bundled data should always be used to avoid version mismatches.
- `Flash.Tests.csproj` does not need changes — tests inherit the share tree from the shared `bin/` output directory.

## Files to modify

| File | Change |
|------|--------|
| `FlashIDA/share/OpenMS/` | New directory: copy from `OpenMS/share/OpenMS/` excluding `examples/` |
| `FlashIDA/src/Flash/Flash.csproj` | Add `<Content>` items for share tree |
| `FlashIDA/src/Flash/IDA/FLASHIdaWrapper.cs` | Set `OPENMS_DATA_PATH` in constructor |
| `FlashIDA/Installation.md` | Remove manual `OPENMS_DATA_PATH` setup instructions |

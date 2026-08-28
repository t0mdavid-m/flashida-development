# escape=`
# ===========================================================================
# FLASHIda local CI -- the Windows lane.
#
# Toolchain ONLY. Nothing repository-specific, nothing licensed and nothing
# machine-specific is baked into this image:
#
#   * the workspace arrives at run time as a bind mount at C:\repo;
#   * the Thermo iAPI DLLs are NEVER in a layer -- they are decrypted on the
#     HOST into FlashIDA\dependencies\ and arrive through that same bind mount
#     (or are decrypted at run time from THERMO_DLL_PASSPHRASE passed by
#     environment, which is read once and never echoed);
#   * THERMO_DLL_PASSPHRASE is never an ARG and never an ENV in this file.
#     A Dockerfile ARG stays visible in `docker history` forever; that is why
#     the design doc forbids it.
#
# THEREFORE: THIS IMAGE MUST NEVER BE PUSHED TO A REGISTRY. It is tagged with
# a bare local name (no registry prefix) so `docker push` fails by default.
# There is no technical enforcement beyond that -- it is a rule, stated here
# and in docker/README.md.
#
# WHAT THIS LANE IS AUTHORITATIVE FOR (design doc section 1):
#   "does it compile under MSVC"                  -> strong, NOT authoritative
#                                                    (CI is; see WITH_GUI below)
#   "does the C#<->C++ P/Invoke round-trip work"  -> authoritative LOCALLY
#   "does the C++ logic behave"                   -> strong
#   "is this float value right"                   -> strong. CI is authoritative.
#   "may this golden be committed"                -> may CAPTURE, never PROMOTE.
#                                                    CI must confirm afterwards.
#
# ---------------------------------------------------------------------------
# BUILD -- the context is docker/windows/, NOT the repo root (~1.6 GB). The
# only COPY is entrypoint.ps1, so the context transfer is two small files.
#
# The Qt pins below are PARSED OUT OF .github/workflows/flashida-ci.yml, never
# copied: the caller runs docker/ci-lists.sh and passes the parsed values as
# build args. This file also carries the same pins as literals, and the build
# FAILS if the two disagree -- that is the whole point (same rule as the test
# lists: never duplicate a value that can rot; assert instead).
#
#   docker build -f docker/windows/Dockerfile -t flashida-win:<tag> `
#     --build-arg CI_QT_VERSION=6.8.3 `
#     --build-arg CI_QT_ARCH=win64_msvc2022_64 `
#     --build-arg "CI_QT_ARCHIVES=qtsvg qtimageformats qtbase" `
#     docker/windows
#
# The three CI_* args have NO DEFAULT. Omitting one fails the build with a
# message naming docker/ci-lists.sh -- fail-closed, never a silent skip.
#
# ---------------------------------------------------------------------------
# RUN -- ONE long-lived container driven by `docker exec`, so ccache and
# scratch survive between legs (design doc section 4):
#
#   docker run -d --name flashida-win `
#     --isolation=<process|hyperv> --memory 24g --cpus 20 `
#     -v <repo>:C:\repo `
#     -v flashida-ccache-msvc:C:\ccache `
#     flashida-win:<tag>
#
#   docker exec flashida-win powershell -NoProfile -ExecutionPolicy Bypass `
#     -File C:\flci\entrypoint.ps1 -Command cs
#
# The repo bind is READ-WRITE and must be: the C# leg legitimately writes
# bin\, obj\, src\packages\, dependencies\, test-output\ and dll\, and every
# one of those has to reach the host for review. The golden tree
# (FlashIDA\test-data\golden) SHOULD additionally be mounted :ro by the
# caller -- that is design doc section 7 layer L2, an optimisation whose
# behaviour on a subdirectory of an rw Windows bind is UNPROVEN. The
# guarantee is L1 (this image never sets LOG_GOLDEN_CAPTURE, and the
# entrypoint refuses to run if it is set) plus L4 (the entrypoint's
# unconditional `git status` assertion over FlashIDA\test-data, no bypass).
#
# <repo> is resolved by the caller from its own location. No absolute host
# path appears anywhere in this file.
# ===========================================================================

# --- Base ------------------------------------------------------------------
# Pin the DATED tag. Rejected alternatives and why (design doc section 4):
#   floating :4.8      -> now resolves only to ltsc2016/ltsc2019, and process
#                         isolation is unsupported for those on Windows 11.
#   :4.8.1-*           -> ships VS 18 BuildTools and only the 4.8.1 targeting
#                         pack; both csprojs pin v4.8.
#   plain servercore   -> saves 1.98 GiB, costs MSBuild + NuGet + net48 + the
#                         .NET runtime.
# Measured: 3.76 GiB compressed / 8.98 GiB uncompressed across 9 layers. It
# already carries VS 2022 BuildTools, Microsoft.Net.Component.4.8.SDK and
# NuGet, and it bootstraps from aka.ms/vs/17/release -- the channel we want.
ARG BASE_IMAGE=mcr.microsoft.com/dotnet/framework/sdk:4.8-20250909-windowsservercore-ltsc2022
FROM ${BASE_IMAGE}

# --- Pins parsed out of flashida-ci.yml (REQUIRED, no defaults) -------------
ARG CI_QT_VERSION
ARG CI_QT_ARCH
ARG CI_QT_ARCHIVES

# --- Pins the yml does NOT carry -------------------------------------------
# CI resolves these from floating channels, so there is nothing to parse:
#   * the contrib download is `gh release download -R OpenMS/contrib` with NO
#     tag, i.e. "latest at run time". We pin the tag the design doc verified
#     (149,253,674 B, anonymous) so the local build is reproducible.
#   * the VC toolset and Windows SDK component ids come from
#     aka.ms/vs/17/release, which currently returns 17.14.39 == the version
#     CI's runner used. The image records what it ACTUALLY installed and the
#     entrypoint WARNS LOUDLY (does not fail) when cl.exe disagrees with the
#     recorded CI value -- failing here would break the image every time
#     Microsoft moves the channel, which is not a FLASHIda regression.
ARG CONTRIB_TAG=2026-03-25-183345
ARG CONTRIB_BYTES=149253674
ARG VC_TOOLSET_COMPONENT=Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64
ARG WINSDK_COMPONENT=Microsoft.VisualStudio.Component.Windows11SDK.26100
ARG EXPECT_VS_BUILD_VERSION=17.14.39
ARG EXPECT_MSVC_VERSION=14.44.35207
ARG EXPECT_WINSDK_VERSION=10.0.26100.0

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# ---------------------------------------------------------------------------
# 0. The pin gate. The FLCI_* literals below are this file's copy of the yml
#    values; the CI_* build args are what docker/ci-lists.sh parsed out of the
#    yml. Disagreement FAILS THE IMAGE BUILD, so a stale Dockerfile pin can
#    never silently produce a differently-toolchained OpenMS.dll.
#
#    FLCI_QT_ARCHIVES_YML is the yml's literal three-name string. What we
#    actually hand aqt is TWO names, deliberately: qtimageformats is a Qt
#    MODULE, not an aqt ARCHIVE, and aqt's filter silently drops unknown
#    archive names -- so CI has been installing qtbase+qtsvg all along. We
#    reproduce CI's EFFECTIVE behaviour and assert the AUTHORED pin. Harmless
#    either way: OpenMS_QT_COMPONENTS is `Core Network`.
# ---------------------------------------------------------------------------
ENV FLCI_QT_VERSION=6.8.3 `
    FLCI_QT_ARCH=win64_msvc2022_64 `
    FLCI_QT_ARCHIVES_YML="qtsvg qtimageformats qtbase" `
    FLCI_QT_ARCHIVES_EFFECTIVE="qtbase qtsvg" `
    FLCI_STATE_DIR=C:\flci

RUN New-Item -ItemType Directory -Force -Path $env:FLCI_STATE_DIR | Out-Null; `
    $pairs = @( `
      @{ n = 'CI_QT_VERSION';  got = $env:CI_QT_VERSION;  want = $env:FLCI_QT_VERSION }, `
      @{ n = 'CI_QT_ARCH';     got = $env:CI_QT_ARCH;     want = $env:FLCI_QT_ARCH }, `
      @{ n = 'CI_QT_ARCHIVES'; got = $env:CI_QT_ARCHIVES; want = $env:FLCI_QT_ARCHIVES_YML } `
    ); `
    $bad = 0; `
    foreach ($p in $pairs) { `
      if ([string]::IsNullOrWhiteSpace($p.got)) { `
        Write-Host ('FAIL: build arg {0} was not supplied. It is PARSED from .github/workflows/flashida-ci.yml, never typed.' -f $p.n); `
        Write-Host '      Fix: build through the dispatcher (ci / ci.ps1), which runs docker/ci-lists.sh and passes'; `
        Write-Host '           --build-arg CI_QT_VERSION=... --build-arg CI_QT_ARCH=... --build-arg CI_QT_ARCHIVES=...'; `
        $bad = 1 `
      } elseif ($p.got.Trim() -ne $p.want.Trim()) { `
        Write-Host ('FAIL: pin drift on {0}: flashida-ci.yml says [{1}], this Dockerfile says [{2}].' -f $p.n, $p.got, $p.want); `
        Write-Host '      The yml is the source of truth (it is frozen, and CI runs it). Update this Dockerfile,'; `
        Write-Host '      rebuild, and recalibrate per docker/README.md -- do not pass the pin by hand to get past this.'; `
        $bad = 1 `
      } else { `
        Write-Host ('pin ok: {0} = {1}' -f $p.n, $p.got) `
      } `
    }; `
    if ($bad -ne 0) { exit 1 }; `
    Write-Host 'Toolchain pins agree with flashida-ci.yml.'

# ---------------------------------------------------------------------------
# 1. The C++ toolchain, by MODIFYING the VS 2022 BuildTools instance the base
#    image already carries (Microsoft's own documented pattern: same verb,
#    same --installPath).
#
#    // UNTESTED, and specced with a fallback: the base image's build history
#    guts the VS Installer down to vswhere.exe and deletes the Package Cache.
#    The bootstrapper re-installs the setup engine and _Instances survives, so
#    `modify` should work; if it does not we fall back to a SECOND instance at
#    C:\BuildTools2 with the same components. Either way the layer only
#    succeeds if cl.exe exists at the end.
#
#    Exit code 3010 is SUCCESS-WITH-REBOOT and MUST be swallowed -- a
#    container cannot reboot and the components are already on disk.
# ---------------------------------------------------------------------------
# (VC_TOOLSET_COMPONENT / WINSDK_COMPONENT are declared once, after FROM, and
# stay in scope for the whole stage. Re-declaring an ARG without a default
# RESETS it to empty -- do not "helpfully" repeat them here.)
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'; `
    $inst = ''; `
    if (Test-Path $vswhere) { $inst = @(& $vswhere -products * -latest -property installationPath)[0] }; `
    if ([string]::IsNullOrWhiteSpace($inst)) { $inst = 'C:\BuildTools' }; `
    Write-Host ('Existing VS instance: {0}' -f $inst); `
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile "$env:TEMP\vs_BuildTools.exe"; `
    $common = @('--quiet', '--wait', '--norestart', '--nocache', `
                '--add', 'Microsoft.VisualStudio.Workload.VCTools', `
                '--add', $env:VC_TOOLSET_COMPONENT, `
                '--add', $env:WINSDK_COMPONENT); `
    $p = Start-Process -FilePath "$env:TEMP\vs_BuildTools.exe" -ArgumentList (@('modify', '--installPath', $inst) + $common) -Wait -PassThru -NoNewWindow; `
    Write-Host ('vs_BuildTools modify exit={0}' -f $p.ExitCode); `
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { `
      Write-Host 'modify-in-place failed; falling back to a second instance at C:\BuildTools2'; `
      $inst = 'C:\BuildTools2'; `
      $p2 = Start-Process -FilePath "$env:TEMP\vs_BuildTools.exe" -ArgumentList (@('install', '--installPath', $inst) + $common) -Wait -PassThru -NoNewWindow; `
      Write-Host ('vs_BuildTools install exit={0}' -f $p2.ExitCode); `
      if ($p2.ExitCode -ne 0 -and $p2.ExitCode -ne 3010) { Write-Host 'FAIL: could not install the VC toolchain (neither modify nor a second instance).'; exit 1 } `
    }; `
    $vcvars = Join-Path $inst 'VC\Auxiliary\Build\vcvars64.bat'; `
    if (-not (Test-Path $vcvars)) { Write-Host ('FAIL: vcvars64.bat missing at {0} - the VC toolchain did not land.' -f $vcvars); exit 1 }; `
    $msvcRoot = Join-Path $inst 'VC\Tools\MSVC'; `
    $toolset = (Get-ChildItem $msvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name; `
    $cl = Join-Path $msvcRoot ('{0}\bin\Hostx64\x64\cl.exe' -f $toolset); `
    if (-not (Test-Path $cl)) { Write-Host ('FAIL: cl.exe missing at {0}' -f $cl); exit 1 }; `
    $sdkInc = 'C:\Program Files (x86)\Windows Kits\10\Include'; `
    $sdk = ''; `
    if (Test-Path $sdkInc) { $sdk = (Get-ChildItem $sdkInc -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name }; `
    if ([string]::IsNullOrWhiteSpace($sdk)) { Write-Host 'FAIL: no Windows SDK under Windows Kits\10\Include'; exit 1 }; `
    $vsver = ''; `
    if (Test-Path $vswhere) { $vsver = @(& $vswhere -products * -latest -property catalog_productDisplayVersion)[0] }; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'vs-install-path.txt') -Value $inst; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'vs-build-version.txt') -Value $vsver; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'msvc-toolset.txt') -Value $toolset; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'winsdk-version.txt') -Value $sdk; `
    Write-Host ('VS {0} / MSVC toolset {1} / Windows SDK {2}' -f $vsver, $toolset, $sdk); `
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 2. The VC++ redistributable, UNCONDITIONALLY.
#    A real PE import-table walk of the shipped binaries shows:
#      OpenMS.dll  load-time-imports MSVCP140.dll, VCOMP140.DLL,
#                                    VCRUNTIME140.dll, VCRUNTIME140_1.dll
#      Qt6Core.dll adds              MSVCP140_1.dll
#    Missing one of these is 0xc0000135 STATUS_DLL_NOT_FOUND at the first
#    P/Invoke, hours into a run. Assert them here so it fails the IMAGE BUILD.
# ---------------------------------------------------------------------------
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile "$env:TEMP\vc_redist.x64.exe"; `
    $p = Start-Process -FilePath "$env:TEMP\vc_redist.x64.exe" -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru -NoNewWindow; `
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1638) { Write-Host ('FAIL: vc_redist.x64.exe exit={0}' -f $p.ExitCode); exit 1 }; `
    $need = @('msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll'); `
    $missing = @(); `
    foreach ($d in $need) { if (-not (Test-Path (Join-Path $env:SystemRoot ('System32\{0}' -f $d)))) { $missing += $d } }; `
    if ($missing.Count -gt 0) { `
      Write-Host ('FAIL: VC++ runtime DLLs absent from System32: {0}' -f ($missing -join ', ')); `
      Write-Host '      OpenMS.dll and Qt6Core.dll load-time-import these; without them every P/Invoke is 0xc0000135.'; `
      exit 1 `
    }; `
    Write-Host ('VC++ runtime present: {0}' -f ($need -join ', ')); `
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 3. Chocolatey + the build tools CI installs, plus two additions.
#
#    CI's list:  ninja cmake ccache 7zip eigen
#    added:      python312  -- NOT optional: regression-runner.ps1:203 shells
#                              out to a bare `python` for compare_golden.py
#                              (stdlib only). Absent -> all 14 regression
#                              cases fail.
#    added:      git        -- NOT optional. Three entrypoint requirements
#                              from the design doc need it, and CI needs none
#                              of them only because a runner is one-shot from
#                              a fresh checkout:
#                                (a) provenance gate check (b) is
#                                    `git -C FlashIDA show HEAD:dll/OpenMS.dll`;
#                                (b) the finally block restores FlashIDA\dll\
#                                    with `git checkout --` and asserts
#                                    `status --porcelain` empty;
#                                (c) it supplies sh.exe + gawk so the
#                                    entrypoint can RUN docker/ci-lists.sh
#                                    rather than grow a second parser.
# ---------------------------------------------------------------------------
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')); `
    & C:\ProgramData\chocolatey\bin\choco.exe install ninja cmake ccache 7zip eigen python312 git -y --no-progress --limit-output; `
    if ($LASTEXITCODE -ne 0) { Write-Host ('FAIL: choco install exit={0}' -f $LASTEXITCODE); exit 1 }; `
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue

# The repo arrives as a bind mount owned by a different account than the
# container user, which git 2.35+ refuses with "detected dubious ownership".
# This container is a disposable local build box, so a blanket exemption is
# the right scope. Without it every git call in the entrypoint fails.
RUN & 'C:\Program Files\Git\cmd\git.exe' config --system --add safe.directory '*'; `
    & 'C:\Program Files\Git\cmd\git.exe' config --system core.longpaths true

# ---------------------------------------------------------------------------
# 4. Qt, via aqt, at the version parsed out of the yml.
#    --archives is the EFFECTIVE two-name set (see the pin gate above).
# ---------------------------------------------------------------------------
RUN $py = 'C:\Python312\python.exe'; `
    if (-not (Test-Path $py)) { $c = Get-Command python.exe -ErrorAction SilentlyContinue; if ($c) { $py = $c.Source } }; `
    if (-not (Test-Path $py)) { Write-Host 'FAIL: python not found after choco install python312'; exit 1 }; `
    & $py -m pip install --no-cache-dir --upgrade pip aqtinstall; `
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL: pip install aqtinstall'; exit 1 }; `
    $archives = $env:FLCI_QT_ARCHIVES_EFFECTIVE.Split(' '); `
    & $py -m aqt install-qt windows desktop $env:FLCI_QT_VERSION $env:FLCI_QT_ARCH --archives $archives -O C:\Qt; `
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL: aqt install-qt'; exit 1 }; `
    $qtroot = ('C:\Qt\{0}\msvc2022_64' -f $env:FLCI_QT_VERSION); `
    foreach ($f in @('bin\Qt6Core.dll', 'bin\Qt6Network.dll', 'lib\cmake\Qt6\Qt6Config.cmake')) { `
      if (-not (Test-Path (Join-Path $qtroot $f))) { Write-Host ('FAIL: Qt payload incomplete, missing {0}\{1}' -f $qtroot, $f); exit 1 } `
    }; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'qt-root.txt') -Value $qtroot; `
    Write-Host ('Qt {0} at {1}' -f $env:FLCI_QT_VERSION, $qtroot); `
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue

ENV QT_ROOT_DIR=C:\Qt\6.8.3\msvc2022_64

# ---------------------------------------------------------------------------
# 5. The prebuilt contrib tarball, extracted to C:\contrib.
#
#    NEVER into OpenMS\contrib: that is a nested submodule, populated with
#    SOURCE on a local clone, and CI deliberately checks out `submodules:
#    true` (not recursive) so it stays empty for the tarball. Extracting over
#    a populated source tree can break find_package(XercesC/Boost/...).
#
#    Downloaded ANONYMOUSLY -- no GITHUB_TOKEN, because a token is not
#    portable to another dev machine (design doc D5). The byte count is
#    asserted: a re-uploaded asset must fail the build loudly, never silently
#    change the toolchain underneath the goldens.
#
#    The two-stage 7z pipe runs through cmd.exe on purpose: a PowerShell
#    pipeline is a text/object stream and corrupts binary data.
# ---------------------------------------------------------------------------
RUN $url = ('https://github.com/OpenMS/contrib/releases/download/{0}/contrib_build-Windows.tar.gz' -f $env:CONTRIB_TAG); `
    Write-Host ('Downloading contrib from {0}' -f $url); `
    & curl.exe -fsSL --retry 3 -o C:\contrib.tar.gz $url; `
    if ($LASTEXITCODE -ne 0) { Write-Host ('FAIL: contrib download failed (curl exit {0}) from {1}' -f $LASTEXITCODE, $url); exit 1 }; `
    $len = (Get-Item C:\contrib.tar.gz).Length; `
    $want = [int64]$env:CONTRIB_BYTES; `
    if ($len -ne $want) { `
      Write-Host ('FAIL: contrib_build-Windows.tar.gz is {0} B, pinned at {1} B for tag {2}.' -f $len, $want, $env:CONTRIB_TAG); `
      Write-Host '      The release asset moved. Re-pin CONTRIB_TAG/CONTRIB_BYTES here and RECALIBRATE against a'; `
      Write-Host '      green CI run (docker/README.md) before capturing any golden with the new toolchain.'; `
      exit 1 `
    }; `
    $sha = (Get-FileHash C:\contrib.tar.gz -Algorithm SHA256).Hash.ToLower(); `
    New-Item -ItemType Directory -Force -Path C:\contrib | Out-Null; `
    Set-Content -Encoding ascii -Path C:\extract-contrib.cmd -Value @( `
      '@echo off', `
      '"C:\Program Files\7-Zip\7z.exe" x -so C:\contrib.tar.gz | "C:\Program Files\7-Zip\7z.exe" x -si -ttar -oC:\contrib -y > nul', `
      'exit /b %ERRORLEVEL%' `
    ); `
    & cmd.exe /c C:\extract-contrib.cmd; `
    if ($LASTEXITCODE -ne 0) { Write-Host ('FAIL: contrib extraction exit={0}' -f $LASTEXITCODE); exit 1 }; `
    Remove-Item C:\extract-contrib.cmd -Force; `
    if (-not (Test-Path C:\contrib\include)) { Write-Host 'FAIL: C:\contrib\include missing after extraction - unexpected tarball layout.'; exit 1 }; `
    Remove-Item C:\contrib.tar.gz -Force; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'contrib-tag.txt') -Value $env:CONTRIB_TAG; `
    Set-Content -Encoding ascii -Path (Join-Path $env:FLCI_STATE_DIR 'contrib-sha256.txt') -Value $sha; `
    Write-Host ('contrib {0} sha256={1} -> C:\contrib' -f $env:CONTRIB_TAG, $sha); `
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 6. LOCALE PIN -- rated HIGH risk in the design doc, and invisible when wrong.
#
#    Mocks\MockMsScan.cs parses every spectrum fixture value with a BARE
#    culture-sensitive double.Parse (:265, :274, :275, :338, :354, :355), and
#    FromTsv / FromTsvAsMS2 / FromTsvAsMSn feed the WHOLE golden and
#    continuity suite. Under de-DE -- this workspace's host locale --
#    double.Parse("674.6919") returns 6746919: every m/z off by 10^4, with no
#    exception anywhere. ScanFactoryCultureTests is NOT a canary for this; it
#    asserts its own [SetCulture] premise.
#
#    Set-Culture is not guaranteed present on Server Core, so the registry is
#    written directly (that is what GetUserDefaultLocaleName, and therefore
#    CultureInfo.CurrentCulture, actually reads) and Set-Culture is used as
#    belt-and-braces when available. A FRESH powershell process must then
#    agree, and 674.6919 must round-trip -- the BEHAVIOURAL check, not just
#    the name check. The entrypoint re-asserts both before running anything.
# ---------------------------------------------------------------------------
RUN $intl = 'HKCU:\Control Panel\International'; `
    Set-ItemProperty -Path $intl -Name 'LocaleName' -Value 'en-US'; `
    Set-ItemProperty -Path $intl -Name 'Locale'     -Value '00000409'; `
    Set-ItemProperty -Path $intl -Name 'sDecimal'   -Value '.'; `
    Set-ItemProperty -Path $intl -Name 'sThousand'  -Value ','; `
    Set-ItemProperty -Path $intl -Name 'sList'      -Value ','; `
    Set-ItemProperty -Path $intl -Name 'sShortDate' -Value 'M/d/yyyy'; `
    if (Get-Command Set-Culture -ErrorAction SilentlyContinue) { Set-Culture en-US }; `
    $probe = & powershell.exe -NoProfile -Command "[string]::Join('|',(Get-Culture).Name,[double]::Parse('674.6919').ToString([Globalization.CultureInfo]::InvariantCulture))"; `
    Write-Host ('locale probe: {0}' -f $probe); `
    if ($probe -ne 'en-US|674.6919') { `
      Write-Host 'FAIL: the container culture is not en-US, or double.Parse does not round-trip 674.6919.'; `
      Write-Host '      MockMsScan parses every fixture value with a bare double.Parse; a non-en-US container'; `
      Write-Host '      silently multiplies every m/z by 10^4 and the whole golden suite becomes meaningless.'; `
      exit 1 `
    }; `
    Write-Host 'Container culture pinned to en-US and verified behaviourally.'

# ---------------------------------------------------------------------------
# 7. Resolve every tool ONCE, by absolute path, into C:\flci\tool-paths.json,
#    and record the measured pins into C:\flci\pins.json. The entrypoint reads
#    both and fails closed on any missing key, so a PATH accident can never
#    become "silently used a different msbuild".
# ---------------------------------------------------------------------------
# BASE_IMAGE is declared BEFORE the FROM, i.e. outside the build stage, so it
# must be re-declared (with no default) to become visible inside it. That form
# INHERITS the pre-FROM value. Every other ARG here was already declared after
# the FROM and must NOT be repeated.
ARG BASE_IMAGE
RUN $state = $env:FLCI_STATE_DIR; `
    $inst = (Get-Content (Join-Path $state 'vs-install-path.txt') -Raw).Trim(); `
    $toolset = (Get-Content (Join-Path $state 'msvc-toolset.txt') -Raw).Trim(); `
    $qtroot = (Get-Content (Join-Path $state 'qt-root.txt') -Raw).Trim(); `
    $nugetCmd = Get-Command nuget.exe -ErrorAction SilentlyContinue; `
    $nuget = ''; `
    if ($nugetCmd) { $nuget = $nugetCmd.Source } `
    else { `
      $hit = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData' -Filter nuget.exe -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 1; `
      if ($hit) { $nuget = $hit.FullName } `
    }; `
    if ([string]::IsNullOrWhiteSpace($nuget)) { `
      Write-Host 'nuget.exe not found in the base image; fetching the official CLI (CI restores with `nuget restore`, so msbuild -t:restore is not a substitute).'; `
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
      Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile (Join-Path $state 'nuget.exe'); `
      $nuget = (Join-Path $state 'nuget.exe') `
    }; `
    $tools = [ordered]@{ `
      git      = 'C:\Program Files\Git\cmd\git.exe'; `
      sh       = 'C:\Program Files\Git\bin\sh.exe'; `
      awk      = 'C:\Program Files\Git\usr\bin\awk.exe'; `
      python   = 'C:\Python312\python.exe'; `
      cmake    = 'C:\Program Files\CMake\bin\cmake.exe'; `
      ctest    = 'C:\Program Files\CMake\bin\ctest.exe'; `
      ninja    = 'C:\ProgramData\chocolatey\bin\ninja.exe'; `
      ccache   = 'C:\ProgramData\chocolatey\bin\ccache.exe'; `
      sevenzip = 'C:\Program Files\7-Zip\7z.exe'; `
      msbuild  = (Join-Path $inst 'MSBuild\Current\Bin\MSBuild.exe'); `
      vcvars64 = (Join-Path $inst 'VC\Auxiliary\Build\vcvars64.bat'); `
      cl       = (Join-Path $inst ('VC\Tools\MSVC\{0}\bin\Hostx64\x64\cl.exe' -f $toolset)); `
      nuget    = $nuget; `
      qtroot   = $qtroot; `
      contrib  = 'C:\contrib'; `
      eigen    = 'C:\ProgramData\chocolatey\lib\eigen\share\cmake' `
    }; `
    $missing = @(); `
    foreach ($k in $tools.Keys) { if ([string]::IsNullOrWhiteSpace([string]$tools[$k]) -or -not (Test-Path ([string]$tools[$k]))) { $missing += ('{0}=[{1}]' -f $k, $tools[$k]) } }; `
    if ($missing.Count -gt 0) { Write-Host ('FAIL: unresolved tool paths: {0}' -f ($missing -join '; ')); exit 1 }; `
    ($tools | ConvertTo-Json) | Set-Content -Encoding ascii -Path (Join-Path $state 'tool-paths.json'); `
    Get-Content (Join-Path $state 'tool-paths.json'); `
    $pins = [ordered]@{ `
      qt_version      = $env:FLCI_QT_VERSION; `
      qt_arch         = $env:FLCI_QT_ARCH; `
      qt_archives_yml = $env:FLCI_QT_ARCHIVES_YML; `
      qt_archives_eff = $env:FLCI_QT_ARCHIVES_EFFECTIVE; `
      contrib_tag     = (Get-Content (Join-Path $state 'contrib-tag.txt') -Raw).Trim(); `
      contrib_sha256  = (Get-Content (Join-Path $state 'contrib-sha256.txt') -Raw).Trim(); `
      vs_build        = (Get-Content (Join-Path $state 'vs-build-version.txt') -Raw).Trim(); `
      msvc_toolset    = $toolset; `
      winsdk          = (Get-Content (Join-Path $state 'winsdk-version.txt') -Raw).Trim(); `
      expect_vs_build = $env:EXPECT_VS_BUILD_VERSION; `
      expect_msvc     = $env:EXPECT_MSVC_VERSION; `
      expect_winsdk   = $env:EXPECT_WINSDK_VERSION; `
      base_image      = $env:BASE_IMAGE `
    }; `
    ($pins | ConvertTo-Json) | Set-Content -Encoding ascii -Path (Join-Path $state 'pins.json'); `
    Get-Content (Join-Path $state 'pins.json')

# PATH here is a convenience for interactive `docker exec` only. Nothing in a
# run depends on it: the entrypoint resolves every tool from tool-paths.json.
ENV FLCI_EXTRA_PATH="C:\Python312;C:\Python312\Scripts;C:\ProgramData\chocolatey\bin;C:\Program Files\CMake\bin;C:\Program Files\Git\cmd;C:\Program Files\Git\usr\bin;C:\Program Files\7-Zip" `
    CCACHE_DIR=C:\ccache `
    CCACHE_MAXSIZE=30G `
    CCACHE_COMPILERCHECK=content `
    CCACHE_SLOPPINESS=time_macros,include_file_ctime,include_file_mtime

# Copied for the same reason the Linux lane copies its entrypoint: the image
# is then self-contained. During entrypoint development you may instead exec
# C:\repo\docker\windows\entrypoint.ps1 from the bind mount -- the script
# prints which path it ran from on every invocation, so the two can never be
# silently confused.
COPY entrypoint.ps1 C:/flci/entrypoint.ps1

LABEL org.opencontainers.image.title="flashida-win" `
      org.opencontainers.image.description="MSVC/Qt/contrib lane for FLASHIda local CI: builds OpenMS.dll, swaps it into FlashIDA/dll, runs the C# suite, the regression runner and the four gates. Toolchain only - no source, no Thermo DLLs, no secrets." `
      flashida.lane="windows" `
      flashida.never-push="true - local-only by policy, see docker/README.md" `
      flashida.authoritative-for="C# to C++ P/Invoke round-trip, locally" `
      flashida.never="golden PROMOTION; the final MSVC verdict; float adjudication" `
      flashida.divergence-from-ci="WITH_GUI=OFF (CI configures ON) - see docker/README.md" `
      vs.buildversion="17.14.39" `
      vctools="Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64" `
      msvc="14.44.35207" `
      winsdk="10.0.26100.0" `
      contrib.tag="2026-03-25-183345" `
      qt="6.8.3 win64_msvc2022_64"

WORKDIR C:/repo

# Keep the container alive so `docker exec` can drive it (the design doc's
# one-long-lived-container run model). The entrypoint is deliberately NOT the
# CMD: every leg is an explicit exec, so a container that is merely up has
# done nothing and cannot be mistaken for a run.
CMD ["ping", "-t", "localhost"]

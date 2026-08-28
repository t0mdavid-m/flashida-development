<#
===========================================================================
 FLASHIda local CI -- the Windows lane entrypoint.

 This is CI's `windows-tests` job, step for step, in CI's order, with CI's
 per-step env:, plus the assertions CI never needed because a GitHub runner
 is a fresh checkout on a one-shot filesystem and this container is neither.

 RUN MODEL: one long-lived container, driven by `docker exec`:

   docker exec flashida-win powershell -NoProfile -ExecutionPolicy Bypass `
       -File C:\flci\entrypoint.ps1 -Command cs

 COMMANDS
   -Command doctor          container-side half of `ci doctor`: pins, tools,
                            locale, the Thermo DLL identity gate, ccache, and
                            the git status of both submodules.
   -Command dll             configure+build OpenMS.dll, swap 4 DLLs into
                            FlashIDA\dll, verify the swap.
   -Command cs              dll + nuget + msbuild(Debug|Any CPU) + the
                            provenance gate + the UNFILTERED NUnit suite +
                            all four gates + the regression runner + cleanup.
   -Command cs -Filter ...  filtered NUnit. Always PARTIAL, always non-zero.
   -Command golden-capture  cs, plus the log-golden / continuity / regression
                            staging inventory, staged OUTSIDE the golden tree.
   -Command cpp -Target a,b targeted MSVC ctest triage. There is deliberately
                            no full MSVC ctest run here (design doc section
                            10): the full set is the Linux lane's job and
                            CI's, on the toolchain CI is authoritative for.

 THE TEST LIST IS PARSED, NEVER COPIED. Every target name comes from
 `docker/ci-lists.sh targets`, which reads .github/workflows/flashida-ci.yml.
 If that produces fewer than -MinTargets names this script FAILS rather than
 substituting a literal list. Note the parser's own mawk self-test
 (`ci lists`) needs the LINUX container and is therefore the host
 dispatcher's step 1, not this script's -- here the list is merely consumed.

 THE EXIT-CODE AND VERDICT CONTRACT (design doc section 6), which this script
 implements for the Windows lane:
   * the LAST LINE is exactly one of
        PASS: <what was verified>
        FAIL: <first failing gate>
        PARTIAL: <what did not run> - NOT CI-EQUIVALENT
   * exit 0 = PASS, 1 = FAIL, 2 = PARTIAL. PARTIAL is ALWAYS non-zero.
   * there is no `|| true` anywhere, and no flag that disables a gate.
   A human reading only the last line is never misled.

 THINGS THIS SCRIPT WILL NOT DO, and why:
   * It never sets LOG_GOLDEN_CAPTURE. That is design doc section 7 layer L1
     and it is the mechanical guarantee that no container run can write into
     FlashIDA\test-data\golden: FLASHIdaLogGolden_test writes every
     <stream>.normalized UNCONDITIONALLY from the same string CaptureGolden
     would write, so a FAILING comparison run already IS the capture and
     promotion is a pure rename. If LOG_GOLDEN_CAPTURE arrives in the
     environment this script REFUSES TO RUN.
   * It never promotes a golden. Promotion is a bare host-side `cp` reviewed
     by a human (section 7 L3); a wrapper is the one command shape the repo's
     golden-write guard does not gate.
   * It never prints THERMO_DLL_PASSPHRASE, never passes it on a command
     line, and never writes it to disk.
   * It never edits anything under OpenMS\src or FlashIDA\src.

 WHAT THIS LANE IS NOT AUTHORITATIVE FOR: the final MSVC verdict, any float
 value, and any golden. It verifies YOUR WORKING TREE, dirty; CI verifies a
 COMMIT from a clean recursive checkout. "Green container" is never "green at
 this SHA". See docker/README.md.
===========================================================================
#>

param(
    [ValidateSet('doctor', 'dll', 'cs', 'cpp', 'golden-capture')]
    [string]$Command = 'doctor',

    # Container path of the bind-mounted workspace. Never a host path.
    [string]$Repo = 'C:\repo',

    # C++ build configuration. Release is the default because it is what CI
    # builds and therefore what the goldens were produced by.
    [ValidateSet('Release', 'Debug')]
    [string]$CppConfig = 'Release',

    # NUnit --where expression. Any value makes the run PARTIAL.
    [string]$Filter = '',

    # ctest/target names for -Command cpp. Validated against the list parsed
    # out of flashida-ci.yml -- never against a list written here.
    [string[]]$Target = @(),

    # Skip the C++ configure+build. The provenance gate STILL RUNS and has no
    # bypass, so this can never silently test a stale engine.
    [switch]$SkipBuild,

    # Configure the C++ build with WITH_GUI=ON, matching CI exactly. Costs
    # ~6m25s and the whole Qt GUI closure. Use it once, to check a suspected
    # container-vs-CI divergence (design doc section 4).
    [switch]$WithGui,

    # Opt-in, default OFF: the REGEN_CONFIG_REFERENCE single-test run. MUST
    # come after the unfiltered suite; enforced below.
    [switch]$RegenConfigReference,

    # Where captured artefacts are staged. NEVER the golden tree.
    [string]$StageDir = '',

    # Calibration expectations for the unfiltered suite (design doc section
    # 8: parent 9bcfc82, CI run 33083942633, completed success 2026-08-27).
    # A mismatch is a FAILURE, not a warning -- but the message says how to
    # move the calibration when a test is legitimately added.
    [int]$ExpectTotal = 181,
    [int]$ExpectPassed = 180,
    [int]$ExpectSkipped = 1,

    # Fail-closed floor for the parsed C++ target list (design doc section 5).
    [int]$MinTargets = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -Target normalisation. PROVEN on Windows PowerShell 5.1: an EXTERNAL invocation
# binds `-Target a,b` as ONE element "a,b" -- `-File <s> -Target a,b`, `-File <s>
# -Target 'a,b'` and `-Command "& <s> -Target 'a,b'"` ALL give Count=1, because a
# [string[]] parameter wraps a single string rather than splitting it. Both shapes
# the dispatcher uses are in that list, so without this every multi-target run dies
# as `unknown target(s): a,b` instead of running. Splitting here keeps the
# per-name, parsed-from-the-yml validation exactly as fail-closed as before.
$Target = @($Target | ForEach-Object { ([string]$_) -split '[,;\s]+' } | Where-Object { $_ -ne '' })

# ---------------------------------------------------------------------------
# Verdict plumbing
# ---------------------------------------------------------------------------
$script:ExitCode = 0
$script:Verdict = ''
$script:PartialReasons = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList
$script:StagedTo = ''

function Fail {
    param([string]$Message)
    throw $Message
}

function Add-Partial {
    param([string]$Reason)
    [void]$script:PartialReasons.Add($Reason)
}

function Add-Warning {
    param([string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-Host ('WARNING: {0}' -f $Message)
}

function Write-Step {
    param([string]$Id, [string]$Title)
    Write-Host ''
    Write-Host ('=== [{0}] {1} ' -f $Id, $Title).PadRight(78, '=')
}

# Run a native command, echo its output to the host, and return ONLY its exit
# code on the pipeline (Out-Host consumes the rest, so `[void](Invoke-Native
# ...)` does not swallow a build log).
#
# $ErrorActionPreference is dropped to Continue for the duration: in Windows
# PowerShell 5.1 a native command that writes to stderr can otherwise surface
# as a NativeCommandError and terminate the script. msbuild, cmake, choco and
# nuget all write to stderr routinely and none of that means failure -- the
# exit code does.
function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments = @(),
        [string]$What = '',
        [switch]$AllowFailure
    )
    if ([string]::IsNullOrWhiteSpace($What)) { $What = [IO.Path]::GetFileName($Exe) }
    Write-Host ('  > "{0}" {1}' -f $Exe, ($Arguments -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        # Clear it FIRST. Proven on Windows PowerShell 5.1: when the executable
        # cannot be started at all, $LASTEXITCODE keeps its PREVIOUS value, so a
        # command that never ran would otherwise report the last command's 0 and
        # a gate would pass without having executed anything.
        $global:LASTEXITCODE = $null
        & $Exe @Arguments | Out-Host
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $code) {
        Fail ('{0} never started: "{1}" could not be executed and produced no exit code. "Did not run" is not an allowed outcome of a gate.' -f $What, $Exe)
    }
    if (-not $AllowFailure -and $code -ne 0) {
        Fail ('{0} failed (exit {1})' -f $What, $code)
    }
    return $code
}

# Run a native command and CAPTURE its output (both streams) as strings. Same
# ErrorActionPreference reasoning as Invoke-Native, which is also what makes
# the 2>&1 here safe.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @()
    $code = 0
    try {
        # Same reason as Invoke-Native: a command that never starts leaves
        # $LASTEXITCODE at its previous value. 127 ("not executed") keeps every
        # caller's `Code -ne 0` test correct instead of handing it a stale 0.
        $global:LASTEXITCODE = $null
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 127 }
    }
    finally { $ErrorActionPreference = $prev }
    return (New-Object PSObject -Property @{ Lines = $lines; Code = $code })
}

function ConvertTo-UnixPath {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') { return ('/{0}/{1}' -f $matches[1].ToLower(), $matches[2]) }
    return $p
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# ---------------------------------------------------------------------------
# Pre-flight assertions. Everything here runs before any command.
# ---------------------------------------------------------------------------

function Assert-Repo {
    $required = @(
        'OpenMS\src\openms',
        'FlashIDA\src\Flash.sln',
        'FlashIDA\dll\zlib.dll',
        'FlashIDA\test-data',
        '.github\workflows\flashida-ci.yml',
        'docker\ci-lists.sh'
    )
    $missing = @()
    foreach ($r in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Repo $r))) { $missing += $r }
    }
    if ($missing.Count -gt 0) {
        Fail (
            ("{0} does not look like the FLASHIda workspace - missing: {1}. " -f $Repo, ($missing -join ', ')) +
            "Mount the repo root at C:\repo (-v <repo>:C:\repo) and check out both submodules " +
            "(git submodule update --init - NOT --recursive: OpenMS/contrib is a nested submodule this " +
            "lane does not use, because the contrib tarball lives at C:\contrib in the image)."
        )
    }
    Write-Host ('repo         : {0}' -f $Repo)
}

function Assert-Locale {
    # HIGH-risk gate. Mocks\MockMsScan.cs parses every spectrum fixture value
    # with a bare culture-sensitive double.Parse and feeds the whole golden and
    # continuity suite; under de-DE (this workspace's host locale)
    # double.Parse("674.6919") returns 6746919 and NOTHING throws. Assert both
    # the culture NAME (the design doc's requirement) and the BEHAVIOUR (the
    # thing that actually matters).
    $name = [System.Globalization.CultureInfo]::CurrentCulture.Name
    $parsed = [double]::Parse('674.6919')
    Write-Host ('culture      : {0} (double.Parse("674.6919") -> {1})' -f $name, $parsed)
    if ($name -ne 'en-US') {
        Fail (
            ("container culture is '{0}', not 'en-US'. MockMsScan parses every fixture value with a " -f $name) +
            "bare double.Parse, so a non-en-US container silently rescales every m/z and the entire " +
            "golden suite becomes meaningless. Rebuild the image (its locale layer asserts this), or " +
            "check that the container user's HKCU\Control Panel\International\LocaleName is en-US."
        )
    }
    if ([Math]::Abs($parsed - 674.6919) -gt 1e-9) {
        Fail (
            ("double.Parse('674.6919') returned {0}. The culture NAME says en-US but the numeric " -f $parsed) +
            "separators do not. Fix HKCU\Control Panel\International (sDecimal must be '.')."
        )
    }
}

function Assert-NoCaptureEnvironment {
    # Design doc section 7, layer L1. The single most important line in this
    # file: never capture, therefore never write into the golden tree.
    if (-not [string]::IsNullOrEmpty($env:LOG_GOLDEN_CAPTURE)) {
        Fail (
            "LOG_GOLDEN_CAPTURE is set in this container's environment. This lane NEVER captures log " +
            "goldens: FLASHIdaLogGolden_test already writes every <stream>.normalized unconditionally, " +
            "byte-identical to what a capture would write, so promotion is a pure rename done by a human " +
            "on the host. Unset it and re-run; use -Command golden-capture to stage the .normalized files."
        )
    }
    if (-not [string]::IsNullOrEmpty($env:REGEN_CONFIG_REFERENCE)) {
        Fail (
            "REGEN_CONFIG_REFERENCE is set in this container's environment. It rewrites the committed " +
            "FlashIDA\test-data\config_schema_reference.json in place and MUST run only after the " +
            "unfiltered suite (run first, the gate passes against its own output). Unset it; pass " +
            "-RegenConfigReference instead, which sets it for exactly one single-test invocation."
        )
    }
}

function Get-ToolPaths {
    $p = Join-Path $env:FLCI_STATE_DIR 'tool-paths.json'
    if ([string]::IsNullOrWhiteSpace($env:FLCI_STATE_DIR) -or -not (Test-Path -LiteralPath $p)) {
        Fail (
            ("{0} not found. This script must run INSIDE the flashida-win image, which writes that file " -f $p) +
            "at build time after resolving every tool by absolute path. Running it on a host, or in the " +
            "Linux container, is not supported."
        )
    }
    $t = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    # Every key the image resolved, not a subset: ninja and ccache are found by
    # CMAKE from PATH (-G Ninja, CMAKE_CXX_COMPILER_LAUNCHER=ccache) rather than
    # from this file, so their absence surfaces as a confusing configure error.
    $needed = @('git', 'sh', 'awk', 'python', 'cmake', 'ctest', 'ninja', 'ccache', 'sevenzip', 'msbuild', 'vcvars64', 'cl', 'nuget', 'qtroot', 'contrib', 'eigen')
    $missing = @()
    foreach ($k in $needed) {
        $v = $t.$k
        if ([string]::IsNullOrWhiteSpace([string]$v) -or -not (Test-Path -LiteralPath ([string]$v))) {
            $missing += ('{0}=[{1}]' -f $k, $v)
        }
    }
    if ($missing.Count -gt 0) { Fail ('tool-paths.json points at paths that do not exist: {0}. Rebuild the image.' -f ($missing -join '; ')) }
    return $t
}

function Get-Pins {
    $p = Join-Path $env:FLCI_STATE_DIR 'pins.json'
    if (-not (Test-Path -LiteralPath $p)) { Fail ('{0} not found. Rebuild the image.' -f $p) }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}

function Import-VcVars {
    param($Tools)
    # cmake needs the MSVC environment. Import it once, into this process.
    # [Environment]::SetEnvironmentVariable, not Set-Item Env:, because names
    # like ProgramFiles(x86) are not valid in an Env: provider path.
    #
    # Driven through a generated .cmd file at a space-free path, NOT through
    # `cmd /c "<quoted string>"`: Windows PowerShell 5.1 escapes embedded
    # double quotes with BACKSLASHES when it hands an argument to a native
    # executable, and cmd.exe does not understand that escape. The bat path
    # contains both spaces and parentheses, so the quoted form is exactly the
    # shape that breaks.
    $bat = $Tools.vcvars64
    $tmpDir = 'C:\flci\tmp'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $cmdFile = Join-Path $tmpDir 'vcvars-dump.cmd'
    @(
        '@echo off',
        ('call "{0}" >nul 2>&1' -f $bat),
        'if errorlevel 1 exit /b 1',
        'set'
    ) | Set-Content -LiteralPath $cmdFile -Encoding ASCII
    Write-Host ('  > "{0}" && set' -f $bat)
    $r = Invoke-Capture -Exe 'cmd.exe' -Arguments @('/c', $cmdFile)
    if ($r.Code -ne 0) { Fail ('vcvars64.bat failed (exit {0}); the VC toolchain is not usable.' -f $r.Code) }
    $lines = $r.Lines
    $n = 0
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $matches[1]
            if ($k -eq 'PROMPT' -or $k -eq '_') { continue }
            [Environment]::SetEnvironmentVariable($k, $matches[2])
            $n++
        }
    }
    Write-Host ('  imported {0} environment entries from vcvars64.bat' -f $n)
}

function Assert-ToolchainPins {
    param($Tools, $Pins)
    # The Qt version and archives were already gated at IMAGE BUILD time
    # against the values parsed out of flashida-ci.yml. What is left is the
    # pair the yml does not carry, where the design doc says: warn loudly,
    # do not fail -- CI resolves them from a floating channel, so a
    # disagreement is Microsoft moving, not a FLASHIda regression.
    Write-Host ('qt           : {0} {1} (archives authored "{2}", installed "{3}")' -f `
            $Pins.qt_version, $Pins.qt_arch, $Pins.qt_archives_yml, $Pins.qt_archives_eff)
    Write-Host ('contrib      : {0}  sha256={1}' -f $Pins.contrib_tag, $Pins.contrib_sha256)
    Write-Host ('vs           : {0} (CI recorded {1})' -f $Pins.vs_build, $Pins.expect_vs_build)
    Write-Host ('winsdk       : {0} (CI recorded {1})' -f $Pins.winsdk, $Pins.expect_winsdk)

    # cl.exe with no arguments prints its banner to stderr and exits non-zero;
    # that is normal, so the exit code is deliberately ignored here.
    #
    # // VERSION-NUMBER TRAP: cl.exe reports the COMPILER version 19.MM.BBBBB
    # where the toolset (and CI's recorded pin) is 14.MM.BBBBB -- the leading
    # component differs BY DESIGN and always has. Comparing the two strings
    # directly would warn on every single run and train people to ignore the
    # warning. Compare the MM.BBBBB tail, which is the part that actually
    # identifies the toolset.
    $clOut = (Invoke-Capture -Exe $Tools.cl).Lines -join ' '
    $clVer = ''
    $mm = [regex]::Match($clOut, '(\d+\.\d+\.\d+)(\.\d+)?')
    if ($mm.Success) { $clVer = $mm.Groups[1].Value }
    Write-Host ('cl.exe       : {0} (compiler version; toolset {1}, CI recorded {2})' -f $clVer, $Pins.msvc_toolset, $Pins.expect_msvc)

    function Get-VersionTail { param([string]$V) $p = "$V".Split('.'); if ($p.Count -lt 3) { return '' } ; return ($p[1] + '.' + $p[2]) }
    $clTail = Get-VersionTail $clVer
    $installedTail = Get-VersionTail $Pins.msvc_toolset
    $expectTail = Get-VersionTail $Pins.expect_msvc

    if ([string]::IsNullOrWhiteSpace($clVer)) {
        Add-Warning 'could not read a version out of cl.exe; the MSVC pin is unverified for this run.'
    }
    elseif ($clTail -ne $installedTail) {
        Add-Warning (
            ("the cl.exe on PATH ({0}) is not the toolset this image recorded ({1}). " -f $clVer, $Pins.msvc_toolset) +
            "vcvars64 may have selected a different instance; check tool-paths.json."
        )
    }
    if ($expectTail -ne '' -and $installedTail -ne '' -and $installedTail -ne $expectTail) {
        Add-Warning (
            ("MSVC toolset drift: this container installed {0}, CI's recorded compiler is {1}. " -f $Pins.msvc_toolset, $Pins.expect_msvc) +
            "aka.ms/vs/17/release moved, which is not a FLASHIda regression - but float columns and any " +
            "golden captured here may now differ from CI's SYSTEMATICALLY, not just by jitter. Recalibrate " +
            "against a fresh green CI run (docker/README.md) before promoting anything."
        )
    }
    if ($Pins.winsdk -ne $Pins.expect_winsdk) {
        Add-Warning ('Windows SDK drift: installed {0}, CI recorded {1}.' -f $Pins.winsdk, $Pins.expect_winsdk)
    }
}

# ---------------------------------------------------------------------------
# The C++ target list. PARSED out of .github/workflows/flashida-ci.yml by
# docker/ci-lists.sh -- never written down here. That is the whole point of
# the parser (design doc section 5): the yml says 26 targets and its own prose
# comments say 25 and 13, so any list copied into another file is stale by
# construction.
#
# INTERFACE: `docker/ci-lists.sh targets` prints one CMake target name per
# line on stdout and its INFO/NOTE diagnostics on stderr. Verified against the
# committed parser: 26 names, exit 0. The two extra forms below are kept only
# as fallbacks in case the subcommand is ever renamed; there is deliberately
# NO fallback to a literal list.
#
# The filter keeps only tokens matching ^[A-Za-z0-9_]+_test$ -- every target in
# the yml's --target block ends in _test and no ctest -R branch does, so the
# stderr diagnostics cannot contaminate the list -- and the result must clear
# -MinTargets.
# ---------------------------------------------------------------------------
function Get-CiTargets {
    param($Tools)
    $script = Join-Path $Repo 'docker\ci-lists.sh'
    if (-not (Test-Path -LiteralPath $script)) {
        Fail ('docker/ci-lists.sh is missing. It is the single reader of flashida-ci.yml; without it this lane has no target list and will not invent one.')
    }
    $unix = ConvertTo-UnixPath $Repo
    $attempts = @(
        ("cd '{0}' && ./docker/ci-lists.sh targets" -f $unix),
        ("cd '{0}' && ./docker/ci-lists.sh --targets" -f $unix)
    )
    $env:MSYS_NO_PATHCONV = '1'
    $lastOut = ''
    foreach ($a in $attempts) {
        Write-Host ('  > sh -c "{0}"' -f $a)
        $r = Invoke-Capture -Exe $Tools.sh -Arguments @('-c', $a)
        $text = ($r.Lines -join "`n")
        $lastOut = $text
        if ($r.Code -ne 0) {
            Write-Host ('    (exit {0}; trying the next interface)' -f $r.Code)
            continue
        }
        # Match WHOLE LINES, never tokens. `targets` prints one bare name per line
        # on stdout while every diagnostic is prose on stderr -- and Invoke-Capture
        # merges the two streams, so a token split would silently absorb any future
        # stderr message that happens to NAME a target into the authoritative list.
        $names = New-Object System.Collections.ArrayList
        foreach ($line in $r.Lines) {
            $tok = ([string]$line).Trim()
            if ($tok -match '^[A-Za-z0-9_]+_test$' -and -not $names.Contains($tok)) { [void]$names.Add($tok) }
        }
        if ($names.Count -ge $MinTargets) {
            Write-Host ('  parsed {0} C++ targets out of flashida-ci.yml' -f $names.Count)
            return $names.ToArray()
        }
        Write-Host ('    (only {0} target names in that output; trying the next interface)' -f $names.Count)
    }
    Fail (
        ("docker/ci-lists.sh produced fewer than {0} C++ target names. " -f $MinTargets) +
        "The parser is fail-closed on purpose and this lane will NOT substitute a hard-coded list. " +
        "Run 'ci lists' (which self-tests the parser under container mawk) and fix it first. " +
        ("Last output was:`n{0}" -f $lastOut)
    )
}

# The toolchain pins the yml DOES carry, read back at run time. The image build
# already gated the Dockerfile literals against these; re-reading them here
# catches the case where the yml moved AFTER the image was built, which the
# build-time gate cannot see. Informational by construction -- a stale image is
# a rebuild, not a code regression -- but loud.
function Assert-YmlPins {
    param($Tools, $Pins)
    $unix = ConvertTo-UnixPath $Repo
    $r = Invoke-Capture -Exe $Tools.sh -Arguments @('-c', ("cd '{0}' && ./docker/ci-lists.sh pins" -f $unix))
    if ($r.Code -ne 0) {
        Add-Warning ('docker/ci-lists.sh pins exited {0}; the yml toolchain pins were not re-checked for this run.' -f $r.Code)
        return
    }
    $kv = @{}
    foreach ($line in $r.Lines) {
        $m = [regex]::Match($line, '^([a-z_]+)=(.*)$')
        if ($m.Success) { $kv[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    }
    $compare = @(
        @{ key = 'qt_version'; got = $Pins.qt_version },
        @{ key = 'qt_arch'; got = $Pins.qt_arch },
        @{ key = 'qt_archives'; got = $Pins.qt_archives_yml }
    )
    foreach ($c in $compare) {
        if (-not $kv.ContainsKey($c.key)) { continue }
        if ($kv[$c.key] -ne $c.got) {
            Add-Warning (
                ("flashida-ci.yml now says {0}=[{1}] but this IMAGE was built with [{2}]. " -f $c.key, $kv[$c.key], $c.got) +
                "Rebuild the image (its build gate will refuse the stale literal) before trusting a float or a golden from this run."
            )
        }
        else { Write-Host ('  yml pin ok  : {0} = {1}' -f $c.key, $kv[$c.key]) }
    }
}

# ---------------------------------------------------------------------------
# Thermo iAPI DLLs. NEVER in an image layer (design doc D5 / section 4):
# either the host decrypted them into FlashIDA\dependencies\ (gitignored) and
# the bind mount carries them, or THERMO_DLL_PASSPHRASE is passed by
# environment and we decrypt here, once, without ever echoing it.
#
# The identity gate is NOT decoration: both csprojs carry
# <SpecificVersion>False</SpecificVersion> and App.config has no binding
# redirect, so nothing else in the system can detect Client.API version drift.
# The expected identities are read OUT OF THE CSPROJS, so they cannot rot.
# ---------------------------------------------------------------------------
function Get-ExpectedThermoAssemblies {
    $projs = @(
        (Join-Path $Repo 'FlashIDA\src\Flash\Flash.csproj'),
        (Join-Path $Repo 'FlashIDA\src\Flash.Tests\Flash.Tests.csproj')
    )
    $expected = @{}
    foreach ($proj in $projs) {
        if (-not (Test-Path -LiteralPath $proj)) { continue }
        $text = Get-Content -LiteralPath $proj -Raw
        $rx = [regex]'(?s)<Reference\s+Include="([^"]+)"\s*>(.*?)</Reference>'
        $rxHint = [regex]'<HintPath>[^<]*dependencies[\\/]([^<\\/]+\.dll)</HintPath>'
        foreach ($m in $rx.Matches($text)) {
            $incl = $m.Groups[1].Value
            $body = $m.Groups[2].Value
            $hm = $rxHint.Match($body)
            if (-not $hm.Success) { continue }
            $file = $hm.Groups[1].Value
            $parts = $incl.Split(',')
            $name = $parts[0].Trim()
            $ver = ''
            $pkt = ''
            foreach ($p in $parts) {
                $kv = $p.Split('=')
                if ($kv.Count -ne 2) { continue }
                if ($kv[0].Trim() -eq 'Version') { $ver = $kv[1].Trim() }
                if ($kv[0].Trim() -eq 'PublicKeyToken') { $pkt = $kv[1].Trim().ToLower() }
            }
            if (-not $expected.ContainsKey($file)) {
                $expected[$file] = @{ file = $file; name = $name; version = $ver; pkt = $pkt }
            }
        }
    }
    if ($expected.Count -lt 5) {
        Fail (
            ("only {0} Thermo assembly reference(s) with a dependencies\ HintPath were found in the two csprojs; " -f $expected.Count) +
            "CI's log shows five (API-2.0, Fusion.API-1.0, Spectrum-1.0, Thermo.TNG.Client.API, Thermo.TNG.Factory). " +
            "The csproj shape changed - fix this parser rather than lowering the floor."
        )
    }
    return $expected
}

function Restore-ThermoDlls {
    param($Tools)
    $depDir = Join-Path $Repo 'FlashIDA\dependencies'
    $expected = Get-ExpectedThermoAssemblies
    $absent = @()
    foreach ($k in $expected.Keys) {
        if (-not (Test-Path -LiteralPath (Join-Path $depDir $k))) { $absent += $k }
    }

    if ($absent.Count -gt 0 -and -not [string]::IsNullOrEmpty($env:THERMO_DLL_PASSPHRASE)) {
        Write-Host ('  {0} Thermo DLL(s) absent; decrypting thermo-dlls.zip.enc from the environment passphrase.' -f $absent.Count)
        $enc = Join-Path $depDir 'thermo-dlls.zip.enc'
        if (-not (Test-Path -LiteralPath $enc)) { Fail ('{0} not found; cannot restore the Thermo DLLs.' -f $enc) }
        $openssl = Join-Path (Split-Path $Tools.sh -Parent) '..\usr\bin\openssl.exe'
        if (-not (Test-Path -LiteralPath $openssl)) {
            $c = Get-Command openssl.exe -ErrorAction SilentlyContinue
            if ($c) { $openssl = $c.Source }
        }
        if (-not (Test-Path -LiteralPath $openssl)) {
            Fail 'openssl.exe not found in the image; decrypt the Thermo zip on the HOST into FlashIDA\dependencies\ instead.'
        }
        $tmpZip = Join-Path $env:TEMP 'thermo-dlls.zip'
        try {
            # -pass env:VAR, never -pass pass:<secret>: the passphrase must not
            # appear in a command line, a process listing, or this transcript.
            & $openssl enc -aes-256-cbc -d -pbkdf2 -in $enc -out $tmpZip -pass env:THERMO_DLL_PASSPHRASE
            if ($LASTEXITCODE -ne 0) { Fail ('openssl could not decrypt thermo-dlls.zip.enc (exit {0}). Wrong passphrase?' -f $LASTEXITCODE) }
            Expand-Archive -LiteralPath $tmpZip -DestinationPath $depDir -Force
        }
        finally {
            if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
            # Drop the secret from this process so nothing downstream can leak it.
            [Environment]::SetEnvironmentVariable('THERMO_DLL_PASSPHRASE', $null)
        }
    }

    # Fail-closed identity gate. ABSENT is a hard failure, never a skip.
    $problems = @()
    foreach ($k in ($expected.Keys | Sort-Object)) {
        $e = $expected[$k]
        $path = Join-Path $depDir $k
        if (-not (Test-Path -LiteralPath $path)) { $problems += ('{0}: ABSENT' -f $k); continue }
        $an = $null
        try { $an = [System.Reflection.AssemblyName]::GetAssemblyName($path) }
        catch { $problems += ('{0}: not a managed assembly ({1})' -f $k, $_.Exception.Message); continue }
        $gotPkt = ''
        $tokBytes = $an.GetPublicKeyToken()
        if ($tokBytes -and $tokBytes.Length -gt 0) {
            $gotPkt = (($tokBytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        $ok = $true
        if ($an.Name -ne $e.name) { $ok = $false }
        if ($e.version -ne '' -and $an.Version.ToString() -ne $e.version) { $ok = $false }
        if ($e.pkt -ne '' -and $e.pkt -ne 'null' -and $gotPkt -ne $e.pkt) { $ok = $false }
        Write-Host ('  {0,-30} {1} v{2} pkt={3}  {4}' -f $k, $an.Name, $an.Version, $gotPkt, $(if ($ok) { 'ok' } else { 'MISMATCH' }))
        if (-not $ok) {
            $problems += ('{0}: expected {1} v{2} pkt={3}, got {4} v{5} pkt={6}' -f $k, $e.name, $e.version, $e.pkt, $an.Name, $an.Version, $gotPkt)
        }
    }
    if ($problems.Count -gt 0) {
        Fail (
            ("Thermo iAPI DLL gate failed:`n  {0}`n" -f ($problems -join "`n  ")) +
            "These are proprietary and are NEVER baked into the image. Fix on the HOST, then re-run:`n" +
            "  openssl enc -aes-256-cbc -d -pbkdf2 -in FlashIDA/dependencies/thermo-dlls.zip.enc \`n" +
            "    -out /tmp/thermo.zip -pass env:THERMO_DLL_PASSPHRASE && unzip -o /tmp/thermo.zip -d FlashIDA/dependencies/`n" +
            "or pass THERMO_DLL_PASSPHRASE into the container and let this script decrypt it. " +
            "Note Thermo.TNG.Client.API.dll ships with Tune and is NOT on the public thermofisherlsms/iapi repo, " +
            "so the encrypted zip is the primary source, not a fallback."
        )
    }
    Write-Host ('  Thermo identity gate passed ({0} assemblies).' -f $expected.Count)
}

# ---------------------------------------------------------------------------
# C++ build
# ---------------------------------------------------------------------------
function Get-BuildDir {
    # NEVER OpenMS\build: that name is reserved for a CI-shaped tree, and
    # reusing it lets a container build masquerade as a CI one. Both names
    # below are already covered by OpenMS/.gitignore's `cmake-build-*`.
    return (Join-Path $Repo ('OpenMS\cmake-build-msvc-{0}' -f $CppConfig.ToLower()))
}

function Invoke-CppConfigureAndBuild {
    param($Tools, [string[]]$Targets = @())
    $buildDir = Get-BuildDir
    $qt = $Tools.qtroot

    if ($SkipBuild) {
        Write-Step 'C++' 'configure + build  [SKIPPED by -SkipBuild]'
        Write-Host '  -SkipBuild does NOT disable the provenance gate, and there is no flag that does.'
        Write-Host '  If the engine sources are newer than the built OpenMS.dll, or the DLL under test is'
        Write-Host '  not the one just built, or it is the committed known-stale one, the gate FAILS and'
        Write-Host '  the C# suite never runs. This shortcut cannot silently test a stale engine.'
        if (-not (Test-Path -LiteralPath (Join-Path $buildDir 'bin\OpenMS.dll'))) {
            Fail ('-SkipBuild was passed but {0}\bin\OpenMS.dll does not exist. Run -Command dll first.' -f $buildDir)
        }
        return $buildDir
    }

    Write-Step 'C++' ('configure + build ({0})' -f $CppConfig)
    $gui = 'OFF'
    if ($WithGui) { $gui = 'ON' }
    if (-not $WithGui) {
        Write-Host '  NOTE: WITH_GUI=OFF, where CI configures ON. WITH_GUI gates GUI TARGETS, not the'
        Write-Host '  OpenMS library sources, so no behavioural difference is expected -- but "not'
        Write-Host '  expected" is not "asserted": the OpenMS.dll this lane checks the bridge against'
        Write-Host '  comes from a differently-configured library build than CI''s. If a golden ever'
        Write-Host '  disagrees between here and CI, re-run this leg once with -WithGui before'
        Write-Host '  blaming the code. (docker/README.md, design doc section 4.)'
    }

    $cfgArgs = @(
        '-S', (Join-Path $Repo 'OpenMS'),
        '-B', $buildDir,
        '-G', 'Ninja',
        ('-DCMAKE_BUILD_TYPE={0}' -f $CppConfig),
        ('-DWITH_GUI={0}' -f $gui),
        '-DPYOPENMS=OFF',
        '-DBOOST_USE_STATIC=ON',
        ('-DOPENMS_CONTRIB_LIBS={0}' -f $Tools.contrib),
        ('-DCMAKE_PREFIX_PATH={0}/lib/cmake;{0}' -f ($qt -replace '\\', '/')),
        ('-DEigen3_DIR={0}' -f $Tools.eigen),
        '-DCMAKE_CXX_COMPILER_LAUNCHER=ccache'
    )
    if ($CppConfig -eq 'Debug') {
        # ccache's argprocessing.cpp bails on /Zi and /ZI (only /Z7 caches), and
        # OpenMS's cmake_minimum_required(3.21) is below 3.25 so CMP0141
        # defaults OLD and the debug-format variable would be silently ignored.
        $cfgArgs += '-DCMAKE_POLICY_DEFAULT_CMP0141=NEW'
        $cfgArgs += '-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded'
    }
    [void](Invoke-Native -Exe $Tools.cmake -Arguments $cfgArgs -What 'cmake configure')

    $buildArgs = @('--build', $buildDir, '--target', 'OpenMS')
    if ($Targets.Count -gt 0) { $buildArgs = @('--build', $buildDir, '--target') + $Targets }
    [void](Invoke-Native -Exe $Tools.cmake -Arguments $buildArgs -What 'cmake build')
    return $buildDir
}

# ---------------------------------------------------------------------------
# The DLL swap. This is CI's bridge/ABI drift detection, and locally it is the
# part with no safety net: CI gets it EMERGENTLY from a fresh checkout +
# `needs: build` + a one-shot filesystem, and all three of those vanish here.
# So every part of it is asserted, and every value is printed.
# ---------------------------------------------------------------------------
function Invoke-DllSwap {
    param($Tools, [string]$BuildDir)

    Write-Step '0' 'Remove FlashIDA\bin'
    # // DEFECT CI CANNOT HIT: Copy-Item -Force PRESERVES the source mtime, so a
    # freshly built OpenMS.dll can be OLDER than a stale bin\ copy, and
    # CopyToOutputDirectory=PreserveNewest then SKIPS it -- the suite silently
    # tests the old engine and reports green. Two defences: wipe bin\, and touch
    # every swapped DLL to now.
    $bin = Join-Path $Repo 'FlashIDA\bin'
    if (Test-Path -LiteralPath $bin) {
        Remove-Item -LiteralPath $bin -Recurse -Force
        Write-Host ('  removed {0}' -f $bin)
    }
    else { Write-Host '  (nothing to remove)' }

    Write-Step '1' 'Swap 4 fresh DLLs into FlashIDA\dll  (zlib.dll stays committed)'
    $dll = Join-Path $Repo 'FlashIDA\dll'
    $qtBin = Join-Path $Tools.qtroot 'bin'
    $pairs = @(
        @{ src = (Join-Path $BuildDir 'bin\OpenMS.dll'); dst = (Join-Path $dll 'OpenMS.dll'); from = 'OpenMS build' },
        @{ src = (Join-Path $BuildDir 'bin\OpenSwathAlgo.dll'); dst = (Join-Path $dll 'OpenSwathAlgo.dll'); from = 'OpenMS build' },
        @{ src = (Join-Path $qtBin 'Qt6Core.dll'); dst = (Join-Path $dll 'Qt6Core.dll'); from = 'Qt install' },
        @{ src = (Join-Path $qtBin 'Qt6Network.dll'); dst = (Join-Path $dll 'Qt6Network.dll'); from = 'Qt install' }
    )
    foreach ($p in $pairs) {
        if (-not (Test-Path -LiteralPath $p.src)) {
            Fail ('swap source missing: {0}. The C++ build did not produce it (Qt6 DLLs are NOT produced by the OpenMS build - they come from {1}).' -f $p.src, $qtBin)
        }
    }
    foreach ($p in $pairs) {
        Copy-Item -LiteralPath $p.src -Destination $p.dst -Force
        (Get-Item -LiteralPath $p.dst).LastWriteTime = Get-Date
        Write-Host ('  {0,-20} <- {1,-12} {2}' -f ([IO.Path]::GetFileName($p.dst)), $p.from, $p.src)
    }

    # The swap must be byte-exact, and the two files it must NOT touch must be
    # unchanged. zlib.dll is OpenMS.dll's own load-time dep and stays committed;
    # FLASHDeconv.exe is tracked in dll/ too and is not part of the swap.
    foreach ($p in $pairs) {
        $a = Get-Sha256 $p.src
        $b = Get-Sha256 $p.dst
        if ($a -ne $b) { Fail ('swap did not land byte-exact for {0} ({1} vs {2})' -f $p.dst, $a, $b) }
    }
    $untouched = @('dll/zlib.dll', 'dll/FLASHDeconv.exe')
    $code = Invoke-Native -Exe $Tools.git -Arguments (@('-C', (Join-Path $Repo 'FlashIDA'), 'diff', '--quiet', 'HEAD', '--') + $untouched) -What 'git diff (untouched dll files)' -AllowFailure
    if ($code -ne 0) {
        Fail (
            ("{0} differ(s) from HEAD. The swap touches exactly four files and neither of these is one of " -f ($untouched -join ' and ')) +
            "them, so your working tree was ALREADY modified here. Stopping now rather than later, because " +
            "this run's finally block does 'git checkout -- dll/' with no opt-out and would destroy that " +
            "change. Commit or stash it first."
        )
    }

    Write-Host '  FlashIDA\dll after the swap:'
    foreach ($f in (Get-ChildItem -LiteralPath $dll -File | Sort-Object Name)) {
        Write-Host ('    {0,-22} {1,12:N0} B  {2}' -f $f.Name, $f.Length, (Get-Sha256 $f.FullName))
    }

    # Load the swapped engine in a CHILD process so no handle is held open
    # (the finally block has to `git checkout -- dll/`, which a live handle
    # would block). This is the cheap early answer to 0xc0000135
    # STATUS_DLL_NOT_FOUND -- a missing VC++ runtime or Qt dep shows up here,
    # not four steps later inside NUnit.
    Write-Host '  loading OpenMS.dll to prove its runtime closure resolves...'
    $probe = @'
$ErrorActionPreference = 'Stop'
$sig = @"
[DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryW(string p);
[DllImport("kernel32", SetLastError=true)] public static extern bool SetDllDirectoryW([MarshalAs(UnmanagedType.LPWStr)] string p);
"@
$k = @(Add-Type -MemberDefinition $sig -Name FlciNative -Namespace Flci -PassThru)[0]
[void]$k::SetDllDirectoryW($args[0])
$h = $k::LoadLibraryW($args[1])
if ($h -eq [IntPtr]::Zero) {
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host ("LOADFAIL {0} win32={1}" -f $args[1], $e)
    exit 1
}
Write-Host "LOADOK"
exit 0
'@
    New-Item -ItemType Directory -Force -Path 'C:\flci\tmp' | Out-Null
    $probeFile = 'C:\flci\tmp\loadprobe.ps1'
    Set-Content -LiteralPath $probeFile -Value $probe -Encoding ASCII
    $r = Invoke-Capture -Exe 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probeFile, $dll, (Join-Path $dll 'OpenMS.dll')
    )
    $rc = $r.Code
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    Write-Host ('    {0}' -f (($r.Lines -join ' ').Trim()))
    if ($rc -ne 0) {
        Fail (
            "the freshly built OpenMS.dll does not load. That is a runtime-closure failure, not a test " +
            "failure: check the VC++ runtime (MSVCP140, MSVCP140_1, VCRUNTIME140, VCRUNTIME140_1, " +
            "VCOMP140) and that zlib.dll / Qt6Core.dll / Qt6Network.dll sit beside it. Windows reports " +
            "this as 0xc0000135 STATUS_DLL_NOT_FOUND."
        )
    }
}

# ---------------------------------------------------------------------------
# THE PROVENANCE GATE (design doc section 8). Three checks, all three values
# printed every run, no flag that disables any of them.
# ---------------------------------------------------------------------------
function Invoke-ProvenanceGate {
    param($Tools, [string]$BuildDir, [switch]$BinRequired)

    Write-Step '5' 'PROVENANCE GATE (bridge/ABI drift - CI gets this emergently, we must assert it)'
    $flash = Join-Path $Repo 'FlashIDA'
    $builtDll = Join-Path $BuildDir 'bin\OpenMS.dll'
    $binDll = Join-Path $flash 'bin\OpenMS.dll'
    $dllDll = Join-Path $flash 'dll\OpenMS.dll'

    if (-not (Test-Path -LiteralPath $builtDll)) { Fail ('no built OpenMS.dll at {0}' -f $builtDll) }

    $shaBuilt = Get-Sha256 $builtDll
    $shaDll = Get-Sha256 $dllDll
    $shaBin = Get-Sha256 $binDll

    # (b) needs HEAD's committed blob as BYTES. A PowerShell pipeline is a
    # text/object stream and would mangle it; Start-Process -RedirectStandard-
    # Output hands the child a real file handle, so the bytes land verbatim.
    # (Deliberately NOT `git hash-object`: FlashIDA/.gitattributes sets `text`
    # for `*`, so attribute-driven eol filtering could make blob ids and file
    # contents disagree. Hashing the actual bytes cannot.)
    $tmpDir2 = 'C:\flci\tmp'
    New-Item -ItemType Directory -Force -Path $tmpDir2 | Out-Null
    $tmpHead = Join-Path $tmpDir2 'head-openms.dll'
    if (Test-Path -LiteralPath $tmpHead) { Remove-Item -LiteralPath $tmpHead -Force }
    $proc = Start-Process -FilePath $Tools.git `
        -ArgumentList @('-C', $flash, 'cat-file', 'blob', 'HEAD:dll/OpenMS.dll') `
        -RedirectStandardOutput $tmpHead -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tmpHead) -or (Get-Item -LiteralPath $tmpHead).Length -eq 0) {
        Fail 'could not read HEAD:dll/OpenMS.dll out of the FlashIDA submodule; the provenance gate cannot be evaluated and will not be skipped.'
    }
    $shaHead = Get-Sha256 $tmpHead
    Remove-Item -LiteralPath $tmpHead -Force -ErrorAction SilentlyContinue

    Write-Host ('  built   {0}  {1}' -f $shaBuilt, $builtDll)
    Write-Host ('  dll/    {0}  {1}' -f $shaDll, $dllDll)
    Write-Host ('  bin/    {0}  {1}' -f $shaBin, $binDll)
    Write-Host ('  HEAD    {0}  FlashIDA HEAD:dll/OpenMS.dll (committed, known stale)' -f $shaHead)

    # (a) the DLL under test IS the DLL just built.
    if ($BinRequired) {
        if (-not (Test-Path -LiteralPath $binDll)) { Fail ('FlashIDA\bin\OpenMS.dll does not exist after msbuild; CopyToOutputDirectory did not run.') }
        if ($shaBin -ne $shaBuilt) {
            Fail (
                "(a) FlashIDA\bin\OpenMS.dll is NOT the DLL that was just built. This is the PreserveNewest " +
                "skip: Copy-Item -Force preserves the SOURCE mtime, so a fresh DLL can be older than a stale " +
                "bin\ copy and MSBuild skips it. The suite would have tested the old engine and reported green. " +
                "Re-run without -SkipBuild."
            )
        }
    }
    if ($shaDll -ne $shaBuilt) {
        Fail '(a) FlashIDA\dll\OpenMS.dll is not the DLL that was just built - the swap did not complete.'
    }

    # (b) it is NOT the committed, known-stale DLL.
    # LIMITATION, stated: this is false-red if someone DELIBERATELY commits a
    # rebuilt DLL. Because there is no --keep-dll flag, that workflow is a
    # rare, manual, diff-reviewed act; re-run after committing and it passes on
    # the new HEAD. A gate that cries wolf is a gate people bypass, so this one
    # is SCOPED rather than softened.
    if ($shaBuilt -eq $shaHead) {
        Fail (
            "(b) the DLL under test is byte-identical to the COMMITTED FlashIDA/dll/OpenMS.dll. Either the " +
            "swap never happened, or you are testing the known-stale committed engine. (If you have just " +
            "deliberately committed a rebuilt DLL, re-run: this check passes against the new HEAD.)"
        )
    }

    # (c) it is not older than the engine sources.
    # LIMITATION, stated: still blind to changes OUTSIDE the OpenMS source tree
    # that affect the DLL -- CMake flags, the contrib tarball, the toolchain.
    # Those are covered by the toolchain-pin assertion above and by rebuilding
    # whenever cmake-build-*/CMakeCache.txt changes, not by this check.
    $srcRoots = @(
        (Join-Path $Repo 'OpenMS\src\openms\source'),
        (Join-Path $Repo 'OpenMS\src\openms\include')
    )
    $newest = $null
    foreach ($root in $srcRoots) {
        if (-not (Test-Path -LiteralPath $root)) { Fail ('{0} does not exist; the OpenMS submodule is not checked out.' -f $root) }
        $c = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -ne $c -and ($null -eq $newest -or $c.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc)) { $newest = $c }
    }
    if ($null -eq $newest) { Fail 'found no files under OpenMS\src\openms\{source,include}; refusing to pass a staleness check that examined nothing.' }
    $dllTime = (Get-Item -LiteralPath $builtDll).LastWriteTimeUtc
    Write-Host ('  newest engine source: {0:yyyy-MM-dd HH:mm:ss}Z  {1}' -f $newest.LastWriteTimeUtc, $newest.FullName)
    Write-Host ('  built OpenMS.dll    : {0:yyyy-MM-dd HH:mm:ss}Z' -f $dllTime)
    if ($dllTime -lt $newest.LastWriteTimeUtc) {
        Fail (
            ("(c) OpenMS.dll is OLDER than {0}. Locally this is THE default failure mode - " -f $newest.FullName) +
            "you edited the engine and did not rebuild. In CI it is unreachable. Re-run without -SkipBuild."
        )
    }
    Write-Host '  provenance gate: all three checks passed.'
}

# ---------------------------------------------------------------------------
# Fixtures. 12 of the 31 log-golden tests Assert.Pass and RETURN when their
# fixtures are absent, so a missing fixture set is a silent green. Assert the
# inventory BEFORE the suite runs (design doc section 7, cost-of-L1).
# ---------------------------------------------------------------------------
function Assert-FixtureInventory {
    $spectra = Join-Path $Repo 'FlashIDA\test-data\spectra'
    $configs = Join-Path $Repo 'FlashIDA\test-data\configs'
    if (-not (Test-Path -LiteralPath $spectra)) { Fail ('{0} not found.' -f $spectra) }
    $checks = @(
        @{ label = 'ms3_cytc_*_scan*.txt'; count = 24; got = @(Get-ChildItem -LiteralPath $spectra -Filter 'ms3_cytc_*_scan*.txt' -File).Count },
        @{ label = 'ms3_cytc2_*'; count = 17; got = @(Get-ChildItem -LiteralPath $spectra -Filter 'ms3_cytc2_*' -File).Count },
        @{ label = 'ms2_cytc_ce*'; count = 6; got = @(Get-ChildItem -LiteralPath $spectra -Filter 'ms2_cytc_ce*' -File).Count }
    )
    $bad = @()
    foreach ($c in $checks) {
        Write-Host ('  {0,-24} {1} (expected {2})' -f $c.label, $c.got, $c.count)
        if ($c.got -ne $c.count) { $bad += ('{0}: {1} != {2}' -f $c.label, $c.got, $c.count) }
    }
    $etd = Join-Path $configs 'method_exploration_etd.json'
    Write-Host ('  {0,-24} {1}' -f 'method_exploration_etd.json', $(if (Test-Path -LiteralPath $etd) { 'present' } else { 'ABSENT' }))
    if (-not (Test-Path -LiteralPath $etd)) { $bad += 'configs/method_exploration_etd.json: ABSENT' }
    if ($bad.Count -gt 0) {
        Fail (
            ("fixture inventory mismatch: {0}. " -f ($bad -join '; ')) +
            "12 of the 31 log-golden tests Assert.Pass and return when their fixtures are missing, so this " +
            "would have been a SILENT GREEN. Check out FlashIDA fully (git submodule update --init) before re-running."
        )
    }
}

# ---------------------------------------------------------------------------
# Log-golden inventory. The all-five-streams capture guard inside
# FLASHIdaLogGolden_test only runs `if (Capture)`, and this lane never
# captures -- so the runner has to assert it. The expected case list and the
# five stream basenames are DERIVED from the committed golden tree, not
# written here: the stream names are engine constants (IdaLogger's k*Name,
# mirrored by LogGoldenComparer.FileNames) and copying them would be exactly
# the duplication the parser landing exists to prevent.
# ---------------------------------------------------------------------------
function Assert-LogGoldenInventory {
    $goldenLogs = Join-Path $Repo 'FlashIDA\test-data\golden\logs'
    $outRoot = Join-Path $Repo 'FlashIDA\bin\log-golden-output'
    if (-not (Test-Path -LiteralPath $goldenLogs)) { Fail ('{0} not found; cannot derive the expected log-golden inventory.' -f $goldenLogs) }
    $cases = @(Get-ChildItem -LiteralPath $goldenLogs -Directory | Sort-Object Name)
    if ($cases.Count -eq 0) { Fail ('{0} contains no mode directories; refusing to pass an inventory check that examined nothing.' -f $goldenLogs) }
    if (-not (Test-Path -LiteralPath $outRoot)) {
        Fail ('{0} does not exist. The log-golden tests produced no output at all, which means they did not run.' -f $outRoot)
    }
    $problems = @()
    $streamsTotal = 0
    foreach ($case in $cases) {
        $streams = @(Get-ChildItem -LiteralPath $case.FullName -Filter '*.golden.tsv' -File | ForEach-Object { $_.Name -replace '\.golden\.tsv$', '' })
        if ($streams.Count -eq 0) { $problems += ('{0}: the committed golden dir has no *.golden.tsv' -f $case.Name); continue }
        foreach ($s in $streams) {
            $streamsTotal++
            $p = Join-Path (Join-Path $outRoot $case.Name) ($s + '.normalized')
            if (-not (Test-Path -LiteralPath $p)) { $problems += ('{0}/{1}.normalized: ABSENT' -f $case.Name, $s) }
            elseif ((Get-Item -LiteralPath $p).Length -eq 0) { $problems += ('{0}/{1}.normalized: EMPTY' -f $case.Name, $s) }
        }
    }
    Write-Host ('  {0} modes x their committed streams = {1} .normalized files expected' -f $cases.Count, $streamsTotal)
    if ($problems.Count -gt 0) {
        Fail (
            ("log-golden inventory incomplete:`n  {0}`n" -f ($problems -join "`n  ")) +
            "LogGoldenComparer.Normalize returns an EMPTY STRING for a file that does not exist, so an unguarded capture " +
            "over a mislocated run would blank the goldens and pass. This lane never captures, but the same " +
            "hole makes a partial run look complete - so it is a hard failure here."
        )
    }
    Write-Host ('  log-golden inventory complete ({0} files).' -f $streamsTotal)
}

# ---------------------------------------------------------------------------
# Staging. NEVER in place, NEVER into FlashIDA\test-data\golden.
#
# The three staging locations are chosen by the ENGINE and the test code, not
# by us (FLASHIdaLogGolden_test writes bin\log-golden-output\, ContinuityTests
# writes bin\continuity-output\, and only regression-runner's -OutputDir is
# ours) -- and changing that would be a source change, which is forbidden.
# What this function guarantees is the part that IS ours: everything a human
# might promote is copied OUT of the repo's working directories into one
# reviewable staging tree, before the regression compare wipes test-output.
# ---------------------------------------------------------------------------
function Get-StageDir {
    if (-not [string]::IsNullOrWhiteSpace($StageDir)) {
        # Everything staged is a CANDIDATE golden, so staging into the fixture tree
        # is how a capture silently becomes a promotion. An operator-supplied
        # -StageDir inside FlashIDA\test-data is REFUSED here rather than left for
        # L4 to notice after the files have already been written.
        $forbidden = (Join-Path $Repo 'FlashIDA\test-data')
        $norm = ([IO.Path]::GetFullPath($StageDir)).TrimEnd('\')
        $forb = ([IO.Path]::GetFullPath($forbidden)).TrimEnd('\')
        if ($norm -eq $forb -or $norm.StartsWith(($forb + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            Fail ('-StageDir {0} resolves inside {1}. Staging never writes into the fixture or golden tree - choose a path outside it (the default is <repo>\.container-out\win).' -f $StageDir, $forbidden)
        }
        return $StageDir
    }
    return (Join-Path $Repo '.container-out\win')
}

function Invoke-Stage {
    param([switch]$Reset)
    $stage = Get-StageDir
    if ($Reset -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $script:StagedTo = $stage
    return $stage
}

function Copy-IfPresent {
    param([string]$From, [string]$To, [string]$Label)
    if (-not (Test-Path -LiteralPath $From)) { Write-Host ('  {0,-24} (nothing at {1})' -f $Label, $From); return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path $To -Parent) | Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
    Write-Host ('  {0,-24} -> {1}' -f $Label, $To)
    return $true
}

# ---------------------------------------------------------------------------
# The C# leg: CI's windows-tests steps, in CI's order, with CI's env:.
# ---------------------------------------------------------------------------
function Invoke-CSharpLeg {
    param($Tools, [string]$BuildDir, [switch]$StageGoldens)

    $flash = Join-Path $Repo 'FlashIDA'
    # CI sets this as ${{ github.workspace }}/OpenMS/share/OpenMS -- forward
    # slashes. It is INERT (FLASHIdaWrapper's static ctor unconditionally
    # overwrites it with <assembly dir>/share/OpenMS), but it is set here for
    # fidelity: dropping it silently is a divergence from the thing being
    # reproduced.
    $openmsData = ((Join-Path $Repo 'OpenMS\share\OpenMS') -replace '\\', '/')

    Write-Step '2' 'Thermo iAPI DLLs + identity gate'
    Restore-ThermoDlls -Tools $Tools

    Write-Step '3' 'nuget restore'
    [void](Invoke-Native -Exe $Tools.nuget -Arguments @('restore', (Join-Path $Repo 'FlashIDA\src\Flash.sln')) -What 'nuget restore')

    Write-Step '4' 'msbuild  (Debug | Any CPU - both values are load-bearing)'
    # Do NOT "improve" this to Release. Flash.csproj's Release|AnyCPU sets
    # OutputPath to bin\Release\ (relative to src\Flash\) while
    # Flash.Tests.csproj uses ..\..\bin\ in all four configurations -- so
    # Flash.exe and Flash.Tests.dll separate and nunit3-console,
    # regression-runner's -FlashExe and TestDirectory\..\test-data all break.
    # Debug|x64 redirects to bin\x64\Debug\ and breaks the same paths. The
    # plan's Release default applies to the C++ build ONLY, and there is
    # deliberately no flag here.
    # /p:LangVersion=7.3 because neither project pins LangVersion on the
    # AnyCPU configurations CI builds, so a newer Roslyn would accept source
    # CI's compiler rejects.
    [void](Invoke-Native -Exe $Tools.msbuild -Arguments @(
            (Join-Path $Repo 'FlashIDA\src\Flash.sln'),
            '/p:Configuration=Debug',
            '/p:Platform=Any CPU',
            '/p:LangVersion=7.3',
            '/m'
        ) -What 'msbuild')

    Invoke-ProvenanceGate -Tools $Tools -BuildDir $BuildDir -BinRequired

    Write-Step '6' 'Copy Thermo DLLs to build output (Flash.exe runtime)'
    $deps = @(Get-ChildItem -LiteralPath (Join-Path $flash 'dependencies') -Filter '*.dll' -File)
    if ($deps.Count -eq 0) { Fail 'no DLLs in FlashIDA\dependencies to copy into bin\.' }
    Copy-Item -Path (Join-Path $flash 'dependencies\*.dll') -Destination (Join-Path $flash 'bin') -Force
    Write-Host ('  copied {0} Thermo DLL(s) into FlashIDA\bin' -f $deps.Count)

    Write-Step '6b' 'Fixture inventory (before the suite - 12 golden tests Assert.Pass without it)'
    Assert-FixtureInventory

    Write-Step '7' 'NUnit'
    $nunit = Join-Path $Repo 'FlashIDA\src\packages\NUnit.ConsoleRunner.3.16.3\tools\nunit3-console.exe'
    if (-not (Test-Path -LiteralPath $nunit)) {
        Fail ('{0} not found after nuget restore. The console runner is restored via NuGet; a restore that "succeeded" without it is a failure.' -f $nunit)
    }
    $filtered = -not [string]::IsNullOrWhiteSpace($Filter)
    # A filtered run writes to a DIFFERENT path so the bridge-smoke gate
    # physically cannot read it and report green off a partial suite.
    $resultXml = Join-Path $Repo $(if ($filtered) { 'TestResults.filtered.xml' } else { 'TestResults.xml' })
    if (Test-Path -LiteralPath $resultXml) { Remove-Item -LiteralPath $resultXml -Force }

    $nunitArgs = @('FlashIDA\bin\Flash.Tests.dll', ('--result={0}' -f $resultXml), '--agents=1', '--timeout=300000')
    if ($filtered) { $nunitArgs += @('--where', $Filter) }

    Push-Location -LiteralPath $Repo
    try {
        [Environment]::SetEnvironmentVariable('OPENMS_DATA_PATH', $openmsData)
        $rc = Invoke-Native -Exe $nunit -Arguments $nunitArgs -What 'nunit3-console' -AllowFailure
    }
    finally { Pop-Location }

    if (-not (Test-Path -LiteralPath $resultXml)) {
        Fail ('nunit3-console produced no {0}. Treat a missing result file as a failure of this step, never a reason to skip the gates.' -f $resultXml)
    }
    [xml]$res = Get-Content -LiteralPath $resultXml
    $run = $res.'test-run'
    $total = [int]$run.total
    $passed = [int]$run.passed
    $failed = [int]$run.failed
    $skipped = [int]$run.skipped
    $incon = [int]$run.inconclusive
    Write-Host ('  total={0} passed={1} failed={2} skipped={3} inconclusive={4} (runner exit {5})' -f $total, $passed, $failed, $skipped, $incon, $rc)

    if ($total -eq 0) {
        # Verified against real NUnit 3.16.3: a bogus selector and an
        # unqualified class name BOTH give "Test Count: 0, Overall result:
        # Passed, exit 0". Zero selected is a failure, never a pass.
        Fail (
            "NUnit selected ZERO tests and still exited 0 - that is NUnit's behaviour for a bad --where, " +
            "not a green run. 'class' needs the fully namespace-qualified name (ContinuityTests lives in " +
            "Flash.Tests.AcquisitionLoop, not Flash.Tests)."
        )
    }
    if ($failed -ne 0 -or $incon -ne 0) {
        Fail ('the C# suite reported failed={0} inconclusive={1}. See {2}.' -f $failed, $incon, $resultXml)
    }
    if ($filtered) {
        # A filtered run stops here on purpose. Everything below either depends
        # on the whole suite having run (GATE 1's JSON goldens are written by
        # GoldenCaptureTests; the log-golden inventory needs all 25 modes) or
        # takes minutes that a targeted run is supposed to save. Running them
        # anyway would produce spurious reds, and skipping them silently is the
        # exact failure this contract exists to prevent -- so they are named.
        Add-Partial (
            ("the NUnit run was FILTERED ({0}): {1} test(s) ran instead of the full suite, and " -f $Filter, $total) +
            "the bridge-smoke gate, the TRACK-CREATE gate, the JSON-golden gate, the regression run " +
            "and the log-golden inventory did NOT run"
        )
        Write-Host ''
        Write-Host 'FILTERED RUN - stopping after NUnit. Gates 1, 3 and 4, the regression run and the'
        Write-Host 'log-golden inventory are skipped, which is why this exits non-zero as PARTIAL.'
        $stage = Invoke-Stage
        [void](Copy-IfPresent -From $resultXml -To (Join-Path $stage ([IO.Path]::GetFileName($resultXml))) -Label 'nunit results')
        return
    }
    else {
        $mismatch = @()
        if ($total -ne $ExpectTotal) { $mismatch += ('total {0} != {1}' -f $total, $ExpectTotal) }
        if ($passed -ne $ExpectPassed) { $mismatch += ('passed {0} != {1}' -f $passed, $ExpectPassed) }
        if ($skipped -ne $ExpectSkipped) { $mismatch += ('skipped {0} != {1}' -f $skipped, $ExpectSkipped) }
        if ($mismatch.Count -gt 0) {
            Fail (
                ("the unfiltered suite does not match the calibration: {0}. " -f ($mismatch -join ', ')) +
                "The calibration anchor is parent 9bcfc82 / CI run 33083942633 (total=181 passed=180 " +
                "failed=0 skipped=1; the skip is ContinuityTests.P4_AL_CT42_DeepMode_TargetLogEffect). " +
                "If you legitimately added or removed a test, re-run with -ExpectTotal/-ExpectPassed/" +
                "-ExpectSkipped and update the calibration record in docker/README.md in the same change."
            )
        }
        Write-Host '  matches the calibration record exactly.'
    }

    if ($RegenConfigReference) {
        Write-Step '8' 'REGEN_CONFIG_REFERENCE (opt-in) - AFTER the unfiltered suite, never before'
        if ($filtered) { Fail '-RegenConfigReference cannot be combined with -Filter: the ordering rule is "after the UNFILTERED suite".' }
        # The yml says it plainly: run first, this rewrites the fixture under
        # the gate's feet and the gate then passes against its own output,
        # reporting green while the schema silently drifted.
        $regenXml = Join-Path $Repo 'RegenResults.xml'
        Push-Location -LiteralPath $Repo
        try {
            [Environment]::SetEnvironmentVariable('REGEN_CONFIG_REFERENCE', '1')
            [Environment]::SetEnvironmentVariable('OPENMS_DATA_PATH', $openmsData)
            [void](Invoke-Native -Exe $nunit -Arguments @(
                    'FlashIDA\bin\Flash.Tests.dll',
                    "--where", "test=='Flash.Tests.ConfigSchemaParityTests.Reference_IsNeverStale'",
                    ('--result={0}' -f $regenXml), '--agents=1', '--timeout=300000'
                ) -What 'nunit3-console (regen)' -AllowFailure)
        }
        finally {
            [Environment]::SetEnvironmentVariable('REGEN_CONFIG_REFERENCE', $null)
            Pop-Location
        }
        if (-not (Test-Path -LiteralPath $regenXml)) { Fail 'the regen run produced no RegenResults.xml.' }
        [xml]$rr = Get-Content -LiteralPath $regenXml
        if ([int]$rr.'test-run'.total -lt 1) {
            Fail 'the regen run selected ZERO tests (NUnit exits 0 on a bad --where). config_schema_reference.json was NOT regenerated.'
        }
        Add-Warning 'REGEN_CONFIG_REFERENCE rewrote FlashIDA\test-data\config_schema_reference.json IN PLACE. That is a committed fixture: review the diff before committing, and note it sits outside both golden hooks.'
    }

    Write-Step '9' 'Flash.exe baseline capture'
    $exe = Join-Path $flash 'bin\Flash.exe'
    $inSpec = Join-Path $flash 'test-data\spectra\ms1_smoke_test.txt'
    $inCfg = Join-Path $flash 'test-data\configs\method_default.json'
    foreach ($f in @($exe, $inSpec, $inCfg)) { if (-not (Test-Path -LiteralPath $f)) { Fail ('missing input for the baseline capture: {0}' -f $f) } }
    New-Item -ItemType Directory -Force -Path (Join-Path $flash 'test-output') | Out-Null
    Push-Location -LiteralPath $Repo
    try {
        # Positional, in exactly this order. There are no CLI flags: the
        # csproj pins StartupObject to Flash.IDA.FLASHIdaWrapper, so args[0]
        # IS the input filename and `-t` would be read as one.
        [void](Invoke-Native -Exe $exe -Arguments @(
                'FlashIDA\test-data\spectra\ms1_smoke_test.txt',
                'FlashIDA\test-output\baseline_phase0.tsv',
                'FlashIDA\test-data\configs\method_default.json'
            ) -What 'Flash.exe baseline')
    }
    finally { Pop-Location }

    Write-Step '10' 'regression-runner -captureMode (phase4 goldens -> staging dir, never in place)'
    Push-Location -LiteralPath $Repo
    try {
        [Environment]::SetEnvironmentVariable('OPENMS_DATA_PATH', $openmsData)
        [void](Invoke-Native -Exe 'powershell.exe' -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'FlashIDA\test-scripts\regression-runner.ps1',
                '-FlashExe', 'FlashIDA\bin\Flash.exe',
                '-TestDataDir', 'FlashIDA\test-data',
                '-OutputDir', 'FlashIDA\test-output\phase4-golden',
                '-captureMode'
            ) -What 'regression-runner -captureMode')
    }
    finally { Pop-Location }

    Write-Step '11' 'GATE 1 - JSON golden capture'
    # The fourth gate, the one CLAUDE.md omits.
    $jsonDir = Join-Path $flash 'test-output\json'
    $missing = @()
    foreach ($f in @('config_default.json', 'config_full.json')) {
        if (Test-Path -LiteralPath (Join-Path $jsonDir $f)) { Write-Host ('  {0} captured' -f $f) } else { $missing += $f }
    }
    if ($missing.Count -gt 0) { Fail ('JSON golden(s) not captured: {0}' -f ($missing -join ', ')) }

    Write-Step '12' 'GATE 2 - test data directories'
    foreach ($f in @('method_default.json', 'method_json_roundtrip.json')) {
        $p = Join-Path $flash ('test-data\configs\{0}' -f $f)
        if (-not (Test-Path -LiteralPath $p)) { Fail ('{0} not found (required by the Phase 1 tests)' -f $p) }
        Write-Host ('  {0} present' -f $f)
    }

    Write-Step '12b' 'Log-golden inventory + STAGE everything promotable'
    Assert-LogGoldenInventory
    # // ORDERING IS LOAD-BEARING: step 13's non-capture regression run WIPES
    # FlashIDA\test-output (regression-runner.ps1:11-13), destroying what steps
    # 9-11 produced. Stage before it, not after.
    $stage = Invoke-Stage -Reset
    Write-Host ('  staging root: {0}' -f $stage)
    [void](Copy-IfPresent -From (Join-Path $flash 'bin\log-golden-output') -To (Join-Path $stage 'goldens\logs') -Label 'log goldens')
    [void](Copy-IfPresent -From (Join-Path $flash 'bin\continuity-output') -To (Join-Path $stage 'goldens\continuity') -Label 'continuity goldens')
    [void](Copy-IfPresent -From (Join-Path $flash 'test-output\phase4-golden') -To (Join-Path $stage 'goldens\regression') -Label 'regression TSVs')
    [void](Copy-IfPresent -From (Join-Path $flash 'test-output\json') -To (Join-Path $stage 'json') -Label 'json goldens')
    [void](Copy-IfPresent -From (Join-Path $flash 'test-output\baseline_phase0.tsv') -To (Join-Path $stage 'baseline_phase0.tsv') -Label 'baseline_phase0.tsv')

    Write-Step '13' 'regression-runner (compare) - this WIPES FlashIDA\test-output'
    $regLog = Join-Path $flash 'test-output\regression-stdout.txt'
    $regRc = 0
    Push-Location -LiteralPath $Repo
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        [Environment]::SetEnvironmentVariable('OPENMS_DATA_PATH', $openmsData)
        Write-Host '  > regression-runner.ps1 (compare) | Tee-Object regression-stdout.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path $regLog -Parent) | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'FlashIDA\test-scripts\regression-runner.ps1' `
            -FlashExe 'FlashIDA\bin\Flash.exe' -TestDataDir 'FlashIDA\test-data' -OutputDir 'FlashIDA\test-output' 2>&1 |
            Tee-Object -FilePath $regLog | Out-Host
        # Re-assert the child exit code explicitly. Tee-Object is a cmdlet and
        # leaves $LASTEXITCODE as the child's code, but any later native call
        # would overwrite it -- so capture it here and act on it below.
        $regRc = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    [void](Copy-IfPresent -From $regLog -To (Join-Path $stage 'regression-stdout.txt') -Label 'regression stdout')

    Write-Step '14' 'GATE 3 - bridge smoke tests'
    # Reads TestResults.xml, which a filtered run never writes (it writes
    # TestResults.filtered.xml) -- and a filtered run has already returned
    # above, so this gate can never be satisfied by a partial suite.
    $trx = Join-Path $Repo 'TestResults.xml'
    if (-not (Test-Path -LiteralPath $trx)) { Fail 'TestResults.xml not found - the NUnit run did not produce results; cannot verify bridge smoke tests.' }
    [xml]$r2 = Get-Content -LiteralPath $trx
    $cases = @($r2.SelectNodes("//test-case[contains(@classname,'BridgeSmokeTests')]"))
    if ($cases.Count -lt 1) { Fail 'zero BridgeSmokeTests cases found in results - the tests did not run (renamed class, category filter, or an aborted suite).' }
    $bad = @($cases | Where-Object { $_.result -ne 'Passed' })
    if ($bad.Count -gt 0) {
        $names = ($bad | ForEach-Object { ('{0}: {1}' -f $_.name, $_.result) }) -join '; '
        Fail ('bridge smoke tests not all Passed (Skipped/Inconclusive count as failures): {0}' -f $names)
    }
    Write-Host ('  bridge smoke tests passed ({0} cases).' -f $cases.Count)

    Write-Step '15' 'GATE 4 - [TRACK-CREATE] entries'
    if (-not (Test-Path -LiteralPath $regLog)) {
        Fail ('regression stdout log not found ({0}) - the regression step produced no output; cannot verify [TRACK-CREATE].' -f $regLog)
    }
    $track = @(Select-String -LiteralPath $regLog -Pattern '\[TRACK-CREATE\]')
    Write-Host ('  found {0} [TRACK-CREATE] entries.' -f $track.Count)
    if ($track.Count -eq 0) { Fail 'zero [TRACK-CREATE] entries - the unified bridge should produce tracking entries.' }

    # The regression exit code is asserted AFTER gates 3 and 4 so a regression
    # failure still gets its gates evaluated and reported, exactly as CI's
    # `if: always()` steps do.
    if ($regRc -ne 0) { Fail ('regression-runner reported failures (exit {0}). See {1}.' -f $regRc, $regLog) }

    if ($StageGoldens) {
        Write-Host ''
        Write-Host 'GOLDEN STAGING COMPLETE. Nothing was written into FlashIDA\test-data\golden, and nothing was promoted.'
        Write-Host ('  staged at: {0}' -f $stage)
        Write-Host '  Promotion is a HUMAN action on the HOST: run `ci golden-diff` to render the cell-level'
        Write-Host '  diffs and print the exact `cp` lines for the cells that moved, review them, and run them.'
        Write-Host '  There is deliberately no golden-promote command anywhere: a wrapper is the one command'
        Write-Host '  shape the repo golden-write guard does not gate.'
        Write-Host '  For the 13 regression TSVs, PREFER the CI phase4-golden-capture artifact over this local'
        Write-Host '  capture: compare_golden.py uses REL_TOL=1e-4, ten times tighter than the C# comparer.'
    }
}

# ---------------------------------------------------------------------------
# Targeted MSVC ctest triage.
# ---------------------------------------------------------------------------
function Invoke-CppLeg {
    param($Tools)
    if ($Target.Count -eq 0) {
        Fail (
            "-Command cpp requires -Target <name>[,<name>...]. There is deliberately no full MSVC ctest run " +
            "here: running all of them locally duplicates CI's cpp-tests job on the toolchain CI is " +
            "authoritative for, for ~35 minutes. The full set belongs to the Linux lane ('ci cpp --full') and " +
            "to CI. This lane's job is the DLL and the C# side."
        )
    }
    Write-Step 'lists' 'C++ target list, parsed out of flashida-ci.yml'
    $known = Get-CiTargets -Tools $Tools
    $unknown = @($Target | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Fail (
            ("unknown target(s): {0}. A C++ test runs in CI only if it is registered in BOTH the --target " -f ($unknown -join ', ')) +
            ("block AND the ctest -R alternation of flashida-ci.yml. Known targets: {0}" -f ($known -join ', '))
        )
    }
    $buildDir = Invoke-CppConfigureAndBuild -Tools $Tools -Targets $Target

    Write-Step 'cpp' 'assert the exes exist, then stage the 5-DLL runtime set beside them'
    $tbin = Join-Path $buildDir 'src\tests\class_tests\bin'
    if (-not (Test-Path -LiteralPath $tbin)) { Fail ('{0} not found - the class tests were not configured. Never pass ENABLE_CLASS_TESTING=OFF.' -f $tbin) }
    foreach ($t in $Target) {
        $exe = Join-Path $tbin ($t + '.exe')
        # Assert EXISTENCE, never mtime: ccache and ninja legitimately skip a relink.
        if (-not (Test-Path -LiteralPath $exe)) { Fail ('{0} was not produced by the build.' -f $exe) }
    }
    $qtBin = Join-Path $Tools.qtroot 'bin'
    $stagePairs = @(
        (Join-Path $buildDir 'bin\OpenMS.dll'),
        (Join-Path $buildDir 'bin\OpenSwathAlgo.dll'),
        (Join-Path $qtBin 'Qt6Core.dll'),
        (Join-Path $qtBin 'Qt6Network.dll'),
        (Join-Path $Repo 'FlashIDA\dll\zlib.dll')     # OpenMS.dll's own load-time dep
    )
    foreach ($s in $stagePairs) {
        if (-not (Test-Path -LiteralPath $s)) { Fail ('runtime DLL missing for the test bin staging: {0}' -f $s) }
        Copy-Item -LiteralPath $s -Destination $tbin -Force
    }
    Write-Host ('  staged {0} runtime DLLs into {1}' -f $stagePairs.Count, $tbin)

    Write-Step 'ctest' ('run {0} target(s)' -f $Target.Count)
    $junit = Join-Path $buildDir 'flci-ctest.xml'
    if (Test-Path -LiteralPath $junit) { Remove-Item -LiteralPath $junit -Force }
    $rx = '(' + (($Target | ForEach-Object { '^' + [regex]::Escape($_) + '$' }) -join '|') + ')'
    [Environment]::SetEnvironmentVariable('OPENMS_DATA_PATH', ((Join-Path $Repo 'OpenMS\share\OpenMS') -replace '\\', '/'))
    [Environment]::SetEnvironmentVariable('OMP_NUM_THREADS', '1')
    $rc = Invoke-Native -Exe $Tools.ctest -Arguments @(
        '--test-dir', $buildDir, '-R', $rx, '--output-on-failure',
        '--no-tests=error', '--output-junit', $junit
    ) -What 'ctest' -AllowFailure

    # NEVER gate on JUnit `failures`: verified on ctest 3.28.3, a MISSING test
    # binary yields ctest exit 8 but tests="2" failures="0" skipped="1" with
    # status="notrun". Gate on exit 0 AND count AND every case status="run".
    if (-not (Test-Path -LiteralPath $junit)) { Fail 'ctest produced no JUnit output; cannot verify what actually ran.' }
    [xml]$j = Get-Content -LiteralPath $junit
    $tc = @($j.SelectNodes('//testcase'))
    Write-Host ('  ctest exit {0}; JUnit reports {1} testcase(s) for {2} requested target(s)' -f $rc, $tc.Count, $Target.Count)
    if ($rc -ne 0) { Fail ('ctest failed (exit {0}). Exit 8 means "no tests matched" even though the run looked green without --no-tests=error.' -f $rc) }
    if ($tc.Count -ne $Target.Count) { Fail ('ctest ran {0} test(s) but {1} were requested.' -f $tc.Count, $Target.Count) }
    foreach ($t in $Target) {
        $hits = @($tc | Where-Object { $_.name -eq $t })
        if ($hits.Count -ne 1) { Fail ('{0} appears {1} time(s) in the JUnit output; expected exactly 1.' -f $t, $hits.Count) }
        if ($hits[0].status -ne 'run') { Fail ('{0} has status="{1}" (not "run") - it did not execute.' -f $t, $hits[0].status) }
    }
    Write-Host '  every requested target executed exactly once.'
    Write-Host ''
    Write-Host ('SCOPE: {0} of {1} registered C++ targets. This is targeted triage; the full set runs on the' -f $Target.Count, $known.Count)
    Write-Host '       Linux lane and on CI, which is authoritative for MSVC anyway.'
}

# ---------------------------------------------------------------------------
# doctor - the container-side half of `ci doctor`. The host-side half (engine
# mode, isolation, the Containers feature state, image list, disk footprint)
# belongs to the dispatcher, which is the only thing that can see them.
# ---------------------------------------------------------------------------
function Invoke-Doctor {
    param($Tools, $Pins)
    Write-Step 'doctor' 'container-side checks'
    Write-Host '  --- tool paths (resolved at image build, asserted at run) ---'
    foreach ($p in $Tools.PSObject.Properties) { Write-Host ('    {0,-9} {1}' -f $p.Name, $p.Value) }
    Write-Host '  --- pins ---'
    foreach ($p in $Pins.PSObject.Properties) { Write-Host ('    {0,-16} {1}' -f $p.Name, $p.Value) }
    Write-Host '  --- ccache ---'
    if (Test-Path -LiteralPath $Tools.ccache) {
        (Invoke-Capture -Exe $Tools.ccache -Arguments @('--show-stats')).Lines |
            Select-Object -First 12 | ForEach-Object { Write-Host ('    {0}' -f $_) }
    }
    Write-Host '  --- Thermo iAPI DLLs (ABSENT is a hard failure, never a skip) ---'
    Restore-ThermoDlls -Tools $Tools
    Write-Host '  --- git status ---'
    foreach ($r in @(@{ n = 'parent'; p = $Repo }, @{ n = 'FlashIDA'; p = (Join-Path $Repo 'FlashIDA') }, @{ n = 'OpenMS'; p = (Join-Path $Repo 'OpenMS') })) {
        $st = (Invoke-Capture -Exe $Tools.git -Arguments @('-C', $r.p, 'status', '--porcelain')).Lines |
            Where-Object { $_ -ne '' }
        Write-Host ('    {0,-9} {1} change(s)' -f $r.n, @($st).Count)
    }
    Write-Host '  --- C++ target list ---'
    $tg = Get-CiTargets -Tools $Tools
    Write-Host ('    {0} targets parsed from flashida-ci.yml' -f $tg.Count)
    Write-Host ''
    Write-Host '  NOT checked here (only the host dispatcher can see them): the Containers Windows'
    Write-Host '  feature state, which docker engine/isolation this container got, the image list,'
    Write-Host '  and the total disk footprint. Run `ci doctor` on the host for those.'
}

# ---------------------------------------------------------------------------
# Cleanup + the layers that survive a human typing commands in their own
# terminal (design doc section 7, findings 1 and 2). Runs in `finally`, has no
# bypass flag, and is the LAST FOREGROUND ACTION of every invocation.
# ---------------------------------------------------------------------------
function Invoke-Cleanup {
    param($Tools)
    Write-Step '16' 'finally: stage results, restore dll/, delete strays, assert the tree is clean'
    if ($null -eq $Tools) { Write-Host '  (tools never resolved; nothing to clean)'; return }
    $flash = Join-Path $Repo 'FlashIDA'
    $problems = @()

    # 1. Stage the small artefacts before they are deleted, so a failed run is
    #    still diagnosable from the host.
    try {
        $stage = Invoke-Stage
        foreach ($f in @('TestResults.xml', 'TestResults.filtered.xml', 'RegenResults.xml')) {
            $p = Join-Path $Repo $f
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $stage $f) -Force }
        }
        # The log-golden and continuity outputs are written UNCONDITIONALLY by the
        # tests -- design doc section 7 L1: a FAILING comparison run already IS the
        # capture. They have to be staged HERE as well as in step 12b, because
        # Invoke-CSharpLeg aborts on failed>0 long before it reaches step 12b, i.e.
        # in exactly the case where a golden moved and there is something to promote.
        # Skipped when 12b already staged them: Copy-Item -Recurse onto an EXISTING
        # destination nests the source inside it rather than merging.
        foreach ($g in @(
                @{ from = (Join-Path $flash 'bin\log-golden-output'); to = (Join-Path $stage 'goldens\logs'); label = 'log goldens' },
                @{ from = (Join-Path $flash 'bin\continuity-output'); to = (Join-Path $stage 'goldens\continuity'); label = 'continuity goldens' }
            )) {
            if (Test-Path -LiteralPath $g.to) { continue }
            [void](Copy-IfPresent -From $g.from -To $g.to -Label $g.label)
        }
    }
    catch { Write-Host ('  WARNING: could not stage result files: {0}' -f $_.Exception.Message) }

    # 2. Delete the strays. regression-runner.ps1:23-31 copies three support
    #    files into the CURRENT WORKING DIRECTORY (the repo root), and the two
    #    NUnit result files land there too. None of them is gitignored today.
    foreach ($f in @('TestResults.xml', 'TestResults.filtered.xml', 'RegenResults.xml',
            'test_inclusion_list.txt', 'test_fasta.fasta', 'test_target_log.log')) {
        $p = Join-Path $Repo $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Write-Host ('  removed stray {0}' -f $f) }
    }

    # 3. Restore FlashIDA/dll/. All six files are TRACKED, so CI's drift swap
    #    leaves four modified tracked files in the submodule after every run.
    #    There is deliberately NO opt-out flag: the "update the committed DLLs"
    #    workflow is a rare manual act done with the diff shown, and inventing
    #    a fail-open lever on the one mechanism whose silent failure is worst
    #    is not worth the convenience.
    try {
        $co = Invoke-Capture -Exe $Tools.git -Arguments @('-C', $flash, 'checkout', '--', 'dll/')
        if ($co.Code -ne 0) {
            $problems += ('git checkout -- dll/ exited {0}: {1}' -f $co.Code, (($co.Lines -join ' ').Trim()))
        }
        # Gate on the EXIT CODE, not only on the output: an empty Lines from a git
        # that never ran (missing binary, dubious ownership, a broken index) is
        # indistinguishable from a clean tree and would print "verified clean".
        $rd = Invoke-Capture -Exe $Tools.git -Arguments @('-C', $flash, 'status', '--porcelain', '--', 'dll/')
        if ($rd.Code -ne 0) {
            $problems += ('git status -- dll/ exited {0}, so the dll restore could NOT be verified: {1}' -f $rd.Code, (($rd.Lines -join ' ').Trim()))
        }
        else {
            $st = @($rd.Lines | Where-Object { $_ -ne '' })
            if ($st.Count -gt 0) {
                $problems += ('FlashIDA/dll is still dirty after restore: {0}' -f ($st -join '; '))
            }
            else { Write-Host '  FlashIDA/dll restored to HEAD and verified clean.' }
        }
    }
    catch { $problems += ('could not restore FlashIDA/dll: {0}' -f $_.Exception.Message) }

    # 4. L4 - the unconditional golden assertion. This is the ONLY layer that
    #    survives someone running the container from their own terminal, where
    #    no PreToolUse hook exists on any path, so it carries no bypass.
    try {
        $r4 = Invoke-Capture -Exe $Tools.git -Arguments @('-C', $flash, 'status', '--porcelain', '-uall', '--', 'test-data')
        # Gate on the EXIT CODE FIRST. This is the one layer with no other backstop,
        # and an empty Lines from a git that did not run is indistinguishable from a
        # clean tree -- i.e. the gate would pass by not having been evaluated.
        if ($r4.Code -ne 0) {
            $problems += (
                ("git status -- test-data exited {0}, so L4 could NOT be evaluated: " -f $r4.Code) +
                (($r4.Lines -join ' ').Trim())
            )
        }
        else {
            $st = @($r4.Lines | Where-Object { $_ -ne '' })
            # -RegenConfigReference rewrites exactly ONE committed fixture, on purpose,
            # with a warning already printed. Without this exemption the flag can never
            # produce a PASS: its success case IS a dirty test-data. Scoped to that one
            # path -- everything else, and everything under test-data/golden, still fails.
            if ($RegenConfigReference) {
                foreach ($e in @($st | Where-Object { $_ -match 'test-data/config_schema_reference\.json$' })) {
                    Write-Host ('  expected, -RegenConfigReference was passed: {0}' -f $e)
                }
                $st = @($st | Where-Object { $_ -notmatch 'test-data/config_schema_reference\.json$' })
            }
            if ($st.Count -gt 0) {
                Write-Host '  FlashIDA/test-data is NOT clean after this run:'
                $st | ForEach-Object { Write-Host ('    {0}' -f $_) }
                [void](Invoke-Capture -Exe $Tools.git -Arguments @('-C', $flash, 'checkout', '--', 'test-data/golden'))
                $problems += (
                    ("{0} change(s) under FlashIDA/test-data. A non-capture run must never modify it; " -f $st.Count) +
                    "test-data/golden has been reverted. If a golden genuinely moved, stage it with " +
                    "-Command golden-capture and promote it by hand on the host with the diff shown."
                )
            }
            else { Write-Host '  FlashIDA/test-data clean (L4).' }
        }
    }
    catch { $problems += ('could not assert FlashIDA/test-data cleanliness: {0}' -f $_.Exception.Message) }

    # 5. Informational: the parent's own status. `.container-out/` is expected
    #    to show up here until the dispatcher landing adds it to .gitignore.
    try {
        $st = @((Invoke-Capture -Exe $Tools.git -Arguments @('-C', $Repo, 'status', '--porcelain')).Lines | Where-Object { $_ -ne '' })
        Write-Host ('  parent repo: {0} change(s) (informational)' -f $st.Count)
        if ($st -match '\.container-out') {
            Write-Host '    note: /.container-out/ is this lane''s staging dir; the dispatcher landing adds it to .gitignore.'
        }
    }
    catch { }

    if ($problems.Count -gt 0) {
        # Cleanup can turn a PASS into a FAIL. That is intentional.
        if ($script:ExitCode -eq 0) {
            $script:ExitCode = 1
            $script:Verdict = ('FAIL: {0}' -f $problems[0])
        }
        foreach ($p in $problems) { Write-Host ('  CLEANUP PROBLEM: {0}' -f $p) }
    }
}

# ===========================================================================
# main
# ===========================================================================
$tools = $null
try {
    Write-Host ('FLASHIda Windows lane -- {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('script       : {0}' -f $PSCommandPath)
    Write-Host ('command      : {0}{1}' -f $Command, $(if ($Filter) { (' (filter: {0})' -f $Filter) } else { '' }))
    Assert-Repo
    Assert-Locale
    Assert-NoCaptureEnvironment
    $tools = Get-ToolPaths
    $pins = Get-Pins
    Assert-ToolchainPins -Tools $tools -Pins $pins
    Assert-YmlPins -Tools $tools -Pins $pins

    Write-Host ''
    Write-Host 'SCOPE: this run verifies the WORKING TREE as it sits, dirty, on this machine.'
    Write-Host '       CI verifies a COMMIT from a clean recursive checkout. A green run here is'
    Write-Host '       never "green at this SHA", and never a verdict on a float or a golden.'

    switch ($Command) {
        'doctor' {
            Invoke-Doctor -Tools $tools -Pins $pins
            $script:Verdict = 'PASS: container-side doctor checks (pins, tools, locale, Thermo identity gate, target list)'
        }
        'dll' {
            Import-VcVars -Tools $tools
            $bd = Invoke-CppConfigureAndBuild -Tools $tools
            Invoke-DllSwap -Tools $tools -BuildDir $bd
            Invoke-ProvenanceGate -Tools $tools -BuildDir $bd
            $script:Verdict = ('PASS: OpenMS.dll built ({0}) and swapped into FlashIDA/dll; provenance gate green' -f $CppConfig)
        }
        'cpp' {
            Import-VcVars -Tools $tools
            Invoke-CppLeg -Tools $tools
            $script:Verdict = ('PASS: {0} MSVC ctest target(s) built and executed' -f $Target.Count)
        }
        'cs' {
            Import-VcVars -Tools $tools
            $bd = Invoke-CppConfigureAndBuild -Tools $tools
            Invoke-DllSwap -Tools $tools -BuildDir $bd
            Invoke-CSharpLeg -Tools $tools -BuildDir $bd
            $script:Verdict = 'PASS: DLL swap + provenance gate + C# suite + regression + all four gates'
        }
        'golden-capture' {
            Import-VcVars -Tools $tools
            $bd = Invoke-CppConfigureAndBuild -Tools $tools
            Invoke-DllSwap -Tools $tools -BuildDir $bd
            Invoke-CSharpLeg -Tools $tools -BuildDir $bd -StageGoldens
            $script:Verdict = ('PASS: full C# leg + golden staging at {0} (nothing promoted)' -f (Get-StageDir))
        }
    }
}
catch {
    $script:ExitCode = 1
    $script:Verdict = ('FAIL: {0}' -f $_.Exception.Message)
    Write-Host ''
    Write-Host '--- failure detail ---'
    Write-Host ($_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-Host ($_.ScriptStackTrace) }
}
finally {
    try { Invoke-Cleanup -Tools $tools }
    catch {
        if ($script:ExitCode -eq 0) { $script:ExitCode = 1; $script:Verdict = ('FAIL: cleanup itself failed: {0}' -f $_.Exception.Message) }
        Write-Host ('CLEANUP FAILED: {0}' -f $_.Exception.Message)
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host ('--- {0} warning(s) ---' -f $script:Warnings.Count)
        foreach ($w in $script:Warnings) { Write-Host ('  ! {0}' -f $w) }
    }
    if ($script:StagedTo -ne '') { Write-Host ('staged artefacts: {0}' -f $script:StagedTo) }

    # PARTIAL only downgrades a PASS; it never upgrades a FAIL.
    if ($script:ExitCode -eq 0 -and $script:PartialReasons.Count -gt 0) {
        $script:ExitCode = 2
        $script:Verdict = ('PARTIAL: {0} - NOT CI-EQUIVALENT' -f ($script:PartialReasons -join '; '))
    }
    if ([string]::IsNullOrWhiteSpace($script:Verdict)) {
        $script:ExitCode = 1
        $script:Verdict = 'FAIL: the run ended without producing a verdict'
    }

    Write-Host ''
    Write-Host $script:Verdict
    exit $script:ExitCode
}

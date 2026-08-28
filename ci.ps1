<#
.SYNOPSIS
    Windows-host shim for ./ci - the single local command surface for FLASHIda's
    dockerised verification.

.DESCRIPTION
    This file deliberately implements NOTHING. It locates bash (Git for Windows)
    and hands every argument, unchanged, to the `ci` script that sits beside it,
    then propagates that script's exit code verbatim. There is exactly one
    dispatcher, one argument parser and one verdict contract - duplicating any
    of them in PowerShell is how the two surfaces would start to disagree.

    Spec: docs/superpowers/specs/2026-08-27-dockerized-local-ci-design.md
          section 10 (the command surface), section 6 (the exit-code contract).

    EXIT CODES (set by `ci`, passed through unchanged)
        0   PASS      every gate that ran, passed, and nothing was skipped
        1   FAIL      a gate, a test or a tree assertion failed
        2   PARTIAL   something CI does was NOT run here (never CI-equivalent)
        3   INFRA     prerequisite/infrastructure failure; nothing was verified
        64  USAGE     misuse: unknown subcommand, bad flag, missing argument
    This shim adds one of its own:
        3             bash could not be found - see the message it prints

    PORTABILITY (owner decision D5): the repo root is taken from this file's own
    location ($PSScriptRoot). No absolute host path is baked in. No secret is
    read, printed or forwarded - THERMO_DLL_PASSPHRASE only ever lives in the
    operator's own environment.

.EXAMPLE
    .\ci.ps1 doctor
.EXAMPLE
    .\ci.ps1 cpp --full
.EXAMPLE
    .\ci.ps1 cs "test=='Flash.Tests.BridgeSmokeTests'"
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CiArgs
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- the dispatcher lives beside this file; nothing else is assumed ----------
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$ciScript = Join-Path $root 'ci'
if (-not (Test-Path -LiteralPath $ciScript)) {
    Write-Host ''
    Write-Host "FAIL: the dispatcher is missing - expected it beside this shim at $ciScript"
    Write-Host '      ci.ps1 implements no subcommand of its own, by design.'
    exit 3
}

# --- find bash --------------------------------------------------------------
# Git for Windows ships it. WSL's bash.exe is NOT usable here: it would see a
# different filesystem and a different docker CLI, so it is excluded on purpose.
function Test-IsMsysBash {
    param([string] $Exe)
    # The only reliable test. MEASURED on this host: PATH resolves bash.exe to
    # C:\Windows\system32\bash.exe (WSL) and to the WindowsApps alias, both of
    # which mount the drive at /mnt/c - so `bash /c/repo/ci` fails with
    # "No such file or directory" and the whole shim silently targets the wrong
    # filesystem. Name-based checks alone are not enough; ask uname.
    try {
        $u = & $Exe -c 'uname -s' 2>$null
    } catch {
        return $false
    }
    if (-not $u) { return $false }
    $first = ([string[]] $u)[0]
    if ([string]::IsNullOrWhiteSpace($first)) { return $false }
    return ($first -match '^(MINGW|MSYS|CYGWIN)')
}

function Find-Bash {
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1. An explicit choice always wins.
    if ($env:FLCI_BASH) { $candidates.Add($env:FLCI_BASH) }

    # 2. Where Git for Windows actually puts it.
    foreach ($p in @(
            "$env:ProgramFiles\Git\bin\bash.exe",
            "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
            "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
            "$env:ProgramFiles\Git\usr\bin\bash.exe")) {
        if ($p) { $candidates.Add($p) }
    }

    # 3. Derived from git.exe, for a Git installed somewhere else entirely.
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent ([string[]] ($git | ForEach-Object { $_.Source }))[0])
        if ($gitRoot) {
            $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
            $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
        }
    }

    # 4. PATH last, because on Windows PATH usually finds WSL first.
    $onPath = Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        foreach ($c in @($onPath)) { $candidates.Add($c.Source) }
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrEmpty($c)) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        # Never even START these: launching WSL can boot a VM.
        if ($c -like "$env:SystemRoot\*") { continue }
        if ($c -like '*\WindowsApps\*') { continue }
        if (Test-IsMsysBash -Exe $c) { return $c }
    }
    return $null
}

$bash = Find-Bash
if (-not $bash) {
    Write-Host ''
    Write-Host 'FAIL: no MSYS/Git-Bash was found, so the dispatcher could not run - nothing was verified.'
    Write-Host '  FIX: install Git for Windows (it ships bash at'
    Write-Host '       C:\Program Files\Git\bin\bash.exe), or point FLCI_BASH at one:'
    Write-Host '         $env:FLCI_BASH = "C:\Program Files\Git\bin\bash.exe"'
    Write-Host '  NOTE: WSL bash is deliberately rejected (uname says Linux, not MINGW/MSYS).'
    Write-Host '        It mounts this drive at /mnt/c and talks to a different docker CLI,'
    Write-Host '        so it would run the containers against a different filesystem.'
    exit 3
}

# The script path has to be handed to bash in ITS OWN namespace. Git Bash does
# not translate a "C:/..." argument for the script operand - it looks for that
# path under the MSYS root and reports "No such file or directory" (measured).
# Ask the bash we actually found, via cygpath; fall back to the /c/... mount
# convention only if cygpath is not there.
function ConvertTo-BashPath {
    param([string] $BashExe, [string] $WindowsPath)

    $viaCygpath = $null
    try {
        $viaCygpath = & $BashExe -c "cygpath -u '$WindowsPath'" 2>$null
    } catch {
        $viaCygpath = $null
    }
    if ($viaCygpath) {
        $line = ([string[]] $viaCygpath)[0]
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
    }

    $slashed = $WindowsPath -replace '\\', '/'
    if ($slashed -match '^([A-Za-z]):(/.*)$') {
        return '/' + $matches[1].ToLower() + $matches[2]
    }
    return $slashed
}

$ciForBash = ConvertTo-BashPath -BashExe $bash -WindowsPath $ciScript

$argv = @($ciForBash)
if ($null -ne $CiArgs) {
    foreach ($a in $CiArgs) { $argv += $a }
}

# Run it. Output is inherited, so the single PASS/FAIL/PARTIAL verdict line the
# dispatcher prints last is the last line the operator sees here too.
& $bash @argv
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code

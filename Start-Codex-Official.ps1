<#
.SYNOPSIS
    Clean baseline launcher for the official Microsoft Store Codex app.

.DESCRIPTION
    Launches the *unmodified* Store-installed Codex executable with NO
    OmniRoute environment overrides, NO bridge, NO isolated runtime home,
    and NO helper processes.

    This is the "control" launcher: when the user wants vanilla Codex
    behavior with their normal logged-in profile and normal reasoning quota.

    Companion: Start-Codex-OmniRoute.ps1 (OmniRoute mode).

.PARAMETER DryRun
    Resolve the Codex executable and print what would be launched, but do
    not actually start the app. Useful for verification scripts.

.NOTES
    - Resolves the Store-installed package dynamically via
      Get-AppxPackage OpenAI.Codex; the absolute install path is not
      hardcoded.
    - Inherits the user's environment unchanged. No CODEX_HOME,
      OMNIROUTE_*, CODEX_BRIDGE_*, or CODEX_ELECTRON_USER_DATA_PATH is set
      by this script.
    - Exits non-zero if the official package is not installed.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-CodexExecutable {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw "Official Codex Microsoft Store app is not installed (Get-AppxPackage OpenAI.Codex returned nothing). Install it from the Microsoft Store first."
    }
    if ($pkg -is [array]) { $pkg = $pkg[0] }

    $candidates = @(
        (Join-Path $pkg.InstallLocation 'app\Codex.exe'),
        (Join-Path $pkg.InstallLocation 'Codex.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    throw "Found Codex package at '$($pkg.InstallLocation)' but could not locate Codex.exe (looked in app\\Codex.exe and Codex.exe). The Store package layout may have changed."
}

$exe = Resolve-CodexExecutable
Write-Host "[official] Codex executable: $exe"
Write-Host "[official] Mode: clean baseline (no OmniRoute env, no bridge, no isolated runtime home)."

if ($DryRun) {
    Write-Host "[official] DryRun: not launching."
    [pscustomobject]@{
        Mode            = 'official'
        Executable      = $exe
        Args            = @()
        EnvOverrides    = @{}
        BridgeProcesses = @()
        DryRun          = $true
    } | Format-List
    exit 0
}

# Launch detached. We intentionally do not pipe stdio so the GUI app
# behaves identically to a Start Menu launch.
Start-Process -FilePath $exe | Out-Null
Write-Host "[official] Launched."

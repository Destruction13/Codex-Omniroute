<#
.SYNOPSIS
    Clean baseline launcher for the official Microsoft Store Codex app.

.DESCRIPTION
    Launches the *unmodified* Microsoft Store Codex app with NO
    OmniRoute environment overrides, NO bridge, and NO helper processes.

    Before launching, this script automatically reverses any OmniRoute
    side-effects: if a backup of the user's original config.toml is
    present (left by Start-Codex-OmniRoute.ps1), it is restored, and any
    running managed bridge process is stopped. The user therefore gets
    pristine vanilla Codex even if they had OmniRoute mode active
    moments before.

    Companion: Start-Codex-OmniRoute.ps1 (OmniRoute mode).

.PARAMETER DryRun
    Resolve the Codex package and print what would be launched, but do not
    actually start the app. Useful for verification scripts.

.PARAMETER NoAutoRestore
    Skip the automatic config restore + bridge shutdown step. Mostly
    useful for verification scripts that want to inspect the current
    OmniRoute-managed state without disturbing it.

.NOTES
    - Resolves the Store-installed package dynamically via
      Get-AppxPackage OpenAI.Codex; the AppUserModelID is not hardcoded.
    - Inherits the user's environment unchanged. No CODEX_HOME,
      OMNIROUTE_*, CODEX_BRIDGE_*, or CODEX_ELECTRON_USER_DATA_PATH is set
      by this script.
    - Exits non-zero if the official package is not installed.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoAutoRestore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-CodexAppx {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw "Official Codex Microsoft Store app is not installed (Get-AppxPackage OpenAI.Codex returned nothing). Install it from the Microsoft Store first."
    }
    if ($pkg -is [array]) { $pkg = $pkg[0] }

    $candidates = @(
        (Join-Path $pkg.InstallLocation 'app\Codex.exe'),
        (Join-Path $pkg.InstallLocation 'Codex.exe')
    )
    $exe = $null
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }
    if (-not $exe) {
        throw "Found Codex package at '$($pkg.InstallLocation)' but could not locate Codex.exe (looked in app\\Codex.exe and Codex.exe). The Store package layout may have changed."
    }

    $appId = 'App'
    try {
        $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifestPath) {
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
            $appNode = $manifest.Package.Applications.Application
            if ($appNode -and $appNode.Id) { $appId = $appNode.Id }
        }
    } catch { }

    return [pscustomobject]@{
        AumId      = "$($pkg.PackageFamilyName)!$appId"
        ExePath    = $exe
        InstallLoc = $pkg.InstallLocation
        Package    = $pkg
    }
}

function Start-CodexViaAppx {
    param(
        [Parameter(Mandatory = $true)][string]$AumId,
        [string]$Arguments = ''
    )

    if (-not ('CodexOfficialAppxActivator' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class CodexOfficialApplicationActivationManager {}

[Flags]
public enum CodexOfficialActivateOptions {
    None = 0,
    DesignMode = 1,
    NoErrorUI = 2,
    NoSplashScreen = 4
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICodexOfficialApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        CodexOfficialActivateOptions options,
        out uint processId);
}

public static class CodexOfficialAppxActivator {
    public static int Activate(string appUserModelId, string arguments, out uint processId) {
        var manager = (ICodexOfficialApplicationActivationManager)new CodexOfficialApplicationActivationManager();
        return manager.ActivateApplication(
            appUserModelId,
            arguments ?? "",
            CodexOfficialActivateOptions.NoErrorUI,
            out processId);
    }
}
'@
    }

    [uint32]$activatedPid = 0
    $hr = [CodexOfficialAppxActivator]::Activate($AumId, $Arguments, [ref]$activatedPid)
    if ($hr -ne 0) {
        throw ("AppX activation failed for {0} (HRESULT 0x{1:X8})." -f $AumId, $hr)
    }
    return $activatedPid
}

# ----------------------------------------------------------------------------
# Auto-restore helpers (reverse OmniRoute side-effects on ~/.codex/config.toml)
# ----------------------------------------------------------------------------

$ManagedBlockBegin = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$ManagedBlockEnd   = '# <<< codex-omniroute-managed'

function Remove-OmniRouteManagedBlock {
    param([string]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }
    $pattern = '(?ms)^[\t ]*' + [regex]::Escape($ManagedBlockBegin) + '[\s\S]*?' + [regex]::Escape($ManagedBlockEnd) + '[\t ]*\r?\n?'
    $stripped = [regex]::Replace($Content, $pattern, '')
    return [regex]::Replace($stripped, '(\r?\n){3,}', "`r`n`r`n")
}

function Invoke-AutoRestore {
    $codexHome  = Join-Path $env:USERPROFILE '.codex'
    $configPath = Join-Path $codexHome 'config.toml'
    $backupPath = Join-Path $codexHome 'config.toml.codex-omniroute-backup'

    # Stop any OmniRoute-managed bridge. The pid file lives next to this
    # script (same convention used by Start-Codex-OmniRoute.ps1).
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $bridgePid = Join-Path $scriptDir 'bridge.pid'
    if (Test-Path -LiteralPath $bridgePid) {
        try {
            $pidText = (Get-Content -LiteralPath $bridgePid -Raw).Trim()
            if ($pidText -match '^\d+$') {
                $existing = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
                if ($existing -and $existing.ProcessName -match '^node') {
                    Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue
                    Write-Host "[official] stopped OmniRoute bridge (pid=$pidText)"
                }
            }
        } catch { }
        Remove-Item -LiteralPath $bridgePid -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $backupPath) {
        $backup = Get-Content -LiteralPath $backupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        if ($backup.Length -eq 0) {
            if (Test-Path -LiteralPath $configPath) {
                Remove-Item -LiteralPath $configPath -Force
                Write-Host "[official] removed OmniRoute-managed config $configPath (no original existed)"
            }
        } else {
            [System.IO.File]::WriteAllText($configPath, $backup, $utf8NoBom)
            Write-Host "[official] restored original config from $backupPath"
        }
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        return
    }

    # No backup -- strip any orphan managed block in place.
    if (Test-Path -LiteralPath $configPath) {
        $existing = Get-Content -LiteralPath $configPath -Raw
        if ($existing -and $existing.Contains($ManagedBlockBegin)) {
            $stripped = Remove-OmniRouteManagedBlock -Content $existing
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($configPath, $stripped, $utf8NoBom)
            Write-Host "[official] stripped OmniRoute managed block from $configPath (no backup available)"
        }
    }
}

if (-not $NoAutoRestore) {
    Invoke-AutoRestore
}

$appx = Resolve-CodexAppx
Write-Host "[official] Codex AppUserModelID: $($appx.AumId)"
Write-Host "[official] Codex package executable: $($appx.ExePath)"
Write-Host "[official] Mode: clean baseline (no OmniRoute env, no bridge)."

if ($DryRun) {
    Write-Host "[official] DryRun: not launching."
    [pscustomobject]@{
        Mode            = 'official'
        AumId           = $appx.AumId
        Executable      = $appx.ExePath
        Args            = @()
        EnvOverrides    = @{}
        BridgeProcesses = @()
        DryRun          = $true
    } | Format-List
    exit 0
}

# Launch through the AppX broker, matching Start Menu semantics. Current
# Store packages reject direct CreateProcess against WindowsApps\...\Codex.exe
# with "Access is denied".
$activatedPid = Start-CodexViaAppx -AumId $appx.AumId
if ($activatedPid -gt 0) {
    Write-Host "[official] Launched via AppX activation (pid=$activatedPid)."
} else {
    Write-Host "[official] AppX activation succeeded."
}

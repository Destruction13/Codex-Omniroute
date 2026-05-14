<#
.SYNOPSIS
    Clean baseline launcher for the official Microsoft Store Codex app.

.DESCRIPTION
    Launches the *unmodified* Microsoft Store Codex app with NO
    OmniRoute environment overrides, NO bridge, NO isolated runtime home,
    and NO helper processes.

    This is the "control" launcher: when the user wants vanilla Codex
    behavior with their normal logged-in profile and normal reasoning quota.

    Companion: Start-Codex-OmniRoute.ps1 (OmniRoute mode).

.PARAMETER DryRun
    Resolve the Codex package and print what would be launched, but do not
    actually start the app. Useful for verification scripts.

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
    [switch]$DryRun
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

    [uint32]$pid = 0
    $hr = [CodexOfficialAppxActivator]::Activate($AumId, $Arguments, [ref]$pid)
    if ($hr -ne 0) {
        throw ("AppX activation failed for {0} (HRESULT 0x{1:X8})." -f $AumId, $hr)
    }
    return $pid
}

$appx = Resolve-CodexAppx
Write-Host "[official] Codex AppUserModelID: $($appx.AumId)"
Write-Host "[official] Codex package executable: $($appx.ExePath)"
Write-Host "[official] Mode: clean baseline (no OmniRoute env, no bridge, no isolated runtime home)."

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
$pid = Start-CodexViaAppx -AumId $appx.AumId
if ($pid -gt 0) {
    Write-Host "[official] Launched via AppX activation (pid=$pid)."
} else {
    Write-Host "[official] AppX activation succeeded."
}

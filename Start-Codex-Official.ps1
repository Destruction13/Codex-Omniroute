<#
.SYNOPSIS
    Clean baseline launcher for the official Microsoft Store Codex app.

.DESCRIPTION
    Launches the *unmodified* Microsoft Store Codex app with NO
    OmniRoute environment overrides, NO bridge, and NO helper processes.

    Before launching, this script automatically reverses any OmniRoute
    side-effects:
      - if a backup of the user's original config.toml is present (left
        by Start-Codex-OmniRoute.ps1), it is restored;
      - if a backup of the user's original auth.json is present, it is
        restored (or the managed sentinel file is deleted if no original
        existed);
      - any running managed bridge process is stopped.
    The user therefore gets pristine vanilla Codex — including their real
    ChatGPT OAuth session — even if they had OmniRoute mode active
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

# Strict-mode-safe Windows-host detection. Touching `$IsWindows` directly
# fails on Windows PowerShell 5.x (the variable is undefined and strict-mode
# treats that as an error). Mirrors Test-WindowsHost in
# Start-Codex-OmniRoute.ps1; duplicated here so the official launcher has no
# dependency on the OmniRoute one.
function Test-WindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    $winVar = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($winVar) { return [bool]$winVar.Value }
    if ($env:OS -eq 'Windows_NT') { return $true }
    return $false
}

function Resolve-CodexAppx {
    if (-not (Test-WindowsHost)) {
        # Allow -DryRun on non-Windows (CI / verifier) without trying to call
        # Get-AppxPackage (which only exists on Windows). The real activation
        # path is Windows-only anyway.
        return [pscustomobject]@{
            AumId      = 'NON-WINDOWS-STUB!App'
            ExePath    = '/dev/null'
            InstallLoc = '/dev/null'
            Package    = $null
        }
    }
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

# Sentinel API key written into the managed ~/.codex/auth.json by
# Start-Codex-OmniRoute.ps1. Keep in sync with $ManagedAuthSentinelApiKey
# there and MANAGED_AUTH_SENTINEL in codex-openai-omniroute-bridge.mjs.
$ManagedAuthSentinelApiKey = 'sk-omniroute-managed'

function Test-IsOmniRouteManagedAuth {
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    try {
        $obj = $Content | ConvertFrom-Json -ErrorAction Stop
    } catch { return $false }
    if (-not $obj) { return $false }
    $hasMarker = $false
    try {
        if ($obj.PSObject.Properties.Name -contains '_codex_omniroute') {
            $marker = $obj.'_codex_omniroute'
            if ($marker -and $marker.managed) { $hasMarker = $true }
        }
    } catch { }
    $hasSentinel = $false
    try {
        if ($obj.PSObject.Properties.Name -contains 'OPENAI_API_KEY') {
            if ([string]$obj.OPENAI_API_KEY -eq $ManagedAuthSentinelApiKey) {
                $hasSentinel = $true
            }
        }
    } catch { }
    return ($hasMarker -or $hasSentinel)
}

function Remove-OmniRouteManagedBlock {
    param([string]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }
    $pattern = '(?ms)^[\t ]*' + [regex]::Escape($ManagedBlockBegin) + '[\s\S]*?' + [regex]::Escape($ManagedBlockEnd) + '[\t ]*\r?\n?'
    $stripped = [regex]::Replace($Content, $pattern, '')
    return [regex]::Replace($stripped, '(\r?\n){3,}', "`r`n`r`n")
}

function Restore-OmniRouteConfigToml {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        if ($backup.Length -eq 0) {
            if (Test-Path -LiteralPath $ConfigPath) {
                Remove-Item -LiteralPath $ConfigPath -Force
                Write-Host "[official] removed OmniRoute-managed config $ConfigPath (no original existed)"
            }
        } else {
            [System.IO.File]::WriteAllText($ConfigPath, $backup, $utf8NoBom)
            Write-Host "[official] restored original config from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    # No backup -- strip any orphan managed block in place.
    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = Get-Content -LiteralPath $ConfigPath -Raw
        if ($existing -and $existing.Contains($ManagedBlockBegin)) {
            $stripped = Remove-OmniRouteManagedBlock -Content $existing
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($ConfigPath, $stripped, $utf8NoBom)
            Write-Host "[official] stripped OmniRoute managed block from $ConfigPath (no backup available)"
        }
    }
}

function Restore-OmniRouteAuthJson {
    param(
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        if ($backup.Length -eq 0) {
            if (Test-Path -LiteralPath $AuthPath) {
                Remove-Item -LiteralPath $AuthPath -Force
                Write-Host "[official] removed OmniRoute-managed auth.json $AuthPath (no original existed)"
            }
        } else {
            [System.IO.File]::WriteAllText($AuthPath, $backup, $utf8NoBom)
            Write-Host "[official] restored original auth.json from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    # No backup -- best-effort: if the live file is our managed sentinel,
    # remove it; otherwise leave the user's file untouched.
    if (Test-Path -LiteralPath $AuthPath) {
        $existing = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and (Test-IsOmniRouteManagedAuth -Content $existing)) {
            Remove-Item -LiteralPath $AuthPath -Force
            Write-Host "[official] removed orphan OmniRoute-managed auth.json $AuthPath (no backup available)"
        }
    }
}

function Invoke-AutoRestore {
    # USERPROFILE is Windows-only; on non-Windows hosts (verifier smoke)
    # fall back to $HOME so this launcher matches the layout
    # Start-Codex-OmniRoute.ps1 used.
    $codexHomeRoot = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if (-not $codexHomeRoot) {
        Write-Warning "[official] cannot resolve user home: USERPROFILE and HOME are both empty; skipping auto-restore."
        return
    }
    $codexHome      = Join-Path $codexHomeRoot '.codex'
    $configPath     = Join-Path $codexHome 'config.toml'
    $backupPath     = Join-Path $codexHome 'config.toml.codex-omniroute-backup'
    $authPath       = Join-Path $codexHome 'auth.json'
    $authBackupPath = Join-Path $codexHome 'auth.json.codex-omniroute-backup'

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

    Restore-OmniRouteConfigToml -ConfigPath $configPath -BackupPath $backupPath
    Restore-OmniRouteAuthJson   -AuthPath   $authPath   -BackupPath $authBackupPath
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

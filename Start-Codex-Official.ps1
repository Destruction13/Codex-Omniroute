<#
.SYNOPSIS
    Clean baseline launcher for the official Microsoft Store Codex app.

.DESCRIPTION
    Launches the *unmodified* Microsoft Store Codex app with no OmniRoute
    runtime overrides, no bridge, and no helper processes.

    Codex OmniRoute now uses the same shared Codex home as official Codex:
    %USERPROFILE%\.codex. The OmniRoute contour is selected only by the
    OmniRoute launcher's process-level -c overrides. This official launcher
    stops the managed bridge, clears stale legacy CODEX_HOME/PATH values from
    older isolated-home builds, performs legacy cleanup if needed, and
    activates Codex normally.

    For users upgrading from earlier versions (PR #3 or PR #2) we DO
    still sweep up any legacy artifacts those launchers left in the
    user's real ~/.codex (managed block, sentinel auth.json,
    *.codex-omniroute-backup files). That sweep is a one-shot
    reverse-of-old-architecture: subsequent launches see nothing to
    clean.

.PARAMETER DryRun
    Resolve the Codex package and print what would be launched, but do
    not actually start the app. Useful for verification scripts.

.PARAMETER NoAutoRestore
    Skip the auto-stop of the managed bridge and the legacy-cleanup
    pass. Mostly useful for verification scripts that want to inspect
    the current state without disturbing it.

.NOTES
    - Resolves the Store-installed package dynamically via
      Get-AppxPackage OpenAI.Codex; the AppUserModelID is not hardcoded.
    - Sets no OMNIROUTE_*, CODEX_BRIDGE_*, or
      CODEX_ELECTRON_USER_DATA_PATH values. The only user-environment
      mutation it may perform is clearing stale values left by older
      isolated-home OmniRoute builds.
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

function Test-SameEnvironmentValue {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Publish-UserEnvironmentChange {
    if (-not (Test-WindowsHost)) { return }

    if (-not ('CodexOfficialEnvBroadcaster' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexOfficialEnvBroadcaster {
    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
    private const uint WM_SETTINGCHANGE = 0x001A;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);

    public static void BroadcastEnvironmentChange() {
        UIntPtr result;
        SendMessageTimeout(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            UIntPtr.Zero,
            "Environment",
            SMTO_ABORTIFHUNG,
            5000,
            out result);
    }
}
'@
    }

    try { [CodexOfficialEnvBroadcaster]::BroadcastEnvironmentChange() } catch {}
}

function Clear-StaleUserCodexHomeOverride {
    param([Parameter(Mandatory = $true)][string]$IsolatedHome)
    if (-not (Test-WindowsHost)) { return }

    $currentUserCodexHome = [System.Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
    if (Test-SameEnvironmentValue $currentUserCodexHome $IsolatedHome) {
        [System.Environment]::SetEnvironmentVariable('CODEX_HOME', $null, 'User')
        Publish-UserEnvironmentChange
        Write-Host "[official] cleared stale user-scope CODEX_HOME override"
    }
}

function Clear-StaleTaskkillShimPathOverride {
    param([Parameter(Mandatory = $true)][string]$ShimDir)
    if (-not (Test-WindowsHost)) { return }
    if ([string]::IsNullOrWhiteSpace($ShimDir)) { return }

    $currentUserPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if ([string]::IsNullOrWhiteSpace($currentUserPath)) { return }
    $parts = @($currentUserPath -split ';')
    if ($parts.Count -eq 0) { return }
    if (-not (Test-SameEnvironmentValue $parts[0] $ShimDir)) { return }
    $rest = @($parts | Select-Object -Skip 1)
    $newPath = ($rest -join ';')
    if ([string]::IsNullOrWhiteSpace($newPath)) { $newPath = $null }
    [System.Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Publish-UserEnvironmentChange
    Write-Host "[official] cleared stale user-scope PATH taskkill shim prefix"
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
# Legacy PR-#2 / PR-#3 cleanup (managed block + sentinel auth.json)
#
# The shared-home launcher does NOT write either into the user's real ~/.codex,
# so this cleanup is purely a one-shot reverse-of-old-architecture for users
# upgrading from earlier repo versions. On a fresh install or after the first
# cleanup pass, it finds nothing and exits.
# ----------------------------------------------------------------------------

$LegacyManagedBlockBegin       = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$LegacyManagedBlockEnd         = '# <<< codex-omniroute-managed'
$LegacyManagedAuthSentinelKey  = 'sk-omniroute-managed'

function Remove-LegacyManagedBlockText {
    param([string]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }
    $pattern = '(?ms)^[\t ]*' + [regex]::Escape($LegacyManagedBlockBegin) + '[\s\S]*?' + [regex]::Escape($LegacyManagedBlockEnd) + '[\t ]*\r?\n?'
    $stripped = [regex]::Replace($Content, $pattern, '')
    return [regex]::Replace($stripped, '(\r?\n){3,}', "`r`n`r`n")
}

function Test-IsLegacyManagedAuth {
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
            if ([string]$obj.OPENAI_API_KEY -eq $LegacyManagedAuthSentinelKey) {
                $hasSentinel = $true
            }
        }
    } catch { }
    return ($hasMarker -or $hasSentinel)
}

function Restore-LegacyConfigToml {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        if ($backup.Length -eq 0) {
            if (Test-Path -LiteralPath $ConfigPath) {
                Remove-Item -LiteralPath $ConfigPath -Force
                Write-Host "[official] legacy cleanup: removed managed-only config.toml $ConfigPath"
            }
        } else {
            [System.IO.File]::WriteAllText($ConfigPath, $backup, $utf8NoBom)
            Write-Host "[official] legacy cleanup: restored original config.toml from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = Get-Content -LiteralPath $ConfigPath -Raw
        if ($existing -and $existing.Contains($LegacyManagedBlockBegin)) {
            $stripped = Remove-LegacyManagedBlockText -Content $existing
            [System.IO.File]::WriteAllText($ConfigPath, $stripped, $utf8NoBom)
            Write-Host "[official] legacy cleanup: stripped managed block from $ConfigPath"
        }
    }
}

function Restore-LegacyAuthJson {
    param(
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        if ($backup.Length -eq 0) {
            if (Test-Path -LiteralPath $AuthPath) {
                $existing = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction SilentlyContinue
                if ($null -ne $existing -and (Test-IsLegacyManagedAuth -Content $existing)) {
                    Remove-Item -LiteralPath $AuthPath -Force
                    Write-Host "[official] legacy cleanup: removed sentinel auth.json $AuthPath"
                }
            }
        } else {
            [System.IO.File]::WriteAllText($AuthPath, $backup, $utf8NoBom)
            Write-Host "[official] legacy cleanup: restored original auth.json from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    if (Test-Path -LiteralPath $AuthPath) {
        $existing = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and (Test-IsLegacyManagedAuth -Content $existing)) {
            Remove-Item -LiteralPath $AuthPath -Force
            Write-Host "[official] legacy cleanup: removed orphan sentinel auth.json $AuthPath"
        }
    }
}

function Stop-ManagedBridge {
    param([string]$PidPath)
    if (-not (Test-Path -LiteralPath $PidPath)) { return }
    try {
        $pidText = (Get-Content -LiteralPath $PidPath -Raw).Trim()
    } catch { return }
    if (-not ($pidText -match '^\d+$')) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return
    }
    $existingPid = [int]$pidText
    try {
        $proc = Get-Process -Id $existingPid -ErrorAction Stop
        if ($proc.ProcessName -match '^node') {
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            Write-Host "[official] stopped OmniRoute bridge (pid=$existingPid)"
        }
    } catch { } # already gone
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Stop-ManagedApplyPatchRewriter {
    param([string]$PidPath)
    if (-not (Test-Path -LiteralPath $PidPath)) { return }
    try {
        $pidText = (Get-Content -LiteralPath $PidPath -Raw).Trim()
    } catch { return }
    if (-not ($pidText -match '^\d+$')) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return
    }
    $existingPid = [int]$pidText
    try {
        $proc = Get-Process -Id $existingPid -ErrorAction Stop
        if ($proc.ProcessName -match '^node') {
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            Write-Host "[official] stopped OmniRoute apply_patch rewriter (pid=$existingPid)"
        }
    } catch { }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Invoke-ConfigRepairIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$ScriptDir
    )
    $repairTool = Join-Path $ScriptDir 'tools\Repair-CodexConfig.ps1'
    if (-not (Test-Path -LiteralPath $repairTool)) { return }
    try {
        & $repairTool -CodexHome $CodexHome -Quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[official] config repair helper exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Warning "[official] config repair helper failed: $($_.Exception.Message)"
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

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $bridgePidPath = Join-Path $scriptDir 'bridge.pid'
    $applyPatchRewriterPidPath = Join-Path $scriptDir 'apply_patch_rewriter.pid'
    $isolatedHome = Join-Path $scriptDir '.codex-omniroute-home'
    $taskkillShimDir = Join-Path $isolatedHome 'bin'

    Stop-ManagedBridge -PidPath $bridgePidPath
    Stop-ManagedApplyPatchRewriter -PidPath $applyPatchRewriterPidPath
    Clear-StaleUserCodexHomeOverride -IsolatedHome $isolatedHome
    Clear-StaleTaskkillShimPathOverride -ShimDir $taskkillShimDir

    # Legacy cleanup: only acts if PR-#2 / PR-#3 artifacts are present.
    Restore-LegacyConfigToml -ConfigPath $configPath -BackupPath $backupPath
    Restore-LegacyAuthJson   -AuthPath   $authPath   -BackupPath $authBackupPath
    Invoke-ConfigRepairIfNeeded -CodexHome $codexHome -ScriptDir $scriptDir
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

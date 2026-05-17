<#
.SYNOPSIS
    OmniRoute launcher (Variant 3): official Codex with main reasoning
    rerouted to OmniRoute, via a narrowly-isolated CODEX_HOME.

.DESCRIPTION
    Codex OmniRoute is intentionally a thin mode switch on top of the
    unmodified Microsoft Store Codex app. The architecture has three
    moving parts:

      1. A local Node bridge (codex-openai-omniroute-bridge.mjs) that:
           - reroutes /v1/responses and /v1/chat/completions to OmniRoute;
           - forwards everything else (compact, dictation, models cache,
             account stuff) to the official upstream unchanged.

      2. An isolated CODEX_HOME (".codex-omniroute-home" next to this
         launcher) seeded from the user's real ~/.codex:
             auth.json         <- copied from user's real auth.json
                                  (keeps the user signed in with the SAME
                                  ChatGPT account; fast mode + ChatGPT
                                  credits keep working).
             models_cache.json <- copied if present, so the bridge's
                                  /v1/models route has data.
             config.toml       <- written by this launcher; selects
                                  model_provider = "omniroute_bridge"
                                  pointing at the bridge.
         state_5.sqlite is deliberately absent in the isolated dir so
         Codex Desktop starts with an empty thread store and, on the
         first new thread, reads model_provider from the freshly-written
         config.toml (the very mechanism that worked in the original
         repo). The user's real ~/.codex/state_5.sqlite (full chat
         history) is NEVER touched.

      3. The launcher exports CODEX_HOME=<isolated path> into its own
         process environment BEFORE the AppX activation, so that the
         broker hands it to Codex.exe. USERPROFILE / APPDATA / HOME /
         LOCALAPPDATA / TEMP / TMP are NOT overridden -- so apply_patch,
         MCP, git, rg, file dialogs, ~/.gitconfig, ~/.ssh continue to
         resolve against the user's real Windows profile.

    The user's real %USERPROFILE%\.codex directory is NEVER modified.
    No backup, no managed-block append, no auth.json sentinel. As a
    result there is no restore-of-real-config to do on the way back
    out -- the official launcher just stops the bridge.

    For users upgrading from earlier versions (PR #3 + earlier) we DO
    sweep up any legacy artifacts left in the user's real ~/.codex by
    those launchers: a leftover managed block in config.toml, a
    sentinel auth.json, and the *.codex-omniroute-backup files. The
    sweep is a best-effort one-shot reverse-of-PR-#3 so the user does
    not have to manually clean their profile when switching to this
    version.

    Codex.exe itself is launched through the AppX activation broker
    (IApplicationActivationManager), exactly the way Start-Menu and
    Start-Codex-Official.ps1 launch it. This preserves Microsoft Store
    package identity for Codex AND for every child shell it spawns, so
    apply_patch.bat, codex-command-runner.exe, rg.exe, and any other
    bundled CLI tool resolve and execute correctly. No PATH prepend, no
    shim, no rewriter daemon, no payload copy is required.

.PARAMETER NoCodex
    Start the bridge and seed the isolated CODEX_HOME, but do NOT launch
    the Codex GUI. Used by verify-codex-omniroute.ps1.

.PARAMETER Restore
    Stop the managed bridge and wipe the isolated CODEX_HOME directory.
    Also reverses any legacy PR-#3 artifacts in the user's real ~/.codex
    (managed block in config.toml, sentinel auth.json, backup files).
    Does not launch Codex.

.PARAMETER DryRun
    Print what would be done (port choice, isolated CODEX_HOME path)
    without starting the bridge, seeding the isolated dir, or
    launching Codex.

.PARAMETER BridgePort
    Preferred bridge port. The launcher will search nearby ports if this
    one is busy. Default 20333.

.PARAMETER ProviderJson
    Path to omniroute-provider.json. Defaults to ./omniroute-provider.json
    relative to the script. May also be configured via env
    OMNIROUTE_PROVIDER_JSON, OMNIROUTE_BASE_URL+OMNIROUTE_API_KEY, or via
    ~/.config/opencode/auth.json (see codex-openai-omniroute-bridge.mjs).

.PARAMETER OpenProject
    Optional path to a project. If set, Codex is launched with
    `--open-project <path>`. Default: do not pre-open a project (Codex
    shows its normal project picker over the user's real filesystem).

.PARAMETER NoFreeformApplyPatch
    Do not emit `experimental_use_freeform_apply_patch = true` in the
    isolated config.toml. Default: emit it as a cheap safety net. Under
    AppX activation, apply_patch.bat works natively and this flag is
    not strictly required.

.NOTES
    - Never modifies the Microsoft Store Codex package.
    - Never modifies %USERPROFILE%\.codex (the user's real Codex profile).
    - The isolated CODEX_HOME is regenerated on every launch; only
      auth.json + models_cache.json are seeded from the user's real
      profile, plus a freshly-written config.toml. state_5.sqlite is
      deliberately absent so Desktop starts with an empty thread store.
    - On -Restore, the isolated CODEX_HOME is removed and any legacy
      PR-#3 artifacts in the user's real ~/.codex are reversed.
#>

[CmdletBinding()]
param(
    [switch]$NoCodex,
    [switch]$Restore,
    [switch]$DryRun,
    [int]$BridgePort = 20333,
    [string]$ProviderJson = './omniroute-provider.json',
    [string]$OpenProject = '',
    [switch]$NoFreeformApplyPatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

# Legacy markers from PR #2 / PR #3 (managed-block-in-real-config-toml and
# managed-auth-sentinel). Kept here ONLY so the cleanup pass on launch /
# -Restore can recognize and reverse them. The current architecture does
# NOT write either of these into the user's real ~/.codex.
$LegacyManagedBlockBegin       = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$LegacyManagedBlockEnd         = '# <<< codex-omniroute-managed'
$LegacyManagedAuthSentinelKey  = 'sk-omniroute-managed'

# Name of the isolated CODEX_HOME directory under the script root.
$IsolatedHomeDirName = '.codex-omniroute-home'

# ----------------------------------------------------------------------------
# Host platform detection
#
# Touching `$IsWindows` directly is unsafe: Windows PowerShell 5.x does not
# define it, and under `Set-StrictMode -Version Latest` an undefined variable
# is a hard error. This helper resolves the host platform without ever
# evaluating `$IsWindows` in a way that the strict-mode parser would reject.
# It returns $true on:
#   - Windows PowerShell 5.x (PSEdition = 'Desktop' is Windows-only by design)
#   - PowerShell 7+ on Windows ($IsWindows = $true, fetched via Get-Variable)
#   - any other host where %OS% is reported as Windows_NT
# and $false on PowerShell 7+ on Linux/macOS (used by CI / verification).
# ----------------------------------------------------------------------------

function Test-WindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    $winVar = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($winVar) { return [bool]$winVar.Value }
    if ($env:OS -eq 'Windows_NT') { return $true }
    return $false
}

# ----------------------------------------------------------------------------
# AppX resolution + activation (same pattern as Start-Codex-Official.ps1)
# ----------------------------------------------------------------------------

function Resolve-CodexAppx {
    if (-not (Test-WindowsHost)) {
        # The verifier and CI run the launcher under pwsh on Linux/macOS for
        # smoke/dry-run; Get-AppxPackage does not exist there. Return a stub
        # so the rest of the script (bridge spin-up + isolated CODEX_HOME
        # seeding) is still exercised. Activation is skipped automatically
        # because `-NoCodex` is the only realistic non-Windows code path.
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
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $exe = $c; break } }
    if (-not $exe) {
        throw "Found Codex package at '$($pkg.InstallLocation)' but could not locate Codex.exe (looked in app\\Codex.exe and Codex.exe)."
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

    if (-not ('CodexOmniRouteAppxActivator' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class CodexOmniRouteApplicationActivationManager {}

[Flags]
public enum CodexOmniRouteActivateOptions {
    None = 0,
    DesignMode = 1,
    NoErrorUI = 2,
    NoSplashScreen = 4
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICodexOmniRouteApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        CodexOmniRouteActivateOptions options,
        out uint processId);
}

public static class CodexOmniRouteAppxActivator {
    public static int Activate(string appUserModelId, string arguments, out uint processId) {
        var manager = (ICodexOmniRouteApplicationActivationManager)new CodexOmniRouteApplicationActivationManager();
        return manager.ActivateApplication(
            appUserModelId,
            arguments ?? "",
            CodexOmniRouteActivateOptions.NoErrorUI,
            out processId);
    }
}
'@
    }

    [uint32]$activatedPid = 0
    $hr = [CodexOmniRouteAppxActivator]::Activate($AumId, $Arguments, [ref]$activatedPid)
    if ($hr -ne 0) {
        throw ("AppX activation failed for {0} (HRESULT 0x{1:X8})." -f $AumId, $hr)
    }
    return $activatedPid
}

# ----------------------------------------------------------------------------
# Port + bridge helpers
# ----------------------------------------------------------------------------

function Test-PortFree {
    param([int]$Port)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Find-FreePort {
    param([int]$Preferred, [int]$Range = 50)
    for ($p = $Preferred; $p -lt $Preferred + $Range; $p++) {
        if (Test-PortFree -Port $p) { return $p }
    }
    throw "No free port found in range [$Preferred, $($Preferred + $Range))."
}

function Find-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "node.exe not found on PATH. Install Node.js >= 18.18 from https://nodejs.org/."
}

function Wait-ForBridgeHealth {
    # NOTE: do not name a param $Host -- $Host is a PowerShell automatic variable.
    param([string]$BridgeHost, [int]$Port, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $url = "http://{0}:{1}/healthz" -f $BridgeHost, $Port
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri $url -TimeoutSec 2 -ErrorAction Stop
            if ($resp.ok) { return $resp }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    throw ("Bridge /healthz did not respond within {0}s on {1}" -f $TimeoutSec, $url)
}

function Stop-ManagedBridge {
    param([string]$PidPath)
    if (-not (Test-Path -LiteralPath $PidPath)) { return }
    try {
        $pidText = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction Stop).Trim()
    } catch { return }
    if (-not ($pidText -match '^\d+$')) { return }
    $existingPid = [int]$pidText
    try {
        $proc = Get-Process -Id $existingPid -ErrorAction Stop
        if ($proc.ProcessName -match '^node') {
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            Write-Host "[omniroute] stopped previous bridge (pid=$existingPid)"
        }
    } catch { } # process already gone
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Codex home resolution
# ----------------------------------------------------------------------------

function Get-OfficialCodexHome {
    # USERPROFILE is Windows-only. On non-Windows hosts (CI / verifier
    # smoke), fall back to $HOME so the launcher and the bridge agree on
    # which directory holds the user's real Codex profile. Codex Desktop
    # itself only ever runs on Windows.
    if ($env:USERPROFILE) {
        return (Join-Path $env:USERPROFILE '.codex')
    }
    if ($env:HOME) {
        return (Join-Path $env:HOME '.codex')
    }
    throw "Cannot resolve Codex home directory: neither USERPROFILE nor HOME is set."
}

# ----------------------------------------------------------------------------
# Isolated CODEX_HOME: write config.toml from scratch
# ----------------------------------------------------------------------------

function Build-IsolatedConfigToml {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [bool]$IncludeFreeform = $true
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Codex OmniRoute -- isolated CODEX_HOME config.')
    [void]$sb.AppendLine('# This file is written from scratch by Start-Codex-OmniRoute.ps1 on')
    [void]$sb.AppendLine('# every launch and lives ONLY in the isolated .codex-omniroute-home/')
    [void]$sb.AppendLine('# directory next to the launcher. Your real %USERPROFILE%\.codex\config.toml')
    [void]$sb.AppendLine('# is NOT touched.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('model_provider = "omniroute_bridge"')
    [void]$sb.AppendLine('model = "gpt-5.4"')
    [void]$sb.AppendLine('model_reasoning_effort = "xhigh"')
    [void]$sb.AppendLine('profile = "omniroute_managed"')
    if ($IncludeFreeform) {
        # Cheap safety net for the rare case where a future Codex update
        # regresses apply_patch.bat under AppX activation. With AppX broker
        # launch this flag is not normally required, but it does no harm.
        [void]$sb.AppendLine('experimental_use_freeform_apply_patch = true')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[model_providers.omniroute_bridge]')
    [void]$sb.AppendLine('name = "OmniRoute Bridge"')
    [void]$sb.AppendLine(('base_url = "http://127.0.0.1:{0}/v1"' -f $Port))
    [void]$sb.AppendLine('wire_api = "responses"')
    [void]$sb.AppendLine('requires_openai_auth = true')
    [void]$sb.AppendLine('supports_websockets = false')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[profiles.omniroute_managed]')
    [void]$sb.AppendLine('model_provider = "omniroute_bridge"')
    [void]$sb.AppendLine('model = "gpt-5.4"')
    [void]$sb.AppendLine('model_reasoning_effort = "xhigh"')
    if ($IncludeFreeform) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[profiles.omniroute_managed.features]')
        [void]$sb.AppendLine('experimental_use_freeform_apply_patch = true')
    }
    return $sb.ToString()
}

function Seed-IsolatedCodexHome {
    param(
        [Parameter(Mandatory = $true)][string]$IsolatedHome,
        [Parameter(Mandatory = $true)][string]$OfficialHome,
        [Parameter(Mandatory = $true)][int]$Port,
        [bool]$IncludeFreeform = $true
    )

    # Always reseed from scratch -- the whole point of Variant 3 is that
    # the isolated dir starts with no state_5.sqlite, so Desktop picks up
    # the freshly-written config.toml on the next thread create.
    if (Test-Path -LiteralPath $IsolatedHome) {
        try {
            Remove-Item -LiteralPath $IsolatedHome -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "[omniroute] could not fully clean previous isolated home at $IsolatedHome -- continuing. Detail: $($_.Exception.Message)"
        }
    }
    New-Item -ItemType Directory -Path $IsolatedHome -Force | Out-Null

    # Seed auth.json (OAuth tokens) from the user's real profile so Codex
    # Desktop boots already logged in as the user. This is the difference
    # between Variant 3 and PR #3's API-key sentinel: we keep the real
    # OAuth tokens, so fast mode / ChatGPT credits keep working.
    $officialAuth = Join-Path $OfficialHome 'auth.json'
    $isolatedAuth = Join-Path $IsolatedHome 'auth.json'
    if (Test-Path -LiteralPath $officialAuth) {
        try {
            Copy-Item -LiteralPath $officialAuth -Destination $isolatedAuth -Force
            Write-Host "[omniroute] seeded auth.json from $officialAuth"
        } catch {
            Write-Warning "[omniroute] failed to copy auth.json: $($_.Exception.Message). Desktop may show the login screen."
        }
    } else {
        Write-Warning "[omniroute] no $officialAuth -- isolated CODEX_HOME starts without auth.json. Launch the official Codex once and sign in, then re-run."
    }

    # Seed models_cache.json if present so the bridge's /v1/models route
    # has data on first load.
    $officialModels = Join-Path $OfficialHome 'models_cache.json'
    $isolatedModels = Join-Path $IsolatedHome 'models_cache.json'
    if (Test-Path -LiteralPath $officialModels) {
        try {
            Copy-Item -LiteralPath $officialModels -Destination $isolatedModels -Force
            Write-Host "[omniroute] seeded models_cache.json from $officialModels"
        } catch {
            Write-Warning "[omniroute] failed to copy models_cache.json: $($_.Exception.Message)"
        }
    }

    # Write the isolated config.toml from scratch.
    $isolatedConfig = Join-Path $IsolatedHome 'config.toml'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $content = Build-IsolatedConfigToml -Port $Port -IncludeFreeform:$IncludeFreeform
    [System.IO.File]::WriteAllText($isolatedConfig, $content, $utf8NoBom)
    Write-Host "[omniroute] wrote isolated config.toml at $isolatedConfig"

    # Explicitly DO NOT carry over state_5.sqlite. If a previous launch
    # left a partial copy in the isolated dir somehow (shouldn't happen
    # after the Remove-Item above, but guard anyway), nuke it so Desktop
    # creates a fresh empty store and reads model_provider from the
    # freshly-written config.toml.
    foreach ($stale in @('state_5.sqlite', 'state_5.sqlite-journal', 'state_5.sqlite-wal', 'state_5.sqlite-shm')) {
        $p = Join-Path $IsolatedHome $stale
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } catch {}
        }
    }

    # Write a stamp file that records the isolated dir contents at seed
    # time. The bridge reads this on /healthz to compute
    # desktop_codex_home_honored: if Codex Desktop honored CODEX_HOME, it
    # will eventually create state_5.sqlite (or modify auth.json /
    # models_cache.json) inside the isolated dir, and the stamp's mtime
    # snapshot will diverge from the current dir.
    $stampPath = Join-Path $IsolatedHome '.omniroute-seed.json'
    $stamp = [ordered]@{
        seeded_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        bridge_port   = $Port
        files = @()
    }
    Get-ChildItem -LiteralPath $IsolatedHome -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        # The stamp file itself is excluded so writing it doesn't change
        # the stamp on subsequent reads.
        if ($_.Name -eq '.omniroute-seed.json') { return }
        $stamp.files += [ordered]@{
            name  = $_.Name
            size  = $_.Length
            mtime = $_.LastWriteTimeUtc.ToString('o')
        }
    }
    $stampJson = $stamp | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($stampPath, $stampJson, $utf8NoBom)
}

function Remove-IsolatedCodexHome {
    param([Parameter(Mandatory = $true)][string]$IsolatedHome)
    if (-not (Test-Path -LiteralPath $IsolatedHome)) { return }
    try {
        Remove-Item -LiteralPath $IsolatedHome -Recurse -Force -ErrorAction Stop
        Write-Host "[omniroute] removed isolated CODEX_HOME at $IsolatedHome"
    } catch {
        Write-Warning "[omniroute] could not fully remove isolated CODEX_HOME at $IsolatedHome -- $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Legacy PR-#3 / PR-#2 cleanup in the user's real ~/.codex
#
# Earlier versions of this launcher wrote a managed-block into the user's
# real ~/.codex/config.toml and replaced their real ~/.codex/auth.json
# with an API-key sentinel. Variant 3 does neither. To make the transition
# safe for upgrading users, we sweep up any leftover artifacts from those
# versions on every launch and on -Restore.
# ----------------------------------------------------------------------------

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
    try { $obj = $Content | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
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

function Invoke-LegacyCleanup {
    param([Parameter(Mandatory = $true)][string]$OfficialHome)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # 1. config.toml: if a backup from PR-#2 exists, restore it; else strip
    #    any orphan managed block in place.
    $configPath = Join-Path $OfficialHome 'config.toml'
    $configBackup = Join-Path $OfficialHome 'config.toml.codex-omniroute-backup'
    if (Test-Path -LiteralPath $configBackup) {
        try {
            $backup = Get-Content -LiteralPath $configBackup -Raw
            if ($null -eq $backup) { $backup = '' }
            if ($backup.Length -eq 0) {
                if (Test-Path -LiteralPath $configPath) {
                    # Backup is the "no original existed" sentinel from PR #2.
                    $existing = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
                    if ($existing -and $existing.Contains($LegacyManagedBlockBegin)) {
                        Remove-Item -LiteralPath $configPath -Force
                        Write-Host "[omniroute] legacy cleanup: removed managed-only config.toml (no original existed)"
                    }
                }
            } else {
                [System.IO.File]::WriteAllText($configPath, $backup, $utf8NoBom)
                Write-Host "[omniroute] legacy cleanup: restored original config.toml from $configBackup"
            }
        } catch {
            Write-Warning "[omniroute] legacy cleanup: failed to restore config.toml from $configBackup -- $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $configBackup -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $configPath) {
        try {
            $existing = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
            if ($existing -and $existing.Contains($LegacyManagedBlockBegin)) {
                $stripped = Remove-LegacyManagedBlockText -Content $existing
                [System.IO.File]::WriteAllText($configPath, $stripped, $utf8NoBom)
                Write-Host "[omniroute] legacy cleanup: stripped orphan managed block from $configPath"
            }
        } catch {
            Write-Warning "[omniroute] legacy cleanup: failed to strip managed block in $configPath -- $($_.Exception.Message)"
        }
    }

    # 2. auth.json: if a backup from PR-#3 exists, restore it; else if the
    #    live file looks like our legacy sentinel, delete it.
    $authPath = Join-Path $OfficialHome 'auth.json'
    $authBackup = Join-Path $OfficialHome 'auth.json.codex-omniroute-backup'
    if (Test-Path -LiteralPath $authBackup) {
        try {
            $backup = Get-Content -LiteralPath $authBackup -Raw
            if ($null -eq $backup) { $backup = '' }
            if ($backup.Length -eq 0) {
                if (Test-Path -LiteralPath $authPath) {
                    $existing = Get-Content -LiteralPath $authPath -Raw -ErrorAction SilentlyContinue
                    if ($null -ne $existing -and (Test-IsLegacyManagedAuth -Content $existing)) {
                        Remove-Item -LiteralPath $authPath -Force
                        Write-Host "[omniroute] legacy cleanup: removed sentinel auth.json (no original existed)"
                    }
                }
            } else {
                [System.IO.File]::WriteAllText($authPath, $backup, $utf8NoBom)
                Write-Host "[omniroute] legacy cleanup: restored original auth.json from $authBackup"
            }
        } catch {
            Write-Warning "[omniroute] legacy cleanup: failed to restore auth.json from $authBackup -- $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $authBackup -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $authPath) {
        try {
            $existing = Get-Content -LiteralPath $authPath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $existing -and (Test-IsLegacyManagedAuth -Content $existing)) {
                Remove-Item -LiteralPath $authPath -Force
                Write-Host "[omniroute] legacy cleanup: removed orphan sentinel auth.json $authPath"
            }
        } catch {
            Write-Warning "[omniroute] legacy cleanup: failed to inspect/remove sentinel auth.json -- $($_.Exception.Message)"
        }
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
$bridgeScript = Join-Path $scriptRoot 'codex-openai-omniroute-bridge.mjs'
if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Bridge script not found: $bridgeScript"
}
$bridgePid = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog = Join-Path $scriptRoot 'bridge.log'

$officialHome = Get-OfficialCodexHome
$isolatedHome = Join-Path $scriptRoot $IsolatedHomeDirName

# ---- Restore mode ---------------------------------------------------------

if ($Restore) {
    Stop-ManagedBridge -PidPath $bridgePid
    Remove-IsolatedCodexHome -IsolatedHome $isolatedHome
    # Reverse any leftover PR-#3 artifacts in the user's real ~/.codex.
    Invoke-LegacyCleanup -OfficialHome $officialHome
    Write-Host "[omniroute] restore complete. Codex now uses your real ~/.codex profile (no bridge, no isolated home)."
    exit 0
}

# ---- Pre-flight -----------------------------------------------------------

$appx = Resolve-CodexAppx
$nodeExe = Find-NodeExe
$port = Find-FreePort -Preferred $BridgePort

Write-Host "[omniroute] Codex AumId:    $($appx.AumId)"
Write-Host "[omniroute] node:           $nodeExe"
Write-Host "[omniroute] bridge port:    $port"
Write-Host "[omniroute] official home:  $officialHome"
Write-Host "[omniroute] isolated home:  $isolatedHome"

# Warn if Codex is already running -- the AppX broker will activate the
# existing instance, which won't re-read config.toml.
$existingCodex = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue
if ($existingCodex) {
    Write-Warning "[omniroute] Codex is already running (pid=$($existingCodex.Id -join ',')). Quit it (right-click tray icon -> Quit) before re-launching so the new CODEX_HOME takes effect."
}

if ($DryRun) {
    Write-Host "[omniroute] DryRun -- not seeding isolated home, not starting bridge, not launching Codex."
    [pscustomobject]@{
        Mode               = 'omniroute'
        AumId              = $appx.AumId
        BridgePort         = $port
        BridgeScript       = $bridgeScript
        OfficialHome       = $officialHome
        IsolatedHome       = $isolatedHome
        FreeformApplyPatch = (-not $NoFreeformApplyPatch)
        OpenProject        = $OpenProject
        DryRun             = $true
    } | Format-List
    exit 0
}

# ---- Sweep any legacy PR-#3 / PR-#2 artifacts -----------------------------
#
# This is a one-shot reverse-of-old-architecture for users upgrading from
# earlier versions of the repo. It is safe to run on a clean profile: it
# only acts if it actually finds a managed block, a sentinel auth.json,
# or one of the backup files.

Invoke-LegacyCleanup -OfficialHome $officialHome

# ---- Seed isolated CODEX_HOME ---------------------------------------------

Seed-IsolatedCodexHome `
    -IsolatedHome    $isolatedHome `
    -OfficialHome    $officialHome `
    -Port            $port `
    -IncludeFreeform:(-not $NoFreeformApplyPatch)

# ---- Start (or restart) the bridge ----------------------------------------

Stop-ManagedBridge -PidPath $bridgePid

$resolvedProvider = $null
if ($ProviderJson) {
    if ([System.IO.Path]::IsPathRooted($ProviderJson)) {
        $resolvedProvider = $ProviderJson
    } else {
        # Resolve relative paths against the script root (where the launcher
        # lives), not the cwd, so that double-clicking the .bat from any
        # directory still finds the provider config.
        $resolvedProvider = Join-Path $scriptRoot $ProviderJson
    }
}

# CODEX_HOME is the ONLY env override we set. We deliberately do NOT touch
# USERPROFILE / APPDATA / HOME / LOCALAPPDATA / TEMP / TMP -- those keep
# pointing at the user's real profile so apply_patch, MCP, git, rg, file
# dialogs, ~/.gitconfig, ~/.ssh continue to work.
#
# CODEX_HOME is set at PROCESS scope (this launcher's own env) so that:
#   - the bridge child process inherits it (we just spawned it);
#   - the AppX broker, invoked later in this script, inherits it from
#     us and hands it to Codex.exe.
# We do NOT restore CODEX_HOME after starting the bridge: keeping it set
# is exactly what Codex Desktop needs to see.
$bridgeEnv = @{
    CODEX_HOME              = $isolatedHome
    CODEX_BRIDGE_HOST       = '127.0.0.1'
    CODEX_BRIDGE_PORT       = "$port"
    BRIDGE_LOG_PATH         = $bridgeLog
}
if ($resolvedProvider -and (Test-Path -LiteralPath $resolvedProvider)) {
    $bridgeEnv['OMNIROUTE_PROVIDER_JSON'] = $resolvedProvider
}

# Apply env vars at process scope. CODEX_HOME stays applied even after
# the bridge is started so the subsequent AppX activation inherits it.
# The non-CODEX_HOME bridge variables (BRIDGE_LOG_PATH, etc.) are also
# kept since they don't affect Codex Desktop.
foreach ($kv in $bridgeEnv.GetEnumerator()) {
    [System.Environment]::SetEnvironmentVariable($kv.Key, [string]$kv.Value, 'Process')
}

"[$(Get-Date -Format o)] bridge starting node=$nodeExe port=$port codex_home=$isolatedHome" |
    Out-File -LiteralPath $bridgeLog -Encoding UTF8 -Append

$proc = $null
# -WindowStyle is Windows-only; only pass it where supported so the
# launcher also works under pwsh on Linux/macOS in CI/verification.
$startArgs = @{
    FilePath         = $nodeExe
    ArgumentList     = @($bridgeScript)
    WorkingDirectory = $scriptRoot
    PassThru         = $true
}
if (Test-WindowsHost) {
    $startArgs['WindowStyle'] = 'Hidden'
}
$proc = Start-Process @startArgs

if (-not $proc) {
    throw "[omniroute] failed to start bridge process (Start-Process returned null)"
}
try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
Set-Content -LiteralPath $bridgePid -Value $proc.Id -Encoding ASCII

try {
    $health = Wait-ForBridgeHealth -BridgeHost '127.0.0.1' -Port $port -TimeoutSec 25
    $omniSource = if ($health -and $health.omniroute) { $health.omniroute.source } else { '<unknown>' }
    Write-Host "[omniroute] bridge healthy on 127.0.0.1:$port (pid=$($proc.Id), source=$omniSource)"
} catch {
    Write-Error "[omniroute] bridge failed to come up: $($_.Exception.Message). See $bridgeLog."
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    throw
}

if ($NoCodex) {
    Write-Host "[omniroute] -NoCodex: bridge is running, isolated CODEX_HOME is seeded. Codex GUI not launched."
    exit 0
}

# ---- Launch Codex via AppX broker ----------------------------------------
#
# Activating through IApplicationActivationManager gives Codex.exe its
# Microsoft Store package identity, which propagates to every child
# process Codex spawns (agent shell, apply_patch.bat -> codex.exe,
# codex-command-runner, rg, etc.). This is the same launch path
# Start Menu uses.
#
# CODEX_HOME is already set in this process's env, so the broker hands
# it to Codex.exe. Desktop reads config.toml from there and selects
# model_provider = "omniroute_bridge", routing /v1/responses through
# the bridge.

$argumentString = ''
if ($OpenProject) {
    $argumentString = "--open-project `"$OpenProject`""
}

$activatedPid = Start-CodexViaAppx -AumId $appx.AumId -Arguments $argumentString
if ($activatedPid -gt 0) {
    Write-Host "[omniroute] launched Codex via AppX activation (pid=$activatedPid)"
} else {
    Write-Host "[omniroute] Codex AppX activation succeeded (pid not reported)"
}

Write-Host "[omniroute] tail the bridge log to watch routing:"
Write-Host "  Get-Content '$bridgeLog' -Tail 50 -Wait"

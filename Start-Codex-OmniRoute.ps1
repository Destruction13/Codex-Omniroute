<#
.SYNOPSIS
    OmniRoute launcher: official Codex with main reasoning rerouted to OmniRoute.

.DESCRIPTION
    Codex OmniRoute is intentionally a thin mode switch on top of the
    unmodified Microsoft Store Codex app. The architecture has three
    moving parts:

      1. A local Node bridge (codex-openai-omniroute-bridge.mjs) that:
           - reroutes /v1/responses and /v1/chat/completions to OmniRoute;
           - forwards everything else (compact, dictation, models cache,
             account stuff) to the official upstream unchanged.

      2. A managed block in the user's normal %USERPROFILE%\.codex\config.toml
         that points Codex Desktop at the bridge:
             model_provider     = "omniroute_bridge"
             [model_providers.omniroute_bridge]
                 base_url = "http://127.0.0.1:<bridge_port>/v1"
                 wire_api = "responses"
                 requires_openai_auth = true
                 supports_websockets  = false

      3. A managed %USERPROFILE%\.codex\auth.json that flips Codex Desktop
         into API-key auth mode:
             { "OPENAI_API_KEY": "sk-omniroute-managed",
               "tokens": null, "last_refresh": null }
         This is the actual fix for the bridge-bypass regression. With a
         real ChatGPT OAuth auth.json in place Codex Desktop talks to
         chatgpt.com directly for main reasoning and never hits the bridge
         no matter what config.toml says. Writing the API-key sentinel
         forces Desktop down the requires_openai_auth code path, which IS
         the bridge. The sentinel value itself is never a valid credential
         against any real upstream; the bridge strips it on the
         official-passthrough route and substitutes the user's real
         OAuth tokens loaded from the backup file (see
         CODEX_OFFICIAL_AUTH_PATH in the bridge).

    The original config.toml and auth.json are backed up to
    %USERPROFILE%\.codex\config.toml.codex-omniroute-backup and
    %USERPROFILE%\.codex\auth.json.codex-omniroute-backup the first time
    the launcher runs. The managed block is delimited by marker comments
    (# >>> codex-omniroute-managed ... # <<< codex-omniroute-managed) so it
    can be detected, re-written on the next launch (port may differ), and
    fully removed by `Start-Codex-OmniRoute.ps1 -Restore` or by
    `Start-Codex-Official.ps1`. The auth.json side mirrors the same
    backup / restore contract: backed up on first launch, restored byte-
    for-byte on -Restore, deleted if no original existed.

    Codex.exe itself is launched through the AppX activation broker
    (IApplicationActivationManager), exactly the way Start-Menu and
    Start-Codex-Official.ps1 launch it. This preserves Microsoft Store
    package identity for Codex AND for every child shell it spawns, so
    apply_patch.bat, codex-command-runner.exe, rg.exe, and any other
    bundled CLI tool resolve and execute correctly. No PATH prepend, no
    shim, no rewriter daemon, no payload copy is required.

    The launcher does NOT isolate HOME, USERPROFILE, APPDATA, LOCALAPPDATA,
    TEMP, TMP, CODEX_HOME, or CODEX_ELECTRON_USER_DATA_PATH. Codex sees the
    user's real Windows profile, real git, real ssh, real file dialogs.
    This is the deliberate replacement for the previous isolated-runtime
    architecture, which made Codex unable to see the user's real
    filesystem, broke git in subtle ways, and required ~1000 lines of
    workaround code (payload copy, AppX alias junctions, three-layer
    apply_patch defense, MCP stdout shield wrapping every server, etc.).

.PARAMETER NoCodex
    Start the bridge and patch the config, but do NOT launch the Codex GUI.
    Used by verify-codex-omniroute.ps1.

.PARAMETER Restore
    Remove the managed block from ~/.codex/config.toml (restoring the
    backed-up original where possible), restore the user's original
    ~/.codex/auth.json from its backup (or delete the managed sentinel
    file when no original existed), and stop the managed bridge.
    Equivalent to switching back to vanilla Codex. Does not launch Codex.

.PARAMETER DryRun
    Print what would be done (port choice, planned config edits) without
    starting the bridge or launching Codex.

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
    managed block. Default: emit it as a cheap safety net. Under AppX
    activation, apply_patch.bat works natively and this flag is not
    strictly required.

.NOTES
    - Never modifies the Microsoft Store Codex package.
    - Always backs up ~/.codex/config.toml AND ~/.codex/auth.json before
      the first modification.
    - The managed block carries the bridge port number; restoring is
      always reversible.
    - The managed auth.json is an API-key sentinel; it does not embed any
      real credential and never reaches a real upstream — the bridge
      strips it on the official passthrough path.
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

$ManagedBlockBegin = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$ManagedBlockEnd   = '# <<< codex-omniroute-managed'

# Sentinel API key written into the managed ~/.codex/auth.json. Its only
# job is to flip Codex Desktop into API-key auth mode so it actually goes
# through the bridge for main reasoning (instead of bypassing it via the
# ChatGPT OAuth session in the user's real auth.json). The bridge strips
# this value on the official-passthrough path; see MANAGED_AUTH_SENTINEL
# in codex-openai-omniroute-bridge.mjs. Keep the value in sync.
$ManagedAuthSentinelApiKey = 'sk-omniroute-managed'

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
        # so the rest of the script (bridge spin-up + config patching) is
        # still exercised. Activation is skipped automatically because
        # `-NoCodex` is the only realistic non-Windows code path.
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
# Codex config.toml: backup + managed block insert/remove
# ----------------------------------------------------------------------------

function Get-OfficialCodexHome {
    # USERPROFILE is Windows-only. On non-Windows hosts (CI / verifier
    # smoke), fall back to $HOME so the launcher and the bridge agree on
    # which directory holds config.toml / auth.json. Codex Desktop itself
    # only ever runs on Windows.
    if ($env:USERPROFILE) {
        return (Join-Path $env:USERPROFILE '.codex')
    }
    if ($env:HOME) {
        return (Join-Path $env:HOME '.codex')
    }
    throw "Cannot resolve Codex home directory: neither USERPROFILE nor HOME is set."
}

function Ensure-ConfigBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    # If a managed block is already present, the file has been touched by a
    # previous run -- DO NOT overwrite an existing backup with the modified
    # content. The backup must always represent the user's original config.
    if (Test-Path -LiteralPath $BackupPath) { return }

    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($ManagedBlockBegin)) {
            # File already contains a managed block but no backup exists.
            # That means a previous launcher run created the block but the
            # original file is gone. Best we can do is save the clean (block-
            # stripped) version as the backup so -Restore reverts to that.
            $stripped = Remove-ManagedBlockText -Content $existing
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($BackupPath, $stripped, $utf8NoBom)
            Write-Host "[omniroute] saved synthetic config backup (original unrecoverable): $BackupPath"
            return
        }
        Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
        Write-Host "[omniroute] backed up original config: $BackupPath"
    } else {
        # No existing config -- record that fact with an empty backup so
        # -Restore deletes our managed-only config.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($BackupPath, '', $utf8NoBom)
        Write-Host "[omniroute] no pre-existing config; empty backup recorded: $BackupPath"
    }
}

function Remove-ManagedBlockText {
    param([string]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }
    # Strip everything between the markers, including the markers themselves.
    # ([\s\S]*?) is non-greedy so we don't eat unrelated content if (for some
    # reason) multiple managed blocks ever appear.
    $pattern = '(?ms)^[\t ]*' + [regex]::Escape($ManagedBlockBegin) + '[\s\S]*?' + [regex]::Escape($ManagedBlockEnd) + '[\t ]*\r?\n?'
    $stripped = [regex]::Replace($Content, $pattern, '')
    # Collapse runs of >=3 blank lines that the strip may have introduced.
    $stripped = [regex]::Replace($stripped, '(\r?\n){3,}', "`r`n`r`n")
    return $stripped
}

function Build-ManagedBlock {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [bool]$IncludeFreeform = $true
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($ManagedBlockBegin)
    [void]$sb.AppendLine('# Managed by Start-Codex-OmniRoute.ps1. Removed by -Restore or by Start-Codex-Official.ps1.')
    [void]$sb.AppendLine('# Original config (if any) is at config.toml.codex-omniroute-backup.')
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
    [void]$sb.AppendLine($ManagedBlockEnd)
    return $sb.ToString()
}

function Strip-ConflictingTopLevelKeys {
    param([string]$Content)
    # TOML rejects duplicate top-level keys. The managed block sets
    # model_provider / model / model_reasoning_effort / profile at the top
    # level, so any existing top-level setting of those keys (outside any
    # [section] header) must be removed before we append our block.
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }

    $lines = $Content -split "(`r`n|`n|`r)"
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $conflictPattern = '^[\t ]*(model_provider|model|model_reasoning_effort|profile)[\t ]*='
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match '^[\t ]*\[' ) { $inSection = $true }
        if (-not $inSection -and $line -match $conflictPattern) {
            Write-Host "[omniroute] stripped conflicting top-level key: $($line.Trim())"
            continue
        }
        $out.Add($line) | Out-Null
    }
    return ($out -join '')
}

function Strip-ManagedSections {
    param([string]$Content)
    # If a previous external edit left a [model_providers.omniroute_bridge]
    # or [profiles.omniroute_managed] section OUTSIDE our managed-block
    # markers, remove it. TOML would otherwise complain about duplicate
    # tables when our managed block re-declares them.
    if ($null -eq $Content -or $Content.Length -eq 0) { return $Content }

    $sectionHeaders = @(
        '^[\t ]*\[model_providers\.omniroute_bridge\][\t ]*$',
        '^[\t ]*\[profiles\.omniroute_managed[^]]*\][\t ]*$'
    )

    $lines = $Content -split "(`r`n|`n|`r)"
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $isHeader = $line -match '^[\t ]*\['
        if ($isHeader) {
            $skip = $false
            foreach ($pattern in $sectionHeaders) {
                if ($line -match $pattern) {
                    Write-Host "[omniroute] stripped stale managed section: $($line.Trim())"
                    $skip = $true
                    break
                }
            }
            if ($skip) { continue }
        }
        if ($skip) { continue }
        $out.Add($line) | Out-Null
    }
    return ($out -join '')
}

function Write-ManagedConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][int]$Port,
        [bool]$IncludeFreeform = $true
    )

    $original = if (Test-Path -LiteralPath $ConfigPath) {
        Get-Content -LiteralPath $ConfigPath -Raw
    } else {
        ''
    }
    if ($null -eq $original) { $original = '' }

    $stripped = Remove-ManagedBlockText -Content $original
    $stripped = Strip-ConflictingTopLevelKeys -Content $stripped
    $stripped = Strip-ManagedSections        -Content $stripped
    $stripped = $stripped.TrimEnd("`r", "`n")

    $block = Build-ManagedBlock -Port $Port -IncludeFreeform:$IncludeFreeform

    $final = if ($stripped.Length -eq 0) {
        $block
    } else {
        $stripped + "`r`n`r`n" + $block
    }

    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigPath, $final, $utf8NoBom)
}

function Restore-OriginalConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        if ($backup.Length -eq 0) {
            # Empty backup means there was no original config -- delete the
            # config we created.
            if (Test-Path -LiteralPath $ConfigPath) {
                Remove-Item -LiteralPath $ConfigPath -Force
                Write-Host "[omniroute] restore: removed managed config $ConfigPath (no original existed)"
            }
        } else {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($ConfigPath, $backup, $utf8NoBom)
            Write-Host "[omniroute] restore: original config restored from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    # No backup -- best-effort: strip the managed block in place.
    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = Get-Content -LiteralPath $ConfigPath -Raw
        if ($existing -and $existing.Contains($ManagedBlockBegin)) {
            $stripped = Remove-ManagedBlockText -Content $existing
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($ConfigPath, $stripped, $utf8NoBom)
            Write-Host "[omniroute] restore: managed block stripped from $ConfigPath (no backup available)"
        }
    }
}

# ----------------------------------------------------------------------------
# Codex auth.json: backup + managed-sentinel write + restore
#
# This is the actual fix for the bridge-bypass regression. Codex Desktop
# decides between OAuth/ChatGPT-session mode and API-key mode by looking
# at the contents of ~/.codex/auth.json:
#
#     { "tokens": { "access_token": "..." } }   -> OAuth/ChatGPT mode,
#                                                  Desktop calls chatgpt.com
#                                                  directly and bypasses our
#                                                  bridge for /v1/responses
#                                                  no matter what
#                                                  config.toml says.
#
#     { "OPENAI_API_KEY": "..." }               -> API-key mode, Desktop
#                                                  honours config.toml's
#                                                  model_provider with
#                                                  requires_openai_auth=true,
#                                                  which IS the bridge.
#
# So in OmniRoute mode we temporarily replace ~/.codex/auth.json with the
# API-key sentinel, while keeping the user's real auth.json byte-for-byte
# in the backup so:
#   (a) -Restore (and Start-Codex-Official.ps1) can put it back exactly,
#   (b) the bridge can still load the real OAuth tokens from the backup
#       for compact / dictation passthrough via CODEX_OFFICIAL_AUTH_PATH.
# ----------------------------------------------------------------------------

function Get-ManagedAuthObject {
    # Returns an [ordered] hashtable so the resulting JSON has a stable key
    # order (helps the verifier and human readers spot the sentinel
    # without parsing).
    return [ordered]@{
        '_codex_omniroute' = [ordered]@{
            'managed' = $true
            'note'    = 'This auth.json was written by Start-Codex-OmniRoute.ps1 to force Codex Desktop into API-key auth mode so main reasoning routes through the OmniRoute bridge. Original file (if any) is at auth.json.codex-omniroute-backup. Restored by -Restore or by Start-Codex-Official.ps1.'
            'sentinel' = $ManagedAuthSentinelApiKey
        }
        'OPENAI_API_KEY'   = $ManagedAuthSentinelApiKey
        'tokens'           = $null
        'last_refresh'     = $null
    }
}

function Test-IsManagedAuthContent {
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    try {
        $obj = $Content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    if (-not $obj) { return $false }
    # Two signals, either is enough to recognize our own write:
    #   (a) the _codex_omniroute marker block,
    #   (b) OPENAI_API_KEY exactly equal to the sentinel.
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

function Ensure-AuthBackup {
    param(
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    # If a backup already exists, never overwrite it -- even if the live
    # auth.json is currently our managed sentinel. Otherwise we would
    # corrupt the only copy of the user's real OAuth tokens.
    if (Test-Path -LiteralPath $BackupPath) { return }

    if (Test-Path -LiteralPath $AuthPath) {
        $existing = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and (Test-IsManagedAuthContent -Content $existing)) {
            # Live file is already our managed sentinel and no backup
            # exists. That means a previous launcher run wrote the
            # sentinel and the user's original is unrecoverable. Record
            # the fact as an empty backup so -Restore knows to DELETE
            # the managed file rather than write the sentinel back.
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($BackupPath, '', $utf8NoBom)
            Write-Host "[omniroute] auth.json is already managed and no backup exists; recorded empty backup at $BackupPath"
            return
        }
        Copy-Item -LiteralPath $AuthPath -Destination $BackupPath -Force
        Write-Host "[omniroute] backed up original auth.json: $BackupPath"
    } else {
        # No existing auth.json -- record that as an empty backup so
        # -Restore deletes our managed sentinel file.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($BackupPath, '', $utf8NoBom)
        Write-Host "[omniroute] no pre-existing auth.json; empty backup recorded: $BackupPath"
    }
}

function Write-ManagedAuth {
    param([Parameter(Mandatory = $true)][string]$AuthPath)

    $authDir = Split-Path -Parent $AuthPath
    if (-not (Test-Path -LiteralPath $authDir)) {
        New-Item -ItemType Directory -Path $authDir -Force | Out-Null
    }
    $managed = Get-ManagedAuthObject
    # Depth 10 is plenty for our tiny object; ConvertTo-Json defaults to 2
    # and would silently truncate the marker.
    $json = $managed | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($AuthPath, $json, $utf8NoBom)
}

function Restore-OriginalAuth {
    param(
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if (Test-Path -LiteralPath $BackupPath) {
        $backup = Get-Content -LiteralPath $BackupPath -Raw
        if ($null -eq $backup) { $backup = '' }
        if ($backup.Length -eq 0) {
            # Empty backup means there was no original auth.json (or it
            # was already managed when we first saw it) -- delete the
            # managed sentinel file.
            if (Test-Path -LiteralPath $AuthPath) {
                Remove-Item -LiteralPath $AuthPath -Force
                Write-Host "[omniroute] restore: removed managed auth.json $AuthPath (no original existed)"
            }
        } else {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($AuthPath, $backup, $utf8NoBom)
            Write-Host "[omniroute] restore: original auth.json restored from $BackupPath"
        }
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return
    }

    # No backup -- best-effort: if the live file is our managed sentinel,
    # remove it; otherwise leave the user's file untouched.
    if (Test-Path -LiteralPath $AuthPath) {
        $existing = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and (Test-IsManagedAuthContent -Content $existing)) {
            Remove-Item -LiteralPath $AuthPath -Force
            Write-Host "[omniroute] restore: removed orphan managed auth.json $AuthPath (no backup available)"
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

$codexHome       = Get-OfficialCodexHome
$configPath      = Join-Path $codexHome 'config.toml'
$backupPath      = Join-Path $codexHome 'config.toml.codex-omniroute-backup'
$authPath        = Join-Path $codexHome 'auth.json'
$authBackupPath  = Join-Path $codexHome 'auth.json.codex-omniroute-backup'

# ---- Restore mode ---------------------------------------------------------

if ($Restore) {
    Stop-ManagedBridge -PidPath $bridgePid
    Restore-OriginalConfig -ConfigPath $configPath -BackupPath $backupPath
    Restore-OriginalAuth   -AuthPath   $authPath   -BackupPath $authBackupPath
    Write-Host "[omniroute] restore complete. Codex now uses your original config + auth."
    exit 0
}

# ---- Pre-flight -----------------------------------------------------------

$appx = Resolve-CodexAppx
$nodeExe = Find-NodeExe
$port = Find-FreePort -Preferred $BridgePort

Write-Host "[omniroute] Codex AumId: $($appx.AumId)"
Write-Host "[omniroute] node:        $nodeExe"
Write-Host "[omniroute] bridge port: $port"
Write-Host "[omniroute] codex home:  $codexHome"
Write-Host "[omniroute] config file: $configPath"
Write-Host "[omniroute] auth  file: $authPath"

# Warn if Codex is already running -- the AppX broker will activate the
# existing instance, which won't re-read config.toml.
$existingCodex = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue
if ($existingCodex) {
    Write-Warning "[omniroute] Codex is already running (pid=$($existingCodex.Id -join ',')). Close it before re-launching so the new config takes effect."
}

if ($DryRun) {
    Write-Host "[omniroute] DryRun -- not modifying config/auth, not starting bridge, not launching Codex."
    [pscustomobject]@{
        Mode               = 'omniroute'
        AumId              = $appx.AumId
        BridgePort         = $port
        BridgeScript       = $bridgeScript
        ConfigPath         = $configPath
        BackupPath         = $backupPath
        AuthPath           = $authPath
        AuthBackupPath     = $authBackupPath
        FreeformApplyPatch = (-not $NoFreeformApplyPatch)
        OpenProject        = $OpenProject
        DryRun             = $true
    } | Format-List
    exit 0
}

# ---- Backup + write managed block + write managed auth.json --------------

Ensure-ConfigBackup -ConfigPath $configPath -BackupPath $backupPath
Write-ManagedConfig -ConfigPath $configPath -Port $port -IncludeFreeform:(-not $NoFreeformApplyPatch)
Write-Host "[omniroute] wrote managed block into $configPath"

Ensure-AuthBackup -AuthPath $authPath -BackupPath $authBackupPath
Write-ManagedAuth -AuthPath $authPath
Write-Host "[omniroute] wrote managed API-key sentinel into $authPath (Desktop will use API-key auth)"

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

$bridgeEnv = @{
    CODEX_HOME              = $codexHome
    CODEX_BRIDGE_HOST       = '127.0.0.1'
    CODEX_BRIDGE_PORT       = "$port"
    BRIDGE_LOG_PATH         = $bridgeLog
}
if ($resolvedProvider -and (Test-Path -LiteralPath $resolvedProvider)) {
    $bridgeEnv['OMNIROUTE_PROVIDER_JSON'] = $resolvedProvider
}
# Point the bridge at the backup so compact / dictation can still use the
# user's real OAuth tokens, even though the live auth.json now holds the
# managed sentinel. If the backup is empty (sentinel for "no original"),
# the bridge gracefully degrades the auth-fallback path (same as today
# when ~/.codex/auth.json is missing).
if (Test-Path -LiteralPath $authBackupPath) {
    $bridgeEnv['CODEX_OFFICIAL_AUTH_PATH'] = $authBackupPath
}

$bridgePrev = @{}
foreach ($kv in $bridgeEnv.GetEnumerator()) {
    $bridgePrev[$kv.Key] = [System.Environment]::GetEnvironmentVariable($kv.Key, 'Process')
    [System.Environment]::SetEnvironmentVariable($kv.Key, [string]$kv.Value, 'Process')
}

"[$(Get-Date -Format o)] bridge starting node=$nodeExe port=$port" |
    Out-File -LiteralPath $bridgeLog -Encoding UTF8 -Append

$proc = $null
try {
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
} finally {
    foreach ($kv in $bridgePrev.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    }
}

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
    Write-Host "[omniroute] -NoCodex: bridge is running, config is patched. Codex GUI not launched."
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
# Codex reads ~/.codex/config.toml at startup and picks up our managed
# block -- model_provider = "omniroute_bridge" routes /v1/responses
# through the bridge. No env-var injection required.

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

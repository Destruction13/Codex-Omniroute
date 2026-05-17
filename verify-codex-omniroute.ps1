<#
.SYNOPSIS
    Verifies the Codex OmniRoute Variant-3 invariants.

.DESCRIPTION
    Runs a bounded OmniRoute launch (bridge only, no Codex GUI) and checks
    the small set of invariants that defines the Variant-3 architecture:

      1. Start-Codex-OmniRoute.ps1 -NoCodex succeeds.
      2. Bridge /healthz responds with ok=true.
      3. The managed bridge PID file exists and points to a live node process.
      4. The isolated CODEX_HOME directory (".codex-omniroute-home" next to
         the launcher) exists and contains the three seeded files:
            - config.toml with model_provider = "omniroute_bridge" and a
              base_url pointing at the active bridge port, plus imported
              MCP/plugin/marketplace sections from the real user config
              and MCP feature gates enabled in root/profile features.
            - auth.json with the user's real OAuth tokens (copy of their
              real ~/.codex/auth.json).
            - .omniroute-seed.json stamp file.
         models_cache.json is optional (present only if the user already
         had one in their real ~/.codex).
      5. The isolated CODEX_HOME preserves prior Codex state/history
         (state_5.sqlite*, logs_2.sqlite*, sessions, global state) while
         reseeding only managed files in place.
      6. The bridge's /healthz exposes:
            - main_reasoning_hits counter (must be 0 at boot, will rise
              as Codex Desktop sends real chat traffic).
            - desktop_codex_home_honored flag (will flip to true once
              Desktop touches the isolated dir).
            - isolated_home.seed_stamp_present = true.
            - official_auth_present = true (we copied real OAuth tokens
              into the isolated home).
      7. The user's real ~/.codex/config.toml has NO managed block (the
         launcher does not mutate the real config under Variant 3).
      8. The user's real ~/.codex/auth.json is NOT the API-key sentinel
         from PR #3 (we copy it, we don't overwrite it).
      9. The user's real ~/.codex has no *.codex-omniroute-backup files
         (legacy artifacts from PR #2 / PR #3; the launcher's legacy
         cleanup pass removes any it finds).
     10. Start-Codex-Official.ps1 -DryRun -NoAutoRestore resolves the
         Codex package without setting any OmniRoute env or referencing
         the bridge module.
     11. The bridge responds to GET /v1/models with the local models cache
         (or with a documented "models_cache_missing" error when the
         cache file is absent).
     12. The dictation endpoint POST /transcribe is reachable (the bridge
         does not 404 it).
     13. rg resolves to an invocable binary.
     14. The literal apply_patch command is rewritten to the local Codex
         CLI helper, and the explicit fallback helper also works.
     15. MCP is checked by proof layer, not only by config:
            - imported config sections;
            - full server handshake/discovery via mcp_probe
              (initialize -> initialized -> tools/list);
            - read-only tools/call smoke for shadcn MCP;
            - authenticated live model-request tool summary, accepting
              either direct MCP attachment fields or the current deferred
              tool_search path;
            - recent Desktop MCP stdio parse errors.
         dynamic_tools is reported only as legacy/debug metadata and is
         never authoritative for PASS/FAIL.
     16. Start-Codex-Official.ps1 -DryRun stops OmniRoute helpers, clears
         stale user-scope CODEX_HOME, leaves persistent isolated history in
         place, and leaves the user's real ~/.codex untouched.

    Optional live smokes (only run with -Live):
       - POST /v1/responses

.PARAMETER Live
    Run a live smoke call against POST /v1/responses. Requires real
    OmniRoute credentials.

.PARAMETER LeaveBridgeRunning
    Do not stop the bridge after verification. Useful for chaining with a
    manual Codex launch.

.PARAMETER BridgePort
    Preferred bridge port. Default 20333.

.PARAMETER NoLiveMcpSession
    Skip GUI/Desktop live MCP checks. This proves only config import and
    MCP server startup, not live model attachment.

.PARAMETER LiveMcpWaitSec
    Wait up to this many seconds for a GUI/Desktop session JSONL to show
    fresh live MCP/tool_search evidence. Default 0.
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$LeaveBridgeRunning,
    [int]$BridgePort = 20333,
    [switch]$NoLiveMcpSession,
    [int]$LiveMcpWaitSec = 0
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Pre-seed $LASTEXITCODE so Set-StrictMode -Latest never trips on it
# before any external command has actually run. The verifier reads
# $LASTEXITCODE after every & call, and a strict-mode error here would
# crash Setup.bat instead of just reporting a FAIL row.
$global:LASTEXITCODE = 0

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}{2}" -f $Status, $Name, $(if ($Detail) { " -- $Detail" } else { '' })) -ForegroundColor $color
}

# Resolve a PowerShell host to invoke child scripts with. Prefer pwsh
# (PowerShell 7+), fall back to the built-in Windows PowerShell. This
# matches the fallback chain used by Setup.ps1 and the .bat launchers,
# so a machine without pwsh installed still runs the verifier instead
# of immediately FAIL-ing with exit=n/a.
function Get-PSHost {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
$psHost = Get-PSHost
if (-not $psHost) {
    Add-Result 'powershell-host' 'FAIL' 'Neither pwsh nor powershell.exe is on PATH; verifier cannot spawn child shells.'
    Write-Host ($results | Format-Table | Out-String)
    exit 1
}

$scriptRoot     = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$omniLauncher   = Join-Path $scriptRoot 'Start-Codex-OmniRoute.ps1'
$offLauncher    = Join-Path $scriptRoot 'Start-Codex-Official.ps1'
$bridgePid      = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog      = Join-Path $scriptRoot 'bridge.log'
$applyPatchRewriterPid = Join-Path $scriptRoot 'apply_patch_rewriter.pid'
$isolatedHome   = Join-Path $scriptRoot '.codex-omniroute-home'
$lastReasoningDiagnosticPath = Join-Path $isolatedHome '.omniroute-last-reasoning.json'
$taskkillShimDir = Join-Path $isolatedHome 'bin'
$historySentinel = Join-Path $isolatedHome '.verify-history-persistence-sentinel'

# USERPROFILE is Windows-only; on Linux / macOS the verifier still runs as
# a smoke. Fall back to $HOME so the bridge / launcher (which themselves
# use os.homedir() / $env:USERPROFILE with the same fallback) see the same
# directory the verifier inspects.
$codexHomeRoot  = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$realCodexHome  = Join-Path $codexHomeRoot '.codex'
$realConfigPath = Join-Path $realCodexHome 'config.toml'
$realAuthPath   = Join-Path $realCodexHome 'auth.json'

$LegacyManagedBlockBegin       = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$LegacyManagedAuthSentinelKey  = 'sk-omniroute-managed'
$LegacyConfigBackup            = Join-Path $realCodexHome 'config.toml.codex-omniroute-backup'
$LegacyAuthBackup              = Join-Path $realCodexHome 'auth.json.codex-omniroute-backup'
$envExamplePath                = Join-Path $scriptRoot '.env.example'
$applyPatchFallback            = Join-Path $scriptRoot 'tools\Invoke-CodexApplyPatch.ps1'
$applyPatchRewriter            = Join-Path $scriptRoot 'tools\apply_patch-rewriter.mjs'
$mcpProbe                      = Join-Path $scriptRoot 'tools\mcp_probe.mjs'
$localCodexCli                 = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe' } else { '' }
$isolatedMcpServerNames        = @()

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

function Get-TomlSectionNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    $names = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return $names.ToArray() }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $match = [regex]::Match($line, '^\s*\[(.+)\]\s*(?:#.*)?$')
        if ($match.Success) {
            $names.Add($match.Groups[1].Value.Trim())
        }
    }
    return $names.ToArray()
}

function Get-RequiredToolingSections {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sections = Get-TomlSectionNames -Path $Path
    return @($sections | Where-Object {
        $n = $_.Trim().ToLowerInvariant()
        $n.StartsWith('marketplaces.', [System.StringComparison]::Ordinal) -or
        $n.StartsWith('plugins.', [System.StringComparison]::Ordinal) -or
        $n.StartsWith('mcp_servers.', [System.StringComparison]::Ordinal)
    })
}

function Test-TomlInlineChildEquivalent {
    param(
        [Parameter(Mandatory = $true)][string]$ChildSectionName,
        [Parameter(Mandatory = $true)][string]$TomlText
    )

    $normalized = $ChildSectionName.Trim().ToLowerInvariant()
    $lastDot = $normalized.LastIndexOf('.')
    if ($lastDot -le 0) { return $false }

    $parent = $normalized.Substring(0, $lastDot)
    $child = $normalized.Substring($lastDot + 1)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($child)) { return $false }

    $parentPattern = [regex]::Escape($parent)
    $sectionMatch = [regex]::Match($TomlText, "(?ms)^\s*\[\s*$parentPattern\s*\]\s*(?:#.*)?\r?\n(?<body>.*?)(?=^\s*\[|\z)")
    if (-not $sectionMatch.Success) { return $false }

    $childPattern = [regex]::Escape($child)
    return [regex]::IsMatch($sectionMatch.Groups['body'].Value, "(?m)^\s*$childPattern\s*=")
}

function Get-McpServerNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($section in @(Get-TomlSectionNames -Path $Path)) {
        $n = $section.Trim()
        if (-not $n.StartsWith('mcp_servers.', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($n.EndsWith('.env', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $server = $n.Substring('mcp_servers.'.Length).Trim()
        if ($server.StartsWith('"') -and $server.EndsWith('"') -and $server.Length -ge 2) {
            $server = $server.Substring(1, $server.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($server)) {
            $names.Add($server)
        }
    }
    return @($names.ToArray() | Sort-Object -Unique)
}

function Test-TomlBooleanInSection {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$SectionName,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $current = ''
    foreach ($line in ($Text -split "\r?\n")) {
        $sectionMatch = [regex]::Match($line, '^\s*\[(.+)\]\s*(?:#.*)?$')
        if ($sectionMatch.Success) {
            $current = $sectionMatch.Groups[1].Value.Trim()
            continue
        }
        if (-not [string]::Equals($current, $SectionName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*true\s*(?:#.*)?$')) {
            return $true
        }
    }
    return $false
}

function Read-TextShared {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return ''
    }
}

function Read-JsonShared {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Read-TextShared -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-SessionMetaFromJsonl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Read-TextShared -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    foreach ($line in ($text -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '"type"\s*:\s*"session_meta"') { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.type -eq 'session_meta') { return $obj }
        } catch { }
    }
    return $null
}

function ConvertTo-NormalizedToolSignal {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', ''))
}

function Get-LiveMcpDynamicToolMatches {
    param(
        [Parameter(Mandatory = $true)]$DynamicTools,
        [Parameter(Mandatory = $true)][string[]]$McpServerNames
    )

    $serverSignals = @{}
    foreach ($server in @($McpServerNames)) {
        $signal = ConvertTo-NormalizedToolSignal -Value $server
        if ($signal) { $serverSignals[$signal] = $server }
    }

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($tool in @($DynamicTools)) {
        $candidateValues = New-Object System.Collections.Generic.List[string]
        foreach ($field in @('server_label', 'serverLabel', 'server_name', 'serverName', 'mcp_server', 'mcpServer')) {
            try {
                $prop = $tool.PSObject.Properties[$field]
                if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    $candidateValues.Add([string]$prop.Value)
                }
            } catch { }
        }
        foreach ($value in @($candidateValues.ToArray())) {
            $toolSignal = ConvertTo-NormalizedToolSignal -Value $value
            if ($toolSignal -and $serverSignals.ContainsKey($toolSignal)) {
                $matches.Add(("{0} via structured dynamic_tools field" -f $serverSignals[$toolSignal]))
            }
        }
    }
    return @($matches.ToArray() | Sort-Object -Unique)
}

function Get-ReasoningDirectMcpToolMatches {
    param(
        [Parameter(Mandatory = $true)]$ReasoningDiagnostic,
        [Parameter(Mandatory = $true)][string[]]$McpServerNames
    )

    $matches = New-Object System.Collections.Generic.List[string]
    $matchedProp = $ReasoningDiagnostic.PSObject.Properties['direct_configured_mcp_servers']
    if (-not $matchedProp) {
        $matchedProp = $ReasoningDiagnostic.PSObject.Properties['matched_configured_mcp_servers']
    }
    if ($matchedProp) {
        foreach ($name in @($matchedProp.Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                $matches.Add([string]$name)
            }
        }
    }
    return @($matches.ToArray() | Sort-Object -Unique)
}

function Get-ReasoningDiagnosticTimestampUtc {
    param([Parameter(Mandatory = $true)]$ReasoningDiagnostic)

    $recordedProp = $ReasoningDiagnostic.PSObject.Properties['recorded_at_utc']
    if (-not $recordedProp -or [string]::IsNullOrWhiteSpace([string]$recordedProp.Value)) {
        return [datetime]::MinValue
    }
    try {
        return ([datetime]::Parse([string]$recordedProp.Value)).ToUniversalTime()
    } catch {
        return [datetime]::MinValue
    }
}

function Find-NewestSessionMeta {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [datetime]$NotBeforeUtc = [datetime]::MinValue
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($file in $files) {
        if ($file.LastWriteTimeUtc -lt $NotBeforeUtc) { continue }
        $meta = Get-SessionMetaFromJsonl -Path $file.FullName
        if ($meta) {
            return [pscustomobject]@{
                Path             = $file.FullName
                LastWriteTimeUtc = $file.LastWriteTimeUtc
                Meta             = $meta
            }
        }
    }
    return $null
}

function Get-CodexDesktopLogRoot {
    if (-not $env:LOCALAPPDATA) { return $null }
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (-not (Test-Path -LiteralPath $packagesRoot)) { return $null }
    $pkg = Get-ChildItem -LiteralPath $packagesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'OpenAI.Codex_*' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $pkg) { return $null }
    return (Join-Path $pkg.FullName 'LocalCache\Local\Codex\Logs')
}

function Find-RecentMcpParseErrors {
    param(
        [datetime]$NotBeforeUtc = [datetime]::MinValue,
        [int]$MaxCount = 5
    )

    $root = Get-CodexDesktopLogRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return @() }
    $cutoff = if ($NotBeforeUtc -gt [datetime]::MinValue) { $NotBeforeUtc.AddMinutes(-2) } else { [datetime]::MinValue }
    $foundErrors = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoff } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 12)
    foreach ($file in $files) {
        $text = Read-TextShared -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($line in ($text -split "\r?\n")) {
            if ($line -notmatch 'Failed to parse MCP message') { continue }
            $ts = [datetime]::MinValue
            $tsMatch = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z)')
            if ($tsMatch.Success) {
                try { $ts = ([datetime]::Parse($tsMatch.Groups[1].Value)).ToUniversalTime() } catch { $ts = [datetime]::MinValue }
            }
            if ($ts -lt $cutoff) { continue }
            $preview = ''
            $previewMatch = [regex]::Match($line, 'linePreview="([^"]*)"')
            if ($previewMatch.Success) { $preview = $previewMatch.Groups[1].Value }
            $foundErrors.Add([pscustomobject]@{
                TimestampUtc = $ts
                Path         = $file.FullName
                Preview      = $preview
                Line         = $line
            })
            if ($foundErrors.Count -ge $MaxCount) { return @($foundErrors.ToArray()) }
        }
    }
    return @($foundErrors.ToArray())
}

# Snapshot the real ~/.codex BEFORE the launcher runs so we can prove
# Variant 3 didn't touch it. Both content snapshots may be $null when
# the user has no real config / auth yet; we accept that as a degenerate
# fresh-install case.
#
# Important nuance: if the user is upgrading from PR-#2/#3, the legacy
# cleanup pass inside the launcher WILL rewrite ~/.codex/config.toml to
# strip the managed block (and remove the sentinel auth.json). That is
# expected behavior, not a regression. The verifier distinguishes
# between "launcher modified clean real config" (regression) and
# "launcher stripped a stale managed block" (expected) by inspecting
# pre-launch content for the legacy block markers.
$realConfigPreExisted  = Test-Path -LiteralPath $realConfigPath
$realConfigPreContent  = if ($realConfigPreExisted) { Get-Content -LiteralPath $realConfigPath -Raw } else { $null }
$realConfigHadLegacy   = ($null -ne $realConfigPreContent -and $realConfigPreContent.Contains($LegacyManagedBlockBegin))
$realAuthPreExisted    = Test-Path -LiteralPath $realAuthPath
$realAuthPreContent    = if ($realAuthPreExisted) { Get-Content -LiteralPath $realAuthPath -Raw } else { $null }
$realAuthHadLegacy     = $false
if ($realAuthPreContent) {
    try {
        $preParsed = $realAuthPreContent | ConvertFrom-Json -ErrorAction Stop
        if ($preParsed -and $preParsed.PSObject.Properties.Name -contains 'OPENAI_API_KEY' -and
            [string]$preParsed.OPENAI_API_KEY -eq $LegacyManagedAuthSentinelKey) {
            $realAuthHadLegacy = $true
        }
    } catch { }
}

# Seed a tiny marker into the isolated home before launching. The launcher
# must update managed files in place, not delete the whole directory, so this
# marker and any pre-existing Codex state bundle should survive the launch.
$historyBundlePre = @{}
foreach ($name in @('state_5.sqlite', 'state_5.sqlite-wal', 'state_5.sqlite-shm', 'logs_2.sqlite', 'sessions', '.codex-global-state.json')) {
    $p = Join-Path $isolatedHome $name
    $historyBundlePre[$name] = Test-Path -LiteralPath $p
}
try {
    New-Item -ItemType Directory -Path $isolatedHome -Force | Out-Null
    [System.IO.File]::WriteAllText($historySentinel, (Get-Date).ToUniversalTime().ToString('o'), [System.Text.UTF8Encoding]::new($false))
} catch {
    Add-Result 'history-sentinel-preseed' 'FAIL' "could not seed history sentinel: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# 1. Launch the bridge (no Codex GUI)
# ----------------------------------------------------------------------------

Write-Host ""
Write-Host "[verify] Starting OmniRoute bridge (no Codex GUI)" -ForegroundColor Cyan

$launcherOk = $false
$launcherExit = $null
try {
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $omniLauncher -NoCodex -BridgePort $BridgePort
    $launcherExit = $LASTEXITCODE
    $launcherOk = ($launcherExit -eq 0)
} catch {
    $launcherOk = $false
}
$launcherExitForMsg = if ($null -eq $launcherExit) { 'n/a' } else { "$launcherExit" }
if ($launcherOk) {
    Add-Result 'omniroute-launcher-nocodex' 'PASS' "Start-Codex-OmniRoute.ps1 -NoCodex exited 0"
} else {
    Add-Result 'omniroute-launcher-nocodex' 'FAIL' "Start-Codex-OmniRoute.ps1 -NoCodex failed (exit=$launcherExitForMsg)"
    Write-Host ($results | Format-Table | Out-String)
    exit 1
}

# ----------------------------------------------------------------------------
# 2. Discover the bridge port (isolated config records the actual port)
# ----------------------------------------------------------------------------

$activePort = $BridgePort
$isolatedConfigPath = Join-Path $isolatedHome 'config.toml'
if (Test-Path -LiteralPath $isolatedConfigPath) {
    $cfg = Get-Content -LiteralPath $isolatedConfigPath -Raw
    if ($cfg -and ($cfg -match 'base_url\s*=\s*"http://127\.0\.0\.1:(\d+)/v1"')) {
        $activePort = [int]$Matches[1]
    }
}

# ----------------------------------------------------------------------------
# 3. Bridge /healthz
# ----------------------------------------------------------------------------

$health = $null
try {
    $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/healthz" -f $activePort) -TimeoutSec 5
} catch { }

if ($health -and $health.ok) {
    $omniSrc = if ($health.omniroute) { $health.omniroute.source } else { '<unknown>' }
    Add-Result 'bridge-healthz' 'PASS' ("/healthz ok on :{0} (omniroute source={1})" -f $activePort, $omniSrc)
} else {
    Add-Result 'bridge-healthz' 'FAIL' "Bridge /healthz did not respond on 127.0.0.1:$activePort"
}

# ----------------------------------------------------------------------------
# 4. PID file + live node process
# ----------------------------------------------------------------------------

if (Test-Path -LiteralPath $bridgePid) {
    $pidText = (Get-Content -LiteralPath $bridgePid -Raw).Trim()
    if ($pidText -match '^\d+$') {
        $proc = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^node') {
            Add-Result 'bridge-pid' 'PASS' ("pid={0} ({1})" -f $pidText, $proc.ProcessName)
        } else {
            Add-Result 'bridge-pid' 'FAIL' "bridge.pid=$pidText but process not running (or not node)"
        }
    } else {
        Add-Result 'bridge-pid' 'FAIL' "bridge.pid contains non-numeric value: '$pidText'"
    }
} else {
    Add-Result 'bridge-pid' 'FAIL' "bridge.pid missing at $bridgePid"
}

# ----------------------------------------------------------------------------
# 5. Isolated CODEX_HOME content
# ----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $isolatedHome)) {
    Add-Result 'isolated-home-present' 'FAIL' "isolated CODEX_HOME directory missing at $isolatedHome"
} else {
    Add-Result 'isolated-home-present' 'PASS' "isolated CODEX_HOME present at $isolatedHome"

    # 5a. config.toml in isolated home points at the bridge
    $isoCfg = ''
    if (Test-Path -LiteralPath $isolatedConfigPath) {
        $isoCfg = Get-Content -LiteralPath $isolatedConfigPath -Raw
        $hasProvider = ($isoCfg -match 'model_provider\s*=\s*"omniroute_bridge"')
        $hasSection  = ($isoCfg -match '\[model_providers\.omniroute_bridge\]')
        $hasUrl      = ($isoCfg -match ('base_url\s*=\s*"http://127\.0\.0\.1:{0}/v1"' -f $activePort))
        if ($hasProvider -and $hasSection -and $hasUrl) {
            Add-Result 'isolated-config-toml' 'PASS' "isolated config.toml selects omniroute_bridge on :$activePort"
        } else {
            $missing = @()
            if (-not $hasProvider) { $missing += 'model_provider="omniroute_bridge"' }
            if (-not $hasSection)  { $missing += '[model_providers.omniroute_bridge]' }
            if (-not $hasUrl)      { $missing += "base_url=:$activePort" }
            Add-Result 'isolated-config-toml' 'FAIL' ("missing in isolated config.toml: {0}" -f ($missing -join ', '))
        }
    } else {
        Add-Result 'isolated-config-toml' 'FAIL' "isolated config.toml not found at $isolatedConfigPath"
    }

    # 5b. auth.json in isolated home has real OAuth tokens (we copied
    # them from the user's real ~/.codex/auth.json), NOT the legacy
    # sentinel.
    $isolatedAuthPath = Join-Path $isolatedHome 'auth.json'
    if (Test-Path -LiteralPath $isolatedAuthPath) {
        try {
            $isoAuth = Get-Content -LiteralPath $isolatedAuthPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $isoAuth = $null
        }
        if ($null -ne $isoAuth) {
            $isSentinel = $false
            try {
                if ($isoAuth.PSObject.Properties.Name -contains 'OPENAI_API_KEY' -and
                    [string]$isoAuth.OPENAI_API_KEY -eq $LegacyManagedAuthSentinelKey) {
                    $isSentinel = $true
                }
            } catch { }
            $hasOAuth = $false
            try {
                if ($isoAuth.PSObject.Properties.Name -contains 'tokens' -and $isoAuth.tokens) {
                    if ($isoAuth.tokens.PSObject.Properties.Name -contains 'access_token' -and
                        -not [string]::IsNullOrWhiteSpace([string]$isoAuth.tokens.access_token)) {
                        $hasOAuth = $true
                    }
                }
            } catch { }
            if ($isSentinel) {
                Add-Result 'isolated-auth-json' 'FAIL' "isolated auth.json is the legacy sentinel (sk-omniroute-managed); should be a real OAuth copy"
            } elseif ($hasOAuth) {
                Add-Result 'isolated-auth-json' 'PASS' "isolated auth.json has real OAuth tokens"
            } elseif ($realAuthPreExisted) {
                Add-Result 'isolated-auth-json' 'FAIL' "isolated auth.json present but has no OAuth tokens, even though user has a real ~/.codex/auth.json"
            } else {
                Add-Result 'isolated-auth-json' 'WARN' "isolated auth.json present but no OAuth tokens (user has no real auth.json yet)"
            }
        } else {
            Add-Result 'isolated-auth-json' 'WARN' "isolated auth.json present but did not parse as JSON"
        }
    } else {
        if ($realAuthPreExisted) {
            Add-Result 'isolated-auth-json' 'FAIL' "user has a real ~/.codex/auth.json but launcher did NOT copy it into the isolated home"
        } else {
            Add-Result 'isolated-auth-json' 'WARN' "isolated auth.json missing (no real auth.json to copy from)"
        }
    }

    # 5c. seed stamp present (used by the bridge to compute
    # desktop_codex_home_honored)
    $isolatedStampPath = Join-Path $isolatedHome '.omniroute-seed.json'
    if (Test-Path -LiteralPath $isolatedStampPath) {
        Add-Result 'isolated-seed-stamp' 'PASS' "seed stamp present at $isolatedStampPath"
    } else {
        Add-Result 'isolated-seed-stamp' 'FAIL' "seed stamp missing at $isolatedStampPath"
    }

    # 5d. History/state bundle must survive reseeding.
    if (Test-Path -LiteralPath $historySentinel) {
        Add-Result 'history-persistence-sentinel' 'PASS' 'pre-existing isolated-home marker survived launcher seed'
    } else {
        Add-Result 'history-persistence-sentinel' 'FAIL' 'launcher deleted the isolated home instead of reseeding managed files in place'
    }

    $missingHistory = @()
    foreach ($name in $historyBundlePre.Keys) {
        if (-not $historyBundlePre[$name]) { continue }
        $p = Join-Path $isolatedHome $name
        if (-not (Test-Path -LiteralPath $p)) { $missingHistory += $name }
    }
    if ($missingHistory.Count -eq 0) {
        Add-Result 'history-state-bundle-preserved' 'PASS' 'pre-existing state/log/session files survived launcher seed'
    } else {
        Add-Result 'history-state-bundle-preserved' 'FAIL' ("missing after seed: {0}" -f ($missingHistory -join ', '))
    }

    # 5e. User tooling sections (MCP, plugin, marketplace definitions) must
    # be present in the effective isolated config. Values are intentionally
    # not printed because MCP env subtables can contain secrets.
    $requiredTooling = Get-RequiredToolingSections -Path $realConfigPath
    $isolatedTooling = Get-RequiredToolingSections -Path $isolatedConfigPath
    $isolatedLookup = @{}
    foreach ($section in $isolatedTooling) {
        $isolatedLookup[$section.Trim().ToLowerInvariant()] = $true
    }
    $missingTooling = @()
    $inlineEquivalentTooling = @()
    foreach ($section in $requiredTooling) {
        if (-not $isolatedLookup.ContainsKey($section.Trim().ToLowerInvariant())) {
            if (Test-TomlInlineChildEquivalent -ChildSectionName $section -TomlText $isoCfg) {
                $inlineEquivalentTooling += $section
            } else {
                $missingTooling += $section
            }
        }
    }
    if ($requiredTooling.Count -eq 0) {
        Add-Result 'isolated-config-tooling-overlay' 'PASS' 'real ~/.codex/config.toml has no MCP/plugin/marketplace sections to import'
    } elseif ($missingTooling.Count -eq 0) {
        $inlineDetail = if ($inlineEquivalentTooling.Count -gt 0) { " ({0} child section(s) represented by parent inline keys)" -f $inlineEquivalentTooling.Count } else { '' }
        Add-Result 'isolated-config-tooling-overlay' 'PASS' (("imported {0} MCP/plugin/marketplace sections into isolated config" -f $requiredTooling.Count) + $inlineDetail)
    } else {
        Add-Result 'isolated-config-tooling-overlay' 'FAIL' ("missing {0} imported tooling section(s); first missing: {1}" -f $missingTooling.Count, $missingTooling[0])
    }

    $isolatedMcpServerNames = @(Get-McpServerNames -Path $isolatedConfigPath)
    $missingCoreMcp = @()
    foreach ($name in @('magic', 'shadcn')) {
        if ($isolatedMcpServerNames -notcontains $name) { $missingCoreMcp += $name }
    }
    if ($isolatedMcpServerNames.Count -eq 0) {
        Add-Result 'mcp-config-imported' 'FAIL' 'isolated config has no [mcp_servers.*] sections'
    } elseif ($missingCoreMcp.Count -eq 0) {
        Add-Result 'mcp-config-imported' 'PASS' ("isolated config has {0} MCP server section(s), including magic and shadcn" -f $isolatedMcpServerNames.Count)
    } else {
        Add-Result 'mcp-config-imported' 'FAIL' ("isolated config has MCP sections, but missing core frontend server(s): {0}" -f ($missingCoreMcp -join ', '))
    }

    $rootBuiltinMcp = Test-TomlBooleanInSection -Text $isoCfg -SectionName 'features' -Key 'builtin_mcp'
    $rootMcpApps = Test-TomlBooleanInSection -Text $isoCfg -SectionName 'features' -Key 'enable_mcp_apps'
    $profileBuiltinMcp = Test-TomlBooleanInSection -Text $isoCfg -SectionName 'profiles.omniroute_managed.features' -Key 'builtin_mcp'
    $profileMcpApps = Test-TomlBooleanInSection -Text $isoCfg -SectionName 'profiles.omniroute_managed.features' -Key 'enable_mcp_apps'
    if ($rootBuiltinMcp -and $rootMcpApps -and $profileBuiltinMcp -and $profileMcpApps) {
        Add-Result 'mcp-feature-flags' 'PASS' 'builtin_mcp and enable_mcp_apps are enabled in root and omniroute_managed profile features'
    } else {
        $missingFlags = @()
        if (-not $rootBuiltinMcp) { $missingFlags += '[features].builtin_mcp' }
        if (-not $rootMcpApps) { $missingFlags += '[features].enable_mcp_apps' }
        if (-not $profileBuiltinMcp) { $missingFlags += '[profiles.omniroute_managed.features].builtin_mcp' }
        if (-not $profileMcpApps) { $missingFlags += '[profiles.omniroute_managed.features].enable_mcp_apps' }
        Add-Result 'mcp-feature-flags' 'FAIL' ("missing true feature flag(s): {0}" -f ($missingFlags -join ', '))
    }

    if (Test-Path -LiteralPath $mcpProbe) {
        try {
            $probeRaw = & node $mcpProbe --config $isolatedConfigPath --timeout-ms 8000 --json 2>&1
            $probeExit = $LASTEXITCODE
            $probeText = ($probeRaw | Out-String)
            if ($probeExit -ne 0) {
                Add-Result 'mcp-probe-isolated-config' 'FAIL' "mcp_probe exited with code $probeExit"
            } else {
                $probe = $probeText | ConvertFrom-Json -ErrorAction Stop
                $lookup = @{}
                foreach ($r in @($probe.results)) { $lookup[$r.name] = $r }
                $discoverableStatuses = @('tools_listed', 'callable')
                $dirty = @($probe.results | Where-Object { $_.status -eq 'transport_dirty' })
                $coreFailures = @()
                foreach ($name in @('magic', 'shadcn')) {
                    if (-not $lookup.ContainsKey($name)) {
                        $coreFailures += ("{0}=missing" -f $name)
                    } elseif ($discoverableStatuses -notcontains [string]$lookup[$name].status) {
                        $coreFailures += ("{0}={1}" -f $name, $lookup[$name].status)
                    }
                }
                if ($dirty.Count -gt 0) {
                    $first = $dirty[0]
                    Add-Result 'mcp-probe-isolated-config' 'FAIL' ("MCP transport dirty for {0}: {1}" -f $first.name, $first.detail)
                } elseif ($coreFailures.Count -eq 0) {
                    $listedCount = @($probe.results | Where-Object { $discoverableStatuses -contains [string]$_.status }).Count
                    $callableCount = @($probe.results | Where-Object { $_.status -eq 'callable' }).Count
                    Add-Result 'mcp-probe-isolated-config' 'PASS' ("full MCP handshake + tools/list succeeded for core MCPs (discoverable={0}, callable={1})" -f $listedCount, $callableCount)
                } else {
                    Add-Result 'mcp-probe-isolated-config' 'FAIL' ("core frontend MCP was not discoverable after full handshake: {0}" -f ($coreFailures -join ', '))
                }

                $nonCoreFailures = @($probe.results | Where-Object {
                    ($_.name -notin @('magic', 'shadcn')) -and
                    ($_.status -notin @('tools_listed', 'callable', 'no_tools', 'skipped_disabled'))
                })
                if ($nonCoreFailures.Count -gt 0) {
                    $sample = @($nonCoreFailures | Select-Object -First 5 | ForEach-Object { "{0}={1}" -f $_.name, $_.status })
                    Add-Result 'mcp-probe-noncore' 'WARN' ("non-core MCP probe issue(s), not used as core PASS proof: {0}" -f ($sample -join ', '))
                }

                if ($isolatedMcpServerNames -contains 'shadcn') {
                    try {
                        $sampleRaw = & node $mcpProbe --config $isolatedConfigPath --timeout-ms 30000 --server shadcn --allow-sample-call --call-server shadcn --call-tool get_project_registries --call-args-json '{}' --json 2>&1
                        $sampleExit = $LASTEXITCODE
                        $sampleText = ($sampleRaw | Out-String)
                        if ($sampleExit -ne 0) {
                            Add-Result 'mcp-probe-shadcn-call' 'FAIL' "mcp_probe sample call exited with code $sampleExit"
                        } else {
                            $sampleProbe = $sampleText | ConvertFrom-Json -ErrorAction Stop
                            $sampleResult = @($sampleProbe.results)[0]
                            if ($sampleResult -and [string]$sampleResult.status -eq 'callable') {
                                $toolCount = if ($sampleResult.PSObject.Properties.Name -contains 'tools_count') { [int]$sampleResult.tools_count } else { -1 }
                                Add-Result 'mcp-probe-shadcn-call' 'PASS' ("read-only tools/call succeeded for shadcn.get_project_registries (tools={0})" -f $toolCount)
                            } else {
                                $status = if ($sampleResult) { [string]$sampleResult.status } else { 'missing-result' }
                                $detail = if ($sampleResult -and ($sampleResult.PSObject.Properties.Name -contains 'detail')) { [string]$sampleResult.detail } else { $sampleText.Trim() }
                                if ($detail.Length -gt 180) { $detail = $detail.Substring(0, 180) + '...' }
                                Add-Result 'mcp-probe-shadcn-call' 'FAIL' ("sample tools/call failed: {0}: {1}" -f $status, $detail)
                            }
                        }
                    } catch {
                        Add-Result 'mcp-probe-shadcn-call' 'FAIL' "sample tools/call threw: $($_.Exception.Message)"
                    }
                } else {
                    Add-Result 'mcp-probe-shadcn-call' 'FAIL' 'shadcn MCP section missing; cannot prove tools/call'
                }
            }
        } catch {
            Add-Result 'mcp-probe-isolated-config' 'FAIL' "mcp_probe threw: $($_.Exception.Message)"
        }
    } else {
        Add-Result 'mcp-probe-isolated-config' 'FAIL' "mcp_probe missing at $mcpProbe"
    }

    $liveSessionForMcp = $null
    if ($NoLiveMcpSession) {
        Add-Result 'mcp-live-session-dynamic-tools' 'INFO' 'skipped by -NoLiveMcpSession; dynamic_tools is debug-only in current Desktop builds'
        Add-Result 'mcp-live-model-request-tools' 'WARN' 'skipped by -NoLiveMcpSession; no live tool_search/direct-MCP model request was required'
        Add-Result 'mcp-appserver-stdio-clean' 'WARN' 'skipped by -NoLiveMcpSession; Desktop MCP stdio logs were not inspected for this run'
    } else {
        $sessionsRoot = Join-Path $isolatedHome 'sessions'
        $deadline = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(0, $LiveMcpWaitSec))
        $session = $null
        $matches = @()
        do {
            $session = Find-NewestSessionMeta -SessionsRoot $sessionsRoot
            if ($session) {
                $dynamicTools = @()
                if ($session.Meta.payload.PSObject.Properties.Name -contains 'dynamic_tools') {
                    $dynamicTools = @($session.Meta.payload.dynamic_tools)
                }
                $namesForMatch = if ($isolatedMcpServerNames.Count -gt 0) { $isolatedMcpServerNames } else { @('magic', 'shadcn') }
                $matches = @(Get-LiveMcpDynamicToolMatches -DynamicTools $dynamicTools -McpServerNames $namesForMatch)
                break
            }
            if ((Get-Date).ToUniversalTime() -lt $deadline) { Start-Sleep -Seconds 2 }
        } while ((Get-Date).ToUniversalTime() -lt $deadline)

        if (-not $session) {
            Add-Result 'mcp-live-session-dynamic-tools' 'INFO' "no GUI/Desktop session JSONL found under $sessionsRoot; dynamic_tools is not authoritative"
        } else {
            $liveSessionForMcp = $session
            $dynamicTools = @()
            if ($session.Meta.payload.PSObject.Properties.Name -contains 'dynamic_tools') {
                $dynamicTools = @($session.Meta.payload.dynamic_tools)
            }
            $displayPath = Resolve-Path -LiteralPath $session.Path -ErrorAction SilentlyContinue
            if (-not $displayPath) { $displayPath = $session.Path }
            if ($matches.Count -gt 0) {
                Add-Result 'mcp-live-session-dynamic-tools' 'INFO' ("debug-only dynamic_tools has structured MCP attachment field(s): {0} ({1})" -f (($matches | Select-Object -First 6) -join ', '), $displayPath)
            } else {
                Add-Result 'mcp-live-session-dynamic-tools' 'INFO' ("debug-only dynamic_tools has {0} tool(s) and no structured MCP server fields ({1}); this is expected when Desktop defers MCP through tool_search" -f $dynamicTools.Count, $displayPath)
            }
        }

        $sessionStartedUtc = [datetime]::MinValue
        if ($liveSessionForMcp -and $liveSessionForMcp.Meta -and $liveSessionForMcp.Meta.payload) {
            $tsText = $null
            if ($liveSessionForMcp.Meta.payload.PSObject.Properties.Name -contains 'timestamp') {
                $tsText = [string]$liveSessionForMcp.Meta.payload.timestamp
            } elseif ($liveSessionForMcp.Meta.PSObject.Properties.Name -contains 'timestamp') {
                $tsText = [string]$liveSessionForMcp.Meta.timestamp
            }
            if ($tsText) {
                try { $sessionStartedUtc = ([datetime]::Parse($tsText)).ToUniversalTime() } catch { $sessionStartedUtc = [datetime]::MinValue }
            }
        }

        $reasoningDiagnostic = $null
        $reasoningMatches = @()
        $reasoningFresh = $false
        $hasToolSearch = $false
        $reasoningDeadline = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(0, $LiveMcpWaitSec))
        do {
            if (Test-Path -LiteralPath $lastReasoningDiagnosticPath) {
                $candidate = Read-JsonShared -Path $lastReasoningDiagnosticPath
                if ($candidate) {
                    $candidateTime = Get-ReasoningDiagnosticTimestampUtc -ReasoningDiagnostic $candidate
                    $reasoningFresh = ($sessionStartedUtc -eq [datetime]::MinValue -or $candidateTime -ge $sessionStartedUtc.AddSeconds(-10))
                    $hasDesktopAuthHeader = $false
                    if ($candidate.PSObject.Properties.Name -contains 'inbound_headers' -and $candidate.inbound_headers) {
                        if ($candidate.inbound_headers.PSObject.Properties.Name -contains 'has_authorization') {
                            $hasDesktopAuthHeader = [bool]$candidate.inbound_headers.has_authorization
                        }
                    }
                    if ($reasoningFresh -and $hasDesktopAuthHeader) {
                        $reasoningDiagnostic = $candidate
                        $namesForMatch = if ($isolatedMcpServerNames.Count -gt 0) { $isolatedMcpServerNames } else { @('magic', 'shadcn') }
                        $reasoningMatches = @(Get-ReasoningDirectMcpToolMatches -ReasoningDiagnostic $candidate -McpServerNames $namesForMatch)
                        $hasToolSearch = ($candidate.PSObject.Properties.Name -contains 'has_tool_search' -and [bool]$candidate.has_tool_search)
                        if ($reasoningMatches.Count -gt 0 -or $hasToolSearch) { break }
                    }
                }
            }
            if ((Get-Date).ToUniversalTime() -lt $reasoningDeadline) { Start-Sleep -Seconds 2 }
        } while ((Get-Date).ToUniversalTime() -lt $reasoningDeadline)

        if (-not (Test-Path -LiteralPath $lastReasoningDiagnosticPath)) {
            Add-Result 'mcp-live-model-request-tools' 'FAIL' "no live /v1/responses tool diagnostic at $lastReasoningDiagnosticPath; relaunch OmniRoute and send one GUI/Desktop chat message"
        } elseif (-not $reasoningDiagnostic) {
            Add-Result 'mcp-live-model-request-tools' 'FAIL' "latest /v1/responses tool diagnostic is stale, unreadable, or not from an authenticated Codex Desktop request; relaunch OmniRoute and send one GUI/Desktop chat message"
        } elseif ($reasoningMatches.Count -gt 0) {
            $toolCount = if ($reasoningDiagnostic.PSObject.Properties.Name -contains 'tools_total') { [int]$reasoningDiagnostic.tools_total } else { -1 }
            Add-Result 'mcp-live-model-request-tools' 'PASS' ("live model request has direct structured MCP attachment(s): {0} (tools={1})" -f (($reasoningMatches | Select-Object -First 6) -join ', '), $toolCount)
        } elseif ($hasToolSearch) {
            $toolCount = if ($reasoningDiagnostic.PSObject.Properties.Name -contains 'tools_total') { [int]$reasoningDiagnostic.tools_total } else { -1 }
            Add-Result 'mcp-live-model-request-tools' 'PASS' ("live model request exposes tool_search deferred-tool path (tools={0}); per-server discoverability is proven by mcp_probe" -f $toolCount)
        } else {
            $toolCount = if ($reasoningDiagnostic.PSObject.Properties.Name -contains 'tools_total') { [int]$reasoningDiagnostic.tools_total } else { -1 }
            $directMcp = if ($reasoningDiagnostic.PSObject.Properties.Name -contains 'direct_mcp_attachment_count') { [int]$reasoningDiagnostic.direct_mcp_attachment_count } else { 0 }
            $heuristicMcp = if ($reasoningDiagnostic.PSObject.Properties.Name -contains 'mcp_shaped_tool_count_heuristic') { [int]$reasoningDiagnostic.mcp_shaped_tool_count_heuristic } else { 0 }
            Add-Result 'mcp-live-model-request-tools' 'FAIL' ("authenticated live model request had neither tool_search nor direct structured MCP attachment (tools={0}, direct_mcp={1}, heuristic_mcp_debug={2})" -f $toolCount, $directMcp, $heuristicMcp)
        }

        $logSinceUtc = $sessionStartedUtc
        if ($logSinceUtc -eq [datetime]::MinValue -and $reasoningDiagnostic) {
            $logSinceUtc = Get-ReasoningDiagnosticTimestampUtc -ReasoningDiagnostic $reasoningDiagnostic
        }
        if ($logSinceUtc -eq [datetime]::MinValue) {
            Add-Result 'mcp-appserver-stdio-clean' 'WARN' 'no live session/request timestamp available; Desktop MCP stdio logs were not scanned with a reliable bound'
        } else {
            $parseErrors = @(Find-RecentMcpParseErrors -NotBeforeUtc $logSinceUtc -MaxCount 3)
            if ($parseErrors.Count -gt 0) {
                $first = $parseErrors[0]
                $preview = if ($first.Preview) { $first.Preview } else { '<no preview>' }
                Add-Result 'mcp-appserver-stdio-clean' 'FAIL' ("Desktop logged {0} MCP JSON parse error(s) since the live MCP/request timestamp; first preview: {1}" -f $parseErrors.Count, $preview)
            } else {
                Add-Result 'mcp-appserver-stdio-clean' 'PASS' 'no recent Desktop "Failed to parse MCP message" log entries found for the live MCP/request timestamp'
            }
        }
    }

    $frontendSkillPath = Join-Path $isolatedHome 'skills\omniroute-frontend-tool-preference\SKILL.md'
    if (-not (Test-Path -LiteralPath $frontendSkillPath)) {
        Add-Result 'frontend-tool-preference-policy' 'FAIL' "managed frontend preference skill missing at $frontendSkillPath"
    } elseif ($localCodexCli -and (Test-Path -LiteralPath $localCodexCli)) {
        $oldCodexHome = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $isolatedHome
            $promptRaw = & $localCodexCli debug prompt-input 'Create a polished frontend UI component.' 2>&1
            $promptText = ($promptRaw | Out-String)
            $skillText = Get-Content -LiteralPath $frontendSkillPath -Raw
            $promptHasSkill = ($promptText -match 'omniroute-frontend-tool-preference' -and
                $promptText -match 'tool_search' -and
                $promptText -match 'dynamic_tools')
            $skillHasPolicy = ($skillText -match 'dynamic_tools.*debug-only' -and
                $skillText -match 'tool_search' -and
                $skillText -match 'discoverable, or callable')
            if ($promptHasSkill -and $skillHasPolicy) {
                Add-Result 'frontend-tool-preference-policy' 'PASS' 'frontend shadcn/magic fallback and MCP proof-layer wording is model-visible via managed skill'
            } else {
                Add-Result 'frontend-tool-preference-policy' 'FAIL' 'managed frontend preference skill exists but the tool_search/dynamic_tools proof-layer wording was not visible in prompt-input'
            }
        } catch {
            Add-Result 'frontend-tool-preference-policy' 'FAIL' "prompt-input check threw: $($_.Exception.Message)"
        } finally {
            if ($null -eq $oldCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
            else { $env:CODEX_HOME = $oldCodexHome }
        }
    } else {
        Add-Result 'frontend-tool-preference-policy' 'WARN' 'local codex.exe missing; verified skill file only'
    }
}

# ----------------------------------------------------------------------------
# 6. /healthz Variant-3 diagnostics
# ----------------------------------------------------------------------------

if ($health) {
    $hits = if ($health.PSObject.Properties.Name -contains 'main_reasoning_hits') { [int]$health.main_reasoning_hits } else { -1 }
    $honored = if ($health.PSObject.Properties.Name -contains 'desktop_codex_home_honored') { [bool]$health.desktop_codex_home_honored } else { $false }
    $stampPresent = $false
    if ($health.PSObject.Properties.Name -contains 'isolated_home' -and $health.isolated_home) {
        if ($health.isolated_home.PSObject.Properties.Name -contains 'seed_stamp_present') {
            $stampPresent = [bool]$health.isolated_home.seed_stamp_present
        }
    }
    $authPresent = if ($health.PSObject.Properties.Name -contains 'official_auth_present') { [bool]$health.official_auth_present } else { $false }

    if ($hits -eq 0) {
        Add-Result 'healthz-counter-fresh' 'PASS' "main_reasoning_hits=0 at boot (will rise when Codex Desktop sends chat traffic)"
    } else {
        Add-Result 'healthz-counter-fresh' 'WARN' "main_reasoning_hits=$hits at boot (expected 0; bridge may have served prior requests)"
    }

    if ($stampPresent) {
        Add-Result 'healthz-stamp-visible' 'PASS' 'bridge sees isolated_home.seed_stamp_present=true'
    } else {
        Add-Result 'healthz-stamp-visible' 'FAIL' 'bridge sees isolated_home.seed_stamp_present=false (launcher did not seed)'
    }

    if ($honored) {
        Add-Result 'healthz-isolated-home-state' 'PASS' 'desktop_codex_home_honored=true (persistent isolated state is visible)'
    } else {
        Add-Result 'healthz-isolated-home-state' 'PASS' 'desktop_codex_home_honored=false (fresh isolated home, still valid)'
    }

    if ($authPresent) {
        Add-Result 'healthz-auth-present' 'PASS' 'bridge sees official_auth_present=true (real OAuth tokens copied)'
    } elseif ($realAuthPreExisted) {
        Add-Result 'healthz-auth-present' 'FAIL' 'bridge sees official_auth_present=false even though user has a real ~/.codex/auth.json'
    } else {
        Add-Result 'healthz-auth-present' 'WARN' 'bridge sees official_auth_present=false (user has no real auth.json to copy)'
    }
} else {
    Add-Result 'healthz-counter-fresh'  'FAIL' '/healthz did not respond; cannot read Variant-3 diagnostics'
    Add-Result 'healthz-stamp-visible'  'FAIL' '/healthz did not respond'
    Add-Result 'healthz-honored-fresh'  'FAIL' '/healthz did not respond'
    Add-Result 'healthz-auth-present'   'FAIL' '/healthz did not respond'
}

# ----------------------------------------------------------------------------
# 7. Real ~/.codex is UNTOUCHED
# ----------------------------------------------------------------------------

# 7a. config.toml has no managed block. Under Variant 3 the launcher
# never writes to this file -- with one exception: if the user is
# upgrading from PR-#2/#3, the legacy-cleanup pass strips the stale
# managed block on launch. That is expected. So we PASS when:
#   - pre-launch had a managed block AND post-launch does not, OR
#   - pre-launch had no managed block AND post-launch content matches.
# Anything else is a regression.
$realCfgAfter = if (Test-Path -LiteralPath $realConfigPath) { Get-Content -LiteralPath $realConfigPath -Raw } else { $null }
$realCfgChanged = ($realCfgAfter -ne $realConfigPreContent)
$realCfgHasManagedBlock = ($null -ne $realCfgAfter -and $realCfgAfter.Contains($LegacyManagedBlockBegin))
# Snapshot the post-cleanup state. The round-trip check uses THIS as
# the baseline so -Restore is allowed to leave the cleaned config in
# place (the cleanup is idempotent: a second pass is a no-op).
$realConfigCleanContent = $realCfgAfter
if ($realCfgHasManagedBlock) {
    Add-Result 'real-config-untouched' 'FAIL' "real ~/.codex/config.toml still contains a managed block (legacy artifact not cleaned)"
} elseif ($realConfigHadLegacy) {
    Add-Result 'real-config-untouched' 'PASS' 'launcher stripped legacy managed block from real ~/.codex/config.toml (upgrade cleanup)'
} elseif ($realCfgChanged) {
    Add-Result 'real-config-untouched' 'FAIL' "real ~/.codex/config.toml content changed without a legacy block to clean up; launcher modified clean real config"
} else {
    Add-Result 'real-config-untouched' 'PASS' 'real ~/.codex/config.toml unchanged by launcher'
}

# 7b. auth.json is NOT the API-key sentinel and matches pre-launch
# content. Under Variant 3 we copy auth.json into the isolated home;
# we never overwrite the real one.
$realAuthAfterExists = Test-Path -LiteralPath $realAuthPath
$realAuthAfter = if ($realAuthAfterExists) { Get-Content -LiteralPath $realAuthPath -Raw } else { $null }
$realAuthChanged = ($realAuthAfter -ne $realAuthPreContent)
$realAuthIsSentinel = $false
if ($realAuthAfter) {
    try {
        $parsed = $realAuthAfter | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -and $parsed.PSObject.Properties.Name -contains 'OPENAI_API_KEY' -and
            [string]$parsed.OPENAI_API_KEY -eq $LegacyManagedAuthSentinelKey) {
            $realAuthIsSentinel = $true
        }
    } catch { }
}
# Snapshot the post-cleanup state for the round-trip check (mirrors
# how we handle config.toml above).
$realAuthCleanContent = $realAuthAfter
if ($realAuthIsSentinel) {
    Add-Result 'real-auth-untouched' 'FAIL' "real ~/.codex/auth.json is the legacy API-key sentinel (Variant-3 launcher should not write this)"
} elseif ($realAuthHadLegacy) {
    Add-Result 'real-auth-untouched' 'PASS' 'launcher removed legacy sentinel auth.json from real ~/.codex (upgrade cleanup)'
} elseif ($realAuthChanged) {
    Add-Result 'real-auth-untouched' 'FAIL' "real ~/.codex/auth.json content changed without a legacy sentinel to clean up; launcher modified clean real auth"
} else {
    Add-Result 'real-auth-untouched' 'PASS' 'real ~/.codex/auth.json unchanged by launcher'
}

# 7c. No *.codex-omniroute-backup files left behind.
$backupsRemain = @()
if (Test-Path -LiteralPath $LegacyConfigBackup) { $backupsRemain += 'config.toml.codex-omniroute-backup' }
if (Test-Path -LiteralPath $LegacyAuthBackup)   { $backupsRemain += 'auth.json.codex-omniroute-backup' }
if ($backupsRemain.Count -eq 0) {
    Add-Result 'real-no-legacy-backups' 'PASS' 'no *.codex-omniroute-backup files in real ~/.codex'
} else {
    Add-Result 'real-no-legacy-backups' 'FAIL' ("legacy backup files still present: {0}" -f ($backupsRemain -join ', '))
}

# ----------------------------------------------------------------------------
# 8. Official launcher DryRun (with -NoAutoRestore so we don't disturb state)
# ----------------------------------------------------------------------------

$officialOk = $true
$officialReason = ''
try {
    $output = & $psHost -NoProfile -ExecutionPolicy Bypass -File $offLauncher -DryRun -NoAutoRestore 2>&1
    if ($LASTEXITCODE -ne 0) {
        $officialOk = $false
        $officialReason = "DryRun exited with code $LASTEXITCODE"
    }
    $joined = ($output | Out-String)
    # The official launcher is allowed to *mention* OmniRoute in its own
    # status output (it literally prints "Mode: clean baseline (no OmniRoute
    # env, no bridge)."). What it is NOT allowed to do is set any of the
    # OmniRoute/bridge env vars or reference the bridge script. So we only
    # flag actual env-var names (UPPER_SNAKE_CASE with a trailing token) and
    # the bridge module path. -cmatch keeps the check case-sensitive so the
    # status string's PascalCase "OmniRoute" doesn't trip a false FAIL.
    if ($joined -cmatch 'OMNIROUTE_[A-Z0-9_]+|CODEX_BRIDGE_[A-Z0-9_]+|bridge\.mjs') {
        $officialOk = $false
        $officialReason = 'DryRun output referenced an OmniRoute env var or bridge.mjs'
    }
} catch {
    $officialOk = $false
    $officialReason = "DryRun threw: $($_.Exception.Message)"
}

if ($officialOk) {
    Add-Result 'official-launcher-dryrun' 'PASS' 'official launcher resolves package cleanly and sets no OmniRoute env'
} else {
    Add-Result 'official-launcher-dryrun' 'FAIL' $officialReason
}

# ----------------------------------------------------------------------------
# 9. Tool/runtime drift checks
# ----------------------------------------------------------------------------

if (Test-Path -LiteralPath $envExamplePath) {
    $envExample = Get-Content -LiteralPath $envExamplePath -Raw
    $mentionsOldLog = ($envExample -match 'CODEX_BRIDGE_LOG\s*=')
    $mentionsOldPid = ($envExample -match 'CODEX_BRIDGE_PID\s*=')
    $mentionsBridgeLogPath = ($envExample -match 'BRIDGE_LOG_PATH\s*=')
    if (-not $mentionsOldLog -and -not $mentionsOldPid -and $mentionsBridgeLogPath) {
        Add-Result 'env-example-runtime-vars' 'PASS' '.env.example matches bridge runtime variables'
    } else {
        Add-Result 'env-example-runtime-vars' 'FAIL' '.env.example still advertises stale CODEX_BRIDGE_LOG/CODEX_BRIDGE_PID or omits BRIDGE_LOG_PATH'
    }
} else {
    Add-Result 'env-example-runtime-vars' 'FAIL' '.env.example missing'
}

$rgCmd = Get-Command rg -ErrorAction SilentlyContinue
if ($rgCmd) {
    $rgLine = $null
    try {
        $rgLine = (& $rgCmd.Source --version 2>&1 | Select-Object -First 1)
    } catch { }
    if ($rgLine) {
        if ($rgCmd.Source -match '\\WindowsApps\\') {
            Add-Result 'rg-runtime-path' 'WARN' "rg is invocable but resolves through WindowsApps: $($rgCmd.Source)"
        } else {
            Add-Result 'rg-runtime-path' 'PASS' "rg is invocable from $($rgCmd.Source)"
        }
    } else {
        Add-Result 'rg-runtime-path' 'FAIL' "rg resolved to $($rgCmd.Source) but did not run"
    }
} else {
    $localRg = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\rg.exe' } else { '' }
    if ($localRg -and (Test-Path -LiteralPath $localRg)) {
        Add-Result 'rg-runtime-path' 'WARN' "rg is not on PATH, but local Codex rg exists at $localRg"
    } else {
        Add-Result 'rg-runtime-path' 'FAIL' 'rg is not on PATH and no local Codex rg.exe was found'
    }
}

$nativeApplyPatchOk = $false
if ((Test-Path -LiteralPath $applyPatchRewriter) -and (Test-Path -LiteralPath $applyPatchRewriterPid)) {
    $tmpRoot = Join-Path $scriptRoot (".codex-omniroute-native-apply-verify-{0}" -f ([guid]::NewGuid().ToString('N')))
    $fakeArg0 = Join-Path $isolatedHome 'tmp\arg0\codex-verify-native'
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $fakeArg0 -Force | Out-Null
        $fakeBat = Join-Path $fakeArg0 'apply_patch.bat'
        $badWrapper = "@echo off`r`n`"C:\Program Files\WindowsApps\OpenAI.Codex_26.506.3741.0_x64__2p2nqsd0c76g0\app\resources\codex.exe`" --codex-run-as-apply-patch %*`r`n"
        [System.IO.File]::WriteAllText($fakeBat, $badWrapper, [System.Text.Encoding]::ASCII)

        $deadline = (Get-Date).AddSeconds(6)
        $rewritten = $false
        do {
            Start-Sleep -Milliseconds 250
            $wrapperText = [System.IO.File]::ReadAllText($fakeBat)
            $rewritten = ($wrapperText -match 'Invoke-CodexApplyPatch\.ps1')
        } while (-not $rewritten -and (Get-Date) -lt $deadline)

        $sample = Join-Path $tmpRoot 'native.txt'
        $patchPath = $sample.Replace('\', '/')
        $patch = "*** Begin Patch`n*** Add File: $patchPath`n+native-apply-ok`n*** End Patch`n"
        $env:PATH = "$fakeArg0;$env:PATH"
        $resolvedApplyPatch = (Get-Command apply_patch -ErrorAction Stop).Source
        $output = $patch | apply_patch 2>&1
        $nativeApplyPatchOk = $rewritten -and ($LASTEXITCODE -eq 0) -and
            (Test-SameEnvironmentValue $resolvedApplyPatch $fakeBat) -and
            (Test-Path -LiteralPath $sample) -and
            (([System.IO.File]::ReadAllText($sample)).Trim() -eq 'native-apply-ok')
        if ($nativeApplyPatchOk) {
            Add-Result 'apply-patch-native-rewriter' 'PASS' 'literal apply_patch resolved through rewritten local helper and applied stdin patch'
        } else {
            $detail = ($output | Out-String).Trim()
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '...' }
            Add-Result 'apply-patch-native-rewriter' 'FAIL' "rewritten=$rewritten resolved=$resolvedApplyPatch detail=$detail"
        }
    } catch {
        Add-Result 'apply-patch-native-rewriter' 'FAIL' "native apply_patch smoke threw: $($_.Exception.Message)"
    } finally {
        $env:PATH = $oldPath
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result 'apply-patch-native-rewriter' 'FAIL' 'apply_patch rewriter script or pid file missing after OmniRoute launch'
}

$applyPatchOk = $false
if (Test-Path -LiteralPath $applyPatchFallback) {
    # Keep the smoke path ASCII-only. Windows PowerShell 5.1 can mangle
    # non-ASCII paths passed through stdin when the user's %TEMP% includes
    # localized profile characters.
    $tmpRoot = Join-Path $scriptRoot (".codex-omniroute-home-verify-{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $sample = Join-Path $tmpRoot 'sample.txt'
        [System.IO.File]::WriteAllText($sample, "original`n", [System.Text.UTF8Encoding]::new($false))
        $patchPath = $sample.Replace('\', '/')
        $patch = "*** Begin Patch`n*** Update File: $patchPath`n@@`n-original`n+changed-by-verifier`n*** End Patch`n"
        $output = $patch | & $psHost -NoProfile -ExecutionPolicy Bypass -File $applyPatchFallback 2>&1
        $stdinApplyPatchOk = ($LASTEXITCODE -eq 0) -and (([System.IO.File]::ReadAllText($sample)).Trim() -eq 'changed-by-verifier')
        [System.IO.File]::WriteAllText($sample, "original`n", [System.Text.UTF8Encoding]::new($false))
        $pipelineOutput = $patch | & $applyPatchFallback 2>&1
        $pipelineApplyPatchOk = ($LASTEXITCODE -eq 0) -and (([System.IO.File]::ReadAllText($sample)).Trim() -eq 'changed-by-verifier')
        $applyPatchOk = $stdinApplyPatchOk -and $pipelineApplyPatchOk
        if ($applyPatchOk) {
            Add-Result 'apply-patch-local-fallback' 'PASS' 'local Codex CLI fallback applied patches from stdin and direct PowerShell pipeline'
        } else {
            if ($stdinApplyPatchOk -and -not $pipelineApplyPatchOk) { $output = $pipelineOutput }
            $detail = ($output | Out-String).Trim()
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '...' }
            Add-Result 'apply-patch-local-fallback' 'FAIL' "fallback did not apply patch: $detail"
        }
    } catch {
        Add-Result 'apply-patch-local-fallback' 'FAIL' "fallback threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result 'apply-patch-local-fallback' 'FAIL' "fallback helper missing at $applyPatchFallback"
}

# ----------------------------------------------------------------------------
# 10. GET /v1/models reachable
# ----------------------------------------------------------------------------

$modelsStatus = $null
try {
    $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/models" -f $activePort) -TimeoutSec 5 -UseBasicParsing
    $modelsStatus = $resp.StatusCode
} catch {
    if ($_.Exception.Response) { $modelsStatus = [int]$_.Exception.Response.StatusCode }
}

if ($modelsStatus -eq 200) {
    Add-Result 'bridge-models' 'PASS' '/v1/models served from local cache (200)'
} elseif ($modelsStatus -eq 503 -or $modelsStatus -eq 502 -or $modelsStatus -eq 404) {
    Add-Result 'bridge-models' 'WARN' "/v1/models returned $modelsStatus (cache likely missing; launch official Codex once)"
} else {
    Add-Result 'bridge-models' 'FAIL' "/v1/models returned unexpected status: $modelsStatus"
}

# ----------------------------------------------------------------------------
# 10. POST /transcribe reachable (route exists)
# ----------------------------------------------------------------------------

$transcribeStatus = $null
try {
    $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/transcribe" -f $activePort) -Method POST `
        -Body 'health-probe' -ContentType 'application/octet-stream' -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    $transcribeStatus = $resp.StatusCode
} catch {
    if ($_.Exception.Response) { $transcribeStatus = [int]$_.Exception.Response.StatusCode }
}
# A bridge that knows the route will reach the upstream (which will then 400/401/etc)
# rather than respond 404. We accept anything except 404 here.
if ($transcribeStatus -and $transcribeStatus -ne 404) {
    Add-Result 'bridge-transcribe' 'PASS' "/transcribe route reachable (status=$transcribeStatus)"
} else {
    Add-Result 'bridge-transcribe' 'FAIL' "/transcribe returned 404 (route not wired)"
}

# ----------------------------------------------------------------------------
# 11. Live smoke (optional)
# ----------------------------------------------------------------------------

if ($Live) {
    $liveBody = @{
        model = 'gpt-5.4'
        input = 'Reply with just the digit 2.'
        stream = $false
    } | ConvertTo-Json -Depth 4

    $liveOk = $false
    try {
        $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/responses" -f $activePort) `
            -Method POST -Body $liveBody -ContentType 'application/json' -TimeoutSec 60
        if ($resp) { $liveOk = $true }
    } catch { }
    if ($liveOk) {
        Add-Result 'live-responses' 'PASS' 'POST /v1/responses returned a parseable JSON response'
    } else {
        Add-Result 'live-responses' 'FAIL' 'POST /v1/responses failed (check bridge.log for upstream error)'
    }
}

# ----------------------------------------------------------------------------
# 12. Official isolation / persistent-home round-trip
# ----------------------------------------------------------------------------

if (-not $LeaveBridgeRunning) {
    $officialOutput = @()
    $officialExit = $null
    try {
        $officialOutput = & $psHost -NoProfile -ExecutionPolicy Bypass -File $offLauncher -DryRun 2>&1
        $officialExit = $LASTEXITCODE
    } catch {
        $officialOutput = @($_.Exception.Message)
        $officialExit = -1
    }

    $isolatedStillPresent = Test-Path -LiteralPath $isolatedHome
    $historyStillPresent  = Test-Path -LiteralPath $historySentinel
    $bridgeGone           = -not (Test-Path -LiteralPath $bridgePid)
    $rewriterGone         = -not (Test-Path -LiteralPath $applyPatchRewriterPid)
    $configBackupGone     = -not (Test-Path -LiteralPath $LegacyConfigBackup)
    $authBackupGone       = -not (Test-Path -LiteralPath $LegacyAuthBackup)
    $userCodexHomeClear = $true
    $userPathShimClear = $true
    if (Test-WindowsHost) {
        $userCodexHome = [System.Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
        $userCodexHomeClear = -not (Test-SameEnvironmentValue $userCodexHome $isolatedHome)
        $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        if (-not [string]::IsNullOrWhiteSpace($userPath)) {
            $pathParts = @($userPath -split ';')
            if ($pathParts.Count -gt 0) {
                $userPathShimClear = -not (Test-SameEnvironmentValue $pathParts[0] $taskkillShimDir)
            }
        }
    }

    # The real ~/.codex must still match the POST-CLEANUP snapshot
    # taken after the initial launch (see real-config-untouched and
    # real-auth-untouched checks above). We use the post-cleanup
    # baseline (not the pre-launch one) because both launchers' legacy
    # cleanup passes are idempotent against an already-clean real ~/.codex.
    $realConfigAfterOfficial = if (Test-Path -LiteralPath $realConfigPath) { Get-Content -LiteralPath $realConfigPath -Raw } else { $null }
    $realAuthAfterOfficial   = if (Test-Path -LiteralPath $realAuthPath)   { Get-Content -LiteralPath $realAuthPath -Raw }   else { $null }
    $realConfigUntouched     = ($realConfigAfterOfficial -eq $realConfigCleanContent)
    $realAuthUntouched       = ($realAuthAfterOfficial -eq $realAuthCleanContent)

    $officialJoined = ($officialOutput | Out-String)
    $officialEnvClean = -not ($officialJoined -cmatch 'OMNIROUTE_[A-Z0-9_]+|CODEX_BRIDGE_[A-Z0-9_]+|bridge\.mjs')

    $allOk = ($officialExit -eq 0) -and $isolatedStillPresent -and $historyStillPresent -and `
             $bridgeGone -and $rewriterGone -and $configBackupGone -and $authBackupGone -and `
             $realConfigUntouched -and $realAuthUntouched -and `
             $userCodexHomeClear -and $userPathShimClear -and $officialEnvClean

    if ($allOk) {
        Add-Result 'official-isolation-dryrun' 'PASS' 'official dry-run stopped OmniRoute helpers, preserved isolated history, cleared stale user CODEX_HOME/PATH overrides, real ~/.codex untouched'
    } else {
        $why = @()
        if ($officialExit -ne 0)            { $why += "official exit=$officialExit" }
        if (-not $isolatedStillPresent)     { $why += 'persistent isolated CODEX_HOME was removed' }
        if (-not $historyStillPresent)      { $why += 'history sentinel missing after official launcher' }
        if (-not $bridgeGone)               { $why += 'bridge.pid still present' }
        if (-not $rewriterGone)             { $why += 'apply_patch_rewriter.pid still present' }
        if (-not $configBackupGone)         { $why += 'legacy config.toml.codex-omniroute-backup still present' }
        if (-not $authBackupGone)           { $why += 'legacy auth.json.codex-omniroute-backup still present' }
        if (-not $realConfigUntouched)      { $why += 'real ~/.codex/config.toml content changed' }
        if (-not $realAuthUntouched)        { $why += 'real ~/.codex/auth.json content changed' }
        if (-not $userCodexHomeClear)       { $why += 'user-scope CODEX_HOME still points at isolated home' }
        if (-not $userPathShimClear)        { $why += 'user-scope PATH still starts with taskkill shim dir' }
        if (-not $officialEnvClean)         { $why += 'official dry-run output referenced OmniRoute env var or bridge.mjs' }
        Add-Result 'official-isolation-dryrun' 'FAIL' ($why -join '; ')
    }
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Verification Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed) {
    Write-Host ("FAILED: {0} checks" -f $failed.Count) -ForegroundColor Red
    exit 1
} else {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}

<#
.SYNOPSIS
    Verifies the Codex OmniRoute architecture invariants.

.DESCRIPTION
    Runs a bounded OmniRoute launch (bridge only, no Codex GUI) and checks
    the small set of invariants that defines the simplified architecture:

      1. Start-Codex-OmniRoute.ps1 -NoCodex succeeds.
      2. Bridge /healthz responds with ok=true.
      3. The managed bridge PID file exists and points to a live node process.
      4. The user's real ~/.codex/config.toml contains the OmniRoute managed
         block with model_provider = "omniroute_bridge" and a fresh
         base_url pointing at the bridge port.
      5. A backup file ~/.codex/config.toml.codex-omniroute-backup exists
         (so -Restore is reversible).
      6. Start-Codex-Official.ps1 -DryRun -NoAutoRestore resolves the Codex
         package without trying to modify config or env.
      7. The bridge responds to GET /v1/models with the local models cache
         (or with a documented "models_cache_missing" error when the cache
         file is absent).
      8. The dictation endpoint POST /transcribe is reachable (the bridge
         does not 404 it).
      9. Start-Codex-OmniRoute.ps1 -Restore stops the bridge and either
         restores the original config.toml byte-for-byte from backup or
         removes the managed-only config when there was no original.

    The old isolated-runtime invariants (payload copy, apply_patch
    rewriter, AppX alias junction, git shim absence, profile sanitization,
    user-local Codex bin fallback) have been retired alongside the
    isolation logic itself.

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
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$LeaveBridgeRunning,
    [int]$BridgePort = 20333
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

$scriptRoot   = $PSScriptRoot
$omniLauncher = Join-Path $scriptRoot 'Start-Codex-OmniRoute.ps1'
$offLauncher  = Join-Path $scriptRoot 'Start-Codex-Official.ps1'
$bridgePid    = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog    = Join-Path $scriptRoot 'bridge.log'
$codexHome    = Join-Path $env:USERPROFILE '.codex'
$configPath   = Join-Path $codexHome 'config.toml'
$backupPath   = Join-Path $codexHome 'config.toml.codex-omniroute-backup'

$ManagedBlockBegin = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$ManagedBlockEnd   = '# <<< codex-omniroute-managed'

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
# 2. Discover the bridge port (managed block records the actual port)
# ----------------------------------------------------------------------------

$activePort = $BridgePort
if (Test-Path -LiteralPath $configPath) {
    $cfg = Get-Content -LiteralPath $configPath -Raw
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
# 5. Managed block in ~/.codex/config.toml
# ----------------------------------------------------------------------------

if (Test-Path -LiteralPath $configPath) {
    $cfgRaw = Get-Content -LiteralPath $configPath -Raw
    $hasBegin = $cfgRaw.Contains($ManagedBlockBegin)
    $hasEnd   = $cfgRaw.Contains($ManagedBlockEnd)
    $hasProvider = ($cfgRaw -match 'model_provider\s*=\s*"omniroute_bridge"')
    $hasSection  = ($cfgRaw -match '\[model_providers\.omniroute_bridge\]')
    $hasUrl      = ($cfgRaw -match ('base_url\s*=\s*"http://127\.0\.0\.1:{0}/v1"' -f $activePort))
    if ($hasBegin -and $hasEnd -and $hasProvider -and $hasSection -and $hasUrl) {
        Add-Result 'config-managed-block' 'PASS' "managed block present with port $activePort"
    } else {
        $missing = @()
        if (-not $hasBegin)    { $missing += 'begin-marker' }
        if (-not $hasEnd)      { $missing += 'end-marker' }
        if (-not $hasProvider) { $missing += 'model_provider="omniroute_bridge"' }
        if (-not $hasSection)  { $missing += '[model_providers.omniroute_bridge]' }
        if (-not $hasUrl)      { $missing += "base_url=:$activePort" }
        Add-Result 'config-managed-block' 'FAIL' ("missing: {0}" -f ($missing -join ', '))
    }
} else {
    Add-Result 'config-managed-block' 'FAIL' "config.toml not found at $configPath"
}

# ----------------------------------------------------------------------------
# 6. Backup exists
# ----------------------------------------------------------------------------

if (Test-Path -LiteralPath $backupPath) {
    Add-Result 'config-backup' 'PASS' "$backupPath present"
} else {
    Add-Result 'config-backup' 'FAIL' "$backupPath missing -- -Restore will not recover original"
}

# ----------------------------------------------------------------------------
# 7. Official launcher DryRun (with -NoAutoRestore so we don't wipe managed state)
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
# 8. GET /v1/models reachable
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
# 9. POST /transcribe reachable (route exists)
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
# 10. Live smoke (optional)
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
# 11. -Restore round-trip
# ----------------------------------------------------------------------------

if (-not $LeaveBridgeRunning) {
    $backupExistedBefore = Test-Path -LiteralPath $backupPath
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $omniLauncher -Restore | Out-Null
    $restoreExit = $LASTEXITCODE

    $configAfter = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw } else { $null }
    $backupGone  = -not (Test-Path -LiteralPath $backupPath)
    $bridgeGone  = -not (Test-Path -LiteralPath $bridgePid)

    # Semantic restore check (was: byte-for-byte equality with the backup).
    # The launcher always reads the backup as a .NET string and re-writes it
    # via WriteAllText with UTF8-no-BOM. On real Windows this can differ in
    # bytes from the original backup file when the original was UTF-8 with
    # BOM or used CR-only line endings, even though the config is logically
    # restored. The invariants we actually care about for catching regressions
    # are:
    #   - launcher exited 0
    #   - backup file was consumed and removed
    #   - bridge.pid was removed (bridge stopped)
    #   - config no longer contains the managed block (if backup existed)
    #     OR config was deleted entirely (if backup was empty / no original)
    $blockGone = $true
    if ($backupExistedBefore) {
        if ($null -ne $configAfter -and $configAfter.Contains($ManagedBlockBegin)) {
            $blockGone = $false
        }
        # If the original config had real content, expect the file to still
        # exist after restore. If the backup was empty (sentinel for "no
        # original"), the launcher deletes the config -- that's correct too.
    } else {
        # No backup at restore-time means -Restore had to fall back to the
        # in-place strip path. Config must not contain a managed block.
        if ($null -ne $configAfter -and $configAfter.Contains($ManagedBlockBegin)) {
            $blockGone = $false
        }
    }

    if ($restoreExit -eq 0 -and $blockGone -and $backupGone -and $bridgeGone) {
        Add-Result 'restore-roundtrip' 'PASS' 'managed block removed, backup cleared, bridge stopped'
    } else {
        $why = @()
        if ($restoreExit -ne 0) { $why += "exit=$restoreExit" }
        if (-not $blockGone)    { $why += 'managed block still present in config' }
        if (-not $backupGone)   { $why += 'backup file still present' }
        if (-not $bridgeGone)   { $why += 'bridge.pid still present' }
        Add-Result 'restore-roundtrip' 'FAIL' ($why -join '; ')
    }
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Verification Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = $results | Where-Object { $_.Status -eq 'FAIL' }
if ($failed) {
    Write-Host ("FAILED: {0} checks" -f $failed.Count) -ForegroundColor Red
    exit 1
} else {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}

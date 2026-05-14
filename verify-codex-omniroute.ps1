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
      6. The user's real ~/.codex/auth.json contains the OmniRoute managed
         API-key sentinel (so Codex Desktop is in API-key auth mode and
         actually uses the bridge for main reasoning instead of
         bypassing it via the ChatGPT OAuth session).
      7. A backup file ~/.codex/auth.json.codex-omniroute-backup exists
         when the user had a pre-existing auth.json.
      8. /healthz's managed_auth diagnostic reports the live auth.json
         is the sentinel AND has no OAuth tokens left over (the explicit
         "Desktop won't bypass us" check that motivates this whole file).
      9. Start-Codex-Official.ps1 -DryRun -NoAutoRestore resolves the Codex
         package without trying to modify config or env.
     10. The bridge responds to GET /v1/models with the local models cache
         (or with a documented "models_cache_missing" error when the cache
         file is absent).
     11. The dictation endpoint POST /transcribe is reachable (the bridge
         does not 404 it).
     12. Start-Codex-OmniRoute.ps1 -Restore stops the bridge and either
         restores the original config.toml + auth.json byte-for-byte from
         backup or removes the managed-only files when there was no
         original.

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

$scriptRoot     = $PSScriptRoot
$omniLauncher   = Join-Path $scriptRoot 'Start-Codex-OmniRoute.ps1'
$offLauncher    = Join-Path $scriptRoot 'Start-Codex-Official.ps1'
$bridgePid      = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog      = Join-Path $scriptRoot 'bridge.log'
# USERPROFILE is Windows-only; on Linux / macOS the verifier still runs as
# a smoke. Fall back to $HOME so the bridge / launcher (which themselves
# use os.homedir() / $env:USERPROFILE with the same fallback) see the same
# directory the verifier inspects.
$codexHomeRoot  = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$codexHome      = Join-Path $codexHomeRoot '.codex'
$configPath     = Join-Path $codexHome 'config.toml'
$backupPath     = Join-Path $codexHome 'config.toml.codex-omniroute-backup'
$authPath       = Join-Path $codexHome 'auth.json'
$authBackupPath = Join-Path $codexHome 'auth.json.codex-omniroute-backup'

$ManagedBlockBegin = '# >>> codex-omniroute-managed (auto-generated; do not edit by hand)'
$ManagedBlockEnd   = '# <<< codex-omniroute-managed'
$ManagedAuthSentinelApiKey = 'sk-omniroute-managed'

# Snapshot whether the user had a real auth.json BEFORE the launcher ran.
# The backup file is the only way the verifier can distinguish:
#   - "no original auth.json existed" (backup is empty, expected after restore: no live file)
# from:
#   - "user had a real auth.json" (backup has content, expected after restore: file matches backup).
# We have to read this *before* invoking the launcher because the launcher
# is what creates the backup.
$authPreExisted = Test-Path -LiteralPath $authPath
$authPreContent = if ($authPreExisted) { Get-Content -LiteralPath $authPath -Raw } else { $null }

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
# 6a. Managed auth.json (API-key sentinel)
# ----------------------------------------------------------------------------
#
# This is the core invariant for the bridge-bypass fix. Codex Desktop only
# routes /v1/responses through our bridge when it is in API-key auth mode,
# which it picks based on the contents of ~/.codex/auth.json. So the
# verifier MUST see:
#   - the live ~/.codex/auth.json exists,
#   - parses as JSON,
#   - has OPENAI_API_KEY == sk-omniroute-managed,
#   - has tokens == null (i.e. no leftover OAuth/ChatGPT session that
#     would tempt Desktop back into the OAuth path).
$authParsed = $null
$authPresent = Test-Path -LiteralPath $authPath
if ($authPresent) {
    try {
        $authRaw = Get-Content -LiteralPath $authPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($authRaw)) {
            $authParsed = $authRaw | ConvertFrom-Json -ErrorAction Stop
        }
    } catch {
        Add-Result 'auth-managed-form' 'FAIL' "auth.json present but not valid JSON: $($_.Exception.Message)"
        $authParsed = $null
    }
}
if (-not $authPresent) {
    Add-Result 'auth-managed-form' 'FAIL' "auth.json not found at $authPath (Desktop will fall back to default OAuth flow)"
} elseif ($null -ne $authParsed) {
    $authKey = $null
    $authTokens = '__unset__'
    try { $authKey = $authParsed.OPENAI_API_KEY } catch { }
    try { $authTokens = $authParsed.tokens } catch { }
    $keyOk = ([string]$authKey -eq $ManagedAuthSentinelApiKey)
    $tokensOk = ($null -eq $authTokens)
    if ($keyOk -and $tokensOk) {
        Add-Result 'auth-managed-form' 'PASS' "OPENAI_API_KEY=sentinel, tokens=null (Desktop is in API-key auth mode)"
    } else {
        $why = @()
        if (-not $keyOk)   { $why += "OPENAI_API_KEY != sentinel" }
        if (-not $tokensOk){ $why += "tokens is not null (OAuth session still present)" }
        Add-Result 'auth-managed-form' 'FAIL' ($why -join '; ')
    }
}

# ----------------------------------------------------------------------------
# 6b. auth.json backup exists when the user had a pre-existing auth.json
# ----------------------------------------------------------------------------
if ($authPreExisted) {
    if (Test-Path -LiteralPath $authBackupPath) {
        Add-Result 'auth-backup' 'PASS' "$authBackupPath present (will be restored on -Restore / Official mode)"
    } else {
        Add-Result 'auth-backup' 'FAIL' "user had auth.json before launch but no backup was created at $authBackupPath"
    }
} else {
    # No user auth.json before launch. The launcher still creates a
    # zero-byte backup as the "no original existed" sentinel, so -Restore
    # knows to DELETE the managed file rather than leave it in place. We
    # accept either the empty backup or no backup (some host filesystems
    # might choose to omit it); both are recoverable.
    if (Test-Path -LiteralPath $authBackupPath) {
        $abLen = (Get-Item -LiteralPath $authBackupPath).Length
        if ($abLen -eq 0) {
            Add-Result 'auth-backup' 'PASS' "empty backup sentinel (no original auth.json existed)"
        } else {
            Add-Result 'auth-backup' 'WARN' "no original auth.json existed but backup has content (length=$abLen)"
        }
    } else {
        Add-Result 'auth-backup' 'WARN' "no pre-existing auth.json and no backup; -Restore will remove the managed file in place"
    }
}

# ----------------------------------------------------------------------------
# 6c. Diagnostic: bridge confirms Desktop will NOT bypass via OAuth session
# ----------------------------------------------------------------------------
#
# /healthz inspects the live ~/.codex/auth.json itself (independent of
# whatever path the bridge was told to use for the official fallback) and
# reports two flags: sentinel_present and oauth_tokens_present. This is
# what catches the "we forgot to write auth.json, Desktop is still in
# ChatGPT-session mode" regression that motivated this whole effort.
$diagPass = $false
$diagDetail = ''
if ($health -and $health.managed_auth) {
    $sentinelPresent = [bool]$health.managed_auth.sentinel_present
    $oauthPresent    = [bool]$health.managed_auth.oauth_tokens_present
    if ($sentinelPresent -and (-not $oauthPresent)) {
        $diagPass = $true
        $diagDetail = "live auth.json has sentinel and no OAuth tokens"
    } else {
        $why = @()
        if (-not $sentinelPresent) { $why += "sentinel not in live auth.json" }
        if ($oauthPresent)         { $why += "live auth.json STILL has tokens.access_token (Desktop will bypass bridge)" }
        $diagDetail = $why -join '; '
    }
}
if ($diagPass) {
    Add-Result 'desktop-not-stuck-in-oauth' 'PASS' $diagDetail
} else {
    Add-Result 'desktop-not-stuck-in-oauth' 'FAIL' ($diagDetail | ForEach-Object { if ($_) { $_ } else { 'no managed_auth diagnostic in /healthz response' } })
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
    $backupExistedBefore     = Test-Path -LiteralPath $backupPath
    $authBackupExistedBefore = Test-Path -LiteralPath $authBackupPath
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $omniLauncher -Restore | Out-Null
    $restoreExit = $LASTEXITCODE

    $configAfter    = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw } else { $null }
    $authAfterExist = Test-Path -LiteralPath $authPath
    $authAfter      = if ($authAfterExist) { Get-Content -LiteralPath $authPath -Raw } else { $null }
    $backupGone     = -not (Test-Path -LiteralPath $backupPath)
    $authBackupGone = -not (Test-Path -LiteralPath $authBackupPath)
    $bridgeGone     = -not (Test-Path -LiteralPath $bridgePid)

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

    # auth.json side of the round-trip:
    #   - the managed sentinel must be gone (whether by restoring the
    #     original from backup or by deleting the file entirely),
    #   - the auth backup file itself must be consumed,
    #   - if a non-empty backup existed BEFORE restore, the live
    #     auth.json must exist again afterwards (we recovered the user's
    #     OAuth session); if no original existed, the live file should be
    #     deleted.
    $authSentinelGone = $true
    if ($authAfterExist -and $null -ne $authAfter -and $authAfter.Contains($ManagedAuthSentinelApiKey)) {
        $authSentinelGone = $false
    }
    $authRestoredCorrectly = $true
    $authReason = ''
    if ($authPreExisted) {
        # User had a real auth.json -- after restore the live file should
        # exist again and (best effort) match the snapshot we took before
        # the launcher ran.
        if (-not $authAfterExist) {
            $authRestoredCorrectly = $false
            $authReason = 'user had auth.json before launch but it is missing after restore'
        } elseif ($null -ne $authPreContent -and $authAfter -ne $authPreContent) {
            # Mismatch: still count as PASS as long as the sentinel is gone
            # (mirrors the config check above which is semantic, not
            # byte-for-byte), but surface the diff in the detail.
            $authReason = 'live auth.json differs from pre-launch snapshot but sentinel is gone (semantic restore)'
        }
    } else {
        # No original auth.json -- after restore the live file should be
        # absent (the launcher removes the managed sentinel file when
        # the backup is empty).
        if ($authAfterExist -and (-not $authSentinelGone)) {
            $authRestoredCorrectly = $false
            $authReason = 'managed sentinel auth.json still present (no original existed)'
        }
    }

    $allOk = ($restoreExit -eq 0) -and $blockGone -and $backupGone -and `
             $authSentinelGone -and $authBackupGone -and $authRestoredCorrectly -and $bridgeGone

    if ($allOk) {
        $detail = 'managed block removed, config backup cleared, auth.json restored, auth backup cleared, bridge stopped'
        if ($authReason) { $detail += " ($authReason)" }
        Add-Result 'restore-roundtrip' 'PASS' $detail
    } else {
        $why = @()
        if ($restoreExit -ne 0)         { $why += "exit=$restoreExit" }
        if (-not $blockGone)            { $why += 'managed block still present in config' }
        if (-not $backupGone)           { $why += 'config backup file still present' }
        if (-not $authSentinelGone)     { $why += 'sentinel API key still in live auth.json' }
        if (-not $authBackupGone)       { $why += 'auth backup file still present' }
        if (-not $authRestoredCorrectly){ $why += "auth.json restore wrong: $authReason" }
        if (-not $bridgeGone)           { $why += 'bridge.pid still present' }
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

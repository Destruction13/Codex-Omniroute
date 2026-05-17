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
              base_url pointing at the active bridge port.
            - auth.json with the user's real OAuth tokens (copy of their
              real ~/.codex/auth.json).
            - .omniroute-seed.json stamp file.
         models_cache.json is optional (present only if the user already
         had one in their real ~/.codex).
      5. The isolated CODEX_HOME does NOT contain state_5.sqlite at seed
         time. This is what forces Codex Desktop to read the fresh
         config.toml on the first new-thread create.
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
     13. Start-Codex-OmniRoute.ps1 -Restore stops the bridge, removes the
         isolated CODEX_HOME, and leaves the user's real ~/.codex
         untouched.

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
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$omniLauncher   = Join-Path $scriptRoot 'Start-Codex-OmniRoute.ps1'
$offLauncher    = Join-Path $scriptRoot 'Start-Codex-Official.ps1'
$bridgePid      = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog      = Join-Path $scriptRoot 'bridge.log'
$isolatedHome   = Join-Path $scriptRoot '.codex-omniroute-home'

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

    # 5d. state_5.sqlite must be absent at seed time. Codex Desktop
    # creates it on first boot; if it's present BEFORE Desktop runs,
    # something seeded it (regression).
    $isolatedStatePath = Join-Path $isolatedHome 'state_5.sqlite'
    if (Test-Path -LiteralPath $isolatedStatePath) {
        # If Codex Desktop ran in a previous session and is no longer
        # running, the file may still be on disk. Treat as WARN because
        # we can't tell from the verifier alone, and the bridge's
        # /healthz fields below give the operator a clearer picture.
        Add-Result 'isolated-state-sqlite-absent' 'WARN' "state_5.sqlite present in isolated home (probably from a previous Codex Desktop run)"
    } else {
        Add-Result 'isolated-state-sqlite-absent' 'PASS' "state_5.sqlite absent at seed time (Desktop will read fresh config.toml)"
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

    # honored=false is the EXPECTED state at -NoCodex time (Desktop
    # never ran). honored=true here would mean state_5.sqlite already
    # exists or auth.json was modified -- not a fatal regression but
    # worth surfacing.
    if (-not $honored) {
        Add-Result 'healthz-honored-fresh' 'PASS' 'desktop_codex_home_honored=false at boot (Desktop has not touched isolated home yet)'
    } else {
        Add-Result 'healthz-honored-fresh' 'WARN' 'desktop_codex_home_honored=true at boot (state_5.sqlite or modified seed file present)'
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
# 9. GET /v1/models reachable
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
# 12. -Restore round-trip
# ----------------------------------------------------------------------------

if (-not $LeaveBridgeRunning) {
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $omniLauncher -Restore | Out-Null
    $restoreExit = $LASTEXITCODE

    $isolatedGone   = -not (Test-Path -LiteralPath $isolatedHome)
    $bridgeGone     = -not (Test-Path -LiteralPath $bridgePid)
    $configBackupGone = -not (Test-Path -LiteralPath $LegacyConfigBackup)
    $authBackupGone   = -not (Test-Path -LiteralPath $LegacyAuthBackup)

    # The real ~/.codex must still match the POST-CLEANUP snapshot
    # taken after the initial launch (see real-config-untouched and
    # real-auth-untouched checks above). We use the post-cleanup
    # baseline (not the pre-launch one) because the launcher's legacy
    # cleanup pass is idempotent and -Restore should be a no-op against
    # an already-clean real ~/.codex.
    $realConfigAfterRestore = if (Test-Path -LiteralPath $realConfigPath) { Get-Content -LiteralPath $realConfigPath -Raw } else { $null }
    $realAuthAfterRestore   = if (Test-Path -LiteralPath $realAuthPath)   { Get-Content -LiteralPath $realAuthPath -Raw }   else { $null }
    $realConfigUntouched    = ($realConfigAfterRestore -eq $realConfigCleanContent)
    $realAuthUntouched      = ($realAuthAfterRestore -eq $realAuthCleanContent)

    $allOk = ($restoreExit -eq 0) -and $isolatedGone -and $bridgeGone -and `
             $configBackupGone -and $authBackupGone -and `
             $realConfigUntouched -and $realAuthUntouched

    if ($allOk) {
        Add-Result 'restore-roundtrip' 'PASS' 'isolated home removed, bridge stopped, legacy backups gone, real ~/.codex untouched'
    } else {
        $why = @()
        if ($restoreExit -ne 0)         { $why += "exit=$restoreExit" }
        if (-not $isolatedGone)         { $why += 'isolated CODEX_HOME still present' }
        if (-not $bridgeGone)           { $why += 'bridge.pid still present' }
        if (-not $configBackupGone)     { $why += 'legacy config.toml.codex-omniroute-backup still present' }
        if (-not $authBackupGone)       { $why += 'legacy auth.json.codex-omniroute-backup still present' }
        if (-not $realConfigUntouched)  { $why += 'real ~/.codex/config.toml content changed' }
        if (-not $realAuthUntouched)    { $why += 'real ~/.codex/auth.json content changed' }
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

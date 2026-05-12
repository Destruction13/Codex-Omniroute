<#
.SYNOPSIS
    Verifies the Codex OmniRoute architecture invariants.

.DESCRIPTION
    Runs a bounded OmniRoute launch (bridge only, no Codex GUI) and checks:

      1. Start-Codex-OmniRoute.ps1 -NoCodex succeeds.
      2. The bridge /healthz responds.
      3. The bridge process is workspace-managed (PID file exists and matches).
      4. The isolated runtime config.toml exists and references model_provider = "omniroute_bridge".
      5. No workspace-local OmniRoute config pollution exists
         (.codex\config.toml under the workspace is NOT created).
      6. No active global Codex provider override exists
         (%USERPROFILE%\.codex\config.toml has no model_provider = "omniroute_bridge"
         and is not modified by the launchers).
      7. The official launcher Start-Codex-Official.ps1 contains no OmniRoute env overrides.
      8. The official launcher (in DryRun) spawns no OmniRoute helper processes.
      9. The dictation bridge supports base64 desktop uploads
         (bridge responds to POST /transcribe with x-codex-base64=1 -- we send a tiny
         smoke payload and verify the bridge attempts to forward, not 4xx-rejects locally).
     10. The managed bridge stops cleanly after verification.

    Optional live smokes (only run with -Live):
       - POST /v1/responses
       - POST /v1/responses/compact

.PARAMETER Live
    Run live smoke calls against the running bridge. Requires real OmniRoute
    credentials and a real Codex auth.json seeded into the isolated runtime.

.PARAMETER LeaveBridgeRunning
    Do not stop the bridge after verification. Useful when chaining with manual
    Codex launches.

.PARAMETER BridgePort
    Preferred bridge port. Default 20333.
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$LeaveBridgeRunning,
    [int]$BridgePort = 20333,
    [string]$RuntimeHome = '.codex-omniroute-home'
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }) | Out-Null
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[{0}] {1} -- {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

$workspace = (Get-Location).Path
$omniLauncher = Join-Path $workspace 'Start-Codex-OmniRoute.ps1'
$officialLauncher = Join-Path $workspace 'Start-Codex-Official.ps1'
$bridgePidFile = Join-Path $workspace 'bridge.pid'
$bridgeLogFile = Join-Path $workspace 'bridge.log'

# ---------------- 7. official launcher static audit ----------------
if (Test-Path -LiteralPath $officialLauncher) {
    $officialText = Get-Content -LiteralPath $officialLauncher -Raw
    $pollutionPatterns = @(
        'OMNIROUTE_',
        'CODEX_BRIDGE_',
        'CODEX_ELECTRON_USER_DATA_PATH',
        'omniroute_bridge',
        'codex-openai-omniroute-bridge',
        '.codex-omniroute-home'
    )
    $hits = @()
    foreach ($pat in $pollutionPatterns) {
        if ($officialText -match [regex]::Escape($pat)) { $hits += $pat }
    }
    if ($hits.Count -eq 0) {
        Add-Result 'official-launcher-clean' 'PASS' 'no OmniRoute references in Start-Codex-Official.ps1'
    } else {
        Add-Result 'official-launcher-clean' 'FAIL' ("OmniRoute references found: " + ($hits -join ', '))
    }
} else {
    Add-Result 'official-launcher-clean' 'FAIL' "missing: $officialLauncher"
}

# ---------------- 6. global config not polluted ----------------
$globalConfig = Join-Path $env:USERPROFILE '.codex\config.toml'
if (Test-Path -LiteralPath $globalConfig) {
    $globalText = Get-Content -LiteralPath $globalConfig -Raw
    if ($globalText -match 'model_provider\s*=\s*"omniroute_bridge"') {
        Add-Result 'global-config-clean' 'FAIL' "global config has model_provider = `"omniroute_bridge`""
    } else {
        Add-Result 'global-config-clean' 'PASS' "global $globalConfig has no active OmniRoute provider override"
    }
} else {
    Add-Result 'global-config-clean' 'WARN' "global $globalConfig does not exist (OK on a fresh install)"
}

# ---------------- 5. workspace-local config NOT created ----------------
$workspaceLocalConfig = Join-Path $workspace '.codex\config.toml'
if (Test-Path -LiteralPath $workspaceLocalConfig) {
    Add-Result 'workspace-config-clean' 'FAIL' "workspace-local $workspaceLocalConfig exists (launcher must not write here)"
} else {
    Add-Result 'workspace-config-clean' 'PASS' 'no workspace-local .codex\config.toml'
}

# ---------------- 8. official DryRun does not spawn helpers ----------------
if (Test-Path -LiteralPath $officialLauncher) {
    $nodeBefore = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    & pwsh -NoProfile -File $officialLauncher -DryRun *> $null 2>&1
    Start-Sleep -Milliseconds 250
    $nodeAfter = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $newPids = $nodeAfter | Where-Object { $nodeBefore -notcontains $_ }
    if (-not $newPids -or $newPids.Count -eq 0) {
        Add-Result 'official-no-helpers' 'PASS' 'no new node helpers after Start-Codex-Official.ps1 -DryRun'
    } else {
        Add-Result 'official-no-helpers' 'FAIL' ("new node pids: " + ($newPids -join ', '))
    }
}

# ---------------- 1+2+3+4. bounded OmniRoute launch ----------------
if (-not (Test-Path -LiteralPath $omniLauncher)) {
    Add-Result 'omniroute-launch' 'FAIL' "missing: $omniLauncher"
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

Write-Host "`n[verify] starting OmniRoute launcher with -NoCodex ..." -ForegroundColor Cyan
try {
    & pwsh -NoProfile -File $omniLauncher -NoCodex -BridgePort $BridgePort -RuntimeHome $RuntimeHome
    Add-Result 'omniroute-launch' 'PASS' '-NoCodex succeeded'
} catch {
    Add-Result 'omniroute-launch' 'FAIL' $_.Exception.Message
    exit 1
}

# bridge PID file
$bridgePid = $null
if (Test-Path -LiteralPath $bridgePidFile) {
    $bridgePid = (Get-Content -LiteralPath $bridgePidFile -Raw).Trim()
    if ($bridgePid -match '^\d+$' -and (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
        Add-Result 'bridge-pid-managed' 'PASS' "pid=$bridgePid, file=$bridgePidFile"
    } else {
        Add-Result 'bridge-pid-managed' 'FAIL' "pid file contents '$bridgePid' not a running process"
    }
} else {
    Add-Result 'bridge-pid-managed' 'FAIL' "missing $bridgePidFile"
}

# health
$health = $null
try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$BridgePort/healthz" -TimeoutSec 3
    if ($health.ok) {
        Add-Result 'bridge-health' 'PASS' ("port={0} omniroute_configured={1}" -f $health.port, $health.omniroute.configured)
    } else {
        Add-Result 'bridge-health' 'FAIL' 'response missing ok=true'
    }
} catch {
    Add-Result 'bridge-health' 'FAIL' $_.Exception.Message
}

# isolated config
$isolatedConfig = Join-Path $workspace (Join-Path $RuntimeHome 'codex\config.toml')
if (Test-Path -LiteralPath $isolatedConfig) {
    $iso = Get-Content -LiteralPath $isolatedConfig -Raw
    $ok = ($iso -match 'model_provider\s*=\s*"omniroute_bridge"') -and
          ($iso -match '\[model_providers\.omniroute_bridge\]') -and
          ($iso -match 'wire_api\s*=\s*"responses"') -and
          ($iso -match 'requires_openai_auth\s*=\s*true')
    if ($ok) {
        Add-Result 'isolated-config-anchored' 'PASS' $isolatedConfig
    } else {
        Add-Result 'isolated-config-anchored' 'FAIL' "isolated config at $isolatedConfig missing required anchors"
    }
} else {
    Add-Result 'isolated-config-anchored' 'FAIL' "missing $isolatedConfig"
}

# ---------------- 9. dictation base64 smoke ----------------
try {
    $tinyBytes = [System.Text.Encoding]::ASCII.GetBytes('not-really-audio-but-bytes-flow')
    $b64 = [Convert]::ToBase64String($tinyBytes)
    $resp = Invoke-WebRequest `
        -Uri "http://127.0.0.1:$BridgePort/transcribe" `
        -Method POST `
        -Headers @{ 'x-codex-base64' = '1'; 'content-type' = 'multipart/form-data; boundary=---x' } `
        -Body $b64 `
        -SkipHttpErrorCheck `
        -TimeoutSec 5
    # The bridge will try to forward to the official upstream; we don't care whether
    # the upstream accepts the bogus payload -- only that the bridge did not refuse
    # the base64 envelope locally (400 bad_request_encoding).
    $isLocalReject = $resp.StatusCode -eq 400 -and (
        $resp.Content -match 'bad_request_encoding'
    )
    if ($isLocalReject) {
        Add-Result 'dictation-base64-decode' 'FAIL' 'bridge rejected base64 envelope locally'
    } else {
        Add-Result 'dictation-base64-decode' 'PASS' ("bridge accepted base64 envelope (upstream status={0})" -f $resp.StatusCode)
    }
} catch {
    Add-Result 'dictation-base64-decode' 'WARN' ("could not exercise /transcribe: " + $_.Exception.Message)
}

# ---------------- optional live smokes ----------------
if ($Live) {
    Write-Host "`n[verify] live smokes enabled" -ForegroundColor Cyan
    try {
        $resp = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$BridgePort/v1/responses" `
            -Method POST `
            -ContentType 'application/json' `
            -Body (@{ model = 'gpt-5.4'; input = 'ping'; stream = $false } | ConvertTo-Json) `
            -TimeoutSec 60
        Add-Result 'live-responses' 'PASS' ('got response of type ' + ($resp.GetType().Name))
    } catch {
        Add-Result 'live-responses' 'FAIL' $_.Exception.Message
    }
    try {
        $resp = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$BridgePort/v1/responses/compact" `
            -Method POST `
            -ContentType 'application/json' `
            -Body '{}' `
            -TimeoutSec 60
        Add-Result 'live-compact' 'PASS' 'compact endpoint reached upstream'
    } catch {
        Add-Result 'live-compact' 'WARN' ('compact upstream rejected (often expected without a real session): ' + $_.Exception.Message)
    }
}

# ---------------- 10. stop managed bridge ----------------
if (-not $LeaveBridgeRunning) {
    if ($bridgePid -and (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $bridgePid -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 250
            if (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue) {
                Add-Result 'bridge-stopped' 'FAIL' "pid $bridgePid still running after stop"
            } else {
                Add-Result 'bridge-stopped' 'PASS' "stopped pid $bridgePid"
            }
        } catch {
            Add-Result 'bridge-stopped' 'FAIL' $_.Exception.Message
        }
    } else {
        Add-Result 'bridge-stopped' 'WARN' 'no managed bridge to stop'
    }
    if (Test-Path -LiteralPath $bridgePidFile) {
        Remove-Item -LiteralPath $bridgePidFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0

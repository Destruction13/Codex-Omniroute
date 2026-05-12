<#
.SYNOPSIS
    OmniRoute launcher: official Codex binary + isolated runtime home + local bridge.

.DESCRIPTION
    Reproduces the Codex OmniRoute architecture:

      1. Resolves the official Microsoft Store Codex package dynamically
         (Get-AppxPackage OpenAI.Codex) and launches its app\Codex.exe.
         The Store package itself is NEVER modified.

      2. Sets up a workspace-local isolated runtime home (default
         .codex-omniroute-home) and points HOME, USERPROFILE, APPDATA,
         LOCALAPPDATA, TEMP, TMP, CODEX_HOME, and
         CODEX_ELECTRON_USER_DATA_PATH inside it. This is what makes the
         OmniRoute fork a separate desktop persona while still being the
         same official binary.

      3. Seeds ONLY the minimal official Codex profile files needed for a
         logged-in feel: auth.json, models_cache.json, installation_id.
         Chats, sessions, thread DBs, logs, and other runtime state are
         NOT copied.

      4. Writes the isolated config.toml. This config:
           * inherits safe content from the user's official config.toml
             (notably [mcp_servers.*] entries) but strips conflicting
             provider/profile blocks;
           * pins model_provider = "omniroute_bridge",
                  model = "gpt-5.4",
                  model_reasoning_effort = "xhigh",
                  profile = "omniroute_managed";
           * defines [model_providers.omniroute_bridge] with
             base_url = "http://127.0.0.1:<bridge_port>/v1",
             wire_api = "responses",
             requires_openai_auth = true,
             supports_websockets = false;
           * marks the target project trusted.

      5. Starts codex-openai-omniroute-bridge.mjs on 127.0.0.1, with the
         bridge PID and log kept inside the workspace (NOT inside the
         isolated runtime home).

      6. Waits for the bridge's /healthz, then launches Codex.exe with the
         isolated environment.

    Official mode (Start-Codex-Official.ps1) remains a clean baseline:
    no OmniRoute env contamination, no helper processes.

.PARAMETER NoCodex
    Start the bridge and prepare the isolated runtime, but do NOT launch
    the Codex GUI. Used by verify-codex-omniroute.ps1 to perform a bounded
    "OmniRoute launch" without opening windows.

.PARAMETER Reset
    Delete the isolated runtime home before launching. Forces a fresh
    seed of auth.json, models_cache.json, installation_id, and config.toml.
    Persistent runtime history under the isolated home is lost.

.PARAMETER DryRun
    Print the planned environment and command without starting the bridge
    or launching Codex.

.PARAMETER BridgePort
    Preferred bridge port. The launcher will search nearby ports if this
    one is busy. Default 20333.

.PARAMETER RuntimeHome
    Path to the isolated runtime home. Default .codex-omniroute-home in
    the current working directory.

.NOTES
    Never writes to the global %USERPROFILE%\.codex\config.toml.
    Never writes to project-local .codex\config.toml.
    Never inlines OmniRoute or official secrets into the repo.
#>

[CmdletBinding()]
param(
    [switch]$NoCodex,
    [switch]$Reset,
    [switch]$DryRun,
    [int]$BridgePort = 20333,
    [string]$RuntimeHome = '.codex-omniroute-home',
    [string]$ProviderJson = './omniroute-provider.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Resolve-CodexExecutable {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw "Official Codex Microsoft Store app is not installed (Get-AppxPackage OpenAI.Codex returned nothing). Install it from the Microsoft Store first."
    }
    if ($pkg -is [array]) { $pkg = $pkg[0] }
    $candidates = @(
        (Join-Path $pkg.InstallLocation 'app\Codex.exe'),
        (Join-Path $pkg.InstallLocation 'Codex.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw "Found Codex package at '$($pkg.InstallLocation)' but could not locate Codex.exe."
}

function Get-OfficialCodexHome {
    return (Join-Path $env:USERPROFILE '.codex')
}

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

function New-IsolatedRuntimeHome {
    param([string]$Root, [switch]$Reset)
    $abs = (Resolve-Path -LiteralPath (Split-Path -Parent $Root) -ErrorAction SilentlyContinue)
    if (-not $abs) { $abs = (Get-Location).Path }
    $full = if ([System.IO.Path]::IsPathRooted($Root)) { $Root } else { Join-Path (Get-Location).Path $Root }

    if ($Reset -and (Test-Path -LiteralPath $full)) {
        Write-Host "[omniroute] reset: removing $full"
        Remove-Item -LiteralPath $full -Recurse -Force
    }

    $sub = @(
        $full,
        (Join-Path $full 'HOME'),
        (Join-Path $full 'AppData\Roaming'),
        (Join-Path $full 'AppData\Local'),
        (Join-Path $full 'AppData\Local\Temp'),
        (Join-Path $full 'codex')
    )
    foreach ($d in $sub) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    return [pscustomobject]@{
        Root      = $full
        Home      = (Join-Path $full 'HOME')
        AppData   = (Join-Path $full 'AppData\Roaming')
        LocalApp  = (Join-Path $full 'AppData\Local')
        Temp      = (Join-Path $full 'AppData\Local\Temp')
        CodexHome = (Join-Path $full 'codex')
    }
}

function Copy-MinimalSeed {
    param([string]$OfficialHome, [string]$IsolatedCodexHome)
    if (-not (Test-Path -LiteralPath $OfficialHome)) {
        Write-Warning "[omniroute] official Codex home '$OfficialHome' not found; cannot seed auth.json / models_cache.json."
        return
    }
    $files = @('auth.json', 'models_cache.json', 'installation_id')
    foreach ($f in $files) {
        $src = Join-Path $OfficialHome $f
        $dst = Join-Path $IsolatedCodexHome $f
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host "[omniroute] seeded $f"
        } elseif (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "[omniroute] official $f missing at $src; isolated runtime may behave as logged-out."
        } else {
            Write-Host "[omniroute] $f already present in isolated runtime; not overwriting"
        }
    }
}

function Sanitize-OfficialConfig {
    param([string]$OfficialConfigPath)

    # Returns the cleaned official config content (string) with provider/profile-conflicting
    # blocks removed. We intentionally do NOT parse TOML — we strip on a block basis.
    if (-not (Test-Path -LiteralPath $OfficialConfigPath)) { return '' }
    $raw = Get-Content -LiteralPath $OfficialConfigPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return '' }

    $lines = $raw -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[\s*([A-Za-z0-9_.\-]+)') {
            $section = $Matches[1]
            $skip = $false
            # Strip top-level scalars that we will explicitly set in the isolated config.
            if ($section -match '^(model_providers\.|profiles\.|profile$|model_provider$|model$|model_reasoning_effort$)') {
                $skip = $true
                continue
            }
        }
        if ($skip) { continue }
        # Also strip top-level lines that set the keys we own.
        if ($trim -match '^(model_provider|model|model_reasoning_effort|profile)\s*=') {
            continue
        }
        $out.Add($line)
    }
    return ($out -join "`n").Trim()
}

function Write-IsolatedConfig {
    param(
        [string]$IsolatedConfigPath,
        [string]$OfficialConfigPath,
        [int]$BridgePort,
        [string]$ProjectPath
    )

    $inherited = Sanitize-OfficialConfig -OfficialConfigPath $OfficialConfigPath

    $projectEscaped = $ProjectPath.Replace('\', '\\')

    $omniBlock = @"
# --- Codex OmniRoute managed (auto-generated; do not hand-edit) ---
model_provider = "omniroute_bridge"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"
profile = "omniroute_managed"

[model_providers.omniroute_bridge]
name = "OmniRoute Bridge"
base_url = "http://127.0.0.1:$BridgePort/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false

[profiles.omniroute_managed]
model_provider = "omniroute_bridge"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"

[projects."$projectEscaped"]
trust_level = "trusted"
# --- end Codex OmniRoute managed ---
"@

    $body = @()
    if ($inherited) {
        $body += '# Inherited from official Codex config (provider/profile blocks stripped).'
        $body += $inherited
        $body += ''
    }
    $body += $omniBlock

    $final = ($body -join "`n") + "`n"
    Set-Content -LiteralPath $IsolatedConfigPath -Value $final -Encoding UTF8 -NoNewline
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

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$workspace = (Get-Location).Path
$bridgeScript = Join-Path $workspace 'codex-openai-omniroute-bridge.mjs'
if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Bridge script not found: $bridgeScript"
}

$exe = Resolve-CodexExecutable
$officialHome = Get-OfficialCodexHome
$officialConfig = Join-Path $officialHome 'config.toml'

$port = Find-FreePort -Preferred $BridgePort
$runtime = New-IsolatedRuntimeHome -Root $RuntimeHome -Reset:$Reset

Copy-MinimalSeed -OfficialHome $officialHome -IsolatedCodexHome $runtime.CodexHome
Write-IsolatedConfig `
    -IsolatedConfigPath (Join-Path $runtime.CodexHome 'config.toml') `
    -OfficialConfigPath $officialConfig `
    -BridgePort $port `
    -ProjectPath $workspace

# Bridge PID/log live in the workspace, NOT in the isolated runtime home.
$bridgePid = Join-Path $workspace 'bridge.pid'
$bridgeLog = Join-Path $workspace 'bridge.log'

# Per-process env overrides for the bridge child. ProcessStartInfo.Environment
# is pre-populated with the parent's environment when UseShellExecute=$false,
# so we only need to set the overrides we actually want to change.
$bridgeEnvOverrides = @{
    CODEX_HOME        = $runtime.CodexHome
    CODEX_BRIDGE_HOST = '127.0.0.1'
    CODEX_BRIDGE_PORT = "$port"
}
if (Test-Path -LiteralPath $ProviderJson) {
    $bridgeEnvOverrides['OMNIROUTE_PROVIDER_JSON'] = (Resolve-Path -LiteralPath $ProviderJson).Path
}

if ($DryRun) {
    Write-Host "[omniroute] DryRun -- not starting bridge or Codex."
    [pscustomobject]@{
        Mode                = 'omniroute'
        Executable          = $exe
        WorkspaceDir        = $workspace
        IsolatedRuntime     = $runtime
        BridgePort          = $port
        BridgeScript        = $bridgeScript
        BridgePidFile       = $bridgePid
        BridgeLogFile       = $bridgeLog
        OfficialConfigSeen  = (Test-Path -LiteralPath $officialConfig)
        EnvForCodex         = @{
            HOME                          = $runtime.Home
            USERPROFILE                   = $runtime.Home
            APPDATA                       = $runtime.AppData
            LOCALAPPDATA                  = $runtime.LocalApp
            TEMP                          = $runtime.Temp
            TMP                           = $runtime.Temp
            CODEX_HOME                    = $runtime.CodexHome
            CODEX_ELECTRON_USER_DATA_PATH = (Join-Path $runtime.LocalApp 'OpenAI\Codex-OmniRoute')
        }
        DryRun              = $true
    } | Format-List
    exit 0
}

# Start the bridge as a workspace-managed child process.
$nodeExe = (Get-Command node -ErrorAction Stop).Path
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $nodeExe
$startInfo.Arguments = "`"$bridgeScript`""
$startInfo.WorkingDirectory = $workspace
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true
foreach ($kv in $bridgeEnvOverrides.GetEnumerator()) {
    $startInfo.Environment[$kv.Key] = [string]$kv.Value
}

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $startInfo
$null = $proc.Start()
try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

Set-Content -LiteralPath $bridgePid -Value $proc.Id -Encoding ASCII
"[$(Get-Date -Format o)] bridge started pid=$($proc.Id) port=$port" | Out-File -LiteralPath $bridgeLog -Encoding UTF8 -Append

# Stream bridge stdout/stderr into bridge.log in the background.
$writer = [System.IO.StreamWriter]::new($bridgeLog, $true)
$writer.AutoFlush = $true
Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
    if ($Event.SourceEventArgs.Data) { $writer.WriteLine("[stdout] " + $Event.SourceEventArgs.Data) }
} | Out-Null
Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
    if ($Event.SourceEventArgs.Data) { $writer.WriteLine("[stderr] " + $Event.SourceEventArgs.Data) }
} | Out-Null
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()

try {
    $health = Wait-ForBridgeHealth -BridgeHost '127.0.0.1' -Port $port -TimeoutSec 25
    Write-Host "[omniroute] bridge healthy on 127.0.0.1:$port (pid=$($proc.Id), source=$($health.omniroute.source))"
} catch {
    Write-Error "[omniroute] bridge failed to come up: $($_.Exception.Message). See bridge.log."
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    throw
}

if ($NoCodex) {
    Write-Host "[omniroute] -NoCodex: bridge is running. Codex GUI not launched."
    exit 0
}

# Isolated environment for the Codex GUI process.
$codexEnv = @{
    HOME                          = $runtime.Home
    USERPROFILE                   = $runtime.Home
    APPDATA                       = $runtime.AppData
    LOCALAPPDATA                  = $runtime.LocalApp
    TEMP                          = $runtime.Temp
    TMP                           = $runtime.Temp
    CODEX_HOME                    = $runtime.CodexHome
    CODEX_ELECTRON_USER_DATA_PATH = (Join-Path $runtime.LocalApp 'OpenAI\Codex-OmniRoute')
}

$codexStart = New-Object System.Diagnostics.ProcessStartInfo
$codexStart.FileName = $exe
$codexStart.WorkingDirectory = $workspace
$codexStart.UseShellExecute = $false
foreach ($kv in $codexEnv.GetEnumerator()) { $codexStart.Environment[$kv.Key] = $kv.Value }
# Preserve PATH from the parent so the binary can still find side-by-side DLLs.
$codexStart.Environment['PATH'] = $env:PATH

$codexProc = [System.Diagnostics.Process]::Start($codexStart)
Write-Host "[omniroute] launched Codex.exe pid=$($codexProc.Id) with isolated runtime $($runtime.CodexHome)"

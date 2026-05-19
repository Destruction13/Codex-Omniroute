<#
.SYNOPSIS
    Verifies the Codex OmniRoute shared-home gateway.

.DESCRIPTION
    This verifier checks the architecture that replaced the old Variant-3
    isolated profile:

      - OmniRoute uses the shared official Codex home.
      - The launcher does not seed or select .codex-omniroute-home.
      - The shared config.toml does not receive a global OmniRoute provider.
      - Runtime model/provider overrides are process arguments.
      - The bridge exposes main reasoning, tool adapters, image lane, compact,
        dictation, and shared-home diagnostics.
      - Configured MCP servers are discovered from the real shared config.

    The verifier starts the real local bridge through Start-Codex-OmniRoute.ps1
    -NoCodex. Optional live checks can call the bridge and/or the real Codex CLI
    with the same runtime overrides. It does not create fake MCP servers or fake
    Codex windows.

.PARAMETER Live
    Send a live HTTP /v1/responses request through the bridge.

.PARAMETER LiveCodexExec
    Run a non-interactive real codex exec request with the same shared-home
    runtime overrides. This is not a GUI proof, but it verifies the real Codex
    agent path and bridge route.

.PARAMETER LeaveBridgeRunning
    Keep the bridge running after verification.

.PARAMETER ProbeAllMcp
    Probe every configured MCP server from the shared official config instead
    of the bounded fast probe set.

.PARAMETER BridgePort
    Preferred bridge port. Default: 20333.
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$LiveCodexExec,
    [switch]$LeaveBridgeRunning,
    [switch]$ProbeAllMcp,
    [int]$BridgePort = 20333,
    [int]$LiveCodexExecTimeoutSec = 120
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
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

function Test-WindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    $winVar = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($winVar) { return [bool]$winVar.Value }
    if ($env:OS -eq 'Windows_NT') { return $true }
    return $false
}

function Test-SamePath {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        $l = [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
        $r = [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
        return [string]::Equals($l, $r, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Get-PSHost {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-WindowsPowerShellHost {
    if (-not (Test-WindowsHost)) { return $null }
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-OfficialCodexHome {
    $root = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return [System.IO.Path]::GetFullPath((Join-Path $root '.codex'))
}

function Get-LocalCodexCli {
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
        if (Test-Path -LiteralPath $candidate) { return [System.IO.Path]::GetFullPath($candidate) }
    }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and $cmd.Source -notmatch '\\WindowsApps\\') { return $cmd.Source }
    return $null
}

function Read-TextShared {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return ''
    }
}

function Test-RootOmniRouteProvider {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $inRoot = $true
    foreach ($line in [System.IO.File]::ReadLines($ConfigPath)) {
        if ($line -match '^\s*\[') { $inRoot = $false }
        if ($inRoot -and $line -match '^\s*model_provider\s*=\s*"(omniroute|omniroute_bridge)"') { return $true }
    }
    return $false
}

function Get-McpServerNames {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $names = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return @() }
    foreach ($line in [System.IO.File]::ReadLines($ConfigPath)) {
        $match = [regex]::Match($line, '^\s*\[(.+?)\]\s*(?:#.*)?$')
        if (-not $match.Success) { continue }
        $section = $match.Groups[1].Value.Trim()
        if (-not $section.StartsWith('mcp_servers.', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($section.EndsWith('.env', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($section.EndsWith('.http_headers', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $name = $section.Substring('mcp_servers.'.Length).Trim()
        if ($name.StartsWith('"') -and $name.EndsWith('"') -and $name.Length -ge 2) {
            try { $name = ($name | ConvertFrom-Json -ErrorAction Stop) } catch { $name = $name.Substring(1, $name.Length - 2) }
        }
        if ($name.StartsWith("'") -and $name.EndsWith("'") -and $name.Length -ge 2) {
            $name = $name.Substring(1, $name.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) { $names.Add($name) }
    }
    return @($names.ToArray() | Sort-Object -Unique)
}

function Get-BridgeHealth {
    param([int]$PreferredPort)
    for ($i = 0; $i -lt 40; $i++) {
        $port = $PreferredPort + $i
        try {
            $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/healthz" -f $port) -TimeoutSec 2
            if ($health -and $health.ok) {
                return [pscustomobject]@{ Port = $port; Health = $health }
            }
        } catch {}
    }
    return $null
}

function Get-RuntimeOverrideArgs {
    param([int]$Port)
    $baseUrl = "http://127.0.0.1:$Port/v1"
    return @(
        '-c', 'model_provider="omniroute"',
        '-c', 'model="gpt-5.5"',
        '-c', 'model_reasoning_effort="xhigh"',
        '-c', 'features.tool_search=true',
        '-c', 'features.apply_patch_freeform=true',
        '-c', ('model_providers.omniroute.base_url="{0}"' -f $baseUrl),
        '-c', 'model_providers.omniroute.wire_api="responses"',
        '-c', 'model_providers.omniroute.env_key="OMNIROUTE_API_KEY"',
        '-c', 'model_providers.omniroute.requires_openai_auth=true',
        '-c', 'model_providers.omniroute.supports_websockets=false'
    )
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    $quote = [char]34
    $backslash = [char]92
    $specialChars = [char[]]@([char]32, [char]9, [char]10, [char]13, $quote)
    if (($Argument.Length -gt 0) -and ($Argument.IndexOfAny($specialChars) -lt 0)) {
        return $Argument
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append($quote)
    $backslashCount = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq $backslash) {
            $backslashCount++
            continue
        }
        if ($ch -eq $quote) {
            if ($backslashCount -gt 0) {
                [void]$builder.Append($backslash, $backslashCount * 2)
                $backslashCount = 0
            }
            [void]$builder.Append($backslash)
            [void]$builder.Append($quote)
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append($backslash, $backslashCount)
            $backslashCount = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append($backslash, $backslashCount * 2)
    }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

function Invoke-CodexExecLiveSmoke {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCli,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string[]]$OverrideArgs,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSec = 120
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $CodexCli
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['CODEX_HOME'] = $CodexHome
    $psi.Arguments = ((@('exec') + $OverrideArgs + @('--skip-git-repo-check', 'Reply with exactly: omniroute-live-ok')) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    $proc = [System.Diagnostics.Process]::Start($psi)
    $completed = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
        try { $proc.Kill($true) } catch {}
        return [pscustomobject]@{ Ok = $false; Detail = "codex exec timed out after $TimeoutSec seconds" }
    }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $text = (($stdout + "`n" + $stderr).Trim())
    if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + '...' }
    return [pscustomobject]@{ Ok = ($proc.ExitCode -eq 0); Detail = "exit=$($proc.ExitCode) $text" }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 30
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    foreach ($key in $Environment.Keys) {
        $psi.Environment[$key] = [string]$Environment[$key]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $completed = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
    }
    try { $proc.WaitForExit(5000) | Out-Null } catch {}
    $stdout = try { $stdoutTask.Result } catch { '' }
    $stderr = try { $stderrTask.Result } catch { '' }
    $text = (($stdout + "`n" + $stderr).Trim())
    return [pscustomobject]@{
        Completed = $completed
        ExitCode = if ($completed) { $proc.ExitCode } else { $null }
        Output = $text
    }
}

$psHost = Get-PSHost
if (-not $psHost) {
    Add-Result 'powershell-host' 'FAIL' 'Neither pwsh nor powershell.exe is on PATH.'
    exit 1
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
$scriptRoot = [System.IO.Path]::GetFullPath($scriptRoot)

$omniLauncher = Join-Path $scriptRoot 'Start-Codex-OmniRoute.ps1'
$officialLauncher = Join-Path $scriptRoot 'Start-Codex-Official.ps1'
$dependencySetup = Join-Path $scriptRoot 'tools\Install-CodexOmniRouteDependencies.ps1'
$bridgePid = Join-Path $scriptRoot 'bridge.pid'
$mcpProbe = Join-Path $scriptRoot 'tools\mcp_probe.mjs'
$applyPatchFallback = Join-Path $scriptRoot 'tools\Invoke-CodexApplyPatch.ps1'
$legacyIsolatedHome = Join-Path $scriptRoot '.codex-omniroute-home'
$officialHome = Get-OfficialCodexHome
$officialConfig = if ($officialHome) { Join-Path $officialHome 'config.toml' } else { '' }
$localCodexCli = Get-LocalCodexCli

if ($officialHome) {
    Add-Result 'shared-home-resolved' 'PASS' "shared Codex home: $officialHome"
} else {
    Add-Result 'shared-home-resolved' 'FAIL' 'USERPROFILE/HOME did not resolve'
}

if (Test-Path -LiteralPath $dependencySetup) {
    try {
        $depsRaw = & $psHost -NoProfile -ExecutionPolicy Bypass -File $dependencySetup -CheckOnly -Quiet -AsJson 2>&1
        $deps = ($depsRaw | Out-String | ConvertFrom-Json -ErrorAction Stop)
        if ($deps.dotnet_sdk_available -and $deps.node_available) {
            Add-Result 'dependency-setup' 'PASS' "Node and .NET SDK available; node source=$($deps.node_source), dotnet source=$($deps.dotnet_source)"
        } else {
            Add-Result 'dependency-setup' 'FAIL' 'dependency setup did not report Node and .NET SDK availability'
        }
    } catch {
        Add-Result 'dependency-setup' 'FAIL' "dependency setup check failed: $($_.Exception.Message)"
    }
} else {
    Add-Result 'dependency-setup' 'FAIL' "missing dependency setup script: $dependencySetup"
}

$launcherOutput = @()
$launcherExit = $null
try {
    & $psHost -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $omniLauncher -NoCodex -BridgePort $BridgePort
    $launcherExit = $LASTEXITCODE
} catch {
    $launcherOutput = @($_.Exception.Message)
    $launcherExit = -1
}

if ($launcherExit -eq 0) {
    Add-Result 'omniroute-launcher-nocodex' 'PASS' 'launcher started bridge without GUI'
} else {
    $detail = (($launcherOutput | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "launcher exited with code $launcherExit" }
    Add-Result 'omniroute-launcher-nocodex' 'FAIL' $detail
}

$active = Get-BridgeHealth -PreferredPort $BridgePort
if ($active) {
    Add-Result 'bridge-healthz' 'PASS' "bridge healthy on port $($active.Port)"
} else {
    Add-Result 'bridge-healthz' 'FAIL' 'no healthy bridge found near preferred port'
}

if ($active -and $officialHome) {
    if (Test-SamePath ([string]$active.Health.codex_home) $officialHome) {
        Add-Result 'bridge-shared-codex-home' 'PASS' "bridge CODEX_HOME is shared official home"
    } else {
        Add-Result 'bridge-shared-codex-home' 'FAIL' "bridge codex_home=$($active.Health.codex_home), expected $officialHome"
    }

    $shared = $active.Health.shared_home
    if ($shared -and [bool]$shared.active_runtime_home) {
        Add-Result 'healthz-shared-home-diagnostic' 'PASS' 'healthz reports shared_home.active_runtime_home=true'
    } else {
        Add-Result 'healthz-shared-home-diagnostic' 'FAIL' 'healthz did not expose shared-home diagnostics'
    }

    if ($active.Health.tool_adapters.tool_search_function_shim -and $active.Health.tool_adapters.tool_search_alias_rerank) {
        Add-Result 'bridge-tool-search-adapter' 'PASS' "tool_search shim is enabled as $($active.Health.tool_adapters.tool_search_shim_function_name)"
    } else {
        Add-Result 'bridge-tool-search-adapter' 'FAIL' 'tool_search shim/rerank is disabled'
    }

    if ($active.Health.image_lane.route -eq 'omniroute') {
        Add-Result 'bridge-image-lane' 'PASS' "image lane routes to OmniRoute model $($active.Health.image_lane.default_model)"
    } else {
        Add-Result 'bridge-image-lane' 'FAIL' 'image lane is not reported as OmniRoute'
    }

    if ([int64]$active.Health.body_budget.omniroute_max_body_bytes -eq 10485760) {
        Add-Result 'bridge-body-budget' 'PASS' '10MB OmniRoute body budget is active with inline-image compaction'
    } else {
        Add-Result 'bridge-body-budget' 'WARN' "body budget is $($active.Health.body_budget.omniroute_max_body_bytes) bytes"
    }
}

if (Test-Path -LiteralPath $legacyIsolatedHome) {
    Add-Result 'legacy-isolated-home-not-active' 'WARN' "legacy directory still exists but is not active: $legacyIsolatedHome"
} else {
    Add-Result 'legacy-isolated-home-not-active' 'PASS' 'legacy isolated directory is absent'
}

if (Test-WindowsHost) {
    $userCodexHome = [System.Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
    if (Test-SamePath $userCodexHome $legacyIsolatedHome) {
        Add-Result 'user-scope-codex-home' 'FAIL' 'user-scope CODEX_HOME still points at legacy isolated home'
    } else {
        Add-Result 'user-scope-codex-home' 'PASS' 'user-scope CODEX_HOME is not the OmniRoute mechanism'
    }
}

if ($officialConfig -and (Test-RootOmniRouteProvider -ConfigPath $officialConfig)) {
    Add-Result 'shared-config-no-global-provider' 'FAIL' 'shared config.toml has top-level model_provider="omniroute" or "omniroute_bridge"'
} else {
    Add-Result 'shared-config-no-global-provider' 'PASS' 'shared config.toml has no global OmniRoute model_provider'
}

$mcpNames = if ($officialConfig) { @(Get-McpServerNames -ConfigPath $officialConfig) } else { @() }
if ($mcpNames.Count -gt 0) {
    Add-Result 'shared-mcp-config-visible' 'PASS' ("shared config has {0} MCP server(s): {1}" -f $mcpNames.Count, (($mcpNames | Select-Object -First 8) -join ', '))
} else {
    Add-Result 'shared-mcp-config-visible' 'WARN' 'shared config has no [mcp_servers.*] sections'
}

if ((Test-Path -LiteralPath $mcpProbe) -and $officialConfig -and $mcpNames.Count -gt 0) {
    try {
        $preferredProbeNames = @('shadcn', 'openspec', 'sequential-thinking', 'openaiDeveloperDocs', 'prisma-mcp-server')
        $probeTargets = if ($ProbeAllMcp) {
            @($mcpNames)
        } else {
            @($preferredProbeNames | Where-Object { $mcpNames -contains $_ } | Select-Object -First 3)
        }
        if ($probeTargets.Count -eq 0) { $probeTargets = @($mcpNames | Select-Object -First 2) }

        $probeResults = @()
        foreach ($target in $probeTargets) {
            $probeRaw = & node $mcpProbe --config $officialConfig --timeout-ms 15000 --server $target --json 2>&1
            $probeExit = $LASTEXITCODE
            if ($probeExit -ne 0) {
                $probeResults += [pscustomobject]@{ name = $target; status = 'probe_failed'; detail = "mcp_probe exit=$probeExit" }
                continue
            }
            $probe = ($probeRaw | Out-String | ConvertFrom-Json -ErrorAction Stop)
            $probeResults += @($probe.results)
        }

        $listed = @($probeResults | Where-Object { $_.status -in @('tools_listed', 'callable') })
        $authRequired = @($probeResults | Where-Object { $_.status -eq 'auth_required' })
        $probeFailures = @($probeResults | Where-Object { $_.status -notin @('tools_listed', 'callable', 'auth_required', 'skipped_disabled', 'no_tools') })
        if ($ProbeAllMcp -and $probeFailures.Count -gt 0) {
            $sample = @($probeFailures | Select-Object -First 6 | ForEach-Object { "$($_.name):$($_.status)" }) -join ', '
            Add-Result 'mcp-probe-shared-config' 'FAIL' "some configured MCP servers failed real tools/list probing: $sample"
        } elseif ($listed.Count -gt 0) {
            $mode = if ($ProbeAllMcp) { 'all configured' } else { 'selected configured' }
            $authSuffix = if ($authRequired.Count -gt 0) {
                "; auth required for $($authRequired.Count): $(($authRequired | ForEach-Object { $_.name }) -join ', ')"
            } else {
                ''
            }
            Add-Result 'mcp-probe-shared-config' 'PASS' "MCP tools/list succeeded for $($listed.Count)/$($probeTargets.Count) $mode server(s)$authSuffix"
        } elseif ($authRequired.Count -gt 0) {
            Add-Result 'mcp-probe-shared-config' 'WARN' "only auth-required MCP servers responded while probing: $($probeTargets -join ', ')"
        } else {
            $sample = @($probeResults | Select-Object -First 4 | ForEach-Object { "$($_.name):$($_.status)" }) -join ', '
            Add-Result 'mcp-probe-shared-config' 'FAIL' "no configured MCP server listed tools; $sample"
        }
    } catch {
        Add-Result 'mcp-probe-shared-config' 'FAIL' "mcp_probe threw: $($_.Exception.Message)"
    }
} elseif ($mcpNames.Count -eq 0) {
    Add-Result 'mcp-probe-shared-config' 'INFO' 'skipped; no MCP servers configured'
} else {
    Add-Result 'mcp-probe-shared-config' 'FAIL' "mcp_probe missing at $mcpProbe"
}

if ($mcpNames -contains 'shadcn') {
    try {
        $sampleRaw = & node $mcpProbe --config $officialConfig --timeout-ms 30000 --server shadcn --allow-sample-call --call-server shadcn --call-tool get_project_registries --call-args-json '{}' --json 2>&1
        $sample = ($sampleRaw | Out-String | ConvertFrom-Json -ErrorAction Stop)
        $row = @($sample.results | Select-Object -First 1)[0]
        if ($row.status -eq 'callable') {
            Add-Result 'mcp-shadcn-readonly-call' 'PASS' 'shadcn.get_project_registries succeeded through shared config'
        } else {
            Add-Result 'mcp-shadcn-readonly-call' 'WARN' "shadcn sample status=$($row.status): $($row.detail)"
        }
    } catch {
        Add-Result 'mcp-shadcn-readonly-call' 'WARN' "shadcn sample threw: $($_.Exception.Message)"
    }
}

if ($active) {
    $modelsStatus = $null
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/models" -f $active.Port) -TimeoutSec 5 -UseBasicParsing
        $modelsStatus = $resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $modelsStatus = [int]$_.Exception.Response.StatusCode }
    }
    if ($modelsStatus -eq 200) {
        Add-Result 'bridge-models' 'PASS' '/v1/models served from shared models cache'
    } elseif ($modelsStatus -in @(404, 502, 503)) {
        Add-Result 'bridge-models' 'WARN' "/v1/models returned $modelsStatus; shared models cache may be absent"
    } else {
        Add-Result 'bridge-models' 'FAIL' "/v1/models returned unexpected status: $modelsStatus"
    }

    $transcribeStatus = $null
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/transcribe" -f $active.Port) -Method POST -Body 'health-probe' -ContentType 'application/octet-stream' -TimeoutSec 5 -UseBasicParsing
        $transcribeStatus = $resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $transcribeStatus = [int]$_.Exception.Response.StatusCode }
    }
    if ($transcribeStatus -and $transcribeStatus -ne 404) {
        Add-Result 'bridge-dictation-official-route' 'PASS' "/transcribe route exists (status=$transcribeStatus)"
    } else {
        Add-Result 'bridge-dictation-official-route' 'FAIL' '/transcribe returned 404'
    }
}

if ($applyPatchFallback -and (Test-Path -LiteralPath $applyPatchFallback)) {
    $tmpRoot = Join-Path $scriptRoot (".codex-omniroute-apply-verify-{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $sample = Join-Path $tmpRoot 'sample.txt'
        [System.IO.File]::WriteAllText($sample, "original`n", [System.Text.UTF8Encoding]::new($false))
        $patchPath = $sample.Replace('\', '/')
        $patch = "*** Begin Patch`n*** Update File: $patchPath`n@@`n-original`n+changed-by-verifier`n*** End Patch`n"
        $patchFile = Join-Path $tmpRoot 'patch.apply'
        [System.IO.File]::WriteAllText($patchFile, $patch, [System.Text.UTF8Encoding]::new($false))
        $applyPatchHost = Get-WindowsPowerShellHost
        if (-not $applyPatchHost) { $applyPatchHost = $psHost }
        $applyResult = Invoke-ProcessWithTimeout `
            -FileName $applyPatchHost `
            -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $applyPatchFallback, '-PatchFile', $patchFile) `
            -WorkingDirectory $scriptRoot `
            -Environment @{ CODEX_OMNI_FORCE_DIRECT_APPLY_PATCH = '1' } `
            -TimeoutSec 20
        $applied = (([System.IO.File]::ReadAllText($sample)).Trim() -eq 'changed-by-verifier')
        if ($applyResult.Completed -and ($applyResult.ExitCode -eq 0) -and $applied) {
            Add-Result 'apply-patch-local-fallback' 'PASS' 'local apply_patch fallback applied a safe temp-file patch'
        } elseif ((-not $applyResult.Completed) -and $applied) {
            Add-Result 'apply-patch-local-fallback' 'WARN' 'fallback applied the temp-file patch but did not exit within 20 seconds; verifier killed the helper'
        } else {
            $detail = $applyResult.Output
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '...' }
            Add-Result 'apply-patch-local-fallback' 'FAIL' "fallback failed: exit=$($applyResult.ExitCode) completed=$($applyResult.Completed) $detail"
        }
    } catch {
        Add-Result 'apply-patch-local-fallback' 'FAIL' "fallback threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result 'apply-patch-local-fallback' 'WARN' 'fallback helper missing; relying on native apply_patch_freeform'
}

$officialOutput = @()
$officialExit = $null
try {
    $officialOutput = & $psHost -NoProfile -ExecutionPolicy Bypass -File $officialLauncher -DryRun -NoAutoRestore 2>&1
    $officialExit = $LASTEXITCODE
} catch {
    $officialOutput = @($_.Exception.Message)
    $officialExit = -1
}
$officialJoined = ($officialOutput | Out-String)
if ($officialExit -eq 0 -and $officialJoined -notmatch 'model_provider="omniroute"|CODEX_BRIDGE_PORT|OMNIROUTE_PROVIDER_JSON') {
    Add-Result 'official-launcher-clean' 'PASS' 'official launcher dry-run has no OmniRoute runtime overrides'
} else {
    Add-Result 'official-launcher-clean' 'FAIL' "official dry-run exit=$officialExit"
}

if ($Live -and $active) {
    $beforeHits = [int64]$active.Health.main_reasoning_hits
    $body = @{ model = 'gpt-5.5'; input = 'Reply with just the digit 2.'; stream = $false } | ConvertTo-Json -Depth 5
    $liveOk = $false
    try {
        $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/responses" -f $active.Port) -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 90
        if ($resp) { $liveOk = $true }
    } catch {}
    $after = Get-BridgeHealth -PreferredPort $active.Port
    $afterHits = if ($after) { [int64]$after.Health.main_reasoning_hits } else { $beforeHits }
    if ($liveOk -and $afterHits -gt $beforeHits) {
        Add-Result 'live-bridge-responses' 'PASS' "live /v1/responses returned and main_reasoning_hits advanced $beforeHits->$afterHits"
    } else {
        Add-Result 'live-bridge-responses' 'FAIL' "live bridge request failed or hit counter did not advance ($beforeHits->$afterHits)"
    }
}

if ($LiveCodexExec -and $active -and $localCodexCli -and $officialHome) {
    $before = Get-BridgeHealth -PreferredPort $active.Port
    $beforeHits = if ($before) { [int64]$before.Health.main_reasoning_hits } else { 0 }
    $smoke = Invoke-CodexExecLiveSmoke `
        -CodexCli $localCodexCli `
        -CodexHome $officialHome `
        -OverrideArgs (Get-RuntimeOverrideArgs -Port $active.Port) `
        -WorkingDirectory $scriptRoot `
        -TimeoutSec $LiveCodexExecTimeoutSec
    $after = Get-BridgeHealth -PreferredPort $active.Port
    $afterHits = if ($after) { [int64]$after.Health.main_reasoning_hits } else { $beforeHits }
    if ($smoke.Ok -and $afterHits -gt $beforeHits) {
        Add-Result 'live-codex-exec-shared-home' 'PASS' "codex exec used bridge; hits $beforeHits->$afterHits"
    } else {
        Add-Result 'live-codex-exec-shared-home' 'FAIL' "$($smoke.Detail); hits $beforeHits->$afterHits"
    }
} elseif ($LiveCodexExec) {
    Add-Result 'live-codex-exec-shared-home' 'FAIL' 'local codex.exe, bridge, or shared home was unavailable'
}

if (-not $LeaveBridgeRunning) {
    try {
        & $psHost -NoProfile -ExecutionPolicy Bypass -File $omniLauncher -Restore 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $bridgePid)) {
            Add-Result 'restore-stops-bridge' 'PASS' 'launcher -Restore stopped managed bridge'
        } else {
            Add-Result 'restore-stops-bridge' 'WARN' 'bridge.pid still exists after restore'
        }
    } catch {
        Add-Result 'restore-stops-bridge' 'FAIL' "restore threw: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '=== Verification Summary ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed) {
    Write-Host ("FAILED: {0} checks" -f $failed.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'All required checks passed; review WARN/INFO rows for optional live gaps.' -ForegroundColor Green
exit 0

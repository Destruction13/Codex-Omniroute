<#
.SYNOPSIS
    Verifies the Codex OmniRoute architecture invariants.

.DESCRIPTION
    Runs a bounded OmniRoute launch (bridge only, no Codex GUI) and checks:

      Bridge / config invariants:
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

      Native-feature parity invariants (added to catch tool/MCP/runtime regressions):
       11. The isolated config does NOT inherit forbidden sections
           ([marketplaces.*], [plugins.*], [projects.*] other than the workspace,
           [windows], [model_providers.*] other than omniroute_bridge,
           [profiles.*] other than omniroute_managed). These tables historically
           leaked machine-specific paths from the user's global Codex home into
           the isolated profile and broke runtime/plugin discovery.
       12. The launcher does NOT install a git shim or override PATH. tools/git-shim/
           must not contain a built shim binary, and the launcher source must not
           reference a shim. Codex sees the user's real git unchanged.
       13. The isolated runtime's skills directory lives under .codex-omniroute-home
           (not under the user's global %USERPROFILE%\.codex\skills).
       14. bridge.log does NOT contain Windows process-management noise that would
           indicate the JSON-RPC MCP transport got polluted (e.g. taskkill SUCCESS
           lines). This is best-effort; absence of the pattern is necessary but
           not sufficient.
       15. The MCP smoke test (tools/mcp_smoke_test.py) runs cleanly against the
           isolated config when Python is available.
       16. Freeform apply_patch invariants:
           - The bundled Codex agent CLI contains the string
             `experimental_use_freeform_apply_patch` (so the in-process patch
             path is actually plumbed through in the installed Codex version).
           - The isolated config.toml has the flag set to true inside the
             [profiles.omniroute_managed] block specifically (Codex empirically
             honors the per-profile placement, not just the top-level one).
           - The active managed `model =` looks like a GPT-5 family model
             (freeform tools require grammar-supporting models; non-GPT-5
             silently falls back to the broken shell-path).
       17. User-local Codex bin fallback:
           - `<isolated>\profile\AppData\Local\OpenAI\Codex\bin\codex.exe`
             exists (Codex Desktop materializes its CLI toolkit there on
             first GUI launch).
           - The launcher source contains the PATH-prepend logic and the
             `-NoLocalCodexBinPath` opt-out.
       18. The MCP per-server JSON-RPC probe (tools/mcp_probe.mjs) reports
           ok=N fail=0 for every stdio MCP entry.

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

.PARAMETER FreshRuntime
    Pass -Reset to the OmniRoute launcher so the isolated runtime is rebuilt
    from scratch. Recommended for CI / regression runs.
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$LeaveBridgeRunning,
    [switch]$FreshRuntime,
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

function Read-Utf8Text {
    # Like Get-Content -Raw, but always UTF-8. Windows PowerShell 5.1's
    # default Get-Content encoding follows the active code page, which
    # mojibakes any non-ASCII byte in the user's TOML config or in a
    # profile path containing Cyrillic / CJK / etc. characters.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($true)
        return [System.IO.File]::ReadAllText($Path, $utf8)
    } catch {
        return $null
    }
}

$workspace = (Get-Location).Path
$omniLauncher = Join-Path $workspace 'Start-Codex-OmniRoute.ps1'
$officialLauncher = Join-Path $workspace 'Start-Codex-Official.ps1'
$bridgePidFile = Join-Path $workspace 'bridge.pid'
$bridgeLogFile = Join-Path $workspace 'bridge.log'

# Auto-detect available PowerShell host so we work on systems that only have
# Windows PowerShell 5.1 (powershell.exe) installed, not pwsh. Avoid the `?.`
# null-conditional operator here -- it is PS7+ only, and we want this file to
# parse cleanly under Windows PowerShell 5.1 as well.
$psHost = $null
$cmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($cmd) { $psHost = $cmd.Source }
if (-not $psHost) {
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { $psHost = $cmd.Source }
}
if (-not $psHost) {
    throw "Neither pwsh nor powershell was found on PATH. Install PowerShell 7+ (recommended) or run from a Windows PowerShell session."
}
Write-Host "[verify] using PowerShell host: $psHost" -ForegroundColor Gray

function Strip-PSComments {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # Drop block comments <# ... #> first (non-greedy, multiline).
    $noBlock = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    # Then drop single-line # comments. We deliberately keep lines that contain
    # a # *inside a string* (e.g. "http://...#foo") -- a strict tokenizer is
    # overkill here, so we only strip lines whose trimmed text starts with '#'.
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($noBlock -split "`r?`n")) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        $kept.Add($line)
    }
    return ($kept -join "`n")
}

# ---------------- 7. official launcher static audit ----------------
# We only flag OmniRoute references that appear in *executable* PowerShell,
# not in comments / docstrings. The official launcher's docstring legitimately
# describes what it does NOT do, which would otherwise trip this check.
if (Test-Path -LiteralPath $officialLauncher) {
    $officialRaw = Read-Utf8Text -Path $officialLauncher
    $officialCode = Strip-PSComments -Text $officialRaw
    $pollutionPatterns = @(
        'OMNIROUTE_',
        'CODEX_BRIDGE_',
        'CODEX_ELECTRON_USER_DATA_PATH',
        'ELECTRON_USER_DATA_DIR',
        'omniroute_bridge',
        'codex-openai-omniroute-bridge',
        '.codex-omniroute-home'
    )
    $hits = @()
    foreach ($pat in $pollutionPatterns) {
        if ($officialCode -match [regex]::Escape($pat)) { $hits += $pat }
    }
    if ($hits.Count -eq 0) {
        Add-Result 'official-launcher-clean' 'PASS' 'no OmniRoute references in executable code of Start-Codex-Official.ps1'
    } else {
        Add-Result 'official-launcher-clean' 'FAIL' ("OmniRoute references found in executable code: " + ($hits -join ', '))
    }
} else {
    Add-Result 'official-launcher-clean' 'FAIL' "missing: $officialLauncher"
}

# ---------------- 6. global config not polluted ----------------
# NOTE: this checks the *state* of the user's machine, not what this launcher
# wrote. The OmniRoute launchers here never write to %USERPROFILE%\.codex.
# If this FAILs the operator likely set the override manually in a previous
# experiment -- they should remove it for a clean baseline.
#
# Resolve USERPROFILE via SHGetKnownFolderPath, not via the $env:USERPROFILE
# variable. The verifier may itself be running inside a parent shell that has
# already overridden USERPROFILE (e.g. when invoked from within an isolated
# Codex runtime that points USERPROFILE at .codex-omniroute-home\profile).
# Special-folder lookup is token-based and ignores that override, so we always
# check the real user's profile.
$realUserProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if (-not $realUserProfile) { $realUserProfile = $env:USERPROFILE }
$globalConfig = Join-Path $realUserProfile '.codex\config.toml'
if (Test-Path -LiteralPath $globalConfig) {
    $globalText = Read-Utf8Text -Path $globalConfig
    if ($globalText -match 'model_provider\s*=\s*"omniroute_bridge"') {
        Add-Result 'global-config-clean' 'FAIL' "global $globalConfig already contains model_provider=`"omniroute_bridge`" -- this launcher did not write it, but you should remove it manually for a clean baseline."
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
    & $psHost -NoProfile -File $officialLauncher -DryRun *> $null 2>&1
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
    $launcherArgs = @('-NoProfile', '-File', $omniLauncher, '-NoCodex', '-BridgePort', "$BridgePort", '-RuntimeHome', $RuntimeHome)
    if ($FreshRuntime) { $launcherArgs += '-Reset' }
    & $psHost @launcherArgs
    if ($LASTEXITCODE -ne 0) { throw "launcher exited with code $LASTEXITCODE" }
    Add-Result 'omniroute-launch' 'PASS' ('-NoCodex succeeded' + ($(if ($FreshRuntime) { ' (fresh runtime)' } else { '' })))
} catch {
    Add-Result 'omniroute-launch' 'FAIL' $_.Exception.Message
    exit 1
}

# Discover the *actual* port the launcher picked. The requested -BridgePort
# may have been busy (e.g. another Codex install holding 20333), in which case
# Find-FreePort moved us forward to 20334 / 20335 / .... We discover the real
# port in three steps:
#   1) parse the most recent `port=NNNN` line from bridge.log
#   2) probe /healthz across $BridgePort..$BridgePort+50 as a fallback
#   3) hard-fail if neither finds a live bridge
function Resolve-BridgePort {
    param([string]$LogFile, [int]$Preferred, [int]$Range = 50)

    if (Test-Path -LiteralPath $LogFile) {
        $lines = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue
        if ($lines) {
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -match 'port=(\d+)') {
                    $candidate = [int]$Matches[1]
                    try {
                        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$candidate/healthz" -TimeoutSec 2 -ErrorAction Stop
                        if ($h.ok) { return @{ Port = $candidate; Source = "bridge.log"; Health = $h } }
                    } catch { }
                    break
                }
            }
        }
    }

    for ($p = $Preferred; $p -lt $Preferred + $Range; $p++) {
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$p/healthz" -TimeoutSec 1 -ErrorAction Stop
            if ($h.ok) { return @{ Port = $p; Source = "scan"; Health = $h } }
        } catch { }
    }
    return $null
}

$resolved = Resolve-BridgePort -LogFile $bridgeLogFile -Preferred $BridgePort
if (-not $resolved) {
    Add-Result 'bridge-port-resolved' 'FAIL' "could not locate live bridge on 127.0.0.1:$BridgePort..$($BridgePort+50). See $bridgeLogFile."
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}
$actualPort = [int]$resolved.Port
$health     = $resolved.Health
Add-Result 'bridge-port-resolved' 'PASS' ("port={0} (source={1}); requested={2}" -f $actualPort, $resolved.Source, $BridgePort)

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

# health (already retrieved during Resolve-BridgePort)
if ($health -and $health.ok) {
    Add-Result 'bridge-health' 'PASS' ("port={0} omniroute_configured={1}" -f $health.port, $health.omniroute.configured)
} else {
    Add-Result 'bridge-health' 'FAIL' "no /healthz response from port $actualPort"
}

# isolated config
$isolatedConfig = Join-Path $workspace (Join-Path $RuntimeHome 'codex\config.toml')
$isoText = $null
if (Test-Path -LiteralPath $isolatedConfig) {
    $isoText = Read-Utf8Text -Path $isolatedConfig
    $ok = ($isoText -match 'model_provider\s*=\s*"omniroute_bridge"') -and
          ($isoText -match '\[model_providers\.omniroute_bridge\]') -and
          ($isoText -match 'wire_api\s*=\s*"responses"') -and
          ($isoText -match 'requires_openai_auth\s*=\s*true')
    if ($ok) {
        Add-Result 'isolated-config-anchored' 'PASS' $isolatedConfig
    } else {
        Add-Result 'isolated-config-anchored' 'FAIL' "isolated config at $isolatedConfig missing required anchors"
    }
} else {
    Add-Result 'isolated-config-anchored' 'FAIL' "missing $isolatedConfig"
}

# ---------------- 11. isolated config inheritance allowlist ----------------
# Even with the launcher's allowlist sanitizer, a stray manual edit could
# reintroduce forbidden tables. We assert that the produced isolated config
# contains NO forbidden section headers. The single allowed exception is the
# managed [projects."<workspace>"] block we own, and the omniroute_bridge /
# omniroute_managed model-provider/profile blocks.
if ($isoText) {
    $forbiddenSectionPatterns = @(
        @{ Name = 'no-marketplaces';      Pattern = '(?im)^\[\s*marketplaces(\.|\])';                                    Detail = '[marketplaces.*] sections must not be inherited' },
        @{ Name = 'no-plugins';            Pattern = '(?im)^\[\s*plugins(\.|\])';                                          Detail = '[plugins.*] sections must not be inherited' },
        @{ Name = 'no-windows';            Pattern = '(?im)^\[\s*windows\s*\]';                                            Detail = '[windows] section must not be inherited' },
        @{ Name = 'no-foreign-providers';  Pattern = '(?im)^\[\s*model_providers\.(?!omniroute_bridge\b)';                Detail = 'only [model_providers.omniroute_bridge] is allowed' },
        @{ Name = 'no-foreign-profiles';   Pattern = '(?im)^\[\s*profiles\.(?!omniroute_managed\b)';                       Detail = 'only [profiles.omniroute_managed] is allowed' }
    )
    foreach ($check in $forbiddenSectionPatterns) {
        if ($isoText -match $check.Pattern) {
            Add-Result $check.Name 'FAIL' $check.Detail
        } else {
            Add-Result $check.Name 'PASS' "absent"
        }
    }

    # Project trust: the only [projects.*] entry in the isolated config must
    # be for the current workspace. Foreign project paths from the user's
    # global config (other repos, Documents\Codex\<date>\..., etc.) must not
    # appear here.
    $projectMatches = [regex]::Matches($isoText, '(?im)^\[\s*projects\.(.+?)\s*\]')
    $expectedKey = $workspace.Replace('\', '\\')
    $foreignProjects = @()
    foreach ($m in $projectMatches) {
        $key = $m.Groups[1].Value.Trim().Trim('"').Trim("'")
        $normKey = $key -replace '/', '\\'
        $normWorkspace = $expectedKey -replace '/', '\\'
        if ($normKey -ieq $normWorkspace) { continue }
        $foreignProjects += $key
    }
    if ($foreignProjects.Count -eq 0) {
        Add-Result 'no-foreign-projects' 'PASS' 'only the workspace project is trusted in the isolated config'
    } else {
        Add-Result 'no-foreign-projects' 'FAIL' ('foreign [projects.*] entries leaked: ' + ($foreignProjects -join '; '))
    }
}

# ---------------- 12. no git shim, no PATH override ----------------
# The launcher source must not reference a git shim, must not override PATH,
# and tools/git-shim/ must not contain a built shim binary. The whole point
# of removing the shim is that Codex sees the user's real git unchanged --
# anything that reintroduces it silently breaks the project goal.
$omniRaw = Read-Utf8Text -Path $omniLauncher
$omniCode = if ($omniRaw) { Strip-PSComments -Text $omniRaw } else { '' }
$shimSentinels = @(
    'Ensure-GitShim',
    'Resolve-CSharpCompiler',
    'OMNIROUTE_REAL_GIT_EXE',
    'tools\\git-shim',
    'tools/git-shim'
)
$shimHits = @()
foreach ($s in $shimSentinels) {
    if ($omniCode -match [regex]::Escape($s)) { $shimHits += $s }
}
if ($shimHits.Count -eq 0) {
    Add-Result 'no-git-shim-in-launcher' 'PASS' 'launcher does not reference a git shim'
} else {
    Add-Result 'no-git-shim-in-launcher' 'FAIL' ("launcher references shim sentinels: " + ($shimHits -join ', '))
}

$shimDir = Join-Path $workspace 'tools\git-shim'
$shimBin = Join-Path $shimDir 'bin\git.exe'
if (Test-Path -LiteralPath $shimBin) {
    Add-Result 'no-git-shim-binary' 'FAIL' "shim binary present at $shimBin (delete tools\git-shim or rebuild branch without it)"
} elseif (Test-Path -LiteralPath $shimDir) {
    # Directory present but no built binary -- still a regression hazard.
    Add-Result 'no-git-shim-binary' 'WARN' "tools\git-shim exists but contains no built git.exe; remove the directory entirely"
} else {
    Add-Result 'no-git-shim-binary' 'PASS' 'tools\git-shim absent'
}

# ---------------- 13. isolated skills directory under workspace ----------------
# The isolated runtime should resolve its skills dir from CODEX_HOME, which
# we point at .codex-omniroute-home\codex. If the directory exists and lives
# under the workspace, that's a signal the runtime initialized inside the
# isolated home rather than reaching back to the user's global ~\.codex\skills.
$isolatedSkills = Join-Path $workspace (Join-Path $RuntimeHome 'codex\skills')
$realUserCodex = Join-Path $realUserProfile '.codex'
$globalSkills = Join-Path $realUserCodex 'skills'
if (Test-Path -LiteralPath $isolatedSkills) {
    $resolvedIsolated = (Resolve-Path -LiteralPath $isolatedSkills).Path
    $resolvedGlobal = if (Test-Path -LiteralPath $globalSkills) { (Resolve-Path -LiteralPath $globalSkills).Path } else { $null }
    if ($resolvedGlobal -and ($resolvedIsolated -ieq $resolvedGlobal)) {
        Add-Result 'isolated-skills-under-workspace' 'FAIL' "isolated skills dir resolved to global $resolvedGlobal"
    } else {
        Add-Result 'isolated-skills-under-workspace' 'PASS' $resolvedIsolated
    }
} else {
    # Skills dir may not exist yet on a brand-new isolated runtime that hasn't
    # been driven by the GUI. Treat as informational.
    Add-Result 'isolated-skills-under-workspace' 'WARN' "no $isolatedSkills yet (launch the GUI once to populate)"
}

# ---------------- 14. bridge.log free of MCP-transport noise ----------------
# Look for any line that obviously cannot be a JSON-RPC frame and would
# corrupt the MCP stdio transport if it ever showed up in an MCP child's
# stdout. The bridge log is not the MCP transport itself, but if these
# patterns appear here it's a strong signal the process tree is leaking
# Windows process-management text into an inherited stdio chain.
if (Test-Path -LiteralPath $bridgeLogFile) {
    $logText = Read-Utf8Text -Path $bridgeLogFile
    $noisePatterns = @(
        'SUCCESS:\s+The process with PID',
        'Failed to parse MCP message',
        'Terminate batch job \(Y/N\)\?'
    )
    $noiseHits = @()
    foreach ($p in $noisePatterns) {
        if ($logText -and $logText -match $p) { $noiseHits += $p }
    }
    if ($noiseHits.Count -eq 0) {
        Add-Result 'bridge-log-clean' 'PASS' 'no MCP-transport noise in bridge.log'
    } else {
        Add-Result 'bridge-log-clean' 'WARN' ("noise patterns observed in bridge.log: " + ($noiseHits -join ', '))
    }
} else {
    Add-Result 'bridge-log-clean' 'WARN' "no $bridgeLogFile (bridge may not have logged yet)"
}

# ---------------- 15. MCP smoke (best-effort, opt-in via Python availability) ----------------
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
$mcpSmoke = Join-Path $workspace 'tools\mcp_smoke_test.py'
if ($python -and (Test-Path -LiteralPath $mcpSmoke)) {
    try {
        $smokeOutput = & $python.Source $mcpSmoke --isolated-config $isolatedConfig 2>&1
        $smokeExit = $LASTEXITCODE
        $detail = ($smokeOutput | Select-Object -First 1) -as [string]
        if ($smokeExit -eq 0) {
            Add-Result 'mcp-smoke' 'PASS' "exit=0 $detail"
        } else {
            Add-Result 'mcp-smoke' 'WARN' "exit=$smokeExit $detail"
        }
    } catch {
        Add-Result 'mcp-smoke' 'WARN' ("mcp_smoke_test.py failed: " + $_.Exception.Message)
    }
} else {
    $reason = if (-not $python) { 'python not on PATH' } else { 'mcp_smoke_test.py missing' }
    Add-Result 'mcp-smoke' 'WARN' "skipped ($reason)"
}

# ---------------- 17/18/19. freeform apply_patch invariants ----------------
# 17. The bundled Codex agent CLI must contain the freeform flag string,
#     otherwise the flag we write into the managed config does nothing
#     and apply_patch silently falls back to the shell-path (Access Denied
#     under non-AppX launches). We string-search the binary in chunks
#     because it is ~245 MB.
# 18. The isolated config.toml must contain the flag in the managed block.
#     This catches a future revision of the launcher that forgets to emit
#     the flag, or a -NoFreeformApplyPatch override that the operator did
#     not intend.
# 19. The active model in the managed block must look like a GPT-5 family
#     model. Freeform tools require the model to support custom tools
#     with grammar, which is GPT-5 territory. Setting the flag for
#     gpt-4.1 / Claude / Gemini etc. is a no-op AND silently regresses
#     apply_patch to the broken shell-path.
$pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
$freeformFlag = 'experimental_use_freeform_apply_patch'
if ($pkg) {
    if ($pkg -is [array]) { $pkg = $pkg[0] }
    $bundledAgent = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
    if (Test-Path -LiteralPath $bundledAgent) {
        $found = $false
        $chunk = 16 * 1024 * 1024
        try {
            $fs = [System.IO.File]::OpenRead($bundledAgent)
            try {
                $buf = [byte[]]::new($chunk)
                while ($true) {
                    $read = $fs.Read($buf, 0, $chunk)
                    if ($read -le 0) { break }
                    $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
                    if ($text.IndexOf($freeformFlag) -ge 0) { $found = $true; break }
                }
            } finally { $fs.Dispose() }
        } catch {
            Add-Result 'freeform-flag-supported' 'WARN' ("could not scan $bundledAgent" + ': ' + $_.Exception.Message)
        }
        if ($found) {
            Add-Result 'freeform-flag-supported' 'PASS' "bundled codex.exe contains '$freeformFlag'"
        } else {
            Add-Result 'freeform-flag-supported' 'FAIL' "bundled codex.exe does NOT contain '$freeformFlag' (Codex update may have renamed/removed the flag)"
        }
    } else {
        Add-Result 'freeform-flag-supported' 'WARN' "bundled codex.exe not found at $bundledAgent"
    }
} else {
    Add-Result 'freeform-flag-supported' 'WARN' 'OpenAI.Codex AppX package not installed; cannot scan bundled binary'
}

if ($isoText) {
    # Count how many DISTINCT placements of the flag we wrote. Codex accepts
    # the flag at top-level, inside a [features] table, per-profile inside
    # [profiles.<name>], AND inside [profiles.<name>.features]. We want all
    # four ideally; specifically [profiles.<name>.features] is what
    # profile_toml.rs:63 actually parses. Pass if all four positive
    # placements are present.
    $allTrue = [regex]::Matches($isoText, '(?im)^\s*experimental_use_freeform_apply_patch\s*=\s*true\b').Count
    $allFalse = [regex]::Matches($isoText, '(?im)^\s*experimental_use_freeform_apply_patch\s*=\s*false\b').Count
    $profileBlockMatch  = [regex]::Match($isoText, '(?ims)\[profiles\.omniroute_managed\][^\[]*?experimental_use_freeform_apply_patch\s*=\s*true')
    $profileFeatsMatch  = [regex]::Match($isoText, '(?ims)\[profiles\.omniroute_managed\.features\][^\[]*?experimental_use_freeform_apply_patch\s*=\s*true')
    if ($allTrue -gt 0 -and $profileBlockMatch.Success -and $profileFeatsMatch.Success) {
        Add-Result 'freeform-flag-set' 'PASS' "$freeformFlag = true present in [profiles.omniroute_managed] AND [profiles.omniroute_managed.features] ($allTrue total)"
    } elseif ($allTrue -gt 0 -and $profileBlockMatch.Success) {
        Add-Result 'freeform-flag-set' 'WARN' "$freeformFlag set in [profiles.omniroute_managed] but NOT in [profiles.omniroute_managed.features]; the .features sub-table is what profile_toml.rs:63 parses"
    } elseif ($allTrue -gt 0) {
        Add-Result 'freeform-flag-set' 'WARN' "$freeformFlag = true present at $allTrue place(s) but NOT inside the omniroute_managed profile (the profile section is what Codex actually honors when a profile is selected)"
    } elseif ($allFalse -gt 0) {
        Add-Result 'freeform-flag-set' 'WARN' "$freeformFlag = false (apply_patch will use shell-path)"
    } else {
        Add-Result 'freeform-flag-set' 'FAIL' "$freeformFlag is missing from the isolated config"
    }

    # Pull the managed-block model. It is the first `model = "..."` line
    # before any [profiles.*] / [model_providers.*] section.
    $managedModel = $null
    $modelLine = [regex]::Match($isoText, '(?im)^\s*model\s*=\s*"([^"]+)"')
    if ($modelLine.Success) { $managedModel = $modelLine.Groups[1].Value }
    if ($managedModel) {
        # GPT-5 family heuristic: anything starting with "gpt-5" (case-insensitive),
        # optionally with provider prefix like "openai/gpt-5..." or "cx/gpt-5...".
        $isGpt5 = $managedModel -match '(?i)(^|/)gpt-5(\.|-|$)'
        if ($isGpt5) {
            Add-Result 'freeform-model-compatible' 'PASS' "managed model '$managedModel' looks GPT-5 family"
        } else {
            Add-Result 'freeform-model-compatible' 'WARN' "managed model '$managedModel' is not GPT-5 family; freeform apply_patch will silently fall back to shell-path (Access Denied)"
        }
    } else {
        Add-Result 'freeform-model-compatible' 'WARN' "could not read managed model from isolated config"
    }
}

# ---------------- 20. user-local Codex bin invocability ----------------
# Codex Desktop unpacks its CLI toolkit (codex.exe, node.exe, rg.exe,
# codex-command-runner.exe, etc.) into <LOCALAPPDATA>\OpenAI\Codex\bin\
# on first launch. Those copies are bit-identical to the WindowsApps
# ones but live outside the AppX-protected directory, so they are
# invocable from any non-AppX child shell. This is the fallback path
# for `apply_patch.bat -> codex.exe --codex-run-as-apply-patch` when
# the freeform flag does not activate.
#
# We confirm the bin directory and the bundled `codex.exe` are present
# inside the isolated runtime, and that the launcher prepended that
# directory to Codex's PATH (unless -NoLocalCodexBinPath was passed).
$localCodexBin = Join-Path $workspace (Join-Path $RuntimeHome 'profile\AppData\Local\OpenAI\Codex\bin')
$localCodexExe = Join-Path $localCodexBin 'codex.exe'
if (Test-Path -LiteralPath $localCodexExe) {
    Add-Result 'local-codex-bin-present' 'PASS' $localCodexExe
} else {
    Add-Result 'local-codex-bin-present' 'WARN' "no codex.exe yet under $localCodexBin (Codex Desktop materializes this on first GUI launch; verify after the next non-NoCodex run)"
}

if ($omniRaw) {
    if ($omniRaw -match '(?im)NoLocalCodexBinPath' -and $omniRaw -match '\$localCodexBin\s*\+\s*'';''\s*\+\s*\$existingPath') {
        Add-Result 'local-codex-bin-path-logic' 'PASS' 'launcher prepends user-local Codex bin to PATH (default ON; -NoLocalCodexBinPath to disable)'
    } else {
        Add-Result 'local-codex-bin-path-logic' 'WARN' 'launcher does not appear to prepend user-local Codex bin to PATH (apply_patch shell-path may fail with Access Denied)'
    }
}

# apply_patch.bat shim in user-local Codex bin. This is our second defense
# against Codex's session-tmp bat hardcoding an absolute path to the
# WindowsApps codex.exe (which is blocked by AppX containment under our
# launch). The shim only fires when the user-local bin dir is FIRST on
# the agent shell's PATH; empirically Codex prepends its session-tmp
# dir AHEAD of our bin, so the shim is shadowed -- but it is harmless.
$shimBat = Join-Path $localCodexBin 'apply_patch.bat'
if (Test-Path -LiteralPath $shimBat) {
    $shimContent = Read-Utf8Text -Path $shimBat
    if ($shimContent -and $shimContent -match '(?im)^\s*codex\.exe\s+--codex-run-as-apply-patch\s+%\*') {
        Add-Result 'apply-patch-shim-present' 'PASS' "$shimBat resolves codex.exe via PATH"
    } else {
        Add-Result 'apply-patch-shim-present' 'WARN' "$shimBat exists but does not look like the launcher-managed shim (content: $($shimContent -replace '\s+', ' '))"
    }
} else {
    Add-Result 'apply-patch-shim-present' 'WARN' "no apply_patch.bat shim at $shimBat (launcher writes it next to user-local codex.exe; pass -NoLocalCodexBinPath to suppress)"
}

# apply_patch.bat rewriter daemon. This is our THIRD line of defense. The
# daemon polls <CODEX_HOME>\tmp\arg0\ for the apply_patch.bat that Codex
# generates per session, and rewrites the hardcoded WindowsApps codex.exe
# path to point at the user-local copy. Required when freeform-flag does
# not activate AND Codex's tmp dir is first on agent PATH (shadowing the
# bin shim) -- which is the current state of the world.
$rewriterPidFile = Join-Path $workspace 'apply-patch-rewriter.pid'
$rewriterScript  = Join-Path $workspace 'tools\apply_patch-rewriter.mjs'
if (Test-Path -LiteralPath $rewriterScript) {
    Add-Result 'apply-patch-rewriter-script' 'PASS' $rewriterScript
} else {
    Add-Result 'apply-patch-rewriter-script' 'WARN' "no $rewriterScript"
}
if (Test-Path -LiteralPath $rewriterPidFile) {
    $rwPid = (Get-Content -LiteralPath $rewriterPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($rwPid -match '^\d+$' -and (Get-Process -Id ([int]$rwPid) -ErrorAction SilentlyContinue)) {
        Add-Result 'apply-patch-rewriter-running' 'PASS' "pid=$rwPid, file=$rewriterPidFile"
    } else {
        Add-Result 'apply-patch-rewriter-running' 'WARN' "rewriter pid file '$rewriterPidFile' contains '$rwPid' but that process is not running"
    }
} else {
    Add-Result 'apply-patch-rewriter-running' 'WARN' "no rewriter daemon pid file at $rewriterPidFile (rerun launcher after Codex's first GUI launch creates the user-local codex.exe)"
}

# Inspect Codex's session-tmp apply_patch.bat (if a session has run
# in this isolated runtime) -- after rewriter activity it should point
# at the user-local codex.exe, NOT the WindowsApps one.
$tmpArg0 = Join-Path $workspace (Join-Path $RuntimeHome 'codex\tmp\arg0')
if (Test-Path -LiteralPath $tmpArg0) {
    $bats = @(Get-ChildItem -LiteralPath $tmpArg0 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Join-Path $_.FullName 'apply_patch.bat'
    } | Where-Object { Test-Path -LiteralPath $_ })
    if ($bats.Count -eq 0) {
        Add-Result 'apply-patch-rewriter-effective' 'WARN' "no apply_patch.bat under $tmpArg0 yet (Codex creates it on first agent session; rerun verifier after the agent has done at least one tool call)"
    } else {
        $brokenCount = 0
        $rewrittenCount = 0
        $sampleBroken = $null
        foreach ($bat in $bats) {
            $body = Read-Utf8Text -Path $bat
            if (-not $body) { continue }
            if ($body -match 'Program Files\\WindowsApps\\OpenAI\.Codex') {
                $brokenCount++
                if (-not $sampleBroken) { $sampleBroken = $bat }
            } else {
                $rewrittenCount++
            }
        }
        if ($brokenCount -eq 0) {
            Add-Result 'apply-patch-rewriter-effective' 'PASS' "$rewrittenCount apply_patch.bat under $tmpArg0 all point at non-AppX codex.exe"
        } else {
            Add-Result 'apply-patch-rewriter-effective' 'FAIL' "$brokenCount apply_patch.bat still hardcoded to WindowsApps codex.exe (sample: $sampleBroken); rewriter daemon may not be running or has not caught up yet"
        }
    }
} else {
    Add-Result 'apply-patch-rewriter-effective' 'WARN' "no $tmpArg0 yet (Codex creates this dir on first agent shell spawn)"
}

# ---------------- 21. MCP per-server JSON-RPC probe ----------------
# The smoke test only checks that each MCP server's command resolves on
# PATH. The probe actually spawns each stdio MCP server and waits for a
# JSON-RPC frame in response to an `initialize` request. This is what
# catches the "12 MCPs configured but only 1 actually transports JSON-RPC"
# failure mode that motivated the stdio shield.
$node = Get-Command node -ErrorAction SilentlyContinue
$mcpProbe = Join-Path $workspace 'tools\mcp_probe.mjs'
if ($node -and (Test-Path -LiteralPath $mcpProbe) -and (Test-Path -LiteralPath $isolatedConfig)) {
    try {
        $probeOutput = & $node.Source $mcpProbe --isolated-config $isolatedConfig --timeout-ms 6000 2>&1
        $probeExit = $LASTEXITCODE
        Write-Host ""
        Write-Host "[verify] MCP per-server probe output:" -ForegroundColor Cyan
        foreach ($l in $probeOutput) { Write-Host "  $l" -ForegroundColor Gray }
        $okCount = (@($probeOutput | Where-Object { $_ -match '^\[PASS\]' })).Count
        $failCount = (@($probeOutput | Where-Object { $_ -match '^\[FAIL\]' })).Count
        $skipCount = (@($probeOutput | Where-Object { $_ -match '^\[SKIP\]' })).Count
        $dirty = (@($probeOutput | Where-Object { $_ -match 'transport_dirty' })).Count
        $detail = "ok=$okCount fail=$failCount skip=$skipCount dirty=$dirty"
        if ($probeExit -ne 0) {
            Add-Result 'mcp-probe' 'WARN' "probe exit=$probeExit ($detail)"
        } elseif ($failCount -eq 0) {
            Add-Result 'mcp-probe' 'PASS' $detail
        } elseif ($okCount -gt 0) {
            Add-Result 'mcp-probe' 'WARN' "$detail -- some MCP servers failed to JSON-RPC handshake (see probe output above)"
        } else {
            Add-Result 'mcp-probe' 'FAIL' "$detail -- no MCP server responded with JSON-RPC (transport likely broken)"
        }
    } catch {
        Add-Result 'mcp-probe' 'WARN' ("mcp_probe.mjs failed: " + $_.Exception.Message)
    }
} else {
    $reason = if (-not $node) { 'node not on PATH' }
              elseif (-not (Test-Path -LiteralPath $mcpProbe)) { 'mcp_probe.mjs missing' }
              else { 'isolated config missing' }
    Add-Result 'mcp-probe' 'WARN' "skipped ($reason)"
}

# ---------------- bridge OmniRoute traffic freshness ----------------
# If bridge.log is present and nonempty, sanity-check that it does in fact
# contain at least one OmniRoute /v1/responses log line. Absence is a soft
# signal (no inference happened during this verifier run), so we only WARN.
if (Test-Path -LiteralPath $bridgeLogFile) {
    $logText2 = Read-Utf8Text -Path $bridgeLogFile
    if ($logText2 -and $logText2 -match 'omniroute -> https?://') {
        Add-Result 'bridge-log-has-omniroute' 'PASS' 'at least one omniroute -> ... line present'
    } else {
        Add-Result 'bridge-log-has-omniroute' 'WARN' 'no historical omniroute traffic in bridge.log (run a query in Codex to populate)'
    }
}

# ---------------- 9. dictation base64 smoke ----------------
# Windows PowerShell 5.1 does NOT support -SkipHttpErrorCheck. We need to
# treat non-2xx responses as a normal result (not a thrown exception), so we
# wrap Invoke-WebRequest in try/catch and read $_.Exception.Response on the
# error path. This works identically in 5.1 and 7+.
function Invoke-StatusAwareWebRequest {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        $Body,
        [int]$TimeoutSec = 5
    )
    try {
        # Note: $args is an automatic PowerShell variable, so we use a different name.
        $iwrArgs = @{
            Uri        = $Uri
            Method     = $Method
            TimeoutSec = $TimeoutSec
            ErrorAction = 'Stop'
            UseBasicParsing = $true
        }
        if ($Headers) { $iwrArgs.Headers = $Headers }
        if ($null -ne $Body) { $iwrArgs.Body = $Body }
        return Invoke-WebRequest @iwrArgs
    } catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch {}
        if (-not $resp) { throw }
        $status = [int]$resp.StatusCode
        # PS 7+ exposes the upstream body via $_.ErrorDetails.Message (the
        # response stream has typically already been consumed). PS 5.1 leaves
        # it in $resp.GetResponseStream(). Try both.
        $bodyText = ''
        try {
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $bodyText = [string]$_.ErrorDetails.Message
            }
        } catch {}
        if (-not $bodyText) {
            try {
                $stream = $resp.GetResponseStream()
                if ($stream -and $stream.CanRead) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            } catch {}
        }
        return [pscustomobject]@{ StatusCode = $status; Content = $bodyText }
    }
}

try {
    $tinyBytes = [System.Text.Encoding]::ASCII.GetBytes('not-really-audio-but-bytes-flow')
    $b64 = [Convert]::ToBase64String($tinyBytes)
    $resp = Invoke-StatusAwareWebRequest `
        -Uri "http://127.0.0.1:$actualPort/transcribe" `
        -Method POST `
        -Headers @{ 'x-codex-base64' = '1'; 'content-type' = 'multipart/form-data; boundary=---x' } `
        -Body $b64 `
        -TimeoutSec 5
    # The bridge will try to forward to the official upstream; we don't care whether
    # the upstream accepts the bogus payload -- only that the bridge did not refuse
    # the base64 envelope locally (400 bad_request_encoding).
    $isLocalReject = ($resp.StatusCode -eq 400) -and ([string]$resp.Content -match 'bad_request_encoding')
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
            -Uri "http://127.0.0.1:$actualPort/v1/responses" `
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
            -Uri "http://127.0.0.1:$actualPort/v1/responses/compact" `
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

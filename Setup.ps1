<#
.SYNOPSIS
    Interactive first-time setup for Codex OmniRoute.

.DESCRIPTION
    Walks a non-technical user through the entire install in one go:

      1. Verifies prerequisites:
           - Microsoft Store Codex app (Get-AppxPackage OpenAI.Codex)
           - Node.js >= 18.18 on PATH
           - PowerShell 5.1+ (we are running in it)
         For each missing prerequisite the wizard prints a direct download
         link and stops — fixing it is up to the user, but the link is
         right there.

      2. Asks for the OmniRoute base_url and API key (the only two
         questions). The API key is read with -AsSecureString so it
         does not echo to the terminal. Both values land in
         `omniroute-provider.json`, which is gitignored.

      3. Writes `omniroute-provider.json` with sane defaults
         (model_prefix = "cx/", default_model = "gpt-5.4",
         gpt55_pin.enabled = false). Advanced fields can still be
         edited by hand if needed; the wizard never asks about them.

      4. Runs `verify-codex-omniroute.ps1 -NoLiveMcpSession` so the user
         gets a bridge-only PASS/FAIL summary before they ever launch
         Codex. A verifier crash never breaks Setup -- the config has
         already been written, and the user can always proceed to
         Start-Codex-OmniRoute.bat.

      5. Tells the user exactly which .bat to double-click next.

    Re-running Setup.bat overwrites `omniroute-provider.json` so you
    can always restart from scratch with fresh credentials. The file
    is in `.gitignore` and is never committed.

.PARAMETER NonInteractive
    Skip prompts; only check prerequisites and rerun the verifier.

.PARAMETER SkipVerify
    Do not run verify-codex-omniroute.ps1 at the end. Useful when the user
    knows their machine is already set up and just wants to refresh
    omniroute-provider.json.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Pretty printing
# ----------------------------------------------------------------------------

function Write-Banner {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host '  Codex OmniRoute - first-time setup' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param([int]$N, [string]$Title)
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $N, $Title) -ForegroundColor Yellow
    Write-Host ('-' * 64) -ForegroundColor DarkGray
}

function Write-OK    { param([string]$Msg) Write-Host "  OK   $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  WARN $Msg" -ForegroundColor Yellow }
function Write-Bad   { param([string]$Msg) Write-Host "  FAIL $Msg" -ForegroundColor Red }
function Write-Hint  { param([string]$Msg) Write-Host "       $Msg" -ForegroundColor Gray }

function Pause-IfInteractive {
    if (-not $NonInteractive) {
        Write-Host ''
        Read-Host 'Press Enter to exit' | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Prerequisite checks
# ----------------------------------------------------------------------------

function Test-Codex {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-OK "Microsoft Store Codex installed (package $($pkg.PackageFullName))"
        return $true
    }
    Write-Bad "Microsoft Store Codex app is NOT installed."
    Write-Hint "Open Microsoft Store and search for 'OpenAI Codex', or visit:"
    Write-Hint "  https://apps.microsoft.com/search?query=openai+codex"
    Write-Hint "After installing, sign in once and open the app, then re-run this Setup."
    return $false
}

function Test-Node {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Bad "Node.js is NOT installed (or not on PATH)."
        Write-Hint "Download the LTS installer from https://nodejs.org/ and install it."
        Write-Hint "After installing, close this window and re-run Setup.bat."
        return $false
    }
    $ver = ''
    try { $ver = (& node --version 2>$null).Trim() } catch {}
    if ($ver -match '^v(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -gt 18 -or ($major -eq 18 -and $minor -ge 18)) {
            Write-OK "Node.js $ver detected (>= 18.18 required)"
            return $true
        }
        Write-Bad "Node.js $ver is too old; the bridge needs >= 18.18."
        Write-Hint "Download the latest LTS from https://nodejs.org/ and re-run Setup.bat."
        return $false
    }
    Write-Warn "Could not parse Node.js version output: '$ver'. Continuing optimistically."
    return $true
}

function Test-Workspace {
    # Confirm we're in the repo root: bridge script must be next to this Setup.ps1.
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $bridge = Join-Path $root 'codex-openai-omniroute-bridge.mjs'
    $launcher = Join-Path $root 'Start-Codex-OmniRoute.ps1'
    $template = Join-Path $root 'omniroute-provider.example.json'
    foreach ($f in @($bridge, $launcher, $template)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Bad "Missing $f"
            Write-Hint "You must run Setup.bat from the repo root (where README.md sits)."
            return $false
        }
    }
    Write-OK "Repo files present (bridge, launcher, provider template)"
    return $true
}

# ----------------------------------------------------------------------------
# Provider JSON helpers
# ----------------------------------------------------------------------------

function Read-Required {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [string]$Example = ''
    )
    while ($true) {
        $hint = if ($Example) { " (example: $Example)" } else { '' }
        if ($Default) {
            $line = Read-Host ("{0}{1} [Enter for default: {2}]" -f $Prompt, $hint, $Default)
            if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
            return $line.Trim()
        }
        $line = Read-Host ("{0}{1}" -f $Prompt, $hint)
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
        Write-Warn 'This value is required. Try again.'
    }
}

function Read-SecretRequired {
    param([string]$Prompt)
    while ($true) {
        $sec = Read-Host -AsSecureString $Prompt
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
        Write-Warn 'API key cannot be empty. Try again.'
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $false)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $line = Read-Host ("{0} {1}" -f $Prompt, $suffix)
    if ([string]::IsNullOrWhiteSpace($line)) { return $DefaultYes }
    return ($line.Trim().ToLower() -in @('y', 'yes', 'д', 'да'))
}

function Save-ProviderJson {
    param(
        [string]$Path,
        [string]$BaseUrl,
        [string]$ApiKey
    )

    # Setup only asks for base_url and api_key. Every other field gets a
    # sane default here. Power users who need to change model_prefix,
    # model_aliases, default_model, or gpt55_pin can edit
    # omniroute-provider.json by hand -- the wizard never asks about them.
    $obj = [ordered]@{
        '_comment'      = 'Generated by Setup.ps1. Edit by hand or rerun Setup.bat. NEVER commit this file. Advanced fields (model_prefix, model_aliases, default_model, gpt55_pin) use safe defaults -- change them only if you know you need to.'
        'base_url'      = $BaseUrl
        'api_key'       = $ApiKey
        'model_prefix'  = 'cx/'
        'default_model' = 'gpt-5.4'
        'model_aliases' = [ordered]@{
            'gpt-5.5' = 'gpt-5.5-xhigh'
        }
        'headers'       = @{ 'x-codex-omniroute-client' = 'codex-omniroute-bridge' }
        'gpt55_pin'     = [ordered]@{
            '_comment'      = 'Optional. Only used when OMNIROUTE_PIN_55=1 in env, OR enabled=true here.'
            'enabled'       = $false
            'connection_id' = ''
            'aliases'       = @('gpt-5.5', 'gpt-5.5-thinking', 'gpt-5.5-mini')
        }
    }
    $json = $obj | ConvertTo-Json -Depth 10
    # UTF-8 without BOM (Codex's TOML/JSON loaders sometimes choke on BOMs).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

Write-Banner

Write-Step 1 'Checking prerequisites'
$prereq = $true
if (-not (Test-Workspace)) { $prereq = $false }
if (-not (Test-Codex))     { $prereq = $false }
if (-not (Test-Node))      { $prereq = $false }
if (-not $prereq) {
    Write-Host ''
    Write-Bad 'Fix the missing prerequisites above and re-run Setup.bat.'
    Pause-IfInteractive
    exit 2
}

$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$providerPath = Join-Path $repoRoot 'omniroute-provider.json'
$templatePath = Join-Path $repoRoot 'omniroute-provider.example.json'

if ($NonInteractive) {
    Write-Step 2 'Skipping interactive provider config (NonInteractive mode)'
    if (-not (Test-Path -LiteralPath $providerPath)) {
        Write-Bad 'omniroute-provider.json does not exist and NonInteractive was set.'
        Write-Hint 'Re-run Setup.bat without flags to create it interactively.'
        Pause-IfInteractive
        exit 2
    }
    Write-OK "Using existing $providerPath"
} else {
    Write-Step 2 'OmniRoute provider configuration'

    if (Test-Path -LiteralPath $providerPath) {
        Write-Warn "omniroute-provider.json already exists at $providerPath"
        Write-Hint 'It will be overwritten with the values you enter below.'
    }

    Write-Host ''
    Write-Host '  You need an OmniRoute base_url and API key from the repo maintainer.' -ForegroundColor White
    Write-Host '  See README.md, section "Where to get OmniRoute access", for the contact.' -ForegroundColor White
    Write-Host ''

    $baseUrl = Read-Required -Prompt 'OmniRoute base_url' -Example 'http://127.0.0.1:20128/v1'
    $apiKey  = Read-SecretRequired -Prompt 'OmniRoute API key (input hidden)'

    Save-ProviderJson -Path $providerPath -BaseUrl $baseUrl -ApiKey $apiKey

    Write-OK "Wrote $providerPath"
    Write-Hint 'This file is gitignored. Do not commit it.'
    Write-Hint 'Advanced fields (model_prefix, default_model, gpt55_pin) use safe defaults.'
    Write-Hint 'Edit omniroute-provider.json by hand only if you actually need to change them.'
}

if ($SkipVerify) {
    Write-Step 3 'Skipping verifier (-SkipVerify)'
} else {
    Write-Step 3 'Running verifier (bridge-only smoke; no Codex GUI)'

    $verifier = Join-Path $repoRoot 'verify-codex-omniroute.ps1'
    if (-not (Test-Path -LiteralPath $verifier)) {
        Write-Warn "Missing $verifier -- skipping verifier."
        Write-Hint 'Your omniroute-provider.json was still written. You can launch Codex.'
    } else {
        # Prefer pwsh, fall back to powershell.exe.
        $psExe = $null
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) { $psExe = $cmd.Source }
        if (-not $psExe) {
            $cmd = Get-Command powershell -ErrorAction SilentlyContinue
            if ($cmd) { $psExe = $cmd.Source }
        }
        if (-not $psExe) {
            Write-Warn 'No PowerShell host found to run the verifier -- skipping.'
        } else {
            # The verifier MUST NOT break Setup. The provider config has
            # already been written; the user must be able to proceed to
            # Start-Codex-OmniRoute.bat regardless of what the verifier
            # reports. We pre-seed $LASTEXITCODE so Set-StrictMode -Latest
            # never trips on an uninitialized automatic variable, and we
            # wrap the call in try/catch so a thrown error still leaves
            # Setup in a clean exit-0 state.
            $global:LASTEXITCODE = 0
            $verifierExit = $null
            try {
                & $psExe -NoProfile -File $verifier -NoLiveMcpSession
                $verifierExit = $LASTEXITCODE
            } catch {
                Write-Warn ("Verifier could not be launched: {0}" -f $_.Exception.Message)
            }
            if ($null -eq $verifierExit) {
                Write-Warn 'Verifier did not return an exit code; skipping its result.'
                Write-Hint 'Your omniroute-provider.json was still written. You can launch Codex.'
            } elseif ($verifierExit -eq 0) {
                Write-OK "Verifier passed (exit 0)."
            } else {
                Write-Warn "Verifier exited with code $verifierExit. Review the table above."
                Write-Hint 'Many WARN rows are expected on a first run before Codex Desktop has been opened once.'
                Write-Hint 'A FAIL on bridge-pid-managed / bridge-health means the bridge could not start.'
                Write-Hint 'You can still proceed to Start-Codex-OmniRoute.bat and try launching.'
            }
        }
    }
}

Write-Step 4 'Done. Next steps:'
Write-Host ''
Write-Host '  Double-click  Start-Codex-OmniRoute.bat  to launch Codex with OmniRoute.' -ForegroundColor Green
Write-Host '  Double-click  Start-Codex-Official.bat   for vanilla Codex (no rerouting).' -ForegroundColor Green
Write-Host ''
Write-Host '  Logs live at  bridge.log  in this folder.' -ForegroundColor Gray
Write-Host ''

Pause-IfInteractive
exit 0

[CmdletBinding()]
param(
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ElectronArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Join-Path $RootDir 'installer\codex-omniroute-setup'
$DepsScript = Join-Path $RootDir 'tools\Install-CodexOmniRouteDependencies.ps1'

$normalizedElectronArgs = @()
foreach ($arg in $ElectronArgs) {
    if ($arg -eq '--dry-run') {
        $DryRun = $true
    } else {
        $normalizedElectronArgs += $arg
    }
}
$ElectronArgs = $normalizedElectronArgs

function Write-Setup {
    param([string]$Message)
    Write-Host "[setup] $Message"
}

function Test-NodeRuntime {
    param([AllowNull()][string]$NodeExe)
    if ([string]::IsNullOrWhiteSpace($NodeExe)) { return $false }
    if (-not (Test-Path -LiteralPath $NodeExe)) { return $false }
    try {
        $version = (& $NodeExe --version 2>$null | Select-Object -First 1)
        return ($version -match '^v(?<major>\d+)\.' -and [int]$Matches.major -ge 20)
    } catch {
        return $false
    }
}

function Get-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [System.IO.Path]::GetFullPath($cmd.Source) }
    return ''
}

function Resolve-NodeRuntime {
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is required to install the local Node.js runtime.'
    }

    $localNode = Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\deps\node\node.exe'
    if (Test-NodeRuntime -NodeExe $localNode) {
        Write-Setup "Using local Node.js: $localNode"
        return $localNode
    }

    $pathNode = Get-CommandPath -Name 'node.exe'
    if (Test-NodeRuntime -NodeExe $pathNode) {
        Write-Setup "Using Node.js from PATH: $pathNode"
        return $pathNode
    }

    if (-not (Test-Path -LiteralPath $DepsScript)) {
        throw "Dependency installer was not found: $DepsScript"
    }

    Write-Setup 'Node.js 20+ was not found. Installing portable local Node.js, no winget required...'
    $jsonText = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $DepsScript -NodeOnly -AsJson
    if ($LASTEXITCODE -ne 0) {
        throw "Local Node.js installer failed with exit code $LASTEXITCODE."
    }

    $json = ($jsonText | Out-String).Trim() | ConvertFrom-Json -ErrorAction Stop
    $nodeExe = [string]$json.node_exe
    if (-not (Test-NodeRuntime -NodeExe $nodeExe)) {
        throw "Local Node.js install completed, but Node.js 20+ is not visible at $nodeExe."
    }

    Write-Setup "Local Node.js is ready: $nodeExe"
    return $nodeExe
}

if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'package.json'))) {
    throw "Source installer was not found at: $AppDir"
}

$nodeExe = Resolve-NodeRuntime
$nodeDir = Split-Path -Parent $nodeExe
$npmCmd = Join-Path $nodeDir 'npm.cmd'
$npxCmd = Join-Path $nodeDir 'npx.cmd'

if (-not (Test-Path -LiteralPath $npmCmd)) {
    $npmCmd = Get-CommandPath -Name 'npm.cmd'
}
if (-not (Test-Path -LiteralPath $npmCmd)) {
    throw 'npm.cmd was not found after resolving Node.js.'
}

$env:PATH = "$nodeDir;$env:PATH"
Push-Location $AppDir
try {
    if (-not (Test-Path -LiteralPath '.\node_modules\.package-lock.json')) {
        Write-Setup 'Installing Electron installer dependencies with npm ci...'
        & $npmCmd ci
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }
    } else {
        Write-Setup 'Dependencies are already installed.'
    }

    Write-Setup 'Building Electron installer UI...'
    & $npmCmd run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE." }

    if ($DryRun) {
        Write-Setup 'Dry run completed. The source installer is ready to launch.'
        exit 0
    }

    Write-Setup 'Opening Codex OmniRoute setup from source...'
    $electronCmd = Join-Path $AppDir 'node_modules\.bin\electron.cmd'
    if (Test-Path -LiteralPath $electronCmd) {
        & $electronCmd . @ElectronArgs
    } elseif (Test-Path -LiteralPath $npxCmd) {
        & $npxCmd --no-install electron . @ElectronArgs
    } else {
        throw 'Electron launcher was not found after npm install.'
    }
    if ($LASTEXITCODE -ne 0) { throw "Electron exited with code $LASTEXITCODE." }
} finally {
    Pop-Location
}

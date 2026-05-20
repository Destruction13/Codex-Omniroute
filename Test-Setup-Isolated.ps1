[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Reset,
    [switch]$FreshMachine,
    [switch]$InPlace,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SetupArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SandboxRoot = Join-Path $RootDir '.setup-isolated'
$SandboxSource = Join-Path $SandboxRoot 'Source'
$UserProfile = Join-Path $SandboxRoot 'UserProfile'
$LocalAppData = Join-Path $UserProfile 'AppData\Local'
$RoamingAppData = Join-Path $UserProfile 'AppData\Roaming'
$TempDir = Join-Path $SandboxRoot 'Temp'
$ProgramFiles = Join-Path $SandboxRoot 'ProgramFiles'
$DepsRoot = Join-Path $LocalAppData 'CodexOmniRoute\deps'

function Write-IsolatedSetup {
    param([string]$Message)
    Write-Host "[isolated-setup] $Message"
}

if ($Reset -and (Test-Path -LiteralPath $SandboxRoot)) {
    Write-IsolatedSetup "Resetting sandbox: $SandboxRoot"
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force
}

foreach ($dir in @($UserProfile, $LocalAppData, $RoamingAppData, $TempDir, $ProgramFiles, $DepsRoot)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$RunRoot = $RootDir
if (-not $InPlace) {
    Write-IsolatedSetup "Creating ZIP-like source copy: $SandboxSource"
    if (Test-Path -LiteralPath $SandboxSource) {
        Remove-Item -LiteralPath $SandboxSource -Recurse -Force
    }
    New-Item -ItemType Directory -Path $SandboxSource -Force | Out-Null
    $excludeDirs = @(
        '.git', '.setup-isolated', '.setup-test', '.worktrees',
        'node_modules', 'dist', 'dist-electron', 'release', 'artifacts'
    )
    $excludeFiles = @('*.log', '*.pid', '*.bak', '*.backup', 'omniroute-provider.json')
    & robocopy.exe $RootDir $SandboxSource /MIR /NFL /NDL /NJH /NJS /NP /XD @excludeDirs /XF @excludeFiles | Out-Host
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE."
    }
    $RunRoot = $SandboxSource
}

$oldEnv = @{}
$names = @(
    'USERPROFILE', 'HOME', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA',
    'TEMP', 'TMP', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'PATH',
    'CODEX_OMNI_DEPS_ROOT', 'CODEX_OMNI_FORCE_LOCAL_NODE',
    'CODEX_OMNI_FORCE_LOCAL_DOTNET', 'CODEX_OMNI_SETUP_SIMULATE_NO_CODEX',
    'CODEX_OMNI_SETUP_SIMULATE_NO_WINGET'
)
foreach ($name in $names) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $env:USERPROFILE = $UserProfile
    $env:HOME = $UserProfile
    $env:HOMEDRIVE = ([System.IO.Path]::GetPathRoot($UserProfile)).TrimEnd('\')
    $env:HOMEPATH = $UserProfile.Substring($env:HOMEDRIVE.Length)
    $env:APPDATA = $RoamingAppData
    $env:LOCALAPPDATA = $LocalAppData
    $env:TEMP = $TempDir
    $env:TMP = $TempDir
    $env:ProgramFiles = $ProgramFiles
    $env:ProgramW6432 = $ProgramFiles
    Set-Item -LiteralPath 'Env:ProgramFiles(x86)' -Value (Join-Path $SandboxRoot 'ProgramFilesX86')

    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }
    $env:PATH = @(
        (Join-Path $systemRoot 'System32'),
        $systemRoot,
        (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0')
    ) -join ';'

    $env:CODEX_OMNI_DEPS_ROOT = $DepsRoot
    $env:CODEX_OMNI_FORCE_LOCAL_NODE = '1'
    $env:CODEX_OMNI_FORCE_LOCAL_DOTNET = '1'

    if ($FreshMachine) {
        $env:CODEX_OMNI_SETUP_SIMULATE_NO_CODEX = '1'
        $env:CODEX_OMNI_SETUP_SIMULATE_NO_WINGET = '1'
        Write-IsolatedSetup 'FreshMachine mode: simulating missing Codex and winget inside the installer process.'
    }

    Write-IsolatedSetup "Sandbox root: $SandboxRoot"
    Write-IsolatedSetup "Run root: $RunRoot"
    Write-IsolatedSetup "LOCALAPPDATA: $env:LOCALAPPDATA"
    Write-IsolatedSetup "Deps root: $env:CODEX_OMNI_DEPS_ROOT"
    Write-IsolatedSetup 'PATH is isolated, so host Node.js/npm/winget aliases are hidden from source bootstrap.'

    $args = @()
    if ($DryRun) { $args += '--dry-run' }
    $args += $SetupArgs

    Push-Location $RunRoot
    try {
        & cmd.exe /d /c Setup.bat @args
        if ($LASTEXITCODE -ne 0) {
            throw "Setup.bat exited with code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
} finally {
    foreach ($name in $oldEnv.Keys) {
        if ($null -eq $oldEnv[$name]) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($name, [string]$oldEnv[$name], 'Process')
        }
    }
}

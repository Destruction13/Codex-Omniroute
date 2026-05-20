[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'FullSetup')]
    [string]$Mode = 'Bootstrap',
    [switch]$Reset,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SandboxRoot = Join-Path $RootDir '.setup-windows-sandbox'
$SandboxSource = Join-Path $SandboxRoot 'Codex-Omniroute'
$RunScript = Join-Path $SandboxSource 'sandbox-run.cmd'
$WsbPath = Join-Path $SandboxRoot 'CodexOmniRouteSetup.wsb'

function Write-Sandbox {
    param([string]$Message)
    Write-Host "[windows-sandbox] $Message"
}

function Escape-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

if ($Reset -and (Test-Path -LiteralPath $SandboxRoot)) {
    Write-Sandbox "Resetting sandbox workspace: $SandboxRoot"
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $SandboxRoot -Force | Out-Null

Write-Sandbox "Creating clean ZIP-like source copy: $SandboxSource"
if (Test-Path -LiteralPath $SandboxSource) {
    Remove-Item -LiteralPath $SandboxSource -Recurse -Force
}
New-Item -ItemType Directory -Path $SandboxSource -Force | Out-Null

$excludeDirs = @(
    '.git', '.setup-isolated', '.setup-test', '.setup-windows-sandbox',
    '.worktrees', 'node_modules', 'dist', 'dist-electron', 'release',
    'artifacts'
)
$excludeFiles = @('*.log', '*.pid', '*.bak', '*.backup', 'omniroute-provider.json')
& robocopy.exe $RootDir $SandboxSource /MIR /NFL /NDL /NJH /NJS /NP /XD @excludeDirs /XF @excludeFiles | Out-Host
if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed with exit code $LASTEXITCODE."
}

if ($Mode -eq 'Bootstrap') {
    $command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup-Isolated.ps1 -Reset -DryRun -InPlace'
    $description = 'Bootstrap mode: clean profile, no host Node/npm/winget in PATH, portable Node install, npm ci, build.'
} else {
    $command = '.\Setup.bat'
    $description = 'FullSetup mode: opens the real setup UI inside Windows Sandbox. Store/Codex availability depends on Windows Sandbox.'
}

@"
@echo off
title Codex OmniRoute Windows Sandbox Test
cd /d "%USERPROFILE%\Desktop\Codex-Omniroute"
echo [windows-sandbox] $description
echo [windows-sandbox] Running from: %CD%
echo.
$command
set RC=%ERRORLEVEL%
echo.
echo [windows-sandbox] Finished with exit code %RC%.
pause
exit /b %RC%
"@ | Set-Content -LiteralPath $RunScript -Encoding ASCII

$escapedHostFolder = Escape-XmlText -Value $SandboxSource
@"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedHostFolder</HostFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>C:\Users\WDAGUtilityAccount\Desktop\Codex-Omniroute\sandbox-run.cmd</Command>
  </LogonCommand>
  <Networking>Enable</Networking>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
</Configuration>
"@ | Set-Content -LiteralPath $WsbPath -Encoding UTF8

Write-Sandbox "Prepared: $WsbPath"

try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -ErrorAction Stop
    if ($feature -and $feature.State -ne 'Enabled') {
        Write-Sandbox 'Windows Sandbox optional feature is not enabled on this host.'
        Write-Sandbox 'Enable "Windows Sandbox" in Windows Features, reboot if Windows asks, then run this again.'
    }
} catch {
    Write-Sandbox 'Could not check the Windows Sandbox optional feature without elevation.'
    Write-Sandbox 'The .wsb file is still prepared; opening it will show whether Windows Sandbox is available.'
}

if ($PrepareOnly) {
    Write-Sandbox 'PrepareOnly mode: not opening Windows Sandbox.'
    exit 0
}

Write-Sandbox 'Opening Windows Sandbox...'
Start-Process -FilePath $WsbPath

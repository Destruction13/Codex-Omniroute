<#
.SYNOPSIS
    Builds the self-contained Codex OmniRoute Setup.exe bootstrapper.

.DESCRIPTION
    Uses the same local dependency setup as the launcher. The build output is
    copied to the repository root as Setup.exe. The executable only bootstraps
    adjacent project files; it does not embed secrets or CODEX_HOME state.
#>

[CmdletBinding()]
param(
    [string]$RuntimeIdentifier = 'win-x64',
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$scriptRoot = [System.IO.Path]::GetFullPath($scriptRoot)
$source = Join-Path $scriptRoot 'tools\setup-bootstrapper.cs'
$setupDeps = Join-Path $scriptRoot 'tools\Install-CodexOmniRouteDependencies.ps1'
$outputExe = Join-Path $scriptRoot 'Setup.exe'

if (-not (Test-Path -LiteralPath $source)) { throw "Missing bootstrapper source: $source" }
if (-not (Test-Path -LiteralPath $setupDeps)) { throw "Missing dependency setup script: $setupDeps" }

$deps = $null
if ($SkipDependencyInstall) {
    $dotnet = Get-Command dotnet -ErrorAction Stop
    $deps = [pscustomobject]@{ dotnet_exe = $dotnet.Source }
} else {
    $json = (& $setupDeps -Quiet -AsJson | Out-String).Trim()
    $deps = $json | ConvertFrom-Json -ErrorAction Stop
}

if (-not $deps.dotnet_exe -or -not (Test-Path -LiteralPath $deps.dotnet_exe)) {
    throw 'A .NET SDK is required to build Setup.exe.'
}

$buildRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\build\setup-bootstrapper'
} else {
    Join-Path $scriptRoot '.setup-bootstrapper-build'
}
$projectPath = Join-Path $buildRoot 'CodexOmniRouteSetup.csproj'
$programPath = Join-Path $buildRoot 'Program.cs'
$publishDir = Join-Path $buildRoot 'publish'

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $programPath -Force

$projectXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>false</ImplicitUsings>
    <Nullable>disable</Nullable>
    <AssemblyName>Setup</AssemblyName>
    <RuntimeIdentifier>$RuntimeIdentifier</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <PublishSingleFile>true</PublishSingleFile>
    <PublishTrimmed>true</PublishTrimmed>
    <EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>
    <DebugType>none</DebugType>
    <UseSharedCompilation>false</UseSharedCompilation>
    <BuildInParallel>false</BuildInParallel>
  </PropertyGroup>
</Project>
"@
[System.IO.File]::WriteAllText($projectPath, $projectXml, (New-Object System.Text.UTF8Encoding($false)))

$oldDotnetCliUseMsbuildServer = $env:DOTNET_CLI_USE_MSBUILD_SERVER
$oldMsbuildDisableNodeReuse = $env:MSBUILDDISABLENODEREUSE
$env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
$env:MSBUILDDISABLENODEREUSE = '1'
try {
    & $deps.dotnet_exe publish $projectPath `
        -c Release `
        -r $RuntimeIdentifier `
        -o $publishDir `
        --self-contained true `
        --source https://api.nuget.org/v3/index.json `
        -p:PublishSingleFile=true `
        -p:PublishTrimmed=true `
        -p:EnableCompressionInSingleFile=true `
        -p:UseSharedCompilation=false `
        -p:BuildInParallel=false
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE"
    }

    & $deps.dotnet_exe build-server shutdown 2>$null | Out-Null
} finally {
    if ($null -eq $oldDotnetCliUseMsbuildServer) {
        Remove-Item Env:\DOTNET_CLI_USE_MSBUILD_SERVER -ErrorAction SilentlyContinue
    } else {
        $env:DOTNET_CLI_USE_MSBUILD_SERVER = $oldDotnetCliUseMsbuildServer
    }
    if ($null -eq $oldMsbuildDisableNodeReuse) {
        Remove-Item Env:\MSBUILDDISABLENODEREUSE -ErrorAction SilentlyContinue
    } else {
        $env:MSBUILDDISABLENODEREUSE = $oldMsbuildDisableNodeReuse
    }
}

$built = Join-Path $publishDir 'Setup.exe'
if (-not (Test-Path -LiteralPath $built)) {
    throw "Published Setup.exe not found: $built"
}
Copy-Item -LiteralPath $built -Destination $outputExe -Force
Write-Host "[setup-build] wrote $outputExe"

<#
.SYNOPSIS
    Builds the Codex OmniRoute installer executables.

.DESCRIPTION
    Produces two deliverables at the repository root:

      * Setup.exe         — premium WPF wizard (tools/installer-wpf).
                            Embeds a snapshot of the current repository so the
                            installer can lay down all launcher / bridge files
                            into the user's chosen folder, then runs winget for
                            Codex Desktop / Node.js / .NET, writes
                            omniroute-provider.json, and runs Setup.ps1 for the
                            shared-home wiring.

      * Setup-Console.exe — legacy console bootstrapper (tools/setup-bootstrapper.cs).
                            Useful for headless / CI / automation flows. It only
                            invokes Setup.ps1 next to it; it does NOT install
                            Codex Desktop and does NOT clone the repo.

    Both executables are self-contained single-file builds (no .NET runtime
    required on the target machine).

.PARAMETER RuntimeIdentifier
    .NET runtime identifier to target. Defaults to 'win-x64'.

.PARAMETER SkipDependencyInstall
    Skip running tools/Install-CodexOmniRouteDependencies.ps1 and reuse the
    'dotnet' command already on PATH.

.PARAMETER SkipConsole
    Skip building Setup-Console.exe.

.PARAMETER SkipInstaller
    Skip building the WPF Setup.exe.

.PARAMETER Configuration
    Configuration name passed to 'dotnet publish'. Defaults to 'Release'.
#>

[CmdletBinding()]
param(
    [string]$RuntimeIdentifier = 'win-x64',
    [switch]$SkipDependencyInstall,
    [switch]$SkipConsole,
    [switch]$SkipInstaller,
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Pack-RepositorySnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$OutputZip
    )

    # Stage the files in a temp folder, then zip with .NET so we can wrap them
    # under a top-level "Codex-Omniroute/" directory and exclude build artefacts
    # / secrets in a robust way.
    $stageRoot = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\build\snapshot-stage'
    } else {
        Join-Path $RepoRoot '.snapshot-stage'
    }
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    $stageDir = Join-Path $stageRoot 'Codex-Omniroute'
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    $excludeDirNames = @(
        '.git',
        '.snapshot-stage',
        '.setup-bootstrapper-build',
        '.codex-omniroute-home',
        '.codex-omniroute-cache',
        'node_modules',
        'bin',
        'obj',
        'tools\installer-wpf\bin',
        'tools\installer-wpf\obj',
        'tools\installer-wpf\Resources'
    )
    $excludeFileNames = @(
        'Setup.exe',
        'Setup-Console.exe',
        'omniroute-provider.json',
        '.env',
        'auth.json',
        'auth.json.bak',
        'bridge.pid',
        'bridge.log',
        '.codex-omniroute-catalog-cache.json',
        '.DS_Store',
        'Thumbs.db'
    )

    Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force | Where-Object {
        $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
        if ([string]::IsNullOrEmpty($rel)) { return $false }

        foreach ($d in $excludeDirNames) {
            $needle = $d.Replace('/', '\')
            if ($rel -eq $needle) { return $false }
            if ($rel.StartsWith($needle + '\')) { return $false }
        }

        if (-not $_.PSIsContainer) {
            foreach ($f in $excludeFileNames) {
                if ($_.Name -ieq $f) { return $false }
            }
            # Skip log/pid noise we don't want to ship in the snapshot.
            if ($_.Name -like '*.log' -or $_.Name -like '*.log.*' -or $_.Name -like '*.pid' -or $_.Name -like '*.bak') {
                return $false
            }
        }
        return $true
    } | ForEach-Object {
        $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
        $target = Join-Path $stageDir $rel
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        } else {
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }

    if (Test-Path -LiteralPath $OutputZip) {
        Remove-Item -LiteralPath $OutputZip -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $OutputZip,
        [System.IO.Compression.CompressionLevel]::Optimal, $false) | Out-Null

    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}

$scriptRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$scriptRoot = [System.IO.Path]::GetFullPath($scriptRoot)
$consoleSource = Join-Path $scriptRoot 'tools\setup-bootstrapper.cs'
$installerProject = Join-Path $scriptRoot 'tools\installer-wpf\OmniRouteInstaller.csproj'
$installerResources = Join-Path $scriptRoot 'tools\installer-wpf\Resources'
$setupDeps = Join-Path $scriptRoot 'tools\Install-CodexOmniRouteDependencies.ps1'

if (-not (Test-Path -LiteralPath $setupDeps)) { throw "Missing dependency setup script: $setupDeps" }

# ---------------------------------------------------------------------
# Resolve dotnet
# ---------------------------------------------------------------------
$deps = $null
if ($SkipDependencyInstall) {
    $dotnet = Get-Command dotnet -ErrorAction Stop
    $deps = [pscustomobject]@{ dotnet_exe = $dotnet.Source }
} else {
    $json = (& $setupDeps -Quiet -AsJson | Out-String).Trim()
    $deps = $json | ConvertFrom-Json -ErrorAction Stop
}
if (-not $deps.dotnet_exe -or -not (Test-Path -LiteralPath $deps.dotnet_exe)) {
    throw 'A .NET SDK is required to build the installer.'
}

$oldDotnetCliUseMsbuildServer = $env:DOTNET_CLI_USE_MSBUILD_SERVER
$oldMsbuildDisableNodeReuse = $env:MSBUILDDISABLENODEREUSE
$env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
$env:MSBUILDDISABLENODEREUSE = '1'

try {
    # -----------------------------------------------------------------
    # Build Setup-Console.exe (legacy bootstrapper, ~10 MB)
    # -----------------------------------------------------------------
    if (-not $SkipConsole) {
        if (-not (Test-Path -LiteralPath $consoleSource)) {
            throw "Missing bootstrapper source: $consoleSource"
        }

        $consoleBuildRoot = if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\build\setup-bootstrapper'
        } else {
            Join-Path $scriptRoot '.setup-bootstrapper-build'
        }
        $consoleProject = Join-Path $consoleBuildRoot 'CodexOmniRouteSetupConsole.csproj'
        $consoleProgram = Join-Path $consoleBuildRoot 'Program.cs'
        $consolePublish = Join-Path $consoleBuildRoot 'publish'

        New-Item -ItemType Directory -Path $consoleBuildRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $consolePublish -Force | Out-Null
        Copy-Item -LiteralPath $consoleSource -Destination $consoleProgram -Force

        $consoleXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>false</ImplicitUsings>
    <Nullable>disable</Nullable>
    <AssemblyName>Setup-Console</AssemblyName>
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
        [System.IO.File]::WriteAllText($consoleProject, $consoleXml, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host '[setup-build] publishing Setup-Console.exe ...'
        & $deps.dotnet_exe publish $consoleProject `
            -c $Configuration `
            -r $RuntimeIdentifier `
            -o $consolePublish `
            --self-contained true `
            --source https://api.nuget.org/v3/index.json `
            -p:PublishSingleFile=true `
            -p:PublishTrimmed=true `
            -p:EnableCompressionInSingleFile=true `
            -p:UseSharedCompilation=false `
            -p:BuildInParallel=false
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish (console) failed with exit code $LASTEXITCODE" }

        $consoleBuilt = Join-Path $consolePublish 'Setup-Console.exe'
        if (-not (Test-Path -LiteralPath $consoleBuilt)) {
            throw "Published Setup-Console.exe not found: $consoleBuilt"
        }
        Copy-Item -LiteralPath $consoleBuilt -Destination (Join-Path $scriptRoot 'Setup-Console.exe') -Force
        Write-Host "[setup-build] wrote $(Join-Path $scriptRoot 'Setup-Console.exe')"
    }

    # -----------------------------------------------------------------
    # Build Setup.exe (premium WPF installer, ~70 MB)
    # -----------------------------------------------------------------
    if (-not $SkipInstaller) {
        if (-not (Test-Path -LiteralPath $installerProject)) {
            throw "Missing installer project: $installerProject"
        }

        # Snapshot the repository into a zip embedded inside Setup.exe so the
        # installer can lay it down on the target machine in one step.
        if (-not (Test-Path -LiteralPath $installerResources)) {
            New-Item -ItemType Directory -Path $installerResources -Force | Out-Null
        }
        $repoZip = Join-Path $installerResources 'CodexOmniRoute.zip'
        if (Test-Path -LiteralPath $repoZip) {
            Remove-Item -LiteralPath $repoZip -Force
        }

        Write-Host '[setup-build] packing repository snapshot ...'
        Pack-RepositorySnapshot -RepoRoot $scriptRoot -OutputZip $repoZip
        Write-Host "[setup-build] snapshot: $repoZip ($([math]::Round((Get-Item $repoZip).Length / 1MB, 2)) MB)"

        Write-Host '[setup-build] publishing Setup.exe ...'
        & $deps.dotnet_exe publish $installerProject `
            -c $Configuration `
            -r $RuntimeIdentifier `
            --self-contained true `
            --source https://api.nuget.org/v3/index.json `
            -p:PublishSingleFile=true `
            -p:EnableCompressionInSingleFile=true `
            -p:UseSharedCompilation=false `
            -p:BuildInParallel=false `
            -p:EnableWindowsTargeting=true
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish (installer) failed with exit code $LASTEXITCODE" }

        $publishDir = Join-Path (Split-Path -Parent $installerProject) "bin\$Configuration\net8.0-windows\$RuntimeIdentifier\publish"
        $built = Join-Path $publishDir 'Setup.exe'
        if (-not (Test-Path -LiteralPath $built)) {
            throw "Published Setup.exe not found: $built"
        }
        Copy-Item -LiteralPath $built -Destination (Join-Path $scriptRoot 'Setup.exe') -Force
        Write-Host "[setup-build] wrote $(Join-Path $scriptRoot 'Setup.exe')"
    }

    & $deps.dotnet_exe build-server shutdown 2>$null | Out-Null
}
finally {
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

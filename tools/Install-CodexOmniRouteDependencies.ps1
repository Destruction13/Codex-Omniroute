<#
.SYNOPSIS
    Ensures local dependencies required by the Codex OmniRoute Windows gateway.

.DESCRIPTION
    The shared-home gateway can run from the official Codex package, but the
    Windows Electron duplicate needs a small app-server wrapper executable.
    This setup script installs a local .NET SDK and, when needed, a local
    Node.js runtime under %LOCALAPPDATA%\CodexOmniRoute\deps.

    It does not mutate CODEX_HOME and does not install dependencies into the
    repository by default.
#>

[CmdletBinding()]
param(
    [string]$DepsRoot = '',
    [switch]$CheckOnly,
    [switch]$NodeOnly,
    [switch]$Quiet,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Step {
    param([string]$Message)
    if (-not $Quiet -and -not $AsJson) {
        Write-Host "[omniroute-setup] $Message"
    }
}

function Test-DotnetSdk {
    param([AllowNull()][string]$DotnetExe)
    if ([string]::IsNullOrWhiteSpace($DotnetExe)) { return $false }
    if (-not (Test-Path -LiteralPath $DotnetExe)) { return $false }
    try {
        $sdks = & $DotnetExe --list-sdks 2>$null
        return @($sdks).Count -gt 0
    } catch {
        return $false
    }
}

function Test-NodeRuntime {
    param([AllowNull()][string]$NodeExe)
    if ([string]::IsNullOrWhiteSpace($NodeExe)) { return $false }
    if (-not (Test-Path -LiteralPath $NodeExe)) { return $false }
    try {
        $version = (& $NodeExe --version 2>$null | Select-Object -First 1)
        if ($version -match '^v(?<major>\d+)\.') {
            return ([int]$Matches.major -ge 20)
        }
        return $false
    } catch {
        return $false
    }
}

function Get-CommandSource {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [System.IO.Path]::GetFullPath($cmd.Source) }
    return ''
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childFull = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside dependency root: $childFull"
    }
}

function Install-LocalDotnetSdk {
    param(
        [Parameter(Mandatory = $true)][string]$DotnetRoot,
        [Parameter(Mandatory = $true)][string]$DepsRoot
    )

    New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $DotnetRoot -Force | Out-Null

    $installer = Join-Path $DepsRoot 'dotnet-install.ps1'
    $uri = 'https://dot.net/v1/dotnet-install.ps1'
    Write-Step "downloading .NET SDK installer"
    Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing

    Write-Step "installing local .NET SDK 8.0 into $DotnetRoot"
    $psExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $psExe) { $psExe = Get-Command powershell.exe -ErrorAction Stop }
    $installOutput = @()
    $installExitCode = 1
    try {
        $installOutput = & $psExe.Source -NoProfile -ExecutionPolicy Bypass -File $installer -Channel 8.0 -InstallDir $DotnetRoot -NoPath 2>&1
        $installExitCode = $LASTEXITCODE
    } catch {
        $installOutput += $_
        $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($lastExit) { $installExitCode = [int]$lastExit.Value }
    }
    if ($installExitCode -eq 0) {
        if (-not $Quiet -and -not $AsJson) { $installOutput | Write-Host }
        return
    }

    if (-not $Quiet -and -not $AsJson) { $installOutput | Write-Host }
    Write-Step "dotnet-install.ps1 failed; downloading the .NET SDK archive directly"
    Install-LocalDotnetSdkArchive -DotnetRoot $DotnetRoot -DepsRoot $DepsRoot
}

function Get-DotnetDistArch {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ([string]$arch) {
        '^(AMD64|IA64|x64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        default { throw "Unsupported Windows architecture for local .NET SDK install: $arch" }
    }
}

function Resolve-DotnetSdkArchive {
    param([Parameter(Mandatory = $true)][string]$DepsRoot)

    $metadataPath = Join-Path $DepsRoot 'dotnet-8-releases.json'
    Write-Step "downloading .NET 8 release metadata"
    Invoke-WebRequest -Uri 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json' -OutFile $metadataPath -UseBasicParsing
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $rid = "win-$(Get-DotnetDistArch)"
    $expectedName = "dotnet-sdk-$rid.zip"

    foreach ($release in $metadata.releases) {
        $sdk = $release.sdk
        if (-not $sdk -or [string]::IsNullOrWhiteSpace([string]$sdk.version)) { continue }
        $file = @($sdk.files) | Where-Object {
            $_.rid -eq $rid -and $_.name -eq $expectedName -and -not [string]::IsNullOrWhiteSpace([string]$_.url)
        } | Select-Object -First 1
        if ($file) {
            return [pscustomobject]@{
                Version = [string]$sdk.version
                Rid = $rid
                Url = [string]$file.url
                Hash = [string]$file.hash
            }
        }
    }

    throw "Could not resolve a .NET SDK archive for $rid."
}

function Install-LocalDotnetSdkArchive {
    param(
        [Parameter(Mandatory = $true)][string]$DotnetRoot,
        [Parameter(Mandatory = $true)][string]$DepsRoot
    )

    New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
    Assert-ChildPath -Parent $DepsRoot -Child $DotnetRoot

    $archive = Resolve-DotnetSdkArchive -DepsRoot $DepsRoot
    $archivePath = Join-Path $DepsRoot "dotnet-sdk-$($archive.Version)-$($archive.Rid).zip"
    Assert-ChildPath -Parent $DepsRoot -Child $archivePath

    Write-Step "downloading .NET SDK $($archive.Version) for $($archive.Rid)"
    Invoke-WebRequest -Uri $archive.Url -OutFile $archivePath -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($archive.Hash)) {
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA512).Hash.ToLowerInvariant()
        if ($actualHash -ne $archive.Hash.ToLowerInvariant()) {
            throw ".NET SDK archive hash mismatch."
        }
    }

    if (Test-Path -LiteralPath $DotnetRoot) {
        Remove-Item -LiteralPath $DotnetRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DotnetRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $DotnetRoot -Force

    if (-not (Test-Path -LiteralPath (Join-Path $DotnetRoot 'dotnet.exe'))) {
        throw ".NET SDK archive did not contain the expected dotnet.exe."
    }
}

function Get-NodeDistArch {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ([string]$arch) {
        '^(AMD64|IA64|x64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        default { throw "Unsupported Windows architecture for local Node.js install: $arch" }
    }
}

function Resolve-NodeVersion {
    param([Parameter(Mandatory = $true)][string]$DepsRoot)

    $explicit = [System.Environment]::GetEnvironmentVariable('CODEX_OMNI_NODE_VERSION', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        if ($explicit -notmatch '^v') { return "v$explicit" }
        return $explicit
    }

    $indexPath = Join-Path $DepsRoot 'node-dist-index.json'
    Write-Step "downloading Node.js release index"
    Invoke-WebRequest -Uri 'https://nodejs.org/dist/index.json' -OutFile $indexPath -UseBasicParsing
    $entries = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -ErrorAction Stop
    foreach ($entry in $entries) {
        $version = [string]$entry.version
        $lts = $entry.lts
        $isLts = ($null -ne $lts) -and ($lts -ne $false) -and ([string]$lts -ne 'False')
        if ($isLts -and ($version -match '^v(?<major>\d+)\.') -and ([int]$Matches.major -ge 20)) {
            return $version
        }
    }
    throw "Could not resolve a supported Node.js LTS release from nodejs.org."
}

function Install-LocalNodeRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$NodeRoot,
        [Parameter(Mandatory = $true)][string]$DepsRoot
    )

    New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
    Assert-ChildPath -Parent $DepsRoot -Child $NodeRoot

    $version = Resolve-NodeVersion -DepsRoot $DepsRoot
    $arch = Get-NodeDistArch
    $archiveName = "node-$version-win-$arch.zip"
    $archivePath = Join-Path $DepsRoot $archiveName
    $extractRoot = Join-Path $DepsRoot 'node-extract'
    $expandedRoot = Join-Path $extractRoot "node-$version-win-$arch"
    $uri = "https://nodejs.org/dist/$version/$archiveName"

    Assert-ChildPath -Parent $DepsRoot -Child $archivePath
    Assert-ChildPath -Parent $DepsRoot -Child $extractRoot
    Write-Step "downloading Node.js $version for win-$arch"
    Invoke-WebRequest -Uri $uri -OutFile $archivePath -UseBasicParsing

    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

    if (-not (Test-Path -LiteralPath (Join-Path $expandedRoot 'node.exe'))) {
        throw "Node.js archive did not contain the expected node.exe."
    }

    if (Test-Path -LiteralPath $NodeRoot) {
        Remove-Item -LiteralPath $NodeRoot -Recurse -Force
    }
    Move-Item -LiteralPath $expandedRoot -Destination $NodeRoot -Force
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($DepsRoot) -and -not [string]::IsNullOrWhiteSpace($env:CODEX_OMNI_DEPS_ROOT)) {
    $DepsRoot = $env:CODEX_OMNI_DEPS_ROOT
}
if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
    if (-not $env:LOCALAPPDATA) {
        throw "LOCALAPPDATA is required when -DepsRoot is not provided."
    }
    $DepsRoot = Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\deps'
}
$DepsRoot = [System.IO.Path]::GetFullPath($DepsRoot)
$dotnetRoot = Join-Path $DepsRoot 'dotnet'
$localDotnet = Join-Path $dotnetRoot 'dotnet.exe'
$nodeRoot = Join-Path $DepsRoot 'node'
$localNode = Join-Path $nodeRoot 'node.exe'
$pathDotnet = Get-CommandSource -Name 'dotnet'
$pathNode = Get-CommandSource -Name 'node'
$forceLocalDotnet = $env:CODEX_OMNI_FORCE_LOCAL_DOTNET -eq '1'
$forceLocalNode = $env:CODEX_OMNI_FORCE_LOCAL_NODE -eq '1'

$dotnetExe = ''
$dotnetSource = ''
if ($NodeOnly) {
    $dotnetExe = ''
    $dotnetSource = 'skipped-node-only'
} elseif (Test-DotnetSdk -DotnetExe $localDotnet) {
    $dotnetExe = $localDotnet
    $dotnetSource = 'local'
} elseif (-not $CheckOnly) {
    Install-LocalDotnetSdk -DotnetRoot $dotnetRoot -DepsRoot $DepsRoot
    if (-not (Test-DotnetSdk -DotnetExe $localDotnet)) {
        throw "Local .NET SDK install completed, but no SDK is visible at $localDotnet."
    }
    $dotnetExe = $localDotnet
    $dotnetSource = 'installed-local'
} elseif ((-not $forceLocalDotnet) -and (Test-DotnetSdk -DotnetExe $pathDotnet)) {
    $dotnetExe = $pathDotnet
    $dotnetSource = 'path'
}

$dotnetOk = $NodeOnly -or (-not [string]::IsNullOrWhiteSpace($dotnetExe))

$nodeExe = ''
$nodeSource = ''
if (Test-NodeRuntime -NodeExe $localNode) {
    $nodeExe = $localNode
    $nodeSource = 'local'
} elseif ((-not $forceLocalNode) -and (Test-NodeRuntime -NodeExe $pathNode)) {
    $nodeExe = $pathNode
    $nodeSource = 'path'
} elseif (-not $CheckOnly) {
    Install-LocalNodeRuntime -NodeRoot $nodeRoot -DepsRoot $DepsRoot
    if (-not (Test-NodeRuntime -NodeExe $localNode)) {
        throw "Local Node.js install completed, but no supported runtime is visible at $localNode."
    }
    $nodeExe = $localNode
    $nodeSource = 'installed-local'
}

$nodeOk = -not [string]::IsNullOrWhiteSpace($nodeExe)

$result = [pscustomobject]@{
    deps_root = $DepsRoot
    dotnet_root = $dotnetRoot
    dotnet_exe = $dotnetExe
    dotnet_source = $dotnetSource
    dotnet_sdk_available = $dotnetOk
    node_root = $nodeRoot
    node_exe = $nodeExe
    node_source = $nodeSource
    node_available = $nodeOk
}

if (-not $dotnetOk) {
    if ($CheckOnly) {
        if ($AsJson) { $result | ConvertTo-Json -Depth 4 -Compress }
        throw "No .NET SDK is available. Run this setup script without -CheckOnly to install a local SDK."
    }
    throw "No .NET SDK is available."
}
if (-not $nodeOk) {
    if ($CheckOnly) {
        if ($AsJson) { $result | ConvertTo-Json -Depth 4 -Compress }
        throw "Node.js 20 or newer is required. Run this setup script without -CheckOnly to install a local runtime."
    }
    throw "Node.js 20 or newer is required."
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 4 -Compress
} else {
    $result | Format-List
}

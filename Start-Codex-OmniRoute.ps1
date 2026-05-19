<#
.SYNOPSIS
    Launch Codex OmniRoute through the shared official Codex home.

.DESCRIPTION
    This launcher implements the shared-home gateway architecture:

      - CODEX_HOME is the normal official home: %USERPROFILE%\.codex.
      - No .codex-omniroute-home directory is seeded or selected.
      - No user-scope CODEX_HOME lease is written for AppX activation.
      - OmniRoute is selected only for this launch by the duplicated
        Electron app's embedded app-server wrapper and process-level -c
        overrides.

    Official Codex remains official when launched from the Start Menu or
    Start-Codex-Official.ps1. Compact and dictation stay on the official
    backend; main reasoning and image endpoints route through the local bridge.

.PARAMETER NoCodex
    Start the local bridge and print the runtime overrides, but do not launch
    Codex Desktop.

.PARAMETER Restore
    Stop the managed bridge and clear stale legacy user-scope CODEX_HOME only
    when it points at this repo's old .codex-omniroute-home path.

.PARAMETER DryRun
    Print the resolved shared home, bridge, Codex CLI, and runtime overrides
    without starting anything.

.PARAMETER PrepareOnly
    Install launcher dependencies, refresh the duplicated Windows app, build
    the app-server wrapper, and exit without starting the bridge or Codex GUI.

.PARAMETER BridgePort
    Preferred bridge port. The launcher searches nearby ports if this one is
    busy. Default: 20333.

.PARAMETER ProviderJson
    Path to omniroute-provider.json. Relative paths are resolved against the
    repository root.

.PARAMETER OpenProject
    Optional workspace path to open in Codex Desktop.

.PARAMETER Model
    Runtime model passed only to the OmniRoute process. Default: gpt-5.5.

.PARAMETER ReasoningEffort
    Runtime reasoning effort passed only to the OmniRoute process. Default:
    xhigh.

.PARAMETER ProviderId
    Runtime provider id. Default: omniroute.

.PARAMETER UseAppxActivation
    Fallback launch method that activates the Store app directly with the same
    argument string. The preferred Windows path is the duplicated Electron app
    because it gives OmniRoute its own UI/app-server chain while keeping
    CODEX_HOME shared.

.PARAMETER NoAppDuplicate
    On Windows, skip the SuperCodex-style local Electron duplicate and launch
    through codex.exe app instead. The duplicate is preferred when Official
    Codex is already running because it gives OmniRoute a separate Electron
    userData/app-server chain while keeping CODEX_HOME shared.
#>

[CmdletBinding()]
param(
    [switch]$NoCodex,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$PrepareOnly,
    [int]$BridgePort = 20333,
    [string]$ProviderJson = './omniroute-provider.json',
    [string]$OpenProject = '',
    [string]$Model = 'gpt-5.5',
    [ValidateSet('low', 'medium', 'high', 'xhigh')]
    [string]$ReasoningEffort = 'xhigh',
    [string]$ProviderId = 'omniroute',
    [switch]$UseAppxActivation,
    [switch]$NoAppDuplicate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Publish-UserEnvironmentChange {
    if (-not (Test-WindowsHost)) { return }
    if (-not ('CodexOmniRouteSharedHomeEnvBroadcaster' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexOmniRouteSharedHomeEnvBroadcaster {
    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
    private const uint WM_SETTINGCHANGE = 0x001A;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);

    public static void BroadcastEnvironmentChange() {
        UIntPtr result;
        SendMessageTimeout(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            UIntPtr.Zero,
            "Environment",
            SMTO_ABORTIFHUNG,
            5000,
            out result);
    }
}
'@
    }
    try { [CodexOmniRouteSharedHomeEnvBroadcaster]::BroadcastEnvironmentChange() } catch {}
}

function Clear-LegacyUserCodexHomeOverride {
    param([Parameter(Mandatory = $true)][string]$LegacyHome)
    if (-not (Test-WindowsHost)) { return }
    $current = [System.Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
    if (Test-SamePath $current $LegacyHome) {
        [System.Environment]::SetEnvironmentVariable('CODEX_HOME', $null, 'User')
        Publish-UserEnvironmentChange
        Write-Host "[omniroute] cleared stale legacy user-scope CODEX_HOME override"
    }
}

function Get-OfficialCodexHome {
    $root = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Cannot resolve user profile root: USERPROFILE and HOME are empty."
    }
    return [System.IO.Path]::GetFullPath((Join-Path $root '.codex'))
}

function Find-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Node.js was not found on PATH."
}

function Resolve-LocalCodexCli {
    param([switch]$Required)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'))
    }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\') { continue }
        if (Test-Path -LiteralPath $candidate) { return [System.IO.Path]::GetFullPath($candidate) }
    }

    if ($Required) {
        throw "Could not find local codex.exe. Open official Codex once so %LOCALAPPDATA%\OpenAI\Codex\bin is populated."
    }
    return ''
}

function Resolve-CodexAppx {
    if (-not (Test-WindowsHost)) {
        return [pscustomobject]@{ AumId = 'NON-WINDOWS-STUB!App'; ExePath = ''; InstallLoc = ''; Package = $null }
    }

    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) { throw "Official Codex Microsoft Store app is not installed." }
    if ($pkg -is [array]) { $pkg = $pkg[0] }

    $appId = 'App'
    try {
        $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifestPath) {
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
            if ($manifest.Package.Applications.Application.Id) {
                $appId = $manifest.Package.Applications.Application.Id
            }
        }
    } catch {}

    return [pscustomobject]@{
        AumId      = "$($pkg.PackageFamilyName)!$appId"
        ExePath    = Join-Path $pkg.InstallLocation 'app\Codex.exe'
        InstallLoc = $pkg.InstallLocation
        Package    = $pkg
    }
}

function Start-CodexViaAppx {
    param(
        [Parameter(Mandatory = $true)][string]$AumId,
        [string]$Arguments = ''
    )

    if (-not ('CodexOmniRouteSharedHomeAppxActivator' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class CodexOmniRouteSharedHomeApplicationActivationManager {}

[Flags]
public enum CodexOmniRouteSharedHomeActivateOptions {
    None = 0,
    DesignMode = 1,
    NoErrorUI = 2,
    NoSplashScreen = 4
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICodexOmniRouteSharedHomeApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        CodexOmniRouteSharedHomeActivateOptions options,
        out uint processId);
}

public static class CodexOmniRouteSharedHomeAppxActivator {
    public static int Activate(string appUserModelId, string arguments, out uint processId) {
        var manager = (ICodexOmniRouteSharedHomeApplicationActivationManager)new CodexOmniRouteSharedHomeApplicationActivationManager();
        return manager.ActivateApplication(
            appUserModelId,
            arguments ?? "",
            CodexOmniRouteSharedHomeActivateOptions.NoErrorUI,
            out processId);
    }
}
'@
    }

    [uint32]$activatedPid = 0
    $hr = [CodexOmniRouteSharedHomeAppxActivator]::Activate($AumId, $Arguments, [ref]$activatedPid)
    if ($hr -ne 0) {
        throw ("AppX activation failed for {0} (HRESULT 0x{1:X8})." -f $AumId, $hr)
    }
    return $activatedPid
}

function Import-LocalEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $count = 0
    foreach ($raw in [System.IO.File]::ReadLines($Path)) {
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).Trim() }

        $match = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        if (-not $match.Success) { continue }

        $name = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        } elseif ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
        $count += 1
    }

    if ($count -gt 0) {
        Write-Host "[omniroute] loaded local .env ($count variable(s), values hidden)"
    }
}

function Read-ProviderJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "[omniroute] provider JSON did not parse: $Path"
        return $null
    }
}

function Get-ProviderApiKey {
    param([AllowNull()]$Provider)
    if ($env:OMNIROUTE_API_KEY) { return $env:OMNIROUTE_API_KEY }
    if ($env:CODEX_OMNI_OMNIROUTE_API_KEY) { return $env:CODEX_OMNI_OMNIROUTE_API_KEY }
    try {
        if ($Provider -and $Provider.PSObject.Properties.Name -contains 'api_key') { return [string]$Provider.api_key }
        if ($Provider -and $Provider.models.providers.omniroute.apiKey) { return [string]$Provider.models.providers.omniroute.apiKey }
    } catch {}
    return ''
}

function Test-PortOpen {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait(150)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Find-FreePort {
    param([int]$Preferred)
    for ($i = 0; $i -lt 40; $i++) {
        $candidate = $Preferred + $i
        if (-not (Test-PortOpen -Port $candidate)) { return $candidate }
    }
    throw "No free bridge port found near $Preferred."
}

function Stop-ManagedBridge {
    param([Parameter(Mandatory = $true)][string]$PidPath)
    if (-not (Test-Path -LiteralPath $PidPath)) { return }
    $pidText = ''
    try { $pidText = (Get-Content -LiteralPath $PidPath -Raw).Trim() } catch {}
    if ($pidText -match '^\d+$') {
        $existingPid = [int]$pidText
        try {
            $proc = Get-Process -Id $existingPid -ErrorAction Stop
            if ($proc.ProcessName -match '^node') {
                Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
                Write-Host "[omniroute] stopped managed bridge (pid=$existingPid)"
            }
        } catch {}
    }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Wait-ForBridgeHealth {
    param(
        [int]$Port,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastError = $null
    do {
        try {
            return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/healthz" -f $Port) -TimeoutSec 2
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 300
        }
    } while ((Get-Date) -lt $deadline)
    throw "Bridge did not become healthy on port $Port. Last error: $lastError"
}

function ConvertTo-WindowsArgument {
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

function Join-WindowsArgumentString {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
}

function Start-ProcessWithEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [switch]$Hidden
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    foreach ($key in $Environment.Keys) {
        $psi.Environment[$key] = [string]$Environment[$key]
    }
    if ($Hidden -and (Test-WindowsHost)) {
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    }
    return [System.Diagnostics.Process]::Start($psi)
}

function Start-DetachedProcessWithEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        [System.Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    try {
        $startParams = @{
            FilePath = $FilePath
            ArgumentList = $Arguments
            WorkingDirectory = $WorkingDirectory
            PassThru = $true
        }
        if (Test-WindowsHost) {
            $startParams['WindowStyle'] = [System.Diagnostics.ProcessWindowStyle]::Hidden
        }
        return Start-Process @startParams
    } finally {
        foreach ($key in $previous.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
        }
    }
}

function Stop-OmniRouteWindowsAppProcesses {
    param([Parameter(Mandatory = $true)][string]$DuplicateRoot)
    if (-not (Test-WindowsHost)) { return }
    if ([string]::IsNullOrWhiteSpace($DuplicateRoot)) { return }

    $root = [System.IO.Path]::GetFullPath($DuplicateRoot).TrimEnd('\', '/')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and ([System.IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase))
        })
    foreach ($proc in $processes) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "[omniroute] stopped duplicated app process (pid=$($proc.ProcessId))"
        } catch {}
    }
}

function Resolve-OmniRouteDependencies {
    param([Parameter(Mandatory = $true)][string]$ScriptRoot)
    $setupScript = Join-Path $ScriptRoot 'tools\Install-CodexOmniRouteDependencies.ps1'
    if (-not (Test-Path -LiteralPath $setupScript)) {
        throw "Dependency setup script missing: $setupScript"
    }
    $jsonText = (& $setupScript -Quiet -AsJson | Out-String).Trim()
    $deps = $jsonText | ConvertFrom-Json -ErrorAction Stop
    if (-not $deps.dotnet_sdk_available -or -not (Test-Path -LiteralPath $deps.dotnet_exe)) {
        throw "A .NET SDK is required to build the app-server wrapper."
    }
    if (-not $deps.node_available -or -not (Test-Path -LiteralPath $deps.node_exe)) {
        throw "Node.js 20 or newer is required to start the OmniRoute bridge."
    }
    return $deps
}

function Publish-AppServerWrapper {
    param(
        [Parameter(Mandatory = $true)][string]$WrapperSource,
        [Parameter(Mandatory = $true)][string]$OutputExe,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    $deps = Resolve-OmniRouteDependencies -ScriptRoot $ScriptRoot
    $dotnetExe = [string]$deps.dotnet_exe
    $buildRoot = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\build\codex-appserver-wrapper'
    } else {
        Join-Path $ScriptRoot '.codex-omniroute-wrapper-build'
    }
    $sourcePath = Join-Path $buildRoot 'Program.cs'
    $projectPath = Join-Path $buildRoot 'CodexOmniRouteAppServerWrapper.csproj'
    $publishDir = Join-Path $buildRoot 'publish'

    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
    Copy-Item -LiteralPath $WrapperSource -Destination $sourcePath -Force
    $projectXml = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>false</ImplicitUsings>
    <Nullable>disable</Nullable>
    <AssemblyName>codex</AssemblyName>
    <DebugType>none</DebugType>
    <UseSharedCompilation>false</UseSharedCompilation>
    <BuildInParallel>false</BuildInParallel>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath $projectPath -Value $projectXml -Encoding UTF8

    $oldDotnetCliUseMsbuildServer = $env:DOTNET_CLI_USE_MSBUILD_SERVER
    $oldMsbuildDisableNodeReuse = $env:MSBUILDDISABLENODEREUSE
    $env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
    $env:MSBUILDDISABLENODEREUSE = '1'
    try {
        $publishOutput = & $dotnetExe publish $projectPath -c Release -p:AssemblyName=codex -p:DebugType=none -p:UseSharedCompilation=false -p:BuildInParallel=false -o $publishDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            $detail = ($publishOutput | Out-String).Trim()
            if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) + '...' }
            throw "dotnet publish failed while building the app-server wrapper. $detail"
        }

        & $dotnetExe build-server shutdown 2>$null | Out-Null
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

    $publishedExe = Join-Path $publishDir 'codex.exe'
    if (-not (Test-Path -LiteralPath $publishedExe)) {
        throw "dotnet publish did not produce $publishedExe"
    }
    $outputDir = Split-Path -Parent $OutputExe
    foreach ($artifact in @('codex.exe', 'codex.dll', 'codex.deps.json', 'codex.runtimeconfig.json')) {
        $src = Join-Path $publishDir $artifact
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $outputDir $artifact) -Force
        }
    }
}

function Ensure-OmniRouteWindowsAppDuplicate {
    param(
        [Parameter(Mandatory = $true)][string]$SourceAppDir,
        [Parameter(Mandatory = $true)][string]$PackageFullName,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    if (-not (Test-WindowsHost)) { throw "Windows app duplicate is only available on Windows." }
    if (-not $env:LOCALAPPDATA) { throw "LOCALAPPDATA is required for the Windows app duplicate." }
    if (-not (Test-Path -LiteralPath $SourceAppDir)) { throw "Codex app directory not found: $SourceAppDir" }

    $duplicateRoot = Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\WindowsApp'
    $duplicateAppDir = Join-Path $duplicateRoot 'app'
    $resourcesDir = Join-Path $duplicateAppDir 'resources'
    $duplicateExe = Join-Path $duplicateAppDir 'Codex.exe'
    $officialEmbeddedExe = Join-Path $resourcesDir 'codex-official.exe'
    $wrapperExe = Join-Path $resourcesDir 'codex.exe'
    $wrapperDll = Join-Path $resourcesDir 'codex.dll'
    $wrapperDeps = Join-Path $resourcesDir 'codex.deps.json'
    $wrapperRuntimeConfig = Join-Path $resourcesDir 'codex.runtimeconfig.json'
    $wrapperSource = Join-Path $ScriptRoot 'tools\codex-appserver-wrapper.cs'
    $setupScript = Join-Path $ScriptRoot 'tools\Install-CodexOmniRouteDependencies.ps1'
    $markerPath = Join-Path $duplicateRoot '.omniroute-source.txt'
    $userDataDir = Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\ElectronUserData'

    if (-not (Test-Path -LiteralPath $wrapperSource)) {
        throw "Wrapper source missing: $wrapperSource"
    }

    if (-not (Test-Path -LiteralPath $setupScript)) {
        throw "Dependency setup script missing: $setupScript"
    }
    $deps = Resolve-OmniRouteDependencies -ScriptRoot $ScriptRoot

    $wrapperHash = (Get-FileHash -LiteralPath $wrapperSource -Algorithm SHA256).Hash
    $setupHash = (Get-FileHash -LiteralPath $setupScript -Algorithm SHA256).Hash
    $expectedMarker = "$PackageFullName`n$wrapperHash`n$setupHash`ndotnet-publish"
    $currentMarker = if (Test-Path -LiteralPath $markerPath) {
        (Get-Content -LiteralPath $markerPath -Raw).Trim()
    } else {
        ''
    }
    $needsRefresh = ($currentMarker -ne $expectedMarker) -or
        (-not (Test-Path -LiteralPath $duplicateExe)) -or
        (-not (Test-Path -LiteralPath $officialEmbeddedExe)) -or
        (-not (Test-Path -LiteralPath $wrapperExe)) -or
        (-not (Test-Path -LiteralPath $wrapperDll)) -or
        (-not (Test-Path -LiteralPath $wrapperDeps)) -or
        (-not (Test-Path -LiteralPath $wrapperRuntimeConfig))

    if ($needsRefresh) {
        Stop-OmniRouteWindowsAppProcesses -DuplicateRoot $duplicateRoot
        New-Item -ItemType Directory -Path $duplicateRoot -Force | Out-Null
        Write-Host "[omniroute] refreshing Windows Electron duplicate under $duplicateRoot"
        & robocopy $SourceAppDir $duplicateAppDir /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $robocopyExit = $LASTEXITCODE
        if ($robocopyExit -gt 7) {
            throw "robocopy failed while refreshing the Windows app duplicate (exit=$robocopyExit)."
        }

        if (Test-Path -LiteralPath $officialEmbeddedExe) {
            Remove-Item -LiteralPath $officialEmbeddedExe -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $wrapperExe)) {
            throw "Embedded codex.exe was not copied into the duplicate: $wrapperExe"
        }
        Move-Item -LiteralPath $wrapperExe -Destination $officialEmbeddedExe -Force

        Write-Host "[omniroute] building app-server wrapper with local dependency setup"
        Publish-AppServerWrapper -WrapperSource $wrapperSource -OutputExe $wrapperExe -ScriptRoot $ScriptRoot
        if (-not (Test-Path -LiteralPath $wrapperExe)) { throw "Failed to build app-server wrapper at $wrapperExe" }
        Set-Content -LiteralPath $markerPath -Value $expectedMarker -Encoding UTF8
    }

    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
    return [pscustomobject]@{
        Root = $duplicateRoot
        AppDir = $duplicateAppDir
        ExePath = $duplicateExe
        UserDataDir = $userDataDir
        DotnetRoot = [string]$deps.dotnet_root
        DotnetExe = [string]$deps.dotnet_exe
    }
}

function Get-RuntimeOverrideArgs {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeProviderId,
        [Parameter(Mandatory = $true)][string]$RuntimeModel,
        [Parameter(Mandatory = $true)][string]$RuntimeReasoningEffort,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $baseUrl = "http://127.0.0.1:$Port/v1"
    return @(
        '-c', ('model_provider="{0}"' -f $RuntimeProviderId),
        '-c', ('model="{0}"' -f $RuntimeModel),
        '-c', ('model_reasoning_effort="{0}"' -f $RuntimeReasoningEffort),
        '-c', 'features.tool_search=true',
        '-c', 'features.apply_patch_freeform=true',
        '-c', ('model_providers.{0}.name="OmniRoute"' -f $RuntimeProviderId),
        '-c', ('model_providers.{0}.base_url="{1}"' -f $RuntimeProviderId, $baseUrl),
        '-c', ('model_providers.{0}.wire_api="responses"' -f $RuntimeProviderId),
        '-c', ('model_providers.{0}.env_key="OMNIROUTE_API_KEY"' -f $RuntimeProviderId),
        '-c', ('model_providers.{0}.requires_openai_auth=true' -f $RuntimeProviderId),
        '-c', ('model_providers.{0}.supports_websockets=false' -f $RuntimeProviderId)
    )
}

function Test-SharedConfigHasOmniRouteGlobalProvider {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $inRoot = $true
    foreach ($line in [System.IO.File]::ReadLines($ConfigPath)) {
        if ($line -match '^\s*\[') { $inRoot = $false }
        if ($inRoot -and $line -match '^\s*model_provider\s*=\s*"(omniroute|omniroute_bridge)"') {
            return $true
        }
    }
    return $false
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
$scriptRoot = [System.IO.Path]::GetFullPath($scriptRoot)

$windowsDuplicateRoot = if ((Test-WindowsHost) -and $env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\WindowsApp' } else { '' }
$windowsDuplicateUserData = if ((Test-WindowsHost) -and $env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CodexOmniRoute\ElectronUserData' } else { '' }
$bridgeScript = Join-Path $scriptRoot 'codex-openai-omniroute-bridge.mjs'
$bridgePid = Join-Path $scriptRoot 'bridge.pid'
$bridgeLog = Join-Path $scriptRoot 'bridge.log'
$bridgeStdoutLog = Join-Path $scriptRoot 'bridge.stdout.log'
$bridgeStderrLog = Join-Path $scriptRoot 'bridge.stderr.log'
$desktopStdoutLog = Join-Path $scriptRoot 'codex-desktop.stdout.log'
$desktopStderrLog = Join-Path $scriptRoot 'codex-desktop.stderr.log'
$localEnvFile = Join-Path $scriptRoot '.env'
$legacyIsolatedHome = Join-Path $scriptRoot '.codex-omniroute-home'

Import-LocalEnvFile -Path $localEnvFile

$officialHome = Get-OfficialCodexHome
$officialConfig = Join-Path $officialHome 'config.toml'
$launcherDeps = Resolve-OmniRouteDependencies -ScriptRoot $scriptRoot
$nodeExe = [string]$launcherDeps.node_exe
if ([string]::IsNullOrWhiteSpace($nodeExe)) { $nodeExe = Find-NodeExe }
$appx = Resolve-CodexAppx
$useWindowsAppDuplicate = (Test-WindowsHost) -and (-not $UseAppxActivation) -and (-not $NoAppDuplicate)
$localCodexExe = Resolve-LocalCodexCli -Required:(-not $useWindowsAppDuplicate -and -not $UseAppxActivation)

$resolvedProviderJson = if ([System.IO.Path]::IsPathRooted($ProviderJson)) {
    [System.IO.Path]::GetFullPath($ProviderJson)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $ProviderJson))
}
$provider = Read-ProviderJson -Path $resolvedProviderJson
$providerApiKey = Get-ProviderApiKey -Provider $provider
if (-not [string]::IsNullOrWhiteSpace($providerApiKey)) {
    [System.Environment]::SetEnvironmentVariable('OMNIROUTE_API_KEY', $providerApiKey, 'Process')
}

if ($Restore) {
    Stop-ManagedBridge -PidPath $bridgePid
    if ($windowsDuplicateRoot) { Stop-OmniRouteWindowsAppProcesses -DuplicateRoot $windowsDuplicateRoot }
    Clear-LegacyUserCodexHomeOverride -LegacyHome $legacyIsolatedHome
    Write-Host "[omniroute] restore complete. Shared Codex home remains: $officialHome"
    exit 0
}

if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Bridge script not found: $bridgeScript"
}

$port = Find-FreePort -Preferred $BridgePort
$overrideArgs = Get-RuntimeOverrideArgs -RuntimeProviderId $ProviderId -RuntimeModel $Model -RuntimeReasoningEffort $ReasoningEffort -Port $port
$launchPathDescription = if ($UseAppxActivation) {
    'AppX ActivateApplication fallback'
} elseif ($useWindowsAppDuplicate) {
    'local duplicated Electron app with app-server wrapper'
} else {
    'codex.exe app'
}

Write-Host "[omniroute] Codex AumId:      $($appx.AumId)"
Write-Host "[omniroute] node:             $nodeExe"
Write-Host "[omniroute] local codex:      $localCodexExe"
Write-Host "[omniroute] bridge port:      $port"
Write-Host "[omniroute] shared CODEX_HOME:$officialHome"
Write-Host "[omniroute] provider JSON:    $resolvedProviderJson"
Write-Host "[omniroute] launch path:      $launchPathDescription"

if (Test-SharedConfigHasOmniRouteGlobalProvider -ConfigPath $officialConfig) {
    Write-Warning "[omniroute] shared config.toml already has a top-level OmniRoute model_provider. This launcher will not write or change it."
}

if ($DryRun) {
    [pscustomobject]@{
        Mode               = 'omniroute-shared-home'
        CodexHome          = $officialHome
        BridgePort         = $port
        BridgeScript       = $bridgeScript
        ProviderJson       = $resolvedProviderJson
        LocalCodexExe      = $localCodexExe
        WindowsAppDuplicate = if ($useWindowsAppDuplicate) { $windowsDuplicateRoot } else { $null }
        WindowsElectronUserData = if ($useWindowsAppDuplicate) { $windowsDuplicateUserData } else { $null }
        RuntimeOverrides   = $overrideArgs
        UserScopeCodexHome = if (Test-WindowsHost) { [System.Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') } else { $null }
        DryRun             = $true
    } | Format-List
    exit 0
}

if ($PrepareOnly) {
    Clear-LegacyUserCodexHomeOverride -LegacyHome $legacyIsolatedHome
    if ($useWindowsAppDuplicate) {
        $duplicate = Ensure-OmniRouteWindowsAppDuplicate `
            -SourceAppDir (Join-Path $appx.InstallLoc 'app') `
            -PackageFullName $appx.Package.PackageFullName `
            -ScriptRoot $scriptRoot
        [pscustomobject]@{
            Mode                    = 'omniroute-prepare'
            CodexHome               = $officialHome
            WindowsAppDuplicate     = $duplicate.Root
            WindowsElectronUserData = $duplicate.UserDataDir
            Wrapper                 = (Join-Path $duplicate.AppDir 'resources\codex.exe')
            OfficialEmbeddedCodex   = (Join-Path $duplicate.AppDir 'resources\codex-official.exe')
            DotnetRoot              = $duplicate.DotnetRoot
            NodeExe                 = $nodeExe
        } | Format-List
    } else {
        Write-Host "[omniroute] PrepareOnly: Windows duplicate disabled; dependencies are available and shared home is $officialHome"
    }
    exit 0
}

Clear-LegacyUserCodexHomeOverride -LegacyHome $legacyIsolatedHome
Stop-ManagedBridge -PidPath $bridgePid

$bridgeEnv = @{
    CODEX_HOME = $officialHome
    CODEX_BRIDGE_HOST = '127.0.0.1'
    CODEX_BRIDGE_PORT = "$port"
    BRIDGE_LOG_PATH = $bridgeLog
    OMNIROUTE_PROVIDER_JSON = $resolvedProviderJson
    CODEX_OMNI_DIAGNOSTIC_DIR = (Join-Path $officialHome 'omniroute\diagnostics')
    CODEX_OMNI_COMPACT_BACKEND = 'official'
    CODEX_OMNI_ALLOW_OFFICIAL_COMPACT = '1'
    CODEX_OMNI_ALLOW_OFFICIAL_RESPONSE_FALLBACK = '0'
    CODEX_OMNI_ROUTE_CLIENT_TOOL_REQUESTS_OFFICIAL = '0'
    CODEX_OMNI_ENABLE_TOOL_SEARCH_FUNCTION_SHIM = '1'
    CODEX_OMNI_ENABLE_TOOL_SEARCH_ALIAS_RERANK = '1'
    CODEX_OMNI_ENABLE_APPLY_PATCH_FUNCTION_ADAPTER = '1'
}
if (-not [string]::IsNullOrWhiteSpace($providerApiKey)) {
    $bridgeEnv['OMNIROUTE_API_KEY'] = $providerApiKey
}
if ($env:CODEX_OMNI_OMNIROUTE_IMAGE_API_KEY) {
    $bridgeEnv['CODEX_OMNI_OMNIROUTE_IMAGE_API_KEY'] = $env:CODEX_OMNI_OMNIROUTE_IMAGE_API_KEY
}

$bridgeProc = Start-DetachedProcessWithEnvironment `
    -FilePath $nodeExe `
    -Arguments @($bridgeScript) `
    -WorkingDirectory $scriptRoot `
    -Environment $bridgeEnv `
    -StdoutPath $bridgeStdoutLog `
    -StderrPath $bridgeStderrLog

if (-not $bridgeProc) { throw "Failed to start bridge process." }
Set-Content -LiteralPath $bridgePid -Value $bridgeProc.Id -Encoding ASCII

try {
    $health = Wait-ForBridgeHealth -Port $port -TimeoutSec 25
    Write-Host "[omniroute] bridge healthy on 127.0.0.1:$port (pid=$($bridgeProc.Id), home=$($health.codex_home))"
} catch {
    try { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    Remove-Item -LiteralPath $bridgePid -Force -ErrorAction SilentlyContinue
    throw
}

if ($NoCodex) {
    Write-Host "[omniroute] -NoCodex: bridge is running; Codex Desktop was not launched."
    Write-Host "[omniroute] runtime overrides:"
    Write-Host ("  {0}" -f (Join-WindowsArgumentString -Arguments $overrideArgs))
    exit 0
}

$desktopEnv = @{
    CODEX_HOME = $officialHome
    OMNIROUTE_API_KEY = $providerApiKey
    CODEX_BRIDGE_PORT = "$port"
    CODEX_OMNI_RUNTIME_PROVIDER_ID = $ProviderId
    CODEX_OMNI_RUNTIME_MODEL = $Model
    CODEX_OMNI_RUNTIME_REASONING_EFFORT = $ReasoningEffort
}

$openPath = if (-not [string]::IsNullOrWhiteSpace($OpenProject)) {
    [System.IO.Path]::GetFullPath($OpenProject)
} else {
    $scriptRoot
}

if ($UseAppxActivation) {
    $appxArgs = @($overrideArgs)
    if (-not [string]::IsNullOrWhiteSpace($OpenProject)) {
        $appxArgs += @('--open-project', $openPath)
    }
    $argString = Join-WindowsArgumentString -Arguments $appxArgs
    $activatedPid = Start-CodexViaAppx -AumId $appx.AumId -Arguments $argString
    Write-Host "[omniroute] launched Codex via AppX activation fallback (pid=$activatedPid)"
} elseif ($useWindowsAppDuplicate) {
    if ($windowsDuplicateRoot) { Stop-OmniRouteWindowsAppProcesses -DuplicateRoot $windowsDuplicateRoot }
    $duplicate = Ensure-OmniRouteWindowsAppDuplicate `
        -SourceAppDir (Join-Path $appx.InstallLoc 'app') `
        -PackageFullName $appx.Package.PackageFullName `
        -ScriptRoot $scriptRoot
    $desktopEnv['CODEX_ELECTRON_USER_DATA_PATH'] = [string]$duplicate.UserDataDir
    if ($duplicate.DotnetRoot) {
        $desktopEnv['DOTNET_ROOT'] = [string]$duplicate.DotnetRoot
        $desktopEnv['DOTNET_ROOT_X64'] = [string]$duplicate.DotnetRoot
        $desktopEnv['PATH'] = ("{0};{1}" -f $duplicate.DotnetRoot, [System.Environment]::GetEnvironmentVariable('PATH', 'Process'))
    }
    $appArgs = @($openPath)
    $desktopProc = Start-DetachedProcessWithEnvironment `
        -FilePath $duplicate.ExePath `
        -Arguments $appArgs `
        -WorkingDirectory $openPath `
        -Environment $desktopEnv `
        -StdoutPath $desktopStdoutLog `
        -StderrPath $desktopStderrLog
    if ($desktopProc -and $desktopProc.Id -gt 0) {
        Write-Host "[omniroute] launched duplicated Codex OmniRoute app (pid=$($desktopProc.Id), userData=$($duplicate.UserDataDir))"
    } else {
        Write-Host "[omniroute] launched duplicated Codex OmniRoute app (userData=$($duplicate.UserDataDir))"
    }
} else {
    $appArgs = @('app') + $overrideArgs + @($openPath)
    $desktopProc = Start-DetachedProcessWithEnvironment `
        -FilePath $localCodexExe `
        -Arguments $appArgs `
        -WorkingDirectory $openPath `
        -Environment $desktopEnv `
        -StdoutPath $desktopStdoutLog `
        -StderrPath $desktopStderrLog
    if ($desktopProc -and $desktopProc.Id -gt 0) {
        Write-Host "[omniroute] launched Codex via local codex.exe app (pid=$($desktopProc.Id))"
    } else {
        Write-Host "[omniroute] launched Codex via local codex.exe app"
    }
}

Write-Host "[omniroute] health: http://127.0.0.1:$port/healthz"
Write-Host "[omniroute] tail the bridge log:"
Write-Host "  Get-Content '$bridgeLog' -Tail 50 -Wait"

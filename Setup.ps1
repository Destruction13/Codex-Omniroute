<#
.SYNOPSIS
    One-click setup for the Codex OmniRoute shared-home gateway.

.DESCRIPTION
    This setup is intentionally boring for the user:

      1. Verifies that official Codex Desktop is installed.
      2. Installs local launcher dependencies under
         %LOCALAPPDATA%\CodexOmniRoute\deps when needed.
      3. Writes omniroute-provider.json from prompts, parameters, or env vars.
      4. Refreshes the duplicated Windows app and builds the embedded
         app-server wrapper.
      5. Creates desktop and Start Menu shortcuts.
      6. Runs the shared-home verifier.

    It does not write user-scope CODEX_HOME and does not create an isolated
    Codex home.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipVerify,
    [switch]$SkipShortcuts,
    [string]$ProviderBaseUrl = '',
    [string]$ProviderApiKey = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Banner {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host '  Codex OmniRoute Setup' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param([int]$N, [string]$Title)
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $N, $Title) -ForegroundColor Yellow
    Write-Host ('-' * 64) -ForegroundColor DarkGray
}

function Write-OK { param([string]$Message) Write-Host "  OK   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  WARN $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  FAIL $Message" -ForegroundColor Red }
function Write-Hint { param([string]$Message) Write-Host "       $Message" -ForegroundColor Gray }

function Pause-IfInteractive {
    if (-not $NonInteractive) {
        Write-Host ''
        Read-Host 'Press Enter to exit' | Out-Null
    }
}

function Get-RepoRoot {
    if ($PSScriptRoot) { return [System.IO.Path]::GetFullPath($PSScriptRoot) }
    return [System.IO.Path]::GetFullPath((Get-Location).Path)
}

function Convert-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Join-WindowsArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Convert-WindowsArgument $_ }) -join ' ')
}

function Get-PowerShellHost {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw 'PowerShell was not found.'
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $psExe = Get-PowerShellHost
    $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $proc = Start-Process -FilePath $psExe -ArgumentList (Join-WindowsArguments -Arguments $argList) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "$ScriptPath exited with code $($proc.ExitCode)."
    }
    return $proc.ExitCode
}

function Assert-Workspace {
    param([Parameter(Mandatory = $true)][string]$Root)

    $required = @(
        'codex-openai-omniroute-bridge.mjs',
        'Start-Codex-OmniRoute.ps1',
        'Start-Codex-Official.ps1',
        'verify-codex-omniroute.ps1',
        'tools\Install-CodexOmniRouteDependencies.ps1',
        'tools\codex-appserver-wrapper.cs',
        'bridge-modules\tool-adapters.mjs',
        'bridge-modules\media-cache.mjs',
        'omniroute-provider.example.json'
    )
    foreach ($rel in $required) {
        $path = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing required setup file: $path"
        }
    }
    Write-OK "Project files are present in $Root"
}

function Assert-OfficialCodexInstalled {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Write-Fail 'Official Codex Desktop is not installed.'
        Write-Hint 'Install official OpenAI Codex from Microsoft Store, sign in once, then run Setup.exe again.'
        throw 'Official Codex Desktop is required.'
    }
    if ($pkg -is [array]) { $pkg = $pkg[0] }
    Write-OK "Official Codex package found: $($pkg.PackageFullName)"
    return $pkg
}

function Read-RequiredValue {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [string]$Example = ''
    )

    while ($true) {
        $hint = if ($Example) { " (example: $Example)" } else { '' }
        if ($Default) {
            $value = Read-Host ("{0}{1} [Enter: {2}]" -f $Prompt, $hint, $Default)
            if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
            return $value.Trim()
        }
        $value = Read-Host ("{0}{1}" -f $Prompt, $hint)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Warn 'This value is required.'
    }
}

function Read-SecretValue {
    param([string]$Prompt)
    while ($true) {
        $secure = Read-Host -AsSecureString $Prompt
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
        Write-Warn 'This value is required.'
    }
}

function Save-ProviderJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )

    $provider = [ordered]@{
        '_comment' = 'Generated by Setup.exe / Setup.ps1. Never commit this file.'
        'base_url' = $BaseUrl
        'api_key' = $ApiKey
        'default_model' = 'gpt-5.5'
        'model_prefix' = 'cx/'
        'model_aliases' = [ordered]@{
            'gpt-5.5' = 'gpt-5.5-xhigh'
        }
        'headers' = @{
            'x-codex-omniroute-client' = 'codex-omniroute-bridge'
        }
    }

    $json = $provider | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Ensure-ProviderConfig {
    param([Parameter(Mandatory = $true)][string]$Root)

    $providerPath = Join-Path $Root 'omniroute-provider.json'
    if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl)) { $ProviderBaseUrl = $env:CODEX_OMNI_OMNIROUTE_BASE_URL }
    if ([string]::IsNullOrWhiteSpace($ProviderApiKey)) { $ProviderApiKey = $env:CODEX_OMNI_OMNIROUTE_API_KEY }

    if ($NonInteractive) {
        if ((Test-Path -LiteralPath $providerPath) -and
            [string]::IsNullOrWhiteSpace($ProviderBaseUrl) -and
            [string]::IsNullOrWhiteSpace($ProviderApiKey)) {
            Write-OK "Using existing provider config: $providerPath"
            return $providerPath
        }
        if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl) -or [string]::IsNullOrWhiteSpace($ProviderApiKey)) {
            throw 'NonInteractive setup requires existing omniroute-provider.json or CODEX_OMNI_OMNIROUTE_BASE_URL/CODEX_OMNI_OMNIROUTE_API_KEY.'
        }
    } else {
        if (Test-Path -LiteralPath $providerPath) {
            Write-Warn "Existing provider config will be overwritten: $providerPath"
        }
        if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl)) {
            $ProviderBaseUrl = Read-RequiredValue -Prompt 'Service URL' -Example 'https://service.example/v1'
        }
        if ([string]::IsNullOrWhiteSpace($ProviderApiKey)) {
            $ProviderApiKey = Read-SecretValue -Prompt 'Access key'
        }
    }

    Save-ProviderJson -Path $providerPath -BaseUrl $ProviderBaseUrl -ApiKey $ProviderApiKey
    Write-OK "Wrote provider config: $providerPath"
    return $providerPath
}

function Install-Dependencies {
    param([Parameter(Mandatory = $true)][string]$Root)

    $setup = Join-Path $Root 'tools\Install-CodexOmniRouteDependencies.ps1'
    $json = (& $setup -Quiet -AsJson | Out-String).Trim()
    $deps = $json | ConvertFrom-Json -ErrorAction Stop
    if (-not $deps.dotnet_sdk_available -or -not $deps.node_available) {
        throw 'Dependency setup did not report Node.js and .NET SDK availability.'
    }
    Write-OK "Node.js ready ($($deps.node_source)): $($deps.node_exe)"
    Write-OK ".NET SDK ready ($($deps.dotnet_source)): $($deps.dotnet_exe)"
    return $deps
}

function Create-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = ''
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Shortcut was not created: $Path"
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-UniqueExistingDirectories {
    param([string[]]$Paths)

    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $Paths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path -LiteralPath $full)) {
                New-Item -ItemType Directory -Path $full -Force | Out-Null
            }
            if ($seen.Add($full)) { [void]$result.Add($full) }
        } catch {}
    }
    return $result.ToArray()
}

function Install-Shortcuts {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$CodexPackage
    )

    $omniBat = Join-Path $Root 'Start-Codex-OmniRoute.bat'
    $officialBat = Join-Path $Root 'Start-Codex-Official.bat'
    $icon = Join-Path $CodexPackage.InstallLocation 'app\Codex.exe'
    $programs = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $folder = Join-Path $programs 'Codex OmniRoute'
    $desktopCandidates = Get-UniqueExistingDirectories @(
        [Environment]::GetFolderPath('DesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Desktop' } else { '' }),
        $(if ($env:OneDrive) { Join-Path $env:OneDrive 'Desktop' } else { '' }),
        $(if ($env:PUBLIC) { Join-Path $env:PUBLIC 'Desktop' } else { '' })
    )

    $desktopCreated = $false
    $desktopErrors = New-Object System.Collections.Generic.List[string]
    foreach ($desktop in $desktopCandidates) {
        try {
            $omniDesktop = Create-Shortcut -Path (Join-Path $desktop 'Codex OmniRoute.lnk') -TargetPath $omniBat -WorkingDirectory $Root -IconLocation $icon
            $officialDesktop = Create-Shortcut -Path (Join-Path $desktop 'Codex Official.lnk') -TargetPath $officialBat -WorkingDirectory $Root -IconLocation $icon
            Write-OK "Desktop shortcuts created: $omniDesktop; $officialDesktop"
            $desktopCreated = $true
            break
        } catch {
            [void]$desktopErrors.Add(("{0}: {1}" -f $desktop, $_.Exception.Message))
        }
    }

    if (-not $desktopCreated) {
        throw ("Desktop shortcut creation failed. Tried: {0}" -f ($desktopErrors.ToArray() -join ' | '))
    }

    $omniStart = Create-Shortcut -Path (Join-Path $folder 'Codex OmniRoute.lnk') -TargetPath $omniBat -WorkingDirectory $Root -IconLocation $icon
    $officialStart = Create-Shortcut -Path (Join-Path $folder 'Codex Official.lnk') -TargetPath $officialBat -WorkingDirectory $Root -IconLocation $icon
    Write-OK "Start Menu shortcuts created: $omniStart; $officialStart"
}

function Prepare-Launcher {
    param([Parameter(Mandatory = $true)][string]$Root)

    $launcher = Join-Path $Root 'Start-Codex-OmniRoute.ps1'
    [void](Invoke-PowerShellScript -ScriptPath $launcher -Arguments @('-Restore') -AllowFailure)
    [void](Invoke-PowerShellScript -ScriptPath $launcher -Arguments @('-PrepareOnly'))
    Write-OK 'Duplicated Codex OmniRoute app and app-server wrapper prepared.'
}

function Run-Verifier {
    param([Parameter(Mandatory = $true)][string]$Root)

    $verifier = Join-Path $Root 'verify-codex-omniroute.ps1'
    [void](Invoke-PowerShellScript -ScriptPath $verifier)
    Write-OK 'Verifier completed successfully.'
}

$root = Get-RepoRoot
Write-Banner

try {
    Write-Step 1 'Checking project and official Codex'
    Assert-Workspace -Root $root
    $codexPackage = Assert-OfficialCodexInstalled

    Write-Step 2 'Installing local dependencies'
    [void](Install-Dependencies -Root $root)

    Write-Step 3 'Configuring provider'
    [void](Ensure-ProviderConfig -Root $root)

    Write-Step 4 'Preparing Windows app gateway'
    Prepare-Launcher -Root $root

    if (-not $SkipShortcuts) {
        Write-Step 5 'Creating launch shortcuts'
        Install-Shortcuts -Root $root -CodexPackage $codexPackage
    } else {
        Write-Step 5 'Skipping shortcuts'
        Write-Warn 'Shortcut creation skipped by flag.'
    }

    if (-not $SkipVerify) {
        Write-Step 6 'Running shared-home verifier'
        Run-Verifier -Root $root
    } else {
        Write-Step 6 'Skipping verifier'
        Write-Warn 'Verifier skipped by flag.'
    }

    Write-Step 7 'Ready'
    Write-Host ''
    Write-Host '  Launch Codex OmniRoute from the Desktop or Start Menu shortcut.' -ForegroundColor Green
    Write-Host '  Official Codex remains available through the normal app and shortcut.' -ForegroundColor Green
    Write-Host ''
    Pause-IfInteractive
    exit 0
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    Pause-IfInteractive
    exit 1
}

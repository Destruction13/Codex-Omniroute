<#
.SYNOPSIS
    Repairs known mojibake-corrupted Codex config paths after a backup.

.DESCRIPTION
    A previous MCP normalization pass can explode non-ASCII Windows profile
    paths (for example C:\Users\Даня) into huge mojibake strings. That breaks
    MCP startup for servers such as magic and shadcn.

    This tool is intentionally conservative: it only rewrites config.toml when
    it detects the known corruption shape and a known-good backup config is
    available. The current config is copied to a timestamped backup before any
    write. Extra short project trust sections from the current config are
    preserved when possible.
#>

[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$KnownGoodBackup = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "[config-repair] $Message" }
}

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-TomlBlocks {
    param([Parameter(Mandatory = $true)][string]$Text)

    $blocks = New-Object System.Collections.Generic.List[object]
    $lines = $Text -split '\r?\n'
    $currentName = $null
    $currentLines = New-Object System.Collections.Generic.List[string]

    function Add-Block {
        param(
            [AllowNull()][string]$Name,
            [Parameter(Mandatory = $true)]$Lines
        )
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        $blocks.Add([pscustomobject]@{
            Name = $Name
            Key  = $Name.Trim().ToLowerInvariant()
            Text = (($Lines.ToArray()) -join "`r`n").Trim()
        })
    }

    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*\[(.+)\]\s*(?:#.*)?$')
        if ($match.Success) {
            Add-Block -Name $currentName -Lines $currentLines
            $currentName = $match.Groups[1].Value.Trim()
            $currentLines = New-Object System.Collections.Generic.List[string]
            $currentLines.Add($line)
            continue
        }
        if ($null -ne $currentName) {
            $currentLines.Add($line)
        }
    }
    Add-Block -Name $currentName -Lines $currentLines
    return $blocks
}

function Test-KnownMojibake {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text.Length -gt 100000) { return $true }
    # Avoid embedding mojibake byte soup in this script. The regression
    # reliably creates absurdly long C:\Users\<name>\... path segments.
    if ($Text -match 'C:[\\]{2}Users[\\]{2}[^"''\r\n]{200,}[\\]{2}AppData[\\]{2}Roaming[\\]{2}npm') { return $true }
    if ($Text -match 'C:[\\]Users[\\][^"''\r\n]{200,}[\\]AppData[\\]Roaming[\\]npm') { return $true }
    if ($Text -match 'C:[\\]Users[\\][^"''\r\n]{200,}[\\]\.cache[\\]codex-runtimes') { return $true }
    return $false
}

function Test-SafeProjectBlock {
    param([Parameter(Mandatory = $true)]$Block)
    if (-not $Block.Name.Trim().ToLowerInvariant().StartsWith('projects.', [System.StringComparison]::Ordinal)) {
        return $false
    }
    if ($Block.Text.Length -gt 2000) { return $false }
    if (Test-KnownMojibake -Text $Block.Text) { return $false }
    return $true
}

if (-not $CodexHome) {
    throw 'CodexHome is empty. Pass -CodexHome explicitly.'
}

$configPath = Join-Path $CodexHome 'config.toml'
if (-not $KnownGoodBackup) {
    $KnownGoodBackup = Join-Path $CodexHome 'config.before-mcp-normalize.20260501T043553.toml'
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Info "config.toml not found at $configPath; nothing to repair"
    exit 0
}

$current = Read-Text -Path $configPath
if (-not (Test-KnownMojibake -Text $current)) {
    Write-Info 'config.toml does not match the known mojibake corruption shape'
    exit 0
}

if (-not (Test-Path -LiteralPath $KnownGoodBackup)) {
    throw "Known-good backup not found: $KnownGoodBackup"
}

$backupText = Read-Text -Path $KnownGoodBackup
if (Test-KnownMojibake -Text $backupText) {
    # A valid UTF-8 backup can still render poorly in the console, but the
    # actual text should not contain the repeated mojibake markers above.
    throw "Known-good backup also appears corrupted: $KnownGoodBackup"
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$safetyBackup = Join-Path $CodexHome ("config.pre-omniroute-repair.{0}.toml" -f $stamp)
Copy-Item -LiteralPath $configPath -Destination $safetyBackup -Force
Write-Info "backed up current config.toml to $safetyBackup"

$baseBlocks = @{}
foreach ($block in @(Get-TomlBlocks -Text $backupText)) {
    $baseBlocks[$block.Key] = $true
}

$extraProjectBlocks = New-Object System.Collections.Generic.List[string]
foreach ($block in @(Get-TomlBlocks -Text $current)) {
    if (-not (Test-SafeProjectBlock -Block $block)) { continue }
    if ($baseBlocks.ContainsKey($block.Key)) { continue }
    $extraProjectBlocks.Add($block.Text)
}

$repaired = $backupText.TrimEnd() + "`r`n"
if ($extraProjectBlocks.Count -gt 0) {
    $repaired += "`r`n# Preserved short project trust sections from repaired config.toml`r`n"
    $repaired += (($extraProjectBlocks.ToArray()) -join "`r`n`r`n")
    $repaired += "`r`n"
}

Write-Text -Path $configPath -Text $repaired
Write-Info ("wrote repaired config.toml ({0} preserved project section(s))" -f $extraProjectBlocks.Count)

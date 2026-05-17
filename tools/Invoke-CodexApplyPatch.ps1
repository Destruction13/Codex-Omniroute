<#
.SYNOPSIS
    Applies a Codex apply_patch payload from a normal PowerShell session.

.DESCRIPTION
    Codex Desktop creates an apply_patch.bat wrapper that points at the
    Microsoft Store package resources under WindowsApps. That wrapper is only
    supported from an AppX-launched Codex child process. A normal shell cannot
    direct-launch those packaged resources and receives "Access is denied."

    This helper is the supported bare-shell fallback: it resolves the local
    Codex CLI installed under %LOCALAPPDATA%\OpenAI\Codex\bin (or a non-AppX
    codex.exe on PATH), reads the patch from an argument, PowerShell pipeline,
    or stdin, normalizes Windows drive-letter paths in patch headers, and
    passes the whole payload as one argument to codex.exe
    --codex-run-as-apply-patch.
#>

param(
    [string[]]$Patch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-LocalCodexCli {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'))
    }

    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $candidates.Add($cmd.Source)
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\') { continue }
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw "Could not find a launchable local codex.exe. Install or open the Microsoft Store Codex app once so %LOCALAPPDATA%\OpenAI\Codex\bin is populated."
}

function Convert-PatchHeaderPathsToForwardSlash {
    param([Parameter(Mandatory = $true)][string]$PatchText)

    $converted = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($PatchText -split '\r?\n', -1)) {
        $match = [regex]::Match($line, '^(\*\*\* (?:Add|Update|Delete) File: |\*\*\* Move to: )([A-Za-z]:\\.+)$')
        if ($match.Success) {
            $converted.Add($match.Groups[1].Value + $match.Groups[2].Value.Replace('\', '/'))
        } else {
            $converted.Add($line)
        }
    }
    return ($converted.ToArray() -join "`n")
}

function ConvertTo-NativeArgument {
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

function Invoke-NativeCodexApplyPatch {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExe,
        [Parameter(Mandatory = $true)][string]$PatchText
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $CodexExe
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = @(
        (ConvertTo-NativeArgument '--codex-run-as-apply-patch'),
        (ConvertTo-NativeArgument $PatchText)
    ) -join ' '

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if (-not [string]::IsNullOrEmpty($stdout)) { [Console]::Out.Write($stdout) }
    if (-not [string]::IsNullOrEmpty($stderr)) { [Console]::Error.Write($stderr) }
    return $proc.ExitCode
}

$patchText = ''
if ($Patch -and $Patch.Count -gt 0) {
    $patchText = ($Patch -join ' ')
} else {
    $patchText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrEmpty($patchText)) {
        # Direct .ps1 pipelines populate $input; batch/native callers provide stdin.
        $pipelineInput = @($input)
        if ($pipelineInput.Count -eq 1) {
            $patchText = [string]$pipelineInput[0]
        } elseif ($pipelineInput.Count -gt 1) {
            $patchText = (($pipelineInput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($patchText)) {
    throw "No patch payload supplied. Pass the patch as one argument, through the PowerShell pipeline, or on stdin."
}

$codexExe = Resolve-LocalCodexCli
$normalizedPatch = Convert-PatchHeaderPathsToForwardSlash -PatchText $patchText

$exitCode = Invoke-NativeCodexApplyPatch -CodexExe $codexExe -PatchText $normalizedPatch
exit $exitCode

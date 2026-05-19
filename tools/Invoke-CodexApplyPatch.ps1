<#
.SYNOPSIS
    Applies a Codex apply_patch payload from a normal PowerShell session.

.DESCRIPTION
    Legacy fallback for older Windows builds where native
    features.apply_patch_freeform is not enough. Codex Desktop can create an
    apply_patch.bat wrapper that points at the
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
    [string]$PatchFile = '',
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
    foreach ($line in ([regex]::Split($PatchText, '\r?\n'))) {
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

function Convert-PatchPathToNative {
    param([Parameter(Mandatory = $true)][string]$PathText)
    $text = $PathText.Trim()
    if ($text -match '^[A-Za-z]:/') {
        $text = $text.Replace('/', '\')
    }
    return [System.IO.Path]::GetFullPath($text)
}

function Find-Subsequence {
    param(
        [Parameter(Mandatory = $true)]$Haystack,
        [Parameter(Mandatory = $true)]$Needle,
        [int]$StartAt = 0
    )
    $hay = @($Haystack)
    $needleItems = @($Needle)
    if ($needleItems.Count -eq 0) { return [Math]::Min($StartAt, $hay.Count) }
    for ($i = [Math]::Max(0, $StartAt); $i -le ($hay.Count - $needleItems.Count); $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needleItems.Count; $j++) {
            if ([string]$hay[$i + $j] -ne [string]$needleItems[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    for ($i = 0; $i -lt [Math]::Max(0, $StartAt); $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needleItems.Count; $j++) {
            if ([string]$hay[$i + $j] -ne [string]$needleItems[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    return -1
}

function Apply-UpdateHunksDirect {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Hunks
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Failed to read file to update $Path"
    }
    $text = [System.IO.File]::ReadAllText($Path)
    $hasFinalNewline = $text.EndsWith("`n")
    $workText = $text -replace "`r`n", "`n"
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ([regex]::Split($workText, "`n"))) { [void]$lines.Add($line) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $cursor = 0
    foreach ($hunk in $Hunks) {
        $old = New-Object System.Collections.Generic.List[string]
        $new = New-Object System.Collections.Generic.List[string]
        foreach ($line in $hunk) {
            if ($line.Length -eq 0) { throw 'Invalid empty hunk line.' }
            $prefix = $line.Substring(0, 1)
            $body = if ($line.Length -gt 1) { $line.Substring(1) } else { '' }
            if ($prefix -eq ' ') {
                [void]$old.Add($body)
                [void]$new.Add($body)
            } elseif ($prefix -eq '-') {
                [void]$old.Add($body)
            } elseif ($prefix -eq '+') {
                [void]$new.Add($body)
            } elseif ($line -eq '\ No newline at end of file') {
                continue
            } else {
                throw "Unsupported hunk line: $line"
            }
        }
        $idx = Find-Subsequence -Haystack $lines.ToArray() -Needle $old.ToArray() -StartAt $cursor
        if ($idx -lt 0) {
            if ($env:CODEX_OMNI_APPLY_PATCH_DEBUG -eq '1') {
                [Console]::Error.WriteLine("DEBUG haystack=[$(($lines.ToArray() | ForEach-Object { '<' + $_ + '>' }) -join ',')]")
                [Console]::Error.WriteLine("DEBUG needle=[$(($old.ToArray() | ForEach-Object { '<' + $_ + '>' }) -join ',')]")
            }
            throw "Could not find hunk target in $Path"
        }
        $lines.RemoveRange($idx, $old.Count)
        $lines.InsertRange($idx, [string[]]$new.ToArray())
        $cursor = $idx + $new.Count
    }

    $out = ($lines.ToArray() -join "`n")
    if ($hasFinalNewline -or $out.Length -gt 0) { $out += "`n" }
    [System.IO.File]::WriteAllText($Path, $out, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-DirectApplyPatch {
    param([Parameter(Mandatory = $true)][string]$PatchText)

    $lines = @($PatchText -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    if ($lines.Count -lt 2 -or $lines[0] -ne '*** Begin Patch') {
        throw 'Patch must start with *** Begin Patch.'
    }

    $i = 1
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -eq '*** End Patch') { return }

        if ($line -match '^\*\*\* Add File: (.+)$') {
            $path = Convert-PatchPathToNative $Matches[1]
            $content = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\*\*\* ') {
                if (-not $lines[$i].StartsWith('+')) { throw "Invalid Add File line: $($lines[$i])" }
                [void]$content.Add($lines[$i].Substring(1))
                $i++
            }
            $parent = Split-Path -Parent $path
            if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [System.IO.File]::WriteAllText($path, (($content.ToArray() -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
            continue
        }

        if ($line -match '^\*\*\* Delete File: (.+)$') {
            $path = Convert-PatchPathToNative $Matches[1]
            Remove-Item -LiteralPath $path -Force
            $i++
            continue
        }

        if ($line -match '^\*\*\* Update File: (.+)$') {
            $path = Convert-PatchPathToNative $Matches[1]
            $moveTo = ''
            $hunks = New-Object System.Collections.ArrayList
            $i++
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\*\*\* (Add|Update|Delete) File: ' -and $lines[$i] -ne '*** End Patch') {
                if ($lines[$i] -match '^\*\*\* Move to: (.+)$') {
                    $moveTo = Convert-PatchPathToNative $Matches[1]
                    $i++
                    continue
                }
                if ($lines[$i] -match '^@@') {
                    $i++
                    $hunk = New-Object System.Collections.Generic.List[string]
                    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^@@' -and $lines[$i] -notmatch '^\*\*\* ') {
                        [void]$hunk.Add($lines[$i])
                        $i++
                    }
                    [void]$hunks.Add([string[]]$hunk.ToArray())
                    continue
                }
                throw "Unsupported update patch line: $($lines[$i])"
            }
            Apply-UpdateHunksDirect -Path $path -Hunks ([object[]]$hunks.ToArray())
            if ($moveTo) {
                $parent = Split-Path -Parent $moveTo
                if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Move-Item -LiteralPath $path -Destination $moveTo -Force
            }
            continue
        }

        throw "Unsupported patch operation: $line"
    }

    throw 'Patch ended before *** End Patch.'
}

$patchText = ''
if (-not [string]::IsNullOrWhiteSpace($PatchFile)) {
    $patchText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PatchFile))
} elseif ($Patch -and $Patch.Count -gt 0) {
    $patchText = ($Patch -join ' ')
} else {
    # Direct .ps1 pipelines populate $input. Native/batch callers usually
    # provide redirected stdin. Read $input first so an interactive console
    # does not block forever in Console.In.ReadToEnd().
    $pipelineInput = @($input)
    if ($pipelineInput.Count -eq 1) {
        $patchText = [string]$pipelineInput[0]
    } elseif ($pipelineInput.Count -gt 1) {
        $patchText = (($pipelineInput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    } elseif ([Console]::IsInputRedirected) {
        $patchText = [Console]::In.ReadToEnd()
    }
}

if ([string]::IsNullOrWhiteSpace($patchText)) {
    throw "No patch payload supplied. Pass the patch as one argument, through the PowerShell pipeline, or on stdin."
}

$normalizedPatch = Convert-PatchHeaderPathsToForwardSlash -PatchText $patchText

if ($env:CODEX_OMNI_FORCE_DIRECT_APPLY_PATCH -eq '1') {
    Invoke-DirectApplyPatch -PatchText $normalizedPatch
    exit 0
}

$codexExe = Resolve-LocalCodexCli
$exitCode = Invoke-NativeCodexApplyPatch -CodexExe $codexExe -PatchText $normalizedPatch
if ($exitCode -ne 0) {
    Write-Warning "native codex apply_patch failed with exit code $exitCode; trying direct local fallback"
    Invoke-DirectApplyPatch -PatchText $normalizedPatch
    exit 0
}
exit $exitCode

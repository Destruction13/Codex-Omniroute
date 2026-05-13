<#
.SYNOPSIS
    OmniRoute launcher: official Codex binary + isolated runtime home + local bridge.

.DESCRIPTION
    Reproduces the Codex OmniRoute architecture:

      1. Resolves the official Microsoft Store Codex package dynamically
         (Get-AppxPackage OpenAI.Codex) and launches its app\Codex.exe.
         The Store package itself is NEVER modified.

      2. Sets up a workspace-local isolated runtime home (default
         .codex-omniroute-home) and points HOME, USERPROFILE, APPDATA,
         LOCALAPPDATA, TEMP, TMP, CODEX_HOME, and
         CODEX_ELECTRON_USER_DATA_PATH inside it. This is what makes the
         OmniRoute fork a separate desktop persona while still being the
         same official binary.

      3. Seeds ONLY the minimal official Codex profile files needed for a
         logged-in feel: auth.json, models_cache.json, installation_id.
         Chats, sessions, thread DBs, logs, and other runtime state are
         NOT copied.

      4. Writes the isolated config.toml. This config:
           * inherits safe content from the user's official config.toml
             (notably [mcp_servers.*] entries) but strips conflicting
             provider/profile blocks;
           * pins model_provider = "omniroute_bridge",
                  model = "gpt-5.4",
                  model_reasoning_effort = "xhigh",
                  profile = "omniroute_managed";
           * defines [model_providers.omniroute_bridge] with
             base_url = "http://127.0.0.1:<bridge_port>/v1",
             wire_api = "responses",
             requires_openai_auth = true,
             supports_websockets = false;
           * marks the target project trusted.

      5. Starts codex-openai-omniroute-bridge.mjs on 127.0.0.1, with the
         bridge PID and log kept inside the workspace (NOT inside the
         isolated runtime home).

      6. Waits for the bridge's /healthz, then launches Codex.exe with the
         isolated environment.

    Official mode (Start-Codex-Official.ps1) remains a clean baseline:
    no OmniRoute env contamination, no helper processes.

.PARAMETER NoCodex
    Start the bridge and prepare the isolated runtime, but do NOT launch
    the Codex GUI. Used by verify-codex-omniroute.ps1 to perform a bounded
    "OmniRoute launch" without opening windows.

.PARAMETER Reset
    Delete the isolated runtime home before launching. Forces a fresh
    seed of auth.json, models_cache.json, installation_id, and config.toml.
    Persistent runtime history under the isolated home is lost.

.PARAMETER DryRun
    Print the planned environment and command without starting the bridge
    or launching Codex.

.PARAMETER BridgePort
    Preferred bridge port. The launcher will search nearby ports if this
    one is busy. Default 20333.

.PARAMETER RuntimeHome
    Path to the isolated runtime home. Default .codex-omniroute-home in
    the current working directory.

.NOTES
    Never writes to the global %USERPROFILE%\.codex\config.toml.
    Never writes to project-local .codex\config.toml.
    Never inlines OmniRoute or official secrets into the repo.
#>

[CmdletBinding()]
param(
    [switch]$NoCodex,
    [switch]$Reset,
    [switch]$DryRun,
    [int]$BridgePort = 20333,
    [string]$RuntimeHome = '.codex-omniroute-home',
    [string]$ProviderJson = './omniroute-provider.json',

    # Override the directory that auth.json / models_cache.json /
    # installation_id are seeded from when the isolated runtime home is
    # (re-)created. Default is the user's official Codex home
    # (%USERPROFILE%\.codex). Use this when the official profile is
    # currently bound to the wrong account: copy the desired account's
    # auth.json (and optionally models_cache.json / installation_id) into
    # any directory and point -AuthSource at it.
    [string]$AuthSource = '',

    # MCP stdio shield. Default ON: every inherited [mcp_servers.<name>]
    # entry gets routed through tools\mcp-stdio-shield.mjs, which drops any
    # non-JSON line on the child's stdout (taskkill SUCCESS messages,
    # cmd.exe banners, npm warnings) so the JSON-RPC transport cannot get
    # corrupted by Windows process-management noise. Pass
    # -NoSanitizeMcpStdout to disable and use the inherited commands raw
    # (only useful for debugging or for environments where the shield is
    # known not to be needed).
    #
    # The historical -SanitizeMcpStdout opt-in flag is preserved for
    # callers that pinned to it; both flags are accepted, but the new
    # default is "shield on".
    [switch]$NoSanitizeMcpStdout,
    [switch]$SanitizeMcpStdout,

    # Mirror %LOCALAPPDATA%\Microsoft\WindowsApps into the isolated
    # LOCALAPPDATA via a directory junction. This is what makes the
    # Microsoft Store AppX execution alias for Codex.exe (and any other
    # AppX-packaged tool the official Codex shells out to, e.g.
    # apply_patch.bat -> codex.exe --codex-run-as-apply-patch) keep
    # resolving even when the isolated runtime points LOCALAPPDATA at a
    # workspace-local directory. Default ON.
    [switch]$NoMirrorAppxAliases,

    # Apply patches via the in-process freeform-tool path instead of
    # spawning `codex.exe --codex-run-as-apply-patch` from the agent
    # shell. The shell-path requires the bundled codex.exe to be
    # invocable from a non-AppX child process, which fails with
    # "Access is denied" under any non-Start-menu launcher (this one
    # included). Switching to the freeform-tool path keeps patch
    # application entirely inside the already-running Codex Desktop
    # process, which already holds package identity, so the AppX
    # ACL constraint is never tripped.
    #
    # NB: the freeform-tool path requires the active model to support
    # custom tools with grammar (GPT-5 family). The launcher's managed
    # block defaults `model = "gpt-5.4"`, which qualifies. If you
    # override `model` to a non-GPT-5 model in this launcher's params or
    # in your inherited config, the freeform path silently falls back
    # to the shell-path and you will hit "Access is denied" again. Pass
    # -NoFreeformApplyPatch in that scenario to suppress the
    # experimental flag from the managed block.
    [switch]$NoFreeformApplyPatch,

    # Belt-and-suspenders fallback for the shell-path of apply_patch.
    # Codex Desktop, on first launch, copies its bundled CLI toolkit
    # (codex.exe, node.exe, rg.exe, codex-command-runner.exe, ...) into
    # %LOCALAPPDATA%\OpenAI\Codex\bin\. Those copies live OUTSIDE
    # WindowsApps and are therefore freely executable from any
    # non-AppX child process. The launcher prepends that directory to
    # Codex's PATH so that anywhere Codex (or its agent shells) resolve
    # `codex.exe` via PATH lookup -- most notably the apply_patch.bat
    # wrapper -- they hit the user-local copy first instead of the
    # WindowsApps one that triggers Access Denied.
    #
    # This is the only PATH override the launcher does. It is strictly
    # additive: the user's existing PATH is preserved unchanged after
    # the prepend, so no other tool gets shadowed. The added directory
    # is INSIDE our isolated runtime home so it cannot pollute outside.
    # Pass -NoLocalCodexBinPath to skip.
    [switch]$NoLocalCodexBinPath,

    # Run tools\apply_patch-rewriter.mjs as a long-lived daemon next to
    # the bridge. The daemon watches <CODEX_HOME>\tmp\arg0\ for
    # apply_patch.bat files Codex Desktop generates at session start
    # and rewrites their hardcoded `"C:\Program Files\WindowsApps\OpenAI.Codex\...\codex.exe"`
    # path to point at the user-local copy that lives outside WindowsApps
    # and is freely invocable from non-AppX child shells.
    #
    # This is the third (and most aggressive) line of defense against
    # the AppX containment failure mode of apply_patch.bat. The previous
    # two (freeform tool flag, PATH-prepended user-local Codex bin with
    # an apply_patch.bat shim) are both shadowed in the current Codex
    # builds: Codex picks the shell-path of apply_patch regardless of
    # the freeform flag, AND Codex prepends its session-tmp directory
    # ahead of our bin on the agent shell's PATH, so our shim is never
    # found first.
    #
    # The rewriter is opt-out via -NoApplyPatchRewriter. Disabling all
    # three defenses simultaneously means apply_patch will fail with
    # "Access is denied" inside the agent shell.
    [switch]$NoApplyPatchRewriter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Resolve-CodexAppx {
    # Returns a PSCustomObject with everything we need to launch the
    # official Microsoft Store Codex AppX:
    #   AumId       -- AppUserModelID (e.g. "OpenAI.Codex_2p2nqsd0c76g0!App")
    #   ExePath     -- absolute path to app\Codex.exe (legacy fallback,
    #                  used only when AppX activation is unavailable)
    #   InstallLoc  -- root of the AppX install
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw "Official Codex Microsoft Store app is not installed (Get-AppxPackage OpenAI.Codex returned nothing). Install it from the Microsoft Store first."
    }
    if ($pkg -is [array]) { $pkg = $pkg[0] }

    $candidates = @(
        (Join-Path $pkg.InstallLocation 'app\Codex.exe'),
        (Join-Path $pkg.InstallLocation 'Codex.exe')
    )
    $exe = $null
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $exe = $c; break } }
    if (-not $exe) {
        throw "Found Codex package at '$($pkg.InstallLocation)' but could not locate Codex.exe."
    }

    # AppUserModelID is "<PackageFamilyName>!<ApplicationId>". The
    # ApplicationId comes from the AppxManifest.xml <Application Id="..."/>
    # node; for OpenAI.Codex it is "App".
    $appId = 'App'
    try {
        $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifestPath) {
            [xml]$m = Get-Content -LiteralPath $manifestPath -Raw
            $appNode = $m.Package.Applications.Application
            if ($appNode -and $appNode.Id) { $appId = $appNode.Id }
        }
    } catch { }
    $aumId = "$($pkg.PackageFamilyName)!$appId"

    return [pscustomobject]@{
        AumId      = $aumId
        ExePath    = $exe
        InstallLoc = $pkg.InstallLocation
        Package    = $pkg
    }
}

function Resolve-CodexExecutable {
    # Backwards-compat shim: any caller that still expects an absolute path
    # to Codex.exe gets it. New launch path uses Start-CodexViaAppx instead.
    return (Resolve-CodexAppx).ExePath
}

# NOTE: this launcher does NOT use IApplicationActivationManager (AppX
# activation) to launch Codex.exe even though the AppUserModelID is
# available. There is a fundamental tradeoff:
#
#   * Start-Process Codex.exe       -- our isolated env (USERPROFILE,
#                                      CODEX_HOME, APPDATA, etc.) is
#                                      inherited correctly by Codex, so the
#                                      isolated runtime's config.toml is
#                                      what Codex reads. BUT Codex.exe runs
#                                      without a propagated AppX activation
#                                      context, so child shells it spawns
#                                      cannot re-invoke its bundled
#                                      codex.exe (used by apply_patch.bat)
#                                      and that path fails with
#                                      "Access is denied".
#
#   * IApplicationActivationManager -- Codex runs with full AppX package
#                                      identity, so apply_patch and other
#                                      Codex-internal shell-out chains
#                                      work. BUT the AppX broker creates
#                                      the activated process from a clean
#                                      environment block, so our isolated
#                                      USERPROFILE/CODEX_HOME overrides are
#                                      silently DROPPED. Codex then reads
#                                      the user's global %USERPROFILE%\.codex
#                                      and the OmniRoute provider config
#                                      never takes effect -- inference
#                                      escapes the bridge.
#
#   * CreateProcess with PROC_THREAD_ATTRIBUTE_PACKAGE_FULL_NAME -- in
#                                      principle gives both isolated env
#                                      AND package identity, but Windows
#                                      restricts use of that attribute to
#                                      processes that already hold the
#                                      target package's identity (or to
#                                      the system AppX broker), so it
#                                      fails for a regular launcher with
#                                      ERROR_BAD_LENGTH (24).
#
# Env isolation is the foundational invariant of OmniRoute mode. Without
# it, the launcher's whole point (rerouting inference through the local
# bridge while pretending to be a normal Codex session) collapses. So we
# choose Start-Process and accept that Codex's apply_patch.bat -> codex.exe
# chain may fail with "Access is denied" inside the agent shell. This is
# the same failure mode any non-AppX-activated Codex launch hits (e.g. ssh
# remote, scheduled task, docker-shell, Linux WSL invoking Codex via
# its EntryPoint). It is a pre-existing Codex AppX-packaging limitation
# and is documented in GUIDE.md.

# NOTE: this launcher intentionally does NOT shim git.exe.
#
# Earlier revisions injected a custom C#-built git shim into PATH ahead of the
# user's real git, in order to massage `git rev-parse --verify --quiet
# refs/remotes/<remote>/<branch>` fallbacks. That violated the project goal
# that the only meaningful behavior difference between OmniRoute mode and
# official mode is the inference routing through the local bridge. Anything
# that rewrites the semantics of a base CLI tool the official Codex binary
# uses is, by construction, a non-upstream divergence.
#
# Codex now sees the user's real git on PATH unchanged. If any specific git
# behavior is needed, the right place to fix it is upstream Codex or in the
# user's git config -- not in this launcher.
function Get-OfficialCodexHome {
    return (Join-Path $env:USERPROFILE '.codex')
}

function Test-PortFree {
    param([int]$Port)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Find-FreePort {
    param([int]$Preferred, [int]$Range = 50)
    for ($p = $Preferred; $p -lt $Preferred + $Range; $p++) {
        if (Test-PortFree -Port $p) { return $p }
    }
    throw "No free port found in range [$Preferred, $($Preferred + $Range))."
}

function New-IsolatedRuntimeHome {
    param([string]$Root, [switch]$Reset)

    # Absolutize the runtime home root. The default is a relative path like
    # '.codex-omniroute-home' -- Resolve-Path -LiteralPath '' would be a
    # parameter-binding error (not suppressible by -ErrorAction), so we build
    # the absolute path ourselves rather than going through Split-Path.
    $full = if ([System.IO.Path]::IsPathRooted($Root)) {
        $Root
    } else {
        Join-Path (Get-Location).Path $Root
    }

    if ($Reset -and (Test-Path -LiteralPath $full)) {
        Write-Host "[omniroute] reset: removing $full"
        Remove-Item -LiteralPath $full -Recurse -Force
    }

    # Windows-consistent layout: APPDATA / LOCALAPPDATA / TEMP all sit *under*
    # the isolated USERPROFILE, the way they do on a real machine. Codex's
    # Electron shell expects APPDATA == USERPROFILE\AppData\Roaming; splitting
    # them across siblings tends to make the GUI exit silently.
    $profileRoot   = Join-Path $full 'profile'
    $appDataRoot   = Join-Path $profileRoot 'AppData\Roaming'
    $localAppRoot  = Join-Path $profileRoot 'AppData\Local'
    $tempRoot      = Join-Path $localAppRoot 'Temp'
    $codexHomeRoot = Join-Path $full 'codex'
    $electronData  = Join-Path $localAppRoot 'OpenAI\Codex-OmniRoute'

    foreach ($d in @($full, $profileRoot, $appDataRoot, $localAppRoot, $tempRoot, $codexHomeRoot, $electronData)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    return [pscustomobject]@{
        Root         = $full
        Home         = $profileRoot
        AppData      = $appDataRoot
        LocalApp     = $localAppRoot
        Temp         = $tempRoot
        CodexHome    = $codexHomeRoot
        ElectronData = $electronData
    }
}

function Copy-MinimalSeed {
    param(
        [string]$OfficialHome,
        [string]$IsolatedCodexHome,
        [string]$AuthSource = ''
    )

    # Determine which directory we seed from for each individual file.
    # auth.json *must* come from the explicit AuthSource (when provided),
    # since that is the whole point of the override. models_cache.json and
    # installation_id can fall back to OfficialHome if AuthSource doesn't
    # contain them, because those two files are not account-bound: the
    # models cache is just a denormalized server response and the
    # installation_id is per-machine.
    $authSrc        = $null
    $modelsSrc      = $null
    $installIdSrc   = $null

    if ($AuthSource) {
        if (-not (Test-Path -LiteralPath $AuthSource)) {
            throw "[omniroute] -AuthSource path not found: $AuthSource"
        }
        $resolvedAuthSource = (Resolve-Path -LiteralPath $AuthSource).Path
        $authJsonInSource = Join-Path $resolvedAuthSource 'auth.json'
        if (-not (Test-Path -LiteralPath $authJsonInSource)) {
            throw "[omniroute] -AuthSource '$resolvedAuthSource' does not contain auth.json"
        }
        $authSrc = $authJsonInSource
        $candModels    = Join-Path $resolvedAuthSource 'models_cache.json'
        $candInstallId = Join-Path $resolvedAuthSource 'installation_id'
        if (Test-Path -LiteralPath $candModels)    { $modelsSrc    = $candModels }
        if (Test-Path -LiteralPath $candInstallId) { $installIdSrc = $candInstallId }
        Write-Host "[omniroute] auth source override: $resolvedAuthSource"
    } elseif (Test-Path -LiteralPath $OfficialHome) {
        $authSrc      = Join-Path $OfficialHome 'auth.json'
        $modelsSrc    = Join-Path $OfficialHome 'models_cache.json'
        $installIdSrc = Join-Path $OfficialHome 'installation_id'
    } else {
        Write-Warning "[omniroute] official Codex home '$OfficialHome' not found and no -AuthSource set; cannot seed auth.json / models_cache.json."
        return
    }

    # Fall back to OfficialHome for any of the secondary files that aren't
    # next to the override auth.json.
    if ($AuthSource -and (Test-Path -LiteralPath $OfficialHome)) {
        if (-not $modelsSrc) {
            $cand = Join-Path $OfficialHome 'models_cache.json'
            if (Test-Path -LiteralPath $cand) { $modelsSrc = $cand }
        }
        if (-not $installIdSrc) {
            $cand = Join-Path $OfficialHome 'installation_id'
            if (Test-Path -LiteralPath $cand) { $installIdSrc = $cand }
        }
    }

    $plan = @(
        @{ Name = 'auth.json';         Src = $authSrc;      Required = $true  },
        @{ Name = 'models_cache.json'; Src = $modelsSrc;    Required = $false },
        @{ Name = 'installation_id';   Src = $installIdSrc; Required = $false }
    )
    foreach ($entry in $plan) {
        $f = $entry.Name
        $src = $entry.Src
        $dst = Join-Path $IsolatedCodexHome $f
        if (-not $src -or -not (Test-Path -LiteralPath $src)) {
            if ($entry.Required) {
                Write-Warning "[omniroute] $f source missing; isolated runtime will behave as logged-out."
            } else {
                Write-Host "[omniroute] $f source missing; skipping (optional)."
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host "[omniroute] seeded $f from $src"
        } else {
            Write-Host "[omniroute] $f already present in isolated runtime; not overwriting"
        }
    }
}

$script:OmniManagedBegin = '# BEGIN CODEX OMNIROUTE MANAGED'
$script:OmniManagedEnd   = '# END CODEX OMNIROUTE MANAGED'

# Allowlist of inherited TOML section *prefixes*. Anything not on this list is
# dropped from the inherited content, so the isolated runtime never picks up
# the user's marketplaces, plugins, projects, windows.sandbox, or other
# dynamic / machine-specific state that points back at the global Codex home.
#
# We deliberately keep this list as small as we can while still making the
# isolated profile feel logged-in:
#   - mcp_servers.*  -> the user's MCP set should appear in OmniRoute mode too
# Everything else (marketplaces, plugins, projects, windows, model_providers,
# profiles, top-level model/profile keys) is owned by either Codex itself
# (it bootstraps marketplaces/plugins on first run inside the isolated home)
# or by this launcher (it writes the model_provider / profile / projects.<ws>
# managed block).
$script:InheritAllowedSectionPrefixes = @(
    'mcp_servers.'
)

# Section *prefixes* that must NEVER be inherited from the global config.
# This is enforced even if a future allowlist entry would otherwise match,
# and the verifier asserts the same set against the produced isolated config.
$script:InheritDeniedSectionPrefixes = @(
    'marketplaces.',
    'marketplaces',  # bare [marketplaces]
    'plugins.',
    'plugins',
    'projects.',
    'projects',
    'windows',
    'model_providers.',
    'profiles.'
)

function Test-InheritAllowedSection {
    param([string]$Section)
    if ([string]::IsNullOrEmpty($Section)) { return $false }
    foreach ($denied in $script:InheritDeniedSectionPrefixes) {
        if ($Section -eq $denied -or $Section.StartsWith($denied)) { return $false }
    }
    foreach ($allowed in $script:InheritAllowedSectionPrefixes) {
        if ($Section -eq $allowed.TrimEnd('.') -or $Section.StartsWith($allowed)) { return $true }
    }
    return $false
}

function Sanitize-OfficialConfig {
    param([string]$OfficialConfigPath)

    # Returns the cleaned official config content (string) restricted to the
    # inheritance allowlist (mcp_servers.* by default). We intentionally do
    # NOT parse TOML here -- we strip on a block basis. Any line outside an
    # allowed section header is dropped, including bare top-level scalars
    # like `model = "gpt-5.5"` from the user's official config.
    #
    # IMPORTANT: the returned text MUST NOT contain bare top-level scalar
    # assignments at the bottom of an open `[table]`. Otherwise, when this
    # text is concatenated with the OmniRoute managed block, the managed
    # block's bare scalars (model_provider, model, model_reasoning_effort,
    # profile) get absorbed into whatever table was last opened in the
    # inherited content (e.g. `[mcp_servers.ref-tools]`) instead of being
    # parsed as top-level keys. The launcher already mitigates that by
    # writing the OmniRoute managed block FIRST, but we keep the allowlist
    # strict so future changes can't reintroduce that hazard.
    if (-not (Test-Path -LiteralPath $OfficialConfigPath)) { return '' }

    # IMPORTANT: read as UTF-8 explicitly. The user's official config.toml is
    # UTF-8 (sometimes with BOM). Windows PowerShell 5.1's default Get-Content
    # encoding follows the active code page, so on Russian/CJK/etc. locales it
    # silently mojibakes any non-ASCII byte (e.g. Cyrillic "Даня" appears as
    # "Р”Р°РЅСЏ" once round-tripped through CP1251). That mojibake then ends
    # up in the isolated config's MCP command paths, breaking MCP server
    # discovery for any user with non-ASCII characters in their profile path.
    # [System.IO.File]::ReadAllText with the no-BOM UTF-8 instance correctly
    # auto-detects the BOM if present and treats the rest as UTF-8 either way.
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($true)
        $raw = [System.IO.File]::ReadAllText($OfficialConfigPath, $utf8)
    } catch {
        return ''
    }
    if (-not $raw) { return '' }

    # First pass: drop any previously-written managed block. This handles the
    # case where someone (a previous launcher version, SuperCodex's launcher,
    # or a manual edit) left a managed block inside the *official* config.
    $raw = [regex]::Replace(
        $raw,
        '(?ms)^# BEGIN CODEX OMNIROUTE (MANAGED|ISOLATED)\r?\n.*?^# END CODEX OMNIROUTE (MANAGED|ISOLATED)\s*(?:\r?\n)?',
        ''
    )
    $raw = [regex]::Replace(
        $raw,
        '(?ms)^# --- Codex OmniRoute managed.*?# --- end Codex OmniRoute managed ---\s*(?:\r?\n)?',
        ''
    )

    $lines = $raw -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]

    # State machine: we keep lines only while we are inside an allowed section.
    # Bare top-level lines (no preceding section header in this scan) are
    # dropped, because we own all top-level keys.
    $inAllowedSection = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        $headerMatch = [regex]::Match($trim, '^\[\s*([A-Za-z0-9_.\-]+(?:\."[^"]*")?(?:\.[A-Za-z0-9_.\-]+)*)\s*\]')
        if ($headerMatch.Success) {
            $section = $headerMatch.Groups[1].Value
            $inAllowedSection = (Test-InheritAllowedSection -Section $section)
            if ($inAllowedSection) { $out.Add($line) }
            continue
        }

        # Quoted-key sections like [projects.'C:\path'] don't match the simple
        # header regex above. Detect those explicitly and treat them as
        # NEVER allowed -- the only project we trust is the workspace, which
        # the managed block already adds.
        if ($trim.StartsWith('[')) {
            $inAllowedSection = $false
            continue
        }

        if ($inAllowedSection) { $out.Add($line) }
        # else: drop (bare top-level scalar, comment, or blank line outside
        # any allowed section).
    }
    return ($out -join "`n").Trim()
}

function ConvertTo-TomlString {
    # Quote a string as a TOML basic string. Backslashes and double quotes
    # are escaped; everything else is passed through. Returns the value
    # WITHOUT the surrounding double quotes.
    #
    # NOTE: PowerShell's -replace uses regex on the pattern AND the
    # replacement string. We use the .Replace() instance method on
    # [string] instead, which is plain substring replace (no regex, no
    # weird substitution metacharacters), so:
    #   "C:\foo".Replace('\', '\\')   -> "C:\\foo"     (1 backslash -> 2)
    # which is exactly what TOML wants. -replace would interpret '\\'
    # in the replacement as 2 literal characters, doubling the count
    # again (4) and producing a malformed TOML path.
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return $escaped
}

function ConvertTo-TomlArrayLiteral {
    # Render a list of strings as a TOML array literal: ["a", "b", "c"].
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '[]' }
    $parts = foreach ($it in $Items) { '"' + (ConvertTo-TomlString $it) + '"' }
    return '[' + ($parts -join ', ') + ']'
}

function Get-TomlEscapedChar {
    # Helper: given the second char of an escape sequence, return the
    # decoded character. Returns $null for unknown escape (caller decides
    # whether to keep the backslash literal).
    param([char]$Second)
    switch ($Second) {
        ([char]'\') { return [char]'\' }
        ([char]'"') { return [char]'"' }
        ([char]'n') { return "`n" }
        ([char]'r') { return "`r" }
        ([char]'t') { return "`t" }
        default     { return $null }
    }
}

function ConvertFrom-TomlBasicString {
    # Decode the *inner* contents of a TOML basic string -- i.e. everything
    # between the surrounding double quotes. Caller is responsible for
    # stripping the quotes. Handles \\, \", \n, \r, \t escapes; unknown
    # escapes pass through with the backslash preserved.
    #
    # NOTE: in PowerShell single-quoted strings, '\\' is two literal chars
    # ("\" + "\"), NOT one. That means `$c -eq '\\'` (where $c is a single
    # [char]) is always false, which silently turned an earlier version of
    # this decoder into a no-op. We compare against [char]'\' instead, and
    # we restructure the loop to avoid the infamous switch+continue
    # ambiguity in PS 5.1 (`continue` inside `switch` does not always
    # return to the enclosing while loop the way callers might expect).
    param([string]$Inner)
    if ([string]::IsNullOrEmpty($Inner)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $bs = [char]'\'
    $i = 0
    while ($i -lt $Inner.Length) {
        $c = $Inner[$i]
        if ($c -eq $bs -and ($i + 1) -lt $Inner.Length) {
            $decoded = Get-TomlEscapedChar -Second $Inner[$i + 1]
            if ($null -ne $decoded) {
                [void]$sb.Append($decoded)
                $i += 2
                continue
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function ConvertFrom-TomlStringLiteral {
    # Decode a quoted TOML basic-string token (with the surrounding double
    # quotes still attached). Returns $null if input isn't a properly-
    # quoted scalar.
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return $null }
    $t = $Token.Trim()
    if (-not ($t.StartsWith('"') -and $t.EndsWith('"'))) { return $null }
    $inner = $t.Substring(1, $t.Length - 2)
    return (ConvertFrom-TomlBasicString -Inner $inner)
}

function ConvertFrom-TomlInlineArray {
    # Tiny parser for a single-line TOML array of strings:
    #   ["a", "b\\c", "d"]
    # Returns [string[]] of decoded values, or $null if input is not a
    # well-formed inline array of strings.
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return $null }
    $t = $Token.Trim()
    if (-not ($t.StartsWith('[') -and $t.EndsWith(']'))) { return $null }
    $inner = $t.Substring(1, $t.Length - 2).Trim()
    if ($inner.Length -eq 0) { return @() }

    $bs = [char]'\'
    $items = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $inner.Length) {
        # Skip whitespace and commas between items.
        while ($i -lt $inner.Length -and ($inner[$i] -eq ' ' -or $inner[$i] -eq "`t" -or $inner[$i] -eq ',')) { $i++ }
        if ($i -ge $inner.Length) { break }
        if ($inner[$i] -ne '"') { return $null }
        $i++
        # Find the matching closing quote, respecting backslash escapes.
        $start = $i
        while ($i -lt $inner.Length) {
            $c = $inner[$i]
            if ($c -eq $bs -and ($i + 1) -lt $inner.Length) {
                $i += 2
                continue
            }
            if ($c -eq '"') { break }
            $i++
        }
        if ($i -ge $inner.Length -or $inner[$i] -ne '"') { return $null }
        $rawInner = $inner.Substring($start, $i - $start)
        $items.Add((ConvertFrom-TomlBasicString -Inner $rawInner))
        $i++  # consume closing quote
    }
    return ,$items.ToArray()
}

function Invoke-McpStdoutShieldRewrite {
    # Walk an already-sanitized inherited TOML content (produced by
    # Sanitize-OfficialConfig, so contains only mcp_servers.* sections)
    # and rewrite each top-level [mcp_servers.<name>] section so that its
    # command/args route through tools/mcp-stdio-shield.mjs. Sub-tables
    # like [mcp_servers.<name>.env] are left untouched.
    #
    # Returns the rewritten TOML text. Conservative: if a section's
    # command or args don't look like simple TOML strings we recognize, we
    # leave that section untouched and emit a warning.
    param(
        [string]$InheritedToml,
        [string]$NodeExe,
        [string]$ShieldScript
    )

    if ([string]::IsNullOrEmpty($InheritedToml)) { return $InheritedToml }
    if (-not $NodeExe -or -not (Test-Path -LiteralPath $NodeExe)) {
        Write-Warning "[omniroute] -SanitizeMcpStdout: node.exe not resolved; leaving MCP commands unwrapped."
        return $InheritedToml
    }
    if (-not $ShieldScript -or -not (Test-Path -LiteralPath $ShieldScript)) {
        Write-Warning "[omniroute] -SanitizeMcpStdout: shield script not found at $ShieldScript; leaving MCP commands unwrapped."
        return $InheritedToml
    }

    $lines = $InheritedToml -split "`r?`n"
    # Pass 1: identify section ranges. A "section range" is the inclusive
    # line index pair [start, end] for a top-level [mcp_servers.<name>]
    # section, NOT extending into any sub-table that follows it.
    $ranges = New-Object System.Collections.Generic.List[object]
    $current = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trim = $lines[$i].Trim()
        $h = [regex]::Match($trim, '^\[\s*([A-Za-z0-9_.\-]+(?:\."[^"]*")?(?:\.[A-Za-z0-9_.\-]+)*)\s*\]')
        if (-not $h.Success) { continue }
        $section = $h.Groups[1].Value

        # Top-level mcp server: matches mcp_servers.<single-segment> exactly.
        $isTop = ($section -match '^mcp_servers\.[^."]+$') -or
                 ($section -match '^mcp_servers\."[^"]+"$')
        # Close the previous section.
        if ($current) {
            $current.End = $i - 1
            $ranges.Add($current) | Out-Null
            $current = $null
        }
        if ($isTop) {
            $current = [pscustomobject]@{ Section = $section; Start = $i; End = $lines.Count - 1 }
        }
    }
    if ($current) {
        $ranges.Add($current) | Out-Null
    }

    if ($ranges.Count -eq 0) { return $InheritedToml }

    # Pass 2: for each range, parse command/args and rewrite.
    $shieldEscaped = (ConvertTo-TomlString $ShieldScript)
    $nodeEscaped   = (ConvertTo-TomlString $NodeExe)

    # Build a mutable copy of lines so we can replace command / args lines.
    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $newLines.Add($l) }

    foreach ($range in $ranges) {
        $cmdLineIdx  = -1
        $argsLineIdx = -1
        $cmdValue  = $null
        $argsValue = $null

        for ($k = $range.Start + 1; $k -le $range.End -and $k -lt $newLines.Count; $k++) {
            $raw = $newLines[$k]
            $trim = $raw.Trim()
            if ($trim.StartsWith('#') -or $trim.Length -eq 0) { continue }
            $kv = [regex]::Match($trim, '^([A-Za-z0-9_\-]+)\s*=\s*(.+)$')
            if (-not $kv.Success) { continue }
            $key = $kv.Groups[1].Value
            $valTok = $kv.Groups[2].Value
            switch ($key) {
                'command' {
                    $cmdLineIdx = $k
                    $cmdValue = ConvertFrom-TomlStringLiteral $valTok
                }
                'args' {
                    $argsLineIdx = $k
                    $argsValue = ConvertFrom-TomlInlineArray $valTok
                }
            }
        }

        if ($cmdLineIdx -lt 0 -or [string]::IsNullOrEmpty($cmdValue)) {
            # url-based MCP, or unparseable command. Leave as-is.
            continue
        }

        # Build the new args = [shield_script, original_command, ...original_args]
        $origArgs = @()
        if ($null -ne $argsValue) { $origArgs = $argsValue }
        $newArgs = @($ShieldScript, $cmdValue) + $origArgs

        $indent = [regex]::Match($newLines[$cmdLineIdx], '^\s*').Value
        $newCmdLine = "${indent}command = `"$nodeEscaped`""
        $newArgsLine = "${indent}args = " + (ConvertTo-TomlArrayLiteral $newArgs)

        $newLines[$cmdLineIdx] = $newCmdLine
        if ($argsLineIdx -ge 0) {
            $newLines[$argsLineIdx] = $newArgsLine
        } else {
            # No args line was present; insert one immediately after command.
            $newLines.Insert($cmdLineIdx + 1, $newArgsLine)
            # Adjust subsequent ranges that reference indices past this insert.
            foreach ($r in $ranges) {
                if ($r.Start -gt $cmdLineIdx) { $r.Start++ }
                if ($r.End -ge $cmdLineIdx)   { $r.End++ }
            }
        }
    }

    return ($newLines -join "`n")
}

function Write-IsolatedConfig {
    param(
        [string]$IsolatedConfigPath,
        [string]$OfficialConfigPath,
        [int]$BridgePort,
        [string]$ProjectPath,
        [bool]$SanitizeMcp = $false,
        [string]$NodeExe = '',
        [string]$ShieldScript = '',
        [bool]$FreeformApplyPatch = $true
    )

    $inherited = Sanitize-OfficialConfig -OfficialConfigPath $OfficialConfigPath
    if ($SanitizeMcp -and $inherited) {
        $inherited = Invoke-McpStdoutShieldRewrite `
            -InheritedToml $inherited `
            -NodeExe $NodeExe `
            -ShieldScript $ShieldScript
    }

    $projectEscaped = $ProjectPath.Replace('\', '\\')

    # The freeform-tool path applies patches in-process inside the running
    # Codex Desktop instead of spawning `codex.exe --codex-run-as-apply-patch`
    # from the agent shell. Spawn-path fails with "Access is denied" under
    # any non-Start-menu launch (the AppX package identity does not
    # propagate to grand-children), so freeform is the workaround. Codex
    # 26.506.x supports the flag; binary scan in the verifier confirms it.
    #
    # The flag is written in FOUR places. Codex's config schema (per binary
    # scan of the bundled agent CLI) exposes the flag at:
    #   - bare top-level                            (Config struct)
    #   - inside `[features]`                       (top-level Features struct)
    #   - inside `[profiles.<name>]`                (Profile struct, direct field)
    #   - inside `[profiles.<name>.features]`       (per-profile Features sub-table)
    # Empirically a single placement does not always activate the freeform
    # tool -- the per-profile-features sub-table is what `profile_toml.rs`
    # actually parses. Writing in all four locations is harmless
    # redundancy and guarantees whichever placement Codex's parser
    # consults is satisfied.
    $freeformTopLevel   = if ($FreeformApplyPatch) { 'experimental_use_freeform_apply_patch = true' } else { '# experimental_use_freeform_apply_patch = false (disabled by -NoFreeformApplyPatch)' }
    $freeformFeatures   = if ($FreeformApplyPatch) { "[features]`nexperimental_use_freeform_apply_patch = true`n" } else { '' }
    $freeformInProfile  = if ($FreeformApplyPatch) { 'experimental_use_freeform_apply_patch = true' } else { '# experimental_use_freeform_apply_patch suppressed' }
    $freeformProfFeats  = if ($FreeformApplyPatch) { "`n[profiles.omniroute_managed.features]`nexperimental_use_freeform_apply_patch = true`n" } else { '' }

    # Order matters here. The managed block ships its bare top-level scalars
    # FIRST so they land at the top of the file, before any [table] header.
    # Putting them after the inherited content would let TOML's parser absorb
    # them into the LAST opened table from inherited content
    # (e.g. `[mcp_servers.ref-tools]`), turning them into
    # `mcp_servers.ref-tools.model_provider = "omniroute_bridge"` rather than
    # the actual top-level routing key. That is exactly how the launcher used
    # to silently route reasoning through the built-in OpenAI provider while
    # the file *looked* like it was OmniRoute-bound.
    $omniBlock = @"
$($script:OmniManagedBegin)
model_provider = "omniroute_bridge"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"
profile = "omniroute_managed"
$freeformTopLevel

$freeformFeatures
[model_providers.omniroute_bridge]
name = "OmniRoute Bridge"
base_url = "http://127.0.0.1:$BridgePort/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false

[profiles.omniroute_managed]
model_provider = "omniroute_bridge"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"
$freeformInProfile
$freeformProfFeats
[projects."$projectEscaped"]
trust_level = "trusted"
$($script:OmniManagedEnd)
"@

    $body = @()
    $body += $omniBlock
    if ($inherited) {
        $body += ''
        $body += '# Inherited from official Codex config (provider/profile blocks stripped).'
        $body += $inherited
    }

    $final = ($body -join "`n") + "`n"
    # Write UTF-8 without a BOM. Set-Content -Encoding UTF8 writes a BOM in
    # Windows PowerShell 5.1, which the official Codex TOML loader has been
    # observed to choke on intermittently. WriteAllText with an explicit
    # non-BOM UTF8Encoding instance is BOM-free across PS 5.1 and PS 7+.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($IsolatedConfigPath, $final, $utf8NoBom)
}

function Wait-ForBridgeHealth {
    # NOTE: do not name a param $Host -- $Host is a PowerShell automatic variable.
    param([string]$BridgeHost, [int]$Port, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $url = "http://{0}:{1}/healthz" -f $BridgeHost, $Port
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri $url -TimeoutSec 2 -ErrorAction Stop
            if ($resp.ok) { return $resp }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    throw ("Bridge /healthz did not respond within {0}s on {1}" -f $TimeoutSec, $url)
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

# $workspace is the project root the user is operating in -- the cwd at
# launcher invocation time. Codex Desktop's --open-project arg should point
# at this dir, runtime home and bridge.log are workspace-local, etc.
$workspace = (Get-Location).Path

# The bridge script lives next to THIS launcher script. Anchor on
# $PSScriptRoot so the launcher works even when invoked from a subdir of
# the project (or from outside it via an absolute path).
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $scriptRoot) { $scriptRoot = $workspace }
$bridgeScript = Join-Path $scriptRoot 'codex-openai-omniroute-bridge.mjs'
if (-not (Test-Path -LiteralPath $bridgeScript)) {
    # Backwards compat: if the launcher is being run from a copy that has
    # the bridge alongside in the cwd but not next to the script (rare),
    # fall back to workspace-relative resolution.
    $altBridge = Join-Path $workspace 'codex-openai-omniroute-bridge.mjs'
    if (Test-Path -LiteralPath $altBridge) {
        $bridgeScript = $altBridge
    } else {
        throw "Bridge script not found: $bridgeScript"
    }
}

$exe = Resolve-CodexExecutable
$officialHome = Get-OfficialCodexHome
$officialConfig = Join-Path $officialHome 'config.toml'

$runtime = New-IsolatedRuntimeHome -Root $RuntimeHome -Reset:$Reset
Copy-MinimalSeed `
    -OfficialHome $officialHome `
    -IsolatedCodexHome $runtime.CodexHome `
    -AuthSource $AuthSource

# Mirror the user's real Microsoft Store AppX execution-alias directory into
# the isolated LOCALAPPDATA. Without this, anything that resolves
# %LOCALAPPDATA%\Microsoft\WindowsApps\<app>.exe (most notably Codex's own
# apply_patch.bat -> codex.exe shim used for code edits) fails with
# "Access is denied" because the alias only exists in the user's real
# LOCALAPPDATA, not in the isolated one.
if (-not $NoMirrorAppxAliases) {
    $realLocalApp = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $realLocalApp) { $realLocalApp = $env:LOCALAPPDATA }
    if ($realLocalApp) {
        $realAppxDir   = Join-Path $realLocalApp 'Microsoft\WindowsApps'
        $isoMicrosoft  = Join-Path $runtime.LocalApp 'Microsoft'
        $isoAppxDir    = Join-Path $runtime.LocalApp 'Microsoft\WindowsApps'
        if (Test-Path -LiteralPath $realAppxDir) {
            try {
                if (-not (Test-Path -LiteralPath $isoMicrosoft)) {
                    New-Item -ItemType Directory -Path $isoMicrosoft -Force | Out-Null
                }
                # Skip if the junction is already in place and points at the
                # real dir. PS 5.1 can't easily inspect reparse-point targets
                # without P/Invoke, so we just check that the path exists and
                # contains a known alias (codex.exe).
                $alreadyMirrored = (Test-Path -LiteralPath (Join-Path $isoAppxDir 'codex.exe'))
                if (-not $alreadyMirrored) {
                    if (Test-Path -LiteralPath $isoAppxDir) {
                        # Stale empty dir from a previous launch -- replace it.
                        Remove-Item -LiteralPath $isoAppxDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    & cmd.exe /c mklink /J "$isoAppxDir" "$realAppxDir" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $isoAppxDir)) {
                        Write-Warning "[omniroute] could not junction $isoAppxDir -> $realAppxDir; apply_patch.bat may fail with Access Denied. Run with -NoMirrorAppxAliases to silence this warning."
                    } else {
                        Write-Host "[omniroute] mirrored AppX aliases: $isoAppxDir -> $realAppxDir"
                    }
                }
            } catch {
                Write-Warning "[omniroute] AppX alias mirror failed: $($_.Exception.Message)"
            }
        }
    }
}

# Bridge PID/log live in the workspace, NOT in the isolated runtime home.
$bridgePid = Join-Path $workspace 'bridge.pid'
$bridgeLog = Join-Path $workspace 'bridge.log'

# Reap any previous workspace-managed bridge before starting a new one.
# Otherwise repeated launches leak listeners (one per attempted port).
if (Test-Path -LiteralPath $bridgePid) {
    $oldPid = (Get-Content -LiteralPath $bridgePid -Raw -ErrorAction SilentlyContinue).Trim()
    if ($oldPid -match '^\d+$') {
        $oldProc = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        if ($oldProc -and $oldProc.ProcessName -match '^node') {
            Write-Host "[omniroute] stopping previous bridge pid=$oldPid"
            try {
                Stop-Process -Id ([int]$oldPid) -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 400
            } catch {
                Write-Warning "[omniroute] failed to stop previous bridge pid=$oldPid : $($_.Exception.Message)"
            }
        }
    }
    Remove-Item -LiteralPath $bridgePid -Force -ErrorAction SilentlyContinue
}

# Pick a free port AFTER cleaning up any previous bridge so the preferred port
# is usually still available.
$port = Find-FreePort -Preferred $BridgePort

# Resolve node.exe early so both the bridge and the (optional) MCP stdout
# shield rewrite share the same Node binary.
$nodeExe = (Get-Command node -ErrorAction Stop).Path

# Shield ships next to this launcher; $scriptRoot was resolved at the top
# of Main using $PSScriptRoot.
$shieldScript = Join-Path $scriptRoot 'tools\mcp-stdio-shield.mjs'

# Decide effective MCP shield setting. The shield is ON by default; the
# legacy -SanitizeMcpStdout opt-in still works as a no-op force-on. The
# new -NoSanitizeMcpStdout flag is the way to turn it off.
$effectiveSanitize = $true
if ($NoSanitizeMcpStdout) { $effectiveSanitize = $false }
if ($SanitizeMcpStdout)   { $effectiveSanitize = $true }
if ($effectiveSanitize -and -not (Test-Path -LiteralPath $shieldScript)) {
    Write-Warning "[omniroute] MCP shield script not found at $shieldScript; falling back to raw MCP commands."
    $effectiveSanitize = $false
}

# Freeform apply_patch is on by default. -NoFreeformApplyPatch suppresses
# the experimental flag from the managed block. See the param block at the
# top of this script for why this matters.
$effectiveFreeform = -not $NoFreeformApplyPatch

# Now write the isolated config with the actual chosen port.
Write-IsolatedConfig `
    -IsolatedConfigPath (Join-Path $runtime.CodexHome 'config.toml') `
    -OfficialConfigPath $officialConfig `
    -BridgePort $port `
    -ProjectPath $workspace `
    -SanitizeMcp:$effectiveSanitize `
    -NodeExe $nodeExe `
    -ShieldScript $shieldScript `
    -FreeformApplyPatch:$effectiveFreeform

if ($effectiveSanitize) {
    Write-Host "[omniroute] MCP stdio shield: ON (use -NoSanitizeMcpStdout to disable)"
} else {
    Write-Host "[omniroute] MCP stdio shield: OFF"
}
if ($effectiveFreeform) {
    Write-Host "[omniroute] freeform apply_patch: ON (in-process patching, requires GPT-5 family model; -NoFreeformApplyPatch to disable)"
} else {
    Write-Host "[omniroute] freeform apply_patch: OFF (apply_patch.bat shell-path will likely fail with Access Denied under non-AppX launches)"
}

# Per-process env overrides for the bridge child. We set these on the parent
# PowerShell process and restore them right after Start-Process spawns the
# bridge, the same pattern Start-Codex-Official.ps1 uses to keep environment
# leakage scoped to the child.
$bridgeEnvOverrides = @{
    CODEX_HOME        = $runtime.CodexHome
    CODEX_BRIDGE_HOST = '127.0.0.1'
    CODEX_BRIDGE_PORT = "$port"
    BRIDGE_LOG_PATH   = $bridgeLog
    BRIDGE_PORT       = "$port"
    BRIDGE_PID_PATH   = $bridgePid
}
if (Test-Path -LiteralPath $ProviderJson) {
    $bridgeEnvOverrides['OMNIROUTE_PROVIDER_JSON'] = (Resolve-Path -LiteralPath $ProviderJson).Path
}

if ($DryRun) {
    Write-Host "[omniroute] DryRun -- not starting bridge or Codex."
    [pscustomobject]@{
        Mode                = 'omniroute'
        Executable          = $exe
        WorkspaceDir        = $workspace
        IsolatedRuntime     = $runtime
        BridgePort          = $port
        BridgeScript        = $bridgeScript
        BridgePidFile       = $bridgePid
        BridgeLogFile       = $bridgeLog
        OfficialConfigSeen  = (Test-Path -LiteralPath $officialConfig)
        EnvForCodex         = @{
            HOME                          = $runtime.Home
            USERPROFILE                   = $runtime.Home
            APPDATA                       = $runtime.AppData
            LOCALAPPDATA                  = $runtime.LocalApp
            TEMP                          = $runtime.Temp
            TMP                           = $runtime.Temp
            CODEX_HOME                    = $runtime.CodexHome
            CODEX_ELECTRON_USER_DATA_PATH = $runtime.ElectronData
            ELECTRON_USER_DATA_DIR        = $runtime.ElectronData
        }
        CodexCliArgs        = @('--open-project', $workspace, "--user-data-dir=$($runtime.ElectronData)")
        DryRun              = $true
    } | Format-List
    exit 0
}

# Start the bridge as a detached workspace-managed child process.
#
# Earlier revisions of this launcher used [System.Diagnostics.Process]::new()
# with RedirectStandardOutput=$true plus PowerShell ObjectEvent handlers to
# tee bridge stdout into bridge.log. The problem: the bridge's stdout pipe was
# owned by THIS PowerShell process, so the moment the launcher script
# returned, the pipe broke and Node started receiving EPIPE on every log
# write. The bridge process disappeared shortly after, which left Codex
# Desktop talking to a dead loopback port -- the symptom in the field looked
# like "OmniRoute provider configured, but no traffic ever reaches the
# bridge", because the bridge was healthy at launcher exit but gone seconds
# later.
#
# Start-Process -WindowStyle Hidden -PassThru spawns Node with NO stdout
# redirection and breaks the parent/child stdio attachment, so the bridge
# survives the launcher exit. The bridge writes its own log file via
# BRIDGE_LOG_PATH. This mirrors how Start-Codex-Official.ps1's sibling
# launcher in the SuperCodex tree spawns its bridge.
# (node.exe was already resolved above as $nodeExe.)
"[$(Get-Date -Format o)] bridge starting node=$nodeExe port=$port" |
    Out-File -LiteralPath $bridgeLog -Encoding UTF8 -Append

$bridgeEnvPrev = @{}
foreach ($kv in $bridgeEnvOverrides.GetEnumerator()) {
    $bridgeEnvPrev[$kv.Key] = [System.Environment]::GetEnvironmentVariable($kv.Key, 'Process')
    [System.Environment]::SetEnvironmentVariable($kv.Key, [string]$kv.Value, 'Process')
}

$proc = $null
try {
    $proc = Start-Process -FilePath $nodeExe `
        -ArgumentList @($bridgeScript) `
        -WorkingDirectory $workspace `
        -WindowStyle Hidden `
        -PassThru
} finally {
    foreach ($kv in $bridgeEnvPrev.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    }
}

if (-not $proc) {
    throw "[omniroute] failed to start bridge process (Start-Process returned null)"
}

try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

Set-Content -LiteralPath $bridgePid -Value $proc.Id -Encoding ASCII
"[$(Get-Date -Format o)] bridge started pid=$($proc.Id) port=$port" |
    Out-File -LiteralPath $bridgeLog -Encoding UTF8 -Append

try {
    $health = Wait-ForBridgeHealth -BridgeHost '127.0.0.1' -Port $port -TimeoutSec 25
    Write-Host "[omniroute] bridge healthy on 127.0.0.1:$port (pid=$($proc.Id), source=$($health.omniroute.source))"
} catch {
    Write-Error "[omniroute] bridge failed to come up: $($_.Exception.Message). See bridge.log."
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    throw
}

if ($NoCodex) {
    Write-Host "[omniroute] -NoCodex: bridge is running. Codex GUI not launched."
    exit 0
}

# Isolated environment for the Codex GUI process.
#
# IMPORTANT: we set these on the *current PowerShell process* and then call
# Start-Process. ProcessStartInfo.Environment-based overrides were dropping the
# Electron shell during testing -- using Start-Process lets Codex.exe inherit
# the full parent environment (PATH, SystemRoot, ProgramFiles, ComSpec,
# PathExt, ...) plus our overrides, which is what the official Start Menu
# launch sees. We restore the prior env values immediately after start; the
# child process keeps its CreateProcess-time snapshot.
$codexEnv = [ordered]@{
    HOME                          = $runtime.Home
    USERPROFILE                   = $runtime.Home
    APPDATA                       = $runtime.AppData
    LOCALAPPDATA                  = $runtime.LocalApp
    TEMP                          = $runtime.Temp
    TMP                           = $runtime.Temp
    CODEX_HOME                    = $runtime.CodexHome
    # Belt-and-suspenders: three different env vars Electron / Codex may read.
    CODEX_ELECTRON_USER_DATA_PATH = $runtime.ElectronData
    ELECTRON_USER_DATA_DIR        = $runtime.ElectronData
}

# Optionally prepend the isolated runtime's <LOCALAPPDATA>\OpenAI\Codex\bin
# to PATH. Codex Desktop unpacks its own CLI toolkit there on first launch
# (codex.exe + node.exe + rg.exe + codex-command-runner.exe, all identical
# to the WindowsApps versions but living in a user-writable, ACL-permissive
# directory). Without this prepend, anything in Codex that resolves
# `codex.exe` via PATH -- most importantly apply_patch.bat, which is the
# shell-path of the Codex apply_patch tool -- finds the WindowsApps copy
# first and then hits "Access is denied" because that copy is invocable
# only from inside the AppX activation context. With the prepend, PATH
# lookups land on the user-local copies and the shell-path of apply_patch
# works exactly the way Codex's bat wrapper expects.
#
# We are very intentional that this is the only PATH modification the
# launcher does:
#   - It is strictly ADDITIVE: the user's full prior PATH is appended
#     unchanged afterwards, so no other tool gets shadowed.
#   - The prepended directory lives entirely INSIDE the isolated runtime
#     home, so it cannot pollute anything outside it.
#   - The executables it points at are exact bit-identical copies of
#     Codex's own bundled CLI -- this is not a shim or a wrapper, no
#     semantics change.
#
# Even with the freeform apply_patch path active, leaving this on is
# cheap insurance: any other tool that ends up resolving codex.exe via
# PATH (debug helpers, future Codex versions, third-party MCP servers
# that shell out to it) will still get a working binary.
# Resolve the user-local Codex bin paths once, in scope of the whole
# Main block, so later defenses (rewriter daemon, verifier checks) can
# reference them regardless of whether -NoLocalCodexBinPath was passed.
$localCodexBin = Join-Path $runtime.LocalApp 'OpenAI\Codex\bin'
$localCodexExe = Join-Path $localCodexBin 'codex.exe'
$applyPatchWrapper = Join-Path $scriptRoot 'tools\apply_patch-wrapper.mjs'

if (-not $NoLocalCodexBinPath) {
    if (-not (Test-Path -LiteralPath $localCodexBin)) {
        New-Item -ItemType Directory -Path $localCodexBin -Force | Out-Null
    }
    $existingPath = [System.Environment]::GetEnvironmentVariable('PATH', 'Process')
    if (-not $existingPath) { $existingPath = $env:PATH }
    if ($existingPath -and ($existingPath.Split(';') -inotcontains $localCodexBin)) {
        $codexEnv['PATH'] = $localCodexBin + ';' + $existingPath
        Write-Host "[omniroute] prepended user-local Codex bin to PATH: $localCodexBin"
    } else {
        # Already in PATH or unset; do nothing.
    }

    # Drop an `apply_patch.bat` shim into the user-local Codex bin.
    # Routed through tools\apply_patch-wrapper.mjs (Node) so the bat
    # works under BOTH agent-shell stdin-pipe invocation
    # (`$patch | apply_patch`) AND positional-arg invocation
    # (`apply_patch $patch`) without being defeated by cmd.exe's quoting
    # of multi-line arguments. The wrapper finally invokes the user-local
    # codex.exe via CreateProcess, so the final argument reaches the
    # Codex CLI cleanly. Empirically Codex prepends its session-tmp bat
    # dir ahead of our bin on the agent shell's PATH so this particular
    # shim is shadowed; the rewriter daemon below handles the session-
    # tmp bat directly. The shim is still installed as a belt-and-
    # suspenders fallback for any path-lookup that hits our bin first.
    $shimBat = Join-Path $localCodexBin 'apply_patch.bat'
    if (Test-Path -LiteralPath $applyPatchWrapper) {
        $shimEscapedNode = $nodeExe.Replace('"', '\"')
        $shimEscapedWrap = $applyPatchWrapper.Replace('"', '\"')
        $shimEscapedExe  = $localCodexExe.Replace('"', '\"')
        $shimContent = "@echo off`r`n`"$shimEscapedNode`" `"$shimEscapedWrap`" `"$shimEscapedExe`" %*`r`n"
    } else {
        # Wrapper missing: fall back to the naive form. Loses multi-line
        # arg robustness but at least invokes the user-local codex.exe.
        $shimContent = @'
@echo off
codex.exe --codex-run-as-apply-patch %*
'@
    }
    # Always (re)write so older shim versions get refreshed.
    Set-Content -LiteralPath $shimBat -Value $shimContent -Encoding ASCII
    Write-Host "[omniroute] installed apply_patch.bat shim: $shimBat"
} else {
    Write-Host "[omniroute] -NoLocalCodexBinPath: user-local Codex bin NOT added to PATH (apply_patch shell-path will fail with Access Denied)"
}

# ---- apply_patch.bat rewriter daemon ------------------------------------
# Codex Desktop generates `apply_patch.bat` at runtime in
# `<CODEX_HOME>\tmp\arg0\codex-arg0XXXXX\` with a HARDCODED absolute
# path to the WindowsApps codex.exe. Codex prepends that tmp directory
# AHEAD of our user-local Codex bin on the agent shell's PATH, so our
# bat shim above is shadowed. The rewriter daemon below watches Codex's
# tmp directory and rewrites the bat in place to point at the user-local
# (non-AppX-protected) codex.exe copy. This is the third defense layer.
$rewriterPid = Join-Path $workspace 'apply-patch-rewriter.pid'
if (-not $NoApplyPatchRewriter -and (Test-Path -LiteralPath $localCodexExe)) {
    $rewriterScript = Join-Path $scriptRoot 'tools\apply_patch-rewriter.mjs'
    if (-not (Test-Path -LiteralPath $rewriterScript)) {
        Write-Warning "[omniroute] apply_patch rewriter script missing: $rewriterScript"
    } else {
        # Reap any previous rewriter daemon left over from a prior launch.
        $rewriterRuntimePid = Join-Path $runtime.CodexHome 'apply-patch-rewriter.pid'
        foreach ($pidFile in @($rewriterPid, $rewriterRuntimePid)) {
            if (Test-Path -LiteralPath $pidFile) {
                $oldRwPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
                if ($oldRwPid -match '^\d+$') {
                    $oldRw = Get-Process -Id ([int]$oldRwPid) -ErrorAction SilentlyContinue
                    if ($oldRw -and $oldRw.ProcessName -match '^node') {
                        try { Stop-Process -Id ([int]$oldRwPid) -Force -ErrorAction Stop } catch {}
                    }
                }
                Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            }
        }

        # If the Node wrapper exists, pass its path as a 4th arg to the
        # rewriter so it routes session-tmp bats through the wrapper for
        # stdin/argv robustness. Without the wrapper, the rewriter still
        # patches the bat's hardcoded WindowsApps path to the user-local
        # codex.exe -- which fixes Access Denied but leaves multi-line
        # arg passing at the mercy of cmd.exe.
        $rwArgs = @($rewriterScript, $runtime.CodexHome, $localCodexExe)
        if (Test-Path -LiteralPath $applyPatchWrapper) {
            $rwArgs += $applyPatchWrapper
        }
        $rwProc = $null
        try {
            $rwProc = Start-Process -FilePath $nodeExe `
                -ArgumentList $rwArgs `
                -WorkingDirectory $workspace `
                -WindowStyle Hidden `
                -PassThru
        } catch {
            Write-Warning "[omniroute] failed to start apply_patch rewriter: $($_.Exception.Message)"
        }
        if ($rwProc) {
            Set-Content -LiteralPath $rewriterPid -Value $rwProc.Id -Encoding ASCII
            try { $rwProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
            $wrapTag = if (Test-Path -LiteralPath $applyPatchWrapper) { ' wrapped-via=' + $applyPatchWrapper } else { '' }
            Write-Host ("[omniroute] apply_patch rewriter daemon: pid={0} watching={1}\\tmp\\arg0  target={2}{3}" -f $rwProc.Id, $runtime.CodexHome, $localCodexExe, $wrapTag)
        }
    }
} elseif ($NoApplyPatchRewriter) {
    Write-Host "[omniroute] -NoApplyPatchRewriter: apply_patch.bat rewriter daemon NOT started (apply_patch.bat hardcoded path will trip Access Denied)"
} else {
    Write-Host "[omniroute] apply_patch rewriter daemon SKIPPED: user-local codex.exe not present yet at $localCodexExe (Codex Desktop materializes it on first GUI launch; rerun launcher afterwards to enable rewriter)"
}

# --open-project tells Codex Desktop to open the workspace as a real
# project-bound session. Without it Codex starts on the "Work in project"
# landing page and creates a synthetic projectless chat under
# %USERPROFILE%\Documents\Codex\<date>\new-chat. Beyond the cosmetic UI
# difference, the projectless landing path historically routed inference
# through Codex's built-in `openai` provider regardless of what
# `model_provider` resolves to in the isolated CODEX_HOME config -- the
# session_meta jsonl in that mode shows `"model_provider":"openai"` and
# the OmniRoute bridge never sees the reasoning request.
#
# We also still pass --user-data-dir as a belt-and-suspenders Electron
# isolation flag in case any plugin path inside Codex resolves Chromium
# state separately from APPDATA.
$codexArgs = @('--open-project', $workspace, "--user-data-dir=$($runtime.ElectronData)")

$prevEnv = @{}
foreach ($kv in $codexEnv.GetEnumerator()) {
    $prevEnv[$kv.Key] = [System.Environment]::GetEnvironmentVariable($kv.Key, 'Process')
    [System.Environment]::SetEnvironmentVariable($kv.Key, [string]$kv.Value, 'Process')
}

$codexProc = $null
try {
    $codexProc = Start-Process -FilePath $exe -ArgumentList $codexArgs -WorkingDirectory $workspace -PassThru
} finally {
    foreach ($kv in $prevEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    }
}

if (-not $codexProc) {
    Write-Error "[omniroute] Start-Process returned no process for Codex.exe at $exe"
    exit 1
}

Write-Host ("[omniroute] launched Codex.exe pid={0} userdata={1}" -f $codexProc.Id, $runtime.ElectronData)
Write-Host "[omniroute] CLI args: $($codexArgs -join ' ')"
Write-Host "[omniroute] isolated CODEX_HOME: $($runtime.CodexHome)"

# Quick liveness check -- a healthy Electron desktop process should still be
# alive a second or two after launch. If not, give the operator a useful hint.
Start-Sleep -Seconds 2
$codexProc.Refresh()
if ($codexProc.HasExited) {
    Write-Warning ("[omniroute] Codex.exe (pid={0}) exited within 2s with code {1}." -f $codexProc.Id, $codexProc.ExitCode)
    Write-Warning "[omniroute]   Common causes: stale isolated profile (try -Reset), or env-var collision."
    Write-Warning "[omniroute]   Check Windows Event Viewer -> Application logs for Codex.exe entries."
} else {
    Write-Host "[omniroute] Codex.exe alive after 2s (pid=$($codexProc.Id))."
}






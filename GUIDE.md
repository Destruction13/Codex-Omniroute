# Codex OmniRoute — operator guide

Day-to-day usage notes, debugging recipes, and answers to "what if".

## First-time setup checklist

- [ ] Microsoft Store Codex app installed, signed in once, opened at least once (so `%USERPROFILE%\.codex\auth.json` and `models_cache.json` exist).
- [ ] PowerShell 7+ available (`pwsh.exe`) is **recommended but not required**. Windows PowerShell 5.1 (`powershell.exe`) also works — `Setup.bat` offers to install PS 7+ via `winget` and the `.bat` launchers auto-prefer `pwsh` when present.
- [ ] Node.js 18.18+ on `PATH` (`node --version`).
- [ ] OmniRoute reachable (locally, via SSH tunnel, or remote). One of:
      - `$env:OMNIROUTE_BASE_URL` + `$env:OMNIROUTE_API_KEY`
      - `omniroute-provider.json` (copied from the example, gitignored)
      - `~/.config/opencode/auth.json` with a `cloud_omni` / `miracloud` / `omniroute` entry.

## Daily flow

```powershell
# In your project workspace:
.\Start-Codex-OmniRoute.ps1
```

Then use Codex normally. The official UI is what's running — same window, same icon, same Skills/Voice/MCP. The only difference is that reasoning calls leave through your OmniRoute key.

To go back to vanilla Codex (your normal account, full quota in play):

```powershell
.\Start-Codex-Official.ps1
```

The official launcher just stops the bridge and activates the unmodified Codex package against your real `~/.codex/`. Because OmniRoute mode never writes to your real `~/.codex/`, there is nothing to restore. You can also clear the isolated home explicitly:

```powershell
.\Start-Codex-OmniRoute.ps1 -Restore
```

That stops the bridge and deletes the isolated `.codex-omniroute-home/` next to the launcher. Your real `~/.codex/` is left untouched.

## How OmniRoute mode affects your machine

OmniRoute mode is intentionally lightweight. Per launch it touches:

| Path | What happens |
|---|---|
| `.codex-omniroute-home/` (next to the launcher) | **Re-seeded in place every launch.** Contains a regenerated `config.toml` selecting `model_provider = "omniroute_bridge"` plus imported MCP/plugin/marketplace/project sections, a verbatim copy of your real `~/.codex/auth.json` (so Codex Desktop stays signed in as you), a copy of your real `~/.codex/models_cache.json` (if present), and a `.omniroute-seed.json` stamp the bridge uses to compute `desktop_codex_home_honored`. Existing `state_5.sqlite*`, `logs_2.sqlite*`, `sessions/`, and related state are preserved so OmniRoute chat history survives restarts. |
| `CODEX_HOME` environment variable | Points Codex Desktop at the isolated dir. The bridge gets it at process scope. For GUI activation, the launcher writes user-scope `CODEX_HOME` because the AppX broker and late Desktop helpers do not inherit arbitrary process env, then a hidden watcher restores the previous user value after a new session JSONL appears or after timeout. `USERPROFILE`, `APPDATA`, `HOME`, and `TEMP` stay real. `PATH` is only temporarily prepended with the generated quiet `taskkill.exe` shim during AppX activation, then restored by the same watcher. |
| `~/.codex/` (your real one) | **Not modified.** The only exception is a one-shot legacy-cleanup pass that removes leftover managed-block / sentinel-`auth.json` / `*.codex-omniroute-backup` artifacts from earlier repo versions, if you're upgrading. |
| `bridge.pid` (next to the launcher) | PID of the managed node bridge process. |
| `bridge.log` (next to the launcher) | Append-only log of bridge activity. |

That's it. The official Codex package keeps its own identity and runs against your normal `%USERPROFILE%`, so file dialogs, `git`, SSH, your projects, your Documents, and your Desktop are all visible as usual. Only Codex Desktop's `config.toml`, `auth.json`, `models_cache.json`, and history/state lookup hits the isolated `CODEX_HOME` — nothing else does.

## How to confirm rerouting is actually happening

While OmniRoute mode is running, in another shell:

```powershell
Get-Content .\bridge.log -Tail 50 -Wait
```

Every `/v1/responses` line on `bridge.log` is an inference call rerouted to OmniRoute. Compact / dictation calls show up as `official ->`.

You can also hit the local health endpoint (port is logged at launcher startup; default 20333):

```powershell
Invoke-RestMethod http://127.0.0.1:20333/healthz
```

The response contains two Variant-3 fields that answer "is Codex Desktop actually routing through the bridge?":

- `main_reasoning_hits`: counter that increments every time the bridge forwards a `/v1/responses` or `/v1/chat/completions` request to OmniRoute. After you send one chat message, this should be `>= 1`.
- `desktop_codex_home_honored`: `true` once Codex Desktop has measurably touched the isolated home (typically by creating `state_5.sqlite`). If this stays `false` after Codex Desktop has been open for a while, your build of Codex Desktop is ignoring `CODEX_HOME` — escalate via an issue so we can switch you to a TLS-MITM fallback.

## Switching back: -Restore vs Start-Codex-Official.ps1

Use whichever fits your workflow:

- `Start-Codex-Official.ps1` — stop the bridge + activate the official Codex GUI against your real `~/.codex/`. Use this when you want to keep working in Codex but without OmniRoute.
- `Start-Codex-OmniRoute.ps1 -Restore` — stop the bridge + delete the isolated `.codex-omniroute-home/` without launching anything. Use this in scripts or when you want a clean isolated state on next launch.

Both delete `bridge.pid`. Both also clear a stale user-scope `CODEX_HOME` if it points at this repo's isolated home, which is the recovery path for an interrupted AppX activation. Neither modifies your real `~/.codex/` in steady state (the launchers' one-shot legacy-cleanup pass only runs if you're upgrading from an earlier repo version that left a managed block / sentinel / backup file behind).

If you want the official launcher to skip even the bridge-stop / legacy-cleanup step (e.g. to inspect leftover state without disturbing it), pass `-NoAutoRestore`.

## Tunneling OmniRoute

If your OmniRoute runs on a remote VM and you tunnel it locally:

```powershell
ssh -L 20128:127.0.0.1:<remote_omniroute_port> -L 1455:127.0.0.1:1455 <user>@<host>
```

Then in the same shell that runs the launcher (or in `omniroute-provider.json`):

```powershell
$env:OMNIROUTE_BASE_URL = "http://127.0.0.1:20128/v1"
$env:OMNIROUTE_API_KEY  = "<your-omniroute-key>"
$env:OMNIROUTE_MODEL_ALIASES = '{"gpt-5.5":"gpt-5.5-xhigh"}'
```

The tunnel command, host, user, and password are **not** part of this repo. Rotate them if they ever leak.

By default, `omniroute-provider.json` maps Codex's `gpt-5.5` selector to
OmniRoute's explicit `gpt-5.5-xhigh` model. The `gpt-5.4` selector has no
alias, so it still forwards as `cx/gpt-5.4`.

## GPT-5.5 connection-ID pin (opt-in only)

If your OmniRoute setup requires a connection ID for 5.5-family models:

```powershell
$env:OMNIROUTE_PIN_55 = "1"
$env:OMNIROUTE_55_CONNECTION_ID = "<your-id>"
```

or set `gpt55_pin` in `omniroute-provider.json`. The bridge will inject the connection ID only when:
- `OMNIROUTE_PIN_55=1`, **and**
- the request `model` matches one of the configured aliases (default: `gpt-5.5`, `gpt-5.5-thinking`, `gpt-5.5-mini`).

Never commit the connection ID.

## Bridge logs

- `bridge.log` (next to the launcher, gitignored) — bridge stdout/stderr, one event per request.
- The bridge **never** logs `Authorization` headers, API keys, or `auth.json` contents.

If you want quieter logs:

```powershell
$env:CODEX_BRIDGE_LOG_LEVEL = "warn"
.\Start-Codex-OmniRoute.ps1
```

If you want more:

```powershell
$env:CODEX_BRIDGE_LOG_LEVEL = "debug"
```

## Choosing a different bridge port

```powershell
.\Start-Codex-OmniRoute.ps1 -BridgePort 21000
```

The launcher will search nearby ports if the preferred one is busy and bake the actual chosen port into the managed `base_url`.

## Pre-opening a project

```powershell
.\Start-Codex-OmniRoute.ps1 -OpenProject 'C:\src\my-project'
```

The path is forwarded to the AppX activation as the activation argument, which makes Codex open that workspace on start (same effect as dragging the folder onto the Codex window). The path can be a directory or a file; non-existent paths are rejected before the bridge is started.

## MCP

Under Variant 3, Codex Desktop reads its config from the isolated `.codex-omniroute-home/config.toml`, **not** your real `~/.codex/config.toml`. The launcher regenerates the isolated config on every launch with the managed `omniroute_bridge` provider + `omniroute_managed` profile, then overlays selected tooling sections.

The overlay order is:

1. Previous isolated config, so Codex runtime sections such as project trust can survive reseeding.
2. Your real `~/.codex/config.toml`, limited to `[marketplaces.*]`, `[plugins.*]`, `[mcp_servers.*]`, `[projects.*]`, `[windows]`, and `[profiles.omniroute_managed.windows]`.
3. Optional `codex-omniroute-config-overlay.toml` next to the launcher, with the same allowed section types. This file is gitignored and can hold local additions or overrides.

Later sources win if the same section appears more than once. The managed `omniroute_bridge` provider/profile is always written by the launcher and cannot be overridden by the overlay.

MCP servers themselves, when launched from the isolated config, still run as subprocesses against your real `%USERPROFILE%` (the launcher doesn't override that env var), so your `.gitconfig`, SSH keys, project files, etc. are visible to MCP servers the same way they would be in vanilla Codex.

OmniRoute treats MCP readiness as separate signals:

1. **Config imported:** `.codex-omniroute-home/config.toml` contains the expected `[mcp_servers.*]` sections.
2. **Server starts:** `tools\mcp_probe.mjs` can initialize the configured server over JSON-RPC.
3. **Live session registry:** the newest `.codex-omniroute-home/sessions/**/*.jsonl` file contains external MCP tools in `session_meta.payload.dynamic_tools`.
4. **Live model request tools:** `.omniroute-last-reasoning.json` contains an authenticated `/v1/responses.tools` summary with configured MCP server names.
5. **Clean Desktop MCP stdio:** recent Codex Desktop logs have no `Failed to parse MCP message` entries from non-JSON `taskkill` output.

Config import and `mcp_probe` never prove live attachment by themselves. Empty `list_mcp_resources` or `list_mcp_resource_templates` output does not prove tool absence; those APIs inspect resources/templates, not the whole callable tool registry.

During AppX activation, OmniRoute also prepends a generated `.codex-omniroute-home\bin\taskkill.exe` shim to user-scope `PATH` and restores the previous `PATH` after the new session appears. Codex's app-server uses `taskkill /PID ... /T /F` while cleaning up MCP subprocesses; on Windows, those success lines can otherwise leak into app-server stdout and corrupt the JSON-RPC stream that Desktop uses for MCP status.

If a specific MCP server misbehaves (for example, leaks non-JSON onto its own JSON-RPC stdout pipe because it wraps `powershell.exe` or a `.cmd` file), the `tools/mcp-stdio-shield.mjs` wrapper drops non-JSON lines before they reach Codex. The launcher auto-wraps imported MCP server commands that directly use PowerShell or `.cmd`/`.bat` wrappers. You can also wrap a server manually in `codex-omniroute-config-overlay.toml`:

```toml
[mcp_servers.noisy_server]
command = "node"
args = ["C:\\path\\to\\Codex-Omniroute\\tools\\mcp-stdio-shield.mjs", "<original-command>", "<original-args>..."]
```

For ad-hoc diagnostics on any MCP server, the `mcp_probe.mjs` tool spawns each `[mcp_servers.*]` entry, sends a single `initialize` JSON-RPC frame, and reports per-server whether a valid response came back within ~6s:

```powershell
node .\tools\mcp_probe.mjs --json
```

By default it reads `~/.codex/config.toml`. After an OmniRoute `-NoCodex` launch you can test the effective merged config with:

```powershell
node .\tools\mcp_probe.mjs --config .\.codex-omniroute-home\config.toml --json
```

Pass `--server <name>` to test a single server.

To verify live attachment, launch OmniRoute, open a new Desktop thread, and run:

```powershell
.\verify-codex-omniroute.ps1
```

The `mcp-live-session-dynamic-tools` row fails if the newest session JSONL has no external MCP tools. The `mcp-live-model-request-tools` row fails if the bridge did not see configured MCP names in the authenticated model request, and `mcp-appserver-stdio-clean` fails if Desktop logged MCP JSON parse errors for the live session. Use `-NoLiveMcpSession` only when you intentionally want bridge-only diagnostics.

## apply_patch

Codex Desktop is activated via the **AppX broker** (`IApplicationActivationManager.ActivateApplication`) — the exact same path the Start Menu takes. OmniRoute also starts a tiny watcher that rewrites Codex's session-local `apply_patch.bat` wrapper to call the local helper, because WindowsApps resources can be inaccessible from child shells.

That same wrapper is **not** a supported normal-shell tool. In a bare PowerShell session, direct `WindowsApps\...\app\resources\codex.exe --codex-run-as-apply-patch` and direct `WindowsApps\...\app\resources\rg.exe` return `Access is denied`. Use the local CLI installed by Codex instead. The helper accepts a single patch argument, a PowerShell pipeline, or stdin from the rewritten `apply_patch.bat`:

```powershell
Get-Content .\patch.diff -Raw | .\tools\Invoke-CodexApplyPatch.ps1
```

For inline patches in PowerShell, pipe one quoted here-string into `apply_patch` and keep the patch terminator as the final patch line:

```powershell
@'
*** Begin Patch
*** Update File: docs/example.txt
@@
-old text
+new text
*** End Patch
'@ | apply_patch
```

The helper resolves `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe`, normalizes Windows drive-letter paths in patch headers to forward slashes, and passes the patch as one argument to `--codex-run-as-apply-patch`.

As a belt-and-suspenders measure the managed config also sets `apply_patch_freeform = true` in `[features]` and `[profiles.omniroute_managed.features]`. The same feature sections enable `builtin_mcp` and `enable_mcp_apps`, which are required for live MCP attachment in current Desktop builds. When the active model supports custom tools with grammar (GPT-5 family does), Codex can route patches through an in-process freeform tool instead of shelling out.

To disable the freeform flag for debugging:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoFreeformApplyPatch
```

## rg

`rg` is not launched from the package resources in a bare shell. On current Store installs the invocable binary lives under `%LOCALAPPDATA%\OpenAI\Codex\bin\rg.exe`, and Codex's child shell has that location on `PATH`. The launcher does not rewrite `PATH` for `rg`; it verifies that `rg` is invocable and documents the source. Direct `WindowsApps\...\app\resources\rg.exe` is an AppX resource, not the normal-shell contract.

## When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `Get-AppxPackage OpenAI.Codex returned nothing` | Codex Store app not installed under this Windows user. | Install from Microsoft Store and sign in once. |
| `models_cache_missing` from bridge `/v1/models` | `~/.codex/models_cache.json` not populated yet. | Open the official Codex once so it can fetch the list from `chatgpt.com`, then re-run the OmniRoute launcher. |
| `omniroute_not_configured` from bridge `/v1/responses` | No env vars, no `omniroute-provider.json`, no OpenCode-style entry. | Set `OMNIROUTE_BASE_URL` + `OMNIROUTE_API_KEY` or run `Setup.bat` again. |
| Codex feels "logged out" in OmniRoute mode | Either your real `~/.codex/auth.json` is empty/missing, or the launcher's copy into the isolated home failed. | Open the official Codex once and sign in. Then re-launch OmniRoute mode — it copies your real `auth.json` into the isolated home on every launch. |
| Compact or dictation fails with 401/403 from official upstream | Codex Desktop's OAuth token is stale and the bridge can't refresh it. | Re-open the official Codex once to refresh the token, then re-launch OmniRoute mode (the launcher re-copies the fresh `auth.json`). |
| `/healthz` shows `desktop_codex_home_honored: false` after you sent a chat | Codex Desktop on your build does not honor `CODEX_HOME`. | Open an issue. The repo has a TLS-MITM fallback path designed for this case. |
| `/healthz` shows `main_reasoning_hits: 0` after you sent a chat | Codex Desktop is bypassing the bridge — typically because it ran with a stale config from before `CODEX_HOME` was set. | Quit Codex Desktop completely (right-click tray → Quit, not just close the window) and re-launch via `Start-Codex-OmniRoute.bat`. |
| `codex mcp list` says enabled, but `mcp-live-session-dynamic-tools` fails | MCP is configured and may even start, but it is not attached to this Desktop session's registry. | Quit Codex Desktop completely, launch with `Start-Codex-OmniRoute.bat`, open a new thread, send one message, and re-run the verifier. If it still fails, compare `dynamic_tools`, `.omniroute-last-reasoning.json`, and the `mcp-appserver-stdio-clean` row. |
| A frontend task says shadcn or magic is "not found," but the shadcn skill is listed | The model confused missing MCP resources/templates with missing tools or ignored the skill fallback. | Treat the state as "MCP configured but not attached to this session" and use the shadcn skill or CLI fallback when it fits the task. |
| Official Codex keeps opening in OmniRoute mode | A previous OmniRoute launch was interrupted while user-scope `CODEX_HOME` pointed at `.codex-omniroute-home`. | Run `.\Start-Codex-Official.ps1` or `.\Start-Codex-OmniRoute.ps1 -Restore`; both clear that stale override when it points at this repo's isolated home. |
| `EADDRINUSE` | Another process holds the bridge port. | Pass `-BridgePort <free port>`, or run `.\Start-Codex-OmniRoute.ps1 -Restore` to stop the previous bridge. |
| `Failed to parse MCP message` in Codex's MCP log | Either Codex app-server cleanup leaked `taskkill` output, or one MCP server is leaking non-JSON onto stdout. | Re-launch via `Start-Codex-OmniRoute.bat` so the quiet `taskkill.exe` shim is active. If the preview is from a server command, wrap that server with `tools\mcp-stdio-shield.mjs`. |
| Codex window looks indistinguishable from official Codex | That's the goal. The only thing different is where `/v1/responses` goes. |
| You want a clean slate | Stop the bridge + delete the isolated `CODEX_HOME`. | `.\Start-Codex-OmniRoute.ps1 -Restore` |

## What gets gitignored (do not commit these)

- `bridge.pid`, `bridge.log` — managed bridge artifacts.
- `omniroute-provider.json`, `.env`, `auth.json`, `models_cache.json`, `installation_id` — secrets / personal state.
- `.codex-omniroute-home/` — active isolated `CODEX_HOME`, regenerated by the OmniRoute launcher.
- `codex-omniroute-config-overlay.toml` — optional local config overlay; it may contain MCP environment values or private paths.

The `.gitignore` enforces all of this. Double-check `git status` before pushing if you've been editing config by hand.

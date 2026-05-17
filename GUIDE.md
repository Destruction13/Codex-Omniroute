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
| `.codex-omniroute-home/` (next to the launcher) | **Re-seeded every launch.** Contains a fresh `config.toml` selecting `model_provider = "omniroute_bridge"`, a verbatim copy of your real `~/.codex/auth.json` (so Codex Desktop stays signed in as you), a copy of your real `~/.codex/models_cache.json` (if present), and a `.omniroute-seed.json` stamp the bridge uses to compute `desktop_codex_home_honored`. `state_5.sqlite` is deliberately absent so Codex Desktop reads the fresh `config.toml` on the first new-thread create. |
| `CODEX_HOME` environment variable (set in the launched process only) | Points at the isolated dir. **No other env vars are overridden** — `USERPROFILE`, `APPDATA`, `HOME`, `TEMP`, and `PATH` all stay real. |
| `~/.codex/` (your real one) | **Not modified.** The only exception is a one-shot legacy-cleanup pass that removes leftover managed-block / sentinel-`auth.json` / `*.codex-omniroute-backup` artifacts from earlier repo versions, if you're upgrading. |
| `bridge.pid` (next to the launcher) | PID of the managed node bridge process. |
| `bridge.log` (next to the launcher) | Append-only log of bridge activity. |

That's it. The official Codex package keeps its own identity and runs against your normal `%USERPROFILE%`, so file dialogs, `git`, SSH, your projects, your Documents, and your Desktop are all visible as usual. Only the Codex Desktop's `config.toml` / `auth.json` / `models_cache.json` / `state_5.sqlite` lookup hits the isolated `CODEX_HOME` — nothing else does.

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

Both delete `bridge.pid`. Neither modifies your real `~/.codex/` in steady state (the launchers' one-shot legacy-cleanup pass only runs if you're upgrading from an earlier repo version that left a managed block / sentinel / backup file behind).

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
```

The tunnel command, host, user, and password are **not** part of this repo. Rotate them if they ever leak.

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

Under Variant 3, Codex Desktop reads its config from the isolated `.codex-omniroute-home/config.toml`, **not** your real `~/.codex/config.toml`. The launcher rewrites the isolated config from scratch on every launch with only the `omniroute_bridge` provider + `omniroute_managed` profile + freeform-apply-patch toggle.

This is a **deliberate trade-off** of the narrow-isolation approach. MCP servers, plugins, and other customizations you have in your real `~/.codex/config.toml` are not visible in OmniRoute mode. Options if you need them:

- **Run vanilla Codex** (`Start-Codex-Official.bat`) when you need your MCP servers \u2014 it uses your real `~/.codex/config.toml`.
- **Re-create them in the isolated config**: open `.codex-omniroute-home/config.toml` between launches and append your `[mcp_servers.*]` / `[plugins.*]` blocks. The launcher will wipe them on the next OmniRoute launch (current behavior), so this is best for short experiments \u2014 see the project issue tracker for plans to extend the launcher with a user-additions overlay.

MCP servers themselves, when launched from the isolated config, still run as subprocesses against your real `%USERPROFILE%` (the launcher doesn't override that env var), so your `.gitconfig`, SSH keys, project files, etc. are visible to MCP servers the same way they would be in vanilla Codex.

If a specific MCP server misbehaves (e.g. leaks non-JSON onto its JSON-RPC stdout pipe because it wraps `taskkill` or `powershell.exe`), the optional `tools/mcp-stdio-shield.mjs` wrapper drops non-JSON lines before they reach Codex. To use it, edit the appropriate config (`.codex-omniroute-home/config.toml` for OmniRoute mode, `~/.codex/config.toml` for vanilla Codex) for that server:

```toml
[mcp_servers.noisy_server]
command = "node"
args = ["C:\\path\\to\\Codex-Omniroute\\tools\\mcp-stdio-shield.mjs", "<original-command>", "<original-args>..."]
```

It is **not** auto-applied — you only need it if you can actually reproduce a "Failed to parse MCP message" log line.

For ad-hoc diagnostics on any MCP server, the `mcp_probe.mjs` tool spawns each `[mcp_servers.*]` entry, sends a single `initialize` JSON-RPC frame, and reports per-server whether a valid response came back within ~6s:

```powershell
node .\tools\mcp_probe.mjs --json
```

By default it reads `~/.codex/config.toml`. Pass `--config <path>` to point it at a different file, or `--server <name>` to test a single server.

## apply_patch

In the simplified architecture, Codex is activated via the **AppX broker** (`IApplicationActivationManager.ActivateApplication`) — the exact same path the Start Menu takes. That preserves the package identity, so Codex's own `apply_patch.bat` inside `WindowsApps\OpenAI.Codex_<ver>\app\` is invocable normally and the `Access is denied` failure mode goes away.

As a belt-and-suspenders measure the managed block also sets `experimental_use_freeform_apply_patch = true` (both as a bare top-level key and inside `[profiles.omniroute_managed.features]`). When the active model supports custom tools with grammar (GPT-5 family does), Codex routes patches through an in-process freeform tool instead of shelling out, so even if the package identity were lost again somehow, patch application would still work.

To disable the freeform flag for debugging:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoFreeformApplyPatch
```

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
| `EADDRINUSE` | Another process holds the bridge port. | Pass `-BridgePort <free port>`, or run `.\Start-Codex-OmniRoute.ps1 -Restore` to stop the previous bridge. |
| `Failed to parse MCP message` in Codex's MCP log | Some MCP server is leaking non-JSON onto its stdout. | Wrap that single server with `tools\mcp-stdio-shield.mjs` (see MCP section above). |
| Codex window looks indistinguishable from official Codex | That's the goal. The only thing different is where `/v1/responses` goes. |
| You want a clean slate | Stop the bridge + delete the isolated `CODEX_HOME`. | `.\Start-Codex-OmniRoute.ps1 -Restore` |

## What gets gitignored (do not commit these)

- `bridge.pid`, `bridge.log` — managed bridge artifacts.
- `omniroute-provider.json`, `.env`, `auth.json`, `models_cache.json`, `installation_id` — secrets / personal state.
- `.codex-omniroute-home/` — kept ignored for backward compatibility with older clones; the current architecture never creates it.

The `.gitignore` enforces all of this. Double-check `git status` before pushing if you've been editing config by hand.

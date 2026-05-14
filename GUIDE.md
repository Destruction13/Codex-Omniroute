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

The official launcher automatically restores your original `config.toml` from the backup and stops the managed bridge before activating Codex, so the switch is seamless. You can also restore explicitly:

```powershell
.\Start-Codex-OmniRoute.ps1 -Restore
```

That stops the bridge and removes the OmniRoute managed block, leaving your `~/.codex/config.toml` exactly as it was.

## How OmniRoute mode affects your machine

OmniRoute mode is intentionally lightweight. Per launch it touches:

| Path | What happens |
|---|---|
| `~/.codex/config.toml` | A clearly-marked managed block is appended (or replaced if one is already there) between `# >>> codex-omniroute-managed` and `# <<< codex-omniroute-managed` markers. Conflicting bare top-level keys (`model_provider`, `model`, `profile`, `model_reasoning_effort`) outside any section are stripped. Your `[mcp_servers.*]`, `[plugins.*]`, etc. are untouched. |
| `~/.codex/config.toml.codex-omniroute-backup` | First-launch snapshot of the original file. `-Restore` puts it back byte-for-byte. |
| `bridge.pid` (next to the launcher) | PID of the managed node bridge process. |
| `bridge.log` (next to the launcher) | Append-only log of bridge activity. |

That's it. No env-var overrides. No `.codex-omniroute-home/`. No payload copy. No registry edits. The official Codex package keeps its own identity and runs against your normal `%USERPROFILE%`, so file dialogs, `git`, SSH, your projects, your Documents, and your Desktop are all visible as usual.

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

## Switching back: -Restore vs Start-Codex-Official.ps1

Both reverse OmniRoute mode. Use whichever fits your workflow:

- `Start-Codex-Official.ps1` — auto-restore + activate the official Codex GUI. Use this when you want to keep working in Codex but without OmniRoute.
- `Start-Codex-OmniRoute.ps1 -Restore` — auto-restore without launching anything. Use this in scripts or when you don't want a Codex window.

Both delete `bridge.pid` and `config.toml.codex-omniroute-backup` once the restore is complete, so the next OmniRoute launch starts from a clean slate.

If you ever want to inspect the OmniRoute-managed state without disturbing it, pass `-NoAutoRestore` to the official launcher (it'll resolve the package but skip the restore step).

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

MCP servers are inherited from your real `~/.codex/config.toml` automatically — OmniRoute doesn't touch them. The managed block only adds the `omniroute_bridge` provider and `omniroute_managed` profile; everything else (your `[mcp_servers.*]`, `[plugins.*]`, marketplaces) is preserved as-is.

If a specific MCP server misbehaves (e.g. leaks non-JSON onto its JSON-RPC stdout pipe because it wraps `taskkill` or `powershell.exe`), the optional `tools/mcp-stdio-shield.mjs` wrapper drops non-JSON lines before they reach Codex. To use it, edit `~/.codex/config.toml` manually for that server:

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
| Codex feels "logged out" in OmniRoute mode | `~/.codex/auth.json` is empty or missing. | Open the official Codex once and sign in. The bridge reads your real `auth.json` for compact/dictation auth fallback. |
| Compact or dictation fails with 401/403 from official upstream | Inbound auth missing and `auth.json` fallback insufficient. | Make sure the official Codex is signed in. Re-open it once to refresh the token. |
| `EADDRINUSE` | Another process holds the bridge port. | Pass `-BridgePort <free port>`, or run `.\Start-Codex-OmniRoute.ps1 -Restore` to stop the previous bridge. |
| `Failed to parse MCP message` in Codex's MCP log | Some MCP server is leaking non-JSON onto its stdout. | Wrap that single server with `tools\mcp-stdio-shield.mjs` (see MCP section above). |
| Codex window looks indistinguishable from official Codex | That's the goal. The only thing different is where `/v1/responses` goes. |
| You want a clean slate | Stop everything and revert your config. | `.\Start-Codex-OmniRoute.ps1 -Restore` |

## What gets gitignored (do not commit these)

- `bridge.pid`, `bridge.log` — managed bridge artifacts.
- `omniroute-provider.json`, `.env`, `auth.json`, `models_cache.json`, `installation_id` — secrets / personal state.
- `.codex-omniroute-home/` — kept ignored for backward compatibility with older clones; the current architecture never creates it.

The `.gitignore` enforces all of this. Double-check `git status` before pushing if you've been editing config by hand.

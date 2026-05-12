# Codex OmniRoute — operator guide

Day-to-day usage notes, debugging recipes, and answers to "what if".

## First-time setup checklist

- [ ] Microsoft Store Codex app installed, signed in once, opened at least once (so `%USERPROFILE%\.codex\auth.json` and `models_cache.json` exist).
- [ ] PowerShell 7+ available (`pwsh.exe`).
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

Then use Codex normally. The official UI is what's running.

To go back to vanilla Codex (your normal account, full quota in play):

```powershell
.\Start-Codex-Official.ps1
```

Both launchers can coexist; OmniRoute mode is contained inside `.codex-omniroute-home/` and never touches your global Codex profile.

## How to confirm rerouting is actually happening

While OmniRoute mode is running, in another shell:

```powershell
Get-Content .\bridge.log -Tail 50 -Wait
```

Every `/v1/responses` line on `bridge.log` is an inference call rerouted to OmniRoute. Compact / dictation calls show up as `official ->`.

You can also hit the local health endpoint:

```powershell
Invoke-RestMethod http://127.0.0.1:20333/healthz
```

(or whichever port the launcher picked — it logs the port at startup).

## Resetting the isolated runtime

```powershell
.\Start-Codex-OmniRoute.ps1 -Reset
```

This deletes `.codex-omniroute-home/` and reseeds `auth.json`, `models_cache.json`, `installation_id` from your current official Codex profile. Use this if:

- You changed accounts in the official Codex.
- You suspect the isolated profile drifted.
- You changed your official `config.toml` and want the OmniRoute mode to pick up the new MCP / Skills entries.

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

- `bridge.log` (in the workspace, gitignored) — bridge stdout/stderr, one event per request.
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

The launcher will search nearby ports if the preferred one is busy.

## When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `Get-AppxPackage OpenAI.Codex returned nothing` | Codex Store app not installed under this Windows user. | Install from Store and sign in once. |
| `models_cache_missing` from bridge `/v1/models` | Isolated `models_cache.json` not seeded. | Open the official Codex once, then re-run OmniRoute launcher (or use `-Reset`). |
| `omniroute_not_configured` from bridge `/v1/responses` | No env vars, no `omniroute-provider.json`, no OpenCode-style entry. | Set `OMNIROUTE_BASE_URL` + `OMNIROUTE_API_KEY`. |
| Codex feels "logged out" inside OmniRoute mode | `auth.json` not seeded. | Re-run launcher with `-Reset` after opening official Codex at least once. |
| Compact or dictation fails with 401/403 from official upstream | Inbound auth missing and `auth.json` fallback insufficient. | Make sure the official Codex profile is fresh (re-login if needed) and use `-Reset`. |
| `EADDRINUSE` | Another process holds the bridge port. | Pass `-BridgePort <free port>`. |
| Codex window looks indistinguishable from official | That's the goal. The OmniRoute window is the same official binary running with an isolated `userData`. |

## What gets gitignored (do not commit these)

- `.codex-omniroute-home/` — isolated runtime home, contains seeded `auth.json`.
- `bridge.pid`, `bridge.log` — workspace-managed bridge artifacts.
- `omniroute-provider.json`, `.env`, `auth.json`, `models_cache.json`, `installation_id` — secrets / personal state.

The `.gitignore` enforces this. Double-check before pushing.

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

## MCP transport: stdio shield (default ON)

Codex talks to each MCP server over a stdio JSON-RPC pipe. On Windows, certain MCP server commands (powershell.exe wrappers, npx.cmd batch files, anything that uses `taskkill` for child cleanup) can leak human-readable text onto that stdout pipe — most often:

```
SUCCESS: The process with PID 12345 has been terminated.
```

When that happens, Codex's MCP host logs `Failed to parse MCP message` and the affected server is effectively dead — it shows up in the UI as "configured" but the agent sees zero tools/resources from it. This was the root cause of the "I have 12 MCPs in the UI but the agent only sees one" failure mode.

The launcher's stdio shield is now **on by default**. Every inherited `[mcp_servers.<name>]` entry whose `command` is set (i.e. stdio MCPs, not URL-based ones) is rewritten in the isolated `config.toml` so it runs through `tools\mcp-stdio-shield.mjs`:

- `command` becomes `node.exe` (the same node that runs the bridge).
- `args` becomes `[<shield-script>, <original-command>, ...<original-args>]`.
- Sub-tables like `[mcp_servers.<name>.env]` are left untouched, so per-server env passes through unchanged.

The shield is a passthrough pipe: lines on the child's stdout whose first non-whitespace character is `{` or `[` are forwarded as JSON-RPC frames; anything else is rerouted to the shield's stderr with a `[mcp-stdio-shield] dropped non-JSON stdout line: ...` prefix, so it's observable in logs but never enters the JSON-RPC channel.

URL-based MCP entries (no `command`, only `url`) are not touched.

To **disable** the shield (e.g. if a specific MCP server has a JSON-RPC framing bug the shield doesn't tolerate, or if you're debugging stdio behavior), pass `-NoSanitizeMcpStdout`:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoSanitizeMcpStdout
```

The legacy opt-in `-SanitizeMcpStdout` flag still works as a no-op force-on for callers that pinned to it.

You can verify each MCP server actually transports JSON-RPC by running:

```powershell
.\verify-codex-omniroute.ps1
```

The `mcp-probe` check spawns each stdio server, sends a single `initialize` JSON-RPC request, and reports per-server whether a JSON frame was received within ~6s. A healthy isolated runtime shows `ok=N fail=0` (where `N` is the count of stdio MCP servers).

## Choosing which account is seeded

The launcher seeds `auth.json`, `models_cache.json`, and `installation_id` from your official Codex home (`%USERPROFILE%\.codex`) on a fresh isolated runtime. If your official profile is currently bound to the wrong account (e.g. you used another tool that overwrote it), you can override the source:

```powershell
.\Start-Codex-OmniRoute.ps1 -Reset -AuthSource 'C:\path\to\saved\.codex'
```

Where `C:\path\to\saved\.codex` is any directory containing at least an `auth.json` for the desired account. `models_cache.json` and `installation_id` are looked up there too, falling back to your official Codex home for the ones that aren't present (those two are not account-bound). The override is also surfaced in launcher output as `[omniroute] auth source override: …`, so it's visible in `bridge.log`.

`-Reset` is required when you change the auth source, because the launcher does not overwrite `auth.json` in an existing isolated runtime.

## Freeform apply_patch + user-local Codex bin on PATH (both default ON)

Without intervention, Codex's `apply_patch` chain is:
```
agent shell  ──►  apply_patch.bat  ──►  codex.exe --codex-run-as-apply-patch  ──►  Access is denied
```

The fail is rooted in Windows AppX containment: the bundled `codex.exe` lives in `C:\Program Files\WindowsApps\OpenAI.Codex_<ver>\app\resources\codex.exe`, which is only invocable from a parent process that holds the AppX package identity. `Start-Process Codex.exe` (what every non-Start-menu launch path does) gives Codex Desktop the package identity itself but does not propagate it to the shells Codex spawns; those shells then cannot re-invoke `codex.exe` directly and `apply_patch.bat` fails.

OmniRoute attacks the problem from two independent angles, both default-on:

**1. Freeform tool (`experimental_use_freeform_apply_patch`).** The launcher writes the flag into the managed block of the isolated `config.toml` in three places — bare top-level, inside a `[features]` table, and inside `[profiles.omniroute_managed]`. Codex's config schema accepts the flag in all three (per binary scan); empirically the per-profile placement is the one that actually activates the tool when an explicit `profile = ...` is selected, but the redundancy is harmless. When the flag is honored, patch application happens in-process inside the already-running Codex Desktop via a freeform tool call. No child shell, no AppX re-trigger.

The flag has one hard dependency: **the active model must support custom tools with grammar**, which currently means GPT-5 family models. The default `model = "gpt-5.4"` qualifies. If you point the launcher at a non-GPT-5 model (`gpt-4.1`, `claude-*`, `gemini-*`), freeform tools cannot be issued and patch application falls back to the shell-path. The verifier's `freeform-model-compatible` check warns when this happens.

**2. User-local Codex bin on PATH.** Codex Desktop, on first launch, unpacks its bundled CLI toolkit (`codex.exe`, `node.exe`, `rg.exe`, `codex-command-runner.exe`, etc.) into `%LOCALAPPDATA%\OpenAI\Codex\bin\`. Those copies are byte-identical to the WindowsApps versions but live in a user-writable, ACL-permissive directory, so they are freely invocable from any non-AppX child shell. The launcher prepends that directory to Codex's `PATH` so anywhere Codex resolves `codex.exe` via `PATH` lookup — most notably `apply_patch.bat` — lands on a working binary instead of the WindowsApps copy that triggers Access Denied.

This is the **only** `PATH` modification the launcher performs. It is strictly additive (the user's prior `PATH` is appended unchanged after the prepend), the prepended directory lives entirely inside the isolated runtime home, and the executables it points at are byte-identical copies of Codex's own CLI — no shim, no semantic change.

Even with the freeform tool active, leaving the `PATH` prepend on is cheap insurance: any other tool that resolves `codex.exe` via `PATH` (debug helpers, future Codex versions, third-party MCP servers that shell out to it) gets a working binary.

To turn either off (debugging only):

```powershell
.\Start-Codex-OmniRoute.ps1 -NoFreeformApplyPatch       # disable freeform tool
.\Start-Codex-OmniRoute.ps1 -NoLocalCodexBinPath        # disable PATH prepend
```

Neither flag is useful in production.

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
| `Failed to parse MCP message` in Codex's MCP log; UI shows MCPs configured but agent only sees one of them | Some MCP server is leaking non-JSON onto its stdout. | The shield is on by default now — make sure you didn't pass `-NoSanitizeMcpStdout`. Re-run with `.\verify-codex-omniroute.ps1` to confirm `mcp-probe` reports `ok=N fail=0`. |
| Documents / Spreadsheets / Presentations / `browser-use` capabilities don't appear | A previous launcher version inherited the user's global `[marketplaces.*]` and `[plugins.*]` entries, which point at `~\.cache\codex-runtimes\…` and confuse the isolated runtime. | `.\Start-Codex-OmniRoute.ps1 -Reset`. The current launcher's allowlist only inherits `[mcp_servers.*]`, so Codex bootstraps marketplaces/plugins fresh inside the isolated home. |
| `apply_patch -h` returns `Access is denied` inside the agent shell | The agent is hitting the shell-path (`apply_patch.bat -> codex.exe`) and `PATH` lookup is landing on the WindowsApps-protected `codex.exe`, which is not invocable from a non-AppX child shell. | The launcher now both (a) writes `experimental_use_freeform_apply_patch = true` into the managed block in three locations (top-level, `[features]`, `[profiles.omniroute_managed]`) so Codex routes patches through an in-process freeform tool, and (b) prepends `%LOCALAPPDATA%\OpenAI\Codex\bin\` (where Codex Desktop has byte-identical copies of its CLI) to `PATH` so the shell-path also lands on a working binary. Re-run `.\verify-codex-omniroute.ps1` and confirm `freeform-flag-set` and `local-codex-bin-present` are PASS. If you still see Access Denied: (1) make sure you did not pass `-NoFreeformApplyPatch` AND `-NoLocalCodexBinPath`, (2) check the verifier's `freeform-model-compatible` row (a non-GPT-5 model disables freeform), and (3) close Codex completely before re-launching (a stale Codex Desktop window from before the fix keeps its old `PATH`). |
| Wrong account seeded into the isolated runtime | `auth.json` was copied from `%USERPROFILE%\.codex\auth.json`, which is currently bound to a different account than you wanted. | Use `-AuthSource <dir>` with `-Reset` to point at any directory containing a saved `auth.json` for the desired account; see "Choosing which account is seeded" above. |

## What gets gitignored (do not commit these)

- `.codex-omniroute-home/` — isolated runtime home, contains seeded `auth.json`.
- `bridge.pid`, `bridge.log` — workspace-managed bridge artifacts.
- `omniroute-provider.json`, `.env`, `auth.json`, `models_cache.json`, `installation_id` — secrets / personal state.

The `.gitignore` enforces this. Double-check before pushing.

# Codex OmniRoute (Windows)

> **Goal in one sentence.** Keep the official Microsoft Store Codex app exactly as it is, but reroute *only* the main reasoning model through OmniRoute via a local OpenAI-compatible bridge — without touching the Store package, without spending the logged-in account's reasoning quota, and without breaking Voice Dictation, Compact, Skills, MCP, plugins, or future official updates.

This is **not** a Codex clone. It is a *runtime-isolation + bridge* harness around the unchanged official binary.

---

## Architecture truth (read first)

| Concern | Behavior |
|---|---|
| Codex UI / Voice Dictation / Skills / MCP / plugins / updates | **Official Microsoft Store app, untouched.** Launched dynamically via `Get-AppxPackage OpenAI.Codex` → `app\Codex.exe`. |
| Desktop identity / window separation | **Workspace-local isolated runtime home** (`.codex-omniroute-home/`) with isolated `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`. |
| Logged-in feel | A *minimal* seed of `auth.json`, `models_cache.json`, `installation_id` copied from your official Codex profile into the isolated runtime. Chats, sessions, thread DBs, logs are **not** copied. |
| Main reasoning (`/v1/responses`, `/v1/chat/completions`) | **Bridge → OmniRoute** with model normalization (`gpt-5.4` → `cx/gpt-5.4`), `store=false`, optional GPT-5.5 connection-ID pin. |
| Compact (`/v1/responses/compact`) | **Bridge → official upstream**, using inbound auth or `auth.json` fallback. |
| Dictation (`/v1/audio/transcriptions`, `/transcribe`) | **Bridge → official upstream**, including base64 multipart envelopes tagged with `x-codex-base64: 1`. |
| Models list (`/v1/models`) | **Served from isolated `models_cache.json`** — never fetched from OmniRoute. |
| MCP definitions | **Inherited** from your official `config.toml` into the isolated config under an explicit allowlist: only `[mcp_servers.*]` (and its sub-tables) is copied. Marketplaces, plugins, foreign projects, and `[windows]` are dropped, so the isolated runtime never reaches into your global `~\.cache\codex-runtimes` or `~\.codex\.tmp\bundled-marketplaces`. |
| Project trust | The isolated config marks the current workspace as `trust_level = "trusted"`. |
| `git`, `node`, `npx`, etc. | **User's real binaries.** The launcher does NOT install a git shim or override `PATH`. Codex sees the same toolchain it would see under the official launcher. |
| Global `%USERPROFILE%\.codex\config.toml` | **Never written.** |
| Workspace-local `.codex\config.toml` | **Never written.** |

If you find yourself wanting to "recreate Codex itself", stop. The whole point is that **the official Codex binary keeps running** and you only swap the main inference path.

---

## Core invariants

1. The Codex executable launched is the unmodified `app\Codex.exe` resolved from `Get-AppxPackage OpenAI.Codex`; no install path is hardcoded.
2. **Official mode** (`Start-Codex-Official.ps1`) launches that binary with *no* OmniRoute env vars and starts *no* helpers.
3. **OmniRoute mode** (`Start-Codex-OmniRoute.ps1`) launches the same binary with an isolated runtime home and isolated Electron `userData`.
4. The only filesystem identity divergence is the workspace-local `.codex-omniroute-home/`.
5. Seeding is *minimal*: only `auth.json`, `models_cache.json`, `installation_id`.
6. Neither launcher writes to project-local `.codex/config.toml`.
7. Neither launcher modifies the global `%USERPROFILE%\.codex\config.toml`.
8. The bridge binds to `127.0.0.1` only.
9. The isolated provider config pins `requires_openai_auth = true`, `supports_websockets = false`, `wire_api = "responses"`.
10. Main reasoning goes to OmniRoute; compact + transcription go to the official upstream.
11. `/v1/models` is served from the cached file, not OmniRoute.
12. The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.
13. Model identifiers like `gpt-5.4` are normalized to `cx/gpt-5.4` (prefix is configurable) before forwarding.
14. No connection IDs, account IDs, or API keys are hardcoded; everything sensitive comes from env, `omniroute-provider.json` (gitignored), or an OpenCode-style provider config.
15. `verify-codex-omniroute.ps1` exercises all parity invariants without leaving the workspace polluted.
16. The launcher never installs a `git` shim, never modifies `PATH`, and never exports `OMNIROUTE_REAL_GIT_EXE`. Inference routing through the local bridge is the **only** intended behavior difference between OmniRoute and Official mode.
17. The isolated `config.toml` only inherits `[mcp_servers.*]` from the user's official config. `[marketplaces.*]`, `[plugins.*]`, foreign `[projects.*]`, `[windows]`, `[model_providers.*]`, `[profiles.*]`, and bare top-level keys are dropped, so the isolated runtime never reaches into the user's global cache.

---

## File plan

```
codex-omniroute/
├── README.md                            # this file
├── GUIDE.md                             # day-to-day usage
├── codex-omniroute-windows-spec.md      # contract for re-implementers / auditors
├── Start-Codex-Official.ps1             # clean baseline launcher
├── Start-Codex-OmniRoute.ps1            # isolated runtime + bridge + official binary
├── Start-Codex-Official.bat             # convenience wrapper
├── Start-Codex-OmniRoute.bat            # convenience wrapper
├── codex-openai-omniroute-bridge.mjs    # local OpenAI-compatible bridge
├── verify-codex-omniroute.ps1           # invariant checker + optional live smoke
├── omniroute-provider.example.json      # template; copy to omniroute-provider.json
├── .env.example                         # env vars the bridge understands
├── .gitignore                           # excludes runtime homes, secrets, logs, pid
├── package.json                         # node engines + scripts (no runtime deps)
├── mock-transcribe-upstream.mjs         # offline test target for /transcribe
└── tools/
    ├── mcp_smoke_test.py                # MCP parity smoke (PATH/url presence)
    ├── mcp_probe.mjs                    # per-server JSON-RPC initialize probe
    └── mcp-stdio-shield.mjs             # default-ON stdio filter for MCP children
```

---

## Setup (Windows, PowerShell 7+)

1. Install the official **Codex** app from the Microsoft Store. Sign in normally.
2. `git clone` this repo into your project workspace.
3. Configure the OmniRoute provider — pick one:
   - **env vars** (highest priority):
     ```powershell
     $env:OMNIROUTE_BASE_URL = "http://127.0.0.1:20128/v1"   # or your remote
     $env:OMNIROUTE_API_KEY  = "<your-omniroute-key>"
     ```
   - **local provider JSON**:
     ```powershell
     Copy-Item .\omniroute-provider.example.json .\omniroute-provider.json
     # edit omniroute-provider.json (it's gitignored)
     ```
   - **OpenCode-style** `~/.config/opencode/auth.json` with a provider entry named `cloud_omni`, `miracloud`, or `omniroute`.
4. (Optional) If you're tunneling OmniRoute, run the SSH tunnel separately:
   ```powershell
   ssh -L 20128:127.0.0.1:<remote_port> -L 1455:127.0.0.1:1455 <your-user>@<your-host>
   ```
   The repo never includes the tunnel command or its credentials.

---

## Run

```powershell
# OmniRoute mode (default — what you want for cost-controlled reasoning).
.\Start-Codex-OmniRoute.ps1

# OmniRoute mode, but reset the isolated runtime first.
.\Start-Codex-OmniRoute.ps1 -Reset

# OmniRoute mode without the GUI (used by verify-codex-omniroute.ps1).
.\Start-Codex-OmniRoute.ps1 -NoCodex

# Clean baseline — vanilla Codex, no OmniRoute anywhere.
.\Start-Codex-Official.ps1
```

After OmniRoute mode is running you can open Codex normally; the UI is the official UI. You can confirm reasoning is rerouted by watching `bridge.log` (created in the workspace, gitignored).

---

## Verify

```powershell
.\verify-codex-omniroute.ps1
```

Checks (full list documented in `codex-omniroute-windows-spec.md`):
1. `Start-Codex-OmniRoute.ps1 -NoCodex` launches successfully.
2. The bridge `/healthz` responds.
3. The bridge process is workspace-managed (`bridge.pid` exists and matches a live process).
4. The isolated `config.toml` exists and pins `model_provider = "omniroute_bridge"`, `wire_api = "responses"`, `requires_openai_auth = true`.
5. No workspace-local `.codex/config.toml` pollution.
6. No active global Codex OmniRoute provider override.
7. `Start-Codex-Official.ps1` contains no OmniRoute env overrides.
8. `Start-Codex-Official.ps1 -DryRun` spawns no new OmniRoute helper processes.
9. The dictation bridge accepts `x-codex-base64: 1` multipart envelopes (i.e. does not 4xx-reject locally).
10. The managed bridge stops cleanly after verification.

Optional live smokes (require real OmniRoute creds + real seeded `auth.json`):

```powershell
.\verify-codex-omniroute.ps1 -Live
```

Exercises:
- `POST /v1/responses` against OmniRoute.
- `POST /v1/responses/compact` against the official upstream.

---

## Bridge route surface

| Route | Method | Where it goes | Notes |
|---|---|---|---|
| `/healthz` | GET | local | status JSON |
| `/v1/models` | GET | isolated `models_cache.json` | never OmniRoute |
| `/v1/responses` | POST | OmniRoute | main reasoning; model normalized; `store=false` |
| `/v1/chat/completions` | POST | OmniRoute | main reasoning; same normalization |
| `/v1/responses/compact` | POST | official upstream | Compact behavior |
| `/v1/audio/transcriptions` | POST | official upstream | dictation |
| `/transcribe` | POST | official upstream `/audio/transcriptions` | base64 multipart supported |
| `/v1/images/generations` | GET/POST | official upstream | parity, optional |
| anything else | * | official upstream | preserves account/MCP/skills/plugins backend calls |

---

## Things you must redact or parameterize

- OmniRoute API key (`OMNIROUTE_API_KEY` env, or `api_key` in `omniroute-provider.json`).
- OmniRoute base URL (`OMNIROUTE_BASE_URL`) if it points to a private/internal endpoint.
- GPT-5.5 connection ID (`OMNIROUTE_55_CONNECTION_ID` env, or `gpt55_pin.connection_id`) — opt-in only.
- Your Codex `auth.json` and any tokens inside it.
- The OmniRoute SSH tunnel hostname / user / password — never commit these.

All of the above are excluded by `.gitignore` and never logged by the bridge.

---

## What still requires a real Windows machine or real credentials

The repo is implementable on Linux but **not fully exercisable** without:

- A Windows machine with the **Microsoft Store Codex app** installed and signed in.
- A reachable **OmniRoute** endpoint and API key for live `/v1/responses` smoke.
- A **real `auth.json`** under `%USERPROFILE%\.codex\` for the `auth.json` / `account_id` fallback paths and for live Compact / Dictation smoke.

Without these, `Start-Codex-Official.ps1`, `Start-Codex-OmniRoute.ps1`, and `verify-codex-omniroute.ps1` will surface clear errors (`Get-AppxPackage` returning nothing, `models_cache.json` missing, `omniroute_not_configured`).

---

## License

This repository is private/unpublished. No license is granted.

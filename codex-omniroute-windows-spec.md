# Codex OmniRoute (Windows) — implementation contract

This document is the **authoritative spec** anyone re-implementing or auditing Codex OmniRoute on Windows must satisfy. It is intentionally normative.

## 1. Goal

Reproduce the success of "official Codex binary + isolated runtime home + local bridge". The official Microsoft Store Codex app must remain the user-facing application. Only the main reasoning path is rerouted to OmniRoute.

**Out of scope**: rebuilding the Codex UI, patching or replacing the Store package, decompiling official binaries, or writing OmniRoute config into the user's global `%USERPROFILE%\.codex\config.toml`.

## 2. Modes

There are exactly two modes, both launched from this workspace:

### 2.1 Official mode
`Start-Codex-Official.ps1`. Clean baseline:
- Resolves `app\Codex.exe` from `Get-AppxPackage OpenAI.Codex`.
- Inherits the user's normal environment.
- Sets **no** OmniRoute env vars (`OMNIROUTE_*`, `CODEX_BRIDGE_*`, `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`).
- Starts **no** helper processes.
- Static audit must show zero OmniRoute references in the script.

### 2.2 OmniRoute mode
`Start-Codex-OmniRoute.ps1`. Same official binary, isolated runtime, with bridge:
- Resolves `app\Codex.exe` from `Get-AppxPackage OpenAI.Codex`.
- Creates / reuses workspace-local `.codex-omniroute-home/` containing isolated `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_HOME`, and Electron `userData` directory (`CODEX_ELECTRON_USER_DATA_PATH`).
- Seeds **only** `auth.json`, `models_cache.json`, `installation_id` from the user's official Codex home, and only when those files are missing in the isolated home.
- Writes the isolated `config.toml`:
  - Inherits the user's official `config.toml` using an **explicit allowlist**. By default the only inherited section family is `[mcp_servers.*]` (and its sub-tables, e.g. `[mcp_servers.<name>.env]`). Everything else is dropped, including:
    - `[marketplaces.*]` (marketplace sources point at the user's global `~\.cache\codex-runtimes\...` and `~\.codex\.tmp\bundled-marketplaces\...` paths; inheriting them makes the isolated runtime reach back into the user's global cache),
    - `[plugins.*]` (plugin enable bits reference marketplace IDs that may not exist inside the isolated runtime),
    - `[projects.*]` (foreign project trust entries are irrelevant to the isolated workspace),
    - `[windows]` (machine-wide sandbox/shell preferences),
    - `[model_providers.*]`, `[profiles.*]`, top-level `model`, `model_provider`, `model_reasoning_effort`, `profile` (the OmniRoute managed block owns these).
  - The allowlist is enforced by `Sanitize-OfficialConfig` in `Start-Codex-OmniRoute.ps1` and re-asserted by `verify-codex-omniroute.ps1`.
  - Adds the OmniRoute managed block:
    ```toml
    model_provider = "omniroute_bridge"
    model = "gpt-5.4"
    model_reasoning_effort = "xhigh"
    profile = "omniroute_managed"
    experimental_use_freeform_apply_patch = true

    [model_providers.omniroute_bridge]
    name = "OmniRoute Bridge"
    base_url = "http://127.0.0.1:<BRIDGE_PORT>/v1"
    wire_api = "responses"
    requires_openai_auth = true
    supports_websockets = false

    [profiles.omniroute_managed]
    model_provider = "omniroute_bridge"
    model = "gpt-5.4"
    model_reasoning_effort = "xhigh"

    [projects."<absolute workspace path>"]
    trust_level = "trusted"
    ```
    `experimental_use_freeform_apply_patch = true` switches Codex's `apply_patch` to an in-process freeform tool call instead of the `apply_patch.bat -> codex.exe --codex-run-as-apply-patch` shell-out. The shell-out path fails with "Access is denied" under any non-Start-menu launch (Windows AppX containment), and AppX activation cannot be used because the broker drops the launcher's isolated env overrides. The flag is on by default; pass `-NoFreeformApplyPatch` to suppress. Requires a GPT-5 family model (the launcher's default `gpt-5.4` qualifies); other models silently fall back to the broken shell-path and the verifier's `freeform-model-compatible` check warns when this happens.
- The launcher does NOT modify `PATH`, does NOT install a git shim, and does NOT export `OMNIROUTE_REAL_GIT_EXE`. Codex sees the user's real `git`, `node`, `powershell.exe`, and other base commands unchanged. The only meaningful behavior difference between OmniRoute mode and Official mode is that main inference traffic is rerouted through the local bridge.
- Inherited `[mcp_servers.<name>]` entries with a `command` (i.e. stdio MCP servers, not URL-based ones) are rewritten in the isolated `config.toml` so they run through `tools\mcp-stdio-shield.mjs`. The shield drops any non-JSON line on the child's stdout (taskkill `SUCCESS:` messages, npm warnings, cmd.exe banners) so they cannot corrupt the MCP JSON-RPC transport. Sub-tables like `[mcp_servers.<name>.env]` are left untouched. The shield is on by default; pass `-NoSanitizeMcpStdout` to disable.
- The launcher mirrors `%LOCALAPPDATA%\Microsoft\WindowsApps` from the user's real `LOCALAPPDATA` into the isolated runtime via a directory junction (`mklink /J`). This keeps Microsoft Store AppX execution aliases resolvable inside the isolated runtime, which is what `apply_patch.bat -> codex.exe --codex-run-as-apply-patch` and similar Codex-internal shell-out chains rely on. Pass `-NoMirrorAppxAliases` to skip the junction.
- `auth.json`, `models_cache.json`, and `installation_id` seeding can be redirected from the default `%USERPROFILE%\.codex` to any directory via `-AuthSource <dir>`. Use this when the official Codex profile is currently bound to the wrong account; combine with `-Reset` to actually overwrite an existing isolated runtime.
- Starts `codex-openai-omniroute-bridge.mjs` on `127.0.0.1`, preferred port `20333`, port-scanning forward if busy.
- `bridge.pid` and `bridge.log` live **in the workspace**, not in the isolated runtime home.
- Waits for `/healthz` to return `{ok: true}` (timeout: 25s).
- Launches `Codex.exe` with `UseShellExecute=false` and the isolated env applied.

`requires_openai_auth = true` is intentional. The official UI must still believe it is operating in an authenticated environment.

## 3. Bridge contract

### 3.1 Mandatory routes
| Route | Method | Forward target | Required behavior |
|---|---|---|---|
| `/healthz` | GET | local | Returns `{ok:true, port, pid, uptime_ms, omniroute:{configured, source, base_url, model_prefix, gpt55_pin_enabled}, official_upstream, official_auth_present, models_cache_present}`. |
| `/v1/models` | GET | isolated `models_cache.json` | Never call OmniRoute. Return 503 with explanation if cache is missing. |
| `/v1/responses` | POST | OmniRoute | Decode body, normalize model, set `store=false`, replace inbound auth with OmniRoute key. |
| `/v1/chat/completions` | POST | OmniRoute | Same normalization. |
| `/v1/responses/compact` | POST | official upstream | Forward inbound auth; if missing, fall back to isolated `auth.json`. |
| `/v1/audio/transcriptions` | POST | official upstream | Decode `x-codex-base64: 1` envelope; do not propagate the flag upstream. |
| `/transcribe` | POST | official upstream `/audio/transcriptions` | Same base64 handling. |
| `/v1/images/generations` | GET/POST | official upstream | Optional parity. |
| *anything else* | * | official upstream | Catchall, with auth fallback. |

### 3.2 Body decoding
For routes that decode the body (OmniRoute targets, base64-flagged targets):
1. Read full body.
2. Apply `content-encoding` reversal in right-to-left order: `gzip`, `deflate` (with `inflateRaw` fallback), `br`, `zstd` (via dynamically imported `@mongodb-js/zstd` / `fzstd` / `zstd-codec`; if no decoder is available, return 415 with a helpful message).
3. If `x-codex-base64` or `x-codex-base64-multipart` is `1` / `true`, base64-decode the (possibly trimmed) body bytes.

### 3.3 Model normalization
For OmniRoute-bound requests:
- If the body parses as JSON with a `model` field, prepend `OMNIROUTE_MODEL_PREFIX` (default `cx/`) unless already prefixed; strip a leading `openai/` first.
- Set `store = false` unconditionally.
- If GPT-5.5 pinning is enabled (`OMNIROUTE_PIN_55=1` and `OMNIROUTE_55_CONNECTION_ID` set) and the bare model matches one of `gpt-5.5`, `gpt-5.5-thinking`, `gpt-5.5-mini`, inject `connection_id` (and `metadata.connection_id`) into the JSON body.
- Re-serialize the JSON; update `Content-Type: application/json` and `Content-Length`.

### 3.4 Header policy
- Always strip hop-by-hop headers and the inbound `content-length` / `content-encoding` (we always send uncompressed).
- For OmniRoute requests: drop `authorization`, `openai-organization`, `openai-project`, `chatgpt-account-id`; inject `Authorization: Bearer <OMNIROUTE_API_KEY>`; merge `provider.headers`.
- For official upstream requests: forward inbound headers; if `authorization` missing, fall back to `Bearer <auth.json access_token or OPENAI_API_KEY>`; if `chatgpt-account-id` missing, fall back to `auth.json#tokens.account_id`.
- Always strip `x-codex-base64` / `x-codex-base64-multipart` before forwarding.

### 3.5 Provider resolution order
1. `OMNIROUTE_BASE_URL` + `OMNIROUTE_API_KEY` from environment.
2. `omniroute-provider.json` next to the bridge (gitignored).
3. `~/.config/opencode/auth.json` entry named `cloud_omni`, `miracloud`, or `omniroute`.

If none resolve, OmniRoute-bound routes return `500 omniroute_not_configured`. Official-upstream routes still work.

### 3.6 Safety
- Bind only to `127.0.0.1`.
- Never log `authorization`, API keys, tokens, account IDs, connection IDs, cookies, or `auth.json` contents.
- Use graceful shutdown on `SIGINT` / `SIGTERM`.

## 4. Verification

`verify-codex-omniroute.ps1` must perform, at minimum:

Bridge / config invariants:
1. Run `Start-Codex-OmniRoute.ps1 -NoCodex` and confirm exit 0.
2. Confirm `bridge.pid` exists and refers to a live process.
3. Confirm `/healthz` returns `ok=true`.
4. Confirm the isolated `config.toml` contains the OmniRoute provider block.
5. Confirm no `<workspace>\.codex\config.toml` was created.
6. Confirm the global `%USERPROFILE%\.codex\config.toml` (if it exists) does **not** contain `model_provider = "omniroute_bridge"`.
7. Static-audit `Start-Codex-Official.ps1` for any OmniRoute / `CODEX_BRIDGE_` / `CODEX_ELECTRON_USER_DATA_PATH` / `omniroute_bridge` / `.codex-omniroute-home` references — must find none.
8. Run `Start-Codex-Official.ps1 -DryRun` and confirm no new `node` helpers were spawned.
9. POST to `/transcribe` with `x-codex-base64: 1` and verify the bridge does not 4xx-reject locally with `bad_request_encoding`.
10. Stop the managed bridge and confirm the PID is gone.

Native-feature parity invariants:
11. The isolated `config.toml` has NO `[marketplaces.*]`, `[plugins.*]`, `[windows]`, `[model_providers.<x>]` other than `omniroute_bridge`, or `[profiles.<x>]` other than `omniroute_managed` sections. The only `[projects.*]` entry is the workspace itself.
12. `Start-Codex-OmniRoute.ps1` source contains no git-shim references (`Ensure-GitShim`, `Resolve-CSharpCompiler`, `OMNIROUTE_REAL_GIT_EXE`, `tools\git-shim`). `tools/git-shim/` does not exist as a directory containing a built shim binary.
13. The isolated runtime's `skills` directory, when present, resolves under `.codex-omniroute-home`, not under the user's global `~\.codex\skills`.
14. `bridge.log` does not contain Windows process-management noise (`SUCCESS: The process with PID …`, `Failed to parse MCP message`, `Terminate batch job (Y/N)?`). This is best-effort: absence is necessary but not sufficient for a clean MCP transport.
15. `tools/mcp_smoke_test.py`, when Python is available, runs cleanly against the isolated config (each MCP server's command is on `PATH` or its `url` is set).
16. `tools/mcp_probe.mjs`, when Node is available, spawns each stdio MCP server with the same `command`/`args`/env Codex would use, sends a single `initialize` JSON-RPC request, and reports per-server whether a JSON-RPC frame came back within ~6s. A healthy isolated runtime answers `ok=N fail=0` (one entry per stdio server, plus `skip` for any URL-based servers).
17. Freeform `apply_patch` invariants:
    - The bundled Codex agent CLI at `<install>\app\resources\codex.exe` contains the string `experimental_use_freeform_apply_patch` (binary scan). This guards against a future Codex update renaming or removing the flag.
    - The isolated `config.toml` has `experimental_use_freeform_apply_patch = true` somewhere in the file (the managed block by default).
    - The active managed `model =` matches a GPT-5 family pattern (regex `(?i)(^|/)gpt-5(\.|-|$)`). Non-GPT-5 models silently fall back to the broken shell-path, so this check WARNs when set to anything else.

Optional (`-Live`):
- POST `/v1/responses` to confirm OmniRoute round-trip.
- POST `/v1/responses/compact` to confirm official upstream round-trip.

## 5. Things that must remain parameterized / redacted

| Value | Where it lives | Notes |
|---|---|---|
| OmniRoute API key | `OMNIROUTE_API_KEY` env, or `api_key` in `omniroute-provider.json`, or OpenCode entry | gitignored |
| OmniRoute base URL | same | gitignored if private |
| GPT-5.5 connection ID | `OMNIROUTE_55_CONNECTION_ID` or `gpt55_pin.connection_id` | opt-in only |
| `auth.json` / `models_cache.json` / `installation_id` | `%USERPROFILE%\.codex\` (source) and `.codex-omniroute-home\codex\` (seeded copy) | gitignored |
| MCP definitions | inherited from user's official `config.toml` | not parameterized; count is whatever the user has |
| SSH tunnel host/user/password | nowhere in repo | rotate if leaked |

## 6. Things this repo cannot fully verify off-Windows

- That the Microsoft Store package layout still exposes `app\Codex.exe` after a future Store update.
- That the official Codex Compact / Dictation endpoints continue to live under `https://chatgpt.com/backend-api/codex` with paths `/responses/compact` and `/audio/transcriptions`. These are the current defaults; override via `CODEX_OFFICIAL_UPSTREAM` if Codex changes them.
- That OmniRoute's `/responses` shape continues to match the OpenAI Responses API.

All of these are the right things to re-check when you upgrade Codex.

## 7. Reversal

The setup is fully reversible:
- Delete `.codex-omniroute-home/` — official Codex is unaffected.
- Stop using `Start-Codex-OmniRoute.ps1` and run `Start-Codex-Official.ps1` (or launch Codex from the Start Menu).
- The official `config.toml`, the Store package, and the official profile have never been modified.

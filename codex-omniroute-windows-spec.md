# Codex OmniRoute (Windows) — implementation contract

This document is the **authoritative spec** anyone re-implementing or auditing Codex OmniRoute on Windows must satisfy. It is intentionally normative.

## 1. Goal

Reroute Codex Desktop's main reasoning calls to OmniRoute without taking over anything else. The official Microsoft Store Codex app must remain the user-facing application, must keep its package identity, and must continue to see the user's normal Windows profile (`%USERPROFILE%`, `%APPDATA%`, `~/.codex/`, Documents, Desktop, projects, git config, SSH keys).

**Out of scope**: rebuilding the Codex UI, patching or replacing the Store package, decompiling official binaries, or sandboxing/isolating the user's profile in any way.

## 2. Modes

There are exactly two modes, both launched from this workspace:

### 2.1 Official mode
`Start-Codex-Official.ps1`. Clean baseline:
- Resolves the Codex package and its `App` AUMID dynamically via `Get-AppxPackage OpenAI.Codex`.
- Activates Codex via `IApplicationActivationManager.ActivateApplication` (the same COM interface the Start Menu uses).
- Inherits the user's normal environment, except for cleanup of a stale user-scope `CODEX_HOME` when it points at this repo's isolated home.
- Sets **no** OmniRoute bridge env vars (`OMNIROUTE_*`, `CODEX_BRIDGE_*`) and does not set `CODEX_HOME` for the launched process.
- Starts **no** helper processes.
- Before activating Codex, stops a running managed bridge (PID file at `bridge.pid` next to the script), clears stale user-scope `CODEX_HOME` only when it points at this repo's `.codex-omniroute-home`, and sweeps up any legacy artifacts left by earlier repo versions (managed block in `~/.codex/config.toml`, sentinel `~/.codex/auth.json`, `*.codex-omniroute-backup` files). The cleanup pass is one-shot, idempotent, and a no-op once cleared. It is suppressible via `-NoAutoRestore` for verification scripts.
- Does **not** restore from any backup: Variant 3 OmniRoute mode never writes to the user's real `~/.codex/`, so there is nothing to restore.

### 2.2 OmniRoute mode (Variant 3 — narrow `CODEX_HOME` isolation)
`Start-Codex-OmniRoute.ps1`. Same official binary, same activation path, with a managed bridge and a freshly-seeded isolated `CODEX_HOME`:
- Resolves the Codex package and its `App` AUMID dynamically via `Get-AppxPackage OpenAI.Codex`.
- Activates Codex via `IApplicationActivationManager.ActivateApplication`, **not** via `Start-Process` against `WindowsApps\...\Codex.exe`. Current Store packages reject direct `CreateProcess` against the package binary with `Access is denied`, and only AppX activation propagates the package identity correctly so that package-internal tooling (`apply_patch.bat`, bundled `codex.exe`, `rg.exe`) is supported from Codex's child processes.
- **Does not** override `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, or any profile env var that would change the user's identity. The bridge receives process-scope `CODEX_HOME`. For GUI activation, the launcher writes user-scope `CODEX_HOME` because the AppX broker and late Desktop helpers build packaged process environments from user/machine environment state. It also temporarily prepends a generated quiet `taskkill.exe` shim to user-scope `PATH` during activation, then restores the previous value. Codex's profile, file dialogs, `git`, SSH, MCP, and project access all run against the user's real `%USERPROFILE%`.
- Reseeds the isolated `CODEX_HOME` in place on every launch:
  - `auth.json` → verbatim copy of the user's real `~/.codex/auth.json` (so Codex Desktop stays signed in as the user; OAuth tokens preserved).
  - `models_cache.json` → copied from the user's real `~/.codex/models_cache.json` if present.
  - `config.toml` → regenerated with the OmniRoute provider block (below) plus imported user/runtime tooling sections.
  - `.omniroute-seed.json` → a manifest of the seeded files (name, size, mtime); the bridge inspects this on `/healthz` to compute `desktop_codex_home_honored`.
  - `state_5.sqlite*`, `logs_2.sqlite*`, `sessions/`, `session_index.jsonl`, and `.codex-global-state.json` → preserved so OmniRoute chat history survives restarts.
- The isolated `config.toml` is overwritten on every launch (idempotent) and starts with:
  ```toml
  model_provider = "omniroute_bridge"
  model = "gpt-5.4"
  model_reasoning_effort = "xhigh"
  profile = "omniroute_managed"
  suppress_unstable_features_warning = true
  [features]
  builtin_mcp = true
  enable_mcp_apps = true
  tool_search_always_defer_mcp_tools = false
  apply_patch_freeform = true   # default ON; -NoFreeformApplyPatch suppresses

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

  [profiles.omniroute_managed.features]
  builtin_mcp = true
  enable_mcp_apps = true
  tool_search_always_defer_mcp_tools = false
  apply_patch_freeform = true
  ```
  `builtin_mcp` and `enable_mcp_apps` are written in both `[features]` and `[profiles.omniroute_managed.features]` so current Desktop builds can attach configured MCP servers to live sessions. `apply_patch_freeform` is also written in both places so that whichever placement Codex's config schema honors for the active profile, the in-process freeform tool is enabled. Literal `apply_patch` shell calls are protected separately by the local `apply_patch.bat` rewriter and `tools\Invoke-CodexApplyPatch.ps1`. The flag requires a GPT-5 family model; the launcher's default `gpt-5.4` qualifies.
- After the managed block, the launcher imports selected sections from the previous isolated config, then the real `~/.codex/config.toml`, then optional `codex-omniroute-config-overlay.toml` next to the launcher. Allowed sections are `[marketplaces.*]`, `[plugins.*]`, `[mcp_servers.*]`, `[projects.*]`, `[windows]`, and `[profiles.omniroute_managed.windows]`. Later sources win. Managed `model_providers.omniroute_bridge` and `profiles.omniroute_managed` sections are never imported.
- The user's real `~/.codex/config.toml` and `~/.codex/auth.json` never receive OmniRoute managed blocks or auth sentinels. Exceptions are backed up first: the one-shot legacy-cleanup pass removes PR-#2/#3 artifacts, and the deterministic config repair restores the known-good pre-normalize config when the current config matches the mojibake/path-corruption signature. Both passes are idempotent and no-ops once cleared.
- Starts a local OpenAI-compatible bridge (`codex-openai-omniroute-bridge.mjs`) as a managed `node` subprocess. The bridge:
  - Binds to `127.0.0.1:<BRIDGE_PORT>` only.
  - Routes `POST /v1/responses` and `POST /v1/chat/completions` to OmniRoute. Increments `main_reasoning_hits` on every such forward.
  - Routes everything else (compact, dictation, models list, account/skills/MCP backend calls) to the official upstream (`https://chatgpt.com/backend-api/codex` by default). The bridge forwards the inbound OAuth bearer Codex Desktop sends with each request; it falls back to the isolated `CODEX_HOME/auth.json` only when no inbound bearer is present.
  - Serves `GET /v1/models` from `$CODEX_HOME/models_cache.json` (the isolated copy of the user's real cache).
  - Reads `$CODEX_HOME/.omniroute-seed.json` and the current contents of `$CODEX_HOME` to compute the `desktop_codex_home_honored` flag on `/healthz` (honored once `state_5.sqlite` is present, or any seeded file has been modified or any new file appeared).
  - Writes `$CODEX_HOME/.omniroute-last-reasoning.json` before each `/v1/responses` or `/v1/chat/completions` forward. The file contains a redacted summary of the request's `tools` array, configured MCP server names, matched MCP server names, and non-secret inbound header signals. It never stores prompts or secrets.
  - Persists its PID at `bridge.pid` next to the launcher script.
  - Logs to `bridge.log` next to the launcher script with `Authorization` headers and API keys redacted.

- `Start-Codex-OmniRoute.ps1 -Restore` is the inverse operation: it stops the managed bridge (if `bridge.pid` points at a live `node` process), removes the isolated `.codex-omniroute-home/` directory, and runs the legacy-cleanup pass against the user's real `~/.codex/`. After `-Restore`, the user's real `~/.codex/` is unchanged from steady state and the isolated dir is gone.

- `Start-Codex-OmniRoute.ps1 -NoCodex` performs the bridge + seed steps but does not activate Codex. Verification scripts use this mode.

## 3. Bridge contract

| Route | Method | Destination | Notes |
|---|---|---|---|
| `/healthz` | GET | local | Status JSON: port, pid, OmniRoute config presence, isolated-home seed stamp + diagnostics, `main_reasoning_hits` counter, `desktop_codex_home_honored` flag, `official_auth_present`, and `last_reasoning_request`. |
| `/v1/models` | GET | `<CODEX_HOME>/models_cache.json` (isolated) | **Never** fetched from OmniRoute. Returns 503 / documented error when the cache file is missing. |
| `/v1/responses` | POST | OmniRoute | Model normalized (`gpt-5.4` → `cx/gpt-5.4`; `gpt-5.5` → `cx/gpt-5.5-xhigh` by default; prefix and aliases configurable). `store=false`. Optional GPT-5.5 connection-ID pin. Increments `main_reasoning_hits` and persists the redacted live tool diagnostic. |
| `/v1/chat/completions` | POST | OmniRoute | Same normalization; same counter. |
| `/v1/responses/compact` | POST | official upstream | Forwards the inbound OAuth bearer Codex Desktop sends. Falls back to the isolated `auth.json` only when no inbound bearer is present. |
| `/v1/audio/transcriptions` | POST | official upstream | Voice Dictation; `x-codex-base64: 1` envelopes decoded locally. |
| `/transcribe` | POST | official upstream `/audio/transcriptions` | Same base64 handling. |
| `/v1/images/generations` | GET/POST | official upstream | Optional parity. |
| anything else | * | official upstream | Catchall preserves account/MCP/skills/plugins backend calls. |

Hard rules:

- The bridge **never** logs `Authorization` headers, API keys, tokens, account IDs, connection IDs, cookies, or `auth.json` contents.
- The bridge **never** reroutes `/v1/responses/compact`, `/v1/audio/transcriptions`, or `/v1/models` to OmniRoute.
- The bridge **never** hardcodes connection IDs, account IDs, or API keys; all sensitive values come from env, `omniroute-provider.json` (gitignored), or an OpenCode-style provider config.
- The bridge **never** writes to the user's real `~/.codex/` directory; it reads and writes only against the isolated `$CODEX_HOME`.
- The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.

## 4. AppX activation contract

The launchers must activate Codex via the COM interface `IApplicationActivationManager` (CLSID `45BA127D-10A8-46EA-8AB7-56EA9078943C`, IID `2e941141-7f97-4756-ba1d-9decde894a3d`):

```csharp
ICodexAppxApplicationActivationManager.ActivateApplication(
    appUserModelId,   // "<PackageFamilyName>!<AppId>"
    arguments,        // optional activation argument, e.g. workspace path
    ActivateOptions.NoErrorUI,
    out processId);
```

This is the same interface the Start Menu uses. It:

- Hands the activation to the AppX broker, which spawns Codex with full package identity.
- Keeps the package identity for Codex while a local watcher rewrites session-local `apply_patch.bat` wrappers to the invocable local Codex CLI helper.
- Survives Microsoft Store updates: the launcher resolves the package by name and reads the `<Application Id="...">` from the package's `AppxManifest.xml` rather than hardcoding the AUMID.

`Start-Process` against `WindowsApps\OpenAI.Codex_<ver>\app\Codex.exe` must **not** be used: current Store packages reject direct `CreateProcess` against the package binary with `Access is denied`, and even when it succeeds the child loses package identity. A normal shell must use `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe` / `rg.exe`; the repo's `tools\Invoke-CodexApplyPatch.ps1` wraps that local apply-patch fallback.

## 5. Core invariants

Each is enforced by the launchers and asserted by `verify-codex-omniroute.ps1`:

1. The Codex executable launched is the unmodified package resolved from `Get-AppxPackage OpenAI.Codex`; no install path is hardcoded.
2. Codex is activated via `IApplicationActivationManager.ActivateApplication`, not via `Start-Process` against `WindowsApps\...\Codex.exe`.
3. Official mode (`Start-Codex-Official.ps1`) sets no `OMNIROUTE_*` / `CODEX_BRIDGE_*` env vars, starts no helper processes, and — before activating Codex — stops a running managed bridge, clears stale user-scope `CODEX_HOME` for this repo's isolated home, and runs the legacy-cleanup pass.
4. OmniRoute mode (`Start-Codex-OmniRoute.ps1`) inherits the user's profile environment unchanged except for `CODEX_HOME`, which is set for the bridge and written at user scope during AppX activation. It also temporarily prepends `.codex-omniroute-home\bin` to user-scope `PATH` when the generated quiet `taskkill.exe` shim is available; this prevents Codex app-server MCP cleanup from leaking `taskkill` success lines into the JSON-RPC stream. A hidden watcher restores the user-scope values after a new Desktop session JSONL appears or after timeout; stale values are cleared by `-Restore` and official mode. Its only on-disk side-effects are:
   - The isolated `.codex-omniroute-home/` directory (`config.toml`, `auth.json` copy, optional `models_cache.json` copy, `.omniroute-seed.json` stamp, and persistent history/state files).
   - A managed `node` bridge process tracked by `bridge.pid` next to the launcher.
   - A managed `apply_patch` rewriter tracked by `apply_patch_rewriter.pid` next to the launcher.
   - A generated `.codex-omniroute-home\bin\taskkill.exe` shim used only during AppX activation.
   - A one-shot legacy/config-repair pass against the user's real `~/.codex/` (backed up first; idempotent; a no-op once cleared).
5. The user's real `~/.codex/config.toml` and `~/.codex/auth.json` never receive OmniRoute managed state. Legacy cleanup and mojibake repair can modify them only after taking or using a backup.
6. The isolated `config.toml` selects `model_provider = "omniroute_bridge"`, `[model_providers.omniroute_bridge]` with `base_url = "http://127.0.0.1:<BRIDGE_PORT>/v1"`, `wire_api = "responses"`, `requires_openai_auth = true`, `supports_websockets = false`, enabled MCP feature gates, and imported MCP/plugin/marketplace/project sections. Existing isolated history/state files are preserved across reseeds.
7. `Start-Codex-OmniRoute.ps1 -Restore` and `Start-Codex-Official.ps1` both stop the managed bridge, stop the `apply_patch` rewriter, and run the legacy-cleanup pass; `-Restore` additionally removes the isolated `.codex-omniroute-home/` directory.
8. The bridge binds to `127.0.0.1` only.
9. The managed `omniroute_bridge` provider pins `requires_openai_auth = true`, `supports_websockets = false`, `wire_api = "responses"`.
10. Main reasoning goes to OmniRoute; compact + transcription go to the official upstream.
11. `/v1/models` is served from the isolated `$CODEX_HOME/models_cache.json`, not OmniRoute.
12. The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.
13. Model identifiers like `gpt-5.4` are normalized to `cx/gpt-5.4` (prefix is configurable) before forwarding.
14. No connection IDs, account IDs, or API keys are hardcoded.
15. `/healthz` exposes `main_reasoning_hits` (counter incremented every time the bridge forwards a request to OmniRoute), `desktop_codex_home_honored` (true once Codex Desktop has measurably touched the isolated home), and `last_reasoning_request` (redacted live model-request tool diagnostics). After sending one chat message, the counter must move.
16. MCP has five verification layers: imported config sections, successful server startup via `mcp_probe`, live `session_meta.payload.dynamic_tools`, live authenticated model-request tools, and clean Desktop MCP stdio logs. MCP is not considered loaded from config import or `mcp_probe` alone. If `codex mcp list` reports enabled servers but live registries are empty for external MCP, the correct diagnosis is "MCP configured but not attached to this session."
17. `verify-codex-omniroute.ps1` exercises the above plus an Official-mode dry run that stops OmniRoute helpers, preserves the isolated history bundle, and leaves the user's real `~/.codex/` unchanged.

## 6. Anti-goals (explicitly NOT in scope)

The following used to be part of this spec and have been **deliberately removed**:

- **Full profile isolation** (`HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_ELECTRON_USER_DATA_PATH` overrides). Caused file dialogs to open in an empty directory, made `git` lose access to `~/.gitconfig` and credential helpers, and required minimal-seed copying of `auth.json` / `models_cache.json` / `installation_id` into the isolated profile. Variant 3 deliberately uses only `CODEX_HOME`, leaving every other profile-related variable untouched.
- **AppX payload mirroring** (`robocopy /MIR WindowsApps\...\Codex_<ver> .codex-omniroute-home/appx-payload/`). Was originally added to work around antivirus-induced ACL damage on the original package. Out of scope now that AppX activation is used.
- **`apply_patch` Node wrapper** (`tools/apply_patch-wrapper.mjs`). Out of scope for the same reason.
- **`PATH`-prepend** to a `%LOCALAPPDATA%\OpenAI\Codex\bin\` copy of the Codex CLI. Out of scope for the same reason. The current launcher only uses a temporary user-scope `PATH` prepend for the generated quiet `taskkill.exe` shim during AppX activation, then restores the previous value.
- **Managed-block-in-real-config-toml + managed-block-in-real-auth-json approach** (PR #2 / PR #3). Wrote a `# >>> codex-omniroute-managed` block into the user's real `~/.codex/config.toml` and replaced their real `~/.codex/auth.json` with an API-key sentinel. Removed in favor of Variant 3 (isolated `CODEX_HOME`) which avoids touching the user's real `~/.codex/` entirely. Artifacts from those PRs are recognized and cleaned up by the current launchers as a one-shot upgrade pass; the bridge no longer carries any sentinel-stripping logic.
- **`CODEX_OFFICIAL_AUTH_PATH` env var** (PR #3). Was used to point the bridge at the original `auth.json` while a sentinel was in place at the live path. Removed: the bridge now reads `auth.json` straight from `$CODEX_HOME` (the isolated path) and forwards inbound bearers as-is, no substitution.
- **AppX alias junction mirroring** (`Mirror-AppxAliases`). Out of scope.
- **Stdio-shielding every MCP server by default.** The shield (`tools/mcp-stdio-shield.mjs`) is applied only to imported MCP server commands that directly use PowerShell or `.cmd`/`.bat` wrappers, or when the user wraps a server in the overlay. Direct `node` and URL servers are not wrapped by default.

If a future regression in Codex or Windows brings back the original failure modes, anti-goals can be reinstated locally — but they must not be reintroduced silently.

## 7. Verification

`verify-codex-omniroute.ps1` runs `Start-Codex-OmniRoute.ps1 -NoCodex` and asserts the invariants in section 5. It additionally exercises the `-Restore` round-trip, confirms the user's real `~/.codex/` is unchanged, reads the newest GUI/Desktop session JSONL to inspect `session_meta.payload.dynamic_tools`, reads `.omniroute-last-reasoning.json` to inspect the authenticated model request's tool summary, and scans recent Desktop logs for MCP JSON parse errors.

The verifier is the executable definition of "ready to use". A successful full run with all rows PASS (or `bridge-models` WARN on a brand-new install, see below) is sufficient evidence that OmniRoute mode is wired up correctly. `-NoLiveMcpSession` is allowed only for bridge-only diagnostics; it does not prove MCP live attachment.

MCP rows are deliberately separate. `mcp-config-imported` proves the isolated config has `[mcp_servers.*]`, `mcp-probe-isolated-config` proves configured servers can initialize, `mcp-live-session-dynamic-tools` inspects the persisted GUI session metadata, `mcp-live-model-request-tools` inspects the authenticated request actually sent to the model, and `mcp-appserver-stdio-clean` catches JSON-RPC pollution such as `taskkill` success text.

`bridge-models` may return WARN on a fresh install because `models_cache.json` only ends up in the isolated home after Codex Desktop has populated the user's real `~/.codex/models_cache.json` at least once (the launcher copies whatever it finds). Opening the official Codex once resolves this.

During real usage, `/healthz` is the operator's single-curl signal that Codex Desktop is actually on the bridge path:
- `main_reasoning_hits > 0` after sending one chat → main reasoning is being rerouted.
- `desktop_codex_home_honored == true` after Codex Desktop has been open for any non-trivial amount of time → Codex Desktop is honoring `CODEX_HOME`.
- Both fields stay at their initial values (`0` and `false`) → Codex Desktop is bypassing the bridge, typically because it was launched with a stale config from before `CODEX_HOME` was set. Quit Codex Desktop completely and re-launch via `Start-Codex-OmniRoute.bat`.

For MCP, `/healthz` alone is not enough. A full proof requires a new GUI/Desktop session, one chat message, external MCP evidence in the live session/request diagnostics, and no recent app-server MCP parse errors. Otherwise MCP is configured but not attached cleanly to that model session.

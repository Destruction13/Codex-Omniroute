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
- Inherits the user's normal environment unchanged.
- Sets **no** OmniRoute env vars (`OMNIROUTE_*`, `CODEX_BRIDGE_*`, `CODEX_HOME`).
- Starts **no** helper processes.
- Before activating Codex, stops a running managed bridge (PID file at `bridge.pid` next to the script) and sweeps up any legacy artifacts left by earlier repo versions (managed block in `~/.codex/config.toml`, sentinel `~/.codex/auth.json`, `*.codex-omniroute-backup` files). The cleanup pass is one-shot, idempotent, and a no-op once cleared. It is suppressible via `-NoAutoRestore` for verification scripts.
- Does **not** restore from any backup: Variant 3 OmniRoute mode never writes to the user's real `~/.codex/`, so there is nothing to restore.

### 2.2 OmniRoute mode (Variant 3 — narrow `CODEX_HOME` isolation)
`Start-Codex-OmniRoute.ps1`. Same official binary, same activation path, with a managed bridge and a freshly-seeded isolated `CODEX_HOME`:
- Resolves the Codex package and its `App` AUMID dynamically via `Get-AppxPackage OpenAI.Codex`.
- Activates Codex via `IApplicationActivationManager.ActivateApplication`, **not** via `Start-Process` against `WindowsApps\...\Codex.exe`. Current Store packages reject direct `CreateProcess` against the package binary with `Access is denied`, and only AppX activation propagates the package identity correctly so that package-internal tooling (`apply_patch.bat`, bundled `codex.exe`, `rg.exe`) is invocable from Codex's child processes.
- **Does not** override `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `PATH`, or any other env var that would change the user's profile or process identity. The launcher sets exactly one env var: `CODEX_HOME` to the absolute path of `.codex-omniroute-home/` next to the launcher. Codex's profile, file dialogs, `git`, SSH, `rg`, MCP, and `apply_patch.bat` all run against the user's real `%USERPROFILE%`.
- Seeds the isolated `CODEX_HOME` from scratch on every launch:
  - `auth.json` → verbatim copy of the user's real `~/.codex/auth.json` (so Codex Desktop stays signed in as the user; OAuth tokens preserved).
  - `models_cache.json` → copied from the user's real `~/.codex/models_cache.json` if present.
  - `config.toml` → written from scratch with the OmniRoute provider block (below).
  - `.omniroute-seed.json` → a manifest of the seeded files (name, size, mtime); the bridge inspects this on `/healthz` to compute `desktop_codex_home_honored`.
  - `state_5.sqlite` → **deliberately absent** at seed time. Codex Desktop creates it on first boot, having read the freshly-written `config.toml` on the first new-thread create.
- The isolated `config.toml` is overwritten on every launch (idempotent) and contains exactly:
  ```toml
  model_provider = "omniroute_bridge"
  model = "gpt-5.4"
  model_reasoning_effort = "xhigh"
  profile = "omniroute_managed"
  experimental_use_freeform_apply_patch = true   # default ON; -NoFreeformApplyPatch suppresses

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
  experimental_use_freeform_apply_patch = true
  ```
  `experimental_use_freeform_apply_patch` is written **twice** (top-level and per-profile) so that whichever placement Codex's config schema honors for the active profile, the in-process freeform tool is enabled. When honored, Codex applies patches in-process instead of shelling out to `apply_patch.bat` → `codex.exe`. The AppX activation path makes the shell-path also work, so this is belt-and-suspenders. The flag requires a GPT-5 family model; the launcher's default `gpt-5.4` qualifies.
- The user's real `~/.codex/config.toml` and `~/.codex/auth.json` are **never modified**. The only exception is the one-shot legacy-cleanup pass that runs on every launch to undo PR-#2/#3 era artifacts (managed block in real `config.toml`, sentinel `auth.json`, `*.codex-omniroute-backup` files) on machines that have upgraded from earlier repo versions. The pass is idempotent and a no-op once cleared.
- Starts a local OpenAI-compatible bridge (`codex-openai-omniroute-bridge.mjs`) as a managed `node` subprocess. The bridge:
  - Binds to `127.0.0.1:<BRIDGE_PORT>` only.
  - Routes `POST /v1/responses` and `POST /v1/chat/completions` to OmniRoute. Increments `main_reasoning_hits` on every such forward.
  - Routes everything else (compact, dictation, models list, account/skills/MCP backend calls) to the official upstream (`https://chatgpt.com/backend-api/codex` by default). The bridge forwards the inbound OAuth bearer Codex Desktop sends with each request; it falls back to the isolated `CODEX_HOME/auth.json` only when no inbound bearer is present.
  - Serves `GET /v1/models` from `$CODEX_HOME/models_cache.json` (the isolated copy of the user's real cache).
  - Reads `$CODEX_HOME/.omniroute-seed.json` and the current contents of `$CODEX_HOME` to compute the `desktop_codex_home_honored` flag on `/healthz` (honored once `state_5.sqlite` is present, or any seeded file has been modified or any new file appeared).
  - Persists its PID at `bridge.pid` next to the launcher script.
  - Logs to `bridge.log` next to the launcher script with `Authorization` headers and API keys redacted.

- `Start-Codex-OmniRoute.ps1 -Restore` is the inverse operation: it stops the managed bridge (if `bridge.pid` points at a live `node` process), removes the isolated `.codex-omniroute-home/` directory, and runs the legacy-cleanup pass against the user's real `~/.codex/`. After `-Restore`, the user's real `~/.codex/` is unchanged from steady state and the isolated dir is gone.

- `Start-Codex-OmniRoute.ps1 -NoCodex` performs the bridge + seed steps but does not activate Codex. Verification scripts use this mode.

## 3. Bridge contract

| Route | Method | Destination | Notes |
|---|---|---|---|
| `/healthz` | GET | local | Status JSON: port, pid, OmniRoute config presence, isolated-home seed stamp + diagnostics, `main_reasoning_hits` counter, `desktop_codex_home_honored` flag, `official_auth_present`. |
| `/v1/models` | GET | `<CODEX_HOME>/models_cache.json` (isolated) | **Never** fetched from OmniRoute. Returns 503 / documented error when the cache file is missing. |
| `/v1/responses` | POST | OmniRoute | Model normalized (`gpt-5.4` → `cx/gpt-5.4` by default; prefix configurable). `store=false`. Optional GPT-5.5 connection-ID pin. Increments `main_reasoning_hits`. |
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
- Allows package-internal tools (`apply_patch.bat`, bundled `codex.exe`, `rg.exe`) to be invoked from Codex's child shells without `Access is denied`.
- Survives Microsoft Store updates: the launcher resolves the package by name and reads the `<Application Id="...">` from the package's `AppxManifest.xml` rather than hardcoding the AUMID.

`Start-Process` against `WindowsApps\OpenAI.Codex_<ver>\app\Codex.exe` must **not** be used: current Store packages reject direct `CreateProcess` against the package binary with `Access is denied`, and even when it succeeds the child loses package identity, breaking `apply_patch`, `rg`, and the bundled `codex.exe`.

## 5. Core invariants

Each is enforced by the launchers and asserted by `verify-codex-omniroute.ps1`:

1. The Codex executable launched is the unmodified package resolved from `Get-AppxPackage OpenAI.Codex`; no install path is hardcoded.
2. Codex is activated via `IApplicationActivationManager.ActivateApplication`, not via `Start-Process` against `WindowsApps\...\Codex.exe`.
3. Official mode (`Start-Codex-Official.ps1`) inherits the user's environment unchanged, sets no `OMNIROUTE_*` / `CODEX_*` env vars, starts no helper processes, and — before activating Codex — stops a running managed bridge and runs the legacy-cleanup pass.
4. OmniRoute mode (`Start-Codex-OmniRoute.ps1`) inherits the user's environment unchanged except for one variable: `CODEX_HOME` is set to the isolated `.codex-omniroute-home/` directory next to the launcher. Its only on-disk side-effects are:
   - The isolated `.codex-omniroute-home/` directory (`config.toml`, `auth.json` copy, optional `models_cache.json` copy, `.omniroute-seed.json` stamp).
   - A managed `node` bridge process tracked by `bridge.pid` next to the launcher.
   - A one-shot legacy-cleanup pass against the user's real `~/.codex/` (idempotent; a no-op once cleared).
5. The user's real `~/.codex/config.toml` and `~/.codex/auth.json` are NEVER written to in steady state. The legacy-cleanup pass only modifies them once if PR-#2/#3-era artifacts are present.
6. The isolated `config.toml` selects `model_provider = "omniroute_bridge"`, `[model_providers.omniroute_bridge]` with `base_url = "http://127.0.0.1:<BRIDGE_PORT>/v1"`, `wire_api = "responses"`, `requires_openai_auth = true`, `supports_websockets = false`. `state_5.sqlite` is deliberately absent from the isolated home so Codex Desktop reads the freshly-written `config.toml` on the first new-thread create.
7. `Start-Codex-OmniRoute.ps1 -Restore` and `Start-Codex-Official.ps1` both stop the managed bridge and run the legacy-cleanup pass; `-Restore` additionally removes the isolated `.codex-omniroute-home/` directory.
8. The bridge binds to `127.0.0.1` only.
9. The managed `omniroute_bridge` provider pins `requires_openai_auth = true`, `supports_websockets = false`, `wire_api = "responses"`.
10. Main reasoning goes to OmniRoute; compact + transcription go to the official upstream.
11. `/v1/models` is served from the isolated `$CODEX_HOME/models_cache.json`, not OmniRoute.
12. The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.
13. Model identifiers like `gpt-5.4` are normalized to `cx/gpt-5.4` (prefix is configurable) before forwarding.
14. No connection IDs, account IDs, or API keys are hardcoded.
15. `/healthz` exposes `main_reasoning_hits` (counter incremented every time the bridge forwards a request to OmniRoute) and `desktop_codex_home_honored` (true once Codex Desktop has measurably touched the isolated home). After sending one chat message, both must move (counter > 0; flag true).
16. `verify-codex-omniroute.ps1` exercises the above plus a `-Restore` round-trip and leaves the user's real `~/.codex/` unchanged.

## 6. Anti-goals (explicitly NOT in scope)

The following used to be part of this spec and have been **deliberately removed**:

- **Full profile isolation** (`HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_ELECTRON_USER_DATA_PATH` overrides). Caused file dialogs to open in an empty directory, made `git` lose access to `~/.gitconfig` and credential helpers, and required minimal-seed copying of `auth.json` / `models_cache.json` / `installation_id` into the isolated profile. Variant 3 deliberately sets ONLY `CODEX_HOME`, leaving every other profile-related variable untouched.
- **AppX payload mirroring** (`robocopy /MIR WindowsApps\...\Codex_<ver> .codex-omniroute-home/appx-payload/`). Was originally added to work around antivirus-induced ACL damage on the original package. Out of scope now that AppX activation is used.
- **`apply_patch.bat` rewriter daemon** (`tools/apply_patch-rewriter.mjs`). Was polling `<isolated>/tmp/arg0/` every 500ms to rewrite the session-local `apply_patch.bat` so it pointed at a non-AppX `codex.exe`. AppX activation preserves package identity, so the session `apply_patch.bat` invokes the bundled `codex.exe` normally.
- **`apply_patch` Node wrapper** (`tools/apply_patch-wrapper.mjs`). Out of scope for the same reason.
- **`PATH`-prepend** to a `%LOCALAPPDATA%\OpenAI\Codex\bin\` copy of the Codex CLI. Out of scope for the same reason.
- **Managed-block-in-real-config-toml + managed-block-in-real-auth-json approach** (PR #2 / PR #3). Wrote a `# >>> codex-omniroute-managed` block into the user's real `~/.codex/config.toml` and replaced their real `~/.codex/auth.json` with an API-key sentinel. Removed in favor of Variant 3 (isolated `CODEX_HOME`) which avoids touching the user's real `~/.codex/` entirely. Artifacts from those PRs are recognized and cleaned up by the current launchers as a one-shot upgrade pass; the bridge no longer carries any sentinel-stripping logic.
- **`CODEX_OFFICIAL_AUTH_PATH` env var** (PR #3). Was used to point the bridge at the original `auth.json` while a sentinel was in place at the live path. Removed: the bridge now reads `auth.json` straight from `$CODEX_HOME` (the isolated path) and forwards inbound bearers as-is, no substitution.
- **AppX alias junction mirroring** (`Mirror-AppxAliases`). Out of scope.
- **Stdio-shielding every MCP server by default.** The shield (`tools/mcp-stdio-shield.mjs`) remains in the repo as an opt-in wrapper for misbehaving servers, but the launcher does not auto-rewrite `[mcp_servers.*]` entries.

If a future regression in Codex or Windows brings back the original failure modes, anti-goals can be reinstated locally — but they must not be reintroduced silently.

## 7. Verification

`verify-codex-omniroute.ps1` runs `Start-Codex-OmniRoute.ps1 -NoCodex` and asserts the invariants in section 5. It additionally exercises the `-Restore` round-trip and confirms the user's real `~/.codex/` is unchanged.

The verifier is the executable definition of "ready to use". A successful run with all rows PASS (or `bridge-models` WARN on a brand-new install, see below) is sufficient evidence that OmniRoute mode is wired up correctly.

`bridge-models` may return WARN on a fresh install because `models_cache.json` only ends up in the isolated home after Codex Desktop has populated the user's real `~/.codex/models_cache.json` at least once (the launcher copies whatever it finds). Opening the official Codex once resolves this.

During real usage, `/healthz` is the operator's single-curl signal that Codex Desktop is actually on the bridge path:
- `main_reasoning_hits > 0` after sending one chat → main reasoning is being rerouted.
- `desktop_codex_home_honored == true` after Codex Desktop has been open for any non-trivial amount of time → Codex Desktop is honoring `CODEX_HOME`.
- Both fields stay at their initial values (`0` and `false`) → Codex Desktop is bypassing the bridge, typically because it was launched with a stale config from before `CODEX_HOME` was set. Quit Codex Desktop completely and re-launch via `Start-Codex-OmniRoute.bat`.

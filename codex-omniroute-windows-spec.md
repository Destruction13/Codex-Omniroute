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
- Sets **no** OmniRoute env vars (`OMNIROUTE_*`, `CODEX_BRIDGE_*`, `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`).
- Starts **no** helper processes.
- Before activating Codex, auto-restores any backup at `~/.codex/config.toml.codex-omniroute-backup` and stops a running managed bridge (PID file at `bridge.pid` next to the script). This is suppressible via `-NoAutoRestore` for verification scripts.

### 2.2 OmniRoute mode
`Start-Codex-OmniRoute.ps1`. Same official binary, same activation path, with a managed bridge:
- Resolves the Codex package and its `App` AUMID dynamically via `Get-AppxPackage OpenAI.Codex`.
- Activates Codex via `IApplicationActivationManager.ActivateApplication`, **not** via `Start-Process` against `WindowsApps\...\Codex.exe`. Current Store packages reject direct `CreateProcess` against the package binary with `Access is denied`, and only AppX activation propagates the package identity correctly so that package-internal tooling (`apply_patch.bat`, bundled `codex.exe`, `rg.exe`) is invocable from Codex's child processes.
- **Does not** override `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`, `PATH`, or any other env var that would change the user's profile or process identity. Codex runs against the user's real `%USERPROFILE%`.
- Patches the user's real `~/.codex/config.toml` (`<userprofile>\.codex\config.toml`) by appending a clearly-marked managed block between two marker comments:
  ```
  # >>> codex-omniroute-managed (auto-generated; do not edit by hand)
  ...
  # <<< codex-omniroute-managed
  ```
  Before the first write, the original file is copied to `~/.codex/config.toml.codex-omniroute-backup`. If no original existed, an empty backup file is created as a sentinel. The backup is never overwritten by subsequent launches.
- Re-running the launcher updates the managed block in place. Conflicting **bare top-level** keys (`model_provider`, `model`, `profile`, `model_reasoning_effort`) outside any section header are stripped before the new block is written so that two independent configurations cannot coexist. Section tables outside the managed block (e.g. `[mcp_servers.*]`, `[plugins.*]`, `[projects.*]`, `[windows]`) are preserved verbatim — they belong to the user.
- The managed block sets:
  ```toml
  # >>> codex-omniroute-managed (auto-generated; do not edit by hand)
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
  # <<< codex-omniroute-managed
  ```
  `experimental_use_freeform_apply_patch` is written **twice** (top-level and per-profile) so that whichever placement Codex's config schema honors for the active profile, the in-process freeform tool is enabled. When honored, Codex applies patches in-process instead of shelling out to `apply_patch.bat` → `codex.exe`. The AppX activation path makes the shell-path also work, so this is belt-and-suspenders. The flag requires a GPT-5 family model; the launcher's default `gpt-5.4` qualifies.

- Starts a local OpenAI-compatible bridge (`codex-openai-omniroute-bridge.mjs`) as a managed `node` subprocess. The bridge:
  - Binds to `127.0.0.1:<BRIDGE_PORT>` only.
  - Routes `POST /v1/responses` and `POST /v1/chat/completions` to OmniRoute.
  - Routes everything else (compact, dictation, models list, account/skills/MCP backend calls) to the official upstream (`https://chatgpt.com/backend-api/codex` by default).
  - Serves `GET /v1/models` from `<userprofile>\.codex\models_cache.json` so Codex sees its real model list even when OmniRoute itself does not implement a models endpoint.
  - Persists its PID at `bridge.pid` next to the launcher script.
  - Logs to `bridge.log` next to the launcher script with `Authorization` headers and API keys redacted.

- `Start-Codex-OmniRoute.ps1 -Restore` is the inverse operation: it stops the managed bridge (if `bridge.pid` points at a live `node` process), restores `~/.codex/config.toml` byte-for-byte from the backup file (or deletes the file when the backup represents "no original"), and removes the backup. After `-Restore`, the on-disk state is indistinguishable from never having run OmniRoute mode.

- `Start-Codex-OmniRoute.ps1 -NoCodex` performs the bridge + config-patch steps but does not activate Codex. Verification scripts use this mode.

## 3. Bridge contract

| Route | Method | Destination | Notes |
|---|---|---|---|
| `/healthz` | GET | local | Status JSON: port, pid, OmniRoute config presence, official auth presence, models cache presence. |
| `/v1/models` | GET | `<CODEX_HOME>/models_cache.json` | **Never** fetched from OmniRoute. Returns 503 / documented error when the cache file is missing. |
| `/v1/responses` | POST | OmniRoute | Model normalized (`gpt-5.4` → `cx/gpt-5.4` by default; prefix configurable). `store=false`. Optional GPT-5.5 connection-ID pin. |
| `/v1/chat/completions` | POST | OmniRoute | Same normalization. |
| `/v1/responses/compact` | POST | official upstream | Uses inbound auth or `auth.json` fallback. |
| `/v1/audio/transcriptions` | POST | official upstream | Voice Dictation; `x-codex-base64: 1` envelopes decoded locally. |
| `/transcribe` | POST | official upstream `/audio/transcriptions` | Same base64 handling. |
| `/v1/images/generations` | GET/POST | official upstream | Optional parity. |
| anything else | * | official upstream | Catchall preserves account/MCP/skills/plugins backend calls. |

Hard rules:

- The bridge **never** logs `Authorization` headers, API keys, tokens, account IDs, connection IDs, cookies, or `auth.json` contents.
- The bridge **never** reroutes `/v1/responses/compact`, `/v1/audio/transcriptions`, or `/v1/models` to OmniRoute.
- The bridge **never** hardcodes connection IDs, account IDs, or API keys; all sensitive values come from env, `omniroute-provider.json` (gitignored), or an OpenCode-style provider config.
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
3. Official mode (`Start-Codex-Official.ps1`) inherits the user's environment unchanged, sets no `OMNIROUTE_*` / `CODEX_*` env vars, starts no helper processes, and auto-restores any prior OmniRoute config + stops a running managed bridge before activating Codex.
4. OmniRoute mode (`Start-Codex-OmniRoute.ps1`) inherits the user's environment unchanged. Its only side-effects are:
   - A managed block appended to `~/.codex/config.toml`.
   - A backup at `~/.codex/config.toml.codex-omniroute-backup`.
   - A managed `node` bridge process tracked by `bridge.pid` next to the launcher.
5. The managed block is delimited by `# >>> codex-omniroute-managed` / `# <<< codex-omniroute-managed` markers. Re-running the launcher replaces the block in place; conflicting bare top-level keys outside any section are stripped to prevent dual-config drift.
6. Sections outside the managed block in `~/.codex/config.toml` (`[mcp_servers.*]`, `[plugins.*]`, `[projects.*]`, `[windows]`, etc.) are preserved verbatim.
7. `Start-Codex-OmniRoute.ps1 -Restore` and `Start-Codex-Official.ps1` both restore the backup byte-for-byte, delete the backup file, and stop the managed bridge.
8. The bridge binds to `127.0.0.1` only.
9. The managed `omniroute_bridge` provider pins `requires_openai_auth = true`, `supports_websockets = false`, `wire_api = "responses"`.
10. Main reasoning goes to OmniRoute; compact + transcription go to the official upstream.
11. `/v1/models` is served from `~/.codex/models_cache.json`, not OmniRoute.
12. The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.
13. Model identifiers like `gpt-5.4` are normalized to `cx/gpt-5.4` (prefix is configurable) before forwarding.
14. No connection IDs, account IDs, or API keys are hardcoded.
15. `verify-codex-omniroute.ps1` exercises the above plus a `-Restore` round-trip and leaves the user's config in its original state.

## 6. Anti-goals (explicitly NOT in scope)

The following used to be part of this spec and have been **deliberately removed**:

- **Profile isolation** (`HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH` overrides). Caused file dialogs to open in an empty directory, made `git` lose access to `~/.gitconfig` and credential helpers, and required minimal-seed copying of `auth.json` / `models_cache.json` / `installation_id`. The AppX activation path makes isolation unnecessary.
- **Workspace-local runtime home** (`.codex-omniroute-home/`). Same root cause as above.
- **AppX payload mirroring** (`robocopy /MIR WindowsApps\...\Codex_<ver> .codex-omniroute-home/appx-payload/`). Was originally added to work around antivirus-induced ACL damage on the original package. Out of scope now that AppX activation is used.
- **`apply_patch.bat` rewriter daemon** (`tools/apply_patch-rewriter.mjs`). Was polling `<isolated>/tmp/arg0/` every 500ms to rewrite the session-local `apply_patch.bat` so it pointed at a non-AppX `codex.exe`. AppX activation preserves package identity, so the session `apply_patch.bat` invokes the bundled `codex.exe` normally.
- **`apply_patch` Node wrapper** (`tools/apply_patch-wrapper.mjs`). Out of scope for the same reason.
- **`PATH`-prepend** to a `%LOCALAPPDATA%\OpenAI\Codex\bin\` copy of the Codex CLI. Out of scope for the same reason.
- **`Sanitize-OfficialConfig` allowlist** over the user's `config.toml`. We no longer copy the user's config into an isolated profile; the managed block is appended in place and the user's other sections are preserved verbatim.
- **AppX alias junction mirroring** (`Mirror-AppxAliases`). Out of scope.
- **Stdio-shielding every MCP server by default.** The shield (`tools/mcp-stdio-shield.mjs`) remains in the repo as an opt-in wrapper for misbehaving servers, but the launcher does not auto-rewrite `[mcp_servers.*]` entries.

If a future regression in Codex or Windows brings back the original failure modes, anti-goals can be reinstated locally — but they must not be reintroduced silently.

## 7. Verification

`verify-codex-omniroute.ps1` runs `Start-Codex-OmniRoute.ps1 -NoCodex` and asserts the invariants in section 5. It additionally exercises the `-Restore` round-trip and confirms the on-disk state after restore matches the original byte-for-byte.

The verifier is the executable definition of "ready to use". A successful run with all rows PASS (or `bridge-models` WARN on a brand-new install, see below) is sufficient evidence that OmniRoute mode is wired up correctly.

`bridge-models` may return WARN on a fresh install because `~/.codex/models_cache.json` is populated by the official Codex Desktop the first time it talks to `chatgpt.com`. Opening the official Codex once resolves this.

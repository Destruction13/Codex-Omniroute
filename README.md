# Codex OmniRoute

Codex OmniRoute is a shared-home gateway for Codex Desktop. Official Codex
keeps using the normal OpenAI route. Codex OmniRoute uses the same official
Codex home, but its launcher passes process-level runtime overrides that point
main model calls at a local OmniRoute bridge.

This project no longer uses `.codex-omniroute-home` as an active `CODEX_HOME`.

## Architecture

Both modes use the official Codex home:

```text
Windows: %USERPROFILE%\.codex
macOS:   ~/.codex
```

The launcher starts `codex-openai-omniroute-bridge.mjs` on
`127.0.0.1:<bridge-port>`. On Windows, the default desktop path follows the
SuperCodex duplicate-app pattern:

1. It mirrors the official Store app into
   `%LOCALAPPDATA%\CodexOmniRoute\WindowsApp`.
2. It keeps Electron UI state in
   `%LOCALAPPDATA%\CodexOmniRoute\ElectronUserData`.
3. It keeps `CODEX_HOME` pointed at `%USERPROFILE%\.codex`.
4. It preserves the official embedded CLI as `resources\codex-official.exe`.
5. It replaces only the duplicate app's `resources\codex.exe` with a small
   wrapper that intercepts `app-server` and injects runtime overrides.

The wrapper launches `codex-official.exe app-server` with these process-level
overrides:

```powershell
codex-official.exe app-server `
  -c 'model_provider="omniroute"' `
  -c 'model="gpt-5.5"' `
  -c 'model_reasoning_effort="xhigh"' `
  -c 'features.tool_search=true' `
  -c 'features.apply_patch_freeform=true' `
  -c 'model_providers.omniroute.base_url="http://127.0.0.1:<port>/v1"' `
  -c 'model_providers.omniroute.wire_api="responses"' `
  -c 'model_providers.omniroute.env_key="OMNIROUTE_API_KEY"' `
  -c 'model_providers.omniroute.requires_openai_auth=true' `
  -c 'model_providers.omniroute.supports_websockets=false'
```

The shared `config.toml` is not rewritten with a global
`model_provider = "omniroute"`. MCP servers, plugins, app connectors, sessions,
auth, model cache, and tool discovery stay in the official home.

## Routes

| Request | Route |
| --- | --- |
| `/v1/responses` | OmniRoute bridge |
| `/v1/chat/completions` | OmniRoute bridge |
| `/v1/images/generations` | OmniRoute image lane |
| `/v1/images/edits` | OmniRoute image lane |
| `/v1/responses/compact` | Official Codex/OpenAI backend |
| `/v1/audio/transcriptions`, `/transcribe` | Official Codex/OpenAI backend |
| `/v1/models` | Shared `%USERPROFILE%\.codex\models_cache.json` |

The bridge includes a native `tool_search` shim and an `apply_patch` response
adapter. If the upstream model calls `omniroute_tool_search`, the bridge
rewrites it back into a Codex-native `tool_search_call` with client execution.
If the upstream emits an `apply_patch` function call, the bridge rewrites it
back into a native custom tool call.

## Image and 10MB handling

The image lane follows the SuperCodex-style split: image generation and edits
go to OmniRoute, while compact and dictation stay official. Configure a
dedicated image key with:

```powershell
$env:CODEX_OMNI_OMNIROUTE_IMAGE_API_KEY = "..."
$env:CODEX_OMNI_OMNIROUTE_IMAGE_MODEL = "chatgpt-web/gpt-5.3-instant"
```

If no image key is set, the bridge falls back to the main provider key.

OmniRoute-compatible upstreams often reject request bodies above 10MB. The
bridge keeps recent inline images, stores omitted older inline images in a
bounded local media cache, and replaces old inline image payloads with text
placeholders before forwarding:

```text
CODEX_OMNI_OMNIROUTE_MAX_BODY_BYTES=10485760
CODEX_OMNI_INLINE_IMAGE_HISTORY_BUDGET_BYTES=6291456
CODEX_OMNI_MEDIA_CACHE_MAX_BYTES=536870912
```

## One-click setup

For a normal Windows machine with official Codex Desktop already installed,
run:

```powershell
.\Setup.exe
```

`Setup.exe` is a self-contained bootstrapper. It runs `Setup.ps1`, installs
local .NET SDK and Node.js dependencies when needed, writes
`omniroute-provider.json`, prepares the duplicated Electron app, builds the
embedded app-server wrapper, creates Desktop/Start Menu shortcuts, and runs the
shared-home verifier. `Setup.bat` remains as a fallback when rebuilding the
executable locally.

Build or refresh the bootstrapper from source:

```powershell
.\tools\Build-SetupExe.ps1
```

## Manual usage

Install local launcher dependencies:

```powershell
.\tools\Install-CodexOmniRouteDependencies.ps1
```

The dependency setup installs the .NET SDK under
`%LOCALAPPDATA%\CodexOmniRoute\deps` when a local SDK is missing. It also
installs a local Node.js runtime when Node.js 20 or newer is not available.
The launcher uses those dependencies to start the bridge and build the Windows
app-server wrapper.

Copy `omniroute-provider.example.json` to `omniroute-provider.json` and fill in
your OmniRoute base URL and API key.

Start OmniRoute mode:

```powershell
.\Start-Codex-OmniRoute.ps1
```

Start only the bridge:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoCodex
```

Launch official Codex without OmniRoute overrides:

```powershell
.\Start-Codex-Official.ps1
```

Stop the managed bridge, stop the duplicated OmniRoute app, and clear stale
legacy environment overrides:

```powershell
.\Start-Codex-OmniRoute.ps1 -Restore
```

## Verification

Run static and gateway checks:

```powershell
npm run check
.\verify-codex-omniroute.ps1
```

Optional live checks:

```powershell
.\verify-codex-omniroute.ps1 -Live
.\verify-codex-omniroute.ps1 -LiveCodexExec
```

`-Live` sends a real HTTP `/v1/responses` request through the bridge.
`-LiveCodexExec` runs the real Codex CLI agent path with the same shared-home
runtime overrides. Decisive GUI proof requires sending a message in the
launched duplicated Codex OmniRoute Desktop window and confirming
`main_reasoning_hits` increments in `/healthz`.

## Legacy files

`.codex-omniroute-home` may still exist on upgraded machines. It is ignored by
the shared-home gateway and remains in `.gitignore` because it can contain old
copied auth or session state. The launcher no longer seeds it, imports config
into it, or writes user-scope `CODEX_HOME` to activate it.

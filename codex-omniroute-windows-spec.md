# Codex OmniRoute Windows shared-home gateway spec

This document records the Windows architecture after the SuperCodex-style
refactor. The old Variant-3 isolated `CODEX_HOME` model is no longer the active
runtime architecture.

## Canon

- Official Codex stays official.
- Codex OmniRoute uses the same shared home as official Codex:
  `%USERPROFILE%\.codex`.
- The launcher does not seed `.codex-omniroute-home`.
- The launcher does not copy `auth.json`, `models_cache.json`, MCP config,
  plugin config, marketplace config, sessions, or connector cache into an
  isolated profile.
- The launcher does not write user-scope `CODEX_HOME` as the AppX activation
  mechanism.
- The shared `config.toml` must not get a global top-level
  `model_provider = "omniroute"` or `model_provider = "omniroute_bridge"`.
- OmniRoute mode is selected only by process-level `-c` overrides passed to the
  launched Codex process.
- Compact and dictation stay on the official Codex/OpenAI backend.
- Main reasoning and image generation/editing route through the local
  OmniRoute bridge.

## Dependency setup

The user-facing installer is `Setup.exe`. It is a self-contained bootstrapper
that runs `Setup.ps1` through built-in Windows PowerShell, installs local
dependencies, prepares the duplicated app, creates launch shortcuts, and runs
the verifier.

Build it from source with:

```powershell
.\tools\Build-SetupExe.ps1
```

The lower-level dependency installer is:

```powershell
.\tools\Install-CodexOmniRouteDependencies.ps1
```

The setup script installs the .NET SDK under
`%LOCALAPPDATA%\CodexOmniRoute\deps` when a local SDK is missing. It also
installs a local Node.js runtime when Node.js 20 or newer is not already
available. The launcher uses these dependencies to start the bridge and build
the duplicated app's embedded app-server wrapper.

## Launch path

The preferred Windows launch path is a local Electron duplicate:

```text
%LOCALAPPDATA%\CodexOmniRoute\WindowsApp\app\Codex.exe
%LOCALAPPDATA%\CodexOmniRoute\ElectronUserData
%USERPROFILE%\.codex
```

The duplicate is refreshed from the official Store package. The official
embedded CLI in the duplicate is preserved as
`resources\codex-official.exe`, and the duplicate's `resources\codex.exe` is a
small wrapper compiled from `tools\codex-appserver-wrapper.cs`. The wrapper
intercepts only `app-server` and launches:

```powershell
resources\codex-official.exe app-server `
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

This path is preferred because it gives OmniRoute a separate Electron
identity, user-data directory, and app-server process while keeping
`CODEX_HOME` shared. Direct `codex.exe app` launch remains available with
`-NoAppDuplicate`. Direct AppX activation remains a fallback exposed by
`-UseAppxActivation`, but it is not the primary mechanism because Store/AppX
activation can lose late process environment and argument context.

The launcher preserves the real profile environment:

```text
USERPROFILE
APPDATA
LOCALAPPDATA
HOME
TEMP
TMP
```

It sets process environment only for the bridge/launcher child process, not at
user scope.

## Bridge contract

The bridge listens on:

```text
http://127.0.0.1:<bridge-port>/v1
```

Routes:

| Path | Upstream | Notes |
| --- | --- | --- |
| `/v1/responses` | OmniRoute | Main reasoning. Increments `main_reasoning_hits`. |
| `/v1/chat/completions` | OmniRoute | Compatibility route. |
| `/v1/images/generations` | OmniRoute image lane | Reuses the main provider API key. |
| `/v1/images/edits` | OmniRoute image lane | Supports JSON and multipart model normalization. |
| `/v1/responses/compact` | Official Codex/OpenAI | Not rerouted to OmniRoute. |
| `/v1/audio/transcriptions`, `/transcribe` | Official Codex/OpenAI | Dictation remains official. |
| `/v1/models` | Shared `models_cache.json` | Never fetched from OmniRoute. |

Health diagnostics must expose:

- `codex_home` equal to `%USERPROFILE%\.codex`.
- `shared_home` state.
- `main_reasoning_hits`.
- `tool_adapters`.
- `image_lane`.
- `body_budget`.
- `last_reasoning_request`.

## Native tools

Native `tool_search` remains available through a bridge shim:

1. Codex sends native `{ "type": "tool_search" }`.
2. The bridge adds an upstream function tool named `omniroute_tool_search`.
3. The bridge strips native `tool_search` before forwarding to OmniRoute.
4. If the upstream calls `omniroute_tool_search`, the bridge rewrites the
   output item into Codex-native `tool_search_call` with `execution="client"`.

Native `apply_patch` remains available through the normal freeform feature
flag. The bridge also keeps a response-side adapter for upstreams that emit an
`apply_patch` function call; it rewrites the call back into a native custom tool
call. The legacy `tools\apply_patch-rewriter.mjs` watcher is not started by the
shared-home launcher and is retained only as a fallback for proven old-build
failures.

## Image lane and 10MB limit

Image generation/editing goes through the OmniRoute image lane. The bridge
normalizes OpenAI-compatible image model names to:

```text
chatgpt-web/gpt-5.3-instant
```

The 10MB request-body limit is handled before forwarding to OmniRoute:

- default max body: `10485760` bytes;
- default inline image history budget: `6291456` bytes;
- omitted inline images are cached in a bounded local media cache;
- old inline image payloads are replaced with text placeholders;
- if the request is still too large, the bridge returns `413` with a clear
  diagnostic instead of silently falling back to the official brain route.

## Legacy mechanisms removed from the active path

- `.codex-omniroute-home` as active `CODEX_HOME`.
- Seed stamp checks.
- Isolated history persistence checks.
- Copying `auth.json` or `models_cache.json`.
- Importing `[mcp_servers.*]`, `[plugins.*]`, or `[marketplaces.*]` into an
  isolated config.
- Writing user-scope `CODEX_HOME` for AppX activation.
- Temporary user-scope `PATH` taskkill shim as a normal launch mechanism.
- Treating `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe app` as the primary
  GUI path when a separate OmniRoute window is required.
- Starting the `apply_patch` wrapper watcher by default.
- Verifier rows that only prove isolated-profile behavior.

## Verification

Required static checks:

```powershell
git status --short
npm run check
node --check .\codex-openai-omniroute-bridge.mjs
node --check .\bridge-modules\tool-adapters.mjs
node --check .\bridge-modules\media-cache.mjs
```

PowerShell parser checks must be run for modified `.ps1` files.

Gateway verification:

```powershell
.\verify-codex-omniroute.ps1
```

The verifier checks the dependency setup script, shared-home bridge health,
native tool adapters, image lane, body-budget settings, safe MCP discovery
from `%USERPROFILE%\.codex\config.toml`, and the official launcher dry run.

Optional live checks:

```powershell
.\verify-codex-omniroute.ps1 -Live
.\verify-codex-omniroute.ps1 -LiveCodexExec
```

Decisive GUI proof requires launching `.\Start-Codex-OmniRoute.ps1`, sending a
real message in the duplicated Codex OmniRoute Desktop window, then checking
that `/healthz` reports `main_reasoning_hits > 0` and `codex_home` is still
the shared official home. Supporting process evidence should show the
duplicated `Codex.exe`, `CODEX_ELECTRON_USER_DATA_PATH`, wrapper
`resources\codex.exe`, and injected `resources\codex-official.exe app-server
-c ...` command line.

## SuperCodex audit reference

The refactor was audited against `lumamax/supercodex` commit:

```text
4b335b2d227fd30f1f289d592a38f5ae81c20b5e
```

The adopted Windows-relevant mechanisms are shared Codex home, process-level
provider overrides, strict official compact/dictation preservation, native
`tool_search` rewriting, native `apply_patch` rewriting, OmniRoute image lane,
and inline image compaction for the 10MB upstream limit.

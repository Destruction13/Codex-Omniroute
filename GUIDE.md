# Codex OmniRoute guide

This guide describes the shared-home gateway model. Official Codex and Codex
OmniRoute share the normal Codex state directory. OmniRoute mode is selected
only by launcher arguments for that process.

## Install

For normal Windows installs, run the one-click bootstrapper:

```powershell
.\Setup.bat
```

In a source checkout or ZIP download, `Setup.bat` runs the current Electron
installer directly from source and doesn't package `Setup.exe`. In a release
bundle without installer sources, the same bootstrapper runs the packaged
`Setup.exe`. The bootstrapper installs local dependencies, prepares the
duplicated Windows app, creates shortcuts, and runs the verifier. Use the
manual steps below only when debugging setup itself.

## Manual install

1. Install and sign in to official Codex Desktop.
2. Run `.\tools\Install-CodexOmniRouteDependencies.ps1` to install local
   launcher dependencies under `%LOCALAPPDATA%\CodexOmniRoute\deps`. The setup
   installs the .NET SDK when needed and installs Node.js 20 or newer when a
   compatible Node runtime is not already available.
3. Copy `omniroute-provider.example.json` to `omniroute-provider.json`.
4. Set `base_url` and `api_key` for your OmniRoute endpoint.

Image requests reuse the main `api_key`; the installer doesn't collect a
separate image-generation credential.

The launcher uses `%USERPROFILE%\.codex` as `CODEX_HOME`. It does not copy
`auth.json`, `models_cache.json`, MCP config, plugin cache, or sessions into an
isolated profile.

On Windows, the first desktop launch refreshes
`%LOCALAPPDATA%\CodexOmniRoute\WindowsApp`, builds the embedded app-server
wrapper with the local .NET SDK, and uses
`%LOCALAPPDATA%\CodexOmniRoute\ElectronUserData` for the duplicated app's UI
state. `CODEX_HOME` remains the shared official home.

## Launch modes

Start Codex OmniRoute:

```powershell
.\Start-Codex-OmniRoute.ps1
```

Start only the bridge:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoCodex
```

Open a specific project:

```powershell
.\Start-Codex-OmniRoute.ps1 -OpenProject C:\AI\Bots\Codex-Omniroute
```

Start official Codex:

```powershell
.\Start-Codex-Official.ps1
```

Stop the managed bridge and the duplicated OmniRoute app:

```powershell
.\Start-Codex-OmniRoute.ps1 -Restore
```

`-Restore` does not delete or rebuild `%USERPROFILE%\.codex`. It stops the
bridge, stops processes under the duplicated OmniRoute app directory, and
clears stale legacy user-scope `CODEX_HOME` values from older isolated-home
builds.

## Runtime overrides

The OmniRoute launcher injects these values into the launched process. On
Windows, the duplicated app's embedded `resources\codex.exe` wrapper adds them
only when it starts `app-server`:

```text
model_provider="omniroute"
model="gpt-5.5"
model_reasoning_effort="xhigh"
features.tool_search=true
features.apply_patch_freeform=true
model_providers.omniroute.base_url="http://127.0.0.1:<bridge-port>/v1"
model_providers.omniroute.wire_api="responses"
model_providers.omniroute.env_key="OMNIROUTE_API_KEY"
model_providers.omniroute.requires_openai_auth=true
model_providers.omniroute.supports_websockets=false
```

The shared `config.toml` must not receive a top-level
`model_provider = "omniroute"` or `model_provider = "omniroute_bridge"` from
this launcher.

## Bridge diagnostics

Open bridge health:

```powershell
Invoke-RestMethod http://127.0.0.1:20333/healthz
```

Important fields:

- `codex_home`: must equal `%USERPROFILE%\.codex`.
- `main_reasoning_hits`: increments when OmniRoute model calls hit the bridge.
- `shared_home`: reports shared config/auth/session/cache visibility.
- `tool_adapters`: reports native `tool_search` and `apply_patch` adapters.
- `image_lane`: reports OmniRoute image routing.
- `body_budget`: reports 10MB and inline-image compaction settings.

## MCP and tools

MCP configuration stays in the shared official config. The launcher does not
copy `[mcp_servers.*]`, `[plugins.*]`, or `[marketplaces.*]` into another home.

Check MCP discovery from the real shared config:

```powershell
node .\tools\mcp_probe.mjs --config "$env:USERPROFILE\.codex\config.toml" --json
```

Check a safe read-only `shadcn` call when that server is configured:

```powershell
node .\tools\mcp_probe.mjs `
  --config "$env:USERPROFILE\.codex\config.toml" `
  --server shadcn `
  --allow-sample-call `
  --call-server shadcn `
  --call-tool get_project_registries `
  --call-args-json '{}' `
  --json
```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Official Codex opens with OmniRoute settings | An old user-scope `CODEX_HOME` override is still present. | Run `.\Start-Codex-OmniRoute.ps1 -Restore`, then `.\Start-Codex-Official.ps1`. |
| `/healthz` shows `main_reasoning_hits: 0` after a GUI message | The desktop process did not receive the runtime overrides, or an existing official window was reused. | Run `.\Start-Codex-OmniRoute.ps1 -Restore`, then relaunch without `-NoAppDuplicate`. |
| The wrapper build fails | Local .NET SDK dependencies are missing or incomplete. | Run `.\tools\Install-CodexOmniRouteDependencies.ps1`, then relaunch OmniRoute. |
| MCP tools are missing | The shared official config or connector cache is stale. | Launch official Codex once, confirm tools there, then relaunch OmniRoute. |
| Image requests fail with auth errors | The service rejected the provider key for the image lane. | Confirm `api_key` is valid, then retry. |
| Requests with image history fail near 10MB | Inline image history is still too large after compaction. | Lower `CODEX_OMNI_INLINE_IMAGE_HISTORY_BUDGET_BYTES` or clear old image-heavy context. |
| `apply_patch` fails | Native freeform path is unavailable in the current build. | Use `tools\Invoke-CodexApplyPatch.ps1` as a local fallback and record the limitation. |

## Legacy cleanup

Older builds used `.codex-omniroute-home` as the active `CODEX_HOME`. The
shared-home gateway ignores that directory. It remains ignored by git because
it may contain old copied auth or session data.

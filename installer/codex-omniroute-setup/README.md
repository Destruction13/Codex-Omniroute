# Codex OmniRoute setup installer

This project builds the Windows Electron installer for Codex OmniRoute. The
installer asks for an install folder, an OmniRoute-compatible base URL, and API
keys, then runs the dependency and verification pipeline from the root project.

## Development

Use these commands from `installer/codex-omniroute-setup` while working on the
installer UI and Electron runner.

```powershell
npm run typecheck
npm run lint
npm run build
```

The UI is a Vite React app that uses shadcn/ui components. The Electron main
process lives in `src-electron`, and the rendered UI lives in `src`.

## Packaging

Build the single-file installer with this command.

```powershell
npm run package:setup
```

The command builds `release/CodexOmniRouteSetup.exe`, then copies it to the
repository root as `Setup.exe`.

## Headless smoke test

For automated smoke tests, pass Electron app arguments after a `--` separator.
The separator prevents Chromium from consuming `--headless-install`.

```powershell
.\Setup.exe -- --headless-install `
  --install-dir C:\AI\Bots\Codex-Omniroute-exe-install-test `
  --base-url http://127.0.0.1:65530/v1 `
  --api-key test-key `
  --skip-recommended `
  --skip-shortcuts `
  --no-launch
```

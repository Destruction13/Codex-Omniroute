@echo off
REM Convenience launcher: shared-home Codex OmniRoute gateway.
REM Prefers PowerShell 7+ (pwsh) when installed; falls back to built-in Windows PowerShell.
pushd "%~dp0"
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-OmniRoute.ps1" %*
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-OmniRoute.ps1" %*
)
set RC=%ERRORLEVEL%
popd
exit /b %RC%

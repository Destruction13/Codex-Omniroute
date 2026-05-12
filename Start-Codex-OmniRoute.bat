@echo off
REM Convenience launcher: official Codex binary + isolated runtime + OmniRoute bridge.
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-OmniRoute.ps1" %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%

@echo off
REM Convenience launcher: clean baseline Codex (no OmniRoute).
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-Official.ps1" %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%

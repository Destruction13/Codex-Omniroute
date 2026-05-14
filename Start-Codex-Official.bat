@echo off
REM Convenience launcher: clean baseline Codex (no OmniRoute).
REM Prefers PowerShell 7+ (pwsh) when installed; falls back to built-in Windows PowerShell.
pushd "%~dp0"
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-Official.ps1" %*
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Start-Codex-Official.ps1" %*
)
set RC=%ERRORLEVEL%
popd
exit /b %RC%

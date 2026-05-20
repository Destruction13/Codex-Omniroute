@echo off
REM Opens a clean Windows Sandbox session for Codex OmniRoute setup testing.

setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Setup-WindowsSandbox.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [windows-sandbox] Failed with exit code %RC%.
    if /I not "%CODEX_SETUP_NO_PAUSE%"=="1" pause
)
endlocal & exit /b %RC%

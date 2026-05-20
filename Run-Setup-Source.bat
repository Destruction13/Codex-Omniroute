@echo off
REM Runs the Electron setup UI from this repository without packaging Setup.exe.

setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Setup-Source.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [setup] Setup from source failed with exit code %RC%.
    echo [setup] Keep this window open and send the lines above if you need help.
    if /I not "%CODEX_SETUP_NO_PAUSE%"=="1" pause
)
endlocal & exit /b %RC%

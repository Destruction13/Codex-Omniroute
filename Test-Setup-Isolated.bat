@echo off
REM Runs Setup.bat inside a process-local isolated Windows profile sandbox.

setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Setup-Isolated.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [isolated-setup] Test failed with exit code %RC%.
    if /I not "%CODEX_SETUP_NO_PAUSE%"=="1" pause
)
endlocal & exit /b %RC%

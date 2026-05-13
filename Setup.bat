@echo off
REM First-time setup wizard. Double-click this file.
REM Checks prerequisites, asks for OmniRoute base_url + API key, writes
REM omniroute-provider.json, runs the verifier. Safe to re-run.
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Setup.ps1" %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%

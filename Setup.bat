@echo off
REM First-time setup wizard. Double-click this file.
REM Checks prerequisites, asks for OmniRoute base_url + API key, writes
REM omniroute-provider.json, runs the verifier. Safe to re-run.
REM
REM PowerShell 7+ (pwsh) is required by the launchers and verifier. If
REM pwsh is not installed, this script auto-installs it via winget --
REM no questions asked, since the project targets non-technical users.
REM If winget is unavailable or the install fails, the script falls back
REM to the built-in Windows PowerShell so setup can still proceed.

setlocal ENABLEDELAYEDEXPANSION
pushd "%~dp0"

REM ---- Detect pwsh (PowerShell 7+) --------------------------------------
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    set "PS_EXE=pwsh.exe"
    goto :run_setup
)

REM ---- pwsh missing: auto-install via winget if available ---------------
echo.
echo --------------------------------------------------------------------
echo   PowerShell 7+ (pwsh) was not found on this machine.
echo   Setup will install it for you so the launchers and verifier
echo   behave consistently. You may see a UAC prompt.
echo --------------------------------------------------------------------
echo.

where /q winget.exe
if not %ERRORLEVEL%==0 (
    echo   winget is not available on this machine, so we cannot install
    echo   PowerShell 7+ automatically. Continuing with the built-in
    echo   Windows PowerShell. If anything misbehaves, install PowerShell 7+
    echo   manually from https://aka.ms/powershell-release?tag=stable
    echo.
    set "PS_EXE=powershell.exe"
    goto :run_setup
)

echo   Running: winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements
echo.
winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements
set WINGET_RC=%ERRORLEVEL%
echo.
if not %WINGET_RC%==0 (
    echo   winget install returned exit code %WINGET_RC%. Continuing with
    echo   built-in PowerShell. You can install PowerShell 7+ manually
    echo   later from https://aka.ms/powershell-release?tag=stable
    echo.
    set "PS_EXE=powershell.exe"
    goto :run_setup
)

REM Re-detect after install; a fresh shell may be needed for PATH to refresh,
REM so also probe the canonical install path before giving up.
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    echo   PowerShell 7+ installed successfully.
    set "PS_EXE=pwsh.exe"
    goto :run_setup
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    echo   PowerShell 7+ installed successfully (resolved via canonical path).
    set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
    goto :run_setup
)
echo   PowerShell 7+ was installed but is not yet on this shell's PATH.
echo   Continuing with built-in PowerShell for this setup run. Next
echo   time you open a new terminal, pwsh will be available.
set "PS_EXE=powershell.exe"

:run_setup
echo.
echo --------------------------------------------------------------------
echo   Using PowerShell host: %PS_EXE%
echo --------------------------------------------------------------------
echo.
%PS_EXE% -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Setup.ps1" %*
set RC=%ERRORLEVEL%
popd
endlocal & exit /b %RC%

@echo off
REM First-time setup wizard. Double-click this file.
REM Checks prerequisites, asks for OmniRoute base_url + API key, writes
REM omniroute-provider.json, runs the verifier. Safe to re-run.
REM
REM PowerShell 7+ (pwsh) is recommended but not required. If pwsh is not
REM installed this script offers to install it via winget; declining or
REM lacking winget falls back to the built-in Windows PowerShell cleanly.

setlocal ENABLEDELAYEDEXPANSION
pushd "%~dp0"

REM ---- Detect pwsh (PowerShell 7+) --------------------------------------
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    set "PS_EXE=pwsh.exe"
    goto :run_setup
)

REM ---- pwsh missing: explain + offer to install via winget --------------
echo.
echo --------------------------------------------------------------------
echo   PowerShell 7+ (pwsh) was not found on this machine.
echo.
echo   Codex OmniRoute works with the built-in Windows PowerShell, but
echo   PowerShell 7+ has better Unicode handling and is the version we
echo   test against. Installing it is recommended for non-technical
echo   users so the launchers behave consistently.
echo --------------------------------------------------------------------
echo.

where /q winget.exe
if not %ERRORLEVEL%==0 (
    echo   winget is not available on this machine, so we cannot offer an
    echo   automatic install. If you want PowerShell 7+, download it from:
    echo     https://aka.ms/powershell-release?tag=stable
    echo   Otherwise the wizard will continue with the built-in PowerShell.
    echo.
    set "PS_EXE=powershell.exe"
    goto :run_setup
)

set /p PWSH_INSTALL="Install PowerShell 7+ now via winget? [y/N]: "
if /I not "%PWSH_INSTALL%"=="y" (
    echo   Skipping PowerShell 7+ install. Continuing with built-in PowerShell.
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

REM Re-detect after install; a fresh shell may be needed for PATH to refresh.
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    echo   PowerShell 7+ installed successfully.
    set "PS_EXE=pwsh.exe"
) else (
    echo   PowerShell 7+ was installed but is not yet on this shell's PATH.
    echo   Continuing with built-in PowerShell for this setup run. Next
    echo   time you open a new terminal, pwsh will be available.
    set "PS_EXE=powershell.exe"
)

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

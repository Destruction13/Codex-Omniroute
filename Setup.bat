@echo off
REM One-click setup fallback. Prefer the self-contained Setup.exe when it is
REM present; otherwise use built-in Windows PowerShell to run Setup.ps1.

setlocal
pushd "%~dp0"

if exist ".\Setup.exe" (
    ".\Setup.exe" %*
    set RC=%ERRORLEVEL%
    popd
    endlocal & exit /b %RC%
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Setup.ps1" %*
set RC=%ERRORLEVEL%
popd
endlocal & exit /b %RC%

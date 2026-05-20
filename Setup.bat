@echo off
REM One-click setup entrypoint. In a source checkout, run the Electron setup
REM directly from source so testers do not need a freshly packaged Setup.exe.
REM In a release bundle without sources, prefer the self-contained Setup.exe;
REM otherwise use built-in Windows PowerShell to run Setup.ps1.

setlocal
pushd "%~dp0"

if /I not "%CODEX_SETUP_USE_EXE%"=="1" if exist ".\installer\codex-omniroute-setup\package.json" (
    call ".\Run-Setup-Source.bat" %*
    set RC=%ERRORLEVEL%
    popd
    endlocal & exit /b %RC%
)

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

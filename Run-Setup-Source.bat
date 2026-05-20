@echo off
REM Runs the Electron setup UI from this repository without packaging Setup.exe.

setlocal EnableExtensions

set "ROOT_DIR=%~dp0"
set "APP_DIR=%ROOT_DIR%installer\codex-omniroute-setup"
set "DRY_RUN=0"

if /I "%~1"=="--dry-run" set "DRY_RUN=1"

if not exist "%APP_DIR%\package.json" (
    echo [setup] Source installer was not found at:
    echo [setup] %APP_DIR%
    exit /b 1
)

pushd "%APP_DIR%" || exit /b 1

call :ensure_node
if errorlevel 1 goto fail

if not exist ".\node_modules\.package-lock.json" (
    echo [setup] Installing Electron installer dependencies...
    call npm ci
    if errorlevel 1 goto fail
) else (
    echo [setup] Dependencies are already installed.
)

echo [setup] Building Electron installer UI...
call npm run build
if errorlevel 1 goto fail

if "%DRY_RUN%"=="1" (
    echo [setup] Dry run completed. The source installer is ready to launch.
    goto ok
)

echo [setup] Opening Codex OmniRoute setup from source...
if exist ".\node_modules\.bin\electron.cmd" (
    call ".\node_modules\.bin\electron.cmd" . %*
) else (
    call npx --no-install electron . %*
)
if errorlevel 1 goto fail

:ok
set "RC=0"
goto done

:fail
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" set "RC=1"
echo.
echo [setup] Setup from source failed with exit code %RC%.
echo [setup] Keep this window open and send the lines above if you need help.
if /I not "%CODEX_SETUP_NO_PAUSE%"=="1" pause
goto done

:done
popd
endlocal & exit /b %RC%

:ensure_node
call :check_node
if not errorlevel 1 exit /b 0

echo [setup] Node.js 20 or newer with npm is required for source setup.

where /q winget.exe
if errorlevel 1 (
    echo [setup] winget was not found. Install Node.js 20 LTS, then run Setup.bat again.
    exit /b 1
)

echo [setup] Installing Node.js LTS with winget...
winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-package-agreements --accept-source-agreements
if errorlevel 1 exit /b 1

call :refresh_path
call :check_node
if errorlevel 1 (
    echo [setup] Node.js was installed, but this command window cannot see it yet.
    echo [setup] Close this window and run Setup.bat again.
    exit /b 1
)

exit /b 0

:check_node
where /q node.exe
if errorlevel 1 exit /b 1

where /q npm.cmd
if errorlevel 1 exit /b 1

set "NODE_MAJOR="
for /f "delims=" %%V in ('node -p "Number(process.versions.node.split('.')[0])" 2^>nul') do set "NODE_MAJOR=%%V"
if not defined NODE_MAJOR exit /b 1

if %NODE_MAJOR% LSS 20 (
    echo [setup] Node.js %NODE_MAJOR% detected, but Node.js 20 or newer is required.
    exit /b 1
)

exit /b 0

:refresh_path
for /f "usebackq delims=" %%P in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$machine=[Environment]::GetEnvironmentVariable('Path','Machine'); $user=[Environment]::GetEnvironmentVariable('Path','User'); [Console]::Out.Write($machine + ';' + $user)"`) do set "PATH=%%P"
set "PATH=%ProgramFiles%\nodejs;%LOCALAPPDATA%\Programs\nodejs;%PATH%"
exit /b 0

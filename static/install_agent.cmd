@echo off
setlocal enabledelayedexpansion

echo =============================================
echo INTERNAL INSTALLER - CMD LAUNCHER
echo =============================================
echo Running from: %~dp0
echo.

set PS1_PATH=%~dp0install_agent.ps1
set PS1_URL=http://10.0.1.103:5050/static/install_agent.ps1

echo [STEP] Downloading installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -Uri '%PS1_URL%' -OutFile '%PS1_PATH%' -UseBasicParsing" ^
    || (
        echo [ERROR] Failed to download install_agent.ps1
        pause
        exit /b 1
    )

echo [OK] Installer downloaded
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%"

echo.
echo Press any key to exit...
pause >nul

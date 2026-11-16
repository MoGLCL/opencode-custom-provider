@echo off
setlocal
title OpenCode Custom Provider - GUI Installer

set "SCRIPT_DIR=%~dp0"
set "GUI_SCRIPT=%SCRIPT_DIR%installer-gui.ps1"
set "CLI_SCRIPT=%SCRIPT_DIR%install.ps1"

if not exist "%GUI_SCRIPT%" (
  if not exist "%CLI_SCRIPT%" (
    echo.
    echo [ERROR] Installer files not found next to this script.
    echo Please right-click the ZIP file -^> "Extract All..." first, then run Install-Windows.bat.
    echo.
    pause
    exit /b 1
  )
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Windows PowerShell was not found on PATH.
  pause
  exit /b 1
)

REM Double-click (no arguments): launch Dark-Mode WPF GUI cleanly with no lingering console window
if "%~1"=="" (
  if exist "%GUI_SCRIPT%" (
    start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%GUI_SCRIPT%"
    exit /b 0
  )
)

REM Explicit CLI arguments (e.g. -ConfigDir, -Quiet, -Uninstall)
set "IS_QUIET=0"
for %%A in (%*) do if /i "%%~A"=="-Quiet" set "IS_QUIET=1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLI_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%IS_QUIET%"=="1" exit /b %EXIT_CODE%
echo.
pause
exit /b %EXIT_CODE%

@echo off
setlocal
title OpenCode Custom Provider - Uninstaller

set "SCRIPT_DIR=%~dp0"
set "GUI_SCRIPT=%SCRIPT_DIR%installer-gui.ps1"
set "CLI_SCRIPT=%SCRIPT_DIR%install.ps1"

if "%~1"=="" (
  if exist "%GUI_SCRIPT%" (
    start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%GUI_SCRIPT%" -InitialTab Install
    exit /b 0
  )
)

if not exist "%CLI_SCRIPT%" (
  echo.
  echo [ERROR] Could not find install.ps1 next to this script.
  echo.
  pause
  exit /b 1
)

set "IS_QUIET=0"
for %%A in (%*) do if /i "%%~A"=="-Quiet" set "IS_QUIET=1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLI_SCRIPT%" -Uninstall %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%IS_QUIET%"=="1" exit /b %EXIT_CODE%
echo.
pause
exit /b %EXIT_CODE%

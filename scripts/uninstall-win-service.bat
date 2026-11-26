@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-win-service.ps1"
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo Uninstall failed. Press any key to close...
  pause >nul
)

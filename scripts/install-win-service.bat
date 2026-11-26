@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-win-service.ps1"
echo.
if %ERRORLEVEL% NEQ 0 (
  echo Installation failed. Press any key to close...
) else (
  echo Installation succeeded! Press any key to close...
)
pause >nul

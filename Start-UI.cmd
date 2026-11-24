@echo off
rem Double-click to start the provisioning UI. Add -Lan to receive progress reports from PCs.
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it with:
  echo     winget install --id Microsoft.PowerShell --source winget
  echo then double-click this file again.
  pause
  exit /b 1
)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-UI.ps1" %*
pause

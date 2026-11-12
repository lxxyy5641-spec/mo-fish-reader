@echo off
where pwsh >nul 2>nul
if errorlevel 1 (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0reader.ps1" %*
  exit /b %errorlevel%
)

pwsh -NoLogo -NoProfile -File "%~dp0reader.ps1" %*

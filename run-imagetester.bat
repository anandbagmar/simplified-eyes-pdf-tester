@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE="

where pwsh >nul 2>nul
if not errorlevel 1 set "POWERSHELL_EXE=pwsh"

if not defined POWERSHELL_EXE (
  where powershell >nul 2>nul
  if not errorlevel 1 set "POWERSHELL_EXE=powershell"
)

if not defined POWERSHELL_EXE (
  echo ERROR: PowerShell was not found on PATH.
  echo Install PowerShell 7 or use Windows PowerShell and try again.
  exit /b 1
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run-imagetester.ps1" %*
exit /b %ERRORLEVEL%

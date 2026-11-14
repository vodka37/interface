@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0shake-goose.ps1" %*
if errorlevel 1 (
  echo.
  pause
)
endlocal

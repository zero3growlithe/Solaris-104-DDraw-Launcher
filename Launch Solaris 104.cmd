@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch Solaris 104.ps1" %*
set "exit_code=%ERRORLEVEL%"
if not "%exit_code%"=="0" pause
exit /b %exit_code%

@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-debug.ps1" %*
exit /b %ERRORLEVEL%

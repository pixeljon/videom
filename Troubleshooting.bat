@echo off
rem Runs VideoMail with a visible console so error messages can be read.
setlocal
cd /d "%~dp0"
echo Starting VideoMail with a console window...
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0VideoMail.ps1"
echo.
echo Exit code: %errorlevel%
echo Log file: %TEMP%\VideoMail.log
pause

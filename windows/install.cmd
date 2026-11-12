@echo off
rem Runs install.ps1 without changing PowerShell's execution policy. Double-click it, or run
rem it from a terminal with the same options as install.ps1 (e.g. install.cmd -WithLocalCleanup).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 (
    echo.
    echo Installation failed. See the messages above.
)
if "%~1"=="" pause

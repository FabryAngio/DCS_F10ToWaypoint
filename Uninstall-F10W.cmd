@echo off
setlocal
title DCS F10 To Waypoint - Uninstallation
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
set "F10W_EXIT=%ERRORLEVEL%"
echo.
if not "%F10W_EXIT%"=="0" (
    echo Uninstallation failed. Read the error shown above.
) else (
    echo Uninstallation completed.
)
echo.
pause
exit /b %F10W_EXIT%

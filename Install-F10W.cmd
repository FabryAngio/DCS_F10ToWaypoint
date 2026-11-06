@echo off
setlocal
title DCS F10 To Waypoint - Installation
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "F10W_EXIT=%ERRORLEVEL%"
echo.
if not "%F10W_EXIT%"=="0" (
    echo Installation failed. Read the error shown above.
) else (
    echo Installation completed. Start DCS and press Ctrl+Shift+M in the cockpit.
)
echo.
pause
exit /b %F10W_EXIT%

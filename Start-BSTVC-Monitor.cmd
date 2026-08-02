@echo off
setlocal
set "launcher=%~dp0Start-BSTVC-Monitor.ps1"

echo Starting BSTVC Monitor...
echo The local dashboard will open after the monitor is ready.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%launcher%" %*
set "exitCode=%ERRORLEVEL%"

if not "%exitCode%"=="0" (
  echo.
  echo Startup failed. Keep this window open and read the error above.
  echo See README.md for troubleshooting.
  pause
)

endlocal & exit /b %exitCode%

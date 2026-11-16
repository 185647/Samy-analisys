@echo off
echo Installing Gold EAs into MetaTrader 5...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GoldEAs.ps1"
echo.
echo If you see FAIL above, take a screenshot of this window and send it.
pause

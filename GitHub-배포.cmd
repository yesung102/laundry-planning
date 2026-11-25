@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0publish-ledger.ps1"
if errorlevel 1 echo Deployment incomplete.
pause

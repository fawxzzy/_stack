@echo off
setlocal
for %%I in ("%~dp0..\..") do set "STACK_ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STACK_ROOT%\ops\Open-ReleaseLauncher.ps1" -StackRoot "%STACK_ROOT%"

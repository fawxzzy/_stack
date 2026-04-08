@echo off
setlocal
for %%I in ("%~dp0..\..") do set "STACK_ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STACK_ROOT%\ops\Open-StackTerminal.ps1" -Title "Mazer Production Deploy" -StackRoot "%STACK_ROOT%" -Command "pnpm run mazer:deploy:prod"

@echo off
setlocal
for %%I in ("%~dp0..\..") do set "STACK_ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STACK_ROOT%\ops\Open-StackTerminal.ps1" -Title "Mazer Dev" -StackRoot "%STACK_ROOT%" -Command "pnpm run mazer:dev" -BrowserUrl "http://127.0.0.1:5173"

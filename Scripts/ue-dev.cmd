@echo off
rem ---------------------------------------------------------------------------
rem ue-dev - launcher for ue-dev.ps1
rem
rem Exists so that callers (agents included) only ever need to remember one
rem command name. Resolving pwsh.exe is kept here, in one place: pwsh is not in
rem System32 the way powershell.exe is, and PATH differs between an interactive
rem shell and a process spawned by another application.
rem
rem   -NoProfile      a user profile would inject environment differences into
rem                   what is meant to be an unattended run
rem   -NonInteractive anything that prompts would stall the loop forever
rem ---------------------------------------------------------------------------
setlocal EnableDelayedExpansion

set "UE_DEV_PWSH="
for /f "delims=" %%I in ('where pwsh 2^>nul') do (
    if not defined UE_DEV_PWSH set "UE_DEV_PWSH=%%I"
)
if not defined UE_DEV_PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "UE_DEV_PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined UE_DEV_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "UE_DEV_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"

if not defined UE_DEV_PWSH (
    echo ue-dev: PowerShell 7 ^(pwsh.exe^) was not found. Install it from https://aka.ms/powershell 1>&2
    exit /b 127
)

"%UE_DEV_PWSH%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0ue-dev.ps1" %*
exit /b %ERRORLEVEL%

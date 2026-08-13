REM Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
REM Created by Kelly Michels · dev@evomedia.net
REM Licensed under the MIT License. See LICENSE.
REM Version: v1.0.0.0.9

@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ZStart.ps1" -Detached %*

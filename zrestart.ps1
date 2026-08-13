# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.9

# zrestart.ps1 — alias for ZKiller.ps1 (kept so both names work). All args pass through.
& (Join-Path $PSScriptRoot "ZKiller.ps1") @args
exit $LASTEXITCODE

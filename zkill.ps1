# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# zkill.ps1 — alias for ZKillOnly.ps1 (kept so both names work). All args pass through.
& (Join-Path $PSScriptRoot "ZKillOnly.ps1") @args
exit $LASTEXITCODE

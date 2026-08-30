# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.19

# zsetup_mail.ps1 — create admin@ and noreply@ mailboxes in a docker-mailserver
# container on the server, and print the DNS records + SMTP/IMAP settings to use.
#
# Usage:
#   zsetup_mail.ps1 -domain yourdomain.com [-mailHost mail.yourdomain.com] [-ec2Host <ip>] [-pemKey <path>]
#
param (
    [string]$domain   = "",
    [string]$mailHost = "",
    [string]$ec2Host  = "",
    [string]$pemKey   = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig
if (-not $ec2Host) { $ec2Host = $cfg.ec2.ip }
if (-not $pemKey)  { $pemKey  = $cfg.ec2.pemKey }

if ([string]::IsNullOrWhiteSpace($domain)) {
    Write-Host ""
    Write-Host "Usage: zsetup_mail.ps1 -domain yourdomain.com [-mailHost mail.yourdomain.com]" -ForegroundColor Yellow
    Write-Host "  Creates admin@ and noreply@ mailboxes on the server's mailserver container." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}
if (-not $mailHost) { $mailHost = "mail.$domain" }

Write-Host "=== Mail Setup Utility ===" -ForegroundColor Cyan

if (-not (Test-Path $pemKey)) {
    Write-Error "PEM key not found: $pemKey"
    exit 1
}

Write-Host "Using PEM Key: $pemKey" -ForegroundColor Gray
Write-Host "Target Host : $ec2Host" -ForegroundColor Gray
Write-Host "Domain Name : $domain" -ForegroundColor Gray

function Generate-Password {
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*"
    $random = New-Object System.Random
    $password = ""
    for ($i = 0; $i -lt 16; $i++) {
        $password += $chars[$random.Next(0, $chars.Length)]
    }
    return $password
}

$adminPassword   = Generate-Password
$noreplyPassword = Generate-Password

Write-Host "`n[1/3] Connecting to the mail server to provision mailboxes..." -ForegroundColor Yellow

$SshOpts = @("-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=no", "-i", $pemKey, "$($cfg.ec2.user)@$ec2Host")

function Exec-Remote ([string]$cmd) { & ssh @SshOpts $cmd }

Write-Host "Adding email account: admin@$domain..." -ForegroundColor Gray
Exec-Remote "sudo docker exec mailserver setup email add admin@$domain '$adminPassword'"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Account admin@$domain added successfully." -ForegroundColor Green
} else {
    Write-Warning "Could not add admin account (it might already exist or docker setup failed)."
}

Write-Host "Adding email account: noreply@$domain..." -ForegroundColor Gray
Exec-Remote "sudo docker exec mailserver setup email add noreply@$domain '$noreplyPassword'"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Account noreply@$domain added successfully." -ForegroundColor Green
} else {
    Write-Warning "Could not add noreply account (it might already exist or docker setup failed)."
}

Write-Host "`n[2/3] DNS Configuration Requirements" -ForegroundColor Yellow
Write-Host "Add or update the following records in your DNS zone for ${domain}:" -ForegroundColor Gray
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "1. MX Record (Inbound mail routing):" -ForegroundColor White
Write-Host "   - Name  : (leave blank or @)" -ForegroundColor Green
Write-Host "   - Type  : MX" -ForegroundColor Green
Write-Host "   - Value : 10 $mailHost" -ForegroundColor Yellow
Write-Host "2. TXT Record (SPF authorization):" -ForegroundColor White
Write-Host "   - Name  : (leave blank or @)" -ForegroundColor Green
Write-Host "   - Type  : TXT" -ForegroundColor Green
Write-Host "   - Value : `"v=spf1 mx ~all`"" -ForegroundColor Yellow
Write-Host "3. A Record for Webmail:" -ForegroundColor White
Write-Host "   - Name  : webmail" -ForegroundColor Green
Write-Host "   - Type  : A" -ForegroundColor Green
Write-Host "   - Value : $ec2Host" -ForegroundColor Yellow
Write-Host "4. A Record for Mail Admin:" -ForegroundColor White
Write-Host "   - Name  : mail-admin" -ForegroundColor Green
Write-Host "   - Type  : A" -ForegroundColor Green
Write-Host "   - Value : $ec2Host" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan

Write-Host "`n[3/3] Application Connection Credentials" -ForegroundColor Yellow
Write-Host "Use these connection settings in your app config or .env:" -ForegroundColor Gray
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "SMTP Hostname        : $mailHost" -ForegroundColor White
Write-Host "SMTP Port (STARTTLS) : 587" -ForegroundColor White
Write-Host "SMTP Port (SSL/TLS)  : 465" -ForegroundColor White
Write-Host "IMAP Hostname        : $mailHost" -ForegroundColor White
Write-Host "IMAP Port (SSL/TLS)  : 993" -ForegroundColor White
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Email User 1         : admin@$domain" -ForegroundColor Green
Write-Host "Password             : $adminPassword" -ForegroundColor Yellow
Write-Host ""
Write-Host "Email User 2         : noreply@$domain" -ForegroundColor Green
Write-Host "Password             : $noreplyPassword" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Completed successfully!" -ForegroundColor Green
Stop-ZTracking

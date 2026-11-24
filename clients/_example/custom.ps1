# ==============================================================
# custom.ps1 - optional one-off steps for this client
# ==============================================================
# Runs on the target PC near the end of Setup.ps1 (before Windows Update),
# as the IT admin, elevated, in Windows PowerShell 5.1.
# Only runs when "Custom script" is turned on for the client.
#
# $Client  = settings (client.json)      e.g. $Client.organization
# $Secrets = passwords (secrets.json)    never print these
#
# Anything that throws marks the "Custom script" step as failed in the
# status report; setup carries on either way.
# ==============================================================
param($Client, $Secrets)

# Example: map a shared drive for every user
# cmd /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v MapS /t REG_SZ /d "net use S: \\fileserver\shared /persistent:yes" /f'

# Example: add a network printer
# Add-Printer -ConnectionName '\\printserver\Reception'

Write-Host "Custom script for $($Client.organization): nothing to do yet."

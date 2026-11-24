#Requires -Version 7.0
<#
.SYNOPSIS
    PROVISIONING-ONLY ISO for PCs that already have Windows 11 and sit at the
    OOBE (setup) screen. No reinstall. Command-line version of the UI's Build screen.

.DESCRIPTION
    Output: dist\<client>\<batch>\<ORG>-Provision.iso
    Mount it on the IP KVM as CD-ROM, then at the OOBE screen:  Shift+F10  ->  D:\RUN <PC number>
    Works on macOS (hdiutil) and Windows (built-in IMAPI2, no ADK needed).

.EXAMPLE
    pwsh ./Build-ProvisionISO.ps1 -Client safitek -Batch b20261124-101500
#>
param(
    [string]$Client = '',
    [string]$Batch = '',
    [string]$ReportUrl = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Provisioning.psm1') -Force

if (-not $Client) {
    Write-Host "Clients: $((Get-ClientList | ForEach-Object { $_.name }) -join ', ')"
    $Client = Read-Host 'Client'
}
$r = Invoke-ProvBuild -Name $Client -Media provision -BatchId $Batch -ReportUrl $ReportUrl
Write-Host ''
$r.instructions | ForEach-Object { Write-Host "  - $_" }
Write-Host 'WARNING: the ISO contains plain-text passwords - keep it private.' -ForegroundColor Yellow

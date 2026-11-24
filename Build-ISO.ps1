#Requires -Version 7.0
<#
.SYNOPSIS
    CLEAN-INSTALL bootable ISO (wipes the disk) for one client. Windows only.
    Command-line version of the UI's Build screen.

.DESCRIPTION
    Takes a stock Windows 11 ISO, adds the client's autounattend.xml + Setup\,
    and writes dist\<client>\<batch>\Win11-<ORG>-Install.iso.
    Uses oscdimg if the Windows ADK is installed, otherwise Windows' built-in
    IMAPI2 (no ADK needed). Must run as Administrator (mounts the stock ISO).

.EXAMPLE
    pwsh ./Build-ISO.ps1 -Client safitek -Batch b20261124-101500 -StockIso D:\Win11_24H2.iso
#>
param(
    [string]$Client = '',
    [string]$Batch = '',
    [string]$StockIso = '',
    [string]$ReportUrl = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Provisioning.psm1') -Force

if (-not $Client) {
    Write-Host "Clients: $((Get-ClientList | ForEach-Object { $_.name }) -join ', ')"
    $Client = Read-Host 'Client'
}
if (-not $StockIso) { $StockIso = (Read-Host 'Path to the stock Windows 11 ISO').Trim('"') }
$r = Invoke-ProvBuild -Name $Client -Media iso -BatchId $Batch -StockIso $StockIso -ReportUrl $ReportUrl
Write-Host ''
$r.instructions | ForEach-Object { Write-Host "  - $_" }
Write-Host 'WARNING: the ISO contains plain-text passwords - keep it private.' -ForegroundColor Yellow

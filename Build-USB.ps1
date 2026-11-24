#Requires -Version 7.0
<#
.SYNOPSIS
    CLEAN-INSTALL USB folder (wipes the disk): autounattend.xml + Setup\ for one
    client. Command-line version of the UI's Build screen. macOS or Windows.

.DESCRIPTION
    Output: dist\<client>\<batch>\usb\
    Write a stock Windows 11 ISO to a USB stick (Rufus: GPT / UEFI), then copy the
    CONTENTS of that folder to the root of the stick. Edit clients in the UI
    (Start-UI) - this script no longer asks questions.

.EXAMPLE
    pwsh ./Build-USB.ps1 -Client safitek -Batch b20261124-101500
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
$r = Invoke-ProvBuild -Name $Client -Media usb -BatchId $Batch -ReportUrl $ReportUrl
Write-Host ''
$r.instructions | ForEach-Object { Write-Host "  - $_" }
Write-Host 'WARNING: autounattend.xml and Setup\secrets.json contain plain-text passwords.' -ForegroundColor Yellow

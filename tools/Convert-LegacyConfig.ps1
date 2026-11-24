#Requires -Version 7.0
<#
.SYNOPSIS
    One-time migration: clients\<name>\config.ps1 (+ packages.json, installers.json)
    -> client.json + secrets.json. The old files are kept as *.legacy.

.EXAMPLE
    pwsh ./tools/Convert-LegacyConfig.ps1            # every client that still has config.ps1
    pwsh ./tools/Convert-LegacyConfig.ps1 -Client safitek
#>
param(
    [string]$Client = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Provisioning.psm1') -Force
$clientsRoot = (Get-ProvPaths).Clients

$names = if ($Client) { @($Client) } else {
    @(Get-ChildItem $clientsRoot -Directory | Where-Object { $_.Name -ne '_example' -and (Test-Path (Join-Path $_.FullName 'config.ps1')) } | ForEach-Object Name)
}
if ($names.Count -eq 0) { Write-Host 'Nothing to convert.'; return }

foreach ($n in $names) {
    $data = Convert-LegacyClient -Name $n -Force:$Force
    $v = Test-ClientData -Client $data.client -Secrets $data.secrets -CustomScript $data.customScript
    Write-Host "[OK] $n -> client.json + secrets.json  ($(@($data.client.apps.winget).Count) winget apps, pattern $($data.client.computerNamePattern))"
    foreach ($e in $v.errors)   { Write-Host "     ERROR:   $($e.message)" -ForegroundColor Red }
    foreach ($w in $v.warnings) { Write-Host "     warning: $($w.message)" -ForegroundColor Yellow }
}

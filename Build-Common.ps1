<#
.SYNOPSIS
    Shared helpers for the Build-*.ps1 scripts. Dot-source it:  . "$PSScriptRoot\Build-Common.ps1"

    clients\<name>\   config.ps1, packages.json, installers.json (optional)
    Setup\            generic scripts, the same for every client
    dist\<name>\      build output (gitignored)
#>

$RepoRoot    = $PSScriptRoot
$ClientsRoot = Join-Path $RepoRoot 'clients'
$DistRoot    = Join-Path $RepoRoot 'dist'
$SetupSource = Join-Path $RepoRoot 'Setup'

# Generic files copied from Setup\ into every image
$GenericSetupFiles  = @('Setup.ps1', 'Launch-Setup.cmd', 'Provision-OOBE.ps1', 'Provision-OOBE.cmd')
$OptionalSetupFiles = @('Launch-Setup-GUI.ps1')

# Returns the client folder. Prompts with the list of clients if $Client is empty.
# -AllowNew creates clients\<name>\ from clients\_example\ when it does not exist.
function Resolve-Client {
    param([string]$Client, [switch]$AllowNew)

    if (-not $Client) {
        $names = @(Get-ChildItem -Path $ClientsRoot -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -ne '_example' } | ForEach-Object { $_.Name })
        if ($names.Count -gt 0) { Write-Host "Clients: $($names -join ', ')" }
        $Client = Read-Host "Client name"
    }
    $Client = $Client.Trim().ToLower()
    if (-not $Client -or $Client -eq '_example') { throw "A client name is required." }

    $dir = Join-Path $ClientsRoot $Client
    if (-not (Test-Path $dir)) {
        if (-not $AllowNew) { throw "Client folder not found: $dir  (run Build-USB.ps1 -Client $Client to create it)" }
        New-Item -ItemType Directory -Path $dir | Out-Null
        # installers.json is opt-in: copy it from _example only if the client needs it
        foreach ($f in 'config.ps1', 'packages.json') {
            Copy-Item -Path (Join-Path $ClientsRoot "_example\$f") -Destination $dir
        }
        Write-Host "[OK] Created $dir from clients\_example" -ForegroundColor Yellow
    }
    return $dir
}

function Write-CrlfFile([string]$Path, [string]$Text) {
    $Text = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Builds a ready-to-use Setup\ folder: generic scripts + this client's files.
# Only this client's config goes in - never other clients' files.
function New-SetupFolder {
    param([string]$ClientDir, [string]$Destination)

    $cfg = Join-Path $ClientDir 'config.ps1'
    if (-not (Test-Path $cfg)) { throw "Missing $cfg" }
    $Config_PackageFile = ''
    . $cfg
    if (-not $Config_PackageFile) { $Config_PackageFile = 'packages.json' }

    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($f in $GenericSetupFiles) {
        $src = Join-Path $SetupSource $f
        if (-not (Test-Path $src)) { throw "Missing Setup\$f" }
        Copy-Item $src $Destination
    }
    foreach ($f in $OptionalSetupFiles) {
        $src = Join-Path $SetupSource $f
        if (Test-Path $src) { Copy-Item $src $Destination }
    }

    Copy-Item $cfg $Destination
    $pkg = Join-Path $ClientDir $Config_PackageFile
    if (-not (Test-Path $pkg)) { throw "Missing $pkg (`$Config_PackageFile in config.ps1)" }
    Copy-Item $pkg $Destination
    $inst = Join-Path $ClientDir 'installers.json'
    if (Test-Path $inst) { Copy-Item $inst $Destination }

    # cmd.exe wants CRLF line endings
    Get-ChildItem $Destination -Filter *.cmd | ForEach-Object {
        Write-CrlfFile $_.FullName ([System.IO.File]::ReadAllText($_.FullName))
    }
}

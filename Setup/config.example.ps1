# ==============================================================
# config.ps1 - Local provisioning configuration
# ==============================================================
# HOW TO USE:
#   1. Copy this file and rename the copy to: config.ps1
#   2. Fill in your values below
#   3. Run Build-USB.ps1 - it reads this file to generate
#      autounattend.xml AND pre-fills Setup.ps1 variables
#   4. config.ps1 is gitignored - it will never be committed
#
# Any value left as "" falls back to an interactive prompt
# at runtime (Setup.ps1 only - autounattend values are required).
# ==============================================================


# --------------------------------------------------------------
# ORGANIZATION  [autounattend.xml + Setup.ps1]
# --------------------------------------------------------------
$Config_Organization = ""


# --------------------------------------------------------------
# WINDOWS EDITION  [autounattend.xml]
# --------------------------------------------------------------
# Must match exactly what is in the ISO image index.
# Common values:
#   "Windows 11 Home"
#   "Windows 11 Pro"
#   "Windows 11 Enterprise"
$Config_WindowsEdition = "Windows 11 Pro"


# --------------------------------------------------------------
# TIMEZONE  [autounattend.xml]
# --------------------------------------------------------------
# Run this on any Windows machine to list valid values:
#   Get-TimeZone -ListAvailable | Select-Object Id
# Common values:
#   "Eastern Standard Time"
#   "Central Standard Time"
#   "Mountain Standard Time"
#   "Pacific Standard Time"
#   "UTC"
$Config_Timezone = "Eastern Standard Time"


# --------------------------------------------------------------
# IT ADMIN ACCOUNT  [autounattend.xml + Setup.ps1]
# --------------------------------------------------------------
# This account is created during OOBE and hidden from the login
# screen after Setup.ps1 runs.
$Config_ITAdminUsername    = "itadmin"
$Config_ITAdminDisplayName = "IT Admin"

# Password stored only on the USB - never committed to git.
# Use a temporary password and rotate it after provisioning.
$Config_ITAdminPassword    = ""


# --------------------------------------------------------------
# PACKAGE FILE  [Setup.ps1]
# --------------------------------------------------------------
# Leave empty to default to packages.json
$Config_PackageFile = "packages.json"


# --------------------------------------------------------------
# WIFI  [Setup.ps1]
# --------------------------------------------------------------
# Configures a WPA2 WiFi profile so the machine connects
# automatically on every boot. Leave both empty to skip.
$Config_WifiSSID     = ""
$Config_WifiPassword = ""


# --------------------------------------------------------------
# TAILSCALE  [Setup.ps1]
# --------------------------------------------------------------
# Generate a reusable, pre-authorized key at:
# https://login.tailscale.com/admin/settings/keys
$Config_TailscaleAuthKey = ""


# --------------------------------------------------------------
# COMPUTER NAME  [Setup.ps1]
# --------------------------------------------------------------
# Max 15 characters, letters/numbers/hyphens only, no spaces.
# Leave empty to be prompted at runtime.
$Config_ComputerName = ""


# --------------------------------------------------------------
# END USER ACCOUNT  [Setup.ps1]
# --------------------------------------------------------------
# Leave all empty to be prompted at runtime.
# If any one of username/fullname is empty, all will be prompted.
$Config_NewUsername    = ""
$Config_NewFullName    = ""

# Plain-text password - stored only on the USB, never committed.
# Leave empty to prompt at runtime (recommended for shared configs).
$Config_NewPassword    = ""

# $true  = add to Administrators group
# $false = standard user account
$Config_NewUserIsAdmin = $false

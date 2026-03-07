# ==============================================================
# config.ps1 — Local provisioning configuration
# ==============================================================
# HOW TO USE:
#   1. Copy this file and rename the copy to: config.ps1
#   2. Fill in your values below
#   3. config.ps1 is gitignored — it will never be committed
#
# Setup.ps1 loads config.ps1 automatically if it exists in the
# same folder. Any value left empty ("") falls back to an
# interactive prompt at runtime.
# ==============================================================

# --------------------------------------------------------------
# PACKAGE FILE
# --------------------------------------------------------------
# Leave empty to default to packages.json
$Config_PackageFile = ""

# --------------------------------------------------------------
# TAILSCALE
# --------------------------------------------------------------
# Generate a reusable, pre-authorized key at:
# https://login.tailscale.com/admin/settings/keys
$Config_TailscaleAuthKey = ""

# --------------------------------------------------------------
# COMPUTER NAME
# --------------------------------------------------------------
# Max 15 characters, letters/numbers/hyphens only, no spaces.
# Leave empty to be prompted at runtime.
$Config_ComputerName = ""

# --------------------------------------------------------------
# IT ADMIN ACCOUNT — hide from login screen
# --------------------------------------------------------------
# Username of the IT admin account to hide (e.g. "ITAdmin").
# Leave empty to be prompted at runtime.
$Config_ITAdminToHide = ""

# --------------------------------------------------------------
# END USER ACCOUNT
# --------------------------------------------------------------
# Leave all empty to be prompted at runtime.
# If any one field is empty the script will prompt for all of them.

$Config_NewUsername = ""
$Config_NewFullName = ""

# Plain-text password — stored only on the USB, never committed.
# Leave empty to be prompted (recommended for shared config files).
$Config_NewPassword = ""

# Set to $true to add the new user to Administrators group,
# $false for a standard user account.
$Config_NewUserIsAdmin = $false

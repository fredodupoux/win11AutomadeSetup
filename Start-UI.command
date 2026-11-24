#!/bin/bash
# Double-click (macOS) to start the provisioning UI. Add -Lan to receive progress reports from PCs.
cd "$(dirname "$0")" || exit 1
if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is required. Install it with:"
  echo "    brew install powershell"
  echo "then double-click this file again."
  read -r -p "Press Enter to close"
  exit 1
fi
exec pwsh -NoProfile -File ./Start-UI.ps1 "$@"

# win11AutomadeSetup

> Windows 11 provisioning for small-business PCs. Onsite techs set up clients and batches of PCs in a local web app (Mac or Windows), build the media, and the PCs set themselves up: apps, Action1, accounts, WiFi, security settings, Windows Update. No code to edit per client.

---

## Quick start (onsite techs)

1. **Install PowerShell 7** (once):
   - **Mac:** `brew install powershell`
   - **Windows:** `winget install --id Microsoft.PowerShell --source winget`
2. **Get the project folder** (clone it or copy it from the shared drive).
3. **Start the UI:**
   - **Mac:** double-click `Start-UI.command`, or run `pwsh ./Start-UI.ps1`
   - **Windows:** double-click `Start-UI.cmd`, or run `pwsh .\Start-UI.ps1`

   It opens <http://localhost:8765> in your browser. Keep the window open while you work.
4. **To see PCs report their progress**, start it with `-Lan` instead: `pwsh ./Start-UI.ps1 -Lan`. On Windows, allow PowerShell through the firewall when asked.

---

## Workflow

| Step | Where | What |
|---|---|---|
| 1 | **Clients → New client** | Start from the template or copy an existing client (settings only, never passwords) |
| 2 | **Client → Settings** | Company, accounts, WiFi, Action1/Tailscale, apps, security switches, custom script. Problems show inline; **Save** |
| 3 | **Client → Batches → New batch** | e.g. *"CS desks - Nov 2026"*, `SAFITEKHT-CS-##`, PCs 1 to 12 |
| 4 | **Build** | Pick client + batch + media → **Build** → output path and per-PC instructions |
| 5 | **At each PC** | Follow the instructions (below) |
| 6 | **Client → Batches** | Each PC turns blue (in progress), then green (done) or red (failed) when the UI runs with `-Lan`; you can also set a status by hand |

### Media types

| | **Provisioning ISO** | **Clean-install USB folder** | **Clean-install ISO** |
|---|---|---|---|
| **For** | Windows 11 already installed, PC at the setup (OOBE) screen | New PC, or wipe the OEM image | Same, for KVM / VM / Ventoy |
| **Disk** | Kept (Windows, drivers, activation) | **Wiped** | **Wiped** |
| **Build on** | Mac or Windows | Mac or Windows | Windows only (no ADK needed; UI started as Administrator) |
| **Per PC** | Mount as **CD-ROM** → Shift+F10 → `D:\RUN 3` | Boot from the USB stick | Boot from the ISO |
| **Names** | From the PC number you type | Increment automatically on the stick | First name of the batch (read-only media) |

**Provisioning ISO on an IP KVM:** mount it as **CD-ROM**, not flash drive. In flash-drive mode Windows says *"The volume does not contain a recognized file system"*.

**Clean-install USB:** write a stock [Windows 11 ISO](https://www.microsoft.com/software-download/windows11) to the stick with [Rufus](https://rufus.ie) (GPT / UEFI), then copy the **contents** of the built `usb` folder to the root of the stick.

---

## What happens on each PC

```
Provisioning ISO only:  Shift+F10 → D:\RUN 3
    Provision-OOBE.ps1 → name from the batch pattern + number → C:\Setup (admins only)
    → sysprep /oobe with an answer file (no /generalize) → reboot
Clean install:  Windows installs from the answer file (autounattend.xml) → reboot

→ OOBE skipped → IT admin created → signs in automatically ONCE
→ Setup.ps1 (never prompts; each step runs on its own, failures don't stop the rest):
   System settings (name, timezone) → WiFi → wait for internet → report "started"
   → winget → Tailscale → apps (winget, direct installers, web-app shortcuts)
   → IT admin (enabled, visible) → end user (must change password)
   → security switches → Dell Command Update → Action1 → custom script
   → Windows Update (retries, never blocks) → auto sign-in OFF
   → status file + report "done"/"failed"
→ Provisioning ISO: answer files, secrets and C:\Setup removed → reboot to the sign-in screen
```

On the PC: `C:\ProgramData\Provisioning\status.json` (result per step) and `C:\ProgramData\Provisioning\logs\setup_*.log`.

---

## Client files

Each client is a folder in `clients/<name>/`. The UI edits these files. Everything except `clients/_example` is **gitignored**.

| File | Contents |
|---|---|
| `client.json` | Settings: organization, timezone, language/keyboard, computer-name pattern, accounts, WiFi, apps, feature switches, notes |
| `secrets.json` | Passwords and keys: IT admin, end user, WiFi, Tailscale auth key, Action1 agent URL |
| `custom.ps1` | Optional extra steps (printers, drives…). Runs elevated on the PC near the end, with `$Client` and `$Secrets` |
| `batches.json` | Batches of PCs, their report token, and what each PC reported |

**Feature switches** (`client.json` → `features`): `action1`, `tailscale`, `automaticUpdates`, `firewall`, `screenLockOnWake`, `remoteDesktop`, `disableSmb1`, `dellCommandUpdate` (Dell hardware only), `windowsUpdate`, `customScript`.

**Apps:** `apps.winget` (IDs from the official winget catalog, searchable in the UI), `apps.installers` (direct-download installers run as admin, e.g. SoWork with `/S`), `apps.webApps` (Chrome `--app` shortcuts for all users, e.g. WhatsApp Web). No Microsoft Store apps.

**WiFi:** WPA2-Personal, WPA3-Personal, open, hidden networks. Enterprise (802.1X) WiFi is not set up automatically.

---

## Command line (optional)

Everything the UI does is also available from a terminal:

```bash
pwsh ./Build-ProvisionISO.ps1 -Client safitek -Batch <batch-id>
pwsh ./Build-USB.ps1          -Client safitek -Batch <batch-id>
pwsh ./Build-ISO.ps1          -Client safitek -Batch <batch-id> -StockIso C:\ISO\Win11.iso   # Windows, as Administrator
pwsh ./tools/Convert-LegacyConfig.ps1      # one-time: old config.ps1 clients -> client.json + secrets.json
pwsh ./tests/Test-Provisioning.ps1 [-UI]   # automated tests (sandboxed; -UI also clicks through the UI)
```

**Backup on the PC:** `Setup\Launch-Setup-GUI.ps1` is a text menu that edits the media's `client.json` / `secrets.json` and runs `Setup.ps1`. Use it for last-minute changes on site.

---

## Project structure

```
Start-UI.ps1 / .cmd / .command   local web app (server) + double-click launchers
ui/                              web app (HTML/CSS/JS, no build step)
lib/Provisioning.psm1            shared logic: clients, validation, batches, builds, ISO, winget catalog
Build-ProvisionISO.ps1 / Build-USB.ps1 / Build-ISO.ps1   command-line builds
autounattend.template.xml        clean-install answer file template
Setup/                           runs ON THE PC (Windows PowerShell 5.1):
  Setup.ps1                        the provisioning script
  Provision-OOBE.ps1 / .cmd        provisioning ISO entry point (Shift+F10)
  Launch-Setup.cmd                 clean install: starts Setup.ps1 after first sign-in
  Launch-Setup-GUI.ps1             backup text menu
clients/                         one folder per client (gitignored except _example)
dist/<client>/<batch>/           build output (gitignored - contains passwords)
cache/                           winget catalog cache (gitignored)
tools/  tests/
PLAN.md                          what's done, what's next, what needs fixing
```

---

## Security

- The UI only answers on this computer. With `-Lan`, the network can reach **only** `/api/report`, and only with a batch's secret token. Settings and passwords never leave the computer.
- `clients/` and `dist/` hold plain-text passwords and are gitignored. Every ISO / USB folder contains them too: keep media private and delete it when the batch is done.
- Provisioning ISO: the PC deletes its copy of the secrets and answer files when setup ends.
- Auto sign-in is used once per PC to start setup, then always turned off.
- Use a temporary IT admin password per batch and rotate it afterwards.

## Tested hardware

| Model | Notes |
|---|---|
| Lenovo mini PCs (SAFITEK) | Provisioning ISO via IP KVM |
| Dell OptiPlex 3070 / 5070 MFF | Clean install; Dell Command Update handles BIOS and firmware |

---

MIT License.

<div align="center">

Made with ♥️ 🇭🇹

</div>

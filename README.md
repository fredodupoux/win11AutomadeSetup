# win11AutomadeSetup

> Automated Windows 11 provisioning for small business PCs: apps, Action1, users, WiFi, security settings and Windows Update. No clicking through OOBE, no Microsoft account.

---

## Two kinds of media, one setup script

| | **Clean install** | **Provisioning only** |
|---|---|---|
| **Use when** | New PC, or you want to wipe the OEM image | Windows 11 is already installed and the PC is at the OOBE ("Let's set things up") screen |
| **Build** | `Build-USB.ps1 -Client <name>` → USB folder, then optionally `Build-ISO.ps1 -Client <name>` → bootable ISO | `Build-ProvisionISO.ps1 -Client <name>` → small data ISO |
| **Build on** | USB folder: Mac or Windows. ISO: Windows + ADK + a stock Windows 11 ISO | Mac or Windows |
| **Disk** | **Wiped** | Kept: Windows, drivers and activation are kept |
| **Hands-on per PC** | Boot from the USB/ISO | Shift+F10 → `D:\RUN 3` |
| **Computer names** | Auto-incremented on a writable USB | PC number typed at `RUN` (ISO is read-only) |

Both end up running the same [`Setup/Setup.ps1`](Setup/Setup.ps1) with the client's `config.ps1`.

---

## Project structure

```
win11AutomadeSetup/
├── Build-USB.ps1              # clean install: answer file + USB folder for a client
├── Build-ISO.ps1 / .cmd       # clean install: bake that folder into a bootable ISO (Windows + ADK)
├── Build-ProvisionISO.ps1     # provisioning only: small ISO for PCs at the OOBE screen
├── Build-Common.ps1           # shared helpers (client selection, Setup\ staging)
├── autounattend.template.xml  # answer-file template, placeholders only
├── Setup/                     # generic scripts, the same for every client
│   ├── Setup.ps1              #   the provisioning script
│   ├── Launch-Setup.cmd       #   clean install: starts Setup.ps1 after first login
│   └── Provision-OOBE.ps1/.cmd#   provisioning only: run from Shift+F10 at OOBE
├── clients/                   # one folder per client (gitignored except _example)
│   ├── _example/              #   config.ps1, packages.json, installers.json templates
│   └── safitek/               #   config.ps1, packages.json, installers.json (optional)
└── dist/                      # build output (gitignored - contains passwords)
    └── safitek/
        ├── usb/               #   autounattend.xml + Setup\  (copy to a USB root)
        ├── Win11-*.iso        #   clean-install ISO
        └── SAFITEK-Provision.iso
```

Each image only contains **one** client's files.

---

## Client folder

`clients/<client>/`:

| File | Purpose |
|---|---|
| `config.ps1` | Organization, accounts, passwords, WiFi, computer name, Action1 URL. See the reference below |
| `packages.json` | winget apps (`winget search <app>` to find IDs) |
| `installers.json` | *Optional.* Apps not in winget: direct-download installers (machine-wide) and web apps (Chrome `--app` shortcuts for all users). No Microsoft Store apps |

New client: `pwsh ./Build-USB.ps1 -Client acme` creates `clients/acme/` from `_example` and prompts for the required values.

---

## Clean install (wipes the disk)

1. **Build the USB folder.** On Mac: `brew install powershell`, then
   ```bash
   pwsh ./Build-USB.ps1 -Client safitek
   ```
   This prompts for missing values, saves them to `clients/safitek/config.ps1` and creates `dist/safitek/usb/` (`autounattend.xml` + `Setup\`).
2. **Make the media.** Either:
   - **USB:** write a [stock Windows 11 ISO](https://www.microsoft.com/software-download/windows11) with [Rufus](https://rufus.ie) (GPT / UEFI, ISO image mode), then copy the **contents** of `dist/safitek/usb/` to the USB root. Or:
   - **Bootable ISO** (KVM / VM / Ventoy). On Windows with the ADK Deployment Tools, in an elevated PowerShell: `.\Build-ISO.ps1 -Client safitek`. It asks for the stock ISO path and writes `dist/safitek/Win11-<name>.iso`.
3. **Boot the PC from it.** Windows installs, creates the IT admin, signs in once, and ~5 minutes later `Setup.ps1` runs. It only prompts for values missing from `config.ps1`.
4. **After it finishes:** delete `autounattend.xml` and `Setup\config.ps1` from the USB (plain-text passwords). On a USB stick the computer name in `autounattend.xml` is already incremented for the next PC.

---

## Provisioning only (PC at the OOBE screen, no reinstall)

1. **Build:** `pwsh ./Build-ProvisionISO.ps1 -Client safitek` creates `dist/safitek/SAFITEK-Provision.iso`. Set the name pattern first in `config.ps1`, e.g. `$Config_ComputerName = 'SAFITEKHT-CS-01'`.
2. **Mount it on the IP KVM as CD-ROM.** In "flash drive" mode Windows says *"The volume does not contain a recognized file system"*.
3. **Per PC:** power on, wait for the OOBE screen, press **Shift+F10**, type `D:\RUN 3` (3 = PC number → `SAFITEKHT-CS-03`). The PC reboots; unmount and go to the next PC.

What happens next, on its own:

```
Provision-OOBE.ps1  (from the OOBE command prompt)
    ├─ computer name from the PC number (or a ledger + counter when run from a USB stick)
    ├─ copies this client's files to C:\Setup (Administrators-only)
    └─ sysprep /oobe /unattend   (no /generalize: Windows, drivers, activation kept)
Reboot → OOBE skipped → IT admin created → signs in automatically ONCE
    └─ Setup.ps1 -Unattended  (never prompts)
         → cleanup → reboot to the sign-in screen
```

If sysprep refuses to run, the script prints its error log and a manual fallback.

### PC already set up (OOBE done by hand)

Copy a client's staged `Setup\` folder (`dist/<client>/usb/Setup`) to the PC, open PowerShell **as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Setup.ps1
```

---

## What Setup.ps1 does

| Phase | Action |
|---|---|
| 1–3 | Load `config.ps1`, start log, check Windows 11 / admin / winget (waits for winget on a new profile) |
| 3.4 | Computer name, timezone, registered organization |
| 3.5 | WiFi profile (WPA2), then waits for internet |
| 4–5 | winget sources; Tailscale if an auth key is set |
| 6 | winget apps from `packages.json` |
| 6.5 | `installers.json`: direct-download installers and web-app shortcuts |
| 7 | IT admin account (kept enabled and **visible** on the sign-in screen); end user as standard user who must change the password at first login |
| 8 | Security settings (below) |
| 9 | Dell Command Update (Dell hardware only) |
| 10 | Action1 agent |
| 11 | Clean install from a writable USB: increment the computer name for the next PC |
| 11.5 | Windows Update, last: retries, skips drivers if they fail, falls back to Windows' own updater. A failure never stops the script |
| 12 | Summary |
| 12.5 | **Auto sign-in turned off**, stored password removed (always, every client) |
| 13 | Provisioning only: delete answer files, `config.ps1` and `C:\Setup`; reboot |

Log: `C:\Users\<itadmin>\win_setup_*.log`

---

## config.ps1 reference

| Variable | Used by | Description |
|---|---|---|
| `Config_Organization` | both | Company name |
| `Config_WindowsEdition` | clean install | Must match the ISO image name, e.g. `Windows 11 Pro` |
| `Config_Timezone` | both | Windows timezone ID (`Get-TimeZone -ListAvailable`) |
| `Config_ITAdminUsername` / `DisplayName` / `Password` | both | Local IT admin account |
| `Config_ComputerName` | both | Max 15 chars. A trailing number (`-01`) enables numbering |
| `Config_PackageFile` | Setup.ps1 | winget list in the client folder (default `packages.json`) |
| `Config_WifiSSID` / `WifiPassword` | Setup.ps1 | Optional WPA2 WiFi |
| `Config_TailscaleAuthKey` | Setup.ps1 | Optional; use `''` to skip |
| `Config_Action1AgentUrl` | Setup.ps1 | Optional Action1 agent MSI link |
| `Config_NewUsername` / `NewFullName` / `NewPassword` | Setup.ps1 | End user account; must change password at first login |
| `Config_NewUserIsAdmin` | Setup.ps1 | `$true` = Administrators, `$false` = standard user |

---

## Security settings applied

- Windows Update: automatic download and install
- Firewall on for all profiles
- Password required on wake
- Remote Desktop enabled (with firewall rule)
- SMBv1 disabled
- Auto sign-in off after setup; IT admin stays visible on the sign-in screen
- Log file readable by its owner only

## Security notes

- `clients/` (except `_example`) and `dist/` are gitignored: they hold plain-text passwords. Never commit them.
- Every USB folder and ISO in `dist/` contains passwords. Keep them private and delete them from KVM storage / USB sticks when done.
- Use a temporary IT admin password and rotate it after provisioning.

## Tested hardware

| Model | Notes |
|---|---|
| Dell OptiPlex 3070 / 5070 MFF | No driver injection needed; Dell Command Update handles BIOS and firmware |
| Lenovo mini PCs (SAFITEK) | Provisioning-only flow via IP KVM |

---

## License

MIT License: free to use, modify, and distribute.

<div align="center">

Made with ♥️ 🇭🇹

</div>

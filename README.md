# ⚡ win11AutomadeSetup

> Automated Windows 11 provisioning — from bare metal to ready-to-use in one boot. No clicking through OOBE, no OEM bloat, no Microsoft account required.

---

## Overview

This project gives you **two ways** to provision a fresh Windows 11 machine with apps, security settings, VPN, and user accounts — all scripted, all repeatable.

| | Option A — Full Reinstall | Option B — Existing Install |
|---|---|---|
| **When to use** | New machine, wipe OEM image | Machine already has Windows 11 |
| **OOBE bypass** | ✅ Fully automated | ⚠️ Manual (see below) |
| **Hands-on time** | ~5 min setup, walk away | ~10 min |
| **OEM bloat** | ❌ Gone | ⚠️ Still there |
| **What you need** | USB drive + Windows 11 ISO | USB/network share |

---

## 📁 Project Structure

```
win11AutomadeSetup/
├── autounattend.xml          # Unattended answer file (Option A — USB reinstall)
├── Setup/
│   ├── Setup.ps1             # Provisioning script (both options)
│   ├── packages.json         # App list for winget
│   ├── config.example.ps1   # Config template — copy to config.ps1 and fill in
│   └── config.ps1            # Your local secrets (gitignored, never committed)
└── README.md
```

---

## 🚀 How to Use

### Option A — Full Reinstall via USB *(recommended)*

This wipes the drive and installs a clean Windows 11 with zero interaction. Boot the USB, walk away, come back to a provisioned machine.

#### Step 1 — Prepare the USB

1. Download the [Windows 11 ISO](https://www.microsoft.com/software-download/windows11) from Microsoft
2. Download [Rufus](https://rufus.ie) and write the ISO to a USB drive (8 GB+)
   - Partition scheme: **GPT**
   - Target system: **UEFI (non-CSM)**
   - Leave all other defaults, click **START**
   - When prompted, choose **"Write in ISO image mode"**
3. Once done, copy these files to the **root of the USB**:

```
USB root/
├── autounattend.xml        ← copy here
└── Setup/                  ← copy this folder
    ├── Setup.ps1
    ├── packages.json
    ├── config.example.ps1
    └── config.ps1          ← your secrets (filled in, never committed)
```

#### Step 2 — Edit `autounattend.xml` before deploying

Open `autounattend.xml` and change:

| Setting | What to change | Search for |
|---|---|---|
| 🔑 ITAdmin password | Set a real temporary password | `CHANGEME_AdminPassword1!` (×3) |
| 🌍 Time zone | Match your region | `Eastern Standard Time` |
| 🏢 Organization | Your company name | `Zaboka Systems` |
| 💿 Windows edition | Home vs Pro | `Windows 11 Pro` |

> ⚠️ **Security note:** The answer file stores the password in plain text on the USB. Use a temporary password and rotate it after setup. Never commit real credentials to Git — use a `.gitignore` or a separate `autounattend.local.xml`.

#### Step 3 — Edit `packages.json`

Add or remove apps from the winget package list to match what you want installed. Each entry needs a valid winget Package Identifier.

```bash
# To find the right ID for an app:
winget search <appname>
```

#### Step 4 — Boot and walk away

1. Plug the USB into the target machine
2. Power on and boot from USB (F12 on Dell for boot menu)
3. Windows installs automatically — no interaction needed
4. Machine reboots and logs in as `ITAdmin`
5. Open **PowerShell as Administrator** and run Setup.ps1 directly from the USB:

```powershell
# Replace E: with the actual USB drive letter
powershell.exe -ExecutionPolicy Bypass -File "E:\Setup\Setup.ps1"
```

6. Follow the prompts in the PowerShell window:
   - 📦 Choose package file name
   - 🔒 Enter Tailscale auth key (optional)
   - 💻 Rename the computer
   - 👤 Create the end-user account
   - 🛡️ Security settings apply automatically

---

### Option B — Existing Windows 11 Install

Use this when the machine already has Windows 11 and you just want to run the provisioning script.

#### OOBE bypass (first, before Windows is set up)

When the machine first boots into the Windows 11 setup wizard:

**Windows 11 Pro:**
> Setup screen → *"Sign in with Microsoft"* → click **"Sign-in options"** → **"Domain join instead"** → create a local account

**Windows 11 Home:**
> Press **`Shift + F10`** to open a command prompt → type `oobe\bypassnro` → press Enter → PC restarts → choose **"I don't have internet"** → **"Continue with limited setup"** → create a local account

#### Run the provisioning script

1. Copy the `Setup/` folder to the machine (USB, network share, etc.)
2. Open **PowerShell as Administrator**
3. Run:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
cd C:\path\to\Setup
.\Setup.ps1
```

---

## 🔐 What Setup.ps1 Does

| Phase | Action |
|---|---|
| 1️⃣ Config | Collects package file name and Tailscale auth key |
| 2️⃣ Logging | Creates a timestamped log in `%USERPROFILE%` |
| 3️⃣ Pre-flight | Verifies Windows 11 build, admin rights, winget |
| 4️⃣ Packages | Updates winget sources |
| 5️⃣ VPN | Installs and authenticates Tailscale (if key provided) |
| 6️⃣ Apps | Installs all apps from `packages.json` |
| 7️⃣ Users | Hides IT admin, renames computer, creates end-user account |
| 8️⃣ Security | Auto-updates, firewall, screen lock, disables RDP, disables SMBv1, BitLocker (Pro) |
| 9️⃣ Cleanup | Displays summary, optionally deletes setup folder, prompts restart |

---

## 🖥️ Tested Hardware

| Model | Status | Driver notes |
|---|---|---|
| Dell OptiPlex 3070 MFF | ✅ Supported | No injection needed — Windows Update covers Intel I219 NIC, UHD 630, Realtek audio. Dell Command Update handles the rest. |
| Dell OptiPlex 5070 MFF | ✅ Supported | Same as above |

> 💡 **Dell users:** `Dell.CommandUpdate` is included in `packages.json`. Run it after provisioning to pull BIOS updates and any remaining drivers.

---

## 📦 Default Apps (`packages.json`)

| Category | Apps |
|---|---|
| 🌐 Browser | Google Chrome, Mozilla Firefox |
| 💬 Comms | Slack, Zoom, Microsoft Teams |
| 🕐 Productivity | Hubstaff |
| 🖥️ Remote Access | AnyDesk |
| 🔧 Utilities | 7-Zip, Notepad++, VLC |
| 🔒 Security | Bitdefender, Tailscale |
| 🖥️ Hardware | Dell Command Update |

Edit `packages.json` freely — add or remove packages to match your environment.

---

## 🛡️ Security Hardening Applied

- ✅ Windows Update set to auto-download and install
- ✅ Firewall enabled on all profiles (Domain, Public, Private)
- ✅ Password required on wake / screen lock
- ✅ Remote Desktop enabled (with firewall rule)
- ✅ SMBv1 disabled
- ✅ BitLocker enabled on C: (Windows Pro/Enterprise only)
- ✅ IT admin account hidden from login screen
- ✅ Log file permissions restricted to owner only

---

## 🤝 Contributing

Pull requests are welcome! If you test on new hardware or add support for additional Dell models, open a PR with your results.

1. Fork the repo
2. Create a branch: `git checkout -b feature/your-feature`
3. Commit and push
4. Open a Pull Request

---

## 📄 License

MIT License — free to use, modify, and distribute.

---

<div align="center">

Made with ♥️ 🇭🇹

</div>

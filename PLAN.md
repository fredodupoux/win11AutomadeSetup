# Project plan & tracker

Single place to see **what's done, what's next, and what needs fixing**.
Update this file in the same commit as the work it describes.

**Status:** ✅ done · 🔄 in progress · ⬜ to do · 🧪 done but needs a hardware test · ❌ dropped

**Last updated:** 2026-11-24

---

## Goal

Onsite techs (Mac **or** Windows) set up a new client or a new batch of PCs from a UI.
They should never have to edit code. Every client-specific choice is data. Rare one-off
needs go in an optional per-client script.

## Decisions

| # | Decision | Date |
|---|---|---|
| D1 | The UI must run on **macOS and Windows** and be usable by onsite techs | 2026-11-24 |
| D2 | Passwords/keys live in a per-client **`secrets.json`** (gitignored), separate from settings | 2026-11-24 |
| D3 | Keep `Setup/Launch-Setup-GUI.ps1` (on-device text menu) as a **backup** tool | 2026-11-24 |
| D4 | Each client can have an optional **custom script** for one-off steps (printers, drives…) | 2026-11-24 |
| D5 | **No Microsoft Store apps**: winget, direct installers, or Chrome web-app shortcuts only | 2026-11-24 |
| D6 | **Auto sign-in is never left on** after setup (it signs in once so Setup.ps1 can run, then turns off) | 2026-11-24 |
| D7 | Two media types: **clean install** (wipes disk) and **provisioning only** (PC at OOBE, mounted as CD-ROM) | 2026-11-24 |
| D8 | Stack: **PowerShell 7 (`pwsh`)** for the UI server + existing build scripts, so techs install one runtime on Mac and Windows. Local only (`localhost`), never hosted | proposed |

---

## Done

| | What | Commit |
|---|---|---|
| ✅ | Provisioning-only flow: Shift+F10 → `D:\RUN <n>` → sysprep `/oobe` → unattended `Setup.ps1` | `b4d92fd` |
| ✅ | `Setup.ps1 -Unattended` (no prompts), waits for winget + internet | `b4d92fd` |
| ✅ | Windows Update moved last, retries, never blocks cleanup (fix for `0x80248007`) | `b4d92fd` |
| ✅ | Non-Store apps: `installers.json` (SoWork machine-wide, WhatsApp Web shortcut) | `b4d92fd` |
| ✅ | IT admin kept visible on the sign-in screen | `b4d92fd` |
| ✅ | Per-client folders `clients/<name>/`, build output in `dist/<name>/`, one client per image | `58dfd94` |
| ✅ | Auto sign-in always turned off at the end, stored password removed | `58dfd94` |
| ✅ | Clean-install ISO no longer skips Windows Update on read-only media | `58dfd94` |
| ✅ | README rewritten around the two media types | `58dfd94` |

---

## Roadmap

### Phase 1: Client data model (no UI yet)
Turns each client into data that a UI can edit safely. Testable with the current builds.

| | ID | Task |
|---|---|---|
| ⬜ | 1.1 | Design `client.json` schema: company, accounts, WiFi, remote mgmt, apps (winget / installers / web apps), feature switches, custom script |
| ⬜ | 1.2 | `secrets.json` per client (IT admin / end user / WiFi passwords, Tailscale key, Action1 URL); gitignored |
| ⬜ | 1.3 | Feature switches instead of hard-coded steps: RDP, SMBv1 off, Dell Command Update, Windows Update, screen lock, must-change-password, Tailscale |
| ⬜ | 1.4 | Batch file: name pattern, start/end number, optional per-batch overrides (WiFi, end user), record of PC → number |
| ⬜ | 1.5 | Optional per-client custom script (`custom.ps1`), run near the end of `Setup.ps1` with its output logged |
| ⬜ | 1.6 | `Setup.ps1`, `Provision-OOBE.ps1`, `Build-*.ps1` read JSON instead of `config.ps1` |
| ⬜ | 1.7 | One-time migration: `clients/*/config.ps1` → `client.json` + `secrets.json` |
| ⬜ | 1.8 | Update `Launch-Setup-GUI.ps1` (backup tool) to the new format, then commit it |
| ⬜ | 1.9 | Hardware test: build SAFITEK from JSON and provision one PC |

### Phase 2: Cross-platform builds (techs on Windows)
| | ID | Task |
|---|---|---|
| ⬜ | 2.1 | Provisioning ISO on Windows **without the ADK** (built-in IMAPI2 instead of `oscdimg`) |
| ⬜ | 2.2 | Investigate building the clean-install (bootable) ISO without the ADK, or on macOS |
| ⬜ | 2.3 | One-line install/start instructions for techs (install `pwsh`, run the UI) on Mac and Windows |

### Phase 3: Local web UI
| | ID | Task |
|---|---|---|
| ⬜ | 3.1 | `pwsh` local server (`Start-UI.ps1`), opens the browser at `localhost`; Mac + Windows |
| ⬜ | 3.2 | Clients screen: list, new from template, duplicate |
| ⬜ | 3.3 | Client editor with checks: name ≤ 15 chars, timezone picker, password rules, required fields |
| ⬜ | 3.4 | Apps: search the real winget catalog (works offline on Mac); flag IDs that don't exist |
| ⬜ | 3.5 | Build screen: pick batch + media type → build → output path + per-PC instructions |
| ⬜ | 3.6 | Batches screen: PCs, numbers used, dates |

### Phase 4: Later
| | ID | Task |
|---|---|---|
| ⬜ | 4.1 | Each finished PC reports back (status file or Action1) → ✅ per PC on the batch screen |
| ⬜ | 4.2 | Locale/keyboard per client (answer file is hard-coded to `en-US`) |
| ⬜ | 4.3 | WPA3 / enterprise WiFi (currently WPA2-PSK only) |

---

## To verify / fix

Things already built but not yet proven on hardware, plus known issues.

| | ID | Item | Notes |
|---|---|---|---|
| 🧪 | F1 | Auto sign-in **once** after the sysprep reboot | Passwordless-only setting turned off before sysprep; confirm itsupport signs in without typing |
| 🧪 | F2 | Windows Update retry / fallback | Confirm no crash on `0x80248007`, cleanup + reboot still happen |
| 🧪 | F3 | SoWork silent install (`/S`) | `/S` is the installer type's standard switch but undocumented by SoWork; confirm it appears for `csagent` |
| 🧪 | F4 | WhatsApp Web shortcut | Icon on desktop + Start for all users; opens in its own window |
| 🧪 | F5 | Auto sign-in OFF after the final reboot | PC must stop at the sign-in screen |
| 🧪 | F6 | Clean-install ISO after the refactor | `Build-ISO.ps1 -Client safitek` on Windows + ADK, boot in a VM |
| ⬜ | F7 | PCs set up with the earlier Autologon build still sign in automatically | Run on each: `reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f` |
| ⬜ | F8 | Clean install prompts for the Tailscale key when it's blank | Treat a blank config value as "skip" (solved by 1.3) |
| ⬜ | F9 | Berling app list unknown | `clients/berling/packages.json` is a copy of the default list; confirm |
| ⬜ | F10 | SAFITEK timezone | Set to `Eastern Standard Time`; if the PCs are in Haiti, `Haiti Standard Time` exists |
| ⬜ | F11 | SAFITEK WiFi | Config uses `((( Bat Radar )))`; confirm it's the site network |
| ⬜ | F12 | Push `main` to GitHub | Local `main` is 3 commits ahead of `origin/main` |
| ⬜ | F13 | Passwords are plain text on every USB/ISO | Inherent to answer files; keep media private, delete after use. Revisit in Phase 1 |

---

## How we use this file

- **Starting work:** mark the task 🔄.
- **Finishing:** mark it ✅ (or 🧪 if it still needs a real PC) and add the commit to *Done*.
- **New bug or request:** add an `F` row (to fix) or a roadmap row; never fix silently.
- **Decisions:** add a `D` row with the date so we don't re-discuss settled questions.

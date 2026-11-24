# Project plan & tracker

Single place to see **what's done, what's next, and what needs fixing**.
Update this file in the same commit as the work it describes.

**Status:** ✅ done · 🔄 in progress · ⬜ to do · 🧪 built, needs a test on real hardware / Windows · ❌ dropped · 👤 needs a decision or action from you

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
| D8 | Stack: **PowerShell 7** for the UI server and builds (techs install one runtime). Plain HTML/JS UI, no build step. Local only (`localhost`); `-Lan` opens only `/api/report` | 2026-11-24 |
| D9 | Target-PC scripts (`Setup/*.ps1`) stay **Windows PowerShell 5.1** compatible (what a fresh Windows has); a test enforces it | 2026-11-24 |

---

## Done

| | What | Commit |
|---|---|---|
| ✅ | Provisioning-only flow: Shift+F10 → `D:\RUN <n>` → sysprep `/oobe` → unattended `Setup.ps1` | `b4d92fd` |
| ✅ | Windows Update moved last, retries, never blocks cleanup (fix for `0x80248007`) | `b4d92fd` |
| ✅ | Non-Store apps (SoWork machine-wide, WhatsApp Web shortcut); IT admin kept visible | `b4d92fd` |
| ✅ | Per-client folders, one client per image, auto sign-in always off at the end | `58dfd94` |
| ✅ | Phase 1: `client.json` / `secrets.json` / `custom.ps1` / `batches.json`, feature switches, batches, migration, JSON-based `Setup.ps1` + `Provision-OOBE.ps1`, backup menu | `2cdbc6f` |
| ✅ | Phase 2: ISO builds without the ADK (IMAPI2 on Windows, hdiutil on macOS), tech quick start | `2cdbc6f` |
| ✅ | Phase 3: local web UI (clients, editor, winget search, batches, build, system) | `2cdbc6f` |
| ✅ | Phase 4: PC progress reports + `status.json`, language/keyboard per client, WPA3/open/hidden WiFi | `2cdbc6f` |
| ✅ | Tests: 84 sandboxed checks + 17-step headless-browser UI test, all passing on macOS | `2cdbc6f` |
| ✅ | Real clients migrated locally: safitek, solima, berling (old files kept as `*.legacy`) | (local, gitignored) |

---

## Roadmap

### Phase 1: Client data model
| | ID | Task | Notes |
|---|---|---|---|
| ✅ | 1.1 | `client.json` schema | Defaults + validation in `lib/Provisioning.psm1` |
| ✅ | 1.2 | `secrets.json` per client | Never written into `client.json`; copying a client never copies secrets |
| ✅ | 1.3 | Feature switches | RDP, SMBv1, firewall, screen lock, auto updates, Dell CU, Windows Update, Action1, Tailscale, custom script |
| ✅ | 1.4 | Batches | Pattern `ACME-PC-##`, range, overrides (WiFi, end user), per-PC status |
| ✅ | 1.5 | Custom script | `custom.ps1`, runs before Windows Update; failure is reported, setup continues |
| ✅ | 1.6 | Scripts read JSON | `Setup.ps1` (rewritten: isolated steps, never prompts), `Provision-OOBE.ps1`, builds |
| ✅ | 1.7 | Migration | `tools/Convert-LegacyConfig.ps1`; run on safitek / solima / berling |
| ✅ | 1.8 | Backup menu | `Launch-Setup-GUI.ps1` edits the JSON files; old `return if` bug fixed |
| 🧪 | 1.9 | Hardware test | Build SAFITEK from the UI, provision one PC → see *To verify* F1–F5, F15 |

### Phase 2: Cross-platform builds
| | ID | Task | Notes |
|---|---|---|---|
| 🧪 | 2.1 | Provisioning ISO on Windows without the ADK | IMAPI2 implemented; not yet run on Windows (F16) |
| 🧪 | 2.2 | Clean-install ISO without the ADK | Windows: IMAPI2 with BIOS + UEFI boot (F6, F16). macOS: not possible (needs UDF for the >4 GB image) → use the USB folder |
| ✅ | 2.3 | Tech quick start | README + `Start-UI.cmd` / `Start-UI.command` (check for PowerShell 7) |

### Phase 3: Local web UI
| | ID | Task | Notes |
|---|---|---|---|
| ✅ | 3.1 | `Start-UI.ps1` server | macOS tested; Windows run pending (F16) |
| ✅ | 3.2 | Clients screen | New from template, copy of a client |
| ✅ | 3.3 | Client editor + checks | Live validation, unsaved-changes guard |
| ✅ | 3.4 | winget catalog search / ID check | Official index, cached 7 days; also warns at build time |
| ✅ | 3.5 | Build screen | Background jobs, log, output, next steps, "Show" in Finder/Explorer |
| ✅ | 3.6 | Batches screen | Per-PC tiles, manual status, auto-refresh |
| ✅ | 3.7 | Turn PC reports on/off from the UI | Build screen checkbox or System page; no restart; remembered in `cache/ui-settings.json` |

### Phase 4: Later
| | ID | Task | Notes |
|---|---|---|---|
| 🧪 | 4.1 | PCs report back | `status.json` on the PC + POST to the UI with `-Lan` (F17) |
| 🧪 | 4.2 | Locale/keyboard per client | Answer files use the client's language/keyboard |
| 🧪 | 4.3 | WPA3 WiFi | WPA3-Personal, open, hidden: done. Enterprise 802.1X: ❌ dropped (needs per-user credentials; revisit if a client needs it) |

---

## To verify / fix

| | ID | Item | Notes |
|---|---|---|---|
| 🧪 | F1 | Auto sign-in **once** after the sysprep reboot | Passwordless-only setting turned off before sysprep / in the clean-install answer file |
| 🧪 | F2 | Windows Update retry / fallback | Confirm no crash on `0x80248007`; summary + cleanup still run |
| 🧪 | F3 | SoWork silent install (`/S`) | Undocumented switch; confirm it's installed for `csagent` |
| 🧪 | F4 | WhatsApp Web shortcut | Icon on desktop + Start for all users |
| 🧪 | F5 | Auto sign-in OFF after the final reboot | PC must stop at the sign-in screen |
| 🧪 | F6 | Clean-install ISO | `Build-ISO.ps1` / UI on Windows as Administrator, boot in a VM |
| 👤 | F7 | PCs set up with the earlier Autologon build still sign in automatically | Run on each: `reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f` |
| ✅ | F8 | Clean install prompted for a blank Tailscale key | `Setup.ps1` never prompts; blank = skipped |
| 👤 | F9 | Berling app list unknown | `clients/berling` got the default list; confirm in the UI |
| 👤 | F10 | SAFITEK timezone | `Eastern Standard Time`; if the PCs are in Haiti, pick `Haiti Standard Time` in the UI |
| 👤 | F11 | SAFITEK WiFi | `((( Bat Radar )))`: confirm it's the site network |
| 👤 | F12 | Push to GitHub | `main` and `client-ui` are local only |
| ✅ | F13 | Passwords on media | Mitigated: secrets separated, never in git, deleted from the PC after a provisioning run. Media itself still holds them: keep it private |
| 👤 | F14 | Berling name pattern too long | `BERLING-PROD-PC##` gives 17 characters (Windows max 15). The UI blocks builds until it's shortened, e.g. `BERLING-PRD-##` |
| 🧪 | F15 | New `Setup.ps1` on a real PC | Rewritten (JSON, isolated steps, status file); run one PC end to end and read `C:\ProgramData\Provisioning\status.json` |
| 🧪 | F16 | UI + builds on a Windows tech machine | Start-UI, winget search (uses `winsqlite3.dll`), provisioning ISO via IMAPI2 |
| 🧪 | F17 | Progress reports over the network | UI with `-Lan`, build with "PCs report their progress", watch the batch tiles; Windows may ask to allow PowerShell through the firewall |
| ✅ | F19 | UI slow / "← Clients" did nothing / "Operation timed out" in the terminal (Safari worst) | Server waited on idle browser pre-connections one at a time; now serves whichever connection has data and drops idle ones. Regression test added |
| ✅ | F20 | Batch form vanished while typing | The batch list's 8 s auto-refresh kept running when the form opened; now stopped while a form is open. Regression test added |
| ✅ | F22 | Provisioning ISO build showed "failed" (`NotSpecified ... RemoteException`) although the ISO was fine | `hdiutil` writes an empty line to stderr, which a background job reports as an error. Tool output is now captured, and a build only fails if the job fails or returns nothing. Test added |
| 🧪 | F21 | Re-test the UI in Safari | Fixes above tested in Chrome (headless) + automated; confirm in Safari |
| 👤 | F18 | Media built before `2cdbc6f` | Old ISOs/USBs carry their own old scripts + `config.ps1` and keep working the old way, without batches/reports/status. Rebuild from the UI to get the new behaviour (e.g. `dist/safitek/SAFITEK-Provision.iso` is the old one) |

---

## How we use this file

- **Starting work:** mark the task 🔄.
- **Finishing:** mark it ✅ (or 🧪 if it still needs a real PC / Windows) and add the commit to *Done*.
- **New bug or request:** add an `F` row (to fix) or a roadmap row; never fix silently.
- **Decisions:** add a `D` row with the date so we don't re-discuss settled questions.

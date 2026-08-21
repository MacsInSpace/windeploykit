# FieldIso — HTTP Windows imaging bootstrap

**Runtime script:** `run.ps1` (served at `http/<LAN>:8080/fieldiso/run.ps1` on **Start field PXE**).

FieldIso WinPE does **not** mount catalog ISOs in WinPE. It **curl**s `install.wim` and runs **DISM /Apply-Image**. See **`docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`** (canonical agent doc).

## Flow (client)

1. iPXE loads `FieldIso.wim` + initrds: `fieldiso.url`, `iso.url`, `install.wim.url`, wimboot BCD assets.
2. Overlay `fieldiso-overlay/Windows/System32/Mount-IsoFromUrl.cmd` → live console.
3. WinPE downloads and runs **`run.ps1`** from the PXE host.
4. `run.ps1`: drivers → disk prep → curl `install.wim` → DISM → OOBD/VirtIO offline inject → **bcdboot** (QEMU/Proxmox).
5. Reboot to Windows (detach ISO; disk before PXE in Proxmox).

**Log line to verify version:** `[FieldIso] HTTP bootstrap starting (run.ps1 2026-06-24-v14)`

## PXE host prerequisites

| Requirement | Where |
| ----------- | ----- |
| Windows ISO in catalog | `http/iso/*.iso` |
| Extracted `install.wim` | `http/iso-wim/<iso-basename>/install.wim` (sidecar + **p7zip** on catalog regen) |
| `install.wim.url` initrd | `http/ISOs/urls/<slug>.install.wim.url` |
| Synced bootstrap | `http/fieldiso/run.ps1` ← repo `sidecar/pxe/fieldiso/run.ps1` |
| FieldIso.wim | `http/wim/FieldIso.wim` (download via Netboot UI or Add WIM) |

After changing `run.ps1`, `run-smb-test.ps1`, or overlay: **Stop → Start field PXE** (re-patches FieldIso overlay v12).

## SMB lab test (separate boot — guest **CLOSED FAIL**; authenticated **RETEST v5**)

**Verdict (2026-06-24):** *Guest* SMB from **Win11 WinPE → macOS share does not work** (errors 1937/1327 after full guest registry). **Full Windows on same LAN works.** FieldIso production path remains **HTTP curl + `install.wim`** — do not switch `run.ps1` to SMB.

**Retest (2026-06-25, `run-smb-test.ps1` v5):** the guest failure was a *signing-key* problem (guest has no NTLM session key → 1937). A real local account negotiates NTLMv2 and supplies that key, so the authenticated path is worth settling. v5 tries an **authenticated** `net use /user:` **before** the guest attempts.

**Run the authenticated retest (lab only):**

1. On the Mac, create a throwaway, **non-admin, read-only-share** local account (e.g. `dk_img`) — *never* the sudo/admin account.
2. Create `<pxe-store>/fieldiso-smb-test.cred` (gitignored), **two lines**: line 1 = username, line 2 = password. macOS store path: `~/.local/share/windeploykit/pxe-boot/fieldiso-smb-test.cred`.
3. **Stop → Start field PXE** (re-patches overlay v12, regens catalog rev 4, serves `http/fieldiso/smb-test.cred`, chains it as an initrd).
4. Boot the **Lab → FieldIso SMB test** entry. The log shows `RESULT: PASS … (via: authenticated …)` if it works.

The password is **masked in logs** (`***`); the cred is served over HTTP and `curl`-able on the VLAN — acceptable only because it is a low-value throwaway account. No `fieldiso-smb-test.cred` present → v5 falls back to guest only (prior behaviour).

**Not on the main PXE menu** — only in **WinDeployKit boot ISO catalog** → **Lab** → **FieldIso SMB test (macOS share)**. Optional regression harness; reversal steps in `docs/plugins/site-build/AGENT_DISCUSSIONS_SITE_BUILD_NETBOOT.md`.

**Stop → Start field PXE** after sidecar changes (regens `ISOs/menu.ipxe` + overlay v12).

Boots FieldIso.wim with `fieldiso.mode=smb-test` + `smb-test.unc`; WinPE auto-runs **`run-smb-test.ps1`** (not `run.ps1`).

**Log prefix:** `[FieldIso-SMB]` · `run-smb-test.ps1 2026-06-25-v5`

**Menu quirk (2026-06-24):** if the lab item instantly bounced back to the catalog, the generated `item` line had a literal `` `t `` instead of a tab (PowerShell single-quoted strings). Fixed with **`Format-AppPxeBootIpxeMenuItemLine`** — see **`docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`** § *iPXE menu items — PowerShell tab quirk*.

**Share target:** `http/fieldiso/smb-test.unc` → `\\<lan-ip>\DEPLOYKIT_SMB_SPIKE$` (lab spike share; trailing `$` = hidden share, not browsable but mountable by explicit UNC; change in sidecar when staging share is named).

## WinPE tools (in FieldIso.wim)

Built into WIM `System32`: `curl.exe`, `7z.exe`, `dism.exe`, PowerShell. Maintainer fetch:

```powershell
pwsh -File ./scripts/fetch-fieldiso-tools.ps1
./scripts/build-fieldiso-wim.sh   # macOS + wimlib
```

See `tools/README.txt` and `fieldiso-overlay/` (WinPE entry; overlay v10 in sidecar).

## Environment variables (WinPE)

| Variable | Purpose |
| -------- | ------- |
| `FIELDISO_APPLY_DIR` | DISM apply target (e.g. `W:\`) |
| `FIELDISO_STAGING_DIR` | `install.wim` download path if not same as apply |
| `FIELDISO_AUTO_PREP_DISK` | **on by default** (diskpart rescan + W:/S:) | `0` skip auto diskpart; `1` force |
| `FIELDISO_CONFIRM_DISK` | **on by default** (type **YES** before wipe) | `0` skip confirm (lab/automation only) |
| `FIELDISO_PREP_DISK_INDEX` | Disk index for auto prep (default `0`) |
| `FIELDISO_EFI_LETTER` | EFI partition letter (default `S`) |
| `FIELDISO_VIRTIO_ROOT` | virtio-win CD root (e.g. `D:\`) |
| `FIELDISO_IMAGE_INDEX` | WIM index (default `1`) |

## Proxmox / QEMU lab

- Attach **virtio-win** ISO as 2nd CD (**D:** — read-only; never download `install.wim` there).
- VirtIO **SCSI** disk needs **vioscsi** + **viostor** offline inject (CD or HTTP `.7z` pack).
- After imaging: boot order **virtio disk first**, detach ISO.
- **Validated 2026-06-24:** q35 + virtio-scsi → Windows 11 OOBE.

Driver pack build: `scripts/build-virtio-win-fieldiso-pack.ps1` · store layout: `fieldiso-drivers/README.md`.

## Do not use httpdisk

Unsigned `httpdisk.sys` fails on amd64 Secure Boot WinPE. Full ISO mount in WinPE is abandoned. Details: **Why we abandoned httpdisk** in `docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`.

## Related paths

| Path | Role |
| ---- | ---- |
| `sidecar/lib/PxeBootPlugin.ps1` | Store, menus, `install.wim` extract, overlay patch |
| `sidecar/pxe/fieldiso-drivers/` | OOBD seed + README |
| `packaging/p7zip-tools.json` | Runtime p7zip for PXE host |
| `packaging/pxe-fieldiso.json` | Hosted FieldIso.wim manifest |

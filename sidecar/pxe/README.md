# Field PXE bundled files (`sidecar/pxe/`)

Shipped in the app installer via `prepare-bundle-deps.ps1`.

| File | Source | Store copy |
|------|--------|------------|
| `snponly.efi` | ipxeboot build or sibling checkout | `tftp/snponly.efi` |
| `wimboot` | `vendor/binaries/pxe-wimboot/wimboot` (`scripts/fetch-wimboot.ps1`) | `http/wimboot/wimboot` |
| `x86_64-sb/` | `vendor/binaries/pxe-secure-boot-x64/x86_64-sb/` (`scripts/fetch-pxe-secure-boot.ps1`) | `tftp/x86_64-sb/` (Option 67 Secure Boot) |
| `mdt-boot-x64/` | `vendor/binaries/pxe-mdt-boot/x64/` (`scripts/fetch-mdt-boot-assets.ps1`) | `http/wim-boot/ImageDeployer*/` on WIM import |

## Platform differences (Windows vs macOS)

This plugin runs on both platforms, but the TFTP host flow is intentionally different:

| Area | Windows (School Manager on Windows) | macOS (School Manager on Mac) |
|------|--------------------------------------|--------------------------------|
| TFTP backend | Uses **Tftpd64** (downloaded by `EnsurePxeBootTftpd64`, staged under store `binaries/tftpd64/`). School Manager starts `tftpd64.exe` hidden and writes `Tftpd32.ini` from current plugin settings. | Uses bundled **dnsmasq** (`vendor/binaries/pxe-macos/dnsmasq-universal`) and generated `dnsmasq-tftp.conf` in TFTP-only mode. |
| Privilege model | Some operations require elevation (for example local account creation and firewall changes). | Starting TFTP on UDP 69 requires macOS admin elevation when services are started. TFTP files live in `~/Library/Application Support/WinDeployKit/plugins/pxe-boot/tftp`; elevation grants traverse on the `~/Library` → `pxe-boot` path so root dnsmasq can read them (see `AGENT_NOTES_PXE_BOOT.md`). |
| Firewall/network prep | School Manager attempts to create Windows Firewall allow rules for UDP 69, the configured HTTP port, and `tftpd64.exe`. | No Windows-style firewall automation path; ensure host firewall allows local TFTP/HTTP traffic used by Netboot. |
| ImageDeployer overlay credentials | Throwaway SMB credential uses local SAM format **`<COMPUTERNAME>\<user>`**. If the throwaway user cannot be created (for example not elevated), overlay auth file publishing is skipped and logged. | Throwaway SMB credential uses **`WORKGROUP\<user>`**. macOS SMB serving is also sensitive to TCC-protected folders (Downloads/Desktop/Documents). |
| Secure Boot Option 67 | Use `x86_64-sb/shimx64.efi`. | Same as Windows: `x86_64-sb/shimx64.efi`. |

## snponly.efi

Build in **ipxeboot** using `snponly-embed.ipxe` in this folder (TFTP `boot.ipxe` first, then HTTP; no WAN fallback while local-HTTP-only):

```bash
cd /path/to/ipxeboot
make bin-x86_64-efi/snponly.efi EMBED=../windeploykit/sidecar/pxe/snponly-embed.ipxe
cp src/bin-x86_64-efi/snponly.efi /path/to/windeploykit/sidecar/pxe/snponly.efi
```

Legacy builds used HTTP-only chain — clients skip the local menu when HTTP is off or unreachable.

On menu regen, School Manager also copies **`http/boot.ipxe` → `tftp/boot.ipxe`** so TFTP-first snponly can load the local menu without HTTP.

## wimboot

```powershell
pwsh -File ./scripts/fetch-wimboot.ps1
git add vendor/binaries/pxe-wimboot/ sidecar/pxe/wimboot
```

On **Start Imaging Services** (and when Netboot is enabled), School Manager syncs bundled files into the user store when the bundle hash changes, and writes `http/boot.ipxe` + **`http/ISOs/menu.ipxe`** (when ISOs + FieldIso present) from config.

## x86_64-sb (Secure Boot)

```powershell
pwsh -File ./scripts/fetch-pxe-secure-boot.ps1
git add vendor/binaries/pxe-secure-boot-x64/ sidecar/pxe/x86_64-sb/
```

Option 67 must be **`x86_64-sb/shimx64.efi`** (not `x86_64-sb/ipxe.efi`). The whole `x86_64-sb/` tree is copied to `tftp/x86_64-sb/`; `autoexec.ipxe` is mirrored there on sync.

**Config defaults** (`config.json`):
- **`defaultBootWim`** — ImageDeployer/TechTools auto wimboot; FieldIso → ISO catalog or auto ISO when **`defaultBootIso`** set
- **`defaultBootIso`** — only when FieldIso is default WIM; clear → manual ISO catalog at PXE

Changing defaults in the UI regens **boot menus only** when the ISO catalog is already fresh (`-SkipIsoCatalogRegen`); stale catalogs still get a full `http/ISOs/*` rebuild. Sidecar skips heavy FieldIso wimlib work on default-only toggles (`-SkipFieldIsoPrepare`). See **`docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`** → *Revert `-SkipIsoCatalogRegen`* if PXE misbehaves after a default change.

**Menu branding:** drop PNG files in store **`http/branding/`** (e.g. `det-branding-1920x1080.png`). Regenerated `boot.ipxe` and `ISOs/menu.ipxe` use `console --picture ${http_base}/branding/...` and the subtitle *It's not WDS. We checked with legal.*

**OOBD drivers:** seed catalog `sidecar/pxe/fieldiso-drivers/models.seed.json` creates store folders under **`http/fieldiso/drivers/Win11x64/`**. aria2 Tracker copies vendor packs (`.cab`/`.exe`/`.7z`) as-is; FieldIso WinPE extracts with bundled **7z.exe** at boot (`run.ps1`).

## FieldIso WinPE overlay

`fieldiso-overlay/Windows/System32/Mount-IsoFromUrl.cmd` is patched into FieldIso.wim via wimlib on ensure/download. **Must use blocking `cmd /k`** — `start cmd` exits the batch, winpeshl ends, WinPE reboots before httpdisk runs. Keep in sync with `ipxeboot/contrib/fieldiso/overlay/`.

## Local ISO catalog (FieldIso)

- ISO files: user store **`http/iso/`** (lowercase)
- Generated catalog: **`http/ISOs/`** — `menu.ipxe`, `catalog.json`, `urls/*.iso.url`
- Requires **FieldIso.wim** in `http/wim/` (Downloads panel or import)
- **Do not commit** ISO/WIM binaries

See **`docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`** → *Field lessons* for onsite debugging (URL encoding, BOM, imgfree, HTTP Range).

## MDT boot assets (ImageDeployer)

ImageDeployer WIMs ship without a coherent in-WIM BCD. The app bundles MDT LiteTouch boot files and copies them on import — **not** from live DeployShare$ mounts.

```powershell
pwsh -File ./scripts/fetch-mdt-boot-assets.ps1 -SourceRoot '/Volumes/DeployShare$/Boot/x64'
git add vendor/binaries/pxe-mdt-boot/ sidecar/pxe/mdt-boot-x64/
```

TechTools and other WIMs still extract BCD/boot.sdi from their own image when present.

**Do not commit large WIM files** — technicians copy boot WIMs into the store `http/wim/` folder locally.

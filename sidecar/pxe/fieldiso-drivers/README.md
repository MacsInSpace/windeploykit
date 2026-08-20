# FieldIso OOBD driver store (local HTTP)

WinPE **`run.ps1`** fetches `drivers/index.json`, matches **WMI model**, downloads a vendor pack over HTTP, extracts with **7z.exe** (in FieldIso.wim), and runs **DISM /Add-Driver** into the **offline applied image** (not pnputil-only unless no apply dir).

## Store layout

Drivers live under the user-chosen **ISO & driver root** (Settings → Downloads → *ISO & driver root*, default follows the Downloads location; macOS diverts TCC-protected bases to `~/Public/WinDeployKit/`), **not** the PXE store. Layout is **`Drivers/<Make>/<Model>/`** — ImageDeployer 1.10's publish/search convention (`Win32_ComputerSystem` Manufacturer + Model; its cache search under `Deploy$\Drivers` is `-Recurse -Depth 1`, so pre-seeded and client-downloaded packs share one tree):

```
<ISO & driver root>/Drivers/
  index.json                          ← regenerated on Start field PXE
  <Make>/<Model>/                     ← one archive per model folder (.cab .exe .7z .zip)
  _default/                           ← fallback when no WMI match
  Proxmox/VirtIO Q35/                 ← lab VMs (q35 OVMF)
  Proxmox/VirtIO i440FX/              ← legacy i440fx
```

Caddy serves this at `http://<host>:<port>/drivers/<Make>/<Model>/…` via a `/drivers/*` route (`handle_path` re-roots onto the library — no links, works across volumes). **Folder names** come from `models.seed.json` — vendor keys are Manufacturer-style (`Acer`, `LENOVO`); NSSP catalog labels are lookup metadata only. Legacy flat `Drivers/<model>/` folders are **removed** (not migrated) on the next store sync — beta clean-slate call, 2026-08-18.

## Get packs

1. **aria2 Tracker** — OOBD drivers tab; Download queues Acer/Lenovo SCCM packs into model folders.
2. **Manual** — Netboot → **Open drivers folder**; copy archive into the matching `Drivers/<Make>/<Model>/` folder.
3. **Proxmox lab** — build virtio pack from virtio-win ISO:

```powershell
# ISO already mounted at /Volumes/virtio-win-0.1.285 (or use -VirtioWinIso)
pwsh -File ./scripts/build-virtio-win-fieldiso-pack.ps1 -VirtioWinRoot /Volumes/virtio-win-0.1.285

# Copy into the ISO & driver root (adjust if you relocated it in Settings)
$dest = Join-Path $HOME 'Public/WinDeployKit/Drivers/Proxmox/VirtIO Q35'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath ./vendor/fieldiso-drivers/virtio-win-*-win11x64.7z -Destination $dest -Force
```

Then **Stop → Start field PXE** (regenerates `index.json`).

**Alternative:** attach virtio-win ISO in Proxmox as 2nd CD — `run.ps1` injects from **D:** offline on QEMU VMs even if HTTP pack extract fails.

## Proxmox WMI match

| Machine type | Typical `Win32_ComputerSystem.Model` |
| ------------ | ------------------------------------- |
| q35 (default) | `Standard PC (Q35 + ICH9, 2009)` |
| i440fx | `Standard PC (i440FX + PIIX, 1996)` |

Seed patterns: `models.seed.json` → folders `Drivers/Proxmox/VirtIO Q35/` and `Drivers/Proxmox/VirtIO i440FX/`.

## Runtime matching

1. Download `index.json` over HTTP.
2. Longest `wmiPatterns` match wins.
3. Else `Drivers/_default/` if `archiveReady`.
4. Download pack → 7z extract → recursive `.inf` scan (v12+) → DISM offline inject.

## Important

- **Do not** stage `install.wim` on **D:** — virtio ISO is read-only.
- Imaging uses **W:** (+ **S:** EFI on auto-prep VMs). See `sidecar/pxe/fieldiso/README.md`.
- Full agent detail: **`docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md`**.

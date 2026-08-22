# Vendored dnsmasq (Netboot / field PXE TFTP)

GPL-licensed [dnsmasq](https://thekelleys.org.uk/dnsmasq/) built for macOS field PXE - **TFTP only** in router mode (`port=0` in generated config).

| File | Description |
|------|-------------|
| `dnsmasq-universal` | arm64 + x86_64 (lipo) - staged to `Resources/binaries/` |
| `dnsmasq-aarch64-apple-darwin` | Apple Silicon only |
| `dnsmasq-x86_64-apple-darwin` | Intel only |
| `COPYING.dnsmasq` | GPL license text |

## Refresh

```bash
./scripts/build-dnsmasq-macos.sh
git add vendor/binaries/pxe-macos/
```

End users do **not** need Homebrew. TFTP on port 69 still requires the macOS administrator password when starting services.

## wimlib-imagex (boot asset extraction)

GPL-licensed [wimlib](https://wimlib.net/) - extracts BCD/boot.sdi/bootmgr from boot WIMs on import.

| File | Description |
|------|-------------|
| `wimlib-imagex-universal` | arm64 + x86_64 static binary - staged to `Resources/binaries/` |
| `wimlib-imagex-aarch64-apple-darwin` | Apple Silicon only |
| `wimlib-imagex-x86_64-apple-darwin` | Intel only |
| `COPYING.wimlib` | GPL license text |
| `VERSION.wimlib` | Pinned release (e.g. `1.14.5`) |

Refresh (macOS host + Xcode CLI tools):

```powershell
pwsh -File ./scripts/fetch-wimlib.ps1
git add vendor/binaries/pxe-macos/wimlib-imagex-* vendor/binaries/pxe-macos/COPYING.wimlib vendor/binaries/pxe-macos/VERSION.wimlib
```

## p7zip (install.wim extract from catalog ISOs)

LGPL-licensed [p7zip](https://sourceforge.net/projects/p7zip/) - **not bundled**, and no longer downloaded either (2026-08-22): this product fetches nothing at runtime. ISOs are read by mounting them (`hdiutil` on macOS, `Mount-DiskImage` on Windows); if a `7z` happens to be on PATH the sidecar will use it.

WinPE uses separate Windows `7z.exe` from `sidecar/pxe/fieldiso/tools/` (`fetch-fieldiso-tools.ps1`).



# Vendored release binaries (committed for GitLab / offline builds)

Prebuilt tools copied into `packaging/staged/` during `prepare-bundle-deps.ps1`.

| Path | Platform | Shipped in |
|------|----------|------------|
| `intune-macos/windeploykit-intunewin-pack-aarch64-apple-darwin` | macOS Apple Silicon | `.app` → `Resources/binaries/` |
| `intune-macos/windeploykit-intunewin-pack-x86_64-apple-darwin` | macOS Intel | `.app` → `Resources/binaries/` |
| `dialog-macos/windeploykit-dialog-universal` | macOS (Intel + Apple Silicon) | `.app` → `Resources/binaries/` (native admin/password prompts) |
| `pxe-macos/dnsmasq-universal` | macOS (Intel + Apple Silicon) | `.app` → `Resources/binaries/` (Netboot TFTP) |
| `pxe-macos/wimlib-imagex-universal` | macOS (Intel + Apple Silicon) | `.app` → `Resources/binaries/` (Netboot boot assets) |
| `pxe-wimboot/wimboot` | macOS + Windows | `resources/sidecar/pxe/wimboot` → user store on field PXE start |
| `pxe-secure-boot-x64/x86_64-sb/` | macOS + Windows | `resources/sidecar/pxe/x86_64-sb/` → `tftp/x86_64-sb/` on Netboot enable / Start Imaging Services |
| `pxe-mdt-boot/x64/` | macOS + Windows | `resources/sidecar/pxe/mdt-boot-x64/` → `http/wim-boot/<ImageDeployer*>` on import |
| `pxe-windows/wimlib/` | Windows x64 + ARM64 | `Resources/binaries/wimlib/` (Netboot boot assets) |
| *(none)* | Windows x64 TFTP | Use **Tftpd64** on the laptop — dnsmasq is not buildable for native Windows |
| `../intune-win-app-util/IntuneWinAppUtil.exe` | Windows x64 | `resources/sidecar/tools/` |

## Refresh macOS packagers

After changing `tools/windeploykit-intunewin-pack` or bumping the WrapTune submodule:

```bash
./scripts/build-intunewin-pack.sh
RID=osx-x64 ./scripts/build-intunewin-pack.sh
./scripts/sync-intune-vendor-binaries.sh
git add vendor/binaries/intune-macos/
```

## Refresh windeploykit-dialog (native macOS prompts)

Tiny AppKit helper (`tools/windeploykit-dialog/main.swift`) for admin-password / confirm / notify
dialogs — used instead of osascript, which security tooling can deny. Requires Xcode CLT.

```bash
./scripts/build-windeploykit-dialog.sh
git add vendor/binaries/dialog-macos/
```

## Refresh Netboot dnsmasq (field PXE TFTP)

```bash
./scripts/build-dnsmasq-macos.sh
git add vendor/binaries/pxe-macos/
```

## Refresh Netboot wimboot (local HTTP boot)

```powershell
pwsh -File ./scripts/fetch-wimboot.ps1
git add vendor/binaries/pxe-wimboot/ sidecar/pxe/wimboot
```

## Refresh Netboot Secure Boot TFTP tree (shimx64 + signed iPXE chain)

Built from **ipxeboot** deploy-menu (`out/tftp/x86_64-sb/`). Required for default Option 67 `x86_64-sb/shimx64.efi`.

```powershell
pwsh -File ./scripts/fetch-pxe-secure-boot.ps1 -SourceDir D:\ipxeboot\contrib\deploy-menu\out\tftp\x86_64-sb
git add vendor/binaries/pxe-secure-boot-x64/ sidecar/pxe/x86_64-sb/
```

## Refresh Netboot MDT boot assets (ImageDeployer wimboot)

Coherent BCD + boot.sdi + UEFI bootmgr from MDT LiteTouch `Boot/x64` (not live server mounts at runtime):

```powershell
pwsh -File ./scripts/fetch-mdt-boot-assets.ps1 -SourceRoot '/Volumes/DeployShare$/Boot/x64'
git add vendor/binaries/pxe-mdt-boot/ sidecar/pxe/mdt-boot-x64/
```

## Refresh Netboot wimlib-imagex (boot asset extraction)

macOS universal + Windows x64/ARM64 portable zips from [wimlib.net](https://wimlib.net/downloads/):

```powershell
pwsh -File ./scripts/fetch-wimlib.ps1
git add vendor/binaries/pxe-macos/wimlib-imagex-* vendor/binaries/pxe-macos/COPYING.wimlib vendor/binaries/pxe-macos/VERSION.wimlib
git add vendor/binaries/pxe-windows/wimlib/ vendor/binaries/pxe-wimlib/SHA256SUMS.txt
```

Requires macOS build tools for the universal binary (`bash`, `clang`, autotools). Windows zips download on any host.

Windows (Tftpd64 — no vendored dnsmasq; upstream is POSIX-only):

Install Tftpd64 on tech laptops; optional path in Netboot Settings.

## Refresh Windows Content Prep Tool

Download from [microsoft/Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) into `vendor/intune-win-app-util/IntuneWinAppUtil.exe`.

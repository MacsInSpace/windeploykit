# Session notes - 2026-08-26 - Windows ARM64 build and test pass

Machine: Windows 11 IoT Enterprise LTSC, ARM64 (Rust host aarch64-pc-windows-msvc),
pwsh 7.6.2, Node 24, VS Build Tools 2022. The MSVC ARM64 component
(Microsoft.VisualStudio.Component.VC.Tools.ARM64) was installed this session -
without it cargo fails with "linker link.exe not found" even though the x64
tools are present.

## What was verified working on Windows

- `npm run typecheck` clean.
- Every scripts/test-*.ps1 gate passes (after the two fixes below).
- Sidecar answers GetPxeBootPluginStatus over NDJSON stdio; adapter detection,
  vault registration, config store all behave.
- `package-windows.ps1 -Arch arm64 -SkipPull -NoSync -SkipPrepare` builds
  WinDeployKit_0.6.0_arm64_en-US.msi and the dist folder + zip.
- The built windeploykit.exe launches, opens its window, spawns the pwsh
  sidecar (WebView2 + pwsh children observed), closes cleanly.
- vendor/binaries/pxe-windows/wimlib/aarch64/wimlib-imagex.exe executes
  natively on ARM64 (1.14.5); tftpd64.exe present.

## Fixes made this session

1. `scripts/test-deploy-overlay.ps1`: the gate dot-sourced libs without setting
   `$script:AppSidecarProjectRoot` and without sourcing `lib/AppPlatform.ps1`,
   so two cases failed on Windows on the bare `$script:AppSidecarProjectRoot`
   and `$IsDarwin` reads (StrictMode; on macOS `$IsMacOS -or $IsDarwin`
   short-circuits before the bare read, which is why it passed there). Now sets
   the root and sources AppPlatform first, same as the sidecar entry.
2. `scripts/package-windows.ps1`: dist copy renamed the MSI with a hardcoded
   `x64` (`WinDeployKit_0.6.0_x64_en-US.msi` for an arm64 build); now uses
   `${Arch}`. Same in the generated README-INSTALL.txt text.
3. NEW `app/src-tauri/tauri.windows.conf.json`: Windows-only bundle resource
   overlay (Tauri merges platform config via RFC 7396; null removes a key).
   Drops the macOS Mach-O binaries (pxe-macos dnsmasq/wimlib, dialog-macos)
   from the Windows MSI and adds what the sidecar actually looks for on
   Windows: `vendor/binaries/pxe-windows/` (tftpd64 + wimlib x86_64/aarch64)
   and `packaging/pxe-tftpd64.json`. The main tauri.conf.json is untouched, so
   the macOS bundle is unchanged.

## x64 cross-build (same session, later)

`package-windows.ps1 -Arch x64 -SkipPull -NoSync -SkipPrepare` on this ARM64
host produces WinDeployKit_0.6.0_x64_en-US.msi (verified by extraction: x64 PE,
pxe-windows in, mac binaries out) and the exe runs under x64 emulation with its
sidecar. This needed one more fix, also applied to AdobeUpdateKit's copy:

4. `Resolve-RustBuildToolchain` in `scripts/package-windows.ps1` had two
   compounding bugs on the cross-host path. `@(list -match re) -contains $true`
   is always false (-match on an array returns the matching STRINGS), so
   `rustup toolchain install` re-ran every time; and its output was not
   suppressed, so it rode along in the function's pipeline return and the
   caller's `.RustTarget` read threw "property cannot be found". Now compares
   `.Count -gt 0` and pipes the install through `Out-Host`.

## Known-broken on Windows, NOT fixed (deliberate)

- `scripts/bootstrap-windows.ps1` is a stale USM port and cannot run: it
  dot-sources the missing `scripts/lib/BuildDownload.ps1` at line 22, then
  calls `Install-DotNetSdkIfMissing`, `scripts/build-psopenad.ps1` and
  `scripts/build-mini-player-tools.ps1` - none exist in this repo. Same
  category as the INERT prepare-bundle-deps.ps1: port properly or delete.
  Manual equivalent used this session: npm install in app/, then
  `sync-secret-vault-modules.ps1 -VerifyOnly`.
- `package-windows.ps1` line ~580 warns "PSOpenAD.psd1 not found under
  src-tauri/target" on every build - USM-era check, WDK does not ship
  PSOpenAD. Harmless noise; remove with the same deliberate cleanup.

## Open questions for the Windows bundle

- The MSI still expects pwsh 7 on PATH on target PCs (-BundlePowerShell not
  exercised; prepare-bundle-deps.ps1 is inert so that path cannot run yet).
- dnsmasq has no Windows binary vendored (`vendor\binaries\pxe-windows\
  dnsmasq.exe` is probed at PxeBootPlugin.ps1:4288 but nothing ships it);
  tftpd64 is the Windows TFTP backend, so this only matters if the dnsmasq
  path is ever preferred on Windows.

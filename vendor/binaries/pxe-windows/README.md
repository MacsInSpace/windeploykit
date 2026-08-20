# Netboot field PXE — Windows TFTP

**dnsmasq is not available on native Windows.** Upstream dnsmasq is POSIX-only; there is no supported build that produces `dnsmasq.exe` for release bundling.

| Backend | Notes |
|---------|--------|
| **Tftpd64** (Windows TFTP) | Auto-installed to store `binaries/tftpd64/` on Netboot enable / Start Imaging Services (manifest `packaging/pxe-tftpd64.json`). School Manager adds Windows Firewall allow rules for UDP 69, HTTP port, and Tftpd64.exe. Optional custom path in Settings. |
| Bundled `dnsmasq.exe` | **Not shipped** — see above. `prepare-bundle-deps.ps1` skips staging when this file is absent. |

## Release checklist (Windows installer)

1. Document Tftpd64 in field-tech setup (one-time install per laptop).
2. Optional: pre-configure `tftpd64Path` in plug-in settings JSON if using a portable copy outside Program Files.

## macOS contrast

Intel + Apple Silicon laptops get vendored dnsmasq via `./scripts/build-dnsmasq-macos.sh` → `vendor/binaries/pxe-macos/` → `Resources/binaries/dnsmasq-universal`. TFTP on port 69 still requires admin on macOS.

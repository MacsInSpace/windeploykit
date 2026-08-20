# Third-party notices

WinDeployKit invokes the following as **separate processes**; it does not link them.

| Component | Licence | How it ships |
| --- | --- | --- |
| [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) | GPLv2 | Vendored binary (`vendor/binaries/pxe-macos/`), licence text alongside |
| [wimlib](https://wimlib.net/) (`wimlib-imagex`) | GPLv3+ | Vendored binary (`vendor/binaries/pxe-macos/`, `pxe-windows/`), licence text alongside |
| [Caddy](https://caddyserver.com/) | Apache-2.0 | Downloaded at runtime |
| [aria2](https://aria2.github.io/) | GPLv2 | Downloaded at runtime |
| [iPXE](https://ipxe.org/) / wimboot | GPLv2 | Vendored EFI binaries |
| [p7zip](https://p7zip.sourceforge.net/) | LGPL | Downloaded at runtime (macOS) |
| [Tftpd64](https://pjo2.github.io/tftpd64/) | GPLv2 | Downloaded at runtime (Windows) |

**Source offer:** corresponding source for the GPL binaries above is available
from each upstream project. Where a vendored binary differs from an upstream
release, the build script used is in `scripts/`.

## Not redistributed

Microsoft components are **never** committed to this repository. You supply them:

- `boot.wim` / `install.wim` — from your own licensed Windows ISO
- `bootmgfw.efi`, `BCD`, `boot.sdi` — from your own Windows/ADK installation
- WinPE optional components — exported from your own Windows ADK install

Their use is governed by your Windows and ADK licence terms.

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
| [Microsoft.PowerShell.SecretManagement](https://github.com/PowerShell/SecretManagement) | MIT | Vendored unmodified (`vendor/psmodules/`), pinned in `vendor/psmodules.lock.json` |
| [SecretManagement.LocalVault](https://github.com/MacsInSpace/SecretManagement.LocalVault) | MIT | Vendored unmodified from the tagged release (`vendor/psmodules/`), pinned by tag, commit and SHA-256 in `vendor/psmodules.lock.json` |
| Default WinPE background (`sidecar/pxe/deploy-client/default-bg.jpg`, pebbles on stone) | Licence and source to be recorded by the maintainer before public release | Bundled, scaled to 1920 px; shown behind the deploy client only until the operator imports their own picture in Boot Images |

The two PowerShell modules are vendored rather than installed at runtime because
PSGallery is not reachable in every deployment environment. They are redistributed
byte-for-byte as published, which is why the vendor tree keeps every file from the
package including symbols - the lockfile asserts unmodified redistribution.

**Source offer:** corresponding source for the GPL binaries above is available
from each upstream project. Where a vendored binary differs from an upstream
release, the build script used is in `scripts/`.

## Not redistributed

Microsoft components are **never** committed to this repository. You supply them:

- `boot.wim` / `install.wim` - from your own licensed Windows ISO
- `bootmgfw.efi`, `BCD`, `boot.sdi` - from your own Windows/ADK installation
- WinPE optional components - exported from your own Windows ADK install

Their use is governed by your Windows and ADK licence terms.

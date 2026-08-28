# Third-party notices

WinDeployKit invokes the following as **separate processes**; it does not link them.

| Component | Licence | How it ships |
| --- | --- | --- |
| [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) | GPLv2 | Vendored binary (`vendor/binaries/pxe-macos/`), licence text alongside |
| [wimlib](https://wimlib.net/) (`wimlib-imagex`) | GPLv3+ | Vendored binary (`vendor/binaries/pxe-macos/`, `pxe-windows/`), licence text alongside |
| [Caddy](https://caddyserver.com/) | Apache-2.0 | Downloaded at runtime |
| [aria2](https://aria2.github.io/) | GPLv2 (with the OpenSSL exception; this build uses Apple TLS) | Windows: upstream release archive downloaded at setup or first use per `packaging/aria2-tools.json`. macOS: aria2 publishes no binary, so `scripts/build-aria2-macos.sh` builds it from the unmodified upstream source tarball (AppleTLS, SDK libxml2/zlib/sqlite3, no third-party libraries) and the result is vendored at `vendor/binaries/pxe-macos/aria2c-universal`, licence text alongside (`COPYING.aria2`); source offer: the exact tarball URL is in `VERSION.aria2` |
| [iPXE](https://ipxe.org/) / wimboot | GPLv2 | Vendored EFI binaries |
| [7-Zip](https://7-zip.org/) (`7zz`, `7z.exe`) | LGPL-2.1 + unRAR restriction (BSD 3-clause parts) | macOS: the upstream universal `7zz` is downloaded at setup ("Download tools") from 7-zip.org per `packaging/p7zip-tools.json`, SHA-256 verified, never bundled. WinPE: `7z.exe` from the upstream 7-Zip extra package via `scripts/fetch-winpe-tools.ps1`. Replaced the Homebrew p7zip repack on 2026-08-29 - no package manager is ever consulted |
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

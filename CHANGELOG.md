# Changelog

All notable changes to WinDeployKit. Dates are when the work landed on `main`.
The format follows Keep a Changelog; the repository is ASCII-only, so are these notes.

## Unreleased

### Added

- **Install feedback for Linux task sequences.** A Debian or Ubuntu install now shows
  up under PXE boot > imaging clients the way a WinPE deploy does. The menu handler
  pings the imaging log before it fetches the kernel (keyed by SMBIOS serial, or the
  MAC when there is none, like the WinPE client) and carries that identity on the
  kernel line; the preseed's `early_command` (autoinstall: `early-commands`) fetches
  `sidecar/pxe/linux/wdk-report.sh` from Caddy and starts it, and from then on every
  installer step is reported in words ("Partitioning the disk", "Installing the base
  system"), with the latest progress line, anything that looks like a failure, and a
  heartbeat when it is quiet. The end-of-install steps report start and finish, the
  new system gets `/etc/windeploykit/deploy.conf` (server, serial, make, model,
  sequence, session), and the first-boot unit runs the sequence's script through the
  reporter, which reports the exit code and the last lines of output. The ingest
  endpoint takes a GET form for this (`?serial=&make=&model=&session=&line=` or
  `&heartbeat=1`) because the installer's busybox wget cannot POST. Gate:
  `scripts/test-linux-install-report.ps1` drives the script under `sh` against the
  real listener. Verified on a ThinkPad 11e 5th Gen: boot ping, sixteen installer
  steps in words, end of install, and first boot reporting "the script exited 0
  after 373s" with the CampusCast installer's last lines.
- **Close to menu bar / tray**, as AdobeUpdateKit and USM have. Closing the window
  hides WinDeployKit to the macOS menu bar (Windows: the notification area) and PXE
  and the deployment share keep serving; the icon's menu has Open and Quit, a left
  click opens, and the tooltip carries the PXE URL while it serves. File > "Close to
  menu bar" (on by default, also under Settings > Window) turns it off. File > Exit
  and the tray's Quit are real exits. The glyph is the app icon's hexagon with a
  deploy arrow (`scripts/make-tray-icons.py`).

### Fixed

- **A Linux task sequence read "pending save" for ever.** The panel checked for
  `<id>.xml` only; a Debian sequence publishes `<id>.cfg` and an Ubuntu one an
  autoinstall. It now checks the name the platform actually publishes.
- **The TFTP, imaging and Caddy log panes follow their newest line**, and the Caddy
  (HTTP fetches) table lists oldest to newest like the other two instead of the
  opposite order. A pane lets go while the reader has scrolled up.

- **Debian sequences no longer stall on "Detect network hardware" on real hardware.**
  Sequence handlers now pass `hw-detect/firmware-lookup=never`. The netboot initrd has
  no firmware and an unattended machine has no USB stick, but at `priority=critical`
  d-i's check-missing-firmware took the default "load from removable media" answer and
  looped: unload and reload every driver that asked for a blob, mount every partition
  looking for media, repeat. A ThinkPad 11e 5th Gen (wired RTL8168, optional
  `rtl8168g-3.fw`) sat there for half an hour; with the argument it installed in
  twenty minutes. The Interactive entry is unchanged: it asks the question and "no"
  ends the loop.

## Unreleased - Linux task sequences (merged 2026-09-06)

Branch `feature/linux-task-sequences`. Design record: `AGENT_NOTES.md` sections
"Linux ISO boot, 2026-09-04" and "Linux task sequences, 2026-09-05"; state of play:
`docs/handover/SESSION_NOTES_2026-09-06_linux-task-sequences.md`; boot mechanics:
`sidecar/pxe/README.md`.

### Added

- **Linux ISOs on the PXE menu.** A Debian or Ubuntu ISO dropped in the library is
  mounted in place (macOS `cd9660` fallback, since `hdiutil` cannot mount hybrid ISOs)
  and its kernel and initrd are served straight off the mount. Nothing is extracted.
- **Debian installers with no ISO.** Operating Systems > Linux installers lists Debian
  13 and 12 (amd64, arm64). Add fetches the mirror's netboot kernel and initrd (about
  95 MB, SHA256-verified) and the menu entry installs from deb.debian.org, so the
  install is always current. `APP_DEBIAN_MIRROR` overrides the mirror.
- **Ubuntu installers.** Ubuntu 24.04 and 22.04 Server rows. Ubuntu 22.04+ has no
  netboot installer, so Add downloads the current live-server ISO into the library
  through Transfers (SHA256SUMS-verified); the entry boots casper off the mounted ISO
  and streams the ISO from Caddy (the target needs about 8 GB of RAM).
- **Debian task sequences** (`platform: debian`) compile to a d-i preseed published as
  `TaskSequences/<id>.cfg`; **Ubuntu task sequences** (`platform: ubuntu`) compile to a
  Subiquity autoinstall published as `TaskSequences/autoinstall/<id>/{user-data,meta-data}`.
  Install-capable Linux entries open a submenu of their platform's sequences plus
  Interactive; Interactive is preselected unless the store default is a Linux sequence.
- **Editor by platform.** The platform chosen on New decides what the editor shows;
  Windows-only sections (role, image, domain join, Win 11 checks, OOBE, local account)
  hide on a Linux sequence and the Win 11 checks hide for Server. Linux fields are
  dropdowns: locale, keymap, timezone, disk, partition recipe (Debian), storage layout
  and OpenSSH (Ubuntu), first-user source. "Linux installer" binds a sequence to a
  release and the menu filters the submenu by it.
- **First user from the vault.** Login, full name and password come from a stored
  credential (login cleaned to a Linux user name, password hashed at publish with
  crypt SHA-512 in pure .NET); a typed password is hashed on save. A "Vault..."
  shortcut sits beside the picker. Nothing in clear is stored or published.
- **First-boot script from the library.** `<library>/Scripts/` is served at `/Scripts/`
  and listed in the editor; "Custom URL..." keeps the free form. **Add...** copies a
  script in from this machine (a `#!` first line is required, CRLF and a BOM are
  normalised to LF), **Folder** opens the folder. The installer fetches the script at
  the end of the install and a one-shot systemd unit runs it once at first boot.
- **Extra packages picker.** Free text plus "Add a known package..." grouped by
  purpose (admin basics, network, VM guest tools, storage, AD join, services,
  desktops); every name exists in both the Debian and Ubuntu archives, and
  platform-specific rows show only for their platform.
- **Windows: Script by URL step.** A first-boot step that runs
  `powershell -Command "irm '<url>' | iex"` with a `.ps1` from the Scripts folder or
  any URL. Nothing is embedded, so there is no length limit. The Scripts route sends
  `Content-Type: text/plain`.
- **QEMU test harness** `scripts/test-linux-iso-boot-qemu.sh`: boots the bundled iPXE
  from a FAT disk, tiers 1-4 (menu, installer UI, network install, unattended install
  from a published sequence), Ubuntu mode, d-i syslog forwarded to the Mac,
  `WDK_LINUX_ENTRY` and `WDK_VM_RAM`.
- **Gates:** `test-linux-menu.ps1` (32 checks), `test-task-sequence-debian.ps1` (38),
  `test-task-sequence-ubuntu.ps1` (22), plus two Windows first-boot cases in
  `test-task-sequence-accounts.ps1`.

### Changed

- **Linux first-boot steps run through `bash -c`** (were `sh -c`, dash) and the editor
  calls them "End-of-install steps" with a "+ Bash" button, because that is when they
  run: in-target as root before the reboot. Verified live in QEMU.
- **Caddy routes:** `/iso-mount/<token>/` (a whole mounted ISO), `/TaskSequences/`,
  `/Scripts/`, `/linux/debian/...` and `/linux/ubuntu/cloud-config-none`.
- `AddPxeBootLinuxNetboot` has a 30-minute IPC timeout (an ISO download is queued, a
  netboot pair is fetched inline).

### Fixed

- **cloud-init read the kernel `url=` as its cloud-config** and was OOM-killed reading
  the 3.4 GB Ubuntu ISO before Subiquity saw the seed. Every Ubuntu handler carries
  `cloud-config-url=` (the seed's user-data, or an empty cloud-config on Interactive).
- **d-i asked "Force UEFI installation?"** when another OS sat on a disk in BIOS mode;
  the preseed sets `partman-efi/non_efi_system`.
- **The netinst ISO could not be the mirror.** The netboot initrd takes its storage
  drivers as udebs from the mirror and a netinst ISO omits them, so d-i reached
  partitioning with no disk. The installer now uses the internet mirror (Craig's call).
- **Long EncodedCommand steps failed silently on Windows.** cmd's line limit is 8191
  characters and an encoded step is 8/3 of its script's length. The batch and the
  first-boot log now flag an over-long step, the editor shows the encoded length in
  amber, and the Script by URL step is the fix.

### Known limits

- Secure Boot must be off for Linux entries: the bundled shim trusts the iPXE CA, not
  a distro kernel key.
- RHEL / Rocky (kickstart) is not built; it is another `platform` value and builder.
- The trixie `atomic` recipe needs about 10 GB; pick `small_disk` below that.

## 0.6.0 - 2026-08-26

First standalone release (tag `v0.6.0`): Windows deployment from macOS and Windows -
Netboot (ProxyDHCP, TFTP, HTTP, `Deploy$`), zero-copy ISO serving, boot images without
the ADK, vendor driver catalogs, Windows task sequences, monitoring and transfers. See
`docs/handover/SESSION_NOTES_2026-08-26_windows-arm64-build.md` and the "Bundle audit and
the 0.6.0 build" section of `AGENT_NOTES.md`.

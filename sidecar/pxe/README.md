# Field PXE bundled files (`sidecar/pxe/`)

Shipped in the app installer via `prepare-bundle-deps.ps1`.

| File | Source | Store copy |
|------|--------|------------|
| `snponly.efi` | ipxeboot build or sibling checkout | `tftp/snponly.efi` |
| `wimboot` | `vendor/binaries/pxe-wimboot/wimboot` (`scripts/fetch-wimboot.ps1`) | `http/wimboot/wimboot` |
| `x86_64-sb/` | `vendor/binaries/pxe-secure-boot-x64/x86_64-sb/` (`scripts/fetch-pxe-secure-boot.ps1`) | `tftp/x86_64-sb/` (Option 67 Secure Boot) |
| `mdt-boot-x64/` | `vendor/binaries/pxe-mdt-boot/x64/` (`scripts/fetch-mdt-boot-assets.ps1`) | `http/wim-boot/LiteTouch*/` on WIM import |

## Platform differences (Windows vs macOS)

This plugin runs on both platforms, but the TFTP host flow is intentionally different:

| Area | Windows (WinDeployKit on Windows) | macOS (WinDeployKit on Mac) |
|------|--------------------------------------|--------------------------------|
| TFTP backend | Uses **Tftpd64** (downloaded by `EnsurePxeBootTftpd64`, staged under store `binaries/tftpd64/`). WinDeployKit starts `tftpd64.exe` hidden and writes `Tftpd32.ini` from current plugin settings. | Uses bundled **dnsmasq** (`vendor/binaries/pxe-macos/dnsmasq-universal`) and generated `dnsmasq-tftp.conf` in TFTP-only mode. |
| Privilege model | Some operations require elevation (for example local account creation and firewall changes). | Starting TFTP on UDP 69 requires macOS admin elevation when services are started. TFTP files live in `~/Library/Application Support/WinDeployKit/plugins/pxe-boot/tftp`; elevation grants traverse on the `~/Library` -> `pxe-boot` path so root dnsmasq can read them (see `AGENT_NOTES_PXE_BOOT.md`). |
| Firewall/network prep | WinDeployKit attempts to create Windows Firewall allow rules for UDP 69, the configured HTTP port, and `tftpd64.exe`. | No Windows-style firewall automation path; ensure host firewall allows local TFTP/HTTP traffic used by Netboot. |
| Deploy overlay credentials | Throwaway SMB credential uses local SAM format **`<COMPUTERNAME>\<user>`**. If the throwaway user cannot be created (for example not elevated), overlay auth file publishing is skipped and logged. | Throwaway SMB credential uses **`WORKGROUP\<user>`**. macOS SMB serving is also sensitive to TCC-protected folders (Downloads/Desktop/Documents). |
| Secure Boot Option 67 | Use `x86_64-sb/shimx64.efi`. | Same as Windows: `x86_64-sb/shimx64.efi`. |

## snponly.efi

Build in **ipxeboot** using `snponly-embed.ipxe` in this folder (TFTP `boot.ipxe` first, then HTTP; no WAN fallback while local-HTTP-only):

```bash
cd /path/to/ipxeboot/src
# macOS native (brew binutils/gcc/x86_64-elf-gcc; see ipxeboot/contrib/macos/README.md):
make CROSS_COMPILE=x86_64-elf- HOST_CC=/opt/homebrew/opt/gcc/bin/gcc-16 \
    "HOST_CFLAGS+=-isystem ../contrib/macos/include" \
    EMBED=/path/to/windeploykit/sidecar/pxe/snponly-embed.ipxe bin-x86_64-efi/snponly.efi
cp bin-x86_64-efi/snponly.efi /path/to/windeploykit/sidecar/pxe/snponly.efi
```

Legacy builds used HTTP-only chain - clients skip the local menu when HTTP is off or unreachable.

On menu regen, WinDeployKit also copies **`http/boot.ipxe` -> `tftp/boot.ipxe`** so TFTP-first snponly can load the local menu without HTTP.

## wimboot

```powershell
pwsh -File ./scripts/fetch-wimboot.ps1
git add vendor/binaries/pxe-wimboot/ sidecar/pxe/wimboot
```

On **Start Imaging Services** (and when Netboot is enabled), WinDeployKit syncs bundled files into the user store when the bundle hash changes, and writes `http/boot.ipxe` from config.

## x86_64-sb (Secure Boot)

```powershell
pwsh -File ./scripts/fetch-pxe-secure-boot.ps1
git add vendor/binaries/pxe-secure-boot-x64/ sidecar/pxe/x86_64-sb/
```

Option 67 must be **`x86_64-sb/shimx64.efi`** (not `x86_64-sb/ipxe.efi`). The whole `x86_64-sb/` tree is copied to `tftp/x86_64-sb/`; `autoexec.ipxe` is mirrored there on sync.

**Config defaults** (`config.json`):
- **`defaultBootWim`** - the WIM PXE clients auto-boot (wimboot)

Changing defaults in the UI regenerates the boot menus.

**Menu branding:** drop PNG files in store **`http/branding/`** (e.g. `det-branding-1920x1080.png`). Regenerated `boot.ipxe` and `ISOs/menu.ipxe` use `console --picture ${http_base}/branding/...` and the subtitle *It's not WDS. We checked with legal.*

**OOBD drivers:** seed catalog `sidecar/pxe/driver-seed/models.seed.json` creates store folders under **`<library>/Drivers/`**. aria2 Tracker copies vendor packs (`.cab`/`.exe`/`.7z`) as-is; the deploy client (startnet.cmd) extracts with the injected **7z.exe** during imaging.



## MDT boot assets (LiteTouch)

MDT LiteTouch WIMs ship without a coherent in-WIM BCD. The app bundles MDT LiteTouch boot files and copies them on import - **not** from live DeployShare$ mounts.

```powershell
pwsh -File ./scripts/fetch-mdt-boot-assets.ps1 -SourceRoot '/Volumes/DeployShare$/Boot/x64'
git add vendor/binaries/pxe-mdt-boot/ sidecar/pxe/mdt-boot-x64/
```

TechTools and other WIMs still extract BCD/boot.sdi from their own image when present.

**Do not commit large WIM files** - technicians copy boot WIMs into the store `http/wim/` folder locally.

## Linux ISOs (Debian installer media)

Any library ISO without `sources/install.wim` is probed for a Linux boot layout
(`$script:AppPxeBootLinuxIsoLayouts` in `PxeBootPlugin.ps1`: Debian `install.amd/`,
`install.a64/`, Debian Live `live/`). A match is mounted like Windows media and served
whole at **`/iso-mount/<token>/`**; the menu gets one `lnx_<slug>` item per ISO whose
handler is `kernel` + `initrd` + `boot` against that route. Nothing is extracted or
copied - the files stream off the ISO 9660 volume.

macOS cannot `hdiutil attach` a Debian hybrid ISO (its Apple partition map wins and
hdiutil reports "no mountable file systems"), so `Mount-AppPxeBootIsoReadOnly` falls
back to `hdiutil attach -nomount` + `mount -t cd9660`, both unprivileged. Dismount has
to `umount` first - `hdiutil detach -force` refuses with "Resource busy" while the
volume is mounted.

Boot test: `scripts/test-linux-iso-boot-qemu.sh` (Homebrew qemu, headless, ~2 min).

### Installing, not just booting: the netboot initrd companion

The netinst's own `initrd.gz` is the CD-ROM flavour (cdrom-detect, no net-retriever, no
NIC modules), so over PXE it stops at "detect and mount installation media". Debian's
answer is the `netboot` initrd from the mirror, and the mount pass fetches it
automatically for installer media (`Ensure-AppPxeBootDebianNetbootInitrd`):

- The kernel a d-i build ships is the same file on the ISO (`install.amd/vmlinuz`) and
  on the mirror (`netboot/.../linux`). Hashing the ISO's kernel and matching it against
  each build's `SHA256SUMS` under `dists/<codename>/main/installer-<arch>/` proves which
  d-i build the ISO came from - no version parsing. Dated builds are tried newest first,
  `current` last.
- Only that build's graphical `initrd.gz` (~80 MB) is downloaded, SHA256-verified, into
  store `http/linux/debian/<codename>-<arch>-<sha8>/` with a `manifest.json`. One
  download per Debian build, shared by every ISO of that build.
- The menu handler then boots the ISO's kernel with the netboot initrd and tells d-i to
  use the Debian mirror: `mirror/country=manual` (without it d-i ignores the preseeded
  host and picks a country mirror), `mirror/http/hostname=deb.debian.org`,
  `mirror/http/directory=/debian`, `mirror/suite=<codename>`,
  `netcfg/choose_interface=auto`. All of it sits BEFORE `---` so none of it leaks into
  the installed system's bootloader config. Not the ISO tree: a netinst omits the
  storage-driver udebs the netboot initrd needs (2026-09-06), and the internet mirror
  is signed and always current. `APP_DEBIAN_MIRROR` overrides the mirror base.
- Offline, or when no build on the mirror matches the ISO's kernel, the entry falls back
  to the ISO's own initrd (boots to the installer only) and says so in the menu and in
  the ISO list. A failed fetch is remembered for 10 minutes so an offline laptop pays
  one DNS timeout per Start.
- `APP_DEBIAN_MIRROR` overrides `https://deb.debian.org/debian`.

QEMU verification: `scripts/test-linux-iso-boot-qemu.sh --install` - verified 2026-09-04 with debian-13.6.0-amd64-netinst: d-i accepted the served ISO tree as its mirror (dists/trixie Release + debian-installer Packages.gz), then fetched its udebs from pool/ on the mounted ISO through Caddy.

### No ISO at all: Linux network installers

Since the mirror supplies drivers and packages, a Debian install needs only the netboot
kernel and initrd. Operating Systems > **Linux network installers** lists Debian 13 and 12
for amd64 and arm64; **Add** fetches the mirror's current gtk `linux` + `initrd.gz`
(about 95 MB) into store `http/linux/debian/<codename>-<arch>/` with a `manifest.json`
(SHA256SUMS-verified, dated d-i build recorded), and the PXE menu gets
`Debian 13 (trixie) amd64 installer (network)` with the task-sequence submenu. **Remove**
drops the directory and the entry. Add on an already-current pair downloads nothing.

### Ubuntu: the ISO is the installer

Ubuntu 22.04+ has no d-i and no netboot installer. The Linux installers catalog offers
Ubuntu 24.04 and 22.04 Server; **Add** downloads the current live-server ISO into the
library through Transfers (SHA256SUMS-verified). Mounted, its `casper/vmlinuz` and
`casper/initrd` boot straight off the mount with `ip=dhcp url=<the ISO over Caddy>`;
casper fetches the whole ISO into RAM and runs Subiquity from it, and packages come from
the Ubuntu archive. An Ubuntu task sequence compiles to a Subiquity autoinstall published
as `TaskSequences/autoinstall/<id>/user-data` + `meta-data`; its handler adds
`autoinstall ds=nocloud-net;s=<seed directory>/ cloud-config-url=<seed>/user-data`. The
`cloud-config-url=` is load-bearing: cloud-init also treats a kernel `url=` as its
cloud-config and would otherwise read the whole ISO into memory (OOM, seen 2026-09-06);
the Interactive entry points it at an empty cloud-config the menu regen writes. Debian and Ubuntu sequences only ever
appear under entries of their own platform.

### Windows: a Script by URL step

A Windows sequence's first-boot steps run from `<id>.firstboot.cmd`, one cmd line each,
and cmd refuses a line over 8191 characters - so a whole script as an `-EncodedCommand`
step (8/3 of its length in base64) fails past about 3 KB. The **Script by URL** step is
the fix: pick a `.ps1` from `<library>/Scripts/` (**Add...** copies one in) or give a URL,
and the batch line is `powershell -Command "irm '<url>' | iex"` - the script streams from
Caddy's `/Scripts/` (served as `text/plain`) at first boot, as SYSTEM, any length. The
panel flags an encoded step that is over the limit. The Scripts folder is shared: the
Linux First-boot script picker hides `.ps1`, the Windows step shows only `.ps1`.

### Task sequences reach the installer through the menu

d-i reads `preseed/url=` off the kernel command line, so the menu entry decides which
task sequence a machine gets (there is no WinPE-style picker after boot). An
install-capable Debian entry with published Debian sequences (`platform: debian`,
enabled, `<id>.cfg` on the share) is a submenu: one item per sequence, `Interactive
install (no task sequence)`, `Back`. A sequence handler boots the same kernel and
netboot initrd with `auto=true priority=critical preseed/url=${http_base}/TaskSequences/<id>.cfg`
added before `---`; Interactive carries neither. Interactive is preselected unless the
store's default sequence is a Debian one. A sequence handler also carries
`hw-detect/firmware-lookup=never`. The netboot initrd ships no firmware (only the
regulatory database), and an unattended machine has no USB stick, yet d-i's
check-missing-firmware still hunts for one: for every driver that asked for a blob it
unloads and reloads the driver, mounts every partition on every disk looking for
media, settles udev and goes round again, and at `priority=critical` its "load from
removable media?" question is skipped and defaults to yes. A ThinkPad 11e 5th Gen sat
on "Detect network hardware" for half an hour that way on 2026-09-06 - its wired
RTL8168 asks for an optional `rtl_nic/rtl8168g-3.fw` - and installed in twenty minutes
once the argument was on the line. Interactive keeps the question (it is asked at
priority high, and "no" ends the loop). Nothing is lost: there is no firmware source
to look up. Firmware for the installed system is a separate matter - Debian publishes
`firmware.cpio.gz` for netboot (496 MB for trixie), and a preseed can set
`apt-setup/non-free-firmware boolean true`; neither is wired up yet. A sequence whose "Linux installer" field names a
release (`debian-<codename>-<arch>`) appears only under that release's entry; a blank one
appears under every Debian entry. Gate: `scripts/test-linux-menu.ps1`; live:
`scripts/test-linux-iso-boot-qemu.sh --preseed` (needs a published sequence whose disk
is `/dev/vda`; `WDK_LINUX_ENTRY=<entry>` picks the menu entry, `WDK_VM_RAM=8192` for
Ubuntu). Verified 2026-09-06: Debian (ISO-backed and ISO-less entries) installed
unattended from deb.debian.org and rebooted, with a bash step logged from in-target;
Ubuntu 24.04.4 installed unattended from the autoinstall seed with the ISO streamed
from Caddy and rebooted. The d-i syslog lands in `$TMPDIR/wdk-linux-iso-boot/d-i.syslog`.

First user: typed, or a vault credential whose login/full name/password are resolved at
publish (password hashed with crypt SHA-512 in the sidecar). A typed password is hashed on
save; only the hash is stored or published. First-boot script: a file in
`<library>/Scripts/` (served at `/Scripts/`, listed in the panel; **Add...** copies one in
from this machine, checking for a `#!` first line and fixing CRLF, **Folder** opens the
folder) or a custom URL. Nothing is copied at publish: the installer fetches the script
over HTTP at the end of the install into `/usr/local/sbin/wdk-run` in the target; it runs
on the first boot of the installed system through a one-shot systemd unit, with the
network up. Steps (the panel calls them "End-of-install steps" on Linux) are different:
each is `bash -c '<command>'` run in-target as root at the end of the install, before
the reboot, with no services running - d-i's late_command, or a curtin in-target
late-command under Subiquity. Extra packages: free text plus a picker of known names
that exist in both the Debian and Ubuntu archives.

Still open: Secure Boot must be off (the bundled shim trusts the iPXE CA, not a distro
kernel key). With the mirror on the internet the installed system's apt sources are the
normal Debian ones.
### Install feedback: a Linux install in the imaging clients list

The WinPE deploy client POSTs its log to `/imaging-log/ingest` (Caddy reverse-proxies it
to a loopback listener in the sidecar) and the panel shows one row per machine with its
last line. A Debian or Ubuntu task sequence now reports through the same endpoint, so
there is one list and one row per machine whichever OS it is getting:

1. **Boot ping.** A sequence handler runs `isset ${serial} && set wdk_id
   ${serial:uristring} || set wdk_id ${mac:hexraw}` and `imgfetch --name wdk-ping
   ${http_base}/imaging-log/ingest?serial=${wdk_id}&make=...&model=...&line=Boot...
   ||` before `kernel`, so the row exists from the moment the entry is chosen, keyed
   the way the WinPE client keys itself (SMBIOS serial, else MAC). `||` means a dead
   endpoint cannot stop a boot. The same identity rides on the kernel line as
   `wdk_serial= wdk_make= wdk_model=`, before `---`, so the installed system's GRUB never
   sees it. Interactive entries do none of this.
2. **The reporter.** `sidecar/pxe/linux/wdk-report.sh` is published to
   `http/linux/wdk-report.sh`. The preseed's `preseed/early_command` (autoinstall:
   `early-commands`) reads the server off the kernel line (`preseed/url=` or
   `ds=nocloud-net;s=`), fetches the script and runs `start`, which reports "Installer
   running: task sequence <id>" and forks `run` into the background. `run` watches
   `/var/log/syslog` (Subiquity: its server debug log) and reports each step d-i's
   main-menu starts, in words, the latest progress line when it changes (debootstrap and
   in-target lines), anything that looks like a failure, and a heartbeat after a quiet
   minute. Reports are GETs - the installer's busybox wget cannot POST - and every one
   ends in `|| true`.
3. **End of install.** The late_command opens with `wdk-report late` (reports, writes
   `/target/etc/windeploykit/deploy.conf` with the server, serial, make, model, sequence
   and session, copies the script to `/usr/local/sbin/wdk-report`) and closes with
   `wdk-report done $rc`, which reports the previous part's exit status and exits with
   it, so d-i still sees a failed step. Both parts are guarded by `[ -f /tmp/wdk-report ]`:
   a sequence whose reporter fetch failed installs exactly as before.
4. **First boot.** `wdk-firstboot.service` runs `/usr/local/sbin/wdk-report firstboot`
   when it exists (else `wdk-run` directly, as before). It runs the sequence's script,
   reports the start, the exit code with the time taken, and the last three lines of
   output, and exits with the script's code, so a failing script still leaves the unit
   enabled to retry at the next boot.

The listener accepts `GET /imaging-log/ingest?serial=&make=&model=&session=&line=` (one
line) or `&heartbeat=1`, URL-decoded, stored exactly as a POST is, answered `200 ok`
(iPXE's `imgfetch` wants a body). A push with no make or model keeps the last known
ones. Gate: `scripts/test-linux-install-report.ps1` starts the real listener, drives the
script under `/bin/sh` with its `WDK_*` test hooks against a d-i-shaped syslog, and
checks what landed in `imaging-logs/`. Verified live on a ThinkPad 11e 5th Gen
(2026-09-06): boot ping, sixteen steps in words, end of install, and first boot
reporting the CampusCast script's exit code and last lines, seven and a half minutes
from ping to reboot. Ubuntu's stage names come from Subiquity's log by pattern and have
not been watched on a live install yet.


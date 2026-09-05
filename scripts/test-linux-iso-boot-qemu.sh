#!/bin/bash
# Linux ISO boot smoke test in a headless QEMU x86_64 UEFI VM (Homebrew qemu, TCG).
#
# Proves the Linux half of the PXE menu against the LIVE store: the generated
# :lnx_<slug> handler fetches the distro kernel + initrd straight off the mounted ISO
# (Caddy /iso-mount/<token>/ route) and the kernel boots into the installer.
#
#   Start Imaging Services in the app (or at least HTTP + ISO mounts), then:
#   ./scripts/test-linux-iso-boot-qemu.sh            # tier 1: kernel + initrd served
#   ./scripts/test-linux-iso-boot-qemu.sh --installer # tier 2: + installer UI on serial
#   ./scripts/test-linux-iso-boot-qemu.sh --install   # tier 3: + installer configures the
#                                                     #   network and loads its components
#                                                     #   from the Debian mirror (internet)
#   WDK_LINUX_ENTRY=lnx_debian_trixie_amd64 ./scripts/test-linux-iso-boot-qemu.sh
#                                                     # pick an entry (default: the first
#                                                     #   :lnx_* in the menu)
#   ./scripts/test-linux-iso-boot-qemu.sh --preseed   # tier 4: boot a TASK SEQUENCE
#                                                     #   handler (needs a published
#                                                     #   Debian sequence whose disk is
#                                                     #   /dev/vda): the installer fetches
#                                                     #   the preseed off the share, installs
#                                                     #   unattended to a scratch disk, and
#                                                     #   reboots - the VM exits (-no-reboot)
#
# Why not OVMF's own PXE: Homebrew's edk2 build never offers a network boot option
# here (the EFI shell wins every time), and UTM's firmware does not run under
# Homebrew qemu. So the bundled full ipxe.efi (own NIC drivers) boots from a virtual
# FAT disk and chains qemu's built-in TFTP, which serves a boot.ipxe that IS the
# generated handler block (console=ttyS0 added so the kernel talks to the serial log).
# The kernel/initrd URLs, the Caddy route and the mount are all production.
set -u
TIER2=0; TIER3=0; TIER4=0
[ "${1:-}" = "--installer" ] && TIER2=1
[ "${1:-}" = "--install" ] && { TIER2=1; TIER3=1; }
[ "${1:-}" = "--preseed" ] && { TIER2=1; TIER3=1; TIER4=1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$HOME/Library/Application Support/windeploykit/plugins/pxe-boot"
MENU="$STORE/http/boot.ipxe"
ACCESS="$STORE/http-access.log"
FW=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
WORK="${TMPDIR:-/tmp}/wdk-linux-iso-boot"
command -v qemu-system-x86_64 >/dev/null || { echo "FAIL: qemu-system-x86_64 not on PATH (brew install qemu)"; exit 1; }
[ -f "$FW" ] || { echo "FAIL: $FW missing"; exit 1; }
case "$WORK" in *[\ ,:]*) echo "FAIL: work dir path must not contain spaces, commas or colons ($WORK)"; exit 1 ;; esac

# --- pre-flight: the live menu has a Linux entry ------------------------------
curl -fsS --max-time 5 http://localhost:8080/boot.ipxe >/dev/null 2>&1 || { echo "FAIL: http://localhost:8080/boot.ipxe not served - Start Imaging Services first."; exit 1; }
HTTP_BASE=$(awk '/^set http_base /{print $3; exit}' "$MENU")
# The entry under test: WDK_LINUX_ENTRY, else the first top-level :lnx_* in the menu.
ENTRY="${WDK_LINUX_ENTRY:-$(grep -m1 -o '^:lnx_[a-z0-9_]*' "$MENU" | grep -v '__' | tr -d ':')}"
[ -n "$ENTRY" ] && grep -q "^:$ENTRY\$" "$MENU" || { echo "FAIL: no :${ENTRY:-lnx_*} handler in boot.ipxe - is a Linux ISO mounted or a network installer added?"; exit 1; }
if [ "$TIER4" = "1" ]; then
    # The entry's first task-sequence handler: <entry>__ts_<sequence>.
    LABEL=$(grep -m1 -o "^:${ENTRY}__ts_[a-z0-9_]*" "$MENU" | tr -d ':')
    [ -n "$LABEL" ] || { echo "FAIL: no :${ENTRY}__ts_* handler in boot.ipxe - publish an enabled Debian task sequence first"; exit 1; }
    PRESEED_URI=$(awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^kernel /{print; exit}' "$MENU" | grep -o 'preseed/url=[^ ]*' | sed 's|preseed/url=\${http_base}||')
    [ -n "$PRESEED_URI" ] || { echo "FAIL: handler $LABEL carries no preseed/url="; exit 1; }
elif grep -q "^:${ENTRY}__manual\$" "$MENU"; then
    # An install-capable entry with sequences is a submenu; its Interactive handler is
    # the plain boot the lower tiers want.
    LABEL="${ENTRY}__manual"
else
    LABEL="$ENTRY"
fi
KERNEL_URI=$(awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^kernel /{print $2; exit}' "$MENU" | sed 's|\${http_base}||')
INITRD_URI=$(awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^initrd /{print $2; exit}' "$MENU" | sed 's|\${http_base}||')
echo "menu is live (http_base $HTTP_BASE) - testing $LABEL"
echo "  kernel $KERNEL_URI"
echo "  initrd $INITRD_URI"
[ "$TIER4" = "1" ] && echo "  preseed $PRESEED_URI"

# --- the VM's boot media ------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK/fatroot/EFI/BOOT"
cp "$REPO/sidecar/pxe/x86_64/ipxe.efi" "$WORK/fatroot/EFI/BOOT/BOOTX64.EFI" || { echo "FAIL: sidecar/pxe/x86_64/ipxe.efi missing"; exit 1; }
printf '#!ipxe\ndhcp || shell\nchain tftp://${next-server}/boot.ipxe || shell\n' > "$WORK/fatroot/EFI/BOOT/autoexec.ipxe"
{
    echo '#!ipxe'
    echo "set http_base $HTTP_BASE"
    echo "echo boot-test: $LABEL"
    # Tier 3 preseeds the early questions on the kernel line (test only, never in the
    # product menu) so d-i walks past language/keymap/hostname to "download installer
    # components" unattended. Everything stays BEFORE '---'.
    PRESEED=""
    # No auto=true: that makes d-i demand a preseed URL before it does anything else.
    # Tier 4 adds nothing: the handler under test already carries the real preseed/url.
    [ "$TIER3" = "1" ] && [ "$TIER4" = "0" ] && PRESEED=" priority=critical locale=en_AU.UTF-8 keymap=us netcfg/get_hostname=wdktest netcfg/get_domain=lan"
    # From tier 3 on, d-i forwards its syslog to this Mac (qemu user-net: 10.0.2.2 is the
    # host) so a stalled install can be read in $WORK/d-i.syslog instead of guessed at.
    [ "$TIER3" = "1" ] && PRESEED="$PRESEED log_host=10.0.2.2 log_port=5514"
    awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^$/{exit} p' "$MENU" \
      | sed -e "s| --- | console=ttyS0,115200$PRESEED --- |" -e 's|^kernel \(.*[^-]\)$|kernel \1 console=ttyS0,115200|' -e 's|^goto start$|shell|'
} > "$WORK/boot.ipxe"

OFFSET=$(stat -f %z "$ACCESS" 2>/dev/null || echo 0)
seen() { tail -c "+$((OFFSET+1))" "$ACCESS" 2>/dev/null | grep -q "$1"; }
SYSLOG_PID=""
if [ "$TIER3" = "1" ]; then
    rm -f "$WORK/d-i.syslog"
    ( nc -u -k -l 5514 > "$WORK/d-i.syslog" 2>/dev/null ) &
    SYSLOG_PID=$!
fi
# Tier 4 gives the installer a scratch disk (/dev/vda, the disk the test sequence names)
# and makes the reboot at the end of the install exit the VM. (The ${EXTRA[@]+...}
# expansion below is for macOS bash 3.2, where an empty array is "unbound" under set -u.)
# 16 GB: trixie's "atomic"
# recipe wants about 10 GB at minimum (768 MB EFI + 768 MB /boot + 8 GB / + swap), and
# an 8 GB disk fails with "Unable to satisfy all constraints" (2026-09-06).
EXTRA=()
if [ "$TIER4" = "1" ]; then
    qemu-img create -q -f qcow2 "$WORK/disk.qcow2" 16G || { echo "FAIL: qemu-img"; exit 1; }
    EXTRA=(-drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" -no-reboot)
fi
qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$FW" \
  -drive if=none,id=fat,file="fat:rw:$WORK/fatroot",format=raw -device ide-hd,drive=fat,bootindex=1 \
  -netdev user,id=n0,tftp="$WORK",bootfile=boot.ipxe -device e1000,netdev=n0 \
  -display none -vga std -serial "file:$WORK/serial.log" -pidfile "$WORK/qemu.pid" \
  -monitor tcp:127.0.0.1:47902,server,nowait \
  ${EXTRA[@]+"${EXTRA[@]}"} >"$WORK/qemu.out" 2>&1 &
QEMU=$!
cleanup() { kill "$QEMU" 2>/dev/null; [ -n "$SYSLOG_PID" ] && kill "$SYSLOG_PID" 2>/dev/null; }
trap cleanup EXIT
echo "VM started (headless) - watching the boot chain (serial: $WORK/serial.log)..."

# --- tier 1: kernel + initrd came off the mounted ISO through Caddy -----------
# TCG: firmware + iPXE + a ~77 MB initrd over slirp took ~90 s on an M3 Max.
DEADLINE=$(( $(date +%s) + 600 ))
for m in "$KERNEL_URI" "$INITRD_URI"; do
    while :; do
        if seen "$m"; then echo "  [OK  ] $m"; break; fi
        kill -0 "$QEMU" 2>/dev/null || { echo "  [FAIL] qemu exited before: $m"; cat "$WORK/qemu.out"; exit 1; }
        if grep -q "failed\|Could not\|Permission denied" "$WORK/serial.log" 2>/dev/null; then
            echo "  [FAIL] iPXE reported a failure before: $m"; grep "failed\|Could not\|Permission denied" "$WORK/serial.log" | head -3; exit 1
        fi
        [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  [FAIL] timed out waiting for: $m"; exit 1; }
        sleep 2
    done
done
if [ "$TIER2" = "0" ]; then echo "linux iso boot: all checks passed (tier 1)"; exit 0; fi

# --- tier 2: the kernel booted and the installer put up its first screen ------
DEADLINE=$(( $(date +%s) + 900 ))
while :; do
    # A preseeded (tier 3) run never shows the language screen - its first visible
    # step is hardware detection, so that counts too.
    if LC_ALL=C grep -a -q "Select a language\|Choose the language\|Detecting network hardware\|Configuring the network\|login:" "$WORK/serial.log" 2>/dev/null; then
        echo "  [OK  ] kernel booted - installer reached its first screen on serial"; break
    fi
    if grep -q "Kernel panic\|end Kernel panic" "$WORK/serial.log" 2>/dev/null; then echo "  [FAIL] kernel panic"; exit 1; fi
    kill -0 "$QEMU" 2>/dev/null || { echo "  [FAIL] qemu exited before the installer came up"; exit 1; }
    [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  [FAIL] no installer screen within 15 min"; exit 1; }
    sleep 5
done
if [ "$TIER3" = "0" ]; then echo "linux iso boot: all checks passed (tier 2)"; exit 0; fi

# --- tier 3: network up, mirror accepted, components loaded ---------------------
# Only meaningful for the netboot-initrd entry (menu note "Installer: netboot initrd").
# The mirror is the Debian mirror on the internet (through qemu's NAT), so nothing of
# this passes through Caddy: the serial console is the witness.
DEADLINE=$(( $(date +%s) + 900 ))
# The last marker is either: an Interactive (un-preseeded) boot stops at the user
# account questions before it starts the partitioner, and that is already past the
# mirror, which is what this tier proves.
for m in "Network autoconfiguration has succeeded" "Loading additional components" "Set up users and passwords\|Starting up the partitioner"; do
    while :; do
        if LC_ALL=C grep -a -q "$m" "$WORK/serial.log" 2>/dev/null; then echo "  [OK  ] installer: $(printf '%s' "$m" | sed 's/\\|/ or /')"; break; fi
        if LC_ALL=C grep -a -q "Bad archive mirror\|No kernel modules were found\|Kernel panic\|Download debconf preconfiguration" "$WORK/serial.log" 2>/dev/null; then
            echo "  [FAIL] installer error before: $m"; LC_ALL=C grep -a -o "Bad archive mirror\|No kernel modules were found\|Kernel panic\|Download debconf preconfiguration" "$WORK/serial.log" | head -2; exit 1
        fi
        kill -0 "$QEMU" 2>/dev/null || { echo "  [FAIL] qemu exited before: $m"; exit 1; }
        [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  [FAIL] timed out waiting for: $m"; exit 1; }
        sleep 5
    done
done
if [ "$TIER4" = "0" ]; then echo "linux iso boot: all checks passed (tier 3)"; exit 0; fi

# --- tier 4: the task sequence drove an unattended install to completion ---------
# The preseed must have come off the share (Caddy /TaskSequences/), and the install
# must finish and reboot on its own: with -no-reboot the VM exits. Under TCG a base
# install from the mirror takes a while - 60 min ceiling.
if seen "$PRESEED_URI"; then echo "  [OK  ] installer fetched the task sequence preseed $PRESEED_URI"; else
    echo "  [FAIL] preseed $PRESEED_URI was never fetched"; exit 1
fi
DEADLINE=$(( $(date +%s) + 3600 ))
STAGE=""
while :; do
    for st in "Partitioning disks\|Formatting partitions" "Installing the base system" "Select and install software" "Installing GRUB\|Install the GRUB boot loader" "Finishing the installation"; do
        if [ "$STAGE" != "$st" ] && LC_ALL=C grep -a -q "$st" "$WORK/serial.log" 2>/dev/null; then
            case "$st" in "$STAGE"*) ;; *) echo "  [....] $(printf '%s' "$st" | sed 's/\\|.*//')"; STAGE="$st" ;; esac
        fi
    done
    if ! kill -0 "$QEMU" 2>/dev/null; then
        # Three independent signs of a finished install, so a killed VM cannot pass:
        # the base system went in, the "Finishing the installation" progress title
        # reached the serial console, and the VM left on its own. (Not "finish-install":
        # that is also a udeb name that scrolls past while components load.)
        if LC_ALL=C grep -a -q "Installing the base system" "$WORK/serial.log" 2>/dev/null && LC_ALL=C grep -a -q "Finishing the installation\|Installation complete" "$WORK/serial.log" 2>/dev/null; then
            echo "  [OK  ] install finished and the machine rebooted (VM exited)"; break
        fi
        echo "  [FAIL] VM exited before the install finished"; exit 1
    fi
    if LC_ALL=C grep -a -q "Installation step failed\|Bad archive mirror\|Kernel panic\|Download debconf preconfiguration\|No root file system" "$WORK/serial.log" 2>/dev/null; then
        echo "  [FAIL] installer stopped:"; LC_ALL=C grep -a -o "Installation step failed[^\^]*\|Bad archive mirror\|Kernel panic\|Download debconf preconfiguration\|No root file system[^\^]*" "$WORK/serial.log" | head -2; exit 1
    fi
    [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  [FAIL] install did not finish within 60 min"; exit 1; }
    sleep 10
done
echo "linux iso boot: all checks passed (tier 4)"
exit 0

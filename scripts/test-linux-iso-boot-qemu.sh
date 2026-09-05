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
#   ./scripts/test-linux-iso-boot-qemu.sh --install   # tier 3: + installer pulls its
#                                                     #   components (udebs) off the
#                                                     #   mounted ISO through Caddy
#
# Why not OVMF's own PXE: Homebrew's edk2 build never offers a network boot option
# here (the EFI shell wins every time), and UTM's firmware does not run under
# Homebrew qemu. So the bundled full ipxe.efi (own NIC drivers) boots from a virtual
# FAT disk and chains qemu's built-in TFTP, which serves a boot.ipxe that IS the
# generated handler block (console=ttyS0 added so the kernel talks to the serial log).
# The kernel/initrd URLs, the Caddy route and the mount are all production.
set -u
TIER2=0; TIER3=0
[ "${1:-}" = "--installer" ] && TIER2=1
[ "${1:-}" = "--install" ] && { TIER2=1; TIER3=1; }
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
LABEL=$(grep -m1 -o '^:lnx_[a-z0-9_]*' "$MENU" | tr -d ':')
[ -n "$LABEL" ] || { echo "FAIL: no :lnx_ handler in boot.ipxe - is a Linux ISO in the library and mounted?"; exit 1; }
KERNEL_URI=$(awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^kernel /{print $2; exit}' "$MENU" | sed 's|\${http_base}||')
INITRD_URI=$(awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^initrd /{print $2; exit}' "$MENU" | sed 's|\${http_base}||')
echo "menu is live (http_base $HTTP_BASE) - testing $LABEL"
echo "  kernel $KERNEL_URI"
echo "  initrd $INITRD_URI"

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
    [ "$TIER3" = "1" ] && PRESEED=" priority=critical locale=en_AU.UTF-8 keymap=us netcfg/get_hostname=wdktest netcfg/get_domain=lan"
    awk -v l=":$LABEL" '$0==l{p=1;next} p&&/^$/{exit} p' "$MENU" \
      | sed -e "s| --- | console=ttyS0,115200$PRESEED --- |" -e 's|^kernel \(.*[^-]\)$|kernel \1 console=ttyS0,115200|' -e 's|^goto start$|shell|'
} > "$WORK/boot.ipxe"

OFFSET=$(stat -f %z "$ACCESS" 2>/dev/null || echo 0)
seen() { tail -c "+$((OFFSET+1))" "$ACCESS" 2>/dev/null | grep -q "$1"; }
qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu qemu64 -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$FW" \
  -drive if=none,id=fat,file="fat:rw:$WORK/fatroot",format=raw -device ide-hd,drive=fat,bootindex=1 \
  -netdev user,id=n0,tftp="$WORK",bootfile=boot.ipxe -device e1000,netdev=n0 \
  -display none -vga std -serial "file:$WORK/serial.log" -pidfile "$WORK/qemu.pid" \
  >"$WORK/qemu.out" 2>&1 &
QEMU=$!
cleanup() { kill "$QEMU" 2>/dev/null; }
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

# --- tier 3: the installer fetched its components from the mounted ISO ----------
# Only meaningful for the netboot-initrd entry (menu note "Installer: netboot initrd").
# Markers: the suite Release, the udeb Packages index, then at least one .udeb.
TOKEN=$(printf '%s' "$KERNEL_URI" | sed 's|^/iso-mount/\([^/]*\)/.*|\1|')
DEADLINE=$(( $(date +%s) + 900 ))
for m in "/iso-mount/$TOKEN/dists/" "debian-installer/binary-" "\.udeb"; do
    while :; do
        if seen "$m"; then echo "  [OK  ] installer fetched $m from the mounted ISO"; break; fi
        if grep -q "Bad archive mirror\|No kernel modules were found\|Kernel panic" "$WORK/serial.log" 2>/dev/null; then
            echo "  [FAIL] installer error before: $m"; grep -o "Bad archive mirror\|No kernel modules were found\|Kernel panic" "$WORK/serial.log" | head -2; exit 1
        fi
        kill -0 "$QEMU" 2>/dev/null || { echo "  [FAIL] qemu exited before: $m"; exit 1; }
        [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  [FAIL] timed out waiting for: $m"; exit 1; }
        sleep 5
    done
done
echo "linux iso boot: all checks passed (tier 3)"
exit 0

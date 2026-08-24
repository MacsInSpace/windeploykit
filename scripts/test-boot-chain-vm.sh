#!/bin/bash
# Boot-chain smoke test in a UTM-managed QEMU VM (headless, no school infra).
#
# A throwaway emulated x86_64 UEFI machine ("WDK Boot Chain" in the UTM library)
# whose NIC ROM (iPXE) is handed a one-line script that chains this Mac's live
# boot.ipxe. A packet-capture filter on the VM's NIC then proves the chain served:
# menu -> wimboot -> deploy overlay -> boot.wim - everything that broke in the
# field on 2026-08-24, testable in ~2 minutes without booting a real machine.
#
#   ./scripts/test-boot-chain-vm.sh            # tier 1: fetch-sequence assertions
#   ./scripts/test-boot-chain-vm.sh --winpe    # tier 2: + wait for WinPE's startnet
#                                              #   to push its first imaging log (TCG: slow)
#   ./scripts/test-boot-chain-vm.sh --reset    # delete the VM (recreated next run)
#
# The VM is created through UTM's AppleScript interface and driven with utmctl, so
# it shows up in the UTM library like any other machine. Emulation is TCG on Apple
# Silicon - right tool for the boot chain, wrong tool for a full apply (use Hyper-V
# or Proxmox for that; Craig, 2026-08-24). 8 cores / 8GB - the M3 Max can spare it.
set -u
VMNAME="WDK Boot Chain"
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
# Lives in the QEMU HELPER's sandbox container - qemu runs as the separate
# com.utmapp.QEMUHelper XPC service, and that sandbox is why every other path
# (/tmp, UTM's own container) came back "Operation not permitted". No spaces:
# the path rides inside a -netdev argument string. Contents refresh every run.
WORK="$HOME/Library/Containers/com.utmapp.QEMUHelper/Data/tmp/wdk-boot-chain"
TIER2=0
case "${1:-}" in
    --winpe) TIER2=1 ;;
    --reset) "$UTMCTL" delete "$VMNAME" 2>/dev/null; rm -rf "$WORK"; echo "VM and workdir removed"; exit 0 ;;
esac
[ -x "$UTMCTL" ] || { echo "FAIL: UTM.app not installed"; exit 1; }
mkdir -p "$WORK"

# --- pre-flight: the live menu ------------------------------------------------
MENU=$(curl -fsS --max-time 5 http://localhost:8080/boot.ipxe 2>/dev/null)
if [ -z "$MENU" ]; then
    echo "FAIL: http://localhost:8080/boot.ipxe not served - Start Imaging Services first."
    exit 1
fi
HTTP_BASE=$(printf '%s\n' "$MENU" | awk '/^set http_base /{print $3; exit}')
echo "menu is live (http_base $HTTP_BASE)"

# The NBP is the REAL product snponly.efi (our iPXE build with the embedded
# fallback chain), served to OVMF's native PXE by qemu's built-in TFTP alongside
# a fresh copy of the REAL boot.ipxe. The embed tries tftp://${next-server}/
# first (qemu's TFTP = these copies) and falls back to http://${next-server}:8080
# (user-net maps 10.0.2.2 to this Mac, i.e. the live Caddy) - so both roads run
# production code. OVMF's own e1000 iPXE ROM never loads under UTM, which is why
# the NBP must BE iPXE.
STORE="$HOME/Library/Application Support/windeploykit/plugins/pxe-boot"
cp "$STORE/tftp/snponly.efi" "$WORK/snponly.efi" || { echo "FAIL: no snponly.efi in the store tftp root"; exit 1; }
cp "$STORE/http/boot.ipxe" "$WORK/boot.ipxe" || { echo "FAIL: no boot.ipxe in the store"; exit 1; }

# --- ensure the VM exists (created once, kept in the UTM library) -------------
if ! "$UTMCTL" list | grep -q "$VMNAME"; then
    echo "creating '$VMNAME' in UTM..."
    osascript <<OSA || { echo "FAIL: could not create the VM via UTM scripting"; exit 1; }
tell application "UTM"
    make new virtual machine with properties {backend:qemu, configuration:{name:"$VMNAME", architecture:"x86_64", uefi:true, memory:8192, cpu cores:8, hypervisor:false, network interfaces:{}, drives:{{removable:false, interface:VirtIO, guest size:40960}}, qemu additional arguments:{{argument string:"-netdev user,id=bc0,tftp=$WORK,bootfile=snponly.efi"}, {argument string:"-device e1000,netdev=bc0,bootindex=1"}, {argument string:"-serial tcp:127.0.0.1:47901,server=on,wait=off"}}}}
end tell
OSA
fi

cleanup() { "$UTMCTL" stop "$VMNAME" 2>/dev/null; }
trap cleanup EXIT
# --hide keeps the UTM window closed; --disposable throws away scratch-disk state so
# every run boots the same machine.
"$UTMCTL" start "$VMNAME" --hide --disposable || { echo "FAIL: could not start the VM"; exit 1; }
T0=$(date +%s)
echo "VM started (headless) - watching the boot chain..."

# --- tier 1: the fetch sequence, from Caddy's access log ----------------------
ACCESS="$HOME/Library/Application Support/windeploykit/plugins/pxe-boot/http-access.log"
OFFSET=$(stat -f %z "$ACCESS" 2>/dev/null || echo 0)
seen() { tail -c "+$((OFFSET+1))" "$ACCESS" 2>/dev/null | grep -q "$1"; }
# No "/boot.ipxe" marker: the menu is served by qemu's TFTP (the embed tries TFTP
# first), so Caddy only sees the chain from wimboot onward. boot.wim last proves the
# whole overlay ran without an abort.
MARKERS=("/wimboot/wimboot" "/deploy/startnet.cmd" "/deploy/deploy.unc" "/wim/")
# 10 minutes: TCG firmware init plus qemu's (slow) built-in TFTP serving the 1MB
# NBP put first-fetch at ~5 minutes on the M3 Max - the chain itself is quick after.
DEADLINE=$(( $(date +%s) + 600 ))
for m in "${MARKERS[@]}"; do
    while :; do
        if seen "$m"; then echo "  [OK  ] $m"; break; fi
        # "stopped" flickers during UTM's startup handoff - only trust it after a
        # grace period and two consecutive reads.
        if [ $(( $(date +%s) - T0 )) -gt 30 ]; then
            STATE=$("$UTMCTL" status "$VMNAME" 2>/dev/null)
            if [ "$STATE" = "stopped" ]; then
                sleep 2
                [ "$("$UTMCTL" status "$VMNAME" 2>/dev/null)" = "stopped" ] && { echo "  [FAIL] VM stopped before: $m"; exit 1; }
            fi
        fi
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "  [FAIL] timed out waiting for: $m"; exit 1; fi
        sleep 2
    done
done
for opt in "/deploy/7z.exe" "/deploy/curl.exe" "/deploy/loghost"; do
    seen "$opt" && echo "  [OK  ] $opt (optional overlay)"
done
seen "/deploy/deploy.cred" && echo "  [note] deploy.cred fetched (cred mode publishes one)"

if [ "$TIER2" = "0" ]; then
    echo "boot chain: all checks passed (tier 1)"
    exit 0
fi

# --- tier 2: WinPE ran startnet and phoned home -------------------------------
LOGDIR="$HOME/Library/Application Support/windeploykit/plugins/pxe-boot/imaging-logs"
BASELINE=$(ls -1 "$LOGDIR" 2>/dev/null | wc -l | tr -d ' ')
DEADLINE=$(( $(date +%s) + 1800 ))
echo "tier 2: waiting for WinPE's first imaging-log push (TCG - minutes)..."
while :; do
    NOW=$(ls -1 "$LOGDIR" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$NOW" -gt "$BASELINE" ] || seen "/imaging-log/ingest"; then
        echo "  [OK  ] WinPE booted, overlay injected, startnet phoned home"
        break
    fi
    [ "$("$UTMCTL" status "$VMNAME" 2>/dev/null)" = "stopped" ] && { echo "  [FAIL] VM stopped before the first log push"; exit 1; }
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "  [FAIL] no imaging log within 30 min"; exit 1; fi
    sleep 10
done
echo "boot chain: all checks passed (tier 2)"
exit 0

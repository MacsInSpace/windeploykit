#!/bin/sh
# WinDeployKit install reporter (wdk-report).
#
# One POSIX shell script with five entry points, so a Linux install shows up in the
# panel's imaging clients the way a WinPE client does:
#
#   start      from d-i's preseed/early_command or Subiquity's early-commands. Works out
#              the deployment laptop and this machine's identity from the kernel line
#              iPXE built, reports that the installer is running, forks "run" into the
#              background and returns at once.
#   run        the background loop: watches the installer's log and reports each step
#              as it starts, a progress line when it changes, anything that looks like
#              a failure, and a heartbeat when nothing else has been said for a minute.
#   late       first late_command part: reports that the end-of-install steps are
#              running, records the deployment server in
#              /target/etc/windeploykit/deploy.conf and copies itself into the new
#              system as /usr/local/sbin/wdk-report.
#   done N     last late_command part: reports that the steps finished (N = the exit
#              code of the step before it).
#   firstboot  from wdk-firstboot.service in the installed system: runs the sequence's
#              first-boot script (/usr/local/sbin/wdk-run), reports the start, the exit
#              code with the time it took, and the last lines of its output.
#
# Reports are GET <base>/imaging-log/ingest?serial=..&make=..&model=..&session=..&line=..
# - the endpoint the WinPE deploy client POSTs JSON to. GET because the installer's
# busybox wget cannot POST. Nothing here may fail an install: every report ends in
# "|| true", "start" returns before the loop begins, and the loop dies with the
# installer's ramdisk at reboot.
#
# Runs under busybox sh (d-i), dash (Debian and Ubuntu targets) and bash. No bashisms,
# no backslashes in the early_command that fetches it (a preseed value is one line).
# Test hooks: WDK_CMDLINE, WDK_LOG, WDK_TARGET, WDK_ENV, WDK_RUN, WDK_ONCE, WDK_INTERVAL
# and WDK_FETCH override the paths, the loop and the fetch tool so that
# scripts/test-linux-install-report.ps1 can drive it on a Mac against the real listener.

cmdline_file=${WDK_CMDLINE:-/proc/cmdline}
env_file=${WDK_ENV:-/tmp/wdk-env}
target=${WDK_TARGET:-/target}
interval=${WDK_INTERVAL:-15}
mode=$1

# Percent-encode a line for a query string. Anything outside a small safe set becomes
# an underscore first, so the result never carries an ampersand, a percent sign or a
# quote whatever the log threw at it; spaces become %20 last.
enc() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | tr -c 'A-Za-z0-9 ._:/=,;()-' '_' | cut -c1-240 | sed 's/ /%20/g'
}

boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\n-'
}

# Identity and server. iPXE puts wdk_serial=, wdk_make= and wdk_model= on the kernel
# line (its SMBIOS values, URI-encoded, the MAC when there is no serial) so that the
# boot ping and every report here key the same panel row. The server is whatever the
# task sequence was fetched from: preseed/url= (d-i) or ds=nocloud-net;s= (Subiquity).
load_env() {
    if [ -f "$env_file" ]; then
        . "$env_file"
    fi
    if [ -z "$WDK_BASE_URL" ] && [ -r "$cmdline_file" ]; then
        for w in $(cat "$cmdline_file"); do
            case "$w" in
                preseed/url=*)
                    u=$(printf '%s' "$w" | cut -d= -f2-)
                    WDK_BASE_URL=${u%/TaskSequences/*}
                    WDK_SEQUENCE=${u##*/}
                    WDK_SEQUENCE=${WDK_SEQUENCE%.cfg}
                    ;;
                ds=nocloud-net*)
                    u=$(printf '%s' "$w" | cut -d= -f3-)
                    u=${u%/}
                    WDK_BASE_URL=${u%/TaskSequences/*}
                    WDK_SEQUENCE=${u##*/}
                    ;;
                wdk_serial=*) WDK_SERIAL=$(printf '%s' "$w" | cut -d= -f2-) ;;
                wdk_make=*)   WDK_MAKE=$(printf '%s' "$w" | cut -d= -f2-) ;;
                wdk_model=*)  WDK_MODEL=$(printf '%s' "$w" | cut -d= -f2-) ;;
            esac
        done
    fi
    if [ -z "$WDK_SERIAL" ]; then
        s=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ' \n\r')
        if [ -z "$s" ]; then
            s=$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00' | head -n 1 | tr -d ':\n' | tr 'a-f' 'A-F')
        fi
        WDK_SERIAL=$(enc "$s")
    fi
    [ -n "$WDK_MAKE" ]  || WDK_MAKE=$(enc "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)")
    [ -n "$WDK_MODEL" ] || WDK_MODEL=$(enc "$(cat /sys/class/dmi/id/product_name 2>/dev/null)")
    [ -n "$WDK_SESSION" ] || WDK_SESSION=$(boot_id)
}

save_env() {
    printf "WDK_BASE_URL='%s'\nWDK_SERIAL='%s'\nWDK_MAKE='%s'\nWDK_MODEL='%s'\nWDK_SEQUENCE='%s'\nWDK_SESSION='%s'\n" \
        "$WDK_BASE_URL" "$WDK_SERIAL" "$WDK_MAKE" "$WDK_MODEL" "$WDK_SEQUENCE" "$WDK_SESSION" > "$1"
}

# wget first: it is the one tool every environment here has (busybox in d-i, GNU in
# the installed system). curl for a target without wget. WDK_FETCH=curl is a test hook.
fetch() {
    if [ "${WDK_FETCH:-}" != curl ] && command -v wget >/dev/null 2>&1; then
        wget -q -O - "$1" >/dev/null 2>&1 || true
    elif command -v curl >/dev/null 2>&1; then
        curl -fsS -m 5 -o /dev/null "$1" >/dev/null 2>&1 || true
    fi
    return 0
}

post() {
    [ -n "$WDK_BASE_URL" ] || return 0
    fetch "$WDK_BASE_URL/imaging-log/ingest?serial=$WDK_SERIAL&make=$WDK_MAKE&model=$WDK_MODEL&session=$WDK_SESSION&line=$(enc "$(date +%H:%M:%S)  $1")"
}

beat() {
    [ -n "$WDK_BASE_URL" ] || return 0
    fetch "$WDK_BASE_URL/imaging-log/ingest?serial=$WDK_SERIAL&make=$WDK_MAKE&model=$WDK_MODEL&session=$WDK_SESSION&heartbeat=1"
}

# d-i's main-menu logs every step it starts; Subiquity's server log marks its stages.
step_lines() {
    grep -o "Menu item '[a-z0-9-]*' selected" "$log" 2>/dev/null | sed "s/Menu item '//; s/' selected//"
    grep -o 'start: subiquity/[A-Za-z0-9_]*/[A-Za-z0-9_]*' "$log" 2>/dev/null | sed 's#start: subiquity/##' | awk '!seen[$0]++'
}

# Empty for the two accessibility helpers d-i always runs first (braille, speech):
# a step nobody chose is not a milestone. Seen as "Step: brltty-udeb" on the 11e.
describe() {
    case "$1" in
        brltty-udeb|espeakup-udeb)        echo "" ;;
        localechooser)                    echo "Choosing the language" ;;
        kbd-chooser|console-setup-udeb)   echo "Configuring the keyboard" ;;
        ethdetect)                        echo "Detecting network hardware" ;;
        netcfg)                           echo "Configuring the network" ;;
        network-preseed)                  echo "Fetching the task sequence" ;;
        choose-mirror)                    echo "Choosing the mirror" ;;
        download-installer|anna)          echo "Loading installer components from the mirror" ;;
        clock-setup|tzsetup-udeb)         echo "Setting the clock" ;;
        user-setup-udeb)                  echo "Creating the first user" ;;
        disk-detect)                      echo "Detecting disks" ;;
        partman-base|partman-auto)        echo "Partitioning the disk" ;;
        bootstrap-base)                   echo "Installing the base system" ;;
        apt-setup-udeb)                   echo "Configuring apt" ;;
        pkgsel)                           echo "Selecting and installing software" ;;
        grub-installer|grub-installer-efi) echo "Installing GRUB" ;;
        finish-install)                   echo "Finishing the installation" ;;
        *)                                echo "Step: $1" ;;
    esac
}

error_lines() {
    grep -E "Installation step failed|Menu item '[a-z0-9-]*' failed|WARNING \*\*: .*(fail|error|cannot|unable)|late_command.*(fail|error)" "$log" 2>/dev/null | cut -c17- | cut -c1-200
}

# The most recent line that says what a long step is doing right now.
progress_hint() {
    tail -n 60 "$log" 2>/dev/null | grep -E 'debootstrap: I: (Retrieving|Validating|Extracting|Unpacking|Configuring)|in-target: (Unpacking|Setting up|Get:|Preparing)|partman.*(Creating|Formatting)|grub-installer: |curtin.*(stage|Installing|Running)' | tail -n 1 | cut -c17- | cut -c1-160
}

case "$mode" in
    start)
        load_env
        [ -n "$WDK_BASE_URL" ] || exit 0
        save_env "$env_file"
        post "Installer running: task sequence $WDK_SEQUENCE"
        # Detach the watcher from the installer's command: setsid where there is one
        # (busybox and util-linux both have it), a plain background job otherwise.
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$0" run </dev/null >/dev/null 2>&1 &
        else
            sh "$0" run </dev/null >/dev/null 2>&1 &
        fi
        ;;
    run)
        load_env
        [ -n "$WDK_BASE_URL" ] || exit 0
        log=${WDK_LOG:-}
        if [ -z "$log" ]; then
            if [ -f /var/log/syslog ]; then
                log=/var/log/syslog
            elif [ -f /var/log/installer/subiquity-server-debug.log ]; then
                log=/var/log/installer/subiquity-server-debug.log
            fi
        fi
        # What has been reported so far lives beside the env file, so a restarted loop
        # (or the gate, which runs one cycle per process) carries on rather than
        # repeating every step. The hint is kept in its encoded form: no quotes.
        state_file="$env_file.state"
        steps_seen=0
        errors_seen=0
        last_hint=''
        if [ -f "$state_file" ]; then
            . "$state_file"
        fi
        idle=0
        while :; do
            said=0
            if [ -n "$log" ] && [ -f "$log" ]; then
                n=$(step_lines | wc -l | tr -d ' ')
                if [ "$n" -gt "$steps_seen" ]; then
                    step_lines | tail -n $((n - steps_seen)) | while read -r item; do d=$(describe "$item"); [ -n "$d" ] && post "$d"; done
                    steps_seen=$n
                    said=1
                fi
                n=$(error_lines | wc -l | tr -d ' ')
                if [ "$n" -gt "$errors_seen" ]; then
                    error_lines | tail -n $((n - errors_seen)) | tail -n 5 | while read -r e; do post "Installer: $e"; done
                    errors_seen=$n
                    said=1
                fi
                hint=$(progress_hint)
                hint_enc=$(enc "$hint")
                if [ -n "$hint" ] && [ "$hint_enc" != "$last_hint" ]; then
                    post "$hint"
                    last_hint=$hint_enc
                    said=1
                fi
                printf "steps_seen=%s\nerrors_seen=%s\nlast_hint='%s'\n" "$steps_seen" "$errors_seen" "$last_hint" > "$state_file" 2>/dev/null || true
            fi
            if [ "$said" = 1 ]; then
                idle=0
            else
                idle=$((idle + interval))
                if [ "$idle" -ge 60 ]; then
                    beat
                    idle=0
                fi
            fi
            [ -n "$WDK_ONCE" ] && break
            sleep "$interval"
        done
        ;;
    late)
        load_env
        [ -n "$WDK_BASE_URL" ] || exit 0
        post "End-of-install steps running"
        d="$target/etc/windeploykit"
        mkdir -p "$d" 2>/dev/null || true
        save_env "$d/deploy.conf"
        printf "WDK_INSTALLED='%s'\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$d/deploy.conf"
        mkdir -p "$target/usr/local/sbin" 2>/dev/null || true
        cp "$0" "$target/usr/local/sbin/wdk-report" && chmod 0755 "$target/usr/local/sbin/wdk-report"
        ;;
    done)
        load_env
        rc=${2:-0}
        if [ "$rc" = 0 ]; then
            post "Installation finished; rebooting into the new system"
        else
            post "Installation finished; the last end-of-install step exited $rc"
        fi
        ;;
    firstboot)
        # In the installed system: the server and identity come from deploy.conf, and
        # the install's session id with them, so first boot lands on the same row.
        env_file=${WDK_ENV:-/etc/windeploykit/deploy.conf}
        load_env
        fblog=${WDK_LOG:-/var/log/wdk-firstboot.log}
        runner=${WDK_RUN:-/usr/local/sbin/wdk-run}
        post "First boot: running the first-boot script"
        started=$(date +%s)
        "$runner" >> "$fblog" 2>&1
        rc=$?
        took=$(( $(date +%s) - started ))
        post "First boot: the script exited $rc after ${took}s"
        tail -n 3 "$fblog" 2>/dev/null | while read -r l; do post "  $l"; done
        exit $rc
        ;;
    *)
        echo "usage: wdk-report start|run|late|done N|firstboot" >&2
        exit 2
        ;;
esac
exit 0

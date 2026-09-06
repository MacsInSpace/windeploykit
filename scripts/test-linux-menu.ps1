#requires -Version 7.0
<#
    .SYNOPSIS
    The Linux half of the PXE menu: a Debian task sequence reaches the installer.

    .DESCRIPTION
    d-i reads preseed/url= off the kernel command line, so the MENU ENTRY decides which
    task sequence a machine gets - there is no WinPE-style picker after boot. This gate
    holds the generated iPXE lines to that contract without a store, a mount or Caddy:

      1. An install-capable ISO with published Debian sequences becomes a submenu: one
         item per sequence, an Interactive item, Back - and a handler per item.
      2. A sequence handler carries auto=true priority=critical preseed/url=..., and all
         installer parameters sit BEFORE '---' (d-i copies what follows '---' into the
         installed system's bootloader config).
      3. Interactive carries no preseed and no auto=true (auto=true without a URL makes
         d-i stop and ask for one).
      4. Interactive is preselected unless the store's default sequence is a Debian one:
         an unattended install wipes a disk and must never be the default by accident.
      5. Boot-only entries (no netboot initrd) and Live media never get a submenu.
      6. Every item line uses a real tab (iPXE's separator; a backtick-t literal breaks
         goto ${target}) and the whole menu is ASCII.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppSidecarProjectRoot = $RepoRoot
$script:AppState = @{ IsReady = $true }
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
foreach ($lib in @('AppProductIdentity', 'Ipc', 'SidecarParams', 'AppPlatform', 'AppPaths', 'AppHttp', 'AppElevation', 'AppNativeProcess', 'AppSidecarJobs', 'AppPluginGates', 'PxeBootPlugin')) {
    . (Join-Path $SidecarRoot "lib/$lib.ps1")
}

$script:fail = 0
function Check($label, [scriptblock]$test) {
    $ok = $false
    $msg = ''
    try { $ok = [bool](& $test) } catch { $ok = $false; $msg = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK  ] $label" }
    else {
        $script:fail++
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($msg) { Write-Host "         $msg" -ForegroundColor DarkRed }
    }
}

# Inventory rows exactly as Get-AppPxeBootLinuxBootInventory shapes them.
function New-Entry([string]$id, [string]$mode) {
    @{
        id            = $id
        isoFileName   = "$id.iso"
        label         = 'Debian GNU/Linux 13.6.0 Trixie amd64 installer'
        kernelHttpRel = 'iso-mount/tok/install.amd/vmlinuz'
        initrdHttpRel = if ($mode -eq 'netboot') { 'linux/debian/trixie-amd64-e7667ff9/initrd.gz' } else { 'iso-mount/tok/install.amd/gtk/initrd.gz' }
        kernelArgs    = if ($mode -eq 'netboot') { 'vga=788 mirror/country=manual mirror/http/hostname=deb.debian.org mirror/http/directory=/debian --- quiet' } else { 'vga=788 --- quiet' }
        installMode   = $mode
        note          = if ($mode -eq 'netboot') { 'Installer: netboot initrd (d-i 20250803+deb13u6) + packages from the mounted ISO' } else { 'NOTE: installer files not fetched' }
        codename      = 'trixie'
        arch          = 'amd64'
        platform      = 'debian'
    }
}
function New-UbuntuEntry([string]$id) {
    @{
        id            = $id
        isoFileName   = 'ubuntu-24.04.4-live-server-amd64.iso'
        label         = 'Ubuntu-Server 24.04.4 LTS Noble Numbat amd64 installer'
        kernelHttpRel = 'iso-mount/utok/casper/vmlinuz'
        initrdHttpRel = 'iso-mount/utok/casper/initrd'
        kernelArgs    = 'ip=dhcp url=${http_base}/iso/ubuntu-24.04.4-live-server-amd64.iso cloud-config-url=${http_base}/linux/ubuntu/cloud-config-none'
        installMode   = 'casper'
        note          = 'Installer: Ubuntu live server - the ISO streams from this machine, packages from the Ubuntu archive'
        codename      = 'noble'
        arch          = 'amd64'
        platform      = 'ubuntu'
    }
}
$seqs = @(
    @{ id = 'campuscast-receiver'; name = 'CampusCast receiver'; cfgHttpRel = 'TaskSequences/campuscast-receiver.cfg'; isDefault = $false; installer = ''; platform = 'debian' }
    @{ id = 'lab-desktop';         name = 'Lab desktop';         cfgHttpRel = 'TaskSequences/lab-desktop.cfg';         isDefault = $false; installer = ''; platform = 'debian' }
)
$ubuntuSeqs = @(
    @{ id = 'ubuntu-lab'; name = 'Ubuntu lab'; cfgHttpRel = 'TaskSequences/autoinstall/ubuntu-lab/'; isDefault = $false; installer = ''; platform = 'ubuntu' }
)
$tab = [char]9

Write-Host 'Kernel arguments:'
Check 'preseed args land before --- and keep what follows it' {
    $r = Add-AppPxeBootDebianPreseedKernelArgs -KernelArgs 'vga=788 --- quiet' -PreseedHttpRel 'TaskSequences/x.cfg'
    $r -eq 'vga=788 auto=true priority=critical hw-detect/firmware-lookup=never preseed/url=${http_base}/TaskSequences/x.cfg --- quiet'
}
Check 'preseed args append when there is no separator' {
    (Add-AppPxeBootDebianPreseedKernelArgs -KernelArgs 'vga=788' -PreseedHttpRel '/TaskSequences/x.cfg') -eq 'vga=788 auto=true priority=critical hw-detect/firmware-lookup=never preseed/url=${http_base}/TaskSequences/x.cfg'
}
Check 'installer mirror args name the Debian mirror, the suite and the country=manual switch, before ---' {
    $r = Add-AppPxeBootDebianInstallerKernelArgs -KernelArgs 'vga=788 --- quiet' -Codename 'trixie'
    ($r -match '^vga=788 mirror/country=manual mirror/protocol=http mirror/http/hostname=\S+ mirror/http/directory=/\S* mirror/http/proxy= mirror/suite=trixie netcfg/choose_interface=auto --- quiet$')
}
Check 'the signed mirror is verified - no allow_unauthenticated anywhere' {
    -not ((Add-AppPxeBootDebianInstallerKernelArgs -KernelArgs '' -Codename 'trixie') -match 'allow_unauthenticated')
}
Check 'the default mirror parses to host + directory' {
    $m = Get-AppPxeBootDebianMirrorHostDirectory
    ([string]$m.host -match '^[a-z0-9.-]+$') -and ([string]$m.directory -match '^/')
}

Write-Host 'Submenu:'
$lines = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences $seqs)
$text = $lines -join "`n"
Check 'install-capable entry opens a submenu titled for the ISO' {
    ($lines[0] -eq ':lnx_deb') -and ($lines[1] -eq 'menu Debian GNU/Linux 13.6.0 Trixie amd64 installer - task sequence')
}
Check 'one item per sequence, tab-separated, labelled with the sequence name' {
    ($lines -contains "item lnx_deb__ts_campuscast_receiver${tab}CampusCast receiver") -and ($lines -contains "item lnx_deb__ts_lab_desktop${tab}Lab desktop")
}
Check 'Interactive and Back items are offered' {
    ($lines -contains "item lnx_deb__manual${tab}Interactive install (no task sequence)") -and ($lines -contains "item start${tab}Back")
}
Check 'Interactive is preselected when no Debian sequence is the default' {
    ($lines -contains 'choose --default lnx_deb__manual target || goto start') -and ($lines -contains 'goto ${target}')
}
Check 'a Debian default sequence is preselected instead' {
    $d = @(@{ id = 'lab-desktop'; name = 'Lab desktop'; cfgHttpRel = 'TaskSequences/lab-desktop.cfg'; isDefault = $true; installer = '' })
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences $d)
    $l -contains 'choose --default lnx_deb__ts_lab_desktop target || goto start'
}

Write-Host 'Sequence handler:'
$seqBlock = @()
$grab = $false
foreach ($l in $lines) {
    if ($l -eq ':lnx_deb__ts_campuscast_receiver') { $grab = $true }
    if ($grab) { $seqBlock += $l; if ($l -eq '') { break } }
}
$seqKernel = [string](@($seqBlock | Where-Object { $_ -like 'kernel *' }) | Select-Object -First 1)
Check 'sequence handler exists and boots the ISO kernel with the netboot initrd' {
    ($seqBlock.Count -gt 0) -and ($seqKernel -like 'kernel ${http_base}/iso-mount/tok/install.amd/vmlinuz initrd=initrd.gz *') -and ($seqBlock -contains 'initrd ${http_base}/linux/debian/trixie-amd64-e7667ff9/initrd.gz')
}
Check 'sequence handler carries preseed/url for its .cfg, unattended, before ---' {
    $seqKernel -match ' auto=true priority=critical hw-detect/firmware-lookup=never preseed/url=\$\{http_base\}/TaskSequences/campuscast-receiver\.cfg --- quiet$'
}
Check 'sequence handler keeps the mirror args (the preseed has no mirror block on purpose)' {
    ($seqKernel -match ' mirror/country=manual ') -and ($seqKernel -match ' mirror/http/directory=/debian ')
}
Check 'sequence handler warns that the disk will be wiped, then returns to the menu on failure' {
    ($seqBlock -contains 'echo Task sequence: CampusCast receiver - unattended, the disk named in the sequence will be wiped.') -and ($seqBlock -contains 'goto start')
}

Write-Host 'Interactive handler:'
$manBlock = @()
$grab = $false
foreach ($l in $lines) {
    if ($l -eq ':lnx_deb__manual') { $grab = $true }
    if ($grab) { $manBlock += $l; if ($l -eq '') { break } }
}
$manKernel = [string](@($manBlock | Where-Object { $_ -like 'kernel *' }) | Select-Object -First 1)
Check 'Interactive boots the same kernel and initrd with no preseed and no auto=true' {
    ($manBlock.Count -gt 0) -and ($manKernel -notmatch 'preseed/url') -and ($manKernel -notmatch 'auto=true') -and ($manKernel -match ' mirror/http/directory=/debian ')
}

Write-Host 'No submenu where it makes no sense:'
Check 'a boot-only entry (no netboot initrd) is a straight boot even with sequences published' {
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_iso' 'iso')) -Sequences $seqs)
    ($l[0] -eq ':lnx_iso') -and -not ($l -like 'menu *') -and -not (($l -join "`n") -match 'preseed/url') -and (@($l | Where-Object { $_ -like 'kernel *' }).Count -eq 1)
}
Check 'an install-capable entry with no sequences is a straight boot' {
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences @())
    ($l[0] -eq ':lnx_deb') -and -not ($l -like 'menu *') -and -not (($l -join "`n") -match 'preseed/url')
}
Check 'null sequences are tolerated' {
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences $null)
    ($l[0] -eq ':lnx_deb') -and -not ($l -like 'menu *')
}

Write-Host 'Hygiene:'
Check 'every item line uses a real tab and none carries a backtick-t literal' {
    $items = @($lines | Where-Object { $_ -like 'item *' -and $_ -notlike 'item --gap*' })
    ($items.Count -eq 4) -and -not ($items | Where-Object { $_ -notmatch "^item \S+$tab\S" }) -and -not ($text.Contains('`t'))
}
Check 'the whole menu is ASCII' {
    -not ($text -match '[^\x09\x0A\x20-\x7E]')
}
Check 'sequence item ids are plain labels derived from the sequence id' {
    (Get-AppPxeBootLinuxSequenceMenuItemId -EntryId 'lnx_deb' -SequenceId 'Camp.us-Cast_9') -eq 'lnx_deb__ts_camp_us_cast_9'
}

Write-Host 'Installer binding (the panel Linux installer field):'
$bound = @(
    @{ id = 'trixie-only';   name = 'Trixie only';   cfgHttpRel = 'TaskSequences/trixie-only.cfg';   isDefault = $false; installer = 'debian-trixie-amd64' }
    @{ id = 'bookworm-only'; name = 'Bookworm only'; cfgHttpRel = 'TaskSequences/bookworm-only.cfg'; isDefault = $false; installer = 'debian-bookworm-amd64' }
    @{ id = 'any-debian';    name = 'Any Debian';    cfgHttpRel = 'TaskSequences/any-debian.cfg';    isDefault = $false; installer = '' }
)
$bl = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences $bound)
Check 'a trixie amd64 entry lists the sequences bound to it and the unbound ones, not the bookworm one' {
    ($bl -contains "item lnx_deb__ts_trixie_only${tab}Trixie only") -and ($bl -contains "item lnx_deb__ts_any_debian${tab}Any Debian") -and -not ($bl -like "item lnx_deb__ts_bookworm_only*")
}
Check 'an entry with only foreign-bound sequences is a straight boot, no submenu' {
    $only = @(@{ id = 'bookworm-only'; name = 'Bookworm only'; cfgHttpRel = 'TaskSequences/bookworm-only.cfg'; isDefault = $false; installer = 'debian-bookworm-amd64' })
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences $only)
    ($l[0] -eq ':lnx_deb') -and -not ($l -like 'menu *')
}

Write-Host 'Ubuntu (casper) entries:'
$ul = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-UbuntuEntry 'lnx_ubuntu')) -Sequences ($seqs + $ubuntuSeqs))
Check 'an Ubuntu casper entry is install-capable: submenu with the Ubuntu sequence, never the Debian ones' {
    ($ul[0] -eq ':lnx_ubuntu') -and ($ul -like 'menu *') -and ($ul -contains "item lnx_ubuntu__ts_ubuntu_lab${tab}Ubuntu lab") -and -not ($ul -like 'item lnx_ubuntu__ts_campuscast*')
}
$uk = [string](@($ul | Where-Object { $_ -like 'kernel *' -and $_ -match 'autoinstall' }) | Select-Object -First 1)
Check 'the Ubuntu sequence handler arms autoinstall with the NoCloud seed directory and streams the ISO' {
    ($uk -match ' ip=dhcp url=\$\{http_base\}/iso/ubuntu-24\.04\.4-live-server-amd64\.iso') -and ($uk -match ' autoinstall ds=nocloud-net;s=\$\{http_base\}/TaskSequences/autoinstall/ubuntu-lab/ cloud-config-url=\$\{http_base\}/TaskSequences/autoinstall/ubuntu-lab/user-data$') -and ($uk -notmatch 'preseed/url') -and ($uk -notmatch 'cloud-config-none')
}
Check 'the Ubuntu Interactive handler has no autoinstall' {
    $mk = [string](@($ul | Where-Object { $_ -like 'kernel *' -and $_ -notmatch 'autoinstall' }) | Select-Object -First 1)
    # ...but it does tell cloud-init its config is empty, or cloud-init eats the ISO named by url=
    ($mk -match 'casper/vmlinuz') -and ($mk -match ' url=') -and ($mk -match 'cloud-config-url=\$\{http_base\}/linux/ubuntu/cloud-config-none')
}
Check 'a Debian entry never lists an Ubuntu sequence' {
    $dl = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @((New-Entry 'lnx_deb' 'netboot')) -Sequences ($seqs + $ubuntuSeqs))
    ($dl -like 'menu *') -and -not ($dl -like 'item lnx_deb__ts_ubuntu*')
}

Write-Host 'ISO-less netboot pairs (store-resident kernel + initrd):'
$pair = @{ dirName = 'trixie-amd64'; codename = 'trixie'; arch = 'amd64'; diVersion = '20250803+deb13u6'; flavour = 'gtk'; fetchedAt = '2026-09-06T00:00:00Z'; sizeBytes = 95000000; linuxHttpRel = 'linux/debian/trixie-amd64/linux'; initrdHttpRel = 'linux/debian/trixie-amd64/initrd.gz' }
$row = ConvertTo-AppPxeBootDebianNetbootInventoryRow -Pair $pair
Check 'a store pair becomes an install-capable entry booting the store kernel and initrd' {
    ($row.id -eq 'lnx_debian_trixie_amd64') -and ($row.installMode -eq 'netboot') -and ($row.kernelHttpRel -eq 'linux/debian/trixie-amd64/linux') -and ($row.initrdHttpRel -eq 'linux/debian/trixie-amd64/initrd.gz')
}
Check 'its label names the release and says it is a network install' {
    $row.label -eq 'Debian 13 (trixie) amd64 installer (network)'
}
Check 'its kernel args point d-i at the mirror for the right suite, before ---' {
    ([string]$row.kernelArgs -match '^vga=788 mirror/country=manual mirror/protocol=http mirror/http/hostname=\S+ mirror/http/directory=/\S* mirror/http/proxy= mirror/suite=trixie netcfg/choose_interface=auto --- quiet$')
}
Check 'arm64 pairs carry no vga= (a BIOS-era framebuffer switch)' {
    $p2 = @{} + $pair
    $p2.arch = 'arm64'
    $p2.dirName = 'trixie-arm64'
    $r2 = ConvertTo-AppPxeBootDebianNetbootInventoryRow -Pair $p2
    ([string]$r2.kernelArgs -notmatch 'vga=') -and ($r2.id -eq 'lnx_debian_trixie_arm64')
}
Check 'a store pair gets the task-sequence submenu like an ISO entry' {
    $l = @(Get-AppPxeBootLinuxMenuHandlerLines -Entries @($row) -Sequences $seqs)
    ($l[0] -eq ':lnx_debian_trixie_amd64') -and ($l -like 'menu *') -and (($l -join "`n") -match 'preseed/url=\$\{http_base\}/TaskSequences/campuscast-receiver\.cfg')
}
Check 'only sane release/arch names are accepted as pair names' {
    (Test-AppPxeBootDebianNetbootPairName -Codename 'trixie' -Arch 'amd64') -and -not (Test-AppPxeBootDebianNetbootPairName -Codename '../x' -Arch 'amd64') -and -not (Test-AppPxeBootDebianNetbootPairName -Codename 'trixie' -Arch 'i386')
}
Check 'a directory that is not a complete pair reads as nothing' {
    $null -eq (Read-AppPxeBootDebianNetbootPair -DirName 'no-such-pair-amd64')
}

if ($script:fail -gt 0) {
    Write-Host "linux menu: $($script:fail) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'linux menu: all checks passed'
exit 0

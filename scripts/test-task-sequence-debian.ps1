#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    A Debian task sequence compiles to a preseed the installer will accept.

    .DESCRIPTION
    The Linux half of the task sequence store. A preseed is the equivalent of
    unattend.xml, and the traps are different enough to be worth a gate of their
    own: line endings the installer takes literally, Windows-only step types that
    must not be mistranslated, shell quoting in late_command, and the mirror
    block that must stay out so the PXE kernel arguments win.

    The worked example is CampusCast, the digital signage receiver: a Debian
    machine that installs unattended and then runs one script at first boot.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'sidecar/lib/PxeBootTaskSequences.ps1')

$script:fail = 0
function Check($label, [scriptblock]$test) {
    $ok = $false
    try { $ok = [bool](& $test) } catch { $ok = $false; $msg = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK  ] $label" }
    else {
        $script:fail++
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($msg) { Write-Host "         $msg" -ForegroundColor DarkRed }
    }
}

# A sequence as the panel would save it: a CampusCast receiver.
$seq = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{
    id       = 'campuscast-receiver'
    name     = 'CampusCast receiver'
    platform = 'debian'
    kind     = 'server'            # a Windows role: must be discarded
    enabled  = $true
    fields   = [pscustomobject]@{
        hostname            = 'campuscast'
        domain              = 'local'
        locale              = 'en_AU.UTF-8'
        keymap              = 'us'
        timezone            = 'Australia/Melbourne'
        username            = 'ccadmin'
        userFullName        = 'CampusCast Admin'
        userPasswordCrypted = '$6$saltsalt$3Nq1exampleexamplehashvaluegoeshere'
        disk                = '/dev/nvme0n1 /dev/sda /dev/mmcblk0'
        partitionRecipe     = 'atomic'
        packages            = 'openssh-server ca-certificates'
        runScriptUrl        = 'http://10.0.0.5:8080/linux/run/campuscast-receiver.sh'
    }
    steps    = @(
        [pscustomobject]@{ type = 'cmd';  description = 'no suspend'; command = "systemctl mask sleep.target suspend.target" }
        [pscustomobject]@{ type = 'reg';  description = 'windows only'; path = 'HKLM\Software\X'; name = 'Y'; valueType = 'REG_SZ'; data = '1' }
        [pscustomobject]@{ type = 'pwsh'; description = 'windows only'; command = 'Write-Host hi' }
    )
})

Write-Host "`nRecord:"
Check 'platform is kept' { $seq.platform -eq 'debian' }
Check 'the Windows client/server role is discarded' { [string]$seq.kind -eq '' }
Check 'an absent platform still means windows' {
    (ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'legacy'; name = 'Legacy' })).platform -eq 'windows'
}
Check 'an unknown platform is refused, not passed through' {
    (ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'x'; name = 'X'; platform = 'plan9' })).platform -eq 'windows'
}

$cfg = Build-AppPxeBootTaskSequencePreseed -Sequence $seq

Write-Host "`nPreseed:"
Check 'renders something' { $cfg.Length -gt 400 }
Check 'a Windows sequence renders no preseed' {
    $w = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'w'; name = 'W'; platform = 'windows' })
    (Build-AppPxeBootTaskSequencePreseed -Sequence $w) -eq ''
}
Check 'no CR anywhere: d-i takes a CR as part of the value' { $cfg -notmatch "`r" }
Check 'hostname and domain are set' {
    $cfg -match 'netcfg/get_hostname string campuscast' -and $cfg -match 'netcfg/get_domain string local'
}
Check 'the password is a hash, never a plaintext field' {
    $cfg -match 'passwd/user-password-crypted password \$6\$' -and $cfg -notmatch 'passwd/user-password '
}
Check 'root login is disabled' { $cfg -match 'passwd/root-login boolean false' }
Check 'the trixie recipes server and small_disk are accepted, anything else falls back to atomic' {
    $mk = { param($r) ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = "r-$r"; name = 'R'; platform = 'debian'; fields = [pscustomobject]@{ partitionRecipe = $r } }) }
    ((Build-AppPxeBootTaskSequencePreseed -Sequence (& $mk 'small_disk')) -match 'choose_recipe select small_disk') -and
    ((Build-AppPxeBootTaskSequencePreseed -Sequence (& $mk 'server')) -match 'choose_recipe select server') -and
    ((Build-AppPxeBootTaskSequencePreseed -Sequence (& $mk 'bogus')) -match 'choose_recipe select atomic')
}
Check 'UEFI install is forced: d-i must not stop to ask when another OS sits on a disk in BIOS mode' {
    $cfg -match 'partman-efi/non_efi_system boolean true'
}
Check 'no mirror block: the PXE kernel arguments own the mirror' {
    $cfg -notmatch 'mirror/http/hostname' -and $cfg -notmatch 'mirror/http/directory'
}
Check 'the disk list and recipe are carried through' {
    $cfg -match 'partman-auto/disk string /dev/nvme0n1' -and $cfg -match 'choose_recipe select atomic'
}
Check 'extra packages are included' { $cfg -match 'pkgsel/include string openssh-server ca-certificates' }
Check 'an invalid recipe falls back rather than being written out' {
    $bad = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{
        id = 'b'; name = 'B'; platform = 'debian'; fields = [pscustomobject]@{ partitionRecipe = 'rm -rf' } })
    (Build-AppPxeBootTaskSequencePreseed -Sequence $bad) -match 'choose_recipe select atomic'
}

Write-Host "`nlate_command:"
Check 'it exists and is one logical line' {
    @($cfg -split "`n" | Where-Object { $_ -match '^d-i preseed/late_command' }).Count -eq 1
}
Check 'the run script is fetched and made executable' {
    $cfg -match 'wget -qO /usr/local/sbin/wdk-run' -and $cfg -match 'chmod 0755 /usr/local/sbin/wdk-run'
}
Check 'a URL carrying a shell metacharacter survives as one argument' {
    # The check that earns its place. An earlier version quoted the URL separately
    # inside an already-quoted sh -c string; for a plain URL the adjacent quoted
    # pieces simply concatenate and the command is still correct, so both `sh -n`
    # and any substring regex pass. It only comes apart when the value contains a
    # space or a metacharacter - so that is what is tested. The late_command is
    # actually executed here, with in-target and wget stubbed, and we assert what
    # wget was handed.
    $url = 'http://h/run.sh?a=1&b=2 c'
    $u = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{
        id = 'u'; name = 'U'; platform = 'debian'
        fields = [pscustomobject]@{ runScriptUrl = $url } })
    $line = @((Build-AppPxeBootTaskSequencePreseed -Sequence $u) -split "`n" |
              Where-Object { $_ -match '^d-i preseed/late_command string ' })[0]
    $body = $line -replace '^d-i preseed/late_command string ', ''
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $dir
    $out = Join-Path $dir 'got'
    # in-target runs the command here rather than in a chroot; wget records the
    # argument it was given, one per line, so a split shows up as two lines.
    # Stubs as real executables on PATH: "in-target" cannot be a shell function,
    # because a hyphen is not valid in a POSIX function name.
    $bin = Join-Path $dir 'bin'; $null = New-Item -ItemType Directory -Path $bin
    foreach ($pair in @(
        @{ n = 'in-target'; b = 'exec "$@"' }
        @{ n = 'wget';      b = "shift 2; printf '%s\n' `"`$@`" >> '$out'" }
        @{ n = 'chmod';     b = 'exit 0' }
        @{ n = 'systemctl'; b = 'exit 0' })) {
        $f = Join-Path $bin $pair.n
        [System.IO.File]::WriteAllText($f, "#!/bin/sh`n$($pair.b)`n")
        & chmod 0755 $f
    }
    [System.IO.File]::WriteAllText((Join-Path $dir 's.sh'), "$body`n")
    $prev = $env:PATH
    $env:PATH = "${bin}:${prev}"
    try { & sh (Join-Path $dir 's.sh') 2>&1 | Out-Null } finally { $env:PATH = $prev }
    $got = @(if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out } else { @() })
    $ok = ($got.Count -eq 1 -and $got[0] -eq $url)
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    $ok
}
Check 'a one-shot unit is registered and disables itself' {
    $cfg -match 'wdk-firstboot.service' -and $cfg -match 'ExecStartPost=/bin/systemctl disable wdk-firstboot.service'
}
Check 'cmd steps run in-target, not in the installer ramdisk' {
    $cfg -match "in-target sh -c 'systemctl mask sleep.target suspend.target'"
}
Check 'reg and pwsh steps are skipped, not mistranslated' {
    $cfg -notmatch 'HKLM' -and $cfg -notmatch 'Write-Host'
}
Check 'a single quote in a command cannot end the shell string early' {
    $q = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{
        id = 'q'; name = 'Q'; platform = 'debian'
        steps = @([pscustomobject]@{ type = 'cmd'; command = "echo 'it''s here'; rm -rf /" }) })
    $out = Build-AppPxeBootTaskSequencePreseed -Sequence $q
    # every embedded quote is closed and reopened, so the payload stays one argument
    $out -match "'\\\\''" -or $out -match "'\\''"
}
Check 'no late_command line at all when there is nothing to run' {
    $n = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'n'; name = 'N'; platform = 'debian' })
    (Build-AppPxeBootTaskSequencePreseed -Sequence $n) -notmatch 'late_command'
}

if ($script:fail) {
    Write-Host "`ndebian task sequence: $($script:fail) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`ndebian task sequence: all checks passed"

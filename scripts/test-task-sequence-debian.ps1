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
# The lib logs on the vault path; standalone there is no sidecar to log to.
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $root 'sidecar/lib/PxeBootTaskSequences.ps1')

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
Check 'crypt(3) SHA-512 matches the reference vector (and openssl passwd -6)' {
    (ConvertTo-AppPxeBootTsSha512Crypt -Password 'Hello world!' -Salt 'saltstring') -eq '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1'
}
Check 'a salt longer than 16 characters is truncated the way crypt does' {
    (ConvertTo-AppPxeBootTsSha512Crypt -Password 'Hello world!' -Salt 'saltstringsaltstring') -like '$6$saltstringsaltst$*'
}
Check 'no salt given: a fresh 16-character salt from the crypt alphabet, 86-character hash' {
    $h = ConvertTo-AppPxeBootTsSha512Crypt -Password 'wdk'
    ($h -match '^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$') -and ($h -ne (ConvertTo-AppPxeBootTsSha512Crypt -Password 'wdk'))
}
Check 'a typed password is hashed on save and the clear text does not survive the record' {
    $r = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'pw'; name = 'PW'; platform = 'debian'; fields = [pscustomobject]@{ userPassword = 'Hello world!'; username = 'wdk' } })
    (-not $r.fields.Contains('userPassword')) -and ([string]$r.fields['userPasswordCrypted'] -match '^\$6\$') -and ((Build-AppPxeBootTaskSequencePreseed -Sequence $r) -notmatch 'Hello world')
}
Check 'a blank typed password keeps the saved hash' {
    $r = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'pw2'; name = 'PW'; platform = 'debian'; fields = [pscustomobject]@{ userPassword = ''; userPasswordCrypted = '$6$keep$keep' } })
    (-not $r.fields.Contains('userPassword')) -and ([string]$r.fields['userPasswordCrypted'] -eq '$6$keep$keep')
}
# Vault-backed first user: the credential's login becomes the Linux user, its password is
# hashed at publish. Stubs stand in for the vault (the sidecar's Test-AppSidecarCommand
# fallback finds them by name).
function Get-AppVaultCredential { param($Name) if ($Name -eq 'lab-admin') { [pscustomobject]@{ UserName = 'CORP\Lab.Admin'; Password = $null } } }
function Get-AppVaultPlainSecret { param($Name) if ($Name -eq 'lab-admin') { 'Hello world!' } }
function Get-AppVaultSecretInfo { param($Name) [pscustomobject]@{ label = 'Lab admin'; fullName = 'Lab Administrator' } }
Check 'a vault first user: login lower-cased and cleaned, full name from the vault, password hashed, nothing in clear' {
    $v = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'v'; name = 'V'; platform = 'debian'; fields = [pscustomobject]@{ userSource = 'vault'; userVaultSecret = 'lab-admin'; username = 'ignored'; userFullName = 'Ignored' } })
    $out = Build-AppPxeBootTaskSequencePreseed -Sequence $v
    ($out -match 'passwd/username string labadmin') -and ($out -match 'passwd/user-fullname string Lab Administrator') -and ($out -match 'passwd/user-password-crypted password \$6\$') -and ($out -notmatch 'Hello world') -and ($out -notmatch 'ignored')
}
Check 'a vault credential that is missing leaves the password out so the installer asks' {
    $v = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'v2'; name = 'V2'; platform = 'debian'; fields = [pscustomobject]@{ userSource = 'vault'; userVaultSecret = 'no-such' } })
    (Build-AppPxeBootTaskSequencePreseed -Sequence $v) -match 'No password hash set'
}
Check 'a Windows login shape becomes a Linux user name' {
    ((ConvertTo-AppPxeBootTsLinuxUserName -Name 'CORP\Local.Admin') -eq 'localadmin') -and ((ConvertTo-AppPxeBootTsLinuxUserName -Name 'ops@example.com') -eq 'ops') -and ((ConvertTo-AppPxeBootTsLinuxUserName -Name '1st-user') -eq 'st-user')
}
function Get-AppPxeBootLocalHttpBaseUrl { 'http://10.0.0.1:8080' }
Check 'a library first-boot script resolves to this machine''s /Scripts/ URL in late_command' {
    $r = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'fs'; name = 'FS'; platform = 'debian'; fields = [pscustomobject]@{ runScriptFile = 'firstboot.sh' } })
    (Build-AppPxeBootTaskSequencePreseedLateCommand -Sequence $r) -match "wget -qO /usr/local/sbin/wdk-run .{0,6}http://10\.0\.0\.1:8080/Scripts/firstboot\.sh'"
}
Check 'a custom URL is used as typed, and a path-shaped script name is refused' {
    $u = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'fu'; name = 'FU'; platform = 'debian'; fields = [pscustomobject]@{ runScriptFile = 'url'; runScriptUrl = 'https://example.org/x.sh' } })
    $b = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'fb'; name = 'FB'; platform = 'debian'; fields = [pscustomobject]@{ runScriptFile = '../etc/passwd' } })
    ((Build-AppPxeBootTaskSequencePreseedLateCommand -Sequence $u) -match "'https://example\.org/x\.sh'") -and ((Build-AppPxeBootTaskSequencePreseedLateCommand -Sequence $b) -notmatch 'wdk-run')
}
Write-Host 'Scripts folder (Add... in the panel):'
$script:scriptsRoot = Join-Path ([IO.Path]::GetTempPath()) ("wdk-ts-scripts-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
function Get-AppImageLibraryRoot { param([switch]$NoCreate) $script:scriptsRoot }
function Format-AppProcessArgumentList { param($Arguments) @($Arguments) }
$null = New-Item -Path $script:scriptsRoot -ItemType Directory -Force
$stage = Join-Path $script:scriptsRoot 'stage'
$null = New-Item -Path $stage -ItemType Directory -Force
function Write-Stage($name, [byte[]]$bytes) { $p = Join-Path $stage $name; [System.IO.File]::WriteAllBytes($p, $bytes); $p }
$utf8 = [System.Text.Encoding]::UTF8
Check 'a CRLF script with a BOM lands in <library>/Scripts as plain LF, is listed, and resolves to the /Scripts/ URL' {
    $p = Write-Stage 'firstboot.sh' ([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("#!/bin/bash`r`necho hi`r`n"))
    $r = Import-AppPxeBootTsScript -SourcePath $p
    $saved = [System.IO.File]::ReadAllBytes($r.path)
    ($r.fileName -eq 'firstboot.sh') -and $r.normalized -and (-not $r.replaced) -and
        ($utf8.GetString($saved) -eq "#!/bin/bash`necho hi`n") -and ($r.url -eq 'http://10.0.0.1:8080/Scripts/firstboot.sh') -and
        (@($r.scripts) -contains 'firstboot.sh') -and (@(Get-AppPxeBootTsFirstBootScripts) -notcontains 'README.txt') -and
        (Test-Path -LiteralPath (Join-Path $script:scriptsRoot 'Scripts/README.txt'))
}
Check 'a script without a #! first line is refused - systemd would exec it and the first boot would silently do nothing' {
    $p = Write-Stage 'noshebang.sh' ($utf8.GetBytes("echo hi`n"))
    try { $null = Import-AppPxeBootTsScript -SourcePath $p; $false } catch { $_.Exception.Message -match '#!' }
}
Check 'a binary, a name with a space, and a README name are refused' {
    $b = Write-Stage 'blob.sh' ([byte[]](0x23, 0x21, 0x00, 0x01))
    $s = Write-Stage 'ok.sh' ($utf8.GetBytes("#!/bin/sh`n"))
    $bin = try { $null = Import-AppPxeBootTsScript -SourcePath $b; $false } catch { $_.Exception.Message -match 'binary' }
    $sp = try { $null = Import-AppPxeBootTsScript -SourcePath $s -TargetFileName 'first boot.sh'; $false } catch { $_.Exception.Message -match 'no spaces' }
    $rd = try { $null = Import-AppPxeBootTsScript -SourcePath $s -TargetFileName 'README.sh'; $false } catch { $_.Exception.Message -match 'README' }
    $bin -and $sp -and $rd
}
Check 'a second import of the same name needs ReplaceExisting and then reports replaced' {
    $p = Write-Stage 'firstboot.sh' ($utf8.GetBytes("#!/bin/bash`necho two`n"))
    $refused = try { $null = Import-AppPxeBootTsScript -SourcePath $p; $false } catch { $_.Exception.Message -match 'already' }
    $r = Import-AppPxeBootTsScript -SourcePath $p -ReplaceExisting
    $refused -and $r.replaced -and ([System.IO.File]::ReadAllText($r.path) -eq "#!/bin/bash`necho two`n")
}
Check 'the imported script is what the compiler names in late_command, and Remove takes it off the list' {
    $r = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'fi'; name = 'FI'; platform = 'debian'; fields = [pscustomobject]@{ runScriptFile = 'firstboot.sh' } })
    $line = Build-AppPxeBootTaskSequencePreseedLateCommand -Sequence $r
    $gone = Remove-AppPxeBootTsScript -FileName 'firstboot.sh'
    ($line -match 'Scripts/firstboot\.sh') -and $gone.removed -and (@($gone.scripts).Count -eq 0) -and
        (-not (Test-Path -LiteralPath (Join-Path $script:scriptsRoot 'Scripts/firstboot.sh'))) -and
        (-not (Remove-AppPxeBootTsScript -FileName 'firstboot.sh').removed)
}
Remove-Item -LiteralPath $script:scriptsRoot -Recurse -Force -ErrorAction SilentlyContinue
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
Check 'cmd steps run in-target through bash, not in the installer ramdisk' {
    $cfg -match "in-target bash -c 'systemctl mask sleep.target suspend.target'"
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
Check 'a sequence with nothing to run still gets the reporter late and done parts, and nothing else' {
    $n = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'n'; name = 'N'; platform = 'debian' })
    $o = Build-AppPxeBootTaskSequencePreseed -Sequence $n
    ($o -match 'late_command string \[ -f /tmp/wdk-report \] && sh /tmp/wdk-report late \|\| true; rc=\$\?; \[ -f /tmp/wdk-report \] && sh /tmp/wdk-report done \$rc; exit \$rc\n') -and ($o -notmatch 'wdk-run') -and ($o -notmatch 'in-target')
}

Write-Host "`nInstall feedback (the reporter):"
Check 'early_command fetches the reporter from the server the preseed came from and starts it, one line, no backslash' {
    $early = @($cfg -split "`n" | Where-Object { $_ -match '^d-i preseed/early_command string ' })
    ($early.Count -eq 1) -and ($early[0] -match 'preseed/url=\*\)') -and ($early[0] -match 'wget -q -O /tmp/wdk-report "\$b/linux/wdk-report\.sh" && sh /tmp/wdk-report start; true$') -and ($early[0] -notmatch '\\')
}
Check 'the late_command opens with the reporter (guarded) and closes by reporting the previous exit status' {
    $line = @($cfg -split "`n" | Where-Object { $_ -match '^d-i preseed/late_command string ' })[0]
    ($line -match 'string \[ -f /tmp/wdk-report \] && sh /tmp/wdk-report late \|\| true; in-target sh -c ') -and ($line -match '; rc=\$\?; \[ -f /tmp/wdk-report \] && sh /tmp/wdk-report done \$rc; exit \$rc$')
}
Check 'the first-boot unit runs the script through the reporter when it is there, and directly when it is not' {
    $cfg -match 'ExecStart=/bin/sh -c "if \[ -x /usr/local/sbin/wdk-report \]; then exec /usr/local/sbin/wdk-report firstboot; fi; exec /usr/local/sbin/wdk-run"'
}
Check 'the early_command runs as written under sh with wget stubbed: it fetches the reporter and starts it' {
    $early = @($cfg -split "`n" | Where-Object { $_ -match '^d-i preseed/early_command string ' })[0] -replace '^d-i preseed/early_command string ', ''
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $dir
    $bin = Join-Path $dir 'bin'; $null = New-Item -ItemType Directory -Path $bin
    $got = Join-Path $dir 'got'
    # wget records its URL; the fetched "reporter" records the mode it was started with.
    $wgetStub = "#!/bin/sh`n" + 'printf ''%s\n'' "$4" >> ''' + $got + '''; printf ''echo started $1 >> ' + $got + '\n'' > "$3"' + "`n"
    $catStub = "#!/bin/sh`n" + 'if [ "$1" = /proc/cmdline ]; then echo ''BOOT_IMAGE=/linux auto=true preseed/url=http://10.0.0.9:8080/TaskSequences/z.cfg --- quiet''; else exec /bin/cat "$@"; fi' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $bin 'wget'), $wgetStub)
    [System.IO.File]::WriteAllText((Join-Path $bin 'cat'), $catStub)
    foreach ($f in @('wget', 'cat')) { & chmod 0755 (Join-Path $bin $f) }
    [System.IO.File]::WriteAllText((Join-Path $dir 'e.sh'), "$early`n")
    $prev = $env:PATH
    $env:PATH = "${bin}:${prev}"
    try { & sh (Join-Path $dir 'e.sh') 2>&1 | Out-Null } finally { $env:PATH = $prev }
    $lines = @(if (Test-Path -LiteralPath $got) { Get-Content -LiteralPath $got } else { @() })
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath '/tmp/wdk-report' -Force -ErrorAction SilentlyContinue
    ($lines.Count -eq 2) -and ($lines[0] -eq 'http://10.0.0.9:8080/linux/wdk-report.sh') -and ($lines[1] -eq 'started start')
}

if ($script:fail) {
    Write-Host "`ndebian task sequence: $($script:fail) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`ndebian task sequence: all checks passed"

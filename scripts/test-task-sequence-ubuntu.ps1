#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    An Ubuntu task sequence compiles to a Subiquity autoinstall the installer will accept.

    .DESCRIPTION
    Ubuntu 22.04+ has no d-i: the live-server installer reads a cloud-init NoCloud seed
    (user-data + meta-data) named on the kernel line. The traps mirror the preseed's -
    LF only, a crypt hash never a clear password, no apt mirror block, Windows-only step
    types skipped - plus YAML's own: a shell payload full of quotes has to survive as one
    single-quoted scalar, and the storage match takes one disk where d-i took a list.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
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
function New-Seq($fields, $steps = @()) {
    ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{
        id = 'ubuntu-lab'; name = 'Ubuntu lab'; platform = 'ubuntu'; kind = 'server'; enabled = $true
        fields = [pscustomobject]$fields; steps = $steps
    })
}

$seq = New-Seq @{
    hostname = 'lab-01'; locale = 'en_AU.UTF-8'; keymap = 'us'; timezone = 'Australia/Melbourne'
    username = 'wdk'; userFullName = 'WDK Test'; userPassword = 'Hello world!'
    disk = '/dev/vda'; storageLayout = 'lvm'; packages = 'curl git'; sshServer = '1'
    runScriptFile = 'url'; runScriptUrl = 'http://10.0.0.1:8080/Scripts/first boot&run.sh'
}
$out = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $seq

Write-Host 'Record:'
Check 'platform ubuntu is kept and the Windows role is discarded' { ($seq.platform -eq 'ubuntu') -and ([string]$seq.kind -eq '') }
Check 'the typed password left the record as a crypt hash' { (-not $seq.fields.Contains('userPassword')) -and ([string]$seq.fields['userPasswordCrypted'] -match '^\$6\$') }

Write-Host 'Autoinstall:'
Check 'renders a cloud-config with an autoinstall version 1 block' { ($out -match '^#cloud-config\n') -and ($out -match '\nautoinstall:\n  version: 1\n') }
Check 'no CR anywhere' { $out -notmatch "`r" }
Check 'a Windows sequence renders no autoinstall' {
    $w = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([pscustomobject]@{ id = 'w'; name = 'W'; platform = 'windows' })
    (Build-AppPxeBootTaskSequenceAutoinstall -Sequence $w) -eq ''
}
Check 'locale, keyboard layout and time zone' {
    ($out -match "  locale: 'en_AU.UTF-8'") -and ($out -match "  keyboard:\n    layout: 'us'") -and ($out -match "  timezone: 'Australia/Melbourne'")
}
Check 'identity carries hostname, user, real name and the HASH - never the clear password' {
    ($out -match "  identity:\n    hostname: 'lab-01'\n    username: 'wdk'\n    realname: 'WDK Test'\n    password: '[$]6[$]") -and ($out -notmatch 'Hello world')
}
Check 'ssh server installed with password logins allowed' { $out -match "  ssh:\n    install-server: true\n    allow-pw: true" }
Check 'a single disk becomes a path match; the layout name is carried' { $out -match "  storage:\n    layout:\n      name: lvm\n      match:\n        path: '/dev/vda'" }
Check 'the default disk list becomes the largest disk, direct layout' {
    $d = New-Seq @{ userPassword = 'x' }
    (Build-AppPxeBootTaskSequenceAutoinstall -Sequence $d) -match "      name: direct\n      match:\n        size: largest"
}
Check 'an unknown layout falls back to direct' {
    (Build-AppPxeBootTaskSequenceAutoinstall -Sequence (New-Seq @{ userPassword = 'x'; storageLayout = 'zfs' })) -match "      name: direct"
}
Check 'extra packages become a list' { $out -match "  packages:\n    - 'curl'\n    - 'git'\n" }
Check 'no SSH server when switched off' {
    (Build-AppPxeBootTaskSequenceAutoinstall -Sequence (New-Seq @{ userPassword = 'x'; sshServer = '0' })) -match "install-server: false"
}
Check 'no apt mirror block: the archive default is the point' { $out -notmatch 'mirror' -and $out -notmatch "\n  apt:" }
Check 'no password hash: the installer asks for the user instead of a passwordless account' {
    $n = New-Seq @{ username = 'wdk' }
    $o = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $n
    ($o -match "  interactive-sections:\n    - identity") -and ($o -notmatch "  identity:")
}
Check 'the installer refreshes nothing and reboots when done' { ($out -match "  refresh-installer:\n    update: false") -and ($out -match "  shutdown: reboot\n$") }

Write-Host 'Late commands:'
Check 'late-commands run through curtin in-target, one YAML item each, after the reporter part' {
    ($out -match "  late-commands:\n    - '\[ -f /tmp/wdk-report \] && sh /tmp/wdk-report late \|\| true'\n    - 'curtin in-target --target=/target -- sh -c ") -and (@($out -split "`n" | Where-Object { $_ -like "    - 'curtin in-target*" }).Count -ge 2)
}
Check 'early-commands fetch the reporter from the NoCloud seed server (wget, then curl) and start it' {
    $e = @($out -split "`n" | Where-Object { $_ -match '^    - .*wdk-report' })
    ($out -match "  early-commands:\n    - 'for w in ") -and ($e[0] -match 'ds=nocloud-net\*\)') -and ($e[0] -match 'cut -d= -f3-') -and ($e[0] -match '\(wget -q -O /tmp/wdk-report "\$b/linux/wdk-report\.sh" \|\| curl -fsSo /tmp/wdk-report "\$b/linux/wdk-report\.sh"\) && sh /tmp/wdk-report start; true''$')
}
Check 'a URL with a space and an ampersand survives YAML and both shell levels as one argument' {
    # Pull the fetch item back out of the YAML (single-quoted scalar: '' is a quote), run
    # it with the tools stubbed, and see what wget was handed.
    $item = @($out -split "`n" | Where-Object { $_ -match "wdk-run" }) | Select-Object -First 1
    $scalar = ([string]$item -replace '^    - ', '')
    if ($scalar -notmatch "^'(.*)'$") { throw "not a single-quoted scalar: $scalar" }
    $cmd = $Matches[1] -replace "''", "'"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wdk-ai-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -Path $tmp -ItemType Directory -Force
    try {
        $log = Join-Path $tmp 'args.log'
        foreach ($stub in @(
            @{ n = 'curtin'; b = 'shift; [ "$1" = "--target=/target" ] && shift; [ "$1" = "--" ] && shift; exec "$@"' }
            @{ n = 'wget';   b = "printf '%s\n' `"`$#`" `"`$3`" > '$log'" }
            @{ n = 'chmod';  b = 'exit 0' })) {
            $path = Join-Path $tmp $stub.n
            [System.IO.File]::WriteAllText($path, "#!/bin/sh`n$($stub.b)`n", (New-Object System.Text.UTF8Encoding $false))
            & chmod +x $path
        }
        $env:PATH = "$tmp" + [IO.Path]::PathSeparator + $env:PATH
        & sh -c $cmd 2>$null
        $got = @(Get-Content -LiteralPath $log)
        ($got[0] -eq '3') -and ($got[1] -eq 'http://10.0.0.1:8080/Scripts/first boot&run.sh')
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check 'cmd steps become late-commands; reg and pwsh steps are skipped, not mistranslated' {
    $st = New-Seq @{ userPassword = 'x' } @(
        [pscustomobject]@{ type = 'cmd'; description = 'c'; command = 'echo it is done' }
        [pscustomobject]@{ type = 'reg'; description = 'r'; op = 'add'; path = 'HKLM\\x'; name = 'n'; value = 'v' }
        [pscustomobject]@{ type = 'pwsh'; description = 'p'; command = 'Get-Date' }
    )
    $o = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $st
    # Inside the YAML single-quoted scalar the shell's own quote appears doubled.
    ($o -match "curtin in-target --target=/target -- bash -c ''echo it is done''") -and ($o -notmatch 'Get-Date') -and ($o -notmatch 'HKLM')
}
Check 'a single quote inside a step is doubled for YAML and survives as one command' {
    $st = New-Seq @{ userPassword = 'x' } @([pscustomobject]@{ type = 'cmd'; description = 'c'; command = "echo it's" })
    $o = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $st
    $item = @($o -split "`n" | Where-Object { $_ -match "echo it" }) | Select-Object -First 1
    # YAML: the scalar is single-quoted, so every literal quote inside it appears doubled.
    ([string]$item -match "^    - '.*''.*'$")
}

Write-Host 'Vault first user:'
function Get-AppVaultCredential { param($Name) if ($Name -eq 'lab-admin') { [pscustomobject]@{ UserName = 'CORP\Lab.Admin' } } }
function Get-AppVaultPlainSecret { param($Name) if ($Name -eq 'lab-admin') { 'Hello world!' } }
function Get-AppVaultSecretInfo { param($Name) [pscustomobject]@{ label = 'Lab admin'; fullName = 'Lab Administrator' } }
Check 'a vault first user: cleaned login, vault full name, hashed password, nothing in clear' {
    $v = New-Seq @{ userSource = 'vault'; userVaultSecret = 'lab-admin'; username = 'ignored' }
    $o = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $v
    ($o -match "    username: 'labadmin'") -and ($o -match "    realname: 'Lab Administrator'") -and ($o -match "    password: '[$]6[$]") -and ($o -notmatch 'Hello world') -and ($o -notmatch 'ignored')
}

Write-Host 'Publish:'
Check 'publish writes autoinstall/<id>/user-data and meta-data, prunes a removed one, and keeps the default valid' {
    $lib = Join-Path ([IO.Path]::GetTempPath()) ("wdk-ai-pub-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $store = Join-Path $lib 'store'
    $null = New-Item -Path $store -ItemType Directory -Force
    $script:AppState = @{ IsReady = $true; RuntimeConfig = @{ imageLibraryRoot = $lib } }
    function Get-AppPxeBootStoreRoot { $store }
    function Get-AppImageLibraryRoot { param([switch]$NoCreate) $lib }
    try {
        $seqs = @(
            [pscustomobject]@{ id = 'ubuntu-lab'; name = 'Ubuntu lab'; platform = 'ubuntu'; enabled = $true; fields = [pscustomobject]@{ userPassword = 'x' } }
            [pscustomobject]@{ id = 'ubuntu-old'; name = 'Old'; platform = 'ubuntu'; enabled = $true; fields = [pscustomobject]@{ userPassword = 'x' } }
        )
        $null = Save-AppPxeBootTaskSequences -Sequences $seqs -DefaultSequenceId 'ubuntu-lab'
        $ud = Join-Path $lib 'TaskSequences/autoinstall/ubuntu-lab/user-data'
        $md = Join-Path $lib 'TaskSequences/autoinstall/ubuntu-lab/meta-data'
        $first = (Test-Path -LiteralPath $ud) -and ((Get-Content -LiteralPath $md -Raw) -eq "instance-id: wdk-ubuntu-lab`n") -and ((Get-Content -LiteralPath $ud -Raw) -match '^#cloud-config')
        $marker = (Get-Content -LiteralPath (Join-Path $lib 'TaskSequences/_default.txt') -Raw) -eq "ubuntu-lab`r`n"
        # drop the second one: its seed directory must go
        $null = Save-AppPxeBootTaskSequences -Sequences @($seqs[0]) -DefaultSequenceId 'ubuntu-lab'
        $pruned = -not (Test-Path -LiteralPath (Join-Path $lib 'TaskSequences/autoinstall/ubuntu-old'))
        $first -and $marker -and $pruned
    } finally {
        Remove-Item -LiteralPath $lib -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:fail) {
    Write-Host "`nubuntu task sequence: $($script:fail) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nubuntu task sequence: all checks passed"

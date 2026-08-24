#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the install image catalog and the task sequence image binding.
.DESCRIPTION
    Craig, 2026-08-22: "The task sequence should have the Install.Wim so we can select
    it in the Task Sequence." Three things have to hold for that to work end to end:

      1. wimlib's `info` output parses into the editions a tech picks from.
      2. A sequence stores {sourceId,index} and only that - a malformed or
         path-shaped sourceId must never reach the published share.
      3. The client half (startnet.cmd) reads TaskSequences/index.json and turns a row
         into a URL + index against the host it is already talking to, ignoring the
         iPXE-only ${next-server} form of the URL.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppState = @{ IsReady = $true }
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
. (Join-Path $SidecarRoot 'lib/AppProductIdentity.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootTaskSequences.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootPlugin.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootInstallImages.ps1')

$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  [OK  ] $Name" }
    catch { Write-Host "  [FAIL] $Name - $($_.Exception.Message)"; $script:failures++ }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") { throw "$What - expected '$Expected', got '$Actual'" }
}

# Real wimlib output (Windows Server 2025 evaluation media, 4 images).
$wimlibInfo = @'
WIM Information:
----------------
Path:           /Volumes/mount/sources/install.wim
GUID:           0x85c0d8f533184149a9aff5dedc654606
Image Count:    4
Boot Index:     0

Available Images:
-----------------
Index:                  1
Name:                   Windows Server 2025 SERVERSTANDARDCORE
Description:            Windows Server 2025 SERVERSTANDARDCORE
Total Bytes:            11322334455
Architecture:           x86_64
Edition ID:             ServerStandardEval
Installation Type:      Server Core
Build:                  26100

Index:                  2
Name:                   Windows Server 2025 SERVERSTANDARD
Description:            Windows Server 2025 SERVERSTANDARD
Total Bytes:            24700000000
Architecture:           x86_64
Edition ID:             ServerStandardEval
Installation Type:      Server
Build:                  26100

Index:                  4
Name:                   Windows Server 2025 SERVERDATACENTER
Description:            Windows Server 2025 SERVERDATACENTER
Total Bytes:            24700000001
Architecture:           x86_64
Edition ID:             ServerDatacenterEval
Installation Type:      Server
Build:                  26100
'@

Write-Host 'wimlib info parsing:'

Test-Case 'every image is found, in order' {
    # Assign, then wrap: the parser emits ONE array object so an empty WIM stays an
    # empty array over IPC. @(call) would nest it - this bit the handler too.
    $parsed = ConvertFrom-AppPxeBootWimlibInfo -Text $wimlibInfo
    $images = @($parsed)
    Assert-Equal 3 $images.Count 'image count'
    Assert-Equal '1,2,4' (($images | ForEach-Object { $_.index }) -join ',') 'indexes'
}

Test-Case 'fields a tech picks by are kept' {
    # Assign, then wrap: the parser emits ONE array object so an empty WIM stays an
    # empty array over IPC. @(call) would nest it - this bit the handler too.
    $parsed = ConvertFrom-AppPxeBootWimlibInfo -Text $wimlibInfo
    $images = @($parsed)
    $second = $images[1]
    Assert-Equal 'Windows Server 2025 SERVERSTANDARD' $second.name 'name'
    Assert-Equal 'ServerStandardEval' $second.edition 'edition'
    Assert-Equal 'Server' $second.installType 'install type'
    Assert-Equal 'x86_64' $second.arch 'arch'
    Assert-Equal 26100 $second.build 'build'
    Assert-Equal 24700000000 $second.sizeBytes 'size'
}

Test-Case 'the WIM Information header is not mistaken for an image' {
    # Assign, then wrap: the parser emits ONE array object so an empty WIM stays an
    # empty array over IPC. @(call) would nest it - this bit the handler too.
    $parsed = ConvertFrom-AppPxeBootWimlibInfo -Text $wimlibInfo
    $images = @($parsed)
    foreach ($i in $images) { if ($i.index -eq 0) { throw 'header parsed as an image' } }
}

Test-Case 'empty and garbage input return an empty array, not $null' {
    foreach ($text in @('', 'no images here', "WIM Information:`n----`nPath: x")) {
        $r = ConvertFrom-AppPxeBootWimlibInfo -Text $text
        if ($null -eq $r) { throw 'returned $null' }
        Assert-Equal 0 @($r).Count "count for '$text'"
    }
}

Test-Case 'the dropdown label names the edition and index' {
    # Assign, then wrap: the parser emits ONE array object so an empty WIM stays an
    # empty array over IPC. @(call) would nest it - this bit the handler too.
    $parsed = ConvertFrom-AppPxeBootWimlibInfo -Text $wimlibInfo
    $images = @($parsed)
    Assert-Equal 'Windows Server 2025 SERVERSTANDARD (index 2)' (Get-AppPxeBootInstallImageLabel -Image $images[1]) 'label'
    Assert-Equal 'Image 7 (index 7)' (Get-AppPxeBootInstallImageLabel -Image ([ordered]@{ index = 7; name = ''; edition = '' })) 'fallback label'
}

Test-Case 'a single-image WIM still parses as an array of one' {
    $one = ConvertFrom-AppPxeBootWimlibInfo -Text "Available Images:`n-----`nIndex:   1`nName:    Windows 11 Pro`n"
    Assert-Equal 1 @($one).Count 'count'
    Assert-Equal 'Windows 11 Pro' @($one)[0].name 'name'
}

Write-Host ''
Write-Host 'Task sequence image binding:'

$baseSeq = @{ id = 'srv'; name = 'Server'; kind = 'server'; enabled = $true; fields = @{} }

Test-Case 'a valid binding round-trips' {
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item ($baseSeq + @{
            image = @{ sourceId = 'iso:Win11_24H2.iso'; index = 6; editionName = 'Windows 11 Pro' }
        })
    Assert-Equal 'iso:Win11_24H2.iso' $rec.image.sourceId 'sourceId'
    Assert-Equal 6 $rec.image.index 'index'
    Assert-Equal 'Windows 11 Pro' $rec.image.editionName 'edition name'
}

Test-Case 'no image means no key at all (tech picks at the device)' {
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $baseSeq
    if ($rec.Contains('image')) { throw 'image key should be absent' }
    $rec2 = ConvertTo-AppPxeBootTaskSequenceRecord -Item ($baseSeq + @{ image = @{ sourceId = ''; index = 3 } })
    if ($rec2.Contains('image')) { throw 'blank sourceId should not bind' }
}

Test-Case 'path-shaped and unknown-kind source ids are refused' {
    foreach ($bad in @('iso:../../etc/passwd', 'iso:sub/dir.iso', 'iso:sub\dir.iso', 'ftp:x.iso', 'Win11.iso', 'iso:')) {
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item ($baseSeq + @{ image = @{ sourceId = $bad; index = 1 } })
        if ($rec.Contains('image')) { throw "'$bad' should have been refused" }
    }
}

Test-Case 'index is clamped into a sane range' {
    foreach ($pair in @(@(0, 1), @(-4, 1), @(999, 64), @(3, 3))) {
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item ($baseSeq + @{
                image = @{ sourceId = 'wim:soe.wim'; index = $pair[0] }
            })
        Assert-Equal $pair[1] $rec.image.index "index $($pair[0])"
    }
}

Test-Case 'resolve turns a binding into share path + HTTP URL' {
    $catalog = @(
        [ordered]@{
            id = 'iso:Win11.iso'; kind = 'iso'; fileName = 'Win11.iso'; label = 'Win11'
            sharePath = '.mounts\win11-abcd1234\sources\install.wim'
            httpPath = 'iso-wim/win11-abcd1234/install.wim'
            imagesKnown = $true
            images = @([ordered]@{ index = 6; name = 'Windows 11 Pro'; edition = 'Professional' })
        }
    )
    $resolved = Resolve-AppPxeBootTaskSequenceImage -Image @{ sourceId = 'iso:Win11.iso'; index = 6 } -Catalog $catalog -HttpPort 8080 -LanIp '10.0.1.147'
    Assert-Equal '.mounts\win11-abcd1234\sources\install.wim' $resolved.sharePath 'share path'
    Assert-Equal 'http://10.0.1.147:8080/iso-wim/win11-abcd1234/install.wim' $resolved.httpUrl 'http url'
    Assert-Equal 'Windows 11 Pro' $resolved.editionName 'edition name from the catalog'
    Assert-Equal 6 $resolved.index 'index'
    if ($null -ne (Resolve-AppPxeBootTaskSequenceImage -Image @{ sourceId = 'iso:Gone.iso'; index = 1 } -Catalog $catalog)) {
        throw 'a missing source should resolve to $null'
    }
    if ($null -ne (Resolve-AppPxeBootTaskSequenceImage -Image $null -Catalog $catalog)) {
        throw 'no image should resolve to $null'
    }
}

Test-Case 'an ISO mount token is stable and URL-safe' {
    $token = Get-AppPxeBootIsoMountToken -IsoFileName 'Windows 11 (24H2) x64.iso'
    if ($token -notmatch '^[A-Za-z0-9._-]+$') { throw "token is not URL-safe: $token" }
    Assert-Equal $token (Get-AppPxeBootIsoMountToken -IsoFileName 'Windows 11 (24H2) x64.iso') 'stable across calls'
    if ($token -eq (Get-AppPxeBootIsoMountToken -IsoFileName 'Windows 11 (23H2) x64.iso')) { throw 'two ISOs collided' }
}

Write-Host ''
Write-Host 'ISO attach bookkeeping (macOS):'

Test-Case 'hdiutil info parses to image path + dev entry + mount point' {
    # The exact record behind the 2026-08-23 orphan: attached at a temp dir, so every
    # Start borrowed it and the share never got .mounts/<token>.
    $json = '{"images":[{"image-path":"/Users/x/Public/WinDeployKit/iso/SERVER_EVAL.iso","system-entities":[{"dev-entry":"/dev/disk14","mount-point":"/private/var/folders/9h/T/sm-pxe-iso-972bf356"}]},{"image-path":"/Users/x/other.dmg","system-entities":[{"dev-entry":"/dev/disk13"},{"dev-entry":"/dev/disk13s1","mount-point":"/Volumes/Other"}]}]}'
    $rows = @(ConvertFrom-AppPxeBootHdiutilInfo -Json $json)
    Assert-Equal 3 $rows.Count 'entity rows'
    $iso = @($rows | Where-Object { $_.imagePath -like '*SERVER_EVAL.iso' })
    Assert-Equal 1 $iso.Count 'iso rows'
    Assert-Equal '/dev/disk14' $iso[0].devEntry 'dev entry'
    Assert-Equal '/private/var/folders/9h/T/sm-pxe-iso-972bf356' $iso[0].mountPoint 'mount point'
    $whole = @($rows | Where-Object { $_.devEntry -eq '/dev/disk13' })[0]
    Assert-Equal '' $whole.mountPoint 'an entity with no mount point reads as empty, not missing'
    Assert-Equal 0 @(ConvertFrom-AppPxeBootHdiutilInfo -Json '').Count 'empty input'
    Assert-Equal 0 @(ConvertFrom-AppPxeBootHdiutilInfo -Json 'not json').Count 'garbage input'
}

Test-Case 'a serve mount is re-homed, never borrowed from outside the share' {
    # Pinned by text: Mount-AppPxeBootIsoReadOnly must re-home (detach + attach at the
    # requested path) when the image is attached elsewhere, and must surface hdiutil's
    # own reason instead of a bare "failed to mount ISO".
    $src = (Get-Command Mount-AppPxeBootIsoReadOnly).ScriptBlock.ToString()
    if ($src -notmatch 'Disconnect-AppPxeBootAttachedIso') { throw 'no re-home path' }
    if ($src -notmatch 're-homing to') { throw 'no re-home log line' }
    if ($src -notmatch 'hdiutil: \$reason') { throw 'attach failure does not carry the hdiutil reason' }
    $reader = (Get-Command Get-AppPxeBootInstallImagesForSource).ScriptBlock.ToString()
    if ($reader -notmatch 'isoMountDir') { throw 'the edition reader does not mount at the canonical .mounts path' }
}

Write-Host ''
if ($failures -gt 0) { Write-Host "install images: $failures failure(s)"; exit 1 }
Write-Host 'install images: all checks passed'
exit 0

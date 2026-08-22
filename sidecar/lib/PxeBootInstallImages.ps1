# Netboot install image catalog - what a task sequence can actually deploy.
#
# A task sequence used to describe only what happens AFTER the image lands (the
# unattend). Craig, 2026-08-22: "The task sequence should have the Install.Wim so we
# can select it in the Task Sequence." So a sequence now names one image + index, and
# the client stops guessing.
#
# Sources, both already on the deploy share:
#   * every ISO in <library>/iso - install.wim is served in place out of the read-only
#     mount at <library>/.mounts/<token>/sources/install.wim (SMB) and
#     /iso-wim/<token>/install.wim (HTTP). Nothing is extracted.
#   * every *.wim / *.ffu dropped in <library>/WIMs.
#
# Editions come from `wimlib-imagex info`, which needs the ISO mounted. Mounting on a
# panel load would be slow and noisy, so the parsed list is cached in the PXE store
# keyed by file name + size + mtime: an ISO is read once, ever, unless it changes.
# An ISO that is already attached (Netboot's mount-and-serve) is borrowed, never
# re-attached - macOS refuses a second attach with "Resource busy".

# Return shapes, because the difference caused three bugs in one day:
#   * the two functions callers reach for - Get-AppPxeBootInstallImageSources and
#     Get-AppPxeBootInstallImageCatalog - emit their entries plainly, so `@(call)`
#     does the obvious thing and an empty library is an empty array.
#   * the image readers below emit ONE array object (`, $images`) because they must
#     distinguish "read it, no images" from "not read yet" ($null). Assign them to a
#     variable first; `@(call)` on those nests the array one level deeper.
$script:AppPxeBootInstallImageCacheVersion = 1

function Get-AppPxeBootInstallImageCachePath {
    Join-Path (Get-AppPxeBootStoreRoot) 'install-images.json'
}

function ConvertFrom-AppPxeBootWimlibInfo {
    <#
    .SYNOPSIS
        Parse `wimlib-imagex info <wim>` into one entry per image.
    .NOTES
        The "Available Images:" section is blank-line separated blocks of "Key: value".
        Only the fields a tech picks by are kept.
    #>
    param([AllowEmptyString()][string]$Text)
    $images = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $images }
    $inImages = $false
    $current = $null
    foreach ($lineRaw in ($Text -split "`r?`n")) {
        $line = [string]$lineRaw
        if ($line -match '^Available Images:') { $inImages = $true; continue }
        if (-not $inImages) { continue }
        if ($line -match '^-+$') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current) { $images += , $current; $current = $null }
            continue
        }
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9 /]*?):\s*(.*)$') { continue }
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        switch ($key) {
            'Index' {
                if ($current) { $images += , $current }
                $current = [ordered]@{
                    index       = [int]$value
                    name        = ''
                    description = ''
                    edition     = ''
                    installType = ''
                    arch        = ''
                    build       = ''
                    sizeBytes   = [long]0
                }
            }
            'Name'                 { if ($current) { $current.name = $value } }
            'Description'          { if ($current) { $current.description = $value } }
            'Edition ID'           { if ($current) { $current.edition = $value } }
            'Installation Type'    { if ($current) { $current.installType = $value } }
            'Architecture'         { if ($current) { $current.arch = $value } }
            'Build'                { if ($current) { $current.build = $value } }
            'Total Bytes'          { if ($current) { $current.sizeBytes = [long]($value -replace '[^0-9]', '') } }
        }
    }
    if ($current) { $images += , $current }
    , $images
}

function Get-AppPxeBootWimImageList {
    <#
    .SYNOPSIS
        Images inside one WIM. Empty array when wimlib is missing or the file is not
        readable - callers show "editions unavailable", they do not fail.
    #>
    param([Parameter(Mandatory)][string]$WimPath)
    if (-not (Test-Path -LiteralPath $WimPath)) { return , @() }
    $tool = Get-AppPxeBootWimlibImagexPath
    if (-not $tool) {
        Write-SidecarLogVerbose 'PXE boot: install image list skipped - wimlib-imagex missing'
        return , @()
    }
    try {
        $out = & $tool info $WimPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-SidecarLogVerbose "PXE boot: wimlib info failed for $WimPath (exit $LASTEXITCODE)"
            return , @()
        }
        return , (ConvertFrom-AppPxeBootWimlibInfo -Text $out)
    } catch {
        Write-SidecarLogVerbose "PXE boot: wimlib info failed for $WimPath - $($_.Exception.Message)"
        return , @()
    }
}

function Get-AppPxeBootInstallImageSourceId {
    param(
        [Parameter(Mandatory)][ValidateSet('iso', 'wim')][string]$Kind,
        [Parameter(Mandatory)][string]$FileName
    )
    "${Kind}:$FileName"
}

function Get-AppPxeBootInstallImageSources {
    <#
    .SYNOPSIS
        Every install image source on the deploy share, without reading any WIM.
        Cheap enough to call on every panel load.
    #>
    $sources = @()
    $lib = $null
    try { $lib = Get-AppImageLibraryPaths } catch { return , $sources }

    foreach ($iso in @(Get-ChildItem -LiteralPath $lib.isoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $token = Get-AppPxeBootIsoMountToken -IsoFileName $iso.Name
        $sources += , [ordered]@{
            id         = Get-AppPxeBootInstallImageSourceId -Kind 'iso' -FileName $iso.Name
            kind       = 'iso'
            fileName   = $iso.Name
            label      = ([IO.Path]::GetFileNameWithoutExtension($iso.Name) -replace '_', ' ')
            sizeBytes  = [long]$iso.Length
            modifiedAt = $iso.LastWriteTimeUtc.ToString('o')
            # Where the client finds it: Z:\<sharePath> over SMB, /<httpPath> over HTTP.
            sharePath  = ".mounts\$token\sources\install.wim"
            httpPath   = "iso-wim/$token/install.wim"
            sourcePath = $iso.FullName
        }
    }
    foreach ($wim in @(Get-ChildItem -LiteralPath $lib.wimsDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.wim', '.ffu' } | Sort-Object Name)) {
        $sources += , [ordered]@{
            id         = Get-AppPxeBootInstallImageSourceId -Kind 'wim' -FileName $wim.Name
            kind       = 'wim'
            fileName   = $wim.Name
            label      = $wim.Name
            sizeBytes  = [long]$wim.Length
            modifiedAt = $wim.LastWriteTimeUtc.ToString('o')
            sharePath  = "WIMs\$($wim.Name)"
            httpPath   = "WIMs/$([Uri]::EscapeDataString($wim.Name))"
            sourcePath = $wim.FullName
        }
    }
    # Plain output: callers write @(Get-AppPxeBootInstallImageSources).
    $sources
}

function Read-AppPxeBootInstallImageCache {
    $path = Get-AppPxeBootInstallImageCachePath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $version = if ($obj.PSObject.Properties['version']) { [int]$obj.version } else { 0 }
        if ($version -ne $script:AppPxeBootInstallImageCacheVersion) { return @{} }
        $map = @{}
        $entries = if ($obj.PSObject.Properties['entries']) { $obj.entries } else { $null }
        foreach ($p in @($entries.PSObject.Properties)) {
            $map[[string]$p.Name] = $p.Value
        }
        return $map
    } catch {
        return @{}
    }
}

function Write-AppPxeBootInstallImageCache {
    param([Parameter(Mandatory)][hashtable]$Map)
    $path = Get-AppPxeBootInstallImageCachePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    $tmp = "$path.tmp"
    (@{ version = $script:AppPxeBootInstallImageCacheVersion; entries = $Map } | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-AppPxeBootInstallImageCacheKey {
    param([Parameter(Mandatory)]$Source)
    '{0}|{1}|{2}' -f $Source.id, $Source.sizeBytes, $Source.modifiedAt
}

function Get-AppPxeBootInstallImagesForSource {
    <#
    .SYNOPSIS
        Images for one source, reading the WIM only when the cache misses.
    .NOTES
        For an ISO this mounts read-only (borrowing an existing attach) for the length
        of one wimlib info call. -NoRead returns whatever is cached and never mounts,
        which is what a panel load wants.
    #>
    param(
        [Parameter(Mandatory)]$Source,
        [hashtable]$Cache,
        [switch]$NoRead
    )
    $key = Get-AppPxeBootInstallImageCacheKey -Source $Source
    if ($Cache -and $Cache.ContainsKey($key)) {
        return , @($Cache[$key])
    }
    if ($NoRead) { return $null }

    if ([string]$Source.kind -eq 'wim') {
        if ([IO.Path]::GetExtension([string]$Source.fileName) -ieq '.ffu') {
            # FFU is a whole-disk capture: one image, no index list to read.
            return , @([ordered]@{ index = 1; name = [string]$Source.fileName; description = 'Full flash update image'; edition = ''; installType = 'FFU'; arch = ''; build = ''; sizeBytes = [long]$Source.sizeBytes })
        }
        return , (Get-AppPxeBootWimImageList -WimPath ([string]$Source.sourcePath))
    }

    $mount = $null
    try {
        $mount = Mount-AppPxeBootIsoReadOnly -IsoPath ([string]$Source.sourcePath)
        $wim = Join-Path ([string]$mount.mountPath) 'sources/install.wim'
        if (-not (Test-Path -LiteralPath $wim)) {
            $wim = Join-Path ([string]$mount.mountPath) 'sources/install.esd'
        }
        if (-not (Test-Path -LiteralPath $wim)) {
            Write-SidecarLogVerbose "PXE boot: no sources/install.wim in $($Source.fileName)"
            return , @()
        }
        return , (Get-AppPxeBootWimImageList -WimPath $wim)
    } catch {
        Write-SidecarLog "PXE boot: could not read editions from $($Source.fileName) - $($_.Exception.Message)"
        return $null
    } finally {
        if ($mount -and -not [bool]$mount.borrowed) {
            Dismount-AppPxeBootIso -Mount $mount
        }
    }
}

function Get-AppPxeBootInstallImageCatalog {
    <#
    .SYNOPSIS
        Every selectable install image, with its editions when they are known.
    .PARAMETER Read
        Read any source the cache does not cover (mounts ISOs). Without it the call is
        a directory listing plus a JSON read - safe on every panel load.
    #>
    param(
        [switch]$Read,
        [string[]]$OnlySourceIds
    )
    $sources = @(Get-AppPxeBootInstallImageSources)
    $cache = Read-AppPxeBootInstallImageCache
    $dirty = $false
    $entries = @()
    foreach ($source in $sources) {
        $wanted = (-not $OnlySourceIds) -or ($OnlySourceIds -contains [string]$source.id)
        $images = Get-AppPxeBootInstallImagesForSource -Source $source -Cache $cache -NoRead:(-not ($Read -and $wanted))
        $known = $null -ne $images
        if ($known -and $Read -and $wanted) {
            $cache[(Get-AppPxeBootInstallImageCacheKey -Source $source)] = @($images)
            $dirty = $true
        }
        $entry = [ordered]@{
            id         = [string]$source.id
            kind       = [string]$source.kind
            fileName   = [string]$source.fileName
            label      = [string]$source.label
            sizeBytes  = [long]$source.sizeBytes
            sharePath  = [string]$source.sharePath
            httpPath   = [string]$source.httpPath
            imagesKnown = [bool]$known
            images     = @(if ($known) { $images } else { @() })
        }
        $entries += , $entry
    }
    if ($dirty) {
        # Drop cache entries whose source is gone or changed (key carries size+mtime).
        $live = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($s in $sources) { [void]$live.Add((Get-AppPxeBootInstallImageCacheKey -Source $s)) }
        $pruned = @{}
        foreach ($k in @($cache.Keys)) { if ($live.Contains([string]$k)) { $pruned[[string]$k] = $cache[$k] } }
        try { Write-AppPxeBootInstallImageCache -Map $pruned } catch {
            Write-SidecarLogVerbose "PXE boot: install image cache write failed - $($_.Exception.Message)"
        }
    }
    # Plain output, same as the sources list: @(Get-AppPxeBootInstallImageCatalog).
    $entries
}

function Get-AppPxeBootInstallImageLabel {
    <#
    .SYNOPSIS
        What the dropdown shows for one image: "Windows 11 Pro (index 6)".
    #>
    param($Image)
    if (-not $Image) { return '' }
    $name = [string]$Image.name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$Image.edition }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "Image $($Image.index)" }
    '{0} (index {1})' -f $name, [int]$Image.index
}

function Resolve-AppPxeBootTaskSequenceImage {
    <#
    .SYNOPSIS
        Turn a sequence's saved {sourceId,index} into everything a client needs to
        apply it. Returns $null when the sequence has no image (= tech picks at the
        device, the behaviour before this existed) or when the source has gone away.
    #>
    param(
        $Image,
        $Catalog,
        [int]$HttpPort = 0,
        [string]$LanIp
    )
    if (-not $Image) { return $null }
    $sourceId = ([string](Get-AppPxeBootTsProp -Item $Image -Name 'sourceId')).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceId)) { return $null }
    $index = [int](Get-AppPxeBootTsProp -Item $Image -Name 'index')
    if ($index -lt 1) { $index = 1 }
    $entries = if ($null -ne $Catalog) { @($Catalog) } else { @(Get-AppPxeBootInstallImageCatalog) }
    $entry = $entries | Where-Object { [string]$_.id -eq $sourceId } | Select-Object -First 1
    if (-not $entry) { return $null }
    $match = @($entry.images) | Where-Object { [int]$_.index -eq $index } | Select-Object -First 1
    $editionName = if ($match) { [string]$match.name } else { ([string](Get-AppPxeBootTsProp -Item $Image -Name 'editionName')) }
    $resolved = [ordered]@{
        sourceId    = [string]$entry.id
        kind        = [string]$entry.kind
        fileName    = [string]$entry.fileName
        label       = [string]$entry.label
        index       = $index
        editionName = $editionName
        sharePath   = [string]$entry.sharePath
        httpPath    = [string]$entry.httpPath
        httpUrl     = ''
    }
    if ($HttpPort -gt 0) {
        $hostPart = if ([string]::IsNullOrWhiteSpace($LanIp)) { '${next-server}' } else { $LanIp }
        $resolved.httpUrl = "http://${hostPart}:$HttpPort/$($entry.httpPath)"
    }
    $resolved
}

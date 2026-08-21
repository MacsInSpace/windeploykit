# Sidecar IPC handlers -- Plugin.PxeBoot
# Mechanically extracted from windeploykit-sidecar.ps1 (2026-08 handler split).
# Functions only -- no top-level code. Dispatch resolves Handle-$Cmd by name at call time.

function Handle-GetPathFreeSpace {
    param([int]$Id, $Params)
    # Free/total bytes on the volume backing a path (image library root by
    # default). Used for download pre-flight checks. Read-only, best-effort.
    $path = Get-AppSidecarParam -Params $Params -Name 'path'
    if (-not $path) {
        Set-AppImageLibraryRuntimeRootFromParams -Params $Params
        $path = Get-AppImageLibraryRoot -NoCreate
    }
    $path = [string]$path
    $free = $null; $total = $null; $ok = $false
    try {
        $probe = $path
        # Walk up to an existing ancestor so DriveInfo resolves even before the
        # target folder is created.
        while ($probe -and -not (Test-Path -LiteralPath $probe)) {
            $parent = Split-Path -Parent $probe
            if (-not $parent -or $parent -eq $probe) { break }
            $probe = $parent
        }
        $rootPath = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $probe -ErrorAction Stop).Path)
        $drive = [System.IO.DriveInfo]::new($rootPath)
        $free = [long]$drive.AvailableFreeSpace
        $total = [long]$drive.TotalSize
        $ok = $true
    } catch {
        Write-SidecarLog "GetPathFreeSpace: $($_.Exception.Message)"
    }
    Write-SidecarResponse -Id $Id -Data @{ ok = $ok; path = $path; freeBytes = $free; totalBytes = $total }
}

function Handle-SetImageLibraryRoot {
    param([int]$Id, $Params)
    # Persist the user-chosen ISO & driver root into runtime config so promote,
    # import, Caddy routes, and the SMB share all agree with the UI.
    $root = Get-AppSidecarParam -Params $Params -Name 'imageLibraryRoot'
    if (-not $root) {
        $root = Get-AppSidecarParam -Params $Params -Name 'root'
    }
    if ($root) {
        Set-AppImageLibraryRuntimeRoot -Root ([string]$root)
    }
    $effective = Get-AppImageLibraryRoot -NoCreate
    Write-SidecarResponse -Id $Id -Data @{ ok = $true; imageLibraryRoot = $effective }
}

function Handle-GetPxeBootPluginConfig {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $data = Get-AppPxeBootPluginConfig
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-SetPxeBootPluginConfig {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $httpPort = Get-AppSidecarParam -Params $Params -Name 'httpPort'
    $interfaceId = Get-AppSidecarParam -Params $Params -Name 'interfaceId'
    $deployMenuUrl = Get-AppSidecarParam -Params $Params -Name 'deployMenuUrl'
    $isoCatalogSource = Get-AppSidecarParam -Params $Params -Name 'isoCatalogSource'
    $tftpd64Path = Get-AppSidecarParam -Params $Params -Name 'tftpd64Path'
    $tftpMode = Get-AppSidecarParam -Params $Params -Name 'tftpMode'
    $tftpBootFile = Get-AppSidecarParam -Params $Params -Name 'tftpBootFile'
    $autoBootDefault = Get-AppSidecarParam -Params $Params -Name 'autoBootDefault'
    $smbShareEnabled = Get-AppSidecarParam -Params $Params -Name 'smbShareEnabled'
    $smbOverlayEnabled = Get-AppSidecarParam -Params $Params -Name 'smbOverlayEnabled'
    $imageDeployerOverlayCreds = Get-AppSidecarParam -Params $Params -Name 'imageDeployerOverlayCreds'
    $imageDeployerOverlayShare = Get-AppSidecarParam -Params $Params -Name 'imageDeployerOverlayShare'
    $isoMountServe = Get-AppSidecarParam -Params $Params -Name 'isoMountServe'
    $skipMenuRegen = Get-AppSidecarParam -Params $Params -Name 'skipMenuRegen'
    $setParams = @{
        HttpPort         = $(if ($null -ne $httpPort) { [int]$httpPort } else { 8080 })
        InterfaceId      = $(if ($interfaceId) { [string]$interfaceId } else { $null })
        DeployMenuUrl    = $(if ($deployMenuUrl) { [string]$deployMenuUrl } else { $null })
        IsoCatalogSource = $(if ($isoCatalogSource) { [string]$isoCatalogSource } else { $null })
        Tftpd64Path      = $(if ($tftpd64Path) { [string]$tftpd64Path } else { $null })
        TftpMode         = $(if ($tftpMode) { [string]$tftpMode } else { 'router' })
        SkipMenuRegen    = ([bool]$skipMenuRegen)
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'tftpBootFile') {
        $setParams['TftpBootFile'] = [string]$tftpBootFile
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'autoBootDefault') {
        $setParams['AutoBootDefault'] = [bool]$autoBootDefault
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'smbShareEnabled') {
        $setParams['SmbShareEnabled'] = [bool]$smbShareEnabled
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'smbOverlayEnabled') {
        $setParams['SmbOverlayEnabled'] = [bool]$smbOverlayEnabled
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'imageDeployerOverlayCreds') {
        $setParams['ImageDeployerOverlayCreds'] = [string]$imageDeployerOverlayCreds
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'imageDeployerOverlayShare') {
        $setParams['ImageDeployerOverlayShare'] = [string]$imageDeployerOverlayShare
    }
    if (Test-AppSidecarParamPresent -Params $Params -Name 'isoMountServe') {
        $setParams['IsoMountServe'] = [bool]$isoMountServe
    }
    $data = Set-AppPxeBootPluginConfig @setParams
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootPluginStatus {
    param([int]$Id, $Params)
    $data = Get-AppPxeBootStatus -SkipCatalogSync -SkipLayoutProbe -SkipHeavyChecks
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootLogTail {
    param([int]$Id, $Params)
    $maxLines = Get-AppSidecarParam -Params $Params -Name 'maxLines'
    $n = 200
    if ($maxLines) { [void][int]::TryParse([string]$maxLines, [ref]$n) }
    $data = Get-AppPxeBootLogTail -MaxLines $n
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootImagingClients {
    param([int]$Id, $Params)
    $data = @{ clients = @(Get-AppPxeBootImagingClients) }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootImagingClientLog {
    param([int]$Id, $Params)
    $serial = Get-AppSidecarParam -Params $Params -Name 'serial'
    $maxLines = Get-AppSidecarParam -Params $Params -Name 'maxLines'
    $n = 300
    if ($maxLines) { [void][int]::TryParse([string]$maxLines, [ref]$n) }
    $data = Get-AppPxeBootImagingClientLog -Serial ([string]$serial) -MaxLines $n
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ClearPxeBootImagingLogs {
    param([int]$Id, $Params)
    $data = Clear-AppPxeBootImagingLogs
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-StartPxeBootServices {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $httpOnly = Get-AppSidecarParam -Params $Params -Name 'httpOnly'
    $tftpOnly = Get-AppSidecarParam -Params $Params -Name 'tftpOnly'
    $minimal = Get-AppSidecarParam -Params $Params -Name 'minimal'
    $data = Start-AppPxeBootServices `
        -HttpOnly:([bool]$httpOnly) `
        -TftpOnly:([bool]$tftpOnly) `
        -Minimal:([bool]$minimal)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-StopPxeBootServices {
    param([int]$Id, $Params)
    $httpOnly = Get-AppSidecarParam -Params $Params -Name 'httpOnly'
    $tftpOnly = Get-AppSidecarParam -Params $Params -Name 'tftpOnly'
    $minimal = Get-AppSidecarParam -Params $Params -Name 'minimal'
    Stop-AppPxeBootServices `
        -HttpOnly:([bool]$httpOnly) `
        -TftpOnly:([bool]$tftpOnly) `
        -Minimal:([bool]$minimal) | Out-Null
    $data = Get-AppPxeBootStatus
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-OpenPxeBootStoreFolder {
    param([int]$Id, $Params)
    $data = Open-AppPxeBootStoreFolder
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-RevealSmbdForFullDiskAccess {
    param([int]$Id, $Params)
    $data = Reveal-AppPxeBootMacOsSmbd
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootWimLibrary {
    param([int]$Id, $Params)
    $data = Get-AppPxeBootWimLibraryResponse
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ImportPxeBootWimBootAssets {
    param([int]$Id, $Params)
    $wimFileName = Get-AppSidecarParam -Params $Params -Name 'wimFileName'
    $sourceDirectory = Get-AppSidecarParam -Params $Params -Name 'sourceDirectory'
    if (-not $wimFileName) { throw 'ImportPxeBootWimBootAssets: wimFileName required.' }
    if (-not $sourceDirectory) { throw 'ImportPxeBootWimBootAssets: sourceDirectory required.' }
    $data = Import-AppPxeBootWimBootAssets `
        -WimFileName ([string]$wimFileName) `
        -SourceDirectory ([string]$sourceDirectory)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ExportPxeBootWimBootAssets {
    param([int]$Id, $Params)
    $wimFileName = Get-AppSidecarParam -Params $Params -Name 'wimFileName'
    if (-not $wimFileName) { throw 'ExportPxeBootWimBootAssets: wimFileName required.' }
    $data = Export-AppPxeBootWimBootAssets -WimFileName ([string]$wimFileName)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ImportPxeBootWim {
    param([int]$Id, $Params)
    $sourcePath = Get-AppSidecarParam -Params $Params -Name 'sourcePath'
    if (-not $sourcePath) { throw 'ImportPxeBootWim: sourcePath required.' }
    $targetFileName = Get-AppSidecarParam -Params $Params -Name 'targetFileName'
    $replaceExisting = Get-AppSidecarParam -Params $Params -Name 'replaceExisting'
    $data = Import-AppPxeBootWim `
        -SourcePath ([string]$sourcePath) `
        -TargetFileName $(if ($targetFileName) { [string]$targetFileName } else { $null }) `
        -ReplaceExisting:([bool]$replaceExisting)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-RemovePxeBootWim {
    param([int]$Id, $Params)
    $fileName = Get-AppSidecarParam -Params $Params -Name 'fileName'
    if (-not $fileName) { throw 'RemovePxeBootWim: fileName required.' }
    $data = Remove-AppPxeBootWim -FileName ([string]$fileName)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ListPxeBootIsoWims {
    param([int]$Id, $Params)
    $isoPath = Get-AppSidecarParam -Params $Params -Name 'isoPath'
    if (-not $isoPath) { throw 'ListPxeBootIsoWims: isoPath required.' }
    $data = Get-AppPxeBootIsoWimList -IsoPath ([string]$isoPath)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ImportPxeBootWimFromIso {
    param([int]$Id, $Params)
    $isoPath = Get-AppSidecarParam -Params $Params -Name 'isoPath'
    $wimPath = Get-AppSidecarParam -Params $Params -Name 'wimPath'
    if (-not $isoPath) { throw 'ImportPxeBootWimFromIso: isoPath required.' }
    if (-not $wimPath) { throw 'ImportPxeBootWimFromIso: wimPath required.' }
    $targetFileName = Get-AppSidecarParam -Params $Params -Name 'targetFileName'
    $replaceExisting = Get-AppSidecarParam -Params $Params -Name 'replaceExisting'
    $data = Import-AppPxeBootWimFromIso `
        -IsoPath ([string]$isoPath) `
        -WimPath ([string]$wimPath) `
        -TargetFileName $(if ($targetFileName) { [string]$targetFileName } else { $null }) `
        -ReplaceExisting:([bool]$replaceExisting)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ImportPxeBootIso {
    param([int]$Id, $Params)
    $sourcePath = Get-AppSidecarParam -Params $Params -Name 'sourcePath'
    if (-not $sourcePath) { throw 'ImportPxeBootIso: sourcePath required.' }
    $targetFileName = Get-AppSidecarParam -Params $Params -Name 'targetFileName'
    $replaceExisting = Get-AppSidecarParam -Params $Params -Name 'replaceExisting'
    $data = Import-AppPxeBootIso `
        -SourcePath ([string]$sourcePath) `
        -TargetFileName $(if ($targetFileName) { [string]$targetFileName } else { $null }) `
        -ReplaceExisting:([bool]$replaceExisting)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-RemovePxeBootIso {
    param([int]$Id, $Params)
    $fileName = Get-AppSidecarParam -Params $Params -Name 'fileName'
    if (-not $fileName) { throw 'RemovePxeBootIso: fileName required.' }
    $data = Remove-AppPxeBootIso -FileName ([string]$fileName)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-OpenPxeBootWimFolder {
    param([int]$Id, $Params)
    $data = Open-AppPxeBootWimFolder
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-OpenPxeBootIsoFolder {
    param([int]$Id, $Params)
    $data = Open-AppPxeBootIsoFolder
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-OpenPxeBootFieldIsoDriversFolder {
    param([int]$Id, $Params)
    $data = Open-AppPxeBootFieldIsoDriversFolder
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootFieldIsoStatus {
    param([int]$Id, $Params)
    $data = Get-AppPxeBootFieldIsoDownloadStatus
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-DownloadPxeBootFieldIso {
    param([int]$Id, $Params)
    $replaceExisting = Get-AppSidecarParam -Params $Params -Name 'replaceExisting'
    $data = Download-AppPxeBootFieldIsoWim -ReplaceExisting:([bool]$replaceExisting)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootOptionalAssets {
    param([int]$Id, $Params)
    $data = Get-AppPxeBootOptionalAssetsStatus
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-DownloadPxeBootOptionalAsset {
    param([int]$Id, $Params)
    $assetId = Get-AppSidecarParam -Params $Params -Name 'assetId'
    if (-not $assetId) { throw 'DownloadPxeBootOptionalAsset: assetId required.' }
    $replaceExisting = Get-AppSidecarParam -Params $Params -Name 'replaceExisting'
    $data = Download-AppPxeBootOptionalAsset -AssetId ([string]$assetId) -ReplaceExisting:([bool]$replaceExisting)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-EnsurePxeBootCaddy {
    param([int]$Id, $Params)
    if (-not (Test-AppPxeBootPluginEnabled)) {
        Write-SidecarResponse -Id $Id -Data @{ ok = $false; skipped = $true; reason = 'not-enabled' }
        return
    }
    $data = Ensure-AppPxeBootCaddy
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-EnsurePxeBootTftpd64 {
    param([int]$Id, $Params)
    if (-not (Test-AppPxeBootPluginEnabled)) {
        Write-SidecarResponse -Id $Id -Data @{ ok = $false; skipped = $true; reason = 'not-enabled' }
        return
    }
    $data = Ensure-AppPxeBootTftpd64
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-SetPxeBootDefaultWim {
    param([int]$Id, $Params)
    $clear = Get-AppSidecarParam -Params $Params -Name 'clear'
    $fileName = Get-AppSidecarParam -Params $Params -Name 'fileName'
    if ($clear) {
        $data = Set-AppPxeBootDefaultWim -Clear
    } elseif ($fileName) {
        $data = Set-AppPxeBootDefaultWim -FileName ([string]$fileName)
    } else {
        $data = Set-AppPxeBootDefaultWim -Clear
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-SetPxeBootDefaultIso {
    param([int]$Id, $Params)
    $clear = Get-AppSidecarParam -Params $Params -Name 'clear'
    $fileName = Get-AppSidecarParam -Params $Params -Name 'fileName'
    if ($clear) {
        $data = Set-AppPxeBootDefaultIso -Clear
    } elseif ($fileName) {
        $data = Set-AppPxeBootDefaultIso -FileName ([string]$fileName)
    } else {
        $data = Set-AppPxeBootDefaultIso -Clear
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetPxeBootTaskSequences {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    Write-SidecarResponse -Id $Id -Data (Get-AppPxeBootTaskSequencesPayload)
}

function Handle-SavePxeBootTaskSequences {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $sequences = Get-AppSidecarParam -Params $Params -Name 'sequences'
    # $null = param missing (malformed call - refuse, never wipe the store).
    # An empty ARRAY is a legitimate "delete them all" save (Craig, 2026-08-20).
    if ($null -eq $sequences) { throw 'SavePxeBootTaskSequences: sequences is required.' }
    $list = @()
    if ($sequences -is [System.Collections.IEnumerable] -and -not ($sequences -is [string])) {
        foreach ($s in $sequences) { if ($s) { $list += , $s } }
    }
    $defaultId = Get-AppSidecarParam -Params $Params -Name 'defaultSequenceId'
    $null = Save-AppPxeBootTaskSequences -Sequences $list -DefaultSequenceId ([string]$defaultId)
    Write-SidecarResponse -Id $Id -Data (Get-AppPxeBootTaskSequencesPayload)
}

function Handle-GetEvalIsoCatalog {
    param([int]$Id, $Params)
    $data = @{ entries = @(Get-AppEvalIsoCatalog) }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-StartEvalIsoDownload {
    param([int]$Id, $Params)
    $isoId = Get-AppSidecarParam -Params $Params -Name 'id'
    if ([string]::IsNullOrWhiteSpace([string]$isoId)) { throw 'StartEvalIsoDownload: id required.' }
    $data = Start-AppEvalIsoDownload -Id ([string]$isoId)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ClearPxeBootLogTail {
    param([int]$Id, $Params)
    $data = Clear-AppPxeBootLogTail
    Write-SidecarResponse -Id $Id -Data $data
}

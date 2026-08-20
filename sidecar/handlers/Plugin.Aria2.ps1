# Sidecar IPC handlers -- Plugin.Aria2
# Mechanically extracted from windeploykit-sidecar.ps1 (2026-08 handler split).
# Functions only -- no top-level code. Dispatch resolves Handle-$Cmd by name at call time.

function Handle-GetAria2PluginConfig {
    param([int]$Id, $Params)
    $downloadDir = Get-AppSidecarParam -Params $Params -Name 'downloadDir'
    if ($downloadDir) {
        Set-AppAria2RuntimeDownloadDir -DownloadDir ([string]$downloadDir)
    }
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    if (Get-Command Get-AppAria2PluginConfigPayloadExtended -ErrorAction SilentlyContinue) {
        $data = Get-AppAria2PluginConfigPayloadExtended
    } else {
        $data = Get-AppAria2PluginConfigPayload
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-SetAria2PluginConfig {
    param([int]$Id, $Params)
    $downloadDir = Get-AppSidecarParam -Params $Params -Name 'downloadDir'
    if ($downloadDir) {
        Set-AppAria2RuntimeDownloadDir -DownloadDir ([string]$downloadDir)
    }
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $routes = Get-AppSidecarParam -Params $Params -Name 'extensionRoutes'
    if (Get-Command Set-AppAria2PluginConfigExtended -ErrorAction SilentlyContinue) {
        $data = Set-AppAria2PluginConfigExtended -ExtensionRoutes $routes
    } else {
        $data = Set-AppAria2PluginConfig
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetAria2TrackerCatalog {
    param([int]$Id, $Params)
    if (-not (Get-Command Get-AppAria2TrackerCatalogPayload -ErrorAction SilentlyContinue)) {
        throw 'GetAria2TrackerCatalog: PXE integration not loaded.'
    }
    $data = Get-AppAria2TrackerCatalogPayload
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-RefreshVendorSccmCatalogs {
    param([int]$Id, $Params)
    # An absent param yields @($null) — filter to real names so the default list applies.
    $vendors = @(Get-AppSidecarParam -Params $Params -Name 'vendors' |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    # Background child pwsh (2026-08-20): the synchronous refresh blocked the whole
    # dispatch loop for minutes. Result arrives as the 'vendor-catalog-refresh' event.
    $data = if ($vendors.Count -gt 0) {
        Start-AppVendorSccmCatalogRefreshJob -Vendors ($vendors | ForEach-Object { [string]$_ })
    } else {
        Start-AppVendorSccmCatalogRefreshJob
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-SubmitAcerSccmCatalogHarvest {
    param([int]$Id, $Params)
    $urls = @(Get-AppSidecarParam -Params $Params -Name 'urls')
    if ($urls.Count -eq 0) { throw 'SubmitAcerSccmCatalogHarvest: urls is required.' }
    $harvestedFrom = Get-AppSidecarParam -Params $Params -Name 'harvestedFrom'
    $data = Set-AppAcerSccmCatalogFromHarvest -Urls ($urls | ForEach-Object { [string]$_ }) -HarvestedFrom ([string]$harvestedFrom)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-CancelAria2DirectDownload {
    param([int]$Id, $Params)
    $key = [string](Get-AppSidecarParam -Params $Params -Name 'key')
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'CancelAria2DirectDownload: key is required.' }
    $cancelled = Stop-AppAria2DirectDownload -Key $key
    Write-SidecarResponse -Id $Id -Data @{ cancelled = [bool]$cancelled; key = $key }
}

function Handle-EnsureAria2Binary {
    param([int]$Id, $Params)
    if (-not (Test-AppAria2PluginEnabled)) {
        Write-SidecarResponse -Id $Id -Data @{ skipped = $true; reason = 'not-enabled' }
        return
    }
    $data = Ensure-AppAria2Binary
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-StartAria2Daemon {
    param([int]$Id, $Params)
    $downloadDir = Get-AppSidecarParam -Params $Params -Name 'downloadDir'
    if ($downloadDir) {
        Set-AppAria2RuntimeDownloadDir -DownloadDir ([string]$downloadDir)
    }
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $data = Start-AppAria2Daemon
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-StopAria2Daemon {
    param([int]$Id, $Params)
    $data = Stop-AppAria2Daemon
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-GetAria2Downloads {
    param([int]$Id, $Params)
    $data = Get-AppAria2DownloadsPayload
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-AddAria2Download {
    param([int]$Id, $Params)
    $downloadDir = Get-AppSidecarParam -Params $Params -Name 'downloadDir'
    if ($downloadDir) {
        Set-AppAria2RuntimeDownloadDir -DownloadDir ([string]$downloadDir)
    }
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $kind = Get-AppSidecarParam -Params $Params -Name 'kind'
    $kindNorm = if ($kind) { ([string]$kind).Trim().ToLowerInvariant() } else { 'uri' }
    $assetKind = Get-AppSidecarParam -Params $Params -Name 'assetKind'
    $modelAlias = Get-AppSidecarParam -Params $Params -Name 'modelAlias'
    $vendor = Get-AppSidecarParam -Params $Params -Name 'vendor'
    $folder = Get-AppSidecarParam -Params $Params -Name 'folder'
    $fileNameHint = Get-AppSidecarParam -Params $Params -Name 'fileNameHint'
    $torrentId = Get-AppSidecarParam -Params $Params -Name 'torrentId'

    if ($torrentId -and (Get-Command Add-AppAria2BundledTorrentDownload -ErrorAction SilentlyContinue)) {
        $data = Add-AppAria2BundledTorrentDownload -TorrentId ([string]$torrentId)
        Write-SidecarResponse -Id $Id -Data $data
        return
    }

    if (Get-Command Add-AppAria2ManagedDownload -ErrorAction SilentlyContinue) {
        if ($kindNorm -eq 'torrent') {
            $b64 = Get-AppSidecarParam -Params $Params -Name 'torrentBase64'
            $data = Add-AppAria2ManagedDownload `
                -Kind 'torrent' `
                -TorrentBase64 ([string]$b64) `
                -AssetKind ([string]$assetKind) `
                -ModelAlias ([string]$modelAlias) `
                -Vendor ([string]$vendor) `
                -Folder ([string]$folder) `
                -FileNameHint ([string]$fileNameHint)
        } else {
            $urisRaw = Get-AppSidecarParam -Params $Params -Name 'uris'
            $uriList = @()
            if ($urisRaw -is [System.Collections.IEnumerable] -and -not ($urisRaw -is [string])) {
                foreach ($u in $urisRaw) { if ($u) { $uriList += [string]$u } }
            } elseif ($urisRaw) {
                $uriList += [string]$urisRaw
            }
            $progressKey = Get-AppSidecarParam -Params $Params -Name 'progressKey'
            $expectedHash = Get-AppSidecarParam -Params $Params -Name 'expectedHash'
            $expectedHashAlgorithm = Get-AppSidecarParam -Params $Params -Name 'expectedHashAlgorithm'
            $catalogRowId = Get-AppSidecarParam -Params $Params -Name 'catalogRowId'
            $data = Add-AppAria2ManagedDownload `
                -Kind 'uri' `
                -Uris $uriList `
                -AssetKind ([string]$assetKind) `
                -ModelAlias ([string]$modelAlias) `
                -Vendor ([string]$vendor) `
                -Folder ([string]$folder) `
                -FileNameHint ([string]$fileNameHint) `
                -ProgressKey ([string]$progressKey) `
                -ExpectedHash ([string]$expectedHash) `
                -ExpectedHashAlgorithm ([string]$expectedHashAlgorithm) `
                -CatalogRowId ([string]$catalogRowId)
        }
        Write-SidecarResponse -Id $Id -Data $data
        return
    }

    if ($kindNorm -eq 'torrent') {
        $b64 = Get-AppSidecarParam -Params $Params -Name 'torrentBase64'
        $data = Add-AppAria2TorrentDownload -TorrentBase64 ([string]$b64)
    } else {
        $urisRaw = Get-AppSidecarParam -Params $Params -Name 'uris'
        $uriList = @()
        if ($urisRaw -is [System.Collections.IEnumerable] -and -not ($urisRaw -is [string])) {
            foreach ($u in $urisRaw) { if ($u) { $uriList += [string]$u } }
        } elseif ($urisRaw) {
            $uriList += [string]$urisRaw
        }
        $data = Add-AppAria2UriDownload -Uris $uriList
    }
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-ControlAria2Download {
    param([int]$Id, $Params)
    $action = Get-AppSidecarParam -Params $Params -Name 'action'
    $gid = Get-AppSidecarParam -Params $Params -Name 'gid'
    if ([string]::IsNullOrWhiteSpace($action)) { throw 'ControlAria2Download: action is required.' }
    if ([string]::IsNullOrWhiteSpace($gid)) { throw 'ControlAria2Download: gid is required.' }
    $data = Invoke-AppAria2DownloadControl -Action ([string]$action) -Gid ([string]$gid)
    Write-SidecarResponse -Id $Id -Data $data
}

function Handle-OpenAria2DownloadFolder {
    param([int]$Id, $Params)
    Set-AppImageLibraryRuntimeRootFromParams -Params $Params
    $downloadDir = Get-AppSidecarParam -Params $Params -Name 'downloadDir'
    if ($downloadDir) {
        Set-AppAria2RuntimeDownloadDir -DownloadDir ([string]$downloadDir)
    }
    $data = Open-AppAria2DownloadFolder
    Write-SidecarResponse -Id $Id -Data $data
}

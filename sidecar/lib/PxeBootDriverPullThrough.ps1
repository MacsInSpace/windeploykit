# Driver pull-through + alias map (Craig, 2026-08-20).
#
# WinPE imaging clients already announce make/model/serial to the sidecar via the
# imaging-log ingest at Connect. Two features ride on that:
#
#   * Pull-through: the housekeeping tick spots an active imaging client whose model
#     resolves in a vendor catalog but has no pack in the driver store, and starts
#     the verified direct download. A ledger keeps one entry per make|model: a
#     failed fetch is retried on the NEXT device / imaging session of that model,
#     never in a loop on the one that saw it fail (Craig, 2026-08-22). The first
#     device deploys as today (the client's own vendor download
#     fallback where the vendor has one); every later device cache-hits the store.
#
#   * Alias map: Drivers/aliases.json maps model names / Lenovo machine types /
#     seed wmiPatterns to the pack folder actually on disk - the deploy client
#     consults it when its exact-name search misses (Dell packs live under systemId
#     folders that never equal Win32 Model; Lenovo under 4-char machine types).
#     Installed packs only, so the file stays small and every entry is actionable.

$script:AppPxeBootDriverRowsCache = $null
$script:AppPxeBootPullThroughLastSyncUtc = [DateTime]::MinValue
$script:AppPxeBootAliasMapSignature = $null

function Get-AppPxeBootCatalogDriverRowsCached {
    # Tracker driver rows from the CACHED vendor catalogs (no live fetch), memoised
    # for 10 minutes - the payload build walks all five catalogs.
    param([int]$MaxAgeMinutes = 10)
    $now = (Get-Date).ToUniversalTime()
    if ($script:AppPxeBootDriverRowsCache -and ($now - $script:AppPxeBootDriverRowsCache.at).TotalMinutes -lt $MaxAgeMinutes) {
        return @($script:AppPxeBootDriverRowsCache.rows)
    }
    if (-not (Get-Command Get-AppAria2TrackerCatalogPayload -ErrorAction SilentlyContinue)) { return @() }
    try {
        $payload = Get-AppAria2TrackerCatalogPayload
        $rows = @(Get-AppAria2JsonProp -Item $payload -Name 'drivers')
        $script:AppPxeBootDriverRowsCache = @{ at = $now; rows = $rows }
        return $rows
    } catch {
        Write-SidecarLogVerbose "PXE boot: catalog driver rows unavailable - $($_.Exception.Message)"
        return @()
    }
}

function Resolve-AppPxeBootCatalogVendorFromMake {
    # Raw WMI Manufacturer -> the catalog vendor bucket ('Dell Inc.' -> Dell).
    param([string]$Make)
    $m = [string]$Make
    if ($m -match '(?i)dell') { return 'Dell' }
    if ($m -match '(?i)lenovo') { return 'LENOVO' }
    if ($m -match '(?i)hp|hewlett') { return 'HP' }
    if ($m -match '(?i)acer') { return 'Acer' }
    if ($m -match '(?i)microsoft') { return 'Microsoft' }
    return $null
}

function Resolve-AppPxeBootDriverRowForDevice {
    # Match a device's WMI make/model to one catalog row (exact, case-insensitive,
    # against modelName + aliases; Lenovo also tries the 4-char machine type).
    param([string]$Make, [string]$Model)
    $vendor = Resolve-AppPxeBootCatalogVendorFromMake -Make $Make
    $model = ([string]$Model).Trim()
    if (-not $vendor -or [string]::IsNullOrWhiteSpace($model)) { return $null }
    $candidates = @($model)
    if ($vendor -eq 'LENOVO' -and $model.Length -ge 4) { $candidates += $model.Substring(0, 4) }
    foreach ($row in @(Get-AppPxeBootCatalogDriverRowsCached)) {
        if ([string](Get-AppAria2JsonProp -Item $row -Name 'vendor') -ne $vendor) { continue }
        $names = @()
        $mn = [string](Get-AppAria2JsonProp -Item $row -Name 'modelName')
        if ($mn) { $names += $mn }
        $names += @(Get-AppAria2JsonProp -Item $row -Name 'aliases' | ForEach-Object { [string]$_ } | Where-Object { $_ })
        foreach ($cand in $candidates) {
            foreach ($n in $names) {
                if ($n -ieq $cand) { return $row }
            }
        }
    }
    return $null
}

function Get-AppPxeBootPullThroughLedgerPath {
    Join-Path (Get-AppAria2StoreRoot) 'driver-pull-through.json'
}

function Get-AppPxeBootPullThroughLedger {
    # make|model -> hashtable entry. Tolerant of the pre-retry shape (no serial/session/attempts).
    param([string]$Path)
    $ledger = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $ledger }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($raw.PSObject.Properties)) {
            $entry = @{}
            $value = $p.Value
            if ($value -is [System.Collections.IDictionary]) {
                foreach ($k in @($value.Keys)) { $entry[[string]$k] = $value[$k] }
            } elseif ($null -ne $value) {
                foreach ($q in @($value.PSObject.Properties)) { $entry[[string]$q.Name] = $q.Value }
            }
            $ledger[[string]$p.Name] = $entry
        }
    } catch { $ledger = @{} }
    return $ledger
}

function Get-AppPxeBootPullThroughEntryValue {
    param([hashtable]$Entry, [string]$Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry.ContainsKey($Name)) { return $Entry[$Name] }
    return $null
}

function ConvertTo-AppPxeBootPullThroughUtc {
    # Ledger timestamps come back from ConvertFrom-Json as [DateTime] (PS 7 hydrates ISO
    # strings) or as text from older files; either way -> UTC, MinValue when unreadable.
    param($Raw)
    if ($Raw -is [DateTime]) { return ([DateTime]$Raw).ToUniversalTime() }
    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParse([string]$Raw, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)
    if (-not $ok) { return [DateTime]::MinValue }
    return $parsed
}

function Get-AppPxeBootPullThroughClientValue {
    # Imaging-client rows are ordered hashtables; older snapshots may lack newer fields.
    param($Client, [string]$Name)
    if ($null -eq $Client) { return $null }
    if ($Client -is [System.Collections.IDictionary]) {
        if ($Client.Contains($Name)) { return $Client[$Name] }
        return $null
    }
    $p = $Client.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Sync-AppPxeBootDriverPullThrough {
    <#
    .SYNOPSIS
        Housekeeping tick (30s throttle): for each imaging client active in the last
        10 minutes, fetch its catalog driver pack when the store lacks it. One ledger
        entry per make|model keeps this from ever looping on a single device:

          * download-started is reconciled on later ticks against the direct-download
            job and becomes 'downloaded' or 'download-failed: <why>' (a sidecar restart
            before the download finished counts as a failure);
          * a failed fetch is retried once per NEW device / imaging session of that
            model (Craig, 2026-08-22) - never again for the session that saw it fail;
          * already-present / downloaded entries fetch again if the pack leaves the disk
            (delete the folder to force a refresh);
          * no-catalog-match / no-download-source entries are re-evaluated after the
            catalog cache TTL (14 days) so a refreshed catalog gets its chance.

        A tech can always fetch by hand from the Drivers tab; the next device then
        records 'already-present'.
    #>
    $now = (Get-Date).ToUniversalTime()
    if (($now - $script:AppPxeBootPullThroughLastSyncUtc).TotalSeconds -lt 30) { return }
    $script:AppPxeBootPullThroughLastSyncUtc = $now
    if (-not (Get-Command Get-AppPxeBootImagingClients -ErrorAction SilentlyContinue)) { return }
    $clients = @(Get-AppPxeBootImagingClients | Where-Object {
            [int]$_.ageSeconds -le 600 -and $_.make -and $_.model
        })
    if ($clients.Count -eq 0) { return }

    $ledgerPath = Get-AppPxeBootPullThroughLedgerPath
    $ledger = Get-AppPxeBootPullThroughLedger -Path $ledgerPath
    $stamp = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $changed = $false

    foreach ($client in $clients) {
        $make = [string]$client.make
        $model = [string]$client.model
        $lkey = ("$make|$model").ToLowerInvariant()
        $clientSerial = [string](Get-AppPxeBootPullThroughClientValue -Client $client -Name 'serial')
        $clientSession = [string](Get-AppPxeBootPullThroughClientValue -Client $client -Name 'session')
        $entry = if ($ledger.ContainsKey($lkey)) { $ledger[$lkey] } else { $null }
        $result = [string](Get-AppPxeBootPullThroughEntryValue -Entry $entry -Name 'result')

        $row = Resolve-AppPxeBootDriverRowForDevice -Make $make -Model $model
        $vendor = $null
        $folder = $null
        $uri = $null
        $progressKey = $null
        $havePack = $false
        if ($row) {
            $vendor = [string](Get-AppAria2JsonProp -Item $row -Name 'vendor')
            $folder = [string](Get-AppAria2JsonProp -Item $row -Name 'folder')
            $uri = [string](Get-AppAria2JsonProp -Item $row -Name 'uri')
            $progressKey = "$vendor|$folder"
            $modelDir = Join-Path (Join-Path (Get-AppPxeBootFieldIsoDriversOsRoot) $vendor) $folder
            $havePack = (Test-Path -LiteralPath $modelDir) -and [bool](Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $modelDir)
        }

        # 1. Reconcile an attempt that was in flight: still running -> wait; otherwise
        #    settle the entry from the download outcome (or the pack on disk).
        if ($entry -and $result -eq 'download-started') {
            if ($progressKey -and (Test-AppAria2DirectDownloadActive -Key $progressKey)) { continue }
            $outcome = if ($progressKey) { Get-AppAria2DirectDownloadOutcome -Key $progressKey } else { $null }
            if ($outcome -and [string]$outcome.status -eq 'failed') {
                $result = "download-failed: $($outcome.error)"
            } elseif ($havePack) {
                $result = 'downloaded'
            } else {
                $result = 'download-failed: interrupted (the download did not finish - sidecar restarted?)'
            }
            $entry['result'] = $result
            $entry['settledAt'] = $stamp
            $changed = $true
            Write-SidecarLog "PXE boot: driver pull-through $result for $make $model"
        }

        # 2. Should this client (re)start an attempt?
        $attempt = $false
        $reason = ''
        if ($havePack) {
            # Nothing to fetch (a tech may have pulled it by hand): note it and move on.
            if (-not $entry) {
                $ledger[$lkey] = @{
                    at       = $stamp
                    make     = $make
                    model    = $model
                    serial   = $clientSerial
                    session  = $clientSession
                    attempts = 0
                    vendor   = $vendor
                    folder   = $folder
                    result   = 'already-present'
                }
                $changed = $true
                Write-SidecarLog "PXE boot: driver pull-through already-present for $make $model (announced by $clientSerial)"
            } elseif ($result -notin @('already-present', 'downloaded')) {
                $entry['result'] = 'already-present'
                $entry['settledAt'] = $stamp
                $changed = $true
            }
            continue
        } elseif (-not $entry) {
            $attempt = $true
            $reason = 'first sighting'
        } elseif ($result -like 'download-failed*') {
            $entrySerial = [string](Get-AppPxeBootPullThroughEntryValue -Entry $entry -Name 'serial')
            $entrySession = [string](Get-AppPxeBootPullThroughEntryValue -Entry $entry -Name 'session')
            $sameSession = ($clientSerial -eq $entrySerial) -and ($clientSession -eq $entrySession)
            if (-not $sameSession) {
                $attempt = $true
                $reason = "retry after earlier failure ($result)"
            }
        } elseif ($result -in @('already-present', 'downloaded')) {
            $attempt = $true
            $reason = 'pack no longer on disk'
        } elseif ($result -in @('no-catalog-match', 'no-download-source')) {
            $at = ConvertTo-AppPxeBootPullThroughUtc -Raw (Get-AppPxeBootPullThroughEntryValue -Entry $entry -Name 'at')
            if (($now - $at).TotalDays -ge 14) {
                $attempt = $true
                $reason = 'catalog re-check'
            }
        }
        if (-not $attempt) { continue }

        # 3. Attempt (or re-attempt) the fetch and record it.
        $attempts = 1 + [int](Get-AppPxeBootPullThroughEntryValue -Entry $entry -Name 'attempts')
        $new = @{
            at       = $stamp
            make     = $make
            model    = $model
            serial   = $clientSerial
            session  = $clientSession
            attempts = $attempts
        }
        if ($result -like 'download-failed*') { $new['lastFailure'] = $result }
        if (-not $row) {
            $new['result'] = 'no-catalog-match'
        } else {
            $new['vendor'] = $vendor
            $new['folder'] = $folder
            if ([string]::IsNullOrWhiteSpace($uri) -or -not [bool](Get-AppAria2JsonProp -Item $row -Name 'downloadable')) {
                $new['result'] = 'no-download-source'
            } else {
                try {
                    # Same key the Drivers tab uses, so the row lights up live there.
                    $null = Add-AppAria2DirectHttpDownload `
                        -Uris @($uri) `
                        -AssetKind 'driver' `
                        -ModelAlias $model `
                        -Vendor $vendor `
                        -Folder $folder `
                        -FileNameHint ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedArchive')) `
                        -ProgressKey $progressKey `
                        -ExpectedHash ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedHash')) `
                        -ExpectedHashAlgorithm ([string](Get-AppAria2JsonProp -Item $row -Name 'expectedHashAlgorithm'))
                    $new['result'] = 'download-started'
                } catch {
                    $new['result'] = "download-failed: $($_.Exception.Message)"
                }
            }
        }
        $ledger[$lkey] = $new
        $changed = $true
        $suffix = if ($attempts -gt 1) { ", attempt $attempts - $reason" } else { '' }
        Write-SidecarLog "PXE boot: driver pull-through $($new['result']) for $make $model (announced by $clientSerial$suffix)"
    }
    if ($changed) {
        ($ledger | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ledgerPath -Encoding UTF8
    }
}

function Write-AppPxeBootDriverAliasMap {
    <#
    .SYNOPSIS
        Publish Drivers/aliases.json for the deploy client: aliases (model
        names, Lenovo machine types, seed wmiPatterns - wildcards allowed) -> the
        vendor/folder of a pack ACTUALLY on disk. Regenerated only when the set of
        installed pack folders changes, so the store-sync poll stays cheap.
    #>
    $root = Get-AppPxeBootFieldIsoDriversOsRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return }
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($vendorDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($modelDir in @(Get-ChildItem -LiteralPath $vendorDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            if (Get-AppPxeBootFieldIsoDriverPackInFolder -FolderPath $modelDir.FullName) {
                [void]$installed.Add("$($vendorDir.Name)|$($modelDir.Name)")
            }
        }
    }
    $mapPath = Join-Path $root 'aliases.json'
    $sig = (@($installed) | Sort-Object) -join ';'
    if ($sig -eq $script:AppPxeBootAliasMapSignature -and (Test-Path -LiteralPath $mapPath)) { return }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Catalog rows give installed packs their model-name/machine-type aliases.
    foreach ($row in @(Get-AppPxeBootCatalogDriverRowsCached)) {
        $vendor = [string](Get-AppAria2JsonProp -Item $row -Name 'vendor')
        $folder = [string](Get-AppAria2JsonProp -Item $row -Name 'folder')
        if (-not $vendor -or -not $folder) { continue }
        if (-not $installed.Contains("$vendor|$folder")) { continue }
        if (-not $seen.Add("$vendor|$folder")) { continue }
        $aliases = [System.Collections.Generic.List[string]]::new()
        $mn = [string](Get-AppAria2JsonProp -Item $row -Name 'modelName')
        if ($mn) { [void]$aliases.Add($mn) }
        foreach ($a in @(Get-AppAria2JsonProp -Item $row -Name 'aliases' | ForEach-Object { [string]$_ } | Where-Object { $_ })) {
            if ($aliases -notcontains $a) { [void]$aliases.Add($a) }
        }
        if ($aliases.Count -eq 0) { continue }
        [void]$entries.Add(@{ vendor = $vendor; folder = $folder; aliases = @($aliases) })
    }
    # Seed wmiPatterns (wildcards) for the pre-seeded vendor tree.
    if (Get-Command Read-AppPxeBootFieldIsoDriversSeed -ErrorAction SilentlyContinue) {
        try {
            $seed = Read-AppPxeBootFieldIsoDriversSeed
            if ($seed -and $seed.vendors) {
                foreach ($vendorProp in $seed.vendors.PSObject.Properties) {
                    $vendorName = [string]$vendorProp.Name
                    foreach ($model in @($vendorProp.Value.models)) {
                        $folder = [string](Get-AppAria2JsonProp -Item $model -Name 'folder')
                        if (-not $folder) { continue }
                        if (-not $installed.Contains("$vendorName|$folder")) { continue }
                        if (-not $seen.Add("$vendorName|$folder")) { continue }
                        $patterns = @(Get-AppAria2JsonProp -Item $model -Name 'wmiPatterns' | ForEach-Object { [string]$_ } | Where-Object { $_ })
                        if ($patterns.Count -eq 0) { continue }
                        [void]$entries.Add(@{ vendor = $vendorName; folder = $folder; aliases = @($patterns) })
                    }
                }
            }
        } catch { }
    }

    $doc = [ordered]@{
        schema    = 1
        generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        entries   = @($entries)
    }
    ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $mapPath -Encoding UTF8 -Force
    $script:AppPxeBootAliasMapSignature = $sig
    Write-SidecarLog "PXE boot: driver alias map published ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }))"
}

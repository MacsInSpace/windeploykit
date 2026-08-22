# EvalIsoCatalog.ps1 - Microsoft Evaluation Center ISO discovery + fetch.
#
# Why this exists: the product needs a legal, no-account, zero-setup source of
# Windows media so a fresh install can be tested end to end. Evaluation Center
# ISOs are freely downloadable from Microsoft and time-limited (180 days for
# Server, 90 for client) - fine for lab, imaging tests and CI.
#
# Ported from Craig's GetWinISOs.ps1 with three changes:
#   1. Cross-platform: Start-BitsTransfer (Windows-only) -> the shared aria2 /
#      direct-HTTP rail, so this works on macOS.
#   2. Fixed the malformed `and (` filter clause (was a parse error).
#   3. No hardcoded E:\ISOs - lands in the image library `iso/` folder, which is
#      what Caddy and the SMB share already serve.
#
# Evaluation Center markup changes without notice: Get-AppEvalIsoDirectUrl is
# best-effort and returns $null rather than throwing when the scrape misses.

$script:AppEvalIsoCatalog = @(
    [ordered]@{ id = 'srv2025'; name = 'Windows Server 2025';    kind = 'server'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025' }
    [ordered]@{ id = 'srv2022'; name = 'Windows Server 2022';    kind = 'server'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022' }
    [ordered]@{ id = 'srv2019'; name = 'Windows Server 2019';    kind = 'server'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019' }
    [ordered]@{ id = 'srv2016'; name = 'Windows Server 2016';    kind = 'server'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2016' }
    [ordered]@{ id = 'win11';   name = 'Windows 11 Enterprise';  kind = 'client'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise' }
    [ordered]@{ id = 'win10';   name = 'Windows 10 Enterprise';  kind = 'client'; page = 'https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise' }
)

function Get-AppEvalIsoCatalog {
    <#
    .SYNOPSIS
        The static list of Evaluation Center editions the app can fetch.
        No network access - the download URL is resolved on demand.
    #>
    $libRoot = $null
    try { $libRoot = (Get-AppImageLibraryPaths).isoDir } catch { }
    foreach ($entry in $script:AppEvalIsoCatalog) {
        $fileName = "$($entry.id)_eval.iso"
        $localPath = if ($libRoot) { Join-Path $libRoot $fileName } else { $null }
        [ordered]@{
            id         = [string]$entry.id
            name       = [string]$entry.name
            kind       = [string]$entry.kind
            page       = [string]$entry.page
            fileName   = $fileName
            downloaded = [bool]($localPath -and (Test-Path -LiteralPath $localPath))
            sizeBytes  = if ($localPath -and (Test-Path -LiteralPath $localPath)) {
                (Get-Item -LiteralPath $localPath).Length
            } else { 0 }
        }
    }
}

function Get-AppEvalIsoDirectUrl {
    <#
    .SYNOPSIS
        Scrape an Evaluation Center page for the en-US x64 ISO fwlink.
    .NOTES
        Filters mirror the original script: English, not Azure, not 32-bit,
        not LTSC, not VHD, not ARM. Returns $null when nothing matches.
    #>
    param([Parameter(Mandatory)][string]$PageUrl)

    try {
        $resp = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Write-SidecarLog "Eval ISO: page fetch failed ($PageUrl) - $($_.Exception.Message)"
        return $null
    }

    $links = @($resp.Links | Where-Object {
        $_.href -like 'https://go.microsoft.com/fwlink*' -and
        $_.outerHTML -like '*ISO*' -and
        $_.outerHTML -notlike '*Azure*' -and
        $_.outerHTML -notlike '*32-bit*' -and
        $_.outerHTML -notlike '*LTSC*' -and
        $_.outerHTML -notlike '*VHD*' -and
        $_.outerHTML -notlike '*ARM*'
    })

    # Prefer an explicit English row when the page offers several languages.
    $english = @($links | Where-Object { $_.outerHTML -match '(?i)en-?us|English' })
    $chosen = if ($english.Count -gt 0) { $english[0] } elseif ($links.Count -gt 0) { $links[0] } else { $null }

    if (-not $chosen) {
        Write-SidecarLog "Eval ISO: no matching download link on $PageUrl (page markup may have changed)"
        return $null
    }
    return [string]$chosen.href
}

function Start-AppEvalIsoDownload {
    <#
    .SYNOPSIS
        Resolve and queue an Evaluation Center ISO into the image library.
        Uses the same download rail as driver packs, so it works on macOS and
        the finished file lands where Caddy/SMB already serve it.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $entry = @($script:AppEvalIsoCatalog | Where-Object { $_.id -eq $Id })[0]
    if (-not $entry) { throw "Eval ISO: unknown id '$Id'." }

    $url = Get-AppEvalIsoDirectUrl -PageUrl ([string]$entry.page)
    if (-not $url) {
        throw "Eval ISO: could not resolve a download URL for $($entry.name). Open $($entry.page) and download manually, or drop the ISO into the image library."
    }

    Write-SidecarLog "Eval ISO: $($entry.name) -> $url"
    return Add-AppAria2ManagedDownload `
        -Kind 'uri' `
        -Uris @($url) `
        -AssetKind 'iso' `
        -FileNameHint "$($entry.id)_eval.iso"
}

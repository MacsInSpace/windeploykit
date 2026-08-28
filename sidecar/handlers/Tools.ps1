# Tools - the product-wide tool inventory and the setup wizard's one "Download tools" action.
#
# Every external tool comes from its own upstream project (Caddy, tftpd64, aria2 on
# Windows, 7-Zip) or is built from upstream source and shipped inside the app
# (dnsmasq, wimlib-imagex, aria2c on macOS). Nothing is fetched from a product asset
# feed, and Homebrew is treated as not installed on every Mac (Craig, 2026-08-29:
# "Treat it as not installed ... grab executables from their projects and offer to
# install at setup"). Same shape as AdobeUpdateKit's GetTools / EnsureTools.
#
# Nothing here gates on a plug-in being enabled: the wizard runs before any plug-in is
# switched on, and a present tool is useful to every panel that needs it.

function Test-AppToolsIsWindows { return [bool]($IsWindows -or ($env:OS -eq 'Windows_NT')) }
function Test-AppToolsIsMacOS { return [bool]($IsMacOS -or ((Get-Variable -Name IsDarwin -Scope Global -ErrorAction SilentlyContinue) -and $IsDarwin)) }

function Get-AppToolsPlatformName {
    if (Test-AppToolsIsWindows) { return 'windows' }
    if (Test-AppToolsIsMacOS) { return 'macos' }
    return 'linux'
}

function New-AppToolRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Version,
        [Parameter(Mandatory)][string]$Source,
        [switch]$Optional,
        [switch]$Bundled,
        [switch]$Downloadable,
        [AllowNull()][string]$Note
    )
    $present = -not [string]::IsNullOrWhiteSpace($Path)
    return [ordered]@{
        id           = $Id
        label        = $Label
        present      = $present
        path         = if ($present) { $Path } else { $null }
        version      = if ([string]::IsNullOrWhiteSpace($Version)) { $null } else { $Version }
        source       = $Source
        optional     = [bool]$Optional
        bundled      = [bool]$Bundled
        downloadable = [bool]$Downloadable
        note         = if ([string]::IsNullOrWhiteSpace($Note)) { $null } else { $Note }
    }
}

function Get-AppToolPathQuiet {
    # A resolver that throws (store not initialised yet, no project root) reads as "missing".
    param([Parameter(Mandatory)][scriptblock]$Resolver)
    try {
        $v = & $Resolver
        if ($null -eq $v) { return $null }
        $s = [string]$v
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { return $null }
        return $s
    } catch {
        return $null
    }
}

function Get-AppToolsStatus {
    $isWin = Test-AppToolsIsWindows
    $isMac = Test-AppToolsIsMacOS
    $rows = [System.Collections.Generic.List[object]]::new()

    # Caddy - HTTP for boot files, ISO/WIM serving. Upstream release archives (GitHub).
    $caddyVersion = if (Get-Variable -Name AppPxeBootCaddyVersion -Scope Script -ErrorAction SilentlyContinue) { [string]$script:AppPxeBootCaddyVersion } else { $null }
    [void]$rows.Add((New-AppToolRow -Id 'caddy' -Label 'Caddy (HTTP server)' `
        -Path (Get-AppToolPathQuiet { Get-AppPxeBootCaddyPath }) -Version $caddyVersion `
        -Source 'github.com/caddyserver/caddy' -Downloadable))

    if ($isWin) {
        # Windows TFTP: tftpd64 (dnsmasq is not buildable for native Windows).
        $tftpVersion = if (Get-Variable -Name AppPxeBootTftpd64Version -Scope Script -ErrorAction SilentlyContinue) { [string]$script:AppPxeBootTftpd64Version } else { $null }
        [void]$rows.Add((New-AppToolRow -Id 'tftpd64' -Label 'Tftpd64 (TFTP server)' `
            -Path (Get-AppToolPathQuiet { Get-AppPxeBootTftpd64Path }) -Version $tftpVersion `
            -Source 'github.com/PJO2/tftpd64' -Downloadable))
    }
    if ($isMac) {
        # macOS TFTP/ProxyDHCP: dnsmasq built from upstream source, shipped in the app.
        [void]$rows.Add((New-AppToolRow -Id 'dnsmasq' -Label 'dnsmasq (TFTP / ProxyDHCP)' `
            -Path (Get-AppToolPathQuiet { Get-AppPxeBootBundledDnsmasqPath }) -Version $null `
            -Source 'thekelleys.org.uk/dnsmasq - built from source, bundled' -Bundled `
            -Note 'Ships inside the app; nothing to download.'))
    }

    # wimlib-imagex - boot-asset extraction. Bundled on both platforms.
    [void]$rows.Add((New-AppToolRow -Id 'wimlib' -Label 'wimlib-imagex (WIM tools)' `
        -Path (Get-AppToolPathQuiet { Get-AppPxeBootBundledWimlibImagexPath }) -Version $null `
        -Source 'wimlib.net - bundled' -Bundled -Note 'Ships inside the app; nothing to download.'))

    # aria2 - Downloads. Windows from the upstream release archives; macOS bundled
    # (aria2 publishes no macOS binary, so the app carries its own build from source).
    $aria2Version = if (Get-Variable -Name AppAria2PinnedVersion -Scope Script -ErrorAction SilentlyContinue) { [string]$script:AppAria2PinnedVersion } else { $null }
    if ($isMac) {
        [void]$rows.Add((New-AppToolRow -Id 'aria2' -Label 'aria2 (downloads)' `
            -Path (Get-AppToolPathQuiet { Get-AppAria2BundledBinaryPath }) -Version $aria2Version `
            -Source 'aria2/aria2 source - built by us, bundled' -Bundled `
            -Note 'Ships inside the app; nothing to download.'))
    } else {
        [void]$rows.Add((New-AppToolRow -Id 'aria2' -Label 'aria2 (downloads)' `
            -Path (Get-AppToolPathQuiet { Get-AppAria2BinaryPath }) -Version $aria2Version `
            -Source 'github.com/aria2/aria2 (arm64: minnyres/aria2-windows-arm64)' -Downloadable))
    }

    if ($isMac) {
        # 7-Zip - optional on macOS (ISOs are mounted, not extracted). Upstream 7zz.
        $sevenVersion = if (Get-Variable -Name AppPxeBootP7zipPinnedVersion -Scope Script -ErrorAction SilentlyContinue) { [string]$script:AppPxeBootP7zipPinnedVersion } else { $null }
        [void]$rows.Add((New-AppToolRow -Id 'sevenzip' -Label '7-Zip (7zz)' `
            -Path (Get-AppToolPathQuiet { Get-AppPxeBootHost7zPath }) -Version $sevenVersion `
            -Source '7-zip.org' -Optional -Downloadable `
            -Note 'Optional: speeds up driver-pack and cab work. ISOs are read by mounting them.'))
    }

    $missingRequired = @($rows | Where-Object { -not $_['present'] -and -not $_['optional'] }).Count
    return [ordered]@{
        platform        = (Get-AppToolsPlatformName)
        rows            = @($rows.ToArray())
        missingRequired = $missingRequired
    }
}

function Get-AppToolSelection {
    # Which downloadable rows to obtain. No 'tools' parameter = every downloadable row on
    # this platform, so the wizard's single button leaves nothing missing.
    param($Params)
    $status = Get-AppToolsStatus
    $downloadable = @($status['rows'] | Where-Object { $_['downloadable'] } | ForEach-Object { [string]$_['id'] })
    $raw = $null
    if ($null -ne $Params) {
        if ($Params -is [System.Collections.IDictionary]) { if ($Params.Contains('tools')) { $raw = $Params['tools'] } }
        elseif ($Params.PSObject.Properties['tools']) { $raw = $Params.tools }
    }
    if ($null -eq $raw) { return $downloadable }
    $list = if ($raw -is [string]) { @($raw -split '[,\s]+') } else { @($raw) }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $list) {
        $id = ([string]$item).Trim().ToLowerInvariant()
        if (-not $id) { continue }
        if ($id -notin $downloadable) { throw "EnsureTools: '$id' is not a downloadable tool on this platform ($($downloadable -join ', '))." }
        [void]$out.Add($id)
    }
    if ($out.Count -eq 0) { return $downloadable }
    return @($out.ToArray())
}

function Invoke-AppToolEnsure {
    # Runs one tool's Ensure- function and normalises the result to @{ ok; message }.
    param([Parameter(Mandatory)][string]$Id)
    $result = switch ($Id) {
        'caddy'    { Ensure-AppPxeBootCaddy }
        'tftpd64'  { Ensure-AppPxeBootTftpd64 }
        'aria2'    { Ensure-AppAria2Binary }
        'sevenzip' { Ensure-AppPxeBootP7zipTools -Download }
        default    { throw "EnsureTools: unknown tool '$Id'." }
    }
    $ok = $false
    $message = ''
    if ($result -is [System.Collections.IDictionary]) {
        $ok = ($result.Contains('ok') -and [bool]$result['ok'])
        if ($result.Contains('message') -and $result['message']) { $message = [string]$result['message'] }
        if ($result.Contains('reason') -and $result['reason'] -and -not $message) { $message = [string]$result['reason'] }
    } elseif ($null -ne $result) {
        $okProp = $result.PSObject.Properties['ok']
        $ok = ($okProp -and [bool]$okProp.Value)
        $msgProp = $result.PSObject.Properties['message']
        if ($msgProp -and $msgProp.Value) { $message = [string]$msgProp.Value }
    }
    return @{ ok = $ok; message = $message }
}

function Handle-GetTools {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Get-AppToolsStatus)
}

function Handle-EnsureTools {
    <#
        One call obtains every downloadable tool for this platform (or the 'tools' subset),
        each from its upstream project, and reports per-tool lines. One tool failing does
        not abandon the rest; the response carries every failure and the final inventory.
        Progress also goes out as 'tools-progress' events for a UI that wants to stream.
    #>
    param([int]$Id, $Params)
    $selected = Get-AppToolSelection -Params $Params
    $lines = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $say = {
        param([string]$Text)
        [void]$lines.Add($Text)
        Write-SidecarLog "Tools: $Text"
        try { Write-SidecarEvent -EventName 'tools-progress' -Data ([ordered]@{ line = $Text }) } catch { }
    }
    foreach ($tool in @($selected)) {
        & $say "$($tool): obtaining from its upstream project..."
        try {
            $r = Invoke-AppToolEnsure -Id $tool
            if ($r.ok) {
                & $say "$($tool): ready$(if ($r.message) { " ($($r.message))" })"
            } else {
                $msg = if ($r.message) { $r.message } else { 'not obtained' }
                [void]$failures.Add([ordered]@{ tool = $tool; message = $msg })
                & $say "$($tool): FAILED - $msg"
            }
        } catch {
            $msg = $_.Exception.Message
            [void]$failures.Add([ordered]@{ tool = $tool; message = $msg })
            & $say "$($tool): FAILED - $msg"
        }
    }
    $status = Get-AppToolsStatus
    Write-SidecarResponse -Id $Id -Data ([ordered]@{
        ok       = ($failures.Count -eq 0)
        lines    = @($lines.ToArray())
        failures = @($failures.ToArray())
        tools    = $status
    })
}

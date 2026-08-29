# Tools - the product-wide tool inventory, the setup wizard's one "Download tools" action,
# and the Tools panel's update check / update / roll back.
#
# The table, state and mechanics live in lib/ToolsRegistry.ps1. Every tool comes from its
# own upstream project or is built from upstream source and shipped inside the app; no
# package manager is ever probed (Craig, 2026-08-29). Nothing here gates on a plug-in
# being enabled: the wizard runs before any plug-in is switched on.

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
    # Runs one tool's Ensure- function (the pinned version) and normalises the result.
    param([Parameter(Mandatory)][string]$Id)
    $spec = Get-AppToolSpec -Id $Id
    if (-not $spec.Contains('ensure')) { throw "EnsureTools: $Id has no installer on this platform." }
    $result = & $spec['ensure']
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

function Get-AppToolIdParam {
    param($Params)
    $id = [string](Get-AppSidecarParam -Params $Params -Name 'id')
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Tools: id is required.' }
    return $id.Trim().ToLowerInvariant()
}

function New-AppToolsProgress {
    # Lines go back in the response and out as 'tools-progress' events for a streaming UI.
    param([Parameter(Mandatory)]$Lines)
    return {
        param([string]$Text)
        [void]$Lines.Add($Text)
        try { Write-SidecarEvent -EventName 'tools-progress' -Data ([ordered]@{ line = $Text }) } catch { }
    }.GetNewClosure()
}

function Handle-GetTools {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data (Get-AppToolsStatus)
}

function Handle-EnsureTools {
    <#
        One call obtains every downloadable tool for this platform (or the 'tools' subset),
        each at its pinned version from its upstream project. One tool failing does not
        abandon the rest; the response carries every failure and the final inventory.
    #>
    param([int]$Id, $Params)
    $selected = Get-AppToolSelection -Params $Params
    $lines = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $say = New-AppToolsProgress -Lines $lines
    foreach ($tool in @($selected)) {
        & $say "$($tool): obtaining from its upstream project..."
        Write-SidecarLog "Tools: ensure $tool"
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
    Write-SidecarResponse -Id $Id -Data ([ordered]@{
        ok       = ($failures.Count -eq 0)
        lines    = @($lines.ToArray())
        failures = @($failures.ToArray())
        tools    = (Get-AppToolsStatus)
    })
}

function Handle-CheckToolUpdates {
    <# Ask each GitHub-sourced tool's project for its latest release. Cached a day; force=true re-asks. #>
    param([int]$Id, $Params)
    $force = [bool](Get-AppSidecarParam -Params $Params -Name 'force')
    $check = Invoke-AppToolsUpdateCheck -Force:$force
    Write-SidecarResponse -Id $Id -Data ([ordered]@{
        checkedAt = (ConvertTo-AppToolIsoText -Value $check['checkedAt'])
        tools     = (Get-AppToolsStatus)
    })
}

function Handle-UpdateTool {
    <# Install the latest upstream release of ONE tool (never automatic). #>
    param([int]$Id, $Params)
    $toolId = Get-AppToolIdParam -Params $Params
    $lines = [System.Collections.Generic.List[string]]::new()
    $say = New-AppToolsProgress -Lines $lines
    $status = Install-AppToolUpdate -Id $toolId -Progress $say
    Write-SidecarResponse -Id $Id -Data ([ordered]@{ ok = $true; lines = @($lines.ToArray()); tools = $status })
}

function Handle-RollbackTool {
    <# Put the kept previous binary of ONE tool back. #>
    param([int]$Id, $Params)
    $toolId = Get-AppToolIdParam -Params $Params
    $lines = [System.Collections.Generic.List[string]]::new()
    $say = New-AppToolsProgress -Lines $lines
    $status = Restore-AppToolPrevious -Id $toolId -Progress $say
    Write-SidecarResponse -Id $Id -Data ([ordered]@{ ok = $true; lines = @($lines.ToArray()); tools = $status })
}

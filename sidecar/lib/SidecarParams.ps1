# JSON-safe reads for sidecar command params (PSCustomObject from ConvertFrom-Json).

function Get-AppSidecarParam {
    <#
    .SYNOPSIS
        Safe param read — JSON deserializes to PSCustomObject; strict mode throws on missing properties.
    #>
    param(
        $Params,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Params) { return $null }
    if ($Params -is [System.Collections.IDictionary]) {
        if (-not $Params.Contains($Name)) { return $null }
        return $Params[$Name]
    }
    $p = $Params.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-AppSidecarParamPresent {
    param(
        $Params,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Params) { return $false }
    if ($Params -is [System.Collections.IDictionary]) {
        return $Params.Contains($Name)
    }
    return $null -ne $Params.PSObject.Properties[$Name]
}

function Get-AppSidecarParamFirst {
    <#
    .SYNOPSIS
        Return the first present param from a list of names (JSON-safe).
    #>
    param(
        $Params,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        $v = Get-AppSidecarParam -Params $Params -Name $n
        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
            return $v
        }
    }
    return $null
}

function Read-AppSchoolGroupMembershipSidecarParams {
    <#
    .SYNOPSIS
        Parse AddUserToSchoolGroups / RemoveUserFromSchoolGroups sidecar params.
    #>
    param($Params)

    $loginRaw = Get-AppSidecarParam -Params $Params -Name 'login'
    $login = if ($null -ne $loginRaw) { [string]$loginRaw } else { $null }
    $memberDnRaw = Get-AppSidecarParamFirst -Params $Params -Names @('memberDn', 'memberDN', 'userDn', 'userDN')
    $memberDn = if ($null -ne $memberDnRaw) { [string]$memberDnRaw } else { $null }
    $presetRaw = Get-AppSidecarParam -Params $Params -Name 'preset'
    $preset = if ($null -ne $presetRaw) { [string]$presetRaw } else { $null }
    $suffixesRaw = Get-AppSidecarParam -Params $Params -Name 'suffixes'
    # [string[]](...) — not @(...) — so a single suffix/name does not collapse or unwrap wrong.
    $suffixes = if ($null -ne $suffixesRaw) { [string[]]($suffixesRaw) } else { $null }
    $groupNamesRaw = Get-AppSidecarParam -Params $Params -Name 'groupNames'
    $groupNames = if ($null -ne $groupNamesRaw) { [string[]]($groupNamesRaw) } else { $null }
    $groupDnRaw = Get-AppSidecarParamFirst -Params $Params -Names @('groupDn', 'groupDN')
    $groupDn = if ($null -ne $groupDnRaw) { [string]$groupDnRaw } else { $null }

    @{
        Login                 = $login
        MemberDn              = $memberDn
        Preset                = $preset
        Suffixes              = $suffixes
        GroupNames            = $groupNames
        GroupDn               = $groupDn
        DryRun                = [bool](Get-AppSidecarParam -Params $Params -Name 'dryRun')
        SkipMembershipCheck   = [bool](Get-AppSidecarParam -Params $Params -Name 'skipMembershipCheck')
    }
}

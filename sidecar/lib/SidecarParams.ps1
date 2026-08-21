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


# AppHttp.ps1 — minimal HTTP helpers for WinDeployKit.
#
# The USM original carried a corp/split-DNS routing table, per-host override cache
# and a TLS probe for department services; none of that applies to a generic
# product. Kept: the TLS policy switch and the Invoke-WebRequest wrapper the PXE
# and Downloads plug-ins actually call. Original preserved in usm-reference/.

$script:AppHttpSkipCertCheck = $false

function Test-AppHttpSkipCertificateCheckSupported {
    return (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
}

function Set-AppHttpTlsPolicy {
    <#
    .SYNOPSIS
        Allow self-signed / private-CA hosts (e.g. an on-prem artifact server).
    #>
    param([bool]$SkipCertificateCheck = $false)
    $script:AppHttpSkipCertCheck = [bool]$SkipCertificateCheck
}

function Clear-AppHttpTlsPolicy {
    $script:AppHttpSkipCertCheck = $false
}

function Format-AppExceptionChain {
    param($ErrorRecord)
    $parts = @()
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($ex) {
        $parts += $ex.Message
        $ex = $ex.InnerException
    }
    return ($parts -join ' -> ')
}

function Invoke-AppHttpWebRequest {
    param([Parameter(Mandatory)][hashtable]$RequestParams)

    $params = @{} + $RequestParams
    if ($script:AppHttpSkipCertCheck -and (Test-AppHttpSkipCertificateCheckSupported)) {
        $params['SkipCertificateCheck'] = $true
    }
    return Invoke-WebRequest @params
}

function Invoke-AppHttpRestMethod {
    param([Parameter(Mandatory)][hashtable]$RequestParams)

    $params = @{} + $RequestParams
    if ($script:AppHttpSkipCertCheck -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $params['SkipCertificateCheck'] = $true
    }
    return Invoke-RestMethod @params
}

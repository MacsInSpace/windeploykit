#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the Windows Server evaluation -> licensed edition conversion.
.DESCRIPTION
    The payload itself only runs on Windows, but the DECISION is a pure function and the
    keys are a table, so both are tested here. Every case below is a mistake the original
    hand-written script actually made.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'sidecar/lib/ServerEvalConversion.ps1')

$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  [OK  ] $Name" }
    catch { Write-Host "  [FAIL] $Name - $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:failures++ }
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

# Real DISM output shapes.
$evalStandard = @"
Deployment Image Servicing and Management tool
Version: 10.0.20348.681

Current Edition : ServerStandardEval

The operation completed successfully.
"@
$evalDatacenter = $evalStandard -replace 'ServerStandardEval', 'ServerDatacenterEval'
$licensed = $evalStandard -replace 'ServerStandardEval', 'ServerStandard'
$targetsStandard = @"
Editions that can be upgraded to:

Target Edition : ServerStandard
Target Edition : ServerDatacenter

The operation completed successfully.
"@

Write-Host 'Edition parsing:'
Test-Case 'Reads the edition out of DISM output' {
    Assert-True ((Get-AppServerEvalCurrentEdition -DismText $evalStandard) -eq 'ServerStandardEval') 'wrong edition parsed'
}
Test-Case 'Blank or junk text yields no edition, not an error' {
    Assert-True ((Get-AppServerEvalCurrentEdition -DismText '') -eq '') 'expected empty'
    Assert-True ((Get-AppServerEvalCurrentEdition -DismText 'nothing to see') -eq '') 'expected empty'
}

Write-Host ''
Write-Host 'Conversion decision:'
Test-Case 'Server 2022 Standard evaluation converts with the 2022 Standard GVLK' {
    $d = Resolve-AppServerEvalConversion -CurrentEditionText $evalStandard -Build '20348' -TargetEditionsText $targetsStandard
    Assert-True ($d.action -eq 'convert') "action was $($d.action) ($($d.reason))"
    Assert-True ($d.target -eq 'ServerStandard') "target was $($d.target)"
    Assert-True ($d.key -eq 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H') "key was $($d.key)"
}
Test-Case 'Datacenter evaluation gets the DATACENTER key, not the Standard one' {
    # The original script handed 2019 Datacenter the 2019 Standard key.
    $d = Resolve-AppServerEvalConversion -CurrentEditionText $evalDatacenter -Build '17763' -TargetEditionsText $targetsStandard
    Assert-True ($d.target -eq 'ServerDatacenter') "target was $($d.target)"
    Assert-True ($d.key -eq 'WMDGN-G9PQG-XVVXX-R3X43-63DFG') "key was $($d.key)"
    Assert-True ($d.key -ne 'N69G4-B89J2-4G8F4-WWYCC-J464C') 'used the Standard key for Datacenter'
}
Test-Case 'A licensed edition is left alone' {
    $d = Resolve-AppServerEvalConversion -CurrentEditionText $licensed -Build '20348' -TargetEditionsText $targetsStandard
    Assert-True ($d.action -eq 'skip') 'a non-evaluation edition should be skipped'
    Assert-True ($d.reason -match 'not an evaluation') "reason was '$($d.reason)'"
}
Test-Case 'An unknown build is skipped rather than guessed' {
    $d = Resolve-AppServerEvalConversion -CurrentEditionText $evalStandard -Build '99999' -TargetEditionsText $targetsStandard
    Assert-True ($d.action -eq 'skip') 'unknown build should be skipped'
    Assert-True ($d.reason -match 'no published GVLK') "reason was '$($d.reason)'"
}
Test-Case 'A target DISM does not offer is skipped' {
    $d = Resolve-AppServerEvalConversion -CurrentEditionText $evalDatacenter -Build '20348' -TargetEditionsText "Target Edition : ServerStandard"
    Assert-True ($d.action -eq 'skip') 'should not attempt an unoffered target'
    Assert-True ($d.reason -match 'does not offer') "reason was '$($d.reason)'"
}
Test-Case 'Unreadable DISM output is skipped' {
    $d = Resolve-AppServerEvalConversion -CurrentEditionText 'DISM failed' -Build '20348' -TargetEditionsText $targetsStandard
    Assert-True ($d.action -eq 'skip') 'should skip'
}

Write-Host ''
Write-Host 'Key table:'
Test-Case 'Every key is a well formed 5x5 product key' {
    $catalog = Get-AppServerEvalGvlkCatalog
    foreach ($build in $catalog.Keys) {
        foreach ($edition in $catalog[$build].Keys) {
            if ($edition -eq 'name') { continue }
            $key = [string]$catalog[$build][$edition]
            Assert-True ($key -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') "bad key for $build/$edition : $key"
        }
    }
}
Test-Case 'No key is reused across editions of the same build' {
    $catalog = Get-AppServerEvalGvlkCatalog
    foreach ($build in $catalog.Keys) {
        $keys = @()
        foreach ($edition in $catalog[$build].Keys) {
            if ($edition -eq 'name') { continue }
            $keys += [string]$catalog[$build][$edition]
        }
        Assert-True ((@($keys | Sort-Object -Unique)).Count -eq $keys.Count) "duplicate key within build $build"
    }
}
Test-Case 'The key the old script used for Server 2022 Standard is not in the table' {
    $catalog = Get-AppServerEvalGvlkCatalog
    $all = @()
    foreach ($build in $catalog.Keys) {
        foreach ($edition in $catalog[$build].Keys) {
            if ($edition -eq 'name') { continue }
            $all += [string]$catalog[$build][$edition]
        }
    }
    Assert-True ($all -notcontains '8B2CN-7C8FB-QWPCQ-42WKG-724QW') 'the unpublished 8B2CN key came back'
}

Write-Host ''
Write-Host 'Generated step:'
Test-Case 'The step is a pwshEncoded step that installs the payload' {
    $step = Get-AppServerEvalConversionStep
    Assert-True ($step.type -eq 'pwshEncoded') "type was $($step.type)"
    Assert-True ([string]$step.command -match 'SetupComplete\.cmd') 'installer does not hook SetupComplete.cmd'
    Assert-True ([string]$step.command -match 'Convert-EvalEdition\.ps1') 'installer does not write the payload'
}
Test-Case 'The payload carries the key table and no-ops off evaluation media' {
    $payload = Get-AppServerEvalConversionPayload
    Assert-True ($payload -match 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H') 'payload is missing the 2022 Standard key'
    Assert-True ($payload -match "notmatch '\(\?i\)Eval") 'payload does not guard on an evaluation edition'
    Assert-True ($payload -match 'Get-TargetEditions') 'payload does not check the offered targets'
    Assert-True ($payload -notmatch 'ServerDataCentre') 'payload uses the misspelled edition id'
}
Test-Case 'A KMS host is only wired in when one is supplied' {
    Assert-True ((Get-AppServerEvalConversionPayload) -notmatch '/skms') 'no KMS host should mean no /skms'
    Assert-True ((Get-AppServerEvalConversionPayload -KmsHost 'kms.example.internal') -match '/skms kms\.example\.internal') 'KMS host was not used'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "server eval conversion: $failures failure(s)"
    exit 1
}
Write-Host 'server eval conversion: all checks passed'
exit 0

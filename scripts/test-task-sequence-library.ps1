#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the task-sequence settings library.
.DESCRIPTION
    Every entry has to render to a command line that actually runs at first boot, so the
    whole catalog is walked through the real step renderer here. Also pins the rules that
    make the catalog trustworthy: documented sources, no invented keys, per-user settings
    written into the Default hive, and parameter values that cannot break out of the
    generated command line.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppState = @{ IsReady = $true }
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/AppProductIdentity.ps1')
. (Join-Path $SidecarRoot 'lib/ServerEvalConversion.ps1')
. (Join-Path $SidecarRoot 'lib/TaskSequenceStepLibrary.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootTaskSequences.ps1')

$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  [OK  ] $Name" }
    catch { Write-Host "  [FAIL] $Name - $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:failures++ }
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

$library = @(Get-AppTaskSequenceStepLibrary)

Write-Host "Catalog ($($library.Count) entries):"
Test-Case 'Every entry is complete and uniquely identified' {
    Assert-True ($library.Count -ge 20) "expected a useful catalog, got $($library.Count)"
    $ids = @($library | ForEach-Object { [string]$_.id })
    Assert-True ((@($ids | Sort-Object -Unique)).Count -eq $ids.Count) 'duplicate entry id'
    foreach ($entry in $library) {
        foreach ($field in @('id', 'name', 'category', 'applies', 'risk', 'description', 'source')) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry[$field])) "$($entry.id): $field is empty"
        }
        Assert-True ([string]$entry.applies -in @('client', 'server', 'both')) "$($entry.id): bad applies '$($entry.applies)'"
        Assert-True ([string]$entry.risk -in @('safe', 'caution')) "$($entry.id): bad risk '$($entry.risk)'"
    }
}
Test-Case 'Every entry cites documentation (no invented registry keys)' {
    foreach ($entry in $library) {
        Assert-True ([string]$entry.source -match '^https://(learn|docs)\.microsoft\.com/') "$($entry.id): source is not Microsoft documentation ($($entry.source))"
    }
}
Test-Case 'Every entry renders to a usable first-boot command line' {
    foreach ($entry in $library) {
        $step = Get-AppTaskSequenceStepFromLibrary -Id ([string]$entry.id)
        Assert-True ([string]$step.type -in @('reg', 'cmd', 'pwsh', 'pwshEncoded')) "$($entry.id): bad step type '$($step.type)'"
        $line = Get-AppPxeBootTsStepCommandLine -Step $step
        Assert-True (-not [string]::IsNullOrWhiteSpace($line)) "$($entry.id): rendered to nothing"
        Assert-True ($line -notmatch '\{\{VALUE\}\}') "$($entry.id): an unsubstituted {{VALUE}} reached the command line"
        Assert-True ($line -notmatch '\{\{[A-Za-z]+\}\}') "$($entry.id): an unsubstituted token reached the command line"
    }
}
Test-Case 'The whole catalog can be rendered into one valid unattend component' {
    $steps = @($library | ForEach-Object { Get-AppTaskSequenceStepFromLibrary -Id ([string]$_.id) })
    $xml = Get-AppPxeBootTsSpecializeRunSync -Steps $steps
    $null = [xml]("<root xmlns:wcm='urn:wcm'>" + $xml + "</root>")
    Assert-True ($xml -match 'RunSynchronousCommand') 'no commands were emitted'
}

Write-Host ''
Write-Host 'Per-user settings:'
Test-Case 'Explorer settings are written into the Default profile hive, not HKCU' {
    foreach ($id in @('explorer-show-extensions', 'explorer-show-hidden', 'explorer-this-pc')) {
        $step = Get-AppTaskSequenceStepFromLibrary -Id $id
        $line = Get-AppPxeBootTsStepCommandLine -Step $step
        Assert-True ($line -match 'reg load') "$id does not load the Default hive - it would apply to nobody"
        Assert-True ($line -match 'C:\\Users\\Default\\NTUSER\.DAT') "$id does not target the Default profile"
        Assert-True ($line -match 'reg unload') "$id leaves the Default hive loaded"
        Assert-True ($line -notmatch 'HKCU') "$id writes to HKCU, which lands in the SYSTEM profile during specialize"
    }
}

Write-Host ''
Write-Host 'Parameters:'
Test-Case 'A default is used when the technician supplies nothing' {
    $step = Get-AppTaskSequenceStepFromLibrary -Id 'telemetry-level'
    Assert-True ([string]$step.data -eq '1') "data was '$($step.data)'"
}
Test-Case 'A supplied value is substituted everywhere it appears' {
    $step = Get-AppTaskSequenceStepFromLibrary -Id 'wsus-server' -Value 'http://wsus.internal:8530'
    Assert-True ((([regex]::Matches([string]$step.command, [regex]::Escape('http://wsus.internal:8530'))).Count -eq 2)) 'the WSUS URL should appear for both WUServer and WUStatusServer'
    Assert-True ([string]$step.command -notmatch '\{\{VALUE\}\}') 'a token survived'
}
Test-Case 'The chosen value is shown in the step description' {
    $step = Get-AppTaskSequenceStepFromLibrary -Id 'timezone-set' -Value 'UTC'
    Assert-True ([string]$step.description -match 'UTC') "description was '$($step.description)'"
}
Test-Case 'An invalid choice is refused' {
    $threw = $false
    try { $null = Get-AppTaskSequenceStepFromLibrary -Id 'telemetry-level' -Value '9' } catch { $threw = $true }
    Assert-True $threw 'an out-of-range choice was accepted'
}
Test-Case 'A value that would break out of the command line is refused' {
    foreach ($bad in @('x" & calc.exe & "', 'a|b', 'a&b', 'a>b', 'a^b')) {
        $threw = $false
        try { $null = Get-AppTaskSequenceStepFromLibrary -Id 'timezone-set' -Value $bad } catch { $threw = $true }
        Assert-True $threw "injection value was accepted: $bad"
    }
}
Test-Case 'An unknown id throws rather than returning an empty step' {
    $threw = $false
    try { $null = Get-AppTaskSequenceStepFromLibrary -Id 'no-such-entry' } catch { $threw = $true }
    Assert-True $threw 'unknown id did not throw'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "task sequence library: $failures failure(s)"
    exit 1
}
Write-Host "task sequence library: all checks passed ($($library.Count) entries)"
exit 0

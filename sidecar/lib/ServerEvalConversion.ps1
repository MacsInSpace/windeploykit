# ServerEvalConversion.ps1 - turn a Windows Server EVALUATION install into a licensed
# edition at first boot, as a task-sequence step.
#
# Why: Evaluation Center media (the ISOs the Operating Systems panel downloads) install
# as ServerStandardEval / ServerDatacenterEval and expire in 180 days. Microsoft's
# documented conversion is DISM /Set-Edition with the matching GVLK.
#
# Craig's ServerBaseActivationandSettings.ps1 did this, and it is worth recording exactly
# why it could not have worked, because the same mistakes are easy to repeat:
#
#   If ($BuildNumber = 20348)            <- ASSIGNMENT, not -eq. Always true, and it
#                                           overwrites $BuildNumber. Every version block
#                                           ran in order on every machine.
#   If ($TargetEdition = "ServerStandard") <- same; Standard, Datacenter and Essentials
#                                           branches all ran.
#   Dism /Set-Edition:ServerDataCentre    <- not a real edition id (it is ServerDatacenter).
#   2019 Datacenter used N69G4-...        <- that is the 2019 STANDARD key.
#   slmgr /ipk WVDHN-...-YY726C           <- 26 characters; one too many.
#   $CurrentEdition -Like "ServerStandard" <- no wildcards, compared against a Caption
#                                           like "Microsoft Windows Server 2022 Standard",
#                                           so every fallback branch was dead.
#
# This version instead: asks DISM what edition is actually running, only acts when it
# ends in Eval, asks DISM which target editions are actually offered, and looks the GVLK
# up by (build, target edition) from the table below.
#
# GVLKs are Microsoft's published Generic Volume License Keys, from
# learn.microsoft.com/windows-server/get-started/kms-client-activation-keys (2026-08-22).
# They are public and only activate against a KMS host - they are not licences.
#
# NOTE ON TESTING: the payload runs on Windows and cannot be executed here. What IS
# covered by the offline gate is the decision (Resolve-AppServerEvalConversion): edition
# parsing, the Eval check, target mapping and key lookup, using captured DISM output.

$script:AppServerEvalGvlk = [ordered]@{
    '26100' = [ordered]@{
        name             = 'Windows Server 2025'
        ServerStandard   = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'
        ServerDatacenter = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
    }
    '20348' = [ordered]@{
        name             = 'Windows Server 2022'
        ServerStandard   = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'
        ServerDatacenter = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33'
    }
    '17763' = [ordered]@{
        name             = 'Windows Server 2019'
        ServerStandard   = 'N69G4-B89J2-4G8F4-WWYCC-J464C'
        ServerDatacenter = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
        ServerSolution   = 'WVDHN-86M7X-466P6-VHXV7-YY726'
    }
    '14393' = [ordered]@{
        name             = 'Windows Server 2016'
        ServerStandard   = 'WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'
        ServerDatacenter = 'CB7KF-BWN84-R7R2Y-793K2-8XDDG'
        ServerSolution   = 'JCKRF-N37P4-C2D82-9YXRT-4M63B'
    }
}

function Get-AppServerEvalGvlkCatalog {
    $script:AppServerEvalGvlk
}

function Get-AppServerEvalGvlk {
    <#
    .SYNOPSIS
        GVLK for a (build, edition) pair, or $null. Edition ids are DISM's:
        ServerStandard, ServerDatacenter, ServerSolution (Essentials).
    #>
    param([string]$Build, [string]$Edition)
    if ([string]::IsNullOrWhiteSpace($Build) -or [string]::IsNullOrWhiteSpace($Edition)) { return $null }
    $row = $script:AppServerEvalGvlk[[string]$Build]
    if (-not $row) { return $null }
    foreach ($name in $row.Keys) {
        if ($name -eq 'name') { continue }
        if ($name -ieq $Edition) { return [string]$row[$name] }
    }
    return $null
}

function Get-AppServerEvalCurrentEdition {
    <#
    .SYNOPSIS
        Pull the edition id out of `DISM /online /Get-CurrentEdition` output.
        Tolerates the localisation-ish spacing DISM uses and stray CRs.
    #>
    param([string]$DismText)
    if ([string]::IsNullOrWhiteSpace($DismText)) { return '' }
    if ($DismText -match '(?im)^\s*Current\s+Edition\s*:\s*(?<edition>[A-Za-z0-9_]+)\s*$') {
        return [string]$matches['edition']
    }
    return ''
}

function Resolve-AppServerEvalConversion {
    <#
    .SYNOPSIS
        The whole decision, as a pure function so it can be tested off-Windows.
    .OUTPUTS
        action  : 'convert' | 'skip'
        edition : what is running now
        target  : the licensed edition to move to
        key     : the GVLK to use
        reason  : why, for the on-device log
    #>
    param(
        [string]$CurrentEditionText,
        [string]$Build,
        [string]$TargetEditionsText
    )
    $out = [ordered]@{ action = 'skip'; edition = ''; target = ''; key = ''; reason = '' }
    $edition = Get-AppServerEvalCurrentEdition -DismText $CurrentEditionText
    $out.edition = $edition
    if (-not $edition) {
        $out.reason = 'could not read the current edition from DISM'
        return $out
    }
    if ($edition -notmatch '(?i)Eval$') {
        $out.reason = "$edition is not an evaluation edition - nothing to convert"
        return $out
    }
    $target = $edition -replace '(?i)Eval$', ''
    $out.target = $target
    $key = Get-AppServerEvalGvlk -Build $Build -Edition $target
    if (-not $key) {
        $out.reason = "no published GVLK for $target on build $Build"
        return $out
    }
    # DISM is the authority on what this image can actually become; if it does not list
    # the target, /Set-Edition would fail with a useless error.
    if (-not [string]::IsNullOrWhiteSpace($TargetEditionsText) -and
        $TargetEditionsText -notmatch [regex]::Escape($target)) {
        $out.reason = "DISM does not offer $target on this image"
        return $out
    }
    $out.action = 'convert'
    $out.key = $key
    $out.reason = "$edition -> $target"
    return $out
}

function Get-AppServerEvalConversionPayload {
    <#
    .SYNOPSIS
        The script that runs ON THE DEVICE, from SetupComplete.cmd.
    .NOTES
        SetupComplete.cmd (not the specialize pass) on purpose: /Set-Edition is a servicing
        operation that wants a full OS and a restart, and SetupComplete runs as SYSTEM after
        setup finishes but before anyone can log on. It never forces a reboot - the edition
        change lands on the next restart, which the join step causes anyway.
        The GVLK table is emitted from Get-AppServerEvalGvlkCatalog so there is one source.
    #>
    param([string]$KmsHost = '')
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($build in $script:AppServerEvalGvlk.Keys) {
        $row = $script:AppServerEvalGvlk[$build]
        foreach ($edition in $row.Keys) {
            if ($edition -eq 'name') { continue }
            [void]$lines.Add("    '$build|$edition' = '$($row[$edition])'")
        }
    }
    $table = ($lines -join "`r`n")
    $kmsBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($KmsHost)) {
        $kmsBlock = @"
    Write-ConversionLog "pointing activation at $KmsHost"
    & cscript.exe //nologo "`$env:SystemRoot\system32\slmgr.vbs" /skms $KmsHost | Out-Null
    & cscript.exe //nologo "`$env:SystemRoot\system32\slmgr.vbs" /ato | Out-Null
"@
    }
    @"
# Convert a Windows Server evaluation install to its licensed edition.
# Written by the imaging task sequence; runs once from SetupComplete.cmd.
`$ErrorActionPreference = 'Continue'
`$logPath = 'C:\Windows\Setup\Scripts\eval-conversion.log'
function Write-ConversionLog {
    param([string]`$Message)
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$Message" | Out-File -Append -FilePath `$logPath -Encoding utf8
}
`$gvlk = @{
$table
}
try {
    `$currentText = (& dism.exe /online /Get-CurrentEdition 2>&1) -join [Environment]::NewLine
    `$edition = ''
    if (`$currentText -match '(?im)^\s*Current\s+Edition\s*:\s*(?<e>[A-Za-z0-9_]+)\s*`$') { `$edition = `$matches['e'] }
    if (-not `$edition) { Write-ConversionLog 'could not read the current edition from DISM - nothing done'; exit 0 }
    if (`$edition -notmatch '(?i)Eval`$') { Write-ConversionLog "`$edition is not an evaluation edition - nothing to do"; exit 0 }
    `$target = `$edition -replace '(?i)Eval`$', ''
    `$build = [string](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    `$key = `$gvlk["`$build|`$target"]
    if (-not `$key) { Write-ConversionLog "no published GVLK for `$target on build `$build - leaving as evaluation"; exit 0 }
    `$targetsText = (& dism.exe /online /Get-TargetEditions 2>&1) -join [Environment]::NewLine
    if (`$targetsText -notmatch [regex]::Escape(`$target)) {
        Write-ConversionLog "DISM does not offer `$target on this image - leaving as evaluation"
        exit 0
    }
    Write-ConversionLog "converting `$edition -> `$target (build `$build)"
    `$output = (& dism.exe /online /Set-Edition:`$target /ProductKey:`$key /AcceptEula /NoRestart 2>&1) -join [Environment]::NewLine
    Write-ConversionLog "DISM exit code `$LASTEXITCODE"
    Write-ConversionLog `$output
    if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq 3010) {
        Write-ConversionLog 'conversion staged - it completes on the next restart'
$kmsBlock
    } else {
        Write-ConversionLog 'conversion failed - the machine stays on the evaluation edition'
    }
} catch {
    Write-ConversionLog "conversion error - `$(`$_.Exception.Message)"
}
exit 0
"@
}

function Get-AppServerEvalConversionInstaller {
    <#
    .SYNOPSIS
        The specialize-pass one-liner's script: drop the payload on disk and hook it into
        SetupComplete.cmd (appending, never clobbering an existing one).
    #>
    param([string]$KmsHost = '')
    $payload = Get-AppServerEvalConversionPayload -KmsHost $KmsHost
    @"
`$dir = 'C:\Windows\Setup\Scripts'
`$null = New-Item -ItemType Directory -Path `$dir -Force
`$payload = @'
$payload
'@
Set-Content -LiteralPath (Join-Path `$dir 'Convert-EvalEdition.ps1') -Value `$payload -Encoding UTF8
`$hook = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\Convert-EvalEdition.ps1"'
`$setupComplete = Join-Path `$dir 'SetupComplete.cmd'
if (Test-Path -LiteralPath `$setupComplete) {
    if (-not (Select-String -LiteralPath `$setupComplete -SimpleMatch 'Convert-EvalEdition.ps1' -Quiet)) {
        Add-Content -LiteralPath `$setupComplete -Value `$hook
    }
} else {
    Set-Content -LiteralPath `$setupComplete -Value @('@echo off', `$hook) -Encoding ASCII
}
"@
}

function Get-AppServerEvalConversionStep {
    <#
    .SYNOPSIS
        The task-sequence first-boot step. Safe on any machine: the payload no-ops unless
        the running edition actually ends in Eval.
    #>
    param([string]$KmsHost = '')
    [ordered]@{
        type        = 'pwshEncoded'
        description = 'Convert Windows Server evaluation to its licensed edition (no-op if not an evaluation)'
        command     = (Get-AppServerEvalConversionInstaller -KmsHost $KmsHost)
    }
}

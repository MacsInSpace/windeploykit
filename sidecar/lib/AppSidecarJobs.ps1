# Long work, off the dispatch thread.
#
# The sidecar is one process with a single-threaded dispatch loop: read a request, run
# the handler to completion, write the response, repeat. Anything slow holds everything
# behind it. "6 seconds on the Task Sequence tab" was a task-sequence request that took
# 90ms queued behind a service start that took 16.4s (log, 2026-08-24). Craig: "We need
# to get rid of this queued commands."
#
# This is the four bespoke background jobs already in the tree (vendor catalogs, eval
# ISO refresh, eval ISO downloads, direct downloads) generalised into one mechanism, so
# the next slow command costs a line in a list instead of 150 lines of its own.
#
# Shape: a named lib FUNCTION runs in a child pwsh; its return value comes back as JSON;
# a reaper on the housekeeping tick emits one event the panels all understand.
#
# A command may only be backgrounded when both of these hold:
#   - it needs nothing from the parent's in-memory state (the child re-reads from disk)
#   - it raises no GUI prompt (a child process cannot own the macOS admin dialog)
# Everything else stays inline. That rule is the whole contract.

$script:AppSidecarJobs = @{}

$script:AppSidecarJobRunner = @'
param(
    [Parameter(Mandatory)][string]$SidecarRoot,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$FunctionName,
    [string]$ArgumentsPath = ''
)
$ErrorActionPreference = 'Stop'
try {
    $projectRoot = Split-Path -Path $SidecarRoot -Parent
    # Whole lib tree: a job function is free to call anything the parent could, and
    # ~800ms of dot-sourcing is nothing against work measured in seconds.
    Get-ChildItem -LiteralPath (Join-Path $SidecarRoot 'lib') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    if (Get-Command Initialize-AppSharedSecretVault -ErrorAction SilentlyContinue) {
        [void](Initialize-AppSharedSecretVault -ProjectRoot $projectRoot)
    }
    $splat = @{}
    if ($ArgumentsPath -and (Test-Path -LiteralPath $ArgumentsPath)) {
        $raw = Get-Content -LiteralPath $ArgumentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $splat[$prop.Name] = $prop.Value }
    }
    $out = & $FunctionName @splat
    (@{ ok = $true; result = $out } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
'@

function Start-AppSidecarJob {
    <#
    .SYNOPSIS
        Run a lib function in a child pwsh and return immediately.
    .PARAMETER Name
        Stable job name - 'pxe-services', 'wim-import'. One job per name at a time; a
        second request while one is in flight is answered with alreadyRunning rather
        than starting a duplicate.
    .PARAMETER OnComplete
        Runs in the PARENT when the job finishes, before the event. For cache
        invalidation the child cannot do from its own process.
    .OUTPUTS
        @{ accepted; background; job; jobId; alreadyRunning }
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FunctionName,
        [hashtable]$Arguments,
        [int]$TimeoutMinutes = 10,
        [scriptblock]$OnComplete
    )
    if ($script:AppSidecarJobs.ContainsKey($Name)) {
        $running = $script:AppSidecarJobs[$Name]
        return @{ accepted = $true; background = $true; job = $Name; jobId = [string]$running.jobId; alreadyRunning = $true }
    }
    $jobId = [Guid]::NewGuid().ToString('N')
    $temp = [IO.Path]::GetTempPath()
    $slug = Get-AppProductSlug
    $runnerPath = Join-Path $temp "$slug-job-$jobId.ps1"
    $resultPath = Join-Path $temp "$slug-job-$jobId.json"
    $argsPath = ''
    Set-Content -LiteralPath $runnerPath -Value $script:AppSidecarJobRunner -Encoding UTF8
    if ($Arguments -and $Arguments.Count -gt 0) {
        $argsPath = Join-Path $temp "$slug-job-$jobId.args.json"
        ($Arguments | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $argsPath -Encoding UTF8
    }
    $pwsh = if ([string]::IsNullOrWhiteSpace([string][Environment]::ProcessPath)) { 'pwsh' } else { [string][Environment]::ProcessPath }
    $procArgs = @('-NoProfile', '-NonInteractive', '-File', $runnerPath,
        '-SidecarRoot', [string]$script:SidecarRoot, '-ResultPath', $resultPath, '-FunctionName', $FunctionName)
    if ($argsPath) { $procArgs += @('-ArgumentsPath', $argsPath) }
    $proc = Start-AppNativeProcess -FilePath $pwsh -Arguments $procArgs
    $script:AppSidecarJobs[$Name] = @{
        jobId      = $jobId
        name       = $Name
        process    = $proc
        resultPath = $resultPath
        runnerPath = $runnerPath
        argsPath   = $argsPath
        startedAt  = Get-Date
        timeoutMin = $TimeoutMinutes
        onComplete = $OnComplete
    }
    Write-SidecarLog "job '$Name': started in the background (child pwsh, $FunctionName)"
    Write-SidecarEvent -EventName 'job-started' -Data @{ job = $Name; jobId = $jobId }
    @{ accepted = $true; background = $true; job = $Name; jobId = $jobId; alreadyRunning = $false }
}

function Test-AppSidecarJobRunning {
    param([Parameter(Mandatory)][string]$Name)
    return $script:AppSidecarJobs.ContainsKey($Name)
}

function Get-AppSidecarJobNames {
    # For a status payload: what is in flight right now.
    @($script:AppSidecarJobs.Keys | Sort-Object)
}

function Sync-AppSidecarJobs {
    <#
    .SYNOPSIS
        Housekeeping tick: reap finished children, run their OnComplete, emit the event.
    .NOTES
        Iterates a copy of the key list - the reap mutates the table.
    #>
    if ($script:AppSidecarJobs.Count -eq 0) { return }
    foreach ($name in @($script:AppSidecarJobs.Keys)) {
        $job = $script:AppSidecarJobs[$name]
        if (-not $job) { continue }
        $proc = $job.process
        if ($proc -and -not $proc.HasExited) {
            # Watchdog: a wedged child must not hold the name latch forever.
            if (((Get-Date) - $job.startedAt).TotalMinutes -gt $job.timeoutMin) {
                Write-SidecarLog "job '$name': watchdog kill ($($job.timeoutMin) min)"
                try { $proc.Kill($true) } catch { }
            }
            continue
        }
        $script:AppSidecarJobs.Remove($name)
        $payload = $null
        try {
            if (Test-Path -LiteralPath $job.resultPath) {
                $payload = Get-Content -LiteralPath $job.resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
        } catch { $payload = $null }
        foreach ($p in @($job.resultPath, $job.runnerPath, $job.argsPath)) {
            if ($p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
        $ok = $false
        $err = $null
        $result = $null
        if ($null -eq $payload) {
            $err = 'the job process ended without a result (killed or crashed)'
        } else {
            try { $ok = [bool]$payload.ok } catch { $ok = $false }
            try { $err = [string]$payload.error } catch { $err = $null }
            try { $result = $payload.result } catch { $result = $null }
            if (-not $ok -and [string]::IsNullOrWhiteSpace($err)) { $err = 'the job failed without an error message' }
        }
        if ($job.onComplete) {
            try { & $job.onComplete $ok $result $err } catch {
                Write-SidecarLog "job '$name': completion handler failed - $($_.Exception.Message)"
            }
        }
        $elapsed = [int]((Get-Date) - $job.startedAt).TotalMilliseconds
        if ($ok) {
            Write-SidecarLog "job '$name': finished +${elapsed}ms"
        } else {
            Write-SidecarLog "job '$name': failed +${elapsed}ms - $err"
        }
        Write-SidecarEvent -EventName 'job-finished' -Data @{
            job     = $name
            jobId   = [string]$job.jobId
            ok      = $ok
            result  = $result
            error   = $err
            elapsed = $elapsed
        }
    }
}

function Stop-AppSidecarJobs {
    # Shutdown cleanup only - no events (the app is going away).
    foreach ($name in @($script:AppSidecarJobs.Keys)) {
        $job = $script:AppSidecarJobs[$name]
        $script:AppSidecarJobs.Remove($name)
        if (-not $job) { continue }
        try { if ($job.process -and -not $job.process.HasExited) { $job.process.Kill($true) } } catch { }
        foreach ($p in @($job.resultPath, $job.runnerPath, $job.argsPath)) {
            if ($p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
    }
}

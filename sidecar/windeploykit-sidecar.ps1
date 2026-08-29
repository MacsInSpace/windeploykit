<#
    WinDeployKit sidecar - long-lived PowerShell 7 service, NDJSON over stdio.

    Protocol (unchanged from the USM original this was ported from):
      stdin   one JSON object per line: {"id":N,"cmd":"Name","params":{...}}
      stdout  one JSON response per line - responses ONLY
      stderr  human-readable log lines

    There is no bootstrap gauntlet here: WinDeployKit has no directory session and
    no sign-in, so the service is ready the moment the dispatch loop starts.
    Commands resolve by convention - "Foo" runs Handle-Foo from handlers/.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:SidecarRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# Repo/bundle root - libs resolve vendored binaries and packaging manifests from
# here (vendor/binaries, packaging/*.json). Must be set before any lib loads.
$script:AppSidecarProjectRoot = Split-Path -Parent $script:SidecarRoot
$ProjectRoot = $script:AppSidecarProjectRoot

# Product identity - the one literal-bearing sidecar file. Must be set before ANY lib
# is dot-sourced (USM docs/handover/PRODUCT_IDENTITY_CONTRACT.md).
. (Join-Path $script:SidecarRoot 'product-identity.ps1')
$env:PSModulePath = "$($script:SidecarRoot)/modules" + [IO.Path]::PathSeparator + $env:PSModulePath

# --- Shared state -----------------------------------------------------------
# Set when THIS process starts a shared service, so shutdown only stops its own.
# StrictMode: these must exist before the finally block reads them.
$script:AppSidecarStartedPxeServices = $false
$script:AppSidecarStartedAria2 = $false

$script:AppState = @{
    IsReady       = $false
    Lifecycle     = 'booting'
    RuntimeConfig = @{}
    StartedAt     = (Get-Date).ToString('o')
}

# --- Library load -----------------------------------------------------------
# Ipc first (everything logs through it), then the rest alphabetically.
$libRoot = Join-Path $script:SidecarRoot 'lib'
. (Join-Path $libRoot 'AppProductIdentity.ps1')
. (Join-Path $libRoot 'Ipc.ps1')
. (Join-Path $libRoot 'SidecarParams.ps1')
. (Join-Path $libRoot 'AppPlatform.ps1')
. (Join-Path $libRoot 'AppPaths.ps1')
. (Join-Path $libRoot 'AppHttp.ps1')
. (Join-Path $libRoot 'AppElevation.ps1')
. (Join-Path $libRoot 'AppNativeProcess.ps1')
. (Join-Path $libRoot 'AppSidecarJobs.ps1')
. (Join-Path $libRoot 'AppPluginGates.ps1')
. (Join-Path $libRoot 'AppSharedSecretVault.ps1')
. (Join-Path $libRoot 'LocalMachineCredentials.ps1')
. (Join-Path $libRoot 'InfrastructureSshCredentials.ps1')
. (Join-Path $libRoot 'AcerSccmDriverCatalog.ps1')
. (Join-Path $libRoot 'DellSccmDriverCatalog.ps1')
. (Join-Path $libRoot 'HpSccmDriverCatalog.ps1')
. (Join-Path $libRoot 'LenovoSccmDriverCatalog.ps1')
. (Join-Path $libRoot 'MicrosoftSccmDriverCatalog.ps1')
. (Join-Path $libRoot 'VendorSccmCatalogRefresh.ps1')
. (Join-Path $libRoot 'PxeBootPlugin.ps1')
. (Join-Path $libRoot 'PxeBootInstallImages.ps1')
. (Join-Path $libRoot 'ServerEvalConversion.ps1')
. (Join-Path $libRoot 'TaskSequenceStepLibrary.ps1')
. (Join-Path $libRoot 'PxeBootTaskSequences.ps1')
. (Join-Path $libRoot 'PxeBootDriverPullThrough.ps1')
. (Join-Path $libRoot 'Aria2Plugin.ps1')
. (Join-Path $libRoot 'Aria2TrackerScrape.ps1')
. (Join-Path $libRoot 'Aria2PxeIntegration.ps1')
. (Join-Path $libRoot 'EvalIsoCatalog.ps1')
. (Join-Path $libRoot 'ToolsRegistry.ps1')

foreach ($handler in (Get-ChildItem -Path (Join-Path $script:SidecarRoot 'handlers') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $handler.FullName
}

# --- Core handlers ----------------------------------------------------------
function Handle-Ping {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data @{ pong = $true; at = (Get-Date).ToString('o') }
}

function Handle-GetSidecarStatus {
    param([int]$Id, $Params)
    Write-SidecarResponse -Id $Id -Data @{
        ready       = [bool]$script:AppState.IsReady
        lifecycle   = [string]$script:AppState.Lifecycle
        startedAt   = [string]$script:AppState.StartedAt
        pid         = $PID
        psVersion   = $PSVersionTable.PSVersion.ToString()
        platform    = if ($IsMacOS) { 'macos' } elseif ($IsWindows) { 'windows' } else { 'other' }
    }
}

function Handle-ApplyRuntimeConfig {
    param([int]$Id, $Params)
    $cfg = @{}
    foreach ($name in @('verboseLogging', 'verbosePowershell', 'skipHttpCertificateCheck')) {
        $cfg[$name] = [bool](Get-AppSidecarParam -Params $Params -Name $name)
    }
    $script:AppState['RuntimeConfig'] = $cfg
    if (Test-AppSidecarCommand Set-AppHttpTlsPolicy) {
        Set-AppHttpTlsPolicy -SkipCertificateCheck ([bool]$cfg['skipHttpCertificateCheck'])
    }
    Write-SidecarResponse -Id $Id -Data @{ applied = $true }
}

function Handle-PrepareAppExit {
    param([int]$Id, $Params)
    try { if (Test-AppSidecarCommand Stop-AppPxeBootServices) { Stop-AppPxeBootServices | Out-Null } } catch { }
    try { if (Test-AppSidecarCommand Stop-AppAria2Daemon) { Stop-AppAria2Daemon | Out-Null } } catch { }
    Write-SidecarResponse -Id $Id -Data @{ stopped = $true }
}

# --- Dispatch ---------------------------------------------------------------
function Invoke-SidecarCommand {
    param([int]$Id, [string]$Cmd, $Params)

    Write-SidecarIpcBegin -Cmd $Cmd -Id $Id
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = 'ok'
    try {
        $handler = "Handle-$Cmd"
        if (-not (Test-AppSidecarCommand $handler)) {
            Write-SidecarLog "IPC: unknown command $Cmd ($Id)"
            Write-SidecarError -Id $Id -Message "Unknown command: $Cmd" -Code 'UNKNOWN'
            return
        }
        try {
            & $handler -Id $Id -Params ($Params ?? @{})
        } catch {
            $outcome = 'error'
            Write-SidecarLog "IPC: $Cmd failed - $($_.Exception.Message)"
            Write-SidecarError -Id $Id -Message $_.Exception.Message -Code 'UNKNOWN'
        }
    } finally {
        $sw.Stop()
        Write-SidecarIpcComplete -Cmd $Cmd -Id $Id -ElapsedMs $sw.ElapsedMilliseconds -Outcome $outcome
    }
}

function Initialize-SidecarHostBridge {
    # Pure .NET stdin pump: the reader thread has no runspace, so it must not
    # call back into PowerShell - it only enqueues raw lines.
    if ('WinDeployKitSidecar.SidecarHost' -as [type]) { return }
    Add-Type @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;

namespace WinDeployKitSidecar {
    public static class SidecarHost {
        public static readonly ConcurrentQueue<string> RequestLines = new ConcurrentQueue<string>();
        public static int StdinComplete;

        public static void StartStdinPump() {
            var t = new Thread(StdinPumpWorker) { IsBackground = true, Name = "windeploykit-sidecar-stdin" };
            t.Start();
        }

        static void StdinPumpWorker() {
            try {
                using (var reader = new StreamReader(Console.OpenStandardInput())) {
                    string line;
                    while ((line = reader.ReadLine()) != null) { RequestLines.Enqueue(line); }
                }
            } catch { }
            finally { Interlocked.Exchange(ref StdinComplete, 1); }
        }
    }
}
'@ -ErrorAction Stop
}

function Invoke-SidecarDispatchOnce {
    try {
        # Background housekeeping the panels depend on for progress events.
        foreach ($job in @('Sync-AppAria2DirectDownloadJobs', 'Sync-AppVendorSccmCatalogRefreshJob', 'Start-AppVendorSccmCatalogAutoRefreshIfDue', 'Sync-AppPxeBootDriverPullThrough', 'Sync-AppEvalIsoCatalogRefreshJob', 'Start-AppEvalIsoCatalogRefreshIfDue', 'Sync-AppEvalIsoDownloadQueue', 'Sync-AppPxeBootInstallWimMounts', 'Sync-AppPxeBootDeployClientPublish', 'Sync-AppPxeBootIngestRoute', 'Sync-AppSidecarJobs')) {
            if (Test-AppSidecarCommand $job) {
                try { & $job | Out-Null } catch { }
            }
        }

        $line = $null
        if (-not [WinDeployKitSidecar.SidecarHost]::RequestLines.TryDequeue([ref]$line)) { return $false }
        if ([string]::IsNullOrWhiteSpace($line)) { return $true }

        $req = $null
        try {
            $req = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-SidecarLog "IPC: malformed request line - $($_.Exception.Message)"
            return $true
        }

        # StrictMode: ConvertFrom-Json omits absent keys entirely, so a bare $req.cmd
        # THROWS on a request that has no cmd. That threw past the IsNullOrWhiteSpace
        # check below into the outer catch, which logs but never answers - so the
        # client waited out its per-command timeout instead of getting an error.
        $id = 0
        try { $id = [int](Get-AppSidecarJsonProp -Item $req -Name 'id') } catch { $id = 0 }
        $cmd = [string](Get-AppSidecarJsonProp -Item $req -Name 'cmd')
        $prm = Get-AppSidecarJsonProp -Item $req -Name 'params'
        if ($null -eq $prm) { $prm = @{} }
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            Write-SidecarError -Id $id -Message 'Request had no cmd.' -Code 'UNKNOWN'
            return $true
        }
        Invoke-SidecarCommand -Id $id -Cmd $cmd -Params $prm
        return $true
    } catch {
        Write-SidecarLog "Dispatch error: $($_.Exception.Message)"
        return $true
    }
}

# --- Main -------------------------------------------------------------------
try {
    Initialize-SidecarHostBridge
    [WinDeployKitSidecar.SidecarHost]::StartStdinPump()

    # Shared secret vault: register once, by path, before we announce ready. This
    # cannot throw (Initialize- catches and records state), so a missing or
    # foreign-machine store degrades credential features rather than blocking boot.
    # Contract: one vault name 'shared', no reset, no prompt, no OS credential UI.
    [void](Initialize-AppSharedSecretVault -ProjectRoot $script:AppSidecarProjectRoot)

    $script:AppState.IsReady = $true
    $script:AppState.Lifecycle = 'ready'
    Write-SidecarLog "WinDeployKit sidecar ready (pwsh $($PSVersionTable.PSVersion), pid $PID)." -Flush
    Write-SidecarEvent -EventName 'ready' -Data @{ lifecycle = 'ready' }

    # Build the caches the first panel would otherwise wait for. Measured cold costs
    # (macOS, 2026-08-24): layout probe 2.2s, driver catalog 2.1s, PXE status 0.6s -
    # nearly 5s that used to land on whichever tab was clicked first. Ordered cheapest
    # first so an early click waits behind as little as possible.
    if (Get-Command Add-AppSidecarWarmupStep -ErrorAction SilentlyContinue) {
        Add-AppSidecarWarmupStep -Name 'pxe layout' -Action {
            if (Get-Command Test-AppPxeBootLayout -ErrorAction SilentlyContinue) { Test-AppPxeBootLayout }
        }
        Add-AppSidecarWarmupStep -Name 'pxe status' -Action {
            if (Get-Command Get-AppPxeBootStatus -ErrorAction SilentlyContinue) { Get-AppPxeBootStatus -SkipCatalogSync }
        }
        Add-AppSidecarWarmupStep -Name 'driver catalog' -Action {
            if (Get-Command Get-AppAria2TrackerCatalogPayload -ErrorAction SilentlyContinue) { Get-AppAria2TrackerCatalogPayload }
        }
    }

    while ($true) {
        $handled = Invoke-SidecarDispatchOnce
        if ([WinDeployKitSidecar.SidecarHost]::StdinComplete -ne 0 -and -not $handled) { break }
        if (-not $handled) {
            # Idle: spend it on the warm-up queue rather than sleeping through it.
            if (-not (Invoke-AppSidecarWarmupStep)) { [System.Threading.Thread]::Sleep(40) }
        }
    }
} catch {
    Write-SidecarLog "Sidecar fatal: $($_.Exception.Message)"
    try { Write-SidecarEvent -EventName 'error' -Data @{ message = $_.Exception.Message; phase = 'fatal' } } catch { }
} finally {
    # Only tear down what THIS process started. dnsmasq and Caddy are found by port,
    # not by parent, so a second sidecar - a test harness, a second window - used to
    # stop the running app's imaging services on its way out (caught 2026-08-24 doing
    # exactly that to a live PXE server).
    try { if (Get-Command Stop-AppSidecarJobs -ErrorAction SilentlyContinue) { Stop-AppSidecarJobs } } catch { }
    if ($script:AppSidecarStartedPxeServices) {
        try { if (Get-Command Stop-AppPxeBootServices -ErrorAction SilentlyContinue) { Stop-AppPxeBootServices | Out-Null } } catch { }
    }
    if ($script:AppSidecarStartedAria2) {
        try { if (Get-Command Stop-AppAria2Daemon -ErrorAction SilentlyContinue) { Stop-AppAria2Daemon | Out-Null } } catch { }
    }
    Write-SidecarLog 'WinDeployKit sidecar stopped.'
}

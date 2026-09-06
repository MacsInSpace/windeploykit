#requires -Version 7.0
<#
    .SYNOPSIS
    Install feedback for Linux task sequences: the reporter and the GET ingest.

    .DESCRIPTION
    A Debian or Ubuntu install reports to the same imaging-log endpoint the WinPE deploy
    client uses, so the panel shows it as one more imaging client. Two halves, both
    exercised for real here:

      1. The ingest listener (a loopback TcpListener behind Caddy) takes a GET with
         ?serial=&make=&model=&session=&line= or &heartbeat=1 - the installer's busybox
         wget cannot POST - and stores it exactly as a POST would. POST still works.
      2. sidecar/pxe/linux/wdk-report.sh, run under /bin/sh with its test hooks pointed
         at fixtures and at the live listener: start (identity off the kernel line, the
         env file, the first report), run (steps, a failure, a progress line from a
         d-i-shaped syslog), late (deploy.conf and the copy into /target), done, and
         firstboot (runs the script, reports its exit code and tail, exits with it).

    Plus the publisher that puts the script under http/linux/, and the preseed and
    autoinstall builders' early command that fetches it (covered in the debian and
    ubuntu gates; the menu gate covers the iPXE boot ping).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppSidecarProjectRoot = $RepoRoot
$script:AppState = @{ IsReady = $true }
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
foreach ($lib in @('AppProductIdentity', 'Ipc', 'SidecarParams', 'AppPlatform', 'AppPaths', 'AppHttp', 'AppElevation', 'AppNativeProcess', 'AppSidecarJobs', 'AppPluginGates', 'PxeBootPlugin')) {
    . (Join-Path $SidecarRoot "lib/$lib.ps1")
}

$script:fail = 0
function Check($label, [scriptblock]$test) {
    $ok = $false
    $msg = ''
    try { $ok = [bool](& $test) } catch { $ok = $false; $msg = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK  ] $label" }
    else {
        $script:fail++
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($msg) { Write-Host "         $msg" -ForegroundColor DarkRed }
    }
}

# A throwaway store: the listener writes imaging-logs/ under it.
$work = Join-Path ([IO.Path]::GetTempPath()) ("wdk-report-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -Path $work -ItemType Directory -Force
$script:storeRoot = Join-Path $work 'store'
$null = New-Item -Path $script:storeRoot -ItemType Directory -Force
function Get-AppPxeBootStoreRoot { $script:storeRoot }
$logDir = Join-Path $script:storeRoot 'imaging-logs'

function Read-Status([string]$serial) {
    $p = Join-Path $logDir "$serial.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
}
function Read-Log([string]$serial) {
    # The unary comma keeps an empty array an array on the way out (PowerShell unrolls).
    $p = Join-Path $logDir "$serial.log"
    if (-not (Test-Path -LiteralPath $p)) { return , @() }
    return , @(Get-Content -LiteralPath $p)
}
function Read-StatusRaw([string]$serial) {
    $p = Join-Path $logDir "$serial.json"
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    Get-Content -LiteralPath $p -Raw
}
function Assert-All([hashtable]$facts) {
    # Every value must be true; the names of the false ones become the failure message.
    $bad = @($facts.Keys | Where-Object { -not [bool]$facts[$_] } | Sort-Object)
    if ($bad.Count) { throw ("not true: " + ($bad -join ', ')) }
    $true
}
function Invoke-Get([string]$pathAndQuery) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port$pathAndQuery" -Method Get -TimeoutSec 5 -SkipHttpErrorCheck
        return @{ status = [int]$r.StatusCode; body = [string]$r.Content }
    } catch {
        return @{ status = -1; body = $_.Exception.Message }
    }
}

Write-Host 'The ingest listener:'
$port = Start-AppPxeBootImagingLogIngest
Check 'starts on a loopback port' { $port -gt 0 }
Check 'a GET with serial, make, model, session and line is stored like a POST and answered 200 ok (iPXE needs a body)' {
    $r = Invoke-Get '/imaging-log/ingest?serial=ABC%20123&make=LENOVO&model=ThinkPad%2011e%205th%20Gen&session=s1&line=10%3A00%3A00%20%20Hello%20there'
    $st = Read-Status 'ABC-123'
    ($r.status -eq 200) -and ($r.body.Trim() -eq 'ok') -and $st -and ($st.serial -eq 'ABC 123') -and ($st.make -eq 'LENOVO') -and ($st.model -eq 'ThinkPad 11e 5th Gen') -and ($st.session -eq 's1') -and ($st.lastLine -eq '10:00:00  Hello there') -and ((Read-Log 'ABC-123') -contains '10:00:00  Hello there')
}
Check 'a heartbeat GET keeps the row alive and the last line' {
    $before = Read-StatusRaw 'ABC-123'
    Start-Sleep -Milliseconds 50
    $r = Invoke-Get '/imaging-log/ingest?serial=ABC%20123&heartbeat=1'
    $st = Read-Status 'ABC-123'
    Assert-All @{ status200 = ($r.status -eq 200); lastLineKept = ($st.lastLine -eq '10:00:00  Hello there'); lastSeenMoved = ((Read-StatusRaw 'ABC-123') -ne $before); noNewLogLine = ((Read-Log 'ABC-123').Count -eq 1) }
}
Check 'a plus in a GET is a space, and a line with no serial lands under UNKNOWN' {
    $r = Invoke-Get '/imaging-log/ingest?line=a+b'
    ($r.status -eq 200) -and ((Read-Status 'UNKNOWN').lastLine -eq 'a b')
}
Check 'a GET with neither a line nor a heartbeat is a 400' {
    (Invoke-Get '/imaging-log/ingest?serial=X').status -eq 400
}
Check 'a GET anywhere else is a 404' {
    (Invoke-Get '/imaging-log/other?serial=X&line=y').status -eq 404
}
Check 'the JSON POST the WinPE client sends still works and is answered 204' {
    $body = '{"serial":"POST1","make":"QEMU","model":"pc","session":"p1","lines":["09:00:00  from WinPE"]}'
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/imaging-log/ingest" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 -SkipHttpErrorCheck
    ([int]$r.StatusCode -eq 204) -and ((Read-Status 'POST1').lastLine -eq '09:00:00  from WinPE')
}
Check 'the panel row lists the Linux client with its make, model and last line' {
    $rows = @(Get-AppPxeBootImagingClients)
    $row = @($rows | Where-Object { [string]$_.serial -eq 'ABC 123' })
    if ($row.Count -ne 1) { throw "expected one row for ABC 123, got $($row.Count) of $($rows.Count): $(($rows | ForEach-Object { [string]$_.serial }) -join ', ')" }
    $row = $row[0]
    Assert-All @{ make = ($row.make -eq 'LENOVO'); model = ($row.model -eq 'ThinkPad 11e 5th Gen'); lastLine = ($row.lastLine -eq '10:00:00  Hello there'); active = [bool]$row.active }
}

Write-Host 'The reporter script (sidecar/pxe/linux/wdk-report.sh):'
$reporter = Join-Path $SidecarRoot 'pxe/linux/wdk-report.sh'
$base = "http://127.0.0.1:$port"
$fix = Join-Path $work 'fix'
$null = New-Item -Path $fix -ItemType Directory -Force
$cmdline = Join-Path $fix 'cmdline'
[System.IO.File]::WriteAllText($cmdline, "BOOT_IMAGE=/linux initrd=initrd.gz vga=788 auto=true priority=critical preseed/url=$base/TaskSequences/campuscast-client.cfg wdk_serial=PF2ABC1D wdk_make=LENOVO wdk_model=20LRS0DP00 --- quiet`n")
$syslog = Join-Path $fix 'syslog'
[System.IO.File]::WriteAllText($syslog, @"
Sep  6 10:52:18 main-menu[321]: INFO: Menu item 'brltty-udeb' selected
Sep  6 10:52:19 main-menu[321]: INFO: Menu item 'espeakup-udeb' selected
Sep  6 10:52:20 main-menu[321]: INFO: Menu item 'netcfg' selected
Sep  6 10:52:28 main-menu[321]: INFO: Menu item 'network-preseed' selected
Sep  6 10:52:40 main-menu[321]: INFO: Menu item 'partman-base' selected
Sep  6 10:53:01 main-menu[321]: INFO: Menu item 'bootstrap-base' selected
Sep  6 10:53:05 debootstrap: I: Retrieving libc6 2.41-12
Sep  6 10:53:09 debootstrap: I: Unpacking libc6:amd64...
Sep  6 10:53:10 main-menu[321]: WARNING **: Configuring 'somepkg' failed with error code 1
Sep  6 10:53:11 debootstrap: I: Configuring libc6:amd64...
"@)
$envFile = Join-Path $fix 'wdk-env'
$target = Join-Path $fix 'target'
function Invoke-Reporter([string]$mode, [string]$extra = '', [hashtable]$vars = @{}) {
    $prev = @{}
    foreach ($k in @('WDK_CMDLINE', 'WDK_ENV', 'WDK_LOG', 'WDK_TARGET', 'WDK_ONCE', 'WDK_INTERVAL', 'WDK_RUN', 'WDK_FETCH')) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
    # curl: a Homebrew wget on the dev Mac can carry local config that keeps it off loopback.
    [Environment]::SetEnvironmentVariable('WDK_FETCH', 'curl')
    [Environment]::SetEnvironmentVariable('WDK_CMDLINE', $cmdline)
    [Environment]::SetEnvironmentVariable('WDK_ENV', $envFile)
    [Environment]::SetEnvironmentVariable('WDK_LOG', $syslog)
    [Environment]::SetEnvironmentVariable('WDK_TARGET', $target)
    [Environment]::SetEnvironmentVariable('WDK_ONCE', '1')
    [Environment]::SetEnvironmentVariable('WDK_INTERVAL', '1')
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
    try {
        $out = & sh $reporter $mode $extra 2>&1
        return @{ rc = $LASTEXITCODE; out = @($out | ForEach-Object { [string]$_ }) }
    } finally {
        foreach ($k in $prev.Keys) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
    }
}
Check 'the script is POSIX sh (sh -n), LF-only ASCII, and dash parses it too' {
    & sh -n $reporter 2>&1 | Out-Null
    $shOk = ($LASTEXITCODE -eq 0)
    $dashOk = $true
    if (Get-Command dash -ErrorAction SilentlyContinue) { & dash -n $reporter 2>&1 | Out-Null; $dashOk = ($LASTEXITCODE -eq 0) }
    $bytes = [System.IO.File]::ReadAllBytes($reporter)
    $shOk -and $dashOk -and -not ($bytes -contains 13) -and -not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)
}
Check 'start: reads the server and identity off the kernel line, saves the env file, reports the sequence, and returns' {
    $r = Invoke-Reporter 'start'
    Start-Sleep -Seconds 2   # the forked "run" does one cycle (WDK_ONCE) and exits
    $env = if (Test-Path -LiteralPath $envFile) { Get-Content -LiteralPath $envFile -Raw } else { '' }
    $st = Read-Status 'PF2ABC1D'
    ($r.rc -eq 0) -and ($env -match "WDK_BASE_URL='$([regex]::Escape($base))'") -and ($env -match "WDK_SERIAL='PF2ABC1D'") -and ($env -match "WDK_SEQUENCE='campuscast-client'") -and
    $st -and ($st.make -eq 'LENOVO') -and ($st.model -eq '20LRS0DP00') -and ((Read-Log 'PF2ABC1D') -match 'Installer running: task sequence campuscast-client').Count -eq 1
}
Check 'run: every d-i step is reported in words, the failure is reported, and the latest progress line once' {
    $lines = Read-Log 'PF2ABC1D'
    (($lines -match '  Configuring the network$').Count -eq 1) -and (($lines -match '  Fetching the task sequence$').Count -eq 1) -and
    (($lines -match '  Partitioning the disk$').Count -eq 1) -and (($lines -match '  Installing the base system$').Count -eq 1) -and
    (($lines -match '  Installer: main-menu_321_: WARNING __: Configuring _somepkg_ failed with error code 1$').Count -eq 1) -and
    (($lines -match '  debootstrap: I: Configuring libc6:amd64\.\.\.$').Count -eq 1) -and
    (($lines -match 'Retrieving libc6').Count -eq 0) -and (($lines -match 'brltty|espeakup').Count -eq 0)
}
Check 'run again on an unchanged log says nothing new' {
    $before = (Read-Log 'PF2ABC1D').Count
    $null = Invoke-Reporter 'run'
    (Read-Log 'PF2ABC1D').Count -eq $before
}
Check 'run: a new step in the log is reported on the next cycle, in words for a known one and by name otherwise' {
    [System.IO.File]::AppendAllText($syslog, "Sep  6 10:58:00 main-menu[321]: INFO: Menu item 'pkgsel' selected`nSep  6 10:58:01 main-menu[321]: INFO: Menu item 'lvmcfg' selected`n")
    $null = Invoke-Reporter 'run'
    $lines = Read-Log 'PF2ABC1D'
    (($lines -match '  Selecting and installing software$').Count -eq 1) -and (($lines -match '  Step: lvmcfg$').Count -eq 1) -and (($lines -match '  Configuring the network$').Count -eq 1)
}
Check 'late: reports, records the server and identity for first boot in /target/etc/windeploykit/deploy.conf, and installs itself' {
    $r = Invoke-Reporter 'late'
    $conf = Join-Path $target 'etc/windeploykit/deploy.conf'
    $copy = Join-Path $target 'usr/local/sbin/wdk-report'
    $c = if (Test-Path -LiteralPath $conf) { Get-Content -LiteralPath $conf -Raw } else { '' }
    ($r.rc -eq 0) -and ($c -match "WDK_BASE_URL='$([regex]::Escape($base))'") -and ($c -match "WDK_SERIAL='PF2ABC1D'") -and ($c -match "WDK_INSTALLED='\d{4}-\d\d-\d\dT") -and
    (Test-Path -LiteralPath $copy) -and ((Get-Content -LiteralPath $copy -Raw) -eq (Get-Content -LiteralPath $reporter -Raw)) -and
    (((Read-Log 'PF2ABC1D') -match '  End-of-install steps running$').Count -eq 1)
}
Check 'done: reports success for 0 and the exit status otherwise' {
    $null = Invoke-Reporter 'done' '0'
    $null = Invoke-Reporter 'done' '3'
    $lines = Read-Log 'PF2ABC1D'
    (($lines -match '  Installation finished; rebooting into the new system$').Count -eq 1) -and (($lines -match '  Installation finished; the last end-of-install step exited 3$').Count -eq 1)
}
Check 'firstboot: runs the first-boot script from deploy.conf''s server, reports start, exit code and the last lines, and exits with the script''s code' {
    $conf = Join-Path $target 'etc/windeploykit/deploy.conf'
    $runner = Join-Path $fix 'wdk-run'
    [System.IO.File]::WriteAllText($runner, "#!/bin/sh`necho one`necho two`necho three`necho four`nexit 4`n")
    & chmod 0755 $runner
    $fblog = Join-Path $fix 'firstboot.log'
    $r = Invoke-Reporter 'firstboot' '' @{ WDK_ENV = $conf; WDK_LOG = $fblog; WDK_RUN = $runner }
    $lines = Read-Log 'PF2ABC1D'
    ($r.rc -eq 4) -and (($lines -match '  First boot: running the first-boot script$').Count -eq 1) -and (($lines -match '  First boot: the script exited 4 after \d+s$').Count -eq 1) -and
    (($lines -match '    two$').Count -eq 1) -and (($lines -match '    four$').Count -eq 1) -and (($lines -match '    one$').Count -eq 0) -and
    ((Get-Content -LiteralPath $fblog) -join ',' -eq 'one,two,three,four')
}
Check 'no server on the kernel line: start does nothing and exits 0 (an interactive boot never reports)' {
    $plain = Join-Path $fix 'cmdline-plain'
    [System.IO.File]::WriteAllText($plain, "BOOT_IMAGE=/linux vga=788 --- quiet`n")
    $env2 = Join-Path $fix 'env2'
    $r = Invoke-Reporter 'start' '' @{ WDK_CMDLINE = $plain; WDK_ENV = $env2 }
    ($r.rc -eq 0) -and -not (Test-Path -LiteralPath $env2)
}
Check 'a line is percent-encoded and cut: ampersand, percent and quotes cannot reach the query string' {
    # The functions sit above the mode switch: take everything before "case" as a library.
    $lib = Join-Path $fix 'enc-lib.sh'
    $src = Get-Content -LiteralPath $reporter
    $body = @($src | Select-Object -First ([array]::IndexOf($src, ($src | Where-Object { $_ -like 'case "$mode" in*' } | Select-Object -First 1))))
    [System.IO.File]::WriteAllText($lib, (($body -join "`n") + "`n"))
    $probe = Join-Path $fix 'enc-probe.sh'
    [System.IO.File]::WriteAllText($probe, ". '$lib'`n" + 'enc ' + "'" + 'a&b=c%d "q" (e) ' + ('z' * 300) + "'`n")
    $out = [string](& sh $probe)
    $out -eq ('a_b=c_d%20_q_%20(e)%20' + ('z' * 224))
}

Write-Host 'The publisher:'
Check 'Write-AppPxeBootLinuxReporterAsset puts the script under http/linux/ byte for byte and rewrites only when it changed' {
    $http = Join-Path $work 'http'
    $p = Write-AppPxeBootLinuxReporterAsset -HttpRoot $http
    $first = (Get-Item -LiteralPath $p).LastWriteTimeUtc
    Start-Sleep -Milliseconds 30
    $null = Write-AppPxeBootLinuxReporterAsset -HttpRoot $http
    ($p -eq (Join-Path $http 'linux/wdk-report.sh')) -and ((Get-Content -LiteralPath $p -Raw) -eq (Get-Content -LiteralPath $reporter -Raw)) -and ((Get-Item -LiteralPath $p).LastWriteTimeUtc -eq $first)
}

Stop-AppPxeBootImagingLogIngest
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($script:fail) {
    Write-Host "`nlinux install report: $($script:fail) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nlinux install report: all checks passed"

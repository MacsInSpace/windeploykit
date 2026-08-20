#requires -Version 5.1
<#
.SYNOPSIS
    FieldIso SMB lab test - WinPE authenticated mount to a macOS share (SB-PXE-1 spike).

    Served at ${http_base}/fieldiso/run-smb-test.ps1 (Stop -> Start field PXE to sync).

    Config (first match wins):
      UNC:        -UncPath > env:FIELDISO_SMB_UNC > System32\smb-test.unc > default lab UNC
      credential: env:FIELDISO_SMB_USER/PASS > System32\smb-test.cred (line1=user, line2=pass)
      workgroup:  env:FIELDISO_SMB_WORKGROUP (default WORKGROUP)

    Does NOT run imaging. Forces an NTLMv2 + signing client policy, then mounts the
    share with /user:WORKGROUP\<user> (the form macOS smbd accepts for a local
    account) and lists/reads/writes it. No guest path - macOS rejects WinPE guest.

    NOTE: ASCII-only log strings. StrictMode Latest.
#>
param(
    [string]$UncPath,
    [string]$DriveLetter = 'Z:',
    [switch]$SkipWriteTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FieldIsoSmbTestVersion = '2026-06-26-v13-hidden-share'

# NTLM domain/workgroup sent with the authenticated mount. PROVEN: macOS smbd
# authenticates a local account only when the NTLM domain is its workgroup
# (default WORKGROUP); a bare or IP-qualified user is rejected as error 86.
# Override via env:FIELDISO_SMB_WORKGROUP if a site uses a non-default workgroup.
$FieldIsoSmbWorkgroup = if ($env:FIELDISO_SMB_WORKGROUP) { [string]$env:FIELDISO_SMB_WORKGROUP } else { 'WORKGROUP' }

function Write-FieldIsoLog {
    param([string]$Message)
    Write-Host "[FieldIso-SMB] $Message"
    try { [Console]::Out.Flush() } catch { }
}

function Read-FieldIsoOneLineFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = [string](Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return $line.Trim()
}

function Read-FieldIsoSmbCredential {
    # Throwaway local SMB account for the authenticated mount test.
    # Read the .cred FILE first: PowerShell Get-Content splits LF *or* CRLF
    # correctly, whereas the .cmd's `set /p` mangles an LF-only file (it slurps
    # BOTH lines into FIELDISO_SMB_USER and leaves the password empty). Env vars
    # (FIELDISO_SMB_USER/PASS) are only a fallback. line1 = user, line2 = password.
    # Every value is hard-trimmed. Never embed a privileged account here.
    $user = $null; $pass = $null
    $credPath = Join-Path $env:SystemRoot 'System32\smb-test.cred'
    if (Test-Path -LiteralPath $credPath) {
        $lines = @(Get-Content -LiteralPath $credPath -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 1) { $user = [string]$lines[0] }
        if ($lines.Count -ge 2) { $pass = [string]$lines[1] }
    }
    if ([string]::IsNullOrWhiteSpace($user) -and $env:FIELDISO_SMB_USER) {
        $user = [string]$env:FIELDISO_SMB_USER
        $pass = [string]$env:FIELDISO_SMB_PASS
    }
    if ([string]::IsNullOrWhiteSpace($user)) { return $null }
    if ($null -eq $pass) { $pass = '' }
    return @{ User = $user.Trim(); Pass = $pass.Trim() }
}

function Invoke-FieldIsoNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $out = & $FilePath @ArgumentList 2>&1
        } else {
            $out = & $FilePath 2>&1
        }
        return @{
            ExitCode = $LASTEXITCODE
            Output   = @($out | ForEach-Object { [string]$_ })
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Write-FieldIsoCommandResult {
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [switch]$Quiet
    )
    foreach ($line in @($Result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            if (-not $Quiet) { Write-FieldIsoLog "  $line" }
        }
    }
    if (-not $Quiet) {
        Write-FieldIsoLog "  -> exit $($Result.ExitCode)"
    }
    return [int]$Result.ExitCode
}

function Set-FieldIsoSmbClientForAuth {
    # macOS smbd (Sonoma/Sequoia/macOS 26) authenticates local accounts with
    # NTLMv2 and negotiates SMB signing - proven, since `smbutil` from the Mac
    # itself authenticates this throwaway account. WinPE can default to a weaker
    # NTLM level and may have signing off, which makes macOS reject the logon.
    # So force NTLMv2-only + keep client signing enabled before the mount.
    $sets = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'LmCompatibilityLevel'; Value = 3 }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'; Name = 'NtlmMinClientSec'; Value = 537395200 } # 0x20080000 NTLMv2 + 128-bit
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'; Name = 'EnableSecuritySignature'; Value = 1 }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'; Name = 'RequireSecuritySignature'; Value = 0 }
    )
    foreach ($s in @($sets)) {
        $p = [string]$s.Path
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
        New-ItemProperty -LiteralPath $p -Name ([string]$s.Name) -PropertyType DWord -Value ([int]$s.Value) -Force | Out-Null
        Write-FieldIsoLog "Set $($s.Name)=$($s.Value) under $p"
    }
    Write-FieldIsoLog 'Restarting Workstation service (NTLMv2 client policy)...'
    $stop = Invoke-FieldIsoNativeCommand -FilePath 'net.exe' -ArgumentList @('stop', 'workstation', '/y')
    Write-FieldIsoCommandResult -Result $stop -Quiet | Out-Null
    Start-Sleep -Seconds 2
    $start = Invoke-FieldIsoNativeCommand -FilePath 'net.exe' -ArgumentList @('start', 'workstation')
    Write-FieldIsoCommandResult -Result $start -Quiet | Out-Null
    Start-Sleep -Seconds 2
    return $true
}

function Get-FieldIsoNetUseErrorHint {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match '(?i)error\s+5\b|access is denied') {
        return 'error 5 = access denied (often before AllowInsecureGuestAuth or server rejects anonymous listing)'
    }
    if ($Text -match '(?i)error\s+67\b|network connection could not be found|network name cannot be found') {
        return 'error 67 = share/path not found or SMB redirector not ready'
    }
    if ($Text -match '(?i)error\s+86\b|invalid password|wrong password') {
        return 'error 86 = bad credentials / guest auth blocked'
    }
    if ($Text -match '(?i)error\s+1937\b|NTLM authentication has been disabled') {
        return 'error 1937 = Win11 WinPE SMB signing vs guest (NTLM disabled for guest) - spike CLOSED FAIL'
    }
    if ($Text -match '(?i)error\s+1327\b|account restrictions are preventing') {
        return 'error 1327 = guest/blank password blocked under signing policy'
    }
    if ($Text -match '(?i)error\s+1326\b|logon failure') {
        return 'error 1326 = logon failure (username/password)'
    }
    if ($Text -match '(?i)wrong password|user name or password is incorrect') {
        return 'auth rejected - apply guest registry first, then retry'
    }
    return $null
}

function Clear-FieldIsoDriveMapping {
    param([Parameter(Mandatory)][string]$Drive)
    # Ignore "network connection could not be found" when drive was never mapped.
    $null = cmd.exe /c "net use $Drive /delete /y >nul 2>&1"
}

function Invoke-FieldIsoNetUseCmd {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][string]$Unc,
        [Parameter(Mandatory)][string]$CmdLine,
        [string]$DisplayCmd
    )
    Write-FieldIsoLog "--- $Label ---"
    if ([string]::IsNullOrWhiteSpace($DisplayCmd)) { $DisplayCmd = $CmdLine }
    Write-FieldIsoLog "  $DisplayCmd"
    Clear-FieldIsoDriveMapping -Drive $Drive
    $result = Invoke-FieldIsoNativeCommand -FilePath 'cmd.exe' -ArgumentList @('/c', $CmdLine)
    $trim = ($result.Output -join "`n").Trim()
    if ($trim) {
        foreach ($line in ($trim -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-FieldIsoLog "  $line"
            }
        }
    }
    $hint = Get-FieldIsoNetUseErrorHint -Text $trim
    if ($hint) { Write-FieldIsoLog "  hint: $hint" }
    if ([int]$result.ExitCode -eq 0) {
        Write-FieldIsoLog '  -> exit 0 (success)'
        return $true
    }
    Write-FieldIsoLog "  -> exit $($result.ExitCode)"
    return $false
}

function Test-FieldIsoDriveMapped {
    param([Parameter(Mandatory)][string]$Drive)
    $result = Invoke-FieldIsoNativeCommand -FilePath 'net.exe' -ArgumentList @('use')
    $out = ($result.Output -join "`n")
    $letter = $Drive.TrimEnd(':')
    return ($out -match "(?i)\s$([regex]::Escape($letter)):\s")
}

function Show-FieldIsoNetworkSummary {
    Write-FieldIsoLog 'Network (ipconfig):'
    $result = Invoke-FieldIsoNativeCommand -FilePath 'ipconfig.exe' -ArgumentList @()
    foreach ($line in @($result.Output)) { Write-FieldIsoLog "  $line" }
}

function Test-FieldIsoPingHost {
    param([Parameter(Mandatory)][string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return }
    if ($HostName -match '^\d+\.\d+\.\d+\.\d+$') {
        Write-FieldIsoLog "Ping $HostName ..."
        $result = Invoke-FieldIsoNativeCommand -FilePath 'ping.exe' -ArgumentList @('-n', '2', '-w', '1500', $HostName)
        foreach ($line in @($result.Output)) { Write-FieldIsoLog "  $line" }
    }
}

function Test-FieldIsoTcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )
    Write-FieldIsoLog "TCP connect $HostName`:$Port ..."
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if (-not $ok) {
            Write-FieldIsoLog '  -> timeout (port not reachable in 3s)'
            return $false
        }
        $client.EndConnect($iar)
        Write-FieldIsoLog '  -> OK'
        return $true
    } catch {
        Write-FieldIsoLog "  -> FAIL: $($_.Exception.Message)"
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Show-FieldIsoNetView {
    param([Parameter(Mandatory)][string]$HostName)
    Write-FieldIsoLog "net view \\$HostName"
    $result = Invoke-FieldIsoNativeCommand -FilePath 'net.exe' -ArgumentList @('view', "\\$HostName")
    Write-FieldIsoCommandResult -Result $result | Out-Null
}

function Test-FieldIsoUncDir {
    param([Parameter(Mandatory)][string]$Unc)
    Write-FieldIsoLog "dir $Unc (no drive letter)"
    $result = Invoke-FieldIsoNativeCommand -FilePath 'cmd.exe' -ArgumentList @('/c', "dir /a `"$Unc`"")
    Write-FieldIsoCommandResult -Result $result | Out-Null
    return ($result.ExitCode -eq 0)
}

function Get-FieldIsoUncHost {
    param([Parameter(Mandatory)][string]$Unc)
    if ($Unc -match '^\\\\([^\\]+)\\') {
        return $matches[1]
    }
    return $null
}

function Get-FieldIsoUncShare {
    param([Parameter(Mandatory)][string]$Unc)
    if ($Unc -match '^\\\\[^\\]+\\([^\\]+)') {
        return $matches[1]
    }
    return $null
}

function Test-FieldIsoShareAccess {
    param(
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][string]$Unc
    )
    Write-FieldIsoLog "Mapped $Drive -> $Unc"
    Write-FieldIsoLog 'dir:'
    Get-ChildItem -LiteralPath $Drive -Force -ErrorAction Stop | ForEach-Object {
        # Directories (DirectoryInfo) have no .Length; accessing it throws under
        # StrictMode and was the cause of the false "PARTIAL" result.
        $size = if ($_.PSIsContainer) { '<DIR>' } else { $_.Length }
        Write-FieldIsoLog "  $($_.Mode) $size $($_.Name)"
    }

    $readProbe = Get-ChildItem -LiteralPath $Drive -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($readProbe) {
        $snippet = Get-Content -LiteralPath $readProbe.FullName -TotalCount 3 -ErrorAction SilentlyContinue
        Write-FieldIsoLog "Read sample ($($readProbe.Name)):"
        foreach ($line in @($snippet)) {
            Write-FieldIsoLog "  $line"
        }
    }

    if (-not $SkipWriteTest) {
        # A write-denied result is EXPECTED on a read-only share and must NOT
        # downgrade an otherwise-successful authenticated read mount to PARTIAL.
        $writeDir = Join-Path $Drive ('windeploykit-pe-write-{0}' -f (Get-Date -Format 'HHmmss'))
        try {
            New-Item -Path $writeDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-FieldIsoLog "Write test: created $writeDir (read-write share)"
            Remove-Item -LiteralPath $writeDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-FieldIsoLog "Write test: write denied - read-only share (OK): $($_.Exception.Message)"
        }
    }
}

# --- main ---
Write-FieldIsoLog "SMB test starting (run-smb-test.ps1 $FieldIsoSmbTestVersion)"

$unc = $UncPath
if ([string]::IsNullOrWhiteSpace($unc) -and $env:FIELDISO_SMB_UNC) {
    $unc = [string]$env:FIELDISO_SMB_UNC
}
if ([string]::IsNullOrWhiteSpace($unc)) {
    $unc = Read-FieldIsoOneLineFile -Path (Join-Path $env:SystemRoot 'System32\smb-test.unc')
}
if ([string]::IsNullOrWhiteSpace($unc)) {
    $unc = '\\10.0.1.147\DEPLOYKIT_SMB_SPIKE$'
}

if ($env:FIELDISO_SMB_DRIVE) {
    $DriveLetter = [string]$env:FIELDISO_SMB_DRIVE
}
if ($DriveLetter -notmatch ':$') {
    $DriveLetter = "$DriveLetter`:"
}

Write-FieldIsoLog "Target UNC: $unc"
Write-FieldIsoLog "Drive letter: $DriveLetter"

Show-FieldIsoNetworkSummary
$hostName = Get-FieldIsoUncHost -Unc $unc
$shareName = Get-FieldIsoUncShare -Unc $unc
if ($hostName) {
    Test-FieldIsoPingHost -HostName $hostName
    $port445 = Test-FieldIsoTcpPort -HostName $hostName -Port 445
    if ($port445) {
        Write-FieldIsoLog 'TCP 445 OK - Mac SMB port reachable (firewall off / path good)'
    }
}

# NTLMv2 + signing-on client policy FIRST - this is what macOS smbd accepts.
# The guest tweaks (which DISABLE signing) are deferred to the fallback phase so
# they cannot sabotage the authenticated attempt.
Write-FieldIsoLog 'Applying NTLMv2 client policy before authenticated net use...'
Set-FieldIsoSmbClientForAuth | Out-Null

if ($hostName) {
    Show-FieldIsoNetView -HostName $hostName
    Test-FieldIsoUncDir -Unc $unc | Out-Null
}

# Authenticated attempts first - a real local account (NTLMv2 session key)
# succeeds where guest fails on WinPE SMB signing (1937).
$cred = Read-FieldIsoSmbCredential
$authAttempts = @()
if ($cred) {
    $u = [string]$cred.User
    $pPlain = [string]$cred.Pass
    $pQuoted = '"' + $pPlain.Replace('"', '') + '"'
    Write-FieldIsoLog ("Authenticated credential present: user=[{0}] passLen={1} password=*** (env / System32\smb-test.cred)" -f $u, $pPlain.Length)
    # PROVEN on the Mac: net use /user:WORKGROUP\dkimg authenticates this local
    # account where a bare or IP-qualified user fails as error 86 - macOS smbd
    # rejects the logon when the NTLM domain isn't its workgroup, and a bare
    # /user: makes WinPE send its OWN computer name as the domain. So the
    # workgroup-qualified form is primary; bare user stays as a fallback for any
    # site whose Mac uses a non-default workgroup we didn't override.
    if ($u -notmatch '[\\@]') {
        $wgQualified = '{0}\{1}' -f $FieldIsoSmbWorkgroup, $u
        $authAttempts += @{
            Label   = "authenticated workgroup-qualified ($wgQualified)"
            Cmd     = 'net use {0} {1} {2} /user:{3}' -f $DriveLetter, $unc, $pQuoted, $wgQualified
            Display = 'net use {0} {1} *** /user:{2}' -f $DriveLetter, $unc, $wgQualified
        }
    }
    $authAttempts += @{
        Label   = "authenticated user ($u)"
        Cmd     = 'net use {0} {1} {2} /user:{3}' -f $DriveLetter, $unc, $pQuoted, $u
        Display = 'net use {0} {1} *** /user:{2}' -f $DriveLetter, $unc, $u
    }
} else {
    Write-FieldIsoLog 'No authenticated credential found (FIELDISO_SMB_USER / System32\smb-test.cred) - cannot test the authenticated path'
}

$mapped = $false
$mappedVia = $null

function Invoke-FieldIsoAttemptList {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Attempts)
    foreach ($attempt in @($Attempts)) {
        $display = if ($attempt.ContainsKey('Display')) { [string]$attempt.Display } else { [string]$attempt.Cmd }
        if (Invoke-FieldIsoNetUseCmd -Label $attempt.Label -Drive $DriveLetter -Unc $unc -CmdLine $attempt.Cmd -DisplayCmd $display) {
            if (Test-FieldIsoDriveMapped -Drive $DriveLetter) {
                return [string]$attempt.Label
            }
            Write-FieldIsoLog '  net use reported success but drive not listed - trying next method'
        }
    }
    return $null
}

# Authenticated mount under the NTLMv2 + signing-on policy. macOS smbd rejects
# WinPE guest auth (error 1937/1327), so the workgroup-qualified local account is
# the only viable path - no guest fallback.
$mappedVia = Invoke-FieldIsoAttemptList -Attempts $authAttempts
if ($mappedVia) { $mapped = $true }

Write-FieldIsoLog '=== SUMMARY ==='
if ($mapped) {
    try {
        Test-FieldIsoShareAccess -Drive $DriveLetter -Unc $unc
        Write-FieldIsoLog "RESULT: PASS - authenticated SMB mount works from WinPE (via: $mappedVia)"
    } catch {
        Write-FieldIsoLog "RESULT: PARTIAL - mapped but access failed: $($_.Exception.Message)"
    }
} else {
    Write-FieldIsoLog 'RESULT: FAIL - no authenticated SMB mount from WinPE'
    Write-FieldIsoLog 'Ping + TCP 445 can succeed while net use still fails. Full Windows OK != WinPE.'
    if (-not $cred) {
        Write-FieldIsoLog 'No credential was available - set FIELDISO_SMB_USER/PASS or System32\smb-test.cred.'
    } else {
        Write-FieldIsoLog ("Credential was tested. error 86 => check the Mac workgroup matches FIELDISO_SMB_WORKGROUP (currently {0}); error 1326 => wrong user/password." -f $FieldIsoSmbWorkgroup)
    }
    Write-FieldIsoLog 'Production FieldIso: HTTP curl + install.wim only. See docs/plugins/site-build/AGENT_DISCUSSIONS_SITE_BUILD_NETBOOT.md'
}

Write-FieldIsoLog 'Done - cmd shell remains open below.'
exit 0

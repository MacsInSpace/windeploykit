#requires -Version 5.1
<#
.SYNOPSIS
    FieldIso HTTP bootstrap - downloaded from ${http_base}/fieldiso/run.ps1 at WinPE startup.

    Windows OS install: curl install.wim over HTTP (signed tools only), DISM /Apply-Image.
    No httpdisk (unsigned kernel driver blocked on amd64 WinPE / Secure Boot).
    Optional OOBD driver packs from fieldiso/drivers; 7z + pnputil.

    install.wim.url in System32 (from iPXE) or derived from iso.url -> http/iso-wim/<iso>/install.wim

    NOTE: Use ASCII only in log strings. StrictMode Latest + ErrorAction Stop throughout.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FieldIsoLog {
    param([string]$Message)
    Write-Host "[FieldIso] $Message"
    try { [Console]::Out.Flush() } catch { }
}

function Stop-FieldIsoBootstrap {
    param([Parameter(Mandatory)][string]$Message)
    Write-FieldIsoLog $Message
    exit 1
}

function Read-FieldIsoOneLineFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = [string](Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return $line.Trim()
}

function Get-FieldIsoWorkDir {
    $dir = Join-Path $env:SystemRoot 'Temp\fieldiso'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    return $dir
}

function Get-FieldIsoToolsDir {
    Join-Path (Get-FieldIsoWorkDir) 'tools'
}

function Ensure-FieldIsoTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$HttpBase,
        [string[]]$CandidateRelPaths
    )
    foreach ($rel in @($CandidateRelPaths)) {
        $sysPath = Join-Path $env:SystemRoot ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $sysPath) {
            return $sysPath
        }
    }

    $toolsDir = Get-FieldIsoToolsDir
    $dest = Join-Path $toolsDir $Name
    if (Test-Path -LiteralPath $dest) { return $dest }

    Write-FieldIsoLog "$Name not in WinPE - FieldIso.wim should include tools in System32."
    return $null
}

function Join-FieldIsoHttpUrl {
    param(
        [Parameter(Mandatory)][string]$HttpBase,
        [Parameter(Mandatory)][string]$RelPath
    )
    $base = $HttpBase.TrimEnd('/')
    $segments = @($RelPath -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $encoded = ($segments | ForEach-Object { [Uri]::EscapeDataString([string]$_) }) -join '/'
    return "$base/$encoded"
}

function Format-FieldIsoNativeExitCode {
    param([int]$ExitCode)
    if ($ExitCode -ge 0) { return "$ExitCode" }
    $unsigned = [uint32]::Cast([int32]$ExitCode)
    return "$ExitCode (0x$($unsigned.ToString('X8')))"
}

function Get-FieldIsoHttpContentLength {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$CurlPath
    )
    if (-not $CurlPath -or -not (Test-Path -LiteralPath $CurlPath)) {
        return [int64]0
    }
    try {
        $lines = @(& $CurlPath -sI -L $Url 2>&1)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = [string]$lines[$i]
            if ($line -match '^Content-Length:\s*(\d+)\s*$') {
                return [int64]$matches[1]
            }
        }
    } catch {
        Write-FieldIsoLog "Could not read ISO Content-Length - $($_.Exception.Message)"
    }
    return [int64]0
}

function Get-FieldIsoInstallWimUrlFromIsoUrl {
    param([AllowNull()][string]$IsoUrl)
    if ([string]::IsNullOrWhiteSpace($IsoUrl)) { return $null }
    try {
        $uri = [Uri]$IsoUrl
    } catch {
        return $null
    }
    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    if ($path -notmatch '(?i)\.iso$') { return $null }
    $isoLeaf = [IO.Path]::GetFileName($path)
    if ([string]::IsNullOrWhiteSpace($isoLeaf)) { return $null }
    $isoBase = [IO.Path]::GetFileNameWithoutExtension($isoLeaf)
    if ([string]::IsNullOrWhiteSpace($isoBase)) { return $null }
    $encodedBase = [Uri]::EscapeDataString($isoBase)
    $builder = New-Object System.UriBuilder $uri
    if ($uri.IsDefaultPort) {
        $builder.Port = -1
    }
    $builder.Path = "/iso-wim/$encodedBase/install.wim"
    return $builder.Uri.AbsoluteUri
}

function Resolve-FieldIsoInstallWimUrl {
    param(
        [AllowNull()][string]$InstallWimUrlFile,
        [AllowNull()][string]$IsoUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($InstallWimUrlFile)) {
        Write-FieldIsoLog "install.wim URL (install.wim.url): $InstallWimUrlFile"
        return $InstallWimUrlFile.Trim()
    }
    $derived = Get-FieldIsoInstallWimUrlFromIsoUrl -IsoUrl $IsoUrl
    if ($derived) {
        Write-FieldIsoLog "install.wim URL (derived from iso.url): $derived"
    }
    return $derived
}

function Get-FieldIsoApplyDir {
    $fromEnv = $env:FIELDISO_APPLY_DIR
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv.Trim().TrimEnd('\')
    }
    # Skip D: - often the read-only virtio-win / ISO CD in lab boots.
    foreach ($letter in @('W', 'E', 'F', 'G', 'C')) {
        if ($letter -eq 'X') { continue }
        $root = "${letter}:\"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (-not (Test-FieldIsoDriveWritable -Root $root)) {
            Write-FieldIsoLog "Apply target skip $root (read-only or not writable)"
            continue
        }
        Write-FieldIsoLog "Apply target (auto): $root"
        return $root.TrimEnd('\')
    }
    return $null
}

function Test-FieldIsoQemuVirtualMachine {
    $model = Get-FieldIsoWmiModel
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        if ($model -match 'Standard PC|QEMU|Virtual Machine|VirtualBox|VMware|Hyper-V') {
            return $true
        }
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $maker = [string]$cs.Manufacturer
        if ($maker -match 'QEMU|Red Hat|innotek|VMware|Microsoft Corporation') {
            return $true
        }
    } catch {
        try {
            $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
            $maker = [string]$cs.Manufacturer
            if ($maker -match 'QEMU|Red Hat|innotek|VMware|Microsoft Corporation') {
                return $true
            }
        } catch { }
    }
    return $false
}

function Test-FieldIsoAutoPrepDiskEnabled {
    if ($env:FIELDISO_AUTO_PREP_DISK -eq '0') { return $false }
    if ($env:FIELDISO_AUTO_PREP_DISK -eq '1') { return $true }
    # Default on: fleet laptops (e.g. staff Acers) need diskpart after the driver inject.
    return $true
}

function Write-FieldIsoDiskInventory {
    Write-FieldIsoLog 'Disk inventory (rescan, list disk, list volume)...'
    Invoke-FieldIsoDiskpartScript -Commands @('rescan') | Out-Null
    Start-Sleep -Seconds 3
    Invoke-FieldIsoDiskpartScript -Commands @('list disk') | Out-Null
    Invoke-FieldIsoDiskpartScript -Commands @('list volume') | Out-Null
}

function Test-FieldIsoDiskWipeConfirmRequired {
    if ($env:FIELDISO_CONFIRM_DISK -eq '0') { return $false }
    if ($env:FIELDISO_CONFIRM_DISK -eq '1') { return $true }
    # Default on: destructive diskpart needs an operator ack (like iPXE menu / deploy prompt).
    return $true
}

function Wait-FieldIsoDiskWipeConfirm {
    param(
        [Parameter(Mandatory)][int]$DiskIndex,
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$EfiLetter
    )
    if (-not (Test-FieldIsoDiskWipeConfirmRequired)) {
        Write-FieldIsoLog 'Disk wipe confirm skipped (FIELDISO_CONFIRM_DISK=0).'
        return
    }
    Write-FieldIsoLog '============================================'
    Write-FieldIsoLog "WARNING: Disk $DiskIndex will be ERASED (clean, GPT, ${EfiLetter}: EFI, ${DriveLetter}: Windows)."
    Write-FieldIsoLog 'Review list disk / list volume above.'
    Write-FieldIsoLog 'Type YES (all caps) to wipe and begin imaging. Ctrl+C to abort.'
    Write-FieldIsoLog '============================================'
    try {
        [Console]::Out.Flush()
    } catch { }
    $answer = Read-Host 'Type YES to wipe disk'
    if ([string]$answer -cne 'YES') {
        Stop-FieldIsoBootstrap "Disk wipe aborted - expected YES, got '$answer'."
    }
    Write-FieldIsoLog 'Disk wipe confirmed - proceeding with diskpart.'
}

function Invoke-FieldIsoDiskpartScript {
    param([Parameter(Mandatory)][string[]]$Commands)
    $scriptPath = Join-Path (Get-FieldIsoWorkDir) ('diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $scriptPath -Value ($Commands -join "`r`n") -Encoding ASCII
    $output = @(& diskpart /s $scriptPath 2>&1)
    foreach ($line in $output) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-FieldIsoLog "diskpart: $text"
        }
    }
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    return ($LASTEXITCODE -eq 0)
}

function Initialize-FieldIsoApplyVolume {
    param(
        [string]$DriveLetter = 'W',
        [string]$EfiLetter = 'S'
    )
    $diskIndex = 0
    if ($env:FIELDISO_PREP_DISK_INDEX) {
        $parsed = 0
        if ([int]::TryParse([string]$env:FIELDISO_PREP_DISK_INDEX, [ref]$parsed) -and $parsed -ge 0) {
            $diskIndex = $parsed
        }
    }
    if ($env:FIELDISO_EFI_LETTER) {
        $EfiLetter = [string]$env:FIELDISO_EFI_LETTER
    }

    Write-FieldIsoLog "Auto-preparing disk $diskIndex as ${DriveLetter}: (+ EFI ${EfiLetter}:)..."
    Write-FieldIsoDiskInventory
    Wait-FieldIsoDiskWipeConfirm -DiskIndex $diskIndex -DriveLetter $DriveLetter -EfiLetter $EfiLetter

    $commands = @(
        "select disk $diskIndex"
        'clean'
        'convert gpt'
        'create partition efi size=100'
        'format fs=fat32 quick label=System'
        "assign letter=$EfiLetter"
        'create partition msr size=16'
        'create partition primary'
        'format fs=ntfs quick label=Windows'
        "assign letter=$DriveLetter"
    )
    if (-not (Invoke-FieldIsoDiskpartScript -Commands $commands)) {
        Write-FieldIsoLog "diskpart prep failed on disk $diskIndex"
        return $false
    }

    Start-Sleep -Seconds 2
    $applyRoot = "${DriveLetter}:\"
    if (-not (Test-FieldIsoDriveWritable -Root $applyRoot)) {
        Write-FieldIsoLog "Disk prep finished but ${DriveLetter}: is not writable"
        return $false
    }
    $script:FieldIsoEfiBootLetter = $EfiLetter
    $script:FieldIsoAutoPreppedVolume = $true
    Write-FieldIsoLog "Apply volume ready: ${DriveLetter}:\ (EFI ${EfiLetter}:)"
    return $true
}

function Ensure-FieldIsoApplyVolume {
    if (-not [string]::IsNullOrWhiteSpace($env:FIELDISO_APPLY_DIR)) { return }
    if (Test-FieldIsoAutoPrepDiskEnabled) {
        Initialize-FieldIsoApplyVolume | Out-Null
        return
    }
    if (Get-FieldIsoApplyDir) { return }
    Write-FieldIsoLog 'No writable apply volume - diskpart prep failed or disabled (FIELDISO_AUTO_PREP_DISK=0). Set FIELDISO_APPLY_DIR to use an existing volume.'
}

function Resolve-FieldIsoEfiLetter {
    if ($script:FieldIsoEfiBootLetter) {
        return $script:FieldIsoEfiBootLetter
    }
    if ($env:FIELDISO_EFI_LETTER) {
        $letter = [string]$env:FIELDISO_EFI_LETTER.Trim().TrimEnd(':')
        if (-not [string]::IsNullOrWhiteSpace($letter)) {
            return $letter
        }
    }
    foreach ($letter in @('S', 'E', 'F', 'G', 'H', 'D')) {
        $root = "${letter}:\"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi')) {
            return $letter
        }
    }
    foreach ($letter in @('S', 'E', 'F', 'G', 'H', 'D')) {
        $root = "${letter}:\"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root 'EFI')) {
            return $letter
        }
        $probe = Join-Path $root 'fieldiso-efi-probe.tmp'
        try {
            [IO.File]::WriteAllBytes($probe, @(0x42))
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
            if ($letter -eq 'S') {
                return $letter
            }
        } catch { }
    }
    return $null
}

function Install-FieldIsoUefiBootFiles {
    param(
        [Parameter(Mandatory)][string]$ApplyDir,
        [string]$EfiLetter
    )
    if ([string]::IsNullOrWhiteSpace($EfiLetter)) {
        $EfiLetter = Resolve-FieldIsoEfiLetter
    }
    if ([string]::IsNullOrWhiteSpace($EfiLetter)) {
        Write-FieldIsoLog 'bcdboot skipped - EFI System Partition letter unknown (expected S:)'
        return $false
    }
    $script:FieldIsoEfiBootLetter = $EfiLetter
    $windowsDir = Join-Path $ApplyDir 'Windows'
    if (-not (Test-Path -LiteralPath $windowsDir)) {
        Write-FieldIsoLog "bcdboot skipped - $windowsDir missing"
        return $false
    }
    $efiRoot = "${EfiLetter}:\"
    if (-not (Test-Path -LiteralPath $efiRoot)) {
        Write-FieldIsoLog "bcdboot skipped - EFI volume ${EfiLetter}: missing"
        return $false
    }
    Write-FieldIsoLog "bcdboot $windowsDir -> $efiRoot (UEFI)"
    $output = @(& bcdboot $windowsDir /s $efiRoot /f UEFI /l en-us 2>&1)
    foreach ($line in $output) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-FieldIsoLog "bcdboot: $text"
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-FieldIsoLog "bcdboot failed (exit $(Format-FieldIsoNativeExitCode $LASTEXITCODE))"
        return $false
    }
    $bootEfi = Join-Path $efiRoot 'EFI\Microsoft\Boot\bootmgfw.efi'
    $fallbackEfi = Join-Path $efiRoot 'EFI\Boot\BOOTX64.EFI'
    if (-not ((Test-Path -LiteralPath $bootEfi) -or (Test-Path -LiteralPath $fallbackEfi))) {
        Write-FieldIsoLog "bcdboot reported success but boot loader missing on ${EfiLetter}:"
        return $false
    }
    Write-FieldIsoLog "UEFI boot files installed (bcdboot) on ${EfiLetter}:"
    return $true
}

function Test-FieldIsoDriveWritable {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = $Root.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $rootPath)) { return $false }
    if (-not (Test-Path -LiteralPath "${rootPath}\")) {
        $rootPath = "${rootPath}\"
    } else {
        $rootPath = if ($Root -match '\\$') { $Root } else { "$Root\" }
    }
    $probe = Join-Path $rootPath ('fieldiso-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($probe, @(0x42))
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-FieldIsoInstallWimStagingDir {
    param(
        [Parameter(Mandatory)][string]$ApplyDir,
        [int64]$RequiredBytes = 0
    )
    $fromEnv = $env:FIELDISO_STAGING_DIR
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $dir = $fromEnv.Trim().TrimEnd('\')
        if ((Test-FieldIsoDriveWritable -Root $dir) -and (
                $RequiredBytes -le 0 -or (Get-FieldIsoDriveFreeBytes -PathRoot $dir) -ge $RequiredBytes
            )) {
            Write-FieldIsoLog "install.wim staging (FIELDISO_STAGING_DIR): $dir"
            return $dir
        }
        Write-FieldIsoLog "FIELDISO_STAGING_DIR not usable: $dir"
    }

    if ((Test-FieldIsoDriveWritable -Root $ApplyDir) -and (
            $RequiredBytes -le 0 -or (Get-FieldIsoDriveFreeBytes -PathRoot $ApplyDir) -ge $RequiredBytes
        )) {
        return $ApplyDir
    }

    foreach ($letter in @('W', 'E', 'F', 'G', 'D', 'C')) {
        if ($letter -eq 'X') { continue }
        $root = "${letter}:\"
        $candidate = $root.TrimEnd('\')
        if ($candidate -eq $ApplyDir) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (-not (Test-FieldIsoDriveWritable -Root $root)) { continue }
        if ($RequiredBytes -gt 0 -and (Get-FieldIsoDriveFreeBytes -PathRoot $root) -lt $RequiredBytes) { continue }
        Write-FieldIsoLog "install.wim staging on $candidate (apply target $ApplyDir not writable or too small)"
        return $candidate
    }
    return $null
}

function Get-FieldIsoDriveFreeBytes {
    param([Parameter(Mandatory)][string]$PathRoot)
    try {
        $root = [System.IO.Path]::GetPathRoot($PathRoot)
        if ([string]::IsNullOrWhiteSpace($root)) { return [int64]0 }
        $drive = New-Object System.IO.DriveInfo($root)
        return [int64]$drive.AvailableFreeSpace
    } catch {
        return [int64]0
    }
}

function Test-FieldIsoInstallWimHttpReady {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$CurlPath
    )
    if (-not $CurlPath -or -not (Test-Path -LiteralPath $CurlPath)) {
        Write-FieldIsoLog 'curl.exe required to fetch install.wim over HTTP.'
        return $false
    }
    try {
        & $CurlPath -sI -L $Url 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-FieldIsoLog "HTTP HEAD failed for install.wim (curl exit $(Format-FieldIsoNativeExitCode $LASTEXITCODE))"
            return $false
        }
    } catch {
        Write-FieldIsoLog "HTTP HEAD failed - $($_.Exception.Message)"
        return $false
    }
    return $true
}

function Invoke-FieldIsoDownloadInstallWim {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$CurlPath
    )
    $parent = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    Write-FieldIsoLog "Downloading install.wim to $OutFile (curl, signed - no httpdisk)..."
    $curlArgs = @(
        '-fL'
        '--retry', '3'
        '--retry-delay', '5'
        '--connect-timeout', '30'
        '--progress-bar'
        '-o', $OutFile
        $Url
    )
    & $CurlPath @curlArgs
    if ($LASTEXITCODE -ne 0) {
        Write-FieldIsoLog "install.wim download failed (curl exit $(Format-FieldIsoNativeExitCode $LASTEXITCODE))"
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if (-not (Test-Path -LiteralPath $OutFile)) {
        Write-FieldIsoLog 'install.wim download failed - output file missing.'
        return $false
    }
    $sizeGb = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1GB, 2)
    Write-FieldIsoLog "install.wim saved - $sizeGb GB"
    return $true
}

function Invoke-FieldIsoApplyInstallWim {
    param(
        [Parameter(Mandatory)][string]$InstallWimUrl,
        [Parameter(Mandatory)][string]$CurlPath,
        [int]$ImageIndex = 1
    )
    if (-not $CurlPath -or -not (Test-Path -LiteralPath $CurlPath)) {
        Stop-FieldIsoBootstrap 'curl.exe not in WinPE - FieldIso.wim must include curl in System32.'
    }

    Ensure-FieldIsoApplyVolume

    $applyDir = Get-FieldIsoApplyDir
    if ([string]::IsNullOrWhiteSpace($applyDir)) {
        Stop-FieldIsoBootstrap 'No writable apply target - diskpart prep failed, set FIELDISO_APPLY_DIR, or set FIELDISO_AUTO_PREP_DISK=0 to use an existing volume.'
    }
    if (-not (Test-Path -LiteralPath $applyDir)) {
        Stop-FieldIsoBootstrap "Apply dir missing: $applyDir"
    }
    if (-not (Test-FieldIsoDriveWritable -Root $applyDir)) {
        Stop-FieldIsoBootstrap "Apply target $applyDir is read-only - format the target volume (W:) or set FIELDISO_APPLY_DIR."
    }

    if (-not (Test-FieldIsoInstallWimHttpReady -Url $InstallWimUrl -CurlPath $CurlPath)) {
        Stop-FieldIsoBootstrap "install.wim HTTP 404 or unreachable at $InstallWimUrl - on WinDeployKit Mac Stop then Start field PXE (downloads p7zip + extracts install.wim). Check sidecar logs if still 404."
    }

    $contentLength = Get-FieldIsoHttpContentLength -Url $InstallWimUrl -CurlPath $CurlPath
    $stagingDir = Get-FieldIsoInstallWimStagingDir -ApplyDir $applyDir -RequiredBytes $contentLength
    if ([string]::IsNullOrWhiteSpace($stagingDir)) {
        $needGb = if ($contentLength -gt 0) { [math]::Round($contentLength / 1GB, 2) } else { 4 }
        Stop-FieldIsoBootstrap "No writable staging drive for install.wim (~${needGb} GB) - format W: or set FIELDISO_STAGING_DIR."
    }

    $freeBytes = Get-FieldIsoDriveFreeBytes -PathRoot $stagingDir
    if ($contentLength -gt 0 -and $freeBytes -gt 0 -and $contentLength -gt $freeBytes) {
        $needGb = [math]::Round($contentLength / 1GB, 2)
        $freeGb = [math]::Round($freeBytes / 1GB, 2)
        Stop-FieldIsoBootstrap "Not enough space on $stagingDir for install.wim - need ~${needGb} GB, have ~${freeGb} GB free."
    } elseif ($contentLength -gt 0) {
        $needGb = [math]::Round($contentLength / 1GB, 2)
        Write-FieldIsoLog "install.wim size ~${needGb} GB (HTTP Content-Length)"
    }

    $wimLocal = Join-Path $stagingDir 'install.wim'
    if ($stagingDir -ne $applyDir) {
        Write-FieldIsoLog "Download staging: $stagingDir | DISM apply target: $applyDir"
    }
    if (-not (Invoke-FieldIsoDownloadInstallWim -Url $InstallWimUrl -OutFile $wimLocal -CurlPath $CurlPath)) {
        Stop-FieldIsoBootstrap "install.wim download failed - if curl exit 23, target drive is read-only; format W: or set FIELDISO_STAGING_DIR."
    }

    Write-FieldIsoLog "DISM /Apply-Image index $ImageIndex -> $applyDir"
    & dism /Apply-Image /ImageFile:$wimLocal /Index:$ImageIndex /ApplyDir:$applyDir /CheckIntegrity /Verify 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-FieldIsoBootstrap "DISM /Apply-Image failed (exit $(Format-FieldIsoNativeExitCode $LASTEXITCODE))"
    }
    Write-FieldIsoLog 'DISM /Apply-Image completed.'
    if (Test-Path -LiteralPath $wimLocal) {
        Remove-Item -LiteralPath $wimLocal -Force -ErrorAction SilentlyContinue
        Write-FieldIsoLog "Removed staging install.wim from $stagingDir"
    }
    return $applyDir
}

function Install-FieldIsoInjectedDrivers {
    $importDir = Join-Path $env:SystemRoot 'Drivers\FieldIsoImport'
    if (-not (Test-Path -LiteralPath $importDir)) {
        return $false
    }
    Write-FieldIsoLog 'Installing injected driver packages...'
    & pnputil /add-driver (Join-Path $importDir '*.inf') /subdirs /install
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        if ($exitCode -eq 3010) {
            Write-FieldIsoLog 'Injected-driver pnputil exit 3010 (drivers installed - rescan next)'
        }
        return $true
    }
    Write-FieldIsoLog "Injected-driver pnputil exit $(Format-FieldIsoNativeExitCode $exitCode)"
    return $false
}

function Invoke-FieldIsoCurl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$CurlPath
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    if ($CurlPath -and (Test-Path -LiteralPath $CurlPath)) {
        $curlArgs = @(
            '-fL'
            '--retry', '5'
            '--retry-all-errors'
            '--retry-delay', '3'
            '--connect-timeout', '30'
            '-C', '-'
            '-o', $OutFile
            $Url
        )
        & $CurlPath @curlArgs
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) { return $true }
        Write-FieldIsoLog "curl exit $LASTEXITCODE for $Url"
    }
    Write-FieldIsoLog 'Falling back to Invoke-WebRequest for download...'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 7200
        return (Test-Path -LiteralPath $OutFile)
    } catch {
        Write-FieldIsoLog "Invoke-WebRequest failed - $($_.Exception.Message)"
        return $false
    }
}

function Get-FieldIsoEntryProp {
    param(
        $Entry,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $null
    }
    return Get-FieldIsoJsonProp -Item $Entry -Name $Name
}

function Get-FieldIsoJsonProp {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Item) { return $null }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-FieldIsoJsonBool {
    param($Value)
    if ($Value -eq $true) { return $true }
    if ($Value -eq $false) { return $false }
    return [string]$Value -eq 'true'
}

function Get-FieldIsoWmiModel {
    foreach ($attempt in 1..4) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $model = [string]$cs.Model
            $maker = [string]$cs.Manufacturer
            if (-not [string]::IsNullOrWhiteSpace($maker)) {
                Write-FieldIsoLog "WMI manufacturer: $maker"
            }
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                return $model.Trim()
            }
        } catch {
            if ($attempt -eq 1) {
                Write-FieldIsoLog "WMI/CIM model query failed - $($_.Exception.Message)"
            }
        }
        try {
            $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
            $model = [string]$cs.Model
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                return $model.Trim()
            }
        } catch { }
        if ($attempt -lt 4) {
            Start-Sleep -Seconds 2
        }
    }
    try {
        $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name SystemProductName -ErrorAction Stop
        $model = [string]$bios.SystemProductName
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            Write-FieldIsoLog "Model from BIOS registry: $model"
            return $model.Trim()
        }
    } catch { }
    return $null
}

function Test-FieldIsoWmiPatternMatch {
    param(
        [string]$Model,
        [string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($Model) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    return $Model.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Select-FieldIsoDriverEntry {
    param(
        [Parameter(Mandatory)]$IndexDoc,
        [string]$WmiModel
    )
    if ([string]::IsNullOrWhiteSpace($WmiModel)) {
        return $null
    }
    $best = $null
    $bestScore = 0
    $vendorsNode = Get-FieldIsoJsonProp -Item $IndexDoc -Name 'vendors'
    if ($vendorsNode) {
        foreach ($vendorProp in $vendorsNode.PSObject.Properties) {
            foreach ($entry in @($vendorProp.Value)) {
                if (-not $entry) { continue }
                $archiveReady = Test-FieldIsoJsonBool -Value (Get-FieldIsoEntryProp -Entry $entry -Name 'archiveReady')
                $archive = [string](Get-FieldIsoEntryProp -Entry $entry -Name 'archive')
                if (-not $archiveReady -or [string]::IsNullOrWhiteSpace($archive)) { continue }
                $score = 0
                foreach ($pat in @(Get-FieldIsoEntryProp -Entry $entry -Name 'wmiPatterns')) {
                    if (Test-FieldIsoWmiPatternMatch -Model $WmiModel -Pattern ([string]$pat)) {
                        $score = [Math]::Max($score, ([string]$pat).Length)
                    }
                }
                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $best = $entry
                }
            }
        }
    }
    if ($best) { return $best }
    return $null
}

function Get-FieldIsoDriverEntryWithDefault {
    param(
        [Parameter(Mandatory)]$IndexDoc,
        [string]$WmiModel
    )
    $entry = Select-FieldIsoDriverEntry -IndexDoc $IndexDoc -WmiModel $WmiModel
    if ($entry) { return $entry }
    $def = Get-FieldIsoJsonProp -Item $IndexDoc -Name 'default'
    $archive = [string](Get-FieldIsoJsonProp -Item $def -Name 'archive')
    $ready = Test-FieldIsoJsonBool -Value (Get-FieldIsoJsonProp -Item $def -Name 'archiveReady')
    if ($ready -and -not [string]::IsNullOrWhiteSpace($archive)) {
        return @{
            relPath      = [string](Get-FieldIsoJsonProp -Item $def -Name 'relPath')
            archive      = $archive
            archiveReady = $true
            folder       = '_default'
            vendor       = '_default'
        }
    }
    return $null
}

function Test-FieldIsoDriverInfPresent {
    param([Parameter(Mandatory)][string]$Root)
    $inf = Get-ChildItem -LiteralPath $Root -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return ($null -ne $inf)
}

function Expand-FieldIsoDriverPack {
    param(
        [Parameter(Mandatory)][string]$PackPath,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string]$SevenZipPath
    )
    if (-not (Test-Path -LiteralPath $SevenZipPath)) {
        Write-FieldIsoLog '7z.exe missing - cannot extract driver pack.'
        return $false
    }
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    & $SevenZipPath x -y "-o$DestDir" $PackPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-FieldIsoLog "7z extract failed (exit $LASTEXITCODE) for $(Split-Path -Leaf $PackPath)"
        return $false
    }
    return $true
}

function Install-FieldIsoDriversOffline {
    param(
        [Parameter(Mandatory)][string]$ApplyDir,
        [Parameter(Mandatory)][string]$DriverRoot
    )
    if (-not (Test-Path -LiteralPath $ApplyDir)) {
        Write-FieldIsoLog "Offline driver inject skipped - apply dir missing: $ApplyDir"
        return $false
    }
    Write-FieldIsoLog "DISM /Add-Driver -> offline image $ApplyDir"
    & dism /English /Image:$ApplyDir /Add-Driver /Driver:$DriverRoot /Recurse 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-FieldIsoLog "DISM /Add-Driver failed (exit $(Format-FieldIsoNativeExitCode $LASTEXITCODE))"
        return $false
    }
    Write-FieldIsoLog 'Offline driver inject completed.'
    return $true
}

function Get-FieldIsoVirtioWinRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:FIELDISO_VIRTIO_ROOT) {
        [void]$candidates.Add($env:FIELDISO_VIRTIO_ROOT.Trim().TrimEnd('\'))
    }
    foreach ($letter in @('D', 'E', 'F', 'G', 'H')) {
        $root = "${letter}:\"
        if (Test-Path -LiteralPath $root) {
            [void]$candidates.Add($root.TrimEnd('\'))
        }
    }
    foreach ($root in @($candidates | Select-Object -Unique)) {
        $netKvm = Join-Path $root 'NetKVM\w11\amd64\netkvm.inf'
        $viostor = Join-Path $root 'amd64\w11\viostor.inf'
        $vioscsi = Join-Path $root 'vioscsi\w11\amd64\vioscsi.inf'
        if ((Test-Path -LiteralPath $netKvm) -or (Test-Path -LiteralPath $viostor) -or (Test-Path -LiteralPath $vioscsi)) {
            return $root
        }
    }
    return $null
}

function Install-FieldIsoVirtioWinFromCd {
    param([string]$SevenZipPath)
    $root = Get-FieldIsoVirtioWinRoot
    if (-not $root) { return $null }
    Write-FieldIsoLog "VirtIO-win CD detected at $root - loading WinPE drivers..."
    & pnputil /add-driver (Join-Path $root 'amd64\w11\*.inf') /subdirs /install 2>&1 | Out-Null
    & pnputil /add-driver (Join-Path $root 'vioscsi\w11\amd64\*.inf') /subdirs /install 2>&1 | Out-Null
    & pnputil /add-driver (Join-Path $root 'NetKVM\w11\amd64\*.inf') /subdirs /install 2>&1 | Out-Null
    & pnputil /add-driver (Join-Path $root 'Balloon\w11\amd64\*.inf') /subdirs /install 2>&1 | Out-Null
    Write-FieldIsoLog "VirtIO WinPE pnputil exit $LASTEXITCODE"
    return $root
}

function Install-FieldIsoVirtioWinOffline {
    param(
        [Parameter(Mandatory)][string]$ApplyDir,
        [AllowNull()][string]$VirtioRoot
    )
    if ([string]::IsNullOrWhiteSpace($VirtioRoot)) {
        $VirtioRoot = Get-FieldIsoVirtioWinRoot
    }
    if ([string]::IsNullOrWhiteSpace($VirtioRoot)) {
        Write-FieldIsoLog 'VirtIO offline inject skipped - attach virtio-win ISO as 2nd CD (FIELDISO_VIRTIO_ROOT).'
        return $false
    }
    $driverRoots = @(
        (Join-Path $VirtioRoot 'amd64\w11')
        (Join-Path $VirtioRoot 'vioscsi\w11\amd64')
        (Join-Path $VirtioRoot 'NetKVM\w11\amd64')
        (Join-Path $VirtioRoot 'Balloon\w11\amd64')
        (Join-Path $VirtioRoot 'pvpanic\w11\amd64')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($driverRoots.Count -eq 0) {
        Write-FieldIsoLog "VirtIO offline inject skipped - no Win11 driver folders under $VirtioRoot"
        return $false
    }
    Write-FieldIsoLog "VirtIO offline inject from $VirtioRoot -> $ApplyDir (Proxmox/QEMU boot requirement)"
    $ok = $true
    foreach ($driverRoot in $driverRoots) {
        if (-not (Install-FieldIsoDriversOffline -ApplyDir $ApplyDir -DriverRoot $driverRoot)) {
            $ok = $false
        }
    }
    if ($ok) {
        Write-FieldIsoLog 'VirtIO offline inject completed.'
    }
    return $ok
}

function Install-FieldIsoOobdDrivers {
    param(
        [Parameter(Mandatory)][string]$HttpBase,
        [string]$CurlPath,
        [string]$SevenZipPath,
        [string]$ApplyDir
    )
    if (-not $SevenZipPath) {
        Write-FieldIsoLog 'OOBD drivers skipped - 7z.exe not available in WinPE.'
        return
    }
    $indexUrl = Join-FieldIsoHttpUrl -HttpBase $HttpBase -RelPath 'drivers/index.json'
    $workDir = Get-FieldIsoWorkDir
    $indexLocal = Join-Path $workDir 'drivers-index.json'
    Write-FieldIsoLog 'Fetching OOBD driver index...'
    if (-not (Invoke-FieldIsoCurl -Url $indexUrl -OutFile $indexLocal -CurlPath $CurlPath)) {
        Write-FieldIsoLog 'OOBD driver index download failed - continuing without drivers.'
        return
    }
    try {
        $index = Get-Content -LiteralPath $indexLocal -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-FieldIsoLog "OOBD driver index parse failed - $($_.Exception.Message)"
        return
    }

    $wmiModel = Get-FieldIsoWmiModel
    if ($wmiModel) {
        Write-FieldIsoLog "WMI model: $wmiModel"
    } else {
        Write-FieldIsoLog 'WMI model: unknown'
    }
    $entry = Get-FieldIsoDriverEntryWithDefault -IndexDoc $index -WmiModel $wmiModel
    if (-not $entry) {
        if ($wmiModel) {
            Write-FieldIsoLog 'No OOBD pack matched WMI model and Drivers/_default/ has no archive on PXE host.'
        } else {
            Write-FieldIsoLog 'WMI model unknown - Drivers/_default/ has no archive on PXE host (copy a .cab/.exe/.7z there, Start field PXE).'
        }
        Write-FieldIsoLog 'Injected drivers (if any) are already installed - continuing without OOBD pack.'
        return
    }
    Write-FieldIsoLog "OOBD match: $(Get-FieldIsoEntryProp -Entry $entry -Name 'vendor')/$(Get-FieldIsoEntryProp -Entry $entry -Name 'folder') -> $(Get-FieldIsoEntryProp -Entry $entry -Name 'archive')"

    $entryRelPath = [string](Get-FieldIsoEntryProp -Entry $entry -Name 'relPath')
    $entryArchive = [string](Get-FieldIsoEntryProp -Entry $entry -Name 'archive')
    $packRel = "$entryRelPath/$entryArchive"
    $packUrl = Join-FieldIsoHttpUrl -HttpBase $HttpBase -RelPath $packRel
    $packLocal = Join-Path $workDir $entryArchive
    Write-FieldIsoLog 'Downloading OOBD driver pack...'
    if (-not (Invoke-FieldIsoCurl -Url $packUrl -OutFile $packLocal -CurlPath $CurlPath)) {
        Write-FieldIsoLog 'OOBD driver pack download failed.'
        return
    }

    $extractDir = Join-Path $workDir 'drivers'
    if (-not (Expand-FieldIsoDriverPack -PackPath $packLocal -DestDir $extractDir -SevenZipPath $SevenZipPath)) {
        return
    }
    if (-not (Test-FieldIsoDriverInfPresent -Root $extractDir)) {
        Write-FieldIsoLog 'No .inf files after extract - pack may be empty or corrupt.'
        return
    }
    if ($ApplyDir -and (Test-Path -LiteralPath $ApplyDir)) {
        Install-FieldIsoDriversOffline -ApplyDir $ApplyDir -DriverRoot $extractDir | Out-Null
    } else {
        Write-FieldIsoLog 'Installing OOBD drivers into running WinPE only (no apply dir for offline inject)...'
        & pnputil /add-driver (Join-Path $extractDir '*.inf') /subdirs /install 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-FieldIsoLog "pnputil exit $LASTEXITCODE"
        } else {
            Write-FieldIsoLog 'OOBD driver install completed (WinPE session).'
        }
    }
}

function Invoke-FieldIsoDismApplyFromIsoRoot {
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [string]$ApplyDir
    )
    $wim = Join-Path $IsoRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) {
        Write-FieldIsoLog 'Legacy ISO-root apply skipped - use install.wim URL + DISM apply.'
        return $false
    }
    if (-not $ApplyDir) {
        Write-FieldIsoLog 'DISM /Apply-Image skipped - set FIELDISO_APPLY_DIR (e.g. W:\) to apply install.wim.'
        return $false
    }
    if (-not (Test-Path -LiteralPath $ApplyDir)) {
        Write-FieldIsoLog "Apply dir missing: $ApplyDir"
        return $false
    }
    Write-FieldIsoLog "DISM /Apply-Image index 1 -> $ApplyDir"
    & dism /Apply-Image /ImageFile:$wim /Index:1 /ApplyDir:$ApplyDir /CheckIntegrity /Verify 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-FieldIsoLog "DISM /Apply-Image failed (exit $LASTEXITCODE)"
        return $false
    }
    Write-FieldIsoLog 'DISM /Apply-Image completed.'
    return $true
}

# --- main ---
$FieldIsoRunVersion = '2026-06-24-v14'
$script:FieldIsoBootstrapOk = $false
$curl = $null
$sevenZip = $null
Write-FieldIsoLog "HTTP bootstrap starting (run.ps1 $FieldIsoRunVersion)"

$isoUrl = Read-FieldIsoOneLineFile -Path (Join-Path $env:SystemRoot 'System32\iso.url')
$installWimUrlFile = Read-FieldIsoOneLineFile -Path (Join-Path $env:SystemRoot 'System32\install.wim.url')
$httpBase = Read-FieldIsoOneLineFile -Path (Join-Path $env:SystemRoot 'System32\fieldiso.url')

if (-not $isoUrl -and -not $installWimUrlFile) {
    Stop-FieldIsoBootstrap 'No iso.url or install.wim.url - pick an ISO from the WinDeployKit boot ISO catalog.'
}
if (-not $httpBase) {
    Stop-FieldIsoBootstrap 'No fieldiso.url (http_base) - regenerate PXE menus (Start field PXE).'
}

if ($isoUrl) {
    Write-FieldIsoLog "ISO URL (catalog): $isoUrl"
}
Write-FieldIsoLog "HTTP base: $httpBase"

$curl = Ensure-FieldIsoTool -Name 'curl.exe' -HttpBase $httpBase -CandidateRelPaths @(
    'System32\curl.exe'
    'Temp\fieldiso\tools\curl.exe'
)
$sevenZip = Ensure-FieldIsoTool -Name '7z.exe' -HttpBase $httpBase -CandidateRelPaths @(
    'System32\7z.exe'
    'Temp\fieldiso\tools\7z.exe'
)

try {
    $null = Install-FieldIsoInjectedDrivers
    Write-FieldIsoDiskInventory
    $virtioRoot = Install-FieldIsoVirtioWinFromCd -SevenZipPath $sevenZip

    $installWimUrl = Resolve-FieldIsoInstallWimUrl -InstallWimUrlFile $installWimUrlFile -IsoUrl $isoUrl
    if ([string]::IsNullOrWhiteSpace($installWimUrl)) {
        Stop-FieldIsoBootstrap 'Could not resolve install.wim URL - add http/iso-wim/<iso>/install.wim on PXE host and Start field PXE.'
    }

    $imageIndex = 1
    if ($env:FIELDISO_IMAGE_INDEX) {
        $parsed = 0
        if ([int]::TryParse([string]$env:FIELDISO_IMAGE_INDEX, [ref]$parsed) -and $parsed -gt 0) {
            $imageIndex = $parsed
        }
    }

    $applyDir = [string](Invoke-FieldIsoApplyInstallWim -InstallWimUrl $installWimUrl -CurlPath $curl -ImageIndex $imageIndex)
    Write-FieldIsoLog "Image applied to $applyDir"

    try {
        Install-FieldIsoOobdDrivers -HttpBase $httpBase -CurlPath $curl -SevenZipPath $sevenZip -ApplyDir $applyDir
    } catch {
        Write-FieldIsoLog "OOBD drivers skipped due to error: $($_.Exception.Message)"
    }

    if (Test-FieldIsoQemuVirtualMachine) {
        if (-not $virtioRoot) {
            $virtioRoot = Get-FieldIsoVirtioWinRoot
        }
        try {
            if (-not (Install-FieldIsoVirtioWinOffline -ApplyDir $applyDir -VirtioRoot $virtioRoot)) {
                Write-FieldIsoLog 'WARNING: VirtIO offline inject incomplete - attach virtio-win ISO; Proxmox VirtIO SCSI needs vioscsi.'
            }
        } catch {
            Write-FieldIsoLog "VirtIO offline inject error: $($_.Exception.Message)"
        }

        $efiLetter = Resolve-FieldIsoEfiLetter
        if ([string]::IsNullOrWhiteSpace($efiLetter)) {
            Stop-FieldIsoBootstrap 'UEFI VM needs EFI System Partition (S:) - disk prep failed. Re-run imaging (disk is re-partitioned on each QEMU boot).'
        }
        if (-not (Install-FieldIsoUefiBootFiles -ApplyDir $applyDir -EfiLetter $efiLetter)) {
            Stop-FieldIsoBootstrap "bcdboot failed on EFI ${efiLetter}: - Windows will not boot (BdsDxe Not Found). Check WinPE log."
        }
    } elseif ($script:FieldIsoAutoPreppedVolume) {
        Install-FieldIsoUefiBootFiles -ApplyDir $applyDir | Out-Null
    }

    $script:FieldIsoBootstrapOk = $true
    Write-FieldIsoLog 'Bootstrap complete - Windows image applied via DISM (no httpdisk).'
    if (Test-FieldIsoQemuVirtualMachine) {
        Write-FieldIsoLog 'Proxmox/QEMU: set boot order to virtio disk first, detach ISO, then reboot (not PXE).'
    }
} catch {
    $detail = $_.Exception.Message
    if ($_.ScriptStackTrace) {
        $detail = "$detail | $($_.ScriptStackTrace)"
    }
    Stop-FieldIsoBootstrap "Imaging stopped - unhandled error: $detail"
}

if (-not $script:FieldIsoBootstrapOk) {
    Stop-FieldIsoBootstrap 'Imaging stopped - bootstrap did not finish successfully.'
}

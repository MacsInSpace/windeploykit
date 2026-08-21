#requires -Version 5.1
<#
.SYNOPSIS
    Bake VirtIO storage drivers (vioscsi + viostor) into a WinPE boot image so it can SEE a
    Proxmox / QEMU VirtIO disk during imaging. Works on FieldIso.wim or ImageDeployer.wim.

.DESCRIPTION
    WinPE shows "There are no fixed disks to show" on a Proxmox VirtIO disk because the boot
    image has no VirtIO storage driver. This adds them offline with DISM so the disk is visible
    immediately on boot (no live `drvload`, no SATA fallback).

    - vioscsi -> VirtIO SCSI controller (q35 default, scsi0 on virtio-scsi)
    - viostor -> VirtIO Block device     (virtio0)
    Both are added by default so the WIM works regardless of the disk bus.

    WINDOWS ONLY: offline driver servicing requires DISM. macOS wimlib can copy files into a WIM
    but cannot register a driver. Run this on a Windows box (Admin): copy the WIM over from the
    Mac's PXE store (.../pxe-boot/http/wim/FieldIso.wim), bake, copy it back, then Start field PXE.

    NOTE: this services the BOOT image (so WinPE sees the disk). It is separate from the OOBD
    pack (scripts/build-virtio-win-fieldiso-pack.ps1), which drivers the DEPLOYED Windows so it
    boots afterwards. For a Proxmox lab you generally want both.

.PARAMETER WimPath
    Path to the WinPE WIM to service (FieldIso.wim or ImageDeployer.wim).

.PARAMETER VirtioWinIso
    Path to a virtio-win-*.iso. It is mounted read-only and dismounted when done.

.PARAMETER VirtioWinRoot
    Path to an already-mounted / extracted virtio-win root (use instead of -VirtioWinIso).

.PARAMETER Index
    WIM image index to service. Default 1 (both FieldIso.wim and ImageDeployer.wim are single-image).

.PARAMETER OsFlavor
    virtio-win OS subfolder. Default 'w11' (WinPE 11 / Win11). Use 'w10', '2k22', '2k25', etc.

.PARAMETER Arch
    Architecture subfolder. Default 'amd64'.

.PARAMETER Drivers
    Which virtio driver folders to add. Default vioscsi,viostor. Add e.g. NetKVM for networking.

.PARAMETER NoBackup
    Skip the automatic <wim>.bak-<timestamp> copy taken before servicing.

.EXAMPLE
    .\scripts\add-virtio-drivers-to-winpe-wim.ps1 -WimPath C:\pxe\FieldIso.wim -VirtioWinIso C:\iso\virtio-win-0.1.285.iso

.EXAMPLE
    .\scripts\add-virtio-drivers-to-winpe-wim.ps1 -WimPath C:\pxe\ImageDeployer.wim -VirtioWinRoot E:\ -Drivers vioscsi,viostor,NetKVM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WimPath,
    [string] $VirtioWinIso,
    [string] $VirtioWinRoot,
    [int]    $Index = 1,
    [string] $OsFlavor = 'w11',
    [string] $Arch = 'amd64',
    [string[]] $Drivers = @('vioscsi', 'viostor'),
    [switch] $NoBackup
)

$ErrorActionPreference = 'Stop'

# --- Guards ---------------------------------------------------------------------------------
$onWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
if (-not $onWindows) {
    throw "Windows only: offline driver servicing needs DISM. Copy the WIM to a Windows box and run this there (Admin)."
}
if (-not (Get-Command Mount-WindowsImage -ErrorAction SilentlyContinue)) {
    throw "The DISM PowerShell module is unavailable. Run on Windows with the ADK / inbox Dism module present."
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Run this in an elevated (Administrator) PowerShell - DISM mount/commit requires it."
}
if (-not (Test-Path -LiteralPath $WimPath)) {
    throw "WIM not found: $WimPath"
}
$WimPath = (Resolve-Path -LiteralPath $WimPath).Path

# --- Resolve the virtio-win root (mount the ISO if needed) ----------------------------------
$mountedIso = $null
try {
    if ($VirtioWinRoot) {
        $virtioRoot = (Resolve-Path -LiteralPath $VirtioWinRoot).Path
    } elseif ($VirtioWinIso) {
        $VirtioWinIso = (Resolve-Path -LiteralPath $VirtioWinIso).Path
        Write-Host "Mounting $VirtioWinIso ..." -ForegroundColor DarkGray
        $mountedIso = Mount-DiskImage -ImagePath $VirtioWinIso -PassThru
        Start-Sleep -Milliseconds 800
        $letter = ($mountedIso | Get-Volume | Where-Object DriveLetter).DriveLetter | Select-Object -First 1
        if (-not $letter) { throw "Mounted virtio-win ISO but no drive letter was assigned." }
        $virtioRoot = "$($letter):\"
    } else {
        throw "Pass -VirtioWinIso <path> or -VirtioWinRoot <mounted path>."
    }
    Write-Host "virtio-win root: $virtioRoot" -ForegroundColor DarkGray

    # --- Locate each requested driver folder ------------------------------------------------
    $driverFolders = [System.Collections.Generic.List[string]]::new()
    foreach ($drv in $Drivers) {
        $candidate = Join-Path $virtioRoot (Join-Path $drv (Join-Path $OsFlavor $Arch))
        if (Test-Path -LiteralPath $candidate) {
            [void]$driverFolders.Add((Resolve-Path -LiteralPath $candidate).Path)
            continue
        }
        # Fallback: recursive search for <driver>.inf (handles non-canonical layouts).
        $inf = Get-ChildItem -LiteralPath $virtioRoot -Recurse -Filter "$drv.inf" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "(?i)\\$([regex]::Escape($OsFlavor))\\" -and $_.FullName -match "(?i)\\$([regex]::Escape($Arch))\\" } |
            Select-Object -First 1
        if ($inf) {
            [void]$driverFolders.Add($inf.DirectoryName)
        } else {
            Write-Warning "Could not find driver '$drv' for $OsFlavor/$Arch under $virtioRoot - skipping."
        }
    }
    if ($driverFolders.Count -eq 0) {
        throw "No driver folders resolved. Check -OsFlavor/-Arch and the virtio-win layout (e.g. \vioscsi\w11\amd64)."
    }

    # --- Backup ------------------------------------------------------------------------------
    if (-not $NoBackup) {
        $bak = "$WimPath.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -LiteralPath $WimPath -Destination $bak -Force
        Write-Host "Backup: $bak" -ForegroundColor DarkGray
    }

    # --- Mount, add drivers, commit ----------------------------------------------------------
    $mountDir = Join-Path ([IO.Path]::GetTempPath()) ("windeploykit-wim-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $mountDir -Force
    $committed = $false
    try {
        Write-Host "Mounting image index $Index of $WimPath ..." -ForegroundColor Cyan
        $null = Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $mountDir
        foreach ($folder in $driverFolders) {
            Write-Host "  + Add-Driver $folder" -ForegroundColor Green
            $null = Add-WindowsDriver -Path $mountDir -Driver $folder -Recurse -ForceUnsigned
        }
        Write-Host "Committing (saving) image ..." -ForegroundColor Cyan
        $null = Dismount-WindowsImage -Path $mountDir -Save
        $committed = $true
    } finally {
        if (-not $committed) {
            Write-Warning "Servicing failed - discarding changes so the WIM is left intact."
            try { $null = Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue } catch { }
        }
        Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host "Done. Baked $($driverFolders.Count) driver(s) into $WimPath (index $Index)." -ForegroundColor Green
    Write-Host "Verify:  Get-WindowsImageDriver -ImagePath `"$WimPath`" -Index $Index | ? Driver -match 'vio'" -ForegroundColor DarkGray
    Write-Host "Next:    copy the WIM back to the Mac PXE store and Stop -> Start Imaging Services." -ForegroundColor DarkGray
}
finally {
    if ($mountedIso) {
        try { Dismount-DiskImage -ImagePath $mountedIso.ImagePath -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

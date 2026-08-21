# Optional local-machine administrator credential (this Mac / this PC).
# Stored as PSCredential via Export-Clixml - same DPAPI / user-only semantics as infrastructure-ssh.
#
# Host-side: macOS sudo elevation (TFTP port 69, sharing -a/-r, routes) without re-prompting.
# Client-side: when Site Build (or similar) exports an SMB share, Windows/Linux clients often need
# this machine's local admin username + password - the login name is surfaced on share status;
# password stays in vault (same entry technicians save here).
# Windows host elevation: stored for future workflows; SMB share creation uses current token when admin.

# Canonical data-root resolvers (no-op when the sidecar already dot-sourced AppPaths.ps1;
# needed when dev/test scripts dot-source this lib standalone).
if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

$script:AppLocalMachineCredentialId = 'local-admin'

function Get-AppLocalMachineCredentialStoreRoot {
    Get-AppPluginDir -Plugin 'local-machine'
}

function Get-AppLocalMachineCredentialMetaPath {
    Join-Path (Get-AppLocalMachineCredentialStoreRoot) 'meta.json'
}

function Get-AppLocalMachineCredentialClixmlPath {
    Join-Path (Get-AppLocalMachineCredentialStoreRoot) "$($script:AppLocalMachineCredentialId).xml"
}

function Read-AppLocalMachineCredentialMeta {
    $path = Get-AppLocalMachineCredentialMetaPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        Write-SidecarLog "Local machine credential meta read failed: $($_.Exception.Message)"
        return $null
    }
}

function Write-AppLocalMachineCredentialMeta {
    param(
        [Parameter(Mandatory)][string]$LoginName,
        [switch]$ClearPassword
    )
    $platform = if ($IsMacOS -or $IsDarwin) { 'macos' } elseif ($IsWindows -or ($env:OS -eq 'Windows_NT')) { 'windows' } else { 'unknown' }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $meta = [ordered]@{
        id        = $script:AppLocalMachineCredentialId
        loginName = $LoginName.Trim()
        updatedAt = $now
        platform  = $platform
        configured = -not $ClearPassword
    }
    ($meta | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Get-AppLocalMachineCredentialMetaPath) -Encoding UTF8 -Force
}

function Test-AppLocalMachineCredentialConfigured {
    $clixml = Get-AppLocalMachineCredentialClixmlPath
    if (-not (Test-Path -LiteralPath $clixml)) { return $false }
    $meta = Read-AppLocalMachineCredentialMeta
    if (-not $meta) { return $true }
    if ($meta.PSObject.Properties['configured'] -and -not [bool]$meta.configured) { return $false }
    return $true
}

function Get-AppLocalMachineCredentialLoginName {
    $meta = Read-AppLocalMachineCredentialMeta
    if ($meta -and $meta.loginName) {
        return [string]$meta.loginName
    }
    if (Get-Command Get-AppMacOsAdminUserName -ErrorAction SilentlyContinue) {
        return Get-AppMacOsAdminUserName
    }
    return [string]$env:USER
}

function Get-AppLocalMachineCredentialSecure {
    if (-not (Test-AppLocalMachineCredentialConfigured)) { return $null }
    $path = Get-AppLocalMachineCredentialClixmlPath
    try {
        $cred = Import-Clixml -LiteralPath $path
        if (-not $cred -or -not $cred.Password) { return $null }
        return @{
            LoginName      = Get-AppLocalMachineCredentialLoginName
            SecurePassword = $cred.Password
        }
    } catch {
        Write-SidecarLog "Local machine credential read failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-AppLocalMachineCredentialStatus {
    $configured = Test-AppLocalMachineCredentialConfigured
    $meta = Read-AppLocalMachineCredentialMeta
    $sessionCached = $false
    if (Get-Command Get-AppMacOsAdminCredentialCacheStatus -ErrorAction SilentlyContinue) {
        $sessionCached = [bool](Get-AppMacOsAdminCredentialCacheStatus).cached
    }
    $platformMeta = if ($IsMacOS -or $IsDarwin) { 'macos' } elseif ($IsWindows -or ($env:OS -eq 'Windows_NT')) { 'windows' } else { 'unknown' }
    @{
        id             = $script:AppLocalMachineCredentialId
        label          = 'Local administrator (this computer)'
        loginName      = if ($meta -and $meta.loginName) { [string]$meta.loginName } else { Get-AppLocalMachineCredentialLoginName }
        configured     = [bool]$configured
        storePath      = Get-AppLocalMachineCredentialStoreRoot
        updatedAt      = if ($meta -and $meta.updatedAt) { [string]$meta.updatedAt } else { $null }
        platform       = if ($meta -and $meta.platform) { [string]$meta.platform } else { $platformMeta }
        sessionCached  = $sessionCached
        wiredForMacOs  = ($IsMacOS -or $IsDarwin)
        wiredForWindows = ($IsWindows -or ($env:OS -eq 'Windows_NT'))
    }
}

function Save-AppLocalMachineCredential {
    param(
        [Parameter(Mandatory)][string]$LoginName,
        [string]$PlainPassword
    )
    $loginTrim = $LoginName.Trim()
    if ([string]::IsNullOrWhiteSpace($loginTrim)) {
        throw 'Local machine credential: login name is required.'
    }

    $path = Get-AppLocalMachineCredentialClixmlPath
    if (-not [string]::IsNullOrWhiteSpace($PlainPassword)) {
        $secure = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force
        $cred = [PSCredential]::new("local@$($script:AppLocalMachineCredentialId)", $secure)
        $cred | Export-Clixml -LiteralPath $path -Force -ErrorAction Stop
        Write-AppLocalMachineCredentialMeta -LoginName $loginTrim
    } elseif (-not (Test-Path -LiteralPath $path)) {
        throw 'Local machine credential: password is required on first save.'
    } else {
        Write-AppLocalMachineCredentialMeta -LoginName $loginTrim
    }

    Import-AppLocalMachineCredentialToMacOsAdminCache | Out-Null
    Write-SidecarLog "Local machine credential saved for login=$loginTrim"
    Get-AppLocalMachineCredentialStatus
}

function Clear-AppLocalMachineCredentialPassword {
    $path = Get-AppLocalMachineCredentialClixmlPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $login = Get-AppLocalMachineCredentialLoginName
    Write-AppLocalMachineCredentialMeta -LoginName $login -ClearPassword
    if (Get-Command Clear-AppMacOsAdminCredentialCache -ErrorAction SilentlyContinue) {
        Clear-AppMacOsAdminCredentialCache
    }
    Write-SidecarLog 'Local machine credential password cleared'
    Get-AppLocalMachineCredentialStatus
}

function Import-AppLocalMachineCredentialToMacOsAdminCache {
    if (-not (Get-Command Set-AppMacOsAdminCredentialCache -ErrorAction SilentlyContinue)) {
        return $false
    }
    $fromVault = Get-AppLocalMachineCredentialSecure
    if (-not $fromVault) { return $false }
    Set-AppMacOsAdminCredentialCache -SecurePassword $fromVault.SecurePassword -UserName $fromVault.LoginName
    Write-SidecarLog 'Local machine credential loaded into macOS admin session cache'
    return $true
}

function Resolve-AppMacOsAdminCredentialFromVaultOrPrompt {
    if (Get-Command Get-AppMacOsAdminCredentialCacheStatus -ErrorAction SilentlyContinue) {
        if ((Get-AppMacOsAdminCredentialCacheStatus).cached) {
            return $true
        }
    }
    if (Import-AppLocalMachineCredentialToMacOsAdminCache) {
        return $true
    }
    return $false
}

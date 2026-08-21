# Infrastructure SSH credential vault (switch / gear passwords).
#
# Passwords are stored as PSCredential via Export-Clixml — same approach as
# StoredCredentials.xml: DPAPI on Windows; user-readable-only on macOS/Linux.
#
# Stored under plugins/infrastructure-ssh/ beneath the canonical app data root
# (see AppPaths.ps1).
#
# Plain JSON index (labels only); one Clixml file per credential id.

# Canonical data-root resolvers (no-op when the sidecar already dot-sourced AppPaths.ps1;
# needed when dev/test scripts dot-source this lib standalone).
if (-not (Get-Command Get-AppDataRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'AppPaths.ps1')
}

function Get-AppInfraSshStoreRoot {
    Get-AppPluginDir -Plugin 'infrastructure-ssh'
}

function Get-AppInfraSshIndexPath {
    Join-Path (Get-AppInfraSshStoreRoot) 'index.json'
}

function Read-AppInfraSshIndex {
    $path = Get-AppInfraSshIndexPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $items = $raw | ConvertFrom-Json
        if ($null -eq $items) { return @() }
        @($items)
    } catch {
        Write-SidecarLog "Infra SSH index read failed: $($_.Exception.Message)"
        @()
    }
}

function Write-AppInfraSshIndex {
    param([Parameter(Mandatory)]$Items)
    $path = Get-AppInfraSshIndexPath
    $json = $Items | ConvertTo-Json -Compress
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force -ErrorAction Stop
}

# Virtual credential id for the app's signed-in DE account. It never touches the
# on-disk store: the list handler advertises it and the two by-id resolvers below
# answer it from the in-memory sign-in credential, so every credential dropdown can
# offer the DE account without the technician re-entering it into the vault.
$script:AppInfraSshDeSignInCredentialId = 'app-de-signin'

function Get-AppInfraSshDeSignInCredential {
    # TODO(Site Profile): no ambient signed-in credential in WinDeployKit — callers
    # supply credentials explicitly or use the stored credential vault.
    return $null
}

function Get-AppInfraSshDeSignInSummary {
    <# Virtual list entry for the signed-in DE account — null when not signed in. #>
    $de = Get-AppInfraSshDeSignInCredential
    if (-not $de -or [string]::IsNullOrWhiteSpace([string]$de.UserName)) { return $null }
    @{
        id         = $script:AppInfraSshDeSignInCredentialId
        label      = 'Signed-in DE account'
        loginName  = [string]$de.UserName
        configured = $true
        builtIn    = $true
    }
}

function Normalize-AppInfraSshCredentialId {
    param([Parameter(Mandatory)][string]$Id)
    $safe = ($Id.Trim() -replace '[^\w\-]', '')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'Invalid infrastructure SSH credential id.'
    }
    $safe
}

function Get-AppInfraSshCredentialPath {
    param([Parameter(Mandatory)][string]$Id)
    $safe = Normalize-AppInfraSshCredentialId -Id $Id
    Join-Path (Get-AppInfraSshStoreRoot) "$safe.xml"
}

function Test-AppInfraSshCredentialExists {
    param([Parameter(Mandatory)][string]$Id)
    Test-Path -LiteralPath (Get-AppInfraSshCredentialPath -Id $Id)
}

function Get-AppInfraSshPlainPassword {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq $script:AppInfraSshDeSignInCredentialId) {
        $de = Get-AppInfraSshDeSignInCredential
        if (-not $de -or -not $de.Password) { return $null }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($de.Password)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $path = Get-AppInfraSshCredentialPath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $cred = Import-Clixml -LiteralPath $path
        if (-not $cred -or -not $cred.Password) { return $null }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr).TrimEnd([char]13, [char]10)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        Write-SidecarLog "Infra SSH cred read failed for $Id`: $($_.Exception.Message)"
        return $null
    }
}

function Test-AppInfraSshDefaultCredentialId {
    param([Parameter(Mandatory)][string]$Id)
    $safe = Normalize-AppInfraSshCredentialId -Id $Id
    return $safe -match '^default-.+-admin$'
}

function Get-AppInfraSshDefaultCredentialSpecs {
    <#
        One generic per-site default, used for devices with no explicit credential
        assignment. The upstream original seeded two org-issued accounts derived
        from a site-id naming convention; WinDeployKit has no such convention, so the
        technician names the account and supplies the password. Never seed a password
        here - see AGENT_NOTES.md section 5.
    #>
    param([Parameter(Mandatory)][string]$SiteId)
    $site = $SiteId.Trim()
    @(
        [PSCustomObject]@{
            id    = "default-$site-admin"
            label = "$site admin"
        }
    )
}

function Get-AppInfraSshIndexProp {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name
    )
    # NpsLogViewer enables Set-StrictMode; JSON index rows may omit optional keys.
    if (-not $Item) { return $null }
    if (-not ($Item.PSObject.Properties.Name -contains $Name)) { return $null }
    return $Item.$Name
}

function Get-AppInfraSshCredentialLoginName {
    param(
        $Item,
        [Parameter(Mandatory)][string]$SafeId,
        [string]$Label
    )
    $rawLogin = Get-AppInfraSshIndexProp -Item $Item -Name 'loginName'
    if (-not [string]::IsNullOrWhiteSpace([string]$rawLogin)) {
        return ([string]$rawLogin).Trim()
    }
    $labelText = if ($Item) { [string](Get-AppInfraSshIndexProp -Item $Item -Name 'label') } else { $Label }
    if (-not [string]::IsNullOrWhiteSpace($labelText)) {
        return $labelText.Trim()
    }
    return $null
}

function Get-AppInfraSshCredentialLoginNameById {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq $script:AppInfraSshDeSignInCredentialId) {
        $de = Get-AppInfraSshDeSignInCredential
        if ($de) { return [string]$de.UserName }
        return $null
    }
    $safeId = Normalize-AppInfraSshCredentialId -Id $Id
    $item = @(Read-AppInfraSshIndex) | Where-Object { [string]$_.id -eq $safeId } | Select-Object -First 1
    Get-AppInfraSshCredentialLoginName -Item $item -SafeId $safeId -Label ([string]$item.label)
}

function Get-AppInfraSshCredentialSiteId {
    param(
        $Item,
        [Parameter(Mandatory)][string]$SafeId
    )
    $raw = Get-AppInfraSshIndexProp -Item $Item -Name 'siteId'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
        return ([string]$raw).Trim()
    }
    if ($SafeId -match '^default-(.+)-admin$') {
        return $Matches[1]
    }
    return $null
}

function Ensure-AppInfraSshDefaultCredentials {
    param([Parameter(Mandatory)][string]$SiteId)
    $sn = $SiteId.Trim()
    $specs = Get-AppInfraSshDefaultCredentialSpecs -SiteId $sn
    $index = @(Read-AppInfraSshIndex)
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $changed = $false
    foreach ($spec in $specs) {
        $match = $index | Where-Object { [string]$_.id -eq $spec.id } | Select-Object -First 1
        if (-not $match) {
            $index += [PSCustomObject]@{
                id           = [string]$spec.id
                label        = [string]$spec.label
                loginName    = [string]$spec.label
                updatedAt    = $now
                isDefault    = $true
                siteId = $sn
            }
            $changed = $true
        } elseif ([string]::IsNullOrWhiteSpace([string](Get-AppInfraSshIndexProp -Item $match -Name 'siteId'))) {
            $index = foreach ($item in $index) {
                if ([string]$item.id -eq $spec.id) {
                    $itemUpdatedAt = Get-AppInfraSshIndexProp -Item $item -Name 'updatedAt'
                    $itemLogin = Get-AppInfraSshIndexProp -Item $item -Name 'loginName'
                    if ([string]::IsNullOrWhiteSpace([string]$itemLogin)) { $itemLogin = [string]$item.label }
                    [PSCustomObject]@{
                        id           = [string]$item.id
                        label        = [string]$item.label
                        loginName    = [string]$itemLogin
                        updatedAt    = if ($itemUpdatedAt) { [string]$itemUpdatedAt } else { $now }
                        isDefault    = $true
                        siteId = $sn
                    }
                } else {
                    $item
                }
            }
            $changed = $true
        }
    }
    if ($changed) {
        Write-AppInfraSshIndex -Items $index
        Write-SidecarLog "Infra SSH default credential index ensured for site $sn"
    }
}

function Clear-AppInfraSshCredentialPassword {
    param([Parameter(Mandatory)][string]$Id)
    $safeId = Normalize-AppInfraSshCredentialId -Id $Id
    $path = Get-AppInfraSshCredentialPath -Id $safeId
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        Write-SidecarLog "Infra SSH credential password cleared: $safeId"
    }
}

function Get-AppInfraSshCredentials {
    param([string]$SiteId)

    $filterSn = $null
    if (-not [string]::IsNullOrWhiteSpace($SiteId)) {
        $filterSn = $SiteId.Trim().PadLeft(4, '0')
    }

    $index = Read-AppInfraSshIndex
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $index) {
        $id = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        try {
            $safeId = Normalize-AppInfraSshCredentialId -Id $id
        } catch {
            continue
        }

        $credSn = Get-AppInfraSshCredentialSiteId -Item $item -SafeId $safeId
        if ($filterSn -and $credSn -ne $filterSn) { continue }

        $path = Get-AppInfraSshCredentialPath -Id $safeId
        $isDefault = $false
        $isDefaultProp = Get-AppInfraSshIndexProp -Item $item -Name 'isDefault'
        if ($null -ne $isDefaultProp) { $isDefault = [bool]$isDefaultProp }
        if (-not $isDefault) { $isDefault = Test-AppInfraSshDefaultCredentialId -Id $safeId }
        $out.Add([PSCustomObject]@{
            id           = $safeId
            label        = [string]$item.label
            loginName    = Get-AppInfraSshCredentialLoginName -Item $item -SafeId $safeId -Label ([string]$item.label)
            updatedAt    = [string](Get-AppInfraSshIndexProp -Item $item -Name 'updatedAt')
            configured   = (Test-Path -LiteralPath $path)
            isDefault    = $isDefault
            siteId = $credSn
        })
    }
    $out.ToArray()
}

function Save-AppInfraSshCredential {
    param(
        [string]$Id,
        [string]$SiteId,
        [Parameter(Mandatory)][string]$Label,
        [string]$PlainPassword,
        [string]$LoginName
    )
    $labelTrim = $Label.Trim()
    if ([string]::IsNullOrWhiteSpace($labelTrim)) {
        throw 'Infrastructure SSH credential label is required.'
    }

    $index = @(Read-AppInfraSshIndex)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        $Id = [guid]::NewGuid().ToString('n')
    }
    $safeId = Normalize-AppInfraSshCredentialId -Id $Id

    $credSn = $null
    if (Test-AppInfraSshDefaultCredentialId -Id $safeId) {
        $credSn = Get-AppInfraSshCredentialSiteId -Item $null -SafeId $safeId
    } elseif (-not [string]::IsNullOrWhiteSpace($SiteId)) {
        $credSn = $SiteId.Trim().PadLeft(4, '0')
    } else {
        $existing = $index | Where-Object { [string]$_.id -eq $safeId } | Select-Object -First 1
        if ($existing) {
            $credSn = Get-AppInfraSshCredentialSiteId -Item $existing -SafeId $safeId
        }
    }
    if (-not $credSn -and -not (Test-AppInfraSshDefaultCredentialId -Id $safeId)) {
        throw 'SetInfraSshCredential: siteId is required for site-specific credentials.'
    }

    $existing = $index | Where-Object { [string]$_.id -eq $safeId } | Select-Object -First 1
    $loginTrim = $null
    if (-not [string]::IsNullOrWhiteSpace($LoginName)) {
        $loginTrim = $LoginName.Trim()
    } elseif ($existing) {
        $loginTrim = Get-AppInfraSshCredentialLoginName -Item $existing -SafeId $safeId -Label $labelTrim
    } elseif (Test-AppInfraSshDefaultCredentialId -Id $safeId) {
        $loginTrim = $labelTrim
    }

    $path = Get-AppInfraSshCredentialPath -Id $safeId
    if (-not [string]::IsNullOrWhiteSpace($PlainPassword)) {
        $secure = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force
        $cred = [PSCredential]::new("infra@$safeId", $secure)
        $cred | Export-Clixml -LiteralPath $path -Force -ErrorAction Stop
    } elseif (-not (Test-Path -LiteralPath $path)) {
        throw 'Infrastructure SSH credential password is required.'
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $found = $false
    $next = foreach ($item in $index) {
        if ([string]$item.id -eq $safeId) {
            $found = $true
            $isDefault = $false
            $isDefaultProp = Get-AppInfraSshIndexProp -Item $item -Name 'isDefault'
            if ($null -ne $isDefaultProp) { $isDefault = [bool]$isDefaultProp }
            if (-not $isDefault) { $isDefault = Test-AppInfraSshDefaultCredentialId -Id $safeId }
            [PSCustomObject]@{
                id           = $safeId
                label        = $labelTrim
                loginName    = $loginTrim
                updatedAt    = $now
                isDefault    = [bool]$isDefault
                siteId = $credSn
            }
        } else {
            $item
        }
    }
    if (-not $found) {
        $next = @($next) + [PSCustomObject]@{
            id           = $safeId
            label        = $labelTrim
            loginName    = $loginTrim
            updatedAt    = $now
            isDefault    = $false
            siteId = $credSn
        }
    }
    Write-AppInfraSshIndex -Items $next
    Write-SidecarLog "Infra credential saved: $labelTrim ($safeId) site=$credSn login=$loginTrim"
    [PSCustomObject]@{ id = $safeId; label = $labelTrim; loginName = $loginTrim; updatedAt = $now; siteId = $credSn }
}

function Remove-AppInfraSshCredential {
    param([Parameter(Mandatory)][string]$Id)
    $safeId = Normalize-AppInfraSshCredentialId -Id $Id
    if (Test-AppInfraSshDefaultCredentialId -Id $safeId) {
        throw 'Default site credentials cannot be deleted — clear the password instead.'
    }
    $path = Get-AppInfraSshCredentialPath -Id $safeId
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
    $index = @(Read-AppInfraSshIndex) | Where-Object { [string]$_.id -ne $safeId }
    Write-AppInfraSshIndex -Items $index
    Write-SidecarLog "Infra SSH credential removed: $safeId"
}

function Copy-AppInfraSshPasswordToClipboard {
    param([Parameter(Mandatory)][string]$Id)
    $plain = Get-AppInfraSshPlainPassword -Id $Id
    if ([string]::IsNullOrEmpty($plain)) { return $false }
    return Set-AppClipboardText -Text $plain
}

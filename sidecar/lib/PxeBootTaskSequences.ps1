# Netboot task sequences - MDT-style named deployments for the deploy client.
#
# Craig's real unattend templates (Client/Server) are embedded below with a split
# token model:
#   * publish-time tokens ({{JoinDomain}}, {{MachineOu}}, {{ProductKey}}, server
#     networking, {{LocalAdminPw}} from the Site Profile, and a
#     store-credential join's full {{JoinDom}}/{{JoinUser}}/{{JoinPw}} triplet) -
#     substituted HERE from each sequence's saved fields when the store syncs, so
#     what lands in <library>/TaskSequences/<id>.xml is concrete.
#   * deploy-time tokens ({{SITE}}, {{SERIAL}}, and for ambient-credential joins the
#     whole {{JoinDom}}/{{JoinUser}}/{{JoinPw}} triplet) - left intact in the
#     published file. the client fills them at deploy time
#     (site id, device serial, and the credentials typed for the share
#     connect - one coherent credential, never publisher identity + deployer
#     password). Join passwords therefore NEVER sit in a file on the share.
#
# The published files are served over the existing read-only Deploy$ share as
# Z:\TaskSequences\<id>.xml; the deploy client's Task Sequence picker lists them and
# copies the chosen one to <OS volume>\Windows\Panther\unattend.xml after apply -
# the standard first-boot (specialize + oobeSystem) mechanism. The windowsPE pass
# from the original hand-built files is omitted: it only runs under setup.exe,
# never for DISM-applied images. EULA-hiding removed per Craig (2026-08-19).

# Standalone-load shim: scripts dot-source lib subsets in any order, and this lib
# calls Test-AppSidecarCommand (the fast Get-Command). Full version in AppPaths.ps1;
# this fallback is plain Get-Command, correct just slower. Same pattern as the
# Write-SidecarLog no-op shims.
if (-not (Get-Command Test-AppSidecarCommand -ErrorAction SilentlyContinue)) {
    function Test-AppSidecarCommand {
        param([Parameter(Mandatory)][string]$Name)
        [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
}

$script:AppPxeBootTaskSequenceMaxCount = 8

function Get-AppPxeBootTaskSequencesPath {
    Join-Path (Get-AppPxeBootStoreRoot) 'task-sequences.json'
}

function Get-AppPxeBootTaskSequenceLibraryDir {
    # Published sequences live in the image library root (= Deploy$ share root) so
    # WinPE sees Z:\TaskSequences. Null when no library root is configured yet.
    try {
        $root = Get-AppImageLibraryRoot -NoCreate
        if ($root) { return (Join-Path $root 'TaskSequences') }
    } catch { }
    return $null
}

function Get-AppPxeBootTsProp {
    # StrictMode-tolerant property read for hydrated JSON objects.
    param($Item, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-AppPxeBootTaskSequenceDefaults {
    # Seeded menu. Steps are the editable/reorderable spec of what runs at first
    # boot (specialize RunSynchronous) - seeded here from Craig's RDP-enable and
    # GPO-disable sets, but plain data the panel can add to, remove, or reorder.
    # Empty productKey publishes the role default from the KMS catalog.
    $defaults = @(
        [ordered]@{
            id      = 'client-domain'
            name    = 'Client'
            kind    = 'client'
            enabled = $true
            fields  = [ordered]@{
                computerName = '{{SERIAL}}'
                network      = 'dhcp'
                ipCidr       = ''
                gateway      = ''
                dns1         = ''
                dns2         = ''
                dns3         = ''
                joinDomain   = ''
                joinCredential = ''
                machineOu    = ''
                productKey   = ''
                registeredOrg   = ''
                registeredOwner = ''
            }
            adminGroups = @()
            steps   = @(
                [ordered]@{ type = 'cmd'; description = 'Disable Windows Firewall'; command = 'netsh advfirewall set allprofiles state off' }
                [ordered]@{ type = 'reg'; description = 'Enable RDP'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'; name = 'fDenyTSConnections'; valueType = 'REG_DWORD'; data = '0' }
                [ordered]@{ type = 'cmd'; description = 'Allow RDP through Firewall'; command = 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes' }
                [ordered]@{ type = 'cmd'; description = 'Set RDP Service to Auto-Start'; command = 'sc config TermService start= auto' }
                # UserAuthentication=0 is what actually disables NLA (the original
                # template set SecurityLayer=2, which only forces TLS - the step's
                # description and effect disagreed; fixed 2026-08-20).
                [ordered]@{ type = 'reg'; description = 'Disable NLA (RDP before first sign-in)'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; name = 'UserAuthentication'; valueType = 'REG_DWORD'; data = '0' }
                [ordered]@{ type = 'reg'; description = 'Remove Legal Notice Caption'; op = 'delete'; path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; name = 'LegalNoticeCaption'; valueType = ''; data = '' }
            )
        }
        [ordered]@{
            id      = 'server-standard'
            name    = 'Server'
            kind    = 'server'
            enabled = $false
            fields  = [ordered]@{
                computerName = 'SVR01'
                # DHCP by default: a seeded sequence must be valid the moment it is enabled.
                # With 'static' and no address it enabled straight into "Fix fields to save",
                # which named no field (Craig, 2026-08-22). Static is still two dropdowns away.
                network      = 'dhcp'
                ipCidr       = ''
                gateway      = ''
                dns1         = ''
                dns2         = ''
                dns3         = ''
                joinDomain   = ''
                joinCredential = ''
                machineOu    = ''
                productKey   = ''
                registeredOrg   = ''
                registeredOwner = ''
            }
            adminGroups = @()
            steps   = @(
                # Craig's ServerBaseActivationandSettings.ps1 as editable steps.
                [ordered]@{ type = 'cmd'; description = 'Time server (time.windows.com)'; command = 'w32tm /config /syncfromflags:manual /manualpeerlist:time.windows.com & w32tm /config /reliable:yes & net stop w32time & net start w32time & w32tm /resync /force' }
                [ordered]@{ type = 'reg'; description = 'Enable RDP'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'; name = 'fDenyTSConnections'; valueType = 'REG_DWORD'; data = '0' }
                [ordered]@{ type = 'cmd'; description = 'Allow RDP through Firewall'; command = 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes' }
                [ordered]@{ type = 'cmd'; description = 'Create DisableGPOs Script'; command = 'mkdir C:\Windows\Setup\Scripts 2>nul & echo reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v DisableGPOs /t REG_DWORD /d 1 /f > C:\Windows\Setup\Scripts\DisableGPOs.cmd' }
                [ordered]@{ type = 'cmd'; description = 'Schedule DisableGPOs Script for Post-Domain Join'; command = 'schtasks /create /tn "DisableGPOs" /tr "C:\Windows\Setup\Scripts\DisableGPOs.cmd" /sc once /st 00:00 /rl highest /f' }
                [ordered]@{ type = 'reg'; description = 'Suppress OOBE product key prompt'; op = 'add'; path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE'; name = 'SetupDisplayedProductKey'; valueType = 'REG_DWORD'; data = '1' }
            )
        }
    )
    # Evaluation Center media installs as ServerStandardEval/ServerDatacenterEval and
    # expires in 180 days, so every Server sequence gets the conversion step. It is a
    # no-op on anything that is not an evaluation edition (see ServerEvalConversion.ps1,
    # which also records why the original hand-written version could not work).
    # NB: the eval->licensed conversion is NOT a task-sequence step any more. The deploy
    # client drops Convert-EvalEdition.ps1 + SetupComplete.cmd into the applied image for
    # server sequences (see Sync-AppPxeBootTaskSequenceStore / the deploy client). Keeping
    # it out of the unattend is what fixed the invalid-answer-file at specialize.
    $defaults
}
function Get-AppPxeBootTaskSequenceDefaultId {
    # '' = no default. A sequence id, or the literal Intune / Autopilot menu item.
    $path = Get-AppPxeBootTaskSequencesPath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return ([string](Get-AppPxeBootTsProp -Item $raw -Name 'defaultSequenceId')).Trim()
    } catch { return '' }
}

$script:AppPxeBootTaskSequenceRenames = @{
    # Craig, 2026-08-23: "The Task Sequence names should be just Server and Client.
    # Keep it simple." Changing the seed alone would leave the old names in every
    # store that already saved them, so the two seeded names heal on read. A name the
    # user has since edited is left exactly as they typed it.
    'Client - domain join'         = 'Client'
    'Server - static IP + domain'  = 'Server'
}

function Read-AppPxeBootTaskSequences {
    $path = Get-AppPxeBootTaskSequencesPath
    if (-not (Test-Path -LiteralPath $path)) {
        return @(Get-AppPxeBootTaskSequenceDefaults)
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        # An existing store with an EMPTY list is an explicit user choice (all
        # sequences deleted - Craig, 2026-08-20: the seeds are examples, fully
        # deletable). Only a missing/corrupt store file re-seeds the examples.
        return @(Get-AppPxeBootTsProp -Item $raw -Name 'sequences')
    } catch {
        Write-SidecarLog "PXE boot: task-sequences store unreadable ($($_.Exception.Message)) - using defaults"
        return @(Get-AppPxeBootTaskSequenceDefaults)
    }
}

function ConvertTo-AppPxeBootTaskSequenceRecord {
    # Normalise one sequence (from JSON or IPC params) into a plain hashtable.
    param([Parameter(Mandatory)]$Item)
    $id = ([string](Get-AppPxeBootTsProp -Item $Item -Name 'id')).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    # Slug guard: the id becomes a filename on the share. TrimStart also strips
    # leading dots - '../x' must not survive as a hidden/path-shaped name.
    $id = ($id -replace '[^A-Za-z0-9._-]', '-').Trim('-').TrimStart('.', '-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $kind = ([string](Get-AppPxeBootTsProp -Item $Item -Name 'kind')).Trim().ToLowerInvariant()
    # Sections replaced kinds (Craig, 2026-08-19): only the client/server role
    # remains; the old OOBE variant is simply a client with no join domain.
    if ($kind -notin @('client', 'server')) { $kind = 'client' }
    # Which installer consumes this sequence. Windows means unattend.xml; debian
    # means a d-i preseed. Absent means windows, so every sequence written before
    # this existed keeps working untouched.
    $platform = ([string](Get-AppPxeBootTsProp -Item $Item -Name 'platform')).Trim().ToLowerInvariant()
    if ($platform -notin @('windows', 'debian', 'ubuntu')) { $platform = 'windows' }
    # kind is a Windows role. A preseed has no client/server split, and leaving a
    # stale 'server' on it would show the wrong fields in the panel.
    if ($platform -ne 'windows') { $kind = '' }
    $fieldsIn = Get-AppPxeBootTsProp -Item $Item -Name 'fields'
    $fields = [ordered]@{}
    if ($fieldsIn) {
        # ForEach-Object, not member enumeration: `.Name` on an EMPTY property
        # collection throws under StrictMode (fields: {} round-tripped via JSON).
        $names = if ($fieldsIn -is [System.Collections.IDictionary]) { @($fieldsIn.Keys) } else { @($fieldsIn.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($n in $names) {
            $fields[[string]$n] = [string](Get-AppPxeBootTsProp -Item $fieldsIn -Name ([string]$n))
        }
    }
    # Debian: a password typed in the panel arrives as fields.userPassword and is hashed
    # here - only userPasswordCrypted is ever stored or published. A blank one keeps the
    # hash already saved.
    if ($platform -in @('debian', 'ubuntu') -and $fields.Contains('userPassword')) {
        $plainPw = [string]$fields['userPassword']
        if (-not [string]::IsNullOrEmpty($plainPw)) {
            $fields['userPasswordCrypted'] = ConvertTo-AppPxeBootTsSha512Crypt -Password $plainPw
        }
        $fields.Remove('userPassword')
    }
    # Heal the wrapper leak (pre-2026-08-20 the payload stringified the raw
    # override object into the dropdown, and it could get saved):
    # '@{value=example.local; userLocked=True; ...}' -> 'example.local'.
    if ($fields.Contains('joinDomain') -and $fields['joinDomain'] -match '^@\{.*?value=([^;}]+)') {
        $fields['joinDomain'] = ([string]$matches[1]).Trim()
    }
    # Ordered custom steps (reg / cmd / pwsh) - the editable first-boot spec.
    $steps = @()
    foreach ($stepIn in @(Get-AppPxeBootTsProp -Item $Item -Name 'steps')) {
        if ($null -eq $stepIn) { continue }
        $type = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'type')).Trim().ToLowerInvariant()
        # pwshEncoded carries a whole script as one step (the Server evaluation
        # conversion is one). Leaving it off this list silently deleted that step on
        # the first save - caught 2026-08-22.
        if ($type -notin @('reg', 'cmd', 'pwsh', 'pwshencoded')) { continue }
        $step = [ordered]@{
            type        = if ($type -eq 'pwshencoded') { 'pwshEncoded' } else { $type }
            description = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'description')).Trim()
        }
        if ($type -eq 'reg') {
            $op = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'op')).Trim().ToLowerInvariant()
            $step.op = if ($op -eq 'delete') { 'delete' } else { 'add' }
            $step.path = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'path')).Trim()
            $step.name = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'name')).Trim()
            $vt = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'valueType')).Trim().ToUpperInvariant()
            $step.valueType = if ($vt -in @('REG_SZ', 'REG_DWORD', 'REG_QWORD', 'REG_EXPAND_SZ', 'REG_MULTI_SZ')) { $vt } else { '' }
            $step.data = [string](Get-AppPxeBootTsProp -Item $stepIn -Name 'data')
            if (-not $step.path) { continue }
        } else {
            $step.command = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'command'))
            if ([string]::IsNullOrWhiteSpace($step.command)) { continue }
        }
        $steps += , $step
        if ($steps.Count -ge 32) { break }
    }
    $adminGroups = @()
    foreach ($g in @(Get-AppPxeBootTsProp -Item $Item -Name 'adminGroups')) {
        $gv = ([string]$g).Trim()
        if ($gv -and $adminGroups -notcontains $gv) { $adminGroups += $gv }
        if ($adminGroups.Count -ge 8) { break }
    }
    # Local account. A password typed in the panel arrives in clear and is stored
    # base64 - obfuscation so the store is not readable over a shoulder, nothing more
    # (LAPS rotates the account). An already-stored value is left alone, so re-saving
    # a sequence never double-encodes or wipes the password.
    # Local account: ONE mode - none | manual | vault. Vault mode takes BOTH the user
    # name and the password from the selected vault credential (Craig, 2026-08-23:
    # "selecting user from the vault also grabs that user's vault password"), so there
    # is no separate name field in that mode. Legacy stores (enabled + passwordSource)
    # are mapped to a mode on read.
    $accountIn = Get-AppPxeBootTsProp -Item $Item -Name 'localAccount'
    $localAccount = $null
    if ($accountIn) {
        $mode = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'mode')).Trim().ToLowerInvariant()
        if ($mode -notin @('none', 'manual', 'vault')) {
            $legacyEnabled = [bool](Get-AppPxeBootTsProp -Item $accountIn -Name 'enabled')
            $legacySource = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'passwordSource')).Trim().ToLowerInvariant()
            $mode = if (-not $legacyEnabled) { 'none' } elseif ($legacySource -eq 'vault') { 'vault' } else { 'manual' }
        }
        $accountName = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'name')).Trim()
        $group = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'group')).Trim()
        if ($group -notin @('Administrators', 'Users')) { $group = 'Administrators' }
        $stored = [string](Get-AppPxeBootTsProp -Item $accountIn -Name 'password')
        $typed = [string](Get-AppPxeBootTsProp -Item $accountIn -Name 'passwordPlain')
        if (-not [string]::IsNullOrEmpty($typed)) {
            $stored = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($typed))
        }
        if ($mode -eq 'vault') { $stored = '' }
        $localAccount = [ordered]@{
            mode           = $mode
            enabled        = ($mode -ne 'none')
            name           = if ($accountName) { $accountName } else { 'localadmin' }
            displayName    = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'displayName')).Trim()
            description    = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'description')).Trim()
            group          = $group
            passwordSource = if ($mode -eq 'vault') { 'vault' } else { 'manual' }
            vaultSecret    = ([string](Get-AppPxeBootTsProp -Item $accountIn -Name 'vaultSecret')).Trim()
            password       = $stored
            autoLogonCount = [int](Get-AppPxeBootTsAutoLogonCount -Account $accountIn)
        }
    }
    # Which install.wim (and which index inside it) this sequence deploys. Empty =
    # the tech picks at the device, which is how every sequence behaved before
    # 2026-08-22. sourceId is 'iso:<file>' or 'wim:<file>' from the image catalog;
    # anything else is dropped rather than published as a dangling reference.
    $imageIn = Get-AppPxeBootTsProp -Item $Item -Name 'image'
    $image = $null
    if ($imageIn) {
        $sourceId = ([string](Get-AppPxeBootTsProp -Item $imageIn -Name 'sourceId')).Trim()
        if ($sourceId -match '^(iso|wim):[^\\/]+$') {
            $imageIndex = 0
            try { $imageIndex = [int](Get-AppPxeBootTsProp -Item $imageIn -Name 'index') } catch { $imageIndex = 0 }
            if ($imageIndex -lt 1) { $imageIndex = 1 }
            if ($imageIndex -gt 64) { $imageIndex = 64 }
            $image = [ordered]@{
                sourceId    = $sourceId
                index       = $imageIndex
                # Remembered so the panel and the published index can still name the
                # edition when the media is offline (an unplugged drive, ISO removed).
                editionName = ([string](Get-AppPxeBootTsProp -Item $imageIn -Name 'editionName')).Trim()
            }
        }
    }
    $nameVal = [string](Get-AppPxeBootTsProp -Item $Item -Name 'name')
    # Heal the two long seeded names on read (see $script:AppPxeBootTaskSequenceRenames).
    $trimmedName = $nameVal.Trim()
    if ($script:AppPxeBootTaskSequenceRenames.ContainsKey($trimmedName)) {
        $nameVal = [string]$script:AppPxeBootTaskSequenceRenames[$trimmedName]
    }
    $record = [ordered]@{
        id          = $id
        name        = if ([string]::IsNullOrWhiteSpace($nameVal)) { $id } else { $nameVal.Trim() }
        kind        = $kind
        enabled     = [bool](Get-AppPxeBootTsProp -Item $Item -Name 'enabled')
        fields      = $fields
        adminGroups = $adminGroups
        platform    = $platform
        steps       = $steps
    }
    if ($localAccount) { $record['localAccount'] = $localAccount }
    if ($image) { $record['image'] = $image }
    $record
}

function Save-AppPxeBootTaskSequences {
    param(
        # AllowEmptyCollection: deleting every sequence is a legitimate save.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sequences,
        [AllowEmptyString()][string]$DefaultSequenceId = ''
    )
    $records = @()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Sequences) {
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $item
        if ($null -eq $rec) { continue }
        if (-not $seen.Add([string]$rec.id)) { continue }
        $records += , $rec
        if ($records.Count -ge $script:AppPxeBootTaskSequenceMaxCount) { break }
    }
    # Default must reference a saved sequence; anything else saves as "no default"
    # (= the client's None item, clean OOBE) so a renamed/removed id
    # can't preselect garbage.
    $default = ([string]$DefaultSequenceId).Trim()
    if ($default) {
        $ids = @($records | ForEach-Object { [string]$_.id })
        if ($ids -notcontains $default) { $default = '' }
    }
    $path = Get-AppPxeBootTaskSequencesPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    (@{ sequences = $records; defaultSequenceId = $default } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    Sync-AppPxeBootTaskSequenceStore | Out-Null
    , $records
}

function ConvertTo-AppPxeBootTsXmlEscaped {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    [System.Security.SecurityElement]::Escape($Value)
}

$script:AppPxeBootTsDomainSuggestionCache = $null
$script:AppPxeBootTsDomainSuggestionTtlMinutes = 5

function Get-AppPxeBootTsDomainCandidates {
    # DNS search suffixes this host already knows about. macOS keeps them in scutil,
    # Windows in the DNS client settings (plus USERDNSDOMAIN when the host is joined).
    $out = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Value)
        $v = ([string]$Value).Trim().Trim('.')
        if ($v -and $v -match '\.' -and $out -notcontains $v) { [void]$out.Add($v) }
    }
    try {
        if ($IsWindows) {
            & $add ([string]$env:USERDNSDOMAIN)
            if (Test-AppSidecarCommand Get-DnsClientGlobalSetting) {
                foreach ($s in @((Get-DnsClientGlobalSetting).SuffixSearchList)) { & $add ([string]$s) }
            }
        } else {
            $scutil = @(& scutil --dns 2>$null)
            foreach ($line in $scutil) {
                if ($line -match 'search domain\[\d+\]\s*:\s*(?<d>\S+)') { & $add ([string]$matches['d']) }
            }
            foreach ($line in @(Get-Content -LiteralPath '/etc/resolv.conf' -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*(?:search|domain)\s+(?<rest>.+)$') {
                    foreach ($d in ($matches['rest'] -split '\s+')) { & $add ([string]$d) }
                }
            }
        }
    } catch { }
    @($out)
}

function Test-AppPxeBootTsDomainIsAdDomain {
    <#
    .SYNOPSIS
        Does this suffix actually look like an Active Directory domain? Asks DNS for the
        domain controller SRV record every AD domain publishes.
    #>
    param([Parameter(Mandatory)][string]$Domain)
    $query = "_ldap._tcp.dc._msdcs.$Domain"
    try {
        if ($IsWindows -and (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
            $rr = Resolve-DnsName -Name $query -Type SRV -ErrorAction Stop
            return (@($rr | Where-Object { $_.Type -eq 'SRV' }).Count -gt 0)
        }
        if (Get-Command dig -ErrorAction SilentlyContinue) {
            # Bounded hard: this runs on the dispatch thread.
            $answer = @(& dig +short +time=2 +tries=1 SRV $query 2>$null)
            return (@($answer | Where-Object { $_ -match '\S' }).Count -gt 0)
        }
    } catch { }
    return $false
}

function Get-AppPxeBootTsDomainSuggestions {
    <#
    .SYNOPSIS
        Domains worth offering in the join field, discovered from this host's DNS
        (Craig, 2026-08-22: "suggested domain join should be grabbed via dns").
        Verified ones - those publishing the AD domain-controller SRV record - come
        first. Memoised for a few minutes: DNS lookups are cheap but not free, and the
        dispatch loop is single-threaded.
    #>
    param([switch]$Force)
    $now = (Get-Date).ToUniversalTime()
    if (-not $Force -and $script:AppPxeBootTsDomainSuggestionCache -and
        ($now - $script:AppPxeBootTsDomainSuggestionCache.at).TotalMinutes -lt $script:AppPxeBootTsDomainSuggestionTtlMinutes) {
        return $script:AppPxeBootTsDomainSuggestionCache.items
    }
    $items = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($candidate in @(Get-AppPxeBootTsDomainCandidates)) {
        [void]$items.Add([ordered]@{
            domain   = $candidate
            verified = [bool](Test-AppPxeBootTsDomainIsAdDomain -Domain $candidate)
            source   = 'dns-search-suffix'
        })
    }
    $ordered = @(@($items | Where-Object { $_.verified }) + @($items | Where-Object { -not $_.verified }))
    $script:AppPxeBootTsDomainSuggestionCache = @{ at = $now; items = $ordered }
    return $ordered
}

function Get-AppPxeBootTaskSequencePublishContext {
    <#
    .SYNOPSIS
        Live values resolved at publish time from the Site Profile: the join
        identity (domain + username - never the password), the local-admin
        passwords used for the {{LocalAdminPw}} token, and the base OU for
        {{SiteOu}} machine-OU tokens.
    .NOTES
        TODO(Site Profile): back these with the Site Profile store. Until it
        exists every value is $null, which makes the token expansion fail loudly
        rather than publishing a wrong-but-plausible value.
        The USM original sourced these from the Site Profile and fell back to
        two hardcoded department bench passwords - both removed here.
    #>
    $ctx = @{
        joinDomain   = $null
        joinUser     = $null
        clientAdmPw  = $null
        serverAdmPw  = $null
        siteOuDn     = $null
        siteId       = $null
    }
    try {
        if (Test-AppSidecarCommand Get-AppSiteProfile) {
            $profile = Get-AppSiteProfile
            if ($profile) {
                $ctx.joinDomain  = [string]$profile.joinDomain
                $ctx.joinUser    = [string]$profile.joinUser
                $ctx.clientAdmPw = [string]$profile.clientAdminPassword
                $ctx.serverAdmPw = [string]$profile.serverAdminPassword
                $ctx.siteOuDn    = [string]$profile.siteOuDn
                $ctx.siteId      = [string]$profile.siteId
            }
        }
    } catch { }
    $ctx
}

function Get-AppPxeBootTsGvlkOptions {
    <#
    .SYNOPSIS
        Microsoft GVLK suggestions for the product-key field: the server editions from
        the eval-conversion table (build-labelled) plus common client keys.
    .NOTES
        Suggestions only - the field is free text (a corporate MAK or retail key is
        what a licensed install actually wants; WDK does not KMS-activate). Leaving it
        blank is correct for an evaluation image: the conversion step licenses it, and
        a GVLK in specialize would make Setup reject the answer file.
    #>
    $out = @()
    if ($script:AppServerEvalGvlk) {
        foreach ($build in @('26100', '20348', '17763', '14393')) {
            if (-not $script:AppServerEvalGvlk.Contains($build)) { continue }
            $table = $script:AppServerEvalGvlk[$build]
            $name = if ($table.Contains('name')) { [string]$table['name'] } else { "Build $build" }
            foreach ($ed in @('ServerStandard', 'ServerDatacenter')) {
                if ($table.Contains($ed)) {
                    $edLabel = $ed -replace '^Server(Standard|Datacenter|Solution)$', '$1'
                    $out += @{ label = "$name $edLabel"; key = [string]$table[$ed] }
                }
            }
        }
    }
    # Published client GVLKs (learn.microsoft.com KMS client setup keys).
    $out += @{ label = 'Windows 11/10 Pro';                 key = 'W269N-WFGWX-YVC9B-4J6C9-T83GX' }
    $out += @{ label = 'Windows 11/10 Enterprise';          key = 'NPPR9-FWDCX-D2C8J-H872K-2YT43' }
    $out += @{ label = 'Windows 11 Enterprise LTSC 2024';   key = 'M7XTQ-FN8P6-TTKYV-9D4CC-J462D' }
    $out += @{ label = 'Windows 11 IoT Enterprise LTSC 2024'; key = 'KBN8V-HFGQ4-MGXVD-347P6-PDQGT' }
    $out
}

function Get-AppPxeBootTsProductKeyDefault {
    # Role default from the configured KMS catalog; falls back to Microsoft's
    # published KMS client setup keys (GVLKs) below.
    # TODO(Site Profile): source the catalog from the Site Profile.
    param([Parameter(Mandatory)][string]$Role)
    try {
        if (Test-AppSidecarCommand Get-AppPxeBootKmsClientKeys) {
            $catalog = Get-AppPxeBootKmsClientKeys
            foreach ($name in $catalog.Keys) {
                $isServer = $name -match '(?i)server'
                if (($Role -eq 'server') -eq $isServer) { return [string]$catalog[$name] }
            }
        }
    } catch { }
    # Server 2022 Standard / Windows IoT Enterprise LTSC 2024, from Microsoft's published
    # GVLK list. The previous server fallback (8B2CN-...) is not a published GVLK at all -
    # it came across from the hand-written activation script (checked 2026-08-22 against
    # learn.microsoft.com/windows-server/get-started/kms-client-activation-keys).
    if ($Role -eq 'server') { 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H' } else { 'KBN8V-HFGQ4-MGXVD-347P6-PDQGT' }
}

function Get-AppPxeBootTsStepCommandLine {
    # One step -> the RunSynchronousCommand Path line (raw; XML-escaped by caller).
    # Quote safety (2026-08-20): a literal " inside a wrapped value broke the
    # generated line at first boot. Registry paths/value names can't legitimately
    # need quotes -> stripped; reg data and pwsh commands escape them as \" (what
    # CommandLineToArgvW understands for both reg.exe and powershell.exe).
    param([Parameter(Mandatory)]$Step)
    switch ([string]$Step.type) {
        'reg' {
            $path = ([string]$Step.path) -replace '"', ''
            $name = ([string]$Step.name) -replace '"', ''
            if ([string]$Step.op -eq 'delete') {
                if ($name) { "cmd /c reg delete `"$path`" /v `"$name`" /f" }
                else { "cmd /c reg delete `"$path`" /f" }
            } else {
                $vt = if ([string]$Step.valueType) { [string]$Step.valueType } else { 'REG_SZ' }
                $data = ([string]$Step.data) -replace '"', '\"'
                $line = "cmd /c reg add `"$path`""
                if ($name) { $line += " /v `"$name`"" }
                $line += " /t $vt /d `"$data`" /f"
                $line
            }
        }
        'pwsh' { "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$(([string]$Step.command) -replace '"', '\"')`"" }
        # A whole script as one step: base64 (UTF-16LE, what -EncodedCommand wants) so
        # quoting cannot break the generated line, however long or nested the script is.
        # The step still stores readable text, so the panel can show and edit it.
        'pwshEncoded' {
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([string]$Step.command))
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        }
        default { "cmd /c $([string]$Step.command)" }
    }
}

function Test-AppPxeBootTsIsEvalConversionStep {
    # The eval->licensed conversion no longer rides in the unattend: it is a 9KB
    # EncodedCommand, /Set-Edition is a servicing op that belongs at SetupComplete, and
    # Z:\ is not mounted during specialize anyway. The deploy client writes
    # Convert-EvalEdition.ps1 + SetupComplete.cmd into the image instead. Any such step
    # already saved in a store is skipped here so it never reaches the answer file
    # (Craig, 2026-08-23: "answer file is invalid for [specialize]").
    param($Step)
    if (-not $Step) { return $false }
    # Get-AppPxeBootTsProp, not $Step.command: a reg step has no command property and a
    # bare read throws under StrictMode.
    $cmd = [string](Get-AppPxeBootTsProp -Item $Step -Name 'command')
    return ($cmd -like '*Convert-EvalEdition.ps1*')
}

function Get-AppPxeBootTsFirstBootScript {
    <#
    .SYNOPSIS
        The sequence's reg/cmd/pwsh steps as a batch that runs from SetupComplete.cmd -
        NOT baked into the unattend. Empty when the sequence has no steps.
    .NOTES
        Craig, 2026-08-23: "move any/all commands/regkeys in the unattend to the server
        from the library." The answer file keeps only what an unattend is FOR - identity,
        locale, OOBE, the local account, domain join, static IP - and every command/reg
        step is applied by this script instead. It runs as SYSTEM after setup, before
        anyone logs on (the standard place for post-install config), logs to
        C:\Windows\Setup\Scripts\firstboot.log, and never stops on a failing step.
        The eval-conversion step is excluded here - it is its own Convert-EvalEdition.ps1.
    #>
    param([Parameter(Mandatory)]$Sequence)
    $steps = @(@($Sequence.steps) | Where-Object { -not (Test-AppPxeBootTsIsEvalConversionStep -Step $_) })
    if ($steps.Count -eq 0) { return '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('@echo off')
    [void]$lines.Add('rem WinDeployKit first-boot steps - run from SetupComplete.cmd as SYSTEM.')
    [void]$lines.Add('set "LOG=%SystemRoot%\Setup\Scripts\firstboot.log"')
    [void]$lines.Add('echo %DATE% %TIME% first-boot steps start>>"%LOG%"')
    $n = 0
    foreach ($step in $steps) {
        $n++
        $desc = [string](Get-AppPxeBootTsProp -Item $step -Name 'description')
        if (-not $desc) { $desc = "Step $n" }
        # A one-line echo of the step name, then the step itself, both logged. The step
        # line is the same one the unattend used to carry (reg/cmd/pwsh/encoded).
        [void]$lines.Add("echo %DATE% %TIME% [$n] $($desc -replace '[<>|&%]', ' ')>>`"%LOG%`"")
        [void]$lines.Add((Get-AppPxeBootTsStepCommandLine -Step $step) + ' >>"%LOG%" 2>&1')
    }
    [void]$lines.Add('echo %DATE% %TIME% first-boot steps done>>"%LOG%"')
    ($lines -join "`r`n") + "`r`n"
}

function Get-AppPxeBootTsSpecializeRunSync {
    # The sequence's ordered steps as a specialize RunSynchronous component.
    # Empty steps list -> no component at all.
    param([object[]]$Steps)
    $Steps = @($Steps | Where-Object { -not (Test-AppPxeBootTsIsEvalConversionStep -Step $_) })
    if (-not $Steps -or $Steps.Count -eq 0) { return '' }
    $cmds = ''
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $desc = [string]$step.description
        if (-not $desc) { $desc = "Step $($i + 1)" }
        $line = Get-AppPxeBootTsStepCommandLine -Step $step
        $cmds += @"
				<RunSynchronousCommand wcm:action="add">
					<Description>$(ConvertTo-AppPxeBootTsXmlEscaped $desc)</Description>
					<Order>$($i + 1)</Order>
					<Path>$(ConvertTo-AppPxeBootTsXmlEscaped $line)</Path>
				</RunSynchronousCommand>

"@
    }
    @"
		<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<RunSynchronous>
$cmds			</RunSynchronous>
		</component>
"@
}
$script:AppPxeBootIanaToWindowsTz = @{
    'Australia/Sydney' = 'AUS Eastern Standard Time'; 'Australia/Melbourne' = 'AUS Eastern Standard Time'
    'Australia/Hobart' = 'Tasmania Standard Time'; 'Australia/Brisbane' = 'E. Australia Standard Time'
    'Australia/Adelaide' = 'Cen. Australia Standard Time'; 'Australia/Darwin' = 'AUS Central Standard Time'
    'Australia/Perth' = 'W. Australia Standard Time'; 'Pacific/Auckland' = 'New Zealand Standard Time'
    'Europe/London' = 'GMT Standard Time'; 'Europe/Dublin' = 'GMT Standard Time'; 'Europe/Paris' = 'Romance Standard Time'
    'Europe/Berlin' = 'W. Europe Standard Time'; 'America/New_York' = 'Eastern Standard Time'
    'America/Chicago' = 'Central Standard Time'; 'America/Denver' = 'Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'; 'Asia/Singapore' = 'Singapore Standard Time'
    'Asia/Tokyo' = 'Tokyo Standard Time'; 'Asia/Kolkata' = 'India Standard Time'; 'Asia/Shanghai' = 'China Standard Time'
    'Asia/Hong_Kong' = 'China Standard Time'; 'Asia/Dubai' = 'Arabian Standard Time'; 'UTC' = 'UTC'; 'Etc/UTC' = 'UTC'
}

$script:AppPxeBootLocaleToInputLocale = @{
    'en-AU' = '0c09:00000409'; 'en-NZ' = '1409:00000409'; 'en-GB' = '0809:00000809'
    'en-US' = '0409:00000409'; 'en-CA' = '1009:00000409'; 'en-IE' = '1809:00001809'
    'en-ZA' = '1c09:00000409'; 'en-IN' = '4009:00000409'
}

function Get-AppPxeBootTsRegionalDefaults {
    <#
    .SYNOPSIS
        Regional suggestions from THIS host - @{ uiLanguage; inputLocale; timeZone } -
        so a deploy defaults to where the imaging box actually is (Craig, 2026-08-23).
        macOS reads AppleLocale + /etc/localtime; Windows reads the culture and time
        zone directly. Falls back to en-AU / AUS Eastern.
    #>
    $locale = 'en-AU'
    $winTz = 'AUS Eastern Standard Time'
    try {
        if ($IsMacOS -or $IsDarwin) {
            $al = (& defaults read -g AppleLocale 2>$null | Select-Object -First 1)
            if ($al) { $locale = ([string]$al).Trim() -replace '_', '-' -replace '@.*$', '' }
            $link = (& readlink /etc/localtime 2>$null | Select-Object -First 1)
            if ($link) {
                $iana = ([string]$link -replace '.*/zoneinfo/', '').Trim()
                if ($script:AppPxeBootIanaToWindowsTz.ContainsKey($iana)) { $winTz = $script:AppPxeBootIanaToWindowsTz[$iana] }
            }
        } elseif ($env:OS -eq 'Windows_NT') {
            try { $locale = (Get-Culture).Name } catch { }
            try { $winTz = (Get-TimeZone).Id } catch { }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($locale)) { $locale = 'en-AU' }
    if ([string]::IsNullOrWhiteSpace($winTz)) { $winTz = 'AUS Eastern Standard Time' }
    # InputLocale wants LCID:keyboard-layout ("0c09:00000409"), not a bare language tag.
    # The bare tag is my regression (2026-08-23) - the original hardcoded value was the
    # explicit pair, and that is what Windows Setup documents.
    $kb = if ($script:AppPxeBootLocaleToInputLocale.ContainsKey($locale)) {
        $script:AppPxeBootLocaleToInputLocale[$locale]
    } else {
        $locale
    }
    @{ userLocale = $locale; inputLocale = $kb; timeZone = $winTz }
}

function Get-AppPxeBootTsIntlSpecialize {
    <#
    .NOTES
        Two different things, kept apart deliberately:
          * UILanguage / UILanguageFallback = the DISPLAY language, which must be a
            language actually installed in the image. English media ships en-US, so
            that is what we emit. en-AU is NOT an installed UI language - it is a
            locale - and naming it here is how an unattend quietly does nothing or
            fails (this was hardcoded to en-AU before 2026-08-23).
          * SystemLocale / UserLocale = regional formats, which DO follow the host
            (en-AU), and InputLocale = keyboard, which wants LCID:layout.
    #>
    param([AllowEmptyString()][string]$UserLocale = '', [AllowEmptyString()][string]$InputLocale = '')
    $d = Get-AppPxeBootTsRegionalDefaults
    $loc = if ([string]::IsNullOrWhiteSpace($UserLocale)) { $d.userLocale } else { $UserLocale }
    $kb = if ([string]::IsNullOrWhiteSpace($InputLocale)) { $d.inputLocale } else { $InputLocale }
    $display = 'en-US'
    @"
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>$(ConvertTo-AppPxeBootTsXmlEscaped $kb)</InputLocale>
			<SystemLocale>$(ConvertTo-AppPxeBootTsXmlEscaped $loc)</SystemLocale>
			<UILanguage>$display</UILanguage>
			<UILanguageFallback>$display</UILanguageFallback>
			<UserLocale>$(ConvertTo-AppPxeBootTsXmlEscaped $loc)</UserLocale>
		</component>
"@
}

function Get-AppPxeBootTsShellSpecialize {
    # ProductKey lives HERE: the ADK documents Shell-Setup ProductKey for the
    # specialize pass; in oobeSystem it is ignored (moved 2026-08-20, Craig's call).
    # Emitted ONLY when a key was actually chosen. An empty key emits no element -
    # a GVLK that does not match the image build makes Windows Setup reject the whole
    # answer file at specialize ("the answer file is invalid"), and it is exactly wrong
    # on an evaluation image, where the eval-conversion step does the licensing with a
    # build-matched key from SetupComplete (Craig, 2026-08-23: Server 2022 GVLK landed
    # on a Server 2025 eval image). WDK does not KMS-activate anyway.
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [AllowEmptyString()][string]$ProductKey,
        [AllowEmptyString()][string]$RegisteredOrg = '',
        [AllowEmptyString()][string]$RegisteredOwner = '',
        [AllowEmptyString()][string]$TimeZone = ''
    )
    $tz = if ([string]::IsNullOrWhiteSpace($TimeZone)) { (Get-AppPxeBootTsRegionalDefaults).timeZone } else { $TimeZone }
    # No fabricated default: an empty org/owner emits no element.
    $orgLine = if (-not [string]::IsNullOrWhiteSpace($RegisteredOrg)) { "`n			<RegisteredOrganization>$(ConvertTo-AppPxeBootTsXmlEscaped $RegisteredOrg)</RegisteredOrganization>" } else { '' }
    $ownerLine = if (-not [string]::IsNullOrWhiteSpace($RegisteredOwner)) { "`n			<RegisteredOwner>$(ConvertTo-AppPxeBootTsXmlEscaped $RegisteredOwner)</RegisteredOwner>" } else { '' }
    $productKeyLine = if (-not [string]::IsNullOrWhiteSpace($ProductKey)) {
        "`n			<ProductKey>$(ConvertTo-AppPxeBootTsXmlEscaped $ProductKey)</ProductKey>"
    } else { '' }
    @"
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<ComputerName>$ComputerName</ComputerName>$productKeyLine$orgLine$ownerLine
			<TimeZone>$(ConvertTo-AppPxeBootTsXmlEscaped $tz)</TimeZone>
		</component>
"@
}

function Get-AppPxeBootTsDnsComponent {
    # Static-networking DNS search order. $Dns is an already-filtered list.
    param([string[]]$Dns)
    if (-not $Dns -or $Dns.Count -eq 0) { return '' }
    $ipLines = ''
    for ($i = 0; $i -lt $Dns.Count; $i++) {
        $ipLines += "						<IpAddress wcm:action=`"add`" wcm:keyValue=`"$($i + 1)`">$(ConvertTo-AppPxeBootTsXmlEscaped $Dns[$i])</IpAddress>`n"
    }
    @"
		<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<Interfaces>
				<Interface wcm:action="add">
					<DNSServerSearchOrder>
$ipLines					</DNSServerSearchOrder>
					<Identifier>Ethernet</Identifier>
				</Interface>
			</Interfaces>
		</component>
"@
}

function Get-AppPxeBootTsStaticIpComponent {
    param([Parameter(Mandatory)][string]$IpCidr, [Parameter(Mandatory)][string]$Gateway)
    @"
		<component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<Interfaces>
				<Interface wcm:action="add">
					<Identifier>Ethernet</Identifier>
					<Ipv4Settings>
						<DhcpEnabled>false</DhcpEnabled>
						<Metric>10</Metric>
						<RouterDiscoveryEnabled>false</RouterDiscoveryEnabled>
					</Ipv4Settings>
					<UnicastIpAddresses>
						<IpAddress wcm:action="add" wcm:keyValue="1">$(ConvertTo-AppPxeBootTsXmlEscaped $IpCidr)</IpAddress>
					</UnicastIpAddresses>
					<Routes>
						<Route wcm:action="add">
							<Identifier>1</Identifier>
							<Metric>10</Metric>
							<NextHopAddress>$(ConvertTo-AppPxeBootTsXmlEscaped $Gateway)</NextHopAddress>
							<Prefix>0.0.0.0/0</Prefix>
						</Route>
					</Routes>
				</Interface>
			</Interfaces>
		</component>
"@
}

function Get-AppPxeBootTsUnattendedJoin {
    # Domain-join section. {{JoinDom}}/{{JoinUser}}/{{JoinPw}} filled at publish (store
    # cred) or on-device (ambient). {{OuElement}} pre-resolved by the caller.
    param([AllowEmptyString()][string]$OuElement = '')
    @"
		<component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<Identification>
				<Credentials>
					<Domain>{{JoinDom}}</Domain>
					<Password>{{JoinPw}}</Password>
					<Username>{{JoinUser}}</Username>
				</Credentials>
				<JoinDomain>{{JoinDomain}}</JoinDomain>
$OuElement			</Identification>
		</component>
"@
}

function Get-AppPxeBootTsOrgName {
    # TODO(Site Profile): registered organisation/owner for generated unattend files.
    $v = $null
    try { $v = (Get-AppPxeBootConfig).orgName } catch { }
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return (Get-AppProductDisplayName) }
    return [string]$v
}

function Get-AppPxeBootTsTimeZone {
    # TODO(Site Profile): Windows time-zone id for generated unattend files.
    $v = $null
    try { $v = (Get-AppPxeBootConfig).timeZone } catch { }
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return 'UTC' }
    return [string]$v
}

function ConvertTo-AppPxeBootTsUnattendPassword {
    <#
    .SYNOPSIS
        Windows Setup's own obfuscation for unattend passwords: base64 of
        UTF-16LE(password + <element name>), with PlainText false.
    .NOTES
        This is OBFUSCATION, NOT ENCRYPTION - anyone with the file can decode it in one
        line. It exists so a password is not sitting in clear text on the deploy share
        where a shoulder-surfer reads it. Craig's call (2026-08-22): acceptable because
        LAPS rotates the account afterwards. The element name really is part of the
        payload - "Password" for LocalAccount/AutoLogon, "AdministratorPassword" for the
        administrator element - and Setup rejects the value if it does not match.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [ValidateSet('Password', 'AdministratorPassword')][string]$ElementName = 'Password'
    )
    if ([string]::IsNullOrEmpty($Password)) { return '' }
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Password + $ElementName))
}

function ConvertFrom-AppPxeBootTsUnattendPassword {
    # Inverse, for tests and for showing an operator what is actually in a file.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [ValidateSet('Password', 'AdministratorPassword')][string]$ElementName = 'Password'
    )
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Value))
    if ($decoded.EndsWith($ElementName)) { return $decoded.Substring(0, $decoded.Length - $ElementName.Length) }
    return $decoded
}

function Get-AppPxeBootTsLocalAccountConfig {
    <#
    .SYNOPSIS
        A sequence's local account, with defaults filled in. Shape:
        enabled, name, displayName, description, group, passwordSource
        ('vault'|'manual'), vaultSecret, password (base64 at rest), autoLogonCount.
    #>
    param($Sequence)
    $raw = Get-AppPxeBootTsProp -Item $Sequence -Name 'localAccount'
    $get = {
        param([string]$Name, $Fallback)
        $v = Get-AppPxeBootTsProp -Item $raw -Name $Name
        if ($null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) { return $Fallback }
        return $v
    }
    $modeVal = ([string](& $get 'mode' '')).ToLowerInvariant()
    if ($modeVal -notin @('none', 'manual', 'vault')) {
        $en = if ($null -eq $raw) { $false } else { [bool](& $get 'enabled' $false) }
        $src = ([string](& $get 'passwordSource' 'manual')).ToLowerInvariant()
        $modeVal = if (-not $en) { 'none' } elseif ($src -eq 'vault') { 'vault' } else { 'manual' }
    }
    [ordered]@{
        mode           = $modeVal
        enabled        = ($modeVal -ne 'none')
        name           = [string](& $get 'name' 'localadmin')
        displayName    = [string](& $get 'displayName' 'Local Admin')
        description    = [string](& $get 'description' 'Created by the imaging task sequence')
        group          = [string](& $get 'group' 'Administrators')
        passwordSource = [string](& $get 'passwordSource' 'manual')
        vaultSecret    = [string](& $get 'vaultSecret' '')
        password       = [string](& $get 'password' '')
        autoLogonCount = [int](Get-AppPxeBootTsAutoLogonCount -Account $raw)
    }
}

function Get-AppPxeBootTsFirstBootAction {
    <#
    .SYNOPSIS
        What the machine does once first-boot setup finishes: restart (default),
        signout, shutdown, or none.
    .NOTES
        Craig, 2026-08-24: "at the end of any setup (first run) we need to reboot"
        - and the server eval->licensed conversion literally requires it: DISM
        Set-Edition stages the change and System > About keeps saying Evaluation
        until the restart (seen on SVR01 the same day). Restart is therefore the
        default, including for sequences saved before this option existed.
    #>
    param($Sequence)
    $v = ''
    $fields = Get-AppPxeBootTsProp -Item $Sequence -Name 'fields'
    if ($fields) { $v = ([string](Get-AppPxeBootTsProp -Item $fields -Name 'firstBootAction')).Trim().ToLowerInvariant() }
    if ($v -in @('none', 'restart', 'shutdown', 'signout')) { return $v }
    return 'restart'
}

function Get-AppPxeBootTsAutoLogonCount {
    <#
    .SYNOPSIS
        How many times Windows signs in automatically after imaging, 0-5. 0 = never.
    .NOTES
        Was a checkbox that meant "twice". Craig asked for the number itself
        (2026-08-24: "just as a drop down... 0-5. 0 (not enabled)") because how many
        reboots a first-boot script needs is the thing that actually varies. A saved
        sequence from before this reads its old checkbox as 2, which is what the
        checkbox wrote.
    #>
    param($Account)
    if (-not $Account) { return 0 }
    $raw = Get-AppPxeBootTsProp -Item $Account -Name 'autoLogonCount'
    if ($null -eq $raw -or ($raw -is [string] -and [string]::IsNullOrWhiteSpace([string]$raw))) {
        if ([bool](Get-AppPxeBootTsProp -Item $Account -Name 'autoLogon')) { return 2 }
        return 0
    }
    $n = 0
    if (-not [int]::TryParse([string]$raw, [ref]$n)) { return 0 }
    if ($n -lt 0) { return 0 }
    if ($n -gt 5) { return 5 }
    return $n
}

function Resolve-AppPxeBootTsLocalAccount {
    <#
    .SYNOPSIS
        The account to create at first boot, resolved to @{ user; pass }, or $null when
        there is no account (mode none) or it cannot be resolved.
    .NOTES
        Vault mode takes BOTH fields from the selected credential - the user name is the
        credential's UserName, not a typed field. Manual uses the typed name and the
        base64-at-rest password. Returns $null (account omitted) rather than a
        blank-password or nameless administrator.
    #>
    param($Account)
    if (-not $Account) { return $null }
    $mode = [string]$Account.mode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = if ([bool]$Account.enabled) { [string]$Account.passwordSource } else { 'none' } }
    if ($mode -eq 'none') { return $null }
    if ($mode -eq 'vault') {
        $secretName = [string]$Account.vaultSecret
        if ([string]::IsNullOrWhiteSpace($secretName)) { return $null }
        if (-not (Test-AppSidecarCommand Get-AppVaultCredential)) { return $null }
        $cred = Get-AppVaultCredential -Name $secretName
        if (-not $cred) {
            Write-SidecarLog "Task sequences: vault credential '$secretName' is missing - local account omitted"
            return $null
        }
        $user = [string]$cred.UserName
        $pass = Get-AppVaultPlainSecret -Name $secretName
        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrEmpty($pass)) {
            Write-SidecarLog "Task sequences: vault credential '$secretName' has no usable user/password - local account omitted"
            return $null
        }
        if ($user -match '^(.+)\\(.+)$') { $user = $matches[2] }
        return @{ user = $user; pass = [string]$pass }
    }
    $user = [string]$Account.name
    if ([string]::IsNullOrWhiteSpace($user)) { return $null }
    $stored = [string]$Account.password
    if ([string]::IsNullOrEmpty($stored)) { return $null }
    $pass = try { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stored)) } catch { $stored }
    if ([string]::IsNullOrEmpty($pass)) { return $null }
    return @{ user = $user; pass = $pass }
}

function Resolve-AppPxeBootTsLocalAccountPassword {
    <#
    .SYNOPSIS
        The account's password in clear, from the vault or from the stored value.
        Returns '' when it cannot be resolved - the caller then omits the account
        rather than publishing a blank-password administrator.
    .NOTES
        Manual passwords are stored base64 in the sequence store: obfuscation so the
        JSON is not readable over a shoulder, nothing more.
    #>
    param($Account)
    if (-not $Account -or -not [bool]$Account.enabled) { return '' }
    if ([string]$Account.passwordSource -eq 'vault') {
        $secretName = [string]$Account.vaultSecret
        if ([string]::IsNullOrWhiteSpace($secretName)) { return '' }
        if (-not (Test-AppSidecarCommand Get-AppVaultPlainSecret)) { return '' }
        $plain = Get-AppVaultPlainSecret -Name $secretName
        if ([string]::IsNullOrEmpty($plain)) {
            Write-SidecarLog "Task sequences: vault secret '$secretName' is missing or empty - local account omitted"
            return ''
        }
        return [string]$plain
    }
    $stored = [string]$Account.password
    if ([string]::IsNullOrEmpty($stored)) { return '' }
    try {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stored))
    } catch {
        # Older stores kept it in clear; accept that rather than losing the account.
        return $stored
    }
}

function Get-AppPxeBootTsOobeAccounts {
    <#
    .SYNOPSIS
        oobeSystem accounts + autologon.
    .NOTES
        Three shapes, in order:
          1. A configured local account (Craig, 2026-08-22) - name/group from the
             sequence, password from the vault or typed in, written with Windows'
             own base64 obfuscation. AutoLogon only when the sequence asks for it,
             for two logons (LogonCount 2) so the one intended setup session
             still lands after the reboot setup triggers (eval conversion, domain join).
          2. No configured account, but the product can supply a local admin password
             (the {{LocalAdminPw}} token, filled at publish time) - the original
             behaviour, unchanged.
          3. Neither - emit NOTHING. Publishing the literal token as a password (which
             is what happened with no profile behind it) produces an unattend that
             cannot work.
        Admin groups are an explicit optional list, emitted only when joining a domain.
    #>
    param(
        [string[]]$AdminGroups = @(),
        [bool]$EmitGroups,
        $LocalAccount,
        [string]$LocalUser = '',
        [string]$LocalPassword,
        [bool]$LegacyLocalAdminAvailable
    )
    $domainAccounts = ''
    if ($EmitGroups -and $AdminGroups -and $AdminGroups.Count -gt 0) {
        $groupLines = ''
        foreach ($g in $AdminGroups) {
            $groupLines += "						<DomainAccount wcm:action=`"add`">`n							<Name>$(ConvertTo-AppPxeBootTsXmlEscaped $g)</Name>`n							<Group>Administrators</Group>`n						</DomainAccount>`n"
        }
        $domainAccounts = @"
				<DomainAccounts>
					<DomainAccountList wcm:action="add">
$groupLines					</DomainAccountList>
				</DomainAccounts>

"@
    }

    $useConfigured = $LocalAccount -and [bool]$LocalAccount.enabled -and -not [string]::IsNullOrEmpty($LocalPassword)
    if ($useConfigured) {
        $name = if (-not [string]::IsNullOrWhiteSpace($LocalUser)) { $LocalUser } else { [string]$LocalAccount.name }
        $encoded = ConvertTo-AppPxeBootTsUnattendPassword -Password $LocalPassword -ElementName 'Password'
        $autoLogon = ''
        $logonCount = [int](Get-AppPxeBootTsAutoLogonCount -Account $LocalAccount)
        if ($logonCount -gt 0) {
            $autoLogon = @"
			<AutoLogon>
				<Password>
					<Value>$encoded</Value>
					<PlainText>false</PlainText>
				</Password>
				<Username>$(ConvertTo-AppPxeBootTsXmlEscaped $name)</Username>
				<LogonCount>$logonCount</LogonCount>
				<Enabled>true</Enabled>
			</AutoLogon>
"@
        }
        return @"
			<UserAccounts>
$domainAccounts				<LocalAccounts>
					<LocalAccount wcm:action="add">
						<Password>
							<Value>$encoded</Value>
							<PlainText>false</PlainText>
						</Password>
						<Description>$(ConvertTo-AppPxeBootTsXmlEscaped ([string]$LocalAccount.description))</Description>
						<DisplayName>$(ConvertTo-AppPxeBootTsXmlEscaped ([string]$LocalAccount.displayName))</DisplayName>
						<Group>$(ConvertTo-AppPxeBootTsXmlEscaped ([string]$LocalAccount.group))</Group>
						<Name>$(ConvertTo-AppPxeBootTsXmlEscaped $name)</Name>
					</LocalAccount>
				</LocalAccounts>
			</UserAccounts>
$autoLogon
"@
    }

    if (-not $LegacyLocalAdminAvailable) {
        if ($domainAccounts) {
            return @"
			<UserAccounts>
$domainAccounts			</UserAccounts>
"@
        }
        return ''
    }

    @"
			<UserAccounts>
				<AdministratorPassword>
					<Value>{{LocalAdminPw}}</Value>
					<PlainText>true</PlainText>
				</AdministratorPassword>
$domainAccounts				<LocalAccounts>
					<LocalAccount wcm:action="add">
						<Password>
							<Value>{{LocalAdminPw}}</Value>
							<PlainText>true</PlainText>
						</Password>
						<Description>For setup only</Description>
						<DisplayName>Local Admin</DisplayName>
						<Group>Administrators</Group>
						<Name>localadmin</Name>
					</LocalAccount>
				</LocalAccounts>
			</UserAccounts>
			<AutoLogon>
				<Password>
					<Value>{{LocalAdminPw}}</Value>
					<PlainText>true</PlainText>
				</Password>
				<Username>localadmin</Username>
				<LogonCount>2</LogonCount>
				<Enabled>true</Enabled>
			</AutoLogon>
"@
}

function Get-AppPxeBootTsOobeShell {
    # AllowEmptyString: with no local account configured and no profile password, the
    # accounts block is legitimately empty, and Mandatory alone rejected that - it threw
    # while building the unattend for the commonest corporate sequence (caught 2026-08-22).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Accounts,
        [bool]$Joining,
        [AllowEmptyString()][string]$RegisteredOrg = '',
        [AllowEmptyString()][string]$RegisteredOwner = '',
        [bool]$HideEula = $true,
        [bool]$HideOnlineAccounts = $true,
        [bool]$HideOemReg = $true,
        [bool]$HideWireless = $true,
        [bool]$ExpressSettings = $true
    )
    $orgLine = if (-not [string]::IsNullOrWhiteSpace($RegisteredOrg)) { "			<RegisteredOrganization>$(ConvertTo-AppPxeBootTsXmlEscaped $RegisteredOrg)</RegisteredOrganization>`n" } else { '' }
    $ownerLine = if (-not [string]::IsNullOrWhiteSpace($RegisteredOwner)) { "			<RegisteredOwner>$(ConvertTo-AppPxeBootTsXmlEscaped $RegisteredOwner)</RegisteredOwner>`n" } else { '' }
    # OOBE screen skips - each optional, default on (a smoother imaging OOBE). The
    # online-account screens are also hidden whenever joining a domain, regardless.
    $oobeLines = [System.Collections.Generic.List[string]]::new()
    [void]$oobeLines.Add("				<HideLocalAccountScreen>true</HideLocalAccountScreen>")
    if ($HideOemReg) { [void]$oobeLines.Add("				<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>") }
    if ($HideOnlineAccounts -or $Joining) { [void]$oobeLines.Add("				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>") }
    if ($HideWireless) { [void]$oobeLines.Add("				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>") }
    if ($HideEula) { [void]$oobeLines.Add("				<HideEULAPage>true</HideEULAPage>") }
    [void]$oobeLines.Add("				<NetworkLocation>Work</NetworkLocation>")
    # ProtectYourPC 1 = express/recommended (skips the prompt); 3 = all off. Default express.
    [void]$oobeLines.Add("				<ProtectYourPC>$(if ($ExpressSettings) { '1' } else { '3' })</ProtectYourPC>")
    $oobeBlock = ($oobeLines -join "`n")
    @"
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<OOBE>
$oobeBlock
			</OOBE>
$Accounts$orgLine$ownerLine		</component>
"@
}

function Build-AppPxeBootTaskSequenceUnattendXml {
    param([Parameter(Mandatory)]$Sequence)
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $Sequence
    if ($null -eq $rec) { return $null }
    $f = $rec.fields
    $get = { param($name, $fallback) if ($f.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$f[$name])) { [string]$f[$name] } else { $fallback } }

    $role = if ($rec.kind -eq 'server') { 'server' } else { 'client' }
    $ctx = Get-AppPxeBootTaskSequencePublishContext

    # --- Computer name -----------------------------------------------------------
    # Free text (Craig, 2026-08-22: this is a corporate product - there is no site id
    # to prefix). {{SERIAL}} still fills on the device, so the default names a machine
    # after its BIOS serial; anything else is published verbatim.
    $computerName = & $get 'computerName' '{{SERIAL}}'
    if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = '{{SERIAL}}' }

    # --- Section toggles ---------------------------------------------------------
    $staticIp = ((& $get 'network' 'dhcp') -eq 'static')
    $joinDomainName = & $get 'joinDomain' ''
    $joining = -not [string]::IsNullOrWhiteSpace($joinDomainName)
    # Product key: emitted only when the user set one AND the image is not an
    # evaluation edition. A GVLK/MAK in specialize is valid and wanted on a full
    # (licensed/retail/volume) ISO, but is REJECTED on eval media ("answer file is
    # invalid"), where the eval-conversion step licenses via DISM /Set-Edition instead.
    # Eval is read straight off the bound image - the Evaluation Center ISOs and their
    # editions carry "eval" (SERVER_EVAL, ServerStandardEval); a full ISO does not.
    # No image bound (tech picks at the device) -> honour a set key, we cannot know.
    $imageRef = if ($rec.Contains('image') -and $rec.image) { "$($rec.image.sourceId) $($rec.image.editionName)" } else { '' }
    $imageIsEval = ($imageRef -match '(?i)eval')
    $productKey = if ($imageIsEval) { '' } else { & $get 'productKey' '' }

    # --- Static-IP section -------------------------------------------------------
    $dnsComponent = ''
    $ipComponent = ''
    if ($staticIp) {
        $dns = @(@((& $get 'dns1' ''), (& $get 'dns2' ''), (& $get 'dns3' '')) | Where-Object { $_ })
        $dnsComponent = Get-AppPxeBootTsDnsComponent -Dns $dns
        $ipCidr = & $get 'ipCidr' ''
        $gateway = & $get 'gateway' ''
        if ($ipCidr -and $gateway) {
            $ipComponent = Get-AppPxeBootTsStaticIpComponent -IpCidr $ipCidr -Gateway $gateway
        }
    }

    # --- Domain-join section (OU resolved, credentials threaded) -----------------
    $joinComponent = ''
    if ($joining) {
        # Free text: a DN typed by whoever built the sequence.
        $ou = & $get 'machineOu' ''
        $ouElement = if ($ou) { "				<MachineObjectOU>$(ConvertTo-AppPxeBootTsXmlEscaped $ou)</MachineObjectOU>`n" } else { '' }
        $joinComponent = Get-AppPxeBootTsUnattendedJoin -OuElement $ouElement
    }

    # --- Assemble ---------------------------------------------------------------
    # Admin-group block is emitted whenever we are joining a domain and the
    # sequence actually lists groups (TODO(Site Profile): per-domain group policy).
    $centralJoin = $joining -and @($rec.adminGroups).Count -gt 0
    # Steps (reg/cmd/pwsh) are NOT in the unattend any more - they run from
    # SetupComplete.cmd via <id>.firstboot.cmd, dropped into the image by the deploy
    # client. The answer file keeps only identity/locale/account/join/IP.
    $regOrg = & $get 'registeredOrg' ''
    $regOwner = & $get 'registeredOwner' ''
    # 'uiLanguage' was the old field name for the same thing (region formats).
    $userLocale = & $get 'userLocale' ''
    if ([string]::IsNullOrWhiteSpace($userLocale)) { $userLocale = & $get 'uiLanguage' '' }
    $inputLocale = & $get 'inputLocale' ''
    $timeZone = & $get 'timeZone' ''
    $intl = Get-AppPxeBootTsIntlSpecialize -UserLocale $userLocale -InputLocale $inputLocale
    $specialize = $dnsComponent + $intl + (Get-AppPxeBootTsShellSpecialize -ComputerName $computerName -ProductKey $productKey -RegisteredOrg $regOrg -RegisteredOwner $regOwner -TimeZone $timeZone) + $ipComponent + $joinComponent
    $localAccount = Get-AppPxeBootTsLocalAccountConfig -Sequence $rec
    $resolvedAccount = Resolve-AppPxeBootTsLocalAccount -Account $localAccount
    $localUser = if ($resolvedAccount) { [string]$resolvedAccount.user } else { '' }
    $localAccountPw = if ($resolvedAccount) { [string]$resolvedAccount.pass } else { '' }
    # The {{LocalAdminPw}} token is only worth emitting if something will fill it.
    $legacyLocalPw = if ($role -eq 'server') { $ctx.serverAdmPw } else { $ctx.clientAdmPw }
    $accounts = Get-AppPxeBootTsOobeAccounts -AdminGroups @($rec.adminGroups | ForEach-Object { [string]$_ }) -EmitGroups $centralJoin `
        -LocalAccount $localAccount -LocalUser $localUser -LocalPassword $localAccountPw -LegacyLocalAdminAvailable ([bool]$legacyLocalPw)
    # OOBE skips: a field absent = default on (skip the screen); only an explicit '0' turns it off.
    $oobeBool = { param($k) -not ($rec.fields.Contains($k) -and [string]$rec.fields[$k] -eq '0') }
    $oobeShell = Get-AppPxeBootTsOobeShell -Accounts $accounts -Joining $joining -RegisteredOrg $regOrg -RegisteredOwner $regOwner `
        -HideEula (& $oobeBool 'oobeHideEula') -HideOnlineAccounts (& $oobeBool 'oobeHideOnline') -HideOemReg (& $oobeBool 'oobeHideOemReg') -HideWireless (& $oobeBool 'oobeHideWireless') -ExpressSettings (& $oobeBool 'oobeExpress')

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
	<settings pass="specialize">
$specialize	</settings>
	<settings pass="oobeSystem">
$intl$oobeShell	</settings>
</unattend>
"@

    # --- Publish-time token fills -----------------------------------------------
    $xml = $xml.Replace('{{JoinDomain}}', (ConvertTo-AppPxeBootTsXmlEscaped $joinDomainName))

    # Join credentials, three sources (Craig, 2026-08-22):
    #   blank            - fill at deploy time; the tokens stay literal and the WinPE
    #                      agent supplies one coherent credential. The default, and the
    #                      only one that puts nothing on the share.
    #   vault:<name>     - a credential read from the shared vault at publish time.
    #   the credential store id - the original path, kept as-is.
    # A join account is not a LAPS-rotated local account, so nothing is ever stored in
    # the sequence file itself: "typed here" writes to the vault and stores the name.
    $joinCredId = & $get 'joinCredential' ''
    if ($joining -and $joinCredId -like 'vault:*') {
        $secretName = $joinCredId.Substring(6).Trim()
        $cred = $null
        if ($secretName -and (Test-AppSidecarCommand Get-AppVaultCredential)) {
            $cred = Get-AppVaultCredential -Name $secretName
        }
        $vaultUser = if ($cred) { [string]$cred.UserName } else { '' }
        $vaultPass = if ($cred -and (Test-AppSidecarCommand Get-AppVaultPlainSecret)) {
            Get-AppVaultPlainSecret -Name $secretName
        } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($vaultUser) -and -not [string]::IsNullOrWhiteSpace($vaultPass) -and $vaultUser.Trim() -ne '') {
            $jDom = $joinDomainName
            if ($vaultUser -match '^(.+?)\\(.+)$') { $jDom = $matches[1]; $vaultUser = $matches[2] }
            elseif ($vaultUser -match '^(.+?)@(.+)$') { $vaultUser = $matches[1]; $jDom = $matches[2] }
            $xml = $xml.Replace('{{JoinDom}}', (ConvertTo-AppPxeBootTsXmlEscaped $jDom))
            $xml = $xml.Replace('{{JoinUser}}', (ConvertTo-AppPxeBootTsXmlEscaped $vaultUser))
            $xml = $xml.Replace('{{JoinPw}}', (ConvertTo-AppPxeBootTsXmlEscaped $vaultPass))
        } else {
            Write-SidecarLog "PXE boot: task sequence '$($rec.id)' vault secret '$secretName' is missing, empty, or has no user name - falling back to deploy-time fill"
        }
    } elseif ($joining -and $joinCredId) {
        try {
            $joinUser = Get-AppInfraSshCredentialLoginNameById -Id $joinCredId
            $joinPass = Get-AppInfraSshPlainPassword -Id $joinCredId
            if (-not [string]::IsNullOrWhiteSpace($joinUser) -and -not [string]::IsNullOrWhiteSpace($joinPass)) {
                $jDom = $joinDomainName
                if ($joinUser -match '^(.+?)\\(.+)$') { $jDom = $matches[1]; $joinUser = $matches[2] }
                elseif ($joinUser -match '^(.+?)@(.+)$') { $joinUser = $matches[1]; $jDom = $matches[2] }
                $xml = $xml.Replace('{{JoinDom}}', (ConvertTo-AppPxeBootTsXmlEscaped $jDom))
                $xml = $xml.Replace('{{JoinUser}}', (ConvertTo-AppPxeBootTsXmlEscaped $joinUser))
                $xml = $xml.Replace('{{JoinPw}}', (ConvertTo-AppPxeBootTsXmlEscaped $joinPass))
            } else {
                Write-SidecarLog "PXE boot: task sequence '$($rec.id)' join credential '$joinCredId' incomplete - falling back to deploy-time fill"
            }
        } catch {
            Write-SidecarLog "PXE boot: task sequence '$($rec.id)' join credential '$joinCredId' unavailable ($($_.Exception.Message)) - falling back to deploy-time fill"
        }
    }
    # Ambient-credential joins leave {{JoinDom}}/{{JoinUser}}/{{JoinPw}} ALL
    # deploy-time: the WinPE agent fills the full triplet from the operator who
    # armed the job, so the join is one coherent credential. (Never freeze the
    # PUBLISHER's identity and mix it with the DEPLOYER's password.)
    $localPw = $legacyLocalPw
    if ($localPw) { $xml = $xml.Replace('{{LocalAdminPw}}', (ConvertTo-AppPxeBootTsXmlEscaped $localPw)) }

    $xml
}


function Sync-AppPxeBootTaskSequenceStore {
    <#
    .SYNOPSIS
        Publish enabled sequences to <library>/TaskSequences/<id>.xml (Z:\TaskSequences
        over Deploy$). Prunes files for removed/disabled sequences. Deploy-time tokens
        stay literal - see the header comment; secrets never land on the share.
    #>
    $dir = Get-AppPxeBootTaskSequenceLibraryDir
    if (-not $dir) { return @{ published = 0; dir = $null } }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    # <library>/Scripts: first-boot scripts a Linux sequence can name; served by Caddy.
    try { $null = Initialize-AppPxeBootTsScriptsDir } catch {
        Write-SidecarLogVerbose "Task sequences: Scripts folder not created - $($_.Exception.Message)"
    }

    $published = 0
    $keep = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # autoinstall/<id>/ directories that belong to enabled Ubuntu sequences.
    $keepDirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $indexRows = @()
    # One cheap catalog read for the whole publish (cached edition lists, no mounting).
    $catalog = $null
    $httpPort = 0
    $lanIp = ''
    try {
        if (Test-AppSidecarCommand Get-AppPxeBootInstallImageCatalog) {
            $catalog = @(Get-AppPxeBootInstallImageCatalog)
            $cfg = Read-AppPxeBootConfig
            $httpPort = [int]$cfg.httpPort
            $lanIp = [string](Get-AppPxeBootLanIp)
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: install image catalog unavailable for publish - $($_.Exception.Message)"
    }
    foreach ($seq in @(Read-AppPxeBootTaskSequences)) {
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq
        if ($null -eq $rec -or -not [bool]$rec.enabled) { continue }
        # Ubuntu: cloud-init NoCloud wants a DIRECTORY - user-data + meta-data - fetched
        # from .../autoinstall/<id>/ (the trailing slash matters to cloud-init). LF only,
        # like the preseed. The keep sentinel <id>.autoinstall never matches a flat file.
        if ([string]$rec.platform -eq 'ubuntu') {
            $rendered = Build-AppPxeBootTaskSequenceAutoinstall -Sequence $rec
            if (-not $rendered) { continue }
            $aiDir = Join-Path (Join-Path $dir 'autoinstall') $rec.id
            if (-not (Test-Path -LiteralPath $aiDir)) { $null = New-Item -Path $aiDir -ItemType Directory -Force }
            $utf8 = New-Object System.Text.UTF8Encoding $false
            foreach ($pair in @(@{ name = 'user-data'; body = ($rendered -replace "`r`n", "`n") }, @{ name = 'meta-data'; body = "instance-id: wdk-$($rec.id)`n" })) {
                $target = Join-Path $aiDir $pair.name
                $have = if (Test-Path -LiteralPath $target) { Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue } else { $null }
                if ($have -ne $pair.body) { [System.IO.File]::WriteAllText($target, $pair.body, $utf8) }
            }
            [void]$keepDirs.Add([string]$rec.id)
            [void]$keep.Add("$($rec.id).autoinstall")
            $published++
            $indexRows += , [ordered]@{
                id              = [string]$rec.id
                name            = [string]$rec.name
                kind            = ''
                platform        = 'ubuntu'
                file            = "autoinstall/$($rec.id)/user-data"
                firstBootAction = ''
                image           = $null
            }
            continue
        }
        # Which answer file this sequence compiles to. Windows wants CRLF for
        # its own consumers; a preseed is read by the Debian installer and LF is
        # not optional there - d-i takes the CR as part of the value and a
        # trailing "\r" turns a hostname into one nobody can resolve.
        if ([string]$rec.platform -eq 'debian') {
            $rendered = Build-AppPxeBootTaskSequencePreseed -Sequence $rec
            $ext = 'cfg'
            $body = ($rendered -replace "`r`n", "`n")
        } else {
            $rendered = Build-AppPxeBootTaskSequenceUnattendXml -Sequence $rec
            $ext = 'xml'
            $body = ($rendered -replace "`r`n", "`n") -replace "`n", "`r`n"
        }
        if (-not $rendered) { continue }
        $file = Join-Path $dir "$($rec.id).$ext"
        # idempotent write (skip when unchanged)
        $have = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($have -ne $body) {
            [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding $false))
        }
        [void]$keep.Add("$($rec.id).$ext")
        $published++

        # index.json row: what the client needs BEFORE it applies anything. A row with
        # no image keeps the old behaviour (the tech picks the WIM at the device).
        $row = [ordered]@{
            id              = [string]$rec.id
            name            = [string]$rec.name
            kind            = [string]$rec.kind
            platform        = [string]$rec.platform
            file            = "$($rec.id).$ext"
            firstBootAction = (Get-AppPxeBootTsFirstBootAction -Sequence $rec)
            image           = $null
        }
        if ($rec.Contains('image')) {
            $resolved = $null
            try {
                $resolved = Resolve-AppPxeBootTaskSequenceImage -Image $rec.image -Catalog $catalog -HttpPort $httpPort -LanIp $lanIp
            } catch {
                Write-SidecarLogVerbose "PXE boot: image resolve failed for '$($rec.id)' - $($_.Exception.Message)"
            }
            if ($resolved) {
                $row.image = $resolved
            } else {
                # Media has gone away: publish what was chosen so the client can say
                # WHICH image is missing instead of silently falling back.
                $row.image = [ordered]@{
                    sourceId    = [string]$rec.image.sourceId
                    index       = [int]$rec.image.index
                    editionName = [string]$rec.image.editionName
                    missing     = $true
                }
            }
        }
        $indexRows += , $row

        # <id>.env - the same row, in the only shape a cmd-only client can read.
        # WinPE has no PowerShell and no JSON parser; `for /f "tokens=1,* delims=="`
        # is what the deploy client uses, so the panel writes KEY=VALUE and nothing
        # clever. index.json stays for clients that can parse it.
        $envLines = [System.Collections.Generic.List[string]]::new()
        [void]$envLines.Add("TS_ID=$($rec.id)")
        [void]$envLines.Add("TS_NAME=$($rec.name)")
        [void]$envLines.Add("TS_KIND=$($rec.kind)")
        [void]$envLines.Add("TS_UNATTEND=$($rec.id).xml")
        if ($rec.fields.Contains('win11Bypass') -and [string]$rec.fields['win11Bypass'] -eq '1') { [void]$envLines.Add("TS_WIN11BYPASS=1") }
        [void]$envLines.Add("TS_FINALE=$(Get-AppPxeBootTsFirstBootAction -Sequence $rec)")
        if ($row.image -and -not [bool]$row.image['missing']) {
            [void]$envLines.Add("TS_IMAGE=$($row.image.sharePath)")
            [void]$envLines.Add("TS_INDEX=$($row.image.index)")
            if ($row.image.editionName) { [void]$envLines.Add("TS_EDITION=$($row.image.editionName)") }
        }
        $envFile = Join-Path $dir "$($rec.id).env"
        # CRLF: cmd's `for /f` on a LF-only file leaves a stray CR in the last token.
        $envBody = (($envLines -join "`r`n") + "`r`n")
        $haveEnv = if (Test-Path -LiteralPath $envFile) { Get-Content -LiteralPath $envFile -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($haveEnv -ne $envBody) {
            [System.IO.File]::WriteAllText($envFile, $envBody, (New-Object System.Text.UTF8Encoding $false))
        }
        [void]$keep.Add("$($rec.id).env")

        # <id>.firstboot.cmd - the sequence's steps, run from SetupComplete by the client.
        $firstBoot = Get-AppPxeBootTsFirstBootScript -Sequence $rec
        $fbFile = Join-Path $dir "$($rec.id).firstboot.cmd"
        if ($firstBoot) {
            $haveFb = if (Test-Path -LiteralPath $fbFile) { Get-Content -LiteralPath $fbFile -Raw -ErrorAction SilentlyContinue } else { $null }
            if ($haveFb -ne $firstBoot) {
                [System.IO.File]::WriteAllText($fbFile, $firstBoot, (New-Object System.Text.UTF8Encoding $false))
            }
            [void]$keep.Add("$($rec.id).firstboot.cmd")
        }
    }
    # .cfg belongs here too, or a preseed for a deleted sequence would be left
    # on the share for ever, and a machine booted from a stale menu entry would
    # still install from it.
    foreach ($pattern in @('*.xml', '*.cfg', '*.env', '*.firstboot.cmd')) {
        foreach ($existing in @(Get-ChildItem -LiteralPath $dir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
            if (-not $keep.Contains($existing.Name)) {
                Remove-Item -LiteralPath $existing.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # autoinstall/<id>/ for a removed or disabled Ubuntu sequence goes the same way.
    $aiRoot = Join-Path $dir 'autoinstall'
    if (Test-Path -LiteralPath $aiRoot -PathType Container) {
        foreach ($existingDir in @(Get-ChildItem -LiteralPath $aiRoot -Directory -ErrorAction SilentlyContinue)) {
            if (-not $keepDirs.Contains($existingDir.Name)) {
                Remove-Item -LiteralPath $existingDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # convert-eval.ps1 - the server eval->licensed script the deploy client copies into
    # C:\Windows\Setup\Scripts on a server deploy (it no-ops on a non-evaluation image).
    # Written here, once, so it rides the same Deploy$ share as the sequences.
    if (Test-AppSidecarCommand Get-AppServerEvalConversionPayload) {
        try {
            $convFile = Join-Path $dir 'convert-eval.ps1'
            $convBody = ((Get-AppServerEvalConversionPayload) -replace "`r`n", "`n") -replace "`n", "`r`n"
            $haveConv = if (Test-Path -LiteralPath $convFile) { Get-Content -LiteralPath $convFile -Raw -ErrorAction SilentlyContinue } else { $null }
            if ($haveConv -ne $convBody) {
                [System.IO.File]::WriteAllText($convFile, $convBody, (New-Object System.Text.UTF8Encoding $false))
            }
            [void]$keep.Add('convert-eval.ps1')
        } catch {
            Write-SidecarLogVerbose "PXE boot: convert-eval.ps1 publish failed - $($_.Exception.Message)"
        }
    }

    # index.json - the machine-readable half of the share. The *.xml files stay exactly
    # as they were (a client that only globs *.xml keeps working); this adds the image
    # binding, which a client cannot infer from an unattend.
    $indexFile = Join-Path $dir 'index.json'
    if ($indexRows.Count -gt 0) {
        $indexBody = ([ordered]@{
                schema            = 1
                updatedAt         = (Get-Date).ToUniversalTime().ToString('o')
                defaultSequenceId = [string](Get-AppPxeBootTaskSequenceDefaultId)
                sequences         = $indexRows
            } | ConvertTo-Json -Depth 8)
        $haveIndex = if (Test-Path -LiteralPath $indexFile) { Get-Content -LiteralPath $indexFile -Raw -ErrorAction SilentlyContinue } else { $null }
        # updatedAt alone must not rewrite the file on every save (the share is watched).
        $stripStamp = { param($s) if ($s) { [regex]::Replace([string]$s, '"updatedAt":\s*"[^"]*"', '"updatedAt":""') } else { '' } }
        if ((& $stripStamp $haveIndex) -ne (& $stripStamp $indexBody)) {
            [System.IO.File]::WriteAllText($indexFile, $indexBody, (New-Object System.Text.UTF8Encoding $false))
        }
    } elseif (Test-Path -LiteralPath $indexFile) {
        Remove-Item -LiteralPath $indexFile -Force -ErrorAction SilentlyContinue
    }

    # _default.txt preselects the client menu (touch-free deploys). Written
    # only when the default resolves to a published file; a dangling default is
    # pruned rather than preselecting a missing sequence (no marker = None item).
    $marker = Join-Path $dir '_default.txt'
    $default = Get-AppPxeBootTaskSequenceDefaultId
    $defaultValid = [bool]($default -and ($keep.Contains("$default.xml") -or $keep.Contains("$default.cfg") -or $keep.Contains("$default.autoinstall")))
    if ($defaultValid) {
        $want = $default + "`r`n"
        $have = if (Test-Path -LiteralPath $marker) { Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($have -ne $want) {
            [System.IO.File]::WriteAllText($marker, $want, (New-Object System.Text.UTF8Encoding $false))
        }
    } elseif (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
    @{ published = $published; dir = $dir }
}

# --- Debian preseed -----------------------------------------------------------
#
# A preseed is the direct equivalent of unattend.xml: the answer file the
# installer reads so nobody stands at the machine. The differences from the
# Windows path are worth knowing before editing this.
#
#   * Selection happens at BOOT, not after it. WinPE shows a picker and copies
#     the chosen XML to Panther; d-i is told `preseed/url=` on the kernel command
#     line, so the PXE menu entry decides which sequence a machine gets.
#   * There is no deploy-time client, so the {{SITE}}/{{SERIAL}} half of the
#     Windows token model has no counterpart. Anything that must be computed per
#     machine is shell in late_command, which is why the hostname can be derived
#     from the MAC there rather than substituted here.
#   * SECRETS CANNOT BE WITHHELD. The Windows publisher deliberately leaves
#     {{JoinPw}} in the file for the client to fill, so a join password never
#     lands on the share. An unauthenticated installer fetching a preseed over
#     HTTP cannot do that: everything in this file is readable by anything that
#     can reach the URL. Passwords go in as crypt(3) hashes and nothing else
#     sensitive goes in at all.
#   * The mirror is deliberately absent. The PXE menu already points d-i at the
#     mounted ISO with mirror/http/*; repeating it here would fight those kernel
#     arguments and send the installer to the internet instead of the ISO.
#
# late_command is the SetupComplete.cmd of this world: it runs late in the
# install with the new system at /target, and `in-target` runs a command inside
# it. The pattern below - drop a script, register a one-shot systemd unit that
# disables itself - is the one CampusCast's own preseed uses in production.

function New-AppPxeBootTsCryptSalt {
    # 16 characters from crypt's alphabet, from the platform CSPRNG.
    $alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return (-join ($bytes | ForEach-Object { $alphabet[$_ % 64] }))
}

function ConvertTo-AppPxeBootTsSha512Crypt {
    <#
    .SYNOPSIS
        crypt(3) SHA-512 ("$6$..."), the form d-i's passwd/user-password-crypted takes.
        Drepper's algorithm at the default 5000 rounds, in pure .NET so it runs the same
        on macOS and Windows (openssl passwd -6 is not on Windows).
    .NOTES
        Verified against the specification's reference vector and LibreSSL's
        openssl passwd -6 in test-task-sequence-debian.ps1.
    #>
    param(
        [Parameter(Mandatory)][string]$Password,
        [string]$Salt
    )
    if ([string]::IsNullOrEmpty($Salt)) { $Salt = New-AppPxeBootTsCryptSalt }
    $Salt = ($Salt -replace '[^./0-9A-Za-z]', '')
    if ($Salt.Length -gt 16) { $Salt = $Salt.Substring(0, 16) }
    # $keyBytes/$saltBytes, never $keyBytes/$saltBytes: variable names are case-insensitive, and
    # assigning bytes to the [string] parameter $Salt would stringify them.
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $saltBytes = [System.Text.Encoding]::UTF8.GetBytes($Salt)
    $join = {
        param($parts)
        $ms = New-Object System.IO.MemoryStream
        foreach ($p in $parts) { $b = [byte[]]$p; if ($b.Length -gt 0) { $ms.Write($b, 0, $b.Length) } }
        , $ms.ToArray()
    }
    $stretch = {
        # D repeated to exactly $len bytes.
        param([byte[]]$D, [int]$len)
        $out = New-Object byte[] $len
        for ($i = 0; $i -lt $len; $i++) { $out[$i] = $D[$i % 64] }
        , $out
    }
    $sha = [System.Security.Cryptography.SHA512]::Create()
    try {
        # B = H(key salt key)
        $B = $sha.ComputeHash((& $join @($keyBytes, $saltBytes, $keyBytes)))
        # A = H(key salt B-by-keylen <B or key per keylen bits>)
        $aParts = [System.Collections.Generic.List[byte[]]]::new()
        $aParts.Add($keyBytes); $aParts.Add($saltBytes)
        $n = $keyBytes.Length
        while ($n -gt 64) { $aParts.Add($B); $n -= 64 }
        if ($n -gt 0) { $aParts.Add([byte[]]$B[0..($n - 1)]) }
        for ($cnt = $keyBytes.Length; $cnt -gt 0; $cnt = $cnt -shr 1) {
            if ($cnt -band 1) { $aParts.Add($B) } else { $aParts.Add($keyBytes) }
        }
        $A = $sha.ComputeHash((& $join $aParts.ToArray()))
        # DP = H(key x keylen), P = DP stretched to keylen
        $dpParts = [System.Collections.Generic.List[byte[]]]::new()
        for ($i = 0; $i -lt $keyBytes.Length; $i++) { $dpParts.Add($keyBytes) }
        $DP = $sha.ComputeHash((& $join $dpParts.ToArray()))
        $P = & $stretch $DP $keyBytes.Length
        # DS = H(salt x (16 + A[0])), S = DS stretched to saltlen
        $dsParts = [System.Collections.Generic.List[byte[]]]::new()
        for ($i = 0; $i -lt (16 + [int]$A[0]); $i++) { $dsParts.Add($saltBytes) }
        $DS = $sha.ComputeHash((& $join $dsParts.ToArray()))
        $S = & $stretch $DS $saltBytes.Length
        $C = $A
        for ($i = 0; $i -lt 5000; $i++) {
            $parts = [System.Collections.Generic.List[byte[]]]::new()
            if ($i -band 1) { $parts.Add($P) } else { $parts.Add($C) }
            if ($i % 3) { $parts.Add($S) }
            if ($i % 7) { $parts.Add($P) }
            if ($i -band 1) { $parts.Add($C) } else { $parts.Add($P) }
            $C = $sha.ComputeHash((& $join $parts.ToArray()))
        }
    } finally {
        $sha.Dispose()
    }
    $alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $sb = [System.Text.StringBuilder]::new()
    $emit = {
        param([int]$b2, [int]$b1, [int]$b0, [int]$count)
        $w = ($b2 -shl 16) -bor ($b1 -shl 8) -bor $b0
        for ($k = 0; $k -lt $count; $k++) { [void]$sb.Append($alphabet[$w -band 63]); $w = $w -shr 6 }
    }
    foreach ($t in @(@(0, 21, 42), @(22, 43, 1), @(44, 2, 23), @(3, 24, 45), @(25, 46, 4), @(47, 5, 26), @(6, 27, 48),
            @(28, 49, 7), @(50, 8, 29), @(9, 30, 51), @(31, 52, 10), @(53, 11, 32), @(12, 33, 54), @(34, 55, 13),
            @(56, 14, 35), @(15, 36, 57), @(37, 58, 16), @(59, 17, 38), @(18, 39, 60), @(40, 61, 19), @(62, 20, 41))) {
        & $emit ([int]$C[$t[0]]) ([int]$C[$t[1]]) ([int]$C[$t[2]]) 4
    }
    & $emit 0 0 ([int]$C[63]) 2
    return ('$6$' + $Salt + '$' + $sb.ToString())
}

function ConvertTo-AppPxeBootTsLinuxUserName {
    # user-setup accepts ^[a-z][-a-z0-9_]*$ - a vault login like CORP\Local.Admin becomes localadmin.
    param([string]$Name)
    $n = [string]$Name
    if ($n -match '^(.+)\\(.+)$') { $n = $matches[2] }
    if ($n -match '^(.+)@(.+)$') { $n = $matches[1] }
    $n = ($n.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
    $n = $n.TrimStart('-', '_', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
    return $n
}

function Resolve-AppPxeBootTsDebianVaultUser {
    <#
    .SYNOPSIS
        The first user from a vault credential: @{ username; fullName; crypted }, or $null.
        The password is hashed here, at publish; nothing in clear reaches the share.
    #>
    param([string]$SecretName)
    if ([string]::IsNullOrWhiteSpace($SecretName)) { return $null }
    if (-not (Test-AppSidecarCommand Get-AppVaultCredential) -or -not (Test-AppSidecarCommand Get-AppVaultPlainSecret)) { return $null }
    $cred = Get-AppVaultCredential -Name $SecretName
    if (-not $cred) {
        Write-SidecarLog "Task sequences: vault credential '$SecretName' is missing - Debian first user not set, the installer will ask"
        return $null
    }
    $login = [string](Get-AppPxeBootTsProp -Item $cred -Name 'UserName')
    $username = ConvertTo-AppPxeBootTsLinuxUserName -Name $login
    $plain = [string](Get-AppVaultPlainSecret -Name $SecretName)
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrEmpty($plain)) {
        Write-SidecarLog "Task sequences: vault credential '$SecretName' has no usable user/password - Debian first user not set"
        return $null
    }
    $fullName = ''
    try {
        if (Test-AppSidecarCommand Get-AppVaultSecretInfo) {
            $info = Get-AppVaultSecretInfo -Name $SecretName
            $fullName = [string](Get-AppPxeBootTsProp -Item $info -Name 'fullName')
            if ([string]::IsNullOrWhiteSpace($fullName)) { $fullName = [string](Get-AppPxeBootTsProp -Item $info -Name 'label') }
        }
    } catch { $fullName = '' }
    if ([string]::IsNullOrWhiteSpace($fullName)) { $fullName = $username }
    if ($username -ne $login) { Write-SidecarLogVerbose "Task sequences: vault login '$login' becomes Linux user '$username'" }
    return @{ username = $username; fullName = $fullName; crypted = (ConvertTo-AppPxeBootTsSha512Crypt -Password $plain) }
}

function Get-AppPxeBootTsScriptsDir {
    # <library>/Scripts: first-boot scripts, served by Caddy at /Scripts/ and visible on Deploy$.
    try {
        $root = Get-AppImageLibraryRoot -NoCreate
        if ($root) { return (Join-Path $root 'Scripts') }
    } catch { }
    return $null
}

function Get-AppPxeBootTsFirstBootScripts {
    # File names the panel offers for "First-boot script". Anything regular except the README.
    $dir = Get-AppPxeBootTsScriptsDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(README|readme)' -and $_.Name -notmatch '^\.' } |
        Sort-Object Name | ForEach-Object { $_.Name })
}

function Initialize-AppPxeBootTsScriptsDir {
    # <library>/Scripts, created with its README on first use. Null without a library root.
    $dir = Get-AppPxeBootTsScriptsDir
    if (-not $dir) { return $null }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
        $readme = Join-Path $dir 'README.txt'
        [System.IO.File]::WriteAllText($readme, ("First-boot scripts for Linux task sequences.`n" +
            "Add one from the sequence editor (First-boot script > Add...) or drop it here (for example firstboot.sh)`n" +
            "and pick it as the sequence's First-boot script. It needs a #! first line - systemd runs it directly.`n" +
            "The installer fetches it from this machine over HTTP (/Scripts/<name>) at the end of the install`n" +
            "and runs it once at first boot through a one-shot systemd unit, as root, with the network up.`n"), (New-Object System.Text.UTF8Encoding $false))
    }
    return $dir
}

function Test-AppPxeBootTsScriptFileName {
    # The name the compiler accepts for runScriptFile, minus the README and dotfiles the
    # listing hides: a wrong name here would be offered by the panel and skipped at publish.
    param([string]$Name)
    $n = [string]$Name
    ($n -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') -and ($n -notmatch '^(README|readme)') -and ($n.Length -le 120)
}

function Import-AppPxeBootTsScript {
    <#
        .SYNOPSIS
        Copy a script from this machine into <library>/Scripts so a Linux sequence can
        name it. The copy is checked the way the target will read it: a #! first line
        (systemd execs the file - without one the first boot silently does nothing),
        text not binary, and LF line endings (a CRLF shebang is "bash\r: not found").
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetFileName,
        [switch]$ReplaceExisting
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Task sequences: source script not found.' }
    $src = Get-Item -LiteralPath $SourcePath
    $name = if ($TargetFileName) { ([string]$TargetFileName).Trim() } else { $src.Name }
    if (-not (Test-AppPxeBootTsScriptFileName -Name $name)) {
        throw "Task sequences: script name '$name' - letters, digits, dot, dash and underscore only, no spaces, not README."
    }
    if ($src.Length -gt 8MB) { throw "Task sequences: $name is over 8 MB - that is not a script; host it and use a custom URL." }
    $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { throw "Task sequences: $name is a binary file, not a script." }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $normalized = $false
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1); $normalized = $true }
    if ($text.Contains("`r")) { $text = ($text -replace "`r`n", "`n") -replace "`r", "`n"; $normalized = $true }
    if (-not $text.StartsWith('#!')) {
        throw "Task sequences: $name has no #! first line. systemd runs the script directly, so it needs one - for example #!/bin/bash."
    }
    $dir = Initialize-AppPxeBootTsScriptsDir
    if (-not $dir) { throw 'Task sequences: no image library root is set, so there is no Scripts folder yet.' }
    $dest = Join-Path $dir $name
    $existed = Test-Path -LiteralPath $dest -PathType Leaf
    if ($existed -and -not $ReplaceExisting) { throw "Task sequences: $name is already in the Scripts folder." }
    [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding $false))
    $url = try { "$(Get-AppPxeBootTsScriptsBaseUrl)/$name" } catch { '' }
    Write-SidecarLog ("Task sequences: first-boot script $name ($($bytes.Length) bytes) copied into the Scripts folder" +
        $(if ($normalized) { ' (BOM/CRLF normalised to plain LF)' } else { '' }))
    @{
        fileName   = $name
        path       = $dest
        url        = $url
        sizeBytes  = (Get-Item -LiteralPath $dest).Length
        replaced   = [bool]$existed
        normalized = $normalized
        scripts    = @(Get-AppPxeBootTsFirstBootScripts)
        scriptsDir = $dir
    }
}

function Remove-AppPxeBootTsScript {
    # Delete a library first-boot script. A sequence still naming it shows "missing" in
    # the panel and publishes without a fetch line (the compiler refuses unknown names).
    param([Parameter(Mandatory)][string]$FileName)
    if (-not (Test-AppPxeBootTsScriptFileName -Name $FileName)) { throw "Task sequences: '$FileName' is not a library script name." }
    $dir = Get-AppPxeBootTsScriptsDir
    $removed = $false
    if ($dir) {
        $path = Join-Path $dir $FileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            $removed = $true
            Write-SidecarLog "Task sequences: first-boot script $FileName removed from the Scripts folder"
        }
    }
    @{ fileName = $FileName; removed = $removed; scripts = @(Get-AppPxeBootTsFirstBootScripts); scriptsDir = $dir }
}

function Open-AppPxeBootTsScriptsFolder {
    $path = Initialize-AppPxeBootTsScriptsDir
    if (-not $path) { throw 'Task sequences: no image library root is set, so there is no Scripts folder yet.' }
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } elseif ($IsMacOS) {
        Start-Process -FilePath 'open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path))
    } else {
        Start-Process -FilePath 'xdg-open' -ArgumentList (Format-AppProcessArgumentList -Arguments @($path)) -ErrorAction SilentlyContinue
    }
    @{ opened = $true; path = $path }
}

function Get-AppPxeBootTsScriptsBaseUrl {
    # Where a target fetches a library script from: this laptop's Caddy. Resolved at
    # publish, and publish runs on every Start / menu regen, so the LAN IP stays current.
    if (Test-AppSidecarCommand Get-AppPxeBootLocalHttpBaseUrl) {
        return ((Get-AppPxeBootLocalHttpBaseUrl) + '/Scripts')
    }
    return 'http://localhost:8080/Scripts'
}

function ConvertTo-AppPxeBootTsShellSingleQuoted {
    <#
        .SYNOPSIS
        Quote a value for POSIX sh. Single quotes, with the close-reopen dance
        for embedded single quotes, so a value can never end the string early.
    #>
    param([string]$Value)
    "'" + ([string]$Value -replace "'", "'\''") + "'"
}

function Get-AppPxeBootTsLateCommandParts {
    <#
        .SYNOPSIS
        The sequence's steps and run script as one d-i late_command.

        .DESCRIPTION
        Only cmd steps make sense here: reg and pwsh are Windows verbs and are
        skipped rather than silently mistranslated. Every command runs in-target,
        so it sees the installed system and not the installer's ramdisk, and
        through bash -c (Craig, 2026-09-06): bash is Essential on Debian and in the
        Ubuntu server base, so it is always in /target by late_command time, people
        type bash syntax, and every sh one-liner runs unchanged under it. The fetch
        line above stays sh: it is ours and POSIX.
    #>
    param([Parameter(Mandatory)]$Sequence)

    $parts = @()
    $flds = $Sequence.fields
    $runUrl = if ($flds -and $flds.Contains('runScriptUrl')) { ([string]$flds['runScriptUrl']).Trim() } else { '' }
    # runScriptFile: '' = none (a legacy runScriptUrl alone still counts), 'url' = the
    # free URL in runScriptUrl, anything else = a file in <library>/Scripts served by Caddy.
    $runFile = if ($flds -and $flds.Contains('runScriptFile')) { ([string]$flds['runScriptFile']).Trim() } else { '' }
    if ($runFile -and $runFile -ne 'url') {
        if ($runFile -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $runUrl = "$(Get-AppPxeBootTsScriptsBaseUrl)/$runFile"
        } else {
            Write-SidecarLog "Task sequences: first-boot script name '$runFile' is not a plain file name - skipped"
            $runUrl = ''
        }
    }
    if ($runUrl) {
        # Fetched at install time rather than embedded, so the script can change
        # without republishing every sequence that uses it. Failure is loud: a
        # first-boot script that silently did not run is the worst outcome.
        #
        # Quote the WHOLE inner command once, never the URL separately. Quoting a
        # value inside an already single-quoted sh -c string closes that string
        # early, and the result still contains every substring a naive test looks
        # for while being a different command entirely.
        # Two levels of quoting, both needed. The URL is quoted for the shell that
        # runs inside sh -c, and the whole payload is quoted again for the shell
        # that reads the late_command line. Getting only the outer level right
        # leaves an ampersand in a URL backgrounding half the command.
        $fetch = "set -e; wget -qO /usr/local/sbin/wdk-run " +
                 (ConvertTo-AppPxeBootTsShellSingleQuoted $runUrl) +
                 "; chmod 0755 /usr/local/sbin/wdk-run"
        $parts += "in-target sh -c $(ConvertTo-AppPxeBootTsShellSingleQuoted $fetch)"
        $parts += @'
printf '[Unit]\nDescription=WinDeployKit first boot\nAfter=network-online.target\nWants=network-online.target\nConditionPathExists=/usr/local/sbin/wdk-run\n\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/wdk-run\nExecStartPost=/bin/systemctl disable wdk-firstboot.service\nRemainAfterExit=yes\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' > /target/etc/systemd/system/wdk-firstboot.service
'@
        $parts += 'in-target systemctl enable wdk-firstboot.service'
    }
    foreach ($step in @($Sequence.steps)) {
        if ([string]$step.type -ne 'cmd') { continue }
        $cmd = ([string]$step.command).Trim()
        if (-not $cmd) { continue }
        $parts += "in-target bash -c $(ConvertTo-AppPxeBootTsShellSingleQuoted $cmd)"
    }
    # Emitted, not wrapped: a `, $parts` here reaches a caller @() as ONE nested array.
    return $parts
}

function Build-AppPxeBootTaskSequencePreseedLateCommand {
    # d-i takes one logical line.
    param([Parameter(Mandatory)]$Sequence)
    $parts = @(Get-AppPxeBootTsLateCommandParts -Sequence $Sequence)
    if ($parts.Count -eq 0) { return '' }
    ($parts -join '; ')
}

function ConvertTo-AppPxeBootTsYamlSingleQuoted {
    # YAML single-quoted scalar: the only escape is '' for a literal quote, so a shell
    # payload full of quotes and backslashes survives untouched.
    param([string]$Value)
    "'" + ([string]$Value -replace "'", "''") + "'"
}

function Build-AppPxeBootTaskSequenceAutoinstallLateCommands {
    <#
    .SYNOPSIS
        The same first-boot parts as the Debian late_command, one per Subiquity
        late-command. d-i's in-target is curtin's `curtin in-target --target=/target --`;
        a part that writes to /target/... directly works unchanged (Subiquity mounts the
        new system there too).
    #>
    param([Parameter(Mandatory)]$Sequence)
    $out = @()
    foreach ($part in @(Get-AppPxeBootTsLateCommandParts -Sequence $Sequence)) {
        $p = [string]$part
        if ($p -match '^in-target (.*)$') { $p = 'curtin in-target --target=/target -- ' + $matches[1] }
        $out += $p
    }
    return $out
}

function Build-AppPxeBootTaskSequenceAutoinstall {
    <#
    .SYNOPSIS
        Render a Subiquity autoinstall (cloud-init NoCloud user-data) for one sequence.
    .DESCRIPTION
        Ubuntu 22.04+ has no d-i: the live-server ISO's installer reads an autoinstall
        YAML from the NoCloud seed named on the kernel line (ds=nocloud-net;s=<url>/).
        Same rules as the preseed: publish-time values only, the password is a crypt
        hash, no apt mirror block (the installer's default archive is the point), and
        nothing sensitive beyond the hash.
    #>
    param([Parameter(Mandatory)]$Sequence)
    if ([string]$Sequence.platform -ne 'ubuntu') { return '' }
    $flds = $Sequence.fields
    $f = {
        param($n, $d = '')
        $v = if ($flds -and $flds.Contains($n)) { ([string]$flds[$n]).Trim() } else { '' }
        if ($v) { $v } else { $d }
    }
    $q = { param($v) ConvertTo-AppPxeBootTsYamlSingleQuoted ([string]$v) }

    $hostname  = & $f 'hostname'   'ubuntu'
    $locale    = & $f 'locale'     'en_AU.UTF-8'
    $keymap    = & $f 'keymap'     'us'
    $timezone  = & $f 'timezone'   'Australia/Melbourne'
    $username  = & $f 'username'   'localadmin'
    $fullName  = & $f 'userFullName' 'Local Administrator'
    $pwCrypt   = & $f 'userPasswordCrypted'
    if ((& $f 'userSource' 'manual') -eq 'vault') {
        $vaultUser = Resolve-AppPxeBootTsDebianVaultUser -SecretName (& $f 'userVaultSecret')
        if ($vaultUser) {
            $username = [string]$vaultUser.username
            $fullName = [string]$vaultUser.fullName
            $pwCrypt  = [string]$vaultUser.crypted
        } else {
            $pwCrypt = ''
        }
    }
    $disk      = & $f 'disk'       '/dev/nvme0n1 /dev/sda /dev/mmcblk0'
    $layout    = & $f 'storageLayout' 'direct'
    if ($layout -notin @('direct', 'lvm')) { $layout = 'direct' }
    $packages  = @(((& $f 'packages' '') -split '\s+') | Where-Object { $_ })
    $sshServer = (& $f 'sshServer' '1') -ne '0'
    $late      = @(Build-AppPxeBootTaskSequenceAutoinstallLateCommands -Sequence $Sequence)
    # The Debian disk field is an ordered list of candidates; Subiquity's match takes one
    # path, so a single device becomes path: and a list becomes the largest disk.
    $disks = @(($disk -split '\s+') | Where-Object { $_ })

    $lines = [System.Collections.Generic.List[string]]::new()
    $add = { param($t) [void]$lines.Add($t) }
    & $add '#cloud-config'
    & $add "# WinDeployKit task sequence: $($Sequence.name)"
    & $add '# Generated - edit the sequence, not this file.'
    & $add 'autoinstall:'
    & $add '  version: 1'
    & $add '  refresh-installer:'
    & $add '    update: false'
    & $add "  locale: $(& $q $locale)"
    & $add '  keyboard:'
    & $add "    layout: $(& $q $keymap)"
    & $add "  timezone: $(& $q $timezone)"
    if ($pwCrypt) {
        & $add '  identity:'
        & $add "    hostname: $(& $q $hostname)"
        & $add "    username: $(& $q $username)"
        & $add "    realname: $(& $q $fullName)"
        & $add "    password: $(& $q $pwCrypt)"
    } else {
        & $add '  # No password hash set on this sequence: the installer asks for the user.'
        & $add '  interactive-sections:'
        & $add '    - identity'
    }
    & $add '  ssh:'
    & $add "    install-server: $(if ($sshServer) { 'true' } else { 'false' })"
    & $add '    allow-pw: true'
    & $add '  storage:'
    & $add '    layout:'
    & $add "      name: $layout"
    & $add '      match:'
    if ($disks.Count -eq 1) {
        & $add "        path: $(& $q $disks[0])"
    } else {
        & $add '        size: largest'
    }
    if ($packages.Count -gt 0) {
        & $add '  packages:'
        foreach ($p in $packages) { & $add "    - $(& $q $p)" }
    }
    & $add '  updates: security'
    if ($late.Count -gt 0) {
        & $add '  late-commands:'
        foreach ($c in $late) { & $add "    - $(& $q $c)" }
    }
    & $add '  shutdown: reboot'
    ($lines -join "`n") + "`n"
}

function Build-AppPxeBootTaskSequencePreseed {
    <#
        .SYNOPSIS
        Render a Debian preseed for one sequence.

        .DESCRIPTION
        Publish-time only. Every value is concrete by the time this is written to
        the library, because there is nothing downstream to substitute tokens.
    #>
    param([Parameter(Mandatory)]$Sequence)

    if ([string]$Sequence.platform -ne 'debian') { return '' }
    $flds = $Sequence.fields
    $f = {
        param($n, $d = '')
        $v = if ($flds -and $flds.Contains($n)) { ([string]$flds[$n]).Trim() } else { '' }
        if ($v) { $v } else { $d }
    }

    $hostname  = & $f 'hostname'   'debian'
    $domain    = & $f 'domain'     'local'
    $locale    = & $f 'locale'     'en_AU.UTF-8'
    $keymap    = & $f 'keymap'     'us'
    $timezone  = & $f 'timezone'   'Australia/Melbourne'
    $username  = & $f 'username'   'localadmin'
    $fullName  = & $f 'userFullName' 'Local Administrator'
    $pwCrypt   = & $f 'userPasswordCrypted'
    # First user from the vault (Craig, 2026-09-06): the credential's login becomes the
    # user, its full name the GECOS, and its password is hashed at publish. A vault
    # entry that cannot be resolved leaves the password out, so the installer asks
    # rather than creating a user nobody can log in as.
    if ((& $f 'userSource' 'manual') -eq 'vault') {
        $vaultUser = Resolve-AppPxeBootTsDebianVaultUser -SecretName (& $f 'userVaultSecret')
        if ($vaultUser) {
            $username = [string]$vaultUser.username
            $fullName = [string]$vaultUser.fullName
            $pwCrypt  = [string]$vaultUser.crypted
        } else {
            $pwCrypt = ''
        }
    }
    $disk      = & $f 'disk'       '/dev/nvme0n1 /dev/sda /dev/mmcblk0'
    $recipe    = & $f 'partitionRecipe' 'atomic'
    $packages  = & $f 'packages'   ''
    $late      = Build-AppPxeBootTaskSequencePreseedLateCommand -Sequence $Sequence

    # partman-auto's built-in recipes. trixie added server and small_disk; atomic there
    # needs about 10 GB (768 MB EFI + 768 MB /boot + 8 GB / + swap) - a smaller disk fails
    # with "Unable to satisfy all constraints", which is what small_disk is for.
    if ($recipe -notin @('atomic', 'home', 'multi', 'server', 'small_disk')) { $recipe = 'atomic' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $add = { param($t) [void]$lines.Add($t) }
    & $add "# WinDeployKit task sequence: $($Sequence.name)"
    & $add "# Generated - edit the sequence, not this file."
    & $add ''
    & $add "d-i debian-installer/locale string $locale"
    & $add "d-i keyboard-configuration/xkb-keymap select $keymap"
    & $add ''
    & $add 'd-i netcfg/choose_interface select auto'
    & $add 'd-i netcfg/dhcp_timeout string 60'
    & $add "d-i netcfg/get_hostname string $hostname"
    & $add "d-i netcfg/get_domain string $domain"
    & $add "d-i netcfg/hostname string $hostname"
    & $add ''
    & $add '# No mirror block on purpose: the PXE menu already points d-i at the'
    & $add '# mounted ISO with mirror/http/*, and repeating it here would override it.'
    & $add ''
    & $add 'd-i passwd/root-login boolean false'
    & $add 'd-i passwd/make-user boolean true'
    & $add "d-i passwd/user-fullname string $fullName"
    & $add "d-i passwd/username string $username"
    if ($pwCrypt) {
        & $add "d-i passwd/user-password-crypted password $pwCrypt"
    } else {
        & $add '# No password hash set on this sequence: the installer will ask.'
    }
    & $add 'd-i passwd/user-default-groups string audio cdrom video dip plugdev netdev sudo'
    & $add ''
    & $add 'd-i clock-setup/utc boolean true'
    & $add "d-i time/zone string $timezone"
    & $add 'd-i clock-setup/ntp boolean true'
    & $add ''
    & $add 'd-i partman-auto/method string regular'
    & $add "d-i partman-auto/choose_recipe select $recipe"
    & $add "d-i partman-auto/disk string $disk"
    & $add 'd-i partman-lvm/device_remove_lvm boolean true'
    & $add 'd-i partman-md/device_remove_md boolean true'
    & $add 'd-i partman/default_filesystem string ext4'
    & $add 'd-i partman-partitioning/confirm_write_new_label boolean true'
    & $add 'd-i partman/choose_partition select finish'
    & $add 'd-i partman/confirm boolean true'
    & $add 'd-i partman/confirm_nooverwrite boolean true'
    # The machine PXE-booted in UEFI mode and gets a UEFI install. Without this d-i
    # stops to ask "Force UEFI installation?" whenever it spots another OS installed
    # in BIOS mode on any disk (seen 2026-09-06 in the QEMU run: the iPXE boot disk).
    & $add 'd-i partman-efi/non_efi_system boolean true'
    & $add ''
    & $add 'tasksel tasksel/first multiselect standard'
    if ($packages) { & $add "d-i pkgsel/include string $packages" }
    & $add 'popularity-contest popularity-contest/participate boolean false'
    & $add ''
    & $add 'd-i grub-installer/only_debian boolean true'
    & $add 'd-i grub-installer/bootdev string default'
    & $add ''
    & $add 'd-i finish-install/reboot_in_progress note'
    if ($late) {
        & $add ''
        & $add "d-i preseed/late_command string $late"
    }
    ($lines -join "`n") + "`n"
}


function Get-AppPxeBootTaskSequencesPayload {
    $sequences = @(Read-AppPxeBootTaskSequences | ForEach-Object { ConvertTo-AppPxeBootTaskSequenceRecord -Item $_ } | Where-Object { $_ })
    $dir = Get-AppPxeBootTaskSequenceLibraryDir
    $publishedFiles = @()
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        $publishedFiles = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.xml', '.cfg') } | ForEach-Object { $_.Name })
        $aiRoot = Join-Path $dir 'autoinstall'
        if (Test-Path -LiteralPath $aiRoot -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $aiRoot -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $d.FullName 'user-data') -PathType Leaf) { $publishedFiles += "$($d.Name).autoinstall" }
            }
        }
    }
    # Join-domain options come from the Site Profile. Guard against wrapper leaks:
    # a store that wraps entries as @{value; userLocked; updatedAt} must be
    # unwrapped before display (field bug 2026-08-20 leaked the whole wrapper).
    # Discovered from this host's DNS - the join field offers them, it does not force one.
    $joinDomainSuggestions = @(Get-AppPxeBootTsDomainSuggestions)
    $joinDomainOptions = @()  # TODO(Site Profile): seeded from the Site Profile join domains
    try {
        $sp = if (Test-AppSidecarCommand Get-AppSiteProfile) { Get-AppSiteProfile } else { $null }
        foreach ($d in @($sp.joinDomains)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$d) -and $joinDomainOptions -notcontains [string]$d) {
                $joinDomainOptions += [string]$d
            }
        }
    } catch { }

    # Machine-OU options from the Site Profile: the configured machine OUs,
    # labelled by their first RDN (e.g. "Computers Administration").
    $machineOuOptions = @()
    try {
        $sp2 = if (Test-AppSidecarCommand Get-AppSiteProfile) { Get-AppSiteProfile } else { $null }
        foreach ($dnRaw in @($sp2.machineOus)) {
            $dn = [string]$dnRaw
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            $label = (($dn -split ',')[0] -replace '^(?i)OU=', '').Trim()
            $machineOuOptions += @{ dn = $dn; label = $label }
        }
    } catch { }

    # OU suggestion: reverse the join domain into DN form with the AD default
    # computers container - example.local -> CN=Computers,DC=example,DC=local.
    $defaultOuSuggestion = $null
    try {
        $firstJoinDomain = @($joinDomainOptions) | Select-Object -First 1
        if ($firstJoinDomain) {
            $dcParts = @(([string]$firstJoinDomain) -split '\.' | Where-Object { $_ } | ForEach-Object { "DC=$_" })
            if ($dcParts.Count -gt 0) {
                $defaultOuSuggestion = 'CN=Computers,' + ($dcParts -join ',')
            }
        }
    } catch { }

    # KMS catalog (product-key dropdown) and admin-group options for the
    # the configured domains ({{SITE}} kept as a token so sequences stay portable).
    $kmsKeyOptions = @()
    try {
        if (Test-AppSidecarCommand Get-AppPxeBootKmsClientKeys) {
            $catalog = Get-AppPxeBootKmsClientKeys
            foreach ($name in $catalog.Keys) {
                $kmsKeyOptions += @{ label = [string]$name; key = [string]$catalog[$name] }
            }
        }
    } catch { }
    if ($kmsKeyOptions.Count -eq 0) { $kmsKeyOptions = @(Get-AppPxeBootTsGvlkOptions) }
    # Role-default product keys resolved server-side so the frontend needs no GVLK
    # copy of its own (it only uses these to clear a pinned key on a role switch).
    $roleDefaults = @{
        client = [string](Get-AppPxeBootTsProductKeyDefault -Role 'client')
        server = [string](Get-AppPxeBootTsProductKeyDefault -Role 'server')
    }
    # TODO(Site Profile): admin-group options come from the Site Profile.
    $adminGroupOptions = @()

    # Store credentials the UI can offer for the join-credential selector.
    $credentialOptions = @()
    try {
        if (Test-AppSidecarCommand Get-AppInfraSshCredentials) {
            foreach ($c in @(Get-AppInfraSshCredentials)) {
                if (-not [bool]$c.configured) { continue }
                $credentialOptions += @{
                    id        = [string]$c.id
                    label     = [string]$c.label
                    loginName = [string]$c.loginName
                }
            }
        }
    } catch { }
    # Install image sources for the per-sequence image dropdown. Cheap read: a
    # directory listing plus the cached edition lists - ISOs are never mounted here.
    # The panel asks ListPxeBootInstallImages with refresh when it wants the unread ones.
    $installImages = @()
    try {
        if (Test-AppSidecarCommand Get-AppPxeBootInstallImageCatalog) {
            $installImages = @(Get-AppPxeBootInstallImageCatalog)
        }
    } catch {
        Write-SidecarLogVerbose "PXE boot: install image catalog unavailable - $($_.Exception.Message)"
    }
    @{
        sequences         = $sequences
        installImages     = $installImages
        regionalDefaults  = (Get-AppPxeBootTsRegionalDefaults)
        libraryDir        = $dir
        firstBootScripts  = @(Get-AppPxeBootTsFirstBootScripts)
        scriptsDir        = (Get-AppPxeBootTsScriptsDir)
        publishedFiles    = $publishedFiles
        defaultSequenceId  = (Get-AppPxeBootTaskSequenceDefaultId)
        credentialOptions  = $credentialOptions
        joinDomainOptions  = $joinDomainOptions
        joinDomainSuggestions = @($joinDomainSuggestions)
        machineOuOptions   = $machineOuOptions
        defaultOuSuggestion = $defaultOuSuggestion
        kmsKeyOptions      = $kmsKeyOptions
        roleDefaults       = $roleDefaults
        adminGroupOptions  = $adminGroupOptions
    }
}

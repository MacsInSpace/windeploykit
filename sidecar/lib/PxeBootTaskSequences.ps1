# Netboot task sequences — MDT-style named deployments for ImageDeployer.
#
# Craig's real unattend templates (Client/Server) are embedded below with a split
# token model:
#   * publish-time tokens ({{JoinDomain}}, {{MachineOu}}, {{ProductKey}}, server
#     networking, {{LocalAdminPw}} from the Site Profile, and a
#     store-credential join's full {{JoinDom}}/{{JoinUser}}/{{JoinPw}} triplet) —
#     substituted HERE from each sequence's saved fields when the store syncs, so
#     what lands in <library>/TaskSequences/<id>.xml is concrete.
#   * deploy-time tokens ({{SITE}}, {{SERIAL}}, and for ambient-credential joins the
#     whole {{JoinDom}}/{{JoinUser}}/{{JoinPw}} triplet) — left intact in the
#     published file. ImageDeployer fills them on the client at deploy time
#     (site id, device serial, and the credentials typed for the share
#     connect — one coherent credential, never publisher identity + deployer
#     password). Join passwords therefore NEVER sit in a file on the share.
#
# The published files are served over the existing read-only Deploy$ share as
# Z:\TaskSequences\<id>.xml; ImageDeployer's Task Sequence picker lists them and
# copies the chosen one to <OS volume>\Windows\Panther\unattend.xml after apply —
# the standard first-boot (specialize + oobeSystem) mechanism. The windowsPE pass
# from the original hand-built files is omitted: it only runs under setup.exe,
# never for DISM-applied images. EULA-hiding removed per Craig (2026-08-19).

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
    # boot (specialize RunSynchronous) — seeded here from Craig's RDP-enable and
    # GPO-disable sets, but plain data the panel can add to, remove, or reorder.
    # Empty productKey publishes the role default from the KMS catalog.
    @(
        [ordered]@{
            id      = 'client-domain'
            name    = 'Client - domain join'
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
            name    = 'Server - static IP + domain'
            kind    = 'server'
            enabled = $false
            fields  = [ordered]@{
                computerName = 'SVR01'
                network      = 'static'
                ipCidr       = ''
                gateway      = ''
                dns1         = ''
                dns2         = ''
                dns3         = ''
                joinDomain   = ''
                joinCredential = ''
                machineOu    = ''
                productKey   = ''
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

function Read-AppPxeBootTaskSequences {
    $path = Get-AppPxeBootTaskSequencesPath
    if (-not (Test-Path -LiteralPath $path)) {
        return @(Get-AppPxeBootTaskSequenceDefaults)
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        # An existing store with an EMPTY list is an explicit user choice (all
        # sequences deleted — Craig, 2026-08-20: the seeds are examples, fully
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
    # leading dots — '../x' must not survive as a hidden/path-shaped name.
    $id = ($id -replace '[^A-Za-z0-9._-]', '-').Trim('-').TrimStart('.', '-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $kind = ([string](Get-AppPxeBootTsProp -Item $Item -Name 'kind')).Trim().ToLowerInvariant()
    # Sections replaced kinds (Craig, 2026-08-19): only the client/server role
    # remains; the old OOBE variant is simply a client with no join domain.
    if ($kind -notin @('client', 'server')) { $kind = 'client' }
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
    # Heal the wrapper leak (pre-2026-08-20 the payload stringified the raw
    # override object into the dropdown, and it could get saved):
    # '@{value=example.local; userLocked=True; ...}' -> 'example.local'.
    if ($fields.Contains('joinDomain') -and $fields['joinDomain'] -match '^@\{.*?value=([^;}]+)') {
        $fields['joinDomain'] = ([string]$matches[1]).Trim()
    }
    # Ordered custom steps (reg / cmd / pwsh) — the editable first-boot spec.
    $steps = @()
    foreach ($stepIn in @(Get-AppPxeBootTsProp -Item $Item -Name 'steps')) {
        if ($null -eq $stepIn) { continue }
        $type = ([string](Get-AppPxeBootTsProp -Item $stepIn -Name 'type')).Trim().ToLowerInvariant()
        if ($type -notin @('reg', 'cmd', 'pwsh')) { continue }
        $step = [ordered]@{
            type        = $type
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
    $nameVal = [string](Get-AppPxeBootTsProp -Item $Item -Name 'name')
    [ordered]@{
        id          = $id
        name        = if ([string]::IsNullOrWhiteSpace($nameVal)) { $id } else { $nameVal.Trim() }
        kind        = $kind
        enabled     = [bool](Get-AppPxeBootTsProp -Item $Item -Name 'enabled')
        fields      = $fields
        adminGroups = $adminGroups
        steps       = $steps
    }
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
    # (= ImageDeployer's None item, clean OOBE / Intune) so a renamed/removed id
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

function Get-AppPxeBootTaskSequencePublishContext {
    <#
    .SYNOPSIS
        Live values resolved at publish time from the Site Profile: the join
        identity (domain + username — never the password), the local-admin
        passwords used for the {{LocalAdminPw}} token, and the base OU for
        {{SiteOu}} machine-OU tokens.
    .NOTES
        TODO(Site Profile): back these with the Site Profile store. Until it
        exists every value is $null, which makes the token expansion fail loudly
        rather than publishing a wrong-but-plausible value.
        The USM original sourced these from the Site Profile and fell back to
        two hardcoded department bench passwords — both removed for WinDeployKit.
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
        if (Get-Command Get-AppSiteProfile -ErrorAction SilentlyContinue) {
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

function Get-AppPxeBootTsProductKeyDefault {
    # Role default from the configured KMS catalog; falls back to Microsoft's
    # published KMS client setup keys (GVLKs) below.
    # TODO(Site Profile): source the catalog from the Site Profile.
    param([Parameter(Mandatory)][string]$Role)
    try {
        if (Get-Command Get-AppPxeBootKmsClientKeys -ErrorAction SilentlyContinue) {
            $catalog = Get-AppPxeBootKmsClientKeys
            foreach ($name in $catalog.Keys) {
                $isServer = $name -match '(?i)server'
                if (($Role -eq 'server') -eq $isServer) { return [string]$catalog[$name] }
            }
        }
    } catch { }
    if ($Role -eq 'server') { '8B2CN-7C8FB-QWPCQ-42WKG-724QW' } else { 'KBN8V-HFGQ4-MGXVD-347P6-PDQGT' }
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
        default { "cmd /c $([string]$Step.command)" }
    }
}

function Get-AppPxeBootTsSpecializeRunSync {
    # The sequence's ordered steps as a specialize RunSynchronous component.
    # Empty steps list -> no component at all.
    param([object[]]$Steps)
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
function Get-AppPxeBootTsIntlSpecialize {
    @'
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>0c09:00000409</InputLocale>
			<SystemLocale>en-AU</SystemLocale>
			<UILanguage>en-AU</UILanguage>
			<UILanguageFallback>en-AU</UILanguageFallback>
			<UserLocale>en-AU</UserLocale>
		</component>
'@
}

function Get-AppPxeBootTsShellSpecialize {
    # ProductKey lives HERE: the ADK documents Shell-Setup ProductKey for the
    # specialize pass; in oobeSystem it is ignored (moved 2026-08-20, Craig's call).
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$ProductKey
    )
    @"
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<ComputerName>$ComputerName</ComputerName>
			<ProductKey>$(ConvertTo-AppPxeBootTsXmlEscaped $ProductKey)</ProductKey>
			<RegisteredOrganization>$(ConvertTo-AppPxeBootTsXmlEscaped (Get-AppPxeBootTsOrgName))</RegisteredOrganization>
			<RegisteredOwner>$(ConvertTo-AppPxeBootTsXmlEscaped (Get-AppPxeBootTsOrgName))</RegisteredOwner>
			<TimeZone>$(ConvertTo-AppPxeBootTsXmlEscaped (Get-AppPxeBootTsTimeZone))</TimeZone>
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
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return 'WinDeployKit' }
    return [string]$v
}

function Get-AppPxeBootTsTimeZone {
    # TODO(Site Profile): Windows time-zone id for generated unattend files.
    $v = $null
    try { $v = (Get-AppPxeBootConfig).timeZone } catch { }
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return 'UTC' }
    return [string]$v
}

function Get-AppPxeBootTsOobeAccounts {
    # oobeSystem accounts + autologon. Admin groups are an explicit optional list
    # (Craig, 2026-08-19) — emitted only when joining a domain and groups are set.
    # {{LocalAdminPw}} comes from the Site Profile.
    param([string[]]$AdminGroups = @(), [bool]$EmitGroups)
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
				<LogonCount>1</LogonCount>
				<Enabled>true</Enabled>
			</AutoLogon>
"@
}
function Get-AppPxeBootTsOobeShell {
    param([Parameter(Mandatory)][string]$Accounts, [bool]$Joining)
    # Joined machines hide the online-account screens; unjoined (workgroup) leave
    # them visible so the operator can enrol / sign in.
    $hideOnline = if ($Joining) { "				<HideOnlineAccountScreens>true</HideOnlineAccountScreens>`n" } else { '' }
    @"
		<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
			<OOBE>
				<HideLocalAccountScreen>true</HideLocalAccountScreen>
				<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
$hideOnline				<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
				<NetworkLocation>Work</NetworkLocation>
				<ProtectYourPC>1</ProtectYourPC>
			</OOBE>
$Accounts			<RegisteredOrganization>$(ConvertTo-AppPxeBootTsXmlEscaped (Get-AppPxeBootTsOrgName))</RegisteredOrganization>
			<RegisteredOwner>$(ConvertTo-AppPxeBootTsXmlEscaped (Get-AppPxeBootTsOrgName))</RegisteredOwner>
		</component>
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

    # --- Computer name: suffix field + composed, healed {{SITE}} prefix ----------
    # Heal collapses only the {{SITE}} token and the configured site id (typed once
    # or repeated, dash or not). Never strip arbitrary leading digits: a suffix can
    # legitimately start with digits (serials/asset tags — Craig, 2026-08-19).
    $nameSuffix = & $get 'computerName' '{{SERIAL}}'
    $nameSuffix = $nameSuffix -replace '^(\{\{SITE\}\}-?)+', ''
    if ($ctx.siteId) {
        $siteEsc = [regex]::Escape([string]$ctx.siteId)
        $nameSuffix = $nameSuffix -replace "^(?i:(?:$siteEsc-?)+)", ''
    }
    $nameSuffix = $nameSuffix.TrimStart('-')
    if ([string]::IsNullOrWhiteSpace($nameSuffix)) { $nameSuffix = '{{SERIAL}}' }
    $computerName = if ($role -eq 'server') { '{{SITE}}' + $nameSuffix } else { '{{SITE}}-' + $nameSuffix }

    # --- Section toggles ---------------------------------------------------------
    $staticIp = ((& $get 'network' 'dhcp') -eq 'static')
    $joinDomainName = & $get 'joinDomain' ''
    $joining = -not [string]::IsNullOrWhiteSpace($joinDomainName)
    $productKey = & $get 'productKey' (Get-AppPxeBootTsProductKeyDefault -Role $role)

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
        $ou = & $get 'machineOu' ''
        if ($ou -match '\{\{SiteOu\}\}') {
            if ($ctx.siteOuDn) { $ou = $ou.Replace('{{SiteOu}}', $ctx.siteOuDn) } else { $ou = '' }
        }
        $ouElement = if ($ou) { "				<MachineObjectOU>$(ConvertTo-AppPxeBootTsXmlEscaped $ou)</MachineObjectOU>`n" } else { '' }
        $joinComponent = Get-AppPxeBootTsUnattendedJoin -OuElement $ouElement
    }

    # --- Assemble ---------------------------------------------------------------
    # Admin-group block is emitted whenever we are joining a domain and the
    # sequence actually lists groups (TODO(Site Profile): per-domain group policy).
    $centralJoin = $joining -and @($rec.adminGroups).Count -gt 0
    $specialize = (Get-AppPxeBootTsSpecializeRunSync -Steps @($rec.steps)) + $dnsComponent + (Get-AppPxeBootTsIntlSpecialize) + (Get-AppPxeBootTsShellSpecialize -ComputerName $computerName -ProductKey $productKey) + $ipComponent + $joinComponent
    $accounts = Get-AppPxeBootTsOobeAccounts -AdminGroups @($rec.adminGroups | ForEach-Object { [string]$_ }) -EmitGroups $centralJoin
    $oobeShell = Get-AppPxeBootTsOobeShell -Accounts $accounts -Joining $joining

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
	<settings pass="specialize">
$specialize	</settings>
	<settings pass="oobeSystem">
		<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
			<InputLocale>0c09:00000409</InputLocale>
			<SystemLocale>en-AU</SystemLocale>
			<UILanguage>en-AU</UILanguage>
			<UILanguageFallback>en-AU</UILanguageFallback>
			<UserLocale>en-AU</UserLocale>
		</component>
$oobeShell	</settings>
</unattend>
"@

    # --- Publish-time token fills -----------------------------------------------
    $xml = $xml.Replace('{{JoinDomain}}', (ConvertTo-AppPxeBootTsXmlEscaped $joinDomainName))

    $joinCredId = & $get 'joinCredential' ''
    if ($joining -and $joinCredId) {
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
    $localPw = if ($role -eq 'server') { $ctx.serverAdmPw } else { $ctx.clientAdmPw }
    if ($localPw) { $xml = $xml.Replace('{{LocalAdminPw}}', (ConvertTo-AppPxeBootTsXmlEscaped $localPw)) }

    $xml
}


function Sync-AppPxeBootTaskSequenceStore {
    <#
    .SYNOPSIS
        Publish enabled sequences to <library>/TaskSequences/<id>.xml (Z:\TaskSequences
        over Deploy$). Prunes files for removed/disabled sequences. Deploy-time tokens
        stay literal — see the header comment; secrets never land on the share.
    #>
    $dir = Get-AppPxeBootTaskSequenceLibraryDir
    if (-not $dir) { return @{ published = 0; dir = $null } }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }

    $published = 0
    $keep = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($seq in @(Read-AppPxeBootTaskSequences)) {
        $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq
        if ($null -eq $rec -or -not [bool]$rec.enabled) { continue }
        $xml = Build-AppPxeBootTaskSequenceUnattendXml -Sequence $rec
        if (-not $xml) { continue }
        $file = Join-Path $dir "$($rec.id).xml"
        # CRLF for Windows-side consumers; idempotent write (skip when unchanged).
        $body = ($xml -replace "`r`n", "`n") -replace "`n", "`r`n"
        $have = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($have -ne $body) {
            [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding $false))
        }
        [void]$keep.Add("$($rec.id).xml")
        $published++
    }
    foreach ($existing in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        if (-not $keep.Contains($existing.Name)) {
            Remove-Item -LiteralPath $existing.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # _default.txt preselects the ImageDeployer menu (touch-free deploys). Written
    # only when the default resolves to a published file; a dangling default is
    # pruned rather than preselecting a missing sequence (no marker = None item).
    $marker = Join-Path $dir '_default.txt'
    $default = Get-AppPxeBootTaskSequenceDefaultId
    $defaultValid = [bool]($default -and $keep.Contains("$default.xml"))
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

function Get-AppPxeBootTaskSequencesPayload {
    $sequences = @(Read-AppPxeBootTaskSequences | ForEach-Object { ConvertTo-AppPxeBootTaskSequenceRecord -Item $_ } | Where-Object { $_ })
    $dir = Get-AppPxeBootTaskSequenceLibraryDir
    $publishedFiles = @()
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        $publishedFiles = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.xml' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    # Join-domain options come from the Site Profile. Guard against wrapper leaks:
    # a store that wraps entries as @{value; userLocked; updatedAt} must be
    # unwrapped before display (field bug 2026-08-20 leaked the whole wrapper).
    $joinDomainOptions = @()  # TODO(Site Profile): seeded from the Site Profile join domains
    try {
        $sp = if (Get-Command Get-AppSiteProfile -ErrorAction SilentlyContinue) { Get-AppSiteProfile } else { $null }
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
        $sp2 = if (Get-Command Get-AppSiteProfile -ErrorAction SilentlyContinue) { Get-AppSiteProfile } else { $null }
        foreach ($dnRaw in @($sp2.machineOus)) {
            $dn = [string]$dnRaw
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            $label = (($dn -split ',')[0] -replace '^(?i)OU=', '').Trim()
            $machineOuOptions += @{ dn = $dn; label = $label }
        }
    } catch { }

    # OU suggestion: reverse the join domain into DN form with the AD default
    # computers container — example.local → CN=Computers,DC=example,DC=local.
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
        if (Get-Command Get-AppPxeBootKmsClientKeys -ErrorAction SilentlyContinue) {
            $catalog = Get-AppPxeBootKmsClientKeys
            foreach ($name in $catalog.Keys) {
                $kmsKeyOptions += @{ label = [string]$name; key = [string]$catalog[$name] }
            }
        }
    } catch { }
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
        if (Get-Command Get-AppInfraSshCredentials -ErrorAction SilentlyContinue) {
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
    @{
        sequences         = $sequences
        libraryDir        = $dir
        publishedFiles    = $publishedFiles
        defaultSequenceId  = (Get-AppPxeBootTaskSequenceDefaultId)
        credentialOptions  = $credentialOptions
        joinDomainOptions  = $joinDomainOptions
        machineOuOptions   = $machineOuOptions
        defaultOuSuggestion = $defaultOuSuggestion
        kmsKeyOptions      = $kmsKeyOptions
        roleDefaults       = $roleDefaults
        adminGroupOptions  = $adminGroupOptions
    }
}

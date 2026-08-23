# TaskSequenceStepLibrary.ps1 - the "add a common setting" catalog for task sequences.
#
# Craig, 2026-08-22: "the unattend is everything ... I'd even like a library of options
# like a dropdown 'firewall on / off' that imports the right reg key for it".
#
# Rules this catalog follows, learned from the settings that go wrong in the field:
#
#  1. USE THE RIGHT MECHANISM. Firewall state and rules are netsh, power is powercfg,
#     policies are registry. Writing a firewall profile's registry value directly is the
#     classic way to end up with a UI that disagrees with the service.
#  2. PER-USER SETTINGS NEED THE DEFAULT HIVE. An HKCU write during specialize lands in
#     the SYSTEM account's profile and applies to nobody. Those entries load
#     C:\Users\Default\NTUSER.DAT, write, and unload, so the setting reaches every new
#     profile. This is the single most common "why didn't my tweak apply" cause.
#  3. EVERY ENTRY IS DOCUMENTED. Each carries a source URL. Anything I could not point at
#     documentation for is not in here - a deployment tool inventing registry keys is how
#     fleets get mystery behaviour.
#  4. NOTHING IS APPLIED BY DEFAULT. The catalog only produces steps a technician
#     explicitly adds, and every entry says plainly what it does.
#
# Entry shape:
#   id, name, category, applies ('client'|'server'|'both'), risk ('safe'|'caution'),
#   description, source, step (a task-sequence step: reg or cmd),
#   parameter (optional: name/label/type/default/choices - the UI prompts, {{VALUE}} in
#   the step's data/command is replaced).

$script:AppTsStepLibraryDefaultHiveWrap = 'reg load HKU\AppDefault "C:\Users\Default\NTUSER.DAT" & {0} & reg unload HKU\AppDefault'

function New-AppTsLibraryDefaultHiveStep {
    # Per-user setting written into the Default profile so new users inherit it.
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name,
        [string]$ValueType = 'REG_DWORD',
        [Parameter(Mandatory)][string]$Data
    )
    $inner = "reg add `"HKU\AppDefault\$SubKey`" /v $Name /t $ValueType /d $Data /f"
    [ordered]@{
        type        = 'cmd'
        description = $Description
        command     = ($script:AppTsStepLibraryDefaultHiveWrap -f $inner)
    }
}

function Get-AppTaskSequenceStepLibrary {
    <#
    .SYNOPSIS
        Common first-boot settings a technician can drop into a sequence.
    #>
    @(
        # --- Remote access -----------------------------------------------------
        [ordered]@{
            id = 'rdp-enable'; name = 'Remote Desktop: enable'; category = 'Remote access'
            applies = 'both'; risk = 'safe'
            description = 'Allows incoming Remote Desktop connections (also needs the firewall rule below).'
            source = 'https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/remote-desktop-allow-access'
            step = [ordered]@{ type = 'reg'; description = 'Enable Remote Desktop'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'; name = 'fDenyTSConnections'; valueType = 'REG_DWORD'; data = '0' }
        }
        [ordered]@{
            id = 'rdp-firewall'; name = 'Remote Desktop: allow through the firewall'; category = 'Remote access'
            applies = 'both'; risk = 'safe'
            description = 'Enables the built-in Remote Desktop firewall rule group.'
            source = 'https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/remote-desktop-allow-access'
            step = [ordered]@{ type = 'cmd'; description = 'Allow RDP through the firewall'; command = 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes' }
        }
        [ordered]@{
            id = 'rdp-nla-off'; name = 'Remote Desktop: turn off Network Level Authentication'; category = 'Remote access'
            applies = 'both'; risk = 'caution'
            description = 'Lets a tech connect before anyone has signed in. Weakens pre-auth - deployment and lab use.'
            source = 'https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/remote-desktop-allow-access'
            step = [ordered]@{ type = 'reg'; description = 'Disable NLA for RDP'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; name = 'UserAuthentication'; valueType = 'REG_DWORD'; data = '0' }
        }
        [ordered]@{
            id = 'psremoting-enable'; name = 'PowerShell remoting: enable'; category = 'Remote access'
            applies = 'both'; risk = 'safe'
            description = 'Runs Enable-PSRemoting -Force (WinRM service, listener and firewall rule).'
            source = 'https://learn.microsoft.com/powershell/module/microsoft.powershell.core/enable-psremoting'
            step = [ordered]@{ type = 'pwsh'; description = 'Enable PowerShell remoting'; command = 'Enable-PSRemoting -Force -SkipNetworkProfileCheck' }
        }

        # --- Firewall ----------------------------------------------------------
        [ordered]@{
            id = 'firewall-on'; name = 'Firewall: on (all profiles)'; category = 'Firewall'
            applies = 'both'; risk = 'safe'
            description = 'Turns Windows Defender Firewall on for domain, private and public profiles.'
            source = 'https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/configure'
            step = [ordered]@{ type = 'cmd'; description = 'Firewall on (all profiles)'; command = 'netsh advfirewall set allprofiles state on' }
        }
        [ordered]@{
            id = 'firewall-off'; name = 'Firewall: off (all profiles)'; category = 'Firewall'
            applies = 'both'; risk = 'caution'
            description = 'Turns the firewall off on every profile. Isolated build networks only.'
            source = 'https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/configure'
            step = [ordered]@{ type = 'cmd'; description = 'Firewall off (all profiles)'; command = 'netsh advfirewall set allprofiles state off' }
        }
        [ordered]@{
            id = 'firewall-ping'; name = 'Firewall: allow ping (ICMPv4)'; category = 'Firewall'
            applies = 'both'; risk = 'safe'
            description = 'Adds an inbound rule for ICMPv4 echo so the machine answers ping.'
            source = 'https://learn.microsoft.com/windows-server/networking/technologies/netsh/netsh-advfirewall-firewall'
            step = [ordered]@{ type = 'cmd'; description = 'Allow ping (ICMPv4)'; command = 'netsh advfirewall firewall add rule name="ICMP Allow incoming V4 echo request" protocol=icmpv4:8,any dir=in action=allow' }
        }
        [ordered]@{
            id = 'firewall-filesharing'; name = 'Firewall: allow File and Printer Sharing'; category = 'Firewall'
            applies = 'both'; risk = 'caution'
            description = 'Enables the File and Printer Sharing rule group (SMB in).'
            source = 'https://learn.microsoft.com/windows-server/networking/technologies/netsh/netsh-advfirewall-firewall'
            step = [ordered]@{ type = 'cmd'; description = 'Allow File and Printer Sharing'; command = 'netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes' }
        }

        # --- Windows Update ----------------------------------------------------
        [ordered]@{
            id = 'wsus-server'; name = 'Windows Update: point at a WSUS server'; category = 'Windows Update'
            applies = 'both'; risk = 'safe'
            description = 'Sets WUServer/WUStatusServer and turns on UseWUServer.'
            source = 'https://learn.microsoft.com/windows/deployment/update/waas-wu-settings'
            parameter = [ordered]@{ name = 'server'; label = 'WSUS URL'; type = 'text'; default = 'http://wsus.example.internal:8530' }
            step = [ordered]@{ type = 'cmd'; description = 'Point Windows Update at WSUS'; command = 'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "{{VALUE}}" /f & reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "{{VALUE}}" /f & reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f' }
        }
        [ordered]@{
            id = 'wu-no-auto-reboot'; name = 'Windows Update: no auto restart while signed in'; category = 'Windows Update'
            applies = 'both'; risk = 'safe'
            description = 'Stops automatic restarts while a user is logged on.'
            source = 'https://learn.microsoft.com/windows/deployment/update/waas-restart'
            step = [ordered]@{ type = 'reg'; description = 'No auto restart with logged-on users'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; name = 'NoAutoRebootWithLoggedOnUsers'; valueType = 'REG_DWORD'; data = '1' }
        }

        # --- Privacy / consumer ------------------------------------------------
        [ordered]@{
            id = 'telemetry-level'; name = 'Diagnostic data: set level'; category = 'Privacy'
            applies = 'both'; risk = 'safe'
            description = 'Sets the diagnostic data level policy (0 Security - Enterprise only, 1 Required, 2 Enhanced, 3 Optional).'
            source = 'https://learn.microsoft.com/windows/privacy/configure-windows-diagnostic-data-in-your-organization'
            parameter = [ordered]@{ name = 'level'; label = 'Level'; type = 'choice'; default = '1'; choices = @('0', '1', '2', '3') }
            step = [ordered]@{ type = 'reg'; description = 'Diagnostic data level'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; name = 'AllowTelemetry'; valueType = 'REG_DWORD'; data = '{{VALUE}}' }
        }
        [ordered]@{
            id = 'consumer-features-off'; name = 'Consumer features: off'; category = 'Privacy'
            applies = 'client'; risk = 'safe'
            description = 'Stops the automatic install of suggested apps on first sign-in.'
            source = 'https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience'
            step = [ordered]@{ type = 'reg'; description = 'Disable consumer features'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; name = 'DisableWindowsConsumerFeatures'; valueType = 'REG_DWORD'; data = '1' }
        }
        [ordered]@{
            id = 'onedrive-autoinstall-off'; name = 'OneDrive: do not auto-install for new users'; category = 'Privacy'
            applies = 'client'; risk = 'safe'
            description = 'Prevents the per-user OneDrive setup running at first sign-in.'
            source = 'https://learn.microsoft.com/sharepoint/use-group-policy'
            step = [ordered]@{ type = 'reg'; description = 'Disable OneDrive auto-install'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; name = 'DisableFileSyncNGSC'; valueType = 'REG_DWORD'; data = '1' }
        }

        # --- Explorer / shell (Default profile) --------------------------------
        [ordered]@{
            id = 'explorer-show-extensions'; name = 'Explorer: show file extensions (new users)'; category = 'Explorer'
            applies = 'both'; risk = 'safe'
            description = 'Writes into the Default profile hive so every new user gets it.'
            source = 'https://learn.microsoft.com/windows/win32/shell/how-to-customize-the-default-user-profile'
            step = (New-AppTsLibraryDefaultHiveStep -Description 'Show file extensions (new users)' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Data '0')
        }
        [ordered]@{
            id = 'explorer-show-hidden'; name = 'Explorer: show hidden files (new users)'; category = 'Explorer'
            applies = 'both'; risk = 'safe'
            description = 'Writes into the Default profile hive so every new user gets it.'
            source = 'https://learn.microsoft.com/windows/win32/shell/how-to-customize-the-default-user-profile'
            step = (New-AppTsLibraryDefaultHiveStep -Description 'Show hidden files (new users)' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' -Data '1')
        }
        [ordered]@{
            id = 'explorer-this-pc'; name = 'Explorer: open to This PC (new users)'; category = 'Explorer'
            applies = 'both'; risk = 'safe'
            description = 'Opens File Explorer on This PC rather than Quick Access, for every new user.'
            source = 'https://learn.microsoft.com/windows/win32/shell/how-to-customize-the-default-user-profile'
            step = (New-AppTsLibraryDefaultHiveStep -Description 'Explorer opens to This PC (new users)' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Data '1')
        }

        # --- Server -------------------------------------------------------------
        [ordered]@{
            id = 'server-manager-off'; name = 'Server Manager: do not open at sign-in'; category = 'Server'
            applies = 'server'; risk = 'safe'
            description = 'Stops Server Manager launching on every logon.'
            source = 'https://learn.microsoft.com/windows-server/administration/server-manager/server-manager'
            step = [ordered]@{ type = 'reg'; description = 'Do not open Server Manager at logon'; op = 'add'; path = 'HKLM\SOFTWARE\Microsoft\ServerManager'; name = 'DoNotOpenServerManagerAtLogon'; valueType = 'REG_DWORD'; data = '1' }
        }
        [ordered]@{
            id = 'ie-esc-off'; name = 'IE Enhanced Security Configuration: off'; category = 'Server'
            applies = 'server'; risk = 'caution'
            description = 'Turns IE ESC off for administrators and users. Convenience on a build server, not a hardened one.'
            source = 'https://learn.microsoft.com/troubleshoot/developer/browsers/general/enhanced-security-configuration-faq'
            step = [ordered]@{ type = 'cmd'; description = 'Disable IE Enhanced Security Configuration'; command = 'reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f & reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f' }
        }

        # --- Power --------------------------------------------------------------
        [ordered]@{
            id = 'power-high-performance'; name = 'Power: high performance plan'; category = 'Power'
            applies = 'both'; risk = 'safe'
            description = 'Activates the built-in High performance scheme.'
            source = 'https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options'
            step = [ordered]@{ type = 'cmd'; description = 'High performance power plan'; command = 'powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        }
        [ordered]@{
            id = 'power-never-sleep-ac'; name = 'Power: never sleep on AC'; category = 'Power'
            applies = 'both'; risk = 'safe'
            description = 'Sets sleep and monitor timeouts to never while plugged in.'
            source = 'https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options'
            step = [ordered]@{ type = 'cmd'; description = 'Never sleep on AC'; command = 'powercfg /change standby-timeout-ac 0 & powercfg /change monitor-timeout-ac 0 & powercfg /change hibernate-timeout-ac 0' }
        }
        [ordered]@{
            id = 'fast-startup-off'; name = 'Power: disable fast startup'; category = 'Power'
            applies = 'client'; risk = 'safe'
            description = 'Makes a shutdown a real shutdown - what you want for imaging and for GPO/driver changes to land.'
            source = 'https://learn.microsoft.com/troubleshoot/windows-client/performance/fast-startup-mode'
            step = [ordered]@{ type = 'reg'; description = 'Disable fast startup'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; name = 'HiberbootEnabled'; valueType = 'REG_DWORD'; data = '0' }
        }

        # --- Security -----------------------------------------------------------
        [ordered]@{
            id = 'uac-admin-prompt'; name = 'UAC: admin consent behaviour'; category = 'Security'
            applies = 'both'; risk = 'caution'
            description = 'ConsentPromptBehaviorAdmin: 5 is the default (prompt for consent for non-Windows binaries), 0 elevates silently.'
            source = 'https://learn.microsoft.com/windows/security/application-security/application-control/user-account-control/settings-and-configuration'
            parameter = [ordered]@{ name = 'behaviour'; label = 'Behaviour'; type = 'choice'; default = '5'; choices = @('0', '1', '2', '3', '4', '5') }
            step = [ordered]@{ type = 'reg'; description = 'UAC admin consent behaviour'; op = 'add'; path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'ConsentPromptBehaviorAdmin'; valueType = 'REG_DWORD'; data = '{{VALUE}}' }
        }
        [ordered]@{
            id = 'smb1-off'; name = 'SMBv1: remove the client and server'; category = 'Security'
            applies = 'both'; risk = 'safe'
            description = 'Removes the SMB1 feature outright. Microsoft has recommended this since 2017.'
            source = 'https://learn.microsoft.com/windows-server/storage/file-server/troubleshoot/detect-enable-and-disable-smbv1-v2-v3'
            step = [ordered]@{ type = 'pwsh'; description = 'Remove SMBv1'; command = 'Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue' }
        }
        [ordered]@{
            id = 'timezone-set'; name = 'Time zone: set'; category = 'Regional'
            applies = 'both'; risk = 'safe'
            description = 'Sets the machine time zone by Windows id (tzutil /l lists them).'
            source = 'https://learn.microsoft.com/windows-server/administration/windows-commands/tzutil'
            parameter = [ordered]@{ name = 'timezone'; label = 'Time zone id'; type = 'text'; default = 'AUS Eastern Standard Time' }
            step = [ordered]@{ type = 'cmd'; description = 'Set time zone'; command = 'tzutil /s "{{VALUE}}"' }
        }
        [ordered]@{
            id = 'ntp-server'; name = 'Time: sync from a specific server'; category = 'Regional'
            applies = 'both'; risk = 'safe'
            description = 'Points w32time at a manual peer and resyncs.'
            source = 'https://learn.microsoft.com/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings'
            parameter = [ordered]@{ name = 'peer'; label = 'Time server'; type = 'text'; default = 'time.windows.com' }
            step = [ordered]@{ type = 'cmd'; description = 'Set time server'; command = 'w32tm /config /syncfromflags:manual /manualpeerlist:"{{VALUE}}" & w32tm /config /reliable:yes & net stop w32time & net start w32time & w32tm /resync /force' }
        }

        # --- Privacy / cloud content -------------------------------------------
        [ordered]@{
            id = 'smartscreen-off'; name = 'SmartScreen: off'; category = 'Privacy'
            applies = 'both'; risk = 'caution'
            description = 'Turns off Microsoft Defender SmartScreen for apps and files. Isolated/lab use.'
            source = 'https://learn.microsoft.com/windows/security/operating-system-security/virus-and-threat-protection/microsoft-defender-smartscreen/microsoft-defender-smartscreen-available-settings'
            step = [ordered]@{ type = 'reg'; description = 'Disable SmartScreen'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; name = 'EnableSmartScreen'; valueType = 'REG_DWORD'; data = '0' }
        }
        [ordered]@{
            id = 'cortana-off'; name = 'Cortana: off'; category = 'Privacy'
            applies = 'client'; risk = 'safe'
            description = 'Disables Cortana via the Windows Search policy.'
            source = 'https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience'
            step = [ordered]@{ type = 'reg'; description = 'Disable Cortana'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; name = 'AllowCortana'; valueType = 'REG_DWORD'; data = '0' }
        }
        [ordered]@{
            id = 'spotlight-off'; name = 'Windows Spotlight & suggestions: off'; category = 'Privacy'
            applies = 'client'; risk = 'safe'
            description = 'Turns off Windows Spotlight lock-screen content and suggested apps/content.'
            source = 'https://learn.microsoft.com/windows/configuration/windows-spotlight'
            step = [ordered]@{ type = 'reg'; description = 'Disable Windows Spotlight features'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; name = 'DisableWindowsSpotlightFeatures'; valueType = 'REG_DWORD'; data = '1' }
        }

        # --- Browser -----------------------------------------------------------
        [ordered]@{
            id = 'edge-first-run-off'; name = 'Edge: skip the first-run experience'; category = 'Browser'
            applies = 'both'; risk = 'safe'
            description = 'Suppresses the Microsoft Edge first-run/welcome flow for every user.'
            source = 'https://learn.microsoft.com/deployedge/microsoft-edge-policies'
            step = [ordered]@{ type = 'reg'; description = 'Edge: hide first-run experience'; op = 'add'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; name = 'HideFirstRunExperience'; valueType = 'REG_DWORD'; data = '1' }
        }

        # --- System ------------------------------------------------------------
        [ordered]@{
            id = 'hibernate-off'; name = 'Power: disable hibernate'; category = 'Power'
            applies = 'both'; risk = 'safe'
            description = 'Runs powercfg /h off - frees the hiberfil and removes hibernate/fast startup.'
            source = 'https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options'
            step = [ordered]@{ type = 'cmd'; description = 'Disable hibernate'; command = 'powercfg /h off' }
        }
        [ordered]@{
            id = 'long-paths-on'; name = 'Filesystem: enable long paths (>260)'; category = 'System'
            applies = 'both'; risk = 'safe'
            description = 'Lets Win32 apps use paths longer than MAX_PATH (LongPathsEnabled).'
            source = 'https://learn.microsoft.com/windows/win32/fileio/maximum-file-path-limitation'
            step = [ordered]@{ type = 'reg'; description = 'Enable long paths'; op = 'add'; path = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; name = 'LongPathsEnabled'; valueType = 'REG_DWORD'; data = '1' }
        }
        [ordered]@{
            id = 'verbose-status'; name = 'Startup: verbose status messages'; category = 'System'
            applies = 'both'; risk = 'safe'
            description = 'Shows detailed "please wait" status at boot/shutdown - handy while imaging.'
            source = 'https://learn.microsoft.com/troubleshoot/windows-client/user-profiles-and-logon/enable-verbose-startup-shutdown-logon-logoff-status-messages'
            step = [ordered]@{ type = 'reg'; description = 'Verbose status messages'; op = 'add'; path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'VerboseStatus'; valueType = 'REG_DWORD'; data = '1' }
        }
    )
}

function Get-AppTaskSequenceStepLibraryLists {
    <#
    .SYNOPSIS
        The catalog as the two lists the menu actually needs - one for client sequences,
        one for server - with the shared entries in both. Static data, so it carries a
        version the UI can cache against and only re-read when it changes.
    #>
    $all = @(Get-AppTaskSequenceStepLibrary)
    $shape = {
        param($Entry)
        $out = [ordered]@{
            id          = [string]$Entry.id
            name        = [string]$Entry.name
            category    = [string]$Entry.category
            applies     = [string]$Entry.applies
            risk        = [string]$Entry.risk
            description = [string]$Entry.description
            source      = [string]$Entry.source
            stepType    = [string]$Entry.step.type
        }
        if ($Entry.Contains('parameter') -and $Entry['parameter']) {
            $out['parameter'] = [ordered]@{
                name    = [string]$Entry['parameter']['name']
                label   = [string]$Entry['parameter']['label']
                type    = [string]$Entry['parameter']['type']
                default = [string]$Entry['parameter']['default']
                choices = @(if ($Entry['parameter'].Contains('choices')) { $Entry['parameter']['choices'] | ForEach-Object { [string]$_ } } else { @() })
            }
        }
        $out
    }
    $client = @($all | Where-Object { [string]$_.applies -in @('client', 'both') } | ForEach-Object { & $shape $_ })
    $server = @($all | Where-Object { [string]$_.applies -in @('server', 'both') } | ForEach-Object { & $shape $_ })
    [ordered]@{
        # Bump when entries change so a cached menu knows to re-read.
        version    = 1
        categories = @($all | ForEach-Object { [string]$_.category } | Sort-Object -Unique)
        client     = $client
        server     = $server
        counts     = [ordered]@{ client = $client.Count; server = $server.Count; total = $all.Count }
    }
}

function Get-AppTaskSequenceStepFromLibrary {
    <#
    .SYNOPSIS
        Turn a library id (+ the technician's value, if the entry takes one) into a step
        ready to append to a sequence.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Value = ''
    )
    $entry = @(Get-AppTaskSequenceStepLibrary | Where-Object { [string]$_.id -eq $Id })
    if ($entry.Count -eq 0) { throw "Task sequence library: unknown entry '$Id'." }
    $entry = $entry[0]
    $step = [ordered]@{}
    foreach ($key in $entry.step.Keys) { $step[$key] = $entry.step[$key] }

    $hasParameter = $entry.Contains('parameter') -and $entry['parameter']
    if ($hasParameter) {
        $chosen = if ([string]::IsNullOrWhiteSpace($Value)) { [string]$entry['parameter']['default'] } else { [string]$Value }
        if ([string]$entry['parameter']['type'] -eq 'choice') {
            $choices = @($entry['parameter']['choices'] | ForEach-Object { [string]$_ })
            if ($choices -notcontains $chosen) {
                throw "Task sequence library: '$chosen' is not a valid value for $Id (expected one of: $($choices -join ', '))."
            }
        }
        # A value that could break out of the generated command line is refused outright
        # rather than escaped - these are settings, not free-form script.
        if ($chosen -match '["`&|<>^%]') {
            throw "Task sequence library: the value for $Id contains characters that are not allowed in a command line."
        }
        foreach ($field in @('data', 'command', 'description')) {
            if ($step.Contains($field) -and [string]$step[$field]) {
                $step[$field] = ([string]$step[$field]).Replace('{{VALUE}}', $chosen)
            }
        }
        if ($step.Contains('description')) { $step['description'] = "$([string]$step['description']) ($chosen)" }
    }
    return $step
}

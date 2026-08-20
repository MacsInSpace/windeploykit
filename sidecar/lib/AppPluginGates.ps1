# Plug-in enablement gates -- generic enabledPlugins map from ApplyRuntimeConfig.
#
# The UI resolves per-school overrides and pushes one map of pluginId -> bool on every
# settings/school change (see docs/core/plugins/AGENT_NOTES_PLUGIN_ARCHITECTURE.md).
# The sidecar never sees per-school logic; it stores the resolved booleans here.
#
# Proactive plug-ins with their own transition side effects (Netboot store init, aria2
# store init) keep their Set-App*RuntimeEnabled helpers; Handle-ApplyRuntimeConfig calls
# them with the map values. Everything else reads Test-AppPluginRuntimeEnabled.

function Set-AppEnabledPluginsRuntimeConfig {
    <#
    .SYNOPSIS
        Normalize and store the enabledPlugins map (hashtable or JSON-deserialized
        PSCustomObject) into AppState.RuntimeConfig.enabledPlugins. Returns the
        normalized hashtable, or $null when the input is unusable.
    #>
    param($Map)
    if ($null -eq $Map) { return $null }
    $norm = @{}
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) { $norm[[string]$key] = [bool]$Map[$key] }
    } elseif ($Map -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Map.PSObject.Properties) { $norm[[string]$prop.Name] = [bool]$prop.Value }
    } else {
        Write-SidecarLog "ApplyRuntimeConfig: ignoring enabledPlugins of unexpected type $($Map.GetType().Name)"
        return $null
    }
    if (-not $script:AppState['RuntimeConfig']) { $script:AppState['RuntimeConfig'] = @{} }
    $script:AppState['RuntimeConfig']['enabledPlugins'] = $norm
    return $norm
}

function Test-AppPluginRuntimeEnabled {
    <#
    .SYNOPSIS
        Whether a plug-in is enabled per the last pushed enabledPlugins map.
        Absent map or absent key means disabled (plug-ins are off by default).
    #>
    param([Parameter(Mandatory)][string]$PluginId)
    $rc = $script:AppState['RuntimeConfig']
    if (-not $rc -or -not $rc.ContainsKey('enabledPlugins')) { return $false }
    $map = $rc['enabledPlugins']
    if (-not ($map -is [System.Collections.IDictionary]) -or -not $map.Contains($PluginId)) { return $false }
    return [bool]$map[$PluginId]
}

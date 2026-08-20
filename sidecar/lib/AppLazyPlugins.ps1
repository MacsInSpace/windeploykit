# Lazy plug-in loading -- load-on-first-IPC, sticky (never unloaded).
#
# Selected reactive, isolation-audited plug-ins are NOT dot-sourced at bootstrap.
# Their handler files are AST-parsed (no execution) to index command -> plugin; the
# dispatcher calls Ensure-AppLazyPluginForCommand before resolving Handle-$Cmd, which
# loads the plug-in's lib + handler files on first use.
#
# HOW LOADING WORKS (scope): plain dot-sourcing inside a function would define the
# plug-in's functions in that function's scope and lose them on return. The loader
# therefore rewrites each file's TOP-LEVEL function definitions to "function script:Name"
# via AST extents (byte-exact splice, immune to here-strings) and dot-invokes the result;
# script:-scoped definitions land in the sidecar script scope from any call depth.
# Top-level state init in these libs already uses $script: variables, which resolve to
# the sidecar script scope regardless of call depth. $PSScriptRoot is provided as a
# loader-local so top-level "Join-Path $PSScriptRoot ..." statements keep working.
#
# WHICH PLUG-INS ARE ELIGIBLE (audit 2026-08-04, re-run before adding any):
#   - Reactive only (no bootstrap/ApplyRuntimeConfig/dispatch-loop hooks). Proactive
#     plug-ins (pxe-boot, aria2, cisco-prime, GPO viewers) stay eager.
#   - No function referenced from outside the plug-in's own files, except behind an
#     explicit Get-Command guard (papercut's balance job) or covered by ExtraCommands.
#   - NOT eligible and why (recorded so nobody re-walks this):
#       eduhub  -- Get-AppEduHubDataset / student-cases match called from
#                  SiteDirectoryCache.ps1, LocalAdHomeGroup.ps1 and windeploykit-sidecar.ps1.
#       compass -- Ensure-AppCompassOu called from LocalAdUserProvisioning.ps1 (user
#                  creation flow); a missed command mapping would crash mid-create.
#       ventraip - Add-AppVentraIpEmailAccount etc. called from LocalAdUserProvisioning.
#     local-school-domain stays eager (site-directory dataset refresh closures call it).

$script:AppLazyPluginSpecs = [ordered]@{
    'mist'       = @{ Libs = @('MistPlugin.ps1');       Handlers = @('Plugin.Mist.ps1') }
    'meraki'     = @{ Libs = @('MerakiPlugin.ps1');     Handlers = @('Plugin.Meraki.ps1') }
    'solarwinds' = @{ Libs = @('SolarWindsPlugin.ps1'); Handlers = @('Plugin.SolarWinds.ps1') }
    'papercut'   = @{ Libs = @('PaperCutPlugin.ps1');   Handlers = @('Plugin.PaperCut.ps1') }
    'servicenow' = @{ Libs = @('ServiceNowPlugin.ps1'); Handlers = @('Plugin.ServiceNow.ps1') }
    'wms'        = @{ Libs = @('WmsPlugin.ps1');        Handlers = @('Plugin.Wms.ps1') }
    'oliver'     = @{ Libs = @('OliverPlugin.ps1');     Handlers = @('Plugin.Oliver.ps1') }
    'mdm'        = @{ Libs = @('MdmKitPlugin.ps1');     Handlers = @('Plugin.Mdm.ps1') }
    'asm'        = @{ Libs = @('AsmPlugin.ps1');        Handlers = @('Plugin.Asm.ps1') }
    'arcade'     = @{ Libs = @('ArcadePacks.ps1');      Handlers = @('Arcade.ps1') }
    'site-build' = @{ Libs = @('SiteBuildPlugin.ps1', 'AppWsManClient.ps1'); Handlers = @('Plugin.SiteBuild.ps1') }
}

$script:AppLazyCommandToPlugin = @{}
$script:AppLazyPluginLoaded = @{}

function Get-AppLazyPluginHandlerFileNames {
    # Handler files the bootstrap glob must skip (they load lazily instead).
    $names = @()
    foreach ($spec in $script:AppLazyPluginSpecs.Values) { $names += $spec.Handlers }
    return $names
}

function Initialize-AppLazyPluginIndex {
    # Parse (never execute) each lazy handler file to map Handle-* commands to their
    # plug-in. Runs once at bootstrap; ~10 ms total.
    param([Parameter(Mandatory)][string]$SidecarRoot)
    foreach ($pluginId in $script:AppLazyPluginSpecs.Keys) {
        $spec = $script:AppLazyPluginSpecs[$pluginId]
        foreach ($handlerFile in $spec.Handlers) {
            $path = Join-Path $SidecarRoot (Join-Path 'handlers' $handlerFile)
            $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
            if ($errs) { throw "lazy plugin index: parse errors in $handlerFile" }
            foreach ($st in $ast.EndBlock.Statements) {
                if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $st.Name -like 'Handle-*') {
                    $script:AppLazyCommandToPlugin[$st.Name.Substring(7)] = $pluginId
                }
            }
        }
        if ($spec.ContainsKey('ExtraCommands')) {
            foreach ($cmd in $spec.ExtraCommands) { $script:AppLazyCommandToPlugin[$cmd] = $pluginId }
        }
    }
    # Runs during the dot-source block, before $script:AppState exists -- the verbose
    # logger reads AppState (debug flag), so guard or it throws under StrictMode.
    if (Get-Variable -Name AppState -Scope Script -ErrorAction SilentlyContinue) {
        Write-SidecarLogVerbose "Lazy plug-ins: $($script:AppLazyPluginSpecs.Keys.Count) deferred, $($script:AppLazyCommandToPlugin.Count) commands indexed."
    } else {
        Write-SidecarLog "Lazy plug-ins: $($script:AppLazyPluginSpecs.Keys.Count) deferred, $($script:AppLazyCommandToPlugin.Count) commands indexed."
    }
}

function Invoke-AppLazyPluginFileLoad {
    # Load one .ps1 into the sidecar script scope from any call depth: splice
    # "script:" onto top-level function names via AST extents, then dot-invoke.
    param([Parameter(Mandatory)][string]$Path)
    $content = [System.IO.File]::ReadAllText($Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, $Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "lazy load: parse errors in $Path" }
    $edits = foreach ($st in $ast.EndBlock.Statements) {
        if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $st.Name -notmatch '^(script|global):') {
            # Function extent starts at "function" (or "filter"); insert before the name,
            # which begins at extent start + keyword + whitespace. Locate the name inside
            # the extent text to keep the offset exact.
            $extentText = $st.Extent.Text
            $nameIdx = $extentText.IndexOf($st.Name, [System.StringComparison]::Ordinal)
            if ($nameIdx -lt 0) { throw "lazy load: cannot locate name of $($st.Name) in $Path" }
            [pscustomobject]@{ Offset = $st.Extent.StartOffset + $nameIdx }
        }
    }
    $sb = [System.Text.StringBuilder]::new($content)
    foreach ($edit in ($edits | Sort-Object Offset -Descending)) {
        [void]$sb.Insert($edit.Offset, 'script:')
    }
    # Re-parse the spliced text WITH the original path and execute via GetScriptBlock()
    # so definitions keep their file affiliation -- $PSScriptRoot and ScriptBlock.File
    # resolve inside loaded functions (SiteBuildPlugin's lib-root probe needs this).
    # [scriptblock]::Create() would lose the file and break both.
    $errs = $null
    $splicedAst = [System.Management.Automation.Language.Parser]::ParseInput($sb.ToString(), $Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "lazy load: spliced content failed to parse for $Path" }
    $PSScriptRoot = Split-Path -Parent $Path
    . $splicedAst.GetScriptBlock()
}

function Ensure-AppLazyPluginLoaded {
    param([Parameter(Mandatory)][string]$PluginId)
    if ($script:AppLazyPluginLoaded.ContainsKey($PluginId)) { return }
    $spec = $script:AppLazyPluginSpecs[$PluginId]
    if (-not $spec) { throw "unknown lazy plugin '$PluginId'" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($lib in $spec.Libs) {
        Invoke-AppLazyPluginFileLoad -Path (Join-Path $script:SidecarRoot (Join-Path 'lib' $lib))
    }
    foreach ($handlerFile in $spec.Handlers) {
        Invoke-AppLazyPluginFileLoad -Path (Join-Path $script:SidecarRoot (Join-Path 'handlers' $handlerFile))
    }
    $script:AppLazyPluginLoaded[$PluginId] = $true
    Write-SidecarLog "Lazy plug-in '$PluginId' loaded on first use ($($spec.Libs.Count + $spec.Handlers.Count) files, $($sw.ElapsedMilliseconds) ms)."
}

function Ensure-AppLazyPluginForCommand {
    # Dispatcher hook: load the owning plug-in before Handle-$Cmd resolution.
    param([Parameter(Mandatory)][string]$Cmd)
    $pluginId = $script:AppLazyCommandToPlugin[$Cmd]
    if ($pluginId) { Ensure-AppLazyPluginLoaded -PluginId $pluginId }
}

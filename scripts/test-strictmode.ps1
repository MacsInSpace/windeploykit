<#
.SYNOPSIS
    Regression gate for Set-StrictMode -Version Latest faults. See README "StrictMode".

.DESCRIPTION
    The sidecar runs every dot-sourced lib under Set-StrictMode -Version Latest.
    Under it, reading a property that does not exist THROWS instead of returning
    $null. ConvertFrom-Json omits absent keys entirely, so any optional field read
    directly is a latent crash.

    The trap that catches people: a null guard does NOT protect you.
        if ($null -ne $json.maybe) { ... }   # THROWS - the read happens first
        if ($json.maybe) { ... }             # THROWS - same reason
    Only a presence test is safe, which is what Get-AppSidecarJsonProp does.

    Exits non-zero on any failure so it can gate CI.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
function Check { param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok) { Write-Host ("  [OK  ] {0}" -f $Name) }
        else { Write-Host ("  [FAIL] {0}" -f $Name); [void]$failures.Add($Name) }
    } catch {
        Write-Host ("  [FAIL] {0} - {1}" -f $Name, $_.Exception.Message)
        [void]$failures.Add($Name)
    }
}

Write-Host 'Get-AppSidecarJsonProp under StrictMode:'
if (-not (Get-Command Write-SidecarLog -ErrorAction SilentlyContinue)) { function Write-SidecarLog { param($Message) } }
. (Join-Path $projectRoot 'sidecar/lib/Ipc.ps1')

$json = '{"present":1,"nested":{"deep":2}}' | ConvertFrom-Json
Check 'present property returns its value'  { (Get-AppSidecarJsonProp -Item $json -Name 'present') -eq 1 }
Check 'absent property returns null'        { $null -eq (Get-AppSidecarJsonProp -Item $json -Name 'missing') }
Check 'null item returns null'              { $null -eq (Get-AppSidecarJsonProp -Item $null -Name 'anything') }
Check 'nested read chains safely'           { $null -eq (Get-AppSidecarJsonProp -Item (Get-AppSidecarJsonProp -Item $json -Name 'absent') -Name 'deep') }
Check 'hashtable missing key returns null'  { $null -eq (Get-AppSidecarJsonProp -Item @{ a = 1 } -Name 'b') }
Check 'hashtable present key returns value' { (Get-AppSidecarJsonProp -Item @{ a = 1 } -Name 'a') -eq 1 }

Write-Host ''
Write-Host 'IPC dispatch answers malformed requests (no silent hang):'
$sidecar = Join-Path $projectRoot 'sidecar/windeploykit-sidecar.ps1'
$requests = @(
    '{"id":901}'                                   # no cmd at all
    '{"id":902,"cmd":""}'                          # empty cmd
    '{"id":903,"cmd":"GetPxeBootPluginStatus"}'    # no params
) -join "`n"
$out = $requests | & pwsh -NoProfile -File $sidecar 2>$null
$answered = @{}
foreach ($line in @($out)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $oid = Get-AppSidecarJsonProp -Item $o -Name 'id'
    if ($null -ne $oid) { $answered[[string]$oid] = $o }
}
Check 'request with no cmd gets an error response'  { $answered.ContainsKey('901') -and -not $answered['901'].ok }
Check 'request with empty cmd gets an error'        { $answered.ContainsKey('902') -and -not $answered['902'].ok }
Check 'request with no params still succeeds'       { $answered.ContainsKey('903') -and $answered['903'].ok }

Write-Host ''
Write-Host 'No unsafe null-guards on JSON reads (the guard that does not guard):'
$libs = Get-ChildItem -Path (Join-Path $projectRoot 'sidecar') -Recurse -Filter *.ps1 |
    Where-Object { $_.FullName -notmatch 'wim-inject' }
$unsafe = [System.Collections.Generic.List[string]]::new()
foreach ($f in $libs) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        # $x.PSObject... is the SAFE form; anything else reading a property inside a
        # null comparison is the trap.
        if ($line -match '\$null -(ne|eq) \$[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z]' -and $line -notmatch 'PSObject') {
            [void]$unsafe.Add(("{0}:{1}" -f $f.Name, $n))
        }
    }
}
# Reviewed and safe. Each entry needs a REASON, so adding to this list is a
# deliberate decision rather than a way to silence the gate.
$allowed = @{
    # Read-AppPxeBootConfig merges the file over a full $defaults set, so every key
    # of the object it returns is always present.
    'PxeBootPlugin.ps1:236' = 'config object always carries every default key'
    'PxeBootPlugin.ps1:243' = 'config object always carries every default key'
    'PxeBootPlugin.ps1:250' = 'config object always carries every default key'
    'PxeBootPlugin.ps1:272' = 'config object always carries every default key'
    # $prop came from .PSObject.Properties[...] on the line above and is short-circuit
    # guarded by -not $prop; PSPropertyInfo always exposes .Value.
    'PxeBootPlugin.ps1:1767' = 'PSPropertyInfo.Value, guarded by -not $prop first'
    'PxeBootPlugin.ps1:1777' = 'PSPropertyInfo.Value, guarded by -not $prop first'
    # Invoke-WebRequest response objects always expose .Content.
    'Aria2TrackerScrape.ps1:180' = 'web response object always has .Content'
}
$new = @($unsafe | Where-Object { -not $allowed.ContainsKey($_) })
if ($new.Count -eq 0) { Write-Host ('  [OK  ] none new ({0} reviewed and allowlisted)' -f $allowed.Count) }
else {
    foreach ($u in $new) { Write-Host ("  [FAIL] unsafe null-guard at {0}" -f $u) }
    [void]$failures.Add('unsafe null-guards')
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("strictmode: {0} failure(s)" -f $failures.Count)
    exit 1
}
Write-Host 'strictmode: all checks passed'
exit 0

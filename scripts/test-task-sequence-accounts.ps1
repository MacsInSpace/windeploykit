#requires -Version 7.0
<#
.SYNOPSIS
    Offline gate for the task sequence local account (name, password source, autologon).
.DESCRIPTION
    The account block is what creates the only usable login on a fresh machine, so its
    three shapes are pinned here: a configured account, the legacy {{LocalAdminPw}} token
    when a profile supplies one, and NOTHING when neither is available (publishing the
    literal token as a password produced an unattend that could not work).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SidecarRoot = Join-Path $RepoRoot 'sidecar'
$script:SidecarRoot = $SidecarRoot
$script:AppState = @{ IsReady = $true }
. (Join-Path $SidecarRoot 'lib/AppPaths.ps1')
function Write-SidecarLog { param([string]$Message, [switch]$Flush) }
function Write-SidecarLogVerbose { param([string]$Message) }
. (Join-Path $SidecarRoot 'lib/AppProductIdentity.ps1')
. (Join-Path $SidecarRoot 'lib/ServerEvalConversion.ps1')
. (Join-Path $SidecarRoot 'lib/PxeBootTaskSequences.ps1')

$failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  [OK  ] $Name" }
    catch { Write-Host "  [FAIL] $Name - $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:failures++ }
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-AccountXml {
    param($Account, [string]$Password, [bool]$Legacy = $false, [string[]]$Groups = @(), [bool]$EmitGroups = $false)
    Get-AppPxeBootTsOobeAccounts -AdminGroups $Groups -EmitGroups $EmitGroups -LocalAccount $Account -LocalPassword $Password -LegacyLocalAdminAvailable $Legacy
}
function Assert-Xml { param([string]$Fragment) $null = [xml]("<root xmlns:wcm='urn:wcm'>" + $Fragment + "</root>") }

Write-Host 'Unattend password obfuscation:'
Test-Case 'Round-trips through Windows own base64 scheme' {
    $encoded = ConvertTo-AppPxeBootTsUnattendPassword -Password 'Sup3r Secret!' -ElementName 'Password'
    Assert-True ($encoded -ne 'Sup3r Secret!') 'the value was not encoded'
    $decoded = ConvertFrom-AppPxeBootTsUnattendPassword -Value $encoded -ElementName 'Password'
    Assert-True ($decoded -eq 'Sup3r Secret!') "decoded to '$decoded'"
}
Test-Case 'The element name is part of the payload (Setup rejects a mismatch)' {
    $asPassword = ConvertTo-AppPxeBootTsUnattendPassword -Password 'abc' -ElementName 'Password'
    $asAdmin = ConvertTo-AppPxeBootTsUnattendPassword -Password 'abc' -ElementName 'AdministratorPassword'
    Assert-True ($asPassword -ne $asAdmin) 'both element names produced the same value'
    $raw = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($asPassword))
    Assert-True ($raw -eq 'abcPassword') "payload was '$raw'"
}
Test-Case 'An empty password encodes to nothing' {
    Assert-True ((ConvertTo-AppPxeBootTsUnattendPassword -Password '' ) -eq '') 'expected empty'
}

Write-Host ''
Write-Host 'Account configuration:'
Test-Case 'Defaults are filled in for a sequence with no account block' {
    $cfg = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{ id = 'x' })
    Assert-True (-not $cfg.enabled) 'should be disabled by default'
    Assert-True ($cfg.name -eq 'localadmin') "name was '$($cfg.name)'"
    Assert-True ($cfg.group -eq 'Administrators') "group was '$($cfg.group)'"
    Assert-True (-not $cfg.autoLogon) 'autologon should default off'
}
Test-Case 'A manual password is stored base64 and resolves back' {
    $stored = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('P@ssw0rd!'))
    $seq = [ordered]@{ localAccount = [ordered]@{ enabled = $true; passwordSource = 'manual'; password = $stored } }
    $cfg = Get-AppPxeBootTsLocalAccountConfig -Sequence $seq
    Assert-True ((Resolve-AppPxeBootTsLocalAccountPassword -Account $cfg) -eq 'P@ssw0rd!') 'manual password did not resolve'
}
Test-Case 'A vault account with no secret name resolves to nothing' {
    $seq = [ordered]@{ localAccount = [ordered]@{ enabled = $true; passwordSource = 'vault'; vaultSecret = '' } }
    $cfg = Get-AppPxeBootTsLocalAccountConfig -Sequence $seq
    Assert-True ((Resolve-AppPxeBootTsLocalAccountPassword -Account $cfg) -eq '') 'expected empty'
}
Test-Case 'A disabled account resolves to nothing even with a password set' {
    $seq = [ordered]@{ localAccount = [ordered]@{ enabled = $false; passwordSource = 'manual'; password = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('x')) } }
    $cfg = Get-AppPxeBootTsLocalAccountConfig -Sequence $seq
    Assert-True ((Resolve-AppPxeBootTsLocalAccountPassword -Account $cfg) -eq '') 'expected empty'
}

Write-Host ''
Write-Host 'Generated oobeSystem block:'
$configured = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{
        localAccount = [ordered]@{ enabled = $true; name = 'deployadmin'; displayName = 'Deploy Admin'; group = 'Administrators'; passwordSource = 'manual'; password = 'x'; autoLogon = $true }
    })

Test-Case 'A configured account is emitted with an obfuscated password' {
    $xml = Get-AccountXml -Account $configured -Password 'Hunter2!'
    Assert-Xml $xml
    Assert-True ($xml -match '<Name>deployadmin</Name>') 'account name missing'
    Assert-True ($xml -match '<PlainText>false</PlainText>') 'password was not marked obfuscated'
    Assert-True ($xml -notmatch 'Hunter2!') 'the password is in clear text in the unattend'
    Assert-True ($xml -notmatch 'LocalAdminPw') 'the legacy token leaked into a configured account'
    $value = ([regex]'<Value>([^<]+)</Value>').Match($xml).Groups[1].Value
    Assert-True ((ConvertFrom-AppPxeBootTsUnattendPassword -Value $value) -eq 'Hunter2!') 'the encoded password does not decode back'
}
Test-Case 'AutoLogon is emitted once, and only when asked for' {
    $withLogon = Get-AccountXml -Account $configured -Password 'Hunter2!'
    Assert-True ($withLogon -match '<AutoLogon>') 'autologon missing when requested'
    Assert-True ($withLogon -match '<LogonCount>1</LogonCount>') 'autologon should be a single logon'
    $noLogon = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{
            localAccount = [ordered]@{ enabled = $true; name = 'deployadmin'; passwordSource = 'manual'; password = 'x'; autoLogon = $false }
        })
    $xml = Get-AccountXml -Account $noLogon -Password 'Hunter2!'
    Assert-True ($xml -notmatch '<AutoLogon>') 'autologon emitted when not requested'
    Assert-True ($xml -match '<Name>deployadmin</Name>') 'the account itself should still be created'
}
Test-Case 'No account and no profile password emits nothing at all' {
    $off = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{ id = 'x' })
    $xml = Get-AccountXml -Account $off -Password '' -Legacy $false
    Assert-True ([string]::IsNullOrWhiteSpace($xml)) "expected an empty block, got: $xml"
    Assert-True ($xml -notmatch 'LocalAdminPw') 'the literal token would have been published as a password'
}
Test-Case 'The legacy token block is unchanged when a profile supplies one' {
    $off = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{ id = 'x' })
    $xml = Get-AccountXml -Account $off -Password '' -Legacy $true
    Assert-Xml $xml
    Assert-True ($xml -match '\{\{LocalAdminPw\}\}') 'the token block should still be produced'
    Assert-True ($xml -match '<Name>localadmin</Name>') 'the legacy account name changed'
}
Test-Case 'Admin groups still ride along with a configured account' {
    $xml = Get-AccountXml -Account $configured -Password 'Hunter2!' -Groups @('DOMAIN\Techs') -EmitGroups $true
    Assert-Xml $xml
    Assert-True ($xml -match 'DOMAIN\\Techs') 'the admin group was dropped'
    Assert-True ($xml -match '<Name>deployadmin</Name>') 'the local account was dropped'
}
Test-Case 'Groups alone (no local account, no token) still produce a valid block' {
    $off = Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{ id = 'x' })
    $xml = Get-AccountXml -Account $off -Password '' -Legacy $false -Groups @('DOMAIN\Techs') -EmitGroups $true
    Assert-Xml $xml
    Assert-True ($xml -match 'DomainAccounts') 'expected the domain accounts block'
    Assert-True ($xml -notmatch 'LocalAccounts') 'no local account should be invented'
}

Write-Host ''
Write-Host 'Saving a sequence:'
Test-Case 'A typed password is stored base64, and re-saving does not double-encode it' {
    $seq = [ordered]@{
        id = 'client-1'; name = 'Client'; kind = 'client'; enabled = $true; fields = [ordered]@{}
        localAccount = [ordered]@{ enabled = $true; name = 'deployadmin'; group = 'Administrators'; passwordSource = 'manual'; passwordPlain = 'Hunter2!'; autoLogon = $true }
    }
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq
    Assert-True ($null -ne $rec.localAccount) 'the local account was dropped on save'
    Assert-True ([string]$rec.localAccount.password -ne 'Hunter2!') 'the password was stored in clear'
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$rec.localAccount.password))
    Assert-True ($decoded -eq 'Hunter2!') "stored value decoded to '$decoded'"
    # Re-save the record as the panel would (no passwordPlain this time).
    $again = ConvertTo-AppPxeBootTaskSequenceRecord -Item $rec
    Assert-True ([string]$again.localAccount.password -eq [string]$rec.localAccount.password) 'the stored password changed on re-save'
    Assert-True ((Resolve-AppPxeBootTsLocalAccountPassword -Account (Get-AppPxeBootTsLocalAccountConfig -Sequence $again)) -eq 'Hunter2!') 'the password no longer resolves after a re-save'
}
Test-Case 'A sequence with no account block saves without inventing one' {
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([ordered]@{ id = 'x'; name = 'x'; kind = 'client'; enabled = $true; fields = [ordered]@{} })
    Assert-True (-not $rec.Contains('localAccount')) 'an empty local account was invented'
}
Test-Case 'A pwshEncoded step survives a save' {
    # The Server evaluation conversion is one of these; it used to be silently dropped.
    $seq = [ordered]@{
        id = 'server-1'; name = 'Server'; kind = 'server'; enabled = $true; fields = [ordered]@{}
        steps = @([ordered]@{ type = 'pwshEncoded'; description = 'Convert evaluation'; command = 'Write-Host hello' })
    }
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq
    Assert-True (@($rec.steps).Count -eq 1) "expected the step to survive, got $(@($rec.steps).Count)"
    Assert-True ([string]$rec.steps[0].type -eq 'pwshEncoded') "type came back as '$($rec.steps[0].type)'"
    Assert-True ([string]$rec.steps[0].command -eq 'Write-Host hello') 'the script body was lost'
}
Test-Case 'The seeded Server sequence keeps its conversion step through a save' {
    $server = @(@(Get-AppPxeBootTaskSequenceDefaults) | Where-Object { $_.kind -eq 'server' })[0]
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $server
    Assert-True (@(@($rec.steps) | Where-Object { [string]$_.type -eq 'pwshEncoded' }).Count -eq 1) 'the evaluation conversion step was dropped on save'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "task sequence accounts: $failures failure(s)"
    exit 1
}
Write-Host 'task sequence accounts: all checks passed'
exit 0

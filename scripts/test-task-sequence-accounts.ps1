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
    Assert-True ($cfg.autoLogonCount -eq 0) "autologon should default to 0, was '$($cfg.autoLogonCount)'"
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
    # The fixture still uses the old boolean, so this also proves a sequence saved
    # before the 0-5 dropdown keeps signing in twice.
    Assert-True ($withLogon -match '<LogonCount>2</LogonCount>') 'a legacy autoLogon=true should still be LogonCount 2'
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

Test-Case 'Auto sign-in count: 0 emits nothing, 1-5 ride through, out of range is clamped' {
    $mk = {
        param($count)
        Get-AppPxeBootTsLocalAccountConfig -Sequence ([ordered]@{
                localAccount = [ordered]@{ enabled = $true; name = 'deployadmin'; passwordSource = 'manual'; password = 'x'; autoLogonCount = $count }
            })
    }
    Assert-True ((Get-AccountXml -Account (& $mk 0) -Password 'Hunter2!') -notmatch '<AutoLogon>') '0 should emit no AutoLogon block'
    foreach ($n in 1, 2, 3, 4, 5) {
        $xml = Get-AccountXml -Account (& $mk $n) -Password 'Hunter2!'
        Assert-True ($xml -match "<LogonCount>$n</LogonCount>") "count $n did not reach the unattend"
    }
    # A hand-edited sequence file should not be able to ask for 99 sign-ins.
    Assert-True ((Get-AccountXml -Account (& $mk 9) -Password 'Hunter2!') -match '<LogonCount>5</LogonCount>') 'out of range should clamp to 5'
    Assert-True ((& $mk 'nonsense').autoLogonCount -eq 0) 'junk should read as 0'
}

Test-Case 'first-boot finale: restart by default, validated values, none allowed' {
    $mk = { param($v) [ordered]@{ id = 'x'; fields = [ordered]@{ firstBootAction = $v } } }
    Assert-True ((Get-AppPxeBootTsFirstBootAction -Sequence ([ordered]@{ id = 'x' })) -eq 'restart') 'no field defaults to restart'
    Assert-True ((Get-AppPxeBootTsFirstBootAction -Sequence (& $mk 'nonsense')) -eq 'restart') 'junk defaults to restart'
    foreach ($v in 'none', 'restart', 'shutdown', 'signout') {
        Assert-True ((Get-AppPxeBootTsFirstBootAction -Sequence (& $mk $v)) -eq $v) "value '$v' rides through"
    }
    Assert-True ((Get-AppPxeBootTsFirstBootAction -Sequence (& $mk 'SHUTDOWN')) -eq 'shutdown') 'case-insensitive'
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
Test-Case 'Local account mode: none/manual resolve; legacy enabled+source maps to mode' {
    # 2026-08-23 (Craig): one mode - none | manual | vault. Vault takes user+password
    # from the credential (covered live; needs a vault). Here: manual + none + legacy.
    $mkManual = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([ordered]@{
            id = 'm'; name = 'm'; kind = 'server'; enabled = $true; fields = [ordered]@{}
            localAccount = [ordered]@{ mode = 'manual'; name = 'deployadmin'; passwordPlain = 'P@ss1!'; group = 'Administrators'; autoLogon = $true }
        })
    Assert-True ([string]$mkManual.localAccount.mode -eq 'manual') 'manual mode not stored'
    $rM = Resolve-AppPxeBootTsLocalAccount -Account (Get-AppPxeBootTsLocalAccountConfig -Sequence $mkManual)
    Assert-True ($null -ne $rM) 'manual account did not resolve'
    Assert-True ([string]$rM.user -eq 'deployadmin') "manual user came back '$($rM.user)'"
    Assert-True (-not [string]::IsNullOrEmpty([string]$rM.pass)) 'manual password did not resolve'

    $mkNone = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([ordered]@{
            id = 'n'; name = 'n'; kind = 'server'; enabled = $true; fields = [ordered]@{}
            localAccount = [ordered]@{ mode = 'none' }
        })
    Assert-True ($null -eq (Resolve-AppPxeBootTsLocalAccount -Account (Get-AppPxeBootTsLocalAccountConfig -Sequence $mkNone))) 'none mode should resolve to null'

    $mkLegacy = ConvertTo-AppPxeBootTaskSequenceRecord -Item ([ordered]@{
            id = 'l'; name = 'l'; kind = 'server'; enabled = $true; fields = [ordered]@{}
            localAccount = [ordered]@{ enabled = $true; passwordSource = 'vault'; vaultSecret = 'x' }
        })
    Assert-True ([string]$mkLegacy.localAccount.mode -eq 'vault') "legacy enabled+vault did not map to vault mode (got '$($mkLegacy.localAccount.mode)')"
}

Test-Case 'The unattend is structurally sane (the traps that made a bad answer file)' {
    $seq = [ordered]@{
        id = 'u'; name = 'u'; kind = 'server'; enabled = $true
        fields = [ordered]@{ computerName = 'SVR01'; network = 'dhcp'; productKey = '' }
        steps = @()
        localAccount = [ordered]@{ mode = 'manual'; name = 'localadmin'; passwordPlain = 'P@ss1!'; group = 'Administrators'; autoLogon = $true }
    }
    $xml = Build-AppPxeBootTaskSequenceUnattendXml -Sequence (ConvertTo-AppPxeBootTaskSequenceRecord -Item $seq)
    $doc = [xml]$xml
    Assert-True ($null -ne $doc) 'not well-formed XML'

    # Display language must be one that is actually IN the image. English media ships
    # en-US; naming a locale like en-AU here is how the answer file quietly fails.
    foreach ($m in [regex]::Matches($xml, '<UILanguage(?:Fallback)?>([^<]*)<')) {
        Assert-True ($m.Groups[1].Value -eq 'en-US') "UILanguage must be en-US, got '$($m.Groups[1].Value)'"
    }
    # Keyboard wants LCID:layout, not a bare language tag.
    foreach ($m in [regex]::Matches($xml, '<InputLocale>([^<]*)<')) {
        Assert-True ($m.Groups[1].Value -match '^[0-9a-f]{4}:[0-9a-f]{8}$') "InputLocale must be LCID:layout, got '$($m.Groups[1].Value)'"
    }
    # Regional formats DO follow the host.
    foreach ($tag in @('SystemLocale', 'UserLocale')) {
        Assert-True ($xml -match "<$tag>[a-z]{2}-[A-Z]{2}</$tag>") "$tag is not a locale"
    }
    # Passwords are the obfuscated form, never PlainText true.
    Assert-True ($xml -notmatch '<PlainText>true</PlainText>') 'a plain-text password reached the unattend'
    Assert-True ($xml -notmatch '\{\{[A-Za-z]+\}\}') 'an unsubstituted {{token}} reached the unattend'
    # No windowsPE pass: these images are applied with DISM, not setup.exe.
    Assert-True ($xml -notmatch 'pass="windowsPE"') 'a windowsPE pass reached a DISM-applied unattend'
    # Exactly the two passes we intend.
    Assert-True (([regex]::Matches($xml, '<settings pass=')).Count -eq 2) 'expected exactly specialize + oobeSystem'
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
Test-Case 'The seeded Server sequence carries no eval-conversion step (it moved out of the unattend)' {
    # 2026-08-23: the eval->licensed conversion is no longer a task-sequence step / a
    # 9KB EncodedCommand in the unattend (that made Setup reject the answer file at
    # specialize). It is convert-eval.ps1 + SetupComplete, installed into the image by
    # the deploy client. The seed must NOT re-add it as a step.
    $server = @(@(Get-AppPxeBootTaskSequenceDefaults) | Where-Object { $_.kind -eq 'server' })[0]
    $rec = ConvertTo-AppPxeBootTaskSequenceRecord -Item $server
    foreach ($s in @($rec.steps)) {
        Assert-True (-not (Test-AppPxeBootTsIsEvalConversionStep -Step $s)) 'the seed still injects the eval-conversion step'
    }
}
Test-Case 'A server unattend has no RunSynchronous and no ProductKey; the conversion is a separate script' {
    $server = @(@(Get-AppPxeBootTaskSequenceDefaults) | Where-Object { $_.kind -eq 'server' })[0]
    $xml = Build-AppPxeBootTaskSequenceUnattendXml -Sequence $server
    Assert-True (([regex]::Matches($xml, 'RunSynchronous')).Count -eq 0) 'steps are still baked into the unattend'
    Assert-True (([regex]::Matches($xml, 'EncodedCommand')).Count -eq 0) 'an EncodedCommand is still in the unattend'
    Assert-True (([regex]::Matches($xml, '<ProductKey>')).Count -eq 0) 'a server unattend must carry no product key (conversion licenses it)'
    # The conversion script itself is still produced, and it is real PowerShell.
    $payload = Get-AppServerEvalConversionPayload
    Assert-True ($payload -match '(?i)Set-Edition') 'convert-eval payload lost its /Set-Edition call'
    # And the first-boot script carries the ordinary steps instead.
    $fb = Get-AppPxeBootTsFirstBootScript -Sequence (ConvertTo-AppPxeBootTaskSequenceRecord -Item $server)
    Assert-True ($fb -match '(?i)reg add') 'the first-boot script lost the reg steps'
    Assert-True (-not ($fb -match '(?i)Convert-EvalEdition.ps1')) 'the eval conversion leaked into the first-boot steps'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "task sequence accounts: $failures failure(s)"
    exit 1
}
Write-Host 'task sequence accounts: all checks passed'
exit 0

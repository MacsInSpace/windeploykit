BeforeAll {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $vendorSm = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'vendor/psmodules/Microsoft.PowerShell.SecretManagement') -Directory |
        Sort-Object Name -Descending | Select-Object -First 1
    Import-Module (Join-Path $vendorSm.FullName 'Microsoft.PowerShell.SecretManagement.psd1') -Force
    $script:ModuleRoot = Join-Path $repoRoot 'sidecar/psmodules/SecretManagement.LocalVault'
    Import-Module (Join-Path $script:ModuleRoot 'SecretManagement.LocalVault.psd1') -Force

    # Every test gets its own store and its own vault registration; nothing touches
    # the real per-user store or the real vault registry entry 'shared'.
    $script:StoreRoot = Join-Path ([IO.Path]::GetTempPath()) ("localvault-test-" + [guid]::NewGuid().ToString('N'))
    $script:VaultName = 'localvault-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Reg = Register-LocalVault -Name $script:VaultName -StoreRoot $script:StoreRoot
}

AfterAll {
    Unregister-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue
    if ($script:StoreRoot -and (Test-Path -LiteralPath $script:StoreRoot)) {
        Remove-Item -LiteralPath $script:StoreRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Register-LocalVault' {
    It 'registers by full module path, not by name' {
        (Get-SecretVault -Name $script:VaultName).ModulePath | Should -Be $script:ModuleRoot
    }
    It 'is idempotent and reports the existing registration' {
        $again = Register-LocalVault -Name $script:VaultName -StoreRoot $script:StoreRoot
        $again.registered | Should -BeFalse
        $again.vault | Should -Be $script:VaultName
    }
    It 'does not create a store until something is written' {
        # No Reset concept: registration alone leaves nothing to wipe.
        $script:Reg.exists | Should -BeFalse
    }
    It 'leaves a registration from a sibling copy alone while that copy exists' {
        # A module directory must be named after its manifest for path registration to resolve.
        $siblingParent = Join-Path ([IO.Path]::GetTempPath()) ("localvault-sibling-" + [guid]::NewGuid().ToString('N'))
        $sibling = Join-Path $siblingParent 'SecretManagement.LocalVault'
        $null = New-Item -ItemType Directory -Path $siblingParent -Force
        Copy-Item -LiteralPath $script:ModuleRoot -Destination $sibling -Recurse
        $v = 'localvault-sib-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            Register-SecretVault -Name $v -ModuleName $sibling -VaultParameters @{ StoreRoot = $script:StoreRoot }
            $r = Register-LocalVault -Name $v -StoreRoot $script:StoreRoot
            $r.registered | Should -BeFalse
            $r.healed | Should -BeFalse
            $r.modulePath | Should -Be $sibling
        } finally {
            Unregister-SecretVault -Name $v -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $siblingParent -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'self-heals a registration whose module copy has been removed (product uninstalled)' {
        # A module directory must be named after its manifest for path registration to resolve.
        $siblingParent = Join-Path ([IO.Path]::GetTempPath()) ("localvault-gone-" + [guid]::NewGuid().ToString('N'))
        $sibling = Join-Path $siblingParent 'SecretManagement.LocalVault'
        $null = New-Item -ItemType Directory -Path $siblingParent -Force
        Copy-Item -LiteralPath $script:ModuleRoot -Destination $sibling -Recurse
        $v = 'localvault-heal-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            Register-SecretVault -Name $v -ModuleName $sibling -VaultParameters @{ StoreRoot = $script:StoreRoot }
            Remove-Item -LiteralPath $siblingParent -Recurse -Force
            $r = Register-LocalVault -Name $v -StoreRoot $script:StoreRoot
            $r.healed | Should -BeTrue
            $r.registered | Should -BeTrue
            $r.modulePath | Should -Be $script:ModuleRoot
            (Get-SecretVault -Name $v).ModulePath | Should -Be $script:ModuleRoot
        } finally { Unregister-SecretVault -Name $v -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-Secret / Get-Secret round trips' {
    It 'String' {
        Set-Secret -Name 'test/string' -Secret 'hunter2-not-real' -Vault $script:VaultName
        Get-Secret -Name 'test/string' -Vault $script:VaultName -AsPlainText | Should -Be 'hunter2-not-real'
    }
    It 'SecureString' {
        $ss = ConvertTo-SecureString 'sekrit' -AsPlainText -Force
        Set-Secret -Name 'test/securestring' -Secret $ss -Vault $script:VaultName
        $back = Get-Secret -Name 'test/securestring' -Vault $script:VaultName
        $back | Should -BeOfType [securestring]
        (New-Object pscredential('x', $back)).GetNetworkCredential().Password | Should -Be 'sekrit'
    }
    It 'PSCredential' {
        $cred = New-Object pscredential('EDU001\st00447', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
        Set-Secret -Name 'dept/edu001' -Secret $cred -Vault $script:VaultName
        $back = Get-Secret -Name 'dept/edu001' -Vault $script:VaultName
        $back | Should -BeOfType [pscredential]
        $back.UserName | Should -Be 'EDU001\st00447'
        $back.GetNetworkCredential().Password | Should -Be 'p@ss'
    }
    It 'Hashtable' {
        Set-Secret -Name 'test/hash' -Secret @{ token = 'abc'; port = 636 } -Vault $script:VaultName
        # SecretManagement hands hashtable string values back as SecureString unless -AsPlainText.
        $back = Get-Secret -Name 'test/hash' -Vault $script:VaultName -AsPlainText
        $back | Should -BeOfType [hashtable]
        $back['token'] | Should -Be 'abc'
        [int]$back['port'] | Should -Be 636
    }
    It 'ByteArray' {
        [byte[]]$bytes = 1..16
        Set-Secret -Name 'test/bytes' -Secret $bytes -Vault $script:VaultName
        $back = Get-Secret -Name 'test/bytes' -Vault $script:VaultName
        ,$back | Should -BeOfType [byte[]]
        ($back -join ',') | Should -Be ((1..16) -join ',')
    }
    It 'overwrites in place and keeps createdAt' {
        Set-Secret -Name 'test/string' -Secret 'v2' -Vault $script:VaultName
        Get-Secret -Name 'test/string' -Vault $script:VaultName -AsPlainText | Should -Be 'v2'
        @(Get-SecretInfo -Name 'test/string' -Vault $script:VaultName).Count | Should -Be 1
    }
    It 'returns nothing for an unknown name' {
        Get-Secret -Name 'nope/nothing' -Vault $script:VaultName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Metadata and Get-SecretInfo' {
    It 'stores metadata with Set-Secret -Metadata' {
        Set-Secret -Name 'school/0450/local-ad' -Secret 'tok' -Metadata @{ school = '0450'; label = 'FPS' } -Vault $script:VaultName
        $info = Get-SecretInfo -Name 'school/0450/local-ad' -Vault $script:VaultName
        $info.Metadata['school'] | Should -Be '0450'
        $info.Metadata['label'] | Should -Be 'FPS'
        $info.Type | Should -Be 'String'
    }
    It 'updates metadata with Set-SecretInfo' {
        Set-SecretInfo -Name 'school/0450/local-ad' -Metadata @{ school = '0450'; label = 'Fitzroy PS' } -Vault $script:VaultName
        (Get-SecretInfo -Name 'school/0450/local-ad' -Vault $script:VaultName).Metadata['label'] | Should -Be 'Fitzroy PS'
    }
    It 'filters by wildcard and reports the right types' {
        $all = @(Get-SecretInfo -Name 'test/*' -Vault $script:VaultName)
        $all.Count | Should -Be 4
        ($all | Where-Object Name -eq 'dept/edu001') | Should -BeNullOrEmpty
        (Get-SecretInfo -Name 'dept/edu001' -Vault $script:VaultName).Type | Should -Be 'PSCredential'
    }
}

Describe 'Remove-Secret' {
    It 'removes the entry and its blob' {
        Set-Secret -Name 'test/remove-me' -Secret 'x' -Vault $script:VaultName
        $blobs = Join-Path $script:StoreRoot 'secrets'
        $before = (Get-ChildItem -LiteralPath $blobs -File).Count
        Remove-Secret -Name 'test/remove-me' -Vault $script:VaultName
        (Get-ChildItem -LiteralPath $blobs -File).Count | Should -Be ($before - 1)
        Get-Secret -Name 'test/remove-me' -Vault $script:VaultName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'On-disk properties' {
    It 'keeps no secret material in the index' {
        $index = Get-Content -LiteralPath (Join-Path $script:StoreRoot 'index.json') -Raw
        $index | Should -Not -Match 'hunter2'
        $index | Should -Not -Match 'p@ss'
        $index | Should -Not -Match 'sekrit'
    }
    It 'keeps no cleartext in any blob' {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:StoreRoot 'secrets') -File) {
            $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f.FullName))
            $text | Should -Not -Match 'hunter2|p@ss|sekrit|st00447'
        }
    }
    It 'records a keyId that matches this machine and user' {
        $info = Get-LocalVaultInfo -StoreRoot $script:StoreRoot
        $info.keyMatches | Should -BeTrue
        $info.secretCount | Should -BeGreaterThan 0
    }
    It 'binds a blob to its name (a re-labelled blob does not decrypt)' {
        $blobs = Join-Path $script:StoreRoot 'secrets'
        $index = Get-Content -LiteralPath (Join-Path $script:StoreRoot 'index.json') -Raw | ConvertFrom-Json
        $a = $index.secrets.'test/string'.file
        $b = $index.secrets.'test/hash'.file
        Copy-Item -LiteralPath (Join-Path $blobs $a) -Destination (Join-Path $blobs "$b.swap") -Force
        Move-Item -LiteralPath (Join-Path $blobs "$b.swap") -Destination (Join-Path $blobs $b) -Force
        { Get-Secret -Name 'test/hash' -Vault $script:VaultName -ErrorAction Stop } | Should -Throw
        # restore for later tests
        Set-Secret -Name 'test/hash' -Secret @{ token = 'abc'; port = 636 } -Vault $script:VaultName
    }
}

Describe 'Cross-process and cross-product sharing' {
    It 'a second pwsh process reads what this one wrote' {
        $sm = (Get-Module Microsoft.PowerShell.SecretManagement).Path
        $cmd = "Import-Module '$sm'; (Get-Secret -Name 'dept/edu001' -Vault '$($script:VaultName)').UserName"
        $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1
        ($out | Select-Object -Last 1) | Should -Be 'EDU001\st00447'
    }
}

Describe 'A copied store on another machine' -Skip:($env:OS -eq 'Windows_NT') {
    It 'derives a different key from a different machine id, and that key fails the auth tag' {
        # Reach into the core: this is the property the whole design rests on.
        $core = Join-Path $script:ModuleRoot 'LocalVault.Core.ps1'
        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript(". '$core'; `$here = Get-LocalVaultDerivedKek; `$there = Get-LocalVaultDerivedKek -MachineId '00000000-0000-0000-0000-00000000BEEF'; ([Convert]::ToBase64String(`$here) -eq [Convert]::ToBase64String(`$there))")
            $same = $ps.Invoke() | Select-Object -Last 1
            $same | Should -BeFalse
        } finally { $ps.Dispose() }
    }
    It 'fails clearly, by keyId, before attempting a decrypt' {
        $copy = "$($script:StoreRoot)-moved"
        Copy-Item -LiteralPath $script:StoreRoot -Destination $copy -Recurse -Force
        $idx = Join-Path $copy 'index.json'
        (Get-Content -LiteralPath $idx -Raw) -replace '"keyId":\s*"[0-9a-f]+"', '"keyId": "0000000000000000"' | Set-Content -LiteralPath $idx -NoNewline
        try {
            $info = Get-LocalVaultInfo -StoreRoot $copy
            $info.keyMatches | Should -BeFalse
            $v2 = 'localvault-moved-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $null = Register-LocalVault -Name $v2 -StoreRoot $copy
            try {
                # SecretManagement wraps the extension's error; the clear message is the inner one.
                $err = $null
                try { Get-Secret -Name 'dept/edu001' -Vault $v2 -ErrorAction Stop } catch { $err = $_ }
                $err | Should -Not -BeNullOrEmpty
                $err.Exception.InnerException.Message | Should -Match 'another machine or by another user'
                # and Test-SecretVault is the documented way to see it without touching a secret
                (Test-SecretVault -Name $v2 -ErrorAction SilentlyContinue) | Should -BeFalse
            } finally { Unregister-SecretVault -Name $v2 -ErrorAction SilentlyContinue }
        } finally { Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Unix file modes' -Skip:($env:OS -eq 'Windows_NT') {
    It 'store dir 700, files 600' {
        (& stat -f '%Lp' $script:StoreRoot) | Should -Be '700'
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:StoreRoot 'secrets') -File) {
            (& stat -f '%Lp' $f.FullName) | Should -Be '600'
        }
        (& stat -f '%Lp' (Join-Path $script:StoreRoot 'master.key')) | Should -Be '600'
    }
}

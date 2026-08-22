# LocalVault.Core.ps1 - shared implementation for SecretManagement.LocalVault.
#
# Dot-sourced by BOTH the outer module (SecretManagement.LocalVault.psm1, which
# exposes Register-LocalVault / Get-LocalVaultInfo) and the extension module
# (SecretManagement.LocalVault.Extension, which SecretManagement loads on its own
# and which must therefore be self-contained). Keep everything here free of any
# product identity: this module is published on its own and vendored by several
# products, none of which should be named here.
#
# Design (DESIGN.md in this repository):
#   * One store per user, shared by every product that registers this module.
#   * File-based: index.json (names, types, metadata - never secret material) plus
#     one encrypted blob per secret, so a write never rewrites the whole store and
#     two products writing different secrets do not race.
#   * No OS credential UI anywhere: no Keychain, no Credential Manager, no
#     secret-tool. Windows = DPAPI CurrentUser (a crypto primitive, not CredMan;
#     works on Windows PowerShell 5.1). macOS/Linux = AES-256-GCM under a random
#     master key that is itself wrapped by a key derived from this machine + this
#     user, so a copied profile directory is unreadable elsewhere.
#   * No Reset concept. Nothing here can destroy a store it did not create.
#
# PowerShell 5.1 rules apply to every code path that can run on Windows: no
# ternary, no ??, no -AsHashtable, no $IsWindows (use $env:OS), AesGcm only behind
# the non-Windows branch (type literals resolve at run time, so the parse is fine).

Set-StrictMode -Version Latest

# Windows PowerShell 5.1 does not load System.Security.dll by default, and that is
# where ProtectedData (DPAPI) lives. PowerShell 7 has it already; the call is a
# no-op there. Measured on the 5.1 CI leg: without this every Set-Secret fails with
# "Unable to find type [System.Security.Cryptography.ProtectedData]".
if ($env:OS -eq 'Windows_NT') {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
}

$script:LocalVaultSchema       = 1
$script:LocalVaultDirName      = 'SecretManagement.LocalVault'
$script:LocalVaultIndexName    = 'index.json'
$script:LocalVaultMasterName   = 'master.key'
$script:LocalVaultBlobDirName  = 'secrets'
$script:LocalVaultKdfSalt      = 'SecretManagement.LocalVault|machine-key|v1'
$script:LocalVaultKdfIter      = 200000
$script:LocalVaultMasterKey    = $null     # per-process cache of the unwrapped master key (non-Windows)
$script:LocalVaultMasterKeyFor = $null     # store root the cache belongs to

# --- platform -----------------------------------------------------------------

function Test-LocalVaultIsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Get-LocalVaultDefaultStoreRoot {
    <#
    .SYNOPSIS
        Product-neutral per-user store location. Every product that registers this
        module lands on the same directory, which is what makes the store shared.
    #>
    if (Test-LocalVaultIsWindows) {
        return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $script:LocalVaultDirName)
    }
    # Not the automatic variable HOME (read-only): module scope happens to shadow
    # it, but dot-sourcing this file at script scope would throw on assignment.
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:HOME }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and (Test-Path variable:IsMacOS) -and $IsMacOS) {
        return (Join-Path $userHome "Library/Application Support/$($script:LocalVaultDirName)")
    }
    $xdg = $env:XDG_DATA_HOME
    if ([string]::IsNullOrWhiteSpace($xdg)) { $xdg = Join-Path $userHome '.local/share' }
    return (Join-Path $xdg $script:LocalVaultDirName)
}

function Resolve-LocalVaultStoreRoot {
    param([hashtable]$AdditionalParameters)
    $root = $null
    if ($AdditionalParameters -and $AdditionalParameters.ContainsKey('StoreRoot') -and $AdditionalParameters['StoreRoot']) {
        $root = [string]$AdditionalParameters['StoreRoot']
    }
    if (-not $root) { $root = Get-LocalVaultDefaultStoreRoot }
    return $root
}

function Get-LocalVaultMachineId {
    <#
    .SYNOPSIS
        A stable, non-secret identifier for THIS machine. Binding, not secrecy - see
        DESIGN.md. Read-only, no prompts, no entitlements.
    #>
    if (Test-LocalVaultIsWindows) {
        # Diagnostic only on Windows (DPAPI does the binding). MachineGuid is the
        # conventional stable id; fall back to the machine name.
        try {
            $guid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            if ($guid) { return [string]$guid }
        } catch { }
        return [Environment]::MachineName
    }
    if ((Test-Path variable:IsMacOS) -and $IsMacOS) {
        try {
            $line = & ioreg -rd1 -c IOPlatformExpertDevice 2>$null | Where-Object { $_ -match 'IOPlatformUUID' } | Select-Object -First 1
            if ($line -and $line -match '"IOPlatformUUID"\s*=\s*"([^"]+)"') { return $Matches[1] }
        } catch { }
        throw 'LocalVault: could not read IOPlatformUUID from ioreg; cannot derive the machine key.'
    }
    foreach ($p in @('/etc/machine-id', '/var/lib/dbus/machine-id')) {
        if (Test-Path -LiteralPath $p) {
            $id = (Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue)
            if ($id) { return $id.Trim() }
        }
    }
    throw 'LocalVault: no /etc/machine-id or /var/lib/dbus/machine-id; cannot derive the machine key.'
}

function Get-LocalVaultUserId {
    if (Test-LocalVaultIsWindows) {
        try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    }
    return [Environment]::UserName
}

function Get-LocalVaultScheme {
    if (Test-LocalVaultIsWindows) { return 'dpapi-v1' }
    return 'aesgcm-machine-v1'
}

function Get-LocalVaultSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-LocalVaultKeyId {
    <#
    .SYNOPSIS
        16 hex chars identifying the (platform, machine, user) a store was created
        under. Stored in plain text in index.json so a moved profile fails with a
        clear message instead of as a corrupt store. Non-secret by construction.
    #>
    param([string]$MachineId, [string]$UserId)
    if (-not $MachineId) { $MachineId = Get-LocalVaultMachineId }
    if (-not $UserId)    { $UserId    = Get-LocalVaultUserId }
    $input = [System.Text.Encoding]::UTF8.GetBytes("localvault-keyid-v1|$(Get-LocalVaultScheme)|$MachineId|$UserId")
    return (Get-LocalVaultSha256Hex -Bytes $input).Substring(0, 16)
}

# --- files --------------------------------------------------------------------

function Get-LocalVaultPaths {
    param([Parameter(Mandatory)][string]$StoreRoot)
    return @{
        Root   = $StoreRoot
        Index  = Join-Path $StoreRoot $script:LocalVaultIndexName
        Master = Join-Path $StoreRoot $script:LocalVaultMasterName
        Blobs  = Join-Path $StoreRoot $script:LocalVaultBlobDirName
    }
}

function Set-LocalVaultUnixMode {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Mode)
    if (Test-LocalVaultIsWindows) { return }
    try { & chmod $Mode $Path 2>$null } catch { }
}

function Initialize-LocalVaultStoreDirs {
    param([Parameter(Mandatory)][string]$StoreRoot)
    $paths = Get-LocalVaultPaths -StoreRoot $StoreRoot
    foreach ($dir in @($paths.Root, $paths.Blobs)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-LocalVaultUnixMode -Path $dir -Mode '700'
        }
    }
    return $paths
}

function Write-LocalVaultFileAtomic {
    <#
    .SYNOPSIS
        Write to a sibling temp file, then Replace (atomic when the target exists)
        or Move (when it does not). A reader never sees a half-written file.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllBytes($tmp, $Bytes)
    Set-LocalVaultUnixMode -Path $tmp -Mode '600'
    if (Test-Path -LiteralPath $Path) {
        # [NullString]::Value, not $null: PowerShell passes $null to a .NET string
        # parameter as "" and File.Replace rejects an empty backup name.
        [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Invoke-LocalVaultLocked {
    <#
    .SYNOPSIS
        Cross-process mutex around index mutations. Two products writing at once
        serialise here; a named mutex works on Windows and on Unix (.NET Core).
    #>
    param([Parameter(Mandatory)][string]$StoreRoot, [Parameter(Mandatory)][scriptblock]$Body)
    # PSScriptAnalyzer reports the callers' parameters ($Name, $Metadata, ...) as
    # unused because they are only referenced inside the -Body scriptblock, which
    # the analyzer cannot see into. False positives; the metadata tests prove the
    # values arrive. Do not "fix" by removing them.
    # Locals here are deliberately un-generic: the body runs in a child of THIS scope
    # and PowerShell resolves variables dynamically and case-insensitively, so a local
    # called $name would silently shadow the caller's $Name inside the body. (Do not
    # 'fix' this with GetNewClosure(): a closure runs in a fresh dynamic module and
    # loses sight of this module's private functions.)
    $lvMutexName = 'SecretManagement.LocalVault-' + (Get-LocalVaultSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($StoreRoot))).Substring(0, 24)
    $lvMutex = New-Object System.Threading.Mutex($false, $lvMutexName)
    $lvHeld = $false
    try {
        try { $lvHeld = $lvMutex.WaitOne(10000) }
        catch [System.Threading.AbandonedMutexException] { $lvHeld = $true }
        if (-not $lvHeld) { throw "LocalVault: timed out waiting for the store lock ($StoreRoot)." }
        return (& $Body)
    } finally {
        if ($lvHeld) { try { $lvMutex.ReleaseMutex() } catch { } }
        $lvMutex.Dispose()
    }
}

# --- index --------------------------------------------------------------------

function ConvertTo-LocalVaultHashtable {
    # ConvertFrom-Json gives PSCustomObject; callers want hashtables, and 5.1 has no -AsHashtable.
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Object.Keys) { $h[[string]$k] = ConvertTo-LocalVaultHashtable $Object[$k] }
        return $h
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-LocalVaultHashtable $p.Value }
        return $h
    }
    if (($Object -is [System.Collections.IEnumerable]) -and -not ($Object -is [string])) {
        return @(foreach ($i in $Object) { ConvertTo-LocalVaultHashtable $i })
    }
    return $Object
}

function New-LocalVaultIndex {
    return @{
        schema    = $script:LocalVaultSchema
        scheme    = Get-LocalVaultScheme
        keyId     = Get-LocalVaultKeyId
        createdAt = [DateTime]::UtcNow.ToString('o')
        secrets   = @{}
    }
}

function Read-LocalVaultIndex {
    param([Parameter(Mandatory)][string]$StoreRoot)
    $paths = Get-LocalVaultPaths -StoreRoot $StoreRoot
    if (-not (Test-Path -LiteralPath $paths.Index)) { return $null }
    $raw = [System.IO.File]::ReadAllText($paths.Index, [System.Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
    $index = ConvertTo-LocalVaultHashtable $obj
    if (-not $index.ContainsKey('secrets') -or $null -eq $index['secrets']) { $index['secrets'] = @{} }
    return $index
}

function Write-LocalVaultIndex {
    param([Parameter(Mandatory)][string]$StoreRoot, [Parameter(Mandatory)][hashtable]$Index)
    $paths = Initialize-LocalVaultStoreDirs -StoreRoot $StoreRoot
    $json = $Index | ConvertTo-Json -Depth 12
    Write-LocalVaultFileAtomic -Path $paths.Index -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Assert-LocalVaultIndexUsable {
    <#
    .SYNOPSIS
        The one failure that must be CLEAR: a store created on another machine or by
        another user. Detected from the plain-text keyId, without attempting a decrypt.
    #>
    param([Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)][string]$StoreRoot)
    $expected = Get-LocalVaultKeyId
    $actual = [string]$Index['keyId']
    if ($actual -ne $expected) {
        throw ("LocalVault: the store at '{0}' was created on another machine or by another user " +
               "(store keyId {1}, this machine {2}). Its secrets cannot be read here. Sign in again to " +
               "re-create them, or remove the store directory to start fresh.") -f $StoreRoot, $actual, $expected
    }
    $scheme = [string]$Index['scheme']
    if ($scheme -ne (Get-LocalVaultScheme)) {
        throw "LocalVault: the store at '$StoreRoot' uses scheme '$scheme' but this platform uses '$(Get-LocalVaultScheme)'."
    }
}

function Open-LocalVaultIndex {
    # Returns the index, creating an empty one on first use. Never resets an existing one.
    param([Parameter(Mandatory)][string]$StoreRoot)
    $index = Read-LocalVaultIndex -StoreRoot $StoreRoot
    if ($null -eq $index) {
        $index = New-LocalVaultIndex
        Write-LocalVaultIndex -StoreRoot $StoreRoot -Index $index
        return $index
    }
    Assert-LocalVaultIndexUsable -Index $index -StoreRoot $StoreRoot
    return $index
}

# --- keys (non-Windows) -------------------------------------------------------

function Invoke-LocalVaultPbkdf2Sha256 {
    <#
    .SYNOPSIS
        PBKDF2-HMAC-SHA256. The static Rfc2898DeriveBytes.Pbkdf2 exists on .NET 6+
        only; Windows PowerShell 5.1 (.NET Framework) has the instance form with a
        HashAlgorithmName from 4.7.2. Same algorithm, same bytes, either way.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Ikm,
        [Parameter(Mandatory)][byte[]]$Salt,
        [Parameter(Mandatory)][int]$Iterations,
        [Parameter(Mandatory)][int]$Length
    )
    $sha256 = [System.Security.Cryptography.HashAlgorithmName]::SHA256
    $t = [System.Security.Cryptography.Rfc2898DeriveBytes]
    $static = $t.GetMethod('Pbkdf2', [type[]]@([byte[]], [byte[]], [int], [System.Security.Cryptography.HashAlgorithmName], [int]))
    if ($static) {
        return $t::Pbkdf2($Ikm, $Salt, $Iterations, $sha256, $Length)
    }
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Ikm, $Salt, $Iterations, $sha256)
    try { return $kdf.GetBytes($Length) } finally { $kdf.Dispose() }
}

function Get-LocalVaultDerivedKek {
    <#
    .SYNOPSIS
        PBKDF2-SHA256 over (machineId | userId). Deterministic for this machine + user,
        different everywhere else. Cost ~30 ms; called once per process.
    #>
    param([string]$MachineId, [string]$UserId)
    if (-not $MachineId) { $MachineId = Get-LocalVaultMachineId }
    if (-not $UserId)    { $UserId    = Get-LocalVaultUserId }
    $ikm  = [System.Text.Encoding]::UTF8.GetBytes("$MachineId|$UserId")
    $salt = [System.Text.Encoding]::UTF8.GetBytes($script:LocalVaultKdfSalt)
    return Invoke-LocalVaultPbkdf2Sha256 -Ikm $ikm -Salt $salt -Iterations $script:LocalVaultKdfIter -Length 32
}

function Protect-LocalVaultAesGcm {
    param([Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][byte[]]$Plain, [byte[]]$Aad)
    $nonce = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
    $cipher = New-Object byte[] $Plain.Length
    $tag = New-Object byte[] 16
    $aes = [System.Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Encrypt($nonce, $Plain, $cipher, $tag, $Aad) } finally { $aes.Dispose() }
    return @{ nonce = $nonce; tag = $tag; cipher = $cipher }
}

function Unprotect-LocalVaultAesGcm {
    param([Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][byte[]]$Nonce, [Parameter(Mandatory)][byte[]]$Tag, [Parameter(Mandatory)][byte[]]$Cipher, [byte[]]$Aad)
    $plain = New-Object byte[] $Cipher.Length
    $aes = [System.Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Decrypt($Nonce, $Cipher, $Tag, $plain, $Aad) } finally { $aes.Dispose() }
    return $plain
}

function Get-LocalVaultMasterKey {
    <#
    .SYNOPSIS
        The random 256-bit key that encrypts every blob on macOS/Linux. Stored wrapped
        (AES-GCM under the derived KEK) in master.key. Indirection is deliberate: a
        future passphrase mix-in or key rotation re-wraps 32 bytes instead of
        re-encrypting every secret.
    #>
    param([Parameter(Mandatory)][string]$StoreRoot, [byte[]]$Kek)
    if ($script:LocalVaultMasterKey -and $script:LocalVaultMasterKeyFor -eq $StoreRoot -and -not $Kek) {
        return $script:LocalVaultMasterKey
    }
    if (-not $Kek) { $Kek = Get-LocalVaultDerivedKek }
    $paths = Initialize-LocalVaultStoreDirs -StoreRoot $StoreRoot
    $aad = [System.Text.Encoding]::UTF8.GetBytes('master-key-v1')
    if (Test-Path -LiteralPath $paths.Master) {
        $bytes = [System.IO.File]::ReadAllBytes($paths.Master)
        # LVMK(4) ver(1) nonce(12) tag(16) cipher(32)
        if ($bytes.Length -ne 65 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'LVMK' -or $bytes[4] -ne 1) {
            throw "LocalVault: master.key at '$StoreRoot' is not in a recognised format."
        }
        try {
            $master = Unprotect-LocalVaultAesGcm -Key $Kek -Nonce $bytes[5..16] -Tag $bytes[17..32] -Cipher $bytes[33..64] -Aad $aad
        } catch {
            throw "LocalVault: master.key at '$StoreRoot' cannot be unwrapped on this machine/user (store moved, or user changed)."
        }
    } else {
        $master = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($master)
        $w = Protect-LocalVaultAesGcm -Key $Kek -Plain $master -Aad $aad
        $out = New-Object System.Collections.Generic.List[byte]
        $out.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('LVMK')); $out.Add([byte]1)
        $out.AddRange([byte[]]$w.nonce); $out.AddRange([byte[]]$w.tag); $out.AddRange([byte[]]$w.cipher)
        Write-LocalVaultFileAtomic -Path $paths.Master -Bytes $out.ToArray()
    }
    $script:LocalVaultMasterKey = $master
    $script:LocalVaultMasterKeyFor = $StoreRoot
    return $master
}

# --- secret (de)serialisation ------------------------------------------------

function ConvertFrom-LocalVaultSecureString {
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertTo-LocalVaultEnvelope {
    # -> @{ type = <SecretType name>; value = <JSON-able> }
    param([Parameter(Mandatory)]$Secret)
    if ($Secret -is [byte[]]) {
        return @{ type = 'ByteArray'; value = [Convert]::ToBase64String($Secret) }
    }
    if ($Secret -is [string]) {
        return @{ type = 'String'; value = $Secret }
    }
    if ($Secret -is [securestring]) {
        return @{ type = 'SecureString'; value = (ConvertFrom-LocalVaultSecureString -Secure $Secret) }
    }
    if ($Secret -is [pscredential]) {
        return @{ type = 'PSCredential'; value = @{ userName = $Secret.UserName; password = (ConvertFrom-LocalVaultSecureString -Secure $Secret.Password) } }
    }
    if ($Secret -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Secret.Keys) {
            $v = $Secret[$k]
            if ($v -is [securestring]) { $v = ConvertFrom-LocalVaultSecureString -Secure $v }
            elseif ($v -is [pscredential]) { $v = @{ '__pscredential' = $true; userName = $v.UserName; password = (ConvertFrom-LocalVaultSecureString -Secure $v.Password) } }
            elseif ($v -is [byte[]]) { $v = @{ '__bytes' = [Convert]::ToBase64String($v) } }
            $h[[string]$k] = $v
        }
        return @{ type = 'Hashtable'; value = $h }
    }
    throw "LocalVault: unsupported secret type '$($Secret.GetType().FullName)'. Supported: byte[], string, SecureString, PSCredential, hashtable."
}

function ConvertFrom-LocalVaultEnvelope {
    param([Parameter(Mandatory)][hashtable]$Envelope)
    $type = [string]$Envelope['type']
    $value = $Envelope['value']
    switch ($type) {
        'ByteArray'    { return ,[Convert]::FromBase64String([string]$value) }
        'String'       { return [string]$value }
        'SecureString' { return (ConvertTo-SecureString -String ([string]$value) -AsPlainText -Force) }
        'PSCredential' {
            $v = ConvertTo-LocalVaultHashtable $value
            return New-Object System.Management.Automation.PSCredential(
                [string]$v['userName'], (ConvertTo-SecureString -String ([string]$v['password']) -AsPlainText -Force))
        }
        'Hashtable' {
            $h = ConvertTo-LocalVaultHashtable $value
            foreach ($k in @($h.Keys)) {
                $v = $h[$k]
                if ($v -is [hashtable] -and $v.ContainsKey('__pscredential')) {
                    $h[$k] = New-Object System.Management.Automation.PSCredential([string]$v['userName'], (ConvertTo-SecureString -String ([string]$v['password']) -AsPlainText -Force))
                } elseif ($v -is [hashtable] -and $v.ContainsKey('__bytes')) {
                    $h[$k] = [Convert]::FromBase64String([string]$v['__bytes'])
                }
            }
            return $h
        }
        default { throw "LocalVault: unknown stored type '$type'." }
    }
}

function Get-LocalVaultSecretTypeEnum {
    param([Parameter(Mandatory)][string]$TypeName)
    return [Microsoft.PowerShell.SecretManagement.SecretType]$TypeName
}

# --- blobs --------------------------------------------------------------------

function Get-LocalVaultBlobFileName {
    param([Parameter(Mandatory)][string]$Name)
    # Names contain '/', so the file is the hash of the name, not the name.
    return (Get-LocalVaultSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Name))).Substring(0, 40) + '.bin'
}

function Protect-LocalVaultBlob {
    param([Parameter(Mandatory)][string]$StoreRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][byte[]]$Plain)
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $out = New-Object System.Collections.Generic.List[byte]
    if (Test-LocalVaultIsWindows) {
        # LVSD(4) ver(1) dpapi(...)  - entropy = name, so a blob cannot be re-labelled.
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect($Plain, $nameBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $out.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('LVSD')); $out.Add([byte]1); $out.AddRange([byte[]]$cipher)
        return $out.ToArray()
    }
    # LVSB(4) ver(1) nonce(12) tag(16) cipher(...)  - AAD = name, same property.
    $key = Get-LocalVaultMasterKey -StoreRoot $StoreRoot
    $w = Protect-LocalVaultAesGcm -Key $key -Plain $Plain -Aad $nameBytes
    $out.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('LVSB')); $out.Add([byte]1)
    $out.AddRange([byte[]]$w.nonce); $out.AddRange([byte[]]$w.tag); $out.AddRange([byte[]]$w.cipher)
    return $out.ToArray()
}

function Unprotect-LocalVaultBlob {
    param([Parameter(Mandatory)][string]$StoreRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][byte[]]$Bytes)
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    if ($Bytes.Length -lt 5) { throw "LocalVault: blob for '$Name' is truncated." }
    $magic = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4)
    if ($Bytes[4] -ne 1) { throw "LocalVault: blob for '$Name' has unknown version $($Bytes[4])." }
    switch ($magic) {
        'LVSD' {
            if (-not (Test-LocalVaultIsWindows)) { throw "LocalVault: '$Name' is a DPAPI blob and cannot be read off Windows." }
            return [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes[5..($Bytes.Length - 1)], $nameBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        'LVSB' {
            if ($Bytes.Length -lt 33) { throw "LocalVault: blob for '$Name' is truncated." }
            $key = Get-LocalVaultMasterKey -StoreRoot $StoreRoot
            $cipher = if ($Bytes.Length -gt 33) { $Bytes[33..($Bytes.Length - 1)] } else { New-Object byte[] 0 }
            return Unprotect-LocalVaultAesGcm -Key $key -Nonce $Bytes[5..16] -Tag $Bytes[17..32] -Cipher ([byte[]]$cipher) -Aad $nameBytes
        }
        default { throw "LocalVault: blob for '$Name' has unknown magic '$magic'." }
    }
}

# --- operations (what the extension functions call) ---------------------------

function Get-LocalVaultSecretValue {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    $index = Read-LocalVaultIndex -StoreRoot $root
    if ($null -eq $index) { return $null }
    Assert-LocalVaultIndexUsable -Index $index -StoreRoot $root
    if (-not $index['secrets'].ContainsKey($Name)) { return $null }
    $entry = $index['secrets'][$Name]
    $paths = Get-LocalVaultPaths -StoreRoot $root
    $file = Join-Path $paths.Blobs ([string]$entry['file'])
    if (-not (Test-Path -LiteralPath $file)) { throw "LocalVault: index lists '$Name' but its blob is missing ($file)." }
    $plain = Unprotect-LocalVaultBlob -StoreRoot $root -Name $Name -Bytes ([System.IO.File]::ReadAllBytes($file))
    $envelope = ConvertTo-LocalVaultHashtable (([System.Text.Encoding]::UTF8.GetString($plain)) | ConvertFrom-Json)
    return (ConvertFrom-LocalVaultEnvelope -Envelope $envelope)
}

function Set-LocalVaultSecretValue {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Secret, [hashtable]$Metadata, [hashtable]$AdditionalParameters)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'LocalVault: secret name is required.' }
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    $envelope = ConvertTo-LocalVaultEnvelope -Secret $Secret
    $plain = [System.Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 12 -Compress))
    $blob = Protect-LocalVaultBlob -StoreRoot $root -Name $Name -Plain $plain
    Invoke-LocalVaultLocked -StoreRoot $root -Body {
        $index = Open-LocalVaultIndex -StoreRoot $root
        $paths = Get-LocalVaultPaths -StoreRoot $root
        $fileName = Get-LocalVaultBlobFileName -Name $Name
        Write-LocalVaultFileAtomic -Path (Join-Path $paths.Blobs $fileName) -Bytes $blob
        $now = [DateTime]::UtcNow.ToString('o')
        $existing = $null
        if ($index['secrets'].ContainsKey($Name)) { $existing = $index['secrets'][$Name] }
        $entry = @{
            file      = $fileName
            type      = $envelope['type']
            createdAt = if ($existing -and $existing['createdAt']) { $existing['createdAt'] } else { $now }
            updatedAt = $now
            metadata  = if ($null -ne $Metadata) { $Metadata } elseif ($existing -and $existing.ContainsKey('metadata')) { $existing['metadata'] } else { @{} }
        }
        $index['secrets'][$Name] = $entry
        Write-LocalVaultIndex -StoreRoot $root -Index $index
    } | Out-Null
    return $true
}

function Set-LocalVaultSecretMetadata {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Metadata, [hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    Invoke-LocalVaultLocked -StoreRoot $root -Body {
        $index = Open-LocalVaultIndex -StoreRoot $root
        if (-not $index['secrets'].ContainsKey($Name)) { throw "LocalVault: no secret named '$Name'." }
        $index['secrets'][$Name]['metadata'] = if ($null -ne $Metadata) { $Metadata } else { @{} }
        $index['secrets'][$Name]['updatedAt'] = [DateTime]::UtcNow.ToString('o')
        Write-LocalVaultIndex -StoreRoot $root -Index $index
    } | Out-Null
}

function Remove-LocalVaultSecretValue {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    return (Invoke-LocalVaultLocked -StoreRoot $root -Body {
        $index = Read-LocalVaultIndex -StoreRoot $root
        if ($null -eq $index -or -not $index['secrets'].ContainsKey($Name)) { return $false }
        Assert-LocalVaultIndexUsable -Index $index -StoreRoot $root
        $paths = Get-LocalVaultPaths -StoreRoot $root
        $file = Join-Path $paths.Blobs ([string]$index['secrets'][$Name]['file'])
        $index['secrets'].Remove($Name)
        Write-LocalVaultIndex -StoreRoot $root -Index $index
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        return $true
    })
}

function Get-LocalVaultSecretInfoList {
    param([string]$Filter = '*', [Parameter(Mandatory)][string]$VaultName, [hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    $index = Read-LocalVaultIndex -StoreRoot $root
    if ($null -eq $index) { return @() }
    Assert-LocalVaultIndexUsable -Index $index -StoreRoot $root
    if ([string]::IsNullOrEmpty($Filter)) { $Filter = '*' }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($name in ($index['secrets'].Keys | Sort-Object)) {
        if ($name -notlike $Filter) { continue }
        $entry = $index['secrets'][$name]
        $meta = @{}
        if ($entry.ContainsKey('metadata') -and $entry['metadata'] -is [hashtable]) { $meta = $entry['metadata'] }
        $list.Add([Microsoft.PowerShell.SecretManagement.SecretInformation]::new(
            [string]$name, (Get-LocalVaultSecretTypeEnum -TypeName ([string]$entry['type'])), $VaultName, [hashtable]$meta))
    }
    return $list.ToArray()
}

function Test-LocalVaultStore {
    param([hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    $index = Read-LocalVaultIndex -StoreRoot $root
    if ($null -ne $index) { Assert-LocalVaultIndexUsable -Index $index -StoreRoot $root }
    if (-not (Test-LocalVaultIsWindows)) { $null = Get-LocalVaultMasterKey -StoreRoot $root }
    return $true
}

function ConvertTo-LocalVaultIsoString {
    # ConvertFrom-Json parses ISO-8601 strings into DateTime; hand them back as ISO so
    # an IPC payload never carries a locale-formatted date.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function Get-LocalVaultStoreInfo {
    param([hashtable]$AdditionalParameters)
    $root = Resolve-LocalVaultStoreRoot -AdditionalParameters $AdditionalParameters
    $index = Read-LocalVaultIndex -StoreRoot $root
    $thisKeyId = Get-LocalVaultKeyId
    $info = [ordered]@{
        storeRoot    = $root
        exists       = ($null -ne $index)
        scheme       = Get-LocalVaultScheme
        thisKeyId    = $thisKeyId
        storeKeyId   = if ($index) { [string]$index['keyId'] } else { $null }
        keyMatches   = if ($index) { ([string]$index['keyId'] -eq $thisKeyId) } else { $true }
        secretCount  = if ($index) { @($index['secrets'].Keys).Count } else { 0 }
        createdAt    = if ($index) { ConvertTo-LocalVaultIsoString $index['createdAt'] } else { $null }
    }
    return $info
}

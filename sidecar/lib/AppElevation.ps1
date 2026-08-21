# AppElevation.ps1 - generic macOS sudo-elevation + credential-cache helpers.
# Extracted from USM AppCurricRoutes.ps1 (lines 132-572) during the windeploykit port.

function ConvertTo-AppAppleScriptQuotedString {
    param([Parameter(Mandatory)][string]$Value)
    $v = [string]$Value
    $v = $v -replace '\\', '\\\\'
    $v = $v -replace '"', '\"'
    return "`"$v`""
}

function ConvertTo-AppUnixShellSingleQuotedString {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + ([string]$Value -replace "'", "'\''") + "'"
}

function Get-AppSha256Hex {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

$script:AppMacOsAdminCredentialCache = @{
    SecurePassword = $null
    PasswordHash   = $null
    Username       = $null
    CachedAt       = $null
}

function Get-AppMacOsAdminCredentialCacheStatus {
    if (-not ($IsMacOS -or $IsDarwin)) {
        return @{
            cached       = $false
            username     = $null
            passwordHash = $null
            cachedAt     = $null
        }
    }
    @{
        cached       = [bool]$script:AppMacOsAdminCredentialCache.SecurePassword
        username     = $script:AppMacOsAdminCredentialCache.Username
        passwordHash = $script:AppMacOsAdminCredentialCache.PasswordHash
        cachedAt     = $script:AppMacOsAdminCredentialCache.CachedAt
    }
}

function Clear-AppMacOsAdminCredentialCache {
    if ($script:AppMacOsAdminCredentialPrefetchState) {
        Stop-AppMacOsAdminCredentialPrefetch -PrefetchState $script:AppMacOsAdminCredentialPrefetchState | Out-Null
    }
    $script:AppMacOsAdminCredentialCache.SecurePassword = $null
    $script:AppMacOsAdminCredentialCache.PasswordHash = $null
    $script:AppMacOsAdminCredentialCache.Username = $null
    $script:AppMacOsAdminCredentialCache.CachedAt = $null
}

function Set-AppMacOsAdminCredentialCache {
    param(
        [Parameter(Mandatory)][System.Security.SecureString]$SecurePassword,
        [string]$UserName
    )
    $plain = ConvertTo-AppPlainTextFromSecureString -SecureString $SecurePassword
    $hash = Get-AppSha256Hex -Text $plain
    $script:AppMacOsAdminCredentialCache.SecurePassword = $SecurePassword
    $script:AppMacOsAdminCredentialCache.PasswordHash = $hash
    $script:AppMacOsAdminCredentialCache.Username = if ($UserName) {
        [string]$UserName
    } else {
        Get-AppMacOsAdminUserName
    }
    $script:AppMacOsAdminCredentialCache.CachedAt = (Get-Date).ToString('o')
}

function Get-AppMacOsAdminUserName {
    if (-not ($IsMacOS -or $IsDarwin)) { return [string]$env:USER }
    try {
        $short = (& id -un 2>$null | Out-String).Trim()
        if ($short) { return $short }
    } catch { }
    return [string]$env:USER
}

function ConvertTo-AppPlainTextFromSecureString {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)
    # SecureStringToBSTR returns only the first character on macOS PowerShell - use Unicode alloc.
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    }
}

function Request-AppMacOsAdminCredential {
    <#
        macOS does not hand back the password from its standard admin/Touch ID sheet, so
        we collect it once via a small secure-entry prompt and cache the SecureString for
        the session. Privileged commands are then executed with sudo (not AppleScript).
    #>
    param([string]$Message)
    Invoke-AppMacOsAdminCredentialPrompt -Message $Message
}

function Get-AppMacOsDialogHelperPath {
    <#
    .SYNOPSIS
        Locate the bundled windeploykit-dialog native prompt helper (tools/windeploykit-dialog).
        Preferred over osascript: security tooling / MDM can deny osascript, and
        then `display dialog` prompts silently never appear. Returns $null when
        the helper isn't present (dev checkout without a build) - callers fall
        back to osascript.
    #>
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    $root = if ((Test-Path variable:script:AppSidecarProjectRoot) -and $script:AppSidecarProjectRoot) { $script:AppSidecarProjectRoot }
        elseif (Test-Path variable:script:ProjectRoot) { $script:ProjectRoot }
        else { $null }
    if (-not $root) { return $null }
    $isArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
    $suffix = if ($isArm) { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
    foreach ($rel in @(
        'binaries/windeploykit-dialog-universal'
        "binaries/windeploykit-dialog-$suffix"
        'vendor/binaries/dialog-macos/windeploykit-dialog-universal'
        "vendor/binaries/dialog-macos/windeploykit-dialog-$suffix"
    )) {
        $path = Join-Path $root $rel
        if (Test-Path -LiteralPath $path) {
            $null = & chmod '+x' $path 2>$null
            $null = & xattr -d com.apple.quarantine $path 2>$null
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Invoke-AppMacOsSecurePasswordDialog {
    <#
    .SYNOPSIS
        Show a secure-entry password prompt and return the plain-text entry.
        windeploykit-dialog (bundled AppKit helper, argv-only, no AppleScript) first;
        osascript `display dialog ... with hidden answer` as fallback.
        Throws on cancel or empty entry.
    #>
    param([Parameter(Mandatory)][string]$Message)

    $helper = Get-AppMacOsDialogHelperPath
    if ($helper) {
        $plain = (& $helper 'password' '--message' $Message 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            $plain = ($plain -replace '\u200b', '').Trim()
            if ([string]::IsNullOrWhiteSpace($plain)) {
                throw 'Administrator password was not entered.'
            }
            return $plain
        }
        if ($code -eq 2) {
            throw 'Administrator permission was not granted (cancelled).'
        }
        Write-SidecarLog "macOS: windeploykit-dialog helper failed (exit $code) - falling back to osascript. $($plain.Trim())"
    }

    if (-not (Get-Command osascript -ErrorAction SilentlyContinue)) {
        throw 'Neither the bundled dialog helper nor osascript is available - cannot request administrator password.'
    }
    $quotedMsg = ConvertTo-AppAppleScriptQuotedString -Value $Message
    $osa = @"
try
    set dlg to display dialog $quotedMsg default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution
    return text returned of dlg
on error errMsg number errNum
    if errNum is -128 then error "User canceled" number -128
    error errMsg number errNum
end try
"@
    try {
        $plain = (& osascript -e $osa 2>&1 | Out-String).Trim()
    } catch {
        $errText = $_.Exception.Message
        if ($errText -match 'User canceled|-128') {
            throw 'Administrator permission was not granted (cancelled).'
        }
        throw
    }
    if ($LASTEXITCODE -ne 0 -and $plain -match 'User canceled|-128') {
        throw 'Administrator permission was not granted (cancelled).'
    }
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw 'Administrator password was not entered.'
    }
    return (($plain -replace '\u200b', '').Trim())
}

function Invoke-AppMacOsAdminCredentialPrompt {
    param([string]$Message)
    $msg = if ($Message) {
        [string]$Message
    } else {
        @(
            'WinDeployKit needs your macOS administrator password for this session'
            '(TFTP port 69, network routes). It is kept in memory only - not saved to disk.'
        ) -join ' '
    }
    $plain = Invoke-AppMacOsSecurePasswordDialog -Message $msg
    return (ConvertTo-SecureString -String $plain -AsPlainText -Force)
}

$script:AppMacOsAdminCredentialPrefetchState = $null

function Start-AppMacOsAdminCredentialPrefetch {
    <#
        Open the admin password dialog on a background STA thread so callers can do slow
        work (PXE menu regen, HTTP start) while the user types. Call Complete-* before
        the first elevated shell command.
    #>
    param(
        [ValidateSet('pxe', 'general')]
        [string]$Purpose = 'general'
    )
    if (-not ($IsMacOS -or $IsDarwin)) { return $null }
    if ((Get-AppMacOsAdminCredentialCacheStatus).cached) { return $null }
    if (Get-Command Resolve-AppMacOsAdminCredentialFromVaultOrPrompt -ErrorAction SilentlyContinue) {
        if (Resolve-AppMacOsAdminCredentialFromVaultOrPrompt) {
            Write-SidecarLog 'macOS: using saved local administrator credential (no dialog)'
            return $null
        }
    }
    if ($script:AppMacOsAdminCredentialPrefetchState) {
        return $script:AppMacOsAdminCredentialPrefetchState
    }

    $msg = if ($Purpose -eq 'pxe') {
        @(
            'WinDeployKit needs your macOS administrator password for Netboot (TFTP port 69).'
            'It is kept in memory only - not saved to disk.'
            'Enter it now - boot menus and HTTP continue starting while this dialog is open.'
        ) -join ' '
    } else {
        @(
            'WinDeployKit needs your macOS administrator password for this session'
            '(TFTP port 69, network routes). It is kept in memory only - not saved to disk.'
        ) -join ' '
    }
    $quotedMsg = ConvertTo-AppAppleScriptQuotedString -Value $msg
    $helperPath = Get-AppMacOsDialogHelperPath

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Fresh runspace - module functions aren't available here, so the
    # helper-first / osascript-fallback logic is duplicated inline.
    $null = $ps.AddScript({
        param([string]$QuotedDialogMessage, [string]$PlainMessage, [string]$HelperPath)
        if ($HelperPath -and (Test-Path -LiteralPath $HelperPath)) {
            $plain = (& $HelperPath 'password' '--message' $PlainMessage 2>&1 | Out-String)
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $plain = ($plain -replace '\u200b', '').Trim()
                if ([string]::IsNullOrWhiteSpace($plain)) {
                    throw 'Administrator password was not entered.'
                }
                return $plain
            }
            if ($code -eq 2) {
                throw 'Administrator permission was not granted (cancelled).'
            }
            # Helper broke unexpectedly - fall through to osascript.
        }
        if (-not (Get-Command osascript -ErrorAction SilentlyContinue)) {
            throw 'Neither the bundled dialog helper nor osascript is available - cannot request administrator password.'
        }
        $osa = @"
try
    set dlg to display dialog $QuotedDialogMessage default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution
    return text returned of dlg
on error errMsg number errNum
    if errNum is -128 then error "User canceled" number -128
    error errMsg number errNum
end try
"@
        try {
            $plain = (& osascript -e $osa 2>&1 | Out-String).Trim()
        } catch {
            $err = $_.Exception.Message
            if ($err -match 'User canceled|-128') {
                throw 'Administrator permission was not granted (cancelled).'
            }
            throw
        }
        if ($LASTEXITCODE -ne 0 -and $plain -match 'User canceled|-128') {
            throw 'Administrator permission was not granted (cancelled).'
        }
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw 'Administrator password was not entered.'
        }
        return ($plain -replace '\u200b', '').Trim()
    }).AddArgument($quotedMsg).AddArgument($msg).AddArgument([string]$helperPath)

    $handle = $ps.BeginInvoke()
    $script:AppMacOsAdminCredentialPrefetchState = @{
        PS      = $ps
        Handle  = $handle
        Runspace = $rs
    }
    Write-SidecarLog 'macOS: administrator password dialog opened (prefetch - Netboot / TFTP)'
    $script:AppMacOsAdminCredentialPrefetchState
}

function Complete-AppMacOsAdminCredentialPrefetch {
    param($PrefetchState)
    if (-not $PrefetchState) { return }
    if ((Get-AppMacOsAdminCredentialCacheStatus).cached) {
        Stop-AppMacOsAdminCredentialPrefetch -PrefetchState $PrefetchState | Out-Null
        return
    }
    try {
        $plain = [string]$PrefetchState.PS.EndInvoke($PrefetchState.Handle)
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw 'Administrator password was not entered.'
        }
        $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
        Set-AppMacOsAdminCredentialCache -SecurePassword $secure
        Write-SidecarLog 'macOS: administrator password cached for this session'
    } finally {
        Stop-AppMacOsAdminCredentialPrefetch -PrefetchState $PrefetchState | Out-Null
    }
}

function Stop-AppMacOsAdminCredentialPrefetch {
    param($PrefetchState)
    if (-not $PrefetchState) { return }
    try {
        if ($PrefetchState.PS -and $PrefetchState.Handle -and -not $PrefetchState.Handle.IsCompleted) {
            try { $PrefetchState.PS.Stop() } catch { }
        }
    } catch { }
    try { if ($PrefetchState.PS) { $PrefetchState.PS.Dispose() } } catch { }
    try { if ($PrefetchState.Runspace) { $PrefetchState.Runspace.Close() } } catch { }
    if ($script:AppMacOsAdminCredentialPrefetchState -eq $PrefetchState) {
        $script:AppMacOsAdminCredentialPrefetchState = $null
    }
}

function Invoke-AppMacOsAdminShellCommand {
    <#
    .SYNOPSIS
        Run a shell command as genuine root via `sudo -S`, feeding the admin password on
        stdin. The password is resolved without a dialog where possible (session cache ->
        in-flight prefetch -> local-admin vault) and only falls back to an osascript
        password prompt when nothing is cached. We deliberately use sudo rather than
        osascript's `do shell script ... with administrator privileges`: the latter runs
        as root but in a restricted security context where Directory Services tools
        (dscl / sysadminctl / pwpolicy) fail with eDSPermissionError (-14120). A real
        root shell from sudo behaves like a manual `sudo bash`. AppleScript is now used
        only to *collect* the password, not to execute privileged commands.
    #>
    param(
        [Parameter(Mandatory)][string]$ShellCommand,
        [string]$PromptMessage,
        [switch]$AllowFailure
    )
    if (-not ($IsMacOS -or $IsDarwin)) {
        throw 'Invoke-AppMacOsAdminShellCommand is macOS only.'
    }

    $attempt = 0
    while ($true) {
        $attempt++
        # Resolve the admin password: session cache -> in-flight prefetch -> local-admin
        # vault -> osascript prompt (last resort, used sparingly).
        $secure = $script:AppMacOsAdminCredentialCache.SecurePassword
        if (-not $secure) {
            if ($script:AppMacOsAdminCredentialPrefetchState) {
                Complete-AppMacOsAdminCredentialPrefetch -PrefetchState $script:AppMacOsAdminCredentialPrefetchState
                $secure = $script:AppMacOsAdminCredentialCache.SecurePassword
            }
            if (-not $secure -and (Get-Command Get-AppLocalMachineCredentialSecure -ErrorAction SilentlyContinue)) {
                $fromVault = Get-AppLocalMachineCredentialSecure
                if ($fromVault) {
                    $secure = $fromVault.SecurePassword
                    if (-not $script:AppMacOsAdminCredentialCache.Username) {
                        $script:AppMacOsAdminCredentialCache.Username = $fromVault.LoginName
                    }
                }
            }
            if (-not $secure) {
                $secure = Request-AppMacOsAdminCredential -Message $PromptMessage
            }
        }
        if (-not $secure) { throw 'macOS administrator password unavailable.' }

        $plain = [System.Net.NetworkCredential]::new('', $secure).Password
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = '/usr/bin/sudo'
            # -S: read password from stdin. -k: ignore any cached sudo timestamp so a stale
            # one can't swallow our piped password (which would then land in bash's stdin).
            # -p '': no prompt text on stderr.
            foreach ($a in @('-S', '-k', '-p', '', '/bin/bash', '-c', $ShellCommand)) {
                $psi.ArgumentList.Add($a)
            }
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.WriteLine($plain)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $exit = $proc.ExitCode
        } finally {
            $plain = $null
        }

        # sudo writes this to stderr when the password is wrong - drop the bad cache and
        # retry once (which re-prompts / re-reads the vault).
        if ($stderr -match 'Sorry, try again|incorrect password attempt') {
            Clear-AppMacOsAdminCredentialCache
            if ($attempt -lt 2) { continue }
            if ($AllowFailure) { return ($stdout + "`n" + $stderr).Trim() }
            throw 'macOS administrator password was incorrect.'
        }
        if ($exit -ne 0) {
            $combined = ($stdout + "`n" + $stderr).Trim()
            if ($AllowFailure) { return $combined }
            throw "macOS admin shell failed (exit $exit): $combined"
        }
        if (-not $script:AppMacOsAdminCredentialCache.SecurePassword) {
            $userName = if ($script:AppMacOsAdminCredentialCache.Username) {
                [string]$script:AppMacOsAdminCredentialCache.Username
            } else { Get-AppMacOsAdminUserName }
            Set-AppMacOsAdminCredentialCache -SecurePassword $secure -UserName $userName
        }
        return ($stdout + "`n" + $stderr)
    }
}


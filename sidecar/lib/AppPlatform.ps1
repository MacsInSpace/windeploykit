# Platform probes for sidecar plugins.
# PS 7+ defines $IsWindows / $IsMacOS / $IsLinux. PS Core 6 used $IsDarwin (removed in PS 7).
# Bare `$IsDarwin` in `if ($IsMacOS -or $IsDarwin)` throws on Windows when the variable was never set.

if ($null -eq (Get-Variable -Name IsDarwin -Scope Global -ErrorAction SilentlyContinue)) {
    Set-Variable -Name IsDarwin -Scope Global -Value ([bool]$IsMacOS)
}

function Test-AppIsMacOSPlatform {
    return [bool]($IsMacOS -or $IsDarwin)
}

function Format-AppProcessArgumentList {
    <#
    .SYNOPSIS
        Join process arguments into ONE pre-quoted string for Start-Process -ArgumentList.
        Start-Process joins an argument ARRAY with spaces WITHOUT quoting, so any spaced
        value — e.g. paths under the app data root ".../Application Support/Unofficial
        School Manager/..." (macOS) or "...\AppData\Roaming\WinDeployKit\..."
        (Windows) — splits into multiple arguments (0.4.0 field bug: RDP/SSH/aria2/PXE).
        Double-quoting spaced items survives both CommandLineToArgvW (Windows) and .NET's
        Unix argument parser. Use for EVERY Start-Process whose arguments can contain a
        path or other user-derived string.
    #>
    param([string[]]$Arguments)
    $parts = foreach ($a in @($Arguments)) {
        $s = [string]$a
        if ($s -eq '__DEPLOYKIT_DIRECT__') { '""' }
        elseif ($s -eq '') { '""' }
        elseif ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' }
        else { $s }
    }
    return ($parts -join ' ')
}

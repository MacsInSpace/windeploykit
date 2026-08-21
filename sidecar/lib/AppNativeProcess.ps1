# AppNativeProcess.ps1 - generic detached-process launcher.
# Extracted from USM RdpLauncher.ps1 (Start-AppNativeProcess) during the windeploykit port.

function Start-AppNativeProcess {
    <#
    .SYNOPSIS
        Launch an executable with EXACT arguments - no shell, no re-parsing.
        Start-Process -ArgumentList joins array items with spaces WITHOUT quoting,
        so any path containing spaces (the app data root is
        ".../Application Support/WinDeployKit/..." on macOS and
        "...\AppData\Roaming\WinDeployKit\..." on Windows) splits
        into multiple arguments. ProcessStartInfo.ArgumentList passes each item
        verbatim on every platform.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw "Failed to start $FilePath" }
    $proc
}


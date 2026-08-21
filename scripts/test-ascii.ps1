<#
.SYNOPSIS
    Fail if any tracked text file contains a non-ASCII character. See README "ASCII only".

.DESCRIPTION
    No em dashes, en dashes, smart quotes, box drawing, arrows or emoji anywhere in
    the repository - documentation, code, comments and UI strings alike. Binary files
    (boot .efi, .wim, torrents, images) are legitimately non-text and are skipped.

    Exits non-zero listing file, line and character so it can gate CI.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    $tracked = & git ls-files
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed - not a git repository?' }

    # Detect binaries by CONTENT (a NUL byte in the first 8 KB), the same heuristic
    # git uses. An extension allowlist missed app/src-tauri/binaries/pwsh-* , which
    # has no extension at all.
    function Test-IsBinaryFile {
        param([Parameter(Mandatory)][string]$Path)
        try {
            $fs = [IO.File]::OpenRead($Path)
            try {
                $buf = [byte[]]::new(8192)
                $read = $fs.Read($buf, 0, $buf.Length)
                for ($i = 0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { return $true } }
                return $false
            } finally { $fs.Dispose() }
        } catch { return $true }
    }

    $violations = [System.Collections.Generic.List[string]]::new()
    $scanned = 0

    foreach ($rel in $tracked) {
        $full = Join-Path $projectRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if (Test-IsBinaryFile -Path $full) { continue }

        $scanned++
        $lineNo = 0
        foreach ($line in [IO.File]::ReadLines($full)) {
            $lineNo++
            foreach ($ch in $line.ToCharArray()) {
                if ([int]$ch -gt 127) {
                    [void]$violations.Add(
                        ("{0}:{1}  U+{2:X4} '{3}'" -f $rel, $lineNo, [int]$ch, $ch))
                    break
                }
            }
        }
    }

    if ($violations.Count -gt 0) {
        foreach ($v in $violations | Select-Object -First 40) { Write-Host "  $v" }
        if ($violations.Count -gt 40) { Write-Host ("  ... and {0} more" -f ($violations.Count - 40)) }
        Write-Host ''
        Write-Host ("ascii: {0} line(s) contain non-ASCII characters - see README 'ASCII only'" -f $violations.Count)
        exit 1
    }

    Write-Host ("ascii: clean ({0} text files scanned)" -f $scanned)
    exit 0
} finally {
    Pop-Location
}

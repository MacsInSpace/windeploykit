# IPC helpers — stdout is JSON-only; diagnostics go to stderr.
#
# Depth notes:
#  - PowerShell's default ConvertTo-Json depth is 2; we override to a large
#    value because Notebook API rows can nest device > model > features etc.
#  - We pass -WarningAction SilentlyContinue so the cmdlet never emits the
#    "Resulting JSON is truncated as serialization has exceeded the set depth"
#    warning -- in non-interactive pwsh those warnings can leak onto stdout
#    via the host's default rendering path and corrupt the NDJSON stream.

$script:IpcJsonDepth = 32
$script:SidecarHostLogWritten = $false
$script:SidecarStdoutUtf8 = [System.Text.UTF8Encoding]::new($false)

function Write-SidecarStdoutLine {
    <#
        Emit one NDJSON line on stdout as UTF-8. Windows defaults Console output to an
        OEM code page; Unicode in IPC payloads (e.g. router notes) can corrupt into
        control characters and break the Rust JSON parser.
    #>
    param([Parameter(Mandatory)][string]$Text)
    try {
        [Console]::OutputEncoding = $script:SidecarStdoutUtf8
    } catch { }
    $payload = $Text + [Environment]::NewLine
    $bytes = $script:SidecarStdoutUtf8.GetBytes($payload)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# While Start-SidecarBootstrap runs on the main runspace thread, stdin is still
# pumped into RequestLines — poll this scriptblock during bootstrap waits so
# GetCredentialStatus / NOT_READY responses are not stuck behind a hung IWR.
$script:SidecarBootstrapDispatchPoll = $null

function Invoke-AppSidecarBootstrapPoll {
    if ($script:SidecarBootstrapDispatchPoll) {
        # Dispatch returns $true/$false — must not leak to caller's output (StrictMode + bootstrap probes).
        [void](& $script:SidecarBootstrapDispatchPoll)
    }
}

function Wait-AppSidecarSecondsWithDispatch {
    param([Parameter(Mandatory)][int]$Seconds)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Invoke-AppSidecarBootstrapPoll
        Start-Sleep -Seconds 1
    }
}

# Runtime counterpart to the bootstrap poll: a long-running handler (streaming
# driver download) can service queued IPC requests from inside its own loop so
# the rest of the app stays responsive — without this, every panel's calls queue
# behind the download and time out on the Rust side (blank panels). Depth-guarded:
# a nested long-running handler dispatched from the pump runs blocking rather
# than pumping again, which bounds re-entrancy at one level.
$script:SidecarDispatchPumpDepth = 0

function Invoke-SidecarDispatchPump {
    if ($script:SidecarDispatchPumpDepth -gt 0) { return }
    $dispatch = Get-Command Invoke-SidecarDispatchOnce -ErrorAction SilentlyContinue
    if (-not $dispatch) { return }
    $script:SidecarDispatchPumpDepth++
    try {
        # Drain what is queued right now (one request per iteration), capped so a
        # flood of queued calls cannot starve the download that is hosting us.
        $drained = 0
        while ((& $dispatch) -and (++$drained -lt 20)) { }
    } catch {
        # A nested command must never kill the hosting download.
    } finally {
        $script:SidecarDispatchPumpDepth--
    }
}

function Write-SidecarEvent {
    param(
        [Parameter(Mandatory)]
        [string]$EventName,
        [object]$Data = @{}
    )
    $ev = @{ event = $EventName; data = $Data }
    $json = $ev | ConvertTo-Json -Depth $script:IpcJsonDepth -Compress -WarningAction SilentlyContinue
    Write-SidecarStdoutLine -Text $json
}

function Write-SidecarResponse {
    param(
        [Parameter(Mandatory)]
        [int]$Id,
        [Parameter(ValueFromPipeline = $false)]
        [AllowNull()]
        $Data = $null
    )
    $resp = @{ id = $Id; ok = $true; data = $Data }
    $json = $resp | ConvertTo-Json -Depth $script:IpcJsonDepth -Compress -WarningAction SilentlyContinue
    Write-SidecarStdoutLine -Text $json
}

function Write-SidecarError {
    param(
        [Parameter(Mandatory)]
        [int]$Id,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Code = 'UNKNOWN'
    )
    $safeMsg = Protect-AppSidecarLogText -Text $Message
    $resp = @{ id = $Id; ok = $false; error = $safeMsg; code = $Code }
    $json = $resp | ConvertTo-Json -Depth $script:IpcJsonDepth -Compress -WarningAction SilentlyContinue
    Write-SidecarStdoutLine -Text $json
}

function Protect-AppSidecarLogText {
    <#
    .SYNOPSIS
        Redact passwords, tokens, and auth material before stderr / IPC error text is emitted.
        Detected values are replaced with the literal eight-asterisk marker ********.
        Documented in docs/core/logging/AGENT_NOTES_SIDECAR_LOGGING.md § The ******** redaction marker.
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text -or $Text.Length -eq 0) { return $Text }

    $s = $Text

    # HTTP Authorization headers and Basic auth blobs
    $s = [regex]::Replace($s, '(?i)(Authorization\s*:\s*Basic\s+)\S+', '${1}********')
    $s = [regex]::Replace($s, '(?i)(Bearer\s+)\S+', '${1}********')
    $s = [regex]::Replace($s, '(?i)\bBasic\s+[A-Za-z0-9+/=]{8,}\b', 'Basic ********')

    # XML / plist secret elements
    $s = [regex]::Replace(
        $s,
        '(?i)(<(?:password|passwd|secret|apikey|apitoken|key)[^>]*>)[^<]+(</(?:password|passwd|secret|apikey|apitoken|key)>)',
        '${1}********${2}'
    )

    # JSON / assignment / header secret keys (word boundary avoids passwordCached=…)
    $secretKeys = @(
        'password', 'passwd', 'pwd', 'passphrase', 'secret',
        'api[_-]?key', 'api[_-]?token', 'access[_-]?token', 'refresh[_-]?token',
        'client[_-]?secret', 'j_password', 'cert_password', 'user_password',
        'CompassApiKey', 'SecureString', 'Authorization'
    ) -join '|'
    $s = [regex]::Replace(
        $s,
        "(?i)\b($secretKeys)\b\s*[:=]\s*(""([^""\\]|\\.)*""|''([^''\\]|\\.)*''|[^\s&,;<>]+)",
        '$1=********'
    )
    $s = [regex]::Replace(
        $s,
        "(?i)([?&](?:$secretKeys)=)[^&\s""']+",
        '${1}********'
    )

    # user:password@ in URL authority (SMB, FTP, HTTPS basic-in-URL)
    $s = [regex]::Replace($s, '(?i)(://[^/\s:@]+):([^@\s/]+)@', '${1}:********@')

    return $s
}

function Write-SidecarLog {
    param(
        [string]$Message,
        [switch]$Flush
    )
    $safe = Protect-AppSidecarLogText -Text $Message
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [Console]::Error.WriteLine("[$ts] $safe")
    # Avoid Flush on every line — a full stderr pipe can block bootstrap on Windows.
    if ($Flush) { [Console]::Error.Flush() }
}

function Get-AppSidecarHostOsLabel {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'Windows' }
    if ($IsMacOS) { return 'macOS' }
    if ($IsLinux) { return 'Linux' }
    return 'unknown'
}

function Get-AppSidecarHostCpuArch {
    try {
        $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        switch ($a) {
            'X64' { return 'AMD64' }
            'Arm64' { return 'ARM64' }
            'X86' { return 'x86' }
            default { return $a }
        }
    } catch {
        if ($env:PROCESSOR_ARCHITECTURE) { return [string]$env:PROCESSOR_ARCHITECTURE }
        return 'unknown'
    }
}

function Get-AppSidecarTauriBinaryPath {
    $root = $script:AppSidecarProjectRoot
    if (-not $root) { return $null }
    if ($IsMacOS) {
        $contents = Split-Path -Path $root -Parent
        if (-not $contents) { return $null }
        $bin = Join-Path (Join-Path $contents 'MacOS') 'windeploykit'
        if (Test-Path -LiteralPath $bin) { return $bin }
    }
    return $null
}

function Get-AppSidecarPackageVariant {
    $bin = Get-AppSidecarTauriBinaryPath
    if ($bin -and (Get-Command lipo -ErrorAction SilentlyContinue)) {
        $info = [string](& lipo -info $bin 2>$null)
        if ($info -match '(?i)Non-fat file.*\barm64\b') { return 'aarch64' }
        if ($info -match '(?i)Non-fat file.*\bx86_64\b') { return 'x86_64' }
        if ($info -match '(?i)Architectures in the fat file' -and $info -match 'arm64' -and $info -match 'x86_64') {
            return 'universal'
        }
    }
    if ($env:APP_VARIANT) { return [string]$env:APP_VARIANT }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'x64' }
    return 'dev'
}

function Write-SidecarHostLog {
    <#
    .SYNOPSIS
        One operational line at sidecar bootstrap — app version/build/variant,
        host OS, CPU arch, and pwsh version (always visible when Debug is off).
    #>
    if ($script:SidecarHostLogWritten) { return }
    $script:SidecarHostLogWritten = $true

    $app = if ($env:APP_VERSION) { [string]$env:APP_VERSION } else { 'dev' }
    $build = if ($env:APP_BUILD) { [string]$env:APP_BUILD } else { 'dev' }
    $variant = Get-AppSidecarPackageVariant
    $os = Get-AppSidecarHostOsLabel
    $arch = Get-AppSidecarHostCpuArch
    $pwsh = if ($PSVersionTable.PSVersion) { $PSVersionTable.PSVersion.ToString() } else { 'unknown' }

    Write-SidecarLog "Sidecar host: app=$app build=$build variant=$variant os=$os arch=$arch pwsh=$pwsh" -Flush
}

function Test-AppSidecarVerboseLogging {
    <#
    .SYNOPSIS
        Settings → Diagnostics → Debug (ApplyRuntimeConfig → APP_VERBOSE_LOGGING).
        When unset before the first ApplyRuntimeConfig, defaults to disabled (quiet boot).
        The Tauri shell passes APP_VERBOSE_LOGGING at pwsh spawn from saved Settings.
    #>
    if ($null -ne $env:APP_VERBOSE_LOGGING -and $env:APP_VERBOSE_LOGGING -ne '') {
        return $env:APP_VERBOSE_LOGGING -eq '1' -or ($env:APP_VERBOSE_LOGGING -ieq 'true')
    }
    if ($script:AppState -and $script:AppState['RuntimeConfig']) {
        $rc = $script:AppState['RuntimeConfig']
        if ($rc -is [hashtable] -and $rc.ContainsKey('verboseLogging')) {
            return [bool]$rc['verboseLogging']
        }
    }
    return $false
}

function Test-AppSidecarVerbosePowershell {
    <#
    .SYNOPSIS
        Settings → Diagnostics → Verbose PowerShell (ApplyRuntimeConfig → APP_VERBOSE_POWERSHELL).
        When unset before the first ApplyRuntimeConfig, defaults to disabled (very noisy).
    #>
    if ($null -ne $env:APP_VERBOSE_POWERSHELL -and $env:APP_VERBOSE_POWERSHELL -ne '') {
        return $env:APP_VERBOSE_POWERSHELL -eq '1' -or ($env:APP_VERBOSE_POWERSHELL -ieq 'true')
    }
    if ($script:AppState -and $script:AppState['RuntimeConfig']) {
        $rc = $script:AppState['RuntimeConfig']
        if ($rc -is [hashtable] -and $rc.ContainsKey('verbosePowershell')) {
            return [bool]$rc['verbosePowershell']
        }
    }
    return $false
}

function Sync-AppSidecarPowershellLogPreferences {
    $pref = if (Test-AppSidecarVerbosePowershell) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference = $pref
    $global:DebugPreference = $pref
}

function Write-SidecarLogVerbose {
    param(
        [string]$Message,
        [switch]$Flush
    )
    if (-not (Test-AppSidecarVerboseLogging)) { return }
    Write-SidecarLog -Message $Message -Flush:$Flush
}

$script:SidecarBootstrapPhaseStartedAt = $null

function Reset-SidecarBootstrapPhaseTimer {
    $script:SidecarBootstrapPhaseStartedAt = [datetime]::UtcNow
}

function Write-SidecarBootProgress {
    <#
    .SYNOPSIS
        Operator-facing boot stage for the startup overlay (always emitted).
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$Step,
        [int]$Total = 14
    )
    if (Get-Command Write-SidecarEvent -ErrorAction SilentlyContinue) {
        Write-SidecarEvent -EventName 'bootstrap-phase' -Data @{
            message = $Message
            step    = $Step
            total   = $Total
        }
    }
}

function Get-SidecarBootstrapPhasePresentation {
    param([Parameter(Mandatory)][string]$Name)
    switch -Regex ($Name) {
        '^Start-SidecarBootstrap$' {
            return @{ message = 'Starting up…'; step = 1 }
        }
        '^network precheck' {
            return @{ message = 'Checking department network and internet…'; step = 2 }
        }
        '^Import-AppModules$' {
            return @{ message = 'Loading connection modules…'; step = 3 }
        }
        '^credential precheck' {
            return @{ message = 'Checking saved sign-in…'; step = 4 }
        }
        '^NPS mount early' {
            return @{ message = 'Preparing log file access…'; step = 5 }
        }
        '^dispatch loop starting' {
            return @{ message = 'Waiting for sign-in…'; step = 1 }
        }
        default { return $null }
    }
}

function Write-SidecarBootstrapPhase {
    <#
    .SYNOPSIS
        Timestamped bootstrap checkpoint for the Sidecar Log panel (stderr).
    #>
    param([Parameter(Mandatory)][string]$Name)
    $suffix = ''
    if ($script:SidecarBootstrapPhaseStartedAt) {
        $ms = ([datetime]::UtcNow - $script:SidecarBootstrapPhaseStartedAt).TotalMilliseconds
        $suffix = " (+$([int]$ms)ms)"
        $script:SidecarBootstrapPhaseStartedAt = [datetime]::UtcNow
    }
    Write-SidecarLogVerbose "Bootstrap > $Name$suffix" -Flush
    $presentation = Get-SidecarBootstrapPhasePresentation -Name $Name
    if ($presentation) {
        Write-SidecarBootProgress -Message $presentation.message -Step $presentation.step
    }
}

function Test-AppSidecarIpcPollCommand {
    param([Parameter(Mandatory)][string]$Cmd)
    # UI live polls — skip IPC begin/ok lines even when Debug is ON (errors and SLOW still log).
    return $Cmd -in @(
        'GetPxeBootPluginStatus'
        'GetPxeBootLogTail'
        'GetNpsMountStatus'
        'GetNpsLogRecords'
        'GetCiscoPrimeMappingStatus'
    )
}

function Write-SidecarIpcBegin {
    param(
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][int]$Id
    )
    if (Test-AppSidecarIpcPollCommand -Cmd $Cmd) { return }
    Write-SidecarLogVerbose "IPC: $Cmd ($Id) begin"
}

function Write-SidecarIpcComplete {
    param(
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][long]$ElapsedMs,
        [ValidateSet('ok', 'error')]
        [string]$Outcome = 'ok'
    )
    $slow = if ($ElapsedMs -ge 10000) { ' SLOW' } else { '' }
    if ($Outcome -eq 'ok' -and (Test-AppSidecarIpcPollCommand -Cmd $Cmd) -and -not $slow) { return }
    if (-not (Test-AppSidecarVerboseLogging) -and $Outcome -ne 'error') { return }
    Write-SidecarLog "IPC: $Cmd ($Id) $Outcome +${ElapsedMs}ms$slow" -Flush
}

function Get-AppSidecarIpcErrorPresentation {
    <#
        Turn raw handler exceptions into a short operator-facing line (Sidecar Log)
        and a concise IPC error message (frontend toast). Stack traces are omitted here.
    #>
    param(
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][string]$Message
    )

    $line = ($Message -split "`n" | Select-Object -First 1).Trim()
    $code = 'UNKNOWN'
    $user = $line

    if ($line -match '(?i)^yt-dlp failed:\s*ERROR:\s*\[youtube\]\s*([\w-]{11}):\s*(.+)$') {
        $vid = $Matches[1]
        $reason = $Matches[2].Trim().TrimEnd('.')
        if ($reason -match '(?i)restricted|network administrator|google workspace|video unavailable') {
            $user = "YouTube blocked on this network ($vid)"
            $code = 'YOUTUBE_BLOCKED'
        }
        else {
            $user = "YouTube: $reason ($vid)"
            $code = 'MINI_PLAYER_YTDLP'
        }
    }
    elseif ($line -match '(?i)^yt-dlp failed to discover a stream URL:\s*(.+)$') {
        $detail = ($Matches[1] -replace '(?i)^ERROR:\s*', '').Trim()
        if ($detail -match '(?i)timed out|unable to connect to proxy') {
            $user = "Could not discover Lo-Fi live stream — $detail"
        }
        else {
            $user = "Could not discover Lo-Fi live stream — $detail"
        }
        $code = 'MINI_PLAYER_YTDLP'
    }
    elseif ($line -match '(?i)^yt-dlp failed:\s*(.+)$') {
        $rest = ($Matches[1] -replace '(?i)^ERROR:\s*', '').Trim()
        if ($rest -match '(?i)unable to connect to proxy') {
            $user = 'Zscaler proxy unreachable — enable ZCC or turn off Use Zscaler proxy in Settings'
            $code = 'MINI_PLAYER_PROXY'
        }
        elseif ($rest -match '(?i)timed out') {
            $user = 'YouTube timed out — try Zscaler proxy or another network'
            $code = 'YOUTUBE_UNREACHABLE'
        }
        else {
            $user = "yt-dlp: $rest"
            $code = 'MINI_PLAYER_YTDLP'
        }
    }
    elseif ($line -match '(?i)^yt-dlp did not return') {
        $user = $line
        $code = 'MINI_PLAYER_YTDLP'
    }
    elseif ($line -match '(?i)YouTube unreachable from the app') {
        $user = 'YouTube unreachable — try Zscaler proxy or paste a watch URL in Settings'
        $code = 'YOUTUBE_UNREACHABLE'
    }

    @{
        Log  = "[$Cmd] $user"
        User = $user
        Code = $code
    }
}

function Write-SidecarIpcErrorLog {
    param(
        [Parameter(Mandatory)][string]$LogLine,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-SidecarLog $LogLine
    if (-not (Test-AppSidecarVerboseLogging) -or -not $ErrorRecord) { return }

    $inv = $ErrorRecord.InvocationInfo
    if ($inv -and $inv.PositionMessage) {
        Write-SidecarLogVerbose "  at $($inv.PositionMessage.Trim())"
    }
    if ($ErrorRecord.ScriptStackTrace) {
        foreach ($stackLine in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            $trimmed = $stackLine.Trim()
            if ($trimmed) { Write-SidecarLogVerbose "  $trimmed" }
        }
    }
}

$script:AppSystemStartReadyLogged = $false

function Reset-AppSystemStartReadyLog {
    $script:AppSystemStartReadyLogged = $false
}

function Test-AppSystemStartNpsGateComplete {
    <#
    .SYNOPSIS
        True when NPS is not blocking the boot-complete log (not mounting).
        idle = mount never queued; ready/failed/skipped = terminal.
    #>
    if (-not $script:AppState) { return $false }
    return $script:AppState.NpsMountStatus -ne 'mounting'
}

function Try-Write-AppSystemStartReadyLog {
    <#
    .SYNOPSIS
        One operational line when standard boot is complete: IPC dispatch is up and
        NPS is not still mounting. Call from Start-SidecarDispatchLoop and after
        NPS mount/sync when IsReady.
    #>
    if ($script:AppSystemStartReadyLogged) { return }
    if (-not $script:AppState -or -not $script:AppState.IsReady) { return }
    if (-not (Test-AppSystemStartNpsGateComplete)) { return }

    $script:AppSystemStartReadyLogged = $true

    $suffix = switch ($script:AppState.NpsMountStatus) {
        'ready'   { ', NPS LogFiles$ ready' }
        'failed'  { '; NPS mount failed' }
        'skipped' { '; NPS skipped' }
        default   { '' }
    }

    Write-SidecarLog "System start ready (sessions open$suffix)." -Flush
}

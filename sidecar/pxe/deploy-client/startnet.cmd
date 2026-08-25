@echo off
rem ===========================================================================
rem  WinDeployKit deploy client - baked into an imported boot WIM as
rem  \Windows\System32\startnet.cmd.
rem
rem  Deliberately cmd-only. A stock Windows boot.wim - the one thing every user
rem  already has - ships dism, diskpart, bcdboot, net and robocopy, and ships
rem  NO PowerShell and NO curl. Anything richer would mean an ADK, which is a
rem  download, a licence and a Windows machine to run it on.
rem
rem  Reads the files that iPXE drops into System32 at boot (the 'deploy-share'
rem  overlay profile - served by Caddy, injected by wimboot, nothing in the WIM):
rem     deploy.unc      \\host\Deploy$
rem     deploy.cred     line 1 user, line 2 password
rem     deploy.loghost  http://host:port - log lines are POSTed here (optional)
rem     deploy.autoprep present = may repartition disk 0 without asking
rem     7z.exe, 7za.dll, 7zxa.dll, curl.exe - the two tools a stock WinPE lacks
rem  and per task sequence on the share:
rem     Z:\TaskSequences\_default.txt   the sequence id to run
rem     Z:\TaskSequences\<id>.env       KEY=VALUE, written by the panel
rem  Drivers come from Z:\Drivers\<Make>\<Model>\ (one archive or an INF tree),
rem  matched on the SMBIOS manufacturer/product, then Z:\Drivers\aliases.txt,
rem  then Z:\Drivers\_default - the same layout ImageDeployer searches.
rem
rem  Anything missing drops to the WinPE prompt with the reason on screen -
rem  never a silent reboot loop.
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

rem --- themed console -------------------------------------------------------
rem  Conhost reads HKCU\Console at WINDOW CREATION, so the theme needs a fresh
rem  window: apply the keys, relaunch this script inside one, and WAIT for it.
rem  start /wait is load-bearing - winpeshl reboots WinPE when its child exits,
rem  so the original console must stay alive as the anchor while the themed
rem  window does the work. WDK_THEMED (inherited env) stops the recursion.
rem  Palette is BGR: near-black panel, soft grey text, green/red/amber accents.
rem  WindowAlpha 0xE6 = ~90% opaque, so the deploy background shows through.
if not defined WDK_THEMED (
    set "WDK_THEMED=1"
    reg add "HKCU\Console" /v WindowAlpha /t REG_DWORD /d 230 /f >nul 2>&1
    reg add "HKCU\Console" /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKCU\Console" /v FaceName /t REG_SZ /d Consolas /f >nul 2>&1
    reg add "HKCU\Console" /v FontFamily /t REG_DWORD /d 54 /f >nul 2>&1
    reg add "HKCU\Console" /v FontSize /t REG_DWORD /d 1310720 /f >nul 2>&1
    reg add "HKCU\Console" /v FontWeight /t REG_DWORD /d 400 /f >nul 2>&1
    reg add "HKCU\Console" /v QuickEdit /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKCU\Console" /v CursorSize /t REG_DWORD /d 25 /f >nul 2>&1
    reg add "HKCU\Console" /v WindowSize /t REG_DWORD /d 2621540 /f >nul 2>&1
    reg add "HKCU\Console" /v ScreenBufferSize /t REG_DWORD /d 32768100 /f >nul 2>&1
    reg add "HKCU\Console" /v ScreenColors /t REG_DWORD /d 7 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable00 /t REG_DWORD /d 1446416 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable02 /t REG_DWORD /d 9156159 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable07 /t REG_DWORD /d 13159632 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable10 /t REG_DWORD /d 10871631 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable12 /t REG_DWORD /d 6378976 /f >nul 2>&1
    reg add "HKCU\Console" /v ColorTable14 /t REG_DWORD /d 4305888 /f >nul 2>&1
    rem Hide THIS (anchor) console before the themed one opens - it must stay
    rem alive (winpeshl reboots WinPE when its child exits) but not visible: an
    rem opaque anchor behind the translucent window blocked the background.
    if exist "%SystemRoot%\System32\wdk-bg.exe" start "" "%SystemRoot%\System32\wdk-bg.exe" --hide-console
    start /wait "WinDeployKit" cmd /c "%~f0"
    exit
)
title WinDeployKit

set "LOG=X:\Windows\Temp\deploy.log"
if not exist "X:\Windows\Temp" md "X:\Windows\Temp" >nul 2>&1
set "SYS=%SystemRoot%\System32"

rem --- screen -------------------------------------------------------------
rem  A console UI, not an HTA: mshta.exe and mshtml.dll are NOT in a stock
rem  boot.wim (WinPE-HTA is an ADK optional component), while cmd and conhost
rem  always are - so the same "nothing but stock WinPE" rule that shaped the
rem  client shapes its UI (checked against Server 2025 boot.wim, 2026-08-23).
call :ui_init
rem Deploy background: our own viewer paints it behind this console - WinPE 26100
rem no longer paints System32\winpe.jpg at all (proven 2026-08-24). Optional both
rem halves; Secure Boot boots pick the exe up from Z:\Tools after the share connects.
if not defined BGON if exist "%SYS%\wdk-bg.exe" if exist "%SYS%\deploy-bg.bmp" (
    start "" "%SYS%\wdk-bg.exe" "%SYS%\deploy-bg.bmp"
    set "BGON=1"
)
rem Deploy status panel (wdk-panel.exe): the face of the deploy client, a
rem native GDI window over the wallpaper fed by deploy.state and the log
rem tail; :ui_takeover hides the console once it is provably alive. C/GDI
rem like the wallpaper viewer, NEVER Go: a bare Go runtime exe (no window,
rem no UI library) hard-resets WinPE 26100 within seconds - proven in the
rem boot-chain VM 2026-08-25 after the Go panel took every boot down.
if not defined UIEXE if exist "%SYS%\wdk-panel.exe" (
    start "" "%SYS%\wdk-panel.exe"
    set "UIEXE=1"
)

rem --- who we are (no wmic, no PowerShell: SMBIOS strings live in the registry) ---
set "MAKE="
set "MODEL="
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| find "REG_SZ"') do set "MAKE=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemProductName 2^>nul ^| find "REG_SZ"') do set "MODEL=%%B"
if not defined MAKE set "MAKE=Unknown"
if not defined MODEL set "MODEL=Unknown"

call :log "=== WinDeployKit deploy client ==="
call :log "Machine: %MAKE% / %MODEL%"
call :ui_stage 1 run
call :log "Starting network (wpeinit)..."
wpeinit
call :ui_stage 1 ok
call :ui_takeover

rem The serial is not in the registry; the first NIC's MAC is the stable id the
rem Netboot panel files this device's log under (the same for a re-image).
set "SERIAL="
for /f "tokens=2 delims=:" %%A in ('ipconfig /all ^| find "Physical Address"') do (
    if not defined SERIAL set "SERIAL=%%A"
)
set "SERIAL=%SERIAL: =%"
set "SERIAL=%SERIAL:-=%"
if not defined SERIAL set "SERIAL=UNKNOWN"
set "SESSION=%RANDOM%%RANDOM%%RANDOM%"

rem Live log to the Netboot panel - same endpoint ImageDeployer pushes to. Only
rem possible because curl.exe rides in with this script; silent when it cannot.
set "LOGHOST="
if exist "%SYS%\deploy.loghost" set /p LOGHOST=<"%SYS%\deploy.loghost"
set "CURL="
if exist "%SYS%\curl.exe" set "CURL=%SYS%\curl.exe"
if defined LOGHOST if defined CURL (
    call :log "Log push: %LOGHOST%/imaging-log/ingest (device %SERIAL%)"
    call :heartbeat_start
) else (
    call :log "Log push off (no loghost or no curl) - log is %LOG% only."
)

set "UNC="
set "DUSER="
set "DPASS="
if exist "%SYS%\deploy.unc" set /p UNC=<"%SYS%\deploy.unc"
if not defined UNC (
    call :fail "No deploy.unc - turn on the deploy share in the Netboot panel and Start Imaging Services."
    goto :shell
)

if exist "%SYS%\deploy.cred" (
    set /a __n=0
    for /f "usebackq delims=" %%L in ("%SYS%\deploy.cred") do (
        set /a __n+=1
        if !__n! EQU 1 set "DUSER=%%L"
        if !__n! EQU 2 set "DPASS=%%L"
    )
)

rem The NIC may still be settling right after wpeinit, so give the connect a few
rem tries before giving up; the real net use error goes to the log on each miss.
rem <nul on every net use: with no credential, net use PROMPTS for a username, and
rem with output redirected the prompt is invisible - the boot just hangs at
rem "attempt 1 of 5" forever (Craig hit exactly that, 2026-08-24, cred mode blank).
rem <nul makes it fail instantly instead, and the error lands in the log.
if not defined DUSER call :log "No deploy.cred was injected (credential mode is blank) - the share must allow unauthenticated access, or pick throwaway/vault in the Netboot panel."
net use Z: >nul 2>&1 && net use Z: /delete /y >nul 2>&1
set "ZOK="
for /l %%A in (1,1,5) do (
    if not defined ZOK (
        call :log "Connecting !UNC! (attempt %%A of 5)"
        if defined DUSER (
            net use Z: "!UNC!" /user:"!DUSER!" "!DPASS!" <nul >"%SYS%\netuse.txt" 2>&1
        ) else (
            net use Z: "!UNC!" <nul >"%SYS%\netuse.txt" 2>&1
        )
        if not errorlevel 1 (
            set "ZOK=1"
        ) else (
            for /f "usebackq delims=" %%E in ("%SYS%\netuse.txt") do call :log "  net use: %%E"
            ping -n 4 127.0.0.1 >nul
        )
    )
)
del /q "%SYS%\netuse.txt" >nul 2>&1
if defined ZOK call :ui_stage 2 ok
if not defined ZOK call :ui_stage 2 bad
if not defined ZOK (
    call :fail "Could not connect !UNC! after 5 tries - see the net use lines above and check the share in the Netboot panel."
    goto :shell
)

rem --- self-heal tools from the share --------------------------------------
rem  Secure Boot clients cannot take unsigned PE files (7z, curl) as initrd -
rem  iPXE prints "Verification failed: Security Policy Violation" and skips
rem  them (seen live 2026-08-24). The share has the same four files under
rem  Z:\Tools, and SMB has no such rule, so pick up whatever is missing here.
rem  Harmless everywhere else: if initrd delivered them, this copies nothing.
for %%T in (7z.exe 7za.dll 7zxa.dll curl.exe wdk-bg.exe wdk-panel.exe) do (
    if not exist "%SYS%\%%T" if exist "Z:\Tools\%%T" (
        copy /y "Z:\Tools\%%T" "%SYS%\%%T" >nul 2>&1
        if exist "%SYS%\%%T" call :log "Fetched %%T from the share (Secure Boot boot path)"
    )
)
if not defined CURL if exist "%SYS%\curl.exe" set "CURL=%SYS%\curl.exe"
if defined LOGHOST if defined CURL call :heartbeat_start
if not defined BGON if exist "%SYS%\wdk-bg.exe" if exist "%SYS%\deploy-bg.bmp" (
    start "" "%SYS%\wdk-bg.exe" "%SYS%\deploy-bg.bmp"
    set "BGON=1"
)
if not defined UIEXE if exist "%SYS%\wdk-panel.exe" (
    start "" "%SYS%\wdk-panel.exe"
    set "UIEXE=1"
)
call :ui_takeover

rem --- which task sequence -------------------------------------------------
set "TSID="
if exist "%SYS%\deploy.tsid" set /p TSID=<"%SYS%\deploy.tsid"
if not defined TSID if exist "Z:\TaskSequences\_default.txt" set /p TSID=<"Z:\TaskSequences\_default.txt"
for /f "tokens=* delims= " %%A in ("%TSID%") do set "TSID=%%A"
if not defined TSID (
    call :fail "No task sequence selected - set a default in the Netboot panel."
    goto :shell
)
if not exist "Z:\TaskSequences\%TSID%.env" (
    call :fail "Task sequence '!TSID!' is not published - Save and publish it in the Netboot panel."
    goto :shell
)

rem --- what it deploys ------------------------------------------------------
set "TS_NAME="
set "TS_IMAGE="
set "TS_INDEX="
set "TS_UNATTEND="
set "TS_AUTOPREP="
set "TS_KIND="
set "TS_WIN11BYPASS="
for /f "usebackq tokens=1,* delims==" %%K in ("Z:\TaskSequences\%TSID%.env") do (
    if /i "%%K"=="TS_NAME"     set "TS_NAME=%%L"
    if /i "%%K"=="TS_IMAGE"    set "TS_IMAGE=%%L"
    if /i "%%K"=="TS_INDEX"    set "TS_INDEX=%%L"
    if /i "%%K"=="TS_UNATTEND" set "TS_UNATTEND=%%L"
    if /i "%%K"=="TS_AUTOPREP" set "TS_AUTOPREP=%%L"
    if /i "%%K"=="TS_KIND"     set "TS_KIND=%%L"
    if /i "%%K"=="TS_WIN11BYPASS" set "TS_WIN11BYPASS=%%L"
    if /i "%%K"=="TS_FINALE"   set "TS_FINALE=%%L"
)
call :ui_stage 3 ok
call :log "Task sequence: %TS_NAME% (%TSID%)"

if not defined TS_IMAGE (
    call :fail "Task sequence '!TSID!' has no Windows image - pick one in the Netboot panel."
    goto :shell
)
if not defined TS_INDEX set "TS_INDEX=1"
set "WIMPATH=Z:\%TS_IMAGE%"
if not exist "%WIMPATH%" (
    call :fail "Image not on the share: !WIMPATH! - is the ISO still in the library?"
    goto :shell
)
call :ui_stage 4 ok
call :log "Image: %WIMPATH% (index %TS_INDEX%)"

rem --- WinPE-side drivers: the disk has to exist before diskpart can see it ---
rem  Storage INFs from the matched pack are loaded into THIS WinPE (drvload).
rem  Proxmox/VirtIO is the case that matters; on bare metal this is a no-op.
set "SEVENZIP="
if exist "%SYS%\7z.exe" set "SEVENZIP=%SYS%\7z.exe"
set "DRIVERDIR="
call :ui_stage 5 run
call :find_drivers
if defined DRIVERDIR call :ui_stage 5 ok
if not defined DRIVERDIR call :ui_stage 5 skip
rem Subroutines of PLAIN lines, and !delayed! in every ( ) and for-set below:
rem %MODEL% / %DRIVERDIR% carry the SMBIOS model name, and a ")" in it (QEMU
rem "Standard PC (Q35 + ICH9, 2009)", Dell "(SFF)" models) terminates a
rem parenthesised block or for-set AT PARSE TIME - cmd dies on the orphaned
rem remainder, the anchor exits, winpeshl reboots. Same bomb family as the
rem heartbeat writer (found 2026-08-25 via the boot-chain VM).
if defined DRIVERDIR call :drivers_found
if not defined DRIVERDIR call :drivers_missing
if defined DRIVERSTAGE call :drvload_storage

rem --- target volume --------------------------------------------------------
rem  Reuse a prepared W: if it is already there; otherwise repartition disk 0 -
rem  and ONLY without asking when the panel published deploy.autoprep.
set "APPLYDIR="
if exist "W:\" set "APPLYDIR=W:\"
if not defined APPLYDIR (
    if exist "%SYS%\deploy.autoprep" set "TS_AUTOPREP=1"
    if not "%TS_AUTOPREP%"=="1" call :confirm_wipe
    if defined NOWIPE (
        call :fail "Not confirmed - nothing was changed."
        goto :shell
    )
    call :log "Partitioning disk 0 (GPT: EFI 260MB, MSR 16MB, Windows)"
    > "X:\Windows\Temp\diskpart.txt" (
        echo select disk 0
        echo clean
        echo convert gpt
        echo create partition efi size=260
        echo format quick fs=fat32 label="System"
        echo assign letter=S
        echo create partition msr size=16
        echo create partition primary
        echo format quick fs=ntfs label="Windows"
        echo assign letter=W
    )
    diskpart /s "X:\Windows\Temp\diskpart.txt" >> "%LOG%" 2>&1
    if errorlevel 1 (
        call :fail "diskpart failed - see X:\Windows\Temp\deploy.log"
        goto :shell
    )
    set "APPLYDIR=W:\"
)
call :ui_stage 6 ok
call :log "Applying to %APPLYDIR%"
call :log "Applying image - DISM runs quiet in the log; live percent on screen."

rem --- apply ----------------------------------------------------------------
rem The image's UNCOMPRESSED size feeds the panel's byte-accurate progress:
rem W: used bytes vs this number is what DISM has really written - the real
rem percent Craig asked for, with no console scraping (that froze the panel
rem against conhost's lock). One metadata read over SMB, a few seconds.
set "APPLYBYTES="
for /f "tokens=1,* delims=:" %%A in ('dism /Get-WimInfo /WimFile:"%WIMPATH%" /Index:%TS_INDEX% 2^>nul ^| find /i "Size"') do if not defined APPLYBYTES set "APPLYBYTES=%%B"
call :ui_stage 7 run
call :ui_note "Applying the image..."
dism /Apply-Image /ImageFile:"%WIMPATH%" /Index:%TS_INDEX% /ApplyDir:%APPLYDIR%
if errorlevel 1 (
    call :fail "DISM /Apply-Image failed - see the DISM output above."
    goto :shell
)
call :ui_stage 7 ok
call :log "DISM apply complete."

rem --- Windows 11 requirement bypass (optional) -----------------------------
rem  Written into the APPLIED image's own SYSTEM hive (LabConfig + MoSetup) so OOBE
rem  honours it on a TPM-less VM or old hardware - reg load/add/unload, all in stock
rem  WinPE. No effect on Server or a supported PC.
if /i "%TS_WIN11BYPASS%"=="1" (
    call :log "Windows 11 requirement bypass -> applied image registry"
    reg load HKLM\WDKSYS "%APPLYDIR%Windows\System32\config\SYSTEM" >>"%LOG%" 2>&1
    if not errorlevel 1 (
        for %%K in (BypassTPMCheck BypassSecureBootCheck BypassRAMCheck BypassCPUCheck BypassStorageCheck) do (
            reg add "HKLM\WDKSYS\Setup\LabConfig" /v %%K /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
        )
        reg add "HKLM\WDKSYS\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
        reg unload HKLM\WDKSYS >>"%LOG%" 2>&1
    ) else (
        call :log "WARNING: could not load the image SYSTEM hive - Win11 bypass skipped."
    )
)

rem --- drivers into the applied image (same call ImageDeployer makes) --------
if defined DRIVERSTAGE (
    call :log "DISM /Add-Driver /Recurse from %DRIVERSTAGE%"
    dism /Image:%APPLYDIR% /Add-Driver /Driver:"%DRIVERSTAGE%" /Recurse >> "%LOG%" 2>&1
    if errorlevel 1 (
        call :log "WARNING: DISM /Add-Driver reported errors - see the log; Windows will still boot with inbox drivers."
    ) else (
        call :log "Drivers injected."
    )
)

rem --- boot files -----------------------------------------------------------
set "EFILETTER=S"
if not exist "%EFILETTER%:\" set "EFILETTER="
if defined EFILETTER (
    bcdboot %APPLYDIR%Windows /s %EFILETTER%: /f UEFI >> "%LOG%" 2>&1
) else (
    bcdboot %APPLYDIR%Windows >> "%LOG%" 2>&1
)
if errorlevel 1 (
    call :fail "bcdboot failed - Windows was applied but will not boot yet."
    goto :shell
)
call :ui_stage 8 ok
call :log "Boot files written."

rem --- first-boot unattend --------------------------------------------------
if defined TS_UNATTEND (
    if exist "Z:\TaskSequences\%TS_UNATTEND%" (
        if not exist "%APPLYDIR%Windows\Panther" md "%APPLYDIR%Windows\Panther" >nul 2>&1
        copy /y "Z:\TaskSequences\%TS_UNATTEND%" "%APPLYDIR%Windows\Panther\unattend.xml" >nul
        if errorlevel 1 (
            call :log "WARNING: could not write the unattend - Windows will boot to plain OOBE."
        ) else (
            call :log "Unattend written to %APPLYDIR%Windows\Panther\unattend.xml"
        )
    ) else (
        call :log "WARNING: %TS_UNATTEND% is not on the share - Windows will boot to plain OOBE."
    )
)

rem --- first-boot steps + eval conversion (run from SetupComplete, not the unattend) ---
rem The reg/cmd steps and the server eval->licensed conversion are scripts on the share,
rem copied into the image here and chained from SetupComplete.cmd (SYSTEM, after setup,
rem before logon). Keeping them out of the unattend is what stopped Setup rejecting the
rem answer file at specialize (Craig, 2026-08-23).
set "SCR=%APPLYDIR%Windows\Setup\Scripts"
set "SETUPCOMPLETE=%SCR%\SetupComplete.cmd"
rem What the machine does once first-boot setup finishes. Default restart: the
rem tweaks want it, and the server eval->licensed conversion literally NEEDS it -
rem DISM Set-Edition stages the change and About keeps saying Evaluation until the
rem reboot (Craig, 2026-08-24). An env published before this option has no key.
if not defined TS_FINALE set "TS_FINALE=restart"
set "NEEDSC="
if exist "Z:\TaskSequences\%TSID%.firstboot.cmd" set "NEEDSC=1"
if /i "%TS_KIND%"=="server" if exist "Z:\TaskSequences\convert-eval.ps1" set "NEEDSC=1"
if /i not "%TS_FINALE%"=="none" set "NEEDSC=1"
if defined NEEDSC (
    if not exist "%SCR%" md "%SCR%" >nul 2>&1
    rem SetupComplete.cmd runs each helper from its own folder (%~dp0 = ...\Setup\Scripts).
    > "%SETUPCOMPLETE%" echo @echo off
    if exist "Z:\TaskSequences\%TSID%.firstboot.cmd" (
        copy /y "Z:\TaskSequences\!TSID!.firstboot.cmd" "%SCR%\!TSID!.firstboot.cmd" >nul
        >>"%SETUPCOMPLETE%" echo if exist "%%~dp0!TSID!.firstboot.cmd" call "%%~dp0!TSID!.firstboot.cmd"
        call :log "First-boot steps staged (!TSID!.firstboot.cmd -> Setup\Scripts)"
    )
    if /i "%TS_KIND%"=="server" if exist "Z:\TaskSequences\convert-eval.ps1" (
        copy /y "Z:\TaskSequences\convert-eval.ps1" "%SCR%\Convert-EvalEdition.ps1" >nul
        >>"%SETUPCOMPLETE%" echo if exist "%%~dp0Convert-EvalEdition.ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%~dp0Convert-EvalEdition.ps1"
        call :log "Eval->licensed conversion staged (Convert-EvalEdition.ps1 -> Setup\Scripts)"
    )
    rem Finale LAST - after the steps and the conversion have run. SetupComplete runs
    rem as SYSTEM before anyone signs in, so restart/shutdown act right there; signout
    rem waits for the first (auto)logon via RunOnce and signs that session out.
    if /i "%TS_FINALE%"=="restart" (
        >>"%SETUPCOMPLETE%" echo shutdown.exe /r /t 10
        call :log "Finale: restart after first-boot setup"
    )
    if /i "%TS_FINALE%"=="shutdown" (
        >>"%SETUPCOMPLETE%" echo shutdown.exe /s /t 10
        call :log "Finale: shut down after first-boot setup"
    )
    if /i "%TS_FINALE%"=="signout" (
        >>"%SETUPCOMPLETE%" echo reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v WDKFinaleSignOut /t REG_SZ /d "shutdown.exe /l" /f
        call :log "Finale: sign out after first sign-in"
    )
)

call :ui_stage 9 ok
copy /y "%LOG%" "%APPLYDIR%Windows\Temp\windeploykit-deploy.log" >nul 2>&1
call :log "Done - rebooting into Windows."
call :heartbeat_stop
net use Z: /delete /y >nul 2>&1
wpeutil reboot
goto :eof

:heartbeat_start
rem Idempotent: the self-heal path calls this again after fetching curl from the
rem share (Secure Boot boots), and two loops would double-post every 30s. HBFLAG
rem is only ever defined by a previous run of this routine.
if defined HBFLAG goto :eof
rem A background cmd that POSTs a heartbeat every 30s so the Netboot panel keeps
rem this device "active" through a 10-minute DISM apply that prints nothing. It
rem is a file of its own because the payload's escaped quotes do not survive a
rem nested `cmd /c "..."`. It exits on its own when the flag file disappears;
rem WinPE has no taskkill. ping is the sleep - WinPE has no timeout.exe either.
set "HBFLAG=X:\Windows\Temp\deploy.heartbeat"
set "HBCMD=X:\Windows\Temp\deploy-heartbeat.cmd"
rem A literal word, never `echo on`/`echo off` - those are the echo directive,
rem not text, so `> file echo on` flips command-echo on for the whole script
rem (the wall of echoed lines Craig saw, 2026-08-23) and writes nothing.
> "%HBFLAG%" echo hb
rem One redirect per line, NO ( ) block: %MODEL% expands at parse time, and on
rem QEMU/Proxmox (and real PCs like "OptiPlex 7050 (SFF)") it contains a ")"
rem that TERMINATES a parenthesised block mid-line - cmd then dies on the
rem orphaned remainder, the anchor exits, and winpeshl reboots WinPE. This was
rem the "VM crashes right after wpeinit" loop (found via the boot-chain VM,
rem 2026-08-25: last log line "Log push:", "Connecting" never arrived). Parens
rem are only special inside a block, so plain lines are safe.
rem Each tick posts EITHER the apply percent (when the panel's deploy.pct
rem changed - the panel measures it, this loop has curl) or a plain
rem heartbeat. %%P%%/%%LASTP%% are escaped so they expand in the CHILD.
> "%HBCMD%" echo @echo off
>>"%HBCMD%" echo :loop
>>"%HBCMD%" echo if not exist "%HBFLAG%" exit
>>"%HBCMD%" echo set "P="
>>"%HBCMD%" echo if exist "X:\Windows\Temp\deploy.pct" set /p P=^<"X:\Windows\Temp\deploy.pct"
>>"%HBCMD%" echo if not defined P goto :beat
>>"%HBCMD%" echo if "%%P%%"=="%%LASTP%%" goto :beat
>>"%HBCMD%" echo "%CURL%" -s -m 3 -o NUL -H "Content-Type: application/json" -d "{\"serial\":\"%SERIAL%\",\"make\":\"%MAKE%\",\"model\":\"%MODEL%\",\"session\":\"%SESSION%\",\"lines\":[\"Apply progress: %%P%%\"]}" "%LOGHOST%/imaging-log/ingest" ^>nul 2^>^&1
>>"%HBCMD%" echo set "LASTP=%%P%%"
>>"%HBCMD%" echo goto :sleep
>>"%HBCMD%" echo :beat
>>"%HBCMD%" echo "%CURL%" -s -m 3 -o NUL -H "Content-Type: application/json" -d "{\"serial\":\"%SERIAL%\",\"make\":\"%MAKE%\",\"model\":\"%MODEL%\",\"session\":\"%SESSION%\",\"heartbeat\":true,\"lines\":[]}" "%LOGHOST%/imaging-log/ingest" ^>nul 2^>^&1
>>"%HBCMD%" echo :sleep
>>"%HBCMD%" echo ping -n 31 127.0.0.1 ^>nul
>>"%HBCMD%" echo goto :loop
start "" /b cmd /c "%HBCMD%"
goto :eof

:heartbeat_stop
if defined HBFLAG if exist "%HBFLAG%" del /q "%HBFLAG%" >nul 2>&1
goto :eof

:ui_init
rem Optional customisation, injected as overlay files beside the client:
rem   deploy.title     one line of header text
rem   deploy-logo.txt  a small ASCII logo (any lines, drawn above the header)
set "UITITLE=WinDeployKit"
if exist "%SYS%\deploy.title" set /p UITITLE=<"%SYS%\deploy.title"
set "STATE=X:\Windows\Temp\deploy.state"
set "UINOTE="
rem VT escape, so the header can be bold without a colour scheme. Windows 10+
rem conhost understands it; if the trick yields nothing we simply print plain.
for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
if defined ESC (
    set "UIB=%ESC%[1m"
    set "UID=%ESC%[90m"
    set "UIR=%ESC%[0m"
) else (
    set "UIB=" & set "UID=" & set "UIR="
)
set "STG1=Network"
set "STG2=Deploy share"
set "STG3=Task sequence"
set "STG4=Windows image"
set "STG5=Drivers"
set "STG6=Disk"
set "STG7=Apply image"
set "STG8=Boot files"
set "STG9=First-boot files"
set "STGCOUNT=9"
for /l %%i in (1,1,9) do set "ST%%i=  "
call :ui_draw
goto :eof

:ui_stage
rem %1 = stage number, %2 = run|ok|bad|skip
if /i "%~2"=="run"  set "ST%~1=>>"
if /i "%~2"=="ok"   set "ST%~1=ok"
if /i "%~2"=="bad"  set "ST%~1=!!"
if /i "%~2"=="skip" set "ST%~1=--"
set "UINOTE="
call :ui_draw
goto :eof

:ui_note
set "UINOTE=%~1"
call :ui_draw
goto :eof

:ui_fail
set "UINOTE=STOPPED: %~1"
call :ui_draw
goto :eof

:ui_draw
rem A logo is optional and comes from a file - no built-in ASCII art: backslashes
rem and pipes in art collide with cmd escaping and broke this block once already.
cls
if exist "%SYS%\deploy-logo.txt" (
    for /f "usebackq delims=" %%L in ("%SYS%\deploy-logo.txt") do echo   %%L
    echo.
)
echo   %UIB%%UITITLE%%UIR%
echo   %UID%%MAKE% / %MODEL%   %SERIAL%%UIR%
echo   ----------------------------------------------------------
for /l %%i in (1,1,%STGCOUNT%) do call :ui_row %%i
echo   ----------------------------------------------------------
if defined UINOTE echo   %UINOTE%
echo.
call :ui_state
goto :eof

:ui_row
call set "_n=%%STG%~1%%"
call set "_s=%%ST%~1%%"
echo    [!_s!] !_n!
goto :eof

:ui_state
rem Snapshot for wdk-ui.exe: key=value, stageN=<st>~<name>, tmp+move so the
rem panel never reads a half-written file. Values via delayed expansion so a
rem stray paren in a note cannot break this block - but an UNSET !var! stays
rem literal, hence the if defined guards.
if not defined STATE goto :eof
> "%STATE%.tmp" (
    echo title=!UITITLE!
    if defined MAKE (echo machine=!MAKE! / !MODEL!) else echo machine=
    if defined SERIAL (echo serial=!SERIAL!) else echo serial=
    if defined UINOTE (echo note=!UINOTE!) else echo note=
    if defined APPLYBYTES (echo applybytes=!APPLYBYTES!) else echo applybytes=
    for /l %%i in (1,1,%STGCOUNT%) do echo stage%%i=!ST%%i!~!STG%%i!
)
move /y "%STATE%.tmp" "%STATE%" >nul 2>&1
goto :eof

:ui_takeover
rem Hide the console only once the panel is provably alive. Aliveness is the
rem deploy.panel.alive file the panel writes AFTER its window exists - never
rem a process probe: `tasklist | find` here reset the machine on every boot
rem that reached it (WinPE auto-restarts on bugcheck, so it looked like a
rem silent reboot loop - the whole 2026-08-25 crash hunt), and tasklist is
rem not in a stock boot.wim anyway. Runs to completion once; no-op after.
if defined UION goto :eof
if not defined UIEXE goto :eof
set /a TKWAIT=0
:ui_takeover_wait
if exist "X:\Windows\Temp\deploy.panel.alive" goto :ui_takeover_alive
set /a TKWAIT+=1
if !TKWAIT! GEQ 5 goto :ui_takeover_dead
ping -n 2 127.0.0.1 >nul
goto :ui_takeover_wait
:ui_takeover_alive
set "UION=1"
call :log "UI panel running - console hidden (fail path brings it back)."
if exist "%SYS%\wdk-bg.exe" start "" "%SYS%\wdk-bg.exe" --hide-console
goto :eof
:ui_takeover_dead
call :log "UI panel did not start - staying on the console."
set "UIEXE="
goto :eof

:confirm_wipe
rem Sets NOWIPE unless the operator confirms. Console asks for the typed WIPE;
rem the panel shows a Yes/No box instead: deploy.confirm.req out, .ack back.
set "NOWIPE="
if defined UION goto :confirm_wipe_ui
echo.
echo   About to ERASE DISK 0 on this machine and install %TS_NAME%.
echo   Type  WIPE  and press Enter to continue, or close this window to stop.
echo.
set "CONFIRM="
set /p CONFIRM=Confirm: 
if /i not "!CONFIRM!"=="WIPE" set "NOWIPE=1"
goto :eof
:confirm_wipe_ui
del /q "X:\Windows\Temp\deploy.confirm.ack" >nul 2>&1
> "X:\Windows\Temp\deploy.confirm.req" echo About to ERASE DISK 0 on this machine and install %TS_NAME%.
call :log "Waiting for on-screen confirmation..."
:confirm_wipe_wait
if not exist "X:\Windows\Temp\deploy.confirm.ack" (
    ping -n 2 127.0.0.1 >nul
    goto :confirm_wipe_wait
)
set "CONFIRM="
set /p CONFIRM=<"X:\Windows\Temp\deploy.confirm.ack"
del /q "X:\Windows\Temp\deploy.confirm.req" "X:\Windows\Temp\deploy.confirm.ack" >nul 2>&1
if /i not "!CONFIRM!"=="YES" set "NOWIPE=1"
goto :eof

:log
rem Timestamp every line - on screen, in the file, and in the push - so the panel and
rem a photo of the screen both show elapsed time without watching a wall clock
rem (Craig, 2026-08-23). %TIME% is HH:MM:SS.cc from WinPE.
set "TS=%TIME: =0%"
echo [deploy] %TS%  %~1
>> "%LOG%" echo %DATE% %TIME% %~1
if defined LOGHOST if defined CURL call :push "%TS%  %~1"
goto :eof

:push
rem One line per POST, JSON built by hand: quotes become apostrophes and
rem backslashes forward slashes, because cmd has no escaping and the panel
rem would rather see C:/x than a dropped line.
set "MSG=%~1"
set "MSG=%MSG:"='%"
set "MSG=%MSG:\=/%"
set "MSG=%MSG:{=(%"
set "MSG=%MSG:}=)%"
"%CURL%" -s -m 3 -o NUL -H "Content-Type: application/json" -d "{\"serial\":\"%SERIAL%\",\"make\":\"%MAKE%\",\"model\":\"%MODEL%\",\"session\":\"%SESSION%\",\"lines\":[\"%MSG%\"]}" "%LOGHOST%/imaging-log/ingest" >nul 2>&1
goto :eof

:drivers_found
call :log "Driver pack: %DRIVERDIR%"
call :stage_drivers
goto :eof

:drivers_missing
call :log "No driver pack for this machine on the share (Z:\Drivers\%MAKE%\%MODEL%) - continuing without."
if exist "Z:\Drivers\%MAKE%\" goto :drivers_missing_list
call :log "  Z:\Drivers\ has no %MAKE% folder - create Z:\Drivers\%MAKE%\%MODEL%\ and drop the INF tree or pack in it."
goto :drivers_missing_vm
:drivers_missing_list
for /d %%M in ("Z:\Drivers\!MAKE!\*") do call :log "  Z:\Drivers\!MAKE!\ has: %%~nxM"
:drivers_missing_vm
if /i "%MAKE%"=="Proxmox" call :log "  Without vioscsi/viostor this VM has an emulated disk - the apply will be slow."
if /i "%MAKE%"=="QEMU" call :log "  Without vioscsi/viostor this VM has an emulated disk - the apply will be slow."
goto :eof

:find_drivers
rem Z:\Drivers\<Make>\<Model> by exact name, then model starts-with folder
rem (Lenovo: product 21F5001AAU, folder 21F), then folder contained in product
rem (Acer: product "TravelMate P414-52", folder the same). Then aliases.txt
rem (alias=Make\Folder, exact), then _default. First hit wins.
set "DRIVERDIR="
if exist "Z:\Drivers\%MAKE%\%MODEL%\" set "DRIVERDIR=Z:\Drivers\%MAKE%\%MODEL%" & goto :eof
for /d %%V in ("Z:\Drivers\*") do (
    for /d %%M in ("%%~fV\*") do (
        if not defined DRIVERDIR (
            set "F=%%~nxM"
            if /i "!MODEL:~0,4!"=="!F:~0,4!" if "!F:~4,1!"=="" set "DRIVERDIR=%%~fM"
            if not defined DRIVERDIR if not "!MODEL:%%~nxM=!"=="!MODEL!" set "DRIVERDIR=%%~fM"
        )
    )
)
if defined DRIVERDIR goto :eof
if exist "Z:\Drivers\aliases.txt" (
    for /f "usebackq tokens=1,* delims==" %%K in ("Z:\Drivers\aliases.txt") do (
        if not defined DRIVERDIR if /i "%%K"=="!MODEL!" if exist "Z:\Drivers\%%L\" set "DRIVERDIR=Z:\Drivers\%%L"
    )
)
if defined DRIVERDIR goto :eof
if exist "Z:\Drivers\_default\" (
    dir /b /s "Z:\Drivers\_default\*.inf" "Z:\Drivers\_default\*.cab" "Z:\Drivers\_default\*.exe" "Z:\Drivers\_default\*.zip" "Z:\Drivers\_default\*.7z" >nul 2>&1 && set "DRIVERDIR=Z:\Drivers\_default"
)
goto :eof

:drvload_storage
rem drvload the storage INFs from the staged tree into THIS WinPE so diskpart can
rem see a VirtIO disk. The virtio-win tree ships w10/w11/2k25 and ARM64 variants
rem side by side; WinPE here is x64, so only paths under an amd64 folder are used.
rem Loading the same driver twice is harmless; a wrong one just fails quietly.
for /r "%DRIVERSTAGE%" %%I in (vioscsi.inf viostor.inf) do (
    if exist "%%~fI" (
        set "P=%%~fI"
        if /i not "!P:\amd64\=!"=="!P!" (
            call :log "drvload %%~nxI (WinPE storage) from %%~dpI"
            drvload "%%~fI" >> "%LOG%" 2>&1
        )
    )
)
goto :eof

:stage_drivers
rem An INF tree is used in place. An archive is expanded to X:\Drivers: .cab with
rem expand.exe (always there), anything else with 7z.exe (injected) - without 7z
rem a .exe/.zip/.7z pack is reported and skipped, never half-applied.
set "DRIVERSTAGE="
rem Loose INFs (a virtio-win tree dropped straight in, as in Proxmox\vm) are used
rem in place - no pack needed. `A && B & C` would run C unconditionally, so this
rem is an if block, not a one-liner.
dir /b /s "!DRIVERDIR!\*.inf" >nul 2>&1
if errorlevel 1 goto :stage_drivers_pack
set "DRIVERSTAGE=%DRIVERDIR%"
call :log "INF tree in place (%DRIVERDIR%)"
goto :eof
:stage_drivers_pack
set "PACK="
for %%E in (cab exe zip 7z) do (
    if not defined PACK for %%P in ("!DRIVERDIR!\*.%%E") do if not defined PACK set "PACK=%%~fP"
)
if not defined PACK (
    call :log "WARNING: !DRIVERDIR! has no INF and no archive - skipped."
    goto :eof
)
set "STAGE=X:\Drivers\pack"
if exist "%STAGE%" rd /s /q "%STAGE%" >nul 2>&1
md "%STAGE%" >nul 2>&1
call :log "Expanding %PACK%"
if /i "!PACK:~-4!"==".cab" (
    expand.exe -F:* "!PACK!" "%STAGE%" >> "%LOG%" 2>&1
) else (
    if not defined SEVENZIP (
        call :log "WARNING: !PACK! needs 7z.exe, which was not injected - drivers skipped."
        goto :eof
    )
    "%SEVENZIP%" x -y -o"%STAGE%" "!PACK!" >> "%LOG%" 2>&1
)
dir /b /s "%STAGE%\*.inf" >nul 2>&1 && set "DRIVERSTAGE=%STAGE%"
if not defined DRIVERSTAGE call :log "WARNING: %PACK% expanded to no INF files - drivers skipped."
goto :eof

:fail
call :ui_fail "%~1"
echo.
echo [deploy] STOPPED: %~1
>> "%LOG%" echo %DATE% %TIME% STOPPED: %~1
echo.
goto :eof

:shell
call :heartbeat_stop
rem An operator cannot type into a hidden window - and on a small screen the
rem topmost panel would sit over the prompt, so both are undone here.
if defined UION (
    if exist "%SYS%\wdk-bg.exe" start "" "%SYS%\wdk-bg.exe" --show-console
    taskkill /f /im wdk-panel.exe >nul 2>&1
    set "UION="
)
echo [deploy] Log: %LOG%
echo [deploy] Dropping to a command prompt.
cmd.exe

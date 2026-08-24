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

set "LOG=X:\Windows\Temp\deploy.log"
if not exist "X:\Windows\Temp" md "X:\Windows\Temp" >nul 2>&1
set "SYS=%SystemRoot%\System32"

rem --- screen -------------------------------------------------------------
rem  A console UI, not an HTA: mshta.exe and mshtml.dll are NOT in a stock
rem  boot.wim (WinPE-HTA is an ADK optional component), while cmd and conhost
rem  always are - so the same "nothing but stock WinPE" rule that shaped the
rem  client shapes its UI (checked against Server 2025 boot.wim, 2026-08-23).
call :ui_init

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
        call :log "Connecting %UNC% (attempt %%A of 5)"
        if defined DUSER (
            net use Z: "%UNC%" /user:"%DUSER%" "%DPASS%" <nul >"%SYS%\netuse.txt" 2>&1
        ) else (
            net use Z: "%UNC%" <nul >"%SYS%\netuse.txt" 2>&1
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
    call :fail "Could not connect %UNC% after 5 tries - see the net use lines above and check the share in the Netboot panel."
    goto :shell
)

rem --- self-heal tools from the share --------------------------------------
rem  Secure Boot clients cannot take unsigned PE files (7z, curl) as initrd -
rem  iPXE prints "Verification failed: Security Policy Violation" and skips
rem  them (seen live 2026-08-24). The share has the same four files under
rem  Z:\Tools, and SMB has no such rule, so pick up whatever is missing here.
rem  Harmless everywhere else: if initrd delivered them, this copies nothing.
for %%T in (7z.exe 7za.dll 7zxa.dll curl.exe) do (
    if not exist "%SYS%\%%T" if exist "Z:\Tools\%%T" (
        copy /y "Z:\Tools\%%T" "%SYS%\%%T" >nul 2>&1
        if exist "%SYS%\%%T" call :log "Fetched %%T from the share (Secure Boot boot path)"
    )
)
if not defined CURL if exist "%SYS%\curl.exe" set "CURL=%SYS%\curl.exe"
if defined LOGHOST if defined CURL call :heartbeat_start

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
    call :fail "Task sequence '%TSID%' is not published - Save and publish it in the Netboot panel."
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
    call :fail "Task sequence '%TSID%' has no Windows image - pick one in the Netboot panel."
    goto :shell
)
if not defined TS_INDEX set "TS_INDEX=1"
set "WIMPATH=Z:\%TS_IMAGE%"
if not exist "%WIMPATH%" (
    call :fail "Image not on the share: %WIMPATH% - is the ISO still in the library?"
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
if defined DRIVERDIR (
    call :log "Driver pack: %DRIVERDIR%"
    call :stage_drivers
    if defined DRIVERSTAGE call :drvload_storage
) else (
    call :log "No driver pack for this machine on the share (Z:\Drivers\%MAKE%\%MODEL%) - continuing without."
    if exist "Z:\Drivers\%MAKE%\" (
        for /d %%M in ("Z:\Drivers\%MAKE%\*") do call :log "  Z:\Drivers\%MAKE%\ has: %%~nxM"
    ) else (
        call :log "  Z:\Drivers\ has no %MAKE% folder - create Z:\Drivers\%MAKE%\%MODEL%\ and drop the INF tree or pack in it."
    )
    if /i "%MAKE%"=="Proxmox" call :log "  Without vioscsi/viostor this VM has an emulated disk - the apply will be slow."
    if /i "%MAKE%"=="QEMU" call :log "  Without vioscsi/viostor this VM has an emulated disk - the apply will be slow."
)

rem --- target volume --------------------------------------------------------
rem  Reuse a prepared W: if it is already there; otherwise repartition disk 0 -
rem  and ONLY without asking when the panel published deploy.autoprep.
set "APPLYDIR="
if exist "W:\" set "APPLYDIR=W:\"
if not defined APPLYDIR (
    if exist "%SYS%\deploy.autoprep" set "TS_AUTOPREP=1"
    if not "%TS_AUTOPREP%"=="1" (
        echo.
        echo   About to ERASE DISK 0 on this machine and install %TS_NAME%.
        echo   Type  WIPE  and press Enter to continue, or close this window to stop.
        echo.
        set "CONFIRM="
        set /p CONFIRM=Confirm: 
        if /i not "!CONFIRM!"=="WIPE" (
            call :fail "Not confirmed - nothing was changed."
            goto :shell
        )
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
call :log "Applying image - DISM prints no lines while it runs; the panel shows a heartbeat until it finishes."

rem --- apply ----------------------------------------------------------------
call :ui_stage 7 run
call :ui_note "Applying the image - DISM shows its own progress below."
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
        copy /y "Z:\TaskSequences\%TSID%.firstboot.cmd" "%SCR%\%TSID%.firstboot.cmd" >nul
        >>"%SETUPCOMPLETE%" echo if exist "%%~dp0%TSID%.firstboot.cmd" call "%%~dp0%TSID%.firstboot.cmd"
        call :log "First-boot steps staged (%TSID%.firstboot.cmd -> Setup\Scripts)"
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
> "%HBCMD%" (
    echo @echo off
    echo :loop
    echo if not exist "%HBFLAG%" exit
    echo "%CURL%" -s -m 3 -o NUL -H "Content-Type: application/json" -d "{\"serial\":\"%SERIAL%\",\"make\":\"%MAKE%\",\"model\":\"%MODEL%\",\"session\":\"%SESSION%\",\"heartbeat\":true,\"lines\":[]}" "%LOGHOST%/imaging-log/ingest" ^>nul 2^>^&1
    echo ping -n 31 127.0.0.1 ^>nul
    echo goto :loop
)
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
goto :eof

:ui_row
call set "_n=%%STG%~1%%"
call set "_s=%%ST%~1%%"
echo    [!_s!] !_n!
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
        if not defined DRIVERDIR if /i "%%K"=="%MODEL%" if exist "Z:\Drivers\%%L\" set "DRIVERDIR=Z:\Drivers\%%L"
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
dir /b /s "%DRIVERDIR%\*.inf" >nul 2>&1
if not errorlevel 1 (
    set "DRIVERSTAGE=%DRIVERDIR%"
    call :log "INF tree in place (%DRIVERDIR%)"
    goto :eof
)
set "PACK="
for %%E in (cab exe zip 7z) do (
    if not defined PACK for %%P in ("%DRIVERDIR%\*.%%E") do if not defined PACK set "PACK=%%~fP"
)
if not defined PACK (
    call :log "WARNING: %DRIVERDIR% has no INF and no archive - skipped."
    goto :eof
)
set "STAGE=X:\Drivers\pack"
if exist "%STAGE%" rd /s /q "%STAGE%" >nul 2>&1
md "%STAGE%" >nul 2>&1
call :log "Expanding %PACK%"
if /i "%PACK:~-4%"==".cab" (
    expand.exe -F:* "%PACK%" "%STAGE%" >> "%LOG%" 2>&1
) else (
    if not defined SEVENZIP (
        call :log "WARNING: %PACK% needs 7z.exe, which was not injected - drivers skipped."
        goto :eof
    )
    "%SEVENZIP%" x -y -o"%STAGE%" "%PACK%" >> "%LOG%" 2>&1
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
echo [deploy] Log: %LOG%
echo [deploy] Dropping to a command prompt.
cmd.exe

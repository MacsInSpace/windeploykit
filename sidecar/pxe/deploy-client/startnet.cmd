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

rem --- who we are (no wmic, no PowerShell: SMBIOS strings live in the registry) ---
set "MAKE="
set "MODEL="
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| find "REG_SZ"') do set "MAKE=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemProductName 2^>nul ^| find "REG_SZ"') do set "MODEL=%%B"
if not defined MAKE set "MAKE=Unknown"
if not defined MODEL set "MODEL=Unknown"

call :log "=== WinDeployKit deploy client ==="
call :log "Machine: %MAKE% / %MODEL%"
call :log "Starting network (wpeinit)..."
wpeinit

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

call :log "Connecting %UNC%"
net use Z: >nul 2>&1 && net use Z: /delete /y >nul 2>&1
if defined DUSER (
    net use Z: "%UNC%" /user:"%DUSER%" "%DPASS%" >nul 2>&1
) else (
    net use Z: "%UNC%" >nul 2>&1
)
if errorlevel 1 (
    call :fail "Could not connect %UNC% - check the share credentials in the Netboot panel."
    goto :shell
)

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
for /f "usebackq tokens=1,* delims==" %%K in ("Z:\TaskSequences\%TSID%.env") do (
    if /i "%%K"=="TS_NAME"     set "TS_NAME=%%L"
    if /i "%%K"=="TS_IMAGE"    set "TS_IMAGE=%%L"
    if /i "%%K"=="TS_INDEX"    set "TS_INDEX=%%L"
    if /i "%%K"=="TS_UNATTEND" set "TS_UNATTEND=%%L"
    if /i "%%K"=="TS_AUTOPREP" set "TS_AUTOPREP=%%L"
)
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
call :log "Image: %WIMPATH% (index %TS_INDEX%)"

rem --- WinPE-side drivers: the disk has to exist before diskpart can see it ---
rem  Storage INFs from the matched pack are loaded into THIS WinPE (drvload).
rem  Proxmox/VirtIO is the case that matters; on bare metal this is a no-op.
set "SEVENZIP="
if exist "%SYS%\7z.exe" set "SEVENZIP=%SYS%\7z.exe"
set "DRIVERDIR="
call :find_drivers
if defined DRIVERDIR (
    call :log "Driver pack: %DRIVERDIR%"
    call :stage_drivers
    if defined DRIVERSTAGE call :load_storage_drivers
) else (
    call :log "No driver pack for this machine on the share (Z:\Drivers\%MAKE%\%MODEL%) - continuing without."
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
call :log "Applying to %APPLYDIR%"

rem --- apply ----------------------------------------------------------------
dism /Apply-Image /ImageFile:"%WIMPATH%" /Index:%TS_INDEX% /ApplyDir:%APPLYDIR%
if errorlevel 1 (
    call :fail "DISM /Apply-Image failed - see the DISM output above."
    goto :shell
)
call :log "DISM apply complete."

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

copy /y "%LOG%" "%APPLYDIR%Windows\Temp\windeploykit-deploy.log" >nul 2>&1
call :log "Done - rebooting into Windows."
net use Z: /delete /y >nul 2>&1
wpeutil reboot
goto :eof

:log
echo [deploy] %~1
>> "%LOG%" echo %DATE% %TIME% %~1
if defined LOGHOST if defined CURL call :push "%~1"
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

:load_storage_drivers
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
echo.
echo [deploy] STOPPED: %~1
>> "%LOG%" echo %DATE% %TIME% STOPPED: %~1
echo.
goto :eof

:shell
echo [deploy] Log: %LOG%
echo [deploy] Dropping to a command prompt.
cmd.exe

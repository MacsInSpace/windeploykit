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
rem  Reads three files that iPXE drops into System32 at boot (see the
rem  'deploy-client' overlay profile):
rem     deploy.unc      \\host\Deploy$
rem     deploy.cred     line 1 user, line 2 password
rem     deploy.autoprep present = may repartition disk 0 without asking
rem  and one published file per task sequence on the share:
rem     Z:\TaskSequences\_default.txt   the sequence id to run
rem     Z:\TaskSequences\<id>.env       KEY=VALUE, written by the panel
rem
rem  Anything missing drops to the WinPE prompt with the reason on screen -
rem  never a silent reboot loop.
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "LOG=X:\Windows\Temp\deploy.log"
if not exist "X:\Windows\Temp" md "X:\Windows\Temp" >nul 2>&1

call :log "=== WinDeployKit deploy client ==="
call :log "Starting network (wpeinit)..."
wpeinit

set "SYS=%SystemRoot%\System32"
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

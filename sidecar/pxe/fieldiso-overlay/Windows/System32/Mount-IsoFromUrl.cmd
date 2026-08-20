@echo off
setlocal EnableExtensions

rem FieldIso WinPE stub - downloads bootstrap PowerShell over HTTP (Caddy).
rem fieldiso.mode=smb-test -> run-smb-test.ps1 (lab SMB); else -> run.ps1 (imaging).
rem Must stay running until cmd exits - winpeshl reboots WinPE when this script returns.

call wpeinit

set "HTTPBASE="
if exist "%SystemRoot%\System32\fieldiso.url" (
  set /p HTTPBASE=<"%SystemRoot%\System32\fieldiso.url"
)

if not defined HTTPBASE (
  echo [FieldIso] No fieldiso.url - Start field PXE to regenerate menus.
  goto :shell
)

set "BOOTMODE=imaging"
if exist "%SystemRoot%\System32\fieldiso.mode" (
  set /p BOOTMODE=<"%SystemRoot%\System32\fieldiso.mode"
)
set "BOOTMODE=%BOOTMODE: =%"

if /i "%BOOTMODE%"=="smb-test" (
  set "RUNSCRIPT=run-smb-test.ps1"
  set "RUNHTTP=fieldiso/run-smb-test.ps1"
  echo [FieldIso] SMB lab mode - %HTTPBASE%/%RUNHTTP%
  rem Lab only: load throwaway SMB credential for the authenticated mount test.
  if exist "%SystemRoot%\System32\smb-test.cred" (
    echo [FieldIso] Loading SMB lab credential ^(smb-test.cred^)...
    call :LoadSmbCred "%SystemRoot%\System32\smb-test.cred"
    if defined FIELDISO_SMB_USER echo [FieldIso] SMB user: %FIELDISO_SMB_USER% ^(password hidden^)
  )
) else (
  set "RUNSCRIPT=run.ps1"
  set "RUNHTTP=fieldiso/run.ps1"
  echo [FieldIso] Imaging mode - %HTTPBASE%/%RUNHTTP%
)

rem wpeinit returns before DHCP/Wi-Fi is always ready - wait before first HTTP attempt
call :WaitForNetwork "%HTTPBASE%"

set "WORKDIR=%SystemRoot%\Temp\fieldiso"
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
set "TOOLS=%WORKDIR%\tools"
if not exist "%TOOLS%" mkdir "%TOOLS%"

set "RUNPS1=%WORKDIR%\%RUNSCRIPT%"
set "CERTUTIL=%SystemRoot%\System32\certutil.exe"

rem curl: System32 (overlay inject), temp tools, or certutil bootstrap from HTTP
set "CURL=%SystemRoot%\System32\curl.exe"
if not exist "%CURL%" set "CURL=%TOOLS%\curl.exe"
if not exist "%CURL%" if exist "%CERTUTIL%" (
  echo [FieldIso] Downloading curl.exe from fieldiso/tools...
  "%CERTUTIL%" -urlcache -split -f "%HTTPBASE%/fieldiso/tools/curl.exe" "%TOOLS%\curl.exe" >nul 2>&1
  if exist "%TOOLS%\curl.exe" set "CURL=%TOOLS%\curl.exe"
)

if exist "%CURL%" (
  call :DownloadBootstrap "%CURL%"
) else if exist "%CERTUTIL%" (
  echo [FieldIso] Downloading %RUNSCRIPT% via certutil...
  "%CERTUTIL%" -urlcache -split -f "%HTTPBASE%/%RUNHTTP%" "%RUNPS1%" >nul 2>&1
) else (
  echo [FieldIso] No curl.exe or certutil - cannot download %RUNSCRIPT%
  goto :shell
)

if not exist "%RUNPS1%" (
  echo [FieldIso] Failed to download %RUNSCRIPT% - check Caddy HTTP on %HTTPBASE%
  goto :shell
)

rem PowerShell is not on PATH in WinPE - use full path (WinPE-PowerShell optional component)
set "PS="
for %%P in (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
  "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
) do if exist %%P set "PS=%%~P"
if not defined PS (
  echo [FieldIso] PowerShell missing from WinPE - add WinPE-PowerShell to FieldIso.wim
  echo           ^(see sidecar/pxe/fieldiso/wim-inject/README.txt^)
  goto :shell
)

if not exist "%SystemRoot%\System32\mscoree.dll" (
  echo [FieldIso] mscoree.dll missing - WinPE-PowerShell inject incomplete
  echo           powershell.exe is present but the .NET engine was not exported
  echo           Re-run prepare-fieldiso-wim-inject.ps1 on Windows, copy wim-inject, re-inject
  goto :shell
)

echo [FieldIso] Running %RUNSCRIPT% (live output)...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%RUNPS1%"
if errorlevel 1 (
  echo [FieldIso] %RUNSCRIPT% exited with errors - see messages above.
)

:shell
rem Do NOT use "start cmd" - winpeshl exits when this batch ends and WinPE reboots.
echo.
echo ============================================
echo [FieldIso] Bootstrap finished - leave this window OPEN.
echo WinPE reboots if this cmd session exits ^(no key prompt - accidental exit causes PXE loop^).
echo Type commands below; only type exit when you want to reboot.
echo ============================================
echo.
cmd /k
echo.
echo [FieldIso] Cmd session closed - holding WinPE open. Type exit again to reboot.
:hold
call :SleepSeconds 60
goto :hold
endlocal
exit /b 0

:LoadSmbCred
rem Reads line 1 = username, line 2 = password into env (no delayed expansion;
rem set /p keeps special chars literal). Vars persist after call (no setlocal here).
set "FIELDISO_SMB_USER="
set "FIELDISO_SMB_PASS="
<"%~1" (
  set /p FIELDISO_SMB_USER=
  set /p FIELDISO_SMB_PASS=
)
exit /b 0

:SleepSeconds
rem WinPE often lacks timeout.exe - use ping to localhost for delays
set "SEC=%~1"
if not defined SEC set "SEC=2"
set /a PINGN=%SEC%+1
ping -n %PINGN% 127.0.0.1 >nul 2>&1
exit /b 0

:WaitForNetwork
set "BASE=%~1"
set "HOST=%BASE:http://=%"
set "HOST=%HOST:https://=%"
for /f "delims=:/" %%H in ("%HOST%") do set "PINGHOST=%%H"
if not defined PINGHOST exit /b 0
echo [FieldIso] Waiting for network (ping %PINGHOST%, up to ~60s)...
set /a NETTRY=0
:waitnet_loop
ping -n 1 -w 1000 %PINGHOST% >nul 2>&1
if not errorlevel 1 (
  echo [FieldIso] Network reachable.
  exit /b 0
)
set /a NETTRY+=1
if %NETTRY% geq 30 (
  echo [FieldIso] Network wait timed out - will retry download anyway.
  exit /b 1
)
call :SleepSeconds 2
goto :waitnet_loop

:DownloadBootstrap
set "CURL_EXE=%~1"
set /a DLTRY=0
:dl_loop
set /a DLTRY+=1
"%CURL_EXE%" -fL -o "%RUNPS1%" "%HTTPBASE%/%RUNHTTP%"
if not errorlevel 1 exit /b 0
if %DLTRY% geq 10 (
  echo [FieldIso] curl failed after %DLTRY% attempts.
  exit /b 1
)
echo [FieldIso] Download attempt %DLTRY% failed, retrying in 3s...
call :SleepSeconds 3
goto :dl_loop

# Session notes - 2026-08-24 (paused, Craig heading home)

## Where we are: fixing the Hyper-V Gen2 (Secure Boot) PXE boot failure

Craig booted a real VM (0450SHV01, Fitzroy PS Hyper-V) against WDK Netboot at 14:35.
Screenshot showed two distinct failures:

1. **`deploy/deploy.cred ... Not found` -> `Could not boot`.** He had switched the
   deploy credential mode to blank at 14:34:46, which (correctly) deletes deploy.cred -
   but the boot.ipxe menu still listed it as an initrd item, and iPXE treats a missing
   listed initrd as FATAL. Stale menu + fatal-by-default = dead boot.
2. **`Verification failed: Security Policy Violation` on 7z.exe / 7za.dll / 7zxa.dll /
   curl.exe.** Secure Boot shim path: shim-verified iPXE refuses UNSIGNED PE binaries
   as initrd items. Text files (startnet.cmd, deploy.unc, winpe.jpg) pass; unsigned
   EXE/DLL never will. 7-Zip and curl builds we bundle are not Authenticode-signed.

## Fixes made - UNCOMMITTED in the WDK working tree, parse-ok, NOT yet live-verified

`git status` in /Volumes/Data/projects/windeploykit shows the two modified files.

1. **sidecar/lib/PxeBootPlugin.ps1** (two edits):
   - `Get-AppPxeBootWimOverlayInitrdLines`: optional (Required=$false) overlay entries
     now emit `initrd ... ||` - iPXE's ignore-failure idiom. A 404 (cred deleted after
     menu write) or a Secure Boot verification refusal can no longer abort the boot.
     Required entries stay fatal.
   - `Write-AppPxeBootDeployOverlayFiles`: after publishing tools to http/deploy, also
     publishes the same four tools to `<image library root>/Tools` (i.e. Z:\Tools on
     the Deploy$ share), honouring Test-AppPxeBootDeployClientInjectEnabled, copy-once
     by size+mtime.
2. **sidecar/pxe/deploy-client/startnet.cmd**: new "self-heal tools from the share"
   block inserted right after the `net use Z:` retry loop succeeds (before the
   task-sequence selection). For each of 7z.exe/7za.dll/7zxa.dll/curl.exe: if missing
   from %SYS% and present at Z:\Tools\, copy it in. Re-sets CURL if it just arrived and
   starts the heartbeat (`if defined LOGHOST if defined CURL call :heartbeat_start`).

## Open items, in order

1. **Verify :heartbeat_start is idempotent.** It can now be called twice: once early
   (line ~75, when curl came via initrd) and once after the self-heal (line ~139). If
   it spawns a second background cmd, guard it (`if defined HEARTBEAT_ON goto :eof`
   style). NOT yet checked - read :heartbeat_start at line ~360.
2. **Live-verify the sidecar side**: run a sidecar, Start services (or just call
   Write-AppPxeBootMenuFiles + Write-AppPxeBootDeployOverlayFiles via a harness), then
   check: (a) boot.ipxe optional initrd lines end with ` ||`; (b) ~/Public/windeploykit/Tools
   exists with the four files; (c) blank cred mode leaves no deploy.cred AND the menu
   still boots (the || makes the stale-menu window harmless too).
3. **Craig re-tests the VM boot** (Secure Boot Gen2). Expect: verification failures
   still print for the four PE files but boot continues; WinPE runs startnet; the log
   shows "Fetched 7z.exe from the share (Secure Boot boot path)" etc.; drivers and log
   push work. Alternative worth mentioning to Craig: Hyper-V "Microsoft UEFI
   Certificate Authority" template or Secure Boot off for imaging VMs also sidesteps
   it, but the fix should stand on its own.
4. **Line endings**: startnet.cmd in-repo is LF-only (checked HEAD: `@echo off\n`) and
   has booted fine that way in his earlier tests; my inserted block is normalised to LF
   to match. Do NOT convert the file to CRLF wholesale without testing a real boot.
5. **USM parity**: USM shares `Get-AppPxeBootWimOverlayInitrdLines` (its overlay is
   ImageDeployer, plus FieldIso smb-test lines around 1290-1315 in its PxeBootPlugin).
   Port the `||` optional-initrd fix to USM once verified in WDK. USM does NOT have the
   cmd deploy client (deferred by Craig), so the share-Tools/self-heal parts do not
   port as-is. USM is PROD - Craig: "USM is the one we cant break."
6. Commit WDK (one commit: menu tolerance + share tools + self-heal), then the USM
   port as its own commit.

## Also unresolved from earlier today (lower priority)
- `SetPxeBootPluginConfig +11139ms SLOW` in his log (14:34:57): the SMB re-provision
  ran on a config save. The smb-share-verified.json fast path has a 7-day expiry and
  re-verifies on shape change - a cred-mode flip changes the shape, so this is
  mostly expected; look only if it recurs on unrelated saves.
- USM `scripts/test-school-group-ldap.ps1` (+ student twin) never loads
  AppSharedSecretVault.ps1 - pre-existing, fails only in its teardown path.
- PSOpenAD-FE: measurement-only changes shipped; if its new sidecar.log ever shows
  SLOW, it needs the stdin-pump loop reshape (~40 lines) before jobs can move off
  the dispatch thread.

## What already shipped today (all pushed)
- WDK: fe2cc19 param()-first fix (ISO import), ddc4b66 perf (Get-Command tax, warm-up,
  log file), 0f82b56 generic background job runner + StartPxeBootServices off the
  dispatch thread, 96e9ee7 TFTP badge adoption via pid file, 170e0bd/80932d4 shape
  gate + cab tool fix, da55596 vault dialog feedback + autologon count 0-5.
- USM: cc7febae param()-first + guard-sweep repairs (site-build reverted to plain
  Get-Command), 008bde99 perf, da0a8d32 job runner, 85fef6b8 TFTP badge adoption,
  0f0c33de StrictMode shape pass (Mount .borrowed in finally was the big one),
  66a78492 shape gate, bab590b5 autologon count.
- PSOpenAD-FE: ee609eb rolling sidecar.log + slow/SLOW markers.

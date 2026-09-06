# Agent notes - WinDeployKit

**Read this first.** It is the handover for a fresh session: what this project
is, where it came from, what is decided, what works, and what is booby-trapped.

**Last updated:** 2026-08-21

---

## 0. Orientation - read this before touching anything

| Fact | Value |
| --- | --- |
| Project root | `/Volumes/Data/projects/windeploykit` |
| GitHub | `MacsInSpace/windeploykit` (**private**). `main` is pushed and tracks `origin/main`; commit and push as you go |
| Git | on `main`; initial commit `75d3f25` landed 2026-08-21. Latest state: section 9 |
| Vault module | `MacsInSpace/SecretManagement.LocalVault` (private) - its own repo since 2026-08-22, vendored at tag `v1.0.2` |
| App data (macOS) | `~/Library/Application Support/windeploykit` (the product slug on every platform since 2026-08-22; was `WinDeployKit`) |
| Bundle id | `com.macsinspace.windeploykit` |
| Dev server | Vite on **42410** (HMR 42411) |
| Sidecar entry | `sidecar/windeploykit-sidecar.ps1` |

**The project has been renamed twice**: `psd-ui` -> `deploykit` -> `windeploykit`
(2026-08-21). If you find a stale `deploykit` or `psd-ui` reference anywhere,
it is a leftover - fix it. `~/Library/Application Support/DeployKit.old-name.bak`
is the pre-rename app data, kept until a full run is confirmed; delete it then.

### Two directories are local-only and gitignored

| Path | What it is | Rule |
| --- | --- | --- |
| `usm-reference/` | The originals this was extracted from, plus all porting notes | **Never push.** Contains internal hostnames and org detail |
| `PSD/` | A clone of FriendsOfMDT/PSD | Format reference only. Not part of this product |

`usm-reference/PORT_NOTES.md` is the long-form running log of every decision and
cut made during the extraction. This file is the summary; that file is the
detail. `usm-reference/IMPORT_MANIFEST.md` records exactly what was copied and
what was deliberately left behind.

### USM is READ-ONLY - and is now DOWNSTREAM of us

`/Volumes/Data/projects/usm` ("USM"; the checkout was `stmc-manager` until 2026-08-22) is the app this was extracted
from. It is **under active development by the user**.

> **Never modify, never `git checkout`, never `git stash` in that repo.**
> Copy out of it only. If you find a bug there, write it up in
> `docs/handover/HANDOVER_TO_USM_AGENT.md` - do not fix it in place.

**Direction changed 2026-08-21 (Craig):** WinDeployKit and PSOpenAD-FE are both
off on their own corporate dev paths, and **USM now takes from this project**,
not the other way round. WinDeployKit owns the netboot/downloads domain; USM
becomes the integrator that vendors it (the way it already vendors MDMKit).

Read-only still applies - "downstream" is about *ownership of the code*, not
permission to edit their tree.

### The three-repo relationship

| Repo | Relationship | Channel to us |
| --- | --- | --- |
| `stmc-manager` (USM) | **Downstream** for netboot/downloads; **upstream** for sidecar runtime core | `docs/handover/HANDOVER_TO_WINDEPLOYKIT_AGENT.md` (tracked, pushed) |
| `PSOpenAD-FE` | **Sibling** - shares the design system only, no code | `docs/handover/HANDOVER_TO_WINDEPLOYKIT_AGENT.md` (tracked) |
| `ipxeboot` | Build dependency for the Secure Boot iPXE chain | none - undeclared, see section 6 |

Outbound from us: **`docs/handover/HANDOVER_TO_USM_AGENT.md`** - tracked and
pushable, mirroring theirs. Append under a dated heading; never rewrite earlier
entries, so both sides can see what has already been carried.

> Moved there 2026-08-21 from `usm-reference/`, which is gitignored and so could
> never be pushed. `usm-reference/` keeps its actual job - reference material and
> internal detail that must never enter the tracked tree. **One historical entry
> stays behind** (2026-08-20, parameter-binding bugs): it quotes USM function and
> parameter names carrying internal domain detail. Already delivered and actioned,
> so nothing outstanding. Anything written for USM from now on goes in the tracked
> file - and must be scrubbed of internal identifiers before it does.

### The ownership boundary (settled 2026-08-21)

| Bucket | Owner | Contents |
| --- | --- | --- |
| **Domain** (~13) | **Us.** USM vendors from here | `PxeBoot*` x3, `Aria2*` x3, the five vendor catalogs, `VendorSccmCatalogRefresh`, `EvalIsoCatalog` |
| **Runtime core** (~9) | **USM.** We consume | `Ipc`, `AppPaths`, `AppPlatform`, `AppHttp`, `SidecarParams`, `AppPluginGates`, `AppLazyPlugins`, `LocalMachineCredentials`, `InfrastructureSshCredentials` |

**`AppNativeProcess.ps1` and `AppElevation.ps1` are runtime core - USM's**, even
though the refactor was done here and currently lives only here. Settled by call
graph: both straddle the boundary (`Start-AppNativeProcess` is called by our
`VendorSccmCatalogRefresh.ps1:168`; `AppElevation` is dot-sourced by our sidecar
entry and backs the elevated dnsmasq/TFTP shells), and the alternative would have
USM vendoring its own credential-prompt machinery back from a downstream project.

> **Do not edit either file here without sending the change to USM first.** USM is
> creating its own copies using our filenames and split so they stay
> byte-comparable. `AppHttp.ps1` is a deliberate 56-line stub of USM's 546 - that
> asymmetry is intentional, not drift.

### Identity injection - contract AGREED 2026-08-21, DONE 2026-08-22 (both halves)

The domain libs hardcode product identity, which is why a cross-repo diff is ~90%
noise and hid three real bugs for a day. The fix is one `$script:AppProductIdentity`
object set by the host sidecar before any lib is dot-sourced (same constraint as
`$script:AppSidecarProjectRoot`), fields `DisplayName` / `Slug` / `BinaryName` /
`UserAgentToken`, and the rule that **a domain lib contains no product literal at
all**. Our values: `WinDeployKit` / `windeploykit` / `windeploykit` /
`WinDeployKit/1.0`. Canonical text: USM's
`docs/handover/PRODUCT_IDENTITY_CONTRACT.md` (read-only; copy the grep from its
section 2, it is the drift check).

Our functional surface is **20 sites** (`AppPaths` x5, `Aria2Plugin` x3, one
User-Agent per vendor catalog, `Ipc` x1, `PxeBootTaskSequences` x1,
`Aria2PxeIntegration` x1); ~50 further mentions are prose, and the contract's grep
counts those too, so they go as well.

**Status 2026-08-22 evening - done on both sides, by one agent (Craig: "rather than run
between 2 agents").** `sidecar/product-identity.ps1` is the only file with product
literals; `lib/AppProductIdentity.ps1`, `lib/AppElevation.ps1`, `lib/AppNativeProcess.ps1`
are byte-identical to USM main; every lib passes the widened drift grep
(`Unofficial School Manager|School Manager|unofficial-school-manager|STMC|stmc|usm-|
WinDeployKit|windeploykit|DeployKit|DEPLOYKIT`). Wording at every shared site is the
same text as USM's (product name only where a technician sees it, "Netboot" in logs);
dev env overrides are `APP_ARIA2` / `APP_PXE_CADDY` / `APP_PXE_TFTPD64`; the
`Format-AppProcessArgumentList` sentinel is `__APP_DIRECT__`. The data root is the
SLUG on every platform (`windeploykit`, USM `usm`) - contract section 1. Commits
`7933b0b`, `79f6e26`. What is left in a diff against USM is functional: the site/school
genericisation, our `Get-AppSidecarJsonProp`, the `AppHttp` stub.

**Explicitly NOT shared: the frontend.** WinDeployKit is corporate - no themes,
no arcade, no personality. USM keeps all of that. Panels, theme system and
`index.css` diverge by design; the sharing boundary is the sidecar domain libs
only. Do not try to reconcile the UI.

---

## 0b. Building the macOS app

Do not work this out from scratch - it is written down.
[`docs/AGENT_NOTES_MACOS_BUILD.md`](docs/AGENT_NOTES_MACOS_BUILD.md) has the
build command, notarisation (it works, and needs no App Store Connect app
record), why stapling fails and why that is expected, bundling the sidecar so a
packaged build can find it, and a release checklist. Carried over from
PSOpenAD-FE where each item was tested against a real release rather than
assumed.

## 1. What this is

An extraction of the **Netboot** and **Downloads** plug-ins from a
school-IT-specific internal tool, made generic, to replace the retired Microsoft
Deployment Toolkit. See `README.md` for the product-facing story.

The extraction is done. What remains is finishing the UI and rewriting the WinPE
client.

**Generic-isation of the school-directory data model completed 2026-08-21.** The
netboot and downloads plug-ins were generic from the start, but the infrastructure
credential layer that came across with them still carried the upstream school model:
381 `school` references, 124 of them `schoolNumber`. All removed -

- `schoolNumber` -> **`siteId`** everywhere. The store already returned
  `siteProfile.siteId`, so this was naming, not behaviour. The `{{SN}}` task-sequence
  token is now **`{{SITE}}`**, matching what section 5 says Site Profile will supply.
- **Deleted** `app/src/lib/infrastructureSsh.ts` and `infrastructureProbeTypes.ts` -
  school network-gear management (core/edge switches, WLC, admin printers, an
  internal catalogue subnet). Every export was dead outside its own module, and none
  of it is Windows deployment.
- The credential vault seeded two org-issued accounts by naming convention. It now
  seeds **one generic site default** (`default-<site>-admin`), with no name or
  password implied. Both TS and sidecar sides moved together - they share the id
  shape, so they must not drift.
- Removed dead upstream subsystems that carried the vocabulary: the school-init
  bootstrap ladder in `Ipc.ps1` (nothing emitted any phase), the group-membership
  param parser in `SidecarParams.ps1` (no callers), and GPO command timeouts in
  `sidecar.rs` (no such handler exists here).
- Product-name and identity leaks fixed: `Unofficial-School-Manager` User-Agent,
  `SCHOOL_MANAGER_PXE_*` env vars, and "Reinstall School Manager" error strings.

The only remaining `school` in the tree is **"Jamf School"** - a real product name in
a cache description, correctly left alone.

> Two persisted keys changed shape, and the project's convention is a clean cut-over,
> no migration: the `download.schoolSubdir` setting id, and default credential ids
> (`default-0000-school-admin` -> `default-<site>-admin`). Existing local values are
> ignored rather than migrated.

---

## 2. Locked decisions - do not relitigate

1. **No ImageDeployer.** The upstream tool used a third-party WinPE client
   (Steven Edwards' ImageDeployer) with no licence grant. It is **excluded** from
   this repo. The WinPE client is being grown from `sidecar/pxe/fieldiso/run.ps1`
   (original code, delivered over HTTP at boot so it iterates without WIM
   rebuilds).
2. **Server-driven agent.** WinPE is headless: it polls the server for a
   per-device job, executes it, streams status back. The wizard lives in the
   desktop app. Chosen because it deletes the "render a UI inside WinPE" problem
   permanently, scales to a room full of machines, and keeps secrets server-side.
   A minimal text fallback stays in the client for degraded operation.
3. **Task sequences execute in three phases**, one step schema
   (`reg | cmd | pwsh | app...`) tagged by phase:
   - **A. WinPE agent** - disk prep, apply, driver install, plant unattend + runner
   - **B. specialize** - unattend `RunSynchronous` (the existing generator)
   - **C. first-boot runner** - planted by the agent, runs the rest in full
     Windows, reports to the same log endpoint, self-removes.
     *Phase C does not exist yet.* It is the highest-value missing piece - it is
     where the Applications layer will plug in.
4. **Boot images: any Windows ISO + wimlib overlay**, with a **build-match rule**
   - `sidecar/pxe/fieldiso/wim-inject/` carries SOFTWARE and COMPONENTS registry
   hives from a DISM-serviced base, so it is welded to its WinPE build family.
   One ADK export per build era. Prefer image **index 1** (bare WinPE), not
   index 2 (Setup).
5. **WinPE drivers: runtime-first.** iPXE downloads the WIM over its own UNDI
   stack so boot always completes; missing NIC/storage drivers only bite in the
   agent phase, where `drvload`/`pnputil` fixes them. Offline `DISM /Add-Driver`
   on Windows is the rare fallback. Keyboard/mouse drivers are mostly moot under
   the headless agent.
6. **Applications: deferred.** The user prototypes script-as-application
   upstream first, then ports it here. Direction: packaged PS1 scripts surfaced
   in a menu and run by the phase-C runner. **winget is not on Server 2022 or
   LTSC/IoT** (it is on Win11 and Server 2025), so scripts are the universal
   base and winget becomes an optional step type later.
7. **UI: MDT Deployment Workbench.** See section 4.
8. **Live data, not cached.** See `docs/DATA_FRESHNESS.md`.
9. **No plug-in registry, no theme packages.** Both were inherited and both were
   deleted. Every node always exists; there are exactly two colour modes.

---

## 3. Current state - what actually works

### Verified working (2026-08-21)

- `npm run tauri:dev` launches; Rust and frontend both build clean; `tsc --noEmit`
  is clean.
- **Until 2026-08-21 the app never started the sidecar.** The Rust host
  deliberately defers the spawn to a `sidecar_restart` call from JS (lib.rs);
  upstream's sign-in flow made that call, the extraction removed the flow, and
  nothing replaced it. Every panel starved behind `Sidecar is not running`,
  which Netboot reported as "No LAN IP". The claims below were verified over
  **stdio**, which is why they were true and the app was still empty. Fixed:
  `app/src/lib/sidecarBoot.ts` starts it at mount, pushes `ApplyRuntimeConfig`
  and the image-library root once it is ready, and shows a clickable
  `SIDECAR STOPPED - RESTART` badge when it is not. Verify in the **app**, not
  just over stdio, before claiming a panel works.
- Sidecar starts, and **all 10 panel commands return ok** (over stdio):
  `GetPxeBootPluginStatus`, `GetPxeBootPluginConfig`, `GetPxeBootWimLibrary`,
  `GetPxeBootTaskSequences`, `GetAria2TrackerCatalog`, `GetAria2PluginConfig`,
  `GetPxeBootImagingClients`, `GetPxeBootLogTail`, `GetEvalIsoCatalog`,
  `GetAria2Downloads`.
- LAN adapter detection works (`lanIp` resolves).
- Vendor driver catalogs load - **1,456 driver rows** from the bundled JSON.
- Console tree navigates; each node renders only its own sections; zero console
  errors in a headless browser check.

### Carried in from USM, 2026-08-21 (see `docs/handover/HANDOVER_TO_USM_AGENT.md`)

- **Lenovo catalog fix.** `$bestScore = -1` -> `[int]::MinValue` at three sites.
  Lenovo is the only *signed* scorer of the five (win10 = -100), so the old seed
  discarded every Win10-only model. Measured on the bundled 372-model catalog:
  **80 unmatched -> 0**. Acer and Dell use `-1` **correctly** and now carry a
  comment at the seed saying so - do not pattern-match them.
- **All-arch TFTP staging.** `Sync-AppPxeBootBundledArchTftpTrees` replaces the
  single-tree, hash-short-circuited Secure Boot sync. Never writes the TFTP root
  (our `snponly.efi` is the byte-patched build). Assets still missing - see section 6.
- **`.gitattributes` created** - we had none. A line-ending-normalised `.efi`
  fails Secure Boot with no useful error.
- **Gateway `catch { }`** in `Get-AppPxeBootNetworkAdapters` (line ~4639) now
  logs instead of discarding - the bug that cost the original "No LAN IP" hunt.

### Linux ISO boot, 2026-09-04 (branch `feature/linux-iso-boot`)

- A Debian installer ISO in the library is mounted read-only like Windows media,
  served whole at `/iso-mount/<token>/`, and the PXE menu gets one `lnx_<slug>`
  entry per ISO that boots the ISO's own kernel + initrd in place. No extraction,
  no copy - Craig's rule for every ISO.
- macOS cannot hdiutil-mount Debian hybrid ISOs ("no mountable file systems": the
  Apple partition map wins). `Mount-AppPxeBootIsoReadOnly` falls back to
  `hdiutil attach -nomount` + `mount -t cd9660`, unprivileged. Dismount must
  `umount` before `hdiutil detach`, else "Resource busy".
- Mount records carry `kind` (`windows` | `linux`), `mountRoot`, `livePath` and
  `linux` (layout, label, kernel/initrd rel paths, kernel args) - same keys for
  both kinds, StrictMode. Menu regen now runs AFTER the mount pass on Start and
  on Update Deployment Share, because the Linux entries are read off the mount map.
- Verified 2026-09-04 in QEMU (`scripts/test-linux-iso-boot-qemu.sh`,
  debian-13.6.0-amd64-netinst): kernel (12.1 MB) and gtk initrd (76.6 MB) fetched
  through Caddy, installer reached "Select a language".
- The netinst's own initrd is the CD-ROM flavour (cdrom-detect, no net-retriever,
  no NIC modules), so over PXE it stops at "detect and mount installation media".
  Same day: the mount pass fetches Debian's matching netboot initrd
  (`Ensure-AppPxeBootDebianNetbootInitrd`). Match = SHA256 of the ISO's kernel
  equals the mirror build's `netboot/.../linux` in SHA256SUMS (the kernel is the
  same file in both places); only that build's gtk `initrd.gz` (~80 MB) is
  downloaded, verified, into `http/linux/debian/<codename>-<arch>-<sha8>/`. The
  menu then boots the ISO's kernel + netboot initrd. **2026-09-06: the mirror is
  the Debian mirror on the internet, not the ISO tree** - a netinst omits the
  storage-driver udebs (`sata-modules`, `scsi-modules`...) the netboot initrd
  needs, so d-i saw no disk; Craig: "drop the premise, the ISOs are freely
  available and it is always up to date". Signed mirror, no
  `allow_unauthenticated`. Offline or unmatched -> ISO-only boot, and the
  menu + ISO list say so. QEMU `--install` tier (ISO-tree era): verified 2026-09-04 with debian-13.6.0-amd64-netinst: d-i accepted the served ISO tree as its mirror (dists/trixie Release + debian-installer Packages.gz), then fetched its udebs from pool/ on the mounted ISO through Caddy.
- **ISO-less Debian (2026-09-06).** Since the mirror supplies everything, a
  Debian install needs only the netboot kernel + initrd. Operating Systems >
  "Linux network installers" (catalog `$script:AppPxeBootDebianNetbootCatalog`:
  trixie/bookworm x amd64/arm64) - Add fetches the mirror's `current` gtk pair
  into `http/linux/debian/<codename>-<arch>/` with a `manifest.json`
  (`Add-AppPxeBootDebianNetboot`, SHA256SUMS-verified, dated d-i build name
  recorded), Remove deletes the directory; both regenerate the menu.
  `Get-AppPxeBootDebianNetbootPairs` enumerates complete pairs (live directory
  state), `ConvertTo-AppPxeBootDebianNetbootInventoryRow` turns one into a menu
  row with the same keys as an ISO row, so the submenu applies unchanged.
  Rust `sidecar.rs` gives `AddPxeBootLinuxNetboot` a 1800 s timeout.
- The preseed builder now forces UEFI (`partman-efi/non_efi_system boolean
  true`): d-i otherwise stops to ask when another OS in BIOS mode sits on any
  disk (the QEMU run's iPXE boot disk did it). It also accepts trixie's new
  recipe names `server` and `small_disk`. **trixie's `atomic` recipe needs about
  10 GB** (768 MB EFI + 768 MB /boot + 8 GB / + swap); a smaller disk fails with
  "Unable to satisfy all constraints on the partition" - that is what
  `small_disk` is for. The QEMU test disk is 16 GB for that reason.
- **Panel, 2026-09-06 (Craig's review of the first Debian sequence):** the platform
  decides what the editor shows. A Debian sequence no longer offers Role, Windows
  image, Join a domain, Win 11 requirements, OOBE screens, After first-boot setup
  or the Windows local account (its first-user fields are the account), and its
  first-boot steps offer only `+ Command` (late_command runs shell; reg/pwsh are
  Windows verbs the builder skips). Win 11 requirements also hide for the Windows
  Server role. Debian fields with a right answer set are dropdowns
  (`TS_DEBIAN_FIELD_OPTIONS`: locale, keyboard, time zone, partitioning recipe,
  target disk presets) - a saved value outside the list still shows as
  "(custom)". "Windows image" becomes **Linux installer** on a Debian sequence:
  the catalog from Operating Systems > Linux network installers, saved in field
  `linuxInstaller` as `debian-<codename>-<arch>` or '' for any. The menu honours
  it: a bound sequence appears only under that release's entry
  (`Get-AppPxeBootLinuxMenuHandlerLines` filters per entry by codename + arch,
  which every inventory row now carries). The Windows local-account validation is
  skipped for a preseed so an empty Windows account cannot block a Debian save.
- **First user from the vault, passwords hashed (2026-09-06, Craig).** A Debian
  sequence's first user is either typed or a vault credential (`userSource`
  manual|vault, `userVaultSecret`). Vault: at publish the credential's login
  becomes the Linux user (`ConvertTo-AppPxeBootTsLinuxUserName`: strip
  DOMAIN\ or @realm, lower-case, keep [a-z0-9_-], drop leading digits), its full
  name the GECOS, and its password is hashed with
  `ConvertTo-AppPxeBootTsSha512Crypt` - crypt(3) SHA-512 in pure .NET (Drepper's
  algorithm, 5000 rounds, verified against the spec vector and LibreSSL's
  `openssl passwd -6`; ~0.4 s a hash). A typed password arrives as
  `fields.userPassword` and is hashed in `ConvertTo-AppPxeBootTaskSequenceRecord`
  on save - only `userPasswordCrypted` is ever stored or published, blank keeps
  the saved hash. An unresolvable vault entry leaves the password out, so the
  installer asks rather than creating a user nobody can log in as. Gotcha met
  writing it: PowerShell variable names are case-insensitive, so `$salt = bytes`
  silently assigned into the `[string]$Salt` parameter and stringified the
  array - byte variables are `$keyBytes` / `$saltBytes`.
- **First-boot script from the library (2026-09-06).** `<library>/Scripts/` (created
  on publish with a README) is served by Caddy at `/Scripts/` and listed in the
  payload as `firstBootScripts`; the panel offers it as a dropdown with "Custom
  URL..." as the escape. Field `runScriptFile`: '' none (a legacy `runScriptUrl`
  alone still counts), `url` = the typed URL, else a plain file name resolved at
  publish to `http://<lan-ip>:8080/Scripts/<name>` (publish runs on every Start
  and menu regen, so the IP stays current). Path-shaped names are refused.
- **Ubuntu (2026-09-06, Craig: "probably Ubuntu").** Different shape from Debian
  and the plumbing already fitted it. 22.04+ has no d-i and no netboot
  installer: Canonical's PXE path is the live-server ISO's own `casper/vmlinuz`
  + `casper/initrd` with `ip=dhcp url=<ISO>` - casper fetches the WHOLE ISO over
  HTTP into RAM and boots Subiquity from its squashfs (so the VM needs ~8 GB;
  packages still come from the Ubuntu archive). So the ISO is genuinely needed:
  the catalog row (`kind = 'iso'`, `Start-AppPxeBootLinuxIsoDownload`) resolves
  the current point release from releases.ubuntu.com, verifies SHA256SUMS, and
  queues it through the aria2 direct rail into the library; once mounted (the
  cd9660 fallback again - hdiutil cannot mount it) the `ubuntu-live-server`
  layout row makes a menu entry with `installMode 'casper'` (install-capable, so
  the submenu applies). `platform: ubuntu` compiles to an autoinstall
  (`Build-AppPxeBootTaskSequenceAutoinstall`): identity with the crypt hash,
  storage `layout: direct|lvm` with `match: path` for one disk or `size: largest`
  for the Debian-style list, ssh, packages, `refresh-installer: update: false`,
  late-commands = the same first-boot parts as d-i run through
  `curtin in-target --target=/target --` (each a YAML single-quoted scalar, '' for
  a quote). Published as `autoinstall/<id>/user-data` + `meta-data` (cloud-init
  wants a directory; the seed URL ends in `/`); prune and the default check know
  the directory. Sequences and entries both carry `platform`, and the submenu
  offers only its own platform's sequences - a preseed never appears under an
  Ubuntu entry. Gates: `test-task-sequence-ubuntu.ps1` (22 checks, including the
  late-command executed with curtin/wget stubbed), `test-linux-menu.ps1` (32).
  Live: verified 2026-09-06 in QEMU (8 GB RAM, 16 GB virtio disk): the Ubuntu sequence handler booted casper off the mounted ISO, casper streamed the 3.4 GB ISO from Caddy, cloud-init fetched the seed, Subiquity ran the autoinstall, curtin wrote the system, and the machine rebooted on its own. Gotchas met: `return , $parts` reaches a
  caller's `@()` as ONE nested array - emit the array plainly. And the big one:
  **cloud-init also reads a kernel `url=`** as "fetch this as my cloud-config" -
  it read the whole 3.4 GB ISO named for casper into memory and was OOM-killed
  twice, so Subiquity never got its seed. cloud-init prefers `cloud-config-url=`
  when both are present, so every Ubuntu handler names one: the seed's
  `user-data` on a sequence handler, `http/linux/ubuntu/cloud-config-none`
  (`#cloud-config` + `{}`, written on menu regen) on Interactive.
- **Linux steps run through `bash -c` (2026-09-06, Craig's call).** They were `sh -c`
  (dash on both distros) and the panel badge said "Cmd", which reads as cmd.exe. bash is
  Essential on Debian and in the Ubuntu server base, so it is always in /target by
  late_command time, and every sh one-liner runs unchanged under it. The panel now says
  "End-of-install steps" / "+ Bash" on a Linux sequence, because that is when they run:
  in-target as root before the reboot, no systemd. The first-boot script is the other
  phase (systemd unit, network up). The fetch line itself stays `sh -c`. "Extra
  packages" got a picker (`TS_LINUX_PACKAGE_PICKS`, names present in both archives,
  per-platform rows for desktops and Hyper-V tools); the text stays the record.
- **First-boot script upload (2026-09-06, Craig: "can we allow uploading a script to the
  local caddy").** `ImportPxeBootTsScript` copies a file from the Mac into
  `<library>/Scripts/` (`Import-AppPxeBootTsScript`), mirroring ImportPxeBootIso's shape
  (dialog in the panel, sidecar does the copy). It refuses what the target would choke
  on: no `#!` first line (systemd execs the file - ENOEXEC, and the first boot silently
  does nothing), binary, a name the compiler would not accept, README; a BOM or CRLF is
  normalised to LF (a CRLF shebang is "bash\r: not found"). `RemovePxeBootTsScript` and
  `OpenPxeBootTsScriptsFolder` round it out; the panel's "Add..." selects the imported
  name straight into the sequence. Nothing is copied at publish - the installer wgets
  the script from Caddy at the end of the install. Gate: five checks in the Debian gate
  against a temp library root (`Get-AppImageLibraryRoot` stubbed).
- Debugging an installer you cannot type at: from tier 3 the QEMU test passes
  `log_host=10.0.2.2 log_port=5514` and listens with `nc -u -k -l 5514`, so
  d-i's syslog lands in `$WORK/d-i.syslog` (udeb fetches, module loads, disks
  seen). partman's own decisions are NOT in syslog (`/var/log/partman`); a
  `partman/early_command` that pipes `list-devices disk`, `/proc/partitions` and
  `debconf-get partman-auto/disk` into `logger` showed what it was given.
- Gotcha found on the way: `Invoke-WebRequest` returns a byte[] for
  octet-stream bodies (deb.debian.org's SHA256SUMS) - `[string]` of that is
  "1 2 3". `Get-AppPxeBootHttpTextContent` decodes. And `$host` is a read-only
  automatic variable - never assign it.
- Gotcha for anyone testing live: `scripts/test-strictmode.ps1` spawns a real
  sidecar, which ADOPTS a running Caddy, decides its imaging-log route points at a
  dead listener, and restarts Caddy from its own (empty) mount map - every
  `/iso-mount/` and `/iso-wim/` route vanishes until the next Start. Do not run
  the gates while a boot test is in flight.
- Secure Boot: the bundled shim trusts the iPXE CA, not Debian's kernel key.
  Linux entries need Secure Boot off; the handler says so when `boot` fails.
- Two adjacent fixes rode along: `Remove-AppPxeBootIso` and the layout warning
  looked mounts up by bare ISO stem, but the map is keyed by token, so neither
  ever matched (the warning fired for every ISO whenever HTTP was up).

### Linux task sequences, 2026-09-05 (branch `feature/linux-task-sequences`)

A task sequence now says which installer consumes it. `platform` is `windows`
(unattend.xml, unchanged) or `debian` (a d-i preseed). Absent means windows, so
every sequence saved before this keeps working untouched, and `kind` is cleared
on a preseed because client/server is a Windows role.

**A preseed is the equivalent of unattend.xml, and late_command is the
equivalent of SetupComplete.cmd.** The worked example in the gate is CampusCast:
a Debian receiver that installs unattended, then runs one script at first boot
through a one-shot systemd unit that disables itself. That is the pattern
CampusCast's own preseed uses in production.

Four differences from the Windows path, all of them load-bearing:

- **Selection happens at boot, not after it.** WinPE shows a picker and copies
  the chosen XML to Panther. d-i is told `preseed/url=` on the kernel command
  line, so the *PXE menu entry* decides which sequence a machine gets. Nothing
  wires that yet - see below.
- **There is no deploy-time client**, so the `{{SITE}}`/`{{SERIAL}}` half of the
  token model has no counterpart. Everything is concrete at publish time, and
  anything per-machine has to be shell in `late_command`.
- **Secrets cannot be withheld.** The Windows publisher deliberately leaves
  `{{JoinPw}}` for the client to fill so a join password never lands on the
  share. An unauthenticated installer fetching a preseed over HTTP cannot do
  that: everything in the file is readable by anything on the boot VLAN.
  Passwords go in as crypt(3) hashes and nothing else sensitive goes in at all.
- **No mirror block in the preseed.** The menu already points d-i at the mounted
  ISO with `mirror/http/*`; repeating it in the preseed overrides those kernel
  arguments and sends the installer to the internet instead of the ISO.

Publishing writes `<id>.cfg` beside the Windows `<id>.xml`, and both the prune
list and the default-sequence check learned about `.cfg` - a preseed for a
deleted sequence left on the share is one a stale menu entry would still
install from. Preseeds are written **LF only**: d-i takes a CR as part of the
value, so a CRLF hostname is one nobody can resolve.

Gotcha worth the whole gate. The fetch line quotes at **two** levels: the URL
for the shell inside `sh -c`, and the whole payload again for the shell reading
the late_command line. Getting only the outer level right still produces a
working command for an ordinary URL, because adjacent quoted strings simply
concatenate - so `sh -n` passes, and every substring regex passes. It only comes
apart when the value holds a space or a metacharacter, which is why
`test-task-sequence-debian.ps1` executes the late_command with `in-target`,
`wget`, `chmod` and `systemctl` stubbed and asserts the URL arrives as one
argument. Two smaller ones found writing that: `in-target` cannot be a shell
function (a hyphen is not a valid POSIX function name, so the stubs are real
executables on PATH), and `Get-Content` on a one-line file returns a scalar,
which has no `.Count` under StrictMode.

The panel picks the platform when a sequence is created and never after, since
the field sets do not overlap. `tsFieldOrder`/`tsFieldLabel` gate the editor, so
a Debian sequence never offers a machine OU and a Windows one never offers a
partition recipe.

**Not done, deliberately:**

- Menu wiring, 2026-09-05 (same branch): an install-capable Debian entry (netboot
  initrd in place) with published Debian sequences is a **submenu** - one item
  per sequence, `Interactive install (no task sequence)`, `Back` - and one
  handler per item (`Get-AppPxeBootLinuxMenuHandlerLines`). Shape chosen over
  flat ISO x sequence: 3 ISOs x 8 sequences is 3 top-level items, not 24. A
  sequence handler adds `auto=true priority=critical
  preseed/url=${http_base}/TaskSequences/<id>.cfg` before `---`
  (`Add-AppPxeBootDebianPreseedKernelArgs`); Caddy already serves that path.
  Interactive is preselected unless the store's default sequence is a Debian
  one - an unattended install wipes a disk and must never be the default by
  accident. Boot-only entries and Live media never get a submenu. Choices come
  from `Get-AppPxeBootLinuxTaskSequenceChoices`: enabled, `platform` debian, and
  the `.cfg` actually on the share. Gate: `scripts/test-linux-menu.ps1`
  (19 checks, no store, no mount). QEMU `--preseed` tier: 2026-09-05: the sequence handler booted, d-i fetched debian-qemu-test.cfg off the share, loaded its components off the ISO and asked nothing up to partitioning, where it stopped with 'No root file system is defined' - the storage-udeb gap (next item), not the menu.
- Nothing serves the first-boot script. `runScriptUrl` is free text today; it
  should become a file in the library served over the existing Caddy tree.
- Ubuntu 20.04+ and RHEL are not covered. **Ubuntu is not a gap in Ubuntu** - it
  has `autoinstall` YAML through cloud-init and is better documented than
  preseed. The trap is only that a preseed handed to a modern Ubuntu ISO is
  silently ignored. RHEL/Rocky want kickstart. Both are another `platform`
  value and another builder; the store, publish and panel gating already take
  one.
- Secure Boot stays off for Linux entries, as the ISO-boot work already records.

Gates: `scripts/test-task-sequence-debian.ps1` (22 checks) alongside the existing
`test-task-sequence-library.ps1` and `test-task-sequence-accounts.ps1`, all green,
plus `tsc --noEmit`.

### Scope sweep, 2026-08-21 - removed what is not an MDT/PXE replacement

Craig: *"All we are doing is MDT/WDS and PXE imaging."* Everything below was
upstream tooling with no path to a WinDeployKit feature, and all of it was
verified unreachable before removal.

| Removed | Size | Why it was dead |
| --- | --- | --- |
| `sidecar/lib/AppLazyPlugins.ps1` | 140 lines | A lazy **plug-in registry** for 11 upstream plug-ins (Mist, Meraki, SolarWinds, PaperCut, ServiceNow, WMS, Oliver, MDM, ASM, Arcade, SiteBuild). **None of those files exist here** and nothing wired the loader. Directly contradicted section 2.9 |
| `app/src/lib/cacheTtls.ts` | 200 lines | Cache catalog for staff/students/groups/MDM device lists. Not imported anywhere |
| `Ipc.ps1` boot ladder + NPS gate | ~110 lines | Bootstrap-phase overlay and an NPS-mount boot gate. Nothing called `Write-SidecarBootstrapPhase`; there is no NPS feature here |
| `SidecarParams.ps1` group parser | 32 lines | `Read-AppSchoolGroupMembershipSidecarParams`, no callers |
| `sidecar.rs` timeout table | ~30 lines | Per-command timeouts for WLC probes, switch CLI/audit bundles, ServiceNow and SiteBuild - none of which have handlers |
| `index.css` | **544 lines** | Theme-package system, skin audio, the animated startup experience (orbs, circuit art, brand glow), boot-progress dots, the site-switcher/site card, drag-reorderable nav. section 2.9 and section 10 say these were deleted; the CSS had survived |
| `AppIcon.tsx` | 43 lines | 30+ glyphs for AD/staff/student/printer/wireless panels. Trimmed to the 12 the console tree can actually reach, plus the fallback |
| `types.ts` | 36 lines | 14 event names nothing emits or consumes, and the LDAP/sites-catalog half of `ApplyRuntimeConfigParams` |

**Kept deliberately**, despite being unused: `badge-*`, `data-card`, `detail-pane*`,
`btn-*` and the nav primitives. `docs/WINDEPLOYKIT_App_StyleGuide.md` section 5-section 6 specifies
them as the design system - unused is not the same as unwanted.

Also kept, because they are genuinely Windows deployment and not upstream residue:
the `Intune`/Autopilot clean-OOBE task-sequence option, VPN/Tailscale adapter
guidance, `GPO-disable` step sets, and the vendor SCCM driver catalogs.

### Panels

| Node | State |
| --- | --- |
| Netboot | **Wired** - services, DHCP options 66/67, adapter/port/mode |
| Boot Images | **Wired** - boot WIM library |
| Operating Systems | **Wired** - OS image catalog + acquisition |
| Out-of-Box Drivers | **Wired** - vendor catalogs + driver store |
| Task Sequences | **Wired** - sequence editor |
| Monitoring | **Wired** - PXE log + imaging clients, both clearable |
| Transfers | **Wired** - download client |
| Applications | Placeholder (deferred, section 2.6) |
| Site Profile | **Placeholder - needed**, see section 5 |
| Sidecar Log | **Wired** - live stderr tail, Pause / Clear / Restart Sidecar verbs (`panels/SidecarLogPanel.tsx`) |
| Deployment Share (root) | Placeholder |

### Shared secret vault (built 2026-08-21)

Credentials live in the **shared secret vault** defined by USM's
`SHARED_SECRET_VAULT_CONTRACT.md` - one per-user store shared by USM,
WinDeployKit and PSOpenAD-FE, the SecretManagement API in front, and
**no OS credential UI** behind it (no Keychain, no Credential Manager,
no secret-tool). Craig closed section 6 as **Option B**.

| Piece | Where |
| --- | --- |
| Vault module | `vendor/psmodules/SecretManagement.LocalVault/1.0.2/` - a **tagged release** of its own repository, github.com/MacsInSpace/SecretManagement.LocalVault, exported with `git archive` (sibling checkout `../SecretManagement.LocalVault` when it has the tag, else a shallow clone). Do not edit here; module bugs go to that repo as issues/PRs, integration findings to the USM handover |
| API module | `vendor/psmodules/Microsoft.PowerShell.SecretManagement/1.1.2/`, pinned in `vendor/psmodules.lock.json` |
| Sync + drift check | `scripts/sync-secret-vault-modules.ps1` (USM's copy, verbatim; `-VerifyOnly` for CI and at bundle time). Bump = edit the pin, rerun, commit `vendor/psmodules` + lock; all three products move together |
| Our glue | `sidecar/lib/AppSharedSecretVault.ps1` |
| Handlers | `sidecar/handlers/Credentials.ps1` - the 7 commands that had none, plus `GetSecretVaultStatus` |
| Bundle | `scripts/prepare-bundle-deps.ps1` verifies the lock and stages both as `modules/<Name>/<ver>/`; the wrapper resolves `modules/` first, then `vendor/psmodules/` |
| Tests | The module's own Pester suite runs in its repo (CI on Ubuntu, macOS, Windows pwsh 7, Windows PowerShell 5.1). Nothing module-level is carried here |

Names we use, from contract section 3:

- **`netboot/join/<id>`** - ours to write. Task-sequence domain-join and Deploy$
  share credentials.
- **`local-machine/admin`** - read. **UserName IS the login** (e.g. `st00447`),
  not a tag.
- **`dept/edu001`** - read, and **write freely from our own sign-in** (contract
  section 5a, 2026-08-21 night). USM treats its `DeptCredentials.xml` as
  authoritative when present and refreshes the vault from it on its next read, so
  our write is either adopted (no file) or superseded (file wins). Neither is
  harmful, so there is no guard - the path-mirroring guard we first built failed
  open and was deleted. `Set-AppVaultDeptCredential` is the writer.

Rules that are not negotiable:

> Registration is **by manifest path, at every start-up** (contract section 8b:
> SecretManagement's in-process registry cache only refreshes on a file-watcher
> event, so a running product never sees a sibling's change). `Register-LocalVault`
> is idempotent and **self-heals** a dead entry left by an uninstalled or cleaned
> sibling - expect one `healed` line in the log after a `cargo clean` in
> PSOpenAD-FE, whose `target/debug` copy currently holds the registration on
> Craig's Mac. There is no reset concept in this vault - the SecretStore bootstrap that had one was withdrawn
> (contract section 4a) after it was shown to wipe every kit's secrets.
> **Every credential function must work with the vault unavailable**, falling
> back to the legacy Clixml file, so a vault fault degrades to yesterday's
> behaviour and never locks a technician out. Verified by moving the module aside
> and re-running all seven handlers.

`keyMatches = false` means the store came from another machine or user. Surface
it as **"sign in again"**, never as corruption.

### Setup and the Deploy$ base (built 2026-08-21)

The Deploy$ base is chosen in a **first-run wizard** and changed afterwards from
the **Deployment Share** node, mirroring MDT: a New Deployment Share Wizard before
the console is usable, then the share root's own properties.

| Piece | Where |
| --- | --- |
| Wizard | `app/src/components/SetupWizard.tsx` - modal, non-dismissable on first run, reused with a Cancel path from Settings |
| First-run flag | `SETTING_SETUP_COMPLETED` (`app/src/lib/setupSettings.ts`) |
| Panel | `app/src/panels/DeploymentSharePanel.tsx` on the `deployment-share` node |

Stored rather than inferred, deliberately: a technician who accepts the default
leaves `SETTING_IMAGE_LIBRARY_DIR` empty, so "no override" is a legitimate steady
state and inferring from it would re-run the wizard every launch.

The wizard shows **free space** on the chosen volume and warns under 20 GB. That
is the section 3b lesson made visible rather than just documented.

**Step 2 - Tools (built 2026-08-29).** Craig: "we should not probe homebrew. Treat it
as not installed (as it probably wont be on any mac) ... in WDK, we should grab
executables from their projects (not edustar.tech) and offer to install at setup".
So the wizard's second step is AdobeUpdateKit's "Download tools" shape:

| Piece | Where |
| --- | --- |
| Inventory + one-shot download | `sidecar/handlers/Tools.ps1` - `GetTools` (rows: caddy, tftpd64 / dnsmasq, wimlib, aria2, 7-Zip) and `EnsureTools` (every downloadable row, or a `tools` subset; per-tool lines, failures never abandon the rest) |
| Sources | Caddy - GitHub release; Tftpd64 - GitHub release (Windows); aria2 - GitHub release on Windows, **bundled build from upstream source on macOS** (`scripts/build-aria2-macos.sh`, `vendor/binaries/pxe-macos/aria2c-universal`); 7-Zip - `7zz` from 7-zip.org on macOS (`packaging/p7zip-tools.json`, `Ensure-AppPxeBootP7zipTools -Download`); dnsmasq and wimlib-imagex - bundled |
| Rule | No resolver looks under `/opt/homebrew` or `/usr/local`; the only outside lookup is a plain `Get-Command` on PATH. Neither product fetches tools from `gitlab.edustar.tech` (that is USM's feed, not ours) |
| Finish | Never blocked by a missing tool - the Netboot and Downloads panels retry on demand and say what is missing |

**Tools node (Advanced Configuration > Tools, built 2026-08-29)** - AdobeUpdateKit's
Core Updates shape. Craig: "a panel for managing these ... so the user can update them
where available ... install via github and let the user update when there is one."

| Piece | Where |
| --- | --- |
| Registry, state, mechanics | `sidecar/lib/ToolsRegistry.ps1` - one table (`Get-AppToolsRegistry`: id, kind `github | manifest | bundled | prereq`, repo + asset regex per platform key, pinned / resolve / live / marker / ensure scriptblocks); `tools-state.json` and `update-check.json` under `<data root>/tools/`; kept versions in `tools/<id>/<version>/` |
| Verbs | `GetTools`, `EnsureTools` (pinned install), `CheckToolUpdates` (GitHub `releases/latest`, cached 24 h, `force`), `UpdateTool` (ONE tool: download the latest asset, verify GitHub's `sha256` digest, refuse an unsigned Mach-O, keep the replaced binary, write marker + state), `RollbackTool` (the kept copy, no network) - `sidecar/handlers/Tools.ps1` |
| Panel | `app/src/panels/ToolsPanel.tsx`; nav id `tools`; Action menu: Check for updates, Download missing tools |
| Two versions | The pin in `packaging/*.json` is the default for a fresh install; what the user installed lives in `tools-state.json`. `Test-*Installed -RequirePinnedVersion` compares against `Get-AppToolExpectedVersion` (state, else pin) - without that a user update was "wrong version" to the next Ensure and got reinstalled over |
| Never automatic | Plug-ins still install the pinned version themselves on enable / service start. Only the panel and the wizard obtain a newer release, on a click |
| Not updatable from the panel | bundled builds (dnsmasq, wimlib-imagex, macOS aria2c) update with the app; 7-Zip has no release feed (pin bumped with the app); PowerShell is the prerequisite - a newer release is reported with a link, never installed |

> **`pushImageLibraryRoot()` is now called at startup** (`App.tsx`). Nothing called
> it before, so the sidecar never learned the configured root and always fell back
> to the default regardless of the setting. If the Deploy$ base ever appears to be
> ignored, check that call first.

### Commands without a sidecar handler (re-measured 2026-08-26)

`app/src/lib/types.ts` declares 83 `SidecarCommand`s; four have no `Handle-*`:

| Command | Callers | What it is |
| --- | --- | --- |
| `GetSiteProfile` / `SetSiteProfile` | none | Expected - section 5 |
| `LoadLocalMachineCredentialToSession` | none (its one caller went with the vault work) | Dead entry - cut it from the union |
| `harvest_acer_sccm_urls` | 1 | **Not a sidecar command** - a Rust `#[tauri::command]` in `acer_harvest.rs` that is wrongly in the sidecar union. Move it out |

The macOS credential-cache pair (`ClearMacOsAdminCredentialCache` /
`PrefetchMacOsAdminCredential`) got handlers on 2026-08-22 (section 9b). Re-measure with:

    awk '/^export type SidecarCommand =/,/;$/' app/src/lib/types.ts | grep -o '"[A-Za-z_]*"' | tr -d '"' | \
      while read c; do grep -q "^function Handle-$c\b" sidecar/windeploykit-sidecar.ps1 sidecar/handlers/*.ps1 || echo $c; done

The 2026-08-21 list of 12 is closed: the seven credential commands and
`DeleteInfraSshCredential` got handlers with the vault.

### Not built yet

- Phase-C first-boot runner (section 2.3)
- The WinPE client rewrite (section 2.1)
- Site Profile (section 5) - several TODOs block on it
- Boot-image creation UI over the existing wimlib overlay engine

---

## 3b. Where data lives - the storage split (enforced)

**Craig, 2026-08-21:** boot images and the TFTP root may live in central app data;
**large ISOs and drivers go wherever the user sets the Deploy$ base.**

| Category | Location | Why |
| --- | --- | --- |
| TFTP root, boot WIMs, `wimboot`, `snponly.efi`, configs, logs | **App data** - `~/Library/Application Support/windeploykit` / `%LOCALAPPDATA%\windeploykit` (slug-named since 2026-08-22) | Small, fixed, machine-local. Must be where the services expect it |
| ISOs, imageable/SOE WIMs, driver packs, download staging | **Image library = the Deploy$ base** - user-chosen, default `~/Public/WinDeployKit` (macOS) / `~/Downloads/WinDeployKit` (Windows) | Multi-GB. Must never fill the system drive |

### The rule

> **Nothing multi-GB may resolve into the app-data store - including on a fallback
> path.** The store is on the system drive. If the image library is unavailable,
> fall back to `Get-AppImageLibraryDefaultRoot` (which is deliberately off the
> app-data tree), never to the plug-in store, and **log it**.

This is not theoretical. USM filled an SSD by writing a **~60 GB WIM to
`%LOCALAPPDATA%`** with no choice of location
(`docs/core/app-data/AGENT_NOTES_APP_DATA_LAYOUT.md` in that repo). Two fallbacks
here had the same shape and were fixed on 2026-08-21:

- `Get-AppAria2EffectiveDownloadDir` defaulted to `<store>/plugins/aria2/downloads`
- `Get-AppPxeBootLayoutPaths` routed `isoDir`/`imageWimsDir` into `<store>/http/...`
  when the image library failed to resolve - behind a **bare `catch { }`**, so it
  was silent

Both now resolve to the image library. Verified by resolving all nine paths and
asserting which side of the boundary each lands on; re-run that check after touching
either resolver.

### The spaces trap (carried from USM, keep it working)

`~/Library/Application Support/...` contains a space, and **`Start-Process
-ArgumentList` joins an argument array with spaces WITHOUT quoting**, so every
app-data path splits into multiple arguments. USM shipped this bug to the field in
aria2, dnsmasq, RDP/SSH launch and folder reveals.

- Always: `Start-Process ... -ArgumentList (Format-AppProcessArgumentList -Arguments @(...))`
  (`sidecar/lib/AppPlatform.ps1`). **Never pass a raw array.**
- Need exact argv: `Start-AppNativeProcess` (`ProcessStartInfo.ArgumentList`).
- `& tool $path` is safe - the bug is specific to `Start-Process`'s array join.

Both live call sites (aria2 daemon, dnsmasq) use the helper and were verified
against a spaced path.

---

## 4. UI rules (enforced)

Governing doc: **`docs/WINDEPLOYKIT_App_StyleGuide.md`**. Direction and the MDT
node mapping: `docs/UI_DIRECTION.md`.

The short version - violating any of these is a defect:

- **Two modes only**: light and dark. `:root` holds the complete light palette;
  dark is redefined under both `prefers-color-scheme` *and* `[data-theme="dark"]`.
  **Never define a colour only inside a media/attribute block.**
- **Square**: `--radius-shell: 0`, card 5px, control 4px. Nothing above 5px.
  (Historic trap: `.btn` used Tailwind `rounded-lg` = 8px because the config
  only overrode sm/DEFAULT/md. The scale is now capped.)
- **32px chrome**: `--header-height` drives the sidebar lockup *and* the panel
  header so they align across the seam. One line: title, then controls.
- **26px rows**, flat surfaces, no gradients or structural shadows.
- **Tooltips, not prose.** Help goes in `title` or `InfoTip`, never a paragraph
  under a control. State is a badge, not a sentence.
- **No decoration**: no emoji in labels, no hero blocks, no "Overview"/
  "Dashboard" node (selecting the share root *is* that view, as in MDT).
- **Verbs match MDT/ADUC wording exactly.** Familiarity is the feature.

### Structure

```
app/src/components/ConsoleShell.tsx   the MMC console: title bar, menu bar, toolbar,
                                      tree | splitter | result pane, status bar
app/src/components/ConsoleTree.tsx    the console tree (26px rows, whole-row selection)
app/src/components/MenuBar.tsx        File / Action / View / Help   (from PSOpenAD-FE)
app/src/components/ContextMenu.tsx    MenuItem, SEP, MenuSurface     (from PSOpenAD-FE)
app/src/components/navConfig.ts       the console tree data (a plain array - no registry)
app/src/state/consoleActions.ts       the ONE home for a node's verbs
app/src/lib/sidecarBoot.ts            the ONE place the sidecar is started (singleton,
                                      StrictMode-safe); lifecycle for the title-bar badge
app/src/components/PanelShell.tsx     result-pane frame: 32px header, optional tabs, body
app/src/panels/<Node>Panel.tsx        one thin file per node
app/src/workspaces/                   shared state containers; panels render sections
```

**Verbs live in the shell, never in a panel (2026-08-21, Craig).** Every panel
used to draw its own header buttons, so the same kind of action sat in a
different place on every node. Now a panel publishes its verbs with
`useConsoleActions({ items, refresh, properties, status })` and the shell
renders them in the Action menu, the right-click menu and the two toolbar
glyphs (Refresh F5, Properties Alt+Enter). `PanelShell` has no `toolbar` prop
any more; adding one back is the defect this rule exists to stop.

Two traps in that registry, both hit while building it:

- **Memoise the def.** `useConsoleActions` publishes on identity change. A
  workspace that keys its memo on a prop array the panel passes as a literal
  (`sections={["host"]}`) republishes every render, the shell re-renders, the
  panel re-renders, and it loops. Key on booleans derived from the array, not
  the array.
- **Read the store at fire time after a node switch.** Right-click on a
  non-active node selects it first; the new panel publishes on mount, so the
  menu opens on a short timer - and must call `getConsoleActions()` then, not
  use the `actions` the handler closed over, which still belong to the node
  being left. The first build showed Netboot's verbs on Transfers.

Nav order is **deployment order, not MDT's**: Netboot (owns the services) -> Boot
Images (what they serve) -> Operating Systems -> Out-of-Box Drivers -> Applications
-> Task Sequences -> Monitoring.

The two workspaces are shared because the state genuinely is (one config poll,
one status poll feed several nodes). `PxeWorkspace` takes a `sections` prop;
`ContentWorkspace` takes a `tabs` prop. A section that owns its whole panel
(`solo`) hides its heading and disclosure caret - the panel title already says it.

**Sibling project:** `/Volumes/Data/projects/PSOpenAD-FE` shares this exact design
system (`docs/PSOPENAD_FE_StyleGuide.md`), adapted for ADUC. Style-guide changes
belong in both.

---

## 5. Site Profile - the main outstanding design task

The upstream tool sourced site-specific values from a school-directory feature
that was not extracted. Every consumer is now a `TODO(Site Profile)` in the code:

```bash
grep -rn "TODO(Site Profile)" sidecar/ app/src/
```

It needs to supply: join domain(s), machine OUs, KMS product keys, admin group
names, local-admin passwords for the `{{LocalAdminPw}}` token, deploy-share host,
site id (for the `{{SITE}}` naming token), org name and time zone for generated
unattend files.

Until it exists, `Get-AppPxeBootTaskSequencePublishContext` returns nulls
**deliberately** - so token expansion fails loudly rather than publishing a
wrong-but-plausible value. Do not "fix" that by adding fallbacks.

> **Security note:** the upstream version fell back to two hardcoded department
> bench passwords (base64-obscured). Those were **removed**. Never reintroduce a
> hardcoded credential fallback.

---

## 6. Traps and gotchas

### Silent `catch { }` blocks

Ported code is full of bare `try { ... } catch { }` with empty handlers -
**40 of them in `PxeBootPlugin.ps1` alone**. During the port, a missing function
inside `Get-AppPxeBootNetworkAdapters` produced
**"No LAN IP" with no log line at all** and took a direct function call to
diagnose.

> If something fails inexplicably, **look for an empty catch first.** Consider
> making them `Write-SidecarLogVerbose` instead of discarding.

### `cargo`/Tauri build fails pointing at `/Volumes/Data/projects/deploykit`

Symptom, on `npm run tauri:dev`:

```
failed to read plugin permissions: failed to read file
'/Volumes/Data/projects/deploykit/app/src-tauri/target/debug/build/
tauri-<hash>/out/permissions/app/autogenerated/commands/app_hide.toml'
```

Note the path: **`deploykit`, not `windeploykit`** - the pre-rename location,
which no longer exists. Nothing in git references it; it is entirely stale Cargo
build cache from before the rename. Tauri's build script records an absolute
`OUT_DIR` and reads permission TOMLs back from it, so a moved project poisons it.

**Fix - targeted, ~15s, no full rebuild:**

```bash
rm -rf app/src-tauri/target/debug/build/tauri-*
rm -rf app/src-tauri/target/debug/.fingerprint/tauri-*
rm -rf app/src-tauri/target/debug/build/windeploykit-*
rm -rf app/src-tauri/target/debug/.fingerprint/windeploykit-*
```

`cargo clean` also works but discards ~6 GB and rebuilds everything for no extra
benefit - only the crates that emit permission files need it.

Around 740 stale references survive in dependency `.d` and `root-output` files.
They are harmless: those record build-script output locations for change
detection, and none is read back by path at compile time the way Tauri's
permissions are. Verified after the fix that no `tauri-*` or `tauri-plugin-*`
build dir still carries the old path.

### `$x = [void](Some-Function)` never calls the function

Measured, and it silently broke the credential clear path:

```powershell
$a = [void](Do-Thing)   # Do-Thing is NEVER invoked
[void](Do-Thing)        # bare statement - DOES invoke
```

On the right-hand side of an assignment PowerShell treats `[void]` as a cast that
short-circuits the call. Use `[bool](...)` when you want the result, or call it as
a bare statement when you do not. There is no error, no warning, and the
surrounding code reads as though it ran.

### `[bool]` vs `[switch]` parameter binding

A `[bool]` parameter cannot take a bare `-Param`; it needs `-Param $true` or
`-Param:$true`. Upstream had two instances; one broke the entire driver catalog
whenever the manifest host was unreachable. Fixed here. The scanner that finds
them is in `usm-reference/HANDOVER_TO_USM_AGENT.md`.

### `$script:AppSidecarProjectRoot`

Must be set **before any lib is dot-sourced** - ~20 call sites resolve
`vendor/binaries` and `packaging/*.json` through it. The sidecar bootstrap does
this; if you write a new entry point, do it there too.

### Other

- **Never edit `usm-reference/` originals** expecting it to affect the build -
  they are reference copies, not sources.
- `wim-inject/` (615 MB) is gitignored: ADK-derived WinPE system files, EULA-scoped.
- `vendor/binaries/pxe-mdt-boot/` and `sidecar/pxe/mdt-boot-x64/` are Microsoft
  boot binaries - gitignored, never redistribute.
- **The nine arch trees are in this repo now** (`sidecar/pxe/<arch>/`, tracked,
  incl. `x86_64-sb/shimx64.efi` and `arm64-sb/shimaa64.efi`) - the 2026-08-22 text
  that said otherwise was stale by the 2026-08-26 audit. `Sync-AppPxeBootBundledArchTftpTrees`
  stages all nine on every Start / Update. **Never** take the root-level
  `snponly.efi` from upstream - ours is byte-patched and the upstream root copy is
  a symlink to the unpatched one. "Staged" is still not "Secure Boot verified on
  hardware" - that boot is item 1 of the section 9 to-do list.
- The Secure Boot iPXE chain builds from a **sibling repo**,
  `/Volumes/Data/projects/ipxeboot`. Undeclared build dependency; formalise it.
- The bundled `snponly.efi` carries a **byte-patched embed** (an upstream WAN
  fallback removed). The ipxeboot source embed still needs the matching change
  at next rebuild.
- **This product downloads nothing at runtime (2026-08-22).**
  `product-identity.ps1` ships `AssetFeedBaseUrl = ''`, so
  `Get-AppProductAssetFeedUrl` returns `$null` and every caller takes its
  bundled-copy fallback. The `packaging/*.json` manifests keep only public
  upstream `githubUrl` values (caddy, tftpd64); the placeholder-host
  `manifestUrl`/`downloadUrl`/`wimUrl` fields are blank. aria2 ships in
  `vendor/aria2-tools/`, p7zip is neither bundled nor fetched (ISOs are read by
  mounting them), and `packaging/aria2-tracker.json` is an empty skeleton - the
  original catalog was org-specific and was removed. To wire up your own
  artifact host, set `AssetFeedBaseUrl` and fill those fields back in.

---

### Two more from USM's contract section 5c (measured by other agents)

- `$null` to a .NET `string` parameter (e.g. `File.Replace($a, $b, $null)`):
  PowerShell passes `""` and the method rejects it. Use `[NullString]::Value`.
- A helper that invokes a caller's scriptblock: PowerShell's dynamic, case-insensitive
  scoping means the body's `$Name` resolves to the helper's own local `$name`.
  Give such helpers un-generic local names; never "fix" with `GetNewClosure()`
  (it loses module-private functions).

The full table is `SHARED_SECRET_VAULT_CONTRACT.md` section 5c in the USM repo.

## 7. Conventions

- **Sidecar IPC**: one JSON object per line on stdin
  (`{"id":N,"cmd":"Name","params":{}}`); responses NDJSON on **stdout only**;
  all human logging to **stderr**. Commands resolve by convention -
  `"Foo"` runs `Handle-Foo`. Adding a command = adding a function.
- **PowerShell**: pwsh 7 compatible, `Set-StrictMode -Version Latest`. Watch two
  known traps - `ConvertFrom-Json` hydrates ISO-8601 into `[DateTime]`, and
  parameter names that collide with automatic variables.
- **Verify by running, not by reading.** The sidecar can be driven from a shell
  (see README). The frontend can be checked headlessly for console errors. Every
  claim in section 3 was verified that way.

---

## 8. If you are picking this up cold

1. Read this file, then `usm-reference/PORT_NOTES.md` for the long history.
2. `cd app && npm install && npm run tauri:dev`.
3. Smoke-test the sidecar from a shell before blaming the UI.
4. The to-do list, in order, is **section 9**. Read it before picking anything.
5. Commit early and often, and push - `main` tracks `origin/main`.

---

## 9. Handover - where things stand and the to-do list (2026-08-22)

Written for whoever picks this up next. Everything here was checked against the
trees on 2026-08-22, not copied from earlier notes. Dates are absolute.

### Done and closed - do not redo

| Thread | State |
| --- | --- |
| Extraction, rename to WinDeployKit, generic-isation (`siteId`) | Done 2026-08-21 (sections 1, 3) |
| Scope sweep (no MDM, no VPN/Tailscale, no school model) | Done 2026-08-21, commit `859e8cf` |
| StrictMode, ASCII-only and storage-split gates | `scripts/test-strictmode.ps1`, `test-ascii.ps1`, `test-storage-policy.ps1`; all clean at `49114d8`. Run all three before every commit |
| First-run wizard + Deploy$ base in Settings | Done (section 3) |
| MMC console shell (menus, toolbar, splitter, verbs registry) | Done (section 4). All verbs live in Action / right-click / toolbar, never in panel headers |
| Sidecar auto-start from the app | `lib/sidecarBoot.ts`, commit `12bc591` |
| Shared secret vault, Option B | Built 2026-08-21, re-vendored from the module's own repo at `v1.0.2` on 2026-08-22 (`49114d8`). USM: "nothing owed" |
| Application icon | `31f68b6` |
| macOS build / notarisation notes | `docs/AGENT_NOTES_MACOS_BUILD.md`, carried from PSOpenAD-FE 2026-08-22 (section 0b) |

### Open threads with the other agents

| With | Thread | Who moves next |
| --- | --- | --- |
| USM | **Arch trees** for Secure Boot. USM `main` (merge `8e9f998f`) has all nine `sidecar/pxe/<arch>/` trees (37 files, 24.5 MB). Ours has none, so Option 67's default `x86_64-sb/shimx64.efi` 404s at boot | **Craig's go**, then us: copy byte-identical from USM `main` (`git show main:sidecar/pxe/<arch>/<file>`), never the upstream root `snponly.efi`, verify every blob's SHA against `git rev-parse main:<path>` in USM, commit. `.gitattributes` already marks `*.efi *.pxe *.kpxe` binary |
| USM | **Identity contract** (section 0). Agreed; not started by anyone | Us, now: (1) set `$script:AppProductIdentity` in `sidecar/windeploykit-sidecar.ps1` before any dot-source - one commit, no behaviour change; (2) convert lib by lib, each file's contract grep hitting 0 before moving on; (3) tell USM in the handover which files are clean so they can vendor them |
| USM | **`AppElevation.ps1` / `AppNativeProcess.ps1`** - USM owns them, said it would take and de-identify them first, has not committed either | Ask USM in the handover. If they stay silent, de-identify our copies under (2) above and offer those; do not edit them for any other reason without telling USM |
| USM | Still owed to USM: nothing. Their last section (2026-08-22 later) closes the vault | - |
| PSOpenAD-FE | Nothing owed either way. They re-vendor the vault themselves (USM told them). Their `target/debug` copy holds the `shared` registration on Craig's Mac until they clean it | - |
| Module repo | Vault bugs go to `MacsInSpace/SecretManagement.LocalVault` as issues/PRs, never to the USM handover | - |

### To-do list, in order

1. **Arch trees** (above) - one commit once Craig says go. Then boot a Secure
   Boot client and watch `Sync-AppPxeBootBundledArchTftpTrees` stage all nine.
2. **Identity object + our 20 sites** (above). Start with `AppPaths.ps1` (x5)
   and `Ipc.ps1` (x1) - they are runtime core, so a clean copy is immediately
   useful to USM; then `Aria2Plugin`, `Aria2PxeIntegration`,
   `PxeBootTaskSequences`, the five vendor catalogs (one UA each via a shared
   `Get-AppUserAgent`), then the prose in `PxeBootPlugin.ps1` (47 hits, all
   comments and log strings).
3. **Confirm the app end to end on this Mac** after a fresh `npm run tauri:dev`:
   `SIDECAR STARTING` clears, Netboot shows the LAN IP, Sidecar Log shows the
   vault `already registered` line. Nobody has confirmed this in the **app**
   since `12bc591`; everything was verified over stdio and headless. When it is
   confirmed, delete `~/Library/Application Support/DeployKit.old-name.bak`.
4. **Handler gaps** (section 3 table): wire or cut
   `LoadLocalMachineCredentialToSession`; move `harvest_acer_sccm_urls` out of
   the sidecar union; decide the two macOS credential-cache commands alongside
   the `AppElevation` re-vendor.
5. **Site Profile** (section 5) - the main design task. 10 `TODO(Site Profile)`
   sites and the `{{SITE}}` / `{{LocalAdminPw}}` token expansion block on it.
   `GetSiteProfile` / `SetSiteProfile` are already in the command union.
6. **Phase-C first-boot runner** (section 2.3) - unblocks Applications and
   everything MDT did after the first reboot.
7. **WinPE client rewrite** (section 2.1) - grow `fieldiso/run.ps1` into the
   server-driven agent.
8. **Boot Images UI** over the existing wimlib overlay engine.
9. **Intune / Autopilot decision** - parked by Craig. Suggested: relabel the
   task-sequence option "None (clean OOBE)" and treat Autopilot hash harvesting
   as its own feature. Do not remove the Intune vendor-binary staging in
   `prepare-bundle-deps.ps1` until he decides.
10. **Secure Boot build dependency** - `ipxeboot` sibling is an undeclared build
    dependency of the byte-patched `snponly.efi` (section 6). Formalise it once
    the arch trees are in.

### Rules that bit us this week - read before writing code

- StrictMode: `$obj.missing` throws, `if ($null -ne $obj.missing)` throws too,
  `$x = [void](Fn)` never calls `Fn`, `@($null).Count` is 1, `Where-Object` on an
  emptying list yields `$null`. Section 6 and README "Code conventions".
- ASCII only, everywhere in the tree. No em dashes, no emoji, no smart quotes.
  The gate content-sniffs binaries, so it is safe to run on everything.
- Verbs never go in panel headers (section 4). Register them through
  `useConsoleActions`.
- Never edit `vendor/psmodules/**` or `vendor/psmodules.lock.json` by hand -
  edit the pin in the sync script and rerun it.
- USM's repo is read-only. `git -C` with absolute paths; never `cd` into it.
- Nothing Microsoft-licensed (`mdt-boot-x64/`, `wim-inject/`) is ever committed.

### How to check the state in one minute

```bash
git log --oneline -5
pwsh -NoProfile -File scripts/test-ascii.ps1
pwsh -NoProfile -File scripts/test-strictmode.ps1
pwsh -NoProfile -File scripts/test-storage-policy.ps1
pwsh -NoProfile -File scripts/sync-secret-vault-modules.ps1 -VerifyOnly
grep -rn "TODO(Site Profile)" sidecar/ app/src/ | wc -l          # 10
ls sidecar/pxe/x86_64-sb 2>/dev/null || echo "arch trees not copied yet"
cd app && npx tsc --noEmit
```


### 9b. Update 2026-08-22 (night) - items 1 and 2 done, by the USM agent working here

Craig: "Rather than run between 2 agents, can you continue and split WinDeployKit out
cleanly." So the USM agent worked in this tree directly. Local commits, **not pushed**:

| Commit | What |
| --- | --- |
| `eb6a28f` | **Arch trees** - all nine `sidecar/pxe/<arch>/` trees (37 files, 25 MB) byte-identical to USM main; every blob's git hash checked against USM's index; root `snponly.efi` untouched. Item 1 done; Craig's go was the instruction above |
| `7933b0b` | **Identity contract** - object, helpers, USM's three runtime files byte-identical, 20 sites + all prose converted, Ipc StrictMode-safe verbose gates. Item 2 done; the `AppElevation`/`AppNativeProcess` thread is closed (USM took them, de-identified, and they came back identical) |
| `79f6e26` | Data root = slug `windeploykit` on every platform (USM rule; we had no installed base) |

Gates after: ascii clean (234 files), strictmode clean, storage policy holds, psmodules
OK, tsc clean, stdio smoke (`Ping`, `GetSidecarStatus`, `GetSecretVaultStatus` ready /
6 secrets).

**Item 4 decision (the two macOS credential-cache commands):** USM's
`Handle-PrefetchMacOsAdminCredential` / cache-status handlers exist because USM's
Netboot panel shows the cached-admin state; nothing in this frontend references them
(`rg MacOsAdminCredential app/src` is empty), so they stay out until a panel needs
them. The functions are in `AppElevation.ps1` already; a handler is four lines when
the time comes.

**Still open:** item 3 (confirm the app end to end on this Mac after `npm run
tauri:dev` - not done in this pass), then 5-10 as listed. The contract's widened grep
(section 0) is the drift check to run before touching any lib USM also carries.

### 9c. Update 2026-08-22 (late night) - driver-catalog policy, saved-password fix

- **Driver catalogs** (Craig: "cached and checked only every 2 weeks, or manually; the old
  data should stay there during the fetch"): TTL 14 days in all five catalogs; cache
  files written tmp + Move-Item (a read landing mid-write used to fall back to the
  bundled catalog and the list shrank); `Start-AppVendorSccmCatalogAutoRefreshIfDue`
  runs from `Invoke-SidecarDispatchOnce` (first evaluation ~3 min after boot, then every
  30 min) and starts the existing background job for stale vendors only, at most once
  per 24 h, never while a refresh runs; the completion event carries `automatic: true`
  and `ContentWorkspace.tsx` reloads quietly (no toasts, no Acer harvest window) and
  shows "Catalogs checked N days ago". The list path was already cache-only.
- **`AppElevation.ps1`** (USM's, byte-identical here): a saved `local-machine/admin`
  credential is validated with `sudo -S -k /usr/bin/true` before it may replace the
  password dialog; once refused it is skipped for the session and the dialog explains
  why. `LocalMachineCredentials.ps1` passes `-Source 'vault'` when loading the cache and
  resets the rejection when a credential is saved. USM field bug 2026-08-22 (stale saved
  password: TFTP failed, no dialog).
- Gates: ascii, strictmode, parse clean; both harnesses pass here.

### 9d. Update 2026-08-22 (late) - driver pull-through retries, imaging-session id, worker UA fix

Mirrored from USM the same night (converged libs, ASCII-clean, all three gates green):

- `sidecar/lib/Aria2PxeIntegration.ps1`: the direct-download worker runs in a bare runspace and
  must not call any App* helper - the user agent is now passed in as its seventh argument (the
  convergence had put `(Get-AppUserAgent)` inside it, which made every pack download fail
  silently). New `$script:AppAria2DirectDownloadOutcomes` + `Get-AppAria2DirectDownloadOutcome`
  / `Test-AppAria2DirectDownloadActive` record the terminal state per progress key.
- `sidecar/lib/PxeBootDriverPullThrough.ps1`: the ledger reconciles `download-started` into
  `downloaded` / `download-failed: <why>` and retries a failed model once per NEW device or
  imaging session (serial + session differ), re-fetches when a pack leaves the disk, and
  re-checks `no-catalog-match` after 14 days. Rule from Craig: "Failed downloads should be
  marked and retried on the next of the same model."
- `sidecar/lib/PxeBootPlugin.ps1`: the imaging-log ingest stamps a `session` on each client
  snapshot (from the client payload when present, else host-derived, rolling over after 10
  quiet minutes); `Get-AppPxeBootImagingClients` exposes it.
- Decision tests live in USM (`sidecar/tests/PxeBootDriverPullThroughLedger.Tests.ps1`, 11
  cases, every dependency stubbed) - port them when this repo grows a Pester tree.
- Also mirrored: the direct-download worker writes `<name>.part` and the archive is renamed only
  after verified completion; the staging-recovery sweep skips active staging folders and archives
  modified in the last two minutes. A half-downloaded pack can no longer be promoted into the store.
- **Ingest bug found and fixed here (2026-08-22):** this repo's imaging-log ingest read the
  payload with `Get-AppSidecarJsonProp`, which lives in `Ipc.ps1` and does NOT exist inside the
  worker's bare runspace - every push threw "not recognized" and no imaging client could ever
  appear. Now uses the in-scriptblock `Get-IngestProp`, matching USM. Same class as the
  download-worker regression: nothing inside `[powershell]::Create()` + `AddScript` may call a
  sidecar function. Verified with a harness that starts the real listener and posts to it.
- Ingest also accepts a heartbeat push (`lines: []`, `heartbeat: true`): it advances the row's
  last-seen and keeps the previous last line, so a client parked at its deployment window stays
  visible and the driver pull-through can start fetching early. USM's deploy client sends one
  every 60 s; any client this repo bakes should do the same.
- Also mirrored: the Deploy$ share is now published on ANY imaging-services start (HTTP or TFTP).
  It used to be ensured only in the HTTP branch, so a TFTP-only start after a stop left the share
  torn down while the panel still showed it ticked - WinPE then fails with "network path not
  found". Panel guidance for "ticked but not published" rewritten to match.

### 9e. Update 2026-08-26 - Update Deployment Share / Restart Services; what Craig wants next

- Done: **Update Deployment Share** (Netboot node and the Deployment Share root) and
  **Restart Services** (Netboot, beside Start / Stop) - Action menu and both right-click
  menus via `consoleActions`, with the mid-image guard. Design, measurements and the
  `c5bb958` overlay regression it flushed out are in the dated section at the end of this
  file ("Update Deployment Share and Restart Services").
- Section 3's handler table re-measured: 83 commands, four without a handler.
- **Done the same day, on Craig's later instruction** ("make sure all assets will be
  included (except the isos ofc) and run a build and release (MacOS universal
  please)"): the bundle audit (dated section at the end of this file), the bundled
  default WinPE background, and **release v0.6.0** -
  `https://github.com/MacsInSpace/windeploykit/releases/tag/v0.6.0`, built from
  `282034a` (tag `v0.6.0`, clean tree), `WinDeployKit_0.6.0_universal.dmg` 31.7 MB,
  SHA-256 `1d7fd9aff6845e8fe3fd42ceda8dd27a4e4d6608e49a7d790d65dda583c968d7`, app
  notarised (id `25836e2c-...`) and DMG notarised (id `aa38cef6-...`), stapling
  Error 65 as documented. Incremental universal build + notarisation: about 4 minutes.
- **The "full code review before build" Craig asked for earlier was NOT done** - the
  later instruction went straight to build and release. Craig (2026-08-26, after the
  release): 0.6.0 is the right number because it has never been opened on a fresh
  Mac; he will do that himself; **the code review happens on his call - do not start
  it unasked.** The repo is private, so nothing has reached the public.
- Policy calls, answered by Craig 2026-08-26: `sidecar/pxe/mdt-boot-x64/` - "leave
  them, they are not needed" (LiteTouch WIMs are not a target; if the files are ever
  in the way, excluding them from the bundle is fine). The default background's
  licence/source is still to be recorded (`NOTICE.md` row).
- **Craig's order after the fresh-Mac test:** (1) a Windows build (needs a
  `tauri.windows.conf.json` carrying `vendor/binaries/pxe-windows/`, the Windows
  aria2 zips and `packaging/pxe-tftpd64.json`), then (2) Applications and the
  post-install steps of the Task Sequence (section 2.3's Phase-C runner is the
  dependency).

## 10. Windows evaluation media (Evaluation Center ISOs) - 2026-08-22

Craig's `GetWinISOs.ps1` rebuilt as a real feature, at the top of Operating Systems.
**Tested against the live pages before writing any code** - the answer to "I'm not 100%
it still works" is: the idea works, the script did not.

### What was broken in the original

| | |
|---|---|
| `and ($_.outerHTML -notlike "*ARM*")` | missing the `-`; the whole `Where-Object` was a runtime error |
| `-like "*Download Windows*(en-US)*"` on link text | current pages render the link text as just "64-bit edition" - matches nothing |
| `country=US` | pages now emit lower-case `country=us` |
| `Start-BitsTransfer` | Windows only |
| `$ISOs = "E:\ISOs"` | hardcoded |
| Windows 10 Enterprise | evaluation retired - that page has no download anchors at all |

### How the pages are parsed now

The only stable identity on the page is the anchor's `aria-label`:

    aria-label="64-bit edition: Download Windows 11 Enterprise ISO 64-bit (en-US)"
    aria-label="Download Windows Server 2025 Preview VHD 64-bit (en-US)"

`ConvertFrom-AppEvalIsoPage` matches that, decodes entities, and classifies media
(ISO/VHD), edition (Standard/LTSC), arch and culture. The catalog offers en-US x64 ISO
only. Gotchas that cost time: 2016/2019/2022 use `/fwlink/p/?linkid=` and encode `=` as
`&#61;`; a slug that does not exist yet answers 403/404, not a clean 404 only.

### Shape

- `sidecar/lib/EvalIsoCatalog.ps1` - product table (one row per release), parser,
  HEAD resolver (real file name + byte size + build/release), 14-day cache under
  `<data root>/plugins/aria2/eval-iso-catalog.json` with atomic writes, background
  refresh in a child pwsh, and `Start-AppEvalIsoDownload` on the direct-HTTP rail
  (`AssetKind 'iso'`, `ProgressKey "eval|<id>"`, 6 h timeout) so it works with the
  aria2 daemon stopped and promotes into Netboot's `iso/` store.
- `Get-AppEvalIsoCatalog` is **cache-only** - never scrapes on the dispatch thread
  (the old version blocked all IPC for up to 60 s per call).
- Housekeeping tick runs `Sync-AppEvalIsoCatalogRefreshJob` and
  `Start-AppEvalIsoCatalogRefreshIfDue` (first check 3 min after boot, then at most
  one cache read every 30 min, refresh only past the 14-day TTL).
- Handlers: `GetEvalIsoCatalog`, `RefreshEvalIsoCatalog`, `StartEvalIsoDownload` -
  all three call `Set-AppImageLibraryRuntimeRootFromParams` first, or "already
  downloaded" is decided against whatever root a previous call happened to push.
- UI: top of the Operating Systems images tab, with a "Check for updates" button, the
  cache age, and a footnote for releases that are retired or not published yet.

### Ready for Windows 12

The product table carries `probe` rows (`win12`) that are expected to return nothing:
a missing page is recorded as `not-published`, never as an error, and the row starts
working the day Microsoft publishes it. Adding another release is one line in
`$script:AppEvalIsoProducts`.

### Tests

- `scripts/test-eval-iso-catalog.ps1` - offline gate, 14 checks against real anchors
  captured under `scripts/fixtures/eval-iso/` (run it with the other three gates).
- `scripts/refresh-eval-iso-catalog.ps1` - live refresh/CLI listing.
- Verified 2026-08-22: 6 downloads offered (Win11 25H2 6.61 GB, Win11 LTSC 4.76 GB,
  Server 2025 7.59 GB, 2022 4.70 GB, 2019 5.26 GB, 2016 6.49 GB); a real fwlink
  streamed 544 MB in 8 s through the worker with the total size matching the catalog.

**PowerShell trap that bit the test harness:** a function returning a one-element
array unrolls it to the element, and `.Count` on a hashtable is its KEY count - "1
offered row" silently read as 9. Return `,@(...)` from helpers that must stay arrays.

### ARM64 (checked 2026-08-22)

Craig asked for ARM. **Microsoft publishes no ARM64 evaluation ISO** - zero ARM anchors
on all six Evaluation Center pages, and `download-windows-11-enterprise-arm64` and
friends 404. The only ARM64 Windows media is the consumer page
(`software-download/windows11arm64`, product edition 3324, "Windows 11 Arm64 25H2").

That page cannot be automated. Its current API (`/software-download-connector/api/`)
happily returns the 38 language SKUs, and then the link call is refused:

    {"Errors":[{"Key":"ErrorSettings.SentinelReject",
                "Value":"Sentinel marked this request as rejected.","Type":8}]}

i.e. Microsoft's anti-bot gate. Windows 10 22H2 sits behind the same wall. So:

- the catalog filter now accepts `x64` OR `arm64`, and the parser already classifies
  ARM64 labels - if Microsoft ever ships ARM eval media the row appears by itself
  (covered by a synthetic-anchor test);
- ARM64 and Win10 22H2 are listed as **manual sources** - a link under the table, with
  the reason in the tooltip. Netboot's ISO import takes them from there.

Do not re-attempt the consumer connector flow without new evidence; it is bot-gated by
design and would be a second fragile path to maintain (Craig's call).

### Download all (2026-08-22)

One button, and it is **sequential on purpose**: six evaluation ISOs is ~35 GB, and six
concurrent multi-GB streams on a school link finish nothing. `Start-AppEvalIsoDownloadAll`
starts the first and parks the rest in `$script:AppEvalIsoPendingQueue`;
`Sync-AppEvalIsoDownloadQueue` on the housekeeping tick starts the next only when no
`eval|*` download is active, re-checking the store each time (a row someone fetched by
hand in the meantime is skipped). Rows already in the store never queue. The button shows
the count and the total bytes, so nobody starts 35 GB by accident.

## 11. Windows Server evaluation -> licensed edition (2026-08-22)

Evaluation Center media installs as `ServerStandardEval` / `ServerDatacenterEval` and dies
after 180 days, so every seeded **Server** task sequence now carries a conversion step.
It is a no-op on anything that is not an evaluation edition.

### Why the hand-written original could not work

Craig's `ServerBaseActivationandSettings.ps1`, verbatim:

    If ($BuildNumber = 20348)              # ASSIGNMENT, not -eq: always true, and it
                                           # overwrites $BuildNumber. Every version block
                                           # ran, in order, on every machine.
    If ($TargetEdition = "ServerStandard") # same - Standard, Datacenter and Essentials
                                           # branches all ran.
    Dism /Set-Edition:ServerDataCentre     # not an edition id (ServerDatacenter).
    2019 Datacenter -> N69G4-...           # that is the 2019 STANDARD key.
    slmgr /ipk WVDHN-...-YY726C            # 26 characters, one too many.
    $CurrentEdition -Like "ServerStandard" # no wildcards, compared against a Caption -
                                           # every fallback branch was dead.

It appeared to work on 2022 Standard by luck: the first DISM call that matched won.

### What runs now

`sidecar/lib/ServerEvalConversion.ps1` (dependency-free, byte-identical in USM):

1. `DISM /online /Get-CurrentEdition` - ask, do not infer from `Win32_OperatingSystem.Caption`.
2. Act only when the edition ends in `Eval`; otherwise log and exit 0.
3. Target = the edition minus `Eval`, and `DISM /online /Get-TargetEditions` must actually
   offer it.
4. GVLK looked up by **(build, target edition)** from Microsoft's published list
   (learn.microsoft.com/windows-server/get-started/kms-client-activation-keys, 2026-08-22).
5. `DISM /online /Set-Edition:<target> /ProductKey:<gvlk> /AcceptEula /NoRestart`, logged to
   `C:\Windows\Setup\Scripts\eval-conversion.log`. No forced reboot - it lands on the
   next restart, which the join step causes anyway.

**It runs from SetupComplete.cmd, not the specialize pass**: `/Set-Edition` is a servicing
operation that wants a full OS, and SetupComplete runs as SYSTEM after setup and before
anyone can log on. The specialize step just drops the payload and appends the hook (it
never clobbers an existing SetupComplete.cmd).

### New step type: `pwshEncoded`

A whole script as one step, base64 (UTF-16LE) into `powershell.exe -EncodedCommand`. The
rendered unattend line contains **no quotes at all**, so nothing can break it, however
nested the script is - while the stored step stays readable text for the panel. Verified:
9174-char line, exact round-trip, valid XML.

### Keys corrected

`Get-AppPxeBootTsProductKeyDefault`'s server fallback was `8B2CN-7C8FB-QWPCQ-42WKG-724QW`,
which is **not a published GVLK** (it came across from the hand-written script). Server 2022
Standard is `VDYBN-27WPP-V4HQT-9VMD4-VMK7H`. A gate test asserts the 8B2CN key never returns.

### Client media is NOT convertible

`/Set-Edition` is a Server capability. Windows client Enterprise **Evaluation** cannot be
converted - Microsoft's documented answer is a clean install, and `/Get-TargetEditions`
offers nothing on a client eval. The GitHub trick doing the rounds
(`Switch-Windows-EnterpriseEval-to-Enterprise`) works by copying licensing SKU tokens into
`System32\spp\tokens\skus` from other media and then activating with MAS - build-specific,
unsupported, and not something to put on a fleet. Use volume/IoT LTSC media for clients;
evaluation client ISOs are for lab and imaging tests.

### Tests

`scripts/test-server-eval-conversion.ps1` (14 checks) - every case is a mistake the original
actually made. USM mirrors them in `sidecar/tests/ServerEvalConversion.Tests.ps1`.

### Operating Systems tab, corrected after first field use (2026-08-22)

Four things Craig hit, all fixed:

1. **Footnotes removed.** The "not published yet / evaluation retired / download and import"
   lines were noise on a corporate product. The data still exists (`products[].status`,
   `manualSources`) - it is simply not rendered.
2. **Never blank.** A refresh that found nothing used to wipe the offered downloads. A
   product with no rows now keeps its cached entries and reports `status = 'kept'`; only a
   genuinely empty product (Windows 10, probe rows) shows nothing, because it had nothing
   cached either. Proven by simulating a total network failure - all six entries survived.
   The 14-day TTL means the panel reads from cache for two weeks unless refreshed by hand.
3. **The row now updates when a download promotes.** It used to keep offering Download until
   the panel remounted ("it showed up after clicking away and back") because nothing reloaded
   the catalog on `aria2-promote`. Same bug fixed in USM.
4. **The torrent Catalog tab is gone; there is an ISO library instead.** WDK does not use
   torrents and had nowhere to see or import media, so a downloaded ISO was invisible even
   though it had landed correctly in the store. The images tab is now: Windows evaluation
   media -> **ISO library** (what is actually in `<image library>/iso`, with Import ISO...,
   Open folder and Remove) -> OEM OS (only when the manifest has entries) -> Transfers.
   The dead torrent UI (`imagesView`, `soeRows`, `torrentColumns`, `downloadTorrentRow`) is
   deleted; the sidecar keeps its torrent support for USM.

### Two field faults, 2026-08-22 evening

**"Unknown command: PrefetchMacOsAdminCredential" on every service start.** The panel warms
the macOS admin credential before anything that needs sudo, so the password dialog (or the
vault read) happens up front rather than mid-start. The handler had never been ported here,
so the ladder got no head start and the bottom of the window showed an error every time.
Added `Handle-PrefetchMacOsAdminCredential`, `Handle-GetMacOsAdminCredentialCacheStatus` and
`Handle-ClearMacOsAdminCredentialCache` to `handlers/Credentials.ps1` - the backing functions
were already in `AppElevation.ps1`.

**Handler load order is a trap.** `handlers/*.ps1` are dot-sourced at line ~68, and the main
script defines its own core handlers AFTER that - so a duplicate in `windeploykit-sidecar.ps1`
silently WINS over one in a handler file. `Handle-ApplyRuntimeConfig` already existed in the
main script; a second copy added in a handler file looked correct, parsed fine, and never ran.
Before adding a handler, grep BOTH places:

    grep -ho '^function Handle-[A-Za-z]*' sidecar/windeploykit-sidecar.ps1 sidecar/handlers/*.ps1

**"Nothing from the sidecar yet" on a healthy sidecar.** The log panel subscribed to stderr on
mount, so everything said before someone opened it was gone - boot, vault status, LAN
discovery, i.e. exactly the lines you open the panel to read. History now lives in
`lib/sidecarLogBuffer.ts`, started from `wireEvents()` at boot and kept whether or not anyone
is looking; the panel renders the buffer on mount. Pause freezes the view without dropping
lines, and Clear empties the shared buffer.

### Task sequences are corporate now, not site-shaped (2026-08-22)

Craig: "Computer name is free hand. As is Domain join, Domain creds, and OU. There is no
{{site}}." So:

- **Computer name** is published verbatim. The `{{SITE}}` prefix composition and its healing
  regexes are gone; `{{SERIAL}}` still fills on the device, so the default still names a
  machine after its BIOS serial.
- **Machine OU** is a typed DN. `{{SiteOu}}` substitution is gone.
- **Join domain** is a text box with suggestions, not a fixed list.
- **Domain join is an optional addition**: a "Join a domain" tick box reveals domain, OU and
  credentials, and clearing it wipes all three rather than leaving half a join behind.

**Domain suggestions come from DNS** (`Get-AppPxeBootTsDomainSuggestions`): the host's search
suffixes from `scutil --dns` / `/etc/resolv.conf` on macOS, `USERDNSDOMAIN` +
`SuffixSearchList` on Windows. Each is probed for `_ldap._tcp.dc._msdcs.<domain>` - the SRV
record every AD domain publishes - so a real domain is marked `(AD)` and sorts first. The
probe is bounded (`dig +time=2 +tries=1`) and memoised for 5 minutes, because it runs on the
single-threaded dispatch loop. Measured here: 421 ms cold, 4 ms cached.

Still open: a vault editor overlay, so join credentials can be created from inside the app
rather than only selected.

### Vault editor + join credentials from the vault (2026-08-22)

**Vault editor overlay** (`components/VaultEditorOverlay.tsx`, commands `ListVaultSecrets` /
`SetVaultSecret` / `RemoveVaultSecret`). The sidecar lists names and metadata and will write
or delete, but **never hands a value back to the UI** - a secret leaves the sidecar only when
a publish step needs it. That is what keeps "from the vault" different from typing a password
into a sequence, so the editor shows set/not-set and offers Replace, never Reveal. Names are
restricted to `[A-Za-z0-9._-]{1,128}`; a user name turns the entry into a PSCredential, which
is what a domain join needs (both halves).

**Join credentials now have three sources**, and the default stores nothing:

| value | behaviour |
|---|---|
| blank | fill at deploy time - `{{JoinDom}}/{{JoinUser}}/{{JoinPw}}` stay literal and the device supplies one coherent credential |
| `vault:<name>` | read from the shared vault at publish time and written into the unattend |
| credential-store id | the original path, unchanged |

A join account is not a LAPS-rotated local account, so nothing is ever stored in the sequence
file itself: "typed here" means "put it in the vault and reference it". A missing or
user-name-less secret logs and falls back to deploy-time fill rather than publishing half a
credential.

**Bug this uncovered:** `Get-AppPxeBootTsOobeShell -Accounts` was `[Parameter(Mandatory)]`
without `[AllowEmptyString()]`. Once the accounts block could legitimately be empty (no local
account, no profile password - the commonest corporate sequence), building the unattend threw.
Fixed in both repos.

### Netboot panel latency (measured, 2026-08-22)

Craig: "the PXE panels [are] slow". Profiled rather than guessed, and there was real fat.

`Get-AppPxeBootStatus` is polled every 8 s and cost ~700 ms EVERY call - almost all of it
shelling out for things that cannot change between two polls:

| per call | before | after |
|---|---|---|
| `Sync-AppPxeBootHttpProcessState` (lsof for the port) | 190 ms | 2 ms |
| `Get-AppPxeBootWimLibraryLayoutSnapshot` (file walk) | 151 ms | 0 ms |
| `Get-AppPxeBootLanIp` | 113 ms | 0 ms |
| `Get-AppPxeBootNetworkAdapters` | 64 ms | 0 ms |
| `Get-AppPxeBootImageLibraryShareStatus` (`sharing -l`) | 29 ms | 0 ms |
| **whole call** | **~700 ms** | **~200 ms** |

Whole Netboot panel command set, warm: 3074 ms -> 2251 ms.

`Get-AppPxeBootMemo -Key -Seconds -Producer` is the mechanism: run at most once per N
seconds, never cache a failure. TTLs are chosen against what the value means, not uniformly:
12 s for adapters and the LAN IP, 8 s for the share, 5 s for the WIM layout, and **1.5 s for
process liveness** - long enough to stop one status build probing the same port twice, short
enough that the next poll tells the truth. Start/stop services, share ensure/remove and ISO
import/remove all call `Clear-AppPxeBootMemo`, so a badge never lags an action the operator
just took.

Trap that bit me here: `Clear-AppPxeBootMemo` was first inserted immediately after
`function X {`, i.e. BEFORE `param()`. That parses, and then fails at runtime with "The
function or command was called as if it were a method" - PowerShell reads
`Clear-AppPxeBootMemo` followed by `param(` as a method call. Statements go after the param
block; `StopPxeBootServices` broke exactly this way and only an IPC round-trip caught it.

What is left: `GetPxeBootWimLibrary` (642 ms warm) and `GetPxeBootPluginConfig` (418 ms) both
still rebuild status-shaped data. Worth another look only if the panel still feels slow.

### "Image not on the share" - the orphaned ISO attach (2026-08-23)

Two boots in a row reached the share and the sequence, then stopped at
`Z:\.mounts\<token>\sources\install.wim` missing, while HTTP serving of the same
install.wim worked. Cause: the edition reader (install image catalog) had attached
the ISO at a temp dir in `/private/var/folders`, its detach failed quietly, and from
then on every Start *borrowed* that attach - fine for Caddy's `/iso-wim/` route, but
the SMB share needs the mount AT `.mounts/<token>` and nothing ever put it there.

Three rules now, all exercised by a live cycle (reader -> serve -> dismount ->
planted orphan -> serve re-homes it -> dismount; host ends with nothing attached):

- Anything that mounts an ISO on macOS mounts it at the canonical
  `.mounts/<token>` path, never a temp dir - so a detach that fails leaves the image
  where serving needs it.
- `Mount-AppPxeBootIsoReadOnly -MountPath X` re-homes an image attached anywhere
  else (detach by dev entry, attach at X) instead of borrowing it; a borrow is only
  for callers that do not care where it is.
- Detach is by dev entry and VERIFIED (`Disconnect-AppPxeBootAttachedIso`); the
  mount directory is removed only when the image is really gone, and the attach
  failure message now carries hdiutil's own reason.

`ConvertFrom-AppPxeBootHdiutilInfo` is a pure parser (pinned in the gate with the
real orphan record) and is deliberately self-contained: its first cut used
`Get-AppSidecarJsonProp` from lib/Ipc.ps1, which the sidecar loads and the gates do
not, so outside the app it returned nothing and the detach it fed never ran.

### Drivers and live logs from the cmd-only client (2026-08-23)

Craig: "WDK needs the same driver install injection as ImageDeployer (noting boot
wim doesn't have pwsh) - how are we installing drivers?" and "we are also not
getting any logs back". Both were gaps in the first cut of the deploy client.

- **Identity without wmic/PowerShell**: `reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS`
  gives SystemManufacturer/SystemProductName (the same SMBIOS strings as
  Win32_ComputerSystem). There is no serial in the registry, so the device id the
  panel files the log under is the first NIC MAC from `ipconfig /all`.
- **Pack lookup** mirrors ImageDeployer's search of `Z:\Drivers\<Make>\<Model>`:
  exact folder, model-starts-with-folder (Lenovo `21F...`), folder-contained-in-model
  (Acer), then `Z:\Drivers\aliases.txt` (`alias=Make\Folder`, exact - the JSON map
  the panel already writes, flattened because cmd cannot parse JSON), then `_default`.
- **Expand**: an INF tree is used in place; `.cab` via `expand.exe` (in every WinPE);
  `.exe/.zip/.7z` via `7z.exe`, which now rides in as an overlay initrd beside
  startnet.cmd. Without it such packs are reported and skipped, never half-applied.
- **Inject**: storage INFs (vioscsi/viostor) are `drvload`ed into WinPE BEFORE
  diskpart so a Proxmox VirtIO disk exists at all; after apply, the same
  `dism /Image:W:\ /Add-Driver /Recurse` call ImageDeployer and FieldIso make.
- **Live log**: `curl.exe` rides in the same way and every `:log` line POSTs the same
  JSON ImageDeployer sends to `/imaging-log/ingest`. Quotes become apostrophes and
  backslashes forward slashes - cmd has no escaping. Silent when curl is absent;
  `X:\Windows\Temp\deploy.log` is always written and copied into the applied image.
- **The tools now ship.** `scripts/prepare-bundle-deps.ps1` used to strip
  `sidecar/pxe/fieldiso/tools/*.exe|dll` as "maintainer-only"; a corporate install
  therefore had no 7z and no curl. They are kept now (LGPL / curl licence - see
  `sidecar/pxe/deploy-client/THIRD-PARTY.txt`). Still nothing is downloaded at runtime.
- **Mounts are re-asserted, not assumed.** The first real boot stopped at "Image not
  on the share": `hdiutil detach` is host-global, and a test harness calling Stop
  took the live app's ISO mounts away while its share stayed up.
  `Sync-AppPxeBootInstallWimMounts` (housekeeping, 20s) re-mounts anything missing
  while this process is serving. Lesson for agents: never run Start/Stop against a
  host where the app is live - use the gates' temp dirs.

### How a corporate user's boot.wim installs install.wim (2026-08-23)

Craig: "When a corporate person downloads WDK, how is the install.wim installed via
the boot.wim? You seem to forget corporate will not have FieldIso.wim." Correct - and
before this there was NO answer: FieldIso is USM lineage (needs an ADK PowerShell
tree), and an imported stock boot.wim booted to `wpeinit` and a prompt.

The answer is `sidecar/pxe/deploy-client/startnet.cmd`, and it is an **overlay, not a
bake** (Craig: "can't this just be an overlay rather than rewriting every and any
boot.wim that is imported?"):

- The `deploy-share` profile lists it as a Runtime entry. Caddy serves it from
  `http/deploy/`, iPXE adds `initrd -n startnet.cmd ...`, and wimboot drops it into
  WinPE's System32 - shadowing the WIM's own `startnet.cmd`. The WIM on disk is
  byte-identical to what was imported; `Sync-AppPxeBootWimOverlays` bakes nothing.
- It is **cmd-only on purpose**. A stock Windows boot.wim ships dism, diskpart,
  bcdboot, net and robocopy, and ships NO PowerShell and NO curl (checked with wimlib
  on the Server 2025 boot.wim). Anything richer means an ADK - a download, a licence
  and a Windows box. `test-deploy-overlay` fails if the client ever invokes
  powershell/pwsh/curl.
- The chain: wpeinit -> `net use Z:` with deploy.cred -> `_default.txt` (or
  `deploy.tsid` from iPXE) -> `Z:\TaskSequences\<id>.env` -> diskpart (GPT, EFI 260M,
  MSR, Windows; asks for WIPE unless `deploy.autoprep` is present) ->
  `dism /Apply-Image` with the sequence's index -> `bcdboot /f UEFI` -> copy
  `<id>.xml` to `Windows\Panther\unattend.xml` -> `wpeutil reboot`. Every failure
  drops to a prompt with the reason and `X:\Windows\Temp\deploy.log`; never a reboot loop.
- `<id>.env` is published beside `<id>.xml` because cmd cannot parse JSON: KEY=VALUE,
  CRLF, `for /f "tokens=1,* delims=="`. index.json stays for clients that can.
- Config `deployClientInject` (default on) removes the served file when off; the
  entry is not Required, so the share/cred files still inject and WinPE runs its own
  startnet.cmd.
- Published with CRLF regardless of what git did to the source: cmd.exe skips `goto`
  labels and leaves a stray CR in `for /f` tokens on an LF-only batch file.

Not yet booted on hardware - the generated boot.ipxe carries the four initrd lines
and the .env is on the share with the Server 2025 binding; the next Proxmox boot is
the real test.

### A task sequence names its own install.wim (2026-08-23)

Craig: "The task sequence should have the Install.Wim so we can selact it in the Task
Sequence." Before this, a sequence described only what happened AFTER the image landed,
and the image itself was whatever ISO the device booted.

- `sidecar/lib/PxeBootInstallImages.ps1` lists sources (every ISO in `<library>/iso`,
  every WIM/FFU in `<library>/WIMs`) and reads their editions with `wimlib-imagex info`.
  Reading needs the ISO mounted, so it happens **once per file, ever**: the parsed list
  is cached in `<store>/install-images.json` keyed by name+size+mtime, and an ISO that
  Netboot already has attached is borrowed, never re-attached. A panel load only does a
  directory listing plus a JSON read; the "Read editions" button asks for the rest.
- A sequence stores `image = { sourceId, index, editionName }`. `sourceId` is
  `iso:<file>` or `wim:<file>`; anything path-shaped is dropped rather than published.
- Publishing writes `TaskSequences/index.json` next to the unchanged `<id>.xml` files -
  a client that only globs `*.xml` keeps working. Each row carries `sharePath`
  (`.mounts\<token>\sources\install.wim`, for a client on Deploy$) and `httpPath`
  (for an HTTP-only client). `updatedAt` is excluded from the change comparison so a
  re-save does not rewrite a watched file.
- Caddy now serves `/TaskSequences/*` so an HTTP-only client can read it.
- FieldIso (`sidecar/pxe/fieldiso/run.ps1`, v15) picks the sequence named in
  `System32\tasksequence.id` or the published default, applies **its** image and index,
  and drops the sequence's unattend into `<applied>\Windows\Panther\unattend.xml`.
  It rebuilds the URL from `httpPath` against the host it is already talking to -
  `httpUrl` in the index is the iPXE form and can contain a literal `${next-server}`.
- **Array-return convention**: these functions emit ONE array object (`, $entries`) so an
  empty result survives as an empty array. Call them as `$x = f` then `@($x)`; writing
  `@(f)` nests the array one level deeper and every lookup silently misses. That bug hit
  the handler, the payload and the gate before the gate pinned it.

Gate: `scripts/test-install-images.ps1` (16 checks) - wimlib parsing, binding
validation, resolution, and the client half lifted out of run.ps1's AST.

### Extracting a boot WIM from an ISO (2026-08-22)

"I cant extract a boot wim from an ISO." The log told the whole story once it arrived:

    PXE boot: installing 7zip 17.06 ... (GitLab HTTPS once per Mac)
    PXE boot: p7zip install failed - nodename nor servname provided (artifacts.example.com:443)
    PXE boot: ListPxeBootIsoWims failed - PXE boot: failed to mount ISO (hdiutil).

Three faults, all fixed:

1. **The ISO was already mounted.** Netboot attaches every ISO in the store to serve
   install.wim in place, and macOS refuses a second attach of the same image ("Resource
   busy"). `Get-AppPxeBootAttachedIsoMountPoint` now finds the existing mount and
   `Mount-AppPxeBootIsoReadOnly` borrows it, marking the result `borrowed` so
   `Dismount-AppPxeBootIso` never tears down a mount Netboot is serving from.
   Parse `hdiutil info -plist` through `plutil -convert json` - the first attempt walked
   `$xml.plist.dict.array.dict` and silently found nothing.
2. **No GitLab downloads here** (Craig). `Ensure-AppPxeBootP7zipTools` used to fetch a pinned
   p7zip from the product asset feed, which in this product is a placeholder host - so every
   ISO read spent ~10 s on a DNS failure before falling back. It now looks for a system 7z
   and otherwise says plainly that ISOs are read by mounting. Nothing needs the download:
   macOS has hdiutil, Windows has Mount-DiskImage.
3. **The import threw AFTER succeeding.** The response read `$bootAssets.packaged` directly;
   `Ensure-AppPxeBootWimBootAssets` has early-return shapes without that key, so StrictMode
   threw once the WIM was already copied - the operation looked like it failed while the file
   sat in the library. Read through `Get-AppSidecarJsonProp` now.

Verified from a clean state: `sources/boot.wim` and `sources/install.wim` list, and the
extract produces a 610 MB `Server2025-boot.wim` with `bootAssetsReady=True`.

Also: the Sidecar Log gained a **Copy** button (and explicit `user-select: text`), because
"I cant copy paste from Sidecar" - it copies exactly what is on screen, filter included.

### Update Deployment Share and Restart Services (2026-08-26)

Craig: an "Update Deployment Share" verb - "people know it" from MDT - in the Action menu
and the right-click menu, tied to all the rebuilding: overlay, task sequence publishing,
a refetched IP, "all the healing". And: "this should not interrupt imaging in flight",
so restarting services is separate - "everything minus the services". Two verbs, one rule:
**Update touches files, Restart touches processes.**

| Verb | Where | Sidecar | Does | Safe mid-image? |
| --- | --- | --- | --- | --- |
| Update Deployment Share | Netboot and the Deployment Share root (`consoleActions` items - the shell puts every item in Action and both right-click menus) | `UpdatePxeBootDeploymentShare` -> `Update-AppPxeBootDeploymentShare`, inline | Fresh LAN IP (memos cleared); store layout; bundled boot assets (hash-compared); per-WIM boot assets; Deploy$ re-ensured while a service is up; task sequences to `Z:\TaskSequences`; `boot.ipxe` / `menu.ipxe` / TFTP menu + autoexec; the deploy overlay; ISO mounts re-asserted while HTTP serves | Yes. Nothing is killed, started, dismounted or unshared |
| Restart Services | Netboot, beside Start / Stop | `RestartPxeBootServices` -> `Restart-AppPxeBootServices` = `Stop -Minimal` then `Start`; same child-pwsh rule and same `pxe-services` job name as Start, so the panel's one `job-finished` path serves both | Caddy and dnsmasq/tftpd64 down and back on the fresh IP. Start regenerates every served file on the way up, so Restart = Update + the bounce | No for a device still booting (menu, boot.wim). An apply already reading `Z:\` carries on: `-Minimal` leaves the share and the ISO mounts alone (host-named and path-named - neither carries the IP); only its log pushes during the bounce are lost |

The mid-image guard lives in the sidecar, not the panel. Without `force` the handler
counts `Get-AppPxeBootImagingClients` rows with `active` (a log push or heartbeat in the
last 3 minutes), answers `{ blocked, imagingClientsActive, clients[] }`, and the panel
opens a danger `ConfirmModal` naming serial / model / IP and calls again with
`force: true`. The panel's own 8 s status poll is not trusted for this - a device can
start between polls.

What a file rewrite cannot fix comes back as `restartReasons` and a "Restart Services to
finish" toast: dnsmasq bakes `dhcp-boot=<file>,<ip>,<ip>` into its config and does not
re-read it, so after a network move TFTP/proxyDHCP still names the old address; and an ISO
mounted after HTTP came up has no `/iso-wim/<token>/` route, because routes are written
into the Caddyfile at HTTP start. Caddy itself needs neither - it listens on `0.0.0.0` and
its Caddyfile names no LAN IP. (`Get-AppPxeBootServiceRestartReasons`.)

Measured over stdio against an isolated HOME with an empty store: Update 5.9 s the first
time on a fresh store (staging snponly, wimboot, 24 MB of arch trees and the deploy
client), **1.05 s warm**. It was 2.0 s warm until the `Get-AppPxeBootStatus` at the end
(1.1 s of it) was dropped: the Netboot panel calls `reloadConfig()` right after the verb
and the share root's badges ride the 8 s poll, so the result carries no status and clears
the memos instead. Inline on purpose, unlike Start: the macOS share ensure may need the
admin dialog from this process, and re-asserted ISO mounts must land in this process's
`IsoMounts`. Not exercised: the `force` restart - a real dnsmasq was live on this Mac and
Stop would have reached it (the rule under "Image not on the share": never Start/Stop
against a live host). The guard path was: a fake `imaging-logs/FAKE1.json` seconds old,
`RestartPxeBootServices` -> `blocked: true`, `clients[0].serial = FAKE1`.

**Regression found and fixed on the way.** Since `c5bb958` (FieldIso removal, 2026-08-24)
nothing on the Start path called `Write-AppPxeBootWimOverlayRuntimeAssets`; the only
callers left were the four branding handlers and the housekeeping refresh, which needs
the files to exist first. A fresh store therefore never got `http/deploy/` and an imported
WIM booted to a bare WinPE prompt - it kept working on the dev box only because the files
were already there. The publish now sits in `Write-AppPxeBootMenuFiles`, before the initrd
lines that depend on `deploy.unc` existing, so Start, Update, Restart, config save and
every import go through it. Confirmed on the isolated store: `deploy.unc`, `loghost`,
`startnet.cmd` and the tools appeared on the first Update. (`Write-AppPxeBootMenuFiles`
also grew `-SkipTaskSequenceSync` so Update can take the publish count without running the
sync twice.)

Craig floated "Update Deployment Share & Restart Services" as the destructive verb's name,
so the label itself warns. Not done: Start regenerates everything, so that verb and
"Restart Services" would be one action under two names, and section 4 wants one verb per
action in MDT/ADUC wording. The confirm carries the warning instead, and only appears when
a device is actually mid-image. If the longer label is wanted anyway it is the one string
in `PxeWorkspace.tsx` ("Restart Services").

### Bundle audit and the 0.6.0 build (2026-08-26)

Craig: "make sure all assets will be included (except the isos ofc) and run a build
and release (MacOS universal please)". The audit (an Explore agent over
`tauri.conf.json`, the staging scripts, `sidecar.rs` and every project-root read in
`sidecar/**`) found the packaged app shipped **`sidecar/` and nothing else**:

- `scripts/prepare-bundle-deps.ps1` and `scripts/package-macos.sh` are ports from
  another product that cannot run here (missing `scripts/lib/BuildDownload.ps1`,
  `load-local-env.sh`, PSOpenAD, Posh-SSH, eduHub, email banners...), and nothing
  called them anyway - `beforeBuildCommand` is `npm run build`. Both now carry an
  INERT header. What ships is `bundle.resources` in `tauri.conf.json`, full stop.
- Fatal at first launch, all fixed by the resources map: no `vendor/psmodules`
  (vault threw), no `packaging/pxe-caddy.json` (HTTP could never start - the asset
  feed is empty), no dnsmasq / wimlib / password dialog, no SCCM catalogs.
- `Aria2Plugin.ps1` could never install aria2 on macOS (manifest has no URL; the
  `vendor/aria2-tools/` archive was unread) - it now has p7zip's bundled-archive
  fallback, **but the archive is not bundled**: notarisation unpacked it and
  rejected the unsigned `aria2c`, and that `aria2c` is a Homebrew bottle linked to
  `/opt/homebrew/opt/*` dylibs - it runs only where Homebrew's aria2 already is.
  macOS aria2 needs a static build before the fallback means anything; until then
  `Get-AppAria2BinaryPath` finds Homebrew's on PATH. `VendorSccmCatalogRefresh.ps1` dot-sourced `lib/NpsLogViewer.ps1` (a
  USM file we never had) as its first statement under `Stop`, so **every**
  background catalog refresh had been exiting 1 - line removed.
- The three vendored universal Mach-O binaries are Developer ID signed in place
  and committed (notarisation refuses unsigned executables in the bundle).
- Version was 0.1.0 / 0.5.3 / 0.1.0 across the three files; now 0.6.0 in four
  (Cargo.lock too). `tauri:build:universal` script added; DMG target added.

Still open from the audit, none blocking the build:
- `sidecar/pxe/mdt-boot-x64/` (gitignored Microsoft boot files) is on Craig's Mac
  and rides into every build made here via `../../sidecar/`. Policy call.
- A Windows build needs `vendor/binaries/pxe-windows/`, the Windows aria2 zips and
  `packaging/pxe-tftpd64.json` - a `tauri.windows.conf.json`, not the base map.
- `.gitignore` still names `sidecar/pxe/fieldiso/...` (gone; tools live in
  `sidecar/pxe/tools/`); `packaging/pxe-fieldiso.json` and
  `packaging/pxe-optional-assets.json` (read at `PxeBootPlugin.ps1` ~4203, never
  existed) are orphans. `AGENT_NOTES` "aria2 ships in vendor/aria2-tools/" was
  true only once the fallback above existed.
- `LoadLocalMachineCredentialToSession` is a dead union entry (section 3 table).

- Module robustness item (for the SecretManagement.LocalVault repo, not here):
  `LocalVault.Core.ps1` runs `& ioreg` by bare name; under a PATH without
  `/usr/sbin` the machine key cannot be derived. launchd's default PATH has it,
  so the packaged app works; `/usr/sbin/ioreg` would remove the dependency.

Details of the build itself: `docs/AGENT_NOTES_MACOS_BUILD.md`, "WinDeployKit
specifics".


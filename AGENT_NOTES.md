# Agent notes - WinDeployKit

**Read this first.** It is the handover for a fresh session: what this project
is, where it came from, what is decided, what works, and what is booby-trapped.

**Last updated:** 2026-08-21

---

## 0. Orientation - read this before touching anything

| Fact | Value |
| --- | --- |
| Project root | `/Volumes/Data/projects/windeploykit` |
| GitHub | `MacsInSpace/windeploykit` (**private**, empty - nothing pushed yet) |
| Git | on `main`; initial commit `75d3f25` landed 2026-08-21 |
| App data (macOS) | `~/Library/Application Support/WinDeployKit` |
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

`/Volumes/Data/projects/stmc-manager` ("USM") is the app this was extracted
from. It is **under active development by the user**.

> **Never modify, never `git checkout`, never `git stash` in that repo.**
> Copy out of it only. If you find a bug there, write it up in
> `usm-reference/HANDOVER_TO_USM_AGENT.md` - do not fix it in place.

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

### Identity injection - contract proposed, not yet agreed

The domain libs hardcode product identity, which is why a cross-repo diff is ~90%
noise and hid three real bugs for a day. The fix is one `$script:AppProductIdentity`
object set by the host sidecar before any lib is dot-sourced (same constraint as
`$script:AppSidecarProjectRoot`), with fields `DisplayName` / `Slug` / `BinaryName`
/ `UserAgentToken`, and the rule that **a domain lib contains no product literal at
all**.

Our functional surface is **20 sites** (`AppPaths` x5, `Aria2Plugin` x3, one
User-Agent per vendor catalog, `Ipc` x1, `PxeBootTaskSequences` x1,
`Aria2PxeIntegration` x1); ~53 further mentions are prose and are being left alone.

**Field names are with USM for agreement - do not start coding this until they
confirm.** Both sides implementing different shapes is the failure this prevents.
Full proposal and rationale in `docs/handover/HANDOVER_TO_USM_AGENT.md`.

**Explicitly NOT shared: the frontend.** WinDeployKit is corporate - no themes,
no arcade, no personality. USM keeps all of that. Panels, theme system and
`index.css` diverge by design; the sharing boundary is the sidecar domain libs
only. Do not try to reconcile the UI.

---

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

### Carried in from USM, 2026-08-21 (see `usm-reference/HANDOVER_TO_USM_AGENT.md`)

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
| Sidecar Log | Placeholder |
| Deployment Share (root) | Placeholder |

### Shared secret vault (built 2026-08-21)

Credentials live in the **shared secret vault** defined by USM's
`SHARED_SECRET_VAULT_CONTRACT.md` - one per-user store shared by USM,
WinDeployKit and PSOpenAD-FE, the SecretManagement API in front, and
**no OS credential UI** behind it (no Keychain, no Credential Manager,
no secret-tool). Craig closed section 6 as **Option B**.

| Piece | Where |
| --- | --- |
| Vault module (USM owns) | `sidecar/psmodules/SecretManagement.LocalVault/` - vendored **byte-identical**, 5 files. Do not edit here; fixes go through the handover channel |
| API module | `vendor/psmodules/Microsoft.PowerShell.SecretManagement/1.1.2/`, pinned in `vendor/psmodules.lock.json` |
| Sync + drift check | `scripts/sync-secret-vault-modules.ps1` (USM's copy, verbatim; `-VerifyOnly` for CI) |
| Our glue | `sidecar/lib/AppSharedSecretVault.ps1` |
| Handlers | `sidecar/handlers/Credentials.ps1` - the 7 commands that had none, plus `GetSecretVaultStatus` |
| Tests | `sidecar/tests/SecretManagementLocalVault.Tests.ps1` (USM's, byte-identical). 24/24 pass on macOS |

Names we use, from contract section 3:

- **`netboot/join/<id>`** - ours to write. Task-sequence domain-join and Deploy$
  share credentials.
- **`local-machine/admin`** - read. **UserName IS the login** (e.g. `st00447`),
  not a tag.
- **`dept/edu001`** - read-only *unless* USM has no legacy `DeptCredentials.xml`.
  That file is the source of truth while `Set-DeptCreds`-era tools exist and USM
  refreshes the vault from it, so writing over it is pointless - USM wins on its
  next read. When no file exists, a sign-in here IS adopted and promoted by USM.

Rules that are not negotiable:

> Registration is **by full path**, once at startup, guarded. There is no reset
> concept in this vault - the SecretStore bootstrap that had one was withdrawn
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

> **`pushImageLibraryRoot()` is now called at startup** (`App.tsx`). Nothing called
> it before, so the sidecar never learned the configured root and always fell back
> to the default regardless of the setting. If the Deploy$ base ever appears to be
> ignored, check that call first.

### Unwired - code exists, nothing reaches it (found 2026-08-21)

These are **incomplete ports, not residue**. Do not delete them; finish them.

| Gap | Evidence | Consequence |
| --- | --- | --- |

12 of the 67 commands in `types.ts` have no handler: the 7 credential ones above,
`ClearMacOsAdminCredentialCache`, `PrefetchMacOsAdminCredential`,
`DeleteInfraSshCredential`, and `GetSiteProfile`/`SetSiteProfile` (expected - section 5).

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
| TFTP root, boot WIMs, `wimboot`, `snponly.efi`, configs, logs | **App data** - `~/Library/Application Support/WinDeployKit` / `%LOCALAPPDATA%\WinDeployKit` | Small, fixed, machine-local. Must be where the services expect it |
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
- **Secure Boot cannot work yet - the arch trees are not in this repo.**
  `vendor/binaries/pxe-secure-boot-x64/` is README-only and `sidecar/pxe/x86_64-sb/`
  does not exist, so `Sync-AppPxeBootBundledArchTftpTrees` has nothing to stage
  while the default Option 67 (`x86_64-sb/shimx64.efi`) points at that path.
  The staging code is correct and ported; the **binaries** must be fetched from
  the `ipxeboot` sibling via `scripts/fetch-pxe-secure-boot.ps1`. Don't read
  "arch staging ported" as "Secure Boot works".
- The Secure Boot iPXE chain builds from a **sibling repo**,
  `/Volumes/Data/projects/ipxeboot`. Undeclared build dependency; formalise it.
- The bundled `snponly.efi` carries a **byte-patched embed** (an upstream WAN
  fallback removed). The ipxeboot source embed still needs the matching change
  at next rebuild.
- `packaging/aria2-tracker.json` is an **empty skeleton** - the original catalog
  was org-specific and was removed. Point `manifestUrl` at your own artifact
  host. **7 URL constants** across `sidecar/lib/` still reference
  `artifacts.example.com` - grep for it.

---

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
4. Highest-value next steps, in order:
   1. **Site Profile** (section 5) - unblocks 10 `TODO(Site Profile)` sites and the
      task-sequence token expansion
   2. **Phase-C first-boot runner** (section 2.3) - unblocks Applications and everything
      MDT did after the first reboot
   3. **WinPE client rewrite** (section 2.1) - grow `fieldiso/run.ps1` into the agent
   4. Boot Images UI over the existing overlay engine
5. Commit early and often - the tree is committed now, so keep it that way.

# Agent notes — WinDeployKit

**Read this first.** It is the handover for a fresh session: what this project
is, where it came from, what is decided, what works, and what is booby-trapped.

**Last updated:** 2026-08-21

---

## 0. Orientation — read this before touching anything

| Fact | Value |
| --- | --- |
| Project root | `/Volumes/Data/projects/windeploykit` |
| GitHub | `MacsInSpace/windeploykit` (**private**, empty — nothing pushed yet) |
| Git | initialised on `main`; **no commits yet** — the whole tree is still staged/untracked |
| App data (macOS) | `~/Library/Application Support/WinDeployKit` |
| Bundle id | `com.macsinspace.windeploykit` |
| Dev server | Vite on **42410** (HMR 42411) |
| Sidecar entry | `sidecar/windeploykit-sidecar.ps1` |

**The project has been renamed twice**: `psd-ui` → `deploykit` → `windeploykit`
(2026-08-21). If you find a stale `deploykit` or `psd-ui` reference anywhere,
it is a leftover — fix it. `~/Library/Application Support/DeployKit.old-name.bak`
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

### The upstream project is READ-ONLY

`/Volumes/Data/projects/stmc-manager` ("USM") is the app this was extracted
from. It is **under active development by the user**.

> **Never modify, never `git checkout`, never `git stash` in that repo.**
> Copy out of it only. If you find a bug there, write it up in
> `usm-reference/HANDOVER_TO_USM_AGENT.md` — do not fix it in place.

---

## 1. What this is

An extraction of the **Netboot** and **Downloads** plug-ins from a
school-IT-specific internal tool, made generic, to replace the retired Microsoft
Deployment Toolkit. See `README.md` for the product-facing story.

The extraction is done. The generic-isation is done. What remains is finishing
the UI and rewriting the WinPE client.

---

## 2. Locked decisions — do not relitigate

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
   (`reg | cmd | pwsh | app…`) tagged by phase:
   - **A. WinPE agent** — disk prep, apply, driver install, plant unattend + runner
   - **B. specialize** — unattend `RunSynchronous` (the existing generator)
   - **C. first-boot runner** — planted by the agent, runs the rest in full
     Windows, reports to the same log endpoint, self-removes.
     *Phase C does not exist yet.* It is the highest-value missing piece — it is
     where the Applications layer will plug in.
4. **Boot images: any Windows ISO + wimlib overlay**, with a **build-match rule**
   — `sidecar/pxe/fieldiso/wim-inject/` carries SOFTWARE and COMPONENTS registry
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
7. **UI: MDT Deployment Workbench.** See §4.
8. **Live data, not cached.** See `docs/DATA_FRESHNESS.md`.
9. **No plug-in registry, no theme packages.** Both were inherited and both were
   deleted. Every node always exists; there are exactly two colour modes.

---

## 3. Current state — what actually works

### Verified working (2026-08-21)

- `npm run tauri:dev` launches; Rust and frontend both build clean; `tsc --noEmit`
  is clean.
- Sidecar starts, and **all 10 panel commands return ok**:
  `GetPxeBootPluginStatus`, `GetPxeBootPluginConfig`, `GetPxeBootWimLibrary`,
  `GetPxeBootTaskSequences`, `GetAria2TrackerCatalog`, `GetAria2PluginConfig`,
  `GetPxeBootImagingClients`, `GetPxeBootLogTail`, `GetEvalIsoCatalog`,
  `GetAria2Downloads`.
- LAN adapter detection works (`lanIp` resolves).
- Vendor driver catalogs load — **1,456 driver rows** from the bundled JSON.
- Console tree navigates; each node renders only its own sections; zero console
  errors in a headless browser check.

### Panels

| Node | State |
| --- | --- |
| Netboot | **Wired** — services, DHCP options 66/67, adapter/port/mode |
| Boot Images | **Wired** — boot WIM library |
| Operating Systems | **Wired** — OS image catalog + acquisition |
| Out-of-Box Drivers | **Wired** — vendor catalogs + driver store |
| Task Sequences | **Wired** — sequence editor |
| Monitoring | **Wired** — PXE log + imaging clients, both clearable |
| Transfers | **Wired** — download client |
| Applications | Placeholder (deferred, §2.6) |
| Site Profile | **Placeholder — needed**, see §5 |
| Sidecar Log | Placeholder |
| Deployment Share (root) | Placeholder |

### Not built yet

- Phase-C first-boot runner (§2.3)
- The WinPE client rewrite (§2.1)
- Site Profile (§5) — several TODOs block on it
- Boot-image creation UI over the existing wimlib overlay engine

---

## 4. UI rules (enforced)

Governing doc: **`docs/WINDEPLOYKIT_App_StyleGuide.md`**. Direction and the MDT
node mapping: `docs/UI_DIRECTION.md`.

The short version — violating any of these is a defect:

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
app/src/components/navConfig.ts   the console tree (a plain array — no registry)
app/src/panels/<Node>Panel.tsx    one thin file per node; routing + title
app/src/workspaces/               shared state containers; panels render sections
```

Nav order is **deployment order, not MDT's**: Netboot (owns the services) → Boot
Images (what they serve) → Operating Systems → Out-of-Box Drivers → Applications
→ Task Sequences → Monitoring.

The two workspaces are shared because the state genuinely is (one config poll,
one status poll feed several nodes). `PxeWorkspace` takes a `sections` prop;
`ContentWorkspace` takes a `tabs` prop. A section that owns its whole panel
(`solo`) hides its heading and disclosure caret — the panel title already says it.

**Sibling project:** `/Volumes/Data/projects/PSOpenAD-FE` shares this exact design
system (`docs/PSOPENAD_FE_StyleGuide.md`), adapted for ADUC. Style-guide changes
belong in both.

---

## 5. Site Profile — the main outstanding design task

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
**deliberately** — so token expansion fails loudly rather than publishing a
wrong-but-plausible value. Do not "fix" that by adding fallbacks.

> **Security note:** the upstream version fell back to two hardcoded department
> bench passwords (base64-obscured). Those were **removed**. Never reintroduce a
> hardcoded credential fallback.

---

## 6. Traps and gotchas

### Silent `catch { }` blocks

Ported code is full of bare `try { … } catch { }` with empty handlers —
**40 of them in `PxeBootPlugin.ps1` alone**. During the port, a missing function
inside `Get-AppPxeBootNetworkAdapters` produced
**"No LAN IP" with no log line at all** and took a direct function call to
diagnose.

> If something fails inexplicably, **look for an empty catch first.** Consider
> making them `Write-SidecarLogVerbose` instead of discarding.

### `[bool]` vs `[switch]` parameter binding

A `[bool]` parameter cannot take a bare `-Param`; it needs `-Param $true` or
`-Param:$true`. Upstream had two instances; one broke the entire driver catalog
whenever the manifest host was unreachable. Fixed here. The scanner that finds
them is in `usm-reference/HANDOVER_TO_USM_AGENT.md`.

### `$script:AppSidecarProjectRoot`

Must be set **before any lib is dot-sourced** — ~20 call sites resolve
`vendor/binaries` and `packaging/*.json` through it. The sidecar bootstrap does
this; if you write a new entry point, do it there too.

### Other

- **Never edit `usm-reference/` originals** expecting it to affect the build —
  they are reference copies, not sources.
- `wim-inject/` (615 MB) is gitignored: ADK-derived WinPE system files, EULA-scoped.
- `vendor/binaries/pxe-mdt-boot/` and `sidecar/pxe/mdt-boot-x64/` are Microsoft
  boot binaries — gitignored, never redistribute.
- The Secure Boot iPXE chain builds from a **sibling repo**,
  `/Volumes/Data/projects/ipxeboot`. Undeclared build dependency; formalise it.
- The bundled `snponly.efi` carries a **byte-patched embed** (an upstream WAN
  fallback removed). The ipxeboot source embed still needs the matching change
  at next rebuild.
- `packaging/aria2-tracker.json` is an **empty skeleton** — the original catalog
  was org-specific and was removed. Point `manifestUrl` at your own artifact
  host. **7 URL constants** across `sidecar/lib/` still reference
  `artifacts.example.com` — grep for it.

---

## 7. Conventions

- **Sidecar IPC**: one JSON object per line on stdin
  (`{"id":N,"cmd":"Name","params":{}}`); responses NDJSON on **stdout only**;
  all human logging to **stderr**. Commands resolve by convention —
  `"Foo"` runs `Handle-Foo`. Adding a command = adding a function.
- **PowerShell**: pwsh 7 compatible, `Set-StrictMode -Version Latest`. Watch two
  known traps — `ConvertFrom-Json` hydrates ISO-8601 into `[DateTime]`, and
  parameter names that collide with automatic variables.
- **Verify by running, not by reading.** The sidecar can be driven from a shell
  (see README). The frontend can be checked headlessly for console errors. Every
  claim in §3 was verified that way.

---

## 8. If you are picking this up cold

1. Read this file, then `usm-reference/PORT_NOTES.md` for the long history.
2. `cd app && npm install && npm run tauri:dev`.
3. Smoke-test the sidecar from a shell before blaming the UI.
4. Highest-value next steps, in order:
   1. **Site Profile** (§5) — unblocks 10 `TODO(Site Profile)` sites and the
      task-sequence token expansion
   2. **Phase-C first-boot runner** (§2.3) — unblocks Applications and everything
      MDT did after the first reboot
   3. **WinPE client rewrite** (§2.1) — grow `fieldiso/run.ps1` into the agent
   4. Boot Images UI over the existing overlay engine
5. Commit early — the repo still has **no commits**.

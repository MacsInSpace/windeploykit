# WinDeployKit

Cross-platform Windows deployment toolkit - PXE boot, an image library, driver
packs and task sequences, driven from a desktop app that runs on **macOS and
Windows**.

**No MDT. No WDS. No Windows Server.** The deployment server is your laptop.

> **Status: early development.** The app builds and runs, and the sidecar answers
> every panel command. Several panels are still placeholders and the WinPE client
> is being rewritten - not usable for production imaging yet.
> [`AGENT_NOTES.md`](AGENT_NOTES.md) records exactly what works today.

---

## Why this exists

Microsoft retired the Microsoft Deployment Toolkit, and on **6 January 2026**
removed it from the Download Center entirely. MDT-based workflows still run in
thousands of organisations, but the toolkit can no longer be obtained, and the
successor story (Autopilot / Intune) assumes cloud-managed, internet-connected
devices.

WinDeployKit rebuilds the part that mattered - *get a bare machine to a working,
domain-joined, driver-complete Windows install over the network* - without the
retired product, a Windows Server, or an on-prem WDS role.

It is also deliberately **cross-platform**: a technician with a MacBook can be
the deployment server on a site that has no server at all.

---

## What it does

| Area | Capability |
| --- | --- |
| **Netboot** | ProxyDHCP + TFTP (dnsmasq), HTTP (Caddy), iPXE -> wimboot chain, Secure Boot shim path, hidden read-only SMB `Deploy$` share |
| **Linux ISOs** | A Debian installer ISO dropped in the library is mounted read-only and gets its own PXE menu entry. The kernel boots straight off the ISO and the installer takes its packages from the mounted ISO tree; the only download is Debian's matching netboot initrd, fetched once per release. Nothing extracted (Secure Boot off) |
| **Boot Images** | Pull `boot.wim` out of any Windows ISO and overlay it with wimlib - no ADK on the imaging machine (one prior ADK export per WinPE build; see Requirements) |
| **Operating Systems** | Windows ISOs mounted read-only and served **zero-copy** - `install.wim` straight out of the ISO, never extracted. Acquisition from Microsoft Evaluation Center, a torrent catalog, or a URL |
| **Out-of-Box Drivers** | Vendor driver-pack catalogs (Dell, HP, Lenovo, Acer, Microsoft Surface) resolved by model, hash-verified on download, injected offline before first boot |
| **Task Sequences** | Named deployment recipes that compile to `unattend.xml` - computer naming, domain join, machine OU, product key, ordered first-boot steps |
| **Monitoring** | Live PXE activity log (which client fetched which boot file) and per-device imaging logs streamed back during deployment. Both clearable |
| **Transfers** | The download client - torrents and HTTP, with progress, cancel and hash verification |

---

## Architecture

```
+-------------------------------------------------------------+
|  Desktop app  (Tauri 2 + React + TypeScript)                |
|  MDT-Workbench-style console tree, one panel per node       |
+---------------------------+---------------------------------+
                            |  NDJSON over stdio
+---------------------------v---------------------------------+
|  Sidecar  (PowerShell 7, long-lived)                        |
|  dispatch loop -> Handle-<Command>                           |
+---------------------------+---------------------------------+
                            |  manages
      +---------------------+----------------------+
      v                     v                      v
  dnsmasq               Caddy                  SMB share
  TFTP :69              HTTP :8080             Deploy$
  ProxyDHCP             wimboot + WIMs         (hidden, read-only)
      |
      v
  PXE client -> iPXE -> wimboot -> WinPE agent
                                   |
                                   +- partition (GPT: EFI / MSR / OS / Recovery)
                                   +- apply install.wim (DISM)
                                   +- inject drivers (offline)
                                   +- plant unattend.xml
                                   +- stream log back to Monitoring
```

The WinPE side is **headless and server-driven**: it collects a job from the
server, executes it, and streams status back. The wizard lives in the app, not on
the machine being imaged - a deliberate departure from MDT's LiteTouch model.
Rationale in [`AGENT_NOTES.md`](AGENT_NOTES.md) section Locked decisions.

---

## Requirements

**To run the app**

- macOS 11+ or Windows 10/11
- **PowerShell 7.4+** (`pwsh` on PATH) - `brew install --cask powershell`
- Windows ISOs you are licensed to deploy

**To develop**

- Node.js 20+, Rust (stable)
- On Windows: VS 2022 with *Desktop development with C++*

**One-time, on a Windows machine with the ADK**

Putting PowerShell into a WinPE boot image requires exporting the WinPE optional
components once per WinPE build family
(`scripts/prepare-fieldiso-wim-inject.ps1`). Once that export exists, every later
boot-image operation - overlay, driver injection, rebuild - runs on macOS with
wimlib. The imaging machine never needs the ADK.

---

## Quick start (development)

```bash
cd app
npm install
npm run tauri:dev          # Vite on :42410, Tauri window; sidecar spawns on first panel call
```

| Command | Does |
| --- | --- |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run build` | Production frontend build |
| `npm run tauri:build` | Packaged app |

The sidecar speaks NDJSON on stdio and can be exercised without the UI:

```bash
printf '{"id":1,"cmd":"GetPxeBootPluginStatus","params":{}}\n' \
  | pwsh -NoProfile -File sidecar/windeploykit-sidecar.ps1
```

---

## Code conventions

Two rules that are enforced, not suggested. Both exist because breaking them has
already cost real debugging time.

### StrictMode

The sidecar runs `Set-StrictMode -Version Latest`, and every dot-sourced lib
inherits it. Under StrictMode, **reading a property that does not exist throws**
instead of returning `$null`. `ConvertFrom-Json` omits absent keys entirely, so
every optional field read directly is a latent crash.

The trap that catches people is that **a null check does not protect you** - the
property is read before the comparison happens:

```powershell
if ($null -ne $json.maybe) { ... }   # THROWS if 'maybe' is absent
if ($json.maybe)           { ... }   # THROWS - same reason
$json.maybe                          # THROWS
$hashtable.maybe                     # THROWS too (Latest covers hashtables)
```

Read every optional field through the accessor instead:

```powershell
$value = Get-AppSidecarJsonProp -Item $json -Name 'maybe'   # $null when absent
```

Other StrictMode facts worth knowing:

| Expression | Result |
| --- | --- |
| `$null.Count` | throws |
| `@($null).Count` | `1`, **not 0** - wrapping does not give you an empty array |
| `@($x)` where `$x` is absent-property | still throws; wrap the accessor, not the read |
| uninitialised `$variable` | throws |
| array index past the end | throws |

Run `pwsh -File scripts/test-strictmode.ps1` before committing sidecar changes.
It checks the accessor, proves the IPC dispatch loop answers malformed requests
rather than hanging, and fails on any new unsafe null-guard. The allowlist in
that script requires a written reason per entry, so silencing it is a decision
rather than a reflex.

### ASCII only

**No non-ASCII characters anywhere in the repository** - no em dashes, no en
dashes, no smart quotes, no box-drawing characters, no arrows, no emoji. This
applies to documentation, code, comments, commit messages and UI strings alike.

Use the ASCII equivalent:

| Instead of | Write |
| --- | --- |
| em dash, en dash | `-` |
| arrows | `->`, `<-`, `=>` |
| ellipsis | `...` |
| section sign | the word `section` |
| box drawing | `-`, `|`, `+` |
| check / cross glyphs | `OK`, `x` |
| emoji | nothing, or a bracketed word such as `[key]` |

Check with:

```bash
pwsh -File scripts/test-ascii.ps1
```

It scans every tracked text file, skipping binaries by content sniffing rather
than by extension, and exits non-zero naming file, line and character. Do not
reach for `grep -P` here: BSD grep on macOS has no `-P`.

In `.tsx`, remember that a bare `>` is invalid in JSX text: write `-&gt;` inside
an element body, and plain `->` inside attributes, strings and comments.

---

## Repository layout

| Path | What |
| --- | --- |
| `app/` | Tauri 2 + React frontend |
| `app/src/components/navConfig.ts` | The console tree - MDT node names, in deployment order |
| `app/src/panels/` | One thin file per tree node |
| `app/src/workspaces/` | Shared state containers whose sections the panels render |
| `app/src-tauri/` | Rust host: window, sidecar process manager (NDJSON framing, id correlation, per-command timeouts) |
| `sidecar/windeploykit-sidecar.ps1` | Sidecar entry point - dispatch loop and core handlers |
| `sidecar/lib/` | PXE services, task sequences, aria2, five vendor driver catalogs |
| `sidecar/handlers/` | The `Handle-<Command>` IPC surface |
| `sidecar/pxe/` | Boot assets: iPXE, wimboot, FieldIso WinPE overlay, boot-file recipes |
| `vendor/binaries/` | dnsmasq, wimlib, wimboot, tftpd64, swiftDialog helper |
| `packaging/` | Runtime-asset manifests and the bundled vendor driver catalogs |
| `scripts/` | Build, packaging and boot-image maintenance |
| `docs/` | Style guide, UI direction, data-freshness policy |

Two paths are **gitignored and local-only**: `PSD/` (a FriendsOfMDT/PSD clone kept
purely as a format reference) and `usm-reference/` (the originals this was
extracted from, plus the porting notes).

---

## Design

The UI deliberately mirrors the **MDT Deployment Workbench**: console tree on the
left, one panel per node, dense square chrome, right-aligned toolbars. Anyone who
has used MDT or WDS should be able to work it out without documentation.

The rules are enforced, not suggested - see
[`docs/WINDEPLOYKIT_App_StyleGuide.md`](docs/WINDEPLOYKIT_App_StyleGuide.md):
light and dark only (no theme packages), square corners, 32px chrome, 26px rows,
flat surfaces, tooltips instead of paragraphs.

Panels show **live machine state, not cached data** -
[`docs/DATA_FRESHNESS.md`](docs/DATA_FRESHNESS.md) sets out where caching is still
legitimate (vendor catalogs) and where it would lie (everything else).

The sibling project **PSOpenAD-FE** shares this exact design system. Style-guide
changes belong in both.

---

## Trademark

**WinDeployKit is not affiliated with, endorsed by, or sponsored by Microsoft.**
Windows, Windows PE, MDT and WDS are trademarks of Microsoft Corporation, used
here only to describe what this tool interoperates with. No Microsoft branding,
logos or typefaces are used.

## Licence

MIT - see [`LICENSE`](LICENSE). Use it, borrow from it, improve it; the one
condition is that the copyright notice travels with the copy.

See [`NOTICE.md`](NOTICE.md) for third-party components (dnsmasq, wimlib, Caddy,
aria2, iPXE/wimboot) and their licences.

Microsoft components are **never** committed to this repository - `boot.wim`,
`install.wim`, `bootmgfw.efi`, `BCD`, `boot.sdi` and the WinPE optional components
all come from your own licensed media and ADK installation, and their use is
governed by your Windows and ADK licence terms.

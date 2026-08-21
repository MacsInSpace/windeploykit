# UI direction - MDT-familiar workbench

**Requirement (Craig, 2026-08-20):** a familiar, MDT Deployment-Workbench-like interface.
Clean and minimal. Functional only. Tooltips instead of paragraphs. No AI-slop panel prose.

**Governing doc:** `docs/WINDEPLOYKIT_App_StyleGuide.md` (copied from USM, canonical mockup
`docs/windeploykit_ui_mockup.html`). Its section 6 already codifies the tooltip rule - apply it strictly:
- Help lives in `title` attrs or `InfoTip` (`app/src/components/InfoTip.tsx`), never in `<p>` blocks under controls.
- State is a badge (`HTTP: running`), never a sentence.
- Panel subtitle = one fact; rest behind the info dot. No subtitle is a valid outcome.
- Inline colour only for actionable conditions.
- Mono for data, Sans for chrome. No italic, no emoji icons, radius 3-5px, no bounce.

## MDT Workbench -> app shell mapping

USM's shell (sidebar / table / 280px detail pane) is already MMC-shaped. Map it 1:1 and
reuse MDT's node names verbatim - familiarity is the feature.

**One structure, no plug-in registry and no theme packages** (decided 2026-08-20): every
node below is always present. Netboot is a node in the tree, not a plug-in. Content
*acquisition* is folded into the node that owns the content rather than living in a
separate Downloads panel.

| MDT Deployment Workbench | Here |
| --- | --- |
| Console tree (left) | Sidebar nav |
| Deployment Share root | Overview - image library root + service status badges |
| Operating Systems | WIMs + mounted ISO catalog **+ OS acquisition** (Evaluation Center ISOs, torrents, OEM ISOs) |
| Out-of-Box Drivers | `Drivers/<Make>/<Model>` store **+ vendor catalog download** (Dell/HP/Lenovo/Acer/Surface) |
| Task Sequences | Task-sequence editor (JSON -> unattend) |
| Applications | Deferred - scripts-as-apps, ported from USM later |
| Boot Images | UI over the wimlib overlay engine (grab boot.wim from any ISO, overlay agent + drivers) |
| *(new)* Netboot | PXE services: ProxyDHCP/TFTP, HTTP, SMB share, boot menu |
| Monitoring | Imaging-log live view (per-device) |
| Advanced Configuration | Site Profile, artifact host, transfers |
| List view (centre) | DataTable, mono data columns |
| Actions pane / Properties dialog | Detail pane with actions; properties as detail-pane tabs, not modals |

Nav order: **Deployment Share** (Overview | Operating Systems | Out-of-Box Drivers |
Applications | Task Sequences | Boot Images | Netboot) | **Monitoring** (Deployments) |
**Advanced Configuration** (Site Profile | Transfers) | Sidecar Log.

Implemented in `app/src/components/navConfig.ts` - a plain array, no registry.

## OS acquisition (Operating Systems node)

Three sources, all landing in the same image library `iso/` folder that Caddy and the SMB
share already serve:

1. **Evaluation Center** - `sidecar/lib/EvalIsoCatalog.ps1`, ported from Craig's
   `GetWinISOs.ps1` (original archived in `usm-reference/`). Server 2016-2025 and
   Windows 10/11 Enterprise, scraped for the en-US x64 fwlink then queued through the
   shared download rail. Free, no account, time-limited - the default test path.
   Ported changes: cross-platform (BITS -> aria2/HTTP rail), fixed a malformed `and (`
   filter clause, no hardcoded `E:\ISOs`.
2. **Torrent catalog** - for organisations distributing their own SOE images.
3. **Manual** - drop an ISO in the folder, or paste a URL.

## Density and modes (2026-08-20)

Locked in with the shell build - see style guide section 1 *Non-negotiables*:

- **Tight and corporate.** MDT Workbench / MMC is the reference, not a dashboard.
- **Two modes only** - light and dark. Every `[data-skin]` block, the skins lib,
  icon packs and skin sounds were deleted.
- **Square corners** - `--radius-shell: 0`, card 5px, control 4px.
- **32px chrome** - `--header-height` drives both the sidebar lockup and the
  panel header so they align across the seam. Was 84px/92px in the USM original.
- **26px rows**, flat surfaces, no gradients or structural shadows.

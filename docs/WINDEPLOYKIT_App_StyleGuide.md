# WinDeployKit — Design System & Style Guide
**For Cursor:** Reference this document for all frontend component work. Do not deviate from these tokens without a specific reason. Consistency across panels matters more than individual panel creativity.

**Product name:** **WinDeployKit** (user-facing).

---

## 1. Aesthetic Direction

**Tight and corporate.** This is an operations console for technicians running
Windows deployments — the visual reference is the MDT Deployment Workbench and
the MMC family, not a consumer dashboard. Dense, square, quiet, and legible at a
glance. Chrome earns its pixels or it goes.

The one thing someone should remember: **it gets out of the way.**

### Non-negotiables

| Rule | Value |
| --- | --- |
| **Two modes only** | Light and dark. **No theme packages, no skins, no icon packs.** `:root` carries the full light palette; dark is redefined under `prefers-color-scheme` and `[data-theme="dark"]`. Never define a colour only inside a media/attribute block. |
| **Corners are square** | `--radius-shell: 0`, `--radius-card: 5px`, `--radius-control: 4px`. Nothing above 5px. No pills except a genuine status badge. |
| **Chrome is 32px** | `--header-height: 32px` for the sidebar lockup *and* the panel header — they align across the seam. A header is one line: title, then controls. No hero blocks, no oversized icons, no stacked subtitles. |
| **Rows are 26px** | Tree and table rows sit near 26px. Density beats breathing room in a tool that lists hundreds of drivers. |
| **Flat surfaces** | No gradients, no radial washes, no drop shadows on structural chrome. Panels are separated by a 1px `--border`, not by elevation. |
| **No decoration** | No emoji in labels or titles, no accent bars on cards, no "hero" anything. Structure encodes meaning or it is not there. |

Density is the house style: if a change makes the window hold *less* information
at the same size, it needs a reason beyond looking nicer.

---

## 2. Colour Palette

All colours are defined as CSS custom properties. In React + Tailwind, extend the Tailwind config with these or use a global CSS file.

```css
:root {
  /* Fluent daylight defaults */
  --bg:        #edf3fa;
  --surface:   #ffffff;
  --surface2:  #f5f8fc;
  --surface3:  #e8eff7;

  /* Borders */
  --border:    #d2ddea;
  --border2:   #9fb2c8;

  /* Accent — electric blue */
  --accent:    #1769d8;
  --accent2:   #0d58ba;
  --accent-dim:#0f4fae;

  /* Semantic */
  --green:     #087b5b;
  --amber:     #925800;
  --red:       #ae2638;
  --purple:    #6747b8;

  /* Text */
  --text:      #10233e;
  --text2:     #3d536e;
  --text3:     #5a7089;

  /* Utility */
  --white:     #ffffff;
  --mono:      'SFMono-Regular', 'Cascadia Code', Consolas, monospace;
  --sans:      'SF Pro Text', 'Segoe UI Variable Text', 'Segoe UI', system-ui, sans-serif;
  --cond:      'SF Pro Display', 'Segoe UI Variable Display', 'Segoe UI', system-ui, sans-serif;
}
```

### Colour usage rules:
- **Never** put `--text` directly on `--bg` without a surface behind it — always use a surface layer
- **Green** = healthy/enabled/connected. **Amber** = warning/disabled/needs attention. **Red** = error/locked/failed/disconnected
- **Purple** is reserved for subnet/network data values and LDAP path fragments — it visually separates technical data from UI chrome
- **Accent blue** is the single interactive colour — active nav, focused inputs, primary buttons, session status dots when healthy

---

## 3. Typography

### Font stack
```
Headings/panel titles:  SF Pro Display / Segoe UI Variable Display 600
Body/nav/labels:        SF Pro Text / Segoe UI Variable Text 400/500
Technical values:       SFMono / Cascadia Code / Consolas 400/500/600
```

Fonts are local platform stacks. The application must not depend on Google Fonts or another remote font service.

### Type scale

| Use | Font | Size | Weight | Colour |
|-----|------|------|--------|--------|
| Panel title | Sans | 18px | 600 | `--text` |
| Panel subtitle (OU path) | Mono | 10px | 400 | `--text3` |
| Nav section label | Sans | 9px | 600 | `--text3` |
| Nav item | Sans | 12.5px | 500 | `--text2` |
| Table header | Mono | 9.5px | 500 | `--text3` |
| Table cell — name/primary | Mono | 11–12px | 400 | `--text` |
| Table cell — secondary | Mono | 10–11px | 400 | `--text3` |
| Table cell — body | Sans | 12px | 400 | `--text2` |
| Status badge | Mono | 9.5px | 500 | semantic |
| Button | Sans | 11.5–12px | 400 | `--text2` |
| Detail pane key | Mono | 9.5px | 400 | `--text3` |
| Detail pane value | Mono | 10px | 400 | `--text2` |
| Site id | Mono | 10px | 400 | `--accent` |
| Site name | Condensed | 15px | 600 | `--text` |

### Rules:
- **Mono for data, Sans for UI.** Anything that comes from AD (DNs, usernames, hostnames, CIDRs, dates, account names) uses Mono. Anything that is part of the UI chrome (button labels, nav items, panel descriptions) uses Sans.
- Letter spacing: Mono labels use `0.08–0.12em`. Mono section labels use `0.1–0.15em` uppercase.
- Never use italic in this UI.

---

## 4. Layout

### App grid
```
┌─────────────────────────────────────────────────────┐
│  Title bar (68px)                                    │
├──────────────┬──────────────────────────────────────┤
│              │  Panel toolbar (44px)                 │
│  Sidebar     ├──────────────────────────────────────┤
│  (284px)     │  [Optional tab bar] (36px)            │
│              ├──────────────────────────────────────┤
│              │  Panel content          │ Detail pane │
│              │  (flex: 1, scroll)      │ (280px,     │
│              │                         │  optional)  │
└──────────────┴─────────────────────────┴────────────┘
```

### Sidebar structure (top to bottom):
1. **Site Profile card** — fixed, never scrolls (~110px)
2. **Nav section** — scrollable, `flex: 1`
3. **User footer** — fixed (~48px)

### Panel content area:
- `padding: 16px 20px` default
- Status chip row at top when relevant
- Data table takes remaining height (`flex: 1`, scrollable within its container)
- Detail pane slides in from right when a row is selected (280px, same height as content area)

### Spacing scale (use these, nothing else):
```
4px   — gap between tightly-related elements (dot + label in a pill)
6px   — gap between elements in a row
8px   — gap between items in nav, small card padding
12px  — internal card padding (tight)
14–16px — standard cell/item padding
20px  — panel content horizontal padding
24px  — section spacing
```

---

## 5. Component Tokens

### Status badges
```css
/* Base */
.badge {
  display: inline-flex; align-items: center; gap: 4px;
  border-radius: 3px; padding: 2px 7px;
  font-family: var(--mono); font-size: 9.5px; font-weight: 500;
}

/* Variants */
.badge-ok    { background: rgba(34,197,94,0.12);  color: var(--green); border: 1px solid var(--green-dim); }
.badge-warn  { background: rgba(245,158,11,0.12); color: var(--amber); border: 1px solid var(--amber-dim); }
.badge-err   { background: rgba(239,68,68,0.12);  color: var(--red);   border: 1px solid var(--red-dim); }
.badge-dim   { background: var(--surface3);       color: var(--text3); border: 1px solid var(--border); }
.badge-info  { background: rgba(59,130,246,0.12); color: var(--accent2); border: 1px solid rgba(59,130,246,0.3); }
```

### Session status dots (in title bar)
```css
.dot-status {
  width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0;
}
.dot-ok  { background: var(--green); box-shadow: 0 0 4px var(--green); }
.dot-err { background: var(--red);   box-shadow: 0 0 4px var(--red); }
.dot-pending { background: var(--amber); }
```

### Buttons
```css
/* Default */
.btn {
  display: flex; align-items: center; gap: 5px;
  background: var(--surface2); border: 1px solid var(--border);
  border-radius: 4px; color: var(--text2);
  padding: 5px 10px; font-size: 11.5px;
  font-family: var(--sans); cursor: pointer;
  transition: all 0.12s;
}
.btn:hover { border-color: var(--border2); color: var(--text); background: var(--surface3); }

/* Primary */
.btn-primary {
  background: var(--accent-dim); border-color: var(--accent); color: white;
}
.btn-primary:hover { background: var(--accent); }

/* Danger */
.btn-danger:hover { border-color: var(--red); color: var(--red); background: rgba(239,68,68,0.1); }
```

### Inputs / Search
```css
.input-box {
  display: flex; align-items: center; gap: 6px;
  background: var(--surface2); border: 1px solid var(--border);
  border-radius: 4px; padding: 4px 10px;
  transition: border-color 0.15s;
}
.input-box:focus-within { border-color: var(--accent); }
.input-box input {
  background: none; border: none; outline: none;
  color: var(--text); font-family: var(--sans); font-size: 12px;
}
.input-box input::placeholder { color: var(--text3); }
```

### Dropdown selectors
```css
/* Always wrap <select> in .input-box (same chrome as text inputs). */
.input-box select {
  width: 100%;
  background: transparent;
  border: none;
  outline: none;
  font-family: var(--sans);
  font-size: 12px;
  color: var(--text);
  appearance: none;
  -webkit-appearance: none;
  color-scheme: dark; /* native popup menus should prefer dark palette */
  padding-right: 16px;
}
.input-box select option {
  background: var(--surface2);
  color: var(--text);
}
```

Rules:
- Use the same `.input-box` shell for all toolbar filters and form dropdowns.
- Do not use raw/native `<select>` styling outside `.input-box`.
- For data selectors (identifiers, tokens), apply `mono` to the `<select>` element.
- For UI selectors (status/year/home-group filters), use sans text (`11-12px`).

### Nav items
```css
.nav-item {
  display: flex; align-items: center; gap: 9px;
  padding: 7px 16px; cursor: pointer;
  border-left: 2px solid transparent;
  color: var(--text2); font-size: 12.5px;
  transition: all 0.12s;
}
.nav-item:hover { background: var(--surface2); color: var(--text); border-left-color: var(--border2); }
.nav-item.active {
  background: linear-gradient(90deg, rgba(59,130,246,0.12) 0%, transparent 100%);
  color: var(--accent2); border-left-color: var(--accent);
}
```

### Table
```css
table { width: 100%; border-collapse: collapse; font-size: 12px; }

thead { background: var(--surface2); position: sticky; top: 0; z-index: 1; }
th {
  padding: 8px 14px; text-align: left;
  font-family: var(--mono); font-size: 9.5px;
  text-transform: uppercase; letter-spacing: 0.1em;
  color: var(--text3); border-bottom: 1px solid var(--border);
}
td {
  padding: 9px 14px; border-bottom: 1px solid rgba(42,51,73,0.5);
  color: var(--text2); vertical-align: middle;
}
tr:hover td { background: rgba(59,130,246,0.04); color: var(--text); }
tr.selected td { background: rgba(59,130,246,0.08); }

/* Row action buttons — hidden until hover */
.row-actions { opacity: 0; transition: opacity 0.1s; }
tr:hover .row-actions { opacity: 1; }
```

### Data cards (for subnet display, campus info, etc.)
```css
.data-card {
  background: var(--surface2);
  border: 1px solid var(--border);
  border-radius: 5px;
  padding: 10px 12px;
}
```

### Subnet type badges
```css
.type-admin  { background: rgba(59,130,246,0.15); color: var(--accent2); border: 1px solid rgba(59,130,246,0.3); }
.type-curric { background: rgba(34,197,94,0.12);  color: var(--green);   border: 1px solid rgba(34,197,94,0.25); }
.type-dmz    { background: rgba(245,158,11,0.12); color: var(--amber);   border: 1px solid rgba(245,158,11,0.25); }
```

---

## 6. Interaction Patterns

### Row selection → detail pane
- Clicking a table row selects it (adds `.selected` class to `<tr>`)
- Detail pane slides in from the right (CSS `transform: translateX(280px)` → `translateX(0)`, 180ms ease)
- Detail pane width: 280px, separated from table by `border-left: 1px solid var(--border)`
- Clicking the same row again, or pressing Escape, closes the detail pane

### Loading states
- Table rows while loading: replace with 3–5 skeleton rows (grey shimmer using `background: linear-gradient(90deg, var(--surface2) 25%, var(--surface3) 50%, var(--surface2) 75%)` animated)
- Never show empty table with spinner — show skeleton rows immediately, then swap
- Status chips show "Loading..." with amber colouring until data resolves

### Empty states
- Never an empty white box. Show a message centred in the content area:
  - Icon (subtle, `var(--text3)`)
  - Short message in Sans `var(--text2)`
  - Optional action button if relevant

### Help text & tooltips
- **Less is more. Prefer a tooltip over an inline paragraph of help text.** Controls should be self-explanatory from their label; put the "why / when / caveats" in a `title` attribute (native tooltip on hover), not in a persistent `<p>` block beneath the control.
- Do **not** stack explanatory `var(--text3)` paragraphs under checkboxes/toggles. They add visual noise and push real controls off-screen. Move that copy into the control's `title`.
- A control's state should be obvious without prose. Use a status **badge** (e.g. `HTTP: running`, `SMB: shared`) next to the toggle rather than a sentence describing the state.
- Reserve inline coloured text for **actionable conditions only** — an error or a blocking warning the user must resolve (e.g. amber "⚠ Downloads is TCC-protected — move the root"). Never for steady-state explanation.
- Don't duplicate a label in its own tooltip. The tooltip adds information the label can't convey, not a restatement.
- Group related service toggles into consistent rows (name + sub-label + badge + checkbox), like the HTTP / TFTP / SMB boxes in the Netboot panel, instead of free-form checkbox lists with help paragraphs.

#### Panel header subtitles — one fact, rest in the tooltip (2026-07-20)

Panel subtitles had grown into long `·`-joined strings (source host, cache age, filters,
mount state, hints) that wrapped across the header and clipped under the site switcher.

**Rule:** `PanelShell`'s `subtitle` carries **one scannable fact** — normally the row count
(`142 / 900`) or the current target. Everything else goes in the `details` prop, revealed by
hovering the info dot beside it.

```tsx
<PanelShell
  title="NPS Log Viewer"
  subtitle={<span>{shown} of {total}</span>}          // one fact, never wraps
  details={[                                          // hover to reveal
    { label: "Source", value: `DC ${host}` },
    { label: "Tail", value: `last ${tail} lines` },
    excluded > 0 && { label: "Excluded", value: `${excluded} rows` },
    { label: "Auth", value: `${rejects} rejects`, tone: rejects > 0 ? "bad" : "normal" },
  ]}
/>
```

| Detail | Rule |
| ------ | ---- |
| Values | Live React nodes — they update while the tip is open. Never snapshot a dynamic value into a string |
| Optional rows | `cond && { … }` — every falsy result is dropped, so `&&` guards are safe |
| Labels | Short single nouns, sentence case: Source, Cache, Scope, Domain, Filter, Updated |
| `tone` | `"bad"` / `"warn"` for **actionable** conditions only (rejects, stale cache, roaming limits) — never steady-state |
| Inline colour in `subtitle` | Same rule: only for something the technician must act on |

**Don't** hide an error message, empty state, or blocking warning inside the tooltip — those
stay visible. The tooltip is for supporting context a technician wants *sometimes*, not for
anything they must act on.

#### Never repeat site context in a panel header

The sidebar **Current site** card is the single source for site context and is on screen at
all times. Do **not** restate any of it in a panel title, subtitle, or header tooltip:

| Already in the sidebar | So never put in a header |
| ---------------------- | ------------------------ |
| Site id (`SITE01`) | `Site SITE01`, `OU=SITE01` |
| Site name | `Example Site` |
| `DC` hostnames | `DC01` |
| `ADMIN` subnet | `10.10.0.0/24` |
| `CURRIC` subnet | `Curric 10.20.0.0/23` |

A panel header with nothing else to say should have **no subtitle at all** — that is the
correct outcome, not a gap to fill.

**Derived** values are fine, because the sidebar doesn't carry them: an AD group name
(`SITE01-admins`), a GPO filter pattern (`SITE01-*`), the campus number, or a value that
genuinely *differs* from the sidebar.

`InfoTip` (`app/src/components/InfoTip.tsx`) is also usable standalone for dense controls
where a native `title` is too limited (needs live values or multiple labelled rows). For a
plain one-line caveat on a control, a native `title` is still correct and cheaper.

### Transitions
- Nav active state: `transition: all 0.12s`
- Buttons: `transition: all 0.12s`
- Detail pane: `transition: transform 0.18s ease`
- Status dots: `transition: box-shadow 0.3s` (glow appears/disappears on session connect)
- **No bounce, no spring, no scale transforms** — this is a tool, not an app store showcase

### Session status changes
- When a session drops: dot goes red, tooltip appears on hover ("DC disconnected — LDAP features unavailable")
- LDAP-dependent panels grey out (`opacity: 0.4`, `pointer-events: none`) with a banner: "LDAP session unavailable — reconnect to restore"
- Reconnect button in banner triggers `ReconnectSessions` command

---

## 7. Tailwind Config Extension (if using Tailwind)

```js
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      colors: {
        bg:        '#0f1117',
        surface:   '#161b27',
        surface2:  '#1e2535',
        surface3:  '#242d42',
        border:    '#2a3349',
        border2:   '#364060',
        accent:    '#3b82f6',
        accent2:   '#60a5fa',
        'accent-dim': '#1d4ed8',
        success:   '#22c55e',
        warning:   '#f59e0b',
        danger:    '#ef4444',
        purple:    '#a78bfa',
        text1:     '#e2e8f0',
        text2:     '#94a3b8',
        text3:     '#64748b',
      },
      fontFamily: {
        mono:  ['"IBM Plex Mono"', 'JetBrains Mono', 'monospace'],
        sans:  ['"IBM Plex Sans"', 'system-ui', 'sans-serif'],
        cond:  ['"IBM Plex Sans Condensed"', '"IBM Plex Sans"', 'sans-serif'],
      },
      fontSize: {
        'xxs': '9px',
        'xs':  '10px',
        'sm':  '11px',
        'md':  '12px',
        'base':'13px',
      },
    },
  },
}
```

---

## 8. Do / Don't

| Do | Don't |
|----|-------|
| Use Mono for all AD/LDAP data (DNs, usernames, IPs, CIDRs, dates from AD) | Use Mono for button labels, nav items, descriptions |
| Keep row action buttons hidden until hover | Show action buttons always — clutters the table |
| Show both LDAP and the site service context in the title bar always | Hide context info anywhere in the app |
| Use `--purple` for subnet CIDRs and LDAP path values | Use purple for anything else |
| Collapse detail pane when navigating to a different panel | Leave stale detail pane open on panel switch |
| Use `border-radius: 0–5px`; shell corners are square | Use pill shapes or rounded cards anywhere except a status badge |
| Label everything with Mono uppercase tracking | Use sentence-case for section labels |
| Keep chrome to one 32px line | Add hero blocks, stacked subtitles, or oversized panel icons |
| Grey out LDAP panels when session is lost | Hide them or show an error page |
| Use the Site Profile card as the persistent identity anchor | Put site info only in the title bar |

---

## 9. Reference File

The HTML mockup (`windeploykit_ui_mockup.html`) is the canonical visual reference. Every CSS class in that file follows these tokens. When building React components, treat the mockup as the spec — extract the structure and translate to JSX + Tailwind or CSS modules.

The mockup shows: title bar, sidebar site card, nav items, tab bar, table with selection, row actions, status chips, detail pane with attribute sections and action buttons.

---

## 10. Modes

Light and dark only, both defined as CSS custom properties on `:root` (see §2).
There is **no** theme-package system, no skin registry, no icon packs and no
per-skin sounds — those were removed deliberately. A viewer in the default
"system" state gets light or dark from `prefers-color-scheme`; an explicit
`data-theme` attribute wins over it in both directions.

Adding a third look is a change to this document first, not a feature flag.

---

*WinDeployKit Design System v1.0 — 25 May 2026 · Skins § added 2026-06 · retro Windows skins 2026-06-17*

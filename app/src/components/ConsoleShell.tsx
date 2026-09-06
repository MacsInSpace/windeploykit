/**
 * The console: title bar, menu bar, toolbar, console tree, result pane, status
 * bar. The same shell PSOpenAD-FE runs, because a technician who knows MMC
 * should not have to learn two of them.
 *
 * Verbs have exactly one source - the active panel publishes them through
 * state/consoleActions - and exactly three uniform outlets here: the Action
 * menu, the right-click menu on the tree node or the result pane, and the two
 * toolbar glyphs every node shares (Refresh, Properties). Panels render no
 * action buttons of their own.
 */
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type MouseEvent, type ReactNode } from "react";

import { AppIcon } from "./AppIcon";
import appIcon from "../../src-tauri/icons/32x32.png";
import { ConsoleTree } from "./ConsoleTree";
import { ContextMenu, SEP, menuLabel, useContextMenu, type MenuItem } from "./ContextMenu";
import { MenuBar, type Menu } from "./MenuBar";
import { ToolbarIcon, type ToolbarGlyph } from "./ToolbarIcon";
import { findNavNode, findParentId, flattenNav, type NavNode } from "./navConfig";
import { APP_VERSION } from "../lib/buildInfo";
import { appExit, sidecar } from "../lib/ipc";
import { getSetting, setSetting, SETTING_CLOSE_TO_TRAY, subscribeSettings } from "../lib/settings";
import { isTauri } from "../lib/tauriEnv";
import { restartSidecarNow, useSidecarBootState } from "../lib/sidecarBoot";
import {
  getConsoleActions,
  useConsoleActionsSnapshot,
  type ConsoleNodeActions,
} from "../state/consoleActions";
import { useToasts } from "../state/toastStore";

const TREE_W_KEY = "windeploykit.console.treeW";
const TREE_W_DEFAULT = 268;
const TREE_W_MIN = 160;
const TREE_W_MAX = 560;

interface VaultStatus {
  ready?: boolean;
  keyMatches?: boolean;
  error?: string | null;
  secretCount?: number;
}

function readTreeW(): number {
  try {
    const raw = localStorage.getItem(TREE_W_KEY);
    const n = raw ? Number(raw) : NaN;
    if (Number.isFinite(n)) return Math.min(TREE_W_MAX, Math.max(TREE_W_MIN, n));
  } catch {
    /* storage unavailable - use the default */
  }
  return TREE_W_DEFAULT;
}

function writeTreeW(w: number) {
  try {
    localStorage.setItem(TREE_W_KEY, String(w));
  } catch {
    /* non-fatal */
  }
}

export function ConsoleShell({
  initialId,
  renderPanel,
}: {
  initialId: string;
  renderPanel: (id: string) => ReactNode;
}) {
  /* -- navigation (Back / Forward / Up, like MMC) ------------------------- */
  const [nav, setNav] = useState<{ stack: string[]; at: number }>({ stack: [initialId], at: 0 });
  const activeId = nav.stack[nav.at] ?? initialId;
  const activeNode = findNavNode(activeId);
  const parentId = findParentId(activeId);

  const navigate = useCallback((id: string) => {
    setNav((cur) => {
      if (cur.stack[cur.at] === id) return cur;
      const stack = [...cur.stack.slice(0, cur.at + 1), id];
      return { stack, at: stack.length - 1 };
    });
  }, []);
  const goBack = useCallback(() => setNav((c) => (c.at > 0 ? { ...c, at: c.at - 1 } : c)), []);
  const goForward = useCallback(
    () => setNav((c) => (c.at < c.stack.length - 1 ? { ...c, at: c.at + 1 } : c)),
    [],
  );

  /* -- tree expansion ------------------------------------------------------ */
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set());
  const toggle = useCallback((id: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);
  const expandAll = useCallback(() => setCollapsed(new Set()), []);
  const collapseAll = useCallback(
    () => setCollapsed(new Set(flattenNav().filter((n) => n.children?.length).map((n) => n.id))),
    [],
  );

  /* -- splitter ------------------------------------------------------------ */
  const [treeW, setTreeW] = useState(readTreeW);
  useEffect(() => writeTreeW(treeW), [treeW]);
  const startResize = useCallback(
    (e: MouseEvent) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = treeW;
      const onMove = (ev: globalThis.MouseEvent) =>
        setTreeW(Math.min(TREE_W_MAX, Math.max(TREE_W_MIN, startW + ev.clientX - startX)));
      const onUp = () => {
        window.removeEventListener("mousemove", onMove);
        window.removeEventListener("mouseup", onUp);
        document.body.classList.remove("is-resizing");
      };
      document.body.classList.add("is-resizing");
      window.addEventListener("mousemove", onMove);
      window.addEventListener("mouseup", onUp);
    },
    [treeW],
  );

  /* -- verbs from the active panel ----------------------------------------- */
  const actions = useConsoleActionsSnapshot();
  const menu = useContextMenu();

  const nodeVerbs = useCallback(
    (node: NavNode | undefined, a: ConsoleNodeActions = actions): MenuItem[] => {
      const items: MenuItem[] = [];
      if (node) items.push(menuLabel(node.label), SEP);
      if (a.items.length > 0) items.push(...a.items, SEP);
      items.push({ label: "Refresh", accel: "F5", disabled: !a.refresh, onSelect: a.refresh });
      items.push({
        label: "Properties...",
        accel: "Alt+Enter",
        disabled: !a.properties,
        isDefault: Boolean(a.properties),
        onSelect: a.properties,
      });
      return items;
    },
    [actions],
  );

  const onTreeContextMenu = useCallback(
    (e: MouseEvent, node: NavNode) => {
      e.preventDefault();
      e.stopPropagation();
      const x = e.clientX;
      const y = e.clientY;
      if (node.id === activeId) {
        menu.openAt(x, y, nodeVerbs(node));
        return;
      }
      // MMC selects the node first. Its panel publishes verbs on mount, so open
      // the menu once that has landed - and read the store at that moment, not
      // the `actions` this handler closed over, which still belong to the node
      // we are leaving.
      navigate(node.id);
      window.setTimeout(() => menu.openAt(x, y, nodeVerbs(node, getConsoleActions())), 80);
    },
    [activeId, menu, navigate, nodeVerbs],
  );

  /* -- keyboard ------------------------------------------------------------ */
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "F5") {
        e.preventDefault();
        actions.refresh?.();
      } else if (e.altKey && e.key === "Enter") {
        e.preventDefault();
        actions.properties?.();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [actions]);

  /* -- title-bar status: sidecar lifecycle + vault ------------------------- */
  const boot = useSidecarBootState();
  const [vault, setVault] = useState<VaultStatus | null>(null);
  useEffect(() => {
    if (!isTauri()) return;
    if (boot.lifecycle !== "ready") {
      setVault(null);
      return;
    }
    let live = true;
    void sidecar
      .invoke<VaultStatus>("GetSecretVaultStatus", {})
      .then((v) => live && setVault(v))
      .catch(() => live && setVault(null));
    return () => {
      live = false;
    };
  }, [boot.lifecycle]);

  /* -- status bar ---------------------------------------------------------- */
  const toasts = useToasts();
  const lastToast = toasts[toasts.length - 1];
  const statusLeft = lastToast
    ? lastToast.body
      ? `${lastToast.title} - ${lastToast.body}`
      : lastToast.title
    : (actions.status ?? "Ready");
  const statusTone = lastToast?.variant === "error" ? "status-error" : lastToast?.variant === "warn" ? "status-warn" : "";

  /* -- menus --------------------------------------------------------------- */
  // Close-to-tray (the window's close button hides the app to the menu bar / tray and
  // PXE keeps serving) is a checkbox here, as in AdobeUpdateKit and USM; Exit is a real
  // exit through the host, since with the setting on a window close no longer quits.
  const closeToTray = useSyncExternalStore(subscribeSettings, () => getSetting(SETTING_CLOSE_TO_TRAY), () => true);
  const isMac = typeof navigator !== "undefined" && /Mac/i.test(navigator.platform || navigator.userAgent);
  const menus = useMemo<Menu[]>(
    () => [
      {
        title: "File",
        mnemonic: "f",
        items: [
          {
            label: "Properties...",
            accel: "Alt+Enter",
            disabled: !actions.properties,
            onSelect: actions.properties,
          },
          SEP,
          ...(isTauri()
            ? [
                {
                  label: isMac ? "Close to menu bar" : "Close to tray",
                  checked: closeToTray,
                  onSelect: () => setSetting(SETTING_CLOSE_TO_TRAY, !closeToTray),
                },
                SEP,
              ]
            : []),
          {
            label: "Exit",
            onSelect: () => {
              void appExit();
            },
          },
        ],
      },
      { title: "Action", mnemonic: "a", items: nodeVerbs(activeNode) },
      {
        title: "View",
        mnemonic: "v",
        items: [
          { label: "Expand All", onSelect: expandAll },
          { label: "Collapse All", onSelect: collapseAll },
          SEP,
          { label: "Refresh", accel: "F5", disabled: !actions.refresh, onSelect: actions.refresh },
          SEP,
          { label: "Sidecar Log", onSelect: () => navigate("logs") },
        ],
      },
      {
        title: "Help",
        mnemonic: "h",
        items: [
          {
            label: "About WinDeployKit",
            onSelect: () =>
              window.alert?.(
                `WinDeployKit ${APP_VERSION}\n\nCross-platform Windows deployment toolkit - PXE boot, image library, driver packs and task sequences. Not affiliated with Microsoft.`,
              ),
          },
        ],
      },
    ],
    [actions, activeNode, nodeVerbs, expandAll, collapseAll, navigate, closeToTray, isMac],
  );

  // Only a sidecar that is NOT fine earns a badge - steady state is silent.
  const sidecarBadge =
    boot.lifecycle === "ready" || boot.lifecycle === "idle" || !isTauri()
      ? null
      : boot.lifecycle === "checking" || boot.lifecycle === "starting"
        ? { cls: "badge-dim", text: "SIDECAR STARTING", title: "Starting the PowerShell sidecar", click: false }
        : boot.lifecycle === "missing-pwsh"
          ? {
              cls: "badge-err",
              text: "POWERSHELL 7 MISSING",
              title: `${boot.detail ?? ""}${boot.installCommand ? ` Install: ${boot.installCommand}` : ""}`,
              click: false,
            }
          : {
              cls: "badge-err",
              text: "SIDECAR STOPPED - RESTART",
              title: `${boot.detail ?? "The sidecar is not running."} Click to restart.`,
              click: true,
            };
  const vaultBadge = !vault
    ? null
    : vault.ready
      ? { cls: "badge-dim", text: "VAULT", title: `Shared secret vault ready - ${vault.secretCount ?? 0} secret(s)` }
      : vault.keyMatches === false
        ? { cls: "badge-warn", text: "VAULT - SIGN IN AGAIN", title: vault.error ?? "The vault store was created on another machine or by another user." }
        : { cls: "badge-warn", text: "VAULT UNAVAILABLE", title: vault.error ?? "Credential features are degraded." };

  return (
    <div className="shell is-console">
      <header className="titlebar">
        <img className="brand-mark" src={appIcon} alt="" width={16} height={16} aria-hidden />
        <span className="brand">WinDeployKit</span>
        <div className="titlebar-right">
          {sidecarBadge &&
            (sidecarBadge.click ? (
              <button
                type="button"
                className={`badge ${sidecarBadge.cls} titlebar-badge-button`}
                title={sidecarBadge.title}
                onClick={() => void restartSidecarNow()}
              >
                {sidecarBadge.text}
              </button>
            ) : (
              <span className={`badge ${sidecarBadge.cls}`} title={sidecarBadge.title}>
                {sidecarBadge.text}
              </span>
            ))}
          {vaultBadge && (
            <span className={`badge ${vaultBadge.cls}`} title={vaultBadge.title}>
              {vaultBadge.text}
            </span>
          )}
          <span className="badge badge-dim mono" title="Build">
            v{APP_VERSION}
          </span>
        </div>
      </header>

      <div className="console">
        <MenuBar menus={menus} />

        <div className="toolbar" role="toolbar" aria-label="Console actions">
          <TB glyph="back" label="Back" disabled={nav.at <= 0} onClick={goBack} />
          <TB glyph="forward" label="Forward" disabled={nav.at >= nav.stack.length - 1} onClick={goForward} />
          <TB glyph="up" label="Up One Level" disabled={!parentId} onClick={() => parentId && navigate(parentId)} />
          <span className="tb-sep" />
          <TB glyph="refresh" label="Refresh (F5)" disabled={!actions.refresh} onClick={actions.refresh} />
          <span className="tb-sep" />
          <TB
            glyph="properties"
            label="Properties (Alt+Enter)"
            disabled={!actions.properties}
            onClick={actions.properties}
          />
        </div>

        <div className="console-body" style={{ gridTemplateColumns: `${treeW}px 5px minmax(0, 1fr)` }}>
          <aside className="tree-pane">
            <ConsoleTree
              activeId={activeId}
              collapsed={collapsed}
              onSelect={navigate}
              onToggle={toggle}
              onContextMenu={onTreeContextMenu}
            />
          </aside>

          <div
            className="splitter"
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize console tree"
            onMouseDown={startResize}
            /* Double-click restores the default, as MMC's splitters do. */
            onDoubleClick={() => setTreeW(TREE_W_DEFAULT)}
          />

          <section
            className="results-pane"
            onContextMenu={(e) => {
              /* Controls inside panels stop propagation; reaching here means
                 blank space, which MMC treats as the node itself. */
              const t = e.target as HTMLElement;
              if (t.closest("button, input, select, textarea, a, [role=menu], table")) return;
              menu.open(e, nodeVerbs(activeNode));
            }}
          >
            <div className="results-body">{renderPanel(activeId)}</div>
            <footer className="status-bar">
              <span className={statusTone || undefined}>{statusLeft}</span>
              <span className="status-right">
                {activeNode ? (
                  <span className="status-node">
                    <AppIcon name={activeNode.icon} size={12} /> {activeNode.label}
                  </span>
                ) : null}
              </span>
            </footer>
          </section>
        </div>

        <ContextMenu state={menu.state} onClose={menu.close} />
      </div>
    </div>
  );
}

function TB({
  glyph,
  label,
  disabled,
  onClick,
}: {
  glyph: ToolbarGlyph;
  label: string;
  disabled?: boolean;
  onClick?: () => void;
}) {
  return (
    <button type="button" className="tb-btn" title={label} aria-label={label} disabled={disabled} onClick={onClick}>
      <ToolbarIcon glyph={glyph} />
    </button>
  );
}

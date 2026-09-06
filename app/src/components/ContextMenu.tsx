/**
 * Right-click context menu and the popup surface the menu bar shares with it.
 *
 * Ported from PSOpenAD-FE verbatim (the two apps share one design system and
 * this is chrome, not domain). MMC behaviour, deliberately:
 *   * right-click a row or tree node opens the menu at the pointer
 *   * the double-click default action is rendered bold
 *   * separators group verbs the way the Workbench groups them
 *   * Escape, click-away, scroll, or resize dismisses
 *   * Up/Down move, Right opens a submenu, Left closes it, Enter invokes
 *
 * Menus flip rather than overflow: one opened near the right or bottom edge is
 * mirrored so it stays fully on screen.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

export interface MenuItem {
  /** Visible label. Use the Workbench's exact wording, not a synonym. */
  label: string;
  onSelect?: () => void;
  /** Rendered bold - the action a double-click performs. */
  isDefault?: boolean;
  /** Destructive styling on hover (Delete). */
  isDanger?: boolean;
  disabled?: boolean;
  /** Non-interactive heading (see `menuLabel`), not a greyed-out verb. */
  isHeading?: boolean;
  /** Accelerator shown right-aligned, MMC style - "F5", "Alt+Enter". */
  accel?: string;
  /** A toggle: set to render a check column (x when on), as in AdobeUpdateKit. */
  checked?: boolean;
  /** Nested items ("New >"). */
  children?: MenuItem[];
}

/** Separator between verb groups. */
export const SEP: MenuItem = { label: "-" };

/** Non-interactive heading, e.g. the node name at the top of the menu. */
export function menuLabel(text: string): MenuItem {
  return { label: text, isHeading: true };
}

export interface ContextMenuState {
  x: number;
  y: number;
  items: MenuItem[];
}

export function useContextMenu() {
  const [state, setState] = useState<ContextMenuState | null>(null);

  const open = useCallback((e: React.MouseEvent, items: MenuItem[]) => {
    e.preventDefault();
    e.stopPropagation();
    if (items.length === 0) return;
    setState({ x: e.clientX, y: e.clientY, items });
  }, []);

  const openAt = useCallback((x: number, y: number, items: MenuItem[]) => {
    if (items.length === 0) return;
    setState({ x, y, items });
  }, []);

  const close = useCallback(() => setState(null), []);

  return { state, open, openAt, close };
}

export function ContextMenu({
  state,
  onClose,
}: {
  state: ContextMenuState | null;
  onClose: () => void;
}) {
  if (!state) return null;
  return <MenuSurface x={state.x} y={state.y} items={state.items} onClose={onClose} depth={0} />;
}

/**
 * One menu popup. The menu bar reuses it so Action and right-click render
 * identical verbs. `manageDismiss` is false when a parent already owns
 * click-away and Escape (the menu bar does), otherwise both fire and a click on
 * the open menu title would close then immediately reopen it.
 */
export function MenuSurface({
  x,
  y,
  items,
  onClose,
  depth,
  manageDismiss = true,
}: {
  x: number;
  y: number;
  items: MenuItem[];
  onClose: () => void;
  depth: number;
  manageDismiss?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: x, top: y });
  const [openSub, setOpenSub] = useState<{ index: number; x: number; y: number } | null>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    let left = x;
    let top = y;
    if (left + r.width > window.innerWidth - 4) left = Math.max(4, x - r.width);
    if (top + r.height > window.innerHeight - 4) top = Math.max(4, window.innerHeight - r.height - 4);
    setPos({ left, top });
  }, [x, y]);

  useEffect(() => {
    if (depth !== 0 || !manageDismiss) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    const onDown = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) onClose();
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("mousedown", onDown, true);
    window.addEventListener("resize", onClose);
    window.addEventListener("scroll", onClose, true);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mousedown", onDown, true);
      window.removeEventListener("resize", onClose);
      window.removeEventListener("scroll", onClose, true);
    };
  }, [depth, manageDismiss, onClose]);

  function invoke(item: MenuItem) {
    if (item.disabled || item.children) return;
    onClose();
    item.onSelect?.();
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    const focusables = Array.from(
      ref.current?.querySelectorAll<HTMLButtonElement>("button.ctx-item:not(:disabled)") ?? [],
    );
    if (focusables.length === 0) return;
    const idx = focusables.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === "ArrowDown") {
      e.preventDefault();
      focusables[(idx + 1) % focusables.length]?.focus();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      focusables[(idx - 1 + focusables.length) % focusables.length]?.focus();
    }
  }

  return (
    <>
      <div
        ref={ref}
        className="ctx-menu"
        role="menu"
        style={{ left: pos.left, top: pos.top }}
        onKeyDown={onKeyDown}
        onContextMenu={(e) => e.preventDefault()}
      >
        {items.map((item, i) => {
          if (item.label === "-") return <div key={`sep-${i}`} className="ctx-sep" role="separator" />;

          if (item.isHeading) {
            return (
              <div key={`label-${i}`} className="ctx-label">
                {item.label}
              </div>
            );
          }

          return (
            <button
              key={`${item.label}-${i}`}
              type="button"
              role={item.checked !== undefined ? "menuitemcheckbox" : "menuitem"}
              aria-checked={item.checked}
              className={[
                "ctx-item",
                item.isDefault ? "is-default" : "",
                item.isDanger ? "is-danger" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              disabled={item.disabled}
              aria-haspopup={item.children ? "menu" : undefined}
              aria-expanded={item.children ? openSub?.index === i : undefined}
              onClick={() => invoke(item)}
              onMouseEnter={(e) => {
                if (!item.children) {
                  setOpenSub(null);
                  return;
                }
                const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                setOpenSub({ index: i, x: r.right - 2, y: r.top - 4 });
              }}
              onKeyDown={(e) => {
                if (e.key === "ArrowRight" && item.children) {
                  const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                  setOpenSub({ index: i, x: r.right - 2, y: r.top - 4 });
                } else if (e.key === "ArrowLeft") {
                  setOpenSub(null);
                } else if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  invoke(item);
                }
              }}
            >
              {item.checked !== undefined && (
                <span className="ctx-check mono" aria-hidden="true">
                  {item.checked ? "x" : ""}
                </span>
              )}
              <span>{item.label}</span>
              {item.accel && !item.children && <span className="ctx-accel">{item.accel}</span>}
              {item.children && (
                <span className="ctx-submenu-marker" aria-hidden="true">
                  &#9656;
                </span>
              )}
            </button>
          );
        })}
      </div>

      {openSub != null && items[openSub.index]?.children && (
        <MenuSurface
          x={openSub.x}
          y={openSub.y}
          items={items[openSub.index].children!}
          onClose={onClose}
          depth={depth + 1}
          manageDismiss={manageDismiss}
        />
      )}
    </>
  );
}

/**
 * MMC menu bar - File / Action / View / Help. Ported from PSOpenAD-FE.
 *
 * The Workbench puts every verb in two places: the Action menu and the
 * right-click menu. Both are built from the same `MenuItem[]`, so a verb cannot
 * exist in one and not the other.
 *
 * Behaviour copied from MMC: click a title to open it, then moving the pointer
 * across the bar switches menus without another click; Escape or a click away
 * closes; Alt+F/A/V/H open by mnemonic.
 */
import { useEffect, useRef, useState } from "react";
import { MenuSurface, type MenuItem } from "./ContextMenu";

export type Menu = { title: string; mnemonic: string; items: MenuItem[] };

export function MenuBar({ menus }: { menus: Menu[] }) {
  const [open, setOpen] = useState<number | null>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const btnRefs = useRef<Array<HTMLButtonElement | null>>([]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        setOpen(null);
        return;
      }
      if (!e.altKey) return;
      const i = menus.findIndex((m) => m.mnemonic.toLowerCase() === e.key.toLowerCase());
      if (i >= 0) {
        e.preventDefault();
        setOpen(i);
      }
    }
    function onDown(e: MouseEvent) {
      if (!barRef.current?.contains(e.target as Node)) setOpen(null);
    }
    window.addEventListener("keydown", onKey);
    window.addEventListener("mousedown", onDown, true);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mousedown", onDown, true);
    };
  }, [menus]);

  const anchor = open == null ? null : btnRefs.current[open]?.getBoundingClientRect();

  return (
    <div className="menubar" role="menubar" ref={barRef}>
      {menus.map((m, i) => (
        <button
          key={m.title}
          ref={(el) => {
            btnRefs.current[i] = el;
          }}
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={open === i}
          className={open === i ? "menubar-item is-open" : "menubar-item"}
          onClick={() => setOpen((cur) => (cur === i ? null : i))}
          onMouseEnter={() => setOpen((cur) => (cur == null ? cur : i))}
        >
          <u>{m.title.slice(0, 1)}</u>
          {m.title.slice(1)}
        </button>
      ))}

      {open != null && anchor && (
        <MenuSurface
          x={anchor.left}
          y={anchor.bottom}
          items={menus[open]!.items}
          onClose={() => setOpen(null)}
          depth={0}
          manageDismiss={false}
        />
      )}
    </div>
  );
}

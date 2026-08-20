import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";

/**
 * Hover / focus tooltip for detail that used to sit in a panel subtitle.
 *
 * Style guide § "Help text & tooltips": less is more — the header shows the one
 * fact a technician scans for; everything else lives in here. Content is normal
 * React children, so live values update while the tip is open.
 *
 * Rendered in a fixed-position layer above panel chrome so it can never be
 * clipped by the header's `overflow` or pushed under the school switcher.
 */

export interface InfoTipRow {
  label: string;
  value: ReactNode;
  /** `warn` / `bad` tint the value for actionable conditions only (style guide §6). */
  tone?: "normal" | "warn" | "bad";
}

/**
 * Rows are commonly built with `cond && {...}` guards, so every falsy result a
 * `&&` chain can produce is accepted and dropped.
 */
export type MaybeInfoTipRow = InfoTipRow | false | null | undefined | "" | 0;

interface InfoTipProps {
  /** Structured rows — preferred. Falls back to `children` for free-form content. */
  rows?: MaybeInfoTipRow[];
  children?: ReactNode;
  /** Accessible name for the trigger. */
  label?: string;
  /** Trigger glyph. Defaults to an info dot sized for the panel header. */
  className?: string;
}

const TIP_GAP = 8;

export function InfoTip({ rows, children, label = "Details", className }: InfoTipProps) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const tipRef = useRef<HTMLDivElement | null>(null);
  const tipId = useId();

  const visibleRows = (rows ?? []).filter((r): r is InfoTipRow => Boolean(r));
  const hasContent = visibleRows.length > 0 || Boolean(children);

  const place = useCallback(() => {
    const el = triggerRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    setPos({ top: r.bottom + TIP_GAP, left: r.left });
  }, []);

  useEffect(() => {
    if (!open) return;
    place();
    // Keep the tip anchored while the panel scrolls or the window resizes.
    const onScroll = () => place();
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
      window.removeEventListener("keydown", onKey);
    };
  }, [open, place]);

  // Nudge back on-screen once measured, so a right-edge trigger doesn't overflow.
  useEffect(() => {
    if (!open || !pos) return;
    const tip = tipRef.current;
    if (!tip) return;
    const r = tip.getBoundingClientRect();
    const overflowX = r.right - (window.innerWidth - 12);
    if (overflowX > 0) setPos((p) => (p ? { ...p, left: Math.max(12, p.left - overflowX) } : p));
  }, [open, pos]);

  if (!hasContent) return null;

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        className={`info-tip-trigger ${className ?? ""}`}
        aria-label={label}
        aria-expanded={open}
        aria-describedby={open ? tipId : undefined}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onClick={(e) => {
          e.stopPropagation();
          setOpen((v) => !v);
        }}
      >
        <span aria-hidden="true">i</span>
      </button>
      {open && pos && (
        <div
          ref={tipRef}
          id={tipId}
          role="tooltip"
          className="info-tip"
          style={{ top: pos.top, left: pos.left }}
        >
          {visibleRows.length > 0 && (
            <dl className="info-tip-rows">
              {visibleRows.map((row) => (
                <div key={row.label} className="info-tip-row">
                  <dt>{row.label}</dt>
                  <dd
                    style={
                      row.tone === "bad"
                        ? { color: "var(--red)" }
                        : row.tone === "warn"
                          ? { color: "var(--amber)" }
                          : undefined
                    }
                  >
                    {row.value}
                  </dd>
                </div>
              ))}
            </dl>
          )}
          {children && <div className="info-tip-body">{children}</div>}
        </div>
      )}
    </>
  );
}

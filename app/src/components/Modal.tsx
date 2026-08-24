import { useEffect, useRef, useCallback, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";

import { useToasts } from "../state/toastStore";

interface ModalProps {
  open: boolean;
  title: string;
  subtitle?: string;
  onClose: () => void;
  /** Disable Escape + click-outside closing while a write is in flight. */
  lock?: boolean;
  /** When locked, still allow X / Escape - runs onCancelWhileBusy (or onClose). */
  allowBusyCancel?: boolean;
  onCancelWhileBusy?: () => void;
  width?: CSSProperties["width"];
  zIndex?: number;
  children: ReactNode;
  footer?: ReactNode;
  /**
   * Repeat toasts raised while this dialog is open as a line along its bottom edge.
   * The shell shows toasts in the status bar, which the backdrop covers - so without
   * this a dialog swallows its own "saved" and, worse, its own errors (Craig,
   * 2026-08-24: pressed Add, "there was no feedback or confirmation"). On by default.
   */
  showToasts?: boolean;
}

export function Modal({
  open,
  title,
  subtitle,
  onClose,
  lock,
  allowBusyCancel,
  onCancelWhileBusy,
  width = 460,
  zIndex = 150,
  children,
  footer,
  showToasts = true,
}: ModalProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  // Click fires on mouseup, and a press/release across different elements dispatches it
  // on their common ancestor (the backdrop). Only close when the press STARTED on the
  // backdrop, so drag-selecting text in a field can't dismiss the dialog.
  const backdropMouseDown = useRef(false);

  // Only toasts raised since this dialog opened - never a stale line from behind it.
  const toasts = useToasts();
  const sinceId = useRef(0);
  if (!open) sinceId.current = toasts.length ? toasts[toasts.length - 1].id : 0;
  const own = showToasts ? toasts.filter((x) => x.id > sinceId.current) : [];
  const latest = own.length ? own[own.length - 1] : null;

  const requestClose = useCallback(() => {
    if (lock && allowBusyCancel) {
      (onCancelWhileBusy ?? onClose)();
      return;
    }
    onClose();
  }, [lock, allowBusyCancel, onCancelWhileBusy, onClose]);

  // Focus the first interactive element when the dialog OPENS.
  //
  // Depends on `open` alone, and must stay that way. Panels pass inline arrows
  // for onClose (e.g. `onCancel={closeDialog}` where closeDialog is defined in
  // the panel body), so `requestClose` gets a new identity on every parent
  // render. Keying this effect on it re-ran .focus() constantly while the
  // parent was re-rendering - say, after a site switch, as queries settle -
  // which yanked the caret back to the dialog's first field. Radio buttons
  // still toggled (a click commits their state without keeping focus), so it
  // presented as "only the text boxes and dropdown are dead".
  useEffect(() => {
    if (!open) return;
    const focusable = dialogRef.current?.querySelector<HTMLElement>(
      "input, textarea, button:not([data-modal-close])",
    );
    focusable?.focus();
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && (!lock || allowBusyCancel)) {
        e.stopPropagation();
        requestClose();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, lock, allowBusyCancel, requestClose]);

  if (!open) return null;

  return createPortal(
    <div
      className="modal-backdrop fixed inset-0 flex items-center justify-center"
      style={{ zIndex: Math.max(zIndex, 900) }}
      onMouseDown={(e) => {
        backdropMouseDown.current = e.target === e.currentTarget;
      }}
      onClick={(e) => {
        if (lock && !allowBusyCancel) return;
        if (e.target === e.currentTarget && backdropMouseDown.current) requestClose();
      }}
      role="presentation"
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="modal-window flex max-h-[86vh] flex-col shadow-2xl"
        style={{
          width,
          background: "var(--surface)",
          border: "1px solid var(--border)",
        }}
      >
        <div
          className="modal-header flex items-start gap-3"
          style={{ borderColor: "var(--border)" }}
        >
          <div className="min-w-0 flex-1">
            <div className="modal-title" style={{ color: "var(--text)" }}>
              {title}
            </div>
            {subtitle && (
              <div className="mono mt-[2px] truncate text-[10px]" style={{ color: "var(--text3)" }}>
                {subtitle}
              </div>
            )}
          </div>
          <button
            data-modal-close
            onClick={requestClose}
            disabled={lock && !allowBusyCancel}
            className="text-[16px] leading-none disabled:opacity-50"
            style={{ color: lock && allowBusyCancel ? "var(--err)" : "var(--text3)" }}
            aria-label={lock && allowBusyCancel ? "Cancel" : "Close"}
          >
            x
          </button>
        </div>
        <div className="modal-body min-h-0 flex-1 overflow-auto">{children}</div>
        {latest && (
          <div
            className="flex items-center gap-2 px-3 py-1.5 text-[11px]"
            style={{
              borderTop: "1px solid var(--border)",
              background: "var(--surface2)",
              color:
                latest.variant === "error"
                  ? "var(--red)"
                  : latest.variant === "warn"
                    ? "var(--amber)"
                    : latest.variant === "success"
                      ? "var(--green)"
                      : "var(--text2)",
            }}
            role="status"
          >
            <span className="truncate">
              {latest.title}
              {latest.body ? ` - ${latest.body}` : ""}
            </span>
          </div>
        )}
        {footer && (
          <div
            className="modal-footer flex items-center justify-end gap-2"
            style={{ borderColor: "var(--border)", background: "var(--surface2)" }}
          >
            {footer}
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
}

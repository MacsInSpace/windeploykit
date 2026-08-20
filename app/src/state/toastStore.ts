// Lightweight toast queue. Components call toast.push(...) from anywhere.
// The <Toaster /> mounted once in App.tsx subscribes and renders the stack.

import { useSyncExternalStore } from "react";


export type ToastVariant = "success" | "error" | "info" | "warn";

export interface Toast {
  id: number;
  variant: ToastVariant;
  title: string;
  body?: string;
  /** ms before auto-dismiss; 0 = sticky */
  ttl?: number;
  /** Action button: `url` opens the release link, `onClick` runs a callback. */
  action?: { label: string; url?: string; onClick?: () => void };
  onDismiss?: () => void;
}

let nextId = 1;
let toasts: Toast[] = [];
const listeners = new Set<() => void>();

function emit() {
  for (const l of listeners) l();
}

function dismiss(id: number) {
  const t = toasts.find((x) => x.id === id);
  if (t?.onDismiss) {
    try {
      t.onDismiss();
    } catch {
      /* ignore */
    }
  }
  toasts = toasts.filter((x) => x.id !== id);
  emit();
}

function push(t: Omit<Toast, "id">): number {
  const id = nextId++;
  const ttl = t.ttl ?? (t.variant === "error" ? 7000 : 3500);
  const toast: Toast = { id, ttl, ...t };
  toasts = [...toasts, toast];
  emit();
  if (ttl > 0) {
    setTimeout(() => dismiss(id), ttl);
  }
  return id;
}

export const toast = {
  push,
  dismiss,
  success: (title: string, body?: string) => push({ variant: "success", title, body }),
  error: (title: string, body?: string) => push({ variant: "error", title, body }),
  info: (title: string, body?: string) => push({ variant: "info", title, body }),
  warn: (title: string, body?: string) => push({ variant: "warn", title, body }),
};

export function useToasts(): Toast[] {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => toasts,
    () => toasts,
  );
}

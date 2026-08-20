import { useState, type ReactNode } from "react";

import { Modal } from "./Modal";

export interface ConfirmModalProps {
  open: boolean;
  title: string;
  subtitle?: string;
  body: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
  /** Keep the confirm button disabled (e.g. until a type-to-confirm phrase matches). */
  confirmDisabled?: boolean;
  onCancel: () => void;
  onConfirm: () => Promise<void> | void;
}

export function ConfirmModal({
  open,
  title,
  subtitle,
  body,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  danger,
  confirmDisabled,
  onCancel,
  onConfirm,
}: ConfirmModalProps) {
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try {
      await onConfirm();
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      title={title}
      subtitle={subtitle}
      onClose={busy ? () => {} : onCancel}
      lock={busy}
      footer={
        <>
          <button className="btn" onClick={onCancel} disabled={busy}>
            {cancelLabel}
          </button>
          <button
            className={`btn ${danger ? "btn-danger" : "btn-primary"}`}
            onClick={run}
            disabled={busy || confirmDisabled}
          >
            {busy ? "Working…" : confirmLabel}
          </button>
        </>
      }
    >
      <div className="text-[12px]" style={{ color: "var(--text2)" }}>
        {body}
      </div>
    </Modal>
  );
}

/**
 * Vault editor - see, add and delete the secrets this machine keeps.
 *
 * The sidecar will list names and metadata and will write or delete a secret, but it
 * will never hand a value back to the UI: a secret leaves the sidecar only when a
 * publish step needs it. That is what keeps "from the vault" meaningfully different
 * from typing a password into a task sequence, so this editor shows "set" or "not
 * set", never the secret itself.
 */
import { useCallback, useEffect, useState } from "react";

import { Modal } from "./Modal";
import { sidecar } from "../lib/ipc";
import { toast } from "../state/toastStore";
import type { VaultSecretSummary, VaultSecretsResponse } from "../lib/types";

interface VaultEditorOverlayProps {
  open: boolean;
  onClose: () => void;
  /** Called after any write, so a caller showing the list can refresh. */
  onChange?: () => void;
  /** When set, the overlay offers "Use" on each row and hands the name back. */
  onPick?: (name: string) => void;
  /** Pre-fills the name field - used by "create the secret this field needs". */
  suggestedName?: string;
}

export function VaultEditorOverlay({ open, onClose, onChange, onPick, suggestedName }: VaultEditorOverlayProps) {
  const [secrets, setSecrets] = useState<VaultSecretSummary[]>([]);
  const [vaultReady, setVaultReady] = useState(true);
  const [vaultError, setVaultError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState(suggestedName ?? "");
  const [userName, setUserName] = useState("");
  const [secret, setSecret] = useState("");
  const [note, setNote] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const apply = useCallback(
    (data: VaultSecretsResponse | undefined) => {
      setSecrets(data?.secrets ?? []);
      setVaultReady(Boolean(data?.vault?.ready));
      setVaultError(data?.vault?.error ?? null);
    },
    [],
  );

  const load = useCallback(async () => {
    try {
      apply(await sidecar.invoke<VaultSecretsResponse>("ListVaultSecrets"));
    } catch (e) {
      toast.error("Vault", e instanceof Error ? e.message : String(e));
    }
  }, [apply]);

  useEffect(() => {
    if (!open) return;
    setName(suggestedName ?? "");
    setConfirmDelete(null);
    void load();
  }, [open, suggestedName, load]);

  const save = useCallback(async () => {
    if (!name.trim() || !secret) return;
    setBusy(true);
    try {
      apply(
        await sidecar.invoke<VaultSecretsResponse>("SetVaultSecret", {
          name: name.trim(),
          secret,
          userName: userName.trim(),
          note: note.trim(),
        }),
      );
      toast.success("Vault", `${name.trim()} saved.`);
      // Never keep the typed secret around once it is in the vault.
      setSecret("");
      setNote("");
      onChange?.();
    } catch (e) {
      toast.error("Vault", e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [name, secret, userName, note, apply, onChange]);

  const remove = useCallback(
    async (target: string) => {
      setBusy(true);
      try {
        apply(await sidecar.invoke<VaultSecretsResponse>("RemoveVaultSecret", { name: target }));
        toast.info("Vault", `${target} removed.`);
        setConfirmDelete(null);
        onChange?.();
      } catch (e) {
        toast.error("Vault", e instanceof Error ? e.message : String(e));
      } finally {
        setBusy(false);
      }
    },
    [apply, onChange],
  );

  const existing = secrets.some((s) => s.name === name.trim());

  return (
    <Modal
      open={open}
      title="Vault"
      subtitle="Secrets this machine keeps. Values are never shown - only replaced."
      onClose={onClose}
      lock={busy}
      width={640}
      footer={
        <button type="button" className="btn btn-primary" onClick={onClose} disabled={busy}>
          Done
        </button>
      }
    >
      <div className="flex flex-col gap-4">
        {!vaultReady ? (
          <p className="text-[11px]" style={{ color: "var(--red)" }}>
            The secret vault is not available{vaultError ? ` - ${vaultError}` : "."}
          </p>
        ) : null}

        <section>
          <div className="mono mb-2 text-[9px] font-medium uppercase" style={{ color: "var(--text3)", letterSpacing: "0.15em" }}>
            Stored secrets ({secrets.length})
          </div>
          {secrets.length === 0 ? (
            <p className="text-[11px]" style={{ color: "var(--text2)" }}>
              Nothing stored yet.
            </p>
          ) : (
            <div className="flex flex-col gap-1">
              {secrets.map((s) => (
                <div
                  key={s.name}
                  className="flex items-center gap-2 rounded border px-2 py-1"
                  style={{ borderColor: "var(--border)" }}
                >
                  <span className="mono flex-1 truncate text-[11px]" title={s.note || undefined}>
                    {s.name}
                  </span>
                  <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                    {s.type === "PSCredential" ? "credential" : "secret"}
                    {s.updatedAt ? ` - ${s.updatedAt}` : ""}
                  </span>
                  {onPick ? (
                    <button
                      type="button"
                      className="btn px-1.5 py-0 text-[10px]"
                      disabled={busy}
                      onClick={() => {
                        onPick(s.name);
                        onClose();
                      }}
                    >
                      Use
                    </button>
                  ) : null}
                  <button
                    type="button"
                    className="btn px-1.5 py-0 text-[10px]"
                    disabled={busy}
                    onClick={() => setName(s.name)}
                    title="Load the name into the form below to replace its value"
                  >
                    Replace
                  </button>
                  {confirmDelete === s.name ? (
                    <button
                      type="button"
                      className="btn btn-danger px-1.5 py-0 text-[10px]"
                      disabled={busy}
                      onClick={() => void remove(s.name)}
                    >
                      Confirm
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="btn px-1.5 py-0 text-[10px]"
                      disabled={busy}
                      onClick={() => setConfirmDelete(s.name)}
                    >
                      Delete
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}
        </section>

        <section>
          <div className="mono mb-2 text-[9px] font-medium uppercase" style={{ color: "var(--text3)", letterSpacing: "0.15em" }}>
            {existing ? "Replace a secret" : "Add a secret"}
          </div>
          <div className="flex flex-col gap-1.5">
            <input
              className="input-box mono h-[26px] text-[11px]"
              placeholder="Name (letters, numbers, dot, dash, underscore)"
              value={name}
              spellCheck={false}
              onChange={(e) => setName(e.target.value)}
            />
            <input
              className="input-box mono h-[26px] text-[11px]"
              placeholder="User name - optional, e.g. CORP\deployadmin (makes it a credential)"
              value={userName}
              spellCheck={false}
              onChange={(e) => setUserName(e.target.value)}
            />
            <input
              type="password"
              className="input-box h-[26px] text-[11px]"
              placeholder={existing ? "New value (replaces the stored one)" : "Value"}
              value={secret}
              onChange={(e) => setSecret(e.target.value)}
            />
            <input
              className="input-box h-[26px] text-[11px]"
              placeholder="Note - optional, e.g. what this is for"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
            <div className="flex items-center gap-2">
              <button
                type="button"
                className="btn btn-primary px-2 py-0.5 text-[11px]"
                disabled={busy || !vaultReady || !name.trim() || !secret}
                onClick={() => void save()}
              >
                {existing ? "Replace" : "Add"}
              </button>
              <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                A user name makes it a credential (both halves), which is what a domain join needs.
              </span>
            </div>
          </div>
        </section>
      </div>
    </Modal>
  );
}

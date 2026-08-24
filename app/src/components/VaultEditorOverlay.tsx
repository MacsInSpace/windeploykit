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
  /** Pre-fills the label - used by "create the credential this field needs". */
  suggestedName?: string;
}

export function VaultEditorOverlay({ open, onClose, onChange, onPick, suggestedName }: VaultEditorOverlayProps) {
  const [secrets, setSecrets] = useState<VaultSecretSummary[]>([]);
  const [vaultReady, setVaultReady] = useState(true);
  const [vaultError, setVaultError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Label / Full name / Username / Password. The storage key is derived from the
  // label by the sidecar - nobody should have to invent one (Craig, 2026-08-23).
  // `replaceKey` is set only when replacing an existing entry's password.
  const [label, setLabel] = useState(suggestedName ?? "");
  const [fullName, setFullName] = useState("");
  const [userName, setUserName] = useState("");
  const [secret, setSecret] = useState("");
  const [replaceKey, setReplaceKey] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  // Which field is stopping the save, and why. A disabled button that will not say
  // what is missing is the same as no button at all (Craig, 2026-08-24: pressed Add,
  // "there was no feedback or confirmation").
  const [problem, setProblem] = useState<{ field: "label" | "userName" | "secret" | "vault"; text: string } | null>(null);

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
    setLabel(suggestedName ?? "");
    setReplaceKey("");
    setConfirmDelete(null);
    setProblem(null);
    void load();
  }, [open, suggestedName, load]);

  const save = useCallback(async () => {
    if (!vaultReady) {
      setProblem({ field: "vault", text: `The secret vault is not available${vaultError ? ` - ${vaultError}` : "."}` });
      return;
    }
    if (!label.trim()) {
      setProblem({ field: "label", text: "A label is needed - it is what the menus show." });
      return;
    }
    if (!userName.trim()) {
      setProblem({ field: "userName", text: "A user name is needed: a credential is both halves." });
      return;
    }
    if (!secret) {
      setProblem({ field: "secret", text: "A password is needed." });
      return;
    }
    setProblem(null);
    setBusy(true);
    try {
      apply(
        await sidecar.invoke<VaultSecretsResponse>("SetVaultSecret", {
          // name only when replacing: otherwise the sidecar derives the key from the label.
          name: replaceKey,
          label: label.trim(),
          fullName: fullName.trim(),
          userName: userName.trim(),
          secret,
        }),
      );
      toast.success("Vault", `${label.trim()} saved.`);
      // Clear the whole form on an add: leaving what you typed sitting there reads as
      // "nothing happened". On a replace, keep the details and drop only the password.
      setSecret("");
      if (!replaceKey) {
        setLabel("");
        setFullName("");
        setUserName("");
      }
      setReplaceKey("");
      onChange?.();
    } catch (e) {
      toast.error("Vault", e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [label, fullName, userName, secret, replaceKey, vaultReady, vaultError, apply, onChange]);

  /** Amber outline on the field that stopped the last save. */
  const outline = (field: "label" | "userName" | "secret") =>
    problem?.field === field ? { borderColor: "var(--amber)" } : undefined;

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

  const existing = secrets.some((s) => (s.label || s.name) === label.trim());

  return (
    <Modal
      open={open}
      title="Vault"
      subtitle="Credentials this machine keeps. Passwords are never shown - only replaced."
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
            Stored ({secrets.length})
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
                  <span className="flex-1 truncate text-[11px]" title={`${s.name}${s.userName ? ` - ${s.userName}` : ""}`}>
                    {s.label || s.name}
                    {s.userName ? (
                      <span className="mono ml-1.5 text-[10px]" style={{ color: "var(--text3)" }}>
                        {s.userName}
                      </span>
                    ) : null}
                  </span>
                  <span className="text-[10px]" style={{ color: "var(--text3)" }}>
                    {s.fullName ? `${s.fullName} - ` : ""}
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
                    onClick={() => {
                      setReplaceKey(s.name);
                      setLabel(s.label || s.name);
                      setFullName(s.fullName ?? "");
                      setUserName(s.userName ?? "");
                      setSecret("");
                    }}
                    title="Load this entry into the form below to replace its password"
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
            {replaceKey || existing ? "Replace a credential" : "Add a credential"}
          </div>
          <div className="flex flex-col gap-1.5">
            <input
              className="input-box h-[26px] text-[11px]"
              placeholder="Label - what you will see in the menus, e.g. Local admin (imaging)"
              style={outline("label")}
              value={label}
              onChange={(e) => {
                setLabel(e.target.value);
                if (problem?.field === "label") setProblem(null);
              }}
            />
            <input
              className="input-box h-[26px] text-[11px]"
              placeholder="Full name - e.g. Local Admin"
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
            />
            <input
              className="input-box mono h-[26px] text-[11px]"
              placeholder="Username - no spaces; domain optional, e.g. CORP\\deployadmin"
              style={outline("userName")}
              value={userName}
              spellCheck={false}
              onChange={(e) => {
                setUserName(e.target.value.replace(/\s+/g, ""));
                if (problem?.field === "userName") setProblem(null);
              }}
            />
            <input
              type="password"
              className="input-box h-[26px] text-[11px]"
              placeholder={replaceKey ? "New password (replaces the stored one)" : "Password"}
              style={outline("secret")}
              value={secret}
              onChange={(e) => {
                setSecret(e.target.value);
                if (problem?.field === "secret") setProblem(null);
              }}
            />
            <div className="flex items-center gap-2">
              <button
                type="button"
                className="btn btn-primary px-2 py-0.5 text-[11px]"
                disabled={busy}
                onClick={() => void save()}
              >
                {replaceKey ? "Replace" : "Add"}
              </button>
              {replaceKey ? (
                <button
                  type="button"
                  className="btn px-2 py-0.5 text-[11px]"
                  onClick={() => {
                    setReplaceKey("");
                    setLabel("");
                    setFullName("");
                    setUserName("");
                    setSecret("");
                  }}
                >
                  Cancel
                </button>
              ) : null}
              <span
                className="text-[10px]"
                style={{ color: problem ? "var(--amber)" : "var(--text3)" }}
              >
                {problem
                  ? problem.text
                  : replaceKey
                    ? `Replacing ${replaceKey}`
                    : "Stored as a credential - both halves, which is what a join or a local account needs."}
              </span>
            </div>
          </div>
        </section>
      </div>
    </Modal>
  );
}

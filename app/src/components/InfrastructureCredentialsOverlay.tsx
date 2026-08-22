/**
 * Credentials - the local administrator for this machine, plus any other logins
 * worth keeping.
 *
 * Rewritten 2026-08-22 (Craig: "its a mess... redo the overlays"). What went, and why:
 *
 *  - Site filtering. Every credential was passed through filterCredentialsForSite,
 *    which returns [] when there is no site - and this product has no sites. Saving
 *    worked; the list simply never rendered what you saved, which read as "cannot add
 *    more than one set of creds". Gone, along with the site default section.
 *  - The explanatory paragraphs (store location, what host elevation does, what SSH /
 *    RDP / web logins are). A credential manager should show credentials.
 *
 * What is left is the whole feature: a local administrator, and a list of label /
 * username / password rows.
 */
import { useCallback, useEffect, useState } from "react";

import { Modal } from "./Modal";
import { sidecar } from "../lib/ipc";
import { toast } from "../state/toastStore";
import type {
  InfraSshCredentialSummary,
  ListInfraSshCredentialsResult,
  LocalMachineCredentialStatus,
} from "../lib/types";

interface InfrastructureCredentialsOverlayProps {
  open: boolean;
  onClose: () => void;
  onVaultChange?: () => void;
}

/** A row being edited. Passwords are write-only: what is stored is never sent back. */
interface DraftRow {
  id: string;
  label: string;
  loginName: string;
  password: string;
  configured: boolean;
  isNew?: boolean;
}

let newRowSeq = 0;

function toDraft(c: InfraSshCredentialSummary): DraftRow {
  return {
    id: c.id,
    label: c.label ?? "",
    loginName: c.loginName ?? "",
    password: "",
    configured: Boolean(c.configured),
  };
}

export function InfrastructureCredentialsOverlay({
  open,
  onClose,
  onVaultChange,
}: InfrastructureCredentialsOverlayProps) {
  const [rows, setRows] = useState<DraftRow[]>([]);
  const [local, setLocal] = useState<LocalMachineCredentialStatus | null>(null);
  const [localUser, setLocalUser] = useState("");
  const [localPassword, setLocalPassword] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [list, localStatus] = await Promise.all([
        sidecar.invoke<ListInfraSshCredentialsResult>("ListInfraSshCredentials", {}),
        sidecar.invoke<LocalMachineCredentialStatus>("GetLocalMachineCredential", {}),
      ]);
      // No site filter: everything saved on this machine is shown.
      setRows((list?.credentials ?? []).filter((c) => !c.builtIn).map(toDraft));
      setLocal(localStatus ?? null);
      setLocalUser(localStatus?.loginName ?? "");
    } catch (e) {
      toast.error("Credentials", e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    setLocalPassword("");
    void load();
  }, [open, load]);

  const patch = (id: string, change: Partial<DraftRow>) =>
    setRows((prev) => prev.map((r) => (r.id === id ? { ...r, ...change } : r)));

  const saveLocal = useCallback(async () => {
    setBusy(true);
    try {
      await sidecar.invoke("SetLocalMachineCredential", {
        loginName: localUser.trim(),
        password: localPassword,
      });
      toast.success("Credentials", "Local administrator saved.");
      setLocalPassword("");
      await load();
      onVaultChange?.();
    } catch (e) {
      toast.error("Credentials", e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [localUser, localPassword, load, onVaultChange]);

  const clearLocal = useCallback(async () => {
    setBusy(true);
    try {
      await sidecar.invoke("ClearLocalMachineCredentialPassword", {});
      toast.info("Credentials", "Local administrator password cleared.");
      setLocalPassword("");
      await load();
      onVaultChange?.();
    } catch (e) {
      toast.error("Credentials", e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [load, onVaultChange]);

  const saveRow = useCallback(
    async (row: DraftRow) => {
      if (!row.label.trim()) {
        toast.error("Credentials", "A label is required.");
        return;
      }
      setBusy(true);
      try {
        await sidecar.invoke("SetInfraSshCredential", {
          // A new row has no server id yet: sending an empty one mints a fresh
          // credential instead of overwriting whichever row was edited last.
          id: row.isNew ? "" : row.id,
          label: row.label.trim(),
          loginName: row.loginName.trim(),
          password: row.password,
        });
        toast.success("Credentials", `${row.label.trim()} saved.`);
        await load();
        onVaultChange?.();
      } catch (e) {
        toast.error("Credentials", e instanceof Error ? e.message : String(e));
      } finally {
        setBusy(false);
      }
    },
    [load, onVaultChange],
  );

  const removeRow = useCallback(
    async (row: DraftRow) => {
      if (row.isNew) {
        setRows((prev) => prev.filter((r) => r.id !== row.id));
        return;
      }
      setBusy(true);
      try {
        await sidecar.invoke("DeleteInfraSshCredential", { id: row.id });
        toast.info("Credentials", `${row.label || row.id} removed.`);
        await load();
        onVaultChange?.();
      } catch (e) {
        toast.error("Credentials", e instanceof Error ? e.message : String(e));
      } finally {
        setBusy(false);
      }
    },
    [load, onVaultChange],
  );

  return (
    <Modal
      open={open}
      title="Credentials"
      onClose={onClose}
      lock={busy}
      width={620}
      footer={
        <button type="button" className="btn btn-primary" onClick={onClose} disabled={busy}>
          Done
        </button>
      }
    >
      <div className="flex flex-col gap-5">
        <section>
          <div className="mono mb-2 text-[9px] font-medium uppercase" style={{ color: "var(--text3)", letterSpacing: "0.15em" }}>
            This computer - local administrator
          </div>
          <div className="flex flex-wrap items-center gap-1.5">
            <input
              className="input-box mono h-[26px] min-w-[11rem] flex-1 text-[11px]"
              placeholder="Username"
              value={localUser}
              spellCheck={false}
              onChange={(e) => setLocalUser(e.target.value)}
            />
            <input
              type="password"
              className="input-box h-[26px] min-w-[11rem] flex-1 text-[11px]"
              placeholder={local?.configured ? "Saved - type to replace" : "Password"}
              value={localPassword}
              onChange={(e) => setLocalPassword(e.target.value)}
            />
            <button
              type="button"
              className="btn btn-primary px-2 py-0.5 text-[11px]"
              disabled={busy || !localUser.trim() || !localPassword}
              onClick={() => void saveLocal()}
            >
              Save
            </button>
            {local?.configured ? (
              <button type="button" className="btn px-2 py-0.5 text-[11px]" disabled={busy} onClick={() => void clearLocal()}>
                Clear
              </button>
            ) : null}
          </div>
        </section>

        <section>
          <div className="mb-2 flex items-center gap-2">
            <span className="mono text-[9px] font-medium uppercase" style={{ color: "var(--text3)", letterSpacing: "0.15em" }}>
              Additional credentials
            </span>
            <button
              type="button"
              className="btn ml-auto px-2 py-0.5 text-[10px]"
              disabled={busy}
              onClick={() =>
                setRows((prev) => [
                  ...prev,
                  { id: `new-${newRowSeq++}`, label: "", loginName: "", password: "", configured: false, isNew: true },
                ])
              }
            >
              + Add
            </button>
          </div>
          {rows.length === 0 ? (
            <p className="text-[11px]" style={{ color: "var(--text2)" }}>
              None yet.
            </p>
          ) : (
            <div className="flex flex-col gap-1.5">
              {rows.map((row) => (
                <div key={row.id} className="flex flex-wrap items-center gap-1.5">
                  <input
                    className="input-box h-[26px] w-[9rem] text-[11px]"
                    placeholder="Label"
                    value={row.label}
                    onChange={(e) => patch(row.id, { label: e.target.value })}
                  />
                  <input
                    className="input-box mono h-[26px] w-[11rem] text-[11px]"
                    placeholder="Username"
                    value={row.loginName}
                    spellCheck={false}
                    onChange={(e) => patch(row.id, { loginName: e.target.value })}
                  />
                  <input
                    type="password"
                    className="input-box h-[26px] min-w-[9rem] flex-1 text-[11px]"
                    placeholder={row.configured ? "Saved - type to replace" : "Password"}
                    value={row.password}
                    onChange={(e) => patch(row.id, { password: e.target.value })}
                  />
                  <button
                    type="button"
                    className="btn btn-primary px-2 py-0.5 text-[11px]"
                    disabled={busy || !row.label.trim()}
                    onClick={() => void saveRow(row)}
                  >
                    Save
                  </button>
                  <button type="button" className="btn px-2 py-0.5 text-[11px]" disabled={busy} onClick={() => void removeRow(row)}>
                    Remove
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>
      </div>
    </Modal>
  );
}

import { useCallback, useEffect, useMemo, useState } from "react";

import { Modal } from "./Modal";
import { CredentialSelect } from "./CredentialSelect";
import { sidecar, SidecarError } from "../lib/ipc";
import {
  isDefaultInfraCredentialId,
  filterCredentialsForSchool,
  schoolDefaultCredentials,
  sortCredentialsForSchool,
  getSiteSwitchDefaultCredentialId,
  setSiteSwitchDefaultCredentialId,
} from "../lib/infrastructureDefaultCredentials";
import { clearCredentialAssignmentsForId } from "../lib/infrastructureCredentialAssignments";
import { resolveInfraCredentialLoginName } from "../lib/infrastructureCredentials";
import { toast } from "../state/toastStore";
import type {
  InfraSshCredentialSummary,
  ListInfraSshCredentialsResult,
  LocalMachineCredentialStatus,
} from "../lib/types";

const INFRA_LOGIN_USERNAME_PLACEHOLDER = `SSH / RDP / web username (e.g. CURRIC\\eduadmin)`;
const LOCAL_ADMIN_USERNAME_PLACEHOLDER = "Local admin username (e.g. st00447)";

interface InfrastructureCredentialsOverlayProps {
  open: boolean;
  onClose: () => void;
  schoolNumber?: string;
  onVaultChange?: () => void;
}

function CredentialPasswordRow({
  cred,
  busy,
  loginName,
  password,
  onLoginNameChange,
  loginNameEditable = false,
  onPasswordChange,
  onSave,
  onClear,
  onDelete,
}: {
  cred: InfraSshCredentialSummary;
  busy: boolean;
  loginName: string;
  password: string;
  onLoginNameChange?: (value: string) => void;
  loginNameEditable?: boolean;
  onPasswordChange: (value: string) => void;
  onSave: () => void;
  onClear?: () => void;
  onDelete?: () => void;
}) {
  const resolvedLogin = resolveInfraCredentialLoginName(cred) ?? "";
  return (
    <div
      className="flex flex-col gap-2 rounded-sm px-3 py-2"
      style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className="mono text-[12px] font-medium" style={{ color: "var(--text)" }}>
          {cred.label}
        </span>
        {cred.isDefault && <span className="badge badge-info">Default</span>}
        {!cred.configured && (
          <span className="badge badge-warn">Password not set</span>
        )}
        {onDelete && (
          <button
            type="button"
            className="btn btn-danger ml-auto shrink-0"
            style={{ padding: "2px 8px", fontSize: "10px" }}
            disabled={busy}
            onClick={onDelete}
          >
            Delete
          </button>
        )}
      </div>
      {loginNameEditable ? (
        <div className="input-box w-full">
          <input
            className="mono w-full bg-transparent text-[11px] outline-none"
            placeholder={INFRA_LOGIN_USERNAME_PLACEHOLDER}
            value={loginName}
            disabled={busy}
            onChange={(e) => onLoginNameChange?.(e.target.value)}
          />
        </div>
      ) : (
        <div className="text-[10px]" style={{ color: "var(--text3)" }}>
          Login: <span className="mono" style={{ color: "var(--text2)" }}>{resolvedLogin || "—"}</span>
        </div>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <div className="input-box min-w-[10rem] flex-1">
          <input
            type="password"
            className="mono w-full bg-transparent text-[11px] outline-none"
            placeholder={cred.configured ? "Enter new password" : "SSH / RDP / web password"}
            value={password}
            disabled={busy}
            onChange={(e) => onPasswordChange(e.target.value)}
          />
        </div>
        <button
          type="button"
          className="btn btn-primary shrink-0"
          style={{ fontSize: "11px" }}
          disabled={busy}
          onClick={onSave}
        >
          Save
        </button>
        {cred.configured && onClear && (
          <button
            type="button"
            className="btn shrink-0"
            style={{ fontSize: "11px" }}
            disabled={busy}
            onClick={onClear}
          >
            Clear
          </button>
        )}
      </div>
    </div>
  );
}

export function InfrastructureCredentialsOverlay({
  open,
  onClose,
  schoolNumber,
  onVaultChange,
}: InfrastructureCredentialsOverlayProps) {
  const [credentials, setCredentials] = useState<InfraSshCredentialSummary[]>([]);
  const [storePath, setStorePath] = useState<string>("");
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [newLabel, setNewLabel] = useState("");
  const [newLoginName, setNewLoginName] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [passwordDrafts, setPasswordDrafts] = useState<Record<string, string>>({});
  const [loginDrafts, setLoginDrafts] = useState<Record<string, string>>({});
  const [localMachine, setLocalMachine] = useState<LocalMachineCredentialStatus | null>(null);
  const [localLoginDraft, setLocalLoginDraft] = useState("");
  const [localPasswordDraft, setLocalPasswordDraft] = useState("");

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [infraResult, localResult] = await Promise.all([
        sidecar.invoke<ListInfraSshCredentialsResult>("ListInfraSshCredentials", {
          schoolNumber,
        }),
        sidecar.invoke<LocalMachineCredentialStatus>("GetLocalMachineCredential", {}),
      ]);
      const sorted = sortCredentialsForSchool(
        filterCredentialsForSchool(infraResult.credentials ?? [], schoolNumber),
        schoolNumber,
      );
      setCredentials(sorted);
      setStorePath(infraResult.storePath ?? "");
      setLocalMachine(localResult);
      setLocalLoginDraft((prev) =>
        prev && localResult.configured ? prev : (localResult.loginName ?? ""),
      );
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not load credentials", e.message);
      setCredentials([]);
    } finally {
      setLoading(false);
    }
  }, [schoolNumber]);

  useEffect(() => {
    if (open) void reload();
  }, [open, reload]);

  const schoolDefaults = useMemo(
    () => schoolDefaultCredentials(credentials, schoolNumber),
    [credentials, schoolNumber],
  );
  const customCredentials = useMemo(
    // builtIn = app-provided virtual entries (signed-in DE account) — offered in
    // pickers but not managed here: nothing on disk to edit or delete.
    () => credentials.filter((c) => !isDefaultInfraCredentialId(c.id) && !c.builtIn),
    [credentials],
  );
  const siteSwitchDefaultId = schoolNumber
    ? getSiteSwitchDefaultCredentialId(schoolNumber)
    : undefined;

  const savePassword = async (cred: InfraSshCredentialSummary) => {
    const password = passwordDrafts[cred.id]?.trim();
    const loginDraft = loginDrafts[cred.id]?.trim();
    const savedLogin = resolveInfraCredentialLoginName(cred) ?? "";
    const loginName = loginDraft || (cred.isDefault ? savedLogin : undefined);
    const loginChanged = loginDraft !== undefined && loginDraft !== savedLogin;

    if (!password && !cred.configured) {
      toast.warn("Infrastructure credentials", "Enter a password to save.");
      return;
    }
    if (!password && cred.configured && !loginChanged) {
      toast.warn("Infrastructure credentials", "Enter a new password or change the username.");
      return;
    }
    if (!loginName) {
      toast.warn(
        "Infrastructure credentials",
        cred.isDefault ? "Username is required." : "Username is required for additional credentials.",
      );
      return;
    }
    setBusy(true);
    try {
      await sidecar.invoke("SetInfraSshCredential", {
        id: cred.id,
        label: cred.label,
        password: password || undefined,
        loginName,
        schoolNumber,
      });
      setPasswordDrafts((s) => {
        const next = { ...s };
        delete next[cred.id];
        return next;
      });
      setLoginDrafts((s) => {
        const next = { ...s };
        delete next[cred.id];
        return next;
      });
      await reload();
      onVaultChange?.();
      toast.success("Credential saved", cred.label);
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not save credential", e.message);
    } finally {
      setBusy(false);
    }
  };

  const clearPassword = async (cred: InfraSshCredentialSummary) => {
    setBusy(true);
    try {
      await sidecar.invoke("ClearInfraSshCredentialPassword", { id: cred.id });
      await reload();
      onVaultChange?.();
      toast.success("Password cleared", cred.label);
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not clear password", e.message);
    } finally {
      setBusy(false);
    }
  };

  const addCredential = async () => {
    if (!schoolNumber) {
      toast.warn("Infrastructure credentials", "Connect a school before adding site credentials.");
      return;
    }
    if (!newLabel.trim() || !newLoginName.trim() || !newPassword) {
      toast.warn("Infrastructure credentials", "Label, username, and password are required.");
      return;
    }
    setBusy(true);
    try {
      await sidecar.invoke("SetInfraSshCredential", {
        label: newLabel.trim(),
        loginName: newLoginName.trim(),
        password: newPassword,
        schoolNumber,
      });
      setNewLabel("");
      setNewLoginName("");
      setNewPassword("");
      await reload();
      onVaultChange?.();
      toast.success("Credential saved", "Encrypted on this device for your user account.");
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not save credential", e.message);
    } finally {
      setBusy(false);
    }
  };

  const saveLocalMachineCredential = async () => {
    const loginName = localLoginDraft.trim();
    const password = localPasswordDraft.trim();
    const loginChanged = loginName !== (localMachine?.loginName ?? "").trim();
    if (!loginName) {
      toast.warn("Local administrator", "Username is required.");
      return;
    }
    if (!password && !localMachine?.configured) {
      toast.warn("Local administrator", "Enter a password to save.");
      return;
    }
    if (!password && localMachine?.configured && !loginChanged) {
      toast.warn("Local administrator", "Enter a new password or change the username.");
      return;
    }
    setBusy(true);
    try {
      await sidecar.invoke("SetLocalMachineCredential", {
        loginName,
        password: password || undefined,
      });
      setLocalPasswordDraft("");
      await reload();
      onVaultChange?.();
      toast.success(
        "Local administrator saved",
        "Encrypted on this device. Used for host elevation and SMB share setup; clients can auth with this account.",
      );
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not save local administrator", e.message);
    } finally {
      setBusy(false);
    }
  };

  const clearLocalMachinePassword = async () => {
    setBusy(true);
    try {
      await sidecar.invoke("ClearLocalMachineCredentialPassword", {});
      setLocalPasswordDraft("");
      await reload();
      onVaultChange?.();
      toast.success("Local administrator cleared", "Password removed from this device.");
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not clear local administrator", e.message);
    } finally {
      setBusy(false);
    }
  };

  const loadLocalMachineToSession = async () => {
    setBusy(true);
    try {
      const result = await sidecar.invoke<{ loaded: boolean; sessionCached: boolean }>(
        "LoadLocalMachineCredentialToSession",
        {},
      );
      await reload();
      onVaultChange?.();
      if (result.loaded || result.sessionCached) {
        toast.success("Local administrator loaded", "Session cache ready for sudo elevation.");
      } else {
        toast.warn("Local administrator", "Save a password first, then load into session.");
      }
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not load local administrator", e.message);
    } finally {
      setBusy(false);
    }
  };

  const deleteCredential = async (cred: InfraSshCredentialSummary) => {
    if (
      typeof window !== "undefined" &&
      !window.confirm(`Delete "${cred.label}"? Device assignments will be cleared.`)
    ) {
      return;
    }
    setBusy(true);
    try {
      await sidecar.invoke("DeleteInfraSshCredential", { id: cred.id });
      clearCredentialAssignmentsForId(cred.id);
      await reload();
      onVaultChange?.();
      toast.success("Credential deleted", cred.label);
    } catch (err) {
      const e = err instanceof SidecarError ? err : new Error(String(err));
      toast.error("Could not delete credential", e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open={open}
      title="Infrastructure credentials"
      subtitle="SSH, RDP, web logins, and optional local administrator — encrypted on this device (Export-Clixml)."
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
          <div
            className="mono mb-2 text-[9px] font-medium uppercase"
            style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
          >
            Store location
          </div>
          <div
            className="rounded-sm px-3 py-2 text-[10.5px]"
            style={{ background: "var(--surface2)", border: "1px solid var(--border)", color: "var(--text2)" }}
          >
            <span className="mono" style={{ color: "var(--text)" }}>
              {storePath || "…/WinDeployKit/plugins/infrastructure-ssh/"}
            </span>
            <div className="mt-1" style={{ color: "var(--text3)" }}>
              School-scoped passwords for switch SSH, WLC web, off-domain server RDP/SSH, and similar.
              Local administrator credentials are stored separately (see below).
            </div>
          </div>
        </section>

        <section>
          <div
            className="mono mb-2 text-[9px] font-medium uppercase"
            style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
          >
            This computer — local administrator
          </div>
          <p className="mb-3 text-[10.5px] leading-snug" style={{ color: "var(--text3)" }}>
            Optional password for this workstation — not tied to a school. Same account you use to
            administer this machine. School Manager uses it for host-side elevation (PXE TFTP on port
            69, SMB share create/remove via <span className="mono">sharing</span>, routes, and
            similar) without prompting every time. When Site Build or other workflows export an SMB
            share, Windows and Linux clients connect with this username and the password saved here
            (not guest). Windows host elevation from this vault is planned; share creation still
            uses your current admin token when you are already elevated. Session cache loads on save
            until you quit or choose Forget password in PXE.
          </p>
          {loading && !localMachine ? (
            <div className="text-[11px]" style={{ color: "var(--text3)" }}>
              Loading…
            </div>
          ) : (
            <div
              className="flex flex-col gap-2 rounded-sm px-3 py-2"
              style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
            >
              <div className="flex flex-wrap items-center gap-2">
                <span className="mono text-[12px] font-medium" style={{ color: "var(--text)" }}>
                  {localMachine?.label ?? "Local administrator (this computer)"}
                </span>
                {!localMachine?.configured && (
                  <span className="badge badge-warn">Password not set</span>
                )}
                {localMachine?.configured && localMachine.sessionCached && (
                  <span className="badge badge-info">Session cached</span>
                )}
                {localMachine?.wiredForMacOs && (
                  <span className="badge">Host admin</span>
                )}
              </div>
              {localMachine?.storePath && (
                <div className="text-[10px]" style={{ color: "var(--text3)" }}>
                  Store:{" "}
                  <span className="mono" style={{ color: "var(--text2)" }}>
                    {localMachine.storePath}
                  </span>
                </div>
              )}
              <div className="input-box w-full">
                <input
                  className="mono w-full bg-transparent text-[11px] outline-none"
                  placeholder={LOCAL_ADMIN_USERNAME_PLACEHOLDER}
                  value={localLoginDraft}
                  disabled={busy}
                  onChange={(e) => setLocalLoginDraft(e.target.value)}
                />
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <div className="input-box min-w-[10rem] flex-1">
                  <input
                    type="password"
                    className="mono w-full bg-transparent text-[11px] outline-none"
                    placeholder={
                      localMachine?.configured
                        ? "Enter new password"
                        : "Local administrator password"
                    }
                    value={localPasswordDraft}
                    disabled={busy}
                    onChange={(e) => setLocalPasswordDraft(e.target.value)}
                  />
                </div>
                <button
                  type="button"
                  className="btn btn-primary shrink-0"
                  style={{ fontSize: "11px" }}
                  disabled={busy}
                  onClick={() => void saveLocalMachineCredential()}
                >
                  Save
                </button>
                {localMachine?.configured && (
                  <button
                    type="button"
                    className="btn shrink-0"
                    style={{ fontSize: "11px" }}
                    disabled={busy}
                    onClick={() => void clearLocalMachinePassword()}
                  >
                    Clear
                  </button>
                )}
                {localMachine?.configured && !localMachine.sessionCached && (
                  <button
                    type="button"
                    className="btn shrink-0"
                    style={{ fontSize: "11px" }}
                    disabled={busy}
                    onClick={() => void loadLocalMachineToSession()}
                  >
                    Load session
                  </button>
                )}
              </div>
            </div>
          )}
        </section>

        <section>
          <div
            className="mono mb-2 text-[9px] font-medium uppercase"
            style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
          >
            Default credentials
            {schoolNumber ? ` · school ${schoolNumber.padStart(4, "0")}` : ""}
          </div>
          <p className="mb-3 text-[10.5px] leading-snug" style={{ color: "var(--text3)" }}>
            {`{sn}`}SchoolAdmin and {`{sn}`}WLCMonitor passwords are site-specific and randomly
            generated — they are issued to schools and most techs already have them. If yours
            is missing, request it from the service desk. Save them here when you have them;
            you&apos;ll need these for switch config backups and Wi-Fi insights. Edit the
            username when a site uses a non-standard spelling (e.g. {`{sn}`}WLCCmonitor).
          </p>
          {!schoolNumber ? (
            <div className="text-[11px]" style={{ color: "var(--text3)" }}>
              Connect a school to manage {`{sn}`}SchoolAdmin and {`{sn}`}WLCMonitor defaults.
            </div>
          ) : loading ? (
            <div className="text-[11px]" style={{ color: "var(--text3)" }}>
              Loading…
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {schoolDefaults.map((cred) => (
                <CredentialPasswordRow
                  key={cred.id}
                  cred={cred}
                  busy={busy}
                  loginNameEditable
                  loginName={loginDrafts[cred.id] ?? resolveInfraCredentialLoginName(cred) ?? ""}
                  password={passwordDrafts[cred.id] ?? ""}
                  onLoginNameChange={(value) =>
                    setLoginDrafts((s) => ({ ...s, [cred.id]: value }))
                  }
                  onPasswordChange={(value) =>
                    setPasswordDrafts((s) => ({ ...s, [cred.id]: value }))
                  }
                  onSave={() => void savePassword(cred)}
                  onClear={() => void clearPassword(cred)}
                />
              ))}
              <div
                className="mt-2 rounded-sm px-3 py-2"
                style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
              >
                <div className="mb-1 text-[10.5px] font-semibold" style={{ color: "var(--text)" }}>
                  Default for discovered switches
                </div>
                <p className="mb-2 text-[10px] leading-snug" style={{ color: "var(--text3)" }}>
                  Inherited when CDP/LLDP finds a switch that has no Infrastructure row or per-device assignment.
                  This does not automatically add the switch to Infrastructure.
                </p>
                <CredentialSelect
                  credentials={credentials}
                  value={siteSwitchDefaultId}
                  disabled={busy}
                  className="input-box w-full text-[11px]"
                  onChange={(credentialId) => {
                    if (!schoolNumber) return;
                    setSiteSwitchDefaultCredentialId(schoolNumber, credentialId);
                    onVaultChange?.();
                    toast.success(
                      "Site switch default updated",
                      credentialId
                        ? "Newly discovered switches will inherit this credential."
                        : `${schoolNumber.padStart(4, "0")}SchoolAdmin will be used as the fallback.`,
                    );
                  }}
                />
              </div>
            </div>
          )}
        </section>

        <section>
          <div
            className="mono mb-2 text-[9px] font-medium uppercase"
            style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
          >
            Additional credentials
          </div>
          <p className="mb-3 text-[10.5px] leading-snug" style={{ color: "var(--text3)" }}>
            Off-domain servers, legacy gear, local admin accounts — label is for your reference;
            username is what SSH / RDP / web clients use at login.
          </p>
          <div className="mb-3 flex flex-col gap-2">
            <div className="input-box w-full">
              <input
                className="w-full bg-transparent text-[11px] outline-none"
                placeholder="Label (e.g. ESXi host, backup NAS)"
                value={newLabel}
                disabled={busy}
                onChange={(e) => setNewLabel(e.target.value)}
              />
            </div>
            <div className="input-box w-full">
              <input
                className="mono w-full bg-transparent text-[11px] outline-none"
                placeholder={INFRA_LOGIN_USERNAME_PLACEHOLDER}
                value={newLoginName}
                disabled={busy}
                onChange={(e) => setNewLoginName(e.target.value)}
              />
            </div>
            <div className="input-box w-full">
              <input
                type="password"
                className="mono w-full bg-transparent text-[11px] outline-none"
                placeholder="SSH / RDP / web password"
                value={newPassword}
                disabled={busy}
                onChange={(e) => setNewPassword(e.target.value)}
              />
            </div>
            <button
              type="button"
              className="btn btn-primary self-start"
              style={{ fontSize: "11px" }}
              disabled={busy}
              onClick={() => void addCredential()}
            >
              Save credential
            </button>
          </div>
          {customCredentials.length === 0 ? (
            <div className="text-[11px]" style={{ color: "var(--text3)" }}>
              No extra credentials — use defaults above or add site-specific passwords here.
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {customCredentials.map((cred) => (
                <CredentialPasswordRow
                  key={cred.id}
                  cred={cred}
                  busy={busy}
                  loginNameEditable
                  loginName={
                    loginDrafts[cred.id] ?? resolveInfraCredentialLoginName(cred) ?? ""
                  }
                  password={passwordDrafts[cred.id] ?? ""}
                  onLoginNameChange={(value) =>
                    setLoginDrafts((s) => ({ ...s, [cred.id]: value }))
                  }
                  onPasswordChange={(value) =>
                    setPasswordDrafts((s) => ({ ...s, [cred.id]: value }))
                  }
                  onSave={() => void savePassword(cred)}
                  onClear={() => void clearPassword(cred)}
                  onDelete={() => void deleteCredential(cred)}
                />
              ))}
            </div>
          )}
        </section>
      </div>
    </Modal>
  );
}

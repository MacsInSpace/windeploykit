import type { InfraSshCredentialSummary } from "../lib/types";

interface CredentialSelectProps {
  credentials: InfraSshCredentialSummary[];
  value: string | undefined;
  onChange: (credentialId: string | undefined) => void;
  disabled?: boolean;
  className?: string;
}

export function CredentialSelect({
  credentials,
  value,
  onChange,
  disabled,
  className = "input-box text-[11px]",
}: CredentialSelectProps) {
  return (
    <select
      className={className}
      disabled={disabled}
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value.trim() || undefined)}
    >
      <option value="">None (unassigned)</option>
      {credentials.map((c) => (
        <option key={c.id} value={c.id}>
          {c.label}
          {c.loginName && c.loginName !== c.label ? ` | ${c.loginName}` : ""}
          {!c.configured ? " (password not set)" : ""}
        </option>
      ))}
    </select>
  );
}

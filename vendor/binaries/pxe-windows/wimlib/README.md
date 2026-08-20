# Vendored wimlib-imagex (Netboot boot asset extraction)

Official portable [wimlib](https://wimlib.net/) Windows binaries — extracts BCD/boot.sdi/bootmgr from boot WIMs on import.

| Path | Description |
|------|-------------|
| `x86_64/wimlib-imagex.exe` | 64-bit Windows (Intel/AMD) + `libwim-15.dll` |
| `aarch64/wimlib-imagex.exe` | ARM64 Windows + `libwim-15.dll` |

Staged to `Resources/binaries/wimlib/` during packaging.

## Refresh

```powershell
pwsh -File ./scripts/fetch-wimlib.ps1
git add vendor/binaries/pxe-windows/wimlib/ vendor/binaries/pxe-wimlib/SHA256SUMS.txt
```

We use **wimlib-imagex** cross-platform, not legacy **imagex.exe** (ADK/WAIK-only).

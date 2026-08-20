# Secure Boot PXE TFTP tree (`x86_64-sb/`)

Signed shim + iPXE chain for UEFI Secure Boot (DHCP Option 67 = `x86_64-sb/shimx64.efi`).

| Path | Shipped in |
|------|------------|
| `x86_64-sb/` | `resources/sidecar/pxe/x86_64-sb/` → user store `tftp/x86_64-sb/` on Netboot enable / Start Imaging Services |

## Refresh (build machine with ipxeboot checkout)

```bash
cd /path/to/ipxeboot/contrib/deploy-menu
./build-snponly.sh
```

```powershell
pwsh -File ./scripts/fetch-pxe-secure-boot.ps1 -SourceDir D:\ipxeboot\contrib\deploy-menu\out\tftp\x86_64-sb
git add vendor/binaries/pxe-secure-boot-x64/ sidecar/pxe/x86_64-sb/
```

Release packaging (`prepare-bundle-deps.ps1`) also copies from sibling `ipxeboot/.../out/tftp/x86_64-sb` when present.

Do **not** use `x86_64-sb/ipxe.efi` as Option 67 — firmware rejects it. Use `x86_64-sb/shimx64.efi` only.

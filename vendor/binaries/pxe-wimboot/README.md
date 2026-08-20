# iPXE wimboot (Netboot local HTTP boot)

| File | Role |
|------|------|
| `wimboot` | PE/UEFI loader served at `http://<laptop>:8080/wimboot/wimboot` |
| `SHA256SUMS.txt` | Pin for `scripts/fetch-wimboot.ps1` |

Upstream: [ipxe/wimboot](https://github.com/ipxe/wimboot) (GPL-2.0). Pinned **v2.9.0** — BIOS + 64-bit UEFI.

## Refresh

```powershell
pwsh -File ./scripts/fetch-wimboot.ps1
git add vendor/binaries/pxe-wimboot/ sidecar/pxe/wimboot
```

`prepare-bundle-deps.ps1` copies `vendor/binaries/pxe-wimboot/wimboot` → staged `sidecar/pxe/wimboot`. On **Start field PXE**, the sidecar syncs it into the user store `http/wimboot/wimboot`.

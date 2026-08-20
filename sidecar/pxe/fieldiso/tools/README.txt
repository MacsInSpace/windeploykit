FieldIso WinPE tools — baked into FieldIso.wim at build time (System32).

Maintainer fetch (any OS with pwsh):

  pwsh -File ./scripts/fetch-fieldiso-tools.ps1

Build pipeline copies curl.exe + 7z.exe into the WIM. Runtime imaging logic is
sidecar/pxe/fieldiso/run.ps1 (HTTP bootstrap — curl install.wim + DISM, not httpdisk).

See sidecar/pxe/fieldiso/README.md and docs/plugins/netboot/AGENT_NOTES_PXE_BOOT.md.

PowerShell: export wim-inject on Windows + ADK (see wim-inject/README.txt), then:

  ./scripts/build-fieldiso-wim.sh

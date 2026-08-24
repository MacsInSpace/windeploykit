WinPE tools for the deploy client - injected beside startnet.cmd at boot
(never written into a WIM) and published to the Deploy$ share as Z:\Tools.

Refresh with:
  pwsh -File ./scripts/fetch-winpe-tools.ps1

7z.exe/7za.dll/7zxa.dll expand vendor driver packs; curl.exe pushes live
imaging logs. Licences in sidecar/pxe/deploy-client/THIRD-PARTY.txt.

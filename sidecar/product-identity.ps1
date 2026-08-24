# product-identity.ps1 - WinDeployKit's product identity (host side).
#
# The ONLY sidecar file allowed to carry product literals - see USM's
# docs/handover/PRODUCT_IDENTITY_CONTRACT.md (section 5: helper surface, fallback rule).
# windeploykit-sidecar.ps1 dot-sources it before any lib; standalone scripts and child
# runspaces / processes that re-dot-source libs reach it through Get-AppProductIdentity's
# fallback (sidecar/lib/AppProductIdentity.ps1). Libs read the fields through the helpers;
# never index this object directly from a lib.

$script:AppProductIdentity = [ordered]@{
    DisplayName      = 'WinDeployKit'        # storage dirs on Windows + macOS, prompts, firewall rule names
    Slug             = 'windeploykit'        # XDG dirs, temp-file prefixes, vault metadata
    BinaryName       = 'windeploykit'        # Contents/MacOS/windeploykit, windeploykit.exe; Cargo package name
    UserAgentToken   = 'WinDeployKit/1.0'    # token only; Get-AppUserAgent composes the header
    # DialogHelperName is left at its default, '<BinaryName>-dialog' = windeploykit-dialog
    # (scripts/build-windeploykit-dialog.sh, vendor/binaries/dialog-macos/).
    # Published-asset feed (p7zip / Caddy / tftpd64 / aria2 manifests). Still the
    # placeholder host from the port: every caller falls back to the bundled manifest when
    # the fetch fails, so behaviour is unchanged until a real feed exists. Omit the field to
    # skip the fetch entirely.
    # No runtime asset feed (Craig, 2026-08-22: "WDK should not download anything from
    # gitlab"). This was a GitLab package URL on a placeholder host, so every fetch failed
    # anyway - after burning a DNS timeout first. Get-AppProductAssetFeedUrl returns $null
    # for an empty base and every caller already treats that as "use the bundled copy",
    # so this single line removes the download attempts rather than papering over them.
    AssetFeedBaseUrl = ''
}

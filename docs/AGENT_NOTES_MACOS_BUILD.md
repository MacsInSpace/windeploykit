# Agent notes - building and releasing the macOS app

Carried over from PSOpenAD-FE, 2026-08-22, where all of this was worked out
against a real release. WinDeployKit is the same shape - Tauri 2 desktop app
with a PowerShell sidecar - so it applies with only the names changed.

Nothing here is theory. Every claim was tested on Craig's machine, and the
places where the obvious thing is wrong are called out.

## The build command

```bash
cd app && env -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID \
  APPLE_SIGNING_IDENTITY="Developer ID Application: Craig Hair (C6VNMT964L)" \
  npm run tauri:build:universal
```

Add the script if it is missing - `tauri build` alone produces an **arm64-only**
DMG, which is not what ships:

```json
"tauri:build:universal": "tauri build --target universal-apple-darwin"
```

Both rustup targets are needed: `aarch64-apple-darwin` and
`x86_64-apple-darwin`. Verify the result rather than trusting it:

```bash
lipo -archs <app>/Contents/MacOS/<binary>     # expect: x86_64 arm64
```

- The signing identity is passed **by environment variable, deliberately not in
  `tauri.conf.json`**. It names a person and a team; keep it out of a file that
  might one day be public.
- `env -u` on the three `APPLE_*` variables is what makes this build *skip*
  notarisation. Leave them set and Tauri notarises - see below.

## Notarisation

It works, and it needs nothing set up beyond what is already in `.env.local`
(`APPLE_ID`, `APPLE_PASSWORD` as an app-specific password, `APPLE_TEAM_ID`).

Specifically, **no App Store Connect app record and no App ID are required.**
This is worth stating because it looks like they should be. The reverse-domain
string in the flow is the **bundle identifier** from `tauri.conf.json`
(`com.macsinspace.windeploykit`), which appears in the ticket as `signingId` -
it is not something you register anywhere.

To notarise, run the same build with the variables left in place:

```bash
cd app
set -a; . ../.env.local; set +a
APPLE_SIGNING_IDENTITY="Developer ID Application: Craig Hair (C6VNMT964L)" \
  npm run tauri:build:universal
```

Check the credentials first if anything looks off - this submits nothing:

```bash
xcrun notarytool history --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID"
```

### Stapling fails, and that is expected here

`xcrun stapler staple` fails with **Error 65, "Could not validate ticket"**,
even though Apple accepted the submission and the verbose log shows the ticket
being found and downloaded. Do not treat this as a broken build. Ruled out on
2026-08-22:

- **cdhash mismatch** - no. The on-disk hashes matched Apple's ticket exactly,
  both slices. Compare with
  `codesign -dvvv --arch arm64 <app>` against `xcrun notarytool log <id> ...`.
- **Propagation delay** - no. Five retries over 2.5 minutes.
- **Filesystem** - no. Fails on the APFS system volume as well as `/Volumes/Data`.
- **Notarising the DMG instead of the app** - no. Accepted, same staple failure.

USM documents the same behaviour across every build it has ever shipped
(`docs/core/git/AGENT_NOTES_MACOS_RELEASE.md`, "Stapling: shipped apps have
never been stapled (finding, not a bug)"). Gatekeeper fetches the ticket
**online at first launch** instead, which works in the field.

**Consequence for the release notes:** the app opens normally on a machine that
can reach Apple once. A first launch with no route to Apple is still refused,
and only then is the quarantine command needed:

```bash
xattr -dr com.apple.quarantine /Applications/WinDeployKit.app
```

`-d` alone is wrong - it clears only the top-level bundle and the app still
refuses to start. Tested: 2 of 3 quarantined paths survived `-d`, 0 survived
`-dr`. Avoid `-c`/`-cr`, which strip every extended attribute rather than the
one. Code signing survives either.

### If uploads fail

USM has hit `deadlineExceeded` on the upload to Apple. Their finding: it was
the local uplink, not the tooling. If it recurs, `notarytool submit` accepts
`--no-s3-acceleration`, and notarytool does not retry uploads on its own - the
loop has to.

## Bundling the sidecar - two things that only fail in a packaged build

Both of these worked in `tauri dev` and failed the moment it was a real `.app`.

**1. Declare the payload as resources.** Without this the bundle contains the
Rust host and nothing for it to talk to:

```json
"bundle": { "resources": { "../../sidecar": "sidecar", "../../vendor": "vendor" } }
```

(WinDeployKit's actual map is longer and explicit - see "WinDeployKit specifics"
below; the principle is the same.) Keeping the repo's own layout means the
sidecar's relative lookups keep working unchanged. On the Rust side, check `resource_dir()` **first**: a Finder-launched
app has a working directory of `/`, so every relative candidate is meaningless
there.

**2. Find `pwsh` without PATH.** An app launched from Finder inherits a minimal
PATH that does not include `/usr/local/bin`, so `which pwsh` fails in exactly
the case that matters. Check the installer locations directly:

```
/usr/local/bin/pwsh, /opt/homebrew/bin/pwsh,
/usr/local/microsoft/powershell/7/pwsh, /usr/bin/pwsh, /snap/bin/pwsh
```

Then tell the user when it is missing. PowerShell 7 is the one dependency a
bundle cannot carry, and meeting its absence as a spawn error on first use is
the worst way to learn it.

## Prove the bundle, do not assume it

The `.app` is the only thing worth testing, and it must be tested the way a
double-click runs it - not from a shell that already has your PATH:

```bash
RES=<app>/Contents/Resources
printf '%s\n' '{"id":"1","method":"ping","params":{}}' '{"id":"9","method":"quit"}' \
  | ( cd "$RES" && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      /usr/local/bin/pwsh -NoProfile -NoLogo -File "$RES/sidecar/<Sidecar>.ps1" )
```

`env -i` and the cut-down PATH are the point. A sidecar that is lazily started
will not be running just because the app is open - that is expected, not a
failure.

Use launchd's real default, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, not a stricter
one: with `/usr/bin:/bin` alone the vault reports "could not read IOPlatformUUID
from ioreg" (`ioreg` is in `/usr/sbin`; SecretManagement.LocalVault 1.0.2 calls it
by bare name - a robustness item for the module repo, not a bundle fault). A
Finder-launched app inherits launchd's PATH, so the packaged app is fine - proven
2026-08-26 with the 0.6.0 bundle: `GetSecretVaultStatus` ready, `dnsmasqPath` inside
`Contents/Resources`, Caddy manifest loaded (`needsInstall`), default background
found.

## Release checklist

Verified in this order, because each answers a different way of being wrong:

| Check | Command |
| --- | --- |
| Both architectures | `lipo -archs <app>/Contents/MacOS/<binary>` |
| Version really bumped | `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' <app>/Contents/Info.plist` |
| Signature | `codesign --verify --deep --strict <app>` |
| Payload present | check `Contents/Resources/sidecar` and `vendor` |
| Built from the tag | clean tree, and `HEAD` is what the tag points at |
| Published asset is the built one | download it back and compare SHA-256 |

Bump the version in **four** places or the bundle disagrees with the tag:
`app/package.json`, `app/src-tauri/tauri.conf.json`, `app/src-tauri/Cargo.toml`,
and the `windeploykit` entry in `app/src-tauri/Cargo.lock` (cargo rewrites it
during the build otherwise, and the tree is dirty at tag time).

Publishing, once the tag is on the commit the DMG was built from:

```bash
gh release create vX.Y.Z <dmg> --title "WinDeployKit X.Y.Z" --notes-file <body>
```

Relative image links do not resolve on a release page - rewrite them to
`raw.githubusercontent.com/<owner>/<repo>/vX.Y.Z/...` in the release body.

## Two traps worth carrying over

**Cargo locks the shared `target/` directory.** A release build and a running
`tauri dev` block each other. If a dev rebuild seems to hang, look for a release
build first.

**A value assigned inside a React state updater is not available to the line
after `setState`.** React runs updaters during render. This shipped twice in
PSOpenAD-FE as a tree that expanded but never loaded its children, because a
`needsLoad` flag was assigned inside the updater and read immediately after.
Decide from a ref holding current state instead.

## WinDeployKit specifics (2026-08-26, first release build)

Found by the bundle audit before 0.6.0: the app shipped `sidecar/` and **nothing
else**. `scripts/prepare-bundle-deps.ps1` and `scripts/package-macos.sh` are ports
from another product that cannot run here (both now carry an INERT header) and
`beforeBuildCommand` never called them anyway. So at first launch the vault threw
(no `Microsoft.PowerShell.SecretManagement`), HTTP could never start (no
`packaging/pxe-caddy.json`), and TFTP, wimlib, the password dialog and the SCCM
driver catalogs were absent. What ships is decided **only** by `bundle.resources`
in `app/src-tauri/tauri.conf.json`:

| Entry | Why |
| --- | --- |
| `../../sidecar/` | the sidecar, its libs, `pxe/` (arch trees, snponly, wimboot, tools, deploy client, default background) |
| `../../vendor/psmodules/` | SecretManagement 1.1.2 + LocalVault 1.0.2 - the vault. Run `pwsh scripts/sync-secret-vault-modules.ps1 -VerifyOnly` before a build; the inert staging script used to |
| `vendor/binaries/pxe-macos/{dnsmasq,wimlib-imagex}-universal` + COPYING/VERSION | TFTP/proxyDHCP and WIM handling; universal (lipo-checked) |
| `vendor/binaries/dialog-macos/windeploykit-dialog-universal` | the native admin-password dialog (osascript fallback otherwise) |
| (not `vendor/aria2-tools/*.tar.gz`) | The first 0.6.0 notarisation was rejected for the **unsigned `aria2c` inside the tar.gz** - Apple unpacks archives. Signing it would not help either: that `aria2c` is a Homebrew bottle linked against `/opt/homebrew/opt/{openssl@3,libssh2,c-ares,sqlite,gettext}` dylibs, so it only runs where Homebrew's aria2 is already installed. **Resolved 2026-08-29:** the tar.gz is gone. `scripts/build-aria2-macos.sh` builds `aria2c` from the upstream source tarball against Apple TLS and the SDK's libxml2/zlib/sqlite3 only (the script fails if `otool -L` shows anything outside `/usr/lib` or `/System`), vendored as `vendor/binaries/pxe-macos/aria2c-universal` and staged into `Resources/binaries/` like dnsmasq - so it is a plain Mach-O the signing loop covers, not an archive. `Get-AppAria2BinaryPath` = `APP_ARIA2` -> bundled -> runtime install (Windows) -> plain `Get-Command`. No Homebrew probe anywhere (Craig, 2026-08-28/29) |
| `packaging/*.json` (explicit list) | Caddy / aria2 / p7zip manifests and the five SCCM driver catalogs |

Deliberately not in the macOS bundle: `vendor/binaries/pxe-windows/`, the Windows
aria2 zips and `packaging/pxe-tftpd64.json` (a Windows build wants a
`tauri.windows.conf.json` for those), `packaging/torrents/` and
`packaging/aria2-tracker.json` (gitignored, local), `vendor/binaries/pxe-mdt-boot/`.

**Caveat that needs a decision:** `sidecar/pxe/mdt-boot-x64/` is gitignored
(Microsoft boot files: BCD, boot.sdi, bootmgfw.efi) but present on Craig's Mac, so
the `../../sidecar/` entry carries it into any build made here. That matches what
the old staging script intended (LiteTouch WIMs need it), but redistribution is a
policy call, not a build detail.

**Signing the vendored Mach-O binaries.** Notarisation refuses unsigned executables
anywhere in the bundle, and Tauri signs only its own binary and frameworks. The
three universal binaries are therefore Developer ID signed **in place** and
committed (`codesign --force --sign "$ID" --options runtime --timestamp <file>`);
no runtime hash check depends on the old bytes. Re-do this when a binary is
re-vendored. Windows PE files (`sidecar/pxe/tools/*.exe`, the EFI trees) are not
Mach-O and notarisation ignores them. **Archives are not opaque to it** - it
unpacked the aria2 tar.gz and rejected the `aria2c` inside (first 0.6.0 attempt).

`bundle.targets` is `["app", "dmg"]` - the DMG is what a release publishes.

**0.6.0 release record (2026-08-26).** Three builds: the first was rejected by
notarisation for the `aria2c` inside a tar.gz (see the table), the second accepted
with the archive removed, the third from tag `v0.6.0` (`282034a`) accepted again -
app ticket `25836e2c-22df-409b-875b-5d4f238d54d3`. The DMG was then notarised on its
own with `xcrun notarytool submit --wait` (`aa38cef6-5669-40fb-b347-8685e672ca52`,
Accepted); stapling failed with Error 65 exactly as above and the DMG bytes did not
change. `spctl -a -t open` on the DMG still says "Unnotarized Developer ID" locally -
that is the missing staple, not a missing ticket. Timings on Craig's Mac with a warm
cargo cache: Rust 25 s per architecture, bundle + sign + notarise about 3 minutes.
Published asset downloaded back: SHA-256 identical to the build.


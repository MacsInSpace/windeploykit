#!/usr/bin/env bash
# Build a macOS distributable. Bundles sidecar + PSOpenAD; pwsh 7 is a separate install unless --bundle-pwsh.
#
# Produces:
#   dist/macos/WinDeployKit_<version>_<arch>/
#     WinDeployKit.app
#     README-INSTALL.txt
#     VERSION.txt
#   dist/macos/WinDeployKit_<version>_<arch>.zip
#   dist/macos/WinDeployKit_<version>_<arch>.pkg  (optional installer)
#
# Prerequisites ON THE BUILD MACHINE ONLY:
#   - Xcode CLT + Developer ID cert in Keychain (codesign + notarization)
#   - Node 18+, Rust (./scripts/bootstrap-frontend.sh)
#   - Network to http://timestamp.apple.com (Apple TSA - required for signing)
#   - Network when using --bundle-pwsh (downloads portable PowerShell)
#
# Usage:
#   ./scripts/package-macos.sh                 # always: aarch64 + x86_64 + universal zips (signed)
#   ./scripts/package-macos.sh --no-backup
#   ./scripts/package-macos.sh --pkg           # also emit .pkg installer (universal)
#   ./scripts/package-macos.sh --bundle-pwsh   # optional: embed portable PowerShell (~250 MB)
#   ./scripts/package-macos.sh --no-sync       # skip test/push/release prompts at end
#
# Signing needs http://timestamp.apple.com (Apple TSA). If unreachable on DE WAN, build on
# hotspot/home internet, or ask IT to allow outbound HTTP to timestamp.apple.com.

set -euo pipefail

if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$(dirname "$0")/load-local-env.sh"
load_local_env "${repo_root}" || true
report_local_env APPLE_ID APPLE_TEAM_ID APPLE_PASSWORD GITLAB_TOKEN || true

app_dir="${repo_root}/app"
tauri_conf="${app_dir}/src-tauri/tauri.conf.json"
dist_root="${repo_root}/dist/macos"
do_backup=true
do_pkg=false
bundle_pwsh=false
do_clean=true
do_sync=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-backup)
      do_backup=false
      shift
      ;;
    --no-clean)
      do_clean=false
      shift
      ;;
    --no-sync)
      do_sync=false
      shift
      ;;
    --no-sign)
      echo "The --no-sign option was removed. macOS release builds are always signed." >&2
      echo "Build on a network that can reach http://timestamp.apple.com (hotspot/home if DE WAN blocks it)." >&2
      exit 1
      ;;
    --pkg)
      do_pkg=true
      shift
      ;;
    --bundle-pwsh)
      bundle_pwsh=true
      shift
      ;;
    --arch|--arch=*)
      echo "The --arch option was removed. This script always builds aarch64, x86_64, and universal zips." >&2
      exit 1
      ;;
    --help|-h)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '==> %s\n' "$*" >&2; }

macos_signing_identity() {
  node -p "require('${tauri_conf}').bundle.macOS.signingIdentity" 2>/dev/null || true
}

# Vendored Mach-O helpers (dnsmasq, wimlib, Intune packager) must be signed with hardened
# runtime + timestamp before Tauri bundles them - otherwise notarization rejects the .app.
sign_macos_staged_binaries() {
  local staged="${repo_root}/packaging/staged/binaries"
  local identity bin ft
  identity="$(macos_signing_identity)"
  if [[ -z "${identity}" ]]; then
    log "WARN: no macOS signingIdentity - skipping staged binary codesign"
    return 0
  fi
  if [[ ! -d "${staged}" ]]; then
    return 0
  fi
  shopt -s nullglob
  for bin in "${staged}"/*; do
    [[ -f "${bin}" ]] || continue
    ft="$(file -b "${bin}" 2>/dev/null || true)"
    [[ "${ft}" == *Mach-O* ]] || continue
    log "Signing staged binary: $(basename "${bin}")"
    codesign --force --options runtime --timestamp --sign "${identity}" "${bin}"
  done
  shopt -u nullglob

  # Vendored PSWSMan dylibs (macOS Remote PowerShell patch payload) ship inside
  # sidecar/vendor/pswsman/. Notarization rejects them unsigned. Signing happens on
  # the STAGED copies only - the repo copies stay byte-identical to upstream PSWSMan
  # (SHA256SUMS.txt). The in-app patched check compares staged copy vs $PSHOME, so
  # signed hashes stay consistent end-to-end.
  local pswsman="${repo_root}/packaging/staged/sidecar/vendor/pswsman"
  if [[ -d "${pswsman}" ]]; then
    while IFS= read -r -d '' bin; do
      ft="$(file -b "${bin}" 2>/dev/null || true)"
      [[ "${ft}" == *Mach-O* ]] || continue
      log "Signing staged PSWSMan dylib: ${bin#"${pswsman}"/}"
      codesign --force --options runtime --timestamp --sign "${identity}" "${bin}"
    done < <(find "${pswsman}" -type f -name '*.dylib' -print0)
  fi
}

version="$(node -p "require('${app_dir}/package.json').version" 2>/dev/null || echo 0.1.0)"
git_sha="$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || echo nogit)"
build_stamp="$(date +%Y%m%d-%H%M)"
build_stamp_date="$(date +%Y%m%d)"
built_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

build_targets=(aarch64-apple-darwin x86_64-apple-darwin)

rustup_bin() {
  if command -v rustup >/dev/null 2>&1; then
    command -v rustup
    return 0
  fi
  if [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
    printf '%s\n' "${HOME}/.cargo/bin/rustup"
    return 0
  fi
  return 1
}

ensure_rust_targets() {
  local rustup_cmd t
  if ! rustup_cmd="$(rustup_bin)"; then
    cat >&2 <<'EOF'
rustup not found. Cross-arch / universal macOS builds need rustup to install Rust targets.

  ./scripts/bootstrap-frontend.sh

If you installed Rust via Homebrew only, either run bootstrap (installs rustup) or:
  brew uninstall rust
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
EOF
    return 1
  fi
  for t in "$@"; do
    if ! "${rustup_cmd}" target list --installed 2>/dev/null | grep -qx "${t}"; then
      log "rustup target add ${t}"
      "${rustup_cmd}" target add "${t}"
    fi
  done
}

find_tauri_app_bundle() {
  local target="$1"
  local bundle_glob="${app_dir}/src-tauri/target/${target}/release/bundle"
  local app_bundle
  app_bundle="$(find "${bundle_glob}/macos" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
  if [[ -z "${app_bundle}" || ! -d "${app_bundle}" ]]; then
    app_bundle="$(find "${bundle_glob}" -maxdepth 2 -name '*.app' -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "${app_bundle}" || ! -d "${app_bundle}" ]]; then
    echo "Could not find .app under ${bundle_glob}" >&2
    return 1
  fi
  printf '%s\n' "${app_bundle}"
}

write_install_readme() {
  local out_dir="$1"
  local artifact_arch="$2"
  cat > "${out_dir}/README-INSTALL.txt" <<EOF
WinDeployKit ${version} - macOS install
============================================

Built: $(date -u '+%Y-%m-%d %H:%M UTC')
Architecture: ${artifact_arch} (app binary: host arch, aarch64, x86_64, or universal)

REQUIREMENTS (install once per Mac)
---------------------------------
  - PowerShell 7 or later (pwsh on PATH)
      macOS:  brew install --cask powershell
      Or:     https://github.com/PowerShell/PowerShell/releases

WHAT IS BUNDLED IN THE .APP
---------------------------
  - WinDeployKit (Tauri UI)
  - PSOpenAD + WinDeployKitPS PowerShell modules
  - SchoolManager sidecar scripts

MINI PLAYER (optional)
----------------------
  yt-dlp + deno are downloaded on first Lo-Fi play to per-user app data
  (cache/tools under the canonical app data root). GitHub HTTPS required once per Mac.

INSTALL
-------
1. Install PowerShell 7+ if not already present (see above).
2. Copy "WinDeployKit.app" to /Applications (or run from this folder).
3. First launch: if Gatekeeper blocks the app, open System Settings ->
   Privacy & Security -> Allow, or right-click the app -> Open once.
4. Sign in with your EDU001 credentials when prompted.

NETWORK
-------
You must reach school STADC/EDUDC (on-site or VPN). Off-WAN testing uses NPS_*
env vars - see app/README.md (developers only).

UPDATES
-------
Replace the .app with a newer build from your team lead. No in-app updater yet.

SUPPORT FILES
-------------
Logs: use the in-app Logs panel.
Credentials: ~/.local/share/WinDeployKitCreds/StoredCredentials.xml (shared with other DE tools).
EOF
}

write_version_file() {
  local out_dir="$1"
  local artifact_arch="$2"
  cat > "${out_dir}/VERSION.txt" <<EOF
version=${version}
build_targets=${build_targets[*]}
artifact_arch=${artifact_arch}
built_utc=${built_utc}
git_sha=${git_sha}
build_stamp=${build_stamp}
EOF
  if [[ "${artifact_arch}" == "universal" ]]; then
    lipo -info "${out_dir}/WinDeployKit.app/Contents/MacOS/windeploykit" >> "${out_dir}/VERSION.txt" 2>&1 || true
  fi
}

assemble_mac_zip() {
  local artifact_arch="$1"
  local app_bundle="$2"
  local out_name="WinDeployKit_${version}_${artifact_arch}"
  local out_dir="${dist_root}/${out_name}"
  local zip_path="${dist_root}/${out_name}.zip"

  log "Assembling ${out_dir}"
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"
  cp -R "${app_bundle}" "${out_dir}/"
  write_install_readme "${out_dir}" "${artifact_arch}"
  write_version_file "${out_dir}" "${artifact_arch}"

  mkdir -p "${dist_root}"
  rm -f "${zip_path}"
  (
    cd "${dist_root}"
    ditto -c -k --sequesterRsrc --keepParent "${out_name}" "${out_name}.zip"
  )
  log "Zip: ${zip_path}"
  printf '%s\n' "${zip_path}"
}

maybe_build_pkg() {
  local artifact_arch="$1"
  local out_name="WinDeployKit_${version}_${artifact_arch}"
  local out_dir="${dist_root}/${out_name}"
  local pkg_path="${dist_root}/${out_name}.pkg"
  local pkg_root pkg_app

  [[ "${do_pkg}" == "true" ]] || return 0
  [[ "${artifact_arch}" == "universal" ]] || return 0
  [[ -d "${out_dir}/WinDeployKit.app" ]] || return 0

  pkg_root="$(mktemp -d)"
  pkg_app="${pkg_root}/Applications/WinDeployKit.app"
  mkdir -p "${pkg_root}/Applications"
  cp -R "${out_dir}/WinDeployKit.app" "${pkg_app}"
  pkgbuild \
    --identifier "com.macsinspace.windeploykit" \
    --version "${version}" \
    --install-location "/" \
    --component "${pkg_app}" \
    "${pkg_path}"
  rm -rf "${pkg_root}"
  log "PKG: ${pkg_path}"
  printf '%s\n' "${pkg_path}"
}

if [[ "${do_backup}" == "true" ]]; then
  log "Workspace backup"
  "${repo_root}/scripts/backup-now.sh" --quiet
fi

restore_tauri_conf() {
  if [[ -f "${tauri_conf}.package-bak" ]]; then
    mv "${tauri_conf}.package-bak" "${tauri_conf}"
  fi
}
trap restore_tauri_conf EXIT

ensure_tauri_conf_backup() {
  if [[ ! -f "${tauri_conf}.package-bak" ]]; then
    cp "${tauri_conf}" "${tauri_conf}.package-bak"
  fi
}

patch_tauri_conf_for_build() {
  ensure_tauri_conf_backup
  [[ "${bundle_pwsh}" == "true" ]] || return 0
  python3 -c "
import json
p = '${tauri_conf}'
with open(p) as f:
    c = json.load(f)
bundle = c.setdefault('bundle', {})
bundle.setdefault('resources', {})['../../packaging/staged/powershell/'] = 'powershell/'
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
"
}

apple_timestamp_reachable() {
  curl -sS -o /dev/null --connect-timeout 8 http://timestamp.apple.com/ts01 >/dev/null 2>&1
}

if ! apple_timestamp_reachable; then
  cat >&2 <<'EOF'
Apple timestamp server (http://timestamp.apple.com) is unreachable from this network.

Developer ID signing needs that server. Without a timestamp, codesign fails with:
  "A timestamp was expected but was not found."

Build on a network that can reach Apple (mobile hotspot, home internet), then run
  ./scripts/package-macos.sh
again for a signed + notarizable .app.

Ask IT to allow outbound HTTP to timestamp.apple.com if you need signed builds on the DE WAN.
EOF
  exit 1
fi

if [[ "${bundle_pwsh}" == "true" ]]; then
  log "Staging dependencies (including portable PowerShell)"
  "${repo_root}/scripts/prepare-macos-bundle-deps.sh" --arch universal --bundle-pwsh
else
  log "Staging bundled dependencies (sidecar + modules; pwsh 7 required on target Mac)"
  "${repo_root}/scripts/prepare-macos-bundle-deps.sh" --arch universal
fi

if [[ "${bundle_pwsh}" == "true" ]]; then
  patch_tauri_conf_for_build
  echo "tauri.conf.json: added powershell resource"
fi

log "Installing npm deps (if needed)"
if [[ ! -d "${app_dir}/node_modules" ]]; then
  (cd "${app_dir}" && npm install)
fi

ensure_rust_targets "${build_targets[@]}"

tauri_target="${app_dir}/src-tauri/target"
if [[ "${do_clean}" == "true" && -d "${tauri_target}" ]]; then
  if ! "${repo_root}/scripts/clean-tauri-target.sh" --check 2>/dev/null; then
    log "Stale Cargo/Tauri target (paths from another folder) - cleaning"
  else
    log "Cleaning Cargo/Tauri target before release build"
  fi
  "${repo_root}/scripts/clean-tauri-target.sh"
fi

export CARGO_TARGET_DIR="${tauri_target}"
export VITE_BUILD_NUMBER="${git_sha}-${build_stamp}"
export VITE_BUILD_STAMP="${build_stamp_date}"
export VITE_APP_VERSION="$(cd "${app_dir}" && node -p "require('./package.json').version")"
log "Frontend build id: ${VITE_APP_VERSION} | ${VITE_BUILD_NUMBER}"

built_apps=()
stage_intune_mac_packager() {
  local rid="$1"
  local suffix="$2"
  local vendor="${repo_root}/vendor/binaries/intune-macos/${name}"
  local staged="${repo_root}/packaging/staged/binaries"
  mkdir -p "${staged}"
  if [[ -f "${vendor}" ]]; then
    cp -f "${vendor}" "${staged}/${name}"
    chmod +x "${staged}/${name}"
    log "Staged vendored ${name}"
  elif command -v dotnet >/dev/null 2>&1; then
    log "Building ${name} (no vendored copy)"
  else
    log "WARN: missing ${vendor} and dotnet not on PATH - Intune packaging unavailable in bundle"
  fi
}

# Tauri's beforeBuildCommand re-runs prepare-bundle-deps.ps1 (tauri.conf.json), which
# deletes + re-stages packaging/staged and would clobber the signatures below right
# before bundling. Exporting the identity makes prepare-bundle-deps re-sign after any
# re-stage, so the bundled copies are always Developer ID-signed (0.5.2 notarization
# rejection: every staged Mach-O helper + PSWSMan dylib arrived adhoc-signed).
DEPLOYKIT_MACOS_SIGN_IDENTITY="$(macos_signing_identity)"
export DEPLOYKIT_MACOS_SIGN_IDENTITY
if [[ -z "${DEPLOYKIT_MACOS_SIGN_IDENTITY}" ]]; then
  log "WARN: no macOS signingIdentity in tauri.conf.json - staged binaries stay adhoc (notarization will fail)"
fi

for build_target in "${build_targets[@]}"; do
  case "${build_target}" in
    aarch64-apple-darwin)
      export VITE_APP_VARIANT=aarch64
      stage_intune_mac_packager osx-arm64 aarch64-apple-darwin
      ;;
    x86_64-apple-darwin)
      export VITE_APP_VARIANT=x86_64
      stage_intune_mac_packager osx-x64 x86_64-apple-darwin
      ;;
    *)
      export VITE_APP_VARIANT="${build_target}"
      ;;
  esac
  sign_macos_staged_binaries
  log "Tauri release build (target=${build_target}, variant=${VITE_APP_VARIANT})"
  (
    cd "${app_dir}"
    npm run tauri build -- --target "${build_target}"
  )
  app_bundle="$(find_tauri_app_bundle "${build_target}")"
  built_apps+=("${app_bundle}")
done

zip_paths=()
pkg_path=""
sync_extra_paths=()

if [[ "${#built_apps[@]}" -ne 2 ]]; then
  echo "Expected two .app bundles (aarch64 + x86_64), got ${#built_apps[@]}" >&2
  exit 1
fi

log "Packaging aarch64, x86_64, and universal zips"
zip_paths+=("$(assemble_mac_zip aarch64 "${built_apps[0]}")")
zip_paths+=("$(assemble_mac_zip x86_64 "${built_apps[1]}")")

universal_work="$(mktemp -d)"
cp -R "${built_apps[0]}" "${universal_work}/WinDeployKit.app"
arm_bin="${universal_work}/WinDeployKit.app/Contents/MacOS/windeploykit"
x64_bin="${built_apps[1]}/Contents/MacOS/windeploykit"
log "Creating universal windeploykit (lipo arm64 + x86_64)"
lipo -create "${arm_bin}" "${x64_bin}" -output "${arm_bin}.universal"
mv "${arm_bin}.universal" "${arm_bin}"
lipo -info "${arm_bin}"

zip_paths+=("$(assemble_mac_zip universal "${universal_work}/WinDeployKit.app")")
rm -rf "${universal_work}"

sync_extra_paths=("${zip_paths[0]}" "${zip_paths[1]}")
primary_zip="${zip_paths[2]}"

if [[ "${do_pkg}" == "true" ]]; then
  while IFS= read -r _pkg; do
    [[ -n "${_pkg}" ]] && pkg_path="${_pkg}"
  done < <(maybe_build_pkg universal)
fi

pkg_extra=()
if [[ -n "${pkg_path}" ]]; then
  pkg_extra=(-ExtraPaths "${pkg_path}")
fi

log "Done. Hand off:"
for z in "${zip_paths[@]}"; do
  log "  ${z}"
done
log "NPS / macOS TCC: launch the .app above - tauri:dev does not reproduce network-volume prompts"

if [[ "${do_sync}" == "true" ]]; then
  if command -v pwsh >/dev/null 2>&1; then
# Correct - build a single comma-separated array value
extra_zips_arg=()
if [[ "${#sync_extra_paths[@]}" -gt 0 ]]; then
  IFS=',' joined="${sync_extra_paths[*]}"
  extra_zips_arg=(-ExtraPaths "${joined}")
fi
  pwsh -NoProfile -File "${repo_root}/scripts/offer-post-build-sync.ps1" \
    -Platform Mac -Version "${version}" -ZipPath "${primary_zip}" \
    "${extra_zips_arg[@]}" "${pkg_extra[@]}"
  else
    log "pwsh not on PATH - skipping post-build git/release prompts (install PowerShell 7+)"
  fi
fi

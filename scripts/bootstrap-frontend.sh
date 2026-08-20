#!/usr/bin/env bash
# Bootstrap the Tauri frontend dev environment.
#
# Installs (idempotent):
#   - rustup + stable toolchain (if absent)
#   - npm dependencies inside /app
#
# Run this once after pulling the repo, then `cd app && npm run tauri:dev`.
#
# NOTE: ASCII-only on purpose. macOS ships bash 3.2, which treats the UTF-8
# bytes of fancy punctuation (e.g. U+2026 ellipsis) as continuation of a
# variable name when the var is unbraced under `set -u`, producing confusing
# `unbound variable` errors. So we use plain "..." and ${var} consistently.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${repo_root}/app"
pwsh_script="${repo_root}/sidecar/windeploykit-sidecar.ps1"

echo "==> Repository root: ${repo_root}"
echo "==> App directory:   ${app_dir}"

if [[ ! -f "${pwsh_script}" ]]; then
  echo "!! Could not find ${pwsh_script} -- the Tauri sidecar bridge expects it."
  echo "   Make sure you're running this from a full checkout."
  exit 1
fi

# 1. Rust toolchain (rustup required for packaging / cross-target builds)
if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck disable=SC1090
  source "${HOME}/.cargo/env"
fi

install_rustup() {
  if [[ "$(uname)" == "Darwin" ]] || [[ "$(uname)" == "Linux" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    source "${HOME}/.cargo/env"
  else
    echo "!! Automatic install only supported on macOS/Linux. On Windows install rustup-init.exe from https://rustup.rs and re-run."
    exit 1
  fi
}

if ! command -v rustup >/dev/null 2>&1; then
  if command -v cargo >/dev/null 2>&1; then
    echo "==> cargo found ($(command -v cargo)) but rustup is missing."
    echo "    Packaging and cross-arch builds need rustup (Homebrew rust alone is not enough)."
    echo "==> Installing rustup (https://rustup.rs) ..."
  else
    echo "==> Rust toolchain not found. Installing via rustup (https://rustup.rs)..."
  fi
  install_rustup
elif ! command -v cargo >/dev/null 2>&1; then
  echo "==> rustup found but cargo is not on PATH; sourcing ~/.cargo/env ..."
  install_rustup
else
  echo "==> rustup found: $(command -v rustup)"
  echo "==> cargo found:  $(command -v cargo)"
fi

rustup --version
cargo --version
rustc --version

# 2. PowerShell 7
if ! command -v pwsh >/dev/null 2>&1; then
  echo "!! PowerShell 7 (pwsh) is not on PATH. The Tauri app will fail to spawn the sidecar."
  echo "   macOS:   brew install --cask powershell"
  echo "   Windows: winget install --id Microsoft.PowerShell"
  echo "   (continuing -- Rust/Node bits will still install)"
fi

# 3. Node deps
if ! command -v npm >/dev/null 2>&1; then
  echo "!! npm not found. Install Node 18+ from https://nodejs.org first."
  exit 1
fi

echo "==> Installing npm dependencies in ${app_dir} ..."
if [[ -d "${app_dir}/node_modules" ]] && [[ ! -f "${app_dir}/node_modules/@tauri-apps/cli/tauri.js" ]]; then
  echo "!! node_modules looks broken (common after sharing the repo with Parallels/Windows)."
  echo "   Removing and reinstalling ..."
  rm -rf "${app_dir}/node_modules"
fi
(cd "${app_dir}" && npm install)

echo
echo "==> Bootstrap complete."
echo "    cd app && npm run tauri:dev"
echo
echo "    The Tauri Rust crate builds on first run -- expect a 2-3 minute cold compile."

#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) aria2c for macOS with NO third-party runtime
# dependencies - Apple TLS (Security.framework) and the SDK's libxml2 / zlib /
# sqlite3 only. Homebrew is treated as not installed on every Mac the app runs on
# (Craig, 2026-08-29), and aria2 publishes no macOS binary of its own, so this is
# the only way the packaged app gets one. Same shape as build-dnsmasq-macos.sh.
#
# Output: vendor/binaries/pxe-macos/aria2c-universal (+ COPYING.aria2, VERSION.aria2)
# Requires: Xcode (or CLT) - clang, make, lipo, xcrun. Nothing from Homebrew.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${ARIA2_VERSION:-1.37.0}"
url="https://github.com/aria2/aria2/releases/download/release-${version}/aria2-${version}.tar.xz"
vendor_dir="${repo_root}/vendor/binaries/pxe-macos"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
sdk="$(xcrun --show-sdk-path)"

log() { printf '==> %s\n' "$*"; }

log "Downloading aria2 ${version}"
curl -fsSL "$url" | tar xJ -C "$work"
src="${work}/aria2-${version}"

build_arch() {
  local arch="$1"
  local host="$2"
  local out="${work}/build-${arch}"
  log "Building aria2c for ${arch}"
  mkdir -p "$out"
  (
    cd "$out"
    "$src/configure" --host="$host" --prefix=/usr/local \
      --with-appletls --without-openssl --without-gnutls \
      --without-libssh2 --without-libcares --without-libgmp --without-libnettle \
      --without-libgcrypt --without-libexpat --without-libuv --without-jemalloc \
      --with-libxml2 --with-libz --with-sqlite3 \
      --disable-nls --disable-shared --enable-static \
      CC="clang -arch ${arch}" CXX="clang++ -arch ${arch}" \
      CFLAGS="-O2 -isysroot ${sdk}" CXXFLAGS="-O2 -isysroot ${sdk}" LDFLAGS="-isysroot ${sdk}" \
      LIBXML2_CFLAGS="-I${sdk}/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
      ZLIB_CFLAGS="-I${sdk}/usr/include" ZLIB_LIBS="-lz" \
      SQLITE3_CFLAGS="-I${sdk}/usr/include" SQLITE3_LIBS="-lsqlite3" \
      > "${out}/configure.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" > "${out}/make.log" 2>&1
  )
  cp "${out}/src/aria2c" "${work}/aria2c-${arch}"
}

build_arch arm64 aarch64-apple-darwin
build_arch x86_64 x86_64-apple-darwin

mkdir -p "$vendor_dir"
lipo -create "${work}/aria2c-arm64" "${work}/aria2c-x86_64" -output "${vendor_dir}/aria2c-universal"
strip -x "${vendor_dir}/aria2c-universal"
chmod +x "${vendor_dir}/aria2c-universal"

# Ad-hoc sign so a local dev build runs; package-macos.sh re-signs every staged
# binary with the Developer ID (notarisation refuses unsigned Mach-O in the bundle).
codesign --force --sign - "${vendor_dir}/aria2c-universal" >/dev/null 2>&1 || true

cp "${src}/COPYING" "${vendor_dir}/COPYING.aria2"
{
  echo "aria2 ${version} - built by scripts/build-aria2-macos.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source: ${url}"
  echo "TLS: Apple Security.framework (AppleTLS); libs: SDK libxml2, zlib, sqlite3; no Homebrew"
} > "${vendor_dir}/VERSION.aria2"

log "Built ${vendor_dir}/aria2c-universal"
file "${vendor_dir}/aria2c-universal"
# Prove the no-Homebrew claim: every linked library must be under /usr/lib or /System.
if otool -L "${vendor_dir}/aria2c-universal" | grep -E '^\s+/' | grep -vE '^\s+/(usr/lib|System)/'; then
  echo "ERROR: aria2c links against a non-system library (see above)" >&2
  exit 1
fi
"${vendor_dir}/aria2c-universal" --version | head -1

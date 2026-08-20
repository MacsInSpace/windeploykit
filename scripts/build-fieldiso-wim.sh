#!/bin/sh
# Build FieldIso.wim — HTTP bootstrap WinPE with PowerShell + curl + 7z in the WIM.
#
# Prerequisites:
#   brew install wimlib   (or vendor/binaries/pxe-macos/wimlib-imagex-universal)
#   winpe.wim               ADK stock WinPE amd64, in the pxe-boot store's http/wim/
#                           (or point BASE_WIM= at it anywhere)
#   sidecar/pxe/fieldiso/wim-inject/Windows/…  from prepare-fieldiso-wim-inject.ps1 (Windows + ADK)
#   sidecar/pxe/fieldiso/tools/curl.exe + 7z.exe  from fetch-fieldiso-tools.ps1
#
# Usage:
#   pwsh -File ./scripts/fetch-fieldiso-tools.ps1
#   # On Windows: pwsh -File ./scripts/prepare-fieldiso-wim-inject.ps1 -BaseWinPeWim …\winpe.wim
#   ./scripts/build-fieldiso-wim.sh
#   OUT=~/Desktop/FieldIso.wim ./scripts/build-fieldiso-wim.sh

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Canonical pxe-boot store (AppPaths.ps1), same as
# inject-fieldiso-drivers-from-imagedeployer.sh. Deliberately NOT apis/ — that is a
# scratch drop-off folder that gets deleted, so nothing here may depend on it.
if [ "$(uname)" = "Darwin" ]; then
  DEFAULT_PXE_STORE="$HOME/Library/Application Support/WinDeployKit/plugins/pxe-boot"
else
  DEFAULT_PXE_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/windeploykit/plugins/pxe-boot"
fi
WIMS_DIR="${WIMS_DIR:-$DEFAULT_PXE_STORE/http/wim}"
BASE_WIM="${BASE_WIM:-$WIMS_DIR/winpe.wim}"
OUT="${OUT:-$WIMS_DIR/FieldIso.wim}"

OVERLAY_ROOT="$REPO_ROOT/sidecar/pxe/fieldiso-overlay"
INJECT_ROOT="$REPO_ROOT/sidecar/pxe/fieldiso/wim-inject"
TOOLS_DIR="$REPO_ROOT/sidecar/pxe/fieldiso/tools"
WORK="${WORK:-/tmp/windeploykit-fieldiso-build}"

WIMLIB="${WIMLIB:-$REPO_ROOT/vendor/binaries/pxe-macos/wimlib-imagex-universal}"
if [ ! -x "$WIMLIB" ]; then
	for candidate in \
		"$REPO_ROOT/vendor/binaries/pxe-macos/wimlib-imagex-aarch64-apple-darwin" \
		"$REPO_ROOT/vendor/binaries/pxe-macos/wimlib-imagex-x86_64-apple-darwin" \
		/opt/homebrew/bin/wimlib-imagex \
		/usr/local/bin/wimlib-imagex; do
		if [ -x "$candidate" ]; then
			WIMLIB="$candidate"
			break
		fi
	done
fi

command -v "$WIMLIB" >/dev/null 2>&1 || {
	echo "wimlib-imagex not found. Run: pwsh -File ./scripts/fetch-wimlib.ps1" >&2
	exit 1
}

if [ ! -f "$BASE_WIM" ]; then
	echo "Missing: $BASE_WIM" >&2
	echo "Copy ADK amd64\\en-us\\winpe.wim to $WIMS_DIR/, or set BASE_WIM=/path/to/winpe.wim" >&2
	exit 1
fi

FIELDISO_TOOL_FILES="curl.exe 7z.exe 7za.dll 7zxa.dll"

missing_tools=0
for tool in $FIELDISO_TOOL_FILES; do
	if [ ! -f "$TOOLS_DIR/$tool" ]; then
		echo "Missing $TOOLS_DIR/$tool — run: pwsh -File ./scripts/fetch-fieldiso-tools.ps1" >&2
		missing_tools=1
	fi
done
if [ "$missing_tools" -ne 0 ]; then exit 1; fi

if [ ! -d "$INJECT_ROOT/Windows/System32/WindowsPowerShell" ]; then
	echo "Missing PowerShell tree: $INJECT_ROOT/Windows/System32/WindowsPowerShell" >&2
	echo "On Windows + ADK run:" >&2
	echo "  pwsh -File ./scripts/prepare-fieldiso-wim-inject.ps1 -BaseWinPeWim …\\winpe.wim" >&2
	exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/staging/Windows/System32"

echo "==> Staging overlay + tools"
cp "$OVERLAY_ROOT/Windows/System32/Mount-IsoFromUrl.cmd" "$WORK/staging/Windows/System32/"
cp "$OVERLAY_ROOT/Windows/System32/winpeshl.ini" "$WORK/staging/Windows/System32/"
cp "$TOOLS_DIR/curl.exe" "$TOOLS_DIR/7z.exe" "$WORK/staging/Windows/System32/" 2>/dev/null || true
for tool in 7za.dll 7zxa.dll; do
	[ -f "$TOOLS_DIR/$tool" ] && cp "$TOOLS_DIR/$tool" "$WORK/staging/Windows/System32/"
done

echo "==> Merging wim-inject PowerShell tree"
# shellcheck disable=SC2034
(
	cd "$INJECT_ROOT" && tar cf - Windows
) | (cd "$WORK/staging" && tar xf -)

echo "==> wimapply overlay into $BASE_WIM"
"$WIMLIB" apply "$BASE_WIM" 1 "$WORK/staging" "--ref=$BASE_WIM"

mkdir -p "$(dirname "$OUT")"
echo "==> wimcapture -> $OUT"
"$WIMLIB" capture "$WORK/staging" "$OUT" \
	"FieldIso" \
	"Field ISO boot (HTTP bootstrap + PowerShell)" \
	--boot \
	--compress=maximum \
	--chunk-size=32K

echo ""
echo "==> Verify tools in WIM"
"$WIMLIB" dir "$OUT" 1 "--path=/Windows/System32" | rg -i 'curl\.exe|7z\.exe|Mount-Iso|winpeshl|WindowsPowerShell' || true

echo ""
echo "Done: $OUT"
echo "Optional: ./scripts/inject-fieldiso-drivers-from-imagedeployer.sh"
echo "Publish:   pwsh -File ./scripts/publish-pxe-fieldiso.ps1 -WimPath '$OUT'"

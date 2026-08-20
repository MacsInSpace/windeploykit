#!/bin/sh
# Merge FieldIso overlay + WinPE tools (PowerShell tree, curl, 7z) into FieldIso.wim via wimlib.
#
# Usage:
#   ./scripts/inject-fieldiso-winpe-tools.sh
#   FIELDISO_WIM="$HOME/Library/Application Support/WinDeployKit/plugins/pxe-boot/http/wim/FieldIso.wim" ./scripts/inject-fieldiso-winpe-tools.sh
#   WIM_INJECT_ROOT=/path/to/wim-inject ./scripts/inject-fieldiso-winpe-tools.sh
#
# wim-inject layout (from prepare-fieldiso-wim-inject.ps1 on Windows):
#   sidecar/pxe/fieldiso/wim-inject/Windows/System32/WindowsPowerShell/...
# Repo-root ./wim-inject/ is also detected if sidecar path has no powershell.exe.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Canonical pxe-boot store (AppPaths.ps1): macOS Application Support, else XDG.
if [ "$(uname)" = "Darwin" ]; then
  DEFAULT_PXE_STORE="$HOME/Library/Application Support/WinDeployKit/plugins/pxe-boot"
else
  DEFAULT_PXE_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/windeploykit/plugins/pxe-boot"
fi
PXE_WIM_DIR="${PXE_WIM_DIR:-$DEFAULT_PXE_STORE/http/wim}"
FIELDISO_WIM="${FIELDISO_WIM:-$PXE_WIM_DIR/FieldIso.wim}"

OVERLAY_ROOT="$REPO_ROOT/sidecar/pxe/fieldiso-overlay"
CANONICAL_INJECT="$REPO_ROOT/sidecar/pxe/fieldiso/wim-inject"
ROOT_INJECT="$REPO_ROOT/wim-inject"
TOOLS_DIR="$REPO_ROOT/sidecar/pxe/fieldiso/tools"
PS_REL="Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

resolve_inject_root() {
	if [ -n "${WIM_INJECT_ROOT:-}" ]; then
		printf '%s' "$WIM_INJECT_ROOT"
		return
	fi
	if [ -f "$CANONICAL_INJECT/$PS_REL" ]; then
		printf '%s' "$CANONICAL_INJECT"
		return
	fi
	if [ -f "$ROOT_INJECT/$PS_REL" ]; then
		echo "==> Using repo-root wim-inject/ (consider: mv wim-inject sidecar/pxe/fieldiso/)" >&2
		printf '%s' "$ROOT_INJECT"
		return
	fi
	if [ -d "$ROOT_INJECT/Windows" ] && [ ! -d "$CANONICAL_INJECT/Windows" ]; then
		echo "==> Using repo-root wim-inject/ (sidecar/pxe/fieldiso/wim-inject has no Windows/ tree)" >&2
		printf '%s' "$ROOT_INJECT"
		return
	fi
	printf '%s' "$CANONICAL_INJECT"
}

INJECT_ROOT="$(resolve_inject_root)"

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

if [ ! -x "$WIMLIB" ]; then
	echo "wimlib-imagex not found. Run: pwsh -File ./scripts/fetch-wimlib.ps1" >&2
	exit 1
fi

if [ ! -f "$FIELDISO_WIM" ]; then
	echo "Missing FieldIso.wim: $FIELDISO_WIM" >&2
	exit 1
fi

PS_EXE="$INJECT_ROOT/$PS_REL"
MSCOREE="$INJECT_ROOT/Windows/System32/mscoree.dll"
INJECT_FILE_COUNT="$(find "$INJECT_ROOT" -type f ! -name 'README.txt' 2>/dev/null | wc -l | tr -d ' ')"

if [ ! -f "$PS_EXE" ]; then
	echo "ERROR: WinPE PowerShell export missing:" >&2
	echo "  expected: $PS_EXE" >&2
	echo "  inject root: $INJECT_ROOT ($INJECT_FILE_COUNT file(s) - need hundreds after prepare script)" >&2
	echo "On Windows (Admin powershell.exe):" >&2
	echo "  powershell.exe -ExecutionPolicy Bypass -File .\\scripts\\prepare-fieldiso-wim-inject.ps1 -BaseWinPeWim C:\\path\\winpe.wim" >&2
	echo "Then copy wim-inject\\Windows\\ to Mac:" >&2
	echo "  sidecar/pxe/fieldiso/wim-inject/Windows/" >&2
	exit 1
fi

if [ ! -f "$MSCOREE" ]; then
	echo "ERROR: WinPE-PowerShell export is incomplete (powershell.exe only, no .NET engine DLLs):" >&2
	echo "  missing: $MSCOREE" >&2
	echo "  inject root: $INJECT_ROOT ($INJECT_FILE_COUNT file(s) - expect 300+ after delta export)" >&2
	echo "Re-run on Windows (Admin powershell.exe 5.1, not pwsh 7):" >&2
	echo "  powershell.exe -ExecutionPolicy Bypass -File .\\scripts\\prepare-fieldiso-wim-inject.ps1 -BaseWinPeWim C:\\path\\winpe.wim" >&2
	echo "Look for: exported NNN delta file(s) under Windows\\  (NNN should be >> 128)" >&2
	echo "Then replace sidecar/pxe/fieldiso/wim-inject/Windows/ on Mac and re-run this script." >&2
	exit 1
fi

echo "==> inject root: $INJECT_ROOT ($INJECT_FILE_COUNT file(s), includes powershell.exe + mscoree.dll)"

UPDATE_FILE="$(mktemp)"
trap 'rm -f "$UPDATE_FILE"' EXIT

append_add() {
	local src="$1"
	local wim_path="$2"
	if [ ! -f "$src" ]; then
		return 1
	fi
	# shellcheck disable=SC2028
	printf 'add "%s" %s --no-acls\n' "$src" "$wim_path" >>"$UPDATE_FILE"
	return 0
}

: >"$UPDATE_FILE"

for rel in \
	"Windows/System32/Mount-IsoFromUrl.cmd" \
	"Windows/System32/winpeshl.ini"; do
	append_add "$OVERLAY_ROOT/$rel" "/$rel" || {
		echo "Missing overlay file: $OVERLAY_ROOT/$rel" >&2
		exit 1
	}
done

for tool in curl.exe 7z.exe 7za.dll 7zxa.dll; do
	append_add "$TOOLS_DIR/$tool" "/Windows/System32/$tool" || true
done

if [ -d "$INJECT_ROOT" ]; then
	while IFS= read -r file; do
		rel="${file#$INJECT_ROOT/}"
		wim_path="/$(printf '%s' "$rel" | tr '\\' '/')"
		append_add "$file" "$wim_path" || true
	done <<EOF
$(find "$INJECT_ROOT" -type f ! -name 'README.txt')
EOF
fi

LINE_COUNT="$(wc -l <"$UPDATE_FILE" | tr -d ' ')"
if [ "$LINE_COUNT" -eq 0 ]; then
	echo "Nothing to inject - run fetch-fieldiso-tools.ps1 and prepare-fieldiso-wim-inject.ps1 first." >&2
	exit 1
fi

echo "==> wimlib update $FIELDISO_WIM ($LINE_COUNT file(s))"
WIM_DIR="$(dirname "$FIELDISO_WIM")"
"$WIMLIB" update "$FIELDISO_WIM" 1 <"$UPDATE_FILE"
rm -f "$WIM_DIR"/.fieldiso-overlay-v* 2>/dev/null || true
echo "==> Done. Removed overlay markers - Start field PXE or re-download to refresh menus."

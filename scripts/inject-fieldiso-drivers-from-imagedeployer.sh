#!/bin/sh
# Copy ImageDeployer WinPE driver packages missing from FieldIso.wim (wimlib-imagex).
#
# macOS: uses vendored wimlib from vendor/binaries/pxe-macos/ (no brew required).
# Adds packages to DriverStore/FileRepository AND Windows/Drivers/ImageDeployerImport
# so Mount-IsoFromUrl.cmd can pnputil /add-driver after wpeinit.
#
# Usage:
#   ./scripts/inject-fieldiso-drivers-from-imagedeployer.sh
#   FIELDISO_WIM=~/store/FieldIso.wim IMAGEDEPLOYER_WIM=~/store/ImageDeployer.wim ./scripts/inject-fieldiso-drivers-from-imagedeployer.sh
#
# Defaults: the canonical pxe-boot store. Override with FIELDISO_WIM / IMAGEDEPLOYER_WIM.

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
IMAGEDEPLOYER_WIM="${IMAGEDEPLOYER_WIM:-$PXE_WIM_DIR/ImageDeployer.wim}"
WORK="${WORK:-/tmp/windeploykit-fieldiso-driver-inject}"
BACKUP="${BACKUP:-1}"

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

for required in "$FIELDISO_WIM" "$IMAGEDEPLOYER_WIM"; do
	if [ ! -f "$required" ]; then
		echo "Missing: $required" >&2
		exit 1
	fi
done

DRIVER_REPO_PATH="/Windows/System32/DriverStore/FileRepository"
IMPORT_ROOT="/Windows/Drivers/ImageDeployerImport"

echo "==> ImageDeployer drivers -> FieldIso"
echo "    IMAGEDEPLOYER_WIM=$IMAGEDEPLOYER_WIM"
echo "    FIELDISO_WIM=$FIELDISO_WIM"
echo "    WIMLIB=$WIMLIB"

rm -rf "$WORK"
mkdir -p "$WORK/id-mount" "$WORK/fi-list" "$WORK/id-list"

echo "==> Listing driver packages in each WIM (no full extract)..."
"$WIMLIB" dir "$FIELDISO_WIM" 1 "--path=$DRIVER_REPO_PATH" >"$WORK/fi-list/raw.txt"
"$WIMLIB" dir "$IMAGEDEPLOYER_WIM" 1 "--path=$DRIVER_REPO_PATH" >"$WORK/id-list/raw.txt"

# Package folder names are the first path segment under FileRepository.
awk -v prefix="$DRIVER_REPO_PATH/" '
	$0 ~ "^" prefix && NF { sub("^" prefix, ""); split($0, a, "/"); if (a[1] != "") print a[1] }
' "$WORK/fi-list/raw.txt" | sort -u >"$WORK/fi-list/packages.txt"

awk -v prefix="$DRIVER_REPO_PATH/" '
	$0 ~ "^" prefix && NF { sub("^" prefix, ""); split($0, a, "/"); if (a[1] != "") print a[1] }
' "$WORK/id-list/raw.txt" | sort -u >"$WORK/id-list/packages.txt"

comm -23 "$WORK/id-list/packages.txt" "$WORK/fi-list/packages.txt" >"$WORK/delta-packages.txt"
DELTA_COUNT="$(wc -l <"$WORK/delta-packages.txt" | tr -d ' ')"

if [ "$DELTA_COUNT" -eq 0 ]; then
	echo "No missing driver packages — FieldIso already contains ImageDeployer's FileRepository set."
	exit 0
fi

echo "==> $DELTA_COUNT driver package(s) to inject:"
sed 's/^/    /' "$WORK/delta-packages.txt"

echo "==> Extracting delta packages from ImageDeployer..."
while IFS= read -r pkg; do
	[ -n "$pkg" ] || continue
	dest="$WORK/id-mount/$pkg"
	mkdir -p "$dest"
	"$WIMLIB" extract "$IMAGEDEPLOYER_WIM" 1 \
		"$DRIVER_REPO_PATH/$pkg" \
		--dest-dir="$dest" --no-acls >/dev/null
	# wimlib creates $dest/$pkg/ — flatten to $dest/
	if [ -d "$dest/$pkg" ]; then
		mv "$dest/$pkg"/* "$dest/" 2>/dev/null || true
		rmdir "$dest/$pkg" 2>/dev/null || true
	fi
done <"$WORK/delta-packages.txt"

UPDATE="$WORK/wimupdate.txt"
: >"$UPDATE"
FILE_COUNT=0

while IFS= read -r pkg; do
	[ -n "$pkg" ] || continue
	src_root="$WORK/id-mount/$pkg"
	find "$src_root" -type f | while IFS= read -r f; do
		rel="${f#$src_root/}"
		printf 'add "%s" "%s/%s/%s" --no-acls\n' \
			"$f" "$DRIVER_REPO_PATH" "$pkg" "$rel" >>"$UPDATE"
		printf 'add "%s" "%s/%s/%s" --no-acls\n' \
			"$f" "$IMPORT_ROOT" "$pkg" "$rel" >>"$UPDATE"
	done
done <"$WORK/delta-packages.txt"

FILE_COUNT="$(wc -l <"$UPDATE" | tr -d ' ')"
echo "==> Built wimupdate with $FILE_COUNT file operations"

if [ "$BACKUP" = "1" ]; then
	BACKUP_PATH="${FIELDISO_WIM}.pre-id-drivers-$(date +%Y%m%d-%H%M%S).bak"
	echo "==> Backup -> $BACKUP_PATH"
	cp -p "$FIELDISO_WIM" "$BACKUP_PATH"
fi

BEFORE_SIZE="$(wc -c <"$FIELDISO_WIM" | tr -d ' ')"
echo "==> Updating FieldIso.wim (this may take a few minutes)..."
(
	cd "$(dirname "$WIMLIB")" || exit 1
	"$WIMLIB" update "$FIELDISO_WIM" 1 <"$UPDATE"
)
AFTER_SIZE="$(wc -c <"$FIELDISO_WIM" | tr -d ' ')"

# New WIM content — drop overlay marker so sidecar re-patches Mount-IsoFromUrl.cmd (cmd /k + pnputil).
MARKER_DIR="$(dirname "$FIELDISO_WIM")"
rm -f "$MARKER_DIR/.fieldiso-overlay-v"[0-9]* 2>/dev/null || true

echo "==> Done."
echo "    Packages added: $DELTA_COUNT"
echo "    Size: $BEFORE_SIZE -> $AFTER_SIZE bytes"
echo "    Removed .fieldiso-overlay-v* marker — Start field PXE to patch Mount-IsoFromUrl.cmd overlay v4."
echo "    Or publish it: pwsh -File ./scripts/publish-pxe-fieldiso.ps1 -WimPath $FIELDISO_WIM"

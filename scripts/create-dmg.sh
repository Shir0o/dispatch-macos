#!/usr/bin/env bash
#
# Package a signed Dispatch.app into a compressed, read-only DMG with an
# /Applications shortcut for drag-to-install.
#
# Usage:
#   ./scripts/create-dmg.sh [path/to/Dispatch.app] [path/to/output.dmg]
#
# When arguments are omitted they default to build/Dispatch.app and
# build/Dispatch-<CFBundleShortVersionString>.dmg.
#
# Environment overrides:
#   VOLUME_NAME   Name shown when the DMG is opened (default: Dispatch)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

APP_PATH="${1:-build/Dispatch.app}"
VOLUME_NAME="${VOLUME_NAME:-Dispatch}"

if [ ! -d "${APP_PATH}" ]; then
    echo "error: app bundle not found at '${APP_PATH}' (run ./scripts/package-app.sh first)" >&2
    exit 1
fi

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [ ! -f "${INFO_PLIST}" ]; then
    echo "error: missing ${INFO_PLIST}" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")"
OUTPUT_DMG="${2:-$(dirname "${APP_PATH}")/Dispatch-${VERSION}.dmg}"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-dmg.XXXXXX")"
cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

echo "Staging ${APP_PATH} for disk image..."
# ditto preserves the code signature and bundle metadata.
ditto "${APP_PATH}" "${STAGING_DIR}/Dispatch.app"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${OUTPUT_DMG}"
mkdir -p "$(dirname "${OUTPUT_DMG}")"

echo "Creating ${OUTPUT_DMG}..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${OUTPUT_DMG}" >/dev/null

echo "Verifying ${OUTPUT_DMG}..."
hdiutil verify "${OUTPUT_DMG}" >/dev/null

echo "DMG created: ${OUTPUT_DMG} ($(du -h "${OUTPUT_DMG}" | cut -f1))"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "Building DevTriage in release mode..."
swift build -c release

APP_BUNDLE="DevTriage.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Assembling ${APP_BUNDLE} structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Locate compiled release binary
BIN_PATH=".build/release/DevTriage"
if [ ! -f "${BIN_PATH}" ]; then
    BIN_PATH="$(swift build -c release --show-bin-path)/DevTriage"
fi

cp "${BIN_PATH}" "${MACOS_DIR}/DevTriage"
chmod +x "${MACOS_DIR}/DevTriage"

cp "Info.plist" "${CONTENTS_DIR}/Info.plist"

echo "Signing ${APP_BUNDLE} with entitlements..."
codesign --force --deep --sign - --entitlements DevTriage.entitlements "${APP_BUNDLE}"

echo "Verifying ${APP_BUNDLE} code signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "App packaging completed successfully: ${APP_BUNDLE}"

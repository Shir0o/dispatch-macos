#!/usr/bin/env bash
#
# Build, assemble, version-stamp, and code-sign the Dispatch.app bundle.
#
# Environment overrides (all optional):
#   CONFIGURATION   Swift build configuration (default: release)
#   BUILD_DIR       Output directory (default: build)
#   UNIVERSAL       Set to 1 to build a universal arm64 + x86_64 binary
#   VERSION         CFBundleShortVersionString to stamp into the bundle
#   BUILD_NUMBER    CFBundleVersion to stamp into the bundle
#   SIGN_IDENTITY   codesign identity (default: value from scripts/signing.local,
#                   falling back to "-" for ad-hoc signing)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-build}"
APP_BUNDLE="${BUILD_DIR}/Dispatch.app"
UNIVERSAL="${UNIVERSAL:-0}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

# Optional, git-ignored local signing override (see signing.local.example).
# An explicit SIGN_IDENTITY from the environment still wins, which is how the
# release workflow selects its Developer ID identity.
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "${SCRIPT_DIR}/signing.local" ]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/signing.local"
fi

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_ARGS=(-c "${CONFIGURATION}")
if [ "${UNIVERSAL}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
    echo "Building Dispatch (${CONFIGURATION}, universal arm64 + x86_64)..."
else
    echo "Building Dispatch (${CONFIGURATION})..."
fi

swift build "${BUILD_ARGS[@]}"

CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Assembling ${APP_BUNDLE} structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

# Locate the compiled release binary (SwiftPM writes universal products to
# .build/apple/Products/<Configuration>, so ask SwiftPM for the real path).
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Dispatch"
if [ ! -f "${BIN_PATH}" ]; then
    BIN_PATH=".build/${CONFIGURATION}/Dispatch"
fi
if [ ! -f "${BIN_PATH}" ]; then
    echo "error: could not locate the compiled Dispatch binary" >&2
    exit 1
fi

cp "${BIN_PATH}" "${MACOS_DIR}/Dispatch"
chmod +x "${MACOS_DIR}/Dispatch"

# Ensure @executable_path/../Frameworks is in rpath so Sparkle.framework resolves
if ! otool -l "${MACOS_DIR}/Dispatch" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/Dispatch"
fi

# Locate and copy Sparkle.framework into Contents/Frameworks
SPARKLE_FRAMEWORK="$(find .build -name "Sparkle.framework" -type d | head -n 1)"
if [ -n "${SPARKLE_FRAMEWORK}" ] && [ -d "${SPARKLE_FRAMEWORK}" ]; then
    echo "Embedding Sparkle.framework from ${SPARKLE_FRAMEWORK}..."
    cp -R "${SPARKLE_FRAMEWORK}" "${FRAMEWORKS_DIR}/"
fi

cp "Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Stamp the release version into the assembled bundle without touching the
# checked-in Info.plist (the tag remains the single source of truth).
if [ -n "${VERSION}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
    echo "Stamped CFBundleShortVersionString: ${VERSION}"
fi
if [ -n "${BUILD_NUMBER}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
    echo "Stamped CFBundleVersion: ${BUILD_NUMBER}"
fi

if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "Signing ${APP_BUNDLE} ad-hoc with entitlements..."
    codesign --force --deep --sign - --entitlements Dispatch.entitlements "${APP_BUNDLE}"
else
    echo "Signing ${APP_BUNDLE} with identity '${SIGN_IDENTITY}'..."
    codesign --force --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" \
        --entitlements Dispatch.entitlements "${APP_BUNDLE}"
fi

echo "Verifying ${APP_BUNDLE} code signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "Architectures: $(lipo -archs "${MACOS_DIR}/Dispatch")"
echo "Bundle size:   $(du -sh "${APP_BUNDLE}" | cut -f1)"
echo "App packaging completed successfully: ${APP_BUNDLE}"

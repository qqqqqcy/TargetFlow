#!/usr/bin/env bash
set -euo pipefail

# Release helper for Dayflow: builds, signs, notarizes, and packages a DMG for distribution.
#
# Usage:
#   ./scripts/release_dmg.sh
#
# Optional env vars:
#   SCHEME           - Xcode scheme (default: Dayflow)
#   CONFIG           - Xcode configuration (default: Release)
#   DERIVED_DATA     - Derived data path (default: build)
#   APP_NAME         - App name (default: Dayflow)
#   ENTITLEMENTS     - Entitlements plist path (default: Dayflow/Dayflow/Dayflow.entitlements)
#   SIGN_ID          - Codesign identity (e.g. "Developer ID Application: Your Name (TEAMID)")
#   VOL_NAME         - DMG volume name (defaults to APP_NAME)
#   DMG_NAME         - Output DMG name (defaults to "${APP_NAME}.dmg")
#   NOTARY_PROFILE   - Saved notarytool keychain profile (optional)
#   NOTARY_APPLE_ID  - Apple ID for notarytool (optional)
#   NOTARY_TEAM_ID   - Team ID for notarytool (optional)
#   NOTARY_APP_PASSWORD - App-specific password for Apple ID (optional)
#   ASC_KEY_ID       - App Store Connect API key ID (optional)
#   ASC_ISSUER_ID    - App Store Connect Issuer ID (optional)
#   ASC_P8_PATH      - Path to .p8 private key (optional)

# Load optional per-developer config
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/release.env"
fi

SCHEME=${SCHEME:-Dayflow}
CONFIG=${CONFIG:-Release}
DERIVED_DATA=${DERIVED_DATA:-build}
APP_NAME=${APP_NAME:-Dayflow}
ENTITLEMENTS=${ENTITLEMENTS:-Dayflow/Dayflow/Dayflow.entitlements}
VOL_NAME=${VOL_NAME:-$APP_NAME}
DMG_NAME=${DMG_NAME:-"${APP_NAME}.dmg"}

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app"
# Work in a non-iCloud temporary directory to avoid fileprovider xattrs
SANITIZED_DIR=${SANITIZED_DIR:-$(mktemp -d -t dayflow_sign)}
trap 'rm -rf "${SANITIZED_DIR}"' EXIT
SANITIZED_APP="${SANITIZED_DIR}/${APP_NAME}.app"

# Fixed project location inside repo
PROJECT_PATH=${PROJECT_PATH:-Dayflow/Dayflow.xcodeproj}
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "ERROR: Xcode project not found at $PROJECT_PATH" >&2
  exit 1
fi

echo "[1/6] Building ${APP_NAME} (${SCHEME}|${CONFIG}) using project ${PROJECT_PATH} with code signing disabled…"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "[2/6] Determining Developer ID signing identity…"
SIGN_ID=${SIGN_ID:-}
if [[ -z "${SIGN_ID}" ]]; then
  # Try to pick the first available Developer ID Application identity.
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}') || true
fi
if [[ -z "${SIGN_ID}" ]]; then
  echo "ERROR: No Developer ID Application identity found. Set SIGN_ID env or import certificate." >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
echo "Using signing identity: ${SIGN_ID}"

echo "[3/6] Creating sanitized copy for signing…"
rm -rf "${SANITIZED_DIR}"
mkdir -p "${SANITIZED_DIR}"
# Copy without extended attributes or resource forks
ditto --noextattr --norsrc "${APP_PATH}" "${SANITIZED_APP}"

echo "[4/6] Codesigning…"
# Ensure any stray metadata is gone
rm -f "${SANITIZED_APP}"/Icon? 2>/dev/null || true
find -L "${SANITIZED_APP}" -name ".DS_Store" -delete || true
if command -v xattr >/dev/null 2>&1; then
  xattr -rc "${SANITIZED_APP}" 2>/dev/null || true
fi

# Use the app's current recording and network entitlements.
RESOLVED_ENTS="${SANITIZED_DIR}/resolved.entitlements"
cp "${ENTITLEMENTS}" "${RESOLVED_ENTS}"

# Now sign the top-level app bundle (no --deep), using resolved entitlements
codesign -vvv --force --strict \
  --options runtime \
  --timestamp \
  --entitlements "${RESOLVED_ENTS}" \
  --sign "${SIGN_ID}" \
  "${SANITIZED_APP}"

echo "[5/6] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${SANITIZED_APP}"
spctl -a -vvv --type execute "${SANITIZED_APP}" || true

echo "[6/6] Creating DMG with create-dmg…"
# Require create-dmg for reliable DMG styling
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "ERROR: create-dmg is required but not installed." >&2
  echo "       Install it with: brew install create-dmg" >&2
  exit 1
fi

# Default to project's background image
SCRIPT_PARENT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_BG="${SCRIPT_PARENT}/docs/assets/dmg-background.png"
DMG_BG=${DMG_BG:-$DEFAULT_BG}

if [[ ! -f "${DMG_BG}" ]]; then
  echo "ERROR: Background image not found at ${DMG_BG}" >&2
  exit 1
fi

rm -f "${DMG_NAME}"

# Window size and positions tuned for docs/assets/dmg-background.png (1550×960 @2x, displays as 775×480)
# Dayflow app on left, Applications folder on right (swapped from typical layout)
create-dmg \
  --volname "${VOL_NAME}" \
  --background "${DMG_BG}" \
  --window-size 775 480 \
  --icon-size "${DMG_ICON_SIZE:-128}" \
  --icon "${APP_NAME}.app" 200 270 \
  --app-drop-link 575 270 \
  --no-internet-enable \
  "${DMG_NAME}" \
  "${SANITIZED_APP}"

echo "[6/6] Submitting DMG for notarization…"
NOTARY_ARGS=("${DMG_NAME}")
if [[ "${NO_NOTARIZE:-0}" == "1" ]]; then
  echo "Skipping notarization: NO_NOTARIZE=1"
  NOTARY_ARGS=()
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Using keychain profile: ${NOTARY_PROFILE}"
  NOTARY_ARGS=(submit "${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait)
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" ]]; then
  echo "Using Apple ID credentials for notarytool"
  NOTARY_ARGS=(submit "${DMG_NAME}" --apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PASSWORD}" --wait)
elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_P8_PATH:-}" ]]; then
  echo "Using App Store Connect API key for notarytool"
  NOTARY_ARGS=(submit "${DMG_NAME}" --key "${ASC_P8_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" --wait)
else
  echo "Skipping notarization: no credentials provided (set NOTARY_PROFILE or Apple ID or ASC_* env)."
  NOTARY_ARGS=()
fi

if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  xcrun notarytool "${NOTARY_ARGS[@]}"
echo "[6/6] Stapling notarization ticket…"
  xcrun stapler staple "${DMG_NAME}"
  xcrun stapler validate "${DMG_NAME}"
else
  echo "NOTE: DMG was NOT notarized. Provide credentials to notarize."
fi

echo "Done. Output: ${DMG_NAME}"

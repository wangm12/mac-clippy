#!/usr/bin/env bash
# ==============================================================================
# Universal macOS App DMG & ZIP Packager
# ==============================================================================
# Generates:
#   1. dist/<AppName>.dmg with /Applications symlink
#   2. dist/<AppName>.zip preserving macOS resource forks & signatures
#   3. dist/SHA256SUMS.txt
#
# Can package an existing .app or build directly from Xcode.
# ==============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Detect or configure app name
APP_NAME="${APP_NAME:-}"
if [[ -z "${APP_NAME}" ]]; then
  # Try to find xcodeproj
  first_proj="$(find "${ROOT}" -maxdepth 2 -name "*.xcodeproj" -not -path "*/.*/*" | head -n 1 || true)"
  if [[ -n "${first_proj}" ]]; then
    APP_NAME="$(basename "${first_proj}" .xcodeproj)"
  else
    APP_NAME="$(basename "${ROOT}")"
  fi
fi

SCHEME="${SCHEME:-${APP_NAME}}"
CONFIGURATION="${CONFIGURATION:-Release}"
VOLUME_NAME="${VOLUME_NAME:-${APP_NAME}}"
DIST_DIR="${DIST_DIR:-${ROOT}/dist}"
STAGING_DIR="${STAGING_DIR:-${ROOT}/.build/${APP_NAME}-dmg-staging}"
DERIVED_DATA="${DERIVED_DATA:-${ROOT}/.build/DerivedData/${APP_NAME}-${CONFIGURATION}}"
DMG_PATH="${DMG_PATH:-${DIST_DIR}/${APP_NAME}.dmg}"
ZIP_PATH="${ZIP_PATH:-${DIST_DIR}/${APP_NAME}.zip}"
CODE_SIGNING_MODE="${CODE_SIGNING_ALLOWED:-NO}"
PREBUILT_APP="${PREBUILT_APP:-}"

mkdir -p "${ROOT}/.build" "${DIST_DIR}"

if [[ -n "${PREBUILT_APP}" ]]; then
  echo "==> Using prebuilt application at: ${PREBUILT_APP}"
  APP_PATH="${PREBUILT_APP}"
else
  # Locate project or workspace
  WORKSPACE="$(find "${ROOT}" -maxdepth 2 -name "*.xcworkspace" -not -path "*/.*/*" | head -n 1 || true)"
  PROJECT="$(find "${ROOT}" -maxdepth 2 -name "*.xcodeproj" -not -path "*/.*/*" | head -n 1 || true)"

  XCODEBUILD_ARGS=(
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    "CODE_SIGNING_ALLOWED=${CODE_SIGNING_MODE}"
  )

  if [[ -n "${WORKSPACE}" ]]; then
    echo "==> Building from workspace: $(basename "${WORKSPACE}")"
    XCODEBUILD_ARGS=(-workspace "${WORKSPACE}" "${XCODEBUILD_ARGS[@]}")
  elif [[ -n "${PROJECT}" ]]; then
    echo "==> Building from project: $(basename "${PROJECT}")"
    XCODEBUILD_ARGS=(-project "${PROJECT}" "${XCODEBUILD_ARGS[@]}")
  else
    echo "error: no .xcworkspace or .xcodeproj found in ${ROOT}" >&2
    exit 1
  fi

  if [[ "${CODE_SIGNING_MODE}" == "YES" ]]; then
    if [[ -z "${CODE_SIGN_IDENTITY:-}" || -z "${DEVELOPMENT_TEAM:-}" ]]; then
      echo "error: signed packaging requires CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM" >&2
      exit 2
    fi
    XCODEBUILD_ARGS+=(
      ENABLE_HARDENED_RUNTIME=YES
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_STYLE=Manual
      "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}"
      "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    )
  else
    XCODEBUILD_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
  fi

  echo "==> Building ${APP_NAME} (${CONFIGURATION})..."
  xcodebuild "${XCODEBUILD_ARGS[@]}" build

  # Locate built .app bundle
  APP_PATH="$(find "${DERIVED_DATA}/Build/Products/${CONFIGURATION}" -name "${APP_NAME}.app" -o -name "*.app" | head -n 1 || true)"
fi

if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "error: could not find built .app bundle in ${DERIVED_DATA:-${APP_PATH}}" >&2
  exit 1
fi

echo "==> Found App bundle at: ${APP_PATH}"

# Staging DMG
echo "==> Staging DMG..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
trap 'rm -rf "${STAGING_DIR}"' EXIT

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# Create DMG
echo "==> Creating DMG: ${DMG_PATH}..."
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "==> Successfully generated DMG: ${DMG_PATH}"

# Create ZIP archive (preserves symlinks, attributes, resource forks)
echo "==> Creating ZIP: ${ZIP_PATH}..."
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "==> Successfully generated ZIP: ${ZIP_PATH}"

# Generate checksums
echo "==> Generating SHA256 checksums..."
(
  cd "${DIST_DIR}"
  shasum -a 256 "$(basename "${DMG_PATH}")" "$(basename "${ZIP_PATH}")" > SHA256SUMS.txt
)
echo "==> Checksums written to: ${DIST_DIR}/SHA256SUMS.txt"
cat "${DIST_DIR}/SHA256SUMS.txt"

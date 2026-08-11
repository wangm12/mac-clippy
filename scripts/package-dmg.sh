#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/MacClippy.xcodeproj"
SCHEME="MacClippy"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/DerivedData/MacClippy-$CONFIGURATION}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
STAGING_DIR="${STAGING_DIR:-$ROOT/.build/mac-clippy-dmg-staging}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/MacClippy.dmg}"
VOLUME_NAME="${VOLUME_NAME:-Mac Clippy}"
CODE_SIGNING_MODE="${CODE_SIGNING_ALLOWED:-NO}"
PREBUILT_APP="${PREBUILT_APP:-}"

require_path_under() {
  local path="$1"
  local root="$2"
  if [[ "${path}" != /* || "${path}" == *"/../"* || "${path}" == */.. || "${path}" == *"/./"* || "${path}" == */. ]]; then
    echo "error: path must be absolute and normalized: ${path}" >&2
    exit 2
  fi

  local existing_parent="${path}"
  while [[ ! -d "${existing_parent}" && "${existing_parent}" != "/" ]]; do
    existing_parent="${existing_parent%/*}"
  done
  local canonical_parent
  canonical_parent="$(cd -P "${existing_parent}" && pwd)"
  local canonical_path="${canonical_parent}/${path##*/}"
  local canonical_root
  canonical_root="$(cd -P "${root}" && pwd)"
  case "${canonical_path}" in
    "${canonical_root}"|"${canonical_root}"/*) ;;
    *) echo "error: refusing to use path outside ${root}: ${path}" >&2; exit 2 ;;
  esac
}

mkdir -p "${ROOT}/.build" "${ROOT}/dist"
require_path_under "${DERIVED_DATA}" "${ROOT}/.build"
require_path_under "${STAGING_DIR}" "${ROOT}/.build"
staging_parent="${STAGING_DIR}"
while [[ ! -d "${staging_parent}" && "${staging_parent}" != "/" ]]; do
  staging_parent="${staging_parent%/*}"
done
canonical_staging_path="$(cd -P "${staging_parent}" && pwd)/${STAGING_DIR##*/}"
canonical_build_root="$(cd -P "${ROOT}/.build" && pwd)"
if [[ "${canonical_staging_path}" == "${canonical_build_root}" ]]; then
  echo "error: STAGING_DIR must be a dedicated child of ${ROOT}/.build; refusing to delete the build root" >&2
  exit 2
fi
require_path_under "${DIST_DIR}" "${ROOT}/dist"
require_path_under "${DMG_PATH}" "${DIST_DIR}"
if [[ -n "${PREBUILT_APP}" ]]; then
  require_path_under "${PREBUILT_APP}" "${ROOT}/build"
  if [[ ! -d "${PREBUILT_APP}" || "${PREBUILT_APP}" != *.app ]]; then
    echo "error: PREBUILT_APP must point to an existing .app bundle: ${PREBUILT_APP}" >&2
    exit 2
  fi
fi

if [[ -z "${PREBUILT_APP}" ]] && ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required to package MacClippy; refusing to build from a stale project" >&2
  exit 2
fi
if [[ -n "${PREBUILT_APP}" ]]; then
  echo "==> Packaging verified archive product"
  APP_PATH="${PREBUILT_APP}"
else
  echo "==> Regenerating MacClippy Xcode project"
  (cd "$ROOT" && xcodegen generate)

  echo "==> Building MacClippy ($CONFIGURATION)"
  XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA"
    -skipPackagePluginValidation
    "CODE_SIGNING_ALLOWED=$CODE_SIGNING_MODE"
  )

  if [[ "$CODE_SIGNING_MODE" == "YES" ]]; then
    if [[ -z "${CODE_SIGN_IDENTITY:-}" || -z "${DEVELOPMENT_TEAM:-}" ]]; then
      echo "error: signed packaging requires CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM" >&2
      exit 2
    fi
    XCODEBUILD_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
    XCODEBUILD_ARGS+=(CODE_SIGNING_REQUIRED=YES)
    XCODEBUILD_ARGS+=(CODE_SIGN_STYLE=Manual)
    XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
    XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  else
    XCODEBUILD_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
  fi

  xcodebuild "${XCODEBUILD_ARGS[@]}" build
  APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacClippy.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying application metadata"
"$ROOT/scripts/verify-build-metadata.sh" "$APP_PATH"

echo "==> Staging DMG"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Wrote $DMG_PATH"

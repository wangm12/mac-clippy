#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/MacClippy.xcodeproj"
SCHEME="MacClippy"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/DerivedData/MacClippy-$CONFIGURATION}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
STAGING_DIR="${STAGING_DIR:-$ROOT/.build/mac-clippy-dmg-staging}"
ARTIFACT_NAME="${ARTIFACT_NAME:-MacClippy}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/${ARTIFACT_NAME}.dmg}"
ZIP_PATH="${ZIP_PATH:-$DIST_DIR/${ARTIFACT_NAME}.zip}"
CHECKSUM_PATH="${CHECKSUM_PATH:-$DIST_DIR/${ARTIFACT_NAME}-SHA256SUMS.txt}"
VOLUME_NAME="${VOLUME_NAME:-Mac Clippy}"
CODE_SIGNING_MODE="${CODE_SIGNING_ALLOWED:-NO}"
PREBUILT_APP="${PREBUILT_APP:-}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-}"

if [[ ! "${ARTIFACT_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: ARTIFACT_NAME may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 2
fi
if [[ -n "${MARKETING_VERSION}" && ! "${MARKETING_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: MARKETING_VERSION must be X.Y.Z when supplied" >&2
  exit 2
fi
if [[ -n "${CURRENT_PROJECT_VERSION}" && ! "${CURRENT_PROJECT_VERSION}" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]]; then
  echo "error: CURRENT_PROJECT_VERSION must be a valid CFBundleVersion when supplied" >&2
  exit 2
fi

require_path_under() {
  local path="$1"
  local root="$2"
  if [[ "${path}" != /* || "${root}" != /* || "${path}" == *$'\n'* || "${root}" == *$'\n'* ]]; then
    echo "error: path and containment root must be absolute paths without newlines: ${path}" >&2
    exit 2
  fi

  local canonical_path
  canonical_path="$(canonicalize_path "${path}")" || {
    echo "error: could not resolve path safely: ${path}" >&2
    exit 2
  }
  local canonical_root
  canonical_root="$(canonicalize_path "${root}")" || {
    echo "error: could not resolve containment root safely: ${root}" >&2
    exit 2
  }
  case "${canonical_path}" in
    "${canonical_root}"|"${canonical_root}"/*) ;;
    *) echo "error: refusing to use path outside ${root}: ${path}" >&2; exit 2 ;;
  esac
}

canonicalize_path() {
  local raw_path="$1"
  [[ "${raw_path}" == /* ]] || return 1
  local current="/"
  local remainder="${raw_path}"
  local component candidate target symlink_hops=0

  while [[ -n "${remainder}" ]]; do
    while [[ "${remainder}" == /* ]]; do
      remainder="${remainder#/}"
    done
    [[ -n "${remainder}" ]] || break
    if [[ "${remainder}" == */* ]]; then
      component="${remainder%%/*}"
      remainder="${remainder#*/}"
    else
      component="${remainder}"
      remainder=""
    fi

    case "${component}" in
      ""|.) continue ;;
      ..)
        if [[ "${current}" != "/" ]]; then
          current="${current%/*}"
          [[ -n "${current}" ]] || current="/"
        fi
        continue
        ;;
    esac

    if [[ "${current}" == "/" ]]; then
      candidate="/${component}"
    else
      candidate="${current}/${component}"
    fi

    if [[ -L "${candidate}" ]]; then
      symlink_hops=$((symlink_hops + 1))
      (( symlink_hops <= 40 )) || return 1
      target="$(readlink "${candidate}")" || return 1
      [[ -n "${target}" ]] || return 1
      [[ "${target}" == /* ]] && current="/"
      remainder="${target%/}/${remainder}"
      continue
    fi

    if [[ -e "${candidate}" ]]; then
      if [[ -d "${candidate}" ]]; then
        current="$(cd -P -- "${candidate}" && pwd -P)" || return 1
      else
        [[ -z "${remainder}" ]] || return 1
        current="${candidate}"
      fi
    else
      current="${candidate}"
    fi
  done

  printf '%s\n' "${current}"
}

mkdir -p "${ROOT}/.build" "${ROOT}/dist"
if [[ -L "${ROOT}/.build" || -L "${ROOT}/dist" ]]; then
  echo "error: .build and dist must be real directories inside the repository" >&2
  exit 2
fi
require_path_under "${DERIVED_DATA}" "${ROOT}/.build"
require_path_under "${STAGING_DIR}" "${ROOT}/.build"
canonical_staging_path="$(canonicalize_path "${STAGING_DIR}")"
canonical_build_root="$(canonicalize_path "${ROOT}/.build")"
if [[ "${canonical_staging_path}" == "${canonical_build_root}" ]]; then
  echo "error: STAGING_DIR must be a dedicated child of ${ROOT}/.build; refusing to delete the build root" >&2
  exit 2
fi
require_path_under "${DIST_DIR}" "${ROOT}/dist"
require_path_under "${DMG_PATH}" "${DIST_DIR}"
require_path_under "${ZIP_PATH}" "${DIST_DIR}"
require_path_under "${CHECKSUM_PATH}" "${DIST_DIR}"
if [[ -n "${PREBUILT_APP}" ]]; then
  require_path_under "${PREBUILT_APP}" "${ROOT}/build"
  if [[ ! -d "${PREBUILT_APP}" || "${PREBUILT_APP}" != *.app ]]; then
    echo "error: PREBUILT_APP must point to an existing .app bundle: ${PREBUILT_APP}" >&2
    exit 2
  fi
fi

# Use the same canonical paths that passed the containment checks so later
# rm/cp/archive commands do not reinterpret trailing dots or parent segments.
DERIVED_DATA="$(canonicalize_path "${DERIVED_DATA}")"
STAGING_DIR="$(canonicalize_path "${STAGING_DIR}")"
DIST_DIR="$(canonicalize_path "${DIST_DIR}")"
DMG_PATH="$(canonicalize_path "${DMG_PATH}")"
ZIP_PATH="$(canonicalize_path "${ZIP_PATH}")"
CHECKSUM_PATH="$(canonicalize_path "${CHECKSUM_PATH}")"
if [[ -n "${PREBUILT_APP}" ]]; then
  PREBUILT_APP="$(canonicalize_path "${PREBUILT_APP}")"
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

  if [[ -n "${MARKETING_VERSION}" ]]; then
    XCODEBUILD_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION}")
  fi
  if [[ -n "${CURRENT_PROJECT_VERSION}" ]]; then
    XCODEBUILD_ARGS+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
  fi

  xcodebuild "${XCODEBUILD_ARGS[@]}" build
  APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacClippy.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying application metadata"
EXPECTED_MARKETING_VERSION="${MARKETING_VERSION}" \
EXPECTED_BUILD_VERSION="${CURRENT_PROJECT_VERSION}" \
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

echo "==> Creating ZIP archive"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "==> Wrote $ZIP_PATH"

rm -f "${CHECKSUM_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "${DMG_PATH#${DIST_DIR}/}" "${ZIP_PATH#${DIST_DIR}/}" > "${CHECKSUM_PATH#${DIST_DIR}/}")
echo "==> Wrote ${CHECKSUM_PATH}"

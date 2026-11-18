#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-MacClippy.xcodeproj}"
SCHEME="${SCHEME:-MacClippy}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ROOT_DIR}/build/archives/MacClippy.xcarchive}"
DERIVED_DATA="${DERIVED_DATA:-${ROOT_DIR}/build/derived-data}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-}"

if [[ -z "${DEVELOPER_IDENTITY}" || -z "${DEVELOPMENT_TEAM}" ]]; then
  echo "error: set DEVELOPER_IDENTITY and DEVELOPMENT_TEAM; credentials are intentionally not stored in the repository" >&2
  exit 2
fi

if [[ "${DEVELOPER_IDENTITY}" != Developer\ ID\ Application:* ]]; then
  echo "error: DEVELOPER_IDENTITY must start with 'Developer ID Application:'" >&2
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

cd "${ROOT_DIR}"
xcodegen generate

XCODEBUILD_ARGS=(
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${DEVELOPER_IDENTITY}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  ENABLE_HARDENED_RUNTIME=YES
)
if [[ -n "${MARKETING_VERSION}" ]]; then
  XCODEBUILD_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION}")
fi
if [[ -n "${CURRENT_PROJECT_VERSION}" ]]; then
  XCODEBUILD_ARGS+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" archive

EXPECTED_MARKETING_VERSION="${MARKETING_VERSION}" \
EXPECTED_BUILD_VERSION="${CURRENT_PROJECT_VERSION}" \
  "${ROOT_DIR}/scripts/verify-build-metadata.sh" \
  "${ARCHIVE_PATH}/Products/Applications/MacClippy.app"

echo "Archive created at ${ARCHIVE_PATH}"

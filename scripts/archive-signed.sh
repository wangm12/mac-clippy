#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-MacClippy.xcodeproj}"
SCHEME="${SCHEME:-MacClippy}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ROOT_DIR}/build/archives/MacClippy.xcarchive}"
DERIVED_DATA="${DERIVED_DATA:-${ROOT_DIR}/build/derived-data}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

if [[ -z "${DEVELOPER_IDENTITY}" || -z "${DEVELOPMENT_TEAM}" ]]; then
  echo "error: set DEVELOPER_IDENTITY and DEVELOPMENT_TEAM; credentials are intentionally not stored in the repository" >&2
  exit 2
fi

if [[ "${DEVELOPER_IDENTITY}" != Developer\ ID\ Application:* ]]; then
  echo "error: DEVELOPER_IDENTITY must start with 'Developer ID Application:'" >&2
  exit 2
fi

cd "${ROOT_DIR}"
xcodegen generate

xcodebuild \
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
  ENABLE_HARDENED_RUNTIME=YES \
  archive

echo "Archive created at ${ARCHIVE_PATH}"

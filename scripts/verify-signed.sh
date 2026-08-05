#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "usage: $0 /path/to/MacClippy.app" >&2
  exit 2
fi

if [[ "${APP_PATH}" != *.app ]]; then
  echo "error: expected an application bundle" >&2
  exit 2
fi

echo "== codesign identity =="
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
printf '%s\n' "${SIGNATURE_DETAILS}"
if ! grep -q 'Authority=Developer ID Application:' <<<"${SIGNATURE_DETAILS}"; then
  echo "error: application is not signed by a Developer ID Application identity" >&2
  exit 1
fi
if ! grep -q 'TeamIdentifier=' <<<"${SIGNATURE_DETAILS}"; then
  echo "error: application signature has no TeamIdentifier" >&2
  exit 1
fi
if ! grep -Eiq 'flags=.*runtime' <<<"${SIGNATURE_DETAILS}"; then
  echo "error: application signature does not enable the hardened runtime" >&2
  exit 1
fi

echo "== strict signature verification =="
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

ENTITLEMENTS_FILE="$(mktemp -t macclippy-entitlements.XXXXXX)"
trap 'rm -f "${ENTITLEMENTS_FILE}"' EXIT
codesign -d --entitlements :- "${APP_PATH}" >"${ENTITLEMENTS_FILE}" 2>/dev/null || true
if plutil -extract com.apple.security.get-task-allow raw -o - "${ENTITLEMENTS_FILE}" 2>/dev/null | grep -q '^true$'; then
  echo "error: release application contains com.apple.security.get-task-allow" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/verify-build-metadata.sh" "${APP_PATH}"

echo "== Gatekeeper assessment =="
spctl --assess --type execute --verbose=4 "${APP_PATH}"

echo "Signature, hardened-runtime inputs, and Gatekeeper assessment passed."

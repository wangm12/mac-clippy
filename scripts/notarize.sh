#!/usr/bin/env bash
set -euo pipefail

NOTARY_INPUT="${NOTARY_INPUT:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
STAPLE_TARGET="${STAPLE_TARGET:-}"

if [[ -z "${NOTARY_INPUT}" || -z "${NOTARY_PROFILE}" ]]; then
  echo "error: set NOTARY_INPUT and NOTARY_PROFILE; the profile must already exist in the local keychain" >&2
  exit 2
fi
if [[ ! -f "${NOTARY_INPUT}" ]]; then
  echo "error: notarization input does not exist: ${NOTARY_INPUT}" >&2
  exit 2
fi
if [[ "${NOTARY_INPUT}" == *.app ]]; then
  echo "error: submit a zip, dmg, or pkg; staple the app separately with STAPLE_TARGET when submitting a zip" >&2
  exit 2
fi

xcrun notarytool submit "${NOTARY_INPUT}" --keychain-profile "${NOTARY_PROFILE}" --wait

if [[ -n "${STAPLE_TARGET}" ]]; then
  if [[ ! -e "${STAPLE_TARGET}" ]]; then
    echo "error: staple target does not exist: ${STAPLE_TARGET}" >&2
    exit 2
  fi
  xcrun stapler staple "${STAPLE_TARGET}"
  xcrun stapler validate "${STAPLE_TARGET}"
  if [[ "${STAPLE_TARGET}" == *.app ]]; then
    spctl --assess --type execute --verbose=4 "${STAPLE_TARGET}"
  fi
fi

echo "Notarization completed; stapling was performed only when STAPLE_TARGET was supplied."

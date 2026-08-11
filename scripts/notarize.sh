#!/usr/bin/env bash
set -euo pipefail

NOTARY_INPUT="${NOTARY_INPUT:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
STAPLE_TARGET="${STAPLE_TARGET:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"

if [[ -z "${NOTARY_INPUT}" || -z "${NOTARY_PROFILE}" || -z "${STAPLE_TARGET}" || -z "${EXPECTED_TEAM_ID}" ]]; then
  echo "error: set NOTARY_INPUT, NOTARY_PROFILE, STAPLE_TARGET, and EXPECTED_TEAM_ID; the profile must already exist in the local keychain" >&2
  exit 2
fi
if [[ ! -f "${NOTARY_INPUT}" ]]; then
  echo "error: notarization input does not exist: ${NOTARY_INPUT}" >&2
  exit 2
fi
if [[ "${NOTARY_INPUT}" == *.app ]]; then
  echo "error: submit a zip, dmg, or pkg; staple the app separately with STAPLE_TARGET" >&2
  exit 2
fi

if [[ ! -e "${STAPLE_TARGET}" ]]; then
  echo "error: staple target does not exist: ${STAPLE_TARGET}" >&2
  exit 2
fi

xcrun notarytool submit "${NOTARY_INPUT}" --keychain-profile "${NOTARY_PROFILE}" --wait

xcrun stapler staple "${STAPLE_TARGET}"
xcrun stapler validate "${STAPLE_TARGET}"
if [[ "${STAPLE_TARGET}" == *.dmg ]]; then
  spctl --assess --type open --verbose=4 "${STAPLE_TARGET}"
  EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID}" \
    "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/verify-dmg.sh" "${STAPLE_TARGET}"
else
  spctl --assess --type execute --verbose=4 "${STAPLE_TARGET}"
  EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID}" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-signed.sh" "${STAPLE_TARGET}"
fi

echo "Notarization, stapling, and staple validation completed."

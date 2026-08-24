#!/usr/bin/env bash
set -euo pipefail

# Pick a DMG-signing identity from `security find-identity -v -p codesigning`
# output on stdin. Preference: the stable project self-signed name, then
# Developer ID Application, then Apple Development. The self-signed identity
# is first so local DMGs match GitHub releases that import the same .p12.
# Other identities are ignored so a leftover certificate cannot silently
# sign the app.
SELF_SIGN_IDENTITY="${MACCLIPPY_SELF_SIGN_IDENTITY:-Mac Clippy}"

developer_id=""
apple_dev=""
self_sign=""

while IFS= read -r line; do
  [[ "${line}" =~ ^[[:space:]]*[0-9]+\) ]] || continue
  name="${line#*\"}"
  name="${name%\"*}"
  [[ -n "${name}" && "${name}" != "${line}" ]] || continue
  if [[ "${name}" == Developer\ ID\ Application:* ]]; then
    developer_id="${developer_id:-${name}}"
  elif [[ "${name}" == Apple\ Development:* ]]; then
    apple_dev="${apple_dev:-${name}}"
  elif [[ "${name}" == "${SELF_SIGN_IDENTITY}" ]]; then
    self_sign="${name}"
  fi
done

if [[ -n "${self_sign}" ]]; then
  printf '%s\n' "${self_sign}"
elif [[ -n "${developer_id}" ]]; then
  printf '%s\n' "${developer_id}"
elif [[ -n "${apple_dev}" ]]; then
  printf '%s\n' "${apple_dev}"
fi
exit 0

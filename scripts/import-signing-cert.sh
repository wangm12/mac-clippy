#!/usr/bin/env bash
# Import a stable self-signed identity from MACOS_CERT_P12 + MACOS_CERT_PASSWORD.
# Intended for GitHub Actions so release DMGs reuse the local certificate.
# No-op when the secrets are unset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P12_INPUT="${MACOS_CERT_P12:-}"
P12_PASSWORD="${MACOS_CERT_PASSWORD:-}"

if [[ -z "${P12_INPUT}" ]]; then
  echo "==> MACOS_CERT_P12 is unset; skipping signing-certificate import"
  exit 0
fi
if [[ -z "${P12_PASSWORD}" ]]; then
  echo "error: MACOS_CERT_PASSWORD is required when MACOS_CERT_P12 is set" >&2
  exit 2
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

p12_path="${tmp}/identity.p12"
if [[ -f "${P12_INPUT}" ]]; then
  cp "${P12_INPUT}" "${p12_path}"
else
  printf '%s' "${P12_INPUT}" | base64 --decode > "${p12_path}"
fi

keychain_dir="${RUNNER_TEMP:-${ROOT}/.build}"
mkdir -p "${keychain_dir}"
keychain="${keychain_dir}/macclippy-signing.keychain-db"
keychain_password="${MACCLIPPY_KEYCHAIN_PASSWORD:-$(openssl rand -hex 20)}"

if [[ -f "${keychain}" ]]; then
  security delete-keychain "${keychain}" >/dev/null 2>&1 || true
fi

echo "==> Creating signing keychain ${keychain}"
security create-keychain -p "${keychain_password}" "${keychain}"
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${keychain_password}" "${keychain}"
security import "${p12_path}" -k "${keychain}" -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "${keychain_password}" "${keychain}" >/dev/null

openssl pkcs12 -in "${p12_path}" -nokeys -clcerts -passin "pass:${P12_PASSWORD}" \
  -out "${tmp}/cert.pem" 2>/dev/null \
  || openssl pkcs12 -in "${p12_path}" -nokeys -clcerts -legacy \
    -passin "pass:${P12_PASSWORD}" -out "${tmp}/cert.pem"

security add-trusted-cert -r trustRoot -p codeSign -k "${keychain}" "${tmp}/cert.pem"

existing_keychains=()
while IFS= read -r keychain_path; do
  keychain_path="${keychain_path//\"/}"
  keychain_path="${keychain_path#"${keychain_path%%[![:space:]]*}"}"
  keychain_path="${keychain_path%"${keychain_path##*[![:space:]]}"}"
  [[ -n "${keychain_path}" ]] && existing_keychains+=("${keychain_path}")
done < <(security list-keychains -d user)
security list-keychain -d user -s "${keychain}" "${existing_keychains[@]}"

echo "==> Imported signing certificate"
security find-identity -v -p codesigning

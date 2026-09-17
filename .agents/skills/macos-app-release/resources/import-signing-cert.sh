#!/usr/bin/env bash
# ==============================================================================
# GitHub Actions Code Signing Certificate Importer
# ==============================================================================
# Imports a Developer ID certificate from secrets:
#   - MACOS_CERT_P12 (base64 or raw file path)
#   - MACOS_CERT_PASSWORD
# If secrets are not provided, gracefully exits (supports unsigned builds).
# ==============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P12_INPUT="${MACOS_CERT_P12:-}"
P12_PASSWORD="${MACOS_CERT_PASSWORD:-}"

if [[ -z "${P12_INPUT}" ]]; then
  echo "==> MACOS_CERT_P12 is unset; skipping signing-certificate import (will build unsigned/ad-hoc)"
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
keychain="${keychain_dir}/signing.keychain-db"
keychain_password="${SIGNING_KEYCHAIN_PASSWORD:-$(openssl rand -hex 20)}"

if [[ -f "${keychain}" ]]; then
  security delete-keychain "${keychain}" >/dev/null 2>&1 || true
fi

echo "==> Creating temporary signing keychain at ${keychain}"
security create-keychain -p "${keychain_password}" "${keychain}"
security set-keychain-settings -t 21600 -u "${keychain}"
security unlock-keychain -p "${keychain_password}" "${keychain}"
security default-keychain -s "${keychain}"

existing_keychains=()
while IFS= read -r keychain_path; do
  keychain_path="${keychain_path//\"/}"
  keychain_path="${keychain_path#"${keychain_path%%[![:space:]]*}"}"
  keychain_path="${keychain_path%"${keychain_path##*[![:space:]]}"}"
  [[ -n "${keychain_path}" ]] && existing_keychains+=("${keychain_path}")
done < <(security list-keychains -d user)
security list-keychain -d user -s "${keychain}" "${existing_keychains[@]}"

# Import certificate
security import "${p12_path}" -k "${keychain}" -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign -T /usr/bin/security -A

# Authorize codesign without GUI prompts
run_with_timeout() {
  local seconds="$1"
  shift
  python3 -c "import subprocess, sys
try:
    subprocess.run(sys.argv[2:], timeout=int(sys.argv[1]))
except Exception:
    sys.exit(0)
" "$seconds" "$@" 2>/dev/null || true
}

run_with_timeout 10 security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "${keychain_password}" "${keychain}" >/dev/null 2>&1 || true

openssl pkcs12 -in "${p12_path}" -nokeys -clcerts -passin "pass:${P12_PASSWORD}" \
  -out "${tmp}/cert.pem" 2>/dev/null \
  || openssl pkcs12 -in "${p12_path}" -nokeys -clcerts -legacy \
    -passin "pass:${P12_PASSWORD}" -out "${tmp}/cert.pem"

if command -v sudo >/dev/null 2>&1; then
  sudo security authorizationdb write com.apple.trust-settings.admin allow 2>/dev/null || true
fi

run_with_timeout 10 security add-trusted-cert -r trustRoot -p codeSign -k "${keychain}" "${tmp}/cert.pem" >/dev/null 2>&1 || true

if command -v sudo >/dev/null 2>&1; then
  sudo security authorizationdb remove com.apple.trust-settings.admin 2>/dev/null || true
fi

echo "==> Successfully imported signing identity:"
security find-identity -v -p codesigning || true

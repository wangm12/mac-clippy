#!/usr/bin/env bash
# Create a stable self-signed code-signing identity once, then reuse it.
#
# Ad-hoc signatures identify the app by binary hash. TCC stores that hash, so
# every rebuild looks like a new app and Accessibility / Input Monitoring must
# be removed and granted again. A named certificate makes the designated
# requirement the certificate leaf, which stays the same across updates.
#
# This is not a Developer ID and is not notarized. Gatekeeper still blocks the
# first launch of a downloaded copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${MACCLIPPY_SELF_SIGN_IDENTITY:-Mac Clippy}"
TEAM="${MACCLIPPY_SELF_SIGN_TEAM:-MCLIPPY001}"
OUT_DIR="${MACCLIPPY_SIGNING_DIR:-${ROOT}/.build/signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"${NAME}\""; then
  echo "==> \"${NAME}\" already exists and is trusted — nothing to do."
  security find-identity -v -p codesigning | grep -F "\"${NAME}\"" || true
  exit 0
fi

keychain="$(security default-keychain -d user | tr -d ' "')"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "==> Generating a self-signed code-signing certificate (${NAME}, OU=${TEAM})"
cat > "${tmp}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = ${NAME}
OU = ${TEAM}
O  = Mac Clippy

[ext]
basicConstraints     = critical, CA:true
keyUsage             = critical, digitalSignature, keyCertSign
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -config "${tmp}/openssl.cnf" 2>/dev/null

# Apple's Security framework cannot read OpenSSL 3's default PKCS#12 encryption.
p12_password="$(openssl rand -hex 20)"
openssl pkcs12 -export \
  -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" -out "${tmp}/identity.p12" \
  -name "${NAME}" -passout "pass:${p12_password}" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "==> Importing into ${keychain}"
security import "${tmp}/identity.p12" -k "${keychain}" -P "${p12_password}" \
  -T /usr/bin/codesign -A

security set-key-partition-list -S apple-tool:,apple:,codesign: -s "${keychain}" \
  >/dev/null 2>&1 || echo "    (skipped — codesign will ask once; choose Always Allow)"

echo "==> Trusting it for code signing"
echo "    macOS may ask for your login password. codesign refuses an untrusted"
echo "    certificate (CSSMERR_TP_NOT_TRUSTED)."
security add-trusted-cert -r trustRoot -p codeSign -k "${keychain}" "${tmp}/cert.pem"

echo "==> Verifying"
if ! security find-identity -v -p codesigning | grep -qF "\"${NAME}\""; then
  echo "error: certificate was created but is not valid for code signing" >&2
  echo "       open Keychain Access, find \"${NAME}\", and set Code Signing to Always Trust" >&2
  exit 1
fi
security find-identity -v -p codesigning | grep -F "\"${NAME}\"" || true

mkdir -p "${OUT_DIR}"
cp "${tmp}/identity.p12" "${OUT_DIR}/MacClippy.p12"
base64 < "${OUT_DIR}/MacClippy.p12" > "${OUT_DIR}/MacClippy.p12.base64"
printf '%s\n' "${p12_password}" > "${OUT_DIR}/password.txt"
chmod 600 "${OUT_DIR}/MacClippy.p12" "${OUT_DIR}/MacClippy.p12.base64" "${OUT_DIR}/password.txt"

cat <<EOF

Done. make dmg will reuse this identity.

If Accessibility or Input Monitoring still look granted but do not work, clear
the stale entries once:

  tccutil reset Accessibility com.macallyouneed.macclippy
  tccutil reset ListenEvent com.macallyouneed.macclippy

Then replace /Applications/MacClippy.app from a freshly signed DMG and grant
access again. Later updates that use this same certificate should keep it.

To let GitHub Actions sign releases with this same identity:

  gh secret set MACOS_CERT_P12 < ${OUT_DIR}/MacClippy.p12.base64
  gh secret set MACOS_CERT_PASSWORD --body '${p12_password}'

That password is also written to ${OUT_DIR}/password.txt. Without those two
secrets, CI builds an unsigned DMG and permissions will reset on each GitHub
update.
EOF

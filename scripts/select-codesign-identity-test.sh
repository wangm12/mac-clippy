#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="${ROOT}/scripts/select-codesign-identity.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${SELECTOR}" ]] || fail "missing executable ${SELECTOR}"

select_from() {
  printf '%s\n' "$1" | "${SELECTOR}"
}

developer_id='Developer ID Application: Example (ABCDE12345)'
apple_dev='Apple Development: someone@example.com (FGHIJ67890)'
self_sign='Mac Clippy'

read -r -d '' mixed <<'EOF' || true
  1) AAA111BBB222 "Apple Development: someone@example.com (FGHIJ67890)"
  2) CCC333DDD444 "Mac Clippy"
  3) EEE555FFF666 "Developer ID Application: Example (ABCDE12345)"
     3 valid identities found
EOF

got="$(select_from "${mixed}")"
[[ "${got}" == "${self_sign}" ]] || fail "expected self-signed identity, got: ${got}"

read -r -d '' without_self_sign <<'EOF' || true
  1) AAA111BBB222 "Apple Development: someone@example.com (FGHIJ67890)"
  2) CCC333DDD444 "Developer ID Application: Example (ABCDE12345)"
     2 valid identities found
EOF

got="$(select_from "${without_self_sign}")"
[[ "${got}" == "${developer_id}" ]] || fail "expected Developer ID, got: ${got}"

read -r -d '' without_developer <<'EOF' || true
  1) AAA111BBB222 "Apple Development: someone@example.com (FGHIJ67890)"
     1 valid identities found
EOF

got="$(select_from "${without_developer}")"
[[ "${got}" == "${apple_dev}" ]] || fail "expected Apple Development, got: ${got}"

read -r -d '' self_only <<'EOF' || true
  1) AAA111BBB222 "Mac Clippy"
     1 valid identities found
EOF

got="$(select_from "${self_only}")"
[[ "${got}" == "${self_sign}" ]] || fail "expected self-signed identity, got: ${got}"

read -r -d '' unrelated <<'EOF' || true
  1) AAA111BBB222 "Some Other App"
     1 valid identities found
EOF

got="$(select_from "${unrelated}")"
[[ -z "${got}" ]] || fail "expected empty selection for unrelated identity, got: ${got}"

got="$(select_from $'     0 valid identities found\n')"
[[ -z "${got}" ]] || fail "expected empty selection when no identities exist, got: ${got}"

echo "select-codesign-identity tests passed."

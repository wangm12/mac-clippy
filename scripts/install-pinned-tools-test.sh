#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-pinned-tools.sh"
VERSIONS="${ROOT}/scripts/pinned-tool-versions.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${INSTALLER}" ]] || fail "missing executable ${INSTALLER}"
[[ -f "${VERSIONS}" ]] || fail "missing ${VERSIONS}"

# shellcheck source=scripts/pinned-tool-versions.sh
source "${VERSIONS}"

work="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-pinned-tools-test.XXXXXX")"
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

make_xcodegen_zip() {
  local dest="$1"
  local with_share="${2:-1}"
  local root="${work}/xg-src"
  rm -rf "${root}"
  mkdir -p "${root}/xcodegen/bin"
  cat > "${root}/xcodegen/bin/xcodegen" <<EOF
#!/bin/sh
echo "Version: ${MACCLIPPY_XCODEGEN_VERSION}"
EOF
  chmod +x "${root}/xcodegen/bin/xcodegen"
  if [[ "${with_share}" == "1" ]]; then
    mkdir -p "${root}/xcodegen/share/xcodegen/SettingPresets"
    printf 'ok\n' > "${root}/xcodegen/share/xcodegen/SettingPresets/base.yml"
  fi
  rm -f "${dest}"
  (cd "${root}" && zip -q -r "${dest}" xcodegen)
}

make_swiftlint_zip() {
  local dest="$1"
  local root="${work}/sl-src"
  rm -rf "${root}"
  mkdir -p "${root}"
  cat > "${root}/swiftlint" <<EOF
#!/bin/sh
echo "${MACCLIPPY_SWIFTLINT_VERSION}"
EOF
  chmod +x "${root}/swiftlint"
  rm -f "${dest}"
  (cd "${root}" && zip -q -r "${dest}" swiftlint)
}

xg_zip="${work}/xcodegen.zip"
sl_zip="${work}/portable_swiftlint.zip"
make_xcodegen_zip "${xg_zip}" 1
make_swiftlint_zip "${sl_zip}"
xg_sha="$(shasum -a 256 "${xg_zip}" | awk '{ print $1 }')"
sl_sha="$(shasum -a 256 "${sl_zip}" | awk '{ print $1 }')"

run_installer() {
  MACCLIPPY_XCODEGEN_URL="file://${xg_zip}" \
    MACCLIPPY_XCODEGEN_SHA256="${xg_sha}" \
    MACCLIPPY_SWIFTLINT_URL="file://${sl_zip}" \
    MACCLIPPY_SWIFTLINT_SHA256="${sl_sha}" \
    MACCLIPPY_TOOLS_PREFIX="$1" \
    "${INSTALLER}"
}

prefix="${work}/ok"
output="$(run_installer "${prefix}")"
[[ -x "${prefix}/bin/xcodegen" ]] || fail "expected xcodegen in ${prefix}/bin"
[[ -x "${prefix}/bin/swiftlint" ]] || fail "expected swiftlint in ${prefix}/bin"
[[ -d "${prefix}/share/xcodegen" ]] || fail "expected share/xcodegen next to the binary"
[[ "${output}" == *"Tool versions passed: XcodeGen ${MACCLIPPY_XCODEGEN_VERSION}, SwiftLint ${MACCLIPPY_SWIFTLINT_VERSION}"* ]] \
  || fail "expected verify-tool-versions success, got: ${output}"

if MACCLIPPY_XCODEGEN_URL="file://${xg_zip}" \
  MACCLIPPY_XCODEGEN_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
  MACCLIPPY_SWIFTLINT_URL="file://${sl_zip}" \
  MACCLIPPY_SWIFTLINT_SHA256="${sl_sha}" \
  MACCLIPPY_TOOLS_PREFIX="${work}/bad-sha" \
  "${INSTALLER}" >"${work}/bad-sha.out" 2>"${work}/bad-sha.err"; then
  fail "expected checksum mismatch to fail"
fi
grep -q "checksum mismatch" "${work}/bad-sha.err" || fail "expected checksum mismatch error"

make_xcodegen_zip "${xg_zip}" 0
xg_sha="$(shasum -a 256 "${xg_zip}" | awk '{ print $1 }')"
if MACCLIPPY_XCODEGEN_URL="file://${xg_zip}" \
  MACCLIPPY_XCODEGEN_SHA256="${xg_sha}" \
  MACCLIPPY_SWIFTLINT_URL="file://${sl_zip}" \
  MACCLIPPY_SWIFTLINT_SHA256="${sl_sha}" \
  MACCLIPPY_TOOLS_PREFIX="${work}/no-share" \
  "${INSTALLER}" >"${work}/no-share.out" 2>"${work}/no-share.err"; then
  fail "expected missing SettingPresets to fail"
fi
grep -q "share/xcodegen" "${work}/no-share.err" || fail "expected missing share/xcodegen error"

if bash "${VERSIONS}" >"${work}/sourced.out" 2>"${work}/sourced.err"; then
  fail "expected pinned-tool-versions.sh to refuse direct execution"
fi
grep -q "source" "${work}/sourced.err" || fail "expected source-only error"

echo "install-pinned-tools tests passed"

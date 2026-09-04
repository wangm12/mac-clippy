#!/usr/bin/env bash

# Install the XcodeGen and SwiftLint versions this repo generates and lints
# with. GitHub-hosted runners float Homebrew formulae, so CI must not use
# `brew install xcodegen` / `brew install swiftlint`.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pinned-tool-versions.sh
source "${script_dir}/pinned-tool-versions.sh"

prefix="${MACCLIPPY_TOOLS_PREFIX:-}"
if [[ -z "${prefix}" ]]; then
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        prefix="${RUNNER_TEMP}/macclippy-tools"
    else
        prefix="${TMPDIR:-/tmp}/macclippy-tools"
    fi
fi
mkdir -p "${prefix}"
prefix="$(cd "${prefix}" && pwd)"

bin_dir="${prefix}/bin"
share_dir="${prefix}/share"
mkdir -p "${bin_dir}" "${share_dir}"

work="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-tools-extract.XXXXXX")"
cleanup() {
    rm -rf "${work}"
}
trap cleanup EXIT

download_verified() {
    local url="$1"
    local dest="$2"
    local expected="$3"
    local label="$4"
    local actual

    curl -fsSL -o "${dest}" "${url}"
    actual="$(shasum -a 256 "${dest}" | awk '{ print $1 }')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "error: ${label} checksum mismatch" >&2
        echo "       url      ${url}" >&2
        echo "       expected ${expected}" >&2
        echo "       actual   ${actual}" >&2
        exit 1
    fi
}

xg_zip="${work}/xcodegen.zip"
download_verified \
    "${MACCLIPPY_XCODEGEN_URL}" \
    "${xg_zip}" \
    "${MACCLIPPY_XCODEGEN_SHA256}" \
    "XcodeGen ${MACCLIPPY_XCODEGEN_VERSION}"
unzip -q "${xg_zip}" -d "${work}/xcodegen-dist"
xg_root="${work}/xcodegen-dist/xcodegen"
if [[ ! -x "${xg_root}/bin/xcodegen" ]]; then
    echo "error: XcodeGen archive missing bin/xcodegen" >&2
    exit 1
fi
if [[ ! -d "${xg_root}/share/xcodegen" ]]; then
    echo "error: XcodeGen archive missing share/xcodegen (SettingPresets)" >&2
    exit 1
fi
install -m 755 "${xg_root}/bin/xcodegen" "${bin_dir}/xcodegen"
rm -rf "${share_dir}/xcodegen"
cp -R "${xg_root}/share/xcodegen" "${share_dir}/xcodegen"

sl_zip="${work}/portable_swiftlint.zip"
download_verified \
    "${MACCLIPPY_SWIFTLINT_URL}" \
    "${sl_zip}" \
    "${MACCLIPPY_SWIFTLINT_SHA256}" \
    "SwiftLint ${MACCLIPPY_SWIFTLINT_VERSION}"
unzip -q "${sl_zip}" -d "${work}/swiftlint-dist"
sl_bin="${work}/swiftlint-dist/swiftlint"
if [[ ! -f "${sl_bin}" ]]; then
    echo "error: SwiftLint archive missing swiftlint" >&2
    exit 1
fi
install -m 755 "${sl_bin}" "${bin_dir}/swiftlint"

if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "${bin_dir}/xcodegen" "${bin_dir}/swiftlint" >/dev/null 2>&1 || true
fi

export PATH="${bin_dir}:${PATH}"
if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${bin_dir}" >> "${GITHUB_PATH}"
fi

echo "Installed pinned tools into ${bin_dir}"
"${script_dir}/verify-tool-versions.sh"

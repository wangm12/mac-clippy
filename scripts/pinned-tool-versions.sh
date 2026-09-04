# Sourced by install-pinned-tools.sh and verify-tool-versions.sh.
# Bump version and sha256 together. Checksums are sha256 of the official
# GitHub release zip, not the extracted binary:
#   shasum -a 256 xcodegen.zip portable_swiftlint.zip

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "error: source ${BASH_SOURCE[0]} instead of executing it" >&2
    exit 2
fi

: "${MACCLIPPY_XCODEGEN_VERSION:=2.45.4}"
: "${MACCLIPPY_XCODEGEN_SHA256:=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef}"
: "${MACCLIPPY_XCODEGEN_URL:=https://github.com/yonaskolb/XcodeGen/releases/download/${MACCLIPPY_XCODEGEN_VERSION}/xcodegen.zip}"

: "${MACCLIPPY_SWIFTLINT_VERSION:=0.63.2}"
: "${MACCLIPPY_SWIFTLINT_SHA256:=c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29}"
: "${MACCLIPPY_SWIFTLINT_URL:=https://github.com/realm/SwiftLint/releases/download/${MACCLIPPY_SWIFTLINT_VERSION}/portable_swiftlint.zip}"

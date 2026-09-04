#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pinned-tool-versions.sh
source "${script_dir}/pinned-tool-versions.sh"

expected_xcodegen="${MACCLIPPY_XCODEGEN_VERSION}"
expected_swiftlint="${MACCLIPPY_SWIFTLINT_VERSION}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required" >&2
    exit 1
fi
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint is required" >&2
    exit 1
fi

actual_xcodegen="$(xcodegen --version | awk '/Version:/ { print $2; exit }')"
actual_swiftlint="$(swiftlint version | head -n 1 | tr -d '[:space:]')"

if [[ "${actual_xcodegen}" != "${expected_xcodegen}" ]]; then
    echo "error: expected XcodeGen ${expected_xcodegen}, found ${actual_xcodegen}" >&2
    exit 1
fi
if [[ "${actual_swiftlint}" != "${expected_swiftlint}" ]]; then
    echo "error: expected SwiftLint ${expected_swiftlint}, found ${actual_swiftlint}" >&2
    exit 1
fi

echo "Tool versions passed: XcodeGen ${actual_xcodegen}, SwiftLint ${actual_swiftlint}"

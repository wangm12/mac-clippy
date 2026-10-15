#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-make-pinned-tools-test.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${WORK}/pinned/bin" "${WORK}/homebrew"
cat > "${WORK}/pinned/bin/xcodegen" <<'PINNED_XCODEGEN'
#!/usr/bin/env sh
echo "Version: 2.45.4"
PINNED_XCODEGEN
cat > "${WORK}/pinned/bin/swiftlint" <<'PINNED_SWIFTLINT'
#!/usr/bin/env sh
echo "0.63.2"
PINNED_SWIFTLINT
cat > "${WORK}/homebrew/xcodegen" <<'HOMEBREW_XCODEGEN'
#!/usr/bin/env sh
echo "Version: 2.46.0"
HOMEBREW_XCODEGEN
cat > "${WORK}/homebrew/swiftlint" <<'HOMEBREW_SWIFTLINT'
#!/usr/bin/env sh
echo "0.65.0"
HOMEBREW_SWIFTLINT
chmod +x "${WORK}/pinned/bin/xcodegen" "${WORK}/pinned/bin/swiftlint" \
  "${WORK}/homebrew/xcodegen" "${WORK}/homebrew/swiftlint"

MACCLIPPY_TOOLS_PREFIX="${WORK}/pinned" \
PATH="${WORK}/homebrew:/usr/bin:/bin:/usr/sbin:/sbin" \
  make --no-print-directory --silent -f "${ROOT}/Makefile" verify-pinned-tools

echo "Make selected pinned tool versions ahead of Homebrew tools"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/package-dmg.sh"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
SANDBOX="$(mktemp -d "${TEMP_BASE}/macclippy-package-path-test.XXXXXX")"
SANDBOX_MARKER="$SANDBOX/.macclippy-package-test-root"
printf 'macclippy-package-path-test\n' > "$SANDBOX_MARKER"

cleanup() {
  if [[ -f "$SANDBOX_MARKER" && "$SANDBOX" == "${TEMP_BASE}"/macclippy-package-path-test.* ]]; then
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

REPO="$SANDBOX/mini repository"
STUBS="$SANDBOX/stubs"
COMMAND_LOG="$SANDBOX/commands.log"
mkdir -p "$REPO/scripts" "$REPO/build" "$REPO/.build" "$REPO/dist" "$STUBS" "$SANDBOX/outside/deep"
mkdir -p "$REPO/.build/temporary"
cp "$SCRIPT_SOURCE" "$REPO/scripts/package-dmg.sh"
printf 'miniature disposable repo\n' > "$REPO/.macclippy-package-test-root"
printf 'keep this build-root content\n' > "$REPO/.build/keep.marker"
printf 'keep this outside content\n' > "$SANDBOX/outside/keep.marker"
cat > "$REPO/scripts/verify-build-metadata.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "$1" ]]
SH
chmod +x "$REPO/scripts/verify-build-metadata.sh"

cat > "$STUBS/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodegen %s\n' "$*" >> "$PACKAGE_TEST_COMMAND_LOG"
SH
cat > "$STUBS/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >> "$PACKAGE_TEST_COMMAND_LOG"
derived=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-derivedDataPath" ]]; then derived="$argument"; fi
  previous="$argument"
done
[[ -n "$derived" ]]
mkdir -p "$derived/Build/Products/Release/MacClippy.app"
SH
cat > "$STUBS/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "$PACKAGE_TEST_COMMAND_LOG"
destination="${!#}"
mkdir -p "$(dirname "$destination")"
: > "$destination"
SH
cat > "$STUBS/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "$PACKAGE_TEST_COMMAND_LOG"
destination="${!#}"
mkdir -p "$(dirname "$destination")"
: > "$destination"
SH
cat > "$STUBS/shasum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'shasum %s\n' "$*" >> "$PACKAGE_TEST_COMMAND_LOG"
printf 'stub-checksum  %s\n' "${@: -1}"
SH
chmod +x "$STUBS"/*

run_packager() {
  local staging_dir="$1"
  env PATH="$STUBS:$PATH" PACKAGE_TEST_COMMAND_LOG="$COMMAND_LOG" STAGING_DIR="$staging_dir" \
    "$REPO/scripts/package-dmg.sh"
}

expect_rejected_before_packaging() {
  local label="$1"
  local staging="$2"
  : > "$COMMAND_LOG"
  if run_packager "$staging"; then
    echo "FAIL: ${label} was accepted" >&2
    exit 1
  fi
  if [[ -s "$COMMAND_LOG" ]]; then
    echo "FAIL: ${label} reached build or package commands" >&2
    cat "$COMMAND_LOG" >&2
    exit 1
  fi
  if [[ "$(cat "$REPO/.build/keep.marker")" != 'keep this build-root content' ]]; then
    echo "FAIL: ${label} changed the build-root marker" >&2
    exit 1
  fi
  echo "PASS: ${label} rejected before any build/package command"
}

expect_rejected_before_packaging "exact .build root with trailing slash" "$REPO/.build///"
expect_rejected_before_packaging "normalized path to exact .build root" "$REPO/.build/child/../"
expect_rejected_before_packaging "nonexistent normalized path to exact .build root" "$REPO/.build/not-created/../"

ln -s "$SANDBOX/outside/deep" "$REPO/.build/escape"
expect_rejected_before_packaging "nonexisting child beneath symlink escape" "$REPO/.build/escape/new-stage"
ln -s "$SANDBOX/outside/deep" "$REPO/.build/existing-escape"
expect_rejected_before_packaging "existing staging symlink escape" "$REPO/.build/existing-escape"
expect_rejected_before_packaging "symlink-aware parent component escape" "$REPO/.build/escape/../new-stage"

: > "$COMMAND_LOG"
NORMAL_STAGING="$REPO/.build/temporary/../dedicated-staging/./"
run_packager "$NORMAL_STAGING"
if [[ ! -f "$REPO/dist/MacClippy.dmg" || ! -f "$REPO/dist/MacClippy.zip" || ! -f "$REPO/dist/MacClippy-SHA256SUMS.txt" ]]; then
  echo "FAIL: normal dedicated staging did not produce the stub artifacts" >&2
  exit 1
fi
for command_name in xcodegen xcodebuild hdiutil ditto shasum; do
  if ! rg -q "^${command_name} " "$COMMAND_LOG"; then
    echo "FAIL: normal packaging did not reach stub ${command_name}" >&2
    cat "$COMMAND_LOG" >&2
    exit 1
  fi
done
if [[ -e "$REPO/.build/dedicated-staging" ]]; then
  echo "FAIL: normal packaging left its disposable staging directory" >&2
  exit 1
fi
if [[ "$(cat "$SANDBOX/outside/keep.marker")" != 'keep this outside content' ]]; then
  echo "FAIL: symlink rejection changed the outside marker" >&2
  exit 1
fi
echo "PASS: normalized dedicated child completed the copied script through stubbed packaging"
echo "PASS: outside symlink target remained intact"

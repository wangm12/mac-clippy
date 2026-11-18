#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cleaner="${root}/scripts/clean-build.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-clean-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

fixture="${work}/repo"
mkdir -p \
  "${fixture}/MacClippyKit" \
  "${fixture}/.build/cache" \
  "${fixture}/.swiftpm/config" \
  "${fixture}/MacClippyKit/.build/cache" \
  "${fixture}/MacClippyKit/.swiftpm/config" \
  "${fixture}/MacClippyKit/build/cache" \
  "${fixture}/build/archives" \
  "${fixture}/build/derived-data" \
  "${fixture}/build/test-results" \
  "${fixture}/build/hardening-phase6/generation-12" \
  "${fixture}/dist"
touch "${fixture}/Makefile" "${fixture}/MacClippyKit/Package.swift"
touch \
  "${fixture}/.build/cache/object" \
  "${fixture}/.swiftpm/config/state" \
  "${fixture}/MacClippyKit/.build/cache/object" \
  "${fixture}/MacClippyKit/.swiftpm/config/state" \
  "${fixture}/MacClippyKit/build/cache/object" \
  "${fixture}/build/archives/app.xcarchive" \
  "${fixture}/build/derived-data/object" \
  "${fixture}/build/test-results/tests.xcresult" \
  "${fixture}/build/hardening-phase6/generation-12/review.md" \
  "${fixture}/dist/MacClippy.dmg"

ROOT_DIR="$fixture" "$cleaner" >/dev/null

for path in \
  "${fixture}/.build" \
  "${fixture}/.swiftpm" \
  "${fixture}/MacClippyKit/.build" \
  "${fixture}/MacClippyKit/.swiftpm" \
  "${fixture}/MacClippyKit/build" \
  "${fixture}/build/archives" \
  "${fixture}/build/derived-data" \
  "${fixture}/build/test-results"; do
  [[ ! -e "$path" ]] || fail "expected generated output to be removed: $path"
done

[[ -f "${fixture}/build/hardening-phase6/generation-12/review.md" ]] \
  || fail "clean removed review evidence"
[[ -f "${fixture}/dist/MacClippy.dmg" ]] || fail "clean removed the distribution package"

unsafe_fixture="${work}/unsafe-repo"
external="${work}/external"
mkdir -p "${unsafe_fixture}/MacClippyKit" "${unsafe_fixture}/.swiftpm" "$external"
touch "${unsafe_fixture}/Makefile" "${unsafe_fixture}/MacClippyKit/Package.swift"
touch "${unsafe_fixture}/.swiftpm/keep" "${external}/keep"
ln -s "$external" "${unsafe_fixture}/.build"

if ROOT_DIR="$unsafe_fixture" "$cleaner" >"${work}/unsafe.out" 2>"${work}/unsafe.err"; then
  fail "expected clean to reject a symlinked build directory"
fi
grep -q "refusing to clean through a symlink" "${work}/unsafe.err" \
  || fail "expected a clear symlink rejection"
[[ -f "${unsafe_fixture}/.swiftpm/keep" ]] || fail "unsafe clean partially removed repository data"
[[ -f "${external}/keep" ]] || fail "unsafe clean touched the symlink target"

echo "clean-build tests passed"

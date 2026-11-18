#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
default_root="$(cd -- "${script_dir}/.." && pwd -P)"
root_dir="${ROOT_DIR:-$default_root}"

fail() {
  echo "error: $*" >&2
  exit 2
}

[[ -d "$root_dir" ]] || fail "repository root does not exist: $root_dir"
root_dir="$(cd -P -- "$root_dir" && pwd -P)"
[[ -f "$root_dir/Makefile" ]] || fail "not a MacClippy repository root: $root_dir"
[[ -f "$root_dir/MacClippyKit/Package.swift" ]] || fail "missing MacClippyKit/Package.swift under $root_dir"

targets=(
  "$root_dir/.build"
  "$root_dir/.swiftpm"
  "$root_dir/MacClippyKit/.build"
  "$root_dir/MacClippyKit/.swiftpm"
  "$root_dir/MacClippyKit/build"
  "$root_dir/build/archives"
  "$root_dir/build/derived-data"
  "$root_dir/build/test-results"
)

validate_target() {
  local target="$1"
  local relative probe component ancestor resolved_ancestor
  local -a components

  case "$target" in
    "$root_dir"/*) ;;
    *) fail "refusing to clean a path outside the repository: $target" ;;
  esac

  relative="${target#"$root_dir"/}"
  probe="$root_dir"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    probe="$probe/$component"
    [[ ! -L "$probe" ]] || fail "refusing to clean through a symlink: $probe"
  done

  if [[ -e "$target" && ! -d "$target" ]]; then
    fail "refusing to remove a non-directory build path: $target"
  fi

  ancestor="$target"
  while [[ ! -d "$ancestor" ]]; do
    ancestor="${ancestor%/*}"
    [[ -n "$ancestor" ]] || ancestor="/"
  done
  resolved_ancestor="$(cd -P -- "$ancestor" && pwd -P)"
  case "$resolved_ancestor" in
    "$root_dir"|"${root_dir}/"*) ;;
    *) fail "refusing to clean through a path outside the repository: $target" ;;
  esac
}

# Validate every path before deleting any of them, so one unsafe path cannot
# leave a partially cleaned workspace.
for target in "${targets[@]}"; do
  validate_target "$target"
done

for target in "${targets[@]}"; do
  if [[ -e "$target" ]]; then
    rm -rf -- "$target"
    printf 'removed %s\n' "${target#"$root_dir"/}"
  fi
done

echo "Preserved dist/ and build review evidence."

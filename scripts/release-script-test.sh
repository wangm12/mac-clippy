#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/release.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-release-script-test.XXXXXX")"
SHA="0123456789abcdef0123456789abcdef01234567"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GIT_MOCK_LOG}"
if [[ "${1:-}" == "status" ]]; then
  if [[ "${GIT_MOCK_DIRTY:-0}" == "1" ]]; then
    printf '?? untracked-test-file\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "symbolic-ref" && "${2:-}" == "--short" ]]; then
  printf '%s\n' "${GIT_MOCK_BRANCH:-main}"
  exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "HEAD" ]]; then
  printf '%s\n' "${GIT_MOCK_SHA}"
  exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "origin/main" ]]; then
  printf '%s\n' "${GIT_MOCK_SHA}"
  exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "-q" ]]; then
  exit 1
fi
if [[ "${1:-}" == "ls-remote" ]]; then
  if [[ "${GIT_MOCK_REMOTE_TAG_EXISTS:-0}" == "1" ]]; then
    printf '%s\t%s\n' "${GIT_MOCK_SHA}" "${3#refs/tags/}"
  fi
  exit 0
fi
if [[ "${1:-}" == "config" ]]; then
  printf '%s\n' 'https://github.com/example/mac-clippy.git'
  exit 0
fi
exit 0
MOCK_GIT
chmod +x "${WORK}/bin/git"

base_env=(
  "GIT_MOCK_LOG=${WORK}/git.log"
  "GIT_MOCK_SHA=${SHA}"
  "PATH=${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
)

env "${base_env[@]}" "${SCRIPT}" 1.2.3 >"${WORK}/success.out"
grep -q '^tag -a v1.2.3 ' "${WORK}/git.log"
grep -q '^push origin v1.2.3$' "${WORK}/git.log"

: > "${WORK}/git.log"
if env "${base_env[@]}" "${SCRIPT}" 1.2.3-rc.1 >"${WORK}/invalid.out" 2>"${WORK}/invalid.err"; then
  echo "error: release helper accepted a prerelease tag" >&2
  exit 1
fi
grep -q 'invalid stable version' "${WORK}/invalid.err"
! grep -q '^tag -a ' "${WORK}/git.log"
! grep -q '^push ' "${WORK}/git.log"

: > "${WORK}/git.log"
if env "${base_env[@]}" GIT_MOCK_DIRTY=1 "${SCRIPT}" 1.2.3 >"${WORK}/dirty.out" 2>"${WORK}/dirty.err"; then
  echo "error: release helper accepted an untracked file" >&2
  exit 1
fi
grep -q 'uncommitted or untracked changes' "${WORK}/dirty.err"
! grep -q '^fetch ' "${WORK}/git.log"
! grep -q '^push ' "${WORK}/git.log"

: > "${WORK}/git.log"
if env "${base_env[@]}" GIT_MOCK_BRANCH=feature "${SCRIPT}" 1.2.3 >"${WORK}/branch.out" 2>"${WORK}/branch.err"; then
  echo "error: release helper accepted a non-main branch" >&2
  exit 1
fi
grep -q "releases must be cut from the 'main' branch" "${WORK}/branch.err"
! grep -q '^fetch ' "${WORK}/git.log"

"${ROOT}/scripts/retarget-nightly-tag-test.sh"

echo "release-script tests passed (all git mutations were mocked)"

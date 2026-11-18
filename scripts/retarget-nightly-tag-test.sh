#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/retarget-nightly-tag.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-nightly-tag-test.XXXXXX")"
SHA="0123456789abcdef0123456789abcdef01234567"
OLD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${GIT_MOCK_LOG}"
printf '\n' >>"${GIT_MOCK_LOG}"

case "${1:-}" in
  check-ref-format)
    [[ "${2:-}" == "refs/tags/nightly" && "${GIT_MOCK_BAD_REF:-0}" != "1" ]]
    ;;
  rev-parse)
    [[ "${2:-}" == "--verify" ]] || exit 2
    if [[ "${3:-}" == "HEAD" ]]; then
      printf '%s\n' "${GIT_MOCK_HEAD_SHA}"
    elif [[ "${3:-}" == "${GIT_MOCK_SOURCE_SHA}^{commit}" && "${GIT_MOCK_COMMIT_EXISTS:-1}" == "1" ]]; then
      printf '%s\n' "${GIT_MOCK_SOURCE_SHA}"
    else
      exit 1
    fi
    ;;
  ls-remote)
    [[ "${GIT_MOCK_LS_REMOTE_FAILURE:-0}" != "1" ]] || exit 3
    [[ "${2:-}" == "--refs" && "${3:-}" == "origin" && "${4:-}" == "refs/tags/nightly" ]] || exit 2
    if [[ -n "${GIT_MOCK_REMOTE_SHA:-}" ]]; then
      printf '%s\trefs/tags/nightly\n' "${GIT_MOCK_REMOTE_SHA}"
    fi
    ;;
  push)
    [[ "${GIT_MOCK_PUSH_FAILURE:-0}" != "1" ]] || exit 4
    ;;
  *)
    echo "unexpected git command: $*" >&2
    exit 2
    ;;
esac
MOCK_GIT
chmod +x "${WORK}/bin/git"

run_update() {
  local label="$1"
  shift
  : >"${WORK}/${label}.git.log"
  if ! env \
      GIT_MOCK_LOG="${WORK}/${label}.git.log" \
      GIT_MOCK_HEAD_SHA="${SHA}" \
      GIT_MOCK_SOURCE_SHA="${SHA}" \
      PATH="${WORK}/bin:/usr/bin:/bin" \
      "$@" "${SCRIPT}" "${SHA}" >"${WORK}/${label}.out" 2>"${WORK}/${label}.err"; then
    echo "error: nightly-tag test '${label}' unexpectedly failed" >&2
    cat "${WORK}/${label}.out" "${WORK}/${label}.err" >&2
    exit 1
  fi
}

run_rejects() {
  local label="$1"
  shift
  : >"${WORK}/${label}.git.log"
  if env \
      GIT_MOCK_LOG="${WORK}/${label}.git.log" \
      GIT_MOCK_HEAD_SHA="${SHA}" \
      GIT_MOCK_SOURCE_SHA="${SHA}" \
      PATH="${WORK}/bin:/usr/bin:/bin" \
      "$@" "${SCRIPT}" "${SHA}" >"${WORK}/${label}.out" 2>"${WORK}/${label}.err"; then
    echo "error: nightly-tag test '${label}' unexpectedly passed" >&2
    cat "${WORK}/${label}.out" >&2
    exit 1
  fi
}

# First publication creates exactly refs/tags/nightly without force.
run_update first_creation GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}"
grep -Fqx "push origin ${SHA}:refs/tags/nightly " "${WORK}/first_creation.git.log"
! grep -Fq 'refs/tags/v' "${WORK}/first_creation.git.log"

# A later main SHA retargets only the rolling ref with an explicit old-value lease.
env GIT_MOCK_LOG="${WORK}/repeat_publication.git.log" \
  GIT_MOCK_HEAD_SHA="${SHA}" GIT_MOCK_SOURCE_SHA="${SHA}" \
  GIT_MOCK_REMOTE_SHA="${OLD_SHA}" PATH="${WORK}/bin:/usr/bin:/bin" \
  GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" \
  "${SCRIPT}" "${SHA}" >"${WORK}/repeat_publication.out"
grep -Fqx "push --force-with-lease=refs/tags/nightly:${OLD_SHA} origin ${SHA}:refs/tags/nightly " "${WORK}/repeat_publication.git.log"
! grep -Fq 'refs/tags/v' "${WORK}/repeat_publication.git.log"

# Repeating the same SHA is idempotent and does not issue any push.
env GIT_MOCK_LOG="${WORK}/already_current.git.log" \
  GIT_MOCK_HEAD_SHA="${SHA}" GIT_MOCK_SOURCE_SHA="${SHA}" \
  GIT_MOCK_REMOTE_SHA="${SHA}" PATH="${WORK}/bin:/usr/bin:/bin" \
  GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" \
  "${SCRIPT}" "${SHA}" >"${WORK}/already_current.out"
! grep -Fq 'push ' "${WORK}/already_current.git.log"

# Non-main refs, invalid SHA values, and source mismatches cannot mutate refs.
run_rejects invalid_ref GITHUB_REF=refs/heads/release GITHUB_SHA="${SHA}"
! grep -Fq 'push ' "${WORK}/invalid_ref.git.log"
run_rejects stable_tag_event GITHUB_REF=refs/tags/v1.2.3 GITHUB_SHA="${SHA}"
! grep -Fq 'push ' "${WORK}/stable_tag_event.git.log"
: >"${WORK}/invalid_source.git.log"
if GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" \
    GIT_MOCK_LOG="${WORK}/invalid_source.git.log" \
    PATH="${WORK}/bin:/usr/bin:/bin" "${SCRIPT}" invalid \
    >"${WORK}/invalid_source.out" 2>"${WORK}/invalid_source.err"; then
  echo "error: nightly-tag updater accepted an invalid SHA" >&2
  exit 1
fi
! grep -Fq 'push ' "${WORK}/invalid_source.git.log"
: >"${WORK}/mismatched_source.git.log"
if GIT_MOCK_LOG="${WORK}/mismatched_source.git.log" \
    GIT_MOCK_HEAD_SHA="${SHA}" GIT_MOCK_SOURCE_SHA="${SHA}" \
    PATH="${WORK}/bin:/usr/bin:/bin" GITHUB_REF=refs/heads/main \
    GITHUB_SHA="${OLD_SHA}" "${SCRIPT}" "${SHA}" \
    >"${WORK}/mismatched_source.out" 2>"${WORK}/mismatched_source.err"; then
  echo "error: nightly-tag updater accepted a source SHA different from GITHUB_SHA" >&2
  exit 1
fi
! grep -Fq 'push ' "${WORK}/mismatched_source.git.log"
run_rejects unknown_commit GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" GIT_MOCK_COMMIT_EXISTS=0
! grep -Fq 'push ' "${WORK}/unknown_commit.git.log"

# A remote lookup or push failure fails the release step closed.
run_rejects remote_lookup_failure GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" GIT_MOCK_LS_REMOTE_FAILURE=1
run_rejects push_failure GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" GIT_MOCK_REMOTE_SHA="${OLD_SHA}" GIT_MOCK_PUSH_FAILURE=1
grep -Fq -- "--force-with-lease=refs/tags/nightly:${OLD_SHA}" "${WORK}/push_failure.git.log"

echo "retarget-nightly-tag tests passed (all Git mutations were mocked)"

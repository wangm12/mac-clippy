#!/usr/bin/env bash
set -euo pipefail

NIGHTLY_REF="refs/tags/nightly"
SOURCE_SHA="${1:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$#" -eq 1 ]] || fail "expected the full source SHA as the only argument"
[[ "${GITHUB_REF:-}" == "refs/heads/main" ]] \
  || fail "the nightly tag can be updated only by a push to refs/heads/main"
[[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] \
  || fail "expected a full lowercase 40-character source SHA"
if [[ -n "${GITHUB_SHA:-}" && "${GITHUB_SHA}" != "${SOURCE_SHA}" ]]; then
  fail "requested source SHA does not match GITHUB_SHA"
fi

git check-ref-format "${NIGHTLY_REF}" \
  || fail "invalid fixed nightly ref ${NIGHTLY_REF}"

checkout_sha="$(git rev-parse --verify HEAD)" \
  || fail "could not resolve the checked-out source commit"
[[ "${checkout_sha}" == "${SOURCE_SHA}" ]] \
  || fail "checkout ${checkout_sha} does not match source SHA ${SOURCE_SHA}"

resolved_sha="$(git rev-parse --verify "${SOURCE_SHA}^{commit}")" \
  || fail "source SHA does not resolve to a commit"
[[ "${resolved_sha}" == "${SOURCE_SHA}" ]] \
  || fail "source SHA resolved to unexpected commit ${resolved_sha}"

remote_refs="$(git ls-remote --refs origin "${NIGHTLY_REF}")" \
  || fail "could not read the remote nightly tag ref"
if [[ -z "${remote_refs}" ]]; then
  # First creation is a normal push. If another writer creates the ref after
  # ls-remote, Git rejects this instead of overwriting it.
  git push origin "${SOURCE_SHA}:${NIGHTLY_REF}"
  echo "Created ${NIGHTLY_REF} at ${SOURCE_SHA}."
  exit 0
fi

line_count="$(printf '%s\n' "${remote_refs}" | awk 'END { print NR }')"
[[ "${line_count}" == "1" ]] \
  || fail "remote returned an ambiguous value for ${NIGHTLY_REF}"
read -r remote_sha remote_ref <<<"${remote_refs}"
[[ "${remote_ref}" == "${NIGHTLY_REF}" ]] \
  || fail "remote returned unexpected ref ${remote_ref:-missing}"
[[ "${remote_sha}" =~ ^[0-9a-f]{40}$ ]] \
  || fail "remote nightly ref did not resolve to a full Git object ID"

if [[ "${remote_sha}" == "${SOURCE_SHA}" ]]; then
  echo "${NIGHTLY_REF} already points to ${SOURCE_SHA}."
  exit 0
fi

# The explicit lease allows only this rolling tag to move, and only if its
# current remote object ID still matches the value observed above.
git push "--force-with-lease=${NIGHTLY_REF}:${remote_sha}" \
  origin "${SOURCE_SHA}:${NIGHTLY_REF}"
echo "Moved ${NIGHTLY_REF} from ${remote_sha} to ${SOURCE_SHA}."

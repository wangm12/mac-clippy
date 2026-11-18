#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/select-release-version.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-release-version-test.XXXXXX")"
SHA="abcdef0123456789abcdef0123456789abcdef01"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

GITHUB_REF=refs/heads/main GITHUB_SHA="${SHA}" GITHUB_RUN_NUMBER=23 \
  GITHUB_OUTPUT="${WORK}/nightly.out" "${SCRIPT}"
grep -qx 'marketing_version=0.0.0' "${WORK}/nightly.out"
grep -qx 'build_version=1126.93.75' "${WORK}/nightly.out"
grep -qx 'artifact_name=MacClippy-nightly-abcdef01' "${WORK}/nightly.out"
grep -qx 'release_kind=nightly' "${WORK}/nightly.out"
grep -qx "source_sha=${SHA}" "${WORK}/nightly.out"

GITHUB_REF=refs/tags/v1.2.3 GITHUB_SHA="${SHA}" GITHUB_RUN_NUMBER=24 \
  GITHUB_OUTPUT="${WORK}/stable.out" "${SCRIPT}"
grep -qx 'marketing_version=1.2.3' "${WORK}/stable.out"
grep -qx 'build_version=1.0.23' "${WORK}/stable.out"
grep -qx 'artifact_name=MacClippy-1.2.3' "${WORK}/stable.out"
grep -qx 'release_kind=stable' "${WORK}/stable.out"

if GITHUB_REF=refs/heads/feature GITHUB_SHA="${SHA}" GITHUB_RUN_NUMBER=25 \
    GITHUB_OUTPUT="${WORK}/feature.out" "${SCRIPT}" >"${WORK}/feature.stdout" 2>"${WORK}/feature.stderr"; then
  echo "error: version selector allowed a nightly from a non-main branch" >&2
  exit 1
fi
grep -q 'only from refs/heads/main' "${WORK}/feature.stderr"

if GITHUB_REF=refs/tags/v1.2.3-rc.1 GITHUB_SHA="${SHA}" GITHUB_RUN_NUMBER=26 \
    GITHUB_OUTPUT="${WORK}/prerelease.out" "${SCRIPT}" >"${WORK}/prerelease.stdout" 2>"${WORK}/prerelease.stderr"; then
  echo "error: version selector allowed a non-stable tag" >&2
  exit 1
fi
grep -q 'stable tags must use vX.Y.Z' "${WORK}/prerelease.stderr"

echo "select-release-version tests passed"

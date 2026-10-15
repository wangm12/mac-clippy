#!/usr/bin/env bash
set -euo pipefail

EVENT_REF="${GITHUB_REF:-}"
SOURCE_SHA="${GITHUB_SHA:-}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "${SOURCE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]] || fail "GITHUB_SHA must be a full 40-character source SHA"

if [[ "${EVENT_REF}" == refs/tags/* ]]; then
  tag="${EVENT_REF#refs/tags/}"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "stable tags must use vX.Y.Z"
  version="${tag#v}"
  [[ "${RUN_NUMBER}" =~ ^[1-9][0-9]*$ ]] || fail "GITHUB_RUN_NUMBER must be a positive integer"
  run_value=$((10#${RUN_NUMBER} - 1))
  build_major=$((run_value / 10000 + 1))
  build_minor=$((run_value / 100 % 100))
  build_patch=$((run_value % 100))
  build_version="${build_major}.${build_minor}.${build_patch}"
  artifact_name="MacClippy-${version}"
  release_kind="stable"
  volume_name="Mac Clippy ${version}"
elif [[ "${EVENT_REF}" == refs/heads/main ]]; then
  version="0.0.0"
  short_sha="${SOURCE_SHA:0:8}"
  hash_prefix="${SOURCE_SHA:0:6}"
  hash_value=$((16#${hash_prefix}))
  build_major=$((hash_value / 10000 + 1))
  build_minor=$((hash_value / 100 % 100))
  build_patch=$((hash_value % 100))
  build_version="${build_major}.${build_minor}.${build_patch}"
  artifact_name="MacClippy-nightly-${short_sha}"
  release_kind="nightly"
  volume_name="Mac Clippy nightly ${short_sha}"
else
  fail "nightly releases are allowed only from refs/heads/main"
fi

[[ "${build_version}" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]] || fail "generated CFBundleVersion is invalid: ${build_version}"

output_file="${GITHUB_OUTPUT:-}"
if [[ -n "${output_file}" ]]; then
  {
    echo "marketing_version=${version}"
    echo "build_version=${build_version}"
    echo "artifact_name=${artifact_name}"
    echo "release_kind=${release_kind}"
    echo "volume_name=${volume_name}"
    echo "source_sha=${SOURCE_SHA}"
  } >> "${output_file}"
else
  printf 'marketing_version=%s\nbuild_version=%s\nartifact_name=%s\nrelease_kind=%s\nvolume_name=%s\nsource_sha=%s\n' \
    "${version}" "${build_version}" "${artifact_name}" "${release_kind}" "${volume_name}" "${SOURCE_SHA}"
fi

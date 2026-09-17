#!/usr/bin/env bash
# ==============================================================================
# Universal Semantic Release Script for macOS Apps
# ==============================================================================
# Usage:
#   ./scripts/release.sh [VERSION]
#   or: make release [VERSION=1.0.0]
#
# Examples:
#   ./scripts/release.sh 1.0.0
#   ./scripts/release.sh v1.0.0
#   ./scripts/release.sh          # Interactively prompts / auto-increments patch
# ==============================================================================

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"

cd "${project_root}"

# 1. Check working directory status
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree has uncommitted changes. Please commit or stash before releasing." >&2
    exit 1
fi

current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [[ "${current_branch}" != "main" && "${current_branch}" != "master" ]]; then
    echo "error: releases must be cut from the default branch ('main' or 'master'). Currently on '${current_branch:-detached HEAD}'." >&2
    exit 1
fi

echo "==> Fetching latest changes and tags from origin..."
git fetch origin "${current_branch}" --tags

# Ensure local branch is up-to-date with remote
local_head=$(git rev-parse HEAD)
remote_head=$(git rev-parse "origin/${current_branch}")
if [[ "${local_head}" != "${remote_head}" ]]; then
    echo "error: local ${current_branch} (${local_head::7}) is not in sync with origin/${current_branch} (${remote_head::7}). Please push or pull first." >&2
    exit 1
fi

# 2. Determine target version
raw_version="${1:-${VERSION:-}}"

if [[ -z "${raw_version}" ]]; then
    # Find the latest semantic version tag
    latest_tag="$(git tag -l "v*" 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "${latest_tag}" ]]; then
        suggested="0.0.1"
    else
        # Auto-increment patch version: e.g. 0.0.1 -> 0.0.2
        v_num="${latest_tag#v}"
        major="$(echo "${v_num}" | cut -d. -f1)"
        minor="$(echo "${v_num}" | cut -d. -f2)"
        patch="$(echo "${v_num}" | cut -d. -f3)"
        next_patch=$((patch + 1))
        suggested="${major}.${minor}.${next_patch}"
    fi

    if [[ -t 0 ]]; then
        read -rp "Enter release version [default: ${suggested}]: " input_version
        raw_version="${input_version:-${suggested}}"
    else
        raw_version="${suggested}"
    fi
fi

# Normalize: strip leading 'v' then prefix with 'v'
clean_version="${raw_version#v}"
tag="v${clean_version}"

if ! [[ "${clean_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "error: invalid semantic version '${raw_version}'. Expected format: X.Y.Z or vX.Y.Z (e.g. 1.0.0)" >&2
    exit 1
fi

# 3. Check if tag already exists
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    echo "error: tag '${tag}' already exists locally." >&2
    exit 1
fi

if git ls-remote --tags origin "refs/tags/${tag}" | grep -q "${tag}"; then
    echo "error: tag '${tag}' already exists on origin." >&2
    exit 1
fi

# 4. Create and push tag
echo "==> Creating tag ${tag}..."
git tag -a "${tag}" -m "Release ${tag}"

echo "==> Pushing tag ${tag} to origin..."
git push origin "${tag}"

repo_url="$(git config --get remote.origin.url 2>/dev/null | sed -E 's|^git@github.com:|https://github.com/|; s|\.git$||' || true)"

echo ""
echo "================================================================"
echo "  🚀 Successfully published tag: ${tag}"
echo "================================================================"
echo "GitHub Actions will now automatically build and publish the release."
if [[ -n "${repo_url}" ]]; then
  echo ""
  echo "🔗 Watch progress: ${repo_url}/actions/workflows/release.yml"
  echo "📦 View release:   ${repo_url}/releases/tag/${tag}"
fi
echo "================================================================"

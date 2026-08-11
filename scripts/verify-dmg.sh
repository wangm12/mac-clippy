#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" || "${DMG_PATH}" != *.dmg ]]; then
  echo "usage: EXPECTED_TEAM_ID=TEAMID $0 /path/to/MacClippy.dmg" >&2
  exit 2
fi
if [[ -z "${EXPECTED_TEAM_ID}" ]]; then
  echo "error: set EXPECTED_TEAM_ID to verify the app embedded in the DMG" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="$(mktemp -d -t macclippy-dmg-mount)"
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach "${MOUNT_POINT}" -force >/dev/null 2>&1 || true
  fi
  rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach "${DMG_PATH}" \
  -readonly \
  -nobrowse \
  -mountpoint "${MOUNT_POINT}" \
  >/dev/null
mounted=1

app_paths=()
while IFS= read -r app_path; do
  app_paths+=("${app_path}")
done < <(find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)

if [[ "${#app_paths[@]}" -ne 1 || "$(basename "${app_paths[0]:-}")" != "MacClippy.app" ]]; then
  echo "error: DMG root must contain exactly one MacClippy.app bundle" >&2
  exit 1
fi
APP_PATH="${app_paths[0]}"

EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID}" "${SCRIPT_DIR}/verify-signed.sh" "${APP_PATH}"

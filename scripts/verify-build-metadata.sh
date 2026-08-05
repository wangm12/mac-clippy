#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.macallyouneed.macclippy}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" || "${APP_PATH}" != *.app ]]; then
  echo "usage: $0 /path/to/MacClippy.app" >&2
  exit 2
fi

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "error: application is missing Contents/Info.plist" >&2
  exit 1
fi

read_plist_value() {
  plutil -extract "$1" raw -o - "${INFO_PLIST}"
}

bundle_id="$(read_plist_value CFBundleIdentifier)"
if [[ "${bundle_id}" != "${EXPECTED_BUNDLE_ID}" ]]; then
  echo "error: unexpected bundle identifier: ${bundle_id}" >&2
  exit 1
fi

package_type="$(read_plist_value CFBundlePackageType)"
if [[ "${package_type}" != "APPL" ]]; then
  echo "error: unexpected bundle package type: ${package_type}" >&2
  exit 1
fi

if [[ "$(read_plist_value LSUIElement)" != "true" ]]; then
  echo "error: LSUIElement must be true for the menu-bar application" >&2
  exit 1
fi

for key in NSAccessibilityUsageDescription NSInputMonitoringUsageDescription; do
  value="$(read_plist_value "${key}")"
  if [[ -z "${value}" ]]; then
    echo "error: missing ${key}" >&2
    exit 1
  fi
done

executable="$(read_plist_value CFBundleExecutable)"
if [[ -z "${executable}" || ! -x "${APP_PATH}/Contents/MacOS/${executable}" ]]; then
  echo "error: bundle executable is missing or not executable" >&2
  exit 1
fi

echo "Application metadata passed for ${bundle_id}."

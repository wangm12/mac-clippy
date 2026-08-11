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

short_version="$(read_plist_value CFBundleShortVersionString)"
build_version="$(read_plist_value CFBundleVersion)"
if [[ ! "${short_version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: invalid CFBundleShortVersionString: ${short_version}" >&2
  exit 1
fi
if [[ ! "${build_version}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: invalid CFBundleVersion: ${build_version}" >&2
  exit 1
fi

# MacClippy selects its activation policy at runtime so users can independently
# show or hide the menu-bar item and Dock icon. A static LSUIElement value would
# make one of those user-selected modes impossible, so the runtime policy is
# verified by App tests/manual integration instead of this bundle-only check.
if static_lsui_element="$(read_plist_value LSUIElement 2>/dev/null)"; then
  case "${static_lsui_element}" in
    true|false|0|1) ;;
    *)
      echo "error: LSUIElement must be a Boolean when present: ${static_lsui_element}" >&2
      exit 1
      ;;
  esac
  echo "Static LSUIElement=${static_lsui_element}; runtime activation policy remains authoritative."
else
  echo "No static LSUIElement; runtime activation policy remains authoritative."
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

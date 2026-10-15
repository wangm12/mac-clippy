#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/verify-build-metadata.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macclippy-build-metadata-test.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

APP="${WORK}/MacClippy.app"
mkdir -p "${APP}/Contents/MacOS"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.macallyouneed.macclippy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>42</string>
  <key>NSAccessibilityUsageDescription</key><string>Test permission text</string>
  <key>NSInputMonitoringUsageDescription</key><string>Test permission text</string>
  <key>CFBundleExecutable</key><string>MacClippy</string>
</dict>
</plist>
PLIST
cat > "${APP}/Contents/MacOS/MacClippy" <<'BIN'
#!/usr/bin/env sh
exit 0
BIN
chmod +x "${APP}/Contents/MacOS/MacClippy"

EXPECTED_MARKETING_VERSION=1.2.3 EXPECTED_BUILD_VERSION=42 "${SCRIPT}" "${APP}" >/dev/null

if EXPECTED_MARKETING_VERSION=1.2.4 EXPECTED_BUILD_VERSION=42 "${SCRIPT}" "${APP}" >"${WORK}/marketing.out" 2>"${WORK}/marketing.err"; then
  echo "error: expected a marketing-version mismatch to fail" >&2
  exit 1
fi
grep -q "expected CFBundleShortVersionString 1.2.4, found 1.2.3" "${WORK}/marketing.err"

if EXPECTED_MARKETING_VERSION=1.2.3 EXPECTED_BUILD_VERSION=43 "${SCRIPT}" "${APP}" >"${WORK}/build.out" 2>"${WORK}/build.err"; then
  echo "error: expected a build-version mismatch to fail" >&2
  exit 1
fi
grep -q "expected CFBundleVersion 43, found 42" "${WORK}/build.err"

echo "verify-build-metadata tests passed"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/MacClippy.xcodeproj"
SCHEME="MacClippy"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/DerivedData/MacClippy-$CONFIGURATION}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
STAGING_DIR="${STAGING_DIR:-$ROOT/.build/mac-clippy-dmg-staging}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/MacClippy.dmg}"
VOLUME_NAME="${VOLUME_NAME:-Mac Clippy}"
CODE_SIGNING_MODE="${CODE_SIGNING_ALLOWED:-NO}"

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Regenerating MacClippy Xcode project"
  (cd "$ROOT" && xcodegen generate)
fi

echo "==> Building MacClippy ($CONFIGURATION)"
XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS,arch=arm64"
  -derivedDataPath "$DERIVED_DATA"
  -skipPackagePluginValidation
  "CODE_SIGNING_ALLOWED=$CODE_SIGNING_MODE"
)

if [[ "$CODE_SIGNING_MODE" == "YES" ]]; then
  [[ -n "${CODE_SIGN_IDENTITY:-}" ]] && XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] && XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  XCODEBUILD_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacClippy.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

echo "==> Staging DMG"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Wrote $DMG_PATH"

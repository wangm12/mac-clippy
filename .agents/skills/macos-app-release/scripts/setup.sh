#!/usr/bin/env bash
# ==============================================================================
# Setup Script: Install macOS App Packaging & Release Pipeline into Target Repo
# ==============================================================================
# Usage:
#   cd /path/to/any/macos-app-repo
#   ~/.gemini/config/skills/macos-app-release/scripts/setup.sh [AppName]
# ==============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${PWD}"

echo "==> Setting up macOS App Release Pipeline in: ${TARGET_DIR}"

# 1. Detect Xcode project / App name
custom_name="${1:-}"
if [[ -n "${custom_name}" ]]; then
  APP_NAME="${custom_name}"
else
  first_proj="$(find "${TARGET_DIR}" -maxdepth 2 -name "*.xcodeproj" -not -path "*/.*/*" | head -n 1 || true)"
  if [[ -n "${first_proj}" ]]; then
    APP_NAME="$(basename "${first_proj}" .xcodeproj)"
  else
    APP_NAME="$(basename "${TARGET_DIR}")"
  fi
fi

echo "==> Application Name: ${APP_NAME}"

# 2. Create directories
mkdir -p "${TARGET_DIR}/.github/workflows"
mkdir -p "${TARGET_DIR}/scripts"

# 3. Copy scripts
echo "==> Installing packaging scripts into ${TARGET_DIR}/scripts/ ..."
cp "${SKILL_DIR}/resources/package-dmg.sh" "${TARGET_DIR}/scripts/package-dmg.sh"
cp "${SKILL_DIR}/resources/release.sh" "${TARGET_DIR}/scripts/release.sh"
cp "${SKILL_DIR}/resources/import-signing-cert.sh" "${TARGET_DIR}/scripts/import-signing-cert.sh"

chmod +x "${TARGET_DIR}/scripts/package-dmg.sh"
chmod +x "${TARGET_DIR}/scripts/release.sh"
chmod +x "${TARGET_DIR}/scripts/import-signing-cert.sh"

# 4. Copy workflow
echo "==> Installing GitHub Action into ${TARGET_DIR}/.github/workflows/release.yml ..."
cp "${SKILL_DIR}/resources/release.yml" "${TARGET_DIR}/.github/workflows/release.yml"

# 5. Integrate with Makefile
if [[ -f "${TARGET_DIR}/Makefile" ]]; then
  if grep -q "^release:" "${TARGET_DIR}/Makefile" 2>/dev/null; then
    echo "==> Makefile already contains release target; skipping Makefile modification."
  else
    echo "==> Appending release targets to existing Makefile ..."
    echo "" >> "${TARGET_DIR}/Makefile"
    cat "${SKILL_DIR}/resources/Makefile.snippet" >> "${TARGET_DIR}/Makefile"
  fi
else
  echo "==> Creating Makefile with release targets ..."
  cat "${SKILL_DIR}/resources/Makefile.snippet" > "${TARGET_DIR}/Makefile"
fi

echo ""
echo "========================================================================"
echo "  🎉 macOS App Packaging & Release Pipeline successfully installed!"
echo "========================================================================"
echo "Created / Updated files:"
echo "  - .github/workflows/release.yml (GitHub Actions DMG/ZIP + Release automation)"
echo "  - scripts/package-dmg.sh       (Local & CI DMG & ZIP packager)"
echo "  - scripts/release.sh           (Semantic release cutter & git tag pusher)"
echo "  - scripts/import-signing-cert.sh (CI signing cert helper)"
echo "  - Makefile                     (make dmg & make release targets)"
echo ""
echo "Next Steps:"
echo "  1. Test packaging locally:      make dmg"
echo "  2. Commit changes:              git add . && git commit -m 'ci: add release pipeline'"
echo "  3. Cut your first release:      make release VERSION=0.0.1"
echo "========================================================================"

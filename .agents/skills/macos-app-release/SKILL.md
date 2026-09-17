---
name: macos-app-release
description: >-
  Automates macOS application packaging (DMG and ZIP), semantic release management,
  and GitHub Actions CI/CD workflows for any macOS / SwiftUI / Xcode app repository.
  Use when configuring, debugging, or standardizing macOS app distribution, DMG creation,
  nightly pre-releases, and official GitHub Releases.
---

# macOS App Packaging & GitHub Release Pipeline

This skill encapsulates a production-proven release pipeline for macOS apps, including DMG packaging with `/Applications` drag-and-drop installer, zipped app bundles, GitHub Actions automation, and one-command self-service releases.

## Core Capabilities

1. **Dual Artifact Distribution**:
   - Compressed `.dmg` disk image with `/Applications` symlink for end-user installation.
   - Preserved `.zip` archive (via `ditto --sequesterRsrc`) for direct unzipping / updates.
   - Automatically calculated `SHA256SUMS.txt` checksum file.
2. **Dual-Track GitHub Releases**:
   - **Nightly Pre-releases**: Automatically built and updated on every branch push (tagged as `nightly`, marked as `--prerelease`).
   - **Stable Releases**: Triggered by pushing a version tag `v*` (e.g. `v0.0.1`), automatically generates release notes and marks as `--latest`.
3. **One-Command Release**:
   - `make release [VERSION=X.Y.Z]` runs pre-flight safety checks (clean git state, main branch, sync with origin) and pushes the tag.
4. **Resilient Code Signing**:
   - Works immediately out-of-the-box in unsigned/ad-hoc mode.
   - Automatically uses Developer ID certificates when GitHub secrets (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`) are configured.

---

## Quick Installation into Another Repository

To set up this entire pipeline in another macOS repository, run:

```bash
# In the target repository directory:
~/.gemini/config/skills/macos-app-release/scripts/setup.sh [AppName]
```

Or copy the templates directly:
- Workflow: [release.yml](./resources/release.yml) -> `.github/workflows/release.yml`
- Packager: [package-dmg.sh](./resources/package-dmg.sh) -> `scripts/package-dmg.sh`
- Release Cutter: [release.sh](./resources/release.sh) -> `scripts/release.sh`
- Cert Importer: [import-signing-cert.sh](./resources/import-signing-cert.sh) -> `scripts/import-signing-cert.sh`
- Makefile snippet: [Makefile.snippet](./resources/Makefile.snippet) -> Append to `Makefile`

---

## Workflow Guide & Usage

### 1. Packaging Locally
```bash
make dmg
# Produces: dist/<AppName>.dmg and dist/<AppName>.zip
```

### 2. Cutting a New Release
```bash
# Explicit version:
make release VERSION=1.0.0

# Or auto-detect & increment patch version:
make release
```

### 3. GitHub Actions CI/CD Behavior
When pushed to GitHub:
- `push` to `main`: Updates the rolling `nightly` release with the latest DMG/ZIP builds.
- `push` tag `vX.Y.Z`: Builds and publishes the official release titled `<AppName> X.Y.Z` as the **Latest Release**.

---

## Reference Guides

- [Code Signing & Notarization Guide](./references/codesigning-and-notarization.md)
- [Headless macOS CI & Keychain Best Practices](./references/headless-ci-best-practices.md)

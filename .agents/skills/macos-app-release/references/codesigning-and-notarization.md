# macOS Code Signing & Notarization Guide

This document outlines the code signing and notarization architecture used in the release pipeline.

## 1. Signing Modes Supported

### Mode A: Unsigned / Ad-hoc (Zero Setup)
- Works immediately out-of-the-box without an Apple Developer Program subscription.
- The pipeline builds with `CODE_SIGNING_ALLOWED=NO` and `ENABLE_HARDENED_RUNTIME=YES`.
- Users who download the DMG can open it on macOS by right-clicking `Open` or running `xattr -cr /Applications/YourApp.app`.

### Mode B: Apple Developer ID Application (Official Distribution)
- For distributing outside the Mac App Store without Gatekeeper warnings.
- Required secrets in GitHub Repository Settings (`Settings -> Secrets and variables -> Actions`):
  1. `MACOS_CERT_P12`: Base64-encoded string of your exported `Developer ID Application.p12` certificate.
  2. `MACOS_CERT_PASSWORD`: The password used to protect the `.p12` file.

### How to export `.p12` from your Mac:
```bash
# 1. Open Keychain Access and locate "Developer ID Application: Your Name (TEAM_ID)"
# 2. Right click -> Export -> choose .p12 format and set a password.
# 3. Base64 encode it to copy into GitHub Secrets:
base64 -i YourCert.p12 | pbcopy
```

## 2. Notarization (Apple Notary Service)
To staple notarization tickets to your DMG:
- Generate an App Store Connect API Key or App-Specific Password.
- Configure `xcrun notarytool submit dist/YourApp.dmg --keychain-profile "notary-profile" --wait`
- Run `xcrun stapler staple dist/YourApp.dmg`

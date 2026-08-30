# Mac Clippy

Mac Clippy is a native macOS clipboard manager that lives in the menu bar. It
keeps your recent clipboard history searchable and makes frequently reused
content easy to paste.

## Features

- Local clipboard history for text, rich text, HTML, images, and files
- Fast full-text search with OCR support for captured images
- Copy, paste, queue paste, and multi-selection
- Pinboards for content you want to keep handy
- Snippets with configurable trigger expansion
- Text transforms such as case conversion, whitespace cleanup, and pretty JSON
- Privacy filters for concealed, transient, auto-generated, and excluded content
- Global shortcut for opening the clipboard dock (default `Command-Shift-V`, customizable in Settings)
- Colored pinboard categories, a details editor, and image Preview OCR text selection

## Search

History and Pinboard search understand:

- Bare words and CJK substrings
- Quoted phrases and prefix matches such as `clip*`
- Filters including `type:text`, `type:image`, `type:url`, `type:files`, `app:`, `name:`, and `has:ocr`

Snippets search name and trigger text only. A `type:` or date filter with no other words explains that those filters apply to History and Pinboard. A mixed query such as `hello type:text` still matches snippet text for `hello`.

## Installation

Build a DMG from source:

```sh
make dmg
```

The result is written to:

```text
dist/MacClippy.dmg
```

Open the DMG, drag `MacClippy.app` to `Applications`, and launch it from
Finder. Clipboard capture works locally. Automatic paste injection and snippet
expansion require macOS Accessibility permission; without it, Mac Clippy keeps
the clipboard available for manual paste.

Signing, first-launch Gatekeeper, and why permissions used to reset on every
update are documented in [Signing and permissions](#signing-and-permissions).

## Privacy and storage

Clipboard data is stored locally in:

```text
~/Library/Application Support/MacClippy/
```

Clipboard payloads and image blobs are encrypted with a device key stored in
the macOS Keychain. Search metadata is kept separately to support fast search.
Conservative capture exclusions are enabled by default, and additional app and
text exclusions can be configured in Settings.

## Development

Requirements:

- macOS 14 or later
- Xcode 26 or later
- XcodeGen (`brew install xcodegen`)

Run these commands from the repository root:

```sh
# Generate the Xcode project from project.yml
make generate

# Build the Debug app
make build

# Run Swift package and app tests
make test

# Run SwiftLint with the checked-in no-new-violations baseline
make lint

# Build and launch the Debug app
make run

# Run the complete CI-style build and test flow
make ci
```

`MacClippyKit` uses Swift Package Manager and fetches GRDB.swift automatically.
Build products and package caches are written to `.build/` and are ignored by
Git.

## Signing and permissions

macOS TCC (Accessibility, Input Monitoring) is bound to the **code-signing
identity**, not the bundle ID or the fact that the app is still named Mac
Clippy. An unsigned or ad-hoc build is identified by a hash of that exact
binary. Rebuild or replace the app and the hash changes. System Settings can
still show the old row as enabled while the new copy is a different app, so
you have to remove the entry and add it again.

That is why every update used to require removing and re-adding permissions.

### What this repo does

This project uses a **stable self-signed certificate** (not an Apple Developer
Program certificate, and not notarization).

| Path | What you get |
|---|---|
| Unsigned / ad-hoc (`codesign -s -`) | App can run after a Gatekeeper bypass. Permissions reset on every update. |
| **Stable self-signed (this repo)** | Same identity on every `make dmg` and on GitHub Releases that import the same `.p12`. Permissions persist. First launch still needs a Gatekeeper bypass. |
| Apple Development | Free Xcode identity. Persists on **your** Mac only. Cannot notarize. Cannot be shared as the GitHub Release identity unless you export it. |
| Developer ID + notarization (`make release`) | Double-click works for other people. Permissions persist. Requires the $99 Apple Developer Program. |

Ad-hoc signing is not used as the default. It avoids the “app is damaged”
dialog but does **not** keep TCC grants.

The certificate is named `Mac Clippy` and uses team id `MCLIPPY001`. The
designated requirement becomes the certificate leaf, so later binaries signed
with the same cert keep the grant.

This is **not** notarized. Other people’s first launch is still blocked by
Gatekeeper. Self-signing never removes that.

Do not reuse this certificate for other apps. VoiceFlow has its own identity
(`VoiceFlow` / `VOICEFLOW1`).

### Create the certificate once

```sh
make signing-cert
```

macOS may ask for the login keychain password so `codesign` can trust the
cert. The private key is written to gitignored files:

```text
.build/signing/MacClippy.p12
.build/signing/MacClippy.p12.base64
.build/signing/password.txt
```

Never commit those files. If the identity already exists, the script exits
without creating a second one.

`make dmg` calls the same path when the `Mac Clippy` identity is missing, so
the first DMG build can also create it.

### Build and install a signed DMG

```sh
make dmg
```

Identity preference when `DEVELOPER_IDENTITY` is unset:

1. `Mac Clippy` self-signed (so local DMGs match GitHub Releases)
2. Developer ID Application
3. Apple Development

Override with `DEVELOPER_IDENTITY` and `DEVELOPMENT_TEAM`.

Install only one copy. Grant permissions to `/Applications/MacClippy.app`.
`make run` / Debug builds stay unsigned (`CODE_SIGNING_ALLOWED=NO`). Daily
Xcode or `make run` overlays will still reset TCC.

### First launch (Gatekeeper)

A downloaded or copied app gets `com.apple.quarantine`. Without notarization
macOS may say it cannot verify the developer, or (if unsigned) that the app
is damaged.

1. System Settings → Privacy & Security → Open Anyway
2. Or clear quarantine for this app only:

```sh
xattr -dr com.apple.quarantine /Applications/MacClippy.app
```

Do not turn Gatekeeper off globally.

### Switching from an unsigned copy

If Accessibility or Input Monitoring already look granted but the signed app
does not work, the old hash-based row is stale. Reset once, then grant again:

```sh
tccutil reset Accessibility com.macallyouneed.macclippy
tccutil reset ListenEvent com.macallyouneed.macclippy
```

Replace `/Applications/MacClippy.app` from a DMG signed with `Mac Clippy`,
open it, and grant access. Later updates signed with the same certificate
should keep the grant.

Settings will warn when the running copy is unsigned or ad-hoc, and tell you
to run `make dmg` and replace the app in `/Applications`.

### GitHub Releases

The Release workflow publishes `dist/MacClippy.dmg` on a version tag (and can
be run by hand from **Actions → Release**). `dist/` is gitignored; the runner
builds a fresh DMG.

For those published updates to keep TCC, GitHub Actions must sign with the
**same** certificate:

```sh
make signing-cert
gh secret set MACOS_CERT_P12 < .build/signing/MacClippy.p12.base64
gh secret set MACOS_CERT_PASSWORD --body "$(cat .build/signing/password.txt)"
```

```sh
git tag v1.0.0
git push origin v1.0.0
```

That creates `https://github.com/wangm12/mac-clippy/releases/tag/v1.0.0`
with `MacClippy.dmg`. Re-running the same tag replaces the asset.

Without those two secrets the workflow still publishes a DMG, but it is
unsigned and permissions will reset on every download.

On GitHub Actions the job will not mint a new certificate. A new cert every
run would silently break TCC for everyone.

### Optional Developer ID and notarization

Double-click-without-warnings for other users still needs the paid program:

```sh
DEVELOPER_IDENTITY="Developer ID Application: Your Name" \
DEVELOPMENT_TEAM="TEAM_ID" \
NOTARY_PROFILE="stored-keychain-profile" \
make release
```

That is archive → signed DMG → notarize / staple / Gatekeeper. It is separate
from the default self-signed `make dmg` path.

### Scripts

| Script | Role |
|---|---|
| `scripts/make-signing-cert.sh` | Create the `Mac Clippy` identity once; export `.p12` |
| `scripts/select-codesign-identity.sh` | Prefer self-signed, then Developer ID, then Apple Development |
| `scripts/resolve-dmg-signing.sh` | Create the cert locally if needed; print identity + team |
| `scripts/import-signing-cert.sh` | Import `MACOS_CERT_P12` on the Release runner |
| `scripts/select-codesign-identity-test.sh` | Fixture tests for identity preference |

`make test` and CI run the identity selector tests.

## Project layout

```text
MacClippy/             macOS application and dock UI
MacClippyKit/          Core storage, capture, search, paste, and platform code
MacClippyTests/        Application-level XCTest target
MacClippyUITests/      macOS UI XCTest smoke and interaction target
scripts/               Self-sign, DMG packaging, verification, and notarization
project.yml            XcodeGen project definition
```

## License

This project is currently distributed without a public license.

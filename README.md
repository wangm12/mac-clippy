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

If a local Apple Development identity is in the Keychain, `make dmg` signs the app with that identity so TCC permissions stay stable during local testing. That is not a Developer ID or notarized release. Without a signing identity, the DMG is unsigned.

Open the DMG, drag `MacClippy.app` to `Applications`, and launch it from
Finder. Clipboard capture works locally. Automatic paste injection and snippet
expansion require macOS Accessibility permission; without it, Mac Clippy keeps
the clipboard available for manual paste.

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

## Release packaging

`make dmg` builds an arm64 Release DMG. It signs with a local Apple Development
identity when one is available; otherwise the DMG is unsigned. `make release`
is the Developer ID archive → final DMG → notarize/staple/Gatekeeper flow.

To create a signed artifact, provide a Developer ID identity and team ID:

```sh
DEVELOPER_IDENTITY="Developer ID Application: Your Name" \
DEVELOPMENT_TEAM="TEAM_ID" \
NOTARY_PROFILE="stored-keychain-profile" \
make release
```

Developer ID signing, notarization, and Gatekeeper verification require the
appropriate Apple certificates and credentials on the build machine.

## Project layout

```text
MacClippy/             macOS application and dock UI
MacClippyKit/          Core storage, capture, search, paste, and platform code
MacClippyTests/        Application-level XCTest target
MacClippyUITests/      macOS UI XCTest smoke and interaction target
scripts/               Build, signing, verification, and DMG packaging scripts
project.yml            XcodeGen project definition
```

## License

This project is currently distributed without a public license.

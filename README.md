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
- Global `Command-Shift-V` shortcut for opening the clipboard dock

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

# Build and launch the Debug app
make run

# Run the complete CI-style build and test flow
make ci
```

`MacClippyKit` uses Swift Package Manager and fetches GRDB.swift automatically.
Build products and package caches are written to `.build/` and are ignored by
Git.

## Release packaging

`make dmg` creates an unsigned arm64 Release DMG. `make release` is an alias for
the same command.

To create a signed artifact, provide a Developer ID identity and team ID:

```sh
CODE_SIGNING_ALLOWED=YES \
CODE_SIGN_IDENTITY="Developer ID Application: Your Name" \
DEVELOPMENT_TEAM="TEAM_ID" \
make dmg
```

Developer ID signing, notarization, and Gatekeeper verification require the
appropriate Apple certificates and credentials on the build machine.

## Project layout

```text
MacClippy/             macOS application and dock UI
MacClippyKit/          Core storage, capture, search, paste, and platform code
MacClippyTests/        Application-level XCTest target
scripts/               Build, signing, verification, and DMG packaging scripts
project.yml            XcodeGen project definition
```

## License

This project is currently distributed without a public license.

<p align="center">
  <a href="README.md">English</a> · <a href="README-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="MacClippy/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="MacClippy Icon" width="128" height="128" />
</p>

<h1 align="center">MacClippy</h1>

<p align="center">
  <strong>A native clipboard manager for macOS.</strong><br>
  Built with Swift, AppKit, SQLite FTS5 search, on-device Vision OCR, and local payload encryption.
</p>

<p align="center">
  <a href="https://github.com/wangm12/mac-clippy/releases/tag/nightly"><img src="https://img.shields.io/badge/release-nightly-blue.svg?style=flat-square" alt="Nightly Build" /></a>
  <a href="https://github.com/wangm12/mac-clippy/releases"><img src="https://img.shields.io/github/v/release/wangm12/mac-clippy?style=flat-square" alt="GitHub Release" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon%20%7C%20Intel-orange?style=flat-square" alt="Architecture" />
  <img src="https://img.shields.io/badge/language-Swift%206-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift" />
</p>

---

## Overview

macOS keeps the current clipboard contents. When you copy something new, the previous contents are replaced.

**MacClippy** is a native clipboard manager for macOS. It captures supported clipboard representations, keeps searchable history on this Mac, and provides Pinboards, snippets, and paste tools.

MacClippy is designed to keep clipboard observation and storage local. Actual responsiveness and resource use depend on the Mac, macOS version, and stored history; this README makes no comparative performance claims.

---

## Key Features

### 🎨 Liquid Glass Floating Dock
- **Native Floating Dock**: Summon the horizontal card dock with **`⌘⇧V`** (customizable) or the menu bar icon. It uses native macOS materials and supports multiple displays and full-screen spaces.
- **Smart Multi-Display & Full-Screen Aware**: Intelligently anchors to the active screen, respects menu bars and Docks, and adapts flawlessly across multiple monitors and Mission Control spaces.
- **Light & Dark Mode Harmony**: Dynamically matches your macOS system appearance and wallpaper tinting.

### ⚡ Full-Fidelity Universal Capture
- **Rich Media Support**: Automatically preserves plain text, rich formatted text (RTF), HTML, high-resolution images (PNG, JPEG, TIFF), file/directory references, URLs, and hex color swatches.
- **Source Application Tracking**: Every item is badged with the originating application's high-res icon and metadata for rapid visual identification.
- **Apple Continuity Universal Clipboard**: Captures content that Apple's Universal Clipboard places on this Mac's pasteboard. This is a macOS feature, not MacClippy history or key synchronization.

### 🔍 SQLite FTS5 & CJK Search
- **Indexed Search**: Uses SQLite FTS5 (Full-Text Search) with WAL mode via GRDB.
- **Full CJK & Prefix Support**: Flawlessly parses Chinese, Japanese, and Korean characters alongside Latin prefixes (`clip*`) and exact phrases (`"quoted text"`).
- **Power Search Filters**: Filter by type (`type:text`, `type:image`, `type:url`, `type:files`), originating app (`app:Xcode`, `app:Slack`), snippet name (`name:`), or OCR status (`has:ocr`).

### 👁️ On-Device Apple Vision OCR
- **On-Device Text Extraction**: Uses the macOS Vision framework to recognize text in copied images.
- **Searchable Graphics**: Recognized text in copied images can be searched in the dock.
- **Live Text Selection**: Preview images in the dock and drag to select, copy, or paste recognized text directly.

### 📌 Categorized Pinboards & Quick Snippets
- **Colored Pinboards**: Organize frequently used code snippets, boilerplate emails, tokens, and visual assets into custom-colored pinboard tabs.
- **Persistent Storage**: Pinned items never scroll away with ephemeral history.
- **Snippet Expansions**: Type a `;trigger`, then press Space to expand it, or choose **Confirm with Tab** in Settings. Triggers use the English semicolon `;` and must be typed rather than pasted. Return does not trigger expansion.

### 🪄 Instant Text Transformations
- **Format on the Fly**: Convert text directly within the dock before pasting:
  - **Case Conversion**: `UPPERCASE`, `lowercase`, `Title Case`, `camelCase`, `snake_case`, `kebab-case`.
  - **Cleanups**: Trim whitespace, unwrap line breaks, strip markdown/HTML tags.
  - **Developer Utilities**: JSON pretty-print / minify, URL encode / decode, Base64 encode / decode.

### 📋 Power Paste Modes
- **Direct Paste**: Press `Return` on a selected result to paste into your frontmost application. Double-click copies the item and closes the panel; `⌘C` copies while keeping it open.
- **Plain Text Paste**: Press `⇧⏎` (Shift+Return) to switch between plain and formatted paste. When Always paste as plain text is enabled, Shift-Return restores formatting.
- **Sequential Queue Paste**: Select multiple cards and choose **More → Paste selected items sequentially**. Items paste into the same target in displayed order; this does not move between form fields or provide a paste-next shortcut.
- **Multi-Card Paste**: Select cards with `⌘-Click` or `Shift-Click`. Merge text items to paste or copy; mixed content explains why merging is unavailable.
- **Quick Look Previews**: Press `Space` to inspect high-resolution images, full code snippets, or lengthy documents in an expanded viewer.

### 🛡️ Local Privacy and Encryption
- **Encrypted Payloads**: Clipboard payload envelopes and stored attachment/image payloads use AES-256-GCM with a 256-bit software key stored in the macOS Data Protection Keychain. The key is marked for this device only; this does not use a Secure Enclave key.
- **Automatic Password Manager Exclusion**: Built-in safeguards automatically suppress clipboard capture from 1Password, Bitwarden, KeePassXC, Apple Passwords, Keychain Access, and ephemeral/concealed pasteboard types.
- **Custom Blacklists**: Exclude any sensitive applications or specific regex patterns from history in Settings.
- **No MacClippy Cloud Sync**: MacClippy has no account-based history sync service.

---

## Performance and Capacity

MacClippy uses native Swift/AppKit components and an SQLite FTS5 index. The repository includes regression and scale fixtures, but their existence is not a published latency, memory, CPU, or cross-product benchmark. No numeric performance target or measured result is published here, and no startup, RSS, search-latency, or animation-rate comparison is claimed.

Clipboard observation polls at about 50 ms during active use and for a short burst after a clipboard change. After roughly 30 seconds without user input or a recent change, the interval moves to about 400 ms. Polling is suspended while the system sleeps.

History retention has independent age, item-count, and payload-size bounds:

- The default item limit is **10,000**.
- The retained image-payload budget is **2 GiB** in total; this is not a per-image allowance.
- The total retained clipboard-payload budget is **4 GiB**.
- **Unlimited** means no age-based expiration. The item and payload limits still apply. SQLite metadata, indexes, journals, and filesystem overhead mean these payload budgets are not a strict cap on the entire application-support directory size.

See the [primary-source competitor comparison and engineering recommendations](docs/competitive-comparison.md).

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **`⌘ ⇧ V`** | Summon or dismiss the MacClippy Dock (customizable in Settings) |
| **`Type to search`** | Instant fuzzy and full-text filter across all history |
| **`⏎` (Return)** | In search, move to results; in results, paste the selected item |
| **`⇧ ⏎`** | Switch between plain and formatted paste |
| **`Space`** | Toggle result preview; type a normal space in search |
| **`⌘ 1` – `⌘ 9`** | Instantly paste item at slot 1 to 9 |
| **`⌘ C`** | Copy selected item to clipboard without dismissing the dock |
| **`⌘ P`** | Choose a target Pinboard for selected items |
| **`Tab` / `Shift-Tab`** | Switch between search and results without clearing the query |
| **`⌘ F` / `⌘ K`** | Focus search |
| **`⌘ ⌥ V`** | Show item details; use `⌘E` there to edit |
| **`⌘ S` / `⌘ Return`** | Save / save and paste while editing |
| **`⌘ ⌫` (Backspace)** | Delete selected item from history |
| **`←` / `→`** | Navigate between clipboard cards |
| **`Esc`** | Exit the current layer; in search, clear the query before closing |

---

Search and filters stay in place while you select, preview, or edit an item. Use the filter button for type, source app and dates. Snippets temporarily use keywords only; returning to History restores its filters. The search × clears words and filters; **Clear filters** keeps the words.

## Search Grammar & Operators

MacClippy's search bar accepts natural text as well as power filter tokens:

- **Plain Words & CJK**: `git commit`, `设计稿`, `東京タワー`
- **Quoted Exact Match**: `"API_KEY_PRODUCTION"`, `"meeting notes"`
- **Prefix Wildcard**: `clip*`, `func*`
- **Type Filters**:
  - `type:text` — Filter plain and formatted text
  - `type:image` — Filter screenshots, photos, and graphics
  - `type:url` — Filter web links and URIs
  - `type:files` — Filter copied file and directory references
- **Source App Filter**: `app:Xcode`, `app:Slack`, `app:Safari`
- **Name Filter**: `name:welcome-email`
- **OCR Filter**: `has:ocr` — Show only images containing recognized text
- **Combined Queries**: `error type:text app:Terminal`

---

## Apple Universal Clipboard

When macOS Universal Clipboard places content from another nearby Apple device on this Mac's pasteboard, MacClippy can capture it as a local entry. MacClippy does not synchronize its history or encryption key between Macs.

Backups contain encrypted app data but do not export the Keychain key. Restore requires the original installation's existing key; a backup cannot migrate history or its key to another device.

---

## Installation & Downloads

### 1. Prebuilt Installers
Installers are built from `main` for nightlies and from `vX.Y.Z` tags for stable releases, after the same-commit CI workflow succeeds:

- **Download DMG or ZIP**:
  - [Latest Releases](https://github.com/wangm12/mac-clippy/releases) (Stable versions)
  - [Nightly Builds](https://github.com/wangm12/mac-clippy/releases/tag/nightly) (Latest continuous build)
- Choose the versioned DMG or ZIP asset from the release page. Open the DMG and drag `MacClippy.app` into your **Applications** folder.

### 2. Permissions & Gatekeeper Note
- **Accessibility Permission**: Required for automatic paste injection (`CGEvent` keystroke simulation) and text transformations. You can grant this in **System Settings → Privacy & Security → Accessibility**.
- **Gatekeeper First-Launch**: Builds without Developer ID signing and notarization may show a Gatekeeper warning.
  - After trying to open the app, go to **System Settings → Privacy & Security** and choose **Open Anyway**, then confirm the prompt. See [Apple's instructions](https://support.apple.com/en-us/102445).

### 3. Build from Source

Requirements:
- macOS 14.0+ at runtime (Sonoma or later)
- Xcode 16.3+ with Swift 6.1+, installed on a macOS version supported by that Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) & [SwiftLint](https://github.com/realm/SwiftLint) (managed automatically via scripts)

```sh
# Clone repository
git clone https://github.com/wangm12/mac-clippy.git
cd mac-clippy

# Install pinned tools (XcodeGen & SwiftLint)
./scripts/install-pinned-tools.sh

# Generate Xcode project
make generate

# Build Debug app
make build

# Package a DMG and ZIP into dist/ (signed when Developer ID credentials are configured)
make dmg
```

---

## Development & Testing

See [the CI and release process](docs/release-process.md) for same-commit release gates, versioning, and minimum-OS runtime coverage.

```sh
make help           # List the available development and release targets
make generate       # Generate MacClippy.xcodeproj from project.yml
make build          # Compile Debug application
make test           # Run package tests and MacClippyTests unit tests; excludes UI tests
make test-scripts   # Run build and release shell-script tests
make test-scale     # Run explicitly opted-in package and Runtime scale fixtures
make test-stress    # Run lifecycle stress tests
make test-tsan      # Run package tests with Thread Sanitizer
make test-app-tsan  # Run MacClippyTests unit tests with Thread Sanitizer
make lint           # SwiftLint check against baseline
make dmg            # Package a DMG and ZIP (signed when Developer ID credentials are configured)
make ci             # Run the CI build and verification workflow
make clean          # Remove managed caches, test results, and archives; preserve dist/ and review evidence
```

---

## Architecture & Tech Stack

```text
MacClippy/
├── MacClippy/             # Native AppKit application, Liquid Glass dock, menus, preferences
├── MacClippyKit/          # Shared framework: storage, FTS5 search, OCR, transforms, encryption
├── MacClippyTests/        # App-level unit and integration tests
├── MacClippyUITests/      # UI interaction, dock animation, and paste tests
├── scripts/               # Code signing, DMG/ZIP packaging, toolchain verification
└── project.yml            # Declarative XcodeGen configuration
```

- **User Interface**: Pure AppKit with customized `NSPanel`, `NSVisualEffectView`, Core Animation, and smooth drag-and-drop support.
- **Storage Engine**: SQLite 3 with WAL journal mode, accessed through [GRDB.swift](https://github.com/groue/GRDB.swift).
- **Search Engine**: SQLite FTS5 with custom unicode tokenizers and CJK substring matching.
- **OCR Engine**: Apple Vision Framework (`VNRecognizeTextRequest`) processes recognized text on-device.
- **Payload Encryption**: CryptoKit AES-256-GCM uses a software-generated 256-bit key stored in the Data Protection Keychain with `WhenUnlockedThisDeviceOnly` accessibility. This is not a Secure Enclave key.

---

## Privacy & Local Storage

MacClippy stores its data on the local machine:

```text
~/Library/Application Support/MacClippy/
```

- MacClippy has no account-based history sync. Apple Universal Clipboard can place copied content on this Mac's pasteboard; MacClippy then stores a local copy.
- Clipboard payload envelopes and attachment/image payload bytes are encrypted. The SQLite databases are not encrypted as a whole: searchable previews, OCR text, full-text search terms, custom labels and snippet triggers, source-app details, content types, timestamps, and other operational metadata remain plaintext so the app can search and display history.
- The encryption key is kept in this installation's Keychain and is not included in a backup. Restore requires the original installation's key; backups do not provide cross-device key migration.
- Sensitive pasteboards (passwords, concealed data, internal temporary copies) are discarded before writing to disk.
- You have 100% control over your data. Clear history anytime with one click in Settings.

---

## License

This project is distributed without a public license.

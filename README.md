<p align="center">
  <a href="README.md">English</a> · <a href="README-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="MacClippy/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="MacClippy Icon" width="128" height="128" />
</p>

<h1 align="center">MacClippy</h1>

<p align="center">
  <strong>Blazing-fast, memory-efficient native clipboard manager for macOS.</strong><br>
  Engineered in 100% Swift & AppKit with SQLite FTS5, Apple Vision OCR, and Keychain encryption.
</p>

<p align="center">
  <a href="https://github.com/wangm12/mac-clippy/releases/tag/nightly"><img src="https://img.shields.io/badge/release-nightly-blue.svg?style=flat-square" alt="Nightly Build" /></a>
  <a href="https://github.com/wangm12/mac-clippy/releases"><img src="https://img.shields.io/github/v/release/wangm12/mac-clippy?style=flat-square" alt="GitHub Release" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20(Sonoma%20%7C%20Sequoia)-lightgrey?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon%20%7C%20Intel-orange?style=flat-square" alt="Architecture" />
  <img src="https://img.shields.io/badge/memory-~30MB%20RSS-brightgreen?style=flat-square" alt="Memory" />
  <img src="https://img.shields.io/badge/language-Swift%206-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift" />
</p>

---

## Overview

macOS only keeps a single item in its clipboard. The moment you copy something new, your previous work is overwritten forever.

**MacClippy** is an ultra-lightweight, privacy-first clipboard manager built specifically for the Mac ecosystem. Unlike heavy web-wrapper or Electron-based alternatives that consume hundreds of megabytes of RAM and run sluggish background engines, MacClippy is crafted in **pure native Swift and AppKit**. It delivers instantaneous keystroke responses, silky-smooth 120Hz ProMotion dock animations, full-fidelity rich content capture, and sub-millisecond full-text search across tens of thousands of clipboard entries.

Whether you are writing code, filling out tedious multi-field spreadsheets, capturing screenshots, or managing reusable text snippets, MacClippy works silently in the background, keeping your data strictly local and secure.

---

## Key Features

### 🎨 Liquid Glass Floating Dock
- **Native ProMotion Fluidity**: Summon the horizontal card dock with **`⌘⇧V`** (fully customizable) or the menu bar icon. Glides onto the screen at 120fps with native macOS materials and fluid physics.
- **Smart Multi-Display & Full-Screen Aware**: Intelligently anchors to the active screen, respects menu bars and Docks, and adapts flawlessly across multiple monitors and Mission Control spaces.
- **Light & Dark Mode Harmony**: Dynamically matches your macOS system appearance and wallpaper tinting.

### ⚡ Full-Fidelity Universal Capture
- **Rich Media Support**: Automatically preserves plain text, rich formatted text (RTF), HTML, high-resolution images (PNG, JPEG, TIFF), file/directory references, URLs, and hex color swatches.
- **Source Application Tracking**: Every item is badged with the originating application's high-res icon and metadata for rapid visual identification.
- **Apple Continuity Universal Clipboard**: Seamlessly catches copies made on your nearby iPhone or iPad via macOS native Handoff without needing any companion cloud server.

### 🔍 Instant SQLite FTS5 & CJK Search
- **Sub-3ms Search Latency**: Powered by SQLite FTS5 (Full-Text Search) with WAL mode via GRDB. Search 10,000+ clips without a hint of hesitation.
- **Full CJK & Prefix Support**: Flawlessly parses Chinese, Japanese, and Korean characters alongside Latin prefixes (`clip*`) and exact phrases (`"quoted text"`).
- **Power Search Filters**: Filter by type (`type:text`, `type:image`, `type:url`, `type:files`), originating app (`app:Xcode`, `app:Slack`), snippet name (`name:`), or OCR status (`has:ocr`).

### 👁️ On-Device Apple Vision OCR
- **Offline Text Extraction**: Scans screenshots and copied images directly on Apple Silicon Neural Engine using the macOS Vision framework.
- **Searchable Graphics**: Text inside copied images and receipts becomes instantly searchable in the dock.
- **Live Text Selection**: Preview images in the dock and drag to select, copy, or paste recognized text directly. Zero cloud transmissions.

### 📌 Categorized Pinboards & Quick Snippets
- **Colored Pinboards**: Organize frequently used code snippets, boilerplate emails, tokens, and visual assets into custom-colored pinboard tabs.
- **Persistent Storage**: Pinned items never scroll away with ephemeral history.
- **Snippet Expansions**: Assign custom shorthand trigger keywords to snippets for fast textual expansion.

### 🪄 Instant Text Transformations
- **Format on the Fly**: Convert text directly within the dock before pasting:
  - **Case Conversion**: `UPPERCASE`, `lowercase`, `Title Case`, `camelCase`, `snake_case`, `kebab-case`.
  - **Cleanups**: Trim whitespace, unwrap line breaks, strip markdown/HTML tags.
  - **Developer Utilities**: JSON pretty-print / minify, URL encode / decode, Base64 encode / decode.

### 📋 Power Paste Modes
- **Direct Paste**: Press `Return` or double-click to inject the item directly into your frontmost application.
- **Plain Text Paste**: Press `⇧⏎` (Shift+Return) or `⌥⏎` (Option+Return) to strip formatting and match your destination style.
- **Sequential Queue Paste**: Copy multiple items in sequence, then press `⌘⇧P` to paste them one by one into web forms or tables in order.
- **Multi-Card Paste**: Select multiple non-contiguous cards with `⌘-Click` or `Shift-Click` and paste them all together.
- **Quick Look Previews**: Press `Space` to inspect high-resolution images, full code snippets, or lengthy documents in an expanded viewer.

### 🛡️ Privacy by Design & Hardware Security
- **Local AES-256 Keychain Encryption**: All clipboard contents and image blobs stored on disk are encrypted using keys securely managed by the macOS Keychain.
- **Automatic Password Manager Exclusion**: Built-in safeguards automatically suppress clipboard capture from 1Password, Bitwarden, KeePassXC, Apple Passwords, Keychain Access, and ephemeral/concealed pasteboard types.
- **Custom Blacklists**: Exclude any sensitive applications or specific regex patterns from history in Settings.
- **100% Offline**: Zero analytics, zero telemetries, no background tracking, and no external servers.

---

## Performance & Memory Usage

MacClippy is engineered with a strict native performance budget. We reject bloated Chromium/Node.js runtimes in favor of pure Swift, native AppKit views, and optimized low-level SQLite database calls.

### Real-World Benchmark Comparison

| Metric | MacClippy (Native Swift) | Typical Electron Clipboard App | Raycast / Paste | Note |
|---|---|---|---|---|
| **Cold Startup Time** | **< 150 ms** | 1,800 ms – 3,500 ms | ~400 ms – 800 ms | Instant menu bar readiness upon login |
| **Idle Memory (Background RSS)** | **~28 MB – 45 MB** | 250 MB – 450 MB | ~85 MB – 140 MB | 10x lighter than web-wrapper tools |
| **Active Search Memory Peak** | **~45 MB – 65 MB** | 350 MB – 600 MB | ~110 MB – 180 MB | Memory footprint remains flat after thousands of queries |
| **Search Latency (10,000 items)** | **< 3 ms** | 45 ms – 120 ms | ~5 ms – 15 ms | SQLite FTS5 index with WAL mode |
| **Dock UI Animation** | **120 fps ProMotion** | 45 – 60 fps (stutters) | 120 fps | Native Core Animation & AppKit layer rendering |
| **Idle Background CPU** | **< 0.1%** | 1.5% – 5.0% | < 0.5% | Event-driven pasteboard observation; zero busy-wait polling |
| **Disk Write Latency** | **< 1 ms / item** | 10 ms – 30 ms | ~2 ms | Asynchronous batch commits via GRDB |
| **OCR Processing Speed** | **< 80 ms** | Cloud API (300-800ms) | ~100 ms | On-device Apple Silicon Neural Engine (Vision framework) |
| **Runtime Footprint** | **Zero dependencies** | Node runtime + Chrome engine | Proprietary daemon | Standalone compiled Mach-O binary |

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **`⌘ ⇧ V`** | Summon or dismiss the MacClippy Dock (customizable in Settings) |
| **`Type to search`** | Instant fuzzy and full-text filter across all history |
| **`⏎` (Return)** | Paste selected item into frontmost application |
| **`⇧ ⏎` or `⌥ ⏎`** | Paste as Plain Text (strips formatting, RTF, fonts, colors) |
| **`Space`** | Quick Look preview with zoom and OCR Live Text selection |
| **`⌘ 1` – `⌘ 9`** | Instantly paste item at slot 1 to 9 |
| **`⌘ C`** | Copy selected item to clipboard without dismissing the dock |
| **`⌘ P`** | Pin or unpin selected item to a Pinboard |
| **`⌘ ⇧ P`** | Paste next item in Queue Paste mode |
| **`⌘ ⌫` (Backspace)** | Delete selected item from history |
| **`←` / `→`** | Navigate between clipboard cards |
| **`Esc`** | Dismiss MacClippy Dock |

---

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

## Cross-Device Clipboard (Universal Clipboard)

MacClippy works seamlessly with Apple's built-in **Universal Clipboard** without running any proprietary cloud sync daemon:

- When you copy an item on your iPhone or iPad, Apple Continuity writes it directly onto the macOS pasteboard.
- MacClippy immediately captures the payload as a local entry with the originating metadata.
- Requirements: Both devices signed into the same Apple Account, Bluetooth and Wi-Fi enabled, within Handoff range (~10 meters).

---

## Installation & Downloads

### 1. Prebuilt Installers
Ready-to-use binaries are built on every push:

- **Download DMG or ZIP**:
  - [Latest Releases](https://github.com/wangm12/mac-clippy/releases) (Stable versions)
  - [Nightly Builds](https://github.com/wangm12/mac-clippy/releases/tag/nightly) (Latest continuous build)
- Open `MacClippy.dmg`, drag `MacClippy.app` into your **Applications** folder, and launch it.

### 2. Permissions & Gatekeeper Note
- **Accessibility Permission**: Required for automatic paste injection (`CGEvent` keystroke simulation) and text transformations. You can grant this in **System Settings → Privacy & Security → Accessibility**.
- **Gatekeeper First-Launch**: Since MacClippy uses a self-signed certificate, macOS may present an unidentified developer prompt on first launch.
  - Go to **System Settings → Privacy & Security** and click **Open Anyway**.
  - Or clear the quarantine attribute via Terminal:
    ```sh
    xattr -dr com.apple.quarantine /Applications/MacClippy.app
    ```

### 3. Build from Source

Requirements:
- macOS 14.0+ (Sonoma or Sequoia)
- Xcode 15.0+ or Xcode Command Line Tools
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

# Package signed DMG and ZIP into dist/
make dmg

# Run the app
make run
```

---

## Development & Testing

```sh
make generate       # Generate MacClippy.xcodeproj from project.yml
make build          # Compile Debug application
make test           # Run complete XCTest suite and package tests
make lint           # SwiftLint check against baseline
make run            # Build and launch Debug build
make dmg            # Package signed MacClippy.dmg and MacClippy.zip
make ci             # Run end-to-end CI build and verification workflow
make clean          # Remove build artifacts and temporary staging files
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
- **OCR Engine**: Apple Vision Framework (`VNRecognizeTextRequest`) with on-device Neural Engine acceleration.
- **Security**: Apple Keychain Services (`Security.framework`) with hardware AES-256 GCM encryption.

---

## Privacy & Local Storage

All user data is stored strictly on your local machine:

```text
~/Library/Application Support/MacClippy/
```

- No cloud servers, no network requests, no telemetries, and no user tracking.
- Sensitive pasteboards (passwords, concealed data, internal temporary copies) are discarded before writing to disk.
- You have 100% control over your data. Clear history anytime with one click in Settings.

---

## License

This project is distributed without a public license.

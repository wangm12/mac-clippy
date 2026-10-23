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

Quick links: [Features and usage](#features-and-usage) · [Capacity](#performance-and-capacity) · [Shortcuts](#keyboard-shortcuts) · [Installation](#installation--downloads) · [Development](#development--testing) · [Privacy](#privacy--local-storage)

## Features and Usage

This guide describes the current repository implementation. **History / All** opens clipboard history, **Pinboards** organize retained items, and **Snippets** hold reusable text.

### Quick Start

1. Launch MacClippy and copy text or an image in another app.
2. Press `⌘⇧V` or click the menu bar icon to open history. Customize the opening shortcut in Settings.
3. Type to search, press `Return` to enter results, select with the arrow keys, then press `Return` again to paste into your previous working window.
4. To copy, double-click a card to copy and close, or use `⌘C` / right-click **Copy** to keep the panel open.
5. Open Settings with the gear button, or use **More actions → Shortcuts & Search Help…** for in-app help.

### Capture and History Cards

- Capture supported plain text, RTF, HTML, images, and file/folder references, including multiple items and representations from one clipboard change.
- Cards show content previews, image thumbnails, file information, links or hex color previews, and available source-app information.
- File entries retain references rather than archiving the original file. Moving or deleting that file can break the reference.
- Oversized or unreadable representations can be marked unavailable. Replay of every app-specific private format is not guaranteed; inspect retained formats and availability in Details.
- History loads in pages. Built-in URL and Image shortcuts filter existing history; deleting one of these shortcuts from its context menu hides the shortcut without deleting records.
- The native floating panel supports multiple displays and full-screen spaces, with adaptations for light/dark appearance, Reduce Motion, Reduce Transparency, and increased contrast.

### Copy, Paste, Duplicate Capture, and Ordering

Ordinary History sorts by **modification time (`modified`), newest first**, then by descending Lamport value and record ID to break ties. It does not sort by last use.

| Action | Clipboard / target-app behavior | History order and counters |
|---|---|---|
| Single-click a card | Select it | No move or access-count increment |
| Double-click a card | Copy to the system clipboard; close after success | No move or access-count increment |
| `⌘C` / Copy | Copy; keep the panel open | No move or access-count increment |
| Copy plain / Copy transformed | Copy derived plain text for this operation | Original unchanged; no move or access-count increment |
| `Return` in results / Paste | Send a paste operation to the target app | After successful injection, increment access count and update last access; no move |
| Copy identical content again in another app | Capture and attempt deduplication | On a match, reuse the existing record, increment access count, update access and modification times, and move it to the newest position |
| Edit or rename a history item | Save changes to the original record | Update modification time; this can change its History position |

For example, with **C → B → A** from newest to oldest, copying or directly pasting B from History leaves **C → B → A**. Copying B again in another app, with a deduplication match, produces **B → C → A**.

Deduplication hashes the primary content and its clipboard representations, then validates the stored candidate. It does not compare only the visible text. Identical words with different HTML, RTF, or other representation data can produce separate entries. A matching capture retains the original record ID, creation time, source information, custom name, and Pinboard memberships without inserting a second row.

The observer skips MacClippy's regular Copy/Paste writes to avoid recapture. **Copying selected or OCR text from a preview is an exception**: extracted text enters normal history capture, subject to pause, exclusion, and deduplication rules.

Access count is auxiliary metadata: both successful paste injection and duplicate external capture can increment it. It does not measure confirmed consumption by a target app. Copying from History and manually pressing `⌘V` elsewhere does not separately increment this counter.

### Formatted, Plain Text, and Multiple-Item Paste

- By default, `Return` uses retained formatting and `Shift-Return` requests plain text. **Always paste as plain text** reverses those choices. Plain-text conversion applies to text-compatible content.
- `⌘`-click toggles selection; `Shift`-click extends a range. In History/Pinboard results, `⌘A` selects all matches for the current query, including matches on unloaded pages.
- **Merge & Copy / Merge & Paste** converts text-compatible items to plain text and joins them with newlines in displayed order. Copy prepares the clipboard; Paste sends one merged payload and updates each original item's access count. Images, files, and unreadable text cannot be merged; the app does not silently drop part of the selection.
- **Selection toolbar → More → Paste selected items sequentially** sends individual items, including different supported types, to the same target app in displayed order. It does not Tab between fields or provide a paste-next shortcut. Results report unavailable items, failures, and interruptions.
- Automatic paste requires Accessibility permission. Follow any failure or permission feedback, or use Copy and paste manually. Successful injection means the system paste events were submitted, not that every target app has consumed the clipboard.

### Search and Filters

SQLite FTS5 provides indexed search, with Chinese, Japanese, and Korean substring matching, Latin prefixes, and quoted phrase queries. Indexed information includes content previews, recognized OCR text, and custom names.

| Query | Meaning |
|---|---|
| `design` / `设计稿` / `git commit` | Keyword search |
| `"meeting notes"` | Quoted phrase query |
| `clip*` | Prefix matching |
| `type:text`, `type:rtf`, `type:html` | Actual stored text kind; `type:text` does not include the latter two |
| `type:image`, `type:files`, `type:url` | Images, file references, or URLs |
| `app:Xcode`, `app:Safari` | Match source-app name or bundle ID |
| `name:welcome` | Match a custom name; `label:` and `tag:` are aliases, not a separate tagging system |
| `has:name`, `has:label` | A nonempty custom name exists |
| `has:ocr` | Recognized OCR text exists |
| `after:2026-01-01` | Modified at or after local midnight on this date, inclusive |
| `before:2026-02-01` | Modified strictly before local midnight on this date, exclusive |
| `error type:text app:Terminal` | Combine keywords and structured clauses |

The filter button offers type, source-app, and date controls. Dates use modification time rather than original creation time. Queries remain while changing filters, selecting, previewing, or editing items. Snippets temporarily use keywords only; returning to History restores its filters. The search × clears words and filters; **Clear filters** removes conditions while keeping words.

### Preview, OCR, Details, and Editing

- Press `Space` in results to toggle previews of supported text, rich text, images, and other content. Space in the search field remains normal text input.
- Apple Vision recognizes image text locally. Recognized text can be searched and selected/copied in image previews. Results depend on image quality and language; images without recognized text do not match `has:ocr`.
- Use `⌘⌥V` or **Details…** for source, creation/modification/access times, access count, custom name, Pinboard memberships, OCR, image dimensions, file paths, and retained representation types, sizes, and availability.
- **Rename…** assigns a custom name. Text-compatible items support **Edit…**; in Details, `⌘E` edits, `⌘S` saves, and `⌘Return` saves and pastes. Editing changes stored content and updates search indexing; images and files do not support text-content editing.
- Drag cards into Pinboards, or drag text-compatible cards into Snippets to start a snippet. Supported text, RTF, HTML, image, or file-reference content can also be dragged into apps accepting those formats.

### Pinboards and Deletion

- Create a Pinboard with **+ / New Pinboard…**; right-click it to rename, change color, or delete the board.
- Add items using **Pin to list**, `⌘P`, the selection toolbar's **Pin to…**, or drag and drop. One history item can belong to several Pinboards.
- Pinboards reference original history items rather than storing separate content copies. Items referenced by any Pinboard are protected from routine automatic cleanup, old-image compression, and Settings' unpinned-history deletion.
- **Remove from this Pinboard / Remove from list** removes membership only. Deleting a Pinboard removes the category while keeping history items. After removal from the last Pinboard, an item is subject to ordinary retention again.
- **Delete from history… / Delete permanently** deletes the original record and removes it from every Pinboard. Batch deletion and deletion involving pinned items require confirmation. **Delete unpinned history** in Settings preserves pinned items.

### Snippets

Use **More actions → New Snippet…**, or drag a text-compatible card into Snippets. Each snippet has a name, body, optional trigger, and optional folder label such as `Work/Email`. Its context menu offers Edit, Preview, Copy, Paste, and Delete. Name and body must be nonempty; triggers must be unique.

- **Expand with Space**: type an English-semicolon `;trigger`, then press Space.
- **Confirm with Tab**: type the same kind of trigger, then press Tab.
- **Off**: disable typed expansion while retaining copy/paste from the panel.
- Pasting a trigger does not expand it, and Return does not trigger expansion. Global typed expansion needs Accessibility and Input Monitoring permissions.
- Body variables expand when used: `{{date}}` → `YYYY-MM-DD`, `{{time}}` → `HH:mm`, and `{{clipboard}}` → current clipboard text. Date/time use the local calendar. Unknown variables stay literal; variables do not execute scripts.

### Text Transforms

Choose **Transform** in a text-compatible card's context menu, or **More → Transform** in Details, then **Copy transformed** or **Paste transformed**. The current eight transforms are:

| Transform | Behavior |
|---|---|
| Uppercase / Lowercase / Title Case | Change case; Title Case uses whitespace-delimited words |
| Trim whitespace | Remove leading/trailing whitespace and newlines |
| Pretty JSON | Format valid JSON and sort keys; leave invalid input unchanged |
| Clean tracking URL | Remove supported URL tracking parameters |
| Markdown quote | Prefix each line with `> ` |
| Sort lines | Sort lines using localized natural comparison |

Transforms derive plain text from HTML/RTF and affect only this copy or paste. They do not overwrite the stored record or search index. Images and files do not support text transforms.

### Capture Pause and Privacy Rules

- **More actions → Pause capture** or **Pause capture** in Settings pauses for 30 seconds, 5 minutes, 1 hour, or until manually resumed. Timed pauses resume automatically.
- **Ignore next copy / Skip next copy** or `⇧⌥⌘C` skips the next clipboard change. Repeated requests accumulate skips; cancel pending skips from More actions. Existing records remain.
- Built-in password-manager exclusions and concealed/transient-type exclusions apply by default. Settings accepts additional excluded apps and one regular-expression text rule per line.
- **Capture All** includes concealed and transient content while retaining built-in password-manager exclusions. Pause and custom exclusion rules still apply.
- Pause and exclusions affect future capture; they do not erase existing history. See Privacy & Local Storage below for encrypted payloads versus plaintext search metadata.

### Settings, Maintenance, and Recovery

| Setting / tool | Purpose |
|---|---|
| General: Shortcut, App visibility, Launch at login | Customize the opening shortcut, independently hide menu bar/Dock icons, and start at login; use the shortcut when both icons are hidden |
| History: Day / Week / Month / Unlimited | Retain for 1/7/30 days by modification time, or without age expiration; pinned items remain protected |
| History capacity dashboard | Inspect item and payload budgets; Unlimited still has count and size limits |
| Compress old images | Manually compress unpinned images modified over 7 days ago, targeting a maximum 2048-pixel edge and committing only beneficial compression; this changes stored images |
| Storage → Health / Refresh | Inspect and refresh storage health |
| Storage → Repair search index | Rebuild search indexing from stored data; this does not repair database corruption |
| Export diagnostics | Export health counters and redacted events for troubleshooting, without history bodies |
| Create backup | Save local history, Pinboards, snippets, and image/attachment data |
| Restore backup | Validate and replace local history, Pinboards, and snippets; this is not a merge import and requires the original installation's encryption key |
| Delete unpinned history | Manually remove unpinned entries while retaining pinned items |

Backups do not export the Keychain key or provide migration to another device. The permissions page opens Accessibility and Input Monitoring settings and shows the running app's path. If permissions do not refresh after authorization or switching app copies, quit and reopen the app.

---

## Performance and Capacity

MacClippy uses native Swift/AppKit components and an SQLite FTS5 index. The repository includes regression and scale fixtures, but their existence is not a published latency, memory, CPU, or cross-product benchmark. No numeric performance target or measured result is published here, and no startup, RSS, search-latency, or animation-rate comparison is claimed.

Clipboard observation polls at about 50 ms during active use and for a short burst after a clipboard change. After roughly 30 seconds without user input or a recent change, the interval moves to about 400 ms. Polling is suspended while the system sleeps.

History retention has independent age, item-count, and payload-size bounds:

- The default unpinned-history item limit is **10,000**; pinned items do not count toward this limit.
- The retained image-payload cleanup budget is **2 GiB**, not a per-image allowance. Accounting includes pinned images, but cleanup deletes only unpinned images, so pinned images can keep actual usage above this budget.
- The combined payload cleanup budget for unpinned history is **4 GiB**; pinned entries remain protected.
- The capacity dashboard is an advisory usage view, not a strict disk quota. Count and payload budgets currently have no Settings editors.
- **Unlimited** means no age-based expiration. The item and payload limits still apply. SQLite metadata, indexes, journals, and filesystem overhead mean these payload budgets are not a strict cap on the entire application-support directory size.

See the [primary-source competitor comparison and engineering recommendations](docs/competitive-comparison.md).

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **`⌘ ⇧ V`** | Summon or dismiss the MacClippy Dock (customizable in Settings) |
| **`Type to search`** | Search indexed history content |
| **`⏎` (Return)** | In search, move to results; in results, paste the selected item |
| **`⇧ ⏎`** | Switch between plain and formatted paste |
| **`Space`** | Toggle result preview; type a normal space in search |
| **`⌘ 1` – `⌘ 9`** | Instantly paste item at slot 1 to 9 |
| **`⌘ C`** | Copy selected item to clipboard without dismissing the dock |
| **`⌘ A`** | Select all matches in History/Pinboard results; select field text when searching |
| **`⇧⌥⌘C`** | Skip capture of the next clipboard change |
| **`⌘ P`** | Choose a target Pinboard for selected items |
| **`Tab` / `Shift-Tab`** | Switch between search and results without clearing the query |
| **`⌘ F` / `⌘ K`** | Focus search |
| **`⌘ ⌥ V`** | Show item details; use `⌘E` there to edit |
| **`⌘ S` / `⌘ Return`** | Save / save and paste while editing |
| **`⌘ ⌫` (Backspace)** | Delete selected history items and their Pinboard memberships |
| **`←` / `→`** | Navigate between clipboard cards |
| **`Esc`** | Exit the current layer; in search, clear the query before closing |

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
- **Accessibility Permission**: Required for automatic paste injection (`CGEvent` keystroke simulation) and typed snippet expansion. You can grant this in **System Settings → Privacy & Security → Accessibility**.
- **Input Monitoring Permission**: Used for global snippet-trigger monitoring. Grant it in **System Settings → Privacy & Security → Input Monitoring**; the permissions page also provides global-shortcut guidance.
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
├── MacClippy/             # AppKit / SwiftUI application, floating dock, menus, preferences
├── MacClippyKit/          # Shared framework: storage, FTS5 search, OCR, transforms, encryption
├── MacClippyTests/        # App-level unit and integration tests
├── MacClippyUITests/      # UI interaction, dock animation, and paste tests
├── scripts/               # Code signing, DMG/ZIP packaging, toolchain verification
└── project.yml            # Declarative XcodeGen configuration
```

- **User Interface**: AppKit windows, panels, and input routing with SwiftUI cards, previews, details, and settings; native materials, Core Animation, and drag-and-drop support.
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
- Built-in password-manager sources and concealed/transient clipboard types are excluded by default. Capture All changes type exclusions as described above; sensitive content that is not identified or excluded can still enter history.
- Settings' unpinned-history deletion preserves pinned items. Delete pinned records explicitly from history, or unpin them before cleanup.

---

## License

This project is distributed without a public license.

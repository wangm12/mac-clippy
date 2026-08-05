# Mac Clippy

Mac Clippy is a standalone native macOS 14+ menu-bar clipboard utility. For
each accepted pasteboard change it retains every advertised representation,
including unavailable and oversized type markers, while the legacy primary
representation still drives the clipboard card.

## Boundary

- The app is a single process with an `NSApplicationDelegate` composition root.
- The menu bar status item opens a reusable, nonactivating bottom clipboard dock
  panel on the screen containing the cursor.
- `MacClippyKit` owns the `MacClippyCore` and `MacClippyPlatform` library
  targets and their package tests.
- GRDB.swift is the only external package dependency and backs the app-owned
  storage layer.
- Future model-backed behavior is reserved for the Fireworks/GLM5.2 backend;
  this scaffold makes no network calls.

## Storage

The app creates `~/Library/Application Support/MacClippy/` with separate
clipboard, search, pinboard, and snippet databases plus encrypted image blobs.
The device key is stored in the system keychain. The standalone app has no App
Group and no dependency on `v1` or `v2`. Snippet triggers are implemented in
the first-release path with auto expansion by default, optional Tab
confirmation, and an off setting; event-tap installation is best effort so it
does not block clipboard capture.

Capture currently supports PNG/TIFF and other image data, text, RTF, HTML, and
file URLs. Every representation in an accepted change is retained, including
empty and provider-unavailable payloads (kept as type-only markers), and the
legacy primary representation still drives the card. Conservative defaults
exclude concealed, transient, auto-generated, and common password-manager
content; additional app and text exclusions are configurable in Settings.
Text-bearing records are indexed when conversion is available. The dock
reloads recent history when opened, searches the FTS index, and copies or
injects stored text/HTML/RTF, image, and file representations before closing. Plain-text copy
remains available for text-bearing records. Text/HTML/RTF cards also offer a
card context-menu Transform submenu that applies the existing text transform
engine (Uppercase, Lowercase, Trim whitespace, Pretty JSON, Clean tracking URL)
as a one-shot pasteboard operation: Copy transformed prepares the pasteboard
without posting a paste keystroke, and Paste transformed injects Cmd+V and
bumps frequency only on a successful injection. HTML/RTF are converted to plain
text before the transform; images and files are never offered.
The dock's Snippets tab supports saving text clipboard cards by dragging them
onto the Snippets pill; snippet expansion remains active in the runtime.
`MacClippyPlatform` provides permission-free Vision OCR APIs for image data and
`CGImage`; captured-image OCR is wired asynchronously and searchable. Tests do
not include a real Vision fixture. Paste injection has an explicit manual-paste
fallback when Accessibility is unavailable. The status item dock also
toggles with the global Command-Shift-V hotkey.
A multi-selection also offers Queue paste, which injects a separate Cmd+V per
selected record in visual order so mixed selections (text + HTML/RTF + image +
files) can each be consumed by the target app. This is distinct from Paste all,
which merges a homogeneous text selection into one paste; Paste all is
unchanged. Queue paste reports explicit unavailable IDs for missing/malformed
records and stops on a manual-paste (Accessibility-unavailable) result without
claiming the remaining IDs injected. Full success closes the dock; partial and
manual-stop outcomes keep the dock open so the explicit result is visible. No
queue database is added; this is one-shot ordered execution.

## Build

Run from `mac-clippy/`:

```sh
make generate
make build
make test
make run
make dmg
make clean
```

`make build` and `make test` use the repo-local `.build/DerivedData` directory.
`make dmg` (also available as `make release`) builds an unsigned Release app
and packages it as `dist/MacClippy.dmg`. Set `CODE_SIGNING_ALLOWED=YES`,
`CODE_SIGN_IDENTITY`, and `DEVELOPMENT_TEAM` when creating a signed artifact.

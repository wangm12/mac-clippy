# Settings Window + Shortcut Recorder

Status: approved
Repository: `/Users/mingjie.wang/Documents/personal/mac-all-you-need/mac-clippy`
Implementation owner: `builder-luna` subagent (`openai/gpt-5.6-luna`, `reasoningEffort: medium`) for every code step. The orchestrator does not write implementation code directly.
Review/verify owner: orchestrator.

## Goal

Reference: Paste's Settings window (General tab + Shortcuts tab). Mac Clippy currently has a
`Settings { }` SwiftUI scene (`MacClippy/MacClippyApp.swift:11`) with no in-app entry point (the
gear button shows an `NSAlert` About dialog instead), a flat single-page settings form, a
hardcoded/non-persisted global hotkey, and a snippet-expansion-mode preference with no UI.

Build a tabbed Settings window (General / Shortcuts) reachable from the dock's gear button, add
persistence + a recorder UI for the global hotkey, and surface the existing snippet-expansion-mode
preference. Scope is a single hotkey (Toggle dock) for this round — no additional configurable
shortcuts.

## Decisions

- No third-party dependency (`sindresorhus/KeyboardShortcuts` was evaluated and rejected — the
  existing `MacClippyGlobalHotKey`/`MacClippyGlobalHotKeyDescriptor` Carbon wrapper already covers
  registration; only persistence and a recorder view are missing, both small, low-risk additions).
- Scope: one configurable shortcut (Toggle dock). Do not add a multi-hotkey framework.
- Settings window entry point: gear button in the dock replaces its `NSAlert` About panel with
  `NSApp.sendAction(#selector(NSApplication.showSettingsWindow(_:)), to: nil, from: nil)`.
- Existing four settings sections (History, Privacy, Permissions, Startup) are preserved verbatim,
  just relocated under a "General" tab, plus a new Snippet Expansion Mode control.

## Verified current state (file:line)

- `MacClippyApp.swift:11-15` — `Settings { MacClippySettingsView() }` scene exists, unreachable from the dock.
- `MacClippyApp.swift:22-23` — `clipboardHotKey = MacClippyGlobalHotKey(descriptor: .defaultClipboard, ...)`, not persisted.
- `MacClippyKit/Sources/MacClippyPlatform/MacClippyGlobalHotKey.swift:4-17` — `MacClippyGlobalHotKeyDescriptor` (keyCode/modifiers as `UInt32`), `.defaultClipboard = Cmd+Shift+V`. No save/load.
- `MacClippyKit/Sources/MacClippyPlatform/MacClippyGlobalHotKey.swift:34-46` — `MacClippyGlobalHotKey.init(descriptor:callback:)`; `descriptor` is `let`, `register()`/`unregister()` exist.
- `MacClippy/MacClippyDock.swift:2106-2120` — gear button, `.help("About Mac Clippy")`, calls `showAboutPanel()`.
- `MacClippy/MacClippyDock.swift:2127-2147` — `showAboutPanel()`, plain `NSAlert` with version + hardcoded shortcut list in the info text.
- `MacClippy/MacClippySettings.swift:9-57` — `MacClippyRetentionPreferences` enum: all current keys (`maxItemsKey`, `maxAgeDaysKey`, `maxImageMegabytesKey`, `excludeConcealedKey`, `excludeTransientKey`, `excludedAppsKey`, `excludedTextPatternsKey`, `privacyPauseKey`, `launchAtLoginKey`).
- `MacClippy/MacClippySettings.swift:60-177` — `MacClippySettingsView`: flat `Form` with History / Privacy / Permissions / Startup sections, `@AppStorage` bindings, `formStyle(.grouped)`, `.frame(width: 520, height: 560)`.
- `MacClippyKit/Sources/MacClippyCore/MacClippySnippetExpansionSettings.swift:11-21` — `modeKey`, `MacClippySnippetExpansionMode` (`.autoExpand`/`.confirmWithTab`/`.disabled`), `load(from:)`/`save(_:to:)`. No UI anywhere.

## Implementation Steps

All steps dispatched to `builder-luna`, smallest correct diff, no unrelated refactors.

### Step 1 — Hotkey persistence

File: `MacClippyKit/Sources/MacClippyPlatform/MacClippyGlobalHotKey.swift`

- Add `static func save(_ descriptor: Self, to defaults: UserDefaults = .standard)` and
  `static func load(from defaults: UserDefaults = .standard) -> Self` to
  `MacClippyGlobalHotKeyDescriptor`. Persist `keyCode`/`modifiers` as `UInt32` under new keys
  (e.g. `com.macallyouneed.macclippy.hotkey.keyCode` / `.modifiers`), matching the existing key
  naming convention in `MacClippyRetentionPreferences`. `load(from:)` falls back to
  `.defaultClipboard` when either key is absent.
- Change `MacClippyGlobalHotKey.descriptor` from `let` to `var` (private(set)) and add
  `func update(to newDescriptor: MacClippyGlobalHotKeyDescriptor) throws` that unregisters the
  current registration, updates the stored descriptor, and re-registers — reusing the existing
  `register()`/`unregister()` bodies rather than duplicating Carbon calls.
- `MacClippyApp.swift:22-23` — change `descriptor: .defaultClipboard` to
  `descriptor: .load(from: .standard)` so a persisted custom hotkey survives relaunch.

### Step 2 — Hotkey recorder view

New file: `MacClippyKit/Sources/MacClippyPlatform/MacClippyHotKeyRecorder.swift` (or under
`MacClippy/` if it needs AppKit/SwiftUI bridging that doesn't belong in the platform package —
decide based on existing conventions, check whether `MacClippyPlatform` already imports SwiftUI
anywhere before placing a SwiftUI-facing view there).

- A view (`NSViewRepresentable` wrapping a custom `NSTextField`/`NSView`, or a pure SwiftUI view
  using a local `NSEvent` monitor while focused — pick whichever fits this codebase's existing
  patterns for capturing raw key events, e.g. reference how `MacClippyDockController` installs
  local key monitors) that:
  - Displays the current shortcut's symbolic representation (e.g. "⌘⇧V") when idle, plus a small
    "×" clear affordance.
  - On click, enters a "recording" state (visually distinct border/background) and captures the
    next keyDown with at least one modifier key. Reject modifier-only or no-modifier combinations
    silently (keep waiting) rather than accepting an invalid shortcut.
  - Esc cancels recording without changing the stored value.
  - On a valid capture, converts the `NSEvent` keyCode/modifierFlags to Carbon
    keyCode/modifiers (reuse or mirror whatever conversion already exists in
    `MacClippyGlobalHotKey`/`MacClippyDockInputPolicy` for keyCode handling — do not invent a
    second keyCode mapping table if one is reusable), calls
    `MacClippyGlobalHotKeyDescriptor.save(...)`, and invokes a caller-supplied `onChange`
    closure with the new descriptor so the app layer can re-register live.

### Step 3 — Settings window becomes tabbed

File: `MacClippy/MacClippySettings.swift`

- Restructure `MacClippySettingsView` into a `TabView` (or equivalent) with two tabs: "General"
  and "Shortcuts". Keep the tab styling consistent with a native macOS Settings window (check
  `.tabViewStyle(...)` options available in the SwiftUI version this project targets — read
  `project.yml`'s deployment target, already known to be macOS 14+ — and pick an appropriate
  style).
- **General tab**: move the existing four sections (History, Privacy, Permissions, Startup)
  in verbatim — no behavior changes to any existing `@AppStorage` binding, Stepper, Toggle,
  TextField, or button action. Add one new section, "Snippets", with a `Picker` (segmented or
  menu style, your judgement) bound via `@AppStorage(MacClippySnippetExpansionSettings.modeKey)`
  to a `String` raw value, offering the three `MacClippySnippetExpansionMode` cases
  (`.autoExpand`/`.confirmWithTab`/`.disabled`) with human-readable labels. Read
  `MacClippySnippetExpansionSettings.swift` fully first to get the exact case names and any
  existing display-name helper before wiring the picker.
- **Shortcuts tab**: a single row — "Toggle dock" label + the new `MacClippyHotKeyRecorder` from
  Step 2, bound to the current persisted descriptor
  (`MacClippyGlobalHotKeyDescriptor.load(from: .standard)` on appear) with an `onChange` closure
  that saves the new descriptor and notifies the app layer to re-register (see Step 5 for the
  exact notification mechanism — read that step before wiring this closure so both ends agree on
  the same signal).
- Preserve the window's overall sizing convention (`.frame(width:height:)`) — adjust dimensions
  only if the tab bar requires it structurally, not for arbitrary polish.

### Step 4 — Entry point

File: `MacClippy/MacClippyDock.swift`

- Replace `showAboutPanel()`'s body (the `NSAlert` construction and `NSApp.runModal` call) with:
  ```swift
  NSApp.sendAction(#selector(NSApplication.showSettingsWindow(_:)), to: nil, from: nil)
  ```
- Update the gear button's `.help(...)` tooltip from `"About Mac Clippy"` to `"Settings"`
  (`~line 2120`). Leave the icon (`"gearshape"`) and button placement unchanged.
- If `showAboutPanel()` becomes trivially a one-line wrapper with no other callers, you may inline
  it at the call site or leave it as a thin named function — whichever keeps the diff smaller and
  matches this file's existing style for similar single-purpose action methods.

### Step 5 — Live hotkey re-registration

File: `MacClippy/MacClippyApp.swift`

- Add a mechanism for the Settings window's Shortcuts tab to trigger re-registration when the user
  records a new hotkey, using `MacClippyGlobalHotKey.update(to:)` from Step 1. Two viable
  approaches — pick the one with the smaller, more idiomatic diff for this codebase after reading
  how `MacClippyApp` currently wires callbacks/notifications between the app delegate and SwiftUI
  views (check how `launchAtLogin`/other cross-cutting state is currently threaded, if at all):
  (a) a `NotificationCenter` post from the recorder's `onChange` closure, observed in
      `MacClippyApp.swift`, calling `try? clipboardHotKey.update(to: newDescriptor)`; or
  (b) exposing the running `MacClippyGlobalHotKey` instance (or a thin wrapper) via environment /
      a shared singleton accessor that `MacClippySettingsView` can call directly.
  Do not silently swallow an `update(to:)` failure — if registration fails (e.g. conflicting
  system shortcut), surface an inline error message in the Shortcuts tab, mirroring the existing
  `launchAtLoginError` pattern in `MacClippySettingsView` (`~line 80, 143-145, 165-177`).

### Step 6 — Tests

- `MacClippyKit/Tests/MacClippyPlatformTests/` — add tests for
  `MacClippyGlobalHotKeyDescriptor.save`/`load` round-tripping through a test `UserDefaults`
  suite (do not pollute `.standard` in tests — use an isolated suite, check how other tests in
  this file/target isolate `UserDefaults`, e.g. `MacClippyDockTests.swift`'s temp-directory
  pattern for inspiration on isolation style, adapted for `UserDefaults`).
- If `MacClippyGlobalHotKey.update(to:)` has any testable pure logic separate from live Carbon
  registration (which can't be meaningfully unit-tested), test what's testable; do not attempt to
  test actual OS-level hotkey registration success/failure in CI.

## Verification

1. `swift test --package-path MacClippyKit`
2. `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`
3. `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`
4. Manual `make run` smoke test: click the gear button → Settings window opens (not an alert);
   General tab shows all prior settings plus Snippets picker; Shortcuts tab shows the current
   hotkey; click to record a new one, confirm it takes effect (old hotkey stops toggling the
   dock, new one does) without relaunching the app; relaunch the app and confirm the custom
   hotkey persisted.

## Sequencing and Review

- Steps 1 → 2 → 3 → 4 → 5 → 6, each dispatched to `builder-luna` as a separate, self-contained
  brief. The orchestrator reviews each diff before dispatching the next step.
- No commits or pushes without explicit request.

# Dock Category Fixes

Status: implementation plan approved with Kimi K3 review changes
Repository: `/Users/mingjie.wang/Documents/personal/mac-all-you-need/mac-clippy`
Implementation owner: `openai/gpt-5.6-luna`, reasoning effort `medium`
Review and verification owner: orchestrator

## User Problems

1. The create-category `+` button often needs multiple clicks.
2. The category composer should dismiss on outside click and reopen empty.
3. Composer typing and keyboard commands leak into the dock search/navigation.
4. Holding left/right should continuously move through cards.
5. Clipboard cards cannot be dragged onto another category.
6. Chosen category colors are persisted but not rendered on category pills.

The custom-label editor uses the same SwiftUI sheet and has the same keyboard
leak. It is included in this pass rather than knowingly shipping a twin bug.

## Verified Root Causes

- `MacClippyDock.swift:1860` presents `MacClippyCreateCategorySheet` using
  `.sheet` from a SwiftUI view hosted in the dock's borderless,
  `.nonactivatingPanel`.
- `MacClippyDockController.swift:462-477` restores dock keyboard ownership
  when the dock resigns key. The policy at `:30-38` restores for `.picker` and
  `.preview`, so a sheet can lose focus to the dock.
- `MacClippyDockController.swift:426-441` also routes local/global mouse and
  keyboard events. `closeIfOutside` at `:504-532` has no child-window/sheet
  containment check, so clicks in a sheet area outside the dock frame can hide
  the dock.
- `MacClippyDockPanel.sendEvent` and the controller's local key monitors both
  route picker keys. The key router's type-to-search branch is at
  `MacClippyDockInputPolicy.swift:175-183`; the arrow repeat guard is at
  `:145`.
- The two carousel `.highPriorityGesture(DragGesture(...))` blocks at
  `MacClippyDock.swift:2174-2180` and `:2237-2243` compete with card `.onDrag`.
- The drag session is an explicit risk: the app has `LSUIElement: true` in
  `project.yml:44`, and there is no `NSApp.activate` or
  `beginDraggingSession` call in the project. Removing the competing gesture
  must be tested manually before treating drag-and-drop as fixed.
- `MacClippyCategoryColorPolicy.color(for:)` is used by core policy/tests but
  not by the dock view. `filterPill` currently uses only neutral theme colors.

## Implementation Steps

### 1. Add modal keyboard ownership mode

Files:

- `MacClippyKit/Sources/MacClippyPlatform/MacClippyDockInputPolicy.swift`
- `MacClippy/MacClippyDockController.swift`
- `MacClippy/MacClippyDock.swift`

Changes:

- Add `.modal` to `MacClippyDockInteractionMode`.
- Add `.dismissModal` to `MacClippyDockKeyAction`.
- Make the router's first event branch handle `.modal`: key-up is `.native`;
  Esc is `.dismissModal`; all other key-down events are `.native`. This must
  precede Cmd+K, shortcuts, search append, and picker handling.
- Keep keyboard restoration limited to `.picker` and `.preview`; `.modal`
  must not trigger `takeKeyboardOwnership` or `makeFirstResponder` on the dock
  content view.
- Add `onModalPresentationChange` to `MacClippyDockView` and wire it through
  the controller. Entering modal mode sets `.modal`; dismissing restores picker
  mode and picker keyboard ownership.
- Route `.dismissModal` to the active modal dismissal action.

### 2. Replace both sheets with in-panel modal overlays

Files:

- `MacClippy/MacClippyDock.swift`
- `MacClippy/MacClippyDockController.swift`

Changes:

- Replace the category `.sheet` with an in-panel overlay consisting of a
  reduce-motion-aware scrim and composer card.
- Replace the label `.sheet` with the same overlay mechanism. Preserve the
  existing label outcome/save/clear behavior.
- Use explicit dismissal closures instead of `Environment.dismiss`.
- Keep modal state in the dock model, including a monotonically increasing
  presentation token. Apply `.id(token)` to each newly presented composer so
  its local text/color state is rebuilt on every presentation.
- Scrim tap dismisses only the modal, not the dock. Esc dismisses the modal.
- Category `+` calls a model presentation method synchronously so one click
  opens the overlay.
- `hide()` clears any modal state before the dock session ends.
- Do not add a child-window exception for the new overlays: they are inside the
  dock panel. The existing `closeIfOutside` child-window gap should remain
  documented for any future AppKit child window and the About alert, not be
  papered over as part of the overlay implementation.

### 3. Allow held arrow navigation

Files:

- `MacClippyKit/Sources/MacClippyPlatform/MacClippyDockInputPolicy.swift`
- `MacClippyKit/Tests/MacClippyPlatformTests/MacClippyDockInteractionPolicyTests.swift`

Changes:

- For plain left/right arrows, remove only the `!isRepeat` condition while
  retaining focus/modifier guards.
- Keep repeat suppression for Space and Return because they toggle/commit.
- Update both picker and preview repeat-arrow assertions. Rename/re-scope tests
  so they no longer claim repeats are consumed.

### 4. Unblock card drag-to-category

Files:

- `MacClippy/MacClippyDock.swift`
- `MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPlatformTests.swift`

Changes:

- Remove the two carousel high-priority swipe gestures that pre-empt card drag.
- Remove `MacClippyDockSwipePolicy` and its now-unused test only if no other
  references remain.
- Remove the view `onNavigate` property and the controller closure at
  `MacClippyDockController.swift:138-140`; keep the separate preview-chevron
  `onNavigate` at `:857`.
- Harden the card payload/drop acceptance with `UTType.utf8PlainText` while
  preserving the existing record-ID payload and `model.pin` path. This is
  interoperability hardening, not the proven root cause.
- Add a compact drag preview only if it can be implemented without introducing
  unrelated card rendering or async work.

Drag spike gate:

- After removing the competing gestures, build and manually test dragging a
  card from the non-active `LSUIElement` dock onto a category pill.
- If no drag session begins, stop and report it. Then implement the smallest
  platform-correct follow-up, likely explicit app activation or a drag proxy,
  and retest. Do not claim Step 4 fixed until a real drag session starts and
  the destination receives the record ID.

### 5. Render category colors

Files:

- `MacClippy/MacClippyRuntime.swift`
- `MacClippy/MacClippyDock.swift`

Changes:

- Add computed `colorHex` to `MacClippyPinboardEntry` using
  `MacClippyCategoryColorPolicy.color(for: board)`.
- Add optional `accentHex` to `filterPill`, passing it only for pinboard pills.
- Render a small color dot for category pills. Use the category color for the
  selected tint/border and drop-target border; retain neutral All/Snippets
  visuals.
- Do not hoist the file-private `Color(macClippyHex:)` extension; it is already
  visible throughout this file.

## Tests and Verification

Before any build, this plan must exist at this path.

1. Run focused package tests:
   `swift test --package-path MacClippyKit`
2. Run app tests through the project Makefile:
   `make test`
   This runs `xcodegen generate`, package tests, and the macOS Xcode test target.
3. Run a manual app check with `make run`:
   - one click opens category composer;
   - typing, arrows, Cmd keys, Return, and Esc stay within the active composer;
   - scrim click dismisses; reopening starts with empty category text;
   - label editor has the same isolated keyboard behavior;
   - held arrows continue to navigate;
   - category pill colors are visible and selected/drop states are tinted;
   - card drag actually starts, reaches the category pill, and pins the item.
4. If drag fails at the spike gate, add the platform follow-up and repeat the
   focused build/manual test before proceeding.

## Review Constraints

- Implementation is dispatched only to `openai/gpt-5.6-luna` with its configured
  `reasoningEffort: medium`.
- The orchestrator reviews the diff, checks for unrelated changes, runs the
  narrowest verification, and dispatches follow-up fixes to Luna when needed.
- Do not commit or push.

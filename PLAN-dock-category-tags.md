# Dock Category Tag UX Fixes (Round 2)

Status: approved
Repository: `/Users/mingjie.wang/Documents/personal/mac-all-you-need/mac-clippy`
Implementation owner: `builder-luna` subagent (`openai/gpt-5.6-luna`, `reasoningEffort: medium`) for every code step. The orchestrator does not write implementation code directly.
Review/verify owner: orchestrator, with `reviewer-kimi` (`fireworks/kimi-k3`) for independent review.

## User-Reported Problems

1. Drag-and-drop onto a category pill works, but there is no clear indicator that the drop succeeded.
2. Hovering over / dropping onto a pill is hard to see because the drag preview and weak drop-target styling obscure the pill row.
3. Category pills need a right-click menu: Rename, Delete, Change Color.
4. The `+` (create category) button still sometimes needs multiple clicks.

## Decisions Confirmed With User

- Delete removes the category only. Clipboard records already pinned to it are preserved and remain visible in All history. The confirmation copy must say this explicitly.
- Change Color is an inline swatch submenu inside the right-click context menu (no modal).
- Rename uses a modal editor (consistent with Create Category), not inline pill editing, because inline text editing inside the nonactivating dock panel is exactly the focus-stealing territory that caused the original keyboard-leak bugs.
- Delete confirmation is an in-panel confirm overlay reusing the existing `.modal` machinery, not `NSAlert`, because `closeIfOutside` (`MacClippyDockController.swift:504-532`) has no child-window exclusion and a separate alert window would be vulnerable to the same outside-click dismissal gap found in the previous round.

## Verified Root Causes

- **Issue 4 (`+` button):** `MacClippyDockPanel` is `.borderless + .nonactivatingPanel`. When it is not key at mouse-down, AppKit consumes the click to focus the window instead of delivering it to the button. `newCategoryButton` (`MacClippyDock.swift:2071-2085`) is a plain `Button` with `.buttonStyle(.plain)` and no first-click handling. `MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard` (`MacClippyDockController.swift:31-38`) excludes `.modal`, so nothing re-asserts key ownership while a modal is open, and the async retry in `takeKeyboardOwnership` (`:562-576`) lands on the next run-loop turn, after the click has already been swallowed.
- **Issue 2 (drop-target visibility):** the `.onDrag` preview is a large, near-opaque card that physically covers the pill rail during drag. Independently, `filterPill`'s `isDropTarget` styling (`:2095-2103`) is weaker than its own hover state (fill `cardColor.opacity(0.50)` vs hover `0.60`, 1pt border), so even without the ghost the drop target does not read as the dominant visual state.
- **Issue 1 (drop confirmation):** feedback does exist — `model.pin` fires `.pinnedTo` (`:1165`) rendered by `actionFeedbackView` in a top-trailing overlay (`:2153-2164`, 1.1s lifetime) — but it is positioned far from the pill that was dropped on and can render behind/away from where the user's attention and the drag ghost were.
- **Issue 3 (pill context menu):** `PinboardSnippetStores.swift` already has `rename` (`:55`), `mutate` (`:63`), and `delete` (`:94`) at the store layer, but `MacClippyRuntime` exposes only `createPinboard` (`:791`) and `pin` (`:797`) — no rename/color/delete wrappers, and no context menu is attached to pinboard pills anywhere in `MacClippyDock.swift`.

## Implementation Steps

All steps below are implemented by `builder-luna`, one focused dispatch per step, smallest correct diff, no unrelated refactors.

### Step 1 — `+` / gear button click reliability

Files: `MacClippy/MacClippyDock.swift`, `MacClippy/MacClippyDockController.swift`, `MacClippyTests/MacClippyDockTests.swift`.

- Add `.contentShape(Circle())` plus `.onTapGesture { model.presentCreateCategory() }` to `newCategoryButton` (`:2071-2085`) so the action fires on mouse-up regardless of whether the click also had to bring the panel to key status.
- Apply the same `.contentShape(Circle())` + explicit tap handling to the gear/About button (`:2028-2040`), which has the identical structural problem.
- Split `MacClippyDockKeyboardOwnershipPolicy`: `shouldRestoreKeyboard` (`:31-38`) should return `true` for `.modal` so `makeKeyAndOrderFront` still runs when the dock resigns key while a modal is open. `shouldRestoreFirstResponder` (`:40-42`) must continue to exclude `.modal` so the composer's `TextField`/`FocusState` keeps text focus and typed input never leaks to the dock's search field.
- Update `MacClippyDockTests.swift:20` (`testKeyboardOwnershipRestoresOnlyPickerAndPreviewModes`) to add explicit `.modal` assertions for both policy functions, reflecting the new split behavior.

### Step 2 — Drop-target visibility

Files: `MacClippy/MacClippyDock.swift`.

- Shrink and reduce the opacity of the `.onDrag` preview (card drag preview closure near `:2534+`) so it no longer visually covers the pill rail during a drag.
- Strengthen `filterPill`'s `isDropTarget` branch (`:2095-2103`) so it is unambiguously the strongest visual state on the rail: accent-tinted fill clearly above the hover fill, a thicker accent-colored stroke, and a small scale-up. Route any animated property through `MacClippyMotion.animation(..., reduceMotion:)` per project Reduce Motion rules.
- Leave All/Snippets pills neutral — they already pass `accentHex: nil` and must not gain a false drop-target treatment.

### Step 3 — Drop confirmation

Files: `MacClippy/MacClippyDock.swift`.

- Add `@State private var dropConfirmedPinboardID: RecordID?` beside `dropTargetPinboardID` (`:1656`).
- In `handleDrop` (`:2135-2151`), on the success path (after `model.pin` is called), set `dropConfirmedPinboardID` to the target pinboard's id and clear it automatically after a short, reduce-motion-aware duration (reuse `MacClippyMotion` timing tokens, do not invent a new one if an equivalent already exists).
- Add a third `filterPill` visual state for `dropConfirmedPinboardID == pinboard.id`: a brief accent pulse/flash distinct from both the resting and active drop-target states.
- Keep the existing `.pinnedTo` toast (`actionFeedbackView`, `:2153-2164`) and the pill's own count bump from `reload()` — this step adds a pill-local confirmation, it does not replace the existing toast.

### Step 4 — Pill right-click menu: Rename / Delete / Change Color

Files: `MacClippy/MacClippyRuntime.swift`, `MacClippy/MacClippyDock.swift`.

Runtime (next to `createPinboard`, `:791`):

- `renamePinboard(id: RecordID, to name: String) throws` → wraps `pinboardStore.rename(id:to:)`, inside `withStoreLock` (`:1790`).
- `setPinboardColor(id: RecordID, color: String) throws` → wraps `pinboardStore.mutate(id:) { $0.color = color }`, inside `withStoreLock`.
- `deletePinboard(id: RecordID) throws` → wraps `pinboardStore.delete(id:)`, inside `withStoreLock`. Must NOT touch `clipboardStore` or delete any records — deletion is category-only per the confirmed decision.

Model (`MacClippyDockModel`, following the existing `perform(_:onSuccess:)` + `reload()` pattern at `:1586-1601`):

- `renamePinboard(_ pinboard: MacClippyPinboardEntry, to name: String)`.
- `setPinboardColor(_ pinboard: MacClippyPinboardEntry, to color: String)`.
- `deletePinboard(_ pinboard: MacClippyPinboardEntry)` — after success, rely on the existing `reconcileSelectedTab()` (`:1545-1550`) to fall back to `.history` if the deleted board was selected; do not duplicate that logic.
- `presentRenameCategory(for pinboard: MacClippyPinboardEntry)` and `presentConfirmDeleteCategory(for pinboard: MacClippyPinboardEntry)`, mirroring `presentCreateCategory()` / `presentEditLabel(for:)` (`:538-546`) including the `modalPresentationToken` bump and `.id(token)` reset pattern already used for the other two modals.

Modal cases (`MacClippyDockModal`, `:33-36`):

- `renameCategory(pinboardID: RecordID, initialName: String, token: UInt)`.
- `confirmDeleteCategory(pinboardID: RecordID, name: String, token: UInt)`.

New editors (in the private editor section alongside `MacClippyEditLabelEditor` `:3024-3086` and `MacClippyCreateCategoryEditor` `:3088-3152`):

- **Rename editor** — modeled directly on `MacClippyEditLabelEditor`: prefilled `TextField`, Cancel/Save, `.keyboardShortcut(.cancelAction/.defaultAction)`, focused on appear. Calls `model.renamePinboard(...)` then `model.dismissModal()`.
- **Delete confirmation editor** — in-panel modal (not `NSAlert`): title referencing the category name, body text stating explicitly that clipboard items will remain in All history and only the category is removed, Cancel and destructive-styled Delete buttons. Delete calls `model.deletePinboard(...)` then `model.dismissModal()`.
- Wire both into `modalOverlay`'s `switch modal` (`:1891-1907`) alongside the existing two cases, each with `.id(token)`.

Context menu:

- Add `@ViewBuilder private func pinboardContextMenu(_ pinboard: MacClippyPinboardEntry) -> some View`, mirroring the structure of `snippetContextMenu` (`:2693-2707`) / `itemContextMenu`.
- Contents: `Button("Rename…") { model.presentRenameCategory(for: pinboard) }`; a `Menu("Change Color")` (or equivalent inline submenu) listing `MacClippyCategoryColorPolicy.palette` swatches, each calling `model.setPinboardColor(pinboard, to: color)` directly with no intermediate modal; `Divider()`; `Button("Delete", role: .destructive) { model.presentConfirmDeleteCategory(for: pinboard) }`.
- Attach via `.contextMenu { pinboardContextMenu(pinboard) }` on the pinboard `filterPill` inside the `ForEach(model.pinboards)` loop (`:1984-2008`), matching the existing `.contextMenu` usage pattern at `:2380` / `:2531`.

### Step 5 — Tests

Files: `MacClippyKit/Tests/MacClippyCoreTests/MacClippyCoreTests.swift`, `MacClippyTests/MacClippyRuntimeBatchTests.swift`, `MacClippyTests/MacClippyDockTests.swift`.

- Core: `PinboardStore.rename` persists the new name; `PinboardStore.mutate` persists a color change; `PinboardStore.delete` removes the board row and explicitly asserts referenced clipboard records are still present in the clipboard store afterward (locks the category-only delete semantics).
- Runtime: one test per new wrapper (`renamePinboard`, `setPinboardColor`, `deletePinboard`), using the existing harness (`MacClippyRuntimeBatchTests.swift:11-19`, `wait` helper at `:344`).
- Dock: extend the Step 1 keyboard-ownership `.modal` test coverage from this plan's Step 1 (do not duplicate — this is the same test file/edit).

## Verification

1. `swift test --package-path MacClippyKit`
2. `make test`
3. Manual `make run` smoke test:
   - click `+` repeatedly from a cold/unfocused dock state — every click opens the composer, no multi-click needed;
   - same check for the gear/About button;
   - drag a card toward a category pill — the rail stays visible under the drag ghost and the target pill is unambiguously highlighted;
   - drop and observe the pill-local confirmation pulse plus the existing `.pinnedTo` toast;
   - right-click a category pill — Rename opens a modal, saves, and dismisses; Change Color submenu applies immediately with no modal; Delete opens the in-panel confirm overlay, states items are preserved, and on confirm removes the category while the item remains visible in All history.

## Sequencing and Review

- Steps 1 → 2 → 3 → 4 → 5, each dispatched to `builder-luna` as a separate, self-contained brief.
- The orchestrator reviews each diff before dispatching the next step. Step 4 is the largest and may be split into a runtime/model dispatch followed by a UI dispatch.
- `reviewer-kimi` performs an independent read-only review of the cumulative diff before this round is considered complete.
- No commits or pushes without explicit request.

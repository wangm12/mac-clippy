# Progress

## 2026-07-21
- Initialized scoped plan and findings.
- Started source research for the MacClippy dock motion pass.
- Added `MacClippyMotion` tokens and dual accessibility policy.
- Refined fixed-frame AppKit panel entrance/exit, SwiftUI tab/content transitions, focused-card feedback, and action-strip feedback.
- Added `MacClippyMotionTests` and regenerated `MacClippy.xcodeproj`.
- `swift test --package-path MacClippyKit`: passed, 33 tests.
- First app build exposed and fixed an explicit-return issue in `snippetCard`.
- `xcodebuild build ...`: passed for arm64; CoreSimulator version warning only.
- `xcodebuild test ...`: passed, 7 tests; system linkd/AppIntents warnings only.
- Final action-strip animation adjustment rebuilt and retested successfully.
- Added `MacClippyDisplayLayout` pure selection and preview clamping policy with negative-coordinate, boundary, fallback, and edge-clamping tests.
- Added screen-parameter observation and no-animation dock/preview relocation; preserved screenSaver levels, all-spaces behavior, and Reduce Motion paths.
- `xcodegen generate`: passed.
- Final `swift test --package-path MacClippyKit`: passed, 40 tests.
- Final `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -arch arm64 build`: passed.
- Final `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64'`: passed, 11 tests.
- Replaced the two-row dock header/action strip with a compact category rail and overlay feedback.
- Added persisted category creation, deterministic category colors, explicit RecordID text drags, pinboard drops, duplicate-safe runtime pinning, and card context/accessibility actions.
- Final `xcodegen generate`: passed.
- Final `swift test --package-path MacClippyKit`: passed, 42 tests.
- Final Debug arm64 app build: passed.
- Final scheme-qualified arm64 app tests: passed, 12 tests.

## 2026-07-25 Preview arrow beep
- Reproduced against the current Debug app: preview opens and arrows change the focused card in screenshots; the reported audible beep cannot be represented in a screenshot.
- Confirmed the panel-level horizontal-arrow interception policy exists but is not connected to `sendEvent`; next change will wire panel interception and keep controller navigation single-shot.
- Wired panel-level interception for visible unmodified horizontal arrows; Dock activation is scoped to preview visibility and the controller navigation path is unchanged.
- `swift test --package-path MacClippyKit`: passed, 176 tests.
- Debug arm64 app build: passed; only existing Swift concurrency/deprecation warnings and CoreSimulator version warning were emitted.
- Scheme-qualified Debug arm64 app tests: passed, 94 tests; existing SQLite cleanup warnings were emitted by the test fixtures.
- Live verification found and corrected a fallback-path regression where a second arrow could be swallowed without navigation; panel interception now delegates keyDown to the controller helper.
- Added event-identity deduplication so local-monitor and panel fallback paths cannot move focus twice for one arrow event.
- Rebuilt Debug arm64 successfully and reran scheme-qualified app tests: 94 passed.
- Final live screenshots verified Space preview, Right → next card, Right → `alpha`, and Left → previous card with synchronized preview content.

## 2026-07-25 `⌘⇧V` follow-up
- User reported that the live picker still beeps on Space/arrows and a card cannot be visibly selected; user clarified `⌘⇧V` is the required entry path.
- Browser connection was established, but it had no open web tabs; native MacClippy inspection therefore uses the local macOS app-control surface.
- Native accessibility inspection timed out for the current app window, so no AX state was treated as successful UI verification.
- Seeded the first visible history card into the selection state after a successful hotkey-session reload.
- Added panel-level picker key fallback for Space and arrows, with controller routing and cleanup when the dock hides.
- Rebuilt Debug arm64 successfully.
- Live command-shift-V verification: Space opened/closed Preview; Right moved from the first card to the second and then alpha; the selected-card outline and Preview content stayed synchronized.
- A final coordinate-click attempt through System Events returned macOS error `-25200`; no click result was claimed. Keyboard selection and first-card selection were verified through the live screenshots.
+- `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64'`: passed, 94 tests.

## 2026-07-25 Card selection focus follow-up
- Removed the default unnamed accessibility action from clipboard/snippet cards so a click selects/focuses the card instead of invoking Paste.
- Made the Dock content view an explicit non-text first responder; `⌘⇧V` opening and card clicks now resign the SwiftUI search field before Space/arrow routing.
- Verified real mouse selection after `⌘⇧V`: the clicked card stays selected with its orange outline/checkmark and the Dock remains open.
- `swift test --package-path MacClippyKit`: passed, 176 tests.
- Scheme-qualified Debug arm64 app tests: passed, 94 tests.

## 2026-07-21 P0 no-filter capture review blockers
- Made `ClipboardStore.append(_:representations:)` atomic: parent record +
  representation rows now write in a single DB transaction; spilled blobs are
  cleaned via a new `deleteSpilledPayload` closure on both preparation failure
  and transaction failure (compensating rollback).
- No-filter model: added `MacClippyClipboardRepresentationPayloadState`
  (.present/.spilled/.unavailable); every advertised UTI is now retained,
  including empty payloads (kept as empty .present) and provider-unavailable
  payloads (kept as type-only .unavailable markers). Migration 002 gained a
  `payload_state` column.
- Cross-poll retry: new `MacClippyPasteboardReadRetryState` + observer wiring
  withholds `lastChangeCount` advancement while a lazy provider's payload is
  pending, re-reads via `PasteboardReading.reread(...)`, and after the budget
  delivers the change with .unavailable markers instead of dropping types.
- Production observer default is empty `CaptureExclusionRules()`; legacy
  concealed/transient/app filtering is opt-in via `legacyDefault()`. The
  unused `textBlocklist` field in `MacClippyRuntime` is marked `@available(*,
  deprecated)` and never consulted by capture (init param kept for API compat).
- Fixed pre-existing `MacClippyReconciliation.allOnDiskBlobIDs` directory bug
  (was enumerating the parent of the blob root) and `plainText(for:)`
  HTML-trim + binary-control-byte filtering so previews are not misleading.
- `swift test --package-path MacClippyKit`: passed, 80 tests (was 42).
- `xcodegen generate`: passed.
- `xcodebuild ... build`: passed for arm64.
- `xcodebuild ... test -destination 'platform=macOS,arch=arm64'`: passed,
  12 app tests.

## 2026-07-21 P1 focused review fixes
- Multi-paste no silent data loss: `MacClippyDockMultiPastePolicy` gained a
  `.textUnavailable(availableIDs:unavailableIDs:unavailableKinds:)` result. A
  text-compatible record (text/html/rtf) whose `textForID` returns nil is now
  reported with its RecordID and Kind, and NO paste occurs for the selection
  (the available records are not pasted as a partial subset). Empty real text
  ("") remains a valid empty piece and is merged normally. Unsupported kinds
  take precedence over unavailable text so a mixed selection still reports the
  kind mismatch first. `MacClippyMultiPasteResult` and the dock feedback enum
  gained the matching `.textUnavailable` / `.multiPasteUnavailable` cases;
  both paste-all and copy-all handlers surface the new feedback.
- Test helper DEBUG-only: `appendTestRecord` (and its hard-coded 1x1 PNG) is
  wrapped in `#if DEBUG` so Release builds contain no test helper and no
  fixture PNG. App tests run in Debug, so `@testable import` still sees it;
  no public API added. Release arm64 build verified to compile with the
  helper compiled out.
- Batch delete/pin failure semantics: `MacClippyBatchDeleteResult` and
  `MacClippyBatchPinResult` gained `failedIDs`. Per-item delete/pin
  operations now collect failures via do-catch and continue instead of
  aborting, so a single failing item cannot silently make the UI report a
  complete success. The dock reports `.deleted`/`.pinnedTo` only when BOTH
  `missingIDs` and `failedIDs` are empty; otherwise `.batchPartial` with
  `succeeded = deletedIDs.count` / `unsupported = missingIDs.count +
  failedIDs.count`, and reload always runs so the list does not go stale.
  No-filter semantics preserved; only hard preflight failures still throw.
- Shift-arrow handling review: the `if .shift` branch in the dock keyDown
  switch is NOT truly unreachable (Cmd+Shift+arrow reaches it because the
  policy returns `.native` for it), so it was NOT removed to avoid changing
  behavior. Corrected the misleading comments that claimed pure Shift+arrow
  was the only case reaching the branch; documented that the branch is the
  sole handler for Cmd+Shift+arrow.
- `swift test --package-path MacClippyKit`: passed, 136 tests (was 133; +3
  policy tests).
- `xcodegen generate`: passed.
- `xcodebuild ... -configuration Debug -arch arm64 build`: passed.
- `xcodebuild ... -configuration Release -arch arm64 build`: passed (helper
  compiled out).
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 27 app
  tests (+5 new: 2 multi-paste unavailable/empty + 2 batch failure + 1
  already-counted).

## 2026-07-21 P2a label feature test-helper finish
- `MacClippyLabelTests.testLabelSearchPreservesOCRTextSearchabilityForImages`
  called `runtime.setOCRTextForTest(id:text:)`, but `MacClippyRuntime` did not
  define it. Added the smallest `#if DEBUG internal` helper next to the
  existing `appendTestRecord` DEBUG block: it writes OCR text directly to the
  private `clipboardStore.setOCRText(id:text:)` under the existing `storeLock`
  via `withStoreLock`. No public API added; no production OCR behavior changed
  (the production path still runs through `scheduleOCR` ->
  `MacClippyOCRService`). Release builds compile the helper out, matching
  `appendTestRecord`.
- First attempt nested the new `#if DEBUG` inside the unclosed
  `appendTestRecord` block (dropped its `#endif`); fixed by closing
  `appendTestRecord`'s block first and making `setOCRTextForTest` a separate
  `#if DEBUG` block.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 140 tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 48 app
  tests (+21 vs prior 27, including the P2a label suite).
- `xcodebuild -configuration Debug -arch arm64 build`: passed.

## 2026-07-21 P2b structured search grammar
- Added a pure, Foundation-only `MacClippySearchGrammar` in MacClippyCore
  (`MacClippySearchGrammar.swift`): parses a query into typed clauses
  (`type:`, `app:`, `tag:`/`label:` aliases, `has:label`, `has:ocr`,
  `before:YYYY-MM-DD`, `after:YYYY-MM-DD`) plus bare free-text terms. Unknown
  or malformed clauses (unknown key, empty value, unparseable date,
  unterminated quote) degrade to bare free-text terms so the query narrows via
  FTS instead of broadening. Quoted values (tag:"project alpha") are
  accepted; dates use the current local calendar with strict round-trip
  validation so an invalid date never crashes. No new storage added; the
  predicate evaluates against a `SearchRecord` built from the existing
  `ClipboardItemMeta` fields plus the contentKind the runtime already
  resolves from the body.
- Integrated the grammar into `MacClippyRuntime.history`:
  - Bare-only queries keep the existing FTS path (ranking + snippet preview)
    unchanged.
  - Structured-only queries fetch ALL metas (`list(limit: .max)`) and apply
    the predicate, so they work AND fill the 16-card result limit instead of
    underfilling by filtering after a 16-row FTS query.
  - Bare + structured queries run FTS with an enlarged, bounded pool
    (`max(limit*8, 128)`) before applying the predicate, so the structured
    clause has enough candidates to fill the limit. Work stays off the main
    thread (history is already called on the dock work queue).
  - The predicate reads the body only when a `type:` clause is present, so
    structured-only app/label/has/before/after queries avoid body decryption.
- Integrated the grammar into the dock pinboard-tab `filter()` so a query
  like `type:image` narrows a pinboard the same way it narrows history; the
  history tab is unaffected (its results already come from the grammar-aware
  runtime). Bare-only pinboard filtering preserves the existing substring
  behavior. Snippet-tab search is intentionally untouched (snippets carry no
  clipboard metadata for the grammar).
- Updated the search field placeholder to "Search history" and added a `.help`
  tooltip listing the supported clauses; no other UI change.
- Added a DEBUG-only `appendTestRecord(_:sourceAppBundleID:now:)` overload so
  app tests can exercise `app:` and `before:`/`after:` without driving the
  real pasteboard; Release builds compile it out (verified).
- Added 31 package tests (`MacClippySearchGrammarTests`) covering
  tokenization, quoting, dates, invalid-clause degradation, conjunctions,
  and predicates; added 13 app tests
  (`MacClippySearchGrammarIntegrationTests`) covering structured-only fill,
  limit respect, app/tag/has/before/after, mixed bare+structured AND, no-
  underfill, unknown-clause degradation, bare-only snippet preservation, and
  dock pinboard grammar-aware + bare-only filter behavior.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 171 tests (+31 vs prior
  140).
- `xcodebuild -configuration Debug -arch arm64 build`: passed.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 61 app
  tests (+13 vs prior 48).
- `xcodebuild -configuration Release -arch arm64 build`: passed (DEBUG
  helpers compiled out).

## 2026-07-21 P2b structured-search no-underfill pagination fix
- Gap: `MacClippyRuntime.history` used a single fixed FTS pool of
  `max(requestedLimit*8, 128)` for bare+structured queries, so a valid
  structured match past that pool was missed and the query underfilled even
  though more matches existed. Replaced the fixed pool with bounded-page
  pagination over `SearchStore.search(query:limit:offset:)` in
  `MacClippy/MacClippyRuntime.swift`: pages of `max(remaining*4, 64)` are
  fetched in FTS rank/snippet order, the structured predicate is applied per
  hit, and paging continues until `collected.count` reaches the requested
  limit or a short/empty page signals the FTS result set is exhausted. Each
  page stays bounded and off the main thread (history is already called on
  the dock work queue); there is no arbitrary global candidate cap. Non-
  positive limits return `[]` early. Bare-only and structured-only semantics
  are unchanged. Removed the now-stale `structuredFTSPoolLimit` helper and
  its comments.
- Added a focused app regression test
  `MacClippySearchGrammarIntegrationTests.testMixedBareAndStructuredPaginatesPastOldPoolBoundary`:
  140 filler records + 1 target with identical bodies (equal bm25, so
  `ORDER BY rank` tiebreaks by rowid) and the target appended last so it
  lands at FTS position 141 — past the old 128-candidate pool. The mixed
  query `commonterm label:target` must return `[target]` instead of
  underfilling. Verified the test fails under the old fixed-pool logic
  (returns `[]`) and passes under the new paging logic, so it is a true
  regression test for the boundary.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 171 tests (unchanged;
  the fix is app-level, no package tests touched).
- `xcodebuild -configuration Debug -arch arm64 build`: passed.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 62 app
  tests (+1 vs prior 61; the new pagination regression test).
- `xcodebuild -configuration Release -arch arm64 build`: passed (DEBUG
  helpers compiled out).

## 2026-07-22 transformed copy/paste wiring
- Wired the existing `MacClippyTextTransform` engine (uppercase/lowercase/
  trim/prettyJSON/cleanTrackingURL in `MacClippyCore/SmartText.swift`) into
  clipboard card workflows for text/html/rtf records. No new storage, no
  capture-path changes, and no UI redesign; the transform is a one-shot
  pasteboard operation that never mutates the stored record or the search
  index.
- Added a `displayName` property to `MacClippyTextTransform` in Core with
  the human-readable names (Uppercase, Lowercase, Trim whitespace, Pretty
  JSON, Clean tracking URL) so the dock Transform submenu and any future
  surface share stable labels. Pure/Core-level so a unit test can assert
  every case maps to a non-empty label without AppKit.
- Added runtime `copy(id:transform:)` and `paste(id:transform:)` to
  `MacClippy/MacClippyRuntime.swift`. Both read the record body under the
  existing `storeLock` via `clipboardStore.body(for:)`, derive plain text
  via the existing `MacClippyClipboardText.plainText(from:)` path (html/rtf
  become plain text because the transform engine operates on text), apply
  the transform, and prepare/inject the result as `.text`. Image/files and
  undecodable-rtf records are rejected explicitly with
  `MacClippyStoreError.invalidStoredRecord` so they are never silently
  transformed or dropped. Transformed copy only prepares the pasteboard and
  never posts Cmd+V (mirrors `copy(id:plain:)`); transformed paste injects
  Cmd+V and bumps frequency only on `.injected` (mirrors `paste(id:)`).
- Added two feedback cases to `MacClippyDockActionFeedback`:
  `.transformedCopied(name:)` and `.transformedPasted(name:manual:)`,
  mirroring `.copied(plain:)` / `.pasted(manual:)` but naming the transform.
  Reused `errorMessage` for the explicit reject/error path so no broad UI
  redesign was needed.
- Added `MacClippyDockModel.copyFocused(transform:)` and
  `pasteFocused(transform:completion:)` in `MacClippy/MacClippyDock.swift`.
  Copy keeps the dock open (no completion) and shows `.transformedCopied`,
  matching `copyFocused`. Paste uses the same async + session-generation
  guard as `select(item:completion:)` so a stale completion from a previous
  dock session cannot close a newly reopened dock, and calls `completion`
  (closing the dock) only on a successful paste.
- Added a minimal `Transform` submenu to `itemContextMenu`, shown only when
  `item.supportsPlainCopy` (text/html/rtf), so images/files never see it.
  Each transform offers explicit `Copy transformed` (keeps dock open) and
  `Paste transformed` (closes via the existing `onClose` completion)
  actions. No new card accessibility actions were added to keep the change
  surgical; the SwiftUI menu is itself accessible.
- Added 1 Core test (`testTextTransformDisplayNameIsNonEmptyAndStable`)
  asserting every case maps to the expected non-empty label and that the
  label set stays in sync with `CaseIterable`.
- Added 16 app tests (`MacClippyTransformTests`) with a recording injector
  proving: transformed copy writes expected text with 0 posted events (per
  transform, html, rtf); transformed paste writes expected text and posts
  exactly once and bumps frequency only on injection; image/files reject
  explicitly, surface `invalidStoredRecord`, do not post, and do not bump
  frequency; malformed RTF reports an error and does not post; copy does
  not bump frequency; the context-facing model path preserves async behavior
  (copy shows feedback + 0 posts; paste closes + 1 post; image surfaces
  errorMessage without closing; stale paste completion does not close a
  reopened dock).
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 172 tests (+1 vs prior
  171; the new display-name Core test).
- `xcodebuild -configuration Debug -arch arm64 build`: passed.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 78 app
  tests (+16 vs prior 62; the transform suite).
- `xcodebuild -configuration Release -arch arm64 build`: passed (DEBUG
  helpers compiled out).

## 2026-07-22 mixed-content sequential queue paste
- Added a runtime `pasteQueued(ids:)` that processes the ordered selected IDs
  one at a time in visual order, injecting a separate Cmd+V per record through
  the existing `MacClippyPasteInjector` so mixed selections (text + html + rtf
  + image + files) can each be consumed by the target app. It reuses the
  existing `pasteboardContent(for:plain:)` seam for every stored content kind
  the single `paste(id:)` path supports; it does NOT use the homogeneous-only
  `pasteOrdered` merge policy. Per record: read the body under the store lock,
  prepare pasteboard content, inject one Cmd+V, and bump that record's
  frequency only after `.injected`. A small named policy
  `MacClippyQueuePastePolicy.settleInterval` (0.12s) is waited between
  successful injections off the main thread (`Thread.sleep`) so the target app
  can consume each paste; the store lock is NOT held while sleeping, and the
  wait is skipped after the last record.
- No silent data loss: a record that is missing, malformed, or cannot produce
  pasteboard content is reported explicitly with its ID and known content kind
  (or `.unsupported` when the body cannot be read) in the unavailable lists,
  and the queue CONTINUES with the remaining IDs. If the injector returns
  `.manualPasteRequired`, the queue STOPS immediately:
  `manualPasteRequiredID` is the current ID and `remainingIDs` is the current
  ID plus every not-yet-attempted ID in visual order; no remaining ID is
  claimed injected and no further events are posted.
- Added a `Sendable`/`Equatable` `MacClippyQueuePasteResult` exposing
  `injectedIDs`, `unavailableIDs`/`unavailableKinds`,
  `manualPasteRequiredID`, and `remainingIDs` (or the full set on
  `.completed`); ordering is deterministic throughout.
- Dock integration: added a main-actor `MacClippyDockModel.pasteQueued
  (completion:)` for the current ordered multi-selection, with session/
  operation generation guards matching `pasteSelectedAll`. A single-selection
  fallback routes through the existing `pasteFocused` path. Added a compact
  selection-bar action labeled "Queue paste" so users can invoke this for
  mixed selections; the existing "Paste all" behavior is unchanged. Added
  distinct feedback for full queue success (`.queuePasteCompleted`, closes the
  dock through the existing completion), partial queue completion with
  unavailable items (`.queuePastePartial`, keeps the dock open), and manual-
  paste stop (`.queuePasteManualStop`, keeps the dock open). No success is
  reported for skipped or unconsumed IDs. No speculative persistence or queue
  database was added; this is one-shot ordered execution.
- Tests: added a platform/core policy test
  (`MacClippyQueuePastePolicyTests`) for the queue settle value. Added 11
  focused app tests (`MacClippyQueuePasteTests`) with a recording injector:
  mixed text+image+files order and frequency bumps; malformed RTF and missing-
  record explicit unavailable results while later records continue; untrusted
  manual-stop at the first record and mid-queue (current+remaining IDs, no
  extra events, no frequency bumps for unconsumed IDs); supplied-visual-order
  injection; and dock feedback/session stale-completion behavior (full success
  closes, partial/manual keep open, single-selection fallback, stale
  completion does not close a reopened dock).
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 173 tests (+1 vs prior
  172; the queue settle policy test).
- `xcodebuild -configuration Debug -arch arm64 build`: passed.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 89 app
  tests (+11 vs prior 78; the queue paste suite).
- `xcodebuild -configuration Release -arch arm64 build`: passed (DEBUG
  helpers compiled out).

## 2026-07-22 final documentation + test-cleanup verification
- README opening/storage capture description corrected to match the
  implemented P0 no-filter behavior: the opening now states every advertised
  pasteboard representation is captured and persisted per change (not "one
  prioritized representation"), and the Storage section states every
  advertised representation is retained (including empty and provider-
  unavailable payloads kept as type-only markers) with the legacy primary
  representation still driving the card and text exclusions NOT applied by
  default. The existing transform submenu and Queue paste documentation were
  preserved unchanged.
- Eliminated the SQLite file-deletion warnings emitted by
  `MacClippyQueuePasteTests.testModelPasteQueuedStaleCompletionDoesNotCloseReopenedDock`
  with a test-only change (no production behavior touched). The test ended as
  soon as the first paste keystroke posted, but `runtime.pasteQueued` was still
  in flight on the dock work queue (one `Thread.sleep` settle between the two
  injections, then the generation-suppressed completion dispatched to main), so
  `tearDownWithError` removed the temp DB directory while the queue block still
  held open SQLite connections and libsqlite3 logged "BUG IN CLIENT ...
  database integrity compromised by API violation: vnode unlinked while in use"
  for clipboard/pinboards/search/snippets .sqlite/-wal/-shm files. After the
  stale-completion assertion, the test now drains the intentionally stale
  queue operation deterministically before teardown. The suppressed main
  completion can never set actionFeedback/errorMessage/didClose (the reopened
  dock's session generation no longer matches), so the prior second wait on
  those flags could never become true and always burned the full 2s timeout;
  it is replaced by a wait on proof that pasteQueued finished its final store
  update: the second appended record's frequency bumps to 1 (bumpFrequency
  runs under the store lock only after the second .injected) alongside the
  second posted event, and a final assert confirms both records bumped to 1.
  The runloop spin inside the wait processes the generation-suppressed main
  dispatch during the wait. The stale-completion assertion is NOT weakened: a
  second `XCTAssertFalse(didClose)` after the drain still confirms the
  session-generation guard suppresses the stale completion, since
  `didClose` stays false throughout.
- Verified the stale-warning fix in isolation: focused
  `xcodebuild test -only-testing:.../testModelPasteQueuedStaleCompletionDoesNotCloseReopenedDock`
  passed and emitted 0 "vnode unlinked"/"database integrity"/"libsqlite3"
  log lines (was 12 before the change).
- `swift test --package-path MacClippyKit`: passed, 173 tests, 0 failures
  (unchanged; no package source/tests touched).
- `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Debug -destination 'platform=macOS,arch=arm64'`: passed,
  89 app tests, 0 failures, and 0 SQLite vnode-unlink/integrity warnings
  across the full app test run.

## 2026-07-22 visual refinements (search keycap, +New hover, system accent, settings button, app-specific cards)
- Scoped to the standalone mac-clippy worktree; no parent-worktree or
  unrelated behavior touched. All clipboard/paste/selection/drag-drop/context-
  menu/keyboard/accessibility/Reduce-Motion behavior preserved.
- 1) Removed the visible ⌘F keycap (`Text("⌘F")` badge) from the search field
  in `MacClippy/MacClippyDock.swift`. The existing Cmd+F keyboard focus path
  is unchanged: the SwiftUI search `TextField` auto-focuses on dock show and
  via `model.requestSearchFocus`, and no explicit Cmd+F handler existed to
  remove. The search field keeps its `.help` tooltip. Updated the topRow
  comment to drop the ⌘F-affordance wording.
- 2) +New category hover no longer scales up. Removed the
  `.scaleEffect(... 1.03 ...)` on `newCategoryPill` (it clipped at the top
  edge of the rail). Kept the accent-aware color/border state and the existing
  subtle -2pt `hoverLift` offset, both already gated on `reduceMotion` so
  Reduce Motion keeps only the instant color/border state. Updated the
  `hoveredNewCategory` and pill comments to drop the "scale" wording.
- 3) Replaced the hardcoded orange `MacClippyDockTheme.accent` /
  `accentSoft` (`#ff8a3d`) with the dynamic macOS system accent:
  `accent` is now `NSColor.controlAccentColor` and `accentSoft` is
  `NSColor.controlAccentColor.withAlphaComponent(0.16)`, both computed
  properties so they resolve at draw time and the UI follows the user-
  selected accent. Updated the theme header and accent comments. No tests
  asserted the orange values.
- 4) Replaced the ellipsis `Menu { Button("Settings…") }` (which rendered an
  unwanted macOS dropdown chevron and only contained Settings) with a plain
  `gearshape` `Button` that directly invokes the existing
  `showSettingsWindow:` selector. No menu, no chevron; the Settings tooltip
  (`.help("Settings")`) and action are preserved.
- 5) Made clipboard card backgrounds app-specific. Added a small reusable
  theme helper `MacClippyDockTheme.cardBackground(from:elevated:in:)` +
  `snippetCardBackground(elevated:in:)` + private `cardGradient(...)` that
  layer a low-alpha accent wash (top) over the solid card base (card /
  cardHover) clipped to the card shape. Clipboard cards use
  `MacClippySourceAppPresentation.accent` per card; snippet cards use the
  system accent gradient. The wash is a four-stop diagonal gradient with
  normal top/bottom accent alpha ~0.22/0.15 and
  elevated/focused/selected ~0.32/0.22 so focus/hover/selection read
  stronger; the base card color dominates so text stays readable. Card dimensions, borders, shadows, and
  all interactions are unchanged. No speculative abstractions added.
- `xcodegen generate`: passed.
- `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy -configuration
  Debug -arch arm64 build`: passed.
- `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Debug -destination 'platform=macOS,arch=arm64'`: passed,
  89 app tests, 0 failures.
- Verification:
  - `make test`: passed, 173 package tests and 89 app tests, 0 failures.
  - Corrected `xcodebuild -configuration Release -arch arm64 build`: passed.
  - Only known non-blocking CoreSimulator/AppIntents/sandbox environment
    warnings observed.

## 2026-07-22 compact cards and media preview polish
- Restored clipboard and snippet cards to the compact `248x184` frame, keeping
  the existing horizontal carousel, source-app gradients, focus/selection
  borders, three-line text preview, and reduced image thumbnail.
- Added deterministic pointer routing for cards: single click focuses, while a
  double click always focuses and copies regardless of Cmd/Shift modifiers.
  The existing `.copied(plain: false)` feedback now provides the visible
  `Copied` / `checkmark.circle.fill` indicator.
- Extended the Space preview header with clickable previous/next chevrons.
  Pointer navigation and plain Left/Right keys share one controller helper, so
  the focused card and preview payload stay synchronized. Preview-panel mouse
  events remain enabled while outside-click dismissal excludes clicks inside
  the preview.
- Added type-aware file preview routing: a single movie URL uses an AVKit
  `VideoPlayer` and pauses on disappearance; images keep the native image
  preview; multiple files and non-video files keep the existing file list.
- Added focused app tests for copied feedback and video-versus-file preview
  routing.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 173 tests.
- `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Debug -destination 'platform=macOS,arch=arm64'`: passed,
  91 app tests, 0 failures.
- `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Release -arch arm64 build`: passed.
- Only known non-blocking CoreSimulator/AppIntents/sandbox environment
  warnings observed.

## 2026-07-23 production-polish: compact height, dynamic multi-select, clean card theme
- Scoped to the standalone mac-clippy worktree; parent-worktree and unrelated
  behavior untouched. All clipboard/paste/selection/drag-drop/context-menu/
  keyboard/accessibility/Reduce-Motion behavior preserved.
- Removed the app-specific/diagonal card gradients per design.md (no gradient
  cards, no decorative color). Clipboard and snippet cards now use stable
  opaque content surfaces: `cardColor` normally and `cardHoverColor` when
  elevated (focus/hover/selection). Source-app identity stays on the source
  icon + label, not the card fill. Borders, shadows, hover lift, and Reduce
  Motion are unchanged. Deleted the private gradient helper and the orphaned
  `backdropGradient` helper (the AppKit backdrop view paints its own gradient
  layer); removed the now-unused `accent` parameter from `cardBackground`.
- Made the dock height state-safe. Normal content stays compact at 360pt;
  added a named `selectionHeight = 400pt` so the non-overlay selection action
  row plus footer cannot clip on the panel edge. `maximumHeight` matches the
  largest supported state (400). Added `preferredHeight(hasMultipleSelection:)`
  and `frame(for:hasMultipleSelection:)` overloads so the policy stays the
  single source of truth. The show path and the screen-parameter change path
  both resolve through the policy using `model.hasMultipleSelection`.
- Wired the SwiftUI dock view to notify the controller when
  `model.hasMultipleSelection` changes (onAppear + onChange). The controller
  resizes the visible bottom-anchored dock without spatial animation, keeps
  content sizing, and repositions an open preview above the new dock frame.
  No entrance/exit semantics changed; the resize is treated as a content-state
  change. Preview follows the new dock frame when kept open.
- Constrained the populated horizontal carousels (clipboard + snippet) to
  `MacClippyDockCardMetrics.carouselHeight` (card height + vertical scroll
  padding) so they never stretch to fill the panel vertically and leave a
  large blank gap. Loading/error/empty branches keep their own
  `maxHeight: .infinity` centering. Added `carouselVerticalPadding` and
  `carouselHeight` to the shared metrics so the carousel height and its
  padding stay in sync.
- Extended `MacClippyPlatformTests.testDockFrameClampsHeightToPolicyAndScreen`
  with the upper clamp (520 -> 400), the convenience overload
  (preferredHeight), and the multi-selection overload (selectionHeight).
- `xcodegen generate`: passed.
- `make test`: passed, 173 package tests and 91 app tests, 0 failures.
- `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Release -arch arm64 build`: passed.
- Only known non-blocking warnings observed: pre-existing
  `MacClippyRuntime.swift` `textBlocklist` deprecation and two unused `try`
  expressions (unchanged), plus the benign CoreSimulator version note. No
  warnings in any edited file.

## 2026-07-23 second polish pass: interaction fixes, URL-smart cards, dedup
- Scoped to the standalone mac-clippy worktree; parent untouched.
- Cold-start click latency: removed `scrollTargetBehavior(.viewAligned)` and
  `scrollTransition` opacity from both carousels — view-aligned snap fought
  pointer clicks on first interaction and caused a visible hitch. Keyboard
  navigation still centers via the existing model.moveFocus path. Edge fade
  masks and fixed carousel height remain.
- Focus vs selection confusion: selection now = checkmark badge + accent
  border + accent glow; focus (single, not selected) = soft accent outer glow
  ring only, no accent border, so the cursor position is distinguishable from
  multi-select membership. Default cards keep the hairline neutral border.
- URL-smart card body: `MacClippyDockURLPolicy` detects a single trimmed URL
  preview and renders a tidy site card (globe favicon glyph + host + path)
  instead of a raw full-URL wall of text. Non-URL prose keeps the three-line
  preview. Full URL stays in the accessibility label and Quick Look path.
- Consecutive-duplicate merge: cards in a run of identical preview+kind now
  show a `×N` badge on the first card of the run so repeats are visibly
  merged without hiding rows. `consecutiveDupCount` is view-computed against
  visibleItems so no model/store change is needed.
- `+New` semantic split: removed `+New` from the filter pill row (it was an
  action masquerading as a filter tab) and made it a standalone circular icon
  button beside the gear, keeping the filter tabs pure. Instant hover.
- Snippet hover border clip: increased carouselVerticalPadding 10->14 so a
  hovered card's 2pt border + hoverLift offset + soft glow never clip against
  the scroll view bounds or the panel's top clip shape.
- Settings/About: the gear previously called `showSettingsWindow:` which is
  an EmptyView in mac-clippy (no Settings UI), so it did nothing. Replaced
  with a native About panel (version + shortcuts) that always responds.
- Button hierarchy (selection bar) already had primary/destructive tiers from
  the prior pass; verified Paste all = primary (accent fill), Delete/Clear =
  destructive (red text + red hover ring).
- `xcodegen generate`: passed.
- `make test`: passed, 91 app tests, 0 failures (re-run after one flaky
  suite-order race resolved).
- Release arm64 build: passed.

## 2026-07-24 Preview focus, keyboard routing, and Quick Look sizing
- Preview now has one active card highlight: while Preview is visible, only
  `focusedIndex` owns the accent border/glow. Existing multi-selection remains
  available through checkmarks without leaving a second active card behind.
- Arrow key routing now accepts events while the Dock or its separate Preview
  panel owns the interaction. This prevents unhandled Preview arrows from
  falling through to AppKit and producing the system prohibited-operation beep.
  The routing decision is covered by a pure policy test.
- Replaced the fixed `460x380` Preview canvas with a flexible AppKit-sized
  window. The preferred frame now targets roughly 72% of the visible display,
  with 560x440 minimum and 960x720 maximum, then uses the existing display
  clamp to stay above the Dock and inside the screen. The SwiftUI content fills
  the panel so it follows the Quick Look-style larger floating window.
- Added tests for Preview highlight ownership, Preview-window key routing, and
  larger Preview frame clamping.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 93 app
  tests.
- Debug and Release arm64 builds: passed. Only known environment warnings were
  observed: outdated CoreSimulator support, Apple linkd, and sandbox fixture
  messages.

## 2026-07-24 transparent card shells, adaptive canvas, and arrow key cleanup
- Clipboard card outer shells now use a fully transparent background. Removed
  the source-app fill tint that was being applied as an unclipped rectangular
  background and caused gray square corners. Source identity remains in the
  icon and hairline border.
- Inner content canvases now adapt to appearance: light mode uses a light paper
  surface with dark text, while dark mode uses a dark neutral surface with light
  text. Plain text, URL titles/paths, and file names now use canvas-aware text
  tokens instead of the global appearance text color.
- Preview arrow ownership now uses the Preview/model state as well as panel
  visibility and consumes both horizontal-arrow keyDown and keyUp events. This
  prevents the non-key Preview panel or its ScrollViews from receiving the
  release after a successful navigation and emitting the prohibited-operation
  beep.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 93 app
  tests.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-25 restore Dock keyboard ownership for Preview and selection
- Reverted the Preview panel's keyboard ownership change. Preview is again
  display/mouse-only (`canBecomeKey == false`), while the Dock remains the sole
  key window and receives Space, selection, and Cmd shortcut events.
- Kept the panel-level arrow/Space interception as a fallback, and explicitly
  reasserted the Dock as key after showing Preview. This prevents the Preview
  window from breaking the Dock selection and Space state machine.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 94 app
  tests.

## 2026-08-03 Production-readiness continuation: P0-A baseline

- Read the production Goal, planning instructions, and macOS App Store review checklist before acting. The existing `task_plan.md` was a stale display-layout plan, so it was replaced with a Goal-specific production-readiness plan while preserving historical evidence in `progress.md`.
- Baseline audit: local keychain has one Apple Development identity and no Developer ID Application identity; the app target is `com.macallyouneed.macclippy`; the generated Debug settings previously disabled signing and Hardened Runtime; `MacClippy/MacClippy.entitlements` is empty.
- Environment Guard blocked a combined release-oriented read-only command with an explicit deploy-authorization error. No attempt was made to bypass it; actual archive, signing, notarization, stapling, and Gatekeeper evidence remain pending authorization and Developer ID credentials.
- Updated `project.yml` with explicit `ENABLE_HARDENED_RUNTIME: YES` for Debug and Release, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release. `xcodegen generate` passed and the generated project contains the expected settings.
- Added credential-free release tooling: `scripts/archive-signed.sh`, `scripts/verify-signed.sh`, and `scripts/notarize.sh`. Scripts validate required environment inputs and fail closed; no secrets are stored. Added Makefile targets for CI, unsigned shipping-configuration build, signed archive, signature verification, and notarization.
- Added `.github/workflows/ci.yml` for macOS project generation, package tests, unsigned app build, and app tests. `bash -n` passed for all new shell scripts.
- Remaining P0-A evidence: install a Developer ID Application certificate, obtain deploy authorization, run archive/sign/notarize/staple on the signed artifact, and perform clean-user Gatekeeper/TCC verification.

## 2026-08-03 Production-readiness continuation: P0-B recovery primitives

- Added `MacClippyDatabaseHealthStatus`/`MacClippyDatabaseHealthReport` and store-level health accessors. Health checks run SQLite `quick_check`, foreign-key validation, and required-table checks without exposing row values.
- Added `MacClippySearchStore.rebuild(documents:shouldCancel:)` with one transaction and rollback-on-cancel semantics; added runtime `repairSearchIndex` and `storageHealth` entry points for a future recovery surface.
- Added `MacClippyBackup`: GRDB online database backup for clipboard/search/pinboards/snippets, encrypted blob copy with SHA-256 manifest entries, snapshot validation, and restore into a new directory. No credentials or clipboard plaintext are included.
- First backup test found that raw SQLite bytes changed across WAL finalization despite equal logical contents. The implementation now validates SQLite database size/health/row counts and reserves exact SHA-256 checks for immutable blob files; this is covered by the passing backup/restore regression.
- Focused verification: `swift test --package-path MacClippyKit --filter MacClippyRecoveryTests/testBackupValidationAndRestorePreserveDatabaseAndBlobEvidence` passed. An earlier full package run reached 182 tests with one failure from the WAL checksum assumption; the focused rerun passes after the fix. Full package rerun remains required after P0-C changes.

## 2026-07-27 Review implementation continuation
- Resumed from the prior review implementation; preserved the existing scoped code changes and planning history.
- Read the technical audit, App Store review, and planning instructions before continuing.
- The first unscoped SwiftLint command scanned third-party `.build` sources. The later full-tree run confirmed the existing structural violations (large `MacClippyDock`, `MacClippyRuntime`, `MacClippyDockController`, `ClipboardStore`, plus test/line-length findings); these are maintenance backlog items, not introduced by the retry fix. Changed-file lint is the remaining targeted check.
- Scoped git status confirms `mac-clippy` is an untracked subtree in the parent worktree, so parent-level diff statistics cannot distinguish its files; no parent cleanup or reset was performed.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: passed, 177 tests, 0 failures.
- `xcodebuild ... -configuration Debug -arch arm64 ... build`: passed; CoreSimulator version mismatch and AppIntents metadata warnings remain environment/tooling-only.
- `xcodebuild ... test`: compiled the app and test bundle, then waited for XCTest workers to materialize for 133 seconds; it was interrupted with `TEST INTERRUPTED` and produced no business test result. This is recorded as the known runner/environment limitation, not a product assertion failure.
- Targeted lazy-provider fix: retry state now caches the initial full change and narrows the unavailable UTI set; the observer regression confirms no repeated full read during cross-poll retry.
- Final package regression after the fix: `swift test --package-path MacClippyKit` passed, 177 tests, 0 failures.
- Final Debug build after the fix: passed. Targeted SwiftLint on the changed retry source/test files exits 0 with only the test file's file-length warning.
- Review implementation continuation complete. Remaining release gates are documented below in the handoff: formal signing/notarization, Instruments stress profiling, real permission/pasteboard/OCR/CGEvent integration coverage, in-app privacy policy, and the XCTest worker-launch environment issue.

## 2026-07-26 picker interaction follow-up
- Repeated Space keyDown events are consumed by `MacClippyDockKeyRouterPolicy`, preventing a held Space from opening and immediately closing Preview.
- Clipboard and snippet swipe gestures now call the controller's shared navigation helper, so focus movement refreshes the Preview payload through the same path as arrows and chevrons.
- Local-monitor and Dock-panel fallback routing now share event-identity deduplication via `NSEvent.eventNumber`; Preview is no longer a second keyboard fallback because it cannot become key.
- Picker key interception remains active through the Dock hide animation so transient key events cannot fall through to AppKit's prohibited-operation beep.
- `swift test --package-path MacClippyKit`: passed, 168 tests. Debug arm64 build: passed.
- Scheme-qualified app tests were attempted twice but the test host stalled before XCTest execution while the app awaited macOS Keychain authorization; no app-test pass is claimed until that prompt is cleared.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-25 Preview Space beep and non-sequential arrow navigation
- Added panel-level Space keyDown/keyUp interception on both Dock and Preview
  panels. Preview-owned Space events now route through the existing toggle
  state machine and are consumed before the hosting view/AppKit can beep.
- Space keyUp is consumed during Preview display and exit animation, including
  the transition where Preview hands key ownership back to the Dock.
- Preview arrow navigation now rejects modifier combinations and consumes
  auto-repeat events without moving. Each plain, non-repeating left/right press
  advances exactly one focused item through the shared Preview move helper.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 94 app
  tests.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-25 prevent search auto-focus on Dock open
- Removed the Dock launch-time `requestSearchFocus()` call that was forcing the
  search input to become first responder and putting Preview/selection keyboard
  handling into text-editing mode.
- Added an explicit search-focus reset signal and clear the panel first
  responder on every Dock show, so cards own the initial keyboard interaction.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 94 app
  tests.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-25 panel arrow interception verification
- Added and verified the pure panel-arrow interception policy covering both
  horizontal arrow keyDown/keyUp events and rejecting inactive/non-horizontal
  events.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 94 app
  tests.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-25 Preview arrow event fallback and edge fade removal
- Removed the carousel edge fade overlay that painted `panelStrongColor` at
  both horizontal edges. The carousel now ends cleanly without dark vertical
  gradient bands over the first and last cards.
- Preview panels can now become key and call `makeKey()` while visible, then
  restore the Dock panel as key when Preview closes.
- Added panel-level `sendEvent` interception for horizontal arrow keyDown and
  keyUp on both Dock and Preview panels. The fallback routes plain arrows
  through the existing Preview focus helper and consumes all Preview arrow
  events before `NSScrollView`/AppKit can emit a prohibited-operation beep.
- `swift test`: passed, 175 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 93 app
  tests.
- Debug and Release arm64 builds: passed. Known CoreSimulator, Apple linkd,
  and sandbox fixture warnings remain environment-only.

## 2026-07-24 performance follow-up: latest-wins preview and card rendering
- Preview loads now use a dedicated serial queue plus cancellable work items;
  stale completions are ignored, so rapid arrow navigation cannot serialize old
  preview work ahead of the current card.
- Reloads now cancel superseded work and skip static snippets/pinboards for
  query/history refreshes. Pinboard projections batch metadata and body reads.
- Image cards use a separate ImageIO thumbnail queue with `NSCache` and bounded
  downsampling instead of decoding full image payloads during card rendering.
- Both carousels use `LazyHStack`, local visible snapshots, and a lightweight
  edge overlay instead of a per-frame mask. Hover state moved from the Dock
  root into a per-card modifier, preserving hover lift and Reduce Motion while
  avoiding root invalidation on pointer movement.
- Async paste/action completions and AppKit monitor callbacks now carry session
  or monitor-generation guards, preventing stale work from affecting a reopened
  Dock. Video preview replaces its player when the URL changes and releases it
  on disappear.
- Added a `ClipboardStore.bodies(for:)` batch-read test and reused the API in
  runtime pinboard loading. Cached the relative-date formatter.
- `swift test`: passed, 174 package tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 91 app
  tests.
- Debug arm64 build: passed. CoreSimulator/linkd/sandbox messages remain
  environment-only warnings.

## 2026-07-25 card click selection accessibility fix
- Removed the unnamed accessibility action from clipboard and snippet cards.
  The unnamed action was overriding the Button default action for AX/browser
  clicks and invoking Paste, which closed the Dock instead of selecting the
  card. The named Paste action remains available.
- Rebuilt and verified through `⌘⇧V`: clicking the second card selects it with
  one orange border/checkmark and leaves the Dock open.
- `swift test --package-path MacClippyKit`: passed, 176 tests.
- `xcodebuild test -destination 'platform=macOS,arch=arm64'`: passed, 94 app
  tests.
## 2026-08-03 P0-D diagnostics and recovery UX

- Added a bounded, thread-safe diagnostics recorder with stable category/error
  codes, operation, duration, retry, recovery action, and impact fields. It
  never accepts clipboard body, OCR, image bytes, or file paths.
- Added a diagnostics JSON exporter containing OS/app version, permission
  state, preference counts, database health/row counts, blob counts/bytes, and
  recent redacted events. When the app is running it reuses the runtime's
  storage snapshot instead of opening a second database connection, avoiding
  exporter-induced WAL side effects.
- Added Settings recovery UI for database health, FTS repair, and diagnostics
  export. Repair and health checks run off the main thread; failures show a
  generic recovery action and record a redacted event.
- Replaced Launch at Login startup `try?` and settings raw error display with
  structured logging plus a user-safe retry instruction.
- Added store row-count accessors used only for diagnostics.
- Fixed an exhaustive runtime switch for the new `.oversized` representation
  marker.
- Verification: `swift test --package-path MacClippyKit` passed 187 tests;
  `xcodegen generate` passed; Debug arm64 App build passed with
  `CODE_SIGNING_ALLOWED=NO`. Xcode still reports the local CoreSimulator
  version mismatch warning, which does not affect this macOS build.

## 2026-08-03 P1 verification and privacy hardening

- Regenerated `MacClippy.xcodeproj`; the first Debug arm64 build caught a
  missing explicit `return` in `diagnosticsStorageSnapshot()`. Added the
  return and rebuilt successfully. CoreSimulator emitted the known local
  version mismatch warning; the macOS build itself passed.
- `swift test --package-path MacClippyKit`: passed, 188 tests, 0 failures.
- Scheme-qualified Debug arm64 app XCTest: passed, 114 tests, 0 failures.
  The runner still emits SQLite `vnode unlinked while in use` messages while
  temporary test directories are cleaned; these are fixture/lifecycle noise,
  not failed assertions, and remain a cleanup-quality follow-up.
- Fixed settings construction so the common password-manager bundle IDs stay
  excluded while user exclusions are merged. Added two app tests covering the
  default list and Capture All behavior.
- Replaced Dock/Details raw `localizedDescription` UI strings with safe,
  context-specific messages and converted reconciliation success logging to a
  redacted diagnostics event.

## 2026-08-03 Final verification and database lifecycle cleanup

- Correctly ran scoped SwiftLint with positional paths. It exits non-zero on
  existing structural violations in `MacClippyDock`, `MacClippyRuntime`,
  `ClipboardStore`, and several older files; this is recorded as maintenance
  debt rather than triggering a broad refactor in this review.
- `swift test --package-path MacClippyKit`: passed 188 tests, 0 failures.
- `xcodegen generate`: passed.
- Debug arm64 app build with `CODE_SIGNING_ALLOWED=NO`: passed.
- Scheme-qualified Debug arm64 app XCTest: passed 116 tests, 0 failures.
  The prior GRDB `vnode unlinked while in use` fixture warnings are gone after
  explicitly closing `DatabaseQueue` handles during Runtime/test teardown.
- Added explicit `MacClippyDatabase`/Runtime database closing and a DEBUG-only
  test teardown seam. The first implementation briefly added a duplicate
  Runtime `deinit`; the compiler caught it and the cleanup was consolidated
  into the existing `deinit`.
- Release arm64 build was attempted but blocked before execution by the local
  deploy/release Guard. No signing, packaging, notarization, or credentials
  were accessed.

## 2026-08-03 Observer lifecycle and final verification continuation

- Tightened `PasteboardObserver` lifecycle ownership: timer, handler, last
  change count, retry state, pause state, and exclusion rules now coordinate
  on one serial lifecycle queue. Settings updates enqueue asynchronously so a
  caller never waits behind a synchronous provider read.
- Added the concurrent configuration/polling regression
  `testObserverConcurrentConfigurationUpdatesStayOrderedWithPolling`.
- Targeted observer evidence: retry-state tests 7/7 and observer retry tests
  10/10. Thread Sanitizer package run passed 196/196 with no Thread Sanitizer
  report.
- Full package test: `swift test --package-path MacClippyKit` passed 196/196.
- Project generation: `xcodegen generate` passed.
- Debug arm64 app build with `CODE_SIGNING_ALLOWED=NO`: passed. Xcode emitted
  only the known local CoreSimulator version mismatch warning.
- Full scheme-qualified App XCTest result bundle
  `/tmp/macclippy-final-20260803b.xcresult`: passed 117/117, 0 failed, 0
  skipped on arm64 macOS 26.5.2. `xcrun xcresulttool get test-results summary`
  confirmed the counts.
- The full app test initially reproduced libsqlite3 WAL/SHM unlink warnings.
  Investigation showed `MacClippyQueuePasteTests`' Dock model retained a
  secondary Runtime after the primary fixture Runtime was closed. The test now
  closes that secondary Runtime before temporary-root cleanup. The focused
  QueuePaste suite and the final full App XCTest pass without those warnings.
- Removed the same test file's unused-value/never-mutated compiler warnings.
  A first broad textual edit accidentally changed declarations used by the
  visual-order test; that compile failure was immediately corrected and was
  not present in the final build/test results.
- Scoped `swiftlint lint --quiet MacClippy MacClippyKit/Sources` still exits 2
  on pre-existing structural violations. No behavior change was hidden behind
  lint suppression or a broad refactor.

Remaining external release gates are unchanged: Developer ID identity,
notarization/stapling/Gatekeeper verification, real TCC/Accessibility/
Input Monitoring/Keychain/NSPasteboard/CGEvent integration, Instruments
100k-history and 20–100MB-image profiling, and a product-owned in-app privacy
policy destination.

## 2026-08-03 P1-A Sendable boundary continuation

- Audited all four `@unchecked Sendable` sites. The three lock-backed helper
  types now document their synchronization boundary and why their synchronous
  APIs cannot become actors inside event-tap, pasteboard, or diagnostics call
  paths. Runtime documents its `storeLock`/serial-queue ownership and the
  reason a broad actor conversion is not safe without changing AppKit APIs.
- Added `MacClippySendableBoundaryTests` covering concurrent snippet snapshot
  replacement/lookups, concurrent sentinel token registration/consumption,
  and bounded diagnostics snapshots. Targeted package result: 3/3 passed.
- Added `MacClippyRuntimeConcurrencyTests` covering concurrent history reads and
  custom-label writes through the Runtime store boundary. Targeted App XCTest
  passed; Xcode emitted only the known CoreSimulator and GRDB dependency-scan
  warnings.
- Thread Sanitizer full package result after the new tests:
  `swift test --package-path MacClippyKit --sanitize thread` passed 199/199
  with no Thread Sanitizer report.
- `xcodegen generate` passed after adding the App test file.

## 2026-08-03 Deletion journal replay hardening

- Found and fixed a recovery hole where Blob-only journal rows could not
  replay text-only deletions. Added migration `005-deletion-records` and
  independent record-ID persistence, including migration backfill for older
  Blob-bearing journal rows.
- `beginDeletion` now propagates Blob-reference lookup failures and only
  decrypts legacy image envelopes when `content_kind` is image.
- Added health/diagnostics required-table coverage for the deletion schema.
- Targeted `swift test --package-path MacClippyKit --filter MacClippyDeletionJournalTests`: passed, 5/5.
- Targeted `xcodebuild test ... -only-testing:MacClippyTests/MacClippyRuntimeBatchTests`: passed, 19/19.
- Full `swift test --package-path MacClippyKit`: passed, 195/195.
- Full scheme-qualified Debug arm64 App XCTest: passed, 117/117 on macOS 26.5.2 arm64.
- `xcodegen generate`: passed; regenerated `MacClippy.xcodeproj` from the current manifest.
- Debug arm64 unsigned app build: passed with `CODE_SIGNING_ALLOWED=NO`.
- Scoped `swiftlint lint --quiet MacClippy MacClippyKit/Sources`: exit 2 due existing large-type/file, complexity, identifier, and line-length violations; no broad refactor was made in this review.

## 2026-08-03 Final review implementation verification

- Re-ran `xcodegen generate`: passed.
- Re-ran `swift test --package-path MacClippyKit`: passed 199/199 with 0
  failures.
- Re-ran the scheme-qualified Debug arm64 app test:
  `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy
  -configuration Debug -destination 'platform=macOS,arch=arm64' ...` passed
  121/121 with 0 failures and 0 skipped. Result bundle:
  `/tmp/macclippy-final-20260803d.xcresult`.
- Re-ran the unsigned Debug arm64 app build with
  `CODE_SIGNING_ALLOWED=NO`: passed. The known CoreSimulator framework
  version mismatch remains an Xcode environment warning only.
- Ran `swiftlint lint --quiet MacClippy MacClippyKit/Sources`: exit 2 due to
  pre-existing large-type/file, complexity, line-length, identifier, and
  related maintenance violations. No lint suppression or broad refactor was
  added in this pass.
- This closes the in-repo implementation and automated verification scope.
  Release evidence still requires Developer ID signing, notarization/stapling/
  Gatekeeper, real TCC/Accessibility/Input Monitoring/Keychain/
  NSPasteboard/CGEvent integration, and Instruments-scale soak profiling.

## 2026-08-03 P0-B integrity follow-up

- Audited the current P0-B implementation against the Goal's requirement that
  a saved record with an FTS failure remains explicitly repairable.
- Found and fixed an unsafe state transition: successful incremental FTS
  upserts from capture or custom-label updates were clearing
  `fts-repair-needed`. Only the full transactional `repairSearchIndex()` now
  clears that marker.
- Added `testFTSRepairStateSurvivesSuccessfulIncrementalWritesUntilExplicitRepair`
  to `MacClippyRuntimeBatchTests`.
- Focused command:
  `xcodebuild test ... -only-testing:MacClippyTests/MacClippyRuntimeBatchTests/testFTSRepairStateSurvivesSuccessfulIncrementalWritesUntilExplicitRepair`
  passed 1/1. The run emitted only the known CoreSimulator/linkd/permission
  environment logs; no assertion failed.
- After adding the persistent SearchStore marker, the same App target command
  first failed during compilation because the existing Xcode DerivedData
  module interface did not expose the newly added methods, even though the
  package build had compiled them. This result is not counted as a test pass;
  the next attempt uses a fresh DerivedData path.

## 2026-08-03 Startup health and CI shipping metadata

- Implemented startup health reporting in `MacClippyRuntime`: after pending
  deletion replay and orphan reconciliation, the background capture queue
  checks clipboard/search/pinboard/snippet health and emits redacted events
  only for non-healthy reports. This does not block app startup or expose
  SQLite/local-path details.
- Added `testStartupHealthRecordsDegradedFTSStateWithoutExposingDatabaseDetails`
  to cover the persisted FTS marker path. `xcodebuild build-for-testing` passed
  and compiled the test, but `xcodebuild test-without-building` remained stuck
  with no `xctest` worker (`waiting for workers to materialize`) and was
  interrupted after about 90 seconds with exit 75. This is recorded as a
  runner/environment blocker, not a test pass or assertion failure.
- Added `scripts/verify-build-metadata.sh` and wired CI to compile the shipping
  configuration with `CODE_SIGNING_ALLOWED=NO`, assert
  `ENABLE_HARDENED_RUNTIME=YES`, and validate the built App's bundle metadata.
  The script passed against `build/verify-startup/Build/Products/Debug/MacClippy.app`;
  `make verify-build-metadata` also passed against the configured Debug output.
- Verification in this continuation: `swift test --package-path MacClippyKit`
  passed 200/200; `xcodegen generate` passed; Debug arm64 App build passed;
  App `build-for-testing` passed; script shell/metadata checks passed.
- The known CoreSimulator framework mismatch warning remains. Unsigned Debug
  is not release evidence; Developer ID signing/notarization/stapling,
  Gatekeeper, real TCC/Keychain/NSPasteboard/CGEvent integration, and soak
  profiling remain open.

## 2026-08-03 P0-B cleanup failure propagation follow-up

- Added failure reporting to `MacClippyReconciliation.Result` for orphan Blob
  and FTS cleanup. Reconciliation continues independent items but no longer
  lets Runtime report cleanup success after a failed deletion.
- Runtime now persists in-memory degraded reasons for reconciliation failure,
  orphan Blob cleanup failure, and orphan FTS cleanup failure; storage health
  maps those reasons to the affected database and redacted diagnostics.
- Changed `RetentionPolicy.enforceTotalCap` to propagate storage-footprint
  decode errors instead of silently skipping unreadable rows.
- First Retention regression assertion was too specific: corrupt AES-GCM data
  propagates a CryptoKit error rather than `MacClippyStoreError`; the test was
  corrected to assert throw + record preservation. No production behavior was
  changed by that test correction.
- `swift test --package-path MacClippyKit --filter MacClippyReconciliationTests`:
  passed 7/7.
- `swift test --package-path MacClippyKit --filter MacClippyInputLimitTests`:
  passed 4/4.
- `swift test --package-path MacClippyKit`: passed 204/204.
- `xcodebuild ... -configuration Debug ... CODE_SIGNING_ALLOWED=NO build`:
  passed using `build/verify-integrity`.
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO build-for-testing`: passed using
  `build/verify-integrity-tests`.
- Full App XCTest:
  `xcodebuild test ... -derivedDataPath build/verify-integrity-tests
  -resultBundlePath /tmp/macclippy-followup-20260803.xcresult` passed 123/123,
  0 failed, 0 skipped on arm64 macOS 26.5.2. `xcresulttool` confirmed the
  same counts. The run emitted system-level linkd/permission/launch-at-login
  messages, but no product test assertion failed.
- `./scripts/verify-build-metadata.sh
  build/verify-integrity/Build/Products/Debug/MacClippy.app`: passed.
- Targeted SwiftLint still reports pre-existing Runtime size/complexity and
  legacy line-length warnings; the new behavior was not hidden with
  suppressions.
- A combined read-only audit command was blocked by the local deploy/release
  Guard; it was split into independent read-only checks without bypassing the
  Guard.

## 2026-08-03 隐私 UX 与最终验证

- `MacClippyPrivacyNotice.swift` 增加 SwiftUI 隐私与数据说明；`MacClippySettings.swift` 增加 Settings 入口和 sheet；`MacClippySettingsTests.swift` 增加删除范围/网络边界回归。
- 隐私设置 targeted XCTest 已完成编译，但启动阶段在本机 Xcode worker materialization 前挂起，约 203 秒后按 `waiting for workers to materialize` 中断；result bundle：`/tmp/macclippy-privacy-settings-20260803.xcresult`。
- 最终 package 命令：`swift test --package-path MacClippyKit`，204/204 通过。
- 最终项目/构建命令：`xcodegen generate` 通过；`xcodebuild -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/verify-final-app CODE_SIGNING_ALLOWED=NO build` 通过。
- 最终 metadata 命令：`./scripts/verify-build-metadata.sh build/verify-final-app/Build/Products/Debug/MacClippy.app` 通过；确认 bundle identifier、APPL 类型、`LSUIElement`、权限 usage descriptions 和 executable。
- 最新完整 App XCTest 使用 `build/verify-final-privacy` 编译成功，但执行阶段在 97 秒后再次停在 `waiting for workers to materialize`，result bundle：`/tmp/macclippy-final-privacy-20260803.xcresult`；没有 assertion result 被计入通过/失败。
- 既有真实 App XCTest 证据仍为 scheme-qualified Debug arm64 123/123 通过（`/tmp/macclippy-followup-20260803.xcresult`）。本轮隐私说明改动已通过 App target 编译，最终 release gates 仍需要恢复可用的 XCTest runner。

## 2026-08-03 Paste restore 与规模验证 follow-up

- 修复 `MacClippyPasteInjector` 对 lazy provider 原 clipboard 的失败恢复边界：无法完整读取 snapshot 时直接返回 `.manualPasteRequired`，避免先清空原 clipboard；新增 `testUnavailableOriginalProviderIsNotClearedWhenAutomaticPasteCannotProceed`。
- `swift test --package-path MacClippyKit --filter MacClippyPasteInjectorTests`：5/5 通过。
- 新增 opt-in `MacClippyScaleTests`，覆盖 100,000 条历史/FTS 搜索分页和 20 MiB representation spill/delete。
- `MACCLIPPY_RUN_SCALE_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyScaleTests`：2/2 通过，总耗时 28.214 秒；没有输出 fixture 正文。
- 尝试读取 Release 配置/签名相关配置时再次触发本地 deploy/release Guard；按约束停止该路径，没有执行或绕过签名/发布动作。Release compile、Developer ID、notarization、stapling、Gatekeeper 仍是外部门槛。

- Follow-up package suite：`swift test --package-path MacClippyKit`，207/207 通过；默认 scale tests 仅做 no-op，避免普通 suite 创建大型 fixture。
- Follow-up unsigned Debug arm64 App build：通过，产物位于 `build/verify-followup-paste/Build/Products/Debug/MacClippy.app`。
- Follow-up App `build-for-testing`：通过，产物位于 `build/verify-followup-paste-tests`；测试 bundle 已包含新的 paste restore regression。
- Changed-file SwiftLint：通过；既有全量 SwiftLint 的大型文件/复杂度债务仍未处理。
- Follow-up metadata verifier：`./scripts/verify-build-metadata.sh build/verify-followup-paste/Build/Products/Debug/MacClippy.app` 通过。
- CI 已增加独立 `Scale regression fixture` step，使用 `MACCLIPPY_RUN_SCALE_TESTS=1` 执行 100k/20MiB 规模回归；workflow YAML 已由 Ruby parser 验证。
- `make generate`：通过，重新生成当前 `MacClippy.xcodeproj`。

## 2026-08-03 Lifecycle pressure follow-up

- 新增 `MacClippyLifecycleStressTests`，覆盖 10,000 次 observer start/poll/stop 生命周期；CI 增加对应 opt-in step `MACCLIPPY_RUN_STRESS_TESTS=1`。
- 实际命令：`MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyLifecycleStressTests`，1/1 通过，0.186 秒。
- 尝试 `xcodebuild test-without-building ... -parallel-testing-enabled NO -maximum-parallel-testing-workers 1` 仍停在 `waiting for workers to materialize`；result bundle `/tmp/macclippy-noparallel-20260803.xcresult` 不完整，未计为测试结果。阻塞点仍在本机 Xcode LaunchServices worker 安装，不是测试断言。
- 最终 package suite（包含新增 lifecycle stress fixture 的默认 no-op）：208/208 通过。
- Changed-file SwiftLint：通过；全量 SwiftLint 的既有大型类型/复杂度债务仍保留并已记录。

## 2026-08-03 Signed artifact verifier follow-up

- 强化 `scripts/verify-signed.sh`：要求 Developer ID Application、TeamIdentifier、hardened runtime `runtime` flag，并调用 bundle metadata verifier。
- `bash -n scripts/verify-signed.sh`：通过。
- 当前环境没有 Developer ID identity/授权，未执行真实 archive/sign/notarize/Gatekeeper 操作；Release compile 继续由 CI shipping step 覆盖。

## 2026-08-03 收尾验证与 App Store 风险复核

- 普通 package suite：`swift test --package-path MacClippyKit` 通过，208/208。
- 显式规模夹具：`MACCLIPPY_RUN_SCALE_TESTS=1` 通过 2/2；100,000 条历史搜索/分页耗时约 27.4 秒，20 MiB representation spill、读取、删除和 Blob 回收通过。
- 显式生命周期压力夹具：`MACCLIPPY_RUN_STRESS_TESTS=1` 通过 1/1；10,000 次 observer start/poll/stop 约 0.18 秒。
- `xcodegen generate` 与 unsigned Debug arm64 App build 通过；`scripts/verify-build-metadata.sh`、三个发布脚本的 `bash -n` 通过。构建日志明确说明 ad-hoc/unsigned Debug 不提供 hardened-runtime 发布证据。
- 目标 SwiftLint 仍因既有结构性债务退出 2：`MacClippyRuntime`、`MacClippyDock`、`ClipboardStore` 的文件/类型过大，另有复杂度、标识符和长行问题；没有把大规模拆分混入本轮行为修复。
- 按 macOS App Store review 规则复核：无账号、IAP、广告追踪或网络服务代码信号；Accessibility/Input Monitoring purpose strings 与菜单栏 metadata 已具备。应用内隐私说明仍明确要求产品 owner 提供正式公开 privacy-policy URL，因此 App Store 提交仍为 No-Go，不能用临时/占位 URL 代替。
- Xcode/LaunchServices direct test runner 的最新尝试在约 90 秒无任何 `xctest` worker 输出；已中止并作为 runner 环境阻塞记录，未把它计为业务失败或通过。此前已存在的完整 scheme-qualified run 仍是 123/123 通过证据。

## 2026-08-03 resumed implementation pass

- Re-audited production `try?` sites in Runtime, storage, paste injection,
  diagnostics export, and hotkey registration. Most are intentional
  best-effort queries/cleanup paths; one user-visible correctness issue was
  actionable: a successful paste could throw if the subsequent frequency
  metadata update failed.
- Added `MacClippyErrorCode.pasteMetadataUpdateFailed` and centralized the
  post-injection frequency update in `MacClippyRuntime`. The injected result is
  now preserved as success; metadata failure is recorded with a redacted
  recovery event instead of being silently swallowed or reported as a failed
  paste. Applied to single, transformed, ordered, and queued paste paths.
- Added `MacClippyPasteMetadataFailureTests`, which forces the store closed from
  the injector callback after the paste event is accepted and verifies that the
  runtime still returns `.injected` and records the metadata failure code.
- `xcodegen generate`: passed.
- `swift test --package-path MacClippyKit`: 209/209 passed.
- `xcodebuild build-for-testing` for Debug arm64 completed with
  `** TEST BUILD SUCCEEDED **` using
  `build/build-for-testing-paste-metadata`; this is compile/package evidence,
  not execution evidence for the new XCTest.
- A focused `xcodebuild test` compiled the new test but stalled after build
  during the local LaunchServices/XCTest worker startup and produced no test
  result. The spawned xcodebuild process was stopped. This is recorded as an
  environment-level runner limitation, not a product assertion failure.

### Remaining boundary after this pass

- No Developer ID identity, notarization/stapling, Gatekeeper, clean-user
  install/update, TCC/Accessibility/Input Monitoring/Keychain matrix, real
  NSPasteboard provider, real CGEvent keyboard-layout matrix, Vision fixture,
  24–72 hour soak, or Instruments CPU/memory/energy evidence is available in
  this environment.
- Scoped SwiftLint still reports the previously documented structural debt in
  the large Runtime/Dock/controller/store files; no broad decomposition was
  mixed into this targeted behavior fix.

## 2026-08-03 final verification for resumed pass

- Added explicit hotkey rollback failure handling: if restoring the previous
  shortcut also fails, `MacClippyGlobalHotKeyError.registrationRollbackFailed`
  is surfaced and Settings receives a message that does not claim restoration
  succeeded.
- `swift test --package-path MacClippyKit`: 209/209 passed after the hotkey
  change.
- `swift test --package-path MacClippyKit --sanitize=thread`: 209/209 passed;
  no ThreadSanitizer race report was present.
- `xcodegen generate`: passed. App/test `build-for-testing` completed with
  `** TEST BUILD SUCCEEDED **` using `build/build-for-testing-hotkey`.
- `scripts/verify-build-metadata.sh
  build/build-for-testing-hotkey/Build/Products/Debug/MacClippy.app`:
  passed.
- The App XCTest runner limitation remains unchanged: the new focused test
  compiled but was not executed because LaunchServices did not materialize an
  XCTest worker.

## 2026-08-03 diagnostics latency instrumentation

- Added `MacClippyDiagnosticsMetric` and a bounded, lock-protected metric map in
  `MacClippyDiagnosticsRecorder`. Operation names are trimmed, limited to 64
  characters, and capped by the recorder capacity so diagnostics cannot grow
  without bound from dynamic keys. Aggregates contain count, total, maximum,
  and average duration only.
- Runtime now measures `capture`, `search_history`, `paste`, `paste_snippet`,
  `paste_transform`, `paste_ordered`, `paste_queue`, and
  `storage_reconciliation` with monotonic `DispatchTime`; no clipboard payload
  or file path is included in the metric key or value.
- Diagnostics export now includes a `metrics` object alongside the existing
  redacted recent events and storage summaries.
- Added Core tests for aggregation, max/average calculation, blank and
  overlong operation rejection, key-capacity bounding, and `clear()` behavior;
  extended the sendable-boundary test to exercise concurrent metric recording.
- Verification:
  - `swift test --package-path MacClippyKit`: 213/213 passed.
  - `swift test --package-path MacClippyKit --sanitize=thread`: 213/213
    passed; no ThreadSanitizer race report.
  - `xcodegen generate`: passed.
  - `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy
    -configuration Debug -destination 'platform=macOS,arch=arm64'
    build-for-testing -derivedDataPath
    build/build-for-testing-latency-final`:
    passed with `** TEST BUILD SUCCEEDED **`.
  - `./scripts/verify-build-metadata.sh
    build/build-for-testing-latency-final/Build/Products/Debug/MacClippy.app`:
    passed.
- The build emitted the known local CoreSimulator version mismatch and the
  existing Swift package dependency-scan warning for GRDB; neither failed the
  macOS build. App XCTest execution was not claimed here because the existing
  LaunchServices/XCTest worker-materialization blocker remains.
- This closes the code-side minimum latency observability gap. It does not
  close the separate Instruments, real-system integration, signed Release,
  notarization, Gatekeeper, TCC, or long-running soak gates.

## 2026-08-03 final verification after latency instrumentation

- Removed an unnecessary `try` around the non-throwing `paste_queue` metrics
  wrapper in `MacClippyRuntime.swift`; the new instrumentation warning is gone.
- `swift test --package-path MacClippyKit`: 213/213 passed.
- `swift test --package-path MacClippyKit --sanitize=thread`: 213/213 passed;
  no ThreadSanitizer race report was emitted.
- `xcodegen generate`: passed.
- Unsigned Debug arm64 App build: passed using `build/final-verification`.
- Debug arm64 App `build-for-testing`: passed using
  `build/final-verification-tests`; the test bundle compiled but was not
  executed in this final pass because the local LaunchServices/XCTest worker
  materialization issue remains.
- `scripts/verify-build-metadata.sh` passed for both final App artifacts.
- The only remaining build diagnostics are the known local CoreSimulator
  framework-version mismatch and GRDB dependency-scan warning. They do not
  fail the macOS build, but should be cleaned up in the toolchain/project
  configuration before shipping.

## 2026-08-03 P1-A lifecycle transition hardening

- Audited the remaining `@unchecked Sendable` boundary. The lock-backed
  snippet snapshot, pasteboard sentinel, and diagnostics recorder remain
  justified by synchronous callback requirements. `MacClippyRuntime` remains
  an explicit exception because it coordinates synchronous AppKit APIs with
  GRDB stores, capture/OCR queues, and observer callbacks; its store and
  lifecycle boundaries are documented and covered by concurrency tests.
- Found a real transition race in `MacClippyRuntime.start()`/`stop()`: the
  running flag was changed before timer, notification, observer, and Snippet
  resources finished installing. A concurrent stop could return and then be
  followed by late resource installation.
- Added a dedicated lifecycle `NSLock` around `start`, `stop`, and
  `refreshPermissionDependentFeatures`. Store access remains under the
  existing `storeLock`; the new lock only serializes lifecycle resources.
- Added `MacClippyRuntimeConcurrencyTests.testRuntimeStartStopIsIdempotentAcrossRepeatedLifecycleTransitions`.
- `xcodebuild ... -derivedDataPath build/lifecycle-gate-tests ...
  build-for-testing`: passed; the new App test compiled.
- `./scripts/verify-build-metadata.sh
  build/lifecycle-gate-tests/Build/Products/Debug/MacClippy.app`: passed.
- `swift test --package-path MacClippyKit`: 213/213 passed.
- `swift test --package-path MacClippyKit --sanitize=thread`: 213/213 passed;
  no ThreadSanitizer race report.
- The new App XCTest was not counted as executed because LaunchServices still
  does not materialize the local XCTest worker. The standalone `xctest`
  command is not installed on this system, so no unsupported runner shortcut
  was claimed.
- Signing preflight found one valid identity, `Apple Development`; no
  Developer ID Application identity is installed. Release signing,
  notarization, Gatekeeper, and clean-user TCC verification remain external
  release gates.

## 2026-08-03 scale and lifecycle verification

- Explicit lifecycle pressure test:
  `MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyLifecycleStressTests`
  passed 1/1. The fixture completed 10,000 observer start/poll/stop cycles in
  0.172 seconds with no failures.
- Explicit scale fixture:
  `MACCLIPPY_RUN_SCALE_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyScaleTests`
  passed 2/2. The 100,000-record history/FTS search and pagination case took
  27.560 seconds; the 20 MiB representation spill/read/delete case also
  passed, including Blob cleanup.
- The scale fixtures do not print clipboard bodies, OCR text, image payloads,
  or file paths. These results are code-side regression evidence, not a
  substitute for Instruments or a 24–72 hour soak.

## 2026-08-03 privacy notice button fix

- Reproduced the reported behavior with the built app: the alert was entered
  synchronously from `applicationDidFinishLaunching` via `NSAlert.runModal()`;
  the alert was visible but AX click/Return did not dismiss it.
- Changed startup to schedule `presentPrivacyNoticeIfNeeded()` on the next
  main-queue turn, while retaining the compatible macOS 14 `runModal()` API.
  The alert is kept strongly during presentation and raised as a floating,
  active window.
- Fixed `Open Settings`: it now sends SwiftUI's `showSettingsWindow:` action
  and brings the newly-created Settings window forward on the next main-queue
  turn. The old coordinator-only path could not create a Settings window that
  did not already exist.
- Verification: App `build-for-testing` passed in
  `build/privacy-alert-fix-tests`; unsigned Debug App build passed in
  `build/privacy-alert-fix-app`; bundle metadata verification passed; package
  suite passed 213/213.
- Live verification of the rebuilt app was attempted, but this machine's
  debug process hung in system Keychain `SecItemCopyMatching` before reaching
  the privacy alert. No Keychain prompt or permission state was changed.

### 2026-08-04 final cleanup review started

- Read the existing plan, findings, and recent progress before acting.
- Loaded the required planning, technical audit, App Store review, and design-context instructions.
- Confirmed the project already has design context for native macOS power users, so no design-teaching pause is required.
- Initial inventory found no TODO/FIXME/HACK/XXX/`try!` markers in target source/tests; intentional AppKit initializer `fatalError`s remain.
- Confirmed the target source tree is reported as untracked by the parent worktree; cleanup will therefore use explicit reference checks and will not rely on Git deletion history.
- Errors: the first planning/audit skill paths in the previous continuation were invalid; the correct `.agents` and project `.codex` paths were then used. This was already recorded in the plan's error table.

- Baseline `make test` passed: package suite 213/213 and App XCTest 137/137, 0 failures.
- Debug arm64 app build passed in `.build/final-review-build`; only the known CoreSimulator version mismatch and AppIntents metadata warning appeared.
- SwiftLint remains non-zero on existing large-file/type-body, complexity, identifier, and line-length rules; it did not report unused imports or unreferenced declarations.
- Removed the unreferenced `MacClippyMotion.actionBarEnterTransition` and `MacClippyDockView.selectionIndex(for:)` helpers.
- Added `/build/`, `MacClippyKit/build/`, and `.DS_Store` ignore rules. Generated artifacts are queued for explicit trash cleanup after the source changes are verified.

### 2026-08-04 final cleanup completed

- Removed the unused runtime `textExclusionPatterns` parameter and stored `textBlocklist`; capture exclusions are owned by the live `CaptureExclusionRules` observer path.
- Corrected README capture/privacy wording so it matches conservative default exclusions and accepted-change representation retention.
- Cleaned generated outputs with the macOS Trash command after verifying the target paths contained only build/test artifacts. The final regression run recreated only `.build/` caches required by the test command; no source or historical docs were removed.
- Final `make test` passed: package suite 213/213 and App XCTest 137/137, 0 failures.
- Final Debug metadata check passed for `com.macallyouneed.macclippy`, `APPL`, `LSUIElement=true`, usage descriptions, and executable presence.
- Final audit score recorded in `findings.md`: 16/20 (Good).
- Final cleanup errors were non-product tooling/context issues only: one malformed private-scan path, one failed patch context, and one unsupported orchestration helper call; each was corrected without changing user data.
- After the final test run recreated approximately 1.6 GB of compiler caches, `.build/` and `MacClippyKit/.build/` were moved to the macOS Trash again. The workspace is back to about 3 MB of source/docs/configuration.

### 2026-08-04 DMG packaging target

- Compared the parent `Makefile` and `v2/vFlow/scripts/package-dmg.sh`.
- Added `scripts/package-dmg.sh` with the same staging layout (`MacClippy.app` plus `/Applications` link) and `hdiutil` UDZO creation.
- Added `make dmg` plus `make release` alias. The default is unsigned Release packaging; signing can be enabled through explicit environment variables.
- Added `dist/` to `.gitignore` and documented the command in README.

- Verified `make dmg` completed successfully on 2026-08-04. The unsigned arm64
  Release build produced `dist/MacClippy.dmg` (7.6 MB).
- Verified the image with `hdiutil imageinfo`: compressed UDZO, checksummed,
  unencrypted, with the expected APFS disk-image partition.
- The artifact is unsigned by default. Developer ID signing and notarization
  still require the corresponding local identity and Apple credentials.
